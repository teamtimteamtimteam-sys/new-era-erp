CREATE OR REPLACE FUNCTION public.reprice_from_committed_terms(p_inbound_batch_id uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch   record;
    v_commit  uuid;
    v_calc    jsonb;
    v_unit    numeric;
    v_rep     jsonb;
BEGIN
    -- ★ ROLE-1 Batch 4a:定价归财务(action.price_receipts),而且看不见采购价的人不能定价 ——
    --   两个码都在库里问(grilling Q1)。引擎 reprice_inbound_batch 自己再问一次后者。
    PERFORM require_permission('action.price_receipts');
    PERFORM require_permission('data.view_purchase_prices');

    SELECT id, code, pricing_formula_id INTO v_batch
    FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;

    -- 【与试算同一份算术】committed_terms_price 里做承诺解析、含量读取与算价;
    -- 这里只负责落账。两条路不可能各算各的。
    v_calc   := committed_terms_price(p_inbound_batch_id, p_reference_date);
    v_commit := (v_calc->>'commitment_id')::uuid;
    v_unit   := (v_calc->>'unit_price_usd_per_kg')::numeric;
    IF v_unit IS NULL OR v_unit <= 0 THEN
        -- 净值 ≤ 0 的料不进价格机器(与 apply_assay_result 同一判断),但这里是人
        -- 主动按的按钮,所以点名说清楚,而不是默默什么都不做。
        RAISE EXCEPTION 'PRICE_NOT_POSITIVE|%', COALESCE(v_unit::text, '?');
    END IF;

    -- ★ ROLE-1 Batch 4b(Tim 的 Q8):按已承诺条款改价从此【提一张申请】(来源 committed_terms),
    --   CFO 批了才过账;批准那一刻按批准日的牌价过账,并在收货还没挂公式时记下承诺副本的来源公式
    --   (receipt_price_post_internal —— 原来落账后紧接着做的那一步,挪到真正落账的那一刻)。
    v_rep := receipt_price_submit_internal(v_batch.id, v_unit, 'USD', 'committed_terms', NULL, v_commit,
                                           'Repriced from committed terms');

    RETURN jsonb_build_object(
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'commitment_id', v_commit,
        'unit_price_usd_per_kg', v_unit,
        'calc', v_calc,
        'request_id', v_rep->'request_id',
        'label', v_rep->'label',
        'status', v_rep->'status',
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'journal_code', v_rep->'journal_code'
    );
END;
$function$;