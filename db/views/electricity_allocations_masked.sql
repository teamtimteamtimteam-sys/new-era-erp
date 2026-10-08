-- db/views/electricity_allocations_masked.sql
-- MES-5a-2(2026-10-08,MES-5a Step 0 Q30,Tim):遮蔽伴生视图 —— electricity_allocations 的每一列都在,金额按 has_permission() 置空。
--   遮蔽的列:bill_amount · price_per_kwh · allocated_amount · overhead_amount · relieved_estimate_amount → data.view_prices
--   (加工成本那条规矩,change_log_mask_rules 里同样五行)。kWh 不遮。
-- 【属主权限】与 processing_cost_entries_masked 同形同理由:把表的读策略(财务或加工查看码)原样写回视图体,视图不放宽任何行访问。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

CREATE VIEW public.electricity_allocations_masked WITH (security_invoker = off) AS
 SELECT id,
    period_from,
    period_to,
    bill_date,
    invoice_ref,
    supplier_id,
    payee_name,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN bill_amount
            ELSE NULL::numeric
        END AS bill_amount,
    bill_kwh,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN price_per_kwh
            ELSE NULL::numeric
        END AS price_per_kwh,
    metered_kwh,
    allocated_kwh,
    shared_pool_kwh,
    unallocated_metered_kwh,
    unmetered_kwh,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN allocated_amount
            ELSE NULL::numeric
        END AS allocated_amount,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN overhead_amount
            ELSE NULL::numeric
        END AS overhead_amount,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN relieved_estimate_amount
            ELSE NULL::numeric
        END AS relieved_estimate_amount,
    relieved_estimate_count,
    payment_status,
    bank_account_code,
    expense_id,
    journal_entry_id,
    notes,
    created_at,
    created_by
   FROM electricity_allocations
  WHERE has_any_permission(ARRAY['module.finance.view'::text, 'module.processing.view'::text]);

GRANT SELECT ON public.electricity_allocations_masked TO authenticated;
REVOKE ALL ON public.electricity_allocations_masked FROM anon;
