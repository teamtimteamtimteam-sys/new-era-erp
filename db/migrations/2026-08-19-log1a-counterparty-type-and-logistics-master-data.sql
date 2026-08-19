-- LOG-1a:物流主数据(库这一半)—— 交易对手类型,以及由它【派生】的 supplies_goods
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么是派生,而不是第二个分类列】
-- suppliers 上已经有两个候选分类:
--   * supplier_types text[](无 CHECK、多选,答"他们做哪一行",至今没有代码据它判断)
--   * supplies_goods boolean(SUP-TYPE-1a,答"我们会不会收到他们的实物货")
-- 后者是【承重】的:operations_now 的 qualification_missing 支、
-- supplier_receipt_pattern、以及收货触发器 guard_inbound_supplier_supplies_goods
-- 三处都读它。再加一个平行的类型列,就是同一个事实的第三次陈述 ——
-- 而本仓库为"一个事实两处陈述必然漂移"付过很多次学费。
--
-- 所以:**类型是唯一的真源,supplies_goods 变成它的 GENERATED STORED 派生列。**
-- 三处判据一个字都不用改 —— 它们读的还是同一个列名、同一个语义。
--
-- 【代价,写清楚:派生列不可写】。原来写 supplies_goods 的地方必须改写类型。
-- 全仓清点过,写入方共 3 处(读取方不受影响):
--   1. app/suppliers/new/actions.ts          —— 新建供应商
--   2. app/suppliers/[id]/edit/actions.ts    —— 编辑供应商
--   3. db/fixtures/89-*.sql                  —— 两处 INSERT + 两处 UPDATE
-- 三处都改得动,所以没有触发 STOP。**但 1 与 2 是页面**,
-- 因此本刀【确实动了页面】,与 brief 里"这一半不碰页面"那句相左 —— 报告里点名。
-- 不改它们的话,派生化生效的那一刻建/改供应商会当场失败(不能写生成列)。
--
-- 【视图必须先拆后建】。PostgreSQL 不能把普通列原地改成生成列,只能 DROP 再 ADD;
-- 而 operations_now 与 supplier_receipt_pattern 都引用了这一列,会挡住 DROP。
-- 下面这两段视图定义是【从线上 pg_get_viewdef 原样取出来的】,不是手抄的 ——
-- 手抄一段 13KB 的视图是自找的漂移。supplier_receipt_pattern 的
-- WITH (security_invoker = off) 必须显式补回:pg_get_viewdef 不吐 reloptions
-- (AGENTS.md 里 PAYEE-1a 记过这一条)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- (a) 交易对手类型 —— 唯一的真源
-- ───────────────────────────────────────────────────────────────────────────
ALTER TABLE public.suppliers ADD COLUMN counterparty_type text;

-- 回填:现有行按它们今天的 supplies_goods 落位。线上 2 家都是供货商,
-- 0 家非供货 —— 所以这一步实际只走 goods_supplier 那一支,但两支都写出来,
-- 因为重建一个更老的快照时 false 是可能存在的。
UPDATE public.suppliers
   SET counterparty_type = CASE WHEN supplies_goods THEN 'goods_supplier' ELSE 'service_vendor' END;

ALTER TABLE public.suppliers
    ADD CONSTRAINT suppliers_counterparty_type_check
    CHECK (counterparty_type IN ('goods_supplier', 'forwarder', 'service_vendor'));

-- 【NOT NULL 且【没有默认值】】—— 写入方必须自己选。给一个默认值等于让
-- "没想过"和"想过并选了供货商"在库里长成同一个样子,而这一列的全部意义
-- 就是把货代与供货商分开。
ALTER TABLE public.suppliers ALTER COLUMN counterparty_type SET NOT NULL;

COMMENT ON COLUMN public.suppliers.counterparty_type IS
'LOG-1a:这一家【是什么】—— 单值,唯一的真源。
goods_supplier = 我们向他们买货并收货;forwarder = 货代/承运人,我们付他们运费、永远不会收到他们的"货";
service_vendor = 房东、水电、保险、专业服务、承包商这一类:付钱,但不会有一车货到场。
【货代保留 supplier id 是有意的】:一家公司一个 id,应付账龄、付款分摊、预付冲抵、外币重估整条链因此一个字都不用改
(ap_open_items 早就有一支 doc_kind=''freight'')。类型只决定他【出现在哪些名单里】,不决定他在账上是谁。
【NOT NULL 且无默认】:写入方必须选。默认值会让"没想过"与"确实是供货商"无法区分。
supplies_goods 是本列的【派生列】,不要反过来写它。';

-- ───────────────────────────────────────────────────────────────────────────
-- supplies_goods 变成派生列 —— 先拆掉挡路的两张视图
-- ───────────────────────────────────────────────────────────────────────────
DROP VIEW public.operations_now;
DROP VIEW public.supplier_receipt_pattern;

ALTER TABLE public.suppliers DROP COLUMN supplies_goods;

ALTER TABLE public.suppliers
    ADD COLUMN supplies_goods boolean
    GENERATED ALWAYS AS (counterparty_type = 'goods_supplier') STORED;

COMMENT ON COLUMN public.suppliers.supplies_goods IS
'SUP-TYPE-1a 建立,LOG-1a 起【改为派生】:GENERATED ALWAYS AS (counterparty_type = ''goods_supplier'') STORED。
语义一个字没变 —— 仍然是【我们会不会收到这一家的实物货】,仍然把关三处:operations_now 的 qualification_missing 支、supplier_receipt_pattern、以及收货触发器 guard_inbound_supplier_supplies_goods(RECEIPT_AGAINST_NON_GOODS_VENDOR)。
变的是【谁说了算】:真源是 counterparty_type,这一列跟着它走。
【它不可写】。想改一家的供货能力,改 counterparty_type;直接写这一列会被 PostgreSQL 拒绝,那是刻意的 —— 两处都能写就是两个真源。
货代(forwarder)与服务商(service_vendor)在这里都是 false,但它们【不是同一类】:前者不进供应商名单,后者要留在费用类的选择器里。要区分它们请读 counterparty_type,不要读这一列。';

-- 重建 operations_now(定义取自线上 pg_get_viewdef,未经手抄)
CREATE VIEW public.operations_now AS
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            g.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            g.batch_code AS item_code,
            array_to_string(g.missing_metals, ', '::text) AS subject,
            g.arrival_date AS item_date
           FROM batch_required_assay_gaps g
          WHERE g.sampleable
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.run_id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.id AS item_id,
            NULL::text AS doc_kind,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.id AS item_id,
            NULL::text AS doc_kind,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_1.id AS item_id,
            NULL::text AS doc_kind,
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
            s_2.id AS item_id,
            NULL::text AS doc_kind,
            s_2.code AS item_code,
            s_2.legal_name AS subject,
            s_2.created_at::date AS item_date
           FROM suppliers s_2
          WHERE s_2.deleted_at IS NULL AND s_2.supplies_goods AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
                   FROM supplier_compliance sc2
                  WHERE sc2.supplier_id = s_2.id AND sc2.deleted_at IS NULL))
        UNION ALL
         SELECT 'credit_over_limit'::text AS item_type,
            'module.customers.view'::text AS permission,
            c_1.id AS item_id,
            NULL::text AS doc_kind,
            c_1.code AS item_code,
            c_1.legal_name AS subject,
            COALESCE(( SELECT min(sr.sale_date) AS min
                   FROM sales_records sr
                  WHERE sr.customer_id = c_1.id), CURRENT_DATE) AS item_date
           FROM customers c_1
          WHERE c_1.deleted_at IS NULL AND c_1.credit_limit_base IS NOT NULL AND customer_ar_exposure_visible(c_1.id) >= c_1.credit_limit_base
        UNION ALL
         SELECT 'output_unsold_aging'::text AS item_type,
            'module.output.view'::text AS permission,
            ob.id AS item_id,
            NULL::text AS doc_kind,
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'safety_stock_below'::text AS item_type,
            'module.inventory.view'::text AS permission,
            msa.material_id AS item_id,
            NULL::text AS doc_kind,
            msa.code AS item_code,
            (((((trim_scale(msa.available_qty)::text || ' / '::text) || trim_scale(msa.safety_stock_qty)::text) || ' '::text) || COALESCE(msa.unit, ''::text)) || ' — short '::text) || trim_scale(msa.safety_stock_qty - msa.available_qty)::text AS subject,
            COALESCE(msa.last_movement_date, CURRENT_DATE) AS item_date
           FROM material_stock_available msa
          WHERE msa.safety_stock_qty IS NOT NULL AND msa.available_qty < msa.safety_stock_qty
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.id AS item_id,
            NULL::text AS doc_kind,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.id AS item_id,
            NULL::text AS doc_kind,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            r.id AS item_id,
            NULL::text AS doc_kind,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.invoice_id AS item_id,
            NULL::text AS doc_kind,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            COALESCE(ar.sales_record_id, ar.invoice_id) AS item_id,
            ar.doc_kind,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_id AS item_id,
            ap.doc_kind,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'margin_cost_not_allocated'::text AS item_type,
            'data.view_prices'::text AS permission,
            bm.run_id AS item_id,
            NULL::text AS doc_kind,
            bm.batch_code AS item_code,
            bm.material_name AS subject,
            ob.output_date AS item_date
           FROM batch_margin bm
             JOIN output_batches ob ON ob.id = bm.output_batch_id
          WHERE bm.margin_status = 'no_unit_cost'::text
        UNION ALL
         SELECT 'metal_quote_stale'::text AS item_type,
            'module.pricing.view'::text AS permission,
            mp.latest_id AS item_id,
            NULL::text AS doc_kind,
            mp.metal AS item_code,
            mp.latest_price::text AS subject,
            mp.max_date AS item_date
           FROM ( SELECT p.metal,
                    max(p.price_date) AS max_date,
                    (array_agg(p.id ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_id,
                    (array_agg(p.price_usd_per_tonne ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_price
                   FROM metal_prices p
                  WHERE p.deleted_at IS NULL
                  GROUP BY p.metal) mp
          WHERE (CURRENT_DATE - mp.max_date) > (( SELECT ps.metal_quote_stale_days
                   FROM pricing_settings ps
                 LIMIT 1))
        UNION ALL
         SELECT 'orders_unfulfilled'::text AS item_type,
            'module.sales.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            so.status AS subject,
            so.order_date AS item_date
           FROM sales_orders so
          WHERE so.deleted_at IS NULL AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
        UNION ALL
         SELECT 'work_order_overdue'::text AS item_type,
            'module.processing.view'::text AS permission,
            w.id AS item_id,
            NULL::text AS doc_kind,
            w.code AS item_code,
            w.scheduled_date::text AS subject,
            w.scheduled_date AS item_date
           FROM work_orders w
          WHERE w.status = 'released'::text AND w.scheduled_date IS NOT NULL AND w.scheduled_date < CURRENT_DATE
        UNION ALL
         SELECT 'work_order_variance_beyond'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.work_order_id AS item_id,
            NULL::text AS doc_kind,
            f.work_order_code AS item_code,
                CASE
                    WHEN f.side = 'input'::text THEN (((('input overrun · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                    ELSE (((('output shortfall · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                END AS subject,
            COALESCE(w2.scheduled_date, w2.created_at::date) AS item_date
           FROM work_order_fulfilment f
             JOIN work_orders w2 ON w2.id = f.work_order_id
          WHERE f.has_plan AND f.planned_or_expected_qty > 0::numeric AND (f.side = 'input'::text AND (w2.status = ANY (ARRAY['released'::text, 'closed'::text])) AND f.actual_qty > (f.planned_or_expected_qty * (1::numeric + (( SELECT ps.wo_input_overrun_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)) OR f.side = 'output'::text AND w2.status = 'closed'::text AND f.actual_qty < (f.planned_or_expected_qty * (1::numeric - (( SELECT ps.wo_output_shortfall_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)))) a
  WHERE has_permission(permission) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));
GRANT SELECT ON public.operations_now TO anon, authenticated, service_role;

-- 重建 supplier_receipt_pattern(定义取自线上 pg_get_viewdef,未经手抄)
CREATE VIEW public.supplier_receipt_pattern WITH (security_invoker = off) AS
 WITH win AS (
         SELECT 180 AS window_days
        ), cfg AS (
         SELECT receiving_settings.grn_short_pct,
            receiving_settings.grn_over_pct,
            receiving_settings.grn_assay_tolerance_pct
           FROM receiving_settings
         LIMIT 1
        ), d AS (
         SELECT g.batch_id,
            g.batch_code,
            g.arrival_date,
            g.supplier_id,
            g.line_id,
            g.line_delta_qty,
            g.kinds
           FROM grn_discrepancies g
             CROSS JOIN win w_1
          WHERE g.arrival_date IS NOT NULL AND g.arrival_date >= (CURRENT_DATE - w_1.window_days)
        ), receipt_agg AS (
         SELECT d.supplier_id,
            count(*) AS comparable_receipts,
            count(*) FILTER (WHERE 'short'::text = ANY (d.kinds)) AS short_receipts,
            count(*) FILTER (WHERE 'over'::text = ANY (d.kinds)) AS over_receipts,
            count(*) FILTER (WHERE 'declared_vs_actual'::text = ANY (d.kinds)) AS declared_vs_actual_receipts,
            count(*) FILTER (WHERE 'material_mismatch'::text = ANY (d.kinds)) AS material_mismatch_receipts,
            count(*) FILTER (WHERE 'assay_beyond_tolerance'::text = ANY (d.kinds)) AS assay_beyond_receipts,
            count(*) FILTER (WHERE cardinality(d.kinds) > 0) AS receipts_with_any_discrepancy,
            min(d.arrival_date) AS earliest_receipt,
            max(d.arrival_date) AS latest_receipt
           FROM d
          GROUP BY d.supplier_id
        ), line_facts AS (
         SELECT DISTINCT ON (d.supplier_id, d.line_id) d.supplier_id,
            d.line_id,
            d.line_delta_qty,
            d.kinds
           FROM d
          ORDER BY d.supplier_id, d.line_id, d.batch_id
        ), line_agg AS (
         SELECT lf.supplier_id,
            count(*) FILTER (WHERE 'short'::text = ANY (lf.kinds)) AS short_lines,
            count(*) FILTER (WHERE 'over'::text = ANY (lf.kinds)) AS over_lines,
            COALESCE(sum(lf.line_delta_qty) FILTER (WHERE 'short'::text = ANY (lf.kinds)), 0::numeric) AS short_qty,
            COALESCE(sum(lf.line_delta_qty) FILTER (WHERE 'over'::text = ANY (lf.kinds)), 0::numeric) AS over_qty
           FROM line_facts lf
          GROUP BY lf.supplier_id
        ), excluded_agg AS (
         SELECT b.supplier_id,
            count(*) AS excluded_receipts
           FROM inbound_batches b
             CROSS JOIN win w_1
          WHERE b.deleted_at IS NULL AND b.arrival_date IS NOT NULL AND b.arrival_date >= (CURRENT_DATE - w_1.window_days) AND NOT (EXISTS ( SELECT 1
                   FROM grn_discrepancies g
                  WHERE g.batch_id = b.id))
          GROUP BY b.supplier_id
        ), undated_agg AS (
         SELECT b.supplier_id,
            count(*) AS undated_receipts,
            count(*) FILTER (WHERE (EXISTS ( SELECT 1
                   FROM grn_discrepancies g
                  WHERE g.batch_id = b.id AND cardinality(g.kinds) > 0))) AS undated_with_discrepancy
           FROM inbound_batches b
          WHERE b.deleted_at IS NULL AND b.arrival_date IS NULL
          GROUP BY b.supplier_id
        )
 SELECT s.id AS supplier_id,
    s.code AS supplier_code,
    s.legal_name AS supplier_name,
    w.window_days,
    CURRENT_DATE - w.window_days AS window_from,
    COALESCE(ra.comparable_receipts, 0::bigint) AS comparable_receipts,
    COALESCE(ra.short_receipts, 0::bigint) AS short_receipts,
    COALESCE(ra.over_receipts, 0::bigint) AS over_receipts,
    COALESCE(ra.declared_vs_actual_receipts, 0::bigint) AS declared_vs_actual_receipts,
    COALESCE(ra.material_mismatch_receipts, 0::bigint) AS material_mismatch_receipts,
    COALESCE(ra.assay_beyond_receipts, 0::bigint) AS assay_beyond_receipts,
    COALESCE(ra.receipts_with_any_discrepancy, 0::bigint) AS receipts_with_any_discrepancy,
    COALESCE(la.short_lines, 0::bigint) AS short_lines,
    COALESCE(la.over_lines, 0::bigint) AS over_lines,
    COALESCE(la.short_qty, 0::numeric) AS short_qty,
    COALESCE(la.over_qty, 0::numeric) AS over_qty,
    COALESCE(ea.excluded_receipts, 0::bigint) AS excluded_receipts,
    COALESCE(ua.undated_receipts, 0::bigint) AS undated_receipts,
    COALESCE(ua.undated_with_discrepancy, 0::bigint) AS undated_with_discrepancy,
    ra.earliest_receipt,
    ra.latest_receipt,
    cfg.grn_short_pct,
    cfg.grn_over_pct,
    cfg.grn_assay_tolerance_pct
   FROM suppliers s
     CROSS JOIN win w
     CROSS JOIN cfg
     LEFT JOIN receipt_agg ra ON ra.supplier_id = s.id
     LEFT JOIN line_agg la ON la.supplier_id = s.id
     LEFT JOIN excluded_agg ea ON ea.supplier_id = s.id
     LEFT JOIN undated_agg ua ON ua.supplier_id = s.id
  WHERE s.deleted_at IS NULL AND s.supplies_goods AND has_permission('module.purchasing.view'::text);
COMMENT ON VIEW public.supplier_receipt_pattern IS 'GRN-2:一家供应商一行 —— 这家是不是【一直】短交。一次短交是行情,连续短交是供应商问题,而 grn_discrepancies 逐条说得出"这一条怎么了",说不出"这一家一向如何"。
【三个计数是三件不同的事,永远不许合并】comparable_receipts(窗口内、有日期、比对得了的)是分母;excluded_receipts(有日期但没有订量可比 —— 判据是【不在 grn_discrepancies 里】,因此也涵盖采购单被软删这条路)【不是合规】,它是"没法评判";undated_receipts(没有到货日,放不进任何窗口)是第三类。把后两类折进分母,等于把"不知道"算成"没问题"。
【undated_with_discrepancy 是这一族最要紧的数】它回答"把日期补上会不会改变结论"。实测(2026-08-18):全库唯一一条 short(IN-2026-0029)正在这一类里 —— 一个朴素的窗口谓词会让那家供应商显示"零次短交"。
【次数按收货算,数量按采购行算】line_delta_qty 是行级事实、挂在该行的每一条收货上,直接按收货求和会把挂了多次收货的行算两遍(线上已有一条)。所以 short_qty / over_qty 在 DISTINCT line_id 上汇总,而 *_receipts 按收货计数。两种单位,列名各自说清。
【没有"一贯短交"这个布尔量,也没有百分比】那需要一个没有人选过的阈值,而这张视图没有资格替采购员做那个判断;百分比则藏起分母(1 次里 1 次也是 100%)。给原始计数,分母摆在明处。
【短交的定义只有一处】本视图读 grn_discrepancies,不重算 —— 两份定义必然漂开。三个阈值同样现读 receiving_settings,并【原样返回】,好让屏幕显示的就是判出这些计数的那三个数。
【一家没有可比对收货的供应商仍然出现,值为 0】从 suppliers 左连接出发,于是页面分得出"没有可比对的收货"与"查不到这家供应商"。
【属主权限 + module.purchasing.view】跨 purchasing × inbound 两模块,invoker 会让无权那侧的行被 RLS 静默丢掉(OPS-14)。实测线上没有任何角色持 purchasing.view 而不持 inbound.view,所以这道门不比今天任何一条路径更宽。';
GRANT SELECT ON public.supplier_receipt_pattern TO anon, authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────────
-- (b) 货代的物流属性 —— 与 supplier 同一个 id,一对一
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE public.forwarder_details (
    supplier_id     uuid PRIMARY KEY REFERENCES public.suppliers (id),
    main_routes     text,
    ports_served    text,
    free_time_terms text,
    dg_classes      text,
    notes           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.forwarder_details IS
'LOG-1a:货代的物流属性。主键【就是】supplier_id —— 一家公司一个 id,一对一。
这样应付账龄、付款分摊、预付冲抵、外币重估整条链完全不用知道"货代"这回事:它看到的还是一个 supplier。
【这里没有联系人,而且不要往这里加】。联系人是一张【共享的子表】,与供应商/客户共用一套形状,那是单独排队的一刀。
在它到来之前,货代的联系人【没有家】—— 这是一个已知的空缺,不是遗漏;
在这里先长一个私有的联系人列,等共享子表落地时就会有两份联系人,而那正是本仓库反复点名的那种漂移。';

COMMENT ON COLUMN public.forwarder_details.dg_classes IS
'LOG-1a:这家货代做得了哪些危险品类别。**自由文本,故意不建枚举** —— 类别体系(IMDG/ADR/UN)按法规与航线走,而本刀不建模任何具名法规(那是 lane_document_requirements.regime 的活,而且它也是自由文本)。';

CREATE TRIGGER trg_forwarder_details_updated_at
    BEFORE UPDATE ON public.forwarder_details
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.forwarder_details ENABLE ROW LEVEL SECURITY;
CREATE POLICY "forwarder_details select" ON public.forwarder_details
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.purchasing.view'::text));
CREATE POLICY "forwarder_details write" ON public.forwarder_details
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));

-- ───────────────────────────────────────────────────────────────────────────
-- (c) 港口与航段。【航段上除了两个港口,什么都没有】
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE public.ports (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code       text NOT NULL UNIQUE,
    name       text NOT NULL,
    country    text,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.ports IS
'LOG-1a:港口主数据。code 惯例是 UN/LOCODE,但【不做 CHECK】—— 内河码头与陆路口岸未必有 LOCODE,一条拦得住真实数据的格式检查比没有检查坏。
country 与 suppliers.country 一样是【自由文本】:本仓库没有国家主数据表,本刀也不建一张(LOG-0 已确认并由 Tim 定下)。';

CREATE TABLE public.lanes (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    origin_port_id       uuid NOT NULL REFERENCES public.ports (id),
    destination_port_id  uuid NOT NULL REFERENCES public.ports (id),
    -- 【清单是否已经定过】—— 见 (e) 的抬头:空清单必须是一个具名状态
    checklist_reviewed_at timestamptz,
    deleted_at           timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid DEFAULT auth.uid(),
    CONSTRAINT lanes_distinct_ports CHECK (origin_port_id <> destination_port_id),
    CONSTRAINT lanes_unique_pair UNIQUE (origin_port_id, destination_port_id)
);

COMMENT ON TABLE public.lanes IS
'LOG-1a:航段 = 起运港 → 目的港。**除此之外什么都没有** —— 承运方式、船公司、时效都不在这里:
航段是"从哪到哪"这个事实,谁来跑、多少钱、要什么单据都挂在它上面,而不是长进它里面。';

COMMENT ON COLUMN public.lanes.checklist_reviewed_at IS
'LOG-1a:这条航段的单据清单【被人定过了没有】。NULL = 从来没定过 —— 那是一个具名状态,不是"不需要任何单据"。
两者在屏幕上必须是两句话:一条没人看过的航段与一条确认过"确实什么都不要"的航段,风险完全不同。
本列由人在确认清单时写,系统永不推断。';

-- ───────────────────────────────────────────────────────────────────────────
-- (d) 报价 —— 【它什么都不入账】
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE public.forwarder_rate_quotes (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id  uuid NOT NULL REFERENCES public.suppliers (id),
    lane_id      uuid NOT NULL REFERENCES public.lanes (id),
    amount_ccy   numeric NOT NULL CHECK (amount_ccy > 0),
    currency     text NOT NULL REFERENCES public.currencies (code),
    valid_from   date NOT NULL,
    valid_to     date NOT NULL,
    notes        text,
    deleted_at   timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    CONSTRAINT frq_validity_order CHECK (valid_to >= valid_from)
);

COMMENT ON TABLE public.forwarder_rate_quotes IS
'LOG-1a:某家货代在某条航段上的报价,带有效期与币种。
**它什么都不入账** —— 没有分录、没有应付、不进 ap_open_items。报价是"他说要多少",实际运费是 freight_documents 那张【凭证】,两者是两件事。
把它们混成一张表,就等于让一份报价看起来像一笔负债 —— 而本仓库对"看起来像答案的东西"点过很多次名。
汇率在这里【不锁】:报价只带币种,锁率发生在实际运费凭证上(freight_documents.fx_rate)。';

CREATE OR REPLACE FUNCTION public.guard_forwarder_rate_quote()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_type text;
    v_code text;
BEGIN
    SELECT counterparty_type, code INTO v_type, v_code
      FROM public.suppliers WHERE id = NEW.supplier_id;
    IF v_type IS DISTINCT FROM 'forwarder' THEN
        RAISE EXCEPTION 'RATE_QUOTE_VENDOR_NOT_A_FORWARDER|%', COALESCE(v_code, NEW.supplier_id::text)
          USING HINT = '报价只能挂在货代身上;这一家不是货代';
    END IF;

    -- 【同一家、同一航段,有效期不许重叠】。重叠意味着同一天有两个价,
    -- 而"哪个算数"没有任何依据可以回答 —— 与其让读的人去猜,不如按名拒绝。
    IF EXISTS (
        SELECT 1 FROM public.forwarder_rate_quotes q
         WHERE q.supplier_id = NEW.supplier_id
           AND q.lane_id = NEW.lane_id
           AND q.deleted_at IS NULL
           AND q.id IS DISTINCT FROM NEW.id
           AND daterange(q.valid_from, q.valid_to, '[]') && daterange(NEW.valid_from, NEW.valid_to, '[]')
    ) THEN
        RAISE EXCEPTION 'FORWARDER_RATE_QUOTE_OVERLAP|%|%', COALESCE(v_code, ''), NEW.lane_id
          USING HINT = '这家货代在这条航段上已有一份有效期重叠的报价;先把旧的收尾或改期';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_forwarder_rate_quotes_guard
    BEFORE INSERT OR UPDATE ON public.forwarder_rate_quotes
    FOR EACH ROW EXECUTE FUNCTION guard_forwarder_rate_quote();

ALTER TABLE public.forwarder_rate_quotes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "forwarder_rate_quotes select" ON public.forwarder_rate_quotes
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.purchasing.view'::text));
CREATE POLICY "forwarder_rate_quotes write" ON public.forwarder_rate_quotes
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));

ALTER TABLE public.ports ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ports select" ON public.ports
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.purchasing.view'::text));
CREATE POLICY "ports write" ON public.ports
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));

ALTER TABLE public.lanes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "lanes select" ON public.lanes
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.purchasing.view'::text));
CREATE POLICY "lanes write" ON public.lanes
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));

-- ───────────────────────────────────────────────────────────────────────────
-- (e) 航段单据清单 —— 【单据要求是数据,不是代码】
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE public.lane_document_requirements (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lane_id       uuid NOT NULL REFERENCES public.lanes (id),
    document_type text NOT NULL,
    regime        text,
    notes         text,
    deleted_at    timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.lane_document_requirements IS
'LOG-1a:某条航段上要哪些单据。**一行一种单据,法规(regime)只是它的一个属性** ——
Basel、OECD、各国口岸规定在这里都只是 regime 这一列里的一个字符串,**本刀不为任何一个具名法规建模**:
法规会变、会叠加、会按国家不同,把它写进 schema 就等于把一份会过期的法律抄进表结构里。
【一行都不预置】。清单由人按航段填 —— 一份猜出来的合规清单比没有清单坏,它会让"没人看过"读成"看过了、没问题"
(与 exec-views-plan.md 里"危废存储天数等牌照文本"同一条理由)。
【空清单是一个具名状态】:见 lanes.checklist_reviewed_at 与视图 lane_checklist_status。';

COMMENT ON COLUMN public.lane_document_requirements.regime IS
'LOG-1a:这份单据出自哪一套规矩(例如巴塞尔公约、OECD 决定、某国口岸要求)。**自由文本,故意不做 CHECK、不做枚举、不做外键。**
本刀不建模任何具名法规 —— 一个枚举会在下一次法规修订时变成谎言,而一条拦得住真实单据的检查比没有检查坏。';

ALTER TABLE public.lane_document_requirements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "lane_document_requirements select" ON public.lane_document_requirements
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.purchasing.view'::text));
CREATE POLICY "lane_document_requirements write" ON public.lane_document_requirements
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));

-- 【空与未定义,是两句话】
CREATE VIEW public.lane_checklist_status
WITH (security_invoker = on) AS
SELECT
    l.id AS lane_id,
    l.checklist_reviewed_at,
    count(r.id) FILTER (WHERE r.deleted_at IS NULL)::integer AS requirement_count,
    CASE
        WHEN l.checklist_reviewed_at IS NULL THEN 'not_defined'
        WHEN count(r.id) FILTER (WHERE r.deleted_at IS NULL) = 0 THEN 'defined_empty'
        ELSE 'defined'
    END AS checklist_state
FROM public.lanes l
LEFT JOIN public.lane_document_requirements r ON r.lane_id = l.id
WHERE l.deleted_at IS NULL
GROUP BY l.id, l.checklist_reviewed_at;

COMMENT ON VIEW public.lane_checklist_status IS
'LOG-1a:一条航段的单据清单处于哪一种状态 —— **三种,不是两种**:
not_defined  = 从来没人定过(checklist_reviewed_at 为 NULL)。**这不是"不需要单据"**,是"没人看过"。
defined_empty = 有人确认过,而且确实什么都不要。
defined      = 有人定过,并且列了要求。
把前两者混成"零条要求",就是把一次未完成的工作显示成一次完成的结论 —— 本仓库对空集当答案点过很多次名。
security_invoker = on:行过滤就是 RLS 本身。';

GRANT SELECT ON public.lane_checklist_status TO anon, authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────────────
-- (f) 两个方向的守卫,都按名拒绝
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_po_vendor_not_forwarder()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_type text;
    v_code text;
    v_name text;
BEGIN
    SELECT counterparty_type, code, legal_name INTO v_type, v_code, v_name
      FROM public.suppliers WHERE id = NEW.supplier_id;
    IF v_type = 'forwarder' THEN
        RAISE EXCEPTION 'PO_VENDOR_IS_A_FORWARDER|%|%', COALESCE(v_code, ''), COALESCE(v_name, '')
          USING HINT = '货代不能当采购单的供应商 —— 运费走运费凭证,不走采购单';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_po_vendor_not_forwarder() IS
'LOG-1a:采购单的供应商不能是货代。【界面同时会把货代从选择器里排除(LOG-1b),但那是体贴,不是边界】——
谁都可以直接打 PostgREST,所以判据装在触发器上。按名抛 PO_VENDOR_IS_A_FORWARDER|<code>|<name>。';

CREATE TRIGGER trg_purchase_orders_vendor_not_forwarder
    BEFORE INSERT OR UPDATE ON public.purchase_orders
    FOR EACH ROW EXECUTE FUNCTION guard_po_vendor_not_forwarder();

CREATE OR REPLACE FUNCTION public.guard_forwarder_details_is_forwarder()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_type text;
    v_code text;
BEGIN
    SELECT counterparty_type, code INTO v_type, v_code
      FROM public.suppliers WHERE id = NEW.supplier_id;
    IF v_type IS DISTINCT FROM 'forwarder' THEN
        RAISE EXCEPTION 'FORWARDER_DETAILS_NOT_A_FORWARDER|%', COALESCE(v_code, NEW.supplier_id::text)
          USING HINT = '这一家不是货代,给它挂物流属性没有意义 —— 先把 counterparty_type 改成 forwarder';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_forwarder_details_is_forwarder() IS
'LOG-1a:反方向的守卫 —— 供货商不能被当成货代挂物流属性。按名抛 FORWARDER_DETAILS_NOT_A_FORWARDER|<code>。';

CREATE TRIGGER trg_forwarder_details_is_forwarder
    BEFORE INSERT OR UPDATE ON public.forwarder_details
    FOR EACH ROW EXECUTE FUNCTION guard_forwarder_details_is_forwarder();

COMMIT;
