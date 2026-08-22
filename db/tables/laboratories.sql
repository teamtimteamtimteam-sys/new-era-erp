-- db/tables/laboratories.sql
-- PROC-5:出化验单的实验室 —— 替掉 assay_results.lab_name 那片自由文本。
--
-- 【RUNTIME CONFIG】加一行是加一行,不是跑一次迁移(与 material_kinds /
-- substances 同形,check_mirrors 不逐行比对内容)。
--
-- NOTE: introduced by db/migrations/2026-08-22-proc5-chemistry-and-laboratory-become-dictionaries.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.laboratories (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.laboratories IS
'PROC-5:出化验单的实验室。替掉 assay_results.lab_name 那片自由文本。

【这一半的理由在【将来】,不在现在 —— 照直说,不要把它说成一次抢救】
线上实测:**只有一个非空取值(FRL,1 行;3 行为空),没有任何重复拼法。**
也就是说今天还没有病症。做它是因为**关门比清理便宜**:同一间实验室的两种拼法
一旦长出来,合并它们就是一个"这两个是不是同一家"的判断,而那个判断没有人能
事后替当时的人做(materials.category 的四种命名法就是这么来的)。

【一间实验室【今天】是一行字典,不是一个往来户 —— 而这是一个刻意的分界】
lab_name 今天回答的是"**这张化验单是谁出的**",那是一个**署名**,不是一个付款对象。
将来要给仲裁实验室付钱时,按 forwarder_details 的先例:那一行字典指向一个
supplier,而不是把这张表推翻重来。**Tim 裁定如此。**

【D5:只发实际存在的那一个】不发任何编造的实验室。FRL 的全称今天没有人写下来,
所以 name_en / name_zh 就是 FRL 本身 —— **编一个全称比留着缩写坏**。
补全它是一次数据编辑,一行 UPDATE。

【RUNTIME CONFIG】加一家是加一行。';

COMMENT ON COLUMN public.laboratories.is_active IS
'PROC-5,与 battery_chemistries.is_active 逐字同一条:
is_active 管【还能不能新选】,不管【已经记下的还算不算数】。
一家实验室停止合作,**它出过的每一张化验单仍然是它出的** ——
外键因此不读 is_active。';

INSERT INTO public.laboratories (code, name_en, name_zh, sort_order, notes) VALUES
    ('FRL', 'FRL', 'FRL', 1,
     '线上唯一在用的实验室(assay_results 1 行)。**全称没有人写下来过**,'
     || '所以这里不编一个 —— 编一个全称比留着缩写坏。补全是一行 UPDATE。');

ALTER TABLE public.laboratories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "laboratories select all"
    ON public.laboratories AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "laboratories insert by permission"
    ON public.laboratories AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'::text));
CREATE POLICY "laboratories update by permission"
    ON public.laboratories AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit'::text))
    WITH CHECK (has_permission('module.inbound.edit'::text));
