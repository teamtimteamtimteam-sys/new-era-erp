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
    UNIQUE (review_id, sequence),
    CONSTRAINT review_goals_objective_not_blank CHECK (btrim(objective_text) <> '')
);

CREATE INDEX idx_review_goals_review ON public.review_goals (review_id);

CREATE TRIGGER trg_review_goals_updated_at
    BEFORE UPDATE ON public.review_goals
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- RLS:与 performance_reviews 逐条对应,经 review_id 上溯。
ALTER TABLE public.review_goals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "review_goals select by permission"
    ON public.review_goals AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));

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
