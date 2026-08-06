-- db/functions/preview_close_financial_year.sql
-- 年结算术与前置检查的唯一来源(FIN-23)。写入侧(close_financial_year)问它,
-- 界面也问它 —— 同一份算术(ask-the-database)。结转额 = 各损益科目【截至年末的
-- 累计净额】(含既往 year_close 分录:结转后累计归零 → 幂等靠算术)。
-- 【结转科目按 account_type 推导,永不用编号区间】—— 区间会无声漏掉 7100/7110/7200。
-- 下一个应结财年:首结看 first_fy_end(申报的长/短首年),否则从 system_start
-- 所在年的循环日(fy_end_month/day,短月收敛)起;此后逐年顺推。
-- 硬前置报状态(写入侧点名拒),软警告(草稿薪资/未清应计)只提示不拦。

CREATE OR REPLACE FUNCTION public.preview_close_financial_year(p_year_end date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_fs       record;
    v_prev     date;
    v_expected date;
    v_end      date;
    v_y        integer;
    v_rows     jsonb := '[]'::jsonb;
    v_net      numeric := 0;
    v_a        record;
    v_d        numeric;
    v_c        numeric;
    v_reval    jsonb;
    v_dep      jsonb;
    v_start    date;
    v_payroll  integer;
    v_accruals integer;
    v_already  boolean;
BEGIN
    PERFORM require_permission('module.finance.view');
    SELECT * INTO v_fs FROM finance_settings WHERE id;

    -- 推导下一个应结财年末:首结看 first_fy_end(申报的长/短首年),否则从
    -- system_start 所在年的循环日起;此后 = 上一个仍有效年结之后的第一个循环日。
    -- 短月收敛:fy_end_day 超出该月天数时取月末。
    SELECT MAX(year_end) INTO v_prev FROM year_closes WHERE reopened_at IS NULL;
    IF v_prev IS NULL THEN
        IF v_fs.first_fy_end IS NOT NULL THEN
            v_expected := v_fs.first_fy_end;
        ELSIF v_fs.system_start_date IS NOT NULL THEN
            v_y := EXTRACT(year FROM v_fs.system_start_date)::integer;
            v_expected := make_date(v_y, v_fs.fy_end_month,
                LEAST(v_fs.fy_end_day,
                      EXTRACT(day FROM (date_trunc('month', make_date(v_y, v_fs.fy_end_month, 1))
                                        + interval '1 month - 1 day'))::integer));
            IF v_expected < v_fs.system_start_date THEN
                v_y := v_y + 1;
                v_expected := make_date(v_y, v_fs.fy_end_month,
                    LEAST(v_fs.fy_end_day,
                          EXTRACT(day FROM (date_trunc('month', make_date(v_y, v_fs.fy_end_month, 1))
                                            + interval '1 month - 1 day'))::integer));
            END IF;
        END IF;
    ELSE
        v_y := EXTRACT(year FROM v_prev)::integer;
        v_expected := make_date(v_y, v_fs.fy_end_month,
            LEAST(v_fs.fy_end_day,
                  EXTRACT(day FROM (date_trunc('month', make_date(v_y, v_fs.fy_end_month, 1))
                                    + interval '1 month - 1 day'))::integer));
        IF v_expected <= v_prev THEN
            v_y := v_y + 1;
            v_expected := make_date(v_y, v_fs.fy_end_month,
                LEAST(v_fs.fy_end_day,
                      EXTRACT(day FROM (date_trunc('month', make_date(v_y, v_fs.fy_end_month, 1))
                                        + interval '1 month - 1 day'))::integer));
        END IF;
    END IF;

    v_end := COALESCE(p_year_end, v_expected);
    IF v_end IS NULL THEN
        RAISE EXCEPTION 'SYSTEM_START_NOT_SET';
    END IF;
    v_already := EXISTS (SELECT 1 FROM year_closes WHERE year_end = v_end AND reopened_at IS NULL);

    -- 各损益科目截至年末的累计净额(贷正)—— 【按 account_type 推导,不用编号区间】
    FOR v_a IN
        SELECT a.code, a.account_type, round(SUM(jl.credit) - SUM(jl.debit), 2) AS net
        FROM journal_lines jl
        JOIN accounts a ON a.id = jl.account_id
        JOIN journal_entries je ON je.id = jl.entry_id
        WHERE a.account_type IN ('revenue', 'cogs', 'expense')
          AND je.entry_date <= v_end
        GROUP BY a.code, a.account_type
        HAVING round(SUM(jl.credit) - SUM(jl.debit), 2) <> 0
        ORDER BY a.code
    LOOP
        v_net := v_net + v_a.net;
        v_rows := v_rows || jsonb_build_object('account', v_a.code,
            'account_type', v_a.account_type, 'net', v_a.net);
    END LOOP;

    -- 硬前置(写入侧逐条点名拒绝;这里报状态供界面亮灯)
    SELECT round(COALESCE(SUM(jl.debit), 0), 2), round(COALESCE(SUM(jl.credit), 0), 2)
    INTO v_d, v_c
    FROM journal_lines jl JOIN journal_entries je ON je.id = jl.entry_id
    WHERE je.entry_date <= v_end;
    v_reval := preview_revalue_foreign_balances(v_end);
    v_dep := preview_depreciate_fixed_assets(v_end);

    -- 软警告:年内未过账的薪资期间;仍挂着的应计成本条目(年末应计是正常会计,
    -- 只提示复核,不拦)。
    SELECT count(*) INTO v_payroll FROM payroll_periods
    WHERE deleted_at IS NULL AND status <> 'posted'
      AND period_month >= date_trunc('year', v_end)::date AND period_month <= v_end;
    SELECT count(*) INTO v_accruals FROM processing_cost_entries
    WHERE deleted_at IS NULL AND remitted_at IS NULL AND relieved_at IS NULL
      AND created_at <= v_end + interval '1 day';

    RETURN jsonb_build_object(
        'year_end', v_end,
        'expected_year_end', v_expected,
        'already_closed', v_already,
        'rows', v_rows,
        'net_result', round(v_net, 2),
        'final_period_closed', (v_fs.locked_before IS NOT NULL AND v_fs.locked_before > v_end),
        'trial_balanced', (v_d = v_c),
        'revaluation_level', (jsonb_array_length(v_reval->'missing_rates') = 0
                              AND (v_reval->>'total_adjustment')::numeric = 0),
        'depreciation_level', ((v_dep->>'total_delta')::numeric = 0),
        'draft_payroll_count', v_payroll,
        'open_accrual_count', v_accruals
    );
END;
$function$;
