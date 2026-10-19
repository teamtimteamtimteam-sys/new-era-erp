-- db/functions/portal_user_revoke.sql
-- MES-9a(2026-10-19,MES-0 Q85 · MES-9 Step 0 Q8 · Q20,Tim):【撤销一个门户账号 —— 下一次调用就拒】。
--   撤销 = ① 链接记下撤销(时刻、谁、理由 —— 理由必填,PORTAL_REVOKE_REASON_REQUIRED)② 删掉这个账号在 auth.sessions 里的每一个会话
--   (= 全局登出:刷新令牌随会话级联删掉;已经签出去的访问令牌在过期前仍验得过签,而每一支门户函数都问"会话还在吗"与"撤销了吗",
--   所以它的下一次调用就是 PORTAL_ACCESS_REVOKED)③ 封禁由服务端动作接着经 auth.admin 做(换不了新令牌)—— auth 的封禁不在这里写,
--   与员工账号的停用同一条路(app/settings/accounts/accountActions.ts)。账号与它的记录都留着(Q20:撤销 + 封禁,不删)。
--   门 action.manage_portal_users。已经撤销的再撤 → PORTAL_ALREADY_REVOKED;链接不在 → PORTAL_LINK_NOT_FOUND。
--   返回 {sessions_ended}。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_user_revoke(p_link_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid;
    v_rev  timestamptz;
    v_n    integer;
BEGIN
    PERFORM require_permission('action.manage_portal_users');
    SELECT p.user_id, p.revoked_at INTO v_user, v_rev FROM supplier_portal_users p WHERE p.id = p_link_id FOR UPDATE;
    IF v_user IS NULL THEN
        RAISE EXCEPTION 'PORTAL_LINK_NOT_FOUND';
    END IF;
    IF v_rev IS NOT NULL THEN
        RAISE EXCEPTION 'PORTAL_ALREADY_REVOKED';
    END IF;
    IF NULLIF(btrim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'PORTAL_REVOKE_REASON_REQUIRED';
    END IF;
    UPDATE supplier_portal_users
       SET revoked_at = now(), revoked_by = auth.uid(), revoked_reason = btrim(p_reason)
     WHERE id = p_link_id;
    DELETE FROM auth.sessions s WHERE s.user_id = v_user;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('sessions_ended', v_n, 'user_id', v_user);
END;
$function$;
