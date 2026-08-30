-- db/tables/material_forms.sql
-- PROC-2:这一种物料【是什么形态】—— 决定货进哪一条链。
--
-- 【RUNTIME CONFIG】加一种是加一行(与 certificate_types / material_kinds /
-- waste_classifications 同形,check_mirrors 不逐行比对内容)。
-- 【每一条轴都是字典,不是枚举、不是自由文本】理由是 F7,而它在这个仓库里
-- 已经发作过:materials.category 长出四种命名法而没有任何东西察觉,
-- 而那笔转换成本不是渐渐变贵,是会变成【不可能】。
--
-- NOTE: introduced by db/migrations/2026-08-22-proc2-intake-condition-axes.sql.
-- First-run script (plain CREATEs).

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

-- ── PROC-BUILD-1(R5):可售性 ──────────────────────────────────────────────
-- 【ALTER 加的列排在末尾】线上 attnum = 8,镜像必须照它的顺序,否则 gate 的
-- 「镜像 vs 线上」判词会把同一张表读成两张(AGENTS.md 的镜像规矩)。
ALTER TABLE public.material_forms ADD COLUMN may_be_sold boolean NOT NULL;

INSERT INTO public.material_forms (code, name_en, name_zh, implies_dismantling, may_be_sold, sort_order, notes) VALUES
    ('whole_pack',     'Whole pack',                '整包',       true,  true,  1, '整只电池包,带壳体与管理系统。拆解量最大。'),
    ('module',         'Module',                    '模组',       true,  true,  2, '已拆到模组一级。'),
    ('loose_cells',    'Loose cells',               '散电芯',     true,  false, 3, '已拆到电芯,仍需要开壳。**不可售(R5)。**'),
    ('electrode_scrap','Electrode scrap / offcuts', '极片废料',   false, true,  4, '产线上的极片边角料与废片。【不需要拆解】—— 它本来就是散料,所以 size_format 对它不适用。'),
    ('black_mass',     'Black mass',                '黑粉',       false, true,  5, '按【物质】命名,不按来源。自己产的与买进来的是同一种物质,哪一批是哪一种由它有没有进料批/产出批回答。【不需要拆解】。'),
    ('mixed_unsorted', 'Mixed, unsorted',           '混合未分选', true,  true,  6, '来料没分过。要先分选才谈得上进哪条链 —— 所以它按【要拆解】处理。'),
    ('de_cased_cell',    'De-cased cell',    '已开壳电芯', true,  false, 7,  '【R2】电芯开壳之后、极片分离之前的那一格。**它与 loose_cells 不是一回事** —— 后者的表注写着仍需要开壳。它仍要再拆(极片分离),所以 implies_dismantling 为真。**它也可以是买进来的**,而买进来的与自己产的是同一种物质。**不可售(R5)。**'),
    ('cathode_sheet',    'Cathode sheet',    '正极片',     false, true,  8,  '【R2】极片分离机的产出之一。**不是 electrode_scrap** —— 那是边角料与废片,这是产品。它可以进极片粉料线,也可以卖(R5:正极片【可以】卖)。'),
    ('anode_sheet',      'Anode sheet',      '负极片',     false, false, 9,  '【R2】极片分离机的产出之一。可以修复,也可以粉化。**不可售(R5)。**'),
    ('separator',        'Separator',        '隔膜',       false, true,  10, '【R2/R4】极片分离机的产出之一,而且它是一个【出口】—— 它离开这条线,不再往下走。'),
    ('casing',           'Casing',           '壳体',       false, true,  11, '【R2/R4】开壳与人工拆解都产出它,而且它是一个【出口】。**它去哪取决于它是什么材质做的,而那件事今天无从知道**(线上产出批化验 0 条)—— 所以只建这个形态,【不建】它的去向。'),
    ('structural_parts', 'Structural parts', '结构件',     false, true,  12, '【R2】人工拆解包与模组时【同时】产出的那些 —— 支架、螺栓、线束一类。它是一个【出口】。**它单独成一行而不并进 casing**,因为 R2 把两者并列点名,而它们的材质与去向不必相同。'),
    ('electrolyte',      'Electrolyte',      '电解液',     false, true,  13, '【R4】目前计划**挥发掉** —— 它既不是产品也不是废物收据,是【消失掉的质量】。环保设备可能后加,那时它才会变成一条真的物料流。**它同时也是一个损耗类别**(loss_categories.electrolyte_evaporation)。');

ALTER TABLE public.material_forms ENABLE ROW LEVEL SECURITY;
-- 【目录不敏感】与 certificate_types / material_kinds / waste_classifications 同一处置。
CREATE POLICY "material_forms select all"
    ON public.material_forms AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "material_forms insert by permission"
    ON public.material_forms AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));
CREATE POLICY "material_forms update by permission"
    ON public.material_forms AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));

COMMENT ON COLUMN public.material_forms.may_be_sold IS
'PROC-BUILD-1【R5,Tim 的裁定】:**法律上允许不允许把这个形态卖给任何人。**
它说的是【法律准不准】,不是【我们卖不卖】—— 一个 true 不表示这条流真的在售。

【三个 false:电芯 loose_cells · 已开壳电芯 de_cased_cell · 负极片 anode_sheet】
**正极片 cathode_sheet 是 true。**

【★ 待补法条出处 ★】Tim 陈述这是新加坡法律的要求,**但没有给出法条出处**。
它以【业务规则-出处待补】的身份记在这里,而**硬拦是这条不确定性的安全一侧**:
将来放松它是改一行数据,将来收紧它是改一条逻辑,而在此期间发生的每一笔交易
都已经做完了。

【为什么这一列 NOT NULL 且不给默认值】一个默认放行的取值等于让"没有人想过"
悄悄变成"可以卖"。**每加一个形态,必须当场回答这个问题。**

【为什么它在形态上而不在物料上】法律说的是【这个东西物理上是什么】,
所以它属于记录"东西物理上是什么"的这张字典 —— 说一次,每一种物料继承。
R6 已裁定买进来的与自己产的是同一种物质,所以两份可以互相矛盾的答案是个缺陷,
不是灵活性。

【它【不】带买方资格层、【不】带审批例外、【不】带豁免申请】—— R5 是硬拦。';
