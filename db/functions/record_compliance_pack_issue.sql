-- db/functions/record_compliance_pack_issue.sql
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q16,Tim):【记下一份合规包的字节】—— PDF 已经由路由从冻下来的 payload 渲染、传进私有桶
--   compliance-documents,这里落它的路径与 sha256(compliance_pack_issues,只追加,一份包可以有好几版)。门 action.compliance_pack。
--   照分析证书那一份写:包要在(COMPLIANCE_PACK_NOT_FOUND)、没被取代(COMPLIANCE_PACK_SUPERSEDED|<号>|<理由> —— 被取代的不再交出去,
--   既有的版本仍然读得到);路径必须是 <包 id>/…(COMPLIANCE_PACK_ISSUE_PATH_INVALID|<号>);哈希必须是 64 位十六进制、一律小写存
--   (COMPLIANCE_PACK_SHA_INVALID);同一串字节在同一份包上只记一次(COMPLIANCE_PACK_BYTES_ALREADY_RECORDED|<号>|<版本>)。
--   版本由这里裁决(锁住那一行)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.record_compliance_pack_issue(p_pack_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p    compliance_packs%ROWTYPE;
    v_sha  text := lower(btrim(COALESCE(p_sha256, '')));
    v_next integer;
    v_had  integer;
BEGIN
    PERFORM require_permission('action.compliance_pack');

    SELECT * INTO v_p FROM compliance_packs WHERE id = p_pack_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_NOT_FOUND|%', COALESCE(p_pack_id::text, '?');
    END IF;
    IF v_p.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_SUPERSEDED|%|%', v_p.code, COALESCE(v_p.superseded_reason, '');
    END IF;
    IF p_file_path IS NULL OR p_file_path NOT LIKE v_p.id::text || '/%' THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_ISSUE_PATH_INVALID|%', v_p.code;
    END IF;
    IF v_sha !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_SHA_INVALID';
    END IF;
    SELECT version INTO v_had FROM compliance_pack_issues WHERE pack_id = p_pack_id AND sha256 = v_sha;
    IF FOUND THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_BYTES_ALREADY_RECORDED|%|%', v_p.code, v_had;
    END IF;

    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM compliance_pack_issues WHERE pack_id = p_pack_id;
    INSERT INTO compliance_pack_issues (pack_id, version, file_path, sha256, issued_by)
    VALUES (p_pack_id, v_next, p_file_path, v_sha, auth.uid());

    RETURN jsonb_build_object('pack_id', p_pack_id, 'code', v_p.code, 'version', v_next, 'file_path', p_file_path, 'sha256', v_sha);
END;
$function$
