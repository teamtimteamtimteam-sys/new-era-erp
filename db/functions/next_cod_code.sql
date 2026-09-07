CREATE OR REPLACE FUNCTION public.next_cod_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】与 next_traceability_report_code / next_credit_note_code
    -- 逐字同一套:共用一把锁会让一种单据烧掉另一种的号,而无缝的意思正是
    -- "号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('cod_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM certificates_of_destruction
    WHERE code LIKE 'COD-' || v_year::text || '-%';
    RETURN 'COD-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;
