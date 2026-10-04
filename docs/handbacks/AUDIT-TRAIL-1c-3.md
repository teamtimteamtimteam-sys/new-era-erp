# AUDIT-TRAIL-1c-3 — period-end, settings and the list homes: the period-lock and GST panels, `/finance/close`, the company profile, list blocks, a trail per journal request and per expense claim, and the claimant's own claim on `/me`; plus the 1c-2 close-out (2026-10-04)

Part of v1.4.33, not yet released.

**Opening check:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `e282b092366c89a1d0cd6ed4b827a7d101b270ee` (AT-1c-2), measured at
**2026-10-04 07:38:14 CST** (this session's first command). **Approvals were ON and stayed ON** (finance / cfo / 1,000).

Every figure below is either a script's own exit line or a query named with who ran it:
- unless stated otherwise, `postgres` (`rolbypassrls = true`) reading base tables;
- "as X" means `SET LOCAL ROLE authenticated` plus X's JWT.

This is cut 3 of the 3 AT-1c cuts (1c-1 → 1c-2 → **1c-3**); **AT-1c is complete**. It is built on Tim's answers to
`docs/surveys/AUDIT-TRAIL-1c/STEP0-HANDBACK.md` (Q1–Q34, all accepted as recommended, 2026-10-03). Reference for the mechanism:
**`docs/change-log.md` §9** (§9.13 is new; M8 is in §9.9).

## §1 · Step 1 — the 1c-2 close-out, item by item

All read-only. Nothing was missing, so step 2 went ahead.

**1. The 1c-2 broken window** is recorded in `docs/forward-queue.md` item 28, in the 1c-1 format:

| | value | source |
|---|---|---|
| start | **2026-10-04 01:18:22 CST** | the main migration's commit, `db/migration-windows.tsv` (`2026-10-04-at1c2-trails-documents-and-contracts.sql`) |
| | 01:31:04 CST | the fu1 follow-up (`2026-10-04-at1c2-fu1-trail-ref-label-journal-lines.sql`) committed, inside the window |
| end, lower bound | **2026-10-04 03:11:04 CST** | `git reflog show --date=iso refs/remotes/origin/main`: `e282b092 refs/remotes/origin/main@{2026-10-04 03:11:04 +0800}: update by push` |
| end, upper bound | **2026-10-04 07:38:14 CST** | this session's first command (`date` printed it). It rests on Tim's "deployed", **not** on a Vercel reading |
| window | **at least 1 h 52 min 42 s, at most 6 h 19 min 52 s** | the upper bound is wide because the push and this close-out are a night apart |

**2. Read-only verification of what the 1c-2 report did not mention.** Two read-only agents gathered the file evidence; every line below was
re-read by me where it decides the verdict.

**a — the eight subjects 1c-2 covered; Q10.** ✅
- `db/functions/trail_subjects.sql:131-138`: one row each for `sale`, `freight`, `fixed_asset`, `bank_statement`, `gst_period`, `fx_rate`,
  `management_pack`, `contract` (e.g. `:133 ('fixed_asset', ARRAY['module.finance.view'], 'fixed_assets', 'id', 'table', NULL)`), beside
  `:93 ('equipment', ARRAY['module.processing.view'], 'fixed_assets', 'id', 'page', NULL)` — two subjects on one root (Q10).
- `app/components/trail/AuditTrail.tsx:29` (the union) and `:73-80` (`TRAIL_SUBJECT_ROOTS`); `lib/trail/render.ts:912-922` (`SUBJECT_TABLES`,
  `fixed_asset` includes `fixed_asset_history`).
- Each host page draws it: `receivables/[saleId]/page.tsx:319 subject="sale"`, `freight/[id]/page.tsx:197`, `assets/[id]/page.tsx:502
  "fixed_asset"`, `bank/statements/[id]/page.tsx:418`, `gst/[periodId]/page.tsx:288`, `fx/[id]/edit/page.tsx:76`, `packs/[id]/page.tsx:98`,
  `app/contracts/[id]/page.tsx:232`.
- Q10, the asset history panel is replaced: `app/finance/assets/[id]/` has no `HistoryPanel.tsx`; `grep -rn HistoryPanel app lib messages` → 0;
  `grep assets.history messages app lib` → 0; no `.from('fixed_asset_history')` anywhere in `app/` or `lib/` (the only mention is a comment at
  `assets/[id]/page.tsx:227` saying the panel became the trail).

**b — Q6: deleted bank statements open read-only for `data.view_deleted`; `/settings/deleted` shows BS-2026-0001 with a label and a link.** ✅
- `app/finance/bank/statements/[id]/page.tsx:64-67` (`if (deleted) { const refused = await requireDeletedAccess('bank.detailTitle') …`),
  `:210` `<DeletedBanner kind="bank_statement" …>`, `:391-393` the delete button inside `<EndedFieldset ended={deleted}>`;
  `reconcile/page.tsx:53-54` redirects a deleted statement to its page.
- `db/views/deleted_records.sql:202-216`: the `'bank_statement'` branch, "who" from the change log.
- `app/settings/deleted/page.tsx:95` `bank_statement: (id) => \`/finance/bank/statements/${id}\``, `:152` the label through
  `t('deleted.kind.' + r.record_kind)`; `messages/en.ts:7078` `bank_statement: 'Bank statement'`, `messages/zh.ts:6872` `'对账单'`.
- **On the deployed page:** the deployed code is this HEAD (`e282b092`, Tim's "deployed"). This machine does not read the Vercel page (the
  standing rule); the same code was rendered by the 1c-2 probe: `/tmp/claude-501/at1c2-probe2.log:11` `✓ Q6 [admin] /settings/deleted lists
  BS-2026-0001 with a link`, and `:8` `✓ Q6 [admin] deleted statement BS-2026-0001: «Deleted on 30/07/2026», read-only, trail entries`.
  The label is the message key above (the probe asserts the link, not the label text — the label is read from the two message files).

**c — Q7: withdrawn FX rates open read-only for normal readers, with who and the reason.** ✅
- `app/finance/fx/[id]/edit/page.tsx:24` `requireModule(MOD.finance)` (no `requireDeletedAccess`); `:39-46` loads the rate with no
  `deleted_at` filter (`notFound()` only on an error or a missing row); `:50-51` who and why from `fx_rate_history` (`action = 'withdrawn'`);
  `:66` `<EndedBanner kind="withdrawn" … by=… reason=…>`; `:68-73` the form inside `<EndedFieldset>`.
- Wording: `lib/trail/text.ts:552-553` `'banner.withdrawn': 'Withdrawn on {date} by {who}'`, `'banner.withdrawnDate'`.
- Fixture evidence: `/tmp/claude-501/at1c2-fixture-inj.log:21` `✓ Q7: a withdrawn rate needs more than the page's own code: red in its arm`.
  (Live had 0 withdrawn rates, so no page-level reading exists; 1c-3 now gives them an entry point, §3.)

**d — Q21: contract approvals read "Restricted" to a reader without the pricing view.** ✅
- `db/tables/approval_log.sql:275` `WHEN 'terms_request' THEN has_permission('module.pricing.view'::text)`;
  `db/functions/trail_subject_members.sql:356-357` (`contract` ord 8 `terms_requests`, ord 9 `approval_log` with
  `{"subject_type": "terms_request"}`).
- Fixture 242 arm C (`db/fixtures/242-…sql:401-406`): a reader with `module.suppliers.view` and no `module.pricing.view` must see a hidden
  row (Restricted), never the decision. `/tmp/claude-501/at1c2-fixture-inj.log:24` `✓ Q21: every row visible to every reader … red in its arm`.

**e — Q22, Q23.** ✅
- Q22: `trail_subject_members.sql:340-342` gives `gst_period` exactly three members; `grep corrects_period_id` on that file → 0. The correction's
  own trail opens with `'gstp.correctionOpened': 'Correction opened for {code}'` (`text.ts:591`, used `render.ts:3227`).
- Q23: `render.ts:3242-3250` folds the INSERTed boxes into one block, `'gstp.locked': 'GST return locked · {n} boxes'`, each line from
  `label_en` only; `scripts/gen-trail-catalogue.mjs:446` hides `gst_return_boxes.label_zh` (`"technical"` in the catalogue).
- Fixture 242 arm G (`:329-340`); arm ⑨ goldens "Correction opened for GST-2026-Q3" and "[GST return locked · 3 boxes] · Box 1 · …";
  ⑨ also asserts no CJK character in that entry.

**f — field-edit fixture arms and goldens for payment requests and credit notes.** ✅ — with one point stated plainly:
- Payment request: fixture 242 arm P (`:440-450`) — a reader's direct edit does not land (no UPDATE policy: zero rows, no error); a system
  write is on the trail as a field edit (`planned_date`) by "System (automatic)". Golden ⑨ "Request changed · PREQ-2026-0005 · Planned
  payment date: 01/10/2026 → 05/10/2026".
- Credit note: **no field edit can exist** — `db/tables/credit_notes.sql:51-53` `trg_credit_notes_append_only BEFORE UPDATE OR DELETE` →
  `guard_credit_note_append_only()` raises `CREDIT_NOTE_IMMUTABLE` for every update (the lines carry the same trigger,
  `credit_note_lines.sql:47-49`). So the arm (`:422-431`) proves the edit is refused by name and writes no change-log row, and golden ⑨
  "Credit note changed · Reason: Price → Price adjustment agreed on 01/10" pins the wording the renderer would use. I counted this as complete
  (the arm is the immutability), not partial; flagged here in case you read it the other way.
- Run today: `node scripts/check-trail-wording.mjs` → ①–⑨ ✓, `X_OWN_EXIT=0`; with `TRAIL_WORDING_FAULT=wording-drift-1c2` only ⑨ red
  (2 goldens: the two "Reconciliation undone" entries), `X_OWN_EXIT=1`.

**g — the Chinese / English identical-output check.** ✅
- It lives in the page probes ("fold-in 3"): `scripts/probe-at1c2.mjs:205-229` compares every trail section of a page rendered with
  `NEXT_LOCALE=zh` against `en` character for character (`zt === et`, `:227`).
- Coverage: 1c-2's probe — every live record of `sale`, `freight`, `fixed_asset`, `bank_statement`, `gst_period`, `fx_rate` (packs and contracts:
  0 live rows, skipped with a named reason) plus three control pages: an AT-1a purchase order, an AT-1b inbound batch, the AT-1c-1 journal
  JE-2026-0001. Earlier probes cover the rest: `probe-at1b1.mjs:202-221` (batches, run, equipment, `/inventory`, a PO, change history),
  `probe-at1b2.mjs:194-208` (a sales order, `/logistics/lanes`), `probe-at1b3.mjs:241-253` (the task page), `probe-at1c1.mjs:211-228` (journal,
  invoice, credit note, payment, expense, payable).
- Red under injection: `probe-at1c2.mjs:224` `if (INJECT === 'cjk') zt += ' 受限'`; `/tmp/claude-501/at1c2-pinj-cjk.log`: all 33 fold-in-3 checks ✗
  (e.g. `zh 516 chars vs en 513; they part at 513`), `40 passed · 33 failed · 2 skipped`, `AT1C2_PROBE_EXIT=1`.
- The 1c-2 live records in both interfaces: `/tmp/claude-501/at1c2-probe2.log`, 33 ✓ fold-in-3 lines (9 sales, 4 freight, 2 assets,
  2 statements, 1 GST period, 12 FX rates, 3 controls incl. JE-2026-0001 667 = 667), `73 passed · 0 failed · 2 skipped`, `PROBE2_OWN_EXIT=0`.

**h — `docs/change-log.md` §9 covers the 1c-2 subjects; `docs/forward-queue.md` marks 1c-2 complete.** ✅
- `docs/change-log.md:273-280` (eight table rows) and §9.12 (`:576-620` before this cut's edits).
- `docs/forward-queue.md:6590` `✅ AT-1c-2(2026-10-04)· 其余的单据与合同` (before this cut's edits).

**i — the decisions 1c-2 took without asking** (`docs/handbacks/AUDIT-TRAIL-1c-2.md` §10, titles only):
1. Q14 without `document_types`.
2. Home changes.
3. The contract subject is gated by `module.suppliers.view`.
4. Withdrawn FX rates have no entry point.
5. Message keys.
6. The asset card's labels adopt the old panel's wording.
7. Kind overrides.
8. A follow-up migration (fu1), not a rebuilt main file.
9. Fixture 242 compares with `IS DISTINCT FROM`.
10. Migration date 2026-10-04.
11. `gm` is the refused reader in the probe.
12. The step 1 count was corrected.
13. GST `label_en` is shown and `label_zh` hidden.
14. Trail text keys use new prefixes.
15. A deleted statement's controls.
16. The round-trip fix lives in the shared `mergeUpdates`.
17. Proof B records the sale as admin@.
18. Pack and contract pages were neither surveyed nor probed.
19. The first backup failure was retried once, immediately.

## §2 · Subjects covered

| Step 0 hand-back subject (§a "Period-end, settings, and records with no page") | 1c-3 |
|---|---|
| `finance_lock` (Q25 · Q3 · Q29; M5 · M6 · **M7** — `period_closes`, its first live user) on `/finance/settings` under the lock form **and** `/finance/close` under close history | ✅ |
| `finance_gst` (Q25; M5 · M6) on `/finance/settings` under the GST panel | ✅ |
| Q4: the six unowned `finance_settings` columns on no panel, still on `/settings/change-history` | ✅ (fixture 243 L · G assert it) |
| `company_profile` (M5) on `/finance/company` | ✅ |
| `year_close` (list block) on `/finance/close` (Q29) | ✅ |
| `journal_request` (per row, Q17) on `/finance/journal` | ✅ — every request card (new-entry and reversal) |
| `expense_claim` (per row, Q20) on `/finance/claims`; the claimant's view on `/me` | ✅ — `/me` through `my_expense_claim` (**M8**, new) |
| `bank_transfer` (list block) on `/finance/bank` | ✅ |
| `wht_remittance` (list block, Q30 "WHT remittance reversed") on `/finance/wht` | ✅ |
| `cash_forecast` · `cash_forecast_line` (list block, Q16) on `/finance/cash-forecast` | ✅ |
| `bank_import_profile` (list block, deleted ones included) on `/finance/bank/import` | ✅ |
| revaluation runs (list block of `journal_entry`) on `/finance/revaluation` | ✅ |
| depreciation runs (list block of `journal_entry`; each asset's charge a line — `journal_entry` gains `fixed_asset_depreciation`) on `/finance/assets` | ✅ |
| bulk FX (Q16, `fx_rate` per rate, one operation one entry) on `/finance/fx` — and the withdrawn-rate entry point 1c-2 queued | ✅ |
| payroll payments (Q18: list block of the `payroll` journals) on `/finance/payroll-payments` | ✅ |
| processing-cost settlement (Q19: list block of remittance journals and relief expenses) on `/finance/processing-costs` | ✅ |
| deleted statements (list block of `bank_statement`, the `data.view_deleted` gate) on `/finance/bank/statements` | ✅ |
| `approval_policy` (`/settings/approvals`) | ⬜ AT-1d (Q2). Untouched |
| the rest of `/me`, HR, settings, accounts; DATE-PICK-1 | ⬜ AT-1d / DATE-PICK-1. Untouched |

## §3 · What was built

### The registry (`db/functions/`)

- **Twelve subjects** in `trail_subjects()`, 56 in all: `finance_lock`, `finance_gst` (both on `finance_settings`, `root_columns`
  `['locked_before']` / `['gst_registered', 'gst_registration_no']`), `company_profile`, `year_close`, `journal_request`, `expense_claim`,
  `my_expense_claim` (no page code — M8), `bank_transfer`, `wht_remittance`, `cash_forecast`, `cash_forecast_line`, `bank_import_profile`.
  Every view code is the page's `requireModule(MOD.finance)` = `module.finance.view`, except `my_expense_claim`.
- **Members** (`trail_subject_members()`):

| subject | members |
|---|---|
| finance_lock | `period_closes`, the whole table (`hop = 'all'`, M7) — home |
| year_close | the closing journal and the reversal journal (up) |
| journal_request | its approvals (home) · the journal it posted (up) |
| expense_claim / my_expense_claim | its approvals (home on `expense_claim`) · its receipts, `finance_attachments.claim_id` (home on `expense_claim`) · the expense it recorded (up) |
| bank_transfer | its journal and reversal journal (up) · the requests that made it (`result_transfer_id`) and reversed it (`transfer_id`) · their approvals |
| wht_remittance | its journal (up) · that journal's reversal (`reversed_by`, up) · the reversal request (`wht_remittance_id`) · the paying request, through the journal (`payment_requests.result_journal_entry_id`) · their approvals |
| journal_entry (1c-1) | + ord 7 `fixed_asset_depreciation` (a depreciation run's per-asset charges; home stays the asset) |

- **Homes changed:** `journal_entry` ord 4–6 (requests and their approvals) are no longer home — a journal request is a subject root now, so it and
  its approval home on the request (a pending request has no journal). `/settings/change-history`'s Record column for those rows names the
  request (its label, e.g. "manual journal #3", unlinked — it has no page).
- **Pre-log sources** (`trail_prelog_sources()`): `period_closes` (closed; reopen stamp + reason), `year_closes` (closed; reopen stamp + reason +
  reversal journal), `cash_forecasts` (frozen; supersede stamp, no person — `superseded_by` is a forecast id), `cash_forecast_lines` (created),
  `bank_import_profiles` (created; deletion stamp, no person). Nothing for `finance_settings` or `company_profile`: they keep only shared
  `updated_*` stamps, which cannot say which panel's column changed — so nobody registered for GST "before the log", and the trail says nothing.
- **Names** (`trail_ref_label()`): "Finance settings", "Company profile", "Period ending DD/MM/YYYY", "Year ending DD/MM/YYYY",
  "Transfer DD/MM/YYYY · Cash at Bank – SGD → Cash at Bank – USD" (account names from the chart of accounts, never the codes).
- **M8** (`record_trail()`): an empty `view_codes` array means the root row's own read rule is the only gate; it is refused unless the root rule
  is `'table'`; `NULL` codes are still refused.

### The rulings

| ruling | built |
|---|---|
| **Q25 · Q3 · Q29** | the lock's trail: "Period lock moved / set / removed" with the line "Period locked before: old → new" (the page's label); "Month closed up to DD/MM/YYYY" (the close row and the lock move are one operation; entries and totals as lines; notes as the reason); "Month reopened from DD/MM/YYYY" (reason). Drawn under the lock form on `/finance/settings` and under close history on `/finance/close` |
| **Q25 (GST)** | "GST registration switched on / off", "GST settings changed", the changed columns as lines — only the two GST columns |
| **Q4** | the six unowned columns reach no panel (M6 on both subjects); they stay on the summary page |
| **Q29** | `/finance/close`: the lock trail under close history; a year-close block ("Year closed up to …" with the closing journal as a linked line; "Year reopened · year ending …" with the reversal journal) |
| **Q16** | list blocks merge one operation across records: a bulk FX save is "Exchange rates recorded · N rates" with one line per rate; a re-freeze is one entry ("Cash forecast frozen · FCST-…" and under it "Cash forecast replaced · FCST-…, Replaced by …") |
| **Q17** | a collapsed trail inside every journal-request card (open and recently decided) |
| **Q18 · Q19** | payroll journals; remittance journals and relief expenses — list blocks of the existing `journal_entry` / `expense` subjects |
| **Q20** | a collapsed trail per claim on `/finance/claims` (pending cards and the decided register); the claimant's own trail per claim on `/me` (M8; the approval and the expense read Restricted, Q4) |
| **Q30** | "WHT remittance reversed" with the reversal journal as a linked line; when a request paid it, one sentence with the request's number |
| **Q8** | no 1c-3 home is a record page that a business event ends; ended records in list blocks are marked in their Record name — "(reversed)", "(replaced)", "(withdrawn)", "(deleted)", "(reopened)", "(switched off)" |
| **Q9** | the stamp sources above |
| **Q26** | nothing replaced: every history-like section on these pages is a working list (close history with Reopen, year-close history, frozen forecasts, journal requests, WHT and transfer tables) and stays |
| **Q27 · Q28** | **31 labels or kinds changed on 7 tables · 3 value maps added · 3 record-type names changed** (measured by diffing the committed catalogue, `git show HEAD:`, against the regenerated one). Every column of the seven tables 1c-3 first shows was checked against its page (§8.2); the four 1c-1 tables these subjects share (requests, claims, transfers, remittances) were already hand-checked in 1c-1 |
| **`inbound_batches.status`** | no 1c-3 page shows `inbound_batches` (none of the twelve subjects' tables is it, and the `journal_entry` / `expense` / `fx_rate` / `bank_statement` blocks do not reach it), so its English values stay as 1c-2 registered them (`AT1C2-INBOUND-STATUS-HAS-NO-VALUE-MAP`) |

### Corrections found while hand-checking (shared renderer, all subjects)

1. **A bank transfer's incoming leg carried the outgoing currency.** "Amount in (destination currency): 1,000.00 SGD" for a USD account. Each leg
   now takes its own account's currency (`lib/currencyMap.ts` `currencyOfBank`, the repo's one bank ↔ currency map, passed in as
   `dict.bankCurrency`); a transfer request's `amount_in` the same. Golden "bank transfer · made" pins "1,000.00 USD".
2. **A transfer's own edit read "Request changed".** It now reads "Bank transfer changed".
3. **Bulk-FX lines** name each rate the way `trail_ref_label` does ("USD · TT selling rate · 02/10/2026"), not with the long side label.

### Corrections found by the rolled-back live proof (§7.2)

4. **A month close's totals had no currency** — on the live lock trail today: "Total debits: 757,013.37". `period_closes.total_debits /
   total_credits` and `year_closes.net_result` are base-currency amounts (`BASE_PRICE_COLS`). My first goldens passed `currency: 'SGD'` and
   hid it; arm ⑩ now renders with no document currency, as the pages do.
5. **An operation whose every row nets to nothing read "Restricted".** `buildEntries` treated "every row merged away" like "every row
   hidden". A lock moved forward and back in one operation now says nothing (the 1c-2 rule: a merged edit with no columns says nothing);
   "Restricted" stays for rows the reader really cannot see.
6. **A remittance created and reversed in one operation** had its creation lines folded under "WHT remittance reversed"; the "done" fold
   now skips the Q30 block.
7. **An import mapping renamed and deleted in one operation** dropped the rename (the 1b-3 rule: a deletion keeps its other changes).

Each fix was reverted in a scratch copy of the tree: ⑩ went red on exactly its golden (`INJ_currency_OWN_EXIT=1`, `INJ_restricted_OWN_EXIT=1`,
`INJ_donefold_OWN_EXIT=1`, `INJ_deletion_OWN_EXIT=1`), and `RESTORED_OWN_EXIT=0`.

### The migration

**`db/migrations/2026-10-04-at1c3-trails-period-end-settings-and-lists.sql`** (builder `db/scripts/build_at1c3_migration.py`): five
functions replaced in place with the same signatures (`trail_subjects`, `trail_subject_members`, `trail_prelog_sources`, `trail_ref_label`,
`record_trail`), `NOTIFY pgrst`. No table, view, policy, table grant, trigger or permission code changed; no business row written. Its own
proof: approvals ON, grants unchanged, pending documents unchanged, `change_log` unchanged, 56 subjects, execute grants, every live record of
the twelve subjects read as tim@ without a refusal, the lock trail carrying every `period_closes` row, every pending document still has a
decider. The new fixture is **243**.

## §4 · Pages — every new or changed route, with its file

| route | file(s) | change |
|---|---|---|
| `/finance/settings` | `app/finance/settings/page.tsx` | lock trail under the lock form (`#lock-trail`), GST trail under the GST panel (`#gst-trail`) |
| `/finance/close` | `app/finance/close/page.tsx` | lock trail under close history (`#lock-trail`); year-close block (`#year-close-trail`) |
| `/finance/company` | `app/finance/company/page.tsx` | trail at the bottom |
| `/finance/revaluation` | `app/finance/revaluation/page.tsx` | revaluation-run block (latest 24 journals, each linked) |
| `/finance/assets` | `app/finance/assets/page.tsx` | depreciation-run block (`#depreciation-trail`) |
| `/finance/fx` | `app/finance/fx/page.tsx` (+ `messages/en.ts`, `messages/zh.ts`: `finance.fxPage.withdrawnTitle` / `withdrawnHint`) | "Withdrawn rates" entry list; block of the page's rates and the withdrawn ones, each linked |
| `/finance/cash-forecast` | `app/finance/cash-forecast/page.tsx` | block of frozen forecasts and recurring lines |
| `/finance/payroll-payments` | `app/finance/payroll-payments/page.tsx` | block of payroll journals |
| `/finance/processing-costs` | `app/finance/processing-costs/page.tsx` | block of remittance journals and relief expenses (read through `processing_cost_entries_masked`; a reader without `module.processing.view` gets a named refusal) |
| `/finance/wht` | `app/finance/wht/page.tsx` | block of remittances |
| `/finance/bank` | `app/finance/bank/page.tsx` | block of transfers |
| `/finance/claims` | `app/finance/claims/page.tsx`, `ClaimDecisionPanel.tsx` | a collapsed trail per claim (pending card; decided register) |
| `/finance/bank/import` | `app/finance/bank/import/page.tsx` | block of import mappings, deleted ones included |
| `/finance/bank/statements` | `app/finance/bank/statements/page.tsx` | block of deleted statements (`#deleted-statements-trail`), each linked; named refusal without `data.view_deleted` |
| `/finance/journal` | `app/finance/journal/page.tsx`, `JournalRequestsPanel.tsx` | a collapsed trail in every request card and decided-request line |
| `/me` | `app/me/page.tsx`, `MyExpenseClaimsPanel.tsx` | a collapsed trail per own claim (`my_expense_claim`) |
| `/finance/journal/[id]` (1c-1) | `lib/trail/render.ts` | a revaluation / depreciation / payroll / year-close journal's title names its source; a depreciation journal lists each asset's charge |
| every 1c-1 page that shows a bank transfer | `lib/trail/render.ts` | the two legs' currencies; "Bank transfer changed" |
| shared | `app/components/trail/AuditTrail.tsx` (twelve subjects, `anchor`, `compact`), `ListTrail.tsx` (any intro, `href`, `anchor`, `refused`), `lib/trail/render.ts` (`describeLedger3`, `mergeByOperation` links), `lib/trail/text.ts`, `lib/trail/dict.ts`, `lib/trail/catalogue.generated.ts` | |

## §5 · Verification, in the brief's order

Each line is the script's own exit line from its own log (`/tmp/claude-501/at1c3-*.log`).

| # | step | result |
|---|---|---|
| 1 | offline gate `db/gate.py --offline` | **`GATE_OFFLINE_EXIT=0`** (67 s, 08:26:55 → 08:28:03), fixture 243 included |
| 2 | backup `~/evoltrya-backups/backup.sh`, background (`run_detached`) | **`BACKUP_EXIT=0`**, 08:28:15 → 08:37: `evoltrya-backup-2026-10-04-0828.dump`, 5.6 MB, verified by the script; finished before step 3 |
| 3 | `db/apply_migration.sh` | COMMIT → ROLLBACK dry run first: **`DRY_OWN_EXIT=0`** (its own proof read 16 records as tim@, none refused). Then **`APPLY_OWN_EXIT=0`**: applying started 08:38:12, committed **08:39:15 CST — the window starts here** (`db/migration-windows.tsv`) |
| 4 | `npm run types:gen` (`DO_NOT_TRACK=1`) | **`TYPES_OWN_EXIT=0`**; `lib/database.types.ts` unchanged (no signature moved) |
| 5 | `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** |
| 6 | `npm run build` | **`BUILD_OWN_EXIT=0`** |
| 7 | full gate `db/gate.py` | **first run: `GATE_EXIT=124`** — stopped by `run_detached` at its 1500 s limit, not the gate's own verdict: after "NO DIFFERENCES — the rebuild matches live ✓" it printed nothing more (output buffered); live had no stuck session. **Rerun immediately, once**, with `DO_NOT_TRACK=1 SUPABASE_TELEMETRY_DISABLED=1 python3 -u`: **`GATE_EXIT=0`**, 368 s — rebuildable ✓ · mirrors = live ✓ (types ✓) · every fixture ✓ (243 included) · anon surface ✓ (326 relations + 1 function ⊆ baseline 327) · `changelog` 242 / 238 / 4, no gaps · `changemask` 27 / 81, no gaps · `swallow` clean · `definer` 0. Where the first run stalled is **not proven**; registered as `GATE-TYPES-CLI-HAS-NO-TIMEOUT` |
| 8 | i18n check (in the build) | "代码引用的每一个键(含可枚举的动态键)en 与 zh 都在" (every key the code references, incl. enumerable dynamic keys, is in en and zh); no new hard-coded Chinese (baseline 18) |
| 9 | error-swallowing check (in the build) | "swallowed query errors: 0 unallowed, 0 queued, 9 allowlisted" |
| 10 | layout survey, 16 pages (the 15 changed finance routes and `/me`), 390 px and 1280 | **`SURVEY390_EXIT=0`**: U1 pan-free 16/16, U2 clipped tables 0. **`SURVEY1280_EXIT=0`**: 16/16, 0. Touch targets under 44 px are reported, not judged |
| 11 | route smoke, background | **`SMOKE_EXIT=0`**: 260 ok, 9 skipped (no data), 0 failed — the 14 new 1c-3 `trail` assertions included. **Scratch reading:** the stale-row check reported the same 6 `ZZ-SMOKE-*` rows as before (5 still referenced, so not deleted); after the run, as `postgres`: 0 `*@test.local` users, 0 `probe-*` roles, 0 such grants; `.ephemeral/` empty |
| 12 | live verification | §7 |

**Files changed after build and full gate, and what was rerun.** The rolled-back proof (§7.2) found four rendering defects (§3, corrections
4–7). The fixes touched `lib/trail/render.ts` and `scripts/check-trail-wording.mjs` (three new goldens; arm ⑩ now renders without a
document currency), plus docs. **No file under `db/` that the gate reads changed after the gate** (not `db/functions`, `db/views`, `db/tables`
or `db/fixtures`; the proof script under `db/scripts/` is not read by the gate), so the gate was not rerun. Everything else was rerun in one
detached chain (`/tmp/claude-501/at1c3-rerun.sh`, `RERUN_EXIT=0`, 10:10:43 → 10:38:46):

| step | result |
|---|---|
| `node scripts/check-trail-wording.mjs` | `TW_OWN_EXIT=0`: ①–⑩ ✓ (56 subjects, 158 tables, 2075 columns; 239 tables and 121,302 sentences swept; 595 keys) |
| `npx tsc --noEmit` | **`TSC2_OWN_EXIT=0`** |
| layout survey (`.next` removed first) | **`SURVEY390_EXIT=0`**, **`SURVEY1280_EXIT=0`**, 16/16 and 0 at both widths |
| `npm run build` | **`BUILD2_OWN_EXIT=0`** |
| route smoke (full) | **`SMOKE2_OWN_EXIT=0`**: 260 ok, 9 skipped, 0 failed; the same 6 stale rows; its own account, role and grants removed (0 / 0 / 0 read back afterwards) |
| page probe | **`PROBE2_OWN_EXIT=0`** (`AT1C3_PROBE_EXIT=0`): 42 passed · 0 failed · 1 skipped |
| live proof + render | **`PROOF2_OWN_EXIT=0`**, **`RENDER2_OWN_EXIT=0`** (§7.2) |

## §6 · Fault injection

**Fixture 243** (`db/scripts/2026-10-04-at1c3-fixture-injections.py`, against a local rebuild of the mirrors):
**`INJECTIONS_OWN_EXIT=0 (24 injections, 0 wrong)`** — clean 243 green, then each injection red in its own arm: M6 on the lock panel · M6 on the
GST panel · M7 member hidden · M7 expansion disabled in `record_trail` · the pre-log close source removed · `op_key` split per row (Q16) · the
"Finance settings" Record name · the bank account number unmasked · year close: closing journal unreachable / edits allowed · journal request:
posted journal dropped / approval homed elsewhere / a reader's direct edit allowed · claim: expense dropped · **M8: an empty code list treated as
"no code held" · M8: the `'page'` edge no longer refused** · Q4: per-row read rule bypassed · transfer: reversal journal unreachable / Record name
gone · WHT: reversal unreachable (Q30) / edits allowed · Q16 before the log: supersede stamp removed · forecast: a reader's direct edit allowed ·
depreciation charges dropped from the run's journal. **Two injections did not bite on the first try** (the `'page'` edge and the transfer's
Record name): both were blind assertions in the fixture (`->>` on an array, `NULL NOT LIKE …`), fixed with `IS DISTINCT FROM` / `COALESCE`;
every `<>` on a jsonb text value in 243 was swept to the same form.

**Wording check** (`TRAIL_WORDING_FAULT=<name>`):

| injection | arms that went red |
|---|---|
| `wording-drift-1c3` (new) | ⑩ only |
| `raw-ref` | ④ ⑥ ⑧ ⑨ ⑩ |
| `raw-null` | ④ ⑥ ⑦ ⑧ ⑨ ⑩ |
| `raw-date` | ④ ⑥ ⑦ ⑧ ⑨ ⑩ |
| `blind-detector` | ① (exit 3) |

**The four proof-found fixes**, each reverted in a full scratch copy of the tree (never the working tree): ⑩ red on exactly its golden —
`INJ_currency_OWN_EXIT=1`, `INJ_restricted_OWN_EXIT=1`, `INJ_donefold_OWN_EXIT=1`, `INJ_deletion_OWN_EXIT=1`; restored `RESTORED_OWN_EXIT=0`.

**Page probe** `scripts/probe-at1c3.mjs --inject=…`, run one after another after the plain run, each with its own exit line (`INJ_OWN_EXIT=1`,
`AT1C3_PROBE_EXIT=1`):

| injection | what went red |
|---|---|
| `m6-leak` | the Q25 lock-panel check |
| `no-close` | the Q25 lock-panel check (the month close must be there) |
| `refusal-wrong` | the Q6 `gm` deleted-statements check |
| `cjk` | all 18 fold-in-3 checks |

**Machine-token checks cover every new subject:** arm ⑩'s sweep runs every table of the twelve subjects with the page's own subject
(4 samples × 3 operations per table + 8 key-event sentences per subject; the count is computed from the registry and asserted); the smoke's
`trail` assertion scans the 14 new 1c-3 sections; the probe scans every trail section on every 1c-3 page.

## §7 · Live verification

### §7.1 · Before / after readings

- **Readings:** `db/scripts/2026-10-04-at1c3-live-readings.sql` (as `postgres`, base tables).
- **Reconciliation:** `list_ledger_reconciliation()` as tim@ (`db/scripts/2026-10-04-at1c3-live-recon.sql`).
- **Before:** 08:24:15 (before the backup and the migration). **After:** 10:39:07 (after both smokes, both probes, the probe injections and
  the two proofs).

| reading | before 08:24:15 | after 10:39:07 |
|---|---|---|
| tables · every-row digest | 241 · `2829081bdcc7` | 241 · `8c9005a73d27` (below) |
| change_log | 3394 rows, max seq 3993 | 3820 rows, max seq 4623 (below) |
| accounts | 7, 0 disabled | 7, 0 disabled |
| approvals | ON | ON |
| pending documents · their digest | 8 · `c113de0d5542` | 8 · `c113de0d5542` |
| settings row (lock · GST · whole-row digest) | 01/08/2026 · GST on M90312345A · `b1ec28c2d2ce` | identical |
| company profile (whole-row digest) | `b6afa17e8445` | identical |
| month / year closes | 1 · 0 reopened · 0 year closes | identical |
| journal requests · claims · transfers · WHT remittances · payment requests | 0 · 4 (last CLM-2026-0004) · 0 · 0 · 0 | identical |
| forecasts · recurring lines · import mappings · expenses · suppliers | 0 · 0 · 0 · 9 (last EXP-2026-0009) · 17 | identical |
| POs · journals · sales · freight · assets · statements · GST · FX · packs · contracts (1c-2's readings) | as 1c-2's after-reading | identical |

**Reconciliation**, before and after, identical: AP list 416,988.32 · ledger 376,404.42 · **unexplained 0.00** · agrees; AR list 57,545.87 ·
ledger 43,002.12 · **unexplained 0.00** · agrees.

**Why the digest and the change log moved.** The 426 change-log rows with `seq > 3993` (read as `postgres`) were grouped by table and operation,
then netted by row key.
- **Every key nets to zero except two.** The pairs that net to zero: the two smokes' and the two probes' ephemeral accounts (`user_roles` 24 / 24,
  `employees` 14 / 14, `performance_reviews` 6 inserts + 6 updates / 6 deletes); the smokes' roles (`roles` 2 / 2, `role_permissions` 144 / 144);
  the smokes' contract seed (`contracts` 4 / 4 and the six term tables 2–4 / 2–4).
- **The exception is `cod_verification_failures`:** row 146 deleted and row 148 inserted — the smoke's documented COD-verify probe (`not_found`
  branch rotates that table once per smoke). The table holds 1 row before and after. That rotation is the only net change on live, and it is
  what moved the digest.
- **The rolled-back proofs left nothing behind.** No change-log row falls inside any proof run; every count, last number, the settings and
  company-profile digests and the pending digest are identical. The sequence has **one gap, 204 numbers (seq 4219–4422), 10:06:51 → 10:10:49**,
  covering the first two proof runs (10:07:04, which failed and rolled back; 10:07:23); the third run (10:38) consumed the numbers above the last
  committed row — the sequence's `last_value` is **4768** while the highest row is **4623**. Sequences are not transactional, so those are the
  proofs' own change-log rows, written and then discarded by their rollbacks. The proofs also advanced document-number sequences
  (CLM-2026-0005, PREQ-2026-0001 … 0005, WHT-2026-10, FCST-2026-0001/0002, JE-2026-0080 …); a sequence advancing is not a row.

### §7.2 · Proof (`db/scripts/2026-10-04-at1c3-live-proof.sql`, `PROOF_OWN_EXIT=0`)

**A — read-only, as tim@ (and each claim as its own claimant):** **31 records** — the lock panel, the GST panel, the company profile, the 4
claims (finance view) and the same 4 as their claimants (`my_expense_claim`, M8: chooer@ ×3, fusheng@ ×1), 6 journals the list blocks read
(2 revaluation, 4 payroll), 1 relief expense, 12 FX rates, the deleted statement BS-2026-0001. Year closes, journal requests, transfers,
remittances, forecasts, recurring lines and import mappings have 0 live rows. Checks: none refused; every record with a page-level trail has
its creation (the GST panel and the company profile have no record on live — Step 0 §c); the lock trail carries the month close of
31/07/2026 (M7, before the log) and no settings column but `locked_before` (M6); nothing appears twice.

**B — one rolled-back transaction, approvals ON.** chooer@ (finance) submits, does and pays; tim@ (cfo) decides; sandra@ (cco) creates the
non-resident vendor; **fusheng@ (warehouse, no finance code) is the claimant**. It: moves the lock forward a month and back (chooer@, the
settings page's direct write, under `SET LOCAL ROLE authenticated` so the lock guards run as they do for the page) · changes the GST registration
number and the company address (tim@) · raises a journal request (tim@ approves) and a second one (withdrawn) · fusheng@ submits claim
CLM-2026-0005, chooer@ approves it · a bank transfer through its request (PREQ-2026-0001: tim@ approves, chooer@ pays), its notes edited, then
reversed through a reversal request · a withheld bill for the vendor, paid, the WHT remitted through its request (WHT-2026-10) and reversed
through a reversal request (Q30) · freezes the week's forecast twice (FCST-2026-0001 replaced by 0002) · adds a recurring line, changes its amount,
switches it off · saves, renames and deletes an import mapping · records two rates for 02/10/2026 in one bulk save. It refuses to start if a
forecast for that week or any rate for that date already exists on live (both 0). It reads every trail as tim@ (the claim again as fusheng@),
then **`ROLLBACK`**.

**Not in B, stated plainly:** **month close / reopen and year close.** 8 committed processing runs with no cost allocation (all dated on or
before 31/08/2026) make `close_period` refuse every month end after the lock (`PROCESSING_COSTS_UNALLOCATED`); allocating them would decide
pre-existing documents, which the brief forbids even inside a rollback; the year close needs a closed final month. Close and reopen are proved
by fixture 243 L on the rebuild through the real functions, and on live the lock trail reads the 31/07/2026 close. Registered as
`AT1C3-LIVE-MONTH-CLOSE-BLOCKED-BY-UNALLOCATED-RUNS`.

**The result** (`render-proof-1c3.mjs`: the real `buildEntries`, the real detector; the two grouped records merged through `mergeByOperation`):
- **46 records → 51 entries, 0 machine tokens**; both list blocks are **one entry per operation** (the re-freeze: 2 records, 1 operation → 1 entry;
  the bulk save: "Exchange rates recorded · 2 rates").
- The claimant's entry reads "Expense claim approved · CLM-2026-0005 … (Part of this change is restricted.)"; the finance view adds "[Expense
  recorded · EXP-2026-0010]".
- The transfer reads "Amount in (destination currency): 1,000.00 USD" (the leg's own currency); the WHT remittance reads "WHT remittance reversed ·
  Reversed by: JE-…" with its own "WHT remitted · WHT-2026-10" sentence.
- **The live lock trail (A) reads "Month closed up to 31/07/2026 · Entries: 18 · Total debits: 757,013.37 SGD · Total credits: 757,013.37 SGD".**

**One thing to read correctly** (as in 1c-1 and 1c-2): the whole proof is one transaction, so Q16 merges every event of one record into one
entry. On live, each person's action is its own transaction and gets its own entry; the lock moved forward and back in the proof nets to
nothing and therefore says nothing.

**What the proof found** (the first render, before the fixes in §3 corrections 4–7): the live lock trail printed the totals with no currency;
the forward-and-back lock move read "Restricted"; the remittance's creation lines sat under "WHT remittance reversed"; the mapping's deletion
dropped its rename. Fixed, goldens added, everything rerun (§5).

### §7.3 · Page probe `scripts/probe-at1c3.mjs` (cfo, admin and gm ephemeral accounts, port 3191)

**`AT1C3_PROBE_EXIT=0`: 42 passed · 0 failed · 1 skipped** (rerun after the fixes: the same). It checked:
- **Q25** `/finance/settings`: the lock section reads "Month closed up to 31/07/2026" and carries no GST or system-start wording; the GST section
  (empty on live) carries no month close or lock move.
- **Q29** `/finance/close`: the lock trail under close history (entries) and the year-close block (empty on live).
- **Q20** `/finance/claims`: one trail per claim (4), each with its submission.
- **Q6** `/finance/bank/statements`: admin's deleted-statements block lists BS-2026-0001 with a link; `gm` (no `data.view_deleted`) gets the named
  refusal.
- **Every 1c-3 page, both interfaces:** every trail section rendered, no machine token, **zh = en character for character** — `/finance/settings`
  (478), `/finance/close` (481), `/finance/company` (90), `/finance/revaluation` (928), `/finance/assets` (99), `/finance/fx` (5,111),
  `/finance/cash-forecast` (118), `/finance/payroll-payments` (1,583), `/finance/processing-costs` (606), `/finance/wht` (97), `/finance/bank` (96),
  `/finance/claims` (2,141), `/finance/bank/import` (121), `/finance/bank/statements` (686); controls: an AT-1a PO (657), an AT-1b batch (5,618),
  the AT-1c-1 journal JE-2026-0001 (667 = 667, the one 1c-1 could not explain — it matched again), an AT-1c-2 FX rate (503).
- **Skipped:** `/finance/journal` — 0 journal requests on live, so no per-request trail to read (fixture 243 J and proof B cover it).
- **Not probed: `/me`** — see §10 decision 23.

### §7.4 · Broken window

| | when | source |
|---|---|---|
| start | **2026-10-04 08:39:15 CST** | the migration's commit, `db/migration-windows.tsv` |
| end | the moment Tim sees the deployment Ready on Vercel | Tim's reading; this machine does not query Vercel |

**What is broken inside the window: nothing found.**
- Five functions replaced in place with the same signatures; `record_trail`'s return columns are unchanged.
- The old app never asks for the twelve new subjects; its 1c-1 / 1c-2 subjects read as before (the migration's own proof read them).
- Visible early, and intended: on `/settings/change-history`, journal-request rows and their approvals name the request instead of the posted
  journal; month closes name "Finance settings"; transfers name "Transfer DD/MM/YYYY · … → …".

## §8 · New wordings and labels

### §8.1 · Event wordings (English; `lib/trail/text.ts`, 44 new keys)

Prefixes are `plock.` `gstset.` `coprof.` `yclose.` `fcst.` `fcl.` `bip.` `btr.` — clear of `messages/en.ts`'s top-level namespaces (`check-i18n` reads
those prefixes as interface keys). Each wording was produced by the renderer and checked by hand; arm ⑩ pins 39 entries (36 sentences plus two one-operation cases and one "says nothing") as whole entries.
Reused, not new: `pr.done.wht_remittance_reversal` "WHT remittance reversed" (Q30), `pr.done.bank_transfer` / `_reversal`, `jr.*`, `exp.claim*`,
`je.posted`, `po.autoApproved`.

| key | English |
|---|---|
| `plock.moved` | Period lock moved |
| `plock.set` | Period lock set |
| `plock.removed` | Period lock removed |
| `plock.monthClosed` | Month closed up to {date} |
| `plock.monthReopened` | Month reopened from {date} |
| `plock.closeChanged` | Month close changed |
| `gstset.registered` | GST registration switched on |
| `gstset.deregistered` | GST registration switched off |
| `gstset.changed` | GST settings changed |
| `coprof.created` | Company profile created |
| `coprof.changed` | Company profile changed |
| `yclose.closed` | Year closed up to {date} |
| `yclose.reopened` | Year reopened · year ending {date} |
| `yclose.changed` | Year close changed |
| `je.posted.revaluation` | FX revaluation posted |
| `je.posted.depreciation` | Depreciation posted |
| `je.posted.payroll` | Payroll journal posted |
| `je.posted.year_close` | Year-end closing journal posted |
| `fxr.recordedMany` | Exchange rates recorded · {n} rates |
| `fcst.frozen` | Cash forecast frozen |
| `fcst.superseded` | Cash forecast replaced |
| `fcst.replacedBy` | Replaced by |
| `fcst.changed` | Cash forecast changed |
| `fcl.added` | Recurring line added |
| `fcl.changed` | Recurring line changed |
| `fcl.switchedOff` | Recurring line switched off |
| `fcl.switchedOn` | Recurring line switched back on |
| `fcl.removed` | Recurring line removed |
| `btr.changed` | Bank transfer changed |
| `bip.created` | Import mapping saved |
| `bip.changed` | Import mapping changed |
| `bip.deleted` | Import mapping deleted |
| `listTrail.intro.yearCloses` | Year closes · newest first · Singapore time |
| `listTrail.intro.revaluations` | FX revaluation runs · newest first · Singapore time |
| `listTrail.intro.depreciation` | Depreciation runs · newest first · Singapore time |
| `listTrail.intro.fxRates` | Exchange rates on this page, and withdrawn rates · newest first · Singapore time |
| `listTrail.intro.forecasts` | Frozen forecasts and recurring lines · newest first · Singapore time |
| `listTrail.intro.payroll` | Payroll journals · newest first · Singapore time |
| `listTrail.intro.costSettlement` | Processing-cost remittance journals and relief expenses · newest first · Singapore time |
| `listTrail.intro.wht` | WHT remittances · newest first · Singapore time |
| `listTrail.intro.transfers` | Bank transfers · newest first · Singapore time |
| `listTrail.intro.importMappings` | Import mappings, including deleted ones · newest first · Singapore time |
| `listTrail.intro.deletedStatements` | Deleted bank statements · newest first · Singapore time |
| `rowTrail.summary` | Audit trail |

List-block record names (built by the pages, English only): "Year ending DD/MM/YYYY", "JE-… · DD/MM/YYYY", "JE-… · remittance DD/MM/YYYY",
"EXP-… · relief DD/MM/YYYY", "USD · TT selling rate · DD/MM/YYYY", "FCST-… · week of DD/MM/YYYY", "Recurring line: <description>",
"WHT-…", "Transfer DD/MM/YYYY · <from> → <to>", "Mapping: <name>", "BS-… (deleted)", each with its state marker where it ended.

Message files (interface strings, not trail text): **added** `finance.fxPage.withdrawnTitle` 'Withdrawn rates' / '已撤回的汇率' and
`finance.fxPage.withdrawnHint` (en / zh).

### §8.2 · Field labels on the seven tables 1c-3 first shows (Q27 · Q28)

**76 shown columns, 0 labels equal to the column name; 20 hidden** (ids, the shared `updated_*` stamps, the logo's storage path). The source is
`lib/trail/catalogue.generated.ts`, from `scripts/gen-trail-catalogue.mjs`. Labels follow each page: the settings page ("Period locked before",
the GST panel's "Registered for GST" / "GST registration number"), `/settings/approvals` ("Level-1 approver role" …), the company form, the
recurring-lines form and the frozen table, the import page ("Mapping name"), the two close tables.

| record type | field (column) | label |
|---|---|---|

| finance setting | approval_level1_role_code | Level-1 approver role |
| finance setting | approval_level2_role_code | Level-2 approver role (at or above the threshold) |
| finance setting | approval_threshold_base | Approval threshold (base currency) |
| finance setting | approvals_enabled | Approvals are in force |
| finance setting | default_allocation_basis | Default cost allocation basis |
| finance setting | first_fy_end | First financial year end |
| finance setting | fy_end_day | Financial year end (day) |
| finance setting | fy_end_month | Financial year end (month) |
| finance setting | gst_rate_pct | GST rate % |
| finance setting | gst_registered | Registered for GST |
| finance setting | gst_registration_no | GST registration number |
| finance setting | locked_before | Period locked before |
| finance setting | system_start_date | System start date |
| month close | closed_at | Closed on |
| month close | closed_by | Closed by |
| month close | entries_count | Entries |
| month close | notes | Notes |
| month close | period_end | Period end |
| month close | reopen_reason | Reopen reason |
| month close | reopened_at | Reopened on |
| month close | reopened_by | Reopened by |
| month close | total_credits | Total credits |
| month close | total_debits | Total debits |
| year close | closed_at | Closed on |
| year close | closed_by | Closed by |
| year close | closing_journal_id | Closing journal |
| year close | net_result | Net result |
| year close | notes | Notes |
| year close | reopen_reason | Reopen reason |
| year close | reopened_at | Reopened on |
| year close | reopened_by | Reopened by |
| year close | reversal_journal_id | Reversal journal |
| year close | year_end | Year end |
| company profile | address_lines | Address |
| company profile | bank_account_name | Bank account name |
| company profile | bank_account_no | Bank account number |
| company profile | bank_address | Bank address |
| company profile | bank_name | Bank name |
| company profile | bank_swift | SWIFT |
| company profile | city | City |
| company profile | country | Country |
| company profile | email | Email |
| company profile | invoice_footer_text | Invoice footer text |
| company profile | legal_name | Legal name |
| company profile | phone | Phone |
| company profile | postal_code | Postal code |
| company profile | registration_no | Company registration no. |
| company profile | website | Website |
| cash forecast | base_currency | Base currency |
| cash forecast | buckets | Weekly figures |
| cash forecast | buffer | Fixed costs and cover |
| cash forecast | code | Forecast number |
| cash forecast | frozen_at | Frozen on |
| cash forecast | frozen_by | Frozen by |
| cash forecast | horizon_weeks | Horizon (weeks) |
| cash forecast | lines | Forecast lines |
| cash forecast | opening | Opening cash |
| cash forecast | promises_memo | Customer promises (memo) |
| cash forecast | superseded_at | Replaced on |
| cash forecast | superseded_by | Replaced by |
| cash forecast | superseded_reason | Why it was replaced |
| cash forecast | undated | Money with no date |
| cash forecast | week_start | Week starting |
| recurring forecast line | amount_ccy | Amount |
| recurring forecast line | cadence | How often |
| recurring forecast line | currency | Currency |
| recurring forecast line | direction | Direction |
| recurring forecast line | end_date | Last occurrence |
| recurring forecast line | is_active | Active |
| recurring forecast line | label | Description |
| recurring forecast line | notes | Notes |
| recurring forecast line | start_date | First occurrence |
| import mapping | bank_account_code | Bank account |
| import mapping | deleted_at | Deleted on |
| import mapping | mapping | Column mapping |
| import mapping | name | Mapping name |

### §8.3 · English for enumerated values (Q28)

| field | values |
|---|---|
| finance_settings · default_allocation_basis | weight → By weight; metal_value → By metal value |
| cash_forecast_lines · cadence | once → One-off; weekly → Weekly; monthly → Monthly; quarterly → Quarterly; annual → Annually |
| cash_forecast_lines · direction | in → Money in; out → Money out |
| bank_import_profiles · bank_account_code | 1000 → Cash at Bank – SGD; 1010 → Cash at Bank – USD |

## §9 · Checks that ran inside the build and the gate

- **i18n:** every referenced key in en and zh, including `finance.fxPage.withdrawnTitle` / `withdrawnHint`; trail wording lives in
  `lib/trail/text.ts` (English only — a trail renders identically in both interfaces, and the probe asserts zh = en per page).
- **Trail wording check** (`scripts/check-trail-wording.mjs`, in the build): arms ①–⑩ green; registry 56 subjects; arm ⑩ 39 goldens plus the
  machine-token sweep over every 1c-3 table.
- **Error swallowing:** 0 unallowed, 0 queued, 9 allowlisted (unchanged).
- **Masked reads:** `/finance/processing-costs` reads `processing_cost_entries_masked` (the first draft read the base table and was refused).
- **Currency literals:** clean (the proof's literal was replaced by a read from `currencies`).
- **Gate lines:** `changelog` 242 / 238 / 4 and `changemask` 27 / 81, no gaps; anon surface ⊆ baseline; `definer` 0; fixture 243 ✓.

## §10 · Decisions taken without asking

1. **M8, a subject with no page code.** The claimant's `/me` view (Q20) needs a reader who holds no finance code. Every subject until now
   required one of its `view_codes`; `my_expense_claim` declares none (`ARRAY[]::text[]`), so the claim's own read rule (finance, or the claim
   is yours) is the gate. `record_trail` refuses an empty code list with `root_rule = 'page'` (that would open the record to everyone) and still
   refuses `NULL`. Fixture 243 E proves the claimant, another employee (refused), and the `'page'` edge.
2. **Two subjects on one claim, not one.** `expense_claim` (finance page, `module.finance.view`) and `my_expense_claim` (no code) keep the finance
   page's gate exactly what the page's guard is — the `supplier` / `forwarder` precedent.
3. **A journal request and its approval now home on the request.** It is a subject root (Q17), and a pending request has no journal, so
   `journal_entry` ord 4–6 lost `home`. The summary page's Record column for those rows changes from the posted journal to the request's label,
   unlinked (it has no page of its own).
4. **The lock-move wording keeps §4's title and the page's label.** §4's example read "Period lock moved: 31/07/2026 → 31/08/2026"; the column
   is "locked **before**" (the first open day), so the trail says "Period lock moved" with the line "Period locked before: 01/08/2026 →
   01/09/2026" — the same words and dates the settings page shows. "Month closed up to …" is the close's period end; "Month reopened from …"
   is the first day of the reopened month. Lock set from nothing / cleared read "Period lock set" / "Period lock removed".
5. **Year-close wording** follows the month's: "Year closed up to DD/MM/YYYY" (closing journal a linked line, notes the reason) and "Year
   reopened · year ending DD/MM/YYYY" (reversal journal a linked line).
6. **Batch journals say what they are, on journal pages and list blocks only.** `revaluation`, `depreciation`, `payroll`, `year_close` journals
   read "FX revaluation posted", "Depreciation posted", "Payroll journal posted", "Year-end closing journal posted" on the `journal_entry`
   subject; other pages keep "Journal posted". `processing_cost` is left out: accrual and remittance journals share that source type, and
   only the cost entries know which is which.
7. **A depreciation run's per-asset charges are members of its journal** (`journal_entry` ord 7, home stays the asset), so the depreciation
   block and the journal page list each asset's charge as a line.
8. **Bulk FX reads as one sentence when one operation inserted several rates** ("Exchange rates recorded · N rates", a line per rate). A single
   rate's own page (one record) is unchanged.
9. **The withdrawn-rate entry point** (1c-2's queued item) is a "Withdrawn rates" list under `/finance/fx`'s table plus a link from every
   rate in the block; the table itself still lists live rates only.
10. **Deleted statements are a block on the statements list**, gated like the statement's own page (`data.view_deleted`); a reader without it
    sees a named refusal in that block, not an empty one.
11. **The processing-cost block reads the entries through `processing_cost_entries_masked`** (the masked-reads check) and shows a named
    refusal to a reader without `module.processing.view`. I did not widen `processing_cost_entry_lookup` with the two id columns: its header
    says adding a column widens what processing readers see, and that is a decision for you.
12. **List blocks read a bounded window** (24 runs; the FX page's rates + 50 withdrawn; 50 deleted statements; the page's 20 forecasts and 50
    transfers; the journal page's listed requests). Registered as `AT1C3-LIST-BLOCKS-READ-A-BOUNDED-WINDOW`.
13. **Per-row trails are collapsed** (`<details>`, "Audit trail") inside the card or row; every trail on a page shares `?trail=` and anchors to
    its own section (`anchor`). The smoke's `trail` check gained an `anchor` selector for the pages that carry two.
14. **Q8 as state markers.** No 1c-3 home is a record page a business event ends, so ended records in list blocks carry their state in the
    Record name: "(reversed)", "(replaced)", "(withdrawn)", "(deleted)", "(reopened)", "(switched off)".
15. **Two corrections in the shared renderer** (§3): a transfer's legs take their own accounts' currencies; a transfer's own edit is "Bank
    transfer changed". Both change what 1c-1's payment-request page says about a transfer; neither had a golden before; arm ⑩ pins them.
16. **`finance_settings` labels, all sixteen, are fixed in 1c-3** — the cut that first shows the table (your rule) — including the four
    approval-policy columns whose panel is AT-1d's: they already show on `/settings/change-history`.
17. **`company_profile.logo_path` is hidden** (a storage path; the page shows the image).
18. **Record-type names:** `period_closes` "month close", `bank_import_profiles` "import mapping" (the page's word), `cash_forecast_lines`
    "recurring forecast line".
19. **The payroll block lists every `payroll` journal** (accruals as well as payments), so its intro and title say "Payroll journals" /
    "Payroll journal posted".
20. **Journal-request trails on both kinds.** Q17 names new-entry requests (they have no page); reversal requests get the same per-card trail —
    it costs nothing and their target journal's page shows them too.
21. **The live proof does not close or reopen a month, nor close a year** (§7.2): 8 committed runs with no cost allocation block every month
    end after the lock, and allocating them would decide pre-existing documents. It moves the lock forward and back through the real path
    instead; close / reopen are proved by fixture 243 L on the rebuild. Registered as `AT1C3-LIVE-MONTH-CLOSE-BLOCKED-BY-UNALLOCATED-RUNS`.
22. **The proof's claimant is fusheng@** (warehouse, no finance code), so M8 and the Restricted decision are exercised by a reader who
    really lacks finance; chooer@ decides (level 1), tim@ decides the transfer, WHT and journal requests.
23. **`/me` is not probed at page level.** A throwaway account has no employee and no claim; making one would mean writing a claim on live.
    The claimant's view is proved by fixture 243 E and by proof B read as fusheng@'s own account.
24. **Fixture 243 writes two prerequisites directly as `postgres`:** a year close (its hard pre-checks need a closed final month) and a WHT
    remittance (it needs a withheld liability) — what the fixture tests is the trail they produce.
25. **Two blind assertions in fixture 243 were found by its own injections and fixed** (a `NULL NOT LIKE …` and an `->>` on an array).
26. **The wording check's registry parser now reads M7 and M8 rows** (`NULL` foreign key, `'all'` hop, `ARRAY[]::text[]`); before the fix it
    read 55 of 56 subjects and said so.
27. **The migration's own read check accepts an empty GST and company-profile trail** — neither row has a record on live (no pre-log source,
    no change since the log began).
28. **The proof takes the foreign currency from `currencies`**, not a literal (the currency-literal check refused the first draft).
29. **Four rendering defects found by the rolled-back proof were fixed in this cut** (§3, corrections 4–7), not queued: the period-close
    totals now carry the base currency (it showed on live); an entry whose every row netted away and none is hidden is skipped rather than
    read "Restricted"; the WHT done-fold no longer pulls the creation lines under the reversal; an import-mapping deletion keeps its other
    changed columns. Each has a golden and a revert that went red.
30. **The full gate was rerun once, immediately**, after its first run was stopped at the 1500 s bound with no verdict (§5 step 7) — no
    measurement said a delay would help, so the rule is one immediate retry. It passed in 368 s with output unbuffered and telemetry off.
31. **The gate was not rerun after the late fixes**: they touched `lib/trail/render.ts`, the wording check and docs, none of which the gate
    reads; every check that does read them (wording, tsc, survey, build, smoke, probe, proof render) was rerun (§5).

## §11 · Known issues and queue

**New in `docs/known-issues.md`:**
- `AT1C3-LIST-BLOCKS-READ-A-BOUNDED-WINDOW` — list blocks read the page's own window (decision 12); older records' trails are reached from
  their own rows or `/settings/change-history`.
- `AT1C3-LIVE-MONTH-CLOSE-BLOCKED-BY-UNALLOCATED-RUNS` — 8 committed processing runs with no allocation, dated on or before 31/08/2026, block
  every month end after the lock on live (test data; decision 21).
- `GATE-TYPES-CLI-HAS-NO-TIMEOUT` — the first full gate went silent after "NO DIFFERENCES" and was stopped at 1500 s; where it stalled is not
  proven. The rerun with unbuffered output and telemetry off passed in 368 s.

**`docs/forward-queue.md`:** item 28 records 1c-2's broken window; AT-1c-3 and AT-1c marked ✅; the 1c-3 window (start 2026-10-04 08:39:15
CST) is to be closed with Tim's Vercel reading at the next close-out. **Not done here, by the brief:** the approval-policy panel (AT-1d),
DATE-PICK-1, any AT-1d page. The `processing_cost_entry_lookup` widening (decision 11) is a question for Tim, not queued as work.
