-- db/views/grn_discrepancies.sql
-- GRN-1a:收货差异 —— 一条【挂了采购行的】收货一行。
--
-- NOTE: introduced by db/migrations/2026-08-17-grn1a-receiving-discrepancy-db-half.sql.
-- ★ MES-8a(2026-10-16):定义本身搬进了底视图 db/views/grn_discrepancies_all.sql(一字未改,那里的抬头记着它的全部理由与三个
--   "不下断言"的地方);这里只剩【门】:module.purchasing.view。列集与原来逐字相同,所以迁移走 CREATE OR REPLACE,依赖它的视图不必重建。
--   为什么要分两层:供应商评分卡要以 module.suppliers.view 的身份读同一份定义,而属主权限的函数读不穿一道按调用者解析的谓词。
-- First-run script. Re-running requires DROP VIEW first.

CREATE VIEW public.grn_discrepancies WITH (security_invoker = off) AS
 SELECT batch_id,
    batch_code,
    arrival_date,
    supplier_id,
    supplier_name,
    po_id,
    po_code,
    po_status,
    line_id,
    line_no,
    ordered_material_id,
    ordered_material_code,
    received_material_id,
    received_material_code,
    ordered_qty,
    ordered_unit,
    received_qty,
    received_unit,
    declared_qty,
    line_received_qty,
    line_receipt_count,
    line_delta_qty,
    line_delta_pct,
    declared_delta_qty,
    assay_beyond_tolerance,
    assay_metals_compared,
    deep_discharge_judged,
    deep_discharge_actual,
    deep_discharge_contradicted,
    kinds
   FROM grn_discrepancies_all
  WHERE has_permission('module.purchasing.view'::text);

COMMENT ON VIEW public.grn_discrepancies IS
    'GRN-1a:收货差异,一条【挂了采购行的】收货一行 —— 订量、实收、申报量、三个差额,以及 kinds 点名哪里不对(short / over / declared_vs_actual / material_mismatch / assay_beyond_tolerance / deep_discharge_contradicted)。【三个阈值现读 receiving_settings,一个数都没写死】。
【它活过关单】—— po_receivable_lines 只收 confirmed/receiving,purchase_order_status 在【单】上汇总(一行超一行短可以正好抵成 100%),两个现成读者都在短交刚成为问题的那一刻消失。本视图两者都不做。
【没挂采购行的批次整行缺席,不是一行零】(work_order_fulfilment 的 has_plan 那一条:没估过 ≠ 估了零)。同理 assay_beyond_tolerance 在两侧缺任何一侧时是 NULL 而不是 false,declared_delta_qty 在没记申报量时是 NULL 而不是 0。
【short/over 是采购行级的事实,挂在该行的每一条收货上】:分批到货不该被报成短交,所以两者都比【累计】;而一条 short 出现两次的意思是"这一行短了、它有两次收货",要按行计数请 DISTINCT line_id。short 只在 closed/cancelled 时报(开着的单"少"只是"还没收完"),over 任何状态都报(它当场就占了地方、欠了钱)—— 与 processing_settings 那两个工单阈值逐字同一条。
【material_mismatch 是告警,永远不是拒绝】—— 换料是可以谈成的正当场景;但它必须【被点名】,因为它也正是"谎报货物性质"在技术上的样子。
★【PROC-1B-iii:deep_discharge_contradicted】★ 采购时判断(purchase_order_lines.deep_discharge_judgement_code)vs 实际到货(inbound_batches.deep_discharge_actual_code)。**两个值都活着,谁也不覆盖谁** —— 不一致正是 Tim 拿去跟供应商谈的东西。【它同样是告警,永远不是拒绝】:R3 明令这个判断不拦收货,fixture 168 钉着"实际与判断矛盾的收货仍然成功"。
【一次差异要【两次互相矛盾的主张】】任一侧是 NULL(这一行比这条轴还老)【或】是 not_assessed(看了但没下判断)时,deep_discharge_contradicted 是 **NULL,不是 false,更不是 true** —— 与 assay_beyond_tolerance 同一条,只是取值集合更宽。判据读字典的 is_a_claim 列,**不在视图里写死 ''not_assessed'' 这个字面量**。
★【"未评估 vs 不能" 与 "没设 vs 不能" 分得开,而分辨力【不在那个布尔上】】★ 两者的 contradicted 都是 NULL。所以视图【同时露出两侧的原始码】deep_discharge_judged / deep_discharge_actual:没设是 NULL,看了没判是字面量 ''not_assessed''。屏幕上是两个不同的字。只露布尔会把这两件事并成一件。
【两个字典 LEFT JOIN,不是 JOIN】内连接会让没记判断的收货行【整行消失】,那是把"没有这个差异"变成"不存在"。
【属主权限 + module.purchasing.view】:跨 inbound × purchasing 两个模块,invoker 会让无权那一侧的行被 RLS 静默丢掉、内连接把整行带走,读者得到的是"没有差异"而不是"受限"(OPS-14)。谓词取 purchasing 是因为【订量本来就只在那道门后面】(po_receivable_lines / purchase_order_status 同码),而线上每个持 purchasing.view 的角色都持 inbound.view —— 实测,不放宽任何一行。';

GRANT SELECT ON public.grn_discrepancies TO authenticated;
