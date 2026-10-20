-- db/functions/portal_submission_reject.sql
-- MES-9c(2026-10-20,MES-9 Step 0 Q19,Tim):【员工驳回一份门户交上来的证书】—— 理由必填(PORTAL_SUBMISSION_REASON_REQUIRED),
--   供应商在门户里看得见这句理由。门 module.suppliers.edit(Q19)。只驳回还在等审核的(PORTAL_SUBMISSION_NOT_WAITING|<状态>)。
--   什么别的都不写:没有证书行、没有附件行;交上来的那份字节留在 portal-uploads 里(它是那一份申请的凭据;那个桶没有删除策略)。
-- NOTE: introduced by db/migrations/2026-10-20-mes9c-certificate-uploads.sql.
CREATE OR REPLACE FUNCTION public.portal_submission_reject(p_submission_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_status text;
    v_reason text := btrim(COALESCE(p_reason, ''));
BEGIN
    PERFORM require_permission('module.suppliers.edit');
    IF v_reason = '' THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_REASON_REQUIRED';
    END IF;
    SELECT x.status INTO v_status FROM portal_certificate_submissions x WHERE x.id = p_submission_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_NOT_FOUND';
    END IF;
    IF v_status <> 'submitted' THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_NOT_WAITING|%', v_status;
    END IF;
    UPDATE portal_certificate_submissions
       SET status = 'rejected', decided_at = now(), decided_by = auth.uid(), reject_reason = left(v_reason, 1000)
     WHERE id = p_submission_id;
    RETURN jsonb_build_object('submission', p_submission_id, 'state', 'rejected');
END;
$function$;
