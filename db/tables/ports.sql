-- db/tables/ports.sql
-- LOG-1a。镜像与 db/migrations/2026-08-19-log1a-*.sql 同源。

CREATE TABLE public.ports (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code       text NOT NULL UNIQUE,
    name       text NOT NULL,
    country    text,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.ports IS
'LOG-1a:港口主数据。code 惯例是 UN/LOCODE,但【不做 CHECK】—— 内河码头与陆路口岸未必有 LOCODE,一条拦得住真实数据的格式检查比没有检查坏。
country 与 suppliers.country 一样是【自由文本】:本仓库没有国家主数据表,本刀也不建一张(LOG-0 已确认并由 Tim 定下)。';

ALTER TABLE public.ports ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ports select" ON public.ports
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.logistics.view'::text));
CREATE POLICY "ports write" ON public.ports
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.ports
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.purchasing.edit');
