-- db/migrations/2026-08-03-hr3d-fu1-reviewer-write-path.sql
-- HR-3d 前置:让【评估人】真的能写他自己的那几个字段。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么必须先做这一步】实测(零模块权限的部门经理,真实会话):
--     author_goal                 CANNOT: 42501
--     edit objective/target/unit  CANNOT: 0 rows (RLS)
--     write reviewer_assessment   CANNOT: 0 rows (RLS)
--     set rating + summary        CANNOT: 0 rows (RLS)
--     open_for_self_assessment    CAN
--     submit_review               BLOCKED: RATING_REQUIRED
--     approve_review              CANNOT: PERMISSION_DENIED
--
-- HR-3a 把 review_goals 定成"HR 模块权限可写、评估人【只读】",于是评估人是只读的,
-- 而 submit_review 虽然在门口放行了他,却【永远过不去】—— 它要求评级与书面结论,
-- 那两样恰恰是他写不了的。评估人的入口页照现状建出来,只能看,不能评。
--
-- 【边界照旧写在函数里,不写在策略里】每个函数都是 SECURITY DEFINER,
-- 各自检查"调用者是不是这一行的 reviewer_employee_id"(或持 module.hr.edit),
-- 并且【只 UPDATE 评估人自己的那几列】。碰不到的东西是结构性的,不是靠自觉:
--   probation_outcome / new_monthly_salary / salary_effective_date /
--   employee_id / reviewer_employee_id / cycle_id / 期间 / status。
--
-- 【状态分段】
--   objective_text / target_value / unit  —— 只在 draft 可改。
--     自评一旦开启,被评估人就在对着这些目标作答;中途改题会让他的回答对不上题。
--   reviewer_assessment_text / rating_code / summary_text —— draft 与 self_review 可写。
--     真实流程是:自评定稿后评估人才落笔,而那时状态仍是 self_review。
--   submitted 之后【全部只读】—— 提交出去的东西与被批准的东西必须是同一份。
--
-- 【评估人仍然提交不了试用期评估】probation_outcome 不在他能写的集合里,
-- 而试用期评估自 submitted 起必须有结论。这是【有意的】:转正与否是 HR 的决定,
-- 不是直线经理的。试用期评估因此仍然由 HR 填结论、HR 提交。
-- ════════════════════════════════════════════════════════════════════════════
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【顺带补掉一个三值逻辑的洞 —— 是跑真实会话才发现的,不是读策略文本发现的】
-- 一个【与这份评估毫无关系】、零模块权限的员工,曾经可以把别人的评估推进自评状态:
--     open_for_self_assessment    *** ALLOWED ***
-- 原因是守卫写成
--     IF NOT (has_permission('module.hr.edit')
--             OR is_reviewer_of(v_r.reviewer_employee_id)) THEN ...
-- reviewer_employee_id 为 NULL 时,`NULL = <uuid>` 得到的是 NULL 而不是 false,
-- 于是 NOT(false OR NULL) = NULL,IF 不触发,守卫整个放行。
-- current_user_employee() 为 NULL(账号没关联员工档案)时同理。
--
-- 【这不是边角情形】open_review_cycle 本来就会造出评估人为空的行 ——
-- review_no_reviewer 那条提醒存在的全部理由就是它们。每开一轮评估,
-- 就产生一批任何登录用户都能推动的评估。
--
-- submit_review 与 set_goal_actual_value 当时没被攻破,但那是【碰巧】:
-- 一个被自己的 REVIEWER_REQUIRED 挡下,一个被状态门挡下。同一个洞在 draft 下照样能写。
-- 三个函数一并改走 is_reviewer_of。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.is_reviewer_of(p_reviewer_employee_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 任何一边是 NULL 都判 false。【全库只此一处】判断"我是不是这一行的评估人"。
    SELECT p_reviewer_employee_id IS NOT NULL
       AND current_user_employee() IS NOT NULL
       AND p_reviewer_employee_id = current_user_employee();
$function$;

COMMENT ON FUNCTION public.is_reviewer_of(uuid) IS
    '调用者是不是这一行的评估人。【NULL 一律判 false】—— 直接写 '
    'reviewer_employee_id = current_user_employee() 会在任一边为 NULL 时得到 NULL,'
    '让 NOT(... OR NULL) 变成 NULL,守卫整个放行。没有指派评估人的评估因此曾经人人可写。';

-- 共用的守卫:调用者要么是这一行的评估人,要么持 module.hr.edit。
--
-- 【签名里只用内建类型】原来写的是 RETURNS performance_reviews(表的复合类型),
-- 那在【空库重建】时必然失败:重放顺序是 函数 → 表,而 check_function_bodies=off
-- 只豁免函数体,【不豁免签名】—— 建函数的那一刻返回类型必须已经存在。
-- check_mirrors 看不见这个问题:它把镜像重放进 mir 架构,而未加架构前缀的
-- performance_reviews 会顺着 search_path 解析到【线上的 public 表】,于是一路绿灯。
-- 是 verify_rebuild(真的建进一个空库)把它抓出来的。
CREATE OR REPLACE FUNCTION public.require_reviewer_of(p_review_id uuid, p_allowed_status text[])
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- %ROWTYPE 在【函数体】里,check_function_bodies=off 豁免的正是这里,所以没问题。
DECLARE v_r performance_reviews%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;
    IF NOT (has_permission('module.hr.edit')
            OR is_reviewer_of(v_r.reviewer_employee_id)) THEN
        RAISE EXCEPTION 'NOT_REVIEW_REVIEWER';
    END IF;
    IF NOT (v_r.status = ANY (p_allowed_status)) THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;
END;
$function$;

-- ── 目标行:新增 / 修改 / 删除,只在 draft ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.add_review_goal(p_review_id uuid, p_objective_text text, p_target_value numeric DEFAULT NULL::numeric, p_unit text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_seq integer; v_id uuid;
BEGIN
    PERFORM require_reviewer_of(p_review_id, ARRAY['draft']);
    IF p_objective_text IS NULL OR btrim(p_objective_text) = '' THEN
        RAISE EXCEPTION 'OBJECTIVE_REQUIRED';
    END IF;
    SELECT COALESCE(max(sequence), 0) + 1 INTO v_seq FROM review_goals WHERE review_id = p_review_id;
    INSERT INTO review_goals (review_id, sequence, objective_text, target_value, unit)
    VALUES (p_review_id, v_seq, btrim(p_objective_text), p_target_value, NULLIF(btrim(p_unit), ''))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('goal_id', v_id, 'review_id', p_review_id, 'sequence', v_seq);
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_review_goal(p_goal_id uuid, p_objective_text text, p_target_value numeric DEFAULT NULL::numeric, p_unit text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_g review_goals%ROWTYPE;
BEGIN
    SELECT * INTO v_g FROM review_goals WHERE id = p_goal_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOAL_NOT_FOUND|%', COALESCE(p_goal_id::text,'?'); END IF;
    PERFORM require_reviewer_of(v_g.review_id, ARRAY['draft']);
    IF p_objective_text IS NULL OR btrim(p_objective_text) = '' THEN
        RAISE EXCEPTION 'OBJECTIVE_REQUIRED';
    END IF;
    -- 【只碰这三列】employee_result_text 与 actual_value 是被评估人的,不在这里。
    UPDATE review_goals
    SET objective_text = btrim(p_objective_text),
        target_value   = p_target_value,
        unit           = NULLIF(btrim(p_unit), '')
    WHERE id = p_goal_id;
    RETURN jsonb_build_object('goal_id', p_goal_id, 'review_id', v_g.review_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.remove_review_goal(p_goal_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_g review_goals%ROWTYPE;
BEGIN
    SELECT * INTO v_g FROM review_goals WHERE id = p_goal_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOAL_NOT_FOUND|%', COALESCE(p_goal_id::text,'?'); END IF;
    -- 【只在 draft】自评开始之后删题,等于把被评估人已经写下的回答一起抹掉。
    PERFORM require_reviewer_of(v_g.review_id, ARRAY['draft']);
    DELETE FROM review_goals WHERE id = p_goal_id;
    RETURN jsonb_build_object('goal_id', p_goal_id, 'review_id', v_g.review_id, 'removed', true);
END;
$function$;

-- ── 评估人的评语:draft 与 self_review ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_goal_assessment(p_goal_id uuid, p_reviewer_assessment_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_g review_goals%ROWTYPE;
BEGIN
    SELECT * INTO v_g FROM review_goals WHERE id = p_goal_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOAL_NOT_FOUND|%', COALESCE(p_goal_id::text,'?'); END IF;
    -- 自评定稿之后评估人才落笔,而那时状态仍是 self_review,所以两个状态都要收。
    PERFORM require_reviewer_of(v_g.review_id, ARRAY['draft','self_review']);
    UPDATE review_goals SET reviewer_assessment_text = p_reviewer_assessment_text WHERE id = p_goal_id;
    RETURN jsonb_build_object('goal_id', p_goal_id, 'review_id', v_g.review_id);
END;
$function$;

-- ── 评级与书面结论:draft 与 self_review ────────────────────────────────────
-- 【刻意不收 probation_outcome、不收薪酬、不动 status】
-- 转正与否是 HR 的决定;调薪同理;提交走 submit_review,批准走 approve_review。
CREATE OR REPLACE FUNCTION public.set_review_conclusion(p_review_id uuid, p_rating_code text, p_summary_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_reviewer_of(p_review_id, ARRAY['draft','self_review']);
    IF p_rating_code IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM review_rating_scale s
                       WHERE s.code = p_rating_code AND s.is_active) THEN
        RAISE EXCEPTION 'RATING_NOT_FOUND|%', p_rating_code;
    END IF;
    UPDATE performance_reviews
    SET rating_code  = p_rating_code,
        summary_text = p_summary_text
    WHERE id = p_review_id;
    RETURN jsonb_build_object('review_id', p_review_id, 'rating_code', p_rating_code);
END;
$function$;

-- 三个既有函数改走 is_reviewer_of(理由见文件头)。
CREATE OR REPLACE FUNCTION public.open_for_self_assessment(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r        performance_reviews%ROWTYPE;
    v_reopened boolean := false;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    IF NOT (has_permission('module.hr.edit')
            OR is_reviewer_of(v_r.reviewer_employee_id)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    IF v_r.status NOT IN ('draft','self_review') THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    v_reopened := (v_r.status = 'self_review' AND v_r.self_assessment_submitted_at IS NOT NULL);

    UPDATE performance_reviews
    SET status = 'self_review', self_assessment_submitted_at = NULL
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'self_review',
                              'previous_status', v_r.status, 'reopened', v_reopened);
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_goal_actual_value(p_goal_id uuid, p_actual_value numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_g review_goals%ROWTYPE;
    v_r performance_reviews%ROWTYPE;
BEGIN
    SELECT * INTO v_g FROM review_goals WHERE id = p_goal_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOAL_NOT_FOUND|%', COALESCE(p_goal_id::text,'?'); END IF;
    SELECT * INTO v_r FROM performance_reviews WHERE id = v_g.review_id;

    IF NOT (has_permission('module.hr.edit')
            OR is_reviewer_of(v_r.reviewer_employee_id)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    IF v_r.status NOT IN ('draft','submitted') THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    UPDATE review_goals SET actual_value = p_actual_value WHERE id = p_goal_id;

    RETURN jsonb_build_object('goal_id', p_goal_id, 'actual_value', p_actual_value,
                              'review_id', v_g.review_id, 'status', v_r.status);
END;
$function$;

CREATE OR REPLACE FUNCTION public.submit_review(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r      performance_reviews%ROWTYPE;
    v_goals  integer;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    IF NOT (has_permission('module.hr.edit')
            OR is_reviewer_of(v_r.reviewer_employee_id)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    -- self_review 是可选的一步,所以两个入口状态都收
    IF v_r.status NOT IN ('draft','self_review') THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    IF v_r.reviewer_employee_id IS NULL THEN
        RAISE EXCEPTION 'REVIEWER_REQUIRED';
    END IF;
    IF v_r.rating_code IS NULL THEN
        RAISE EXCEPTION 'RATING_REQUIRED';
    END IF;
    IF v_r.summary_text IS NULL OR btrim(v_r.summary_text) = '' THEN
        RAISE EXCEPTION 'SUMMARY_REQUIRED';
    END IF;
    IF v_r.review_type = 'probation' AND v_r.probation_outcome IS NULL THEN
        RAISE EXCEPTION 'PROBATION_OUTCOME_REQUIRED';
    END IF;

    SELECT count(*) INTO v_goals FROM review_goals WHERE review_id = p_review_id;
    IF v_goals = 0 THEN
        RAISE EXCEPTION 'GOALS_REQUIRED';
    END IF;

    UPDATE performance_reviews
    SET status = 'submitted', submitted_at = now(), submitted_by = auth.uid()
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'submitted',
                              'rating_code', v_r.rating_code, 'goals', v_goals);
END;
$function$;

COMMIT;
