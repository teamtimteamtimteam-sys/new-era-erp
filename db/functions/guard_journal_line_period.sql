CREATE OR REPLACE FUNCTION public.guard_journal_line_period()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_date date;
    v_src  text;
BEGIN
    -- 明细自己没有日期 —— 它的期间是【父分录的】。
    SELECT entry_date, source_type INTO v_date, v_src
      FROM journal_entries WHERE id = NEW.entry_id;
    IF NOT FOUND THEN
        -- 外键本来就会拦;这里【不静默放行】—— 查不到父分录时不能当成"期间没问题"。
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_id';
    END IF;
    PERFORM assert_posting_allowed(v_date, v_src);
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_journal_line_period() IS
    'GO-2:明细的期间取自【父分录】。它关上的是"绕过 post_journal_entry 直接写明细"这条路;"往已过账凭证追加明细"在【开着的】期间仍然成立,那是不变性的问题,见 docs/known-issues.md 的 JE-APPEND 条。';