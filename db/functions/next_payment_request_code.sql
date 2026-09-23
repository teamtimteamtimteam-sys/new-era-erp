-- db/functions/next_payment_request_code.sql
-- PAY-REQ-1(2026-09-23):付款申请的编号,PREQ-YYYY-NNNN,无洞 —— 与
-- next_expense_claim_code 逐字同形(advisory lock + 年内 MAX+1;前缀从 document_types 读)。
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.next_payment_request_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_year integer := EXTRACT(YEAR FROM p_date)::integer; v_seq integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('payment_request_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
      FROM payment_requests WHERE code LIKE document_type_prefix('payment_request') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('payment_request') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$
;
