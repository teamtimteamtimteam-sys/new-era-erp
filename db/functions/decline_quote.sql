CREATE OR REPLACE FUNCTION public.decline_quote(p_quote_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_q quotes%ROWTYPE;
BEGIN
    PERFORM require_permission('module.sales.edit');

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'QT_DECLINE_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_q FROM quotes WHERE id = p_quote_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'QT_NOT_FOUND|%', COALESCE(p_quote_id::text, '?');
    END IF;
    -- 【只有签发出去的才谈得上谢绝】草稿还没发给任何人,没有人能拒绝它;
    -- 已转成订单的更不必说。
    IF v_q.status <> 'issued' THEN
        RAISE EXCEPTION 'QT_NOT_ISSUED|%|%', v_q.code, v_q.status;
    END IF;
    -- 【过期的报价谢绝得了,这是有意的】过期只是日历走过去了,而"对方明确说
    -- 不要"是一个真实发生的事实 —— 拒绝记录它,只会让那条信息无处安放。

    UPDATE quotes SET status = 'declined', decline_reason = btrim(p_reason),
                      updated_by = auth.uid()
     WHERE id = p_quote_id;

    INSERT INTO quote_history (quote_id, change_type, detail)
    VALUES (p_quote_id, 'declined', btrim(p_reason));

    RETURN jsonb_build_object('quote_id', p_quote_id, 'code', v_q.code, 'status', 'declined');
END;
$function$

;
