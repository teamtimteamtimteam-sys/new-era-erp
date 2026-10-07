-- db/tables/operation_type_fields.sql
-- MES-4a(2026-10-07,MES-0 Q43 · MES-4a Step 0 Q10 · Q13,Tim):【一道工序记哪些参数与指标】—— 配置是数据,不是固定的列。
--   一行 = 某道工序上的一个字段:kind(parameter = 这一炉用的设定 · indicator = 这一炉出来的结果)、value_type(number · count · text · yes_no)、
--   单位、要不要必填(必填在【结平】时判,不在提交时判 —— Q11)、有没有范围(has_range;范围上下限为空 = Not yet set,V36)。
--   【退役,不删】一个字段一旦存在,它就可能有值;删掉它会让旧值失去意思。所以没有 DELETE(OPERATION_FIELD_RETIRE_NOT_DELETE),
--   停用就是 is_active = false;用上之后它的 kind / value_type / unit 也不许改(OPERATION_FIELD_IN_USE)—— 改了,旧值就换了意思。
--   【引导】规格书点名的那些计数与指标(Q13):全部不必填、全部没有范围。要必填、要范围,是 Tim 以后在工序页上的设定,不是改码。
--   RUNTIME CONFIG(加一个字段是加一行)。读:module.processing.view;写:module.processing.edit。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.operation_type_fields (
    operation_type_code text NOT NULL REFERENCES public.operation_types (code),
    field_code          text NOT NULL CHECK (field_code ~ '^[a-z][a-z0-9_]*$'),
    name_en             text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh             text NOT NULL CHECK (btrim(name_zh) <> ''),
    kind                text NOT NULL CHECK (kind IN ('parameter', 'indicator')),
    value_type          text NOT NULL CHECK (value_type IN ('number', 'count', 'text', 'yes_no')),
    unit                text,
    is_required         boolean NOT NULL DEFAULT false,
    has_range           boolean NOT NULL DEFAULT false,
    range_min           numeric,
    range_max           numeric,
    is_active           boolean NOT NULL DEFAULT true,
    sort_order          integer NOT NULL DEFAULT 0,
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid DEFAULT auth.uid(),
    PRIMARY KEY (operation_type_code, field_code),
    -- 范围只对数(number · count)有意思;没声明有范围的字段,上下限必须是空的 —— 空的意思由 has_range 回答,不靠读的人猜
    CONSTRAINT operation_type_fields_range_shape
        CHECK ((has_range OR (range_min IS NULL AND range_max IS NULL))
               AND (NOT has_range OR value_type IN ('number', 'count'))
               AND (range_min IS NULL OR range_max IS NULL OR range_min <= range_max))
);

COMMENT ON TABLE public.operation_type_fields IS
    'MES-4a:一道工序记哪些参数(parameter,这一炉用的设定)与指标(indicator,这一炉出来的结果)。配置是数据(MES-0 Q43)。必填在结平时判(Q11);范围为空 = Not yet set(V36);越出范围照记、标出来,不拒(Q12)。退役不删;用上之后 kind / value_type / unit 不许改。RUNTIME CONFIG。';
COMMENT ON COLUMN public.operation_type_fields.has_range IS
    'MES-4a:这个字段【有】一个范围(由设备厂商或工艺工程师给)。为真而上下限都空 = Not yet set,列在 /settings/pending-values 的 V36。为假 = 这个字段没有范围可言(计数、文字),不是"没人给"。';

-- 【属主身份】"用上了没有"要数所有加工单的值与所有配方 —— 不能让改字段的人的读权限少数几行(RLS 静默丢行,xmodule 那一族)。
CREATE OR REPLACE FUNCTION public.guard_operation_type_field()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'OPERATION_FIELD_RETIRE_NOT_DELETE|%|%', OLD.operation_type_code, OLD.field_code;
    END IF;
    IF NEW.operation_type_code IS DISTINCT FROM OLD.operation_type_code OR NEW.field_code IS DISTINCT FROM OLD.field_code THEN
        RAISE EXCEPTION 'OPERATION_FIELD_KEY_FIXED|%|%', OLD.operation_type_code, OLD.field_code;
    END IF;
    IF (NEW.kind IS DISTINCT FROM OLD.kind OR NEW.value_type IS DISTINCT FROM OLD.value_type OR NEW.unit IS DISTINCT FROM OLD.unit)
       AND (EXISTS (SELECT 1 FROM processing_run_values v
                     WHERE v.operation_type_code = OLD.operation_type_code AND v.field_code = OLD.field_code)
            OR EXISTS (SELECT 1 FROM process_recipe_versions rv JOIN process_recipes r ON r.id = rv.recipe_id
                        WHERE r.operation_type_code = OLD.operation_type_code AND rv.param_values ? OLD.field_code)) THEN
        RAISE EXCEPTION 'OPERATION_FIELD_IN_USE|%|%', OLD.operation_type_code, OLD.field_code;
    END IF;
    NEW.updated_at := now();
    NEW.updated_by := auth.uid();
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_operation_type_fields_guard
    BEFORE UPDATE OR DELETE ON public.operation_type_fields
    FOR EACH ROW EXECUTE FUNCTION public.guard_operation_type_field();

INSERT INTO public.operation_type_fields (operation_type_code, field_code, name_en, name_zh, kind, value_type, unit, sort_order, notes) VALUES
    -- 规格 §3.2 人工拆解
    ('manual_disassembly', 'modules_in', 'Modules in', '投入模组数', 'indicator', 'count', 'pcs', 10, 'Spec §3.2: module count in (the mass is the input leg).'),
    ('manual_disassembly', 'cells_out', 'Cells out', '产出电芯数', 'indicator', 'count', 'pcs', 20, 'Spec §3.2: cell count out (routing is by unit).'),
    ('manual_disassembly', 'cells_damaged', 'Cells damaged in disassembly', '拆解中损坏的电芯数', 'indicator', 'count', 'pcs', 30, 'Spec §3.2: tooling, technique and safety indicator.'),
    -- 规格 §3.3 开壳
    ('casing_removal', 'cells_in_hard_case', 'Cells in, hard case', '投入硬壳电芯数', 'indicator', 'count', 'pcs', 10, 'Spec §3.3: classification count.'),
    ('casing_removal', 'cells_in_pouch', 'Cells in, pouch', '投入软包电芯数', 'indicator', 'count', 'pcs', 20, 'Spec §3.3: classification count.'),
    ('casing_removal', 'classified_by', 'Classified by (visual or equipment)', '分类方式(目视或设备)', 'indicator', 'text', NULL, 30, 'Spec §3.3: visual and manual, or equipment identification.'),
    ('casing_removal', 'units_judged_by_hand', 'Units the equipment could not identify, judged by hand', '设备认不出、人工判定的件数', 'indicator', 'count', 'pcs', 40, 'Spec §3.3: the indicator of identification effectiveness.'),
    ('casing_removal', 'misclassifications', 'Misclassifications', '分错的件数', 'indicator', 'count', 'pcs', 50, 'Spec §3.3: persistently non-zero means the classification step needs revision.'),
    ('casing_removal', 'scrap_cut_through', 'Scrap: cut through', '报废:切穿', 'indicator', 'count', 'pcs', 60, 'Spec §3.3 scrap by cause.'),
    ('casing_removal', 'scrap_internal_short', 'Scrap: internal short circuit', '报废:内短路', 'indicator', 'count', 'pcs', 70, 'Spec §3.3 scrap by cause.'),
    ('casing_removal', 'scrap_smoke', 'Scrap: smoke', '报废:冒烟', 'indicator', 'count', 'pcs', 80, 'Spec §3.3 scrap by cause.'),
    ('casing_removal', 'scrap_fire', 'Scrap: fire', '报废:起火', 'indicator', 'count', 'pcs', 90, 'Spec §3.3 scrap by cause.'),
    ('casing_removal', 'cuts_this_run', 'Cuts this run', '本炉切割次数', 'indicator', 'count', 'cuts', 100, 'Spec §3.3: cumulative cut count per tool is built from these.'),
    -- 规格 §3.4 极片分离(与合在一起的 electrode_line 同一组)
    ('electrode_separation', 'cells_in', 'Cells in', '投入电芯数', 'indicator', 'count', 'pcs', 10, 'Spec §3.4.'),
    ('electrode_separation', 'run_time_min', 'Run time', '运行时间', 'indicator', 'number', 'min', 20, 'Spec §3.4: read from the machine controller.'),
    ('electrode_separation', 'energy_kwh', 'Energy', '能耗', 'indicator', 'number', 'kWh', 30, 'Spec §3.4.'),
    ('electrode_separation', 'unplanned_stops', 'Unplanned stops', '非计划停机次数', 'indicator', 'count', 'stops', 40, 'Spec §3.4.'),
    ('electrode_separation', 'unplanned_stop_min', 'Unplanned stop time', '非计划停机时长', 'indicator', 'number', 'min', 50, 'Spec §3.4.'),
    ('electrode_line', 'cells_in', 'Cells in', '投入电芯数', 'indicator', 'count', 'pcs', 10, 'Spec §3.4 (the combined casing-removal and separation machine).'),
    ('electrode_line', 'run_time_min', 'Run time', '运行时间', 'indicator', 'number', 'min', 20, 'Spec §3.4.'),
    ('electrode_line', 'energy_kwh', 'Energy', '能耗', 'indicator', 'number', 'kWh', 30, 'Spec §3.4.'),
    ('electrode_line', 'unplanned_stops', 'Unplanned stops', '非计划停机次数', 'indicator', 'count', 'stops', 40, 'Spec §3.4.'),
    ('electrode_line', 'unplanned_stop_min', 'Unplanned stop time', '非计划停机时长', 'indicator', 'number', 'min', 50, 'Spec §3.4.'),
    -- 规格 §3.5 两条粉料线
    ('electrode_powder_line', 'run_time_min', 'Run time', '运行时间', 'indicator', 'number', 'min', 10, 'Spec §3.5.'),
    ('electrode_powder_line', 'energy_kwh', 'Energy', '能耗', 'indicator', 'number', 'kWh', 20, 'Spec §3.5.'),
    ('battery_powder_line', 'run_time_min', 'Run time', '运行时间', 'indicator', 'number', 'min', 10, 'Spec §3.5.'),
    ('battery_powder_line', 'energy_kwh', 'Energy', '能耗', 'indicator', 'number', 'kWh', 20, 'Spec §3.5.');

ALTER TABLE public.operation_type_fields ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_type_fields select by permission" ON public.operation_type_fields
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
CREATE POLICY "operation_type_fields insert by permission" ON public.operation_type_fields
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.processing.edit'::text));
CREATE POLICY "operation_type_fields update by permission" ON public.operation_type_fields
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE ON public.operation_type_fields TO authenticated;
REVOKE ALL ON public.operation_type_fields FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"(与 operation_types 同一条)。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.operation_type_fields
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
