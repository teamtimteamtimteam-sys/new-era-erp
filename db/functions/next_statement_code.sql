CREATE OR REPLACE FUNCTION public.next_statement_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 自己的一把锁(与 next_credit_note_code / next_quote_code 同一惯用法):
    -- 共用一把会烧掉别人的号,而无缝的意思正是号码之间没有洞。
    PERFORM pg_advisory_xact_lock(hashtext('statement_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
      FROM customer_statements
     WHERE code LIKE 'STMT-' || v_year::text || '-%';
    RETURN 'STMT-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$

;
