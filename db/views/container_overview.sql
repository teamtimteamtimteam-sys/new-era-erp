-- db/views/container_overview.sql
-- LOG-2a / fu1。定义取自线上 pg_get_viewdef;security_invoker 显式补回(pg_get_viewdef 不吐 reloptions)。

CREATE VIEW public.container_overview
WITH (security_invoker = off) AS
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
  WHERE c.deleted_at IS NULL AND has_permission('module.purchasing.view'::text);

COMMENT ON VIEW public.container_overview IS
'LOG-2a:箱子一行 —— 发货单数、涉及几个客户、最新里程碑、清单状态、待收单据数。
【lane_checklist_state 原样带着三种状态】(not_defined / defined_empty / defined,外加没挂航段的 no_lane):
把 not_defined 折叠成"0 条待收",就是把"没人看过"显示成"齐了"。
【属主权限,不是 invoker(LOG-2a-fu1)】:它跨 purchasing + sales + suppliers 三个模块,invoker 语义下一个只持 purchasing 的读者会【静默地少看到几条发货单】—— 计数会小,而没有任何东西报错(OPS-14 那五处缺陷的形状)。门写在视图体里那一句 has_permission。';

GRANT SELECT ON public.container_overview TO anon, authenticated, service_role;
