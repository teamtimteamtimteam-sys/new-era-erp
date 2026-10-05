-- db/views/bank_unmatched_journal_lines.sql
-- 匹配工作台的候选清单:银行科目('1000'/'1010')上、所属分录 posted、
-- 原币 = 账户本币(bank_native_currency)、且尚未被任何报表行认领的分录行。
-- 收付款 / 已付开支 / 手工分录都会产出这样的行 —— 这正是"报表行配分录行"
-- 这一设计通用的原因。~~SECURITY INVOKER。~~
-- ★ U1-A(Tim 的 UNBLOCK-1 Q1 · Q2,2026-10-05):改成【属主权限】,门写回视图体里(module.finance.view —— 与 journal_lines /
--   journal_entries 的 permissive 读策略同一个码)。理由:journal_lines 上那条 restrictive 策略让不持 data.view_pay 的财务读者
--   读不到工资分录的行;invoker 时,发薪那几条银行贷方会【悄悄】从候选清单里消失 —— 而它们正是对账单上那几笔工资转账要配的行。
--   现在行照常在,金额(amount_ccy)按同一个判据受限(持 data.view_pay,或分录不是工资分录),amounts_restricted 说"受限,不是 0"。
--   能配(match_bank_line)要 module.finance.edit,而今天持它的角色都持 data.view_pay;这里只是让看的人看见同一张清单。
-- NOTE: introduced by db/migrations/2026-07-30-phase3-s3a-bank-reconciliation.sql.

CREATE OR REPLACE VIEW public.bank_unmatched_journal_lines
WITH (security_invoker = off) AS
 SELECT l.id AS journal_line_id,
    e.id AS entry_id,
    e.code AS entry_code,
    e.entry_date,
    e.memo,
    e.source_type,
    e.source_id,
    a.code AS account_code,
    l.currency,
        CASE
            WHEN has_permission('data.view_pay'::text) OR e.source_type IS DISTINCT FROM 'payroll'::text THEN l.amount_ccy
            ELSE NULL::numeric
        END AS amount_ccy,
        CASE
            WHEN l.debit > 0::numeric THEN 'debit'::text
            ELSE 'credit'::text
        END AS direction,
    NOT (has_permission('data.view_pay'::text) OR e.source_type IS DISTINCT FROM 'payroll'::text) AS amounts_restricted
   FROM journal_lines l
     JOIN accounts a ON a.id = l.account_id
     JOIN journal_entries e ON e.id = l.entry_id
  WHERE (a.code = ANY (ARRAY['1000'::text, '1010'::text])) AND e.status = 'posted'::text AND l.currency = bank_native_currency(a.code) AND NOT (EXISTS ( SELECT 1
           FROM bank_line_matches m
          WHERE m.journal_line_id = l.id)) AND has_permission('module.finance.view'::text);
