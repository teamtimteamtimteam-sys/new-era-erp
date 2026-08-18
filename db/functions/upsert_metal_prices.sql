CREATE OR REPLACE FUNCTION public.upsert_metal_prices(p_price_date date, p_prices jsonb, p_price_index text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_source_reference text DEFAULT NULL::text, p_quote_delayed boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
    PERFORM require_permission('module.pricing.edit');
    -- METAL-2:录入的是【哪个指数】的行情。NULL = 未声明(老序列),它是一个
    -- 可表示的状态而不是默认值 —— 界面上是一个必须选的下拉,而不是留空就当某个值。
    IF p_price_index IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM metal_price_indices WHERE code = p_price_index AND is_active) THEN
        RAISE EXCEPTION 'PRICE_INDEX_UNKNOWN|%', p_price_index;
    END IF;
    IF p_price_date IS NULL THEN
        RAISE EXCEPTION 'PRICE_DATE_REQUIRED';
    END IF;

    -- LME-1a:【出处必填,而且按名拒】p_source 有 DEFAULT NULL 只是为了不打断
    -- 既有调用方的参数写法 —— 它【不是】一个可以省略的参数,漏了就在这里停下。
    -- 表上那条 NOT NULL(已拿掉 DEFAULT)是兜底:它挡得住绕过本函数的直插,
    -- 但抛出来的是约束原文;这一句是给人看的那一版。
    IF p_source IS NULL OR btrim(p_source) = '' THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_REQUIRED';
    END IF;
    IF p_source NOT IN ('published_index','broker_quote','internal_estimate','unknown') THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_INVALID|%', p_source;
    END IF;
    -- 【unknown 不许用在新录入上】它是给 LME-1a 之前那些无从考证的历史行的。
    -- 允许新录入选 unknown,等于把这一列变回一句空话 —— 只是换了个词。
    IF p_source = 'unknown' THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_UNKNOWN_NOT_ALLOWED_FOR_NEW';
    END IF;
    -- 【published_index 必须说得出是哪一个】表上有同样的 CHECK;这一句先说人话。
    IF p_source = 'published_index' AND p_price_index IS NULL THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_INDEX_REQUIRED';
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
        INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, price_index, source,
                                  source_reference, quote_delayed, created_by, updated_by)
        VALUES (v_metal, v_price, p_price_date, p_price_index, p_source,
                nullif(btrim(coalesce(p_source_reference,'')), ''), p_quote_delayed, v_user, v_user)
        ON CONFLICT (metal, price_date, price_index) DO UPDATE
        SET price_usd_per_tonne = EXCLUDED.price_usd_per_tonne,
            source              = EXCLUDED.source,
            source_reference    = EXCLUDED.source_reference,
            quote_delayed       = EXCLUDED.quote_delayed,
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
        'price_index', p_price_index,
        'source', p_source,
        'inserted', v_inserted,
        'updated', v_updated,
        'skipped', v_skipped
    );
END;
$function$;
