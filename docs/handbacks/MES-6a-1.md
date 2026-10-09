v1.4.48 — Samples and assay disputes: a new Quality section records samples (SMP-…) and who holds them until they are disposed of, an assay that disagrees with the other party can be put into a dispute that holds pricing and settlement until it is resolved, a laboratory can be linked to its supplier so an arbitration fee is recorded as an expense, and every expense reversal now asks for a reason.

# MES-6a-1 — samples, assay arbitration, lab → supplier, reasons on expense reversals (MES group, twelfth cut; 2026-10-09)

Tim's brief of 2026-10-09 ("MES-6a-1 — build: samples, assay arbitration, lab → supplier link, reasons on expense reversals (v1.4.48)"):
Q1 split (this cut = samples · arbitration · lab → supplier · F3; MES-6a-2 = F / Cl and the quality indicators), Q12 (warehouse **not** given
`module.quality.edit`), F3 per Q33–Q37, every other MES-6a Step 0 recommendation for this cut accepted as stated
(`docs/surveys/MES-6a/STEP0-HANDBACK.md`). Migration `db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql` (5,208 lines, built from the
mirrors by `db/scripts/build_mes6a1_migration.py`). Opening SHA: HEAD = origin/main = `git ls-remote origin main` =
`ba8638985c5dbe77dd52312c14032690a00bc00a` (tree clean).

---

## §1 · Opening live readings (before anything changed)

Read 2026-10-09 **20:02:18 CST** as `postgres` (`rolbypassrls = true`) over direct psql, `BEGIN READ ONLY … ROLLBACK`, base tables
(`db/scripts/2026-10-09-mes6a1-opening-readings.sql`, `READ_OWN_EXIT=0`).

| Reading | Value |
|---|---|
| Assays | **4**, all on inbound batches, all `ours`, all applied, none superseded, none deleted, 0 with a `sample_ref` · 0 on output batches |
| Laboratories | **1** (`FRL`, active) |
| Contracts | **0** (sell 0 · buy 0) · settlement terms 0 |
| Receipt price requests open from an assay | **0** |
| Expenses | **10**, all posted (8 unpaid · 2 paid) · 0 reversed · 0 mirrors · electricity reversals 0 |
| Permission catalogue | **75** codes (34 action) · 0 quality codes |
| Roles | admin 75 (missing none) · cco 42 · cfo 32 · cto 34 · finance 41 · gm 21 · warehouse 28 · auditor 20 · hr 8 · operations 15 · procurement 16 · sales 17 · employee 0 |
| Accounts | 7 — admin@ (admin) · chooer@ (finance) · fusheng@ (warehouse) · phua@ (cto) · sandra@ (cco) · tim@ (cfo) · vince@ (gm); 0 disabled · 0 throwaway |
| Standing state | approvals **ON** (level 1 `finance` · level 2 `cfo` · threshold 1,000) · `require_calibrated_since` **NULL** · `change_log` 24,434 rows (max seq 27,152) · notifications 2 |
| Pending documents | **1** — `expense_claim CLM-2026-0004` 1,000.00 (not mine) |
| Document types | **56** (no `SMP`) |
| Reconciliation (tim@, 21:51 CST, before the migration — `db/scripts/2026-10-05-at1d3-live-recon.sql`) | AP list 422,188.32 / ledger 381,604.42 / **unexplained 0.00** · AR 57,545.87 / 43,002.12 / **0.00** |

## §2 · Role-by-role reading table (live, measured)

Read inside the live proof (`db/scripts/2026-10-09-mes6a1-live-proof.sql` via `.mjs`, `MES6A1_PROOF_EXIT=0`, started 23:46:51 CST; transaction
12.2 s, ROLLBACK) after my own sample and dispute existed — live has none, so without them the pages and panel would read nothing. Each row is a
**one-off clone of a real role** (`mintThrowaway { cloneOf }`: exactly that role's codes at that moment — after the migration: admin 77 · finance 42 ·
warehouse 29 · cto 36 · cco 44 · cfo 33 · gm 21); no real account read or acted. The page gates are `requireFunction(FN.qualitySamples /
FN.qualityDisputes)` = `module.quality.view`; record / open / withdraw / umpire / fee / V16 = `module.quality.edit`; resolve = `action.apply_assay`;
the batch panel rows are what the clone reads itself through `sample_rows` / `assay_dispute_rows` on my inbound batch (2 samples, 1 dispute); the
expense page gate is `requireModule(MOD.finance)` = `module.finance.view`; reverse = `module.finance.edit`; the fee is `assay_dispute_rows.fee_amount_base`
as the clone reads it; the lab's supplier is written under `module.materials.edit`.

| Real role (live account) | `/quality/samples` and `/quality/disputes` | Take a sample · open a dispute · V16 | Resolve | Batch-page quality panel | Expense page | Reverse an expense | Arbitration fee on the dispute | Link a lab to its supplier |
|---|---|---|---|---|---|---|---|---|
| admin (admin@) | open | **yes** | **yes** | 2 samples · 1 dispute | open | **yes** | 850.00 | **yes** |
| finance (chooer@) | open | no | no | 2 · 1 | open | **yes** | 850.00 | **yes** |
| warehouse (fusheng@) | open | no | no | 2 · 1 | **refused** | no | **Restricted** | no |
| cto (phua@) | open | **yes** | **yes** | 2 · 1 | open | no | 850.00 | **yes** |
| cco (sandra@) | open | **yes** | no | 2 · 1 | open | no | 850.00 | **yes** |
| cfo (tim@) | open | no | no | 2 · 1 | open | no | 850.00 | no |
| gm (vince@) | **refused** (no `module.quality.view`) | no | no | **2 · 1** (via `module.inbound.view` — the panel shows to either code; its links to `/quality` are plain text for gm) | open | no | 850.00 | no |

How to read it: **taking samples and opening disputes is cto's, cco's and admin's**; warehouse **reads** (Q12 — adding `module.quality.edit`
to warehouse later is a one-line role change if Fu Sheng handles samples); **resolving is the assay applier's** (cto · admin), never quality edit
alone — the proof's `qe` (quality edit only) was refused `PERMISSION_DENIED|action.apply_assay`. The fee **amount** is shown to every holder of
`module.finance.view` (standing decision 1) and reads **Restricted** for warehouse, not 0. Those without a code see the control, disabled, with the
sentence naming the code (DBLOCK-1). **The only grant changes in this cut are the nine quality rows; no approval added (Q38).**

## §3 · Every item built

### §3.1 Database (one migration)

- **Four new tables** (all change-logged; RLS select only; writes through functions only):
  `samples` (`SMP-YYYY-NNNN`, gapless per year; exactly one batch — inbound or output; kind ours · counterparty · umpire · retained ·
  contamination; taken-on date required, never defaulted; optional mass, sales order (output only), contamination check (contamination only, a
  sampled check on the same output batch); keep-until date and its source copied at creation — contract days → V16 → not set — never changed);
  `sample_events` (append-only custody: taken · sent_to_lab · received_back · moved · disposed, `bigserial` order, one disposal at most, disposal
  needs a reason); `assay_disputes` (open → resolved | withdrawn only through the functions; one open per batch, unique index as the second layer;
  limit and fee rule copied from the sales order's contract snapshot when opened — buy side: none); `quality_settings` (one row: V16).
- **New columns:** `assay_results.sample_id` (nullable; a trigger and the function both refuse a sample from another batch, `SAMPLE_NOT_FOR_BATCH`) ·
  `laboratories.supplier_id` · `contract_settlement_terms.arbitration_fee_rule` (V14) · `expenses.reversal_reason / reversed_at / reversed_by`
  (+ `expenses_reversal_shape` CHECK; the row guard allows them only during posted → reversed, refuses a blank reason, and freezes them after).
- **Functions:** `record_sample` · `record_sample_event` · `set_quality_settings` · `open_assay_dispute` · `record_dispute_umpire` ·
  `withdraw_assay_dispute` · `resolve_assay_dispute` (`action.apply_assay`; **applies nothing**) · `link_dispute_fee` · `next_sample_code` ·
  `guard_assay_sample_batch`. Replaced: `record_assay_result` (+ `p_sample_id uuid DEFAULT NULL`, last; the old 12-argument signature dropped) ·
  `apply_assay_result`, `preview_assay_price`, `receipt_price_post_internal` (assay-sourced) and `sale_settlement_compute` refuse
  `ASSAY_DISPUTE_OPEN|<batch>|<dispute>` while a dispute is open (manual and committed-terms repricing still go through) · `apply_assay_result` /
  `apply_output_assay` supersede only the **same party's** previous result (D4) · `reverse_expense` (reason checked first after the code),
  `reverse_expense_internal` (refuses blank itself, stores the reason, mirror notes `REVERSAL: <code>`), `reverse_electricity_allocation` (passes its
  reason) · `trail_subjects` / `trail_subject_members` (subjects `sample`, `assay_dispute`, `quality_settings`; batch members).
- **Views:** `sample_rows` · `assay_dispute_rows` (fee amount masked to `module.finance.view`; counterparty share by V14) · `assay_dispute_metals` ·
  `assay_disagreements_all` (base, revoked). Replaced: `operations_now` (+ `sample_retention_due`, `assay_dispute_open`, `assay_results_disagree` →
  **62** arms) · `pending_values` (+ V16, V14 → **22** arms).
- **Codes and grants:** `module.quality.view` (admin · cco · cfo · cto · finance · warehouse) and `module.quality.edit` (admin · cco · cto);
  `action.apply_assay` declares `module.quality.view` among its view codes. Document registry `SMP` (56 → 57).
- **Proof inside the migration** (same transaction): the nine grants exactly, 77 codes, admin holds all, action-implies-view and edit-implies-view
  for every role, pending documents each still have a decider who is not the raiser, seven accounts enabled, pre-existing rows of every touched table
  byte-identical, new columns empty, `change_log` moved by 12 rows only, the four new tables empty (V16 empty), 62 / 22 arms, 114 mask rules,
  `require_calibrated_since` NULL. A COMMIT → ROLLBACK dry run on live passed twice before the real apply (`DRY_OWN_EXIT=0` 20:50 CST and
  `DRY_EXIT=0` 21:39–21:41 CST, the second on the final migration).

### §3.2 Fixtures

- **New:** 260 (SMP · CUST · RET · ASSAY · EARLY · CODES · READ · LOG · PV) and 261 (OPEN · HOLD · RESOLVE · D4 · SELL · FEE · DISAGREE · V14 · F3).
- **Changed, without weakening:** 100 (registries 56 → 57, SMP), 101 (48 → 49), 254 (57 rows), 111 (sixty-two arms), 40 (preview / apply parity under a
  dispute), 118 F5 (D4), 149 J (sell dispute refuses settlement; withdrawn → the same amount), 220 I6 (a waiting assay request cannot be approved while a
  dispute is open), 256 · 258 (reasons on single-argument reversals; 258 F3 arm).
- **Fault injection:** `db/scripts/2026-10-09-mes6a1-fixture-injections.py` — **70 cells** (30 on 260 · 32 on 261 · 8 on 40 / 118 / 149 / 220 / 258 /
  100 / 111), **0 wrong**, `INJECTIONS_OWN_EXIT=0` — run on a fresh rebuild **after the last database edit** (the `sample_rows` column order).

### §3.3 App

- **Quality section** in the Operation module (nav `Quality`): `/quality/samples` (list + the V16 panel + its trail), `/quality/samples/new`
  (two steps: pick a batch, then the form), `/quality/samples/[id]` (record, custody, record what happened, assays of this sample, trail),
  `/quality/disputes`, `/quality/disputes/new`, `/quality/disputes/[id]` (results side by side, umpire · resolve · withdraw, arbitration fee, trail).
- **Panels:** `QualityPanel` on both batch pages and both assay detail pages (samples, disputes, an open dispute says what it holds); the assay forms
  name the sample assayed (`?sample=` preselects it from a sample page).
- **F3:** the reverse dialog asks for a reason (confirm disabled while blank; the hint says not to write anyone's health details); the expense page's
  banner reads the reason from the original; the mirror's machine note is no longer printed as a memo. `EXPENSE_REVERSAL_REASON_REQUIRED` en / zh.
- **Dictionary:** laboratories gain a Supplier column/select (`module.materials.edit`). **Contract terms:** the arbitration fee rule select (V14).
- **Reminders:** the three new arms on `/tools/reminders`. **Pending values:** V16 and V14 wording. **Neutral party labels** (Ours · Counterparty ·
  Umpire) replace "The buyer" in en / zh and in the trail catalogue.
- **Trail:** catalogue rows for the four tables and six new columns, `set.quality`, reversal reason on the expense and expense-claim trails,
  wording arm ㉖ (ten sentences, fault `wording-drift-mes6a1` red in ㉖ only).
- **Registries:** search 57 / 57 · documents 290 / 88 · deep routes · smoke `ID_SOURCES` / `EXPECTED_SKIPS` / trail expectations · throwaway prefix
  `mes6a1probe` · check-i18n manifest (eight new dynamic prefixes, all enumerable).

## §4 · Pages — every new or changed route, with its file

| Route | File | New / changed |
|---|---|---|
| `/quality/samples` | `app/quality/samples/page.tsx` (+ `SamplesTable.tsx`, `QualitySettingsPanel.tsx`) | new |
| `/quality/samples/new` | `app/quality/samples/new/page.tsx` (+ `SampleForm.tsx`, `BatchPicker.tsx`, `batchOptions.ts`) | new |
| `/quality/samples/[id]` | `app/quality/samples/[id]/page.tsx` (+ `SampleEventForm.tsx`, `SampleTables.tsx`) | new |
| `/quality/disputes` | `app/quality/disputes/page.tsx` (+ `DisputesTable.tsx`) | new |
| `/quality/disputes/new` | `app/quality/disputes/new/page.tsx` (+ `OpenDisputeForm.tsx`) | new |
| `/quality/disputes/[id]` | `app/quality/disputes/[id]/page.tsx` (+ `DisputeActions.tsx`, `FeeLinkForm.tsx`, `MetalsTable.tsx`) | new |
| `/inbound/[id]/edit` | `app/inbound/[id]/edit/page.tsx` (+ `app/components/quality/QualityPanel.tsx`) | changed |
| `/output/[id]/edit` | `app/output/[id]/edit/page.tsx` | changed |
| `/inbound/[id]/assays/[assayId]` | `app/inbound/[id]/assays/[assayId]/page.tsx` | changed |
| `/output/[id]/assays/[assayId]` | `app/output/[id]/assays/[assayId]/page.tsx` | changed |
| `/inbound/[id]/assays/new` | `app/inbound/[id]/assays/new/page.tsx` · `AssayForm.tsx` · `../actions.ts` (+ `app/components/quality/SamplePickerField.tsx`, `sampleOptions.ts`) | changed |
| `/output/[id]/assays/new` | `app/output/[id]/assays/new/page.tsx` · `OutputAssayForm.tsx` · `../actions.ts` | changed |
| `/finance/expenses/[id]` | `app/finance/expenses/[id]/page.tsx` · `ReverseExpenseButton.tsx` · `actions.ts` (+ `app/finance/expenseErrorCodes.ts`) | changed |
| `/settings/dictionaries` | `app/settings/dictionaries/page.tsx` · `DictSection.tsx` · `registry.ts` | changed |
| `/contracts/[id]` | `app/contracts/[id]/termSpecs.ts` (settlement terms → arbitration fee rule) | changed |
| `/settings/pending-values` | `messages/en.ts` · `messages/zh.ts` (V16 · V14) | changed (wording) |
| `/tools/reminders` | `lib/reminders.ts` (three arms) | changed |

## §5 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | Offline gate | `GATEOFF_EXIT=0` (83 s; 264 fixtures, 260 and 261 among them) |
| 2 | Backup | first attempt **`BACKUP_EXIT=1`** (21:41 → 22:02 CST: `pg_dump` lost its SSL connection during `COPY public.change_log`; the script deleted the partial file); retried once immediately (house rule) → **`BACKUP_EXIT=0`** (22:03 → 22:28 CST, `evoltrya-backup-2026-10-09-2203.dump`, 7.4 MB, TOC 8,689 ≥ floor 7,743). `select 1` measured 4.7–6.3 s that evening |
| 3 | Apply | `APPLY_EXIT=0`; applied at 22:29:40 CST, committed **22:33:44 CST** (`db/migration-windows.tsv`: `2026-10-09T22:33:44+0800 … ba863898`) |
| 4 | Types | `NOTIFY pgrst, 'reload schema'` then `types:gen` `TYPESGEN_OWN_EXIT=0` — only this cut's 4 tables, 4 views, 8 functions added |
| 5 | tsc | first run 1 file (`batchOptions.ts`, a union `from()` argument) → split into two calls → `TSC_OWN_EXIT=0` |
| 6 | Build | `BUILD_EXIT=0` (every static check + `next build`) |
| 7 | Full gate | `GATE_EXIT=0` (640 s): rebuild matches live · 264 fixtures · 290 tables / 282 logged / 8 exempt · 38 masked tables / 114 columns · types match live · anon surface a subset of the 328-line baseline |
| 8 | i18n | `I18N_OWN_EXIT=0` — 255 dynamic prefixes, all enumerable, 2,765 keys checked |
| 9 | Error swallowing | `SWALLOW_OWN_EXIT=0` — 0 unallowed |
| 10 | Layout survey | 16 pages × **390 px and 1280 px: 0 page overflow, 0 clipped tables** (`SURVEY_EXIT=0` both). The two `[id]` pages have no live row (none may be created on live) — measured on temporary, uncommitted copies rendering the same components with fixed data (the MES-5b-3 precedent); deleted before the smoke. **Not measured:** `/contracts/[id]` (live has 0 contracts) and `/output/[id]/assays/[assayId]` (live has 0 output assays) — both changes are the same components already measured elsewhere (one more select row in the settlement-terms editor; the same `QualityPanel`) |
| 11 | Smoke | `SMOKE_EXIT=0` — **283 ok · 16 skipped (no data, including `/quality/samples/[id]` and `/quality/disputes/[id]`, registered) · 0 failed** (1,703 s, median 5.9 s per route). Scratch cleanup reading: 0 smoke accounts, 0 probe roles, 0 grants without an account on live afterwards; the six stale `ZZ-SMOKE-*` rows it reports (four still referenced) predate this cut and were not touched |
| 12 | Live verification | §6 |

## §6 · Live verification

### §6.1 Rolled-back proof — `db/scripts/2026-10-09-mes6a1-live-proof.sql` via `.mjs` (`MES6A1_PROOF_EXIT=0`, 23:46:51 CST; transaction 12.2 s, ROLLBACK)

Fourteen throwaway accounts (`mes6a1probe-…`): `qe` (quality view + edit, inbound / output view), `rec` (inbound / output view + edit), `apl` (assay
applier), `cfo` (the **real cfo role** itself — the level-2 approver is a role, a clone cannot decide), `dict` (materials edit), `fin` (finance view +
edit), `sal` (customers view + edit, output view, pricing view), and the seven role clones. My own setting (owner inserts, prefix `ZZ-PROBE-MES6A1`):
two suppliers (default input tax code `OP` — live is GST-registered), a material, two laboratories, an inbound batch with a committed purchase formula,
an output batch, **my own USD rate and ni quote for 2026-10-09 (live had none)**, an LME September calendar and quotes, a customer, a contract (limit 0.5,
fee split equally), a sales order.

| Step | What happened (read back from the proof's own lines) |
|---|---|
| start | reconciliation AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** |
| ① sample | qe took **SMP-2026-0001** (ours, 200 g; keep-until *Not yet set* — V16 empty) · sent to my lab (ref LAB-REF-1, state *at lab*) · received back (state *held*, 3 custody lines) · rec recorded an assay naming it · a sample of another batch refused `SAMPLE_NOT_FOR_BATCH` |
| ② held | apl applied our assay → an assay price request waiting for the CFO · qe opened a dispute (buy side: limit not set, no fee rule) · apl applying the counterparty result and previewing its price both refused with the **same** `ASSAY_DISPUTE_OPEN|IN-2026-0500|…` |
| ② posting refused | the CFO approving that waiting request refused `ASSAY_DISPUTE_OPEN|…` — still submitted, no journal, no price |
| ② resolved | umpire sample and result recorded · qe could not resolve (`PERMISSION_DENIED|action.apply_assay`) · apl resolved naming the umpire result — content, applications, requests, price and journal count **identical (nothing applied)** |
| ② hold lifted | the CFO approved the request after the resolution (unit price 3.7170 SGD) · AP 422,560.02 / 381,976.12 / **0.00** · AR **0.00** |
| ③ sell side | sales order linked to my contract; settlement computed before · qe opened a dispute (limit 0.5 and "split equally" copied in) → settlement refused `ASSAY_DISPUTE_OPEN|OUT-2026-0689|…` · withdrawn → settlement **identical** to before |
| ④ fee | qe could not link the lab (`PERMISSION_DENIED|module.materials.edit`) · dict linked my umpire lab to its supplier · fin recorded an unpaid expense of 850.00 SGD to that supplier · qe linked it to the dispute · AP 423,410.02 / 382,826.12 / **0.00** · AR **0.00** |
| ⑤ reversal | no reason and a blank reason both refused `EXPENSE_REVERSAL_REASON_REQUIRED|EXP-…` (first check after the code) · reversed with a reason → stored trimmed on the original with who and when; mirror notes `REVERSAL: EXP-…` · AP / AR **0.00** |
| ⑥ roles | §2 |
| untouched | pre-existing batches, metal content, assays, price requests, contracts, terms, sales orders, expenses, payments, journals, laboratories, suppliers, rates, quotes, finance settings and V16 byte-identical; pending still only `expense_claim CLM-2026-0004`; approvals on; reconciliation **0.00 / 0.00** |
| after ROLLBACK | samples 0 · disputes 0 · probe suppliers 0 · probe labs 0 · labs linked to a supplier 0 · V14 set 0 · V16 NULL · reversal reasons 0 · `require_calibrated_since` NULL |

The first attempt (`PROOF_EXIT=1`, 23:43 CST) stopped at step ④ on `TAX_CODE_REQUIRED|supplier` (live is GST-registered; my local rehearsal was not).
The transaction rolled back and the driver cleaned up (read back: 0 probe accounts, 0 probe roles, the cfo role back to its one holder, 0 samples,
0 disputes). Fixed by giving my two suppliers a default input code `OP`, rehearsed locally with GST registered, then the run above.

### §6.2 Read-only — the role table

§2 (inside the proof, as clones of the seven real roles' codes).

### §6.3 Before and after

`db/scripts/2026-10-06-mes1-live-readings.sql` (every public base table: count + digest; `READ_BEFORE_OWN_EXIT=0` 21:51:14 CST, `READ_AFTER_OWN_EXIT=0`
23:49:08 CST, after the proof) and `2026-10-05-at1d3-live-recon.sql` (tim@'s session; `RECON_*_OWN_EXIT=0`).

| Reading | Before | After |
|---|---|---|
| Per-table digests (286 base tables before, 290 after) | — | **every one identical** except: the four new tables (samples 0 · sample_events 0 · assay_disputes 0 · quality_settings 1); the migration's own rows (`permissions` 75 → 77 · `role_permissions` 349 → 358 · `document_types` 56 → 57); `assay_results`, `expenses`, `laboratories` — **only because they gained columns**: recomputed over their pre-migration columns the digests equal the before values exactly (`fb75a9f3223a` · `54de8ed3bd53` · `25b58e08fedd`) and every new column is NULL on every row; `cod_verification_failures` — the smoke's documented COD probe row (`failed_at` 23:38:59 CST, during the smoke; it deletes itself after 10 minutes) |
| Accounts | 7 · 0 disabled · 0 throwaway · 0 grants without an account | **same** |
| Roles | admin 75 · cco 42 · cfo 32 · cto 34 · finance 41 · warehouse 28 · gm 21 | admin **77** · cco **44** · cfo **33** · cto **36** · finance **42** · warehouse **29** · gm 21 — exactly the nine quality grants |
| Approvals | ON (finance / cfo / 1,000) | ON (finance / cfo / 1,000) |
| Pending | `expense_claim CLM-2026-0004` 1,000.00 | same |
| `require_calibrated_since` | NULL | NULL |
| Nothing of mine | — | 0 samples · 0 disputes · 0 lab links · V14 none · V16 NULL · 0 reversal reasons · 0 `ZZ-PROBE-MES6A1` rows · 0 `mes6a1probe` accounts |
| Reconciliation | AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** | **identical** |
| `change_log` | 24,615 rows (max seq 27,346) | 26,473 (max 29,484) — the migration's 12 rows, the smoke's and the proof's throwaway-account events, and the COD probe |

### §6.4 Broken window

**Start: 2026-10-09 22:33:44 CST** (measured, `db/migration-windows.tsv`). End: when Tim confirms the deployment (this machine does not query
Vercel — AGENTS.md). **What is broken in the window** (derived, not measured on live): the deployed app's expense page sends no reason, so **every
expense reversal on the old app is refused** `EXPENSE_REVERSAL_REASON_REQUIRED` (the old app prints its fallback sentence) until the deploy; live has
never reversed an expense (opening: 0). The old assay forms call `record_assay_result` by named parameters without `p_sample_id` → its default, so they
work. Dispute refusals only bite when a dispute exists, and the old app has no way to open one. The old pages do not read the new tables.

## §7 · Decisions taken without asking

1. **Two-step "new" pages:** `/quality/samples/new` and `/quality/disputes/new` first pick a batch with a plain GET form (`?batch=inbound:<id>` /
   `output:<id>`), then show that batch's own lists. The batch and assay pages link straight to step two.
2. **V16 lives on `/quality/samples`** as a panel with its own trail (the electricity-settings precedent); emptying it is allowed (back to *Not yet set*);
   the panel says a new value applies only to samples recorded afterwards.
3. **The quality panel is drawn for holders of either code** (quality view or the batch's own view); for a reader without `module.quality.view` its links
   to `/quality` are plain text, not dead links. "Open a dispute" is not offered while one is open (the database refuses it anyway).
4. **The assay forms' sample picker** lists every sample of the batch, disposed ones included (an assay can be of a sample later disposed of).
5. **Reminder links:** retention due → the sample page; open dispute → the dispute page; disagreeing results → the output batch page (its quality panel
   opens a dispute).
6. **The fee picker** lists only posted expenses to the umpire lab's supplier (latest 100) and only for finance-view holders; others read "ask finance to
   link it". A lab with no supplier says where to link it.
7. **The resolve picker** lists every live result of the batch (ours, counterparty, umpire).
8. **Neutral labels everywhere the party is named:** besides "The buyer" → "Counterparty", `assay.party_umpire` "Umpire laboratory" → "Umpire"
   (zh 仲裁实验室 → 仲裁) and zh 我方 → 我们, so the three families read the same words.
9. **The expense page** reads the banner's reason, who and when from the original (`reversal_reason` · `reversed_at` · `reversed_by`); reversals made
   before this cut fall back to the mirror as before. The mirror's machine note `REVERSAL: <code>` is no longer printed as a memo (the "Reversal of …"
   banner says it); a legacy mirror that carries a typed reason still shows it.
10. **The reason hint** sits in the dialog body ("…do not write anyone's health details here"); the placeholder is an example, not an instruction.
11. **Trail:** samples, custody lines and disputes use the generic family (the MES-5b-3 precedent); V16 uses the settings family ("Internal sample
    retention changed"); the area is a new **Quality**; `retain_until_source` reads "The contract / The internal period / Not set" in the trail.
12. **The reversal reason on the trail** is read from the original's `reversal_reason` on both the expense trail and the expense-claim trail.
13. **`sample_rows.state` is the first branch column** in the view, because check-i18n reads the state labels from the file's first branch.
14. **Smoke:** both list pages map to their tables; both `[id]` pages are in `EXPECTED_SKIPS` (live has none — the assertion will fire the day the first
    sample / dispute exists); the `/quality/samples` trail is `emptyOk` (V16 never changed on live).
15. **Layout survey of the `[id]` pages on temporary copies** (never committed, deleted before the smoke).
16. **The live proof inserts its own USD rate, ni quote and LME September calendar / quotes** inside the rolled-back transaction (live had none), and
    gives its own suppliers default input tax code `OP`.
17. **The CFO decision in the proof** is taken by a throwaway holding the **real cfo role** (`{ realRole: 'cfo' }`, removed afterwards) — the level-2
    approver is the role.
18. **The backup was retried once** after the SSL drop (house rule: retry once, then stop). The failed dump's server session stayed
    `idle in transaction` holding 584 AccessShareLocks (`idle_in_transaction_session_timeout` is 0 on live); `pg_terminate_backend` was **refused by this
    session's permission check**; the session was gone by itself when re-read at 22:14 CST, before the retry finished and before the migration.
19. `dict.noSupplier` reads "Not linked"; the dispute list shows "largest difference · limit L" or "limit not set".
20. `setQualitySettings` refuses a non-integer before calling the database, with the same named sentence the database would give.

## §8 · Assertions measured and found false or imprecise

**Zero** of the brief's assertions measured false: the SHA, the clean tree, 7 accounts enabled, approvals ON finance / cfo / 1,000, admin holding all 75
codes, `require_calibrated_since` NULL — each read at the opening. Stale records corrected in this cut (Step 0 Q45): `assay_results.sql`'s old comment
(14-15: `is_final` "decides superseding") · `docs/forward-queue.md`'s MES-5b-2 close-out note "expense reversals have no reason field" (annotated, kept) ·
U12's two lines reconciled (sell side answered, buy side open).

**Two things of my own, recorded here so they are not mistaken for nothing:**
- At **21:34:13 CST** (before the backup) I imported `scripts/smoke-routes.mjs` to inspect it; the script runs on import and **started a smoke run
  against live** (dev server, a throwaway all-codes account, page loads only — GETs). I stopped it with SIGTERM; its own cleanup ran and I read back 0
  smoke accounts, 0 probe roles, 0 grants, no live lock, no pending cleanup plan. It wrote nothing else that I can find.
- The first live proof run failed (§6.1) and rolled back cleanly.

## §9 · Docs updated

`docs/forward-queue.md` (item 47; MES table 9a ✅ / 9b next; V17 and N38 under MES-6b; Q12 note; U12 reconciled; the MES-5b-2 note) ·
`docs/mes-pending-values.md` (V16, V14 rows and notes; V15 none; V17 deferred) · `docs/known-issues.md` (D4 and "The buyer" registered and closed; N38
re-pointed to MES-6b; the reversal-reason note beside `U1B-EXPENSE-CLAIM-DESCRIPTION-IN-EXPENSE-NOTES`) · `docs/role-matrix.md` (quality codes) ·
`docs/change-log.md` §23 · `docs/dashboard-arm-inventory.md` (three arms) · `db/migration-windows.tsv` (window start).
