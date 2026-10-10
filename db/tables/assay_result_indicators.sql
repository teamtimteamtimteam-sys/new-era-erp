-- db/tables/assay_result_indicators.sql
-- MES-6a-2(2026-10-10,MES-6a Step 0 Q3 · Q4,Tim):一份化验上一个指标的值 —— 残粉、箔纯度、粒径(assay_indicators 的码)。
--   在两张化验表单上填,经 record_assay_result 的 p_indicators 一起落下(一份化验一笔事务);【没有写策略】,写只经那一支函数。
--   值 ≥ 0,没有上限、没有判定(Q3:没有限 —— V17 在 MES-6b)。单位是指标自己的(字典的 unit)。
--   批次上没有副本(Q3):批次页读的是它那几份化验上最近记下的值,不另存一份会漂开的数。
--   读:与化验的金属行同一条(化验挂在哪一批,就要那一批那一页的查看码)。
--
-- NOTE: introduced by db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.assay_result_indicators (
    assay_result_id uuid NOT NULL REFERENCES public.assay_results (id) ON DELETE CASCADE,
    indicator       text NOT NULL REFERENCES public.assay_indicators (code),
    value           numeric NOT NULL CHECK (value >= 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (assay_result_id, indicator)
);
CREATE INDEX assay_result_indicators_indicator_rel ON public.assay_result_indicators (indicator);

COMMENT ON TABLE public.assay_result_indicators IS
'MES-6a-2:一份化验上一个指标(assay_indicators)的值。经 record_assay_result 的 p_indicators 落下,没有写策略。值 ≥ 0,没有上限、没有判定(没有限,V17 在 MES-6b)。批次上不抄副本。读跟着化验的父批次(进料 / 产出查看码)。';
COMMENT ON COLUMN public.assay_result_indicators.value IS
'记下的值,单位是那个指标自己的(assay_indicators.unit,% 或 µm)。原样存、原样印,不舍入。';

ALTER TABLE public.assay_result_indicators ENABLE ROW LEVEL SECURITY;
-- 与 assay_result_metals 的读策略逐字同一个谓词(化验挂在哪一批,就要那一批那一页的查看码)。写:一条策略都不给。
CREATE POLICY "assay_result_indicators select by permission"
    ON public.assay_result_indicators
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.assay_results ar
                    WHERE ar.id = assay_result_indicators.assay_result_id
                      AND ((ar.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
                        OR (ar.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)))));
GRANT SELECT ON public.assay_result_indicators TO authenticated;
REVOKE ALL ON public.assay_result_indicators FROM anon;
