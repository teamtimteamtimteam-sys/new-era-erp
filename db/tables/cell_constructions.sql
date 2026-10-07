-- db/tables/cell_constructions.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q45;MES-4b Step 0 Q3–Q8,Tim):【电芯是卷绕的还是叠片的】—— 一个【批次】的事实,不是物料的。
--   规格 §3.4:同一类物料的批次可能因来源不同而结构不同;卷绕与叠片走两台不同的极片分离设备。
--   引导三行:wound(卷绕)· stacked(叠片)· unknown(看过了,分不出来)。is_determined 是【规则列】:
--   极片分离 / 自动极片线的投料批必须带一个 is_determined 为真的值(INPUT_CELL_CONSTRUCTION_REQUIRED)——
--   unknown 与"没记"一样过不去,但它们【不是】同一件事:unknown 是一次看过之后的结论,空是没人看过。
--   RUNTIME CONFIG(/settings/dictionaries,module.processing.edit —— 路由是加工的事实)。
--   读:加工、进料、产出三个查看码任一(批次页与加工单表单都要画它的名字)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.cell_constructions (
    code          text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$'),
    name_en       text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh       text NOT NULL CHECK (btrim(name_zh) <> ''),
    -- 【规则列】这个值是不是一个【确定的】结构 —— 只有为真的值过得了极片分离的投料闸。
    is_determined boolean NOT NULL,
    is_active     boolean NOT NULL DEFAULT true,
    sort_order    integer NOT NULL DEFAULT 0,
    notes         text
);

COMMENT ON TABLE public.cell_constructions IS
    'MES-4b:电芯结构(规格 §3.4 —— 卷绕 / 叠片走两台不同的分离设备)。批次的属性(inbound_batches / output_batches.cell_construction_code),只对仍装着电芯的形态成立(material_forms.implies_dismantling)。引导 wound · stacked · unknown;is_determined 为真的才过得了极片分离的投料闸。RUNTIME CONFIG。';

COMMENT ON COLUMN public.cell_constructions.is_determined IS
    'MES-4b(Q3 · Q5):这个值是不是一个【确定的】结构。operation_types.requires_cell_construction 为真的工序(引导:electrode_separation · electrode_line),每一批投料都必须带一个 is_determined 为真的值;空或 unknown → INPUT_CELL_CONSTRUCTION_REQUIRED|<批号>。';

INSERT INTO public.cell_constructions (code, name_en, name_zh, is_determined, sort_order, notes) VALUES
    ('wound', 'Wound', '卷绕', true, 10, 'Spec §3.4: jelly-roll cells; separated on the wound-cell machine.'),
    ('stacked', 'Stacked', '叠片', true, 20, 'Spec §3.4: stacked-electrode cells; separated on the stacked-cell machine.'),
    ('unknown', 'Unknown (inspected, cannot tell)', '未知(看过,分不出)', false, 30, 'MES-0 Q45: somebody looked and could not tell. Not the same as not recorded — but neither passes the electrode-separation input check.');

ALTER TABLE public.cell_constructions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cell_constructions select by permission" ON public.cell_constructions
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.processing.view'::text, 'module.inbound.view'::text, 'module.output.view'::text]));
CREATE POLICY "cell_constructions write by permission" ON public.cell_constructions
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.cell_constructions TO authenticated;
REVOKE ALL ON public.cell_constructions FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.cell_constructions
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
