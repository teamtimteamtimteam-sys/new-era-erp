-- ASY-1b:过账许可闸改回【调用者权限】—— 它本来就长在 post_journal_entry 里
--
-- gate 的 definer 判词与 B2 顶出来:assert_posting_allowed 是 SECURITY DEFINER
-- 却没有调用者检查。两条出路都验过:
--   * 收回 EXECUTE + 白名单 —— 【不行】。post_journal_entry 自己是 SECURITY
--     INVOKER,它对被收回函数的调用以【当前用户】身份查权限(SAL-B4 撞过的同一件
--     事),那样每一次过账都会 permission denied。
--   * 改成 SECURITY INVOKER —— 对了,而且更朴素:这段代码搬出来之前就在
--     post_journal_entry 的函数体里以调用者身份跑,读的 finance_settings /
--     year_closes 也正是那个调用者本来就读得到的两张表。语义一字未变。
--     另一个调用方 preview_reprice_inbound_batch 是 DEFINER,函数体内的调用以
--     属主身份跑,同样不受影响。
-- NOTE: apply with ./db/apply_migration.sh
BEGIN;

DROP FUNCTION IF EXISTS public.assert_posting_allowed(date, text);

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

COMMENT ON FUNCTION public.assert_posting_allowed(date, text) IS
    '过账许可闸(ASY-1):年结闸 + 期间锁,自 post_journal_entry 原样搬出,【调用者权限】—— 搬家前它就以调用者身份在那个函数体里跑,读的也是调用者本来就读得到的两张表。一份实现两个调用方:真过账与只读试算共用,免得预览放行一笔提交会拒的分录(reprice_split 的先例)。命中即点名抛 YEAR_CLOSED / PERIOD_LOCKED。';

COMMIT;
