-- db/tables/account_settings.sql
-- MES-9a(2026-10-19,MES-9 Step 0 §9 · Q24 · Q26,Tim):【账号那一侧的待补的值 —— 单行】。
--   V38  initial_password_valid_days   一个当面交出去的初始密码,在第一次登录之前有效几天。
--        空 = Not yet set:/settings/accounts 与供应商页的门户账号那一块照直说「初始密码不会过期」。
--   V40  password_min_length           项目的密码最短长度(Supabase 的项目设置;今天是 Supabase 的默认 6)。Tim 在 Supabase 改了以后在这里记下那个数。
--   两个都是【第一个真实供应商账号之前】由 Tim 给(MES-9 Step 0 §15);引导为空,不猜。
--   ★ 今天两个都【不被执行】(docs/known-issues.md:MES9A-V38-NOT-ENFORCED · MES9A-V40-IS-A-RECORD)——
--     这里存的是 Tim 定的值,好让待补的值页面在它们还空着时说出来;执行那一半是登记在案的后续。
--   由 action.manage_permissions 经 set_account_setting 改;修改史在变更记录里。
--   RUNTIME CONFIG:Tim 设一次,线上就与本文件不同 —— 那是系统在正常工作。
--
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.account_settings (
    id                          boolean PRIMARY KEY DEFAULT true CHECK (id),
    initial_password_valid_days integer CHECK (initial_password_valid_days IS NULL OR initial_password_valid_days > 0),
    password_min_length         integer CHECK (password_min_length IS NULL OR password_min_length >= 6),
    updated_at                  timestamptz NOT NULL DEFAULT now(),
    updated_by                  uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.account_settings IS
    'MES-9a:账号那一侧的待补的值(单行)。V38 = initial_password_valid_days(初始密码在第一次登录之前有效几天);V40 = password_min_length(项目的密码最短长度,Supabase 设置 —— 这里记 Tim 定的数)。引导为空;今天两者都不被执行(known issues MES9A-V38-NOT-ENFORCED · MES9A-V40-IS-A-RECORD)。action.manage_permissions 经 set_account_setting 改。';

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
