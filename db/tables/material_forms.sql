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

INSERT INTO public.material_forms (code, name_en, name_zh, implies_dismantling, sort_order, notes) VALUES
    ('whole_pack',     'Whole pack',                '整包',       true,  1, '整只电池包,带壳体与管理系统。拆解量最大。'),
    ('module',         'Module',                    '模组',       true,  2, '已拆到模组一级。'),
    ('loose_cells',    'Loose cells',               '散电芯',     true,  3, '已拆到电芯,仍需要开壳。'),
    ('electrode_scrap','Electrode scrap / offcuts', '极片废料',   false, 4, '产线上的极片边角料与废片。【不需要拆解】—— 它本来就是散料,所以 size_format 对它不适用。'),
    ('black_mass',     'Black mass',                '黑粉',       false, 5, '按【物质】命名,不按来源。自己产的与买进来的是同一种物质;哪一批是哪一种,由它有没有进料批/产出批回答。【不需要拆解】。'),
    ('mixed_unsorted', 'Mixed, unsorted',           '混合未分选', true,  6, '来料没分过。要先分选才谈得上进哪条链 —— 所以它按【要拆解】处理。');

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
