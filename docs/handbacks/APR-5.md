# APR-5 — the sales side: CFO approval for credit notes and invoice voids (5a), and the pre-shipment release (5b)

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
reads 17:21:39). **End: PENDING — Tim reads it from Vercel.**

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
