-- MES-5b Step 0 · read-only: can authenticated UPDATE processing_cost_entries directly, and under which policy?
-- postgres (rolbypassrls = true), catalog reads only; BEGIN READ ONLY … ROLLBACK.
BEGIN READ ONLY;
SELECT has_table_privilege('authenticated', 'public.processing_cost_entries', 'UPDATE') AS table_update,
       has_column_privilege('authenticated', 'public.processing_cost_entries', 'relieved_at', 'UPDATE') AS col_relieved_at,
       has_column_privilege('authenticated', 'public.processing_cost_entries', 'remitted_at', 'UPDATE') AS col_remitted_at;
SELECT polname, polcmd, pg_get_expr(polqual, polrelid) AS using_expr, pg_get_expr(polwithcheck, polrelid) AS check_expr
  FROM pg_policy WHERE polrelid = 'public.processing_cost_entries'::regclass ORDER BY polname;
SELECT tgname, tgenabled FROM pg_trigger WHERE tgrelid = 'public.processing_cost_entries'::regclass AND NOT tgisinternal ORDER BY tgname;
ROLLBACK;
