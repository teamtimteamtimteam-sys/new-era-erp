# CHAIN-WALK-COST — Step 0 readings (2026-10-28)

Brief: "CHAIN-WALK-COST — make the chain walk and the change-history trail cheap for every role (close-out of SYSTEM-MAP-3 first; grilling + survey, then STOP)".
Started from `5e6d58fac255c447d5ba571dc81140d80b0b7955` (HEAD = origin/main). **No application code changed and no migration ran in Step 0.** No sub-agent was started.

**Identity of every reading.**
- Live: production pages through one throwaway `sm3probe` cfo clone (GET only); read-backs as `postgres` (`rolbypassrls = true`) on base tables, reconciliation as tim@ (cfo) rolled back;
  **existing** `pg_stat_statements` rows read once as `postgres` (no new timing on live — the brief allows timing on live only in the final proof).
- Local (all EXPLAIN / timing): one throwaway cluster on this machine (PostgreSQL 17.10, `work_mem` 2184kB and `random_page_cost` 1.1 set to live's values, `jit` off on both).
  Every walk / trail / read runs **as the real account of each of the seven roles** (`SET LOCAL ROLE authenticated` + that account's JWT claims), rolled back.
  Harness: `harness/` (`walk.py` one call with EXPLAIN + `pg_stat_xact_user_functions`; `survey.py` every chain page × every document × seven roles; `trail_survey.py` the same for `record_trail`;
  `pageq.py` other page reads; `diff.py` old vs prototype walk, row for row).

| local DB | what it is |
|---|---|
| `cwclive` | repo rebuild (`verify_rebuild.py --skip-diff`) + the **data of the 2026-10-27 19:50 backup** (`pg_restore --data-only`, triggers off, change_log chunks; 90,347 rows = manifest) + **today's** `document_types` · `document_relation_arms` · `roles` · `role_permissions` · `user_roles` copied from live (read-only SELECTs). Five live-only `NOT VALID` checks and `containers_code_format` were dropped **locally** so live's rows load. |
| `cwcscale` | `cwclive` + a **volume proxy**: rows of the big tables copied with new ids, nullable FKs cleared (unrelated volume): output batches +15,000 · inbound +7,200 · journal entries +9,200 · runs +2,800 · POs +1,980 · SOs +1,980 · shipments +2,400 · processing_outputs +3,400. Movements, payments, assays, invoices, processing_inputs refused the copy (XOR checks) and are **not** scaled. ⚠ `processing_outputs.run_id` is NOT NULL, so its copies pile onto the existing runs — **unrealistic fan-out**; readings touching that path are pessimistic. |
| `sct` / `sct1` | `cwcscale` / `sp1` + 632,429 unrelated change_log rows (images replaced by their own random id) → 722,776 |
| `sp1` · `sp2` · `sw2` · `sall` · `sp1w2` | `cwcscale` + prototype P1 (policy wrap) · P2 (permission cache) · W2 (set-based walk) · W2+P2 · P1+W2 (`harness/proto-*.sql`) |

## Part 1 — SYSTEM-MAP-3 close-out

| Step | Reading |
|---|---|
| 1.1 / 1.2 | `db/scripts/2026-10-28-system-map-3-closeout-prod-check.mjs` → **`SM3_CLOSEOUT_EXIT=0`, 3/3** (`readings/sm3-closeout-prod-check.txt`): PO-2026-0003 → HTTP 200, the purchasing chain drawn after the page (8 steps, at purchase order; inbound batch · assay · pricing · payable found; payment request · payment · bank reconciliation none) ⇒ **production serves 5567a85 / 5e6d58f**; "All related records" → `/related/purchase_order/<id>` HTTP 200. Nothing pressed. `select 1` inside the database 0.698 ms before / 0.039 ms after; db and rest ACTIVE_HEALTHY. (The script's "group links" count, 0, used a selector that does not match that page; it is not evidence either way.) |
| read-back | `readings/readback-part1.txt` (`READBACK_OWN_EXIT=0`): 7 users / 7 enabled; 0 throwaway users, 0 probe roles, 0 orphan grants; 1 active cfo grant; approvals ON `finance/cfo/1000`; `require_calibrated_since` NULL; 2 CODs; AP 0.00 / AR 0.00 unexplained. |
| 1.3 | 64d-3 marked closed in `docs/forward-queue.md` (uncommitted; goes into the cut's commit). |

## A — what the walk costs, and why

**1. Role is not the multiplier.** On `cwclive` (live data, live grants), every chain page × every document (277 walks) × seven roles, warm session (`readings/survey-livedata.json`):
worst walk **177 ms** (IN-2026-0001, processing chain); per page the seven roles are within ~15 % of each other (warehouse lower where it cannot see finance steps).
From SHP-2026-0001 (the brief's case), fresh connection: **admin 79.1 / 78.3 ms · cfo 78.1 / 79.3 ms**, 6 rows each, the same 18 `search_related_rows` and 40 `has_permission` calls (two runs counted).
**The live pair 1,126.8 / 255.6 ms has no stored query or log in the repo** (only quoted in `forward-queue.md` / `known-issues.md`); it could not be re-derived.

**2. Live is 3–21× local, and varies on its own.** The SYSTEM-MAP-3 perf script's own documents, re-walked locally as cfo on a fresh connection (as that script did) — `readings/ratio.json`:
live ÷ local **median 4.75×** (2.9–6.8× on 17 of 20 walks), and three outliers: **purchase order 15.9× (804.6 vs 50.5 ms) · assay 12.6× (775.5 vs 61.6) · payroll payment 21.2× (738.3 vs 34.9)** — the three "cfo near 800 ms" pages.
Live's own `pg_stat_statements` (since 2026-07-29, as `postgres`): `document_chain_walk` through PostgREST **822 calls, mean 828.7 ms, sd 805.1, min 3.2, max 7,762.9**; `record_trail` 14,701 calls, mean 288.9, max 7,160.7.
Live's database is 146 MB with `shared_buffers` 224 MB — it is in memory; the gap is CPU and concurrency, not disk. ⇒ **"admin ≈ 4× cfo" and "cfo ≈ 800 ms" are the same phenomenon: run-to-run variance on the free-plan instance (inference; the local reproduction says it is not the role and not the document).**

**3. What the work is (identical for every role):**
- **per hop, a fixed catalog cost** — `search_related_rows` re-derives `document_relations` from `pg_catalog` on every call: 3.5 ms and **9,325 buffer hits** each (EXPLAIN in this session), plus building and planning its dynamic SQL; the walk issues one call per (found document × target type): 9 from the shipment, 15 from IN-2026-0001.
- **per row, a permission check** — 541 policies on 316 tables call `has_permission()` (331 of the 387 SELECT/ALL policies), **none** in the `(SELECT has_permission(…))` form. `has_permission` is SECURITY DEFINER with a SET clause (never inlined) and re-aggregates the reader's roles each call: **~177 buffers per row**. A sequential scan of 20 output batches = 3,541 buffers. A reader who lacks the code evaluates every OR branch.
- **probes that scan whole tables** — "which output-batch prefixes have rows" runs `EXISTS (… code LIKE 'XXX-%')` for 13 prefixes; the 12 with no rows scan the whole table, each row through `has_permission`.

**4. At volume (`cwcscale`, `readings/survey-scale*.json`, budget lifted to measure):**
processing chain **11,145–12,717 ms** on every role (was 54–177 ms), **180,464 `has_permission` calls per walk** (97 % of the time); sales order · invoice · credit note **616–681 ms**; everything else ≤ 126 ms.
At today's budget those four processing pages are refused (`DOCUMENT_CHAIN_WALK_BUDGET`) **even locally**.

## B — the fix, measured before proposing it

| prototype (on `cwcscale`) | processing run | sales order | purchase order |
|---|--:|--:|--:|
| today | 11,145–12,514 | 641–681 | 108–126 |
| **P1** every policy `has_permission(x)` → `(SELECT has_permission(x))` (541 ALTER POLICY) | **33–35** | 586–603 | 82–110 |
| P2 `current_user_permissions()` cached per transaction | 661–1,662 (admin 2.5× gm) | 557–560 | 79–106 |
| **W2** set-based walk: each hop's SQL built once per (step, source type, target type), run for the whole frontier (`= ANY($1)`) | 11,147–12,344 | **94–100** | 70–76 |
| W2 + P2 | 692–1,688 | 40–44 | 48–64 |
| **P1 + W2** (all 20 page/chain combinations, 7 roles, `survey-sp1w2.json`) | **32–34** | **35–36** | **48–66** · **worst of all: 66 ms**, 0 errors |

**Same results:** W2 against today's walk on `cwclive`, every document × seven roles: **1,939 / 1,939 identical** (step, key, id, code, label, href) (`harness/diff.py`). P1 is a pure re-plan (the wrapped call is the same value for the whole statement).
**Proposed:** P1 + W2 (W2 also keeps the 2 s `DOCUMENT_CHAIN_WALK_BUDGET` check before each hop).

## C — the trail

Today (`cwclive`, `trail-livedata.json`): worst **103 ms** (IN-2026-0001); per page the seven roles within a few ms; warehouse 41 ms on output batches vs cfo 63 (warehouse resolves fewer names). 157 named `TRAIL_NOT_PERMITTED` refusals (warehouse on finance / sales pages), as designed.
At volume (`sct`, 723k change_log): inbound batch **~3.7 s**, output batch **~3.5 s**, payroll period 1.4 s, processing run 1.26 s, payable 0.7 s — **role-independent, and P1 does not help** (`sct1`; `record_trail` is SECURITY DEFINER).
Cause (`pg_stat_xact_user_functions`, OUT-2026-0186): the work scales with **all member rows** (922 there, inflated by the fan-out artifact), not with the 20 entries shown — for each member row, before paging: `trail_fk_targets` (catalog, 2× per row, 2.5 s of 3.4 s), `trail_prelog_sources`, `trail_row_visible` (rebuilds the policy SQL from `pg_policies` per row), `trail_current_image`.
**Proposed:** per-table metadata once per call; page first (group, number and cut to N entries), then decorate only the rows in those entries. The panel: `AuditTrail.tsx:224` throws and there is no Suspense — wrap it like `DocumentChains` (Suspense + an in-section "could not be drawn"); one shared component, so all 105 files using it gain it.

## Other per-page reads (0.2 — reported, not fixed)

Candidates = every read the 21 pages call (static map, `.rpc()` / `.from()`) that live's `pg_stat_statements` shows with mean > 100 ms or max > 300 ms; re-timed locally as the seven accounts (`pageq-live.txt`, `pageq-scale.txt`):
today all **≤ 15 ms**. At volume: **`inbound_batch_margin` (inbound batch page) on IN-2026-0001: 15.6 ms → 362,281 ms** (`inbound-batch-margin-in0001.txt`; the run that batch fed got the artifact fan-out, so pessimistic — but it grows super-linearly); 73–78 ms on three other batches. Everything else ≤ 9 ms.
Live means for reference (all callers, all pages): `inbound_batch_margin` 986 ms (max 6,962) · `coa_certificate_data` 353 (max 4,596) · `traceability_report_data` 108 (max 6,748).

---

# Step 1 — build readings (Tim's rulings 2026-10-28 20:16:42 CST → push)

**Identity of every reading** as in Step 0. Local DBs added in Step 1: `cwc` (empty repo rebuild) + `db/seeds/seven-roles-2026-10-28.sql` + **`db/seeds/chain-walk-year.sql`** → `cwcseed` (before) /
`cwcafter` (after: `harness/apply-after.sh` — this cut's functions and policy wrap, today's walk and trail kept as `*_old` for comparison); `cwclive` / `cwcliveafter` the same pair on the live-data copy.
No sub-agent was started, so none connected to live.

## The seed — one year (Tim Q2), row counts read back (`readings/seed-row-counts.txt`)

purchase orders 2,000 · inbound batches 7,300 (6,000 on a PO, 3 each) · assays 7,300 · journal entries 30,000 (lines 59,888) · payments 8,000 (5,000 out, 3,000 in) · payment requests 4,000 ·
payment allocations 8,000 · bank statements 12 · statement lines 10,000 (matches 8,000) · work orders 1,500 · runs 3,000 · inputs 7,300 · output batches 15,000 (8 prefixes) · outputs 15,000 ·
cost allocations 7,300 · inventory movements 60,000 · quotes 3,000 · sales orders 2,000 (lines / reservations / sales 4,000) · containers 1,000 · shipments 2,500 · invoices 2,000 · credit notes 100 ·
employees 60 · attendance 12 × 60 · overtime 12 × 60 · leave 1,500 · payroll 12 × 60 · **change log 600,124** (280,039 inserts + 320,085 updates). Loads in **9–10 s** (replica, local only).

## What changed (and why each piece, measured)

| piece | cause it removes | file |
|---|---|---|
| every public policy's `has_permission` / `has_any_permission` / `current_user_employee()` / `auth.uid()` → `(SELECT …)` — **560 policies, 783 calls** | per-row permission / identity calls (180,464 a walk on the processing chain; 2,617 `current_user_employee()` a people-chain walk) | migration ①, `db/tables/*.sql` (314 + 20 files), `scripts/check-policy-permission-wrap.mjs`, `db/policy-permission-allowlist.tsv` (12 row · 53 storage) |
| walk: one set-based query per (step, source type, target type); each table pair's edges read once per walk with an equality filter (**-fu1**; the first version read every pair at once — see below); seen / asked as key sets | per-document `search_related_rows` (catalog re-derived each call) and quadratic array scans | `db/functions/document_chain_walk.sql` |
| `document_relation_arm_pairs(arm, ids[])` · `document_chain_step_admitted(filter, ids[])` · `document_detail_hrefs` set-based; the single forms delegate | under RLS a non-leakproof test is never an index condition → one scan per document (the payment-request jsonb arm: 1.2–2.7 ms each, 200 a statement walk) | the three functions + `document_relation_arm_ids` · `document_chain_step_admits` · `document_detail_href` |
| trail: members by the FK's own type; "before change history" only when it fits the page; per-row reads only for rows drawn; member set built in one step; large parents matched in one pass | `col::text = ANY(…)` seq scans; decoration of every member row; quadratic appends; one GIN probe per parent | `db/functions/record_trail.sql` |
| `trail_current_image` · `trail_row_visible` · `trail_ref_label` · `change_log_field`: key compared in the column's type (data errors = no match, as before); `trail_fk_targets` by oid, PL/pgSQL | `::text` / `to_jsonb(t) @>` seq scans; a SQL function re-planned every call | those files |
| the change-history panel draws its own failure (`section.failed`) and rethrows Next's control flow | a failed `record_trail` turned the whole page into a 500 | `app/components/trail/AuditTrail.tsx`, `lib/trail/text.ts` |

## Before → after on the seed (`readings/seed-before-*.txt`, `seed-after-*.txt`; 8 documents per page — 3 for the before walk; worst of each page, seven roles, ms inside the database)

The "walk after" column below is the **first** version (relation map read once). **-fu1** (per pair, equality filter — the shape live handles cheaply) measured on the same seed, 8 per page (`seed-after-walk-fu1.json`): purchase order 50–79 · inbound processing 113–133 · assay 24–47 · payable 55–56 · payment request 64–69 · payment 64–66 · **bank statement 120–128** · work order 112–118 · run 111–127 · output 30–31 · sales pages 33–38 · people pages 20–29 ms. **Four pages are over the 100 ms aim (≤ 133 ms), none over 300** — the price of reading pairs one at a time locally, paid for the live behaviour below.

| page | walk before | walk after | trail before | trail after |
|---|--:|--:|--:|--:|
| purchase order | 618–1,002 | 29–39 | 18–21 | 15–18 |
| inbound batch (processing chain) | 4,917–5,881 | 34–36 | 288–323 | 45–60 |
| assay | 312–612 | 15–19 | — | — |
| payable | 312–361 | 18–19 | 68–72 | 10 |
| payment | 600–711 | 25 | 96–102 | 11–12 |
| **bank statement** | **62,137–69,779** | **82–88** | **15,579–16,663** | **60–69** |
| work order · run · output batch | 4,818–5,747 | 18–35 | 8–324 | 4–33 |
| quote · SO · shipment · container · invoice · credit note | 483–876 | 13–16 | 7–43 | 4–10 |
| attendance · overtime · payroll | 312–341 | 14–16 | 128–298 | 18–39 |
| leave | 62–73 | 13–14 | 8–9 | 4–5 |
| payroll payment (journal) | 338–360 (`seed-before-walk-journal.txt`) | 14 | 153–501 | 10–12 |

**Fixture 297** (fresh rebuild of the final code, `readings/fixture-297.txt`, 29.8 s): seven roles × 23 page/chain cases — 161 walks, worst **80.0 ms**; 134 trails, worst **42.0 ms**; 13 named refusals;
**0 over the 100 ms aim, 0 over 300 ms**; F arm: a declared edge sleeping 350 ms measured **1,548.8 ms** (red). Left in place on a local copy, the same fixture **fails** (`fixture-297-injected.txt`,
`F297_INJECTED_OWN_EXIT=3`, every role's statement walk ~438 ms named). Fixture 296 still passes on the new walk (`fixture-296.txt`).

## Same results (row for row)

| what | where | result |
|---|---|---|
| walk, every chain document × seven roles | live-data copy | `livecopy-walk-diff.txt` |
| trail, every chain-page record × 3 page sizes × seven roles | live-data copy | `livecopy-trail-diff.txt` |
| what each role can read, every table whose policies changed (318) | live-data copy · seed | `livecopy-policy-read.txt` · seed: **2,226 / 2,226 identical, 1,815,062 rows hashed** |
| `search_related` · `search_related_rows` · `document_detail_hrefs` · `change_log_rows` | live-data copy | `livecopy-related-diff.txt` |
| walk / trail / related on the seed (3 per page; today's functions are slow there) | seed | `seed-*-diff.txt` |
| `inbound_batch_margin`, 292 batches × seven roles | seed | **2,044 / 2,044 identical** (`margin-*.json`) |

## Added scope — `inbound_batch_margin` on the realistic seed (`margin-cwcseed.json` / `margin-cwcafter.json`)

292 batches (every 25th) × seven roles: worst **143.6–154.6 ms** before and after (admin · cco · cfo · cto · finance · gm), warehouse refused by name (`PERMISSION_DENIED`, `data.view_prices`) both times.
No role over 300 ms → **not changed** (the ruling's trigger). The 362 s reading of Step 0 was the inflated proxy's fan-out.

## Live proof run 1 — the first walk version (2026-10-29 00:16 → stopped 00:59, `readings/live-proof-run1-stopped.txt`)

Started after smoke; admin and cfo finished, cco was on its fourth page when it was stopped (SIGTERM to the node process → its own cleanup; `CWC_PROOF_EXIT=143`;
read-back afterwards 7 users · 0 throwaway users / roles · 1 cfo · 0.00 — `readback-after-proof-run1.txt`). 906 PASS, **2 FAIL — both budget refusals** with the database signals normal:
admin · leave and cfo · work order. In-database walk times (fresh connection, EXPLAIN ANALYZE) of up to 1,150 ms, including **a one-row container page at 859 ms that took 29.6 ms before**.
Locally the first version had a fixed cost the old walk did not: reading the whole chain's relation map with one `IN` filter (12–19 ms cold), where the planner cannot prune
`document_relations`' bridge / XOR branches the way it does for a single pair. On tonight's live data (the 22:27 backup restored locally, fresh connections): leave 12.8 (old) · 26.9 (first) · **11.2 (-fu1)** ms;
bank statement 10.9 · 24.5 · **10.3** ms. → **-fu1** (`db/migrations/2026-10-29-chain-walk-cost-fu1.sql`, one function, same window): walk 1,939 / 1,939 identical on the live-data copy,
fixtures 296 / 297 green (297: walks worst 113.8 ms, 27 of 161 over the 100 ms aim, 0 over 300), offline gate `GATE_EXIT=0`, live dry run 26 / 26 identical (`dry-run-fu1.txt`), applied 01:05:43.

## Live proof run 2 — -fu1 (2026-10-29 01:24:07 → 02:5x, `readings/live-proof.txt`, `live-proof.json`) — **acceptance NOT met**

`db/scripts/2026-10-28-chain-walk-cost-live-proof.mjs`, seven throwaway clones (`sm3probe`), one reader at a time, `next start` on this tree against live, GET only, abort rules of AGENTS.md
(never fired: in-database `select 1` ≤ 0.067 ms, median round trip ≤ 416 ms, db / rest ACTIVE_HEALTHY before every reader). **`CWC_PROOF_EXIT=1` — 2,712 PASS · 10 FAIL.**
- **8 pages had a bar refused by `DOCUMENT_CHAIN_WALK_BUDGET`** (2 s), the database signals normal each time: admin · processing run · cfo · payable · cfo · work order · cco · shipment ·
  finance · OUT-2026-0119 · gm · assay · gm · sales order · warehouse · OUT-2026-0119 (the other 2 FAILs are the same refusal seen by the in-database timing of gm · sales order and warehouse · OUT-2026-0119).
- Every bar that drew showed the same steps, links and 「受限」 lines as SYSTEM-MAP-3's proof judged (the chain checks are unchanged); **the audit trail section was drawn on every page that has one — 0 `failed`**
  (121 with entries; 12 not applicable because the role cannot open the page). **Warehouse · OUT-2026-0119: HTTP 200, the trail drawn with entries** (the page that returned 500 in SYSTEM-MAP-3).
- In-database time, worst per role (EXPLAIN ANALYZE as the clone, fresh connection): admin walk 1,428 / trail 677 · cfo 1,897 / 1,029 · cco 1,368 / 780 · cto 996 / 601 · finance 1,393 / 625 · gm 1,148 / 1,416 · warehouse 977 / 1,230 ms.
  Page-level, live's own `pg_stat_statements` deltas over the run (`pgss-snap-before-run2.txt` → `pgss-snap-after-run2.txt`): `document_chain_walk` 327 calls, mean 717 ms; `record_trail` 286 calls, mean 796 ms.
- **Why, measured:** the live database host is swapping — `MemTotal` 426 MB, `MemAvailable` 101 MB, about 580 MB of 1.07 GB swap in use, 12.8 M major faults; during the run the two CPUs were
  87–88 % idle with 7.5 % iowait and 0 steal (`live-host-metrics.txt`, Supabase's privileged metrics endpoint, read-only). The same walks run in 10–60 ms on the local rebuild of the same data.
  The abort signals cannot see it (a `select 1` page stays in memory). → `docs/known-issues.md` § CWC-LIVE-INSTANCE-SWAPPING; SUPABASE-PLAN (go-live group #15) and a restart are Tim's to decide.
- Read-back after (`readback-after-proof.txt`, `READBACK_OWN_EXIT=0`): 7 users / 7 enabled · 0 throwaway users / roles · 0 orphan grants · 1 cfo · approvals `finance/cfo/1000` · `require_calibrated_since` NULL · 2 CODs · AP / AR 0.00.
- **SM3-ADMIN-WALK-OVER-BUDGET and SM3-OUTPUT-TRAIL-TIMEOUT stay open** (the ruling closes them only on 0 refusals and 0 trail errors).

## Other readings of the verify order

| step | reading |
|---|---|
| offline gate | `GATE_EXIT=0` (169 s; `gate-offline.txt`) · after -fu1 `GATE_EXIT=0` (180 s; `gate-offline-fu1.txt`). First run red on fixture 236 R3 (a typed key comparison raised on 'not-a-uuid'); fixed in `trail_current_image` / `trail_row_visible` (data errors = no row) |
| backup | `BACKUP_EXIT=0`, 2026-10-28 22:27:41 → 23:06, `evoltrya-backup-2026-10-28-2227.dump` + 22 change_log chunks, 97,828 rows = count (`backup.txt`); -fu1 took no new backup (one function; this backup predates both migrations — SYSTEM-MAP-3 -fu2 precedent) |
| live dry run | `DRY_OWN_EXIT=0`: 26 / 26 before = after (walks, trails, table reads as tim@ and the warehouse account) · 560 policies wrapped · 0 unwrapped · 2 new functions · anon cannot walk · budget refuses (`dry-run.txt`); -fu1 the same (`dry-run-fu1.txt`). The migration body held its table locks 20 s on live |
| apply | `APPLY_OWN_EXIT=0` — **broken window opens 2026-10-28 23:11:30 CST** (`apply.txt`); -fu1 `APPLYFU1_OWN_EXIT=0` at 2026-10-29 01:05:43 (`apply-fu1.txt`) |
| types · tsc · build | `TYPES_OWN_EXIT=0` (+13 lines: the two new functions) · `TSC_OWN_EXIT=0` · `BUILD_OWN_EXIT=0` (`build-fu1.txt`; `check-policy-permission-wrap` ✓ 667 policies · 783 wrapped calls · 65 listed) |
| full gate | `GATE_EXIT=0` on the first version (868 s, `gate-full.txt`) and **on the final code after -fu1 (773 s, `gate-full-fu1.txt`)** — fixture 297 and live-fixture 297 green |
| i18n · error-swallowing | `I18N_OWN_EXIT=0` · `SWALLOW_OWN_EXIT=0` |
| layout | 390 px and 1440 px, OUT-2026-0119 · PO-2026-0003 · IN-2026-0001: 3 / 3 usable at both widths, 0 overflow, 0 clipped tables (`layout-390.txt`, `layout-1440.txt`; run before the migration — the app change is the trail panel only) |
| smoke | `SMOKE_EXIT=0` — 344 ok · 25 skipped (no data) · 0 FAILED · `NETRETRY_TOTAL=0`, 1,923 s (`smoke.txt`); watchdog never fired, recorded single round trips 2,141 · 1,854 · 1,829 ms (`smoke-watchdog.txt`); read-back clean. Not re-run after -fu1 (no app change; one function, covered by the gate's fixtures and proof run 2) |
| COD bytes | both equal the AGENTS.md baseline: 34,701 B `ba299a4f…f42101` · 34,746 B `717661f6…2513a4f9` (`cod-bytes.txt`, `COD_OWN_EXIT=0`) |
| fresh clone | `d318f579fb2f32c36ba4e93fc93e6e2a63ef1af8`, no `.env.local`, `npm ci && npm run build`: **`FRESH_OWN_EXIT=0`** (`fresh-clone-build.txt`). The only change after that clone is this line and that log (docs only). |

---

# CWC-CLOSE — clean-memory live re-proof and smoke (2026-10-29 08:15 → 10:4x CST)

Close-out of CHAIN-WALK-COST: **no code, no migration, no version number.** Started from `ffddc974b3e1752f822a38b6c8ec4aaa77fbe6dc` (HEAD = origin/main). No sub-agent was started.
Tim upgraded the plan: **NO** → Tim authorised one project restart through the Management API.

**Identity of every reading.** Host metrics: Supabase's privileged metrics endpoint (read-only, the service key passed to curl on stdin; only the memory / swap / vmstat / CPU lines kept — `scratchpad` reader, not committed).
Health and restart: Management API. Read-backs as `postgres` (`rolbypassrls = true`) on base tables, reconciliation as tim@ (cfo) rolled back. Walk / trail timings: the proof's own `EXPLAIN (ANALYZE)` as each role's throwaway clone, rolled back.

| step | reading |
|---|---|
| 1 · production | GitHub's newest Production deployment is `ffddc974b3e1` (id 7394743752), `state=success` 2026-10-28T19:05:46Z (03:05:46 CST) — a downstream record (AGENTS.md: Vercel is the source); Tim confirmed the deployment 2026-10-29 08:15 CST (relayed, not measured). The CWC app change (`section.failed`) is drawn only on a failure, so the HTML cannot tell the versions apart. |
| 2 · before restart (08:23:24) | `MemTotal` 426 MB · `MemAvailable` 185 MB · **swap 450 MB of 1,074 MB in use** · CPUs over 62 s: idle 90 % · **iowait 4.8 %** · steal 0 (no proof running). Compute: `billing/addons` → **no compute add-on selected** (the plan's default instance; 426 MB is what the host reports). (`close-host-metrics-restart.txt`) |
| 3 · restart | `POST /v1/projects/<ref>/restart` **08:24:48 CST → HTTP 200**; `pg_postmaster_start_time()` **08:25:52 CST** (vmstat counters reset: the host rebooted). Health: `db=ACTIVE_HEALTHY rest=ACTIVE_HEALTHY` at **08:34:38** — the nine polls 08:26–08:34 were unreadable (a parser bug in my poller, not the API), so the moment it became healthy between 08:25:52 and 08:34:38 is **not measured**. (`close-restart.txt`) |
| 3 · after restart (08:34:53) | `MemAvailable` 142 MB · **swap 355 MB in use nine minutes after boot** · ~9,000 pages swapped in and out per minute · iowait 3.5 % with no reader running. **The restart did not give a swap-free instance: the idle footprint does not fit in 426 MB.** |
| 4 · read-back (`close-readback-before-proof.txt`, `READBACK_OWN_EXIT=0`) | 7 users / 7 enabled, each holding exactly one role (admin · cco · cfo · cto · finance · gm · warehouse; per account by uuid) · 0 throwaway users / roles · 0 orphan grants · 7 active grants · 1 cfo · approvals ON `finance/cfo/1000` · `require_calibrated_since` NULL · 2 CODs · AP 0.00 / AR 0.00 unexplained. COD bytes equal the AGENTS.md baseline (`close-cod-bytes-before.txt`, `COD_OWN_EXIT=0`). |

## Step 5 — live proof on the final code (`close-live-proof.txt`, `close-live-proof.json`)

The same script and pages as proof run 2 (`db/scripts/2026-10-28-chain-walk-cost-live-proof.mjs`, unchanged), `next start` on a fresh `npm run build` of `ffddc97` (`BUILD_OWN_EXIT=0`), seven throwaway clones, one reader at a time, GET only.
08:39:05 → 10:08 CST. Abort rules never fired: in-database `select 1` ≤ 0.475 ms, five-trip medians 394–545 ms, db / rest ACTIVE_HEALTHY before every reader. **`CWC_PROOF_EXIT=1` — 2,822 PASS · 5 FAIL; all five are `DOCUMENT_CHAIN_WALK_BUDGET` refusals** (run 2: 2,712 PASS · 10 FAIL, 8 page bars refused):

| # | where | how it showed | in-database `select 1` at that moment |
|---|---|---|---|
| 1 | admin · payable | the page's bar refused (page HTTP 200) | 0.02 ms · db / rest healthy |
| 2 | cfo · output batch | the in-database walk timing (processing) refused | reader start 0.022 ms (the script measures `select 1` at the moment only for a page-bar refusal) |
| 3 | finance · payment | the in-database walk timing (purchasing) refused | reader start 0.475 ms (same) |
| 4 | finance · output batch | the in-database walk timing (processing) refused | reader start 0.475 ms (same) |
| 5 | warehouse · processing run | the page's bar refused (page HTTP 200) | 0.045 ms · db / rest healthy |

**Change-history trail: 0 errors** — 133 in-database trail timings (11 `TRAIL_NOT_PERMITTED` by design, 0 other errors); on the pages 121 drawn with entries, 12 where the role cannot open the page, **0 `failed`**; warehouse · OUT-2026-0119 HTTP 200 with the trail drawn.

In-database time per role (EXPLAIN ANALYZE as the clone, fresh connection), worst — run 2 beside it:

| role | walk worst (page) | run 2 walk worst | trail worst (page) | run 2 trail worst | walk median | trail median |
|---|--:|--:|--:|--:|--:|--:|
| admin | 1,285 (shipment) | 1,428 | 526 (shipment) | 677 | 374 | 130 |
| cfo | 1,868 (assay) | 1,897 | 1,152 (output batch) | 1,029 | 493 | 204 |
| cco | 1,050 (purchase order) | 1,368 | 580 (output batch) | 780 | 433 | 169 |
| cto | 1,176 (processing run) | 996 | 645 (output batch) | 601 | 459 | 186 |
| finance | 1,108 (assay) | 1,393 | **3,102 (OUT-2026-0119)** | 625 | 671 | 257 |
| gm | 1,027 (shipment) | 1,148 | 704 (inbound batch) | 1,416 | 435 | 230 |
| warehouse | 1,622 (inbound batch) | 977 | 807 (inbound batch) | 1,230 | 157 | 286 |

(Medians and worsts exclude the three refused timings, which have no time.) Page-level, live's `pg_stat_statements` deltas over the run (`close-pgss.txt`, PostgREST callers): `document_chain_walk` 144 calls, mean 543 ms (run 2: 717); `record_trail` 122 calls, mean 272 ms (run 2: 796).
Locally the same walks are 10–60 ms (Step 1). **Same picture as run 2: the host, not the code.**

Host per reader (`close-host-metrics-per-role.txt`; read when each reader starts, i.e. after the previous one):

| marker | available | swap in use | iowait (2 CPUs) |
|---|--:|--:|--|
| before admin 08:39:55 | 158 MB | 256 MB | not measured (window too short — the endpoint refreshes about once a minute, so a 30 s window compared a sample with itself; fixed to ≥ 65 s from cto on) |
| before cfo 08:52 | 101 MB | 591 MB | not measured (same) |
| before cco 09:05 | 121 MB | 790 MB | not measured (same) |
| before cto 09:18 | 120 MB | 458 MB | 9.8 · 10.2 % |
| before finance 09:30 | 127 MB | 719 MB | **18.2 · 15.8 %** |
| before gm 09:44 | 117 MB | 541 MB | 11.1 · 10.6 % |
| before warehouse 09:58 | 107 MB | 636 MB | 13.2 · 12.6 % |
| after all readers 10:07 | 144 MB | 325 MB | 1.5 · 1.9 % |

Read-back after (`close-readback-after-proof.txt`): **byte-identical** to the one before.

## Step 6 — smoke on the final database state (`close-smoke.txt`, `close-smoke-watchdog.txt`)

`node scripts/smoke-routes.mjs` (with SYSTEM-MAP-3's network-level retry) under `db/run_detached.sh`, 10:08:50 → 10:39 CST, under a watchdog applying the AGENTS.md abort rules once a minute (plus host memory / swap, recorded only).
**`SMOKE_EXIT=1` — one route failed: `/tools/reminders` → HTTP 500**, `查询失败(operations_now): 57014 canceling statement due to statement timeout` (15,615 ms). **343 ok · 25 skipped (no data) · 1 FAILED** (the CWC smoke: 344 · 25 · 0); 318 routes timed, 1,459.8 s, median 3,592 ms. **`NETRETRY_TOTAL=0`** (no network retries).
Watchdog: never fired — in-database `select 1` ≤ 1.53 ms, medians 391–550 ms, db / rest healthy every minute; **swap climbed 377 → 1,033 MB of 1,074 MB** (10:37:22). (The first watchdog matched the `run_detached` wrapper instead of the node process; it was restarted at 10:09:23, before it had read anything, and the second targeted node 44268.)
The failing read timed once afterwards as the real admin account, alone, rolled back (`close-operations-now-timing.txt`): **planning 537 ms + execution 382 ms**. `operations_now` last changed in SYSTEM-MAP-2 (`2e0d0477`); the CWC smoke at 2026-10-28 23:33 passed this route. ⇒ **inference, not proof:** the 8 s timeout is the same swapping host, under smoke load, with swap near full. Not re-run (no measurement says the host would be better on a second try) and not fixed (close-out, no code).
Read-back after smoke (`close-readback-after-smoke.txt`): **byte-identical**; COD bytes equal the baseline (`close-cod-bytes-after.txt`); host at rest afterwards: 143 MB available · swap 478 MB · iowait 1.5–1.7 % (`close-host-metrics-after-smoke.txt`).

## Verdicts
- 64d-4 closed (deployment confirmed by Tim 2026-10-29 08:15 CST; broken window 2026-10-28 23:11:30 → 2026-10-29 08:15 CST, about 9 h 04 m).
- **SM3-ADMIN-WALK-OVER-BUDGET and SM3-OUTPUT-TRAIL-TIMEOUT stay open** (5 refusals; the trail half is met — 0 trail errors). No fix attempted.
- CWC-LIVE-INSTANCE-SWAPPING stays open, linked to go-live item 15 (SUPABASE-PLAN): a restart does not clear it.
- CWC-STORAGE-POLICIES-UNWRAPPED closed as accepted (Tim 2026-10-29).
