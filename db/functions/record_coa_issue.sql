-- db/functions/record_coa_issue.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q31):【记下一张分析证书的字节】—— PDF 已经由路由照快照渲染、传进私有桶 coa-documents,
--   这里落它的路径与 sha256(coa_issues,只追加)。门 action.issue_coa(与桶的上传策略同一个码)。
--   证书要在、要是已签发(COA_NOT_FOUND · COA_NOT_ISSUED);路径必须是 <证书 id>/…(COA_ISSUE_PATH_INVALID);
--   一张证书只记一份字节(COA_BYTES_ALREADY_RECORDED —— 没有第二版,与 cod_issues 同一条)。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.record_coa_issue(p_coa_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c record;
BEGIN
    PERFORM require_permission('action.issue_coa');
    SELECT c.id, c.code, c.status INTO v_c FROM certificates_of_analysis c WHERE c.id = p_coa_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'COA_NOT_FOUND|%', COALESCE(p_coa_id::text, '?');
    END IF;
    IF v_c.status <> 'issued' THEN
        RAISE EXCEPTION 'COA_NOT_ISSUED|%|%', v_c.code, v_c.status;
    END IF;
    IF p_file_path IS NULL OR p_file_path NOT LIKE v_c.id::text || '/%' THEN
        RAISE EXCEPTION 'COA_ISSUE_PATH_INVALID|%', v_c.code;
    END IF;
    IF EXISTS (SELECT 1 FROM coa_issues i WHERE i.coa_id = p_coa_id) THEN
        RAISE EXCEPTION 'COA_BYTES_ALREADY_RECORDED|%', v_c.code;
    END IF;
    INSERT INTO coa_issues (coa_id, file_path, sha256, issued_by) VALUES (p_coa_id, p_file_path, lower(p_sha256), auth.uid());
    RETURN jsonb_build_object('coa_id', p_coa_id, 'code', v_c.code, 'sha256', lower(p_sha256));
END;
$function$
