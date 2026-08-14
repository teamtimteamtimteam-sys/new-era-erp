CREATE OR REPLACE FUNCTION public.record_output_sale(p_output_batch_id uuid, p_quantity numeric, p_unit_price numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_customer_id uuid DEFAULT NULL::uuid, p_sale_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_price_source text DEFAULT NULL::text, p_price_provenance jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user          uuid := auth.uid();
    v_deleted       timestamptz;
    v_remaining     numeric;
    v_code          text;
    v_new_remaining numeric;
    v_state         text;
    v_fx            numeric;
    v_amount_base    numeric;
    v_movement_ids  uuid[];
    v_available     numeric;
    v_held          numeric;
    v_committed     numeric;
    v_sale_id       uuid;
    v_sale_date     date;
    v_unit_cost     numeric;
    v_cogs          numeric;
    v_je1           jsonb;
    v_je2           jsonb;
BEGIN
    PERFORM require_permission('module.output.edit');
    IF p_sale_date IS NULL THEN
        RAISE EXCEPTION 'SALE_DATE_REQUIRED';
    END IF;
    v_sale_date := p_sale_date;
    SELECT deleted_at, remaining_qty, code INTO v_deleted, v_remaining, v_code
    FROM output_batches WHERE id = p_output_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'OUTPUT_DELETED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'SALE_QTY_INVALID';
    END IF;
    -- IOD-1:【可卖的是"可用",不是"物理剩余"】。被扣住的货仍在这批里,
    -- 但它不可动用 —— 所以拒绝必须同时说出两个数,否则人看着 remaining 够
    -- 却卖不掉,屏幕上没有任何东西解释为什么。
    -- SO-2:第三个桶,同一条理由 —— 【一个说不出 committed 的拒绝,会让人
    -- 看着"可用 0、暂扣 0"却卖不掉】,而真正的答案是"它许给了某张订单"。
    -- 消息里因此有三个数;哪一张订单由订单页与批次面板的预留清单回答。
    -- 【这一刀不从 committed 里卖】:发货消耗归 cut 4,它会带着订单行一起来。
    v_available := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                             WHERE output_batch_id = p_output_batch_id
                               AND stock_status = 'available'), 0);
    v_held := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                        WHERE output_batch_id = p_output_batch_id
                          AND stock_status = 'on_hold'), 0);
    v_committed := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                             WHERE output_batch_id = p_output_batch_id
                               AND stock_status = 'committed'), 0);
    IF p_quantity > v_available THEN
        RAISE EXCEPTION 'IOD_SALE_EXCEEDS_AVAILABLE|%|%|%|%',
            p_quantity, v_available, v_held, v_committed;
    END IF;

    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'SALE_PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【交易日】的行方买入价(tt_buy)估值 ——
    -- 收入与应收是我们将来要【卖给银行】的外币。当日无牌价即拒(FX_RATE_MISSING),
    -- 不许悄悄用最近一天的。汇率不再由调用方递入:牌价属于 fx_rates,不属于表单。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, v_sale_date, 'tt_buy');
    v_amount_base := round(p_quantity * p_unit_price * v_fx, 2);

    -- ── SAL-B:信用管控 —— 拦截【暂放在这里】,等销售订单存在就搬到下单处 ──────
    -- (docs/sales-scoping.md §6/§8:quote 无处挂、order 未建、发货是今天唯一的
    -- 咽喉。搬,不要在订单上再加第二道检查 —— 两道检查就是两份会漂的实现。)
    IF p_customer_id IS NOT NULL THEN
        DECLARE
            v_hold  boolean;
            v_limit numeric;
            v_cust_code text;
            v_exposure numeric;
        BEGIN
            SELECT credit_hold, credit_limit_base, code
            INTO v_hold, v_limit, v_cust_code
            FROM customers WHERE id = p_customer_id;
            -- 人工冻结:无论敞口多少都停发(争议发票时停货不是算术条件)
            IF v_hold THEN
                RAISE EXCEPTION 'CREDIT_HOLD|%', v_cust_code;
            END IF;
            -- 【NULL = 没设限额(放行);0 = 现款现货(任何赊销都拒)—— 相反,不是相近】
            -- 把 NULL 当 0 用会拒掉全部既有客户的销售;fixture 39A 两头钉死。
            IF v_limit IS NOT NULL THEN
                v_exposure := customer_ar_exposure_base(p_customer_id);
                -- 【本位币比较】,与审批阈值同理:单据币种比较会让 USD 客户越过
                -- SGD 客户越不过的限额(fixture 39B 用同一个判别形状钉住)
                IF v_exposure + v_amount_base > v_limit THEN
                    -- 【把数字说全】:限额、当前敞口、这一单 —— 只说"超限"等于
                    -- 让人去手算系统已经知道的三个数
                    RAISE EXCEPTION 'CREDIT_LIMIT_EXCEEDED|%|%|%|%',
                        v_cust_code, v_limit, v_exposure, v_amount_base;
                END IF;
            END IF;
        END;
    END IF;

    -- IOD-1:出货走 drain_stock —— 一次销售可能跨几个库位桶,于是写出【多行】流水。
    -- 顺序与规则收在 drain_stock 一处(见其函数头),销售这一层只说"拿这么多出来"。
    -- 【SO-2b:腿在 sales_record_movements 里,一条一行】此前这里把 v_movement_ids[1]
    -- 记进单值外键 sales_records.movement_id —— 一个列装不下多条腿,于是那一列一直
    -- 在说半句真话(而且"第一条"只是排空顺序上碰巧排在前面的那条,没有任何业务
    -- 含义)。那一列已经 DROP;下面按 drain_stock 返回的每一个 uuid 写一行腿。
    v_movement_ids := drain_stock(
        p_qty => p_quantity, p_movement_type => 'sale', p_business_date => v_sale_date,
        p_output_batch_id => p_output_batch_id, p_statuses => ARRAY['available'],
        p_notes => p_notes, p_created_by => v_user);

    -- customer_id 有效性由 FK 把关(可空:批次可能未指定客户)
    -- SAL-A(FIN-26 的卖方半边):出处是【记录】,不是从公式在不在推断。
    -- computed 必带依据;manual/NULL 不留依据 —— 空白好过编造。
    IF p_price_source IS NOT NULL AND p_price_source NOT IN ('computed', 'manual') THEN
        RAISE EXCEPTION 'PRICE_SOURCE_INVALID|%', p_price_source;
    END IF;
    IF p_price_source = 'computed' AND (p_price_provenance IS NULL OR jsonb_typeof(p_price_provenance) <> 'object') THEN
        RAISE EXCEPTION 'PROVENANCE_REQUIRED';
    END IF;

    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date, notes, created_by, price_source, price_provenance)
    VALUES (p_output_batch_id, p_customer_id, p_quantity, p_unit_price, p_currency, v_fx, v_amount_base, v_sale_date, p_notes, v_user,
            p_price_source,
            CASE WHEN p_price_source = 'computed' THEN p_price_provenance END)
    RETURNING id INTO v_sale_id;

    -- SO-2b:【一条腿一行】—— drain_stock 返回几个 uuid 就写几行。
    INSERT INTO sales_record_movements (sales_record_id, movement_id)
    SELECT v_sale_id, x FROM unnest(v_movement_ids) x;
    -- 【断言,不是假设】腿的条数必须等于 drain 返回的条数。一条都不能少:
    -- 少一条,这笔销售在台账上就有一段出库没有主人,而屏幕上什么都不会变
    -- (那正是被 DROP 掉的那一列十几周里一直在做的事)。
    IF (SELECT count(*) FROM sales_record_movements WHERE sales_record_id = v_sale_id)
       <> array_length(v_movement_ids, 1) THEN
        RAISE EXCEPTION 'SALE_LEGS_LOST|%|%', array_length(v_movement_ids, 1),
            (SELECT count(*) FROM sales_record_movements WHERE sales_record_id = v_sale_id);
    END IF;

    -- cut 2a JE#1:收入 —— 借 1100 / 贷 4000,原币行(amount_ccy = qty × price,
    -- fx 原样),USD 侧由 post_journal_entry 折算,与 amount_base 同式同值。
    v_je1 := post_journal_entry(
        v_sale_date,
        'Sale ' || v_code,
        'sale', v_sale_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '4000', 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx)));

    -- cut 2a JE#2:COGS —— 有产出腿单位成本才挂;没有则只挂收入(cogs_journal 为
    -- null),等 allocate_processing_costs 补挂(见其 COGS catch-up)。
    SELECT po.unit_cost_base INTO v_unit_cost
    FROM processing_outputs po
    WHERE po.output_batch_id = p_output_batch_id
    LIMIT 1;

    IF v_unit_cost IS NOT NULL THEN
        v_cogs := round(p_quantity * v_unit_cost, 2);
        IF v_cogs <> 0 THEN
            v_je2 := post_journal_entry(
                v_sale_date,
                'COGS ' || v_code,
                'sale', v_sale_id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_je2->>'entry_id')::uuid WHERE id = v_sale_id;
        END IF;
    END IF;

    v_new_remaining := v_remaining - p_quantity;
    v_state := CASE WHEN v_new_remaining = 0 THEN '已售罄' ELSE '部分售出' END;

    UPDATE output_batches
    SET remaining_qty = v_new_remaining,
        state = v_state,
        updated_by = v_user,
        updated_at = now()
    WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'sold', p_quantity,
        'remaining_qty', v_new_remaining,
        'state', v_state,
        'sale_id', v_sale_id,
        'amount_base', v_amount_base,
        'revenue_journal', v_je1->>'code',
        'cogs_journal', v_je2->>'code'
    );
END;
$function$

;
