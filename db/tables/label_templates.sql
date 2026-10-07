-- db/tables/label_templates.sql
-- MES-3b(2026-10-07,MES-0 Q40;MES-3b Step 0 Q4 · Q5,Tim):【标签模板】—— 一张字典,在【固定的几种形状】里选:
--   给哪一种东西印(进料批 · 产出批 · 库位)、纸多大(A6 · A5,横放)、印不印危险品那一行。
--   版式本身只有一份(app/components/labels/labelHtml.ts):模板只是挑一种形状,永远不能往标签里塞一段标记(Q5 的 a,不是 c)。
--   默认 = 那一种东西下面启用着、sort_order 最小的那一行。
--   引导播六行:每一种东西一张 A6(= 今天的那张标签)与一张 A5 —— 页面上那个"A6 还是 A5"的选择从第一天就在(Tim 的 v1.4.40 发布行)。
--   热敏打印机(D10)来了之后的尺寸与 DPI 不在这里:那时它们是新的形状,加行之前先加 CHECK 里的值(一支迁移)。
--   RUNTIME CONFIG:改名、停用、换默认是改一行(/settings/dictionaries,module.inventory.edit —— 库存的写码,标签是仓库的事)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.label_templates (
    code        text PRIMARY KEY,
    name_en     text NOT NULL,
    name_zh     text NOT NULL,
    is_active   boolean NOT NULL DEFAULT true,
    sort_order  integer NOT NULL DEFAULT 0,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid DEFAULT auth.uid(),
    object_kind text NOT NULL CHECK (object_kind IN ('inbound_batch', 'output_batch', 'storage_location')),
    page_size   text NOT NULL CHECK (page_size IN ('A6', 'A5')),
    show_dg     boolean NOT NULL DEFAULT true
);

COMMENT ON TABLE public.label_templates IS
    'MES-3b:标签模板(RUNTIME CONFIG)。一行 = 一种固定形状:object_kind(inbound_batch · output_batch · storage_location)× page_size(A6 · A5,横放)× show_dg(印不印危险品那一行)。版式只有一份,模板只挑形状。默认 = 那一种东西启用着、sort_order 最小的一行。';

INSERT INTO public.label_templates (code, name_en, name_zh, object_kind, page_size, show_dg, sort_order) VALUES
    ('inbound_a6',  'Inbound batch · A6',  '进料批 · A6', 'inbound_batch',    'A6', true,  10),
    ('inbound_a5',  'Inbound batch · A5',  '进料批 · A5', 'inbound_batch',    'A5', true,  20),
    ('output_a6',   'Output batch · A6',   '产出批 · A6', 'output_batch',     'A6', true,  30),
    ('output_a5',   'Output batch · A5',   '产出批 · A5', 'output_batch',     'A5', true,  40),
    ('location_a6', 'Location · A6',       '库位 · A6',   'storage_location', 'A6', false, 50),
    ('location_a5', 'Location · A5',       '库位 · A5',   'storage_location', 'A5', false, 60);

CREATE TRIGGER trg_label_templates_updated_at
    BEFORE UPDATE ON public.label_templates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.label_templates ENABLE ROW LEVEL SECURITY;
-- 读:印得了哪一种标签的人(进料 / 产出 / 库存查看)。写:库存的编辑码。
CREATE POLICY "label_templates select by permission"
    ON public.label_templates AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inventory.view') OR has_permission('module.inbound.view')
           OR has_permission('module.output.view'));
CREATE POLICY "label_templates write by permission"
    ON public.label_templates AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.inventory.edit'))
    WITH CHECK (has_permission('module.inventory.edit'));

REVOKE ALL ON public.label_templates FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.label_templates
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.inventory.edit');
