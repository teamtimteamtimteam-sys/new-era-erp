# TABLE-FEATURES-2 — how a footer total is built (the pattern every list follows)

Rulings (verbatim at `docs/table-features.md`, Tim 2026-10-25 Q1 / Q5 and Tim 2026-10-26 Q1–Q9):
- Footer totals on the 21 amount lists (bank statements, close and supplier statements get none). A footer totals **every row matching the filters**, calculated **by the database**. **One total per currency.** If any amount in the set is hidden from the reader, that total reads 「受限」.
- **No total on any balance-type column** (opening/closing balances, running totals, a price such as inventory avgPrice).
- **Totals are net:** a reversal cancels its original, so a reversed pair adds 0, agreeing with the ledger. Where a reversal is a positive **mirror row** (payments, expenses, journal reversal entries), the mirror counts **negative**. Where a reversed document is only flagged (freight, bank transfers, electricity allocations, WHT remittances, void invoices), it is **excluded** (adds 0).
- Commissions: only `fixed_amount` rows, one total per currency. Payments: "received" and "paid" separately (grp), not netted.
- 「受限」 on lists where the reader cannot see some rows is decided **per reader** (a permission check), not by counting rows they cannot see.

## Database side — one function per list
- File `db/functions/list_totals_<list>.sql`: a few `--` header lines (what, which filters it mirrors with file:line, gate code, net rule), then the function in **`pg_get_functiondef` form**, ending with `$function$;` and **no trailing newline**. Reference: `db/functions/list_totals_payments.sql`.
- Signature: `public.list_totals_<list>(<the page's filters, each with DEFAULT NULL::type>)` → `RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)`. `LANGUAGE plpgsql`, `STABLE`, `SET search_path TO 'public', 'pg_temp'`. **SECURITY INVOKER** (the default) unless the page itself reads through a definer RPC (then DEFINER with the same `require_permission` first — never a definer without a caller check).
- First statement: `PERFORM require_permission('<the page gate code>');` — the code the page's `requireModule(MOD.x)` / guard resolves to (read `lib/modules.ts`).
- Read **the same relation the page reads** (the `_masked` view / status view / RPC body), never a base table the reader cannot fully see (journal: `journal_lines_masked`, never `journal_lines`).
- Apply **exactly** the page's filters, including fixed predicates (`deleted_at IS NULL`, `superseded_by IS NULL`, `status <> 'submitted'` done in JS today …). A filter the page resolves in JS must be done in SQL.
- `measure` = a short name the page maps to its column key. `currency` = the row currency; NULL only when the column has one fixed currency stated in its header (the page passes it as `fixedCurrency`). Base-currency columns: return the base code (`(SELECT code FROM currencies WHERE is_base)`).
- `restricted`: true when any amount in that (grp, currency, measure) set is hidden from the reader; then `total` is **NULL**. Whole-reader masking → `NOT has_permission('<data code>')`. Per-row masking → `bool_or(<masked col> IS NULL AND <the row is not legitimately NULL>)`. When restricted for the whole reader and zero rows are visible, still return one row per measure (currency NULL, total NULL, restricted true) — restricted is never expressed as zero rows. An empty, unrestricted set returns zero rows (the page shows no footer).
- Round totals to 2 dp. Qualify every column (plpgsql OUT-param names `currency`, `total` … clash otherwise).
- Validate the body **against live, rolled back**, as a real session (never COMMIT):
  ```
  psql "host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres" -X -v ON_ERROR_STOP=1 <<'SQL'
  BEGIN;
  \i db/functions/list_totals_<list>.sql
  SET LOCAL ROLE authenticated;
  SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
  SELECT * FROM list_totals_<list>();
  ROLLBACK;
  SQL
  ```
  (634c00f9… is tim@, role cfo.) Compare against a direct sum as postgres for the same filter.

## App side
- In the page's `*Rows.ts` (or the page), add `<list>Totals(supabase, params)`: `shapeListTotals(mustRows(await supabase.rpc('list_totals_<list>', {...}), '<list> totals'))` (`lib/listTotals.ts`), passing the **same parsed params** the list query uses (`|| undefined` for empty filters). The RPC name will not type-check until `lib/database.types.ts` is regenerated after the migration — that is expected; nothing else may fail tsc.
- The page passes `totals` to its client `*Table`; the table adds `footer={() => totalsFooterRows(totals, { <measure>: '<colKey>' }, t[, fixedCurrency])}` (`app/components/ui/list-totals.tsx`). The first column must not carry a total (DataTable puts the label there).
- Messages: use only `table.totals.*` and `common.restricted`. **Do not edit `messages/*.ts`**; list any key you need in your report.
