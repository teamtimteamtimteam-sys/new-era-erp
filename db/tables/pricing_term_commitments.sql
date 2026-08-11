-- db/tables/pricing_term_commitments.sql
-- 承诺时抄下的结算条款(FIN-27)。【副本就是记录】—— 结算只读它,从不读活公式。
--
-- 【为什么是抄一份,而不是给公式加版本】这个仓库已经答过两次同一道题:
--   * apply_payment_term_template 把模板行抄到 purchase_order_payment_terms,
--     不留回指;
--   * FIN-26 把估算的依据冻结在采购行上,而不是回头解析公式。
-- 公式是可编辑的模板(界面上就是一个表单),而采购行上的 pricing_formula_id 是
-- 一份【关于将来怎么结算的承诺】。抄下来之后,模板此后被改、被停用、被软删,
-- 都碰不到已成交的交易 —— 不变性是【构造出来的】,不是靠守卫拦出来的。
--
-- 【承诺时刻】
--   * 采购行:create_purchase_order。它直接落 'confirmed'/'approved',而且全仓库
--     只有它写 purchase_order_lines(没有行编辑路径),所以下单即承诺;
--   * 进料批次:只有一种情形是它自己的承诺 —— 没有采购单的现场收货,在
--     apply_assay_result(p_pricing_formula_id => …) 里第一次指名公式的那一刻。
--     有采购单的批次不另立承诺,它按那条采购行的副本结算(resolve_pricing_commitment)。
--
-- 【存量引用没有副本,而且不回填】(FIN-27 D)把今天的公式抄到一张旧单上,记下的
-- 是它【现在】说的话,未必是当时谈的。编造的承诺比缺失的承诺更坏 —— 同 FIN-26 的
-- 灰色"出处未知"、processing_cost_entry_history 的空白前史。结算遇到"有公式引用、
-- 没有副本"会点名拒(PRICING_TERMS_NOT_COMMITTED),不悄悄退回去读活公式。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【受限访问列 / RESTRICTED-ACCESS COLUMNS】
--   treatment_charge_usd_per_tonne / flat_discount_pct —— 与 pricing_formulas
--   同口径,归 data.view_prices。只能经 pricing_term_commitments_masked 读取。
-- 【加列必改两处】列清单 SELECT 授权与 _masked 视图 —— 否则新列有写无读(FIN-6),
-- db/gate.py 的 colgrant 会当场点名。
-- ════════════════════════════════════════════════════════════════════════════
--
-- NOTE: introduced by db/migrations/2026-08-07-fin27-pricing-terms-commitment.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.pricing_term_commitments (
    id                             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 承诺挂在【被承诺的那条记录】上,二者其一(UNIQUE:一条记录只承诺一次)
    purchase_order_line_id         uuid UNIQUE REFERENCES public.purchase_order_lines (id),
    inbound_batch_id               uuid UNIQUE REFERENCES public.inbound_batches (id),
    -- 【抄下来的,不是指过去的】source_formula_id 【没有外键、永不 JOIN 回去】:
    -- 它记录副本抄自哪张模板,与 apply_payment_term_template 不留回指同一个意思。
    -- code/name 一并抄成文本 —— 公式改名或软删都不该动到已成交的这份记录。
    source_formula_id              uuid,
    source_formula_code            text NOT NULL,
    source_formula_name            text,
    -- 条款本体(与 pricing_formulas 同名同义,便于逐字对照)
    price_basis                    text NOT NULL
                                   CHECK (price_basis IN ('spot','average')),
    average_days                   integer CHECK (average_days IS NULL OR average_days BETWEEN 1 AND 365),
    treatment_charge_usd_per_tonne numeric NOT NULL   -- RESTRICTED
                                   CHECK (treatment_charge_usd_per_tonne >= 0),
    flat_discount_pct              numeric NOT NULL   -- RESTRICTED
                                   CHECK (flat_discount_pct >= 0 AND flat_discount_pct <= 100),
    committed_at                   timestamptz NOT NULL DEFAULT now(),
    committed_by                   uuid DEFAULT auth.uid(),
    CONSTRAINT pricing_term_commitments_one_target CHECK (
        num_nonnulls(purchase_order_line_id, inbound_batch_id) = 1
    ),
    CONSTRAINT pricing_term_commitments_average_days_required CHECK (
        price_basis <> 'average' OR average_days IS NOT NULL
    ),
    -- ── METAL-2 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 成交那一刻抄下的指数。公式事后改指数,这一单仍按当初谈的那个结算。
    price_index text REFERENCES public.metal_price_indices (code)
);

COMMENT ON TABLE public.pricing_term_commitments IS
    '承诺时抄下的结算条款(FIN-27)。副本就是记录 —— 结算只读它,从不读活公式。';
COMMENT ON COLUMN public.pricing_term_commitments.source_formula_id IS
    '抄自哪张公式。【记录,不是引用】:没有外键,任何代码路径都不许 JOIN 回 pricing_formulas 去取条款。';

-- 副本不可变(形状取自 employment_history):写错了不靠改历史,靠重新承诺 ——
-- 而"重新承诺"是一次商务动作,不能由一次 UPDATE 悄悄完成。
-- 守卫函数在 db/functions/guard_pricing_commitment_immutable.sql。
CREATE TRIGGER trg_pricing_term_commitments_immutable
    BEFORE UPDATE OR DELETE ON public.pricing_term_commitments
    FOR EACH ROW EXECUTE FUNCTION public.guard_pricing_commitment_immutable();

ALTER TABLE public.pricing_term_commitments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pricing_term_commitments select by permission"
    ON public.pricing_term_commitments
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text)
        OR has_permission('module.inbound.view'::text));

-- 写入只经函数(commit_pricing_terms,DEFINER),所以没有 INSERT 策略 ——
-- 承诺不是能手写的东西。

-- 字段级遮蔽(cut 2b 的规矩):表级 SELECT 授权【蕴含所有列】,所以先整表收回,
-- 再把非敏感列逐列授回。敏感列只能经 pricing_term_commitments_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.pricing_term_commitments FROM authenticated, anon;
GRANT SELECT (id, purchase_order_line_id, inbound_batch_id, source_formula_id,
              source_formula_code, source_formula_name, price_basis, average_days,
              committed_at, committed_by, price_index)
    ON public.pricing_term_commitments TO authenticated;

-- METAL-2:成交时抄下的指数 —— 可读一类(与 price_basis 同级)。
COMMENT ON COLUMN public.pricing_term_commitments.price_index IS
    'METAL-2:成交那一刻抄下的指数(FIN-27)。公式事后改指数,这一单仍按当初谈的那个结算。';
