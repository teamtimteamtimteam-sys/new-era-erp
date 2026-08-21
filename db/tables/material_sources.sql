-- db/tables/material_sources.sql
-- PROC-2:这一种物料【从哪来】—— 决定废物代码与"要不要放电"成不成立。
--
-- 【RUNTIME CONFIG】加一种是加一行(与 certificate_types / material_kinds /
-- waste_classifications 同形,check_mirrors 不逐行比对内容)。
-- 【每一条轴都是字典,不是枚举、不是自由文本】理由是 F7,而它在这个仓库里
-- 已经发作过:materials.category 长出四种命名法而没有任何东西察觉,
-- 而那笔转换成本不是渐渐变贵,是会变成【不可能】。
--
-- NOTE: introduced by db/migrations/2026-08-22-proc2-intake-condition-axes.sql.
-- First-run script (plain CREATEs).

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

ALTER TABLE public.material_sources ENABLE ROW LEVEL SECURITY;
-- 【目录不敏感】与 certificate_types / material_kinds / waste_classifications 同一处置。
CREATE POLICY "material_sources select all"
    ON public.material_sources AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "material_sources insert by permission"
    ON public.material_sources AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));
CREATE POLICY "material_sources update by permission"
    ON public.material_sources AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));
