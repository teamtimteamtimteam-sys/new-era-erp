-- db/functions/withdraw_journal_request.sql
-- APR-6(2026-09-25,grilling Q3):撤回一张在等的手工凭证 / 冲销申请。
-- 谁能撤:提单人本人(按人认 —— self_leg 说这个账号就是提单人那个人),或任何持 module.finance.edit 的人。
-- 只撤 submitted。撤回不过账,只是放弃;记在本行上(谁、何时、为什么),【不】写 approval_log ——
-- 撤回不是一次决定(付款、工资、收货定价、贷项申请同一条)。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.withdraw_journal_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r journal_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM journal_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JOURNAL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission('module.finance.edit');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'JOURNAL_REQUEST_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE journal_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$;
