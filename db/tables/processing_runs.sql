-- db/tables/processing_runs.sql
-- 加工批次(一次投料→产出的加工事件)。status 只有 committed/reversed 两态 ——
-- 加工一经提交只能整体冲销(rollback_processing_run),没有"编辑中"状态。
-- 成本列(material_cost_base / process_cost_base / total_cost_base / allocation_*)
-- 由 allocate_processing_costs() 填写,allocation_snapshot 存分摊当刻的完整依据;
-- capitalized_cost_base / capitalization_entry_id 是自动过账切次的产物(成本资本化
-- 分录)。code 'PROC-YYYY-NNNN' 触发器取号(非无缝)。
-- 无 updated_at 触发器(建表早期漏挂)—— 镜像忠实于线上。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件
-- (成本与资本化列是 phase1-cut2 / phase3-cut2a 等迁移陆续追加的,列序按线上 attnum)。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE SEQUENCE public.processing_code_seq;

CREATE TABLE public.processing_runs (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                    text NOT NULL UNIQUE,  -- 'PROC-YYYY-NNNN',触发器取号
    process_date            date,
    total_input             numeric,
    total_output            numeric,
    loss_qty                numeric,
    notes                   text,
    status                  text NOT NULL CHECK (status IN ('committed','reversed')),
    deleted_at              timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid,
    updated_at              timestamptz NOT NULL DEFAULT now(),
    updated_by              uuid,
    -- FIN-36:【没有 schema 默认值,这是有意的】成本方法直接决定每个产出批次的报告
    -- 毛利(FIN-25 量过同一张单 62.50 对 27.50),而一个谁也看不见的默认值等于替
    -- 所有人做了这个判断 —— Doc 2 明写它应当是"显式、可配置的选择"。
    -- commit_processing_run 必填;表单从 finance_settings.default_allocation_basis 预选。
    allocation_basis        text NOT NULL
                            CHECK (allocation_basis IN ('weight','metal_value')),
    material_cost_base       numeric,
    process_cost_base        numeric,
    total_cost_base          numeric,
    allocation_snapshot     jsonb,
    allocated_at            timestamptz,
    allocated_by            uuid,
    capitalized_cost_base    numeric,
    capitalization_entry_id uuid REFERENCES public.journal_entries (id),
    -- ── FIN-36 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 分摊基准最后一次被改动的时点,由 trg_processing_runs_basis_changed 维护。
    -- processing_run_allocation_status.is_stale 与 batch_margin.is_stale 把它当
    -- 【第四个过期源】—— 前三个是成本条目、输入批的 price_history、上游单重分摊。
    allocation_basis_changed_at timestamptz
);

CREATE OR REPLACE FUNCTION public.generate_processing_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'PROC-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('processing_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

-- FIN-36:基准一改就盖时点 —— 它是第四个过期源。
-- 守卫函数体在 db/functions/stamp_allocation_basis_changed.sql。
-- 【只在基准单独变动时盖章】跟着重分摊一起改的不算漂移 —— allocate_processing_costs
-- 挂 evoltrya.alloc_ctx,守卫函数见到它就不盖章(与年结穿期间锁同一个惯用法)。
-- 时点用 clock_timestamp():now() 是事务时间,事务内两次写相等就分不开先后(FIN-36d)。
CREATE TRIGGER trg_processing_runs_basis_changed
    BEFORE UPDATE OF allocation_basis ON public.processing_runs
    FOR EACH ROW
    WHEN (NEW.allocation_basis IS DISTINCT FROM OLD.allocation_basis)
    EXECUTE FUNCTION public.stamp_allocation_basis_changed();

CREATE TRIGGER trg_generate_processing_code
    BEFORE INSERT ON public.processing_runs
    FOR EACH ROW EXECUTE FUNCTION generate_processing_code();

ALTER TABLE public.processing_runs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_runs select by permission"
    ON public.processing_runs
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

CREATE POLICY "processing_runs insert by permission"
    ON public.processing_runs
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "processing_runs update by permission"
    ON public.processing_runs
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "processing_runs delete by permission"
    ON public.processing_runs
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.processing.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 processing_runs_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.processing_runs FROM authenticated, anon;
GRANT SELECT (id, code, process_date, total_input, total_output, loss_qty, notes, status, deleted_at, created_at, created_by, updated_at, updated_by, allocation_basis, allocation_snapshot, allocated_at, allocated_by, capitalization_entry_id, allocation_basis_changed_at)
    ON public.processing_runs TO authenticated;

-- FIN-1a:改名列的注释(说明写在数据库里,重建出来的库也带着)
COMMENT ON COLUMN public.processing_runs.capitalized_cost_base IS '本位币资本化成本(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 capitalized_cost_usd)。';
COMMENT ON COLUMN public.processing_runs.material_cost_base IS '本位币材料成本(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 material_cost_usd)。';
COMMENT ON COLUMN public.processing_runs.process_cost_base IS '本位币加工成本(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 process_cost_usd)。';
COMMENT ON COLUMN public.processing_runs.total_cost_base IS '本位币总成本(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 total_cost_usd)。';

COMMENT ON COLUMN public.processing_runs.allocation_basis IS
    '这一单的成本分摊基准 —— 【选出来的,不是默认出来的】(FIN-36)。没有 schema 默认值是有意的:成本方法直接决定每个产出批次的报告毛利(FIN-25 量过 62.50 对 27.50),而一个谁也看不见的默认值等于替所有人做了这个判断。commit_processing_run 必填,表单从 finance_settings.default_allocation_basis 预选。改动它会把本单标记为过期(见 allocation_basis_changed_at)。';

COMMENT ON COLUMN public.processing_runs.allocation_basis_changed_at IS
    '分摊基准最后一次被改动的时点(FIN-36),由 trg_processing_runs_basis_changed 维护。processing_run_allocation_status.is_stale 与 batch_margin.is_stale 把它当【第四个过期源】—— 前三个是成本条目、输入批的 price_history、上游单重分摊。少了它,一次 UPDATE ... SET allocation_basis 会让存着的单位成本与单据自称的方法对不上而毫无信号。allocate_processing_costs 挂 evoltrya.alloc_ctx,所以重分摊自己不会被标成过期。';
