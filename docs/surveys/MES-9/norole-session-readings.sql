-- MES-9 Step 0 — what a signed-in session holding NO role reads today (read-only; BEGIN READ ONLY … ROLLBACK).
-- Identity: SET LOCAL ROLE authenticated + request.jwt.claims for a random uuid that has no auth.users row, no user_roles, no employee —
-- exactly what a self-registered or a supplier account would be. RLS applies (authenticated does not bypass it).
BEGIN READ ONLY;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000c0de","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT 'WHO|' || current_user || '|uid=' || auth.uid() || '|codes=' || COALESCE(array_length(current_user_permissions(), 1), 0);
SELECT 'collection_promise_status|' || count(*) || '|customers=' || count(DISTINCT customer_id) || '|sum_base=' || COALESCE(sum(promised_amount_base), 0) FROM collection_promise_status;
SELECT 'approval_log_masked|' || count(*) || '|amount_visible=' || count(amount_ccy) || '|note_visible=' || count(note) FROM approval_log_masked;
SELECT 'metal_prices|' || count(*) FROM metal_prices;
SELECT 'pricing_settings|' || count(*) FROM pricing_settings;
SELECT 'user_roles|' || count(*) || '|users=' || count(DISTINCT user_id) FROM user_roles;
SELECT 'roles|' || count(*) FROM roles;
SELECT 'company_profile|' || count(*) FROM company_profile;
SELECT 'accounts|' || count(*) FROM accounts;
SELECT 'laboratories|' || count(*) FROM laboratories;
SELECT 'hr_settings|' || count(*) FROM hr_settings;
SELECT 'suppliers|' || count(*) FROM suppliers;
SELECT 'purchase_orders|' || count(*) FROM purchase_orders;
SELECT 'inbound_batches|' || count(*) FROM inbound_batches;
SELECT 'storage_objects_visible|' || count(*) || '|buckets=' || COALESCE(string_agg(DISTINCT bucket_id, ','), '-') FROM storage.objects;
SELECT 'operations_now|' || count(*) FROM operations_now;
SELECT 'my_profile|' || count(*) FROM my_profile;
RESET ROLE;
ROLLBACK;
