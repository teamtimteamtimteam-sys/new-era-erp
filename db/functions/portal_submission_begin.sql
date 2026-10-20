-- db/functions/portal_submission_begin.sql
-- MES-9c(2026-10-20,MES-9 Step 0 §5 · V39,Tim):【门户开始交一份证书】—— 在【任何一个字节存下之前】按 V39 判,过了才登记一行、给出桶里的路径。
--   先过 portal_require_link()(角色 · 链接 · 撤销 · 会话);供应商只从链接推出来 —— 一份证书只能交给调用者自己那一家。
--   依次按名拒(第一条不过就停,什么都不写):
--     V39 没给(account_settings 两列任一为空)            → PORTAL_UPLOAD_LIMITS_NOT_SET
--     文件类型不在 V39 里(路由按文件头认出的类型)        → PORTAL_UPLOAD_TYPE_NOT_ACCEPTED|<类型>
--     大小 ≤ 0 或超过 V39 的上限                          → PORTAL_UPLOAD_TOO_LARGE|<上限字节数>(≤ 0 → PORTAL_UPLOAD_EMPTY)
--     证书类型不认识或已停用                              → PORTAL_CERT_TYPE_UNKNOWN|<码>
--     有效期至早于有效期起                                → PORTAL_CERT_DATES_INVALID
--     文件名空                                            → PORTAL_UPLOAD_NAME_REQUIRED
--   过了:写一行 status = uploading(路径 = <供应商 id>/<这一行的 id>.<扩展名>,扩展名由类型定,不取文件名里的),回 id · 桶 · 路径。
--   字节随后由路由以【这个会话自己的令牌】传进 portal-uploads(存储策略只放行一行 uploading 的、这位账号自己的、十分钟内登记的路径),
--   然后 portal_submission_finish 确认字节到了;没到 → portal_submission_abandon。
--   【什么别的都不写】:没有 supplier_compliance 行,没有库存、价钱、总账的改动(委托书)。
--   证书号与有效期可空(DEFAULT NULL,排在最后)—— 门户表单上这三格可以不填,PostgREST 收到没有这几个键的调用也认得出这支函数。
--   EXECUTE 只授 supplier_portal(zzz_function_grants.sql;db/portal-grants-baseline.tsv,判词八)。
-- NOTE: introduced by db/migrations/2026-10-20-mes9c-certificate-uploads.sql.
CREATE OR REPLACE FUNCTION public.portal_submission_begin(p_cert_type text, p_file_name text, p_file_type text, p_file_size bigint, p_cert_no text DEFAULT NULL::text, p_valid_from date DEFAULT NULL::date, p_valid_until date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link     uuid := portal_require_link();
    v_user     uuid;
    v_supplier uuid;
    v_max      bigint;
    v_types    text[];
    v_id       uuid := gen_random_uuid();
    v_ext      text;
    v_path     text;
    v_name     text := left(btrim(regexp_replace(COALESCE(p_file_name, ''), '[\\/[:cntrl:]]+', '_', 'g')), 200);
BEGIN
    SELECT p.user_id, p.supplier_id INTO v_user, v_supplier FROM supplier_portal_users p WHERE p.id = v_link;
    SELECT a.portal_upload_max_bytes, a.portal_upload_types INTO v_max, v_types FROM account_settings a WHERE a.id;
    IF v_max IS NULL OR v_types IS NULL THEN
        RAISE EXCEPTION 'PORTAL_UPLOAD_LIMITS_NOT_SET';
    END IF;
    IF p_file_type IS NULL OR NOT (p_file_type = ANY (v_types)) THEN
        RAISE EXCEPTION 'PORTAL_UPLOAD_TYPE_NOT_ACCEPTED|%', COALESCE(p_file_type, '');
    END IF;
    IF p_file_size IS NULL OR p_file_size <= 0 THEN
        RAISE EXCEPTION 'PORTAL_UPLOAD_EMPTY';
    END IF;
    IF p_file_size > v_max THEN
        RAISE EXCEPTION 'PORTAL_UPLOAD_TOO_LARGE|%', v_max;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM certificate_types ct WHERE ct.code = p_cert_type AND ct.is_active) THEN
        RAISE EXCEPTION 'PORTAL_CERT_TYPE_UNKNOWN|%', COALESCE(p_cert_type, '');
    END IF;
    IF p_valid_from IS NOT NULL AND p_valid_until IS NOT NULL AND p_valid_until < p_valid_from THEN
        RAISE EXCEPTION 'PORTAL_CERT_DATES_INVALID';
    END IF;
    IF v_name = '' THEN
        RAISE EXCEPTION 'PORTAL_UPLOAD_NAME_REQUIRED';
    END IF;
    v_ext := CASE p_file_type WHEN 'application/pdf' THEN 'pdf' WHEN 'image/jpeg' THEN 'jpg' WHEN 'image/png' THEN 'png' ELSE 'bin' END;
    v_path := v_supplier::text || '/' || v_id::text || '.' || v_ext;
    INSERT INTO portal_certificate_submissions (id, portal_user_id, user_id, supplier_id, cert_type_code, cert_no, valid_from, valid_until,
                                                file_name, file_type, file_size, storage_path)
    VALUES (v_id, v_link, v_user, v_supplier, p_cert_type, NULLIF(left(btrim(COALESCE(p_cert_no, '')), 120), ''), p_valid_from, p_valid_until,
            v_name, p_file_type, p_file_size, v_path);
    RETURN jsonb_build_object('id', v_id, 'bucket', 'portal-uploads', 'path', v_path);
END;
$function$;
