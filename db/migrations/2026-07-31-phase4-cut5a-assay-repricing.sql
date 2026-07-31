-- db/migrations/2026-07-31-phase4-cut5a-assay-repricing.sql
-- Phase 4 cut 5a: assay results & assay-driven repricing (DB only).
--
-- 业务现实:货到在先,真实金属含量在后。先按估计/供应商申报含量【暂定】计价,
-- AP 就此成立;几天或几周后化验证书回来,按实际含量重算价格,差额调整欠款。
-- 本切补上:结构化的化验单据(assay_results)、化验 → 重算价格的链路
-- (apply_assay_result,走与手工计价完全相同的路径)、暂定/最终的区分
-- (inbound_batches.pricing_status),以及一个先修的记账错误(B1)。
--
-- Pieces:
--   B1. reprice_inbound_batch(内部共享体)—— 价差按"仍在库比例"拆 1200/5000;
--       set_inbound_unit_price 变成薄壳(校验语义、错误码、返回键全部保留)。
--   B2. inbound_batches + pricing_formula_id / pricing_status(回填保持诚实:
--       本切之前手工定的价是 provisional,不是 final)。
--   B3/B4. assay_results / assay_result_metals(化验单据 + 逐金属含量)。
--   B5. record_assay_result —— 只记录,不动价:记录与执行分开,结果先能被审阅。
--   B6. apply_assay_result / unapply_assay_result。
--   B7. 视图 batch_assay_status。

BEGIN;

-- ============================================================================
-- B1. 共享重计价体 + 在库比例拆账
-- ============================================================================
-- 【先修一个记账错误】旧 set_inbound_unit_price 把价差整额记 借1200/贷2000。
-- 这只在整批仍在库时正确:化验结果晚于收货、常常晚于投产 —— 批次的价值那时已经
-- 走到 1220(在制)甚至 5000(材料成本),再借 1200 等于凭空造出不存在的原料库存。
--
-- 处理:按重计价那一刻【仍在库的比例】拆分价差 ——
--     in_stock_ratio  = remaining_qty / quantity(quantity=0 防守;夹在 [0,1])
--     inventory_share = round(delta × ratio, 2)  → 1200 原料库存
--     cost_share      = delta − inventory_share  → 5000 材料成本
-- 已消耗部分的价值早已离开原料库存,后来的价格更正应该跟着价值去了的地方走;
-- 按剩余量比例分摊是标准的存货计价调整处理,对审计师可解释。
--
-- 【已知简化】不追消耗部分具体变成了哪些产出(那要重跑分摊);材料重计价之后
-- 要不要重跑 allocate_processing_costs,是操作员另行的决定,不在这里自动发生。
--
-- 共享方式:整个"锁行→校验→GUC 放行改价→price_history→拆账分录"的本体收进
-- reprice_inbound_batch;set_inbound_unit_price 只剩转发。apply_assay_result 走
-- 同一入口 —— 价差分录、价格史、拆账三件事不可能在两条路径上各长各样。
CREATE OR REPLACE FUNCTION public.reprice_inbound_batch(
    p_inbound_batch_id uuid,
    p_unit_price numeric,
    p_currency text DEFAULT 'USD',
    p_fx_rate numeric DEFAULT NULL,
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_old       numeric;
    v_deleted   timestamptz;
    v_qty       numeric;
    v_remaining numeric;
    v_code      text;
    v_fx        numeric;
    v_usd       numeric;
    v_delta     numeric;
    v_ratio     numeric;
    v_inv       numeric := 0;
    v_cost      numeric := 0;
    v_lines     jsonb;
    v_je        jsonb := NULL;
BEGIN
    SELECT unit_price, deleted_at, quantity, remaining_qty, code
    INTO v_old, v_deleted, v_qty, v_remaining, v_code
    FROM inbound_batches WHERE id = p_inbound_batch_id FOR UPDATE;
    IF NOT FOUND OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;
    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_currency = 'USD' THEN
        v_fx := 1;
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    v_usd := round(p_unit_price * v_fx, 4);  -- 单价 4 位小数,与 unit_cost_usd 精度一致

    -- GUC 放行本函数内的 unit_price 更新(guard_inbound_price_change),用毕即清,
    -- 免得同事务内后续的直改被误放行(同 movement_ctx 模式)。
    PERFORM set_config('evoltrya.price_ctx', 'set_inbound_unit_price', true);
    UPDATE inbound_batches
    SET unit_price = v_usd, updated_by = v_user, updated_at = now()
    WHERE id = p_inbound_batch_id;
    PERFORM set_config('evoltrya.price_ctx', '', true);

    INSERT INTO price_history (inbound_batch_id, old_unit_price, new_unit_price, currency, original_price, fx_rate, notes, created_by)
    VALUES (p_inbound_batch_id, v_old, v_usd, p_currency, p_unit_price, v_fx, p_notes, v_user);

    -- cut 2a:计价即入账 —— 整批数量 × 价差(负债在收货整批上成立,非剩余量)。
    -- 记于定价日 CURRENT_DATE(到货日尚无金额,刻意如此);USD 口径(原币在 price_history)。
    v_delta := round(v_qty * (v_usd - COALESCE(v_old, 0)), 2);
    v_ratio := CASE WHEN v_qty = 0 THEN 1
                    ELSE LEAST(1, GREATEST(0, v_remaining / v_qty)) END;

    IF v_delta <> 0 THEN
        -- 拆账(见文件头):在库份额进 1200,已消耗份额进 5000;贷方(负差时借方)恒 2000
        v_inv  := round(v_delta * v_ratio, 2);
        v_cost := round(v_delta - v_inv, 2);

        v_lines := '[]'::jsonb;
        IF abs(v_inv) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '1200',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', 'USD', 'amount_ccy', abs(v_inv),
                'line_memo', 'in-stock share');
        END IF;
        IF abs(v_cost) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '5000',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', 'USD', 'amount_ccy', abs(v_cost),
                'line_memo', 'consumed share');
        END IF;
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2000',
            'side', CASE WHEN v_delta > 0 THEN 'credit' ELSE 'debit' END,
            'currency', 'USD', 'amount_ccy', abs(v_delta));

        v_je := post_journal_entry(
            CURRENT_DATE,
            'Pricing ' || v_code,
            'purchase',
            p_inbound_batch_id,
            v_lines
        );
    END IF;

    RETURN jsonb_build_object(
        -- 旧返回键原样保留(既有调用方靠它们)
        'batch_id', p_inbound_batch_id,
        'unit_price_usd', v_usd,
        -- cut 5a 起的完整分解(界面与对账都要能逐项交代)
        'batch_code', v_code,
        'old_unit_price', v_old,
        'new_unit_price', v_usd,
        'price_delta_usd', v_delta,
        'in_stock_ratio', round(v_ratio, 4),
        'inventory_share_usd', v_inv,
        'cost_share_usd', v_cost,
        'journal_code', v_je->>'code'
    );
END;
$function$;

-- 薄壳:签名、错误语义、返回键全部不变(返回是旧键的超集)
CREATE OR REPLACE FUNCTION public.set_inbound_unit_price(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN reprice_inbound_batch(p_inbound_batch_id, p_unit_price, p_currency, p_fx_rate, p_notes);
END;
$function$;

-- ============================================================================
-- B2. inbound_batches:定价公式与定价状态
-- ============================================================================
ALTER TABLE public.inbound_batches
    ADD COLUMN pricing_formula_id uuid REFERENCES public.pricing_formulas (id),
    ADD COLUMN pricing_status text NOT NULL DEFAULT 'provisional'
        CHECK (pricing_status IN ('unpriced','provisional','final'));

-- 回填保持诚实:没价的是 unpriced;本切之前手工定的价没有化验背书,是 provisional
UPDATE public.inbound_batches
SET pricing_status = CASE WHEN unit_price IS NULL THEN 'unpriced' ELSE 'provisional' END;

-- ============================================================================
-- B3. assay_results:化验单据
-- is_final 区分正式证书与初检/部分读数;superseded_by 记录复验取代早先结果,
-- 链条保持可读。记录与执行分开(record ≠ apply)—— 结果先能被人审阅。
-- ============================================================================
CREATE TABLE public.assay_results (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code             text NOT NULL UNIQUE,  -- gapless 'ASY-YYYY-NNNN',record_assay_result 分配
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
CREATE POLICY "authenticated full access on assay_results"
    ON public.assay_results AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.next_assay_code(p_date date DEFAULT CURRENT_DATE)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('assay_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM assay_results
    WHERE code LIKE 'ASY-' || v_year::text || '-%';
    RETURN 'ASY-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$fn$;

-- ============================================================================
-- B4. assay_result_metals:逐金属含量
-- ============================================================================
CREATE TABLE public.assay_result_metals (
    assay_result_id uuid NOT NULL REFERENCES public.assay_results (id) ON DELETE CASCADE,
    metal           text NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    content_pct     numeric NOT NULL CHECK (content_pct >= 0 AND content_pct <= 100),
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (assay_result_id, metal)
);

ALTER TABLE public.assay_result_metals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on assay_result_metals"
    ON public.assay_result_metals AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- ============================================================================
-- B5. record_assay_result:只记录,不动价
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_assay_result(
    p_inbound_batch_id uuid,
    p_assay_date date,
    p_metals jsonb,
    p_lab_name text DEFAULT NULL,
    p_certificate_ref text DEFAULT NULL,
    p_sample_ref text DEFAULT NULL,
    p_is_final boolean DEFAULT true,
    p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_el    jsonb;
    v_metal text;
    v_pct   numeric;
    v_seen  text[] := ARRAY[]::text[];
    v_count integer := 0;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    IF p_assay_date IS NULL OR p_assay_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSAY_DATE_INVALID|%', COALESCE(p_assay_date::text, '?');
    END IF;
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    v_code := next_assay_code(p_assay_date);
    INSERT INTO assay_results (id, code, inbound_batch_id, assay_date, lab_name,
                               certificate_ref, sample_ref, is_final, notes, created_by, updated_by)
    VALUES (v_id, v_code, p_inbound_batch_id, p_assay_date, p_lab_name,
            p_certificate_ref, p_sample_ref, p_is_final, p_notes, v_user, v_user);

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
        v_pct := (v_el->>'content_pct')::numeric;
        IF v_pct IS NULL OR v_pct < 0 OR v_pct > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;
        INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
        VALUES (v_id, v_metal, v_pct);
        v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'assay_result_id', v_id,
        'code', v_code,
        'metal_count', v_count
    );
END;
$function$;

-- ============================================================================
-- B6. apply_assay_result / unapply_assay_result
-- ============================================================================
CREATE OR REPLACE FUNCTION public.apply_assay_result(
    p_assay_result_id uuid,
    p_pricing_formula_id uuid DEFAULT NULL,
    p_reference_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_assay    record;
    v_batch    record;
    v_formula  uuid;
    v_fcode    text;
    v_metals   jsonb;
    v_calc     jsonb;
    v_unit     numeric;
    v_rep      jsonb := NULL;
    v_priced   boolean := false;
    v_status   text;
    v_prior    uuid;
    v_note     text := NULL;
BEGIN
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    IF v_assay.applied_at IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
    END IF;

    SELECT * INTO v_batch FROM inbound_batches
    WHERE id = v_assay.inbound_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_assay.inbound_batch_id;
    END IF;

    -- 1. 批次含量 = 本化验的含量(删后重插)。分摊、估值、回收率读的都是
    --    inbound_batch_metals —— 它必须始终是"当前最可信的真相";化验行本身留作历史。
    DELETE FROM inbound_batch_metals WHERE inbound_batch_id = v_batch.id;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, created_by, updated_by)
    SELECT v_batch.id, arm.metal, arm.content_pct, v_user, v_user
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    SELECT jsonb_agg(jsonb_build_object('metal', arm.metal, 'content_pct', arm.content_pct))
    INTO v_metals
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    -- 2. 公式解析:入参 → 批次 → 采购单明细行 → 无
    v_formula := COALESCE(
        p_pricing_formula_id,
        v_batch.pricing_formula_id,
        (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
          WHERE pol.id = v_batch.purchase_order_line_id)
    );

    IF v_formula IS NOT NULL THEN
        -- 3. 与计价器同一 DB 函数算价,再走与手工计价【同一条】重计价路径
        --    (reprice_inbound_batch)—— 价差分录、price_history、1200/5000 拆账
        --    三件事只存在一份实现。参考日默认化验日:结算价随行情,行情看化验那天。
        v_calc := calculate_metal_price(v_formula, v_metals, v_batch.quantity,
                                        COALESCE(p_reference_date, v_assay.assay_date));
        v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
        SELECT code INTO v_fcode FROM pricing_formulas WHERE id = v_formula;

        IF v_unit > 0 THEN
            v_rep := reprice_inbound_batch(v_batch.id, v_unit, 'USD', NULL,
                                           'Assay ' || v_assay.code || ' applied');
            v_priced := true;
        ELSE
            -- 低品位料可能"不值它的处理费"(净值 ≤ 0)。负价不入价格机器 ——
            -- 含量照常落地,价格留给人决断。
            v_note := 'computed price not positive: ' || COALESCE(v_unit::text, '?');
        END IF;
    ELSE
        -- 4. 无公式可解:含量照常落地、化验照常标记已执行,价格不动 ——
        --    手工计价的采购本来就由人定价,这不是错误。
        v_note := 'no pricing formula resolved';
    END IF;

    -- 5. 批次的定价状态:只有真的重了价才谈得上 final
    v_status := CASE WHEN v_priced AND v_assay.is_final THEN 'final'
                     ELSE v_batch.pricing_status END;
    UPDATE inbound_batches
    SET pricing_formula_id = COALESCE(v_formula, pricing_formula_id),
        pricing_status = v_status,
        updated_by = v_user
    WHERE id = v_batch.id;

    -- 6. 取代链:此前已执行且未被取代的化验,superseded_by 指向本次
    -- code 作平局裁决:applied_at 在同一事务里可能相同(now() 冻结),
    -- 而编号无缝且单调 —— 排序必须确定
    SELECT id INTO v_prior FROM assay_results
    WHERE inbound_batch_id = v_batch.id AND id <> p_assay_result_id
      AND applied_at IS NOT NULL AND superseded_by IS NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_prior IS NOT NULL THEN
        UPDATE assay_results SET superseded_by = p_assay_result_id, updated_by = v_user
        WHERE id = v_prior;
    END IF;

    UPDATE assay_results
    SET applied_at = now(), applied_by = v_user, updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 完整分解:界面展示的、向供应商/审计师解释调整的,就是这一份 —— 每个数都留
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'priced', v_priced,
        'formula_code', v_fcode,
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'in_stock_ratio', v_rep->'in_stock_ratio',
        'inventory_share_usd', v_rep->'inventory_share_usd',
        'cost_share_usd', v_rep->'cost_share_usd',
        'journal_code', v_rep->'journal_code',
        'pricing_status', v_status,
        'note', v_note
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.unapply_assay_result(p_assay_result_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_assay  record;
    v_latest uuid;
BEGIN
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND OR v_assay.applied_at IS NULL THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 只许撤最近一次:链条中间抽走一环,superseded_by 的叙事就断了。
    -- code 作平局裁决(applied_at 同事务内可能相同,编号无缝单调)。
    SELECT id INTO v_latest FROM assay_results
    WHERE inbound_batch_id = v_assay.inbound_batch_id
      AND applied_at IS NOT NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_latest IS DISTINCT FROM p_assay_result_id THEN
        RAISE EXCEPTION 'NOT_LATEST_ASSAY|%', v_assay.code;
    END IF;

    UPDATE assay_results
    SET applied_at = NULL, applied_by = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' unapplied] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 被本次取代的上一份化验,链解开
    UPDATE assay_results SET superseded_by = NULL, updated_by = v_user
    WHERE superseded_by = p_assay_result_id;

    -- 【刻意不回价、不回含量】撤销"已执行"标记只是承认这份结果不再作数;
    -- 价格与含量退回到哪一版,是新化验或手工计价的显式动作 —— 静默回滚一个
    -- 已经过完账、可能已被分摊读走的状态,比留着它更危险。
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_assay.inbound_batch_id,
        'reverted_price', false
    );
END;
$function$;

-- ============================================================================
-- B7. batch_assay_status:批次页面板 + 未来"待化验"工作清单的一把查
-- ============================================================================
CREATE OR REPLACE VIEW public.batch_assay_status
WITH (security_invoker = on) AS
 SELECT ib.id AS inbound_batch_id,
    ib.code AS batch_code,
    sup.legal_name AS supplier_name,
    m.name AS material_name,
    ib.quantity,
    ib.unit,
    ib.unit_price,
    ib.pricing_status,
    ib.pricing_formula_id,
    pf.code AS formula_code,
    COALESCE(a.assay_count, 0::bigint) AS assay_count,
    a.latest_assay_id,
    a.latest_assay_code,
    a.latest_assay_date,
    COALESCE(a.latest_assay_applied, false) AS latest_assay_applied,
    COALESCE(a.has_unapplied_assay, false) AS has_unapplied_assay,
    ib.purchase_order_id,
    po.code AS po_code
   FROM inbound_batches ib
     JOIN suppliers sup ON sup.id = ib.supplier_id
     JOIN materials m ON m.id = ib.material_id
     LEFT JOIN pricing_formulas pf ON pf.id = ib.pricing_formula_id
     LEFT JOIN purchase_orders po ON po.id = ib.purchase_order_id
     LEFT JOIN LATERAL (
         SELECT count(*) AS assay_count,
                bool_or(ar.applied_at IS NULL) AS has_unapplied_assay,
                (array_agg(ar.id ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_id,
                (array_agg(ar.code ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_code,
                (array_agg(ar.assay_date ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_date,
                (array_agg(ar.applied_at IS NOT NULL ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_applied
           FROM assay_results ar
          WHERE ar.inbound_batch_id = ib.id AND ar.deleted_at IS NULL) a ON true
  WHERE ib.deleted_at IS NULL;

COMMIT;
