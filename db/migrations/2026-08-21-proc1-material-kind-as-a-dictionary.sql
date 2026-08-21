-- PROC-1(2026-08-21):物料的【种类】变成一张字典,以及"能不能被投料"这一列。
--
-- 依据全部在 docs/proc-reality.md,本文件不复述,只点名:
-- F1(category 四种命名法、其中一种编码方向且已与数据矛盾)、
-- F3(第三份命名权威在 app/materials/options.ts,而且它把黑粉切成两个值)、
-- F7(自由文本的分类列拖延特别贵:值会累积,而对账没有真源)、
-- 以及 PROC-0b 里那条【对我自己的更正】:字典 + 触发器,不是 CHECK。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【grill 改了三处,其中两处改的是 brief 本身;第三处是它自己的内部矛盾】
--
-- ① **D2 的 NOT NULL 与 D7 的"清库重建"【互相矛盾,而 D7 那一半今天做不到】。**
--    实测:`materials` 八行(四在册 + 四软删)【每一行都被批次引用着】——
--    MAT-2026-0001 有 9 进 10 出、MAT-2026-0002 有 8 进 7 出,连两行冒烟残骸
--    也各有一张在册批次(ZZ-SMOKE-PROBE 上那张正是 AGENTS.md 点名"不要删"的
--    IN-2026-0180,100,000 kg)。删物料要先删批次,而删批次要先删库存流水与
--    总账分录 —— **"清库"会一路串进总账。**
--    **所以清库发生在【切换那一天】(全新重建),不是本刀。**
--    而只要那八行还在,真正的 `NOT NULL` 就【必须】为它们编造八个值 ——
--    **正是 D7 自己禁止的那件事。**
--    **处置:用 `CHECK (...) NOT VALID`** —— 新行必须说出两者(INSERT 与
--    UPDATE 都拦),旧行留空不动。**这不是发明出来的折中,是本表自己的先例**:
--    MAT-1 的 `waste_classification_code`(「既有物料全部 NULL,而且不回填」),
--    以及 FIN-32 的 `business_date`(「15 行历史 NULL 是历史,不是 bug」)。
--    **NOT NULL 与"不许编造值"之间,本仓库已经选过一次,这次照它。**
--
-- ② **F4 要的那道闸【在 brief 自己的排除清单里】**("Anything about runs")。
--    但一个没有任何地方兑现的 `may_be_processed` 就是 D8 亲口说的那个缺陷
--    —— 库建好了、没有门。**处置:加,但只加一条,而且加在
--    `guard_processing_input` 上** —— 那个守卫【本来就】是"什么东西可以当投料"
--    的那道门(它自己的注释写着「它守的是两侧」)。不动 `commit_processing_run`
--    的签名、不动它的任何一条既有分支。
--
-- ③ **D6 说"移除 app/materials/options.ts"—— 那会顺手杀掉两件本刀不管的东西。**
--    实测该文件还导出 `CHEMISTRY_OPTIONS`(十个值)、`UNIT_OPTIONS`、
--    `CUSTOM_VALUE`、`labelKeyForValue`。**处置:只移除 `CATEGORY_OPTIONS`,
--    文件留着。** 化学体系字典是 G18,是另一刀。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 字典 ══════════════════════════════════════════════════════════════
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

-- ═══ 2 · materials 上的两列 ════════════════════════════════════════════════
ALTER TABLE public.materials
    ADD COLUMN kind_code        text REFERENCES public.material_kinds (code),
    ADD COLUMN may_be_processed boolean;

COMMENT ON COLUMN public.materials.kind_code IS
'PROC-1:这一种物料【是什么】—— 指向 material_kinds。

【为什么不是 NOT NULL,而这【不是】一次退让】D2 要的是 NOT NULL,而 D7 同时
禁止"为了满足约束而编造值"。两者在今天【互相矛盾】,因为 materials 的八行
(四在册 + 四软删)**每一行都被批次引用着**,删不掉:MAT-2026-0001 有 9 进
10 出,连 ZZ-SMOKE-PROBE 上都挂着一张在册的 IN-2026-0180(100,000 kg,
AGENTS.md 点名"不要删")。真正的 NOT NULL 必须为这八行编造八个值。
**处置:materials_kind_stated 那条 CHECK ... NOT VALID** —— 新行必须说出来,
旧行留空不动,而【留空的意思就是"没有人决定过"，那是真话】。
本表自己的先例:MAT-1 的 waste_classification_code(既有物料全部 NULL,不回填);
同族先例:FIN-32 的 business_date。**清库发生在切换那一天,不是本刀。**

【NOT VALID 在 UPDATE 上也拦,而那是【想要的】】改一行既有物料时,
它会要求你顺手把种类说出来 —— 也就是说这八行【在有人决定它们是什么之前改不动】。
屏幕上必须把这句话说成人话(物料表单已接),而不是漏一条裸约束名出去。';

COMMENT ON COLUMN public.materials.may_be_processed IS
'PROC-1:这一种物料【可不可以被一炉加工吃掉】—— 加工那道闸唯一读的就是这一列。

【它与 material_kinds.may_ever_be_processed 是两个问题】那一列说【这一类】
有没有可能(耗材永远不可能);本列说【这一件】要不要。前者是规则,后者是判断。

【为什么"这里产的"不是一列】黑粉既买进来也自己产 —— 而"它是不是这里产的"
的答案是"它有没有产出批",不是它身上的一个布尔。线上两个真实物料【都】同时
有进料批与产出批,所以任何按功能切一刀的单值分区今天就不成立。';

-- 【两列一起说出来 —— NOT VALID:新行拦,旧行不动】
ALTER TABLE public.materials
    ADD CONSTRAINT materials_kind_stated
    CHECK (kind_code IS NOT NULL AND may_be_processed IS NOT NULL) NOT VALID;

COMMENT ON CONSTRAINT materials_kind_stated ON public.materials IS
'PROC-1:一行物料必须【同时】说出它是什么、以及能不能投料。
NOT VALID:对 INSERT 与 UPDATE 生效,而八行历史留空不动 ——
它们【本来就是"没有人决定过"】,回填等于发明一个没人记录过的事实
(MAT-1 在本表上做过同样的决定,FIN-32 在 business_date 上做过同样的决定)。';

-- ═══ 3 · 两列不许互相矛盾 —— 【触发器,不是 CHECK】═══════════════════════
-- 【为什么是触发器】这条规矩要看【另一张表】(material_kinds),而 CHECK 看不见
-- 另一张表 —— 本仓库用触发器的理由一向是这一条(payment_term_template_lines
-- 那条跨父子的规矩就是这样才用的守卫)。
-- 【为什么不因此退回 CHECK + 写死取值】那正是 PROC-0b 更正掉的方向:
-- 写死取值就丢掉了"加一种是加一行"。而触发器【同样对直连 psql 成立】,
-- 所以 D3 要的那个性质("直插不能说出不可能的话")一点没丢。
CREATE OR REPLACE FUNCTION public.guard_material_kind_processable()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_allowed boolean;
    v_zh      text;
BEGIN
    -- 种类还没说 → 不是本守卫的事,交给 materials_kind_stated 那条 CHECK。
    -- 【八行历史行正落在这里】它们 kind_code 为空,本守卫对它们一言不发。
    IF NEW.kind_code IS NULL OR NEW.may_be_processed IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT mk.may_ever_be_processed, mk.name_zh INTO v_allowed, v_zh
      FROM material_kinds mk WHERE mk.code = NEW.kind_code;
    -- 外键保证查得到;查不到只可能是外键被绕过,那要响,不要静默放行。
    IF NOT FOUND THEN
        RAISE EXCEPTION 'MATERIAL_KIND_NOT_FOUND|%', NEW.kind_code;
    END IF;
    IF NEW.may_be_processed AND NOT v_allowed THEN
        RAISE EXCEPTION 'MATERIAL_KIND_NOT_PROCESSABLE|%|%', NEW.kind_code, v_zh
          USING HINT = '这一类东西不可能被投料;要改的是它的种类,或者那一类的规则。';
    END IF;
    RETURN NEW;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.guard_material_kind_processable() FROM PUBLIC, anon;

COMMENT ON FUNCTION public.guard_material_kind_processable() IS
'PROC-1:materials.may_be_processed 不许越过它那一类的 may_ever_be_processed。

════════════════════════════════════════════════════════════════════════════
【它【挡不住】什么 —— 写在这里,因为本仓库最常犯的缺陷是守卫的名字比它的射程宽】

它挡住的是【不可能】:一个 consumable / packaging / spare_part 被标成可投料。
**它挡不住【一个本该可投料的 battery_material 被建成 may_be_processed = false】**
—— 那是一个业务判断,schema 看不见,而且它的症状是【沉默】:
有人想投料,发现投不了,而那一刻离建卡那一刻可能隔着几个月。

**那一半由两处负责,都不是这个守卫:**
  1. **物料表单把这个选择【明说出来】**(PROC-1 同刀),不给默认值 ——
     一个预设某一侧的勾选框就是一个没人做过的决定,从表单进来而不是从 NULL 进来;
  2. **物料列表上一个筛选**:kind_code = ''battery_material'' 且
     may_be_processed = false 的行。**它【不该】做成看板的一支臂** ——
     那不是"等着人处理的事",它可能完全正确(确实有不该被加工的电池料)。
     与 EQP-2d 记下的「哪些机器没人在盯」同一个形状、同一条判据。
════════════════════════════════════════════════════════════════════════════';

CREATE TRIGGER trg_materials_kind_processable
    BEFORE INSERT OR UPDATE ON public.materials
    FOR EACH ROW EXECUTE FUNCTION public.guard_material_kind_processable();

-- ═══ 4 · category 退役 ═════════════════════════════════════════════════════
-- 【为什么在【同一刀】里退役】本仓库那条规矩:一条记录不许活得比它的主体久。
-- 证据已经量过(docs/proc-reality.md N10):视图 0 处、函数 0 处、
-- fixture 只 INSERT 不断言,唯一读者是物料列表的筛选下拉,
-- **而它的合法取值住在第三个地方(app/materials/options.ts)** ——
-- 也就是说【没有任何一处拿它做决定】。
-- 【顺带:它的取值已经与数据矛盾】MAT-2026-0001 标着「进料-电池」而有 10 个产出批。
ALTER TABLE public.materials DROP COLUMN category;

-- ═══ 5 · F4 的那道闸 —— 一条,加在【投料守卫】上 ═══════════════════════════
-- 见抬头 ②:brief 把"runs"排除在外,而一个没有门的 may_be_processed 正是
-- D8 亲口说的那个缺陷。加在 guard_processing_input 上,因为那个守卫【本来就】
-- 是"什么东西可以当投料"的那道门 —— 不动 commit_processing_run 一个字。
-- 【既有两条分支逐字保留】直插守卫与自吞守卫原样,新的一条加在末尾。
CREATE OR REPLACE FUNCTION public.guard_processing_input()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_material_id uuid;
    v_may  boolean;
    v_code text;
BEGIN
    IF current_setting('evoltrya.movement_ctx', true) NOT LIKE 'processing:%'
       AND current_setting('evoltrya.movement_ctx', true) NOT LIKE 'reversal:%' THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_DIRECT_INSERT';
    END IF;
    IF NEW.output_batch_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM processing_outputs po
        WHERE po.output_batch_id = NEW.output_batch_id AND po.run_id = NEW.run_id
    ) THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_SELF_CONSUME|%', NEW.run_id;
    END IF;
    -- ── PROC-1:只有【说了可以投料】的物料进得来 ────────────────────────────
    -- 【NULL 不放行】八行历史物料的 may_be_processed 是空的,而空的意思是
    -- "没有人决定过" —— 把它读成"可以"正是本仓库反复付账的那一个错
    -- (METAL-1 的 no_reference、SS-1 的阈值为 NULL)。所以判据写成
    -- `IS NOT TRUE`:空与 false 一样被拦,而拒绝的话说得出是哪一种。
    SELECT COALESCE(ib.material_id, ob.material_id) INTO v_material_id
      FROM (SELECT 1) x
      LEFT JOIN inbound_batches ib ON ib.id = NEW.inbound_batch_id
      LEFT JOIN output_batches  ob ON ob.id = NEW.output_batch_id;
    IF v_material_id IS NOT NULL THEN
        SELECT m.may_be_processed, m.code INTO v_may, v_code
          FROM materials m WHERE m.id = v_material_id;
        IF v_may IS NOT TRUE THEN
            RAISE EXCEPTION 'MATERIAL_NOT_PROCESSABLE|%|%', v_code,
                CASE WHEN v_may IS NULL THEN 'undecided' ELSE 'false' END
              USING HINT = '这一种物料没有被声明为可投料;第二个参数说的是【没人决定过】还是【决定了不投】。';
        END IF;
    END IF;
    RETURN NEW;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.guard_processing_input() FROM PUBLIC, anon;

COMMIT;
