CREATE OR REPLACE FUNCTION public.record_statement_issue(p_statement_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s    customer_statements%ROWTYPE;
    v_next integer;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_s FROM customer_statements WHERE id = p_statement_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STATEMENT_NOT_FOUND|%', COALESCE(p_statement_id::text, '?');
    END IF;

    -- 【被取代的那一份不再签发,但既有的版本仍然读得到】与 record_invoice_issue
    -- 拒 void 同一条:被取代的意思是"这一份结束了",而不是"它没发生过" ——
    -- 客户手里那一版仍然是真实寄出去过的东西。
    IF v_s.superseded_at IS NOT NULL THEN
        RAISE EXCEPTION 'STATEMENT_SUPERSEDED|%|%', v_s.code,
            COALESCE(v_s.superseded_reason, '');
    END IF;

    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next
      FROM statement_issues WHERE statement_id = p_statement_id;

    INSERT INTO statement_issues (statement_id, version, file_path, sha256, issued_by)
    VALUES (p_statement_id, v_next, p_file_path, p_sha256, auth.uid());

    RETURN jsonb_build_object('statement_id', p_statement_id, 'code', v_s.code,
                              'version', v_next, 'file_path', p_file_path);
END;
$function$

;
