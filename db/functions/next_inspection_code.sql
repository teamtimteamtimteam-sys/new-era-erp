-- db/functions/next_inspection_code.sql
-- MES-7b-2(2026-10-16,MES-0 Q53 · MES-7b Step 0 Q13 · Q27):巡检的编号 INS-YYYY-NNNN —— 按年、无洞,与 next_incident_code 逐行同形
--   (自己的一把 advisory lock;MAX(split_part)+1 带 LIKE 过滤;前缀从 document_types 读;宽度 GREATEST(4, 位数) —— CODE-WIDTH-4)。
--   年份按【记录那一天】(record_inspection_run 传 CURRENT_DATE),与 INC / NCR 同一个先例。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
CREATE OR REPLACE FUNCTION public.next_inspection_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】INS 与 INC / NCR 各自连号 —— 共用一把会让一种单据烧掉另一种的号。
    PERFORM pg_advisory_xact_lock(hashtext('inspection_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM inspection_runs
    WHERE code LIKE document_type_prefix('inspection') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('inspection') || '-' || v_year::text || '-' || LPAD(v_seq::text, GREATEST(4, length(v_seq::text)), '0');
END;
$function$;
