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
    allocation_basis_changed_at timestamptz,
    -- ── WO-1a 追加的列 ───────────────────────────────────────────────────────
    -- 这一次加工是照哪一张工单做的。WO-1a 建列,【WO-1b 才由
    -- commit_processing_run 写入】—— 本刀不动那个函数的签名。为空 = 临时起意的
    -- 加工,那是合法的,而差异报表必须把它显示成【计划外】,不是显示成零。
    work_order_id           uuid REFERENCES public.work_orders (id),
    -- ── AUDEL-1b 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────
    deleted_by    uuid,
    delete_reason text,
    -- ── EQP-2a 追加的列(同上,attnum 27)────────────────────────────────
    -- 这一炉是哪台机器跑的。可空,而"空"是一个【具名类别】(未归属),不是零。
    equipment_id  uuid REFERENCES public.fixed_assets (id)
);

COMMENT ON COLUMN public.processing_runs.delete_reason IS
    'AUDEL-1b:为什么回滚这张加工单。加工单的"删除"就是它的冲销(status=reversed + deleted_at),所以理由记在这里 —— rollback_processing_run() 必填。';

CREATE INDEX idx_processing_runs_work_order ON public.processing_runs (work_order_id)
    WHERE work_order_id IS NOT NULL;
CREATE INDEX idx_processing_runs_equipment ON public.processing_runs (equipment_id);

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
-- WO-1a-fu1:work_order_id 也在列清单里。【列清单的 SELECT 授权不会自动延伸到
-- 后加的列】(表级 INSERT/UPDATE 会,这个不对称就是全部的坑),所以 WO-1a 加完列
-- 之后它是"写得进、读不出"的 —— 实测 has_column_privilege = false。
-- 它不是敏感列:是一个单据之间的链接,与同表的 capitalization_entry_id 同一类。
-- EQP-2a:equipment_id 也在列清单里 —— 它不是钱,是一台机器的引用。
-- 【而它同时也必须进 processing_runs_masked】:一旦一张表有了 _masked 伴生,
-- 每一列都得在那张视图里,授没授权都一样(colgrant 的第二个分支,WO-1a-fu1 红过)。
GRANT SELECT (id, code, process_date, total_input, total_output, loss_qty, notes, status, deleted_at, created_at, created_by, updated_at, updated_by, allocation_basis, allocation_snapshot, allocated_at, allocated_by, capitalization_entry_id, allocation_basis_changed_at, work_order_id, deleted_by, delete_reason, equipment_id)
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

COMMENT ON COLUMN public.processing_runs.work_order_id IS
    'WO-1a 建列,WO-1b 由 commit_processing_run 写入。这一次加工是照哪一张工单做的;为空 = 临时起意的加工(那是合法的,而且差异报表必须把它显示成【计划外】,不是显示成零)。';

-- AUDEL-1b:置 deleted_at 必须走【门】(函数),且 deleted_by / delete_reason 必须填好。
-- 光加两列挡不住任何事 —— 软删本来就是一次直连 UPDATE。
CREATE TRIGGER trg_processing_runs_soft_delete_provenance
    BEFORE UPDATE ON public.processing_runs
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();

COMMENT ON COLUMN public.processing_runs.equipment_id IS 'EQP-2a:这一炉是【哪台机器】跑的。可空。
【为什么可空,而且"空"必须是一个有名字的类别】线上十三炉一台机器都没有归属
(而且当时全库连一张资产卡都没有);临时起意、或者当时没人记下来,都是常态。
把它做成必填,得到的不是纪律,是一堆事后补的假归属。**所以任何按机器汇总的
读法都必须把 equipment_id 为空的那些显示成【未归属】这一个具名类别,
而不是让它们悄悄消失、更不是把它们算成零** —— 与 WO-1b 给 work_order_id
立的规矩逐字相同(那边叫【计划外】)。
【它归的是机器,不是产线也不是工位】fixed_assets 一张卡就是一台机器
(EQP-1a-TAIL:一条设备采购行订一台,四台是四行)。
【谁能写它】commit_processing_run,并且只在两种情形之外:加工日早于该卡的
取得日(EQUIPMENT_NOT_ACQUIRED)、或晚于它的处置日(EQUIPMENT_DISPOSED)。
**投用之前的试车是【允许】归属的** —— 那是这盘生意里真实存在的一段,
而且正是它证明了投用日(见 docs/equipment-survey.md 的资本化边界一节)。';
