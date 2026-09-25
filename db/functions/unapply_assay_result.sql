CREATE OR REPLACE FUNCTION public.unapply_assay_result(p_assay_result_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_assay  record;
    v_latest uuid;
    v_req    uuid;
BEGIN
    -- PROC-1:先读单据才知道父是谁,权限判在任何改动之前(定义者身份读,不漏行)
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND OR v_assay.applied_at IS NULL THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    PERFORM require_permission('action.apply_assay');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 只许撤最近一次:链条中间抽走一环,superseded_by 的叙事就断了。
    -- 链按【父】各自成链 —— 同一张表里进料链与产出链互不相扰。
    -- code 作平局裁决(applied_at 同事务内可能相同,编号无缝单调)。
    SELECT id INTO v_latest FROM assay_results
    WHERE (CASE WHEN v_assay.inbound_batch_id IS NOT NULL
                THEN inbound_batch_id = v_assay.inbound_batch_id
                ELSE output_batch_id = v_assay.output_batch_id END)
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

    -- ★ ROLE-1 Batch 4b(Tim 的 Q3):这份化验还挂着一张在等 CFO 的定价申请 → 撤回它,理由写明是
    --   哪一份化验、为什么撤。已经批过的价【不动】(下面那段刻意不回价的理由原样成立)。
    SELECT id INTO v_req FROM receipt_price_requests
     WHERE assay_result_id = p_assay_result_id AND status = 'submitted';
    IF v_req IS NOT NULL THEN
        PERFORM receipt_price_withdraw_internal(v_req,
            'Assay ' || v_assay.code || ' unapplied: ' || btrim(p_reason));
    END IF;

    -- 【刻意不回价、不回含量】撤销"已执行"标记只是承认这份结果不再作数;
    -- 价格与含量退回到哪一版,是新化验或手工计价的显式动作 —— 静默回滚一个
    -- 已经过完账、可能已被分摊读走的状态,比留着它更危险。
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_assay.inbound_batch_id,
        'output_batch_id', v_assay.output_batch_id,
        'reverted_price', false,
        'withdrawn_price_request_id', v_req
    );
END;
$function$
;
