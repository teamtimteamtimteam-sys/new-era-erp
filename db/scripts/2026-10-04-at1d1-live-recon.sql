-- db/scripts/2026-10-04-at1d1-live-recon.sql
-- AUDIT-TRAIL-1d-1 · 应收 / 应付的清单与总账对账(list_ledger_reconciliation)—— 只读,以 tim@(cfo)的会话读
--   (那支函数按读者的码过滤;属主身份没有 JWT,读到的是一次拒绝,不是一次测量)。前后各跑一次,两边都必须 unexplained 0.00。
BEGIN READ ONLY;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT s ->> 'side' AS side, s ->> 'list_base' AS list, s ->> 'ledger_base' AS ledger, s ->> 'unexplained_base' AS unexplained, s ->> 'agrees' AS agrees
  FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') s;
ROLLBACK;
