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

    INSERT INTO cod_issues (cod_id, file_path, sha256, issued_by)
    VALUES (p_cod_id, p_file_path, p_sha256, auth.uid());

    RETURN jsonb_build_object('cod_id', p_cod_id, 'code', v_cod.code, 'sha256', p_sha256);
END;
$function$;
