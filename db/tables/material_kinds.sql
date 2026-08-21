-- db/tables/material_kinds.sql
-- PROC-1:物料【是什么】—— 按本性分区的一张字典。
--
-- 【RUNTIME CONFIG】加一种是加一行,不是跑一次迁移(与 certificate_types /
-- waste_classifications 同形,check_mirrors 不逐行比对内容)。
--
-- 【为什么是字典而不是一条 CHECK】PROC-0b 里先建议过写进表上的 CHECK;
-- 那条建议被更正了 —— Tim 的"把要预留的东西做成【数据】"与它拉反,而仓库自己的
-- 先例站在数据这一边:certificate_types 是字典,收货闸门靠触发器读它,
-- 而【触发器同样对直连 psql 成立】。换来的是"加一种 = 一行"。
--
-- 【没有 other / 没有 reagent】理由写在表注上,连同 reagent 的返回条件。
--
-- 【规则列 may_ever_be_processed 与 materials.may_be_processed 是两个问题】
-- 前者说【这一类】有没有可能,后者说【这一件】要不要。两者的关系由
-- guard_material_kind_processable 执行(挂在 db/tables/materials.sql 上)。
--
-- NOTE: introduced by db/migrations/2026-08-21-proc1-material-kind-as-a-dictionary.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.material_kinds (
    code                  text PRIMARY KEY,
    name_en               text NOT NULL,
    name_zh               text NOT NULL,
    -- 【规则住在字典行上】—— certificate_types.disposition 的形状。
    -- 它回答的是"这一类东西【有没有可能】被投料",而不是"这一件要不要"。
    may_ever_be_processed boolean NOT NULL,
    is_active             boolean NOT NULL DEFAULT true,
    sort_order            integer NOT NULL DEFAULT 0,
    notes                 text
);

COMMENT ON TABLE public.material_kinds IS
'PROC-1:物料【是什么】—— 按本性分区的一张字典。RUNTIME CONFIG:加一种是加一行,
不是跑一次迁移(与 certificate_types / waste_classifications 同一形状,
check_mirrors 不逐行比对它的内容)。

【为什么是字典而不是一条 CHECK】PROC-0b 里 Claude 先建议写进表上的 CHECK,
理由是"直插不许说出不可能的话"。**那条建议被更正了**:Tim 的"把要预留的东西
做成【数据】而不是【列】"与它拉反,而本仓库自己的先例站在数据这一边 ——
certificate_types 是字典,而收货闸门靠 guard_supplier_qualification 这个
【触发器】读它,**触发器同样对每一个写入者成立,包括直连 psql**。
换来的是:将来加一种物料种类、或者改一种种类能不能被投料,代价是【一行】。

【没有 other】它看起来像一个决定,行为上是"我不知道" —— 三态坑换从逃生门进来。
代价说清楚:没有 other,加一种新种类就是加一行【数据】(本表是 RUNTIME CONFIG),
而不是一支迁移 —— 这正是把它做成字典换来的东西。

【没有 reagent】粉料线还没到、流程图没定稿,今天确认不了要不要用工艺药剂。
一个没人用的枚举值会教下一个读它的人"这一类在用"。
**返回条件:第一次真的采购一种工艺药剂**(docs/proc-reality.md 的 U1)。

【方向【不是】本表的一个维度】"进料 / 产出"曾经是 materials.category 的第一刀,
而它已经被数据推翻:MAT-2026-0001 标着「进料」却有 10 个产出批。
一种物料是不是这里产的,答案是"它有没有产出批",不是它的种类。';

COMMENT ON COLUMN public.material_kinds.may_ever_be_processed IS
'PROC-1:这一类东西【有没有可能】被一炉加工吃掉。

【它与 materials.may_be_processed 是两个问题,不是一个】
本列说的是【这一类】(耗材永远不可能是投料);那一列说的是【这一件】
(某一种电池料,我们决定不投它)。前者是一条规则,后者是一次判断。
两者的关系由 guard_material_kind_processable 执行:
**这一列为 false 时,那一列不许为 true。反之【不】强制** ——
一件可以被投料的东西,我们完全可能决定不投它。';

INSERT INTO public.material_kinds (code, name_en, name_zh, may_ever_be_processed, sort_order, notes) VALUES
    ('battery_material', 'Battery material', '电池料', true, 1,
     '【按【功能】起名,不按某一个实例】它覆盖:整颗电芯与模组、极片废料、以及【我们买进来的黑粉】。'
     || '早先提过的 "battery" 这个名字被否掉了 —— 看到它的人会读成"整颗电池",第一天就会把买进来的黑粉分错类。'),
    ('ewaste', 'E-waste', '电子废料', true, 2,
     '非电池的电子废料。may_ever_be_processed = true 是【允许】,不是【断言我们会加工它】——'
     || '具体某一种要不要投,由 materials.may_be_processed 逐件决定。'),
    ('packaging', 'Packaging', '包装材料', false, 3,
     '吨袋一类。【自成一类,不并进耗材】它可能随货出去、也可能可回收,'
     || '而耗材是被【工艺】吃掉的 —— 两者的成本归属与补货触发都不同(PROC-0b N8,Tim 裁定)。'),
    ('consumable', 'Consumable', '耗材辅料', false, 4,
     '被工艺消耗掉、成为生产成本的那些。'),
    ('spare_part', 'Spare part', '备件', false, 5,
     '机器的备件。【自成一类】它挂在一台机器上、有关键度,而且【不按批次追溯】——'
     || '并进耗材会在保养模块(EQP-2b/2c)接上它之前就把那条链丢掉(PROC-0b N3,Tim 裁定)。');

ALTER TABLE public.material_kinds ENABLE ROW LEVEL SECURITY;
-- 【目录不敏感】与 certificate_types / leave_types / currencies 同一处置。
CREATE POLICY "material_kinds select all"
    ON public.material_kinds
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);
CREATE POLICY "material_kinds insert by permission"
    ON public.material_kinds
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));
CREATE POLICY "material_kinds update by permission"
    ON public.material_kinds
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));
