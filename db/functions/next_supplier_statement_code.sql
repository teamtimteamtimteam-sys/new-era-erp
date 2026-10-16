-- db/functions/next_supplier_statement_code.sql
-- MES-8a(2026-10-16,MES-8 Step 0 Q7):SST-YYYY-NNNN,按年无洞。宽度 GREATEST(4, 位数)—— 超过 9,999 照实长出去(SST-2026-10000),
--   不截到 4 位(CODE-WIDTH-4 那一族年度重置的号还在截,Tim 的 Q14 裁定留着它们;这一支是新的,从第一天起就不截)。
--   取最大号用 split_part(…)::integer —— 按数比,不按字比('10000' 在字面上小于 '9999')。自己的一把锁(next_statement_code 的惯用法)。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.next_supplier_statement_code(p_date date)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year   integer := EXTRACT(YEAR FROM p_date)::integer;
    v_prefix text := document_type_prefix('supplier_statement');
    v_n      text;
BEGIN
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_DATE_REQUIRED';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('supplier_statement_code_' || v_year::text)::bigint);
    SELECT (COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1)::text INTO v_n
      FROM supplier_statements
     WHERE code LIKE v_prefix || '-' || v_year::text || '-%';
    RETURN v_prefix || '-' || v_year::text || '-' || LPAD(v_n, GREATEST(4, length(v_n)), '0');
END;
$function$
