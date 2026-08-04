-- db/tables/processing_cost_entry_history.sql
-- 成本条目的【只增不改】历史。
--
-- 【为什么是这个形状,不是不可变】这套系统里带钱的记录只有两种成规:不可变
-- (分录行、库存流水、发票作废重开、已批准的评估),或者【可变的行 + 只增不改的
-- 历史】(employees 旁边的 employment_history)。成本条目走后者,因为"估算变实际"
-- 本来就是 FIN-6 的设计意图 —— 改金额是正常业务动作,不是更正错误;做成不可变会
-- 逼着人为一次录入错误去作废重开。而且它底下的账【已经】是只增不改的:
-- fin_journal_cost_entry 从不改旧分录,它冲旧记新。
--
-- 【受限访问列】old_amount_base / new_amount_base —— 与 processing_cost_entries
-- 的 amount_base 同口径,归 data.view_prices,只经 _masked 视图出现。
-- 加列时:列清单 SELECT 授权与 _masked 视图【两处都要改】,否则新列有写无读,
-- 页面 42501 而静默空白(FIN-6 就是这么漏的);db/gate.py 现在会当场点名。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin8-cost-entry-history-and-stale-allocation.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.processing_cost_entry_history (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_id         uuid NOT NULL REFERENCES public.processing_cost_entries (id),
    run_id           uuid NOT NULL REFERENCES public.processing_runs (id),
    change_type      text NOT NULL CHECK (change_type IN ('create','update','delete','restore')),
    old_amount_base  numeric,  -- RESTRICTED
    new_amount_base  numeric,  -- RESTRICTED
    old_cost_type    text,
    new_cost_type    text,
    old_is_estimate  boolean,
    new_is_estimate  boolean,
    changed_at       timestamptz NOT NULL DEFAULT now(),
    changed_by       uuid
);

CREATE INDEX idx_cost_entry_history_entry ON public.processing_cost_entry_history (entry_id, changed_at DESC);
CREATE INDEX idx_cost_entry_history_run   ON public.processing_cost_entry_history (run_id, changed_at DESC);

COMMENT ON TABLE public.processing_cost_entry_history IS
    '成本条目的只增不改历史(employment_history 的形状)。谁、什么时候、从多少改到多少。';

-- 历史本身不许被改写 —— 否则"留痕"只是摆设(函数体在 db/functions/)
CREATE TRIGGER trg_cost_entry_history_append_only
    BEFORE UPDATE OR DELETE ON public.processing_cost_entry_history
    FOR EACH ROW EXECUTE FUNCTION guard_cost_entry_history_append_only();

ALTER TABLE public.processing_cost_entry_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cost entry history select by permission" ON public.processing_cost_entry_history
    FOR SELECT USING (has_permission('module.processing.view'::text));

-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
-- 【加列必改这一行】列清单 SELECT 授权不会自动延伸到 ALTER 加的新列。
REVOKE SELECT ON public.processing_cost_entry_history FROM authenticated, anon;
GRANT SELECT (id, entry_id, run_id, change_type, old_cost_type, new_cost_type,
              old_is_estimate, new_is_estimate, changed_at, changed_by)
    ON public.processing_cost_entry_history TO authenticated;
