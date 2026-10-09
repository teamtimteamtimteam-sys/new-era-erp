-- db/functions/next_blending_plan_code.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17):配料计划的编号 BLD-YYYY-NNNN —— 按年、无洞,与 next_work_order_code 逐行同形
--   (自己的一把 advisory lock;MAX(split_part)+1 带 LIKE 过滤;前缀从 document_types 读)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.next_blending_plan_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】BLD 与 WO / SO / QT 各自连号 —— 共用一把会让一种单据烧掉另一种的号。
    PERFORM pg_advisory_xact_lock(hashtext('blending_plan_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM blending_plans
    WHERE code LIKE document_type_prefix('blending_plan') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('blending_plan') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$
