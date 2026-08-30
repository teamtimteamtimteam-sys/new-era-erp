-- PROC-BUILD-1(2026-08-30):损耗类别 · 形态取值 · 可售性 —— 三件事,一支迁移。
--
-- 依据:docs/operation-model-scoping.md(PROC-MODEL-0,3ca72f9)。那份普查把七件事
-- 分成【一个模型(五件) + 一件独立可发(损耗类别) + 一个动因(放电)】。
-- **本刀只建那件独立可发的,加上它顺带需要的形态取值,再加上 Tim 的可售性裁定。**
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀【不建】什么,写在最前面,因为它是这一刀的边界】
--   五件被挡住的一件都不建:工序类型与路由 · 一炉的时长 · 在制品 · heel ·
--   不过磅的循环流。**也不建"只建那张表"的版本。**
--   **`processing_runs.loss_qty` 一列都不动** —— 普查把这件事评为 CHEAP,
--   理由正是那一列留着;动它就把这一刀变成另一刀。
--   **工序类型字典【本刀撤下】**,理由记在 docs/proc-loss-and-saleability.md:
--   R3(放电不产生新东西)那种工序【今天没有任何东西跑得动它】,
--   因为 commit_processing_run 对空产出数组抛 NO_OUTPUTS。
--
-- 【为什么三件事同一支迁移】电解液是一条真的连接:它既是一个【形态】(R4:
--   它离开这条线),又是一个【损耗类别】(W2-i:质量走了)。拆成两刀要付
--   两次备份与两个破窗,而它们本来就要同时对。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 金属去向(损耗类别的规则取值)════════════════════════════════════
--
-- 【做成字典而不是 CHECK】与 PROC-1 对 N5 的自我更正同一条:CHECK 要动表,
-- 字典要动一行。而 unknown 将来可能被一次真实化验解掉 —— 那时改的是取值,
-- 不是一条约束。

CREATE TABLE public.loss_metal_fates (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.loss_metal_fates IS
'PROC-BUILD-1:损耗类别的【金属去向】取值。三个:金属留着 / 金属走了 / 还不知道。

【为什么 unknown 是一个正当取值而不是一个空】本仓库为「空的两种意思」付过很多次账
(METAL-1 的 no_reference、SS-1 的阈值为 NULL)。这里把「我们查过,而答案是不知道」
做成一个【说得出口的值】,于是它与「没有人填过」分得开 —— 后者由 NOT NULL 拦掉。';

INSERT INTO public.loss_metal_fates (code, name_en, name_zh, sort_order, notes) VALUES
    ('stays',   'Metal stays behind', '金属留着',   1, 'W2-(i):质量走了、金属没走。回收率【不该】为这一部分扣分。'),
    ('leaves',  'Metal leaves',       '金属走了',   2, 'W2-(ii):质量与金属一起走。这是回收率该扣分的那一种。'),
    ('unknown', 'Not yet known',      '还不知道',   3, '**这是一个决定,不是一个空。** 线上产出批化验 0 条,所以某些流带不带走金属【今天答不了】。把它记成 stays 或 leaves 都是在编一个数,而那个数会直接流进回收率。');

-- ═══ 2 · 损耗类别字典 ═════════════════════════════════════════════════════

CREATE TABLE public.loss_categories (
    code         text PRIMARY KEY,
    name_en      text NOT NULL,
    name_zh      text NOT NULL,
    -- 【规则列 ①】金属跟着走了没有。**这是这张字典存在的全部理由。**
    metal_fate   text NOT NULL REFERENCES public.loss_metal_fates (code),
    -- 【规则列 ②】这是不是【真的损耗】。residue_disposal 为 false ——
    -- 它是一条带负价值的产出,暂时停在这里,不是它的归宿。
    is_true_loss boolean NOT NULL,
    is_active    boolean NOT NULL DEFAULT true,
    sort_order   integer NOT NULL DEFAULT 0,
    notes        text
);

COMMENT ON TABLE public.loss_categories IS
'PROC-BUILD-1:一笔损耗【是哪一种】。RUNTIME CONFIG,加一种是加一行。

【为什么它必须存在】docs/proc-reality.md 第五部分 W2 判过:今天
`processing_runs.loss_qty` 是一个 numeric,而它把【三件物理上不同的事】塌成一个数:
  (i) 水与挥发物 —— 质量走了、**金属留着**;
  (ii) 粉尘与洒漏 —— 都走了,这是唯一被表示对的一种;
  (iii) 残渣送处置 —— **根本不是损耗**,是一条带负价值的产出。
(i) 与 (ii) 对「金属去哪了」的答案【相反】,所以合在一个数里,
**回收率永远算不对,而错的方向取决于当天湿度**。

【这是本刀选中它的理由】七件事里其余六件今天是【沉默】(说不出口);
只有这一件今天在【发声而且说错】。沉默不会传染,错数会 ——
proc-reality 的 F4 数过它已经污染了四个互相印证的数字。';

COMMENT ON COLUMN public.loss_categories.metal_fate IS
'PROC-BUILD-1:这一种损耗把【金属】带走了没有。**一个数答不了这个问题,
这一列就是把那个问题分开的地方。** 回收率将来要按它分支:
金属留着的那部分不该被扣分,金属走了的那部分该。';

COMMENT ON COLUMN public.loss_categories.is_true_loss IS
'PROC-BUILD-1:这是不是【真的损耗】。**false 的那些是停在这里的过路客。**
W2-(iii) 判过:送去处置的残渣有重量、有去向、有一张处置费单据,而且有
Basel/牌照意义上的申报义务 —— **把它记成"损耗"等于让它从物料台账上消失,
而监管问的正是它**。它的归宿是一条【带负价值的产出】,那要等 U6(哪几条产出流
存在)。**在 U6 答之前,记成一个具名的类别【好过】记成 loss_qty 里一个匿名的数**,
而这一列让"它还没到家"留在数据里,不留在散文里。';

INSERT INTO public.loss_categories (code, name_en, name_zh, metal_fate, is_true_loss, sort_order, notes) VALUES
    ('moisture',
     'Water & volatiles', '水与挥发物', 'stays', true, 1,
     'W2-(i)。【Tim 已裁定】蒸发掉的水【本身就是一种损耗】,而且是"质量走了、金属没走"的那一种 —— 所以 is_true_loss 为真而 metal_fate 为 stays,两者不矛盾。'),
    ('dust_spill',
     'Dust & spillage', '粉尘与洒漏', 'leaves', true, 2,
     'W2-(ii)。**这是今天唯一被 loss_qty 表示对的一种** —— 质量与金属一起走。'),
    ('residue_disposal',
     'Residue sent for disposal', '残渣送处置', 'leaves', false, 3,
     'W2-(iii)。**它根本不是损耗** —— is_true_loss 为 false 就是这句话。它有重量、有去向、有一张处置费单据,归宿是一条带负价值的产出(U6)。在那之前记成一个具名类别,好过记成 loss_qty 里一个匿名的数。'),
    ('electrolyte_evaporation',
     'Electrolyte evaporation', '电解液挥发', 'unknown', true, 4,
     '【R4,Tim 的工艺路线】电解液目前计划挥发掉 —— 它既不是产品也不是废物收据,是【消失掉的质量】。**它没有并进 moisture,理由是 metal_fate**:moisture 那一行断言"金属留着",而电解液带不带走金属【今天没有人知道】(线上产出批化验 0 条)。并进去等于免费送出一个未经证实的断言,而那个断言会直接流进回收率 —— 那正是 W2/F4 记过账的那一种污染。');

-- ═══ 3 · 损耗事实行 ═══════════════════════════════════════════════════════

CREATE TABLE public.processing_run_losses (
    run_id             uuid NOT NULL REFERENCES public.processing_runs (id) ON DELETE CASCADE,
    loss_category_code text NOT NULL REFERENCES public.loss_categories (code),
    quantity           numeric NOT NULL CHECK (quantity > 0),
    notes              text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid DEFAULT auth.uid(),
    -- 【一张单的同一个类别只记一行】与 inbound_batch_safety_states 同一条:
    -- 重复一行不是"更确定",它只会让任何按类别求和的读法开始骗人。
    PRIMARY KEY (run_id, loss_category_code)
);

COMMENT ON TABLE public.processing_run_losses IS
'PROC-BUILD-1:一张加工单上【分了类的那部分损耗】,一类一行。

【它与 processing_runs.loss_qty 的关系 —— 本刀【不动】那一列】
  * **它们不必相等,而且现在【刻意】不要求相等。** 产线还没开,没有人知道
    三类各占多少;要求相等等于逼操作员编一个数去凑平,而编出来的数
    与量出来的数在报表里长得一模一样。
  * **但分类之和【不许超过】 loss_qty** —— 这条守得住,因为它不需要知道真实配比。
    它与 commit_processing_run 的 OUTPUT_EXCEEDS_INPUT 是同一个形状:
    一条【不等式】可以在真值未知时断言,一条【等式】不行。
    违反时按名拒:LOSS_CATEGORIES_EXCEED_LOSS_QTY。
  * 差额(loss_qty − 已分类之和)= **还没有解释的质量**,由
    processing_run_loss_breakdown 说出来。

【★ 它【不能】回答的那个问题,写在这里免得被当成已解决 ★】
**"过磅误差不是损耗"** —— 这张表把质量分成【已解释】与【未解释】两部分,
但【未解释】里混着两件事:还没有人去分类的损耗,与账本身对不上。
**要分开这两件,需要有人【断言】"这批数字对不上",而那个断言今天没有地方放。**
本刀【刻意不建】一个叫"过磅误差"的损耗类别 —— 那会把一个记账问题
伪装成一件物理事实,而这正是 loss_qty 今天在犯的错的小号版本。
记为遗留缺口,归属:称重与对账那一刀。';

COMMENT ON COLUMN public.processing_run_losses.quantity IS
'PROC-BUILD-1:这一类损耗的量,单位与加工单一致。**必须为正** ——
一笔为零的损耗与"没有这一类"分不开,而后者由"没有这一行"表示。';

-- 分类之和不许超过 loss_qty。
CREATE FUNCTION public.guard_processing_run_losses()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_run_id  uuid := COALESCE(NEW.run_id, OLD.run_id);
    v_sum     numeric;
    v_loss    numeric;
    v_code    text;
BEGIN
    SELECT r.loss_qty, r.code INTO v_loss, v_code
      FROM public.processing_runs r WHERE r.id = v_run_id;

    SELECT COALESCE(sum(l.quantity), 0) INTO v_sum
      FROM public.processing_run_losses l WHERE l.run_id = v_run_id;

    -- 【loss_qty 为空时不拦】空的意思是"这张单没有记过损耗总量",
    -- 而不是"总量是零"。拿 0 去比会把一条【没人填过】读成【上限为零】,
    -- 那正是本仓库反复付账的那个错(METAL-1 的 no_reference)。
    IF v_loss IS NOT NULL AND v_sum > v_loss THEN
        RAISE EXCEPTION 'LOSS_CATEGORIES_EXCEED_LOSS_QTY|%|%|%', v_code, v_sum, v_loss
          USING HINT = '分了类的损耗之和超过了这张加工单的损耗总量。两者【不必相等】,但分类不许超过总量。';
    END IF;
    RETURN NULL;
END;
$function$;

CREATE CONSTRAINT TRIGGER trg_processing_run_losses_within_total
    AFTER INSERT OR UPDATE OR DELETE ON public.processing_run_losses
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_run_losses();

-- ═══ 4 · 已解释 vs 未解释 ═════════════════════════════════════════════════

CREATE VIEW public.processing_run_loss_breakdown
WITH (security_invoker = true) AS
SELECT r.id                AS run_id,
       r.code              AS run_code,
       r.process_date,
       r.loss_qty,
       COALESCE(l.categorised_qty, 0) AS categorised_qty,
       -- 【差额可以为空】loss_qty 为空时"还没解释多少"这个问题不成立,
       -- 而 0 会把它读成"全部解释完了"。
       CASE WHEN r.loss_qty IS NULL THEN NULL
            ELSE r.loss_qty - COALESCE(l.categorised_qty, 0) END AS unexplained_qty
  FROM public.processing_runs r
  LEFT JOIN (SELECT run_id, sum(quantity) AS categorised_qty
               FROM public.processing_run_losses GROUP BY run_id) l
    ON l.run_id = r.id
 WHERE r.deleted_at IS NULL;

COMMENT ON VIEW public.processing_run_loss_breakdown IS
'PROC-BUILD-1:一张加工单的损耗,分成【已解释】与【还没解释】两块。

**`unexplained_qty` 不是"过磅误差"** —— 它是"还没有人说这部分去了哪"。
两者今天分不开(见 processing_run_losses 的表注),而把它命名成误差
会让一个记账问题看起来像一件已经查清的物理事实。';

-- ═══ 5 · 权限 ═════════════════════════════════════════════════════════════
-- 字典按物料模块判(与 material_forms 同一条);事实行按加工模块判
-- (与 assay_result_metals 同一条:哪个模块能读/写父,哪个就能读/写行)。

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['loss_metal_fates', 'loss_categories'] LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY "%s select all" ON public.%I AS PERMISSIVE FOR SELECT TO authenticated USING (true)', t, t);
        EXECUTE format('CREATE POLICY "%s insert by permission" ON public.%I AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission(%L))', t, t, 'module.processing.edit');
        EXECUTE format('CREATE POLICY "%s update by permission" ON public.%I AS PERMISSIVE FOR UPDATE TO authenticated USING (has_permission(%L)) WITH CHECK (has_permission(%L))', t, t, 'module.processing.edit', 'module.processing.edit');
    END LOOP;
END $$;

ALTER TABLE public.processing_run_losses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_run_losses select by permission"
    ON public.processing_run_losses AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));
CREATE POLICY "processing_run_losses insert by permission"
    ON public.processing_run_losses AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'::text));
CREATE POLICY "processing_run_losses update by permission"
    ON public.processing_run_losses AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
CREATE POLICY "processing_run_losses delete by permission"
    ON public.processing_run_losses AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.processing.edit'::text));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.loss_metal_fates      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.loss_categories       TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.processing_run_losses TO authenticated;
GRANT SELECT ON public.processing_run_loss_breakdown TO authenticated;

-- ═══ 6 · 形态取值 —— Tim 的工艺路线点名的那七种 ═══════════════════════════
--
-- 【逐个对过既有六行,不重复建一个已有的形态】(brief STEP 3a)
--   * `loose_cells`(散电芯)已存在,表注写着「已拆到电芯,**仍需要开壳**」
--     —— 所以 `de_cased_cell`(已开壳的电芯)是它【之后】的一格,不是它的别名;
--   * `electrode_scrap`(极片废料)已存在,表注写着「产线上的极片**边角料与废片**」
--     —— 那是**废料**;而 `cathode_sheet` / `anode_sheet` 是**产品**。
--     **两者不许合并**:一个可售(R5)、一个不可售,而且它们的下游去向不同。
--   * 其余五种(隔膜 / 壳体 / 结构件 / 电解液)既有六行里一个都没有。
--
-- 【implies_dismantling 怎么定】它的意思是"这个形态【还要再拆】"。
--   `de_cased_cell` 为 true:壳开了,内容物还要过极片分离。
--   其余六种为 false:它们已经是散的了。

INSERT INTO public.material_forms (code, name_en, name_zh, implies_dismantling, sort_order, notes) VALUES
    ('de_cased_cell',    'De-cased cell',        '已开壳电芯', true,  7,
     '【R2】电芯开壳之后、极片分离之前的那一格。**它与 loose_cells 不是一回事** —— 后者的表注写着"仍需要开壳"。它仍要再拆(极片分离),所以 implies_dismantling 为真。**它也可以是【买进来的】**(R2/F2:料可以以任何一种形态进厂),而买进来的与自己产的是同一种物质(与 black_mass 同一条)。'),
    ('cathode_sheet',    'Cathode sheet',        '正极片',     false, 8,
     '【R2】极片分离机的产出之一。**不是 electrode_scrap** —— 那是边角料与废片,这是产品。它可以进极片粉料线,也可以卖(R5:正极片【可以】卖)。'),
    ('anode_sheet',      'Anode sheet',          '负极片',     false, 9,
     '【R2】极片分离机的产出之一。可以修复,也可以粉化。**不可售(R5)。**'),
    ('separator',        'Separator',            '隔膜',       false, 10,
     '【R2/R4】极片分离机的产出之一,而且它是一个【出口】—— 它离开这条线,不再往下走。'),
    ('casing',           'Casing',               '壳体',       false, 11,
     '【R2/R4】开壳与人工拆解都产出它,而且它是一个【出口】。**它去哪取决于它是什么材质做的,而那件事今天无从知道**(线上产出批化验 0 条)—— 所以本刀只建这个形态,【不建】它的去向。'),
    ('structural_parts', 'Structural parts',     '结构件',     false, 12,
     '【R2】人工拆解包与模组时【同时】产出的那些 —— 支架、螺栓、线束一类。它是一个【出口】。**它单独成一行而不并进 casing**,因为 R2 把两者并列点名,而它们的材质与去向不必相同。'),
    ('electrolyte',      'Electrolyte',          '电解液',     false, 13,
     '【R4】目前计划**挥发掉** —— 它既不是产品也不是废物收据,是【消失掉的质量】。环保设备可能后加,那时它才会变成一条真的物料流。**它同时也是一个损耗类别**(loss_categories.electrolyte_evaporation),而这正是本刀把三件事放进同一支迁移的那条连接。');

-- ═══ 7 · 可售性 —— 挂在【形态】上 ═════════════════════════════════════════
--
-- 【为什么挂在形态上而不是物料上】法律说的是【这个东西物理上是什么】,
-- 所以它属于"记录东西物理上是什么"的那张字典。**说一次,每一种物料继承它。**
-- 挂在物料上的话,同一种物质会有两份互相可以矛盾的答案,而 R6 已经裁定
-- 买进来的与自己产的是【同一种物质】。

ALTER TABLE public.material_forms ADD COLUMN may_be_sold boolean;

UPDATE public.material_forms SET may_be_sold = CASE code
    -- 【R5,Tim 的裁定】按 Tim 的陈述,新加坡法律不允许把这三种卖给任何人。
    WHEN 'loose_cells'   THEN false   -- 电芯
    WHEN 'de_cased_cell' THEN false   -- 已开壳电芯
    WHEN 'anode_sheet'   THEN false   -- 负极片
    ELSE true
END;

ALTER TABLE public.material_forms ALTER COLUMN may_be_sold SET NOT NULL;

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

-- ═══ 8 · 两条断言,四个入口 ═══════════════════════════════════════════════
--
-- 【为什么是触发器而不是改那八个函数】proc-reality 对 N5 的自我更正写过同一条:
-- **触发器对每一个写入者都成立,包括直连 psql**。而"报价能挡、发货挡不住"
-- 那种半拦,比不拦更糟 —— 它制造信心。
--
-- 【四层,而它们只需要四个触发器】(brief 4b,逐个点名)
--   ① 报价      quote_lines(material_id)              —— 一份卖不了的东西的报价
--   ② 订单      sales_order_lines(material_id)         —— 一份永远履行不了的承诺
--   ③ 占用      sales_order_reservations(output_batch_id)
--   ④ 出货/直销 sales_records(output_batch_id)         —— **NOT NULL,所以
--      record_output_sale 与 ship_order 两条路【共用这一个门】**

-- 物料级:只问形态可不可售。**这一层没有批次,所以问不了"形态没设"那个问题。**
CREATE FUNCTION public.assert_material_form_saleable(p_material_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_form text;
    v_zh   text;
    v_en   text;
BEGIN
    SELECT f.code, f.name_zh, f.name_en INTO v_form, v_zh, v_en
      FROM public.materials m
      JOIN public.material_forms f ON f.code = m.form_code
     WHERE m.id = p_material_id
       AND f.may_be_sold IS FALSE;

    IF FOUND THEN
        RAISE EXCEPTION 'SALE_FORM_NOT_SALEABLE|%|%|%', v_form, v_zh, v_en
          USING HINT = '这个形态在法律上不允许出售(R5)。这【不是】库存问题,也【不是】审批问题 —— 没有例外路径。';
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.assert_material_form_saleable(uuid) IS
'PROC-BUILD-1:物料级的可售性断言 —— 报价行与订单行用它。
**它只回答"这个形态法律上准不准卖",不回答"这一批的形态设没设"** ——
后者是批次的问题,物料级没有批次可问。';

-- 批次级:形态可不可售,【加上】"这一批是加工出来的而形态没设"。
CREATE FUNCTION public.assert_output_batch_saleable(p_output_batch_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_material uuid;
    v_code     text;
    v_form     text;
    v_from_run boolean;
BEGIN
    SELECT ob.material_id, ob.code, m.form_code
      INTO v_material, v_code, v_form
      FROM public.output_batches ob
      JOIN public.materials m ON m.id = ob.material_id
     WHERE ob.id = p_output_batch_id;

    IF NOT FOUND THEN
        RETURN;   -- 批次不存在不是本函数的题;既有的 OUTPUT_NOT_FOUND 管它。
    END IF;

    -- ① 形态已知且不可售 —— 与物料级同一条判据,同一个错误码。
    PERFORM public.assert_material_form_saleable(v_material);

    -- ════════════════════════════════════════════════════════════════════════
    -- ② 形态【没设】,而这一批是【加工出来的】。
    --
    -- 【这条不对称是刻意的,不要"修"平它】(与 PROC-3 的 D3 同源,理由不同)
    --   * **买进来的料、以及这条轴之前就存在的料:照旧可售。** 一个 NULL 形态
    --     在它们身上的意思是"这条轴比这行料还年轻",而不是"有人漏填了"。
    --     把它们也拦掉,等于停掉线上每一笔销售,并且会教操作员随便填一个值
    --     去解锁 —— 那会毁掉这条轴本身。
    --   * **加工产出的料:拦。** 产线跑起来那天,一个【从来没有人设过形态】的
    --     产出批会悄悄变成可售,而且没有任何信号。**这里的后果是法律上的**,
    --     而这正是本仓库反复付账的那个形状。
    --   两者防的不是同一件事:前者防的是【停线】,后者防的是【卖掉一件不许卖的东西】。
    --
    -- 【这条拒绝【不】说"这个东西不许卖"】—— 那是另一句话,而且会是假的。
    -- 它说的是"这一批的形态没设,所以【判断不了】"。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_form IS NULL THEN
        SELECT EXISTS (SELECT 1 FROM public.processing_outputs po
                        WHERE po.output_batch_id = p_output_batch_id)
          INTO v_from_run;

        IF v_from_run THEN
            RAISE EXCEPTION 'SALE_FORM_NOT_SET|%', v_code
              USING HINT = '这一批是加工产出的,而它的物料没有设形态,所以【判断不了】它可不可售。这【不是】说它不许卖。到【物料 → 打开这一种物料】把形态设上。';
        END IF;
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.assert_output_batch_saleable(uuid) IS
'PROC-BUILD-1:批次级的可售性断言 —— 占用与出货/直销用它。

**它会抛两条【不同】的拒绝,而它们永远不许合并成一条:**
  * `SALE_FORM_NOT_SALEABLE` —— 这个形态法律上不许卖(R5);
  * `SALE_FORM_NOT_SET`      —— 这一批是加工出来的而形态没设,所以判断不了。
    **它【不是】说这个东西不许卖。**
再加上既有的库存类拒绝(`IOD_SALE_EXCEEDS_AVAILABLE` /
`SO_RESERVE_EXCEEDS_AVAILABLE` / `OUTPUT_NOT_FOUND` / `OUTPUT_DELETED`)——
**三种句子,三种下一步动作,一条都不许长得像另一条。**';

-- ── 四个触发器 ───────────────────────────────────────────────────────────
CREATE FUNCTION public.guard_line_form_saleable()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM public.assert_material_form_saleable(NEW.material_id);
    RETURN NEW;
END;
$function$;

CREATE FUNCTION public.guard_batch_form_saleable()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM public.assert_output_batch_saleable(NEW.output_batch_id);
    RETURN NEW;
END;
$function$;

-- ① 报价行
CREATE TRIGGER trg_quote_lines_form_saleable
    BEFORE INSERT OR UPDATE OF material_id ON public.quote_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_line_form_saleable();

-- ② 订单行
CREATE TRIGGER trg_sales_order_lines_form_saleable
    BEFORE INSERT OR UPDATE OF material_id ON public.sales_order_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_line_form_saleable();

-- ③ 占用
CREATE TRIGGER trg_so_reservations_form_saleable
    BEFORE INSERT ON public.sales_order_reservations
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_form_saleable();

-- ④ 出货与直销共用的那一个门(sales_records.output_batch_id 是 NOT NULL)
CREATE TRIGGER trg_sales_records_form_saleable
    BEFORE INSERT ON public.sales_records
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_form_saleable();

COMMIT;
