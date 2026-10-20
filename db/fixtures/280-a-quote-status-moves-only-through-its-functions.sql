-- 280 FIN-CHAIN-1:报价的状态只经函数写(APR5-QUOTE-STATUS-DIRECT-UPDATE,2026-10-20)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(Tim APR-5 Q12;FIN-CHAIN-1 委托书 B4)
--   以一个持 module.sales.edit 的【登录用户】身份(SET LOCAL ROLE authenticated —— RLS 真的在场):
--   A  直连插一张 draft 报价照旧可以;直连插一张 issued 的 → QT_STATUS_THROUGH_FUNCTION_ONLY|status|issued;
--        直连插时带 decline_reason → …|decline_reason|…
--   B  直连改备注照旧可以(报价的用途);直连改 status → …|status|<号>;
--        直连填 converted_order_id → …|converted_order_id|<号>(守卫先于配对 CHECK 说话)
--   C  经函数走得通:record_qt_issue → issued;decline_quote → declined + 理由;
--        之后直连改谢绝理由 → …|decline_reason|<号>
--   D  属主路径放行:以 postgres(row_security_active = false)直连改状态不被这支守卫拦
--   E  ★ 故障注入:拿掉触发器,B 臂那一句直连改状态当场通过 —— 证明 B 臂的拒绝来自这支守卫
--
-- 自带数据(README 第 2 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE FUNCTION pg_temp.f280_try(p_sql text, p_auth boolean DEFAULT true) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_auth THEN EXECUTE 'SET LOCAL ROLE authenticated'; END IF;
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_sales uuid;
    v_cust uuid; v_ord uuid;
    q1 uuid; q1_code text; q2 uuid; q2_code text;
    v_msg text;
    d date := CURRENT_DATE;
BEGIN
    INSERT INTO auth.users (id) VALUES (v_user);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx280-sales', 'f', 'f', true) RETURNING id INTO r_sales;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_sales, 'module.sales.view'), (r_sales, 'module.sales.edit'), (r_sales, 'module.customers.view'),
        (r_sales, 'data.view_prices');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_sales);
    INSERT INTO customers (legal_name, country) VALUES ('fixture 280 customer', 'SG') RETURNING id INTO v_cust;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════════ A · 直连插 ══════════════
    v_msg := pg_temp.f280_try(format(
        'INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate) VALUES (%L, %L, %L, %L, 1)',
        v_cust, d, d + 30, (SELECT code FROM currencies WHERE is_base)));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 280A1 失败:直连插一张 draft 报价应当照旧可以,实得 %', v_msg; END IF;
    SELECT id, code INTO q1, q1_code FROM quotes WHERE customer_id = v_cust ORDER BY created_at LIMIT 1;
    v_msg := pg_temp.f280_try(format(
        'INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate, status) VALUES (%L, %L, %L, %L, 1, %L)',
        v_cust, d, d + 30, (SELECT code FROM currencies WHERE is_base), 'issued'));
    IF v_msg <> 'QT_STATUS_THROUGH_FUNCTION_ONLY|status|issued' THEN
        RAISE EXCEPTION 'FIXTURE 280A2 失败:直连插一张 issued 的报价应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f280_try(format(
        'INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate, decline_reason) VALUES (%L, %L, %L, %L, 1, %L)',
        v_cust, d, d + 30, (SELECT code FROM currencies WHERE is_base), 'x'));
    IF v_msg <> 'QT_STATUS_THROUGH_FUNCTION_ONLY|decline_reason|draft' THEN
        RAISE EXCEPTION 'FIXTURE 280A3 失败:直连插时带谢绝理由应当按名拒,实得 %', v_msg; END IF;
    IF (SELECT count(*) FROM quotes WHERE customer_id = v_cust) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 280A4 失败:被拒的两次插入不该留下行'; END IF;

    -- ══════════════ B · 直连改 ══════════════
    v_msg := pg_temp.f280_try(format('UPDATE quotes SET notes = %L WHERE id = %L', 'renegotiated', q1));
    IF v_msg <> 'OK' OR (SELECT notes FROM quotes WHERE id = q1) IS DISTINCT FROM 'renegotiated' THEN
        RAISE EXCEPTION 'FIXTURE 280B1 失败:直连改备注应当照旧可以,实得 %', v_msg; END IF;
    v_msg := pg_temp.f280_try(format('UPDATE quotes SET status = %L WHERE id = %L', 'issued', q1));
    IF v_msg <> 'QT_STATUS_THROUGH_FUNCTION_ONLY|status|' || q1_code THEN
        RAISE EXCEPTION 'FIXTURE 280B2 失败:直连改状态应当按名拒,实得 %', v_msg; END IF;
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, (SELECT code FROM currencies WHERE is_base), 1) RETURNING id INTO v_ord;
    v_msg := pg_temp.f280_try(format('UPDATE quotes SET converted_order_id = %L WHERE id = %L', v_ord, q1));
    IF v_msg <> 'QT_STATUS_THROUGH_FUNCTION_ONLY|converted_order_id|' || q1_code THEN
        RAISE EXCEPTION 'FIXTURE 280B3 失败:直连填 converted_order_id 应当由守卫按名拒,实得 %', v_msg; END IF;
    IF (SELECT status FROM quotes WHERE id = q1) <> 'draft' THEN
        RAISE EXCEPTION 'FIXTURE 280B4 失败:被拒的改动不该动状态'; END IF;

    -- ══════════════ C · 经函数走得通 ══════════════
    v_msg := pg_temp.f280_try(format('SELECT record_qt_issue(%L, %L, %L)', q1, 'f280/q1.pdf', repeat('a', 64)));
    IF v_msg <> 'OK' OR (SELECT status FROM quotes WHERE id = q1) <> 'issued' THEN
        RAISE EXCEPTION 'FIXTURE 280C1 失败:签发经函数应当走得通(→ issued),实得 %', v_msg; END IF;
    v_msg := pg_temp.f280_try(format('SELECT decline_quote(%L, %L)', q1, 'price too high'));
    IF v_msg <> 'OK' OR (SELECT status FROM quotes WHERE id = q1) <> 'declined'
       OR (SELECT decline_reason FROM quotes WHERE id = q1) <> 'price too high' THEN
        RAISE EXCEPTION 'FIXTURE 280C2 失败:谢绝经函数应当走得通(→ declined + 理由),实得 %', v_msg; END IF;
    v_msg := pg_temp.f280_try(format('UPDATE quotes SET decline_reason = %L WHERE id = %L', 'rewritten', q1));
    IF v_msg <> 'QT_STATUS_THROUGH_FUNCTION_ONLY|decline_reason|' || q1_code THEN
        RAISE EXCEPTION 'FIXTURE 280C3 失败:直连改谢绝理由应当按名拒,实得 %', v_msg; END IF;

    -- ══════════════ D · 属主路径放行 ══════════════
    INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate)
    VALUES (v_cust, d, d + 30, (SELECT code FROM currencies WHERE is_base), 1) RETURNING id, code INTO q2, q2_code;
    v_msg := pg_temp.f280_try(format('UPDATE quotes SET status = %L WHERE id = %L', 'issued', q2), false);
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 280D 失败:属主(row_security_active = false)不该被这支守卫拦,实得 %', v_msg; END IF;

    -- ══════════════ E · 故障注入:拿掉触发器 ══════════════
    DROP TRIGGER trg_quotes_status_through_function ON public.quotes;
    INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate)
    VALUES (v_cust, d, d + 30, (SELECT code FROM currencies WHERE is_base), 1) RETURNING id INTO q2;
    v_msg := pg_temp.f280_try(format('UPDATE quotes SET status = %L WHERE id = %L', 'issued', q2));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 280E 失败:拿掉守卫之后直连改状态应当通过 —— 否则 B2 是被别的东西拒的,实得 %', v_msg; END IF;

    RAISE NOTICE 'FIXTURE 280 全部通过:A 直连插 · B 直连改 · C 经函数走得通 · D 属主放行 · E 注入';
END;
$$;
ROLLBACK;
