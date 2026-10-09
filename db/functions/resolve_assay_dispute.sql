-- db/functions/resolve_assay_dispute.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q13 · Q19,Tim):【结案:点名哪一份说了算】—— action.apply_assay(今天应用化验的人;
--   结案预先替他做了那个选择,所以是他的码,不是质量的编辑码)。说明必填。说了算的那一份:同一批的任何一份没删的结果
--   (我们的、对手方的、或仲裁的;ASSAY_NOT_FOR_BATCH)。
--   ★ 它【什么都不应用】(Q19):挡着的那几处放开,说了算的那一份照常经 apply_assay_result → CFO 批的定价申请(进料),
--   或 apply_output_assay / 结算(产出)。没有自动的取平均、各让一半 —— 没有人给过那条规矩。返回 {dispute_id, status, governing_assay_code}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.resolve_assay_dispute(p_dispute_id uuid, p_governing_assay_id uuid, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
    v_d    assay_disputes%ROWTYPE;
    v_a    assay_results%ROWTYPE;
BEGIN
    PERFORM require_permission('action.apply_assay');
    SELECT * INTO v_d FROM assay_disputes WHERE id = p_dispute_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_FOUND|%', COALESCE(p_dispute_id::text, '?');
    END IF;
    IF v_d.status <> 'open' THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_OPEN|%', v_d.status;
    END IF;
    IF v_note IS NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOTE_REQUIRED';
    END IF;
    SELECT * INTO v_a FROM assay_results WHERE id = p_governing_assay_id AND deleted_at IS NULL;
    IF NOT FOUND OR v_a.inbound_batch_id IS DISTINCT FROM v_d.inbound_batch_id
       OR v_a.output_batch_id IS DISTINCT FROM v_d.output_batch_id THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOR_BATCH|%', COALESCE(v_a.code, COALESCE(p_governing_assay_id::text, '?'));
    END IF;
    UPDATE assay_disputes
       SET status = 'resolved', governing_assay_id = p_governing_assay_id, resolution_note = v_note,
           resolved_at = now(), resolved_by = auth.uid(), updated_at = now(), updated_by = auth.uid()
     WHERE id = p_dispute_id;
    RETURN jsonb_build_object('dispute_id', p_dispute_id, 'status', 'resolved', 'governing_assay_code', v_a.code);
END;
$function$
