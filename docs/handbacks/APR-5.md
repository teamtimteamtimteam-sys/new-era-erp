# APR-5 — the sales side: CFO approval for credit notes and invoice voids (5a), and the pre-shipment release with warehouse shipping (5b)

APR-5 was split at its grilling (Tim, 2026-09-25, Q14): **APR-5a** — credit notes, invoice voids and every direct path that
bypassed them — shipped in this session; **APR-5b** — the CFO's pre-shipment release and warehouse shipping — is the next cut
(`docs/forward-queue.md` item 10). The approvals effects are `docs/approvals.md` §3q; the matrix line is `docs/role-matrix.md` §2.

# APR-5a — a credit note or an invoice void reaches the ledger only when the CFO approves it (2026-09-25)

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `ce8fd2a055318299d54de3eb6d1bccd1f1ef910e`
(ROLE-1 Batch 3b). **Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with its
identity (`postgres`, `rolbypassrls = t`, base tables unless a view is named; views read as tim@ under `authenticated`).

## §W · ROLE-1 Batch 3b's broken window — closed with bounds, labelled by kind

Tim confirmed the Batch 3b deploy on 2026-09-25, before this session began.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-25 13:01:19 | `db/apply_migration.sh`'s own line (`db/migration-windows.tsv`) |
| end, lower bound | 13:33:44 | **measured**: the push moved `origin/main` → `ce8fd2a0` (`git reflog show --date=iso refs/remotes/origin/main`) — no deploy can precede it |
| end, upper bound | 13:45:08 | **derived**: database clock `now()` read as `postgres` (`rolbypassrls = t`) in this session, after Tim's "deployed" confirmation had arrived — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 32 min 25 s, at most 43 min 49 s.** Back-noted in `docs/handbacks/ROLE-1.md` § Batch 3b §6.

## §0 · Step 0 (grilling) and Tim's answers

**What grilling found** (code read from the mirrors; live read as `postgres`, base tables):
1. **N1 is no longer needed for sales.** Nothing on the sales side routes by amount any more (Tim's matrix: sales orders, quotes and
   sales invoices need no approval; release, credit notes and voids go to the CFO every one). Every logged amount exists stored.
2. **Order flow is invoice-before-ship** (`SO_SHIP_NOT_INVOICED`, `ship_order.sql:96-106`); invoiced lines are frozen
   (`SO_AMEND_LINE_INVOICED`). So a release that covers invoiced lines cannot be amended from under the CFO (5b).
3. **Warehouse cannot ship on today's code even with a code**: partial shipping calls `release_reservation`, gated
   `module.sales.edit`; the shipping controls live on the sales-order page, which shows prices (5b).
4. **Six unregistered bypasses, all live before this cut:** direct `UPDATE invoices SET status='void'` (policy + freeze trigger allowed
   exactly that, with no GL reversal and the lines freed for re-billing) · direct flip of `invoice_lines.invoice_voided` · a hand-made
   `kind='order'` invoice INSERT that `ship_order` would accept · `reverse_journal_entry` on `invoice` / `credit_note` entries ·
   the two one-step functions themselves · a void of an invoice carrying credit notes (1100 relieved twice).
5. Live (2026-09-25, `postgres`): approvals on (L1 finance, L2 cfo); pending = 1 expense claim (1,000.00, `blocks_disable` 0);
   **0 sales orders confirmed or partially shipped** (nothing shippable); invoices — order 1 issued / 1 void, sale 5 issued / 2 void;
   1 credit note; 82 journal entries; list vs ledger 0.00 unexplained on both sides (tim@).

**Tim accepted all fourteen recommendations (Q1–Q14).** In this cut:
- **Q1** — N1 retired for `sales_orders` / `quotes` / `credit_notes`; recorded in `docs/approvals.md` §3c; `journal_entries` stays with N5.
- **Q9** — one `invoice_requests` table (kind `credit_note` / `void`); finance raises; the CFO's approval posts at once on the frozen
  date; one open request per invoice; the raiser or any `module.finance.edit` holder may withdraw; `create_credit_note` / `void_invoice`
  refuse `INVOICE_NEEDS_APPROVED_REQUEST`, bodies in `*_internal` revoked from `authenticated`.
- **Q10** — receipts never blocked; shipping refused against an invoice with a void waiting (`INVOICE_VOID_REQUESTED`) and against a
  line in an unshipped-cancel credit request (`INVOICE_CREDIT_REQUESTED`).
- **Q11** — all five direct paths closed. **Q12** — four other findings registered in `docs/known-issues.md`, none fixed
  (`APR5-CANCEL-INVOICED-ORDER-LEAVES-INVOICE-LIVE` · `APR5-SALE-INVOICE-RE-BILLS-ORDER-FLOW-SALES` · `APR5-QUOTE-STATUS-DIRECT-UPDATE`
  · `APR5-PARTIALLY-SHIPPED-HAS-NO-EXIT`). **Q13** — `invoice_request` registered in the engine. **Q14** — the split.
- Q2–Q8 and Q13's `shipping_release` are 5b (`docs/forward-queue.md` item 10). **Until 5b ships, cco keeps shipping.**

## §1 · What 5a shipped

Migration `db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql` (built by `db/scripts/build_apr5a_migration.py`
from the mirrors). **No new permission code**, so the standing ruling "every new code also goes to admin" had nothing to grant.
- **`invoice_requests`** (`db/tables/invoice_requests.sql`): `submitted → approved | rejected | withdrawn`; frozen `doc_date`, `reason`,
  `lines`; `amount_base` (credit note = debit total of its entry; void = `invoices.total_base`); result credit note and entry on the row.
  Read on `module.finance.view`; no write policy; anon revoked.
- **Functions:** `submit_credit_note_request` · `submit_invoice_void_request` (both `module.finance.edit`) →
  `invoice_request_submit_internal` (named refusals before insert · `INVOICE_REQUEST_OPEN` · `assert_other_decider` →
  `INVOICE_REQUEST_NO_OTHER_DECIDER` · dry run `invoice_request_dry_run`, SQLSTATE PQ004 · approvals off → posted, `auto_approved`) ·
  `decide_invoice_request` (`module.finance.view` + `data.view_prices`; `forbid_self_approval(created_by, NULL, 'invoice_request')`;
  level 2 directly; reject needs a reason; approve = `invoice_request_post_internal`) · `withdraw_invoice_request`.
  `create_credit_note_internal` / `void_invoice_internal` hold the old bodies without the gate; the void body adds
  `INVOICE_HAS_CREDIT_NOTES`. Five internals revoked from `authenticated` (`db/views/zzz_function_grants.sql`; allowlisted in
  `db/check_mirrors.py`).
- **Direct paths:** four write policies dropped on `invoices` / `invoice_lines`; `guard_invoice_direct_write` (statement level, replaces
  both `enforce_write_permission` triggers) → `INVOICE_THROUGH_FUNCTION_ONLY`; `guard_invoice_line_mutation` freezes `invoice_voided`
  except `false → true` on a void invoice; `reverse_journal_entry` refuses `invoice` / `credit_note`.
- **`ship_order`:** `INVOICE_VOID_REQUESTED` / `INVOICE_CREDIT_REQUESTED` (Q10). Its gate is unchanged (cco until 5b).
- **Engine:** `approval_chain_gates` row (level 2, `module.finance.view` + `data.view_prices`) · `approval_pending_documents` arm
  (`blocks_disable`, `fixed_level` 2, subject NULL) · `approval_log` CHECK + read branch · `record_approval_decision` branch ·
  `operations_now` arm `invoice_request_pending` + reminder (`lib/reminders.ts`) · `docs/dashboard-arm-inventory.md` row 35.
- **Screens (en/zh):** the invoice page carries `InvoiceRequestPanel` — the waiting request (kind, amount, date, reason, lines) with
  Approve / Reject (behind `data.view_prices`, disabled with the reason otherwise) and Withdraw (behind `module.finance.edit`, or the
  raiser's own account), plus earlier requests. Void and "Raise a credit note" now submit a request; while one waits both are visible,
  unpressable, and say which request holds them. New copy under `finance.invoiceRequest.*`, the error families, the dashboard item,
  the approvals subject label; `cn.submit` / `cn.consequence` / `invoice.voidConfirm` / `JE_REVERSE_USE_SOURCE_PATH` reworded.
- **Fixtures:** 223 new (A–O, with a fault injection: remove `trg_invoices_direct_write` and a direct void becomes a silent zero-row
  update with the invoice still issued). Nine fixtures that called the two doors (67 · 68 · 70 · 71 · 73 · 129 · 130 · 212 · 213) now
  call the `*_internal` engines — their subject is the engine's arithmetic; 71's catalogue check reads `create_credit_note_internal`.
  205 own-document gaps 6 → 7; 111 arms 38 → 39. No approvals-on fixture needed new gate codes (the pair is the payment-request pair).

## §2 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline` | run 1 `GATE_EXIT=4` (fixture 223 L: its 1100 helper missed the reversal entry, whose `source_id` points at the original entry — fixture fixed, not the code) · run 2 `GATE_EXIT=0` · run 3 (after the last mirror edit) `GATE_EXIT=0`, 51 s |
| backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-09-25-1645.dump`, TOC 6,261 (previous 6,258) |
| migration dry run on live (`COMMIT` → `ROLLBACK`) | first try: DNS could not resolve the pooler (psql exit 2, nothing sent); retried once at once: `DRY_OWN_EXIT=0` |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`; preflight 19 functions (8 replaced · 11 new); **window start 17:22:42 CST** (applied at 17:21:39) |
| types (`npm run types:gen`, after `NOTIFY pgrst`) | `TYPES_OWN_EXIT=0` (+187 lines) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | first `BUILD_OWN_EXIT=1` (`check-auth-error-swallowing`: the page read `auth.getUser()` inside `Promise.all` without naming its error — rewritten to the checked shape) · then `BUILD_OWN_EXIT=0` |
| `db/gate.py` (full) | run 1 died on `SSL SYSCALL error: EOF detected` at the grant-gap query (network; "NO DIFFERENCES" already printed) — `GATE_EXIT=1` is that crash, not a verdict · run 2 `GATE_EXIT=0`, 414 s: rebuildable ✓ · mirrors vs live ✓ · 226 fixtures ✓ · anon surface ✓ (relations 326, functions 1) |
| `check-i18n` | `I18N_OWN_EXIT=0` |
| `check-error-swallowing` | `SWALLOW_OWN_EXIT=0` (0 unallowed) |
| smoke (detached) | `SMOKE_EXIT=0` — 253 ok, 7 skipped (no data), 0 failed. Its pre-run scratch report printed "✗ fetch failed" (report only, not a stop). **Clean-up read back at 18:16:03 as `postgres`:** `smoke-%` accounts 0 · `probe-%` roles 0 · probe grants 0 · unrevoked grants 7 (as before) · `.ephemeral/` empty |

## §3 · Live proof

**Script:** `db/scripts/2026-09-25-apr5a-live-proof.sql` — one transaction, `ROLLBACK`, as `postgres`; each cell sets
`request.jwt.claims` to a real account under `SET LOCAL ROLE authenticated`. **`PROOF_OWN_EXIT=0`** (18:16:30).

| cell | who | what | result |
|---|---|---|---|
| D1 / D2 | chooer@ | `void_invoice` INV-2026-0009 · `create_credit_note` INV-2026-0007 | `INVOICE_NEEDS_APPROVED_REQUEST|…` both |
| D3 | sandra@ | `submit_invoice_void_request` | `PERMISSION_DENIED|module.finance.edit` |
| W1–W3 | chooer@ | direct void · direct `invoice_voided` flip · direct invoice INSERT | `INVOICE_THROUGH_FUNCTION_ONLY` ×3 |
| W4 | postgres | owner-path `invoice_voided` flip on a live invoice | `INVOICE_IMMUTABLE` |
| W5 / W6 | chooer@ | `reverse_journal_entry` JE-2026-0069 (invoice) · JE-2026-0055 (credit note) | `JE_REVERSE_USE_SOURCE_PATH|…|invoice` / `|credit_note` |
| W7 | chooer@ | void request on shipped INV-2026-0007 | `INVOICE_SHIPPED_NOT_VOIDABLE` at submit (engine's words; nothing saved) |
| N1 | admin@ | void request on INV-2026-0009 | `INVOICE_REQUEST_NO_OTHER_DECIDER` (one person with tim@); 0 rows left |
| C1 | chooer@ | credit note request, INV-2026-0007, revenue reduction 1.00 | submitted; no credit note, no entry, 1100 unchanged |
| C2 | postgres | pending arm · deciders | `blocks_disable`, `fixed_level` 2 · deciders: tim@ |
| C3 / C4 / C5 | chooer@ · chooer@ · vince@ | second request · decide own · withdraw | `INVOICE_REQUEST_OPEN` · `SELF_APPROVAL_FORBIDDEN|raiser` · `PERMISSION_DENIED|module.finance.edit` |
| C6 / C7 | tim@ | approve | CN-2026-0002 + JE-2026-0080; 1100 43,002.12 → 43,001.12; 4000 −38,493.00 → −38,492.00; log approved, level 2, tim@, `self_decided` false |
| V1 / V2 | chooer@ → tim@ | void INV-2026-0009 (taxed sale) | submitted, 1,245.87, still issued → void + JE-2026-0081; 1100 → 42,898.25; 2100 −102.87 → 0.00 |
| R1–R3 | tim@ · chooer@ | reject without reason · reject · withdraw own | `…_REJECT_REASON_REQUIRED` · rejected, nothing posted · withdrawn, no log row |
| L0 / L1 | tim@ | `list_ledger_reconciliation()` before / after the approvals | AP 416,988.32 / 376,404.42 → same; AR 57,545.87 / 43,002.12 → 57,442.00 / 42,898.25; **unexplained 0.00 both sides, both times** |

Not provable on live: Q10's shipping refusals — there is no confirmed or partially shipped order on live. Fixture 223 E / H pin them.

**Before and after readings** — `db/scripts/2026-09-25-apr5a-readings.sql`, before at 16:39:31, after at 18:17:00 (part 1 as
`postgres`, base tables; part 2 as tim@ on views; part 3 each account as itself):
- **identical:** approvals on (L1 finance, L2 cfo, threshold 1000); every role's code count and md5 (admin 63 `4cfdb6c0…` · cfo 30
  `730763e8…` · finance 38 `49745fb9…` · cco 37 `2ca7db2d…` · warehouse 23 `ad7470fc…` · gm 21 · cto 32 …) and every real account's
  `current_user_permissions()`; 7 unrevoked grants; pending — 1 expense claim, 2 leave, 1 medical approved-unpaid, 5 open stocktakes,
  0 PO / payment / payroll / receipt-price; `approval_pending_documents()` = 1 expense claim 1,000.00; journal entries 82;
  approval_log 14; invoices / lines / credit notes / shipments / sales records unchanged; balances 1100 43,002.12 · 1200 61,387.92 ·
  1210 0.00 · 1220 134.86 · 2100 −102.87 · 2500 0.00 · 4000 −38,493.00; AP list 416,988.32 / ledger 376,404.42, AR list 57,545.87 /
  ledger 43,002.12, **unexplained 0.00 both sides**.
- **changed, as intended:** `invoice_requests` exists (0 rows, 0 pending); the four invoice write policies are gone; the two
  `enforce_write_permission` triggers are replaced by `trg_invoices_direct_write` / `trg_invoice_lines_direct_write`;
  `reverse_journal_entry` refuses invoice / credit-note entries (f → t).
- **Nothing left pending by this cut; every pending document still has a decider who is not its own party** (the migration's own
  proof printed each — CLM-2026-0004 → tim@; leave → admin@, tim@; MC-2026-0001 → admin@, chooer@; stocktakes → chooer@).

## §4 · Who can no longer do what (approvals on)

- **Choo Er (finance):** voids and credit notes go from one step to *raise*; she can withdraw any waiting request; she cannot decide.
- **tim@ (cfo):** decides every credit note and void; raises neither (holds no `module.finance.edit`).
- **admin@:** holds every code, but a request raised from it is refused at submit (same person as tim@, the only level-2 holder).
- **Sandra (cco), Phua, Fu Sheng, Vince:** unchanged (none held `module.finance.edit`). Sandra still ships (5b moves it).
- **No document is left with only its raiser eligible:** Choo Er's requests → tim@.

## §5 · The broken window — started, end PENDING

**Start: 2026-09-25 17:22:42 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at" line
reads 17:21:39). ~~**End: PENDING — Tim reads it from Vercel.**~~ **Closed in APR-5b §W** (Tim confirmed the deploy on 2026-09-25):
end between **18:19:23** (measured — the push moved `origin/main` → `897e478a`) and **18:26:44** (derived — database clock read as
`postgres` after the relayed confirmation). **Window: at least 56 min 41 s, at most 1 h 04 min 02 s.**

What the old app does against the new database (approvals ON):
- **Void and "Post credit note" are refused for everyone.** The old buttons call `void_invoice` / `create_credit_note`, which now
  raise `INVOICE_NEEDS_APPROVED_REQUEST`; the old copy has no sentence for it, so it shows the generic unexpected-error text with the
  code. There is no screen to raise a request until the deploy.
- **Unaffected:** creating invoices (both kinds), receipts and payments, shipping (still cco; no shippable order on live), every
  approval chain, the switch, everything pending, and every other screen (the smoke ran the new code against the new database).

## §6 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs
(a commit cannot carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
**Next cut: APR-5b** (`docs/forward-queue.md` item 10), then APR-6.

# APR-5b — the CFO releases an order before it ships; the warehouse ships from a price-free queue (2026-09-25)

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `897e478a397d70a232f0cd1793cfc9d6cc948698` (APR-5a).
**Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with its identity
(`postgres`, `rolbypassrls = t`, base tables unless a view is named; views read as tim@ under `authenticated`).

## §W · APR-5a's broken window — closed with bounds, labelled by kind

Tim confirmed the APR-5a deploy on 2026-09-25, before this session began.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-25 17:22:42 | `db/apply_migration.sh`'s own line (`db/migration-windows.tsv`) |
| end, lower bound | 18:19:23 | **measured**: the push moved `origin/main` → `897e478a` (`git reflog show --date=iso refs/remotes/origin/main`) — no deploy can precede it |
| end, upper bound | 18:26:44 | **derived**: database clock `now()` read as `postgres` (`rolbypassrls = t`) in this session, after Tim's "deployed" confirmation had arrived — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 56 min 41 s, at most 1 h 04 min 02 s.** Back-noted in APR-5a §5 above.

## §0 · Step 0 (grilling) and Tim's answers

**What grilling found** (code read from the mirrors; live read as `postgres`, base tables, 18:26–18:29):
1. **Q8 could not be done by quantity as the data stood** — unshipped-cancel credits were capped by amount and `credit_note_lines.qty`
   was optional (`create_credit_note_internal.sql:143-185`, `:266`); `ship_order` capped nothing.
2. **`ship_order` returned the sales money** (`revenue_ccy`, `revenue_base`, `currency`, `fx_rate`) — a price leak once warehouse ships.
3. **Warehouse could not read what it shipped**: the three shipment tables read on `module.sales.view`, the delivery note embedded
   `sales_orders` / `customers` / `materials`.
4. **The order page's ship control also asked `module.finance.view`**, which the database never required.
5. Live: **0 sales orders confirmed or partially shipped**, 0 invoiced-but-unshipped lines, 0 open reservations, 0 customers on hold —
   nothing stranded or blocked by the migration.

**Tim accepted all twelve recommendations (5b Q1–Q12)**, adding one ruling: **the warehouse queue shows the order's delivery
address** (5b Q6) — recorded under AGENTS.md standing decision 3 as its one named exception.
- **Q1** — unshipped-cancel lines carry a quantity at submit (`CN_UNSHIPPED_CANCEL_QTY_REQUIRED` · `…_EXCEEDS`); shipping is capped at
  invoiced − Σ cancelled − shipped (`SO_SHIP_EXCEEDS_RELEASABLE|order|line|qty|ceiling`); no automatic release above the ceiling;
  `APR5-PARTIALLY-SHIPPED-HAS-NO-EXIT` stays registered.
- **Q2 / Q3 / Q4** — `shipping_release_lines` names invoice lines; coverage = approved and not voided; one submitted per order,
  several approved may coexist, a covered line cannot be named again; the raiser or any request-code holder withdraws; only a void lapses.
- **Q5** — `ship_order` returns no money. **Q6** — the queue as proposed plus the delivery address. **Q7** — the three shipment
  tables read on `module.sales.view OR action.ship_goods`; the delivery note reads through a DEFINER reader. **Q8** — the ship control
  lives only at `/logistics/shipping`. **Q9** — container attach/detach registered, not changed. **Q10** — margin NULL ("not costed")
  when any batch has no cost. **Q11** — two dashboard arms. **Q12** — fixture 224 with a fault injection.

## §1 · What 5b shipped

Migration `db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql` (built by
`db/scripts/build_apr5b_migration.py` from the mirrors).
- **Two new codes, both also to admin** (the standing ruling): `action.request_shipping_release` → cco · admin;
  `action.ship_goods` → warehouse · admin. Warehouse is **not** given `module.sales.view`.
- **`shipping_releases` + `shipping_release_lines`** (`db/tables/…`): `submitted → approved | rejected | withdrawn`; label
  `order · release #n`; `amount_base` = Σ named invoice lines. Read on `module.sales.view`; no write policy; anon revoked.
- **Functions:** `submit_shipping_release` (`action.request_shipping_release`; `SHIPPING_RELEASE_OPEN` · `…_ORDER_NOT_SHIPPABLE` ·
  `…_NO_LINES` · `…_LINE_NOT_INVOICED` · `…_LINE_ALREADY_RELEASED` · `assert_other_decider` → `…_NO_OTHER_DECIDER`; approvals off →
  approved, `auto_approved`) · `decide_shipping_release` (`module.sales.view` + `data.view_prices`; `forbid_self_approval(created_by,
  NULL, 'shipping_release')`; level 2 directly; reject needs a reason) · `withdraw_shipping_release` · readers
  `shipping_release_context` (CFO) · `shipping_queue_rows` (warehouse, no price, delivery address) · `shipment_document`
  (delivery note header and lines).
- **`ship_order`:** gate `action.ship_goods`; `SO_SHIP_CUSTOMER_ON_HOLD` · `SO_SHIP_NOT_RELEASED` · `SO_SHIP_EXCEEDS_RELEASABLE`;
  partial shipment calls `release_reservation_internal`; no money in its return. `record_shipment_issue` gate `action.ship_goods`.
  `release_reservation` / `reserve_stock` keep their gates and call `*_internal` (EXECUTE revoked from `authenticated`).
  The ceiling's one derivation is the base view `sales_order_line_releasable_all` (revoked; read by `ship_order`, the queue and the
  dashboard arm — a function would 42501 every dashboard reader through the owner-rights view).
- **Engine:** chain-gate row (level 2, `module.sales.view` + `data.view_prices`) · pending arm (`blocks_disable`, `fixed_level` 2) ·
  `approval_log` CHECK + read branch · `record_approval_decision` branch · `operations_now` arms `shipping_release_pending` and
  `shipping_release_ready` + reminders · `docs/dashboard-arm-inventory.md` rows 36–37. `self_approval_exception` untouched.
- **Screens (en/zh):** order page — the release panel (raise with line picks, CFO context, Approve / Reject behind
  `data.view_prices`, Withdraw behind the request code or the raiser's own account, history with lapsed lines struck through) and a
  visible line pointing to the queue in place of the ship control; `/logistics/shipping` — the queue (registry entry on
  `action.ship_goods`, "restricted" for everyone else); shipment page and delivery-note PDF read through `shipment_document`, accept
  `action.ship_goods`, and the issue control is disabled with the code for cco; the credit-note form requires a quantity on
  unshipped-cancel lines.
- **Fixtures:** 224 new (A–P; injection: a queue reader with an extra `unit_price` column must turn the column-list assertion red).
  Thirteen approvals-on fixtures give their level-2 role `module.sales.view` (the new gate pair); 68–71 raise a born-approved
  release before each shipment (their subject is not the release); 68 / 69 read `reserve_stock_internal`'s source; 69E now proves
  the second wall (`SO_SHIP_EXCEEDS_RELEASABLE`) under its injection; 223 adds quantities; 205 7 → 8; 111 39 → 41 arms.

## §2 · Verification — every figure is the script's own exit line

| step | result |
|---|---|
| `db/gate.py --offline` | run 1 `GATE_EXIT=4` (13 approvals-on fixtures: `APPROVALS_CHAIN_HAS_NO_APPROVER|decide_shipping_release`; 69E's injection met the new ceiling) · run 2 `GATE_EXIT=4` (223 lacked quantities) · runs 3–5 `GATE_EXIT=4` (224's own arms: I3 expected a re-reservation the code does not make; a fake sha) · run 6 `GATE_EXIT=0`, 51 s |
| migration dry run on live (`COMMIT` → `ROLLBACK`) | `DRY_OWN_EXIT=0`; read back as `postgres`: 0 new codes, no table |
| backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-09-25-1931.dump`, TOC 6,293 (previous 6,261) |
| rebuilt migration vs dry-run file | byte-identical (`cmp`) |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`; preflight 17 functions (8 replaced · 9 new); **window start 19:52:50 CST** (applied at 19:50:51) |
| types (`npm run types:gen`, after `NOTIFY pgrst`) | `TYPES_OWN_EXIT=0` (+195 lines) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | first `BUILD_OWN_EXIT=1` (the deep-route list was stale for `/logistics/shipping` — regenerated) · then `BUILD_OWN_EXIT=0` |
| `db/gate.py` (full) | `GATE_EXIT=0`, 431 s: rebuildable ✓ · mirrors vs live ✓ · 227 fixtures ✓ · anon surface ✓ (relations 326, functions 1) |
| `check-i18n` | `I18N_OWN_EXIT=0` |
| `check-error-swallowing` | `SWALLOW_OWN_EXIT=0` (0 unallowed) |
| smoke (detached) | `SMOKE_EXIT=0` — 254 ok, 7 skipped (no data), 0 failed. **Clean-up read back at 20:38:18 as `postgres`:** `smoke-%` accounts 0 · `probe-%` roles 0 · probe grants 0 · unrevoked grants 7 (as before) · `.ephemeral/` empty |

## §3 · Live proof

**Script:** `db/scripts/2026-09-25-apr5b-live-proof.sql` — one transaction, `ROLLBACK`, as `postgres`; each cell sets
`request.jwt.claims` to a real account under `SET LOCAL ROLE authenticated`. **`PROOF_OWN_EXIT=0`** (finished 20:42:41).
Three earlier runs stopped **in setup, before any cell**, and rolled back: OUT-2026-0007 refused `SALE_FORM_NOT_SET` (a run output
with no material form); CUS-2026-0004 has no payment terms and no default tax code, so the proof passes 30 days and `ZR` to
`create_order_invoice`. OUT-2026-0002 is the only reservable batch with stock ≥ 17 and it is uncosted — so the margin cell shows
the "not costed" path live (fixture 224 F pins the same).

| cell | who | what | result |
|---|---|---|---|
| S0 | sandra@ · chooer@ | build SO-2026-0005 (2 lines) + SO-2026-0006 through the ordinary doors, reserve on OUT-2026-0002, invoice INV-2026-0010 | done (inside the transaction) |
| A1 / A2 | fusheng@ · sandra@ | ship before any release · cco ships | `SO_SHIP_NOT_RELEASED|SO-2026-0005|1` · `PERMISSION_DENIED|action.ship_goods` |
| B1 / B2 | sandra@ · postgres | raise | submitted, 2 lines, 300.00, JE unchanged · pending arm `blocks_disable`, `fixed_level` 2, deciders: tim@ |
| B3 / B4 / B5 | sandra@ · sandra@ · fusheng@ | second raise · decide own · warehouse raises | `SHIPPING_RELEASE_OPEN|…` · `SELF_APPROVAL_FORBIDDEN|raiser` · `PERMISSION_DENIED|action.request_shipping_release` |
| N1 | admin@ | raise on SO-2026-0006 | `SHIPPING_RELEASE_NO_OTHER_DECIDER|SO-2026-0006`, 0 rows left |
| C1 / C2 | fusheng@ · tim@ | CFO context | `PERMISSION_DENIED|module.sales.view` · limit none, hold false, exposure 704.00, INV-2026-0010 open 300.00 not paid, line 1 invoiced 200.00, cost NULL, margin NULL |
| G1 | tim@ | approve | approved; log approved, level 2, tim@, `self_decided` false; nothing posted |
| Q1 / Q2 | fusheng@ · sandra@ | the queue | 2 rows, delivery address shown, the nineteen columns (no price, currency, rate, amount, margin, invoice code, balance) · `PERMISSION_DENIED|action.ship_goods` |
| H1 | tim@ → fusheng@ | hold the customer, ship | `SO_SHIP_CUSTOMER_ON_HOLD|SO-2026-0005|CUS-2026-0004`; hold lifted |
| F1 / F2 | fusheng@ | ship line 1, 4 of 10 | SHP-2026-0002; return keys `code, line_count, order_status, revenue_journal, ship_date, shipment_id`; 2500 −340.00 → −260.00 · 4000 −38,493.00 → −38,573.00 · 1220 / 5000 unchanged (uncosted batch) |
| F3 / F4 / F5 | fusheng@ · fusheng@ · sandra@ | read shipments + delivery note · issue it · cco issues | 2 shipments, delivery note with the customer and no price · OK · `PERMISSION_DENIED|action.ship_goods` |
| K1 / K2 / K3 | chooer@ · fusheng@ · fusheng@ | cancel without qty · after tim@ approved cancelling 2, ship the re-reserved 6 · ship 4 | `CN_UNSHIPPED_CANCEL_QTY_REQUIRED|INV-2026-0010|1` · `SO_SHIP_EXCEEDS_RELEASABLE|SO-2026-0005|1|6|4` · OK (order stays `partially_shipped` — `APR5-PARTIALLY-SHIPPED-HAS-NO-EXIT`) |
| V1 | tim@ · chooer@ · fusheng@ | approve SO-2026-0006's release, void its invoice, re-invoice, ship | `SO_SHIP_NOT_RELEASED|SO-2026-0006|1`; the release row is still `approved` (coverage lapsed by itself) |
| I1 | fusheng@ | `release_reservation_internal` | `permission denied for function release_reservation_internal` |
| L1 / L2 / L3 | tim@ · postgres | list vs ledger after the whole lifecycle | AP 416,988.32 / 376,404.42 · AR 57,845.87 / 43,302.12 — **unexplained 0.00 both sides**; nothing left waiting |

**Before and after readings** — `db/scripts/2026-09-25-apr5b-readings.sql`, before at 19:32:31, after at 20:43:22 (part 1 as
`postgres`, base tables; part 2 as tim@ on views; part 3 each account as itself):
- **identical:** approvals on (L1 finance, L2 cfo, threshold 1000); pending — 1 expense claim (1,000.00), 2 leave, 1 medical
  approved-unpaid, 5 open stocktakes, 0 PO / payment / payroll / receipt-price / invoice requests; `approval_pending_documents()` =
  1 expense claim; journal entries 82; approval_log 14; invoices, lines, credit notes, shipments 3, shipment lines 1, shipment issues 3,
  sales records 9, live reservations 0, customers on hold 0; balances 1100 43,002.12 · 1220 134.86 · 2500 0.00 · 4000 −38,493.00 ·
  5000 809.14; AP list 416,988.32 / ledger 376,404.42, AR list 57,545.87 / ledger 43,002.12, **unexplained 0.00 both sides**;
  every other role's code count and md5 (auditor 20 · cfo 30 `730763e8…` · cto 32 · finance 38 `49745fb9…` · gm 21 …); 7 unrevoked grants.
- **changed, as intended:** catalogue 64 → 66; `action.request_shipping_release` = admin cco; `action.ship_goods` = admin warehouse;
  admin 63 → 65 (`485022c5…`), cco 37 → 38 (`59932566…`), warehouse 23 → 24 (`a3e9b958…`) — and the same for admin@, sandra@,
  fusheng@'s `current_user_permissions()`; `shipping_releases` exists (0 rows, 0 pending); the three shipment read policies are
  `module.sales.view OR action.ship_goods`; `ship_order` and `record_shipment_issue` gate on `action.ship_goods`.
- **Nothing left pending by this cut; every pending document still has a decider who is not its own party** (the migration's own
  proof printed each — CLM-2026-0004 → tim@; leave → admin@, tim@; MC-2026-0001 → admin@, chooer@; stocktakes → chooer@;
  shipping_release deciders: 1).

## §4 · Who can no longer do what, and who newly can (approvals on)

- **Sandra (cco):** can no longer ship or issue delivery notes. Newly raises and withdraws shipping releases. Still creates, confirms,
  amends and cancels orders and reserves / releases stock.
- **tim@ (cfo):** newly decides every shipping release, seeing exposure, credit limit, hold, the invoice's open balance and per-line
  margin. Raises nothing, ships nothing.
- **Fu Sheng (warehouse):** newly ships from `/logistics/shipping` (no prices; the delivery address), reads the shipments he made and
  issues their delivery notes. Still no `module.sales.view` — the order page stays closed to him.
- **admin@:** holds both new codes; can ship; a release raised from it is refused at submit (same person as tim@, the only level-2
  holder); cannot decide (not cfo).
- **Choo Er (finance):** unshipped-cancel credit requests now need a quantity. **Phua, Vince:** read the release panel; nothing else.
- **No document is left with only its raiser eligible:** Sandra's releases → tim@.

## §5 · The broken window — started, end PENDING

**Start: 2026-09-25 19:52:50 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at" line
reads 19:50:51). **End: PENDING — Tim reads it from Vercel.**

What the old app does against the new database (approvals ON):
- **Shipping is refused for everyone.** Sandra's ship button (old order page) → `PERMISSION_DENIED|action.ship_goods` (the old
  copy says "restricted"); admin@'s → `SO_SHIP_NOT_RELEASED`, which the old copy has no sentence for (the generic unexpected-error
  text with the code). There is no screen to raise a release and no shipping queue until the deploy. **Live impact: none** —
  there is no confirmed or partially shipped order on live (Step 0 and the before reading).
- **Delivery notes:** issuing refuses cco (`PERMISSION_DENIED|action.ship_goods`); previews still render for `module.sales.view`.
- **An unshipped-cancel credit request without a quantity** → `CN_UNSHIPPED_CANCEL_QTY_REQUIRED`, which the old copy shows
  as the generic text with the code; the old form's quantity field works if filled.
- **Unaffected:** invoicing, receipts and payments, credit-note and void requests with quantities, every approval chain, the switch,
  everything pending, and every other screen (the smoke ran the new code against the new database).

## §6 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs
(a commit cannot carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
**Next cut: APR-6** (`docs/forward-queue.md` item 11).
