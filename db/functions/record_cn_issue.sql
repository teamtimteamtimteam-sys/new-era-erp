CREATE OR REPLACE FUNCTION public.record_cn_issue(p_credit_note_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cn   credit_notes%ROWTYPE;
    v_next integer;
BEGIN
    -- 【签发要 finance.edit,与开票同一道门】签发出去的是一份对外单据。
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_cn FROM credit_notes WHERE id = p_credit_note_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CN_NOT_FOUND|%', COALESCE(p_credit_note_id::text, '?');
    END IF;

    -- 【没有"草稿"这一档,所以没有对应的拒绝】凭证一出生就已经过账了
    -- (先过账再写单头),不存在"还不是承诺"的中间态 —— 与销售订单不同。
    PERFORM pg_advisory_xact_lock(hashtext('cn_issue_' || p_credit_note_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM cn_issues WHERE credit_note_id = p_credit_note_id;

    INSERT INTO cn_issues (credit_note_id, version, file_path, sha256, issued_by)
    VALUES (p_credit_note_id, v_next, p_file_path, p_sha256, auth.uid());

    RETURN jsonb_build_object('version', v_next);
END;
$function$

;
