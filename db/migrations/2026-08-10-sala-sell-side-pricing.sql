-- SAL-A:卖方定价 —— 在 Tim 今天就在用的销售表单上,把定价模型接进系统
--
-- Doc 1 点名的痛:"不同的定价模型应当整合进本模块"。本切【不碰账】:
-- 算出一个价、填进表单;record_output_sale 照旧过账。规格:docs/sales-scoping.md §4/§8。
--
-- 【汇率的边翻面了 —— 全切最可能出的错】买方报价按 tt_sell 折算(我们买外币付钱);
-- 销售收钱进来,按 tt_buy。record_output_sale 本来就用 tt_buy,所以【过账是对的】——
-- 风险全在报价路径照抄 computeLineEstimate 的 tt_sell(它是最近的能跑的例子)。
-- 【边是共享换算的一个参数,不是两份实现】:换算就是 fx_rate_asof(ccy, date, side),
-- 买路径传 'tt_sell',本函数传 'tt_buy' —— 同一扇门,参数不同。fixture 38 A 臂
-- 用 tt_buy≠tt_sell 的日子钉住这一边,注入翻边即红。
--
-- 【三种模型,现货是预设不是分支】固定价 = 手填;公式价 = 金属含量 × 行情 × 应付
-- − 处理费 − 折扣;现货 = 【退化公式】(100% 应付、零处理费、零折扣)。现货在这里
-- 是【填出同一份 terms、走同一台引擎】—— 多一条算术分支就是第四个要保持正确的东西,
-- 而它会像修掉的那六个重复实现一样漂移。
--
-- 【出处继承 FIN-26,不重新发明】手填的 8.0000 挨着一个公式引用就会被读成算出来的 ——
-- 它在本项目上骗过一位仔细的读者。卖方从第一天起同样处理:computed 必带依据、
-- manual 明说、配对 CHECK 让"没有依据的 computed"不可表示。
--
-- 【本切不做,写在这里免得下一个人再撞一遍墙】(规格 §5/§8):
--   * 卖方的条款承诺(FIN-27 扩展)—— 属于合同那一切(SAL-D);
--   * 指数联动/远期作价期 —— 价格基准只会向【后】看(spot / N 日均),
--     "交割后一个月均价"是另一种结算流程;
--   * metal_prices 每金属只有【一条】序列 —— "LME 还是 SMM" 表达不了,出处里
--     只诚实地写它真正查过的序列(price_series: 'metal_prices'),不冒称任何指数;
--   * 预留/占用 —— Phase 2 的状态分层库存。
--
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. sales_records:出处两列 + 配对 CHECK(FIN-26 的形状,逐字)
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.sales_records
    ADD COLUMN price_source     text CHECK (price_source IN ('computed', 'manual')),
    ADD COLUMN price_provenance jsonb,
    ADD CONSTRAINT sales_records_provenance_pairing
        CHECK ((price_source = 'computed') = (price_provenance IS NOT NULL));

COMMENT ON COLUMN public.sales_records.price_source IS
    '售价的出处(SAL-A,FIN-26 的卖方半边):computed = 报价按钮产出(必带 price_provenance);manual = 手填。NULL = SAL-A 之前的行,当时没记 —— 【不回填猜测】,界面画"未知"。不要从公式在不在推断。';
COMMENT ON COLUMN public.sales_records.price_provenance IS
    'computed 行的重导出依据(SAL-A):逐金属行情与日期、金属含量、应付比例、处理费与折扣、汇率与 as-of 与【边】(tt_buy —— 收钱进来)、以及 price_series(当前恒为 metal_prices:每金属只有一条序列,LME/SMM 表达不了,出处只写真正查过的东西)。不能重导出的出处只是标签。';

-- ════════════════════════════════════════════════════════════════════════════
-- 2. 卖方报价:一台引擎,现货是预设
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.price_output_sale(
    p_output_batch_id uuid,
    p_formula_id      uuid,      -- NULL = 现货预设(100% 应付、零处理费、零折扣)
    p_currency        text,
    p_quantity        numeric,
    p_reference_date  date
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    -- 【收钱进来 → tt_buy】。改这一处等于把整个卖方报价换到错误的一边 ——
    -- fixture 38 A 臂在 tt_buy 与 tt_sell 不同的日子上钉着它。
    v_side       constant text := 'tt_buy';
    v_batch      record;
    v_metals     jsonb;
    v_terms      jsonb;
    v_mode       text;
    v_formula    record;
    v_result     jsonb;
    v_skipped    text[];
    v_usd_price  numeric;
    v_usd        record;
    v_doc        record;
    v_factor     numeric;
    v_unit_ccy   numeric;
BEGIN
    -- 报价就是价格信息(与 calculate_metal_price 同一道门)
    PERFORM require_permission('data.view_prices');

    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'QUANTITY_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;

    SELECT ob.id, ob.code INTO v_batch
    FROM output_batches ob WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_BATCH_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    -- 金属含量来自产出批自己的化验(output_batch_metals)—— 卖的是这批货的含量
    SELECT COALESCE(jsonb_agg(jsonb_build_object('metal', m.metal, 'content_pct', m.content_pct)), '[]'::jsonb)
    INTO v_metals
    FROM output_batch_metals m WHERE m.output_batch_id = p_output_batch_id;
    IF v_metals = '[]'::jsonb THEN
        RAISE EXCEPTION 'NO_METAL_CONTENT|%', v_batch.code;
    END IF;

    IF p_formula_id IS NOT NULL THEN
        v_mode := 'formula';
        SELECT id, code, direction, is_active, deleted_at INTO v_formula
        FROM pricing_formulas WHERE id = p_formula_id;
        IF NOT FOUND OR v_formula.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', p_formula_id;
        END IF;
        IF NOT v_formula.is_active THEN
            RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_formula.code;
        END IF;
        -- 买方公式不能拿来卖:方向是公式自己声明的商务属性
        IF v_formula.direction NOT IN ('sale', 'both') THEN
            RAISE EXCEPTION 'FORMULA_DIRECTION|%|%', v_formula.code, v_formula.direction;
        END IF;
        v_terms := pricing_terms_of_formula(p_formula_id);
    ELSE
        -- ── 现货预设:【填出同一份 terms,走同一台引擎】——————————————————————
        -- 100% 应付、零处理费、零折扣、spot 基准。这不是第四条算术分支:
        -- 下面这份 jsonb 与 pricing_terms_of_formula 的输出同构,进的是同一个
        -- calculate_metal_price_from_terms。fixture 38 B 臂断言它与显式的
        -- 100%/0/0 公式给出同一个数 —— 那正是"预设而非分支"的证明。
        v_mode := 'spot_preset';
        SELECT jsonb_build_object(
            'price_basis', 'spot',
            'average_days', NULL,
            'treatment_charge_usd_per_tonne', 0,
            'flat_discount_pct', 0,
            'payables', COALESCE(jsonb_object_agg(m.metal, 100), '{}'::jsonb))
        INTO v_terms
        FROM output_batch_metals m WHERE m.output_batch_id = p_output_batch_id;
    END IF;

    v_result := calculate_metal_price_from_terms(v_terms, v_metals, p_quantity, p_reference_date);

    -- 报价路径:缺行情即拒(quoting 侧的处置 —— 一份按零价卖出去的报价比停一下更坏;
    -- 分摊侧的"跳过继续"在 allocate_processing_costs,两边注释互指,不要统一)
    SELECT COALESCE(array_agg(x), ARRAY[]::text[]) INTO v_skipped
    FROM jsonb_array_elements_text(COALESCE(v_result->'skipped_metals', '[]'::jsonb)) x;
    IF array_length(v_skipped, 1) > 0 THEN
        RAISE EXCEPTION 'METAL_PRICE_MISSING|%|%', array_to_string(v_skipped, ','), p_reference_date;
    END IF;

    v_usd_price := (v_result->>'unit_price_usd_per_kg')::numeric;

    -- ── USD → 单据币种:与买路径同一扇门(fx_rate_asof),【边】不同 ————————————
    SELECT a.rate, a.as_of INTO v_usd FROM fx_rate_asof('USD', p_reference_date, v_side) a;
    IF v_usd.rate IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_MISSING|USD|%|%', p_reference_date, v_side;
    END IF;
    SELECT a.rate, a.as_of INTO v_doc FROM fx_rate_asof(p_currency, p_reference_date, v_side) a;
    IF v_doc.rate IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_MISSING|%|%|%', p_currency, p_reference_date, v_side;
    END IF;
    v_factor := v_usd.rate / v_doc.rate;
    v_unit_ccy := round(v_usd_price * v_factor, 4);

    RETURN jsonb_build_object(
        'unit_price_ccy', v_unit_ccy,
        'currency', p_currency,
        'quantity_kg', p_quantity,
        'breakdown', v_result,
        -- 出处:足以重导出这个数(FIN-26 的标准:重导不出的出处只是标签)。
        -- price_series 恒为 'metal_prices':每金属只有一条序列,不冒称 LME/SMM。
        'provenance', jsonb_build_object(
            'mode', v_mode,
            'formula_id', CASE WHEN p_formula_id IS NOT NULL THEN p_formula_id::text END,
            'formula_code', CASE WHEN p_formula_id IS NOT NULL THEN v_formula.code END,
            'terms', v_terms,
            'metals', v_metals,
            'metal_lines', v_result->'lines',
            'price_series', 'metal_prices',
            'quantity_kg', p_quantity,
            'reference_date', p_reference_date,
            'unit_price_usd_per_kg', v_usd_price,
            'fx', jsonb_build_object(
                'side', v_side,
                'usd_rate', v_usd.rate, 'usd_as_of', v_usd.as_of,
                'doc_rate', v_doc.rate, 'doc_as_of', v_doc.as_of,
                'factor', v_factor)
        )
    );
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. record_output_sale 收下出处(签名变了:DROP + CREATE,不留旧重载)
-- ════════════════════════════════════════════════════════════════════════════
DROP FUNCTION public.record_output_sale(uuid, numeric, numeric, text, numeric, uuid, date, text);

COMMIT;
