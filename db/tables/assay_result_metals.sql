-- db/tables/assay_result_metals.sql
-- 化验单据的逐金属含量行。与 inbound_batch_metals / metal_prices 共用同一套
-- 七金属 CHECK 集合(加金属时同时放宽所有这些 CHECK)。
-- apply_assay_result 执行时把这些行【复制】到 inbound_batch_metals(删后重插)——
-- 本表是历史,批次含量表是当前真相。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut5a-assay-repricing.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.assay_result_metals (
    assay_result_id uuid NOT NULL REFERENCES public.assay_results (id) ON DELETE CASCADE,
    metal           text NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    content_pct     numeric NOT NULL CHECK (content_pct >= 0 AND content_pct <= 100),
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (assay_result_id, metal)
);

ALTER TABLE public.assay_result_metals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "assay_result_metals select by permission"
    ON public.assay_result_metals
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'::text));

CREATE POLICY "assay_result_metals insert by permission"
    ON public.assay_result_metals
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'::text));

CREATE POLICY "assay_result_metals update by permission"
    ON public.assay_result_metals
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit'::text)) WITH CHECK (has_permission('module.inbound.edit'::text));

CREATE POLICY "assay_result_metals delete by permission"
    ON public.assay_result_metals
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inbound.edit'::text));
