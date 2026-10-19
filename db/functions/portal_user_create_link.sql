-- db/functions/portal_user_create_link.sql
-- MES-9a(2026-10-19,MES-0 Q87 · MES-9 Step 0 Q5 · Q6 · Q7,Tim):【把一个刚建出来的登录账号挂到一家供应商的一位联系人上】。
--   供应商页上「给这位联系人一个门户登录」的第二步:第一步是服务端动作以 service role 建出 auth 账号(初始密码当面交、首次登录必须换,
--   与员工账号同一条路 —— 没有邮件、没有邀请表,Q6);这一步写链接。门 action.manage_portal_users(admin · cco,Q87)。
--   判据(都在库里,屏幕不做第二份):
--     供应商在、没删 → 否则 PORTAL_SUPPLIER_NOT_FOUND;
--     联系人属于这家、没删、没匿名化 → 否则 PORTAL_CONTACT_NOT_OF_SUPPLIER;联系人有邮箱 → 否则 PORTAL_CONTACT_NO_EMAIL(Q5:登录用的就是它的邮箱);
--     账号在、它的邮箱就是这位联系人的邮箱(不分大小写)→ 否则 PORTAL_EMAIL_NOT_CONTACT;
--     这位联系人没有一个没撤销的门户账号 → 否则 PORTAL_CONTACT_ALREADY_LINKED;这个账号没有挂过 → 否则 PORTAL_ACCOUNT_ALREADY_LINKED;
--     账号不持角色、不是员工 → guard_portal_account_separation 按名拒(PORTAL_ACCOUNT_HAS_ROLE / PORTAL_ACCOUNT_IS_EMPLOYEE)。
--   一个账号 = 一家供应商 + 它的一位联系人;同一个人替两家供应商做事 = 两个账号(Step 0 §2)。返回链接的 id。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_user_create_link(p_user_id uuid, p_supplier_id uuid, p_contact_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_email text;
    v_id    uuid;
BEGIN
    PERFORM require_permission('action.manage_portal_users');
    IF NOT EXISTS (SELECT 1 FROM suppliers s WHERE s.id = p_supplier_id AND s.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'PORTAL_SUPPLIER_NOT_FOUND';
    END IF;
    SELECT c.email INTO v_email FROM counterparty_contacts c
     WHERE c.id = p_contact_id AND c.supplier_id = p_supplier_id AND c.deleted_at IS NULL AND c.anonymised_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PORTAL_CONTACT_NOT_OF_SUPPLIER';
    END IF;
    IF NULLIF(btrim(v_email), '') IS NULL THEN
        RAISE EXCEPTION 'PORTAL_CONTACT_NO_EMAIL';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id AND lower(u.email) = lower(btrim(v_email))) THEN
        RAISE EXCEPTION 'PORTAL_EMAIL_NOT_CONTACT';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users p WHERE p.contact_id = p_contact_id AND p.revoked_at IS NULL) THEN
        RAISE EXCEPTION 'PORTAL_CONTACT_ALREADY_LINKED';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users p WHERE p.user_id = p_user_id) THEN
        RAISE EXCEPTION 'PORTAL_ACCOUNT_ALREADY_LINKED';
    END IF;
    INSERT INTO supplier_portal_users (user_id, supplier_id, contact_id, created_by)
    VALUES (p_user_id, p_supplier_id, p_contact_id, auth.uid())
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;
