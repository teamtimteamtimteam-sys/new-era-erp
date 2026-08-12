-- db/tables/storage_location_allowed_classes.sql
-- 库位可存放的受控物料分类(LOC-1)。一行 = 这个库位可以放这一类。
--
-- NOTE: introduced by db/migrations/2026-08-12-loc1-storage-location-master.sql.
-- First-run script (plain CREATEs).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【两条语义,都要在读代码之前读到】
--
-- (a) 【零行 = 未配置 = "还没决定"】—— 将来的检查对它【告警,绝不拒绝】。
--     它与"配了、但不含这一类"是两回事:后者是一个有人做过的决定,该拒。
--     把两者压成同一个"不在允许清单里"的布尔量,就是把【没人想过】演成
--     【想过、结论是不行】—— 一个不会响的拦截比没有拦截更坏,因为人以为
--     系统在替他判断。同 MAT-1 的「未分类不是非受控」、METAL-1 的
--     `no_reference`、MAT-1 报告里被否掉的 (a) 方案:第三种状态不是前两种
--     里的哪一种。查询时的判据是【这个库位有没有任何一行】,不是
--     【有没有这一类的那一行】。
--
-- (b) 【本表在这一刀里只记录,不设闸】—— 今天没有任何东西因为这张表拒绝过
--     一次收货或移库。落闸的地方是【出入库单据那一刀】。明写在这里,是因为
--     一张叫 allowed_classes 的表看起来就像已经在拦了,而"以为有拦截"比
--     "知道没有"更坏。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 【为什么引 code 而不是 id】`waste_classifications` 的主键就是 `code text`
-- (MAT-1,与 certificate_types 同形),没有 uuid 主键可引。
--
-- 【删一行 = 不再允许那一类】"不在表里"就是"不允许"的表达方式,与
-- pricing_formula_metals 同形 —— 这类物理删除已记在
-- docs/as-built-divergences.md 第 2 条。

CREATE TABLE public.storage_location_allowed_classes (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    location_id         uuid NOT NULL REFERENCES public.storage_locations (id) ON DELETE RESTRICT,
    classification_code text NOT NULL REFERENCES public.waste_classifications (code),
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    UNIQUE (location_id, classification_code)
);

COMMENT ON TABLE public.storage_location_allowed_classes IS
    'LOC-1:库位可存放的受控物料分类。一行 = 这个库位可以放这一类。【零行 = 未配置 = 还没决定】,将来的检查对它告警而绝不拒绝 —— 与"配了、但不含这一类"(有人做过决定,该拒)是两回事,压成一个布尔量就是把"没人想过"演成"想过、结论是不行"。【本刀只记录,不设闸】:落闸的地方是出入库单据那一刀,今天没有任何东西因为这张表拒绝过一次收货或移库。';

COMMENT ON COLUMN public.storage_location_allowed_classes.classification_code IS
    'LOC-1:引 waste_classifications.code(该表主键就是 code,没有 uuid 可引)。【合规逻辑将来读的是 waste_classifications.is_controlled,不是这个字符串】—— 分类的名字会增删改,"受不受控"才是语义(MAT-1)。另:materials.waste_classification_code IS NULL 意为【未分类】,永远不等于 non_focused。';

ALTER TABLE public.storage_location_allowed_classes ENABLE ROW LEVEL SECURITY;

-- 读写跟着库位自己的模块走(module.inventory.*)—— 与 storage_locations 上
-- 既有的策略同一条判断,不另立一套。
CREATE POLICY "storage_location_allowed_classes select by permission"
    ON public.storage_location_allowed_classes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inventory.view'::text));

CREATE POLICY "storage_location_allowed_classes insert by permission"
    ON public.storage_location_allowed_classes
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inventory.edit'::text));

CREATE POLICY "storage_location_allowed_classes update by permission"
    ON public.storage_location_allowed_classes
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inventory.edit'::text)) WITH CHECK (has_permission('module.inventory.edit'::text));

CREATE POLICY "storage_location_allowed_classes delete by permission"
    ON public.storage_location_allowed_classes
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inventory.edit'::text));
