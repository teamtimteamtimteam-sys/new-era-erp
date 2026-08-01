-- db/functions/open_review_cycle.sql
-- 开启一轮年度评估:每名【在职且已转正】(employment_status = 'active')的员工一份 draft,
-- 评估人默认取部门经理;经理本人那一份没有合法默认值(自己不能评自己)⇒ 留空,由 HR 指派。
-- 试用期、离职、以及在离职通知期('notice')的员工都不生成。
-- 【幂等】NOT EXISTS + 部分唯一索引双保险,重跑不会产生第二份。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql.

CREATE OR REPLACE FUNCTION public.open_review_cycle(p_cycle_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c        review_cycles%ROWTYPE;
    v_created  integer;
    v_total    integer;
    v_noreviewer integer;
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
               -- 部门经理;经理本人那一份没有合法默认值(自己不能评自己)⇒ 留空
               NULLIF(d.manager_employee_id, e.id),
               'draft'
        FROM employees e
        LEFT JOIN departments d ON d.id = e.department_id
        WHERE e.deleted_at IS NULL
          -- 【'active' = 在职且已转正】。probation 与 separated 按题意排除;
          -- 'notice'(在离职通知期内)同样不生成 —— 它不是 active,而且一份
          -- 走完流程要几周的年度评估对一个正在走人的人没有意义。
          AND e.employment_status = 'active'
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

    RETURN jsonb_build_object(
        'cycle_id', p_cycle_id, 'cycle_name', v_c.name, 'status', 'open',
        'created', v_created, 'total_reviews', v_total,
        'without_reviewer', v_noreviewer);
END;
$function$
;