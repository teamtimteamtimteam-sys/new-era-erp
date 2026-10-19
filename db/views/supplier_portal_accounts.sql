-- db/views/supplier_portal_accounts.sql
-- MES-9a(2026-10-19,MES-9 Step 0 Q7 · Q24,Tim):【一家供应商的门户账号 —— 供应商页上那一块读它】。
--   每一条门户链接一行:挂在哪一位联系人上(今天的名字与邮箱)、登录用的邮箱、开的时刻与人、撤销(时刻 · 人 · 理由)、匿名化、
--   最近一次登录、【还没换掉初始密码】(user_metadata.must_change_password —— 中间件按它把人扣在 /set-password)、是否被封。
--   【属主视图】它要读 auth.users(登录邮箱、最近登录、封禁、那一个标记),而 auth 不在 PostgREST 暴露的架构里;
--   谓词写在视图体里:module.suppliers.view(Q7:看那一块的码就是供应商页的门)。与 user_directory 同一个做法。
--   没有任何密码、令牌、会话的东西出来。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.

CREATE VIEW public.supplier_portal_accounts WITH (security_invoker = off) AS
 SELECT p.id,
    p.supplier_id,
    p.user_id,
    p.contact_id,
    c.name AS contact_name,
    c.email AS contact_email,
    u.email::text AS account_email,
    p.created_at,
    p.created_by,
    p.revoked_at,
    p.revoked_by,
    p.revoked_reason,
    p.anonymised_at,
    u.last_sign_in_at,
    COALESCE((u.raw_user_meta_data ->> 'must_change_password'::text) = 'true'::text, false) AS must_change_password,
    (u.banned_until IS NOT NULL AND u.banned_until > now()) AS banned
   FROM supplier_portal_users p
     JOIN counterparty_contacts c ON c.id = p.contact_id
     LEFT JOIN auth.users u ON u.id = p.user_id
  WHERE has_permission('module.suppliers.view'::text);

COMMENT ON VIEW public.supplier_portal_accounts IS
    'MES-9a:一家供应商的门户账号(供应商页那一块)。属主视图(读 auth.users 的登录邮箱、最近登录、封禁与 must_change_password),谓词 module.suppliers.view 写在视图体里。不出任何密码、令牌或会话。';

REVOKE ALL ON public.supplier_portal_accounts FROM authenticated, anon;
GRANT SELECT ON public.supplier_portal_accounts TO authenticated;
