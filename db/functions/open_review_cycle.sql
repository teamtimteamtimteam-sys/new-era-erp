-- db/functions/open_review_cycle.sql
-- 开启一轮年度评估:每名【在职且已转正】(employment_status = 'active')的员工一份 draft。
-- 试用期、离职、在离职通知期('notice')的员工都不生成;【review_exempt 的整个跳过】
-- (组织架构顶端 —— 不建评估,也就不会报"没有评估人")。
--
-- 【HR-3b:评估人三级解析】部门经理 → 本人就是部门经理时取【上级部门】的经理 → NULL。
-- 每一级都排除"解析到本人"。留 NULL 的那些【不是被忽略了】—— hr_alerts 的
-- review_no_reviewer 一支会在开轮当天就把它们顶出来,好过到 due_date 才发现。
--
-- 【幂等】NOT EXISTS + 部分唯一索引双保险,重跑不会产生第二份。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql;
--       reviewer resolution and review_exempt added by
--       db/migrations/2026-08-04-hr3b-salary-basis-and-review-visibility.sql.

CREATE OR REPLACE FUNCTION public.open_review_cycle(p_cycle_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c          review_cycles%ROWTYPE;
    v_created    integer;
    v_total      integer;
    v_noreviewer integer;
    v_exempt     integer;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_c FROM review_cycles WHERE id = p_cycle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CYCLE_NOT_FOUND|%', COALESCE(p_cycle_id::text, '?');
    END IF;
    IF v_c.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'CYCLE_NOT_FOUND|%', v_c.name;
    END IF;
    IF v_c.status = 'closed' THEN
        RAISE EXCEPTION 'CYCLE_CLOSED|%', v_c.name;
    END IF;

    WITH ins AS (
        INSERT INTO performance_reviews
            (employee_id, review_type, cycle_id, period_start, period_end,
             reviewer_employee_id, status)
        SELECT e.id, 'annual', v_c.id, v_c.period_start, v_c.period_end,
               -- 【E2 三级解析】部门经理 → 本人就是部门经理时取【上级部门】的经理
               -- → 再不行留 NULL(E3 的提醒会把它顶出来,不会悄悄躺着)。
               -- 每一级都排除"解析到本人",因为自己不能评自己(表上的 check 也会拦)。
               COALESCE(
                   NULLIF(d.manager_employee_id, e.id),
                   NULLIF(pd.manager_employee_id, e.id)
               ),
               'draft'
        FROM employees e
        LEFT JOIN departments d  ON d.id = e.department_id
        LEFT JOIN departments pd ON pd.id = d.parent_department_id
        WHERE e.deleted_at IS NULL
          -- 【'active' = 在职且已转正】。probation 与 separated 按题意排除;
          -- 'notice'(在离职通知期内)同样不生成。
          AND e.employment_status = 'active'
          -- 【E1 免评估的整个跳过】不建评估,也就不会有"没有评估人"的提醒。
          AND NOT e.review_exempt
          AND NOT EXISTS (
              SELECT 1 FROM performance_reviews pr
              WHERE pr.employee_id = e.id AND pr.cycle_id = v_c.id AND pr.status <> 'void')
        RETURNING 1
    )
    SELECT count(*) INTO v_created FROM ins;

    UPDATE review_cycles SET status = 'open' WHERE id = p_cycle_id AND status <> 'open';

    SELECT count(*), count(*) FILTER (WHERE reviewer_employee_id IS NULL)
    INTO v_total, v_noreviewer
    FROM performance_reviews WHERE cycle_id = p_cycle_id AND status <> 'void';

    SELECT count(*) INTO v_exempt FROM employees
    WHERE deleted_at IS NULL AND employment_status = 'active' AND review_exempt;

    RETURN jsonb_build_object(
        'cycle_id', p_cycle_id, 'cycle_name', v_c.name, 'status', 'open',
        'created', v_created, 'total_reviews', v_total,
        -- 【故意留在返回值里】没有评估人的份数是要有人去处理的,不是可以忽略的余数。
        'without_reviewer', v_noreviewer,
        'skipped_review_exempt', v_exempt);
END;
$function$
;