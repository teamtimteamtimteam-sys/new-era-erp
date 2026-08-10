CREATE OR REPLACE FUNCTION public.attribute_sale_customer(p_sales_record_id uuid, p_customer_id uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_sale     record;
    v_cust     record;
    v_prior    text;
    v_exposure numeric;
    v_user     uuid := auth.uid();
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT sr.id, sr.customer_id, sr.amount_base, ob.code AS batch_code
    INTO v_sale
    FROM sales_records sr
    JOIN output_batches ob ON ob.id = sr.output_batch_id
    WHERE sr.id = p_sales_record_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SALE_NOT_FOUND|%', COALESCE(p_sales_record_id::text, '?');
    END IF;

    -- 【单向】已经有主的销售不从这条路改 —— 改投他人是另一种行为(动两个人的账)
    IF v_sale.customer_id IS NOT NULL THEN
        SELECT code INTO v_prior FROM customers WHERE id = v_sale.customer_id;
        RAISE EXCEPTION 'SALE_ALREADY_ATTRIBUTED|%|%', v_sale.batch_code, COALESCE(v_prior, '?');
    END IF;

    SELECT id, code INTO v_cust FROM customers
    WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;

    -- ★【这里【不】查信用限额,也不查冻结】★
    -- 补挂记录的是一个【已经成立】的事实:货已经卖了、钱已经欠着了。在这里因为
    -- "欠得太多"而拒绝,等于拒绝把一笔已经存在的债写进账 —— 债不会因此消失,
    -- 只会继续隐形,而隐形正是这一刀要修的病。与"投入没化验就拒绝加工"同一种错误。
    -- 越限的后果由看板 credit_over_limit 支说;新的销售仍会被 record_output_sale 拦。

    PERFORM set_config('evoltrya.attribution_ctx', 'attribute_sale_customer', true);
    UPDATE sales_records SET customer_id = p_customer_id WHERE id = p_sales_record_id;
    PERFORM set_config('evoltrya.attribution_ctx', '', true);

    v_exposure := customer_ar_exposure_base(p_customer_id);

    INSERT INTO sales_attribution_log
        (sales_record_id, customer_id, amount_base, exposure_after, note, attributed_by)
    VALUES (p_sales_record_id, p_customer_id, v_sale.amount_base, v_exposure, NULLIF(btrim(p_note), ''), v_user);

    RETURN jsonb_build_object(
        'sales_record_id', p_sales_record_id,
        'batch_code', v_sale.batch_code,
        'customer_code', v_cust.code,
        'amount_base', v_sale.amount_base,
        -- 补挂之后的敞口:界面据此当场说出"这一挂把敞口推到了多少"
        'exposure_after', v_exposure,
        'credit_limit_base', (SELECT credit_limit_base FROM customers WHERE id = p_customer_id),
        'over_limit', COALESCE(v_exposure > (SELECT credit_limit_base FROM customers WHERE id = p_customer_id), false)
    );
END;
$function$;