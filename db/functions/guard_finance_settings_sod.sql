-- db/functions/guard_finance_settings_sod.sql
-- SOD-1:后门① —— finance_settings.locked_before 的直连 UPDATE。
-- /finance/settings 的"手动锁"走的正是这条,它【不经过】close_period;
-- 而 authenticated 对本表持表级 UPDATE 授权(GO-2 量到的同一个洞)。
-- SECURITY DEFINER 的理由与 GO-2 逐字相同:闸要读 journal_entries,
-- 一个【有 edit 没 view】的写入者读到 0 行,闸就空转 —— 空集不是"没有"。
-- 只管【前进】的锁:解锁与 reopen 把锁往回搬,那不隐藏任何东西。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql.

CREATE OR REPLACE FUNCTION public.guard_finance_settings_sod()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 只管【前进】的锁。解锁与 reopen_period 把锁往回搬,那不隐藏任何东西。
    IF NEW.locked_before IS NULL THEN
        RETURN NEW;
    END IF;
    IF OLD.locked_before IS NOT NULL AND NEW.locked_before <= OLD.locked_before THEN
        RETURN NEW;
    END IF;

    -- 与正门同一个问法、同一份规矩。
    PERFORM assert_segregated(
        'SOD_POST_AND_CLOSE',
        sod_manual_posters_in(OLD.locked_before, NEW.locked_before - 1),
        to_char(NEW.locked_before - 1, 'YYYY-MM-DD'));
    RETURN NEW;
END;
$function$;