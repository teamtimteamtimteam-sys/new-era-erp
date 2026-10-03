# AUDIT-TRAIL-1c-2 — the other documents and contracts: sales, freight documents, fixed assets, bank statements, GST periods, FX rates, management packs, contracts; plus the 1c-1 close-out (2026-10-04)

Part of v1.4.33, not yet released.

**Opening check:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `f25830288b8703de36eb066de5ae093139f54e2c` (AT-1c-1), measured at
**2026-10-03 17:20:24 CST** (this session's first command). **Approvals were ON and stayed ON** (finance / cfo / 1,000).

Every figure below is either a script's own exit line or a query named with who ran it:
- unless stated otherwise, `postgres` (`rolbypassrls = true`) reading base tables;
- "as X" means `SET LOCAL ROLE authenticated` plus X's JWT.

This is cut 2 of the 3 AT-1c cuts (1c-1 → **1c-2** → 1c-3). It is built on Tim's answers to `docs/surveys/AUDIT-TRAIL-1c/STEP0-HANDBACK.md`
(Q1–Q34, all accepted as recommended, 2026-10-03). Reference for the mechanism: **`docs/change-log.md` §9** (§9.12 is new).

## §1 · Step 1 — the 1c-1 close-out, item by item

All read-only. Nothing was missing, so step 2 went ahead.

**1. The 1c-1 broken window** is recorded in `docs/forward-queue.md` item 27, in the 1b-3 format:

| | value | source |
|---|---|---|
| start | **2026-10-03 15:26:50 CST** | `db/migration-windows.tsv` (`2026-10-03-at1c1-trails-ledger-documents.sql`) |
| end, lower bound | **2026-10-03 17:16:34 CST** | `git reflog show --date=iso refs/remotes/origin/main`: `f2583028 … 2026-10-03 17:16:34 +0800: update by push` |
| end, upper bound | **2026-10-03 17:20:24 CST** | this session's first command. It rests on Tim's "deployed", **not** on a Vercel reading |
| window | **at least 1 h 49 min 44 s, at most 1 h 53 min 34 s** | |

**2. The zh/en mismatch** is registered as `AT1C1-TRAIL-ZH-EN-ONE-UNEXPLAINED-MISMATCH` in `docs/known-issues.md`:
- **The page:** journal **JE-2026-0001** (`/finance/journal/9aca7a6c-fc60-4f6a-83bf-3aea84c535a5`).
- **The reading:** the first probe run (16:12 CST) gave Chinese 667 characters, English 683.
- **What differed is not known.** That run predates the probe's "where they part" print.
- **The rule it breaks:** a trail renders identically in both interfaces.

**One correction to the brief, from the logs.** The same journal was compared **seven** more times, not five, and all seven matched:
- four plain runs: 16:15 · 16:18 · 16:21 · 16:40;
- three runs carrying other injections: 17:06 · 17:09 · 17:12.

The 17:14 `cjk` run was red on purpose. Source: `grep "fold-in 3 [admin] /finance/journal/9aca7a6c"` over `/tmp/claude-501/at1c1-probe*.log`
and `at1c1-pinj-*.log`.

This session's probe compared that journal six more times. Five matched, each reading the same 667 characters in zh and en (§7.3): the plain run, the rerun, and the banner-noby, history-back and refusal-wrong runs. The `cjk` injection run was red on purpose.

**3. Read-only verification of what the 1c-1 report did not mention.**

**a — Q11 is in known issues and is the first item under UNBLOCK-1.** ✅
- `docs/known-issues.md`: `## AT1C1-PAYROLL-JOURNAL-SHOWS-INDIVIDUAL-PAY`.
- `docs/forward-queue.md` UNBLOCK-1: its first bullet is "★ 第一条(Tim 的 AT-1c Q11 …)".

**b — Q2: the approval-policy panel is under AT-1d.** ✅
- `docs/forward-queue.md` AT-1d entry: "审批方针那一块面板归这里(Tim 的 AT-1c Q2,2026-10-03)… `approval_policy` 主语".

**c — Q34: the 1b-3 defect-28 golden exists and goes red under injection.** ✅
- The goldens are in `scripts/check-trail-wording.mjs`:
  - "Step deleted · Lunch" → "Target date: 05/10/2026", "Done: No";
  - before the log: "Previous step target date …", "Step was ticked: No".
- Injected in a scratch copy of HEAD (`git archive HEAD`, `lib/trail/render.ts` patched):

  | run | result |
  |---|---|
  | the logged path's lines emptied | `INJ1_OWN_EXIT=1`, "行 [] ≠ [Target date …]" |
  | the history path's lines emptied | `INJ2_OWN_EXIT=1` |
  | restored | `RESTORED_OWN_EXIT=0` |
  | clean | `CLEAN_OWN_EXIT=0` |
- The 1b-3 hand-back correction is at `docs/handbacks/AUDIT-TRAIL-1b-3.md:267-269`.

**d — Q5: a written-off batch's payable opens read-only with its banner.** ✅
- `app/finance/payables/[batchId]/page.tsx`:
  - the `deleted_records` row;
  - `<EndedBanner kind="writtenOff" …>`;
  - the page's only control (attachments) sits inside `EndedFieldset`.
- The 1c-1 probe read "Q5 [cfo] written-off batch IN-2026-0002 … «Written off on 08/09/2026 by Tim», read-only, trail entries".

**e — Q9: stamp-only events are registered for the 1c-1 subjects.** ✅
- `db/functions/trail_prelog_sources.sql` at HEAD registers invoices `voided_at`, payment_requests `paid_at` and expense_claims `decided_at`.
- Fixture 241 arm S covers them.
- The other two of the five stamps (freight reversal, statement reconciled) belong to 1c-2 subjects; this cut registers them.

**f — Q13, Q31 and Q33.** ✅
- **Q13:** `trail_refs` resolves `allocations`. Golden: "EXP-2026-0004: 300.00 (document currency)".
- **Q31:** golden "Payment reversed · PMT-2026-0010" on the original, on the mirror and before the log.
- **Q33:** golden "Journal reversed" plus one line "Reversed by: JE-2026-0091", with its `href` asserted.
- Fixture 241 J raises if the reversal's lines leak.

**g — Q26: replaced sections and kept working lists.** ✅
- The invoice's "Earlier requests" list is removed (the `history` prop is gone compared with `66a1b331`).
- The payment-request decision block is kept.
- All seven 1c-1 pages carry `<AuditTrail` at the bottom.

**h — Q27 and Q28 for the 1c-1 subjects.** ✅
- Measured over the 24 tables of the seven subjects (`SUBJECT_TABLES`): 302 shown columns, **0 labels equal to the column name**.
- 33 of those columns are enums. **One** has no value map: `inbound_batches.status`.
- That column is **not** among the payable's `root_columns`, so no 1c-1 page shows it.
- It is registered as `AT1C2-INBOUND-STATUS-HAS-NO-VALUE-MAP`, because the 1b batch page does show it.

**i — Q24 is registered, and change-log §9 covers M7, Q16, Q12 and the 1c-1 subjects.** ✅
- `docs/known-issues.md`: `## AT1C1-UNRECONCILE-WRITES-TIMESTAMP-INTO-NOTES`.
- `docs/change-log.md`: the §9.9 M7 row; §9.1 "Every row carries its operation (`op_key` …, Q16)"; §9.11 "Employee names in references (Q12)";
  the seven 1c-1 rows of the §9 table.

**j — the decisions 1c-1 took without asking** (`docs/handbacks/AUDIT-TRAIL-1c-1.md` §10, titles only):
1. The `payable` root columns.
2. Home records for the summary page.
3. Auto-approval is inferred, not stored.
4. Label parts.
5. Reversal reasons.
6. Allocation amounts.
7. Banners.
8. `ListTrail` merges by `op_key`.
9. `href` is generic.
10. Q15 is fixed for every caller.
11. `record_trail` is dropped and re-created.
12. Fixture 241 tests M7 with a temporary subject.
13. Labels for the 1b-shown tables were hand-checked under Q27.
14. Bank account codes 1000 / 1010 read "Cash at Bank – SGD / USD".
15. Claims and asset cost entries are members of `expense`.
16. Credit-note text keys are `cnote.*`.
17. `/finance/payment-requests/[id]` is skipped in the smoke.
18. "Each subject's field edit" is covered in three different ways.
19. The proof's setup choices.
20. The probe's one unexplained mismatch.
21. Fixture 241 needed 11 offline-gate runs.

## §2 · Subjects covered

| Step 0 §a subject | 1c-2 |
|---|---|
| `sale` (Q14) · `freight` · `fixed_asset` (Q10; the old history panel is replaced) · `bank_statement` (Q6 deleted statements, Q24) · `gst_period` (Q22 · Q23) · `fx_rate` (Q7 withdrawn rates) · `management_pack` (Q25) · `contract` (Q21) | ✅ all eight |
| Q9's remaining stamps: `freight_documents.reversed_at`, `bank_statements.reconciled_at` | ✅ |
| Queued from 1c-1: field-edit fixture arms and goldens for payment requests and credit notes | ✅, plus goldens for "Payment changed" and "Invoice changed" |
| `finance_lock` · `finance_gst` · `company_profile` · year closes · revaluation / depreciation runs · bulk FX · cash forecasts · payroll payments · processing settlement · WHT / transfer-list blocks · claims · import profiles · journal requests | ⬜ AT-1c-3. Those pages are untouched |
| `approval_policy` (`/settings/approvals`) | ⬜ AT-1d (Q2). Untouched |
| DATE-PICK-1 | untouched |

## §3 · What was built

### The registry

- **Eight subjects** are added to `trail_subjects()`, 44 in all.
  - **View code:** `module.finance.view`.
  - **Exception:** `contract` uses `module.suppliers.view`, matching the page's own `requireModule(MOD.suppliers)`.
- **Members** are added to `trail_subject_members()`:

| subject | members |
|---|---|
| sale | movements · attribution · invoice lines · payment allocations · attachments (home) · journals by `source_id` (`source_type = sale`) · `cogs_entry_id` and `reversed_by` (up) |
| freight | allocations (home) · payment allocations · journals via `journal_entry_id`, `reversal_entry_id` and `reversed_by` |
| fixed_asset | history · cost entries · depreciation · anchors · disposal requests and their approvals · the equipment tables (not home) · handover refs · journals via `disposal_journal_id` / the depreciation `journal_entry_id` / `reversed_by` |
| bank_statement | lines · matches · reconciliations · variance items |
| gst_period | boxes · filing requests and their approvals. No self-link (Q22) |
| fx_rate | history |
| management_pack | the root only |
| contract | the seven term tables · terms requests (home) · their approvals (not home) · contract–document links (not home) |

- **Pre-log sources:** a creation stamp for every 1c-2 table, plus these event stamps:
  - the freight reversal;
  - the statement reconciled and deleted;
  - a reconciliation superseded;
  - a GST period filed;
  - disposal and filing requests withdrawn;
  - a pack superseded.

### The rulings

| ruling | built |
|---|---|
| **Q14** | The sale is a subject root. Its Record column reads "OUT-… sale DD/MM/YYYY" and links to `/finance/receivables/<id>` (`trail_ref_label`, `trail_row_record`). This is done **without** a `document_types` row (§10, item 1). The output batch's `sales_records` membership is no longer home |
| **Q10 · Q26** | `fixed_asset` is a second subject beside `equipment`. FA-HIST-1's "Change history" panel is deleted (`app/finance/assets/[id]/HistoryPanel.tsx`), along with its message keys (43 lines in en, 42 in zh) and its two `check-i18n` manifest entries. Before the log, `fixed_asset_history` speaks; after it, the card's own change-log rows do (one event, two rows) |
| **Q6** | `deleted_records` gains a `bank_statement` branch; "who" comes from the change log. The statement page opens a deleted statement read-only for holders of `data.view_deleted`; everyone else gets the named refusal. `/settings/deleted` links to it, and the statement's workspace redirects to it |
| **Q7** | The FX edit page opens a withdrawn rate read-only, with "Withdrawn on … by …" and the reason, both taken from its `withdrawn` history row |
| **Q8** | The freight page's amber block is replaced by the shared banner: "Reversed on … by …", the reason, and a link to the reversal journal. Its four now-unused message keys are deleted |
| **Q9** | `freight_documents.reversed_at` and `bank_statements.reconciled_at` are registered as event stamps |
| **Q21** | Contract trails. The CFO's decisions follow `approval_log`'s terms-request branch, so a reader without `module.pricing.view` sees them as Restricted. Proved in fixture 242 C |
| **Q22 · Q23** | No self-link on GST periods. The boxes fold into the filing entry, `label_en` only; `label_zh` is hidden |
| **Q24** | `unreconcileReason` recognises the machine suffix and says "Reconciliation undone" with the person's reason |
| **Q25** | Packs are proved in fixture 242 K and in the rolled-back live proof (§7.2). There is no live pack |
| **Q27 · Q28** | In the catalogue: **136 labels or kinds changed on 27 tables · 24 value maps added or changed · 14 record-type names changed**. Measured by diffing the committed catalogue (`git show HEAD:`) against the regenerated one. Every shown column of the eight subjects' 36 tables was checked (§9), and every enum column there has English |
| **A column that comes back is not a change** (found by the proof, §7.2) | `mergeUpdates` (`lib/trail/render.ts`, there since AT-1a) now drops a column that ends where it started inside one operation. A merged edit left with no columns says nothing |

### The migrations

Both were built from the mirrors:
- **`db/migrations/2026-10-04-at1c2-trails-documents-and-contracts.sql`** (builder: `db/scripts/build_at1c2_migration.py`):
  - six functions replaced in place, with the same signatures;
  - `deleted_records` replaced in place, with the same columns;
  - `NOTIFY pgrst`.
- **`db/migrations/2026-10-04-at1c2-fu1-trail-ref-label-journal-lines.sql`:** `trail_ref_label` replaced in place, adding the journal-line
  name the main file missed (§10, item 8).

No table, policy, table grant, trigger or permission code changed. No business row was written. The new fixture is **242**.

## §4 · Pages — every new or changed route, with its file

| route | file | change |
|---|---|---|
| `/finance/receivables/[saleId]` | `app/finance/receivables/[saleId]/page.tsx` | trail added at the bottom (subject `sale`) |
| `/finance/freight/[id]` | `app/finance/freight/[id]/page.tsx` | trail; the amber reversed block becomes `EndedBanner kind="reversed"` with who, the reason and the reversal-journal link (Q8) |
| `/finance/assets/[id]` | `app/finance/assets/[id]/page.tsx` (+ `HistoryPanel.tsx` **deleted**) | trail (subject `fixed_asset`) replaces the "Change history" panel; its queries are removed (Q10 · Q26) |
| `/finance/bank/statements/[id]` | `app/finance/bank/statements/[id]/page.tsx` | trail; a deleted statement opens read-only for `data.view_deleted` (`requireDeletedAccess`) with the "Deleted on …" banner; the workspace link is not drawn; the delete button sits inside `EndedFieldset` (Q6) |
| `/finance/bank/statements/[id]/reconcile` | `…/reconcile/page.tsx` | a deleted statement redirects to its detail page instead of opening the workspace |
| `/finance/gst/[periodId]` | `app/finance/gst/[periodId]/page.tsx` | trail (Q22 · Q23) |
| `/finance/fx/[id]/edit` | `app/finance/fx/[id]/edit/page.tsx` | trail; a withdrawn rate loads read-only with the "Withdrawn on … by …" banner, and the form sits inside `EndedFieldset` (Q7) |
| `/finance/packs/[id]` | `app/finance/packs/[id]/page.tsx` | trail (Q25) |
| `/contracts/[id]` | `app/contracts/[id]/page.tsx` | trail (Q21) |
| `/settings/deleted` | `app/settings/deleted/page.tsx` | links a deleted bank statement to its page |
| shared | `app/components/trail/AuditTrail.tsx`, `app/components/trail/EndedBanner.tsx` | the eight subjects and their roots; banner kind `withdrawn`; `DeletedKind` gains `bank_statement` |

Every trail page reads `trailCount(searchParams.trail)` ("Show older entries"), the same as 1b-1.

## §5 · Verification, in the brief's order

Each line is the script's own exit line from its own log (`/tmp/claude-501/at1c2-*.log`).

**Step 1 — offline gate `db/gate.py --offline`**
- **`GATE_OFFLINE_EXIT=0`** (66 s). Fixture 242 is included.

**Step 2 — backup `~/evoltrya-backups/backup.sh`, in the background**
- The first run gave `BACKUP_EXIT=1`: the pooler closed the connection during `dumpFunc`.
- Per AGENTS.md ("立刻重试一次"), it was retried once, immediately. **`BACKUP_EXIT=0`**, 00:58:46 → 01:15:48: `evoltrya-backup-2026-10-04-0058.dump`,
  5.6 MB, 7313 TOC entries.
- It finished before step 3.

**Step 3 — `db/apply_migration.sh`, main file**
- First a COMMIT→ROLLBACK dry run: `DRY_OWN_EXIT=0`.
- Then **`APPLY_OWN_EXIT=0`**: applying started 01:16:57 CST and committed at **01:18:22 CST**. **That is where the window starts.**

**Step 4 — `npm run types:gen`**
- `TYPES_OWN_EXIT=0`, and `lib/database.types.ts` is unchanged: no signature moved.

**Step 5 — `npx tsc --noEmit`**
- **`TSC_OWN_EXIT=0`**. Rerun: §5.1.

**Step 6 — `npm run build`**
- **`BUILD_OWN_EXIT=0`**. Rerun: §5.1.
- `check-cjk-rendered` shrank its baseline by one in `Wordmark.tsx`. That file is not from this cut; nothing in it was touched.

**Step 7 — full gate `db/gate.py`**
- The first run gave `GATE_EXIT=1`: `trail_ref_label` mirror ≠ live. The `journal_lines` branch had been added to the mirror after the
  migration was built.
- Fixed by the **fu1** migration: dry run `FU1_DRY_OWN_EXIT=0`, then apply `FU1_APPLY_OWN_EXIT=0` (01:29:53 → committed 01:31:04).
- The rerun gave **`GATE_EXIT=0`**, three verdicts in 422 s:
  - rebuildable ✓ (B1/B2 0 on live and rebuild);
  - mirrors = live ✓;
  - every fixture passes, 242 included ✓;
  - anon surface ✓ (326 relations + 1 function ⊆ baseline of 327);
  - `changelog`: 242 tables / 238 logged / 4 exempt, no gaps;
  - `changemask`: 27 / 81, no gaps;
  - `swallow` clean.

**Step 8 — i18n (part of the build)**
- "Every key the code references (including enumerable dynamic keys) exists in en and zh."

**Step 9 — error-swallowing (part of the build)**
- "swallowed query errors: 0 unallowed, 0 queued, 9 allowlisted".

**Step 10 — layout survey of the new or changed pages with a live row, desktop (1280) and 390 px**
- The pages: a sale, a freight document, both assets, both statements (one deleted), the GST period and one FX rate.
- **390 px: `SURVEY390_EXIT=0`**, U1 pan-free 9/9, U2 clipped tables 0.
- **1280: `SURVEY1280_EXIT=0`**, 9/9, 0.
- Packs and contracts have **no live row**, so the survey cannot open them. Their change is one `<AuditTrail>` at the bottom of an existing page.
- Touch targets under 44 px are reported, not judged.

**Step 11 — route smoke `scripts/smoke-routes.mjs`, in the background**
- **`SMOKE_EXIT=0`**: 243 routes, 234 timed.
- `/finance/packs/[id]` and `/finance/payment-requests/[id]` are skipped: there is no live row.
- **Scratch cleanup reading:**
  - The stale-row check reported the same 6 `ZZ-SMOKE-*` rows as before (754–1397 h old; 5 still referenced, so not deleted).
  - After the run, as `postgres`: 0 `smoke-*@test.local` / `probe-*` users, 0 `probe-*` roles, 0 such grants. `.ephemeral/` is empty.
- Rerun: §5.1.

**Step 12 — live verification**
- §7.

**Files changed after the build and the full gate, and what was rerun.** The proof (§7.2) found one renderer defect: the round-trip.
- **The fix touched:**
  - `lib/trail/render.ts`: `mergeUpdates`;
  - `scripts/check-trail-wording.mjs`: one golden, so arm ⑨ now has 44;
  - `docs/change-log.md`.
- **The proof script changed twice:**
  - The sale is recorded by admin@, because finance lacks `action.direct_sale`.
  - Its FX / GST / pack "no such row on live" assumptions are now guards that refuse. The FX guard is currency-free, so it passes the
    currency-literal check.
- **No file under `db/` that the gate reads changed after the gate:** not `db/functions`, `db/views` or `db/fixtures`. The gate was not rerun.
- **Not rerun:** the layout survey. The fix only removes lines that should never have been printed.
- Everything that reads the changed files was rerun: §5.1.

### §5.1 · Rerun after the late fix

| step | result |
|---|---|
| `node scripts/check-trail-wording.mjs` | **`WORDING_OWN_EXIT=0`**: ①–⑨ ✓ |
| `npx tsc --noEmit` | **`TSC2_OWN_EXIT=0`** |
| `npm run build` | **`BUILD2_OWN_EXIT=0`**:<br>• "currency literals: 0 unallowed"<br>• "swallowed query errors: 0 unallowed, 0 queued, 9 allowlisted"<br>• i18n ✓<br>• wording ①–⑨ ✓<br>• `next build` ✓<br>The first rerun was red: the currency-literal check flagged the proof's new FX guard. The guard was reworded and the build rerun |
| live proof | **`PROOF_OWN_EXIT=0`** (02:46:38–02:46:53), §7.2 |
| route smoke (full) | **`SMOKE2_OWN_EXIT=0`**, 02:48–03:00:
• 243 routes, 234 timed, 0 failed
• the same skip list as the first run
• scratch reading: the same 6 stale `ZZ-SMOKE-*` rows; the run removed its own ephemeral account, role and grants (§7.1) |
| page probe | **`PROBE2_OWN_EXIT=0`** (`AT1C2_PROBE_EXIT=0`): 73 passed · 0 failed · 2 skipped, ending 03:08:57. JE-2026-0001 reads 667 = 667 again |

## §6 · Fault injection

**Fixture 242** (`db/scripts/2026-10-04-at1c2-fixture-injections.py`, against the local rebuild):
- **`INJECTIONS_OWN_EXIT=0 (25 injections, 0 wrong)`**: clean 242 green, then each injection red in its own arm.
- Log: `/tmp/claude-501/at1c2-fixture-inj.log`. The run followed reloading this cut's six function mirrors and the view mirror into the local cluster.
- Three injections did not bite on the first try. Each was redesigned until it did (§10, item 9).

**Wording check** (`TRAIL_WORDING_FAULT=<name>`):

| injection | arms that went red |
|---|---|
| `blind-detector` | ① |
| `raw-ref` | ④ ⑥ ⑧ ⑨ |
| `raw-null` | ④ ⑥ ⑦ ⑧ ⑨ |
| `raw-date` | ④ ⑥ ⑦ ⑧ ⑨ |
| **`wording-drift-1c2`** (new) | ⑨ only |

**The round-trip golden** (the late fix):
- Run on a full scratch copy of the tree (`/tmp/claude-501/at1c2-inj`), never the working tree:

  | run | result |
  |---|---|
  | clean | `CLEAN_COPY_OWN_EXIT=0` |
  | the filter removed from `mergeUpdates` | **`INJ_RT_OWN_EXIT=1`**: ⑨ red on exactly this golden, printing `Status: Open → Open`, `Reconciled on: (empty) → (empty)` |
  | restored | `RESTORED_RT_OWN_EXIT=0` |
- The first two attempts copied only part of the tree and crashed on a missing file. Those reds were read and discarded, not counted.

**Page probe** `scripts/probe-at1c2.mjs` with `--inject=banner-noby · history-back · refusal-wrong · cjk`:
- Each run went red in its own checks with its own exit line (`INJ_OWN_EXIT=1`, `AT1C2_PROBE_EXIT=1`), run one after another after the plain run.

| injection | what went red |
|---|---|
| `banner-noby` | the Q8 freight banner check |
| `history-back` | both Q26 asset checks |
| `refusal-wrong` | the Q6 gm refusal |
| `cjk` | all 33 fold-in-3 checks |

- The un-injected run is 73 / 0 / 2.

## §7 · Live verification

### §7.1 · Before / after readings

- **Readings:** `db/scripts/2026-10-04-at1c2-live-readings.sql`.
- **Reconciliation:** `list_ledger_reconciliation()` as tim@ (`db/scripts/2026-10-04-at1c2-live-recon.sql`).
- **Before:** 00:52:18 (before the backup and the migration). **After:** 03:09:19 (after the smokes, the probes and the proofs).

| reading | before 00:52:18 | after 03:09:19 |
|---|---|---|
| tables · every-row digest | 241 · `795ac59ff3da` | 241 · `2829081bdcc7` (below) |
| change_log | 2986 rows, max seq 3361 | 3394 rows, max seq 3993 (below) |
| accounts | 7, 0 disabled | 7, 0 disabled |
| approvals | ON | ON |
| pending documents · their digest | 8 · `c113de0d5542` | 8 · `c113de0d5542` |
| POs · journals | 11 (last PO-2026-0011) · 82 (last JE-2027-0003) | identical |
| sales · freight · assets | 9, 0 unattributed · 4, last FRT-2027-0003, 4 reversed · 2, last FA-2026-0002, 0 disposed | identical |
| statements · GST periods · FX rates | 2, last BS-2026-0002, 1 deleted · 1, last GST-2026-Q3 · 12, 0 withdrawn, latest 17/08/2026 | identical |
| packs · contracts | 0 · 0 | 0 · 0 |
| 1c-2 rows | 0 FX history · 2 asset history · 0 reconciliations · 0 GST boxes · 0 terms requests · 4 finance attachments | identical |

**Reconciliation** (as tim@), before and after, identical:
- AP: list 416,988.32 · ledger 376,404.42 · **unexplained 0.00** · agrees.
- AR: list 57,545.87 · ledger 43,002.12 · **unexplained 0.00** · agrees.

**Why the digest and the change log moved.** The 408 change-log rows with `seq > 3361` (read as `postgres`) were grouped by table and
operation, then netted by row key.
- **Every key nets to zero except two.** The pairs that net to zero:
  - the ephemeral accounts of the two smokes, the surveys and the probes: `user_roles` 22 / 22, `employees` 10 / 10,
    `performance_reviews` 4 inserts + 4 updates / 4 deletes;
  - the smokes' roles: `roles` 2 / 2, `role_permissions` 144 / 144;
  - the smokes' contract seed: `contracts` 4 / 4, and the six term tables 2–4 / 2–4.
- **The exception is `cod_verification_failures`:**
  - row 144 was deleted (02:07:50) and row 146 inserted (03:02:03), with 145 in between;
  - this is the smoke's documented COD-verify probe, whose `not_found` branch rotates that table, once per smoke;
  - the table holds 1 row before and after.
  - That rotation is the only net change on live, and it is what moved the every-row digest.
- **No `*@test.local` user or `probe-*` role remains.** `.ephemeral/` is empty.

**The rolled-back proofs left nothing behind.**
- No change-log row falls inside any proof run.
- Every count, last number and the pending digest are identical, so no pre-existing document changed.
- The change-log sequence has exactly **one gap** since the before reading: **224 numbers (seq 3587–3810)**, between 02:40:41 and 02:48:16.
- That span holds the three proof runs (02:40:54, 02:41:47, 02:46:38) and no other live writer. Sequences are not transactional, so those
  numbers are the proofs' own change-log rows, written and then discarded by their rollbacks.
- The proofs also advanced document-number sequences such as `CON-2026-0082` the same way. A sequence advancing is not a row.

### §7.2 · Proof (`db/scripts/2026-10-04-at1c2-live-proof.sql`, `PROOF_OWN_EXIT=0`)

**A — read-only.** As tim@, `record_trail` for **every record of the eight subjects on live: 30 records**:
- 9 sales, 4 freight documents, 2 assets, 2 statements, 1 GST period, 12 FX rates, 0 packs, 0 contracts.

Checks:
- No record is refused, and every root has its creation.
- Nothing appears twice.
- **Q9:** the reversal stamp comes back on all 4 reversed freight documents, and the reconciliation stamp on BS-2026-0002 (reconciled,
  with no reconciliation record).
- **Q6:** the deletion stamp of BS-2026-0001.
- **Q10:** both live `fixed_asset_history` rows are on their asset's trail.

**B — one rolled-back transaction, with approvals ON.** Who did what:
- chooer@ (finance) submits and does;
- tim@ (cfo) decides;
- sandra@ (cco) creates the supplier, the forwarder and the contract;
- admin@ does the setup and records the sale (§10, item 17).

What it creates:
- a walk-in sale, then attributes it;
- a freight document **FRT-2026-0002**: notes changed, then reversed;
- an asset **FA-2026-0003**: life changed, cost added via EXP-2026-0010, put in service, disposal requested, then approved by tim@;
- statement **BS-2026-0003**: notes changed, both lines ignored, reconciled with the whole difference explained, then undone;
- a second statement **BS-2026-0004**, deleted;
- GST **GST-2026-Q2**: notes changed, filing requested, approved, filed; then correction **GST-2026-Q2-F7-1**;
- a USD tt_sell rate for 02/10/2026: recorded, corrected, withdrawn;
- packs **PACK-2026-07**, then **PACK-2026-07-2**, which replaces it;
- contract **CON-2026-0082**: title changed, a grade spec added, activation requested, then approved by tim@.

Before any of it, the script **refuses** if any tt_sell rate for 02/10/2026, a GST period overlapping 2026 Q2, or a pack for
07/2026 already exists on live. Without that guard, the second `record_fx_rate` would correct a pre-existing rate. All three were 0.

It reads every trail as tim@ and confirms the deleted statement is listed in `deleted_records` with chooer@ as the person. Then it ends in
`ROLLBACK`.

**The result:**
- `scripts/…/render-proof.mjs` (the real `buildEntries`) renders **41 records into 73 entries, with 0 machine tokens**.
- No line has the same value on both sides of its arrow.
- **The runs, in order:**
  1. 02:40:54 failed on `PERMISSION_DENIED|action.direct_sale` (§10, item 17). With `ON_ERROR_STOP` the session ended inside the open
     transaction, so nothing was committed.
  2. 02:41:47 passed, with the sale moved to admin@.
  3. 02:46:38 passed, the final script (the FX guard reworded for the currency-literal check). The figures above are from this run.

**One thing to read correctly:** the whole proof is **one transaction**. Q16 therefore merges every event of one record into one entry
(one `op_key`), exactly as 1c-1 §6.3 described. On live, each person's action is its own transaction and gets its own entry.

**The defect the proof found** (fixed, with a golden that goes red when the fix is removed, §6):
- **What it printed:** BS-2026-0003 was reconciled and undone in the same transaction. Its entry also printed
  "Bank statement changed · Status: Open → Open · Reconciled on: (empty) → (empty) · Reconciled by: (empty) → (empty)".
- **The cause:** `mergeUpdates` (since AT-1a) took the first old value and the last new value, and kept columns whose net value had not moved.
- **The fix:** merged rows now drop those columns. The second render of the same output differs from the first only by those four lines.

### §7.3 · Page probe `scripts/probe-at1c2.mjs` (cfo, admin and gm ephemeral accounts, port 3192)

**`AT1C2_PROBE_EXIT=0`: 73 passed · 0 failed · 2 skipped** (`/tmp/claude-501/at1c2-probe.log`, 02:10–02:19). The rerun after the fix is in §5.1.

What it checked:
- **Q6** (4 checks):
  - admin opens BS-2026-0001 read-only with «Deleted on 30/07/2026» and trail entries (nobody was recorded, so there is no "by");
  - gm gets the named refusal, not a 404;
  - the workspace URL sends you to the statement;
  - `/settings/deleted` lists it with a link.
- **Q8:** FRT-2026-0001 reads «Reversed on 20/08/2026 by Tim», with a link to the reversal journal.
- **Q26:** both asset pages have no "This trail starts on" (the old panel's tell) and do have the trail.
- **Every live record of six subjects, in both interfaces:** trail entries, no machine token, and zh = en character for character.
  - The records: 9 sales, 4 freight, 2 assets, 2 statements, 1 GST period, 12 FX rates.
  - The control pages: an AT-1a PO, an AT-1b batch (5,618 characters), and the AT-1c-1 journal JE-2026-0001 (667 = 667).
- **Skipped:** `management_pack` and `contract`, which have 0 live records. They are proved in fixture 242 and the rolled-back proof.

## §8 · Broken window

| | when | source |
|---|---|---|
| start | **2026-10-04 01:18:22 CST** | the main migration's commit, `db/migration-windows.tsv` |
| | 01:31:04 CST | fu1 committed (within the window) |
| end | the moment Tim sees the deployment Ready on Vercel | Tim's reading; this machine does not query Vercel |

**What is broken inside the window: one thing, found by reading the old page.**
- **The defect:** `/settings/deleted` (old code) labels each row with `t('deleted.kind.' + record_kind)`.
  - `deleted_records` now returns BS-2026-0001 as kind `bank_statement`, and the old message files have no `deleted.kind.bank_statement`.
  - So on that page, during the window, the statement's row shows the raw key `deleted.kind.bank_statement` as its kind, with no link.
  - The deployed code adds the key ('Bank statement' / '对账单') and the link.
- **What still works with the old app:**
  - The sale's Record column on the global Change history page now links to `/finance/receivables/<id>`, a page the old app has.
  - The old asset page's history panel reads `fixed_asset_history`, which is unchanged.
  - The old app never asks for the eight new subjects.

## §9 · New wordings and labels

### §9.1 · Event wordings (English; `lib/trail/text.ts`, 65 new keys)

Prefixes are `sale.` `frt.` `fa.` `bst.` `gstp.` `fxr.` `mpk.` `con.`. They avoid the `gst` / `pack` / `bank` / `assets` collisions with
`messages/en.ts`. Each wording was produced by the renderer and checked by hand; arm ⑨ pins 44 of them as whole entries.

| key | English |
|---|---|
| `banner.withdrawn` | Withdrawn on {date} by {who} |
| `banner.withdrawnDate` | Withdrawn on {date} |
| `sale.recorded` | Sale recorded |
| `sale.attributed` | Customer attributed to the sale |
| `sale.cogsPosted` | Cost of sales posted |
| `sale.changed` | Sale changed |
| `frt.recorded` | Freight document recorded |
| `frt.reversed` | Freight document reversed |
| `frt.changed` | Freight document changed |
| `frt.allocationChanged` | Freight allocation changed |
| `fa.inService` | Put into service |
| `fa.disposed` | Asset disposed |
| `fa.costAdded` | Cost added |
| `fa.costChanged` | Cost entry changed |
| `fa.depreciated` | Depreciation posted |
| `fa.rebased` | Depreciation re-based |
| `fa.disposalSent` | Disposal sent for approval |
| `fa.disposalApproved` | Disposal approved |
| `fa.disposalRejected` | Disposal rejected |
| `fa.disposalWithdrawn` | Disposal request withdrawn |
| `fa.disposalChanged` | Disposal request changed |
| `bst.imported` | Bank statement imported |
| `bst.lines` | Lines |
| `bst.deleted` | Bank statement deleted |
| `bst.reconciled` | Bank statement reconciled |
| `bst.unreconciled` | Reconciliation undone |
| `bst.changed` | Bank statement changed |
| `bst.lineMatched` | Statement line matched |
| `bst.lineUnmatched` | Statement line unmatched |
| `bst.lineIgnored` | Statement line ignored |
| `bst.lineUnignored` | Statement line no longer ignored |
| `bst.lineChanged` | Statement line changed |
| `bst.reconChanged` | Reconciliation record changed |
| `gstp.opened` | GST period opened |
| `gstp.correctionOpened` | Correction opened for {code} |
| `gstp.correctionOpenedPlain` | Correction period opened |
| `gstp.sent` | GST return sent for approval |
| `gstp.approved` | GST return approved |
| `gstp.rejected` | GST return rejected |
| `gstp.withdrawn` | GST return request withdrawn |
| `gstp.requestChanged` | GST return request changed |
| `gstp.locked` | GST return locked · {n} boxes |
| `gstp.box` | Box {n} |
| `gstp.filed` | GST return filed |
| `gstp.changed` | GST period changed |
| `fxr.recorded` | Exchange rate recorded |
| `fxr.corrected` | Exchange rate corrected |
| `fxr.withdrawn` | Exchange rate withdrawn |
| `fxr.changed` | Exchange rate changed |
| `mpk.produced` | Management pack produced |
| `mpk.superseded` | Management pack replaced |
| `mpk.replacedBy` | Replaced by |
| `mpk.changed` | Management pack changed |
| `con.created` | Contract created |
| `con.edited` | Contract changed |
| `con.activated` | Contract activated |
| `con.suspended` | Contract suspended |
| `con.statusChanged` | Contract status changed |
| `con.deleted` | Contract deleted |
| `con.termAdded` | {Thing} added |
| `con.termChanged` | {Thing} changed |
| `con.termRemoved` | {Thing} removed |
| `con.linked` | Linked to {code} |
| `con.linkedPlain` | Linked to an order |
| `tr.sentActivate` | Contract activation sent to the CFO |

Message files (interface strings, not trail text):
- **Added:** `deleted.kind.bank_statement`: 'Bank statement' / '对账单'.
- **Removed:** the `assets.history.*` block (43 lines in en, 42 in zh) and four freight banner keys, now that the shared banner says it.

### §9.2 · Field labels on the eight subjects' 36 tables (Q27 · Q28)

**357 shown columns, 0 labels equal to the column name; 139 hidden** (ids, timestamps the entry header already says, `label_zh`, machine
columns). The source is `lib/trail/catalogue.generated.ts`, from `scripts/gen-trail-catalogue.mjs`.

Points that are not obvious from the table:
- **The asset card adopts the old panel's wording**, so the trail says what the page used to say: "Originating expense", "Cost (transaction
  currency)" and so on.
- **The history pairs are derived, not hand-copied.** "Previous …" / "New …" are generated from the card's own labels and kinds.
- **A disposal's and a GST filing's `executed_at`** read "Carried out on".

| record type | field (column) | label |
|---|---|---|
| GST filing request | boxes | Boxes as submitted |
| GST filing request | decided_at | Decided on |
| GST filing request | decided_by | Decided by |
| GST filing request | decision_notes | Decision notes |
| GST filing request | executed_at | Carried out on |
| GST filing request | label | Request |
| GST filing request | note | Note |
| GST filing request | period_id | GST period |
| GST filing request | status | Status |
| GST filing request | withdraw_reason | Withdrawal reason |
| GST filing request | withdrawn_at | Withdrawn on |
| GST filing request | withdrawn_by | Withdrawn by |
| GST period | code | GST period number |
| GST period | corrects_period_id | Corrects period |
| GST period | filed_at | Filing recorded on |
| GST period | filed_by | Filing recorded by |
| GST period | filed_on | Filed on |
| GST period | filed_reference | IRAS acknowledgement |
| GST period | notes | Notes |
| GST period | period_end | Period end |
| GST period | period_start | Period start |
| GST period | status | Status |
| GST return box | box | Box |
| GST return box | label_en | Box description (English) |
| GST return box | period_id | GST period |
| GST return box | value_base | Value (base currency) |
| asset card change | new_acceptance_date | New acceptance date |
| asset card change | new_acquisition_date | New acquisition date |
| asset card change | new_category | New category |
| asset card change | new_code | New asset number |
| asset card change | new_cost_base | New cost (base currency) |
| asset card change | new_cost_ccy | New cost (transaction currency) |
| asset card change | new_currency | New currency |
| asset card change | new_depreciation_account_code | New depreciation account |
| asset card change | new_description | New description |
| asset card change | new_disposal_date | New disposal date |
| asset card change | new_disposal_journal_id | New disposal journal entry |
| asset card change | new_disposal_proceeds_base | New disposal proceeds (base currency) |
| asset card change | new_expense_id | New originating expense |
| asset card change | new_fx_rate | New FX rate at acquisition |
| asset card change | new_in_service_date | New in service from |
| asset card change | new_notes | New notes |
| asset card change | new_planned_in_service_date | New planned in service from |
| asset card change | new_residual_base | New residual value (base currency) |
| asset card change | new_status | New status |
| asset card change | new_useful_life_months | New useful life (months) |
| asset card change | old_acceptance_date | Previous acceptance date |
| asset card change | old_acquisition_date | Previous acquisition date |
| asset card change | old_category | Previous category |
| asset card change | old_code | Previous asset number |
| asset card change | old_cost_base | Previous cost (base currency) |
| asset card change | old_cost_ccy | Previous cost (transaction currency) |
| asset card change | old_currency | Previous currency |
| asset card change | old_depreciation_account_code | Previous depreciation account |
| asset card change | old_description | Previous description |
| asset card change | old_disposal_date | Previous disposal date |
| asset card change | old_disposal_journal_id | Previous disposal journal entry |
| asset card change | old_disposal_proceeds_base | Previous disposal proceeds (base currency) |
| asset card change | old_expense_id | Previous originating expense |
| asset card change | old_fx_rate | Previous FX rate at acquisition |
| asset card change | old_in_service_date | Previous in service from |
| asset card change | old_notes | Previous notes |
| asset card change | old_planned_in_service_date | Previous planned in service from |
| asset card change | old_residual_base | Previous residual value (base currency) |
| asset card change | old_status | Previous status |
| asset card change | old_useful_life_months | Previous useful life (months) |
| asset cost entry | amount_base | Amount (base currency) |
| asset cost entry | amount_ccy | Amount |
| asset cost entry | asset_id | Asset |
| asset cost entry | currency | Currency |
| asset cost entry | expense_id | From expense |
| asset cost entry | fx_rate | FX rate |
| asset disposal request | amount_base | Amount (base currency) |
| asset disposal request | asset_id | Asset |
| asset disposal request | bank_account | Bank account |
| asset disposal request | decided_at | Decided on |
| asset disposal request | decided_by | Decided by |
| asset disposal request | decision_notes | Decision notes |
| asset disposal request | disposal_date | Disposal date |
| asset disposal request | estimate | Estimate |
| asset disposal request | executed_at | Carried out on |
| asset disposal request | label | Request |
| asset disposal request | proceeds_base | Proceeds (base currency) |
| asset disposal request | reason | Reason |
| asset disposal request | result | Result |
| asset disposal request | result_entry_id | Posted as |
| asset disposal request | snapshot | Asset at the time |
| asset disposal request | status | Status |
| asset disposal request | withdraw_reason | Withdrawal reason |
| asset disposal request | withdrawn_at | Withdrawn on |
| asset disposal request | withdrawn_by | Withdrawn by |
| bank reconciliation | as_of | As at |
| bank reconciliation | bank_closing_balance | Bank closing balance |
| bank reconciliation | book_balance | Book balance |
| bank reconciliation | currency | Currency |
| bank reconciliation | difference | Difference |
| bank reconciliation | ignored_lines | Ignored lines |
| bank reconciliation | matched_lines | Matched lines |
| bank reconciliation | reconciled_at | Reconciled on |
| bank reconciliation | reconciled_by | Reconciled by |
| bank reconciliation | statement_id | Bank statement |
| bank reconciliation | superseded_at | Superseded on |
| bank reconciliation | superseded_reason | Why it was undone |
| bank statement line | amount | Amount |
| bank statement line | description | Description |
| bank statement line | ignore_reason | Why it is ignored |
| bank statement line | line_date | Date |
| bank statement line | line_no | Line |
| bank statement line | match_status | Match status |
| bank statement line | notes | Notes |
| bank statement line | reference | Reference |
| bank statement line | statement_id | Bank statement |
| bank statement | bank_account_code | Account |
| bank statement | closing_balance | Closing balance |
| bank statement | code | Bank statement number |
| bank statement | currency | Currency |
| bank statement | deleted_at | Deleted on |
| bank statement | file_name | Source file |
| bank statement | notes | Notes |
| bank statement | opening_balance | Opening balance |
| bank statement | period_end | Period end |
| bank statement | period_start | Period start |
| bank statement | reconciled_at | Reconciled on |
| bank statement | reconciled_by | Reconciled by |
| bank statement | status | Status |
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
| contract | code | Contract number |
| contract | currency | Currency |
| contract | customer_id | Customer |
| contract | deleted_at | Deleted on |
| contract | document_ref | Document reference |
| contract | effective_from | In force from |
| contract | effective_to | In force until |
| contract | incoterm | Incoterm |
| contract | kind | Kind |
| contract | notes | Notes |
| contract | payment_terms_days | Payment terms (days) |
| contract | side | Side |
| contract | signed_on | Signed on |
| contract | status | Status |
| contract | supplier_id | Supplier |
| contract | title | Title |
| depreciation charge | amount_base | Amount (base currency) |
| depreciation charge | asset_id | Asset |
| depreciation charge | journal_entry_id | Journal |
| depreciation charge | period_end | Period end |
| depreciation re-basing | asset_id | Asset |
| depreciation re-basing | effective_from | Effective from |
| depreciation re-basing | expense_id | From expense |
| depreciation re-basing | maintenance_id | Service or repair |
| depreciation re-basing | pre_anchor_target_base | Depreciable amount before re-basing (base currency) |
| depreciation re-basing | reason | Reason |
| depreciation re-basing | remaining_months | Remaining months |
| downtime | duration | Duration |
| downtime | ended_at | Came back up |
| downtime | equipment_id | Equipment |
| downtime | notes | Notes |
| downtime | reason | Reason |
| downtime | started_at | Went down |
| exchange rate change | action | Action |
| exchange rate change | currency | Currency |
| exchange rate change | notes | Notes |
| exchange rate change | prev_rate | Previous rate |
| exchange rate change | rate_date | Rate date |
| exchange rate change | rate_sgd_per_unit | Rate (base currency per unit) |
| exchange rate change | rate_type | Side |
| exchange rate change | reason | Reason |
| exchange rate change | source | Source |
| exchange rate | currency | Currency |
| exchange rate | deleted_at | Withdrawn on |
| exchange rate | notes | Notes |
| exchange rate | rate_date | Rate date |
| exchange rate | rate_sgd_per_unit | Rate (base currency per unit) |
| exchange rate | rate_type | Side |
| exchange rate | source | Source |
| explained difference | amount | Amount |
| explained difference | item_kind | Type |
| explained difference | item_no | Item |
| explained difference | note | What it is |
| explained difference | reconciliation_id | Reconciliation |
| fixed asset | acceptance_date | Acceptance date |
| fixed asset | acquisition_date | Acquisition date |
| fixed asset | category | Category |
| fixed asset | code | Asset number |
| fixed asset | cost_base | Cost (base currency) |
| fixed asset | cost_ccy | Cost (transaction currency) |
| fixed asset | currency | Currency |
| fixed asset | depreciation_account_code | Depreciation account |
| fixed asset | description | Description |
| fixed asset | disposal_date | Disposal date |
| fixed asset | disposal_journal_id | Disposal journal entry |
| fixed asset | disposal_proceeds_base | Disposal proceeds (base currency) |
| fixed asset | expense_id | Originating expense |
| fixed asset | fx_rate | FX rate at acquisition |
| fixed asset | in_service_date | In service from |
| fixed asset | notes | Notes |
| fixed asset | planned_in_service_date | Planned in service from |
| fixed asset | residual_base | Residual value (base currency) |
| fixed asset | status | Status |
| fixed asset | useful_life_months | Useful life (months) |
| freight allocation | amount_base | Amount |
| freight allocation | basis_qty | Allocation basis (quantity) |
| freight allocation | freight_document_id | Freight document |
| freight allocation | in_stock_ratio | Share still in stock |
| freight allocation | inbound_batch_id | Inbound batch |
| freight document | allocation_basis | Apportionment |
| freight document | amount_base | Amount (base currency) |
| freight document | amount_ccy | Amount |
| freight document | bank_account_code | Bank account |
| freight document | code | Freight document number |
| freight document | container_id | Container |
| freight document | currency | Currency |
| freight document | deleted_at | Deleted on |
| freight document | direction | Direction |
| freight document | doc_date | Date |
| freight document | fx_rate | FX rate |
| freight document | journal_entry_id | Journal entry |
| freight document | notes | Notes |
| freight document | payment_status | Payment |
| freight document | reversal_entry_id | Reversal entry |
| freight document | reversal_reason | Reason for reversal |
| freight document | reversed_at | Reversed on |
| freight document | reversed_by | Reversed by |
| freight document | status | Status |
| freight document | supplier_id | Forwarder |
| grade specification | contract_id | Contract |
| grade specification | material_id | Material |
| grade specification | max_pct | Maximum % |
| grade specification | metal | Element |
| grade specification | min_pct | Minimum % |
| grade specification | notes | Notes |
| handover downtime note | downtime_id | Downtime |
| handover downtime note | handover_id | Handover |
| index pricing term | base_event | Base month from |
| index pricing term | contract_id | Contract |
| index pricing term | index_code | Index |
| index pricing term | metal | Metal |
| index pricing term | notes | Notes |
| index pricing term | payable_pct | Payable % |
| index pricing term | qp_months | Quotational period (M+n) |
| insurance obligation | contract_id | Contract |
| insurance obligation | cover_type | Cover |
| insurance obligation | currency | Currency |
| insurance obligation | insured_by | Insured by |
| insurance obligation | min_amount | Minimum amount |
| insurance obligation | notes | Notes |
| management pack | base_currency | Base currency |
| management pack | code | Pack |
| management pack | locked_before_at_production | Locked before (at production) |
| management pack | notes | Notes |
| management pack | payload | Pack contents |
| management pack | period_end | Period end |
| management pack | period_month | Month |
| management pack | period_start | Period start |
| management pack | produced_at | Produced on |
| management pack | produced_by | Produced by |
| management pack | superseded_at | Replaced on |
| management pack | superseded_by | Replaced by |
| management pack | superseded_reason | Why it was replaced |
| penalty element | contract_id | Contract |
| penalty element | notes | Notes |
| penalty element | substance | Substance |
| penalty element | threshold_pct | Threshold % |
| penalty element | usd_per_tonne_per_pct_over | USD per tonne per % over |
| refining charge | contract_id | Contract |
| refining charge | metal | Metal |
| refining charge | notes | Notes |
| refining charge | usd_per_tonne_of_metal | USD per tonne of metal |
| sale attribution | amount_base | Amount (base currency) |
| sale attribution | attributed_at | Attributed on |
| sale attribution | attributed_by | Attributed by |
| sale attribution | customer_id | Customer |
| sale attribution | exposure_after | Customer exposure after |
| sale attribution | note | Note |
| sale attribution | sales_record_id | Sale |
| sale stock movement | movement_id | Stock movement |
| sale stock movement | sales_record_id | Sale |
| sale | amount_base | Amount (base currency) |
| sale | cogs_entry_id | Cost-of-sales journal |
| sale | currency | Currency |
| sale | customer_id | Customer |
| sale | fx_rate | FX rate |
| sale | notes | Memo |
| sale | output_batch_id | Output batch |
| sale | price_provenance | How the price was set |
| sale | price_source | Price source |
| sale | quantity | Quantity |
| sale | sale_date | Sale date |
| sale | sales_order_line_id | Sales order line |
| sale | unit_price | Unit price |
| service interval | disposition | When it falls due |
| service interval | equipment_id | Equipment |
| service interval | interval_days | Every N days |
| service interval | interval_kg | Every N kilograms processed |
| service interval | kind | Kind of work |
| service interval | lead_days | Warn this many days before |
| service interval | lead_kg | Warn this many kilograms before |
| service interval | notes | Notes |
| service or repair | capitalisation_reason | Capitalisation reason |
| service or repair | capitalised | Capitalised |
| service or repair | capitalised_expense_id | Capitalised through expense |
| service or repair | description | What was done |
| service or repair | downtime_id | Downtime |
| service or repair | equipment_id | Equipment |
| service or repair | expense_id | Expense |
| service or repair | kind | Kind of work |
| service or repair | notes | Notes |
| service or repair | performed_by_employee_id | Done by (employee) |
| service or repair | performed_by_name | Done by (name) |
| service or repair | performed_by_supplier_id | Done by (supplier) |
| service or repair | performed_on | Done on |
| settlement basis | contract_id | Contract |
| settlement basis | notes | Notes |
| settlement basis | penalty_basis | Penalties |
| settlement basis | refining_charge_basis | Refining charge |
| settlement basis | sale_weight_basis | Settles on |
| settlement basis | sample_retention_days | Retention days |
| settlement basis | sample_retention_required | Sample retention required |
| settlement basis | settling_party | Assay that counts |
| settlement basis | splitting_limit_pct | Splitting limit (percentage points) |
| statement line match | journal_line_id | Matched to |
| statement line match | matched_amount | Matched amount |
| statement line match | statement_line_id | Statement line |
| terms request | contract_id | Contract |
| terms request | decided_at | Decided on |
| terms request | decided_by | Decided by |
| terms request | decision_notes | Decision notes |
| terms request | executed_at | Applied on |
| terms request | formula_id | Formula |
| terms request | kind | Request type |
| terms request | label | Request |
| terms request | proposed | Proposed terms |
| terms request | reason | Reason |
| terms request | snapshot | Terms before |
| terms request | status | Status |
| terms request | withdraw_reason | Withdrawal reason |
| terms request | withdrawn_at | Withdrawn on |
| terms request | withdrawn_by | Withdrawn by |
| volume commitment | committed_by_party | Committed by |
| volume commitment | contract_id | Contract |
| volume commitment | direction | At least / at most |
| volume commitment | material_id | Material |
| volume commitment | notes | Notes |
| volume commitment | period | Per |
| volume commitment | quantity | Quantity |
| volume commitment | unit | Unit |

### §9.3 · English for enumerated values (Q28)

| field | values |
|---|---|
| asset_disposal_requests · bank_account | 1000 → Cash at Bank – SGD; 1010 → Cash at Bank – USD |
| asset_disposal_requests · status | submitted → Waiting for approval; approved → Approved; rejected → Rejected; withdrawn → Withdrawn |
| bank_reconciliation_variance_items · item_kind | unpresented_cheque → Cheque not yet presented; deposit_in_transit → Deposit in transit; bank_charge → Bank charge not yet booked; bank_interest → Bank interest not yet booked; timing → Other timing difference; error_to_correct → Error — correction still to post |
| bank_statement_lines · match_status | unmatched → Unmatched; matched → Matched; ignored → Ignored |
| bank_statements · bank_account_code | 1000 → Cash at Bank – SGD; 1010 → Cash at Bank – USD |
| bank_statements · status | open → Open; reconciled → Reconciled |
| contract_insurance_obligations · insured_by | us → Us; counterparty → The counterparty |
| contract_pricing_terms · base_event | shipment → Shipment; arrival → Arrival; assay_complete → Assay complete |
| contract_settlement_terms · penalty_basis | none_agreed → None agreed; per_element → Per element |
| contract_settlement_terms · refining_charge_basis | none_agreed → None agreed; per_metal → Per metal |
| contract_settlement_terms · sale_weight_basis | as_received → Wet weight (as received); dry → Dry weight |
| contract_settlement_terms · settling_party | ours → Ours; counterparty → The buyer |
| contract_volume_commitments · committed_by_party | us → Us; counterparty → The counterparty |
| contract_volume_commitments · direction | min → At least; max → At most |
| contract_volume_commitments · period | month → Month; quarter → Quarter; year → Year; total → Whole contract |
| contracts · kind | supply → Supply; offtake → Offtake; framework → Framework; service → Service; other → Other |
| contracts · side | buy → Buy; sell → Sell |
| contracts · status | draft → Draft; active → Active; suspended → Suspended; expired → Expired; terminated → Terminated |
| equipment_maintenance · kind | service → Routine service; repair → Repair |
| equipment_service_intervals · disposition | warn → Warn; ignore → Ignore |
| equipment_service_intervals · kind | service → Service; repair → Repair |
| fixed_asset_history · new_category | equipment → Equipment; vehicle → Vehicle; office → Office; other → Other |
| fixed_asset_history · new_status | active → Active; disposed → Disposed |
| fixed_asset_history · old_category | equipment → Equipment; vehicle → Vehicle; office → Office; other → Other |
| fixed_asset_history · old_status | active → Active; disposed → Disposed |
| fixed_assets · category | equipment → Equipment; vehicle → Vehicle; office → Office; other → Other |
| fixed_assets · status | active → Active; disposed → Disposed |
| freight_documents · allocation_basis | weight → By weight; value → By value; stated → Stated per batch |
| freight_documents · bank_account_code | 1000 → Cash at Bank – SGD; 1010 → Cash at Bank – USD |
| freight_documents · direction | inbound → Inbound — freight on material we bought; outbound → Outbound — freight on goods we shipped |
| freight_documents · payment_status | paid → Paid; unpaid → Unpaid (payable) |
| freight_documents · status | posted → Posted; reversed → Reversed |
| fx_rate_history · action | created → Recorded; corrected → Corrected; withdrawn → Withdrawn |
| fx_rate_history · rate_type | tt_buy → TT buy (bank buys the foreign currency); tt_sell → TT sell (bank sells the foreign currency); mid → Mid |
| fx_rates · rate_type | tt_buy → TT buy (bank buys the foreign currency); tt_sell → TT sell (bank sells the foreign currency); mid → Mid |
| gst_filing_requests · status | submitted → Waiting for approval; approved → Approved; rejected → Rejected; withdrawn → Withdrawn |
| gst_periods · status | open → Open; approved → Approved — ready to file; filed → Filed |
| gst_return_boxes · box | box1 → Box 1; box2 → Box 2; box3 → Box 3; box4 → Box 4; box5 → Box 5; box6 → Box 6; box7 → Box 7; box8 → Box 8; box9 → Box 9; box10 → Box 10; box11 → Box 11; box12 → Box 12; box13 → Box 13; box14 → Box 14; box15 → Box 15 |
| sales_records · price_source | computed → Calculated; manual → Entered by hand |
| terms_requests · kind | formula_create → New pricing formula; formula_change → Change to a pricing formula; formula_reactivate → Pricing formula back in use; contract_activate → Contract activation |
| terms_requests · status | submitted → Waiting for the CFO; approved → Approved; rejected → Rejected; withdrawn → Withdrawn |

## §10 · Decisions taken without asking

1. **Q14 without `document_types`.**
   - `search_documents_sql` builds `SELECT code` for every registered table, and `sales_records` has no `code` column.
   - Registering it would break global search.
   - The sale's name and link come from `trail_ref_label` / `trail_row_record` instead, in the same shape a document gets.
2. **Home changes:**
   - The output batch's `sales_records` membership is no longer home, so a sale row's Record is the sale (Q14).
   - Freight allocations are home on `freight`.
   - On `fixed_asset`, the equipment tables are members but not home: their home stays `equipment`.
   - On `contract`, terms-request approvals and contract–document links are not home.
3. **The contract subject is gated by `module.suppliers.view`**, the page's own module, not finance.
4. **Withdrawn FX rates have no entry point.**
   - `/finance/fx` lists live rates only (`page.tsx:139`, `fxQuery.ts:47`).
   - The page opens a withdrawn rate when given its URL; a list entry for it would change a 1c-3 page.
   - Queued to 1c-3 (`docs/forward-queue.md`).
5. **Message keys:**
   - The freight page's four reversal-banner keys are deleted, since the shared banner says it.
   - `deleted.kind.bank_statement` is added for `/settings/deleted`.
6. **The asset card's labels adopt the old panel's wording** (§9.2), so what the page used to say carries over.
7. **Kind overrides.** Codes, money and rates get their real kinds, for example `bank_account` as an enum mapped to "Cash at Bank – …".
   An FX rate's name reads "USD · TT selling rate · DD/MM/YYYY".
8. **A follow-up migration (fu1), not a rebuilt main file.**
   - The main file had already committed when the gate showed that the `journal_lines` branch was missing from it.
   - fu1 replaces `trail_ref_label` in place, with its own dry run.
   - `build_at1c2_migration.py` now says "do not re-run".
9. **Fixture 242 compares with `IS DISTINCT FROM`.**
   - A `<>` against NULL never fires, which the Q14 injection exposed.
   - Two other injections were redesigned until they bit:
     - **freight home:** the injection also promoted the batch membership;
     - **Q21:** the injection now bypasses `trail_row_visible`.
10. **Migration date 2026-10-04,** from `date` at build time (the session began on 2026-10-03).
11. **`gm` is the refused reader in the probe.** It holds every module but not `data.view_deleted`.
12. **The step 1 count was corrected**: seven later matching runs, not five (§1).
13. **GST `label_en` is shown and `label_zh` hidden.** Hiding `label_en` made the machine-token sweep flag uuids.
14. **Trail text keys use new prefixes** (§9.1), to stay clear of existing message namespaces.
15. **A deleted statement's controls:**
    - The workspace link is not drawn.
    - The reconcile URL redirects to the statement.
    - The delete button sits inside `EndedFieldset`.
16. **The round-trip fix lives in the shared `mergeUpdates`**, so it applies to every subject since AT-1a. Same release (v1.4.33).
17. **Proof B records the sale as admin@.**
    - On live, `action.direct_sale` belongs only to the admin and cco roles (`role_permissions`, read as postgres), and chooer@ was refused.
    - admin@ is tim@'s second account. A sale needs no approval, so no approval separation is lost.
18. **Pack and contract pages were neither surveyed nor probed**: there are 0 live rows. They are proved in fixture 242 (K, C) and in proof B.
19. **The first backup failure was retried once, immediately**, per AGENTS.md. No delay was chosen.

## §11 · Known issues and queue

- **`docs/known-issues.md`** gains:
  - `AT1C1-TRAIL-ZH-EN-ONE-UNEXPLAINED-MISMATCH` (step 1);
  - `AT1C2-INBOUND-STATUS-HAS-NO-VALUE-MAP` (step 1 h).
- **`docs/forward-queue.md`:**
  - item 27 records the 1c-1 window;
  - AT-1c-2 is marked ✅;
  - the 1c-3 note about withdrawn FX rates is added.
- **Unchanged and still open:** AT-1c-3, AT-1d (with Q2's panel), DATE-PICK-1, UNBLOCK-1 (Q11 first).
