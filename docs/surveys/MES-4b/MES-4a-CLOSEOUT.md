# MES-4a close-out — step 1 results (2026-10-07)

**STOPPED BEFORE MES-4b STEP 0.** Items **a** and **f** below are only partly done, so under the brief's step 5 MES-4b Step 0 (grilling)
did **not** start: no fix, no code edit, no migration, no live write. The only writes are docs: `docs/forward-queue.md` item 40 (window closed,
Tim's two actions, this check), this file and `closeout-readings.sql` beside it. Waiting on Tim's ruling on a and f.

**Opening check.** First command **2026-10-07 20:52:44 CST** (`date`). Tree clean. After `git fetch`: `HEAD` = `origin/main` =
`git ls-remote origin main` = **`51bbdb428b823d96aa6d6829f24ea02fcc9f1276`** (MES-4a, v1.4.41).

**Live readings: TAKEN** (not refused this time) — 20:58 CST, as `postgres` (`rolbypassrls = true`), `BEGIN READ ONLY … ROLLBACK` under
`default_transaction_read_only = on`; queries in `closeout-readings.sql`, both runs `READ_OWN_EXIT=0`. Tags: **[M]** measured (file:line or a
named query with its identity) · **[I]** inferred from code reading · **[Q]** quoted from an earlier record.

---

## 1 · Broken window — closed (`docs/forward-queue.md` item 40)

| | time (CST) | source |
|---|---|---|
| start | **2026-10-07 19:03:15** | measured — `db/migration-windows.tsv:223` |
| end, lower bound | **2026-10-07 20:32:27** | measured — `git reflog show --date=iso refs/remotes/origin/main`: `51bbdb42 … {2026-10-07 20:32:27 +0800}: update by push` |
| end, upper bound | **2026-10-07 20:52:44** | this session's first command, holding Tim's "deployed" — **a report, not a Vercel reading** |
| **window** | **1 h 29 min 12 s – 1 h 49 min 29 s** | |

What was broken in it (derived, MES-4a hand-back §5.4, not measured on live): a run committed from the old form was refused
(`RUN_TIMES_REQUIRED|start,end`); the old loss panel's direct writes were refused; reads unaffected. At 20:58 live holds **0** runs with a start
time, 0 loss rows, 0 weighings [M] — nobody recorded a run inside the window.

## 2 · Tim's own actions after deploy (`docs/forward-queue.md` item 40)

1. Link machines to operations on the operation page (`/operation/operation-types/<code>`). Live today: **0** links [M], so every operation's
   machine is optional.
2. Set each shift's start and end time in the shift editor (`/settings/dictionaries` › Shifts; both or neither). Live today: day and night,
   both active, both with no times [M] — the two V6 rows.

## 3 · Items a–i

### a · Opening live readings as recorded in the hand-back — **PARTLY DONE**

- Recorded: `docs/handbacks/MES-4a.md:23` `processing_runs` 14 rows · `:25` `processing_run_losses` 0 rows · `:28` `shifts` 2 rows, both with no times.
- **Not recorded: uncommitted and unallocated runs.** The MES-4a brief's "Opening reading" asked for them by name ("run counts, uncommitted and
  unallocated runs, loss rows, shift rows"); §0 of the hand-back carries neither number. The reading **was** taken — off-repo log
  `~/mes4a-work/logs/opening-readings.txt` (15:14:30, `READ_OWN_EXIT=0`):
  `runs|committed|t|10|8|…` (committed, live 10, unallocated 8) and `runs|reversed|f|4|3|…` (reversed 4, all deleted, unallocated 3) — but it
  never reached the hand-back. (Status has two values, `committed` and `reversed`; "uncommitted" = the 4 reversed.)
- Re-read now [M, 20:58]: committed live **10**, unallocated **8**; reversed **4**, unallocated **3**; MES-4a-era runs **0**; loss rows **0**;
  shifts **2** (day, night, active, no times). Identical to the 15:14 log.

### b · Usability on live today — **PRESENT: both kinds of run can be recorded**

- Shift: `assert_run_header.sql:36` requires `shifts.is_active` only (no times); live has 2 active shifts [M]. The form offers every active
  shift (`app/operation/processing/new/page.tsx:107` `.eq('is_active', true)`; `NewProcessingForm.tsx:528-531`).
- Machine: `assert_run_equipment.sql:40-47` requires one only when the operation has a linked machine not disposed; live links **0** [M].
- Output weighing: a typed weight records a manual weighing in the same transaction (`commit_processing_run.sql:314-325`,
  `record_manual_weighing_internal.sql:25-41`, instrument optional); with `require_calibrated_since` NULL [M] a weighing with no instrument is
  flagged, not refused (`commit_processing_run.sql:344-347`).
- Required values: none — `operation_type_fields` with `is_required` = **0** [M]; required values are checked at closure, not commit.
- Inputs [M, same predicate as `guard_processing_input`]: of **12** inbound batches with available stock, **1** is admitted by every active
  operation — `ZZ-PROCCOST1-DEMO` (100, `discharged_verified`). The other 11 sit on materials whose `may_be_processed` is undecided (NULL →
  `MATERIAL_NOT_PROCESSABLE`), a pre-MES-4a data state. Only **1** live material is a processable battery material.
- **Verdict:** an operator holding `action.processing_commit` (warehouse, admin) can record a **transforming run** (e.g. manual disassembly
  on `ZZ-PROCCOST1-DEMO`, typed output weight, chosen shift) and a **deep-discharge run** (deep discharge accepts `discharged_verified` too,
  `closeout-readings` `operation_types` row) on live right now. Nothing MES-4a added blocks it. A deep discharge of a **charged** batch needs a
  charged batch first — none is in stock on live today; receiving one is an ordinary receipt. [I for the commit itself — this session did not
  commit; MES-4a's rolled-back live proof (hand-back §5.1) committed both kinds as fusheng@.]

### c · The brief's fixture list, item by item — **PRESENT** (with two notes)

All in fixture 253 (`db/fixtures/253-a-run-states-its-hours-weighs-its-outputs-and-closes-its-balance-in-writing.sql`):

| brief item | arm · lines |
|---|---|
| header: time and shift refusals, process-date rule, older runs unaffected | HDR · 125-140 (each refusal), 142-143 (overnight), 145-146 (table trigger), 148-159 (pre-MES-4a run: update OK, `before_closure`, not closable, not correctable) |
| machines: required when linked, unlinked refused, disposed not counted, non-equipment refused | MACH · 177-178, 179-180, 184-186, 171-172 |
| fields: at commit and later, append-only correction, out-of-range flagged, retired | FIELD · 193-198, 201-202, 206-214 + 227-228, 197-200, 219-223 |
| events: append-only, correction, dictionary type | EVENT · 250-251, 243-249, 237-240 |
| recipes: fixed version, pre-fill, difference shown | RECIPE · 265-266, 267-273, 276-279 |
| loss_qty derived, different value refused, named losses above it refused | LOSS · 298-300, 296-297, 304-305 |
| closure (11 cases) | CLOSE · required value 326-328 · weighing missing 330-333 · zero remainder 352-357 · within tolerance 360-368 · beyond tolerance 373-375 · tolerance not set 335-336 · with explanation 341-345, 376-378 · reopened 348-351 · state-changing DISCH 448-449 · pre-MES-4a HDR 156-157 · no aftercare 337-340 |
| weighings (8 cases) | WEIGH · picked 399-404 · typed 386-395 · REQUIRED 411-412 · out of calibration 430-437 · no instrument flagged 396-398 (+ refused with the switch on 418-421) · superseded 423-425 · already used 406-410 · IN_USE 427-428 |
| deep discharge without outputs | DISCH · 441-447 |
| two new operations accept `discharged_verified` only | NEWOPS · 453-468 |
| losses append-only, withdrawal = correction to zero, no direct write | LOSS · 315-316, 309-312, 317-320 |
| `correct_run_header`: each field, refused field, `corrects_run_id` rules | CORR · 473-484, 485-486, 491-497 |
| dropped policies (222 P3, L1) | POL · 501-508; fixture 222 (item e) |
| month-end warning non-blocking, reminder arm | MONTH · 512-523; non-blocking: COST · 531-532 |
| allocation unaffected by closure, both directions | COST · 527-539 |
| V1, V36, V6 relabelled | PV · 543-563 |
| shift time field kind | SHIFT · 569-574 (the paired DB columns written by a processing editor); the editor's `time` kind itself is app code (item h) |

Fault injection: `db/scripts/2026-10-07-mes4a-fixture-injections.py`, log `~/mes4a-work/logs/injections-2.log` (off-repo, 16:11):
`INJECTIONS_OWN_EXIT=0 (68 injections, 0 wrong)`; per arm HDR 6 · MACH 4 · FIELD 8 · EVENT 4 · RECIPE 5 · LOSS 5 · CLOSE 7 · WEIGH 8 ·
DISCH 2 · NEWOPS 2 · CORR 4 · POL 2 · MONTH 2 · COST 2 · PV 3 · SHIFT 2 · TRAIL 2 — **all 17 arms red**, the script refuses to pass otherwise
(`:250-255`). Notes: (1) two WEIGH injections go red in **HDR** (its overnight run is the first commit); the script accepts them as
`WEIGH|HDR`. (2) The injection run (16:10–16:11) **predates** three later edits it never re-ran against: `correct_run_header.sql` and fixture
253 (16:20:51, the code rename `RUN_HEADER_BEFORE_MES4A` → `RUN_HEADER_PREDATES_RECORD`) and `trail_refs.sql` / `trail_ref_label.sql`
(16:46:09) [M, file mtimes]. The clean fixture passed on the final versions (offline and full gate, hand-back §4).

### d · Existing fixtures calling `commit_processing_run` — **PRESENT** (one count corrected)

`git diff 9cbcba2a 51bbdb42 -- db/fixtures` [M]: **54** existing fixtures changed, **0** deleted or renamed, 1 added (253).
- **45** fixtures call `commit_processing_run` (`git grep -l "commit_processing_run(" 9cbcba2a -- db/fixtures`) — **all 45 changed**. The
  hand-back's "46" counts fixture 111, which only names it in comments (`111…:35,167,278`). The other 9 changed fixtures (26, 31, 83, 85, 101,
  111, 172, 196, 248) insert runs directly and gained the header columns.
- Not weakened: no changed fixture has fewer `RAISE EXCEPTION` lines than before (53 equal, 222: 47 → 51). Every changed assertion line
  (`git diff -U0 … | grep RAISE|IF|<>`): 222 P3 / L1 flipped (item e); arm counts 30 (21 → 22, `30-…:411`), 47 (+`processing_balance_unclosed` in its
  expected list), 111 F1 (55 → 56); 47 passes `p_loss_qty` NULL instead of 0 (0 would now be `LOSS_QTY_NOT_INPUT_MINUS_OUTPUT`). **One
  narrowing:** 111 F1 ②'s isolation read now excludes `processing_balance_unclosed` (`db/fixtures/111-…:345`
  `WHERE item_type <> 'processing_balance_unclosed'`, with its reason: the fixture's scaffolding runs light that arm, which 253 MONTH pins).

### e · Fixture 222 flipped; known issue closed; no direct write path — **PRESENT**

- 222 P3 `:302` "直连改备注应当按名拒(MES-4a 拿掉了 UPDATE 策略)" (was "照旧放行"), plus `:305` outputs and `:308` inputs; L1 `:329-348`
  (view-only → `PERMISSION_DENIED|action.processing_aftercare`; warehouse direct insert / update / delete → `permission denied for table
  processing_run_losses`; through `record_run_loss` / `correct_run_loss` → OK).
- `docs/known-issues.md:198` "~~ROLE1B3B-PROCESSING-UPDATE-POLICIES …~~ —— ✅ **关闭于 MES-4a(2026-10-07)**".
- Live [M, part 2]: policies on the four tables = SELECT only, plus the pre-existing `processing_inputs insert by permission`; that INSERT is
  refused by `trg_processing_inputs_guard` (`PROCESSING_INPUT_DIRECT_INSERT` outside a processing / reversal context,
  `db/tables/processing_inputs.sql` guard body). Statement-level `trg_processing_{runs,inputs,outputs}_direct_change` raise
  `PROCESSING_THROUGH_FUNCTION_ONLY` on any UPDATE / DELETE (`guard_processing_direct_write`); `processing_run_losses`: authenticated holds no
  INSERT / UPDATE / DELETE privilege and `trg_processing_run_losses_append_only` stands.

### f · The smoke check loosened during MES-4a — **NOT AS DESCRIBED**

Diff (`git diff 9cbcba2a 51bbdb42 -- scripts/smoke-routes.mjs`):

```diff
+    // emptyOk:一道引导播下、之后没人改过的工序,审计记录本来就是空的(冒烟读的是第一道在用的工序);要断言的是它画得出、不是受限或报错
+    '/operation/operation-types/[code]': [{ trail: 'audit-trail', why: '工序页底的审计记录(MES-4a)', emptyOk: true }],
…
+            if (route === '/operation/operation-types/[code]') {
+                const rows = await restRows(`/rest/v1/operation_types?select=code&is_active=eq.true&order=sort_order&limit=1`, …)
```

- The committed assertion was **added already loose**; the strict version (entries required) lived only in the working tree for the first
  smoke run (hand-back §4 row 11).
- `emptyOk` is **unconditional**: `scripts/smoke-routes.mjs:956-957` passes `state === 'empty'` whenever `emptyOk` is set, and the route always
  reads the first active operation by `sort_order` (deep discharge), whether or not it has changes. So **it does not fail when a changed
  operation shows no trail entry** — the brief's condition is false. It still fails on `refused`, on a missing section, and on machine tokens
  in the trail text (`:950-966`).

### g · V1, V36, V6 — **PRESENT**

`db/views/pending_values.sql:184-192` (V1: active operations whose kind produces outputs, tolerance empty, href
`/operation/operation-types/<code>`) · `:194-202` (V36: active fields with `has_range` and both bounds empty) · `:60-67` (V6: href
`/settings/dictionaries`). Labels `messages/en.ts:10620,10628-10629,10636,10644-10645`. `docs/mes-pending-values.md:22` (V6 "moved here by
MES-4a, Step 0 Q5"), `:33` (V1), `:34` (V36). Live [M]: V1 6 rows (the six transforming operations), V6 2 rows, V36 0 rows.

### h · Shift time kind; new operations; deep discharge without outputs — **PRESENT**

- `app/settings/dictionaries/registry.ts:43` `kind: … | 'time'`; `:244-252` shifts with `starts_at` / `ends_at` `kind: 'time'`, paired;
  rendered `DictSection.tsx:253`, saved `actions.ts:87,131`.
- `db/tables/operation_type_safety_states.sql:56-57` `('casing_removal', 'discharged_verified', …)`, `('electrode_separation',
  'discharged_verified', …)`; live [M]: casing_removal and electrode_separation accept `discharged_verified` only.
- `commit_processing_run.sql:213-222` (outputs required only when the operation produces them) and `:386-392` (state-changing: loss 0);
  page `NewProcessingForm.tsx:310-324` (`producesOutputs && validOutputs.length === 0` is the only refusal); fixture 253 DISCH.

### i · Decisions MES-4a took without asking (`docs/handbacks/MES-4a.md` §6), titles only

1. Machine picker when nothing is linked. · 2. The loss field left the form. · 3. Times are entered on the house date-time picker. · 4. Only
values that differ from the recipe are sent. · 5. A withdrawn exception and a zero loss are corrections, not deletions. · 6. Refusal code renamed
`RUN_HEADER_BEFORE_MES4A` → `RUN_HEADER_PREDATES_RECORD`. · 7. Header corrections only on MES-4a runs. · 8. A reversed, uncorrected run links to
the run form with `?corrects=<id>`. · 9. The operation page lists equipment-category assets only. · 10. Recipe codes are upper-cased on entry. ·
11. The month-end step is "outstanding", never "blocked". · 12. `/settings/dictionaries` also admits `module.processing.view`. · 13. The trail
names a value's field and a recipe version. · 14. `WEIGHING_IN_USE` is a capture-family code. · 15. `RUN_NOT_COMMITTED`'s sentence was
generalised. · 16. The smoke test reads a live operation code. · 17. Fixture dates moved into the past. · 18. Type-checking before the migration
used a temporary splice.

## 4 · Assertions measured and found false or imprecise

1. **Hand-back §2 "the 46 that call `commit_processing_run`"** — 45 call it; the 46th (111) names it only in comments (item d).
2. **Smoke: "Changed it to `emptyOk` (still asserts the trail renders …)"** — accurate for what it asserts, but the brief's "loosened only for
   an operation with no changes" does not hold: the exemption is per route, not per operation state (item f).
3. **Hand-back §0** omits the uncommitted / unallocated counts the brief asked for, though they were measured (item a).
4. **Hand-back §0 code holders** name live roles with accounts; the 15:14 log shows `module.processing.edit` also on `operations` and
   `module.processing.view` also on `auditor` and `operations` — roles with no live account. Not an error in the role table; noted so the
   holder list is not read as complete.

## 5 · Stop

MES-4b Step 0 not started. Waiting on Tim's ruling on a and f.
