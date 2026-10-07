-- db/tables/nea_waste_categories.sql
-- MES-3a(2026-10-06,MES-0 Q32 · V29;MES-3a Step 0 Q4,Tim):【NEA 批准的废物类别】字典 —— 库存上限按"执照 × 类别"记(吨)。
--   【引导一行都不播,而这是一个决定】类别的名字与编号是 NEA 执照条件里写的,不是这里能编的。
--   今天唯一的分类是 waste_classifications 的 focused / non_focused,而把那两个映射到 NEA 的类别上是"发明,不是建模"
--   (hazardous_qty_on_hand_tonnes 的旧注释原话)—— 所以本表从空开始,"类别列表还没给"在 /settings/pending-values 上是 V29。
--   【为什么不是 waste_classifications 的新行】那张表决定哪个货架收哪类料(storage_location_allowed_classes);
--   一份执照的词汇混进去,改一个类别就会改掉货架的规矩(MES-3a Step 0 Q4)。
--   RUNTIME CONFIG:加一类是加一行(/settings/dictionaries,module.materials.edit),记进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.nea_waste_categories (
    code        text PRIMARY KEY,
    name_en     text NOT NULL,
    name_zh     text NOT NULL,
    is_active   boolean NOT NULL DEFAULT true,
    sort_order  integer NOT NULL DEFAULT 0,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.nea_waste_categories IS
    'MES-3a:NEA 批准的废物类别(RUNTIME CONFIG,从空开始 —— V29,由 NEA 执照给)。库存上限按执照 × 类别记(licence_storage_limits),物料的类别在 materials.nea_waste_category_code。不是 waste_classifications(那张决定货架收什么)。';

CREATE TRIGGER trg_nea_waste_categories_updated_at
    BEFORE UPDATE ON public.nea_waste_categories
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.nea_waste_categories ENABLE ROW LEVEL SECURITY;
-- 读:要用到它的四个模块(物料主数据、执照、库存、进料 / 产出)—— 不是 USING (true):那 44 条开着的读策略不再加一条(MES-0 Q86)。
CREATE POLICY "nea_waste_categories select by permission"
    ON public.nea_waste_categories AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.materials.view') OR has_permission('module.suppliers.view')
           OR has_permission('module.inventory.view') OR has_permission('module.inbound.view')
           OR has_permission('module.output.view'));
CREATE POLICY "nea_waste_categories write by permission"
    ON public.nea_waste_categories AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.materials.edit'))
    WITH CHECK (has_permission('module.materials.edit'));

REVOKE ALL ON public.nea_waste_categories FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"(与 waste_classifications 同一条)。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.nea_waste_categories
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
