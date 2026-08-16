-- FXG-1:fx_rate_gaps 把自己的数字说清楚 —— 一行一个数,一个数一件事
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【改之前它在撒三种谎,都是实测出来的】
-- 这张视图有两支来源(METAL-3 加的第二支):【过账】与【报价】。
-- 而它把两支的计数 sum() 进同一列 txn_count,页面的文案则一律念成"当天 N 笔凭证"。
--
--   ① 纯报价日:2026-08-20 / CNY / {mid} / txn_count=2 / gap_source=quote
--      —— 那天【一笔外币凭证都没有】。屏幕上写的是"当天 2 笔凭证"。
--   ② 混合日:2026-08-21 / CNY / {tt_buy,tt_sell,mid} / txn_count=2 / gap_source=posting+quote
--      —— 那个 2 是【1 笔凭证 + 1 条报价】,两种单位相加。屏幕上还是"2 笔凭证"。
--   ③ 顶上那句总述:"{n} 天有外币过账、却没有当日牌价" —— 对 ① 那种行整句不成立。
--
-- (线上今天恰好只有 posting 那一支的 7 行,所以这三种谎【一次都没有被看见过】。
--  上面两行是回滚型探针造出来的真实视图输出,不是设想。)
--
-- 【为什么是拆成两列,而不是"一列 + 按 gap_source 变的标签"】
-- 混合日两支【都】命中,它真的有两个数;一列只能挑一个说,那是另一种撒谎。
-- 拆开之后每一列的单位是固定的,页面直接画,不做第二次推导。
--
-- 【0 在这里是一次测量,不是一个占位】纯报价日的 entry_count = 0,因为过账那一支
-- 【扫过了那一天】并且确实没有非本位币凭证 —— 与「报表不报这一行 ≠ 报表报了 0」
-- 那条不矛盾:那里的 0 是把"没问过"说成"答案是零",这里的 0 是问过了、答案就是零。
--
-- 【为什么要 DROP 而不是 CREATE OR REPLACE】CREATE OR REPLACE VIEW 只能在末尾加列,
-- 删不掉也改不了名。留着 txn_count 就是把这个陷阱留给下一个人 —— 一个"有时是凭证数、
-- 有时是报价数、有时是两者相加"的列,读的人没有任何办法看出自己拿到的是哪一种。
-- 依赖链实测只有一条(operations_now,而且它不读 txn_count;没有任何东西依赖
-- operations_now),所以显式按序 DROP 两张、再按序重建 —— 不用 CASCADE:
-- CASCADE 会连我没有列举过的东西一起删掉,而我恰恰已经把它们数清楚了。
-- operations_now 的主体从 db/views/operations_now.sql 【逐字节】取出,一个字没改;
-- 它的 GRANT 一并重述(DROP 会带走授权)。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

DROP VIEW public.operations_now;
DROP VIEW public.fx_rate_gaps;

CREATE VIEW public.fx_rate_gaps WITH (security_invoker = on) AS
 SELECT d.rate_date,
    d.currency,
    m.missing_types,
    d.entry_count,
    d.quote_count,
    d.gap_source
   FROM ( SELECT u.rate_date,
            u.currency,
            sum(u.entry_count)::bigint AS entry_count,
            sum(u.quote_count)::bigint AS quote_count,
            bool_or(u.src = 'posting'::text) AS needs_settlement_types,
            array_to_string(array_agg(DISTINCT u.src ORDER BY u.src), '+'::text) AS gap_source
           FROM ( SELECT e.entry_date AS rate_date,
                    l.currency,
                    count(DISTINCT l.entry_id) AS entry_count,
                    0::bigint AS quote_count,
                    'posting'::text AS src
                   FROM journal_lines l
                     JOIN journal_entries e ON e.id = l.entry_id
                  WHERE l.currency <> (( SELECT c.code
                           FROM currencies c
                          WHERE c.is_base)) AND e.status = 'posted'::text
                  GROUP BY e.entry_date, l.currency
                UNION ALL
                 SELECT mp.price_date AS rate_date,
                    i.quote_currency AS currency,
                    0::bigint AS entry_count,
                    count(*) AS quote_count,
                    'quote'::text AS src
                   FROM metal_prices mp
                     JOIN metal_price_indices i ON i.code = mp.price_index
                  WHERE mp.deleted_at IS NULL AND i.is_active AND i.quote_currency IS NOT NULL AND i.quote_currency <> (( SELECT c.code
                           FROM currencies c
                          WHERE c.is_base))
                  GROUP BY mp.price_date, i.quote_currency) u
          GROUP BY u.rate_date, u.currency) d
     CROSS JOIN LATERAL ( SELECT array_agg(t.t) AS missing_types
           FROM unnest(
                CASE
                    WHEN d.needs_settlement_types THEN ARRAY['tt_buy'::text, 'tt_sell'::text, 'mid'::text]
                    ELSE ARRAY['mid'::text]
                END) t(t)
          WHERE NOT (EXISTS ( SELECT 1
                   FROM fx_rate_asof(d.currency, d.rate_date, t.t) fx_rate_asof(rate, as_of)))) m
  WHERE m.missing_types IS NOT NULL;

-- ── operations_now:逐字节取自 db/views/operations_now.sql,一个字没改 ─────────
-- 它只读 rate_date / currency / missing_types,不读计数列 —— 重建它纯粹是因为
-- DROP 那一张必须先拿掉依赖者。
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
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.assay_count = 0
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
          WHERE s_2.deleted_at IS NULL AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
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
          WHERE so.deleted_at IS NULL AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))        UNION ALL
-- ── EXEC-3a:工单逾期 ──────────────────────────────────────────────────────
-- 【排产日为空【永远不是】逾期】—— 空的意思是"没排期",而不是"排在过去"。
-- 一个 COALESCE(scheduled_date, CURRENT_DATE) 会把没排期的全部报成今天到期,
-- COALESCE(..., 'infinity') 会把它们全部漏掉 —— 两个方向都错,所以这里
-- 显式 IS NOT NULL(WO-1c 记在 arm inventory 里的那条)。
--
-- 【"放行了三个月、从没排过期"该不该有别的支管】—— 仍然是一个【开着的问题】,
-- 记在 arm inventory 里。这一支不假装回答它:它只报"排了期而且过了期"的。
         SELECT 'work_order_overdue'::text AS item_type,
            'module.processing.view'::text AS permission,
            w.id AS item_id,
            NULL::text AS doc_kind,
            w.code AS item_code,
            w.scheduled_date::text AS subject,
            w.scheduled_date AS item_date
           FROM work_orders w
          WHERE w.status = 'released'::text
            AND w.scheduled_date IS NOT NULL
            AND w.scheduled_date < CURRENT_DATE
        UNION ALL
-- ── EXEC-3a:工单差异超阈 ──────────────────────────────────────────────────
-- 【两种坏消息,两个阈值,两种触发时机】—— WO-1c 在 arm inventory 里留的那个
-- 问题("投入超耗与产出短交是否用同一个阈值")的答案是【不是】,所以
-- processing_settings 有两列,而这一支有两条腿:
--
--   * 投入超耗:吃掉的比计划多出 t_in% 以上。**开着的单和收了工的单都报** ——
--     超耗在它发生的那一刻就是可处理的事(料已经下去了,要么改计划、要么查为什么)。
--   * 产出短交:产出比预期少 t_out% 以上。**只报收了工的单** —— 在收工之前,
--     "少"只是"还没做完",把它报出来等于每天提醒一件正在进行的事。
--
-- 【没记录预期的行永远不报】has_plan = false 意味着没人估过,而不是估了零。
-- 一个把它当零的实现会让每一次产出都成为"短交 100%"—— 这正是 WO-1a 让
-- 预期产出行可选、WO-1b 让视图返回 NULL 的全部理由,在这里必须一路守住。
--
-- 阈值现读 processing_settings,不写死(与 metal_quote_stale 同一条)。
         SELECT 'work_order_variance_beyond'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.work_order_id AS item_id,
            NULL::text AS doc_kind,
            f.work_order_code AS item_code,
            CASE WHEN f.side = 'input'::text
                 THEN 'input overrun · ' || COALESCE(f.material_code, '?') || ' · '
                      || trim_scale(f.actual_qty)::text || ' / ' || trim_scale(f.planned_or_expected_qty)::text
                 ELSE 'output shortfall · ' || COALESCE(f.material_code, '?') || ' · '
                      || trim_scale(f.actual_qty)::text || ' / ' || trim_scale(f.planned_or_expected_qty)::text
            END AS subject,
            COALESCE(w2.scheduled_date, w2.created_at::date) AS item_date
           FROM work_order_fulfilment f
             JOIN work_orders w2 ON w2.id = f.work_order_id
          WHERE f.has_plan
            AND f.planned_or_expected_qty > 0::numeric
            AND (
                 (f.side = 'input'::text
                  AND w2.status = ANY (ARRAY['released'::text, 'closed'::text])
                  AND f.actual_qty > f.planned_or_expected_qty
                      * (1::numeric + (SELECT ps.wo_input_overrun_pct FROM processing_settings ps LIMIT 1) / 100::numeric))
              OR (f.side = 'output'::text
                  AND w2.status = 'closed'::text
                  AND f.actual_qty < f.planned_or_expected_qty
                      * (1::numeric - (SELECT ps.wo_output_shortfall_pct FROM processing_settings ps LIMIT 1) / 100::numeric))
            )
) a
  WHERE has_permission(permission) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));;;;

GRANT SELECT ON public.operations_now TO authenticated;

COMMIT;
