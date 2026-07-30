-- db/views/bank_unmatched_journal_lines.sql
-- 匹配工作台的候选清单:银行科目('1000'/'1010')上、所属分录 posted、
-- 原币 = 账户本币(bank_native_currency)、且尚未被任何报表行认领的分录行。
-- 收付款 / 已付开支 / 手工分录都会产出这样的行 —— 这正是"报表行配分录行"
-- 这一设计通用的原因。SECURITY INVOKER。
-- NOTE: introduced by db/migrations/2026-07-30-phase3-s3a-bank-reconciliation.sql.

CREATE OR REPLACE VIEW public.bank_unmatched_journal_lines
WITH (security_invoker = on) AS
 SELECT l.id AS journal_line_id,
    e.id AS entry_id,
    e.code AS entry_code,
    e.entry_date,
    e.memo,
    e.source_type,
    e.source_id,
    a.code AS account_code,
    l.currency,
    l.amount_ccy,
        CASE
            WHEN l.debit > 0::numeric THEN 'debit'::text
            ELSE 'credit'::text
        END AS direction
   FROM journal_lines l
     JOIN accounts a ON a.id = l.account_id
     JOIN journal_entries e ON e.id = l.entry_id
  WHERE (a.code = ANY (ARRAY['1000'::text, '1010'::text])) AND e.status = 'posted'::text AND l.currency = bank_native_currency(a.code) AND NOT (EXISTS ( SELECT 1
           FROM bank_line_matches m
          WHERE m.journal_line_id = l.id));
