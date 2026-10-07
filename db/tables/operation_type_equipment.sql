-- db/tables/operation_type_equipment.sql
-- MES-4a(2026-10-07,MES-0 Q41 · MES-4a Step 0 Q9,Tim):【哪台机器跑哪道工序】—— 工序 ↔ 资产的关联,processing_runs.equipment_id
--   能变成必填的那个前置条件(此前"今天这个库里根本没有这条关联",commit_processing_run 的 EQP-2a 段落与 docs/processing-support-as-built.md)。
--   ① 只关联【设备】类资产(fixed_assets.category = 'equipment'):车辆、办公、其它不是跑工序的机器 → EQUIPMENT_LINK_NOT_EQUIPMENT|<编号>|<类>。
--   ② 规则在 commit_processing_run:一道工序只要挂着【至少一台没处置的】机器,这一炉就必须说出是哪一台,而且必须是挂着的那几台之一
--      (EQUIPMENT_REQUIRED_FOR_OPERATION · EQUIPMENT_NOT_LINKED_TO_OPERATION)。处置掉的机器不算数。
--   ③ 【引导是空的】哪台机器跑哪道工序是 Tim 的数据,在工序页上挂;这张表不在 RUNTIME CONFIG 清单里(没有引导可比 —— 与配方同一类)。
--   读:module.processing.view;写:module.processing.edit。挂上、摘下都进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.operation_type_equipment (
    operation_type_code text NOT NULL REFERENCES public.operation_types (code),
    fixed_asset_id      uuid NOT NULL REFERENCES public.fixed_assets (id),
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    PRIMARY KEY (operation_type_code, fixed_asset_id)
);

COMMENT ON TABLE public.operation_type_equipment IS
    'MES-4a:哪台机器跑哪道工序(MES-0 Q41)。只关联设备类资产;一道工序挂着至少一台没处置的机器时,它的加工单必须说出是挂着的哪一台。引导是空的(Tim 在工序页上挂)。';

CREATE INDEX operation_type_equipment_asset ON public.operation_type_equipment (fixed_asset_id);

CREATE OR REPLACE FUNCTION public.guard_operation_type_equipment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_cat  text;
BEGIN
    -- 属主读 fixed_assets(它只给财务读;挂机器的人持加工的码)—— 只取类与编号,不外泄别的列
    SELECT fa.code, fa.category INTO v_code, v_cat FROM fixed_assets fa WHERE fa.id = NEW.fixed_asset_id;
    IF v_cat IS DISTINCT FROM 'equipment' THEN
        RAISE EXCEPTION 'EQUIPMENT_LINK_NOT_EQUIPMENT|%|%', COALESCE(v_code, NEW.fixed_asset_id::text), COALESCE(v_cat, '?');
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_operation_type_equipment_guard
    BEFORE INSERT OR UPDATE ON public.operation_type_equipment
    FOR EACH ROW EXECUTE FUNCTION public.guard_operation_type_equipment();

ALTER TABLE public.operation_type_equipment ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_type_equipment select by permission" ON public.operation_type_equipment
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
CREATE POLICY "operation_type_equipment write by permission" ON public.operation_type_equipment
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operation_type_equipment TO authenticated;
REVOKE ALL ON public.operation_type_equipment FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.operation_type_equipment
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
