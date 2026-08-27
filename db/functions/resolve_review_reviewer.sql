-- db/functions/resolve_review_reviewer.sql
-- PROBATION-1(2026-08-27):「谁评估这个人」的【唯一一处】定义。
--
-- 【为什么它是一支函数】这段三级解析原本只写在 open_review_cycle 的
-- INSERT ... SELECT 里。PROBATION-1 要第二个调用方(open_probation_review),
-- 而复制它就是同一条规矩的两份实现 —— 这个仓库为这个形状反复付过账。
-- db/fixtures/136 的 H 臂做目录断言:两个入口都必须【调用】它。
-- 那一臂第一版只做字符串 LIKE,而故障注入当场证明它是空的
-- (把调用换回内联的 COALESCE 之后,函数体里那句解释性注释仍然写着这个名字,
--  于是断言照样通过)—— 现在它先剥掉注释再比。
--
-- 【解析不出来返回 NULL 是刻意的】hr_alerts 的 review_no_reviewer 一支专门等这种情况。
-- 悄悄塞一个人进去才是错的。
--
-- NOTE: introduced by db/migrations/2026-08-27-probation1-a-door-for-the-probation-review.sql.

CREATE OR REPLACE FUNCTION public.resolve_review_reviewer(p_employee_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$
    -- 【三级解析】部门经理 → 本人就是部门经理时取【上级部门】的经理 → 再不行 NULL。
    -- 每一级都排除"解析到本人":自己不能评自己
    -- (performance_reviews_not_self_review 这条 CHECK 也会拦,但拦在这里更早)。
    -- NULL 【不是】被忽略 —— hr_alerts 的 review_no_reviewer 一支会把它顶出来。
    SELECT COALESCE(
               NULLIF(d.manager_employee_id, e.id),
               NULLIF(pd.manager_employee_id, e.id)
           )
      FROM employees e
      LEFT JOIN departments d  ON d.id = e.department_id
      LEFT JOIN departments pd ON pd.id = d.parent_department_id
     WHERE e.id = p_employee_id;
$function$;

COMMENT ON FUNCTION public.resolve_review_reviewer(uuid) IS
    'PROBATION-1:「谁评估这个人」的【唯一一处】定义 —— 部门经理 → 上级部门经理 → NULL,每一级排除本人。两个调用方:open_review_cycle(年度轮)与 open_probation_review(试用期)。抽出来之前它只写在 open_review_cycle 的 INSERT ... SELECT 里;本刀要第二个调用方,而复制它就是同一条规矩的两份实现。解析不出来返回 NULL 是刻意的:hr_alerts 的 review_no_reviewer 一支专门等这种情况,悄悄塞一个人进去才是错的。';