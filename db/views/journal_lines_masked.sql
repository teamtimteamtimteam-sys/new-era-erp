-- db/views/journal_lines_masked.sql
-- U1-A(Tim 的 UNBLOCK-1 Q1 · Q2 · Q3,2026-10-05):分录行的遮蔽伴生视图 —— 【工资分录的金额】要 data.view_pay。
--
-- 【遮什么】source_type = 'payroll' 的分录(过账、发薪、公积金、扣款,以及冲销件 —— 冲销照抄 source_type)的每一行:
--   debit · credit · amount_ccy 三个金额。行本身、科目、行摘要(员工编号 + 姓名,Q3)、币种、汇率照常给。
--   一个人的工资就是这几个数;一期只有一个人时,连这一期的合计也是他的工资(Q1)—— 所以遮的是【每一行】,不是"按人那几行"。
-- 【为什么另起一张视图】journal_lines 上那条 restrictive 策略("amounts: …")让不持 view_pay 的人经 API 读不到那几行;
--   页面要的是【那一行在、金额受限】,于是页面读这里(属主身份,绕过那条策略),行谓词与基表的 permissive 策略同一个码。
-- 【side 与 amounts_restricted 是派生列】金额受限时页面仍要知道这一行记在哪一边、以及"这是受限,不是零"
--   (AGENTS.md:0.00 与「受限」不是一回事)。两列都不在基表里,change_log_mask_gaps 不把它们算作遮蔽列。
-- 【判据只有一份】CASE 里那一句与 change_log_mask_rules 的 pay_journal 规则(change_log_rule_visible)逐字同一个判据:
--   持 data.view_pay,或这一行所在分录的 source_type 不是 'payroll'。

CREATE VIEW public.journal_lines_masked WITH (security_invoker = off) AS
 SELECT l.id,
    l.entry_id,
    l.account_id,
        CASE
            WHEN has_permission('data.view_pay'::text) OR e.source_type IS DISTINCT FROM 'payroll'::text THEN l.debit
            ELSE NULL::numeric
        END AS debit,
        CASE
            WHEN has_permission('data.view_pay'::text) OR e.source_type IS DISTINCT FROM 'payroll'::text THEN l.credit
            ELSE NULL::numeric
        END AS credit,
    l.currency,
        CASE
            WHEN has_permission('data.view_pay'::text) OR e.source_type IS DISTINCT FROM 'payroll'::text THEN l.amount_ccy
            ELSE NULL::numeric
        END AS amount_ccy,
    l.fx_rate,
    l.line_memo,
    l.created_at,
    l.fx_rate_date,
    l.tax_code,
        CASE
            WHEN l.debit > 0::numeric THEN 'debit'::text
            ELSE 'credit'::text
        END AS side,
    NOT (has_permission('data.view_pay'::text) OR e.source_type IS DISTINCT FROM 'payroll'::text) AS amounts_restricted
   FROM journal_lines l
     JOIN journal_entries e ON e.id = l.entry_id
  WHERE has_permission('module.finance.view'::text);

COMMENT ON VIEW public.journal_lines_masked IS
    'U1-A(UNBLOCK-1 Q1–Q3):分录行的遮蔽伴生视图。source_type = payroll 的分录每一行的 debit / credit / amount_ccy 只给持 data.view_pay 的人;行、科目、行摘要照常给。side 与 amounts_restricted 是派生列:受限时页面仍知道这一行记在哪一边,并把它说成「受限」而不是 0.00。行谓词 = journal_lines 的 permissive 读策略(module.finance.view)。';

GRANT SELECT ON public.journal_lines_masked TO authenticated;
