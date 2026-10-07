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
    ('battery_powder_line', 'black_mass', NULL),
    -- MES-4a(MES-0 Q37 · MES-4a Step 0 Q3):electrode_line 那四行拆给两段
    ('casing_removal', 'de_cased_cell', NULL),
    ('casing_removal', 'casing', NULL),
    ('electrode_separation', 'cathode_sheet', NULL),
    ('electrode_separation', 'anode_sheet', NULL),
    ('electrode_separation', 'separator', '【R4】它是一个【出口】——离开这条线,不再往下走。'),
    -- MES-4b(MES-0 Q37 · Q55;MES-4b Step 0 Q10):新产品的出处 —— 只是信息,与这张表的其余行一样【不在提交时校验】,
    --   产出选择器也不按它过滤(线上 5 种物料里 4 种没有形态,一过滤它们就看不见了)。
    ('electrode_powder_line', 'cathode_powder', '【MES-4b · 规格 §3.5】正负极分开剥。'),
    ('electrode_powder_line', 'anode_powder', '【MES-4b · 规格 §3.5】'),
    ('electrode_powder_line', 'copper_foil', '【MES-4b · 规格 §3.5】'),
    ('electrode_powder_line', 'aluminium_foil', '【MES-4b · 规格 §3.5】'),
    ('electrode_powder_line', 'collected_dust', '【MES-4b · 规格 §3.5】除尘收集、称过的粉尘 —— 产出,不是损耗。'),
    ('battery_powder_line', 'collected_dust', '【MES-4b · 规格 §3.5】同上。'),
    ('manual_disassembly', 'harness_bms_busbar', '【MES-4b · 规格 §3.2】线束、管理板与汇流排单独称。');

-- 安全状态受理 —— **本刀的核心**

ALTER TABLE public.operation_type_output_forms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_type_output_forms select all" ON public.operation_type_output_forms
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "operation_type_output_forms write by permission" ON public.operation_type_output_forms
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operation_type_output_forms TO authenticated;

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.operation_type_output_forms
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
