# AUDIT-TRAIL-1b-1 — batch trails that keep every old row, work-order / stocktake / equipment / handover trails, the six registry extensions, and three corrections to AT-1a (2026-09-29)

Part of v1.4.33, not yet released.

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `039ff877d7000433f84ae405cbcc7381ea0911a4` (AT-1a close-out).
**Approvals were ON and stayed ON** (finance / cfo / 1,000). Every figure below is a script's own exit line, or a query named with who ran
it: `postgres` (`rolbypassrls = true`) on base tables unless stated; "as X" means `SET LOCAL ROLE authenticated` plus X's JWT.

Cut 1 of 3 of AT-1b (1b-1 → 1b-2 → 1b-3), per Tim's Q1. Reference for the mechanism: **`docs/change-log.md` §9** (§9.9 is new).

## §1 · Step 1 — the Step 0 hand-back is in the repo

`scratchpad/at1b/STEP0-HANDBACK.md` was copied unchanged to `docs/surveys/AUDIT-TRAIL-1b/STEP0-HANDBACK.md`, and a section was appended:
"Tim's answers, 2026-09-29: all Q1–Q14 accepted as recommended; split into 1b-1, 1b-2, 1b-3 inside v1.4.33.", with the three cuts'
scopes as Tim's block stated them.

## §2 · What was built

| ruling | built |
|---|---|
| M1 | `trail_subjects.view_codes` (text[]): **any one** code admits (`has_any_permission`). First real user: `warehouse_request` (inventory **or** finance) |
| M2 | `trail_prelog_sources.by_kind` (`account` / `employee`); `record_trail` hands an employee id to `trail_actor` as a person, not as an account. First real user: the handover's `acknowledged_by` |
| M3 | `trail_subjects.root_rule` (`table` / `page`): with `page` the page's code is the gate and the root row's own events are per-row (Restricted to a reader who fails the root table's rule). First real user: `equipment` (root `fixed_assets` is finance-only) |
| M4 · Q4 | `trail_subject_members.hop` (`down` / `up`) and `shown` (a stepping stone that is not part of the record) — plus `home`, the membership `trail_row_record` follows for the summary page's Record column (decision 2) |
| M5 | `record_trail` rebuilds the root key from the row's own typed value (a boolean key matched `{"id":"true"}` against `{"id":true}` and came back empty with no error) |
| M6 | `trail_subjects.root_columns`: a root limited to the columns its panel owns (changes that touch none of them are dropped; the rest are trimmed) |
| fold-in 1 | `trail_actor`: without `module.hr.view` a reader recognises only himself; everyone else is `restricted` — the `ActorName` rule, for both readers and every person-valued field |
| fold-in 2 | `/settings/change-history`: 20 operations, then "Show older entries" (`?show=40`, cap 500; read in chunks of 200 with the function's own keyset). Newest / Older are gone |
| fold-in 3 | every string inside a trail section is from `lib/trail/text.ts`: the summary page's empty states, paging note and "Show older entries"; the screen-reader "changed to" |
| Q32 · Q33 · Q4 · Q5 · Q6 | `inbound_batch` / `output_batch` subjects (39 + 36 member rows); the old batch Audit Trail replaced on both pages; state warnings as grey notes; the two old views kept, unread |
| Q26 | `work_order` subject; the work-order history list replaced |
| Q11 | `stocktake` subject; a pre-22/09 posting rebuilt from `posted_at`; posting and approval folded into one line |
| Q10 · Q22 · Q14 | `/operation/equipment` (list) and `/operation/equipment/[id]` (read-only, never reads `equipment_maintenance_advice`); `equipment` subject; reminder links repointed |
| Q23 | `/operation/handovers/[id]`, reached from the list's date cell and after submitting; `shift_handover` subject |
| Q12 | `warehouse_requests` read rule = inventory **or** finance; `amount_base` column-revoked and served by `warehouse_requests_masked` (`data.view_prices`); mask rule added; `/inventory` block (`RecentTrail`) reads `record_trail('warehouse_request', …)` per request; run page shows rollback requests |
| Q21 · Q8 | written-off batches and reversed runs open for their normal readers, read-only (`<fieldset disabled>`), with a banner "Written off / Reversed on DD/MM/YYYY by <name>", the reason as its second line, the date only when no one was recorded |

Migration: `db/migrations/2026-09-29-at1b1-trails-batches-and-operation.sql` (built from the mirrors by
`db/scripts/build_at1b1_migration.py`): three registry functions reshaped (DROP + CREATE), five replaced in place
(`record_trail`, `trail_actor`, `trail_ref_label`, `trail_row_record`, `change_log_mask_rules`), the `warehouse_requests` read rule and
column grant, one new view. No table column changed, no trigger rebound, no business row written, no permission code added. Fixtures
**237** and **238**.

## §3 · Pages — every new or changed route, with its file

| route | file(s) | change |
|---|---|---|
| `/inbound/[id]/edit` | `app/inbound/[id]/edit/page.tsx` | unified "Audit trail" replaces the batch Audit Trail; a written-off batch opens (was 404) read-only with its banner |
| `/output/[id]/edit` | `app/output/[id]/edit/page.tsx` | the same |
| `/operation/processing/[id]` | `app/operation/processing/[id]/page.tsx` | a reversed run opens (was 404) with its banner; the rollback control is visible and disabled; the trail adds rollback requests |
| `/operation/orders/[id]` | `app/operation/orders/[id]/page.tsx` | "Audit trail" replaces the work-order history list |
| `/stocktakes/[id]` | `app/stocktakes/[id]/page.tsx` | "Audit trail" at the bottom |
| `/operation/equipment` | `app/operation/equipment/page.tsx` (new), `app/operation/equipment/CellsTable.tsx` (new) | read-only machine list for processing access; nav entry under Operation (`lib/modules.ts`) |
| `/operation/equipment/[id]` | `app/operation/equipment/[id]/page.tsx` (new) | read-only machine page: details, service state, servicing, downtime, recent runs, a link to the asset card for finance readers, the trail |
| `/operation/handovers` | `app/operation/handovers/HandoversTable.tsx`, `app/operation/handovers/new/NewHandoverForm.tsx` | the date cell links to the handover; after submitting, the form lands on the new handover |
| `/operation/handovers/[id]` | `app/operation/handovers/[id]/page.tsx` (new) | the handover (people, shift, acknowledgement with its button, notes, items, referenced downtime with the machine) and its trail |
| `/inventory` | `app/inventory/page.tsx`, `app/components/trail/RecentTrail.tsx` (new) | a short "Audit trail" block under the warehouse-request panel |
| `/settings/change-history` | `app/settings/change-history/page.tsx` | fold-ins 2 and 3 |
| every trail section | `app/components/trail/AuditTrail.tsx`, `AuditTrailList.tsx`, `EndedBanner.tsx` (new) | seven more subjects; the page's subject passed to the renderer; screen-reader text from the catalogue; the Q21 banner and read-only wrapper |
| reminders `equipment_service_due` / `_approaching` | `lib/reminders.ts` | links to `/operation/equipment[/id]` (were `/finance/assets[/id]`) |

## §4 · Verification (in the order the brief set)

| # | step | verdict (the script's own line) |
|---|---|---|
| 1 | offline gate `db/gate.py --offline` | **`GATE_OFFLINE_EXIT=0`** (68 s wall; fixtures 236 · 237 · 238 ✓). Also before it: all static build checks except `next build` → `PRECHECKS_OWN_EXIT=0` |
| — | migration dry run on live (`COMMIT` → probe + `ROLLBACK`, the grants replay included) | **`DRY_OWN_EXIT=0`**, 2 min 13 s; probe: 10 subjects, `amount_base` not selectable by `authenticated`; in-transaction proof: tim@ read IN-2026-0001 (37 rows, all pre-log), the warehouse account read equipment FA's trail (5 rows) |
| 2 | backup (detached) | **`BACKUP_EXIT=0`**: `evoltrya-backup-2026-09-29-2054.dump`, 5.7 MB, TOC 7,289 (previous 7,257, floor 6,531), ~17 min |
| 3 | `db/apply_migration.sh` | **`APPLY_OWN_EXIT=0`**, preflight passed, in-transaction proof passed; **committed 2026-09-29 21:15:05 CST** (`db/migration-windows.tsv`) |
| 4 | `npm run types:gen` (after `NOTIFY pgrst`, `DO_NOT_TRACK=1`) | **`TYPES_OWN_EXIT=0`**, +234 / −1 lines (the new view; the reshaped registry functions) |
| 5 | `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** |
| 6 | `npm run build` | first run exit 1 (`lib/maskedTables.ts` out of step with the types — `warehouse_requests` is now masked) → `node scripts/gen-masked-tables.mjs` → **`BUILD_OWN_EXIT=0`** |
| 7 | full gate `db/gate.py` | **`GATE_EXIT=0`** (461 s): rebuildable ✓ · mirrors = live incl. types ✓ · fixtures incl. 236–238 ✓ · anon surface ✓ · `changelog` 238 / 242 ✓ · `changemask` 27 masked tables / 81 columns, zero gaps ✓ · `colgrant` / `colreader` ✓. Tree fingerprint identical before and after |
| 8 | `node scripts/check-i18n.mjs` | **`I18N_OWN_EXIT=0`** |
| 9 | `node scripts/check-error-swallowing.mjs` | **`SWALLOW_OWN_EXIT=0`** |
| 10 | layout survey `scripts/survey-phone.mjs --routes=…` (12 new or changed pages) | **390 px: 12 / 12 usable** (`SURVEY390_EXIT=0`), no page overflow, no clipped table; every trail section `entries` (the `/inventory` block `empty` — 0 warehouse requests live), section overflow 0, card layout. **1280 px: 12 / 12 usable** (`SURVEY1280_EXIT=0`), three-column grid, section overflow 0. `/operation/handovers/[id]` could not be surveyed: 0 handovers live (it is proved in §6 B) |
| 11 | smoke `scripts/smoke-routes.mjs` (detached) | first run **`SMOKE_EXIT=1`: 259 ok, 9 skipped (no data), 1 FAILED** — `/logistics/containers/[id]` → 503 with
`ConnectTimeoutError` reaching Supabase (the smoke's own note: "authentication unreachable, not this page"); that page is not touched by
this cut. Retried once, immediately (the repo's rule for a network failure) → **second run `SMOKE_EXIT=0`: 260 ok, 9 skipped (no data),
0 FAILED**, including the new `trail` assertions on `/inbound/[id]/edit` · `/output/[id]/edit` · `/operation/orders/[id]` ·
`/stocktakes/[id]` · `/operation/equipment/[id]` (`/operation/handovers/[id]` is an expected skip: 0 handovers live). Scratch cleanup
reading (the smoke's own report, both runs): **6 stale rows, all pre-existing** (`ZZ-SMOKE-PROBE` · `-M25` · `-NTF` · `-S25` · `-CJK` ·
`-IB25`, 655–1,297 h old, five still referenced) — the same six AT-1a reported; none from this session. `.ephemeral/` empty after every
run |
| — | page probe `scripts/probe-at1b1.mjs` (new; warehouse + admin sessions) | first run 15 passed · 6 failed — all six were the probe's own criteria (the crash pattern "This page could not be found"
is embedded in every dev page; a banner regex that did not allow the double space left by stripping tags; and the Chinese check tripped on
a record's **name**, "【SMOKE 冒烟脚本临时行…", which is data — Q8). Fixed the criteria (fold-in 3 is now "the trail section reads the same,
character for character, in the Chinese and English interfaces"), rerun → **`AT1B1_PROBE_EXIT=0`: 21 passed, 0 failed**: written-off
IN-2026-0002 opens for the warehouse account with its banner, reason, read-only form and trail; the admin reads "Written off on 08/09/2026
by Tim"; PROC-2026-0494 opens with its banner; PROC-2026-0002 (no one recorded) says the date only; the equipment list and FA-2026-0001's
page open for the warehouse account with an `entries` trail; `/inventory` has the block; names are Restricted in the warehouse account's
batch trail; the summary page offers "Show older entries" and no Newest; seven trail sections (two batches, a reversed run, a machine,
`/inventory`, PO-2026-0010, the summary page) read identically in the Chinese and English interfaces |
| 12 | live verification | §6 |

**Files that changed after the build and the full gate, and what was rerun.** After the probe's first run: `scripts/probe-at1b1.mjs`
(its criteria), `lib/trail/text.ts` + `app/components/trail/RecentTrail.tsx` (the `/inventory` block's empty state got its own sentence,
"No warehouse request has been recorded yet." — it had borrowed "…for this record yet"), `db/scripts/2026-09-29-at1b1-live-proof.sql`
(its incoming-person lookup) and the docs. The gate reads none of them (it reads the mirrors, fixtures and generated types); the build does,
so it was rerun: **`TSC_OWN_EXIT=0`, `BUILD_OWN_EXIT=0`** (includes the wording check, i18n, error swallowing and lint).

## §5 · Fault injection — every arm went red, the clean runs went green

- **Fixtures 237 / 238 — 20 injections** (`db/scripts/2026-09-29-at1b1-fixture-injections.py`, each a definition edit inside the fixture's
  own transaction, against a local rebuild; an injection that fails to apply refuses by itself): **`INJECTIONS_OWN_EXIT=0` — 20 / 20 red
  in the arm they target, both clean runs green.** M1 · M2 · M3 · M4 (two: stepping stones shown; no upward hop) · M5 · M6 · A (names never
  restricted; own name restricted too) · B (no upward hop → old rows lost) · B6 · J · K (assays not shown) · K6 · H · N · Q · S · W (mask rule
  removed; read rule back to finance only). The first round had one that went red somewhere else: Q crashed walking a refusal as a list —
  the fixture's arms now check a refusal before reading rows (seven arms hardened), and Q's first reader of the written-off batch is B3, where
  it now goes red.
- **`scripts/check-trail-wording.mjs`** — the machine-token detector caught my own first draft (a document code taken from a column the
  sampler fills with ids; metal codes printed raw; history headings built from a hidden column) before any page existed; rerun of its 11 named injections against the extended code: **11 / 11 red in their own arm** (ruler exit 3; registry, catalogue ×4, machine tokens ×5 exit 1).
- **Smoke `trail` assertion** — `SMOKE_TRAIL_FAULT=1` with `SMOKE_ONLY` on the five new trail pages → **all 5 FAIL**, each naming the injected uuid;
`SMOKE_EXIT=1`.
- **Page probe** — three named injections, each red in its own assertion (`AT1B1_PROBE_EXIT=1` each): `live-batch` → the three banner /
read-only / name checks; `cjk` → the Chinese-interface comparison, naming the character where the two renders part; `older-label` → the
paging check.

## §6 · Live verification

**Readings before / after** (`db/scripts/2026-09-29-at1b1-live-readings.sql`, `postgres`, `rolbypassrls = true`, 23:18:51 and 23:21:55
CST; `READ_OWN_EXIT=0` both times; the two outputs `diff` identical):

| reading | before | after |
|---|---|---|
| tables (excl. `change_log`) + digest of every row of every table | 241 · `c9aadb46675f` | 241 · `c9aadb46675f` |
| `change_log` | 1,326 rows, max seq 1,343 | 1,326 rows, max seq 1,343 |
| accounts | 7, 0 disabled | 7, 0 disabled |
| approvals | ON | ON |
| pending documents | 8 · `c113de0d5542` | 8 · `c113de0d5542` |
| purchase orders | 11, last PO-2026-0011 | 11, last PO-2026-0011 |
| batches · handovers · warehouse requests | 24 inbound · 20 output · 0 · 0 | 24 inbound · 20 output · 0 · 0 |

Reconciliation, as tim@ (`list_ledger_reconciliation()`): AP list 416,988.32 / ledger 376,404.42, AR list 57,545.87 / ledger 43,002.12,
**unexplained 0.00 on both sides**, both `agrees`. Every pending document still has a decider who is not its own party (the migration's
in-transaction proof ⑥ listed all eight).

**A · every live batch, row for row** (`db/scripts/2026-09-29-at1b1-live-proof.sql` part A; read as admin@, who holds 71 of 72 codes —
the missing one is `module.tasks.view_all`):

- **44 batches read · 292 old-view rows · 391 new trail rows (0 hidden to admin@) · old rows missing from the new trail: 0.**
- By kind, old rows / found: approval 11/11 · attribution 1/1 · cost_allocation 1/1 · cost_entry_change 7/7 · journal_entry 47/47 ·
  movement 107/107 · output_created 20/20 · price_change 14/14 · receipt 24/24 · report_issued 1/1 · reservation 3/3 · run_input 14/14 ·
  run_output 17/17 · sale 9/9 · sale_movement 9/9 · shipment 1/1 · stocktake_line 4/4 · work_order_change 2/2 (18 kinds live;
  `po_change` and `so_change` have 0 rows).
- **Upward-hop rows (Q4): 45 in the old view, 45 found.**
- Added kinds the old trail never showed: assay metals 14 · assays 8 · certificates of destruction 3 · certificate PDFs 2 · finance
  attachments 1 · freight allocations 1 · inbound metal content 19 · inbound safety states 1 · invoice lines 7 · output metal content 6 ·
  output safety states 1 · payment allocations 2 · prepayments 1.

**B · a handover, created and read inside the rolled-back transaction** (part B): submitted as the warehouse account (Fu Sheng — so the
name shows: it is his own, fold-in 1), outgoing Fu Sheng, incoming Choo Er, referencing the latest downtime; its trail read as that account
(2 rows) and rendered with `lib/trail/render.ts`:

```
29/09/2026 23:21  Fu Sheng  Shift handover submitted
      Shift: Day shift
      Handover date: 29/09/2026
      Incoming: Choo Er
      Outgoing: Fu Sheng
      Downtime: FA-2026-0001 · 23/08/2026 18:55
      Reason: AT-1b-1 live proof — rolled back
```

The first attempt stopped at my own setup (`HANDOVER_PEOPLE_REQUIRED` — I looked the incoming person up through tim@'s account, which
is not the `user_id` of any employee row) and the whole transaction was aborted; the readings above were taken around both attempts.

**C · pages** (the probe in §4, against live data): a written-off batch and a reversed run open with their banners; the equipment list and
a machine page open as the warehouse account's permissions; see §4's probe line.

## §7 · Broken window

**Start: 2026-09-29 21:15:05 CST** (the commit time; `db/migration-windows.tsv`). **End: when you see the Vercel deploy succeed** — that
reading comes from you, not from this machine.

**What is broken inside it:**
- **Nothing breaks.** The old app calls `record_trail` only with the three AT-1a subjects and unchanged arguments; the old batch pages read
  the old views, which did not change; `change_log_rows` did not change; no app code selects `warehouse_requests.amount_base` directly
  (the `/inventory` panel reads `warehouse_requests_visible()`).
- **Early, and intended:** fold-in 1 is in the database, so before the deploy the warehouse account already sees "Restricted" for other
  people's names on the three AT-1a trails.
- **During the apply itself (about 2 minutes, measured by the dry run):** replacing the `warehouse_requests` read rule held that table's
  lock until commit, so a read of the `/inventory` request panel in those two minutes would have waited (and could have timed out).

## §8 · Decisions I took without asking

Each is also recorded where it lives in the code.

**Database**
1. **`approval_log`'s `warehouse_request` branch stays finance-only.** Q12 widened `warehouse_requests` (inventory or finance, amount
   masked). The approval rows for those requests carry the request's amount, and `approval_log`'s amount columns are granted whole to
   `authenticated` with no masked view — widening that branch would hand the amount to the warehouse. The request's own row records who
   decided, when and why, so the warehouse sees the decision; the approval row is Restricted to them. `AT1B-WAREHOUSE-APPROVALS-FINANCE-ONLY`.
2. **A third member column, `home`** (not in Step 0's M4): with a table in several subjects, the summary page's Record column needs to
   know which membership is the row's home, or a processing input would suddenly "belong" to a batch. The walk also honours `match` now,
   so an `approval_log` row for a leave request no longer walks to a purchase order.
3. **Upward-hop scope:** for inbound batches the hops reproduce the old view exactly; for output batches the runs are reached through
   both the producing and the consuming side, so an output batch also shows the cost changes and cost journals of the run that produced
   it (the old view showed its journals but not its cost changes). Output write-off journals, which the old view never joined, are shown.
4. **Pre-log times are the row's `created_at`** (a movement, a sale), not the old view's `occurred_at` / business dates — rows written in
   one transaction then share a timestamp and read as one entry ("Goods received" with its receipt movement).
5. **No borrowed actors:** rows whose table keeps no "who" read "Not recorded" before the log began, instead of borrowing the parent
   document's creator as the old view did. `AT1B-PRELOG-ACTOR-NOT-RECORDED`.
6. **`trail_ref_label` gained three readings:** a processing run carries `ended` (it was rolled back); a handover reads
   "DD/MM/YYYY · shift"; a downtime reads "machine · DD/MM/YYYY HH:MM" (Singapore time) — those two tables have no code or name.
7. **The `/inventory` block uses a seventh subject, `warehouse_request`**, read once per request (the panel's own ≤ 5 requests, ≤ 10
   entries) and merged — "the same reader" rather than a new list-level function.
8. **A reversed run with no `deleted_at`** would take `updated_at` for its banner date. None exists: all four reversed runs carry
   `deleted_at` (as `postgres`, `processing_runs`).

**Wording and rendering**
9. **Wording is chosen per page subject** (`buildEntries(…, { subject })`): a processing input on a batch page reads "Used in processing
   PROC-…", on the run page it is part of "Processing completed". Events from another record reached one hop up carry that record's
   number at the end of their title ("Purchase order amended · PO-2026-0010"), and never head an entry on the record's own page.
10. **Machine-written approval notes are never shown:** the notes `post_stocktake` and `release_work_order` write are database sentences in
    Chinese (`MACHINE_NOTE_SUBJECTS`); the automatic-approval notes were already hidden.
11. **A reversal journal is recognised structurally** — another journal on the page points at it through `reversed_by` — never by its
    memo (fixture 181's intent). If the original is on an older page not yet loaded, the reversal reads "Journal posted · JE-…".
12. **Approvals fold into the event they approve** when both are in one operation (a work order's release, a stocktake's posting, a
    warehouse request's decision): the approval becomes a line under that event rather than a second heading (Q11 for stocktakes).
13. **A count and its stocktake line written together read once** (the count wins); a certificate of destruction created when a batch
    is fully processed reads "prepared — not issued yet", and "issued" only when it is.
14. **Label overrides** for 60 of the 385 columns (the generated label was wrong or read badly — e.g. a downtime's reason had been "On
    kilograms", a service description "Say what was done.", an invoice line's unit "Unit price", a certificate "Codes"); the batch, work
    order and stocktake codes are hidden from field lists (they are in the title and the page header).

**Pages**
15. **Q21 read-only is a `<fieldset disabled>` around everything below the page title** (links stay usable: print, label, other records);
    on the run page it wraps the rollback control. The banner is English (Q8), uses the `ActorName` rule for the name (a reader without
    HR sees "Restricted"), and says the date only when no person was recorded.
16. **The equipment list shows every asset card** — `equipment_usage`, the view processing readers can read, has no category.
    `AT1B-EQUIPMENT-LIST-EVERY-ASSET`.
17. **Equipment page performers** come from `handover_people` (employees) and `supplier_lookup` (suppliers); an id that does not resolve
    reads "Restricted", not blank. The page links to the asset card only for finance readers.
18. **The handover page carries the Acknowledge button** (the same button and gate as the list), and **submitting a handover lands on its
    page** (Q23).
19. **Both reminder links were repointed for every reader** — measured: every role holding `module.finance.view` also holds
    `module.processing.view`, so no one loses a path.
20. **`CellsTable`** (the new pages' small tables) always keeps its first column on phones — the build's phone check cannot see
    caller-supplied columns, and the identity column is the right one to keep.
21. **The old batch Audit Trail components** (`app/components/audit/*`) are left in the tree, unreferenced, to be removed with the two
    views they read (the i18n check still classifies their keys from those views).
22. **The summary page reads in chunks of 200** (the function's own cap) and scans five times what it shows when "Key events only" is on
    (was a fixed 100). Its page title, intro, mask note and filters stay bilingual (page chrome); five message keys that only served the
    removed paging and empty states were deleted from both message files.

**Tools and checks**
23. **Fixture 237 extends `trail_subjects()` inside its own transaction** with two temporary subjects, because M1 (partly), M5 and M6 have
    no real subject until 1b-2 / 1b-3.
24. **`scripts/check-trail-wording.mjs`** reads `SUBJECT_TABLES` from `lib/trail/render.ts` (replacing the three hard-wired table sets),
    parses the registry by row shape, finds a table's mirror even when it shares a file (`freight_allocations`), and sweeps every subject's
    tables again with that subject's page context.
25. **A new page probe, `scripts/probe-at1b1.mjs`**, signs in as a real warehouse account and as admin and asserts on the rendered pages
    (banners, read-only, equipment, the `/inventory` block, Restricted names, "Show older entries", no Chinese inside any trail section in
    the Chinese interface). The smoke signs in as admin only, and three things in this cut show only to a non-admin.
26. **`db/scripts/2026-09-29-at1b1-live-readings.sql` and `…-live-proof.sql`** are committed, so the before/after readings and the proof
    can be rerun (AT-1a's were not in the repo).
27. **Regenerated:** `lib/deepRoutes.generated.ts` (two new deep routes) and `lib/maskedTables.ts` (`warehouse_requests` is masked).

## §9 · For Tim to review: every wording and field label this cut adds (Q9 · Q11)

The trail prints only these sentences (plus values and names). Values in {braces} are filled with already-resolved words, never codes.

**Wordings added in 1b-1 (123 keys, `lib/trail/text.ts`)**

| key | wording |
|---|---|
| `srChangedTo` | changed to |
| `summary.empty` | No changes match these filters. |
| `summary.noRecordMatch` | No record matches “{q}”. |
| `summary.pageNote` | Newest first · Singapore time · {n} operations shown |
| `wrBlock.intro` | Recent warehouse requests · newest first · Singapore time |
| `wrBlock.empty` | No warehouse request has been recorded yet. |
| `banner.writtenOff` | Written off on {date} by {who} |
| `banner.writtenOffDate` | Written off on {date} |
| `banner.reversed` | Reversed on {date} by {who} |
| `banner.reversedDate` | Reversed on {date} |
| `batch.received` | Goods received |
| `batch.outputCreated` | Output batch created |
| `batch.writtenOff` | Batch written off |
| `batch.edited` | Batch details changed |
| `batch.stageStarted` | Processing started on this batch |
| `batch.stageDone` | Fully processed |
| `batch.stageBack` | Returned to stock to process (processing rolled back) |
| `batch.permitVerified` | Import permit verified |
| `batch.sourceReason` | Source reason recorded |
| `batch.priceFinal` | Receipt price finalised |
| `batch.noPurchaseOrder` | Not received against a purchase order |
| `batch.noCogs` | No cost-of-sales journal |
| `batch.runRolledBack` | This processing was later rolled back |
| `batch.movement` | Stock movement · {type} |
| `batch.priceChanged` | Price changed |
| `batch.usedIn` | Used in processing {run} |
| `batch.producedBy` | Produced by processing {run} |
| `batch.costFrom` | Processing cost allocated from {run} |
| `batch.useChanged` | Processing record for this batch changed |
| `batch.metalRecorded` | Metal content recorded |
| `batch.metalsChanged` | Metal content changed |
| `batch.metalRemoved` | Metal content removed |
| `batch.assayRecorded` | Assay recorded |
| `batch.assayApplied` | Assay applied to this batch |
| `batch.assayWithdrawn` | Assay result withdrawn |
| `batch.assayDeleted` | Assay deleted |
| `batch.assayChanged` | Assay changed |
| `batch.safetyAdded` | Safety state recorded |
| `batch.safetyRemoved` | Safety state removed |
| `batch.priceRequested` | Receipt price request raised |
| `batch.priceRequestWithdrawn` | Receipt price request withdrawn |
| `batch.priceRequestChanged` | Receipt price request updated |
| `batch.prepayment` | Prepayment applied |
| `batch.freight` | Freight cost allocated |
| `batch.payment` | Payment allocated |
| `batch.attachmentAdded` | Attachment added |
| `batch.attachmentRemoved` | Attachment removed |
| `batch.codIssued` | Certificate of destruction issued |
| `batch.codPending` | Certificate of destruction prepared — not issued yet |
| `batch.codVoided` | Certificate of destruction voided |
| `batch.codChanged` | Certificate of destruction updated |
| `batch.codPdf` | Certificate of destruction PDF issued |
| `batch.sold` | Sold |
| `batch.saleChanged` | Sale changed |
| `batch.saleStock` | Stock issued for the sale |
| `batch.saleAttributed` | Sale attributed |
| `batch.invoiced` | Invoiced |
| `batch.reserved` | Reserved for a sales order |
| `batch.reservationReleased` | Reservation released |
| `batch.reservationUsed` | Reservation used by a shipment |
| `batch.shipped` | Shipped |
| `batch.reportIssued` | Traceability report issued |
| `batch.settlement` | Sales settlement calculated |
| `batch.counted` | Counted in stocktake {code} |
| `journal.posted` | Journal posted · {code} |
| `journal.reversal` | Reversal journal posted · {code} |
| `journal.reversedBy` | Journal {code} reversed by {by} |
| `journal.laterReversed` | Later reversed by {by} |
| `journal.edited` | Journal changed |
| `approval.submitted` | {Thing} submitted for approval |
| `approval.approved` | {Thing} approved |
| `approval.approvedLevel` | {Thing} approved (level {level}) |
| `approval.rejected` | {Thing} rejected |
| `approval.auto` | {Thing} approved automatically (approvals were switched off) |
| `approval.other` | {Thing}: approval step recorded — {decision} |
| `wo.created` | Work order created |
| `wo.released` | Work order released |
| `wo.closed` | Work order closed |
| `wo.cancelled` | Work order cancelled |
| `wo.amended` | Work order amended |
| `wo.edited` | Work order edited |
| `wo.lineAdded` | Input line added |
| `wo.lineChanged` | Input line changed |
| `wo.lineRemoved` | Input line removed |
| `wo.expectedAdded` | Expected output added |
| `wo.expectedChanged` | Expected output changed |
| `wo.expectedRemoved` | Expected output removed |
| `st.started` | Stocktake started |
| `st.posted` | Stocktake posted |
| `st.cancelled` | Stocktake cancelled |
| `st.edited` | Stocktake edited |
| `st.count` | Count recorded |
| `st.recount` | Count changed |
| `st.lineRemoved` | Count removed |
| `eq.cardCreated` | Asset card created |
| `eq.cardEdited` | Asset card edited |
| `eq.service` | Service recorded |
| `eq.repair` | Repair recorded |
| `eq.workChanged` | Service record changed |
| `eq.workRemoved` | Service record removed |
| `eq.capitalised` | Work capitalised |
| `eq.down` | Downtime started |
| `eq.up` | Downtime ended |
| `eq.downChanged` | Downtime changed |
| `eq.intervalSet` | Service interval set |
| `eq.intervalChanged` | Service interval changed |
| `eq.intervalRemoved` | Service interval removed |
| `eq.handoverNote` | Mentioned in a shift handover |
| `ho.submitted` | Shift handover submitted |
| `ho.acknowledged` | Shift handover acknowledged |
| `ho.edited` | Shift handover edited |
| `ho.item` | Handover item added |
| `ho.downtime` | Downtime noted in the handover |
| `wr.raised` | {Kind} requested |
| `wr.approved` | {Kind} request approved and carried out |
| `wr.rejected` | {Kind} request rejected |
| `wr.withdrawn` | {Kind} request withdrawn |
| `wr.changed` | {Kind} request updated |
| `wr.kind.writeOff` | write-off |
| `wr.kind.rollback` | processing rollback |
| `wr.kind.codVoid` | certificate void |
| `wr.kind.other` | warehouse |
| `so.changed` | Sales order changed |

**Field labels on the tables this part adds (385 shown columns on 43 tables; ids, stamps and sequence columns never appear)**

| record type | field (column) | label |
|---|---|---|
| assay result metal | assay_result_id | Assay |
| assay result metal | content_pct | Content % |
| assay result metal | metal | Metal |
| assay result | applied_at | Applied on |
| assay result | applied_by | Applied by |
| assay result | assay_date | Assay date |
| assay result | certificate_ref | Certificate reference |
| assay result | code | Assay number |
| assay result | deleted_at | Deleted on |
| assay result | inbound_batch_id | Inbound batch |
| assay result | is_final | Final |
| assay result | lab_name | Laboratory |
| assay result | moisture_pct | Moisture % |
| assay result | notes | Notes |
| assay result | output_batch_id | Output batch |
| assay result | result_party | Whose result |
| assay result | sample_ref | Sample reference |
| assay result | superseded_by | Replaced by |
| assay result | weight_basis | Weight basis |
| certificate of destruction | code | Certificate number |
| certificate of destruction | completed_on | Processing completed on |
| certificate of destruction | inbound_batch_id | Inbound batch |
| certificate of destruction | issued_at | Issued on |
| certificate of destruction | issued_by | Issued by |
| certificate of destruction | replaced_by_cod_id | Replaced by certificate |
| certificate of destruction | snapshot | Certificate details |
| certificate of destruction | status | Status |
| certificate of destruction | void_reason | Reason voided |
| certificate of destruction | voided_at | Voided on |
| certificate of destruction | voided_by | Voided by |
| certificate PDF issue | cod_id | Certificate |
| certificate PDF issue | issued_at | Issued on |
| certificate PDF issue | issued_by | Issued by |
| downtime | duration | Duration |
| downtime | ended_at | Came back up |
| downtime | equipment_id | Equipment |
| downtime | notes | Notes |
| downtime | reason | Reason |
| downtime | started_at | Went down |
| service or repair | capitalisation_reason | Capitalisation reason |
| service or repair | capitalised | Capitalised |
| service or repair | capitalised_expense_id | Capitalised through expense |
| service or repair | description | What was done |
| service or repair | downtime_id | Downtime |
| service or repair | equipment_id | Equipment |
| service or repair | expense_id | Expense |
| service or repair | kind | Kind of work |
| service or repair | notes | Notes |
| service or repair | performed_by_employee_id | Done by (employee) |
| service or repair | performed_by_name | Done by (name) |
| service or repair | performed_by_supplier_id | Done by (supplier) |
| service or repair | performed_on | Done on |
| service interval | disposition | When it falls due |
| service interval | equipment_id | Equipment |
| service interval | interval_days | Every N days |
| service interval | interval_kg | Every N kilograms processed |
| service interval | kind | Kind of work |
| service interval | lead_days | Warn this many days before |
| service interval | lead_kg | Warn this many kilograms before |
| service interval | notes | Notes |
| finance attachment | claim_id | Claim |
| finance attachment | deleted_at | Deleted on |
| finance attachment | doc_type | Document type |
| finance attachment | expense_id | Expense |
| finance attachment | file_name | File name |
| finance attachment | inbound_batch_id | Inbound batch |
| finance attachment | notes | Notes |
| finance attachment | payment_id | Payment |
| finance attachment | sales_record_id | Sales record |
| fixed asset | acceptance_date | Acceptance date |
| fixed asset | acquisition_date | Acquisition date |
| fixed asset | category | Category |
| fixed asset | code | Asset number |
| fixed asset | cost_base | Cost (base currency) |
| fixed asset | cost_ccy | Cost |
| fixed asset | currency | Currency |
| fixed asset | depreciation_account_code | Depreciation account |
| fixed asset | description | Description |
| fixed asset | disposal_date | Disposal date |
| fixed asset | disposal_journal_id | Disposal journal |
| fixed asset | disposal_proceeds_base | Disposal proceeds |
| fixed asset | expense_id | Created by an expense |
| fixed asset | fx_rate | FX rate |
| fixed asset | in_service_date | In service from |
| fixed asset | notes | Notes |
| fixed asset | planned_in_service_date | Planned in service from |
| fixed asset | residual_base | Residual (base currency) |
| fixed asset | status | Status |
| fixed asset | useful_life_months | Useful life (months) |
| freight allocation | amount_base | Amount |
| freight allocation | basis_qty | Basis |
| freight allocation | freight_document_id | Freight document |
| freight allocation | in_stock_ratio | Share still in stock |
| freight allocation | inbound_batch_id | Inbound batch |
| inbound batch metal | content_pct | Content % |
| inbound batch metal | content_source | Content source |
| inbound batch metal | inbound_batch_id | Inbound batch |
| inbound batch metal | metal | Metal |
| inbound batch metal | source_assay_id | From assay |
| inbound batch safety state | inbound_batch_id | Inbound batch |
| inbound batch safety state | safety_state_code | Safety state |
| inbound batch | arrival_date | Arrival date |
| inbound batch | chemistry_certainty_code | Chemistry certainty |
| inbound batch | declared_qty | Declared quantity |
| inbound batch | deep_discharge_actual_code | Deep discharge (actual) |
| inbound batch | delete_reason | Reason written off |
| inbound batch | deleted_at | Written off on |
| inbound batch | deleted_by | Written off by |
| inbound batch | import_permit_ref | Import permit reference |
| inbound batch | import_permit_verified_at | Import permit verified on |
| inbound batch | import_permit_verified_by | Import permit verified by |
| inbound batch | imported | Imported |
| inbound batch | material_id | Material |
| inbound batch | notes | Notes |
| inbound batch | pricing_formula_id | Pricing formula |
| inbound batch | pricing_status | Pricing |
| inbound batch | purchase_order_id | Purchase order |
| inbound batch | purchase_order_line_id | Purchase order line |
| inbound batch | quantity | Quantity |
| inbound batch | remaining_qty | Remaining quantity |
| inbound batch | source_reason_code | Source reason |
| inbound batch | source_reason_note | Source reason note |
| inbound batch | source_reason_recorded_at | Source reason recorded on |
| inbound batch | source_reason_recorded_by | Source reason recorded by |
| inbound batch | stage | Stage |
| inbound batch | status | Status |
| inbound batch | supplier_id | Supplier |
| inbound batch | unit | Unit |
| inbound batch | unit_price | Unit price |
| stock movement | business_date | Business date |
| stock movement | inbound_batch_id | Inbound batch |
| stock movement | location_id | Location |
| stock movement | movement_type | Movement type |
| stock movement | notes | Notes |
| stock movement | occurred_at | Occurred on |
| stock movement | output_batch_id | Output batch |
| stock movement | qty_delta | Quantity change |
| stock movement | run_id | Processing run |
| stock movement | stock_status | Stock status |
| invoice line | amount_base | Amount |
| invoice line | amount_ccy | Amount |
| invoice line | description | Description |
| invoice line | invoice_id | Invoice |
| invoice line | invoice_voided | Invoice voided |
| invoice line | line_no | Line |
| invoice line | quantity | Quantity |
| invoice line | sales_order_line_id | Sales order line |
| invoice line | sales_record_id | Sales record |
| invoice line | tax_base | Tax |
| invoice line | tax_code | Tax code |
| invoice line | tax_rate_pct | Tax rate % |
| invoice line | unit | Unit |
| invoice line | unit_price | Unit price |
| journal entry | code | Journal entrie number |
| journal entry | entry_date | Entry date |
| journal entry | memo | Memo |
| journal entry | reversed_by | Reversed by |
| journal entry | source_type | Source type |
| journal entry | status | Status |
| output batch metal | content_pct | Content % |
| output batch metal | content_source | Content source |
| output batch metal | metal | Metal |
| output batch metal | output_batch_id | Output batch |
| output batch metal | source_assay_id | From assay |
| output batch safety state | output_batch_id | Output batch |
| output batch safety state | safety_state_code | Safety state |
| output batch | awaiting_operation_type_code | Awaiting operation |
| output batch | customer_id | Customer |
| output batch | delete_reason | Reason written off |
| output batch | deleted_at | Written off on |
| output batch | deleted_by | Written off by |
| output batch | material_id | Material |
| output batch | notes | Notes |
| output batch | output_date | Output date |
| output batch | purity | Purity / Grade |
| output batch | purpose_code | Purpose |
| output batch | quantity | Quantity |
| output batch | remaining_qty | Remaining quantity |
| output batch | state | State |
| output batch | status | Status |
| output batch | unit | Unit |
| payment allocation | allocated_base | Allocated (base currency) |
| payment allocation | allocated_ccy | Allocated |
| payment allocation | allocated_pay | Allocated (payment currency) |
| payment allocation | expense_id | Expense |
| payment allocation | freight_document_id | Freight document |
| payment allocation | inbound_batch_id | Inbound batch |
| payment allocation | invoice_id | Invoice |
| payment allocation | payment_id | Payment |
| payment allocation | purchase_order_id | Purchase order |
| payment allocation | sales_record_id | Sales record |
| payment allocation | withheld_base | Withheld (base currency) |
| payment allocation | withheld_pay | Withheld (payment currency) |
| prepayment application | amount_base | Amount |
| prepayment application | amount_ccy | Amount |
| prepayment application | currency | Currency |
| prepayment application | expense_id | Expense |
| prepayment application | inbound_batch_id | Inbound batch |
| prepayment application | journal_entry_id | Journal |
| prepayment application | notes | Notes |
| prepayment application | purchase_order_id | Purchase order |
| batch price change | currency | Currency |
| batch price change | fx_rate | FX rate |
| batch price change | inbound_batch_id | Inbound batch |
| batch price change | new_unit_price | New unit price |
| batch price change | notes | Notes |
| batch price change | old_unit_price | Previous unit price |
| batch price change | original_price | Original price |
| batch price change | rate_as_of | Rate as of |
| batch price change | rate_type | Rate type |
| pricing term commitment metal | commitment_id | Commitment |
| pricing term commitment metal | metal | Metal |
| pricing term commitment metal | payable_pct | Payable % |
| receipt price request | amount_base | Amount |
| receipt price request | assay_result_id | Assay |
| receipt price request | commitment_id | Commitment |
| receipt price request | currency | Currency |
| receipt price request | decided_at | Decided on |
| receipt price request | decided_by | Decided by |
| receipt price request | decision_notes | Decision notes |
| receipt price request | inbound_batch_id | Inbound batch |
| receipt price request | label | Request |
| receipt price request | notes | Notes |
| receipt price request | old_unit_price | Previous unit price |
| receipt price request | posted_unit_price | Posted unit price |
| receipt price request | result_journal_entry_id | Journal |
| receipt price request | snapshot | Request details |
| receipt price request | source | Source |
| receipt price request | status | Status |
| receipt price request | unit_price_ccy | Unit price |
| receipt price request | withdraw_reason | Withdraw reason |
| receipt price request | withdrawn_at | Withdrawn on |
| receipt price request | withdrawn_by | Withdrawn by |
| sale attribution | amount_base | Amount |
| sale attribution | attributed_at | Attributed on |
| sale attribution | attributed_by | Attributed by |
| sale attribution | customer_id | Customer |
| sale attribution | exposure_after | Exposure after |
| sale attribution | note | Note |
| sale attribution | sales_record_id | Sales record |
| sales order change | amend_reason | Reason |
| sales order change | detail | Detail |
| sales order change | line_no | Line number |
| sales order change | new_notes | New notes |
| sales order change | new_quantity | New quantity |
| sales order change | new_terms_text | New terms text |
| sales order change | new_unit_price | New unit price |
| sales order change | old_notes | Previous notes |
| sales order change | old_quantity | Previous quantity |
| sales order change | old_terms_text | Previous terms text |
| sales order change | old_unit_price | Previous unit price |
| sales order reservation | consumed_at | Consumed on |
| sales order reservation | consumed_by | Consumed by |
| sales order reservation | location_id | Storage location |
| sales order reservation | output_batch_id | Output batch |
| sales order reservation | qty | Quantity |
| sales order reservation | release_reason | Release reason |
| sales order reservation | released_at | Released on |
| sales order reservation | released_by | Released by |
| sales order reservation | sales_order_line_id | Sales order line |
| sale stock movement | movement_id | Movement |
| sale stock movement | sales_record_id | Sales record |
| sales record | amount_base | Amount |
| sales record | cogs_entry_id | Cost-of-sales journal |
| sales record | currency | Currency |
| sales record | customer_id | Customer |
| sales record | fx_rate | FX rate |
| sales record | notes | Notes |
| sales record | output_batch_id | Output batch |
| sales record | price_provenance | How the price was set |
| sales record | price_source | Price source |
| sales record | quantity | Quantity |
| sales record | sale_date | Sale date |
| sales record | sales_order_line_id | Sales order line |
| sales record | unit_price | Unit price |
| sales settlement | amount_usd | Amount (USD) |
| sales settlement | assay_result_id | Assay results |
| sales settlement | breakdown | Breakdown |
| sales settlement | computed_at | Computed on |
| sales settlement | computed_by | Computed by |
| sales settlement | gross_weight_kg | Gross weight (kg) |
| sales settlement | metal_value_usd | Metal value (USD) |
| sales settlement | moisture_pct | Moisture % |
| sales settlement | output_batch_id | Output batch |
| sales settlement | penalty_usd | Penalty (USD) |
| sales settlement | refining_charge_usd | Refining charge (USD) |
| sales settlement | sales_order_id | Sales order |
| sales settlement | settlement_weight_kg | Settlement weight (kg) |
| sales settlement | settling_party_used | Settling party used |
| sales settlement | superseded_by | Superseded by |
| sales settlement | terms_snapshot | Terms snapshot |
| sales settlement | weight_basis_used | Weight basis used |
| handover downtime note | downtime_id | Downtime |
| handover downtime note | handover_id | Handover |
| handover item | body | Details |
| handover item | handover_id | Handover |
| handover item | item_type_code | Type |
| shift handover | acknowledged_at | Acknowledged on |
| shift handover | acknowledged_by | Acknowledged by |
| shift handover | handover_date | Handover date |
| shift handover | incoming_employee_id | Incoming |
| shift handover | notes | Notes |
| shift handover | outgoing_employee_id | Outgoing |
| shift handover | shift_code | Shift |
| shift handover | submitted_at | Submitted on |
| shift handover | submitted_by | Submitted by |
| shipment line | location_id | Location |
| shipment line | output_batch_id | Output batch |
| shipment line | qty | Quantity |
| shipment line | reservation_id | Reservation |
| shipment line | sales_order_line_id | Sales order line |
| shipment line | sales_record_id | Sales record |
| shipment line | shipment_id | Shipment |
| stocktake count | book_qty | Book quantity |
| stocktake count | counted_at | Counted on |
| stocktake count | counted_by | Counted by |
| stocktake count | counted_qty | Counted quantity |
| stocktake count | inbound_batch_id | Inbound batch |
| stocktake count | notes | Notes |
| stocktake count | output_batch_id | Output batch |
| stocktake count | stocktake_id | Stocktake |
| stocktake count | stocktake_line_id | Stocktake line |
| stocktake line | book_qty | Book quantity |
| stocktake line | counted_at | Counted on |
| stocktake line | counted_qty | Counted quantity |
| stocktake line | inbound_batch_id | Inbound batch |
| stocktake line | notes | Notes |
| stocktake line | output_batch_id | Output batch |
| stocktake line | stocktake_id | Stocktake |
| stocktake | cancel_reason | Cancellation reason |
| stocktake | cancelled_at | Cancelled on |
| stocktake | cancelled_by | Cancelled by |
| stocktake | delete_reason | Delete reason |
| stocktake | deleted_at | Deleted on |
| stocktake | deleted_by | Deleted by |
| stocktake | notes | Notes |
| stocktake | posted_at | Posted on |
| stocktake | started_at | Started on |
| stocktake | status | Status |
| traceability report | code | Traceability report issue number |
| traceability report | issued_at | Issued on |
| traceability report | issued_by | Issued by |
| traceability report | output_batch_id | Output batch |
| warehouse request | amount_base | Amount |
| warehouse request | cod_id | Certificate of destruction |
| warehouse request | decided_at | Decided on |
| warehouse request | decided_by | Decided by |
| warehouse request | decision_notes | Decision notes |
| warehouse request | executed_at | Carried out on |
| warehouse request | inbound_batch_id | Inbound batch |
| warehouse request | kind | Kind |
| warehouse request | label | Request |
| warehouse request | output_batch_id | Output batch |
| warehouse request | reason | Reason |
| warehouse request | run_id | Processing run |
| warehouse request | snapshot | Request details |
| warehouse request | status | Status |
| warehouse request | withdraw_reason | Withdraw reason |
| warehouse request | withdrawn_at | Withdrawn on |
| warehouse request | withdrawn_by | Withdrawn by |
| work order expected output | basis | Where it came from |
| work order expected output | basis_reference | Basis reference |
| work order expected output | expected_qty | Expected quantity |
| work order expected output | material_id | Material |
| work order expected output | work_order_id | Work order |
| work order change | amend_reason | Reason |
| work order change | detail | Detail |
| work order change | new_notes | New notes |
| work order change | new_qty | New quantity |
| work order change | new_scheduled_date | New scheduled date |
| work order change | old_notes | Previous notes |
| work order change | old_qty | Previous quantity |
| work order change | old_scheduled_date | Previous scheduled date |
| work order line | material_id | Material |
| work order line | planned_qty | Planned quantity |
| work order line | work_order_id | Work order |
| work order | cancel_reason | Cancel reason |
| work order | cancelled_at | Cancelled on |
| work order | cancelled_by | Cancelled by |
| work order | close_reason | Close reason |
| work order | closed_at | Closed on |
| work order | closed_by | Closed by |
| work order | notes | Notes |
| work order | scheduled_date | Scheduled date |
| work order | status | Status |

**Value labels added in 1b-1**

| field | values |
|---|---|
| certificates_of_destruction · status | pending → Pending; issued → Issued; void → Void |
| inbound_batch_metals · content_source | assay → From an assay; manual → Entered by hand |
| output_batch_metals · content_source | assay → From an assay; manual → Entered by hand |
| finance_attachments · doc_type | invoice → Invoice; contract → Contract; receipt → Receipt; bank_slip → Bank slip; weighbridge → Weighbridge ticket; other → Other |
| equipment_service_intervals · kind | service → Service; repair → Repair |
| equipment_service_intervals · disposition | warn → Warn; ignore → Ignore |
| journal_entries · status | posted → Posted; reversed → Reversed |
| price_history · rate_type | tt_buy → TT buying rate; tt_sell → TT selling rate; mid → Mid rate |
| sales_records · price_source | computed → Calculated; manual → Entered by hand |
| sales_settlements · settling_party_used | ours → Our assay; counterparty → Counterparty's assay; umpire → Umpire assay |
| sales_settlements · weight_basis_used | as_received → As received; dry → Dry |
| stocktakes · status | open → Open; posted → Posted; cancelled → Cancelled |
| work_order_history · change_type | created → Created; released → Released; closed → Closed; cancelled → Cancelled; header_update → Details changed; line_add → Input line added; line_update → Input line changed; line_remove → Input line removed; expected_add → Expected output added; expected_update → Expected output changed; expected_remove → Expected output removed |

## §10 · Assertions in the brief that I measured

- "Add it to `docs/forward-queue.md` under UNBLOCK-1" — **no UNBLOCK-1 existed** (`grep -rn UNBLOCK docs/ AGENTS.md`: 0 hits). I created
  "UNBLOCK-1 · measured, not fixed, waiting on a ruling" and put Q14 in it.
- "Repoint the processing pages' equipment links from /finance/assets" — measured (`grep -rn "finance/assets" app/operation app/inventory
  app/tools app/components lib`): **the processing pages had none**; the only such links were the two equipment reminder arms in
  `lib/reminders.ts:198-203` (reached from the dashboard by processing readers). Those were repointed.
- "Keep every one of the 20 current kinds" — live holds **18** of them (`po_change` and `so_change` have 0 rows, as `postgres` on
  `batch_audit_trail_all`); fixture 238 exercises `po_change` and every upward kind; `so_change` is registered (sales-order history via
  the order line) with no live row to show.
- "Include the 45 upward-hop rows" — **45 of 45 found** (§6 A: `processing_cost` 19 + `allocation` 5 + `stocktake` 1 journals, 10 purchase-order and 1
work-order approvals, 7 cost-entry changes, 2 work-order changes — the same 45 the Step 0 measurement named).
- "All 7 real accounts stay enabled" — **7, 0 disabled**, before and after (§6).

## §11 · Docs

- **`docs/change-log.md`** — §4 (summary page paging and language); §9 intro and table (seven subjects + the run's rollback requests),
  §9.1 (any-of codes, root rule), §9.2 (`hop` / `shown` / `home`), §9.4 (summary paging), §9.5 (`by_kind`, the Q11 exception), §9.6
  (`SUBJECT_TABLES`, `root_columns`, boolean keys), §9.7 (Restricted names, machine-written notes, batch state notes), §9.8 (fixtures 237 /
  238, the new smoke assertions), new §9.9 (M1–M6).
- **`docs/forward-queue.md`** — AT-1b split into 1b-1 (✅) · 1b-2 · 1b-3 with their scopes; new **UNBLOCK-1** with Q14.
- **`docs/known-issues.md`** — `AT1B-EQUIPMENT-ADVICE-SHOWS-COSTS` (Q14) · `AT1B-WAREHOUSE-APPROVALS-FINANCE-ONLY` ·
  `AT1B-PRELOG-ACTOR-NOT-RECORDED` · `AT1B-OLD-BATCH-VIEW-DEFECTS` · `AT1B-EQUIPMENT-LIST-EVERY-ASSET`.
- **`docs/surveys/AUDIT-TRAIL-1b/STEP0-HANDBACK.md`** — the Step 0 hand-back and Tim's answers (§1).
