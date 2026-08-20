-- LOG-2a-fu1:闸抓到的两件,都是本刀自己的
--
-- ① 【xmodule】container_overview 是 security_invoker 视图,而它跨了三个模块:
--    purchasing(箱子自己)+ sales(shipments / sales_orders)+ suppliers(货代名字)。
--    这正是 OPS-14 那五处缺陷的形状:**行不会报错,它们会消失** ——
--    一个持 purchasing 但不持 sales 的读者,看到的 shipment_count / customer_count
--    会【少】,而且没有任何东西说一句话。
--    按 AGENTS.md 的补救表:这里借来的是【派生事实】(计数、一个名字、一个里程碑),
--    所以走 (a) —— 属主权限,并把读者自己的模块判据写进视图体。
--    属主权限不会放宽模块边界:has_permission() 是 SECURITY DEFINER,解析的是
--    【调用者】,与视图属主是谁无关。
--
-- ② 【B2】next_container_code 是 DEFINER、无调用者检查、且可执行。
--    它的孪生兄弟 next_shipment_code 的处理是现成的:从 authenticated 收回 EXECUTE,
--    并在 DEFINER_NO_CHECK_ALLOWED 里写明理由。照抄,不另发明。
BEGIN;

DROP VIEW public.container_overview;

CREATE VIEW public.container_overview
WITH (security_invoker = off) AS
SELECT
    c.id,
    c.code,
    c.container_number,
    c.vessel,
    c.voyage,
    c.departure_date,
    c.bl_number,
    c.lane_id,
    c.forwarder_id,
    f.legal_name AS forwarder_name,
    (SELECT count(*) FROM shipments s WHERE s.container_id = c.id)::integer AS shipment_count,
    (SELECT count(DISTINCT o.customer_id)
       FROM shipments s JOIN sales_orders o ON o.id = s.sales_order_id
      WHERE s.container_id = c.id)::integer AS customer_count,
    (SELECT m.milestone FROM container_milestones m
      WHERE m.container_id = c.id ORDER BY m.event_date DESC, m.recorded_at DESC LIMIT 1)
        AS latest_milestone,
    (SELECT m.event_date FROM container_milestones m
      WHERE m.container_id = c.id ORDER BY m.event_date DESC, m.recorded_at DESC LIMIT 1)
        AS latest_milestone_date,
    COALESCE(ls.checklist_state, 'no_lane') AS lane_checklist_state,
    (SELECT count(*) FROM container_documents d
      WHERE d.container_id = c.id AND d.status = 'pending')::integer AS documents_pending
FROM public.containers c
LEFT JOIN public.suppliers f ON f.id = c.forwarder_id
LEFT JOIN public.lane_checklist_status ls ON ls.lane_id = c.lane_id
WHERE c.deleted_at IS NULL
  -- 【属主权限视图必须自己带门】—— 这一句就是那扇门。
  AND has_permission('module.purchasing.view'::text);

COMMENT ON VIEW public.container_overview IS
'LOG-2a:箱子一行 —— 发货单数、涉及几个客户、最新里程碑、清单状态、待收单据数。
【lane_checklist_state 原样带着三种状态】(not_defined / defined_empty / defined,外加没挂航段的 no_lane):
把 not_defined 折叠成"0 条待收",就是把"没人看过"显示成"齐了"。
【属主权限,不是 invoker(LOG-2a-fu1)】:它跨 purchasing + sales + suppliers 三个模块,
invoker 语义下一个只持 purchasing 的读者会【静默地少看到几条发货单】——
计数会小,而没有任何东西报错(OPS-14 那五处缺陷的形状)。
门写在视图体里那一句 has_permission(''module.purchasing.view'');
has_permission 是 DEFINER、解析的是调用者,所以属主权限并不放宽模块边界。';

GRANT SELECT ON public.container_overview TO anon, authenticated, service_role;

-- ② 取号器收权 —— 与 next_shipment_code 同处理
REVOKE EXECUTE ON FUNCTION public.next_container_code(date) FROM authenticated;

COMMIT;
