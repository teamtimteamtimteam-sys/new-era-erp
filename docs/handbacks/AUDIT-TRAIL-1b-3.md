# AUDIT-TRAIL-1b-3 — master data and tools: material, storage-location, metal-price, pricing-formula, task and threshold-panel trails; deleted records open read-only (2026-10-03)

Part of v1.4.33, not yet released.

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `f8530f1da89767cc2d1b2afb6c638a1be34e8924` (AT-1b-2), measured at
**2026-10-03 09:18:04 CST** (this session's first command). **Approvals were ON and stayed ON** (finance / cfo / 1,000). Every figure
below is a script's own exit line, or a query named with who ran it: `postgres` (`rolbypassrls = true`) on base tables unless stated;
"as X" means `SET LOCAL ROLE authenticated` plus X's JWT.

Cut 3 of 3 of AT-1b (1b-1 → 1b-2 → 1b-3); **AT-1b is complete**. Reference for the mechanism: **`docs/change-log.md` §9** (§9.10 is new).
This cut adds subjects; it does not change the mechanism (no change to `record_trail`, `trail_actor`, `trail_row_visible`, masking or
any policy).

## §1 · Step 1 — the 1b-2 close-out

**The broken window** is recorded in `docs/forward-queue.md` (item 25, the 1b-1 format): start **2026-09-30 01:06:27 CST**
(`db/migration-windows.tsv`) · end lower bound **02:57:40 CST** (the push that moved `origin/main` to `f8530f1d`, `git reflog show --date=iso
refs/remotes/origin/main`) · end upper bound **2026-10-03 09:18:04 CST** (this session's first command, holding your "deployed" — a
report, not a Vercel reading). **1 h 51 min 13 s to 80 h 11 min 37 s (3 d 8 h 11 min 37 s).** The upper bound is wide because three
days passed between the push and this session; it bounds when "deployed" was said, not how long the deploy took. Committed together
with this cut's work (all four items below were present).

**The read-only checks the 1b-2 report did not mention, item by item:**

| | item | result | evidence |
|---|---|---|---|
| a | the sales-order page keeps its "amended since issued" notice and its "From quote" link, fed by the kept history query | ✅ | `app/sales/orders/[id]/page.tsx:63-73` — the narrowed query: `.from('sales_order_history').select('change_type, detail, changed_at').in('change_type', [...AMEND_TYPES, 'converted_from_quote'])`; `:88-91` `lastAmendAt` / `amendedSinceIssue` from it; `:97-102` `fromQuoteCode` (`converted_from_quote` detail) → `quotes` lookup; rendered at `:130-141` (the "From quote" link, falling back to the code when the quote cannot be read) and `:150-154` + `:234-238` (the two amber notices). `converted_from_quote` and the four amend types are in the table's CHECK (`db/tables/sales_order_history.sql:29,36`) |
| b | pre-log history (Q1) merged for the 1b-2 subjects, under the divider, nothing shown twice | ✅ | registered: `db/functions/trail_prelog_sources.sql` (quotes · quote_history · sales_orders · sales_order_history · shipments · customers · suppliers + `approved_at` stamp · containers · … :94-171); divider drawn above the first pre-log entry: `app/components/trail/AuditTrailList.tsx:135,150-153`; fixture 239 arms D + N (`db/fixtures/239-…sql:331-` — creation + history one entry, six history rows all there, `so_issues`/`qt_issues` not rebuilt, `f239_twice` null). **Live, read-only as tim@** (`scratchpad/at1b3/s1b.sql`, `S1B_OWN_EXIT=0`): SO-2026-0001 18 rows, QT-2026-0001 6, SHP-2026-0001 5, CTR-2026-0002 4 — every row pre-log, **0 shown twice**, 0 pre-log rows ordered above a logged entry. No 1b-2 record on live has both logged and pre-log rows (queried: suppliers / customers created before the log with a change-log row — none), so the "above / below the divider" ordering on live is shown only by the fixture |
| c | the shipment page under M1 (either of two permissions) and forwarders under M3 each have their own fixture arm | ✅ | fixture 239 arm **H** (`:200-218`): a `module.sales.view` reader and an `action.ship_goods`-only reader both read the shipment; no-code and logistics-only readers refused by name. Arm **F** (`:276-290`): a logistics-only reader reads the forwarder with the supplier row Restricted (M3); a suppliers.view reader sees the root row. Both are injection-tested (`db/scripts/2026-09-30-at1b2-fixture-injections.py`: "M1 any-of → first code only" → red in H; "M3 page rule ignored" → red in F) |
| d | change-log §9 covers the 1b-2 subjects; the forward queue marks 1b-2 complete and lists the four remaining Step 0 labels under 1b-3 | ✅ | `docs/change-log.md` §9 table rows for the eleven 1b-2 subjects, §9.5 (quotes and orders before the log; suppliers' stamp), §9.6, §9.7, §9.8, §9.9 (M1 / M3 users); `docs/forward-queue.md` "✅ AT-1b-2(2026-09-30)" and, under "⬜ AT-1b-3", the four labels ("Make this a team task", "Choose a source", "Wo input overrun %", "Notes en") |

## §2 · What was built

| ruling | built |
|---|---|
| Step 0 §a registry | eight subjects in `trail_subjects()` — `material` · `storage_location` · `metal_price` · `pricing_formula` · `task` · `processing_settings` · `pricing_settings` · `receiving_settings` — and their 10 member rows in `trail_subject_members()` (counted: rows of the eight subjects in the mirror) |
| Q2 | the trail sits at the bottom of `/materials/[id]/edit`, `/inventory/locations/[id]/edit`, `/tools/pricing/metal-prices/[id]/edit`, `/tools/pricing/formulas/[id]/edit` (their only pages) |
| Q13 | `save_storage_location` (new, SECURITY DEFINER, gated on `module.inventory.edit`): the location row is written only if it changed, the allowed classes only where they changed (delete the unticked, insert the newly ticked), all in one call — replacing three separate writes in `app/inventory/locations/actions.ts`; new and edit both use it |
| Q3 · Q26 | `task` subject: steps, participants, history; personal tasks too (the root must pass `tasks`' own read rule — team, own, or `module.tasks.view_all` — the same test as opening the page). The task page's "Change history" section is replaced; its two components are deleted |
| M5 · M6 | the three threshold panels: `root_columns` = the panel's own columns (processing 2, pricing 1, receiving 3); pages pass `'true'`; each trail sits under its panel, in the same branch that shows the panel |
| Q1 · M2 | pre-log sources for the 1b-3 tables (creation and deletion stamps; formula and task history; a formula's creation and metals and a team task's step creation / tick folded with their history rows); task tables' actors are employee ids |
| Q9 · Q21 · Q8 | `deleted_records` gains customers, suppliers, materials, formulas (who: from the change log; none recorded → NULL); deleted customers, suppliers, materials, formulas, sales orders, quotes and purchase orders open read-only with "Deleted on DD/MM/YYYY by <name>" / the date only for `data.view_deleted`; a named refusal for everyone else; `/settings/deleted` lists and links the new kinds and fixes the sales-order and quote links (and the purchase-order, batch and run links) |
| labels | **57 labels changed on the 17 tables** (7 of them the Step 0 four and their same-shape siblings), **12 columns newly hidden**, **2 kind changes**, **0 changes outside these tables** — measured by diffing the committed `lib/trail/catalogue.generated.ts` (`git show HEAD:`) against the regenerated one, shown columns only (`scratchpad/at1b3/labeldiff.mjs`); every one checked against its page (§10); value maps; `materials.unit`'s Chinese-stored values (吨 / 克 / 件) read in English (Q8) |

Migration: `db/migrations/2026-10-03-at1b3-trails-master-data-and-tools.sql` (built from the mirrors by
`db/scripts/build_at1b3_migration.py`): three registry functions replaced in place (same signatures), one new function
(`save_storage_location`), one view replaced with the same columns (`deleted_records`). No table, policy, grant on a table, trigger or
permission code changed; no business row written. Fixture **240**.

## §3 · Pages — every new or changed route, with its file

| route | file(s) | change |
|---|---|---|
| `/materials/[id]/edit` | `app/materials/[id]/edit/page.tsx` | "Audit trail" at the bottom (Q2); a deleted material opens read-only with its banner for `data.view_deleted`, a named refusal otherwise (was 404) |
| `/inventory/locations/[id]/edit` | `app/inventory/locations/[id]/edit/page.tsx`, `app/inventory/locations/actions.ts` | "Audit trail" at the bottom (Q2); save and create through `save_storage_location` (Q13) |
| `/inventory/locations/new` | `app/inventory/locations/actions.ts` | create through `save_storage_location` (one call instead of two) |
| `/tools/pricing/metal-prices/[id]/edit` | `app/tools/pricing/metal-prices/[id]/edit/page.tsx` | "Audit trail" at the bottom (Q2) |
| `/tools/pricing/formulas/[id]/edit` | `app/tools/pricing/formulas/[id]/edit/page.tsx` | "Audit trail" at the bottom (Q2); a deleted formula opens read-only with its banner (deactivate / delete visible, disabled) |
| `/tools/tasks/[id]` | `app/tools/tasks/[id]/page.tsx`; deleted `ChangeHistory.tsx`, `ChangeHistoryTable.tsx` | "Audit trail" replaces "Change history" (Q26), on personal tasks too (Q3) |
| `/operation/orders` | `app/operation/orders/page.tsx` | the variance-threshold panel's trail under the panel (M5 · M6) |
| `/tools/pricing/metal-prices` | `app/tools/pricing/metal-prices/page.tsx` | the price-anomaly panel's trail under the panel |
| `/purchasing/discrepancies` | `app/purchasing/discrepancies/page.tsx` | the discrepancy-threshold panel's trail under the panel (in the `module.inbound.view` branch) |
| `/sales/customers/[id]` | `app/sales/customers/[id]/page.tsx` | a deleted customer opens read-only (edit link → disabled button; credit section says it is not worked out for a deleted customer) |
| `/suppliers/[id]/edit` | `app/suppliers/[id]/edit/page.tsx` | a deleted supplier opens read-only with its banner |
| `/sales/orders/[id]` | `app/sales/orders/[id]/page.tsx` | a deleted sales order opens read-only with its banner (no amend entry) |
| `/sales/quotes/[id]` | `app/sales/quotes/[id]/page.tsx` | a deleted quote (absent from `quote_status`) is read from `quotes` and opens read-only with its banner |
| `/purchasing/orders/[id]` | `app/purchasing/orders/[id]/page.tsx` | a deleted purchase order opens read-only with its banner (its action row is not drawn) |
| `/settings/deleted` | `app/settings/deleted/page.tsx` | customers · suppliers · materials · formulas listed; every kind linked |
| every page above | `app/components/moduleGuard.tsx` (`requireDeletedAccess`), `app/components/trail/EndedBanner.tsx` (`kind: 'deleted'`, `DeletedBanner`), `app/components/trail/AuditTrail.tsx` (eight subjects), `lib/trail/render.ts`, `lib/trail/text.ts` | shared pieces |

## §4 · Verification (in the order the brief set)

| # | step | verdict (the script's own line) |
|---|---|---|
| 1 | offline gate `db/gate.py --offline` | **`GATE_OFFLINE_EXIT=0`** (66 s; fixture 240 ✓). Before it, every static build check except `next build`: `PRECHECKS_OWN_EXIT=0` |
| — | migration preflight + dry run on live (the built file with `COMMIT` → grants replay + `ROLLBACK`) | **`PREFLIGHT_OWN_EXIT=0`** (3 functions replaced · 2 new — the second is the proof's temporary helper); first dry run stopped at proof ⑥ (`TRAIL_NOT_PERMITTED|task`: tim@ reading another person's personal task — correct behaviour; the proof was wrong, see decision 25), fixed → **`DRY_OWN_EXIT=0`**, 1 min 47 s. The proof also caught, before any run, that a new function is still PUBLIC-executable when the in-body proof runs (the grants replay comes after it) — the migration now revokes / grants it explicitly right after the CREATE |
| 2 | backup (detached) | **`BACKUP_EXIT=0`**: `evoltrya-backup-2026-10-03-1012.dump`, 5.5 MB, TOC 7,311 (previous 7,311, floor 6,579), 10:12 → 10:28. Alive while it ran: its server backend was checked (`idle in transaction`, `dumpFunc` statements) while the file was still 0 bytes, not assumed |
| 3 | `db/apply_migration.sh` | **`APPLY_OWN_EXIT=0`**; preflight passed; in-transaction proof passed (29 subjects; grants unchanged; 8 pending documents unchanged, each with a decider not its own party; `change_log` unchanged; deleted customers 4 / suppliers 8 / materials 4 / formulas 0 listed for tim@, equal to the base tables; every task's history rows on its trail for its owner); **committed 2026-10-03 10:31:01 CST** (`db/migration-windows.tsv`) |
| 4 | `npm run types:gen` (after `NOTIFY pgrst` + 15 s, `DO_NOT_TRACK=1`) | **`TYPES_OWN_EXIT=0`**, +11 lines (`save_storage_location`) |
| 5 | `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** |
| 6 | `npm run build` | **`BUILD_OWN_EXIT=0`** |
| 7 | full gate `db/gate.py` | **`GATE_EXIT=0`** (three verdicts 445 s wall-clock, plus the anon-surface verdict): rebuildable ✓ · mirrors = live incl. types and GUCs ✓ · fixtures incl. 240 ✓ · anon surface ✓ (live ⊆ baseline of 327; anon-callable functions: `cod_verification` only, as before) · `changelog` 238 / 242 ✓ · `changemask` 27 masked tables / 81 columns, zero gaps ✓ · `colgrant` / `colreader` ✓ · definer: 0 without a caller check. Tree fingerprint (diff + status + untracked contents) identical before and after: `4da427f4…` |
| 8 | `node scripts/check-i18n.mjs` | **`I18N_OWN_EXIT=0`** |
| 9 | `node scripts/check-error-swallowing.mjs` | **`SWALLOW_OWN_EXIT=0`** (0 unallowed) |
| 10 | layout survey `scripts/survey-phone.mjs --routes=…` (14 changed routes) `--paths=…` (four deleted records: customer, supplier, material, quote) | **390 px: 16 / 18 usable** (`SURVEY390_EXIT=0`), no clipped table. The two page overflows are `/sales/quotes/[id]` **+8 px, pre-existing** — the same culprit as 1b-2 measured (the lines editor's material dropdown; `AT1B2-QUOTE-PAGE-390-OVERFLOW`), once on a live quote and once on the deleted one. **Every trail section `entries`** (the three panels `empty` — 0 change-log rows on live), **section overflow 0, card layout**. **1280 px: 18 / 18 usable** (`SURVEY1280_EXIT=0`), three-column grid, section overflow 0, tallest entry 206 px |
| 11 | route smoke `scripts/smoke-routes.mjs` (detached, `run_detached.sh --token SMOKE`) | **`SMOKE_EXIT=0`**: 243 routes + probes, **260 ok, 9 skipped (no data), 0 FAILED**, 10:55 → 11:16 (1,264 s). The eight 1b-3 trail pages carry a `trail` content assertion (the three panels `emptyOk`). **Scratch-row reading:** the start-of-run check reported **6 stale rows, all pre-existing** (`materials` ZZ-SMOKE-PROBE / -M25 / -NTF, `suppliers` ZZ-SMOKE-S25, `customers` ZZ-SMOKE-CJK, `inbound_batches` ZZ-SMOKE-IB25; 740–1,382 h old; five still referenced by other rows, one unreferenced) — reported, not deleted. After the run: `.ephemeral/` empty (no leftover cleanup plan); `auth.users` **7 real, 0 `@test.local`, 0 disabled**. Rerun after the renderer changes (trail pages only, `SMOKE_ONLY`): **`SMOKE_EXIT=0`**, 54 ok, 2 skipped, 0 FAILED |
| 11b | interaction probe `scripts/probe-at1b3.mjs` (real `auditor`, `gm`, `admin` sessions; `next dev`) | **`AT1B3_PROBE_EXIT=0`: 22 passed · 0 failed · 3 skipped** (deleted formula / sales order / purchase order: 0 on live, covered by fixture 240 and reading). Banners read on the page by `auditor`: CUS-2026-0001 "Deleted on 02/06/2026" · SUP-2026-0083 "Deleted on 18/08/2026" · ZZ-1BCONF-M "Deleted on 13/08/2026" · ZZ-SMOKE-QT-CJK "Deleted on 02/09/2026 by Tim"; `gm` gets the named refusal (`data-access-denied`) on each, never a 404; every trail page has entries with no machine token; the task page has no "Change history" section; the Chinese interface reads the same trail. Rerun after the renderer changes: 22 / 0 / 3 |
| 12 | live verification | §6 |

### Files changed after the first build and the full gate, and what was rerun

The live proof (§6 B) showed two rendering defects (decisions 26 · 27) and the task comparison a third (decision 28). Changed after the
first build / gate: `lib/trail/render.ts`, `scripts/check-trail-wording.mjs` (goldens for 26 and 27 — **not** for 28; see the correction
below), `scripts/probe-at1b3.mjs`
(pass label carries the banner text), `scripts/survey-phone.mjs` (`--paths=`), docs. No database file changed after the gate (the
gate reads no app file; the tree fingerprint it records covers `db/`). Rerun: `tsc` **`TSC_OWN_EXIT=0`** · wording check (in the
build) · surveys 390 / 1280 **identical results** (`SURVEY390_EXIT=0`, `SURVEY1280_EXIT=0`) · trail-page smoke **`SMOKE_EXIT=0`** ·
probe **`AT1B3_PROBE_EXIT=0`** · and `npm run build` last: **`BUILD_OWN_EXIT=0`** (finished 12:10:23 CST, after every other file change except
this handback and the docs).

## §5 · Fault injection — every arm went red

| what | injections | result |
|---|---|---|
| fixture 240 (`db/scripts/2026-10-03-at1b3-fixture-injections.py`, `injection_probe.Pristine` checked clean before each cell) | 20 — members dropped (material attachments / assay requirement, location classes, formula terms requests, task history / participants) · Q13 (classes back to delete-all + insert-all; the row written when nothing changed; no permission check) · gates (metal price on the pricing module; terms requests not Restricted; a personal task readable by anyone with the module) · M2 (task actors read as accounts) · pre-log (a step's creation not registered) · M5 / M6 (root key not rebuilt; the processing and receiving panels see the whole row) · `deleted_records` (person not taken from the change log; a pre-log deletion given a guessed person; kinds not following their own module) … | **20 / 20 red, each in its own arm**; `INJECTIONS_OWN_EXIT=0` |
| wording check `check-trail-wording.mjs` | 13 named injections incl. `wording-drift-1b3` | **13 / 13 red in their arm** (blind-detector exit 3) |
| route smoke | `trail` assertion fed a uuid on the eight trail pages | **8 / 8 FAIL, `SMOKE_EXIT=1`** (`scratchpad/at1b3/smoke-fault.log`: "…审计记录里有机器字:uuid …") |
| probe | holder-is-gm · refusal-is-auditor · banner-guess · history-back · cjk | **all red** (8 · 4 · 3 · 1 · 1 failures, `AT1B3_PROBE_EXIT=1` each); clean rerun 22 / 0 / 3 |

## §6 · Live verification (before / after readings, the read-only checks, the rolled-back proof)

**Readings** (`db/scripts/2026-10-03-at1b3-live-readings.sql`, as `postgres`, `rolbypassrls = true`, base tables) — before 11:39:06,
after 11:42:20, **identical byte for byte**:

| | reading |
|---|---|
| every public table but `change_log`, every row | 241 tables · digest `c8336b005507` |
| `change_log` | 2,361 rows, max seq 2,429 |
| accounts | 7, 0 disabled |
| approvals | ON |
| pending documents | 8 · `c113de0d5542` |
| purchase orders | 11, last PO-2026-0011 |
| materials | 9, last ZZ-STK1CONF-M |
| locations | 4 · 1 allowed class |
| tasks | 20, last TASK-2026-0181 |
| steps · task history · metal prices · formula history | 4 · 46 · 12 · 0 |
| threshold rows | `1b4ebab0bdc9` |

**The digest moved once between the pre-migration reading (10:28, `6e6c6636ec24`) and the before-reading (11:39, `c8336b005507`)**
— traced, not assumed: the route smoke's documented COD-verify probe rotates `cod_verification_failures` (row 141, written by 1b-2's
smoke on 30/09 02:06, deleted; row 142 inserted 11:13:53). Every other write between 10:28 and 11:39 nets to zero by row key; the
migration itself writes no business row.

**Reconciliation** (`ar_ap_reconciliation`, as tim@, before and after identical): AP list 416,988.32 vs ledger 376,404.42 —
**unexplained 0.00, agrees**; AR list 57,545.87 vs ledger 43,002.12 — **unexplained 0.00, agrees** (SGD).

**Proof** (`db/scripts/2026-10-03-at1b3-live-proof.sql`, `PROOF_OWN_EXIT=0`):

- **A — read only.** Every task read by its owner's account (else tim@): **46 of 46 old history rows found inside a trail entry**
  (TASK-2026-0006 30 / 30, -0007 15 / 15, -0181 0, deleted -0005 1 / 1). **9 personal tasks refused by name** for tim@
  (`TRAIL_NOT_PERMITTED|task` — TASK-2026-0003, -0004 with no owner; -0161, -0162, -0163, -0168, -0171, -0173, -0175 owned by ZZ-REPRO /
  ZZ-R* employees with no login) — each has 0 history rows, so nothing is missing; refusing them is the read rule working. The three
  panels: 0 rows for tim@, not refused. Rendered with the final renderer (`render-jsonl.mjs`): deleted CUS-2026-0001 ("Customer
  created", pre-log, by Tim), SUP-2026-0083 (pre-log, "Not recorded"), ZZ-1BCONF-M (created + deleted, pre-log), ZZ-SMOKE-QT-CJK
  (quote created by Tim).
- **B — rolled back.** As admin@ inside one transaction: material **MAT-2026-0077**, location **ZZ-AT1B3-PROOF** (saved twice — a
  rename plus a class swap — through `save_storage_location`), personal task **TASK-2026-0207**. **The second save wrote exactly 3
  change-log rows**: `storage_locations` UPDATE (name); one class DELETE; one class INSERT. Rendered:
  - material (read by tim@): "Material created … Assay required for: Cobalt · Nickel" · "[Material deleted] Spec / Description:
    (empty) → AT-1b-3 live proof — rolled back";
  - location (read by tim@): "Storage location created «ZZ-AT1B3-PROOF» … Allowed material classes: Focused material" · "[Allowed
    material classes changed · 1 added, 1 removed] Added: Non-focused material · Removed: Focused material" · "[Storage location
    details changed] Name: …";
  - task (read by admin@, its owner): "Task created … Step: Check the trail" · "[Step ticked · Check the trail]" · "[Task edited]
    Title: …".
  `ROLLBACK`; the after-reading above shows none of it remains.

**Task comparison** (`scratchpad/at1b3/compare-tasks.txt`): old history rows **46**, each found inside a new entry **46**. What
reads differently from the old "Change history" section: dates `DD/MM/YYYY` · enums in English ("To Do → In Progress") · participant
events name the person ("Participant added · Vince") · step events name the step ("Step re-dated «Lunch»") · the actor is shown
("Not recorded" for pre-log rows the table kept no actor for — the TASK-2026-0007 smoke steps) · "Promoted from personal" → "Made a
team task" · a deleted step says "Step was ticked: No" where the old section said "un-ticked".

## §7 · Broken window

**Start 2026-10-03 10:31:01 CST** (`db/apply_migration.sh` commit, `db/migration-windows.tsv`). **End: when Tim sees the deploy
Ready on Vercel** — a report from Tim, not a measurement from this machine (AGENTS.md: the terminal work ends at the push).

What is broken in the window (old app + new database): **nothing that writes**. The old location action still writes the tables
directly (its three writes are unchanged and still allowed); the new function is unused until the deploy. The one visible effect:
the old `/settings/deleted` lists the four new kinds (customer, supplier, material, formula) with **raw key labels**
(`deleted.kind.customer`) and **no links** — the old page has neither the labels nor the hrefs. During the apply itself
(10:29:17 → 10:31:01) `deleted_records` was locked by the view replacement.

**Not part of the window, stated so it is not missed:** at 12:07 a second backup was started by mistake (no migration followed it;
the only migration of this cut committed at 10:31:01). It is read-only (`pg_dump`) and was left to finish rather than killed
mid-dump; its own line reads **`BACKUP_EXIT=0`** — `evoltrya-backup-2026-10-03-1207.dump`, 5.6 MB, TOC 7,313 (previous 7,311: the new function and its ACL entry), finished 12:23.

## §8 · Decisions I took without asking

Each is also recorded where it lives in the code.

**Registry and pre-log**
1. **A formula's own creation and its payable metals are registered before the log, alongside `pricing_formula_history`** (Step 0 §a
   said "history over the create"). 1b-2's decision 1 precedent: the history row is written by an AFTER trigger in the same transaction,
   so they share a timestamp and fold into one sentence; and the one live formula predates the history table (0 history rows), so it
   would otherwise have no creation at all. The deletion stamp is **not** registered (the history's `delete` records it).
2. **A team task's step creation and its tick stamp are registered alongside `node_added` / `node_done`;** participants are not
   registered at all before the log. Personal tasks have no history (`trg_tasks_history` writes only on team tasks), so without the
   stamps a personal task's earlier steps would be missing; on team tasks the renderer says each step event once (fixture 240 N,
   golden ⑦). The owner's own first participant row is deliberately unrecorded by the history trigger and stays so.
3. **The threshold panels have no pre-log history.** The single-row tables have no creation time, and M6 drops stamps on columns the
   panel does not own; on live their trails are honestly empty today (0 change-log rows, as `postgres`).
4. **`deleted_records` takes "who" for customers, suppliers, materials and formulas from the change-log entry that set `deleted_at`**
   (the tables never stored a deleter) and never from `updated_by`. Fixture 240 D injects "take the last editor" and goes red.

**Writer (Q13)**
5. **`save_storage_location` is SECURITY DEFINER with `require_permission('module.inventory.edit')` first** — the
   `save_counterparty_contact` pattern — because it must call `notify_class_violations` (revoked from `authenticated`): the
   violation notice used to fire on every save via the INSERT-only trigger; with diff writes, a save that only removes classes has no
   INSERT, so the function calls the same check itself (non-empty remaining set — exactly the old condition). A save that changes
   nothing no longer re-notifies. Create uses the same function (one call instead of two).
6. **The three nullable parameters carry `DEFAULT NULL`** so the generated types make them optional — no `as string` casts in the
   action (AGENTS.md: a cast that silences the type check needs a reason).

**Wording and rendering**
7. **One event, two rows:** for a formula change and a team-task change the change-log row speaks after the log began and the
   history row is not said again; before the log the history row speaks. Tasks match per thing (header / step id / employee).
8. **Steps and participants are key events** (they are the event, not a field edit), so an operation that only ticks a step is not
   collapsed into "Task step edited".
9. **A location's code and a terms request's label are typed text** in the title's typed part (1b-2 decision 4), not spliced into the
   wording.
10. **Terms-request wording follows the page's "Send to the CFO"**: "New pricing formula / Change to the pricing formula / Putting the
    pricing formula back in use sent to the CFO", "CFO approved / rejected the terms"; the approval row folds into the decision. The
    catalogue's own value labels for `terms_requests.kind` / `status` were whole card-heading sentences and a lower-case "waiting" —
    replaced with short labels (§10).
11. **"Made a team task"** for `promoted_from_personal` (the old section said "Promoted from personal"; the promote button reads "Make
    this a team task"). The other task events keep the old section's words (Step ticked, Participant taken off, …).
12. **`materials.unit`** values are stored in Chinese by the unit dropdown (吨 / 克 / 件) — machine-written, so English on the trail
    (`messages/trail-machine-values.ts`), and quantity units read the same map. Live has only `kg` today.
13. **The metal price's label is "Price (USD/t)"** (the form's label), not the list's "Price / tonne" — the currency must be stated
    (AGENTS.md's currency rule); with the old label the value printed with no currency.

**Pages**
14. **Deleted records: the page's own module guard first, then `requireDeletedAccess`** — a holder of the module but not of
    `data.view_deleted` gets the named refusal (title = the page's own title key), never a 404.
15. **Read-only = `<EndedFieldset>`** around everything below the title (1b-1's pattern); the trail stays outside it. The customer's
    edit link (a link cannot be disabled by a fieldset) becomes a disabled button inside one; the formula's deactivate / delete buttons
    stay visible and disabled (DBLOCK-1). **The purchase order's action row is not drawn** for a deleted order — mostly links, and the
    page's own rule is "a question that does not apply is not asked".
16. **A deleted quote is read from `quotes`** (the page's `quote_status` view lists only live quotes) and shaped like the view's row;
    expired / convertible / amended-since-issue are false for it.
17. **A deleted customer's credit section says "The credit position is not worked out for a deleted customer."** —
    `customer_credit_status` excludes deleted customers, and the page's existing fallback would have said "Restricted", a false
    permission answer. New message key in both languages (page chrome).
18. **`/settings/deleted` links written-off batches and reversed runs too** — the comment there said they had no page; untrue since
    1b-1.
19. **The panels' trails sit directly under each panel** (Step 0 §a), not at the bottom of the list page. Their "Show older entries"
    link replaces the list page's query string — registered as `AT1B3-PANEL-TRAIL-DROPS-LIST-FILTERS` (it appears only after 20
    panel changes; none yet).
20. **The task page's dead message keys** (`tasks.history.heading`, `.empty`, `.actor`, `.actorUnrecordedHint`, `.colTime`, `.colWhat`,
    `.colDetail`, `.ticked`, `.unticked`) were deleted from both files; `tasks.history.type.*` stays (the catalogue reads it).

**Tools and checks**
21. **`scripts/check-trail-wording.mjs` gained arm ⑦ 主数据样例** (golden wording for every 1b-3 subject; a sweep over every
    task-history and formula-history `change_type`, terms-request status and a hidden entry per subject; injection
    `wording-drift-1b3`).
22. **The smoke's `trail` assertion gained `emptyOk`** for the three panels only (`refused` is still red); the eight 1b-3 pages carry it.
23. **`scripts/survey-phone.mjs` gained `--paths=`** — explicit concrete URLs measured like routes — because a route measures only the
    first live row, so a deleted record's banner and read-only state could never be measured.
24. **`scripts/probe-at1b3.mjs`** (new): real `auditor` (holds `data.view_deleted`) and real `gm` (every module, not that code)
    sessions; see §4.
25. **The migration's proof reads `deleted_records` as tim@** (it filters by the caller's module codes; as the owner with no JWT it
    reads 0 rows — a refused read, not a measurement) and reads each task as its owner's account (tim@ holds no `module.tasks.view_all`;
    personal tasks are private to others — 9 deleted personal tasks with 0 history rows are refused by name for their reader and
    reported, not failed).

**Found by the live proof, fixed after the first build (rerun list in §4)**
26. **A deletion keeps the other changes made with it.** The proof's material had its spec edited and was deleted in one operation;
    the "Material deleted" block swallowed the spec edit. Deletion blocks now list the other changed columns (change-log §9.7);
    golden added.
27. **A replaced set is said in the order it happened.** The proof's class swap (one class added, one removed) netted to nothing.
    Rows now net only when the DELETE came before the INSERT (a save that rewrote the set), and a block that adds then removes splits
    at the first removal (change-log §9.7); golden added.
28. **A deleted step lists its target date and tick state** ("Step was ticked: No"), from the step row or before the log from the
    history row's `old_node_*` columns — the old section said "un-ticked" for these and the first new rendering said nothing.
    > **Correction (AUDIT-TRAIL-1c-1, Tim's AT-1c Q34, 2026-10-03):** this fix shipped **without** a golden check. §4 said
    > "goldens for the three"; there were goldens for 26 and 27 only — `scripts/check-trail-wording.mjs` arm ⑦ swept `node_removed`
    > for machine tokens, which would not notice the target date and tick state going missing again. AT-1c-1 added the two goldens
    > (logged and pre-log deleted step) to arm ⑧. Fault-injected: with both deleted-step line lists emptied in `lib/trail/render.ts`,
    > those two goldens — and only those — went red (`⑧ 账上的单据:2 处`); restored, all eight arms green.
29. **`scripts/survey-phone.mjs --paths=`** (decision 23) was used for the four deleted records; the rerun after decisions 26–28
    gave identical survey results at both widths.

## §9 · Assertions in the brief that I measured

- "Approvals are ON (finance / cfo / 1,000 SGD)" — ON (`finance_settings`, as `postgres`).
- "7 live accounts, all enabled" — **7, 0 disabled** (`auth.users`, before and after, §6).
- "Personal tasks: whoever can open the task's page sees its trail" — live has **0** live personal tasks (all 3 live tasks are team
  tasks; my first reading said "3 personal" — a misread of a `count(*) FILTER` column, corrected by listing the rows); personal tasks
  are proved by fixture 240 T and the rolled-back proof (§6 B).
- "Render the trail of every live task" — 3 live tasks plus 17 deleted ones (the read rule does not filter `deleted_at`), §6 A.
- "Open one deleted record of each kind that exists on live" — kinds with live rows: customer 4, supplier 8, material 4, quote 1;
  formula, sales order, purchase order 0 (as `postgres`, `deleted_at IS NOT NULL`).
- `data.view_deleted` holders — **admin, auditor, cco, cfo, cto, finance** (`role_permissions` joined to `roles`, as `postgres`).

## §10 · For Tim to review: every wording and field label this cut adds (Q9 · Q11)

**Wordings added in 1b-3 (`lib/trail/text.ts`)**

| key | wording |
|---|---|
| `banner.deleted` | Deleted on {date} by {who} |
| `banner.deletedDate` | Deleted on {date} |
| `mat.created` | Material created |
| `mat.edited` | Material details changed |
| `mat.statusChanged` | Material status changed |
| `mat.deleted` | Material deleted |
| `mat.assayChanged` | Assay requirement changed |
| `mat.assayFor` | Assay required for |
| `loc.created` | Storage location created |
| `loc.edited` | Storage location details changed |
| `loc.deactivated` | Storage location taken out of use |
| `loc.reactivated` | Storage location back in use |
| `loc.classesChanged` | Allowed material classes changed |
| `loc.classesLine` | Allowed material classes |
| `mp.created` | Metal price recorded |
| `mp.edited` | Metal price changed |
| `mp.deleted` | Metal price deleted |
| `pf.created` | Pricing formula created |
| `pf.edited` | Pricing formula changed |
| `pf.deleted` | Pricing formula deleted |
| `pf.restored` | Pricing formula restored |
| `pf.deactivated` | Pricing formula taken out of use |
| `pf.reactivated` | Pricing formula back in use |
| `pf.metalSet` | Payable % set |
| `pf.metalRemoved` | Payable % removed |
| `pf.payableFor` | Payable % · {metal} |
| `tr.sentNew` | New pricing formula sent to the CFO |
| `tr.sentChange` | Change to the pricing formula sent to the CFO |
| `tr.sentReactivate` | Putting the pricing formula back in use sent to the CFO |
| `tr.sentOther` | Terms sent to the CFO |
| `tr.approved` | CFO approved the terms |
| `tr.rejected` | CFO rejected the terms |
| `tr.withdrawn` | Terms request withdrawn |
| `tr.changed` | Terms request updated |
| `task.created` | Task created |
| `task.edited` | Task edited |
| `task.deleted` | Task deleted |
| `task.promoted` | Made a team task |
| `task.ownerTransferred` | Owner transferred |
| `task.stepLine` | Step |
| `task.stepAdded` | Step added |
| `task.stepRemoved` | Step deleted |
| `task.stepRenamed` | Step renamed |
| `task.stepRedated` | Step re-dated |
| `task.stepDone` | Step ticked |
| `task.stepUndone` | Step un-ticked |
| `task.stepMoved` | Step moved |
| `task.stepChanged` | Step changed |
| `task.participantAdded` | Participant added |
| `task.participantRemoved` | Participant taken off |
| `task.participantLeft` | Participant left |
| `set.processing` | Variance thresholds changed |
| `set.pricing` | Price anomaly warning changed |
| `set.receiving` | Discrepancy thresholds changed |

(54 keys)

**Field labels on the 17 tables this cut shows** (ids, stamps, hashes and sequence columns never appear). The four Step 0 labels:
`task_nodes` / `task_participants` / `task_history.task_id` "Make this a team task" → **Task** (the promote button's text);
`metal_prices.source` "Choose a source" → **Source** (the dropdown's placeholder; the list says "Source"); `processing_settings`
"Wo input overrun %" / "Wo output shortfall %" → **Input overrun (%)** / **Output shortfall (%)** (the panel); `pricing_settings`
"Notes en" / "Notes zh" → **Notes (EN)** / **Notes (ZH)** (on no page; the catalogue's "Name (EN)" style). Others corrected against their
pages: materials `code` → Code, `may_be_processed` → May be fed to a processing run, `safety_stock_qty` → Safety stock threshold;
attachments `doc_category` → Category; required metals → Assay required for; allowed classes → Allowed material class; metal prices
`price_date` → Price date, `price_usd_per_tonne` → Price (USD/t), `source_reference` → Evidence reference, `quote_delayed` → Delayed
figure; formulas `code` → Code, `average_days` → Averaging days, `is_active` → In use (was the status sentence "Status: in use");
formula history names, averaging days, treatment charge (USD/t), Was / Now in use; terms requests `kind` → Request type, `label` →
Request, `proposed` → Proposed terms, `snapshot` → Terms before, `withdraw_reason` → Withdrawal reason, `executed_at` → Applied on;
task steps `title` → Step title, `parent_id` → Parent step, `done_at/by` → Ticked on/by; participants `employee_id` → Participant,
`removed_at/by` → Taken off on/by; task history step-title / target-date / tick / position / reminder labels; pricing settings
`metal_price_change_warn_pct` → Warn above (%), `default_metal_index` → Default price index, `metal_quote_stale_days` → Quote goes stale
after (days); receiving settings → Short delivery (%) / Over-delivery (%) / Assay tolerance (%).

| record type | field (column) | label |
|---|---|---|
| material | chemistry | Chemistry |
| material | code | Code |
| material | deleted_at | Deleted on |
| material | form_code | Form |
| material | kind_code | Kind |
| material | may_be_processed | May be fed to a processing run |
| material | name | Name |
| material | notes | Notes |
| material | safety_stock_qty | Safety stock threshold |
| material | size_format_code | Size format |
| material | source_code | Source |
| material | spec | Spec / Description |
| material | status | Status |
| material | unit | Unit |
| material | waste_classification_code | Waste classification |
| material attachment | deleted_at | Deleted on |
| material attachment | doc_category | Category |
| material attachment | file_name | File |
| material attachment | file_type | File type |
| material attachment | material_id | Material |
| material attachment | notes | Notes |
| assay requirement | material_id | Material |
| assay requirement | metal | Assay required for |
| storage location | code | Code |
| storage location | is_active | Active |
| storage location | name | Name |
| storage location | notes | Notes |
| storage location | zone | Zone |
| allowed material class | classification_code | Allowed material class |
| allowed material class | location_id | Location |
| metal price | deleted_at | Deleted on |
| metal price | metal | Metal |
| metal price | notes | Notes |
| metal price | price_date | Price date |
| metal price | price_index | Price index |
| metal price | price_usd_per_tonne | Price (USD/t) |
| metal price | quote_delayed | Delayed figure |
| metal price | source | Source |
| metal price | source_reference | Evidence reference |
| pricing formula | average_days | Averaging days |
| pricing formula | customer_id | Customer |
| pricing formula | deleted_at | Deleted on |
| pricing formula | direction | Direction |
| pricing formula | flat_discount_pct | Flat discount % |
| pricing formula | is_active | In use |
| pricing formula | name | Formula name |
| pricing formula | notes | Notes |
| pricing formula | price_basis | Price basis |
| pricing formula | price_index | Settlement index |
| pricing formula | supplier_id | Supplier |
| pricing formula | treatment_charge_usd_per_tonne | Treatment charge (USD per tonne) |
| payable metal | formula_id | Formula |
| payable metal | metal | Metal |
| payable metal | payable_pct | Payable % |
| pricing formula change | metal | Metal |
| pricing formula change | new_average_days | New averaging days |
| pricing formula change | new_direction | New direction |
| pricing formula change | new_flat_discount_pct | New flat discount % |
| pricing formula change | new_is_active | Now in use |
| pricing formula change | new_name | New formula name |
| pricing formula change | new_payable_pct | New payable % |
| pricing formula change | new_price_basis | New price basis |
| pricing formula change | new_treatment_charge_usd_per_tonne | New treatment charge (USD/t) |
| pricing formula change | old_average_days | Previous averaging days |
| pricing formula change | old_direction | Previous direction |
| pricing formula change | old_flat_discount_pct | Previous flat discount % |
| pricing formula change | old_is_active | Was in use |
| pricing formula change | old_name | Previous formula name |
| pricing formula change | old_payable_pct | Previous payable % |
| pricing formula change | old_price_basis | Previous price basis |
| pricing formula change | old_treatment_charge_usd_per_tonne | Previous treatment charge (USD/t) |
| terms request | contract_id | Contract |
| terms request | decided_at | Decided on |
| terms request | decided_by | Decided by |
| terms request | decision_notes | Decision notes |
| terms request | executed_at | Applied on |
| terms request | formula_id | Formula |
| terms request | kind | Request type |
| terms request | label | Request |
| terms request | proposed | Proposed terms |
| terms request | reason | Reason |
| terms request | snapshot | Terms before |
| terms request | status | Status |
| terms request | withdraw_reason | Withdrawal reason |
| terms request | withdrawn_at | Withdrawn on |
| terms request | withdrawn_by | Withdrawn by |
| task | deleted_at | Deleted on |
| task | description | Description |
| task | due_date | Due date |
| task | owner_id | Owner |
| task | priority | Priority |
| task | reminder_at | Reminder |
| task | status | Status |
| task | tags | Tags |
| task | task_type | Task type |
| task | title | Title |
| task step | done | Done |
| task step | done_at | Ticked on |
| task step | done_by | Ticked by |
| task step | parent_id | Parent step |
| task step | target_date | Target date |
| task step | task_id | Task |
| task step | title | Step title |
| task participant | added_at | Added on |
| task participant | added_by | Added by |
| task participant | employee_id | Participant |
| task participant | removed_at | Taken off on |
| task participant | removed_by | Taken off by |
| task participant | task_id | Task |
| task change | employee_id | Participant |
| task change | new_description | New description |
| task change | new_due_date | New due date |
| task change | new_node_done | Step now ticked |
| task change | new_node_target_date | New step target date |
| task change | new_node_title | New step title |
| task change | new_priority | New priority |
| task change | new_reminder_at | New reminder |
| task change | new_sort_order | New position |
| task change | new_status | New status |
| task change | new_tags | New tags |
| task change | new_title | New title |
| task change | old_description | Previous description |
| task change | old_due_date | Previous due date |
| task change | old_node_done | Step was ticked |
| task change | old_node_target_date | Previous step target date |
| task change | old_node_title | Previous step title |
| task change | old_priority | Previous priority |
| task change | old_reminder_at | Previous reminder |
| task change | old_sort_order | Previous position |
| task change | old_status | Previous status |
| task change | old_tags | Previous tags |
| task change | old_title | Previous title |
| variance threshold setting | notes | Notes |
| variance threshold setting | wo_input_overrun_pct | Input overrun (%) |
| variance threshold setting | wo_output_shortfall_pct | Output shortfall (%) |
| price anomaly setting | default_metal_index | Default price index |
| price anomaly setting | metal_price_change_warn_pct | Warn above (%) |
| price anomaly setting | metal_quote_stale_days | Quote goes stale after (days) |
| price anomaly setting | notes | Notes |
| price anomaly setting | notes_en | Notes (EN) |
| price anomaly setting | notes_zh | Notes (ZH) |
| discrepancy threshold setting | grn_assay_tolerance_pct | Assay tolerance (%) |
| discrepancy threshold setting | grn_over_pct | Over-delivery (%) |
| discrepancy threshold setting | grn_short_pct | Short delivery (%) |
| discrepancy threshold setting | notes | Notes |

(145 shown columns on 17 tables; 77 hidden)

| field | values |
|---|---|
| materials · status | draft → Draft; active → Active; inactive → Inactive |
| materials · unit | kg → kg; 吨 → t; 克 → g; 件 → pcs |
| material_attachments · doc_category | spec-sheet → Spec sheet; msds → MSDS; coa → COA; datasheet → Datasheet; other → Other |
| metal_prices · source | published_index → Published index; broker_quote → Broker / counterparty quotation; internal_estimate → Internal estimate; unknown → Source not recorded |
| pricing_formulas · direction | purchase → Purchase; sale → Sale; both → Both |
| pricing_formulas · price_basis | spot → Spot; average → Average |
| pricing_formula_history · change_type | create → Created; update → Edited; delete → Deleted; restore → Restored; metal_set → Payable % set; metal_clear → Payable % removed |
| pricing_formula_history · new_direction | purchase → Purchase; sale → Sale; both → Both |
| pricing_formula_history · new_price_basis | spot → Spot; average → Average |
| pricing_formula_history · old_direction | purchase → Purchase; sale → Sale; both → Both |
| pricing_formula_history · old_price_basis | spot → Spot; average → Average |
| terms_requests · kind | formula_create → New pricing formula; formula_change → Change to a pricing formula; formula_reactivate → Pricing formula back in use; contract_activate → Contract activation |
| terms_requests · status | submitted → Waiting for the CFO; approved → Approved; rejected → Rejected; withdrawn → Withdrawn |
| tasks · priority | high → High; medium → Medium; low → Low |
| tasks · status | todo → To Do; in_progress → In Progress; done → Done |
| tasks · task_type | personal → Personal; team → Team |
| task_history · new_priority | high → High; medium → Medium; low → Low |
| task_history · new_status | todo → To Do; in_progress → In Progress; done → Done |
| task_history · old_priority | high → High; medium → Medium; low → Low |
| task_history · old_status | todo → To Do; in_progress → In Progress; done → Done |

## §11 · Docs

- **`docs/change-log.md`** — §9 intro and table (eight subjects), §9.5 (formulas and tasks before the log; materials, locations, metal
  prices), §9.7 (one event two rows; terms requests; `materials.unit`), §9.8 (fixture 240, arm ⑦, probe, smoke `emptyOk`), §9.9 (M2 /
  M5 / M6 users), new **§9.10** (deleted records open read-only).
- **`docs/forward-queue.md`** — item 25 (1b-2's window); **AT-1b-3 ✅ and AT-1b ✅**; the Step 0 labels done.
- **`docs/known-issues.md`** — `AT1B3-PANEL-TRAIL-DROPS-LIST-FILTERS`.

