-- db/tables/operation_type_output_forms.sql
-- PROC-WIRE-1B-i:这道工序【出】哪些形态(R1 的 N×M 之一)。RUNTIME CONFIG。
-- 【状态改变型一行都没有】—— 那正是 R3,不是漏播。
-- NOTE: introduced by db/migrations/2026-08-31-procwire1bi-operations-wired-and-the-discharge-deadlock.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.operation_type_output_forms (
    operation_type_code text NOT NULL REFERENCES public.operation_types (code) ON DELETE CASCADE,
    form_code           text NOT NULL REFERENCES public.material_forms (code),
    notes               text,
    PRIMARY KEY (operation_type_code, form_code)
);

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

ALTER TABLE public.operation_type_output_forms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_type_output_forms select all" ON public.operation_type_output_forms
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "operation_type_output_forms write by permission" ON public.operation_type_output_forms
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operation_type_output_forms TO authenticated;
