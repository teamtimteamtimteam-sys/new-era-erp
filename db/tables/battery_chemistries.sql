-- db/tables/battery_chemistries.sql
-- PROC-5:一种物料的【电池化学体系】—— 替掉 materials.chemistry 那片自由文本。
--
-- 【RUNTIME CONFIG】加一行是加一行,不是跑一次迁移(与 material_kinds /
-- substances 同形,check_mirrors 不逐行比对内容)。
--
-- NOTE: introduced by db/migrations/2026-08-22-proc5-chemistry-and-laboratory-become-dictionaries.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.battery_chemistries (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.battery_chemistries IS
'PROC-5:一种物料的【电池化学体系】。替掉 materials.chemistry 那片自由文本。

【为什么叫 battery_chemistries 而不是 chemistries】今天这八个值【全部】是电池
化学体系(NMC / NCA / LFP / LCO / LMO / LTO / 钠离子 / 混合)。叫 chemistries
是过度承诺:电子废料没有"化学体系"可言,而它将来若需要一条自己的轴,那是它自己
的一刀 —— 硬套过来正是 material_kinds 的 has_condition_axes 已经拒绝过的做法。
(PROC-4 把字典命名的代价量过了:名字选错的账,是等它被外键引用之后才付的。)

【code 就是【今天存进库里的那个值】,一个字母都没改】
线上 MAT-2026-0001 存的是 ''NMC''。把 code 改成 ''nmc'' 会让那一行对不上,
而"顺手规范一下大小写"就是一次没人要求的数据迁移。所以 code 保持原样,
包括两个中文值 —— **它们不好看,而好看不是改动已存储值的理由**。
显示名在 name_en / name_zh 上。

【没有【其他】】那一行曾经是 app 侧的一个 sentinel:选中它会打开一个自由文本框。
**它就是这一刀要治的病本身**(Tim 裁定去掉)。加一种新化学体系从此 = 加一行数据,
门槛是 module.materials.edit,而不是"任何人随手敲一个字符串"。

【没有【不适用】—— S6 的答复:退役】
PROC-2 把它记成 G18:一个"不适用"被塞进取值列表,只因为当时没有别的地方放。
**现在有了**:material_kinds.has_condition_axes 回答"这一类物料有没有化学体系
可言"。留着它等于让同一个问题有两个答案,而两个答案会不一致。
线上【零行】在用它,所以退役不花任何代价。
**留空的意思仍然是"没有人记过"** —— 那与"不适用"是两件事,而后者由种类回答。

【RUNTIME CONFIG】加一种是加一行(与 material_kinds / substances 同形)。';

COMMENT ON COLUMN public.battery_chemistries.is_active IS
'PROC-5,与 PROC-3(inbound_safety_states)、PROC-4(substances)是【同一条】:

**两个动词,谁也替不了谁。**
  * is_active 管的是【今天还能不能【新选】这个值】—— 它管选单。
  * 它【绝不】管"已经记下来的事实还算不算数"。停用一种化学体系,
    **既有物料上记着的那个值一个字都不变,也照常读得出来** ——
    那是当时有人做出的判断,不因为今天不再选它而变成假的。
**外键【不】读 is_active**,与前两刀同理:停用一行字典是一个看起来很轻的动作,
而它若能让既有数据失效,那就是一条无痕迹、且一次性对所有单据生效的破坏路径。';

COMMENT ON COLUMN public.battery_chemistries.sort_order IS
'PROC-5(D4):显示顺序是【数据】。

实测:本刀之前顺序【只有一个】出处 —— app 侧 CHEMISTRY_OPTIONS 的数组序;
库里没有任何一处按 chemistry 排序。所以这里【没有】PROC-4 那种"两个互相矛盾的
顺序"问题,本列只是把那个唯一的顺序从代码搬进数据,让新加一行落在被选择的位置上。';

INSERT INTO public.battery_chemistries (code, name_en, name_zh, sort_order, notes) VALUES
    ('NMC',    'NMC (Ni-Mn-Co)',      '三元 NMC',   1, NULL),
    ('NCA',    'NCA (Ni-Co-Al)',      '三元 NCA',   2, NULL),
    ('LFP',    'LFP (Li-Fe-P)',       '磷酸铁锂',   3, NULL),
    ('LCO',    'LCO (Li-Co)',         '钴酸锂',     4, NULL),
    ('LMO',    'LMO (Li-Mn)',         '锰酸锂',     5, NULL),
    ('LTO',    'LTO (Li-Ti)',         '钛酸锂',     6, NULL),
    ('钠离子', 'Sodium-ion',          '钠离子',     7,
     'code 是中文,因为它就是今天存进库里的那个值 —— 改它是一次数据迁移,不是一次改名。'),
    ('混合',   'Mixed feed',          '混合',       8,
     '【D2:它与批次那一侧的「已知混合」不是重复,两者可以同时成立,也可以各自单独成立】'
     || 'materials.chemistry = 混合 的意思是**这一种物料【本身就是】混合料**,'
     || '在这一行里那是一条正当的主数据;而 inbound_batches 的化学体系确定度 = 已知混合,'
     || '说的是**这一批货【到手之后发现】是混的**。前者描述我们买的是什么,'
     || '后者描述这一车到底是什么。分工在两个字段自己的注释上已经逐字写着,这里只是搬过来。');

ALTER TABLE public.battery_chemistries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "battery_chemistries select all"
    ON public.battery_chemistries AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "battery_chemistries insert by permission"
    ON public.battery_chemistries AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));
CREATE POLICY "battery_chemistries update by permission"
    ON public.battery_chemistries AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));
