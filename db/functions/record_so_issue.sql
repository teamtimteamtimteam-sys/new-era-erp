CREATE OR REPLACE FUNCTION public.record_so_issue(p_order_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order sales_orders%ROWTYPE;
    v_next  integer;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_order FROM sales_orders WHERE id = p_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_order_id::text, '?');
    END IF;
    -- 草稿不签发:签发出去的是一份对外承诺,而草稿还不是承诺。
    IF v_order.status = 'draft' THEN
        RAISE EXCEPTION 'SO_NOT_ISSUABLE|%|%', v_order.code, v_order.status;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('so_issue_' || p_order_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM so_issues WHERE sales_order_id = p_order_id;

    INSERT INTO so_issues (sales_order_id, version, file_path, sha256, issued_by)
    VALUES (p_order_id, v_next, p_file_path, p_sha256, auth.uid());

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (p_order_id, 'issued', 'v' || v_next::text);

    RETURN jsonb_build_object('version', v_next);
END;
$function$

;
