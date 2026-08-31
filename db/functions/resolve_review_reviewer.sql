-- db/functions/resolve_review_reviewer.sql
-- PROBATION-1:「谁评估这个人」的【唯一一处】定义。两个调用方:open_review_cycle
-- 与 open_probation_review;db/fixtures/136 的 H 臂做目录断言。
-- CLEANUP-A(2026-08-31):加 module.hr.view 判据,而且【RAISE 不返回 NULL】——
-- 本支的 NULL 已经有主("解析不出评估人",hr_alerts 的 review_no_reviewer 等着它);
-- 让无权限也返回 NULL,那条告警会对一个其实有经理的人响。

CREATE OR REPLACE FUNCTION public.resolve_review_reviewer(p_employee_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_reviewer uuid;
BEGIN
    IF NOT has_permission('module.hr.view'::text) THEN
        RAISE EXCEPTION 'REVIEWER_RESOLUTION_PERMISSION_DENIED|%', 'module.hr.view'
          USING HINT = '「谁评估这个人」要读部门与上级部门 —— 那要 HR 模块的查看权限。'
                       '这【不是】"解析不出评估人"(那件事本支用 NULL 表示,'
                       'hr_alerts 的 review_no_reviewer 专门等着它),所以不能返回 NULL。';
    END IF;

    -- 【三级解析】部门经理 → 本人就是部门经理时取【上级部门】的经理 → 再不行 NULL。
    -- 每一级都排除"解析到本人":自己不能评自己。
    -- NULL 【不是】被忽略 —— hr_alerts 的 review_no_reviewer 一支会把它顶出来。
    SELECT COALESCE(
               NULLIF(d.manager_employee_id, e.id),
               NULLIF(pd.manager_employee_id, e.id)
           )
      INTO v_reviewer
      FROM employees e
      LEFT JOIN departments d  ON d.id = e.department_id
      LEFT JOIN departments pd ON pd.id = d.parent_department_id
     WHERE e.id = p_employee_id;

    RETURN v_reviewer;
END
$function$;

COMMENT ON FUNCTION public.resolve_review_reviewer(p_employee_id uuid) IS
    'CLEANUP-A:「谁评估这个人」的唯一一处定义 —— 部门经理 → 上级部门经理 → NULL,每一级排除本人。两个调用方:open_review_cycle 与 open_probation_review。【无权限时 RAISE,不返回 NULL】因为本支的 NULL 已经有主:它是"解析不出评估人",hr_alerts 的 review_no_reviewer 专门等着它;让无权限也返回 NULL,那条告警会对一个其实有经理的人响,而真正的原因永远不上屏。判据 module.hr.view(departments 的 SELECT 策略)。本人读自己现在得到按名拒绝而不是 NULL —— 从错误答案换成一句说明,是 R1 被满足,不是丢了功能。';
