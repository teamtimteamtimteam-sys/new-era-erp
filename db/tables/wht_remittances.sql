-- db/tables/wht_remittances.sql
-- WHT-1:一次向 IRAS 的预提税汇款,只可追加。
--
-- ★【与 gst_periods 不同:没有「打开一期」这个动作】★ 欠多少是从【已经发生的
--   代扣】推导出来的(wht_liability_by_month 从总账读),不需要谁先声明这个月
--   存在。于是「没有人开这一期、于是这个月的税悄悄没人管」在结构上不存在。
--
-- ★【补汇是第二次汇款,不是对第一次的更正】★ 所以同一个月可以有多行,
--   而不是一个 superseded 标志。真要更正,冲销那张分录 —— 已汇金额从总账
--   那一侧读,冲销会让它自动不作数。
--
-- 写入只走 remit_wht(SECURITY DEFINER);这里只开 SELECT。
--
-- NOTE: introduced by db/migrations/2026-08-28-wht1-withholding-tax-on-non-resident-payments.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.wht_remittances (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code             text NOT NULL UNIQUE,        -- 'WHT-2026-08',补汇为 'WHT-2026-08-2'
    -- 这一笔汇的是【哪一个代扣月】的税。它与 remitted_on 通常差一个月,那是设计:
    -- 当月代扣的税,次月 15 日前申报并缴纳(与 CPF 次月 14 日同一种形状)。
    period_month     date NOT NULL,               -- 当月 1 号
    remitted_on      date NOT NULL,               -- 实际付出去的那一天
    amount_base      numeric NOT NULL CHECK (amount_base > 0),
    -- IRAS S45 电子申报的回执/参考号。**必填** —— 一笔说不出参考号的汇款,
    -- 日后对着 IRAS 无从交代(与 gst_periods.filed_reference 同一条理由,
    -- 只是那一条允许空,而这里不允许:那边"申报"与"缴款"是两件事,这里是一件)。
    filed_reference  text NOT NULL,
    journal_entry_id uuid NOT NULL REFERENCES public.journal_entries (id),
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    CONSTRAINT wht_remittances_month_is_first CHECK (period_month = date_trunc('month', period_month)::date),
    -- 汇款日不能早于它所属的那个月 —— 还没发生的代扣汇不出去。
    CONSTRAINT wht_remittances_after_period CHECK (remitted_on >= period_month)
);

CREATE INDEX idx_wht_remittances_month ON public.wht_remittances (period_month);

-- 只可追加:一次汇款是一件发生过的事。**改正的走法是冲销那张分录**,
-- 而不是改这一行 —— 见 wht_liability_by_month 的视图注释:已汇金额是从
-- 【总账】读的,所以冲销分录会让这一笔自动不作数,不需要在这里标任何状态。
CREATE OR REPLACE FUNCTION public.guard_wht_remittance_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'WHT_REMITTANCE_IMMUTABLE|%', COALESCE(OLD.code, NEW.code);
END;
$function$;

CREATE TRIGGER trg_wht_remittances_append_only
    BEFORE UPDATE OR DELETE ON public.wht_remittances
    FOR EACH ROW EXECUTE FUNCTION public.guard_wht_remittance_append_only();

ALTER TABLE public.wht_remittances ENABLE ROW LEVEL SECURITY;
CREATE POLICY "wht_remittances select by permission"
    ON public.wht_remittances
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

COMMENT ON TABLE public.wht_remittances IS
'WHT-1:一次向 IRAS 的预提税汇款,只可追加。**没有"打开一期"这个动作** ——
欠多少是从已经发生的代扣【推导】出来的,汇了多少是【记录】下来的。
同一个月可以有多行(补汇):一笔补汇是【第二次汇款】,不是对第一次的更正,
所以它是新的一行而不是一个 superseded 标志。
真要更正,冲销那张分录 —— 已汇金额从总账读,冲销会让它自动不作数。';
