CREATE OR REPLACE FUNCTION public.upsert_payroll_period(p_period_month date, p_payment_date date, p_currency text, p_fx_rate numeric, p_source_note text, p_notes text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_base     text;   -- OPS-8:本位币从 currencies.is_base 读
    v_period   record;
    v_id       uuid;
    v_code     text;
    v_el       jsonb;
    v_emp      record;
    v_seen     uuid[] := ARRAY[]::uuid[];
    v_gross    numeric;
    v_er_cpf   numeric;
    v_ee_cpf   numeric;
    v_other    numeric;
    v_net      numeric;
    v_expected numeric;
    v_count    integer := 0;
    v_t_gross  numeric := 0;
    v_t_er     numeric := 0;
    v_t_ee     numeric := 0;
    v_t_other  numeric := 0;
    v_t_net    numeric := 0;
BEGIN
    -- OPS-8:本位币是【数据】(currencies.is_base),不是字面量。
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    PERFORM require_permission('module.hr.edit');
    IF p_period_month IS NULL OR p_period_month <> date_trunc('month', p_period_month)::date THEN
        RAISE EXCEPTION 'PERIOD_MONTH_INVALID|%', COALESCE(p_period_month::text, '?');
    END IF;
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_fx_rate IS NULL OR p_fx_rate <= 0 THEN
        RAISE EXCEPTION 'FX_RATE_INVALID|%', COALESCE(p_fx_rate::text, '?');
    END IF;
    -- FIN-0:本位币期间的 fx_rate 只能是 1(OPS-8:本位币问 currencies.is_base,
    -- 不写 'SGD' —— 这一句自己的注释就承认它判的是本位币)
    IF p_currency = v_base AND p_fx_rate <> 1 THEN
        RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
    END IF;
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    SELECT * INTO v_period FROM payroll_periods
    WHERE period_month = p_period_month AND deleted_at IS NULL
    FOR UPDATE;

    IF FOUND THEN
        -- 已过账的周期不接受重导:先 unpost 才能改(总账已经认了这批数)
        IF v_period.status = 'posted' THEN
            RAISE EXCEPTION 'PAYROLL_POSTED|%', v_period.code;
        END IF;
        v_id := v_period.id;
        v_code := v_period.code;
        UPDATE payroll_periods
        SET payment_date = p_payment_date, currency = p_currency, fx_rate = p_fx_rate,
            source_note = p_source_note, notes = p_notes, updated_by = v_user
        WHERE id = v_id;
        DELETE FROM payroll_lines WHERE payroll_period_id = v_id;
    ELSE
        v_id := gen_random_uuid();
        v_code := next_payroll_code(p_period_month);
        INSERT INTO payroll_periods (id, code, period_month, payment_date, currency, fx_rate,
                                     source_note, notes, created_by, updated_by)
        VALUES (v_id, v_code, p_period_month, p_payment_date, p_currency, p_fx_rate,
                p_source_note, p_notes, v_user, v_user);
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        SELECT id, code INTO v_emp FROM employees
        WHERE id = (v_el->>'employee_id')::uuid AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', COALESCE(v_el->>'employee_id', '?');
        END IF;
        IF v_emp.id = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_EMPLOYEE|%', v_emp.code;
        END IF;
        v_seen := v_seen || v_emp.id;

        v_gross  := (v_el->>'gross_pay')::numeric;
        v_er_cpf := COALESCE((v_el->>'employer_cpf')::numeric, 0);
        v_ee_cpf := COALESCE((v_el->>'employee_cpf')::numeric, 0);
        v_other  := COALESCE((v_el->>'other_deductions')::numeric, 0);
        v_net    := (v_el->>'net_pay')::numeric;

        IF v_gross IS NULL OR v_net IS NULL
           OR v_gross < 0 OR v_er_cpf < 0 OR v_ee_cpf < 0 OR v_other < 0 OR v_net < 0 THEN
            RAISE EXCEPTION 'AMOUNT_INVALID|%', v_emp.code;
        END IF;

        -- 服务商给的行必须自洽。这是本函数【唯一】的算术 —— 不是在算工资,
        -- 是在把录错/解析错的一行挡在总账之外。
        v_expected := round(v_gross - v_ee_cpf - v_other, 2);
        IF v_expected <> round(v_net, 2) THEN
            RAISE EXCEPTION 'LINE_NOT_BALANCED|%|%|%', v_emp.code, v_expected, round(v_net, 2);
        END IF;

        INSERT INTO payroll_lines (payroll_period_id, employee_id, gross_pay, employer_cpf,
                                   employee_cpf, other_deductions, net_pay, notes)
        VALUES (v_id, v_emp.id, v_gross, v_er_cpf, v_ee_cpf, v_other, v_net, v_el->>'notes');

        v_count := v_count + 1;
        v_t_gross := v_t_gross + v_gross;
        v_t_er    := v_t_er + v_er_cpf;
        v_t_ee    := v_t_ee + v_ee_cpf;
        v_t_other := v_t_other + v_other;
        v_t_net   := v_t_net + v_net;
    END LOOP;

    UPDATE payroll_periods
    SET gross_total = round(v_t_gross, 2),
        employer_cpf_total = round(v_t_er, 2),
        employee_cpf_total = round(v_t_ee, 2),
        other_deductions_total = round(v_t_other, 2),
        net_pay_total = round(v_t_net, 2),
        updated_by = v_user
    WHERE id = v_id;

    RETURN jsonb_build_object(
        'payroll_period_id', v_id,
        'code', v_code,
        'line_count', v_count,
        'gross_total', round(v_t_gross, 2),
        'employer_cpf_total', round(v_t_er, 2),
        'employee_cpf_total', round(v_t_ee, 2),
        'other_deductions_total', round(v_t_other, 2),
        'net_pay_total', round(v_t_net, 2)
    );
END;
$function$;