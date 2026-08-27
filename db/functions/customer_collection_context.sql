CREATE OR REPLACE FUNCTION public.customer_collection_context(p_customer_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c    customers%ROWTYPE;
    v_data jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');

    SELECT * INTO v_c FROM customers WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'CHASE_DATE_REQUIRED';
    END IF;
    IF p_as_of > CURRENT_DATE THEN
        -- 与 AGING_AS_OF_FUTURE / STATEMENT_PERIOD_FUTURE 同一条:
        -- 一次"发生在未来"的催收不是记录,是计划。
        RAISE EXCEPTION 'CHASE_DATE_FUTURE|%|%', p_as_of::text, CURRENT_DATE::text;
    END IF;

    -- 单日窗口:只取它 closing 那一侧。它因此天然带着 STATEMENT-1 实测出来的
    -- 那个区别 —— 已收未核销的钱不冲任何单据,所以 owed / on_account / net_due
    -- 是三个数,不是一个。
    v_data := customer_statement_data(p_customer_id, p_as_of, p_as_of);

    RETURN jsonb_build_object(
        'customer_id',      p_customer_id,
        'customer_code',    v_data->>'customer_code',
        'customer_name',    v_data->>'customer_name',
        'as_of',            p_as_of,
        'base_currency',    v_data->>'base_currency',
        'owed_base',        (v_data->>'closing_base')::numeric,
        'on_account_base',  (v_data->>'on_account_base')::numeric,
        'net_due_base',     (v_data->>'net_due_base')::numeric,
        'by_currency',      v_data->'by_currency',
        'buckets',          v_data->'buckets',
        'lines',            v_data->'lines',
        -- 【这个客户最近被催过没有】—— 命名的缺席由界面说,这里只给事实
        'last_chased_on',   (SELECT max(chased_on) FROM collection_chases
                              WHERE customer_id = p_customer_id AND superseded_at IS NULL),
        'open_promises',    (SELECT COALESCE(count(*), 0) FROM collection_promises pr
                               JOIN collection_chases ch ON ch.id = pr.chase_id
                              WHERE ch.customer_id = p_customer_id
                                AND ch.superseded_at IS NULL AND pr.outcome IS NULL),
        -- ★【还没了结的承诺，每一个带上它自己的【证据】】★
        -- 证据 = 这个承诺做出【那一天之后】，这个客户身上真的核销掉了多少。
        -- 它【不】替人下判断（一笔无关的付款到账，不该把没兑现的承诺标成兑现），
        -- 它只是让按下 kept / broken 的那个人是在读数字，不是在猜。
        -- 【为什么算在这里而不在视图里】这一支要跑 customer_statement_data，
        -- 而那支函数带 require_permission —— 放进要喂 operations_now 的视图里，
        -- 会让没有 finance 权限的读者【整个仪表盘报错】。这一支只在客户页上跑，
        -- 而记结局的人就站在那一页。
        'promises_open',    COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'promise_id',           pr.id,
                       'chase_id',             ch.id,
                       'chase_code',           ch.code,
                       'chased_on',            ch.chased_on,
                       'promised_amount_ccy',  pr.promised_amount_ccy,
                       'currency',             pr.currency,
                       'promised_amount_base', pr.promised_amount_base,
                       'promised_date',        pr.promised_date,
                       'is_overdue',           pr.promised_date < CURRENT_DATE,
                       'applied_since_base',
                           COALESCE((customer_statement_data(
                               p_customer_id, ch.chased_on, LEAST(CURRENT_DATE, p_as_of)
                           )->>'applied_base')::numeric, 0)
                   ) ORDER BY pr.promised_date)
              FROM collection_promises pr
              JOIN collection_chases   ch ON ch.id = pr.chase_id
             WHERE ch.customer_id = p_customer_id
               AND ch.superseded_at IS NULL
               AND pr.outcome IS NULL
               AND ch.chased_on <= p_as_of), '[]'::jsonb)
    );
END;
$function$

;
