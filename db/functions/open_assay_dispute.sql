-- db/functions/open_assay_dispute.sql
-- MES-6a-1(2026-10-09,MES-0 Q62;MES-6a Step 0 Q16 · Q17 · Q22,Tim):【立一件化验争议】—— module.quality.edit。
--   同一批(进料或产出)的一份 ours 与一份 counterparty(出具方按名核对:ASSAY_DISPUTE_PARTY_MISMATCH);理由必填;
--   一批同时最多一件开着的(ASSAY_DISPUTE_ALREADY_OPEN —— 唯一索引是第二道)。不判两份差多少:立不立是人的决定(Q17 —— 买方没有提示,
--   一个人自己立;卖方的提示是 assay_results_disagree 那一支)。
--   【容差与仲裁费分摊在案】卖方可以指一张销售单(只对产出批):那张单挂着的合同副本里的 splitting_limit_pct 与 arbitration_fee_rule
--   抄进 limit_pct_at / fee_rule_at;买方或没指销售单 → 两样都空(limit not set · Not yet set,Q62 · Q22)。
--   开着之后进料那一侧的应用、试算与化验来源的定价过账按名拒,卖方结算按名拒(ASSAY_DISPUTE_OPEN)。
--   返回 {dispute_id, batch_code, limit_pct_at, fee_rule_at}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.open_assay_dispute(p_our_assay_id uuid, p_counterparty_assay_id uuid, p_reason text, p_sales_order_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
    v_ours   assay_results%ROWTYPE;
    v_cp     assay_results%ROWTYPE;
    v_bcode  text;
    v_st     jsonb;
    v_limit  numeric;
    v_rule   text;
    v_id     uuid := gen_random_uuid();
BEGIN
    PERFORM require_permission('module.quality.edit');
    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_ours FROM assay_results WHERE id = p_our_assay_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_our_assay_id::text, '?');
    END IF;
    SELECT * INTO v_cp FROM assay_results WHERE id = p_counterparty_assay_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_counterparty_assay_id::text, '?');
    END IF;
    IF v_ours.result_party <> 'ours' THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_PARTY_MISMATCH|%|%|ours', v_ours.code, v_ours.result_party;
    END IF;
    IF v_cp.result_party <> 'counterparty' THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_PARTY_MISMATCH|%|%|counterparty', v_cp.code, v_cp.result_party;
    END IF;
    IF v_ours.inbound_batch_id IS DISTINCT FROM v_cp.inbound_batch_id
       OR v_ours.output_batch_id IS DISTINCT FROM v_cp.output_batch_id THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_SAME_BATCH|%|%', v_ours.code, v_cp.code;
    END IF;

    -- 锁住那一批:判"有没有开着的"与立案串行
    IF v_ours.inbound_batch_id IS NOT NULL THEN
        SELECT code INTO v_bcode FROM inbound_batches WHERE id = v_ours.inbound_batch_id AND deleted_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_ours.inbound_batch_id; END IF;
        IF EXISTS (SELECT 1 FROM assay_disputes d WHERE d.inbound_batch_id = v_ours.inbound_batch_id AND d.status = 'open') THEN
            RAISE EXCEPTION 'ASSAY_DISPUTE_ALREADY_OPEN|%', v_bcode;
        END IF;
    ELSE
        SELECT code INTO v_bcode FROM output_batches WHERE id = v_ours.output_batch_id AND deleted_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_ours.output_batch_id; END IF;
        IF EXISTS (SELECT 1 FROM assay_disputes d WHERE d.output_batch_id = v_ours.output_batch_id AND d.status = 'open') THEN
            RAISE EXCEPTION 'ASSAY_DISPUTE_ALREADY_OPEN|%', v_bcode;
        END IF;
    END IF;

    IF p_sales_order_id IS NOT NULL THEN
        IF v_ours.output_batch_id IS NULL THEN
            RAISE EXCEPTION 'ASSAY_DISPUTE_SALES_ORDER_NEEDS_OUTPUT_BATCH';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM sales_orders WHERE id = p_sales_order_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SO_NOT_FOUND|%', p_sales_order_id;
        END IF;
        SELECT t.settlement_terms INTO v_st FROM contract_document_terms t WHERE t.sales_order_id = p_sales_order_id;
        v_limit := (v_st ->> 'splitting_limit_pct')::numeric;
        v_rule := v_st ->> 'arbitration_fee_rule';
    END IF;

    INSERT INTO assay_disputes (id, inbound_batch_id, output_batch_id, our_assay_id, counterparty_assay_id, sales_order_id,
                                status, opening_reason, limit_pct_at, fee_rule_at, created_by, updated_by)
    VALUES (v_id, v_ours.inbound_batch_id, v_ours.output_batch_id, p_our_assay_id, p_counterparty_assay_id, p_sales_order_id,
            'open', v_reason, v_limit, v_rule, v_user, v_user);

    RETURN jsonb_build_object('dispute_id', v_id, 'batch_code', v_bcode, 'limit_pct_at', v_limit, 'fee_rule_at', v_rule);
END;
$function$
