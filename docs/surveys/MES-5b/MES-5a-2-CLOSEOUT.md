# MES-5a-2 close-out — step 1 of the MES-5a-2 close-out + MES-5b Step 0 brief (2026-10-08)

**Verdict: b and f do not pass, so MES-5b Step 0 did not start** (the brief's step 1.4). a, c, d, e and g read as stated. Nothing was fixed.
The window close is in `docs/forward-queue.md` item 43.

**Opening check.** First command **2026-10-08 18:43:41 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`6a12e5698119b9b67aeb2f92bf8963ec7780d164`. Files staged by explicit path only.

**Identities.** Every live reading below ran as `postgres` (`rolbypassrls = true`) over direct psql to the pooler, read-only (`BEGIN READ ONLY … ROLLBACK`),
on base tables only (`docs/surveys/MES-5b/closeout-readings.sql`, `READ_OWN_EXIT=0`, 18:51 CST). Every "local" result ran on a throwaway cluster in this
job's scratch directory, rebuilt from the HEAD mirrors (`db/verify_rebuild.py --offline`, `REBUILD_OWN_EXIT=0`, B1 0 · B2 0) — never on live. No live
row was written.

---

## 1 · Broken window — closed (bounded)

- **Start:** 2026-10-08 16:05:51 CST — measured, `db/migration-windows.tsv` (`2026-10-08-mes5a2-energy.sql`).
- **End, lower bound:** 2026-10-08 16:56:54 CST — measured, `git reflog show --date=iso refs/remotes/origin/main`:
  `6a12e569 refs/remotes/origin/main@{2026-10-08 16:56:54 +0800}: update by push`.
- **End, upper bound:** 2026-10-08 18:43:41 CST — this session's first command, with Tim's "deployed" already in hand. It rests on what Tim said,
  not on a Vercel reading.
- **Window: 51 min 03 s – 2 h 37 min 50 s.**
- Close-out reading (18:51 CST): meters **0** · readings 0 · allocations 0 / lines 0 · V25 rule NULL · `energy_kwh` values 0 · runs created since the
  window opened **0** · electricity lines 6 live / 4 open estimates / 1 relieved (identical to the MES-5a-2 before- and after-readings) ·
  `require_calibrated_since` NULL · notifications 2 · 7 accounts, 0 banned. Nobody used the new energy features in the window.

## 2 · Read-only verification

### a · The opening live readings, as recorded in the hand-back — present

`docs/handbacks/MES-5a-2.md:13-34` (§0): opening reading 14:18 CST (`docs/surveys/MES-5a-2/opening-readings.sql`) and full before-reading 15:37:54 CST
(`db/scripts/2026-10-08-mes5a2-live-readings.sql`), as `postgres`, base tables; reconciliation in tim@'s session. Every item the MES-5a-2 brief's
"Opening reading" named is there: devices by kind (`:26`, 2 scales · 2 gateways · **0 meters**, so no meter `equipment_id` to report) · runs with
`energy_kwh` (`:27`, 0) · hand-typed electricity lines (`:28`, 6 live: 5 estimates, 1 actual; 4 open; 1 relieved) · AP / AR (`:25`, 422,188.32 /
381,604.42 / **0.00** · 57,545.87 / 43,002.12 / **0.00**). Plus accounts, approvals, pending documents, system accounts, change log, notifications,
`require_calibrated_since`, table count. The same figures re-read after the proof in §6.3 (`:218-237`).

### b · The MES-5a-2 brief's "Fixtures must cover" list — **one item is half covered: the paid (Cr bank) journal**

The brief's list (MES-5a-2 session transcript, user message of 2026-10-08 06:17:33Z) against fixture 256
(`db/fixtures/256-a-meter-reads-a-register-a-run-gets-its-share-and-a-bill-posts-once.sql`):

| Brief item | Fixture · arm | Lines |
|---|---|---|
| meters with and without a machine; only `action.manage_devices` sets it | 256 METER | refused `:165-166`; with / without machine `:167-174`; move refused `:175-177`; move allowed `:178-181` |
| readings: append-only, correction with a reason, lower refused, reset with reason accepted, entry permission | 256 READ | permission `:185-186`; lower `:194-195`; reset no reason / with reason `:206-209`; correction `:224-229`; superseded `:230-231`; withdraw `:235-239`; append-only `:241-246` |
| run energy: own value used; discharge recovered shown apart | 256 RUNE | `:282-288`, `:404-409` |
| Q22 split: all recorded → by energy; one missing → whole machine by run time; basis on every line | 256 SPLIT | `:305-312` |
| per tonne on total input | 256 TONNE | `:411-416` |
| allocation: preview = posting; one expense; per-run lines; journal; covered estimates relieved, uncovered untouched; unmetered / shared left in 6200; AP = ledger 0.00 | 256 ALLOC (+ SPLIT `:315-318`) | header `:347-355`; lines `:356-361`; expense `:363-367`; journal `:369-372`; settled lines `:374-383`; estimates `:385-391`; ledger moves `:394-397`; AP = ledger `:399-402` |
| — **the journal "Cr AP or bank"** | 256 ALLOC — **AP only** | the only post in the fixture is `'unpaid'` (`:335`, `:343`) and the assertion is `2000:credit` (`:371`). **No arm posts a paid bill; no arm asserts the bank credit.** The live proof also posted unpaid only (`db/scripts/2026-10-08-mes5a2-live-proof.sql:216-237`). |
| foreign-currency bill refused by name; base read from data | 256 CCY | `:321-327` |
| refused without `module.finance.edit` | 256 PERM | `:335-336` |
| amounts masked without `data.view_prices`, kWh visible | 256 MASK | `:427-439` |
| change-log binding of every new table, 235 at 8, the `electricity_allocation` trail, wording arm | 256 LOG + `scripts/check-trail-wording.mjs` ㉒ | `:443-455`; wording item d |
| V25 | 256 V25 | `:292-295`, `:459-472` |
| masked-view side of the inbound `module_count` grant check | 255 MC (injection only) | `db/scripts/2026-10-08-mes5a2-fixture-injections.py`, last cell |

**The paid branch, measured on the local rebuild** (not a fixture; `paid-branch.sql` in the scratch directory, `PAID_OWN_EXIT=0`, ROLLBACK): an
all-codes session posted a paid SGD 250 / 200 kWh bill with no runs against bank `1000` → journal **Dr 6200 250.00 · Cr 1000 250.00**, expense
`paid`, bank `1000`; the same with bank `1010` refused `ELECTRICITY_BANK_NOT_BASE|1010|SGD`; AP / AR unexplained 0.00 / 0.00. **So the branch works
today; what is missing is the fixture arm and its injection.**

**Fault injection, re-run.** The recorded run (`INJECTIONS_OWN_EXIT=0`, log written 14:45:34 CST) cannot postdate the last edit of fixture 256 and
of the injection script (both 14:45:30 CST) — 42 cases do not run in four seconds. So the script was re-run against the local rebuild of HEAD:
**`INJECTIONS_OWN_EXIT=0` — 41 injections on 256 + 1 on 255, 0 wrong**, each red in the arm it names (READ 10 · SPLIT 5 · ALLOC 5 · MASK 3 · PERM 3 ·
METER 2 · RUNE 2 · CCY 2 · LOG 2 · V25 2 · TONNE 1 · REV 1 · SPLIT|ALLOC 1 · CCY|REV 1 · CCY|SPLIT 1; 255 MC 1), and the clean run green. Fixtures
alone on the same rebuild: 100 · 235 · 255 · 256 all exit 0.

### c · Q35 — recorded; `relieve_processing_accruals` not touched, so the literal stays (as the ruling says)

- Known issue `MES5A2-RELIEVE-SGD-LITERAL`, `docs/known-issues.md:10497-10506`: the `'SGD', 1` literal and why `scripts/check-currency-literals.mjs`
  does not see a literal inside `INSERT … VALUES`.
- The literal: `db/functions/relieve_processing_accruals.sql:105` (`… p_actual_amount, 'SGD', 1,`).
- Not touched: `git show --stat 6a12e569` lists no `relieve_processing_accruals.sql`; its last commit is `e8fcfb6c` (AP-RECON-1 Batch B). The
  allocation's own posting reads the base from data (`db/functions/post_electricity_allocation.sql:28`, `base_currency_code()`), asserted by 256 CCY `:323-327`.

### d · V25, change-log binding, the `electricity_allocation` trail, the wording arm — present (arm number differs from the brief)

- V25 arm: `db/views/pending_values.sql:249-258` (`'V25'`, `module.finance.view`, listed while the rule is NULL and a non-retired meter has no
  machine). Docs row `docs/mes-pending-values.md:38`, plus "What V25 holds back" `:122-126`.
- Change log: two triggers each in `db/views/zzz_change_log_triggers.sql` — `electricity_allocation_lines` `:269-272`, `electricity_allocations`
  `:273-276`, `electricity_settings` `:277-280`, `meter_readings` `:601-604`, all bound to `'id'` (the primary key). On the rebuild
  `change_log_coverage_gaps()` = `{"gaps": [], "bound": 274, "examined": 282, "excluded": 8}`.
- Trail: subjects `electricity_allocation` and `electricity_settings` (`db/functions/trail_subjects.sql:281-282`); members — the allocation's lines
  and the run's line (`db/functions/trail_subject_members.sql:508-509`); 256 LOG asserts all three trails (`:450-455`).
- Wording arm: **㉒, not ㉑** — ㉑ was already MES-5a-1's (`scripts/check-trail-wording.mjs:49`); the arm is `:5635-5641`, its fault guard `:5810`. This is
  the hand-back's self-taken decision 15 (`docs/handbacks/MES-5a-2.md:276`); the current brief still says ㉑. Run here: clean `TW_CLEAN_OWN_EXIT=0`
  (`✓ ㉒`); `TRAIL_WORDING_FAULT=wording-drift-mes5a2` → `TW_FAULT_OWN_EXIT=1`, **only** `✗ ㉒ … 2 处`.

### e · Fixture 100 — 31 → 32, only the new function, nothing loosened

`git show 6a12e569 -- db/fixtures/100-every-document-code-still-mints-identically.sql`: one hunk, +3 / −2 —

```
-    IF v_n <> 31 THEN
-        RAISE EXCEPTION 'FIXTURE 100/5 失败:按 MAX(split_part(code)) 取号的函数应有 31 支,这次只看见 % 支'
+    -- ★ MES-5a-2:31 → 32(post_electricity_allocation —— 电费单的费用单编号,与 relieve_processing_accruals 同一套 EXP 取号,带 LIKE 过滤)。
+    IF v_n <> 32 THEN
+        RAISE EXCEPTION 'FIXTURE 100/5 失败:按 MAX(split_part(code)) 取号的函数应有 32 支,这次只看见 % 支'
```

The LIKE-filter check beside it (`:330-346`, the scan and `v_bad`) is unchanged. On the rebuild, the arm's own predicate (comments stripped) counts
**32** functions, **0** without the LIKE filter; the only one absent from the parent commit is `post_electricity_allocation` (no mirror at `5647ea6f`),
which mints `EXP-…` behind `code LIKE …` (`db/functions/post_electricity_allocation.sql:62-66`). Reason in the hand-back §2.2 (`:103-105`).

### f · Usability with one code each — **none of the three works**

Measured three ways: the page gate with the app's own evaluator (`allows()` from `lib/modules.ts`, run with `tsx` against the real `FN` / `MOD`
entries); the page's reads and the action's RPC as a session holding exactly that one code on the local rebuild (`usability-f.sql`, `F_OWN_EXIT=0`,
ROLLBACK); and the code paths.

| Session holds only | Page gate | Page reads (rows) | The action's RPC | Works on the page? |
|---|---|---|---|---|
| `action.manage_devices` | `/operation/devices` and `/[id]`: `requireFunction(FN.devices)` = `module.processing.view` (`app/operation/devices/[id]/page.tsx:48`, `lib/modules.ts:471`, `:361`) → **refused** | `devices` 0 (policy `module.processing.view`, `db/tables/devices.sql:104-106`) · `equipment_usage` 0 (machine picker) | `save_device` new meter on a machine **OK**; link an existing meter to a machine **OK** (`save_device.sql:30`) | **No** — the page refuses before it renders; even past the gate the device would not load and the machine picker would be empty |
| `action.confirm_capture` | same gate → **refused** | `devices` 0 · `meter_readings_current` 0 | `record_meter_reading` **OK** (`record_meter_reading.sql:20`) | **No** — page refused |
| `module.finance.edit` | `/finance/electricity`, `/new`, `/[id]`: `requireModule(MOD.finance)` = `module.finance.view` (`app/finance/electricity/new/page.tsx:16`, `lib/modules.ts:573`, `:367`) → **refused** | `supplier_lookup` 0 · `electricity_allocations_masked` 0 | preview **refused** `PERMISSION_DENIED\|module.finance.view` (`preview_electricity_allocation.sql:16`); post **OK** — the RPC posted a 100 / 100 bill with no preview (`post_electricity_allocation.sql:40` asks only `module.finance.edit`) | **No** — page refused; and on the page Post stays disabled until a preview exists (`NewAllocationForm.tsx:127`), which this session cannot get |

So each action code works at the database and not at all through the page, because every page involved is entered with a **view** code. Two
side facts from the same measurement:
- **Making a device a meter** happens when it is registered (on `/operation/devices`); the kind is fixed afterwards (`save_device.sql:55`). On the device
  page the machine link is set in the edit form — the brief's "make a device a meter … on the device page" is therefore two pages.
- **`post_electricity_allocation` asks less than its own preview** (`module.finance.edit` vs `module.finance.view`): a session with edit and without
  view can post a bill it was never allowed to preview. Not reachable through the page (above); reachable through the RPC.

**On live today nobody is in this position** (`closeout-readings.sql` part 2): admin holds all five codes; cto holds `action.manage_devices` +
`action.confirm_capture` + `module.processing.view`; warehouse `action.confirm_capture` + `module.processing.view`; finance `module.finance.edit` +
`module.finance.view` — one live holder each. The hand-back's role table (`docs/handbacks/MES-5a-2.md:56-59`) says what each control **needs**; it is
accurate for those four roles and silent on the view code a page also needs.

### g · Self-taken decisions in `docs/handbacks/MES-5a-2.md` §7 (titles)

1. V25 lives in a new one-row table `electricity_settings`, recorded not applied.
2. `bill_kwh` is required.
3. A register reset makes the interval across it unmeasured.
4. A machine counts as measured only if each of its meters has two readings in the period.
5. A run belongs to a period by its `process_date` (Asia/Singapore days).
6. Rounding: kWh to 0.001, amounts to the cent, overhead = bill − allocated.
7. Periods may not overlap; a run already allocated is refused.
8. The share lines are settled through `remitted_*`.
9. Relieved estimates are soft-deleted with `relieved_at` / `relief_expense_id`.
10. `reverse_expense` refuses an allocation's expense; no allocation reversal in this cut.
11. The expense's account is `fin_cost_account('electricity')` = 5110, no GST line.
12. 6200 is promoted to a system account.
13. Preview needs `module.finance.view`; posting needs `module.finance.edit`.
14. The page offers the base currency only; a paid bill uses the base-currency bank account.
15. The wording arm is ㉒.
16. No month-end change.
17. The input-batch picker got `basis-full sm:basis-0`.
18. The live proof's machines, operation and batch are the proof's own.
19. The role table reads as one-off clones of the seven real roles.

## 3 · Recommendations (not applied)

- **b — add the paid arm.** One arm in fixture 256 (e.g. ALLOC-PAID): post a paid base-currency bill against the base bank account; assert
  Dr 2200 / Dr 6200 / **Cr the bank**, the expense `paid` with that bank and no supplier needed, and `ELECTRICITY_BANK_NOT_BASE` for a foreign-currency
  bank; with its own injection (credit 2000 on a paid bill → red in that arm). The branch already works (measured above), so this is coverage, not a fix.
  It can ride in MES-5b's first commit, since MES-5b's F1 (allocation reversal) has to reverse both branches anyway.
- **f — Tim's call, and I recommend (A).**
  **(A)** Rule that an action / edit code is only ever granted together with the view code of the module whose page uses it — which is how all four
  live roles already stand — and make that a mechanism, not a note: a guard on `role_permissions` (or the role editor's save) that refuses
  `action.manage_devices` / `action.confirm_capture` without `module.processing.view` and `module.finance.edit` without `module.finance.view`, with a
  fixture. While in there, make `post_electricity_allocation` ask `module.finance.view` as well, so the post never asks less than its preview.
  **(B)** Widen the device and electricity pages, and the `devices` / `meter_readings` / `equipment_usage` / `supplier_lookup` read policies, to admit
  action-code holders. More surface, every page and policy would carry a second rule, and it does not match how roles are granted.
- **Documentation only (does not stop anything):** the hand-back's role table could say "needs X **and** the page's view code".

## 4 · Assertions measured and found false or imprecise

- **The brief's "wording arm ㉑"** — the arm is ㉒ (item d); the hand-back recorded the renumbering as decision 15.
- **The MES-5a-2 report's injection run** was not the last thing before the push: it predates the last edit of fixture 256 and of the injection
  script (item b). Re-run on HEAD: unchanged verdict.
- **The MES-5a-2 report's "Fixtures must cover … Cr AP or bank"** reads as covered in the hand-back (§2.2 lists ALLOC); only the AP half is.
- **The hand-back's role table** states the code each control needs; that code alone does not open the page (item f).
- Zero other assertions found false.
