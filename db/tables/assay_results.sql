-- db/tables/assay_results.sql
-- 化验单据:一行 = 一份实验室结果(或初检读数)对一个进料批次的含量断言。
--
-- 业务现实:货到在先,真实含量在后 —— 先按估计含量暂定计价,证书回来再按实际
-- 含量重算(apply_assay_result)。所以【记录与执行分开】:record_assay_result 只
-- 落这张表,不动批次;执行是显式动作,先能被人审阅。
--
--   * is_final 区分正式证书与初检/部分读数 —— 只有 is_final 的化验被执行后,
--     批次的 pricing_status 才升 'final';
--   * superseded_by 记录复验取代早先结果(链条保持可读;unapply 只许撤最新一环);
--   * applied_at/by 是"已执行"标记 —— 执行时批次的 inbound_batch_metals 被替换为
--     本化验的含量(批次含量永远是当前最可信的真相),本行留作历史。
-- 无缝编号 'ASY-YYYY-NNNN':next_assay_code(),咨询锁串行化取号(同 JE/收付款)。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut5a-assay-repricing.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.assay_results (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code             text NOT NULL UNIQUE,  -- gapless 'ASY-YYYY-NNNN'
    inbound_batch_id uuid NOT NULL REFERENCES public.inbound_batches (id),
    assay_date       date NOT NULL,
    lab_name         text,
    certificate_ref  text,
    sample_ref       text,
    is_final         boolean NOT NULL DEFAULT true,
    notes            text,
    applied_at       timestamptz,
    applied_by       uuid,
    superseded_by    uuid REFERENCES public.assay_results (id),
    deleted_at       timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid DEFAULT auth.uid()
);

CREATE INDEX idx_assay_results_batch ON public.assay_results (inbound_batch_id);

CREATE TRIGGER trg_assay_results_updated_at
    BEFORE UPDATE ON public.assay_results
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.assay_results ENABLE ROW LEVEL SECURITY;
CREATE POLICY "assay_results select by permission"
    ON public.assay_results
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'::text));

CREATE POLICY "assay_results insert by permission"
    ON public.assay_results
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'::text));

CREATE POLICY "assay_results update by permission"
    ON public.assay_results
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit'::text)) WITH CHECK (has_permission('module.inbound.edit'::text));

CREATE POLICY "assay_results delete by permission"
    ON public.assay_results
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inbound.edit'::text));
