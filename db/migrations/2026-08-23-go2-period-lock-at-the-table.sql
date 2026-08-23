-- GO-2:把期间锁【钉在表上】,不只钉在正门上
--
-- 【实测到的洞】GO-2 之前,期间锁与年结闸只由 assert_posting_allowed 执行,
-- 而它只被 post_journal_entry 调用。post_journal_entry 【确实】是唯一一个
-- INSERT journal_entries / journal_lines 的函数(查线上目录得出,32 个写日记账
-- 的函数里另外 31 个都调它),所以【正门】是严实的:两道闸都实测拒绝。
--
-- 但 authenticated 对这两张表持有【表级 INSERT 授权】,RLS 的 INSERT 策略只问
-- has_permission('module.finance.edit')。于是绕开函数直接 INSERT 是通的 ——
-- GO-2 在回滚事务里实测了四格:
--     正门 · 月锁   → 拒绝 PERIOD_LOCKED
--     正门 · 年结   → 拒绝 YEAR_CLOSED
--     后门 · 月锁   → **过账成功**(entry_date 落在 locked_before 之前)
--     后门 · 年结   → **过账成功**(日期落在仍有效的已结年度之内)
--
-- 【为什么是触发器,而不是收回 INSERT 授权】post_journal_entry 【不是】
-- SECURITY DEFINER —— 它以调用者身份运行,而 /finance/journal/new 直接 rpc 调它。
-- 收回 authenticated 的 INSERT 会把手工凭证录入一起打死。触发器则不管是谁写、
-- 走哪条路,都在表这一层问同一个问题。
--
-- 【为什么触发器函数是 SECURITY DEFINER —— 这一条是实测出来的,不是习惯】
-- assert_posting_allowed 读 finance_settings 与 year_closes,而这两张表的 SELECT
-- 策略都是 has_permission('module.finance.view')。一个【只有 edit 没有 view】的
-- 调用者读到 0 行,于是 v_locked 与 v_year_closed 都是 NULL,闸【空转】——
-- 这正是本仓库反复遇到的那个形状(空集不是"没有")。以属主身份跑,读取就不再
-- 取决于写入者的读权限。**闸的实现仍然只有一份** —— 触发器不重写判据,
-- 它调用同一个 assert_posting_allowed,连 year_close 的例外都原样继承。
-- 线上目前没有任何【有 edit 没 view】的活跃角色,所以那是潜在的、不是正在发生的;
-- 但闸的正确性不该继续依赖"没有人这样配角色"。
-- 先例:同在 journal_lines 上的 check_journal_balance 就是 SECURITY DEFINER。
-- B2 与 definer_without_caller_check 都豁免 RETURNS trigger(闸门是基表写入)。
--
-- 【它【不】改变锁的含义】没有新规矩、没有新例外。year_close + close_ctx 那条
-- 唯一的例外住在 assert_posting_allowed 里,两个触发器都因为调用它而自动继承。
--
-- 【它没有关上的那一半 —— 见 docs/known-issues.md 的 JE-APPEND 条】
-- 「往一张【已过账】的凭证追加明细」在【锁定期】里从此被拒(本迁移),
-- 但在【开着的期间】里仍然成立。那件事要的规矩是"明细只能在创建该分录的
-- 同一笔事务里插入",而期间锁从来不是它被违反的那条规矩 —— 不变性才是。
-- 那条规矩需要一个上下文标记(now() 排不出事务内的先后),不在本刀里做。
BEGIN;

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

DROP TRIGGER IF EXISTS trg_journal_entries_period ON public.journal_entries;
CREATE TRIGGER trg_journal_entries_period
    BEFORE INSERT ON public.journal_entries
    FOR EACH ROW EXECUTE FUNCTION public.guard_journal_entry_period();

DROP TRIGGER IF EXISTS trg_journal_lines_period ON public.journal_lines;
CREATE TRIGGER trg_journal_lines_period
    BEFORE INSERT ON public.journal_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_journal_line_period();

COMMENT ON FUNCTION public.guard_journal_entry_period() IS
'GO-2:期间锁与年结闸钉在表上。调用 assert_posting_allowed —— 与 post_journal_entry 同一份实现、同一条 year_close 例外。SECURITY DEFINER 是因为闸要读的 finance_settings / year_closes 对只有 module.finance.edit 的调用者不可见,以调用者身份读会读到 0 行而【空转】。';

COMMENT ON FUNCTION public.guard_journal_line_period() IS
'GO-2:明细的期间取自【父分录】。它关上的是"绕过 post_journal_entry 直接写明细"这条路;"往已过账凭证追加明细"在【开着的】期间仍然成立,那是不变性的问题,见 docs/known-issues.md 的 JE-APPEND 条。';

COMMIT;
