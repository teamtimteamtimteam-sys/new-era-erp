-- EXEC-3a:四支高管臂 —— 而第五支【被撤掉了】,理由写在清单里
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 规格取自 docs/dashboard-arm-inventory.md(它治理这件事)与
-- docs/exec-views-plan.md §2。四支:
--   qualification_expiring · qualification_missing(CMP-1 的两支,逐字照办)
--   work_order_overdue · work_order_variance_beyond(WO-1c 记下的两个候选)
--
-- 【第五支 batch_margin 撤了】一个卖出去的批次毛利偏低,是一个【状态】,
-- 不是一件"等人处理的事" —— 它没有清除动作:你不能"处理掉"一个已经发生的毛利。
-- 看板装的是待办(operations_now 这个名字就是这个意思),而毛利的家是 /margin。
-- 真正可处理的那一半【已经在册】:arm 15 margin_cost_not_allocated —— 成本没分摊,
-- 而分摊是一个真的动作,做完灯就灭。清单里那一行改写成这个判词。
--
-- 【本刀装的两个阈值,回答的是清单里留的那个问题】WO-1c 写着:
-- "需要…Tim 对【投入超耗】与【产出短交】是否用同一个阈值的一句话 —— 它们是
--  两种不同的坏消息"。答案是【不是同一个】,所以 processing_settings 有两列。
-- 而"两种不同的坏消息"还体现在触发时机上:超耗在发生那一刻就可处理,
-- 短交在收工之前只是"还没做完"。
--
-- 【dashboard.item.* 的四个标签键在本刀一并加】EXEC-1a 的教训:check-i18n 的
-- 后缀集合现读 operations_now.sql 的 item_type 字面量,所以视图与那几个键是一次
-- 原子改动 —— 少了它们,npm run build 当场红。
-- 牌子与设置面板是 3b。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 两个阈值有了家 ═════════════════════════════════════════════════════
-- 单行配置表,形状取自 pricing_settings(METAL-1)。
CREATE TABLE public.processing_settings (
    id boolean PRIMARY KEY DEFAULT true CHECK (id),
    -- 投入超耗:吃掉的比计划多出百分之几算"超了"
    wo_input_overrun_pct numeric NOT NULL DEFAULT 10
        CHECK (wo_input_overrun_pct > 0),
    -- 产出短交:产出比预期少百分之几算"短了"
    wo_output_shortfall_pct numeric NOT NULL DEFAULT 10
        CHECK (wo_output_shortfall_pct > 0),
    notes text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.processing_settings IS
    'EXEC-3a:加工模块的单行配置。今天装着工单差异的两个阈值 —— 【两个,不是一个】:投入超耗与产出短交是两种不同的坏消息(WO-1c 在 arm inventory 里问的正是这一句),一个是成本问题、一个是收率问题,合成一个数等于说它们一样严重。默认各 10%。看板的 work_order_variance_beyond 支【现读这两列】,没有任何地方写死这两个数(与 FIN-36 把分摊基准从 schema 默认值提出来同一条:一个谁也看不见的默认值等于替所有人做了这个判断)。';
COMMENT ON COLUMN public.processing_settings.wo_input_overrun_pct IS
    '投入超耗的阈值(百分比)。吃掉的量超过计划量 ×(1 + 本值/100)时,那张工单进看板。【开着的单和收了工的单都报】—— 超耗在它发生的那一刻就是可处理的事。';
COMMENT ON COLUMN public.processing_settings.wo_output_shortfall_pct IS
    '产出短交的阈值(百分比)。产出量低于预期量 ×(1 − 本值/100)时,那张工单进看板。【只报收了工的单】—— 收工之前,"少"只是"还没做完",报出来等于每天提醒一件正在进行的事。没记录预期的行永远不报:没估过不是估了零。';

INSERT INTO public.processing_settings (id) VALUES (true);

ALTER TABLE public.processing_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_settings select by permission" ON public.processing_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));
CREATE POLICY "processing_settings update by permission" ON public.processing_settings
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));

-- ═══ 2 · 四支臂 ════════════════════════════════════════════════════════════
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
-- ── EXEC-3a:资质到期(CMP-1 的第一支)───────────────────────────────────────
-- 【没有 −30 天下限,这是这一支最要紧的一句】hr_alerts 的 work_pass_expiry 是
-- 这个形状的原型,它带着 `>= -30` 的下限:过期超过一个月就不再报。那个下限对
-- 工作准证是合理的(人早就走了),对【阻断类】的证书是危险的 —— 线上此刻就有
-- 一张过期两年半的证书,带下限的告警会把它静默丢掉,而它恰恰是最该被看见的那张。
--
-- 【disposition = 'ignore' 的不进来】那些是公司明确决定不追的instrument,
-- 把它们放到一块"等人处理"的看板上,只会稀释真正要处理的那几张。
-- 这是一个判断,写下来:看板是给【要做的事】用的,不是给【所有事实】用的。
--
-- 窗口取 certificate_types.warn_lead_days(每类自己的提前量:阻断类 90 天、
-- ISO 60 天、其他 30 天)—— 不写死一个数,与 metal_quote_stale 同一条。
-- 门牌指供应商编辑页:续证就在那张页面上的 CompliancePanel(fixture 47 钉住)。
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            sc.supplier_id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            ct.name_en || ' · ' || sc.valid_until::text AS subject,
            sc.valid_until AS item_date
           FROM supplier_compliance sc
             JOIN certificate_types ct ON ct.code = sc.cert_type_code
             JOIN suppliers s ON s.id = sc.supplier_id
          WHERE sc.deleted_at IS NULL AND s.deleted_at IS NULL
            AND ct.is_active AND ct.disposition <> 'ignore'::text
            AND sc.valid_until IS NOT NULL
            AND (sc.valid_until - CURRENT_DATE) <= ct.warn_lead_days
        UNION ALL
-- ── EXEC-3a:一张证都没有(CMP-1 的第二支)─────────────────────────────────
-- 【缺席不是过期,它需要自己的一支】—— 与 awaiting_assay 之于 assay_unapplied
-- 同一条(CMP-1 的原话)。上面那一支扫的是【存在但快过期/已过期】的证书;
-- 一个一张证都没有的供应商在那一支里【一行都不会出现】,而那是最糟的情形。
-- 形状取自 holiday_calendar_missing:配置缺席,而不是配置过期。
--
-- 【判据是"一张都没有",不是"缺某一类"】—— 后者需要一张"谁必须持有哪几类"的
-- 要求矩阵,而这个库里没有:suppliers.supplier_types 有 recycler/trader/dismantler
-- 这些值,但没有任何东西说明哪一类必须持哪张证。造一个矩阵出来等于替人做了
-- 一个没人做过的决定,而它会立刻变成 3 家供应商 × 5 类阻断证 = 15 行噪音。
-- **有了"这家需要合规文件"的标记之后,这一支应当收窄到它** —— 记在
-- docs/dashboard-arm-inventory.md 里,不在这里悄悄替它决定。
--
-- item_date 取供应商的建档日:days_waiting 因此读作"这家进来多久了还没有任何证"。
         SELECT 'qualification_missing'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            s.legal_name AS subject,
            s.created_at::date AS item_date
           FROM suppliers s
          WHERE s.deleted_at IS NULL
            AND NOT EXISTS (
                SELECT 1 FROM supplier_compliance sc
                 WHERE sc.supplier_id = s.id AND sc.deleted_at IS NULL)
        UNION ALL
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
  WHERE has_permission(permission) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));;

COMMIT;
