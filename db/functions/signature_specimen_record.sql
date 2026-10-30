-- db/functions/signature_specimen_record.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q4):【登记签署人本人刚传上来的签字样本】—— 服务端动作把画好的签名重编码成 PNG、以本人的会话传到
--   signing-assets 的 specimens/<本人员工 id>/<p_specimen_id>.png,然后调这一支。它在【之前那一张】上记 superseded_at(换掉留历史),写新的一行。
--   按名拒:调用者没有员工档案或此刻不在签署人名单上 → CONTRACT_SIGN_NOT_SIGNATORY;对象不在 → SIGNING_ASSET_NOT_STORED;
--   不是 PNG → SIGNING_ASSET_TYPE;sha256 不是 64 位小写十六进制 → SIGNING_ASSET_HASH_INVALID。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.signature_specimen_record(p_specimen_id uuid, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp  uuid := current_user_employee();
    v_path text;
    v_meta jsonb;
BEGIN
    IF v_emp IS NULL OR NOT contract_signatory_active() THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_NOT_SIGNATORY';
    END IF;
    IF p_sha256 IS NULL OR p_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'SIGNING_ASSET_HASH_INVALID';
    END IF;
    v_path := 'specimens/' || v_emp::text || '/' || p_specimen_id::text || '.png';
    SELECT COALESCE(o.metadata, '{}'::jsonb) INTO v_meta FROM storage.objects o WHERE o.bucket_id = 'signing-assets' AND o.name = v_path;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SIGNING_ASSET_NOT_STORED';
    END IF;
    IF v_meta ->> 'mimetype' IS DISTINCT FROM 'image/png' OR NOT (v_meta ? 'size') THEN
        RAISE EXCEPTION 'SIGNING_ASSET_TYPE';
    END IF;
    UPDATE signature_specimens SET superseded_at = now() WHERE employee_id = v_emp AND superseded_at IS NULL;
    INSERT INTO signature_specimens (id, employee_id, file_path, file_size, sha256, created_by)
    VALUES (p_specimen_id, v_emp, v_path, (v_meta ->> 'size')::bigint, p_sha256, auth.uid());
    RETURN jsonb_build_object('id', p_specimen_id, 'path', v_path);
END;
$function$;
