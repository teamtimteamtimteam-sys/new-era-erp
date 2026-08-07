CREATE OR REPLACE FUNCTION public.reprice_from_committed_terms(p_inbound_batch_id uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_batch   record;
    v_commit  uuid;
    v_formula uuid;
    v_calc    jsonb;
    v_unit    numeric;
    v_rep     jsonb;
BEGIN
    PERFORM require_permission('module.inbound.edit');

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

    v_rep := reprice_inbound_batch(v_batch.id, v_unit, 'USD', NULL,
                                   'Repriced from committed terms');

    -- 批次上记下这张公式,界面据此显示"这批货归哪张公式管"(结算仍只读副本)
    SELECT c.source_formula_id INTO v_formula
    FROM pricing_term_commitments c WHERE c.id = v_commit;
    IF v_batch.pricing_formula_id IS NULL AND v_formula IS NOT NULL THEN
        UPDATE inbound_batches SET pricing_formula_id = v_formula, updated_by = v_user
        WHERE id = v_batch.id;
    END IF;

    RETURN jsonb_build_object(
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'commitment_id', v_commit,
        'unit_price_usd_per_kg', v_unit,
        'calc', v_calc,
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'journal_code', v_rep->'journal_code'
    );
END;
$function$;