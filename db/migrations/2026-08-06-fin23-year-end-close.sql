-- db/migrations/2026-08-06-fin23-year-end-close.sql
--
-- FIN-23:年结。
--
-- 【财年是申报的配置】fy_end_month/fy_end_day(Tim 定为 12/31)+ 可空的
-- first_fy_end:新加坡首个财年可长达 18 个月,Tim 尚未定首年是 2026-12-31 还是
-- 顺延 —— 留空按循环推;定了就以显式日期为准。与 system_start_date 同款:申报,
-- 不推断。finance_settings 是 RUNTIME CONFIG:引导默认 12/31 就是申报值,正确。
--
-- 【结转科目按 account_type 推导,永不用编号区间】4000-6999 这种区间会无声漏掉
-- 7100/7110/7200 —— 全是损益、全是 chart 定型之后加的;留存收益就恰好错掉一个
-- 汇兑结果,而且没有任何东西会说。与 is_monetary、币种字面量同一课:按属性分类,
-- 不按数字。fixture 17 的 FX 臂就是抓这一条的。
--
-- 【幂等靠算术】结转额 = 各损益科目【截至年末的累计净额】(含既往年结分录)。
-- 结转之后累计归零 → 第二次跑算出全零,什么都不过账。与重估、折旧同形。
--
-- 【报表的不对称,有意为之】损益表【剔除】year_close 分录(否则结转把当年损益表
-- 清成零 —— 报表按日期区间聚合分录行,结转分录恰好落在区间内);资产负债表
-- 【包含】它(已结年度的损益行合计归零,3100 接住结果,合成的"本期损益"行只剩
-- 结转后的活动 —— 自洽)。两处查询旁各有注释互指。
--
-- 【已结年度的独立守卫】locked_before 是一条会动的线:reopen_period(月级,合法
-- 动作)会把它退回已结年度之内,回填分录进去,留存收益就悄悄错了。所以
-- post_journal_entry 加第二道与月锁无关的闸:日期落进【仍有效】年结的一律
-- YEAR_CLOSED 拒绝,排在月锁之前(两者都命中时,年是更强的事实)。年结自己的
-- 分录凭 evoltrya.close_ctx GUC 过两道闸(movement_ctx/price_ctx 同款把门):
-- 结转分录在 year_closes 行落库【之前】过账,冲销分录凭 ctx 过、随后一次性盖章。
--
-- 【关年不动锁】前置硬校验要求 locked_before 已在年末之后(月结推的),关年只
-- 【断言】锁位,不动它;重开年也不动 —— 月锁与年闸各管各的,要改 12 月就
-- reopen_period(留痕),年闸已由 reopen_financial_year 抬起。

BEGIN;

-- ── 1. 财年配置(申报,不推断)──────────────────────────────────────────
ALTER TABLE public.finance_settings ADD COLUMN fy_end_month integer NOT NULL DEFAULT 12
    CHECK (fy_end_month BETWEEN 1 AND 12);
ALTER TABLE public.finance_settings ADD COLUMN fy_end_day integer NOT NULL DEFAULT 31
    CHECK (fy_end_day BETWEEN 1 AND 31);
ALTER TABLE public.finance_settings ADD COLUMN first_fy_end date;

COMMENT ON COLUMN public.finance_settings.fy_end_month IS
    '财年末的月份(FIN-23,申报值 —— 新加坡公司自选财年,不得假设 12/31)。与 fy_end_day 一起推导每个财年末;首年可被 first_fy_end 覆盖。';
COMMENT ON COLUMN public.finance_settings.fy_end_day IS
    '财年末的日(FIN-23)。短月自动收敛到月末(2/30 → 2/28)。';
COMMENT ON COLUMN public.finance_settings.first_fy_end IS
    '首个财年末(FIN-23,可空)。新加坡首个财年可长达 18 个月 —— 留空按循环对推;定了以此为准。只影响第一次年结。';

-- ── 2. source_type += year_close ─────────────────────────────────────────
ALTER TABLE public.journal_entries DROP CONSTRAINT journal_entries_source_type_check;
ALTER TABLE public.journal_entries ADD CONSTRAINT journal_entries_source_type_check
    CHECK (source_type IN ('manual','purchase','sale','processing_cost','allocation','stocktake',
                           'writeoff','payment','fx','expense','prepayment','payroll','transfer',
                           'revaluation','depreciation','asset_disposal','year_close'));

-- ── 3. 年结日志 ──────────────────────────────────────────────────────────
CREATE TABLE public.year_closes (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    year_end            date NOT NULL,
    closing_journal_id  uuid NOT NULL REFERENCES public.journal_entries (id),
    net_result          numeric NOT NULL,   -- 贷方为正 = 盈利
    notes               text,
    closed_at           timestamptz NOT NULL DEFAULT now(),
    closed_by           uuid,
    reopened_at         timestamptz,
    reopened_by         uuid,
    reopen_reason       text,
    reversal_journal_id uuid REFERENCES public.journal_entries (id)
);

COMMENT ON TABLE public.year_closes IS
    '年结日志(FIN-23)。一行 = 一次年结;重开盖 reopened_* 章并记冲销分录,行保留(审计)。【仍有效】(reopened_at IS NULL)的年结驱动 post_journal_entry 的 YEAR_CLOSED 闸 —— 与 locked_before 无关的第二道防线,月级 reopen_period 退锁穿不透它。';

CREATE UNIQUE INDEX idx_year_closes_active ON public.year_closes (year_end) WHERE reopened_at IS NULL;

-- IMMUTABLE:只放行"重开盖章"这一种 UPDATE(reopened_at NULL→非空,同一动作里
-- 记下冲销分录),其余列锁死;禁 DELETE。period_closes 同款。
CREATE OR REPLACE FUNCTION public.reject_year_close_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'YEAR_CLOSE_IMMUTABLE';
    END IF;
    IF OLD.reopened_at IS NULL AND NEW.reopened_at IS NOT NULL
       AND NEW.year_end = OLD.year_end
       AND NEW.closing_journal_id = OLD.closing_journal_id
       AND NEW.net_result = OLD.net_result
       AND NEW.closed_at = OLD.closed_at
       AND NEW.reopen_reason IS NOT NULL THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'YEAR_CLOSE_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_year_closes_immutable
    BEFORE UPDATE OR DELETE ON public.year_closes
    FOR EACH ROW EXECUTE FUNCTION public.reject_year_close_mutation();

ALTER TABLE public.year_closes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "year_closes select by permission" ON public.year_closes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
-- 写入只经 SECURITY DEFINER 函数;不开 INSERT/UPDATE/DELETE 策略。

-- ── 4. post_journal_entry:YEAR_CLOSED 闸(月锁之前)+ 月锁的 close_ctx 例外 ──
CREATE OR REPLACE FUNCTION public.post_journal_entry(p_entry_date date, p_memo text, p_source_type text, p_source_id uuid, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_locked       date;
    v_year_closed  date;   -- FIN-23:命中的最晚仍有效年结
    v_line         jsonb;
    v_account      record;
    v_side         text;
    v_currency     text;
    v_amount       numeric;
    v_fx           numeric;
    v_usd          numeric;
    v_fx_date      date;
    v_base         text;
    v_total_debit  numeric := 0;
    v_total_credit numeric := 0;
    v_count        integer := 0;
    v_year         integer;
    v_seq          integer;
    v_code         text;
    v_entry_id     uuid;
BEGIN
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    IF p_entry_date IS NULL THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【FIN-23:已结年度守卫 —— 与月锁无关的第二道闸,排在月锁之前】
    -- locked_before 是一条会动的线:reopen_period(月级、合法、留痕)会把它退回
    -- 已结年度之内 —— 回填分录进去,损益科目再动,留存收益就悄悄错了。这道闸
    -- 不跟着锁退:日期落进【仍有效】年结(year_closes.reopened_at IS NULL)的
    -- 一律点名拒绝。两道都命中时报 YEAR_CLOSED —— 年是更强的事实。
    -- 年结自己的分录凭 evoltrya.close_ctx 过(close_financial_year /
    -- reopen_financial_year 在同一事务内设置,用毕即清 —— movement_ctx 同款);
    -- 结转分录在 year_closes 行落库之前过账,本闸对它本就无感,ctx 是给
    -- 重开的冲销分录用的(先过账、后一次性盖章)。
    -- ════════════════════════════════════════════════════════════════════════
    IF NOT (p_source_type = 'year_close'
            AND current_setting('evoltrya.close_ctx', true) = 'year_close') THEN
        SELECT MAX(yc.year_end) INTO v_year_closed
        FROM year_closes yc
        WHERE yc.reopened_at IS NULL AND p_entry_date <= yc.year_end;
        IF v_year_closed IS NOT NULL THEN
            RAISE EXCEPTION 'YEAR_CLOSED|%|%', p_entry_date, v_year_closed;
        END IF;
    END IF;

    -- 期间锁:早于 locked_before 的日期拒绝。
    -- 例外(FIN-23):年结分录及其冲销必须写进已被月结锁住的年末 ——
    -- 仅当 source_type='year_close' 且 close_ctx 在场时放行,别无他路。
    SELECT locked_before INTO v_locked FROM finance_settings WHERE id;
    IF v_locked IS NOT NULL AND p_entry_date < v_locked
       AND NOT (p_source_type = 'year_close'
                AND current_setting('evoltrya.close_ctx', true) = 'year_close') THEN
        RAISE EXCEPTION 'PERIOD_LOCKED|%|%', p_entry_date, v_locked;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|lines';
    END IF;

    -- 无缝编号:咨询锁串行化"取当年最大号+1";失败回滚会释放号码。
    PERFORM pg_advisory_xact_lock(hashtext('je_code')::bigint);
    v_year := EXTRACT(YEAR FROM p_entry_date)::integer;
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM journal_entries
    WHERE code LIKE 'JE-' || v_year::text || '-%';
    v_code := 'JE-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    INSERT INTO journal_entries (code, entry_date, memo, source_type, source_id)
    VALUES (v_code, p_entry_date, p_memo, p_source_type, p_source_id)
    RETURNING id INTO v_entry_id;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_count := v_count + 1;

        SELECT id, code, is_active INTO v_account
        FROM accounts WHERE code = v_line->>'account_code';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%', COALESCE(v_line->>'account_code', '?');
        END IF;
        IF NOT v_account.is_active THEN
            RAISE EXCEPTION 'ACCOUNT_INACTIVE|%', v_account.code;
        END IF;

        v_side := v_line->>'side';
        IF v_side IS NULL OR v_side NOT IN ('debit', 'credit') THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|side';
        END IF;

        v_amount := (v_line->>'amount_ccy')::numeric;
        IF v_amount IS NULL OR v_amount <= 0 THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|amount_ccy';
        END IF;

        v_currency := v_line->>'currency';
        IF v_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = v_currency) THEN
            RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(v_currency, '?');
        END IF;

        v_fx_date := NULLIF(v_line->>'fx_rate_date', '')::date;
        IF v_currency = v_base THEN
            v_fx := 1;
            v_fx_date := NULL;  -- 本位币没有取自哪天这回事  -- 本位币(FIN-0 起为 SGD)强制 1,忽略传入值
        ELSE
            v_fx := (v_line->>'fx_rate')::numeric;
            IF v_fx IS NULL THEN
                RAISE EXCEPTION 'FX_RATE_REQUIRED|%', v_currency;
            END IF;
            IF v_fx <= 0 THEN
                RAISE EXCEPTION 'JE_LINE_INVALID|fx_rate';
            END IF;
        END IF;

        v_usd := round(v_amount * v_fx, 2);

        INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate, fx_rate_date, line_memo)
        VALUES (
            v_entry_id,
            v_account.id,
            CASE WHEN v_side = 'debit'  THEN v_usd ELSE 0 END,
            CASE WHEN v_side = 'credit' THEN v_usd ELSE 0 END,
            v_currency,
            v_amount,
            v_fx,
            v_fx_date,
            v_line->>'line_memo'
        );

        IF v_side = 'debit' THEN
            v_total_debit := v_total_debit + v_usd;
        ELSE
            v_total_credit := v_total_credit + v_usd;
        END IF;
    END LOOP;

    -- 空数组/单行:延迟触发器只在有行插入时排队,这里提前拦掉(否则空分录溜过)
    IF v_count < 2 THEN
        RAISE EXCEPTION 'JOURNAL_UNBALANCED|%|%|%', v_code, v_total_debit, v_total_credit;
    END IF;

    -- Σdebit = Σcredit 由 DEFERRED 触发器在提交时强制
    RETURN jsonb_build_object(
        'entry_id', v_entry_id,
        'code', v_code,
        'total_debit', v_total_debit,
        'total_credit', v_total_credit
    );
END;
$function$;

-- ── 5. 预览:算术与前置检查的唯一来源 ────────────────────────────────────
-- 结转额 = 各损益科目【截至年末的累计净额】(含既往 year_close 分录 ——
-- 结转后累计归零,第二次算出全零:幂等靠算术)。报表侧相反:损益表【剔除】
-- year_close(见 app/finance/pnl/page.tsx 的注释,两处互指)。
-- p_year_end 可空:空 = 推导出的下一个应结财年(界面要先知道该结哪年)。
-- 写入侧(close_financial_year)日期必填,不受此默认影响。
CREATE OR REPLACE FUNCTION public.preview_close_financial_year(p_year_end date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
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

-- ── 6. 关年 ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.close_financial_year(p_year_end date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_fs       record;
    v_preview  jsonb;
    v_r        jsonb;
    v_lines    jsonb := '[]'::jsonb;
    v_net      numeric;
    v_amt      numeric;
    v_je       jsonb;
    v_close_id uuid := gen_random_uuid();
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_year_end IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;
    -- 串行化(与月结同一把锁)
    SELECT * INTO v_fs FROM finance_settings WHERE id FOR UPDATE;

    v_preview := preview_close_financial_year(p_year_end);

    -- 幂等出口:已结(累计已归零)→ 什么都不做,原样说明
    IF (v_preview->>'already_closed')::boolean THEN
        RETURN jsonb_build_object('year_end', p_year_end, 'net_result', 0,
                                  'journal_code', NULL, 'already_closed', true);
    END IF;

    -- 只能结【推导出的下一个财年】—— 乱序关年会把留存收益链条打断
    IF p_year_end <> (v_preview->>'expected_year_end')::date THEN
        RAISE EXCEPTION 'YEAR_END_INVALID|%|%', p_year_end, v_preview->>'expected_year_end';
    END IF;

    -- 硬前置,逐条点名(软警告不在此列 —— 年末应计与草稿薪资由界面提示复核)
    IF NOT (v_preview->>'final_period_closed')::boolean THEN
        RAISE EXCEPTION 'FINAL_PERIOD_NOT_CLOSED|%|%', p_year_end,
            COALESCE(v_fs.locked_before::text, '(unlocked)');
    END IF;
    IF NOT (v_preview->>'trial_balanced')::boolean THEN
        RAISE EXCEPTION 'TRIAL_BALANCE_UNBALANCED|%', p_year_end;
    END IF;
    IF NOT (v_preview->>'revaluation_level')::boolean THEN
        RAISE EXCEPTION 'REVALUATION_NOT_RUN|%', p_year_end;
    END IF;
    IF NOT (v_preview->>'depreciation_level')::boolean THEN
        RAISE EXCEPTION 'DEPRECIATION_NOT_RUN|%', p_year_end;
    END IF;

    v_net := (v_preview->>'net_result')::numeric;

    -- 结转行:把每个非零损益科目清零(贷余借清、借余贷清),净额对 3100
    FOR v_r IN SELECT * FROM jsonb_array_elements(v_preview->'rows')
    LOOP
        v_amt := (v_r->>'net')::numeric;
        v_lines := v_lines || jsonb_build_object(
            'account_code', v_r->>'account',
            'side', CASE WHEN v_amt > 0 THEN 'debit' ELSE 'credit' END,
            'currency', 'SGD', 'amount_ccy', abs(v_amt), 'fx_rate', 1,
            'line_memo', 'year-end close');
    END LOOP;

    IF jsonb_array_length(v_lines) = 0 THEN
        -- 全年损益净额与逐科目都为零(空年)—— 无可结转,不留分录不留行
        RETURN jsonb_build_object('year_end', p_year_end, 'net_result', 0,
                                  'journal_code', NULL, 'already_closed', false);
    END IF;

    IF v_net <> 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '3100',
            'side', CASE WHEN v_net > 0 THEN 'credit' ELSE 'debit' END,
            'currency', 'SGD', 'amount_ccy', abs(v_net), 'fx_rate', 1,
            'line_memo', 'net result to retained earnings');
    END IF;

    -- 结转分录日期 = 年末,而年末已被月结锁住(硬前置)—— 凭 close_ctx 过月锁,
    -- 用毕即清(movement_ctx 同款)。YEAR_CLOSED 闸此刻无感:本年的 year_closes
    -- 行还没落库。
    PERFORM set_config('evoltrya.close_ctx', 'year_close', true);
    v_je := post_journal_entry(p_year_end,
        'Year-end close FY ending ' || p_year_end, 'year_close', v_close_id, v_lines);
    PERFORM set_config('evoltrya.close_ctx', '', true);

    INSERT INTO year_closes (id, year_end, closing_journal_id, net_result, notes, closed_by)
    VALUES (v_close_id, p_year_end, (v_je->>'entry_id')::uuid, v_net, p_notes, v_user);

    RETURN jsonb_build_object('year_end', p_year_end, 'net_result', v_net,
        'journal_code', v_je->>'code', 'rows', v_preview->'rows',
        'already_closed', false);
END;
$function$;

-- ── 7. 重开年 ────────────────────────────────────────────────────────────
-- 分录不可变,重开 = 冲销结转分录(镜像行,日期同为年末)+ 盖章留痕。
-- 【不动 locked_before】:关年没动过它(只断言),重开也不动 —— 要改 12 月的账,
-- 下一步是 reopen_period(月级,自己留痕);YEAR_CLOSED 闸已随盖章抬起。
CREATE OR REPLACE FUNCTION public.reopen_financial_year(p_year_end date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_row   record;
    v_lines jsonb := '[]'::jsonb;
    v_l     record;
    v_je    jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;
    PERFORM 1 FROM finance_settings WHERE id FOR UPDATE;

    SELECT * INTO v_row FROM year_closes
    WHERE year_end = p_year_end AND reopened_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM year_closes WHERE year_end = p_year_end) THEN
            RAISE EXCEPTION 'ALREADY_REOPENED';
        END IF;
        RAISE EXCEPTION 'CLOSE_NOT_FOUND';
    END IF;
    -- 只能从最晚的仍有效年结往回重开 —— 隔着后年重开前年,3100 的链条就断了
    IF EXISTS (SELECT 1 FROM year_closes
               WHERE reopened_at IS NULL AND year_end > p_year_end) THEN
        RAISE EXCEPTION 'LATER_YEAR_CLOSED|%', p_year_end;
    END IF;

    -- 冲销行 = 结转分录的镜像(借贷互换),日期同为年末 —— 恢复到关年之前的
    -- 状态,连"截至年末"口径的报表也一并复原
    FOR v_l IN
        SELECT a.code, jl.debit, jl.credit
        FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
        WHERE jl.entry_id = v_row.closing_journal_id
        ORDER BY a.code
    LOOP
        v_lines := v_lines || jsonb_build_object(
            'account_code', v_l.code,
            'side', CASE WHEN v_l.debit > 0 THEN 'credit' ELSE 'debit' END,
            'currency', 'SGD', 'amount_ccy', CASE WHEN v_l.debit > 0 THEN v_l.debit ELSE v_l.credit END,
            'fx_rate', 1, 'line_memo', 'year-end close reversal');
    END LOOP;

    -- 凭 close_ctx 过两道闸(本年 year_closes 行此刻仍有效 → YEAR_CLOSED 需豁免;
    -- 月锁同理),先过账、后一次性盖章 —— 守卫触发器只放行这一种 UPDATE。
    PERFORM set_config('evoltrya.close_ctx', 'year_close', true);
    v_je := post_journal_entry(p_year_end,
        'REVERSAL: year-end close FY ending ' || p_year_end || ' — ' || btrim(p_reason),
        'year_close', v_row.id, v_lines);
    PERFORM set_config('evoltrya.close_ctx', '', true);

    UPDATE year_closes
    SET reopened_at = now(), reopened_by = v_user, reopen_reason = btrim(p_reason),
        reversal_journal_id = (v_je->>'entry_id')::uuid
    WHERE id = v_row.id;

    RETURN jsonb_build_object('year_end', p_year_end,
        'reversal_journal_code', v_je->>'code', 'net_result_reversed', v_row.net_result);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.preview_close_financial_year(date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.close_financial_year(date, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.reopen_financial_year(date, text) FROM PUBLIC, anon;


COMMIT;
