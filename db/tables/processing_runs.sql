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
    equipment_id  uuid REFERENCES public.fixed_assets (id),
    -- ── PROC-WIRE-1B-i 追加的列 ──────────────────────────────────────────
    -- 这一炉跑的是【哪一道工序】。列本身仍然可空 —— 那 13 张测试残留要留在原地;
    -- 【新行由下面那条 NOT VALID 的 CHECK 必填】(PROC-SUPPORT-1)。
    operation_type_code text REFERENCES public.operation_types (code)
);

COMMENT ON COLUMN public.processing_runs.operation_type_code IS
'PROC-WIRE-1B-i:这张加工单跑的是【哪一道工序】。

【列本身可空,而【新行】是必填的 —— 两句话都要说】线上 14 张里有 13 张没有工序,
它们是测试残留,**刻意不回填**(猜出来的工序与真的工序长得一模一样)。
所以列保持可空,由 processing_runs_operation_type_required 这条 **NOT VALID**
的 CHECK 只管新行。★ 永远不要 VALIDATE 它 ★ —— 见那条约束自己的注释。

★【PROC-SUPPORT-1(2026-09-01):上面那条"记为具名缺口"的话已经过期,而这里
  把它改掉而不是留着】★ 它当时写的是:
    「什么拦得住真单不填?今天没有东西 —— 界面必填,数据库不拦。
      一条 NOT VALID 的 CHECK 要一次「从今天起必须填」的裁定,属于产线跑起来那天。」
  **那次裁定已经下了,而且提前到了产线跑起来【之前】,理由比原来那条更强:**
  在产线跑起来【之后】立规矩,意味着第一批真实炉次正是没被规矩管住的那些。
  实测:真实炉次为 0、界面早已必填、工序字典 5/5 完整 ——
  **现在立规矩的迁移成本是零,晚立的成本不可回收。强制力应当先于流量到场。**
  今天拦得住真单不填的有两样:commit_processing_run 里的 OPERATION_TYPE_REQUIRED
  (给操作员一句可本地化的话),以及上面那条 CHECK(对任何写入者都成立 ——
  本表有一条 insert by permission 的 RLS 策略,函数不是唯一的门)。

【为什么这一列必填而 equipment_id 不必填】那是一次【字典完整性】判断,不是
对称性判断 —— 理由写在 equipment_id 的列注释上,请连着读。

【命名】仓库里每一张字典都以 text code 为主键(form_code / purpose_code /
loss_category_code / chemistry_certainty_code),所以这一列叫 _code 而不是 _id。
brief 写的是 operation_type_id,那个名字假设了 uuid 主键 —— 照抄它才是漂移。';

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

-- ── PROC-SUPPORT-1:一张加工单必须说出它跑的是哪一道工序 ──────────────────
ALTER TABLE public.processing_runs
    ADD CONSTRAINT processing_runs_operation_type_required
    CHECK (operation_type_code IS NOT NULL) NOT VALID;

COMMENT ON CONSTRAINT processing_runs_operation_type_required ON public.processing_runs IS
    'PROC-SUPPORT-1:一张加工单必须说出它跑的是哪一道工序。
【NOT VALID 是刻意的,而且永远不要 VALIDATE 它】线上 14 张(10 张未软删)没有工序的加工单是【测试残留】,不是待修的破损。VALIDATE 会去检查它们,于是唯一能让约束通过的办法是【给它们猜一个工序】—— 而猜出来的工序与真的工序长得一模一样,会流进设备用量、回收率、工单实绩,并且会让那四道闸【看起来对这些单生效过】,而它们从未生效过。这正是本刀存在的理由。
【它与函数里那条拒绝不是重复】函数那条给操作员一句可本地化的话;这一条对【任何写入者】都成立 —— processing_runs 有一条 "insert by permission" 的 RLS 策略,任何拿到 module.processing.edit 的人都可以直接 INSERT 一张加工单绕开函数。(投入腿那一侧拦得住裸插:PROCESSING_INPUT_DIRECT_INSERT 要求函数上下文;但一张没有投入腿的空单仍然造得出来,而它会永远落在"未归属"那一组里。)
【报表怎么显示那 10 张】显示成【未归属】,不是丢掉、也不是归零 —— 抄 EQP-2c 的 unattributed_runs_in_window。';

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
GRANT SELECT (id, code, process_date, total_input, total_output, loss_qty, notes, status, deleted_at, created_at, created_by, updated_at, updated_by, allocation_basis, allocation_snapshot, allocated_at, allocated_by, capitalization_entry_id, allocation_basis_changed_at, work_order_id, deleted_by, delete_reason, equipment_id, operation_type_code)
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

COMMENT ON COLUMN public.processing_runs.equipment_id IS
    'EQP-2a:这一炉是哪台机器跑的。可空,而"空"是一个【具名类别】(未归属),不是零。
★【PROC-SUPPORT-1 / R2:这一列【不】跟着 operation_type_code 一起变成必填 —— 不要"修"掉这处不对称】★
理由是一次【测量】,不是一次对称性偏好:线上 fixed_assets 只有 2 行,两行都是深度放电机(FA-2026-0001 / FA-2026-0002,in_service_date 均为 NULL)。于是 deep_discharge 对应【两台】机器(工序推不出机器,不可派生),而另外【四道】工序 —— manual_disassembly、electrode_line、electrode_powder_line、battery_powder_line —— 【一台在册机器都没有】。一旦这一列必填,这四道工序的加工单一张都提交不了。
所以:operation_type_code 的字典【完整】(5/5 已播种)→ 必填代价为零;equipment_id 的字典【残缺】(5 道里 4 道无资产可指)→ 必填代价是让四道工序停摆。**这是字典完整性判断,不是对称性判断。**
【真正的前置条件,可查询而不是凭感觉】(1) 每一道启用的工序至少有一台在册在役资产;(2) 而那需要一条【工序 ↔ 资产】的关联 —— **今天这个库里没有这条关联**,那才是缺口本身。记在 docs/processing-support-as-built.md。';
