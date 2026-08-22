-- PROC-4:那份金属清单变成一张字典 —— 八条 CHECK 换成八条外键
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【S1 的实测:是【八张】表,不是四张】
-- 切次简报说四张。线上目录里逐条查过,是八:
--   assay_result_metals · inbound_batch_metals · output_batch_metals ·
--   metal_prices · pricing_formula_metals · pricing_term_commitment_metals ·
--   material_required_metals · pricing_formula_history
-- 七张的定义【一字不差】;pricing_formula_history 那一条多一个 `metal IS NULL OR`,
-- 而那是【刻意的差别不是漂移】:表头级的改动没有金属可言。
-- **少数出来的那四张,会安安静静地留着 CHECK** —— 于是加一行字典之后,
-- 一半的表接受新值、另一半照旧拒,而没有任何东西会说这件事。
--
-- 【D3:这张字典叫 substances,不叫 metals】
-- 排着队要进来的东西里,**氟、氯、石墨、塑料没有一个是金属**。
-- 一张叫 metals 的表在收下石墨的那天就开始说假话,而那时它已经被八张表引用着。
-- 名字现在选对,比以后改便宜 —— 改名的实测代价见表注。
--
-- 【D2:只发今天真的存在的七个】不加氟/氯/石墨/塑料。
-- 字典的意义就是"以后加一个只要一行";而现在就加,等于宣称我们已经能记录、
-- 能定价它们,而今天两样都不能。返回条件写在表注上。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE public.substances (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    symbol     text,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
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

【D2:今天只有七个,而这【不是】清单的全部】
第一批要加的,连同它们各自的返回条件:
  * **氟(F)/ 氯(Cl)** —— 惩罚元素。今天它们【连记都记不下来】。
    返回条件:**第一份写明惩罚结构的承购/供货条款**(docs/proc-reality.md 的 U11)。
  * **石墨** —— 可回收流。返回条件:**第一次真的回收出一条石墨流**。
  * **塑料** —— 同上。返回条件:**流程图定稿,确认它是一条产品流而不是处置流**
    (U6)。
现在就把它们加进来,等于宣称我们能记录、能定价它们 —— 而今天两样都不能,
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

COMMENT ON COLUMN public.substances.symbol IS
'元素符号(Ni / Co / Li…)。**可空,而空是有意义的**:塑料不是元素,没有符号。
它是展示用的,不参与任何判断 —— 判断一律用 code。';

-- ── 七个,一个不多。顺序照 app 侧那个"重要的排前面",不照字母序 ──────────────
INSERT INTO public.substances (code, name_en, name_zh, symbol, sort_order, notes) VALUES
    ('ni', 'Nickel',    '镍', 'Ni', 1, NULL),
    ('co', 'Cobalt',    '钴', 'Co', 2, NULL),
    ('li', 'Lithium',   '锂', 'Li', 3, NULL),
    ('mn', 'Manganese', '锰', 'Mn', 4, NULL),
    ('cu', 'Copper',    '铜', 'Cu', 5, NULL),
    ('al', 'Aluminium', '铝', 'Al', 6, NULL),
    ('fe', 'Iron',      '铁', 'Fe', 7, NULL);

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

-- ════════════════════════════════════════════════════════════════════════════
-- 八条 CHECK → 八条外键
--
-- 【为什么可以直接 DROP 再 ADD,而且不加 NOT VALID】线上实测:这八张表里存着的
-- 码【只有那七个】,没有任何历史杂值(material_required_metals 与
-- pricing_formula_history 是空表)。所以外键当场就能验过,不需要 NOT VALID ——
-- 而 NOT VALID 在这里反而是错的:它会让"旧行可以是任何东西"成为一个真命题。
--
-- 【pricing_formula_history 仍然允许 NULL】外键对 NULL 天然放行,所以那一条
-- `metal IS NULL OR` 的语义由外键【原样保留】,不需要额外的 CHECK。
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.assay_result_metals            DROP CONSTRAINT assay_result_metals_metal_check;
ALTER TABLE public.assay_result_metals            ADD CONSTRAINT assay_result_metals_metal_fkey
    FOREIGN KEY (metal) REFERENCES public.substances (code);

ALTER TABLE public.inbound_batch_metals           DROP CONSTRAINT inbound_batch_metals_metal_check;
ALTER TABLE public.inbound_batch_metals           ADD CONSTRAINT inbound_batch_metals_metal_fkey
    FOREIGN KEY (metal) REFERENCES public.substances (code);

ALTER TABLE public.output_batch_metals            DROP CONSTRAINT output_batch_metals_metal_check;
ALTER TABLE public.output_batch_metals            ADD CONSTRAINT output_batch_metals_metal_fkey
    FOREIGN KEY (metal) REFERENCES public.substances (code);

ALTER TABLE public.metal_prices                   DROP CONSTRAINT metal_prices_metal_check;
ALTER TABLE public.metal_prices                   ADD CONSTRAINT metal_prices_metal_fkey
    FOREIGN KEY (metal) REFERENCES public.substances (code);

ALTER TABLE public.pricing_formula_metals         DROP CONSTRAINT pricing_formula_metals_metal_check;
ALTER TABLE public.pricing_formula_metals         ADD CONSTRAINT pricing_formula_metals_metal_fkey
    FOREIGN KEY (metal) REFERENCES public.substances (code);

ALTER TABLE public.pricing_term_commitment_metals DROP CONSTRAINT pricing_term_commitment_metals_metal_check;
ALTER TABLE public.pricing_term_commitment_metals ADD CONSTRAINT pricing_term_commitment_metals_metal_fkey
    FOREIGN KEY (metal) REFERENCES public.substances (code);

ALTER TABLE public.material_required_metals       DROP CONSTRAINT material_required_metals_metal_check;
ALTER TABLE public.material_required_metals       ADD CONSTRAINT material_required_metals_metal_fkey
    FOREIGN KEY (metal) REFERENCES public.substances (code);

ALTER TABLE public.pricing_formula_history        DROP CONSTRAINT pricing_formula_history_metal_check;
ALTER TABLE public.pricing_formula_history        ADD CONSTRAINT pricing_formula_history_metal_fkey
    FOREIGN KEY (metal) REFERENCES public.substances (code);

COMMIT;
