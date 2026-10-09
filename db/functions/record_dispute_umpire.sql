-- db/functions/record_dispute_umpire.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q16,Tim):【记下一件开着的争议的仲裁样品与仲裁结果】—— module.quality.edit。
--   两样都可选、至少给一样(ASSAY_DISPUTE_UMPIRE_EMPTY);给了的那一样必须是同一批的(SAMPLE_NOT_FOR_BATCH / ASSAY_NOT_FOR_BATCH),
--   仲裁结果的出具方必须是 umpire(ASSAY_DISPUTE_PARTY_MISMATCH)。只对开着的争议(ASSAY_DISPUTE_NOT_OPEN);开着时可以改记。
--   记下它【不】结案、不应用任何东西 —— 结案是 resolve_assay_dispute。返回 {dispute_id}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.record_dispute_umpire(p_dispute_id uuid, p_umpire_sample_id uuid, p_umpire_assay_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_d  assay_disputes%ROWTYPE;
    v_s  samples%ROWTYPE;
    v_a  assay_results%ROWTYPE;
BEGIN
    PERFORM require_permission('module.quality.edit');
    SELECT * INTO v_d FROM assay_disputes WHERE id = p_dispute_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_FOUND|%', COALESCE(p_dispute_id::text, '?');
    END IF;
    IF v_d.status <> 'open' THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_OPEN|%', v_d.status;
    END IF;
    IF p_umpire_sample_id IS NULL AND p_umpire_assay_id IS NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_UMPIRE_EMPTY';
    END IF;
    IF p_umpire_sample_id IS NOT NULL THEN
        SELECT * INTO v_s FROM samples WHERE id = p_umpire_sample_id;
        IF NOT FOUND OR v_s.inbound_batch_id IS DISTINCT FROM v_d.inbound_batch_id
           OR v_s.output_batch_id IS DISTINCT FROM v_d.output_batch_id THEN
            RAISE EXCEPTION 'SAMPLE_NOT_FOR_BATCH|%', COALESCE(v_s.code, p_umpire_sample_id::text);
        END IF;
    END IF;
    IF p_umpire_assay_id IS NOT NULL THEN
        SELECT * INTO v_a FROM assay_results WHERE id = p_umpire_assay_id AND deleted_at IS NULL;
        IF NOT FOUND OR v_a.inbound_batch_id IS DISTINCT FROM v_d.inbound_batch_id
           OR v_a.output_batch_id IS DISTINCT FROM v_d.output_batch_id THEN
            RAISE EXCEPTION 'ASSAY_NOT_FOR_BATCH|%', COALESCE(v_a.code, p_umpire_assay_id::text);
        END IF;
        IF v_a.result_party <> 'umpire' THEN
            RAISE EXCEPTION 'ASSAY_DISPUTE_PARTY_MISMATCH|%|%|umpire', v_a.code, v_a.result_party;
        END IF;
    END IF;

    UPDATE assay_disputes
       SET umpire_sample_id = COALESCE(p_umpire_sample_id, umpire_sample_id),
           umpire_assay_id = COALESCE(p_umpire_assay_id, umpire_assay_id),
           updated_at = now(), updated_by = auth.uid()
     WHERE id = p_dispute_id;
    RETURN jsonb_build_object('dispute_id', p_dispute_id);
END;
$function$
