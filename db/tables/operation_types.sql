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
    ('electrode_line', 'Automatic foil separating line', '自动极片线', 'transforming', NULL, 3,
     '【R2】电芯 → 壳体 / 正极片 / 负极片 / 隔膜。**开壳与极片分离是【一道】工序**(R2 明写),不是两道。【R4:电解液在这里挥发】—— 它不是产出形态,它是一个损耗类别(loss_categories.electrolyte_evaporation),所以它【不在】本工序的产出形态里。
【TIDY-1(2026-09-01):code 与英文名【故意】对不上】英文名按行业叫法从 “Automatic electrode line” 改成 “Automatic foil separating line”,而 code 仍是 electrode_line。**Tim 的裁定:改 code 会波及每一处引用,改一个显示标签不该波及任何东西。**所以这个错位是一次【决定】,不是没人来得及改。中文名(自动极片线)一直是对的,未动。'),
    ('electrode_powder_line', 'Foil processing line', '极片粉料线', 'transforming', NULL, 4,
     '【R2】极片 → 黑粉。
【TIDY-1(2026-09-01):code 与英文名【故意】对不上】英文名按行业叫法从 “Electrode powder line” 改成 “Foil processing line”,而 code 仍是 electrode_powder_line。**Tim 的裁定:改 code 会波及每一处引用,改一个显示标签不该波及任何东西。**所以这个错位是一次【决定】,不是没人来得及改。中文名(极片粉料线)一直是对的,未动。'),
    ('battery_powder_line', 'Battery processing line', '整电池粉料线', 'transforming', NULL, 5,
     '【R2】**不同的设备**,专收放不了电的整包/模组/3C 电池/损坏电池。它与极片粉料线是两道工序,理由就是"一台机器一道工序"。
【TIDY-1(2026-09-01):code 与英文名【故意】对不上】英文名按行业叫法从 “Battery powder line” 改成 “Battery processing line”,而 code 仍是 battery_powder_line。**Tim 的裁定:改 code 会波及每一处引用,改一个显示标签不该波及任何东西。**所以这个错位是一次【决定】,不是没人来得及改。中文名(整电池粉料线)一直是对的,未动。');

ALTER TABLE public.operation_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_types select all" ON public.operation_types
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "operation_types write by permission" ON public.operation_types
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operation_types TO authenticated;
