-- db/tables/fx_rate_history.sql
-- FX-RATES-1:**牌价的变更史 —— append-only。**
--
-- 【为什么牌价【可改】,而已申报的报表【不可改】—— 这两条不能合成一条】
--   已申报的 GST 报表、已签下的银行对账,是**我们发出去的单据**:它们冻结,
--   更正是一个新事件(gst_return_boxes / bank_reconciliations)。
--   一条牌价是**我们记录下来的世界事实**。手滑打错一个数,不是世界上发生了
--   一件新事,是【我们对世界的记录错了】—— 那是一次更正,不是一个事件。
--   所以走 price_history 那个形状:当前值可改,改必须经函数,每次改留一行。
--
-- 【被它替掉的是什么】FX-RATES-1 之前,改一条牌价是【就地编辑,零痕迹】,
-- 撤销是【直接改 deleted_at,零痕迹】,而 RLS 还允许【硬删】。
-- 那是唯一一种"一次表单提交就能销毁审计线索"的路径。
-- 已过账的凭证不受影响(journal_lines.fx_rate 冻在行上),
-- 但"我们那天到底用的哪个数"会被静静改写 —— 而那个问题日后一定有人问。
--
-- 写入只走 record_fx_rate / withdraw_fx_rate(SECURITY DEFINER),故只开 SELECT。
--
-- NOTE: introduced by db/migrations/2026-08-27-fxrates1-one-write-path-history-and-month-end-readiness.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.fx_rate_history (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    fx_rate_id  uuid NOT NULL REFERENCES public.fx_rates (id) ON DELETE RESTRICT,
    action      text NOT NULL CHECK (action IN ('created', 'corrected', 'withdrawn')),
    -- 这一刻【之后】这条牌价是什么(withdrawn 记的是撤销前的值)
    currency    text NOT NULL,
    rate_date   date NOT NULL,
    rate_type   text NOT NULL,
    rate_sgd_per_unit numeric NOT NULL CHECK (rate_sgd_per_unit > 0),
    -- 改之前是什么(created 时为 NULL —— 之前什么都不是)
    prev_rate   numeric CHECK (prev_rate IS NULL OR prev_rate > 0),
    source      text,
    notes       text,
    -- 【更正与撤销必须给理由】新建不用:新建的理由就是"这天的牌价是这个数"。
    reason      text,
    CONSTRAINT fx_rate_history_reason_shape CHECK (
        (action = 'created'   AND prev_rate IS NULL AND reason IS NULL)
     OR (action = 'corrected' AND prev_rate IS NOT NULL AND btrim(COALESCE(reason,'')) <> '')
     OR (action = 'withdrawn' AND btrim(COALESCE(reason,'')) <> '')
    ),
    changed_at  timestamptz NOT NULL DEFAULT now(),
    changed_by  uuid DEFAULT auth.uid()
);

CREATE INDEX idx_fx_rate_history_rate ON public.fx_rate_history (fx_rate_id, changed_at);

CREATE OR REPLACE FUNCTION public.reject_fx_rate_history_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'FX_RATE_HISTORY_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_fx_rate_history_immutable
    BEFORE UPDATE OR DELETE ON public.fx_rate_history
    FOR EACH ROW EXECUTE FUNCTION public.reject_fx_rate_history_mutation();

ALTER TABLE public.fx_rate_history ENABLE ROW LEVEL SECURITY;
-- 写入只走 record_fx_rate / withdraw_fx_rate(SECURITY DEFINER),故只开 SELECT。
CREATE POLICY "fx_rate_history select by permission"
    ON public.fx_rate_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
