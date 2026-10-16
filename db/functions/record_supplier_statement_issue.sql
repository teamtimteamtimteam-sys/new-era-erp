-- db/functions/record_supplier_statement_issue.sql
-- MES-8a(2026-10-16,MES-8 Step 0 Q9 · Q25):【记下一份供应商对账单的字节】—— PDF 已经由路由从冻下来的那一行渲染、传进私有桶
--   supplier-statement-documents,这里落它的路径与 sha256(supplier_statement_issues,只追加,一份对账单可以有好几版)。门 module.finance.edit。
--   照分析证书那一份写(F17 的三条从第一天起就在):对账单要在(SUPPLIER_STATEMENT_NOT_FOUND)、没被取代(SUPPLIER_STATEMENT_SUPERSEDED|<号>|<理由>
--   —— 被取代的不再签发,既有的版本仍然读得到);路径必须是 <对账单 id>/…(SUPPLIER_STATEMENT_ISSUE_PATH_INVALID|<号>);
--   哈希必须是 64 位十六进制、一律小写存(SUPPLIER_STATEMENT_SHA_INVALID);同一串字节在同一份对账单上只记一次
--   (SUPPLIER_STATEMENT_BYTES_ALREADY_RECORDED|<号>|<版本>)。版本由这里裁决(并发安全:锁住那一行)。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.record_supplier_statement_issue(p_statement_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s    supplier_statements%ROWTYPE;
    v_sha  text := lower(btrim(COALESCE(p_sha256, '')));
    v_next integer;
    v_had  integer;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_s FROM supplier_statements WHERE id = p_statement_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_NOT_FOUND|%', COALESCE(p_statement_id::text, '?');
    END IF;
    IF v_s.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_SUPERSEDED|%|%', v_s.code, COALESCE(v_s.superseded_reason, '');
    END IF;
    IF p_file_path IS NULL OR p_file_path NOT LIKE v_s.id::text || '/%' THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_ISSUE_PATH_INVALID|%', v_s.code;
    END IF;
    IF v_sha !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_SHA_INVALID';
    END IF;
    SELECT version INTO v_had FROM supplier_statement_issues WHERE statement_id = p_statement_id AND sha256 = v_sha;
    IF FOUND THEN
        RAISE EXCEPTION 'SUPPLIER_STATEMENT_BYTES_ALREADY_RECORDED|%|%', v_s.code, v_had;
    END IF;

    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM supplier_statement_issues WHERE statement_id = p_statement_id;
    INSERT INTO supplier_statement_issues (statement_id, version, file_path, sha256, issued_by)
    VALUES (p_statement_id, v_next, p_file_path, v_sha, auth.uid());

    RETURN jsonb_build_object('statement_id', p_statement_id, 'code', v_s.code, 'version', v_next,
                              'file_path', p_file_path, 'sha256', v_sha);
END;
$function$
