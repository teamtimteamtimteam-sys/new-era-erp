-- EQP-2b:保养与维修记录 —— 一条记录指着钱,但它自己【一分钱都不过】
--
-- ════════════════════════════════════════════════════════════════════════════
-- 三个对象,全部不给操作员留门(界面是 EQP-2d;间隔、到期与看板臂是 EQP-2c):
--   1. equipment_maintenance —— 一行 = 对一台机器做过的一次活;
--   2. maintenance_settings —— 资本化阈值的单行配置(它【只建议,从不拦】);
--   3. equipment_maintenance_advice —— 那条建议的推导,阈值【现读配置】。
-- ════════════════════════════════════════════════════════════════════════════
--
-- ── 接地把设计改了什么(逐条,证据在切次报告里)────────────────────────────
--
-- 【一】D4 里"资本化经由的那笔支出"这条链接,**今天对一台在跑的机器根本建不出来**。
--   record_expense 的追加支在资产【已投用】时按名拒(ASSET_ALREADY_IN_SERVICE),
--   而 FIN-22 给的理由是明写的:"投用后的追加是一次会计判断,不是这条路顺手做得了
--   的事,所以按名拒,把那个判断交还给人。"
--   **而一台需要大修的机器,几乎按定义就是已经投用的。**
--   所以这一列【留着】(它对投用之前的工作是对的,也是将来那条路落地时的落点),
--   但本迁移把这个限制写在列注释里,并记进 docs/known-issues.md ——
--   否则下一个人会把 capitalised_expense_id 读成一条走得通的路。
--   **本刀不改 record_expense**(brief 明写,而且 Tim 正在走查那条路)。
--
-- 【二】D5 的"原始成本"没有一个现成的数可以指。
--   fixed_assets.cost_base 是【到目前为止的记录成本】—— EQP-1b-iii 之后它等于
--   未冲销成本明细之和,并且每资本化一次就长大一次。而"取得时的原价"没有
--   单独存过(零成本卡 + 后补发票的路径下,"第一条明细"也不等于取得价)。
--   所以本刀用 cost_base,并【把它是什么说清楚】:它是记录成本,不是冻结在
--   取得日的那个数。两者的区别【在第一次资本化大修之后才开始咬人】,
--   而那时该由谁来选,是一次会计决定,不是一个默认值。记在视图注释里。
--
-- 【三】Q5 的两个候选之外还有第三个,而它才是该抄的那个。
--   brief 列了"成对旧/新的强类型历史表"(purchase_order_history)与"纯追加"。
--   但本刀的【亲兄弟】—— EQP-2a 一刀之前建的 equipment_downtime —— 用的是
--   第三种:**可改 + 留痕(updated_at / updated_by),没有历史表**。
--   保养记录不过账(D3)、不寄给任何人,而成对旧/新那种形状是给
--   【会被改单并重新签发给对方的单据】和【驱动金钱的数字】用的。
--   把"这台机器身上发生的事"的两半做成两种更正形状,才是那个不一致。
--   **返回条件写在表注里**:资本化判断哪天需要审计轨迹,就抄 po_history 的形状。
--
-- 【四】"谁做的"照抄既有先例,而先例是【三列】不是两列。
--   expenses 与 payments 都同时带 employee_id + supplier_id,由
--   num_nonnulls(...) <= 1 配对(PAYEE-1a);expenses 另有 payee_name 那个
--   自由文本,专给"一次性的收款人"。保养这一侧原样照抄三列,
--   并且【要求至少说出一个】—— 刚刚(EQP-1c-b-fu)才记过 supplier_types
--   那个"空格子同时是两种意思"的三态坑,这里不必再挖一个:
--   外包给一家没在册的公司,写进 performed_by_name 即可。
--
-- 【五】D6 照抄 EQP-2a 的停机表:读 finance.view OR processing.view,
--   写 processing.edit。**没有新权限码**(全库根本没有 module.operations —— 
--   operations 是一个角色)。那个 OR 是 AGENTS.md 第 2 条常设决定。
--
-- ── 遮蔽检查(brief 要求逐次报告)────────────────────────────────────────────
-- 本刀【新建】三个对象,不改任何既有表。被外键引用的四张里:
-- fixed_assets / equipment_downtime / expenses / suppliers 都【不是】遮蔽表
-- (relacl 里 authenticated 持表级 SELECT);**employees 是遮蔽表** ——
-- 但本刀只是【外键引用】它,一列都不加,所以列清单 GRANT 与 _masked 视图
-- 都不需要动。新建的三个对象自己没有 _masked 伴生,也就没有"每列都要在视图里"
-- 那条要求。
--
-- ── 这一刀【没有任何一个对象是操作员够得到的】────────────────────────────
-- 间隔、到期、"逾期"推导与看板臂是 EQP-2c;界面是 EQP-2d。**排期,不是遗漏。**
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-21-eqp2b-maintenance-and-repair-records.sql

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1 · 资本化阈值:单行配置(形状取自 receiving_settings / processing_settings)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.maintenance_settings (
    id boolean PRIMARY KEY DEFAULT true CHECK (id),
    -- 占机器【记录成本】的百分之几,才够得上"值得资本化"
    capitalise_pct_of_cost numeric NOT NULL DEFAULT 10
        CHECK (capitalise_pct_of_cost > 0),
    -- 绝对下限(本位币):便宜机器上的小活不该因为百分比达标就资本化
    capitalise_floor_base  numeric NOT NULL DEFAULT 1000
        CHECK (capitalise_floor_base >= 0),
    notes      text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid DEFAULT auth.uid()
);

INSERT INTO public.maintenance_settings (id) VALUES (true);

COMMENT ON TABLE public.maintenance_settings IS
'EQP-2b:资本化阈值的单行配置(形状取自 receiving_settings / processing_settings)。
【它只建议,从不拦】—— 这是本表存在方式的全部要点。是否资本化的判据有两半:
① 这次修理【延长了寿命或提高了产能】吗 —— 一个人的判断,任何查询都做不出来;
② 花的钱够不够大 —— 一个数,系统算得出来。
**系统只答得了第二半,所以它只说"够/不够",绝不替谁下结论、也绝不拦住谁。**
这正是本仓库那条规矩:一个看不见完整答案的检查,可以提醒,不可以拒绝。
【两个数,不是一个】只有百分比,一台便宜机器上换个轴承就"达标"了;
只有绝对值,一台贵机器上的大修反而够不着。两者【都要满足】才算达标。
【RUNTIME CONFIG】运营改得动,所以 check_mirrors 不逐行比对它 ——
线上与本文件不同【是系统在正常工作】。引导那一行必须在。';

COMMENT ON COLUMN public.maintenance_settings.capitalise_pct_of_cost IS
'EQP-2b:这次活的花费占机器【记录成本】的百分之几,才够得上资本化的门槛。
引导值 10 是一个默认,不是一次决定 —— Tim 改一次,线上就与本文件不同,那是对的。
【"记录成本"是 fixed_assets.cost_base】它不是冻结在取得日的原价:
EQP-1b-iii 之后它等于未冲销成本明细之和,每资本化一次就长大一次。
两者的区别【在第一次资本化大修之后才开始咬人】—— 见
equipment_maintenance_advice 的视图注释,那里写了这件事该由谁来定。';

COMMENT ON COLUMN public.maintenance_settings.capitalise_floor_base IS
'EQP-2b:绝对下限,以本位币计。低于它一律不算达标,哪怕百分比够了 ——
一台便宜机器上换个几十块的件,不该因为它占原值 10% 就被建议资本化。
引导值 1000。允许为 0(= 不设下限),所以 CHECK 是 >= 0 而不是 > 0。';

ALTER TABLE public.maintenance_settings ENABLE ROW LEVEL SECURITY;
-- 读:与保养记录同一个 OR(机器卡在财务、干活的人在加工,两边都要读得到阈值)。
CREATE POLICY "maintenance_settings select by permission" ON public.maintenance_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text) OR has_permission('module.processing.view'::text));
-- 改阈值是财务侧的事(它是一条会计政策),不是车间的。
CREATE POLICY "maintenance_settings update by permission" ON public.maintenance_settings
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text))
    WITH CHECK (has_permission('module.finance.edit'::text));

-- ════════════════════════════════════════════════════════════════════════════
-- 2 · 保养与维修记录
-- ════════════════════════════════════════════════════════════════════════════
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

-- ════════════════════════════════════════════════════════════════════════════
-- 3 · 资本化建议:阈值【现读配置】,而它只说话、不拦人
-- ════════════════════════════════════════════════════════════════════════════
-- 【一个数都没写死】两个阈值都现读 maintenance_settings —— 与 grn_discrepancies
-- 读 receiving_settings 是同一条。fixture 76 立下的判据:在同一个事务里改配置,
-- 看结论【两个方向都】动;只调一个方向,一个"永远返回同一个答案"的实现也能过。
--
-- 【它只答得了两半里的一半,所以它只建议】是否资本化 = 延长寿命或提高产能
-- (人的判断)【并且】花费够大(这个数)。**一个看不见完整答案的检查,
-- 可以提醒,不可以拒绝** —— 所以这里没有任何拒绝,只有一列 meets_threshold。
--
-- 【"机器的成本"用的是 fixed_assets.cost_base,而它是【记录成本】不是取得原价】
-- EQP-1b-iii 之后它等于未冲销成本明细之和,每资本化一次就长大一次。
-- 取得原价没有单独存过(零成本卡 + 后补发票那条路径下,"第一条明细"也不等于它)。
-- **两者的区别在第一次资本化大修之后才开始咬人**,而那时"阈值该按取得价还是按
-- 当前账面值算"是一次会计决定,不是一个可以在这里悄悄选掉的默认值。
-- 到那一天,答案会变成 maintenance_settings 上的第三个字段,或者一个新的口径列。
--
-- 【没有花费的行不下任何断言】没有 expense_id 就没有金额,于是
-- meets_threshold 是 NULL —— 那不是"不达标",是"这件事还没有钱可谈"。
-- (与 processing_metal_recovery 对"没测含量"的处置同一条:空不是零。)
CREATE VIEW public.equipment_maintenance_advice WITH (security_invoker = off) AS
 SELECT m.id AS maintenance_id,
    m.equipment_id,
    fa.code AS equipment_code,
    m.performed_on,
    m.kind,
    m.capitalised,
    m.expense_id,
    e.amount_base AS work_cost_base,
    fa.cost_base  AS equipment_cost_base,
    s.capitalise_pct_of_cost,
    s.capitalise_floor_base,
    -- 这次活占机器记录成本的百分比。机器成本为 0 时【不下断言】——
    -- 除以零得不到一个百分比,而 0 会读成"不达标"。
    CASE WHEN e.amount_base IS NULL OR fa.cost_base IS NULL OR fa.cost_base = 0
         THEN NULL::numeric
         ELSE round(e.amount_base / fa.cost_base * 100, 2)
    END AS pct_of_equipment_cost,
    -- 【两个条件【都】要满足】只看百分比,便宜机器上换个轴承就达标;
    -- 只看绝对值,贵机器上的大修反而够不着。
    CASE WHEN e.amount_base IS NULL OR fa.cost_base IS NULL OR fa.cost_base = 0
         THEN NULL::boolean
         ELSE (e.amount_base / fa.cost_base * 100 >= s.capitalise_pct_of_cost)
              AND (e.amount_base >= s.capitalise_floor_base)
    END AS meets_threshold
   FROM equipment_maintenance m
   JOIN fixed_assets fa ON fa.id = m.equipment_id
   LEFT JOIN expenses e ON e.id = m.expense_id AND e.status = 'posted'
   CROSS JOIN maintenance_settings s
  WHERE has_permission('module.finance.view'::text) OR has_permission('module.processing.view'::text);

COMMENT ON VIEW public.equipment_maintenance_advice IS
'EQP-2b:每一条保养/维修记录的【资本化建议】—— 阈值现读 maintenance_settings,
一个数都没写死(与 grn_discrepancies 读 receiving_settings 同一条)。
**它只说"够/不够",从不拦人、也从不替谁下结论。** 是否资本化的判据有两半,
系统只答得了"花费够不够大"那一半;另一半(延长寿命还是维持原状)是人的判断。
一个看不见完整答案的检查,可以提醒,不可以拒绝。
【meets_threshold 为 NULL 的两种情形,都不是"不达标"】没有挂支出单(这件活
没花钱,或者钱还没记),以及机器的记录成本为 0(零成本卡还没拿到发票)——
空不是零。
【已冲销的支出不算】LEFT JOIN 上带着 e.status = ''posted''。
【口径:equipment_cost_base 是【记录成本】,不是取得原价】见本视图上方迁移
注释里那一段 —— 两者的区别在第一次资本化大修之后才开始咬人,而那时该按哪个算
是一次会计决定。';

COMMIT;
