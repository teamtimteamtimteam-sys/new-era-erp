# AUDIT-TRAIL-1b-2 — the commercial half: quote, sales-order, shipment, customer, commission, supplier, forwarder, container, lane, port and licence trails; the quote and sales-order History sections replaced (2026-09-30)

Part of v1.4.33, not yet released.

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `ac03576fe80be1bbf3fc08fe506f91c745fd35a7` (the 1b-1 window-record
commit), measured at 2026-09-29 23:53:55 CST. **Approvals were ON and stayed ON** (finance / cfo / 1,000). Every figure below is a
script's own exit line, or a query named with who ran it: `postgres` (`rolbypassrls = true`) on base tables unless stated; "as X" means
`SET LOCAL ROLE authenticated` plus X's JWT.

Cut 2 of 3 of AT-1b (1b-1 → 1b-2 → 1b-3). Reference for the mechanism: **`docs/change-log.md` §9**. This cut adds subjects; it does not
change the mechanism (no change to `record_trail`, `trail_actor`, `trail_row_visible`, masking or any policy).

## §1 · Step 1 — the 1b-1 close-out

**The broken window** is recorded in `docs/forward-queue.md` (item 24, the AT-1a format): start **2026-09-29 21:15:05 CST**
(`db/migration-windows.tsv`) · end lower bound **23:26:55 CST** (the push that moved `origin/main` to `e0e1a789`, `git reflog show --date=iso
refs/remotes/origin/main`) · end upper bound **23:40:39 CST** (the first command of the close-out session, holding your "deployed" — a
report, not a Vercel reading). **2 h 11 min 50 s to 2 h 25 min 34 s.** Committed and pushed on its own first (`ac03576f`), because
item h stopped step 2.

**The nine read-only checks, item by item** (reported in the close-out session; repeated here as the brief asks):

| | item | result | evidence |
|---|---|---|---|
| a | Step 0 hand-back in the repo with your answers | ✅ | `docs/surveys/AUDIT-TRAIL-1b/STEP0-HANDBACK.md`, answers at `:379` |
| b | M1–M6 all built | ✅ | `trail_subjects.sql` (`view_codes`, `root_rule`, `root_columns`), `trail_subject_members.sql` (`hop`, `shown`, `home`), `trail_prelog_sources.sql` (`by_kind`), `record_trail.sql:80` (M1) · `:87` (M3) · `:90-93` (M5) · `:165, :242` (M6); on live (as `postgres`, `rolbypassrls = true`): 10 subjects incl. `warehouse_request` inventory \| finance and `equipment` rule `page`, 11 upward hops, 11 stepping stones, 1 employee-kind pre-log source |
| c | processing pages' equipment links go to `/operation/equipment/[id]` | ✅ | no processing page links to `/finance/assets`; the links that exist: `app/operation/handovers/[id]/page.tsx:97`, `app/operation/equipment/page.tsx:42`, `lib/reminders.ts:201-206`. The run page has no equipment link at all (0 of 14 runs record a machine) |
| d | the batch trail's dead `/processing/{id}` links fixed | ✅ | they came from `db/views/batch_audit_trail_all.sql:205,231,256,281`; no page reads that view; both batch pages render `AuditTrail`; the old components are imported only by each other |
| e | state warnings as grey notes; "indirect link" gone | ✅ | `lib/trail/render.ts` (`batch.noPurchaseOrder` · `batch.runRolledBack` · `batch.noCogs` as `note` lines); `AuditTrailList.tsx` renders `note` in the muted colour; "indirect" / "polymorphic" appear nowhere in the new trail code |
| f | pre-22/09 stocktake "posted" folds with its approval | ✅ (fixture) | stamp registered (`trail_prelog_sources.sql`); fold in `render.ts` `foldApprovals`; fixture 238 arm S proves both halves. Live: 4 posted stocktakes, all before 22/09, 0 approval rows — nothing to fold on live |
| g | Q14 in `docs/known-issues.md` | ✅ | `AT1B-EQUIPMENT-ADVICE-SHOWS-COSTS` (`docs/known-issues.md:9856`) |
| h | mis-generated labels checked against their pages | ◐ → **resolved by your ruling (2026-09-29)** | 1b-1 corrected the two Step 0 labels on its own tables (`warehouse_requests.cod_id`, `shipment_lines.location_id`) and one wrong shape was left on a 1b-1 table: `journal_entries.code` = "Journal entrie number". The other eight Step 0 labels sit on 1b-2 / 1b-3 tables. Ruling: a label belongs to the cut that first shows its table; 1b-2 fixes those on its tables (§9) and the journal label; the rest are queued under 1b-3 (`docs/forward-queue.md`); 1b-1's hand-back corrected (the journal row, and 60 → the measured 91 overrides) |
| i | change-log §9 and the forward queue | ✅ | `docs/change-log.md` §9 table + §9.9; `docs/forward-queue.md` had 1b-2 and 1b-3 queued with their scopes |

## §2 · What was built

| ruling | built |
|---|---|
| Step 0 §a registry | eleven subjects in `trail_subjects()` — `quote` · `sales_order` · `shipment` · `customer` · `commission_agreement` · `supplier` · `container` · `forwarder` · `lane` · `port` · `company_licence` — and their 33 member rows in `trail_subject_members()` (counted: rows of the eleven subjects in the mirror) (§a row for row, plus `statement_issues` under the customer's statements — decision 6) |
| M1 | `shipment` admitted by `module.sales.view` **or** `action.ship_goods` — the page's guard; live reader: the warehouse account |
| M3 | `forwarder` with root rule `page`: the root `suppliers` row is per-row (Restricted without `module.suppliers.view`), details and rate quotes visible to logistics readers |
| Q1 | pre-log sources for every 1b-2 table (creation, lifecycle stamps); the history tables win over the issue tables (Step 0 §a) and the order's own creation folds with its history's `created` (decision 1) |
| Q2 | the trail sits at the bottom of `/sales/commissions/[id]/edit` and `/suppliers/[id]/edit` (their only pages) |
| Q26 | the quote page's History section (`quotes/[id]/page.tsx:257-268`) and the sales-order page's (`orders/[id]/page.tsx:268-290`) are gone; the trail replaces them. The order page keeps its history query, narrowed to the columns and change types that feed "amended since issued" and the "From quote" link |
| list-level | `app/components/trail/ListTrail.tsx` — one block at the bottom of `/logistics/lanes` (every lane and port) and `/purchasing/licences` (every licence), deleted records included |
| wording | 114 new wordings in `lib/trail/text.ts` (§10), a describer per subject in `lib/trail/render.ts`; labels for the 38 tables hand-checked (90 label overrides, 3 kind overrides; 26 value maps on these tables, 17 of them written in this cut — §10) |

Migration: `db/migrations/2026-09-30-at1b2-trails-commercial.sql` (built from the mirrors by `db/scripts/build_at1b2_migration.py`):
four functions replaced in place, same signatures — `trail_subjects`, `trail_subject_members`, `trail_prelog_sources`, `trail_ref_label`.
No table, policy, grant, trigger or permission code changed; no business row written. Fixture **239**.

## §3 · Pages — every new or changed route, with its file

| route | file(s) | change |
|---|---|---|
| `/sales/quotes/[id]` | `app/sales/quotes/[id]/page.tsx` | "Audit trail" at the bottom; the History section removed (Q26) |
| `/sales/orders/[id]` | `app/sales/orders/[id]/page.tsx` | "Audit trail" at the bottom; the History section removed (Q26); history query narrowed |
| `/sales/shipments/[id]` | `app/sales/shipments/[id]/page.tsx` | "Audit trail" at the bottom (M1) |
| `/sales/customers/[id]` | `app/sales/customers/[id]/page.tsx` | "Audit trail" at the bottom |
| `/sales/commissions/[id]/edit` | `app/sales/commissions/[id]/edit/page.tsx` | "Audit trail" at the bottom (Q2) |
| `/suppliers/[id]/edit` | `app/suppliers/[id]/edit/page.tsx` | "Audit trail" at the bottom (Q2) |
| `/logistics/containers/[id]` | `app/logistics/containers/[id]/page.tsx` | "Audit trail" at the bottom |
| `/logistics/forwarders/[id]` | `app/logistics/forwarders/[id]/page.tsx` | "Audit trail" at the bottom (M3) |
| `/logistics/lanes` | `app/logistics/lanes/page.tsx`, `app/components/trail/ListTrail.tsx` (new) | a list-level "Audit trail" for every lane and port |
| `/purchasing/licences` | `app/purchasing/licences/page.tsx`, `app/components/trail/ListTrail.tsx` (new) | a list-level "Audit trail" for every licence (in the page's `module.suppliers.view` branch) |
| every trail section | `app/components/trail/AuditTrail.tsx`, `AuditTrailList.tsx` | eleven subjects; a typed part after a title or a heading (decision 4) |
| batch and work-order trails (1b-1 pages, shared renderer) | `lib/trail/render.ts` | a batch attachment's file name moves into the typed part; work-order amendment lines read "Quantity", not "quantity" (decision 5) |

## §4 · Verification (in the order the brief set)

| # | step | verdict (the script's own line) |
|---|---|---|
| 1 | offline gate `db/gate.py --offline` | **`GATE_OFFLINE_EXIT=0`** (64 s wall; fixtures 236 · 237 · 238 · 239 ✓). Before it: all static build checks except `next build`; the lint freeze caught one unused variable of mine and went green |
| — | migration dry run on live (the built file with `COMMIT` → probe + `ROLLBACK`, the grants replay included) | **`DRY_OWN_EXIT=0`**, 17 s; probe: 21 subjects, 140 member rows, 130 pre-log sources; in-transaction proof: tim@ read SO-2026-0001 (18 rows, all pre-log, every history row), the warehouse account read SHP-2026-0001 (5 rows) |
| 2 | backup (detached) | **`BACKUP_EXIT=0`**: `evoltrya-backup-2026-09-30-0045.dump`, 5.5 MB, TOC 7,311 (previous 7,289, floor 6,560), about 18 min. Alive while it ran: a server-side `COPY` backend and a growing file were checked, not assumed |
| 3 | `db/apply_migration.sh` | **`APPLY_OWN_EXIT=0`**; preflight passed (4 functions replaced, 1 temporary proof function new); in-transaction proof passed; **committed 2026-09-30 01:06:27 CST** (`db/migration-windows.tsv`) |
| 4 | `npm run types:gen` (after `NOTIFY pgrst`, `DO_NOT_TRACK=1`) | **`TYPES_OWN_EXIT=0`**, byte-identical to the committed file (no signature changed) |
| 5 | `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** |
| 6 | `npm run build` | **`BUILD_OWN_EXIT=0`** |
| 7 | full gate `db/gate.py` | **`GATE_EXIT=0`** (521 s): rebuildable ✓ · mirrors = live incl. types ✓ · fixtures incl. 236–239 ✓ · anon surface ✓ · `changelog` 238 / 242 ✓ · `changemask` 27 masked tables / 81 columns, zero gaps ✓ · `colgrant` / `colreader` ✓. Tree fingerprint identical before and after |
| 8 | `node scripts/check-i18n.mjs` | **`I18N_OWN_EXIT=0`** |
| 9 | `node scripts/check-error-swallowing.mjs` | **`SWALLOW_OWN_EXIT=0`** (0 unallowed) |
| 10 | layout survey `scripts/survey-phone.mjs --routes=…` (the nine 1b-2 pages; after the renderer fixes below, again with the two 1b-1 pages whose rendering changed) | **390 px: 10 / 11 usable** (`SURVEY390_EXIT=0`) — no clipped table; **every trail section `entries`, section overflow 0, card layout**. The one page overflow is `/sales/quotes/[id]` **+8 px, pre-existing**: its culprit is the material dropdown in the lines editor, and the same page at `ac03576f` (swapped back in place on the same tree, then restored byte for byte) reads the same +8 px with the same culprit — `AT1B2-QUOTE-PAGE-390-OVERFLOW`. **1280 px: 11 / 11 usable** (`SURVEY1280_EXIT=0`), three-column grid, section overflow 0, tallest entry 256 px. `/sales/commissions/[id]/edit` **could not be surveyed**: 0 agreements live (the survey refuses a route it has no id for); it is proved by fixture 239 K |
| 11 | smoke `scripts/smoke-routes.mjs` (detached) | **`SMOKE_EXIT=0`: 260 ok, 9 skipped (no data), 0 FAILED**, including the new `trail` assertions on the nine 1b-2 pages (`/sales/commissions/[id]/edit` is an expected skip: 0 agreements live). Slowest route `/logistics/lanes` 19.6 s in dev (compile included); measured separately as tim@: the 7 lane trails read in 1.2 s and the 14 port trails in 1.2 s (one statement each, round trip included). Scratch cleanup reading (the smoke's own report): **6 stale rows, all pre-existing** (`ZZ-SMOKE-PROBE` · `-M25` · `-NTF` · `-S25` · `-CJK` · `-IB25`, 658–1,301 h old, five still referenced) — the same six AT-1a and 1b-1 reported; none from this session. `.ephemeral/` empty after every run; `auth.users` 7 accounts, 0 disabled, 0 probe / smoke / survey accounts, 0 orphan grants |
| — | page probe `scripts/probe-at1b2.mjs` (new; warehouse + admin sessions) | **`AT1B2_PROBE_EXIT=0`: 16 passed, 0 failed** — the warehouse account (no `module.sales.view`) opens SHP-2026-0001 with an `entries` trail and is refused the order page (M1); all nine pages `entries`, no machine token; SUP-2026-0003's dated file name only inside typed text; the two History sections gone; the order and lanes trails read the same in the Chinese interface |
| 12 | live verification | §6 |

**Files that changed after the build, the full gate and the smoke, and what was rerun.** The live proof (§6 B) writes everything in one
transaction, and that exposed three ways one operation lost something on screen (decisions 22–24). `lib/trail/render.ts` and
`scripts/check-trail-wording.mjs` changed (plus the proof script, the handback and `docs/change-log.md` §9.7). The gate reads none of them
for its database verdicts (mirrors, fixtures, types); its `swallow` / `currency` lines scan app code, and those checks run inside the build.
Rerun: **`TSC_OWN_EXIT=0` · `BUILD_OWN_EXIT=0`** (wording ⑥, i18n, error swallowing, currency, lint) · both layout surveys (above) · the smoke
over **every page that renders a trail** (AT-1a, 1b-1 and 1b-2 pages, the summary page, `/inventory`): **`SMOKE_EXIT=0`, 45 ok, 2 skipped
(no data), 0 FAILED** · the probe: **16 passed, 0 failed** · the twelve wording injections (§5). Last of all, one label in the
generated catalogue (`sales_order_history.amend_reason`, §5) — `scripts/gen-trail-catalogue.mjs` and `lib/trail/catalogue.generated.ts`;
the gate does not read them; rebuilt: **`BUILD_OWN_EXIT=0`** (generator consistency, wording ① – ⑥, i18n, lint).

## §5 · Fault injection — every arm went red, the clean runs went green

- **Fixture 239 — 17 injections** (`db/scripts/2026-09-30-at1b2-fixture-injections.py`, each a definition edit inside the fixture's own
  transaction against a local rebuild; an injection that fails to apply refuses by itself): **`INJECTIONS_OWN_EXIT=0` — 17 / 17 red in the
  arm they target, the clean run green.** M1 (first code only → H, the shipper) · M3 (root must pass its own rule → F, logistics reader) ·
  delivery-note issues dropped (H) · quote history dropped (Q) · order history dropped (S) · contacts dropped (C) · every row visible (C:
  the statement not Restricted) · supplier approvals dropped (P) · rate quotes dropped (F) · milestones dropped (T) · lane requirements
  dropped (L lane) · lanes arriving at a port dropped (L destination port) · licence gated on the logistics code (L licence) · the order
  creation stamp not registered (D) · the order history not registered (D) · `so_issues` registered too (D: shown twice) · the supplier
  approval stamp not registered (D). The first round had one expectation that named the reader instead of the arm's own message; it went
  red in the right arm, and the expectation was corrected.
- **Fixtures 236 – 238** stayed green on the new registry. One arm (236 P6, a deleted material known only by its name) went red when
  materials first carried their unit; the unit is now attached only when the image has one, and 236 is unchanged.
- **`scripts/check-trail-wording.mjs` — 12 named injections** (the 11 of AT-1a / 1b-1 plus `wording-drift`): **each red in its own arm**
  (ruler exit 3; registry, catalogue ×4, machine tokens ×5, ⑥ exit 1 — `raw-date` / `raw-ref` / `raw-null` also redden ⑥, which renders
  through the same code). The checks caught real defects before any page existed: lowercase history labels ("quantity"), an
  amended order printing its notes change twice, and three titles taking a document number from a column the
  catalogue hides (the sampler fills hidden columns with ids) — that one was arm ④ on my first draft; ⑥ caught the other two.
  A check of my own on the generator's override maps (duplicate table keys in one object literal) then found that my 1b-2 entry for
  `sales_order_history` had silently replaced 1b-1's, turning its `amend_reason` label back into "Amend reason"; merged into one
  entry, regenerated, rebuilt (**`BUILD_OWN_EXIT=0`**).
- **Smoke `trail` assertion** — `SMOKE_TRAIL_FAULT=1` with `SMOKE_ONLY` on the nine 1b-2 pages → **all 9 FAIL**, each naming the injected
  uuid; `SMOKE_EXIT=1`.
- **Page probe** — four named injections, each red in its own assertion (`AT1B2_PROBE_EXIT=1` each): `m1-admin-only` → the "refused the
  order page" check; `typed-leak` → the SUP-2026-0003 typed-text check (and a customer page); `history-back` → both Q26 checks; `cjk` →
  the Chinese-interface comparison.

## §6 · Live verification

**Readings before / after** (`db/scripts/2026-09-30-at1b2-live-readings.sql`, `postgres`, `rolbypassrls = true`, 02:28:14 and 02:30:25
CST; `READ_OWN_EXIT=0` both times; the two outputs `diff` identical):

| reading | before | after |
|---|---|---|
| tables (excl. `change_log`) + digest of every row of every table | 241 · `6e6c6636ec24` | 241 · `6e6c6636ec24` |
| `change_log` | 1,752 rows, max seq 1,771 | 1,752 rows, max seq 1,771 |
| accounts | 7, 0 disabled | 7, 0 disabled |
| approvals | ON | ON |
| pending documents | 8 · `c113de0d5542` | 8 · `c113de0d5542` |
| purchase orders · quotes · sales orders · suppliers | 11 (last PO-2026-0011) · 3 · 6 · 17 | 11 (last PO-2026-0011) · 3 · 6 · 17 |
| history rows | 6 quote · 22 order · 0 supplier status · 17 approval | 6 quote · 22 order · 0 supplier status · 17 approval |

Reconciliation, as tim@ (`list_ledger_reconciliation()`), before and after: AP list 416,988.32 / ledger 376,404.42, AR list 57,545.87 /
ledger 43,002.12, **unexplained 0.00 on both sides**, both `agrees`. Every pending document still has a decider who is not its own party
(the migration's in-transaction proof ⑥ listed all eight). After the proof: QT-2026-0003, SO-2026-0005 and ZZ-AT1B2-PROOF do not exist.

**A · every live quote and sales order, read-only** (`db/scripts/2026-09-30-at1b2-live-proof.sql` part A; read as tim@, cfo):
**9 records · 28 old history rows · 28 found in the new trail · missing: none.** Each line the old History sections printed (rebuilt
from the same rows exactly as the old `page.tsx` printed them), beside the entry that now carries it:

```

### QT-2026-0001
  OLD  2026-08-15 22:47 · created · QT-2026-0001
  NEW  15/08/2026 22:47 · Tim · Quote created · 2 lines · 340.00 SGD Customer: Test Customer | Quotation date: 15/08/2026 | Valid until: 14/09/2026 | Currency: SGD | FX rate: 1 | Terms text: Payment within 30 days of delivery. | Notes: SO-4b walk | Line 1 · NMC Cathode Foil: 10 kg @ 28.00 SGD | Line 2 · Special Battery Material: 5 kg @ 12.00 SGD
  OLD  2026-08-15 22:48 · issued · v1
  NEW  15/08/2026 22:48 · Removed account · Quote issued to the customer (version 1) 
  OLD  2026-08-15 22:49 · converted to order · SO-2026-0004
  NEW  15/08/2026 22:49 · Tim · Quote converted to sales order SO-2026-0004 

### QT-2026-0002
  OLD  2026-09-08 23:15 · created · QT-2026-0002
  NEW  08/09/2026 23:15 · Tim · Quote created Customer: Test Customer | Quotation date: 08/09/2026 | Valid until: 08/10/2026 | Currency: SGD | FX rate: 1
  OLD  2026-09-08 23:15 · issued · v1
  NEW  08/09/2026 23:15 · Tim · Quote issued to the customer (version 1) 

### ZZ-SMOKE-QT-CJK
  OLD  2026-09-02 15:15 · created · ZZ-SMOKE-QT-CJK
  NEW  02/09/2026 15:15 · Tim · Quote created Customer: 上海金属回收有限公司 | Quotation date: 02/09/2026 | Valid until: 02/10/2026 | Currency: SGD | FX rate: 1 | Terms text: 付款条件:交货后 30 天内付清。Payment within 30 days of delivery. | Notes: 备注:本次报价含中文说明,用于验证字体栈 —— Mixed 中英文 test 12,345.67

### SO-2026-0001
  OLD  2026-08-14 00:37 · created · SO-2026-0001 【补记 · SO-2b 2026-08-14】建单时这一行被 RLS 拒(sales_order_history 没有客户端 INSERT 策略)且错误被丢弃,从未写入。此处按单据自己的 created_at / created_by 补记 —— 补的是一件确实发生过的事,日期与人都不是推断出来的。
  NEW  14/08/2026 00:37 · Removed account · Sales order created Customer: Test Customer-2 | Order date: 14/08/2026 | Currency: SGD | FX rate: 1 | Notes: SO-1-fu confirmation run
  OLD  2026-08-14 00:37 · confirmed
  NEW  14/08/2026 00:37 · Removed account · Sales order confirmed 
  OLD  2026-08-14 00:40 · issued · v1
  NEW  14/08/2026 00:40 · Removed account · Sales order issued to the customer (version 1) 
  OLD  2026-08-14 16:48 · reserved · line 1 · OUT-2026-0118 12 kg
  NEW  14/08/2026 16:48 · Removed account · Stock reserved Details: line 1 · OUT-2026-0118 12 kg
  OLD  2026-08-14 16:48 · released · line 1 · 12 · walk complete
  NEW  14/08/2026 16:48 · Removed account · Reservation released Details: line 1 · 12 · walk complete
  OLD  2026-08-14 20:29 · invoiced · INV-2026-0006
  NEW  14/08/2026 20:29 · Removed account · Invoiced · INV-2026-0006 
  OLD  2026-08-14 20:29 · invoice voided · INV-2026-0006 · SO-3a walk complete
  NEW  14/08/2026 20:29 · Removed account · Invoice voided · INV-2026-0006  | Reason: SO-3a walk complete
  OLD  2026-08-14 23:12 · invoiced · INV-2026-0007
  NEW  14/08/2026 23:12 · Removed account · Invoiced · INV-2026-0007 
  OLD  2026-08-14 23:13 · reserved · line 1 · OUT-2026-0118 12 kg
  NEW  14/08/2026 23:13 · Removed account · Stock reserved Details: line 1 · OUT-2026-0118 12 kg
  OLD  2026-08-14 23:13 · shipped · SHP-2026-0001 · 12/12
  NEW  14/08/2026 23:13 · Removed account · Goods shipped · SHP-2026-0001 Details: 12/12
  OLD  2026-08-15 19:29 · credit note raised · CN-2026-0001 · SGD 50 · walk
  NEW  15/08/2026 19:29 · Tim · Credit note raised · CN-2026-0001 Details: SGD 50 · walk
  OLD  2026-08-17 19:33 · issued · v2
  NEW  17/08/2026 19:33 · Tim · Sales order issued to the customer (version 2) 

### SO-2026-0002
  OLD  2026-08-14 17:56 · created · SO-2026-0002
  NEW  14/08/2026 17:56 · Removed account · Sales order created · 1 line · 34.50 SGD Customer: ST Engineering | Order date: 14/08/2026 | Currency: SGD | FX rate: 1 | Notes: SO-2b creation walk — will be cancelled | Line 1 · NMC Cathode Foil: 1 kg @ 34.50 SGD
  OLD  2026-08-14 17:56 · cancelled · creation walk
  NEW  14/08/2026 17:56 · Removed account · Sales order cancelled  | Reason: creation walk

### SO-2026-0003
  OLD  2026-08-15 17:40 · created · SO-2026-0003
  NEW  15/08/2026 17:40 · Tim · Sales order created · 2 lines · 200.00 SGD Customer: Test Customer | Order date: 15/08/2026 | Currency: SGD | FX rate: 1 | Line 1 · NMC Cathode Foil: 10 kg @ 10.00 SGD | Line 2 · Special Battery Material: 20 kg @ 5.00 SGD
  OLD  2026-08-15 17:41 · confirmed
  NEW  15/08/2026 17:41 · Tim · Sales order confirmed 
  OLD  2026-08-15 17:49 · reserved · line 1 · OUT-2026-0003 5 kg
  NEW  15/08/2026 17:49 · Tim · Stock reserved Details: line 1 · OUT-2026-0003 5 kg
  OLD  2026-08-15 17:54 · cancelled · This is an order just for testing
  NEW  15/08/2026 17:54 · Tim · Sales order cancelled [Reservation released] | Details: line 1 · 5 · order cancelled: This is an order just for testing | Reason: This is an order just for testing
  OLD  2026-08-15 17:54 · released · line 1 · 5 · order cancelled: This is an order just for testing
  NEW  15/08/2026 17:54 · Tim · Sales order cancelled [Reservation released] | Details: line 1 · 5 · order cancelled: This is an order just for testing | Reason: This is an order just for testing

### SO-2026-0004
  OLD  2026-08-15 22:49 · created · SO-2026-0004
  NEW  15/08/2026 22:49 · Tim · Sales order created from quote QT-2026-0001 · 2 lines · 340.00 SGD Customer: Test Customer | Order date: 15/08/2026 | Currency: SGD | FX rate: 1 | Terms text: Payment within 30 days of delivery. | Notes: SO-4b walk | Line 1 · NMC Cathode Foil: 10 kg @ 28.00 SGD | Line 2 · Special Battery Material: 5 kg @ 12.00 SGD
  OLD  2026-08-15 22:49 · converted from quote · QT-2026-0001
  NEW  15/08/2026 22:49 · Tim · Sales order created from quote QT-2026-0001 · 2 lines · 340.00 SGD Customer: Test Customer | Order date: 15/08/2026 | Currency: SGD | FX rate: 1 | Terms text: Payment within 30 days of delivery. | Notes: SO-4b walk | Line 1 · NMC Cathode Foil: 10 kg @ 28.00 SGD | Line 2 · Special Battery Material: 5 kg @ 12.00 SGD
  OLD  2026-08-15 22:49 · cancelled · quote walk
  NEW  15/08/2026 22:49 · Tim · Sales order cancelled  | Reason: quote walk

### ZZ2B-SO1

### ZZ2B-SO2

old history rows 28 · each found inside an entry 28
```

**Differences from the old sections, all deliberate:** dates `DD/MM/YYYY` (Q15); a `created` row's detail — the document's own number —
is not repeated, and SO-2026-0001's back-fill note written in Chinese by a migration is not shown (Q8,
`AT1B2-SO-CREATED-BACKFILL-NOTE`); rows written in one operation share one entry (SO-2026-0004's creation and "converted from quote";
SO-2026-0003's cancellation and its reservation release); each entry now names who ("Removed account" where the writer was a
since-deleted account); ZZ2B-SO1 / ZZ2B-SO2, which had no history rows, now show their creation.

**B · a quote, a sales order and a supplier of my own, created, changed and read inside one rolled-back transaction** (part B): the
quote and order written as admin@; the supplier raised and submitted by sandra@ (cco) and approved by tim@ — only Tim's two accounts
hold `action.supplier_approve`, and the first attempt, approving as tim@ a supplier admin@ had raised, stopped at
`SELF_APPROVAL_FORBIDDEN|raiser` (admin@ and tim@ are the same person) and rolled back. The three trails, read as tim@ (a signed-in
account) and rendered with `lib/trail/render.ts`:

```

### quote quote (proof) — 10 rows, 1 entries
  30/09/2026 02:30  Tim        Quote created · 1 line · 280.00 SGD
                              Customer: Test Customer
                              Quotation date: 30/09/2026
                              Valid until: 30/10/2026
                              Currency: SGD
                              FX rate: 1
                              Line 1 · NMC Cathode Foil: 10 kg @ 28.00 SGD
                              [Line changed · Line 1 · NMC Cathode Foil]
                              Quantity: 10 kg → 12 kg
                              [Quote issued to the customer (version 1)]
                              [Quote details changed]
                              Notes: (empty) → AT-1b-2 live proof — rolled back

### sales_order sales_order (proof) — 7 rows, 1 entries
  30/09/2026 02:30  Tim        Sales order created · 1 line · 345.00 SGD
                              Customer: Test Customer
                              Order date: 30/09/2026
                              Currency: SGD
                              FX rate: 1
                              Notes: AT-1b-2 live proof — rolled back
                              Line 1 · NMC Cathode Foil: 10 kg @ 34.50 SGD
                              [Sales order confirmed]
                              [Sales order amended · line changed · Line 1]
                              Quantity: 10 → 8
                              Reason: Customer takes 8 kg

### supplier supplier (proof) — 9 rows, 1 entries
  30/09/2026 02:30  Sandra     Supplier created
                              Legal name: AT-1b-2 proof supplier (rolled back)
                              What this company is: Goods supplier
                              Country: SG
                              Supplies goods: Yes
                              [Supplier submitted for review]
                              Note: Ready for review
                              [Supplier approved]
                              Note: Licence checked
                              [Compliance certificate added · Basel Convention · «PROOF-001»]
                              Valid from: 30/09/2026
                              Valid until: 30/09/2027
                              [Supplier details changed]
                              Notes: (empty) → AT-1b-2 live proof — rolled back
```

One transaction is one operation to the reader (Q2), so each record reads as one entry, headed by its most important event, with the
rest as sub-headings; for the same reason the supplier entry names one person (Sandra) although Tim approved inside it — in real use
the approval is its own operation and its own entry.

## §7 · Broken window

**Start: 2026-09-30 01:06:27 CST** (the commit time; `db/migration-windows.tsv`). **End: when you see the Vercel deploy succeed** — that
reading comes from you, not from this machine.

**What is broken inside it: nothing.** The migration replaced four functions in place with the same signatures and took no table lock.
The old app calls `record_trail` only with the ten subjects of 1b-1 and unchanged arguments; the eleven new subjects do not exist for it.
The old quote and order pages still read `quote_history` / `sales_order_history` for their History sections. **Early, and intended:**
on `/settings/change-history` the Record column of reservations, shipment lines and order history rows now names their order or shipment
(decision 7).

## §8 · Decisions I took without asking

Each is also recorded where it lives in the code.

**Registry and pre-log**
1. **An order's and a quote's own creation is registered alongside its history's `created` row**, not instead of it. Step 0 §a said
   "keep one source" to avoid showing an event twice; measured on live, the creation stamp and the history row carry the **same
   timestamp** on every order and quote (same transaction), so they group into one entry and the renderer folds them into one
   sentence — nothing shows twice — and the two live orders that have no history at all (ZZ2B-SO1 / ZZ2B-SO2) get a creation entry
   instead of "Nothing has been recorded". Fixture 239 D asserts the fold and the absence of duplicates.
2. **The PDF issue tables (`qt_issues`, `so_issues`) are not registered before the log**, as Step 0 §a ruled. Measured consequence:
   QT-2026-0001's second issue (v2) has no history row (`record_qt_issue` writes one only on the draft → issued transition), so its
   pre-log trail says version 1 only; the page's "Issued versions" list still shows both. `AT1B2-PRELOG-QUOTE-REISSUE`.
3. **`suppliers.approved_at` is registered as a stamp** — suppliers approved before ROLE-1 Batch 2a (24/09) have no status history or
   approval row. Later approvals write all three in one transaction and fold into one sentence.
4. **Typed text in a title** (file names, contact names, document types, certificate numbers) is the entry's `titlePart` / a heading's
   `part`, rendered in the `data-trail-typed` span — not spliced into the wording. Found by measurement: the supplier attachment
   "Screenshot 2026-06-28 at 5.49.23 PM.png" read as a machine token (a date) in a title. Applied to 1b-1's batch attachments too
   (same renderer, same latent problem; 1 finance attachment live).
5. **Shared-renderer fixes on 1b-1 pages:** work-order amendment lines printed "quantity: 10 → 8" (a generated "New quantity" minus
   "New "); now capitalised. The new golden arm (§5) caught the same shape in the sales-order describer first.
6. **`statement_issues` is a customer member** (under its statement). Step 0 §a lists "statements"; their PDF issues are part of them.
   Finance-only, like the statements.
7. **Reservations, shipment lines and the order history now have a home** (the order / the shipment). Before, they had none, so the
   Change history page's Record column fell back to the first document column (a batch). That column now names the order or shipment.
8. **Materials carry their unit** in `trail_ref_label` (only when the image has one) — order and quote lines have no unit column, so
   "10" reads "10 kg". Fixture 236 P6 (a material known only from a name-only image) is unchanged.
9. **Creation entries list fields in the page's order** (`FIELD_ORDER`, 1b-2 tables only) instead of jsonb key order (which is by key
   length, so "Notes" came first); **quote and order creation carry the line count and total** like a PO ("· 2 lines · 340.00 SGD";
   omitted when any price is restricted or the currency is unknown).

**Wording**
10. **History `detail` strings**: a leading document number goes into the title ("Goods shipped · SHP-2026-0001"); the rest is a
    "Details" line, or the reason (a voided invoice, a cancellation), shown as written. A `created` row's detail is not shown — it is
    the document's own number, or on SO-2026-0001 a back-fill note written in Chinese by a migration (Q8). `AT1B2-SO-CREATED-BACKFILL-NOTE`.
11. **On the order page, a history row is the event** and the rows written in the same operation are not said again: the order row's
    notes/terms beside a `header_update`, line rows beside a line amendment, reservations beside `reserved` / `released` / `shipped`, the
    issue row beside `issued`, the status beside `confirmed` / `closed` / `cancelled`.
12. **A supplier's approval decision folds silently into the status sentence** ("Supplier approved", reason = the note) — the approval
    row would only repeat it. Shipping-release approvals keep their note line (it carries the level).
13. **Free text read as free text:** a contact's role and a container / lane document type are typed inputs on their pages, not
    enums — shown as written (`KIND_OVERRIDES`).
14. **Hidden:** attachments' MIME type and size, issue hashes, the quote's and order's own number (in the page header). Shipment,
    statement and chase numbers stay visible — their entries name them.
15. **Label choices** (every one checked against the page that shows or edits it; §10): the form's label first, then the detail
    page's column; Title Case on the customer, supplier and compliance forms turned into sentence case ("Legal name", not "Legal Name");
    Step 0's named ones on 1b-2 tables fixed: contact `name` "File" → **Name**, container `code` "Container number" → **Container code**
    (`container_number` keeps "Container number"), commission `valid_to` "Valid" → **Valid to**, statement `base_currency` "By currency"
    → **Base currency** (and `by_currency` → "Amounts by currency"). Folded in: `journal_entries.code` → **Journal number**.

**Pages**
16. **List-level trails** read `record_trail` once per record (21 records on the lanes page today, in parallel), merge newest first
    with a Record column, include deleted records, and drop an entry shown identically by two records (a lane's creation belongs to
    the lane and to both its ports). The Record column has no link (these records have no page).
17. **A deleted commission agreement** keeps its existing "this agreement was deleted" page without a trail, and deleted suppliers /
    customers still 404: opening deleted master data is 1b-3's Q9.

**Tools and checks**
18. **`scripts/check-trail-wording.mjs` gained a sixth arm, ⑥ 商务样例**: for every 1b-2 subject a field edit, a child-line change and
    a key event are rendered and compared word for word with the sentences in §10 (injection `wording-drift`); plus a sweep over every
    sales-order and quote history value, every supplier status move, credit, detachment and document state. `ListTrail.tsx` joined the
    files whose wording keys are counted.
19. **`scripts/probe-at1b2.mjs`** (new, the 1b-1 probe's shape): the warehouse account — `action.ship_goods` without
    `module.sales.view` — opens a shipment and its trail; the admin opens all nine pages; the History sections are gone; typed text
    stays typed; the Chinese interface leaves the trail untouched.
20. **The live proof** writes as admin@ (all codes) and reads as tim@; tim@ also approves the proof supplier, because its creator
    cannot. `db/scripts/2026-09-30-at1b2-live-readings.sql` / `…-live-proof.sql` are committed.
21. **The quote-page overflow at 390 px (+8 px) is pre-existing** and not fixed here — measured before and after (§4, the layout survey row);
    `AT1B2-QUOTE-PAGE-390-OVERFLOW`.

**Found by the live proof, fixed in this cut** (one transaction is one operation; each was reproduced in arm ⑥ before the fix)
22. **A line changed in the same operation as a quote's or order's creation** was swallowed by the creation entry; it is now listed
    under it ("Line changed · Line 1 · NMC Cathode Foil"), the rule the purchase-order creation already follows.
23. **A block's sub-heading could lose what happened**: when another event heads the entry, a block's own title is its sub-heading —
    and a block that began with a bare "Line 1" heading lost its title ("Sales order amended"). Line blocks now carry the line in their
    title ("Line changed · Line 1 · …", "Sales order amended · line changed · Line 1").
24. **Several supplier status steps in one operation** read as one step with a single reason. Each step is now its own block; with
    several steps each step's note is a "Note" line; an absorbed approval no longer copies its note into the reason.

## §9 · Step 0 labels: which were fixed in 1b-2, which are left for 1b-3

| Step 0 label | table | first page | fixed in |
|---|---|---|---|
| "File" on a contact's name | `counterparty_contacts.name` | customer page, supplier edit page | **1b-2** → "Name" |
| "Container number" on two columns | `containers.code` / `.container_number` | container page | **1b-2** → `code` "Container code"; `container_number` stays "Container number" |
| "Valid" | `commission_agreements.valid_to` | commission edit page | **1b-2** → "Valid to" |
| "By currency" | `customer_statements.base_currency` | customer page | **1b-2** → "Base currency" (`by_currency` → "Amounts by currency") |
| "Make this a team task" | `task_nodes.task_id` / `task_participants.task_id` | task page | **1b-3** (queued in `docs/forward-queue.md`) |
| "Choose a source" | `metal_prices.source` | metal price edit page | **1b-3** |
| "Wo input overrun %" | `processing_settings.wo_input_overrun_pct` | threshold panel | **1b-3** |
| "Notes en" | `pricing_settings.notes_en` | threshold panel | **1b-3** |

Folded in (your ruling): `journal_entries.code` "Journal entrie number" → **"Journal number"**, and 1b-1's hand-back corrected where it
listed that label as correct and where it said "60" overrides (measured: 91).

## §10 · For Tim to review: every wording and field label this cut adds (Q9 · Q11)

**Wordings added in 1b-2 (`lib/trail/text.ts`)** — one removed: `so.changed` ("Sales order changed", 1b-1), replaced by the `so.*` event wordings.

| key | wording |
|---|---|
| `label.details` | Details |
| `qt.created` | Quote created |
| `qt.issued` | Quote issued to the customer (version {version}) |
| `qt.issuedPlain` | Quote issued to the customer |
| `qt.declined` | Quote declined |
| `qt.converted` | Quote converted to sales order {code} |
| `qt.convertedPlain` | Quote converted to a sales order |
| `qt.statusChanged` | Quote status changed |
| `qt.edited` | Quote details changed |
| `qt.deleted` | Quote deleted |
| `so.created` | Sales order created |
| `so.createdFromQuote` | Sales order created from quote {code} |
| `so.confirmed` | Sales order confirmed |
| `so.closed` | Sales order closed |
| `so.cancelled` | Sales order cancelled |
| `so.deleted` | Sales order deleted |
| `so.statusChanged` | Sales order status changed |
| `so.edited` | Sales order details changed |
| `so.issued` | Sales order issued to the customer (version {version}) |
| `so.issuedPlain` | Sales order issued to the customer |
| `so.reserved` | Stock reserved |
| `so.released` | Reservation released |
| `so.invoiced` | Invoiced |
| `so.invoiceVoided` | Invoice voided |
| `so.shipped` | Goods shipped |
| `so.creditNoted` | Credit note raised |
| `so.amended` | Sales order amended |
| `so.headerChanged` | Notes and terms changed |
| `so.releaseRequested` | Shipping release requested |
| `so.releaseApproved` | Shipping release approved |
| `so.releaseRejected` | Shipping release rejected |
| `so.releaseWithdrawn` | Shipping release withdrawn |
| `so.releaseChanged` | Shipping release updated |
| `shp.created` | Goods shipped |
| `shp.edited` | Shipment details changed |
| `shp.lineAdded` | Shipment line added |
| `shp.containerSet` | Loaded into container |
| `shp.containerCleared` | Taken out of container |
| `shp.issued` | Delivery note issued (version {version}) |
| `contact.added` | Contact added |
| `contact.changed` | Contact changed |
| `contact.removed` | Contact removed |
| `att.changed` | Attachment details changed |
| `cus.created` | Customer created |
| `cus.edited` | Customer details changed |
| `cus.statusChanged` | Customer status changed |
| `cus.deleted` | Customer deleted |
| `cus.creditChanged` | Credit settings changed |
| `cus.limitChanged` | Credit limit changed |
| `cus.holdOn` | Credit hold placed — shipments frozen |
| `cus.holdOff` | Credit hold lifted |
| `cus.statementIssued` | Statement of account issued |
| `cus.statementSuperseded` | Statement of account superseded |
| `cus.statementPdf` | Statement PDF issued (version {version}) |
| `cus.chased` | Payment chased |
| `cus.chaseSuperseded` | Chase record corrected |
| `cus.promise` | Payment promised |
| `cus.promiseOutcome` | Promise outcome recorded |
| `cm.created` | Commission agreement created |
| `cm.edited` | Commission agreement changed |
| `cm.deleted` | Commission agreement deleted |
| `sup.created` | Supplier created |
| `sup.edited` | Supplier details changed |
| `sup.deleted` | Supplier deleted |
| `sup.submitted` | Supplier submitted for review |
| `sup.approved` | Supplier approved |
| `sup.rejected` | Supplier rejected |
| `sup.activated` | Supplier activated |
| `sup.suspended` | Supplier suspended |
| `sup.reinstated` | Supplier reinstated |
| `sup.blacklisted` | Supplier blacklisted |
| `sup.archived` | Supplier archived |
| `sup.restored` | Supplier taken out of the archive |
| `sup.backToDraft` | Supplier returned to draft |
| `sup.statusChanged` | Supplier status changed |
| `sup.certAdded` | Compliance certificate added |
| `sup.certChanged` | Compliance certificate changed |
| `sup.certRemoved` | Compliance certificate removed |
| `fwd.created` | Forwarder created |
| `fwd.edited` | Forwarder details changed |
| `fwd.deleted` | Forwarder deleted |
| `fwd.detailsSet` | Logistics details recorded |
| `fwd.detailsChanged` | Logistics details changed |
| `fwd.quoteAdded` | Rate quote added |
| `fwd.quoteChanged` | Rate quote changed |
| `fwd.quoteRemoved` | Rate quote removed |
| `ctr.created` | Container created |
| `ctr.edited` | Container details changed |
| `ctr.deleted` | Container deleted |
| `ctr.milestone` | Milestone recorded |
| `ctr.detached` | Shipment {code} taken out of this container |
| `ctr.docAdded` | Document added to the checklist |
| `ctr.docReceived` | Document received |
| `ctr.docNa` | Document marked not applicable |
| `ctr.docPending` | Document marked pending again |
| `ctr.docChanged` | Document changed |
| `ctr.docRemoved` | Document removed from the checklist |
| `lane.created` | Lane created |
| `lane.edited` | Lane changed |
| `lane.deleted` | Lane removed |
| `lane.reviewed` | Document checklist reviewed |
| `lane.reqAdded` | Required document added |
| `lane.reqChanged` | Required document changed |
| `lane.reqRemoved` | Required document removed |
| `port.created` | Port added |
| `port.edited` | Port changed |
| `port.deleted` | Port removed |
| `lic.created` | Licence recorded |
| `lic.edited` | Licence changed |
| `lic.statusChanged` | Licence standing changed |
| `lic.deleted` | Licence removed |
| `listTrail.intro.lanes` | Lanes, ports and their document checklists · newest first · Singapore time |
| `listTrail.intro.licences` | Company licences · newest first · Singapore time |
| `listTrail.empty` | Nothing has been recorded here yet. |

(114 keys)

**Field labels on the 38 tables this cut shows** (ids, stamps, hashes and sequence columns never appear). Changed on tables outside this cut: `journal_entries.code` "Journal entrie number" → **Journal number**; `sales_order_history.line_no` "Line number" → **Line**, `.detail` "Detail" → **Details** (they read on the output-batch page too).

| record type | field (column) | label |
|---|---|---|
| quote | converted_order_id | Converted to |
| quote | currency | Currency |
| quote | customer_id | Customer |
| quote | decline_reason | Reason declined |
| quote | delete_reason | Reason for deletion |
| quote | deleted_at | Deleted on |
| quote | deleted_by | Deleted by |
| quote | fx_rate | FX rate |
| quote | notes | Notes |
| quote | quote_date | Quotation date |
| quote | status | Status |
| quote | terms_text | Terms text |
| quote | valid_until | Valid until |
| quote line | line_no | Line |
| quote line | material_id | Material |
| quote line | notes | Notes |
| quote line | price_provenance | How the price was set |
| quote line | price_source | Price source |
| quote line | quantity | Quantity |
| quote line | quote_id | Quote |
| quote line | unit_price | Unit price |
| quote PDF issue | issued_at | Issued on |
| quote PDF issue | issued_by | Issued by |
| quote PDF issue | quote_id | Quote |
| quote event | detail | Details |
| sales order | cancel_reason | Cancellation reason |
| sales order | cancelled_at | Cancelled on |
| sales order | closed_at | Closed on |
| sales order | confirmed_at | Confirmed on |
| sales order | contract_id | Contract |
| sales order | currency | Currency |
| sales order | customer_id | Customer |
| sales order | delete_reason | Reason for deletion |
| sales order | deleted_at | Deleted on |
| sales order | deleted_by | Deleted by |
| sales order | fx_rate | FX rate |
| sales order | notes | Notes |
| sales order | order_date | Order date |
| sales order | status | Status |
| sales order | terms_text | Terms text |
| sales order line | line_no | Line |
| sales order line | material_id | Material |
| sales order line | notes | Notes |
| sales order line | price_provenance | How the price was set |
| sales order line | price_source | Price source |
| sales order line | quantity | Quantity |
| sales order line | sales_order_id | Sales order |
| sales order line | unit_price | Unit price |
| sales order reservation | consumed_at | Consumed on |
| sales order reservation | consumed_by | Consumed by |
| sales order reservation | location_id | Storage location |
| sales order reservation | output_batch_id | Output batch |
| sales order reservation | qty | Quantity |
| sales order reservation | release_reason | Release reason |
| sales order reservation | released_at | Released on |
| sales order reservation | released_by | Released by |
| sales order reservation | sales_order_line_id | Sales order line |
| shipping release | amount_base | Invoiced amount |
| shipping release | decided_at | Decided on |
| shipping release | decided_by | Decided by |
| shipping release | decision_notes | Decision notes |
| shipping release | label | Release |
| shipping release | sales_order_id | Sales order |
| shipping release | status | Status |
| shipping release | withdraw_reason | Withdraw reason |
| shipping release | withdrawn_at | Withdrawn on |
| shipping release | withdrawn_by | Withdrawn by |
| shipping release line | invoice_line_id | Invoice line |
| shipping release line | release_id | Shipping release |
| shipping release line | sales_order_line_id | Sales order line |
| sales order PDF issue | issued_at | Issued on |
| sales order PDF issue | issued_by | Issued by |
| sales order PDF issue | sales_order_id | Sales order |
| sales order change | amend_reason | Reason |
| sales order change | detail | Details |
| sales order change | line_no | Line |
| sales order change | new_notes | New notes |
| sales order change | new_quantity | New quantity |
| sales order change | new_terms_text | New terms text |
| sales order change | new_unit_price | New unit price |
| sales order change | old_notes | Previous notes |
| sales order change | old_quantity | Previous quantity |
| sales order change | old_terms_text | Previous terms text |
| sales order change | old_unit_price | Previous unit price |
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
| shipment | code | Shipment number |
| shipment | container_id | Container |
| shipment | notes | Notes |
| shipment | sales_order_id | Sales order |
| shipment | ship_date | Shipped on |
| shipment line | location_id | Location |
| shipment line | output_batch_id | Output batch |
| shipment line | qty | Quantity |
| shipment line | reservation_id | Reservation |
| shipment line | sales_order_line_id | Sales order line |
| shipment line | sales_record_id | Sales record |
| shipment line | shipment_id | Shipment |
| delivery note issue | issued_at | Issued on |
| delivery note issue | issued_by | Issued by |
| delivery note issue | shipment_id | Shipment |
| customer | address | Address |
| customer | code | Customer number |
| customer | country | Country |
| customer | credit_hold | Credit hold |
| customer | credit_limit_base | Credit limit |
| customer | credit_rating | Credit rating |
| customer | customer_types | Customer types |
| customer | default_tax_code | Default tax code |
| customer | deleted_at | Deleted on |
| customer | incoterm | Incoterm |
| customer | legal_name | Legal name |
| customer | notes | Notes |
| customer | payment_terms | Payment terms |
| customer | payment_terms_days | Payment terms (days) |
| customer | short_name | Short name |
| customer | status | Status |
| customer | tax_id | Tax ID |
| contact | customer_id | Customer |
| contact | deleted_at | Removed on |
| contact | email | Email |
| contact | is_primary | Primary contact |
| contact | name | Name |
| contact | name_inferred | Name taken from older records |
| contact | notes | Notes |
| contact | phone | Phone |
| contact | role | Role |
| contact | supplier_id | Supplier |
| customer attachment | customer_id | Customer |
| customer attachment | deleted_at | Deleted on |
| customer attachment | doc_category | Category |
| customer attachment | file_name | File |
| customer attachment | notes | Notes |
| credit change | new_credit_hold | Credit hold |
| credit change | new_credit_limit_base | Credit limit |
| credit change | old_credit_hold | Previous credit hold |
| credit change | old_credit_limit_base | Previous credit limit |
| statement of account | base_currency | Base currency |
| statement of account | buckets | Ageing |
| statement of account | by_currency | Amounts by currency |
| statement of account | charges_base | Charges |
| statement of account | closing_base | Closing balance |
| statement of account | code | Customer statement number |
| statement of account | credits_base | Credits |
| statement of account | customer_id | Customer |
| statement of account | issued_at | Issued on |
| statement of account | issued_by | Issued by |
| statement of account | lines | Statement lines |
| statement of account | opening_base | Opening balance |
| statement of account | period_end | Period end |
| statement of account | period_start | Period start |
| statement of account | receipts_base | Receipts |
| statement of account | superseded_at | Superseded on |
| statement of account | superseded_by | Superseded by |
| statement of account | superseded_reason | Reason superseded |
| statement PDF issue | issued_at | Issued on |
| statement PDF issue | issued_by | Issued by |
| statement PDF issue | statement_id | Statement |
| payment chase | base_currency | Base currency |
| payment chase | channel | Channel |
| payment chase | chased_by | Chased by |
| payment chase | chased_on | Chased on |
| payment chase | code | Collection chase number |
| payment chase | contacted_person | Contact person |
| payment chase | customer_id | Customer |
| payment chase | net_due_base | Net due |
| payment chase | on_account_base | On account |
| payment chase | owed_base | Owed |
| payment chase | owed_buckets | Owed by age |
| payment chase | owed_by_currency | Owed by currency |
| payment chase | reached | Reached the customer |
| payment chase | summary | What was said |
| payment chase | superseded_at | Corrected on |
| payment chase | superseded_by | Corrected by |
| payment chase | superseded_reason | Reason corrected |
| chased document | chase_id | Chase |
| chased document | subject_type | Document type |
| payment promise | chase_id | Chase |
| payment promise | currency | Currency |
| payment promise | fx_rate | FX rate |
| payment promise | outcome | Outcome |
| payment promise | outcome_note | Outcome note |
| payment promise | outcome_recorded_at | Outcome recorded on |
| payment promise | outcome_recorded_by | Outcome recorded by |
| payment promise | promised_amount_base | Promised amount (base currency) |
| payment promise | promised_amount_ccy | Promised amount |
| payment promise | promised_date | Promised date |
| commission agreement | agent_supplier_id | Agent |
| commission agreement | amount_ccy | Amount |
| commission agreement | basis | Basis |
| commission agreement | currency | Currency |
| commission agreement | deleted_at | Deleted on |
| commission agreement | rate_pct | Rate (%) |
| commission agreement | recognition_trigger | Obligation arises |
| commission agreement | remarks | Clause / remarks |
| commission agreement | side | Which side it attaches to |
| commission agreement | valid_from | Valid from |
| commission agreement | valid_to | Valid to |
| supplier | address | Address |
| supplier | approved_at | Approved on |
| supplier | approved_by | Approved by |
| supplier | code | Supplier number |
| supplier | counterparty_type | What this company is |
| supplier | country | Country |
| supplier | credit_rating | Credit rating |
| supplier | default_payment_term_template_id | Default payment terms |
| supplier | default_tax_code | Default tax code |
| supplier | deleted_at | Deleted on |
| supplier | incoterm | Incoterm |
| supplier | legal_name | Legal name |
| supplier | notes | Notes |
| supplier | owner_id | Owner |
| supplier | payment_terms | Payment terms |
| supplier | short_name | Short name |
| supplier | status | Status |
| supplier | supplier_types | Supplier types |
| supplier | supplies_goods | Supplies goods |
| supplier | tax_id | Tax ID |
| supplier | tax_residence | Tax residence (Singapore income tax) |
| compliance certificate | cert_no | Certificate number |
| compliance certificate | cert_type_code | Certificate type |
| compliance certificate | deleted_at | Deleted on |
| compliance certificate | document_id | Certificate document |
| compliance certificate | issuing_body | Issuing body |
| compliance certificate | notes | Notes |
| compliance certificate | supplier_id | Supplier |
| compliance certificate | valid_from | Valid from |
| compliance certificate | valid_until | Valid until |
| supplier attachment | deleted_at | Deleted on |
| supplier attachment | doc_category | Category |
| supplier attachment | file_name | File |
| supplier attachment | notes | Notes |
| supplier attachment | supplier_id | Supplier |
| supplier status change | from_status | Previous status |
| supplier status change | note | Note |
| supplier status change | to_status | New status |
| container | bl_number | B/L number |
| container | code | Container code |
| container | container_number | Container number |
| container | delete_reason | Reason for deletion |
| container | deleted_at | Deleted on |
| container | deleted_by | Deleted by |
| container | departure_date | Departure date |
| container | expected_arrival_date | Expected arrival |
| container | forwarder_id | Forwarder |
| container | lane_id | Lane |
| container | notes | Notes |
| container | vessel | Vessel |
| container | voyage | Voyage |
| container milestone | container_id | Container |
| container milestone | event_date | Date it happened |
| container milestone | milestone | Milestone |
| container milestone | note | Note |
| container milestone | recorded_at | Recorded on |
| container milestone | recorded_by | Recorded by |
| container document | container_id | Container |
| container document | document_type | Document type |
| container document | from_lane | From lane checklist |
| container document | na_reason | Why not applicable |
| container document | notes | Notes |
| container document | regime | Regime |
| container document | status | Status |
| forwarder logistics details | dg_classes | Dangerous-goods classes handled |
| forwarder logistics details | free_time_terms | Free-time terms |
| forwarder logistics details | main_routes | Main routes |
| forwarder logistics details | notes | Notes |
| forwarder logistics details | ports_served | Ports served |
| forwarder logistics details | supplier_id | Forwarder |
| rate quote | amount_ccy | Amount |
| rate quote | currency | Currency |
| rate quote | deleted_at | Deleted on |
| rate quote | free_days | Free days |
| rate quote | lane_id | Lane |
| rate quote | notes | Notes |
| rate quote | supplier_id | Forwarder |
| rate quote | valid_from | Valid from |
| rate quote | valid_to | Valid to |
| lane | checklist_reviewed_at | Checklist reviewed on |
| lane | deleted_at | Removed on |
| lane | destination_port_id | Destination port |
| lane | origin_port_id | Origin port |
| required lane document | deleted_at | Removed on |
| required lane document | document_type | Document type |
| required lane document | lane_id | Lane |
| required lane document | notes | Notes |
| required lane document | regime | Regime |
| port | code | Port code |
| port | country | Country |
| port | deleted_at | Removed on |
| port | name | Port name |
| company licence | approved_storage_limit_tonnes | Approved storage limit (tonnes) |
| company licence | cert_no | Licence number |
| company licence | cert_type_code | Licence kind |
| company licence | deleted_at | Deleted on |
| company licence | issue_date | Issue date |
| company licence | issuing_body | Issuing body |
| company licence | notes | Notes |
| company licence | scope | Conditions and scope |
| company licence | status | Standing |
| company licence | valid_from | Valid from |
| company licence | valid_until | Valid until |

(311 shown columns on 38 tables; 153 hidden)

**Value labels on these tables**

| field | values |
|---|---|
| quotes · status | draft → Draft; issued → Issued; declined → Declined; converted → Converted to an order |
| quote_lines · price_source | computed → Calculated; manual → Entered by hand |
| quote_history · change_type | created → Created; issued → Issued; declined → Declined; converted → Converted to an order |
| sales_orders · status | draft → Draft; confirmed → Confirmed; partially_shipped → Partially shipped; shipped → Shipped; closed → Closed; cancelled → Cancelled |
| sales_order_lines · price_source | computed → Calculated; manual → Entered by hand |
| shipping_releases · status | submitted → Waiting for approval; approved → Approved; rejected → Rejected; withdrawn → Withdrawn |
| customers · customer_types | cathode_maker → Cathode material maker; battery_factory → Battery factory; trader → Trader; other → Other |
| customers · status | draft → Draft; active → Active; inactive → Inactive |
| customer_attachments · doc_category | hazardous-waste-permit → Hazardous waste permit; import-license → Import licence; export-license → Export licence; basel-document → Basel document; contract → Contract; other → Other |
| collection_chases · channel | phone → Phone; email → Email; whatsapp → WhatsApp; in_person → In person; letter → Letter |
| collection_chase_documents · subject_type | sales_record → Sale; invoice → Invoice; statement → Statement |
| collection_promises · outcome | kept → Kept — the money arrived; broken → Broken — it did not; renegotiated → Renegotiated; cancelled → Cancelled |
| commission_agreements · basis | percentage_of_value → Percentage of value; per_tonne → Per tonne; fixed_amount → Fixed amount |
| commission_agreements · recognition_trigger | on_shipment → On shipment; on_invoice → On invoice; on_counterparty_payment → On counterparty payment |
| commission_agreements · side | purchase → Purchase side; sale → Sale side; free_standing → Free-standing |
| suppliers · counterparty_type | goods_supplier → Goods supplier; forwarder → Forwarder / carrier; service_vendor → Service vendor |
| suppliers · status | draft → Draft; pending_review → Pending review; approved → Approved; rejected → Rejected; active → Active; suspended → Suspended; blacklisted → Blacklisted; archived → Archived |
| suppliers · supplier_types | dismantler → Dismantler; battery_factory_scrap → Battery plant scrap; recycler → Recycler; trader → Trader; equipment_vendor → Equipment vendor |
| suppliers · tax_residence | resident → Singapore tax resident; non_resident → Non-resident |
| supplier_attachments · doc_category | hazardous-waste-permit → Hazardous waste permit; import-license → Import licence; export-license → Export licence; basel-document → Basel document; contract → Contract; other → Other |
| supplier_status_history · from_status | draft → Draft; pending_review → Pending review; approved → Approved; rejected → Rejected; active → Active; suspended → Suspended; blacklisted → Blacklisted; archived → Archived |
| supplier_status_history · to_status | draft → Draft; pending_review → Pending review; approved → Approved; rejected → Rejected; active → Active; suspended → Suspended; blacklisted → Blacklisted; archived → Archived |
| container_milestones · milestone | booked → Booked; gated_in → Gated in; loaded → Loaded; departed → Departed; arrived → Arrived; customs_cleared → Customs cleared; delivered → Delivered; other → Other |
| container_documents · status | pending → Pending; received → Received; not_applicable → Not applicable |
| company_compliance · status | active → Active; suspended → Suspended; revoked → Revoked |

## §11 · Docs

- **`docs/change-log.md`** — §9 intro and table (eleven subjects), §9.5 (quotes and orders before the log; suppliers' approval stamp),
  §9.6 (a record with no page — `ListTrail`), §9.7 (typed title parts; history `detail`), §9.8 (fixture 239, arm ⑥, probe), §9.9 (M1 and
  M3 first real users).
- **`docs/forward-queue.md`** — item 24 (1b-1's window); AT-1b-2 ✅; the Step 0 labels on 1b-3 tables queued under 1b-3.
- **`docs/known-issues.md`** — `AT1B2-PRELOG-QUOTE-REISSUE` · `AT1B2-SO-CREATED-BACKFILL-NOTE` · `AT1B2-QUOTE-PAGE-390-OVERFLOW`.
- **`docs/handbacks/AUDIT-TRAIL-1b-1.md`** — the two corrections (§1 h).
