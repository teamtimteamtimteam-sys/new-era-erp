-- db/tables/processing_settings.sql
-- EXEC-3a:加工模块的单行配置(形状取自 pricing_settings / METAL-1)。
-- 今天装着工单差异的两个阈值 —— 【两个,不是一个】。
--
-- NOTE: introduced by db/migrations/2026-08-16-exec3a-four-executive-arms.sql.
-- First-run script (plain CREATEs).
--
-- 【RUNTIME CONFIG】这张表运营改得动(编辑面板是 EXEC-3b),所以
-- check_mirrors 不逐行比对它的内容 —— 线上与文件不同【是系统在正常工作】。
-- 但引导那一行必须在,而且列的语义变了要回来重读这个文件(AGENTS.md 那一节)。

CREATE TABLE public.processing_settings (
    id boolean PRIMARY KEY DEFAULT true CHECK (id),
    -- 投入超耗:吃掉的比计划多出百分之几算"超了"
    wo_input_overrun_pct numeric NOT NULL DEFAULT 10
        CHECK (wo_input_overrun_pct > 0),
    -- 产出短交:产出比预期少百分之几算"短了"
    wo_output_shortfall_pct numeric NOT NULL DEFAULT 10
        CHECK (wo_output_shortfall_pct > 0),
    notes text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.processing_settings IS
    'EXEC-3a:加工模块的单行配置。今天装着工单差异的两个阈值 —— 【两个,不是一个】:投入超耗与产出短交是两种不同的坏消息(WO-1c 在 arm inventory 里问的正是这一句),一个是成本问题、一个是收率问题,合成一个数等于说它们一样严重。默认各 10%。看板的 work_order_variance_beyond 支【现读这两列】,没有任何地方写死这两个数(与 FIN-36 把分摊基准从 schema 默认值提出来同一条:一个谁也看不见的默认值等于替所有人做了这个判断)。';
COMMENT ON COLUMN public.processing_settings.wo_input_overrun_pct IS
    '投入超耗的阈值(百分比)。吃掉的量超过计划量 ×(1 + 本值/100)时,那张工单进看板。【开着的单和收了工的单都报】—— 超耗在它发生的那一刻就是可处理的事。';
COMMENT ON COLUMN public.processing_settings.wo_output_shortfall_pct IS
    '产出短交的阈值(百分比)。产出量低于预期量 ×(1 − 本值/100)时,那张工单进看板。【只报收了工的单】—— 收工之前,"少"只是"还没做完",报出来等于每天提醒一件正在进行的事。没记录预期的行永远不报:没估过不是估了零。';

INSERT INTO public.processing_settings (id) VALUES (true);

ALTER TABLE public.processing_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_settings select by permission" ON public.processing_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));
CREATE POLICY "processing_settings update by permission" ON public.processing_settings
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
