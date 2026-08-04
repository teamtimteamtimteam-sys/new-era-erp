-- FIN-8:成本条目的留痕,与"分摊已过期"这个信号。
--
-- 两件事,同一个根:成本条目【可以改】,但改完之后没有任何东西记得改过什么,
-- 也没有任何东西告诉人"这一改让批次成本对不上了"。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【A. 留痕:跟 employment_history 走,不做成不可变】
-- ════════════════════════════════════════════════════════════════════════════
-- 这套系统里带钱的记录只有两种成规:
--   * 不可变 —— 分录行、库存流水、发票(作废重开)、已批准的评估;
--   * 可变的行 + 只增不改的历史 —— employees 旁边挂 employment_history。
-- 成本条目走【第二种】,理由是估算变实际本来就是 FIN-6 的设计意图:改金额是
-- 正常业务动作,不是更正错误。若做成不可变,一次录错就得作废重开,与设计相悖。
-- 而且它底下的账【本来就是只增不改的】—— fin_journal_cost_entry 从不改旧分录,
-- 它冲旧记新。所以"可变的行 + 只增不改的历史"正是这条已经成立的形状。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【B. 分摊过期:标出来,不自动重跑】
-- ════════════════════════════════════════════════════════════════════════════
-- allocate_processing_costs 是显式调用,按调用那一刻的成本快照写死批次成本。
-- 之后再改成本条目,总账会动(触发器冲旧记新),批次【不会】—— 两边就此劈叉,
-- 且没有任何地方报出来。PROC-2026-0003 现在就是这样:分录已按 500 记,批次仍是 400。
--
-- 【不自动重跑】的理由,与 FIN-6 不自动冲销估算差异是同一条:重跑会改写资本化,
-- 而批次可能已经卖掉一部分。实测(2026-08-04,回滚 fixture)确认:
--   * 重跑本身是安全的,会先冲销旧资本化分录再重挂;
--   * 但【已过账的 COGS 不会重述】(10b 只补 cogs_entry_id IS NULL 的销售),
--     而资本化是按【全量】重挂的 —— 也就是说,已售部分的成本增量会落在存货
--     (1220)而不是销货成本里,并且一直留在那儿。
--   * 对比 reprice_inbound_batch:它按在库比例把差额【拆开】,在库进 1200、
--     已耗进 5000。分摊没有这个拆分,它假设批次原封未动。
-- 所以视图除了报"过期",还要报【这一单能不能安全重跑】(有没有已过账的 COGS),
-- 界面据此给不同的话术,而不是一个按钮糊弄两种情况。

BEGIN;

-- ── A. 留痕表 ───────────────────────────────────────────────────────────────
CREATE TABLE public.processing_cost_entry_history (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_id         uuid NOT NULL REFERENCES public.processing_cost_entries (id),
    run_id           uuid NOT NULL REFERENCES public.processing_runs (id),
    change_type      text NOT NULL CHECK (change_type IN ('create','update','delete','restore')),
    old_amount_base  numeric,
    new_amount_base  numeric,
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

-- 只增不改:UPDATE/DELETE 一律挡掉,免得"历史"本身也能被改
CREATE OR REPLACE FUNCTION public.guard_cost_entry_history_append_only()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'HISTORY_APPEND_ONLY';
END;
$fn$;

CREATE TRIGGER trg_cost_entry_history_append_only
    BEFORE UPDATE OR DELETE ON public.processing_cost_entry_history
    FOR EACH ROW EXECUTE FUNCTION guard_cost_entry_history_append_only();

-- 写历史的触发器。changed_by 优先取行上的 updated_by(应用会写),否则 auth.uid()。
CREATE OR REPLACE FUNCTION public.log_cost_entry_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_type text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO processing_cost_entry_history (
            entry_id, run_id, change_type, new_amount_base, new_cost_type, new_is_estimate, changed_by)
        VALUES (NEW.id, NEW.run_id, 'create', NEW.amount_base, NEW.cost_type, NEW.is_estimate,
                COALESCE(NEW.created_by, auth.uid()));
        RETURN NULL;
    END IF;

    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        v_type := 'delete';
    ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
        v_type := 'restore';
    ELSIF NEW.amount_base IS DISTINCT FROM OLD.amount_base
       OR NEW.cost_type   IS DISTINCT FROM OLD.cost_type
       OR NEW.is_estimate IS DISTINCT FROM OLD.is_estimate THEN
        v_type := 'update';
    ELSE
        RETURN NULL;  -- 只动了备注之类,不留痕
    END IF;

    INSERT INTO processing_cost_entry_history (
        entry_id, run_id, change_type,
        old_amount_base, new_amount_base, old_cost_type, new_cost_type,
        old_is_estimate, new_is_estimate, changed_by)
    VALUES (NEW.id, NEW.run_id, v_type,
            OLD.amount_base, NEW.amount_base, OLD.cost_type, NEW.cost_type,
            OLD.is_estimate, NEW.is_estimate, COALESCE(NEW.updated_by, auth.uid()));
    RETURN NULL;
END;
$fn$;

CREATE TRIGGER trg_processing_cost_entries_history_ins
    AFTER INSERT ON public.processing_cost_entries
    FOR EACH ROW EXECUTE FUNCTION log_cost_entry_change();
CREATE TRIGGER trg_processing_cost_entries_history_upd
    AFTER UPDATE ON public.processing_cost_entries
    FOR EACH ROW EXECUTE FUNCTION log_cost_entry_change();

ALTER TABLE public.processing_cost_entry_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cost entry history select by permission" ON public.processing_cost_entry_history
    FOR SELECT USING (has_permission('module.processing.view'::text));

-- 【金额敏感,与 amount_base 同口径】收回表级 SELECT,列清单只给非金额列,
-- 金额只经遮蔽视图按 data.view_prices 出现 —— 与 processing_cost_entries 一致。
-- 加列时两处都要改,否则 db/gate.py 的【列权限缺口】判据会失败(这正是本次的教训)。
REVOKE SELECT ON public.processing_cost_entry_history FROM authenticated, anon;
GRANT SELECT (id, entry_id, run_id, change_type, old_cost_type, new_cost_type,
              old_is_estimate, new_is_estimate, changed_at, changed_by)
    ON public.processing_cost_entry_history TO authenticated;

CREATE VIEW public.processing_cost_entry_history_masked WITH (security_invoker = off) AS
 SELECT id,
    entry_id,
    run_id,
    change_type,
        CASE WHEN has_permission('data.view_prices'::text) THEN old_amount_base ELSE NULL::numeric END AS old_amount_base,
        CASE WHEN has_permission('data.view_prices'::text) THEN new_amount_base ELSE NULL::numeric END AS new_amount_base,
    old_cost_type,
    new_cost_type,
    old_is_estimate,
    new_is_estimate,
    changed_at,
    changed_by
   FROM processing_cost_entry_history
  WHERE has_permission('module.processing.view'::text);

GRANT SELECT ON public.processing_cost_entry_history_masked TO authenticated;

-- ── B. 分摊状态视图 ─────────────────────────────────────────────────────────
-- security_invoker:没有敏感列,让基表的 RLS 照常生效即可(不同于遮蔽视图)。
CREATE VIEW public.processing_run_allocation_status WITH (security_invoker = on) AS
 SELECT r.id AS run_id,
    r.code,
    r.allocated_at,
    c.last_cost_change,
    -- 过期 = 分摊过,而且分摊之后成本条目还动过(含软删,删一条也改总额)
    (r.allocated_at IS NOT NULL AND c.last_cost_change IS NOT NULL
     AND c.last_cost_change > r.allocated_at) AS is_stale,
    COALESCE(g.cogs_posted, 0) AS cogs_posted,
    -- 能否安全重跑:已过账的 COGS 不会被重述,而资本化按全量重挂 ——
    -- 已售部分的成本增量会留在存货里。有 COGS 的单必须人工判断,不能一键。
    (COALESCE(g.cogs_posted, 0) = 0) AS safe_to_reallocate
   FROM processing_runs r
   LEFT JOIN LATERAL (
       SELECT max(GREATEST(e.created_at, e.updated_at)) AS last_cost_change
       FROM processing_cost_entries e WHERE e.run_id = r.id
   ) c ON true
   LEFT JOIN LATERAL (
       SELECT count(*) AS cogs_posted
       FROM sales_records sr
       JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = r.id
       WHERE sr.cogs_entry_id IS NOT NULL
   ) g ON true
  WHERE r.deleted_at IS NULL;

GRANT SELECT ON public.processing_run_allocation_status TO authenticated;

-- ── C. 函数执行权 ───────────────────────────────────────────────────────────
-- 触发器函数不该被谁直接调用(B1/B2 判据)。新加的两个一并收干净。
REVOKE EXECUTE ON FUNCTION public.log_cost_entry_change() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.guard_cost_entry_history_append_only() FROM PUBLIC, anon;
-- 顺手补上 FIN-6 遗留的同类问题:gate 的 B1 判据早已在报它(anon 可 EXECUTE),
-- 就在这张表的触发器上,跟本次改动同一处,一起收掉而不是留着继续报。
REVOKE EXECUTE ON FUNCTION public.guard_cost_entry_settled() FROM PUBLIC, anon;

COMMIT;
