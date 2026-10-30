-- db/functions/contract_sign_begin.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q1 · Q3 · Q4 · Q5 · Q6 · Q9):【开始签一份合同文件】—— 判完才登记一行 kind = signed、status = uploading,
--   给出签过版本的路径、源文件的路径与哈希、签署人自己的签字样本与(选了的话)公司印章的路径、印出来的名字与职衔。
--   服务端动作随后把样本与印章盖到源文件上、另存成新的一份 PDF、按这条路径传、调 contract_file_finish(那一步才算签了)。
--   调这一支的会话【必须是刚刚凭密码登录的那一个】:服务端用签署人重新输入的密码另开一个会话,不换掉浏览器里那一个(Q5)。
--   依次按名拒:
--     文件不存在                                              → CONTRACT_FILE_NOT_FOUND
--     不是一份在用的 original(被替换了 / 是签过的版本)       → CONTRACT_SIGN_NOT_CURRENT_ORIGINAL|<合同号>
--     调用者此刻不在签署人名单上(Q3)                        → CONTRACT_SIGN_NOT_SIGNATORY
--     读不到这份合同的文件(Q3:要读得到那份合同 + Q8)        → CONTRACT_FILE_RESTRICTED|<合同号>
--     这个令牌不是 5 分钟之内凭密码登录的(Q5)               → CONTRACT_SIGN_PASSWORD_REQUIRED
--     合同不在 active(Q1:只签条款已经过 CFO 的合同)         → CONTRACT_SIGN_NOT_ACTIVE|<合同号>|<状态>
--     这一份已经有一份在用的签过版本(Q9)                    → CONTRACT_FILE_ALREADY_SIGNED|<合同号>
--     本人还没有签字样本(Q4:先在 /me 画一次)               → CONTRACT_SIGN_NO_SPECIMEN
--     选了印章而还没有在用的印章                              → CONTRACT_SIGN_NO_STAMP
--     页码 < 1、位置不在 0..1 之间、或印章的位置给了一半      → CONTRACT_SIGN_PLACEMENT_INVALID
--   页码不超过源文件的页数,由服务端在打开 PDF 之后判(库读不到 PDF)。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_sign_begin(p_file_id uuid, p_with_stamp boolean, p_signature_page integer, p_signature_x numeric, p_signature_y numeric, p_stamp_page integer DEFAULT NULL::integer, p_stamp_x numeric DEFAULT NULL::numeric, p_stamp_y numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_f     contract_files%ROWTYPE;
    v_c     contracts%ROWTYPE;
    v_sig   contract_signatories%ROWTYPE;
    v_emp   employees%ROWTYPE;
    v_pw    timestamptz;
    v_spec  signature_specimens%ROWTYPE;
    v_stamp company_stamps%ROWTYPE;
    v_id    uuid := gen_random_uuid();
    v_path  text;
BEGIN
    SELECT * INTO v_f FROM contract_files WHERE id = p_file_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NOT_FOUND';
    END IF;
    SELECT * INTO v_c FROM contracts WHERE id = v_f.contract_id;
    IF v_f.kind <> 'original' OR v_f.status <> 'current' THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_NOT_CURRENT_ORIGINAL|%', v_c.code;
    END IF;
    SELECT * INTO v_sig FROM contract_signatories s WHERE s.employee_id = current_user_employee() AND s.removed_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_NOT_SIGNATORY';
    END IF;
    IF NOT contract_file_readable(v_c.id) THEN
        RAISE EXCEPTION 'CONTRACT_FILE_RESTRICTED|%', v_c.code;
    END IF;
    v_pw := signing_password_verified_at();
    IF v_pw IS NULL OR v_pw < now() - interval '5 minutes' THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_PASSWORD_REQUIRED';
    END IF;
    IF v_c.status <> 'active' OR v_c.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_NOT_ACTIVE|%|%', v_c.code, v_c.status;
    END IF;
    IF EXISTS (SELECT 1 FROM contract_files f WHERE f.source_file_id = v_f.id AND f.kind = 'signed' AND f.status = 'current') THEN
        RAISE EXCEPTION 'CONTRACT_FILE_ALREADY_SIGNED|%', v_c.code;
    END IF;
    SELECT * INTO v_spec FROM signature_specimens s WHERE s.employee_id = v_sig.employee_id AND s.superseded_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_NO_SPECIMEN';
    END IF;
    IF COALESCE(p_with_stamp, false) THEN
        SELECT * INTO v_stamp FROM company_stamps s WHERE s.superseded_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CONTRACT_SIGN_NO_STAMP';
        END IF;
    END IF;
    IF p_signature_page IS NULL OR p_signature_page < 1 OR p_signature_x IS NULL OR p_signature_y IS NULL
       OR p_signature_x < 0 OR p_signature_x > 1 OR p_signature_y < 0 OR p_signature_y > 1
       OR (COALESCE(p_with_stamp, false) AND (p_stamp_page IS NULL OR p_stamp_page < 1 OR p_stamp_x IS NULL OR p_stamp_y IS NULL
                                              OR p_stamp_x < 0 OR p_stamp_x > 1 OR p_stamp_y < 0 OR p_stamp_y > 1)) THEN
        RAISE EXCEPTION 'CONTRACT_SIGN_PLACEMENT_INVALID';
    END IF;
    SELECT * INTO v_emp FROM employees WHERE id = v_sig.employee_id;
    v_path := v_c.id::text || '/' || v_id::text || '.pdf';
    INSERT INTO contract_files (id, contract_id, kind, source_file_id, file_name, file_path, created_by,
                                signatory_id, signer_employee_id, signer_name, signer_title, specimen_id, stamp_id,
                                signature_page, signature_x, signature_y, stamp_page, stamp_x, stamp_y, password_verified_at)
    VALUES (v_id, v_c.id, 'signed', v_f.id, left('signed-' || v_f.file_name, 200), v_path, auth.uid(),
            v_sig.id, v_emp.id, v_emp.legal_name, v_sig.title, v_spec.id,
            CASE WHEN COALESCE(p_with_stamp, false) THEN v_stamp.id END,
            p_signature_page, p_signature_x, p_signature_y,
            CASE WHEN COALESCE(p_with_stamp, false) THEN p_stamp_page END,
            CASE WHEN COALESCE(p_with_stamp, false) THEN p_stamp_x END,
            CASE WHEN COALESCE(p_with_stamp, false) THEN p_stamp_y END,
            v_pw);
    RETURN jsonb_build_object('id', v_id, 'bucket', 'contract-files', 'path', v_path, 'contract_code', v_c.code,
                              'source_path', v_f.file_path, 'source_sha256', v_f.sha256,
                              'specimen_path', v_spec.file_path, 'specimen_sha256', v_spec.sha256,
                              'stamp_path', CASE WHEN COALESCE(p_with_stamp, false) THEN v_stamp.file_path END,
                              'stamp_sha256', CASE WHEN COALESCE(p_with_stamp, false) THEN v_stamp.sha256 END,
                              'signer_name', v_emp.legal_name, 'signer_title', v_sig.title,
                              'password_verified_at', v_pw);
END;
$function$;
