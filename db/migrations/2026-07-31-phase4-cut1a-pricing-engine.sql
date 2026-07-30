-- db/migrations/2026-07-31-phase4-cut1a-pricing-engine.sql
-- Phase 4 cut 1a: metal-content pricing engine (DB only).
--
-- DOMAIN: 再生料的价格是【算出来的】,不是报出来的:
--   price = Σ(quantity × content% × payable% × market price) − treatment charge − flat discount
-- payable%(可付比例,通常 60~80%)是核心商务变量,按交易对手谈定。
-- 一张 pricing_formula 就是一个交易对手谈定条款的存档 —— 不必每次重敲,
-- 结算时还能逐行摊开给对方看。
--
-- Pieces:
--   B1. pricing_formulas(无缝编号 'PF-YYYY-NNNN')
--   B2. pricing_formula_metals(每金属 payable%)
--   B3. calculate_metal_price() —— 定价计算,返回完整的逐行明细
--   B4. upsert_metal_prices() —— 每日行情批量录入

BEGIN;

-- ============================================================================
-- B1. pricing_formulas
-- ============================================================================
CREATE TABLE public.pricing_formulas (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                        text NOT NULL UNIQUE,  -- gapless 'PF-YYYY-NNNN',由下方触发器分配
    name                        text NOT NULL,
    direction                   text NOT NULL DEFAULT 'both'
                                CHECK (direction IN ('purchase','sale','both')),
    price_basis                 text NOT NULL DEFAULT 'spot'
                                CHECK (price_basis IN ('spot','average')),
    average_days                integer CHECK (average_days IS NULL OR average_days BETWEEN 1 AND 365),
    treatment_charge_usd_per_tonne numeric NOT NULL DEFAULT 0
                                CHECK (treatment_charge_usd_per_tonne >= 0),
    flat_discount_pct           numeric NOT NULL DEFAULT 0
                                CHECK (flat_discount_pct >= 0 AND flat_discount_pct <= 100),
    -- 交易对手绑定:只是后续切次里"默认带出哪张公式"的便利,不是限制 ——
    -- 任何公式都可以套用到任何一笔交易上。
    supplier_id                 uuid REFERENCES public.suppliers (id),
    customer_id                 uuid REFERENCES public.customers (id),
    notes                       text,
    is_active                   boolean NOT NULL DEFAULT true,
    deleted_at                  timestamptz,
    created_at                  timestamptz NOT NULL DEFAULT now(),
    created_by                  uuid DEFAULT auth.uid(),
    updated_at                  timestamptz NOT NULL DEFAULT now(),
    updated_by                  uuid DEFAULT auth.uid(),
    -- 均价基准必须给出天数
    CONSTRAINT pricing_formulas_average_days_required CHECK (
        price_basis <> 'average' OR average_days IS NOT NULL
    ),
    -- 通用公式(两者皆空)或绑定单一交易对手,不能同时绑供应商与客户
    CONSTRAINT pricing_formulas_one_counterparty CHECK (
        num_nonnulls(supplier_id, customer_id) <= 1
    )
);

CREATE INDEX idx_pricing_formulas_supplier ON public.pricing_formulas (supplier_id);
CREATE INDEX idx_pricing_formulas_customer ON public.pricing_formulas (customer_id);

-- 无缝编号:咨询锁串行化"取当年最大号+1"(同 JE/收付款/开支/对账单手法);
-- 回滚即释放号码。做成 helper + BEFORE INSERT 触发器 —— 本切没有建档 RPC,
-- UI 直接 INSERT 时不必自己算号。
CREATE FUNCTION public.next_pricing_formula_code(p_date date DEFAULT CURRENT_DATE)
RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('pricing_formula_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM pricing_formulas
    WHERE code LIKE 'PF-' || v_year::text || '-%';
    RETURN 'PF-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

CREATE OR REPLACE FUNCTION public.assign_pricing_formula_code()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := next_pricing_formula_code(CURRENT_DATE);
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_pricing_formulas_code
    BEFORE INSERT ON public.pricing_formulas
    FOR EACH ROW EXECUTE FUNCTION public.assign_pricing_formula_code();

CREATE TRIGGER trg_pricing_formulas_updated_at
    BEFORE UPDATE ON public.pricing_formulas
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.pricing_formulas ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on pricing_formulas"
    ON public.pricing_formulas AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================================
-- B2. pricing_formula_metals
-- 【不在本表里的金属完全不计价(payable 0)】—— 沉默即"不付钱",
-- calculate_metal_price 会把这类金属列进 unpaid_metals 提醒调用方。
-- ============================================================================
CREATE TABLE public.pricing_formula_metals (
    formula_id  uuid NOT NULL REFERENCES public.pricing_formulas (id) ON DELETE CASCADE,
    metal       text NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    payable_pct numeric NOT NULL CHECK (payable_pct >= 0 AND payable_pct <= 100),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid DEFAULT auth.uid(),
    PRIMARY KEY (formula_id, metal)
);

CREATE TRIGGER trg_pricing_formula_metals_updated_at
    BEFORE UPDATE ON public.pricing_formula_metals
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.pricing_formula_metals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on pricing_formula_metals"
    ON public.pricing_formula_metals AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================================
-- B3. calculate_metal_price
-- 返回值就是 UI 展示、以及给交易对手出结算单据的原始素材 —— 每一个中间量都留着。
-- ============================================================================
CREATE FUNCTION public.calculate_metal_price(
    p_formula_id     uuid,
    p_metals         jsonb,
    p_quantity_kg    numeric,
    p_reference_date date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_f            pricing_formulas%ROWTYPE;
    v_ref          date := COALESCE(p_reference_date, CURRENT_DATE);
    v_el           jsonb;
    v_metal        text;
    v_content      numeric;
    v_seen         text[] := ARRAY[]::text[];
    v_payable      numeric;
    v_has_terms    boolean;
    v_price        numeric;
    v_price_date   date;
    v_from         date;
    v_to           date;
    v_contained    numeric;
    v_payable_kg   numeric;
    v_value        numeric;
    v_lines        jsonb := '[]'::jsonb;
    v_skipped      text[] := ARRAY[]::text[];
    v_unpaid       text[] := ARRAY[]::text[];
    v_gross        numeric := 0;
    v_treatment    numeric;
    v_discount     numeric;
    v_net          numeric;
    v_unit         numeric;
BEGIN
    -- 1. 公式
    SELECT * INTO v_f FROM pricing_formulas
    WHERE id = p_formula_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', COALESCE(p_formula_id::text, '?');
    END IF;
    IF NOT v_f.is_active THEN
        RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_f.code;
    END IF;

    -- 2. 数量
    IF p_quantity_kg IS NULL OR p_quantity_kg <= 0 THEN
        RAISE EXCEPTION 'QUANTITY_INVALID';
    END IF;

    -- 3. 金属清单
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        IF v_metal IS NULL OR v_metal NOT IN ('ni','co','li','mn','cu','al','fe') THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;

        v_content := (v_el->>'content_pct')::numeric;
        IF v_content IS NULL OR v_content < 0 OR v_content > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;

        -- 4. 商务条款:公式里没有这个金属 = 完全不计价(payable 0),记入 unpaid_metals。
        --    注意与 skipped 的区别:unpaid 是"没谈价",skipped 是"没行情"。
        SELECT pfm.payable_pct INTO v_payable
        FROM pricing_formula_metals pfm
        WHERE pfm.formula_id = p_formula_id AND pfm.metal = v_metal;
        v_has_terms := FOUND;
        IF NOT v_has_terms THEN
            v_payable := 0;
            v_unpaid := v_unpaid || v_metal;
        END IF;

        -- 5. 行情:spot 取参考日之前最近一条;average 取窗口内均值(窗口内无行 → NULL)。
        v_price := NULL; v_price_date := NULL; v_from := NULL; v_to := NULL;
        IF v_f.price_basis = 'spot' THEN
            SELECT mp.price_usd_per_tonne, mp.price_date
            INTO v_price, v_price_date
            FROM metal_prices mp
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL AND mp.price_date <= v_ref
            ORDER BY mp.price_date DESC
            LIMIT 1;
        ELSE
            -- price_from / price_to 报【实际参与均值的行】的日期范围,而不是名义窗口 ——
            -- 结算单据上要能看出这个均价到底由哪几天的行情撑起来。
            SELECT avg(mp.price_usd_per_tonne), min(mp.price_date), max(mp.price_date)
            INTO v_price, v_from, v_to
            FROM metal_prices mp
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL
              AND mp.price_date BETWEEN (v_ref - (v_f.average_days - 1)) AND v_ref;
        END IF;

        -- 无可用行情 → 跳过(贡献 0),记入 skipped_metals;沿用 allocate_processing_costs
        -- 的先例:缺行情从来不是硬错误。
        IF v_price IS NULL THEN
            v_skipped := v_skipped || v_metal;
        END IF;

        -- 6. 逐行数量与金额
        v_contained  := round(p_quantity_kg * v_content / 100.0, 4);
        v_payable_kg := round(v_contained * v_payable / 100.0, 4);
        v_value      := CASE WHEN v_price IS NULL THEN 0
                             ELSE round(v_payable_kg / 1000.0 * v_price, 2) END;
        v_gross := v_gross + v_value;

        -- 缺行情/未计价的金属同样出现在 lines 里(金额 0、价格 NULL)——
        -- 结算单据要能逐项交代,不能让它们凭空消失。
        v_lines := v_lines || jsonb_build_object(
            'metal', v_metal,
            'content_pct', v_content,
            'payable_pct', v_payable,
            'contained_kg', v_contained,
            'payable_kg', v_payable_kg,
            'price_usd_per_tonne', v_price,
            'price_date', v_price_date,
            'price_from', v_from,
            'price_to', v_to,
            'metal_value_usd', v_value
        );
    END LOOP;

    -- 7. 汇总
    v_gross     := round(v_gross, 2);
    v_treatment := round(p_quantity_kg / 1000.0 * v_f.treatment_charge_usd_per_tonne, 2);
    v_discount  := round(v_gross * v_f.flat_discount_pct / 100.0, 2);
    v_net       := round(v_gross - v_treatment - v_discount, 2);
    v_unit      := round(v_net / p_quantity_kg, 4);

    RETURN jsonb_build_object(
        'formula_id', v_f.id,
        'formula_code', v_f.code,
        'formula_name', v_f.name,
        'price_basis', v_f.price_basis,
        'average_days', v_f.average_days,
        'reference_date', v_ref,
        'quantity_kg', p_quantity_kg,
        'lines', v_lines,
        'gross_value_usd', v_gross,
        'treatment_usd', v_treatment,
        'discount_usd', v_discount,
        'net_value_usd', v_net,
        'unit_price_usd_per_kg', v_unit,
        -- 低品位料确实可能"不值它的处理费";照实返回,由调用方决定接不接这单。
        'negative_value', (v_net < 0),
        'skipped_metals', to_jsonb(v_skipped),
        'unpaid_metals', to_jsonb(v_unpaid)
    );
END;
$function$;

-- ============================================================================
-- B4. upsert_metal_prices —— 每日行情批量录入
-- ============================================================================
CREATE FUNCTION public.upsert_metal_prices(p_price_date date, p_prices jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_el       jsonb;
    v_metal    text;
    v_raw      text;
    v_price    numeric;
    v_inserted integer := 0;
    v_updated  integer := 0;
    v_skipped  integer := 0;
    v_was_ins  boolean;
BEGIN
    IF p_price_date IS NULL THEN
        RAISE EXCEPTION 'PRICE_DATE_REQUIRED';
    END IF;
    IF p_prices IS NULL OR jsonb_typeof(p_prices) <> 'array' THEN
        RAISE EXCEPTION 'NO_PRICES';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_prices)
    LOOP
        v_metal := v_el->>'metal';
        IF v_metal IS NULL OR v_metal NOT IN ('ni','co','li','mn','cu','al','fe') THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;

        -- 空值跳过而不是报错:UI 的每日录入表单常常只填了其中几个金属。
        v_raw := v_el->>'price_usd_per_tonne';
        IF v_raw IS NULL OR btrim(v_raw) = '' THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        v_price := v_raw::numeric;
        IF v_price IS NULL OR v_price <= 0 THEN
            RAISE EXCEPTION 'PRICE_INVALID|%|%', v_metal, v_raw;
        END IF;

        -- (metal, price_date) 唯一。软删的行也占着这个位置 —— 撞上就顺手复活它
        -- (deleted_at = NULL)并写入新价,这两种情形都算 updated。
        INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, created_by, updated_by)
        VALUES (v_metal, v_price, p_price_date, 'manual', v_user, v_user)
        ON CONFLICT (metal, price_date) DO UPDATE
        SET price_usd_per_tonne = EXCLUDED.price_usd_per_tonne,
            source              = EXCLUDED.source,
            deleted_at          = NULL,
            updated_by          = v_user
        RETURNING (xmax = 0) INTO v_was_ins;

        IF v_was_ins THEN
            v_inserted := v_inserted + 1;
        ELSE
            v_updated := v_updated + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'price_date', p_price_date,
        'inserted', v_inserted,
        'updated', v_updated,
        'skipped', v_skipped
    );
END;
$function$;

COMMIT;
