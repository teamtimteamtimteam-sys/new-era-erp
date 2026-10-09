-- db/functions/withdraw_assay_dispute.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q13 · Q16,Tim):【撤回一件开着的化验争议】—— module.quality.edit,理由必填。
--   撤回之后挡着的那几处(应用、试算、化验来源的定价过账、卖方结算)放开;什么都不应用。返回 {dispute_id, status}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.withdraw_assay_dispute(p_dispute_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
    v_d      assay_disputes%ROWTYPE;
BEGIN
    PERFORM require_permission('module.quality.edit');
    SELECT * INTO v_d FROM assay_disputes WHERE id = p_dispute_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_FOUND|%', COALESCE(p_dispute_id::text, '?');
    END IF;
    IF v_d.status <> 'open' THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_OPEN|%', v_d.status;
    END IF;
    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_REASON_REQUIRED';
    END IF;
    UPDATE assay_disputes
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(), withdraw_reason = v_reason,
           updated_at = now(), updated_by = auth.uid()
     WHERE id = p_dispute_id;
    RETURN jsonb_build_object('dispute_id', p_dispute_id, 'status', 'withdrawn');
END;
$function$
