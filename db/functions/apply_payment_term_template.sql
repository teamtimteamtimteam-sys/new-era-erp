CREATE OR REPLACE FUNCTION public.apply_payment_term_template(p_purchase_order_id uuid, p_template_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po    record;
    v_tpl   record;
    v_count integer := 0;
    v_fixed integer := 0;   -- FIN-29:本模板有几条定额腿
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT id, code, order_date, status, currency INTO v_po
    FROM purchase_orders WHERE id = p_purchase_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    SELECT id, name, currency INTO v_tpl
    FROM payment_term_templates
    WHERE id = p_template_id AND deleted_at IS NULL AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEMPLATE_NOT_FOUND|%', COALESCE(p_template_id::text, '?');
    END IF;

    -- ── FIN-29:定额腿的币种必须与本单相同,否则点名拒 ──────────────────────
    -- 【全部校验都在 DELETE 之前】拒绝必须是真的什么都没做:这个函数的语义是
    -- "替换整份计划",若先删后拒,靠的就只是事务回滚。把判断提到前面,
    -- 于是"被拒时原计划一行未动"是【结构上】成立的,不是靠回滚兜的。
    SELECT count(*) INTO v_fixed
    FROM payment_term_template_lines l
    WHERE l.template_id = p_template_id AND l.fixed_amount_ccy IS NOT NULL;

    IF v_fixed > 0 THEN
        IF v_tpl.currency IS NULL THEN
            -- 守卫(guard_template_fixed_needs_currency)之前建出来的行。不猜、不照抄:
            -- 照抄等于替双方认下一个没人谈过的币种(同 FIN-26 / FIN-27 的规矩)。
            RAISE EXCEPTION 'TEMPLATE_CURRENCY_UNDECLARED|%', v_tpl.name;
        END IF;
        IF v_tpl.currency <> v_po.currency THEN
            -- 【不换算】付款条款是谈定的承诺,不是算出来的量。按牌价折过去,
            -- 记下的就不再是双方谈的那个数。
            RAISE EXCEPTION 'TEMPLATE_CURRENCY_MISMATCH|%|%|%',
                v_tpl.name, v_tpl.currency, v_po.currency;
        END IF;
    END IF;

    -- 【替换】而不是追加:套模板的语义是"这张 PO 的计划就是模板说的那样"
    DELETE FROM purchase_order_payment_terms WHERE purchase_order_id = p_purchase_order_id;

    INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                              fixed_amount_ccy, trigger_event, due_date, notes)
    SELECT p_purchase_order_id, l.seq, l.label, l.percentage, l.fixed_amount_ccy, l.trigger_event,
           -- 模板存的是相对下单日的天数偏移(模板不可能知道具体日期)
           CASE WHEN l.trigger_event = 'fixed_date'
                THEN v_po.order_date + COALESCE(l.days_offset, 0)
                ELSE NULL END,
           l.notes
    FROM payment_term_template_lines l
    WHERE l.template_id = p_template_id
    ORDER BY l.seq;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RETURN jsonb_build_object('purchase_order_id', p_purchase_order_id, 'term_count', v_count,
                              'currency', v_po.currency, 'fixed_leg_count', v_fixed);
END;
$function$;