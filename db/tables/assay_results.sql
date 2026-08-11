-- db/tables/assay_results.sql
-- 化验单据:一行 = 一份实验室结果(或初检读数)对【一个批次】的含量断言。
--
-- 业务现实:货到在先,真实含量在后 —— 先按估计含量暂定计价,证书回来再按实际
-- 含量重算(apply_assay_result)。所以【记录与执行分开】:record_assay_result 只
-- 落这张表,不动批次;执行是显式动作,先能被人审阅。
--
-- PROC-1(2026-08-12):化验有两种父 —— 进料批或产出批,恰好一个
-- (num_nonnulls XOR,processing_inputs 的形状)。记录、编号、取代链共享;
-- 【应用拆开】:进料化验走 apply_assay_result(抄含量 + 重算应付),产出化验走
-- apply_output_assay(只抄含量 —— 产出批没有一张应付可以重述)。RLS 跟着父走:
-- 进料化验挂 module.inbound.*,产出化验挂 module.output.*。
--
--   * is_final 区分正式证书与初检/部分读数 —— 只有 is_final 的化验被执行后,
--     批次的 pricing_status 才升 'final'(仅进料侧;产出批没有定价状态);
--   * superseded_by 记录复验取代早先结果(链条保持可读;unapply 只许撤最新一环;
--     链按【父】各自成链 —— 进料链与产出链互不相扰);
--   * applied_at/by 是"已执行"标记 —— 执行时批次的含量表被替换为本化验的含量
--     (批次含量永远是当前最可信的真相),本行留作历史。
-- 无缝编号 'ASY-YYYY-NNNN':next_assay_code(),咨询锁串行化取号(同 JE/收付款);
-- 进料与产出化验共用一条序列 —— 化验单号是实验室视角的,不分进出。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut5a-assay-repricing.sql;
-- output parent by db/migrations/2026-08-12-proc1-output-assays.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.assay_results (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code             text NOT NULL UNIQUE,  -- gapless 'ASY-YYYY-NNNN'
    inbound_batch_id uuid REFERENCES public.inbound_batches (id),
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
    updated_by       uuid DEFAULT auth.uid(),
    -- PROC-1(ALTER 加列,留在末尾)
    output_batch_id  uuid REFERENCES public.output_batches (id),
    CONSTRAINT assay_results_one_parent
        CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1)
);

CREATE INDEX idx_assay_results_batch ON public.assay_results (inbound_batch_id);
CREATE INDEX idx_assay_results_output_batch ON public.assay_results (output_batch_id);

COMMENT ON COLUMN public.assay_results.output_batch_id IS
    'PROC-1:产出批父(与 inbound_batch_id 二选一,num_nonnulls = 1 —— processing_inputs 的形状)。挂产出批的化验由 apply_output_assay 应用:只抄含量、不动定价 —— 产出批没有一张应付可以重述。';

CREATE TRIGGER trg_assay_results_updated_at
    BEFORE UPDATE ON public.assay_results
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.assay_results ENABLE ROW LEVEL SECURITY;
-- PROC-1:RLS 跟着父走 —— 守卫跟着数据自己的归属,不跟着功能建在哪个目录(OPS-15)
CREATE POLICY "assay_results select by permission"
    ON public.assay_results
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)));

CREATE POLICY "assay_results insert by permission"
    ON public.assay_results
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
             OR (output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)));

CREATE POLICY "assay_results update by permission"
    ON public.assay_results
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)))
    WITH CHECK ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
             OR (output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)));

CREATE POLICY "assay_results delete by permission"
    ON public.assay_results
    AS PERMISSIVE FOR DELETE TO authenticated
    USING ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)));
