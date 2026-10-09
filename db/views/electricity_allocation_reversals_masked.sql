-- db/views/electricity_allocation_reversals_masked.sql
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q32,Tim):遮蔽伴生视图 —— electricity_allocation_reversals 的每一列都在,金额按 has_permission() 置空。
--   遮蔽的列:bill_amount · actual_line_amount · restored_estimate_amount → data.view_prices(分摊那五列同一条规矩,change_log_mask_rules 里同样三行)。
--   件数、理由、日期不遮。
-- 【属主权限】与 electricity_allocations_masked 同形同理由:把表的读策略(财务或加工查看码)原样写回视图体。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b2-reversals.sql.

CREATE VIEW public.electricity_allocation_reversals_masked WITH (security_invoker = off) AS
 SELECT id,
    allocation_id,
    reversal_date,
    reason,
    reversal_expense_id,
    reversal_journal_entry_id,
    payment_status,
    bank_account_code,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN bill_amount
            ELSE NULL::numeric
        END AS bill_amount,
    actual_line_count,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN actual_line_amount
            ELSE NULL::numeric
        END AS actual_line_amount,
    restored_estimate_count,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN restored_estimate_amount
            ELSE NULL::numeric
        END AS restored_estimate_amount,
    created_at,
    created_by
   FROM electricity_allocation_reversals
  WHERE has_any_permission(ARRAY['module.finance.view'::text, 'module.processing.view'::text]);

GRANT SELECT ON public.electricity_allocation_reversals_masked TO authenticated;
REVOKE ALL ON public.electricity_allocation_reversals_masked FROM anon;
