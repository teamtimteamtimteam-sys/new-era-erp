v1.4.76 — Saved views on the 28 list pages that filter (per person, one optional default per list, a quick range saved by name and recalculated on opening); bulk approve / reject on the five request panels and bulk reject on the expense-claim queue and the weighbridge drafts, one item at a time through the single-click action with a result list per item; leave and medical-claim rejects need a reason, refused by name in the database.

# TABLE-FEATURES-3 — hand-back (2026-10-26)

Brief: "TABLE-FEATURES-3" (Step 0, 2026-10-26) and Tim's rulings Q1–Q4 of 2026-10-26, recorded verbatim at `docs/table-features.md` § "The rulings — Tim 2026-10-26 (TABLE-FEATURES-3 Step 0)" and queue entry 64c-3.
Started from `f5a62e79f60c37ffdb5228df804032d31f824ff3` (HEAD = origin/main = ls-remote, tree clean). Step 0: `docs/surveys/TABLE-FEATURES-3/step0.md`; readings: `docs/surveys/TABLE-FEATURES-3/readings/`.

## 0 · Part 1 — TF-2 close-out
- **Broken window of TF-2 closed 2026-10-26 18:49 CST** (Tim's confirmation; 15:24:40 → 18:49 = 3 h 24 m 20 s) — recorded in `docs/handbacks/TABLE-FEATURES-2.md` §9.
- **Live-safety audit (read-only, postgres on base tables)** — `readings/tf2-live-safety-audit.txt`. The sub-agents' live calls (14:32:28–14:47:00 CST) all **precede** TF-2's backup (14:53:53),
  so live was compared with that backup **and** with the 2026-10-23 backup: `role_permissions` and every table the sub-agents wrote to are identical row by row; the one live
  difference (`cod_verification_failures`, during the TF-2 smoke) is outside that set; every row that changed between the two backups is stamped 2026-10-23; change_log byte-identical.
  The TF-2 hand-back's §6 omitted two statements (an `UPDATE` on a `freight_documents` row; deletion of the `data.view_pay` grants) — both rolled back, both shown by the audit to have left nothing.
- **Production check** `TF2_CLOSEOUT_EXIT=0` 4/4 (run 1 was a probe fault: an October filter with 0 invoices draws no footer). Read back 0 throwaways.
- SUB-AGENTS rule in AGENTS.md; TF-2 closed in queue 64c-2. **No sub-agent was started in this cut.**

## 1 · Against each scope item and ruling

| Item | Result |
|---|---|
| A · saved views (2026-10-25 Q3; 2026-10-26 Q1) | `saved_views` table (own rows only, one default per person per list, anon nothing, not change-logged); `<SavedViewsBar>` + `loadSavedViews` on the **28** filter pages; 19 browser-sorted tables on the 8 browser-sorted pages write `<prefix>sort/dir` into the address. Q1's "29" was my Step 0 counting fault — see §5. |
| Q2 · presets in views | a view whose dates equal a quick range stores `date_preset=<name>` and opens on today's range (live proof V: stored `status=unpaid&date_preset=thisMonth`, reopened as 2026-10-01…2026-10-31); hand-typed dates stay. |
| Q3 · default view | redirect only when the address is empty (`loadSavedViews`), "Plain list" = `?view=plain`; a link with its own parameters is never overridden. Edge registered: SAVED-VIEW-DEFAULT-RETURNS-WHEN-LAST-FILTER-CLEARED. |
| B · bulk actions (2026-10-25 Q2) | journal · warehouse · asset disposal · terms (on `/contracts` and `/tools/pricing/formulas` only) approve + reject; expense-claim queue and weighbridge drafts reject only; one reason for the batch; one item at a time through the single-click action; result list per item; select-all = rows on screen. No bulk withdraw / export. |
| Q4 · proof | live, one rolled-back transaction: approver given the real `cfo` role as a NEW `user_roles` row (removed by the rollback); 3 journal requests → 2 approved, the approver's own refused `SELF_APPROVAL_FORBIDDEN`. Read back: 0 throwaways; 0 active `cfo` grants but the real holder. Local result-list test `BULK_RUN_EXIT=0` 6/6. Browser on live: bulk bar + select-all shown, nothing pressed. |
| C · reject reasons (2026-10-25 Q11) | `LEAVE_REJECT_REASON_REQUIRED\|<code>` / `MEDICAL_CLAIM_REJECT_REASON_REQUIRED\|<code>` raised by the decide functions on a blank reason; server actions refuse blank first; Reject on `/hr/leave/[id]` and `/hr/claims/[id]` asks for a reason. Fixture 293; live proof L/M. |
| Grilling changes (accepted) | checkbox per card on the card lists; no bulk on `/contracts/[id]` or the formula edit page; leave rule in the function, not a table constraint (live has one old rejected leave with a blank note). |
| Record | TF-2 audit result and the two omitted breaches recorded in `docs/handbacks/TABLE-FEATURES-2.md` §9 and AGENTS.md (SUB-AGENTS). |

## 2 · Verify chain (in order)

| # | Step | Reading |
|---|---|---|
| 1 | offline gate | **`GATE_EXIT=0`** (142 s; `gate-offline.txt`). An earlier offline run on unfinished code (`gate-offline-early.txt`, `GATE_EXIT=4`) caught 19 fixtures pinning the change-log exclusion count at 9 and one wrong case in my fixture 293 — both fixed before this run. |
| 2 | backup | **`BACKUP_EXIT=0`** (19:51:20 → ≈20:17 CST; `evoltrya-backup-2026-10-26-1951.dump` + 19 change_log chunks, 86,090 rows = count). |
| 3 | live dry run | **`DRY_OWN_EXIT=0`**: table, 4 policies, anon none, authenticated no TRUNCATE, 10 exclusions, both reason checks present → ROLLBACK; afterwards nothing on live (`dry-run.txt`). |
| 4 | apply | **`APPLY_OWN_EXIT=0`**, preflight 3 replaced / 0 new functions; **window start 2026-10-26 20:21:50 CST** (`apply.txt`, `db/migration-windows.tsv`). In the window the old app meets a blank leave / medical reject refused under a code it has no message for. |
| 5 | types | **`TYPES_OWN_EXIT=0`** (DO_NOT_TRACK=1), +41 lines. |
| 6 | tsc | **`TSC_OWN_EXIT=0`**. |
| 7 | build | run 1 `BUILD_OWN_EXIT=1` (eslint gate: an unused constant in my proof script; `build-run1-lint.txt`); run 2 **`BUILD_OWN_EXIT=0`**. |
| 8 | full gate | **`GATE_EXIT=0`** (766 s; every verdict ✓, mirrors = live; `gate-full.txt`). Re-run on the final tree: §2b. |
| 9 | i18n · swallowing | **`I18N_OWN_EXIT=0`** · **`SWALLOW_OWN_EXIT=0`**. |
| 10 | layout survey | 35 routes = the 28 saved-view pages + `/inventory` `/contracts` `/tools/pricing/formulas` `/finance/claims` `/operation/capture` + `/hr/leave/[id]` `/hr/claims/[id]`: **390 px 35/35 at 0 overflow, 0 clipped; 1280 px 35/35 at 0 / 0** (`layout-390.txt`, `layout-1280.txt`, JSON beside them). **Not on screen:** no open journal / warehouse / terms / disposal request and no capture draft exists on live, so those bulk bars draw nothing there; the leave / claim detail pages measured decided records (no Reject button). |
| 11 | smoke | **`SMOKE_EXIT=0`**: 337 routes + probes, 25 skipped (no data), 0 failed (20:52 → 21:42; `smoke.txt`). It reported 6 stale `ZZ-SMOKE-*` rows from earlier cuts (report-only; untouched). |
| 12 | live proof | build `BUILD_OWN_EXIT=0`; run 1 driver fault (prefix `tf3probe` not registered in `scripts/ephemeral.mjs` — nothing created; `live-proof-run1-driver.txt`); run 2 **probe fault** (my result lines split on `|` and the refusal itself is `CODE|<code>` — the database answers were right; `live-proof-run2-probe-fault.txt`); run 3 **`TF3_PROOF_EXIT=0`, 12/12** (`live-proof.txt`, §3). Read back `readback-proof.txt`. |
| 13 | COD bytes | **`COD_OWN_EXIT=0`**: both equal the AGENTS.md baseline (34,701 `ba299a4f…f42101` · 34,746 `717661f6…13a4f9`). |
| 14 | fresh clone, no `.env.local` | §2b. |

### 2b · Full gate re-run and fresh clone on the final tree
On commit `7fe65ad37a5ecd97850bc6f3f1bb3804e6f9cb71` (everything but this subsection and the three logs it names): **`GATE_EXIT=0`** (854 s, every verdict ✓; `gate-full-final.txt`).
Fresh clone of that commit, no `.env.local`, `npm ci && npm run build`: run 1 `FRESH_OWN_EXIT=1` — every static check green, `next build` could not fetch Geist / Google Sans from
Google Fonts (`fresh-clone-build-run1-fonts.txt`; a cold clone has no font cache); fonts.googleapis.com answered 200 a moment later; one immediate retry **`FRESH_OWN_EXIT=0`** (`fresh-clone-build.txt`).
The only change after that gate is this docs commit (this subsection + the three logs) — no code, mirror or fixture; stated, as TF-2 did.

## 3 · Live proof (`next start` on this tree against live; one transaction ending in ROLLBACK; throwaways `tf3probe` via the shared helper)
- **V** saved view: stored `status=unpaid&date_preset=thisMonth` (from `?status=unpaid&date_from=2026-10-01&date_to=2026-10-31&page=2`), set as default, read back as its owner;
  reopened → `/finance/expenses?status=unpaid&date_from=2026-10-01&date_to=2026-10-31` = SG this month by independent arithmetic; another throwaway reads 0 views.
- **B** (Q4) approver a real `cfo` holder inside the transaction (1); manual journal #1, #2 raised by another → approved (entries posted inside the transaction); #3 raised by the approver → `SELF_APPROVAL_FORBIDDEN`, still submitted.
- **L / M** leave and medical-claim reject with NULL / '' / '   ' → `LEAVE_REJECT_REASON_REQUIRED|TF3PROOF-LV` / `MEDICAL_CLAIM_REJECT_REASON_REQUIRED|TF3PROOF-MC`, documents unchanged; with a reason both reject.
- **Browser, nothing pressed:** `/finance/claims` bulk bar + select-all + 1 card checkbox, "Reject selected (0)", no result list; `/finance/expenses` views bar with "Plain list" and "Save view", no redirect.
- **Read back** (postgres, counts only): 7 users / 7 enabled; 0 throwaway users / roles / orphan grants; **0 active `cfo` grants to anyone but the real holder** (1 real, 2 rows in all — the other is admin@'s revoked row); role codes admin · cco · cfo · cto · finance · gm · warehouse;
  approvals ON finance/cfo/1000; require_calibrated_since NULL; 2 CODs; reconciliation AP and AR 0.00 unexplained; 0 saved views, 0 journal requests, 0 TF3 rows left.
  Not touched: the portal access-token hook, `portal-uploads`, `claim-receipts`. **No sub-agent was started; every live read and proof was this session's.**

## 4 · Decisions taken without asking
1. The views bar names a view's dates by preset only when **both** dates equal a preset; paging and one-off keys (`page`, `*_page`, `trail`, `warn`, `k`, `set`, `error`, `ok`, `view`) are never saved. Saving under an existing name replaces it.
2. A view whose query is empty opens as `?view=plain`, so an "everything" view is not overridden by the default.
3. Client sort keys: one prefix per table (listed in `docs/table-features.md`); the four single-table pages use plain `sort`/`dir` (no other table there uses them).
4. Bulk runs in **screen order**, not tick order; after a run the selection clears and the page refreshes; a call that never reaches the server is that item's refusal ("did not reach the system"), not the batch's.
5. The bulk bar sits inside the same `PermissionGate` as the single-item buttons (visible, unpressable, with its reason, for a reader who cannot decide).
6. `saved_views` carries no write gate (`enforce_write_permission`): its predicate is `user_id = auth.uid()`, the `notification_reads` precedent; fixture 198 names both.
7. Medical-claim and leave reject messages carry no request code in the action's own check (it has none to give); the database refusal keeps its code.

## 5 · Assertions measured false / conflicts, stated plainly
1. **My Step 0 "29 filter pages" was wrong: 28.** A two-pass regex left `corrects` on `/safety/environment` (a correction pre-fill). Built on Q1's subject ("pages with filters in the address"); sort-only is 56, not 55. Recorded beside the ruling.
2. **My Step 0 table called the terms panel a DataTable list;** its requests are cards (the DataTable is each request's change table).
3. **TF-2 hand-back §6 omitted two statements** (above, Part 1).

## 6 · Registered, not fixed
SAVED-VIEW-DEFAULT-RETURNS-WHEN-LAST-FILTER-CLEARED (`docs/known-issues.md`, "TABLE-FEATURES-3 登记") — a question for Tim.

## 7 · Measured costs, for the next estimate
| Step | Cost |
|---|---|
| offline gate | 142 s |
| backup | ≈ 26 min (19:51 → ≈20:17) |
| dry run + apply | < 3 min |
| build | ≈ 45 s |
| full gate | 766 s |
| layout | 390 s (390 px, 35 pages) + ≈ 6 min (1280 px) |
| smoke | 50 min |
| live proof | ≈ 2 min |
