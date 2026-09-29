# AUDIT-TRAIL-1 + DATE-PICK-1: the measured basis for a time estimate

Survey only (AUDIT-TRAIL-0 stop gate). Nothing in the repo was edited. No build, gate, smoke or backup was run, and the live DB was not touched.
**This file does not give an estimate for the new cut.** It gives the floor and the rates, each with its source.

## Sources and methods (every number below cites one of these)

| tag | what | how it was read |
|---|---|---|
| **HB** | the handback's own verification table (`docs/handbacks/<CUT>.md` §2/§4/§5) | `grep`/`sed` of the file. These are the script's own timings, as the handback records them |
| **DUMP** | backup duration | `~/evoltrya-backups/evoltrya-backup-<YYYY-MM-DD-HHMM>.dump`. **Start** is the minute stamp in the filename (the script names the file at launch). **End** is the file's mtime (`stat -f %m`). So each value is **±60 s** |
| **WIN** | migration apply commit time | `db/migration-windows.tsv` (the timestamp `apply_migration.sh` records) |
| **GIT** | commit times and sizes | `git log --format='%h %ci %s'`, `git show --shortstat`, `--numstat`, `--name-status` |
| **SESS** | session start/end and idle gaps | Only the `"timestamp"` fields of `~/.claude/projects/-Users-timchen/<uuid>.jsonl` were grepped (no content read). A session is mapped to a cut **by time overlap** with that cut's commit, so the mapping is **Inferred**. "Gap" = no transcript event for more than 15 min. A gap can be idle time waiting on Tim, **or** a long blocking tool call (for example a smoke wait), and I cannot tell which |

---

## 1 · Process floor: the fixed verification steps every migration cut pays

### 1a · Per step, over the last 10 migration cuts (APR-6 … HISTORY-1)

| step | n | min | median | max | values (cut) | source | M/I |
|---|--:|--:|--:|--:|---|---|---|
| offline gate `db/gate.py --offline` (one green run) | 10 | **52 s** (APR-6) | **54–58 s** | **61 s** (HISTORY-1) | A6 52 · A7 53 · A8 53 · A9 54 · A10 54 · ES 54/60 · TE 60 · OT 58 · LB 58 · H1 61 | HB | Measured |
| backup (detached; gates the apply) | 10 | **1,066 s ≈ 18 min** (TERMS-EDIT-1) | **1,373 s ≈ 23 min** | **1,719 s ≈ 29 min** (EMP-SELF-1) | A6 1398 · A7 1347 · A8 1599 · A9 1176 · A10 1415 · TE 1066 · ES 1719 · OT 1298 · LB 1081 · H1 1550 | DUMP (±60 s) | Measured |
| ↳ note | | | | | 2026-09-25 morning backups took **383 s and 569 s** (the 1123 and 1250 dumps). From 09-25 16:45 on, every backup took 1,066–1,719 s. The growth is not explained by dump size (4.9 → 5.4 MB). EMP-SELF-1 HB: "0 bytes through the catalogue phase … `EXECUTE dumpFunc`" | DUMP, HB | Measured (cause Inferred) |
| migration dry run on live (COMMIT→probe→ROLLBACK) | 1 timed | — | — | **626 s** first try, **199 s** batched (HISTORY-1, 495 trigger statements over 238 tables) | The other cuts record only `DRY_OWN_EXIT=0` with no duration | HB | Measured (H1 only) |
| backup end → apply committed (includes apply + preflight + in-txn proof) | 10 | **2 min** (LB) | **4 min** | **5 min** (A8, A10, ES, H1) | H1's apply itself: 23:57:21 → 00:00:03 = **162 s** | DUMP + WIN, HB | Measured (bounds) |
| `NOTIFY pgrst` + wait until the new functions appear | 1 | | **59 s** | | EMP-SELF-1 (`db/wait_for.sh`) | HB | Measured |
| `npm run types:gen` | 0 | — | — | — | Not timed in any migration handback. Inside the 45–64 min apply→commit tail | — | not measured |
| `npx tsc --noEmit` | 3 | **9 s** | 10 s | **10 s** | INPUT-2b 9 · INPUT-3 9 · FONT-1 10 | HB (UI cuts) | Measured |
| `npm run build` (static checks + `next build`) | 6 | **34 s** | 38–39 s | **42 s** | INPUT-2b 34 · INPUT-3 36 · FONT-1 38/39 · FONT-3 38 · DATE-1 40 · FONT-2 42 | HB (UI cuts, 2026-09-11…20) | Measured, but **old**: the migration handbacks do not time the build, and the build has gained checks since then |
| full gate `db/gate.py` | 10 | **296 s** (APR-9) | **488 s ≈ 8 min** | **908 s** (HISTORY-1) | A6 499 · A7 480 · A8 378 · A9 296 · A10 335 · TE 340 · ES 522 · OT 496 · LB 502 · H1 908 | HB | Measured |
| ↳ | | | | | H1's 908 s is the first run with the `changelog` / `changemask` rebuild and 238-table trigger mirrors. **AUDIT-TRAIL-1 inherits that cost**, so for it use 908, not the median | HB | Measured / Inferred |
| smoke `scripts/smoke-routes.mjs` (detached), sum of per-route times | 6 | **1,175 s** (TE run 2) | **1,289 s ≈ 21.5 min** | **1,679 s ≈ 28 min** (ES) | A10 1275 · TE 1175 · ES 1679 · OT 1492 · LB 1303 · H1 1212 | HB ("N routes timed, X s total") | Measured (route-time sum, **not** wall) |
| smoke **wall clock** | 3 | **~31 min** (APR-7 01:10→01:41) | | **~35 min** (APR-6 22:41→23:16) | DATE-1: wall 864 s vs timed sum 650 s → **wall ≈ 1.33 × sum** | HB | Measured (3 points) |
| live proof (one txn, ROLLBACK) | 0 | — | — | — | Not timed anywhere. **3 of 5 recent cuts needed a second run** (H1 exit 3, OT exit 3, ES exit 3), each caused by a wrong expectation in the proof, not a bug in the code | HB | not measured |
| deploy confirm → close-out commit | 3 | **11 min** (H1) | 28 min (LB) | 59 min (OT, includes a 52-min transcript gap) | GIT: 01:00→01:11 · 19:25→19:53 · 14:40→15:39 | GIT | Measured |

### 1b · Retries: a measured tax, not an exception

In the last 10 migration cuts, **6 of 10 had at least one red first run.** Only APR-6, APR-7, APR-8 and LEAVE-BAL-1 were clean end to end. (Source: HB, every row in §2/§4/§5.)

| cut | retries (the script's own line) | wall cost of the retry |
|---|---|---|
| HISTORY-1 | dry run ×2 (626 s → 199 s); backup `EXIT=1` network drop (`Can't assign requested address`); build ×2; full gate `EXIT=5` `SSL SYSCALL EOF`; live proof exit 3 | ≥ 626 s dry run + one gate attempt (≤ 908 s) + small ones |
| LEAVE-BAL-1 | none | 0 |
| OVERTIME-1 | offline gate ×2; **build ×4**; live proof ×2 | ≈ 3 × 38 s builds + 58 s + fixes (Inferred) |
| EMP-SELF-1 | smoke run 1 refused at import (0 s); live proof ×2 | small |
| TERMS-EDIT-1 | full gate `EXIT=1` (a literal `'USD'` in the cut's own proof script); **smoke run 1 failed on a needle → full rerun**; smoke run 2 exit 6 (sweep timeout) → reap | ≈ 340 s gate + **≈ 20–28 min smoke** → apply→commit took **127 min**, against a 45–64 min norm |
| APR-10 | offline gate ×4; **backup `EXIT=124` at the 2,700 s cap (45 min lost)**; dry run hit `statement timeout` behind `pg_dump`'s locks | **≈ 45 min** |
| APR-9 | offline gate ×2; backup relaunched (no `nohup`); tsc ×2 | small |
| APR-8, APR-7, APR-6 | none | 0 |

**Network drops** (the kind the brief names): 1 of the last 10 cuts had them: HISTORY-1, twice (the backup network drop and the full gate's SSL EOF). APR-10's backup hang is a third, lock/timeout-shaped.

### 1c · The floor, summed

The brief's order: offline gate → dry run → backup (detached, **gates** the apply) → apply → types → tsc → build → full gate → smoke (detached, gates the close) → live proof (after the smoke) → commit → deploy confirm.

**(i) Summed from the step medians (Measured steps; the unmeasured ones are labelled):**

| step | min | median | max |
|---|--:|--:|--:|
| offline gate | 0.9 | 0.95 | 1.0 |
| dry run (only H1 measured; small-migration dry runs were never timed, assume ≤ 1 min, **Inferred**) | 1 | 1 | 10.4 (H1, unbatched) |
| backup | 17.8 | 22.9 | 28.7 |
| backup end → apply committed | 2 | 4 | 5 |
| pgrst reload + types:gen (types not timed: **Inferred ~1**) | 1 | 2 | 2 |
| tsc + build | 0.7 | 0.8 | 0.9 |
| full gate | 4.9 | 8.1 | 15.1 |
| smoke (wall ≈ 1.33 × timed sum; 3 wall points 14.4–35) | 19.6×1.33 ≈ 26 | 21.5×1.33 ≈ 29 | 35 |
| live proof (never timed; **Inferred** a few min, and 3/5 need 2 runs) | 2 | 5 | 10 |
| **sum, sequential** | **≈ 56 min** | **≈ 74 min** | **≈ 108 min** |

(The full gate and the smoke can overlap only if they don't both need live. The handbacks run them one after the other, gate then smoke, because the smoke creates live accounts, so the sum above is sequential.)

**(ii) Cross-check from timestamps, per cut (Measured: DUMP + WIN + GIT):** from the backup launch to the cut commit. This is the floor plus whatever writing, fixing and handback work happened in the same stretch.

| cut | backup | backup end → apply | apply → cut commit | **backup launch → cut commit** |
|---|--:|--:|--:|--:|
| APR-5b | 19 | 3 | 54 | **76** |
| APR-6 | 24 | 3 | 57 | **84** |
| APR-7 | 23 | 4 | 49 | **76** |
| APR-8 | 27 | 5 | 60 | **92** |
| APR-9 | 20 | 4 | 45 | **69** |
| APR-10 | 24 | 5 | 46 | **75** (plus the 45-min failed backup before it) |
| TERMS-EDIT-1 | 18 | 4 | 127 | **149** (smoke rerun) |
| EMP-SELF-1 | 29 | 5 | 64 | **98** |
| OVERTIME-1 | 22 | 4 | 78 | **104** (build ×4, proof ×2) |
| LEAVE-BAL-1 | 18 | 2 | 51 | **71** |
| HISTORY-1 | 26 | 5 | 60 | **91** |

- backup launch → cut commit: **min 69 · median 84 · max 149 min** (11 cuts, APR-5a excluded because its session has 94 min of gaps).
- apply → cut commit (types … smoke … proof … handback): **min 45 · median 57 · max 127 min.**
- Add the pre-backup fixed steps (offline gate about 1 min, dry run 1–10 min) and the deploy close-out (11–28 min, Measured on 2 cuts). **The whole fixed floor comes to ≈ 80–125 min, with a median near 95 min** (Inferred as a sum of Measured parts).
- The two methods agree: (i) gives a 74-min median for the steps alone, and (ii) gives an 84-min median that also includes the handback and the fixes.

### 1d · Extra floor for DATE-PICK-1: a rendering-layer cut pays the UI instruments too

DATE-0 (`docs/handbacks/DATE-0-stopgate.md` §7.1, Measured): **"过程地板 ≈ 75 分钟,而它与这一刀改多少行【无关】"** ("the process floor is ≈ 75 minutes, and it has nothing to do with how many lines the cut changes"). Instruments total 3,900 s, and the stretch from the first run to the last build took 4,443 s.

| instrument | readings (s) | source |
|---|---|---|
| `survey-controls --mode=drift` (141 routes × 2 viewports), **before + after, each** | 1154 · 1193 (DATE-0) · 1164 · 1314 · 1372 (DATE-1) · 1669 · 727 (INPUT-2b) · 782 (INPUT-3 r1) · 1037 (INPUT-3) · 1558 · 1958 (FONT-1) · 1733 (FONT-2) → **min 727 · median ≈ 1,250 · max 1,958** | HB. `docs/known-issues.md` `INPUT3-DRIFT-COST-UNEXPLAINED` says "do not schedule on any single one" |
| full reading-layer probe | 1648 (FONT-1) · 1668 (FONT-2) | HB |
| `--mode=edit` | 117–161 | HB (INPUT-2b, FONT-1) |
| smoke on the UI cuts (older, fewer routes) | 377 (warm) · 641 · 692 · 864 · 871 (cold) · 1007 · 1038 | HB |
| UI-cut process totals | INPUT-2b: **34 min warm / 58 min cold**. FONT-2: **5,393 s ≈ 90 min** (Measured, against a 5,301 s estimate) | HB |

**So DATE-PICK-1 is a rendering cut and pays ≈ 40–65 min of drift (before + after) on top of the migration floor.** If AUDIT-TRAIL-1 ships in the same cut, the drift runs overlap the migration steps only where they don't compete for the dev server (Inferred).

---

## 2 · The work: wall-clock per cut from git and session timestamps

### 2a · Migration cuts (SESS + DUMP + WIN + GIT, minutes)

"A" = session start → backup launch. This is the authoring stretch: brief, design, migration, fixtures with fault injection, app code, offline gate and dry run. "A adj" subtracts transcript gaps longer than 15 min, which is a **lower bound** because a gap may be a blocking tool run.

| cut | files · +ins/−del (GIT) | app/components/lib files · +lines | page.tsx touched | migration lines | new fixture · lines | injections / arms (HB) | **A** | A adj | session → cut commit | adj |
|---|---|---|--:|--:|---|---|--:|--:|--:|--:|
| APR-5b | 82 · +6666/−548 | 18 · +1068 | 3 | 2707 | 1 · 652 | — | 66 | 66 | 142 | 142 |
| APR-6 | 61 · +5001/−199 | 13 · +625 | 3 | 2012 | 1 · 439 | 14 arms A–N + 1 injection | 64 | 64 | 148 | 148 |
| APR-7 | 95 · +6827/−525 | 22 · +985 | 5 | 2676 | 1 · 567 | arms A–N + 1 injection | 59 | 59 | 135 | 135 |
| APR-8 | 93 · +6341/−199 | 15 · +1007 | 3 | 2434 | 1 · 570 | A–K + 1 injection | 73 | 73 | 165 | 144 |
| APR-9 | 80 · +7579/−165 | 20 · +1260 | 4 | 3081 | 1 · 610 | A–L + 2 injections | 148 | 72 | 217 | 141 |
| APR-10 | 124 · +7130/−389 | 23 · +700 | 6 | 3693 | 1 · 742 | 9 arm groups + 2 injections | 292 | 52 | 367 | 127 |
| TERMS-EDIT-1 | 39 · +3012/−30 | 16 · +1016 | 1 | 514 | 1 · 288 | A–H + 1 injection | 16 * | 16 | 165 | 114 |
| EMP-SELF-1 | 36 · +2640/−65 | 12 · +255 | 3 | 956 | 1 · 371 | 7 arms, 1 injection | 46 | 46 | 144 | 144 |
| OVERTIME-1 | 69 · +6028/−90 | 22 · +1197 | 6 | 2092 | 1 · 467 | **26 injections** | 86 | 55 | 189 | 158 |
| LEAVE-BAL-1 | 33 · +2619/−45 | 9 · +107 | 2 | 1101 | 1 · 256 | **19 injections** | 76 | 41 | 147 | 112 |
| **HISTORY-1** | 78 · +7489/−22 | 12 · +832 | 3 | 2626 | **2 · 647** | **38 injections** (29 + 9) | **130** | **114** | **221** | **205** |

\* TERMS-EDIT-1's backup launched 16 min into its session, so its build work sat after the backup. Its A is not comparable.

- **Session → cut commit, 11 migration cuts: min 135 · median 165 · max 367 min raw; min 112 · median 142 · max 205 min gap-adjusted** (Inferred mapping, Measured timestamps).
- **The HISTORY-1 analogue: 221 min raw, 205 adjusted, plus 11 min to close out.** A = 130 min for 2 fixtures (38 injections), a 238-table generated trigger file, 3 pages and 832 app lines. HISTORY-0 (the survey) was a separate session before it (not mapped).
- **Size barely moves the total.** LEAVE-BAL-1 (2.6k lines, 9 app files) took 147 min. APR-7 (6.8k lines, 22 app files, 5 pages) took 135 min. The spread comes from retries (TERMS-EDIT-1, APR-10) and idle gaps, not from size. Across the 9 cuts without large gaps, A ranges 41–114 min (adjusted) while insertions range 2.6k–7.6k. Only HISTORY-1 (the most injections, 38) sits clearly high (Inferred from the table).

### 2b · UI conversion cuts (zero migration)

| cut | size (GIT) | session (SESS, Inferred mapping) | wall to commit | of which instruments (HB) | residue ≈ the work |
|---|---|---|--:|--:|--:|
| **DATE-1** (1/3 + 2/3) | formatter + 3 gates (10 files) + sweep **393 sites / 152 files** (+826/−482) via a scratch `codemod-dates.mjs` | 2b1474e4 12:29 → 15:03 (possibly started in b0376ad6's 40-min gap at 11:41) | **154–198 min** | drift ×3 = 3,850 s, smoke 864, gate 366, build 40, probes ~130 → **≈ 87 min** | **≈ 67–111 min** |
| **INPUT-3** | **287 sites / 14 routes / 37 app files** | d0095eca, HB §1.1 start 09:00:16 → commit 10:26 | **86 min** | drift 1037 + smoke 641 + gate 209 + build 36 + tsc 9 → **≈ 32 min** | **≈ 54 min** |
| **INPUT-2b** (ROUND 2 + 3) | **436 units / 124 files** | 6c53eddd + 9ef15f29 | — | HB: ROUND 3 alone **48 min** end to end | HB: ROUND 2 build work **≈ 2,970 s ≈ 50 min** |
| **INPUT-2** | 190 sites via 49 constants / 46 app files | 0e07ad27 19:50 → 21:50 | **120 min** | HB: drift 1485, edit 145, gate 403, build 38 … ≈ 37 min, **plus a 2,337 s probe lost and rerun** | — |
| FONT-1 | 403 app files (+1710/−1457) | 1857e889 + cd669bd6, 13:53 → 19:38, one stop for Tim | ≈ 345 min | HB timeline 06:04Z → 09:21Z = 197 min of measurement and conversion. The **conversion itself took ~360 s** (scripted) | — |
| FONT-2 | 300 app files | 1443b0c4 21:52 → 00:17 | **145 min** | HB: process **5,393 s ≈ 90 min** | **≈ 55 min** |
| FONT-3 (1/2) + (2/2) | 252 + 35 app files | 4d59f728 14:13 → 18:06 | **233 min** (1/2 at 68 min) | smoke 692, gate 340, build 38 … | — |
| BTN-TRIGGER-1 | **33 sites / 31 files** (+46/−32) | a2575d60 05:24 → 07:06 | **102 min** | gate 274, two builds … | — |

---

## 3 · Per-unit rates you can defend

| rate | value | source | M/I | fit for DATE-PICK-1 |
|---|---|---|---|---|
| mechanical site, driven by a shared constant | **4.1 s/site, 16 s/edit** (190 sites, 49 edits, 780 s) | INPUT-2 HB §14.2 | Measured | Poor: a date picker is not a class swap |
| scripted codemod sweep, including judging and instruments, excluding the process floor | **≈ 7 s/edit, ≈ 24 s/file** (≈ 2,970 s / 422 edits / 124 files) | INPUT-2b HB §R3-18② | Measured | Only for the mechanical part (import + tag rename) |
| DATE-1 sweep: residue ÷ sites | **≈ 10–17 s/site, ≈ 26–44 s/file** (67–111 min / 393 sites / 152 files) | §2b above | Inferred (residue = wall − Measured instruments) | Closest in *topic*; but these were display strings, not controls |
| INPUT-3: residue ÷ sites | **≈ 11 s/site, ≈ 88 s/file, ≈ 3.9 min/route** (54 min / 287 / 37 / 14) | §2b | Inferred | Controls, but styling only |
| judgment-heavy single control (a file-upload button wired to a shared class, a colour ruling) | **≈ 2.5 min/item** (12 items ≈ 30 min) | INPUT-2 HB §14.2, **an estimate that was never re-measured** | **Inferred** | The nearest per-control figure for a native→custom swap with value plumbing (name/hidden input, defaultValue, min/max, required) |
| bespoke control replacement inside a migration cut | OVERTIME-1 build run 3: "two new native date controls … replaced by server-built dropdowns from `lib/dates`" inside one build-fix loop. Not timed | OVERTIME-1 HB §2 | not measured | Shows the ratchet catches new natives. No rate |
| migration cut, authoring stretch (A adj) | **41–114 min, median ≈ 57** (9 cuts, one new fixture each) | §2a | Inferred mapping / Measured stamps | Per-cut, not per-unit |
| fixture with fault injection | HISTORY-1: A = 114–130 min for **2 fixtures / 38 injections** plus the generator. OVERTIME-1: 55–86 min for 1 fixture / 26 injections. LEAVE-BAL-1: 41–76 min for 1 fixture / 19 injections. → **≈ 2–3.5 min per injection arm** if all of A were charged to fixtures, which is an **upper bound** since A also holds the migration and app code | §2a + HB | Inferred | Upper bound only |
| per page touched in a migration cut | no stable rate: A shows no trend over 1–6 pages (TERMS-EDIT-1 1 page · APR-10 6 pages) | §2a | Inferred | Don't use per-page |
| full UI-cut floor (drift before + after, build, smoke, gate) | **58 min cold / 34 min warm** (INPUT-2b), **≈ 75 min** (DATE-0), **≈ 90 min** (FONT-2) | HB | Measured | Pay once, independent of site count |

### Denominators for the coming work (Measured today, for the rate-holder to apply)

- Native date inputs in code: **134** (`scripts/date-format-baseline.json` → `nativeDateInputs`, code only, comments excluded). A raw grep for `type="(date|month|datetime-local|week)"` over `app components lib` (*.ts, *.tsx) finds **142 hits in 92 files**, but that count **includes comments**. DATE-0 counted 130 `date` + 4 `datetime-local` in 85 files. The brief's "~134 / ~85" matches the ratchet baseline.
- Two shared date components already exist: `ContractDateInput` (TERMS-EDIT-1) and `app/components/ui/date-filter-input.tsx` (HISTORY-1). Both cut the count (135 → 134), which means some native sites are already behind a wrapper. File count with comments excluded was not re-measured here.

## 4 · Caveats that change the reading

1. **Transcript gaps are ambiguous.** A gap longer than 15 min can be Tim deciding or a detached smoke/gate being waited on. The "adj" columns are therefore lower bounds and the raw columns are upper bounds.
2. **Backup time jumped** from 6–9 min (09-25 morning) to 18–29 min (every cut since 09-25 afternoon). Use the 18–29 min range, not the older numbers.
3. **The HISTORY-1 gate (908 s) is the new baseline** for any cut that touches `change_log` or its mirrors, and AUDIT-TRAIL-1 does. The earlier 296–522 s range predates the 238-table trigger mirrors.
4. **Retries were the norm: 6 of the last 10 cuts had at least one red first run.** The costliest single retries measured were APR-10's backup hang (45 min) and TERMS-EDIT-1's smoke rerun (≈ 20–28 min).
5. **Build and tsc times come from 09-11…09-20 UI handbacks.** No migration handback times them.
