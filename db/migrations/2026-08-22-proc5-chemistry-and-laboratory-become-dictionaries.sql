-- PROC-5:化学体系与实验室变成字典 —— F7 点名的最后两处自由文本分类
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【S1 实测:这两列身上【一条约束都没有】】
-- 不是"CHECK 写死了一份清单"(那是 PROC-4 的情形),是**彻底的自由文本**:
--   materials.chemistry      text,可空,无默认,无 CHECK
--   assay_results.lab_name   text,可空,无默认,无 CHECK
-- 唯一的"清单"住在 app 里(CHEMISTRY_OPTIONS),而它**自带一个逃生门**:
-- `其他` 是一个 sentinel,选中它会打开一个自由文本框。
--
-- 【而那个门已经被走过了 —— 这是本刀最有力的论据,它在现在不在将来】
-- 线上两行真物料,其中 MAT-2026-0002(在册,8 个批次在用)的 chemistry 是
-- **「Special Chemistry Structure」** —— 不在 app 自己的清单里,读起来像占位符。
-- materials.category 长出四种命名法,走的就是这条路。
--
-- 【实验室相反:理由在将来,不在现在 —— 照直说】
-- 线上 assay_results 只有 **一个** 非空 lab_name(FRL,1 行;3 行为空),
-- **没有重复拼法**。所以这一半不是在治一个已经发作的病,是在关一扇门。
-- Tim 的裁定:先做字典;将来要给仲裁实验室付钱那天,再按 forwarder_details
-- 的先例把那一行指向一个 supplier,而不是推翻重来。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 一 · 电池化学体系
-- ════════════════════════════════════════════════════════════════════════════
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

-- ── 那一行占位串,以及为什么它变成 NULL ──────────────────────────────────────
--
-- 【先说清楚发生过什么:一次被实测推翻的判断】
-- 本刀原本打算用 NOT VALID 外键把 MAT-2026-0002 的
-- 「Special Chemistry Structure」原样留着,理由是"外键只在外键列变动时才校验,
-- 所以那一行的别的字段照样改得动"。**那句话是错的,而它是被测出来错的:**
--   SELECT tgattr FROM pg_trigger WHERE tgisinternal  →  **空**
-- RI 触发器【不带列清单】,于是带着字典外值的那一行 **任何字段都改不动**
-- —— 改名字、改安全库存、改备注一律被拒。而 MAT-2026-0002 是在册、
-- 八个批次在用的真物料,冻住它的代价比那个占位串值钱得多。
--
-- 【Tim 的裁定:把它置为 NULL】
-- 而这【不是】在丢信息:NULL 在这一列上早就有定义 —— **「没有人记过」**,
-- 那正是事实。「Special Chemistry Structure」不是一条化学体系信息,
-- 它是从自由文本口里进来的一个占位串;把它洗成字典值等于宣称它是一种化学体系,
-- 把它留着则冻住一行在用的主数据。**置空让"没人说过这批料是什么"变成一件读得出来的事。**
--
-- 【原值记在这里,所以它没有消失】
--   materials.code = 'MAT-2026-0002'(Special Battery Material)
--   原 chemistry   = 'Special Chemistry Structure'
-- 要复原,一行 UPDATE 就够 —— 但复原之前得先有人说出它到底是什么。
-- 【这一步撞上了一件【本刀之外】的事,而它值得记在这里】
-- 第一次跑这支迁移时,上面那条 UPDATE 被 **materials_kind_stated** 拒了:
--     ERROR: new row for relation "materials" violates check constraint "materials_kind_stated"
-- 那是 PROC-1 立的一条 `CHECK (kind_code IS NOT NULL AND may_be_processed IS NOT NULL) NOT VALID`。
-- **NOT VALID 的 CHECK 不像外键 —— 它在【任何一次 UPDATE】上都重算整行。**
-- 而 PROC-1 刻意没有回填种类,于是:
--
--   **线上 8 行物料【全部】违反那条 CHECK,也就是说它们【现在就一行都改不动】。**
--   (实测:8 / 8。自 2026-08-21 PROC-1 落地起就是如此,至今没有任何东西说过这件事。)
--
-- 这不是本刀造成的,也不是本刀负责修的(修它要有人说出每一种物料是什么种类 ——
-- 那正是 PROC-1 的 D7 拒绝替人做的判断)。**但本刀要动其中一行,所以必须绕过它。**
--
-- 【怎么绕:把那条 CHECK 卸下、改完、原样(仍然 NOT VALID)装回去】
-- 这【不削弱任何东西】:它本来就是 NOT VALID —— 它从不声称旧行合规,
-- 只声称新行必须合规。卸下再装回,前后逐字相同。
ALTER TABLE public.materials DROP CONSTRAINT materials_kind_stated;

UPDATE public.materials
   SET chemistry = NULL
 WHERE chemistry IS NOT NULL
   AND chemistry NOT IN (SELECT code FROM public.battery_chemistries);

ALTER TABLE public.materials
    ADD CONSTRAINT materials_kind_stated
    CHECK (kind_code IS NOT NULL AND may_be_processed IS NOT NULL) NOT VALID;

-- 【外键因此【不】需要 NOT VALID —— 而这个区别是事实决定的,不是风格】
-- 置空之后线上再没有任何字典外的值,所以它当场就验得过。
-- NOT VALID 在这里反而是错的:它会让"旧行可以是任何东西"成为一个真命题,
-- 而且(实测)会把那些行冻住。
ALTER TABLE public.materials
    ADD CONSTRAINT materials_chemistry_fkey
    FOREIGN KEY (chemistry) REFERENCES public.battery_chemistries (code);

COMMENT ON COLUMN public.materials.chemistry IS
'PROC-5:指向 battery_chemistries 那张字典(外键 materials_chemistry_fkey,已验证)。

【留空 = 没有人记过】它【不是】"不适用" —— 后者由 material_kinds.has_condition_axes
回答(一箱吨袋没有化学体系可言)。PROC-2 的 G18 把这个区别记了下来,
PROC-5 据此把「不适用」这个取值退役了:同一个问题有两个答案,两个答案会不一致。

【本刀把一行占位串置成了 NULL,而那不是丢信息】
MAT-2026-0002 原本存着「Special Chemistry Structure」—— 一个从旧自由文本口进来的
占位串。它不是化学体系信息;置空之后,"**没有人说过这批料到底是什么**"
变成一件读得出来的事。原值记在迁移文件里,复原只要一行 UPDATE ——
但复原之前得先有人说出它是什么。

【自由文本口关上了】从前这一列会静静收下任何字符串(线上就长出过一个)。
现在加一种化学体系 = 往字典里加一行,门槛是 module.materials.edit。';

-- ════════════════════════════════════════════════════════════════════════════
-- 二 · 实验室
-- ════════════════════════════════════════════════════════════════════════════
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

-- 【这一条【不】NOT VALID】线上唯一的那个值(FRL)已经在字典里,其余是 NULL,
-- 而外键对 NULL 天然放行 —— 所以它当场就验得过。与化学体系那一条的区别不是风格,
-- 是【线上有没有杂值】这个事实。
ALTER TABLE public.assay_results
    ADD CONSTRAINT assay_results_lab_name_fkey
    FOREIGN KEY (lab_name) REFERENCES public.laboratories (code);

COMMENT ON COLUMN public.assay_results.lab_name IS
'PROC-5:指向 laboratories 那张字典(外键 assay_results_lab_name_fkey)。

【留空 = 没有人记过是哪家出的】那不是"我们自己做的" —— 若将来"自检"要成为一个
可记录的事实,它是字典里的一行,不是一个空值的含义。

【列名仍然叫 lab_name,而它现在存的是 code】与 PROC-4 留下的 metal → substance_code
同一族的名不副实。改名的代价见 docs/known-issues.md;它不挡路,所以不在本刀里付。';

COMMIT;
