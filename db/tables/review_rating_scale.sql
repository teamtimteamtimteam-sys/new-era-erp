-- db/tables/review_rating_scale.sql
-- 评级档位目录。【配置,不是枚举】—— 与 leave_types 同一套路:双语名 + description,
-- is_active 停用而不删除,sort_order 决定呈现次序。加一档、停用一档,都不该再来一次迁移。
--
-- is_probation_pass 是【提示,不是规则】:这一档"通常意味着试用期通过"。
-- approve_review 【不读它】—— 转正与否由 performance_reviews.probation_outcome 明说,
-- 不从评级推导。推导出来的决定没法在单据上签字。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3a-performance-reviews.sql.
-- First-run script (plain CREATEs).

-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 下面的种子是"全新安装的默认值",不是线上快照】
-- 写入策略是特意开的(module.hr.edit 的 insert/update/delete),界面在 HR-3c 落地;HR-3a 的 fixture 已经证明加一档、停用一档都不需要改代码。
-- 所以【线上与本文件不一致是正常的,不是漂移】,check_mirrors.py 不把本表与线上比对。
-- 它只保证镜像这一套自己首尾相顾(本文件引用到的码/科目都存在于对应的种子里)。
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE public.review_rating_scale (
    code              text PRIMARY KEY,
    name_en           text NOT NULL,
    name_zh           text NOT NULL,
    description_en    text,
    description_zh    text,
    sort_order        integer NOT NULL DEFAULT 0,
    is_active         boolean NOT NULL DEFAULT true,
    is_probation_pass boolean NOT NULL DEFAULT false,
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        uuid DEFAULT auth.uid()
);

CREATE TRIGGER trg_review_rating_scale_updated_at
    BEFORE UPDATE ON public.review_rating_scale
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.review_rating_scale ENABLE ROW LEVEL SECURITY;
CREATE POLICY "review_rating_scale select by permission"
    ON public.review_rating_scale AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "review_rating_scale insert by permission"
    ON public.review_rating_scale AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "review_rating_scale update by permission"
    ON public.review_rating_scale AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "review_rating_scale delete by permission"
    ON public.review_rating_scale AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- 四档,sort_order 由高到低排列(升序取出即为 OUTSTANDING → BELOW,同 leave_types 的用法)
INSERT INTO public.review_rating_scale
    (code, name_en, name_zh, description_en, description_zh, sort_order, is_probation_pass) VALUES
    ('OUTSTANDING', 'Outstanding',        '卓越',
     'Consistently exceeded every objective set for the period.',
     '本期各项目标均持续超额达成。', 10, true),
    ('EXCEEDS',     'Exceeds Expectations','超出预期',
     'Exceeded most objectives set for the period.',
     '本期多数目标超出预期达成。', 20, true),
    ('MEETS',       'Meets Expectations', '符合预期',
     'Met the objectives set for the period.',
     '本期目标达成,符合预期。', 30, true),
    ('BELOW',       'Below Expectations', '低于预期',
     'Did not meet the objectives set for the period.',
     '本期目标未达成。', 40, false);

-- ============================================================================
