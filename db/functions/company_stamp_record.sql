-- db/functions/company_stamp_record.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · Q3):【登记 admin 刚传上来的公司印章】—— 服务端动作把上传的图重编码成 PNG、传到 signing-assets 的
--   stamps/<p_stamp_id>.png,然后调这一支:之前在用的那一张记 superseded_at(换掉留历史),写新的一行。要 action.manage_signatories。
--   按名拒:没有码 → PERMISSION_DENIED|action.manage_signatories;对象不在 → SIGNING_ASSET_NOT_STORED;不是 PNG → SIGNING_ASSET_TYPE;
--   sha256 形状不对 → SIGNING_ASSET_HASH_INVALID。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.company_stamp_record(p_stamp_id uuid, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_path text := 'stamps/' || p_stamp_id::text || '.png';
    v_meta jsonb;
BEGIN
    PERFORM require_permission('action.manage_signatories');
    IF p_sha256 IS NULL OR p_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'SIGNING_ASSET_HASH_INVALID';
    END IF;
    SELECT COALESCE(o.metadata, '{}'::jsonb) INTO v_meta FROM storage.objects o WHERE o.bucket_id = 'signing-assets' AND o.name = v_path;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SIGNING_ASSET_NOT_STORED';
    END IF;
    IF v_meta ->> 'mimetype' IS DISTINCT FROM 'image/png' OR NOT (v_meta ? 'size') THEN
        RAISE EXCEPTION 'SIGNING_ASSET_TYPE';
    END IF;
    UPDATE company_stamps SET superseded_at = now() WHERE superseded_at IS NULL;
    INSERT INTO company_stamps (id, file_path, file_size, sha256, created_by)
    VALUES (p_stamp_id, v_path, (v_meta ->> 'size')::bigint, p_sha256, auth.uid());
    RETURN jsonb_build_object('id', p_stamp_id, 'path', v_path);
END;
$function$;
