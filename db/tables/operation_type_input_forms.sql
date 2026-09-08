-- db/tables/operation_type_input_forms.sql
-- PROC-WIRE-1B-i:这道工序【收】哪些形态(R1 的 N×M 之一)。RUNTIME CONFIG。
-- NOTE: introduced by db/migrations/2026-08-31-procwire1bi-operations-wired-and-the-discharge-deadlock.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.operation_type_input_forms (
    operation_type_code text NOT NULL REFERENCES public.operation_types (code) ON DELETE CASCADE,
    form_code           text NOT NULL REFERENCES public.material_forms (code),
    notes               text,
    PRIMARY KEY (operation_type_code, form_code)
);

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

ALTER TABLE public.operation_type_input_forms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_type_input_forms select all" ON public.operation_type_input_forms
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "operation_type_input_forms write by permission" ON public.operation_type_input_forms
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operation_type_input_forms TO authenticated;

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.operation_type_input_forms
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
