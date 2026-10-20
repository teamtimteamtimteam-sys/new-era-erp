-- db/tables/account_settings.sql
-- MES-9a(2026-10-19,MES-9 Step 0 §9 · Q24 · Q26,Tim):【账号那一侧的待补的值 —— 单行】。
--   V38  initial_password_valid_days   一个当面交出去的初始密码,在第一次登录之前有效几天。
--        空 = Not yet set:/settings/accounts 与供应商页的门户账号那一块照直说「初始密码不会过期」。
--   V40  password_min_length           项目的密码最短长度(Supabase 的项目设置;今天是 Supabase 的默认 6)。Tim 在 Supabase 改了以后在这里记下那个数。
--   两个都是【第一个真实供应商账号之前】由 Tim 给(MES-9 Step 0 §15);引导为空,不猜。
--   ★ 今天两个都【不被执行】(docs/known-issues.md:MES9A-V38-NOT-ENFORCED · MES9A-V40-IS-A-RECORD)——
--     这里存的是 Tim 定的值,好让待补的值页面在它们还空着时说出来;执行那一半是登记在案的后续。
--   V39  portal_upload_max_bytes · portal_upload_types   供应商在门户上传一份证书的上限:每份最大字节数、收哪几种文件(MIME)。
--        ★ Tim 2026-10-20(MES-9c 委托书)定了:10 MB(10,485,760 字节)· PDF / JPEG / PNG —— 所以这两列【带默认值】,引导与线上都从第一天
--        就是这个数(MES-9c 迁移以 ADD COLUMN … DEFAULT 加上,线上那一行当场得到它,不经一次 UPDATE)。清空它 = 门户上传按名拒
--        (PORTAL_UPLOAD_LIMITS_NOT_SET),待补的值页面列出 V39。执行在 portal_submission_begin(任何字节存下之前)与桶 portal-uploads。
--        改它要一支迁移(没有设值的界面 —— Tim 定的数,不是操作员的日常设定)。
--   由 action.manage_permissions 经 set_account_setting 改(V38 · V40);修改史在变更记录里。
--   RUNTIME CONFIG:Tim 设一次,线上就与本文件不同 —— 那是系统在正常工作。
--
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.account_settings (
    id                          boolean PRIMARY KEY DEFAULT true CHECK (id),
    initial_password_valid_days integer CHECK (initial_password_valid_days IS NULL OR initial_password_valid_days > 0),
    password_min_length         integer CHECK (password_min_length IS NULL OR password_min_length >= 6),
    updated_at                  timestamptz NOT NULL DEFAULT now(),
    updated_by                  uuid DEFAULT auth.uid(),
    -- ── MES-9c 追加的列(ALTER 加的列排在末尾):V39,Tim 2026-10-20 定的值作默认 ──
    portal_upload_max_bytes     bigint DEFAULT 10485760 CHECK (portal_upload_max_bytes IS NULL OR portal_upload_max_bytes > 0),
    portal_upload_types         text[] DEFAULT ARRAY['application/pdf'::text, 'image/jpeg'::text, 'image/png'::text]
                                CHECK (portal_upload_types IS NULL OR cardinality(portal_upload_types) > 0)
);

COMMENT ON TABLE public.account_settings IS
    'MES-9a:账号那一侧的待补的值(单行)。V38 = initial_password_valid_days(初始密码在第一次登录之前有效几天);V40 = password_min_length(项目的密码最短长度,Supabase 设置 —— 这里记 Tim 定的数)。引导为空;今天两者都不被执行(known issues MES9A-V38-NOT-ENFORCED · MES9A-V40-IS-A-RECORD)。action.manage_permissions 经 set_account_setting 改。MES-9c:V39 = portal_upload_max_bytes · portal_upload_types(门户上传的上限,Tim 2026-10-20 定 10 MB · PDF / JPEG / PNG,作默认值;portal_submission_begin 执行)。';

INSERT INTO public.account_settings (id) VALUES (true);

CREATE TRIGGER trg_account_settings_updated_at
    BEFORE UPDATE ON public.account_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.account_settings ENABLE ROW LEVEL SECURITY;
-- 读:管账号的人(/settings/accounts)与看供应商的人(供应商页的门户账号那一块要说初始密码会不会过期)。写只经函数。
CREATE POLICY "account_settings select by permission" ON public.account_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['action.manage_permissions'::text, 'module.suppliers.view'::text]));
GRANT SELECT ON public.account_settings TO authenticated;
REVOKE ALL ON public.account_settings FROM anon;
