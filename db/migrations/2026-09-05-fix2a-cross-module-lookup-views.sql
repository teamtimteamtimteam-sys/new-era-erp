-- db/migrations/2026-09-05-fix2a-cross-module-lookup-views.sql
-- FIX-2a(2026-09-05)· 一次缺席被渲染成一个答案 —— 剩下的那 81 处
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀的标准不是"谁被挡住了",是"哪一屏在说谎"】
--
-- FIX-1 修了 Fu Sheng 填不完的那张收货表单,并把其余的在 §11.4 点了名,理由是
-- 「没有人被挡住」。**那个理由是错的,而 Tim 点出了错在哪:**
--
--     那张收货表单严重的地方从来不是他不方便,是【系统说了谎】——
--     屏幕上写着"没有供货的供应商",说的是七家真实存在的供应商。
--     Cluster B 的空面板是【同一句谎话,只是更安静】:
--     Choo Er 打开一块盘点面板,看见空的,于是认定没有盘点。她可能是错的。
--     没有人被挡住,所以没有人报告,所以它可以被一直相信下去。
--
-- 所以判据是:**有没有哪一屏,把一个空结果显示成一件关于生意的事实?**
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【实测的population —— 重新普查过,因为 §11.4 对那六个没人持有的角色只有【数】】
--
-- 方法:199 条路由 × 传递 import 闭包 × 线上 pg_policies(212 表)× 线上视图体
--      (102 张,其中 97 张 security_invoker=off)× 【12 个角色各一次模拟会话】
--      (SET LOCAL ROLE authenticated + 该角色的 sub,单事务,全部回滚)。
--
--   142 对(路由,对象):某个进得去这一页的角色读到空,而 admin 读得到行
--    57 对 —— 读它的文件【已经】在问某个权限(其中一部分问的是【另一个】权限,
--            那是 FIX-2b 的题目,本刀不碰)
--    85 对 —— 读它的文件【一个权限都没问】
--     4 对 —— 复核后是假阳性,逐条记在下面
--  ★ 81 对 = 本刀的真population
--
-- 【四个假阳性,逐条点名 —— 因为"我没修"与"它不需要修"必须分得开】
--   ① /inbound/[id]/edit  × output_batches   闭包假阳性:读它的是
--      metalContentActions.ts 的 saveOutputMetal / stocktakes/actions.ts,
--      而这一页只 import saveInboundMetal / deleteInboundMetal —— 那一支【不会被调到】;
--   ② /output/[id]/edit   × inbound_batches  同上,方向相反;
--   ③ /output/[id]/assays/[assayId] × assay_results
--   ④ /output/[id]/assays/[assayId] × assay_result_metals
--      —— ③④ 不是权限造成的:assay_results 的谓词【按行】分岔
--      (inbound_batch_id → inbound.view;output_batch_id → output.view),
--      而线上 4 行【全部】是进料化验、产出化验 0 行。sales 持 output.view,
--      它读到 0 是【真的没有产出化验】。★ 一个按行分岔的谓词,不能按角色判空。★
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【本刀唯一的不变量 —— 每一张查名视图都遵守它,而它就是暴露面的全部论据】★★
--
--     **查名视图只改【行】谓词。每一【列】原样保留它已经背着的 data.* 遮蔽。**
--
-- 也就是说:一张查名视图【不可能】让任何人看见一个他本来无权看见的数据类。
--   · payroll_period_lookup 带着薪酬合计,但那四列仍然按 data.view_pay 遮成 NULL
--     —— 而 finance 与 cfo 本来就持有 data.view_pay(实测),挡住他们的
--     从来只是 module.hr.view 这一道【行】门;
--   · inbound_batch_lookup 带着 unit_price,仍然按 data.view_prices 遮;
--   · processing_output_lookup 带着 unit_cost_base,仍然按 data.view_prices 遮。
--
-- **于是"这张视图暴露了什么"只需要看它【没有被遮的那几列】** —— 每一张下面都写着。
-- 一个新权限码都没有铸。任何角色的授权一条都没有增减。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【(a) 与 (b) —— 每一处都落在其中一边,没有一处留成空白】
--   (a) 这个读者【应该】看见  → 一张窄的属主权限查名视图(与 FIX-1 同形);
--   (b) 这个读者【不应该】看见 → 屏幕必须【说出来】。那不在这个文件里,
--       在调用点:<Refusal> / <RefusalBlock>(CONV-0 收敛出的那一份画法)。
--   本刀:(a) 70 处 · (b) 11 处 · 合计 81。
--
-- ★【(b) 不是安慰奖】对 warehouse 与 operations 扣下价格与毛利【就是对的】——
--   Tim 的 Q4 裁定原话「初期不给。加回来便宜,看过了就收不回」。
--   不可接受的是【沉默】,不是【扣下】。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 镜像:db/views/{container_overview,processing_run_allocation_status,
--                supplier_lookup,customer_lookup,material_lookup}.sql(改)
--       db/views/*_lookup.sql(13 张新)
-- 行为断言:db/fixtures/194-a-reader-is-told-what-is-withheld-not-shown-an-empty-screen.sql
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 第〇部分 · 一处【修复】,不是一次放宽 —— Tim 要求与暴露面清单分开报告
-- ════════════════════════════════════════════════════════════════════════════
-- container_overview 的体内谓词是 module.purchasing.view,
-- 而读它的那两页(/logistics/containers、/logistics/containers/[id])的守卫是
-- **module.logistics.view**。于是 operations / sales / warehouse 三个角色
-- 【通过了这一页的守卫】,然后从这一页【自己的主表】读到零行 ——
-- 箱子列表画得出来,每一行的发货单数、涉及客户数、最新里程碑、待收单据数全是空的。
--
-- ★ 这不是"给谁多看了什么":能开这一页的人本来就应该读得到这一页的内容。
--   把 logistics.view 加进去,【没有】让任何打不开这一页的人读到任何东西。
--   purchasing.view 原样留着 —— 没有人因此少读。
CREATE OR REPLACE VIEW public.container_overview AS
 SELECT c.id,
    c.code,
    c.container_number,
    c.vessel,
    c.voyage,
    c.departure_date,
    c.bl_number,
    c.lane_id,
    c.forwarder_id,
    f.legal_name AS forwarder_name,
    (( SELECT count(*) AS count
           FROM shipments s
          WHERE s.container_id = c.id))::integer AS shipment_count,
    (( SELECT count(DISTINCT o.customer_id) AS count
           FROM shipments s
             JOIN sales_orders o ON o.id = s.sales_order_id
          WHERE s.container_id = c.id))::integer AS customer_count,
    ( SELECT m.milestone
           FROM container_milestones m
          WHERE m.container_id = c.id
          ORDER BY m.event_date DESC, m.recorded_at DESC
         LIMIT 1) AS latest_milestone,
    ( SELECT m.event_date
           FROM container_milestones m
          WHERE m.container_id = c.id
          ORDER BY m.event_date DESC, m.recorded_at DESC
         LIMIT 1) AS latest_milestone_date,
    COALESCE(ls.checklist_state, 'no_lane'::text) AS lane_checklist_state,
    (( SELECT count(*) AS count
           FROM container_documents d
          WHERE d.container_id = c.id AND d.status = 'pending'::text))::integer AS documents_pending
   FROM containers c
     LEFT JOIN suppliers f ON f.id = c.forwarder_id
     LEFT JOIN lane_checklist_status ls ON ls.lane_id = c.lane_id
  WHERE c.deleted_at IS NULL
    AND (has_permission('module.purchasing.view'::text)
      OR has_permission('module.logistics.view'::text));

-- ════════════════════════════════════════════════════════════════════════════
-- 第一部分 · 放宽 FIX-1 那三张查名视图的【行】谓词
-- ★ 列一个字没动 —— 暴露的仍然是 FIX-1 已经论证过的那几列。★
-- ════════════════════════════════════════════════════════════════════════════

-- supplier_lookup:+ logistics.view(货代与箱子两页要叫出货代的名字)
--                 + finance.view (付款、费用、预扣税五页要叫出收款方的名字;cfo 只持三个模块)
--                 + pricing.view (计价公式挂在某一家供应商上)
-- 暴露面不变:id / code / legal_name / supplies_goods / counterparty_type / deleted_at。
-- **仍然没有 payment_terms / incoterm / credit_rating / tax_id / address / tax_residence。**
CREATE OR REPLACE VIEW public.supplier_lookup AS
 SELECT s.id,
    s.code,
    s.legal_name,
    s.supplies_goods,
    s.counterparty_type,
    s.deleted_at
   FROM suppliers s
  WHERE has_permission('module.suppliers.view'::text)
     OR has_permission('module.inbound.view'::text)
     OR has_permission('module.logistics.view'::text)
     OR has_permission('module.finance.view'::text)
     OR has_permission('module.pricing.view'::text);

-- customer_lookup:+ finance.view(贷项凭证、发票、收款、应收五页要叫出客户的名字)
--                 + pricing.view(计价公式挂在某一个客户上)
CREATE OR REPLACE VIEW public.customer_lookup AS
 SELECT c.id,
    c.code,
    c.legal_name,
    c.deleted_at
   FROM customers c
  WHERE has_permission('module.customers.view'::text)
     OR has_permission('module.output.view'::text)
     OR has_permission('module.finance.view'::text)
     OR has_permission('module.pricing.view'::text);

-- material_lookup:+ inventory.view(库存三页按物料分组,要叫出物料的名字)
--                 + purchasing.view(采购单行指向一种物料)
--
-- ★★【本刀给这张视图【加了四列】—— 加列就是扩权,所以理由写在这里】★★
--   kind_code / kind_name_en / kind_name_zh —— 物料【种类】。库存按种类分组,
--     进料的到货状态轴按种类决定问哪几个问题。种类是这张字典的目录,不是内容。
--   waste_classification_code —— 废物分类。★ 这一列是【现场安全】,不是商务:
--     /inventory/reports/violations 拿它回答"这批货能不能放在这个库位"。
--     对一个每天搬这些货的人扣下它,不是谨慎,是危险。
--   ★ 种类名【摊平】进来(不做 FK 嵌入):PostgREST 的嵌入对被嵌的表另套一遍
--     RLS,而视图没有 FK,嵌不了 —— 与 shipment_lookup 同一个理由。
--   仍然【没有】chemistry / spec / safety_stock_qty / notes —— 那些是物料主数据
--     的内容,而这张视图存在的理由是不给它们。
CREATE OR REPLACE VIEW public.material_lookup AS
-- ★【列的顺序不是风格问题】CREATE OR REPLACE VIEW 只允许在【末尾追加】列;
--   把新列插在 deleted_at 前面会当场报 "cannot change name of view column"。
--   所以 FIX-1 那四列原样留在前面,新的五列一律追加在后面。
 SELECT m.id,
    m.code,
    m.name,
    m.deleted_at,
    m.unit,
    m.kind_code,
    k.name_en AS kind_name_en,
    k.name_zh AS kind_name_zh,
    m.waste_classification_code
   FROM materials m
     LEFT JOIN material_kinds k ON k.code = m.kind_code
  WHERE has_permission('module.materials.view'::text)
     OR has_permission('module.inbound.view'::text)
     OR has_permission('module.output.view'::text)
     OR has_permission('module.inventory.view'::text)
     OR has_permission('module.purchasing.view'::text);

-- ════════════════════════════════════════════════════════════════════════════
-- 第二部分 · 放宽一张【状态】视图的行谓词
-- ════════════════════════════════════════════════════════════════════════════
-- processing_run_allocation_status:+ finance.view
-- /finance/month-end 靠它回答「这一期的分摊还作数吗」。cfo 与 finance 读到零行时,
-- 那一屏显示的是"没有过期的分摊" —— 而那正是关账前最不能猜的一句话。
-- ★ 它的七列【一列钱都没有】(run_id / code / allocated_at / last_cost_change /
--   is_stale / cogs_posted(计数) / safe_to_reallocate),所以放宽行谓词
--   不经过 data.view_prices 那道门 —— 没有门可经过。
CREATE OR REPLACE VIEW public.processing_run_allocation_status AS
 SELECT r.id AS run_id,
    r.code,
    r.allocated_at,
    c.last_cost_change,
    r.allocated_at IS NOT NULL AND c.last_cost_change IS NOT NULL AND c.last_cost_change > r.allocated_at AS is_stale,
    COALESCE(g.cogs_posted, 0::bigint) AS cogs_posted,
    r.capitalization_entry_id IS NULL OR je.status = 'posted'::text AS safe_to_reallocate
   FROM processing_runs r
     LEFT JOIN journal_entries je ON je.id = r.capitalization_entry_id
     LEFT JOIN LATERAL ( SELECT max(x.ts) AS last_cost_change
           FROM ( SELECT GREATEST(e.created_at, e.updated_at) AS ts
                   FROM processing_cost_entries e
                  WHERE e.run_id = r.id
                UNION ALL
                 SELECT fa.created_at
                   FROM freight_allocations fa
                     JOIN freight_documents fd ON fd.id = fa.freight_document_id
                     JOIN processing_inputs pif ON pif.inbound_batch_id = fa.inbound_batch_id
                  WHERE pif.run_id = r.id AND fd.deleted_at IS NULL AND fd.status = 'posted'::text
                UNION ALL
                 SELECT ph.created_at
                   FROM price_history ph
                     JOIN processing_inputs pi ON pi.inbound_batch_id = ph.inbound_batch_id
                  WHERE pi.run_id = r.id
                UNION ALL
                 SELECT r2.allocated_at
                   FROM processing_inputs pi2
                     JOIN processing_outputs po2 ON po2.output_batch_id = pi2.output_batch_id
                     JOIN processing_runs r2 ON r2.id = po2.run_id
                  WHERE pi2.run_id = r.id AND r2.allocated_at IS NOT NULL
                UNION ALL
                 SELECT GREATEST(obm.created_at, obm.updated_at) AS ts
                   FROM processing_outputs po6
                     JOIN output_batch_metals obm ON obm.output_batch_id = po6.output_batch_id
                  WHERE po6.run_id = r.id AND r.allocation_basis = 'metal_value'::text
                UNION ALL
                 SELECT bpca.created_at
                   FROM batch_processing_cost_allocations bpca
                     JOIN processing_runs rsrc ON rsrc.id = bpca.run_id
                     JOIN processing_inputs pif7 ON pif7.inbound_batch_id = bpca.inbound_batch_id
                  WHERE pif7.run_id = r.id AND bpca.run_id <> r.id AND rsrc.deleted_at IS NULL AND rsrc.status = 'committed'::text
                UNION ALL
                 SELECT r.allocation_basis_changed_at AS ts) x) c ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS cogs_posted
           FROM sales_records sr
             JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = r.id
          WHERE sr.cogs_entry_id IS NOT NULL) g ON true
  WHERE r.deleted_at IS NULL
    AND (has_permission('module.processing.view'::text)
      OR has_permission('module.finance.view'::text));

-- ════════════════════════════════════════════════════════════════════════════
-- 第三部分 · 十三张新的【查名】视图
-- 每一张:属主权限(security_invoker = off)+ 体内一句 has_permission 的析取。
-- 每一张下面写着【它没有遮的那几列】—— 那就是它的暴露面。
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. inbound_batch_lookup ────────────────────────────────────────────────
-- 谁要它:/finance/payments/[id]・/finance/payables/[batchId]・
--         /inventory/inbound/[materialId]・/purchasing/orders/[id]・
--         /finance/{journal,journal/[id],ledger/[account]}(单据链接的标签)。
-- 暴露面(未遮的列):id / code / material_id / supplier_id / quantity /
--   remaining_qty / unit / stage / arrival_date / status —— 【编号、数量与阶段】。
-- unit_price 在列上,但仍然按 data.view_prices 遮 —— 与 inbound_batches_masked
-- 逐字同一条谓词。**没有 pricing_formula_id / pricing_status / notes /
-- import_permit_* / source_reason_*** —— 那些是进料自己的业务内容,不是"叫出编号"。
CREATE VIEW public.inbound_batch_lookup WITH (security_invoker = off) AS
 SELECT b.id,
    b.code,
    b.material_id,
    b.supplier_id,
    b.quantity,
    b.remaining_qty,
    b.unit,
    b.stage,
    b.arrival_date,
    b.status,
    b.deleted_at,
    -- notes 与 created_at:应付明细页(/finance/payables/[batchId])印这两个。
    -- created_at 只是 arrival_date 缺失时的单据日兜底。notes 是【这一批自己的
    -- 现场备注】—— 商务条款不在这里(付款条件在 suppliers,价格已按 view_prices 遮),
    -- 而一张"要为这批货付多少钱"的页面读不到这批货的备注是说不过去的。
    b.notes,
    b.created_at,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN b.unit_price
            ELSE NULL::numeric
        END AS unit_price
   FROM inbound_batches b
  WHERE has_permission('module.inbound.view'::text)
     OR has_permission('module.purchasing.view'::text)
     OR has_permission('module.finance.view'::text)
     OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.inbound_batch_lookup IS
    'FIX-2a:进料批次的【查名】视图 —— 编号 / 物料 / 供应商 / 数量 / 阶段 / 到货日。付款、应付、库存与采购四处要把一笔金额或一行库存指回它来自哪一批。unit_price 在列上但【仍按 data.view_prices 遮】,与 inbound_batches_masked 同一条谓词 —— 本视图只改【行】谓词,不改任何一列的遮蔽。行谓词 inbound.view OR purchasing.view OR finance.view OR inventory.view。没有 pricing_formula_id / pricing_status / 进口许可 / 来源理由(notes 与 created_at 在列上,应付明细页要它们 —— 现场备注不是商务条款)。暴露面就是这张视图未遮的列清单。';

GRANT SELECT ON public.inbound_batch_lookup TO authenticated;

-- ── 2. output_batch_lookup ─────────────────────────────────────────────────
-- 谁要它:/inventory・/inventory/output/[materialId]・/finance/payments/[id]・
--         /finance/receivables/[saleId]・/finance/{journal,ledger}。
-- 暴露面:id / code / material_id / customer_id / quantity / remaining_qty /
--   unit / output_date / state / status —— 产出批次表上【本来就没有价格列】。
CREATE VIEW public.output_batch_lookup WITH (security_invoker = off) AS
 SELECT b.id,
    b.code,
    b.material_id,
    b.customer_id,
    b.quantity,
    b.remaining_qty,
    b.unit,
    b.output_date,
    b.state,
    b.status,
    b.deleted_at
   FROM output_batches b
  WHERE has_permission('module.output.view'::text)
     OR has_permission('module.purchasing.view'::text)
     OR has_permission('module.finance.view'::text)
     OR has_permission('module.inventory.view'::text)
     OR has_permission('module.processing.view'::text);

COMMENT ON VIEW public.output_batch_lookup IS
    'FIX-2a:产出批次的【查名】视图 —— 编号 / 物料 / 客户 / 数量 / 状态 / 产出日。库存与财务五处要把一行库存或一笔金额指回它是哪一批。★ output_batches 这张表【本来就没有任何价格列】,所以这里没有遮蔽 —— 毛利在 batch_margin,单位成本在 processing_outputs,两张都【没有】跟着放宽。行谓词 output.view OR purchasing.view OR finance.view OR inventory.view OR processing.view。没有 purity / notes / purpose_code。';

GRANT SELECT ON public.output_batch_lookup TO authenticated;

-- ── 3. processing_run_lookup ───────────────────────────────────────────────
-- 谁要它:/finance/processing-costs(把一条成本指回它属于哪一张加工单)・
--         /inventory(物料平衡:投入、产出、损耗三个【数量】合计)。
-- ★ 暴露面里【一列钱都没有】:material_cost_base / process_cost_base /
--   total_cost_base / capitalized_cost_base / allocation_snapshot 全部不在列上。
--   total_input / total_output / loss_qty 是【公斤】,不是钱。
CREATE VIEW public.processing_run_lookup WITH (security_invoker = off) AS
 SELECT r.id,
    r.code,
    r.process_date,
    r.status,
    r.work_order_id,
    r.total_input,
    r.total_output,
    r.loss_qty,
    r.deleted_at
   FROM processing_runs r
  WHERE has_permission('module.processing.view'::text)
     OR has_permission('module.finance.view'::text)
     OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.processing_run_lookup IS
    'FIX-2a:加工单的【查名】视图 —— 编号 / 日期 / 状态 / 工单 + 投入、产出、损耗三个【数量】。/inventory 的物料平衡与 /finance/processing-costs 的成本归属要它。★ 一列钱都没有:material_cost_base / process_cost_base / total_cost_base / capitalized_cost_base / allocation_snapshot 全部不出列。行谓词 processing.view OR finance.view OR inventory.view。';

GRANT SELECT ON public.processing_run_lookup TO authenticated;

-- ── 4. processing_output_lookup ────────────────────────────────────────────
-- 谁要它:/inventory 的"成品按成本"那一栏。
-- ★ unit_cost_base 仍然按 data.view_prices 遮 —— 与 processing_outputs_masked
--   逐字同一条谓词。放宽的只有【行】:此前 warehouse / finance / procurement /
--   sales 读到零条产出腿,于是那一栏是 0.00 而不是「受限」。
--   /inventory 自己【已经有】那个具名受限的渲染(INV-VAL-1),它此前拿不到行去驱动。
CREATE VIEW public.processing_output_lookup WITH (security_invoker = off) AS
 SELECT o.id,
    o.output_batch_id,
    o.run_id,
    o.quantity_produced,
    o.cost_incomplete,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN o.unit_cost_base
            ELSE NULL::numeric
        END AS unit_cost_base
   FROM processing_outputs o
  WHERE has_permission('module.processing.view'::text)
     OR has_permission('module.finance.view'::text)
     OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.processing_output_lookup IS
    'FIX-2a:产出腿的【查名】视图 —— 批次 / 加工单 / 数量,外加按 data.view_prices 遮的单位成本(与 processing_outputs_masked 同一条列谓词)。只改【行】谓词:此前读不到行的人在 /inventory 上拿到的是一个自信的 0.00,而那一页自己已经有具名受限的渲染,只是没有行去驱动它。行谓词 processing.view OR finance.view OR inventory.view。';

GRANT SELECT ON public.processing_output_lookup TO authenticated;

-- ── 5. processing_cost_entry_lookup ────────────────────────────────────────
-- 谁要它:/finance/processing-costs・/finance/month-end・
--         /finance/{journal,journal/[id],ledger/[account]}(sourceLinks 的标签)。
-- amount_base 按 data.view_prices 遮,与 processing_cost_entries_masked 同一条。
CREATE VIEW public.processing_cost_entry_lookup WITH (security_invoker = off) AS
 SELECT e.id,
    e.run_id,
    e.cost_type,
    e.is_estimate,
    e.created_at,
    e.deleted_at,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN e.amount_base
            ELSE NULL::numeric
        END AS amount_base
   FROM processing_cost_entries e
  WHERE has_permission('module.processing.view'::text)
     OR has_permission('module.finance.view'::text);

COMMENT ON VIEW public.processing_cost_entry_lookup IS
    'FIX-2a:加工成本条目的【查名】视图 —— id / 加工单 / 成本类型 / 是否估算 / 创建时间,外加按 data.view_prices 遮的金额(与 processing_cost_entries_masked 同一条列谓词)。财务的分录、总账与月结三处要把一条分录指回它的来源单据。行谓词 processing.view OR finance.view —— cfo 只持 finance / logistics / purchasing 三个模块,此前这三页对他全是空的。';

GRANT SELECT ON public.processing_cost_entry_lookup TO authenticated;

-- ── 6. work_order_lookup ───────────────────────────────────────────────────
CREATE VIEW public.work_order_lookup WITH (security_invoker = off) AS
 SELECT w.id,
    w.code,
    w.status,
    w.scheduled_date
   FROM work_orders w
  WHERE has_permission('module.processing.view'::text)
     OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.work_order_lookup IS
    'FIX-2a:工单的【查名】视图 —— 编号 / 状态 / 排期日。/inventory/output/[materialId] 要把一批产成品指回它的工单。行谓词 processing.view OR inventory.view。没有 notes / close_reason / cancel_reason —— 那三列是【为什么关掉的】,不是"叫出编号"。';

GRANT SELECT ON public.work_order_lookup TO authenticated;

-- ── 7. payroll_period_lookup ───────────────────────────────────────────────
-- 谁要它:/finance/payroll-payments(付这一期的薪)・/finance/month-end(关账)。
-- ★★【这一张是"列的遮蔽原样保留"最要紧的一个例子】★★
-- 四个合计在列上,但仍然按 data.view_pay 遮 —— 与 employees_masked 同一条谓词。
-- 而 finance 与 cfo **本来就持有 data.view_pay**(实测:admin/cco/cfo/finance/hr),
-- 挡住他们的从来只是 module.hr.view 这一道【行】门。
-- 也就是说本视图【没有让任何人多看见一分钱】:它只是不再把
-- "这个月没有薪资期间"这句假话说给一个要去付薪的人听。
CREATE VIEW public.payroll_period_lookup WITH (security_invoker = off) AS
 SELECT p.id,
    p.code,
    p.period_month,
    p.payment_date,
    p.currency,
    p.status,
    p.cpf_paid_at,
    p.deductions_paid_at,
    p.deleted_at,
        CASE WHEN has_permission('data.view_pay'::text) THEN p.gross_total ELSE NULL::numeric END AS gross_total,
        CASE WHEN has_permission('data.view_pay'::text) THEN p.net_pay_total ELSE NULL::numeric END AS net_pay_total,
        CASE WHEN has_permission('data.view_pay'::text) THEN p.employer_cpf_total ELSE NULL::numeric END AS employer_cpf_total,
        CASE WHEN has_permission('data.view_pay'::text) THEN p.employee_cpf_total ELSE NULL::numeric END AS employee_cpf_total,
        CASE WHEN has_permission('data.view_pay'::text) THEN p.other_deductions_total ELSE NULL::numeric END AS other_deductions_total
   FROM payroll_periods p
  WHERE has_permission('module.hr.view'::text)
     OR has_permission('module.finance.view'::text);

COMMENT ON VIEW public.payroll_period_lookup IS
    'FIX-2a:薪资期间的【查名】视图 —— 编号 / 期间 / 付款日 / 状态 / 已缴时点。五个合计在列上但【仍按 data.view_pay 遮】,与 employees_masked 同一条列谓词。★ finance 与 cfo 本来就持有 data.view_pay,挡住他们的只是 module.hr.view 这道【行】门 —— 所以本视图一分钱都没有多给,它只是不再对一个要去付薪的人说"这个月没有薪资期间"。行谓词 hr.view OR finance.view。没有 source_note / notes / journal_entry_id。';

GRANT SELECT ON public.payroll_period_lookup TO authenticated;

-- ── 8. employee_lookup ─────────────────────────────────────────────────────
-- ★ Tim 的 Q2 裁定:【只有名字】。id / code / preferred_name / legal_name / user_id。
--   「一个名字不是一条人事事实,而一个裸 uuid 挂在固定资产上是它自己的一种谎话。」
-- 【没有】薪酬、证件、准证、部门、职位、入离职日期、work_email、work_phone。
-- 与 ActorName 的分工:ActorName 管"谁做的"(它已经会说「受限」了);
-- 这一张管"这份单据【指向】谁"(付款收款人、费用申请人、薪资付给谁)。
CREATE VIEW public.employee_lookup WITH (security_invoker = off) AS
 SELECT e.id,
    e.code,
    e.preferred_name,
    e.legal_name,
    e.user_id,
    e.deleted_at
   FROM employees e
  WHERE has_permission('module.hr.view'::text)
     OR has_permission('module.finance.view'::text);

COMMENT ON VIEW public.employee_lookup IS
    'FIX-2a:员工的【查名】视图 —— id / 工号 / 称呼名 / 法定名 / 登录账号。Tim 的 Q2 裁定:只有名字。付款、费用与薪资三处要把一份单据指向一个人。【没有】monthly_salary / identity_no / work_pass_* / residency_status / department_id / position_id / hire_date / separation_* / work_email / work_phone —— 那些才是人事事实,而 data.view_pay 与 data.view_identity 管着它们。行谓词 hr.view OR finance.view。与 ActorName 的分工:那一个答"谁做的",这一张答"这份单据指向谁"。';

GRANT SELECT ON public.employee_lookup TO authenticated;

-- ── 9. shipment_lookup ─────────────────────────────────────────────────────
-- 谁要它:/logistics/containers/[id](这只箱子里装着哪几张发货单)。
-- ★【为什么把客户名与订单号【摊平】进来,而不是让调用点做 FK 嵌入】
--   PostgREST 的嵌入对【每一张被嵌的表】各自套一遍 RLS。
--   `shipments(sales_orders(customers(legal_name)))` 因此要同时持
--   sales.view 与 customers.view —— 而这一页的守卫是 logistics.view。
--   摊平之后判据只有一处:这张视图的体内谓词。
CREATE VIEW public.shipment_lookup WITH (security_invoker = off) AS
 SELECT s.id,
    s.code,
    s.ship_date,
    s.container_id,
    s.sales_order_id,
    o.code AS sales_order_code,
    c.legal_name AS customer_legal_name
   FROM shipments s
     LEFT JOIN sales_orders o ON o.id = s.sales_order_id
     LEFT JOIN customers c ON c.id = o.customer_id
  WHERE has_permission('module.sales.view'::text)
     OR has_permission('module.logistics.view'::text);

COMMENT ON VIEW public.shipment_lookup IS
    'FIX-2a:发货单的【查名】视图 —— 编号 / 出运日 / 箱子 / 销售订单号 / 客户法定名。★ 客户名与订单号是【摊平】进来的,不是让调用点做 FK 嵌入:PostgREST 的嵌入对每一张被嵌的表各自套一遍 RLS,于是 shipments(sales_orders(customers)) 要同时持 sales.view 与 customers.view,而 /logistics/containers/[id] 的守卫是 logistics.view。摊平之后判据只有一处。行谓词 sales.view OR logistics.view。没有金额、没有数量、没有订单行。';

GRANT SELECT ON public.shipment_lookup TO authenticated;

-- ── 10. freight_document_lookup ────────────────────────────────────────────
-- 谁要它:/logistics/containers/[id]・/logistics/forwarders/[id] 的运费单据列表。
-- amount_ccy 按 data.view_prices 遮 —— sales 持有它,warehouse 与 operations 不持有,
-- 于是同一张列表对不同的人给出不同的金额列,而那正是既有的规矩。
CREATE VIEW public.freight_document_lookup WITH (security_invoker = off) AS
 SELECT d.id,
    d.code,
    d.doc_date,
    d.currency,
    d.status,
    d.payment_status,
    d.direction,
    d.supplier_id,
    d.container_id,
    d.deleted_at,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN d.amount_ccy
            ELSE NULL::numeric
        END AS amount_ccy
   FROM freight_documents d
  WHERE has_permission('module.inbound.view'::text)
     OR has_permission('module.finance.view'::text)
     OR has_permission('module.logistics.view'::text);

COMMENT ON VIEW public.freight_document_lookup IS
    'FIX-2a:运费单据的【查名】视图 —— 编号 / 单据日 / 币种 / 状态 / 付款状态 / 方向。金额按 data.view_prices 遮。行谓词在既有的 inbound.view OR finance.view 之外加 logistics.view —— 读这两页的守卫就是 logistics.view,此前 sales 通过守卫之后读到零张单据。';

GRANT SELECT ON public.freight_document_lookup TO authenticated;

-- ── 11. tax_code_lookup ────────────────────────────────────────────────────
-- 谁要它:/sales/customers/[id]/edit・/suppliers/[id]/edit 的默认税码下拉。
-- 纯参考数据,一列钱都没有。挡住 sales 与 procurement 的是 module.finance.view。
CREATE VIEW public.tax_code_lookup WITH (security_invoker = off) AS
 SELECT t.code,
    t.side,
    t.name_en,
    t.name_zh,
    t.is_claimable,
    t.is_active,
    t.sort_order
   FROM tax_codes t
  WHERE has_permission('module.finance.view'::text)
     OR has_permission('module.customers.view'::text)
     OR has_permission('module.suppliers.view'::text);

COMMENT ON VIEW public.tax_code_lookup IS
    'FIX-2a:税码的【查名】视图 —— 码 / 买卖侧 / 中英名 / 可抵扣 / 启用 / 排序。客户与供应商的编辑页要它填"默认税码"那个下拉;此前 sales 与 procurement 拿到一张空下拉,而税码是一张【参考字典】,不是一笔财务数据。行谓词 finance.view OR customers.view OR suppliers.view。没有 F5 申报格位(f5_supply_box / f5_purchase_box / f5_tax_box)—— 那是报税表的结构,不是选一个税码要的东西。';

GRANT SELECT ON public.tax_code_lookup TO authenticated;

-- ── 12. finance_settings_lookup ────────────────────────────────────────────
-- 谁要它:/sales/customers/[id]/edit(gst_registered)・
--         /suppliers/[id]/edit(gst_registered)・
--         /operation/processing/new(default_allocation_basis)。
-- ★【三列,而且是被点名的三列】—— 期间锁 locked_before、审批阈值
--   approval_threshold_base、GST 登记号 gst_registration_no 都【不在】列上:
--   没有任何一个调用点读它们,而它们各自是一条真正的财务配置。
CREATE VIEW public.finance_settings_lookup WITH (security_invoker = off) AS
 SELECT s.id,
    s.gst_registered,
    s.gst_rate_pct,
    s.default_allocation_basis
   FROM finance_settings s
  WHERE has_permission('module.finance.view'::text)
     OR has_permission('module.customers.view'::text)
     OR has_permission('module.suppliers.view'::text)
     OR has_permission('module.processing.view'::text);

COMMENT ON VIEW public.finance_settings_lookup IS
    'FIX-2a:财务设置里【三个被别的模块读的开关】—— 是否 GST 登记 / GST 税率 / 默认分摊基准。客户与供应商编辑页要第一个,新建加工单要第三个。★ locked_before(期间锁)、approval_threshold_base(审批阈值)、gst_registration_no(登记号)【都不在列上】:没有调用点读它们,而它们各自是一条真正的财务配置。行谓词 finance.view OR customers.view OR suppliers.view OR processing.view。';

GRANT SELECT ON public.finance_settings_lookup TO authenticated;

-- ── 13b. customer_billing_lookup ───────────────────────────────────────────
-- 谁要它:/finance/invoices/new —— 开一张发票要带出这个客户的付款账期与默认税码。
--
-- ★【为什么另建一张,而不是把这两列加进 customer_lookup】
--   customer_lookup 的读者现在有六个模块码(customers / output / finance /
--   pricing 及其下的角色)。付款账期与默认税码是【商务条款】,不是名字 ——
--   把它们加进那张广口视图,等于让每一个只需要"叫出客户名字"的人顺带拿到条款。
--   两张视图、两个受众:名字给所有需要指认客户的页面,条款只给开单的人。
CREATE VIEW public.customer_billing_lookup WITH (security_invoker = off) AS
 SELECT c.id,
    c.payment_terms_days,
    c.default_tax_code
   FROM customers c
  WHERE has_permission('module.customers.view'::text)
     OR has_permission('module.finance.view'::text);

COMMENT ON VIEW public.customer_billing_lookup IS
    'FIX-2a:客户的【开单条款】视图 —— 只有 id / 付款账期 / 默认税码。开发票的页面要它。★ 刻意【不】把这两列加进 customer_lookup:那张是"叫出客户名字"的广口视图(customers / output / finance / pricing 四个码都读得到),而账期与税码是商务条款。两张视图,两个受众。行谓词 customers.view OR finance.view。没有 credit_limit_base / credit_hold / credit_rating / incoterm —— 授信是另一件事,customer_credit_status 管它。';

GRANT SELECT ON public.customer_billing_lookup TO authenticated;

-- ── 13. output_batch_metal_lookup ──────────────────────────────────────────
-- 谁要它:/inventory 的"成品按市价"那一栏 —— 含量 × 金属行情。
-- ★ 含量【不是】价格:metal_prices 的 SELECT 谓词实测是 USING (true)(公开),
--   而含量此前只对 output.view 可见。于是 /inventory 上一个持 inventory.view
--   的读者拿到"市值 0.00" —— 两个乘数里,公开的那个他读得到,另一个读不到。
CREATE VIEW public.output_batch_metal_lookup WITH (security_invoker = off) AS
 SELECT m.output_batch_id,
    m.metal,
    m.content_pct
   FROM output_batch_metals m
  WHERE has_permission('module.output.view'::text)
     OR has_permission('module.inventory.view'::text)
     OR has_permission('module.processing.view'::text);

COMMENT ON VIEW public.output_batch_metal_lookup IS
    'FIX-2a:产出批次金属含量的【查名】视图 —— 批次 / 金属 / 含量百分比。/inventory 的"成品按市价"用它乘以金属行情。★ 含量不是价格:metal_prices 的 SELECT 谓词是 USING (true)(公开),此前含量只对 output.view 可见,于是持 inventory.view 的读者拿到"市值 0.00" —— 两个乘数里公开的那个读得到,另一个读不到。行谓词 output.view OR inventory.view OR processing.view。没有 source_assay_id / 出处 —— 那是含量【怎么来的】,不是含量本身。';

GRANT SELECT ON public.output_batch_metal_lookup TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- ★★【CREATE OR REPLACE VIEW 会把 WITH (...) 那一段【丢掉】—— 补回来】★★
-- AGENTS.md「Database mirrors」那一节记着这条,而本刀实测又撞了一次:
-- 上面五张【被替换】的视图,replace 之后 reloptions 里的 security_invoker 不见了。
--
-- ★ 说准一点:丢掉它【不会】把视图变成 invoker —— PostgreSQL 的默认本来就是
--   属主权限,所以【行为一字未变】。坏的是两件别的事:
--     ① 镜像文本对不上(db/views/*.sql 里写着 WITH (security_invoker = off)),
--        check_mirrors 会为一件没有发生的漂移报红;
--     ② 下一个读镜像的人据此判断"这张视图是不是刻意声明过属主权限",
--        而一个丢了声明的视图读起来像是没人想过这件事。
-- 新建的那 15 张不受影响 —— CREATE VIEW 上写了 WITH,它跟着走。
ALTER VIEW public.container_overview               SET (security_invoker = off);
ALTER VIEW public.supplier_lookup                  SET (security_invoker = off);
ALTER VIEW public.customer_lookup                  SET (security_invoker = off);
ALTER VIEW public.material_lookup                  SET (security_invoker = off);
ALTER VIEW public.processing_run_allocation_status SET (security_invoker = off);

COMMIT;
