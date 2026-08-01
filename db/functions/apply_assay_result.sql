CREATE OR REPLACE FUNCTION public.apply_assay_result(p_assay_result_id uuid, p_pricing_formula_id uuid DEFAULT NULL::uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
    PERFORM require_permission('module.inbound.edit');
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
        v_calc := calculate_metal_price_internal(v_formula, v_metals, v_batch.quantity,
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