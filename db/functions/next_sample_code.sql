-- db/functions/next_sample_code.sql
-- MES-6a-1(2026-10-09,MES-0 Q53 · MES-6a Step 0 Q7 · Q41):样品的编号 SMP-YYYY-NNNN —— 按年、无洞,与 next_blending_plan_code 逐行同形
--   (自己的一把 advisory lock;MAX(split_part)+1 带 LIKE 过滤;前缀从 document_types 读)。
--   宽度沿用兄弟们的 4 位(CODE-WIDTH-4 仍是它自己那一条,Q41)。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.next_sample_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】SMP 与 BLD / WO 各自连号 —— 共用一把会让一种单据烧掉另一种的号。
    PERFORM pg_advisory_xact_lock(hashtext('sample_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM samples
    WHERE code LIKE document_type_prefix('sample') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('sample') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$
