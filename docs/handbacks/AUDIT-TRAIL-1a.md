# AUDIT-TRAIL-1a — plain-English audit trails at the bottom of three pages, a readable Change history, and DD/MM/YYYY on screen (2026-09-29)

**Tester line — v1.4.33:** Purchase orders, processing records and roles now show a plain-English audit trail at the bottom of the page, the Change history page now reads in plain English, and dates on screen show as day/month/year (date entry boxes change in a later update).

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `d93c083b0c0b6192fd2638c058e266e0050da6eb` (HISTORY-1 close-out).
**Approvals were ON and stayed ON** (L1 finance · L2 cfo · 1,000). Every figure below is a script's own exit line, or a query named
with who ran it: `postgres` (`rolbypassrls = t`) on base tables unless stated; "as X" means `SET LOCAL ROLE authenticated` plus X's JWT.

Part 1 of 5 (AT-1a → AT-1b → AT-1c → AT-1d → DATE-PICK-1). Reference for the mechanism: **`docs/change-log.md` §9**.

## §1 · Step 1 — the survey is in the repo

All eleven survey outputs were still in the Step 0 scratchpad (`…/0c0d03c2-…/scratchpad/at0/`) and were copied unchanged into
`docs/surveys/AUDIT-TRAIL-0/`: `ops-finance.md`, `ops-commercial.md`, `ops-production.md`, `ops-people-settings.md`, `events.md`,
`values-labels.md`, `labels.csv`, `reader-masking.md`, `mockup-data.md`, `dates.md`, `estimate-basis.md`. **None was missing**, so
nothing had to be rebuilt. The full Step 0 hand-back (the last assistant message of that session, 40 KB, extracted from its
transcript) is `docs/surveys/AUDIT-TRAIL-0/README.md`, followed by the section "Tim's answers, 2026-09-29: all Q1–Q43 accepted as
recommended; split approved in the order above". The only edit to it: its pointer to the scratchpad now points at the repo folder.

## §2 · What was built

| ruling | built |
|---|---|
| Q5 · Q2 · Q3 · Q4 · Q6 | **`record_trail(subject, id, entries)`** — SECURITY DEFINER; registry subjects only (`trail_subjects`, `trail_subject_members`); authorisation = the page's view code + the root row's own read rule + **each child / related row re-checked against its own table's read rule** (`trail_row_visible`, the table's permissive SELECT/ALL policies re-evaluated on that row or its last image); refusals raise `TRAIL_SUBJECT_UNKNOWN` / `TRAIL_NOT_PERMITTED`, never an empty list; rows the reader cannot see keep only their time (`row_hidden`); one entry per `txid`; children found at read time (live rows by FK + log images through two new GIN partial indexes) |
| Q5 (masking) | **`change_log_mask_row()`** — the loop body of `change_log_rows` pulled out; both readers call it; no rule added |
| Q1 | pre-log history: `trail_prelog_sources()` (created rows + lifecycle stamps per table), boundary `change_log_began_at()` = 2026-09-28 23:58:11.294 +08 (measured `min(occurred_at)`); rebuilt rows carry `prelog = true`, sort after every logged entry, never duplicate what the log holds; reusable per subject (`docs/change-log.md` §9.6) |
| Q12 · Q13 · Q14 · Q17 · Q18 · Q40 | resolvers in the database: `trail_ref_label` / `trail_refs` (document numbers, dictionary names, currencies, batch labels + unit, PO line labels, people; deleted → last image + `gone`, no image → `gone` with no label), `trail_actor` (person / system / removed / unlinked / anonymised / unknown), `trail_row_record` (which record a row belongs to, for the summary page); the app writes the sentences (`lib/trail/render.ts`) |
| Q7 · Q9 · Q10 · Q11 | English-only wording catalogue `lib/trail/text.ts` (117 wordings); field labels, record-type names and value labels generated into `lib/trail/catalogue.generated.ts` by `scripts/gen-trail-catalogue.mjs` (page label → similar wording → `labels.csv`; hand-checked overrides for this part's 18 tables); machine-written Chinese → English in `messages/trail-machine-values.ts` (Q8) |
| Q27 · Q29 | `app/components/trail/AuditTrail.tsx` (server: reads, refuses by name, builds entries) + `AuditTrailList.tsx` (layout: When · Who · What happened; four detail lines then "Show N more"; 120-character truncation with "more"; 20 entries then "Show older entries"; cards at 390 px; "Restricted" pill vs "(empty)") |
| Q15 · Q16 | `lib/dates.ts`: `formatDate` / `formatDateTime` now `DD/MM/YYYY` (`HH:MM`) in both languages; new `formatDocumentDate` / `formatDocumentDateTime` keep "01 Sep 2026" for the seven PDF routes; new `formatTrailStamp` (`DD/MM/YYYY HH:MM`, Singapore) for trails, the summary page and `/settings/deleted` |
| Q30 · Q31 · Q28 | `/settings/change-history` rewritten: filters date range · Area · Record type · Record (document number or name, `change_log_find_records`) · Who (people, System (automatic), Removed account) · Key events only; columns When · Who · Record · What happened; one line per operation; same wording as the trails; still every write. `change_log_rows` keeps its gate, gains `p_tables` · `p_removed_account` · `p_by_entry` · `p_record_ids` and returns `txid` · `actor` · `belongs_to` · `refs`; `change_log_filters` gains `people` · `has_system` · `has_removed` |
| Q26 | the mid-page PO amendment history box is gone; the trail at the bottom replaces it |
| Q34 | six defects registered in `docs/known-issues.md` (`AT0-*`); only the false approvals comment in `lib/modules.ts` fixed (registered as closed) |
| Q41 | `scripts/check-trail-wording.mjs` in `npm run build`; smoke `{ trail }` content assertion on the three pages and the summary page; one shared detector `lib/trail/machineTokens.ts`; both fault-injected |

Migration: `db/migrations/2026-09-29-at1a-record-trail.sql` (built from the mirrors by `db/scripts/build_at1a_migration.py`; functions
only, no table lock) + `db/migrations/2026-09-29-at1a-record-trail-indexes.sql` (the two GIN indexes, `CREATE INDEX CONCURRENTLY`, run
with psql after the main file committed — why it is a second file is in its header and in §8). Fixture **236**. No new permission code.

## §3 · Pages — every new or changed route, with its file

| route | file(s) | change |
|---|---|---|
| `/purchasing/orders/[id]` | `app/purchasing/orders/[id]/page.tsx` | "Audit trail" at the very bottom (outside the non-equipment receipts block, so equipment orders have it too); the mid-page amendment history box removed (Q26); `searchParams.trail` for "Show older entries" |
| `/operation/processing/[id]` | `app/operation/processing/[id]/page.tsx` | "Audit trail" at the bottom |
| `/settings/roles/[id]` | `app/settings/roles/[id]/page.tsx` | "Audit trail" at the bottom |
| `/settings/change-history` | `app/settings/change-history/page.tsx` (rewritten); `ChangeHistoryTable.tsx` and `fieldValue.tsx` deleted | plain-English entries, new filters and columns (§2) |
| `/settings/deleted` | `app/settings/deleted/page.tsx` | deletion times `DD/MM/YYYY HH:MM` (Q15) |
| every page that prints a date through `formatDate` / `formatDateTime` (145 files import the formatter) | `lib/dates.ts` | `DD/MM/YYYY` in both languages (Q16) |
| seven PDF routes (PO, sales order, quote, delivery note, invoice, credit note, customer statement) | `app/{purchasing/orders,sales/orders,sales/quotes,sales/shipments,finance/invoices,finance/credit-notes,finance/statements}/[id]/pdf/route.ts` | switched to `formatDocumentDate` — **output unchanged** ("01 Sep 2026") |
| shared components | `app/components/trail/AuditTrail.tsx`, `app/components/trail/AuditTrailList.tsx` | new |
| `/finance/close` | `app/finance/close/page.tsx`, `app/finance/close/PeriodPicker.tsx` | month-end options carry an ISO value and a formatted label (was: a display string used as data — 500 under DD/MM/YYYY; §4) |
| `/finance/bank/statements/[id]/reconcile` | `app/finance/bank/statements/[id]/reconcile/page.tsx` | passes raw dates; the workspace formats once and sorts by date (§4) |

## §4 · Verification (in the order the brief set)

| # | step | verdict (the script's own line) |
|---|---|---|
| 1 | offline gate `db/gate.py --offline` | **`GATE_OFFLINE_EXIT=0`** (62 s; fixture 236 ✓) |
| — | migration dry run on live (`COMMIT` → probe + `ROLLBACK`, grants replay included) | first run red in its own proof (`AT1A_PROOF|authenticated can execute the inner function change_log_mask_row` — a body `REVOKE … FROM authenticated` cannot bite while `PUBLIC` holds the default grant); builder fixed to revoke `PUBLIC`/`anon` first → **`DRY_OWN_EXIT=0`**. Timed per statement: 1.5–2 s round trips, 185 s total, ~100 s of it the grants replay — the reason the indexes moved to a second, concurrent file (§8) |
| 2 | backup (detached) | **`BACKUP_EXIT=0`**: `evoltrya-backup-2026-09-29-1259.dump`, 5.4 MB, TOC 7,257 (previous 6,677 — that dump predates HISTORY-1's 476 triggers; floor 6,009). ~27 min; a bounded wait ran out once while `pg_dump` was visibly copying tables (server-side `COPY` advancing, file growing), so I waited again rather than call it dead |
| 3 | `db/apply_migration.sh` | **`APPLY_OWN_EXIT=0`**; preflight: 18 functions (1 replaced, 16 new, 1 new with an OUT-parameter signature the preflight could not parse — no live overload exists; one signature each for `trail_current_image` and `change_log_rows` read back afterwards); in-transaction proof passed (tim@ read PO-2026-0010: 10 rows, all pre-log); **committed 2026-09-29 13:30:45 CST**. Then `2026-09-29-at1a-record-trail-indexes.sql` over psql: **`INDEX_OWN_EXIT=0`**, 9.7 s, both indexes valid |
| 4 | `npm run types:gen` (after `NOTIFY pgrst`) | first two runs exit 1: the Supabase CLI appended a telemetry error line (`Timeout while shutting down PostHog`) to stdout. With `DO_NOT_TRACK=1 SUPABASE_TELEMETRY_DISABLED=1`: **`TYPES_OWN_EXIT=0`**, +98 lines, byte-identical to a clean direct run |
| 5 | `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** |
| 6 | `npm run build` | first run exit 1 (`check-instrument-selfproof`: the new check lacked its AIM header — added, stating its blind spot) → **`BUILD_OWN_EXIT=0`** |
| 7 | full gate `db/gate.py` | **`GATE_EXIT=0`** (611 s): rebuildable ✓ · mirrors = live incl. types ✓ · fixtures incl. 236 ✓ · anon surface ✓ · `changelog` / `changemask` live + rebuild ✓. Tree fingerprint identical from the build to after the gate |
| 8 | `node scripts/check-i18n.mjs` | **`I18N_OWN_EXIT=0`** |
| 9 | `node scripts/check-error-swallowing.mjs` | **`SWALLOW_OWN_EXIT=0`** (0 unallowed) |
| 10 | layout survey `scripts/survey-phone.mjs` (the three trail pages + `/settings/change-history`) | **390 px: 4 / 4 usable** (`SURVEY390_EXIT=0`) — no page overflow, no clipped table; trail sections `entries`, section overflow 0, card layout, divider shown on the three record pages. **1280 px: 4 / 4 usable** (`SURVEY1280_EXIT=0`) — three-column grid on every entry, section overflow 0. Tallest entry: 302 px (phone, processing) / 266 px (desktop). Self-test passed in both widths |
| 11 | smoke `scripts/smoke-routes.mjs` (detached) | **first run `SMOKE_EXIT=6`**: `/finance/close → 500` (below), and the network dropped at clean-up (`fetch failed`) — 8 steps unconfirmed; `npm run reap:ephemeral` reaped them and a read-back showed 0 smoke accounts / roles / grants / `ZZ-SMOKE` rows, 7 accounts, 0 disabled. Fix → rebuild → **second run `SMOKE_EXIT=0`: 258 ok, 8 skipped (no data), 0 FAILED**, incl. the four new `trail` assertions |
| 12 | live verification (one rolled-back transaction) | §6 — **before = after, identical** |

**The `/finance/close` 500, and why the fix belongs in this part.** The close page built its month-end `<option value>` from `formatDate`
and then used the selected value as data (journal preview query, the close RPC, the P&L / balance-sheet links, `?period=`). Postgres
happened to accept "31 Aug 2026"; it rejects "31/08/2026". A sweep for the same shape found the bank-reconciliation screen formatting dates
twice (page and component) — harmless with "01 Sep 2026", but `new Date("01/09/2026")` is **January 9**, so it would have shown wrong dates.
Both fixed at the source, `formatDate` made idempotent on its own output, and six assertions added to `check-date-data-paths.mjs` (§5).
Registered as a closed entry, `AT1A-DISPLAY-DATE-USED-AS-DATA`. After these fixes: `TSC_OWN_EXIT=0`, `BUILD_OWN_EXIT=0` (includes i18n,
error-swallowing, date paths, trail wording). The gate reads no app file that changed, so its verdict stands.

**Scratch cleanup reading** (the smoke's own report, second run): **6 stale rows, all pre-existing** (651–1,294 h old, five still
referenced): `ZZ-SMOKE-PROBE`, `ZZ-SMOKE-M25`, `ZZ-SMOKE-NTF`, `ZZ-SMOKE-S25`, `ZZ-SMOKE-CJK`, `ZZ-SMOKE-IB25` — the same six HISTORY-1
reported; none from this session. `.ephemeral/` empty after every run.

## §5 · Fault injection — every arm went red, the clean runs went green

- **`scripts/check-trail-wording.mjs` — 11 arms, each red in its own arm, clean run green:**

  | injection | red in |
  |---|---|
  | `blind-detector` | ① ruler (exit 3) |
  | `registry-drift` | ② registry |
  | `missing-key` · `dead-key` · `label-gap` · `enum-gap` | ③ catalogue (missing-key also ④) |
  | `raw-date` · `raw-ref` · `raw-json` · `raw-null` · `raw-role` | ④ machine tokens |

  One injection did not bite at first: `raw-ref` changed the sampler's view of the columns too, so no ids were produced to leak. The
  sampler now reads the original catalogue kinds; rerun → red.
- **Fixture 236 — 30 injections** (`db/scripts/2026-09-29-at1a-fixture236-injections.py`, each a `CREATE OR REPLACE` inside the fixture's
  own transaction, against a local rebuild): **all 30 red in the arm they target** (P1–P13 incl. P11, W1–W5, L1–L3, R1–R3 incl. the role
  half of R2, S1–S4, plus "live-row discovery off", caught by P8). The first round had four that went red in a *different* arm; each was
  informative and was resolved by a better-aimed injection or by moving an assertion (P3, P7, R2, S2 — the reasons are in the script).
- **Smoke `trail` assertion:** `SMOKE_TRAIL_FAULT=1` with `SMOKE_ONLY` on the four pages → **all 4 FAIL**, each naming the injected uuid;
  `SMOKE_EXIT=1`.
- **`check-date-data-paths.mjs` (new ⑤b):** removing the day-first branch in `lib/dates.ts` → exit 1, naming
  "01/09/2026 → 09/01/2026" and `toYmd → 2026-01-09`; file restored byte for byte, rerun exit 0.
- **Shared detector:** `selfProof()` runs on every invocation of both checks (nine known-bad samples must all be caught, one
  known-good sentence must pass).

## §6 · Live verification

**Readings before / after** (the same read-only query, `postgres`, `rolbypassrls = t`, 18:51:10 and 18:52:48 CST):

| reading | before | after |
|---|---|---|
| tables (excl. `change_log`) + digest of every row of every table | 241 · `ba055525…` | 241 · `ba055525…` |
| `change_log` | 752 rows, max seq 759 | 752 rows, max seq 759 |
| accounts | 7, 0 disabled | 7, 0 disabled |
| approvals | ON · finance / cfo / 1,000 | ON · finance / cfo / 1,000 |
| pending documents | 9 · `dead3b38…` | 9 · `dead3b38…` |
| purchase orders | 11, last PO-2026-0011 | 11, last PO-2026-0011 |

**The proof** (one transaction, as admin@ — Tim's account — under `authenticated`): `create_purchase_order` (Shanghai Yidong, 10 kg NMC
Cathode Foil at 5.00 SGD, tax TX; approvals ON so it is pending) → `amend_purchase_order` (quantity 12, reason "Supplier can deliver 12 kg")
→ `record_trail('purchase_order', …)` read under that session → `ROLLBACK`. The first attempt stopped at my own setup
(`TAX_CODE_REQUIRED|supplier` — the supplier has no default tax code) and rolled back. Rendered with the app's renderer:

```
29/09/2026 18:52  Tim  Purchase order raised — waiting for approval · 1 line · 60.00 SGD
      Line changed · Line 1 · NMC Cathode Foil
      Estimated amount   50.00 SGD → 60.00 SGD
      Quantity           10 kg → 12 kg
      Tax amount         4.50 SGD → 5.40 SGD
      Reason: Supplier can deliver 12 kg
```

Raising and amending inside one transaction is one operation to the reader (Q2 groups by transaction), so it is one entry. The script's
last statement (a count of `change_log` rows) ran before `RESET ROLE` and was refused — `permission denied for table change_log` — which
also shows a signed-in account cannot read the log directly; the transaction was rolled back either way, as the readings show.

**PO-2026-0010, read-only as tim@, against mock-up A:**

```
─ Before 28/09/2026 23:58, only key steps and amendments were kept; single-field edits were not. ─
08/09/2026 10:47  Sandra  Purchase order cancelled
                          Reason: Too many errors - will redo one
08/09/2026 10:41  Sandra  Purchase order issued to the supplier (version 2)
08/09/2026 10:41  Sandra  Purchase order amended · 3 changes
                          Notes        (empty) → Payment schedule 50% Advanced, 40% upon delivery, 10% upon completion of training
                          Incoterm     CIF → CIF or otherwise specified
                          Order date   03/09/2026 → 08/09/2026
                          Reason: To change the payment schedule, order date and leaving Incoterms open
03/09/2026 16:52  Tim     Purchase order issued to the supplier (version 1)
03/09/2026 16:51  Tim     Purchase order raised · 1 line · 305,550.00 SGD
                          Approved automatically (approvals were switched off)
```

Same as mock-up A, with three differences: the two PDF issues now appear (the mock-up left `po_issues` out); the divider sits above the
whole trail (every entry of this PO predates the log); and the three field lines are in stored order, not the mock-up's. The "raised"
total is today's value (`AT1A-PRELOG-SHOWS-TODAYS-VALUES`); here it equals the creation total.

## §7 · Broken window

**Start: 2026-09-29 13:30:45 CST** (the commit time; `db/migration-windows.tsv`). **End: when you see the Vercel deploy succeed** —
that reading comes from you, not from this machine.

**What is broken inside it: nothing.** The migration only adds functions and replaces two readers with compatible ones: old app code calls
`change_log_rows` with named parameters (all still accepted; the extra returned columns are ignored) and `change_log_filters` (same
signature, extra keys). No table, view or grant the old app reads changed. The main transaction took **no table lock** (the indexes were
built `CONCURRENTLY` afterwards), so no write waited. Until the deploy lands, users simply see the old screens (no trails, old dates,
the old Change history page).

## §8 · Decisions I took without asking

Each is recorded where it lives in the code as well.

**Reader and database**
1. **The trail names people for every reader.** `ActorName` shows "Restricted" for actors to readers without `module.hr.view`; the
   trail does not, because the brief says the trail "adds no rule of its own" (HISTORY-1's list has no rule for actor names) and Q14 says
   preferred-else-legal name everywhere. If you want the ActorName behaviour on trails, it is one condition in `trail_actor`.
2. **Two actor wordings beyond Q17:** "An account with no person linked" (an account that exists but belonged to nobody when it wrote —
   only test accounts do this) and "Not recorded" (a pre-log row whose table kept no actor, e.g. processing inputs). "A former employee"
   is used after anonymisation (ActorName's wording family).
3. **The indexes are a second, non-transactional file.** A plain `CREATE INDEX` on `change_log` holds a lock that blocks every audited
   write until COMMIT, and `apply_migration.sh` replays the 133-statement grants file before committing — the dry run measured 1.5–2 s per
   round trip and 185 s end to end, so saves would have queued for well over a minute and hit the 8 s `authenticated` timeout.
   `CREATE INDEX CONCURRENTLY` cannot run inside a transaction, so it went through psql directly right after the main file (9.7 s,
   `INDEX_OWN_EXIT=0`). The main migration takes no table lock at all.
4. **`change_log_rows` was extended, not duplicated.** Q5 keeps the summary page on its own reader; Q30 needs entry paging, area and
   record-name filters and resolved names, so the same function (same gate) gained four defaulted parameters and four columns. Changing
   the return type needs `DROP` + `CREATE` in the one transaction; old callers use named parameters, so the window is safe.
   `change_log_filters` kept its signature and gained three keys. New `change_log_find_records` answers "document number or name".
5. **Registries are SQL functions over `VALUES`** (like `change_log_mask_rules`), not tables — they are code, versioned in mirrors,
   and `check-trail-wording` compares them with the app's table sets.
6. **The log's start is declared** (`change_log_began_at()`, the measured first row), not inferred — the same reasoning as
   `finance_settings.system_start_date`. `check-trail-wording` checks the app's copy against it.
7. **Pre-log rows group by exact timestamp** (one transaction shares `now()`); a record's own pre-log "created" entry shows today's
   values — registered as `AT1A-PRELOG-SHOWS-TODAYS-VALUES`. A PO's pre-log cancellation and approvals come from
   `purchase_order_history` / `approval_log`, not from the stamps, so they cannot appear twice.
8. **Row visibility re-evaluates the table's own permissive policies inside the reader**, ANDing any restrictive ones (none today).
   A child whose table has no read policy for `authenticated` (e.g. `cod_verification_failures`) counts as not visible.
9. **A record that does not exist refuses with `TRAIL_NOT_PERMITTED`**, the same as one you may not read — the refusal does not tell a
   reader which ids exist.
10. **Reference labels:** documents → number; suppliers / customers → legal name; materials → name; batches → "number · material" (and
    their unit); PO lines → "PO number line N"; dictionaries → `name_en`. The contract link line uses the contract's resolved number,
    never the copied `contract_code` column.

**Wording and rendering**
11. **Key events** (for the summary page's toggle) are the business-event rules — creation, deletion, status and approval steps,
    permission changes, account events, lifecycle stamps; field-only edits are routine.
12. **A line edit made in the same transaction as the PO's creation is shown under the creation entry** (creation itself never edits
    its lines — measured: only the header's total and contract are updated in that transaction), so it cannot be swallowed as an artefact.
13. **Several edits to the same row in one operation read as one change** (columns merged, first old value, last new value).
14. **A wholly hidden operation** shows its time and a "Restricted" pill for who and what; a partly hidden one adds "Part of this
    change is restricted."
15. **Processing-run notes are shown as "Notes"**, not as a reason; a masked cost amount gets its own "Amount — Restricted" line rather
    than a plain word inside the title.
16. **Cost-entry journals are not listed on the run trail** (their link lives on the journal side, in finance's read scope) —
    `AT1A-RUN-COST-JOURNALS-NOT-ON-TRAIL`; the allocation's capitalisation journal is shown.
17. **Typed text is exempt from the smoke's machine-token scan** (`data-trail-typed`, Q8 "shown as written"); the build-time check
    scans it too, because there the samples are mine.
18. **The trail is an ordered list, not a `<table>`** — entries vary from 0 to dozens of lines and become cards at 390 px.
19. **Wording keys under `who.*`, value maps keyed `table#column`:** `actor.*` and `table.column` collide with existing message
    namespaces, which check-i18n then treats as message keys.
20. **Machine-written Chinese lives in `messages/trail-machine-values.ts`** — a translation table, which the CJK check deliberately
    does not scan; a Chinese literal in `lib/` would be read as on-screen text.

**Summary page**
21. **25 operations per page** (it was 50 rows): one operation can hold 72 rows (the smoke's role set-up). With "Key events only" the
    page reads up to 100 operations to fill a page and says how many routine edits it hid.
22. **Page chrome follows the interface language** (titles and filter labels through `t()`, with new keys in both languages); the
    entries themselves are English (Q7). The Who filter's "System (automatic)" and "Removed account" use the trail's words.
23. **Record-type names and areas exist for all 238 tables now** (generated, English only) because the Record type filter needs them;
    names outside the three subjects are derived and queued for your review.

**Dates**
24. **Month-only displays stay "Sep 2026"** — Q16 names dates; a month has no day. **Audit stamps elsewhere stay `YYYY-MM-DD HH:MM`**
    (D2) — Q15 changed them only on trails, the summary page and `/settings/deleted`.
25. **`formatDate` keeps its `locale` argument** (now unused) so none of the 145 importing files had to change.

**Tools**
26. **`scripts/survey-phone.mjs` gained `--width=N`** (default 390, unchanged output) and a trail-section reading; its overflow
    self-test now injects viewport + 510 px (still exactly 900 px at 390).
27. **`scripts/smoke-routes.mjs` gained `SMOKE_ONLY`** (exact route patterns; unknown names refuse) — used only for the fault-injection
    run, which is not a full smoke.
28. **Fixture 236 plants later operations as synthetic `change_log` rows with their own `txid`** (a fixture is one transaction), as
    fixture 234 does, and plants pre-log history with `ALTER TABLE … DISABLE TRIGGER zzz_change_log` inside its transaction. The
    view-code refusal (R2) is asserted on a role, because on a PO the root row's own read rule refuses as well.
29. **The two date-path fixes (`/finance/close`, bank reconciliation) and the idempotent formatter were done in this part** although
    the brief said to fix only one Q34 defect: they are not Q34 items but consequences of Q16 that the smoke turned into a 500, and
    shipping Q16 without them would have broken close and shown wrong dates on reconciliation.
30. **`survey-phone.mjs`' `--width` and `smoke-routes.mjs`' `SMOKE_ONLY` changed after the full gate.** Neither file is read by the
    gate; the build that followed (lint and the instrument self-proof read scripts) was green.


## §9 · For Tim to review: every wording, and every field label this part uses (Q9 · Q11)

The trail and the summary page print only these sentences (plus values and names). §4 of the Step 0 hand-back is included verbatim
where it applies; everything else is new. Values in {braces} are filled with already-resolved words, never codes.

**Layout**

| key | wording |
|---|---|
| `section.title` | Audit trail |
| `section.intro` | Newest first · Singapore time |
| `col.when` | When |
| `col.who` | Who |
| `col.what` | What happened |
| `col.record` | Record |
| `restricted` | Restricted |
| `empty` | (empty) |
| `showMore` | Show {n} more |
| `showLess` | Show less |
| `more` | more |
| `less` | less |
| `olderEntries` | Show older entries |
| `noEntries` | Nothing has been recorded for this record yet. |
| `divider` | Before {date}, only key steps and amendments were kept; single-field edits were not. |
| `reason` | Reason |
| `restrictedPart` | Part of this change is restricted. |

**Refusals**

| key | wording |
|---|---|
| `refusal.notPermitted` | You cannot see the audit trail of this record. |
| `refusal.unknown` | This page does not have an audit trail yet. |

**Who**

| key | wording |
|---|---|
| `who.system` | System (automatic) |
| `who.removed` | Removed account |
| `who.unlinked` | An account with no person linked |
| `who.anonymised` | A former employee |
| `who.unknown` | Not recorded |

**Values**

| key | wording |
|---|---|
| `value.yes` | Yes |
| `value.no` | No |
| `value.sinceDeleted` | {label} (since deleted) |
| `value.goneGeneric` | a {thing} that has since been deleted |
| `value.unnamed` | a {thing} |
| `value.detailsChanged` | Details changed |
| `value.detailsRecorded` | Details recorded |

**Any other record (fallback, summary page)**

| key | wording |
|---|---|
| `generic.created` | {Thing} created |
| `generic.edited` | {Thing} edited |
| `generic.deleted` | {Thing} deleted |
| `generic.truncated` | Every {thing} record removed at once |

**Login accounts (summary page)**

| key | wording |
|---|---|
| `account.ACCOUNT_CREATE` | Account created |
| `account.ACCOUNT_DELETE` | Account removed (it was never finished) |
| `account.ACCOUNT_DISABLE` | Account disabled |
| `account.ACCOUNT_DISABLE_FAILED` | Account could not be disabled |
| `account.ACCOUNT_ENABLE` | Account re-enabled |
| `account.ACCOUNT_ENABLE_FAILED` | Account could not be re-enabled |

**Purchase orders**

| key | wording |
|---|---|
| `po.raised` | Purchase order raised |
| `po.raisedPending` | Purchase order raised — waiting for approval |
| `po.lines.one` | {n} line |
| `po.lines.many` | {n} lines |
| `po.autoApproved` | Approved automatically (approvals were switched off) |
| `po.submitted` | Submitted for approval |
| `po.approved` | Purchase order approved |
| `po.approvedLevel` | Purchase order approved (level {level}) |
| `po.rejected` | Purchase order rejected |
| `po.approvalVoided` | Approval withdrawn — the order value went up |
| `po.approvalOther` | Approval step recorded: {decision} |
| `po.firstReceipt` | First goods received — order now receiving |
| `po.closed` | Purchase order closed |
| `po.reopened` | Purchase order reopened |
| `po.cancelled` | Purchase order cancelled |
| `po.deleted` | Purchase order deleted |
| `po.statusChanged` | Purchase order status changed |
| `po.amended` | Purchase order amended |
| `po.changes.one` | {n} change |
| `po.changes.many` | {n} changes |
| `po.edited` | Purchase order edited |
| `po.issued` | Purchase order issued to the supplier (version {version}) |
| `po.lineHeading` | Line {n} |
| `po.lineAdded` | Line added |
| `po.lineChanged` | Line changed |
| `po.lineRemoved` | Line removed |
| `po.termHeading` | Instalment {n} |
| `po.termAdded` | Instalment added |
| `po.termChanged` | Instalment changed |
| `po.termRemoved` | Instalment removed |
| `po.dueDateSet` | Instalment due date set |
| `po.retentionSet` | Retention set |
| `po.retentionReleased` | Retention released |
| `po.retentionChanged` | Retention changed |
| `po.termsCommitted` | Pricing terms committed |
| `po.contractLinked` | Linked to contract {code} |
| `po.contractLinkedPlain` | Linked to a contract |

**Processing records**

| key | wording |
|---|---|
| `run.completed` | Processing completed |
| `run.processDate` | process date {date} |
| `run.used` | Used |
| `run.produced` | Produced |
| `run.loss` | Loss |
| `run.allocated` | Processing costs allocated |
| `run.capitalised` | Capitalised |
| `run.journal` | Journal |
| `run.rolledBack` | Processing rolled back |
| `run.edited` | Processing record edited |
| `run.basisChanged` | Cost allocation basis changed |
| `run.costAdded` | Processing cost added |
| `run.costChanged` | Processing cost changed |
| `run.costRemoved` | Processing cost removed |
| `run.costRestored` | Processing cost restored |
| `run.costRelieved` | Accrued cost relieved by a real invoice |
| `run.estimate` | (estimate) |
| `run.lossRecorded` | Loss recorded |
| `run.lossChanged` | Loss changed |
| `run.lossRemoved` | Loss removed |
| `run.batchShare` | Cost share |

**Roles**

| key | wording |
|---|---|
| `role.created` | Role created |
| `role.edited` | Role edited |
| `role.deactivated` | Role deactivated |
| `role.reactivated` | Role reactivated |
| `role.deleted` | Role deleted |
| `role.permsChanged` | Permissions changed |
| `role.permsSet` | Permissions set |
| `role.added` | {n} added |
| `role.removed` | {n} removed |
| `role.perms.one` | {n} permission |
| `role.perms.many` | {n} permissions |
| `role.lineAdded` | Added |
| `role.lineRemoved` | Removed |
| `role.lineGiven` | Given |
| `role.notKept` | The list before this was not kept. |

**Summary page**

| key | wording |
|---|---|
| `summary.noRecord` | Not tied to a single record |
| `summary.keyHidden.one` | Key events only — {n} routine edit on this page is hidden. |
| `summary.keyHidden.many` | Key events only — {n} routine edits on this page are hidden. |


**Field labels** for this part's 18 tables (197 shown; 71 hidden columns — ids, created/updated stamps, sequence numbers — never appear).
Most follow the page's own label; the ones marked in the generator as overrides were hand-checked because the survey's automatic match
was wrong (for example the payment-term description had been matched to "Category", the supplier to "Supplier (optional)").

| record type | field (column) | label |
|---|---|---|
| purchase order | approval_status | Approval status |
| purchase order | approved_at | Approved on |
| purchase order | approved_by | Approved by |
| purchase order | cancel_reason | Cancellation reason |
| purchase order | cancelled_at | Cancelled on |
| purchase order | cancelled_by | Cancelled by |
| purchase order | category | Category |
| purchase order | closed_at | Closed on |
| purchase order | contract_id | Contract |
| purchase order | currency | Currency |
| purchase order | delete_reason | Reason for deletion |
| purchase order | deleted_at | Deleted on |
| purchase order | deleted_by | Deleted by |
| purchase order | delivery_location | Delivery location |
| purchase order | estimated_total_ccy | Estimated total |
| purchase order | expected_delivery_date | Expected delivery |
| purchase order | fx_rate | FX rate |
| purchase order | incoterm | Incoterm |
| purchase order | notes | Notes |
| purchase order | order_date | Order date |
| purchase order | status | Status |
| purchase order | supplier_id | Supplier |
| purchase order | tax_total_ccy | GST |
| purchase order | terms_text | Terms text |
| purchase order line | asset_id | Machine |
| purchase order line | deep_discharge_judgement_code | Deep discharge judgement |
| purchase order line | estimated_amount_ccy | Estimated amount |
| purchase order line | estimated_unit_price | Estimated unit price |
| purchase order line | expected_assay | Expected assay |
| purchase order line | line_no | Line |
| purchase order line | material_id | Material |
| purchase order line | notes | Notes |
| purchase order line | price_provenance | How the price was set |
| purchase order line | price_source | Price source |
| purchase order line | price_status | Price status |
| purchase order line | pricing_formula_id | Pricing formula |
| purchase order line | purchase_order_id | Purchase order |
| purchase order line | quantity | Quantity |
| purchase order line | tax_amount_ccy | Tax amount |
| purchase order line | tax_code | Tax code |
| purchase order line | tax_rate_pct | Tax rate % |
| purchase order line | unit | Unit |
| payment instalment | due_date | Due date |
| payment instalment | expected_date | Expected date |
| payment instalment | expected_date_set_at | Expected date set on |
| payment instalment | expected_date_set_by | Expected date set by |
| payment instalment | fixed_amount_ccy | Fixed amount |
| payment instalment | label | Description |
| payment instalment | notes | Notes |
| payment instalment | percentage | Percentage |
| payment instalment | purchase_order_id | Purchase order |
| payment instalment | trigger_event | Due on |
| retention | anchor_event | Counted from |
| retention | fixed_amount_ccy | Retention amount |
| retention | notes | Notes |
| retention | percentage | Retention % |
| retention | purchase_order_line_id | Line |
| retention | released_amount_ccy | Amount released |
| retention | released_at | Released on |
| retention | released_by | Released by |
| retention | retention_months | Retention period (months) |
| retention | withheld_amount_ccy | Amount withheld |
| retention | withholding_reason | Reason for withholding |
| committed pricing terms | average_days | Averaging days |
| committed pricing terms | committed_at | Committed on |
| committed pricing terms | committed_by | Committed by |
| committed pricing terms | flat_discount_pct | Flat discount % |
| committed pricing terms | inbound_batch_id | Batch |
| committed pricing terms | price_basis | Price basis |
| committed pricing terms | price_index | Price index |
| committed pricing terms | purchase_order_line_id | Line |
| committed pricing terms | source_formula_name | Formula name |
| committed pricing terms | treatment_charge_usd_per_tonne | Treatment charge (USD/t) |
| purchase order issue | issued_at | Issued on |
| purchase order issue | issued_by | Issued by |
| purchase order issue | purchase_order_id | Purchase order |
| purchase order issue | sha256 | Sha256 |
| contract link | contract_id | Contract |
| contract link | contract_title | Contract title |
| contract link | currency | Currency |
| contract link | grade_specs | Grade specifications |
| contract link | incoterm | Incoterm |
| contract link | linked_at | Linked on |
| contract link | linked_by | Linked by |
| contract link | payment_terms_days | Payment terms (days) |
| contract link | pricing_terms | Pricing terms |
| contract link | purchase_order_id | Purchase order |
| contract link | sales_order_id | Sales order |
| contract link | settlement_terms | Settlement terms |
| approval decision | actor_user_id | Decided by |
| approval decision | amount_base | Amount (base currency) |
| approval decision | amount_ccy | Amount |
| approval decision | currency | Currency |
| approval decision | decided_at | Decided on |
| approval decision | decision | Decision |
| approval decision | fx_rate | FX rate |
| approval decision | level | Level |
| approval decision | note | Note |
| approval decision | reconstruction_note | Reconstruction note |
| approval decision | self_decided | Decided on own document |
| purchase order change | amend_reason | Reason |
| purchase order change | line_no | Line |
| purchase order change | new_delivery_location | Delivery location |
| purchase order change | new_estimated_amount_ccy | Estimated amount |
| purchase order change | new_estimated_total_ccy | Estimated total |
| purchase order change | new_estimated_unit_price | Estimated unit price |
| purchase order change | new_expected_delivery_date | Expected delivery |
| purchase order change | new_fx_rate | FX rate |
| purchase order change | new_incoterm | Incoterm |
| purchase order change | new_notes | Notes |
| purchase order change | new_order_date | Order date |
| purchase order change | new_payment_term | Instalment |
| purchase order change | new_price_status | Price status |
| purchase order change | new_quantity | Quantity |
| purchase order change | new_terms_text | Terms text |
| purchase order change | new_unit | Unit |
| purchase order change | old_delivery_location | Delivery location |
| purchase order change | old_estimated_amount_ccy | Estimated amount |
| purchase order change | old_estimated_total_ccy | Estimated total |
| purchase order change | old_estimated_unit_price | Estimated unit price |
| purchase order change | old_expected_delivery_date | Expected delivery |
| purchase order change | old_fx_rate | FX rate |
| purchase order change | old_incoterm | Incoterm |
| purchase order change | old_notes | Notes |
| purchase order change | old_order_date | Order date |
| purchase order change | old_payment_term | Instalment |
| purchase order change | old_price_status | Price status |
| purchase order change | old_quantity | Quantity |
| purchase order change | old_terms_text | Terms text |
| purchase order change | old_unit | Unit |
| purchase order change | payment_term_seq | Instalment |
| processing record | allocated_at | Costs allocated on |
| processing record | allocated_by | Costs allocated by |
| processing record | allocation_basis | Allocation basis |
| processing record | allocation_basis_changed_at | Allocation basis changed on |
| processing record | allocation_snapshot | Allocation details |
| processing record | capitalization_entry_id | Capitalisation journal |
| processing record | capitalized_cost_base | Capitalised cost |
| processing record | delete_reason | Reason |
| processing record | deleted_at | Rolled back on |
| processing record | deleted_by | Rolled back by |
| processing record | equipment_id | Equipment |
| processing record | loss_qty | Loss |
| processing record | material_cost_base | Material cost |
| processing record | notes | Notes |
| processing record | operation_type_code | Operation |
| processing record | process_cost_base | Process cost |
| processing record | process_date | Process date |
| processing record | status | Status |
| processing record | total_cost_base | Total cost |
| processing record | total_input | Total input |
| processing record | total_output | Total output |
| processing record | work_order_id | Work order |
| processing input | inbound_batch_id | Batch used |
| processing input | output_batch_id | Batch used |
| processing input | quantity_consumed | Quantity used |
| processing input | run_id | Processing run |
| processing output | allocated_cost_base | Allocated cost |
| processing output | cost_incomplete | Cost incomplete |
| processing output | output_batch_id | Batch produced |
| processing output | quantity_produced | Quantity produced |
| processing output | run_id | Processing run |
| processing output | unit_cost_base | Unit cost |
| processing cost | amount_base | Amount |
| processing cost | cost_type | Cost type |
| processing cost | deleted_at | Removed on |
| processing cost | is_estimate | Estimate |
| processing cost | notes | Notes |
| processing cost | relief_expense_id | Relieving expense |
| processing cost | relieved_at | Relieved on |
| processing cost | remitted_at | Remitted on |
| processing cost | remitted_journal_entry_id | Remittance journal |
| processing cost | run_id | Processing run |
| processing cost change | new_amount_base | Amount |
| processing cost change | new_cost_type | Cost type |
| processing cost change | new_is_estimate | Estimate |
| processing cost change | old_amount_base | Amount |
| processing cost change | old_cost_type | Cost type |
| processing cost change | old_is_estimate | Estimate |
| processing cost allocation | amount_base | Amount |
| processing cost allocation | basis_qty | Basis quantity |
| processing cost allocation | basis_total_qty | Basis total |
| processing cost allocation | inbound_batch_id | Batch |
| processing cost allocation | run_id | Processing run |
| processing loss | loss_category_code | Loss category |
| processing loss | notes | Notes |
| processing loss | quantity | Quantity |
| processing loss | run_id | Processing run |
| role | deleted_at | Deleted on |
| role | description_en | Description (English) |
| role | description_zh | Description (Chinese) |
| role | is_active | Active |
| role | is_system | System role |
| role | name_en | Name (English) |
| role | name_zh | Name (Chinese) |
| role permission | permission_code | Permission |
| role permission | role_id | Role |

**Value labels** used on these tables (from the page's own message keys where registered, otherwise written for this part):

| field | values |
|---|---|
| approval decision · decision | submitted → Submitted for approval; approved → Approved; rejected → Rejected; auto_approved → Approved automatically; approval_voided → Approval withdrawn; recalled → Recalled; withdrawn → Withdrawn; countersigned → Countersigned; executed → Carried out; cancelled → Cancelled; returned → Returned for changes; posted → Posted; acknowledged → Acknowledged |
| committed pricing terms · price_basis | spot → Spot price; average → Average price |
| processing cost · cost_type | labour → Labour; electricity → Electricity; gas → Gas; depreciation → Depreciation; consumables → Consumables; waste_treatment → Waste Treatment; other → Other |
| processing cost change · change_type | create → Cost recorded; update → Cost changed; delete → Cost removed; restore → Cost restored |
| processing record · allocation_basis | weight → by weight; metal_value → by metal value |
| processing record · status | committed → Completed; reversed → Rolled back |
| purchase order change · change_type | header_update → Order details changed; line_add → Line added; line_update → Line changed; line_remove → Line removed; payment_term_add → Instalment added; payment_term_update → Instalment changed; payment_term_remove → Instalment removed; cancelled → Cancelled |
| purchase order line · price_source | manual → Entered by hand; formula → From a pricing formula; quote → From a quote; contract → From the contract; computed → Calculated |
| purchase order line · unit | kg → kg; t → t; unit → units; units → units; pcs → pieces; l → litres |
| purchase order · approval_status | pending → Awaiting approval; approved → Approved; rejected → Rejected |
| purchase order · category | consumables → Factory consumables; equipment_goods → Equipment and goods; office → Office supplies |
| purchase order · status | draft → Draft; confirmed → Confirmed; receiving → Receiving; closed → Closed; cancelled → Cancelled |
| inbound_batches · stage (machine-written Chinese) | 待加工 → Awaiting processing; 加工中 → Processing started; 已加工完 → Fully processed |

**Record-type names** for the summary page's filters (English only, all 239 incl. login accounts) are the generated
`TRAIL_TABLES` list in `lib/trail/catalogue.generated.ts`; names outside the three subjects were derived from table names and are queued
for your review (`docs/forward-queue.md`, the amended "238 tables' display names" item).

## §10 · Assertions in the brief that I measured

- "Your survey outputs are in a temporary scratchpad" — **true**, all eleven present (§1).
- "the false approvals comment in `lib/modules.ts:843`" — **true** (lines 843–846).
- "Inside one rolled-back transaction, create a purchase order …, edit a line, and read its trail" — **done**; note that one transaction is
  one entry by Q2, so the creation and the edit read as one entry (§6).
- "PDFs and outward documents keep 01 Sep 2026" — seven PDF routes used the screen formatter; switched to `formatDocumentDate` (§3).
- "All 7 real accounts stay enabled" — **7, 0 disabled**, before and after, and after every smoke run.
- Zero other assertions measured false.

## §11 · Docs

- **`docs/change-log.md`** — §4 updated (the summary page reads in plain English; one masking step); new §9 "Audit trails on each page":
  the reader, authorisation, which rows belong, masking, grouping and paging, pre-log merge, how later parts add a subject, wording rules,
  checks.
- **`docs/forward-queue.md`** — AT-1b (v1.4.34), AT-1c (v1.4.35), AT-1d (v1.4.36) and DATE-PICK-1 (v1.4.37) queued with their §8 scopes
  (plus where Q21, Q22–Q25, Q32–Q33 and Q35–Q39 land); "238 tables' display names" amended to English-only (Q7) with what AT-1a already
  generated; "per-record history panels" marked as carried by the AUDIT-TRAIL series; the DATE-1 picker row marked answered.
- **`docs/known-issues.md`** — the six defects (`AT0-DEEP-DISCHARGE-DIRECT-UPDATE`, `AT0-WITHDRAW-PAYMENT-REQUEST-NO-REQUESTER-CHECK`,
  `AT0-APPROVALS-COMMENT` (closed here), `AT0-RUN-EQUIPMENT-NOT-PASSED`, `AT0-ACTIONS-WITHOUT-CALLER`, `AT0-PO-CLOSE-REASON-IN-NOTES`) and
  three limits of this part (`AT1A-PRELOG-SHOWS-TODAYS-VALUES`, `AT1A-RUN-COST-JOURNALS-NOT-ON-TRAIL`, `AT1A-TRAIL-READ-COST`), and the
  date-path defect found and fixed here (`AT1A-DISPLAY-DATE-USED-AS-DATA`, closed).
- **`docs/surveys/AUDIT-TRAIL-0/`** — the Step 0 survey and hand-back (§1).
