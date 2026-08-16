-- EXEC-1a:两支高管臂 —— 行情陈旧、未履约订单
--
-- 规格取自 docs/exec-views-plan.md §2(Sandra 的 a 与 c)与
-- docs/dashboard-arm-inventory.md 里的 ASY-3 那一节。两份文件的分工照旧:
-- 支的规格写在 arm inventory,归属写在 plan doc,这一刀两边都不复制。
--
-- ── 这一刀装了什么 ────────────────────────────────────────────────────────
--   ① pricing_settings 多一列:行情陈旧的天数阈值(NOT NULL DEFAULT 14)——
--      ASY-3 报告为它留的那一列。METAL-1 建这张表时就是为了这一刻:
--      "两件事都是【行情这个序列现在不可信】,一个因为它错,一个因为它旧"。
--   ② operations_now 多两支。视图的列契约一字未动,只是 UNION 里多了两个分支。
--
-- 【为什么阈值默认 14 而不是 7 或 30】实测(ASY-3,2026-08-10):有史以来只有
-- 3 个行情日、分 2 次录入,四个金属各只有一条报价。按这个"六周两次"的节奏,
-- 7 天会天天响 —— 一个天天响的警报等于没有警报;30 天则要等到 average 口径
-- 已经开始跳过那个金属之后才响,那时数字已经错了。14 是这两者之间的一次决定,
-- 而【它住在可见配置里】,所以它是一个可以被改的决定,不是一个藏起来的假设。
--
-- 【本刀不碰的两件事,写下来免得下一个人以为漏了】
--   * 窗口太薄(average 口径下窗口内 < 2 条报价)—— 它改变的是【数字的含义】
--     而不只是它的年龄,所以它属于计价面板,不属于看板(ASY-3 的结论,逐字照办);
--   * 牌子、面板字段、i18n 文案 —— EXEC-1b。
--     **例外:两个 dashboard.item.* 标签键在本刀一并加。** 不是"顺手做了 1b" ——
--     check-i18n 的后缀集合【现读本文件的 item_type 字面量】,所以视图与那两个键
--     是一次原子改动:少了它们,npm run build 当场红。
BEGIN;

-- ═══ 1 · 阈值有了家 ════════════════════════════════════════════════════════
ALTER TABLE public.pricing_settings
    ADD COLUMN metal_quote_stale_days integer NOT NULL DEFAULT 14
        CHECK (metal_quote_stale_days > 0);

COMMENT ON COLUMN public.pricing_settings.metal_quote_stale_days IS
    '行情多少天没更新算【旧】(EXEC-1a,ASY-3 报告为它留的那一列)。看板的 metal_quote_stale 支现读这一列 —— 【没有任何地方写死这个数】。默认 14:实测录入节奏是"六周两次",7 天会天天响(等于没有警报),30 天要等到 average 口径已经跳过那个金属之后才响。判据按 price_date 不按 created_at —— 补录发生过(6-25 的行情 7-2 才录进来),按 created_at 会让补录当天显得刚刚更新过。';

-- ═══ 2 · 两支臂 ════════════════════════════════════════════════════════════
-- CREATE OR REPLACE:列契约一字未动(item_type / permission / permission_any /
-- item_id / doc_kind / item_code / subject / item_date / days_waiting),
-- 只是内层 UNION 多了两支。
CREATE OR REPLACE VIEW public.operations_now AS
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
-- ── EXEC-1a:行情陈旧 ────────────────────────────────────────────────────────
-- 一个金属一行。判据【只有年龄】—— 窗口太薄那一半不上看板(ASY-3 的原话:
-- 它是关于【这一次计价】的事实,而看板臂是关于【维护欠账】的事实,两个读者、
-- 两个位置),它长在计价面板上,EXEC-1b 做。
--
-- 【按 price_date,绝不按 created_at】—— 实测过:2026-06-25 的行情是 7-2 才录进来的
-- (晚 7 天)。按 created_at 判断新旧,会让一次补录当天显得"刚刚更新过",
-- 而那正好是最需要提醒的时刻。
--
-- 【阈值从 pricing_settings 现读,不写死】实测录入节奏是"六周两次":7 天会天天响
-- (等于没有警报),30 天要等到数字已经被跳过之后才响。14 天是这两者之间的一次
-- 【决定】,而它住在可见配置里 —— 与 FIN-36 把分摊基准从 schema 默认值提出来
-- 是同一条:一个谁也看不见的默认值等于替所有人做了这个判断。
--
-- item_id 指向【最近那一条报价】—— 一个臂要能点进去,而"这个金属"本身没有 id;
-- 最近那条报价正是人要去看、去接着往下录的那一行。
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
          WHERE CURRENT_DATE - mp.max_date >
                (SELECT ps.metal_quote_stale_days FROM pricing_settings ps LIMIT 1)
        UNION ALL
-- ── EXEC-1a:未履约订单 ─────────────────────────────────────────────────────
-- 一张单一行。【"货还欠着"这个读法】—— confirmed(答应了,一件没发)与
-- partially_shipped(发了一部分)。不发明任何排程概念:shipments 没有状态列,
-- 一条发货记录只在货【真的走了】之后才存在,所以"待发运"在这个 schema 里没有指称。
--
-- 【逐单的完成度不在这里算】它由 sales_order_fulfilment_status() 回答 ——
-- 那是一处推导,而这个仓库为"抄一份 Σ vs Σ 过去"付过五次账。这一支只回答
-- "哪些单还欠着货",要看欠多少,点进订单页。
-- item_date 取 order_date,与 po_awaiting_receipt 逐字同一个约定
-- (days_waiting 因此读作"这张单答应了多久还没发完")。
         SELECT 'orders_unfulfilled'::text AS item_type,
            'module.sales.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            so.status AS subject,
            so.order_date AS item_date
           FROM sales_orders so
          WHERE so.deleted_at IS NULL
            AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
) a
  WHERE has_permission(permission) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));;

COMMIT;
