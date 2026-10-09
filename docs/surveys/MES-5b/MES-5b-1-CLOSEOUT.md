# MES-5b-1 close-out — step 1 of the MES-5b-1 close-out + MES-5b-2 build brief (2026-10-09)

**Verdict: a, b and d pass; c is a recorded mismatch for Tim (it does not stop step 2); e is listed.** Nothing was fixed. The window close is in
`docs/forward-queue.md` item 44.

**Opening check.** First command **2026-10-09 13:06:49 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`00744effe656e8a6eb20c9c73ee099db0bdd55b1`. Files staged by explicit path only.

**Identities.** Live readings ran over direct psql to the pooler inside `BEGIN READ ONLY … ROLLBACK`: as `postgres` (`rolbypassrls = true`) on base
tables, and — for what each role reads — with each real account's JWT claims set inside that read-only transaction, the reconciliation precedent
(`db/scripts/2026-10-05-at1d3-live-recon.sql`): nothing was written, nothing acted. The page renders were fetched from the **deployed** app by seven
one-off clones of the real roles (`mintThrowaway { cloneOf }`, prefix `mes5b1probe`), cleaned by the ephemeral plan (after: 0 `mes5b1probe` accounts,
0 `probe-` roles, 7 real accounts, 0 disabled). Files: `mes5b1-closeout-readings.sql` (`READ_OWN_EXIT=0`, 13:12:34 CST) and
`mes5b1-closeout-render.mjs` (`RENDER_PROBE_EXIT=0`, 13:13–13:16 CST), both beside this file.

---

## 1 · Broken window — closed (bounded)

- **Start:** 2026-10-08 21:28:31 CST — measured, `db/migration-windows.tsv` (`2026-10-08-mes5b1-balance-and-yield.sql`).
- **End, lower bound:** 2026-10-08 22:39:22 CST — measured, `git reflog show --date=iso refs/remotes/origin/main`:
  `00744eff refs/remotes/origin/main@{2026-10-08 22:39:22 +0800}: update by push`.
- **End, upper bound:** 2026-10-09 13:06:49 CST — this session's first command, with Tim's "deployed" already in hand. It rests on what Tim said,
  not on a Vercel reading.
- **Window: 1 h 10 min 51 s – 15 h 38 min 18 s.**
- Close-out reading (13:19 CST, `postgres`, base tables): processing runs created since the window opened **0** (14 in all, 10 live, MES-4a-era 0) ·
  V37 values set 0 · closures 0 · quarantine splits 0 · `require_calibrated_since` NULL. Nobody used the new features in the window.

## 2 · Read-only verification

### a · The MES-5b-1 brief's "Fixtures must cover" list — every item covered

The list is the brief's own (MES-5b-1 session transcript, user message of 2026-10-08 11:33:58Z). Fixture 257 =
`db/fixtures/257-every-kilogram-goes-somewhere-and-every-level-adds-up.sql`; fixture 255 = `db/fixtures/255-a-batch-is-discharged-…sql`.
Measured today: `python3 db/gate.py --offline` on HEAD → **`GATEOFF_EXIT=0`** (85 s; fixtures 235 ✓ · 255 ✓ · 257 ✓). The injection run the
hand-back records (22:35 CST) postdates the last edit of 257 (20:52:46), 255 (20:12:48) and the injection script (20:55:27) — file mtimes.

| Brief item | Fixture · arm | Lines |
|---|---|---|
| consumption counted; deep discharge pass-through; quarantine split a transfer, no loss or remainder | 257 CONS | flows `:289-297`; split = transfer, no loss / remainder row, child carries the share `:299-303`; discharge an event of 400 `:305-306` |
| attribution: multi-input / multi-output by input mass; an output fed onward carries its share; every level exact | 257 ATTR | 200/300 on four children `:311-312`; 200·100 / 300·100 into R2 `:314-316`; rational identity over every tree `:318-319` (`f257_tree_bad`, `:124-150`); R1 / R2 attributed totals `:321-326` |
| batch identity, inbound and output, incl. discharge, split and reversed lines | 257 BAL (+ CONS) | inbound C 400 = 50 + 260 + 90, unexplained 0 `:331-334`; reversed run listed and linked `:335-339`; output O1 170 = 100 + 70 `:341-344`; split child `:345-347`; voided by reversal `:349-350`; discharge event `:305` |
| pre-MES-4a labelled; reversed excluded and listed; correcting run linked | 257 PRE · BAL · MONTH | `:354-358`; `:335-339`; reversed 50 listed `:391` |
| monthly balance lines and stock roll-forward | 257 MONTH · ROLL | input = outputs + losses + remainder per month × scope × operation `:372-377`; plant = Σ operations `:379-382`; every plant line `:383-392`; roll-forward `:406-422` |
| non-kg legs excluded and listed | 257 MONTH · NOTKG | `:393-395`; `:399-402` |
| the split closing its own balance; tolerance 0 seeded; absent from the month-end warning | 255 SPLIT | closed, remainder 0, tolerance 0, within `:476-481`; seeded 0 `:482-483`; absent from the reminder and `processing_runs_unclosed_balance` (the month-end warning) `:484-487`; absent from V1 `:488-489` |
| `/inventory` lifetime balance under Q3's exclusions | 257 INV | 710, differing from the old sum by exactly 400 + 90 + 10 `:364-367` |
| yield per run / operation / month; dust an output; recoverable losses; no yield on pass-through | 257 YIELD · PRE | `:426-432`; `:434-439`; no yield for reversed / discharge / split / non-kg `:359-360` |
| each grouping incl. "chemistry not recorded"; supplier name restricted without `module.inbound.view` | 257 GROUP | chemistry `:455-459`; supplier `:460-463`; machine `:464-466`; restricted / shown / "not recorded" is not a restriction `:468-479` |
| V37 flags below target, never refuses, hidden before any MES-4a-era run | 257 V37 | hidden before `:222-223`; listed after `:234-238`; set, viewer refused, leaves the list `:240-245`; R2 committed after it was set `:251` (no refusal); flags `:443-450` |
| f check: role save refuses; bootstrap self-check; fixture over rebuilt roles; build check on declared views | 257 FCHECK · rebuild cells · build | `set_role_permissions` refusals / any-one / self-gated / undeclared / edit guard `:505-519`; catalogue declarations `:521-525`; every rebuilt role `:527-531`; bootstrap self-check `db/tables/role_permissions.sql:268-280` (`BOOTSTRAP_ACTION_REQUIRES_VIEW`) and `db/tables/permissions.sql:236-252` (`PERMISSIONS_REQUIRES_VIEW_INVALID` / `_UNDECLARED`), both injected as rebuild cells (`db/scripts/2026-10-08-mes5b1-fixture-injections.py:235-240`); build check `scripts/check-action-view-declared.mjs` in `npm run build` (`package.json:7`) — run today **`AVD_OWN_EXIT=0`** (33 codes, 237 pages) |
| bootstrap admin every code; bootstrap finance `module.processing.view` | 257 FCHECK | `:533-539` — asserts **every code but `module.tasks.view_all`** (see c); finance `:538-539` |
| change-log binding, exclusions at 8; the wording arm | 257 LOG · V37 · wording ㉓ | coverage 0 gaps, excluded 8 `:543-545`; the V37 change in the log `:246-247`; ㉓ `scripts/check-trail-wording.mjs:5813-5893` — run today clean **`TW_CLEAN_OWN_EXIT=0`**, `TRAIL_WORDING_FAULT=wording-drift-mes5b1` → **`TW_FAULT_OWN_EXIT=1`**, only `✗ ㉓ … 1 处` |

### b · Four records — present

- **The unit check at commit:** `docs/known-issues.md:10536-10543` — `MES5B1-INPUT-UNIT-NOT-CHECKED-AT-COMMIT` (Q10: registered, not built; the views
  leave such a run out; 0 non-kg batches on live).
- **The per-tonne row struck:** `docs/forward-queue.md:1999` — `~~**Tim 的一句裁定:「每吨」的分母**~~ ✅ **已裁(MES-5a Q23:total_input …)—— MES-5b-1 划掉(Step 0 Q36)**`.
- **The wording arm:** ㉓, measured red and green today (table above).
- **Change-log exclusions at 8:** fixture 257 LOG `:544` (`excluded <> 8` raises) and fixture 235, both ✓ in today's offline gate.

### c · The standing ruling on admin's codes — it does **not** contain the `module.tasks.view_all` exception

The ruling, as the repo records it — `docs/role-matrix.md:208`:

> ★ **admin 角色持【每一个】码 · the admin role holds every code**(Tim 常设裁定,2026-09-24,已关)| Tim 用 admin@ 做测试,所以 `admin` 角色**保留它全部的码,
> 并拿到每一个新码**。…… ★ 唯一例外,照直记:`module.tasks.view_all`(读别人的个人任务)admin 【从来没有】—— Tim 2026-09-23 23:33 还回去的 45 个码里就没有它;
> 这条裁定说的是「保留 + 每一个新码」,所以 Batch 2b 没有替 Tim 加它。**要不要加,是 Tim 的一句话**

(and `docs/role-matrix.md:23`: "★ **角色持每一个码**(常设裁定 2026-09-24)").

The row's `module.tasks.view_all` sentence is the implementer's record of a fact (admin never held it) and of an **open question for Tim** — not an
exception Tim ruled. The ruling's own words are "keep + every new code", headed "holds every code"; the MES-5b-1 brief said "the bootstrap admin role
holds every permission code, matching the standing ruling". MES-5b-1 built 74 / 75 (`db/tables/role_permissions.sql:65-70`; fixture 257 `:533-537`;
its hand-back decision 14). **Mismatch recorded for Tim:** `docs/known-issues.md` `MES5B1C-ADMIN-TASKS-VIEW-ALL-UNRULED`. Not changed here.

### d · Usability on live — all seven roles open all three; every page renders with live data

From the hand-back's role table (`docs/handbacks/MES-5b-1.md:55-64`): all seven real roles **open** `/operation/balance`, `/operation/yield` and the
batch panel on both batch pages. Re-measured today:

| Real role (account) | Gate codes held (`has_permission`, own session) | Rows read through the readers (own session) | Deployed page, clone of the role: HTTP · title · pre-MES-4a label · error text |
|---|---|---|---|
| admin (admin@) | processing ✓ · inbound ✓ · output ✓ | monthly 23 (2026-08 "before closure" 1) · roll-forward 5 · run yield 30 (all 30 pre-MES-4a) · summary 42 · tree IN-2026-0001 103 · OUT-2026-0184 10 | balance 200 · ✓ · ✓ · none — yield 200 · ✓ · ✓ · none — `/inbound/<IN-2026-0001>/edit` 200 · ✓ · ✓ · none — `/output/<OUT-2026-0184>/edit` 200 · ✓ · — · none |
| finance (chooer@) | ✓ · ✓ · ✓ | identical | identical |
| warehouse (fusheng@) | ✓ · ✓ · ✓ | identical | identical |
| cto (phua@) | ✓ · ✓ · ✓ | identical | identical |
| cco (sandra@) | ✓ · ✓ · ✓ | identical | identical |
| cfo (tim@) | ✓ · ✓ · ✓ | identical | identical |
| gm (vince@) | ✓ · ✓ · ✓ | identical | identical |

- Clones held 74 / 41 / 28 / 34 / 42 / 32 / 21 codes (the same counts as the MES-5b-1 opening reading).
- "Pre-MES-4a label" = the page body contains "before balance closure" / "记在结平之前" (the balance page's remainder line, the yield page's per-run
  note, the inbound panel's remainder state). Live 2026-08 plant lines: input 4,015 · output 3,135 · remainder **before closure 880** · reversed 40.
- The output panel renders (title present, no error) without the label because **no live output batch has fed a run** (`OB|…|runs_fed=0` for every
  one) — its tree has no run node to label. Not a gap.
- "Error text" = `Application error` / `Internal Server Error` / `PERMISSION_DENIED` / the restricted-module hint: absent on all 28 fetches.

### e · Self-taken decisions in `docs/handbacks/MES-5b-1.md` §6 (titles)

1. A run with no operation counts as consumption.
2. The split is recognised by its `discharge_module_splits` rows.
3. Non-kg: the whole run is left out, not just the leg.
4. Exactness as a pair of numbers.
5. The batch identity has more lines than Q5 listed.
6. The monthly and roll-forward readers admit processing, finance or inventory view.
7. The batch-tree reader admits processing view or the root batch's own view code.
8. "Chemistry" and "supplier" follow the run's input back to its origin batches.
9. Yield per operation × month divides by every consuming run of that cell.
10. A balance closed with remainder exactly 0 counts as "closed within tolerance".
11. Movements with no business date are in no month.
12. V37's arm needs an MES-4a-era consuming run.
13. V37 is edited on the operation page by a direct update; not on the operation's trail.
14. The bootstrap admin holds every code except `module.tasks.view_all`.
15. "Self" declarations store the code itself.
16. `module.*.edit` codes are not declared.
17. The build check counts a page's gate as a use of its code.
18. The view replay order was fixed rather than renaming views.
19. The split closes through `close_run_balance`.
20. The month-end step keeps its link to the run list.
21. Fixture 257 runs INV before MONTH.
22. The live proof adds a fifth throwaway reader `pv`.
23. The live proof dates its runs the day before the run.
24. Probe prefix `mes5b1probe`.
25. The tables' first column is always kept on phones.

## 3 · Assertions measured and found false or imprecise

- **The brief's "the bootstrap admin holding every code"** (MES-5b-1 fixture list) — fixture 257 asserts every code but `module.tasks.view_all` (item c).
- Zero other assertions found false.
