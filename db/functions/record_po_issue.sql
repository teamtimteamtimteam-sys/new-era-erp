CREATE OR REPLACE FUNCTION public.record_po_issue(p_po_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po record;
    v_version integer;
    v_id uuid;
BEGIN
    PERFORM require_permission('module.purchasing.edit');

    SELECT id, code, approval_status INTO v_po
    FROM purchase_orders WHERE id = p_po_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_po_id::text, '?');
    END IF;
    -- 【未获批的单不能签发,无条件】审批关着时单据生来就是 approved,这里没有代价;
    -- 开着时,这补上 APR-2 A4 点名的缺口 ——"发给供应商"这个动作当时不存在,
    -- 现在存在了,就要把关。一张待批的单发出去,是在审批之前完成承诺。
    IF v_po.approval_status <> 'approved' THEN
        RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_po.code, v_po.approval_status;
    END IF;
    IF p_file_path IS NULL OR btrim(p_file_path) = '' THEN
        RAISE EXCEPTION 'ISSUE_FILE_PATH_REQUIRED';
    END IF;
    IF p_sha256 IS NULL OR p_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'ISSUE_SHA256_INVALID';
    END IF;

    -- 版本号逐单递增;UNIQUE (po, version) 挡并发,FOR UPDATE 挡同事务竞态
    PERFORM 1 FROM purchase_orders WHERE id = p_po_id FOR UPDATE;
    SELECT COALESCE(max(version), 0) + 1 INTO v_version
    FROM po_issues WHERE purchase_order_id = p_po_id;

    INSERT INTO po_issues (purchase_order_id, version, file_path, sha256, issued_by)
    VALUES (p_po_id, v_version, p_file_path, p_sha256, auth.uid())
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('issue_id', v_id, 'version', v_version, 'code', v_po.code);
END;
$function$;