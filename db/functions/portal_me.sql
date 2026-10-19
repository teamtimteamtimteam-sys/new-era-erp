-- db/functions/portal_me.sql
-- MES-9a(2026-10-19,MES-9 Step 0 §2 · Q10,Tim):【门户外壳的"你是谁"】—— /portal 顶上那一行:哪一家供应商、哪一位联系人、登录用的邮箱。
--   先过 portal_require_link()(角色 · 链接 · 撤销 · 会话)。只说调用者自己那一家、自己那一位;没有任何参数。
--   一样都不多给:不给供应商的银行、条款、评分、状态史、别的联系人,不给任何员工的名字。
--   EXECUTE 只授 supplier_portal(zzz_function_grants.sql;门户可达面 = db/portal-grants-baseline.tsv,判词八)。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_me()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link uuid := portal_require_link();
    v_out  jsonb;
BEGIN
    SELECT jsonb_build_object(
               'supplier', jsonb_build_object('code', s.code, 'name', s.legal_name),
               'contact', jsonb_build_object('name', c.name, 'role', c.role),
               'account_email', u.email,
               'linked_at', p.created_at)
      INTO v_out
      FROM supplier_portal_users p
      JOIN suppliers s ON s.id = p.supplier_id
      JOIN counterparty_contacts c ON c.id = p.contact_id
      JOIN auth.users u ON u.id = p.user_id
     WHERE p.id = v_link;
    RETURN v_out;
END;
$function$;
