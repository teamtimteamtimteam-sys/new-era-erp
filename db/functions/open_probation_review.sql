-- db/functions/open_probation_review.sql
-- PROBATION-1(2026-08-27):试用期转正评估的【那扇门】—— 在它之前一扇都没有。
--
-- 【它之前有多缺】performance_reviews 的唯一写入者是 open_review_cycle,
-- 而那支只造 review_type='annual' 且明确排除试用期员工;
-- performance_reviews_cycle_shape 要求 probation ⇒ cycle_id IS NULL,
-- 而它永远写 cycle_id —— 所以它在结构上也造不出一份试用期评估。
-- app 里没有任何一处 INSERT performance_reviews(saveHrDecision 只 UPDATE)。
-- ★ 最尖锐的证据:冒烟脚本必须【直接 POST 到 REST】才造得出那一行来测页面。★
--
-- 【为什么不是给 open_review_cycle 加参数】见函数注释:两种形状,不是一种的变体。
-- 【期间不编默认值】probation_end_date 为空就按名拒 —— 那个日期正是转正决定
-- 依据的事实本身。实测线上 4 个试用期员工【全部】没有填。
--
-- NOTE: introduced by db/migrations/2026-08-27-probation1-a-door-for-the-probation-review.sql.

CREATE OR REPLACE FUNCTION public.open_probation_review(p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_e        employees%ROWTYPE;
    v_id       uuid := gen_random_uuid();
    v_reviewer uuid;
    v_ex_id    uuid;
    v_ex_stat  text;
BEGIN
    -- 与 open_review_cycle 同一道门:发起一次转正评估是 HR 的动作。
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_e FROM employees
     WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', COALESCE(p_employee_id::text, '?');
    END IF;

    -- 【只对在试用期的人成立】转正评估对一个已转正/已离职的人没有意义,
    -- 而 approve_review 的 confirm 分支会去改 employment_status —— 对着错的人跑
    -- 会把一个已经在职的人重新"转正"一次。
    IF v_e.employment_status <> 'probation' THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_ON_PROBATION|%|%', v_e.code, v_e.employment_status;
    END IF;

    -- ★【不给日期编默认值】★ period_start / period_end 是 NOT NULL,
    -- 而 probation_end_date 可以为空(实测线上 4 个试用期员工【全部】为空)。
    -- 拿 CURRENT_DATE 顶上去,就是替人凭空定下试用期的终点 ——
    -- 而那个日期正是转正决定所依据的事实本身,也是 hr_alerts 三支的锚点。
    -- 本仓库对"决定期间的日期"已经有一条规矩:要么有,要么按名拒,绝不默认。
    IF v_e.probation_end_date IS NULL THEN
        RAISE EXCEPTION 'PROBATION_END_DATE_NOT_SET|%', v_e.code;
    END IF;

    -- period_end >= period_start 是表上的 CHECK(performance_reviews_period_shape)。
    -- 先在这里按名拒,免得读到的是一串约束名。
    IF v_e.probation_end_date < v_e.hire_date THEN
        RAISE EXCEPTION 'PROBATION_PERIOD_INVALID|%|%|%',
            v_e.code, v_e.hire_date::text, v_e.probation_end_date::text;
    END IF;

    SELECT id, status INTO v_ex_id, v_ex_stat
      FROM performance_reviews
     WHERE employee_id = p_employee_id
       AND review_type = 'probation'
       AND status <> 'void'
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'PROBATION_REVIEW_EXISTS|%|%', v_e.code, v_ex_stat;
    END IF;

    v_reviewer := resolve_review_reviewer(p_employee_id);

    INSERT INTO performance_reviews
        (id, employee_id, review_type, cycle_id, period_start, period_end,
         reviewer_employee_id, status, created_by)
    VALUES (v_id, p_employee_id, 'probation', NULL, v_e.hire_date, v_e.probation_end_date,
            v_reviewer, 'draft', auth.uid());

    RETURN jsonb_build_object(
        'review_id',            v_id,
        'employee_code',        v_e.code,
        'period_start',         v_e.hire_date,
        'period_end',           v_e.probation_end_date,
        'reviewer_employee_id', v_reviewer,
        -- 【解析不出评估人不是失败】它是一件要被看见的事,所以照直报出来,
        -- 由 hr_alerts 的 review_no_reviewer 一支接手催。
        'reviewer_resolved',    (v_reviewer IS NOT NULL),
        'status',               'draft');
END;
$function$;

COMMENT ON FUNCTION public.open_probation_review(uuid) IS
    'PROBATION-1:从产品内部造出一份试用期评估 —— 这条路此前【一扇门都没有】(open_review_cycle 只造 annual 且排除试用期员工;cycle_shape 要求 probation ⇒ cycle_id IS NULL,所以它结构上也造不出;app 里没有任何一处 INSERT performance_reviews;冒烟必须直接 POST 到 REST 才测得了页面)。期间 = hire_date → probation_end_date,【取不到就按名拒】(PROBATION_END_DATE_NOT_SET)——替人编一个试用期终点,就是凭空造出转正决定所依据的那个事实。评估人走 resolve_review_reviewer(与年度轮同一处),解析不出留 NULL 并如实报出,由 hr_alerts 的 review_no_reviewer 接手。五条按名拒绝:EMPLOYEE_NOT_FOUND / EMPLOYEE_NOT_ON_PROBATION / PROBATION_END_DATE_NOT_SET / PROBATION_PERIOD_INVALID / PROBATION_REVIEW_EXISTS。人工发起,不自动生成(Tim 2026-08-27):一行写着某人名字、还指派了评估人的记录自己冒出来,不是一件小事。';