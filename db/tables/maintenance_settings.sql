-- db/tables/maintenance_settings.sql
-- EQP-2b:资本化阈值的单行配置(形状取自 receiving_settings / processing_settings)。
--
-- 【它只建议,从不拦】—— 这是本表存在方式的全部要点。判据有两半:
-- ① 这次修理延长了寿命或提高了产能吗(人的判断,任何查询都做不出来);
-- ② 花的钱够不够大(一个数)。系统只答得了第二半,所以它只说"够/不够"。
-- 一个看不见完整答案的检查,可以提醒,不可以拒绝。
--
-- 【RUNTIME CONFIG】运营改得动,所以 check_mirrors 不逐行比对它的内容 ——
-- 线上与文件不同【是系统在正常工作】。但引导那一行必须在(bootstrap 判词)。
-- 【列的语义变了要回来重读这个文件】—— AGENTS.md 那一节:改了含义而没改列名的
-- 迁移,没有任何一道检查看得见。
--
-- 【重放顺序:它必须在 db/views/equipment_maintenance_advice.sql 之前存在】——
-- 而 tables 本就排在 views 前面,所以不需要任何特殊处理。
--
-- NOTE: introduced by db/migrations/2026-08-21-eqp2b-maintenance-and-repair-records.sql.
-- First-run script (plain CREATEs).

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
