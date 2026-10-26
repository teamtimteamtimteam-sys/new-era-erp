-- db/functions/list_totals_medical_claims.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/hr/claims 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/hr/claims/claimsRows.ts:60-65 的 filtered() 逐项同一套:employee_id = 员工、claim_year = 年、
--   settlement_state = 状态;读同一张视图 medical_claim_status(claimsRows.ts:73)。
-- 【合计】amount(amount_sgd)。currency 给 NULL:这一列固定是新元,列名与格子(ClaimsTable.tsx)写着 SGD,由页面说出来。
-- 【净额】医疗报销没有冲销镜像行;页面列出所有状态(含 rejected / withdrawn),合计照列表同一个集合。
-- 【门】require_permission('module.hr.view') —— 与页面守卫(requireModule(MOD.hr))同一个码。invoker。
-- 【受限】逐行:视图对不持 data.view_health 的读者把别人的金额置 NULL(medical_claim_status.sql:27-30),
--   基表 amount_sgd NOT NULL CHECK > 0(medical_claims.sql:13)—— 所以这里 NULL 就是「看不见」,不是「没有」。
CREATE OR REPLACE FUNCTION public.list_totals_medical_claims(p_employee uuid DEFAULT NULL::uuid, p_year integer DEFAULT NULL::integer, p_status text DEFAULT NULL::text)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.hr.view');
    RETURN QUERY
    SELECT ''::text, NULL::text, 'amount'::text,
           CASE WHEN bool_or(m.amount_sgd IS NULL) THEN NULL::numeric ELSE round(sum(m.amount_sgd), 2) END,
           bool_or(m.amount_sgd IS NULL)
      FROM medical_claim_status m
     WHERE (p_employee IS NULL OR m.employee_id = p_employee)
       AND (p_year IS NULL OR m.claim_year = p_year)
       AND (p_status IS NULL OR m.settlement_state = p_status)
    HAVING count(*) > 0;
END;
$function$;