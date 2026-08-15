CREATE OR REPLACE FUNCTION public.next_credit_note_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁,而不是跟发票共用 'invoice_code_<year>'】两种单据各自
    -- 连号:CN-2026-0001 与 INV-2026-0001 是两个序列。共用一把锁会让贷项凭证
    -- 烧掉发票的号(反过来也一样),而无缝的意思正是"号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('credit_note_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM credit_notes
    WHERE code LIKE 'CN-' || v_year::text || '-%';
    RETURN 'CN-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$

;
