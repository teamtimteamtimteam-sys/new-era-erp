CREATE OR REPLACE FUNCTION public.next_traceability_report_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】与 next_credit_note_code / next_shipment_code / next_quote_code
    -- 逐字同一套:共用一把锁会让一种单据烧掉另一种的号,而无缝的意思正是
    -- "号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('traceability_report_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM traceability_report_issues
    WHERE code LIKE 'TRC-' || v_year::text || '-%';
    RETURN 'TRC-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;
