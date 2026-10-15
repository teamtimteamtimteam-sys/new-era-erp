-- db/functions/next_coa_code.sql
-- MES-6b-2(2026-10-15,MES-0 Q53 · MES-6b Step 0 Q30):分析证书的编号 COA-YYYY-NNNN —— 按年、无洞,与 next_ncr_code 逐行同形
--   (自己的一把 advisory lock;MAX(split_part)+1 带 LIKE 过滤;前缀从 document_types 读)。号在签发那一刻铸(issue_coa)。
--   ★ 宽度 GREATEST(4, 位数)(CODE-WIDTH-4)。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.next_coa_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】COA 与 NCR / SMP 各自连号 —— 共用一把会让一种单据烧掉另一种的号。
    PERFORM pg_advisory_xact_lock(hashtext('coa_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM certificates_of_analysis
    WHERE code LIKE document_type_prefix('coa') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('coa') || '-' || v_year::text || '-' || LPAD(v_seq::text, GREATEST(4, length(v_seq::text)), '0');
END;
$function$
