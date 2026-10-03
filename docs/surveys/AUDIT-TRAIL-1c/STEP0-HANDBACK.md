# AUDIT-TRAIL-1c · Step 0 hand-back (stop gate)

Part of v1.4.33, not yet released.

**Opening check passed** at **2026-10-03 12:27:47 CST** (this session's first command): tree clean; `HEAD` = `origin/main` =
`ls-remote` = `24b913fdb9149bed81f527fb60b6371e1e3c299f`. Step 1 then committed one docs change (`e0a7b20e`, "AT-1b-3 close-out:
window closed"). Step 0 itself made no code edit, no migration and no database write.

**How it was measured.** Five read-only survey agents; their notes are kept next to this file:
- `A-finance-docs.md` — journals, invoices, credit notes, the receivables sale, the payables batch, payments, payment requests
  (with transfers and WHT results), expenses, freight, finance attachments;
- `B-assets-bank-gst-fx-contracts.md` — fixed assets, bank statements and reconciliation, GST, FX rates, packs, contracts;
- `C-settings-periodend.md` — the shared `finance_settings` row (Q25), period-end and settings pages, the operations with no page;
- `D-masking.md` — column masking, bank details, payroll figures, row rules, the live role matrix;
- `E-wording-timing.md` — event wordings, field labels, and the measured run times of AT-1a … 1b-3.

Every live figure was read as **`postgres` (`rolbypassrls = true`) on base tables** (relkind `r`), inside `BEGIN READ ONLY … ROLLBACK`
or through the Management API with SELECT only. Each claim in those files is marked Measured (query or file:line) or Inferred.

---

## 1. Step 1 — the 1b-3 close-out, item by item

**The broken window** is recorded in `docs/forward-queue.md` item 26 (the 1b-2 format), committed and pushed as `e0a7b20e`:

| | value | source |
|---|---|---|
| start | **2026-10-03 10:31:01 CST** | `db/migration-windows.tsv` (last row, `2026-10-03-at1b3-trails-master-data-and-tools.sql`) |
| end, lower bound | **2026-10-03 12:24:10 CST** | `git reflog show --date=iso refs/remotes/origin/main`: `24b913fd … {2026-10-03 12:24:10 +0800}: update by push` |
| end, upper bound | **2026-10-03 12:27:47 CST** | this session's first command (`date` printed it). It rests on your "deployed", **not** on a Vercel reading |
| window | **at least 1 h 53 min 09 s, at most 1 h 56 min 46 s** | |

**Read-only checks the 1b-3 report did not mention:**

| | item | result | evidence |
|---|---|---|---|
| a | trails on materials, locations, metal prices, formulas + terms requests, the three threshold panels (M5 · M6, own columns only) | ✅ | `<AuditTrail>` at `app/materials/[id]/edit/page.tsx:129`, `app/inventory/locations/[id]/edit/page.tsx:92`, `app/tools/pricing/metal-prices/[id]/edit/page.tsx:77`, `app/tools/pricing/formulas/[id]/edit/page.tsx:161`; panels `app/operation/orders/page.tsx:122`, `app/tools/pricing/metal-prices/page.tsx:243`, `app/purchasing/discrepancies/page.tsx:126` (all `id="true"`, M5). Registry `db/functions/trail_subjects.sql:80-90`; `root_columns`: processing `['wo_input_overrun_pct','wo_output_shortfall_pct']`, pricing `['metal_price_change_warn_pct']`, receiving `['grn_short_pct','grn_over_pct','grn_assay_tolerance_pct']` — exactly the columns each panel's action updates (`app/operation/orders/thresholdActions.ts:39`, `app/tools/pricing/metal-prices/thresholdActions.ts:38`, `app/purchasing/discrepancies/thresholdActions.ts:51`). Terms requests and their approvals are `pricing_formula` members (`trail_subject_members.sql:218-219`). `record_trail.sql:83,165,242` applies `root_columns`; fixture 240 arm S raises if another column reaches a panel (`db/fixtures/240-…sql:382-388`) |
| b | Q13: the location save writes only what changed, in one call | ✅ | `app/inventory/locations/actions.ts:51` — one `supabase.rpc('save_storage_location', …)` for both create and edit; `db/functions/save_storage_location.sql:36-39` updates the row only `IS DISTINCT FROM` the new values; `:42-43` deletes only unticked classes; `:46-49` inserts only newly ticked ones; `:27` `require_permission('module.inventory.edit')` first. (The `.from('storage_locations').update({ is_active })` at `actions.ts:103-104` is the separate activate / deactivate toggle, not the save) |
| c | Q3: a personal task's trail is visible to whoever can open the task; the change history section is replaced | ✅ | `app/tools/tasks/[id]/page.tsx:236` draws `<AuditTrail subject="task">` unconditionally (no `task_type` branch); the page reads `tasks` under RLS (`:39-45`, `notFound()` when not readable), and the trail's root rule is the same `tasks` policy — `module.tasks.view` AND (team OR own OR `view_all`) (`db/tables/tasks.sql:90-99`). `ChangeHistory.tsx` / `ChangeHistoryTable.tsx` deleted in `24b913fd` (`git log -- app/tools/tasks/[id]/ChangeHistory.tsx`) |
| d | deleted customers, suppliers, materials, formulas, sales orders, quotes, POs: read-only with "Deleted on DD/MM/YYYY by <name>" (date only where no person) for `data.view_deleted`; a named refusal, not a 404, for everyone else | ✅ | `requireDeletedAccess` + `<DeletedBanner>` on all seven pages: `app/sales/customers/[id]/page.tsx:127,249`, `app/suppliers/[id]/edit/page.tsx:75,207`, `app/materials/[id]/edit/page.tsx:57,112`, `app/tools/pricing/formulas/[id]/edit/page.tsx:53,135`, `app/sales/orders/[id]/page.tsx:45,133`, `app/sales/quotes/[id]/page.tsx:70,147`, `app/purchasing/orders/[id]/page.tsx:85,671`. Refusal: `app/components/moduleGuard.tsx:158-161` → `common.deletedDenied` "This record has been deleted." (`messages/en.ts:1198-1199`). Banner: `app/components/trail/EndedBanner.tsx:43-44` picks `banner.deleted` "Deleted on {date} by {who}" or `banner.deletedDate` "Deleted on {date}" (`lib/trail/text.ts:402-403`) from the `deleted_records` row (`EndedBanner.tsx:84-87`) |
| e | `/settings/deleted` lists the four added kinds; sales-order and quote links work; the NEW page shows proper labels | ✅ | `app/settings/deleted/page.tsx:81-93` `KIND_HREF` (11 kinds incl. `sales_order` → `/sales/orders/{id}`, `quote` → `/sales/quotes/{id}`, `customer`, `supplier`, `material`, `pricing_formula`); `:95` the filter kinds are that map's keys; labels through `t('deleted.kind.' + kind)` (`:149,200`) and both message files carry all eleven: `messages/en.ts:7065-7077` (Customer · Supplier · Material · Pricing formula …), `messages/zh.ts:6859-6872`. The raw keys (`deleted.kind.customer`) were the OLD page in the window only |
| f | the four Step 0 labels fixed | ✅ | read from the committed `lib/trail/catalogue.generated.ts` (`TRAIL_FIELDS`, parsed with node): `task_nodes` / `task_participants` / `task_history.task_id` → **Task**; `metal_prices.source` → **Source**; `processing_settings.wo_input_overrun_pct` → **Input overrun (%)** (`wo_output_shortfall_pct` → Output shortfall (%)); `pricing_settings.notes_en` → **Notes (EN)** (`notes_zh` → Notes (ZH)). The strings "Make this a team task", "Choose a source", "Wo input overrun %" and "Notes en" occur **0** times in the catalogue (they survive only in the generator's comment, `scripts/gen-trail-catalogue.mjs:273-274`) |
| g | the three rendering defects found in the live proof | ✅ (with one note) | see below |
| h | change-log §9 covers the 1b-3 subjects and the deleted-record pages; the forward queue marks AT-1b complete | ✅ | `docs/change-log.md:222-225` (intro), `:252-259` (eight table rows), §9.5 `:341-350`, §9.7 `:417-435`, §9.8 `:455-465`, §9.9 (M2 · M5 · M6 users), **§9.10 `:491-509`** (deleted records). `docs/forward-queue.md` "✅ AT-1b … 三刀都做完了(1b-3,2026-10-03)" and "✅ AT-1b-3(2026-10-03)" |

**g — the three rendering defects** (`docs/handbacks/AUDIT-TRAIL-1b-3.md` decisions 26–28). I re-ran each case through the committed
renderer (`lib/trail/render.ts` `buildEntries`, a scratch harness; read-only):

| # | what it was | the fix | re-run today |
|---|---|---|---|
| 26 | the proof's material had its spec edited **and** was deleted in one operation; the "Material deleted" block swallowed the spec edit | deletion blocks list the other changed columns: `render.ts:2139` (material), `:2189` (metal price), `:2239` (formula) — `changeLines(…, new Set(['deleted_at']))` | "Material deleted" + "Spec / Description: (empty) → Shredded". Golden: `scripts/check-trail-wording.mjs:628` |
| 27 | the proof's class swap (one class added, one removed) netted to nothing | `netReplace` nets a pair only when the DELETE came **before** the INSERT (`render.ts:989-1000`); `splitAtFirstRemoval` splits a block at the first removal (`render.ts:2106`, used `:2129,2162`) | an insert-then-delete of one class renders "Allowed material classes changed · 1 added, 1 removed". Goldens: `check-trail-wording.mjs:603,623` |
| 28 | a deleted task step said nothing (the old section said "un-ticked") | a deleted step lists its target date and tick state — from the step row (`render.ts:2342`) or, before the log, from the history row's `old_node_*` (`:2398`) | logged: "Step deleted · Lunch" + "Target date: 05/10/2026", "Done: No"; pre-log: "Previous step target date: 05/10/2026", "Step was ticked: No" |

**Note on g (reported, not fixed):** the 1b-3 hand-back §4 says the wording check gained "goldens for the three". It has goldens for 26
and 27 only. **Decision 28 has no golden** — `grep "Step deleted\|Step was ticked\|node_removed" scripts/check-trail-wording.mjs` → 0
hits; arm ⑦ only sweeps `node_removed` for machine tokens (`:692-697`), which would not notice the target date and tick state going
missing again. The fix itself is present and renders correctly (above). Recommended: add that golden in AT-1c-1 (Q34).

**i — decisions 1b-3 took without asking** (`docs/handbacks/AUDIT-TRAIL-1b-3.md` §8, titles only):
1. A formula's own creation and payable metals registered before the log, alongside its history.
2. A team task's step creation and tick stamp registered alongside `node_added` / `node_done`; participants not registered before the log.
3. The threshold panels have no pre-log history.
4. `deleted_records` takes "who" for customers, suppliers, materials, formulas from the change log, never from `updated_by`.
5. `save_storage_location` is SECURITY DEFINER with `require_permission('module.inventory.edit')` first.
6. Its three nullable parameters carry `DEFAULT NULL`.
7. One event, two rows: the change-log row speaks after the log, the history row before it.
8. Task steps and participants are key events.
9. A location's code and a terms request's label are typed text in the title.
10. Terms-request wording follows the page's "Send to the CFO".
11. "Made a team task" for `promoted_from_personal`.
12. `materials.unit` Chinese values read in English.
13. The metal price's label is "Price (USD/t)".
14. Deleted records: the page's own module guard first, then `requireDeletedAccess`.
15. Read-only = `<EndedFieldset>`; the PO's action row is not drawn for a deleted order.
16. A deleted quote is read from `quotes`.
17. A deleted customer's credit section says the position is not worked out.
18. `/settings/deleted` links written-off batches and reversed runs too.
19. The panels' trails sit directly under each panel.
20. The task page's dead message keys deleted.
21. `check-trail-wording.mjs` gained arm ⑦.
22. The smoke's `trail` assertion gained `emptyOk` for the three panels.
23. `survey-phone.mjs` gained `--paths=`.
24. `scripts/probe-at1b3.mjs` (new).
25. The migration's proof reads `deleted_records` as tim@ and each task as its owner's account.
26. A deletion keeps the other changes made with it.
27. A replaced set is said in the order it happened.
28. A deleted step lists its target date and tick state.
29. `survey-phone.mjs --paths=` used for the four deleted records.

**Assertions in the brief I measured:** approvals ON (finance / cfo / 1,000) and 7 accounts all enabled were **not re-read** this session
(no query of `finance_settings` or `auth.users` was needed — Step 0 wrote nothing); the 1b-3 hand-back's after-reading (11:42:20, as
`postgres`) is the latest measurement: approvals ON, 7 accounts, 0 disabled. "238 tables recorded" — not re-read; survey A/B/C each
confirmed every AT-1c table carries `zzz_change_log` (`information_schema.triggers`, as postgres).

---

## 2. What grilling changed in this scope

1. **Every AT-1c trail is 100 % pre-log on live today.** No finance, contract or settings table has a single `change_log` row; every
   finance row predates 28/09/2026 23:58 (A §0.3, B, C §B — `count(*)` on `change_log` by table, as postgres). Only the smoke
   harness's temporary contracts left rows. So **what is registered in `trail_prelog_sources` is all anyone will see at launch**, and
   `approval_log` holds **0** rows for every finance subject type; `journal_requests`, `invoice_requests`, `payment_requests`,
   `bank_transfers`, `wht_remittances`, packs, contracts, terms requests and disposal requests are all **empty** (A §0.4, B).
2. **Five lifecycle stamps are the only record of live events** and must be registered as Q11-style exceptions: `invoices.voided_at /
   voided_by` (all 3 live voids predate invoice requests), `freight_documents.reversed_at / reversed_by` (all 4 freight documents are
   reversed), `payment_requests.paid_at / paid_by` (no history records execution), `bank_statements.reconciled_at / reconciled_by`
   (BS-2026-0002 is reconciled with **no** `bank_reconciliations` row), `expense_claims.decided_at / decided_by` (2 decided claims,
   **0** `approval_log` rows). → Q9.
3. **A reversal journal points at the original journal, not the document** — all 13 live reversal pairs have `source_id = original
   journal id` (`reverse_journal_entry_internal.sql:59-70`). A document reaches its reversal only through the original's `reversed_by`
   (an M4 up hop, the batch-trail precedent). Side effect found: the journal page's "Source" link on reversal entries points at a
   journal id as if it were a batch or run (`app/finance/sourceLinks.ts:70-73`; 2 purchase reversals, 1 allocation reversal on live). → Q15.
4. **Q25 cannot be built as ruled without one new registry extension.** The lock's trail must show month close and reopen, but
   `period_closes` has no column pointing at `finance_settings` and vice versa, so neither a down hop nor an M4 up hop reaches it
   (`record_trail.sql:116-128`). The same is true of `finance_settings_history` under the approval-policy panel. → **M7** (Q3).
5. **Q25's home is contested.** The brief lists it under AT-1c; `docs/forward-queue.md:6571-6572` lists it under AT-1d. The
   approval-policy panel lives on `/settings/approvals` (guard `action.manage_permissions`, `app/settings/approvals/page.tsx:60`),
   which is a settings page, not a finance page. → Q2.
6. **Four Q21 gaps in finance.** Deleted bank statements 404 (detail and reconcile pages; the list hides them, `statements/page.tsx:49`) —
   AT-0's survey said otherwise. Withdrawn FX rates 404 (`fx/[id]/edit/page.tsx:33`). The payables page shows a **written-off batch
   with no sign it was written off** (9 of 24 live inbound batches; `inbound_batch_lookup` has no deleted filter). Every other ended
   finance record (reversed journal, payment, expense, freight; voided invoice; disposed asset; superseded pack; filed GST period) already
   opens. → Q6, Q7, Q5.
7. **The equipment subject cannot be reused for the finance asset page.** `equipment` is gated on processing; the finance page needs a new
   `fixed_asset` subject on the same root (the `supplier` / `forwarder` precedent of two subjects on one table). → Q10.
8. **Employee names in references bypass the ActorName rule.** `trail_actor` restricts names for readers without `module.hr.view`, but
   `trail_ref_label`'s employees branch returns the name unchecked (`db/functions/trail_ref_label.sql:60-62`, rendered at
   `lib/trail/render.ts:263`). §9.7 says "every person-valued field goes through the same function". Finance tables carry many such
   columns (`employee_id` on claims, payroll lines, expenses, payments, payment requests). No current finance reader is affected (all hold
   hr.view). → Q12.
9. **Individual net pay reaches the GL unmasked.** `pay_payroll_lines` posts one line per employee with net pay and a memo of code + legal
   name (`pay_payroll_lines.sql:85-90`); `journal_lines` is unmasked (standing decision 1). cto and gm (1 holder each) hold finance.view
   without `data.view_pay`. → Q11.
10. **Batch runs have no run table.** Revaluation, depreciation and processing remittance each write **one journal with `source_id`
    NULL**, identified by `source_type`; bulk FX writes no run row at all — its only identity is the transaction. `ListTrail` is hard-typed
    to lane / port / licence (`app/components/trail/ListTrail.tsx:28-33`). → Q16, Q17.
11. **Size.** About **27 subjects**, **558** newly shown columns on 48 tables plus **76** never hand-checked columns on 11 already-shown
    tables, **54** enum values with no English, and **130–170** new wordings. AT-1c is the largest cut of the four. → Q1.

**Assertions I measured as false or out of date**
- ops-finance §3B: "`/finance/bank/statements` lists deleted statements" — **false**, it filters them out (`statements/page.tsx:49`).
- ops-finance finding 8: "`fx_rate_history` is read on the fx pages" — **false**: no fx page shows it (B).
- ops-finance M10 / M11: remitting or relieving processing costs writes `processing_cost_entry_history` — **false**
  (`log_cost_entry_change.sql:17-26` logs create / delete / restore and amount / type / estimate changes only).
- `app/finance/payables/[batchId]/page.tsx:55-57` comment "cfo has no inbound.view" — **stale**: every finance.view role (admin, auditor,
  cco, cfo, cto, finance, gm) now also holds the inbound, output, processing, purchasing, logistics, hr, suppliers, customers and pricing
  view codes (A §0.7, D §5; `role_permissions` × `user_roles` with `revoked_at IS NULL`, as postgres).
- ops-finance finding 7: "`approval_log` 15 rows" — the finance subject types hold **0** rows today.
- The 1b-3 hand-back §4 "goldens for the three" — two, not three (§1 g note).

**Measured true:** every AT-1c table has the change-log trigger; every AT-1c actor column holds a login id (no M2); every key is
`id uuid` except the singletons (`finance_settings`, `company_profile`: `id boolean`, M5); `change_log_mask_gaps()` = `{"gaps": [],
"examined_tables": 27, "examined_columns": 81}` (D §1).

---

## a. Registry: every subject (root · members · host · M1–M6)

View code is `module.finance.view` (`requireModule(MOD.finance)`, `lib/modules.ts:140,365`) unless stated. "M4" = an upward hop (a
journal via `entry_id` / `journal_entry_id`, a reversal via `reversed_by`). Full member tables with fk, hop, `shown` and `home` are in
the survey files (A §1–10, B, C §B).

**Finance documents**

| subject | host route · file | root (rule) | members | needs |
|---|---|---|---|---|
| `journal_entry` | `/finance/journal/[id]` · `app/finance/journal/[id]/page.tsx` | journal_entries (table) | journal_lines · its reversal (`reversed_by` up) / the entry it reversed (down) · journal_requests (`result_journal_entry_id`, `target_entry_id`) · approval_log {journal_request} | M4 |
| `invoice` | `/finance/invoices/[id]` · `…/page.tsx` | invoices (table) | invoice_lines · invoice_requests → approval_log {invoice_request} · invoice_issues · credit_notes (not home) · payment_allocations · journal via `entry_id` + its reversal | M4 |
| `credit_note` | `/finance/credit-notes/[id]` | credit_notes (table) | credit_note_lines · cn_issues · the invoice_request that created it → approval_log · journal via `entry_id` | M4 |
| `sale` | `/finance/receivables/[saleId]` | sales_records (table) | sales_attribution_log · finance_attachments · payment_allocations · invoice_lines · journals (sale, COGS via `cogs_entry_id`, reversals) | M4 · Q14 |
| `payable` | `/finance/payables/[batchId]` | inbound_batches (**page**, M3 — the root rule is inbound.view) | payment_allocations · freight_allocations · prepayment_applications · finance_attachments · price_history · purchase / write-off / prepayment journals + reversals | M3 · M4 · M6 (`root_columns` = the payable columns incl. `deleted_at`) · Q5 |
| `payment` | `/finance/payments/[id]` | payments (table) | payment_allocations · finance_attachments · the mirror (`reversed_by_payment` up) / the original (down) · payment_requests (`result_payment_id`, `payment_id`) → approval_log · journal + reversal | M4 |
| `payment_request` | `/finance/payment-requests/[id]` | payment_requests (table) | approval_log {payment_request} · result payment (up) · the payment being reversed (up, **stepping stone**) · bank_transfers (`result_transfer_id` home, `transfer_id`) · wht_remittances (`wht_remittance_id`; and for a remittance request, via `result_journal_entry_id` → `wht_remittances.journal_entry_id`) · journals | M4 (incl. stepping stone) |
| `expense` | `/finance/expenses/[id]` | expenses (table) | payment_allocations · finance_attachments · prepayment_applications · the mirror / original (`reversed_by_expense`) · journals · expense_claims (`expense_id`) · fixed_asset_cost_entries | M4 |
| `freight` | `/finance/freight/[id]` | freight_documents (table; SELECT inbound.view OR finance.view + ALL finance.edit) | freight_allocations · payment_allocations · journal (`journal_entry_id`, `reversal_entry_id`) | M4 |
| `fixed_asset` | `/finance/assets/[id]` · `app/finance/assets/[id]/page.tsx` | fixed_assets (table — the policy is finance.view) | fixed_asset_history · cost entries · depreciation · depreciation anchors · asset_disposal_requests → approval_log {asset_disposal_request} · equipment_maintenance / downtime / service_intervals (**not home**; their home stays `equipment`) | M4 · Q10 |
| `bank_statement` | `/finance/bank/statements/[id]` (+ `/reconcile`) | bank_statements (table) | bank_statement_lines → bank_line_matches · bank_reconciliations → variance items | — · Q6 · Q24 |
| `gst_period` | `/finance/gst/[periodId]` | gst_periods (table) | gst_return_boxes · gst_filing_requests → approval_log {gst_filing_request} | — · Q22 · Q23 |
| `fx_rate` | `/finance/fx/[id]/edit` | fx_rates (table) | fx_rate_history (one event, two rows — the 1b-3 rule) | — · Q7 |
| `management_pack` | `/finance/packs/[id]` | management_packs (table) | — (no self-link through `superseded_by`) | — |
| `contract` | `/contracts/[id]` · `app/contracts/[id]/page.tsx` | contracts (table; side-dependent: customers.view or suppliers.view; page guard `module.suppliers.view`, it reads under RLS and 404s first `:50-55`) | the 7 term tables · contract_document_terms (not home) · terms_requests {contract_activate} → approval_log {terms_request} (not home) | — · Q21 |

**Period-end, settings, and records with no page**

| subject | host | root (rule) | members | needs |
|---|---|---|---|---|
| `finance_lock` | `/finance/settings` under `LockForm` (`page.tsx:132`) **and** `/finance/close` | finance_settings, key `'true'` (M5), `root_columns ['locked_before']` (M6) | **period_closes** (no fk → M7) | M5 · M6 · **M7** · Q2 · Q3 · Q29 |
| `finance_gst` | `/finance/settings` under `GstPanel` (`page.tsx:145`) | finance_settings (M5), `root_columns ['gst_registered','gst_registration_no']` | — | M5 · M6 |
| `approval_policy` | `/settings/approvals` (guard `action.manage_permissions`) | finance_settings (M5), the 4 approval columns | finance_settings_history (M7) | M5 · M6 · M7 · **AT-1d if Q2 is accepted** |
| `company_profile` | `/finance/company` | company_profile, key `'true'` (M5), whole row | — | M5 |
| `year_close` (list block) | `/finance/close` | year_closes | journals via `closing_journal_id`, `reversal_journal_id` | M4 · ListTrail |
| `journal_request` (per row) | `/finance/journal` (`#jr-{id}`, `JournalRequestsPanel.tsx:94`) | journal_requests | approval_log · result / target journals | M4 · Q17 |
| `expense_claim` (per row) | `/finance/claims` (`/me` is AT-1d) | expense_claims (finance.view OR own) | approval_log {expense_claim} · finance_attachments (`claim_id`) · the posted expense | M4 · Q20 |
| `bank_transfer` (list block) | `/finance/bank` (+ the request page as a member) | bank_transfers | journals · payment_requests (`transfer_id`, `result_transfer_id`) → approval_log | M4 |
| `wht_remittance` (list block) | `/finance/wht` (+ the request page) | wht_remittances | journal · payment_requests (`wht_remittance_id`) → approval_log | M4 |
| `cash_forecast` · `cash_forecast_line` (list block) | `/finance/cash-forecast` | cash_forecasts; cash_forecast_lines | — | ListTrail · Q16 |
| `bank_import_profile` (list block) | `/finance/bank/import` | bank_import_profiles (incl. deleted) | — | ListTrail |
| revaluation runs (list block) | `/finance/revaluation` | the run's journal (`source_type='revaluation'`, `source_id` NULL), through `journal_entry` | — | ListTrail |
| depreciation runs (list block) | `/finance/assets` | the run's journal (`source_type='depreciation'`) | fixed_asset_depreciation (`journal_entry_id`; home = the asset) | M4 · ListTrail |
| bulk FX | `/finance/fx` | — no run row; per rate `fx_rate` | — | Q16 |
| payroll payments | `/finance/payroll-payments` | → Q18 | | |
| processing-cost settlement | `/finance/processing-costs` | → Q19 | | |
| deleted statements | `/finance/bank/statements/[id]` opened read-only (Q6) | `bank_statement` | | |

**`finance_attachments`** is a child of four parents through mutually exclusive foreign keys; it is registered under `sale`, `payable`,
`payment` and `expense` (and `expense_claim` via `claim_id`), each membership home — `trail_row_record` takes the first home whose
foreign key is filled (A §10).

---

## b. Mechanism extensions beyond M1–M6

| | what | why | where |
|---|---|---|---|
| **M7** | **a whole-table member of a singleton root**: under an M5 root, a member with no foreign key means every row of that table (and every log row of it) belongs, filtered by `match` | the lock panel must show month close / reopen (`period_closes`) and the approval panel its history (`finance_settings_history`); neither table has a key to reach (§2 item 4) | `trail_subject_members` (fk NULL or `hop = 'all'`), `record_trail` discovery, `trail_row_record` home walk. Alternative without a mechanism change in Q3 |
| **ListTrail widening** | `ListTrail` accepts any registered subject (today a hard-typed union of three) | eight list-level homes in §a | `app/components/trail/ListTrail.tsx:28-33` (code only) |
| **operation key** (Q16) | `record_trail` also returns the transaction key, so a list block merges **one operation across records** into one entry | bulk FX (N rates, one operation, no run row) and freeze + supersede (two forecasts, one operation) otherwise show N times; ListTrail's dedupe drops only identical entries | `record_trail` return columns (additive) |
| employee names (Q12) | `trail_ref_label`'s employees branch applies the ActorName rule | §2 item 8 | `trail_ref_label.sql:60-62` |

**Not needed:** M2 (no employee-id actors anywhere in AT-1c, A §0.5, B, C §D). M6 on members — only the `payroll_payment` design in
Q18 would need it, and I recommend the design that does not.

---

## c. Q25 — the shared settings row split into panels

`finance_settings` (`id boolean PRIMARY KEY DEFAULT true CHECK (id)`, `db/tables/finance_settings.sql:24`), 16 live columns. Writer of
each (C §A1, file:line there):

| panel | columns it owns | writer · gate |
|---|---|---|
| **Period lock** (`/finance/settings`, `LockForm`) | `locked_before` | `setPeriodLock` direct update (`app/finance/settings/actions.ts:30-36`, `module.finance.edit`); `close_period` (`close_period.sql:65`, `module.finance.edit`); `reopen_period` (`reopen_period.sql:39`, `action.finance_reopen`) |
| **GST settings** (`/finance/settings`, `GstPanel`) | `gst_registered`, `gst_registration_no` | `set_finance_settings` (`gstActions.ts:55`, `action.finance_settings`) |
| **Approval policy** (`/settings/approvals`) | `approvals_enabled`, `approval_threshold_base`, `approval_level1_role_code`, `approval_level2_role_code` | `set_approvals_policy` only (`action.manage_permissions`); it also inserts a `finance_settings_history` row in the same transaction |
| **no panel** | `gst_rate_pct` (dead — nothing reads it), `system_start_date`, `fy_end_month`, `fy_end_day`, `first_fy_end`, `default_allocation_basis` | `set_finance_settings` only; no screen writes them (`set_finance_settings.sql:8,33-38`) → Q4 |
| technical | `updated_at`, `updated_by` | every writer; never shown |

**The lock's trail** shows `locked_before` moves (each close / reopen already moves it) **plus** the `period_closes` rows through M7, so
the close notes, the reopen reason and the one pre-log close (period ending 31/07/2026, closed 05/08/2026) are there. Year close does not
move the lock (`close_financial_year.sql:31`), so it is a list block on `/finance/close`, not part of the lock panel.

**Pre-log:** none of the three panels has a pre-log record of its own columns — `finance_settings` keeps only shared `updated_*` stamps.
**There is no record of who registered for GST, or when.** The lock panel's pre-log content is `period_closes` (closed / reopened stamps);
the approval panel's is `finance_settings_history` (1 live row, 22/09/2026).

---

## d. Q21 pages for finance records

| record (live, as postgres) | today | proposal | banner (English, DD/MM/YYYY) | who may open |
|---|---|---|---|---|
| reversed journal entry (13 of 82) | opens; banners "reversed by X" / "reversal of X" (`journal/[id]/page.tsx:151-170`) | keep; banner gains who | "Reversed on DD/MM/YYYY by <name>" — who and when are the reversal entry's `created_at / created_by`, reason its memo | normal readers |
| voided invoice (3 of 9) | opens; red banner with date and reason, **no who** although `voided_by` exists (`invoices/[id]/page.tsx:440-447`) | add who | "Voided on DD/MM/YYYY by <name>" + "Reason: …" | normal readers |
| reversed payment (4 of 13, + 4 mirrors) | opens; "reversed by <mirror>"; **the mirror has no "reversal of" banner** | add who; add the mirror's banner | "Reversed on … by …" / "Reversal of PMT-…" | normal readers |
| reversed expense (0 of 9) | opens; both banners | add who | "Reversed on … by …" | normal readers |
| reversed freight (4 of 4) | opens; amber banner with date, entry, reason, **no who** (`freight/[id]/page.tsx:160-181`) | add who | "Reversed on … by …" + "Reason: …" | normal readers |
| **written-off batch on the payables page** (9 of 24) | opens as an ordinary payable, **no sign it was written off** | banner + read-only (1b-1's batch pattern) | "Written off on … by …" + reason (`deleted_at / deleted_by / delete_reason`) | normal readers (Q5) |
| **deleted bank statement** (1 of 2, BS-2026-0001, 30/07/2026) | **404** on detail and reconcile; hidden on the list | open read-only (§9.10); add to `deleted_records` and `/settings/deleted` | "Deleted on DD/MM/YYYY" (no `deleted_by` column; deleted before the log) | `data.view_deleted` (Q6) |
| **withdrawn FX rate** (0 of 12; `fx_rate_history` 0 rows) | **404** (`fx/[id]/edit/page.tsx:33`) | open read-only | "Withdrawn on … by …" + reason (both in `fx_rate_history`) | normal readers (Q7) |
| disposed asset · superseded pack · filed / corrected GST period · suspended contract | open | unchanged; trail added | — | — |

Deleted freight would 404 (`freight/[id]/page.tsx:54-59`) but nothing writes `freight_documents.deleted_at` and there are 0 deleted rows —
left as is.

---

## e. Finance-specific masking

**The trail masks every column the screens mask; nothing new is needed for AT-1c** (D §1). `change_log_mask_gaps()` returns 0 gaps over
27 masked tables / 81 columns (as postgres). The AT-1c tables with masking today:

| table | masked columns | code |
|---|---|---|
| company_profile | 5 bank columns | `data.view_banking` |
| invoices | subtotal_base, tax_base, total_base, fx_rate | `data.view_prices` |
| invoice_lines | unit_price, amount_base, amount_ccy, tax_base | `data.view_prices` |
| sales_records | unit_price, fx_rate, amount_base, price_provenance | `data.view_prices` |
| prepayment_applications | amount_base, amount_ccy | `data.view_purchase_prices` |
| payroll_lines | 5 amounts | `code_or_self:data.view_pay:employee_id` |
| processing_cost_entries, processing_cost_entry_history | amounts | `data.view_prices` |

Everything else (journals, payments, expenses, credit notes, bank, GST, assets, payroll period totals) is unmasked — standing decision 1
("finance.view implies prices"; the GL's lack of masking is accepted).

**Bank details:** only `company_profile` holds real bank data; the `bank_account_code` columns are GL codes (1000 / 1010, CHECK at
`bank_statements.sql:15`); no supplier, customer or employee table has a bank column. `bank_statement_lines.description / reference` are
free text, unmasked on screen too (4 live rows, no account-number-like runs).

**Row rules that are not plain finance.view** (D §4): `approval_log` per subject type (finance.view for the finance types; hr.view for
payroll requests; **pricing.view for every terms request, including a contract's**); `contracts` and its term tables (customer side →
customers.view, supplier side → suppliers.view; plus an ALL policy for `action.contract_terms`); `terms_requests` (formula: pricing +
both price codes; contract: the contracts rule); `equipment_*` (finance.view OR processing.view); `payroll_lines` (hr.view, OR finance.view
+ view_pay, OR own row); `payroll_periods` (hr.view only); `processing_cost_entries` (processing.view only); `freight_*` (inbound.view OR
finance.view); `expense_claims` (finance.view OR own).

**What a current finance reader sees:** every role with finance.view also holds hr, processing, suppliers, customers and pricing view,
so **no row is Restricted for any live finance reader today**; the one partial case is `payroll_lines` amounts for cto / gm / auditor
(row visible via hr.view, amounts masked). The row checks still run for every row; a future finance-only role would see Restricted rows
for payroll, processing cost entries, contracts and terms requests.

**Two masking questions:** individual pay in the GL (Q11); employee names in references (Q12).

---

## f. Existing history sections

| section | file:line | verdict |
|---|---|---|
| asset **HistoryPanel** (`fixed_asset_history`) | `app/finance/assets/[id]/page.tsx:233-246,523` | **replace** (Q26 names it). No other page reads `fixed_asset_history`; tied to it: `scripts/check-i18n.mjs:868-869` and the `assets.history.*` keys (`messages/en.ts:9366`, zh) — the generator reads labels from en.ts, so the keys it uses for `fixed_asset_history` labels must move into its overrides before the keys go |
| invoice request **history list** (decided / withdrawn requests) | `app/finance/invoices/[id]/InvoiceRequestPanel.tsx:145-161` (fed `page.tsx:206`) | **replace**; the open-request block (`:74-143`) is a control — keep |
| approval-policy history (`ApprovalsHistory`) | `app/settings/approvals/page.tsx:78-82,129` | replace — with its page (AT-1d if Q2) |
| payment-request decision block | `app/finance/payment-requests/[id]/page.tsx:258-283` | keep — it is the request's current state; it never says who decided or withdrew, and the trail adds that (Q26) |
| **keep** (working lists or state): ended-state banners; settlement tables (invoice `:532-575`, sale, payable, expense); issued-PDF version lists; the credit-note list; attachment panels; the reconciliation's superseded list; the GST filing panel; the contract terms-request panel (the formula precedent); close history and year-close history (`close/page.tsx:281-286,327-331`); frozen forecasts and recurring lines; the journal requests panel; the WHT and transfer tables; the lock display | | |

No FX history UI exists to replace (B).

---

## g. Wordings and labels

**Event wordings** (E §1): the AT-0 catalogue has **85** rows for AT-1c (F01–F72, F83–F86, D21–D29): 9 with an existing key, 36 "state
word as a sentence", 40 new. 15 of them (F34–F48, period lock / GST / approvals / close) move with Q2. One missing row: a **WHT remittance
reversal** (`reverse_wht_remittance_internal`, request kind `wht_remittance_reversal`) has no catalogue entry. Reusable today: `journal.*`
(5), the generic `approval.*` (6), `batch.prepayment / freight / payment / invoiced`, `so.invoiced / invoiceVoided / creditNoted`,
`banner.reversed*`. **Estimate: 130–170 new keys in `lib/trail/text.ts`** (AT-1a 117, 1b-1 123, 1b-2 114, 1b-3 54 — measured from each
commit's diff of that file).

**Ambiguous wordings, settled by the old value or the writer** (E §1, 19 cases; the ones that matter):
- a request **inserted as approved** is an automatic approval (approvals off), not a person's;
- payment requests have six kinds, three of them reversals — "approved" of a reversal kind says so; "paid" comes from `pay_payment_request`;
- a payment or expense **reversal inserts a new, opposite row**: its creation must read "Payment reversed" / "Expense reversed", never
  "Payment recorded";
- a journal reversal flips the original and posts a new entry in one transaction — **one** entry;
- invoice void vs credit note: both `invoice_requests`, told apart by `kind`; `invoices.kind` (sale vs order) changes the wording;
- `record_fx_rate` is an upsert: created vs corrected (a correction carries a reason); `withdraw_fx_rate` is a soft delete, and re-recording
  a withdrawn date creates a second row;
- a GST period is opened (F49) or opened **as a correction** (F50, `corrects_period_id`);
- pack and forecast supersede: UPDATE old + INSERT new in one transaction — "Pack produced (replaces PACK-…)";
- bank lines: → unmatched means "unmatched" or "no longer ignored" by the old status; unmatch also deletes the match row; unreconcile writes
  two tables;
- `set_finance_settings` uses dynamic SQL — one update can carry several settings (F38–F44); `locked_before` changes through the lock form,
  close and reopen.

**Field labels** (E §2, counted from `TRAIL_FIELDS`): **558** shown columns on **48** tables new to AT-1c (0 hand overrides; 164 have a
page-measured label in `labels.csv`), plus **76** columns on the **11** already-shown tables that passed only the automated check
(journal_entries, invoice_lines, sales_records, sales_attribution_log, payment_allocations, freight_allocations, finance_attachments,
prepayment_applications, fixed_assets, contract_document_terms, terms_requests). For comparison: AT-1a 197, 1b-1 385, 1b-2 311,
1b-3 145. `fixed_asset_history` alone has 42 old_/new_ columns. **Generated labels found wrong** (fixed in the build):
- wrong meaning: `invoices.status` "All"; `invoices.kind` / `invoice_requests.kind` / `credit_note_lines.kind` "Reason type";
  `payment_requests.payment_id` "Planned payment date"; `bank_transfers.to_account` "Accounts"; `fx_rate_history.action` "Actions";
  `expense_claims.no_receipt_reason` "Number receipt reason"; three `tax_code` columns "Tax ID";
- button / option / form text: `fixed_asset_history.new_expense_id` "+ New Expense"; `contract_pricing_terms.qp_months` "M (the base month
  itself)" (the label is "Quotational period (M+n)"); "Reason (required)"; "Starting Monday";
- language suffix: `gst_return_boxes.label_en / label_zh` "Label en / zh"; `payment_trigger_events.phrase_en` "Phrase en";
- casing / shape: "Gst period number", "Wht remittance number", "Rate Date", "Fy end day", "Approval level1 role", "Previous iD";
- timestamps labelled with state words ("Decided", "Produced", "Frozen", "Superseded"); `fx_rates.deleted_at` should read "Withdrawn on";
- duplicates within one table: `amount_base` and `amount_ccy` both "Amount" (payments, payment requests, freight); `gst_periods.filed_at`
  and `filed_on` both "Filed on";
- to hide: `sha256` on `invoice_issues` / `cn_issues`; JSON columns "Snapshot", "Payload", "Mapping", `allocations`, `lines` → "Details
  changed" (or a renderer, Q13).

**Enums with no English** (E §2, B): 24 columns, 54 values — `invoices.kind / status`, `payments.status`, `gst_periods.status`,
`fx_rate_history.action`, `fixed_asset_history.changed_by_kind`, disposal status (lower-case today), counterparty type, the contract
enums (insured_by, committed_by_party, direction, period, settling_party, refining_charge_basis, penalty_basis). 12 more enum columns have
no CHECK and no map (they would fall to humanize). Bank account codes (1000 / 1010) read as the account name. **Record labels missing:**
`trail_ref_label` returns null for fx_rates, bank_statement_lines, gst_return_boxes, bank_reconciliations and depreciation rows (B).

---

## h. Conflicts with Q1–Q43, Q1–Q14, or how AT-1a / 1b built the mechanism

| # | conflict | where | proposed resolution |
|---|---|---|---|
| 1 | Q25 is in this brief's AT-1c scope; the forward queue puts it (and the approval policy) in AT-1d | `docs/forward-queue.md:6571-6572` | Q2 |
| 2 | Q25 "the lock's trail also shows month close and reopen" cannot be expressed by M1–M6 | `record_trail.sql:116-128` | M7 (Q3) |
| 3 | §9.7 "every person-valued field goes through the same function" vs `trail_ref_label` returning employee names unchecked | `trail_ref_label.sql:60-62` | Q12 |
| 4 | AT-1b §9.5 "no stamp a history already records" — five finance stamps are the only record | §2 item 2 | Q9 (Q11 precedent) |
| 5 | AT-0 Q21 ("records ended by a business event open for normal readers; deletions for `data.view_deleted`") — two finance pages 404 their ended records; the payables page shows a written-off batch as live | §d | Q5 · Q6 · Q7 |
| 6 | Q26 "replace the asset history panel" — its labels feed the catalogue generator | `messages/en.ts:9366`, `check-i18n.mjs:868-869` | move them into the generator's overrides in the same commit (no question) |
| 7 | AT-1b decision "a table shared by two subjects picks wording per subject + table" — journals, allocations, attachments now belong to 5–8 subjects each | `render.ts` `SUBJECT_TABLES` | code only; `home` must be set per membership so `/settings/change-history`'s Record column stays stable (Q14) |
| 8 | making `sales_records` a subject root changes the summary page's Record column for sale rows (the walk-up is skipped for root tables) and `sales_records` is not in `document_types` | `trail_row_record.sql` first IF | Q14 |
| 9 | the payables page and `inbound_batch` share a root; AT-1b built `inbound_batch` with the root rule `table` | `trail_subjects.sql` | a second subject (Q5), the `supplier` / `forwarder` precedent |
| 10 | the equipment subject (AT-1b-1) is processing-gated; the finance asset page needs the same root | `trail_subjects.sql:64` | `fixed_asset` (Q10) |
| 11 | ListTrail's de-duplication (1b-2) drops only identical entries — one operation over two records shows twice | `ListTrail.tsx` | operation key (Q16) |

No conflict found with the 1b fold-ins (names Restricted without hr.view, 20-then-more paging, an all-English trail section).

---

## i. Migration shape and broken window

**One migration per cut, functions only** (plus one seed row if Q14 is accepted):
- replaced in place, same signature: `trail_subjects`, `trail_subject_members` (+ M7), `trail_prelog_sources`, `trail_row_record` (M7 home
  walk), `trail_ref_label` (employee rule, Q12; labels for fx rates, statement lines, return boxes, reconciliations, depreciation),
  `deleted_records` (+ bank statements, Q6);
- `record_trail`: M7 discovery, plus the operation key (Q16). **Adding an output column changes the return type**, which `CREATE OR
  REPLACE` cannot do — it is a `DROP FUNCTION` + `CREATE` inside the migration's one transaction (the preflight's overload check is not
  triggered: the signature's arguments are unchanged; grants are replayed by `apply_migration.sh`). Without Q16 it stays in place;
- `document_types`: one row for the sale (Q14) — a seed table, mirror and `check_mirrors` seed comparison in the same commit;
- no table DDL, no policy, no grant on a table, no trigger, no permission code. No business row written.

**Broken window (old app + new database):**
- **nothing that writes breaks** — no writer changes;
- old pages keep calling `record_trail` for the 1b subjects with the same arguments; a `record_trail` drop + create (Q16) holds an
  exclusive lock only for the apply itself, and an extra output column is ignored by the old caller (PostgREST returns it; the old
  code reads named fields);
- **visible early, and intended:** the summary page's Record column for sale rows (Q14); `/settings/deleted` lists deleted statements
  with a raw key label and no link until the deploy (the 1b-3 shape) if Q6 is in that cut; employee names in references become
  Restricted for readers without hr.view (Q12) — no live finance reader is affected.

---

## j. Time estimate — two numbers, calibrated on the four cuts

**Measured** (E §3 — session transcripts, `db/migration-windows.tsv`, push times):

| cut | session start → push | active | before the backup | backup → push | subjects |
|---|---|---|---|---|---|
| AT-1a | 11:08:58 → 18:55:08 | 4 h 38 m (3 h 08 m idle waiting on a reply) | 1 h 50 m | 2 h 48 m | 3 + mechanism |
| 1b-1 | 19:12:26 → 23:26:55 | 3 h 37 m (build) | 1 h 05 m | 2 h 32 m | ≈ 9 + M1–M6 |
| 1b-2 | 23:40:07 → 02:57:40 | 3 h 04 m | 52 m | 2 h 12 m | 11 |
| 1b-3 | 09:17:57 → 12:24:10 | 3 h 06 m | 54 m | 2 h 12 m | 8 + deleted pages |

Process steps measured: backup 27 / 17 / 18 / 16 min; full gate 611 / 461 / 521 / 445 s; offline gate ≈ 65 s; dry run 17–185 s; smoke
1,264 s (1b-3). The backup → push phase also holds every fix the proof, probe or smoke found — 35–70 min each time.

| | AT-1c |
|---|---|
| **Process floor per migration cut** | **1 h 15 m – 1 h 40 m** pure (backup, gates, dry run, apply, types, build, survey, smoke, probe, proof); **2 h 10 m – 2 h 50 m** as every cut has actually run it, fix loops included |
| **Work** | **9 – 15 h** (inferred): about 27 subjects at the measured 17–31 min per subject (1b-2: 16.7, 1b-3: 23.3, 1b-1: 31) = 7.5–14 h, plus about 1 h for M7, the ListTrail widening and the operation key; labels (634 columns) and keys (130–170) sit inside the per-subject rate, as they did in 1b |

**One session cannot hold it** — no session has held more than about 3 h 40 m of build. → Q1: three cuts, each leaving usable pages.

---

## Open questions — all of them, each with my recommendation

**Shape**

❓ **Q1 — Split AT-1c?** Work 9–15 h, about 27 subjects.
➡️ **Three cuts inside v1.4.33, each with its own migration and floor:**
- **1c-1 · mechanism + the ledger documents:** M7, ListTrail widening, the operation key (Q16), the employee-name rule (Q12); `journal_entry`,
  `invoice`, `credit_note`, `payment`, `payment_request` (with transfers and WHT results), `expense`; the banners in §d for those; the
  invoice-request history replaced; the source-link fix (Q15) and the 1b-3 golden (Q34). About 3–4 h work.
- **1c-2 · the rest of the documents + contracts:** `sale`, `payable` (Q5), `freight`, `fixed_asset` (HistoryPanel replaced), `bank_statement`
  (+ deleted statements, Q6), `gst_period`, `fx_rate` (+ withdrawn rates, Q7), `management_pack`, `contract`. About 3–4 h.
- **1c-3 · period-end, settings and the list homes:** `finance_lock` (+ `period_closes`) on `/finance/settings` and `/finance/close`,
  `finance_gst`, `company_profile`, year closes, revaluation and depreciation runs, bulk FX, cash forecasts, payroll payments (Q18),
  processing settlement (Q19), WHT, transfers, claims (Q20), import profiles, journal requests. About 3–4 h.
Total 9–15 h work + 3 × (1 h 15 m – 2 h 50 m) floor.

❓ **Q2 — Where does Q25 live?** The brief lists it under AT-1c; the forward queue under AT-1d. The approval-policy panel is on
`/settings/approvals` (guard `action.manage_permissions`), a settings page.
➡️ **AT-1c does the two finance panels (lock + GST) and `/finance/close`; AT-1d does `/settings/approvals` with the `approval_policy` subject**
(it reuses M7 for `finance_settings_history`, and replaces `ApprovalsHistory` there). Update the forward queue's AT-1d line accordingly.

❓ **Q3 — How does the lock's trail reach month close and reopen?**
➡️ **M7, a whole-table member under a singleton root** (no foreign key; every row and log row of `period_closes` belongs to the lock).
The alternative — a constant `period_closes.settings_id boolean` column — needs table DDL and reproduces the M5 text-vs-boolean trap
for rows found only in the log.

❓ **Q4 — Six `finance_settings` columns belong to no panel** (`gst_rate_pct` (dead), `system_start_date`, the three FY columns,
`default_allocation_basis`); no screen writes them.
➡️ **Leave them unowned.** Their changes stay on `/settings/change-history` (the complete record). If a screen for them is ever built, it
claims them then.

**Pages and records**

❓ **Q5 — The payables page.** Reuse `inbound_batch` (needs M1 + M3 and brings the whole warehouse story, 39 members) or a new `payable`
subject? And a written-off batch shows as an ordinary payable today (9 of 24).
➡️ **A new `payable` subject** (root rule `page`, M3; `root_columns` = the payable columns incl. `deleted_at`, M6; only the money members).
**A written-off batch opens read-only with "Written off on DD/MM/YYYY by <name>" + reason**, for normal readers — the 1b-1 batch pattern.

❓ **Q6 — Deleted bank statements 404, and the list hides them** (1 live, deleted 30/07/2026, no `deleted_by` column).
➡️ **Open read-only for `data.view_deleted`** (the §9.10 pattern), banner "Deleted on DD/MM/YYYY" (date only — nobody recorded), named
refusal for others; add statements to `deleted_records` and `/settings/deleted` with a link.

❓ **Q7 — Withdrawn FX rates 404** (0 on live today). A withdrawal is a business event with a reason and a person (`fx_rate_history`).
➡️ **Open read-only for the page's normal readers**, banner "Withdrawn on DD/MM/YYYY by <name>" + "Reason: …" — the Q21 rule for records
ended by a business event.

❓ **Q8 — Banners on finance records that end by a business event.** The invoice-void and freight-reversal banners omit who, although it is
recorded; the payment mirror has no "Reversal of" banner (the journal and expense pages have one).
➡️ **One wording, the AT-1b Q8 shape, English only:** "Voided on DD/MM/YYYY by <name>" / "Reversed on DD/MM/YYYY by <name>", "Reason: …"
when recorded, the name under the ActorName rule; add "Reversal of PMT-…" to the payment mirror. For journals, payments and expenses the
who / when come from the reversal row's own creation (they keep no stamp of their own).

❓ **Q9 — Five stamps are the only record of live events** (invoice void, freight reversal, request paid, statement reconciled, claim
decided), against the "no stamp a history already records" rule.
➡️ **Register all five as pre-log stamps** — your Q11 exception for stocktakes, applied the same way: where an approval row exists for the
same operation, they share a timestamp and the renderer folds them into one line.

❓ **Q10 — The finance asset page.** The `equipment` subject is processing-gated.
➡️ **A new `fixed_asset` subject on `/finance/assets/[id]`** (finance.view), with the equipment tables as non-home members; the
HistoryPanel is replaced; `fixed_asset_history` speaks before the log, the change-log row after (the 1b-3 "one event, two rows" rule);
its 42 old_/new_ columns are labelled, not hidden.

**Masking and names**

❓ **Q11 — Individual net pay reaches the GL unmasked.** `pay_payroll_lines` posts one line per employee (net pay; memo = code + legal
name); cto and gm hold finance.view without `data.view_pay`. Does "finance.view implies prices" also mean "finance.view implies individual
pay through the GL"?
➡️ **The trail follows the journal screen** (standing decision 1; masking the trail alone would hide what the journal page shows). Register
it in `docs/known-issues.md` as a separate decision for you — e.g. posting payroll as one total line instead of one per person. No change
in AT-1c.

❓ **Q12 — Employee names in references** (`employee_id` on claims, payroll lines, expenses, payments, payment requests) are returned by
`trail_ref_label` without the ActorName check.
➡️ **Apply the ActorName rule there too** (in `trail_ref_label`, so both readers inherit it) — §9.7 already promises it for every
person-valued field. No live finance reader changes (all hold hr.view); the warehouse account would see "Restricted" on such references
in the 1b trails.

**Mechanism details**

❓ **Q13 — `payment_requests.allocations` is JSONB, not a foreign key.** A pending, rejected or withdrawn request can never appear on the
expense, batch, freight or PO it targets; on its own trail the column would read "Details changed".
➡️ **A dedicated renderer on the request's own trail** that lists the targets by document number (Q12 of AT-0 allows one); accept that the
targets' trails show a request only once it is paid, and register that in `docs/known-issues.md`.

❓ **Q14 — The sale as a subject root** switches `/settings/change-history`'s Record column for sale rows from the output batch to the sale,
and `sales_records` has no `document_types` row (so no link).
➡️ **Add a `sale` document type** routed to `/finance/receivables/[id]`, so the Record column names and links the sale — the page that is
now its trail's home.

❓ **Q15 — The journal page's "Source" link on reversal entries points at a journal id as if it were a batch or run** (`sourceLinks.ts:70-73`;
3 live entries).
➡️ **Fix it in 1c-1** (follow the original entry's source) — it is on a page this cut ships, and the trail would otherwise sit under a
wrong link.

❓ **Q16 — One operation across several records** (bulk FX: N rates, no run row; forecast freeze + supersede: two rows) shows N times in a
list block.
➡️ **Return the operation key from `record_trail`** (additive column) and let `ListTrail` merge by it. The alternative is to accept N
entries for a bulk FX save.

❓ **Q17 — Records with no page of their own.**
➡️ **A `ListTrail` block** on the list page for year closes, revaluation and depreciation runs, cash forecasts, import profiles, WHT
remittances and transfers; **a per-row expandable trail** where each row is already an action card with an anchor — journal requests
(`#jr-{id}`) and claims (the Q24 precedent). Transfers and WHT remittances also show on their payment request's trail.

❓ **Q18 — Payroll payments on `/finance/payroll-payments`.** A `payroll_payment` subject rooted on `payroll_periods` needs M3 + M6 and a
new "M6 on members" (the period's other edits would show).
➡️ **A list block of the payroll payment journals** (`journal_entry`, `source_type = 'payroll'`) on that page; the period's full trail is
AT-1d's `/hr/payroll/[id]`. No new extension.

❓ **Q19 — Processing-cost settlement on `/finance/processing-costs`.** The entries already belong to `processing_run` (processing.view).
➡️ **A list block of the remittance journals and relief expenses** (`journal_entry` / `expense` subjects); the entries' own history stays on
the run page.

❓ **Q20 — Expense claims.** No claim page.
➡️ **A per-claim expandable trail on `/finance/claims`**; the claimant's side on `/me` is AT-1d; once posted, the claim also shows on the
expense's trail.

❓ **Q21 — Contracts.** A contract reader without `module.pricing.view` sees the CFO's activation approvals as Restricted (the `approval_log`
terms-request branch asks pricing.view even for contracts).
➡️ **Accept** (your Q4: existence visible, content Restricted). No live contract reader lacks pricing.view.

❓ **Q22 — GST correction periods.** As a member of the original, every later edit of the correction would also appear on the original.
➡️ **Do not register the self-link.** The correction's own trail opens with "Correction opened for GST-…"; the original keeps the page's
existing link to it.

❓ **Q23 — GST return boxes** are inserted together in one approval transaction; `label_zh` is machine-written Chinese.
➡️ **Fold the boxes into the filing entry** ("GST return locked · 9 boxes", each box a line in English); never show `label_zh` (Q8).

❓ **Q24 — Undoing a reconciliation appends a raw timestamp to the statement's notes** (`unreconcile_statement.sql:32`, `'UNRECONCILED ' ||
now()::text …`), so a notes diff would show a machine timestamp.
➡️ **The renderer recognises that machine suffix and says "Reconciliation undone" instead**; register the writer in `docs/known-issues.md`
(fixing what it writes is a separate change).

❓ **Q25 — Packs** cannot be smoke-tested (0 live packs; on the smoke skip list).
➡️ **Prove the pack trail in the rolled-back live proof** and the fixture; the smoke keeps its skip.

**Wording and labels**

❓ **Q26 — Sections to replace.**
➡️ **Replace** the asset HistoryPanel and the invoice-request history list; **keep** the payment-request decision block (it is the request's
current state — the trail adds who decided) and every working list in §f.

❓ **Q27 — Field labels.** 558 new columns + 76 never hand-checked; the wrong ones in §g.
➡️ **Hand-check all 634 against their pages** (the AT-1a / 1b rule: page label first, then `en.ts`, then `labels.csv`); hide `sha256`;
JSON columns "Details changed" except Q13; every label listed in each cut's hand-back for your review.

❓ **Q28 — Enum values** (54 missing, 12 columns with no source).
➡️ **English for every value, from the page's own option labels where they exist**; bank account codes read as the account name.

❓ **Q29 — `/finance/close`.**
➡️ **The `finance_lock` trail (lock moves + month closes and reopens) under the close-history table, and a `year_close` list block under the
year-close panel.** The settings page shows the same `finance_lock` trail under the lock form.

❓ **Q30 — The WHT remittance reversal has no catalogue wording.**
➡️ **"WHT remittance reversed"**, with the reversal journal as a line; and "WHT remittance reversal sent for approval" for its request.

❓ **Q31 — Payment and expense reversals insert an opposite row.** Its creation must not read "Payment recorded".
➡️ **"Payment reversed · PMT-…" on both pages** (the original's and the mirror's), read from the mirror's creation; the same for expenses.

❓ **Q32 — Automatic approvals on finance requests** (a request inserted as `approved`).
➡️ **"Approved automatically (approvals were switched off)"** — the AT-0 wording, as on purchase orders.

❓ **Q33 — Reversal journal lines.** Show the reversing entry's lines on the original's trail?
➡️ **No** — the reversal is one line ("Reversed by JE-…", linked); its lines are the mirror image and live on its own page.

❓ **Q34 — The missing 1b-3 golden** (decision 28, deleted task step).
➡️ **Add it in 1c-1** to `scripts/check-trail-wording.mjs` arm ⑦ with a fault injection, and correct the 1b-3 hand-back's "goldens for the
three".

---

**Stopped at the gate.** No code edit and no migration before your answers to Q1–Q34.
