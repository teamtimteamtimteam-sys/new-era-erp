-- db/views/processing_balance_monthly.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q8 · Q12,Tim):【月度物料平衡 —— 带门的外壳】。/operation/balance 与 /inventory 的物料平衡合计读它。
--   门 = processing_run_lookup 给同样这几个数(投入 · 产出 · 损耗,只有公斤)时的那一组码:module.processing.view、module.finance.view
--   或 module.inventory.view 任一 —— /inventory 今天就凭这三个之一读平衡合计,换一份真源不该把谁挡在外面。一个字的算术都不在这里。
--   属主权限:基视图从 authenticated 收回了;视图读视图走属主替换。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_balance_monthly WITH (security_invoker = off) AS
 SELECT month,
    scope,
    operation_type_code,
    line,
    line_key,
    basis,
    qty,
    runs
   FROM processing_balance_monthly_all
  WHERE has_permission('module.processing.view'::text) OR has_permission('module.finance.view'::text) OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.processing_balance_monthly IS
    'MES-5b-1:月度物料平衡,带门(module.processing.view / module.finance.view / module.inventory.view 任一)。算术全在 processing_balance_monthly_all。';

GRANT SELECT ON public.processing_balance_monthly TO authenticated;
REVOKE ALL ON public.processing_balance_monthly FROM anon;
