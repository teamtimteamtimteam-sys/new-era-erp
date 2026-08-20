-- LOG-5d(2026-08-20):把日期改【早】的更正,此前永远不生效。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【线上复现的那一例】CTR-2026-0009:
--     arrived  event=2026-08-16  recorded=18:22:38
--     arrived  event=2026-08-14  recorded=18:25:13   ← 更正:录得更晚、日期更早
-- 每一个锚在里程碑上的读者都用 ORDER BY event_date DESC, recorded_at DESC,
-- 于是 08-16 永远排在前面 —— 那条更正【一次都没有生效过】。
--
-- 【为什么这个错特别难看见】把日期改【晚】的更正碰巧是生效的(它排到了前面),
-- 而 LOG-5a 的 fixture 102B 测的正是那个方向。于是一份绿的 fixture、
-- 一句"自愈"的宣传语、和一个只在一半方向上成立的实现,同时存在 ——
-- 【一个只覆盖一个方向的断言,读起来与一个覆盖两个方向的断言一模一样】。
--
-- 【规则】同一种里程碑之内,算数的是【最后被录入】的那一条
-- (recorded_at DESC, id DESC),它的 event_date 就是锚点。
-- 这与"只增不改"是同一句话的另一半:既然更正的唯一写法是再记一条,
-- 那么"最后写下的那条"就必须是算数的那条。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【改了哪些读者 / 没改哪些,逐条列出来】
--   改  · free_time_expiring 的 arrived 锚点      —— 它就是免柜期那口钟的零点
--   改  · container_no_arrival 的 departed 锚点   —— 它就是那口钟的零点
--   不改 · container_eta_overdue 的 arrived 判断  —— 是 NOT EXISTS,【根本没有排序】;
--          "有没有到过港"不因更正而改变,所以无处可改
--   不改 · container_no_arrival 里的 NOT EXISTS(arrived) —— 同上
--   不改 · container_overview.latest_milestone(_date) —— 那是【状态显示】
--          ("现在走到哪一步"),不是锚点;而且它【不喂任何一支臂】:四支臂各自
--          直接查 container_milestones,箱子页只从它取 lane_checklist_state,
--          列表页只拿它显示
--   不改 · 箱子页的里程碑【列表】—— 历史的陈列,按事件日读起来才顺
--
-- 列集未变,故 CREATE OR REPLACE 够用。

BEGIN;

-- ── recorded_at 必须在【事务内】也走得动 ────────────────────────────────────
-- 【这一条不是顺手加的,新规则没有它就是"确定但随意"】
-- recorded_at 的默认值是 now() = 【事务时刻】:同一个事务里插两条,时间戳一模一样,
-- 于是 ORDER BY recorded_at DESC 分不出先后,胜负落到 id DESC ——
-- 而 uuid 比大小【没有"更晚"的含义】。那样的规则是确定的,但它选的那一条是随意的。
-- 实测(scratch):同一事务两次插入,now() 得到 1 个不同值,clock_timestamp() 得到 2 个。
--
-- 【仓库里已经为同一件事做过同一个决定】stamp_allocation_basis_changed 的注释原话:
-- 「clock_timestamp() 而不是 now():事务内也要走得动,否则"分摊完之后又改了基准"
--   与"分摊时顺手改的"分不开」。这里是同一句话换了个主语。
--
-- 只改默认值,既有行一个都不动(它们的时间戳本来就是当时那个事务的时刻)。
ALTER TABLE public.container_milestones
    ALTER COLUMN recorded_at SET DEFAULT clock_timestamp();

COMMENT ON COLUMN public.container_milestones.recorded_at IS
'LOG-5d:这一行是【什么时候被录进来的】——【不是】事情发生的时间(那是 event_date)。
同一种里程碑之内,算数的是 recorded_at 最晚的那一条:更正的唯一写法是再记一条,
所以最后写下的那条就是算数的那条。默认值是 clock_timestamp() 而不是 now() ——
now() 是事务时刻,同一事务里插两条会拿到同一个值,那时"哪一条算数"就变成随意的了。';

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
-- 【锚点是"最后被【录入】的那条 arrived"】(LOG-5d 改)—— ORDER BY
-- recorded_at DESC, id DESC。**此前是 event_date DESC,那是错的**:
-- 里程碑只增不改,更正的写法是再记一条;而一条把日期改【早】的更正,
-- 在 event_date 排序下【永远排不到前面】,于是它一次都不会生效。
-- (线上实例 CTR-2026-0009:先录 arrived 08-16,再录一条更正 08-14 ——
--  所有读者仍然锚在 08-16。改晚的更正碰巧生效,改早的永远不生效。)
-- 【屏幕那一侧算的是同一件事,必须同刀改】页面为了显示剩余天数自己算了一遍
-- (app/logistics/containers/[id]/ContainerFreightPanel.tsx),口径一旦与这里分岔,
-- 屏幕写着"剩余 1 天"而看板一声不吭,且没有任何东西会报错。两处注释互相点名。
-- 【id DESC 是破平局的】recorded_at 默认 now() = 事务时刻,同一事务里插两条会一样;
-- uuid 比大小没有"更晚"的含义,但它是【确定的】—— 不确定比排错更坏。
-- 【这条规则只管"同一种里程碑里哪一条算数"】。跨类型的"现在走到哪一步"是另一个
-- 问题,仍按 event_date 排(container_overview.latest_milestone)—— 那里若改成
-- recorded_at,今天补录一条 booked 就会让箱子"退回"已订舱。
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
                  ORDER BY m.recorded_at DESC, m.id DESC
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
                  ORDER BY m.recorded_at DESC, m.id DESC
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
