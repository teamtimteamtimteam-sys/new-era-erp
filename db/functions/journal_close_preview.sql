-- db/functions/journal_close_preview.sql
-- U1-A(Tim 的 UNBLOCK-1 Q2,2026-10-05):/finance/close 那一格"截至所选月末:几张分录 · Σ借 · Σ贷"—— 从此问这里。
-- 【为什么必须搬】原来那一句是 PostgREST 拉 journal_lines(内连 journal_entries)再在页面上加;journal_lines 上那条 restrictive 策略
--   让不持 data.view_pay 的财务读者读不到工资分录的行,于是他看到的分录数与两个合计都【悄悄变小】,而"已平"的对勾照样画出来 ——
--   那一格是关账的确认依据(页面上的注释写着:验不了就不能画勾)。属主身份绕过那条策略,每一个读者拿到同一组数。
-- 【口径与原来逐字相同】entry_date <= p_period_end 的全部行,不按 status 过滤。
-- 【门】module.finance.view,按名拒;截止日不给默认值(PERIOD_REQUIRED)。
CREATE OR REPLACE FUNCTION public.journal_close_preview(p_period_end date)
 RETURNS TABLE(entry_count bigint, debits numeric, credits numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'PERIOD_REQUIRED';
    END IF;
    RETURN QUERY
    SELECT count(DISTINCT l.entry_id), COALESCE(sum(l.debit), 0), COALESCE(sum(l.credit), 0)
      FROM journal_lines l
      JOIN journal_entries e ON e.id = l.entry_id
     WHERE e.entry_date <= p_period_end;
END;
$function$
