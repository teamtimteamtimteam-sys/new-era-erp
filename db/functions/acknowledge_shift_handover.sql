CREATE OR REPLACE FUNCTION public.acknowledge_shift_handover(p_handover_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ho  shift_handovers%ROWTYPE;
    v_emp uuid := current_user_employee();
BEGIN
    PERFORM require_permission('module.processing.edit');

    SELECT * INTO v_ho FROM shift_handovers WHERE id = p_handover_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'HANDOVER_NOT_FOUND|%', p_handover_id;
    END IF;
    IF v_ho.acknowledged_at IS NOT NULL THEN
        RAISE EXCEPTION 'HANDOVER_ALREADY_ACKNOWLEDGED|%', v_ho.acknowledged_at
          USING HINT = '这张交接班已经被签收过了。**签收不是一个可以重来的动作** —— 覆盖它会把第一次签收的人与时刻抹掉,而那正是这一列存在的理由。';
    END IF;
    -- ════════════════════════════════════════════════════════════════════════
    -- ★【签收的人必须【是这张交接班点名的那位接班人】】★
    -- Tim 的原话是"**接班的那个人**的签收"。放宽成"任何有权限的人都能签",
    -- 这一列就退化成一个时间戳 —— 它会永远是满的,而它本来要回答的问题
    -- (**下一个班的人真的看过这些话了吗**)从此没有答案。
    -- 【为什么按 employee 而不是按 auth 用户】车间可能共用工位账号,
    -- 而"谁接的班"必须是一个人。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_ACK_NO_EMPLOYEE'
          USING HINT = '签收要落到一个【员工】身上,而这个登录账号没有对应的员工档案。签收是一个人做的事,不是一个账号做的事。';
    END IF;
    IF v_emp <> v_ho.incoming_employee_id THEN
        RAISE EXCEPTION 'HANDOVER_ACK_NOT_INCOMING'
          USING HINT = '只有这张交接班点名的那位【接班人】能签收它。别人代签,这一栏就只是一个时间戳,而它本来要回答的是"下一个班的人真的看过这些话了吗"。接班的人换了,就先把交接班改成他。';
    END IF;

    UPDATE shift_handovers
       SET acknowledged_at = now(),
           acknowledged_by = v_emp,
           updated_by      = auth.uid()
     WHERE id = p_handover_id;

    RETURN p_handover_id;
END;
$function$

