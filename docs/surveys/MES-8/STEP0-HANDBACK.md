# MES-8 Step 0 — hand-back (2026-10-16), with the MES-7b-2 close-out

**STOP GATE.** No code edit, no migration, no live write. The only writes are docs: the close-out (`6af1b532`, "MES-7b-2 close-out") and this file with
the read-only query file beside it (`live-readings.sql`). Waiting on Tim's answers to Q1–Q29 (§12).

**Opening check.** First command **2026-10-16 19:57:20 CST**. Tree clean. `HEAD` = `origin/main` = `git ls-remote origin main` =
`3c281640c70d173db1266d95be62c6b08b449252`; after the close-out `6af1b532e38ba78c8bc85cd81b03bb7205fce4b8` (fresh clone of that commit, no
`.env.local`: `CI_OWN_EXIT=0`, `X_OWN_EXIT=0`). Files staged by explicit path only. No git command was refused.

**Live readings (measured, read-only).** `live-readings.sql` at **20:19:18 CST** (`READ_OWN_EXIT=0`), as `postgres` (`rolbypassrls = true`) over direct psql to
the pooler, inside `BEGIN READ ONLY … ROLLBACK`, base tables and the catalog — except where a line says it read a **view**:

| Reading | Value |
|---|---|
| Suppliers (not deleted) | **9**: approved 1 · draft 8; goods suppliers 7; `credit_rating` filled **0** |
| Purchase orders | 26, of which 4 carry an `on_order` (prepayment) term |
| Inbound batches (not deleted) | 15 from 3 suppliers; pricing final 2 · provisional 13 |
| Scorecard inputs | `grn_discrepancies` 0 rows · `contract_grade_breaches` 0 rows (**both are views**; the second has a `has_permission` predicate, so as `postgres` its 0 is a **permission answer, not a measurement** — AGENTS.md「一个『0 行』的读数」) · NCRs 0 · assay disputes 0 · supplier certificates 4, 1 lapsed |
| AP | `ap_open_items` 0 — **a view with a permission predicate; not measured** (as above) |
| Statements · packs | customer statements 0, issues 0 · management packs 0 |
| Periods | `finance_settings.locked_before` 2026-08-01 · `system_start_date` 2026-08-01 |
| Sales | output batches 14 · `sales_records` 9 · `sales_settlements` 0 |
| Processing | runs 14 (committed 10); `allocation_basis` in use: `metal_value`, `weight` |
| Prices | `metal_prices` 12 rows, **0 with an index**, latest 2026-08-10 · `index_market_calendar` 0 rows |
| Batch metal content | inbound batches with content 7 · output batches 4 |
| Licence data | `company_compliance` 1 row · NEA categories **0** · ceilings 0 |
| Roles (active) | admin · auditor · cco · cfo · cto · employee · finance · gm · hr · procurement · sales · warehouse (no `floor_display`) |
| Codes | 81 (module 34 · action 36 · data 11) |
| Holders | `module.suppliers.view` admin · auditor · cco · cfo · cto · finance · gm · procurement · warehouse · `module.suppliers.edit` admin · cco · cto · finance · procurement · warehouse · `action.supplier_approve` admin · cfo · `module.finance.view` admin · auditor · cco · cfo · cto · finance · gm · `module.finance.edit` admin · finance · `data.view_prices` admin · auditor · cco · cfo · cto · finance · gm · procurement · sales · `module.processing.view` admin · auditor · cco · cfo · cto · finance · gm · operations · warehouse |
| Registries | document types 61 · pending-value arms 29 · public tables 313 |
| Standing state | approvals ON (finance / cfo / 1,000) · 7 accounts, 0 disabled, 0 throwaway · `require_calibrated_since` NULL · 192 views, 0 with a write grant to anon / authenticated · COD-2026-0001 / -0002 sha256 `ba299a4f…f42101` / `717661f6…13a4f9`, objects 34,701 / 34,746 bytes (unchanged) (`closeout-readings.sql`, 20:10:59) |

**How the facts were gathered.** Three read-only sub-agents (none connected to a database, ran a build or imported a script): `docs/known-issues.md` **in full**
(10,983 lines, last line read 10,984 = the empty final line; digest kept in the job scratch directory); `docs/forward-queue.md` — **read in full lines 1–5000 and
7228–7645; lines 5000–7227 (UI, font, button and polish history) were covered by section headers and keyword search only, not paged** (stated, not
hidden); and the MES-8 code map (suppliers, statements, margin, exposure, freeze precedents, session / display, pending values, fixture pins). I read in
full: AGENTS.md, the specification PDF (pypdf, 11 pages), MES-0 README, the MES-7b Step 0, the MES-7b-2 and MES-7b-1 hand-backs, the MES-5b Step 0,
`docs/mes-pending-values.md`, `docs/role-matrix.md`, fixture 268, and the MES-7b-2 brief (from the previous session's transcript). Load-bearing claims
re-read at file:line today: `db/views/batch_margin.sql:90-108` · `db/functions/issue_customer_statement.sql:15` · `db/functions/freeze_management_pack.sql:39-40` ·
`db/functions/customer_statement_data.sql:24` · `docs/known-issues.md:3518-3540` (IDLE-DRAFT) · `docs/forward-queue.md:2455-2510` (stage 6) and `:1004-1047`
(items 53–54) · `db/views/zzz_function_grants.sql:803-829` · `db/apply_migration.sh:67-74`.

Tags: **[M]** measured · **[I]** inferred from code reading · **[Q]** quoted from an earlier record · **[S]** specification · **[R]** a Tim ruling on record.

---

## §0 · The MES-7b-2 close-out (step 1), item by item

All of it is in `MES-7b-2-CLOSEOUT.md` beside this file; summary:

1. **Broken window closed** (`docs/forward-queue.md` item 54): start **19:03:57** · end lower bound **19:53:32** (push of `3c281640`, reflog; `f30c256d` went in
   the same push) · end upper bound **19:57:20** (this session's first command, holding Tim's "deployed" — a relay). **At least 49 min 35 s, at most
   53 min 23 s.** In the window: no checklist, run, finding, parameter, result, incident or NCR; change log only MES-7b-2's own throwaways (INSERT = DELETE);
   0 rows after the push. The deployed app is the MES-7b-2 code (its pages and V18 / V20 render).
2. **F16 exposure, read-only, first.** The 45 views that accepted a write before F16 (33 anon, 45 authenticated) sit on **37 base tables**. The change log
   covers **2026-09-28 23:58:11 → 2026-10-16 19:47:56 CST** (45,139 rows); it records role and account, **not the path** (function, direct REST and a
   view-path write look the same), and it holds **nothing before 2026-09-28** — that part of the exposure is **unmeasured**. On the 37 tables: 32 have 0
   rows; the other five have **1,441** rows, per table:

   | table | rows | authenticated | anon | no session | explained by |
   |---|---|---|---|---|---|
   | `approval_log` | 2 | 2 | 0 | 0 | admin@ deciding two leave requests 2026-09-29 22:43 (`decide_leave_request`, same transactions as below) |
   | `leave_requests` | 2 | 2 | 0 | 0 | the same two transactions |
   | `gateway_keys` | 6 | 6 | 0 | 0 | MES-1's live probe 2026-10-06 (`issue_gateway_key` ×3, `revoke_gateway_key` ×1, `retire_device` ×2) |
   | `performance_reviews` | 555 | 370 | 0 | 185 | route smoke: `open_probation_review` 185 + `set_review_reviewer` 185, cleanup DELETE 185 (service role); 0 left |
   | `employees` | 876 | 0 | 0 | 876 | route smoke's throwaway employees, 438 INSERT = 438 DELETE (service role); 0 left |

   The ten non-smoke writes, each with time, table, operation and row: `approval_log` INSERT `81f7c9dc…` 2026-09-29 22:43:20 and `98dc8619…` 22:43:43;
   `leave_requests` UPDATE `5d93ee0d…` 22:43:20 and `b5a8ff39…` 22:43:43 (`decided_at, decided_by, status, …`); `gateway_keys` INSERT `c866f2e7…`
   2026-10-06 15:08:24, INSERT `48cdbb3d…` 15:08:51, UPDATE `c866f2e7…` 15:08:54 (revoke), UPDATE `48cdbb3d…` 15:08:58 (revoke + `devices`), INSERT
   `6138df2f…` 16:54:57, UPDATE `6138df2f…` 17:03:01 (revoke + `devices`). Every one of the 1,441 rows is listed in `f16-exposure-writes.txt`.
   **No unexplained write.** So step 2 went ahead.
3. **a — fixture list:** all 13 items of the MES-7b-2 block covered (table with file:line in the close-out §3 a); re-run today on a fresh local rebuild: 268 /
   263 / 267 green; the cut's injection script `INJECTIONS_OWN_EXIT=0` (57 + 2 cells, 0 wrong); wording ㉝'s two fault cells each red in ㉝ only;
   `GATE_VIEWWRITE_FAULT=grant` → offline gate exit 1 naming `pending_values:authenticated:insert`.
4. **b — usability:** deployed app, clones of admin · cto · warehouse · cfo · finance, four pages × five = **20 fetches, all 200**. "New checklist" is a link for
   the three safety editors and drawn disabled naming `module.safety.edit` for cfo and finance; the environment page shows the "no monitored parameter (V20)"
   notice for all (live has no parameter, so no record form for anyone); the pending-values page lists V18 and V20 for all five. Local rebuild with my own
   data: **35 fetches, all 200** — "Record an inspection", the run form, the findings forms and the environment record form are pressable for admin · cto ·
   warehouse and drawn disabled naming `module.safety.edit` for cfo · finance; warehouse sees the NCR control disabled naming `module.quality.edit`.
   **Nothing missing, nothing broken.**
5. **c** — the 16 decision titles are listed in the close-out §3 c.
6. **Recorded, not stopping:** MES-7b-2 did **not** set default privileges as its brief's F16 step 3 asked; it substituted a revoke that runs inside every later
   migration's transaction plus the gate's `viewwrite` line (hand-back §9 decision 1). Residual gap: a view created outside `apply_migration.sh` stays writable
   until the next migration or the next gate run. **Q26** asks Tim to accept or reject that substitution.

## §1 · What grilling changed in MES-8's scope

1. **Size → five cuts, not two** [M + I]. MES-0 sized MES-8a at 4 tables / 3 pages (5 h 45 – 9 h 45) and MES-8b at 2.5 / 4 (5 h 25 – 10 h 00). Drawn out
   (§2) they are **five proof shapes**: a computed supplier measure with an effect at PO creation; an external frozen document (statement PDF + archive);
   two read-side money reports (margin, exposure); a second external frozen document per period (compliance pack); and a session / role change (wall
   display). Q1.
2. **MES-0 Q80 is imprecise and needs a ruling** [I, `batch_margin.sql`, `allocate_processing_costs.sql`]. Q80 says attribute an output's revenue back
   "through each run by that run's own `allocation_basis`". But `allocation_basis` splits a run's **cost across its outputs**; it says nothing about how an
   output's revenue splits across a run's **several inputs**. MES-5b ruled the input split **by mass consumed** (MES-5b Q4, built as `batch_balance_tree_all`).
   Q10.
3. **A scorecard input is a known-wrong judge** [Q, `docs/known-issues.md:6479-6547` CONTRACT-1, open]: `contract_grade_breaches` ignores `material_id`
   and which party issued the assay. Scoring suppliers on it would score them on a known error. Q3.
4. **Most scorecard inputs carry no supplier column** [M, code map]: `nonconformance_reports`, `assay_disputes` and `contract_grade_breaches` reach the
   supplier only through `inbound_batches.supplier_id` (or `purchase_orders.supplier_id`). Not a blocker; it fixes the measure definitions (Q3).
5. **"Sampling level adding required assays" (MES-0 Q77) has no mechanism to attach to** [M]: required assays are per **material**
   (`material_required_metals`), not per supplier or receipt; `samples` has no level. Q5.
6. **The wall display collides with a standing ruling** [Q + R]: IDLE-DRAFT (`docs/known-issues.md:3518-3540`) built a 30-minute idle logout with "one value,
   not per role" — and MES-0 Q83 (accepted 2026-10-05) gives one role an exemption. The later ruling should stand, but it reverses a written one. Q19.
7. **External documents need bytes, not only a payload** [M]: `management_packs` (the freeze precedent MES-0 names) keeps a jsonb payload only — no PDF, no
   sha256, no bucket. The standing rule "documents issued to outside parties render from a frozen snapshot" fits the statement / COD / traceability
   precedent (snapshot + PDF + sha256 archive) better. Supplier statements and the compliance pack go to outside parties; margin, exposure and the display
   do not. Q9, Q16.
8. **The compliance pack can hold only what the system knows today** [M + R]: NEA return format (V26) and EU recycling-efficiency method (V27) are not set; NEA
   waste categories are 0 on live (V29). So the pack is a **regulatory record pack** (balance, roll-forward, licence ceiling checks, incidents, environmental
   results, inspections) with the NEA-return and EU sections stated "Not yet set" — not an NEA return. Q14, Q18, Q28.
9. **Health data must not travel into the pack** [I]: the incident register's injury columns are masked (`data.view_health`); a frozen pack copied for
   outside readers must carry incidents without injury details. Q14.
10. **`hazardous_qty_on_hand_tonnes()` no longer exists** [M, `db/migrations/2026-10-06-mes3a-storage-safety.sql:3222`]; MES-0 §1.7 row 30 still cites it. The pack
    reads `nea_category_on_hand_all` / `storage_ceiling_status`.
11. **Fold-ins:** none queued (no F-number after F16 in the queue, sub-agent read). One candidate found (Q25), and the F16 substitution (Q26).

## §2 · (a) What MES-8 is, and its exact contents

**MES-0 §8.2** [Q, `docs/surveys/MES-0/README.md:707-708`]: **MES-8a** = functions 25 scorecards, 26 statements — `supplier_score_rules`,
`supplier_scores`, `supplier_statements`, `supplier_statement_issues`; effects per Q77; 4 tables / 3 pages; extras "effects at PO creation: 1 h";
**5 h 45 – 9 h 45**. **MES-8b** = functions 28 profit per incoming batch, 29 metal exposure, 30 compliance pack, 31 wall display — inbound-batch margin,
inventory exposure, `compliance_packs` (freeze), wall display (role, idle exemption, refresh); 2.5 tables / 4 pages; extras "display role and idle exemption:
1–2 h"; **5 h 25 – 10 h 00**. Rulings [R, MES-0 Q1–Q96 accepted]: Q77 (effects), Q78 (measures), Q79 (statements), Q80 (inbound profit), Q81 (USD exposure),
Q82 (compliance pack frozen per period), Q83 (display role); V23, V24, V26, V27, V28; masking "scores by `module.suppliers.view`" (Q91); no new approval (Q89).
Left to MES-8 by earlier Step 0s [Q]: NCRs on supplier scorecards (MES-6b Step 0:129); freezing and filing the regulatory balance, the NEA return, EU
efficiency, and inbound profit by allocation basis (MES-5b Step 0:147,199-200,267,542; `processing_balance_monthly_all.sql:15`); the NEA return and compliance
pack (MES-3a Step 0:141; MES-7b Step 0:157). **Left to MES-9** [Q]: the supplier portal (function 27), the internal-only sweep of the 44 `USING (true)`
policies and the default `EXECUTE` grant, portal users and invitations; a supplier reading its own statement or scorecard online is MES-9's.

**Proposed contents, by recommended cut (Q1):**

**MES-8a-1 · Supplier scorecards**
- **Tables:** `supplier_score_settings` (one row: V23 measure weights, grade thresholds, review window days; V24 grade → prepayment cap % and grade → sampling
  level — all NULL); `supplier_scorecard_reviews` (append-only: supplier, window from–to, the measures **copied**, the weights / thresholds in force **copied**,
  the grade or "not graded", reviewer, note; correction = a new review citing it with a reason).
- **Views / functions:** `supplier_scorecard_measures` (live, per supplier and window: short deliveries, NCRs, disputes, discharge-judgement mismatches,
  certificate lapses; grade breaches shown, not scored — Q3); `record_supplier_review`; `supplier_po_advice(supplier, payment terms)` used by
  `create_purchase_order` to return a non-blocking `warnings` key, and by the PO form before submit.
- **Pages:** `/purchasing/suppliers/scorecards` (list), a "Scorecard" panel on the supplier page with the review history, the settings panel (V23 / V24).
- **Codes:** `action.supplier_review` (Q6). **Pending values:** V23, V24.

**MES-8a-2 · Supplier statements**
- **Tables:** `supplier_statements` (`SST-YYYY-NNNN` gapless; supplier, period, opening, receipts / expenses charged, credits, payments, prepayment
  applications, closing, by currency, frozen `lines`, supersede with reason), `supplier_statement_issues` (version, file path, sha256; append-only).
- **Functions:** `supplier_statement_data`, `issue_supplier_statement` (tie check → `SUPPLIER_STATEMENT_DOES_NOT_TIE`), `next_supplier_statement_code`,
  `record_supplier_statement_issue`; private bucket for the PDFs.
- **Pages:** a "Statement" panel on the supplier page; PDF route `/finance/supplier-statements/[id]/pdf` (GET renders the frozen row; POST archives).
- **Fold-in:** F17 if Q25.

**MES-8b-1 · Profit per incoming batch and inventory exposure**
- **Views:** `inbound_batch_margin_all` (owner, revoked) + gated reader (decision 2: `data.view_prices AND (module.finance.view OR module.processing.view)`);
  `inventory_metal_exposure_all` + reader (same predicate).
- **Pages:** `/margin/inbound` (beside `/margin`), an "Inventory" section on `/finance/price-exposure` (the sell-side section unchanged); a margin line on
  `/inbound/[id]/edit` for readers who pass the predicate.

**MES-8b-2 · Compliance pack**
- **Tables:** `compliance_packs` (`CPK-YYYY-MM`, re-issue `-2`…, frozen `payload`, supersede with reason), `compliance_pack_issues` (version, file path,
  sha256); private bucket.
- **Functions:** `compliance_pack_data(month)` (live preview), `freeze_compliance_pack`, `record_compliance_pack_issue`.
- **Pages:** `/compliance/packs` (list + live preview), `/compliance/packs/[id]` (the frozen pack) + PDF route; a month-end line (warning only).
- **Codes:** Q17. **Pending values:** V26, V27. **Arm:** `compliance_pack_not_frozen` (Q15).

**MES-8b-3 · Wall display**
- **Role / code:** `floor_display` role (no account created by this cut), `data.view_floor_board`.
- **Function / page:** `floor_board()` (SECURITY DEFINER, counts only, no money, no personal data); `/display` (bare chrome).
- **Session:** the idle exemption for a session whose only role is `floor_display` (`lib/session.ts`, middleware, `IdleWatcher`). **Pending value:** V28.

## §3 · (b) Each report or pack: what it states, reads, covers, who produces it, freezing, numbering, correction, audience

| | Supplier scorecard | Supplier statement | Profit per inbound batch | Inventory exposure | Compliance pack | Wall display |
|---|---|---|---|---|---|---|
| **States** | per supplier and window: counts of short deliveries, NCRs, disputes, discharge mismatches, certificate lapses; grade when V23 is set | what the company owes the supplier: opening, charges, credits, payments, closing, by currency | per inbound batch: attributed realised revenue, cost of what was sold, margin, the unsold share at cost | per metal: on-hand kg × content % × latest price = USD value, with each price's date | a month's regulatory record (§14 Q14) | live counts of the floor's open items |
| **Reads** | `supplier_receipt_pattern`, `nonconformance_reports`, `assay_disputes`, `grn_discrepancies`, `supplier_compliance` (all via `inbound_batches.supplier_id`) | AP ledger: priced receipts, expenses, payments, prepayment applications (the `ap_open_items` / `list_open_base` formula), GL 2000 per supplier for the tie | `batch_balance_tree_all` shares, `batch_margin`'s revenue and unit cost, `inbound_batch_valuation_rows` | `inventory_movements` (remaining), `inbound/output_batch_metals`, `metal_prices` | `processing_balance_monthly_all`, `stock_rollforward_monthly_all`, `nea_category_on_hand_all`, `receipt_ceiling_checks`, incidents (no injury columns), `environmental_results`, `inspection_runs` / findings | `operations_now` arms of the floor (processing, safety, inventory), no money arms |
| **Period** | a rolling window (V23) ending the review date | chosen from–to | to date (live) | today (live) | one calendar month | now |
| **Produced by** | review: `action.supplier_review`; measures live for `module.suppliers.view` | `module.finance.edit` (the customer-statement code) | live, no producer | live, no producer | Q17 | live |
| **Frozen** | each review copies its measures, weights and grade | lines frozen at issue; PDF from the frozen row; sha256 archive | no (a management report, internal) | no | payload frozen; PDF from the payload; sha256 archive | no |
| **Numbered** | no code (records of an event) | `SST-YYYY-NNNN` gapless | — | — | `CPK-YYYY-MM`, re-issue `-2` | — |
| **Corrected** | a new review citing it, with a reason | a new statement superseding it, with a reason; old bytes kept | — | — | a re-issue superseding it, with a reason; old bytes kept | — |
| **For** | management, purchasing (cco) | the supplier | management | management (finance) | NEA, auditors, buyers on request | the floor |

## §4 · (c) Effect on existing pages, functions, reports and fixtures (month-end included)

- **Functions changed:** `create_purchase_order` (a `warnings` key in its return; no new refusal — Q5); `pending_values` (+V23, V24, V26, V27, V28);
  `operations_now` (+1 arm `compliance_pack_not_frozen` if Q15); `trail_subjects` / members (`supplier_scorecard_review`, `supplier_statement`,
  `compliance_pack`); `document_types` (+`SST`, `CPK` → 63); `permissions` / `role_permissions` (Q6, Q17, Q19); `price_exposure_report` untouched.
- **Pages changed:** the supplier page (scorecard and statement panels), the PO form (warnings shown before submit), `/margin` (link to the inbound view),
  `/finance/price-exposure` (inventory section), `/finance/month-end` (one warning line linking the month's pack), `/settings/pending-values`, nav
  (a Compliance entry), `lib/session.ts`, `lib/supabase/middleware.ts`, `app/components/IdleWatcher.tsx`, `lib/loginRoute.ts` (`/display` bare chrome).
- **Month-end:** the pack is **never** a close blocker; the step lists "compliance pack for <month>: not frozen" as a warning once the month is locked (the
  MES-0 Q48 shape). `management_packs` and its freeze are unchanged.
- **Fixtures:** new 269 (8a-1), 270 (8a-2), 271 (8b-1), 272 (8b-2), 273 (8b-3). Moved without weakening: **100 / 254** (61 → 63 document types),
  **101** (declared gates), **111** (70 → 71 arms if Q15), `check-search-registry` `EXPECTED_ROWS` 61 → 63, `check-document-registry`, **257** FCHECK (new
  action codes declare their views), `check-reminder-arms`, `check-trail-wording` (㉞ … one arm per cut), 234 / 235 (new tables bound, exclusions stay 8).

## §5 · (d) Approvals, trails, change log, masking

- **Approvals:** none new (MES-0 §4.1 / Q89 [R]): reviews, statements and packs are records or documents of facts; statements follow customer statements
  (no approval). Approvals stay ON, finance / cfo / 1,000. Q21.
- **Trails:** `supplier_scorecard_review` and `supplier_statement` shown on the supplier page; `compliance_pack` on its page; settings rows under their
  panels. One wording arm per cut with a drift and a part fault.
- **Change log:** every new table bound; exclusions stay 8.
- **Masking:** no masked column needed — scorecard tables carry no money and gate on `module.suppliers.view`; statements gate on `module.finance.view`
  (they are the AP ledger, decision 1); margin and exposure carry decision 2's predicate in the reader body (money absent, not 0.00, for others); the pack
  copies **no** injury columns and no pay. Q22.

## §6 · (e) "Not yet set" values MES-8 adds

| # | value | lives on | page | arm reads | supplied by | when |
|---|---|---|---|---|---|---|
| V23 | Scorecard: weight per measure, grade thresholds, review window (days) | `supplier_score_settings` | the scorecard settings panel | one row while any of them is empty | Tim with cco | the first supplier review after go-live (8a-1) |
| V24 | Grade → prepayment cap %; grade → sampling level | same | same | one row while grades exist (V23 set) and these are empty | Tim with cco | same |
| V26 | NEA return: format and frequency | `compliance_settings` (+ source line) | `/compliance/packs` | one row from day one (Q18) | the NEA licence | NEA licence issued (8b-2) |
| V27 | EU recycling-efficiency method and targets | same | same | one row from day one | the EU implementing act / the EU buyer | the first EU-bound sale |
| V28 | Wall-display refresh interval and tiles | `floor_board_settings` | `/display` (settings panel for admin) | one row once a `floor_display` account exists | Tim | display installed (8b-3) |

No other number is introduced: no default weight, no default grade line, no default prepayment cap, no exposure threshold, no margin target, no pack due day.

## §7 · (f) Migration shape and broken window

- **Shape:** one migration per cut, dated from `date`, built from the mirrors, COMMIT → ROLLBACK dry run on live first; code first, migrate last.
- **8a-1 window:** new tables, codes, a trailing `warnings` key in `create_purchase_order`'s return (the old app ignores unknown keys) — nothing breaks.
- **8a-2 window:** new tables, bucket — nothing breaks (the old app never reads them).
- **8b-1 window:** new views — nothing.
- **8b-2 window:** new tables, codes, bucket, the arm — the old reminders page does not draw the new arm until the deploy (cosmetic).
- **8b-3 window:** role and code — the idle exemption is **app code**, so until the deploy a `floor_display` session (none exists; no account is created)
  would still be logged out. Nothing in use breaks.
- **Existing records:** none changed; no back-fill (MES-0 Q94 [R]). The 26 POs, 15 inbound batches and 9 sales records stay as recorded; a scorecard,
  statement or pack starts empty.

## §8 · (g) Time estimate — two numbers per cut, calibrated

**Measured** [M, transcripts; active = brief → push (7b-2 from the close-out push), gaps ≥ 10 min excluded unless they end in a tool result (none);
floor / work by tool-call class; `measure_7b.py` imports `measure_7a.py`'s method unchanged, kept in the job scratch directory]:

| cut | active | floor | work | Step-0 est. low (raw) | active ÷ low | work ÷ est. work low |
|---|---|---|---|---|---|---|
| MES-1 … MES-6b-2 | (15 rows, MES-7b Step 0 §9 / MES-6b Step 0 §11) | | | | | |
| MES-7a-1 | 2 h 35 | 1 h 25 | 1 h 09 | 7 h 00 | 0.37 | 0.22 |
| MES-7a-2 | 2 h 01 | 1 h 16 | 0 h 45 | 5 h 20 | 0.38 | 0.21 |
| **MES-7b-1** | **2 h 34** | **1 h 25** | **1 h 09** | 7 h 25 | **0.35** | **0.19** |
| MES-7b-1 close-out | 0 h 13 | 0 h 04 | 0 h 09 | — | — | — |
| **MES-7b-2** | **2 h 33** (2 h 47 with its close-out) | **1 h 16** | **1 h 17** | 8 h 00 | **0.32** | **0.19** |

Floor components (7b-1 / 7b-2, min): backup 14 / 16 · full gate 12 / 13 · smoke 40 (one failed run + rerun) / 24 · layout 0 / 9 · apply + dry run 5 / 4 ·
offline gate 3 / 2 · build 3 / 3 · live proof 3 / 1 · fresh clone 4 / 3 · injections 1 / 2. **Medians:** active ÷ low **0.67** (19 cuts) / **0.37** (last five,
0.32–0.55); work ÷ est. work low **0.47** (19) / **0.21** (last five, 0.19–0.24). **Floor used: 1 h 15 – 2 h 00** (the four latest floors 1 h 16 – 1 h 25,
plus the live dry run, the fresh-clone build and one rerun at the top). This close-out + Step 0 block: ≈ 1 h 05 close-out (live exposure readings,
deployed and local page probes, fixture re-runs) + the Step 0.

**Work (raw estimate, minutes) and calibrated (× 0.21, last-five median):**

| part | 8a-1 Scorecards | 8a-2 Statements | 8b-1 Margin + exposure | 8b-2 Compliance pack | 8b-3 Wall display |
|---|---|---|---|---|---|
| orientation | 5 | 5 | 5 | 5 | 5 |
| database | measures view 40–60 · reviews + function 40–60 · settings V23/V24 25–40 · PO advice + `create_purchase_order` 30–45 | 2 tables + data + issue + code + tie 100–150 | inbound margin view 60–90 · exposure view 40–60 | table + data (six sections) 60–90 · freeze / supersede 30–45 · issue + bucket 20–30 · codes, V26/V27, arm 15–20 | role + code + board function + V28 40–60 |
| app | pages + PO form warnings 60–90 | PDF route + panel 60–90 | pages + panels 50–80 | pages + PDF 70–110 | `/display` + idle exemption (3 files) + refresh 50–80 |
| fixtures + injections | 50–80 | 45–70 | 45–70 | 50–80 | 40–60 (+ a session probe) |
| live proof | 15–25 | 15–25 | 10–20 | 15–25 | 15–25 |
| messages, docs, static, trail arm | 30–45 | 25–40 | 25–40 | 30–45 | 20–30 |
| **raw work** | **4 h 55 – 7 h 30** | **4 h 15 – 6 h 30** (+ F17 15–25) | **3 h 55 – 6 h 05** | **4 h 55 – 7 h 30** | **2 h 50 – 4 h 20** |
| **calibrated work** | **≈ 1 h 00 – 1 h 35** | **≈ 0 h 55 – 1 h 20** | **≈ 0 h 50 – 1 h 15** | **≈ 1 h 00 – 1 h 35** | **≈ 0 h 35 – 0 h 55** |

**Estimates — process floor + work, two numbers per cut:**
- **MES-8a-1 Scorecards:** floor **1 h 15 – 2 h 00** + work **≈ 1 h 00 – 1 h 35** = **≈ 2 h 15 – 3 h 35**.
- **MES-8a-2 Statements:** floor **1 h 15 – 2 h 00** + work **≈ 0 h 55 – 1 h 20** (F17 + ≈ 5 min) = **≈ 2 h 10 – 3 h 20**.
- **MES-8b-1 Margin + exposure:** floor **1 h 15 – 2 h 00** + work **≈ 0 h 50 – 1 h 15** = **≈ 2 h 05 – 3 h 15**.
- **MES-8b-2 Compliance pack:** floor **1 h 15 – 2 h 00** + work **≈ 1 h 00 – 1 h 35** = **≈ 2 h 15 – 3 h 35**.
- **MES-8b-3 Wall display:** floor **1 h 15 – 2 h 00** + work **≈ 0 h 35 – 0 h 55** = **≈ 1 h 50 – 2 h 55**.
- **Total (five cuts):** floors 6 h 15 – 10 h 00 + work ≈ 4 h 20 – 6 h 40 = **≈ 10 h 35 – 16 h 40**.
- **As MES-0's two cuts:** 8a floor 1 h 15 – 2 h 00 + work ≈ 1 h 55 – 2 h 55 = **≈ 3 h 10 – 4 h 55**; 8b floor 1 h 15 – 2 h 00 + work ≈ 2 h 25 – 3 h 45 =
  **≈ 3 h 40 – 5 h 45** — both above every measured MES cut at the top (largest 3 h 55 active).
- Pessimistic bound (× 0.47, the 19-cut work median): the work numbers roughly double (8a-1 ≈ 2 h 20 – 3 h 30 …); the last five cuts all landed at
  0.19–0.24.
- MES-0's own raw figures: 8a 5 h 45 – 9 h 45 · 8b 5 h 25 – 10 h 00.

---

## §12 · Every open question, with a recommended answer and its evidence

Grilling is a design tree. **Round 1** is the frontier — questions whose prerequisites are settled. **Round 2** questions depend on a round-1 answer;
each names it, and its recommendation assumes the round-1 recommendation. If Tim answers a round-1 question differently, the round-2 questions under it are
re-asked.

### Round 1

❓ **Q1** - **How many cuts**: MES-0 planned two (8a, 8b). Drawn out they are five proof shapes (§1 item 1); as two cuts each is ≈ 3 h 10 – 4 h 55 and
3 h 40 – 5 h 45 calibrated, above every measured MES cut at the top (§8). Each extra cut costs one floor (≈ 1 h 15 – 2 h 00).

➡️ **Five cuts, in this order: MES-8a-1 Scorecards · MES-8a-2 Statements · MES-8b-1 Margin + exposure · MES-8b-2 Compliance pack · MES-8b-3 Wall display**
(≈ 2 h 15 – 3 h 35 · 2 h 10 – 3 h 20 · 2 h 05 – 3 h 15 · 2 h 15 – 3 h 35 · 1 h 50 – 2 h 55). *(Cheaper alternative: four cuts, with the wall display folded
into 8b-1 — saves one floor but mixes a session change into a money report's proof.)*

❓ **Q2** - **What a scorecard is**: MES-0 named `supplier_score_rules` and `supplier_scores`; V23 says "rolling period". A live-only score moves under
anyone's feet; a stored score without a record of what it was computed from cannot be explained later (the frozen-copy rule every MES cut has applied: V1,
V9, V11, V36 are copied onto their records).

➡️ **Measures computed live (a view, per supplier and window), and a review is an append-only record that copies the measures, the weights / thresholds in
force and the resulting grade at the moment someone records it. PO effects read the supplier's latest not-superseded review. A mistaken review is
corrected by a new review citing it with a reason.** No score is stored without a review.

❓ **Q3** - **Which measures** (MES-0 Q78: short-delivery counts, grade breaches, NCRs, disputes, discharge-judgement accuracy, certificate lapses):
`contract_grade_breaches` is a known-wrong judge (CONTRACT-1 open, `known-issues.md:6479-6547`); `nonconformance_reports` / `assay_disputes` reach the supplier
through the batch; `supplier_receipt_pattern` already counts short and over receipts (window hard-coded 180 days, `supplier_receipt_pattern.sql:42`).

➡️ **Scored measures: short deliveries and over-deliveries (from `grn_discrepancies` in the window, not the 180-day view), NCRs on the supplier's batches by
disposition, buy-side disputes, discharge-judgement mismatches (`grn_discrepancies` deep-discharge kinds), certificate lapses (days a `block` / `warn`
certificate was expired in the window). Grade breaches are shown with the CONTRACT-1 caveat and NOT scored until CONTRACT-1 is fixed.** Counts only;
NULL-safe (`known-issues.md:5169-5214`: a NULL compare is "not compared", never 0).

❓ **Q4** - **V23 not set**: with no weights, thresholds or window there is no grade.

➡️ **Until V23 is set, a review records the measures over a window the reviewer types (from–to, required) and its grade reads "Not graded — V23 not set";
no PO effect fires. Once V23 is set, the window defaults to nothing — the reviewer still types it — and the grade is computed from the copied weights.**
Nothing guesses a weight or a line.

❓ **Q5** - **Effects at PO creation** (MES-0 Q77: price advisory only; prepayment cap per grade as a warning; sampling level per grade adding required
assays): required assays are per material, not per supplier (`material_required_metals.sql:32-38`); no sampling level exists anywhere.

➡️ **Prepayment: `create_purchase_order` returns `warnings: [{code: 'PREPAYMENT_ABOVE_GRADE_CAP', grade, cap_pct, on_order_pct}]` when the latest review's
grade has a V24 cap and the PO's `on_order` terms exceed it; the PO form shows it before submit; nothing is refused. Sampling: the grade's sampling level
(V24, free text) is shown on the receipt form and the batch page as advice — it does not add required assays in MES-8 (that needs a per-receipt assay
requirement that does not exist; register it).** Price: the latest grade shown beside the supplier on the PO form, advisory only.

❓ **Q6** - **Scorecard codes**: MES-0 masks scores by `module.suppliers.view` (Q91); recording a review is a judgement about a supplier, like approving one
(`action.supplier_approve` admin · cfo).

➡️ **Read: `module.suppliers.view` (as today). Record a review and set V23 / V24: new `action.supplier_review` → cco, admin (declared view
`module.suppliers.view`; cco holds it).** cfo stays read-only. *(Alternative: reuse `module.suppliers.edit` — six roles incl. warehouse, which would then
grade suppliers.)*

❓ **Q7** - **Supplier statement shape** (MES-0 Q79: "an issued statement of account, frozen, PDF, archived — the customer-statement shape"):
`customer_statements` freezes `lines`, supersedes with a reason, has no void, ties to the ledger (`STATEMENT_DOES_NOT_TIE`), is issued under
`module.finance.edit` and read under `module.finance.view` (`issue_customer_statement.sql:15`, `customer_statement_data.sql:24`).

➡️ **The same shape for suppliers: `SST-YYYY-NNNN` gapless (width `GREATEST(4, …)`, not the 4-digit truncation of `CODE-WIDTH-4`); period from–to; opening,
charges (priced receipts and expenses), credits, payments, prepayment applications, closing, per currency; frozen lines; issue refuses unless the statement
ties to GL 2000 for that supplier (`SUPPLIER_STATEMENT_DOES_NOT_TIE`); correction = a new statement superseding it with a reason; issue
`module.finance.edit`, read `module.finance.view`.**

❓ **Q8** - **What a supplier statement leaves out**: 13 of 15 live inbound batches are provisionally priced; `ap_open_items` also carries employee
counterparties (claims) (`known-issues.md:3953`).

➡️ **Provisional receipts are on the statement at their provisional value, each line marked "provisional"; unpriced receipts are not charged and are listed
under "received, not yet priced" with quantity only; employee counterparties never get a supplier statement.**

❓ **Q9** - **Statement document**: outside party → the frozen-snapshot rule; the customer statement renders a PDF from the frozen row and archives it by
sha256 in a private bucket (`app/finance/statements/[id]/pdf/route.ts:28,179-224`); its language is an open ruling (`forward-queue.md:3404-3413`).

➡️ **The same: PDF rendered only from the frozen row, archived by sha256 in a new private bucket `supplier-statement-documents`, each re-download re-checks the
hash; English, like today's customer statement; the language ruling, when made, applies to both.**

❓ **Q10** - **Profit per incoming batch — the attribution rule** (MES-0 Q80 says "by that run's own `allocation_basis`"; §1 item 2: that basis splits cost
across outputs, not revenue across inputs).

➡️ **An inbound batch's share of each downstream output = MES-5b's mass-consumed share (`batch_balance_tree_all`, exact numerics). Its margin = Σ over
outputs of share × (revenue of the sold quantity − that output's `unit_cost_base` × quantity sold) — the output's unit cost already carries the run's
`allocation_basis` split. The unsold share shows as on-hand quantity at cost, not as margin. NULL — "not computable" — if any leg on the path is unpriced or
unallocated; never 0.** Gate: decision 2.

❓ **Q11** - **Revenue source**: `batch_margin` uses `sales_records` (`batch_margin.sql:96-106`); sell-side settlements never post (SETTLE-1, 0 on live).

➡️ **`sales_records` revenue and quantity, exactly as `batch_margin` reads them (one definition, one place); settlements appear only when they post.**

❓ **Q12** - **Inventory exposure — the definition** (MES-0 Q81: USD with each price's date, no conversion; unassayed content "not measured"): 12 price rows,
none indexed, latest 2026-08-10; content on 7 inbound / 4 output batches.

➡️ **Per metal (payable metals only — `substances.role`): Σ remaining kg of live inbound and output batches × content % × the latest `metal_prices` row on
or before today, in USD per tonne, with that price's date shown and flagged when older than the batch's own content date. A batch with no content is
"not measured" (its kg listed, not valued); a metal with no price is "no price". No FX conversion; no threshold.**

❓ **Q13** - **Where exposure and inbound margin live, and who reads them**: `/finance/price-exposure` (sell-side, `module.finance.view`); `/margin`
(decision 2).

➡️ **Inventory exposure: a second section on `/finance/price-exposure`, behind decision 2's predicate (it is a price figure on stock). Inbound margin:
`/margin/inbound` beside `/margin`, same predicate; a margin line on the inbound batch page for readers who pass it, "restricted" for others.**

❓ **Q14** - **What the compliance pack is** (MES-0 Q82: NEA return V26, regulatory balance, EU efficiency V27, frozen per period): V26 / V27 not set; NEA
categories 0 on live; incidents carry masked injury columns.

➡️ **A monthly regulatory record pack: (1) the processing balance (plant and per operation) and (2) the stock roll-forward for the month; (3) licence in force,
on-hand by NEA category at month end and the month's receipt ceiling checks by outcome; (4) incidents in the month with kind, NEA-reportable,
notified and report dates — no injury details; (5) environmental results with their limits and judgements; (6) inspections done and findings open at month
end; (7) "NEA return — format not yet set (V26)"; (8) "EU recycling efficiency — method not yet set (V27)". For NEA, auditors and buyers on request.**

❓ **Q15** - **Period and freeze gate**: management packs freeze only a finance-locked month (`PACK_MONTH_NOT_LOCKED`, `freeze_management_pack.sql:51-52`).

➡️ **One calendar month; freezing requires that month to be locked (`locked_before` after its end), the same gate, so the figures cannot move after the
freeze. A reminder arm `compliance_pack_not_frozen` lists each locked month since `system_start_date` without a live pack; month-end shows it as a warning,
never a block.**

❓ **Q16** - **Pack numbering, correction and document**: outside party → frozen snapshot; management packs have no PDF / sha.

➡️ **`CPK-YYYY-MM`, a re-issue `CPK-YYYY-MM-2` superseding the first with a required reason (the old payload and bytes kept); PDF rendered only from the
frozen payload, archived by sha256 in a private bucket `compliance-documents`; English; no void.**

❓ **Q17** - **Who produces and reads the pack**: no compliance code exists; the licence and safety data sit behind `module.suppliers.view`,
`module.inventory.view` and `module.safety.view`.

➡️ **New `module.compliance.view` (read packs and the live preview) → admin, auditor, cfo, cco, cto, gm; new `action.compliance_pack` (freeze, re-issue,
archive) → cto, admin, declared view `module.compliance.view`.** The pack payload is frozen with owner rights, so a reader needs only the compliance view.

❓ **Q18** - **V26 / V27 on the pending list**: neither has a record to hang on until the licence or an EU sale exists.

➡️ **One row each from the day 8b-2 ships (the V18 / V20 precedent: an empty dictionary is a row), on `compliance_settings`, read
`module.compliance.view`; each pack prints the state "Not yet set" in its sections 7 and 8.**

❓ **Q19** - **Wall display and the idle-logout ruling**: MES-0 Q83 [R]: a `floor_display` role, one code reading one SECURITY DEFINER board function, one
account per screen, that role alone exempt from idle logout, no anonymous display. IDLE-DRAFT (`known-issues.md:3518-3540`) built "one value, not per
role". Supabase's own inactivity timeout stays 0; a disabled token works up to 1 h (`known-issues.md:9903`).

➡️ **Q83 stands and is recorded as superseding IDLE-DRAFT's "one value" for exactly one case: a session whose only role is `floor_display` and whose only code
is `data.view_floor_board` is exempt; any other code on that role removes the exemption (checked at sign-in and on every request). `/display` reads only
`floor_board()`; every other route refuses that role.**

❓ **Q20** - **What the board shows, and refresh (V28)**: no polling exists anywhere (`IdleWatcher.tsx:84` is the only `setInterval`).

➡️ **Counts only, from `operations_now`'s processing, safety and inventory arms (no money, no names of people, no health); the tile list and the refresh
interval are V28. Until V28 is set the page shows the counts with "refreshed at hh:mm" and a refresh button — no auto-refresh interval is guessed.**

❓ **Q21** - **Approvals**: MES-0 §4.1 / Q89 [R].

➡️ **None new.** Reviews, statements, packs and the board are records or documents of facts; approvals stay ON, finance / cfo / 1,000.

❓ **Q22** - **Trails, change log, masking**:

➡️ **Trail subjects `supplier_scorecard_review`, `supplier_statement`, `compliance_pack`; one wording arm per cut with its two faults; every new table
change-logged, exclusions stay 8; no masked column — gating by the table's own read code and decision 2 in the money readers; the pack copies no injury
or pay column.**

❓ **Q23** - **Migration and window**:

➡️ **One migration per cut, COMMIT → ROLLBACK dry run on live first, code first and migrate last, no back-fill (§7). Every window breaks nothing in use;
8b-3's idle exemption arrives with the deploy (no `floor_display` account exists).**

❓ **Q24** - **Fixtures**:

➡️ **New 269 – 273, one per cut; moved without weakening: 100 / 254 (63 types), 101, 111 (71 arms if Q15), 257, 234 / 235, the search and document registries,
`check-reminder-arms`, `check-trail-wording`; every new arm fault-injected; the injection run repeated on a fresh rebuild after the last database edit.**

❓ **Q25** - **F17 — a fold-in candidate**: `record_cod_issue` lacks the CoA side's lowercase-hash, path-prefix and `COA_BYTES_ALREADY_RECORDED` checks
(`known-issues.md:10823`, open). 8a-2 builds the same issue pattern for statements.

➡️ **Fold it into 8a-2 as F17: `record_cod_issue` gains the CoA variant's three checks, and the new statement-issue function is written to the CoA variant
from the start (≈ 15–25 min raw).** *(Or leave it registered.)*

❓ **Q26** - **F16's default-privileges substitution** (close-out §3 b; MES-7b-2 decision 1): the brief asked for default privileges so future views get no
write grant; the cut instead re-revokes inside every migration's transaction and checks with the gate's `viewwrite` line. Residual gap: a view created
outside `apply_migration.sh` is writable until the next migration or gate run.

➡️ **Accept the substitution and record it in the brief's place** (default privileges cannot tell a view from a table; changing them would strip the write
grant 273 of 303 table mirrors rely on). Residual gap registered, not built.

### Round 2 (each depends on the round-1 answer named)

❓ **Q27** - **(Q2, Q4) Review cadence**: V23 includes a "review period".

➡️ **No reminder for "review due" until V23's window is set; once set, an arm `supplier_review_due` lists approved / active goods suppliers whose latest review
is older than the window — the V18 shape (no number, no reminder).**

❓ **Q28** - **(Q14) EU recycling efficiency in the pack**: the method (Regulation (EU) 2023/1542 implementing act or the buyer's) is V27.

➡️ **No computation in MES-8; the section prints "method not yet set (V27)" with the month's input and output masses already in sections 1–2.** When V27
is set, its computation is its own cut.

❓ **Q29** - **(Q19) Who creates a display account**:

➡️ **Not this cut: 8b-3 creates the role and code only; an admin creates one account per screen through `/settings/accounts` (the ordinary path), holding
only `floor_display`. The 7 real accounts are untouched.**

## §13 · Tim's own facts this cut needs (not design questions)

- Which suppliers will be reviewed first, by whom, and over what window (V23); whether grades are letters or numbers, and the prepayment cap per grade (V24).
- Whether supplier statements are ever sent today, and in which language (shared with the customer-statement language ruling).
- The NEA return's format and frequency once the licence is issued (V26); whether any buyer has asked for EU recycling efficiency (V27).
- Where the wall display will hang, what it must show, how often it must refresh (V28).

## §14 · Assertions measured and found false or imprecise

1. **MES-0 Q80** — "attribute each output batch's revenue back through each run by that run's own `allocation_basis`": `allocation_basis` splits cost across
   a run's outputs (`allocate_processing_costs.sql:84,341,429`); it does not split an output's revenue across the run's inputs. Q10.
2. **MES-0 §1.7 row 30** — "NULL hazardous on-hand": the function was dropped in MES-3a (`2026-10-06-mes3a-storage-safety.sql:3222`); replaced by
   `nea_category_on_hand_all` / `storage_ceiling_status`.
3. **MES-5b Step 0 Q4** named `inbound_batch_balance_all`; it was built as `batch_balance_tree_all` / `batch_balance_tree` (0 hits for the first name).
4. **MES-0 names `management_packs` as the freeze precedent for an outside document**; it has no PDF and no sha256 (`management_packs.sql:37-76`). The statement /
   COD precedent is used instead (Q16).
5. **Two readings that look like measurements are not:** `ap_open_items` 0 and `contract_grade_breaches` 0 as `postgres` are views with permission predicates
   (no JWT) — reported "not measured", not "empty".
6. **Coverage of `docs/forward-queue.md`:** lines 5000–7227 were searched, not paged (stated above).
7. Zero other assertions of the brief found false: SHA `3c281640`, clean tree, approvals ON finance / cfo / 1,000, 7 accounts enabled, `require_calibrated_since`
   NULL, the two COD byte strings unchanged, no view writable by anon / authenticated, the deployed app on the MES-7b-2 code (measured through its pages).

## §15 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q29.
