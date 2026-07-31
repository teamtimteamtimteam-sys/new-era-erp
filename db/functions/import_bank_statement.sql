CREATE OR REPLACE FUNCTION public.import_bank_statement(p_bank_account text, p_period_start date, p_period_end date, p_opening numeric, p_closing numeric, p_file_name text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_ccy          text;
    v_statement_id uuid := gen_random_uuid();
    v_year         integer;
    v_seq          integer;
    v_code         text;
    v_line         jsonb;
    v_no           integer := 0;
    v_amount       numeric;
    v_date         date;
    v_sum          numeric := 0;
    v_overlaps     integer;
    v_dups         integer := 0;
BEGIN
    v_ccy := bank_native_currency(p_bank_account);
    IF v_ccy IS NULL THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_bank_account, '?');
    END IF;
    IF p_period_start IS NULL OR p_period_end IS NULL OR p_period_end < p_period_start THEN
        RAISE EXCEPTION 'PERIOD_INVALID|%|%', COALESCE(p_period_start::text,'?'), COALESCE(p_period_end::text,'?');
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- 先整体校验(金额为非零数字、日期在期间内)并求 Σ
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_no := v_no + 1;
        IF jsonb_typeof(v_line->'amount') <> 'number' OR (v_line->>'amount')::numeric = 0 THEN
            RAISE EXCEPTION 'LINE_AMOUNT_INVALID|%', v_no;
        END IF;
        v_amount := (v_line->>'amount')::numeric;
        v_date := (v_line->>'line_date')::date;
        IF v_date IS NULL OR v_date < p_period_start OR v_date > p_period_end THEN
            RAISE EXCEPTION 'LINE_DATE_OUT_OF_RANGE|%|%', v_no, COALESCE(v_date::text, '?');
        END IF;
        v_sum := v_sum + v_amount;

        -- 疑似重复(同账户其他在册报表上已有同日期+同金额+同摘要的行)—— 只计数
        SELECT v_dups + count(*) INTO v_dups
        FROM bank_statement_lines l
        JOIN bank_statements s ON s.id = l.statement_id
        WHERE s.bank_account_code = p_bank_account
          AND s.deleted_at IS NULL
          AND l.line_date = v_date
          AND l.amount = v_amount
          AND l.description IS NOT DISTINCT FROM (v_line->>'description');
    END LOOP;

    -- 余额恒等式:opening + Σ = closing
    IF round(p_opening + v_sum, 2) IS DISTINCT FROM round(p_closing, 2) THEN
        RAISE EXCEPTION 'STATEMENT_NOT_BALANCED|%|%', round(p_opening + v_sum, 2), round(p_closing, 2);
    END IF;

    -- 期间重叠警告(不拦)
    SELECT count(*) INTO v_overlaps
    FROM bank_statements s
    WHERE s.bank_account_code = p_bank_account
      AND s.deleted_at IS NULL
      AND s.period_start <= p_period_end
      AND s.period_end >= p_period_start;

    -- 无缝编号:咨询锁串行化"取当年最大号+1"(同 JE/收付款/开支手法)
    v_year := EXTRACT(YEAR FROM p_period_end)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('bank_stmt_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM bank_statements
    WHERE code LIKE 'BS-' || v_year::text || '-%';
    v_code := 'BS-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    INSERT INTO bank_statements (id, code, bank_account_code, currency, period_start, period_end,
                                 opening_balance, closing_balance, file_name)
    VALUES (v_statement_id, v_code, p_bank_account, v_ccy, p_period_start, p_period_end,
            p_opening, p_closing, p_file_name);

    -- 行按数组顺序编号
    v_no := 0;
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_no := v_no + 1;
        INSERT INTO bank_statement_lines (statement_id, line_no, line_date, description, reference, amount)
        VALUES (v_statement_id, v_no, (v_line->>'line_date')::date,
                v_line->>'description', v_line->>'reference', (v_line->>'amount')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'statement_id', v_statement_id,
        'code', v_code,
        'line_count', v_no,
        'overlapping_statements', v_overlaps,
        'possible_duplicates', v_dups
    );
END;
$function$
