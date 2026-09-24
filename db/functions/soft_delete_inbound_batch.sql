CREATE OR REPLACE FUNCTION public.soft_delete_inbound_batch(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_code text;
    v_open numeric;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        -- 【理由必填,而且拒绝要按名】注销一批料是一次真实的物理事件
        -- (它会写一条 writeoff 流水)。没有理由的注销,事后没有人答得出为什么。
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|inbound_batches|%',
            COALESCE((SELECT code FROM inbound_batches WHERE id = p_batch_id), '?');
    END IF;

    SELECT code INTO v_code FROM inbound_batches
     WHERE id = p_batch_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- AP-RECON-1(Tim AP-RECON-0 Q2):【还欠着供应商钱的已计价批次,不许注销】
    --   注销只写一条 writeoff 流水(借 5200 / 贷 1200)—— 存货拿走了,那笔计价分录记下的
    --   【应付】却原样留在 2000 上。而每一个应付读者(ap_open_items、ap_aging_asof、
    --   record_payment_internal)都过滤 deleted_at IS NULL:于是那笔债从清单上消失、
    --   付款也核销不进去,只剩手工分录一条路。IN-2026-0154 的 4,032.00 就是这样来的
    --   (测试数据,不修,记在 known-wrong-until-cutover)。
    --   欠款 = 数量×单价 − 已过账付款的核销 − 预付冲抵 —— 与 ap_open_items 进料支同一条算术。
    --   【读基表,不读 ap_open_items】本函数的门是 module.inbound.edit;那张视图对没有
    --   finance.view 的读者是 0 行,读它会让一个仓库账号的"欠款为 0"成为一句假话,于是放行。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT round(round(ib.quantity * ib.unit_price, 2)
                 - COALESCE((SELECT sum(pa.allocated_ccy)
                               FROM payment_allocations pa
                               JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                              WHERE pa.inbound_batch_id = ib.id), 0)
                 - COALESCE((SELECT sum(ppa.amount_base)
                               FROM prepayment_applications ppa
                              WHERE ppa.inbound_batch_id = ib.id), 0), 2)
      INTO v_open
      FROM inbound_batches ib
     WHERE ib.id = p_batch_id AND ib.unit_price IS NOT NULL;
    IF COALESCE(v_open, 0) > 0 THEN
        RAISE EXCEPTION 'INBOUND_HAS_OPEN_PAYABLE|%|%', v_code, v_open
          USING HINT = '这批货的计价还欠着供应商这笔钱(它在应付 2000 上)—— 注销会让它从应付清单上消失、再也付不进来。先付清,或先把价格更正过来;实物损失不是注销单据的理由';
    END IF;

    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE inbound_batches
       SET deleted_at = now(), deleted_by = v_user, delete_reason = btrim(p_reason),
           updated_by = v_user, updated_at = now()
     WHERE id = p_batch_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);

    -- ── COD-1:注销掉的料【不是被处理掉的】────────────────────────────────
    -- 实测:线上 11 张 remaining_qty = 0 的进料批里 8 张是这一类。
    -- 一张已签发的证书在这里作废 —— 它说的是"我们处理了你的料",而这票货被报废了。
    PERFORM refresh_cod_for_batch(p_batch_id);

    RETURN jsonb_build_object('id', p_batch_id, 'code', v_code, 'deleted_by', v_user);
END;
$function$;
