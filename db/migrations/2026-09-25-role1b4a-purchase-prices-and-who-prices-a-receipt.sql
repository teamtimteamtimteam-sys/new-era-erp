-- db/migrations/2026-09-25-role1b4a-purchase-prices-and-who-prices-a-receipt.sql
-- ROLE-1 · Batch 4a —— 采购价可见性(Tim 的 Q9 线)与"看不见价格的人不能定价"(docs/role-matrix.md §8 · §13)。
-- 由 db/scripts/build_role1b4a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Batch 4 grilling Q1 · Q7 · Q9–Q12,Tim 2026-09-25 全部接受;Q13:两刀,本刀是 4a)
--   ① 两个新码:data.view_purchase_prices —— 今天持 data.view_prices 的每一个角色一并拿到它,
--      仓库只拿它;action.price_receipts —— 财务。★ 两个都一并授给 admin(Tim 的常设裁定)。
--   ② 采购那一侧的十二张遮蔽视图换码;三张定价公式视图按【行】遮(sale → view_prices,
--      purchase / both → view_purchase_prices,判据一支 pricing_formula_terms_visible);
--      batch_audit_trail 的 amount_restricted 按事件问码;ap_aging_asof · approve_purchase_order ·
--      preview_reprice_inbound_batch · calculate_metal_price(按公式方向)换码;approval_chain_gates 的
--      采购单批准两行换码;role_can_see_amounts 要两个码都有;list_ledger_reconciliation 按边问码
--      (AP → 采购码,AR 不动);po_document_data 自己按采购码置空价格(关 ROLE1-PO-DOCUMENT-DATA-PRICES)。
--      inbound_batches_masked 与 prepayment_applications_masked【一起】搬(不然 ap_open_items 会把
--      一笔被遮的预付当成 0,多报应付)。
--   ③ 收货定价归财务,而且在库里挡"看不见价格的人不能定价"(Q1 · Q4):set_inbound_unit_price ·
--      reprice_from_committed_terms 与其试算 · create_inbound_batch【带价时】要 action.price_receipts +
--      data.view_purchase_prices;引擎 reprice_inbound_batch 拆掉嵌套的 module.inbound.edit,改问
--      data.view_purchase_prices(所以应用化验也要看得见采购价)。
--   ④ 三扇侧门(Q7 (a)–(c)):price_history 的 INSERT 策略拿掉;reverse_journal_entry 按名拒 purchase
--      分录(JE_REVERSE_USE_SOURCE_PATH);reprice_inbound_batch 的 EXECUTE 从 authenticated 收回。
--
-- 【不做什么】审批开关与策略一个字都不碰;不写任何业务行;不新增审批链(收货定价审批是 Batch 4b)。
-- ★ 两刀之间(本刀上线到 4b 上线):财务定价仍一步生效、不经 CFO 批准 —— 矩阵惯常的 [LC] 过渡期。
--
-- 【RUNTIME CONFIG 的引导默认值】role_permissions 的引导【改了】:五个持 data.view_prices 的引导角色
--   (gm · finance · procurement · sales · auditor)加 data.view_purchase_prices;warehouse 加它;
--   finance 加 action.price_receipts。permissions 是逐行比对的种子:新增两行,data.view_prices 的名字与
--   描述改写(从此只说销售与成本那一侧)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少、一张不多;
-- approval_log、journal_entries、price_history、收货单一行没变;授权 = 之前 + 本刀的授权,不多不少、一条没收;
-- 持 view_prices 的角色每一个都持 view_purchase_prices;admin 持两个新码;采购单批准两级仍各有一个
-- 真的决定人;每一张在途单据都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B4A_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ('data.view_purchase_prices', 'action.price_receipts')) THEN
        RAISE EXCEPTION 'ROLE1B4A_PRE|new codes already exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'price_history'
                    AND policyname = 'price_history insert by permission') THEN
        RAISE EXCEPTION 'ROLE1B4A_PRE|price_history insert policy is not there to drop';
    END IF;
    IF to_regprocedure('public.pricing_formula_terms_visible(text)') IS NOT NULL THEN
        RAISE EXCEPTION 'ROLE1B4A_PRE|pricing_formula_terms_visible already exists';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE b4a_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved');
CREATE TEMP TABLE b4a_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log, (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM price_history) AS price_history, (SELECT count(*) FROM inbound_batches) AS receipts,
       (SELECT count(*) FROM inbound_batches WHERE unit_price IS NOT NULL) AS receipts_priced;
CREATE TEMP TABLE b4a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 目录:两个新码;data.view_prices 的名字与描述改写 ────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('data.view_purchase_prices', 'data', 'View purchase prices', '查看采购价格', 'Purchase orders and their lines, retentions and payment terms, purchase pricing formulas and committed terms, the calculator, receipt unit prices and price history, and payables ageing. Seeing a receipt price does not allow setting it.', '采购单与采购行、质保金与付款条款、采购计价公式与已承诺条款、计价器、收货单价与改价历史、应付账龄。看得见收货价不等于定得了价。', 205),
    ('action.price_receipts', 'action', 'Price and reprice goods receipts', '收货定价与改价', 'Set or change a goods receipt''s unit price — on the receipt, when creating it, or from committed terms. Every change posts to the supplier payable. Requires View purchase prices as well. Applying an assay stays with Apply assay results.', '给收货单定价或改价 —— 在收货单上、建单时,或按已承诺条款。每一次都过到供应商应付。同时要有「查看采购价格」。应用化验仍归「应用化验结果」。', 1050);
UPDATE public.permissions SET name_en = 'View sales prices & costs', name_zh = '查看销售价格与成本',
       description_en = 'Sales prices, invoices, receivables, landed cost, inventory valuation, processing cost and margin. Purchase-side prices are under View purchase prices.', description_zh = '销售价格、发票、应收、到岸成本、存货计值、加工成本与毛利。采购那一侧的价格归「查看采购价格」。'
 WHERE code = 'data.view_prices';

-- ── 2 · 授权(在函数与视图之前:下面的自证与视图都要问到它们)─────────────────
-- 今天持 data.view_prices 的每一个角色一并拿到采购码(谁都不少看一格);仓库只拿采购码。
INSERT INTO role_permissions (role_id, permission_code)
SELECT DISTINCT rp.role_id, 'data.view_purchase_prices' FROM role_permissions rp
 WHERE rp.permission_code = 'data.view_prices'
ON CONFLICT (role_id, permission_code) DO NOTHING;
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES ('warehouse', 'data.view_purchase_prices'), ('finance', 'action.price_receipts')) g(role_code, c)
    ON g.role_code = r.code
ON CONFLICT (role_id, permission_code) DO NOTHING;
-- admin:Tim 的常设裁定 —— 持每一个码,含本刀两个。幂等。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, c FROM roles r
 CROSS JOIN unnest(ARRAY['data.view_purchase_prices', 'action.price_receipts']) c
 WHERE r.code = 'admin'
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 3 · 公式条款按行遮的那一支判据(新)─────────────────────────────────────

-- db/functions/pricing_formula_terms_visible.sql
-- ROLE-1 Batch 4a(2026-09-25,Tim 的 Q9 线,grilling Q9):一条定价公式的【条款数字】(payable%、
-- TC、折扣)按【行】遮 —— 公式的 direction 说它是哪一侧的价格:
--   'sale'              → data.view_prices(销售那一侧,仓库永远拿不到)
--   'purchase' / 'both' → data.view_purchase_prices('both' 也用于采购,按采购那一侧算)
-- 【单独一支,不内联】三张公式视图与 calculate_metal_price 问的是同一句话,内联就是四份判据。
-- NULL 方向(公式不存在)按采购那一侧答 —— 调用方随后自己报"找不到"。
CREATE OR REPLACE FUNCTION public.pricing_formula_terms_visible(p_direction text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN p_direction = 'sale' THEN has_permission('data.view_prices')
                ELSE has_permission('data.view_purchase_prices') END;
$function$;

-- ── 4 · 视图(镜像原样;列不变,所以 CREATE OR REPLACE)──────────────────────

-- ─── view purchase_orders_masked
CREATE OR REPLACE VIEW public.purchase_orders_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    supplier_id,
    order_date,
    expected_delivery_date,
    currency,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN estimated_total_ccy
            ELSE NULL::numeric
        END AS estimated_total_ccy,
    status,
    approval_status,
    approved_at,
    approved_by,
    incoterm,
    terms_text,
    notes,
    closed_at,
    cancelled_at,
    cancel_reason,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    deleted_by,
    delete_reason,
    cancelled_by,
    -- CONTRACT-1:这张单据挂在哪一份合同之下。**新列加在末尾** ——
    -- CREATE OR REPLACE VIEW 只许末尾追加,中间插一列要 DROP + 重建。
    -- 【它必须出现在这张视图里】purchase_orders 是遮蔽表,而 colgrant 那道闸要求
    -- 它的每一列要么被列授权、要么在 _masked 里(WO-1a 那一课:ADD/GRANT/_masked
    -- 三件事要在同一次迁移里做完 —— KPI-1 为漏掉后两件付过一次账)。
    -- 【条款不从这一列读】它只是导航;条款读 contract_document_terms 那份副本。
    contract_id,
    -- PO-GST-1(2026-09-03):这张单的税额合计。**是钱** —— 与 estimated_total_ccy
    -- 同一扇门。净额那一列一个字节没动,含税额在读的那一侧相加(见列注释)。
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN tax_total_ccy
            ELSE NULL::numeric
        END AS tax_total_ccy,
    -- PO-GST-1-fu2:含税额 —— **屏幕读这一列,自己不做加法**。
    -- 委托 ①d 的那条要求:屏幕与 PDF 必须读同一个来源。net 与 tax 本来就是同两列,
    -- 而 gross = net + tax 这次加法若两边各写一遍,就是第二份实现。
    -- 【不落库成第三列】导出量不存;存了就会有"净额改了而它没跟上"的错数。
    -- 遮蔽自然传导:分量为 NULL 时整个表达式就是 NULL。
        CASE WHEN has_permission('data.view_purchase_prices'::text)
             THEN estimated_total_ccy + COALESCE(tax_total_ccy, 0)
             ELSE NULL::numeric END AS gross_total_ccy,
    -- 这张单【算过税吗】—— NULL 的税额合计【不是】零税:它是"开在 PO-GST-1 之前,
    -- 或开在 GST 未注册的时候"。屏幕靠它决定说哪一句话,而不是印一个 0.00。
    (tax_total_ccy IS NOT NULL) AS carries_tax,
    -- PUR-1(2026-09-08):交货地点。**新列加在末尾** —— CREATE OR REPLACE VIEW
    -- 只许末尾追加,中间插一列要 DROP + 重建(与上面 contract_id 那一条同一课)。
    -- 【不遮蔽】它是一个地址,不是钱。
    delivery_location
   FROM purchase_orders
  WHERE has_permission('module.purchasing.view'::text);

-- ─── view purchase_order_lines_masked
CREATE OR REPLACE VIEW public.purchase_order_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_id,
    line_no,
    material_id,
    quantity,
    unit,
    pricing_formula_id,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN estimated_unit_price
            ELSE NULL::numeric
        END AS estimated_unit_price,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN estimated_amount_ccy
            ELSE NULL::numeric
        END AS estimated_amount_ccy,
    expected_assay,
    notes,
    created_at,
    created_by,
    price_source,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN price_provenance
            ELSE NULL::jsonb
        END AS price_provenance,
    asset_id,
    -- PROC-1B-iii fu1:遮蔽表加一列 = 三件事(列 + 列级授权 + 本视图)。
    -- 【不遮蔽,原样透出】它是工艺路由要用的事实,不是钱、不是个人信息。
    deep_discharge_judgement_code,
    -- PO-GST-1(2026-09-03):税码与税率【不遮蔽】—— 一个是分类,一个是法定税率,
    -- 都不是钱;税【额】是钱,而且从被扣住的净额推得出来,所以随 data.view_prices,
    -- 与 estimated_amount_ccy 同一扇门。
    tax_code,
    tax_rate_pct,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN tax_amount_ccy
            ELSE NULL::numeric
        END AS tax_amount_ccy,
    -- PUR-1(2026-09-08):这一行的定价状态选择。**新列加在末尾**(同上一条)。
    -- 【不遮蔽】它是一个分类 —— 它说的是"这个价定了没有",不是那个价是多少。
    price_status
   FROM purchase_order_lines
  WHERE has_permission('module.purchasing.view'::text);

-- ─── view purchase_order_payment_terms_masked
CREATE OR REPLACE VIEW public.purchase_order_payment_terms_masked WITH (security_invoker = off) AS
SELECT id,
    purchase_order_id,
    seq,
    label,
    percentage,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN fixed_amount_ccy
            ELSE NULL::numeric
        END AS fixed_amount_ccy,
    trigger_event,
    due_date,
    notes,
    created_at,
    expected_date,
    expected_date_set_by,
    expected_date_set_at
   FROM purchase_order_payment_terms
  WHERE has_permission('module.purchasing.view'::text);

-- ─── view payment_term_template_lines_masked
CREATE OR REPLACE VIEW public.payment_term_template_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    template_id,
    seq,
    label,
    percentage,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN fixed_amount_ccy
            ELSE NULL::numeric
        END AS fixed_amount_ccy,
    trigger_event,
    days_offset,
    notes,
    created_at
   FROM payment_term_template_lines
  WHERE has_permission('module.purchasing.view'::text);

-- ─── view purchase_order_line_retentions_masked
CREATE OR REPLACE VIEW public.purchase_order_line_retentions_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_line_id,
    percentage,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN fixed_amount_ccy
            ELSE NULL::numeric
        END AS fixed_amount_ccy,
    retention_months,
    anchor_event,
    notes,
    created_at,
    created_by,
    released_at,
    released_by,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN released_amount_ccy
            ELSE NULL::numeric
        END AS released_amount_ccy,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN withheld_amount_ccy
            ELSE NULL::numeric
        END AS withheld_amount_ccy,
    withholding_reason
   FROM purchase_order_line_retentions
  WHERE has_permission('module.purchasing.view'::text);

-- ─── view purchase_order_retention_status
CREATE OR REPLACE VIEW public.purchase_order_retention_status WITH (security_invoker = off) AS
 SELECT r.id AS retention_id,
    r.purchase_order_line_id,
    pol.purchase_order_id,
    po.code AS purchase_order_code,
    po.currency,
    pol.line_no,
    fa.id AS asset_id,
    fa.code AS asset_code,
    fa.description AS asset_description,
    fa.acceptance_date,
    r.anchor_event,
    r.retention_months,
        CASE
            WHEN fa.acceptance_date IS NULL THEN NULL::date
            ELSE (fa.acceptance_date + ((r.retention_months || ' months'::text)::interval))::date
        END AS maturity_date,
        CASE
            WHEN fa.acceptance_date IS NULL THEN 'clock_not_started'::text
            WHEN r.released_at IS NOT NULL THEN 'released'::text
            WHEN (fa.acceptance_date + ((r.retention_months || ' months'::text)::interval))::date <= CURRENT_DATE THEN 'awaiting_confirmation'::text
            ELSE 'running'::text
        END AS retention_state,
    r.percentage,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN r.fixed_amount_ccy
            ELSE NULL::numeric
        END AS fixed_amount_ccy,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN COALESCE(r.fixed_amount_ccy, round(pol.estimated_amount_ccy * r.percentage / 100.0, 2))
            ELSE NULL::numeric
        END AS retention_amount_ccy,
    r.released_at,
    r.released_by,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN r.released_amount_ccy
            ELSE NULL::numeric
        END AS released_amount_ccy,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN r.withheld_amount_ccy
            ELSE NULL::numeric
        END AS withheld_amount_ccy,
    r.withholding_reason
   FROM purchase_order_line_retentions r
     JOIN purchase_order_lines pol ON pol.id = r.purchase_order_line_id
     JOIN purchase_orders po ON po.id = pol.purchase_order_id
     JOIN fixed_assets fa ON fa.id = pol.asset_id
  WHERE has_permission('module.purchasing.view'::text);

-- ─── view pricing_term_commitments_masked
CREATE OR REPLACE VIEW public.pricing_term_commitments_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_line_id,
    inbound_batch_id,
    source_formula_id,
    source_formula_code,
    source_formula_name,
    price_basis,
    average_days,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN treatment_charge_usd_per_tonne
            ELSE NULL::numeric
        END AS treatment_charge_usd_per_tonne,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN flat_discount_pct
            ELSE NULL::numeric
        END AS flat_discount_pct,
    committed_at,
    committed_by,
    price_index
   FROM pricing_term_commitments
  WHERE has_permission('module.purchasing.view'::text) OR has_permission('module.inbound.view'::text);

-- ─── view pricing_term_commitment_metals_masked
CREATE OR REPLACE VIEW public.pricing_term_commitment_metals_masked WITH (security_invoker = off) AS
 SELECT commitment_id,
    metal,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN payable_pct
            ELSE NULL::numeric
        END AS payable_pct
   FROM pricing_term_commitment_metals
  WHERE has_permission('module.purchasing.view'::text) OR has_permission('module.inbound.view'::text);

-- ─── view inbound_batches_masked
CREATE OR REPLACE VIEW public.inbound_batches_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    supplier_id,
    quantity,
    unit,
    remaining_qty,
    arrival_date,
    stage,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    purchase_order_id,
    purchase_order_line_id,
    pricing_formula_id,
    pricing_status,
    deleted_by,
    delete_reason,
    declared_qty,
    chemistry_certainty_code,
    imported,
    import_permit_ref,
    import_permit_verified_by,
    import_permit_verified_at,
    -- PROC-1B-iii fu1:遮蔽表加一列 = 三件事(列 + 列级授权 + 本视图)。
    -- 【不遮蔽,原样透出】它是工艺路由要用的事实,不是钱、不是个人信息。
    deep_discharge_actual_code,
    -- RECV-SOURCE-1:来源理由四列。【不遮蔽,原样透出】—— 审计轨迹的第一环,
    -- 不是钱、不是个人信息;colgrant 的规矩是"有 _masked 伴生,每一列都得在里面"。
    source_reason_code,
    source_reason_note,
    source_reason_recorded_by,
    source_reason_recorded_at
   FROM inbound_batches
  WHERE has_permission('module.inbound.view'::text);;

GRANT SELECT ON public.inbound_batches_masked TO authenticated;

-- ─── view inbound_batch_lookup
CREATE OR REPLACE VIEW public.inbound_batch_lookup WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    supplier_id,
    quantity,
    remaining_qty,
    unit,
    stage,
    arrival_date,
    status,
    deleted_at,
    notes,
    created_at,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price
   FROM inbound_batches b
  WHERE has_permission('module.inbound.view'::text) OR has_permission('module.purchasing.view'::text) OR has_permission('module.finance.view'::text) OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.inbound_batch_lookup IS
    'FIX-2a:进料批次的【查名】视图 —— 编号 / 物料 / 供应商 / 数量 / 阶段 / 到货日。付款、应付、库存与采购四处要把一笔金额或一行库存指回它来自哪一批。unit_price 在列上但【仍按 data.view_purchase_prices 遮】,与 inbound_batches_masked 同一条谓词 —— 本视图只改【行】谓词,不改任何一列的遮蔽。行谓词 inbound.view OR purchasing.view OR finance.view OR inventory.view。没有 pricing_formula_id / pricing_status / 进口许可 / 来源理由(notes 与 created_at 在列上,应付明细页要它们 —— 现场备注不是商务条款)。暴露面就是这张视图未遮的列清单。';

GRANT SELECT ON public.inbound_batch_lookup TO authenticated;

-- ─── view price_history_masked
CREATE OR REPLACE VIEW public.price_history_masked WITH (security_invoker = off) AS
 SELECT id,
    inbound_batch_id,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN old_unit_price
            ELSE NULL::numeric
        END AS old_unit_price,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN new_unit_price
            ELSE NULL::numeric
        END AS new_unit_price,
    currency,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN original_price
            ELSE NULL::numeric
        END AS original_price,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
    notes,
    created_at,
    created_by,
    rate_as_of,
    rate_type
   FROM price_history
  WHERE has_permission('module.inbound.view'::text);

-- ─── view prepayment_applications_masked
CREATE OR REPLACE VIEW public.prepayment_applications_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_id,
    inbound_batch_id,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    notes,
    journal_entry_id,
    created_at,
    created_by,
    expense_id,
    currency,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN amount_ccy
            ELSE NULL::numeric
        END AS amount_ccy
   FROM prepayment_applications
  WHERE has_permission('module.finance.view'::text);

-- ─── view pricing_formulas_masked
CREATE OR REPLACE VIEW public.pricing_formulas_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    name,
    direction,
    price_basis,
    average_days,
        CASE
            WHEN pricing_formula_terms_visible(direction) THEN treatment_charge_usd_per_tonne
            ELSE NULL::numeric
        END AS treatment_charge_usd_per_tonne,
        CASE
            WHEN pricing_formula_terms_visible(direction) THEN flat_discount_pct
            ELSE NULL::numeric
        END AS flat_discount_pct,
    supplier_id,
    customer_id,
    notes,
    is_active,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    price_index
   FROM pricing_formulas
  WHERE has_permission('module.pricing.view'::text);

-- ─── view pricing_formula_metals_masked
CREATE OR REPLACE VIEW public.pricing_formula_metals_masked WITH (security_invoker = off) AS
 SELECT formula_id,
    metal,
        CASE
            WHEN pricing_formula_terms_visible(( SELECT f.direction
                   FROM pricing_formulas f
                  WHERE f.id = pricing_formula_metals.formula_id)) THEN payable_pct
            ELSE NULL::numeric
        END AS payable_pct,
    created_at,
    created_by,
    updated_at,
    updated_by
   FROM pricing_formula_metals
  WHERE has_permission('module.pricing.view'::text);

-- ─── view pricing_formula_history_masked
CREATE OR REPLACE VIEW public.pricing_formula_history_masked WITH (security_invoker = off) AS
 SELECT id,
    formula_id,
    change_type,
    metal,
        CASE
            WHEN (pricing_formula_terms_visible(( SELECT f.direction
                   FROM pricing_formulas f
                  WHERE f.id = pricing_formula_history.formula_id)) AND pricing_formula_terms_visible(COALESCE(old_direction, 'both'::text)) AND pricing_formula_terms_visible(COALESCE(new_direction, 'both'::text))) THEN old_payable_pct
            ELSE NULL::numeric
        END AS old_payable_pct,
        CASE
            WHEN (pricing_formula_terms_visible(( SELECT f.direction
                   FROM pricing_formulas f
                  WHERE f.id = pricing_formula_history.formula_id)) AND pricing_formula_terms_visible(COALESCE(old_direction, 'both'::text)) AND pricing_formula_terms_visible(COALESCE(new_direction, 'both'::text))) THEN new_payable_pct
            ELSE NULL::numeric
        END AS new_payable_pct,
    old_name,
    new_name,
    old_direction,
    new_direction,
    old_price_basis,
    new_price_basis,
    old_average_days,
    new_average_days,
        CASE
            WHEN (pricing_formula_terms_visible(( SELECT f.direction
                   FROM pricing_formulas f
                  WHERE f.id = pricing_formula_history.formula_id)) AND pricing_formula_terms_visible(COALESCE(old_direction, 'both'::text)) AND pricing_formula_terms_visible(COALESCE(new_direction, 'both'::text))) THEN old_treatment_charge_usd_per_tonne
            ELSE NULL::numeric
        END AS old_treatment_charge_usd_per_tonne,
        CASE
            WHEN (pricing_formula_terms_visible(( SELECT f.direction
                   FROM pricing_formulas f
                  WHERE f.id = pricing_formula_history.formula_id)) AND pricing_formula_terms_visible(COALESCE(old_direction, 'both'::text)) AND pricing_formula_terms_visible(COALESCE(new_direction, 'both'::text))) THEN new_treatment_charge_usd_per_tonne
            ELSE NULL::numeric
        END AS new_treatment_charge_usd_per_tonne,
        CASE
            WHEN (pricing_formula_terms_visible(( SELECT f.direction
                   FROM pricing_formulas f
                  WHERE f.id = pricing_formula_history.formula_id)) AND pricing_formula_terms_visible(COALESCE(old_direction, 'both'::text)) AND pricing_formula_terms_visible(COALESCE(new_direction, 'both'::text))) THEN old_flat_discount_pct
            ELSE NULL::numeric
        END AS old_flat_discount_pct,
        CASE
            WHEN (pricing_formula_terms_visible(( SELECT f.direction
                   FROM pricing_formulas f
                  WHERE f.id = pricing_formula_history.formula_id)) AND pricing_formula_terms_visible(COALESCE(old_direction, 'both'::text)) AND pricing_formula_terms_visible(COALESCE(new_direction, 'both'::text))) THEN new_flat_discount_pct
            ELSE NULL::numeric
        END AS new_flat_discount_pct,
    old_is_active,
    new_is_active,
    changed_at,
    changed_by
   FROM pricing_formula_history
  WHERE has_permission('module.pricing.view'::text);

-- ─── view batch_audit_trail
CREATE OR REPLACE VIEW public.batch_audit_trail WITH (security_invoker = off) AS
 SELECT batch_kind,
    batch_id,
    occurred_at,
    business_date,
    event_kind,
    module_code,
    has_permission(module_code) AS may_view,
        CASE
            WHEN has_permission(module_code) THEN actor_id
            ELSE NULL::uuid
        END AS actor_id,
    actor_space,
    source_table,
        CASE
            WHEN has_permission(module_code) THEN source_id
            ELSE NULL::uuid
        END AS source_id,
        CASE
            WHEN has_permission(module_code) THEN source_code
            ELSE NULL::text
        END AS source_code,
        CASE
            WHEN has_permission(module_code) THEN href
            ELSE NULL::text
        END AS href,
        CASE
            WHEN has_permission(module_code) THEN detail
            ELSE NULL::jsonb
        END AS detail,
    (seams ||
        CASE
            WHEN ('has_masked_amount'::text = ANY (seams)) AND NOT has_permission(
                CASE
                    WHEN event_kind = 'price_change'::text THEN 'data.view_purchase_prices'::text
                    ELSE 'data.view_prices'::text
                END) THEN ARRAY['amount_restricted'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN actor_id IS NOT NULL AND NOT (EXISTS ( SELECT 1
               FROM employees e
              WHERE e.user_id = t.actor_id)) AND NOT (EXISTS ( SELECT 1
               FROM employee_accounts ea
              WHERE ea.user_id = t.actor_id)) THEN ARRAY['actor_unresolvable'::text]
            ELSE ARRAY[]::text[]
        END AS seams
   FROM batch_audit_trail_all t
  WHERE has_any_permission(ARRAY['module.inbound.view'::text, 'module.output.view'::text, 'module.inventory.view'::text, 'module.processing.view'::text, 'module.finance.view'::text, 'module.sales.view'::text, 'module.purchasing.view'::text, 'module.stocktakes.view'::text]);

COMMENT ON VIEW public.batch_audit_trail IS
    'AUDIT-1:跨模块审计轨迹,键在批次上(batch_kind + batch_id)。外层判据 = OR admission(进不进得来),逐行 may_view = 那一支自己的模块权限(这一段是内容还是「受限」)。单一 OR 判据会二选一地坏掉:泄露财务行,或让财务整段消失 —— 后者读起来是「没有分录」而真相是「你不能看」,正是 AUD-1 那个错的好消息。seams 逐行说出轨迹跟不动的那一跳;绝不省略行。';

GRANT SELECT ON public.batch_audit_trail TO authenticated;

-- ── 5 · 函数(镜像原样)──────────────────────────────────────────────────────

-- ─── calculate_metal_price
CREATE OR REPLACE FUNCTION public.calculate_metal_price(p_formula_id uuid, p_metals jsonb, p_quantity_kg numeric, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- ROLE-1 Batch 4a(grilling Q9):计价器算出的是【这条公式那一侧】的价格 —— 销售公式要
    -- data.view_prices,采购与两用公式要 data.view_purchase_prices(与三张公式视图同一条线,
    -- pricing_formula_terms_visible)。公式不存在时按采购那一侧问,随后由 _internal 报找不到。
    PERFORM require_permission(CASE WHEN (SELECT f.direction FROM pricing_formulas f WHERE f.id = p_formula_id) = 'sale'
                                    THEN 'data.view_prices' ELSE 'data.view_purchase_prices' END);
    RETURN calculate_metal_price_internal(p_formula_id, p_metals, p_quantity_kg, p_reference_date);
END;
$function$;

-- ─── approve_purchase_order
CREATE OR REPLACE FUNCTION public.approve_purchase_order(p_po_id uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po    record;
    v_base  numeric;
    v_level smallint;
BEGIN
    PERFORM require_permission('module.purchasing.view');
    -- ★★【R4:批的人必须看得见他批的那个数】★★(CHAIN-BUILD-1,2026-08-30)
    --   本函数按【金额】选级别(approval_level_for),而金额在 purchase_orders_masked /
    --   purchase_order_lines_masked 上是遮蔽列,门是 data.view_purchase_prices(ROLE-1 Batch 4a)。
    --   于是一个只持 module.purchasing.view 的人可以【打开单据、按下批准】,
    --   而屏幕上那一格写着「受限」—— 他批的是一个自己看不见的数字。
    --
    --   【为什么是"要这个权限",不是"在审批路径上解遮蔽"】(4a 的两条路,选了前者)
    --   解遮蔽会开出【第二条看价格的路】,绕过 _masked 那一套 —— 而那一套自己带着
    --   gate 的 colgrant / colreader 两条判词。多一条路 = 多一份定义,正是本仓库
    --   反复付账的那个形状。这里不发明新权限码,只是要求一个【已经存在】的。
    --
    --   【它与开关那道闸不重复,两者问的不是同一件事】
    --     · 开关时问:这个【角色】看得见金额吗(策略层面,可全知,后果是全体)
    --     · 批准时问:这个【人】看得见金额吗(个体层面,权限是多角色的并集)
    --   与 AGENTS.md「决定期间的值:控件禁用 + 服务端独立拒绝」是同一个两道闸的形状。
    PERFORM require_permission('data.view_purchase_prices');
    -- APR-2c:审批未生效时,"批准"是一个没有意义的动作 —— 单据本来就已经是 approved。
    -- 点名拒绝,而不是默默成功:后者会让人以为审批流在跑。
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    SELECT id, code, created_by, approval_status, status, currency, fx_rate, estimated_total_ccy
    INTO v_po FROM purchase_orders WHERE id = p_po_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_po_id::text, '?');
    END IF;
    IF v_po.approval_status <> 'pending' THEN
        RAISE EXCEPTION 'PO_NOT_PENDING|%|%', v_po.code, v_po.approval_status;
    END IF;

    -- 【四眼】提单的人不能自己批。与 approve_review 的 SELF_APPROVAL_FORBIDDEN 同名同理。
    -- ★ APR-ROUTE-1 Batch B(R3):按【人】认,不按账号认 —— self_leg 是那一份定义。
    --   同一个人的另一个账号提的单,这里照拒。裸码保留(APR-2 §3)。
    IF self_leg(v_po.created_by, NULL::uuid, auth.uid()) <> 'none' THEN
        RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN';
    END IF;

    -- 【本位币比,用单据自己存的汇率】(决定 3)。FIN-35 删掉了 fx_rate 的默认值,
    -- 所以一张外币单要么带着真汇率,要么根本不存在 —— 这里不必再防平价。
    v_base  := round(v_po.estimated_total_ccy * v_po.fx_rate, 2);
    v_level := approval_level_for(v_base);
    PERFORM require_approver_for(v_level);

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders
    SET approval_status = 'approved',
        approved_at = now(),
        approved_by = auth.uid(),
        -- 批准把单据从 draft 推到 confirmed;advance_po_on_receipt 仍按 confirmed 走
        status = CASE WHEN status = 'draft' THEN 'confirmed' ELSE status END,
        updated_by = auth.uid()
    WHERE id = p_po_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);


    PERFORM record_approval_decision('purchase_order', p_po_id, 'approved', v_level, p_note);

    RETURN jsonb_build_object('purchase_order_id', p_po_id, 'code', v_po.code,
                              'level', v_level, 'amount_base', v_base);
END;
$function$;

-- ─── preview_reprice_inbound_batch
CREATE OR REPLACE FUNCTION public.preview_reprice_inbound_batch(p_inbound_batch_id uuid, p_new_unit_price numeric, p_currency text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old       numeric;
    v_qty       numeric;
    v_remaining numeric;
    v_fx        numeric;
    v_fx_asof   date;
    v_base      numeric;
    v_split     jsonb;
    v_delta     numeric;
BEGIN
    PERFORM require_permission('data.view_purchase_prices');
    SELECT unit_price, quantity, remaining_qty
    INTO v_old, v_qty, v_remaining
    FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    IF p_new_unit_price IS NULL OR p_new_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;

    -- 【与 reprice_inbound_batch 逐行同构】本位币免换算;外币按【定价日】(即
    -- 提交时的 CURRENT_DATE)的 tt_sell 折算,缺牌价时用同一个 fx_rate_for 抛出
    -- 同一份 FX_RATE_MISSING|币种|日期|侧。少乘这一次就是 ASY-1 之前那个 56% 的差。
    SELECT a.rate, a.as_of INTO v_fx, v_fx_asof
    FROM fx_rate_asof(p_currency, CURRENT_DATE, 'tt_sell') a;
    IF v_fx IS NULL THEN
        PERFORM fx_rate_for(p_currency, CURRENT_DATE, 'tt_sell');
    END IF;

    v_base  := round(p_new_unit_price * v_fx, 4);
    v_split := reprice_split(v_qty, v_remaining, v_old, v_base);
    v_delta := (v_split->>'delta_usd')::numeric;

    -- 价差不为零时提交要过账 —— 过账过不去的日子,试算也不许说"可以"
    IF v_delta <> 0 THEN
        PERFORM assert_posting_allowed(CURRENT_DATE, 'purchase');
    END IF;

    RETURN jsonb_build_object(
        'old_unit_price', v_old,
        'new_unit_price', v_base,
        'delta_usd', v_delta,
        'in_stock_ratio', (v_split->>'in_stock_ratio')::numeric,
        'inventory_share_usd', (v_split->>'inventory_share_usd')::numeric,
        'cost_share_usd', (v_split->>'cost_share_usd')::numeric,
        -- 折算用的牌价与它取自哪天:屏幕上的数是怎么来的,要指得出来(FIN-21)
        'fx_rate', v_fx,
        'rate_as_of', v_fx_asof,
        'currency', p_currency
    );
END;
$function$;

-- db/functions/ap_aging_asof.sql
-- AGING-1(2026-08-27):AP 账龄【截至某一天】。
--
-- 【为什么是函数不是视图】视图接不了参数,而 ap_open_items 把 CURRENT_DATE 焊在
-- 视图体里。但"截至"不止这一层 —— 完整的四层写在函数注释与
-- db/migrations/2026-08-27-aging1-as-at-a-date.sql 的抬头里:
--   ① 视图接不了参数 ② 结清额按付款日回推 ③ 单据在那天存在不存在 ④ 金额在那天是多少
--
-- 【p_as_of 默认今天,并且【等于今天时逐行复现 ap_open_items】】
-- db/fixtures/135 的 A 臂两个方向的差集都断言为空 —— 一次悄悄改变了当前数字的
-- 重构是这里能出的最坏结果,所以它由测量钉住,不由声明保证。
--
-- 【一处刻意的分歧】单据日期晚于 D 的单据本函数不收,而 ap_open_items 的进料支
-- 没有日期过滤、会收。fixture 135 的 H 臂把它变成一条被断言的行为。
--
-- NOTE: introduced by db/migrations/2026-08-27-aging1-as-at-a-date.sql.

CREATE OR REPLACE FUNCTION public.ap_aging_asof(p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_as_of    date;
    v_today    date := CURRENT_DATE;
    v_start    date;
    v_base     text;
    v_rows     jsonb;
    v_buckets  jsonb;
    v_total    numeric;
    v_unpriced integer;
BEGIN
    -- 没有财务模块 → 【按名拒绝】,不是 0 行。两张老视图给的是 0 行
    -- (视图没有别的表达方式),而 0 行在页面上读作「没有未结单据」——
    -- 一句假话。函数有更好的表达方式,就该用。
    PERFORM require_permission('module.finance.view');

    -- 只读查询的"截至哪天",默认今天 —— 与 leave_balance / accrued_annual_leave
    -- 一族同一个惯用法,并已记在 docs/empty-string-to-rpc-audit.md 的白名单里。
    -- 【它不是那条"不许给日期默认值"的规矩的例外,是那条规矩的射程之外】:
    -- 那条管的是决定汇率、期间、金额的【写入】日期,而这里什么都不写。
    v_as_of := COALESCE(p_as_of, v_today);

    IF v_as_of > v_today THEN
        RAISE EXCEPTION 'AGING_AS_OF_FUTURE|%|%', v_as_of, v_today;
    END IF;

    SELECT fs.system_start_date INTO v_start FROM finance_settings fs LIMIT 1;
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;

    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.doc_date, x.doc_code), '[]'::jsonb)
      INTO v_rows
      FROM (
        -- ── 支一:已计价、在册的进料批次 ────────────────────────────────
        SELECT 'inbound'::text                                   AS doc_kind,
               ib.id                                             AS doc_id,
               ib.code                                           AS doc_code,
               ib.id                                             AS inbound_batch_id,
               ib.supplier_id                                    AS supplier_id,
               sup.legal_name                                    AS supplier_name,
               COALESCE(ib.arrival_date, ib.created_at::date)    AS doc_date,
               NULL::date                                        AS due_date,
               round(ib.quantity * pr.price, 2)                  AS doc_value_base,
               round(COALESCE(s.settled, 0) + COALESCE(pp.applied, 0), 2) AS settled_base,
               round(round(ib.quantity * pr.price, 2)
                     - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2) AS open_base,
               v_base                                            AS currency,
               round(round(ib.quantity * pr.price, 2)
                     - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2) AS open_ccy,
               (v_as_of - COALESCE(ib.arrival_date, ib.created_at::date))   AS days_outstanding,
               aging_bucket(v_as_of - COALESCE(ib.arrival_date, ib.created_at::date)) AS bucket,
               'supplier'::text                                  AS counterparty_kind,
               ib.supplier_id                                    AS counterparty_id,
               sup.legal_name                                    AS counterparty_name
          FROM inbound_batches_masked ib
          JOIN suppliers sup ON sup.id = ib.supplier_id
          -- 价格:D 那天的价,再套上与 inbound_batches_masked.unit_price
          -- 【逐字同源】的那道 data.view_purchase_prices 遮罩(ROLE-1 Batch 4a 起)(见抬头)。
          CROSS JOIN LATERAL (
                SELECT CASE WHEN has_permission('data.view_purchase_prices')
                            THEN inbound_unit_price_asof(ib.id, v_as_of)
                       END AS price
          ) pr
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.inbound_batch_id = ib.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                SELECT sum(ppa.amount_base) AS applied
                  FROM prepayment_applications_masked ppa
                  LEFT JOIN journal_entries je ON je.id = ppa.journal_entry_id
                 WHERE ppa.inbound_batch_id = ib.id
                   AND COALESCE(je.entry_date, ppa.created_at::date) <= v_as_of
          ) pp ON true
         WHERE (ib.deleted_at IS NULL OR ib.deleted_at::date > v_as_of)
           AND COALESCE(ib.arrival_date, ib.created_at::date) <= v_as_of
           AND pr.price IS NOT NULL

        UNION ALL

        -- ── 支二:挂账开支 ─────────────────────────────────────────────
        SELECT 'expense'::text, e.id, e.code, NULL::uuid,
               e.supplier_id, sup.legal_name,
               e.expense_date, NULL::date,
               -- AP-RECON-1:净额 + 进项税,与 ap_open_items 费用支逐字同一套(见该视图抬头)。
               e.amount_base + COALESCE(e.tax_base, 0),
               round((COALESCE(s.settled, 0) + COALESCE(pp.applied, 0)) * e.fx_rate, 2),
               CASE WHEN (COALESCE(s.settled, 0) + COALESCE(pp.applied, 0)) = 0
                    THEN e.amount_base + COALESCE(e.tax_base, 0)
                    ELSE round((e.amount_ccy + e.tax_ccy - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0)) * e.fx_rate, 2)
               END,
               e.currency,
               round(e.amount_ccy + e.tax_ccy - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2),
               (v_as_of - e.expense_date),
               aging_bucket(v_as_of - e.expense_date),
               CASE WHEN e.employee_id IS NOT NULL THEN 'employee' ELSE 'supplier' END::text,
               COALESCE(e.supplier_id, e.employee_id),
               COALESCE(sup.legal_name, emp.legal_name)
          FROM expenses e
          LEFT JOIN suppliers sup ON sup.id = e.supplier_id
          LEFT JOIN employees emp ON emp.id = e.employee_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.expense_id = e.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                SELECT sum(ppa.amount_ccy) AS applied
                  FROM prepayment_applications_masked ppa
                  LEFT JOIN journal_entries je ON je.id = ppa.journal_entry_id
                 WHERE ppa.expense_id = e.id
                   AND COALESCE(je.entry_date, ppa.created_at::date) <= v_as_of
          ) pp ON true
         WHERE e.expense_date <= v_as_of
           -- 【为什么 payment_status 这个"现在"的标志还留着,而且必须留着】
           -- 实测:EXP-2026-0002 与 EXP-2026-0005 是 payment_status='paid' 却
           -- 【一条核销行都没有】—— 它们是当场付掉的,那笔钱根本不走 allocation。
           -- 所以"已付"在这套系统里【推导不出来】,只有那个标志说得出来。
           -- 于是判据写成:今天还挂着账 【或者】 它的结清发生在 D 【之后】。
           -- D = 今天时,后半永远为假(没有晚于今天的收付款 —— 实测 0 笔),
           -- 于是它逐字退化成今天那张视图的 `payment_status='unpaid'`。
           -- 这就是"默认今天等于今天的行为"在这一支上的落点。
           AND (e.payment_status = 'unpaid'
                OR EXISTS (SELECT 1 FROM payment_allocations pa2
                             JOIN payments p2 ON p2.id = pa2.payment_id
                            WHERE pa2.expense_id = e.id AND p2.payment_date > v_as_of)
                OR EXISTS (SELECT 1 FROM prepayment_applications ppa2
                             LEFT JOIN journal_entries je2 ON je2.id = ppa2.journal_entry_id
                            WHERE ppa2.expense_id = e.id
                              AND COALESCE(je2.entry_date, ppa2.created_at::date) > v_as_of))
           -- 单据在 D 那天【站着没有】:今天 posted 的站着;今天是 reversed 的,
           -- 若那次冲销发生在 D 之后,它在 D 那天也是站着的。
           AND (e.status = 'posted'
                OR (e.status = 'reversed'
                    AND (SELECT m.expense_date FROM expenses m
                          WHERE m.id = e.reversed_by_expense) > v_as_of))
           -- 镜像行照旧排除(它是冲销的记账凭证,不是一张新的应付单)
           AND NOT EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = e.id)

        UNION ALL

        -- ── 支三:未付运费单 ───────────────────────────────────────────
        SELECT 'freight'::text, fd.id, fd.code, NULL::uuid,
               fd.supplier_id, sup.legal_name,
               fd.doc_date, NULL::date,
               fd.amount_base,
               round(COALESCE(s.settled, 0) * fd.fx_rate, 2),
               round((fd.amount_ccy - COALESCE(s.settled, 0)) * fd.fx_rate, 2),
               fd.currency,
               round(fd.amount_ccy - COALESCE(s.settled, 0), 2),
               (v_as_of - fd.doc_date),
               aging_bucket(v_as_of - fd.doc_date),
               'supplier'::text, fd.supplier_id, sup.legal_name
          FROM freight_documents fd
          JOIN suppliers sup ON sup.id = fd.supplier_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.freight_document_id = fd.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
         WHERE fd.doc_date <= v_as_of
           AND (fd.deleted_at IS NULL OR fd.deleted_at::date > v_as_of)
           AND (fd.payment_status = 'unpaid'
                OR EXISTS (SELECT 1 FROM payment_allocations pa2
                             JOIN payments p2 ON p2.id = pa2.payment_id
                            WHERE pa2.freight_document_id = fd.id AND p2.payment_date > v_as_of))
           -- 运费单的冲销日:优先取【冲销分录的分录日】(那是业务日),
           -- 取不到才退回 reversed_at 的录入时刻。与 reverse_freight_document
           -- 用 CURRENT_DATE 立那张冲销分录逐字对应。
           AND (fd.status = 'posted'
                OR (fd.status = 'reversed'
                    AND COALESCE((SELECT je.entry_date FROM journal_entries je
                                   WHERE je.id = fd.reversal_entry_id),
                                 fd.reversed_at::date) > v_as_of))
      ) x
     WHERE x.open_ccy > 0;

    -- 档位合计:四档【一档不落】,没有的那一档是 0 而不是缺席 ——
    -- 一个缺席的键在页面上会渲染成空白,读起来像"没算出来"。
    SELECT jsonb_object_agg(b.bucket, COALESCE(agg.total, 0))
      INTO v_buckets
      FROM (VALUES ('b0_30'), ('b31_60'), ('b61_90'), ('b90_plus')) AS b(bucket)
      LEFT JOIN LATERAL (
            SELECT round(sum((e->>'open_base')::numeric), 2) AS total
              FROM jsonb_array_elements(v_rows) e
             WHERE e->>'bucket' = b.bucket
      ) agg ON true;

    SELECT COALESCE(round(sum((e->>'open_base')::numeric), 2), 0)
      INTO v_total FROM jsonb_array_elements(v_rows) e;

    -- 【被"那天还没有价"挡掉的批次有几张】—— 一个缺席要说得出数目,
    -- 否则它与"本来就没有这笔应付"在屏幕上长得一模一样。
    -- 没有 data.view_purchase_prices 时这个数是 NULL 而不是 0:那不是"零张",
    -- 是"你看不到这一栏",与价格本身遮成 NULL 同一个道理。
    IF has_permission('data.view_purchase_prices') THEN
        SELECT count(*) INTO v_unpriced
          FROM inbound_batches ib
         WHERE (ib.deleted_at IS NULL OR ib.deleted_at::date > v_as_of)
           AND COALESCE(ib.arrival_date, ib.created_at::date) <= v_as_of
           AND inbound_unit_price_asof(ib.id, v_as_of) IS NULL;
    ELSE
        v_unpriced := NULL;
    END IF;

    RETURN jsonb_build_object(
        'side',                'ap',
        'as_of',               v_as_of,
        'today',               v_today,
        'is_past',             (v_as_of < v_today),
        'system_start_date',   v_start,
        'before_system_start', (v_start IS NOT NULL AND v_as_of < v_start),
        'base_currency',       v_base,
        -- 机器令牌,不是给人读的句子 —— 双语措辞留在 messages/,按语言选一条。
        'amount_basis',        'quantity_now_price_asof',
        'unpriced_excluded',   v_unpriced,
        'total_open_base',     v_total,
        'buckets',             v_buckets,
        'rows',                v_rows
    );
END;
$function$;

COMMENT ON FUNCTION public.ap_aging_asof(date) IS
    'AGING-1:AP 账龄【截至某一天】。视图接不了参数,而"截至"有四层而不是一层:① CURRENT_DATE 焊在视图体里;② 结清额要按付款日回推(晚于 D 的付款不算);③ 单据在 D 那天站着没有(D 之后的冲销/删除不回溯);④ 金额在 D 那天是多少(单价按 price_history 回推 —— 实测 2026-07-05 之前九张在开批次全部无价)。数量没有历史表,所以金额 = 今天的数量 × D 那天的价,由 amount_basis 明说。未来日期按名拒 AGING_AS_OF_FUTURE。截止日早于 system_start_date 不拒绝,返回 before_system_start 由页面与 CSV 各说一句(方向是把欠款报多)。p_as_of 默认今天,且【等于今天时逐行复现今天那张视图】—— db/fixtures/135 的 A 臂钉住。';

-- db/functions/approval_chain_gates.sql
-- APR-2:【哪些链接上了 require_approver_for,以及那条链自己的门是什么】
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ 它存在的理由,是一个【实测出来的、当时活在线上的】死锁 ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- `require_approver_for(N)` 问的是「你在不在第 N 级那个【角色】里」。
-- 而每一支决定函数【另外】问一句「你持不持有本模块的那个【权限码】」。
-- ★ 在 APR-2 之前,【没有任何东西断言这两个集合有交集】。
--
-- 实测(2026-09-22,以 postgres 读 user_roles / role_permissions / auth.users 基表,
-- 以及 require_approver_for 自己的答案):
--
--   一级 = finance = chooer@evoltrya.test  —— 他【不】持 module.processing.edit
--   二级 = cfo     = admin@swm-os.test
--
--   | 链           | 模块门                              | 持有人                  | ∩ 一级 |
--   |--------------|-------------------------------------|-------------------------|--------|
--   | 采购单       | purchasing.view + data.view_prices  | admin chooer phua sandra vince | chooer ✓ |
--   | ★ 工单       | processing.edit                     | admin phua sandra vince | ★ 空   |
--
-- ☞ 也就是说:**审批一打开,线上就没有任何人放行得了一张工单** ——
--   而 WO-1b 把那一行 require_approver_for(1) 写下去的时候,三道闸全绿。
--   今天 work_orders 里 draft = 0,所以没有单据卡住;下一张就再也放行不了。
--   ★ APR-2 的处置是把工单从这台引擎的【路由】那一半摘下来(Tim 的 Q1 裁定:
--     按角色分级只管【带钱的单据】),于是 APR-2 结束时本表只剩采购单两支。
-- ★ APR-3(2026-09-22)加进报销单两行 —— 本仓库第二条接上按角色分级的链。
-- ★ PAY-REQ-1(2026-09-23)加进付款申请【一行】(只有二级:CFO 批每一张)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这是一张手写的名册,所以它必须被核对,不能被相信】
-- ════════════════════════════════════════════════════════════════════════════
-- 一张与代码分开维护的清单,迟早与代码漂开,而漂开的那一刻它仍然全绿。
-- 所以 db/fixtures/203 有一条【目录派生】的断言:
--     SELECT proname FROM pg_proc WHERE prosrc LIKE '%require_approver_for%'
-- 那个集合必须与本函数的 action_function 列【逐字相等】。
-- ☞ 加一条链接上 require_approver_for,就要在这里加一行,否则 fixture 当场变红。
--
-- 【为什么门是一个数组,不是一个码】approve_purchase_order 要【两个】:
-- module.purchasing.view(进得了模块)+ data.view_prices(看得见他要批的那个数,
-- R4)。而 reject_purchase_order 只要前一个 —— 驳回不需要看见金额。
-- **两支函数的门不一样,所以它们各占一行,不合并。**
--
-- 【为什么不是 SECURITY DEFINER】它是一张常量表,不读任何东西。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr2-self-approval-and-the-approver-that-nobody-is.sql.

CREATE OR REPLACE FUNCTION public.approval_chain_gates()
 RETURNS TABLE(subject_type text, action_function text, level smallint, gate_permissions text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT v.subject_type, v.action_function, v.level, v.gate_permissions
      FROM (VALUES
        ('purchase_order'::text, 'approve_purchase_order'::text, 1::smallint,
            ARRAY['module.purchasing.view', 'data.view_purchase_prices']::text[]),
        ('purchase_order'::text, 'approve_purchase_order'::text, 2::smallint,
            ARRAY['module.purchasing.view', 'data.view_purchase_prices']::text[]),
        -- ★ ROLE-1 Batch 4a(2026-09-25):采购单的金额是【采购那一侧】的价格 —— 批准的门换成
        --   data.view_purchase_prices(今天持 view_prices 的每一个角色一并拿到它)。报销单与付款申请不动。
        -- 驳回【不】要 data.view_prices —— 它仍然按金额分级(所以两级都在),
        -- 而它不显示那个金额。门窄一格,所以它自己一行。
        ('purchase_order'::text, 'reject_purchase_order'::text, 1::smallint,
            ARRAY['module.purchasing.view']::text[]),
        ('purchase_order'::text, 'reject_purchase_order'::text, 2::smallint,
            ARRAY['module.purchasing.view']::text[]),
        -- ★★ APR-3(Tim 的 Q1):报销单。门是【module.finance.view + data.view_prices】,
        --    【不是】module.finance.edit —— 采购单那条链的形状,原样照搬。
        --    两条理由,都在 docs/approvals.md §0 与 §5 里已经成立:
        --    ① 批的人不该是提得了这张单的人(edit 就是提单的那个码);
        --    ② R4:批的人必须看得见他批的那个数,而这条链【按金额分档】。
        --    ★ 实测的第三条,也是决定性的那条:cfo 持 module.finance.view 与
        --      data.view_prices,【不持】module.finance.edit。写成 edit 的话,
        --      今天二级之所以还有一个人,靠的只是 cfo 的唯一真持有人就是 admin
        --      账号(§0b 记着的那次撞车)—— Tim 一拿到独立的 CFO 账号、把 cfo
        --      从 admin 上收回,二级当场归零,而那一天没有任何东西会说是这一刀
        --      造成的。写成 view + prices,那一天它仍然是 1。
        --    【approve 与 reject 不分两行】与采购单不同:本链两支分支【都】分档
        --    (驳回也落一行带 level 的留痕),所以两边都要看得见金额,门一样宽。
        ('expense_claim'::text, 'decide_expense_claim'::text, 1::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[]),
        ('expense_claim'::text, 'decide_expense_claim'::text, 2::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[]),
        -- ★★ PAY-REQ-1(Tim 的矩阵:付款与冲销付款,CFO 批每一张,不分档):
        --    【只有二级这一行】。decide_payment_request 直接要二级审批人(不按金额分档),
        --    (★ 这句注释【不写】那支函数的名字:203E 按 prosrc 数它的调用方,注释也算。)
        --    从不经 approval_level_for —— 所以一级那一行不存在,而不是"门一样宽所以省了"。
        --    门与报销单同一对码,理由同上(提单的码是 edit;R4 要看得见金额)。
        ('payment_request'::text, 'decide_payment_request'::text, 2::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[]),
        -- ★★ PAYROLL-APR-1(Tim 的矩阵:工资过账与撤销,CFO 批每一张,不分档):同样【只有二级
        --    这一行】,理由与付款申请逐字同一条。门是 module.hr.view + data.view_pay(Tim 的 Q8)——
        --    工资期页的门,加上看得见工资数的那个码(§5:批的人必须看得见他批的那个数);
        --    【不是】module.hr.edit:那是提单的码。
        ('payroll_request'::text, 'decide_payroll_request'::text, 2::smallint,
            ARRAY['module.hr.view', 'data.view_pay']::text[])
      ) AS v(subject_type, action_function, level, gate_permissions)
$function$;

COMMENT ON FUNCTION public.approval_chain_gates() IS
'APR-2(APR-3 加进报销单两行):接上了 require_approver_for 的链,以及每一支动作【自己的】模块门(可能是几个码的合取)。★ 它存在是因为 WO-1b 实测在线上造出过一个死锁:一级审批角色 finance 的唯一真持有人不持 module.processing.edit,于是审批一开,工单谁都放行不了,而三道闸全绿。这张名册是手写的,所以 db/fixtures/203 有一条目录派生的断言钉住它与 pg_proc 里真正调用 require_approver_for 的那组函数逐字相等 —— 加一条链就要在这里加一行。★ APR-3 的报销单两行取的门是 module.finance.view + data.view_prices,【不是】module.finance.edit —— 写成 edit 的话,今天二级还有一个人靠的只是 cfo 的唯一真持有人就是 admin 账号(§0b 那次撞车),而独立 CFO 账号一落地它就归零。';

-- db/functions/role_can_see_amounts.sql
-- CHAIN-BUILD-1(R4):这个【角色】看得见金额吗 —— 即它有没有 data.view_prices。
--
-- 【为什么这是一个真问题】采购单的金额在 purchase_orders_masked /
--   purchase_order_lines_masked 上是遮蔽列,而审批【按金额选级别】。
--   一个只持 module.purchasing.view 的审批人打得开单据、按得下批准,
--   而金额那一格写着「受限」—— 他批的是一个自己看不见的数字。
--
-- ★ ROLE-1 Batch 4a(2026-09-25,grilling Q11):价格码拆成两个 —— 采购单的金额按
--   data.view_purchase_prices 遮,报销单与付款申请的金额按 data.view_prices。审批的两级是【所有】
--   链共用的,所以一个角色要【两个码都有】才算看得见它要批的金额。
-- 【单独一支,不内联】开关那道闸与就绪面板两处问同一句话,内联就是两份判据。
CREATE OR REPLACE FUNCTION public.role_can_see_amounts(p_role_code text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM roles r
          JOIN role_permissions rp ON rp.role_id = r.id
         WHERE r.code = p_role_code
           AND r.is_active
           AND rp.permission_code = 'data.view_prices')
       AND EXISTS (
        SELECT 1 FROM roles r
          JOIN role_permissions rp ON rp.role_id = r.id
         WHERE r.code = p_role_code
           AND r.is_active
           AND rp.permission_code = 'data.view_purchase_prices');
$function$;

COMMENT ON FUNCTION public.role_can_see_amounts(text) IS
'CHAIN-BUILD-1(R4):这个角色看得见金额吗 —— 即它有没有 data.view_prices【与】data.view_purchase_prices(ROLE-1 Batch 4a 起价格码分两侧,而审批的两级是所有链共用的)。采购单的金额在 purchase_orders_masked / purchase_order_lines_masked 上是遮蔽列,而审批【按金额选级别】,所以一个看不见金额的角色批的是自己看不见的数字。开关时用它按名拒(策略层面,可全知);批准时另有一道问【这个人】的检查(个体层面,权限是多角色的并集)—— 两者问的不是同一件事,不是重复。';

-- db/functions/list_ledger_reconciliation.sql
-- AP-RECON-1 Batch B(2026-09-24):清单与总账的常设勾稽 —— 应付清单 ↔ 2000,应收清单 ↔ 1100。
--
-- 【它问的是一个问题,而且只问这一个】此刻清单上说欠的,与总账科目上记的,差多少;
-- 那一笔差里每一分钱有没有名字。
--   · 清单 = ap_open_items / ar_open_items 的 Σ open_base —— 应付页、应收页、付款表单
--     预填的都是它。
--   · 总账 = 控制科目【全账】余额(journal_lines,不截日、不按 status 过滤 ——
--     冲销对的两条腿都在,全时段净额为 0;FRT-2027-* 那三对因此自己抵掉)。
--
-- 【允许的差只有三种,一种也不多】(Tim AP-RECON-1 Q6 / Q8–Q10;Batch B Q1–Q2)
--   1. residue    —— list_ledger_residue 里逐单据登记的已知残留(只有迁移能写;
--                    重建库上为空)。每行带理由与 known-wrong 引用。
--   2. revaluation —— 控制科目上 source_type = 'revaluation' 的分录行,【算出来】的、
--                    有名字的一行。清单按单据入账汇率计,不重估;总账重估。两者差的
--                    就是这一行,它有自己的金额,不藏在别处。
--   3. on_account —— 挂账的收付款(没有核销到任何单据上的那部分):
--                    付款币种的 amount_ccy − Σ(allocated_pay − withheld_pay),按付款汇率
--                    折本位币 —— 与 record_payment_internal 过 v_unalloc_base 的式子同式。
--                    ★ 冲销对【两边都不算】:被冲销的原件(status = 'reversed')与冲销件
--                    (被别人的 reversed_by_payment 指着)都不是挂账的钱。不排除的话,
--                    冲销件没有核销行,会整笔读成挂账 —— 线上实测会凭空多出 4,866.08。
-- 其余一律进 unexplained_base。**没有兜底桶** —— gl_control_reconciliation 抬头那一段
-- 说的是同一件事:一个永远为 0 的判词是装饰,不是检查。
--
-- 【符号约定】每一个具名项的金额都是它对"清单 − 总账"(gap_base)的贡献:
--   unexplained_base = gap_base − residue_base − revaluation_base − on_account_base。
--   总账侧统一成"正数 = 还欠着的钱"(AR = 借 − 贷,AP = 贷 − 借)。
--
-- 【与 gl_control_reconciliation 的分工】那一支按【机制】分类(起单/结算/重估)、截在
-- as-of 日,冻在管理包里的包读它的三个键 —— 它的签名与键不动(Q8),它的抬头已改正:
-- 它的"起单差异"会把缺陷一起吸进去(AP-RECON-1 §3)。本函数按【已知残留】分类,
-- 不截日,不吸任何东西。
--
-- 【两道门】module.finance.view(require_permission);清单的金额还要看得见那一侧的价格 ——
-- AP 要 data.view_purchase_prices、AR 要 data.view_prices(ROLE-1 Batch 4a 起按边分开)——
-- 进料批、销售记录与发票的价格列都是遮蔽的,没有这个码的人读到的清单是残缺的,
-- 拿它去减总账会得到一个自信的假"未解释"。所以此时两边都【按名拒】:
-- refusal = 'PRICES_RESTRICTED',数字为 NULL —— 答不上来不是对不上。
--
-- 月结页(/finance/month-end)有一步读它,每一边一个未解释数;它【不】挡 close_period
-- (Q11:挡不挡关账是以后的决定)。明细页:/finance/list-vs-ledger。
-- 行为断言:db/fixtures/213-the-list-and-the-ledger-agree-and-a-difference-has-a-name.sql
--
-- NOTE: introduced by db/migrations/2026-09-24-aprecon1b-the-list-and-the-ledger-agree.sql.
CREATE OR REPLACE FUNCTION public.list_ledger_reconciliation()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_sides     jsonb := '[]'::jsonb;
    v_side      text;
    v_acct      text;
    v_list      numeric;
    v_rows      integer;
    v_ledger    numeric;
    v_reval     numeric;
    v_onacc     numeric;
    v_onacc_rows jsonb;
    v_res       numeric;
    v_res_rows  jsonb;
    v_gap       numeric;
    v_unexp     numeric;
BEGIN
    -- 【SECURITY DEFINER 必须自己问调用者是谁】
    PERFORM require_permission('module.finance.view');

    FOREACH v_side IN ARRAY ARRAY['ap', 'ar'] LOOP
        v_acct := CASE WHEN v_side = 'ap' THEN '2000' ELSE '1100' END;

        -- ★ ROLE-1 Batch 4a(grilling Q11):每一边问【它自己那一侧】的价格码 —— AP 清单的金额只经
        --   inbound_batches_masked 与 prepayment_applications_masked 遮(两张一起搬到了
        --   data.view_purchase_prices);AR 清单仍按 data.view_prices 遮。
        IF NOT has_permission(CASE WHEN v_side = 'ap' THEN 'data.view_purchase_prices'
                                   ELSE 'data.view_prices' END) THEN
            v_sides := v_sides || jsonb_build_object(
                'side', v_side, 'control_account', v_acct,
                'refusal', 'PRICES_RESTRICTED',
                'list_base', NULL, 'list_rows', NULL, 'ledger_base', NULL, 'gap_base', NULL,
                'residue', '[]'::jsonb, 'residue_base', NULL,
                'revaluation_base', NULL, 'on_account', '[]'::jsonb, 'on_account_base', NULL,
                'unexplained_base', NULL, 'agrees', NULL);
            CONTINUE;
        END IF;

        -- ── 清单 ──────────────────────────────────────────────────────────
        IF v_side = 'ap' THEN
            SELECT count(*), COALESCE(sum(open_base), 0) INTO v_rows, v_list FROM ap_open_items;
        ELSE
            SELECT count(*), COALESCE(sum(open_base), 0) INTO v_rows, v_list FROM ar_open_items;
        END IF;

        -- ── 总账:全账,不截日,不按 status 过滤 ─────────────────────────────
        SELECT COALESCE(sum(CASE WHEN v_side = 'ar' THEN jl.debit - jl.credit
                                 ELSE jl.credit - jl.debit END), 0)
          INTO v_ledger
          FROM journal_lines jl
          JOIN accounts a ON a.id = jl.account_id
         WHERE a.code = v_acct;

        -- ── 具名项 2:重估(总账侧的数;它对 gap 的贡献是它的相反数)─────────
        SELECT COALESCE(sum(CASE WHEN v_side = 'ar' THEN jl.debit - jl.credit
                                 ELSE jl.credit - jl.debit END), 0)
          INTO v_reval
          FROM journal_lines jl
          JOIN accounts a ON a.id = jl.account_id
          JOIN journal_entries je ON je.id = jl.entry_id
         WHERE a.code = v_acct AND je.source_type = 'revaluation';

        -- ── 具名项 3:挂账的收付款,冲销对两边都不算 ─────────────────────────
        SELECT COALESCE(sum(u.base), 0),
               COALESCE(jsonb_agg(jsonb_build_object('code', u.code, 'amount_base', u.base)
                                  ORDER BY u.code), '[]'::jsonb)
          INTO v_onacc, v_onacc_rows
          FROM (SELECT p.code,
                       round(round(p.amount_ccy - COALESCE(
                           (SELECT sum(pa.allocated_pay - pa.withheld_pay)
                              FROM payment_allocations pa
                             WHERE pa.payment_id = p.id), 0), 2) * p.fx_rate, 2) AS base
                  FROM payments p
                 WHERE p.direction = CASE WHEN v_side = 'ap' THEN 'out' ELSE 'in' END
                   AND p.status = 'posted'
                   AND NOT EXISTS (SELECT 1 FROM payments o WHERE o.reversed_by_payment = p.id)) u
         WHERE u.base <> 0;

        -- ── 具名项 1:登记的残留 ────────────────────────────────────────────
        SELECT COALESCE(sum(r.amount_base), 0),
               COALESCE(jsonb_agg(jsonb_build_object(
                   'doc_code', r.doc_code, 'amount_base', r.amount_base,
                   'residue_class', r.residue_class, 'reason', r.reason,
                   'known_wrong_ref', r.known_wrong_ref) ORDER BY r.doc_code), '[]'::jsonb)
          INTO v_res, v_res_rows
          FROM list_ledger_residue r
         WHERE r.side = v_side;

        v_gap   := round(v_list - v_ledger, 2);
        -- ★【没有兜底桶】★ 只扣这三项。
        v_unexp := round(v_gap - v_res - (-v_reval) - v_onacc, 2);

        v_sides := v_sides || jsonb_build_object(
            'side',             v_side,
            'control_account',  v_acct,
            'refusal',          NULL,
            'list_base',        round(v_list, 2),
            'list_rows',        v_rows,
            'ledger_base',      round(v_ledger, 2),
            'gap_base',         v_gap,
            'residue',          v_res_rows,
            'residue_base',     round(v_res, 2),
            'revaluation_base', round(-v_reval, 2),
            'on_account',       v_onacc_rows,
            'on_account_base',  round(v_onacc, 2),
            'unexplained_base', v_unexp,
            'agrees',           (v_unexp = 0));
    END LOOP;

    RETURN jsonb_build_object(
        'base_currency', base_currency_code(),
        'sides',         v_sides);
END;
$function$
;

-- ─── po_document_data
CREATE OR REPLACE FUNCTION public.po_document_data(p_po_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po   record;
    v_sup  record;
    v_lines jsonb;
    v_terms jsonb;
    -- PUR-1:这张单挂在哪一份合同之下 —— 读的是【抄下来的那一份】。
    v_contract_code text;
    -- ★ ROLE-1 Batch 4a(2026-09-25,关掉 ROLE1-PO-DOCUMENT-DATA-PRICES):本函数以属主权限读【基表】,
    --   所以遮蔽视图挡不住它 —— 价格在这里自己按 data.view_purchase_prices 置空(NULL = 受限,
    --   不是 0;prices_visible 说出来是哪一种)。定价【状态】不是价格,照印。
    v_see  boolean := has_permission('data.view_purchase_prices');
BEGIN
    PERFORM require_permission('module.purchasing.view');

    SELECT po.id, po.code, po.order_date, po.expected_delivery_date, po.currency,
           po.status, po.approval_status, po.incoterm, po.terms_text, po.notes,
           po.estimated_total_ccy, po.tax_total_ccy, po.supplier_id,
           -- PUR-1:交货地点(自由文本,可空)
           po.delivery_location
    INTO v_po FROM purchase_orders po
    WHERE po.id = p_po_id AND po.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_po_id::text, '?');
    END IF;

    SELECT s.legal_name, s.address, s.country, s.tax_id
    INTO v_sup FROM suppliers s WHERE s.id = v_po.supplier_id;

    -- ── PUR-1:参照合同号 ────────────────────────────────────────────────────
    -- ★★【读 contract_document_terms,【不】读 contracts】★★
    --   contract_document_terms 的表注写得很死:purchase_orders.contract_id 只回答
    --   "挂在哪一份合同上",**任何读取路径都不许拿它回查条款内容** —— 一旦那么写,
    --   "抄"就静悄悄退化成了"引用"。合同编号【就是被抄下来的字段之一】
    --   (contract_code,NOT NULL),所以这里读副本,而不是顺着外键回查。
    --   后果是具体的:合同日后改了编号,这张【已经开出去的】单上印的仍是当时那个 ——
    --   而那正是供应商手里那张纸上写着的东西。
    -- 【没挂合同就是 NULL】PDF 那一侧据此【整块不印】,不印一个空标签。
    SELECT t.contract_code INTO v_contract_code
      FROM contract_document_terms t WHERE t.purchase_order_id = p_po_id;

    -- ── 逐行:定价状态在这里裁决,PDF 只负责画(docs/purchase-order-document.md §B)──
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'line_no', l.line_no,
        'material_name', COALESCE(m.name, fa.description),
        'quantity', l.quantity,
        'unit', l.unit,
        'unit_price', CASE WHEN v_see THEN l.estimated_unit_price END,          -- 单据币种;可空
        'amount_ccy', CASE WHEN v_see THEN l.estimated_amount_ccy END,
        -- PO-GST-1:行上的税 —— 供应商手里那张纸要逐行看得见它。
        'tax_code', l.tax_code,
        'tax_rate_pct', l.tax_rate_pct,
        'tax_amount_ccy', CASE WHEN v_see THEN l.tax_amount_ccy END,
        'expected_assay', l.expected_assay,
        'notes', l.notes,
        -- 【FIN-26 的那次误读,在这里终结】价格是不是手填的【估算】是记录下来的
        -- 事实(price_source),不是从公式在不在推断的
        'price_is_manual_estimate', (l.price_source = 'manual' AND c.id IS NOT NULL),
        'pricing_status', CASE
            WHEN c.id IS NOT NULL                 THEN 'provisional_committed'
            -- 公式挂着、条款没抄下来(FIN-27 之前的旧行):【不印公式今天的条款】——
            -- 那是编造一份承诺,known-wrong 里写明这些行走手工结算
            WHEN l.pricing_formula_id IS NOT NULL THEN 'provisional_uncommitted'
            -- ★★【PUR-1:存下来的那个选择排在这里,而位置就是判据】★★
            --   上面两支(有承诺 / 挂公式)是【事实】,这一支是【选择】——
            --   事实排在选择前面,于是一行按公式结算的料【印不出 FIXED】,
            --   哪怕它的 price_status 不知怎么被写成了 'fixed'。
            --   写入那一侧已经按名拒了(guard_po_line_price_status),
            --   而这里是第二道:**一道闸能被绕过的时候,第二道不是冗余**
            --   (比这道闸更老的行、以及将来任何一条新的写入路径)。
            --   反方向【是允许的】:一行没有公式、被人标成 provisional,
            --   就印暂定价 —— 那是真话,也正是本刀补上的那个能力。
            WHEN l.price_status = 'provisional'   THEN 'provisional_uncommitted'
            WHEN l.estimated_unit_price IS NOT NULL THEN 'fixed'
            -- 【标成 fixed 却一个价都没有】仍然是 not_priced —— 纸上不能说
            -- "价格已定"而那一栏是一横。选择改变不了"没有数字"这件事。
            ELSE 'not_priced'
        END,
        'committed_terms', CASE WHEN c.id IS NOT NULL THEN jsonb_build_object(
            'source_formula_code', c.source_formula_code,
            'source_formula_name', c.source_formula_name,
            'price_basis', c.price_basis,
            'average_days', c.average_days,
            'treatment_charge_usd_per_tonne', CASE WHEN v_see THEN c.treatment_charge_usd_per_tonne END,
            'flat_discount_pct', CASE WHEN v_see THEN c.flat_discount_pct END,
            'metals', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                           'metal', cm.metal, 'payable_pct', CASE WHEN v_see THEN cm.payable_pct END)
                           ORDER BY cm.metal), '[]'::jsonb)
                       FROM pricing_term_commitment_metals cm
                       WHERE cm.commitment_id = c.id)
        ) END
    ) ORDER BY l.line_no), '[]'::jsonb)
    INTO v_lines
    FROM purchase_order_lines l
    -- EQP-1a:【INNER → LEFT】原先是 JOIN materials —— 设备行会从【打印出来的
    -- 采购单】上整行消失,而单据其余部分照常成立:没有错误、没有空行,
    -- 只是那台机器不在发给供应商的纸上。
    LEFT JOIN materials m ON m.id = l.material_id
    LEFT JOIN fixed_assets fa ON fa.id = l.asset_id
    LEFT JOIN pricing_term_commitments c ON c.purchase_order_line_id = l.id
    WHERE l.purchase_order_id = p_po_id;

    -- ── 付款计划(FIN-29 的承诺分期,原样印)────────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'seq', t.seq, 'label', t.label, 'percentage', t.percentage,
        'fixed_amount_ccy', CASE WHEN v_see THEN t.fixed_amount_ccy END,
        'trigger_event', t.trigger_event, 'trigger_phrase', pte.phrase_en,
        'due_date', t.due_date, 'notes', t.notes
    ) ORDER BY t.seq), '[]'::jsonb)
    INTO v_terms
    FROM purchase_order_payment_terms t
    LEFT JOIN payment_trigger_events pte ON pte.code = t.trigger_event
    WHERE t.purchase_order_id = p_po_id;

    -- 【单据币种,只有单据币种】(§D)—— 这里没有 fx_rate,没有本位币数字。
    -- 本位币是内部口径:它决定审批级别,不该出现在供应商手里的纸上。
    RETURN jsonb_build_object(
        'code', v_po.code,
        'order_date', v_po.order_date,
        'expected_delivery_date', v_po.expected_delivery_date,
        -- PUR-1:交货地点与参照合同号。**两者都可空,而空就是【不印】** ——
        -- PDF 那一侧不画空标签(见 PurchaseOrderDocument.tsx 的两处判断)。
        'delivery_location', v_po.delivery_location,
        'contract_code', v_contract_code,
        'currency', v_po.currency,
        'status', v_po.status,
        'approval_status', v_po.approval_status,
        'incoterm', v_po.incoterm,
        'terms_text', v_po.terms_text,
        'notes', v_po.notes,
        -- ★★【PO-GST-1:净额 / 税 / 含税额,三个数,一个来源】★★
        -- 屏幕与 PDF 读的都是这三个字段所依据的【同两列】(estimated_total_ccy 与
        -- tax_total_ccy)。此前 PDF 读本函数、屏幕直接读遮蔽视图 —— 两条路今天
        -- 落在同一列上,所以【碰巧】一致;加了税之后再各算各的,迟早各说各话。
        -- 【含税额在这里加一次】gross = net + COALESCE(tax, 0),不另存一列:
        -- 存第三个数就是给自己第三个会漂的地方。
        'estimated_total_ccy', CASE WHEN v_see THEN v_po.estimated_total_ccy END,
        'tax_total_ccy', CASE WHEN v_see THEN v_po.tax_total_ccy END,
        'gross_total_ccy', CASE WHEN v_see THEN v_po.estimated_total_ccy + COALESCE(v_po.tax_total_ccy, 0) END,
        'prices_visible', v_see,
        -- 【这张单带不带税】NULL 的税额合计不是零税:它是"这张单开在采购单携带税
        -- 之前,或开在 GST 未注册的时候"。PDF 与屏幕对这两种情形说的话不一样。
        'carries_tax', (v_po.tax_total_ccy IS NOT NULL),
        -- ★【有没有一条【不在范围内】的行】★ 有就要在纸上说清:这一部分的 GST
        -- 不付给这家供应商,而是进口清关时付给新加坡海关。见 ①b。
        'has_out_of_scope_line', EXISTS (
            SELECT 1 FROM purchase_order_lines x
             WHERE x.purchase_order_id = p_po_id AND x.tax_code = 'OP'),
        'supplier', jsonb_build_object(
            'legal_name', v_sup.legal_name, 'address', v_sup.address,
            'country', v_sup.country, 'tax_id', v_sup.tax_id),
        'lines', v_lines,
        'payment_terms', v_terms
    );
END;
$function$;


-- FIN-21(2026-08-06):改问 fx_rate_asof —— 同一条解析规则,多拿一个【取自哪一天】,
-- 与所用侧(恒 tt_sell)一起记进 price_history.rate_as_of / rate_type。
-- 缺牌价仍拒:再调一次 fx_rate_for 抛唯一的 FX_RATE_MISSING(重估写入侧同一模式)。

CREATE OR REPLACE FUNCTION public.reprice_inbound_batch(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_old       numeric;
    v_deleted   timestamptz;
    v_qty       numeric;
    v_remaining numeric;
    v_code      text;
    v_fx        numeric;
    v_fx_asof date;   -- FIN-21:牌价取自哪一天(fx_rate_asof 的 as_of)
    v_usd       numeric;
    v_split     jsonb;
    v_delta     numeric;
    v_ratio     numeric;
    v_inv       numeric := 0;
    v_cost      numeric := 0;
    v_lines     jsonb;
    v_je        jsonb := NULL;
BEGIN
    -- ★ ROLE-1 Batch 4a(Tim 2026-09-24:看不见价格的人不能定价,【在库里】挡):这是每一条定价路径
    --   (建单带价、定价面板、按已承诺条款改价、应用化验)都落进来的那一支引擎,所以
    --   "看得见采购价"在这里问【按按钮的那个人】(DEFINER 不改 auth.uid())。它原来那道嵌套的
    --   module.inbound.edit 拆掉(ROLE-1 Batch 2 grilling 第 4 条登记给 Batch 4 的那一处):
    --   谁能定价由各自的门说 —— 手工定价 action.price_receipts,应用化验 action.apply_assay。
    --   本支的 EXECUTE 已从 authenticated 收回(侧门 (c)),只经那几扇门进来。
    PERFORM require_permission('data.view_purchase_prices');
    SELECT unit_price, deleted_at, quantity, remaining_qty, code
    INTO v_old, v_deleted, v_qty, v_remaining, v_code
    FROM inbound_batches WHERE id = p_inbound_batch_id FOR UPDATE;
    IF NOT FOUND OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;
    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【定价日】的行方卖出价(tt_sell)估值 ——
    -- 这批货将来要向银行买外币去付。当日无牌价即拒(FX_RATE_MISSING);
    -- 汇率不再由调用方递入(p_fx_rate 必须为空),原币与所用汇率仍进 price_history。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    -- FIN-21:问 fx_rate_asof —— 同一条解析规则,多拿一个【取自哪一天】。
    -- 缺牌价时它返回空行;再调一次 fx_rate_for 让它抛出唯一的那份
    -- FX_RATE_MISSING|币种|日期|侧(重估写入侧同一模式,错误文案不写第二遍)。
    SELECT a.rate, a.as_of INTO v_fx, v_fx_asof
    FROM fx_rate_asof(p_currency, CURRENT_DATE, 'tt_sell') a;
    IF v_fx IS NULL THEN
        PERFORM fx_rate_for(p_currency, CURRENT_DATE, 'tt_sell');
    END IF;

    v_usd := round(p_unit_price * v_fx, 4);  -- 单价 4 位小数(FIN-0 起为 SGD 本位价;列名沿用 _usd,重命名与生产重建同批)

    -- GUC 放行本函数内的 unit_price 更新(guard_inbound_price_change),用毕即清,
    -- 免得同事务内后续的直改被误放行(同 movement_ctx 模式)。
    PERFORM set_config('evoltrya.price_ctx', 'set_inbound_unit_price', true);
    UPDATE inbound_batches
    SET unit_price = v_usd, updated_by = v_user, updated_at = now()
    WHERE id = p_inbound_batch_id;
    PERFORM set_config('evoltrya.price_ctx', '', true);

    INSERT INTO price_history (inbound_batch_id, old_unit_price, new_unit_price, currency, original_price, fx_rate,
                               rate_as_of, rate_type, notes, created_by)
    VALUES (p_inbound_batch_id, v_old, v_usd, p_currency, p_unit_price, v_fx,
            v_fx_asof, 'tt_sell', p_notes, v_user);

    -- cut 2a:计价即入账 —— 整批数量 × 价差(负债在收货整批上成立,非剩余量)。
    -- 记于定价日 CURRENT_DATE(到货日尚无金额,刻意如此);USD 口径(原币在 price_history)。
    -- 拆分算术来自 reprice_split —— 与 preview_reprice_inbound_batch 共用同一份。
    v_split := reprice_split(v_qty, v_remaining, v_old, v_usd);
    v_delta := (v_split->>'delta_usd')::numeric;
    v_ratio := (v_split->>'in_stock_ratio')::numeric;

    IF v_delta <> 0 THEN
        -- 拆账:在库份额进 1200,已消耗份额进 5000;贷方(负差时借方)恒 2000
        v_inv  := (v_split->>'inventory_share_usd')::numeric;
        v_cost := (v_split->>'cost_share_usd')::numeric;

        v_lines := '[]'::jsonb;
        IF abs(v_inv) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '1200',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_inv),
                'line_memo', 'in-stock share');
        END IF;
        IF abs(v_cost) > 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', '5000',
                'side', CASE WHEN v_delta > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_cost),
                'line_memo', 'consumed share');
        END IF;
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2000',
            'side', CASE WHEN v_delta > 0 THEN 'credit' ELSE 'debit' END,
            'currency', base_currency_code(), 'amount_ccy', abs(v_delta));

        v_je := post_journal_entry(
            CURRENT_DATE,
            'Pricing ' || v_code,
            'purchase',
            p_inbound_batch_id,
            v_lines
        );
    END IF;

    RETURN jsonb_build_object(
        -- 旧返回键原样保留(既有调用方靠它们)
        'batch_id', p_inbound_batch_id,
        'unit_price_usd', v_usd,
        -- cut 5a 起的完整分解(界面与对账都要能逐项交代)
        'batch_code', v_code,
        'old_unit_price', v_old,
        'new_unit_price', v_usd,
        'price_delta_usd', v_delta,
        'in_stock_ratio', v_ratio,
        'inventory_share_usd', v_inv,
        'cost_share_usd', v_cost,
        'journal_code', v_je->>'code'
    );
END;
$function$;

-- ─── set_inbound_unit_price
CREATE OR REPLACE FUNCTION public.set_inbound_unit_price(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- ★ ROLE-1 Batch 4a:定价归财务(action.price_receipts),而且看不见采购价的人不能定价 ——
    --   两个码都在库里问(grilling Q1)。引擎 reprice_inbound_batch 自己再问一次后者。
    PERFORM require_permission('action.price_receipts');
    PERFORM require_permission('data.view_purchase_prices');
    RETURN reprice_inbound_batch(p_inbound_batch_id, p_unit_price, p_currency, p_fx_rate, p_notes);
END;
$function$;

-- ─── reprice_from_committed_terms
CREATE OR REPLACE FUNCTION public.reprice_from_committed_terms(p_inbound_batch_id uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_batch   record;
    v_commit  uuid;
    v_formula uuid;
    v_calc    jsonb;
    v_unit    numeric;
    v_rep     jsonb;
BEGIN
    -- ★ ROLE-1 Batch 4a:定价归财务(action.price_receipts),而且看不见采购价的人不能定价 ——
    --   两个码都在库里问(grilling Q1)。引擎 reprice_inbound_batch 自己再问一次后者。
    PERFORM require_permission('action.price_receipts');
    PERFORM require_permission('data.view_purchase_prices');

    SELECT id, code, pricing_formula_id INTO v_batch
    FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;

    -- 【与试算同一份算术】committed_terms_price 里做承诺解析、含量读取与算价;
    -- 这里只负责落账。两条路不可能各算各的。
    v_calc   := committed_terms_price(p_inbound_batch_id, p_reference_date);
    v_commit := (v_calc->>'commitment_id')::uuid;
    v_unit   := (v_calc->>'unit_price_usd_per_kg')::numeric;
    IF v_unit IS NULL OR v_unit <= 0 THEN
        -- 净值 ≤ 0 的料不进价格机器(与 apply_assay_result 同一判断),但这里是人
        -- 主动按的按钮,所以点名说清楚,而不是默默什么都不做。
        RAISE EXCEPTION 'PRICE_NOT_POSITIVE|%', COALESCE(v_unit::text, '?');
    END IF;

    v_rep := reprice_inbound_batch(v_batch.id, v_unit, 'USD', NULL,
                                   'Repriced from committed terms');

    -- 批次上记下这张公式,界面据此显示"这批货归哪张公式管"(结算仍只读副本)
    SELECT c.source_formula_id INTO v_formula
    FROM pricing_term_commitments c WHERE c.id = v_commit;
    IF v_batch.pricing_formula_id IS NULL AND v_formula IS NOT NULL THEN
        UPDATE inbound_batches SET pricing_formula_id = v_formula, updated_by = v_user
        WHERE id = v_batch.id;
    END IF;

    RETURN jsonb_build_object(
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'commitment_id', v_commit,
        'unit_price_usd_per_kg', v_unit,
        'calc', v_calc,
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'journal_code', v_rep->'journal_code'
    );
END;
$function$;

-- ─── preview_reprice_from_committed_terms
CREATE OR REPLACE FUNCTION public.preview_reprice_from_committed_terms(p_inbound_batch_id uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_calc   jsonb;
    v_unit   numeric;
    v_impact jsonb := NULL;
BEGIN
    -- ★ ROLE-1 Batch 4a:这是定价面板的试算 —— 与它提交的那扇门同一对码:定价归财务(action.price_receipts),而且看不见采购价的人不能定价 ——
    --   两个码都在库里问(grilling Q1)。引擎 reprice_inbound_batch 自己再问一次后者。
    PERFORM require_permission('action.price_receipts');
    PERFORM require_permission('data.view_purchase_prices');
    v_calc := committed_terms_price(p_inbound_batch_id, p_reference_date);
    v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
    -- 单价 ≤ 0 时不试算拆账(它会 PRICE_INVALID),但明细照给 —— 那种料
    -- apply_assay_result 本来也不会给它定价,摆一个"调整 −X 元"反而是误导。
    IF v_unit > 0 THEN
        -- 币种显式:提交路径 reprice_from_committed_terms 也是按 USD 递进去的
        v_impact := preview_reprice_inbound_batch(p_inbound_batch_id, v_unit, 'USD');
    END IF;
    RETURN jsonb_build_object('calc', v_calc, 'impact', v_impact);
END;
$function$;

-- ─── create_inbound_batch
CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text, p_currency text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_id      uuid;
    v_warn    text[];
    v_pricing jsonb := NULL;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    -- ★ ROLE-1 Batch 4a(grilling Q4):建单【带价】就是定价 —— 要 action.price_receipts 与
    --   data.view_purchase_prices,在【写入之前】按名拒,整笔建单回滚;绝不悄悄丢掉那个价。
    --   不带价的建单只要 module.inbound.edit(仓库照建)。
    IF p_unit_price IS NOT NULL THEN
        PERFORM require_permission('action.price_receipts');
        PERFORM require_permission('data.view_purchase_prices');
    END IF;

    -- IOD-2-fu1:到货日【按名】必填。不写这一句,漏出去的是 FIN-32 的约束原文。
    -- 【不给默认值】:CURRENT_DATE 会让留空比填对更容易通过。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    -- 【顺序要紧】库位先校验再落库:拒绝必须发生在写入之前,否则一次被拒的
    -- 收货会留下半个批次(单事务会回滚,但错误信息的语义也该是"什么都没发生")。
    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸。同样在写入之前 —— 它可能抛 IOD_CLASS_EXCLUDED。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- GRN-1a:p_declared_qty 原样落库,【不拒绝任何差异】,也【绝不从采购行推断】。
    -- PROC-2c:确定度随表头一起落 —— 适用性由 trg_inbound_batches_condition_applicable
    -- 判(它在库里,所以这条路、批次页面、直连 SQL 三条一起盖住)。
    -- RECV-SOURCE-1:理由原样落库,拒绝(RECEIPT_SOURCE_REQUIRED /
    -- SOURCE_REASON_EXPLANATION_REQUIRED)由 guard_receipt_source_stated 抛 ——
    -- 本函数一个字都不重复它们,重复一遍就是第二份会漂开的判断。
    -- INB-PAY-1:unit_price 【不在这里落】—— 见下面定价那一段。
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, unit, remaining_qty, arrival_date,
        stage, notes, purchase_order_id, purchase_order_line_id,
        declared_qty, chemistry_certainty_code, source_reason_code, source_reason_note,
        created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_arrival_date,
        COALESCE(p_stage,'待加工'), p_notes, p_purchase_order_id, p_purchase_order_line_id,
        p_declared_qty, p_chemistry_certainty, p_source_reason_code,
        NULLIF(btrim(COALESCE(p_source_reason_note, '')), ''),
        v_user, v_user)
    RETURNING id INTO v_id;

    -- PROC-2c:安全状态【只在给了参数时才碰】。
    -- 【NULL 与 '{}' 在这里是两件事】NULL = "这条路没提这件事"(既有调用点),
    -- '{}' = "明说了:一个状态都没有"。两者结果相同(零行),但只有前者
    -- 保证【一个字节都不动】—— F1 钉的正是这个。
    IF p_safety_states IS NOT NULL THEN
        PERFORM set_inbound_safety_states(v_id, p_safety_states);
    END IF;

    -- 用毕即清 —— 同 commit_processing_run 的 movement_ctx:免得同事务内后续的
    -- 插入把这个库位当成自己的(那正是 ctx 这种机制唯一的锋利处)。
    PERFORM set_config('evoltrya.location_ctx', '', true);

    -- INB-PAY-1:建单带价 = 建单 + 定价,【同一事务、同一份定价实现】。
    -- reprice_inbound_batch 写 price_history、按定价日过 purchase 分录(Dr 1200 / Cr 2000),
    -- 并按名拒绝非正价格、非法币种与缺牌价 —— 任何一条拒绝都让整笔建单回滚。
    IF p_unit_price IS NOT NULL THEN
        v_pricing := reprice_inbound_batch(v_id, p_unit_price, p_currency, NULL, NULL);
    END IF;

    -- IOD-2:返回值从 uuid 变成 jsonb —— 告警要有地方回去。batch_id 仍在里面。
    -- INB-PAY-1:定价的分解(含分录号)随之返回;不带价时为 null。
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn),
                              'pricing', v_pricing);
END;
$function$

;

-- db/functions/reverse_journal_entry.sql
-- 手工冲销一张分录(module.finance.edit)。付款、转账、代扣税缴纳的分录按名拒,走各自的申请。
-- ★ PAYROLL-APR-1(2026-09-24,Tim 的 Q5):工资期的过账分录与它的冲销也按名拒 —— 撤销走撤销申请。

CREATE OR REPLACE FUNCTION public.reverse_journal_entry(p_entry_id uuid, p_reversal_date date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_src text;
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- ★ PAY-REQ-1(Tim 的 Q2(b)):付款与银行转账的分录【不许】从这里冲 ——
    --   这里冲掉一笔付款的分录,钱在总账上回来了,而付款行仍是 posted、核销仍然
    --   算数(结算按 payments.status 求和),而且绕过了冲销申请与 CFO 的批准。
    --   付款走冲销申请(reverse_payment 那一条);转账走转账冲销申请。
    --   ★ PAY-REQ-1 Batch B(Tim 的 Q3):代扣税缴纳也关在这里 —— 它的更正从此走
    --   wht_remittance_reversal 申请(reverse_wht_remittance_internal),经 CFO 批准。
    SELECT source_type, code INTO v_src, v_code FROM journal_entries WHERE id = p_entry_id;
    -- ★ ROLE-1 Batch 4a(侧门 (b)):收货定价的 purchase 分录也关在这里 —— 从这里冲掉它,2000 回来了,
    --   收货单的单价与改价历史却不动,ap_open_items 照样说欠着,清单与总账从此各说各话。
    --   更正走改价(定价面板;Batch 4b 起经 CFO 批准的定价申请)。
    IF v_src IN ('payment', 'transfer', 'wht_remittance', 'purchase') THEN
        RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_code, v_src;
    END IF;
    -- ★ PAYROLL-APR-1(Tim 的 Q5):工资期的【过账】分录也关在这里 —— 从这里冲掉它,总账回来了,
    --   期间却仍是 posted、付款照样付得出去,而且绕过了撤销申请与 CFO 的批准。撤销走撤销申请。
    --   ☞ 【过账那一张,以及它的冲销】—— 冲掉一张撤销分录,等于不经申请把工资重新过了一遍账,
    --   而期间仍是 draft。判法反过来写:source_type 'payroll' 里,只有【付款】分录(以及它们的冲销)
    --   放行 —— 它们被 payroll_lines.paid_journal_entry_id / cpf_journal_entry_id /
    --   deductions_journal_entry_id 指着。付款分录根本没有正经的冲销路径(已登记
    --   PAYROLL-PAYMENT-NO-REVERSAL-PATH);在这里关掉它们,等于把唯一的(错的)出路也关了
    --   而不给一条对的 —— 那是另一刀的事。
    IF v_src = 'payroll' AND NOT EXISTS (
           SELECT 1 FROM journal_entries j
            WHERE j.id = p_entry_id
              AND (EXISTS (SELECT 1 FROM payroll_lines pl
                            WHERE pl.paid_journal_entry_id IN (j.id, j.source_id))
                   OR EXISTS (SELECT 1 FROM payroll_periods pp
                               WHERE pp.cpf_journal_entry_id IN (j.id, j.source_id)
                                  OR pp.deductions_journal_entry_id IN (j.id, j.source_id)))) THEN
        RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_code, v_src;
    END IF;
    RETURN reverse_journal_entry_internal(p_entry_id, p_reversal_date, p_memo);
END;
$function$;

-- ── 6 · 侧门 (a):price_history 不再接受直连插入 ──────────────────────────────
DROP POLICY "price_history insert by permission" ON public.price_history;

-- ── 7 · 侧门 (c):定价引擎只经门进来 ─────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.reprice_inbound_batch(uuid, numeric, text, numeric, text) FROM authenticated;

-- ── 8 · 自证 ──────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.b4a_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      LEFT JOIN holds h ON 'module.processing.edit' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      LEFT JOIN holds h ON 'module.stocktakes.edit' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
     WHERE s.status = 'open' AND s.deleted_at IS NULL
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE b4a_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved');

DO $proof$
DECLARE
    v_bad       text;
    v_n         int;
    v_expected  int;
    k           text;
BEGIN
    -- ① 授权 = 之前 + 本刀的授权,不多不少;一条没收
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
        EXCEPT SELECT role_code || ':' || permission_code FROM b4a_grants_before
        EXCEPT SELECT role_code || ':data.view_purchase_prices' FROM b4a_grants_before
                WHERE permission_code = 'data.view_prices'
        EXCEPT SELECT unnest(ARRAY['warehouse:data.view_purchase_prices', 'finance:action.price_receipts',
                                   'admin:data.view_purchase_prices', 'admin:action.price_receipts'])) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B4A_PROOF|unexpected grant: %', v_bad; END IF;
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        SELECT role_code || ':' || permission_code AS x FROM b4a_grants_before
        EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B4A_PROOF|a grant was removed: %', v_bad; END IF;
    SELECT count(DISTINCT role_code) + 2 INTO v_expected FROM b4a_grants_before
     WHERE permission_code = 'data.view_prices' OR role_code IN ('warehouse', 'admin');
    SELECT count(*) INTO v_n FROM role_permissions rp WHERE rp.permission_code IN ('data.view_purchase_prices',
                                                                                    'action.price_receipts');
    IF v_n <> v_expected THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|expected % new-code grants, got %', v_expected, v_n;
    END IF;

    -- ② 谁都不少看一格:持 view_prices 的每一个角色都持采购码;仓库持采购码、不持 view_prices;
    --    action.price_receipts 只在 finance 与 admin
    SELECT string_agg(r.code, ', ') INTO v_bad FROM roles r
     WHERE EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_code = 'data.view_prices')
       AND NOT EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id
                        AND rp.permission_code = 'data.view_purchase_prices');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B4A_PROOF|holds view_prices without the purchase code: %', v_bad; END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE r.code = 'warehouse' AND rp.permission_code = 'data.view_prices')
       OR NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                       WHERE r.code = 'warehouse' AND rp.permission_code = 'data.view_purchase_prices') THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|warehouse price codes are not purchase-only';
    END IF;
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.price_receipts';
    IF v_bad IS DISTINCT FROM 'admin finance' THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|price_receipts holders are %', v_bad;
    END IF;

    -- ③ 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|approvals switched off';
    END IF;

    -- ④ 在途单据一张不少、一张不多;留痕、分录、改价历史、收货单一行没变
    IF EXISTS ((SELECT b.k, b.id FROM b4a_pending_before b EXCEPT SELECT a.k, a.id FROM b4a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM b4a_pending_after a EXCEPT SELECT b.k, b.id FROM b4a_pending_before b)) THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|a pending document changed state';
    END IF;
    IF (SELECT (approval_log, journal_entries, price_history, receipts, receipts_priced) FROM b4a_counts_before)
       IS DISTINCT FROM
       (SELECT ((SELECT count(*) FROM approval_log), (SELECT count(*) FROM journal_entries),
                (SELECT count(*) FROM price_history), (SELECT count(*) FROM inbound_batches),
                (SELECT count(*) FROM inbound_batches WHERE unit_price IS NOT NULL))) THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|a business row count changed';
    END IF;

    -- ⑤ 结构:三扇侧门关上
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'price_history'
                AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|price_history still has a write policy';
    END IF;
    IF has_function_privilege('authenticated', 'public.reprice_inbound_batch(uuid, numeric, text, numeric, text)',
                              'EXECUTE') THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|authenticated can still execute reprice_inbound_batch';
    END IF;
    IF (SELECT array_agg(DISTINCT g ORDER BY g) FROM approval_chain_gates() c, unnest(c.gate_permissions) g
         WHERE c.action_function = 'approve_purchase_order')
       IS DISTINCT FROM ARRAY['data.view_purchase_prices', 'module.purchasing.view']::text[] THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|approve_purchase_order gate row';
    END IF;

    -- ⑥ 采购单批准的两级此刻都有人批得了(开着的审批不许因为换码而变成"开着却没人能批")
    FOR v_n IN 1..2 LOOP
        IF (SELECT count(*) FROM approval_deciders('purchase_order', 'approve_purchase_order', v_n::smallint,
                NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
                (SELECT approval_level2_role_code FROM finance_settings))) = 0 THEN
            RAISE EXCEPTION 'ROLE1B4A_PROOF|nobody can approve a level-% purchase order', v_n;
        END IF;
    END LOOP;

    -- ⑦ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.b4a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ROLE1B4A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.b4a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ROLE1B4A_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.b4a_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.b4a_pending_decider_check(boolean);

COMMIT;
