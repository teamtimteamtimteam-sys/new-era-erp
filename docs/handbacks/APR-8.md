# APR-8 — contract terms and pricing formulas take effect only when the CFO approves them (2026-09-26)

The approvals effects are `docs/approvals.md` §3u; the matrix lines are `docs/role-matrix.md` (contract terms · pricing formulas).
**No version number is assigned** — the standing ruling is one number for the whole approval chain, announced at its end.

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `0091c72768d6170fd5881df50540ea27f05085b7` (APR-7).
**Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with its identity (`postgres`,
`rolbypassrls = t`, base tables unless a view is named; views read as tim@ under `authenticated`).

## §W · APR-7's broken window — closed with bounds, labelled by kind

Tim confirmed APR-7 deployed (2026-09-26) and has no Vercel "Ready" time to add.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-26 00:54:32 | **measured**: `db/migration-windows.tsv` |
| end, lower bound | 01:44:23 | **measured**: the push moved `origin/main` → `0091c727` (`git reflog show --date=iso refs/remotes/origin/main`) |
| end, upper bound | 21:47:24 | **derived**: this session's first read of `now()` as `postgres` (`rolbypassrls = t`), taken after Tim's "deployed" confirmation had arrived — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 49 min 51 s, at most 20 h 52 min 52 s.** Also written into `docs/handbacks/APR-7.md` §6.
**APR7-LEGACY-RUNS-CANNOT-ROLL-BACK:** Tim accepts the 10 legacy runs as test data — moved from `docs/known-issues.md` to
`docs/known-wrong-until-cutover.md`.

## §0 · Step 0 (grilling) and Tim's answers

**What grilling found** (code from the mirrors; live read as `postgres`, base tables, 2026-09-26 21:47):
1. **Nothing is versioned — documents copy at commit.** A PO line / receipt gets an immutable `pricing_term_commitments` row, a linked
   PO / SO a `contract_document_terms` snapshot, a sale its `price_provenance`. So "takes effect" = what the next read of the live row
   returns; nothing already priced can change.
2. **Contracts already had a status and only `active` had effect** (`link_document_to_contract` → `CONTRACT_NOT_ACTIVE`). Live: 0 contracts,
   0 term rows, 0 links.
3. **Formulas had no status, only `is_active`**, and were written by direct INSERT / UPDATE / DELETE from the formula page. Live readers:
   `calculate_metal_price` (calculator, new-PO estimate) · `price_output_sale` · `commit_pricing_terms` (PO creation, assay application),
   all through `pricing_terms_of_formula`. Live: 1 formula (PF-2026-0001, active, admin@ 2026-07-30), 3 metals, 1 commitment.
4. **The pricing-terms commitment did not need to come in:** once the live formula changes only through approval, every commitment made
   afterwards copies approved terms.
5. **"No other decider" bites Tim as admin@** — admin@ holds both raiser codes; level 2's only real holder is tim@, the same person.
6. **No term-editing screen and no contract detail page exist.**

**Tim accepted all eleven recommendations (Q1–Q11)**; the stopping line (formulas as APR-8a, contracts as APR-8b) was **not needed** —
the whole cut shipped.

| Q | built |
|---|---|
| Q1 | new formula born inactive + `formula_create`; change to an active one = `formula_change` with the full proposed terms, replaced in place on approval (`pricing_formula_history` logs it); old terms stay in effect while it waits; `formula_reactivate`; stop / delete stay one step (`deactivate_pricing_formula` · `delete_pricing_formula`). No status column |
| Q2 | every route into `active` needs the CFO (`contract_activate`); active header `CONTRACT_ACTIVE_IS_FROZEN`, active terms `CONTRACT_TERMS_FROZEN`; suspend / expire / terminate one step; the CFO sees now vs. last approved |
| Q3 | no term editor; registered `APR8-NO-TERM-EDITOR`; the editor cut queued after APR-10, before the colleagues' test |
| Q4 | one table `terms_requests`, four kinds, one chain `decide_terms_request`, gate = the five measured codes |
| Q5 | one waiting request per subject (`TERMS_REQUEST_OPEN`); contract header / terms frozen while waiting; fingerprint re-checked at approval (`TERMS_CHANGED_SINCE_REQUEST`) |
| Q6 | formula write policies dropped + statement guard `PRICING_FORMULA_THROUGH_REQUEST_ONLY`; contract direct insert only as draft (`CONTRACT_ACTIVATES_THROUGH_REQUEST`); no new code |
| Q7 | PF-2026-0001 left in use; `docs/known-wrong-until-cutover.md` |
| Q8 | CFO panel with a side-by-side terms table (changed rows marked) and who uses it; cco sees status, notes, Withdraw; en + zh |
| Q9 | chain row · pending arm (`blocks_disable`, level 2, amount NULL) · `approval_log` type + read branch · `record_approval_decision` branch · `operations_now` arm |
| Q10 | live proof below |
| Q11 | one session; not split |

## §1 · What shipped

Migration `db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql` (2,434 lines, built by
`db/scripts/build_apr8_migration.py` from the mirrors; preflight: 25 `CREATE FUNCTION`, 3 replaced · 22 new). It proves itself before
COMMIT: approvals on; grants unchanged; the pending set unchanged; `approval_log`, journal entries / lines / Σ debits, formulas, live
formulas, metals, history, commitments, contracts, term rows and links unchanged; `terms_requests` empty; no write policy on the two
formula tables or on `terms_requests`; all 10 guards present; every internal not executable by `authenticated`; the chain row is level 2
only; the new chain has a decider; every pending document has a decider who is not its own party.

**Functions (22 new):** `submit_formula_create_request` · `submit_formula_change_request` · `submit_formula_reactivate_request` ·
`submit_contract_activation_request` → `terms_request_submit_internal` (dry run `terms_request_dry_run`, PQ006) · `decide_terms_request` →
`terms_request_execute_internal` · `withdraw_terms_request` · `terms_requests_visible` · `deactivate_pricing_formula` ·
`delete_pricing_formula` · helpers `formula_terms_state` · `contract_terms_state` · `formula_terms_normalize` · `terms_request_snapshot` ·
`terms_request_fingerprint` · `contract_terms_lock_reason` · guards `guard_pricing_formula_direct_write` · `guard_contract_write` ·
`guard_contract_terms_frozen`. **Replaced (3):** `approval_chain_gates` · `approval_pending_documents` · `record_approval_decision`.

**Screens (en / zh):**
- `/tools/pricing/formulas` — a requests panel at the top (anchor `#tr-<id>`): each waiting request with a terms table (in use → proposed;
  changed rows marked), who uses the formula (committed and unaffected / uncommitted receipts that would copy the approved terms / the
  calculator, new POs and sales from approval on), Approve / Reject (visible, disabled with the missing code) and Withdraw.
- `/tools/pricing/formulas/new` and `/[id]/edit` — the form now **sends the terms to the CFO** (reason required); the Active tick box is
  gone (status is stated instead); the edit page gains **Stop using** and the formula's own request panel, and the form is disabled
  while a request waits, naming it. Delete goes through `delete_pricing_formula`.
- `/contracts` — the contract requests panel (last approved → now) and a "putting contracts in effect" list: **Request activation**
  (draft / suspended, with a reason) and **Suspend** (active); both disabled while a request waits.
- `/contracts/new` — draft only; the sentence "this cannot be changed afterwards" is gone because it is no longer true.
- Dashboard reminder `terms_request_pending`; `/settings/approvals` chain label.

**Fixtures:** 227 (new, A–K incl. fault injection — dropping the formula guard turns the direct UPDATE back into a silent zero-row no-op)
· 217 (formula through the new door; its existing contract a draft) · 205 (own-document gaps 10 → 11) · 111 (44 arms) · 16 fixtures grant
their level-2 role the new gate codes (in 127 · 151 · 35 · 203 the existing array was extended — a separate statement would have landed
inside a savepoint the fixture expects to fail, and in 218 an alias `r` collided with a record variable). `db/check_mirrors.py` and
`db/verify_rebuild.py` allowlist `contract_terms_lock_reason` and the revoked internals; `scripts/check-document-registry.mjs` 235 → 236;
`scripts/check-i18n.mjs` reads the new prefixes from the table, the error-code set and the two `as const` lists.
`scripts/currency-messages-baseline.json`: `termsRequest.field.treatment_charge_usd_per_tonne` = "Treatment charge (USD/t)" is a unit fixed
by the column name, like the existing `pricing.form.treatment` — reviewed and baselined, not refreshed to make the build pass.

## §2 · Verify — every figure is the script's own line

| step | result |
|---|---|
| `db/gate.py --offline` | `OWN_EXIT=0` (53 s) |
| dry run of the migration file on live (`COMMIT` → grants + probe + `ROLLBACK`) | `DRY_OWN_EXIT=0`; probe: chain rows 1, `authenticated` → `terms_request_execute_internal` f, → `submit_formula_create_request` t, `anon` → it f |
| backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-09-26-2259.dump`, TOC 6,433 (previous 6,369, floor 5,732), 23:25 |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`; proof NOTICEs: 1 decider for `terms_request` (tim@); 9 pending documents, each with a decider |
| `npm run types:gen` | `TYPES_OWN_EXIT=0` (+173 lines) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_OWN_EXIT=0` (after replacing a hand-written `<table>` in the panel with `DataTable`, and the baseline line above) |
| `db/gate.py` (full) | `GATE_EXIT=0` (378 s) — rebuild ✓ · mirrors vs live ✓ · fixtures ✓ · anon surface ✓ (baseline 327) |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_OWN_EXIT=0` |
| smoke (`node scripts/smoke-routes.mjs`, detached) | `SMOKE_EXIT=0` — 236 routes + probes; 229 timed, median 6,561 ms. Clean-up read back as `postgres` (base tables, 2026-09-27 00:26): `.ephemeral/` 0 plans; `auth.users` 7, `roles` 13, unrevoked `user_roles` 7 — the real accounts only, no smoke account or role left |

## §3 · Live proof and the before / after readings

Script `db/scripts/2026-09-26-apr8-live-proof.sql`, one transaction, `ROLLBACK` at the end — **nothing was left on live**
(`PROOF_OWN_EXIT=0`, 2026-09-27 00:27 CST, as `postgres` switching to each real account under `authenticated`; the two owner-path steps
say so). The first run stopped at its own set-up check (`PROOF_SETUP|…`, no supplier is `active` — live suppliers are `draft` / `approved`)
before touching anything; the pick was corrected to "an approved supplier first" and the whole script re-run.

| cell | who | what | result |
|---|---|---|---|
| R1–R5 | sandra@ · chooer@ · admin@ | direct formula UPDATE (cco) · the same (finance) · finance submits · Tim-as-admin@ submits · cco inserts an **active** contract | `PRICING_FORMULA_THROUGH_REQUEST_ONLY` · `PERMISSION_DENIED\|module.pricing.edit` ×2 · `TERMS_REQUEST_NO_OTHER_DECIDER\|…` · `CONTRACT_ACTIVATES_THROUGH_REQUEST\|…` |
| F1 | sandra@ → tim@ | **formula_create** | submitted, formula inactive; `pricing_terms_of_formula` (postgres) → `FORMULA_INACTIVE`; sandra@ approving → `SELF_APPROVAL_FORBIDDEN\|raiser`; switching approvals off → `APPROVALS_CANNOT_DISABLE_WITH_PENDING`; tim@ approves → active, ni 70, log `approved` |
| F2 | sandra@ → tim@ | **formula_change** on PF-2026-0001 (flat discount → 2.5) | while waiting the reader still returns the old terms; snapshot `proposed` 2.5, `usage.po_lines_committed` 1; stop → `TERMS_REQUEST_OPEN`; a second request → `TERMS_REQUEST_OPEN`; approved → 2.5 in effect; the existing commitment keeps its own copy |
| F3 | sandra@ · postgres · tim@ | fingerprint | owner-path edit while waiting → approval `TERMS_CHANGED_SINCE_REQUEST`; sandra@ withdraws → `withdrawn` |
| F4 | sandra@ → tim@ | **formula_reactivate** | stop (one step) → request → reject with a blank reason `TERMS_REQUEST_REJECT_REASON_REQUIRED` → reject with a reason (stays inactive) → request again → approved, active |
| C | sandra@ → tim@ | **contract_activate** | draft + a pricing term inserted by cco → request → terms `CONTRACT_TERMS_FROZEN`, header `TERMS_REQUEST_FREEZES_CONTRACT` → approved, active → header `CONTRACT_ACTIVE_IS_FROZEN` → suspend (one step) → edit 90 → 92 → request again: snapshot `last_approved` 90 vs `current` 92 → approved, active |
| K | postgres | end | journal entries unchanged; nothing left waiting; `approval_log` +13 rows inside the transaction (rolled back) |

**Before and after readings** — `db/scripts/2026-09-26-apr8-readings.sql` (part 1 as `postgres`, base tables; part 2 as tim@ on views;
part 3 each account as itself), before at 2026-09-26 22:56:30, after at 2026-09-27 00:28:45 (after the proof and the smoke). Diffed:
- **identical:** approvals on (L1 finance, L2 cfo, threshold 1000, locked before 2026-08-01); pending — 1 expense claim (1,000.00),
  2 leave, 1 medical approved-unpaid, 5 open stocktakes, 0 PO / payment / payroll / receipt-price / invoice / journal / warehouse requests,
  0 shipping releases; `approval_pending_documents()` = 1 expense claim (`blocks_disable` 0); journal entries 82 (by source type
  unchanged), journal lines 184, Σ debits 1,636,102.89; approval_log 14; formulas 1 (PF-2026-0001 active), metals 3, history 0,
  commitments 1; contracts 0, term rows 0, links 0; balances 1000 −127,593.48 · 1100 43,002.12 · 1200 61,387.92 · 2000 −376,404.42;
  AP list 416,988.32 / ledger 376,404.42, AR list 57,545.87 / ledger 43,002.12, **unexplained 0.00 on both sides**; catalogue 66; holders
  of the seven relevant codes; every role's code count and md5 (admin 65 `485022c5…` · cco 38 `59932566…` · cfo 30 `730763e8…` · finance
  38 `49745fb9…` · the rest unchanged) and every account's `current_user_permissions()`; 7 unrevoked grants.
- **changed, as intended:** `terms_requests` exists (0 rows, 0 waiting; before: absent); formula write policies 6 → **0**; APR-8 guards
  0 → **10**; `authenticated` can execute the eight doors (**t**) and not `terms_request_execute_internal` / `terms_request_submit_internal`
  (**f**; before: absent).
- **Nothing left pending by this cut; every pending document still has a decider who is not its own party** (the migration printed each:
  CLM-2026-0004 → tim@; LV-2026-0001 / 0003 → admin@, tim@; MC-2026-0001 → admin@, chooer@; ST-2026-0082…0086 → chooer@; terms_request
  deciders: 1).

## §4 · Doors closed, and who can no longer / can newly do what (approvals on)

**Closed:** creating, changing, re-activating a pricing formula in one step (direct INSERT / UPDATE / DELETE on both formula tables);
making a contract active directly (insert or update); editing an active contract's header or any of its seven term tables; editing a
contract or formula while a request waits. **Unchanged:** `link_document_to_contract` (Batch 2b Q1).

- **Sandra (cco):** can no longer put a formula in use, change one in use, re-activate one, create an active contract, activate a contract
  or edit an active one — each is a request the CFO approves. **Newly:** sends terms to the CFO, sees the request and its outcome,
  withdraws it, suspends an active contract, stops using a formula.
- **Tim as tim@ (cfo):** **newly** approves or rejects every formula and contract request, on `/tools/pricing/formulas` and `/contracts`.
  Raises nothing (holds neither raiser code).
- **Tim as admin@:** holds both raiser codes, but a request raised as admin@ is refused at submit (`TERMS_REQUEST_NO_OTHER_DECIDER` — the
  same person as tim@, level 2's only real holder); cannot decide (no `cfo`). Stop / delete / suspend stay one step.
- **Choo Er · Phua · Fu Sheng · Vince:** no change (they never held either raiser code; reading formulas is unchanged).
- **No document is left with only its raiser eligible:** terms requests → tim@ (proof NOTICE: 1 decider).

## §5 · Findings registered on the way

- **APR8-NO-TERM-EDITOR** (`docs/known-issues.md`) — the seven term tables have no editing screen; the editor cut is queued after APR-10.
- **PF-2026-0001** in use without ever having been approved — `docs/known-wrong-until-cutover.md` (Q7).
- `link_document_to_contract`'s HINT and `contracts.errors.CONTRACT_NOT_ACTIVE` used to tell the user to "set the contract to active",
  which no screen allowed; the copy now points at the activation request (the function's HINT text itself is unchanged).

## §6 · The broken window — started, end PENDING

**Start: 2026-09-26 23:31:04 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at" line reads
23:27:14). **End: PENDING — Tim reads it from Vercel.**

What the old app does against the new database (approvals ON):
- **Saving a pricing formula is refused for everyone** — the old new / edit pages write the tables directly: cco and admin@ get
  `PRICING_FORMULA_THROUGH_REQUEST_ONLY`, others `PERMISSION_DENIED|module.pricing.edit`; the old copy has no sentence for the first, so
  it shows the raw / generic text. Deleting a formula is refused the same way. There is no screen to send terms to the CFO until the deploy.
- **Creating a contract with status "Active"** (the old form's default) is refused `CONTRACT_ACTIVATES_THROUGH_REQUEST`; "Draft" still
  saves. No screen to request activation until the deploy.
- **Unaffected:** the calculator, new purchase orders with a formula line, receipt pricing and repricing, assay application, sales
  pricing (PF-2026-0001 stays active), every other approval chain, the switch, everything pending. **Live impact:** nothing was waiting;
  0 contracts exist.

## §7 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs (a commit cannot
carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
**Next cut:** APR-9 — salary-change request and asset disposal (`docs/forward-queue.md` item 14).
