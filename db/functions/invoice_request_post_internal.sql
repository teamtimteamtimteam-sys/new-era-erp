-- db/functions/invoice_request_post_internal.sql
-- APR-5a(2026-09-25):把一张贷项 / 作废申请【过账】—— 批准那一刻(或审批关着时提交那一刻)跑的那一支,
-- 也是试跑(invoice_request_dry_run)跑的同一支。参数全从申请行上读,就是提交时冻下来的那一组
-- (日期、理由、贷项的行 —— grilling Q9「on the frozen date」)。
--
--   credit_note → create_credit_note_internal(发票, doc_date, reason, lines)
--   void        → void_invoice_internal(发票, reason, doc_date)
--   其它种类    → INVOICE_REQUEST_KIND_UNKNOWN(PAY-REQ-1 Batch B 那一条:不认识的种类按名拒,
--                 不许落进一个 ELSE 去做别的事)
--
-- 返回引擎的返回值,再加三样:entry_id(这次过账的分录;不带税的 sale 型发票作废没有)、
-- credit_note_id(贷项才有)、amount_base(贷项 = 那张分录的借方合计;作废 = 发票的 total_base)。
-- 【为什么读分录而不是另算】与 payment_request_dry_run 读它自己那张分录同一条:同一支引擎的产物,
-- 不在这里另算一份会漂开的数。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.invoice_request_post_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     invoice_requests%ROWTYPE;
    v_res   jsonb;
    v_entry uuid;
    v_cn    uuid := NULL;
    v_base  numeric;
BEGIN
    SELECT * INTO v_r FROM invoice_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;

    CASE v_r.kind
    WHEN 'credit_note' THEN
        v_res := create_credit_note_internal(v_r.invoice_id, v_r.doc_date, v_r.reason, v_r.lines);
        v_cn := (v_res->>'credit_note_id')::uuid;
        SELECT je.id INTO v_entry FROM journal_entries je WHERE je.code = v_res->>'journal_code';
        SELECT sum(l.debit) INTO v_base FROM journal_lines l WHERE l.entry_id = v_entry;
    WHEN 'void' THEN
        v_res := void_invoice_internal(v_r.invoice_id, v_r.reason, v_r.doc_date);
        IF v_res->>'reversal_code' IS NOT NULL THEN
            SELECT je.id INTO v_entry FROM journal_entries je WHERE je.code = v_res->>'reversal_code';
        END IF;
        SELECT i.total_base INTO v_base FROM invoices i WHERE i.id = v_r.invoice_id;
    ELSE
        RAISE EXCEPTION 'INVOICE_REQUEST_KIND_UNKNOWN|%|%', v_r.label, v_r.kind;
    END CASE;

    RETURN v_res || jsonb_build_object('entry_id', v_entry, 'credit_note_id', v_cn,
                                       'amount_base', round(COALESCE(v_base, 0), 2));
END;
$function$
;