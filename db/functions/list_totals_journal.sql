-- db/functions/list_totals_journal.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1–Q3 · Q6):/finance/journal 的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】与 app/finance/journal/journalRows.ts 的 applyFilters 同一套:entry_date ≥ from、≤ to(journal_entries 无软删、无状态筛选)。
-- 【量】amount = 每张分录 Σ借方(与 shapeJournalRows 同一个数),读 journal_lines_masked —— 【绝不读基表 journal_lines】:
--   那上面的 restrictive 策略让不持 data.view_pay 的人读不到工资分录的行,合计会悄悄变小、永远说不出「受限」
--   (journal_lines.sql:106-111)。本位币,currency 给本位币代码。
-- 【净额】(Q2)冲销是一张同为正数的冲销分录(reverse_journal_entry_internal.sql:56-70),原分录翻成 reversed 并以
--   reversed_by 指着它;冲销分录在这里记【负数】,一对冲销加起来是 0。
-- 【受限】逐行遮(journal_lines_masked.sql:19,工资分录 × 不持 data.view_pay):集合里任何一行 amounts_restricted →
--   整个合计 restricted、total 为 NULL(Q6:不把看得见的那一部分单独印出来)。
-- 【门】require_permission('module.finance.view') —— 与页面守卫 requireModule(MOD.finance)、与视图的行谓词同一个码。invoker。
CREATE OR REPLACE FUNCTION public.list_totals_journal(p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date)
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text,
           (SELECT c.code FROM currencies c WHERE c.is_base)::text,
           'amount'::text,
           CASE WHEN bool_or(l.amounts_restricted) THEN NULL
                ELSE round(sum(CASE WHEN EXISTS (SELECT 1 FROM journal_entries o WHERE o.reversed_by = e.id)
                                    THEN -l.debit ELSE l.debit END), 2) END,
           bool_or(l.amounts_restricted)
      FROM journal_entries e
      JOIN journal_lines_masked l ON l.entry_id = e.id
     WHERE (p_date_from IS NULL OR e.entry_date >= p_date_from)
       AND (p_date_to IS NULL OR e.entry_date <= p_date_to)
    HAVING count(*) > 0;
END;
$function$;