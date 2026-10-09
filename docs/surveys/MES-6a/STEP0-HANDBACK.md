# MES-6a Step 0 — hand-back (2026-10-09), with the MES-5b-3 close-out

**STOP GATE.** No code edit, no migration, no live write. The only writes are docs:
- the close-out (`cdfd6645`, "MES-5b-3 close-out": `docs/forward-queue.md` item 46, `docs/surveys/MES-5b/MES-5b-3-CLOSEOUT.md` and its readings / render files);
- this file and the read-only query file beside it (`live-readings.sql`).

Waiting on Tim's answers to Q1–Q45 (§12).

**Opening check.** First command **2026-10-09 18:40:39 CST**. Tree clean. `HEAD` = `origin/main` = `git ls-remote origin main` =
`45ca694cb9ffb150b8887315d39c4e30ab92d273`. Files staged by explicit path only.

**Live readings (measured, read-only).** `live-readings.sql` at **18:55:03 CST**, as `postgres` (`rolbypassrls = true`) over direct psql to the pooler,
inside `BEGIN READ ONLY … ROLLBACK`, on base tables and the catalog; `READ_OWN_EXIT=0`. Standing state: 7 accounts, 0 disabled · approvals ON
finance / cfo / 1,000 · `require_calibrated_since` NULL · catalogue 75 codes (34 action), 0 with "quality" in the name.

**How the facts were gathered.** Four read-only sub-agents, none connected to a database or ran a build:
- assays, samples, arbitration and the purchase-side pricing path (every function, table, page and fixture, with path:line);
- substances (F / Cl), the inline-quality ingestion class and the laboratory → supplier link;
- every path that reverses an expense today (F3);
- measured active times of MES-5b-1 … MES-5b-3 from the session transcripts (the MES-5b Step 0 calibration script, recovered and re-run; it
  reproduces the earlier MES-3b / MES-5a-1 / MES-5a-2 rows to the second), and what earlier records left to MES-6a.

Two more sub-agents read `docs/known-issues.md` and `docs/forward-queue.md` in full for the close-out and for this survey. I read in full: AGENTS.md,
the specification PDF (pypdf, 11 pages), MES-0 README, the MES-5b Step 0 hand-back, the MES-5b-1 and MES-5b-3 hand-backs, the MES-5b-2 close-out,
`docs/mes-pending-values.md`, `docs/role-matrix.md`. Every load-bearing claim below was re-read at its file:line (spot-checked: `messages/en.ts:2169`,
`assay_results.sql:14-15`, `apply_assay_result.sql:145-152`, `reverse_expense.sql:27`, `expenses.sql:172-186`) or measured live.

Tags: **[M]** measured · **[I]** inferred from code reading · **[Q]** quoted from an earlier record · **[S]** from the specification · **[R]** a Tim ruling already on record.

---

## §0 · Step 1 — MES-5b-3 close-out, item by item

Full evidence: `docs/surveys/MES-5b/MES-5b-3-CLOSEOUT.md`. Committed and pushed as `cdfd6645` ("MES-5b-3 close-out").

| Item | Result |
|---|---|
| 1 · Broken window | Start 17:21:45 CST (measured, `db/migration-windows.tsv`) · end lower bound 18:18:14 CST (measured, reflog of `origin/main` → `45ca694c`) · end upper bound 18:40:39 CST (this session's first command, resting on Tim's "deployed", not a Vercel reading) → **56 min 29 s – 1 h 18 min 54 s**. Nobody used the feature in it (plans 0, blending runs 0, runs since 0). `docs/forward-queue.md` item 46 |
| 2 · Vercel information | `032f557a` (docs only) build failed after 1 m 49 s; `45ca694c` deployed; Tim gave no log; no action — recorded in item 46 as a relayed statement |
| 3a · Fixture list | ✓ every item mapped to its fixture arm and injection cell: 259 (ten arms, 37 cells) · 100 (55 → 56, one cell) · 101 (47 → 48) · 254 NUM (56 rows) · 257 FCHECK (admin holds every code, one cell) · 235 stays 8; `check-search-registry` `SR_OWN_EXIT=0` (56 / 56) and `check-document-registry` `DR_OWN_EXIT=0` (286 / 87) run today |
| 3b · Trail, ㉕, BLD, exclusions | ✓ `trail_subjects.sql:288-289`, `trail_subject_members.sql:518-519` (live same); ㉕ clean `TW_CLEAN_OWN_EXIT=0` / fault `TW_FAULT_OWN_EXIT=1`, red in ㉕ only; BLD row `document_types.sql:179-180` (live same, 56 rows); exclusions live 8 (`gaps []`, 278 / 286) |
| 3c · +107 px | ✓ plan page `/operation/blending/[id]` (harness of the real components), the permission notice beside the cancel-reason input (`inline` gate did not wrap) → `flex-wrap` on both gates (`BlendingPlanActions.tsx:39`, `:57`); 390 px +107 → 0, 1280 px 0. The before figure is the hand-back's (harness not committed) |
| 3d · Deployed app | ✓ clones of warehouse (28) · finance (41) · admin (75): `/operation/blending` and `/new` **200** for all; warehouse and admin have the "New blending plan" link, finance a disabled button naming `action.wo_create` and a disabled form; a non-existent plan id **404** after the gate; `/operation/processing/new` **200**, 7 operations, **no `blending`**. **Release on a plan page cannot be rendered: live has 0 plans.** The creator sees the release control **disabled with its reason** (DBLOCK-1), not hidden — the brief's wording is imprecise; who can press it was measured in MES-5b-3's rolled-back live proof |
| 3e · Decisions | 25 titles listed in the close-out file §2 e |
| 4 · Commit | `cdfd6645` "MES-5b-3 close-out", pushed |
| 5 · Stop? | Nothing missing or not working → step 2 went ahead |

---

## §1 · What grilling changed in MES-6a's scope

1. **The inline-quality transform cannot be built in this cut** [M + Q]. No payload format exists anywhere in the repo for `inline_quality`; the standing
   rule ("no transform is built on a payload format no real device has supplied", `docs/handbacks/MES-5a-1.md:115`, `MES-5a-2.md:118`,
   `docs/surveys/MES-4a/STEP0-HANDBACK.md:539-541`) applies. Live: the class is active with `transform_function` NULL, and so are 6 other classes;
   0 devices of kind `inline_instrument` (gateway 2, scale 2). MES-0's cut line (`README.md:703`) and MES-1 / MES-2 Step 0 (`:190`, `:172`) assigned it
   here — it stays `awaiting_transform`; the manual stand-in is the assay record (MES-0 D7). Q2.
2. **Adding F and Cl is not a picker filter; two sale paths would stop** [I, code read].
   - `sale_settlement_compute.sql:202-216` loops over **every** metal on the assay and raises `SETTLEMENT_PAYABLE_NOT_STATED|<metal>` without a pricing
     term; with `per_metal` refining it raises `REFINING_CHARGE_NOT_FILED` (`:238-245`). An F row on a sale assay blocks settlement.
   - `price_output_sale.sql:47-50,94-104` prices every `output_batch_metals` row; an unpriced metal → `METAL_PRICE_MISSING`. An F row on an output
     batch blocks every sale quote.
   - `apply_assay_result` feeds all assay metals into `calculate_metal_price_from_terms` (F lands in `skipped_metals` / `unpaid_metals`);
     `processing_metal_recovery_all.sql:17-77` would give F a "recovery" row; `allocate_processing_costs` lists it as skipped.
   - Pickers would print the raw key **"metals.f"**: `toOptions` builds `labelKey: 'metals.' + code` (`substanceQuery.ts:78-84`) and only the 7 metals
     have keys (`messages/en.ts:7653-7661`).
   - So role filtering is needed in **readers and validators**, not only pickers (Q27, Q28, Q30).
3. **Fixture 119 pins the opposite of the role filter** [M]. It inserts a new substance and asserts that **no** path refuses it, price paths included
   (`119-…:74-139`). A role filter that refuses penalty elements on price paths must rewrite 119 (Q27). Fixtures 116, 119, 244 insert substances
   without a role column, so `role NOT NULL` with no default breaks them (Q26).
4. **A latent "D4" defect becomes reachable once disputes exist** [I]. `apply_assay_result` step 6 (`:145-152`) marks the previously applied assay
   `superseded_by` whatever the new assay's party — applying a counterparty or umpire result would "supersede" ours, which the table's own comment
   forbids (`assay_results.sql:199-208`). Today nobody applies a non-`ours` inbound assay, so it has never fired (Q20).
5. **The purchase side reads no party and no limit; buy contracts carry no settlement terms** [M + I]. `result_party` is read only by
   `sale_settlement_compute` (`:154-169`); `contract_settlement_terms` is sell-only in the UI (`termSpecs.ts:15-16`) and `contract_activation_missing`
   requires terms only on sell contracts (`:42`). So on the buy side a splitting limit and a fee rule (V14) **cannot exist** today — every buy-side dispute
   reads "limit not set", which is exactly what Q62 ruled (Q17, Q22).
6. **The pricing request does not see a dispute** [I]. `receipt_price_fingerprint.sql:20-35` holds no party and no dispute state, so a dispute opened
   while an assay-sourced request waits would not trip `RECEIPT_PRICE_CHANGED_SINCE_REQUEST`; the hold has to be checked again at posting (Q18).
7. **F3 is smaller than "add a reason" and larger than "one function"** [I].
   - Only `reverse_expense_internal` changes an expense's status; two entry points reach it: `reverse_expense` and `reverse_electricity_allocation`.
   - `reverse_expense(p_expense_id uuid, p_memo text DEFAULT NULL)` **already takes an optional memo** (`reverse_expense.sql:27`); it lands only in the
     **mirror** row's `notes` as `'REVERSAL: <code> — <memo>'` (`reverse_expense_internal.sql:133-143`). The page never sends it
     (`app/finance/expenses/[id]/actions.ts:13-18`). `docs/forward-queue.md:642` ("`reverse_expense` 不收理由") is therefore imprecise.
   - `guard_expense_mutation` forbids writing anything onto the original row except posted → reversed + `reversed_by_expense` (`expenses.sql:172-184`),
     so a reason on the original needs the guard extended (Q34).
   - Expense claims and medical claims have no reversal of their own (they reverse through `reverse_expense` on the generated expense); freight,
     payments, journals, payroll and overtime already require reasons. Live: **10 expenses, 0 ever reversed** [M].
8. **The trail calls an inbound counterparty "The buyer"** [M]. `assay_results.result_party` borrows the label set `contracts.settlement.party`
   (`scripts/check-i18n.mjs:639` → `messages/en.ts:2169` `counterparty: 'The buyer'`). On an inbound assay the counterparty is the supplier (Q24).
9. **Indicators the specification puts on assays have nowhere to go** [M]. Residual powder on foil, foil purity and particle-size distribution
   (spec §3.5, MES-0 3.5b/3.5c/3.5e assigned here) — `assay_result_metals` holds substances only; grep for particle / psd / d50 in `db/` → 0. Moisture
   exists (`assay_results.moisture_pct`). Q3, Q4.
10. **Size.** Samples + arbitration + the hold + F3 is one proof shape (records, a refusal on the pricing path, a finance reversal); F/Cl + indicators is
    another (dictionary roles threaded through pricing and settlement readers). Together ≈ 3 h 25 – 5 h 10 calibrated, the top above the largest
    measured MES cut (3 h 35). Recommendation: **two cuts** (Q1).

---

## §2 · (a) What MES-6a is, and exactly what it contains

MES-0 §8.2 row 9 [Q, `docs/surveys/MES-0/README.md:703`]: functions **15 samples · 16 arbitration · 19 F and Cl**; "`samples`, `assay_disputes`;
`substances.role` + F, Cl rows; laboratory → supplier link; purchase-side hold in `apply_assay_result` / `reprice_inbound_batch`; inline quality
transform"; 3 tables / 3 pages; estimate 5 h 15 – 8 h 45. Rulings already on record [R, all of MES-0 Q1–Q96 accepted, `README.md:1141`]:
**Q61** samples · **Q62** purchase-side arbitration ("prompt only where a splitting limit exists … while a dispute is open, final repricing of that
batch refuses") · **Q63** fee split (contract term, V14; fee = expense; counterparty share = receivable or deduction) · **Q64** labs → suppliers ·
**Q69** F / Cl + `substances.role`, ppm display · **Q53** sample code `SMP-` · **Q90** `module.quality.view` / `.edit`. Spec items assigned here [Q]:
3.5b residual powder, 3.5c foil purity, 3.5d moisture, 3.5e particle size, 3.5i sample id bound to batch, 3.5j inline average, 5f; V14–V17.
Earlier Step 0s: inline quality transform (MES-1 `:190`, MES-2 `:172`), indicators + samples (MES-4b `:93`).

**Proposed contents, by recommended cut (Q1):**

**MES-6a-1 · Samples and arbitration (+ lab → supplier, + F3)**
- **Tables:** `samples` (`SMP-YYYY-NNNN`, gapless, yearly; inbound XOR output batch; kind; taken at / by; retain-until in force; optional
  `contamination_check_id`) · `sample_events` (append-only custody: taken · sent to lab · received back · moved · disposed — with lab, location,
  reason) · `assay_disputes` (batch; our assay; counterparty assay; status open / resolved / withdrawn; opening reason; limit in force; umpire sample
  and umpire assay; governing assay and resolution note; fee expense; fee rule in force) · `quality_settings` (one row: V16).
- **Columns:** `assay_results.sample_id` (nullable FK, beside `sample_ref`) · `laboratories.supplier_id` (nullable FK) ·
  `contract_settlement_terms.arbitration_fee_rule` (nullable, V14) · `expenses.reversal_reason`, `reversed_at`, `reversed_by` (F3).
- **Functions:** `record_sample`, `record_sample_event`, `open_assay_dispute`, `resolve_assay_dispute`, `withdraw_assay_dispute`,
  `link_dispute_fee`, `next_sample_code`; `record_assay_result` gains `p_sample_id` (appended, DEFAULT NULL); `apply_assay_result` +
  `preview_assay_price` refuse `ASSAY_DISPUTE_OPEN`; `receipt_price_post_internal` refuses posting an assay-sourced request while a dispute is open;
  `sale_settlement_compute` refuses `ASSAY_DISPUTE_OPEN`; `apply_assay_result` stops superseding across parties (D4); `reverse_expense` /
  `reverse_expense_internal` require the reason; `guard_expense_mutation` admits the three new columns in the reversal transition.
- **Codes:** `module.quality.view` / `module.quality.edit` (Q90, Q11–Q13); declarations in `permissions.requires_view_any`.
- **Pages:** `/quality/samples` (list), `/quality/samples/[id]` (custody, assays, trail), `/quality/disputes` (list), `/quality/disputes/[id]`
  (the two results side by side, differences per metal, limit, umpire, resolution, fee, trail); a samples panel and a dispute link on
  `/inbound/[id]/edit`, `/output/[id]/edit` and the two assay detail pages; sample picker on both assay forms; reason box on
  `/finance/expenses/[id]`; lab → supplier in the laboratories dictionary editor.
- **Arms:** reminder `sample_retention_due` (retained, past retain-until, not disposed); `assay_dispute_open`; `assay_results_disagree` (sell side,
  limit exists, ours vs counterparty beyond it, no dispute — Q62's prompt); pending values V16 and V14.

**MES-6a-2 · F and Cl, and the quality indicators**
- `substances.role` (NOT NULL, `payable_metal` · `penalty_element` · `other`); rows `f`, `cl`; role filters in pickers, validators and payable readers;
  dictionary names instead of `metals.*` keys in `toOptions`; ppm display for penalty elements.
- `assay_indicators` (dictionary: code, unit, names, active) + `assay_result_indicators` (per assay, value) with residual powder, foil purity and particle
  size (Q3, Q4); entry on both assay forms; shown on assay and batch pages.
- `ingest_data_classes.inline_quality.target_en` re-pointed at the indicators (text only; the transform stays NULL — Q2).

**Left to later cuts** [Q / I]:
- the inline-quality transform itself → the cut that connects the first inline instrument (needs its vendor's payload; D7);
- V17 acceptance limits (moisture, particle size) per contract → MES-6b with the quality hold (Q5);
- N38 chemistry certainty on outputs (`docs/known-issues.md:4468-4480`, "化验那一刀") → MES-6b (the CoA must state it) (Q6);
- collecting the counterparty's share of a fee (receivable / settlement deduction) → with the purchase-side settlement ruling (index-pricing §9) (Q22);
- NCR, quality hold G29, CoA → MES-6b; `metal` → `substance_code` rename (623 sites, `known-issues.md:4514-4533`) → its own cut;
- the purchase-side weight-basis branch (SETTLE-1 ①, `known-issues.md:6614-6627`) → index-pricing §9 (Tim, unanswered).

## §3 · (b) Each function: what is recorded, where entered, where shown, how it relates

| function | recorded | entered | shown | relation to today's records |
|---|---|---|---|---|
| **15 Samples** | a physical sample: code, batch, kind (ours · counterparty · umpire · retained · contamination, Q61), when / who taken, mass (optional), retain-until in force; custody events (sent to which lab with which reference, received back, moved to which location, disposed with reason) | `/quality/samples` new (from a batch page with the batch pre-filled); custody on the sample page | sample page; samples panel on both batch pages and both assay pages; sample on the assay; reminder arm | **batches:** inbound XOR output, like assays (`assay_results_one_parent`). **Assays:** `assay_results.sample_id` beside the free-text `sample_ref` (4 live assays, `sample_ref` set on 0 [M]); a sample must belong to the assay's batch. **Contracts:** retain-until from the sales contract snapshot's `sample_retention_days` (sell only — buy contracts carry no settlement terms) else V16. **Locations:** `storage_locations` (no `kind`; `is_quarantine` exists). **Contamination checks (MES-4b):** optional link for kind `contamination`. **Runs, grade specs, MES-4a/5a/5b records:** none |
| **16 Arbitration** | a dispute: batch, our assay, counterparty assay, per-metal difference (computed), limit in force (copied: sell contract snapshot, buy "not set"), umpire sample / assay, governing assay + note, fee expense, fee rule in force | `/quality/disputes` — opened from an assay page or the `assay_results_disagree` arm | dispute page; banner on the batch and assay pages; arms | **Assays:** reads two, never edits them; resolution names the governing one, which is then applied the normal way (`apply_assay_result` → CFO request, ROLE-1 4b). **Purchase pricing:** `apply_assay_result` and posting of an assay request refuse while open (Q18). **Sell settlement:** `sale_settlement_compute` refuses while open; its existing derived refusals stay. **Contracts:** reads `splitting_limit_pct`, new `arbitration_fee_rule`. **Expenses:** the fee is an ordinary unpaid expense to the lab's supplier (Q63), linked by id. **Labs:** `laboratories.supplier_id` (Q64). **Runs, blending:** `blending_plan_outcome` and `contract_grade_breaches` stay as they are (they read the latest non-superseded assay; D4 fix keeps ours visible) |
| **19 F and Cl** | two substances with role `penalty_element`; contents in % | assay forms (both), batch content panel, required metals, PO expected assay, contract grade specs and penalty elements, blending targets | assay / batch pages with ppm beside %; penalty terms in ppm | **Assays and batch content:** stored like any substance. **Pricing (metal prices, formulas, commitments, calculator, pricing terms, refining charges):** payable metals only. **Settlement:** payable loop skips non-payables; penalty loop reads them (`:259-284`). **Recovery view, cost allocation:** payable only. **Grade specs, blending:** any role (F max bound is meaningful) |
| Indicators (6a-2) | residual powder %, foil purity %, particle size µm per assay | assay forms | assay pages; batch page "latest recorded" | assays only; no batch-level copy; contract limits wait for MES-6b (V17) |
| Lab → supplier | which supplier pays a lab | dictionary editor (`module.materials.edit`) | dispute fee, lab dictionary | `forwarder_details` precedent per Tim's ruling (`laboratories.sql:28-31`); payment still needs an approved supplier (`payment_request_payee_check.sql:45-50`) |
| F3 | reason, when, who, on the reversed expense | reason box in the reverse dialog | expense page banner, expense trail, claim trails | both entry points through `reverse_expense_internal`; mirror `notes` stops carrying human text |

## §4 · (c) Effect on existing pages, functions and fixtures

**Functions changed (all CREATE OR REPLACE, same signature, unless stated):**
- `record_assay_result` — **signature change** (append `p_sample_id uuid DEFAULT NULL`): DROP + CREATE + its signature-specific REVOKE / GRANT
  (`2026-08-23-proc6-…sql:282-283` precedent). Positional callers `82:88,148`, `238:146`, `259:148,370` stay valid (appended with default); named
  callers 15, 21, 54, 118, 119, 217, 220, 221 unaffected.
- `apply_assay_result` (dispute refusal after the batch lock `:43-48`; D4 at `:145-152`), `preview_assay_price` (parity, by batch — fixture 40's contract),
  `receipt_price_post_internal` (refuse posting an assay request while a dispute is open), `sale_settlement_compute` (one refusal).
- `reverse_expense`, `reverse_expense_internal`, `guard_expense_mutation`; `reverse_electricity_allocation` passes its reason through unchanged in text.
- 6a-2: `upsert_metal_prices`, `calculate_metal_price_from_terms`, the formula / commitment writers (refuse non-payables), `sale_settlement_compute`
  payable loop, `price_output_sale`, `processing_metal_recovery_all`, `allocate_processing_costs` (payable only).
- `pending_values` (+ V16, V14 arms), `operations_now` (+ 3 arms), `trail_subjects` / `trail_subject_members` (+ `sample`, `assay_dispute`).

**Pages changed:** both assay forms (sample picker), both assay detail pages and both batch edit pages (samples panel, dispute banner),
`/finance/expenses/[id]` (reason box, banner from the original row), the laboratories dictionary editor (supplier), `/settings/pending-values`
(messages), Operation / Quality navigation. 6a-2: 4 metal-price pages, calculator, formula form, contract term specs, `MetalContentPanel`
(ppm; `toFixed(2)` hides 0.0050 %), `substanceQuery.ts` labels.

**Fixtures** (no assertion removed; every new arm fault-injected):

| fixture | change |
|---|---|
| 40 | a new arm: preview refuses where apply refuses `ASSAY_DISPUTE_OPEN` (parity) |
| 118 F4 | unchanged (records three disagreeing results, none superseded) — the D4 fix keeps it true; a new arm: applying the counterparty result does not supersede ours |
| 149 D | unchanged arms; a new arm `ASSAY_DISPUTE_OPEN` on the sell side |
| 220 I | a new arm: an assay request waiting when a dispute opens cannot be approved |
| 256 REV, 258 PERM / F2 / VAR / KINDS | single-argument `reverse_expense` calls (`256:426`; `258:227,333,375,384,442,448,456,461,471,483`) gain a reason so they still reach the refusal they assert; a new blank-reason arm |
| 105, 106, 129, 130, 135, 201, 213, 241, 258 F2 | already pass a memo — unchanged; 106 `:76` (`notes LIKE 'REVERSAL:%'`) stays true |
| 214 `:194` | pins `reverse_expense(uuid,text)` — unchanged (signature kept) |
| 100 · 101 · 254 · search / document registries | 56 → 57 (SMP), +1 MAX+1 minting function; (table, code) pairs +1; tables +4, code tables +1 |
| 235 · 234 · 102 | new tables bound; exclusions stay 8 |
| 116 · 119 · 244 (6a-2) | name a role in their substance INSERTs; 119 rewritten: a new **payable** substance passes every path, a **penalty element** is refused by name on price paths and accepted on assay / content / grade / penalty paths |
| 30 · 121 · 242 (6a-2) | unaffected (`>= 7`, `ORDER BY code LIMIT 1` still `al`) |
| new | 260 (samples, disputes, the hold, D4, F3), 261 (roles, F / Cl through pricing and settlement, indicators) |

Static checks touched: `check-i18n` (new prefixes wired), `check-action-view-declared` (quality codes), `check-trail-wording` (arms ㉖ / ㉗),
`check-confirm-subject` (reason dialog), `check-search-registry`, `check-document-registry`.

## §5 · (d) Approvals, audit trails, change log, masking

- **Approvals: none new** [R + M]. The house test (`docs/approvals.md:1093-1094`: "does the document have a state in which it waits for someone, or is
  creating it the act?"): a sample and a custody event are records of events; a dispute waits for a laboratory, not for an approver; resolving it decides
  nothing about money — the governing assay goes through the existing CFO-approved pricing request (ROLE-1 4b). The fee is an ordinary expense
  (expenses are not approved, `role-matrix.md:87`); its payment goes through the payment request (CFO). F3: expense reversals carry no approval
  (MES-5b Q25, `role-matrix.md:168`). Approvals ON / finance / cfo / 1,000 unchanged.
- **Trails:** new subjects `sample` (members: `sample_events`) and `assay_dispute`; both also members of `inbound_batch` / `output_batch` (where assays
  already are, `trail_subject_members.sql:54-55,100-101`). The expense subject renders the reversal reason from the original row's UPDATE, so it also
  reaches the expense-claim subjects, which today lack the mirror (`:377-382`). One wording arm per cut with its own fault (㉖ 6a-1, ㉗ 6a-2); the label
  fix of §1.8 rides ㉖.
- **Change log:** every new table bound (`gen_change_log_bindings.py --only`); no exclusion (stays 8). `quality_settings` changes are change-logged
  (the `electricity_settings` precedent for a pending value's edits).
- **Masking: none new.** Samples, disputes, indicators and contents are technical data — perm2b left `content_pct` unmasked on purpose
  (`2026-08-01-perm2b-field-masking.sql:83-84`). The fee lives on an expense (decision 1: finance view sees prices). The F3 reason is unmasked (Q35).

## §6 · (e) "Not yet set" values MES-6a adds

| # | value | lives on | page | arm reads | permission | supplied by | when |
|---|---|---|---|---|---|---|---|
| V16 | Internal sample retention (days) for samples no contract governs | `quality_settings.internal_retention_days` | `/quality/samples` settings panel | the single row while empty **and** at least one retained sample exists with no contract days (V9 precedent: no rows nobody can act on) | `module.quality.view` | Tim / quality | the first retained sample |
| V14 | Arbitration fee split rule per sell contract | `contract_settlement_terms.arbitration_fee_rule` | `/contracts/[id]` settlement terms | each contract with a dispute (open or resolved) and the rule empty | `module.customers.view` (the terms' own read) | the counterparty contract | contract signing |
| V15 | F / Cl penalty thresholds and rates | `contract_penalty_elements` (exists) | `/contracts/[id]` | **no arm** — a per-contract term already refused by name at settlement (`PENALTY_ELEMENTS_NOT_FILED`) when the contract declares `per_element` | — | counterparty contract (U11) | first contract with a penalty structure |
| V17 | Moisture and particle-size acceptance limits | — | — | **deferred to MES-6b** (Q5) | — | offtake contract | first offtake contract |

Live today: 0 contracts, 0 samples, 0 disputes [M] — both new arms are empty on day one. Nothing guesses a number.

## §7 · (f) F3 — today's paths, what a required reason changes, fixtures

**Today** [I, path:line]:
- `reverse_expense(uuid, p_memo text DEFAULT NULL)` — `module.finance.edit`; refuses not found, already reversed, an allocation's expense (names it),
  `RELIEF_ESTIMATE_NOW_ALLOCATED`; then `reverse_expense_internal(id, memo)`; then F2's relief restore (`reverse_expense.sql:40-89`).
- `reverse_expense_internal(uuid, text)` — INVOKER, revoked; refuses `EXPENSE_HAS_ASSET`, `EXPENSE_HAS_SETTLEMENT`, `EXPENSE_HAS_PREPAYMENT_APPLIED`,
  `ASSET_IN_SERVICE_COST_LOCKED`, `ASSET_COST_LEDGER_DIVERGED`, `PERIOD_LOCKED` (indirect); reverses the journal (memo "Expense reversal <code>"),
  inserts the mirror with `notes = 'REVERSAL: <code>' || ' — ' || memo`, flips the original to `reversed` (`reverse_expense_internal.sql:33-173`).
- `reverse_electricity_allocation(uuid, p_reason)` — reason required first (`ELECTRICITY_REVERSAL_REASON_REQUIRED`), stored on
  `electricity_allocation_reversals.reason`, and passed to internal as `'Electricity bill reversed: ' || reason` (`:33,50-53,87,115-119`).
- UI: `ReverseExpenseButton.tsx:43-54` — a `ConfirmButton` with no `reason` prop; the action sends only `p_expense_id`. The original's "Memo" on the
  mirror page prints the raw notes (`page.tsx:333-336`); the trail strips only the code prefix (`render.ts:3047-3054`).
- No other UI reverses an expense; claims derive "reversed" from the generated expense.

**What changes for users:** the Reverse dialog gains a required reason box (the `ConfirmButton.reason` pattern of `ReverseAllocationControl.tsx:29-35`:
confirm disabled while blank, server refuses blank independently). The reason shows on the expense's banner, on its trail ("Expense edited · Status:
Posted → Reversed · Reversal reason: …"), and on the claim's trail when the expense came from a claim. Nothing else changes: refusals, dates, F2 restore,
settled / prepayment refusals all as today. Live: no expense has ever been reversed, so no history is rewritten.

**Fixtures:** §4 table (256, 258 gain reasons; a blank-reason arm; a trail arm); the wording arm ⑧ sample (`check-trail-wording.mjs:911-915`) gains the
reason line.

## §8 · (g) Migration shape and broken window

**Shape: one migration per cut, dated from `date`.**
- **6a-1:** four tables; `assay_results.sample_id`; `laboratories.supplier_id` (RUNTIME CONFIG — the bootstrap seeds FRL with NULL, which is still
  correct: no lab has a known supplier); `contract_settlement_terms.arbitration_fee_rule` (nullable; existing rows: 0 live); `expenses` three columns
  + guard + CHECK (`status = 'reversed'` ⇒ reason not blank — holds on live: 0 reversed); `record_assay_result` DROP + CREATE; the other functions
  CREATE OR REPLACE; two permission codes + grants (admin every code; cfo every view code; holders per Q11–Q13) + `requires_view_any`; `SMP` registry
  row; arms; trail registrations.
- **6a-2:** `substances.role` (RUNTIME CONFIG — the bootstrap must state its 7 rows as `payable_metal` and add `f`, `cl` as `penalty_element`; the
  meaning of every existing column is unchanged); two tables; function bodies; the class's `target_en` text.

**Broken window (old app + new database)** [I]:
- **6a-1:** the old expense page sends no reason → **every expense reversal is refused by name** (`EXPENSE_REVERSAL_REASON_REQUIRED`, shown as the old
  localizer's fallback sentence) until the deploy. Live has never reversed an expense. Old assay forms call `record_assay_result` by named arguments
  without `p_sample_id` → resolved by the default, works. The dispute refusals bite only where a dispute exists (none on the old app — it has no dispute
  page). Old pages do not query the new tables. Window ≈ deploy time.
- **6a-2:** old metal-price / formula pickers would offer F and Cl (labelled "metals.f") and the server refuses them by name (`SUBSTANCE_NOT_PAYABLE`);
  old readers never meet an F row until someone records one. Window ≈ deploy time.
- **Existing records:** 4 assays keep `sample_ref` and gain `sample_id` NULL; 10 expenses unchanged (none reversed); 7 substances get
  `payable_metal`; no run, batch, ledger row, grade spec, plan or MES-4a/5a/5b record changes. No back-fill.

## §9 · (h) Time estimate — two numbers, measured calibration

**Measured** [M, transcripts; active = brief → push, gaps < 10 min; the method reproduces the earlier §11 rows to the second]:

| cut | active (build only) | floor | work | Step 0 estimate low | active ÷ low | work ÷ estimated work low |
|---|---|---|---|---|---|---|
| MES-5b-1 | 3 h 05 | 1 h 26 | 1 h 40 | 4 h 05 | 0.76 | 0.55 |
| MES-5b-2 | 2 h 23 | 1 h 26 | 0 h 57 | 3 h 35 | 0.67 | 0.38 |
| MES-5b-3 | 2 h 09 | 1 h 17 | 0 h 52 | 3 h 40 | 0.59 | 0.33 |
| (MES-1 … MES-5a-2) | 2 h 06 – 3 h 35 | 0 h 54 – 2 h 06 | 1 h 01 – 1 h 44 | | median 0.93 | median 0.68 |

Floor components of the last three: smoke 23–27 min, full gate 11–12, backup 10–19, survey 8–12, live proof 3–8, apply 3–5. A close-out runs 12–15 min,
a Step 0 proper 16–20 min.

**Floor used: 1 h 15 – 1 h 45** (the last three clean floors were 1 h 17 – 1 h 26; the top keeps one rerun).

**Work, per cut (estimated low – high, minutes; calibrated at × 0.35 – 0.55, the last three cuts' work ratio):**

| part | 6a-1 | 6a-2 |
|---|---|---|
| orientation | 5 – 5 | 5 – 5 |
| database | samples + events + SMP registry 40 – 60 · disputes + hold (apply, preview parity, posting recheck, settlement) + D4 50 – 80 · lab link + V14 column 10 – 15 · F3 (columns, guard, two functions) 25 – 40 · codes + declarations + arms + V16 15 – 25 | role + rows + validators 25 – 40 · payable readers (settlement, quote, recovery, allocation) 20 – 35 · indicators 20 – 30 |
| pages | 40 – 70 | 20 – 35 |
| fixtures + injections | 30 – 50 | 25 – 40 |
| live proof | 10 – 15 | 5 – 10 |
| messages, docs, static | 15 – 25 | 10 – 20 |
| **work** | **4 h 00 – 6 h 25** | **2 h 10 – 3 h 35** |
| **calibrated work** | **≈ 1 h 25 – 2 h 15** | **≈ 0 h 45 – 1 h 10** |

**Estimates (floor + work):**
- **MES-6a-1 Samples and arbitration (+ lab link, + F3):** floor **1 h 15 – 1 h 45** + work **4 h 00 – 6 h 25** = **5 h 15 – 8 h 10**;
  calibrated ≈ **2 h 40 – 4 h 00**.
- **MES-6a-2 F / Cl and indicators:** floor **1 h 15 – 1 h 45** + work **2 h 10 – 3 h 35** = **3 h 25 – 5 h 20**; calibrated ≈ **2 h 00 – 2 h 55**.
- **One cut instead:** floor 1 h 15 – 1 h 45 + work 6 h 10 – 10 h 00 = **7 h 25 – 11 h 45**; calibrated ≈ **3 h 25 – 5 h 10** (the top beyond the largest
  measured MES cut, 3 h 35).
- MES-0's figure for MES-6a was 5 h 15 – 8 h 45 (without F3, with the inline transform, without indicators).
- F3 alone inside 6a-1: ≈ 25 – 40 min of database work + 10 min page + 15 min fixtures (calibrated ≈ 20 – 35 min).

---

## §10 · Assertions measured and found false or imprecise

1. **MES-0 `:703` "inline quality transform" in MES-6a** — cannot be built under the standing rule (no payload format, no device) (§1.1).
2. **MES-0 `:124` and evidence `:125` "12 FK columns"** — **13** today (`blending_plan_targets.metal`, MES-5b-3) [M, catalog].
3. **MES-0 Q69 "`content_pct` is unconstrained `numeric`"** — it is CHECKed 0–100 on all three tables (`assay_result_metals.sql:15` etc.); only scale and
   precision are free, so ppm still fits as a small %.
4. **`docs/forward-queue.md:642` "`reverse_expense` 不收理由"** — it takes an optional `p_memo` (`reverse_expense.sql:27`); nothing requires or sends it.
5. **`assay_results.sql:14-15`** says applying an `is_final` assay raises `pricing_status` to `final`; since ROLE-1 4b only the CFO's approval of an
   assay-sourced request does (`receipt_price_post_internal.sql:35-39`). To correct when 6a-1 touches the file.
6. **The trail's "The buyer"** for an inbound counterparty assay (§1.8).
7. **`substanceQuery.ts:16-19`** says there are no `metals.*` keys and names come from the dictionary; `toOptions` uses `metals.<code>` keys (`:78-84`).
8. **Citation drift in MES-0 docs:** `sale_settlement_compute.sql:150-186` is now `:152-188`; the SETTLE-1 ② entry is `known-issues.md:6629`;
   `forward-queue.md` sample/assay items moved from `:1624`/`:1681`/`:2926` to `:2014-2068`, `:2074`, `:2104-2112`. Left as history.
9. **`forward-queue.md:2055` vs `:2063`** — U12 ("whose assay governs") is "answered" in one line (sell side: `settling_party`) and "open" in the next
   (it is open for the buy side). Not corrected here.
10. **The brief's "today only the electricity bill reversal requires one"** — true of expense reversals; freight documents, payments, journals, payroll,
    overtime and WHT reversals already require reasons (`FREIGHT_REVERSAL_REASON_REQUIRED`, `PAYMENT_REVERSAL_REASON_REQUIRED`, …).
11. Zero other assertions of the brief found false: SHA, clean tree, 7 accounts enabled, approvals ON finance / cfo / 1,000, `require_calibrated_since`
    NULL, admin 75 / 75 — re-measured.

## §11 · Tim's own facts this cut needs (not design questions)

- Which laboratory does the plant use, and is there an umpire laboratory yet? Live: one lab (`FRL`), no supplier link.
- Who physically takes, labels, stores and ships samples (decides Q12).
- Whether any purchase contract will state assay / arbitration terms (today buy contracts cannot carry settlement terms — §1.5).
- Index-pricing §9 (purchase side, unanswered) — it decides how a counterparty fee share is ever collected on the buy side.

---

## §12 · Every open question, with a recommended answer and its evidence

### A · Scope and cuts

❓ **Q1 — One cut or two.** One cut is ≈ 7 h 25 – 11 h 45 (calibrated ≈ 3 h 25 – 5 h 10). The parts are two proof shapes: records + a refusal on the
pricing path + a finance reversal; and a dictionary role threaded through pricing and settlement readers.
➡️ **Two cuts:** **MES-6a-1 Samples and arbitration** (+ lab → supplier, + F3), ≈ 5 h 15 – 8 h 10, calibrated ≈ 2 h 40 – 4 h 00; then **MES-6a-2 F / Cl and
indicators**, ≈ 3 h 25 – 5 h 20, calibrated ≈ 2 h 00 – 2 h 55. One extra floor (≈ 1 h 15) buys two cuts inside the measured range.

❓ **Q2 — The inline-quality transform** (MES-0 `:703`; MES-1 / MES-2 Step 0 assigned it here). No payload format exists; no inline instrument is
registered (live: 0); the standing rule forbids a transform on an invented format.
➡️ **Not built.** `inline_quality` stays `awaiting_transform`; the manual stand-in is the assay record (moisture today, indicators from 6a-2). It is built
in the cut that connects the first inline instrument, from its vendor's point list. 6a-2 re-points the class's `target_en` at the indicators.

❓ **Q3 — Residual powder on foil, foil purity, particle size** (spec §3.5b/c/e, assigned here; no place to record them today).
➡️ **In 6a-2:** a dictionary `assay_indicators` (code, unit, names, active, RUNTIME CONFIG) and `assay_result_indicators` (assay, indicator, value ≥ 0),
entered on both assay forms, shown on assay and batch pages ("latest recorded"). No batch-level copy, no limit (V17, Q5). Moisture stays its column.

❓ **Q4 — How particle size is recorded.** Laboratories report a distribution as D10 / D50 / D90 (µm); the specification says only "particle size
distribution".
➡️ **Seed five indicators:** `residual_powder_pct` (%), `foil_purity_pct` (%), `d10_um`, `d50_um`, `d90_um` (µm) — five rows; Tim can deactivate any.
Definitions, not standards: no value or limit is seeded.

❓ **Q5 — V17 acceptance limits for moisture and particle size** (MES-0 assigned here). Grade specs hold substances only and are a report, not a gate
(`contract_grade_specs.sql:16-24`); live has 0 contracts.
➡️ **Defer to MES-6b**, where grade breaches meet the quality hold (G29): the limits are per contract and only bite through a hold.

❓ **Q6 — N38, chemistry certainty on output batches** ("留给化验那一刀", `known-issues.md:4468-4480`; MES-5b Step 0 `:204` "the assay cut").
➡️ **Not in 6a.** It is lineage, not an assay record; re-point the known-issues destination to **MES-6b** (the CoA must state certainty).

### B · Samples (6a-1)

❓ **Q7 — Shape.** Q61 ruled the fields; it did not say whether custody is columns or events.
➡️ **`samples` (code `SMP-YYYY-NNNN`, gapless yearly; inbound XOR output batch; kind per Q61; taken at / by; mass g optional; notes; retain-until in force)
+ append-only `sample_events` (taken · sent to lab [lab, reference] · received back · moved [location] · disposed [reason]).** Current holder, location
and state are derived from the latest event — the append-only rule for process records, and "还在不在" (SETTLE-1 ②) answered by a record, not a flag.

❓ **Q8 — Retain-until.** Buy contracts carry no settlement terms (UI and activation check are sell-only).
➡️ **Copied onto the sample at creation:** the sample date + the sales contract snapshot's `sample_retention_days` when the sample names a sales order
whose contract requires retention; otherwise + V16; with V16 empty, "Not yet set" (no date, no reminder). Later changes never re-date an old sample.

❓ **Q9 — Sample ↔ assay.**
➡️ **`assay_results.sample_id` (nullable FK) beside `sample_ref`;** `record_assay_result` gains `p_sample_id uuid DEFAULT NULL` appended last; a sample of
another batch is refused (`SAMPLE_NOT_FOR_BATCH`). Not required — today's path keeps working; the 4 live assays stay as they are.

❓ **Q10 — Contamination samples** (MES-4b checks already record sample mass per stream).
➡️ **Kind `contamination` may name a `contamination_check_id` (optional).** No change to MES-4b tables.

❓ **Q11 — Codes.** Q90 ruled `module.quality.view` (cco, cto, finance, cfo, admin, warehouse) / `module.quality.edit` (cco, cto, admin). Alternative:
samples follow the batch's codes as assays do.
➡️ **Introduce both codes now, as Q90 ruled**, with a Quality module (`/quality/samples`, `/quality/disputes`). Samples cross both batch kinds; disputes
belong to neither. Every code to admin; every view code to cfo (standing rulings). Pages gated `module.quality.view`; batch / assay pages show their
panels to holders of either the batch's view code or `module.quality.view`.

❓ **Q12 — Who records custody.** Q90 gives warehouse view only; the physical custodian of a sample is usually the warehouse.
➡️ **Add warehouse to `module.quality.edit`** if Fu Sheng handles samples (§11); otherwise keep Q90 and samples are recorded by cco / cto. Tim's fact.

❓ **Q13 — Who opens and resolves a dispute.**
➡️ **Open / withdraw: `module.quality.edit`. Resolve (name the governing assay): `action.apply_assay`** (cto, admin — today's owners of applying an assay,
whose choice the resolution pre-empts). `action.apply_assay`'s declared views gain `module.quality.view` (any-of, Q30 of MES-5b).

❓ **Q14 — V16 internal retention days.**
➡️ **One row `quality_settings.internal_retention_days`, edited under `module.quality.edit`, change-logged; arm only while empty and a retained sample
with no contract days exists.**

❓ **Q15 — Disposal before retain-until.**
➡️ **Allowed with a reason, flagged "disposed before retain-until"** (nothing refuses on a date nobody set by contract); reminder arm
`sample_retention_due` lists retained samples past retain-until and not disposed.

### C · Arbitration (6a-1)

❓ **Q16 — The dispute record.**
➡️ **`assay_disputes`: batch; our assay; counterparty assay (different parties, same batch); status open → resolved | withdrawn; opening reason; limit in
force (copied); umpire sample and umpire assay (optional); governing assay + note; fee expense; fee rule in force.** Per-metal differences are computed
(view), not stored. No document code (MES-0 Q53 gave none). Status moves only through functions; change-logged.

❓ **Q17 — The prompt.** Q62: prompt only where a splitting limit exists.
➡️ **Arm `assay_results_disagree`** (sell side only — the only side that can hold a limit): an output batch with an `ours` and a `counterparty` result
differing beyond the contract snapshot's limit and no dispute. **Buy side: no prompt; a person opens the dispute**, which reads "limit not set".

❓ **Q18 — Where the purchase-side hold sits.** Options: (A) `apply_assay_result` only; (B) the engine `reprice_inbound_batch` (also blocks manual and
committed-terms repricing); (C) where `final` is decided.
➡️ **A + C:** `apply_assay_result` refuses `ASSAY_DISPUTE_OPEN|<batch>|<dispute>` on a batch with an open dispute (and `preview_assay_price` the same, by
batch — fixture 40's parity); `receipt_price_post_internal` refuses posting an **assay-sourced** request while a dispute is open (catches a request
already waiting — the fingerprint carries no dispute state). Manual and committed-terms repricing stay possible: a provisional price is not "final
repricing" (Q62's words).

❓ **Q19 — What resolution does.**
➡️ **It names the governing assay and unblocks; it applies nothing.** The governing assay is then applied the normal way (`apply_assay_result` → CFO
request). No automatic rule (average, split the difference) — none was supplied, and inventing one would be a standard.

❓ **Q20 — D4: applying a non-`ours` result supersedes ours.**
➡️ **Fix in 6a-1:** `apply_assay_result` sets `superseded_by` only when the new assay has the **same party** as the prior applied one; applying an umpire
or counterparty result leaves ours readable. Fixture 118 gets the arm.

❓ **Q21 — Sell side.** `sale_settlement_compute` already refuses derived disagreements (`RESULTS_IN_DISPUTE`, `RESULTS_EXCEED_SPLITTING_LIMIT`).
➡️ **Also refuse `ASSAY_DISPUTE_OPEN` while a dispute record is open;** keep the derived refusals unchanged.

❓ **Q22 — The fee** (Q63 ruled: contract term V14; fee = expense; counterparty share = receivable or deduction).
➡️ **`contract_settlement_terms.arbitration_fee_rule`** (loser pays · equal · further-from-umpire pays · buyer · seller; nullable = V14) — sell contracts
only, so a buy-side dispute's rule always reads "Not yet set". **The fee is an ordinary unpaid expense to the lab's supplier, linked on the dispute;** the
counterparty's share is **computed for display only**. Collecting it (receivable / deduction) is not built — it waits on index-pricing §9 and the first
real dispute.

❓ **Q23 — Lab → supplier** (Q64; Tim's ruling at `laboratories.sql:28-31`: "那一行字典指向一个 supplier").
➡️ **`laboratories.supplier_id` (nullable FK → suppliers), set in the dictionary editor under `module.materials.edit`.** The fee expense pre-fills that
supplier; payment still needs it approved (`PAYMENT_REQUEST_SUPPLIER_BLOCKED`).

❓ **Q24 — "The buyer" on inbound assay trails.**
➡️ **Fix in 6a-1:** `assay_results.result_party` gets its own neutral labels (Ours · Counterparty · Umpire), pinned by arm ㉖.

❓ **Q25 — The stale comment `assay_results.sql:14-15`.**
➡️ **Correct it in 6a-1** (the cut touches the file).

### D · F and Cl (6a-2)

❓ **Q26 — `substances.role` and its default.** A default `payable_metal` would make every future row payable silently; fixtures 116, 119, 244 insert
without a role.
➡️ **NOT NULL, no default; values `payable_metal` · `penalty_element` · `other` (Q69).** Existing 7 rows → `payable_metal`; the dictionary editor gains the
choice; the three fixtures name a role.

❓ **Q27 — Where the role filters, and fixture 119.**
➡️ **Payable only:** the 4 metal-price pages, calculator, formula payables, contract pricing terms, refining charges — and the server side refuses a
non-payable by name (`SUBSTANCE_NOT_PAYABLE`) in `upsert_metal_prices`, `calculate_metal_price_from_terms`, the formula / commitment writers.
**Penalty element only:** contract penalty elements. **Any role:** assay entry, batch content, required metals, PO expected assay, grade specs, blending
targets. **Fixture 119 rewritten:** a new payable substance passes every path; a penalty element is refused on price paths and accepted everywhere else.

❓ **Q28 — Readers that would break on an F row.**
➡️ **Payable computations iterate `payable_metal` only:** `sale_settlement_compute`'s payable loop, `price_output_sale`, `calculate_metal_price_from_terms`
(via apply), `processing_metal_recovery_all`, `allocate_processing_costs`. Penalty elements are read by the penalty loop only. A fixture arm puts an F row
on a sale assay and an output batch and asserts settlement and the quote still compute.

❓ **Q29 — ppm** (Q69: shown in ppm for penalty elements).
➡️ **Stored and entered in %; shown in ppm beside % for penalty elements** (assay pages, batch content panel, penalty terms' threshold); the content panel
stops rounding them to 2 decimals. The penalty **rate** stays "USD per tonne per percentage point over" (a contract term's unit) with its ppm equivalent
shown — changing the unit would rewrite a contract term.

❓ **Q30 — Labels.**
➡️ **`toOptions` uses the dictionary's own names** (`name_en` / `name_zh` by locale), as its comment already claims; the 7 `metals.*` keys stay for the
pages that use them. Every future substance then labels itself.

❓ **Q31 — The two rows.**
➡️ **`f` Fluorine / 氟 (F) and `cl` Chlorine / 氯 (Cl), role `penalty_element`, sort order 8 and 9** (below fixture 116's 99), seeded on live and in the
bootstrap.

❓ **Q32 — V15, F / Cl penalty thresholds.**
➡️ **No pending-value arm:** it is a per-contract term, refused by name at settlement (`PENALTY_ELEMENTS_NOT_FILED`) when a contract declares
`per_element`; with 0 contracts an arm would have nothing to list.

### E · F3 — every expense reversal requires a reason

❓ **Q33 — Scope and order.**
➡️ **Both entry points** (`reverse_expense`, `reverse_electricity_allocation`); claims inherit (they reverse through the generated expense). The reason is
checked **first after the permission** in `reverse_expense` (the electricity and freight order), refusing `EXPENSE_REVERSAL_REASON_REQUIRED|<code>` on
NULL or blank; `reverse_expense_internal` refuses a blank too, so no future entry point can skip it. Other documents' reversals already require reasons
(§10.10) — unchanged.

❓ **Q34 — Where the reason lives.** Options: (a) on the original row (`reversal_reason`, `reversed_at`, `reversed_by` — the `freight_documents`
precedent), guard extended to admit them only in the posted → reversed transition, CHECK reason not blank when reversed; (b) a new append-only
`expense_reversals` table; (c) the mirror's `notes` (today's channel: machine prefix and human text in one column — the AT1D1 shape).
➡️ **(a).** One row, one transition; the trail shows it on the expense and on the claim subjects (which lack the mirror); the mirror's notes go back to
`REVERSAL: <code>` only. Electricity passes its own reason (no prefix) — the allocation keeps its copy on `electricity_allocation_reversals`.

❓ **Q35 — Masking the reason.** A reason on a medical-claim expense is readable by every `module.finance.view` holder (the U1B family).
➡️ **No masking** (expenses are unmasked by decision 1; masking one column means a masked view over `expenses`); the reason box carries a hint not to
write health details. Registered in `docs/known-issues.md` beside `U1B-EXPENSE-CLAIM-DESCRIPTION-IN-EXPENSE-NOTES`.

❓ **Q36 — Signature and window.**
➡️ **Keep `reverse_expense(p_expense_id uuid, p_memo text DEFAULT NULL)`** (CREATE OR REPLACE cannot rename the parameter; fixture 214 pins it); the page
sends `p_memo` as the reason; NULL / blank is refused by name. In the window the old page is refused by name — accepted (0 reversals ever on live).

❓ **Q37 — The page.**
➡️ **`ConfirmButton reason={{ placeholder }}`** on `ReverseExpenseButton` (blank disables confirm; server independent); `blocked` / `consequence` logic
unchanged; the banner reads the reason from the original row; the mirror's "Memo" line no longer prints machine text. New code into
`expenseErrorCodes.ts` with en / zh sentences.

### F · Governance

❓ **Q38 — Approvals.**
➡️ **None new** (§5). Approvals ON / finance / cfo / 1,000 unchanged.

❓ **Q39 — Trails.**
➡️ **New subjects `sample` and `assay_dispute`, both also members of the batch subjects; the expense reversal reason on the expense and claim trails;
wording arms ㉖ (6a-1) and ㉗ (6a-2) with their own faults.**

❓ **Q40 — Change log and masking.**
➡️ **Every new table bound; exclusions stay 8; no new masked column** (§5).

❓ **Q41 — Registries.**
➡️ **`SMP` only** (gapless, yearly, width 4 like its siblings — `CODE-WIDTH-4` stays its own item): fixture 100 56 → 57, 101, 254, search registry 56 → 57,
document registry. Disputes carry no code.

❓ **Q42 — Pending values.**
➡️ **V16 and V14 with their arms and `docs/mes-pending-values.md` rows in the same commit (6a-1); V15 none; V17 deferred** (§6).

### G · Migration, fixtures, records

❓ **Q43 — Migration and window.**
➡️ **Accept §8:** one migration per cut; the only break is the old expense page refused by name for the length of 6a-1's window; no back-fill.

❓ **Q44 — Fixtures.**
➡️ **New 260 (samples, custody, disputes, the hold A + C, D4, settlement refusal, F3) and 261 (roles, F / Cl through pricing and settlement, indicators);
changed without weakening: 40, 118, 149, 220, 256, 258, 100, 101, 254 (6a-1); 116, 119, 244 (6a-2).** Every new arm fault-injected; the injection run repeated
after the last edit, before the push.

❓ **Q45 — Stale records found (§10).**
➡️ **Correct each in the cut that touches its file:** `assay_results.sql:14-15` and the `forward-queue.md:642` note in 6a-1; `substanceQuery.ts:16-19` in
6a-2; the MES-0 counts and line references left as history with a note in this file; U12's two lines (`forward-queue.md:2055/2063`) reconciled when 6a-1
records the buy-side "limit not set".

## §13 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q45.
