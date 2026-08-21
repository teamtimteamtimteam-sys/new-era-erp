-- EQP-2a:机器【做过什么】—— 加工归到机器上,用量【推导】,停机是它自己的一张表
--
-- ════════════════════════════════════════════════════════════════════════════
-- 三件事,一件都不给操作员留门(界面是 EQP-2c,保养是 EQP-2b):
--   1. processing_runs 认得下"这一炉是哪台机器跑的"(可空);
--   2. 用量【只推导,不存储】—— 一张视图;
--   3. 停机记录成为一张【自己的表】。
-- ════════════════════════════════════════════════════════════════════════════
--
-- ── 接地把设计改了什么(逐条,证据在切次报告里)────────────────────────────
--
-- 【一】D1 那条拒绝【钉错了事实】,本刀把它挪到真正不可能的那两件上。
--   原设计:"加工日那天机器不在役 → 拒"。而 in_service_date 是【投用】日,
--   投用【之前】的试车是这盘生意里一件有名有姓的事 —— docs/equipment-survey.md
--   的资本化边界那一节把"试车料"与安装、调试并列。照原设计,系统就【记不下
--   那些正好用来证明投用日的加工】,而那些加工造成的磨损是真的(EQP-2b 的
--   保养间隔要读它)。
--   真正不可能的是另外两件,而且都是卡上【必填/可判】的事实:
--     * 加工日早于 acquisition_date —— 那天这台机器还不是我们的;
--     * 加工日晚于处置 —— 它已经不在了。
--   所以它【仍然是拒绝,不是警告】:边界挪对之后,剩下被拒的每一种都是真的
--   不可能,没有哪一种只配得上一句提醒。(而且 RPC 这条路上没有"警告"这个
--   通道,现造一个是另一刀的事。)
--
-- 【二】processing_runs 【是遮蔽表】—— 查过了,不是假定的。
--   relacl 里 authenticated/anon 是 `awdDxtm`,**没有 r**;四个成本列
--   (material_/process_/total_/capitalized_cost_base)只经 _masked 视图读。
--   所以加一列必须在【同一支迁移】里做三件事:加列、加进列清单 GRANT、
--   加进 processing_runs_masked。少任何一件 colgrant 判词就红,而在它红之前
--   那一列是"写得进、读不出"(WO-1a 分三刀付过这笔账)。
--   equipment_id 不是敏感列(它是一台机器的引用,不是钱),所以它【授出去】,
--   同时【也进遮蔽视图】—— 一旦一张表有了 _masked 伴生,它的每一列都必须在
--   那张视图里,授没授权都一样(colgrant 的第二个分支)。
--
-- 【三】用量只有【质量】这一种,而这是一个结论,不是一个将就。
--   加工这一族里【没有任何】开始/结束/班次/工时列:processing_runs 上唯一的
--   世界侧日期是 process_date(一个 date),其余 created_at / updated_at /
--   allocated_at / deleted_at 全是记账时刻,work_orders.scheduled_date 是计划。
--   所以【运转小时推导不出来,也不许伪造】—— EQP-2b 的保养间隔因此只能按
--   吨/公斤走。这一句写在这里,是为了让下一刀读到的是一个【测量结果】,
--   而不是一句"暂时没做"。
--
-- 【四】停机表多一条 D3 没说的规矩:一台机器【同时只能有一段没结束的停机】。
--   它不是算术、也不是判断,是一件世界上的事实:机器不会同时坏两次。
--   一条部分唯一索引(WHERE ended_at IS NULL)—— 与 uq_expenses_live_po_line、
--   idx_year_closes_active 同一个惯用法。
--   【而【没有】加的那条:停机与加工不许重叠。】加工只有 date 粒度、停机带
--   时刻,重叠在数据上判不出来;何况 D4 明写这一刀不做这类算术。
--
-- 【五】权限:【没有新码,也没有把财务的数据给操作侧写】。
--   全库根本没有 module.operations —— operations 是一个【角色】。
--   停机表是一张新表,它自己带策略;fixed_assets 只是被外键引用,而外键校验
--   不走 RLS。读用 module.finance.view OR module.processing.view,写用
--   module.processing.edit。那个 OR 不是本刀发明的:AGENTS.md 的第 2 条常设
--   决定就是它,batch_margin 里逐字实现着,理由也一样 ——
--   **实测没有哪个业务角色两个都持**(operations 有 processing.edit、没有
--   finance.view;finance/auditor 反过来;只有 admin/gm 两个都有)。
--   所以这是在【套用一条已经做过的决定】,不是新做一个。
--
-- 【六】D4:本刀【不算】可用率 / OEE —— 理由写在停机表的表注里,带返回条件。
--
-- ── 这一刀【没有任何一个对象是操作员够得到的】────────────────────────────
-- 界面是 EQP-2c,保养记录与保养到期是 EQP-2b。这是【顺序】,不是遗漏。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-21-eqp2a-what-the-machine-did.sql

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1 · 这一炉是哪台机器跑的(可空)
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.processing_runs
    ADD COLUMN equipment_id uuid REFERENCES public.fixed_assets (id);

COMMENT ON COLUMN public.processing_runs.equipment_id IS
'EQP-2a:这一炉是【哪台机器】跑的。可空。
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

-- 【遮蔽表的三件事之二:列清单 GRANT】表级 SELECT 早已收回,列清单不会自动扩展。
-- equipment_id 不敏感(是一台机器的引用,不是钱),所以授出去。
GRANT SELECT (equipment_id) ON public.processing_runs TO authenticated;

CREATE INDEX idx_processing_runs_equipment ON public.processing_runs (equipment_id);

-- ════════════════════════════════════════════════════════════════════════════
-- 2 · 遮蔽表的三件事之三:_masked 视图必须带上新列
-- ════════════════════════════════════════════════════════════════════════════
-- 【一旦一张表有了 _masked 伴生,它的每一列都必须在那张视图里】—— 授没授权
-- 都一样。colgrant 的判据是 (NOT granted AND NOT in_view) OR (has_view AND NOT in_view),
-- 第二个分支管的就是这件事(WO-1a 的 fu1 在这里红过一次)。
-- equipment_id 不遮蔽,原样透出。
CREATE OR REPLACE VIEW public.processing_runs_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    process_date,
    total_input,
    total_output,
    loss_qty,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    allocation_basis,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN material_cost_base
            ELSE NULL::numeric
        END AS material_cost_base,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN process_cost_base
            ELSE NULL::numeric
        END AS process_cost_base,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN total_cost_base
            ELSE NULL::numeric
        END AS total_cost_base,
    allocation_snapshot,
    allocated_at,
    allocated_by,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN capitalized_cost_base
            ELSE NULL::numeric
        END AS capitalized_cost_base,
    capitalization_entry_id,
    allocation_basis_changed_at,
    work_order_id,
    deleted_by,
    delete_reason,
    equipment_id
   FROM processing_runs
  WHERE has_permission('module.processing.view'::text);

-- ════════════════════════════════════════════════════════════════════════════
-- 3 · 停机记录:它自己的一张表
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么是一张表,而不是谁身上的一个字段】——
--   * 挂在 fixed_assets 上的一个字段只装得下【当前状态】:机器修好之后,
--     "3 月 3 日到 7 日停过"这件事就没地方待了,更别说第二次停机;
--   * 挂在 processing_runs 上更不对:停机恰恰是【没有加工的那段时间】,
--     它不是某一炉的属性。
-- 一台机器有很多段停机,每一段有自己的起止与原因 —— 那是一张表的形状。
--
-- 【它抄的是既有的两个先例,各取它真的有的那一半】
--   * supplier_compliance(CMP-1):一个主体 → 多条带日期的记录,
--     **结束可空**(所以"还没结束"表示得出来),软删 + 建改留痕;
--   * leave_requests:`CHECK (end_date >= start_date)` —— 本仓库"一段时间不许
--     倒着走"的原话。
--   两个先例各只有一半:前者有开口、没有次序约束;后者有次序、没有开口。
--   这张表两样都要,所以次序那条写成【允许开口】的形式。
--
-- 【为什么起止是 timestamptz 而不是 date】停机是这套系统里少数几件
-- 【时刻真的有意义】的事:上午十点停和当天停一整天,不是一回事。
-- 加工只有 date,是因为加工那边从来没人记过时刻(见本迁移抬头【三】);
-- 这里没有那个历史包袱,所以不必继承它。
--
-- 【两个日期都【不给默认值】】它们是世界这一侧的事实 —— 机器什么时候停的,
-- 不是这一行什么时候被敲进来的。默认成 now() 会把"忘了填"变成"刚刚停的",
-- 而那正是本仓库那条"决定期间/事实的日期必填、永不默认"要挡的东西。
--
-- 【本刀【不】连保养记录】那些记录 EQP-2b 才存在,所以这里连一列都不留 ——
-- 留一个指向不存在的表的空列,读起来像"忘了填",而不是"还没到"。
-- **它的缺席是【排期】,不是疏漏。** EQP-2b 落地时加那条外键。
CREATE TABLE public.equipment_downtime (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    equipment_id uuid NOT NULL REFERENCES public.fixed_assets (id),
    -- 世界侧事实,都不给默认值
    started_at   timestamptz NOT NULL,
    -- 【可空 = 还没结束】—— 这正是记录它的人当下所处的状态
    ended_at     timestamptz,
    reason       text NOT NULL,
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid,
    -- 一段停机的长度 = 两个记录下来的事实之差。**这不是 D4 禁止的那种算术**:
    -- D4 禁的是可用率/OEE —— 那需要一个分母(日历工时?排班工时?计划工时?),
    -- 而分母是一次没有人做过的判断。两个时刻相减不需要任何判断。
    duration     interval GENERATED ALWAYS AS (ended_at - started_at) STORED,
    CONSTRAINT equipment_downtime_period_order
        CHECK (ended_at IS NULL OR ended_at >= started_at),
    CONSTRAINT equipment_downtime_reason_stated
        CHECK (btrim(reason) <> '')
);

COMMENT ON TABLE public.equipment_downtime IS
'EQP-2a:一行 = 一台机器【没有在跑】的一段时间。
【开口的那一段是常态,不是例外】ended_at 可空 —— 机器停下来的那一刻就有人记它,
而那时没人知道它什么时候好。所以"已开始、未结束"必须表示得出来。
【一台机器同时只能有一段没结束的停机】uq_equipment_downtime_open 那条部分唯一索引 ——
机器不会同时坏两次。
【本刀不连保养记录】保养/维修记录要到 EQP-2b 才存在,所以这里【一列都不留】。
留一个指向不存在的表的空列,读起来像"忘了填"而不是"还没到"。
**这个缺席是排期,不是疏漏** —— EQP-2b 落地时加那条外键。
【本刀刻意不算可用率,也不算 OEE】记下"机器停了多久"是一个【事实】;
算出"可用率 87%"是一个【判断】,而它的分母没有人选过:
日历小时?排班小时?计划生产小时?三种算出来的是三个数,而这盘生意
今天连排班表都不存在(加工那一族里没有任何开始/结束/班次列 —— 实测)。
**返回条件:有人把分母定下来的那一天** —— 那时它是一次决定,不是一个默认值。';

COMMENT ON COLUMN public.equipment_downtime.duration IS
'EQP-2a:这一段停了多久,= ended_at − started_at,由数据库自己算(生成列)。
还没结束时它是 NULL —— 那不是"零",是"还不知道"。';

COMMENT ON CONSTRAINT equipment_downtime_period_order ON public.equipment_downtime IS
'EQP-2a:一段时间不许倒着走 —— 抄的是 leave_requests_date_order 的原话,
但写成【允许开口】的形式:还没结束(ended_at 为空)时这条约束不适用。
两个先例各有一半 —— supplier_compliance 有开口没次序,leave_requests 有次序没开口。';

-- 一台机器同时只能有一段没结束的停机(先例:uq_expenses_live_po_line /
-- idx_year_closes_active —— 同一个"活着的那一条只能有一条"的形状)。
CREATE UNIQUE INDEX uq_equipment_downtime_open
    ON public.equipment_downtime (equipment_id)
    WHERE ended_at IS NULL;

CREATE INDEX idx_equipment_downtime_equipment ON public.equipment_downtime (equipment_id);

ALTER TABLE public.equipment_downtime ENABLE ROW LEVEL SECURITY;

-- 【读:两个模块的 OR —— 套用 AGENTS.md 第 2 条常设决定,不是新做一个决定】
-- batch_margin 里逐字实现着同一个 OR,理由也一样:**实测没有哪个业务角色
-- 两个都持**(operations 有 processing.edit 没有 finance.view;finance/auditor
-- 反过来;只有 admin/gm 两个都有)。机器卡在财务那边、干活的人在加工那边,
-- 而两边都需要读得到停机 —— 少了 OR,总有一边看不见。
CREATE POLICY "equipment_downtime select by permission"
    ON public.equipment_downtime
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text) OR has_permission('module.processing.view'::text));

-- 【写:加工侧】记停机的是车间,不是财务。
-- 【没有新权限码,也没有把财务的数据给操作侧写】—— 这是一张新表,它自己带策略;
-- fixed_assets 只是被外键引用,而外键校验不走 RLS。
CREATE POLICY "equipment_downtime insert by permission"
    ON public.equipment_downtime
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "equipment_downtime update by permission"
    ON public.equipment_downtime
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));

-- ════════════════════════════════════════════════════════════════════════════
-- 4 · 用量:【只推导,不存储】
-- ════════════════════════════════════════════════════════════════════════════
-- 【能推导出来的只有质量这一种,而这是一个测量结果,不是一个将就】
-- 加工这一族里没有任何开始/结束/班次/工时列 —— 实测:processing_runs 上唯一的
-- 世界侧日期是 process_date(date),其余 created_at / updated_at / allocated_at /
-- deleted_at 全是记账时刻;processing_inputs/outputs 只有 created_at;
-- work_orders 只有 scheduled_date(计划)。
-- **所以运转小时【推导不出来】,而本刀【不】为了让它可能而加一个时长字段。**
-- 诚实的输出是"没有小时";EQP-2b 的保养间隔因此按【公斤】走。
-- 要哪天真的按小时保养,那是一次单独的决定(要么车间开始记时刻,要么
-- 保养间隔改口径)—— 不是在这里悄悄补一列。
--
-- 【口径:读表头,不重算腿】total_input / total_output / loss_qty 是
-- commit_processing_run 从腿上算好写下的,而"腿的合计等于表头"这件事在
-- fixture 80 里已经有断言。这里再从腿上算一遍,只会造出【同一个问题的第二个答案】。
-- 实测(线上五炉逐一比对):表头与腿的合计【完全一致】。
--
-- 【不算数的两种炉子,判据是两列一起看】
--   rollback_processing_run 在同一条 UPDATE 里把 status 置为 'reversed'
--   【并且】写下 deleted_at —— 两个标记由同一句话产生,所以它们永远同步。
--   实测线上十三炉:committed 且未删 10 条、reversed 且已删 3 条,
--   另外两种组合【零条】。判据因此写成 status='committed' AND deleted_at IS NULL:
--   两列一起看是刻意的 —— 任何一个将来被单独改动,这里都会立刻不一致。
--
-- 【这张视图回答的是"这台机器做过什么",不是"所有的炉子都去哪了"】
-- **equipment_id 为空的炉子【不在】这张视图里** —— 它们没有机器可归。
-- 要看它们,得另外读一次 processing_runs,并且按 equipment_id 那一列的注释
-- 把它们显示成【未归属】这个具名类别。把本视图读成一份完整的加工account,
-- 会把未归属的那些悄悄当成不存在。
CREATE VIEW public.equipment_usage WITH (security_invoker = off) AS
 SELECT fa.id AS equipment_id,
    fa.code AS equipment_code,
    fa.description AS equipment_description,
    fa.acquisition_date,
    fa.in_service_date,
    fa.status AS equipment_status,
    count(pr.id) AS run_count,
    -- 单位是【公斤】—— 线上进料批次与产出批次的 unit 全库只有 'kg' 一种(实测)。
    COALESCE(sum(pr.total_input), 0::numeric)  AS input_kg,
    COALESCE(sum(pr.total_output), 0::numeric) AS output_kg,
    COALESCE(sum(pr.loss_qty), 0::numeric)     AS loss_kg,
    min(pr.process_date) AS first_run_date,
    max(pr.process_date) AS last_run_date
   FROM fixed_assets fa
   LEFT JOIN processing_runs pr
          ON pr.equipment_id = fa.id
         AND pr.status = 'committed'
         AND pr.deleted_at IS NULL
  WHERE has_permission('module.finance.view'::text) OR has_permission('module.processing.view'::text)
  GROUP BY fa.id, fa.code, fa.description, fa.acquisition_date, fa.in_service_date, fa.status;

COMMENT ON VIEW public.equipment_usage IS
'EQP-2a:每台机器【做过什么】—— 从既有的加工记录推导,一个数都不存。
【LEFT JOIN 是刻意的】一台还没跑过任何一炉的机器【也要在这张表里】,
带着一排 0 —— 它的意思是"这台机器存在,而它什么都还没做",
与"没有这台机器"完全不同。而 run_count = 0 时 first_run_date / last_run_date
是 NULL,那不是零,是"还没有第一次"。
【只有公斤,没有小时】加工这一族里没有任何时刻/班次/工时记录(实测),
所以运转小时【推导不出来】。EQP-2b 的保养间隔因此按公斤走。
**不要为了让小时成为可能而在这里加一个时长字段** —— 那是把一个测量
换成一个编造。';

-- ════════════════════════════════════════════════════════════════════════════
-- 5 · commit_processing_run 认得下机器
-- ════════════════════════════════════════════════════════════════════════════
-- 【DROP + CREATE,不是 CREATE OR REPLACE】签名变了。预检会拒绝一次签名不同的
-- 替换(FIN-21:那是重载,旧签名会作为镜像看不见的漂移活下来)。
-- **这一手与 WO-1b 给它加 p_work_order_id 时逐字相同**(见
-- db/migrations/2026-08-16-wo1b-the-seam.sql 第 298–300 行),新参数同样
-- 【带默认值、排在最后】,所以老调用方一个字都不用改。
DROP FUNCTION public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid);

CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, p_work_order_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id      uuid := auth.uid();
    v_process_date date;
    v_run_id       uuid;
    v_total_input  numeric := 0;
    v_total_output numeric := 0;
    v_input        jsonb;
    v_output       jsonb;
    v_inbound_id   uuid;
    v_output_id    uuid;   -- FIN-25:再加工投料(产出批为源)
    v_consumed     numeric;
    v_remaining    numeric;
    v_available     numeric;
    v_held          numeric;
    v_new_remaining numeric;
    v_material_id  uuid;
    v_qty          numeric;
    v_unit         text;
    v_purity       text;
    v_new_output_id uuid;
    v_wo           work_orders%ROWTYPE;   -- WO-1b
    v_eq           fixed_assets%ROWTYPE;  -- EQP-2a:这一炉归给哪台机器
BEGIN
    PERFORM require_permission('module.processing.edit');
    IF p_process_date IS NULL THEN
        RAISE EXCEPTION 'PROCESS_DATE_REQUIRED';
    END IF;

    -- FIN-36:分摊基准【必填】。不在这里回退到 finance_settings 的公司默认值 ——
    -- 那只会把"没人选过"从 schema 挪进函数,同一个病换一层楼。表单永远带着值来
    -- (预选自 finance_settings.default_allocation_basis),所以必填没有代价。
    IF p_allocation_basis IS NULL THEN
        RAISE EXCEPTION 'ALLOCATION_BASIS_REQUIRED';
    END IF;
    IF p_allocation_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', p_allocation_basis;
    END IF;

    -- ── WO-1b:工单这一支【只在给了参数的时候才存在】────────────────────────
    -- 【为什么是可选的,而不是必填】临时起意的加工是合法的 —— 车间不会为了系统
    -- 先去补一张计划。把它变成必填,得到的不是纪律,是一堆事后补的假工单。
    -- 差异报表因此必须把 work_order_id 为空的那些显示成【计划外】这一个具名的
    -- 类别,而不是让它们悄悄消失(那是 WO-1c 的事,规则记在这里)。
    IF p_work_order_id IS NOT NULL THEN
        SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'WO_NOT_FOUND|%', p_work_order_id;
        END IF;
        -- 【只有放行了的工单可以开工】草稿是还没答应的事(与 reserve_stock 只认
        -- 已确认订单同一条);而 closed / cancelled 是【已经结束的事】,再往上挂
        -- 一次加工会让那张单的完成度在它收工之后继续变 —— 收工时写进理由行的
        -- 那句"runs=N"从此不再复算得出来。
        IF v_wo.status <> 'released' THEN
            RAISE EXCEPTION 'WO_NOT_RELEASED|%|%', v_wo.code, v_wo.status;
        END IF;
    END IF;

    -- ── EQP-2a:机器这一支【也只在给了参数的时候才存在】────────────────────
    -- 位置跟着 WO-1b 那一支放。【为什么可空】线上十三炉一台机器都没有归属,
    -- 而临时起意的加工是合法的 —— "未归属"必须是一个【具名类别】,不是一个零。
    IF p_equipment_id IS NOT NULL THEN
        SELECT * INTO v_eq FROM fixed_assets WHERE id = p_equipment_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_FOUND|%', p_equipment_id;
        END IF;
        -- 【拒绝的边界钉在"真的不可能"上,不钉在"还没投用"上】
        -- 加工日早于取得日 = 那天这台机器还不是我们的。
        IF p_process_date < v_eq.acquisition_date THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_ACQUIRED|%|%|%',
                v_eq.code, v_eq.acquisition_date, p_process_date
              USING HINT = '这一炉的日期早于这台机器的取得日 —— 那天它还不是我们的';
        END IF;
        -- 处置之后它已经不在了。
        IF v_eq.status = 'disposed' AND v_eq.disposal_date IS NOT NULL
           AND p_process_date > v_eq.disposal_date THEN
            RAISE EXCEPTION 'EQUIPMENT_DISPOSED|%|%|%',
                v_eq.code, v_eq.disposal_date, p_process_date
              USING HINT = '这一炉的日期晚于这台机器的处置日 —— 那时它已经不在了';
        END IF;
        -- 【投用之前【不】拒 —— 这是本刀对原设计改动最大的一处】
        -- 原设计要拒"加工日那天机器不在役",而 in_service_date 是【投用】日。
        -- 投用之前的试车是这盘生意里一件有名有姓的事:
        -- docs/equipment-survey.md 的资本化边界那一节把"试车料"与安装、调试并列。
        -- 拒掉它们,系统就【记不下那些正好用来证明投用日的加工】,也丢掉了
        -- 那段真实的磨损 —— 而 EQP-2b 的保养间隔要读它。
        -- 剩下被拒的两种都是真的不可能,所以它们【是拒绝,不是警告】。
    END IF;

    v_process_date := p_process_date;
    -- 0. 基本校验
    IF p_inputs IS NULL OR jsonb_array_length(p_inputs) = 0 THEN
        RAISE EXCEPTION 'NO_INPUTS';
    END IF;
    IF p_outputs IS NULL OR jsonb_array_length(p_outputs) = 0 THEN
        RAISE EXCEPTION 'NO_OUTPUTS';
    END IF;
    IF p_loss_qty IS NOT NULL AND p_loss_qty < 0 THEN
        RAISE EXCEPTION 'LOSS_NEGATIVE';
    END IF;

    -- 0b. 同一批次(不论来源)不能重复添加。FIN-25:投料可为进料批或产出批,
    --     恰一非空;两个都给或都不给 → INPUT_PARENT_INVALID。
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_inputs) elem
        WHERE num_nonnulls(elem->>'inbound_batch_id', elem->>'output_batch_id') <> 1
    ) THEN
        RAISE EXCEPTION 'INPUT_PARENT_INVALID';
    END IF;
    IF (SELECT count(DISTINCT COALESCE(elem->>'inbound_batch_id', elem->>'output_batch_id'))
        FROM jsonb_array_elements(p_inputs) elem) <> jsonb_array_length(p_inputs) THEN
        RAISE EXCEPTION 'DUPLICATE_INPUT';
    END IF;

    -- 1. 遍历投入:校验库存(并锁行)+ 累计投入合计
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_consumed IS NULL OR v_consumed <= 0 THEN
            RAISE EXCEPTION 'INPUT_QTY_INVALID';
        END IF;

        IF v_inbound_id IS NOT NULL THEN
            SELECT remaining_qty INTO v_remaining
            FROM inbound_batches
            WHERE id = v_inbound_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_inbound_id;
            END IF;
        ELSE
            -- FIN-25:产出批投料 —— 同一套校验、同一把锁。库存机器本就共用
            -- (inventory_movements 两侧 XOR,remaining_qty 两表同义)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches
            WHERE id = v_output_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_output_id;
            END IF;
        END IF;
        -- IOD-1:投得进去的是【可用】,不是【物理剩余】—— 被扣住的货还在批次里,
        -- 但它不可动用。拒绝同时说出可用与暂扣两个数,否则人看着 remaining 够
        -- 却投不进去,屏幕上没有任何解释。
        v_available := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                                 WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                                   AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                                   AND m.stock_status = 'available'), 0);
        v_held := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                            WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                              AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                              AND m.stock_status = 'on_hold'), 0);
        IF v_consumed > v_available THEN
            RAISE EXCEPTION 'IOD_CONSUME_EXCEEDS_AVAILABLE|%|%|%', v_consumed, v_available, v_held;
        END IF;

        v_total_input := v_total_input + v_consumed;
    END LOOP;

    -- 2. 遍历产出:校验 + 累计产出合计
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_qty := (v_output->>'quantity')::numeric;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'OUTPUT_QTY_INVALID';
        END IF;
        IF (v_output->>'material_id') IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NO_MATERIAL';
        END IF;
        v_total_output := v_total_output + v_qty;
    END LOOP;

    -- 3. 质量守恒:产出不能大于投入
    IF v_total_output > v_total_input THEN
        RAISE EXCEPTION 'OUTPUT_EXCEEDS_INPUT|%|%', v_total_output, v_total_input;
    END IF;

    -- 4. 建加工单表头(code 由触发器生成)
    INSERT INTO processing_runs (
        process_date, total_input, total_output, loss_qty, notes, status,
        allocation_basis, work_order_id, created_by, updated_by, equipment_id
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        COALESCE(p_loss_qty, v_total_input - v_total_output),
        p_notes, 'committed', p_allocation_basis, p_work_order_id, v_user_id, v_user_id,
        p_equipment_id
    )
    RETURNING id INTO v_run_id;

    -- 5. 再遍历投入:扣库存 + 更新阶段 + 建投入腿 + 记库存流水(消耗)
    --    FIN-25:ctx 提前到这里 —— 投入腿的守卫触发器(guard_processing_input)
    --    只放行函数上下文;原来 ctx 在第 6 步(产出)才设,投入腿就会被自己拒掉。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_inbound_id IS NOT NULL THEN
            SELECT remaining_qty INTO v_remaining
            FROM inbound_batches WHERE id = v_inbound_id;
            v_new_remaining := v_remaining - v_consumed;

            UPDATE inbound_batches
            SET remaining_qty = v_new_remaining,
                stage = CASE WHEN v_new_remaining <= 0 THEN '已加工完' ELSE '加工中' END,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_inbound_id;

            -- IOD-1:投料走 drain_stock —— 可能跨几个库位桶,于是写出多行(规则见其函数头)
            PERFORM drain_stock(
                p_qty => v_consumed, p_movement_type => 'processing_consume',
                p_business_date => v_process_date, p_inbound_batch_id => v_inbound_id,
                p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);

            INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
            VALUES (v_run_id, v_inbound_id, v_consumed);
        ELSE
            -- FIN-25:产出批投料。state 是【销售状态】(表注),消耗不碰它 ——
            -- 只扣 remaining_qty,流水挂 output_batch_id(XOR 的另一侧)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches WHERE id = v_output_id;
            v_new_remaining := v_remaining - v_consumed;

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_output_id;

            PERFORM drain_stock(
                p_qty => v_consumed, p_movement_type => 'processing_consume',
                p_business_date => v_process_date, p_output_batch_id => v_output_id,
                p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);

            INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed)
            VALUES (v_run_id, v_output_id, v_consumed);
        END IF;
    END LOOP;

    -- 6. 遍历产出:建产出批次 + 建产出腿
    --    产出的入库流水由 AFTER INSERT 触发器发出;先设置上下文标记本批产出属于本加工单。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_material_id := (v_output->>'material_id')::uuid;
        v_qty         := (v_output->>'quantity')::numeric;
        v_unit        := COALESCE(NULLIF(v_output->>'unit', ''), 'kg');
        v_purity      := NULLIF(v_output->>'purity', '');

        INSERT INTO output_batches (
            material_id, quantity, unit, remaining_qty, output_date, state, purity,
            created_by, updated_by
        ) VALUES (
            v_material_id, v_qty, v_unit, v_qty, v_process_date, '库存中', v_purity,
            v_user_id, v_user_id
        )
        RETURNING id INTO v_new_output_id;

        INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced)
        VALUES (v_run_id, v_new_output_id, v_qty);
    END LOOP;

    -- 用毕即清(price_ctx 同一条理由:免得同事务内后续的直改被误放行 ——
    -- fixture 19F 实测:不清,守卫触发器对残留 ctx 放行裸 INSERT)
    PERFORM set_config('evoltrya.movement_ctx', '', true);

    RETURN v_run_id;
END;
$function$

;

COMMIT;
