-- db/migrations/2026-09-05-fix1-cross-module-lookup-views.sql
-- FIX-1 item 3(2026-09-05)· 收货的人必须【叫得出】他要指向的那个东西
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【实测的缺陷 —— 而它比报上来的大三倍】
--
-- Fu Sheng(warehouse)持 module.inbound.edit,收货是他每天的活。他打开
-- 「新增进料」,选不了供应商 —— 页面说"没有供货的供应商"。
-- 在【他自己的会话】里量过(SET LOCAL ROLE authenticated + 他的 sub,单事务回滚):
--
--     suppliers(供货、在册)   他看见 0    postgres 看见 7
--     materials(在册)         他看见 0    postgres 看见 5      ← 没有人报上来
--     customers(在册)         他看见 0    postgres 看见 3
--     po_receivable_lines      他看见 0    (今天线上本来就 0,见下)
--     storage_locations        他看见 1    ✓
--     inbound_source_reasons   他看见 4    ✓
--
-- **供应商、物料、采购单行三个下拉全是空的 —— 那张表单【填不完】,不是不方便。**
-- 只有供应商那一个自己会说话("没有供货的供应商"),所以只有它被报了上来。
--
-- ★【那道闸【放行了】—— 挡住他的是 RLS,不是界面】★
-- 同一次探针里 has_permission('module.inbound.view') = true:
-- requireModule(MOD.inbound) 通过,页面正常渲染。RLS 在那之后把行滤光,
-- **而它滤光的方式是返回零行、不报错**。于是 lib/db-helpers.ts 的
-- mustRows 把 `res.data ?? []` 原样递下去,页面画出一张空下拉。
--
--     **屏幕上那句"没有供货的供应商",说的是七家真实存在的供应商。**
--
-- 这正是 AGENTS.md 禁的那个形状:【把一次缺席渲染成一个答案】。
-- 它也解释了为什么没有任何一道闸抓到它 —— 没有任何一道闸在看"这个读者
-- 拿到的空,是真的空,还是被滤成的空"。这条发现比本刀修的东西活得久,
-- 所以它单独写进了 docs/accounts-roles-and-permissions.md,不只是本文件的抬头。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么不是"把 module.suppliers.view 授给 warehouse"】
--
-- 因为那不是他需要的东西。suppliers 这张表上还有
--     payment_terms · incoterm · credit_rating · tax_id · address · tax_residence
-- 而 module.suppliers.view 这个码同时打开 contracts 与 7 张 contract_*、
-- commission_agreements、counterparty_contacts、company_compliance ——
-- **也就是整段商务关系。** 而 role_permissions 对 warehouse 写的原话是
-- 「现场收货、产出与盘点;**不接触任何商务数据**」。
--
-- 他要的只有一样:**把那家供应商的名字叫出来,好让这张收货单指得中。**
--
-- 【本刀因此照 C-1b 已经裁过的那一句做】(docs/accounts-roles-and-permissions.md:462)
--     「读与写为什么可以是两个码…现场的人必须【看得见】有哪些实验室、有哪些
--       收货理由,否则他填不了单;而决定"名录里该有谁"是物料主数据的事。
--       这就是 Fu Sheng 的处境,**一个新码都不需要**。」
-- 那一次的落点是字典;这一次是供应商、物料、客户与可收货的采购单行。
-- 同一句话,第二处落点。**没有新权限码,一个都没有。**
--
-- 【形状:窄的属主权限查名视图】—— 而这不是本刀发明的,收货表单里【已经有一个】:
-- supplier_receiving_blocked 就是一张属主权限视图,体内挂 module.inbound.view,
-- 连着 suppliers,而 Fu Sheng 今天就读得到它。本刀只是把同一招用在
-- 他真正卡住的那三张表上。
--
-- ★★【暴露面 = 下面的列清单,一个字不多。这句话是本刀的全部承诺】★★
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【谁因此新读得到 —— 逐个点名,算过的】
--
--   supplier_lookup            → operations(Phua)、warehouse(Fu Sheng)
--   material_lookup            → warehouse(Fu Sheng)
--   customer_lookup            → operations(Phua)、warehouse(Fu Sheng)
--   po_receivable_lines_lookup → operations(Phua)、warehouse(Fu Sheng)
--
-- **12 个在册角色里,新读到东西的只有这两个,而它们正是 Tim 裁进本刀的两个。**
-- 第三个角色一行都没有多拿到 —— 这是对着线上 role_permissions 算出来的,
-- 不是估的。行为断言:fixture 100,两个方向都钉。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【po_receivable_lines 为什么是【新造一张】而不是把老的放宽】—— 两个理由,都是硬的
--
--  ① **放宽老的那一张【做不到】。** 它读的是 purchase_orders_masked 与
--     purchase_order_lines_masked,而那两张伴生视图【各自体内】也写着
--     has_permission('module.purchasing.view')。只改最外层的谓词是一次空操作:
--     内层照样返回零行。要真放宽就得动三张视图,而那三张是整个采购模块的读者。
--  ② **老的那一张带着价。** pricing_formula_id 与 estimated_unit_price 在列上。
--     单价那一列确实已经被 purchase_order_lines_masked 按 data.view_prices 遮成
--     NULL(查过,不是假设:CASE WHEN has_permission('data.view_prices') …),
--     但 pricing_formula_id 没有遮。而收货表单【一个价都不读】——
--     两处调用点选的都是同样十列,里面没有价。
--     所以新的这一张干脆【一列价都不出】:遮成 NULL 与根本不出现,
--     对下一个读代码的人不是同一句话。
--
-- ★【它顺带做了 GRN-1a 明说留给以后的那个决定】★
-- db/migrations/2026-08-17-grn1a-…sql 的抬头写着,它 2026-08-17 就量到
-- 「warehouse 角色读 po_receivable_lines 得 0 行」,并且判词是:
--     「operations 与 warehouse 看不见差异,与他们今天看不见订量是同一件事。
--       这不是本刀新加的限制;**要改的话该改的是订量那道门,而那是一个单独的决定。**」
-- **那个单独的决定,就是今天这一刀。** 但本刀只开【收货表单要的那十列】那道小门,
-- **grn_discrepancies 一个字没动** —— 它仍然只对持 purchasing.view 的人有行。
-- 那是下一刀的题目,不是顺手。
-- ════════════════════════════════════════════════════════════════════════════
-- 镜像:db/views/{supplier_lookup,material_lookup,customer_lookup,
--                po_receivable_lines_lookup}.sql
-- 行为断言:db/fixtures/100-a-receiving-clerk-can-name-what-he-receives.sql
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. supplier_lookup ──────────────────────────────────────────────────────
-- 【只有叫得出名字所需的东西】:id / 编号 / 法定名 + 两个【下拉自己要用的】判据列。
-- supplies_goods 与 counterparty_type 出现在这里,是因为两处调用点各拿它们过滤
-- (收货只列供货户;进料编辑把货代排除)。把过滤搬到客户端做不到 —— 那会要求
-- 先把不该看的行发下去。**deleted_at 出列是为了让调用点的 .is('deleted_at', null)
-- 一个字不改**;它不是敏感列。
-- 【没有 payment_terms / incoterm / credit_rating / tax_id / address / tax_residence】
-- —— 那六列就是"商务数据"本身,而这张视图存在的全部理由是不给它们。
CREATE VIEW public.supplier_lookup WITH (security_invoker = off) AS
 SELECT s.id,
    s.code,
    s.legal_name,
    s.supplies_goods,
    s.counterparty_type,
    s.deleted_at
   FROM suppliers s
  WHERE has_permission('module.suppliers.view'::text)
     OR has_permission('module.inbound.view'::text);

COMMENT ON VIEW public.supplier_lookup IS
    'FIX-1 item 3:供应商的【查名】视图 —— 只有 id/编号/法定名 + 下拉自己要用的两个判据列(supplies_goods、counterparty_type)。收货与进料编辑用它把单据指向一家供应商,而【不】因此拿到付款条件、贸易术语、信用评级、税号或地址。属主权限 + 体内谓词 suppliers.view OR inbound.view;新读到它的只有 operations 与 warehouse。暴露面就是这张视图的列清单 —— 加列等于扩权,请连着 fixture 100 一起想。';

GRANT SELECT ON public.supplier_lookup TO authenticated;

-- ── 2. material_lookup ──────────────────────────────────────────────────────
-- 收货、产出、化验三处表单都只选 id / code / name(有两处只按 id 取 name)。
-- 【没有 chemistry / spec / safety_stock_qty / waste_classification_code】——
-- 那些是物料主数据的内容,不是"叫出名字"要的东西。
CREATE VIEW public.material_lookup WITH (security_invoker = off) AS
 SELECT m.id,
    m.code,
    m.name,
    m.deleted_at
   FROM materials m
  WHERE has_permission('module.materials.view'::text)
     OR has_permission('module.inbound.view'::text)
     OR has_permission('module.output.view'::text);

COMMENT ON VIEW public.material_lookup IS
    'FIX-1 item 3:物料的【查名】视图 —— 只有 id/编号/名称。收货、产出与化验表单用它把单据指向一种物料,而【不】因此拿到化验成分、规格、安全库存或废物分类。属主权限 + 体内谓词 materials.view OR inbound.view OR output.view;新读到它的只有 warehouse(operations 本来就持 materials.view)。暴露面就是这张视图的列清单。';

GRANT SELECT ON public.material_lookup TO authenticated;

-- ── 3. customer_lookup ──────────────────────────────────────────────────────
-- 建/改产出批次时要指定客户。两处调用点都只选 id / code / legal_name。
CREATE VIEW public.customer_lookup WITH (security_invoker = off) AS
 SELECT c.id,
    c.code,
    c.legal_name,
    c.deleted_at
   FROM customers c
  WHERE has_permission('module.customers.view'::text)
     OR has_permission('module.output.view'::text);

COMMENT ON VIEW public.customer_lookup IS
    'FIX-1 item 3:客户的【查名】视图 —— 只有 id/编号/法定名。产出批次表单用它把批次指向一个客户,而【不】因此拿到信用、对账、联系人或销售订单。属主权限 + 体内谓词 customers.view OR output.view;新读到它的只有 operations 与 warehouse。暴露面就是这张视图的列清单。';

GRANT SELECT ON public.customer_lookup TO authenticated;

-- ── 4. po_receivable_lines_lookup ───────────────────────────────────────────
-- 【与 po_receivable_lines 的关系:同一份业务判据,更窄的一份列】
-- 可收货的定义(未删 + status ∈ {confirmed, receiving})、已收量的算法
-- (Σ 挂在【该行】上的在册批次)、剩余量地板 0 —— 三条与老视图【逐字相同】。
-- 不同的只有两件:
--   · 它读【基表】而不是三张 _masked 伴生视图 —— 因为那三张体内各自挂着
--     purchasing.view,只改外层是空操作(见抬头 ①);
--   · 它【一列价都不出】—— 没有 estimated_unit_price,也没有 pricing_formula_id
--     与 expected_assay。两处收货调用点一个都不读(选的就是下面这十列)。
-- ★ 两份"可收货"的定义从此有两个实现 —— 这是本刀【明知而接受】的代价,
--   fixture 100 有一条断言把两张视图的行集钉在一起(对持 purchasing.view 的读者
--   两者必须给出同一组 line_id),改一边不改另一边会当场变红。
CREATE VIEW public.po_receivable_lines_lookup WITH (security_invoker = off) AS
 SELECT po.id AS po_id,
    po.code AS po_code,
    po.supplier_id,
    po.order_date,
    pol.id AS line_id,
    pol.line_no,
    pol.material_id,
    m.name AS material_name,
    pol.unit,
    round(GREATEST(pol.quantity - COALESCE(rec.qty, 0::numeric), 0::numeric), 4) AS remaining_qty
   FROM purchase_orders po
     JOIN purchase_order_lines pol ON pol.purchase_order_id = po.id
     JOIN materials m ON m.id = pol.material_id
     LEFT JOIN LATERAL ( SELECT sum(ib.quantity) AS qty
           FROM inbound_batches ib
          WHERE ib.purchase_order_line_id = pol.id AND ib.deleted_at IS NULL) rec ON true
  WHERE po.deleted_at IS NULL
    AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
    AND (has_permission('module.purchasing.view'::text)
      OR has_permission('module.inbound.view'::text));

COMMENT ON VIEW public.po_receivable_lines_lookup IS
    'FIX-1 item 3:收货表单的【可收货采购单行】查名视图 —— 十列,【一列价都没有】(对照 po_receivable_lines 带 estimated_unit_price / pricing_formula_id / expected_assay)。它做了 GRN-1a 抬头明说留给以后的那个决定:让 inbound.view 也看得见订量,但只开收货表单要的那十列。属主权限 + 体内谓词 purchasing.view OR inbound.view;新读到它的只有 operations 与 warehouse。grn_discrepancies 【没有】跟着放宽 —— 那是单独一刀。';

GRANT SELECT ON public.po_receivable_lines_lookup TO authenticated;

COMMIT;
