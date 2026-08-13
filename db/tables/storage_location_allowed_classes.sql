-- db/tables/storage_location_allowed_classes.sql
-- 库位可存放的受控物料分类(LOC-1)。一行 = 这个库位可以放这一类。
--
-- NOTE: introduced by db/migrations/2026-08-12-loc1-storage-location-master.sql.
-- First-run script (plain CREATEs).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【两条语义,都要在读代码之前读到】
--
-- (a) 【零行 = 未配置 = "还没决定"】—— 检查对它【告警,绝不拒绝】(IOD-2 起)。
--     它与"配了、但不含这一类"是两回事:后者是一个有人做过的决定,该拒。
--     把两者压成同一个"不在允许清单里"的布尔量,就是把【没人想过】演成
--     【想过、结论是不行】—— 一个不会响的拦截比没有拦截更坏,因为人以为
--     系统在替他判断。同 MAT-1 的「未分类不是非受控」、METAL-1 的
--     `no_reference`、MAT-1 报告里被否掉的 (a) 方案:第三种状态不是前两种
--     里的哪一种。查询时的判据是【这个库位有没有任何一行】,不是
--     【有没有这一类的那一行】。
--
-- (b) 【本表设闸 —— 从 IOD-2 起】(2026-08-13)
--     判词是 public.check_location_class(库位, 物料),【四个落地点共用一处】:
--     create_inbound_batch / receive_inbound_batch_against_po / create_output_batch
--     与 create_stock_transfer 的【入】腿。行为由 fixture 59 钉住。
--
--     【这一句被改过两次,改动本身就是教训】LOC-1 当初写的是"落闸的地方是出入库
--     单据那一刀";那一刀是 IOD-1,而 IOD-1 落完了并没有设闸,于是那句话在合并
--     的瞬间就指着一个已经过去的时点(IOD-1 fu3 把它改指 IOD-2)。今天 IOD-2
--     落闸,所以这一段第三次改写 —— 一句描述已不存在的状态的注释,和一句断言
--     不可能发生的危险的注释,是同一种缺陷。
--
--     【三态,而分界线是"有没有人做过决定"】
--         零行(未配置)        → 告警 IOD_CLASS_UNCONFIGURED_LOCATION,绝不拒绝
--         物料未分类            → 告警 IOD_MATERIAL_UNCLASSIFIED,【在已配置库位上也是告警】
--         配了、且不含这一类    → 拒绝 IOD_CLASS_EXCLUDED
--         配了且含;或未指定库位 → 静默
--     只有一次【明确的人为排除】才拒绝;缺失的决定一律告警 —— 拒绝一次没人做过
--     的决定,是把系统的沉默说成人的意志。
--
--     【那个被实测撞到过的陷阱,现在由 fixture 59 C 臂钉死】(IOD-1 的 survey)
--     物料【未分类】(materials.waste_classification_code IS NULL)落在一个
--     已配置的库位上:天真的谓词 EXISTS (... = NULL) 为假,于是它会掉进
--     "配了但不含这一类 → 拒绝"。**而未分类不是"被排除",它是没人分过类**
--     (MAT-1 的那条,反向再来一次)。实测:
--         SG-A1 | (NULL = unclassified) | configured_rows=1 | falls through to REFUSE
--
-- (c) 【闸看不见什么 —— 明确的范围外】
--     检查只在【货落地的那一刻】发生。出库腿与状态变更一个字都不查(分类管的是
--     货可以待在哪里,不是能不能离开 —— 拦住一批放错地方的货离开,只会把它焊死
--     在错的地方)。而【配置改变之后已经躺在那里的存量冲突,本系统今天不会告诉
--     任何人】:那批货不会再移动一次给落地腿机会,要发现它必须主动扫全量库存。
--     那是报表/告警问题,已排入告警/通知那一刀。fixture 59 F4 臂把这个状态造
--     出来并断言"搬走它不被拦",顺带让这个盲区在仓库里留下痕迹。
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
    'LOC-1:库位可存放的受控物料分类。一行 = 这个库位可以放这一类。【零行 = 未配置 = 还没决定】,检查对它告警而绝不拒绝 —— 与"配了、但不含这一类"(有人做过决定,该拒)是两回事,压成一个布尔量就是把"没人想过"演成"想过、结论是不行"。【IOD-2 起本表设闸】:判词是 check_location_class(库位, 物料),由四个落地点共用 —— 三个建批次 RPC 与 create_stock_transfer 的入腿。三态:零行告警 IOD_CLASS_UNCONFIGURED_LOCATION;物料未分类告警 IOD_MATERIAL_UNCLASSIFIED(【在已配置库位上也只是告警】—— 未分类不是被排除,是没人分过类,天真的 EXISTS 谓词会把它送进拒绝);配了且不含这一类才拒绝 IOD_CLASS_EXCLUDED。【闸只拦正在落地的货】:出库腿与状态变更永不检查(分类管的是货待在哪里,不是能不能离开);而【配置改变后已经躺在那里的存量冲突,本系统今天不会告诉任何人】—— 那要主动扫全量库存,是报表/告警问题,已排入告警那一刀。';

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
