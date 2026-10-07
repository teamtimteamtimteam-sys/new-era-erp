-- db/tables/processing_run_closures.sql
-- MES-4a(2026-10-07,规格 §4.1;MES-0 Q46 · Q47 · Q50;MES-4a Step 0 Q17–Q23,Tim):【一炉的物料平衡结平】—— 只追加。
--   规格 §4.1:每一个分叉点,投入 = 各产出之和 + 有名字的损耗;偏差带按工序预先定好,超出它的不能直接结,要一句书面说明。
--   一行 = 一次结平,抄下那一刻的账:投入、产出、有名字的损耗、余数(= 投入 − 产出 − 有名字的损耗,即"没解释的质量")、
--   那道工序当时的容差(balance_tolerance_pct;为空 = Not yet set,V1)与判断(within_tolerance;容差没给时为 NULL)、说明、谁、何时。
--   ★ 规则在 close_run_balance(action.processing_aftercare,Q50):余数为 0 → 结;在一个【给了的】容差里 → 结,说明可选;
--     容差没给而余数不为 0(Q46),或超出容差(Q47)→ 必须写说明,不要第二个人。必填的值缺着、或有产出没挂称重 → 不许结。
--   【重开】之后再有一条损耗或一个值被记下或更正(它们的 id 大于这一行抄下的水位线 loss_watermark / value_watermark),
--   这次结平就【不再是当前的】—— 那一炉回到"没结平",要人再结一次。只追加,所以重开不改任何一行:它是读出来的。
--   水位线用 id(identity)而不是时间:同一笔事务里写的两行,now() 一模一样(AGENTS.md「取最新那一行」)。
--   UPDATE / DELETE / TRUNCATE 语句级拒。读:module.processing.view。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.processing_run_closures (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id           uuid NOT NULL REFERENCES public.processing_runs (id),
    input_qty        numeric NOT NULL,
    output_qty       numeric NOT NULL,
    named_loss_qty   numeric NOT NULL,
    remainder_qty    numeric NOT NULL,
    tolerance_pct    numeric,
    within_tolerance boolean,
    explanation      text,
    loss_watermark   bigint NOT NULL DEFAULT 0,
    value_watermark  bigint NOT NULL DEFAULT 0,
    closed_at        timestamptz NOT NULL DEFAULT now(),
    closed_by        uuid DEFAULT auth.uid(),
    CONSTRAINT processing_run_closures_arithmetic
        CHECK (remainder_qty = input_qty - output_qty - named_loss_qty),
    CONSTRAINT processing_run_closures_explained
        CHECK (remainder_qty = 0 OR within_tolerance IS TRUE OR (explanation IS NOT NULL AND btrim(explanation) <> ''))
);

COMMENT ON TABLE public.processing_run_closures IS
    'MES-4a:一炉物料平衡的结平(规格 §4.1),只追加。抄下那一刻的投入 · 产出 · 有名字的损耗 · 余数 · 容差与判断 · 说明。余数不为 0 而又不在一个给了的容差里 → 必须有说明(表上的 CHECK 与 close_run_balance 同一句)。之后的损耗或值越过水位线 → 这次结平不再当前(重开是读出来的)。';

CREATE INDEX processing_run_closures_run ON public.processing_run_closures (run_id);

CREATE TRIGGER trg_processing_run_closures_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.processing_run_closures
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.processing_run_closures ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_run_closures select by permission" ON public.processing_run_closures
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
GRANT SELECT ON public.processing_run_closures TO authenticated;
REVOKE ALL ON public.processing_run_closures FROM anon;
