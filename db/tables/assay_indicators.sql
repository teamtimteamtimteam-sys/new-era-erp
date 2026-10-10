-- db/tables/assay_indicators.sql
-- MES-6a-2(2026-10-10,MES-0 3.5b · 3.5c · 3.5e;MES-6a Step 0 Q3 · Q4,Tim):化验上【除了物质含量之外】还要记的指标 —— 一张字典。
--   今天五个,都是【定义】,不是标准:残粉(箔上残留的粉,%)· 箔纯度(%)· 粒径的 D10 / D50 / D90(µm,实验室按分布报)。
--   一个值、一个限都没有种 —— 限(V17,水分与粒径的验收限)按合同,随质量冻结排在 MES-6b(Step 0 Q5)。
--   水分【不在这里】:它照旧是 assay_results.moisture_pct 那一列(换湿 / 干基要用它,Q3)。
--   值记在 assay_result_indicators(一份化验一个指标一行),在两张化验表单上填;批次上没有一份抄过去的副本(Q3)。
--   读:持进料 / 产出 / 物料任一查看码的人(不是 USING (true) —— 见下面的策略)。
--   RUNTIME CONFIG:Tim 可以停用任何一个(字典编辑器,与 substances 同一个写码 module.materials.edit);停用只管"还能不能新选",
--   已经记下的值照旧读得出来(与 substances.is_active 同一条,D5)。check_mirrors 不逐行比对它的内容。
--
-- NOTE: introduced by db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.assay_indicators (
    code       text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$'),
    name_en    text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh    text NOT NULL CHECK (btrim(name_zh) <> ''),
    unit       text NOT NULL CHECK (btrim(unit) <> ''),
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.assay_indicators IS
'MES-6a-2:化验上除物质含量之外要记的指标(字典)。五个定义:残粉 %、箔纯度 %、粒径 D10 / D50 / D90 µm —— 定义,不是标准:没有值、没有限(V17 在 MES-6b)。水分仍是 assay_results.moisture_pct。值在 assay_result_indicators。停用只管新选(D5)。写 module.materials.edit;读要进料 / 产出 / 物料任一查看码。';
COMMENT ON COLUMN public.assay_indicators.unit IS
'这个指标的单位,原样印在值的后面(%、µm)。一个文字标签,不参与任何换算 —— 屏幕不替它换单位。';

-- ── 五个定义(Q4)。值与限一个都不种 ──────────────────────────────────────
INSERT INTO public.assay_indicators (code, name_en, name_zh, unit, sort_order, notes) VALUES
    ('residual_powder_pct', 'Residual powder on foil', '箔上残粉', '%',  1, NULL),
    ('foil_purity_pct',     'Foil purity',             '箔纯度',   '%',  2, NULL),
    ('d10_um',              'Particle size D10',       '粒径 D10', 'µm', 3, NULL),
    ('d50_um',              'Particle size D50',       '粒径 D50', 'µm', 4, NULL),
    ('d90_um',              'Particle size D90',       '粒径 D90', 'µm', 5, NULL);

ALTER TABLE public.assay_indicators ENABLE ROW LEVEL SECURITY;
-- 读:读得到化验的人(进料 / 产出查看码)与维护字典的人(物料查看码)—— 记化验、看化验、看批次的人都要读得出指标的名字。
--   【不是 USING (true)】那 44 条对 authenticated 敞开的读策略是一个被钉住的数(fixture 249 POL),目录也用不着对每一个人敞开
--   (cell_constructions 的先例:按读它的那几页的码)。
CREATE POLICY "assay_indicators select by permission"
    ON public.assay_indicators AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.inbound.view'::text, 'module.output.view'::text, 'module.materials.view'::text]));
CREATE POLICY "assay_indicators insert by permission"
    ON public.assay_indicators AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));
CREATE POLICY "assay_indicators update by permission"
    ON public.assay_indicators AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.assay_indicators TO authenticated;
REVOKE ALL ON public.assay_indicators FROM anon;

-- ── SILENT-1 · 被拒绝的写要抛,不许是一次"成功的空操作"(与 substances 同一支语句级触发器)──────────
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.assay_indicators
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
