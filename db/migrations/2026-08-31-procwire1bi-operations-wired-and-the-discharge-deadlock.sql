-- PROC-WIRE-1B-i:工序接进加工单 + 逐工序的安全状态受理 + 直通式工序(R3)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- ★★ 本刀最要紧的一条:【深度放电今天根本跑不了,而挡住它的不是 NO_OUTPUTS】★★
--
-- 盘问阶段量到的:
--   * `inbound_safety_states.charged_not_discharged` 的 **may_be_fed = false**;
--   * `guard_processing_input` 对任何带着不可投料状态的投料抛
--     `INPUT_SAFETY_STATE_NOT_FEEDABLE`。
--
-- **于是这道闸拒绝投喂的,恰恰是深度放电存在的全部理由那一种料。**
-- 一块没放过电的电池是唯一需要放电的东西,而它不许被投进任何东西。
-- 两条拒绝互相指着对方 —— 与 PROC-BUILD-1 的 fu1 修掉的那个死锁【同一个形状】。
--
-- **这条发现改变了本刀的形状:** 只把 `NO_OUTPUTS` 放松掉、把字典建出来,
-- 深度放电【仍然跑不了】,而那样的一刀会报告成功却什么都没演示。
--
-- 【根因:may_be_fed 答的是一个问错了的问题】它今天的意思是"可不可以投给
-- 【任何】工序",而它真正的意思是"可不可以投给【转化型】工序"。
-- 深度放电的全部目的就是【受理】充电状态并把它清掉。
-- 于是这条轴与 R1 的形态轴是同一个形状:**工序自己声明它受理哪些安全状态**。
--
-- 【红线,而且是 Tim 的硬要求】这是一张【逐工序的、明写的受理清单】,
-- **绝不是"状态改变型工序一律放行"那种按 kind 的旁路**。
-- `damaged_deformed` 与 `swollen_leaking` 是放电机【解决不了】的起火风险,
-- 深度放电**不受理**它们。
--
-- 【不变式,fixture 钉住它】
--   (a) 加工单【没有】工序类型 → may_be_fed 仍然是答案,今天的行为一个字不变;
--   (b) 加工单【有】工序类型 → 只有明写在清单里的状态才被受理,
--       **没写的一律拒,哪怕它 may_be_fed = true**。
--   也就是说:**声明一道工序只会把闸【收紧】;任何放宽都必须是一行明写的数据。**
--   一个"设了工序就放行"的实现,在 fixture 里必须红。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 【本刀是 1B-i,不是整个 1B】盘问把 1B 拆成三刀,判据是"一刀演示一件事":
--   * **1B-i(本刀)**:工序字典 + operation_type_code + 逐工序安全受理 +
--     直通式工序端到端。**演示的那一件事:深度放电真的跑得起来。**
--   * **1B-ii**:M4(产出批的安全状态)+ 在制品可见性。
--     M4 不是改一道守卫,是【一张还不存在的表】—— 安全状态今天只有进料批有,
--     所以那道闸不是"不问产出批",是【问不了】。它是第二件可演示的事。
--   * **1B-iii**:R6 采购时的判断。它碰不到加工单,而且 grn_discrepancies
--     已经是那个形状(预期 vs 实际,缺一侧给 NULL 而不是 false)。
-- **记下来是三刀,不是一刀缩了水。**
--
-- 【直通式工序:放松 NO_OUTPUTS 是这件事里最小的一块】
-- 只放松那一个检查会【毁掉批次】:投料循环会 drain_stock 并把 remaining_qty
-- 扣到 0(货还在院子里,账上没了),而 loss_qty = COALESCE(p_loss_qty,
-- total_input - total_output) 会凭空记下一笔【等于全部投入】的损耗。
-- 所以直通式是一条【自己的分支】:料【穿过】工序而不是被消耗。
--
-- 幂等性:一次性 DDL,不可重入。
BEGIN;

-- ═══ 1 · 工序的【种类】—— 而两条规则列就是它存在的理由 ═══════════════════
--
-- 【为什么种类是字典而不是 CHECK】运行时的分支【读这两列】,不读一个写死的
-- 'state_changing' 字符串。于是"直通"这件事是【数据】说的,不是代码说的 ——
-- 与 PROC-WIRE-1A 的 is_saleable_stock 同一条,fixture 也用同一种方式钉它。
CREATE TABLE public.operation_kinds (
    code             text PRIMARY KEY,
    name_en          text NOT NULL,
    name_zh          text NOT NULL,
    -- 【规则列 ①】这一类工序【吃不吃】投料。false = 料穿过去,库存不动。
    consumes_input   boolean NOT NULL,
    -- 【规则列 ②】这一类工序【产不产】新批次。false = 没有产出腿,而那【不是】
    -- "忘了填",是这一类工序的定义(R3:同一批进、同一批出,只改状态)。
    produces_outputs boolean NOT NULL,
    is_active        boolean NOT NULL DEFAULT true,
    sort_order       integer NOT NULL DEFAULT 0,
    notes            text
);

COMMENT ON TABLE public.operation_kinds IS
'PROC-WIRE-1B-i:一道工序【属于哪一类】。RUNTIME CONFIG,加一种是加一行。

【两条规则列就是它存在的全部理由】commit_processing_run 的分支【读这两列】,
不读一个写死的字符串。于是"这道工序吃不吃料、产不产批"是【数据】回答的 ——
与 output_batch_purposes.is_saleable_stock 同一条。

【为什么两列而不是一列】它们今天完全相关(转化=吃且产,状态改变=不吃不产),
但概念上独立:一道"只吃不产"的工序是【纯销毁】,而"只产不吃"是不可能的。
把它们合成一列,等于断言那个巧合是一条定律。';

INSERT INTO public.operation_kinds (code, name_en, name_zh, consumes_input, produces_outputs, sort_order, notes) VALUES
    ('transforming', 'Transforming', '转化型', true, true, 1,
     '料被吃掉,变成一批或几批新东西。今天线上 13 张加工单全部是这一类(虽然它们还没有工序类型)。'),
    ('state_changing', 'State-changing', '状态改变型', false, false, 2,
     '【R3】同一批进、同一批出,只改状态,不产新批。**料【穿过】工序,库存一克不动** —— 深度放电就是这一种。它没有产出腿,而那不是"忘了填"。');

-- ═══ 2 · 工序类型字典(R2 的五道)═══════════════════════════════════════
CREATE TABLE public.operation_types (
    code                        text PRIMARY KEY,
    name_en                     text NOT NULL,
    name_zh                     text NOT NULL,
    kind_code                   text NOT NULL REFERENCES public.operation_kinds (code),
    -- 【状态改变型工序把料改成【哪个】状态】R3 的"改状态"落在这一列上。
    -- 转化型为空 —— 那是"不适用",不是"没人决定过"(守卫在下面把这条钉死)。
    resulting_safety_state_code text REFERENCES public.inbound_safety_states (code),
    is_active                   boolean NOT NULL DEFAULT true,
    sort_order                  integer NOT NULL DEFAULT 0,
    notes                       text
);

COMMENT ON TABLE public.operation_types IS
'PROC-WIRE-1B-i:一道【工序】。R2 的五道,一台机器一道。RUNTIME CONFIG。

【R1:形态不是一条有序的链】每一道工序【自己声明】它收哪些形态、出哪些形态,
路由是一张 N×M 关系表(operation_type_input_forms / _output_forms),
**不是从一个序列推出来的**。

【安全状态用【同一个形状】】operation_type_safety_states 与那两张形态表同形 ——
"这道工序受理什么"因此只有【一个】定义方式,不是两套。
盘问明令:不许把"受理的形态"与"受理的安全状态"做成两种不一致的形状。

【resulting_safety_state_code 只对状态改变型有意义】转化型必须为空,
状态改变型必须非空 —— 由 guard_operation_type_shape 执行,让数据回答,不靠人猜。';

-- 【形状守卫:让"空"的意思由种类回答】与 PROC-BUILD-1 的
-- guard_material_condition_axes 同一条 —— 空是"不适用"还是"没人决定过",
-- 必须由数据回答,不能靠读的人猜。
CREATE OR REPLACE FUNCTION public.guard_operation_type_shape()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE v_changes boolean;
BEGIN
    SELECT NOT k.produces_outputs INTO v_changes
      FROM public.operation_kinds k WHERE k.code = NEW.kind_code;

    IF v_changes AND NEW.resulting_safety_state_code IS NULL THEN
        RAISE EXCEPTION 'OPERATION_RESULT_STATE_REQUIRED|%', NEW.code
          USING HINT = '状态改变型工序【必须】说出它把料改成哪个状态 —— R3 的"改状态"就是这一列。没有它,这道工序什么都不做。';
    END IF;
    IF NOT v_changes AND NEW.resulting_safety_state_code IS NOT NULL THEN
        RAISE EXCEPTION 'OPERATION_RESULT_STATE_NOT_APPLICABLE|%', NEW.code
          USING HINT = '转化型工序不改投料批的安全状态 —— 它把料吃掉,产出新批。这一列对它【不适用】,必须为空。';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_operation_types_shape
    BEFORE INSERT OR UPDATE ON public.operation_types
    FOR EACH ROW EXECUTE FUNCTION public.guard_operation_type_shape();

INSERT INTO public.operation_types (code, name_en, name_zh, kind_code, resulting_safety_state_code, sort_order, notes) VALUES
    ('deep_discharge', 'Deep discharge', '深度放电', 'state_changing', 'discharged_verified', 1,
     '【R3】同一批进、同一批出,只把状态从"未放电"改成"已放电并核实"。**它不产任何新批次。** 它是唯一一道受理 charged_not_discharged 的工序 —— 那正是它存在的理由,也正是本刀发现的那个死锁的解。'),
    ('manual_disassembly', 'Manual disassembly', '人工拆解', 'transforming', NULL, 2,
     '【R2】整包/模组 → 电芯,**同时**产出壳体与结构件(R2 明写"ALSO yielding")。人工台。'),
    ('electrode_line', 'Automatic electrode line', '自动极片线', 'transforming', NULL, 3,
     '【R2】电芯 → 壳体 / 正极片 / 负极片 / 隔膜。**开壳与极片分离是【一道】工序**(R2 明写),不是两道。【R4:电解液在这里挥发】—— 它不是产出形态,它是一个损耗类别(loss_categories.electrolyte_evaporation),所以它【不在】本工序的产出形态里。'),
    ('electrode_powder_line', 'Electrode powder line', '极片粉料线', 'transforming', NULL, 4,
     '【R2】极片 → 黑粉。'),
    ('battery_powder_line', 'Battery powder line', '整电池粉料线', 'transforming', NULL, 5,
     '【R2】**不同的设备**,专收放不了电的整包/模组/3C 电池/损坏电池。它与极片粉料线是两道工序,理由就是"一台机器一道工序"。');

-- ═══ 3 · 受理关系(R1 的 N×M)—— 三张同形的表 ═══════════════════════════
CREATE TABLE public.operation_type_input_forms (
    operation_type_code text NOT NULL REFERENCES public.operation_types (code) ON DELETE CASCADE,
    form_code           text NOT NULL REFERENCES public.material_forms (code),
    notes               text,
    PRIMARY KEY (operation_type_code, form_code)
);

CREATE TABLE public.operation_type_output_forms (
    operation_type_code text NOT NULL REFERENCES public.operation_types (code) ON DELETE CASCADE,
    form_code           text NOT NULL REFERENCES public.material_forms (code),
    notes               text,
    PRIMARY KEY (operation_type_code, form_code)
);

CREATE TABLE public.operation_type_safety_states (
    operation_type_code text NOT NULL REFERENCES public.operation_types (code) ON DELETE CASCADE,
    safety_state_code   text NOT NULL REFERENCES public.inbound_safety_states (code),
    -- 【这道工序把这个状态【解决掉】没有】深度放电解决 charged_not_discharged;
    -- 它受理 discharged_verified 但那个状态不需要被解决。
    -- 提交一张状态改变型加工单时,被解决的那些状态从批次上【删掉】,
    -- 再写上 resulting_safety_state_code —— 否则那批货会永远带着"未放电"。
    resolves            boolean NOT NULL DEFAULT false,
    notes               text,
    PRIMARY KEY (operation_type_code, safety_state_code)
);

COMMENT ON TABLE public.operation_type_safety_states IS
'PROC-WIRE-1B-i:这道工序【受理】哪些安全状态。**这张表是那个死锁的解。**

【它与 may_be_fed 的关系,一句话说清】may_be_fed 是【没有工序类型时】的答案,
也就是今天的行为;一旦加工单说出了自己是哪道工序,答案就换成这张表。

【不变式:只许收紧,不许默认放宽】
  * 没有工序类型 → may_be_fed,行为一个字不变;
  * 有工序类型 → **只有这张表里明写的才受理,没写的一律拒**,
    哪怕它 may_be_fed = true。
声明一道工序只会把闸收紧;任何放宽都必须是这里的一行【明写的数据】。
**"设了工序就放行"的实现,在 fixture 里是红的。**

【为什么 swollen_leaking 一道工序都没有受理】R2 点名整电池粉料线收
"放不了电的整包/模组/3C/损坏电池",没有点名【鼓包漏液】。
漏液是与"变形"不同的一种危害,而这是全系统唯一一道失败后果是【起火】的闸 ——
不确定时站在拒绝那一侧。**于是这种料今天没有路线,那是刻意的**,
它等 Tim 的一句裁定,不等一个猜测。';

-- 投料形态(R1:每道工序自己声明)
INSERT INTO public.operation_type_input_forms (operation_type_code, form_code, notes) VALUES
    ('deep_discharge', 'whole_pack', NULL),
    ('deep_discharge', 'module', NULL),
    ('deep_discharge', 'loose_cells', NULL),
    ('deep_discharge', 'mixed_unsorted', '未分选料里可能混着没放过电的电池。'),
    ('manual_disassembly', 'whole_pack', NULL),
    ('manual_disassembly', 'module', NULL),
    ('electrode_line', 'loose_cells', NULL),
    ('electrode_line', 'de_cased_cell', '【F2/R2】已开壳电芯也可以是【买进来的】——同一种物质,同一条下游路。'),
    ('electrode_powder_line', 'cathode_sheet', NULL),
    ('electrode_powder_line', 'anode_sheet', NULL),
    ('electrode_powder_line', 'electrode_scrap', '边角料与废片走同一条粉料线。'),
    ('battery_powder_line', 'whole_pack', NULL),
    ('battery_powder_line', 'module', NULL),
    ('battery_powder_line', 'mixed_unsorted', NULL);

-- 产出形态(状态改变型【一行都没有】,那正是 R3)
INSERT INTO public.operation_type_output_forms (operation_type_code, form_code, notes) VALUES
    ('manual_disassembly', 'loose_cells', NULL),
    ('manual_disassembly', 'casing', '【R2】拆包/模组时【同时】产出。'),
    ('manual_disassembly', 'structural_parts', '【R2】同上。'),
    ('electrode_line', 'casing', NULL),
    ('electrode_line', 'cathode_sheet', NULL),
    ('electrode_line', 'anode_sheet', NULL),
    ('electrode_line', 'separator', '【R4】它是一个【出口】——离开这条线,不再往下走。'),
    ('electrode_powder_line', 'black_mass', NULL),
    ('battery_powder_line', 'black_mass', NULL);

-- 安全状态受理 —— **本刀的核心**
INSERT INTO public.operation_type_safety_states (operation_type_code, safety_state_code, resolves, notes) VALUES
    -- 【深度放电】唯一受理"未放电"的工序,而且它【解决】这个状态。
    ('deep_discharge', 'charged_not_discharged', true,
     '★ 这一行就是死锁的解:唯一受理"未放电"的地方,而且放完之后这个状态被【删掉】。'),
    ('deep_discharge', 'discharged_verified', false,
     '已经放过电的料再进一次放电机,无害 —— 受理,但没有什么要解决的。'),
    -- 【深度放电【不】受理任何损坏状态】Tim 的硬要求:放电机解决不了起火风险。
    -- 于是这里【故意】没有 damaged_deformed / water_exposed / swollen_leaking 三行。

    ('manual_disassembly', 'discharged_verified', false, NULL),
    ('electrode_line', 'discharged_verified', false, NULL),
    ('electrode_powder_line', 'discharged_verified', false, NULL),

    -- 【整电池粉料线】R2 明写它收"放不了电的整包/模组/3C/损坏电池" ——
    -- 所以它受理"未放电"与"变形损坏",而那正是它与极片粉料线是【两台设备】的理由。
    ('battery_powder_line', 'discharged_verified', false, NULL),
    ('battery_powder_line', 'charged_not_discharged', false,
     '【R2】它专收【放不了电】的料 —— 那种料按定义就是没放过电的。它不【解决】这个状态:料在这里被粉碎掉了,不是被放电了。'),
    ('battery_powder_line', 'damaged_deformed', false,
     '【R2】"损坏电池"。同上,不解决 —— 料被粉碎掉了。');

-- ═══ 4 · 把工序接进加工单 ═══════════════════════════════════════════════
--
-- 【可空,而且这是刻意的】线上 13 张加工单没有工序类型,而它们是测试残留 ——
-- **绝不给它们猜一个工序**(猜出来的工序与真的工序长得一模一样,而它会流进
-- 设备用量、回收率、工单实绩)。
--
-- 【那么什么拦得住一张【真】的加工单不填工序?—— 今天:没有东西。】
-- 界面上它是必填的,数据库上不是。**这句话必须照直说**,而不是发明一条约束:
-- 一条 NOT NULL 会把那 13 行就地冻住,而 NOT VALID 的 CHECK 只管新行 ——
-- 后者是可以考虑的,但它要一次裁定:"从今天起加工单必须说出工序"。
-- **那是产线跑起来那天的事,不是本刀的事**;记为具名缺口,见文档。
ALTER TABLE public.processing_runs
    ADD COLUMN operation_type_code text REFERENCES public.operation_types (code);

COMMENT ON COLUMN public.processing_runs.operation_type_code IS
'PROC-WIRE-1B-i:这张加工单跑的是【哪一道工序】。

【可空】线上 13 张是测试残留,不给它们猜工序。
【什么拦得住真单不填?今天没有东西】—— 界面必填,数据库不拦。
一条 NOT VALID 的 CHECK 可以只管新行,但那要一次"从今天起必须填"的裁定,
属于产线跑起来那天。**记为具名缺口,不发明约束。**

【命名】仓库里每一张字典都以 text code 为主键(form_code / purpose_code /
loss_category_code / chemistry_certainty_code),所以这一列叫 _code 而不是 _id。
brief 写的是 operation_type_id,那个名字假设了 uuid 主键 —— 照抄它才是漂移。';

-- ═══ 5 · 那道闸:逐工序受理(死锁的解)═════════════════════════════════
CREATE OR REPLACE FUNCTION public.guard_processing_input()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_material_id uuid;
    v_may  boolean;
    v_code text;
    v_axes       boolean;
    v_batch_code text;
    v_n          integer;
    v_bad_zh     text;
    v_bad_en     text;
    v_c_zh       text;
    v_c_en       text;
    -- PROC-WIRE-1B-i
    v_op         text;
    v_op_zh      text;
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

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-3:这一【批】货现在是什么状态
    --
    -- 【只问进料批次,不问产出批次】—— **M4,仍然没修,归 1B-ii。**
    -- 理由不是"产出批不需要问",而是【问不了】:安全状态今天只有进料批有,
    -- 根本没有 output_batch_safety_states 这张表。那是 1B-ii 的第一件事。
    -- ════════════════════════════════════════════════════════════════════════
    IF NEW.inbound_batch_id IS NOT NULL THEN
        SELECT mk.has_condition_axes INTO v_axes
          FROM inbound_batches ib
          JOIN materials       m  ON m.id   = ib.material_id
          JOIN material_kinds  mk ON mk.code = m.kind_code
         WHERE ib.id = NEW.inbound_batch_id;

        IF FOUND AND v_axes IS TRUE THEN
            SELECT ib.code INTO v_batch_code
              FROM inbound_batches ib WHERE ib.id = NEW.inbound_batch_id;

            -- 【D1:缺席仍然是自己那一条拒绝】"没有人记过"→ 去把它记下来。
            -- 这一条【与工序无关】:不管跑哪道工序,没人看过的料都不许进。
            SELECT count(*) INTO v_n
              FROM inbound_batch_safety_states s
             WHERE s.inbound_batch_id = NEW.inbound_batch_id;
            IF v_n = 0 THEN
                RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_RECORDED|%', v_batch_code
                  USING HINT = '一条安全状态都没有的意思是【没有人记过】,不是"这批货安全"。到【进料 → 打开这一批 → 到货状态】那一块把它记上。';
            END IF;

            -- ════════════════════════════════════════════════════════════════
            -- ★ PROC-WIRE-1B-i:受理由【这道工序】回答 ★
            --
            -- 【没有工序类型 → may_be_fed,今天的行为一个字不变】
            -- 【有工序类型 → 只受理明写的那些,没写的一律拒】
            --
            -- **方向只有一个:声明一道工序只会把闸收紧。** 任何放宽都必须是
            -- operation_type_safety_states 里一行明写的数据 —— 绝没有
            -- "状态改变型一律放行"那种按 kind 的旁路(那会让一块鼓包漏液的
            -- 电池进放电机,而放电机解决不了它)。
            --
            -- 【D2 合取仍然成立】一批料身上每一个状态都必须被受理;
            -- 有一条不被受理就拒,并且【一次点完】所有不被受理的。
            -- 【D4:仍然不读 is_active】—— 已经记下来的事实不因字典停用而改变。
            -- ════════════════════════════════════════════════════════════════
            SELECT pr.operation_type_code INTO v_op
              FROM processing_runs pr WHERE pr.id = NEW.run_id;

            IF v_op IS NULL THEN
                SELECT string_agg(d.name_zh, '、' ORDER BY d.sort_order)
                         FILTER (WHERE d.may_be_fed IS NOT TRUE),
                       string_agg(d.name_en, ', ' ORDER BY d.sort_order)
                         FILTER (WHERE d.may_be_fed IS NOT TRUE)
                  INTO v_bad_zh, v_bad_en
                  FROM inbound_batch_safety_states s
                  JOIN inbound_safety_states d ON d.code = s.safety_state_code
                 WHERE s.inbound_batch_id = NEW.inbound_batch_id;

                IF v_bad_zh IS NOT NULL THEN
                    RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_FEEDABLE|%|%|%',
                        v_batch_code, v_bad_zh, v_bad_en
                      USING HINT = '这一批带着不可投料的安全状态(全部列在消息里,一次清完)。状态改了要到【进料 → 打开这一批 → 到货状态】那一块改。';
                END IF;
            ELSE
                SELECT ot.name_zh INTO v_op_zh FROM operation_types ot WHERE ot.code = v_op;

                SELECT string_agg(d.name_zh, '、' ORDER BY d.sort_order),
                       string_agg(d.name_en, ', ' ORDER BY d.sort_order)
                  INTO v_bad_zh, v_bad_en
                  FROM inbound_batch_safety_states s
                  JOIN inbound_safety_states d ON d.code = s.safety_state_code
                 WHERE s.inbound_batch_id = NEW.inbound_batch_id
                   AND NOT EXISTS (
                       SELECT 1 FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op
                          AND a.safety_state_code = s.safety_state_code);

                IF v_bad_zh IS NOT NULL THEN
                    RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_ACCEPTED|%|%|%|%',
                        v_batch_code, COALESCE(v_op_zh, v_op), v_bad_zh, v_bad_en
                      USING HINT = '这道工序【不受理】这一批身上的某些安全状态(全部列在消息里)。这与"不可投料"是两句话:换一道受理它的工序也许就行 —— 比如没放电的料要先走【深度放电】。';
                END IF;
            END IF;

            -- 【D3:确定度【没记】仍然放行】不要"修"掉这处不对称 ——
            -- 安全状态防的是【起火】,确定度防的是【数字算错】,后者由化验回答,
            -- 不由停线回答。线上 23 批货一条确定度都没有。
            SELECT c.name_zh, c.name_en INTO v_c_zh, v_c_en
              FROM inbound_batches ib
              JOIN inbound_chemistry_certainties c ON c.code = ib.chemistry_certainty_code
             WHERE ib.id = NEW.inbound_batch_id
               AND c.may_be_fed IS NOT TRUE;
            IF FOUND THEN
                RAISE EXCEPTION 'INPUT_CHEMISTRY_NOT_FEEDABLE|%|%|%',
                    v_batch_code, v_c_zh, v_c_en
                  USING HINT = '这一批的化学体系确定度被记成了一个不可投料的值。到【进料 → 打开这一批 → 到货状态】那一块改。';
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$fn$;

-- ═══ 6 · 提交路:直通式分支 ═══════════════════════════════════════════════
--
-- 【为什么是 DROP + CREATE 而不是 CREATE OR REPLACE】新增了一个参数,签名就变了,
-- 而 db/preflight_migration.py 对"同名不同签名"是【拒绝】的 —— 那会变成一个
-- 重载:旧签名活下来,成为镜像看不见的漂移(FIN-21 记过这一条)。
-- 所以显式先删后建,整支仍在同一笔事务里。
DROP FUNCTION public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid);

CREATE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, p_work_order_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_operation_type_code text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id      uuid := auth.uid();
    v_process_date date;
    v_run_id       uuid;
    v_total_input  numeric := 0;
    v_total_output numeric := 0;
    v_input        jsonb;
    v_output       jsonb;
    v_inbound_id   uuid;
    v_output_id    uuid;   -- FIN-25:再加工投料(产出批为源)
    v_consumed     numeric;
    v_remaining    numeric;
    v_available     numeric;
    v_held          numeric;
    v_new_remaining numeric;
    v_material_id  uuid;
    v_qty          numeric;
    v_unit         text;
    v_purity       text;
    v_new_output_id uuid;
    v_wo           work_orders%ROWTYPE;   -- WO-1b
    v_eq           fixed_assets%ROWTYPE;  -- EQP-2a:这一炉归给哪台机器
    -- PROC-WIRE-1B-i:这一炉跑的是哪道工序,以及那道工序【吃不吃料、产不产批】。
    -- 【分支读的是字典那两列,不是一个写死的字符串,也不是调用方传的旗标】
    v_op           text;
    v_consumes     boolean := true;   -- 没有工序类型时:今天的行为
    v_produces     boolean := true;
    v_result_state text;
BEGIN
    PERFORM require_permission('module.processing.edit');
    IF p_process_date IS NULL THEN
        RAISE EXCEPTION 'PROCESS_DATE_REQUIRED';
    END IF;

    -- FIN-36:分摊基准【必填】。不在这里回退到 finance_settings 的公司默认值 ——
    -- 那只会把"没人选过"从 schema 挪进函数,同一个病换一层楼。表单永远带着值来
    -- (预选自 finance_settings.default_allocation_basis),所以必填没有代价。
    IF p_allocation_basis IS NULL THEN
        RAISE EXCEPTION 'ALLOCATION_BASIS_REQUIRED';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-WIRE-1B-i:解析工序类型。**分支由【工序】决定,不由调用方传旗标决定** ——
    -- 一个 p_is_state_changing 参数会让"这一炉算不算直通"变成调用方的意见,
    -- 而它是那道工序的事实。两者的区别在第一次有人传错的时候才显形,那太晚了。
    -- 【没有工序类型 → v_consumes / v_produces 都是 true,今天的行为一个字不变。】
    -- ════════════════════════════════════════════════════════════════════════
    IF p_operation_type_code IS NOT NULL THEN
        SELECT ot.code, k.consumes_input, k.produces_outputs, ot.resulting_safety_state_code
          INTO v_op, v_consumes, v_produces, v_result_state
          FROM operation_types ot
          JOIN operation_kinds k ON k.code = ot.kind_code
         WHERE ot.code = p_operation_type_code AND ot.is_active;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'OPERATION_TYPE_UNKNOWN|%', p_operation_type_code
              USING HINT = '未知或已停用的工序。停用的意思是"以后别再选它",不是"把历史改掉"。';
        END IF;
    END IF;
    IF p_allocation_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', p_allocation_basis;
    END IF;

    -- ── WO-1b:工单这一支【只在给了参数的时候才存在】────────────────────────
    -- 【为什么是可选的,而不是必填】临时起意的加工是合法的 —— 车间不会为了系统
    -- 先去补一张计划。把它变成必填,得到的不是纪律,是一堆事后补的假工单。
    -- 差异报表因此必须把 work_order_id 为空的那些显示成【计划外】这一个具名的
    -- 类别,而不是让它们悄悄消失(那是 WO-1c 的事,规则记在这里)。
    IF p_work_order_id IS NOT NULL THEN
        SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'WO_NOT_FOUND|%', p_work_order_id;
        END IF;
        -- 【只有放行了的工单可以开工】草稿是还没答应的事(与 reserve_stock 只认
        -- 已确认订单同一条);而 closed / cancelled 是【已经结束的事】,再往上挂
        -- 一次加工会让那张单的完成度在它收工之后继续变 —— 收工时写进理由行的
        -- 那句"runs=N"从此不再复算得出来。
        IF v_wo.status <> 'released' THEN
            RAISE EXCEPTION 'WO_NOT_RELEASED|%|%', v_wo.code, v_wo.status;
        END IF;
    END IF;

    -- ── EQP-2a:机器这一支【也只在给了参数的时候才存在】────────────────────
    -- 位置跟着 WO-1b 那一支放。【为什么可空】线上十三炉一台机器都没有归属,
    -- 而临时起意的加工是合法的 —— "未归属"必须是一个【具名类别】,不是一个零。
    IF p_equipment_id IS NOT NULL THEN
        SELECT * INTO v_eq FROM fixed_assets WHERE id = p_equipment_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_FOUND|%', p_equipment_id;
        END IF;
        -- 【拒绝的边界钉在"真的不可能"上,不钉在"还没投用"上】
        -- 加工日早于取得日 = 那天这台机器还不是我们的。
        IF p_process_date < v_eq.acquisition_date THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_ACQUIRED|%|%|%',
                v_eq.code, v_eq.acquisition_date, p_process_date
              USING HINT = '这一炉的日期早于这台机器的取得日 —— 那天它还不是我们的';
        END IF;
        -- 处置之后它已经不在了。
        IF v_eq.status = 'disposed' AND v_eq.disposal_date IS NOT NULL
           AND p_process_date > v_eq.disposal_date THEN
            RAISE EXCEPTION 'EQUIPMENT_DISPOSED|%|%|%',
                v_eq.code, v_eq.disposal_date, p_process_date
              USING HINT = '这一炉的日期晚于这台机器的处置日 —— 那时它已经不在了';
        END IF;
        -- 【投用之前【不】拒 —— 这是本刀对原设计改动最大的一处】
        -- 原设计要拒"加工日那天机器不在役",而 in_service_date 是【投用】日。
        -- 投用之前的试车是这盘生意里一件有名有姓的事:
        -- docs/equipment-survey.md 的资本化边界那一节把"试车料"与安装、调试并列。
        -- 拒掉它们,系统就【记不下那些正好用来证明投用日的加工】,也丢掉了
        -- 那段真实的磨损 —— 而 EQP-2b 的保养间隔要读它。
        -- 剩下被拒的两种都是真的不可能,所以它们【是拒绝,不是警告】。
    END IF;

    v_process_date := p_process_date;
    -- 0. 基本校验
    IF p_inputs IS NULL OR jsonb_array_length(p_inputs) = 0 THEN
        RAISE EXCEPTION 'NO_INPUTS';
    END IF;
    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-WIRE-1B-i:产出的有无,由【工序】说了算
    --   * 会产出的工序(转化型)少了产出 → 照旧 NO_OUTPUTS,一个字没松;
    --   * 不产出的工序(状态改变型,R3)带着产出来 → 【也是拒】,而且是另一条码。
    -- 后者容易被漏掉:只放松一侧会让一张"放电还产出了黑粉"的单悄悄成立。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_produces THEN
        IF p_outputs IS NULL OR jsonb_array_length(p_outputs) = 0 THEN
            RAISE EXCEPTION 'NO_OUTPUTS';
        END IF;
    ELSE
        IF p_outputs IS NOT NULL AND jsonb_array_length(p_outputs) > 0 THEN
            RAISE EXCEPTION 'OPERATION_PRODUCES_NO_OUTPUTS|%', v_op
              USING HINT = '这道工序【按定义】不产新批次(R3:同一批进、同一批出,只改状态)。带着产出提交它,说明选错了工序或者选错了单。';
        END IF;
    END IF;
    IF p_loss_qty IS NOT NULL AND p_loss_qty < 0 THEN
        RAISE EXCEPTION 'LOSS_NEGATIVE';
    END IF;

    -- 0b. 同一批次(不论来源)不能重复添加。FIN-25:投料可为进料批或产出批,
    --     恰一非空;两个都给或都不给 → INPUT_PARENT_INVALID。
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_inputs) elem
        WHERE num_nonnulls(elem->>'inbound_batch_id', elem->>'output_batch_id') <> 1
    ) THEN
        RAISE EXCEPTION 'INPUT_PARENT_INVALID';
    END IF;
    IF (SELECT count(DISTINCT COALESCE(elem->>'inbound_batch_id', elem->>'output_batch_id'))
        FROM jsonb_array_elements(p_inputs) elem) <> jsonb_array_length(p_inputs) THEN
        RAISE EXCEPTION 'DUPLICATE_INPUT';
    END IF;

    -- 1. 遍历投入:校验库存(并锁行)+ 累计投入合计
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_consumed IS NULL OR v_consumed <= 0 THEN
            RAISE EXCEPTION 'INPUT_QTY_INVALID';
        END IF;

        IF v_inbound_id IS NOT NULL THEN
            SELECT remaining_qty INTO v_remaining
            FROM inbound_batches
            WHERE id = v_inbound_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_inbound_id;
            END IF;
        ELSE
            -- FIN-25:产出批投料 —— 同一套校验、同一把锁。库存机器本就共用
            -- (inventory_movements 两侧 XOR,remaining_qty 两表同义)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches
            WHERE id = v_output_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_output_id;
            END IF;
        END IF;
        -- IOD-1:投得进去的是【可用】,不是【物理剩余】—— 被扣住的货还在批次里,
        -- 但它不可动用。拒绝同时说出可用与暂扣两个数,否则人看着 remaining 够
        -- 却投不进去,屏幕上没有任何解释。
        v_available := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                                 WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                                   AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                                   AND m.stock_status = 'available'), 0);
        v_held := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                            WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                              AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                              AND m.stock_status = 'on_hold'), 0);
        IF v_consumed > v_available THEN
            RAISE EXCEPTION 'IOD_CONSUME_EXCEEDS_AVAILABLE|%|%|%', v_consumed, v_available, v_held;
        END IF;

        v_total_input := v_total_input + v_consumed;
    END LOOP;

    -- 2. 遍历产出:校验 + 累计产出合计
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_qty := (v_output->>'quantity')::numeric;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'OUTPUT_QTY_INVALID';
        END IF;
        IF (v_output->>'material_id') IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NO_MATERIAL';
        END IF;
        v_total_output := v_total_output + v_qty;
    END LOOP;

    -- 3. 质量守恒:产出不能大于投入
    IF v_total_output > v_total_input THEN
        RAISE EXCEPTION 'OUTPUT_EXCEEDS_INPUT|%|%', v_total_output, v_total_input;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-WIRE-1B-i:直通式的质量账
    -- **料【穿过】工序,没有被吃掉** —— 所以投入 = 产出 = 通过量,损耗【真的是 0】
    -- (放电不带走任何质量;这不是"没量过所以填 0",是 R3 说的同一批进同一批出)。
    -- 不这么写的话:total_output = 0 会让质量平衡读成"投了 100 出来 0",
    -- 而 loss_qty = COALESCE(p_loss_qty, 100 - 0) 会凭空记下一笔【等于全部投入】
    -- 的损耗 —— 一张放电单会报告它把碰过的东西全毁了。
    -- ════════════════════════════════════════════════════════════════════════
    IF NOT v_produces THEN
        v_total_output := v_total_input;
        IF COALESCE(p_loss_qty, 0) <> 0 THEN
            RAISE EXCEPTION 'STATE_CHANGE_LOSS_NOT_ZERO|%|%', v_op, p_loss_qty
              USING HINT = '状态改变型工序不带走质量,所以它的损耗只能是 0。填了别的数,要么选错了工序,要么这一炉其实是转化型。';
        END IF;
    END IF;

    -- 4. 建加工单表头(code 由触发器生成)
    INSERT INTO processing_runs (
        process_date, total_input, total_output, loss_qty, notes, status,
        allocation_basis, work_order_id, created_by, updated_by, equipment_id,
        operation_type_code
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        CASE WHEN v_produces THEN COALESCE(p_loss_qty, v_total_input - v_total_output)
             ELSE 0 END,
        p_notes, 'committed', p_allocation_basis, p_work_order_id, v_user_id, v_user_id,
        p_equipment_id,
        v_op
    )
    RETURNING id INTO v_run_id;

    -- 5. 再遍历投入:扣库存 + 更新阶段 + 建投入腿 + 记库存流水(消耗)
    --    FIN-25:ctx 提前到这里 —— 投入腿的守卫触发器(guard_processing_input)
    --    只放行函数上下文;原来 ctx 在第 6 步(产出)才设,投入腿就会被自己拒掉。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_inbound_id IS NOT NULL THEN
            -- ════════════════════════════════════════════════════════════
            -- PROC-WIRE-1B-i:【直通式不扣库存】
            -- 一炉深度放电结束之后,那批货还在院子里,还是那么多克。
            -- 扣掉它 = 账上把一批还存在的货销掉,而这是那个"只放松 NO_OUTPUTS"
            -- 的实现最先造成的破坏(它会把 remaining_qty 扣到 0)。
            -- **投入腿照记** —— 那是【通过量】,记的是"这批料走过这道工序",
            -- 不是"这批料被吃掉了"。设备用量与工时因此仍然读得到它。
            -- ════════════════════════════════════════════════════════════
            IF v_consumes THEN
                SELECT remaining_qty INTO v_remaining
                FROM inbound_batches WHERE id = v_inbound_id;
                v_new_remaining := v_remaining - v_consumed;

                UPDATE inbound_batches
                SET remaining_qty = v_new_remaining,
                    stage = CASE WHEN v_new_remaining <= 0 THEN '已加工完' ELSE '加工中' END,
                    updated_by = v_user_id,
                    updated_at = now()
                WHERE id = v_inbound_id;

                -- IOD-1:投料走 drain_stock —— 可能跨几个库位桶,于是写出多行(规则见其函数头)
                PERFORM drain_stock(
                    p_qty => v_consumed, p_movement_type => 'processing_consume',
                    p_business_date => v_process_date, p_inbound_batch_id => v_inbound_id,
                    p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);
            END IF;

            INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
            VALUES (v_run_id, v_inbound_id, v_consumed);

            -- ════════════════════════════════════════════════════════════
            -- PROC-WIRE-1B-i:**R3 的"改状态"就落在这里**
            -- 被这道工序【解决掉】的状态从批次上删掉,再写上结果状态。
            -- 不删的话,一批放完电的货会永远带着"未放电",于是下一道工序
            -- 仍然拒绝它 —— 那正是本刀要解的那个死锁,只是换了个位置复发。
            -- ════════════════════════════════════════════════════════════
            IF NOT v_produces AND v_result_state IS NOT NULL THEN
                DELETE FROM inbound_batch_safety_states s
                 WHERE s.inbound_batch_id = v_inbound_id
                   AND s.safety_state_code IN (
                       SELECT a.safety_state_code FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op AND a.resolves);

                INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
                VALUES (v_inbound_id, v_result_state)
                ON CONFLICT (inbound_batch_id, safety_state_code) DO NOTHING;
            END IF;
        ELSE
            -- ════════════════════════════════════════════════════════════
            -- PROC-WIRE-1B-i:【状态改变型工序暂时收不了产出批】,按名拒。
            -- 理由是结构性的,不是策略性的:安全状态今天【只有进料批有】,
            -- 没有 output_batch_safety_states 这张表,所以"把状态改成已放电"
            -- 这件事在产出批上【无处可写】。放它过去会得到一炉什么都没改的
            -- 放电 —— 一次静默的无操作,比拒绝坏得多。
            -- **这张表是 1B-ii 的第一件事(M4 同一张表)。**
            -- ════════════════════════════════════════════════════════════
            IF NOT v_produces THEN
                RAISE EXCEPTION 'STATE_CHANGE_OUTPUT_INPUT_UNSUPPORTED|%', v_op
                  USING HINT = '安全状态目前只有进料批记得下(没有产出批的那张表),所以状态改变型工序暂时只收进料批。这一条等 1B-ii 的 output_batch_safety_states。';
            END IF;
            -- FIN-25:产出批投料。state 是【销售状态】(表注),消耗不碰它 ——
            -- 只扣 remaining_qty,流水挂 output_batch_id(XOR 的另一侧)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches WHERE id = v_output_id;
            v_new_remaining := v_remaining - v_consumed;

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_output_id;

            PERFORM drain_stock(
                p_qty => v_consumed, p_movement_type => 'processing_consume',
                p_business_date => v_process_date, p_output_batch_id => v_output_id,
                p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);

            INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed)
            VALUES (v_run_id, v_output_id, v_consumed);
        END IF;
    END LOOP;

    -- 6. 遍历产出:建产出批次 + 建产出腿
    --    产出的入库流水由 AFTER INSERT 触发器发出;先设置上下文标记本批产出属于本加工单。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_material_id := (v_output->>'material_id')::uuid;
        v_qty         := (v_output->>'quantity')::numeric;
        v_unit        := COALESCE(NULLIF(v_output->>'unit', ''), 'kg');
        v_purity      := NULLIF(v_output->>'purity', '');

        INSERT INTO output_batches (
            material_id, quantity, unit, remaining_qty, output_date, state, purity,
            created_by, updated_by
        ) VALUES (
            v_material_id, v_qty, v_unit, v_qty, v_process_date, '库存中', v_purity,
            v_user_id, v_user_id
        )
        RETURNING id INTO v_new_output_id;

        INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced)
        VALUES (v_run_id, v_new_output_id, v_qty);
    END LOOP;

    -- 用毕即清(price_ctx 同一条理由:免得同事务内后续的直改被误放行 ——
    -- fixture 19F 实测:不清,守卫触发器对残留 ctx 放行裸 INSERT)
    PERFORM set_config('evoltrya.movement_ctx', '', true);

    RETURN v_run_id;
END;
$function$;

-- ═══ 7 · 成本:状态改变型【暂时按名拒绝分摊】 ═══════════════════════════
--
-- ★★ 停下来报告的那一条 —— Tim 的裁定与线上的一条不变式撞上了 ★★
--
-- Tim 裁定:状态改变型工序的成本【资本化回它自己的投料批】。
-- 而线上量到的:**inbound_batches.unit_price 是【应付之锚】** ——
-- 表头原话「应付 = quantity × unit_price,改价即改欠款」,
-- 而 db/views/ap_open_items.sql 是【实时】这么算的:
--     round(ib.quantity * ib.unit_price, 2) - 已结 - 已用定金
-- 也就是说:**把我们自己的电费加到 unit_price 上,会当场增加我们【欠供应商】
-- 的钱。** 供应商没有因为我们放电而多一分债权。
-- 这一列还被 trg_inbound_batches_price_guard 守着,只能经 set_inbound_unit_price
-- 改动,而那条路会写 price_history(一条"改价留痕"的记录)并把耗过它的
-- 加工单标记过期 —— 一条把放电成本写成"重新议价"的假账。
--
-- **所以本刀【不】实现资本化,并且按 Tim 的明令停下来报告。**
-- 需要的是一个【与 unit_price 分开的】成本载体(应付不读它,存货估值读它),
-- 那是新结构 + 一次会计裁定(借方是 1200 还是别的科目),不是本刀顺手能定的。
--
-- 【而本刀必须堵住的是那个【静默】】今天对一张零产出腿的加工单:
--   * 按【价值】基准 → NO_METAL_VALUE(它已经会拒);
--   * 按【重量】基准 → v_total_basis = 0,NULLIF 之后除法得 NULL,
--     **没有腿可更新,于是它什么都不做、还返回成功**。
-- 一次"报告成功却什么都没分摊"的调用,正是本仓库反复付账的那种假绿灯。
-- 于是本刀让它【按名拒绝】,把那个开着的会计问题说出来 —— 记下缺口,不替它作答。
CREATE OR REPLACE FUNCTION public.guard_allocation_not_state_changing(p_run_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE v_op text; v_code text;
BEGIN
    SELECT pr.operation_type_code, pr.code INTO v_op, v_code
      FROM public.processing_runs pr
      JOIN public.operation_types ot ON ot.code = pr.operation_type_code
      JOIN public.operation_kinds k  ON k.code  = ot.kind_code
     WHERE pr.id = p_run_id AND k.produces_outputs IS FALSE;

    IF FOUND THEN
        RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_UNRESOLVED|%|%', v_code, v_op
          USING HINT = '状态改变型工序没有产出腿,所以今天的分摊无处可落。Tim 已裁定成本应资本化回投料批,但 unit_price 是【应付之锚】(改它就是改欠供应商的钱),所以那需要一个与它分开的成本载体 —— 一次会计裁定 + 新结构,记在 docs/proc-operations-wired.md。在那之前这条路【按名拒绝】,而不是静默地什么都不分摊。';
    END IF;
END;
$function$;

-- ═══ 8 · RLS 与授权 ═══════════════════════════════════════════════════════
-- 五张表同形:人人读得到(下拉与路由要用),改要工序编辑权。
-- **没有新增权限码** —— 跑一道工序是加工的事,module.processing.edit 就够。
ALTER TABLE public.operation_kinds ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_kinds select all" ON public.operation_kinds
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.operation_kinds TO authenticated;

ALTER TABLE public.operation_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_types select all" ON public.operation_types
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "operation_types write by permission" ON public.operation_types
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operation_types TO authenticated;

ALTER TABLE public.operation_type_input_forms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_type_input_forms select all" ON public.operation_type_input_forms
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "operation_type_input_forms write by permission" ON public.operation_type_input_forms
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operation_type_input_forms TO authenticated;

ALTER TABLE public.operation_type_output_forms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_type_output_forms select all" ON public.operation_type_output_forms
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "operation_type_output_forms write by permission" ON public.operation_type_output_forms
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operation_type_output_forms TO authenticated;

-- 【这一张的写权限【故意】与其它几张一样,而它值得多说一句】
-- 它是那道【起火】闸的受理清单。给 module.processing.edit 是因为决定
-- "这台机器收什么料"本来就是工序的事;但改它的后果比改一张普通字典重 ——
-- 表注里那条"只许收紧"的不变式,fixture 钉着,改坏了 gate 会红。
ALTER TABLE public.operation_type_safety_states ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_type_safety_states select all" ON public.operation_type_safety_states
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "operation_type_safety_states write by permission" ON public.operation_type_safety_states
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operation_type_safety_states TO authenticated;

-- 把那道拒绝接进分摊路(同签名,CREATE OR REPLACE)
CREATE OR REPLACE FUNCTION public.allocate_processing_costs(p_run_id uuid, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- Cost allocation. Metals with a usable price (deleted_at IS NULL, price_date <= run
-- process_date) contribute to metal value; metals WITHOUT one contribute 0 and are
-- recorded in allocation_snapshot.skipped_metals (the former missing-price hard error is gone).
-- NO_METAL_VALUE still blocks when the total metal value across all legs is 0.
-- (Phase 1 follow-up 1, 2026-07-03.)
-- cut 2a (2026-07-06): 10a 资本化分录(借 1220 / 贷 1200 材料 + 贷 5xxx 费用;
-- 重分摊 = 冲旧 + 重挂);10b 给无 COGS 的既有销售按原 sale_date 补挂 COGS。
DECLARE
    v_user                 uuid := auth.uid();
    v_run                  processing_runs%ROWTYPE;
    v_basis                text;
    v_process_date         date;
    v_material             numeric;
    v_process              numeric;
    v_total                numeric;
    v_inputs_without_price integer;
    v_total_basis          numeric;
    v_total_metal_value    numeric;
    v_bad_code             text;
    v_bad_metal            text;
    v_prices_used          jsonb;
    v_default_index        text;
    v_skipped_metals       jsonb;
    v_outputs              jsonb;
    v_sum_alloc            numeric;
    v_snapshot             jsonb;
    v_ct                   record;
    v_sale                 record;
    v_cap_lines            jsonb;
    v_cap_total            numeric;
    v_cap_je               jsonb;
    v_cap_entry_id         uuid;
    v_cogs                 numeric;
    v_cogs_je              jsonb;
    -- FIN-24:差额法用
    v_prior                jsonb;      -- 分摊前各产出腿的 allocated(差额的"已记录"侧)
    v_rec_src              jsonb;      -- 已记录的各来源(material / 各 cost_type)
    v_rec_total            numeric;
    v_by_source            jsonb;      -- 本次各来源(写进 snapshot,下次的"已记录")
    v_delta                numeric;
    v_leg                  record;
    v_d1220                numeric := 0;
    v_d5000                numeric := 0;
    v_d5200                numeric := 0;
    v_l1220                numeric;
    v_l5000                numeric;
    v_other                numeric;
    v_cred_total           numeric := 0;
    v_deb_total            numeric;
    v_cap_status           text;
    -- FIN-25:再加工
    v_material_in          numeric;   -- 进料批投料(→ 1200)
    v_material_re          numeric;   -- 产出批投料(→ 1220 解除上游)
    v_upstream_incomplete  boolean;
    v_re_without_price     integer;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- 1. Lock the run; must exist and be a live committed run.
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;
    IF v_run.deleted_at IS NOT NULL OR v_run.status <> 'committed' THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.status;
    END IF;

    -- PROC-WIRE-1B-i:状态改变型工序没有产出腿,分摊无处可落。
    -- **按名拒绝,而不是静默地什么都不分摊** —— 按重量基准时 v_total_basis = 0,
    -- 除法得 NULL、没有腿可更新,于是它会报告成功却一分钱都没挂上。
    -- Tim 已裁定成本应资本化回投料批;那条路被【应付之锚】挡住(见守卫的 HINT
    -- 与 docs/proc-operations-wired.md),所以这里先把静默堵上。
    PERFORM public.guard_allocation_not_state_changing(p_run_id);

    -- 2. Resolve + validate basis.
    v_basis := COALESCE(p_basis, v_run.allocation_basis);
    IF v_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', v_basis;
    END IF;
    v_process_date := v_run.process_date;

    -- 3. Unit guard: all math assumes kg.
    SELECT ib.code INTO v_bad_code
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id AND ib.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    SELECT ob.code INTO v_bad_code
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id AND ob.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    -- 4. Material cost(FIN-25 起两路):进料批按 inbound.unit_price;产出批
    --    (再加工)按上游 processing_outputs.unit_cost_base。NULL 价照旧计 0 并
    --    计数 —— 【允许,不拒绝】:车间按天走,财务分摊按月走,拒绝会让车间等
    --    财务。零不静默:cost_incomplete 标记打在本单产出上,逐级传染(见 9c),
    --    上游补分摊后本单过期,重跑即修复。
    -- FRT-1:材料成本 = 【落地成本】,不只是单价 —— 单价 + 分摊到该批的单位运费。
    -- 运费资本化进批次之后,这里若仍只读 unit_price,运费就停在 1200/5000,
    -- 永远走不到产出批的 unit_cost_base,batch_margin 会继续停在运费之前的那个数
    -- (而运费那张分录本身完全正确)。这正是"资本化的错误藏在存货里"最具体的一种。
    SELECT COALESCE(SUM(pi.quantity_consumed
             * (COALESCE(ib.unit_price, 0)
                + CASE WHEN ib.quantity > 0 THEN batch_freight_base(ib.id) / ib.quantity ELSE 0 END)), 0),
           COUNT(*) FILTER (WHERE ib.unit_price IS NULL)
      INTO v_material_in, v_inputs_without_price
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id;

    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(po_up.unit_cost_base, 0)), 0),
           COUNT(*) FILTER (WHERE po_up.unit_cost_base IS NULL),
           COALESCE(bool_or(po_up.unit_cost_base IS NULL OR po_up.cost_incomplete), false)
      INTO v_material_re, v_re_without_price, v_upstream_incomplete
    FROM processing_inputs pi
    JOIN processing_outputs po_up ON po_up.output_batch_id = pi.output_batch_id
    WHERE pi.run_id = p_run_id;
    v_inputs_without_price := v_inputs_without_price + COALESCE(v_re_without_price, 0);
    v_material := v_material_in + v_material_re;

    -- 5. Process cost = Σ live cost entries.
    SELECT COALESCE(SUM(amount_base), 0) INTO v_process
    FROM processing_cost_entries
    WHERE run_id = p_run_id AND deleted_at IS NULL;

    -- 6. Total.
    v_total := v_material + v_process;

    -- 7. Basis totals. Metals without a usable price contribute 0 (LEFT JOIN + COALESCE)
    --    and are recorded in skipped_metals; only a zero grand total blocks (NO_METAL_VALUE).
    IF v_basis = 'metal_value' THEN
        -- METAL-2:分摊【没有交易可以继承指数】—— 一张加工单不是一笔谈定的买卖,
        -- 没有对手方、没有条款,所以它按 pricing_settings 的房屋约定取价。
        -- 【这是默认值在替一条缺席的条款站位,不是"这批成本按某个声明的指数结算了"】。
        -- 快照里一并记下用的是哪个指数,免得日后有人把它读成一条谈定的条款。
        SELECT default_metal_index INTO v_default_index FROM pricing_settings WHERE id;

        SELECT COALESCE(SUM(
                 po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0)
               ), 0)
          INTO v_total_metal_value
        FROM processing_outputs po
        JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
        LEFT JOIN LATERAL (
            SELECT mp.price_usd_per_tonne
            FROM metal_prices mp
            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.price_date <= v_process_date
            ORDER BY mp.price_date DESC
            LIMIT 1
        ) pr ON true
        WHERE po.run_id = p_run_id;

        IF COALESCE(v_total_metal_value, 0) = 0 THEN
            RAISE EXCEPTION 'NO_METAL_VALUE';
        END IF;

        v_total_basis := v_total_metal_value;

        SELECT COALESCE(jsonb_agg(
                   jsonb_build_object('metal', metal,
                                      'price_usd_per_tonne', price_usd_per_tonne,
                                      'price_date', price_date)
                   ORDER BY metal), '[]'::jsonb)
          INTO v_prices_used
        FROM (
            SELECT DISTINCT ON (mp.metal) mp.metal, mp.price_usd_per_tonne, mp.price_date
            FROM metal_prices mp
            WHERE mp.deleted_at IS NULL AND mp.price_date <= v_process_date
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.metal IN (
                  SELECT DISTINCT obm.metal
                  FROM processing_outputs po
                  JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
                  WHERE po.run_id = p_run_id AND obm.content_pct > 0
              )
            ORDER BY mp.metal, mp.price_date DESC
        ) q;

        -- Metals present (content > 0) on this run with NO usable price row: excluded from
        -- value (they contributed 0 above) and reported in the snapshot as skipped.
        SELECT COALESCE(jsonb_agg(m ORDER BY m), '[]'::jsonb)
          INTO v_skipped_metals
        FROM (
            SELECT DISTINCT obm.metal AS m
            FROM processing_outputs po
            JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
            WHERE po.run_id = p_run_id AND obm.content_pct > 0
              AND NOT EXISTS (
                  SELECT 1 FROM metal_prices mp
                  WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                    AND mp.price_date <= v_process_date
              )
        ) s;
    ELSE
        SELECT COALESCE(SUM(quantity_produced), 0) INTO v_total_basis
        FROM processing_outputs WHERE run_id = p_run_id;
        v_total_metal_value := NULL;
        v_prices_used := '[]'::jsonb;
        v_skipped_metals := '[]'::jsonb;
    END IF;

    -- FIN-24:差额法的"已记录"侧 —— 在下面的 UPDATE 改写之前,把各产出腿
    -- 当前的 allocated 拍下来。目标 − 已记录 = 应过账的差额(与重估/折旧同形)。
    SELECT COALESCE(jsonb_object_agg(po.output_batch_id::text,
                    COALESCE(po.allocated_cost_base, 0)), '{}'::jsonb)
      INTO v_prior
    FROM processing_outputs po WHERE po.run_id = p_run_id;

    -- 8 + 9. Allocate (largest-share row absorbs the rounding remainder), persist legs,
    --        and collect the per-output result — all in one statement.
    WITH legs AS (
        SELECT po.id AS leg_id, po.output_batch_id, po.quantity_produced,
               CASE WHEN v_basis = 'weight' THEN po.quantity_produced::numeric
                    ELSE COALESCE((
                        SELECT SUM(po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0))
                        FROM output_batch_metals obm
                        LEFT JOIN LATERAL (
                            SELECT mp.price_usd_per_tonne
                            FROM metal_prices mp
                            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                              AND mp.price_date <= v_process_date
                            ORDER BY mp.price_date DESC
                            LIMIT 1
                        ) pr ON true
                        WHERE obm.output_batch_id = po.output_batch_id
                    ), 0)
               END AS basis_value
        FROM processing_outputs po
        WHERE po.run_id = p_run_id
    ),
    calc AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               round(v_total * basis_value / NULLIF(v_total_basis, 0), 2) AS alloc_raw,
               row_number() OVER (ORDER BY basis_value DESC, leg_id) AS rn
        FROM legs
    ),
    adj AS (
        SELECT c.*, (round(v_total, 2) - SUM(alloc_raw) OVER ()) AS remainder
        FROM calc c
    ),
    final AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               alloc_raw + CASE WHEN rn = 1 THEN remainder ELSE 0 END AS allocated
        FROM adj
    ),
    upd AS (
        UPDATE processing_outputs po
        SET allocated_cost_base = f.allocated,
            unit_cost_base = round(f.allocated / f.quantity_produced, 4)
        FROM final f
        WHERE po.id = f.leg_id
        RETURNING f.output_batch_id, f.basis_value, f.allocated, po.unit_cost_base
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   'output_batch_id', output_batch_id,
                   'share', round(basis_value / NULLIF(v_total_basis, 0), 6),
                   'allocated_cost_base', allocated,
                   'unit_cost_base', unit_cost_base)
               ORDER BY output_batch_id),
           COALESCE(SUM(allocated), 0)
      INTO v_outputs, v_sum_alloc
    FROM upd;

    -- 9b. Snapshot + run header.
    -- FIN-24:by_source = 本次各来源的入账口径(材料 + 逐 cost_type,各 2 位),
    -- 下一次差额跑的"已记录"就从这里读 —— recorded,不再从分录反推。
    v_by_source := jsonb_build_object('material', round(v_material_in, 2));
    IF round(v_material_re, 2) <> 0 THEN
        -- 再加工材料单列一源:首挂贷 1220(解除上游产出),差额与 material 同贷 5000
        v_by_source := v_by_source || jsonb_build_object('material_reprocessed', round(v_material_re, 2));
    END IF;
    FOR v_ct IN
        SELECT cost_type, round(sum(amount_base), 2) AS amt
        FROM processing_cost_entries
        WHERE run_id = p_run_id AND deleted_at IS NULL
        GROUP BY cost_type
    LOOP
        v_by_source := v_by_source || jsonb_build_object(v_ct.cost_type, v_ct.amt);
    END LOOP;

    v_snapshot := jsonb_build_object(
        'capitalized_by_source', v_by_source,
        'basis', v_basis,
        'computed_at', now(),
        'inputs_without_price', v_inputs_without_price,
        'total_output_metal_value_usd',
            CASE WHEN v_basis = 'metal_value' THEN round(v_total_metal_value, 2) ELSE NULL END,
        'prices_used', v_prices_used,
        -- METAL-2:用的是哪个指数,以及它【是房屋约定而不是条款】。
        -- 读快照的人必须能分清这两件事:这批成本不是"按 LME 结算"的,
        -- 它是"在没有条款可循时,按当时的房屋约定取了 LME 的价"。
        'price_index', v_default_index,
        'price_index_is_house_default', true,
        'skipped_metals', v_skipped_metals
    );

    -- 9c(FIN-25):不完整成本标记 —— 任何投料无价、或上游产出自己就带着标记,
    --    本单全部产出打上 cost_incomplete。零永不静默,层层传染;上游补分摊后
    --    本单过期(状态视图第三支),重跑即清。
    UPDATE processing_outputs
    SET cost_incomplete = (v_inputs_without_price > 0 OR v_upstream_incomplete)
    WHERE run_id = p_run_id;

    -- FIN-36c:告诉基准触发器"这次基准变动是【跟着重分摊一起发生的】,不是漂移"。
    -- 与年结用 evoltrya.close_ctx 穿过期间锁是同一个惯用法(post_journal_entry)。
    -- 【为什么不靠时间戳判断】now() 是事务时间:同一个事务里两次分摊拿到相同的
    -- allocated_at,任何"看 allocated_at 变没变"的判据都会失效(fixture 就在一个
    -- 事务里跑)。显式的上下文标记不受事务边界影响。
    PERFORM set_config('evoltrya.alloc_ctx', '1', true);

    UPDATE processing_runs
    SET material_cost_base   = round(v_material, 2),
        process_cost_base    = round(v_process, 2),
        total_cost_base      = round(v_total, 2),
        allocation_basis    = v_basis,
        allocation_snapshot = v_snapshot,
        allocated_at        = now(),
        allocated_by        = v_user,
        updated_at          = now(),
        updated_by          = v_user
    WHERE id = p_run_id;

    -- 标记只覆盖上面那一条 UPDATE:同一事务里【之后】的裸改基准仍算漂移
    PERFORM set_config('evoltrya.alloc_ctx', '', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- 10a.【FIN-24:首挂全额,此后差额 —— 不再全额冲销重挂】
    -- 旧实现重述资本化(1220 按新价整体改写)而已过账 COGS 从不重述:卖掉份额的
    -- 价差留在库存里,卖得越多错得越多;材料价差贷 1200,而 reprice 早把已耗份额
    -- 记进了 5000 —— 两处叠加 = 重复计数 + 1200 变负(实测:100kg@1 全耗、重定价
    -- 到 2、重分摊 → 1220=200 但 5000 多挂 100、1200=−100)。
    -- 差额法(与重估/折旧同形):目标 − 已记录,只过差额,第二次跑为零。
    --   * 每个产出批按【自己】的处置比例拆(Part B:一炉多批、各卖各的):
    --       在库 + 已售未挂COGS → 1220(后者价值仍躺在 1220,10b 随后按新单位成本解除)
    --       已售已挂COGS       → 5000(COGS 补差)
    --       注销/盘亏           → 5200(处置在产出粒度可知,注销总额是运营信号,
    --                              不并进材料成本 —— Tim 的裁定,推翻了与 reprice
    --                              一致性的论证;reprice 在进料粒度分不出注销与
    --                              耗用、整体进 5000 的不精确,另记 known-issues)
    --   * 贷方:材料差额 → 5000(reprice 把已耗价差停在那里;5000 同时是 COGS
    --     科目,已售份额的借方与之同户恰好互抵 —— 这一巧合是本设计的支点);
    --     费用差额 → 各自成本科目(fin_cost_account)。
    --   * 产出批喂回再加工在 schema 上【不可表示】(processing_inputs 只指
    --     inbound_batches)—— 处置只有在库/已售/注销三种。粉线大概率多段加工,
    --     真建了再加工必须先扩这套拆分(known-issues 有账)。
    -- ════════════════════════════════════════════════════════════════════════
    v_rec_total := COALESCE(v_run.capitalized_cost_base, 0);
    IF v_run.capitalization_entry_id IS NOT NULL THEN
        SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_run.capitalization_entry_id;
        IF v_cap_status <> 'posted' THEN
            -- 资本化分录被人工冲销:存量"已记录"与总账已分道,差额法的基准不再可信。
            -- 这是【唯一】剩下的红色情形:人工冲销是人做的决定,修复也该是人工分录。
            RAISE EXCEPTION 'ALLOCATION_LEDGER_DIVERGED|%', v_run.code;
        END IF;
    END IF;

    IF v_run.capitalization_entry_id IS NULL THEN
        -- ── 首挂:全额资本化(原路径)────────────────────────────────────────
        v_cap_lines := '[]'::jsonb;
        v_cap_total := 0;
        IF round(v_material_in, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_in, 2));
            v_cap_total := v_cap_total + round(v_material_in, 2);
        END IF;
        -- FIN-25:再加工材料 —— 解除的是上游产出的 1220,不是原料的 1200。
        -- 同科目 Dr(资本化进本单产出)/Cr(解除上游)两腿并存,净额即增量。
        IF round(v_material_re, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_re, 2), 'line_memo', 're-processed input relieved');
            v_cap_total := v_cap_total + round(v_material_re, 2);
        END IF;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
            FROM processing_cost_entries
            WHERE run_id = p_run_id AND deleted_at IS NULL
            GROUP BY cost_type
            ORDER BY cost_type
        LOOP
            IF v_ct.amt > 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            ELSIF v_ct.amt < 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', -v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            END IF;
        END LOOP;

        v_cap_entry_id := NULL;
        IF v_cap_total <> 0 THEN
            v_cap_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1220',
                                   'side', CASE WHEN v_cap_total > 0 THEN 'debit' ELSE 'credit' END,
                                   'currency', base_currency_code(), 'amount_ccy', abs(v_cap_total))
            ) || v_cap_lines;
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Capitalize ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = v_cap_total,
            capitalization_entry_id = v_cap_entry_id
        WHERE id = p_run_id;
    ELSE
        -- ── 差额路径 ─────────────────────────────────────────────────────────
        -- 已记录的各来源:优先 snapshot(FIN-24 起写入);老单从已过账的资本化
        -- 分录行反推 —— 1200 行 = 材料,5xxx 行按 fin_cost_account 的反向映射。
        v_rec_src := v_run.allocation_snapshot->'capitalized_by_source';
        IF v_rec_src IS NULL THEN
            SELECT COALESCE(jsonb_object_agg(q.src, q.amt), '{}'::jsonb) INTO v_rec_src FROM (
                SELECT CASE a.code
                           WHEN '1200' THEN 'material'
                           WHEN '5100' THEN 'labour'
                           WHEN '5110' THEN 'electricity'
                           WHEN '5120' THEN 'gas'
                           WHEN '5130' THEN 'depreciation'
                           WHEN '5140' THEN 'consumables'
                           WHEN '5150' THEN 'waste_treatment'
                           WHEN '5190' THEN 'other'
                       END AS src,
                       round(SUM(jl.credit) - SUM(jl.debit), 2) AS amt
                FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
                WHERE jl.entry_id = v_run.capitalization_entry_id AND a.code <> '1220'
                GROUP BY a.code) q
            WHERE q.src IS NOT NULL;
        END IF;

        -- 贷方:逐来源差额。材料 → 5000(不是 1200!—— reprice 已把已耗价差记在
        -- 5000,这里把属于未售产出的部分从 5000 拨进 1220,双方不再叠加);
        -- 费用 → 各自成本科目。负差翻借方。
        v_cap_lines := '[]'::jsonb;
        v_cred_total := 0;
        FOR v_ct IN
            SELECT key AS src, (v_by_source->>key)::numeric - COALESCE((v_rec_src->>key)::numeric, 0) AS d
            FROM jsonb_object_keys(v_by_source) AS key
            UNION
            SELECT key, 0 - (v_rec_src->>key)::numeric
            FROM jsonb_object_keys(v_rec_src) AS key
            WHERE v_by_source->>key IS NULL
            ORDER BY 1
        LOOP
            IF v_ct.d <> 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object(
                    'account_code', CASE WHEN v_ct.src IN ('material', 'material_reprocessed') THEN '5000' ELSE fin_cost_account(v_ct.src) END,
                    'side', CASE WHEN v_ct.d > 0 THEN 'credit' ELSE 'debit' END,
                    'currency', base_currency_code(), 'amount_ccy', abs(v_ct.d),
                    'line_memo', 'allocation delta: ' || v_ct.src);
                v_cred_total := v_cred_total + v_ct.d;
            END IF;
        END LOOP;

        -- 借方:逐产出批的差额,按该批自己的处置比例拆
        FOR v_leg IN
            SELECT po.output_batch_id, po.quantity_produced AS qty,
                   po.allocated_cost_base AS new_alloc,
                   COALESCE((v_prior->>po.output_batch_id::text)::numeric, 0) AS old_alloc,
                   ob.remaining_qty,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NOT NULL), 0) AS sold_cogs,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NULL), 0) AS sold_nocogs,
                   -- FIN-25 第四处置:被下游加工消耗的份额 → 5000 停车
                   --(与 reprice 对已耗进料完全同构:下游过期后重跑,其材料差额
                   -- 贷 5000 收回停车 —— 传导靠既有过期旗逐级走,不递归)
                   COALESCE((SELECT SUM(pi2.quantity_consumed) FROM processing_inputs pi2
                             WHERE pi2.output_batch_id = po.output_batch_id), 0) AS consumed_proc
            FROM processing_outputs po
            JOIN output_batches ob ON ob.id = po.output_batch_id
            WHERE po.run_id = p_run_id
        LOOP
            v_delta := round(v_leg.new_alloc - v_leg.old_alloc, 2);
            IF v_delta = 0 OR v_leg.qty = 0 THEN CONTINUE; END IF;
            v_other := GREATEST(0, v_leg.qty - v_leg.remaining_qty - v_leg.sold_cogs - v_leg.sold_nocogs - v_leg.consumed_proc);
            v_l1220 := round(v_delta * (v_leg.remaining_qty + v_leg.sold_nocogs) / v_leg.qty, 2);
            v_l5000 := round(v_delta * (v_leg.sold_cogs + v_leg.consumed_proc) / v_leg.qty, 2);
            -- 5200 取残差,保证三桶之和恰等于该批差额
            v_d1220 := v_d1220 + v_l1220;
            v_d5000 := v_d5000 + v_l5000;
            v_d5200 := v_d5200 + (v_delta - v_l1220 - v_l5000);
        END LOOP;

        -- 强制配平:Σ借(三桶)与 Σ贷(逐来源)各自取整后可差一两分 ——
        -- 差额并进 1220 桶(金额最大、且是"目标状态"侧,与 8+9 步的
        -- largest-share-absorbs 同一习惯)。
        v_deb_total := v_d1220 + v_d5000 + v_d5200;
        v_d1220 := v_d1220 + round(v_cred_total - v_deb_total, 2);

        IF v_d1220 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '1220',
                'side', CASE WHEN v_d1220 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d1220),
                'line_memo', 'in-stock share')) || v_cap_lines;
        END IF;
        IF v_d5000 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5000',
                'side', CASE WHEN v_d5000 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5000),
                'line_memo', 'sold/consumed share — COGS catch-up / re-processing park')) || v_cap_lines;
        END IF;
        IF v_d5200 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5200',
                'side', CASE WHEN v_d5200 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5200),
                'line_memo', 'written-off share')) || v_cap_lines;
        END IF;

        -- 幂等出口:没有任何差额 → 不过账(allocated_at 照常刷新,过期标记消除)
        IF jsonb_array_length(v_cap_lines) > 0 THEN
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Re-allocation delta ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            -- 差额分录记进 snapshot 的留痕数组;capitalization_entry_id 仍指首挂
            v_snapshot := v_snapshot || jsonb_build_object('delta_entry_ids',
                COALESCE(v_run.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)
                    || to_jsonb((v_cap_je->>'entry_id')::text));
            UPDATE processing_runs SET allocation_snapshot = v_snapshot WHERE id = p_run_id;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = round(v_rec_total + v_cred_total, 2)
        WHERE id = p_run_id;
    END IF;

    -- 10b. cut 2a:COGS 补挂 —— 只补此前无 COGS 分录的销售(cogs_entry_id IS NULL),
    --      用最新 unit_cost_base,按各自原 sale_date(撞期间锁则 PERIOD_LOCKED 直接抛出)。
    --      已挂 COGS 不追溯重述(标准成本式简化;重述属人工冲销决策)。
    FOR v_sale IN
        SELECT sr.id, sr.quantity, sr.sale_date, ob.code AS batch_code, po.unit_cost_base
        FROM sales_records sr
        JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = p_run_id
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        WHERE sr.cogs_entry_id IS NULL
        ORDER BY sr.sale_date, sr.created_at
    LOOP
        v_cogs := round(v_sale.quantity * v_sale.unit_cost_base, 2);
        IF v_cogs <> 0 THEN
            v_cogs_je := post_journal_entry(
                v_sale.sale_date,
                'COGS ' || v_sale.batch_code,
                'sale', v_sale.id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_cogs_je->>'entry_id')::uuid WHERE id = v_sale.id;
        END IF;
    END LOOP;

    -- 10. Return.
    RETURN jsonb_build_object(
        'run_id', p_run_id,
        'basis', v_basis,
        'material_cost_base', round(v_material, 2),
        'process_cost_base', round(v_process, 2),
        'total_cost_base', round(v_total, 2),
        'inputs_without_price', v_inputs_without_price,
        'outputs', COALESCE(v_outputs, '[]'::jsonb)
    );
END;
$function$;

COMMIT;
