-- db/functions/list_totals_my_expense_claims.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1):/me 费用报销那张表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/me/meRows.ts 的 myExpenseCount / myExpensePage 同一套:expense_claim_status,employee_id = 本人。
--   没有参数:主语就是调用者(current_user_employee());不是员工 → 按名拒。
-- 【合计】amount(amount_ccy),每个币种(单据自己的 currency)一行。
-- 【净额】报销单本身没有冲销镜像行(冲销发生在它生成的那张费用单上,报销单这一行不变);所有状态都在列表里,合计同一个集合。
-- 【门】没有模块码:/me 不挂模块守卫,行由视图的「本人」谓词放行(expense_claim_status.sql 的 WHERE)。invoker。
-- 【受限】视图不遮金额;照实算 bool_or(amount_ccy IS NULL) —— 基表 NOT NULL CHECK > 0(expense_claims.sql:23)。
CREATE OR REPLACE FUNCTION public.list_totals_my_expense_claims()
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
    SELECT ''::text, c.currency::text, 'amount'::text,
           CASE WHEN bool_or(c.amount_ccy IS NULL) THEN NULL::numeric ELSE round(sum(c.amount_ccy), 2) END,
           bool_or(c.amount_ccy IS NULL)
      FROM expense_claim_status c
     WHERE c.employee_id = v_emp
     GROUP BY c.currency
     ORDER BY 2;
END;
$function$;