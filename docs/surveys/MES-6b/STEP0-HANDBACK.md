# MES-6b Step 0 — hand-back (2026-10-15), with the MES-6a-2 close-out rulings

**STOP GATE.** No code edit, no migration, no live write. The only writes are docs:
- the close-out rulings (`cffc44dc`, "MES-6a-2 close-out rulings": the penalty-picker render in `MES-6a-2-CLOSEOUT.md` §3a; F7 and F8 under MES-6b in
  `docs/forward-queue.md`);
- this file and the read-only query file beside it (`live-readings.sql`).

Waiting on Tim's answers to Q1–Q42 (§12).

**Opening check.** First command **2026-10-15 00:02:00 CST**. Tree clean. `HEAD` = `origin/main` = `git ls-remote origin main` =
`d32a2f01df37f4cd39386345a42de5b50bc84f6a`; after the rulings commit `cffc44dc19483b76c229788f0f2119cb80ca6d35`. Files staged by explicit path only.

**Live readings (measured, read-only).** `live-readings.sql` at **00:13:03 CST**, as `postgres` (`rolbypassrls = true`) over direct psql to the pooler,
inside `BEGIN READ ONLY … ROLLBACK`, base tables and the catalog; `READ_OWN_EXIT=0`:

| Reading | Value |
|---|---|
| Inbound batches (not deleted) | **15**, of which **1** has `chemistry_certainty_code` |
| Output batches (not deleted) | **14**; 4 carry metal content — **all `manual`** (6 rows) |
| Assays | **4**, **0 on output batches**, 0 with moisture, 0 indicator values; samples 0 · disputes 0 |
| Holds today | `on_hold` ledger rows **2** · `committed` rows 6 · reservations **3** · quarantine locations **0** · open warehouse requests 0 |
| Contracts | **0** · grade specs 0 · sales orders 6 · sales settlements 0 |
| Certificates | CODs 3 (2 issued) · traceability report issues 1 |
| Registries | document types **57** (no NCR / COA) · public tables 292 · catalogue 77 (no `action.ncr_decide` / `action.issue_coa`) · `pending_values` 22 arms |
| Standing state | approvals **ON** (finance / cfo / 1,000) · 7 accounts, 0 disabled, 0 throwaway · `require_calibrated_since` NULL · admin 77 |

**How the facts were gathered.** Seven read-only sub-agents in the previous block (none connected to a database or ran a build): `docs/known-issues.md`
in full; `docs/forward-queue.md` in full; holds / V17 code paths; CoA precedents and N38; F4–F6 code paths; the MES-6a-2 fixture map (F8); measured
active times of MES-1 … MES-6a-2 and HOTFIX-6A2 from the session transcripts. I read in full: AGENTS.md, the specification PDF (11 pages), MES-0
README, MES-6a Step 0, the MES-6a-1 and MES-6a-2 hand-backs, `docs/mes-pending-values.md`, `docs/role-matrix.md`, the known-issues MES-6a sections.
Load-bearing claims were re-read at file:line (spot-checked today: `scripts/check-trail-wording.mjs:5885,5981,6116,6320`;
`app/inbound/[id]/assays/new/AssayForm.tsx:197-207`; `app/contracts/[id]/page.tsx:94`; `db/tables/warehouse_requests.sql:47`;
`db/tables/inventory_movements.sql:22-27,78-79`; F262 `:209,:271,:394,:428,:477`).

Tags: **[M]** measured · **[I]** inferred from code reading · **[Q]** quoted from an earlier record · **[S]** from the specification · **[R]** a Tim ruling on record.

---

## §0 · The penalty-element picker (the close-out ruling) ✓

Rendered on a local rebuild of HEAD with a draft sell contract of my own (`CON-2026-0003`, F 0.005 % and Cl 0.0025 % penalty rows), the page HEAD's own
at `/contracts/[id]`, sessions as clones of **cco** and **admin** [M]: the penalty-element "add" form's substance picker offers **`f` = Fluorine and
`cl` = Chlorine only** — no payable metal; the pricing-term and refining-charge pickers offer the seven payable metals and no F / Cl; thresholds and
rates read `0.005% (50 ppm)` · `1000 per % (0.1 per ppm)` · `0.0025% (25 ppm)` · `425.5 per % (0.04255 per ppm)`; the rebuild's own guard refuses
`cu` as a penalty element (`SUBSTANCE_NOT_PENALTY_ELEMENT|cu`). Live read back afterwards: 0 throwaway accounts, 0 probe roles, 7 accounts enabled.
Details: `MES-6a-2-CLOSEOUT.md` §3a. **No fold-in needed.**

## §1 · What grilling changed in MES-6b's scope

1. **Two cuts, not one** [M + I]. MES-0 sized MES-6b at 6 h 25 – 11 h 30 before V17, N38 and F4–F8 were added; with them it is two proof shapes —
   *a gate on stock movement* (the hold, NCR, V17 judgement, plus F4 / F5 on the settlement path) and *an issued external document* (the CoA, N38,
   a CFO void request). One cut estimates at ≈ 6 h 00 – 9 h 05 calibrated, far beyond the largest measured MES cut (6a-1, 3 h 55 active). Q1.
2. **The quality hold cannot be `hold_stock`** [I]. The `on_hold` bucket holds only *available* stock (`hold_stock.sql:29-31`); there is no
   `on_hold ↔ committed` edge (`inventory_movements.sql:52-61`) and `ship_order` takes from `committed` (`ship_order.sql:221-226`) — so reserved goods
   ship straight past it. Its reason lives only in `inventory_movements.notes`; there is no hold entity to list or close. `output_batch_purposes.sql:37-39`
   already says G29 must be its **own axis**. Q2.
3. **The single choke point exists** [I]: a BEFORE INSERT trigger on `inventory_movements` (the warehouse-request freeze, `guard_warehouse_request_freeze.sql:14-45`)
   catches every ledger writer, DEFINER functions included. A hold enforced there needs no edit in the dozen functions that move stock. Q3.
4. **V17 can only be judged where a contract meets a batch** [M + I]. Limits are per contract (MES-6a Q5 [R]); an output batch meets a sell contract only
   through a reservation on a sales order linked to it. Live: 0 contracts, 0 output assays — nothing could be judged today, and nothing will be until both
   exist. `contract_grade_specs.metal` is an FK to `substances`, so moisture and indicators cannot be expressed there (`contract_grade_specs.sql:33-60`). Q10–Q14.
5. **The CoA must read the governing assay, not the batch content** [I]. `apply_output_assay` replaces all of a batch's content with whichever party's result
   was applied last (`apply_output_assay.sql:39-44`, while superseding only within a party `:49-57`), and `unapply_assay_result` leaves rows saying
   `content_source = 'assay'` for an assay no longer applied (`unapply_assay_result.sql:58-60`). Q17.
6. **N38 is computable from lineage today** [I + M]: walk `batch_lineage_all` to the inbound leaves and take the weakest `chemistry_certainty_code`.
   Live: **1 of 15** inbound batches has one, so almost every CoA would say "not recorded" — honest, and the reason to state it. Q18.
7. **The COD precedent renders its PDF from live data, not from its frozen snapshot** [I]: `app/inbound/[id]/cod/pdf/route.tsx:149-150` says "the frozen one"
   while `cod_certificate_data` re-assembles from live tables (`cod_certificate_data.sql:23-32,55-57`). The CoA must render from its snapshot; the COD
   discrepancy is a finding to register (Q41).
8. **There is no mail service** (`app/settings/accounts/accountActions.ts:7-9`, `package.json`) and MES-0 ruled no public verify page for the CoA (Q96 [R]) —
   sharing is a download. Q22.
9. **F4 has two traps the brief did not name** [I]: a contract that penalises a payable metal *without* pricing it fails settlement with
   `SETTLEMENT_PAYABLE_NOT_STATED|cu` (payable loop `sale_settlement_compute.sql:217-233`; a 0 % pricing term is impossible, `contract_pricing_terms.sql:54`);
   and a substance both priced and penalised is paid **and** penalised with nothing stopping it (pre-MES-6a-2 fixture 149 was exactly that). Q25–Q28.
10. **F5 has a silent twin on the output side** [I]: a penalty-only *output* assay **applies** and wipes the batch's payable content (`apply_output_assay.sql:39-44`),
    after which the sale quote raises `NO_METAL_CONTENT` and metal-value cost allocation `NO_METAL_VALUE`. Q29–Q30.
11. **F6 is not a one-line fix** [I]: every one of the 22 ㉓–㉖ samples produces a null part, so switching the reader to `titlePart` stays green and a part-only
    fault cannot bite without a sample that has a part. Q31.
12. **Inbound grade breaches stay a report in this cut** [Q + I]: CONTRACT-1 ③ makes G29 the *trigger* for turning them into a gate (`known-issues.md:6518-6534`),
    but `contract_grade_breaches` ignores the spec's `material_id` and the result's party (`contract_grade_breaches.sql:42-54`) — gating on it would gate on a
    known-wrong judgement. Q6.

## §2 · (a) What MES-6b is, and its exact contents

**MES-0 §8.2 row MES-6b** [Q, `docs/surveys/MES-0/README.md:704`]: functions **17 NCR · 18 CoA**; "`nonconformance_reports`, `certificates_of_analysis`,
`coa_issues`; hold linked to NCR; CoA PDF, archive, void request"; 3.5 tables / 4 pages; extras "PDF + archive + CFO void chain: 1.5–2.5 h"; estimate
6 h 25 – 11 h 30. Rulings on record [R, all of MES-0 Q1–Q96 accepted, `:1141`]: **Q53** `NCR-`, `COA-` · **Q65** NCR sources (grade breach, inspection,
customer complaint, manual) and dispositions (accept, accept with penalty, reject, rework, downgrade), new `action.ncr_decide` (cco, cto, admin) ·
**Q66** "an open NCR puts the batch on hold …; disposition releases it" · **Q67** CoA per output batch, from the final governing result; frozen snapshot,
sha256 archive, English; new `action.issue_coa` (cco, admin); void through a CFO request like the COD; no public verify page · **Q68** preconditions: a
final result exists; no open NCR or hold; instruments behind inline readings were in calibration · **Q89** one new CFO request (CoA void) · **Q96** the
verification domain stays its own pre-production item. Folded in since: **V17** and **N38** (MES-6a Step 0 Q5 · Q6, Tim 2026-10-09,
`docs/forward-queue.md:7331`); **F7 · F8** (Tim, 2026-10-15); **F4 · F5 · F6** (proposed in this brief, for Tim to confirm).

**Proposed contents, by recommended cut (Q1):**

**MES-6b-1 · Quality hold, NCR, V17 (+ F4, F5, F7, F8)**
- **Tables:** `nonconformance_reports` (`NCR-YYYY-NNNN`, gapless yearly; inbound XOR output batch; source `manual` · `quality_limit` · `customer_complaint`;
  opened at / by; description; status `open` → `decided`; disposition `accept` · `accept_with_penalty` · `reject` · `rework` · `downgrade`; decided at / by;
  decision note; optional links: assay, dispute, sales order, judgement) · `contract_quality_limits` (sell contracts; optional material; parameter
  `moisture_pct` or an `assay_indicators` code; min and / or max) · `quality_limit_judgements` (append-only: batch · contract · sales-order line ·
  parameter · assay · value · `limit_min_at` / `limit_max_at` copied · result).
- **Columns:** `contract_settlement_terms.quality_limit_basis` (`none_agreed` · `per_parameter`; NULL = V17 "Not yet set").
- **Functions:** `open_ncr`, `decide_ncr`, `next_ncr_code`; `batch_quality_hold(batch)` + `guard_quality_hold` (BEFORE INSERT on `inventory_movements`:
  refuses `QUALITY_HOLD_OPEN|<batch>|<ncr>` on `processing_consume`, `sale`, the shipment leg and `status_change_*` into `committed`);
  `record_sale_settlement` and `create_blending_plan` / `amend_blending_plan` / `release_blending_plan` refuse a held batch; `judge_quality_limits(batch)`
  called from `record_assay_result` (output side) and `reserve_stock_internal`, writing judgements and opening a `quality_limit` NCR on a breach;
  `link_document_to_contract` copies the limits into `contract_document_terms`; `contract_activation_missing` asks for `quality_limit_basis` on sell
  contracts. F4: `guard_substance_role` takes a role set; the payable loop skips penalty-listed substances. F5: `apply_assay_result` / `apply_output_assay`.
- **Codes:** `action.ncr_decide` (cco · cto · admin; declares `module.quality.view`). Opening an NCR = `module.quality.edit`.
- **Pages:** `/quality/ncr` (list), `/quality/ncr/new` (batch first, the MES-6a-1 two-step precedent), `/quality/ncr/[id]` (record, hold, judgement,
  disposition, trail); a hold banner on both batch pages and the sales-order page; the contract page's new "Quality limits" section; the F7 ppm readout
  on both assay forms.
- **Arms:** `ncr_open`, `quality_hold_reserved` (held batch with a reservation), pending value **V17**.

**MES-6b-2 · Certificate of analysis, N38 (+ F6)**
- **Tables:** `certificates_of_analysis` (`COA-YYYY-NNNN`; output batch; governing assay; status `issued` → `void`; issued at / by; `snapshot jsonb`;
  `replaced_by_coa_id`; void reason / at / by) · `coa_issues` (bytes path + sha256, append-only).
- **Functions:** `coa_certificate_data(batch)` (assembles; refuses by name), `issue_coa` (preconditions Q19, freezes the snapshot, mints the number),
  `record_coa_issue`, `next_coa_code`; `output_batch_chemistry_certainty` (N38, over `batch_lineage_all`); `warehouse_requests` kind `coa_void` +
  `submit_coa_void_request` + its execution (CFO, level 2, fixed — the COD shape).
- **Codes:** `action.issue_coa` (cco · admin; declares `module.output.view`, `module.quality.view`).
- **Pages:** `/output/[id]/coa/pdf` (GET preview, GET `?coa=` stored bytes with sha256 check, POST issue); a CoA panel on `/output/[id]/edit`;
  `/quality/coa` (list). Chemistry certainty shown on the output batch page.
- **Arms:** `coa_facts_changed` (an issued CoA whose batch has a newer assay or an NCR since).

**Left to later cuts** [Q / I]: NCRs from inspections (MES-7b); G22, the right to reject at receipt (`forward-queue.md:2187-2191`, unruled); inbound grade
breaches as a gate (CONTRACT-1 ③ — after `contract_grade_breaches` is corrected, Q6); purchase-side penalty money (index-pricing §9, unanswered);
the CoA public verify page and its domain (Q96); emailing documents (no mail service); NCRs on supplier scorecards (MES-8a); the inline-quality
transform (no payload format, MES-6a Q2); a material re-grade function for `downgrade` (none exists).

## §3 · (b) The quality hold

| Question | Recommended answer | Evidence |
|---|---|---|
| What places it | an **open NCR** — opened by a person (`manual`, `customer_complaint`) or by the system on a **V17 breach** (`quality_limit`). A failed contamination check (V11) or an inbound grade breach **prompts** (arm), it does not hold | Q66 [R]; V11/V36/V9 flag-never-refuse rule (`contamination_checks.sql:30-33`); Q6 |
| What it blocks | processing input (incl. blending execution), direct sale, **reservation**, **shipment** (committed stock too), sale settlement, adding / releasing a held batch in a blending plan, issuing a CoA (6b-2) | ledger trigger precedent `inventory_movements.sql:155-160`; `ship_order.sql:221-226`; `record_sale_settlement.sql:23-26` |
| What it leaves alone | transfers (move it to quarantine if wanted), stocktake adjustments, inventory `hold_stock` / `release_stock`, releasing a reservation, write-off **through the CFO request**, recording and applying assays, pricing | `create_stock_transfer_internal.sql:77-86`; `warehouse_request_execute_internal.sql:37-41` |
| Who places / releases | open: `module.quality.edit` (admin · cco · cto); decide (releases unless the disposition is `reject`): `action.ncr_decide` (cco · cto · admin), never the opener | Q65 [R]; four-eyes-by-person precedent `release_blending_plan.sql:26` |
| vs MES-3a quarantine | independent: quarantine is a *location rule* from safety states (fire), refuses landings only; a quality hold moves nothing | `assert_quarantine_landing.sql:13-36`; `batch_quarantine_states.sql:2-4` |
| vs MES-6a-1 dispute | independent: a dispute holds *pricing and settlement* (`ASSAY_DISPUTE_OPEN`, four sites) and not movement; an NCR may cite a dispute; resolving one never releases the other | `sale_settlement_compute.sql:146-154`; `apply_assay_result.sql:51-58` |
| vs STK-1 `on_hold` | unchanged; an inventory action (how many tonnes set aside), not a quality conclusion | `forward-queue.md:2137-2144` [Q] |

## §4 · (c) V17 — limits, home, judgement

- **Expressed:** per **sell contract** (Q5 [R]), optionally per material, per parameter — `moisture_pct` (the assay's own column) or any
  `assay_indicators` code (residual powder, foil purity, D10 / D50 / D90), with a min and / or a max. The table is generic; the pending value is V17
  "moisture and particle-size acceptance limits".
- **Lives:** `contract_quality_limits` (a sibling of `contract_grade_specs`, written under `action.contract_terms`, frozen with the contract, snapshot into
  `contract_document_terms.quality_limits` at link — `link_document_to_contract.sql:101-106` precedent) plus `quality_limit_basis` on the settlement
  terms ("declared none" ≠ "not declared", SETTLE-1 ③ [Q] `known-issues.md:6646-6669`).
- **Judged:** when an output batch with an assay meets a reservation on a sales order linked to such a contract — at `record_assay_result` (output side)
  and at `reserve_stock_internal`. The assay judged is the **contract's settling party's** latest live result (or the dispute's governing assay once
  resolved) — the settlement rule (`sale_settlement_compute.sql:166-170`). Each judgement row copies the limit in force (V36 / V11 / V9 precedent:
  `processing_run_values.range_min_at`, `contamination_checks.warning_pct_at`, `discharge_module_results.pass_voltage_v_at`); result `within` ·
  `below_min` · `above_max` · `not_measured` (NULL is never zero, C3 `known-issues.md:5158-5209`). A breach opens a `quality_limit` NCR (→ hold).

## §5 · (d) The certificate of analysis

| Item | Recommended | Evidence |
|---|---|---|
| Subject | one output batch; optionally names the sales order it accompanies | Q67 [R]; `shipment_lines.output_batch_id` `shipment_lines.sql:25` |
| Assay stated | the governing result: the dispute's `governing_assay_id` if resolved, else the latest live `is_final` result of party `ours` (or the contract's settling party when a sales order is named); its **own lines** (`assay_result_metals`), not batch content | `resolve_assay_dispute.sql:19-38`; §1.5 |
| Content | company · batch code, material, quantity, output date · laboratory name, certificate ref, assay date, party, weight basis, moisture · every substance with % (ppm beside penalty elements) · the five indicators if recorded · V17 limits and judgement when a sales order is named · **N38 chemistry certainty** of the feed · issuer and issue time | spec §4.2 [S] "statement of feedstock composition"; `lib/substances.ts` |
| N38 | weakest of the inbound leaves' `chemistry_certainty_code` via `batch_lineage_all`: `single_known` · `mixed` · `not recorded` · `unknown_pending`; plus content provenance (measured by the stated assay) | `known-issues.md:4468-4484` [Q]; `inbound_chemistry_certainties.sql:48-55` |
| When | the stated assay exists and `is_final`; no open NCR (no hold); no open dispute; the output legs' weighings in calibration (`weighing_calibration_all`, the MES-2 gate; no inline readings exist) | Q68 [R]; `commit_processing_run.sql:306-307,353-360` |
| Numbering | `COA-YYYY-NNNN`, gapless yearly, width `GREATEST(4, length(n))` (CODE-WIDTH-4) | Q53 [R]; `known-issues.md:3327-3382` |
| Signing | "Issued by <name>, <position>" and the issue time; no image signature | Q21 (open) |
| Sharing | PDF download from the batch page; no email, no public link | §1.8; Q96 [R] |
| Void | CFO request (`warehouse_requests` kind `coa_void`, level 2, fixed); a replacement is a new number with `replaced_by_coa_id`; never voided automatically | Q67 / §4.1 [R]; APR7 anti-pattern `known-issues.md:173-180` |

## §6 · (e) F4–F8: today's code paths, effects, fixtures

- **F4** — `guard_substance_role('penalty_element','substance')` on `contract_penalty_elements` (`contract_penalty_elements.sql:83-85`;
  `guard_substance_role.sql:26-32`, one role only); picker `penaltyOnly` (`app/contracts/[id]/page.tsx:94`); CSD pins it (`check-substance-display.mjs:70,150`).
  Settlement: payable loop over `payable_metal` rows of the assay (`sale_settlement_compute.sql:217-272`) and an independent penalty loop with no role
  filter (`:275-300`) → a substance in both is paid **and** penalised; a penalised payable metal with no pricing term raises `SETTLEMENT_PAYABLE_NOT_STATED`
  (`:227-233`). The sale quote never reads contracts (`price_output_sale.sql` — no "contract") → unchanged. Fixtures to change: 119 F2P `:235-242`,
  262 PEN `:208-218`, INJ `:112-115,186-187`, CSD `:70,71,150`; new arms in 149 (penalised-not-priced; priced-and-penalised refused).
- **F5** — `apply_assay_result` deletes all content and copies the assay (`apply_assay_result.sql:75-83`), prices `payable_metals_only(…)` → `'[]'` →
  `NO_METALS` (`calculate_metal_price_from_terms.sql:80-82`), whole apply rolls back; with no commitment it **succeeds and wipes** the payable content
  (`:132-145`). Output: no pricing, so a penalty-only output assay applies and wipes (`apply_output_assay.sql:39-44`). Fixture 54E `:386-391` pins
  "an assay is a complete statement" for payable content. No fixture pins the penalty-only case today.
- **F6** — `check-trail-wording.mjs:5885,5981,6116,6320` read `e.part` (absent); `lib/trail/render.ts:67,5316` set `titlePart`; 22 pinned nulls
  (㉓ 3 · ㉔ 3 · ㉕ 6 · ㉖ 10); every sample's `titlePart` is null on the paths traced; faults `wording-drift-mes5b1/5b2/5b3/6a1` drift labels, none a part.
- **F7** — the content cell is a bare `DecimalInput` (`AssayForm.tsx:197-207`; `OutputAssayForm.tsx:136-139`); rows carry the substance's role
  (`SubstanceOption.role`, `lib/substances.ts`); measured on the deployed app: no ppm before or after entering 0.0123 (close-out §2 c).
- **F8** — no INJ cell for the engine's terms-side check (`calculate_metal_price_from_terms.sql:66-71`) or the formula-change path (F262 `:181-182`);
  "exclusions = 8" asserted (F262 `:477`, 235 `:134`) but never injected; F262 IND records 2 of 5 on the output path (`:421-433`); 119 F1 has no cell.

## §7 · (f) Effect on existing pages, functions and fixtures

- **Functions changed (6b-1):** `record_assay_result` (calls the judgement for output batches), `reserve_stock_internal`, `record_sale_settlement`,
  `create_blending_plan` / `amend_blending_plan` / `release_blending_plan` (via `blending_plan_write_children`), `link_document_to_contract`
  (snapshot), `contract_activation_missing`, `contract_terms_state`, `guard_substance_role` (F4), `sale_settlement_compute` (F4), `apply_assay_result` /
  `apply_output_assay` / `preview_apply_output_assay` (F5), `pending_values`, `operations_now`, `trail_subjects` / `trail_subject_members`. New trigger on
  `inventory_movements` (a second BEFORE INSERT beside the freeze). **All CREATE OR REPLACE with the same signature** — no DROP needed.
- **Functions changed (6b-2):** `warehouse_requests` CHECK (+ `coa_void`, + `coa_id`), `warehouse_request_submit_internal` / `decide_warehouse_request` /
  `warehouse_request_execute_internal` / `warehouse_request_snapshot`, `approval_chain_gates`, `operations_now`, trail registrations.
- **Pages:** both batch pages (hold banner; 6b-2 CoA panel and certainty), both assay forms (F7), `/contracts/[id]` (quality-limits section, termSpecs),
  `/sales/orders/[id]` (hold banner on reserved lines), `/tools/reminders`, `/settings/pending-values`, Operation › Quality nav (NCR; CoA).
- **Fixtures:** new 263 (6b-1: NCR · HOLD on every blocked path and every allowed path · V17 judgement · AUTO NCR · F4 · F5) and 264 (6b-2: CoA · N38 ·
  VOID); changed without weakening: 100 · 101 · 254 · search / document registries (57 → 58 → 59: NCR, COA), 111 (arms), 30 (arm list), 235 / 234
  (new tables bound, exclusions stay 8), 119 · 262 (F4), 149 (F4 arms), 54 (F5 arm beside 54E), 262 IND (F8), 257 (two new action codes declared),
  `check-substance-display` (F4, F7), `check-trail-wording` (F6; arms ㉘ and ㉙).

## §8 · (g) Approvals, trails, change log, masking

- **Approvals:** one new CFO request — **CoA void** (MES-0 Q89 [R]), level 2, fixed, the COD shape; the raiser never decides (by person). An NCR
  disposition is a quality decision, not an approval (money travels through existing approved documents: receipt price request, credit note,
  write-off request). Holds have no approval. Approvals ON / finance / cfo / 1,000 unchanged.
- **Trails:** new subjects `ncr` and `coa`, both also members of the batch subjects; contract quality limits under the `contract` subject; judgements
  under the batch subject; wording arms ㉘ (6b-1) and ㉙ (6b-2), each with its own fault, reading `titlePart`.
- **Change log:** every new table bound (`gen_change_log_bindings.py --only`); exclusions stay 8.
- **Masking:** none new — NCRs, holds, limits and CoAs carry no money (the CoA states no price; decision 1 leaves the fee side to finance). The CoA
  snapshot names the customer only when a sales order is named (display label follows the document, decision 3).

## §9 · (h) "Not yet set" values MES-6b adds

| # | value | lives on | page | arm reads | permission | supplied by | when |
|---|---|---|---|---|---|---|---|
| V17 | Moisture and particle-size (and any indicator) acceptance limits, per sell contract | `contract_settlement_terms.quality_limit_basis` + `contract_quality_limits` | `/contracts/[id]` | each live sell contract **with at least one linked sales order** whose `quality_limit_basis` is NULL (V9 precedent: no rows nobody can act on) | `module.customers.view` | Tim / the offtake contract | the first offtake contract |

No other numeric standard is introduced: the hold, NCR and CoA need none (Q37). Live: 0 contracts → the arm is empty on day one.

## §10 · (i) Migration shape and broken window

- **Shape:** one migration per cut, dated from `date`; built from the mirrors; COMMIT → ROLLBACK dry run on live before the real apply.
- **6b-1 window (old app + new DB):** the hold bites only where an open NCR exists, and the old app cannot open one → nothing breaks. The judgement
  runs inside `record_assay_result` / `reserve_stock_internal` and needs a contract with limits → none live. F4 loosens a guard (old picker still
  offers F / Cl only). F5 changes apply for penalty-only assays only (none live). `contract_activation_missing` asking for `quality_limit_basis` would
  refuse activation from the old contract page (it cannot set the column) — 0 contracts live. **Window ≈ deploy time, nothing used breaks.**
- **6b-2 window:** new tables and a widened CHECK; the old app reads neither. Nothing breaks.
- **Existing records:** none changed. 0 contracts, 0 output assays, 3 reservations (unaffected: no NCR), 2 `on_hold` rows (unaffected), 3 CODs untouched.
  No back-fill.

## §11 · (j) Time estimate — two numbers, measured calibration

**Measured** [M, transcripts; active = brief → push, gaps ≥ 10 min excluded unless ending in a tool result; split floor / work by tool-call class, ±5–10 min]:

| cut | active | floor | work | Step-0 est. low | active ÷ low | work ÷ est. work low |
|---|---|---|---|---|---|---|
| MES-1 | 2h42 | 1h24 | 1h17 | 4h20 | 0.62 | 0.43 |
| MES-2 | 2h46 | 1h02 | 1h44 | 2h35 | 1.08 | 1.16 |
| MES-3a | 2h47 | 1h01 | 1h46 | 2h50 | 0.99 | 1.01 |
| MES-3b | 2h09 | 0h41 | 1h27 | 2h50 | 0.76 | 0.76 |
| MES-4a | 3h38 | 1h59 | 1h38 | 3h40 | 0.99 | 0.64 |
| MES-4b | 3h26 | 1h45 | 1h40 | 3h20 | 1.03 | 0.74 |
| MES-5a-1 | 2h10 | 1h00 | 1h10 | 3h30 | 0.62 | 0.57 |
| MES-5a-2 | 2h39 | 1h12 | 1h26 | 3h00 | 0.89 | 0.87 |
| MES-5b-1 | 3h05 | 1h22 | 1h43 | 4h05 | 0.76 | 0.57 |
| MES-5b-2 | 2h23 | 1h28 | 0h54 | 3h35 | 0.67 | 0.37 |
| MES-5b-3 | 2h09 | 1h14 | 0h54 | 3h40 | 0.59 | 0.35 |
| MES-6a-1 | 3h55 | 2h02 | 1h53 | 5h15 | 0.75 | 0.47 |
| MES-6a-2 | 3h45 | 2h18 | 1h26 | 3h25 | 1.10 | 0.66 |
| HOTFIX-6A2 | 0h12 | ≈0h06 | ≈0h05 | — | — | — |

Medians: active ÷ estimate low **0.76** (all) / 0.75 (last five); work ÷ estimated work low **0.64** (all) / **0.47** (last five, range 0.35–0.66).
Floor components, median minutes (all / last five): backup 13 / **24** · full gate 11 / 13 · smoke 24 / 26 · layout survey 11 / 11 · apply 6 / 6 ·
offline gate 4 / 4 · build 6 / 6 · live proof 2 / 5 → total 82 / **88**; the last two cuts' floors were 2 h 02 and 2 h 18 (each lost one first backup;
6a-2 ran four layout passes). **Fresh-clone build (new since HOTFIX-6A2): measured 106 s and 113 s** (HOTFIX-6A2: clone 1 s, `npm ci` 6 s warm,
`npm run build` 99 s; this block's close-out push 22:17:42 → 22:19:35 CST) — ≈ 2 min per cut. MES-6a's Step 0 low ends under-ran both 6a cuts' floors by
17–33 min: **floor used below 1 h 45 – 2 h 30** (the last two measured, plus the fresh-clone build, plus one rerun at the top).

**Work, per cut (estimated low – high, minutes):**

| part | 6b-1 | 6b-2 |
|---|---|---|
| orientation | 5 – 5 | 5 – 5 |
| database | NCR table + open / decide + `NCR-` registry 40 – 60 · hold guard on the ledger + settlement + blending + CoA hook 40 – 70 · V17 limits + basis + snapshot + judgement + auto-NCR 50 – 80 · F4 20 – 30 · F5 25 – 40 | CoA tables + data / issue / record + `COA-` registry 50 – 80 · N38 view 25 – 40 · void request (kind, submit, execute, snapshot, gates) 30 – 50 |
| pages | NCR list / new / detail, hold banners, contract quality section, F7 50 – 80 | PDF route + document + panel + list 60 – 90 |
| fixtures + injections | 45 – 70 (incl. F8 20 – 30 inside) | 40 – 60 (incl. F6 20 – 35 inside) |
| live proof | 10 – 15 | 10 – 15 |
| messages, docs, static | 20 – 30 | 15 – 25 |
| **work** | **5 h 05 – 8 h 00** | **3 h 55 – 6 h 05** |
| **calibrated work (× 0.47, last-five median)** | **≈ 2 h 25 – 3 h 45** | **≈ 1 h 50 – 2 h 50** |

**Estimates — process floor + work, two numbers per cut:**
- **MES-6b-1 Quality hold, NCR, V17 (+ F4, F5, F7, F8):** floor **1 h 45 – 2 h 30** + work **5 h 05 – 8 h 00** (calibrated **2 h 25 – 3 h 45**) =
  **6 h 50 – 10 h 30** raw; **≈ 4 h 10 – 6 h 15** calibrated. Above the largest measured MES cut (3 h 55) — the reason Q1 asks whether F4 / F5 ride here.
- **MES-6b-2 Certificate of analysis, N38 (+ F6):** floor **1 h 45 – 2 h 30** + work **3 h 55 – 6 h 05** (calibrated **1 h 50 – 2 h 50**) = **5 h 40 – 8 h 35**
  raw; **≈ 3 h 35 – 5 h 20** calibrated.
- **F4 + F5 alone** (if Q1 moves them out of 6b-1): work 45 – 70 min (calibrated ≈ 20 – 35); 6b-1 without them ≈ 3 h 50 – 5 h 40 calibrated.
- **One cut instead:** floor 1 h 45 – 2 h 30 + work 9 h 00 – 14 h 05 (calibrated 4 h 15 – 6 h 35) = **≈ 6 h 00 – 9 h 05 calibrated**.
- A close-out runs 12–15 min (50 min when it renders pages); a Step 0 proper 19–25 min.

---

## §12 · Every open question, with a recommended answer and its evidence

Grilling is a design tree. **Round 1** is the frontier — questions whose prerequisites are settled. **Round 2** questions depend on a round-1 answer;
each names it, and its recommendation assumes the round-1 recommendation. If Tim answers a round-1 question differently, the round-2 questions under
it are re-asked.

### Round 1

❓ **Q1** - **One cut or two, and where F4 / F5 ride**: As one cut MES-6b is ≈ 6 h 00 – 9 h 05 calibrated. It is two proof shapes — a gate on stock
movement (hold, NCR, V17) and an issued external document (CoA, N38, CFO void). F4 / F5 change the settlement and assay-apply paths, a third shape.

➡️ **Two cuts:** **MES-6b-1 Quality hold, NCR, V17** (+ F4, F5, F7, F8) ≈ 4 h 10 – 6 h 15 calibrated, then **MES-6b-2 Certificate of analysis, N38** (+ F6)
≈ 3 h 35 – 5 h 20. If Tim prefers cuts inside the measured range, move F4 + F5 into 6b-2 (6b-1 ≈ 3 h 50 – 5 h 40). The CoA comes second because it
must refuse a held batch (Q68 [R]).

❓ **Q2** - **What a quality hold is**: (a) the STK-1 `on_hold` bucket via `hold_stock` — cannot hold reserved stock, does not stop `ship_order`, reason only
in `notes` (`hold_stock.sql:29-31`, `ship_order.sql:221-226`); (b) a separate `quality_holds` table, NCRs referencing it; (c) **the hold is the open NCR
itself** — a batch is on hold while it has an NCR whose status is `open` (MES-0 Q66: "an open NCR puts the batch on hold … disposition releases it").

➡️ **(c).** One record, one release path, nothing to keep in step; a manual hold is opening an NCR with source `manual`. `output_batch_purposes.sql:37-39`
already asks for a separate axis; (c) is that axis without a second table. `hold_stock` stays the inventory action it is.

❓ **Q3** - **Where the hold is enforced**: (a) a check added to each function that moves stock (≈ 12 writers, §3 of the holds survey); (b) **one BEFORE INSERT
trigger on `inventory_movements`** beside the warehouse-request freeze (`inventory_movements.sql:155-160`), plus explicit checks in the few non-ledger
actions (sale settlement, blending plan create / amend / release, CoA issue).

➡️ **(b).** The ledger is the only door every movement passes, DEFINER functions included — the freeze's own reasoning ("one table, no side doors").
Blocked movement types: `processing_consume`, `sale`, the shipment leg, `status_change_out`/`_in` into `committed`. Allowed: `transfer_*`, `adjustment`,
`status_change_*` between `available` and `on_hold` and from `committed` back to `available`, `writeoff` (only reached through the CFO-approved request),
`receipt`, `processing_produce`, reversal legs. Refusal `QUALITY_HOLD_OPEN|<batch>|<ncr>` (no digits in the code, `known-issues.md:648-704`).

❓ **Q4** - **Does a hold also block sale settlement**: settlement prices goods already shipped; today it refuses an open dispute (`sale_settlement_compute.sql:146-154`).

➡️ **Yes** — `record_sale_settlement` refuses `QUALITY_HOLD_OPEN` while the batch has an open NCR: "until we know what this is, it is not settled",
the dispute's own rule. A customer complaint on shipped goods therefore holds settlement until the NCR is decided.

❓ **Q5** - **Relation to quarantine and to disputes**: quarantine (MES-3a) is a location rule for fire risk that refuses landings; a dispute (MES-6a-1)
holds pricing and settlement only.

➡️ **Independent, all three.** A hold moves nothing (moving a held batch into a quarantine location is allowed, never automatic); an NCR may cite a
dispute and a dispute may lead to an NCR; resolving one never releases the other. The batch page shows each as its own line.

❓ **Q6** - **Which events open an NCR automatically**: candidates — a V17 breach; an inbound grade breach (CONTRACT-1 ③'s trigger); a contamination
check above V11; a discharge module failure; an inspection (MES-7b).

➡️ **Only a V17 breach** (the brief: "V17 … acting through that hold"). Inbound grade breaches, V11 and discharge failures stay flags that **prompt** an
NCR (an arm); every repo limit so far flags and never refuses (V36 · V11 · V9). Inbound grade breaches are not gated because `contract_grade_breaches`
ignores the spec's `material_id` and the result's party (`contract_grade_breaches.sql:42-54`); CONTRACT-1 ③ stays open with that as its new return
condition. Inspections arrive with MES-7b.

❓ **Q7** - **The NCR record**: MES-0 Q65 ruled sources and dispositions; it did not say shape or numbering.

➡️ **`nonconformance_reports`:** `NCR-YYYY-NNNN` (gapless yearly, width `GREATEST(4, …)`); inbound XOR output batch; source `manual` · `quality_limit` ·
`customer_complaint` (`inspection` reserved for MES-7b); description (required); optional links (assay, dispute, sales order, judgement); status `open` →
`decided` only through functions; disposition + note + decided at / by; append-only otherwise (a correction is a new NCR citing the old). Change-logged.
Several open NCRs on one batch are allowed (the hold lasts while any is open).

❓ **Q8** - **What V17 limits are and where they live**: Q5 of MES-6a ruled "per contract". `contract_grade_specs.metal` is an FK to substances and
cannot hold moisture or indicators.

➡️ **`contract_quality_limits`** (sell contracts only): contract; material (optional, like grade specs); parameter = `moisture_pct` or an `assay_indicators`
code (a CHECK / FK pair); `min_value` and / or `max_value`; notes. Written under `action.contract_terms`, frozen with the contract, snapshot at link. Generic
over the five indicators; the pending value keeps the name V17.

❓ **Q9** - **Who decides an NCR, and four eyes**: Q65 ruled `action.ncr_decide` (cco, cto, admin).

➡️ **`action.ncr_decide` decides; the opener never decides their own NCR** (by person, `SELF_APPROVAL_FORBIDDEN|raiser`); opening refuses when no other
holder exists (`NCR_NO_OTHER_DECIDER`, the WO / blending precedent). A system-opened (`quality_limit`) NCR has no human opener and any holder decides.
`action.ncr_decide` declares `module.quality.view` (`/quality/ncr/[id]`).

❓ **Q10** - **The certificate's subject**: per output batch (Q67 [R]); a buyer often wants the certificate for *their* shipment.

➡️ **Per output batch, optionally naming one sales order** (then it states that contract's V17 limits and judgement and the customer's name). One live
CoA per batch × sales order (none named = one per batch).

❓ **Q11** - **Which assay a CoA states**: `apply_output_assay` overwrites batch content with whichever party applied last; `unapply` leaves stale provenance;
`is_final` is never read on the output side.

➡️ **The governing assay, read from its own lines:** the dispute's `governing_assay_id` when one was resolved; else, with a sales order named, the
contract's settling party's latest live result; else our latest live result. It must be `is_final`. The CoA never reads `output_batch_metals`.
The two content defects are registered (Q41), not fixed here.

❓ **Q12** - **N38 — what "chemistry certainty" means on an output batch**: only inbound batches carry `chemistry_certainty_code` (`single_known` · `mixed`
· `unknown_pending`; NULL = not recorded); lineage carries neither (`known-issues.md:4468-4484`).

➡️ **The weakest of the inbound leaves through `batch_lineage_all`** — order `unknown_pending` < not recorded < `mixed` < `single_known` — computed by an
owner-rights view gated like the batch (`output_batch_chemistry_certainty`), shown on the output batch page and frozen into the CoA ("Feed chemistry:
known · known to be mixed · not recorded"). Live: 1 of 15 inbound batches has a code, so most will say "not recorded" — the point of N38.

❓ **Q13** - **The CoA issuer and signing**: the COD prints no person (`certificates_of_destruction.sql:74`); a certificate of analysis conventionally carries
an authorised signatory.

➡️ **Print "Issued by <display name>, <position>" and the issue time; no signature image.** Tim's call — the COD's no-names rule was about a public
verify page, and the CoA has none (Q96 [R]).

❓ **Q14** - **Sharing with the buyer**: no mail service exists; MES-0 ruled no public verify page.

➡️ **A PDF download** from the output batch page (and the sales-order page when named), English only (Q67 [R]); no "sent" flag (the `*_issues` families
record no receipt, `shipment_issues.sql:9`).

❓ **Q15** - **F4 — accept payable metals as penalty elements**: today the guard admits `penalty_element` only (`guard_substance_role.sql:26-32`).

➡️ **Accept `payable_metal` or `penalty_element`** (the guard takes a set of roles; `other` still refused); every price path stays payable-only. Picker:
payable metals and penalty elements; ppm beside the threshold only for `penalty_element` (a 3 % copper threshold reads "3 %", not "30000 ppm").

❓ **Q16** - **F5 — a penalty-only assay**: options (a) merge by substance for every assay — breaks fixture 54E's "an assay is a complete statement"
(`54-…:386-391`); (b) refuse by name; (c) **apply an assay that contains no payable metal as a supplement**: it replaces only the substances it measured,
prices nothing, supersedes nothing.

➡️ **(c)** on both sides (inbound and output), with the preview saying "supplement — replaces F, Cl only, prices nothing". A full assay keeps the
complete-statement rule (54E unchanged). This also closes the output-side wipe (§1.10).

❓ **Q17** - **F6 — the four wording arms**: switching `e.part` → `e.titlePart` alone stays green (all 22 samples have a null part), so a part-only fault cannot bite.

➡️ **Switch the four readers; add to each arm one sample from its own cut whose entry carries a part** (㉔: an energy run share, `render.ts:1941-1943`); where an
arm's cut has no part-producing path (㉓ ㉕ ㉖, traced), its part-only fault **injects a fake part into the generic family** and the arm must go red.
Each arm gets a fault named `wording-part-<arm>`.

❓ **Q18** - **F7 — which inputs get the ppm readout**: the brief names "every penalty-element % input on both assay entry forms"; other % inputs that take a
penalty element: the batch content panel's manual entry (`MetalContentPanel`), the contract's penalty threshold, grade specs, blending targets.

➡️ **The two assay forms and the batch content manual entry** (the three places a measured value is typed), with one CSD rule that every penalty-element
content input renders `ppmOf` beside it; the contract threshold already shows ppm in its rows and gets the same readout on its input. Grade specs and
blending targets stay %.

❓ **Q19** - **F8 — the list**: from the close-out item a.

➡️ **Five additions:** an INJ cell for the engine's terms-side `SUBSTANCE_NOT_PAYABLE`; one for the formula-change path (a guard on the change request
alone); one that adds a 9th change-log exclusion and must turn F262 LOG and 235 O1 red; F262 IND recording all five indicators on the output path;
a cell for 119 F1's seven-payable assertion. Run on a fresh rebuild after the last edit, with MES-6b-1's own cells.

❓ **Q20** - **Approvals**: MES-0 Q89 ruled one new CFO request (CoA void).

➡️ **Only that**, in 6b-2 — `warehouse_requests` kind `coa_void` (the COD's engine), level 2, fixed, raiser never decides. NCR dispositions, holds and
limits carry no approval. Approvals ON / finance / cfo / 1,000 unchanged.

### Round 2 (each depends on the round-1 answer named)

❓ **Q21** - **(Q2, Q3) What leaves a held batch**: a `reject` disposition keeps the hold; the batch still has to go somewhere.

➡️ **Write-off through the existing CFO request** (allowed by the ledger guard because it executes under the request's context); a return to the
supplier has no function today and stays out. The NCR records `reject`; the hold ends when the batch has no stock left.

❓ **Q22** - **(Q2) Dispositions and their effects**:

➡️ `accept` → hold released; `accept_with_penalty` → released, the money goes through the existing document (credit note / receipt price request), the
NCR records which; `rework` → released (the next processing run is the rework); `downgrade` → released, recorded only (no re-grade function exists —
registered); `reject` → hold stays (Q21). The NCR carries no amount (no masking needed).

❓ **Q23** - **(Q2, Q3) Existing reservations when a hold lands**:

➡️ **Kept, not released automatically**; shipment of them is refused by the guard; arm `quality_hold_reserved` lists held batches with reservations
and links the sales order; releasing a reservation stays allowed.

❓ **Q24** - **(Q3) Blending plans with a held candidate**:

➡️ **Create / amend refuse a held batch as a line; release refuses a plan with a held line; execution is already refused by the ledger guard** —
so a held batch is never a planned input. Existing released plans: the guard refuses at execution and the plan page says why.

❓ **Q25** - **(Q8) "Declared none" vs "not declared"**:

➡️ **`contract_settlement_terms.quality_limit_basis`** (`none_agreed` · `per_parameter`; NULL = V17 Not yet set); `contract_activation_missing` asks for it on
sell contracts, and `per_parameter` with no limit rows is refused by name (`QUALITY_LIMITS_NOT_FILED`), the SETTLE-1 ③ pattern.

❓ **Q26** - **(Q8) When and on which assay V17 is judged**:

➡️ **At `record_assay_result` on an output batch already reserved to a sales order linked to a contract with limits, and at `reserve_stock_internal`
for a batch that already has an assay** — on the contract's settling party's latest live result (governing assay after a resolved dispute). One
append-only judgement row per parameter with the limit copied (`limit_min_at` / `limit_max_at`) and the result `within` · `below_min` · `above_max` ·
`not_measured`. A later contract change never re-judges (the snapshot is frozen at link).

❓ **Q27** - **(Q6, Q26) A breach at reservation: refuse or hold**:

➡️ **Reserve, then open a `quality_limit` NCR (→ hold)** in the same transaction; the reservation's page shows it. Refusing the reservation would hide
the finding behind an error and leave no record; the NCR is the record and the decision.

❓ **Q28** - **(Q8) Buy-side V17**:

➡️ **No.** Buy contracts carry no settlement terms (`assay_disputes.sql:14-15`); moisture on the purchase side is a pricing basis question (index-pricing §9).

❓ **Q29** - **(Q10, Q11) CoA preconditions**:

➡️ **Refuse by name** when: no governing assay or it is not `is_final` (`COA_NO_FINAL_ASSAY`); an open NCR (`QUALITY_HOLD_OPEN`); an open dispute
(`ASSAY_DISPUTE_OPEN`); an output-leg weighing out of calibration (`READING_INSTRUMENT_NOT_CALIBRATED`, the MES-2 gate via `weighing_calibration_all`,
absences governed by `require_calibrated_since`, NULL today); a named sales order whose V17 judgement is a breach without an `accept*` disposition.

❓ **Q30** - **(Q10) Numbering, code and holders**:

➡️ **`COA-YYYY-NNNN`** in `document_types` (57 → 59 with `NCR`), minted at issue; **`action.issue_coa`** → cco · admin (MES-0 Q90), declaring
`module.output.view` and `module.quality.view`; viewing CoAs follows the output batch's view code.

❓ **Q31** - **(Q10, Q11) What is frozen and what the PDF renders**:

➡️ **The snapshot is assembled once by the database and the PDF is rendered from the snapshot** (not from a second live read — the COD discrepancy,
§1.7). Bytes stored in a private bucket `coa-documents` with sha256; GET `?coa=` streams stored bytes and re-checks the hash (409 on mismatch).

❓ **Q32** - **(Q20, Q31) Void and reissue**:

➡️ **Void only through the CFO request**; the voided row keeps its snapshot and bytes; a replacement is a new number with `replaced_by_coa_id` on the old.
**Never voided automatically** (APR7 anti-pattern, `known-issues.md:173-180`); arm `coa_facts_changed` lists issued CoAs whose batch gained a newer assay
or an NCR since issue.

❓ **Q33** - **(Q15) F4 — the same substance priced and penalised in one contract**: today both apply — paid for its payable % and charged its refining
charge, then penalised above the threshold (`sale_settlement_compute.sql:217-300`); nothing prevents it.

➡️ **Refuse by name at the terms**: a contract may not list one substance in both its pricing terms and its penalty elements
(`SUBSTANCE_PRICED_AND_PENALISED|<code>`, checked on both tables and by `contract_activation_missing`). A substance is paid or penalised in a contract,
never both. If Tim wants both, the alternative is to allow it and print both lines on the settlement — tell me.

❓ **Q34** - **(Q15) F4 — penalised but not priced**: a penalised payable metal on the sale assay with no pricing term raises
`SETTLEMENT_PAYABLE_NOT_STATED|cu` (`:227-233`), and a 0 % pricing term is impossible (`contract_pricing_terms.sql:54`).

➡️ **The payable loop skips a substance the frozen terms list as a penalty element**; any other payable metal with no term still refuses as today.
Fixture 149 gains the arm (cu penalised, not priced → settles; cu priced and penalised → refused at the terms).

❓ **Q35** - **(Q15) F4 — the sale quote**: `price_output_sale` reads no contract and prices every payable metal in the batch content.

➡️ **Unchanged.** A quote has no contract; it would value copper a buyer later penalises — registered as a known limitation of a contract-less quote.

❓ **Q36** - **(Q16) F5 — supersede and provenance of a supplement**:

➡️ **A supplement supersedes nothing and is superseded by nothing; its rows carry `content_source = 'assay'` and its own `source_assay_id`**; unapplying it
removes only the rows it wrote. Fixture 54 gains an arm beside 54E (a full assay still replaces everything).

❓ **Q37** - **(Q8, Q25) Pending values**:

➡️ **V17 only**, with its arm and `docs/mes-pending-values.md` row in the same commit (6b-1). The hold, NCR and CoA need no number. No arm for "an NCR
open too long" (no number for "too long" exists — inventing one is a standard).

❓ **Q38** - **(Q2, Q10) Reminder arms**:

➡️ **6b-1:** `ncr_open` (`module.quality.view`), `quality_hold_reserved` (`module.quality.view` or `module.sales.view`), prompts for an inbound grade
breach and a contamination check above V11 (`quality_prompt_ncr`). **6b-2:** `coa_facts_changed`. Fixture 111 / 30 move with them.

❓ **Q39** - **(Q20) Trails, change log, masking**:

➡️ **Subjects `ncr` and `coa`**, members of both batch subjects; quality limits under `contract`; judgements under the batch; wording arms ㉘ / ㉙ reading
`titlePart` with their own faults; every new table change-logged, exclusions stay 8; **no masked column** (no money anywhere in these records).

❓ **Q40** - **(Q1) Migration and window**:

➡️ **Accept §10:** one migration per cut, COMMIT → ROLLBACK dry run on live first; nothing breaks in either window (no NCR, contract or output assay
exists live, and the old app cannot create one); no back-fill.

❓ **Q41** - **(Q11, Q31) Stale records and findings to register / correct**:

➡️ **Correct in the cut that touches the file:** SETTLE-1 ② (`known-issues.md:6633-6644`, still says no sample record exists — MES-6a-1 built it);
CONTRACT-1 ③ (`:6522` "no hold state" → "G29 landed; gate deferred to the corrected judgement"); N38's body (`:4484`) closed by 6b-2; PROC-4 item 1 (`:4522`
F/Cl "queued"); `docs/role-matrix.md:196` vs admin holding every code. **Register (not fix):** `apply_output_assay` replaces content across parties;
`unapply_assay_result` leaves stale `content_source = 'assay'`; the COD PDF renders from live data although its comment says frozen (`route.tsx:149-150`);
`is_final` unread on the output side.

❓ **Q42** - **(Q1) Fixtures**:

➡️ **New 263 (6b-1) and 264 (6b-2); changed without weakening** the list in §7; every new arm fault-injected; the injection run repeated after the last
database edit, on a fresh rebuild, before the push; F8's five cells in the same run.

## §13 · Tim's own facts this cut needs (not design questions)

- Who in the plant may place and decide NCRs (today: open = cco · cto · admin; decide = cco · cto · admin, never the opener).
- Whether any buyer already asks for a certificate per shipment, and in what form (decides Q10 and the CoA layout).
- The first offtake contract's acceptance limits (V17) — moisture and particle size are the spec's own examples (§3.5 [S]).

## §14 · Assertions measured and found false or imprecise

1. **Known-issues N40 "确定度 3 个各 0 批"** (`:~4496`) — live today **1 of 15** inbound batches has a `chemistry_certainty_code` (§ live readings).
2. **The COD PDF route's comment "the frozen one"** (`app/inbound/[id]/cod/pdf/route.tsx:149-150`) — the bytes come from a second live read (§1.7).
3. **`docs/role-matrix.md:196` "`action.issue_cod` 从 cto 与 admin 拿掉"** — admin holds every code since 2026-09-23 (`role_permissions.sql:59-68`; live admin 77 / 77).
4. **MES-0's citation `forward-queue.md:1681`** for "CoA before the first real sale" has drifted to `:2197`.
5. **`operations_now` arm count** — the mirror and fixture 111 say 62; a regex over the live view definition counted 60 (`'x'::text AS item_type` form only)
   — the two differ in what the regex matched, not in the view; 62 stands (fixture 111 pins it).
6. **SETTLE-1 ② and ④** (`known-issues.md:6633-6644`, `:6671-6678`) — written before samples existed and "4 assays, none on output batches", the latter still true.
7. Zero other assertions of the brief found false: SHA, clean tree, 7 accounts enabled, approvals ON finance / cfo / 1,000, admin 77 / 77,
   `require_calibrated_since` NULL, production on the MES-6a-2 app (the close-out read its indicator panel on the deployed forms).

## §15 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q42.
