-- db/functions/waiting_decisions.sql
-- SYSTEM-MAP-2(Tim 2026-10-26 裁定 2.4 (9) · 2026-10-27 Q1–Q7):★【在等【我】决定的单据】—— 一行一张,只列我此刻批得了的★
--
-- 【一份判据,三个读者】待办页(waiting_for_me)· 首页的待办数(waiting_for_me_count)· 提醒页的审批支(operations_now 按行过滤)。
--
-- 【"批得了"不在这里另写一遍】(SYSTEM-MAP-2 grilling,Tim 接受):
--   · 在途的是哪些:approval_pending_documents()(APR-3 那一份,采购单 · 报销 · 十种 CFO 级申请 · 调薪 · 加班);
--   · 链上的单据谁批得了:approval_deciders()(APR-ROUTE-1 R4:有资格的级别 ∩ 链的模块门 ∩ 不是自己或 R2 例外)——
--     CFO 级、1,000 的分档、四眼与自批例外全在那里,本函数只拿【我】去问它;
--   · 调薪:salary_change_deciders();
--   · 其余几种(请假 · 医疗 · 考核批准 · 加班 · 不合格 · 工单 / 配料放行 · 供应商批准 · 采集草稿 · 门户证书 · 付款):
--     门 = decision_gate_code() / review_approval_code(),四眼 = self_approval_allows()(与 forbid_self_approval 同一支)。
--   ★ 钉住"列在这里 ⇔ 那一支真的决定函数接受"的是 fixture 302(24 种 × 七个线上角色,逐格回滚),不是这段注释。
--
-- 【审批关着的时候】与各决定函数同形:blocks_disable 的链(决定函数按名拒 APPROVALS_NOT_ENABLED)谁都批不了 → 不列;
--   报销单不分档,只问链的门码与四眼(decide_expense_claim_items 关着时就是这么判的)。
-- 【分不了档的报销单(本位币金额 NULL)】决定函数按名拒(FX_RATE_MISSING)→ 谁都批不了 → 不列。
-- 【盘点不在这里】Tim 2026-10-27 Q4 (a):open 是"正在点",它留在提醒页。
-- 【付款(payment_to_pay)】一张已批准、等付款的付款申请 —— 不是一个决定,是在等财务付(Tim Q4 (c));门 = pay_payment_request 的码,
--   再加引擎里的 guard_payment_sod(建这家供应商的人不付它的款,SOD_PAYEE_AND_PAY)—— fixture 295 R 臂量出来的。
--
-- 列:item_type 种类 · item_id 单据 · parent_id 它住的那一页的主体(工资期 · 收货批 · 发票 · 销售单 · 资产 · GST 期 · 员工 ·
--   合同或公式 · 供应商;冲销凭证申请是它要冲的那张分录)· doc_kind 只在条款申请上说是 contract 还是 formula · code 单据号或标签 · subject 说的是谁 / 什么 ·
--   raised_by 提的人(trail_actor 的形状:读者没有 module.hr.view 时是 restricted,不是一个名字)· waiting_since 从什么时候起在等。
-- 【为什么 SECURITY DEFINER】它横跨十几个模块的表,而每一行是否列出由上面的判据按【调用者】(auth.uid())裁;
--   EXECUTE 给 authenticated(operations_now 是属主视图,它调用的函数按读者判 EXECUTE)。没有会话 → 零行。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.waiting_decisions()
 RETURNS TABLE(item_type text, item_id uuid, parent_id uuid, doc_kind text, code text, subject text, raised_by jsonb, waiting_since timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH s AS (
        SELECT fs.approvals_enabled AS appr_on, fs.approval_level1_role_code AS l1,
               fs.approval_level2_role_code AS l2, fs.approval_threshold_base AS thr
          FROM finance_settings fs LIMIT 1
    ),
    me AS (SELECT auth.uid() AS uid),
    pend AS (
        SELECT d.subject_type, d.doc_id, d.raiser_user_id, d.subject_employee_id, d.blocks_disable,
               CASE WHEN d.fixed_level IS NOT NULL THEN d.fixed_level
                    WHEN d.amount_base IS NULL OR s.thr IS NULL THEN NULL::smallint
                    ELSE approval_level_at(d.amount_base, s.thr) END AS lvl
          FROM approval_pending_documents() d CROSS JOIN s
    ),
    -- 链上的单据:approval_chain_gates 里有它的那几种(驳回那一支的门窄一格,不算"批得了")
    chain_ok AS (
        SELECT p.subject_type, p.doc_id
          FROM pend p CROSS JOIN s CROSS JOIN me
         WHERE me.uid IS NOT NULL
           AND EXISTS (SELECT 1 FROM approval_chain_gates() g WHERE g.subject_type = p.subject_type)
           AND CASE
                 WHEN s.appr_on THEN
                      p.lvl IS NOT NULL
                  AND EXISTS (SELECT 1
                                FROM approval_chain_gates() g
                               CROSS JOIN LATERAL approval_deciders(g.subject_type, g.action_function, g.level,
                                                                    p.raiser_user_id, p.subject_employee_id, s.l1, s.l2) x
                               WHERE g.subject_type = p.subject_type AND g.level = p.lvl
                                 AND g.action_function NOT LIKE 'reject\_%' AND x.user_id = me.uid)
                 WHEN p.blocks_disable THEN false
                 ELSE NOT EXISTS (SELECT 1
                                    FROM approval_chain_gates() g CROSS JOIN LATERAL unnest(g.gate_permissions) c(code)
                                   WHERE g.subject_type = p.subject_type AND g.action_function NOT LIKE 'reject\_%'
                                     AND NOT has_permission(c.code))
                      AND self_approval_allows(p.raiser_user_id, p.subject_employee_id, p.subject_type, me.uid)
               END
        UNION ALL
        SELECT p.subject_type, p.doc_id
          FROM pend p CROSS JOIN me
         WHERE p.subject_type = 'salary_change_request' AND me.uid IS NOT NULL
           AND EXISTS (SELECT 1 FROM salary_change_deciders(p.raiser_user_id, p.subject_employee_id) x WHERE x.user_id = me.uid)
        UNION ALL
        SELECT p.subject_type, p.doc_id
          FROM pend p CROSS JOIN me
         WHERE p.subject_type = 'overtime_batch' AND me.uid IS NOT NULL
           AND has_permission(decision_gate_code('overtime_batch'))
           AND self_approval_allows(p.raiser_user_id, NULL::uuid, 'overtime_batch', me.uid)
           AND NOT EXISTS (SELECT 1 FROM overtime_lines l WHERE l.batch_id = p.doc_id
                              AND NOT self_approval_allows(p.raiser_user_id, l.employee_id, 'overtime_batch', me.uid))
    ),
    ok AS MATERIALIZED (SELECT DISTINCT subject_type, doc_id FROM chain_ok)
    SELECT 'purchase_order'::text, po.id, NULL::uuid, NULL::text, po.code, sp.legal_name,
           trail_actor('prelog', po.created_by, NULL::uuid),
           COALESCE((SELECT max(l.decided_at) FROM approval_log l
                      WHERE l.subject_type = 'purchase_order' AND l.subject_id = po.id
                        AND l.decision IN ('submitted', 'approval_voided')), po.created_at)
      FROM purchase_orders po JOIN ok ON ok.subject_type = 'purchase_order' AND ok.doc_id = po.id
      LEFT JOIN suppliers sp ON sp.id = po.supplier_id
    UNION ALL
    SELECT 'expense_claim', c.id, NULL, NULL, c.code, e.legal_name,
           trail_actor('prelog', c.created_by, NULL::uuid), COALESCE(c.submitted_at, c.created_at)
      FROM expense_claims c JOIN ok ON ok.subject_type = 'expense_claim' AND ok.doc_id = c.id
      LEFT JOIN employees e ON e.id = c.employee_id
    UNION ALL
    SELECT 'payment_request', r.id, NULL, NULL, r.code, NULL,
           trail_actor('prelog', r.created_by, NULL::uuid), r.created_at
      FROM payment_requests r JOIN ok ON ok.subject_type = 'payment_request' AND ok.doc_id = r.id
    UNION ALL
    SELECT 'payroll_request', q.id, q.payroll_period_id, NULL, q.label, pp.code,
           trail_actor('prelog', q.created_by, NULL::uuid), q.created_at
      FROM payroll_requests q JOIN ok ON ok.subject_type = 'payroll_request' AND ok.doc_id = q.id
      JOIN payroll_periods pp ON pp.id = q.payroll_period_id
    UNION ALL
    SELECT 'receipt_price_request', rq.id, rq.inbound_batch_id, NULL, rq.label, ib.code,
           trail_actor('prelog', rq.created_by, NULL::uuid), rq.created_at
      FROM receipt_price_requests rq JOIN ok ON ok.subject_type = 'receipt_price_request' AND ok.doc_id = rq.id
      JOIN inbound_batches ib ON ib.id = rq.inbound_batch_id
    UNION ALL
    SELECT 'invoice_request', iq.id, iq.invoice_id, NULL, iq.label, inv.code,
           trail_actor('prelog', iq.created_by, NULL::uuid), iq.created_at
      FROM invoice_requests iq JOIN ok ON ok.subject_type = 'invoice_request' AND ok.doc_id = iq.id
      JOIN invoices inv ON inv.id = iq.invoice_id
    UNION ALL
    SELECT 'shipping_release', sr.id, sr.sales_order_id, NULL, sr.label, so.code,
           trail_actor('prelog', sr.created_by, NULL::uuid), sr.created_at
      FROM shipping_releases sr JOIN ok ON ok.subject_type = 'shipping_release' AND ok.doc_id = sr.id
      JOIN sales_orders so ON so.id = sr.sales_order_id
    UNION ALL
    SELECT 'journal_request', jq.id, jq.target_entry_id, NULL, jq.label, NULL,
           trail_actor('prelog', jq.created_by, NULL::uuid), jq.created_at
      FROM journal_requests jq JOIN ok ON ok.subject_type = 'journal_request' AND ok.doc_id = jq.id
    UNION ALL
    SELECT 'warehouse_request', wq.id, wq.inbound_batch_id, NULL, wq.label, NULL,
           trail_actor('prelog', wq.created_by, NULL::uuid), wq.created_at
      FROM warehouse_requests wq JOIN ok ON ok.subject_type = 'warehouse_request' AND ok.doc_id = wq.id
    UNION ALL
    SELECT 'terms_request', tq.id, COALESCE(tq.contract_id, tq.formula_id),
           CASE WHEN tq.contract_id IS NOT NULL THEN 'contract' WHEN tq.formula_id IS NOT NULL THEN 'formula' END,
           tq.label, NULL, trail_actor('prelog', tq.created_by, NULL::uuid), tq.created_at
      FROM terms_requests tq JOIN ok ON ok.subject_type = 'terms_request' AND ok.doc_id = tq.id
    UNION ALL
    SELECT 'asset_disposal_request', dq.id, dq.asset_id, NULL, dq.label, NULL,
           trail_actor('prelog', dq.created_by, NULL::uuid), dq.created_at
      FROM asset_disposal_requests dq JOIN ok ON ok.subject_type = 'asset_disposal_request' AND ok.doc_id = dq.id
    UNION ALL
    SELECT 'gst_filing_request', gq.id, gq.period_id, NULL, gq.label, NULL,
           trail_actor('prelog', gq.created_by, NULL::uuid), gq.created_at
      FROM gst_filing_requests gq JOIN ok ON ok.subject_type = 'gst_filing_request' AND ok.doc_id = gq.id
    UNION ALL
    SELECT 'salary_change_request', sq.id, sq.employee_id, NULL, sq.label, e.legal_name,
           trail_actor('prelog', sq.created_by, NULL::uuid), sq.created_at
      FROM salary_change_requests sq JOIN ok ON ok.subject_type = 'salary_change_request' AND ok.doc_id = sq.id
      LEFT JOIN employees e ON e.id = sq.employee_id
    UNION ALL
    SELECT 'overtime_batch', ob.id, NULL, NULL, ob.label, NULL,
           trail_actor('prelog', ob.submitted_by, NULL::uuid), COALESCE(ob.submitted_at, ob.created_at)
      FROM overtime_batches ob JOIN ok ON ok.subject_type = 'overtime_batch' AND ok.doc_id = ob.id
    UNION ALL
    -- 考核批准(approve_review):门 = review_approval_code(提交人, 员工),四眼两条腿
    SELECT 'performance_review', r.id, NULL, NULL, e.code, e.legal_name,
           trail_actor('prelog', r.submitted_by, NULL::uuid), COALESCE(r.submitted_at, r.created_at)
      FROM performance_reviews r CROSS JOIN me
      JOIN employees e ON e.id = r.employee_id
     WHERE r.status = 'submitted' AND me.uid IS NOT NULL
       AND has_permission(review_approval_code(r.submitted_by, r.employee_id))
       AND self_approval_allows(r.submitted_by, r.employee_id, 'performance_review', me.uid)
    UNION ALL
    SELECT 'leave_request', lr.id, NULL, NULL, lr.code, e.legal_name,
           trail_actor('prelog', lr.created_by, NULL::uuid), lr.created_at
      FROM leave_requests lr CROSS JOIN me
      LEFT JOIN employees e ON e.id = lr.employee_id
     WHERE lr.status = 'pending' AND lr.deleted_at IS NULL AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('leave_request'))
       AND self_approval_allows(lr.created_by, lr.employee_id, 'leave_request', me.uid)
    UNION ALL
    SELECT 'medical_claim', mc.id, NULL, NULL, mc.code, e.legal_name,
           trail_actor('prelog', mc.created_by, NULL::uuid), mc.created_at
      FROM medical_claims mc CROSS JOIN me
      LEFT JOIN employees e ON e.id = mc.employee_id
     WHERE mc.status = 'submitted' AND mc.deleted_at IS NULL AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('medical_claim'))
       AND self_approval_allows(mc.created_by, mc.employee_id, 'medical_claim', me.uid)
    UNION ALL
    SELECT 'ncr', n.id, NULL, NULL, n.code, NULL,
           trail_actor('prelog', n.opened_by, NULL::uuid), n.opened_at
      FROM nonconformance_reports n CROSS JOIN me
     WHERE n.status = 'open' AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('ncr'))
       AND self_approval_allows(n.opened_by, NULL::uuid, 'ncr', me.uid)
    UNION ALL
    SELECT 'work_order', wo.id, NULL, NULL, wo.code, NULL,
           trail_actor('prelog', wo.created_by, NULL::uuid), wo.created_at
      FROM work_orders wo CROSS JOIN me
     WHERE wo.status = 'draft' AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('work_order'))
       AND self_approval_allows(wo.created_by, NULL::uuid, 'work_order', me.uid)
    UNION ALL
    SELECT 'blending_plan', bp.id, NULL, NULL, bp.code, NULL,
           trail_actor('prelog', bp.created_by, NULL::uuid), bp.created_at
      FROM blending_plans bp CROSS JOIN me
     WHERE bp.status = 'draft' AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('blending_plan'))
       AND self_approval_allows(bp.created_by, NULL::uuid, 'blending_plan', me.uid)
    UNION ALL
    -- 供应商批准:等的起点 = 最近一次进入 pending_review 的那一刻(supplier_status_history)
    SELECT 'supplier', sp.id, NULL, NULL, sp.code, sp.legal_name,
           trail_actor('prelog', COALESCE(h.changed_by, sp.created_by), NULL::uuid), COALESCE(h.changed_at, sp.created_at)
      FROM suppliers sp CROSS JOIN me
      LEFT JOIN LATERAL (SELECT sh.changed_at, sh.changed_by FROM supplier_status_history sh
                          WHERE sh.supplier_id = sp.id AND sh.to_status = 'pending_review'
                          ORDER BY sh.changed_at DESC LIMIT 1) h ON true
     WHERE sp.status = 'pending_review' AND sp.deleted_at IS NULL AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('supplier'))
       AND self_approval_allows(sp.created_by, NULL::uuid, 'supplier', me.uid)
    UNION ALL
    SELECT 'capture_draft', cd.id, NULL, NULL, COALESCE(dv.code, cd.data_class), COALESCE(dv.name, cd.data_class),
           trail_actor('prelog', ib.entered_by, NULL::uuid), cd.created_at
      FROM capture_drafts cd CROSS JOIN me
      LEFT JOIN devices dv ON dv.id = cd.device_id
      LEFT JOIN ingest_inbox ib ON ib.id = cd.inbox_id
     WHERE cd.status = 'pending' AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('capture_draft'))
    UNION ALL
    SELECT 'portal_certificate', ps.id, ps.supplier_id, NULL, COALESCE(ps.cert_no, ps.cert_type_code), sp.legal_name,
           trail_actor('prelog', ps.user_id, NULL::uuid), COALESCE(ps.submitted_at, ps.created_at)
      FROM portal_certificate_submissions ps CROSS JOIN me
      JOIN suppliers sp ON sp.id = ps.supplier_id
     WHERE ps.status = 'submitted' AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('portal_certificate'))
    UNION ALL
    SELECT 'payment_to_pay', r.id, NULL, NULL, r.code, NULL,
           trail_actor('prelog', r.created_by, NULL::uuid), COALESCE(r.decided_at, r.created_at)
      FROM payment_requests r CROSS JOIN me
     WHERE r.status = 'approved' AND me.uid IS NOT NULL
       AND has_permission(decision_gate_code('payment_to_pay'))
       -- guard_payment_sod(引擎里照跑):付给供应商的出款,付款人不能是建这家供应商的人 —— 同一对判据
       --   (sod_supplier_creator + self_leg,assert_segregated 的那一句);冲销付款不受它管(payment_reversal_ctx)。
       AND NOT (r.kind = 'payment_out' AND r.counterparty_type = 'supplier'
                AND EXISTS (SELECT 1 FROM unnest(sod_supplier_creator(r.supplier_id)) a(first_actor)
                             WHERE self_leg(a.first_actor, NULL::uuid, me.uid) <> 'none'))
$function$;

COMMENT ON FUNCTION public.waiting_decisions() IS
'SYSTEM-MAP-2:在等【调用者】决定的单据,一行一张,只列他此刻批得了的。在途 = approval_pending_documents();链上的谁批得了 = approval_deciders()(CFO 级 · 1,000 分档 · 四眼 · R2 例外全在那里);调薪 = salary_change_deciders();其余几种 = decision_gate_code() / review_approval_code() + self_approval_allows()。三个读者:waiting_for_me(待办页)· waiting_for_me_count(首页)· operations_now(提醒页的审批支按行过滤)。盘点不在这里(Tim Q4 a)。已批准等付款的付款申请是 payment_to_pay(Q4 c)。fixture 302 钉住"列出 ⇔ 真的决定函数接受"。';
