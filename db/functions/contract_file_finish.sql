-- db/functions/contract_file_finish.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 A · D · E · Q2):【一个合同文件的字节到了】—— 确认对象在桶里、是 PDF、大小对得上,收下服务端算出来的 sha256,
--   这一行变成 current。三种各自再判一次(begin 与这一步之间合同可能变了):
--     original      合同仍在 draft / active、在用的那一份没有被签;之前在用的那一份记 superseded(A:替换留历史)。
--     signed        源文件仍是在用的 original、合同仍是 active、还没有别的在用签过版本、签它的人仍在名单上;大小取存下来的那一份。
--     countersigned 它下面那份签过版本仍在用、还没有在用的签回件;合同的 signed_on 若还空着,填成新加坡的今天(Q2)。
--   按名拒:不是自己登记的 → CONTRACT_FILE_NOT_FOUND;不在 uploading → CONTRACT_FILE_NOT_UPLOADING|<状态>;
--     对象不在 → CONTRACT_FILE_NOT_STORED;不是 PDF / 大小对不上 → CONTRACT_FILE_MISMATCH;sha256 形状不对 → CONTRACT_FILE_HASH_INVALID;
--     合同状态 / 已签 / 签回件 / 签署人 —— 与 begin 那几条同名。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_finish(p_file_id uuid, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r      contract_files%ROWTYPE;
    v_c    contracts%ROWTYPE;
    v_src  contract_files%ROWTYPE;
    v_meta jsonb;
    v_size bigint;
BEGIN
    SELECT * INTO r FROM contract_files x WHERE x.id = p_file_id AND x.created_by = auth.uid();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_FOUND';
    END IF;
    SELECT * INTO v_c FROM contracts WHERE id = r.contract_id FOR UPDATE;
    SELECT * INTO r FROM contract_files x WHERE x.id = p_file_id FOR UPDATE;
    IF r.status <> 'uploading' THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_UPLOADING|%', r.status;
    END IF;
    IF p_sha256 IS NULL OR p_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'CONTRACT_FILE_HASH_INVALID';
    END IF;
    SELECT COALESCE(o.metadata, '{}'::jsonb) INTO v_meta FROM storage.objects o WHERE o.bucket_id = r.bucket_id AND o.name = r.file_path;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_STORED';
    END IF;
    v_size := NULLIF(v_meta ->> 'size', '')::bigint;
    IF v_meta ->> 'mimetype' IS DISTINCT FROM 'application/pdf' OR v_size IS NULL OR v_size <= 0
       OR (r.file_size IS NOT NULL AND v_size <> r.file_size) THEN
        RAISE EXCEPTION 'CONTRACT_FILE_MISMATCH';
    END IF;
    IF r.kind = 'original' THEN
        IF v_c.status NOT IN ('draft', 'active') OR v_c.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'CONTRACT_FILE_CONTRACT_CLOSED|%|%', v_c.code, v_c.status;
        END IF;
        IF EXISTS (SELECT 1 FROM contract_files o JOIN contract_files s ON s.source_file_id = o.id AND s.kind = 'signed' AND s.status = 'current'
                    WHERE o.contract_id = v_c.id AND o.kind = 'original' AND o.status = 'current') THEN
            RAISE EXCEPTION 'CONTRACT_FILE_SIGNED_LOCKED|%', v_c.code;
        END IF;
        UPDATE contract_files SET status = 'superseded', superseded_at = now()
         WHERE contract_id = v_c.id AND kind = 'original' AND status = 'current';
    ELSIF r.kind = 'signed' THEN
        SELECT * INTO v_src FROM contract_files WHERE id = r.source_file_id FOR UPDATE;
        IF v_src.status <> 'current' THEN
            RAISE EXCEPTION 'CONTRACT_SIGN_NOT_CURRENT_ORIGINAL|%', v_c.code;
        END IF;
        IF v_c.status <> 'active' OR v_c.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'CONTRACT_SIGN_NOT_ACTIVE|%|%', v_c.code, v_c.status;
        END IF;
        IF EXISTS (SELECT 1 FROM contract_files f WHERE f.source_file_id = v_src.id AND f.kind = 'signed' AND f.status = 'current') THEN
            RAISE EXCEPTION 'CONTRACT_FILE_ALREADY_SIGNED|%', v_c.code;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM contract_signatories s WHERE s.id = r.signatory_id AND s.removed_at IS NULL
                          AND s.employee_id = current_user_employee()) THEN
            RAISE EXCEPTION 'CONTRACT_SIGN_NOT_SIGNATORY';
        END IF;
    ELSE
        SELECT * INTO v_src FROM contract_files WHERE id = r.source_file_id FOR UPDATE;
        IF v_src.status <> 'current' THEN
            RAISE EXCEPTION 'CONTRACT_COUNTERSIGN_NEEDS_SIGNED|%', v_c.code;
        END IF;
        IF EXISTS (SELECT 1 FROM contract_files f WHERE f.source_file_id = v_src.id AND f.kind = 'countersigned' AND f.status = 'current') THEN
            RAISE EXCEPTION 'CONTRACT_FILE_COUNTERSIGNED_FINAL|%', v_c.code;
        END IF;
    END IF;
    UPDATE contract_files SET status = 'current', sha256 = p_sha256, file_size = COALESCE(file_size, v_size), stored_at = now()
     WHERE id = r.id;
    IF r.kind = 'countersigned' THEN
        UPDATE contracts SET signed_on = (now() AT TIME ZONE 'Asia/Singapore')::date WHERE id = v_c.id AND signed_on IS NULL;
    END IF;
    RETURN jsonb_build_object('id', r.id, 'kind', r.kind, 'state', 'current', 'sha256', p_sha256, 'size', v_size);
END;
$function$;
