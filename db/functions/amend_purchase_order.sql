CREATE OR REPLACE FUNCTION public.amend_purchase_order(p_purchase_order_id uuid, p_reason text, p_header jsonb DEFAULT NULL::jsonb, p_lines jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_po       record;
    v_el       jsonb;
    v_line_id  uuid;
    v_qty      numeric;
    v_price    numeric;
    v_new_date date;
    v_fx       numeric;
    v_total    numeric;
    v_plan_fixed numeric;
    v_plan_pct   numeric;
    v_changed  integer := 0;
BEGIN
    PERFORM require_permission('module.purchasing.edit');

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        -- 【理由必填】一次改动没有理由,历史上就是一行"数字变了"而没有"为什么"。
        RAISE EXCEPTION 'PO_AMEND_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_po FROM purchase_orders
     WHERE id = p_purchase_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;

    -- 【已结束 / 已作废的单不能改】先 reopen,让状态变化成为一次有记录的动作,
    -- 而不是修改的副作用。
    IF v_po.status IN ('closed','cancelled') THEN
        RAISE EXCEPTION 'PO_NOT_AMENDABLE|%|%', v_po.code, v_po.status;
    END IF;

    -- 理由传给留痕触发器(触发器读不到函数参数)
    PERFORM set_config('evoltrya.amend_reason', btrim(p_reason), true);
    PERFORM set_config('evoltrya.po_amend_ctx', '1', true);

    -- ── 表头 ────────────────────────────────────────────────────────────────
    IF p_header IS NOT NULL AND jsonb_typeof(p_header) = 'object' THEN
        v_new_date := COALESCE((p_header->>'order_date')::date, v_po.order_date);
        -- 【汇率从不由调用方递入】改单据日就要重取牌价:缺牌价即拒绝、绝不编一个。
        -- 采购是我们买外币 → tt_sell。本位币恒 1(定义,不是兜底)。
        IF v_new_date IS DISTINCT FROM v_po.order_date THEN
            IF v_po.currency = base_currency_code() THEN
                v_fx := 1;
            ELSE
                v_fx := fx_rate_for(v_po.currency, v_new_date, 'tt_sell');
            END IF;
        ELSE
            v_fx := v_po.fx_rate;
        END IF;

        UPDATE purchase_orders SET
            order_date = v_new_date,
            expected_delivery_date = CASE WHEN p_header ? 'expected_delivery_date'
                THEN (p_header->>'expected_delivery_date')::date ELSE expected_delivery_date END,
            incoterm = CASE WHEN p_header ? 'incoterm' THEN p_header->>'incoterm' ELSE incoterm END,
            terms_text = CASE WHEN p_header ? 'terms_text' THEN p_header->>'terms_text' ELSE terms_text END,
            notes = CASE WHEN p_header ? 'notes' THEN p_header->>'notes' ELSE notes END,
            fx_rate = v_fx,
            updated_by = v_user
        WHERE id = p_purchase_order_id;
    END IF;

    -- ── 明细 ────────────────────────────────────────────────────────────────
    IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
        LOOP
            v_line_id := NULLIF(v_el->>'id', '')::uuid;

            IF COALESCE((v_el->>'remove')::boolean, false) THEN
                IF v_line_id IS NULL THEN
                    RAISE EXCEPTION 'PO_LINE_REMOVE_NEEDS_ID';
                END IF;
                -- 收过货的行删不掉 —— 守卫触发器点名拒(货真的到了,单据上却没有出处)
                DELETE FROM purchase_order_lines
                 WHERE id = v_line_id AND purchase_order_id = p_purchase_order_id;
                v_changed := v_changed + 1;
                CONTINUE;
            END IF;

            v_qty := (v_el->>'quantity')::numeric;
            IF v_qty IS NULL OR v_qty <= 0 THEN
                RAISE EXCEPTION 'PO_LINE_QUANTITY_INVALID|%', COALESCE(v_el->>'line_no', '?');
            END IF;
            v_price := NULLIF(v_el->>'estimated_unit_price', '')::numeric;

            IF v_line_id IS NULL THEN
                -- 新增行:与建单同口径(金额 = 数量 × 单价,无价则 0)
                -- EQP-1a:改单也能加设备行 —— 恰一非空,与建单同一句话
                IF num_nonnulls((v_el->>'material_id')::uuid, (v_el->>'asset_id')::uuid) <> 1 THEN
                    RAISE EXCEPTION 'PO_LINE_KIND_INVALID|%', COALESCE(v_el->>'line_no', '?')
                      USING HINT = '一行要么订材料、要么订一台已建卡的设备,不能都给、也不能都不给';
                END IF;
                IF (v_el->>'asset_id') IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM fixed_assets WHERE id = (v_el->>'asset_id')::uuid
                ) THEN
                    RAISE EXCEPTION 'ASSET_NOT_FOUND|%', v_el->>'asset_id';
                END IF;
                INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, asset_id,
                    quantity, unit, estimated_unit_price, estimated_amount_ccy, notes, created_by)
                VALUES (p_purchase_order_id,
                    COALESCE((v_el->>'line_no')::integer,
                        (SELECT COALESCE(MAX(line_no), 0) + 1 FROM purchase_order_lines
                          WHERE purchase_order_id = p_purchase_order_id)),
                    (v_el->>'material_id')::uuid, (v_el->>'asset_id')::uuid,
                    v_qty, COALESCE(v_el->>'unit', 'kg'),
                    v_price, round(v_qty * COALESCE(v_price, 0), 2), v_el->>'notes', v_user);
            ELSE
                -- 【已收下限由触发器把关】砍到已收之下 → PO_LINE_BELOW_RECEIVED
                UPDATE purchase_order_lines SET
                    quantity = v_qty,
                    unit = COALESCE(v_el->>'unit', unit),
                    estimated_unit_price = CASE WHEN v_el ? 'estimated_unit_price'
                        THEN v_price ELSE estimated_unit_price END,
                    estimated_amount_ccy = round(v_qty * COALESCE(
                        CASE WHEN v_el ? 'estimated_unit_price' THEN v_price
                             ELSE estimated_unit_price END, 0), 2)
                WHERE id = v_line_id AND purchase_order_id = p_purchase_order_id;
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', v_line_id;
                END IF;
            END IF;
            v_changed := v_changed + 1;
        END LOOP;
    END IF;

    -- ── 总额:与明细【同一条语句】算完 ───────────────────────────────────────
    -- 【顺序就是要点】这一列是 APR-2 作废触发器盯着的东西。若先改行、再另起一条
    -- 语句写总额,触发器判断时依据的总额与产生它的那批行已经不是一回事 ——
    -- 那会产生一个看起来完全正常、却基于陈旧数字的审批决定。
    UPDATE purchase_orders po SET
        estimated_total_ccy = COALESCE(s.total, 0),
        updated_by = v_user
    FROM (SELECT COALESCE(SUM(estimated_amount_ccy), 0) AS total
            FROM purchase_order_lines WHERE purchase_order_id = p_purchase_order_id) s
    WHERE po.id = p_purchase_order_id;

    SELECT estimated_total_ccy INTO v_total FROM purchase_orders WHERE id = p_purchase_order_id;

    -- ── 付款计划:定额腿必须仍然加得上 ───────────────────────────────────────
    SELECT COALESCE(SUM(fixed_amount_ccy), 0), COALESCE(SUM(percentage), 0)
      INTO v_plan_fixed, v_plan_pct
      FROM purchase_order_payment_terms WHERE purchase_order_id = p_purchase_order_id;

    IF v_plan_fixed > 0 THEN
        -- 【定额腿在场:拒绝,不缩放】一条定额腿之所以是定额,正因为有人谈的是一个
        -- 数字而不是一个比例。替它按比例缩放,就是系统替操作员重新谈了一次条款,
        -- 而没有任何人被告知(与调高信用额度让告警安静同族)。
        -- 报出三个数:订单额、计划额、差额 —— 补救归操作员,而两条路都是有记录的动作。
        DECLARE
            v_plan_total numeric :=
                v_plan_fixed + round(v_total * v_plan_pct / 100.0, 2);
        BEGIN
            IF round(v_plan_total, 2) <> round(v_total, 2) THEN
                RAISE EXCEPTION 'PO_PLAN_FIXED_MISMATCH|%|%|%',
                    round(v_total, 2), round(v_plan_total, 2),
                    round(v_plan_total - v_total, 2);
            END IF;
        END;
    END IF;
    -- 【比例计划不在此列,而且这不是遗漏】百分比的意思就是"订单的这一份",
    -- 它按构造跟着总额走;定额的意思是"这么多钱",只有它需要被拦住。

    PERFORM set_config('evoltrya.po_amend_ctx', '', true);
    PERFORM set_config('evoltrya.amend_reason', '', true);

    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'lines_changed', v_changed,
        'estimated_total_ccy', v_total,
        'approval_status', (SELECT approval_status FROM purchase_orders WHERE id = p_purchase_order_id));
END;
$function$

