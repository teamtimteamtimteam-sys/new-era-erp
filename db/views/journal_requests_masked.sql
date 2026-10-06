-- db/views/journal_requests_masked.sql
-- U1-B(2026-10-05,U1A-PAYROLL-REVERSAL-REQUEST-SHOWS-AMOUNT):手工凭证申请的遮蔽伴生视图。
-- 【遮什么】amount_base —— 一张工资分录(发薪 · 公积金 · 扣款)的冲销申请,金额就是那张分录的合计;要 data.view_pay。
--   判据住在 journal_request_amount_visible(与 journal_lines_masked 同一个谓词:持码,或冲销的不是工资分录)。
--   amount_restricted 说出"这一个 NULL 是受限,不是零"—— 页面照它印「受限」,不印 0.00。
-- 【行谓词】= 基表的读策略(module.finance.view)—— 属主视图绕过 RLS,所以这里必须再问一次。
-- 【列】基表的每一列都在这里(colgrant)。判据与 change_log_mask_rules 的 jr_amount 同一支函数。

CREATE VIEW public.journal_requests_masked WITH (security_invoker = off) AS
 SELECT id,
    kind,
    status,
    label,
    entry_date,
    memo,
    lines,
    target_entry_id,
        CASE
            WHEN journal_request_amount_visible(id) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    credits_bank,
    decided_at,
    decided_by,
    decision_notes,
    result_journal_entry_id,
    withdrawn_at,
    withdrawn_by,
    withdraw_reason,
    created_at,
    created_by,
    NOT journal_request_amount_visible(id) AS amount_restricted
   FROM journal_requests
  WHERE has_permission('module.finance.view'::text);

COMMENT ON VIEW public.journal_requests_masked IS
    'U1-B:手工凭证申请的遮蔽伴生视图。amount_base 要 journal_request_amount_visible(持 data.view_pay,或冲销的不是工资分录);amount_restricted 为真时页面印「受限」。行谓词 = 基表的读策略(module.finance.view)。';

GRANT SELECT ON public.journal_requests_masked TO authenticated;
