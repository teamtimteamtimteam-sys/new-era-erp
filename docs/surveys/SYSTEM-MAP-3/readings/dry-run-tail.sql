-- SYSTEM-MAP-3 live dry run:迁移正文 + zzz_function_grants 重放之后,在同一笔事务里读几个数,然后 ROLLBACK(不提交)
SELECT 'PROOF|new_functions=' || count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname IN ('document_relation_arm_ids','document_detail_href','document_detail_hrefs',
   'document_chain_step_admits','document_chain_walk','bank_match_lines','generate_overtime_batch_code');
SELECT 'PROOF|arms=' || (SELECT count(*) FROM document_relation_arms) || ' arm_edges=' || (SELECT count(*) FROM document_relations WHERE kind = 'arm')
    || ' edges_total=' || (SELECT count(*) FROM document_relations);
SELECT 'PROOF|document_types=' || count(*) || ' with_detail_route=' || count(detail_route) FROM document_types;
SELECT 'PROOF|overtime_rows=' || count(*) || ' overtime_coded=' || count(code) FROM overtime_batches;
SELECT 'PROOF|grants anon_walk=' || has_function_privilege('anon', 'public.document_chain_walk(jsonb,integer,text,uuid)', 'EXECUTE')
    || ' auth_walk=' || has_function_privilege('authenticated', 'public.document_chain_walk(jsonb,integer,text,uuid)', 'EXECUTE')
    || ' anon_arms_select=' || has_table_privilege('anon', 'public.document_relation_arms', 'SELECT')
    || ' auth_arms_insert=' || has_table_privilege('authenticated', 'public.document_relation_arms', 'INSERT');
-- 以 tim@(cfo)的身份走三条链(只读),整笔仍会回滚
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SELECT 'PROOF|tim_purchasing_from_PO-2026-0003=' || coalesce(string_agg(w.step || ':' || w.code, ' ' ORDER BY w.step, w.code), '(none)')
  FROM document_chain_walk('{"steps":[{"keys":["purchase_order"],"filter":null},{"keys":["inbound_batch"],"filter":null},{"keys":["assay_result"],"filter":null},{"keys":["inbound_batch"],"filter":null},{"keys":["inbound_batch"],"filter":"payable"},{"keys":["payment_request"],"filter":null},{"keys":["payment_out"],"filter":null},{"keys":["bank_statement"],"filter":null}],"edges":[[0,1],[1,2],[1,3],[2,3],[3,4],[4,5],[5,6],[4,6],[6,7]]}'::jsonb, 0, 'purchase_order', '6d2ce1ff-728e-4594-bd7b-155002f54de7') w;
SELECT 'PROOF|tim_sales_from_SO-2026-0001=' || coalesce(string_agg(w.step || ':' || w.code, ' ' ORDER BY w.step, w.code), '(none)')
  FROM document_chain_walk('{"steps":[{"keys":["quote"],"filter":null},{"keys":["sales_order"],"filter":null},{"keys":["sales_order"],"filter":"reservation"},{"keys":["shipment"],"filter":null},{"keys":["container"],"filter":null},{"keys":["invoice"],"filter":null},{"keys":["payment_receipt"],"filter":null},{"keys":["credit_note"],"filter":null}],"edges":[[0,1],[1,2],[1,3],[2,3],[3,4],[1,5],[5,6],[5,7]]}'::jsonb, 1, 'sales_order', '0564cb00-6890-4dee-b9ba-0f8618540cf4') w;
SELECT 'PROOF|tim_people_from_PAY-2026-0001=' || coalesce(string_agg(w.step || ':' || w.code, ' ' ORDER BY w.step, w.code), '(none)')
  FROM document_chain_walk('{"steps":[{"keys":["attendance_period"],"filter":null},{"keys":["overtime_batch"],"filter":null},{"keys":["leave_request"],"filter":null},{"keys":["payroll_period"],"filter":null},{"keys":["journal_entry"],"filter":"payroll_payment"}],"edges":[[0,3],[1,3],[2,3],[3,4]]}'::jsonb, 3, 'payroll_period', 'b3784931-8c17-4f63-b6f3-7809b52bb1a2') w;
SELECT 'PROOF|tim_related_groups_PO=' || coalesce(string_agg(target_key || '=' || n, ' ' ORDER BY target_key), '(none)')
  FROM search_related('purchase_order', '6d2ce1ff-728e-4594-bd7b-155002f54de7');
RESET ROLE;
ROLLBACK;
SELECT 'PROOF|after_rollback_new_functions=' || count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname IN ('document_chain_walk','document_relation_arm_ids');
SELECT 'PROOF|after_rollback_arms_table=' || (to_regclass('public.document_relation_arms') IS NOT NULL);
