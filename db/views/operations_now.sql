-- db/views/operations_now.sql
-- OPS-18(Phase 6):operations_now —— 全站"正在等人处理的事",一件一行;每一支按【读者】的码裁决。
-- ★ MES-8b-2(2026-10-17,MES-8 Step 0 Q20,Tim):支的定义搬进了 db/views/operations_arms_all.sql(连同原来的抬头,原样);
--   本视图只剩【按读者过滤】那一句与两列推导(permission_any · days_waiting)—— 列、列序与每一行都与搬之前逐字相同。
--   搬的理由:大屏的 floor_board() 要从同一份支的定义上【计数】,而读本视图的 SECURITY DEFINER 函数仍然只拿到调用者看得见的那几支
--   (has_permission 解析的是调用者)。加一支改 operations_arms_all.sql。
-- WHERE has_permission(a.permission) 按【调用者】逐支裁决:无权的支【整支缺席】,
--   arm_permission_widen 放宽、arm_permission_any 收窄(lib/modules.ts 的 allows() 同形)。
CREATE VIEW public.operations_now AS
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM operations_arms_all a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type))) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));

GRANT SELECT ON public.operations_now TO authenticated;
