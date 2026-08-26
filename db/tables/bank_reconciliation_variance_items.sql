-- db/tables/bank_reconciliation_variance_items.sql
-- BANK-REC:**差额的逐项说明。**
--
-- 合法的差额是真实存在的:未兑现的支票、在途存款、时点差。一道只会拒绝、
-- 不给出口的闸,人会绕过去 —— 这个仓库有成文的教训(known-issues「摘掉一条
-- 安全状态是一次无痕迹的编辑」:闸没有出口,人就把那一行删掉直到灯灭)。
-- 所以差额有两条路:要么为 0,要么【逐项说清楚】。
--
-- ★【说明不会让两个数字相等】★ 报表照样是 reconciled,而它身上写着
--   "这两个数差 X,原因如下"。抹平差额才是错的 —— 那正是这张表存在的意义:
--   它记的是【差额为什么合理】,不是【差额不存在】。
--
-- 【挂在那一次对账上,不是挂在报表上】它属于一个冻结的事件,所以它自己也冻结
-- (trg_bank_variance_items_immutable 拦 UPDATE 与 DELETE)。重开报表再对一次,
-- 是一行新的 bank_reconciliations 加它自己的一组说明,旧的原样留着。
--
-- 【金额带符号,而这不是随手定的】未兑现的支票:账上已经把钱付掉、银行还没扣
-- → 银行余额【高于】账面 → book − bank 为负。在途存款方向相反。带符号的金额
-- 相加恰好等于差额,是这条规矩唯一自然的写法;"绝对值 + 方向枚举"会多出一个
-- 能填错的地方,而它填错时两边仍然能凑上。
--
-- 【item_kind 可枚举 → check-i18n 自己读得到这一行】文案键 bank.varianceKind.<kind>。
-- 加一个种类,检查的射程自动跟着变宽,不需要同时改检查。
--
-- 写入只走 reconcile_statement(SECURITY DEFINER),所以这里只开 SELECT。
--
-- NOTE: introduced by db/migrations/2026-08-26-bankrec-balance-agreement-and-the-explained-difference.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.bank_reconciliation_variance_items (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reconciliation_id uuid NOT NULL REFERENCES public.bank_reconciliations (id) ON DELETE RESTRICT,
    item_no           integer NOT NULL CHECK (item_no >= 1),
    item_kind         text NOT NULL CHECK (item_kind IN (
                          'unpresented_cheque',   -- 已开出、银行未兑现的支票
                          'deposit_in_transit',   -- 在途存款
                          'bank_charge',          -- 银行扣费,账上还没记
                          'bank_interest',        -- 银行计息,账上还没记
                          'timing',               -- 其它时点差
                          'error_to_correct'      -- 确认是错的,待更正分录
                      )),
    amount            numeric NOT NULL CHECK (amount <> 0),
    note              text NOT NULL CHECK (btrim(note) <> ''),
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    UNIQUE (reconciliation_id, item_no)
);

CREATE INDEX idx_bank_variance_items_recon
    ON public.bank_reconciliation_variance_items (reconciliation_id);

CREATE OR REPLACE FUNCTION public.reject_variance_item_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'VARIANCE_ITEM_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_bank_variance_items_immutable
    BEFORE UPDATE OR DELETE ON public.bank_reconciliation_variance_items
    FOR EACH ROW EXECUTE FUNCTION public.reject_variance_item_mutation();

ALTER TABLE public.bank_reconciliation_variance_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "bank_variance_items select by permission"
    ON public.bank_reconciliation_variance_items
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
