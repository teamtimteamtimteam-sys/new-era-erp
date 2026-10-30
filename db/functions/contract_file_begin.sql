-- db/functions/contract_file_begin.sql
-- CONTRACT-ESIGN(Tim 2026-10-29 · 2026-10-30 Q1 · Q10 · Q12):【开始给一份合同传一个文件】—— 在【任何一个字节存下之前】判完,过了才登记一行
--   uploading、给出私有桶 contract-files 里的路径;字节由浏览器直传(GOLIVE-2 第 9 行的形状),contract_file_finish 确认。
--   p_kind:'original'(未签的合同文件)或 'countersigned'(对方签回的扫描件)。签过的版本不走这里(contract_sign_begin)。
--   依次按名拒(第一条不过就停,什么都不写):
--     没有 action.contract_terms                                         → PERMISSION_DENIED|action.contract_terms
--     合同不存在 / 已删                                                  → CONTRACT_NOT_FOUND
--     读不到这份合同的文件(那一侧的读码 + 价格码,Q8)                  → CONTRACT_FILE_RESTRICTED|<合同号>
--     种类不是这两种                                                     → CONTRACT_FILE_KIND_INVALID|<种类>
--     original:合同不在 draft / active(Q1)                            → CONTRACT_FILE_CONTRACT_CLOSED|<合同号>|<状态>
--     original:在用的那一份已经被我方签过、没有作废(D)                → CONTRACT_FILE_SIGNED_LOCKED|<合同号>
--     countersigned:没有一份在用的我方签过版本(Q10:先签)              → CONTRACT_COUNTERSIGN_NEEDS_SIGNED|<合同号>
--     countersigned:那一份签过版本已经有了在用的签回件(它是最终版本)  → CONTRACT_FILE_COUNTERSIGNED_FINAL|<合同号>
--     不是 PDF(Q10 · Q12:两种都只收 PDF)                              → CONTRACT_FILE_TYPE_NOT_ACCEPTED|<类型>
--     大小 ≤ 0 / 超过 25 MB(Q12,桶上也是这个数)                       → CONTRACT_FILE_EMPTY / CONTRACT_FILE_TOO_LARGE|26214400
--     文件名空                                                           → CONTRACT_FILE_NAME_REQUIRED
--     整个项目的存储已到 900 MB(CLAIM-RECEIPTS-1 Q10 那一条,免费方案)  → CONTRACT_FILE_STORAGE_FULL|<已用字节数>|<上限字节数>
--   过了:写一行(路径 = <合同 id>/<这一行的 id>.pdf),回 id · 桶 · 路径。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.contract_file_begin(p_contract_id uuid, p_kind text, p_file_name text, p_file_type text, p_file_size bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c       contracts%ROWTYPE;
    v_orig    contract_files%ROWTYPE;
    v_signed  uuid;
    v_source  uuid;
    v_max     constant bigint := 26214400;    -- 25 MB(Tim Q12;与桶的 file_size_limit 同一个数)
    v_ceiling constant bigint := 943718400;   -- 900 MB(CLAIM-RECEIPTS-1 Q10,免费方案 1 GB)
    v_used    bigint;
    v_id      uuid := gen_random_uuid();
    v_path    text;
    v_name    text := left(btrim(regexp_replace(COALESCE(p_file_name, ''), '[\\/[:cntrl:]]+', '_', 'g')), 200);
BEGIN
    PERFORM require_permission('action.contract_terms');
    SELECT * INTO v_c FROM contracts WHERE id = p_contract_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND';
    END IF;
    IF NOT contract_file_readable(v_c.id) THEN
        RAISE EXCEPTION 'CONTRACT_FILE_RESTRICTED|%', v_c.code;
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('original', 'countersigned') THEN
        RAISE EXCEPTION 'CONTRACT_FILE_KIND_INVALID|%', COALESCE(p_kind, '');
    END IF;
    SELECT * INTO v_orig FROM contract_files f WHERE f.contract_id = v_c.id AND f.kind = 'original' AND f.status = 'current';
    IF FOUND THEN
        SELECT f.id INTO v_signed FROM contract_files f WHERE f.source_file_id = v_orig.id AND f.kind = 'signed' AND f.status = 'current';
    END IF;
    IF p_kind = 'original' THEN
        IF v_c.status NOT IN ('draft', 'active') THEN
            RAISE EXCEPTION 'CONTRACT_FILE_CONTRACT_CLOSED|%|%', v_c.code, v_c.status;
        END IF;
        IF v_signed IS NOT NULL THEN
            RAISE EXCEPTION 'CONTRACT_FILE_SIGNED_LOCKED|%', v_c.code;
        END IF;
    ELSE
        IF v_signed IS NULL THEN
            RAISE EXCEPTION 'CONTRACT_COUNTERSIGN_NEEDS_SIGNED|%', v_c.code;
        END IF;
        IF EXISTS (SELECT 1 FROM contract_files f WHERE f.source_file_id = v_signed AND f.kind = 'countersigned' AND f.status = 'current') THEN
            RAISE EXCEPTION 'CONTRACT_FILE_COUNTERSIGNED_FINAL|%', v_c.code;
        END IF;
        v_source := v_signed;
    END IF;
    IF p_file_type IS DISTINCT FROM 'application/pdf' THEN
        RAISE EXCEPTION 'CONTRACT_FILE_TYPE_NOT_ACCEPTED|%', COALESCE(p_file_type, '');
    END IF;
    IF p_file_size IS NULL OR p_file_size <= 0 THEN
        RAISE EXCEPTION 'CONTRACT_FILE_EMPTY';
    END IF;
    IF p_file_size > v_max THEN
        RAISE EXCEPTION 'CONTRACT_FILE_TOO_LARGE|%', v_max;
    END IF;
    IF v_name = '' THEN
        RAISE EXCEPTION 'CONTRACT_FILE_NAME_REQUIRED';
    END IF;
    SELECT COALESCE(sum((o.metadata ->> 'size')::bigint), 0) INTO v_used FROM storage.objects o;
    IF v_used + p_file_size > v_ceiling THEN
        RAISE EXCEPTION 'CONTRACT_FILE_STORAGE_FULL|%|%', v_used, v_ceiling;
    END IF;
    v_path := v_c.id::text || '/' || v_id::text || '.pdf';
    INSERT INTO contract_files (id, contract_id, kind, source_file_id, file_name, file_size, file_path, created_by)
    VALUES (v_id, v_c.id, p_kind, v_source, v_name, p_file_size, v_path, auth.uid());
    RETURN jsonb_build_object('id', v_id, 'bucket', 'contract-files', 'path', v_path);
END;
$function$;
