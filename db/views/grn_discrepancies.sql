-- db/views/grn_discrepancies.sql
-- GRN-1a:收货差异 —— 一条【挂了采购行的】收货一行。
--
-- NOTE: introduced by db/migrations/2026-08-17-grn1a-receiving-discrepancy-db-half.sql.
-- First-run script. Re-running requires DROP VIEW first.
--
-- 【为什么它存在,而两个现成的读者不够】GRN-0 量到的:
--   * po_receivable_lines 只收 confirmed / receiving —— 单一关那一行就消失了,
--     而短交恰恰是关单之后才成为问题的;
--   * purchase_order_status 在【单】上汇总 —— 一行超收一行短收可以正好抵成
--     receipt_pct = 100%。它不是没算,是算在了看不见差异的粒度上。
--
-- 【三个"不下断言"的地方,每一个都是刻意的】
--   * 没挂采购行的批次【整行缺席】,不是一行零(work_order_fulfilment 的 has_plan);
--   * assay_beyond_tolerance 在预期或实际缺任何一侧时是 NULL,不是 false;
--   * declared_delta_qty 在没记申报量时是 NULL,不是 0。
--
-- 【属主权限 + module.purchasing.view】跨 inbound × purchasing 两个模块,
-- invoker 会让无权那一侧的行被 RLS 静默丢掉(OPS-14 的 xmodule)。谓词取
-- purchasing 是因为订量本来就只在那道门后面 —— 实测 warehouse 读
-- po_receivable_lines 得 0 行,而线上每个持 purchasing.view 的角色都持 inbound.view。
--
-- 【阈值一个都没写死】三个都现读 receiving_settings(它是 RUNTIME CONFIG)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它看不见什么 —— 写下来,免得一张空白的差异表被读成"没有差异"】
-- 本视图的粒度是【一条收货一行】。于是一条【一次都没收过】的采购行,不产生
-- 任何行 —— 而那恰恰是最彻底的短交。这不是漏洞,是粒度的直接后果;但它必须
-- 被说出来,因为"视图里没有它"与"它没问题"在屏幕上长得一模一样。
--
-- 线上今天正好有一条(GRN-1a 应用当天实测):PO-2026-0006,订 50、收 0、
-- 状态 cancelled。那一条【不该报】—— 一张被取消的、货从没来过的单,是订单
-- 管理在正常工作,不是一次短交。所以今天这个盲区没有一个实例是错的。
-- 【但换成 closed 就是另一回事了】:关了单、一次都没收到货,那是一次 100%
-- 的短交,而本视图说不出它。要覆盖它,需要的是一张【以采购行为粒度】的伴生
-- 视图(每行一条,包含零收货的行),不是把本视图改成外连接 —— 外连接会让
-- 每一条收货行都多带一个"这一行还有没收的"含义,把两个问题搅在一起。
-- 那是一个单独的决定,留给读这段话的人,不在 GRN-1a 里顺手做掉。
-- ════════════════════════════════════════════════════════════════════════════

CREATE VIEW public.grn_discrepancies WITH (security_invoker = off) AS
 WITH cfg AS (
         SELECT receiving_settings.grn_short_pct,
            receiving_settings.grn_over_pct,
            receiving_settings.grn_assay_tolerance_pct
           FROM receiving_settings
         LIMIT 1
        ), line_totals AS (
         SELECT ib.purchase_order_line_id AS line_id,
            sum(ib.quantity) AS line_received_qty,
            count(*) AS line_receipt_count
           FROM inbound_batches ib
          WHERE ib.purchase_order_line_id IS NOT NULL AND ib.deleted_at IS NULL
          GROUP BY ib.purchase_order_line_id
        ), applied_assay AS (
         SELECT DISTINCT ON (a.inbound_batch_id) a.inbound_batch_id,
            a.id AS assay_id
           FROM assay_results a
          WHERE a.inbound_batch_id IS NOT NULL AND a.deleted_at IS NULL AND a.applied_at IS NOT NULL
          ORDER BY a.inbound_batch_id, a.applied_at DESC
        ), assay_gap AS (
         SELECT b_1.id AS batch_id,
            bool_or((abs(m.content_pct - e.content_pct) / e.content_pct * 100::numeric) > cfg_1.grn_assay_tolerance_pct) AS beyond,
            count(*) AS metals_compared
           FROM inbound_batches b_1
             JOIN purchase_order_lines pol_1 ON pol_1.id = b_1.purchase_order_line_id
             JOIN applied_assay aa ON aa.inbound_batch_id = b_1.id
             CROSS JOIN cfg cfg_1
             CROSS JOIN LATERAL jsonb_to_recordset(
                CASE
                    WHEN jsonb_typeof(pol_1.expected_assay) = 'array'::text THEN pol_1.expected_assay
                    ELSE '[]'::jsonb
                END) e(metal text, content_pct numeric)
             JOIN assay_result_metals m ON m.assay_result_id = aa.assay_id AND m.metal = e.metal
          WHERE e.content_pct > 0::numeric
          GROUP BY b_1.id
        )
 SELECT b.id AS batch_id,
    b.code AS batch_code,
    b.arrival_date,
    b.supplier_id,
    sup.legal_name AS supplier_name,
    po.id AS po_id,
    po.code AS po_code,
    po.status AS po_status,
    pol.id AS line_id,
    pol.line_no,
    pol.material_id AS ordered_material_id,
    om.code AS ordered_material_code,
    b.material_id AS received_material_id,
    rm.code AS received_material_code,
    pol.quantity AS ordered_qty,
    pol.unit AS ordered_unit,
    b.quantity AS received_qty,
    b.unit AS received_unit,
    b.declared_qty,
    round(lt.line_received_qty, 4) AS line_received_qty,
    lt.line_receipt_count,
    round(lt.line_received_qty - pol.quantity, 4) AS line_delta_qty,
    round((lt.line_received_qty - pol.quantity) / pol.quantity * 100::numeric, 2) AS line_delta_pct,
        CASE
            WHEN b.declared_qty IS NULL THEN NULL::numeric
            ELSE round(b.quantity - b.declared_qty, 4)
        END AS declared_delta_qty,
    ag.beyond AS assay_beyond_tolerance,
    ag.metals_compared AS assay_metals_compared,
    ((((ARRAY[]::text[] ||
        CASE
            WHEN (po.status = ANY (ARRAY['closed'::text, 'cancelled'::text])) AND lt.line_received_qty < (pol.quantity * (1::numeric - cfg.grn_short_pct / 100::numeric)) THEN ARRAY['short'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN lt.line_received_qty > (pol.quantity * (1::numeric + cfg.grn_over_pct / 100::numeric)) THEN ARRAY['over'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN b.declared_qty IS NOT NULL AND b.declared_qty > 0::numeric AND (b.quantity < (b.declared_qty * (1::numeric - cfg.grn_short_pct / 100::numeric)) OR b.quantity > (b.declared_qty * (1::numeric + cfg.grn_over_pct / 100::numeric))) THEN ARRAY['declared_vs_actual'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN b.material_id IS DISTINCT FROM pol.material_id THEN ARRAY['material_mismatch'::text]
            ELSE ARRAY[]::text[]
        END) ||
        CASE
            WHEN ag.beyond THEN ARRAY['assay_beyond_tolerance'::text]
            ELSE ARRAY[]::text[]
        END AS kinds
   FROM inbound_batches b
     JOIN purchase_order_lines pol ON pol.id = b.purchase_order_line_id
     JOIN purchase_orders po ON po.id = pol.purchase_order_id
     JOIN suppliers sup ON sup.id = b.supplier_id
     JOIN materials om ON om.id = pol.material_id
     JOIN materials rm ON rm.id = b.material_id
     JOIN line_totals lt ON lt.line_id = pol.id
     CROSS JOIN cfg
     LEFT JOIN assay_gap ag ON ag.batch_id = b.id
  WHERE b.deleted_at IS NULL AND po.deleted_at IS NULL AND has_permission('module.purchasing.view'::text);

COMMENT ON VIEW public.grn_discrepancies IS
    'GRN-1a:收货差异,一条【挂了采购行的】收货一行 —— 订量、实收、申报量、三个差额,以及 kinds 点名哪里不对(short / over / declared_vs_actual / material_mismatch / assay_beyond_tolerance)。【三个阈值现读 receiving_settings,一个数都没写死】。
【它活过关单】—— po_receivable_lines 只收 confirmed/receiving,purchase_order_status 在【单】上汇总(一行超一行短可以正好抵成 100%),两个现成读者都在短交刚成为问题的那一刻消失。本视图两者都不做。
【没挂采购行的批次整行缺席,不是一行零】(work_order_fulfilment 的 has_plan 那一条:没估过 ≠ 估了零)。同理 assay_beyond_tolerance 在两侧缺任何一侧时是 NULL 而不是 false,declared_delta_qty 在没记申报量时是 NULL 而不是 0。
【short/over 是采购行级的事实,挂在该行的每一条收货上】:分批到货不该被报成短交,所以两者都比【累计】;而一条 short 出现两次的意思是"这一行短了、它有两次收货",要按行计数请 DISTINCT line_id。short 只在 closed/cancelled 时报(开着的单"少"只是"还没收完"),over 任何状态都报(它当场就占了地方、欠了钱)—— 与 processing_settings 那两个工单阈值逐字同一条。
【material_mismatch 是告警,永远不是拒绝】—— 换料是可以谈成的正当场景;但它必须【被点名】,因为它也正是"谎报货物性质"在技术上的样子。
【属主权限 + module.purchasing.view】:跨 inbound × purchasing 两个模块,invoker 会让无权那一侧的行被 RLS 静默丢掉、内连接把整行带走,读者得到的是"没有差异"而不是"受限"(OPS-14)。谓词取 purchasing 是因为【订量本来就只在那道门后面】(po_receivable_lines / purchase_order_status 同码),而线上每个持 purchasing.view 的角色都持 inbound.view —— 实测,不放宽任何一行。';

GRANT SELECT ON public.grn_discrepancies TO authenticated;
