> Supporting evidence for `docs/surveys/MES-0/README.md`. Written by a read-only survey sub-agent on 2026-10-05 and re-read in full by the survey author. Tags as in that file.

# MES-0 · cut-duration calibration (read-only research, 2026-10-05)

Repo: `~/Documents/projects/new-era-erp`. Nothing in the repo or the DB was touched.

## 0 · Method and labels

- **Push time** = `git reflog show --date=iso refs/remotes/origin/main` ("update by push"). Measured.
- **Migration commit (window start)** = `db/migration-windows.tsv`. Measured (written by `apply_migration.sh`).
- **Session start**, three kinds:
  - **M** = measured: the hand-back's own "Opening check … this session's first command" line.
  - **D** = derived: the *next* cut's §W "end, upper bound" of the previous window, which is "this session's first live read / first command" of the cut in question (e.g. `ROLE-1.md:776`, `:994`, `:1219`, `:1451`, `AP-RECON-1.md:266`, `:588`, `INB-PAY-1.md:137-138`). It is a real clock reading by that session, but taken by the session, not stated as its "opening".
  - **U** = upper bound only: previous push of anything (session may have started later; includes Tim's review gap). Treat as ≤.
- **Backup start** = the dump's filename minute (`evoltrya-backup-YYYY-MM-DD-HHMM.dump`); **backup end** = the dump file's mtime in `~/evoltrya-backups/` (measured, `stat`) or the hand-back's own "→ HH:MM" line. APR-10's backup start is inferred (2,700 s timeout before the 16:06 retry).
- **Gate / offline-gate / smoke seconds** are quoted from the hand-back line given (script's own figure).
- **Stats columns** are from `git show --name-status` of the cut commit (A = added file, M = modified): mirror files under `db/tables` (A = new table), `db/functions`, `db/views`; new `app/**/page.tsx`; `db/fixtures`. Lines = `--shortstat` insertions/deletions (includes the hand-back and docs).
- No hand-back states its own total wall-clock; every span below is computed by me from the timestamps above.

## 1 · Per-cut table (newest first)

Span = session start → push. "apply→push" = migration commit → push = the broken window's measured lower bound (it matches each hand-back's "at least" figure). "backup→push" = backup start → push (a proxy for the post-work process tail; it over-counts where work continued after the backup was launched, e.g. ROLE-1-2b, TERMS-EDIT-1).

| cut | date | start kind | span | start→apply | backup→push | apply→push | mig | tbl A/M | fn A/M | view A/M | new pages | fixtures A/M | lines + / − |
|---|---|:-:|---|---|---|---|:-:|---|---|---|:-:|---|---|
| U1-A | 10-05 | M | **3h39** | 1h13 | 2h43 (1h28 excl. 75 min probe-writing gap) | 2h25 | 1 | 0/11 | 5/11 | 6/6 | 0 (19 routes changed) | 1/3 | 6106/366 |
| DATE-PICK-1 (no DB) | 10-05 | M | **5h36** | — | — | — | 0 | — | — | — | 0 (96 app files M) | 0/0 | 2769/650 |
| AT-1d-3 | 10-05 | M | **2h28** | 1h17 | 1h37 | 1h10 | 1 | 0/0 | 1/5 | 0/0 | 0 | 1/0 | 5423/81 |
| AT-1d-2 | 10-04 | M | **4h16** | 2h00 | 2h30 | 2h16 | 1 | 0/1 | 0/5 | 0/0 | 0 | 1/0 | 4837/33 |
| AT-1d-1 | 10-04 | M | **5h14** | 3h54 | 1h28 | 1h19 | 1 | 0/0 | 4/8 | 0/2 | 0 | 1/1 | 6214/268 |
| AT-1c-3 | 10-04 | M | **3h05** | 1h01 | 2h15 | 2h04 | 1 | 0/0 | 0/5 | 0/0 | 0 | 1/0 | 5412/90 |
| AT-1c-2 | 10-03/04 | M | **9h50** | 7h57 | 2h12 | 1h52 | 2 | 0/0 | 0/6 | 0/1 | 0 | 1/0 | 6108/377 |
| AT-1c-1 | 10-03 | M | **4h18** | 2h28 | 2h06 | 1h49 | 1 | 0/0 | 0/7 | 0/0 | 0 | 1/0 | 5075/152 |
| AT-1b-3 | 10-03 | M | **3h06** | 1h12 | 2h12 | 1h53 | 1 | 0/0 | 1/3 | 0/1 | 0 | 1/0 | 4369/402 |
| AT-1b-2 | 09-30 | M | **3h17** | 1h25 | 2h12 | 1h51 | 1 | 0/0 | 0/4 | 0/0 | 0 | 1/0 | 4434/118 |
| AT-1b-1 | 09-29 | U | ≤4h18 | ≤2h06 | 2h32 | 2h11 | 1 | 0/1 | 0/8 | 1/0 | 3 | 2/0 | 6561/260 |
| AT-1a | 09-29 | U | unknown (≥5h56 from backup) | — | 5h56 | 5h24 | 2 | 0/1 | 15/2 | 0/1 | 0 | 1/0 | 13084/416 |
| HISTORY-1 | 09-28/29 | U | ≤4h03 (incl. grilling) | ≤3h03 | 1h31 | 1h00 | 1 | 1/18 | 20/3 | 2/2 | 1 | 2/0 | 7489/22 |
| LEAVE-BAL-1 | 09-28 | U | ≤3h46 | ≤2h55 | 1h11 | 0h50 | 1 | 0/2 | 0/6 | 0/1 | 0 | 1/0 | 2619/45 |
| OVERTIME-1 | 09-28 | D | **3h08** | 1h50 | 1h44 | 1h18 | 1 | 2/4 | 16/5 | 0/2 | 2 | 1/1 | 6028/90 |
| EMP-SELF-1 | 09-27 | D | **2h21** | 1h17 | 1h38 | 1h04 | 1 | 0/1 | 2/7 | 0/0 | 0 | 1/1 | 2640/65 |
| TERMS-EDIT-1 | 09-27 | D | **2h42** | 0h35 (?) | 2h29 | 2h07 | 1 | 0/0 | 1/2 | 0/0 | 1 | 1/0 | 3012/30 |
| APR-10 | 09-27 | D | **6h05** | 5h18 | 2h00 (45 min lost to backup timeout) | 0h46 | 1 | 1/10 | 12/12 | 0/3 | 0 | 1/44 | 7130/389 |
| APR-9 | 09-27 | D | **3h33** | 2h48 | 1h08 | 0h45 | 1 | 2/3 | 20/9 | 0/2 | 0 | 1/6 | 7579/165 |
| APR-8 | 09-26/27 | D | **2h44** | 1h43 | 1h32 | 1h00 | 1 | 1/11 | 21/3 | 0/2 | 0 | 1/19 | 6341/199 |
| APR-7 | 09-25/26 | D | **2h13** | 1h23 | 1h16 | 0h49 | 1 | 1/3 | 19/8 | 0/2 | 0 | 1/22 | 6827/525 |
| APR-6 | 09-25 | D | **2h28** | 1h27 | 1h28 | 1h01 | 1 | 1/3 | 9/6 | 0/2 | 0 | 1/8 | 5001/199 |
| APR-5b | 09-25 | D | **2h21** | 1h26 | 1h16 | 0h54 | 1 | 2/6 | 8/8 | 1/2 | 1 | 1/19 | 6666/548 |
| APR-5a (incl. APR-5 Step 0) | 09-25 | D | **4h34** | 3h37 | 1h34 | 0h56 | 1 | 1/3 | 10/7 | 0/2 | 0 | 1/11 | 5700/497 |
| ROLE-1 B3b | 09-25 | D | **1h35** | 1h02 | 0h43 | 0h32 | 1 | 0/6 | 1/13 | 0/1 | 0 | 1/16 | 4184/192 |
| ROLE-1 B3a (incl. B3 Step 0) | 09-25 | D | **1h17** | 0h53 | 0h32 | 0h23 | 1 | 1/4 | 5/14 | 0/1 | 0 | 1/6 | 4481/325 |
| ROLE-1 B4b | 09-25 | D | **2h20** | 1h56 | 0h35 | 0h24 | 1 | 1/3 | 11/9 | 0/2 | 0 | 1/12 | 5261/81 |
| ROLE-1 B4a (incl. B4 Step 0) | 09-25 | D | **1h08** | 0h44 | 0h39 | 0h24 | 1 | 0/3 | 1/14 | 0/17 | 0 | 1/18 | 3603/163 |
| PAYROLL-APR-1 | 09-24/25 | D | **1h50** | 1h11 | 1h04 | 0h39 | 1 | 1/3 | 10/11 | 0/2 | 0 | 1/14 | 5567/295 |
| ROLE-1 B2b | 09-24 | D | **2h23** | 1h51 | 1h47* | 0h31 | 1 | 0/18 | 3/7 | 0/0 | 0 | 1/11 | 3007/234 |
| ROLE-1 B2a | 09-24 | D | **1h36** | 1h07 | 0h47 | 0h28 | 1 | 1/10 | 10/3 | 0/1 | 0 | 1/23 | 4423/243 |
| CLAIM-GST-1 | 09-24 | D | **1h22** | 0h53 | 0h47 | 0h28 | 1 | 0/1 | 1/6 | 0/3 | 0 | 1/3 | 3689/98 |
| AP-RECON-1 B | 09-24 | D | **3h14** | 1h08 | 2h15 (40 min smoke hang) | 2h06 | 1 | 1/0 | 3/19 | 0/1 | 1 | 2/33 | 7808/425 |
| AP-RECON-1 A | 09-24 | U | ≤2h26 | ≤2h01 | 0h33 | 0h24 | 1 | 0/0 | 1/9 | 0/4 | 0 | 1/2 | 4390/38 |
| PAY-REQ-1 B | 09-23/24 | D | **1h40** | 1h07 | 0h57 | 0h33 | 1 | 0/2 | 8/6 | 0/1 | 0 | 1/2 | 3504/430 |
| PAY-REQ-1 A | 09-23 | D | **2h30** | 1h51 | 0h59 | 0h38 | 1 | 1/5 | 12/10 | 0/2 | 2 | 1/18 | 8234/1156 |
| ROLE-1 B1 | 09-23 | U | ≤3h15 | ≤2h45 | 0h42 | 0h29 | 1 | 0/12 | 6/23 | 0/1 | 0 | 1/9 | 5012/165 |
| INB-PAY-1 | 09-23 | D | **0h48** | 0h22 | 0h39 | 0h26 | 1 | 0/0 | 0/1 | 0/0 | 0 | 1/1 | 745/74 |

\* ROLE-1 B2b launched its backup at 20:52 but applied at 22:07 — work continued after the backup (offline gate re-run "after the screen changes", `ROLE-1.md:643`), so its backup→push is not a pure tail. TERMS-EDIT-1's 35 min start→apply is suspicious for 3,000 lines; the D start (APR-10 window's upper bound, `TERMS-EDIT-1.md:16-20`) may have been read after work began.

Session-start sources: U1-A `U1-A.md:9`; DATE-PICK-1 `DATE-PICK-1.md:5`; AT-1d-3 `AUDIT-TRAIL-1d-3.md:8`; AT-1d-2 `AUDIT-TRAIL-1d-2.md:5`; AT-1d-1 `AUDIT-TRAIL-1d-1.md:5-6`; AT-1c-3 `AUDIT-TRAIL-1c-3.md:6`; AT-1c-2 `AUDIT-TRAIL-1c-2.md:6`; AT-1c-1 `AUDIT-TRAIL-1c-1.md:6`; AT-1b-3 `AUDIT-TRAIL-1b-3.md:6`; AT-1b-2 `AUDIT-TRAIL-1b-2.md:17` (close-out session's first command 23:40:39). D-starts: window start (TSV) + the next cut's "at most" bound: `APR-10.md:21`, `TERMS-EDIT-1.md:20`, `EMP-SELF-1.md:21`, `OVERTIME-1.md:21`, `APR-9.md:20`, `APR-8.md:20`, `APR-7.md:22`, `APR-6.md:21`, `APR-5.md:23,154`, `ROLE-1.md:547,737,776,994,1219,1451`, `AP-RECON-1.md:266,588`, `PAY-REQ-1.md:20,232`, `INB-PAY-1.md:137-138`.

## 2 · Measured process-step durations

### 2.1 Full gate `db/gate.py` (script's own seconds)

| cut | s | source | note |
|---|---:|---|---|
| U1-A | 419 (wrapper wall 532) | `U1-A.md:144`; `~/u1a-work/logs/gate-wrap.log` | |
| DATE-PICK-1 | 366 | `DATE-PICK-1.md:251` | non-DB cut still ran it |
| AT-1d-3 | 731 | `AUDIT-TRAIL-1d-3.md:124` | |
| AT-1d-2 | 414 | `AUDIT-TRAIL-1d-2.md:125` | |
| AT-1d-1 | 341 | `AUDIT-TRAIL-1d-1.md:144` | |
| AT-1c-3 | 368 after a 1,500 s timeout (no verdict) | `AUDIT-TRAIL-1c-3.md:274,692` | 25 min lost |
| AT-1c-2 | 422 after a red run + fu1 migration | `AUDIT-TRAIL-1c-2.md:237-240` | |
| AT-1c-1 | 425 | `AUDIT-TRAIL-1c-1.md:73` | |
| AT-1b-3 | 445 | `AUDIT-TRAIL-1b-3.md:82` | |
| AT-1b-2 | 521 | `AUDIT-TRAIL-1b-2.md:80` | |
| AT-1b-1 | 461 | `AUDIT-TRAIL-1b-1.md:73` | |
| AT-1a | 611 | `AUDIT-TRAIL-1a.md:66` | |
| HISTORY-1 | 908 after an SSL-EOF crash | `HISTORY-1.md:68` | |
| LEAVE-BAL-1 | 502 | `LEAVE-BAL-1.md:82` | |
| OVERTIME-1 | 496 | `OVERTIME-1.md:134` | |
| EMP-SELF-1 | 522 | `EMP-SELF-1.md:114` | |
| TERMS-EDIT-1 | 340 after a red run (currency literal) | `TERMS-EDIT-1.md:126` | |
| APR-10 | 335 | `APR-10.md:118` | |
| APR-9 | 296 | `APR-9.md:113` | |
| APR-8 | 378 | `APR-8.md:105` | |
| APR-7 | 480 | `APR-7.md:96` | |
| APR-6 | 499 | `APR-6.md:106` | |
| APR-5a | 414 after an SSL-EOF crash | `APR-5.md:97` | |
| APR-5b | 431 | `APR-5.md:256` | |
| ROLE-1 B2a / B2b / B4a / B4b / B3a / B3b | 516 / 513 / 496 / 428 / 431 / 434 | `ROLE-1.md:415,653,884,1102,1335,1560` | |
| PAYROLL-APR-1 | 733 | `PAYROLL-APR-1.md:114` | |
| CLAIM-GST-1 | 500 | `CLAIM-GST-1.md:145` | |
| AP-RECON-1 A / B | 402 / 369 | `AP-RECON-1.md:214,536` | |
| PAY-REQ-1 A / B | 695 / 671 | `PAY-REQ-1.md:124,333` | |
| INB-PAY-1 | 494 | `INB-PAY-1.md:107` | |

**n = 37, range 296–908 s, median 445 s (7.4 min).** Script figure excludes wrapper overhead (U1-A: 419 s verdicts vs 532 s wall).
Gate network/timeout failures needing a rerun: HISTORY-1, APR-5a, AT-1c-3 (3 of 37). Red verdicts needing a fix + rerun: AT-1c-2, TERMS-EDIT-1 (2 of 37).

### 2.2 Offline gate `db/gate.py --offline` (per run)

AT-1d-3 67 s (`:118`) · AT-1d-2 71 s (`:119`) · AT-1d-1 72 s (`:138`) · AT-1c-3 67 s (`:268`) · AT-1c-2 66 s (`:214`) · AT-1b-3 66 s (`:75`) · AT-1b-2 64 s (`:73`) · AT-1b-1 68 s (`:66`) · AT-1a 62 s (`:59`) · HISTORY-1 61 s (`:61`) · LEAVE-BAL-1 58 s (`:76`) · OVERTIME-1 58 s (`:125`) · EMP-SELF-1 54/60 s (`:106`) · TERMS-EDIT-1 60 s (`:119`) · APR-9 54 s (`:106`) · APR-8 53 s (`:98`) · APR-7 53 s (`:88`) · APR-6 52 s (`:99`) · PAYROLL-APR-1 51 s (`:107`) · U1-A 74 s (`~/u1a-work/logs/gate-off4.log`, "wall-clock 74s").
**Range 51–74 s; October cuts 66–74 s.** Red offline runs are common and cheap: U1-A 4 runs (3 red), AT-1c-1 **11 runs** (`AUDIT-TRAIL-1c-1.md:67`), APR-5b 5 runs (`APR-5.md:248`), APR-10 4+ (`APR-10.md:111`), PAY-REQ-1A 4 (`PAY-REQ-1.md:117`), ROLE-1 B2a/B2b 3 each. The fix time between red runs is work, not floor.

### 2.3 Backup (start = filename, end = file mtime or hand-back line)

| cut | start → end | min | source |
|---|---|---:|---|
| U1-A | 16:23 → 16:36:06 | 13 | mtime; `U1-A.md:139` |
| AT-1d-3 | 00:47 → 01:12:22 | 25 | mtime; `AUDIT-TRAIL-1d-3.md:119` |
| AT-1d-2 | 18:46 → 18:57:53 | 12 | mtime; `AUDIT-TRAIL-1d-2.md:120` |
| AT-1d-1 | 15:27 → 15:33:06 | 6 | mtime; `AUDIT-TRAIL-1d-1.md:139` |
| AT-1c-3 | 08:28:15 → 08:37:28 | 9 | mtime; `AUDIT-TRAIL-1c-3.md:269` |
| AT-1c-2 | (fail) retry 00:58:46 → 01:15:46 | 17 (+ failed attempt) | `AUDIT-TRAIL-1c-2.md:217-218` |
| AT-1c-1 | 15:10 → 15:24:46 | 14 (842 s) | `AUDIT-TRAIL-1c-1.md:68` |
| AT-1b-3 | 10:12 → 10:28:18 | 16 | mtime; `AUDIT-TRAIL-1b-3.md:77` |
| AT-1b-2 | 00:45 → 01:03:27 | 18 | mtime; `AUDIT-TRAIL-1b-2.md:75` |
| AT-1b-1 | 20:54 → 21:11:58 | 18 | mtime; `AUDIT-TRAIL-1b-1.md:68` |
| AT-1a | 12:59 → 13:26:40 | 28 | mtime; `AUDIT-TRAIL-1a.md:61` |
| HISTORY-1 | (fail) retry 23:29 → 23:55:05 | 26 (+ failed attempt) | mtime; `HISTORY-1.md:63` |
| LEAVE-BAL-1 | 18:14 → 18:32:16 | 18 | mtime |
| OVERTIME-1 | 12:57 → 13:18 | 21 | `OVERTIME-1.md:129` |
| EMP-SELF-1 | 21:05 → 21:33 | 28 | `EMP-SELF-1.md:108` |
| TERMS-EDIT-1 | 17:40 → 17:58 | 18 | `TERMS-EDIT-1.md:120` |
| APR-10 | timed out at 2,700 s, retry 16:06 → ? | 45 lost + retry | `APR-10.md:113` |
| APR-9 | 09:57 → 10:16 | 19 | `APR-9.md:108` |
| APR-8 | 22:59 → 23:25 | 26 | `APR-8.md:100` |
| APR-7 | 00:28 → 00:50 | 22 | `APR-7.md:91` |
| APR-6 | 21:57 → 22:20 | 23 | `APR-6.md:101` |
| CLAIM-GST-1 | 14:47 → 15:05 | 18 | `CLAIM-GST-1.md:139` |
| AP-RECON-1 A / B | 10:12 → 10:20 / 11:51 → 11:59 | 8 / 8 | `AP-RECON-1.md:209,530` |

**n = 23 with both ends: range 6–28 min, median 18 min.** 3 incidents (HISTORY-1, AT-1c-2 network failures; APR-10 timeout = 45 min lost).

### 2.4 Migration dry run + apply

AT-1c-3: apply 08:38:12 → 08:39:15 (1 min) (`:270`) · AT-1c-1: 15:25:31 → 15:26:50 (`:69`) · AT-1c-2: 01:16:57 → 01:18:22; fu1 01:29:53 → 01:31:04 (`:224,239`) · AT-1b-2 dry run 17 s (`:74`) · AT-1b-1 dry run 2 min 13 s (`:67`) · HISTORY-1 dry runs 626 s then 199 s, apply 162 s (`HISTORY-1.md:62,160`) · AT-1a: grants replay made the dry run 185 s, `CREATE INDEX CONCURRENTLY` 9.7 s (`AUDIT-TRAIL-1a.md:184-186`) · U1-A: 3 attempts 16:36:38 / 16:37:31 / committed 16:40:23 (`U1-A.md:140`). **Typical 1–4 min including the dry run; up to ~15 min for a 500-trigger migration.**

### 2.5 Route smoke

| cut | route-time total / wall | runs | source |
|---|---|:-:|---|
| U1-A | 828.7 s routes / **1,073 s wall** | 1 | `logs/smoke.log`, `logs/smoke-wrap.log` |
| DATE-PICK-1 | — | 2 (network fail, rerun) | `DATE-PICK-1.md:255` |
| AT-1d-1 | — | 2 (own defect) | `AUDIT-TRAIL-1d-1.md:148` |
| AT-1b-3 | **1,264 s wall** (10:55 → 11:16) | 1 | `AUDIT-TRAIL-1b-3.md:86` |
| AT-1b-1 | — | 2 (503, rerun) | `AUDIT-TRAIL-1b-1.md:77-79` |
| AT-1a | — | 2 (500 + network) | `AUDIT-TRAIL-1a.md:70` |
| HISTORY-1 | 1,212.1 s | 1 | `HISTORY-1.md:71` |
| LEAVE-BAL-1 | 1,303.0 s | 1 | `LEAVE-BAL-1.md:85` |
| OVERTIME-1 | 1,491.9 s | 1 | `OVERTIME-1.md:137` |
| EMP-SELF-1 | 1,679.3 s | 2 | `EMP-SELF-1.md:117-118` |
| TERMS-EDIT-1 | 1,175.4 s | 2 | `TERMS-EDIT-1.md:130-131` |
| APR-10 | 1,274.9 s | 1 | `APR-10.md:121` |
| APR-7 | wall 01:10 → 01:41 (31 min) | 1 | `APR-7.md:99` |
| APR-6 | wall 22:41 → 23:16 (35 min) | 1 | `APR-6.md:109` |
| ROLE-1 B2a | 686.6 s; wall 19:50 → ~20:04 | 1 | `ROLE-1.md:418` |
| ROLE-1 B2b | 777.8 s | 1 | `ROLE-1.md:654` |
| ROLE-1 B4a | 505.5 s; wall 02:09:50 → 02:20:38 | 1 | `ROLE-1.md:887` |
| ROLE-1 B4b | 509.2 s | 1 | `ROLE-1.md:1105` |
| ROLE-1 B3a | 500.6 s; wall 11:41:07 → 11:51:57 | 1 | `ROLE-1.md:1338` |
| ROLE-1 B1 | — | 2 | `ROLE-1.md:102-103` |
| PAYROLL-APR-1 | 813.6 s | 1 | `PAYROLL-APR-1.md:117` |
| CLAIM-GST-1 | 671.7 s; wall 15:19 → 15:33 | 1 | `CLAIM-GST-1.md:146` |
| AP-RECON-1 A | 590.8 s | 1 | `AP-RECON-1.md:215` |
| AP-RECON-1 B | 557.4 s, then **hung to the 2,400 s bound** | 1 | `AP-RECON-1.md:537` |
| PAY-REQ-1 A | 903.2 s | 1 | `PAY-REQ-1.md:127` |

**Wall: 11–14 min on 09-23..25; 20–35 min on 09-25..28 (dev-server compile slow); 18–21 min in October.** Reruns in 8 of ~38 cuts (+ one 40-min hang).

### 2.6 Layout survey and cut probes (from U1-A log mtimes, measured; per-route rate inferred)

- `survey-phone` 390 px, 15 routes: **220 s** (`logs/survey390-wrap.log`); 1280 px, 18 routes: ~266 s (17:01:08 → 17:05:34); 390 px, 3 routes: ~141 s (17:05:40 → 17:08:01). ⇒ **~90–100 s fixed + ~8–10 s per route** (inferred). Whole survey block in U1-A: 16:56 → 17:08 = **12 min**.
- U1-A page probe (107 checks): 18:43:34 → 18:47:43 = **4 min**; three probe fault-injection runs 18:47 → 19:01 = **14 min**; DATE-PICK-1's probe needed 4 attempts (`DATE-PICK-1.md:256`).
- Before/after live readings: seconds each (U1-A 16:18:10–16:18:16; 19:01:48–19:01:53); the anonymisation proof 6 s (`U1-A.md:223`).
- types/tsc/build ×3 including two fixes: 16:40:37 → 16:45:10 (4.5 min; `logs/types.log` → `build3.log`). No hand-back states a build time.

### 2.7 U1-A minute-by-minute (all from `~/u1a-work/logs/*` mtimes, measured)

| clock | step | elapsed | floor or work |
|---|---|---|---|
| 15:26:55 → 15:55 | drafting (migration, mirrors, fixture 247, pages) | 28 min | work |
| 15:55 → 16:23 | offline gate ×4 (3 red) + fixes, fixture injections, trail goldens, before-readings 16:18 | 28 min | ~5 min floor / ~23 min work |
| 16:23 → 16:36 | backup (serial wait) | 13 min | floor |
| 16:36 → 16:40 | apply ×3 (2 rolled back) | 4 min | floor (+ a miscount) |
| 16:40 → 16:45 | types, tsc, build ×3 | 5 min | floor |
| 16:45 → 16:48 | i18n/swallow/injection rerun | 3 min | floor |
| 16:48 → 16:56 | full gate (419 s / 532 s wall) | 9 min | floor |
| 16:56 → 17:08 | survey 390 / 1280 / 390b | 12 min | floor |
| 17:08 → 17:26 | smoke | 18 min | floor |
| 17:28 → 18:43 | (no logs) — writing `probe-u1a.mjs` and, inferred, the hand-back | 75 min | work + hand-back |
| 18:43 → 19:01 | probe + 3 probe injections | 18 min | floor |
| 19:01 → 19:06:19 | proof, after-readings, build5, commit, push | 5 min | floor |

**Machine floor ≈ 1 h 28 min; work + hand-back ≈ 2 h 11 min; total 3 h 39 min.**

## 3 · Broken windows (apply → push = measured lower bound; upper bounds from the next cut's §W)

U1-A ≥2h25m56 (end pending) · AT-1d-3 1h10m13 – 7h57m31 (`DATE-PICK-1.md:23`) · AT-1d-2 2h16m18 – 4h56m34 (`AUDIT-TRAIL-1d-3.md:27`) · AT-1d-1 1h19m18 – 1h23m38 (`AUDIT-TRAIL-1d-2.md:27`) · AT-1c-3 2h04m13 – 2h11m05 (`AUDIT-TRAIL-1c-3.md:710`) · AT-1c-2 1h52m42 – 6h19m52 (`AUDIT-TRAIL-1c-3.md:28`) · AT-1c-1 1h49m44 – 1h53m34 (`AUDIT-TRAIL-1c-2.md:26`) · AT-1b-3 1h53m09 – … · AT-1b-2 1h51m13 – 80h11m (`AUDIT-TRAIL-1b-3.md:19`) · AT-1b-1 2h11m50 – 2h25m34 (`AUDIT-TRAIL-1b-2.md:18`) · AT-1a 5h24m23 · HISTORY-1 1h00m08 · LEAVE-BAL-1 0h50m49 · OVERTIME-1 1h18m51 · EMP-SELF-1 1h04m34 – 13h53m58 (`OVERTIME-1.md:21`) · TERMS-EDIT-1 2h07m18 – 2h19m15 (`EMP-SELF-1.md:21`) · APR-10 46m23 – 52m01 (`TERMS-EDIT-1.md:20`) · APR-9 45m35 – 55m36 (`APR-10.md:21`) · APR-8 1h00m25 – 8h01m09 (`APR-9.md:20`) · APR-7 49m51 – 20h52m52 (`APR-8.md:20`) · APR-6 1h01m19 – 1h07m22 (`APR-7.md:22`) · APR-5b 54m55 – 1h03m46 (`APR-6.md:21`) · APR-5a 56m41 – 1h04m02 (`APR-5.md:154`) · ROLE-1 B3b 32m25 – 43m49 (`APR-5.md:23`) · B3a 23m58 – 27m12 (`ROLE-1.md:1453`) · B4b 24m28 – 1h03m46 (`:1221`) · B4a 24m40 – 5h39m27 (`:996`) · PAYROLL-APR-1 39m17 – 61m40 (`:778`) · B2b 31m37 – 53m21 (`PAYROLL-APR-1.md:19`) · B2a 28m28 – … (`ROLE-1.md:547`) · CLAIM-GST-1 28m14 – 3h22m59 (`ROLE-1.md:312`) · AP-RECON-1B 2h06m06 – 2h12m29 (`AP-RECON-1.md:588`) · AP-RECON-1A 24m27 – 30m05 (`:266`) · PAY-REQ-1B 33m36 – 8h06m35 (`PAY-REQ-1.md:393`) · PAY-REQ-1A 38m50 – 44m23 (`:232`) · ROLE-1 B1 29m54 – 39m16 (`:20`) · INB-PAY-1 26m34 – 31m33 (`INB-PAY-1.md:9`).

The lower bound tracks how much verification runs *after* apply: ~25–40 min (Sept 23–25), ~45–65 min (Sept 25–29), ~1h10–2h25 (Sept 29 – Oct 5, surveys + page probes + live readings inside the window).

## 4 · Derived calibration

### 4.1 Total span of a DB-touching cut (session start → push)

M + D starts only, n = 31: **range 0h48 – 9h50, median 2h30, IQR 1h50 – 3h33.**
October regime (AT-1b-2 … U1-A, all M, n = 9): 2h28 · 3h05 · 3h06 · 3h17 · **3h39** · 4h16 · 4h18 · 5h14 · 9h50 → **median 3h39**.

### 4.2 Process floor (the fixed machinery), three regimes

Proxy = backup start → push (backup + apply + build + gate + survey/probe + smoke + readings + commit/push + the hand-back written during the waits).

| regime | cuts | backup→push median (range) | apply→push median | what is in it |
|---|---|---|---|---|
| A · 09-23 → 09-25 | INB-PAY-1, ROLE-1 B1–B3b, PAY-REQ-1, AP-RECON-1, CLAIM-GST-1, PAYROLL-APR-1 (n = 14) | **45 min** (32 – 64; outliers 1h47, 2h15) | 28.5 min | backup ~8–18 · gate ~7–8 · smoke ~10–14 · live proof · short hand-back |
| B · 09-25 → 09-28 | APR-5a … APR-10, TERMS-EDIT-1, EMP-SELF-1, OVERTIME-1, LEAVE-BAL-1, HISTORY-1 (n = 12) | **1h32** (1h08 – 2h29) | 58 min | backup ~18–28 · gate ~5–9 · smoke 20–35 (slow dev compile) · reruns |
| C · 09-29 → 10-05 | AT-1a … AT-1d-3, U1-A (n = 10, excl. AT-1a) | **2h12** raw (1h28 – 2h32) | 1h53 | + layout survey (~12) · page probe + injections (~15–20) · before/after live digests · 400–1,000-line hand-backs |

**Clean-run floor today (regime C, no reruns): ~1h30** — measured in AT-1d-1 (1h28 backup→push), AT-1d-3 (1h37 from before-readings 00:47:50 to push; `AUDIT-TRAIL-1d-3.md:158`), U1-A (1h28 machine time, §2.7).
**Floor with one rerun / incident: ~2h10 – 2h30** (AT-1b/1c medians). Smallest whole DB cut ever measured: **INB-PAY-1, 48 min** (one function, regime A) — that is the floor-only data point for the older, lighter procedure.
**Incident tax:** 12 of 37 DB cuts needed a process retry — 8 infrastructure (backup fail/timeout: HISTORY-1, AT-1c-2, APR-10; gate crash/timeout: APR-5a, AT-1c-3, HISTORY-1; smoke network/hang: AT-1b-1, AT-1a, AP-RECON-1B) and 4 caused by the cut's own smoke needle/setup (AT-1d-1, EMP-SELF-1, TERMS-EDIT-1, ROLE-1 B1) — each costing **10–45 min**. Expected value ≈ +10–15 min per cut.

These line up with UNBLOCK-1's own floor estimate of 1h30 – 2h15 (`docs/surveys/UNBLOCK-1/STEP0-HANDBACK.md:627-638`).

### 4.3 Work rate (inferred: work ≈ span − regime floor; noisy, ±50%)

| cut | new tables / new pages / new fns | span | work ≈ |
|---|---|---|---|
| INB-PAY-1 | 0 / 0 / 0 (1 fn M) | 0h48 | ~0 |
| ROLE-1 B4a | 0 / 0 / 1 (14 M, 17 views M) | 1h08 | ~20 min |
| CLAIM-GST-1 | 0 / 0 / 1 (6 M) | 1h22 | ~30 min |
| ROLE-1 B3a | 1 / 0 / 5 | 1h17 | ~30 min |
| ROLE-1 B2a | 1 / 0 / 10 | 1h36 | ~45 min |
| PAYROLL-APR-1 | 1 / 0 / 10 | 1h50 | ~60 min |
| APR-6 | 1 / 0 / 9 | 2h28 | ~50 min |
| APR-7 | 1 / 0 / 19 | 2h13 | ~35 min |
| APR-8 | 1 / 0 / 21 | 2h44 | ~65 min |
| ROLE-1 B4b | 1 / 0 / 11 | 2h20 | ~90 min |
| APR-9 | 2 / 0 / 20 | 3h33 | ~2h |
| APR-5b | 2 / 1 / 8 | 2h21 | ~45 min |
| PAY-REQ-1A | 1 / 2 / 12 | 2h30 | ~1h40 |
| AP-RECON-1B | 1 / 1 / 3 | 3h14 | ~1h45 (excl. 40-min smoke hang) |
| OVERTIME-1 | 2 / 2 / 16 | 3h08 | ~1h30 |
| TERMS-EDIT-1 | 0 / 1 / 1 | 2h42 | ~1h05 (incl. reruns) |
| HISTORY-1 | 1 / 1 / 20 (+476 triggers) | ≤4h03 | ≤2h30 |
| U1-A | 0 / 0 (19 routes changed) / 5 (11 fns M, 12 views) | 3h39 | ~2h10 |
| AT-1d-3 / 1b-3 / 1c-3 / 1b-2 (trail registrations) | 0 / 0 | 2h28 – 3h17 | ~1h – 1h45 |
| AT-1c-2 (8 subjects, 36 tables catalogued, red gate + fu1) | 0 / 0 | 9h50 | ~7h30 |

**Rough rates (inferred):**
- a new table with its lifecycle functions (~10), mirrors and one fixture: **~45–60 min of work** (median of 7 one-table cuts ≈ 50 min; range 30–90);
- each new page on top: **~25–45 min**;
- so a "new table + new page" unit ≈ **1h15 – 1h45 work**, and a cut adding one of each ≈ **1h30 floor + 1h30 work ≈ 3h** today (OVERTIME-1 did 2+2 in 3h08 under the lighter regime B floor);
- a modify-many cut (visibility or trail changes across 10–20 routes, no new tables): **~1–2h work per ~10 routes/readers** (U1-A ~2h10 for ~19 routes and 5 tables' policies; AT-1d-* 1–3h45);
- a breadth UI cut with no DB (DATE-PICK-1, 96 app files, 92-route survey): **5h36 total**.
- Step 0 / grilling inside a cut adds 1–2h (APR-5a 4h34, APR-10 6h05 both carried Step 0); when a separate Step 0 survey already wrote the design down to file:line (U1-A), work came in **at roughly half** of the comparable cuts.

## 5 · U1-A: how the previous survey estimated it vs what it took

- Estimate (`docs/surveys/UNBLOCK-1/STEP0-HANDBACK.md` §8, lines 619-650): floor **1h30 – 2h15** + work **4h – 6h** = **5h30 – 8h15**; analogues named AT-1d-1 (5h14) and AT-1c-1 (4h18); upper bound assumed one red-gate round.
  (Note: the brief's "§6 (cut plan)" is §7 "Proposed order and split", lines 595-617; §6 is the trail/change-log interaction.)
- Actual: opening **15:26:55** (`docs/handbacks/U1-A.md:9`) → push **19:06:19** (reflog) = **3h39m24s**. Commit `d625c4b5` 19:06:14, close-out `c062ff3a` pushed 19:09:18.
- Split (§2.7): floor ≈ **1h28** (inside the estimated floor, at its low end) · work + hand-back ≈ **2h11** (vs 4–6h estimated).
- **Actual / estimate = 0.44 – 0.66; 1h51m under the low bound.** The floor estimate was right; the work estimate was ~2–2.7× too high. U1-A still had 3 red offline gates, 2 rolled-back apply attempts and 3 builds — offline reds cost ~1 min each plus the fix, so "one red round" in a pre-apply phase is cheap; only full-gate reds (7–12 min + in-window) and infra incidents are expensive.
- Likely cause (inferred): the analogues were trail-catalogue cuts with large per-subject wording work; U1-A's mechanism and every reader had been pinned to file:line in Step 0 §3/§6, so building was mostly transcription.
- Broken window: start 16:40:23 (`U1-A.md:241`), ≥ 2h25m56 to push — longer than usual because the probe was written and the live verification ran inside it (`U1-A.md:248`).

## 6 · AGENTS.md tool costs — re-verified

| AGENTS.md says | newer measurement | source |
|---|---|---|
| full gate 310 s (2026-09-05, 193 fixtures; `AGENTS.md:112`) | **296 – 908 s, median 445 s**, n = 37 (fixtures now ~247); wrapper wall ≈ +25% (U1-A 419 → 532 s) | §2.1 |
| `--offline` 44 s (`AGENTS.md:113`) | **51 – 74 s; October 66 – 74 s** | §2.2 |
| build ~22 s (`AGENTS.md:2091`) | not restated in any hand-back; U1-A types+tsc+3 builds with fixes = 4.5 min | §2.6 |
| survey-phone 102 s single route (`AGENTS.md:2110`) | consistent: 3 routes 141 s, 15 routes 220 s, 18 routes ~266 s → ~95 s fixed + ~9 s/route | §2.6 |
| probe-avatar 33 s (`AGENTS.md:2111`) | not rerun; cut probes now 4 min (U1-A, 107 checks) + ~4.5 min per injection | §2.6 |
| smoke 765 s (`AGENTS.md:528`) | route totals 500 – 1,679 s; wall **11 – 35 min**, October ~18 – 21 min; reruns in 8 of ~38 | §2.5 |
| backup ~10 min (`AGENTS.md:1827`) | **6 – 28 min, median 18 min** (n = 23); 3 incidents incl. one 45-min timeout | §2.3 |

## 7 · Caveats

- "D" starts are clock readings taken by the session (first live read / first command) and can lag the true start by a few minutes; "U" rows are upper bounds and include Tim's review gaps.
- Spans of cuts that carried a Step 0 / grilling inside the session (APR-5a, APR-10, ROLE-1 B3a/B4a, HISTORY-1) include waiting for Tim's answers.
- Hand-back writing is never timed separately; it happens during waits (backup/gate/smoke) and in un-logged gaps (U1-A 17:28 → 18:43). It is counted inside "floor" here except where noted.
- Only U1-A kept a work-log directory (`~/u1a-work/logs`); every other per-step clock comes from the hand-back text or backup-file mtimes.
