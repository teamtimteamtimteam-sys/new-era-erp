-- db/functions/reversal_date_for.sql
-- AP-RECON-1 Batch B(2026-09-24,Tim Batch B Q5):一张【由系统代填冲销日】的冲销,冲销日取
-- 今天与原分录日期里较晚的那一个。
--
-- 【为什么需要它】reverse_journal_entry_internal 从本刀起拒绝早于原分录的冲销
-- (REVERSAL_BEFORE_ORIGINAL;FRT-2027-* 的冲销记在原件之前一年,截在两者之间的 as-at
-- 报表只看得见冲销那一条腿)。而七个调用点(费用 / 付款 / 运费冲销、薪资撤回、加工分摊重做
-- 与回滚 ×2)从来不问人要日期,直接盖 CURRENT_DATE。薪资按【发薪日】过账、加工按作业日
-- 过账,两者都可以晚于今天(不晚于本月末,见 assert_posting_allowed):今天撤回一张月末
-- 发薪的薪资是正当的更正,拦下它没有道理 —— 于是冲销落在原分录那一天,而不是被拒。
-- 【由人给日期的调用点不走这里】(日记账页、作废发票、冲销代扣汇款、冲销银行转账):
-- 人给了一个早于原分录的日子,就按名拒 —— 那是一个可以改的输入,不是一个要替人改的数。
--
-- 它只是一个表达式,抽出来是为了七处写的是同一句话,而不是七份各自记得 GREATEST 的副本。
--
-- NOTE: introduced by db/migrations/2026-09-24-aprecon1b-the-list-and-the-ledger-agree.sql.
CREATE OR REPLACE FUNCTION public.reversal_date_for(p_entry_id uuid)
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT GREATEST(CURRENT_DATE, (SELECT je.entry_date FROM journal_entries je WHERE je.id = p_entry_id))
$function$;
