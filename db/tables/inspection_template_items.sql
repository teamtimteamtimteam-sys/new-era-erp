-- db/tables/inspection_template_items.sql
-- MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q13,Tim):【一张巡检清单上的一项】—— 按顺序(position 1, 2, 3 …)排好的检查项的字。
--   ★ 巡检不指着这一行:一次巡检把那一刻的字抄进 inspection_results(Q13)—— 所以这里的字照改、项照删,过去的巡检一个字都不动。
--   【写】只经 save_inspection_template(module.safety.edit),整张清单一次存下、按顺序重排;会话里直连的写按名拒
--     INSPECTION_TEMPLATE_THROUGH_FUNCTION_ONLY(guard_inspection_template_write,语句级)。
--   【读】module.safety.view。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.inspection_template_items (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    template_id uuid NOT NULL REFERENCES public.inspection_templates (id),
    position    integer NOT NULL CHECK (position > 0),
    item_text   text NOT NULL CHECK (btrim(item_text) <> ''),
    CONSTRAINT inspection_template_items_position UNIQUE (template_id, position)
);

COMMENT ON TABLE public.inspection_template_items IS
    'MES-7b-2:巡检清单上的一项(按 position 排)。巡检不指着它 —— 记下那一刻把字抄进 inspection_results,所以这里照改、照删,过去的巡检不动。写只经 save_inspection_template(module.safety.edit)。读 module.safety.view。';

ALTER TABLE public.inspection_template_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "inspection_template_items select by permission" ON public.inspection_template_items
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.safety.view'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inspection_template_items TO authenticated;
REVOKE ALL ON public.inspection_template_items FROM anon;

CREATE TRIGGER trg_inspection_template_items_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.inspection_template_items
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_inspection_template_write();
