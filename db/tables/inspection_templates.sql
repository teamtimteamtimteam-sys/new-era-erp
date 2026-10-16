-- db/tables/inspection_templates.sql
-- MES-7b-2(2026-10-16,MES-0 功能 23 · Q72;MES-7b Step 0 Q13 · Q20,Tim):【一张巡检清单】—— 安全巡检的模板:一个代号、一个名字、
--   巡的是哪一片(area)、多久巡一次(frequency_days —— V18)、以及按顺序排好的检查项(inspection_template_items)。
--   ★ 一张都不引导(Q13):清单是安全工程公司 / WSH 主任给的(V18),不是这里编的。没有任何一张启用的清单时,待补的值页上 V18 一行。
--   ★ 频率空着 = "Not yet set"(V18):那张清单照样巡得了,只是"到期该巡"那条提醒不会为它响(没有日子可数),待补的值页上它一行。
--   ★ 改一张清单【从不改写】过去的巡检:一次巡检在记下的那一刻把每一项的字抄进 inspection_results(Q13)。所以清单的代号、名字、片区、
--     检查项都可以照改;停用只管"以后还能不能新巡"。不许删(停用代替删 —— 巡检指着它)。
--   【写】只经 save_inspection_template(module.safety.edit):清单与它的检查项一次存下,检查项按顺序重排。会话里直连的写按名拒
--     INSPECTION_TEMPLATE_THROUGH_FUNCTION_ONLY;删除对谁都按名拒 INSPECTION_TEMPLATE_NOT_DELETABLE(guard_inspection_template_write,语句级)。
--   【读】module.safety.view。没有金额。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.inspection_templates (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code           text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9][A-Z0-9_-]*$'),
    name           text NOT NULL CHECK (btrim(name) <> ''),
    area           text NOT NULL CHECK (btrim(area) <> ''),
    frequency_days integer CHECK (frequency_days IS NULL OR frequency_days > 0),
    is_active      boolean NOT NULL DEFAULT true,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid DEFAULT auth.uid()
);

CREATE INDEX inspection_templates_code_trgm ON public.inspection_templates USING gin (code extensions.gin_trgm_ops);

COMMENT ON TABLE public.inspection_templates IS
    'MES-7b-2:一张安全巡检清单 —— 代号、名字、片区、频率(天,V18;空 = Not yet set)、启用,检查项在 inspection_template_items。一张都不引导。改清单从不改写过去的巡检(巡检记下那一刻把检查项的字抄走)。写只经 save_inspection_template(module.safety.edit),不许删(停用代替)。读 module.safety.view。';
COMMENT ON COLUMN public.inspection_templates.frequency_days IS
    'V18:多久巡一次(天)。空 = Not yet set —— 照样巡得了,只是"到期该巡"的提醒不为它响,待补的值页上它一行。由安全工程公司 / WSH 主任给。';

ALTER TABLE public.inspection_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "inspection_templates select by permission" ON public.inspection_templates
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.safety.view'::text));
-- 写:一条策略都不给 —— 只经 save_inspection_template。INSERT / UPDATE / DELETE 授着,是为了让直连的写走到守卫、按名被拒,而不是撞上一句 42501。
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inspection_templates TO authenticated;
REVOKE ALL ON public.inspection_templates FROM anon;

CREATE TRIGGER trg_inspection_templates_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.inspection_templates
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_inspection_template_write();
CREATE TRIGGER trg_inspection_templates_updated_at
    BEFORE UPDATE ON public.inspection_templates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
