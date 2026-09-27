# APR-10 — a GST return waits for the CFO's approval of its figures; purchase orders are raised by category (2026-09-27)

Tim's matrix (`docs/role-matrix.md` §2 GST filing · §6 raising a PO by category · amending, cancelling, closing): finance prepares
a GST return and the CFO approves it; a PO is raised by the category's holder, approval tiers unchanged. One cut — the stopping
line (ship GST as 10a and PO categories as 10b if `db/gate.py --offline` was not green with the GST half finished) did **not**
trigger. No version number assigned (standing ruling).

Identities throughout: live reads as `postgres` (`rolbypassrls = t`), base tables unless a view is named; views read as tim@
(`634c00f9…`, cfo) under `authenticated`; role holders counted from unrevoked grants only.

## §W · APR-9's broken window — closed with bounds, labelled by kind

Also written into `docs/handbacks/APR-9.md` §6. Tim confirmed APR-9 deployed (2026-09-27).

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-27 10:20:23 | **measured**: `db/migration-windows.tsv` |
| end, lower bound | 2026-09-27 11:05:58 | **measured**: the push moved `origin/main` → `aaed80f8` (`git reflog show --date=iso refs/remotes/origin/main`) |
| end, upper bound | 2026-09-27 11:15:59 | **derived**: this session's first read of `now()` as `postgres`, after Tim's "deployed" confirmation — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 45 min 35 s, at most 55 min 36 s.**
**Accepted by Tim (2026-09-27):** all eight APR-9 build decisions (`APR-9.md` §1), including decision 2 — reviews keep the
posted-period-only effective-date check; the stricter check stays on salary-change requests only.

## §0 · Step 0 (grilling) and Tim's answers

**Step 0 findings that shaped the cut** (live, `postgres`, base tables, 2026-09-27 11:15):
- **Filing a GST return never touched the ledger.** `file_gst_return` copied the F5 boxes into `gst_return_boxes` and set the
  period `filed`, gated on `locked_before > period_end`. So the control worth having is the CFO approving **the figures before they
  go to IRAS**, not a record of a filing already made. One live period, GST-2026-Q3 (open), 0 box rows; 1400 = 18.00 Dr, 2100 =
  102.87 Cr; Q3 F5 as tim@: box1 1,143.00 · box6 102.87 · box7 18.00 · box8 84.87.
- **The queued Batch 5 backfill would have mislabelled every PO.** 11 live POs: 6 buy battery feedstock (MAT-2026-0001/0002,
  up to 120,000.00), 5 buy FA-2026-0001/0002 — none a consumable.
- **Warehouse held no purchasing code at all** (`role_permissions`), so it could not even open the page to raise a consumables PO.
- The "no other decider" refusal closes the PO half of `ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE`.

**Tim's answers (2026-09-27):** Q1–Q6, Q8, Q9 as recommended; **Q7 ruled differently.**

| Q | ruling | where it landed |
|---|---|---|
| Q1 | the CFO approves the numbers before filing: finance submits (F5 boxes frozen), CFO approves (writes the snapshot), finance records the IRAS date + reference in one step, no approval | `submit_gst_filing_request` · `decide_gst_filing_request` · `gst_filing_execute_internal` · `record_gst_filing` |
| Q2 | opening an F7 stays one step with a reason; filing it goes through the same request, with the difference against the original's snapshot shown | `gst_filing_requests_visible.original_boxes`, the panel's two extra columns |
| Q3 | reopening any month in the quarter refused by name while a request waits; lock precondition and F5 fingerprint re-checked at approval | `guard_gst_filing_lock` (`GST_FILING_WAITING_BLOCKS_REOPEN`) · `GST_PERIOD_NOT_LOCKED` · `GST_RETURN_CHANGED_SINCE_REQUEST` |
| Q4 | APR-9 disposal pattern: level-2 registry row, `blocks_disable = true`, born approved when approvals are off | `approval_chain_gates` · `approval_pending_documents` |
| Q5 | backfill all 11 POs to `equipment_goods`; an asset or battery-material line means `equipment_goods`; otherwise the raiser chooses (replaces the Batch 5 backfill rule) | `purchase_orders.category` · `guard_po_line_category` |
| Q6 | three raise codes (warehouse / cco / finance), each also admin; `module.purchasing.edit` no longer raises; warehouse gains `module.purchasing.view`; cto loses raising | migration §1 grants · `create_purchase_order` |
| **Q7** | **amend, cancel, close and reopen: the raiser in person, OR anyone who currently holds that PO's category raise code; everyone else refused by name; approving keeps its gate** | `po_may_manage` · `assert_po_manager` (`PO_NOT_RAISER_OR_CATEGORY_HOLDER`) |
| Q8 | the category is fixed at creation; to change it, cancel and raise again | `guard_po_amendable` (`PO_FIELD_IMMUTABLE\|category`) |
| Q9 | a named `PO_CATEGORY_REQUIRED` during the broken window | `create_purchase_order(…, p_category DEFAULT NULL)` |

## §1 · What shipped

**Migration** `db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql` (built from mirrors by
`db/scripts/build_apr10_migration.py`, 3,693 lines). Its self-proof, in the same transaction: approvals on; grants = before +
exactly the seven ruled rows; pending set unchanged; approval_log / journal / GST periods and snapshots / POs (digest excluding the
new column) / PO lines, terms and history / the lock unchanged; `gst_filing_requests` empty; no write policy on it or on the four
PO tables; six guards; two internals not executable by `authenticated`; the GST chain row level 2 only; `create_purchase_order`
has exactly one signature; the GST chain has a decider; every raise code has a real holder; every pending document has a decider
who is not its own party.

**New table (1):** `gst_filing_requests` (RLS read only; no write policy; anon revoked). **New column:** `purchase_orders.category`
(CHECK, NOT NULL, no default; added with a transient default so the backfill fired no row triggers; column-granted; in
`purchase_orders_masked`). **`gst_periods`:** status gains `approved`; the filed-shape CHECK allows it.
**New codes (3):** `action.raise_po_consumables` · `action.raise_po_equipment` · `action.raise_po_office`.
**New functions (12):** `po_category_raise_code` · `po_may_manage` · `assert_po_manager` · `guard_po_line_category` ·
`guard_po_direct_write` · `gst_filing_execute_internal` · `submit_/decide_/withdraw_gst_filing_request` · `record_gst_filing` ·
`gst_filing_requests_visible` · `guard_gst_filing_lock`.
**Replaced (12):** `create_purchase_order` (DROP + CREATE: `p_category` added; raise code by category; other-decider check at the
PO's level) · `amend_/cancel_/close_/reopen_purchase_order` · `apply_payment_term_template` (all → `assert_po_manager`) ·
`guard_po_amendable` (category immutable) · `file_gst_return` (refusal only) · `record_approval_decision` ·
`approval_pending_documents` · `approval_chain_gates` · `approvals_readiness` (the fold-in below).
**Also:** `approval_log` subject CHECK + read-policy branch; `operations_now` arm `gst_filing_pending`; 12 PO write policies
dropped; six triggers.

**Screens:** see §6 (screen inventory). en + zh copy for all of it.

**Fold-in — `/settings/approvals`:** `approvals_readiness().pending_by_chain[].amount_unknown` counted every NULL amount, so salary
changes (routed by person) — and every fixed-level request — were described as "cannot be valued in the base currency yet, so they
cannot be routed to a level". It now counts only amount-routed chains (in the registry, no fixed level), and a new
`routed_by_person` flag gives salary changes their own line: en "(Routed by person, not by amount: the CFO decides, or the CCO when
the CFO is the one raising it or the one it is for.)" · zh「(按人路由,不按金额:CFO 决定;CFO 本人提的或调的是 CFO 自己时,由 CCO 决定。)」

**Fixtures:** new `229` (A registration · G GST lifecycle with approvals on · H F7 correction, withdraw, reject · J approvals off ·
P categories · Q Tim's Q7 · R no other decider · S no direct writes · K and L two fault injections, each proven load-bearing).
Changed: `128` (filing arms → request path; old door refuses) · `111` (47 arms) · `205` (level-2 chains 12 → 13) · `100`
(warehouse now reads `po_receivable_lines`, Q6) · `52` and `216` (direct PO writes now refused earlier; their row-guard arms run on
the owner path) · `33` `35` `36` `52` `216` (their PO-raising roles get the equipment raise code) · 41 fixtures pass
`p_category` / insert `category`. Tooling: `check_mirrors.py` + `verify_rebuild.py` recognise `assert_po_manager(` as a caller
check (both, kept identical) and allowlist the two internals; `check-i18n.mjs` +3 prefixes; `check-document-registry.mjs` 238 → 239.

**Build decisions taken without asking — say if any is wrong:**
1. **The four PO tables lost their 12 write policies** (`PO_THROUGH_FUNCTION_ONLY`). Measured: all 15 writers are SECURITY DEFINER
   owned by `postgres`; `app/` only reads. Without this, a `module.purchasing.edit` holder could INSERT a PO directly with
   `approval_status` defaulting to `approved` — no approval and no raise code — which would have made Q6 and Q7 decorative.
2. **Applying a payment-term template counts as amending** (it rewrites the PO's payment schedule), so it follows Q7.
   `set_payment_term_expected_date` (a forecast date) and `record_po_issue` keep `module.purchasing.edit`.
3. **"Battery material" is `materials.kind_code = 'battery_material'`** — the catalogue's own field. Two live feedstock materials
   have no kind set, so the rule cannot see them; registered as `APR10-BATTERY-RULE-READS-KIND` rather than guessed around.
4. **Reopening a month *before* the waiting quarter is refused too** — the lock is one date, so reopening June unlocks July–September.
5. **The GST request carries no amount in `approval_log`** (the terms-request shape): the figures are a return, and box 8 can be
   negative. The pending list shows it with amount NULL; the fold-in above keeps it out of the "cannot be valued" count.
6. **An `approved` period reads the snapshot**, like a filed one: the page heading says "the return AS APPROVED — these are the
   figures to file", with a banner that it has not been filed at IRAS yet.
7. **Raise code → category mapping lives only in the database** (`po_category_raise_code`); the screens ask it rather than keep a
   TypeScript copy (`lib/poCategoryAccess.ts`).

## §2 · Verify — every figure is the script's own line

| step | result |
|---|---|
| `db/gate.py --offline` | first `GATE_EXIT=1` (the five PO manage doors lost their literal permission check → definer scan; fixtures red on `APPROVAL_THRESHOLD_NOT_SET` — my level computation ran with approvals off — and on raise codes) → fixed → `GATE_EXIT=4` twice (216's direct-insert arm; 229's own mistakes) → **`GATE_EXIT=0`**, 232 fixtures ✓ (54 s); re-run after the `approvals_readiness` fold-in: **`GATE_EXIT=0`** |
| dry run of the migration file on live (`COMMIT` → probe + `ROLLBACK`) | `DRY_OWN_EXIT=0` (before the fold-in); after it, one run hit `statement timeout` **while the backup's `pg_dump` held its share locks** (the first ALTER waited — AGENTS.md's backup-before-migration lesson, nothing committed); re-run after the backup finished: **`DRY_OWN_EXIT=0`** |
| backup | first attempt **`BACKUP_EXIT=124`** — the supervisor's 2,700 s bound; 0 bytes written, no lock held, DB reachable (6 s round trip). I deleted its 0-byte `.INCOMPLETE` file and retried once immediately: **`BACKUP_EXIT=0`** — `evoltrya-backup-2026-09-27-1606.dump` (5.0 MB, TOC 6,567), 16:29 |
| `db/apply_migration.sh` | **`APPLY_OWN_EXIT=0`**; pre-flight 25 CREATE FUNCTION (11 replaced · 14 new); proof NOTICEs: 11 POs backfilled; 1 decider for `gst_filing_request`; raisers — consumables: admin@, fusheng@ · equipment: admin@, sandra@ · office: admin@, chooer@; every pending document with a decider |
| `npm run types:gen` | `TYPES_OWN_EXIT=0` (+121 lines) |
| `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** |
| `npm run build` | **`BUILD_OWN_EXIT=0`** |
| `db/gate.py` (full) | **`GATE_EXIT=0`** (335 s) — rebuild ✓ · mirrors vs live ✓ · fixtures ✓ (232) · anon surface ✓ (baseline 327) |
| `node scripts/check-i18n.mjs` | **`I18N_OWN_EXIT=0`** |
| `node scripts/check-error-swallowing.mjs` | **`SWALLOW_OWN_EXIT=0`** |
| smoke (`node scripts/smoke-routes.mjs`, detached) | **`SMOKE_EXIT=0`** — 236 routes + probes; 229 timed, total 1,274.9 s, median 5,243 ms. Clean-up read back as `postgres` (base tables, 2026-09-27 17:18): `.ephemeral/` 0 plans; `auth.users` 7, `roles` 13, unrevoked `user_roles` 7 — the real accounts only; `gst_filing_requests` 0 rows; `purchase_orders` 11 |

## §3 · Live proof and the before / after readings

Script `db/scripts/2026-09-27-apr10-live-proof.sql`, one transaction, `ROLLBACK` at the end — **nothing was left on live**
(**`PROOF_OWN_EXIT=0`**, 2026-09-27 16:48 CST, as `postgres` switching to each real account under `authenticated`; read-backs as
`postgres`, base tables; the dashboard arm read as tim@). After the rollback: 0 GST requests, Q3 `open`, 0 box rows, 11 POs,
`locked_before` 2026-08-01, 82 journal entries, 14 approval_log rows. The first run stopped at P1 (the PO line needed a tax code —
GST is registered) and rolled back whole; the lines now carry `TX`, as PO-0010/0011 do.

| cell | who | what | result |
|---|---|---|---|
| G0 | postgres | lock → 2026-10-01 (in the transaction) | locked_before 2026-10-01 |
| G1 | admin@ | submit Q3 | `GST_FILING_NO_OTHER_DECIDER\|GST-2026-Q3 · filing #1`; 0 rows |
| G2 | chooer@ | submit Q3 | submitted; period still `open`; 0 box rows; 10 boxes frozen; pending row amount NULL, `blocks_disable` t, level 2; dashboard (as tim@) `gst_filing_pending`, item = the period |
| G3 | chooer@ | old door `file_gst_return` | `GST_FILING_NEEDS_APPROVED_REQUEST\|GST-2026-Q3` |
| G4 | postgres | switch approvals off while it waits | `APPROVALS_CANNOT_DISABLE_WITH_PENDING\|1\|GST-2026-Q3 · filing #1` |
| G5 | chooer@ | approve own | `SELF_APPROVAL_FORBIDDEN\|raiser` |
| G6 | tim@ · postgres | `reopen_period(2026-07-31)` · lock back to 2026-09-15 | both `GST_FILING_WAITING_BLOCKS_REOPEN\|GST-2026-Q3 · filing #1`; lock still 2026-10-01 |
| G7 | tim@ | approve after the frozen box1 was moved +1 | `GST_RETURN_CHANGED_SINCE_REQUEST`; still submitted |
| G8 | tim@ | approve | request + period `approved`; 10 box rows: box1 1,143.00 · box6 102.87 · box7 18.00 · box8 84.87; log `submitted/2 approved/2` |
| G9 | chooer@ | record the IRAS filing | `filed` 2026-10-15 IRAS-PROOF |
| G10 | chooer@ | open F7, submit it | GST-2026-Q3-F7-1; visible to tim@: original GST-2026-Q3, 10 original boxes |
| G11 | chooer@ | withdraw the F7 request | withdrawn; 0 decision rows in the log |
| P1 | fusheng@ | raise consumables (film 10 kg × 5, TX) | PO-2026-0012 consumables `draft/pending` |
| P2 | fusheng@ | raise equipment_goods | `PERMISSION_DENIED\|action.raise_po_equipment` |
| P3 | fusheng@ | consumables PO with a machine line | `PO_CATEGORY_LINE_MISMATCH\|…\|1\|consumables` |
| P4 | phua@ (cto) | raise consumables | `PERMISSION_DENIED\|action.raise_po_consumables` |
| P5 | sandra@ | raise with no category | `PO_CATEGORY_REQUIRED` |
| P6 | chooer@ | raise office | PO-2026-0013 office `draft/pending` |
| P7 | admin@ | raise equipment_goods 5,000.00 | `PO_NO_OTHER_DECIDER\|PO-2026-0014`; POs 13 → 13 |
| P8 | admin@ | raise consumables 50.00 | PO-2026-0014 `draft/pending` (level 1 — chooer@ can decide) |
| P9 | chooer@ | approve own office PO | `SELF_APPROVAL_FORBIDDEN` |
| P10 | tim@ | approve it | level 1 (by level 2) → `confirmed/approved` |
| P11 | chooer@ | approve fusheng@'s PO | level 1 → `confirmed/approved` |
| Q1 | phua@ | cancel fusheng@'s PO | `PO_NOT_RAISER_OR_CATEGORY_HOLDER\|PO-2026-0012\|action.raise_po_consumables` |
| Q2 | sandra@ | amend it | same refusal |
| Q3 | fusheng@ | amend own | amended (notes "raiser") |
| Q4 | sandra@ | amend PO-2026-0003 (raised by admin@, equipment_goods) | amended — she holds that category's code |
| Q5 | phua@ | amend PO-2026-0003 | `PO_NOT_RAISER_OR_CATEGORY_HOLDER\|PO-2026-0003\|action.raise_po_equipment` |
| Q6 | admin@ | cancel fusheng@'s PO (not the raiser; holds the consumables code) | cancelled |
| S1 | phua@ | direct INSERT into `purchase_orders` | `PO_THROUGH_FUNCTION_ONLY` |
| S2 | postgres | change a PO's category | `PO_FIELD_IMMUTABLE\|category\|PO-2026-0003` — ⚠ the first run's S2 set PO-0013 to the category it already had, so it tested nothing; re-run separately (rolled back) on PO-2026-0003 `equipment_goods → office`, and the script now changes office → consumables |

**Before and after readings** — `db/scripts/2026-09-27-apr10-readings.sql` (part 1 as `postgres`, base tables, `relkind`
self-proved; part 2 as tim@ on views; part 3 each account as itself), before at 16:22:36 (before the migration), after at 17:18:51
(after the proof and the smoke); `READINGS_OWN_EXIT=0` both times. Diffed:
- **identical:** approvals on (L1 finance, L2 cfo, threshold 1000, locked before 2026-08-01); pending —
  `approval_pending_documents()` = 1 expense claim (CLM-2026-0004, 1,000.00, `blocks_disable` 0); GST-2026-Q3 `open`, 0 box rows;
  approval_log 14; journal entries 82, lines 184, Σ debits 1,636,102.89; balances 1000 −127,593.48 · 1100 43,002.12 ·
  1200 61,387.92 · **1400 18.00 · 2100 −102.87** · 2000 −376,404.42; **list-vs-ledger (as tim@): AP list 416,988.32 / ledger
  376,404.42, AR list 57,545.87 / ledger 43,002.12, unexplained 0.00 on both sides**; PO statuses (4 cancelled · 2 closed ·
  2 confirmed · 3 receiving, all approved) and the PO digest; every other role's code count and md5 (cfo 30 `730763e8…` ·
  cto 32 · gm 21 · …); tim@, phua@, vince@ `current_user_permissions()`; 7 unrevoked grants.
- **changed, as intended:** `gst_filing_requests` exists (0 rows, 0 waiting; before: absent); `purchase_orders` by category
  **equipment_goods: 11** (before: no column); APR-10 guards 0 → **6**; write policies on the four PO tables 12 → **0**;
  `authenticated` can execute the four GST doors, `po_may_manage` and the new `create_purchase_order` (**t**) and not
  `gst_filing_execute_internal` / `assert_po_manager` (**f**); the old 11-argument `create_purchase_order` is gone; catalogue
  66 → **69**; holders — `action.raise_po_consumables` admin warehouse · `action.raise_po_equipment` admin cco ·
  `action.raise_po_office` admin finance · `module.purchasing.view` + warehouse; role codes **admin 65 → 68** (`957c088c…`) ·
  **cco 38 → 39** (`0f3799de…`) · **finance 38 → 39** (`1898acc0…`) · **warehouse 24 → 26** (`a52209ef…`);
  `current_user_permissions()` admin@ 68 · chooer@ 39 · fusheng@ 26 · sandra@ 39.
- **Nothing left pending by this cut; every pending document still has a decider who is not its own party** (the migration
  printed each: CLM-2026-0004 → tim@; LV-2026-0001 / 0003 → admin@, tim@; MC-2026-0001 → admin@, chooer@; ST-2026-0082…0086 → chooer@).

## §4 · Doors closed, and who can no longer / can newly do what (approvals on)

**Closed:** recording a GST filing in one step (`file_gst_return`); moving the lock back into a quarter whose filing waits;
raising a PO with `module.purchasing.edit`; raising any PO without a category; putting a machine or a battery-material line in a
non-equipment PO; changing a PO's category; amending, cancelling, closing, reopening or re-templating a PO for anyone other than its
raiser or a holder of its category code; any direct write to the four PO tables; a ≥ 1,000 PO nobody but its raiser could approve.

- **Choo Er (finance):** can no longer record a GST filing in one step; no longer raises consumables or equipment POs (she raised
  none). **Newly:** submits and withdraws GST filing requests; records the IRAS date and reference once approved; raises office POs;
  amends / cancels / closes office POs (any, as the office-code holder).
- **Sandra (cco):** can no longer raise consumables or office POs. **Keeps** raising equipment & goods; **still** amends, cancels and
  closes all 11 existing POs — they are all `equipment_goods` and she holds that code (Q7).
- **Phua (cto):** can no longer raise, amend, cancel, close or reopen any PO (keeps `module.purchasing.edit` for supplier issues and
  expected payment dates).
- **Fu Sheng (warehouse):** **newly** sees purchasing (`module.purchasing.view`), raises consumables POs, and manages consumables POs.
- **Tim as tim@ (cfo):** **newly** approves or rejects every GST filing request he did not raise; PO approval unchanged.
- **Tim as admin@:** holds all three raise codes (standing ruling), so raises and manages any category; a PO of 1,000 or more
  raised as admin@ is refused at submit (`PO_NO_OTHER_DECIDER`); a GST filing request raised as admin@ is refused at submit
  (`GST_FILING_NO_OTHER_DECIDER`).
- **Vince:** no change.

## §5 · Findings registered on the way

- **Closed:** the PO half of `ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE` (the expense-claim half stays).
- **Registered:** `APR10-BATTERY-RULE-READS-KIND` (build decision 3).

## §6 · Screen inventory — every action this cut adds or changes

| action | who | route | file |
|---|---|---|---|
| Submit a GST return's figures for approval (optional note; disabled with the reason when the quarter is not closed) | finance (`module.finance.edit`) | `/finance/gst/[periodId]` | `app/finance/gst/[periodId]/GstFilingPanel.tsx` (+ `page.tsx`, `app/finance/gst/actions.ts` `submitGstFiling`) |
| Approve / reject a GST filing request (frozen boxes; "now" beside any moved box; F7: original + difference) | CFO (`module.finance.view` + `data.view_prices`; the database refuses the raiser) | `/finance/gst/[periodId]#gst-filing` | same panel · `decideGstFiling` |
| Withdraw a GST filing request | the raiser, or `module.finance.edit` | `/finance/gst/[periodId]#gst-filing` | same panel · `withdrawGstFiling` |
| Record the IRAS filing date and reference (only on an approved period) | finance | `/finance/gst/[periodId]` | same panel · `recordGstFiling` (the old "Record the filing" control is removed from `GstControls.tsx`) |
| Open an F7 correction (unchanged, one step) | finance | `/finance/gst/[periodId]` | `app/finance/gst/GstControls.tsx` `CorrectControl` |
| See waiting GST requests | finance-module readers | `/finance/gst` (status column: Open · Waiting for the CFO · Approved, not filed yet · Filed); dashboard `gst_filing_pending` → `/finance/gst/<period>#gst-filing`; `/settings/approvals` pending line | `app/finance/gst/page.tsx` + `GstPeriodsTable.tsx` · `lib/reminders.ts` · `app/settings/approvals/ApprovalsPanel.tsx` |
| Pick a PO category (options you lack a code for are visible, disabled, naming the code; machine orders fixed to equipment & goods) | the category's raise-code holder | `/purchasing/orders/new` | `app/purchasing/orders/new/NewOrderForm.tsx` · `page.tsx` · `actions.ts` · `lib/poCategoryAccess.ts` |
| "New purchase order" button (disabled, naming the three codes, for anyone holding none) | — | `/purchasing/orders` | `app/purchasing/orders/page.tsx` |
| See a PO's category | purchasing readers | `/purchasing/orders/[id]` (header card) | `app/purchasing/orders/[id]/page.tsx` |
| Amend / cancel / close / reopen a PO (disabled, naming that category's code, for anyone else) | the raiser, or a holder of the PO's category code | `/purchasing/orders/[id]` · `/purchasing/orders/[id]/amend` (page-level refusal) | `[id]/page.tsx` · `CancelOrderControl.tsx` · `CloseReopenControls.tsx` · `[id]/amend/page.tsx` (`requireAllowed` in `app/components/moduleGuard.tsx`) |
| Approve / reject a PO (unchanged) | L1 / L2 approver | `/purchasing/orders/[id]` | `ApprovalControls.tsx` |
| Salary changes' line in the pending list | admin | `/settings/approvals` | `app/settings/approvals/ApprovalsPanel.tsx` |

## §7 · The broken window — started, end PENDING

**Start: 2026-09-27 16:34:41 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at" line
reads 16:32:21). **End: PENDING — Tim reads it from Vercel.**

What the old app does against the new database (approvals ON):
- **Raising a PO is refused for everyone** — the old form sends no category, so `create_purchase_order` answers
  `PO_CATEGORY_REQUIRED` (Q9); the old copy has no sentence for it, so it shows the generic text. Nothing is written.
- **Amend / cancel / close / reopen / apply a template** work only for the raiser or a holder of the PO's category code — for the
  11 existing POs that is admin@ and sandra@ (equipment); phua@ and chooer@ are now refused, with the generic text.
- **Recording a GST filing is refused** (`GST_FILING_NEEDS_APPROVED_REQUEST`, generic text), and there is no screen to submit a
  filing request until the deploy. **No live impact:** Q3 cannot be filed before September is closed anyway.
- **Unaffected:** PO approvals, receiving, month-end close, reopening a month (nothing waits), opening a GST period, every other
  chain, the switch, everything pending (CLM-2026-0004 still decidable by tim@).

## §8 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs (a commit cannot
carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
**Next cut:** the contract term editor (`docs/forward-queue.md` item 16).
