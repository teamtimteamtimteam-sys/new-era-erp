-- db/functions/link_dispute_fee.sql
-- MES-6a-1(2026-10-09,MES-0 Q63 · Q64;MES-6a Step 0 Q22 · Q23,Tim):【把仲裁费那一张费用单挂到争议上】—— module.quality.edit。
--   仲裁费是一张【普通】费用单(财务照常经 record_expense 记,未付),付给出仲裁结果的那家实验室在供应商表里的那一户:
--   争议必须已记下仲裁结果(ASSAY_DISPUTE_FEE_NO_UMPIRE_ASSAY),那份结果的实验室必须指着一户供应商
--   (ASSAY_DISPUTE_FEE_LAB_HAS_NO_SUPPLIER —— 在字典编辑器里指,module.materials.edit),费用单的供应商必须就是那一户
--   (ASSAY_DISPUTE_FEE_SUPPLIER_MISMATCH),费用单必须在册(EXPENSE_NOT_POSTED)。一件争议只挂一张(ASSAY_DISPUTE_FEE_ALREADY_LINKED);
--   撤回的争议不挂(ASSAY_DISPUTE_WITHDRAWN)。
--   挂上不付钱:付那张费用单照常走付款申请,而那户供应商没批准时付款申请按名拒(PAYMENT_REQUEST_SUPPLIER_BLOCKED)。
--   对手方该担的那一份只算出来给人看(assay_dispute_rows),不收。返回 {dispute_id, fee_expense_code}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.link_dispute_fee(p_dispute_id uuid, p_expense_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_d    assay_disputes%ROWTYPE;
    v_lab  text;
    v_sup  uuid;
    v_exp  expenses%ROWTYPE;
BEGIN
    PERFORM require_permission('module.quality.edit');
    SELECT * INTO v_d FROM assay_disputes WHERE id = p_dispute_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_NOT_FOUND|%', COALESCE(p_dispute_id::text, '?');
    END IF;
    IF v_d.status = 'withdrawn' THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_WITHDRAWN';
    END IF;
    IF v_d.fee_expense_id IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_FEE_ALREADY_LINKED|%', (SELECT code FROM expenses WHERE id = v_d.fee_expense_id);
    END IF;
    IF v_d.umpire_assay_id IS NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_FEE_NO_UMPIRE_ASSAY';
    END IF;
    SELECT a.lab_name INTO v_lab FROM assay_results a WHERE a.id = v_d.umpire_assay_id;
    SELECT l.supplier_id INTO v_sup FROM laboratories l WHERE l.code = v_lab;
    IF v_sup IS NULL THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_FEE_LAB_HAS_NO_SUPPLIER|%', COALESCE(v_lab, '?');
    END IF;
    SELECT * INTO v_exp FROM expenses WHERE id = p_expense_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', COALESCE(p_expense_id::text, '?');
    END IF;
    IF v_exp.status <> 'posted' OR v_exp.reversed_by_expense IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_NOT_POSTED|%', v_exp.code;
    END IF;
    IF v_exp.supplier_id IS DISTINCT FROM v_sup THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_FEE_SUPPLIER_MISMATCH|%|%', v_exp.code, v_lab;
    END IF;
    UPDATE assay_disputes SET fee_expense_id = p_expense_id, updated_at = now(), updated_by = auth.uid() WHERE id = p_dispute_id;
    RETURN jsonb_build_object('dispute_id', p_dispute_id, 'fee_expense_code', v_exp.code);
END;
$function$
