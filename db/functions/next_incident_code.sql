-- db/functions/next_incident_code.sql
-- MES-7b-1(2026-10-16,MES-0 Q53 · MES-7b Step 0 Q3 · Q27):事故的编号 INC-YYYY-NNNN —— 按年、无洞,与 next_ncr_code 逐行同形
--   (自己的一把 advisory lock;MAX(split_part)+1 带 LIKE 过滤;前缀从 document_types 读;宽度 GREATEST(4, 位数) —— CODE-WIDTH-4)。
--   年份按【记录那一天】(record_incident 传 CURRENT_DATE),与 NCR / SMP 同一个先例 —— 编号是登记的顺序,不是事故发生的顺序。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.next_incident_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】INC 与 NCR / SMP 各自连号 —— 共用一把会让一种单据烧掉另一种的号。
    PERFORM pg_advisory_xact_lock(hashtext('incident_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM incidents
    WHERE code LIKE document_type_prefix('incident') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('incident') || '-' || v_year::text || '-' || LPAD(v_seq::text, GREATEST(4, length(v_seq::text)), '0');
END;
$function$;
