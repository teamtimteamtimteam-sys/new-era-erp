-- db/functions/list_totals_my_medical_claims.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/me 医疗报销那张表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/me/meRows.ts 的 myMedicalCount / myMedicalPage 同一套:medical_claim_status,employee_id = 本人。
--   没有参数:主语就是调用者(current_user_employee());不是员工 → 按名拒(/me 对没有员工档案的人不画这张表)。
-- 【合计】amount(amount_sgd)。currency 给 NULL:固定新元,面板格子写着 SGD(MyClaimsPanel.tsx),由页面说出来。
-- 【净额】没有冲销镜像行;所有状态都在列表里,合计同一个集合。
-- 【门】没有模块码:/me 不挂模块守卫,行由视图的「本人」谓词放行(medical_claim_status.sql 末行)。invoker。
-- 【受限】本人的行从不遮(视图 CASE 对 employee_id = current_user_employee() 让路),但照实算:bool_or(amount_sgd IS NULL)
--   —— 基表 NOT NULL,NULL 只可能是遮。
CREATE OR REPLACE FUNCTION public.list_totals_my_medical_claims()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp uuid;
BEGIN
    v_emp := current_user_employee();
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'LIST_TOTALS_NO_EMPLOYEE'
          USING HINT = '这份合计只算调用者自己的行,而这个登录账号没有对应的员工档案。';
    END IF;
    RETURN QUERY
    SELECT ''::text, NULL::text, 'amount'::text,
           CASE WHEN bool_or(m.amount_sgd IS NULL) THEN NULL::numeric ELSE round(sum(m.amount_sgd), 2) END,
           bool_or(m.amount_sgd IS NULL)
      FROM medical_claim_status m
     WHERE m.employee_id = v_emp
    HAVING count(*) > 0;
END;
$function$;