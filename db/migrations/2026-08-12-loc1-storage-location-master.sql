-- db/migrations/2026-08-12-loc1-storage-location-master.sql
-- LOC-1:库位主数据 —— 一张 2026-07-03 就预留下来的表,这一刀把它做完并给它屏幕
--
-- 【这不是新建,是补完】`storage_locations` 是 phase2-cut1(2026-07-03)建的
-- 预留:`inventory_movements.location_id` 从那天起就指着它,而它零行、没有屏幕、
-- 全库没有一行应用代码读它。一张只被外键指着的空表,与一个没有屏幕的机制是
-- 同一件事 —— 所以这一刀按【补完】写,而不是假装它不存在再建一张。
--
-- ─── 三件事写在这里,因为读的人会到这里来找 ────────────────────────────────
--
-- 【一 · zone 只是显示分组,合规逻辑永远不许读它】
-- 它是给人在列表上分堆用的("A 区""冷库"),不是一个受控属性。真正决定
-- 这个库位能放什么的是 storage_location_allowed_classes,那是一张有外键、
-- 有唯一约束、能被断言的表。zone 是一个自由文本 —— 任何读它来做合规判断的
-- 代码,都是在把一个排版决定当成一条规则。
--
-- 【二 · code 的 "SG-" 前缀是约定,【故意】不用 CHECK 钉死】
-- 今天只有一个法人实体,把 "SG-" 写进 CHECK 等于把"只有一个实体"这件事
-- 焊进 schema —— 而多实体是 Doc 2/3 明写要来的(见 docs/as-built-divergences.md
-- 第 1 条:实体维度今天【完全不存在】,那一天是一次跨全表的迁移)。
-- 一条今天为真、明天要拆的约束,比没有约束更贵。约定写在界面提示与本注释里。
--
-- 【三 · 停用是唯一的下架路径,而它是一条【具名】政策】
-- 库位会被库存流水指着(ON DELETE RESTRICT),所以在今天之前"删不掉"这件事
-- 是【外键顺手挡下来的】,不是任何人决定的 —— 而一条靠副作用成立的规则,
-- 读代码的人看不见,第一次遇到 23503 的人只会以为自己撞了个技术故障。
-- 现在:DELETE 的 RLS 策略撤掉,加一个具名守卫触发器
-- `LOCATION_NO_HARD_DELETE|<code>`。外键的 RESTRICT 留着 —— 两道锁不冲突,
-- 但站在最前面的那一道现在会自报姓名。同 FIN-31 给 processing_cost_entries
-- 的 `guard_cost_entry_no_hard_delete`,也正是 Doc 2 原则 7 本来就要的那件事。
-- `deleted_at` 因此【物理去掉】:一行不能有两个"下架"状态,而它今天零行、
-- 没有任何视图/策略/函数读它(线上目录核实过),现在不去掉,以后就得靠
-- 注释解释两个状态谁说了算 —— 那正是这个仓库反复付过账的形状。
--
-- ─── storage_location_allowed_classes 的两条语义 ───────────────────────────
--
-- 【(a) 零行 = 未配置 = "还没决定"】将来的检查对它【告警,绝不拒绝】。
-- 它与"配了、但不含这一类"是两回事 —— 后者是一个有人做过的决定,该拒。
-- 把两者压成一个"不在允许清单里"的布尔量,就是把"没人想过"演成"想过、
-- 结论是不行":一个不会响的拦截比没有拦截更坏,因为人以为系统在替他判断。
-- 同 MAT-1 的「未分类不是非受控」、METAL-1 的 `no_reference`、
-- MAT-1 报告里那条被否掉的 (a) 方案 —— 第三种状态不是前两种里的哪一种。
--
-- 【(b) 这一刀只【记录】,不设闸】没有任何东西会因为这张表而拒绝一次收货或
-- 移库。落闸的地方是【出入库单据那一刀】。明写在这里,是因为一张叫
-- "allowed_classes" 的表看起来就像已经在拦了,而"以为有拦截"比"知道没有"更坏。
--
-- 【分类用 code 不用 id】`waste_classifications` 的主键就是 `code text`
-- (MAT-1 如此,与 certificate_types 同形),不存在 uuid 主键可引。
-- 而【合规逻辑将来要读的是 `is_controlled`,不是 code 字符串】——
-- 分类的名字会增删改,"受不受控"才是它的语义(MAT-1 把这句话写在列注释里)。
-- 另外:`materials.waste_classification_code IS NULL` 的意思是【未分类】,
-- 永远不等于 `non_focused` —— 前者是没人分过,后者是有人分过、结论是不受控。
--
-- 镜像:db/tables/{storage_locations,storage_location_allowed_classes}.sql、
--       db/functions/guard_storage_location_no_hard_delete.sql;
-- 行为断言:fixture 55。

BEGIN;

-- ═══ 0 · storage_locations:补齐主数据该有的形状 ════════════════════════════
-- 零行,所以 SET NOT NULL 与 NOT NULL DEFAULT 都不需要回填。
ALTER TABLE public.storage_locations
    ALTER COLUMN name SET NOT NULL,
    ADD COLUMN zone text,
    ADD COLUMN is_active boolean NOT NULL DEFAULT true,
    DROP COLUMN deleted_at;

COMMENT ON TABLE public.storage_locations IS
    'LOC-1:库位主数据。【没有硬删路径】—— 下架只有停用(is_active=false),由 guard_storage_location_no_hard_delete 具名拒绝,inventory_movements 的外键 RESTRICT 是第二道。code 约定以 "SG-" 起头,【故意不用 CHECK 钉死】:今天只有一个实体,把它焊进 schema 就是把"只有一个实体"变成一条 schema 事实,而多实体是计划中的。';

COMMENT ON COLUMN public.storage_locations.zone IS
    'LOC-1:【仅用于显示分组】(列表上分堆:A 区、冷库…)。合规逻辑永远不许读它 —— 决定这个库位能放什么的是 storage_location_allowed_classes,那是有外键、有唯一约束、断言得了的表;zone 是自由文本。读 zone 做合规判断,等于把一个排版决定当成一条规则。';

COMMENT ON COLUMN public.storage_locations.is_active IS
    'LOC-1:停用标记 —— 这张表【唯一】的下架路径。停用的库位不再出现在新单据的选择器里,已经引用它的历史流水一个字不动。硬删由具名守卫拒绝,不是靠外键顺手挡。';

-- 停用是唯一下架路径:撤掉 DELETE 策略,换一条会自报姓名的守卫。
DROP POLICY "storage_locations delete by permission" ON public.storage_locations;

CREATE OR REPLACE FUNCTION public.guard_storage_location_no_hard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 停用(UPDATE is_active=false)才是这张表的下架语义:它保留库位的身份,
    -- 让历史流水指着的那一行继续说得出自己是谁。硬删两件都不做。
    -- 【为什么要具名】此前"删不掉"是 inventory_movements 的外键顺手挡下来的:
    -- 一条靠副作用成立的规则,读代码的人看不见,撞上的人只看到一个 23503。
    RAISE EXCEPTION 'LOCATION_NO_HARD_DELETE|%', OLD.code;
END;
$function$;

CREATE TRIGGER trg_storage_locations_no_hard_delete
    BEFORE DELETE ON public.storage_locations
    FOR EACH ROW EXECUTE FUNCTION public.guard_storage_location_no_hard_delete();

-- ═══ 1 · storage_location_allowed_classes:这个库位可以放哪几类 ═════════════
-- 一行 = 一个"可以"。零行 = 未配置(见文件头 (a));删掉一行 = 不再允许那一类
-- —— "不在表里"就是"不允许"的表达方式,与 pricing_formula_metals 同形
-- (docs/as-built-divergences.md 第 2 条已把这类物理删除记在案)。
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
-- 既有的四条策略同一条判断,不另立一套。
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

COMMIT;
