CREATE OR REPLACE FUNCTION public.issue_customer_statement(p_customer_id uuid, p_from date, p_to date, p_supersede_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_d      jsonb;
    v_id     uuid := gen_random_uuid();
    v_code   text;
    v_prev   uuid;
    v_prevcd text;
BEGIN
    -- 签发是一个【动作】,不是一次阅读:比 customer_statement_data 的门更紧一档。
    PERFORM require_permission('module.finance.edit');

    -- 【算的那一支就是预览读的那一支】—— 不在这里重写一遍
    v_d := customer_statement_data(p_customer_id, p_from, p_to);

    -- ★【对不上就不寄】★ 期初/期末来自 ar_aging_asof,发生/贷记/收款来自基表 ——
    -- 两份推导【能够】分开,所以这条等式是一次真的检查,不是装饰(OPS-17)。
    -- 对不上说明是【我们这边】的算术出了问题,而不是客户欠得不对;
    -- 一份自己都对不上的对账单寄出去,是把一个内部错误变成一场客户争议。
    IF (v_d->>'ties')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'STATEMENT_DOES_NOT_TIE|%|%|%',
            (v_d->>'customer_code'), (v_d->>'tie_difference'), (v_d->>'closing_base');
    END IF;

    -- 【同一段期间已经出过 → 新起一行,把旧的标掉】(不是改旧的那一行)
    -- 数字既然变了,那就是【另一份文件】;而更正必须是一个新事件。
    SELECT id, code INTO v_prev, v_prevcd
      FROM customer_statements
     WHERE customer_id = p_customer_id
       AND period_start = p_from AND period_end = p_to
       AND superseded_at IS NULL
     ORDER BY issued_at DESC LIMIT 1;

    IF FOUND AND COALESCE(btrim(p_supersede_reason), '') = '' THEN
        RAISE EXCEPTION 'STATEMENT_SUPERSEDE_REASON_REQUIRED|%|%', v_prevcd, (v_d->>'customer_code');
    END IF;

    v_code := next_statement_code(CURRENT_DATE);

    INSERT INTO customer_statements
        (id, code, customer_id, period_start, period_end, base_currency,
         opening_base, charges_base, credits_base, receipts_base, closing_base,
         lines, by_currency, buckets, issued_by)
    VALUES (v_id, v_code, p_customer_id, p_from, p_to, (v_d->>'base_currency'),
            (v_d->>'opening_base')::numeric, (v_d->>'charges_base')::numeric,
            (v_d->>'credits_base')::numeric, (v_d->>'receipts_base')::numeric,
            (v_d->>'closing_base')::numeric,
            v_d->'lines', v_d->'by_currency', v_d->'buckets', auth.uid());

    IF v_prev IS NOT NULL THEN
        UPDATE customer_statements
           SET superseded_at = now(), superseded_by = v_id,
               superseded_reason = btrim(p_supersede_reason)
         WHERE id = v_prev;
    END IF;

    RETURN jsonb_build_object(
        'statement_id', v_id, 'code', v_code,
        'customer_code', (v_d->>'customer_code'),
        'period_start', p_from, 'period_end', p_to,
        'closing_base', (v_d->>'closing_base')::numeric,
        'no_movement', (v_d->>'no_movement')::boolean,
        'superseded', v_prevcd);
END;
$function$

;
