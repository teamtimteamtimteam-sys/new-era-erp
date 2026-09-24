CREATE OR REPLACE FUNCTION public.assert_posting_allowed(p_entry_date date, p_source_type text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_locked      date;
    v_year_closed date;
BEGIN
    -- ════════════════════════════════════════════════════════════════════════
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):【分录日期不得晚于本月最后一天】
    --   此前这里只有下界(年结、月锁),没有上界 —— LOG-4b 的测试单就是这样把
    --   JE-2027-0001…0003 记进了真账(一年后的日子,还占掉了 2027 年的无缝编号)。
    --   【为什么是月末而不是今天】折旧、重估、薪资按【期末日】过账,月结可以在 28 号做;
    --   以今天为界会把正当的月结拦在门外。业务单据(运费、费用、发票、收付款)在各自的
    --   函数里另有一道更紧的闸:日期晚于今天按名拒 —— 那是"一件已经发生的事"的判据,
    --   这里是"账不许记进下个月"的判据,两者不是同一个问题。
    --   【没有测试开关】fixture 把日期挪到真实的过去,而不是在这道闸上开一个口子(Tim Q7)。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_entry_date > (date_trunc('month', CURRENT_DATE) + interval '1 month - 1 day')::date THEN
        RAISE EXCEPTION 'POSTING_DATE_BEYOND_CURRENT_MONTH|%|%', p_entry_date,
            (date_trunc('month', CURRENT_DATE) + interval '1 month - 1 day')::date;
    END IF;

    -- 【FIN-23:已结年度守卫 —— 与月锁无关的第二道闸,排在月锁之前】
    -- locked_before 是一条会动的线:reopen_period(月级、合法、留痕)会把它退回
    -- 已结年度之内 —— 回填分录进去,损益科目再动,留存收益就悄悄错了。这道闸
    -- 不跟着锁退:日期落进【仍有效】年结(year_closes.reopened_at IS NULL)的
    -- 一律点名拒绝。两道都命中时报 YEAR_CLOSED —— 年是更强的事实。
    -- 年结自己的分录凭 evoltrya.close_ctx 过(close_financial_year /
    -- reopen_financial_year 在同一事务内设置,用毕即清 —— movement_ctx 同款);
    -- 结转分录在 year_closes 行落库之前过账,本闸对它本就无感,ctx 是给
    -- 重开的冲销分录用的(先过账、后一次性盖章)。
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
END;
$function$;