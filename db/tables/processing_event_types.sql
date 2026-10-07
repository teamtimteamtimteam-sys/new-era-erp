-- db/tables/processing_event_types.sql
-- MES-4a(2026-10-07,规格 §3.1 · §5 · §6.2;MES-4a Step 0 Q15,Tim):【一炉里的异常事件,是哪一种】—— 一张固定的清单,没有"其它"。
--   引导三行:非计划停机 · 设备报警 · 安全报警(规格点名的三种)。加一种是加一行(/settings/dictionaries,module.processing.edit)。
--   ★ 没有 other:一件说不出是哪一种的异常没有审计价值(规格 §4.1 对损耗说的同一句话),而"其它"会把这条清单变成一个兜底桶。
--   RUNTIME CONFIG。读:module.processing.view。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.processing_event_types (
    code       text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$' AND code <> 'other'),
    name_en    text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh    text NOT NULL CHECK (btrim(name_zh) <> ''),
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.processing_event_types IS
    'MES-4a:一炉里异常事件的种类(规格 §5 "Exception events")。引导:unplanned_stop · equipment_alarm · safety_alarm;没有 other。RUNTIME CONFIG。';

INSERT INTO public.processing_event_types (code, name_en, name_zh, sort_order, notes) VALUES
    ('unplanned_stop', 'Unplanned stop', '非计划停机', 10, 'Spec §3.4: unplanned stop count and duration.'),
    ('equipment_alarm', 'Equipment alarm', '设备报警', 20, 'Spec §5: equipment alarms recorded individually.'),
    ('safety_alarm', 'Safety alarm', '安全报警', 30, 'Spec §2 · §6.2: the ERP receives the record that a safety alarm occurred; the alarm itself is hardwired at site.');

ALTER TABLE public.processing_event_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_event_types select by permission" ON public.processing_event_types
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
CREATE POLICY "processing_event_types write by permission" ON public.processing_event_types
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.processing_event_types TO authenticated;
REVOKE ALL ON public.processing_event_types FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.processing_event_types
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
