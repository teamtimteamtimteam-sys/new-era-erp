-- db/functions/warehouse_request_submit_internal.sql
-- APR-7(2026-09-25):提一张仓库申请 —— 四扇提交的门各问完自己的码,落进这一支。本支不问码。
--
--   1. 理由必填(WAREHOUSE_REQUEST_REASON_REQUIRED|种类|编号)—— 它原样成为 delete_reason / 回滚理由 / void_reason。
--   2. 主体要在、没被删、这一种要成立:
--        注销:batch_write_off_needs_request 为真,否则 WAREHOUSE_REQUEST_NOT_NEEDED|批号(空批一步删,Q1);
--        回滚:加工单在且未回滚(RUN_NOT_FOUND · RUN_ALREADY_DELETED);
--        作废:证书在且已签发(COD_NOT_FOUND · COD_NOT_ISSUED)。
--   3. 碰到同一样东西的在等申请 → WAREHOUSE_REQUEST_OPEN|编号|那一张(Q3,跨种类;唯一索引是同种类的第二道)。
--   4. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动 → WAREHOUSE_REQUEST_NO_OTHER_DECIDER|label
--      (assert_other_decider,按人认)。线上是 admin@:它与 tim@ 是同一个人,而二级只有 tim@。
--   5. 落一行 submitted,snapshot 冻结;按批准那一刻的同一支试跑(warehouse_request_dry_run)——
--      欠款、订单预留、产出动过、期间锁,全按原话拒。amount_base 取试跑的结果。
--   6. 审批开着:留痕 submitted,二级。关着:当场生效,状态 approved,留痕 auto_approved。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_submit_internal(p_kind text, p_subject uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_on    boolean := approvals_enabled();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_del   timestamptz;
    v_stat  text;
    v_open  text;
    v_n     integer;
    v_label text;
    v_dry   jsonb;
    v_exec  jsonb := NULL;
BEGIN
    IF p_kind = 'write_off_inbound' THEN
        SELECT code INTO v_code FROM inbound_batches WHERE id = p_subject AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
    ELSIF p_kind = 'write_off_output' THEN
        SELECT code INTO v_code FROM output_batches WHERE id = p_subject AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
    ELSIF p_kind = 'rollback' THEN
        SELECT code, deleted_at INTO v_code, v_del FROM processing_runs WHERE id = p_subject FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RUN_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
        IF v_del IS NOT NULL THEN
            RAISE EXCEPTION 'RUN_ALREADY_DELETED';
        END IF;
    ELSIF p_kind = 'cod_void' THEN
        SELECT COALESCE(code, id::text), status INTO v_code, v_stat
          FROM certificates_of_destruction WHERE id = p_subject FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'COD_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
        IF v_stat <> 'issued' THEN
            RAISE EXCEPTION 'COD_NOT_ISSUED|%|%', v_code, v_stat;
        END IF;
    ELSE
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_REASON_REQUIRED|%|%', p_kind, v_code;
    END IF;

    IF p_kind IN ('write_off_inbound', 'write_off_output')
       AND NOT batch_write_off_needs_request(
               CASE WHEN p_kind = 'write_off_inbound' THEN p_subject END,
               CASE WHEN p_kind = 'write_off_output' THEN p_subject END) THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_NEEDED|%', v_code;
    END IF;

    v_open := warehouse_request_conflict(p_kind, p_subject);
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;

    -- label:同一个主体上第几张。咨询锁串行化"数一遍 + 1"。
    PERFORM pg_advisory_xact_lock(hashtext('warehouse_request_label')::bigint);
    SELECT count(*) + 1 INTO v_n FROM warehouse_requests r
     WHERE r.kind = p_kind
       AND COALESCE(r.inbound_batch_id, r.output_batch_id, r.run_id, r.cod_id) = p_subject;
    v_label := v_code || ' · ' || CASE p_kind WHEN 'rollback' THEN 'rollback'
                                               WHEN 'cod_void' THEN 'void'
                                               ELSE 'write-off' END || ' #' || v_n::text;

    PERFORM assert_other_decider('warehouse_request', 'decide_warehouse_request', 2::smallint,
                                 'WAREHOUSE_REQUEST_NO_OTHER_DECIDER|' || v_label);

    INSERT INTO warehouse_requests (id, kind, status, label, inbound_batch_id, output_batch_id, run_id, cod_id,
                                    reason, snapshot, amount_base, created_by)
    VALUES (v_id, p_kind, 'submitted', v_label,
            CASE WHEN p_kind = 'write_off_inbound' THEN p_subject END,
            CASE WHEN p_kind = 'write_off_output' THEN p_subject END,
            CASE WHEN p_kind = 'rollback' THEN p_subject END,
            CASE WHEN p_kind = 'cod_void' THEN p_subject END,
            btrim(p_reason), warehouse_request_snapshot(p_kind, p_subject), 0, auth.uid());

    v_dry := warehouse_request_dry_run(v_id);
    UPDATE warehouse_requests SET amount_base = (v_dry->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('warehouse_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        v_exec := warehouse_request_execute_internal(v_id);
        UPDATE warehouse_requests
           SET status = 'approved', executed_at = now(),
               amount_base = (v_exec->>'amount_base')::numeric,
               result_entry_ids = ARRAY(SELECT jsonb_array_elements_text(v_exec->'entry_ids')::uuid)
         WHERE id = v_id;
        PERFORM record_approval_decision('warehouse_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场生效,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'kind', p_kind,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'amount_base', COALESCE(v_exec->'amount_base', v_dry->'amount_base'));
END;
$function$;
