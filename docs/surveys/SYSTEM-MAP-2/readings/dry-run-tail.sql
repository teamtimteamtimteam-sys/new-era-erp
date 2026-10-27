-- SYSTEM-MAP-2 live dry run:迁移正文 + zzz_function_grants 重放之后,在同一笔事务里读几个数,然后 ROLLBACK(不提交)
SELECT 'PROOF|new_functions=' || count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname IN ('self_approval_allows','decision_gate_code','certificate_expiry_status','decision_arms',
   'waiting_decisions','waiting_mine','waiting_for_me','waiting_for_me_count','waiting_decision_reach');
SELECT 'PROOF|arms=' || count(DISTINCT m[1]) FROM regexp_matches(pg_get_viewdef('public.operations_arms_all'::regclass), '''([a-z_0-9]+)''::text AS item_type', 'g') m;
SELECT 'PROOF|decision_arms=' || count(*) FROM decision_arms();
SELECT 'PROOF|po_status_has_approval=' || EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.purchase_order_status'::regclass AND attname = 'approval_status');
SELECT 'PROOF|cert_view_rows=' || count(*) FROM supplier_compliance sc JOIN suppliers s ON s.id = sc.supplier_id WHERE sc.deleted_at IS NULL AND s.deleted_at IS NULL;
SELECT 'PROOF|grants self_approval_allows auth=' || has_function_privilege('authenticated', 'public.self_approval_allows(uuid,uuid,text,uuid)', 'EXECUTE')
    || ' anon_waiting=' || has_function_privilege('anon', 'public.waiting_for_me()', 'EXECUTE')
    || ' auth_waiting=' || has_function_privilege('authenticated', 'public.waiting_for_me()', 'EXECUTE')
    || ' cert_view_insert=' || has_table_privilege('authenticated', 'public.supplier_certificate_status', 'INSERT')
    || ' cert_view_select=' || has_table_privilege('authenticated', 'public.supplier_certificate_status', 'SELECT');
-- 以 tim@(cfo)的身份读一次,整笔仍会回滚
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|tim_todo=' || waiting_for_me_count() || ' tim_decisions=' || (SELECT count(*) FROM waiting_decisions())
    || ' tim_ops_rows=' || (SELECT count(*) FROM operations_now) || ' cert_status=' || coalesce((SELECT string_agg(status, ',') FROM supplier_certificate_status), '');
RESET ROLE;
ROLLBACK;
SELECT 'PROOF|after_rollback_new_functions=' || count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname IN ('waiting_for_me','waiting_decisions','decision_arms');
