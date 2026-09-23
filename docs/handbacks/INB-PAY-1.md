# INB-PAY-1 — a receipt priced at creation now posts exactly like one priced later (2026-09-23)

**Opening gate (passed):** working tree clean; `HEAD` = `origin/main` = `git ls-remote origin main`
= `bc5da5d129c4cc03c0a6b97a8c89f38a0db081a0` (APR-4).

**★ Broken window start** (the line `db/apply_migration.sh` prints itself):
### `2026-09-23 16:16:20 CST`
(`migration applied at 16:15:57`; committed and "库已经是新的了" at 16:16:20; on disk in `db/migration-windows.tsv`
as `2026-09-23T16:16:20+0800`.) **End: closed — an UPPER BOUND, not a measurement** (ROLE-MATRIX-0, 2026-09-23): Tim relayed "INB-PAY-1 deployed"; the clock reading taken with that relay already in hand is **16:47:53 CST** (`date`, ROLE-MATRIX-0 opening gate). ☞ **Window ≤ 31 min 33 s.** The real end (Vercel Ready) can only be earlier; the commit is 16:42:50, so it cannot be earlier than the push after that.

**★★ What is broken during the window, approvals ON.** The database is new; production runs the old code.

| what | during the window |
|---|---|
| **desk receipt (`/inbound/new`) with a unit price** | ★ **Refused.** The old form sends no currency, so the new function refuses by name with `CURRENCY_INVALID\|?`. The old action doesn't know that code and shows it inside the generic save-error sentence (or the shared fallback). **Nothing is written** — the refusal rolls back the whole receipt. |
| desk receipt **without** a price | works, unchanged |
| field receiving against a PO (`/inbound/receive`) | works, unchanged (different function, no price) |
| pricing a receipt on its page | works, unchanged (same function as before) |
| approvals | ★ **Untouched.** No chain, policy row or switch touched. `approvals_enabled` t, `approval_log` 14 → 14, every pending count unchanged (§4). |

☞ **In one line:** for the length of the window, typing a price on the desk form is refused; leaving it blank and pricing
on the receipt's page (the path that always posted correctly) still works.

---

## §0 · What Step 0 changed (Tim accepted all three findings, 2026-09-23)

Measured as `postgres` (`rolbypassrls = t`); `inbound_batches` is a base table (`relkind = 'r'`), and so are
`price_history` and `journal_entries`. Queries: `q1.sql` in the session scratchpad (per-receipt join of
`inbound_batches` × `journal_entries` (`source_type='purchase'`) × `price_history`), and the one-liners quoted below.

1. **IN-2026-0011 and IN-2026-0012 are not instances of this defect.** Each has a `price_history` row written at
   **2026-07-05 23:37** by the pricing step (`old_unit_price` NULL → 150 / 200). The first `purchase` journal entry
   anywhere is **2026-07-06 10:02** (`select min(created_at) from journal_entries where source_type='purchase'`),
   i.e. cut 2a. They were priced correctly, the evening before payables started posting. IN-2026-0013 and
   IN-2026-0002 (both soft-deleted) are the same shape.
2. **No receipt on live, live or deleted, was ever priced at creation.**
   `select count(*) from inbound_batches ib where unit_price is not null and not exists (select 1 from price_history ph where ph.inbound_batch_id = ib.id)` → **0**;
   and every priced receipt's first `price_history` row starts from `old_unit_price` NULL. The defect existed only in code.
3. **Pricing a creation-priced receipt later posted only the difference.** `reprice_inbound_batch` posts
   (new − old) × quantity, so the creation price × quantity never reached 2000 — while `ap_open_items` and
   `apply_prepayment` count quantity × unit price as owed. Fixture 208 arm C pins this (§2).

The known-issues entry `APR4-RECEIPT-PRICED-AT-CREATION-NO-PAYABLE` carried the wrong premise ("live instances
IN-2026-0011 / 0012", "no price history"). **It is closed** — removed from `docs/known-issues.md` under that file's own
rule (a fixed entry is deleted), with the corrected findings recorded here. `docs/approvals.md`'s pointer is amended.

## §1 · What shipped (Tim Q2 = A)

| piece | change |
|---|---|
| `create_inbound_batch` | inserts the receipt **unpriced**, then — if a price was given — calls **`reprice_inbound_batch`** in the same transaction. Same `purchase` entry, same `price_history` row, same named refusals. New trailing `p_currency`, **no default** (currency decides the rate). DROP + CREATE (signature changed), EXECUTE revoked from PUBLIC/anon, granted to authenticated/service_role. Returns `pricing` (the repricing breakdown incl. `journal_code`), null when unpriced. |
| desk form `/inbound/new` | keeps its price box; gains a **currency picker defaulting to the base currency** (`getBaseCurrency()` / `getCurrencyCodes()`, never a literal), a hint that a price here records the payable and price history, and the board-rate hint for foreign currencies. |
| desk action | a price ≤ 0 is refused on the field (`inbound.pricing.errors.PRICE_INVALID`); the database refuses independently. Pricing refusals (`PRICE_INVALID` / `CURRENCY_INVALID` / `FX_RATE_MISSING`) are translated on the price field. |
| `app/inbound/pricingErrorCodes.ts` | the pricing error set and translator moved out of `[id]/edit/pricingActions.ts` so both paths say the same sentence from one list; `check-i18n`'s MANIFEST points at the new file. |
| en / zh | `inbound.form.unitPricePostsHint` |
| fixture 104 | its three priced creations now pass `p_currency => v_base` (they now post a purchase entry too; every arm still green) |

**Q3 — no approval changes.** **Q5 — still posted on the pricing date** (`CURRENT_DATE`, today's `tt_sell`), identical
to pricing later; a receipt backdated into a locked period is unaffected because the entry is dated today.

## §2 · Proof

**Fixture 208** (`db/fixtures/208-a-receipt-priced-at-creation-posts-like-one-priced-later.sql`), on the rebuild:
A creation-priced (base) → one purchase entry, 2000 = 14 × 150, one price-history row · **B** unpriced then priced at
the same price → journal lines and price history **identical to A** · **C** repricing A 150 → 160 → 2000 net for that
receipt = 2240.00 = quantity × unit price (the `ap_open_items` formula) · **D** the same comparison in a foreign
currency at its own `tt_sell` · **E** price 0, negative price, missing currency, missing rate → refused by name, whole
receipt rolled back · **F** unpriced creation unchanged.

**Fault injection** (throwaway local cluster built by `db/verify_rebuild.py --skip-diff --offline`; the old direct
write put back into the new signature):

| cell | injected | result |
|---|---|---|
| 1 | old body (price written directly, `pricing` null) | red: `208A … 实得 null` (exit code not captured; message read from the output) |
| 2 | old body, but returning a fake `journal_code` | **exit 3**, red: `208A … 恰好一条 purchase 分录,实得 0` |
| 3 | old body, arm C alone | **exit 3**, red: `208C … 总账 140.00,单据 2240.00` — only the difference posted |
| restore | real body | **exit 0**; arm C alone passes |

**Live proof** (`db/scripts/2026-09-23-inbpay1-live-proof.sql`, one transaction, **ROLLBACK**): identity
`current_user = authenticated`, `auth.uid() = 321f1819-…` (an admin). Output, verbatim:
```
PROOF A: journal JE-2026-0080
PROOF lines  A=[1200:2100.00:0,2000:0:2100.00]  B=[1200:2100.00:0,2000:0:2100.00]
PROOF prices A=[150.0000:SGD:150:1:tt_sell]  B=[150.0000:SGD:150:1:tt_sell]
PROOF C: 2000 net 2240.00 / document value 2240.00
PROOF E: price 0 refused by name: PRICE_INVALID
PROOF PASSED (inside the transaction; ROLLBACK follows)
```
`PROOF_EXIT=0`. ⚠ The **first** run failed on my own script: I put `SET CONSTRAINTS ALL IMMEDIATE` at the top, so the
deferred balance trigger fired after the first journal line (`JOURNAL_UNBALANCED|JE-2026-0080|2100.00|0`). The
transaction aborted, so nothing committed; the line was moved to the end (fixture 104 already says it must be there),
and the second run passed. JE-2026-0080 appears in both because the numbered code was consumed only inside rolled-back
transactions.

## §3 · Verify (every figure is the script's own line)

| step | result |
|---|---|
| `db/gate.py --offline` (before the migration) | `GATEOFF_EXIT=0`, 48s; fixtures 104 ✓ 208 ✓ |
| backup | `BACKUP_EXIT=0`, `evoltrya-backup-2026-09-23-1603.dump` (4.5M) |
| `db/apply_migration.sh` | preflight ✓ (0 replaced, 1 created); committed atomically; window start 16:16:20 |
| `npm run types:gen` (after `NOTIFY pgrst`) | exit 0; one line: `p_currency?: string` |
| `npx tsc --noEmit` | `TSC_EXIT=0` |
| `npm run build` | `BUILD_EXIT=0` |
| `db/gate.py` full | `GATE_EXIT=0` (494s): 可重建性 ✓ · 镜像 vs 线上 ✓ · 行为断言 ✓ · 匿名面 ✓ (baseline 327) |
| `check-i18n` | `CHECK_I18N_EXIT=0` |
| `check-error-swallowing` | `SWALLOW_EXIT=0` |
| smoke (detached, `db/run_detached.sh`) | `SMOKE_EXIT=0` — 251 ok, 6 skipped (no data), **0 FAILED**. Its report-only scratch-row check listed 6 stale `ZZ-SMOKE-*` rows (505–1147 h old, five still referenced); they predate this cut and it didn't touch them |
| leftover ephemeral accounts | **0** — `select count(*) from auth.users where email like '%@test.local'` as `postgres` (`auth.users` `relkind='r'`); no `.ephemeral/` plan files, no orphan `next dev`, no `.live-lock`, 0 `idle in transaction`. Nothing to reap |

## §4 · Before and after (as `postgres`, `rolbypassrls = t`, base tables; query: `readings.sql` in the scratchpad)

Before at 16:03:35 CST; after at 16:17:20 CST (after the migration and the live proof's ROLLBACK). **`diff` of the two
outputs: empty.**

| reading | before | after |
|---|---|---|
| `approvals_enabled` | t | **t** |
| `approval_log` rows | 14 | **14** |
| purchase orders `approval_status='pending'` | 0 | 0 |
| expense claims submitted | 1 | 1 |
| leave pending | 2 | 2 |
| medical claims submitted | 0 | 0 |
| reviews submitted | 0 | 0 |
| stocktakes open | 5 | 5 |
| work orders draft | 0 | 0 |
| journal entries (all / purchase) | 82 / 10 | **82 / 10** |
| 2000 balance (credit − debit) | 376,404.42 | **376,404.42** |
| `inbound_batches` / `price_history` rows | 24 / 14 | 24 / 14 |

`idle in transaction` backends after the proof: 0. Nothing is left pending on live.

## §5 · Housekeeping

* **APR-4's broken window: closed with an upper bound** — start 15:19:53 CST, end ≤ 15:54:19 CST (the clock reading
  taken before Tim's "deployed" reached this machine) ⇒ **≤ 34 min 26 s**. Labelled as an upper bound in
  `docs/handbacks/APR-4.md`, both places.
* **Pricing-terms commitment:** recorded in `docs/forward-queue.md` as **unscheduled, not queued** (Tim).
* **Four legacy receipts** (IN-2026-0011, 0012, and the soft-deleted 0013, 0002): one line each in
  `docs/known-wrong-until-cutover.md` (Tim Q4 — leave and label; repricing can't post them, the difference is 0).

## §6 · Commit, push, three SHAs
Reported in the terminal at push time. **Broken window: start 2026-09-23 16:16:20 CST, end ≤ 16:47:53 CST — an upper bound (Tim relayed
"deployed"; the clock reading is ROLE-MATRIX-0's), so ≤ 31 min 33 s.**
