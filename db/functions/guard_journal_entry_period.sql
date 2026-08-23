CREATE OR REPLACE FUNCTION public.guard_journal_entry_period()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 与正门同一个判据、同一份实现、同一条例外。
    PERFORM assert_posting_allowed(NEW.entry_date, NEW.source_type);
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_journal_entry_period() IS
    'GO-2:期间锁与年结闸钉在表上。调用 assert_posting_allowed —— 与 post_journal_entry 同一份实现、同一条 year_close 例外。SECURITY DEFINER 是因为闸要读的 finance_settings / year_closes 对只有 module.finance.edit 的调用者不可见,以调用者身份读会读到 0 行而【空转】。';