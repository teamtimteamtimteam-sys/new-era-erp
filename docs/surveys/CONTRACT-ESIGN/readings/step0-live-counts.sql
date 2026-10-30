-- CONTRACT-ESIGN Step 0:以 postgres(rolbypassrls = true)只数,基表行数是真行数
SELECT 'PROOF|' || json_build_object(
  'contracts', (SELECT count(*) FROM contracts),
  'contract_document_terms', (SELECT count(*) FROM contract_document_terms),
  'sales_settlements', (SELECT count(*) FROM sales_settlements),
  'employees_with_login', (SELECT count(*) FROM employees WHERE user_id IS NOT NULL),
  'buckets', (SELECT string_agg(id, ',' ORDER BY id) FROM storage.buckets),
  'bucket_count', (SELECT count(*) FROM storage.buckets),
  'storage_policies', (SELECT count(*) FROM pg_policies WHERE schemaname='storage' AND tablename='objects'),
  'contract_status_values', (SELECT string_agg(DISTINCT status::text, ',') FROM contracts)
)::text;
