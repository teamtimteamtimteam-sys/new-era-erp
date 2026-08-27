CREATE OR REPLACE FUNCTION public.next_chase_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 自己的一把锁 —— 共用一把会烧掉别人的号,而无缝的意思正是号码之间没有洞。
    PERFORM pg_advisory_xact_lock(hashtext('chase_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
      FROM collection_chases
     WHERE code LIKE 'CHASE-' || v_year::text || '-%';
    RETURN 'CHASE-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$

;
