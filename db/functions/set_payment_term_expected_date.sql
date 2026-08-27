CREATE OR REPLACE FUNCTION public.set_payment_term_expected_date(p_term_id uuid, p_expected_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_t purchase_order_payment_terms%ROWTYPE; v_owner text;
BEGIN
    PERFORM require_permission('module.purchasing.edit');

    SELECT * INTO v_t FROM purchase_order_payment_terms WHERE id = p_term_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_TERM_NOT_FOUND|%', COALESCE(p_term_id::text, '?');
    END IF;
    -- 【只有需要估计的那三种才谈得上"预计日期"】另外两种已经有真日期:
    -- fixed_date 由表上那条 CHECK 保证,on_order 的日子是 PO 的下单日。
    -- 给它们再加一个估计,就是在一个事实旁边放一个猜测,让人去挑。
    SELECT owner_name INTO v_owner FROM payment_event_owners WHERE trigger_event = v_t.trigger_event;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPECTED_DATE_NOT_APPLICABLE|%', v_t.trigger_event;
    END IF;
    IF p_expected_date IS NULL THEN
        -- 【不传 = 撤回那个估计】而它同样留痕:谁撤的、什么时候撤的
        UPDATE purchase_order_payment_terms
           SET expected_date = NULL, expected_date_set_by = auth.uid(), expected_date_set_at = now()
         WHERE id = p_term_id;
        RETURN jsonb_build_object('term_id', p_term_id, 'expected_date', NULL, 'owner', v_owner);
    END IF;
    -- 【一个"预计在过去"的日期不是预计,是没人维护的痕迹】按名拒,并说出保管人是谁。
    IF p_expected_date < CURRENT_DATE THEN
        RAISE EXCEPTION 'EXPECTED_DATE_IN_PAST|%|%|%',
            p_expected_date::text, CURRENT_DATE::text, v_owner;
    END IF;

    UPDATE purchase_order_payment_terms
       SET expected_date = p_expected_date,
           expected_date_set_by = auth.uid(),
           expected_date_set_at = now()
     WHERE id = p_term_id;

    RETURN jsonb_build_object('term_id', p_term_id, 'expected_date', p_expected_date,
                              'trigger_event', v_t.trigger_event, 'owner', v_owner);
END;
$function$

;
