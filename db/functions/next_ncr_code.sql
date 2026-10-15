-- db/functions/next_ncr_code.sql
-- MES-6b-1(2026-10-15,MES-0 Q53 · MES-6b Step 0 Q7):不合格报告的编号 NCR-YYYY-NNNN —— 按年、无洞,与 next_sample_code 逐行同形
--   (自己的一把 advisory lock;MAX(split_part)+1 带 LIKE 过滤;前缀从 document_types 读)。
--   ★ 宽度 GREATEST(4, 位数)(CODE-WIDTH-4):LPAD 到固定的 4 位会在第 10,000 张时把号【截短】成一个已经发过的号 —— 新的取号函数不再照抄那一句。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.next_ncr_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】NCR 与 SMP / BLD 各自连号 —— 共用一把会让一种单据烧掉另一种的号。
    PERFORM pg_advisory_xact_lock(hashtext('ncr_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM nonconformance_reports
    WHERE code LIKE document_type_prefix('ncr') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('ncr') || '-' || v_year::text || '-' || LPAD(v_seq::text, GREATEST(4, length(v_seq::text)), '0');
END;
$function$
