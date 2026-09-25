-- db/functions/receipt_price_post_internal.sql
-- ROLE-1 Batch 4b(2026-09-25):把一张定价申请【过账】—— 批准那一刻(或审批关着时提交那一刻)跑的
-- 那一支,也是试跑(receipt_price_request_dry_run)跑的同一支。
--
--   1. 引擎 reprice_inbound_batch:原币单价 × 【今天】的 tt_sell(Tim 的 Q2:过账记在批准日、按那天的
--      牌价)→ unit_price、price_history、purchase 分录(1200 / 5000 / Cr 2000)。引擎自己再问一次
--      data.view_purchase_prices —— 问的是按下去的那个人(批准时是 CFO)。
--   2. 化验来源、而且那份化验是 is_final → 收货的 pricing_status 升为 final(Tim 的 Q3:只在批准时)。
--      pricing_status 的直连写由 guard_inbound_batch_price_request 拒;本支是属主路径。
--   3. 按已承诺条款改价 → 收货还没挂公式时,记下承诺副本的来源公式(原 reprice_from_committed_terms
--      落账后做的那一步,挪到真正落账的这一刻)。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_price_post_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r       receipt_price_requests%ROWTYPE;
    v_rep     jsonb;
    v_formula uuid;
BEGIN
    SELECT * INTO v_r FROM receipt_price_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;

    v_rep := reprice_inbound_batch(v_r.inbound_batch_id, v_r.unit_price_ccy, v_r.currency, NULL,
                                   concat_ws(' · ', 'Price request ' || v_r.label, v_r.notes));

    IF v_r.source = 'assay'
       AND (SELECT a.is_final FROM assay_results a WHERE a.id = v_r.assay_result_id) THEN
        UPDATE inbound_batches SET pricing_status = 'final', updated_by = auth.uid()
         WHERE id = v_r.inbound_batch_id AND pricing_status <> 'final';
    END IF;

    IF v_r.source = 'committed_terms' AND v_r.commitment_id IS NOT NULL THEN
        SELECT c.source_formula_id INTO v_formula
          FROM pricing_term_commitments c WHERE c.id = v_r.commitment_id;
        IF v_formula IS NOT NULL THEN
            UPDATE inbound_batches SET pricing_formula_id = v_formula, updated_by = auth.uid()
             WHERE id = v_r.inbound_batch_id AND pricing_formula_id IS NULL;
        END IF;
    END IF;

    RETURN v_rep;
END;
$function$
;
