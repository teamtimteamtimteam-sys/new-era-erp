-- db/tables/certificates_of_analysis.sql
-- MES-6b-2(2026-10-15,MES-0 功能 18 · Q53 · Q67 · Q68 · Q89 · Q90;MES-6b Step 0 Q10–Q14 · Q29–Q32,Tim):【一张分析证书(CoA)】——
--   交给买方的那张纸:这一批产出是什么成分、谁测的、按哪一份结果说话、来料的化学有多确定。
--
--   【主体】恰好一批产出批;可选地点名一张销售单(Q10)—— 点名了,纸上多出那张单所挂合同的 V17 验收限与判定、以及客户的名字。
--     销售单必须是预留过或发过这一批的那几张之一(COA_SALES_ORDER_NOT_FOR_BATCH)。
--     【一批 × 一张单(或不点名)同时只有一张活证书】(uq_coa_live_per_batch_order);作废的留着。
--   【号在签发那一刻铸】COA-YYYY-NNNN,按年无洞(next_coa_code;document_types 的 'coa';宽度 GREATEST(4, 位数))。没有 pending 状态 ——
--     一张证书生下来就是签发了的(与 COD 不同:COD 由判据自己成立、等人签发;CoA 是人在那一刻要一张)。
--   【说话的那一份化验】governing_assay_id(Q11):结案争议点名的那一份;否则点名了单 → 那张单的合同约定那一方最新一份活的;否则我们最新一份活的。
--     它必须 is_final。纸上的成分读【那一份化验自己的行】(assay_result_metals / assay_result_indicators),【从不读 output_batch_metals】。
--   【快照】snapshot:签发那一刻纸上每一个值,由库组装一次(coa_assemble)。PDF 只从它渲染;字节存进私有桶 coa-documents,
--     哈希在 coa_issues(Q31)。读取路径【不许】拿快照里的 id 回查内容(与 certificates_of_destruction.snapshot 同一条)。
--   【作废】只经 CFO 申请(warehouse_requests 的 coa_void,二级,不分档;Q20 · Q32):行留着,快照与字节一个字不动;
--     重开一张是一个新号,作废的那一张 replaced_by_coa_id 指向它。【永远不会被自动作废】—— 事实变了只在提醒 coa_facts_changed 里说。
--   【读】跟着那一批的查看码(module.output.view,Q30)。写:一条策略都不给 —— 只经 issue_coa / void_coa_internal。
--   【没有金额】—— 没有遮蔽的列(Q39)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.certificates_of_analysis (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                text NOT NULL UNIQUE,
    output_batch_id     uuid NOT NULL REFERENCES public.output_batches (id),
    -- 可选:点名的那一张销售单(Q10)
    sales_order_id      uuid REFERENCES public.sales_orders (id),
    -- 说话的那一份化验(Q11)—— 签发那一刻选定,冻住
    governing_assay_id  uuid NOT NULL REFERENCES public.assay_results (id),
    status              text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued', 'void')),
    issued_at           timestamptz NOT NULL,
    issued_by           uuid NOT NULL,
    -- 签发那一刻纸上的每一个值(由库组装一次)
    snapshot            jsonb NOT NULL,
    void_reason         text,
    voided_at           timestamptz,
    voided_by           uuid,
    -- 作废之后顶上来的那一张(同一批 × 同一张单的下一张证书,签发时由 issue_coa 填)
    replaced_by_coa_id  uuid REFERENCES public.certificates_of_analysis (id),
    created_at          timestamptz NOT NULL DEFAULT now(),
    -- 作废必须有理由、时刻与人 —— 与 cod_void_has_reason 同一条
    CONSTRAINT certificates_of_analysis_void_shape CHECK (
        (status = 'void') = (voided_at IS NOT NULL)
        AND (voided_at IS NULL) = (voided_by IS NULL)
        AND (status <> 'void' OR (void_reason IS NOT NULL AND btrim(void_reason) <> ''))),
    -- 只有作废的那一张才有替代品,而且不是它自己
    CONSTRAINT certificates_of_analysis_replacement_shape CHECK (
        replaced_by_coa_id IS NULL OR (status = 'void' AND replaced_by_coa_id <> id))
);

-- 【一批 × 一张单(或不点名)同时只有一张活证书】作废掉的留着 —— 买方手里那张纸要查得到。
CREATE UNIQUE INDEX uq_coa_live_per_batch_order
    ON public.certificates_of_analysis (output_batch_id, COALESCE(sales_order_id, '00000000-0000-0000-0000-000000000000'::uuid))
    WHERE status <> 'void';
CREATE INDEX certificates_of_analysis_output_batch_id_rel ON public.certificates_of_analysis (output_batch_id);
CREATE INDEX certificates_of_analysis_sales_order_id_rel ON public.certificates_of_analysis (sales_order_id);
CREATE INDEX certificates_of_analysis_governing_assay_id_rel ON public.certificates_of_analysis (governing_assay_id);
CREATE INDEX certificates_of_analysis_replaced_by_coa_id_rel ON public.certificates_of_analysis (replaced_by_coa_id);
-- 搜索:code 的后缀匹配(与 nonconformance_reports 同一条)
CREATE INDEX certificates_of_analysis_code_trgm ON public.certificates_of_analysis USING gin (code extensions.gin_trgm_ops);

COMMENT ON TABLE public.certificates_of_analysis IS
    'MES-6b-2:一张分析证书(COA-YYYY-NNNN)—— 恰好一批产出批,可选地点名一张预留过或发过它的销售单(点名了就多出合同的 V17 验收限、判定与客户名)。一批 × 一张单同时只有一张活证书。号在签发那一刻铸,没有 pending。说话的那一份化验(governing_assay_id)是结案争议点名的那一份,否则合同约定那一方(点名了单)或我们最新一份活的结果,必须 is_final;成分读那一份化验自己的行,从不读批次含量。快照由库组装一次,PDF 只从快照渲染,字节在私有桶 coa-documents、哈希在 coa_issues。作废只经 CFO 申请(warehouse_requests 的 coa_void),行、快照与字节都留着;重开一张是新号,旧的 replaced_by_coa_id 指向它;永远不会被自动作废。读跟着那一批的查看码。没有金额。';
COMMENT ON COLUMN public.certificates_of_analysis.snapshot IS
    'MES-6b-2(Q31):签发那一刻纸上每一个值的副本 —— 公司、批次、说话的那一份化验与它的成分 / 指标、来料化学确定度(N38)、点名的单与合同的验收限 / 判定 / 客户名、签发人(名字与职位)与签发时刻。由 coa_assemble 组装一次;PDF 只从它渲染。里面的 *_id 只回答"这来自哪一行",【任何读取路径都不许拿它回查内容】。';
COMMENT ON COLUMN public.certificates_of_analysis.governing_assay_id IS
    'MES-6b-2(Q11):纸上说话的那一份化验 —— 结案争议点名的那一份(最近结案的那一件);否则点名了销售单 → 那张单所挂合同约定那一方最新一份没删的结果;否则我们(ours)最新一份没删的结果。必须 is_final(COA_NO_FINAL_ASSAY)。签发那一刻选定,冻住。';

ALTER TABLE public.certificates_of_analysis ENABLE ROW LEVEL SECURITY;
-- 读:跟着那一批的查看码(Q30)。写:一条策略都不给 —— 只经 issue_coa / void_coa_internal(SECURITY DEFINER)。
CREATE POLICY "certificates_of_analysis select by permission" ON public.certificates_of_analysis
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.output.view'::text));
GRANT SELECT ON public.certificates_of_analysis TO authenticated;
REVOKE ALL ON public.certificates_of_analysis FROM anon;

-- 【签发之后内容一个字都不许改 —— 只许作废,作废之后只许填一次替代品】;不许删、不许清空。属主路径同样受它管。
CREATE TRIGGER trg_certificates_of_analysis_mutation
    BEFORE UPDATE OR DELETE ON public.certificates_of_analysis
    FOR EACH ROW EXECUTE FUNCTION public.guard_coa_mutation();
CREATE TRIGGER trg_certificates_of_analysis_truncate
    BEFORE TRUNCATE ON public.certificates_of_analysis
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
