-- db/views/stock_rollforward_monthly.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q8,Tim):【库存的月度滚动 —— 带门的外壳】。/operation/balance 的第二块读它。
--   门与月度平衡同一组码(module.processing.view / module.finance.view / module.inventory.view 任一):只有数量,没有一分钱。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.stock_rollforward_monthly WITH (security_invoker = off) AS
 SELECT month,
    unit,
    opening,
    received,
    produced,
    consumed,
    sold,
    written_off,
    adjusted,
    voided,
    moved,
    closing
   FROM stock_rollforward_monthly_all
  WHERE has_permission('module.processing.view'::text) OR has_permission('module.finance.view'::text) OR has_permission('module.inventory.view'::text);

COMMENT ON VIEW public.stock_rollforward_monthly IS
    'MES-5b-1:库存的月度滚动,带门(module.processing.view / module.finance.view / module.inventory.view 任一)。算术全在 stock_rollforward_monthly_all。';

GRANT SELECT ON public.stock_rollforward_monthly TO authenticated;
REVOKE ALL ON public.stock_rollforward_monthly FROM anon;
