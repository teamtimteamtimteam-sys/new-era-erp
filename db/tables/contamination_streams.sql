-- db/tables/contamination_streams.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q52 · V11;MES-4b Step 0 Q21,Tim):【交叉污染抽检的两条流】—— 正极片里混了多少负极、负极片里混了多少正极。
--   一行 = 一条流:它抽检哪一种极片(sheet_form_code)、在里面找哪一种外来物(foreign_form_code)、超过多少要标出来(warning_pct,V11)。
--   引导两行:cathode(抽正极片,找负极片)· anode(抽负极片,找正极片)。warning_pct 引导为空 = Not yet set(V11:Tim / 第一份
--   黑粉承购合同的规格给)—— 为空时一次抽检的结果是"判不了",不是"在范围内"。
--   【它为什么是一张表,不是两个写死的码】提醒臂(contamination_check_missing)要从【数据】里认出哪些产出是这条流的极片 ——
--   一张表让"多一条流"是一行,而不是改一支视图。V11 也要有一行可以住。
--   RUNTIME CONFIG(/settings/dictionaries,module.processing.edit)。读:加工或产出查看码(极片批的买方关心的质量事实)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contamination_streams (
    code              text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$'),
    name_en           text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh           text NOT NULL CHECK (btrim(name_zh) <> ''),
    -- 抽检的是哪一种极片 —— 一次抽检必须挂在这一炉的一条这种形态的产出腿上
    sheet_form_code   text NOT NULL REFERENCES public.material_forms (code),
    -- 在里面找的外来物是哪一种形态
    foreign_form_code text NOT NULL REFERENCES public.material_forms (code),
    -- V11:超过多少(外来物质量占样品质量的百分比)要标出来。为空 = Not yet set。只标出来,从不拒。
    warning_pct       numeric CHECK (warning_pct IS NULL OR (warning_pct >= 0 AND warning_pct <= 100)),
    is_active         boolean NOT NULL DEFAULT true,
    sort_order        integer NOT NULL DEFAULT 0,
    notes             text,
    CONSTRAINT contamination_streams_forms_differ CHECK (sheet_form_code <> foreign_form_code)
);

COMMENT ON TABLE public.contamination_streams IS
    'MES-4b:交叉污染抽检的流(规格 §3.4 —— 至少每班一次)。一行 = 抽哪一种极片、找哪一种外来物、警戒线(V11)。引导 cathode · anode。RUNTIME CONFIG。';

COMMENT ON COLUMN public.contamination_streams.warning_pct IS
    'MES-4b(V11):污染率警戒线,外来物质量占样品质量的百分比。为空 = Not yet set(Tim / 第一份黑粉承购合同的规格给)—— 为空时一次抽检判不了(above_warning 为 NULL),不是"在范围内"。超过它只标出来,从不拒。每一次抽检记下当时的值(contamination_checks.warning_pct_at),改它不会重判旧的抽检。';

INSERT INTO public.contamination_streams (code, name_en, name_zh, sheet_form_code, foreign_form_code, sort_order, notes) VALUES
    ('cathode', 'Cathode stream', '正极流', 'cathode_sheet', 'anode_sheet', 10, 'Spec §3.4: anode material found in the cathode sheets.'),
    ('anode', 'Anode stream', '负极流', 'anode_sheet', 'cathode_sheet', 20, 'Spec §3.4: cathode material found in the anode sheets.');

ALTER TABLE public.contamination_streams ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contamination_streams select by permission" ON public.contamination_streams
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.processing.view'::text, 'module.output.view'::text]));
CREATE POLICY "contamination_streams write by permission" ON public.contamination_streams
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.contamination_streams TO authenticated;
REVOKE ALL ON public.contamination_streams FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contamination_streams
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.processing.edit');
