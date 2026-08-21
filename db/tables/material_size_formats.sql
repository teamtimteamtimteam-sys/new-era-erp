-- db/tables/material_size_formats.sql
-- PROC-2:这一种电池【来自哪一类应用】—— 决定拆解工作量与搬运方式。
--
-- 【RUNTIME CONFIG】加一种是加一行(与 certificate_types / material_kinds /
-- waste_classifications 同形,check_mirrors 不逐行比对内容)。
-- 【每一条轴都是字典,不是枚举、不是自由文本】理由是 F7,而它在这个仓库里
-- 已经发作过:materials.category 长出四种命名法而没有任何东西察觉,
-- 而那笔转换成本不是渐渐变贵,是会变成【不可能】。
--
-- NOTE: introduced by db/migrations/2026-08-22-proc2-intake-condition-axes.sql.
-- First-run script (plain CREATEs).

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

ALTER TABLE public.material_size_formats ENABLE ROW LEVEL SECURITY;
-- 【目录不敏感】与 certificate_types / material_kinds / waste_classifications 同一处置。
CREATE POLICY "material_size_formats select all"
    ON public.material_size_formats AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "material_size_formats insert by permission"
    ON public.material_size_formats AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));
CREATE POLICY "material_size_formats update by permission"
    ON public.material_size_formats AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));
