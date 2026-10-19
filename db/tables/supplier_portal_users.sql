-- db/tables/supplier_portal_users.sql
-- MES-9a(2026-10-19,MES-0 Q85 · Q87 · MES-9 Step 0 Q2 · Q5 · Q8 · Q20,Tim):【一个门户账号 = 一家供应商 + 它的一位联系人】。
--
-- 【它是什么】一个 auth.users 账号(与员工一样的登录),外加这一行。这一行在,那个账号的令牌就带 role = supplier_portal
--   (portal_access_token_hook 在每一次签发令牌时查这里),于是它在库里是一个【单独的 Postgres 角色】:
--   它够得着的只有按名字授给 supplier_portal 的东西(db/portal-grants-baseline.tsv,判词八),一样都不从 authenticated 继承。
-- 【一个账号只属于一家】user_id 唯一;同一个人替两家供应商做事 = 两个账号(Step 0 §2)。
--   一位联系人同时最多一个【没撤销的】门户账号(部分唯一索引);撤销之后可以再开一个(新账号、新链接,旧的留着)。
-- 【永远不是员工、永远不持角色】guard_portal_account_separation 在四张表上双向拒(Q5)。
-- 【撤销,不删】revoked_at / revoked_by / revoked_reason(portal_user_revoke:链接撤销 + 删会话;封禁由服务端动作经 auth.admin 做)。
--   应请求匿名化联系人时盖 anonymised_at(portal_contact_anonymise,Q20);账号 id 与记录都留着。
-- 【谁读】供应商页的门户账号那一块:module.suppliers.view(Q7)。Supabase Auth 的 hook 以 supabase_auth_admin 读(只读一条策略)。
--   门户会话自己【不直接读】这张表 —— 它只经 portal_* 函数,而那些函数从 auth.uid() 推出它是谁(没有任何供应商 id 是参数)。
-- 【谁写】只经 portal_user_create_link / portal_user_revoke / portal_contact_anonymise(SECURITY DEFINER,门 action.manage_portal_users)。
--   没有任何 INSERT / UPDATE / DELETE 策略;一次性证明的收尾以 service role 删它自己造的行。
-- 变更记录照常记(豁免仍是 8);它挂在供应商的审计记录下(trail_subject_members 'supplier' 第 7 支)。
--
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.supplier_portal_users (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid NOT NULL UNIQUE REFERENCES auth.users (id) ON DELETE RESTRICT,
    supplier_id     uuid NOT NULL REFERENCES public.suppliers (id) ON DELETE RESTRICT,
    contact_id      uuid NOT NULL REFERENCES public.counterparty_contacts (id) ON DELETE RESTRICT,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    revoked_at      timestamptz,
    revoked_by      uuid,
    revoked_reason  text,
    anonymised_at   timestamptz,
    anonymised_by   uuid,
    CONSTRAINT supplier_portal_users_revoke_reason
        CHECK (revoked_at IS NULL OR NULLIF(btrim(revoked_reason), '') IS NOT NULL),
    CONSTRAINT supplier_portal_users_anonymised_after_revoke
        CHECK (anonymised_at IS NULL OR revoked_at IS NOT NULL)
);

CREATE UNIQUE INDEX supplier_portal_users_one_live_per_contact
    ON public.supplier_portal_users (contact_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_supplier_portal_users_supplier ON public.supplier_portal_users (supplier_id);

COMMENT ON TABLE public.supplier_portal_users IS
    'MES-9a:一个门户账号 = 一家供应商 + 它的一位联系人(Q5)。这一行在,账号的令牌就带 role = supplier_portal(portal_access_token_hook),它在库里只够得着按名授给那个角色的东西(判词八,db/portal-grants-baseline.tsv)。永远不是员工、永远不持角色(guard_portal_account_separation,双向)。撤销不删(portal_user_revoke:撤销 + 删会话;封禁经 auth.admin);应请求匿名化联系人(portal_contact_anonymise)。读 module.suppliers.view;写只经三支 DEFINER 函数(action.manage_portal_users)。';

-- 链接两头的守卫:这个账号不持角色、不是员工(另三张表上挂着反方向那一半)
CREATE TRIGGER trg_supplier_portal_users_separation
    BEFORE INSERT OR UPDATE OF user_id ON public.supplier_portal_users
    FOR EACH ROW EXECUTE FUNCTION public.guard_portal_account_separation();

ALTER TABLE public.supplier_portal_users ENABLE ROW LEVEL SECURITY;
CREATE POLICY "supplier_portal_users select by permission" ON public.supplier_portal_users
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));
-- Supabase Auth 的 hook(portal_access_token_hook,调用者权限)以 supabase_auth_admin 跑,它要读得到这一张表 —— 只读,只给它
CREATE POLICY "supplier_portal_users read by the auth hook" ON public.supplier_portal_users
    AS PERMISSIVE FOR SELECT TO supabase_auth_admin
    USING (true);
GRANT SELECT ON public.supplier_portal_users TO supabase_auth_admin;
REVOKE ALL ON public.supplier_portal_users FROM anon;
