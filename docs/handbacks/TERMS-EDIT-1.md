# TERMS-EDIT-1 — a contract detail page where cco enters and edits all seven kinds of contract terms (2026-09-27)

The matrix line is `docs/role-matrix.md` (contract terms). APR-8 (`docs/handbacks/APR-8.md`) built the lifecycle; this cut adds the
editor and changes no APR-8 rule. **No version number is assigned** — one number for the whole approval chain, announced at its end.

**Opening gate:** tree clean; `HEAD` = `origin/main` = `ls-remote` = `a5df6ea74588117d90f98ec509dac5b06550f3a8` (APR-10).
**Approvals were ON and stayed ON.** Every figure below is a script's own exit line or a query named with its identity (`postgres`,
`rolbypassrls = t`, base tables unless a view is named; views read as tim@ under `authenticated`).

## §W · APR-10's broken window — closed with bounds, labelled by kind

Tim confirmed APR-10 deployed (2026-09-27) and has no Vercel "Ready" time to add.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-27 16:34:41 | **measured**: `db/migration-windows.tsv` |
| end, lower bound | 2026-09-27 17:21:04 | **measured**: the push moved `origin/main` → `a5df6ea7` (`git reflog show --date=iso refs/remotes/origin/main`) |
| end, upper bound | 2026-09-27 17:26:42 | **derived**: this session's first read of `now()` as `postgres` (`rolbypassrls = t`), taken after Tim's "deployed" confirmation had arrived — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 46 min 23 s, at most 52 min 1 s.** Also written into `docs/handbacks/APR-10.md` §7.
**Tim accepted APR-10's four build decisions (2026-09-27):** direct writes to the PO tables closed; applying a payment-term template counts
as amending; the battery-material rule reads the catalogue's kind field (`APR10-BATTERY-RULE-READS-KIND` stays registered — the two live
feedstock materials are test data, and kind is filled when real materials are entered; noted on the entry); reopening a month before a
waiting quarter is refused. Recorded in `APR-10.md` §7.

## §0 · Step 0 (grilling) and Tim's answers

**What grilling found** (mirrors + live read as `postgres`, base tables, 2026-09-27 17:26:42):
1. **The seven term tables** — grade specs (many; one per material + metal), insurance obligations (many), volume commitments (many),
   pricing terms (one per metal), settlement terms (**one per contract**), refining charges (one per metal), penalty elements (one per
   substance). Each has a write policy on `action.contract_terms`, `enforce_write_permission`, and APR-8's `guard_contract_terms_frozen`.
2. **Nothing was required before activation.** `terms_request_submit_internal` checked status, period, reason, an open request and the
   other decider — never the terms. But `sale_settlement_compute` refuses a sale whose contract copy lacks a settlement basis, a payable
   for a paid metal, a refining row when `per_metal`, or a penalty row when `per_element` — i.e. an incomplete sales contract could be
   approved and then fail at settlement, after it is frozen.
3. **Direct writes were already fully guarded** (the freeze trigger runs as the caller) — unlike the PO tables APR-10 closed.
4. **Expired and terminated contracts were not frozen** (`contract_terms_lock_reason` returned only the waiting request or `active`).
5. Live: 0 contracts, 0 term rows, 0 terms requests. `/contracts` already linked each code to `/contracts/<id>`, which did not exist (404).

**Tim accepted all eleven recommendations (Q1–Q11):**

| Q | built |
|---|---|
| Q1 | one page `/contracts/[id]`: header, seven sections, this contract's request panel, Request activation / Suspend; linked from the `/contracts` list and from each contract request in the CFO's panel |
| Q2 | direct writes under RLS from server actions, no new write function; every constraint and unique-index name mapped to en + zh copy |
| Q3 | `CONTRACT_TERMS_INCOMPLETE\|<code>\|<missing>` in `terms_request_submit_internal` for sell contracts; buy side needs nothing; the page shows the same checklist and disables Request activation with the reason |
| Q4 | `contract_terms_lock_reason` also returns `expired` / `terminated` (same migration) |
| Q5 | header editable whenever the terms are; counterparty and side fixed, disabled with "create a new contract" |
| Q6 | pricing, settlement, refining and penalty sections shown on buy-side contracts but disabled, with the reason |
| Q7 | no draft deletion |
| Q8 | the smoke creates its own ZZ-SMOKE draft of each side and removes it through the existing clean-up |
| Q9 | migration accepted; fixtures that build sell contracts get the Q3 rows — **measured: none needed** (below) |
| Q10 | live proof as listed (§3) |
| Q11 | one session |

**Q9, measured:** only fixture 227 requests contract activation, and its contract is buy-side (supplier). Every other fixture that builds a
sell contract (147, 148, 149, 150, 197) inserts it `active` on the owner path (`postgres`, RLS bypassed), which never goes through
`terms_request_submit_internal`. `db/gate.py --offline` confirmed it (below). So no existing fixture needed the rows; fixture 230 carries them.

## §1 · What shipped

**Migration** `db/migrations/2026-09-27-terms-edit1-contract-terms-editor.sql` (514 lines, built by
`db/scripts/build_terms_edit1_migration.py` from the mirrors; preflight: 4 `CREATE FUNCTION` — 2 replaced · 2 new, one of them the
proof's temporary `pg_temp` helper). It proves itself before COMMIT: approvals on; grants unchanged; the pending set unchanged;
`approval_log`, journal entries / lines / Σ debits, contracts, the seven term tables and `terms_requests` unchanged; the checklist is
INVOKER and executable by `authenticated`; the lock stays DEFINER; the submit internal stays unexecutable by `authenticated` and reads the
checklist; the 8 APR-8 contract guards present; the terms chain has a decider; every pending document has a decider who is not its own party.

**Functions:**
- **new** `contract_activation_missing(uuid) → text[]` — SECURITY INVOKER; for a sell contract returns, in order, `settlement_terms`,
  `pricing_terms`, `refining_charge:<metal>` (per priced metal when `per_metal`), `penalty_elements` (when `per_element`); empty for buy.
  The submit reads it as owner; the page reads it as the caller (RLS applies — a reader who cannot see the contract gets an empty list).
- **replaced** `terms_request_submit_internal` — the contract branch refuses `CONTRACT_TERMS_INCOMPLETE|<code>|<items>` after the period check.
- **replaced** `contract_terms_lock_reason` — also returns `expired` / `terminated`, so the seven term tables refuse
  `CONTRACT_TERMS_FROZEN|<code>|expired|terminated`. The header guard reads only `request:` / `active`, so the header rule is unchanged
  (registered, §5).

**No new permission code**, so the standing "every new code also to admin" ruling had nothing to grant.

**Screens (en / zh):** see §6 for the inventory.
- `/contracts/[id]` — `app/contracts/[id]/page.tsx` (server), `TermSection.tsx` (one component for all seven sections, driven by
  `termSpecs.ts`), `HeaderForm.tsx`, `actions.ts` (`saveTermRow` · `deleteTermRow` · `saveContractHeader`). A contract the reader cannot see
  under RLS is a 404 (warehouse reading a sell contract).
- `ContractActivationPanel` — the checklist under Request activation (disabled while anything is missing, each item named).
- `TermsRequestsPanel` — a contract request's code links to `/contracts/<id>`; the detail page shows only that contract's requests.
- `/contracts/new` — saving now lands on the new contract's page; the stale sentence "It CANNOT be edited … no screen yet for linking an
  order" is rewritten (both halves had stopped being true).
- `app/contracts/ContractDateInput.tsx` — one native date control shared by the new-contract form and the header editor (below).

**Fixtures:** 230 (new, A–H incl. fault injection — replacing the checklist with an always-empty one lets an incomplete sell contract be
submitted, so the refusal is load-bearing). No existing fixture changed.

**Tooling:** `check_mirrors.py` + `verify_rebuild.py` — the `contract_terms_lock_reason` allowlist reason now says what it returns (both
kept identical). `check-i18n.mjs` — four new dynamic prefixes read from `termSpecs.ts` and the checklist function body; fault-injected
(three zh keys removed → three named failures, restored → green). `smoke-routes.mjs` — `ID_SOURCES['/contracts']`, the two ZZ-SMOKE drafts
(every kind except pricing on the sell one — §5), content needles for `/contracts/[id]`, and a buy-side render check. `check-scratch-rows.mjs` — knows
`contracts` `ZZ-SMOKE%`. `lib/deepRoutes.generated.ts` regenerated (208 routes).

**Build decisions taken without asking — say if any is wrong:**
1. **The four "USD per tonne" labels were baselined** in `scripts/currency-messages-baseline.json` (`refining_charges` ×2,
   `penalty_elements` ×2 in `messages/en.ts`): the unit is fixed by the column names `usd_per_tonne_of_metal` /
   `usd_per_tonne_per_pct_over`, the same case APR-8 baselined for the treatment charge. Reviewed, not refreshed to make the build pass.
2. **One shared native date control instead of three more.** The date ratchet only allows the count to fall; the header editor needs three
   date fields and the new-contract form already had three. Both now use `ContractDateInput`, so the count fell 138 → 135 and the baseline
   was tightened (its history note kept). DATE-0 will have one place to replace for contracts.
3. **The header of an expired / terminated contract is still writable through the API** (the screen disables it). Q4 ruled the terms lock;
   the header guard is an APR-8 rule this cut may not change. Registered `TERMSEDIT1-ENDED-HEADER-WRITABLE`; fixture 230 F3 pins today's rule.
4. **Buy-side contracts can still hold sell-side rows via the API** (the tables do not restrict side). The page shows such rows but its
   controls on those four sections are disabled with the Q6 reason. Not registered — the tables never restricted side and nothing reads
   them on the buy side.
5. **The smoke's drafts carry explicit codes `ZZ-SMOKE-CON-SELL` / `-BUY`**, so they burn no live contract number and the scratch-row
   report recognises them. (The live proof's rolled-back contracts did advance `contract_code_seq`: it read CON-2026-0078 / 0079 — a
   sequence is not transactional; the same happened in APR-8's proof.)

## §2 · Verify — every figure is the script's own line

| step | result |
|---|---|
| `db/gate.py --offline` | `GATE_EXIT=0` (60 s), 233 fixtures ✓ incl. 230, 227, 217 |
| backup (detached) | `BACKUP_EXIT=0` — `evoltrya-backup-2026-09-27-1740.dump` (5.1 MB, TOC 6,598; previous 6,567, floor 5,910), 17:58 |
| dry run of the migration file on live (`COMMIT` → probe + `ROLLBACK`) | `DRY_OWN_EXIT=0`; probe: `authenticated` → `contract_activation_missing` t, lock of an unknown id NULL, checklist of an unknown id 0 items |
| `db/apply_migration.sh` | `APPLY_OWN_EXIT=0`; preflight 4 CREATE FUNCTION (2 replaced · 2 new); proof NOTICEs: 1 decider for `terms_request` (tim@); 9 pending documents, each with a decider |
| `npm run types:gen` | `TYPES_OWN_EXIT=0` (+4 lines) |
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build` | `BUILD_OWN_EXIT=0` (after the two decisions above and dropping a pinned `text-sm` from the section table's columns) |
| `db/gate.py` (full) | first `GATE_EXIT=1` — the currency check flagged a literal `'USD'` **in this cut's own proof script** (`db/scripts/…-live-proof.sql`); fixed to read `currencies.is_base`; re-run **`GATE_EXIT=0`** (340 s) — rebuild ✓ · mirrors vs live ✓ · fixtures ✓ · anon surface ✓ (baseline 327) |
| after the gate and build | one later edit only: `scripts/smoke-routes.mjs` (the sell draft stops carrying a pricing term) and docs. Re-checked on the committed tree: `CCY_OWN_EXIT=0`, `I18N_OWN_EXIT=0`, `node --check` ok; smoke run 2 executed that exact script. The full gate and `next build` were not re-run for it |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` (227 dynamic prefixes, 0 unclassified, 2,197 enumerated keys) |
| `node scripts/check-error-swallowing.mjs` | `SWALLOW_OWN_EXIT=0` |
| smoke (`node scripts/smoke-routes.mjs`, detached) — run 1 | `SMOKE_EXIT=1` — 255 ok, 7 skipped, **1 failed**: `/finance/price-exposure`'s content needle, caused by the smoke's own sell draft carrying a pricing term (§5, `TERMSEDIT1-EXPOSURE-IGNORES-STATUS`); `/contracts/[id]` and the buy-side check passed. Clean-up read back as `postgres` (base tables, 18:46:46): `.ephemeral/` 0 plans; `auth.users` 7, `roles` 13, unrevoked `user_roles` 7; contracts 0, term rows 0, terms requests 0 |
| smoke — run 2 (the draft no longer carries a pricing term) | **`SMOKE_EXIT=6`** — **256 ok, 7 skipped, 0 failed** (237 routes + probes; 230 timed, total 1,175.4 s, median 4,723 ms; `/contracts/[id]` 8,605 ms); exit 6 = clean-up not confirmed: every step in the plan was confirmed deleted, but the by-name sweep (smoke accounts / ZZ-SMOKE employees / probe roles) timed out (`The operation was aborted due to timeout`; that sweep error is also what set the run's own code to 1 — `scripts/ephemeral.mjs:324` — not a route). Per the exit-6 procedure: `npm run reap:ephemeral` → `REAP_OWN_EXIT=0`, "no stale plans"; read back as `postgres` (base tables, 20:06:24): `auth.users` 7 (0 `smoke-%`), `roles` 13 (0 `probe-%` / `fixture-%`), unrevoked `user_roles` 7, `ZZ-SMOKE-%` employees 0, contracts 0, terms requests 0. **Nothing left.** |

## §3 · Live proof and the before / after readings

Script `db/scripts/2026-09-27-terms-edit1-live-proof.sql`, one transaction, `ROLLBACK` at the end — **nothing was left on live**
(`PROOF_OWN_EXIT=0`, 2026-09-27 18:19:42 CST, as `postgres` switching to each real account under `authenticated`).

| cell | who | what | result |
|---|---|---|---|
| P1 | sandra@ | draft a **sell** contract, edit its header | CON-2026-0078, header `CIF · SGD · 30` |
| P2 | sandra@ | request activation with no terms | `CONTRACT_TERMS_INCOMPLETE\|CON-2026-0078\|settlement_terms,pricing_terms`; no request row |
| P3 | sandra@ | one row of each of the seven kinds (`per_metal` + a Ni refining row, `per_element` + a Cu penalty) | checklist (read as sandra@) empty |
| P4 | chooer@ · tim@ | direct writes to the terms | insert → `new row violates row-level security policy …`; update → `PERMISSION_DENIED\|action.contract_terms` (both); rows unchanged |
| P5 | sandra@ | request activation; edit while waiting | submitted (`CON-2026-0078 · activate #1`); term → `CONTRACT_TERMS_FROZEN\|…\|CON-2026-0078 · activate #1`; header → `TERMS_REQUEST_FREEZES_CONTRACT\|…` |
| P6 | tim@ | read the request, approve | `terms_requests_visible` as tim@ carries all seven sections (1 row each), `last_approved` null; approved → active |
| P7 | sandra@ | edit the active contract | term → `CONTRACT_TERMS_FROZEN\|CON-2026-0078\|active`; header → `CONTRACT_ACTIVE_IS_FROZEN\|CON-2026-0078` |
| P8 | sandra@ → tim@ | suspend, payable 90 → 92, request again | tim@ sees `last_approved` 90 · `current` 92 (`activate #2`); approved → active |
| P9 | sandra@ | terminate, edit a term | `CONTRACT_TERMS_FROZEN\|CON-2026-0078\|terminated` (Q4) |
| P10 | sandra@ | buy-side draft with no terms, request | submitted (`CON-2026-0079 · activate #1`), then withdrawn |
| P11 | admin@ | request activation | `TERMS_REQUEST_NO_OTHER_DECIDER\|CON-2026-0079 · activate #2` (APR-8, unchanged) |
| P12 | fusheng@ | read both contracts | sell contract 0 rows (base table, RLS), buy contract 1 row; checklist empty for him |
| K | postgres | end | journal entries 82 · lines 184 unchanged; nothing waiting; `approval_log` +5 inside the transaction (rolled back) |

**Before and after readings** — `db/scripts/2026-09-27-terms-edit1-readings.sql` (part 1 as `postgres`, base tables, `relkind` printed;
part 2 as tim@ on views; part 3 each account as itself), before at 2026-09-27 17:59:23, after at 2026-09-27 20:06:56 (after the proof and both smoke runs); `READINGS_OWN_EXIT=0` both times. Diffed (`diff` of the two outputs):
- **identical:** approvals on (L1 finance, L2 cfo, threshold 1000, locked before 2026-08-01); contracts 0 (ZZ-SMOKE 0), every term table 0,
  `contract_document_terms` 0; terms requests 0, waiting 0; 8 contract guards; write policies (7 term tables 1 each, `contracts` 2);
  approval_log 14; journal entries 82, lines 184, Σ debits 1,636,102.89; balances 1000 −127,593.48 · 1100 43,002.12 · 1200 61,387.92 ·
  1400 18.00 · 2000 −376,404.42 · 2100 −102.87; catalogue 69; holders of the seven relevant codes; every role's code count and md5 (admin 68
  `957c088c…` · cco 39 `0f3799de…` · cfo 30 `730763e8…` · finance 39 `1898acc0…` · the rest unchanged) and every role's code list; every real
  account's `current_user_permissions()`; 7 unrevoked grants; PO digest `15e452a4…`; `approval_pending_documents()` = 1 expense claim
  (1,000.00, `blocks_disable` 0); as tim@ on the views: AP list 416,988.32 / ledger 376,404.42, AR list 57,545.87 / ledger 43,002.12,
  **unexplained 0.00 on both sides**.
- **changed, as intended (and only these):** `contract_activation_missing(uuid)` absent → present (INVOKER, `authenticated` t, `anon` f);
  `contract_terms_lock_reason` definition md5 `318b0d9f…` → `f037c305…` (still DEFINER, `anon` f); `terms_request_submit_internal`
  `1cb402aa…` → `73819e8e…` (still DEFINER, `authenticated` f, `anon` f).

## §4 · Who can do what now (approvals on)

- **Sandra (cco, `action.contract_terms`):** **newly** edits a draft or suspended contract's header and all seven kinds of terms on
  `/contracts/<id>`, sees what is still missing before activation, and requests activation there. Refused (visibly, with the reason) on an
  active contract, while a request waits, and on an expired or terminated one. Suspends from the same page.
- **Tim as tim@ (cfo):** sees every contract's page read-only (every control disabled naming `action.contract_terms`); approves or rejects
  on the contract's page or on `/contracts`, and each request links to the contract. No new refusal.
- **Tim as admin@:** holds `action.contract_terms`, so edits like Sandra; a request raised as admin@ is still refused at submit
  (`TERMS_REQUEST_NO_OTHER_DECIDER`), unchanged from APR-8. Cannot decide.
- **Choo Er (finance) · Phua (cto) · Vince (gm):** read both sides read-only; controls disabled naming the code.
- **Fu Sheng (warehouse):** reads buy-side contracts read-only (holds `module.suppliers.view` and `data.view_purchase_prices`, so the
  buy-side rates are what the matrix already allows); a sell-side contract is a 404 for him, as it is absent from his register.
- **Newly refused for everyone (through the API too):** requesting activation of a sell contract with incomplete terms
  (`CONTRACT_TERMS_INCOMPLETE`); editing the terms of an expired or terminated contract (`CONTRACT_TERMS_FROZEN|…|expired|terminated`).
- **Nothing left pending by this cut; every pending document still has a decider who is not its own party** (the migration printed each:
  CLM-2026-0004 → tim@; LV-2026-0001 / 0003 → admin@, tim@; MC-2026-0001 → admin@, chooer@; ST-2026-0082…0086 → chooer@; terms_request
  deciders: 1).

## §5 · Findings registered on the way

- **Closed:** `APR8-NO-TERM-EDITOR` (`docs/known-issues.md`, struck through with the closing note).
- **Registered:** `TERMSEDIT1-ENDED-HEADER-WRITABLE` (build decision 3).
- **Registered:** `TERMSEDIT1-EXPOSURE-IGNORES-STATUS` — `price_exposure_report` lists every contract's pricing terms whatever its status,
  so a **draft** with a pricing term shows as a sell position on `/finance/price-exposure`. Found by this cut's first smoke run: the smoke's
  own sell draft carried a pricing term, that page left its "named zero" state, and its content needle (which accepts only the two named
  zeros) went red. The smoke's draft no longer carries a pricing term (which also exercises the page's "still missing" checklist). Two
  questions for Tim: should the report count only `active` contracts; and that needle must learn the "positions" state before the first
  real sell contract with pricing terms appears.
- `/contracts` had linked every contract code to `/contracts/<id>` since before this cut, and that page did not exist — it now does.

## §6 · Screen inventory — every action this cut adds or changes

| action | who | route | file |
|---|---|---|---|
| Open a contract (code link in the register; also in "Putting contracts in effect") | everyone who can see that side | `/contracts` → `/contracts/[id]` | `app/contracts/ContractsTables.tsx` · `ContractActivationPanel.tsx` |
| See the header, the seven kinds of terms, status and period | readers of that side (sell: `module.customers.view`; buy: `module.suppliers.view`) | `/contracts/[id]` | `app/contracts/[id]/page.tsx` |
| Edit the header (counterparty and side fixed, disabled with "create a new contract") | `action.contract_terms`, draft / suspended, no waiting request | `/contracts/[id]` | `app/contracts/[id]/HeaderForm.tsx` · `actions.ts` `saveContractHeader` |
| Add / edit / delete a grade spec · insurance obligation · volume commitment | same | `/contracts/[id]` | `app/contracts/[id]/TermSection.tsx` · `actions.ts` `saveTermRow` / `deleteTermRow` · `termSpecs.ts` |
| Add / edit / delete index pricing · settlement basis (one per contract) · refining charges · penalty elements | same, **sell contracts only** (buy: shown disabled with the reason) | `/contracts/[id]` | same |
| See what is missing before activation (sell) — Request activation disabled, each item named | everyone on the page | `/contracts/[id]` | `app/contracts/ContractActivationPanel.tsx` (checklist from `contract_activation_missing`) |
| Request activation (reason required) / Suspend an active contract | `action.contract_terms` | `/contracts/[id]` (and `/contracts`, unchanged) | `ContractActivationPanel.tsx` · `app/components/pricing/termsRequestActions.ts` |
| Approve / reject a contract activation (side-by-side terms, changed rows marked) | CFO (the five gate codes; the database refuses the raiser) | `/contracts/[id]` (this contract's requests) · `/contracts` (all) | `app/components/pricing/TermsRequestsPanel.tsx` · `termsRequestsData.ts` (`contractId` filter) |
| Open the contract from its request | CFO and anyone who sees the panel | `/contracts` → `/contracts/[id]` | `TermsRequestsPanel.tsx` (code is a link for contract requests) |
| Withdraw a contract request | the raiser, or `action.contract_terms` | `/contracts/[id]` · `/contracts` | `TermsRequestsPanel.tsx` |
| Create a contract — now lands on its page | `action.contract_terms` | `/contracts/new` → `/contracts/[id]` | `app/contracts/new/actions.ts` · `NewContractForm.tsx` |

## §7 · The broken window — started, end PENDING

**Start: 2026-09-27 18:02:10 CST** (`db/apply_migration.sh`'s own line, also in `db/migration-windows.tsv`; its "applied at" line reads
18:00:56). **End: PENDING — Tim reads it from Vercel.**

**Closed in EMP-SELF-1 (2026-09-27) — with bounds, labelled by kind.** Tim confirmed TERMS-EDIT-1 deployed (in the EMP-SELF-1 brief) with no
Vercel "Ready" time.

| | time (CST) | kind |
|---|---|---|
| start | 2026-09-27 18:02:10 | **measured**: `db/migration-windows.tsv` / `apply_migration.sh`'s own line |
| end, lower bound | 2026-09-27 20:09:28 | **measured**: the push moved `origin/main` → `888c97c4` (`git reflog show --date=iso refs/remotes/origin/main`) |
| end, upper bound | 2026-09-27 20:21:25 | **derived**: EMP-SELF-1's first read of `now()` as `postgres` (`rolbypassrls = t`), taken with Tim's "deployed" confirmation already in hand — **a relayed confirmation, not a measurement of Vercel** |

**Window: at least 2 h 07 min 18 s, at most 2 h 19 min 15 s.**

**Tim accepted build decisions 1 and 2 (2026-09-27):** the four "USD per tonne" labels stay baselined in
`scripts/currency-messages-baseline.json`; the shared `ContractDateInput` and the tightened date baseline (138 → 135) stand.
Decision 3 (`TERMSEDIT1-ENDED-HEADER-WRITABLE`) was then fixed by EMP-SELF-1 on Tim's Q7 ruling.

What the old app does against the new database (approvals ON):
- **Requesting activation of a sell contract with incomplete terms** is refused `CONTRACT_TERMS_INCOMPLETE`; the old copy has no sentence
  for it, so it shows the generic text. **No live impact:** there are 0 contracts, and the old app has no screen to enter terms anyway.
- **Editing the terms of an expired or terminated contract through the API** is refused; the old app has no such screen.
- **Unaffected:** everything else — the old `/contracts` and `/contracts/new`, APR-8's requests and decisions, every other chain, the
  switch, everything pending. The old register still links to `/contracts/<id>`, which 404s until the deploy (as it always has).

## §8 · Commit, push, three SHAs

Reported in the hand-back message: `HEAD`, `origin/main` and `git ls-remote origin main` as full 40-character SHAs (a commit cannot
carry its own hash). Deployment is Tim's to read; the window's end stays PENDING until he does.
**Next cut:** EMP-SELF-1 (the remaining part) — `docs/forward-queue.md` item 17.
