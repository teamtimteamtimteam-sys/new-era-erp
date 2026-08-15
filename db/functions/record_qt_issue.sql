CREATE OR REPLACE FUNCTION public.record_qt_issue(p_quote_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_q    quotes%ROWTYPE;
    v_next integer;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_q FROM quotes WHERE id = p_quote_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'QT_NOT_FOUND|%', COALESCE(p_quote_id::text, '?');
    END IF;
    -- 谢绝了的、已经转成订单的,都不再签发:那两个状态说的是"这件事结束了",
    -- 而签发是把一份【还在谈】的东西发出去。
    IF v_q.status NOT IN ('draft', 'issued') THEN
        RAISE EXCEPTION 'QT_NOT_ISSUABLE|%|%', v_q.code, v_q.status;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('qt_issue_' || p_quote_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM qt_issues WHERE quote_id = p_quote_id;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【顺序就是要点 —— fu2】状态先翻,签发档【最后】插。
    -- 反过来写,那次状态 UPDATE 会把 quotes.updated_at 顶到 issued_at 之后,
    -- 于是每一张刚签发的报价都立刻自称"签发之后又改过"——
    -- 而一个总是亮着的警报等于没有警报。
    -- 签发档那一行的时间戳是其它一切要与之比较的基准,所以它必须是这次调用里
    -- 最晚发生的事。
    -- 【第一次签发就是 draft → issued 那次转换】签发是"发给对方"这件事本身,
    -- 而 issued 的意思正是它。第二次起只追加版本,状态不动。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_q.status = 'draft' THEN
        UPDATE quotes SET status = 'issued', updated_by = auth.uid() WHERE id = p_quote_id;
        INSERT INTO quote_history (quote_id, change_type, detail)
        VALUES (p_quote_id, 'issued', 'v' || v_next::text);
    END IF;

    INSERT INTO qt_issues (quote_id, version, file_path, sha256, issued_by)
    VALUES (p_quote_id, v_next, p_file_path, p_sha256, auth.uid());

    RETURN jsonb_build_object('version', v_next, 'status',
        CASE WHEN v_q.status = 'draft' THEN 'issued' ELSE v_q.status END);
END;
$function$

;
