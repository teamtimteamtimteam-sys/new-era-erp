-- db/tables/review_goals.sql
-- 评估的目标行:期初说好要做成什么,以及做成了什么。
--
-- "Measure Outcomes, Not Time" —— 【没有权重、没有逐条打分】。
-- 一旦有了分数,谈话就会围着分数转,而不是围着结果转;整份评估只有一个档位
-- (performance_reviews.rating_code)和一段书面结论,那才是要签字的东西。
--
-- ON DELETE CASCADE:目标行依附于评估。评估本身从不硬删(靠 void 作废),
-- 这条级联是给"评估还在草稿阶段就被整份删掉"那种情形兜底的。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.review_goals (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    review_id                uuid NOT NULL REFERENCES public.performance_reviews (id) ON DELETE CASCADE,
    sequence                 integer NOT NULL,
    objective_text           text NOT NULL,          -- 期初定下的期望
    employee_result_text     text,                   -- 自评阶段由员工写
    reviewer_assessment_text text,                   -- 评估人写
    created_at               timestamptz NOT NULL DEFAULT now(),
    created_by               uuid DEFAULT auth.uid(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    updated_by               uuid DEFAULT auth.uid(),
    -- ── HR-3c 追加:目标可以带数字,【全部可选】────────────────────────────────
    target_value             numeric,   -- 期初定下的量化指标
    actual_value             numeric,   -- 期末实际值;自评期本人写,draft/submitted 评估人写
    unit                     text,      -- 单位;填了任一数字就必须有
    UNIQUE (review_id, sequence),
    -- 【光有数字没有单位不成其为指标】95 是什么?百分比、件、天、还是分钟?
    CONSTRAINT review_goals_unit_required CHECK (
        (target_value IS NULL AND actual_value IS NULL)
        OR (unit IS NOT NULL AND btrim(unit) <> '')
    ),
    CONSTRAINT review_goals_objective_not_blank CHECK (btrim(objective_text) <> '')
);

CREATE INDEX idx_review_goals_review ON public.review_goals (review_id);

CREATE TRIGGER trg_review_goals_updated_at
    BEFORE UPDATE ON public.review_goals
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- RLS:与 performance_reviews 逐条对应,经 review_id 上溯。
ALTER TABLE public.review_goals ENABLE ROW LEVEL SECURITY;

-- HR-3b:与 performance_reviews 同步 —— 一般性读取要 module.hr.view AND data.view_reviews。
-- 目标行里就是自评与评语的正文,不能比它依附的评估更宽。
CREATE POLICY "review_goals select by permission"
    ON public.review_goals AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view') AND has_permission('data.view_reviews'));

CREATE POLICY "review_goals select as reviewer"
    ON public.review_goals AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM performance_reviews r
                   WHERE r.id = review_goals.review_id
                     AND r.reviewer_employee_id = current_user_employee()));

CREATE POLICY "review_goals select own approved"
    ON public.review_goals AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM performance_reviews r
                   WHERE r.id = review_goals.review_id
                     AND r.employee_id = current_user_employee()
                     AND r.status IN ('approved','acknowledged')));

CREATE POLICY "review_goals insert by permission"
    ON public.review_goals AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "review_goals update by permission"
    ON public.review_goals AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "review_goals delete by permission"
    ON public.review_goals AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));
GRANT SELECT (target_value, actual_value, unit) ON public.review_goals TO authenticated;
COMMENT ON COLUMN public.review_goals.target_value IS
    '期初定下的量化指标。【可选】—— 数字编不出来就不编,这一行仍然只靠 objective_text 说清楚。';
COMMENT ON COLUMN public.review_goals.actual_value IS
    '期末的实际值。自评阶段由【本人】写(save_self_assessment),draft/submitted 阶段由【评估人或 HR】写(set_goal_actual_value)。两条路都碰不到 target_value 与 unit。';
COMMENT ON COLUMN public.review_goals.unit IS
    '指标的单位(%、件、天……)。只要填了 target_value 或 actual_value 就必须有单位:一个没有单位的数字不是指标,是一个会被读错的数。';
