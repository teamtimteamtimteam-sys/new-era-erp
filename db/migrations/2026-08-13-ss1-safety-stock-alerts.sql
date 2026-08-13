-- db/migrations/2026-08-13-ss1-safety-stock-alerts.sql
-- SS-1:安全库存告警 —— 阈值是【有人做过的一个决定】,而空着不是零
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这一刀的全部难点在 NULL 上,不在算术上】
-- safety_stock_qty IS NULL 的意思是【还没有人决定要盯这个物料】,不是"阈值为零"。
-- 这两者在屏幕上长得一模一样(都不告警),但它们的【将来】完全不同:
--   * 阈值为零 = 有人看过、决定这东西缺货也无所谓;
--   * NULL     = 没有人想过这件事。
-- 把后者读成"查过了,没问题",正是 METAL-1 的 no_reference 那一课:一个不会响的
-- 检查比没有检查更坏,因为人以为系统在替他盯着。所以:
--   * 告警对 NULL 【一次都不响】;
--   * 而物料列表必须把"未监控"【写出来】,绝不留空 —— 空白读起来像"没事",
--     而它的真实含义是"没人设过"。这一条在 Step 2 的列表列上兑现。
--
-- 【CHECK 只管"存在时必须为正"】阈值 0 会让告警永远不响,那是把"不监控"写成一个
-- 看起来像监控的数字 —— 要不监控,就留空,那是【同一个意思的唯一一种写法】。
-- 负数无意义。所以 NULL 或 > 0,没有第三种。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【可用量:一处求和,不是第二份 drain 逻辑】
-- material_stock_available 把流水按物料聚合,判据只有一句:
--     stock_status = 'available'
-- 这与 derived_stock_qty 用的是【同一条规则】,只是粒度不同(它按 批次×库位×状态,
-- 这里按 物料)。没有复制任何 drain / 状态流转的逻辑 —— 那些逻辑写在流水【怎么产生】
-- 那一侧,这里只是把已经产生的流水加起来。
--
-- 【为什么不直接调 derived_stock_qty】它按批次×库位取数,一个物料要调 N 次;而且
-- 它自带 require_permission('module.inventory.view') —— 一个属主权限视图在体内替
-- 调用者做权限判断是对的,但那应当由视图自己的谓词表达一次,而不是被一个算子在
-- 每行上重复抛出。
--
-- 【暂扣的货【不】算进来,这是判据的一部分】阈值问的是"还有多少【能用】的货",
-- 而暂扣的那部分按定义不能用。把暂扣算进可用,会让一次暂扣把缺货掩盖掉 ——
-- 那恰好是这个告警最该说话的时刻。fixture 60 D 臂钉住这一条。
--
-- 【属主权限 + 体内谓词】(AGENTS.md 修法 (a))本视图跨 materials 与
-- inventory_movements,invoker 会让 RLS 把读者无权的行【静默丢掉】,而行丢掉在
-- 聚合里意味着"可用量偏小" —— 一个偏小的可用量会【凭空造出告警】。所以属主权限
-- 读全量,谓词写在体内,按调用者裁决:无权的读者【一行都没有】,不是一个错的数。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【新增一支仪表盘臂:safety_stock_below】
-- 规格见 docs/dashboard-arm-inventory.md(同一提交里加了一行 —— 那份清单的规矩)。
--   permission : module.inventory.view(看得见库存分布 = 看得见库存模块)
--   item_id    : 物料本身 —— 【补救动作在那张页面上】(把阈值改掉,或者去补货;
--                前者就在物料编辑页,后者从物料出发)。
--   subject    : 可用 / 阈值 单位 —— 差额。视图的列集是固定的,没有数值列,
--                而这三个数正是这支唯一有用的内容,所以它们进 subject 文本。
--   item_date  : 【最后一次库存移动】,没有就退回今天。阈值告警是一个【持续状态】,
--                不是一件在某天发生的事 —— 它没有天然的发生日。用最后一次移动,
--                是因为那是这个数字最后一次改变的时刻;去算"哪天跌破的"要在首页
--                翻整段流水史,而首页那条界的规矩不允许(credit_over_limit 用
--                COALESCE(最后一次销售, CURRENT_DATE) 是同一形状的先例)。
--
-- 镜像:db/tables/materials.sql、db/views/{material_stock_available,operations_now}.sql、
--       docs/dashboard-arm-inventory.md。
-- 行为断言:fixture 60(本刀);fixture 47 的支清单 + 建行、fixture 30 的合计同步。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 阈值列 ═════════════════════════════════════════════════════════════
ALTER TABLE public.materials
    ADD COLUMN safety_stock_qty numeric;

ALTER TABLE public.materials
    ADD CONSTRAINT materials_safety_stock_qty_positive
    CHECK (safety_stock_qty IS NULL OR safety_stock_qty > 0);

COMMENT ON COLUMN public.materials.safety_stock_qty IS
    'SS-1:安全库存阈值(按物料的计量单位)。【NULL = 不监控 = 还没有人做过这个决定】,绝不等于"阈值为零":告警对 NULL 一次都不响,而这个"不响"【不可以被读成"查过了,没问题"】—— 那是 METAL-1 的 no_reference 那一课(一个不会响的检查比没有检查更坏,因为人以为系统在替他盯着)。所以物料列表把"未监控"明写出来,不留空。CHECK 只允许 NULL 或 > 0:阈值 0 是把"不监控"写成一个看起来像监控的数字,而"不监控"的唯一写法是留空。告警是【采购信号】—— 低于阈值不拦任何销售、投料或收货。';

-- ═══ 2 · 按物料的可用量:一处求和 ═══════════════════════════════════════════
CREATE VIEW public.material_stock_available WITH (security_invoker = off) AS
 SELECT m.id AS material_id,
    m.code,
    m.name,
    m.unit,
    m.safety_stock_qty,
    COALESCE(s.available_qty, 0::numeric) AS available_qty,
    s.last_movement_date
   FROM materials m
     LEFT JOIN ( SELECT COALESCE(ib.material_id, ob.material_id) AS material_id,
            sum(mv.qty_delta) AS available_qty,
            max(mv.business_date) AS last_movement_date
           FROM inventory_movements mv
             LEFT JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
             LEFT JOIN output_batches ob ON ob.id = mv.output_batch_id
          WHERE mv.stock_status = 'available'::text
          GROUP BY (COALESCE(ib.material_id, ob.material_id))) s ON s.material_id = m.id
  WHERE m.deleted_at IS NULL
    AND has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.material_stock_available IS
    'SS-1:按物料的【可用】库存(stock_status = ''available'' 的流水求和,两种批次都算)。与 derived_stock_qty 同一条规则、不同粒度 —— 那个按 批次×库位×状态,这个按物料;没有复制任何 drain/状态流转逻辑。【暂扣不算】:阈值问的是"还有多少能用的货",而一次暂扣若能掩盖缺货,这个告警恰好在最该说话的时刻哑掉。属主权限 + 体内 has_permission —— invoker 会让 RLS 丢行,而聚合里丢行等于可用量偏小,偏小会【凭空造出告警】。';

-- ═══ 3 · 仪表盘臂 ═══════════════════════════════════════════════════════════
-- 列集不变(只多一支 UNION),所以 CREATE OR REPLACE 够用。
CREATE OR REPLACE VIEW public.operations_now WITH (security_invoker = off) AS
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
            ((((((trim_scale(msa.available_qty))::text || ' / '::text) || (trim_scale(msa.safety_stock_qty))::text) || ' '::text) || COALESCE(msa.unit, ''::text)) || ' — short '::text) || (trim_scale(msa.safety_stock_qty - msa.available_qty))::text AS subject,
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
            ar.sales_record_id AS item_id,
            NULL::text AS doc_kind,
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
          WHERE bm.margin_status = 'no_unit_cost'::text) a
  WHERE has_permission(permission) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));

COMMIT;
