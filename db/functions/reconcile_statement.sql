CREATE OR REPLACE FUNCTION public.reconcile_statement(p_statement_id uuid, p_variance_items jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_stmt        record;
    v_outstanding integer;
    v_matched     integer;
    v_ignored     integer;
    v_book        numeric;
    v_diff        numeric;
    v_items       jsonb;
    v_item        jsonb;
    v_idx         integer := 0;
    v_explained   numeric := 0;
    v_recon_id    uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_stmt FROM bank_statements
    WHERE id = p_statement_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STATEMENT_NOT_FOUND|%', p_statement_id;
    END IF;
    IF v_stmt.status <> 'open' THEN
        RAISE EXCEPTION 'STATEMENT_ALREADY_RECONCILED|%', v_stmt.code;
    END IF;

    SELECT count(*) FILTER (WHERE match_status = 'unmatched'),
           count(*) FILTER (WHERE match_status = 'matched'),
           count(*) FILTER (WHERE match_status = 'ignored')
    INTO v_outstanding, v_matched, v_ignored
    FROM bank_statement_lines
    WHERE statement_id = p_statement_id;

    -- 【第一道:行覆盖率】这一条本来就有,顺序不动 —— 行还没处理完时,
    -- 余额差额几乎必然也对不上,先报那个会把人指向错误的方向。
    IF v_outstanding > 0 THEN
        RAISE EXCEPTION 'LINES_OUTSTANDING|%', v_outstanding;
    END IF;

    -- 【第二道:余额一致 —— 本刀补的就是它】
    -- 账面余额从 bank_book_balance_asof 来,与银行首页那个数【同一份算术】。
    v_book := bank_book_balance_asof(v_stmt.bank_account_code, v_stmt.period_end);
    v_diff := round(v_book - v_stmt.closing_balance, 2);

    v_items := CASE WHEN p_variance_items IS NULL THEN '[]'::jsonb ELSE p_variance_items END;
    IF jsonb_typeof(v_items) <> 'array' THEN
        RAISE EXCEPTION 'VARIANCE_ITEMS_INVALID';
    END IF;

    IF jsonb_array_length(v_items) = 0 THEN
        -- 【没有说明】那么两个数字必须自己相等。**不设容差** ——
        -- 容差就是"带阈值的未解释差额",而下面那一支已经给了诚实的出口。
        IF v_diff <> 0 THEN
            RAISE EXCEPTION 'BALANCE_DISAGREES|%|%|%',
                v_stmt.closing_balance, v_book, v_diff;
        END IF;
    ELSE
        -- 【有说明,却没有差额】说明是用来解释差额的;没有差额就没有要解释的东西。
        -- 放行等于允许一份自相矛盾的记录。
        IF v_diff = 0 THEN
            RAISE EXCEPTION 'VARIANCE_NOT_APPLICABLE';
        END IF;

        FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
            v_idx := v_idx + 1;
            IF COALESCE(v_item->>'amount', '') !~ '^-?[0-9]+(\.[0-9]+)?$'
               OR (v_item->>'amount')::numeric = 0 THEN
                RAISE EXCEPTION 'VARIANCE_AMOUNT_INVALID|%', v_idx;
            END IF;
            IF btrim(COALESCE(v_item->>'note', '')) = '' THEN
                RAISE EXCEPTION 'VARIANCE_NOTE_REQUIRED|%', v_idx;
            END IF;
            IF COALESCE(v_item->>'kind', '') NOT IN ('unpresented_cheque', 'deposit_in_transit',
                    'bank_charge', 'bank_interest', 'timing', 'error_to_correct') THEN
                RAISE EXCEPTION 'VARIANCE_KIND_INVALID|%', COALESCE(v_item->>'kind', '');
            END IF;
            v_explained := v_explained + round((v_item->>'amount')::numeric, 2);
        END LOOP;

        -- 【逐项金额必须【恰好】等于差额】否则"这是原因"就只是一句放在差额旁边的
        -- 注解,而不是对差额的【交代】—— 金额那一栏会退化成装饰。
        IF round(v_explained, 2) <> v_diff THEN
            RAISE EXCEPTION 'VARIANCE_UNEXPLAINED|%|%', v_diff, round(v_explained, 2);
        END IF;
    END IF;

    -- ★【说明【不】把两个数字抹平】★ book_balance 与 bank_closing_balance 原样抄下,
    --   difference 原样留着。报表是 reconciled,而它身上写着差多少、为什么。
    INSERT INTO bank_reconciliations (
        statement_id, as_of, currency, bank_closing_balance, book_balance, difference,
        matched_lines, ignored_lines)
    VALUES (p_statement_id, v_stmt.period_end, v_stmt.currency,
            v_stmt.closing_balance, v_book, v_diff, v_matched, v_ignored)
    RETURNING id INTO v_recon_id;

    IF jsonb_array_length(v_items) > 0 THEN
        INSERT INTO bank_reconciliation_variance_items (
            reconciliation_id, item_no, item_kind, amount, note)
        SELECT v_recon_id,
               ordinality::integer,
               it->>'kind',
               round((it->>'amount')::numeric, 2),
               btrim(it->>'note')
        FROM jsonb_array_elements(v_items) WITH ORDINALITY AS e(it, ordinality);
    END IF;

    UPDATE bank_statements
    SET status = 'reconciled', reconciled_at = now(), reconciled_by = auth.uid()
    WHERE id = p_statement_id;

    RETURN jsonb_build_object(
        'statement_id', p_statement_id,
        'reconciliation_id', v_recon_id,
        'code', v_stmt.code,
        'matched_lines', v_matched,
        'ignored_lines', v_ignored,
        'closing_balance', v_stmt.closing_balance,
        'book_balance', v_book,
        'difference', v_diff,
        'variance_items', jsonb_array_length(v_items)
    );
END;
$function$;