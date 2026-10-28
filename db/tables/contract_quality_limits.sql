-- db/tables/contract_quality_limits.sql
-- MES-6b-1(2026-10-15,MES-6a Step 0 Q5 · V17;MES-6b Step 0 Q8 · Q25 · Q26,Tim):【卖方合同的质量验收限】—— 水分与粒径(以及任何一个化验指标)
--   的上 / 下限,逐份合同、可以按物料分。合同的第八张条款表,与品位规格(contract_grade_specs)是兄弟:品位规格的 metal 是指向 substances 的外键,
--   装不下水分与指标,所以另开一张(Step 0 §1.4)。
--
--   【参数】parameter = 'moisture_pct'(化验自己那一列水分)或 assay_indicators 里的一个码(残粉 · 箔纯度 · D10 / D50 / D90)。
--     一对 CHECK / 外键把它钉住:indicator 是由 parameter 算出来的存储列(水分时为空),外键指 assay_indicators(code) ——
--     于是一个不在字典里的指标写不进来,而水分不需要字典。
--   【界】min_value 与 / 或 max_value(至少一个),不小于 0;水分另有 ≤ 100。下界不高于上界。
--   【按物料】material_id 可空 = 这份合同的每一种物料;指了物料的那一行对那种物料优先于空的那一行(与配料计划抄品位规格同一个规矩)。
--     一份合同 × 物料 × 参数一行(NULLS NOT DISTINCT:两条"每一种物料"的同参数行也是重复)。
--   【冻结】与另外七张条款表同一套:写 action.contract_terms;合同生效中 / 有在等的生效申请 / 到期 / 终止时直连写按名拒
--     CONTRACT_TERMS_FROZEN(guard_contract_terms_frozen);挂接销售单那一刻随结算口径一起抄进 contract_document_terms.settlement_terms
--     的 quality_limits(link_document_to_contract),以后合同再改【不】回头判(Q26)。
--   【声明】contract_settlement_terms.quality_limit_basis:'none_agreed' = 声明了没有限;'per_parameter' = 有,行在本表;空 = V17 Not yet set。
--     卖方合同申请生效要它(contract_activation_missing),per_parameter 而本表没有行按名拒 QUALITY_LIMITS_NOT_FILED(SETTLE-1 ③ 那一条)。
--   【只有卖方】条款编辑器把这一段放在卖方那一侧(termSpecs SELL_ONLY,与计价 / 结算 / 精炼费 / 惩罚同一个处置);判定只读挂在销售单上的副本,
--     所以一行写在买方合同上的限永远不被判(Q28:没有买方的 V17)。
--   【没有金额】—— 没有遮蔽的列(Q39)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contract_quality_limits (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id  uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    -- 可空 = 这份合同的每一种物料
    material_id  uuid REFERENCES public.materials (id),
    parameter    text NOT NULL CHECK (btrim(parameter) = parameter AND parameter <> ''),
    -- 由 parameter 算出来:水分时为空,否则就是那个指标码 —— 外键把它钉在字典上
    indicator    text GENERATED ALWAYS AS (CASE WHEN parameter = 'moisture_pct' THEN NULL ELSE parameter END) STORED
                 REFERENCES public.assay_indicators (code),
    min_value    numeric CHECK (min_value IS NULL OR min_value >= 0),
    max_value    numeric CHECK (max_value IS NULL OR max_value >= 0),
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    CONSTRAINT contract_quality_limits_a_bound CHECK (min_value IS NOT NULL OR max_value IS NOT NULL),
    CONSTRAINT contract_quality_limits_bounds_order CHECK (min_value IS NULL OR max_value IS NULL OR min_value <= max_value),
    CONSTRAINT contract_quality_limits_moisture_pct CHECK (
        parameter <> 'moisture_pct' OR (COALESCE(min_value, 0) <= 100 AND COALESCE(max_value, 0) <= 100)),
    CONSTRAINT contract_quality_limits_one_per_parameter UNIQUE NULLS NOT DISTINCT (contract_id, material_id, parameter)
);

CREATE INDEX idx_contract_quality_limits_contract ON public.contract_quality_limits (contract_id);
CREATE INDEX contract_quality_limits_material_id_rel ON public.contract_quality_limits (material_id);
CREATE INDEX contract_quality_limits_indicator_rel ON public.contract_quality_limits (indicator);

COMMENT ON TABLE public.contract_quality_limits IS
    'MES-6b-1(V17;MES-6b Step 0 Q8 · Q25 · Q26):卖方合同的质量验收限 —— 参数(moisture_pct 或一个化验指标码)× 可选物料 × 上 / 下限。合同的第八张条款表:写 action.contract_terms,与另外七张一起冻结(CONTRACT_TERMS_FROZEN),挂接那一刻随结算口径抄进 contract_document_terms.settlement_terms.quality_limits,以后不回头判。有没有限由 contract_settlement_terms.quality_limit_basis 声明(none_agreed / per_parameter;空 = V17 Not yet set)。判定在 judge_quality_limits:一批产出批的化验遇上一张挂着这份合同的销售单上的预留时,越限就开一张 quality_limit 的不合格报告(→ 质量暂扣)。没有金额。';
COMMENT ON COLUMN public.contract_quality_limits.parameter IS
    'moisture_pct(化验那一列水分,%)或 assay_indicators 的一个码(residual_powder_pct · foil_purity_pct · d10_um · d50_um · d90_um)。单位跟着那个参数自己的单位走(% 或 µm)。';
COMMENT ON COLUMN public.contract_quality_limits.indicator IS
    '由 parameter 算出来的存储列:水分时为空,否则等于 parameter —— 它只是为了让外键把指标码钉在 assay_indicators 上(一对 CHECK / 外键,Step 0 Q8)。不要直接写它。';

ALTER TABLE public.contract_quality_limits ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract quality limits select by owner permission"
    ON public.contract_quality_limits AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND (SELECT has_permission('module.customers.view'::text)))
                       OR (c.supplier_id IS NOT NULL AND (SELECT has_permission('module.suppliers.view'::text))))));
-- 写条款只归 cco(action.contract_terms),与另外七张条款表同一条(ROLE-1 Batch 2b)。
CREATE POLICY "contract quality limits write by owner permission"
    ON public.contract_quality_limits AS PERMISSIVE FOR ALL TO authenticated
    USING ((SELECT has_permission('action.contract_terms'::text)))
    WITH CHECK ((SELECT has_permission('action.contract_terms'::text)));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.contract_quality_limits TO authenticated;
REVOKE ALL ON public.contract_quality_limits FROM anon;

-- SILENT-1 的语句级闸:被 RLS 挡下的改 / 删不许是一次"成功的空操作"(与另外七张条款表同一支)。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_quality_limits
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.contract_terms');

-- APR-8 的冻结:生效中、或挂着一张在等的生效申请时,直连写按名拒 CONTRACT_TERMS_FROZEN。属主路径放行。
CREATE TRIGGER trg_contract_quality_limits_frozen
    BEFORE INSERT OR UPDATE OR DELETE ON public.contract_quality_limits
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_terms_frozen();
