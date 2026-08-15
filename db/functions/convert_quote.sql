CREATE OR REPLACE FUNCTION public.convert_quote(p_quote_id uuid, p_order_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_q       quotes%ROWTYPE;
    v_lines   jsonb := '[]'::jsonb;
    v_l       record;
    v_n       int := 0;
    v_res     jsonb;
    v_order   uuid;
    v_ocode   text;
    v_made    int;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_q FROM quotes WHERE id = p_quote_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'QT_NOT_FOUND|%', COALESCE(p_quote_id::text, '?');
    END IF;

    -- 【拒绝的顺序:先说最具体的那一条】已经转过、被谢绝了,都是比"状态不对"
    -- 更有信息量的答案 —— 而"已经转过"还要说出【转成了哪一张单】,否则人会
    -- 再转一次去找它。
    IF v_q.status = 'converted' THEN
        RAISE EXCEPTION 'QT_ALREADY_CONVERTED|%|%', v_q.code,
            COALESCE((SELECT code FROM sales_orders WHERE id = v_q.converted_order_id), '?');
    END IF;
    IF v_q.status = 'declined' THEN
        RAISE EXCEPTION 'QT_DECLINED|%', v_q.code;
    END IF;
    IF v_q.status <> 'issued' THEN
        RAISE EXCEPTION 'QT_NOT_ISSUED|%|%', v_q.code, v_q.status;
    END IF;
    -- 【过期:边界含当天】有效期等于今天仍然转得了。消息里点出补救办法 ——
    -- 改 valid_until 再签发一版,而不是让人对着一句"过期了"猜下一步。
    IF quote_is_expired(v_q.valid_until) THEN
        RAISE EXCEPTION 'QT_EXPIRED|%|%', v_q.code, v_q.valid_until;
    END IF;

    -- ── 抄行:【一个字都不重算】────────────────────────────────────────────
    -- 【出处两列要么都递、要么都不递 —— 这是一个真的坑】create_sales_order 的
    -- 配对检查问的是【键在不在】(v_line ? 'price_source'),不是值是不是 NULL。
    -- 若无条件把两个键都放进去、值给 NULL,那检查会认为"两个都有",于是
    -- price_provenance 会以 jsonb 的 null【字面量】写进去 —— 它不是 SQL NULL,
    -- 于是 sales_order_lines_provenance_pairing 当场违约。所以按行条件拼。
    -- 【也不用 jsonb_strip_nulls】那个函数是递归的:它会钻进 price_provenance
    -- 里把内层的 null 也删掉 —— 那正是"转换悄悄改了这笔交易"。
    FOR v_l IN SELECT * FROM quote_lines WHERE quote_id = p_quote_id ORDER BY line_no
    LOOP
        v_n := v_n + 1;
        v_lines := v_lines || (
            jsonb_build_object(
                'material_id', v_l.material_id,
                'quantity',    v_l.quantity,
                'unit_price',  v_l.unit_price)
            || CASE WHEN v_l.notes IS NOT NULL
                    THEN jsonb_build_object('notes', v_l.notes) ELSE '{}'::jsonb END
            || CASE WHEN v_l.price_source IS NOT NULL
                    THEN jsonb_build_object('price_source', v_l.price_source,
                                            'price_provenance', v_l.price_provenance)
                    ELSE '{}'::jsonb END);
    END LOOP;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'QT_NO_LINES|%', v_q.code;
    END IF;

    -- ── 建单:【调用那扇门,不重写它】──────────────────────────────────────
    -- DEFINER 调 DEFINER 不绕过权限:require_permission 解析的是【调用者】的
    -- JWT,与谁拥有函数无关。订单日【不抄报价日】—— 它是客户接受的那一天,
    -- 空值由 create_sales_order 自己按名拒(ORDER_DATE_REQUIRED),这里不重写
    -- 那条规则。币种与汇率原样抄(见本文件抬头那一段的代价说明)。
    v_res := create_sales_order(v_q.customer_id, p_order_date, v_q.currency, v_q.fx_rate,
                                v_lines, v_q.notes, v_q.terms_text);
    v_order := (v_res->>'id')::uuid;
    v_ocode := v_res->>'code';

    -- 【断言,不是假设】抄过去几行,就该建出几行。将来有人给上面那个循环加一个
    -- 提前 CONTINUE,这里当场炸,而不是留下一张【少了几行】的订单 —— 而那张单
    -- 与报价的差别没有任何东西会报出来。
    SELECT count(*) INTO v_made FROM sales_order_lines WHERE sales_order_id = v_order;
    IF v_made <> v_n THEN
        RAISE EXCEPTION 'QT_CONVERT_LINES_LOST|%|%', v_n, v_made;
    END IF;

    -- ── 收尾:只写一次的那一列 + 两边各留一行痕 ────────────────────────────
    UPDATE quotes SET status = 'converted', converted_order_id = v_order,
                      updated_by = auth.uid()
     WHERE id = p_quote_id;

    INSERT INTO quote_history (quote_id, change_type, detail)
    VALUES (p_quote_id, 'converted', v_ocode);

    -- 【订单那一侧也要留一行】否则从订单看不出它是照哪张报价下的 —— 而那正是
    -- 三个月后有人会问的第一个问题。
    INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
    VALUES (v_order, 'converted_from_quote', v_q.code, auth.uid());

    RETURN jsonb_build_object(
        'quote_id', p_quote_id,
        'quote_code', v_q.code,
        'sales_order_id', v_order,
        'sales_order_code', v_ocode,
        'order_date', p_order_date,
        'currency', v_q.currency,
        'fx_rate', v_q.fx_rate,
        'lines', v_n);
END;
$function$

;
