-- SAL-B3:看板补 credit_over_limit 臂(module.customers.view —— sales 持它)
-- NOTE: apply with ./db/apply_migration.sh
BEGIN;

CREATE OR REPLACE VIEW public.operations_now WITH (security_invoker = off) AS
 SELECT item_type,
    permission,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.assay_count = 0
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_1.code AS item_code,
            (ct.name_en || ' — '::text) || s_1.legal_name AS subject,
            sc.valid_until AS item_date
           FROM supplier_compliance sc
             JOIN certificate_types ct ON ct.code = sc.cert_type_code
             JOIN suppliers s_1 ON s_1.id = sc.supplier_id
          WHERE sc.deleted_at IS NULL AND s_1.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND sc.valid_until IS NOT NULL AND sc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'qualification_missing'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_2.code AS item_code,
            s_2.legal_name AS subject,
            s_2.created_at::date AS item_date
           FROM suppliers s_2
          WHERE s_2.deleted_at IS NULL AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
                   FROM supplier_compliance sc2
                  WHERE sc2.supplier_id = s_2.id AND sc2.deleted_at IS NULL))
        UNION ALL
        -- SAL-B:达到或超过信用限额的客户。敞口走 customer_ar_exposure_base ——
        -- 与销售拦截同一份算术(属主视图里以属主身份执行,EXECUTE 收回不碍事)。
        -- 【NULL 限额的客户永远不上牌】:没设限不是超限。item_date 取最早未结销售日 ——
        -- 敞口挂了多久。冻结(credit_hold)不上牌:那是人做的决定,不是等人处理的事。
         SELECT 'credit_over_limit'::text AS item_type,
            'module.customers.view'::text AS permission,
            c_1.code AS item_code,
            c_1.legal_name AS subject,
            COALESCE(( SELECT min(sr.sale_date)
                   FROM sales_records sr
                  WHERE sr.customer_id = c_1.id), CURRENT_DATE) AS item_date
           FROM customers c_1
          WHERE c_1.deleted_at IS NULL
            AND c_1.credit_limit_base IS NOT NULL
            AND customer_ar_exposure_base(c_1.id) >= c_1.credit_limit_base
    UNION ALL
         SELECT 'output_unsold_aging'::text AS item_type,
            'module.output.view'::text AS permission,
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL) a
  WHERE has_permission(permission);

GRANT SELECT ON public.operations_now TO authenticated;

COMMIT;
