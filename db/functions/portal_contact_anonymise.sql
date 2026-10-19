-- db/functions/portal_contact_anonymise.sql
-- MES-9a(2026-10-19,MES-9 Step 0 Q20,Tim):【应请求,把一个已撤销的门户账号背后那位联系人匿名化】。
--   名字换成「Anonymised」,职能、邮箱、电话、备注清空,不再是主联系人,软删,并盖 anonymised_at;链接盖 anonymised_at / anonymised_by。
--   变更记录里关于这位联系人那一行的每一条(新增、每一次修改 —— 包括本函数这一句自己写下的那一条,它的 old 里装着匿名化之前的字)
--   只把 change_log_redactable_columns('counterparty_contacts') 列出的几列涂成 null,盖 redacted_at(anonymise_employee 的同一个做法;
--   change_log 的守卫逐行核对涂抹的形状)。【账号 id 留着】:审计记录里那个账号做过的事照旧挂在它身上(Q20)。
--   登录邮箱(auth.users.email)由服务端动作接着经 auth.admin 换掉 —— auth 架构不由本函数写。
--   门 action.manage_portal_users。没撤销 → PORTAL_ANONYMISE_NEEDS_REVOKE;已经匿名化 → PORTAL_ALREADY_ANONYMISED;链接不在 → PORTAL_LINK_NOT_FOUND。
--   返回 {contact_id, log_rows_redacted}。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_contact_anonymise(p_link_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    l   supplier_portal_users%ROWTYPE;
    v_n integer;
BEGIN
    PERFORM require_permission('action.manage_portal_users');
    SELECT * INTO l FROM supplier_portal_users p WHERE p.id = p_link_id FOR UPDATE;
    IF l.id IS NULL THEN
        RAISE EXCEPTION 'PORTAL_LINK_NOT_FOUND';
    END IF;
    IF l.revoked_at IS NULL THEN
        RAISE EXCEPTION 'PORTAL_ANONYMISE_NEEDS_REVOKE';
    END IF;
    IF l.anonymised_at IS NOT NULL THEN
        RAISE EXCEPTION 'PORTAL_ALREADY_ANONYMISED';
    END IF;
    UPDATE counterparty_contacts
       SET name = 'Anonymised', role = NULL, email = NULL, phone = NULL, notes = NULL, is_primary = false,
           deleted_at = COALESCE(deleted_at, now()), anonymised_at = now(), updated_by = auth.uid()
     WHERE id = l.contact_id;
    UPDATE supplier_portal_users SET anonymised_at = now(), anonymised_by = auth.uid() WHERE id = l.id;
    -- 【必须在上面那句之后】它自己就被 change_log_capture 记了一行,而那一行的 old 里装着匿名化之前的字
    UPDATE change_log c
       SET old = change_log_null_keys(c.old, change_log_redactable_columns(c.table_name)),
           new = change_log_null_keys(c.new, change_log_redactable_columns(c.table_name)),
           redacted_at = clock_timestamp()
     WHERE c.redacted_at IS NULL
       AND c.table_name = 'counterparty_contacts' AND c.row_key ->> 'id' = l.contact_id::text;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('contact_id', l.contact_id, 'log_rows_redacted', v_n);
END;
$function$;
