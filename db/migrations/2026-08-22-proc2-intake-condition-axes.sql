-- PROC-2(2026-08-22):进料的【状态轴】—— 五条轴,五张字典。
--
-- 依据在 docs/proc-reality.md(U0)。本刀只动【主数据】与【收货记录】:
-- 加工单、化验、计价一律没碰。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【统治规则,写在最前面,因为它决定了这一刀的边界】
--   **一个【取值】将来可以用一【行】的代价加进来;一条【轴】不行** ——
--   轴是一列,加上它的每一个读者。所以【轴在本刀定死,取值可以后到】。
--
-- 【grill 的结论:五条轴各自决定的东西不重复,但【三条是有条件适用的】】
--   * FORM 只对【电池料】成立(kind 的事);
--   * SIZE FORMAT 只在【那个形态需要拆解】时成立 —— 黑粉没有拆解可言;
--   * SOURCE 的 implies_never_charged 与 SAFETY STATE 的 charged/discharged
--     【会互相矛盾】:厂内边角料从来没充过电,它不可能是"未放电"。
--   **每一个条件都做成【字典行上的一列】,不是散文。** 这是 D3 的形状,
--   也是 PROC-1 把 may_ever_be_processed 放在字典行上的同一条。
--
-- 【一处对 brief 的偏离(N29 的答复)】brief 的散文写「two-wheeler and light
-- mobility」「industrial vehicles and equipment」,而我给的代码名是
-- `light_mobility` / `industrial_equipment` —— **面板里那六行一行不少,
-- 但其中两行把最好认的那个词从代码名里改没了**,于是读起来像是被悄悄删掉了。
-- 那正是"一份清单的两种表示不共享词汇"的小号版本。**代码名改成 `two_wheeler`。**
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 形态(在物料上)══════════════════════════════════════════════════
CREATE TABLE public.material_forms (
    code               text PRIMARY KEY,
    name_en            text NOT NULL,
    name_zh            text NOT NULL,
    -- 【规则列】这个形态要不要拆解 —— SIZE FORMAT 只在它为 true 时才有意义。
    implies_dismantling boolean NOT NULL,
    is_active          boolean NOT NULL DEFAULT true,
    sort_order         integer NOT NULL DEFAULT 0,
    notes              text
);

COMMENT ON TABLE public.material_forms IS
'PROC-2:这一种物料【是什么形态】。RUNTIME CONFIG,加一种是加一行。

【它决定什么】**货进哪一条链。** 整包 / 模组 / 散电芯要拆;极片废料与黑粉不拆;
未分选的混合料要先分选。这是五条轴里后果最大的一条,而它在原来那四条里【没有】。

【black_mass 这个值按【物质】命名,永远不按【来源】命名】
Evoltrya 自己就产黑粉,而某一批黑粉是买来的还是自己产的,
**已经由"它有没有进料批 / 产出批"回答了**。把方向编码进物料的属性,
正是 materials.category 干过的事 —— 而 F1 在线上实测证伪了它:
一行标着「进料」的物料挂着 10 个产出批。**不要换个名字把它请回来。**

【implies_dismantling 是一条规则,不是一个描述】size_format 那条轴只在它为
true 时才成立;为 false 时 size_format 留空【不是"没人决定"】,是"不适用" ——
而这个区别由这一列回答,不靠人去猜。';

COMMENT ON COLUMN public.material_forms.implies_dismantling IS
'PROC-2:这个形态要不要拆解。**它是 size_format 那条轴的适用条件** ——
为 false 时(黑粉、极片废料)那条轴不适用,留空是"不适用"而不是"没人决定过"。
本仓库为"空的两种意思"付过很多次账(METAL-1 的 no_reference、SS-1 的阈值),
所以这里让【数据】回答,不让读的人猜。';

INSERT INTO public.material_forms (code, name_en, name_zh, implies_dismantling, sort_order, notes) VALUES
    ('whole_pack',     'Whole pack',                '整包',       true,  1, '整只电池包,带壳体与管理系统。拆解量最大。'),
    ('module',         'Module',                    '模组',       true,  2, '已拆到模组一级。'),
    ('loose_cells',    'Loose cells',               '散电芯',     true,  3, '已拆到电芯,仍需要开壳。'),
    ('electrode_scrap','Electrode scrap / offcuts', '极片废料',   false, 4, '产线上的极片边角料与废片。【不需要拆解】—— 它本来就是散料,所以 size_format 对它不适用。'),
    ('black_mass',     'Black mass',                '黑粉',       false, 5, '按【物质】命名,不按来源。自己产的与买进来的是同一种物质;哪一批是哪一种,由它有没有进料批/产出批回答。【不需要拆解】。'),
    ('mixed_unsorted', 'Mixed, unsorted',           '混合未分选', true,  6, '来料没分过。要先分选才谈得上进哪条链 —— 所以它按【要拆解】处理。');

-- ═══ 2 · 来源(在物料上)══════════════════════════════════════════════════
CREATE TABLE public.material_sources (
    code                 text PRIMARY KEY,
    name_en              text NOT NULL,
    name_zh              text NOT NULL,
    -- 【规则列】这一来源的料【从来没有充过电】—— 于是"要不要放电"这个问题
    -- 对它根本不成立(不是"已放电",是"没有可放的")。
    implies_never_charged boolean NOT NULL,
    is_active            boolean NOT NULL DEFAULT true,
    sort_order           integer NOT NULL DEFAULT 0,
    notes                text
);

COMMENT ON TABLE public.material_sources IS
'PROC-2:这一种物料【从哪来】。RUNTIME CONFIG,加一种是加一行。

【它决定什么】**废物代码,以及【要不要放电】这个问题成不成立。**

【与 suppliers.supplier_types 【互相独立】,不设外键 —— 三条理由,都是量过的】
1. **那一列今天【没有字典】。** suppliers.supplier_types 是 text[],**没有 CHECK、
   也没有查找表**(app/suppliers/supplierTypes.ts 的抬头自己写着这句)。
   给一张带外键的新字典去引用一个自由文本数组,等于把漂移接过来。
2. **两者问的不是同一件事。** supplier_types 问"这一家做哪一行",
   本表问"这一批料从哪来"。**一个贸易商可以卖厂内边角料,一个拆解商可以卖退役料。**
3. **基数就不对。** 实测线上:SUP-2026-0003 是 [dismantler, recycler]、
   SUP-2026-0002 是 [recycler, trader] —— 供应商类型是【多值】的,
   从它根本推不出一批料的单一来源。

**所以不要"统一"它们。** 哪一天 supplier_types 变成字典(它自己的一刀),
两者仍然是两张表 —— 那一刀不该顺手把这一条并进去。';

COMMENT ON COLUMN public.material_sources.implies_never_charged IS
'PROC-2:这一来源的料【从来没有充过电】(厂内边角料)。

【它存在的理由是防一次【互相矛盾】】没有它,一批 production_scrap 的料
可以同时被标成 safety_state = charged_not_discharged —— 而那在物理上不可能。
**两列能互相矛盾,就是 brief 说的"迟早会跟它的孪生兄弟打架的那一列"。**
这一列把话说死:为 true 时,"充没充电"这个问题对它【不成立】,
而不是"答案是已放电"。**两者不一样:后者意味着有人放过电,前者意味着没什么可放。**
读它的是 PROC-3 那道闸(见 material_forms 表注末尾那句排期)。';

INSERT INTO public.material_sources (code, name_en, name_zh, implies_never_charged, sort_order, notes) VALUES
    ('production_scrap', 'Production scrap',          '厂内边角料', true,  1, '电池厂产线上的废料。【从来没有充过电】—— 所以"要不要放电"对它不成立。'),
    ('end_of_life',      'End-of-life',               '退役料',     false, 2, '用过的电池。荷电状态未知,必须逐批看 safety_state。'),
    ('customer_return',  'Customer return / reject',  '客户退货',   false, 3, '客户退回或判废的货。可能是新的、也可能用过 —— 同样逐批看。');

-- ═══ 3 · 规格尺寸(在物料上)══════════════════════════════════════════════
CREATE TABLE public.material_size_formats (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.material_size_formats IS
'PROC-2:这一种电池【来自哪一类应用】。RUNTIME CONFIG,加一种是加一行。

【它决定什么】**拆解工作量与搬运方式。** 这是这条轴唯一的判据(Tim 定的),
每一个值都要过这一关:它是不是意味着【不一样的拆解工作量与搬运方式】。

【本表【没有规则列】,而这是刻意的】其余四条轴各自驱动一条规则(要不要拆、
充没充过电、能不能投料),所以规则住在它们的字典行上(D3)。
**这一条不驱动任何数据库规则** —— 它描述工作量,而工作量今天没有任何一处
被系统读去做判断。**给它加一个没人读的规则列,就是"一个没人用的枚举值
教下一个人这一类在用"的同一种病。**

【适用条件不在本表,在 material_forms.implies_dismantling】
黑粉与极片废料没有拆解可言,所以它们的 size_format 留空【是"不适用"】——
那个区别由那一列回答。

【medical_aerospace 被【考虑过并且划掉了】,不是漏了】见下面那条 notes 的做法:
划掉的理由与回来的条件都写下来,因为在这个仓库里
【一次考虑过的省略,如果没有写下来,与一次疏忽长得一模一样】。
**返回条件:第一次真的收到医疗或航空电池。** 那时它是一行。';

INSERT INTO public.material_size_formats (code, name_en, name_zh, sort_order, notes) VALUES
    ('ev_traction',          'EV traction (passenger & commercial)', '电动车动力电池', 1, '乘用车与商用车的动力包。螺栓固定、高压,拆解量最大。'),
    ('two_wheeler',          'Two-wheeler & light mobility',         '两轮与轻型出行',  2, '电动两轮车、滑板车一类。多为手工可开的小包。'),
    ('ess_ups',              'ESS, UPS & data-centre backup',        '储能与后备电源',  3, '储能柜、UPS、机房后备。模块化,单件重。'),
    ('industrial_equipment', 'Industrial vehicles & equipment',      '工业车辆与设备',  4, '叉车、AGV 一类。'),
    ('consumer_electronics', 'Consumer electronics & power tools',   '消费电子与电动工具', 5, '手机、笔电、电动工具电池。散装来料为主。');

-- ═══ 4 · 安全状态(在【进料批】上,多值)══════════════════════════════════
CREATE TABLE public.inbound_safety_states (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    -- 【规则列】带着这个状态的一批料,能不能被投料。
    may_be_fed boolean NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.inbound_safety_states IS
'PROC-2:这一【批】料的安全状态。**多值** —— 一批料可以同时是"进过水"与"破损"。
挂在进料批上而不是物料上,因为它逐批不同,而且只有收货的人看得见。
RUNTIME CONFIG,加一种是加一行。

【它决定什么】**能不能投料(may_be_fed),以及怎么存放。**
存放那一半今天【没有落点】—— 系统里没有任何"存放要求"的机制。
所以本表只做前一半,后一半记成一条待办而不是一个没人读的列
(一个没人用的列教下一个人"这件事已经在管了")。

════════════════════════════════════════════════════════════════════════════
【热失控历史【被考虑过,并且 Tim 决定不要】—— 这是一个决定,不是一个遗漏】
它不在下面的取值里,**而这句话必须写在这里**:在这个仓库里,
一次考虑过的省略如果没有写下来,与一次疏忽长得一模一样,
于是下一个人会把它当成漏掉的补进来 —— 而那会推翻一个已经做过的决定。
**不要因为"看起来少了一个"就加它。** 要加,先去问 Tim。
════════════════════════════════════════════════════════════════════════════

【may_be_fed 与 inbound_chemistry_certainties.may_be_fed 是【两个理由,同一个后果】】
一个讲危险,一个讲认不认得出来。**PROC-3 那道闸要把它们【相与】,
任何一个单独都不充分。** 两处注释互相点名,免得有人以为读一个就够了。

【下面这些 may_be_fed 是【引导默认值】,不是决定】与 certificate_types.disposition
同一条:Tim 在界面上改一行,线上就与本文件不同,那是系统在正常工作。';

COMMENT ON COLUMN public.inbound_safety_states.may_be_fed IS
'PROC-2:带着这个状态的料能不能被投料。**这一列只是【记录事实】,它自己不拦任何人** ——
读它的那道闸是 PROC-3(见 D4:那道前置条件加在 commit_processing_run 上,
它已经有三条同形的生命周期前置:WO_NOT_RELEASED / EQUIPMENT_NOT_ACQUIRED /
EQUIPMENT_DISPOSED)。**本刀只记事实,不建闸** —— 它的缺席是排期,不是遗漏。';

INSERT INTO public.inbound_safety_states (code, name_en, name_zh, may_be_fed, sort_order, notes) VALUES
    ('charged_not_discharged', 'Charged, not yet discharged', '带电未放电', false, 1,
     '还带着电。**未放电的电芯进破碎机就是一场火** —— 这是本轴存在的首要理由。'
     || '【注意它与 material_sources.implies_never_charged 的关系】厂内边角料从来没充过电,'
     || '所以这个状态对它【不成立】,而不是"它已经放过电了"。两者不一样。'),
    ('discharged_verified',    'Discharged and verified',     '已放电并核验', true,  2,
     '放过电,而且有人核验过。【"核验过"是这个值的一半】—— 没核验的放电与没放电,在事故面前是同一件事。'),
    ('damaged_deformed',       'Damaged or deformed',         '破损或变形',   false, 3,
     '外壳破损、变形。引导默认不许投料 —— Tim 改一行即可。'),
    ('water_exposed',          'Water-exposed',               '进过水',       false, 4,
     '泡过水或受潮。引导默认不许投料。【它可能在干燥后可投】,而那是一个判断 —— 改这一行,不要绕过它。'),
    ('swollen_leaking',        'Swollen or leaking',          '鼓包或漏液',   false, 5,
     '鼓包、漏液。引导默认不许投料。');

-- ═══ 5 · 化学体系确定度(在【进料批】上)══════════════════════════════════
CREATE TABLE public.inbound_chemistry_certainties (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    may_be_fed boolean NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.inbound_chemistry_certainties IS
'PROC-2:对【这一批】料的化学体系,我们知道多少。挂在进料批上,逐批不同。

【它决定什么】**能不能投料** —— 一批认不出化学体系的料,在认出来之前不许进炉。
"能不能与别的料【同炉】"是另一个问题,归 G19(化学体系隔离),不在本刀。

════════════════════════════════════════════════════════════════════════════
【它与 materials.chemistry 【不是同一件事的两个名字,是两件事】(Tim 裁定)】
  * `materials.chemistry = 混合` → **这一种物料【就是】混合料。**
    这是这一行里正当且常见的主数据:一种你有意按混合料买进、存放、卖出的东西。
  * 本表 `mixed`                → **这一批货【结果是】混合的**,不管卡片怎么写。

**两者可以同时成立,也可以各自独立成立**:一批 NMC 物料的货可能来的时候是混的,
而一批混合料的货也可能完全如预期。
**所以【不要】把 混合 从化学体系字典里禁掉** —— 那会变成"不许把混合料登记成一种物料",
而那是正常做法。G18(化学体系变字典)那一刀要写的是【分工】,不是禁令,
而且**两边要用同一句话**,让下一个人无论先打开哪一个都读到同一段。
════════════════════════════════════════════════════════════════════════════

【三个状态的界必须写死,否则它们会在门口塌成两个(Tim 点名)】
**`mixed` 的意思是【我们知道它是混的】—— 一个已经确立的事实。**
它【绝不】是"我们分不出来"。分不出来的那一种叫 `unknown_pending`。
**站在一个乱糟糟的集装箱前面的人最容易把这两个搞混**,而这与
「测出来是零」对「从来没测过」是同一个形状 —— 这个仓库为它付过一次账了。';

INSERT INTO public.inbound_chemistry_certainties (code, name_en, name_zh, may_be_fed, sort_order, notes) VALUES
    ('single_known',    'Single, known chemistry',        '单一已知',   true,  1,
     '这一批是单一化学体系,而且知道是哪一种。'),
    ('mixed',           'Mixed (known to be mixed)',      '已知混合',   true,  2,
     '**【我们知道它是混的】—— 一个确立的事实,不是"分不出来"。** 分不出来的那一种是 unknown_pending。'),
    ('unknown_pending', 'Unknown, pending identification', '待识别',    false, 3,
     '还没认出来。**在认出来之前不许投料** —— 而这与"已知是混的"完全不同:'
     || '后者可以投,前者不行,因为我们根本不知道投进去的是什么。');

-- ═══ 6 · 字典的读写策略(五张同一处置)════════════════════════════════════
-- 【目录不敏感】与 certificate_types / material_kinds / waste_classifications 同。
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['material_forms','material_sources','material_size_formats',
                             'inbound_safety_states','inbound_chemistry_certainties'] LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY "%s select all" ON public.%I AS PERMISSIVE FOR SELECT TO authenticated USING (true)', t, t);
        EXECUTE format('CREATE POLICY "%s insert by permission" ON public.%I AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission(%L))', t, t, 'module.materials.edit');
        EXECUTE format('CREATE POLICY "%s update by permission" ON public.%I AS PERMISSIVE FOR UPDATE TO authenticated USING (has_permission(%L)) WITH CHECK (has_permission(%L))', t, t, 'module.materials.edit', 'module.materials.edit');
    END LOOP;
END $$;

-- ═══ 7 · 物料上的三列 ═════════════════════════════════════════════════════
ALTER TABLE public.materials
    ADD COLUMN form_code        text REFERENCES public.material_forms (code),
    ADD COLUMN source_code      text REFERENCES public.material_sources (code),
    ADD COLUMN size_format_code text REFERENCES public.material_size_formats (code);

COMMENT ON COLUMN public.materials.form_code IS
'PROC-2:这一种物料是什么形态 —— 决定货进哪一条链。
【只对带状态轴的种类成立】适用条件是 material_kinds.has_condition_axes;
不适用时留空【是"不适用"】,不是"没人决定过"。那个区别由那一列回答。';

COMMENT ON COLUMN public.materials.source_code IS
'PROC-2:这一种物料从哪来 —— 决定废物代码,以及"要不要放电"这个问题成不成立。
【与供应商类型互相独立】理由(三条,都量过)写在 material_sources 的表注上。';

COMMENT ON COLUMN public.materials.size_format_code IS
'PROC-2:来自哪一类应用 —— 决定拆解工作量与搬运方式。
【适用条件是 material_forms.implies_dismantling】黑粉与极片废料没有拆解可言,
所以它们这一列留空【是"不适用"】。**这是本刀里第二处"空有两种意思"的地方,
而两处都由数据回答,不由读的人猜。**';

-- ═══ 8 · 适用条件:字典上多一列(PROC-1 那张字典)══════════════════════════
-- 【为什么加在 material_kinds 上而不是写死 'battery_material'】
-- 写死一个 code 到 CHECK 或触发器里,就把 PROC-1 刚做成数据的东西又变回了代码。
-- 加一列 = 一次加法,而将来"哪些种类有状态轴"改一行数据即可。
ALTER TABLE public.material_kinds
    ADD COLUMN has_condition_axes boolean NOT NULL DEFAULT false;

UPDATE public.material_kinds SET has_condition_axes = true WHERE code = 'battery_material';

COMMENT ON COLUMN public.material_kinds.has_condition_axes IS
'PROC-2:这一类物料要不要回答【状态轴】(形态 / 来源 / 规格尺寸)。

【为什么只有 battery_material 是 true】那三条轴的取值全部是电池形状的
(整包 / 模组 / 散电芯 / 极片废料 / 黑粉;退役料 / 厂内边角料;EV / 两轮 / 储能…)。
包装、耗材、备件没有形态可言;**电子废料(ewaste)也没有** ——
它不是电池,那套取值对它一个都不合适。ewaste 将来若要自己的一套轴,
那是它自己的一刀,不是把这三条硬套过去。

【它是【适用条件】,不是【重要性】】为 false 时那三列留空的意思是"不适用",
而不是"没人决定过" —— 而这正是本仓库反复付账的那个区别。';

-- ═══ 9 · 有条件的必填 —— 触发器(跨表,CHECK 看不见另一张表)═══════════════
CREATE OR REPLACE FUNCTION public.guard_material_condition_axes()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_needs boolean;
    v_dismantle boolean;
BEGIN
    -- 种类还没说 → 不是本守卫的事(materials_kind_stated 管那一条)。
    -- 【八行历史物料正落在这里】它们 kind_code 为空,本守卫对它们一言不发。
    IF NEW.kind_code IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT mk.has_condition_axes INTO v_needs FROM material_kinds mk WHERE mk.code = NEW.kind_code;
    IF NOT COALESCE(v_needs, false) THEN
        -- 【这一类没有状态轴 —— 那三列必须【空着】,不许填】
        -- 允许填,就等于允许"一箱吨袋是整包形态"这种句子存在。
        IF NEW.form_code IS NOT NULL OR NEW.source_code IS NOT NULL OR NEW.size_format_code IS NOT NULL THEN
            RAISE EXCEPTION 'MATERIAL_KIND_HAS_NO_CONDITION_AXES|%', NEW.kind_code
              USING HINT = '这一类物料没有形态/来源/规格尺寸可言;要填这三列,先改它的种类。';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.form_code IS NULL OR NEW.source_code IS NULL THEN
        RAISE EXCEPTION 'MATERIAL_CONDITION_AXES_REQUIRED|%', NEW.kind_code
          USING HINT = '这一类物料要说出形态与来源 —— 两者都永远不会替你填。';
    END IF;
    SELECT mf.implies_dismantling INTO v_dismantle FROM material_forms mf WHERE mf.code = NEW.form_code;
    IF v_dismantle THEN
        IF NEW.size_format_code IS NULL THEN
            RAISE EXCEPTION 'MATERIAL_SIZE_FORMAT_REQUIRED|%', NEW.form_code
              USING HINT = '这个形态需要拆解,所以要说出它来自哪一类应用(拆解工作量由它决定)。';
        END IF;
    ELSE
        -- 【不拆解的形态不许有规格尺寸】黑粉没有"来自哪一类应用"可言 ——
        -- 允许填,那一列就会长出一堆没人能依据的值,而空与非空再也分不清含义。
        IF NEW.size_format_code IS NOT NULL THEN
            RAISE EXCEPTION 'MATERIAL_SIZE_FORMAT_NOT_APPLICABLE|%', NEW.form_code
              USING HINT = '这个形态不需要拆解(黑粉、极片废料),规格尺寸对它不适用。';
        END IF;
    END IF;
    RETURN NEW;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.guard_material_condition_axes() FROM PUBLIC, anon;

COMMENT ON FUNCTION public.guard_material_condition_axes() IS
'PROC-2:三条物料级状态轴的【有条件必填】,以及它的反面【不适用就不许填】。

【为什么两个方向都要拦】只拦"该填没填",那一列就会在不适用的行上长出值,
于是"空"再也不只有一种意思 —— 而把空的两种意思分开,正是这三条轴存在的理由之一。

【它管不到什么】它保证这三列【被回答了】,保证不了【答对了】:
一批实际是模组的料被登记成整包,schema 看不见。那一半靠收货的人与走查。

【适用条件全部是【数据】,不是写死的 code】
  * 哪些种类要回答 → material_kinds.has_condition_axes
  * 哪些形态要说规格尺寸 → material_forms.implies_dismantling
改一行数据就改行为,而这正是 PROC-1 把 CHECK 换成字典换来的东西。';

CREATE TRIGGER trg_materials_condition_axes
    BEFORE INSERT OR UPDATE ON public.materials
    FOR EACH ROW EXECUTE FUNCTION public.guard_material_condition_axes();

-- ═══ 10 · 进料批上的化学体系确定度 ═════════════════════════════════════════
-- ════════════════════════════════════════════════════════════════════════════
-- 【inbound_batches 是【遮蔽表】,所以这是【三件事,一支迁移】(WO-1a 那一课)】
-- 实测:24 列、23 列有列级 SELECT 授权(unit_price 是被扣住的那一个)、
-- 无表级 SELECT 授权、且有 inbound_batches_masked 伴生视图。
-- 于是加一列必须同时做三件事,少一件 gate 的 colgrant 判词就红:
--   ① ADD COLUMN;② 加进列级 GRANT SELECT(非敏感);③ 加进 _masked 视图。
-- **判据是 `(NOT granted AND NOT in_view) OR (has_view AND NOT in_view)`** ——
-- 一张表一旦有了 _masked 伴生,【每一列都必须在那张视图里】,授权与否都一样。
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.inbound_batches
    ADD COLUMN chemistry_certainty_code text
        REFERENCES public.inbound_chemistry_certainties (code);

COMMENT ON COLUMN public.inbound_batches.chemistry_certainty_code IS
'PROC-2:对【这一批】料的化学体系我们知道多少 —— 逐批不同,只有收货的人看得见。
【与 materials.chemistry 不是同一件事】那一列说"这一种物料【是】什么",
本列说"这一批货我们【知道】什么"。两者可以同时成立、也可以各自独立成立:
一批 NMC 物料的货可能来的时候是混的,一批混合料的货也可能完全如预期。
**同一段话写在 inbound_chemistry_certainties 的表注上,两边一字不差** ——
下一个人无论先打开哪一个,读到的都是同一句(Tim 点名要这样)。
【可空】既有进料批不回填 —— 空的意思是"没有人记过",而那是真话。';

-- ② 列级授权(非敏感:它是一个状态码,不是钱)
GRANT SELECT (chemistry_certainty_code) ON public.inbound_batches TO authenticated;

-- ③ 遮蔽视图跟着长一列
-- 【这里【不能】DROP + CREATE,而这是跑出来才知道的】实测:
--     ERROR: cannot drop view inbound_batches_masked because other objects depend on it
--     DETAIL: ap_open_items / batch_assay_status(→ operations_now)/
--             po_prepayment_applicable / po_receivable_lines / purchase_order_status
-- **五张下游视图挂在它身上,其中一条通到 operations_now。**
-- DROP ... CASCADE 会把它们一起删掉,而那是一次静默的大破坏。
-- 【CREATE OR REPLACE 在这里【合法】,因为新列加在末尾】PostgreSQL 允许
-- CREATE OR REPLACE VIEW 往【末尾】追加列,只要既有列的名字、类型、顺序一字不动。
-- 这正是本刀的情形 —— 所以列契约没变,五张下游视图一个都不用动。
CREATE OR REPLACE VIEW public.inbound_batches_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    supplier_id,
    quantity,
    unit,
    remaining_qty,
    arrival_date,
    stage,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    purchase_order_id,
    purchase_order_line_id,
    pricing_formula_id,
    pricing_status,
    deleted_by,
    delete_reason,
    declared_qty,
    chemistry_certainty_code
   FROM inbound_batches
  WHERE has_permission('module.inbound.view'::text);

GRANT SELECT ON public.inbound_batches_masked TO authenticated;

-- ═══ 11 · 安全状态:多值 → 连接表 ══════════════════════════════════════════
CREATE TABLE public.inbound_batch_safety_states (
    inbound_batch_id  uuid NOT NULL REFERENCES public.inbound_batches (id) ON DELETE CASCADE,
    safety_state_code text NOT NULL REFERENCES public.inbound_safety_states (code),
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    -- 【一批料的同一个状态只记一次】主键就是那条规矩 ——
    -- 重复一行不是"更确定",它只会让任何按状态计数的读法开始骗人。
    PRIMARY KEY (inbound_batch_id, safety_state_code)
);

COMMENT ON TABLE public.inbound_batch_safety_states IS
'PROC-2:一批料【身上的安全状态】,一行一个。**多值,而且这是它单独成表的全部理由** ——
一批料可以同时是「进过水」与「破损」,而一个单值的列表达不了它。

【主键 = (批次, 状态)】同一个状态在同一批上只记一次。重复不是"更确定",
它只会让任何按状态计数的读法开始骗人。

【没有安全状态行 = 没有人记过,【不是】"安全"】这与本仓库反复付账的那个区别
是同一个(METAL-1 的 no_reference、SS-1 的阈值为 NULL、PROC-1 的 may_be_processed)。
读它的屏幕与 PROC-3 那道闸都必须把"一条都没有"按名说出来,而不是当成通过。';

CREATE INDEX idx_inbound_batch_safety_states_batch
    ON public.inbound_batch_safety_states (inbound_batch_id);

ALTER TABLE public.inbound_batch_safety_states ENABLE ROW LEVEL SECURITY;
-- 【跟着父单据判】与 assay_result_metals 同一条:哪个模块能读/写父,哪个就能读/写行。
CREATE POLICY "inbound_batch_safety_states select by permission"
    ON public.inbound_batch_safety_states
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'::text));
CREATE POLICY "inbound_batch_safety_states insert by permission"
    ON public.inbound_batch_safety_states
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'::text));
CREATE POLICY "inbound_batch_safety_states delete by permission"
    ON public.inbound_batch_safety_states
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inbound.edit'::text));

COMMIT;
