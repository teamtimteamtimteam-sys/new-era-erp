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
