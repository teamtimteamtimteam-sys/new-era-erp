-- db/tables/portal_document_downloads.sql
-- MES-9b(2026-10-19,MES-9 Step 0 Q22,Tim):【门户下载记录】—— 一位门户账号每要走一份签发档,这里就多一行:谁(账号 · 链接 · 供应商)、
--   哪一份(种类 · 签发记录 id · 单据号 · 版本 · 桶里的路径 · 当时记下的 sha256)、什么时候。只记门户账号(员工的下载不记 —— docs/pdpa.md 的决定照旧)。
--
-- 【只追加】guard_portal_document_download_append_only:改、删、清空一律按名拒。
-- 【谁写】只经 portal_document_open()(SECURITY DEFINER,只授 supplier_portal):它先过 portal_require_link(角色 · 链接 · 撤销 · 会话),
--   再确认那一份签发档属于调用者自己那一家,然后写下这一行、交出路径与哈希。没有任何 INSERT / UPDATE / DELETE 策略,authenticated 与 anon
--   连写的授权都没有 —— 门户会话写得进的【只有】它自己的这几行,而且只经那一支函数(委托书:门户用户除此之外什么都写不了)。
-- 【它也是存储的钥匙】门户会话读桶里的那一份 PDF 时,存储策略(portal_can_read_object)要求【这位账号刚刚为这一个对象写下过一行】
--   (两分钟内)—— 于是绕过这张表直接去桶里取字节是取不到的:每一次真正的取字节前面都有一行记录。
-- 【谁读】员工:module.suppliers.view(供应商页门户那一块,与门户账号那一张同一个码)。门户会话自己不直接读。
-- 【变更记录】第九张豁免(change_log_exclusions):它本身就是一份只追加的日志,再记一遍是把量翻一倍而不多一个事实(MES-1 那一类)。
--
-- NOTE: introduced by db/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.portal_document_downloads (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    portal_user_id  uuid NOT NULL REFERENCES public.supplier_portal_users (id) ON DELETE RESTRICT,
    user_id         uuid NOT NULL,
    supplier_id     uuid NOT NULL REFERENCES public.suppliers (id) ON DELETE RESTRICT,
    document_kind   text NOT NULL CHECK (document_kind IN ('purchase_order', 'supplier_statement', 'cod')),
    issue_id        uuid NOT NULL,
    document_code   text NOT NULL,
    version         integer CHECK (version IS NULL OR version >= 1),
    bucket_id       text NOT NULL,
    file_path       text NOT NULL,
    sha256          text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    downloaded_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT portal_document_downloads_version_shape
        CHECK ((document_kind = 'cod') = (version IS NULL))
);

CREATE INDEX idx_portal_document_downloads_supplier ON public.portal_document_downloads (supplier_id, downloaded_at DESC);
CREATE INDEX idx_portal_document_downloads_object ON public.portal_document_downloads (portal_user_id, bucket_id, file_path, downloaded_at DESC);

COMMENT ON TABLE public.portal_document_downloads IS
    'MES-9b:门户下载记录(Q22)—— 门户账号每要走一份签发档一行(谁 · 哪一份 · 什么时候)。只追加;只经 portal_document_open() 写;它也是存储的钥匙(portal_can_read_object 要求两分钟内有这一行)。员工读 module.suppliers.view。变更记录的第九张豁免。';

CREATE TRIGGER trg_portal_document_downloads_append_only
    BEFORE UPDATE ON public.portal_document_downloads
    FOR EACH ROW EXECUTE FUNCTION public.guard_portal_document_download_append_only();
CREATE TRIGGER trg_portal_document_downloads_no_delete
    BEFORE DELETE OR TRUNCATE ON public.portal_document_downloads
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_portal_document_download_append_only();

ALTER TABLE public.portal_document_downloads ENABLE ROW LEVEL SECURITY;
CREATE POLICY "portal_document_downloads select by permission" ON public.portal_document_downloads
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));
REVOKE ALL ON public.portal_document_downloads FROM authenticated, anon;
GRANT SELECT ON public.portal_document_downloads TO authenticated;
