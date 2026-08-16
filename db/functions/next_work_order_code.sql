CREATE OR REPLACE FUNCTION public.next_work_order_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】WO 与 SO / QT / CN 各自连号 —— 共用一把会让一种单据
    -- 烧掉另一种的号,而无缝的意思正是"号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('work_order_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM work_orders
    WHERE code LIKE 'WO-' || v_year::text || '-%';
    RETURN 'WO-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$

;
