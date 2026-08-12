-- db/tables/storage_locations.sql
-- 库位主数据 —— 表 + updated_at 触发器 + 硬删守卫 + RLS。
-- 约定与既有表一致:
--   * 审计字段 created_by/updated_by 默认 auth.uid(),created_at/updated_at 默认 now()
--   * updated_at 由共享的 update_updated_at() 自动顶起(不要重定义它)
--   * RLS:读 module.inventory.view,写 module.inventory.edit
--
-- NOTE: introduced by db/migrations/2026-07-03-phase2-cut1-inventory-ledger.sql.
-- LOC-1(2026-08-12,db/migrations/2026-08-12-loc1-storage-location-master.sql):
--   name 补 NOT NULL;新增 zone / is_active;【去掉 deleted_at】;
--   撤掉 DELETE 策略,改由具名守卫触发器拒绝。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.
--
-- ─── 三条读的人会来找的说明 ────────────────────────────────────────────────
--
-- 【zone 只是显示分组,合规逻辑永远不许读它】它是列表上分堆用的自由文本。
-- 决定这个库位能放什么的是 storage_location_allowed_classes —— 有外键、有唯一
-- 约束、断言得了。读 zone 做合规判断,是把一个排版决定当成一条规则。
--
-- 【code 约定以 "SG-" 起头,故意不用 CHECK 钉死】今天只有一个法人实体,把
-- "SG-" 写进 CHECK 就是把"只有一个实体"焊进 schema —— 而多实体是计划中的
-- (docs/as-built-divergences.md 第 1 条:实体维度今天完全不存在,那一天是一次
-- 跨全表迁移)。一条今天为真、明天要拆的约束比没有约束更贵。
--
-- 【没有硬删路径,而这是一条具名政策】下架只有停用(is_active=false)。
-- LOC-1 之前"删不掉"是 inventory_movements 的外键顺手挡下来的 —— 一条靠副作用
-- 成立的规则,读代码的人看不见,撞上的人只看到一个 23503。现在最前面站着
-- guard_storage_location_no_hard_delete,它自报姓名;外键的 RESTRICT 留作第二道。
-- `deleted_at` 因此被物理去掉:一行不能有两个"下架"状态。

CREATE TABLE public.storage_locations (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text NOT NULL UNIQUE,
    name        text NOT NULL,
    notes       text,
    created_by  uuid DEFAULT auth.uid(),
    updated_by  uuid DEFAULT auth.uid(),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    -- ── LOC-1 追加(ALTER 加的列排在末尾,与线上 ordinal 一致)──────────────
    zone        text,
    is_active   boolean NOT NULL DEFAULT true
);

COMMENT ON TABLE public.storage_locations IS
    'LOC-1:库位主数据。【没有硬删路径】—— 下架只有停用(is_active=false),由 guard_storage_location_no_hard_delete 具名拒绝,inventory_movements 的外键 RESTRICT 是第二道。code 约定以 "SG-" 起头,【故意不用 CHECK 钉死】:今天只有一个实体,把它焊进 schema 就是把"只有一个实体"变成一条 schema 事实,而多实体是计划中的。';

COMMENT ON COLUMN public.storage_locations.zone IS
    'LOC-1:【仅用于显示分组】(列表上分堆:A 区、冷库…)。合规逻辑永远不许读它 —— 决定这个库位能放什么的是 storage_location_allowed_classes,那是有外键、有唯一约束、断言得了的表;zone 是自由文本。读 zone 做合规判断,等于把一个排版决定当成一条规则。';

COMMENT ON COLUMN public.storage_locations.is_active IS
    'LOC-1:停用标记 —— 这张表【唯一】的下架路径。停用的库位不再出现在新单据的选择器里,已经引用它的历史流水一个字不动。硬删由具名守卫拒绝,不是靠外键顺手挡。';

CREATE TRIGGER trg_storage_locations_updated_at
    BEFORE UPDATE ON public.storage_locations
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 守卫函数在 db/functions/guard_storage_location_no_hard_delete.sql。
CREATE TRIGGER trg_storage_locations_no_hard_delete
    BEFORE DELETE ON public.storage_locations
    FOR EACH ROW EXECUTE FUNCTION public.guard_storage_location_no_hard_delete();

-- 【重复库位号自报姓名】code 上的 UNIQUE 给的是【保证】,这个触发器给的是
-- 【名字】(LOC_CODE_EXISTS|<code>)。两者不互相取代:并发插入会同时通过
-- 触发器里的 EXISTS(互相看不见未提交的行),那时挡住第二个的是唯一索引;
-- 而人看得见的那条路上,先撞到的是触发器,拿到的是一句翻译得了的业务错误。
-- 守卫函数在 db/functions/guard_storage_location_code_unique.sql。
CREATE TRIGGER trg_storage_locations_code_named
    BEFORE INSERT OR UPDATE OF code ON public.storage_locations
    FOR EACH ROW EXECUTE FUNCTION public.guard_storage_location_code_unique();

ALTER TABLE public.storage_locations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "storage_locations select by permission"
    ON public.storage_locations
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inventory.view'::text));

CREATE POLICY "storage_locations insert by permission"
    ON public.storage_locations
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inventory.edit'::text));

CREATE POLICY "storage_locations update by permission"
    ON public.storage_locations
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inventory.edit'::text)) WITH CHECK (has_permission('module.inventory.edit'::text));

-- 【没有 DELETE 策略,这是刻意的】LOC-1 撤掉了它。下架 = 停用;硬删由
-- trg_storage_locations_no_hard_delete 具名拒绝。
