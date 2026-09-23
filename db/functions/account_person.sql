-- db/functions/account_person.sql
-- APR-ROUTE-1(Tim 的 R3 · Q6):【"这个账号是哪一个人"的唯一一份定义】
--
-- 【为什么要一支函数,而不是到处写 employees.user_id = x】
-- Tim 会有不止一个账号(admin@swm-os.test,以及之后一个只持 cfo 的账号)。
-- 自批拒绝、R2 的自批标记、以及"有没有【别人】批得动"(R4)全都要认【人】,
-- 不是认账号 —— 否则第二个账号会【不带任何标记地】批掉它主人的单。
-- 那些判据全部经由本函数问"这是谁",于是 Batch B 给一个人加第二个账号时,
-- ★ 要改的只有本函数的函数体 ★,而不是二十处 JOIN。
--
-- 【Batch B(2026-09-23)之后的形状】先查主账号(employees.user_id),
-- 查不到再回落到 employee_accounts(额外账号)。两处不可能同时登记同一个账号
-- (两道守卫,见 employee_accounts 的抬头),所以先后只决定【读哪张表】,
-- 不决定【答案】。current_user_employee() 从此就是 account_person(auth.uid()) ——
-- 于是 58 个调用方、所有"本人行"的策略,对第二个账号自动成立(Tim 的 Q7)。
-- 【Batch A 的形状,留作记录】那时它只读 employees.user_id;"同一个人的两个账号"
-- 在库里还表达不出来,所以它等价于 current_user_employee() 对任意一个账号的版本。
--
-- 【返回 NULL = 这个账号不属于任何在册员工】不是"不知道"。调用方
-- (self_leg · approval_deciders)把 NULL 当成"这个账号就是它自己这个人",
-- 而【绝不】拿两个 NULL 相等去判"同一个人"—— forbid_self_approval 抬头那一条。
--
-- 【为什么 SECURITY DEFINER,以及为什么被收权】它读 employees(有 RLS),
-- 而它回答的是【任意一个账号】是谁 —— 给了 authenticated 就等于把"账号 → 员工"
-- 的对照表问出来。调用方全是 DEFINER 或在 DEFINER 里跑,收回之后照常工作。
-- 收权写在 db/views/zzz_function_grants.sql。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1a-higher-decides-lower-and-the-flagged-self.sql.

CREATE OR REPLACE FUNCTION public.account_person(p_user uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(
        (SELECT e.id FROM employees e
          WHERE p_user IS NOT NULL AND e.user_id = p_user AND e.deleted_at IS NULL
          LIMIT 1),
        -- ★ Batch B:额外账号。一个已删的员工不是一个"人"(与主账号那一支同一条)。
        (SELECT e.id FROM employee_accounts ea
           JOIN employees e ON e.id = ea.employee_id AND e.deleted_at IS NULL
          WHERE p_user IS NOT NULL AND ea.user_id = p_user));
$function$;

COMMENT ON FUNCTION public.account_person(uuid) IS
'APR-ROUTE-1(R3):"这个账号是哪一个人"的唯一定义 —— 返回它所属的在册员工 id(先查主账号 employees.user_id,再回落到额外账号 employee_accounts),不属于任何员工时返回 NULL。current_user_employee()、自批拒绝(self_leg)、R2 的自批标记与 R4 的"别人批得动吗"(approval_deciders)全部经由它认人。EXECUTE 已从 authenticated 收回 —— 它回答任意一个账号是谁。';
