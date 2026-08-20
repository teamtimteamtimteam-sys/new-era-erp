-- LOG-5a(2026-08-20):物流告警的库侧 —— 四支【臂】,没有事件行。
--
-- Tim 已定,本迁移不再论证:四个告警全部是 operations_now 的臂(不是 notifications
-- 的事件);free_days 落在 forwarder_rate_quotes 上;锚点是【最晚的那条 arrived】,
-- 用 container_overview 的既成惯例;ETA 是 containers 上一列可空的世界侧日期;
-- 单据迟到锚 departure_date;v1 阈值写死;免柜期那一支财务也要看得见。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【一处必须先说的偏离 —— brief 指定的机制做不到它要的事】
-- brief 写的是"免柜期那一支 additionally finance via arm_permission_any"。
-- 但 arm_permission_any 在视图末尾是【与】进去的:
--     WHERE has_permission(permission) AND (any IS NULL OR has_any_permission(any))
-- 也就是说它只会【收窄】,永远不会放宽。既有的唯一使用者
-- margin_cost_not_allocated 之所以成立,是因为它的 permission 是一个【两边都持有】
-- 的数据类码(data.view_prices),any 才是模块的"二选一"。
-- 而 logistics(暂借 module.purchasing.view)与 finance 之间【没有任何共同码】——
-- 线上 36 个权限码里一个都没有。所以照 brief 的字面写,财务【看不见】那一支。
--
-- 【本迁移的做法】另加一个【放宽】用的算子 arm_permission_widen(),与收窄的
-- arm_permission_any() 并列,末尾改成:
--     WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type)))
--       AND (arm_permission_any(item_type) IS NULL OR has_any_permission(...))
-- 【对既有 22 支逐支无影响,而且这是可证的】:arm_permission_widen 对除
-- free_time_expiring 以外的每一个 item_type 都返回 NULL,而
-- has_any_permission(NULL) = EXISTS(SELECT … FROM unnest(NULL)) = false ——
-- 于是 `has_permission(permission) OR false` 与改动前逐字节等价。
-- fixture 里两个方向都断言。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── (a) 免柜天数 ────────────────────────────────────────────────────────────
ALTER TABLE public.forwarder_rate_quotes
    ADD COLUMN free_days integer CHECK (free_days IS NULL OR free_days >= 0);

COMMENT ON COLUMN public.forwarder_rate_quotes.free_days IS
'LOG-5a:这份报价给了几个免柜天。
【NULL 与 0 是两件不同的事,而这条区别撑着整支告警】
  * NULL = 【这份报价没有写免柜期】—— 我们不知道,于是那一支告警【保持沉默】;
  * 0    = 【零个免费天】—— 一到港就开始计滞港费,告警从第一天起就该响。
把 NULL 当成 0,会让每一个到港的箱子从第一天起报警(喊狼来了);
把 0 当成 NULL,会让一个【真的从第一天起就在烧钱】的箱子一声不吭。
两种错的方向相反,而后一种更贵 —— 所以两者都不许被推断,只能被写下来。
CHECK 允许 0,正因为 0 是一个【有人做过的决定】,不是"没填"。';

-- ── (b) 预计到达 ────────────────────────────────────────────────────────────
ALTER TABLE public.containers
    ADD COLUMN expected_arrival_date date;

COMMENT ON COLUMN public.containers.expected_arrival_date IS
'LOG-5a:预计到达日。【世界那一侧的事实 —— 是某个人说过的一句话,不是算出来的】。
没有默认值,永不预填,【尤其不许由"开航日 + 航段平均天数"推出来】:那会造出一个
看起来像事实的估计,而没有人说过那句话。同一条规矩已经在 create_container 的
CONTAINER_DEPARTURE_DATE_REQUIRED 上兑现过(HINT:开航日是世界那一侧的事实,
系统无从代填),也写在 container_milestones.event_date 的列注释里:
【区别在于谁知道这件事,不在于用了哪个函数】。
可空:船期没给之前,"不知道"是一个正当状态 —— 而 container_eta_overdue
对 NULL 一支不响,那是一条【已知的局限】(与 work_order_overdue 同形)。';

-- ── (c·放宽算子)────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.arm_permission_widen(p_item_type text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- 【放宽】:持有其中任一码的读者,即便没有那一支声明的 permission,也看得见它。
    -- 与 arm_permission_any() 【方向相反】—— 那一个是【收窄】(与 permission 相与)。
    -- 两个名字很像而语义相反,所以两处注释互相点名。
    -- 免柜期是【钱】的事(滞港费),而录里程碑的人在操作侧:两边都要看得见,
    -- 而它们之间没有共同的权限码,所以只能放宽。
    SELECT CASE WHEN p_item_type = 'free_time_expiring'
                THEN ARRAY['module.purchasing.view', 'module.finance.view']
           END;
$function$;

COMMENT ON FUNCTION public.arm_permission_any(text) IS
'OPS/EXEC:某一支【额外要求】的模块码集合 —— 与那一支的 permission 【相与】,所以它只会收窄。放宽用 arm_permission_widen()(LOG-5a),两者方向相反。';

-- ── (c·四支臂)──────────────────────────────────────────────────────────────
-- 列集未变(仍是那九列),所以 CREATE OR REPLACE 够用,不必 DROP。
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
        UNION ALL
-- ═══ LOG-5a:物流的四支 ═══════════════════════════════════════════════════
-- 【四支全部排除已软删的箱子】(c.deleted_at IS NULL,逐支各写一次)。
-- 【三个阈值 2 / 14 / 7 都是写死的(v1,Tim 定)】。要把它们变成可调的那一天,
-- 现成的先例是 certificate_types.warn_lead_days —— 一张 RUNTIME CONFIG 表,
-- 每一类自带提前期【和】后果(block/warn/ignore),"加一种是编辑一行,不是跑一次迁移"。
-- 在那之前,写死的数字至少是【看得见】的:它就在这里,不在某个配置项里。

-- ── 1 · 免柜期将尽 / 已超 ────────────────────────────────────────────────
-- 【锚点是"最晚的那条 arrived"】—— 与 container_overview 的既成惯例逐字一致
-- (ORDER BY event_date DESC, recorded_at DESC LIMIT 1)。里程碑是只增不改的,
-- 所以更正的写法是【再记一条】;取最晚的那条,等于让更正自动生效:
-- 把到港日改晚一天,剩余天数就多一天,而这一支下一次被读到时自己就变了。
-- 【报价里 free_days 为 NULL 的箱子一支都不响】NULL = "这份报价没有写免柜期",
-- 与 0 =「零个免费天」是两件不同的事,而把前者当成后者会让每一个到港的箱子
-- 从第一天起就报警 —— 那是喊狼来了,而喊狼来了的告警等于没有告警。
         SELECT 'free_time_expiring'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            ((q.free_days - (CURRENT_DATE - arr.event_date))::text || ' left of '::text
              || q.free_days::text) || COALESCE(' — '::text || f.legal_name, ''::text) AS subject,
            arr.event_date AS item_date
           FROM containers c
             LEFT JOIN suppliers f ON f.id = c.forwarder_id
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'arrived'::text
                  ORDER BY m.event_date DESC, m.recorded_at DESC
                 LIMIT 1) arr ON true
             JOIN forwarder_rate_quotes q
               ON q.supplier_id = c.forwarder_id AND q.lane_id = c.lane_id
              AND q.deleted_at IS NULL
              AND c.departure_date >= q.valid_from AND c.departure_date <= q.valid_to
          WHERE c.deleted_at IS NULL
            AND q.free_days IS NOT NULL
            AND (q.free_days - (CURRENT_DATE - arr.event_date)) <= 2
        UNION ALL
-- ── 2 · 走了很久,没人说到了 ─────────────────────────────────────────────
-- 【这一支是上一支的保命companion】免柜期那一支只在【有 arrived】时才可能响;
-- 一个没人录到港的箱子,在那一支里【永远安静】,而安静与"没问题"在屏幕上
-- 长得一模一样(METAL-1 的 no_reference 那一课)。所以这一支专门说:
-- 开走 14 天了,而没有任何人说过它到了。
         SELECT 'container_no_arrival'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            dep.event_date::text AS subject,
            dep.event_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'departed'::text
                  ORDER BY m.event_date DESC, m.recorded_at DESC
                 LIMIT 1) dep ON true
          WHERE c.deleted_at IS NULL
            AND (CURRENT_DATE - dep.event_date) >= 14
            AND NOT (EXISTS ( SELECT 1 FROM container_milestones m2
                               WHERE m2.container_id = c.id AND m2.milestone = 'arrived'::text))
        UNION ALL
-- ── 3 · 说好的到港日过了,而它还没到 ─────────────────────────────────────
-- 【expected_arrival_date 为 NULL 时这一支不响】,而那是一条【已知的局限】,
-- 不是一个疏漏:与 work_order_overdue 逐字同形(它也只报"排了期而且过了期"的,
-- 并在视图里明写"放行了三个月、从没排过期该不该有别的支管"仍是开着的问题)。
-- 同一个问题在这里原样成立:一个从来没人填过 ETA 的箱子,是"没问题",
-- 还是最该被问的那一个?这一支不假装回答它。
         SELECT 'container_eta_overdue'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            c.expected_arrival_date::text AS subject,
            c.expected_arrival_date AS item_date
           FROM containers c
          WHERE c.deleted_at IS NULL
            AND c.expected_arrival_date IS NOT NULL
            AND c.expected_arrival_date < CURRENT_DATE
            AND NOT (EXISTS ( SELECT 1 FROM container_milestones m3
                               WHERE m3.container_id = c.id AND m3.milestone = 'arrived'::text))
        UNION ALL
-- ── 4 · 开走了,单据还欠着 ───────────────────────────────────────────────
-- 【锚在 departure_date】—— 它是箱子上唯一 NOT NULL 的世界侧日期,所以一定算得出来。
-- 【代价照直写】:有些单据(订舱确认、装箱单)本该在开航【之前】就到,
-- 以开航日为零点会让它们永远不迟。这一支因此不是"所有该到的单据"的告警,
-- 是"开航之后还欠着"的告警 —— 名字与它测的东西一致。
-- 【从没实例化过清单的箱子一支都不响】:pending 数为 0,这里就没有行。
-- 那种"空"与"都收齐了"在库里长得一样,而把它们分开是 5b 的事(屏幕上说清哪一种空)。
         SELECT 'container_documents_late'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            p.n::text || ' pending'::text AS subject,
            c.departure_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT count(*) AS n
                   FROM container_documents d
                  WHERE d.container_id = c.id AND d.status = 'pending'::text) p ON true
          WHERE c.deleted_at IS NULL
            AND p.n > 0
            AND (CURRENT_DATE - c.departure_date) >= 7
) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type)))
    AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));

GRANT SELECT ON public.operations_now TO authenticated;

COMMIT;
