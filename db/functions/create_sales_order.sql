CREATE OR REPLACE FUNCTION public.create_sales_order(p_customer_id uuid, p_order_date date, p_currency text, p_fx_rate numeric, p_lines jsonb, p_notes text DEFAULT NULL::text, p_terms_text text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_code  text;
    v_id    uuid;
    v_line  jsonb;
    v_i     int := 0;
    v_n     int;
BEGIN
    PERFORM require_permission('module.sales.edit');

    -- 【订单日永不默认】物理事件日:补一个 CURRENT_DATE 会让"留空"比"填对"
    -- 更容易通过(AGENTS.md 的日期规矩,FIN-10 那一族的命名)。
    IF p_order_date IS NULL THEN
        RAISE EXCEPTION 'ORDER_DATE_REQUIRED';
    END IF;
    IF p_customer_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'SO_CREATE_CUSTOMER_INVALID|%', COALESCE(p_customer_id::text, '?');
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies WHERE code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- 【汇率没有默认值 —— FIN-35】假设出来的 1:1 在非本位币单据上永远是错的,
    -- 而且看起来完全正常。
    IF p_fx_rate IS NULL OR p_fx_rate <= 0 THEN
        RAISE EXCEPTION 'SO_CREATE_FX_INVALID|%', COALESCE(p_fx_rate::text, '?');
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'SO_CREATE_NO_LINES';
    END IF;

    v_code := next_sales_order_code(p_order_date);

    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate, notes, terms_text, created_by)
    VALUES (v_code, p_customer_id, p_order_date, p_currency, p_fx_rate,
            NULLIF(btrim(COALESCE(p_notes, '')), ''),
            NULLIF(btrim(COALESCE(p_terms_text, '')), ''), v_user)
    RETURNING id INTO v_id;

    -- 【逐行校验,并且【点名是第几行、哪一格】】一句"某一行不合法"等于让人
    -- 自己去数第几行 —— 表单上有二十个格子。
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_i := v_i + 1;
        IF NOT EXISTS (SELECT 1 FROM materials
                        WHERE id = NULLIF(v_line->>'material_id', '')::uuid AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SO_CREATE_LINE_INVALID|%|material', v_i;
        END IF;
        IF COALESCE((v_line->>'quantity')::numeric, 0) <= 0 THEN
            RAISE EXCEPTION 'SO_CREATE_LINE_INVALID|%|quantity', v_i;
        END IF;
        IF COALESCE((v_line->>'unit_price')::numeric, 0) <= 0 THEN
            RAISE EXCEPTION 'SO_CREATE_LINE_INVALID|%|unit_price', v_i;
        END IF;
        -- FIN-26 的配对:出处与依据要么都有、要么都没有。表侧的 CHECK 也管着,
        -- 但那条 CHECK 报的是约束名 —— 按名拒才说得出是第几行。
        IF (v_line ? 'price_source') <> (v_line ? 'price_provenance') THEN
            RAISE EXCEPTION 'SO_CREATE_LINE_INVALID|%|provenance', v_i;
        END IF;

        INSERT INTO sales_order_lines
            (sales_order_id, line_no, material_id, quantity, unit_price, price_source, price_provenance, notes)
        VALUES (v_id, v_i,
                (v_line->>'material_id')::uuid,
                (v_line->>'quantity')::numeric,
                (v_line->>'unit_price')::numeric,
                NULLIF(v_line->>'price_source', ''),
                CASE WHEN v_line ? 'price_provenance' THEN v_line->'price_provenance' END,
                NULLIF(btrim(COALESCE(v_line->>'notes', '')), ''));
    END LOOP;

    -- 【留痕与单据同一个事务】—— 这一行就是这整支迁移的起因。
    INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
    VALUES (v_id, 'created', v_code, v_user);

    -- 【断言,不是假设】三张表都写到了才算建成。将来有人给上面任何一段加一个
    -- 提前 RETURN,这里当场炸,而不是留下一张没有行、或者没有留痕的单。
    SELECT count(*) INTO v_n FROM sales_order_lines WHERE sales_order_id = v_id;
    IF v_n <> v_i OR v_i = 0 THEN
        RAISE EXCEPTION 'SO_CREATE_LINES_LOST|%|%', v_i, v_n;
    END IF;

    RETURN jsonb_build_object('id', v_id, 'code', v_code, 'lines', v_i);
END;
$function$

;
