CREATE OR REPLACE FUNCTION public.record_cod_issue(p_cod_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cod record;
BEGIN
    IF NOT has_permission('action.issue_cod') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;

    SELECT c.id, c.code, c.status INTO v_cod
      FROM certificates_of_destruction c WHERE c.id = p_cod_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'COD_NOT_FOUND|%', COALESCE(p_cod_id::text, '?');
    END IF;
    -- 【只有已签发的才有字节可存】没签发的没有号,那份 PDF 上印不出号来。
    IF v_cod.status <> 'issued' THEN
        RAISE EXCEPTION 'COD_NOT_ISSUED|%|%', COALESCE(v_cod.code, v_cod.id::text), v_cod.status;
    END IF;

    -- ★ F17(MES-8a,2026-10-16;MES-8 Step 0 Q25 · MES-7a-1 Step 0 Q26):分析证书那一侧(record_coa_issue)的三样补齐 ——
    --   路径必须在 <证书 id>/ 之下(路由本来就这么拼;一条不在自己目录里的路径是在指别人的字节);
    --   一张证书只记一份字节(以前由 cod_issues 的唯一约束以一句裸消息拒,现在按名);哈希一律小写存(CHECK 只收小写十六进制)。
    IF p_file_path IS NULL OR p_file_path NOT LIKE v_cod.id::text || '/%' THEN
        RAISE EXCEPTION 'COD_ISSUE_PATH_INVALID|%', COALESCE(v_cod.code, v_cod.id::text);
    END IF;
    IF EXISTS (SELECT 1 FROM cod_issues i WHERE i.cod_id = p_cod_id) THEN
        RAISE EXCEPTION 'COD_BYTES_ALREADY_RECORDED|%', COALESCE(v_cod.code, v_cod.id::text);
    END IF;

    INSERT INTO cod_issues (cod_id, file_path, sha256, issued_by)
    VALUES (p_cod_id, p_file_path, lower(p_sha256), auth.uid());

    RETURN jsonb_build_object('cod_id', p_cod_id, 'code', v_cod.code, 'sha256', lower(p_sha256));
END;
$function$;
