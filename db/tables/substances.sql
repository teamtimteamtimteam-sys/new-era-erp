-- db/tables/substances.sql
-- PROC-4:我们【测量并核算】的元素与物质 —— 替掉曾经重复在【八张】表上的
-- 那条 CHECK (metal IN ('ni','co','li','mn','cu','al','fe'))。
--
-- 【RUNTIME CONFIG】加一种是加一行,不是跑一次迁移(与 material_kinds /
-- certificate_types / waste_classifications 同形,check_mirrors 不逐行比对内容)。
--
-- 【名字为什么不是 metals】排队要进来的东西里氟氯石墨塑料没有一个是金属 ——
-- 理由与改名的实测代价都在表注上。
--
-- NOTE: introduced by db/migrations/2026-08-22-proc4-the-metal-list-becomes-a-dictionary.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.substances (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    symbol     text,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text,
    -- MES-6a-2(2026-10-10,MES-0 Q69;MES-6a Step 0 Q26,Tim):这种物质在商务上【扮演什么】。NOT NULL、【没有默认值】——
    --   默认 payable_metal 会让以后加的每一行都悄悄变成"可计价",而那正是 F / Cl 不该是的东西。
    role       text NOT NULL CHECK (role IN ('payable_metal', 'penalty_element', 'other'))
);

COMMENT ON TABLE public.substances IS
'PROC-4:我们【测量并核算】的元素与物质 —— 一张字典,替掉曾经重复在八张表上的
那条 CHECK (metal IN (…))。

【为什么叫 substances 而不是 metals(D3)】
排队要进来的东西里,**氟、氯、石墨、塑料没有一个是金属**:氟氯是惩罚元素,
石墨是碳的一种形态,塑料连元素都不是。一张叫 metals 的表在收下石墨那天就开始
说假话,而那时它已经被八张表引用着。**名字选错的代价,是等它被引用之后才付的。**

【本表的行是什么】"一种物质,我们在物料里测它的含量、并在商务上核算它" ——
这一句同时容得下:可付款金属(今天的七个)、惩罚元素(氟、氯)、
以及可回收的非金属流(石墨、塑料)。

【已知的名不副实,而代价是量过的】指向本表的那八个列【仍然叫 metal】。
实测把它改名要动 **623 处**(db/tables 38 · views+functions 89,其中 15 处是
函数吐出去的 **JSON 键**,改了就是改 API 形状 · app+lib 314 · fixtures 182)。
本刀不付这笔账:CHECK 才是挡住氟氯石墨的那个东西,列名只是难看。
**排期:列名 metal → substance_code,代价 623 处,见 docs/known-issues.md。**

【D2:七个可计价金属 + 两个惩罚元素,而这【仍然不是】清单的全部】
  * ~~**氟(F)/ 氯(Cl)** —— 惩罚元素。今天它们【连记都记不下来】。~~
    ★ **MES-6a-2(2026-10-10,MES-6a Step 0 Q31,Tim)加上了**:f / cl,role = penalty_element。化验与含量里记得下,
    合同的惩罚条款里点得了名;**定价那几条路(行情、公式、承诺、合同计价与精炼费、计价器)按名拒它们**
    (SUBSTANCE_NOT_PAYABLE),结算的计价、报价、回收率与成本分摊只读 payable_metal —— 见 role 的列注。
    原来写的返回条件(第一份写明惩罚结构的条款,U11)没有变:它们的阈值与费率仍是一份一份合同的条款(V15 不设待补的值)。
  * **石墨** —— 可回收流。返回条件:**第一次真的回收出一条石墨流**。
  * **塑料** —— 同上。返回条件:**流程图定稿,确认它是一条产品流而不是处置流**
    (U6)。
现在就把后两样加进来,等于宣称我们能记录、能定价它们 —— 而今天两样都不能,
一个没人用得上的字典行会教下一个读它的人"这一类在用"(material_kinds 不加
reagent 是同一条)。

【RUNTIME CONFIG】加一种物质 = 加一行,不是一支迁移。check_mirrors 不逐行比对
它的内容(与 material_kinds / certificate_types / waste_classifications 同形)。';

COMMENT ON COLUMN public.substances.is_active IS
'PROC-4,与 PROC-3 在 inbound_safety_states 上立的是【同一条】:

**两个动词,谁也替不了谁。**
  * is_active 管的是【今天还能不能【新选】这个值】—— 它管选单。
  * 它【绝不】管"已经记下来的数字还算不算数"。停用一个物质,
    **历史化验结果、历史含量、历史报价一个字都不变,也照常读得出来** ——
    那些数字是当时测出来的事实,不因为今天不再选它而变成假的。
  * 要让一种物质【不再被计价】或改变它的商务待遇,那是【规则】,
    将来由它自己的规则列回答,不是把 is_active 关掉。

**外键【不看】is_active** —— 这是刻意的,和 PROC-3 的守卫只读 may_be_fed
一模一样:停用一行字典是一个看起来很轻的动作,而它若能让既有数据失效,
那就是一条无痕迹、且一次性对所有单据生效的破坏路径。
拦住"新选"要靠读本列的那些界面与校验,不靠外键。';

COMMENT ON COLUMN public.substances.sort_order IS
'PROC-4(D4):显示顺序是【数据】。

【本刀之前,顺序有【两个】互相矛盾的出处 —— 实测】
  * app 侧:app/metal-prices/options.ts 的数组字面量顺序(ni, co, li, mn, cu, al, fe)
    —— 一个"重要的排前面"的顺序;
  * DB 侧:视图与函数里一律 `ORDER BY metal`,那是【字母序】(al, co, cu, fe, li, mn, ni)。
**同一批金属,下拉里镍第一,报表里铝第一。** 这不是本刀造成的,是本刀发现的。
本列把那个顺序变成一个【被选择的】事实:新加一行时,它出现在哪儿由这一列决定,
而不是由字母、也不是由插入次序。';

COMMENT ON COLUMN public.substances.role IS
'MES-6a-2(2026-10-10,MES-0 Q69;MES-6a Step 0 Q26–Q28,Tim):这种物质在商务上扮演什么。NOT NULL,【没有默认值】。

  * payable_metal   —— 按含量计价的金属。【只有它们】进得了定价的那几条路:行情(metal_prices)、公式与它的承诺副本
                       (pricing_formula_metals · pricing_term_commitment_metals)、合同的计价条款与精炼费
                       (contract_pricing_terms · contract_refining_charges)、计价器与 calculate_metal_price_from_terms ——
                       别的按名拒 SUBSTANCE_NOT_PAYABLE(表上的守卫 guard_substance_role 一道,写入函数自己再先说一遍);
                       结算的计价那一圈、销售报价、按条款计价、回收率与成本分摊也只读它们。
  * penalty_element —— 惩罚元素(氟、氯)。【只有它们】点得进合同的惩罚条款(contract_penalty_elements),别的按名拒
                       SUBSTANCE_NOT_PENALTY_ELEMENT;结算只在惩罚那一圈读它们。屏幕上在 % 旁边带 ppm(1 % = 10,000 ppm),不舍到两位。
  * other           —— 记得下、哪儿都不算钱的(将来的石墨、塑料之类)。

【在哪儿都记得下】化验、批次含量、物料必测项、采购单的预计化验、合同品位规格、配料目标 —— 三种都收(Q27 的"任意")。

【为什么没有默认值】一个默认 payable_metal 会让以后加的每一行都悄悄变成"可计价";一个默认 other 会让一种真要计价的金属
悄悄算不进钱。两种错都不报错 —— 所以加一行就得说出它是哪一种(字典编辑器上是一个必选的下拉)。

【改一行的 role 不回头判已经写下的行】与 is_active 同一条(D5):守卫只管新写入与改到那一列的那一次;
既有的行情、条款、含量照旧读得出来。要让一种金属"不再计价",改的是这一列,而它从那一刻起才生效。';

COMMENT ON COLUMN public.substances.symbol IS
'元素符号(Ni / Co / Li…)。**可空,而空是有意义的**:塑料不是元素,没有符号。
它是展示用的,不参与任何判断 —— 判断一律用 code。';

-- ── 七个可计价金属 + 两个惩罚元素。顺序照 app 侧那个"重要的排前面",不照字母序 ──────────────
-- MES-6a-2(Step 0 Q26 · Q31):七个既有的行 role = payable_metal(线上由迁移改,与这里同一句);f / cl 排 8 · 9
--   (在 fixture 116 的 99 之下),role = penalty_element。【这份引导的默认值仍然正确】—— 既有各列的意思一个字没变,
--   只多了一列,而那一列在这里写明了每一行(AGENTS.md「RUNTIME CONFIG」:改表的那一刀要说清引导仍然对)。
INSERT INTO public.substances (code, name_en, name_zh, symbol, sort_order, notes, role) VALUES
    ('ni', 'Nickel',    '镍', 'Ni', 1, NULL, 'payable_metal'),
    ('co', 'Cobalt',    '钴', 'Co', 2, NULL, 'payable_metal'),
    ('li', 'Lithium',   '锂', 'Li', 3, NULL, 'payable_metal'),
    ('mn', 'Manganese', '锰', 'Mn', 4, NULL, 'payable_metal'),
    ('cu', 'Copper',    '铜', 'Cu', 5, NULL, 'payable_metal'),
    ('al', 'Aluminium', '铝', 'Al', 6, NULL, 'payable_metal'),
    ('fe', 'Iron',      '铁', 'Fe', 7, NULL, 'payable_metal'),
    ('f',  'Fluorine',  '氟', 'F',  8, NULL, 'penalty_element'),
    ('cl', 'Chlorine',  '氯', 'Cl', 9, NULL, 'penalty_element');

ALTER TABLE public.substances ENABLE ROW LEVEL SECURITY;
-- 【目录不敏感】与 material_kinds / certificate_types / currencies 同一处置。
CREATE POLICY "substances select all"
    ON public.substances AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "substances insert by permission"
    ON public.substances AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));
CREATE POLICY "substances update by permission"
    ON public.substances AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.substances
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
