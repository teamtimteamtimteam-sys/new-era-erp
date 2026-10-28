-- db/tables/saved_views.sql
-- TABLE-FEATURES-3(Tim 2026-10-25 Q3 · 2026-10-26 Q1–Q3):一个人在一张列表上存下的视图 —— 筛选与排序,存成地址的查询串。
--
-- NOTE: introduced by db/migrations/2026-10-26-table-features-3-saved-views-and-reject-reasons.sql.
-- First-run script (plain CREATEs).
--
-- 【只属于一个人】Q3:per user only(分享以后再说)。RLS 四条策略都锁在 user_id = auth.uid() —— 与 notification_reads 同一个形状:
--   它记的是"我想这样看",那句话只有本人说得出,所以不装写闸(enforce_write_permission):那不是一个权限问题(fixture 198 点名豁免)。
-- 【一张表,不是 cookie】与 IA-BUILD-1 的 user_dock 同一条理由(Tim):视图要跟着人从手机走到桌面,cookie 是跟着设备的。
-- 【query】地址里 ? 之后那一段,去掉翻页与一次性参数(lib/savedViews.ts);存视图时日期正好是一个快捷区间,
--   存成 date_preset=<名>,打开时按那一天重新算(Tim 2026-10-26 Q2)。
-- 【is_default】每人每张列表至多一个(部分唯一索引);只在地址里什么都没有时才套用(Q3,lib/savedViews.ts applyDefaultView)。
-- 【list_key】列表的路由(/finance/expenses);只认路由的形状。
-- 【不进变更记录】每个读者自己的屏幕偏好,没有业务含义 —— change_log_exclusions 里第十张(与 notification_reads 同一类)。
-- 【anon 什么都没有】线上新表本就不给 anon(COD-2 的默认权限);这里照写,好让重建与线上一致(判词六)。

CREATE TABLE public.saved_views (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users (id) ON DELETE CASCADE,
    list_key    text NOT NULL CHECK (list_key ~ '^/[a-z0-9/_-]*$'),
    name        text NOT NULL CHECK (btrim(name) <> '' AND char_length(name) <= 60),
    query       text NOT NULL CHECK (char_length(query) <= 2000),
    is_default  boolean NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT saved_views_name_unique UNIQUE (user_id, list_key, name)
);

CREATE UNIQUE INDEX saved_views_one_default ON public.saved_views (user_id, list_key) WHERE is_default;

COMMENT ON TABLE public.saved_views IS
    'TABLE-FEATURES-3(Tim 2026-10-25 Q3 · 2026-10-26 Q1–Q3):一个人在一张列表上存下的视图(筛选与排序,存成查询串)。只属于本人:RLS 锁在 user_id = auth.uid();每人每张列表至多一个默认(部分唯一索引),只在地址为空时套用。日期正好是快捷区间时存 date_preset=<名>,打开时重算。不进变更记录(屏幕偏好)。';

CREATE TRIGGER trg_saved_views_updated_at
    BEFORE UPDATE ON public.saved_views
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.saved_views ENABLE ROW LEVEL SECURITY;

CREATE POLICY "saved_views select own"
    ON public.saved_views
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));

CREATE POLICY "saved_views insert own"
    ON public.saved_views
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY "saved_views update own"
    ON public.saved_views
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (user_id = (SELECT auth.uid()))
    WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY "saved_views delete own"
    ON public.saved_views
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (user_id = (SELECT auth.uid()));

REVOKE ALL ON public.saved_views FROM anon;
REVOKE ALL ON public.saved_views FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.saved_views TO authenticated;
