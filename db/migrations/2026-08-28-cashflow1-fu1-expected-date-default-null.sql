-- CASHFLOW-1 fu1:set_payment_term_expected_date 的第二个参数给一个 DEFAULT NULL
--
-- 【为什么】那支函数【本来就接受 NULL】—— 撤回一个估计是正当动作,函数体里
-- 专门有一支处理它。但参数没有默认值,于是生成的 TypeScript 类型把它标成
-- 必填的 `string`,前端要传 null 就只能【强转类型】—— 而一次为了骗过编译器
-- 的强转,正是下一个人会相信的那种假话。
--
-- 【为什么是改签名而不是在前端转一下】口径应当由库这一侧说清楚:
-- "不传 = 撤回那个估计"。改了默认值之后,生成的类型自己就变成可选,
-- 前端那句 `...(x ? {p_expected_date: x} : {})` 与其它几支写法一致。
--
-- 【这不是重载】参数类型没变(uuid, date),只是多了一个默认值 ——
-- preflight 拒的是【签名不同】的 CREATE OR REPLACE,这一支不是。
BEGIN;

CREATE OR REPLACE FUNCTION public.set_payment_term_expected_date(
    p_term_id       uuid,
    p_expected_date date DEFAULT NULL
)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
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
$function$;

COMMIT;
