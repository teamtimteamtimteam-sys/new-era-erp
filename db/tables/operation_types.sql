-- db/tables/operation_types.sql
-- PROC-WIRE-1B-i:一道【工序】(R2 的五道,一台机器一道)。RUNTIME CONFIG。
-- NOTE: introduced by db/migrations/2026-08-31-procwire1bi-operations-wired-and-the-discharge-deadlock.sql.
-- First-run script (plain CREATEs).

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
    notes                       text,
    -- ── MES-4a 追加的列(2026-10-07,规格 §4.1;MES-0 Q46 · Q47;MES-4a Step 0 Q18,Tim)──────────
    -- 这道工序一炉的物料平衡允许多大的余数(投入的百分比)。为空 = Not yet set(V1,Tim 与 cto 在每一段调试结束时给)——
    -- 没给的时候,任何不为零的余数都要一句书面说明才能结平(Q46);给了,超出它的也要(Q47)。结平时抄进那一行。
    balance_tolerance_pct       numeric CHECK (balance_tolerance_pct IS NULL OR balance_tolerance_pct >= 0),
    -- ── MES-4b 追加的列(2026-10-07,规格 §3.4;MES-0 Q45 · Q51 · V10;MES-4b Step 0 Q5 · Q17,Tim)─────────────
    -- V10:这一段一炉的电解液占投入质量的百分比 —— 算出来的电解液损耗 = 它 × 投入 / 100。为空 = Not yet set。
    electrolyte_share_pct       numeric CHECK (electrolyte_share_pct IS NULL OR (electrolyte_share_pct >= 0 AND electrolyte_share_pct <= 100)),
    -- 「Electrolyte evaporates in this step」—— 标的是【损耗发生在哪一段】,不是压缩机装在哪(Tim 的工厂事实,Q17)。
    -- 引导【全部为假】:哪几段挥发由 Tim 自己在工序页上勾(module.processing.edit)。
    electrolyte_loss_applies    boolean NOT NULL DEFAULT false,
    -- 这一段的投料批必须带一个确定的电芯结构(卷绕 / 叠片)—— 规格 §3.4:两种结构走两台分离设备。引导:electrode_separation · electrode_line。
    requires_cell_construction  boolean NOT NULL DEFAULT false
);

COMMENT ON COLUMN public.operation_types.balance_tolerance_pct IS
    'MES-4a(规格 §4.1 · MES-0 Q46 · Q47):这道工序一炉物料平衡允许的余数,投入的百分比。为空 = Not yet set(V1)—— 不是 0:没给的时候任何不为零的余数都要书面说明。结平时抄进 processing_run_closures.tolerance_pct。只对转化型有意义(状态改变型投入恒等于产出)。';

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
    ('electrode_line', 'Automatic foil separating line', '自动极片线', 'transforming', NULL, 3,
     '【R2】电芯 → 壳体 / 正极片 / 负极片 / 隔膜。**开壳与极片分离是【一道】工序**(R2 明写),不是两道。【R4:电解液在这里挥发】—— 它不是产出形态,它是一个损耗类别(loss_categories.electrolyte_evaporation),所以它【不在】本工序的产出形态里。
【TIDY-1(2026-09-01):code 与英文名【故意】对不上】英文名按行业叫法从 “Automatic electrode line” 改成 “Automatic foil separating line”,而 code 仍是 electrode_line。**Tim 的裁定:改 code 会波及每一处引用,改一个显示标签不该波及任何东西。**所以这个错位是一次【决定】,不是没人来得及改。中文名(自动极片线)一直是对的,未动。'),
    ('electrode_powder_line', 'Foil processing line', '极片粉料线', 'transforming', NULL, 4,
     '【R2】极片 → 黑粉。
【TIDY-1(2026-09-01):code 与英文名【故意】对不上】英文名按行业叫法从 “Electrode powder line” 改成 “Foil processing line”,而 code 仍是 electrode_powder_line。**Tim 的裁定:改 code 会波及每一处引用,改一个显示标签不该波及任何东西。**所以这个错位是一次【决定】,不是没人来得及改。中文名(极片粉料线)一直是对的,未动。'),
    ('battery_powder_line', 'Battery processing line', '整电池粉料线', 'transforming', NULL, 5,
     '【R2】**不同的设备**,专收放不了电的整包/模组/3C 电池/损坏电池。它与极片粉料线是两道工序,理由就是"一台机器一道工序"。
【TIDY-1(2026-09-01):code 与英文名【故意】对不上】英文名按行业叫法从 “Battery powder line” 改成 “Battery processing line”,而 code 仍是 battery_powder_line。**Tim 的裁定:改 code 会波及每一处引用,改一个显示标签不该波及任何东西。**所以这个错位是一次【决定】,不是没人来得及改。中文名(整电池粉料线)一直是对的,未动。'),
    -- ── MES-4a(2026-10-07,MES-0 Q37;MES-4a Step 0 Q3,Tim):规格书把开壳与极片分离写成【两段、两台设备】(§3.3 · §3.4)。
    --   electrode_line(两段合在一台机器上)照旧留着 —— 买哪一种机器是 Tim 的事,换的是配置,不是代码。
    ('casing_removal', 'Casing removal', '开壳', 'transforming', NULL, 6,
     '【MES-4a · 规格 §3.3】电芯 → 已开壳电芯 + 壳体。硬壳与软包是两台设备;先分类(分类本身是一条记录)。只受理已放电并核实的料。'),
    ('electrode_separation', 'Electrode separation', '极片分离', 'transforming', NULL, 7,
     '【MES-4a · 规格 §3.4】已开壳电芯 → 正极片 / 负极片 / 隔膜(三路分开称)。卷绕与叠片是两台设备。电解液在这一段挥发或回收 —— 它是一个损耗类别,不是产出形态。只受理已放电并核实的料。');

-- MES-4b(Step 0 Q5):分极片的两道工序要求投料带确定的电芯结构。是一个标志,不是函数里的一张码表。
UPDATE public.operation_types SET requires_cell_construction = true WHERE code IN ('electrode_separation', 'electrode_line');

COMMENT ON COLUMN public.operation_types.electrolyte_share_pct IS
    'MES-4b(V10;MES-0 Q51;MES-4b Step 0 Q17):这一段一炉电解液占投入质量的百分比(0–100)。为空 = Not yet set(电芯供应商的规格书 / 工艺工程师给,第一批极片分离之前)。只在 electrolyte_loss_applies 为真的工序上有意义:算出来的电解液损耗 = 份额 × total_input / 100(record_derived_electrolyte_loss),份额抄进那一行。';
COMMENT ON COLUMN public.operation_types.electrolyte_loss_applies IS
    'MES-4b(Tim 的工厂事实,Step 0 Q17):「Electrolyte evaporates in this step」—— 这一段有电解液挥发。它标的是损耗【发生】在哪一段,不是压缩机装在哪(压缩机是设备,不是工序)。引导全部为假,Tim 在工序页上自己勾。为真才可以记一笔算出来的电解液损耗;V10 只列为真而份额为空的工序。';
COMMENT ON COLUMN public.operation_types.requires_cell_construction IS
    'MES-4b(规格 §3.4;MES-0 Q45;MES-4b Step 0 Q5):这一段的每一批投料都必须带一个确定的电芯结构(cell_constructions.is_determined)—— 空或 unknown → INPUT_CELL_CONSTRUCTION_REQUIRED|<批号>。引导:electrode_separation 与 electrode_line。结构 ↔ 机器只记录、不校验(Q8)。';

ALTER TABLE public.operation_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_types select all" ON public.operation_types
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "operation_types write by permission" ON public.operation_types
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operation_types TO authenticated;

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.operation_types
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
