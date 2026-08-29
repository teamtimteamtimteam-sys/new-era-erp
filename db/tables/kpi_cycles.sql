-- db/tables/kpi_cycles.sql
-- KPI-1:KPI 的考核周期 —— 0–5 打分、加权、M3 / M6 两道关口(规格 §11 第 4 步)。
--
-- ★★【为什么【不】复用 review_cycles,尽管形状一模一样】★★(Tim 2026-08-29 裁定)
--   `review_cycles` 今天 0 行,列也逐个对得上(name / period_start / period_end /
--   due_date / status)—— 复用在技术上是免费的。**而那正是危险所在:**
--   **共用周期,是两个模块悄悄变成一个的方式。** 第一次有人开一个 HR 评估周期,
--   每一块 KPI 屏幕都会继承它,于是【Tim 裁过的"两者并存"会被一条没人再读过的外键推翻】。
--   五个重复的列,对上一次永久的耦合 —— 这不是一个接近的取舍。
--   **形状是刻意保持一致的**,好让将来真要合并时代价还是小的。
--
-- 【两者为什么必须并存,而不是二选一】(规格 §12.2,已由 Tim 裁定为"另起")
--   `review_goals` 的表注自己写着:**「没有权重、没有逐条打分」**,
--   理由是「一旦有了分数,谈话就会围着分数转,而不是围着结果转」。
--   而 KPI 的全部内容就是 0–5 乘权重。**两者是设计上的对立面,不是偶然的重复。**
--   本模块因此【不读也不写】review_goals,尤其不碰它那三条 SELECT 策略 ——
--   其中一条是「本人只在评估 approved/acknowledged 之后才看得见自己的目标」,
--   那是自评的可见性机制,KPI 不替代它、也不许放宽它。
--
-- NOTE: introduced by db/migrations/2026-08-29-kpi1-positions-and-the-kpi-framework.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.kpi_cycles (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name         text NOT NULL CHECK (btrim(name) <> ''),
    period_start date NOT NULL,
    period_end   date NOT NULL,
    due_date     date NOT NULL,
    status       text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','open','closed')),
    -- ★【M3 / M6 两道关口】★ 原表第一页:「Use Month 3 and Month 6 gates; review monthly.」
    --   月度打分的周期 gate 为空;正式关口的那两次各自标出来。
    --   规格第六章说得更细:M3 是 launch-readiness review,M6 是 commissioning /
    --   operating-readiness review 与第一次正式考核。
    gate         text CHECK (gate IS NULL OR gate IN ('M3','M6')),
    notes        text,
    deleted_at   timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    CONSTRAINT kpi_cycles_period_order CHECK (period_end >= period_start)
);

CREATE INDEX idx_kpi_cycles_open ON public.kpi_cycles (period_start DESC) WHERE deleted_at IS NULL;

ALTER TABLE public.kpi_cycles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "kpi_cycles select by permission"
    ON public.kpi_cycles AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));
CREATE POLICY "kpi_cycles insert by permission"
    ON public.kpi_cycles AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'::text));
CREATE POLICY "kpi_cycles update by permission"
    ON public.kpi_cycles AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit'::text)) WITH CHECK (has_permission('module.hr.edit'::text));

COMMENT ON TABLE public.kpi_cycles IS
    'KPI-1:KPI 的考核周期。★**刻意不复用 review_cycles,尽管形状一模一样**★(Tim 2026-08-29):共用周期是两个模块悄悄变成一个的方式 —— 第一次有人开一个 HR 评估周期,每块 KPI 屏幕都会继承它,而 Tim 裁过的"两者并存"就被一条没人再读过的外键推翻了。五个重复的列 vs 一次永久的耦合。**形状刻意保持一致**,好让将来真要合并时代价还是小的。两者必须并存的理由在 review_goals 自己的表注里:它写着「没有权重、没有逐条打分」,而 KPI 的全部内容就是 0–5 乘权重 —— **设计上的对立面,不是偶然的重复**。本模块不读也不写 review_goals,尤其不碰它那条「本人只在 approved/acknowledged 之后才看得见自己目标」的自评可见性策略。';

COMMENT ON COLUMN public.kpi_cycles.gate IS
    'KPI-1:M3 / M6 两道正式关口(原表第一页:Use Month 3 and Month 6 gates; review monthly)。月度打分的周期这里为空 —— 关口不是"又一次打分",第六章给它们各自的判断题:M3 决定是否 regulatory-ready / equipment-ready / commercially ready / financially protected,M6 决定是否 ready for sustained controlled operations。';
