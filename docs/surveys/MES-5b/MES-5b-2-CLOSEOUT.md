# MES-5b-2 close-out — step 1 of the MES-5b-2 close-out + MES-5b-3 build brief (2026-10-09)

**Verdict: a–e pass. f passes on what the deployed app can show; two of the brief's assumptions in f were measured false — live has no
electricity allocation, and the expense reversal has no reason field (it never had one; only the allocation reversal takes a reason, Q22).
Neither is a defect in what MES-5b-2 built, so step 2 goes ahead (brief 1.5); both are recorded below and in the MES-5b-3 hand-back.**
Nothing was fixed. The window close is in `docs/forward-queue.md` item 45.

**Opening check.** First command **2026-10-09 15:56:43 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`68aa5277c95c4abb1bb5218a972a77174e10b0ac`. Files staged by explicit path only.

**Identities.** Live readings: `mes5b2-closeout-readings.sql` (beside this file) over direct psql to the pooler inside `BEGIN READ ONLY … ROLLBACK`,
as `postgres` (`rolbypassrls = true`), base tables and the catalog — `READ_OWN_EXIT=0`, 16:08:03 CST (approvals ON, 7 accounts, 0 disabled). Page renders: `mes5b2-closeout-render.mjs`
(beside this file) — three one-off clones of real roles (`mintThrowaway { cloneOf }`, prefix `mes5b2probe`) on the **deployed** app
(`https://new-era-erp.vercel.app`), `RENDER_PROBE_EXIT=0`, about 16:08 CST; the browser half opens the reverse dialog and **dismisses** it, never
confirms. Cleaned by the ephemeral plan: after, 0 `mes5b2probe` accounts, 0 `probe-` roles, 7 real accounts, 0 disabled (read 16:09 CST).

---

## 1 · Broken window — closed (bounded)

- **Start:** 2026-10-09 14:48:26 CST — measured, `db/migration-windows.tsv` (`2026-10-09-mes5b2-reversals.sql`).
- **End, lower bound:** 2026-10-09 15:45:02 CST — measured, `git reflog show --date=iso refs/remotes/origin/main`:
  `68aa5277 refs/remotes/origin/main@{2026-10-09 15:45:02 +0800}: update by push`.
- **End, upper bound:** 2026-10-09 15:56:43 CST — this session's first command, with Tim's "deployed" already in hand. It rests on what Tim said,
  not on a Vercel reading.
- **Window: 56 min 36 s – 1 h 08 min 17 s.**
- Close-out reading (16:08 CST, `postgres`, base tables): electricity allocations **0** · reversals 0 · reversed expenses 0 · expenses created since
  the window opened 0 · cost entries stamped since 0 · `require_calibrated_since` NULL. Nobody used the new features in the window.

## 2 · Read-only verification

### a · The V37 fold-in — on the operation page's own trail, with its wording arm and fault ✓

- Member: `db/functions/trail_subject_members.sql:516` —
  `('operation_type', 5, 'operation_type_output_forms', 'operation_types', 'operation_type_code', '{}'::jsonb, 'down', true, true)`;
  live: the same line is in `pg_get_functiondef` (reading `A|… = true`).
- Renderer: `lib/trail/render.ts:1136-1138` — `operation_type: [ … 'operation_type_output_forms']` (comment: "+ 每一种产出形态的预期得率(V37)").
- Fixture: 258 LOG `db/fixtures/258-…sql:554-557` — sets black mass to 70 and requires ≥ 1 `operation_type_output_forms` row in
  `record_trail('operation_type', 'battery_powder_line', 500)`; its injection cell `db/scripts/2026-10-09-mes5b2-fixture-injections.py:164`
  ("a V37 change is not on the operation's trail").
- Wording arm ㉔: `scripts/check-trail-wording.mjs:5897-5904` (fault `wording-drift-mes5b2`), `:5988-5990`. Run today on HEAD: clean
  **`TW_CLEAN_OWN_EXIT=0`** ("✓ ㉔ MES-5b-2 的电费单撤回与工序页上的 V37"); `TRAIL_WORDING_FAULT=wording-drift-mes5b2` → **`TW_FAULT_OWN_EXIT=1`**, red in ㉔
  only ("✗ … ㉔ …:2 处").

### b · Q28 — posting needs `module.finance.view` ✓

- `db/functions/post_electricity_allocation.sql:44-45` — `PERFORM require_permission('module.finance.edit');` then
  `PERFORM require_permission('module.finance.view');`; live: both present (reading `B|post asks finance.view=true|asks finance.edit=true`).
- Fixture 258 PERM `:207-212` — a holder of edit without view is refused `PERMISSION_DENIED|module.finance.view` and no allocation is left.
- Injection `…fixture-injections.py:66-67` ("posting no longer asks module.finance.view (Q28)") removes that line → red in PERM.

### c · Q21 — the variance view ignores reversed reliefs; the `'SGD', 1` literal replaced ✓

- `db/views/processing_cost_variance.sql:42` — `WHERE pce.relieved_at IS NOT NULL AND pce.deleted_at IS NULL AND ex.status = 'posted'::text`
  (comment `:21-23`); live: `C|variance filters posted=true`.
- `db/functions/relieve_processing_accruals.sql:110` — the expense row writes `base_currency_code(), 1` (comment `:16-17`); live:
  `relieve has SGD literal=false|relieve reads base_currency_code=true`.
- Fixture 258 VAR `:370-393` (including a reversed relief whose stamps were never cleared, `:389`) and CCY `:395-409` (base switched inside the
  transaction → the relief expense is in that currency at rate 1). Injections `:120` (variance counts reversed reliefs) and `:123` (the literal back).

### d · Q23 — post → reverse → post for the same period ✓

- Fixture 258 REPOST `:281-306`: after bill A is reversed, the corrected bill for the **same period** previews 160 / 320 and relieves the restored
  370 again (`:286`); the run carries two lines, one reversed (`:291`); energy reads only the live allocation's line (`:295`); a run already in a
  live allocation is refused `ELECTRICITY_RUN_ALREADY_ALLOCATED` (`:300-302`); the live allocation still blocks an overlapping period (`:305`);
  AP = ledger (`:306`).
- Injections `:94-103` (already-allocated / period-overlaps counting a reversed allocation; the guard gone; the guard behaving like the old unique).
- Live: no unique constraint on `run_id`; the one-live guard trigger present (readings `D|…=0`, `D|…=1`).

### e · `docs/known-issues.md` — the three entries ✓

- `MES5A2-RELIEF-REVERSAL-ORPHANS` `:10536` — struck, "关闭于 MES-5b-2"; its first paragraph **corrects the mechanism** (relief stamps, it does not
  soft-delete) and keeps the wrong original visible.
- `MES5B2-SETTLEMENT-STAMP-SIDE-DOOR` `:10602` — struck, closed (the guard, the context flag, fixture 258 GUARD).
- `MES5A2-RELIEVE-SGD-LITERAL` `:10507` — struck, closed (`base_currency_code()`, fixture 258 CCY); the second half of its deletion condition
  (whether the currency check should read `VALUES`) is stated as still Tim's.

### f · Usability on the deployed app — what it can show, and the two assumptions it cannot meet

| Clone of (codes) | `/finance/expenses/<EXP-2026-0003>` (ordinary, unpaid) | `/finance/expenses/<EXP-2026-0005>` (month-end relief) | `/finance/electricity` | `/finance/electricity/<no such id>` |
|---|---|---|---|---|
| admin (74) | HTTP 200 · Reverse **pressable** · pressed: dialog opens, subject `EXP-2026-0003`, "Reverse this expense? A mirror entry will be created and its journal reversed." · **no reason field** · dismissed, closed | 200 · pressable · dialog + "This is a month-end relief. Reversing it puts the 1 estimate(s) it relieved back as unsettled …" · **no reason field** · dismissed | 200 | **404** (passes the gate, then notFound) |
| finance (41) | identical to admin | identical | 200 | 404 |
| warehouse (28) | 200 · **refused at the gate** · no Reverse control in the page (fetch and browser) | refused · no control | refused | refused (the gate answers before the id) |

No error text on any of the 12 fetches.

**Assumption 1 — "the allocation page renders the reverse action".** Live has **0** electricity allocations (reading `F|ALLOC|0`), so no
allocation page exists to render on the deployed app; step 1 is read-only, so none was made. What exists instead: the control is
`app/finance/electricity/[id]/ReverseAllocationControl.tsx:22-40` (`ConfirmButton` with `reason={{ placeholder: t('energy.reverseReason') }}` at
`:28`, inside `PermissionGate code="module.finance.edit"`), rendered at `app/finance/electricity/[id]/page.tsx:185`; MES-5b-2 rendered it through a
scratch harness of the real page (hand-back §5 row 10 — unreversed with the control, reversed with a 180-character reason) and measured
who can press it inside the live proof (hand-back §2: admin · finance pressable; cto · cco · cfo · gm visible, not pressable; warehouse refused).
**Not measured on the deployed app** — it can be, the first time an allocation exists on live.

**Assumption 2 — "an expense page renders the reverse action with its reason field".** The expense reversal has **no reason field**, by design:
`reverse_expense(p_expense_id)` takes no reason (unchanged signature, Step 0 Q21 · Q24 asked for none), `ReverseExpenseButton.tsx` calls
`reverseExpense(expenseId)` and its `ConfirmButton` has no `reason` prop; only the **allocation** reversal requires one (Q22,
`ELECTRICITY_REVERSAL_REASON_REQUIRED`, fixture 258 PERM `:233`). Measured on the deployed app: the dialog opens, names the expense and, on a relief,
says how many estimates come back — and has no reason input. If Tim wants a reason on every expense reversal, that is a new ruling
(`reverse_expense` gains a parameter); not done here.

### g · Self-taken decisions in `docs/handbacks/MES-5b-2.md` §7 (titles)

1. One implementation of "reverse an expense".
2. A prepayment-applied expense is refused too.
3. Part-settled counts as settled.
4. The settlement guard also covers inserts.
5. The context flag `evoltrya.cost_settlement_ctx`.
6. One reversal date, asserted.
7. Re-accrual: one journal per restored estimate.
8. A state check before reversing.
9. What the reversal record holds.
10. `run_id UNIQUE` → a BEFORE INSERT guard plus a plain index.
11. `reverse_electricity_allocation` asks `module.finance.edit` only.
12. The run-energy view reads only the live allocation's line.
13. The F2 "now allocated" check takes the allocation advisory lock.
14. The variance view filters `status = 'posted'`.
15. `processing_cost_entry_lookup` gains `relief_expense_id`.
16. The expense page blocks, not hides.
17. The allocation refusal carries the allocation id.
18. "Every expense kind" in the fixtures.
19. The trail shows the reversal on each covered run.
20. The allocation page was surveyed through scratch harnesses.
21. In the live proof, the payment that settles an expense is setup.
22. Mask rules +3 on the reversal's three amounts.

## 3 · Tim's rulings recorded (brief 1.2)

- **`MES5B2-PREPAYMENT-APPLIED-EXPENSE-NOT-REVERSIBLE`** — accepted as a ruling, not an open item (`docs/known-issues.md`, the hand-back's decision 2).
- **`MES5B1C-ADMIN-TASKS-VIEW-ALL-UNRULED`** — Tim ruled that admin holds `module.tasks.view_all`; it lands in MES-5b-3's migration (live admin role and
  the bootstrap seed) and the entry closes there.

## 4 · Assertions measured and found false or imprecise

- **f, "the allocation page … render[s] the reverse action"** — live has no allocation; not renderable on the deployed app without creating one.
- **f, "… with its reason field" (for the expense page)** — the expense reversal never had a reason field; only the allocation reversal does.
- Zero other assertions found false (the SHA, clean tree, 7 accounts enabled, approvals ON, `require_calibrated_since` NULL — all re-measured).
