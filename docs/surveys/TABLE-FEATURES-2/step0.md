# TABLE-FEATURES-2 — Step 0 (2026-10-26)

Started from `a27417a137bb760b13a766ce727c8c5f7f0a99ca` (HEAD = origin/main = ls-remote, tree clean). Survey files: `survey-totals.md` · `survey-presets.md` · `survey-overflow.md` (read-only; no browser sweeps, no builds).
Part 1 readings: `readings/closeout-prod-check.txt` (TF1_CLOSEOUT_EXIT=0, 7/7; run 1 = probe faults, `closeout-prod-check-run1-probe-faults.txt`), `readings/readback-closeout.txt`.

## Measured facts that shape the scope

- **PostgREST aggregates are off.** As `postgres` (`rolbypassrls = t`): `pg_db_role_setting` holds no `pgrst.*` setting for any role or the database, and `authenticator`'s rolconfig has none → default off. A database-computed total therefore means SQL functions → **a migration** (backup, dry run, window).
- **Year end:** live `finance_settings` = `fy_end_month 12 · fy_end_day 31 · first_fy_end NULL` (as postgres). SELECT policy is `has_permission('module.finance.view')` only (`pg_policy`, = `db/tables/finance_settings.sql:130-133`) → 7 of the 11 preset pages cannot read it today.
- **Reversals are positive mirror rows:** `reverse_payment_internal.sql:56-63`, `reverse_expense_internal.sql:143-152` insert a copy with the same sign, status posted; the original flips to `reversed`.
- **Commissions:** `per_tonne` rows store a per-tonne rate in `amount_ccy` (`commission_agreements.sql:62-67`).
- **Overflow:** both toolbars already have `flex-wrap` (`OrdersToolbar.tsx:33`, `InboundToolbar.tsx:77`); the select's own min-content (longest supplier name) is the cause; the bound that cures it (`max-w-full` on the select) is banned by `docs/variant-c-spec.md:474` §4.1d (Tim 2026-09-11), restated at `:1384`.

## Questions put to Tim and the estimate: see the Step 0 report in the session (copied into the hand-back after the rulings).
