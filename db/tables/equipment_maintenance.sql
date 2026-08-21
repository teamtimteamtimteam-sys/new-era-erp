-- db/tables/equipment_maintenance.sql
-- EQP-2b:一行 = 对一台机器做过的一次活(例行保养 或 修理)。
--
-- 【这张表一分钱都不过】钱由 record_expense 过,并且只由它过。本表【指着】
-- 那笔支出,自己不带金额、不写分录。下一个最容易被提出的要求就是"让这一行
-- 带个成本吧" —— 那会开出第二条过账路,而那正是长出两本对不上的账的方式。
--
-- 【两条链接都可选,两个方向都是】计划停机里的保养不造成停机;一次故障可以在
-- 还没人动手之前就被记下来。有保养不蕴含有停机,反之亦然。
--
-- 【更正的形状:可改 + 留痕,没有历史表】与它的亲兄弟 equipment_downtime
-- (EQP-2a)一致。成对旧/新的强类型历史(purchase_order_history)是给会被改单
-- 并重新签发给对方的单据、以及驱动金钱的数字用的。返回条件见表注。
--
-- 【调度层读这些行,但不在这一刀里】间隔/到期/逾期与看板臂是 EQP-2c,
-- 界面是 EQP-2d。**它们的缺席是排期,不是遗漏。**
--
-- NOTE: introduced by db/migrations/2026-08-21-eqp2b-maintenance-and-repair-records.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.equipment_maintenance (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    equipment_id uuid NOT NULL REFERENCES public.fixed_assets (id),
    -- 【世界侧的日期,不给默认值】活是哪天干的,不是这一行哪天被敲进来的。
    -- 默认成今天会把"忘了填"变成"今天干的",而那正是本仓库那条
    -- 「决定事实的日期必填、永不默认」要挡的东西(FIN-10 那十一个函数)。
    performed_on date NOT NULL,
    -- 例行保养 还是 修理。两者的调度逻辑不同(EQP-2c 读这一列),
    -- 而且资本化只可能发生在修理那一侧 —— 例行保养按定义是维持,不是改良。
    kind         text NOT NULL CHECK (kind IN ('service', 'repair')),
    description  text NOT NULL CHECK (btrim(description) <> ''),
    -- ── 谁做的:照抄 expenses / payments 的三列(PAYEE-1a)────────────────
    performed_by_employee_id uuid REFERENCES public.employees (id),
    performed_by_supplier_id uuid REFERENCES public.suppliers (id),
    performed_by_name        text,
    -- ── D2:两条可选链接,两个方向都可选 ────────────────────────────────
    downtime_id  uuid REFERENCES public.equipment_downtime (id),
    -- ── D3/D4:指着钱,但自己不过账 ─────────────────────────────────────
    expense_id             uuid REFERENCES public.expenses (id),
    capitalised            boolean NOT NULL DEFAULT false,
    capitalisation_reason  text,
    capitalised_expense_id uuid REFERENCES public.expenses (id),
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid,
    -- 【谁做的:从不两个,而且至少说出一个】前半句抄 expenses_counterparty_shape;
    -- 后半句是本刀加的,理由写在表注里 —— 不想再挖一个"空格子同时是两种意思"的坑。
    CONSTRAINT equipment_maintenance_performer_shape CHECK (
        num_nonnulls(performed_by_employee_id, performed_by_supplier_id) <= 1
        AND (num_nonnulls(performed_by_employee_id, performed_by_supplier_id) = 1
             OR COALESCE(btrim(performed_by_name), '') <> '')
    ),
    -- 【说要资本化,就得说为什么】D4:判断是人下的,而一个没有理由的判断
    -- 在审计面前等于没有判断。反过来不强制:没资本化的行不必解释自己。
    CONSTRAINT equipment_maintenance_capitalisation_reason CHECK (
        capitalised = false OR COALESCE(btrim(capitalisation_reason), '') <> ''
    ),
    -- 资本化经由的那笔支出,只可能出现在【说了要资本化】的行上。
    CONSTRAINT equipment_maintenance_capitalised_expense CHECK (
        capitalised_expense_id IS NULL OR capitalised = true
    )
);

COMMENT ON TABLE public.equipment_maintenance IS
'EQP-2b:一行 = 对一台机器做过的一次活(例行保养 或 修理)。

【这张表【一分钱都不过】—— 而这句话是它最重要的一条】
钱由 record_expense 过,并且只由它过。本表【指着】那笔支出(expense_id),
自己不带任何金额、不写任何分录。
**下一个最容易被提出的要求就是"让这一行带个成本吧"—— 那会开出第二条过账路,
而两条过账路正是这套系统长出两本对不上的账的方式。**
要金额,读它指着的那张支出单。

【两条链接都是可选的,两个方向都是】
* 停机(downtime_id):计划停机里做的保养不造成停机,而一次故障可以在还没有人
  动手之前就被记下来。**有保养不蕴含有停机,有停机也不蕴含有保养。**
* 支出(expense_id):自己人花两小时紧一颗螺丝,没有任何单据。

【资本化是【记录下来的判断】,不是算出来的】
Tim 的规矩有两半:延长寿命或提高产能(人的判断),【并且】花费够大(一个数)。
系统只算得了第二半,所以它只【建议】—— 见 equipment_maintenance_advice,
以及 maintenance_settings 的表注。本表存的是那个【判断】和它的【理由】:
capitalised = true 而没有 capitalisation_reason 的行,表上那条 CHECK 直接拒。

【capitalised_expense_id 今天对一台【在跑的】机器建不出来 —— 这不是本表的毛病】
record_expense 的追加支在资产已投用时按名拒(ASSET_ALREADY_IN_SERVICE),
理由是 FIN-22 明写的:投用后的追加是一次会计判断,交还给人。而一台需要大修的
机器几乎按定义就是已投用的。所以这一列对【投用之前】的工作是对的、也是将来那条路
落地时的落点,但今天它在大修这条常见路径上【填不了】。
记在 docs/known-issues.md,带返回条件。**不要把它读成一条走得通的路。**

【更正的形状:可改 + 留痕,没有历史表 —— 与 equipment_downtime 一致】
成对旧/新的强类型历史(purchase_order_history)是给【会被改单并重新签发给对方的
单据】和【驱动金钱的数字】用的。本表不过账、不寄给任何人,而它的亲兄弟
equipment_downtime(EQP-2a)正是可改 + 留痕。把"这台机器身上发生的事"的两半
做成两种更正形状,才是那个不一致。
**返回条件:资本化判断哪天需要审计轨迹,就抄 purchase_order_history 的形状。**

【调度层读这些行,但它不在这一刀里】保养间隔、下次到期、"逾期"的推导与看板臂
都是 EQP-2c;界面是 EQP-2d。**它们的缺席是排期,不是遗漏。**';

COMMENT ON COLUMN public.equipment_maintenance.performed_on IS
'EQP-2b:这次活是【哪一天】干的 —— 世界侧的事实,不给默认值。
EQP-2c 的保养间隔要按它算下一次到期,所以一个悄悄填成"今天"的日期会把
整条排程往后推,而且没有任何东西看得出来。';

COMMENT ON COLUMN public.equipment_maintenance.kind IS
'EQP-2b:例行保养(service)还是修理(repair)。
【为什么是两类而不是更多】它们的调度逻辑不同:保养按间隔重复,修理是事件驱动。
而资本化只可能落在 repair 这一侧 —— 例行保养按定义是【维持】,不是改良。
(本表不强制这一点:一个把 service 标成资本化的行,该拦它的是人的判断,
不是一条 CHECK —— 因为"大修"与"保养"的边界本身就是那个判断的一部分。)';

COMMENT ON CONSTRAINT equipment_maintenance_performer_shape ON public.equipment_maintenance IS
'EQP-2b:谁做的 —— 【从不两个,而且至少说出一个】。
前半句抄 expenses_counterparty_shape(PAYEE-1a):一件活不可能同时由自己人和
外包同时完成。后半句是本刀加的:三列全空会让"自己人干的但没记名字"与
"根本没人填过"变成同一个空格子 —— 那正是 EQP-1c-b-fu 刚在 supplier_types 上
记下的三态坑。外包给一家没在册的公司,写 performed_by_name 即可,所以
这条要求永远满足得了。';

CREATE INDEX idx_equipment_maintenance_equipment ON public.equipment_maintenance (equipment_id, performed_on);
CREATE INDEX idx_equipment_maintenance_downtime ON public.equipment_maintenance (downtime_id);
CREATE INDEX idx_equipment_maintenance_expense ON public.equipment_maintenance (expense_id);

ALTER TABLE public.equipment_maintenance ENABLE ROW LEVEL SECURITY;

-- 【D6:照抄 EQP-2a 的停机表,一个字都没改】读是两个模块的 OR,写是加工侧。
-- **没有新权限码** —— 全库根本没有 module.operations(operations 是一个角色);
-- 那个 OR 是 AGENTS.md 第 2 条常设决定,batch_margin 与 equipment_downtime 里
-- 各实现着一遍,理由相同:实测没有哪个业务角色两个都持。
CREATE POLICY "equipment_maintenance select by permission"
    ON public.equipment_maintenance
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text) OR has_permission('module.processing.view'::text));

CREATE POLICY "equipment_maintenance insert by permission"
    ON public.equipment_maintenance
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "equipment_maintenance update by permission"
    ON public.equipment_maintenance
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
