CREATE OR REPLACE FUNCTION public.record_shipment_issue(p_shipment_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ship shipments%ROWTYPE;
    v_next integer;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_ship FROM shipments WHERE id = p_shipment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIPMENT_NOT_FOUND|%', COALESCE(p_shipment_id::text, '?');
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('shipment_issue_' || p_shipment_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM shipment_issues WHERE shipment_id = p_shipment_id;

    INSERT INTO shipment_issues (shipment_id, version, file_path, sha256, issued_by)
    VALUES (p_shipment_id, v_next, p_file_path, p_sha256, auth.uid());

    RETURN jsonb_build_object('version', v_next);
END;
$function$

;
