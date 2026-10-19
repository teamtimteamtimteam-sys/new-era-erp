-- db/functions/portal_export_my_data.sql
-- MES-9a(2026-10-19,MES-9 Step 0 Q20 · PDPA 待办 3,Tim):【一个门户账号导出系统里关于它自己的一切】—— 个人资料访问请求的那一条路。
--   一个门户账号证明"我是谁"的办法就是登录;登录了,它自己按这一个钮就拿得到(docs/pdpa.md 待办 3 对门户账号由此关闭)。
--   先过 portal_require_link()。内容:它的联系人那一行(名字、职能、邮箱、电话 —— 【员工写的内部备注 notes 不给】,那是员工对对方的
--   内部记录,Step 0 §4 的"internal notes"一栏)、它的门户链接(建立、撤销)、它的账号(登录邮箱、建立时刻、最近一次登录)、它属于哪一家供应商
--   (编号与名字)。9c 的证书提交来了以后,它们也进这一份。别的联系人、别的供应商、任何员工:一个字都没有。
--   EXECUTE 只授 supplier_portal。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_export_my_data()
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
               'exported_at', now(),
               'supplier', jsonb_build_object('code', s.code, 'name', s.legal_name),
               'contact', jsonb_build_object('name', c.name, 'role', c.role, 'email', c.email, 'phone', c.phone,
                                             'created_at', c.created_at, 'updated_at', c.updated_at),
               'portal_account', jsonb_build_object('linked_at', p.created_at, 'revoked_at', p.revoked_at),
               'sign_in', jsonb_build_object('email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at))
      INTO v_out
      FROM supplier_portal_users p
      JOIN suppliers s ON s.id = p.supplier_id
      JOIN counterparty_contacts c ON c.id = p.contact_id
      JOIN auth.users u ON u.id = p.user_id
     WHERE p.id = v_link;
    RETURN v_out;
END;
$function$;
