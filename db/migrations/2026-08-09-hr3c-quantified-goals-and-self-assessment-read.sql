-- db/migrations/2026-08-09-hr3c-quantified-goals-and-self-assessment-read.sql
-- HR cut 3c(数据层部分):目标行可以带数字,以及【自评期间被评估人读得到目标】。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本切修的是 HR-3b 定错的一条规则】
-- HR-3b 写死了"被评估人在批准之前什么都读不到"。那条规则让自评【根本没法写】——
-- save_self_assessment 要求一个人对着他看不见的目标写结果。
-- 所以这里开一条【窄到只够写自评】的读路径:
--   status = 'self_review' 且是本人时,看得见目标、指标、单位、以及【他自己写的】
--   结果与实际值;看不见评级、书面结论、评估人的评语、试用期结论、任何薪酬字段。
--   在此之前(draft)与在此之后(submitted 未批准)仍然【一行都读不到】。
--
-- 【为什么是视图,不是放宽 RLS】RLS 是【行级】的:放开这一行,评级和评语也跟着开。
-- 这正是 cut 2b 立下遮蔽机制的理由 —— 属主权限视图 + 在视图体里把行谓词原样加回来。
-- 所以自评的读路径是两个视图,而不是第四条 policy。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【字段契约 / FIELD CONTRACT】HR-3d 要照着这张表去画屏幕,不能靠试出来 ——
-- 试错会试对九个格子、试错一个,而错的那个多半是薪酬或评级。
--
--                        │ 目标/指标 │ 本人结果 │ 评语 │ 评级+结论 │ 试用结论 │ 薪酬
--  ─────────────────────┼──────────┼─────────┼─────┼──────────┼─────────┼──────
--  本人 draft            │    ✗     │    ✗    │  ✗  │    ✗     │    ✗    │  ✗
--  本人 self_review      │    ✓     │    ✓    │  ✗  │    ✗     │    ✗    │  ✗
--  本人 submitted        │    ✗     │    ✗    │  ✗  │    ✗     │    ✗    │  ✗
--  本人 approved/ack     │    ✓     │    ✓    │  ✓  │    ✓     │    ✓    │  ✓(本人让路)
--  评估人(无 hr 权限)   │    ✓     │    ✓    │  ✓  │    ✓     │    ✓    │  ✗(无 view_pay)
--  hr / admin            │    ✓     │    ✓    │  ✓  │    ✓     │    ✓    │  ✓
--
--  * "本人 approved/ack" 走既有的 performance_reviews / review_goals 策略 +
--    performance_reviews_masked;薪酬那一格是遮蔽视图对本人的让路(HR-3a 的设计)。
--  * "评估人" 走 select as reviewer 那条策略;薪酬被 data.view_pay 挡住。
--  * "本人 self_review" 只走本切新增的两个视图,基表策略【一个字都没改】。
--  * 未持 data.view_reviews 的角色(如 auditor)在任何状态下都读不到正文 —— HR-3b。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- B1. 目标行可以带数字 —— 【全部可选】
-- ════════════════════════════════════════════════════════════════════════════
-- 一个目标在"编一个数字出来"和"就用文字说清楚"之间,应当可以选后者。
-- 【没有权重、没有逐条得分、没有自动合计】—— 评级仍然是评估人的判断,
-- 不是算出来的。一旦有了总分,谈话就会围着分数转,而不是围着结果转。
ALTER TABLE public.review_goals
    ADD COLUMN target_value numeric,
    ADD COLUMN actual_value numeric,
    ADD COLUMN unit text;

-- 【光有数字没有单位不成其为指标】95 是什么?百分比、件、天、还是分钟?
ALTER TABLE public.review_goals
    ADD CONSTRAINT review_goals_unit_required CHECK (
        (target_value IS NULL AND actual_value IS NULL)
        OR (unit IS NOT NULL AND btrim(unit) <> '')
    );

COMMENT ON COLUMN public.review_goals.target_value IS
    '期初定下的量化指标。【可选】—— 数字编不出来就不编,这一行仍然只靠 objective_text 说清楚。';
COMMENT ON COLUMN public.review_goals.actual_value IS
    '期末的实际值。自评阶段由【本人】写(save_self_assessment),draft/submitted 阶段由'
    '【评估人或 HR】写(set_goal_actual_value)。两条路都碰不到 target_value 与 unit。';
COMMENT ON COLUMN public.review_goals.unit IS
    '指标的单位(%、件、天……)。只要填了 target_value 或 actual_value 就必须有单位:'
    '一个没有单位的数字不是指标,是一个会被读错的数。';

GRANT SELECT (target_value, actual_value, unit) ON public.review_goals TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- B3. 自评期间的读路径 —— 两个属主权限视图,窄到只够写自评
-- ════════════════════════════════════════════════════════════════════════════
-- 【视图体里把谓词原样加回来】(cut 2b 铁律):本人 + 且仅在 self_review。
-- 【列清单就是权限边界】没有出现在 SELECT 里的列,任何人都读不出来 ——
-- rating_code / summary_text / reviewer_assessment_text / probation_outcome /
-- new_monthly_salary / salary_effective_date 一个都不在。
CREATE VIEW public.my_self_assessment WITH (security_invoker = off) AS
 SELECT r.id AS review_id,
    r.employee_id,
    r.review_type,
    r.cycle_id,
    c.name AS cycle_name,
    r.period_start,
    r.period_end,
    r.status,
    r.self_assessment_text,
    r.self_assessment_submitted_at
   FROM performance_reviews r
     LEFT JOIN review_cycles c ON c.id = r.cycle_id
  WHERE r.employee_id = current_user_employee()
    AND r.status = 'self_review'::text;

CREATE VIEW public.my_self_assessment_goals WITH (security_invoker = off) AS
 SELECT g.id AS goal_id,
    g.review_id,
    g.sequence,
    g.objective_text,
    g.target_value,
    g.unit,
    g.employee_result_text,
    g.actual_value
   FROM review_goals g
     JOIN performance_reviews r ON r.id = g.review_id
  WHERE r.employee_id = current_user_employee()
    AND r.status = 'self_review'::text
  ORDER BY g.sequence;

-- ════════════════════════════════════════════════════════════════════════════
-- B2. actual_value 进入"本人可写"的集合 —— 守卫一个字都不放松
-- ════════════════════════════════════════════════════════════════════════════
-- 【结构性保证不变】本函数仍然只 UPDATE 两张表里各自的少数几列,全是静态 SQL、
-- 无一处动态拼接。target_value / unit / objective_text / reviewer_assessment_text /
-- rating_code / summary_text / probation_outcome / 薪酬两列 / status 【依旧够不到】。
-- 变的只是把 actual_value 加进了那个"够得到"的白名单里。
--
-- 【用 ? 判断键是否存在,而不是取值是否为空】—— 不传这个键 = 保持原值;
-- 显式传 null = 清空。少了这个区分,一次只想改文字的保存会把数字抹掉。
CREATE OR REPLACE FUNCTION public.save_self_assessment(p_review_id uuid, p_self_assessment_text text, p_goal_results jsonb DEFAULT NULL::jsonb, p_final boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r       performance_reviews%ROWTYPE;
    v_me      uuid := current_user_employee();
    v_el      jsonb;
    v_goal_id uuid;
    v_n       integer := 0;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    IF v_me IS NULL OR v_r.employee_id IS DISTINCT FROM v_me THEN
        RAISE EXCEPTION 'NOT_REVIEW_SUBJECT';
    END IF;

    IF v_r.status <> 'self_review' THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    IF v_r.self_assessment_submitted_at IS NOT NULL THEN
        RAISE EXCEPTION 'SELF_ASSESSMENT_LOCKED|%', v_r.self_assessment_submitted_at;
    END IF;

    IF p_goal_results IS NOT NULL THEN
        IF jsonb_typeof(p_goal_results) <> 'array' THEN
            RAISE EXCEPTION 'GOAL_RESULTS_NOT_ARRAY';
        END IF;
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_goal_results) LOOP
            v_goal_id := (v_el->>'goal_id')::uuid;
            IF v_goal_id IS NULL THEN
                RAISE EXCEPTION 'GOAL_ID_REQUIRED';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM review_goals g
                           WHERE g.id = v_goal_id AND g.review_id = p_review_id) THEN
                RAISE EXCEPTION 'GOAL_NOT_IN_REVIEW|%', v_goal_id;
            END IF;
            UPDATE review_goals
            SET employee_result_text = CASE WHEN v_el ? 'result_text'
                                            THEN v_el->>'result_text'
                                            ELSE employee_result_text END,
                actual_value         = CASE WHEN v_el ? 'actual_value'
                                            THEN (v_el->>'actual_value')::numeric
                                            ELSE actual_value END
            WHERE id = v_goal_id;
            v_n := v_n + 1;
        END LOOP;
    END IF;

    UPDATE performance_reviews
    SET self_assessment_text = p_self_assessment_text,
        self_assessment_submitted_at = CASE WHEN p_final THEN now() ELSE NULL END
    WHERE id = p_review_id;

    RETURN jsonb_build_object('review_id', p_review_id, 'status', v_r.status,
                              'goals_written', v_n, 'final', p_final,
                              'self_assessment_submitted_at',
                              (SELECT self_assessment_submitted_at FROM performance_reviews
                                WHERE id = p_review_id));
END;
$function$;

-- ── 评估人 / HR 在 draft 与 submitted 阶段填实际值 ──────────────────────────
-- 【自评阶段不走这里】那时 actual_value 归本人写(save_self_assessment);
-- 两条路各管一段状态,不会互相覆盖。
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
            OR v_r.reviewer_employee_id = current_user_employee()) THEN
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

COMMIT;
