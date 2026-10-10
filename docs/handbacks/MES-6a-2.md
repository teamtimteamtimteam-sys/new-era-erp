v1.4.49 — Fluorine, chlorine and quality indicators: fluorine and chlorine can now be recorded on assays and named as penalty elements in contracts (shown in % with the ppm beside them) without affecting metal prices or settlement, and assays can record residual powder, foil purity and particle size (D10, D50, D90).

# MES-6a-2 — fluorine and chlorine as penalty elements, assay quality indicators (MES group, thirteenth cut; 2026-10-10)

Tim's brief of 2026-10-10 ("MES-6a-1 close-out + MES-6a-2 build: F and Cl as penalty elements, quality indicators (v1.4.49)"): step 1 closed
MES-6a-1's window and ran the read-only checks a–f; step 2 built MES-6a-2 with every MES-6a Step 0 recommendation for it accepted as stated
(Q3 · Q4 · Q26–Q32 and the 6a-2 parts of Q38–Q45, `docs/surveys/MES-6a/STEP0-HANDBACK.md`), plus two fold-ins (overflow from 1.e — none found;
live-acting scripts start nothing on import). Migration `db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql` (3,747 lines, built
from the mirrors by `db/scripts/build_mes6a2_migration.py`). Opening SHA (step 1): HEAD = origin/main = `git ls-remote origin main` =
`d645d5a79b6257e1235b0acf1061523095d3d917`; after step 1's push: `0565de863c5c1b95ae244e0868c2f916a2c42ded` (tree clean).

---

## §1 · Step 1 — MES-6a-1 close-out, item by item

Committed as "MES-6a-1 close-out" (`0565de86`, pushed; HEAD = origin/main = ls-remote). Full evidence: `docs/surveys/MES-6a/MES-6a-1-CLOSEOUT.md`.

| Item | Result |
|---|---|
| 1 · Window | Closed in `docs/forward-queue.md` item 47 in the MES-5b-3 format: start **2026-10-09 22:33:44 CST** (measured, `db/migration-windows.tsv`) · end lower bound **23:55:45 CST** (measured: the push in `git reflog` of `origin/main`) · end upper bound **2026-10-10 09:46:07 CST** (derived: this session's first command, with Tim's "deployed" in hand — a relay, not a reading of Vercel). **At least 1 h 22 min 01 s, at most 11 h 12 min 23 s.** Close-out readings at 09:53:09 CST: no sample, dispute, lab link, V14/V16 value, reversed expense or new assay since the window opened — nobody used the cut's new things in the window |
| a · Fixtures ↔ arms ↔ injection cells | every rule maps to a fixture arm and an injection cell (260 · 261 nine arms each; 40 F · 118 F5 · 149 J · 220 I6 · 256 / 258 F3 · 100 / 101 / 254 · 111 · 235 at 8); MES-6a-1's 70 cells, 0 wrong |
| b · Grants | the nine quality grants on live, role by role (admin · cco · cto view + edit; cfo · finance · warehouse view); action-implies-view: 67 pairs, 0 violations; catalogue 77, admin 77 |
| c · Registries and records | registries 57 with SMP (`SR_OWN_EXIT=0` 57 / 57 · `DR_OWN_EXIT=0` 290 / 88); V16 / V14 arms live and documented (`docs/mes-pending-values.md:40-41`); known-issues closures (`:10642-10655`); Q12 at `forward-queue.md:707-708`; V17 / N38 in MES-6b; wording arm ㉖ green, its fault red only in ㉖. **One premise of the brief was not accurate:** arm ㉗ did not exist yet — it is MES-6a-2's (built in step 2) |
| d · Deployed app | warehouse · finance · cco · admin clones on the **deployed** app, browser read-only (non-GET requests blocked and counted: 0): every page 200; disabled controls name their code; the expense reversal dialog's confirm stays disabled while the reason is blank or spaces, enables with text, Cancel closes it. A first run lost the network halfway (`RENDER_PROBE_EXIT=6`); reaped by plan (`REAP_OWN_EXIT=0`, 0 leftovers), retried once: `RENDER_PROBE_EXIT=0` |
| e · Layout of `/contracts/[id]` and the output assay page | on a local rebuild of HEAD with data of my own (live has neither): **0 px overflow, 0 clipped tables at 390 and 1280 px** — nothing to fix in step 2 (fold-in 1 closed with no change) |
| f · Decisions | MES-6a-1 hand-back §7's twenty decisions, listed by title |
| 4 · Stop? | nothing missing or broken in a–d → step 2 started |

## §2 · Opening live readings (step 2, before anything changed)

Read **2026-10-10 10:37:25 CST** as `postgres` (`rolbypassrls = true`), `BEGIN READ ONLY … ROLLBACK`, base tables
(`db/scripts/2026-10-10-mes6a2-opening-readings.sql`, `READ_OWN_EXIT=0`).

| Reading | Value |
|---|---|
| Substances | **7** — ni · co · li · mn · cu · al · fe (sort 1–7, all active); columns code, name_en, name_zh, symbol, is_active, sort_order, notes (no `role`); **f 0 · cl 0** |
| References per substance (metal_prices (not deleted) · formula metals · commitment metals · assay metals · inbound content · output content) | ni 2 (2) · 1 · 1 · 2 · 5 · 0 — co 2 (2) · 1 · 1 · 3 · 4 · 2 — li 1 (1) · 1 · 1 · 2 · 2 · 0 — mn 1 (1) · 0 · 0 · 1 · 1 · 0 — cu 3 (2) · 0 · 0 · 3 · 4 · 4 — al 2 (1) · 0 · 0 · 2 · 2 · 0 — fe 1 (1) · 0 · 0 · 1 · 1 · 0; contract pricing terms, refining charges, penalty elements, grade specs: **0** for every substance |
| Contracts | **0** · penalty-element rows 0 · settlement terms 0 |
| Assays | **4**, all on inbound batches, 0 with moisture; 0 on output batches |
| Indicator tables | absent; the `inline_quality` target already reads "Assay indicators (MES-6a)" (left as it is) |
| Standing state | approvals **ON** (level 1 `finance` · level 2 `cfo` · threshold 1,000) · `require_calibrated_since` **NULL** · catalogue **77**, admin **77** · `change_log` 27,683 rows (max seq 30,694) · document types 57 |
| Accounts | 7 — admin@swm-os.test (admin) · chooer@ (finance) · fusheng@ (warehouse) · phua@evolytra.test (cto) · sandra@ (cco) · tim@ (cfo) · vince@ (gm); 0 disabled · 0 throwaway |
| Pending documents (`approval_pending_documents()`) | **1** — `expense_claim CLM-2026-0004` 1,000.00 (not mine). The migration's decider check (APR-10's wider helper, which also counts stocktakes awaiting posting and an approved medical claim awaiting payment) listed **8**, each with a decider other than its raiser (§5 row 3) |
| Reconciliation (tim@'s claims, `db/scripts/2026-10-05-at1d3-live-recon.sql`, `RECON_OWN_EXIT=0`) | AP list 422,188.32 / ledger 381,604.42 / **unexplained 0.00** · AR 57,545.87 / 43,002.12 / **0.00** |

## §3 · Every item built

### §3.1 Database (one migration)

- **`substances.role`** (Q26): `text NOT NULL`, **no default**, `CHECK (role IN ('payable_metal', 'penalty_element', 'other'))`, last column. The
  migration adds it nullable, sets the seven existing rows to `payable_metal`, then `SET NOT NULL` and the CHECK — so no default ever existed.
  **`f` Fluorine / 氟 / F (sort 8)** and **`cl` Chlorine / 氯 / Cl (sort 9)**, both `penalty_element` (Q31), seeded on live and in the bootstrap.
- **Guards** (Q27): one trigger function `guard_substance_role(role, column)` (INVOKER, revoked from authenticated) on six tables —
  `metal_prices` · `pricing_formula_metals` · `pricing_term_commitment_metals` · `contract_pricing_terms` · `contract_refining_charges` take only
  `payable_metal` (else `SUBSTANCE_NOT_PAYABLE|<code>`); `contract_penalty_elements` takes only `penalty_element` (else
  `SUBSTANCE_NOT_PENALTY_ELEMENT|<code>`). Judged on INSERT and on UPDATE of that column; existing rows are not re-judged. An unknown code is
  left to the foreign key. `upsert_metal_prices` and the engine `calculate_metal_price_from_terms` say the same refusal themselves first (the
  engine for a non-payable key in the terms' `payables` and for one in the content list).
- **Readers** (Q28): `payable_metals_only(jsonb)` (SQL, revoked from authenticated) drops known non-payables before the engine —
  `apply_assay_result` (content still lands in full), `preview_assay_price`, `committed_terms_price`; `price_output_sale` (both the content and
  the preset payables), `sale_settlement_compute` (the payable loop), `allocate_processing_costs` (four queries) and the view
  `processing_metal_recovery_all` read payable metals only. Penalties are untouched: settlement's penalty loop reads `contract_penalty_elements`.
- **Indicators** (Q3 · Q4): `assay_indicators` (dictionary; RUNTIME CONFIG; five rows: `residual_powder_pct` "Residual powder on foil" % ·
  `foil_purity_pct` "Foil purity" % · `d10_um` / `d50_um` / `d90_um` "Particle size D10 / D50 / D90" µm; read with an inbound, output or
  materials view code, written with `module.materials.edit`) and `assay_result_indicators` (assay × indicator → value ≥ 0; no write policy;
  read follows the assay's parent batch). `record_assay_result` gains `p_indicators jsonb DEFAULT NULL` (last; the 13-argument signature dropped):
  refuses `INDICATORS_INVALID` · `INDICATOR_INVALID|code` · `DUPLICATE_INDICATOR|code` · `INDICATOR_VALUE_INVALID|code|raw`; returns
  `indicator_count`. **No limit, no judgement, no batch-level copy; moisture stays its own column.**
- **Registration:** both tables change-logged (bound 282 → 284; exclusions stay 8); `assay_indicators` in `document_type_exceptions` (44 → 45 —
  it has a `code` column but is a dictionary); trail: subject `dictionary_assay_indicators`, member `assay_result_indicators` on both batch subjects.
  No new code, no new approval, no masked column, no document code (Q38–Q42).
- **Proof inside the migration** (same transaction): no grant changed, 77 codes all held by admin; approvals on; seven accounts unchanged; pending
  documents identical and each still has a decider who is not its raiser; **35 tables' pre-existing rows byte-identical** (prices, formulas,
  commitments, contracts and every term table, required metals, blending targets, assays, assay metals, batches and their content, price requests and
  history, runs, journals, expenses, payments, sales orders and settlements, samples, disputes, materials, suppliers) and the seven substances
  identical apart from `role`; substances exactly 7 payable + f / cl; five indicator definitions, zero values; `change_log` moved by exactly 10
  (7 substance UPDATEs, 2 INSERTs, 1 exception INSERT); six guards present; `record_assay_result` once, DEFINER, `p_indicators` last and defaulted;
  anon executes exactly two functions; the two inner functions unreachable; 44 open read policies; coverage and mask gaps 0 (8 · 114);
  `require_calibrated_since` NULL. Rehearsed three ways before applying: on a local copy of HEAD's rebuild with seven accounts and approvals on
  (`MIG_LOCAL_EXIT=0`, then `verify_rebuild` of the new mirrors against that migrated copy: **NO DIFFERENCES**, B1/B2 0 both sides — twice, the
  second after the last mirror edit) and as a COMMIT → ROLLBACK dry run on live (`DRYRUN_OWN_EXIT=0`, 11:47:26 → 11:50:18 CST).

### §3.2 Fixtures

- **New:** 262 (ROLE · PAY · PEN · SETTLE · QUOTE · APPLY · RECOV · COST · PPM · IND · LOG). SETTLE's hand figures: settlement weight 9,000 kg;
  ni 1,800 kg contained, 70 % payable = 1,260 kg × 10,000 USD/t = **12,600.00**; refining 1.8 t × 100 = **180.00**; F 0.0123 − 0.005 = 0.0073 points ×
  9 t × 1,000 = **65.70**; amount **12,354.30**; the same assay under a contract with no penalty agreed: metal value identical, penalty 0.
- **Changed, without weakening:** 116 (its fictional substance now states `role 'payable_metal'` — it must enter prices and content), 244 (states
  `'other'`), **119** rewritten (F2: a new payable substance passes every price path incl. commitment metals and contract pricing / refining terms;
  F2P: a penalty substance is accepted on assay, content, required metals, grade spec and penalty element and **refused by name on seven price
  paths**; `cu` as a penalty element refused; F3 adds an FK refusal on a contract pricing term), **149** (its penalty element `cu` → `f` with the
  same 0.5 / 50; `f` 2.5 added to the three assays — amounts 11,542.50 / 11,567.50 unchanged, and now settlement must ignore an F line), **230**
  (penalty `cu` → `f`; the no-code test uses `cl` so it is still refused for the **code**, not the role).
- **Fault injection:** `db/scripts/2026-10-10-mes6a2-fixture-injections.py` — **34 cells on 262 + 1 layered + 6 on 119 / 149 / 230 = 41, 0 wrong**,
  every arm of 262 red at least once, `INJECTIONS_OWN_EXIT=0` — run on `m6a2c`, a fresh rebuild of the mirrors made **after the last database
  edit** (the `contract_penalty_elements` table comment). The layered cell (only the `metal_prices` guard removed) stays green, as stated in the
  script: `upsert_metal_prices` refuses first.

### §3.3 App

- **`lib/substances.ts`** (pure): `toSubstanceOptions` (the dictionary's own name in the reader's language, Q30), `payableOnly` / `penaltyOnly`
  (Q27), and the display — `contentText` / `contentCell`: % **as stored, never rounded**, and for a penalty element the ppm beside it
  (`0.0123% (123 ppm)`), computed by moving the decimal point in the string (0.0029 × 10000 is 28.999999999999996 in floating point).
- **Pickers:** price pages (metal prices list · new · edit · bulk, calculator, formulas new / edit) offer payable metals only; materials' required
  metals, purchase-order estimate, both assay forms and batch content offer every role; the contract's pricing terms and refining charges pick from
  payable metals, its penalty elements from penalty elements. All option labels come from `.label` (nine consumers switched from `t(labelKey)`).
- **Display:** assay detail pages (inbound and output) print content with ppm for penalty elements; the batch content panel no longer rounds to
  two places; the output apply preview uses the same text; the contract shows a penalty threshold as `0.005% (50 ppm)` and its rate as
  `1000 per % (0.1 per ppm)` (the contract unit unchanged, Q29).
- **Indicators:** `IndicatorFields` on both assay forms (number inputs, min 0, active definitions only), parsed by `indicatorPayload` and sent as
  `p_indicators`; `AssayIndicators` on both assay detail pages (the values, with a "no limit applies" note) and on both batch pages (the latest
  recorded value per indicator, linking to its assay).
- **Dictionaries:** substances gain a required Role select; a new "Assay indicators" section (unit required; `module.materials.edit`).
- **Errors:** `SUBSTANCE_NOT_PAYABLE` / `SUBSTANCE_NOT_PENALTY_ELEMENT` (pricing and terms families, naming the substance) and the four indicator
  codes (assay family), en / zh. `metals.f` / `metals.cl` keys for the display sites that translate a code.
- **Trail:** catalogue rows for `substances.role` and both tables; indicator values fold into "Assay recorded" lines; wording arm **㉗** (seven
  sentences, fault `wording-drift-mes6a2` red in ㉗ only).
- **Two new build checks:** `scripts/check-substance-display.mjs` (18 unit assertions on the real functions; source rules for locale, payable-only
  pricing pages, the contract's two dictionaries and three mappings, no `toFixed` on `content_pct`; five self-proof cells; four env faults) and
  `scripts/check-import-inert.mjs` (fold-in 2, §3.4).

### §3.4 Fold-in 2 — live-acting scripts start nothing on import

- **Mechanism:** `scripts/lib/entrypoint.mjs` — `onlyWhenRunDirectly(import.meta.url)` throws `NOT_RUN_ON_IMPORT|<file>` unless the module is
  the one `node` was started with (real paths on both sides). It is the **first statement after the imports** in every script that acts on live:
  **55** (54 existing — the smoke, the surveys, ~30 probes, the PDF sampler, the reaper, the ghost-grant sweep, the scratch-row check, nine
  `db/scripts` live proofs and probes, four close-out renders — plus this cut's live-proof driver). The MES-6a-1 render probe's ad-hoc
  `RUN_DIRECTLY` guard was replaced by it.
- **Check, in the build:** `scripts/check-import-inert.mjs` classifies by AST (imports of `liveLock.mjs`, of a throwaway / cleanup function from
  `ephemeral.mjs`, dynamic imports of either, or a literal naming the service key, the pooler or the deployed host — comments are not in the AST);
  requires the guard as the first statement; requires the two libraries to have no top-level statements; then **really imports every one of
  them** in a child process whose `child_process`, `fetch`, `net` / `tls`, `http(s)`, file writes and `process.exit` are trapped — each must refuse
  with `NOT_RUN_ON_IMPORT` and attempt nothing. Six self-proof cells run every time (an unguarded top-level spawn and fetch must be trapped; a
  guarded one must refuse cleanly; a guard in second place must be named; a liveLock import must be classified; a harmless script must not be).
- **Proved:** clean `55 / 55`, 0 attempts. Fault by env (`unguard:scripts/smoke-routes.mjs`) → red, static layer. **Fault on disk** (smoke's guard
  line deleted, run under an OS network-deny sandbox as a second layer) → red in both layers: the import **tried**
  `child_process.execFileSync, fs.writeFileSync, process.exit(1)` — all trapped, nothing ran; no lock file, no plan file afterwards; the file
  restored (checksum identical). Each self-proof layer blinded in turn → exit 3.

## §4 · Pages — every new or changed route, with its file

| Route | File | New / changed |
|---|---|---|
| `/settings/dictionaries` | `app/settings/dictionaries/page.tsx` · `registry.ts` | changed (substance Role; new Assay indicators section) |
| `/tools/pricing/metal-prices` | `app/tools/pricing/metal-prices/page.tsx` · `MetalPricesToolbar.tsx` · `substanceQuery.ts` · `options.ts` | changed (payable only; dictionary names) |
| `/tools/pricing/metal-prices/new` | `…/new/page.tsx` · `NewMetalPriceForm.tsx` | changed |
| `/tools/pricing/metal-prices/[id]/edit` | `…/[id]/edit/page.tsx` · `EditMetalPriceForm.tsx` | changed |
| `/tools/pricing/metal-prices/bulk` | `…/bulk/page.tsx` | changed |
| `/tools/pricing/calculator` | `app/tools/pricing/calculator/page.tsx` · `CalculatorForm.tsx` | changed |
| `/tools/pricing/formulas/new` · `/tools/pricing/formulas/[id]/edit` | `…/formulas/new/page.tsx` · `…/[id]/edit/page.tsx` · `FormulaForm.tsx` | changed |
| `/materials/[id]/edit` | `app/materials/[id]/edit/page.tsx` · `RequiredMetalsPanel.tsx` | changed (dictionary names) |
| `/purchasing/orders/new` | `app/purchasing/orders/new/page.tsx` · `NewOrderForm.tsx` · `actions.ts` | changed (names; the estimate skips non-payables) |
| `/inbound/[id]/edit` (batch page) | `app/inbound/[id]/edit/page.tsx` (+ `app/components/quality/AssayIndicators.tsx`, `app/components/metals/MetalContentPanel.tsx`) | changed |
| `/output/[id]/edit` (batch page) | `app/output/[id]/edit/page.tsx` (same two components) | changed |
| `/inbound/[id]/assays/new` | `…/assays/new/page.tsx` · `AssayForm.tsx` · `../actions.ts` (+ `IndicatorFields.tsx`, `indicatorPayload.ts`, `app/inbound/assayErrorCodes.ts`) | changed |
| `/output/[id]/assays/new` | `…/assays/new/page.tsx` · `OutputAssayForm.tsx` · `../actions.ts` | changed |
| `/inbound/[id]/assays/[assayId]` | `app/inbound/[id]/assays/[assayId]/page.tsx` | changed (ppm; indicators) |
| `/output/[id]/assays/[assayId]` | `app/output/[id]/assays/[assayId]/page.tsx` | changed (ppm; indicators; preview text) |
| `/contracts/[id]` | `app/contracts/[id]/page.tsx` · `termSpecs.ts` | changed (two dictionaries; ppm beside threshold and rate) |
| every trail panel (batch pages, dictionaries) | `lib/trail/render.ts` · `app/components/trail/AuditTrail.tsx` · `lib/trail/catalogue.generated.ts` | changed (wording) |

## §5 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | Offline gate | `GATEOFF_EXIT=0` (87 s) |
| 2 | Backup | first attempt **`BACKUP_EXIT=1` — stopped by me**, 11:57 → 12:14 CST: I read the 0-byte file and the backend's `idle in transaction` / `ClientRead` on a sequence query as a dead socket, from **one** sample, and terminated my own `pg_dump` (16 min 47 s); the script deleted the partial file and live showed no leftover backend or lock afterwards. Sampling the retry three times 20 s apart showed the same picture is **normal progress** (the statement changes between samples; the custom-format file stays 0 bytes until late) — so the first run was **probably healthy**, and the stop cost one backup cycle. Retried once immediately → **`BACKUP_EXIT=0`** (12:15 → 12:40 CST, `evoltrya-backup-2026-10-10-1215.dump`, 7.9 MB, verified by the script). Recorded as a memory so it is not repeated |
| 3 | Apply | `APPLY_OWN_EXIT=0`; preflight clean (14 CREATE FUNCTION: 10 replaced · 4 new); started 12:42:04, committed **12:45:10 CST** (`db/migration-windows.tsv`: `2026-10-10T12:45:10+0800 … 0565de86`) |
| 4 | Types | `NOTIFY pgrst` (in the migration) then `types:gen` `TYPESGEN_OWN_EXIT=0` — **+92 lines, 0 removed**: the two tables, `substances.role`, `payable_metals_only`, `p_indicators` (the pre-window build used a hand-spliced copy; replaced byte-for-byte by the generated file) |
| 5 | tsc | `TSC_OWN_EXIT=0` |
| 6 | Build | first run red at `check-currency-literals` (my live-proof SQL had a `currency = 'USD'` branch; removed — the unique index already refuses a duplicate rate) → `BUILD_OWN_EXIT=0`: every static check incl. ㉗, `check-import-inert` 55 / 55, `check-substance-display`, then `next build`; **re-run after the last code edit** (the smoke's penalty row, step 11): `BUILD_FINAL_OWN_EXIT=0`. The app-side fault injections were repeated after their files' last edits too: ㉗ (`TW_FAULT_OWN_EXIT=1`, red in ㉗ only; clean 0) · `check-substance-display` four faults all 1, five self-proof cells all 3 · `check-import-inert` env fault 1, clean 0 |
| 7 | Full gate | `GATE_EXIT=0` (649 s): rebuild matches live · B1 / B2 0 both sides · **265 fixtures** · document types 57 · colgrant no gap · types match live · anon surface a subset of the 328-line baseline (325 relations · 2 functions) |
| 8 | i18n | `I18N_OWN_EXIT=0` |
| 9 | Error swallowing | `SWALLOW_OWN_EXIT=0` — 0 unallowed (9 allowlisted) |
| 10 | Layout survey | **15 live pages × 390 px and 1280 px: 0 page overflow, 0 clipped tables** (`S390_EXIT=0` · `S1280_EXIT=0`, self-test passed both) — dictionaries; metal prices list / new / edit / bulk; calculator; formulas new / edit; materials edit; purchase order new; inbound batch, assay form and assay detail; output batch and assay form. **The two pages live has no data for** (`/contracts/[id]` — live has 0 contracts — and `/output/[id]/assays/[assayId]` — live has 0 output assays), with the step 1.e pages, measured on the step 1.e harness refreshed to this cut's code (a scratch copy outside the repo answering only those pages' tables from a local copy of the **migrated** schema with data of my own: the contract's penalty elements F 0.005 % and Cl 0.0025 %; an output assay with seven metals, F 0.0123 %, Cl 0.00005 % and the five indicators): **0 / 0 at both widths** (`H390_EXIT=0` · `H1280_EXIT=0`). Read off those rendered pages: `0.005% (50 ppm)` · `1000 per % (0.1 per ppm)` · `0.0025% (25 ppm)` · `425.5 per % (0.04255 per ppm)` · assay rows `0.0123 (123 ppm)` and `0.00005 (0.5 ppm)` · the "Quality indicators" panel with its five rows |
| 11 | Smoke | first run **`SMOKE_EXIT=1`** — it stopped at its own setup, before any route: its scratch sell contract wrote a penalty row with `cu`, now refused by name (`SUBSTANCE_NOT_PENALTY_ELEMENT|cu`); its cleanup ran (live afterwards: 0 throwaway accounts, 0 probe roles, 0 contracts, 0 penalty rows). The row changed to `f` (decision 21) → **`SMOKE_EXIT=0` — 283 ok · 16 skipped (no data) · 0 failed** (257 routes timed, 1,862 s, median 6.3 s). Scratch cleanup reading afterwards: **0 throwaway accounts, 0 probe roles, 0 grants without an account, 0 contracts**, `.ephemeral` empty; the six stale `ZZ-SMOKE-*` rows it reports (four still referenced) predate this cut and were not touched |
| 12 | Live verification | §6 |

## §6 · Live verification

Driver `db/scripts/2026-10-10-mes6a2-live-proof.mjs` (accounts by `mintThrowaway`, prefix `mes6a2probe`) running
`db/scripts/2026-10-10-mes6a2-live-proof.sql` in **one transaction ending in ROLLBACK** — `MES6A2_PROOF_EXIT=0` / `PROOF_EXIT=0`, started
14:13 CST, psql 18.6 s, transaction 10.4 s. Every action by a throwaway account holding exactly the codes it needs (cco: `action.contract_terms` +
customers / suppliers / pricing view and edit + price data; fin: `action.metal_prices` + pricing view + price data; rec: inbound / output view and
edit; apl: `action.apply_assay` + inbound / output view; sal: customers view / edit + output view + pricing view + `data.view_prices`; iv: inbound /
output view). **No real account read or acted.** My own setup rows (owner path, prefix `ZZ-PROBE-MES6A2`): a supplier, a material, an inbound
batch, four output batches, a customer, a draft sell contract, a sales order, a USD rate and an ni quote for 2026-08-14, the LME September 2026
calendar and ni quotes — live had none of those dates (read first; the proof refuses if any appears).

| Step | What happened (all inside the rolled-back transaction) |
|---|---|
| Reconciliation at start | AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** (read in a clone of cfo's codes) |
| F as a penalty element | cco named **F** on my sell contract `CON-2026-0086` (threshold 0.005 %, 1,000 USD per settlement tonne per point over) → accepted |
| F refused on price paths | a contract pricing term `SUBSTANCE_NOT_PAYABLE|f` · a formula (`submit_formula_create_request`, cco) `SUBSTANCE_NOT_PAYABLE|f` · a metal price (`upsert_metal_prices`, fin) `SUBSTANCE_NOT_PAYABLE|f` — **no row left behind** on any of the four price tables |
| Assays with F and Cl in % | rec recorded a sale assay `ASY-2026-0005` (output batch, dry, 10 % moisture: ni 20 · F 0.0123 · Cl 0.004), an output assay `ASY-2026-0007` (another output batch: same F / Cl) and an inbound assay `ASY-2026-0008` (ni 30 · F 0.0050 · Cl 0.00005) — **stored exactly as entered** (`0.0123`, `0.004`, `0.0050`, `0.00005`) |
| ppm display | the stored values through `lib/substances.ts` (the function the assay pages call): `ni 30%` · `ni 20%` · **`f 0.0123% (123 ppm)` · `f 0.005% (50 ppm)` · `cl 0.004% (40 ppm)` · `cl 0.00005% (0.5 ppm)`** — and the same text read off the rendered harness pages (§5 row 10) |
| Sale settlement | sal settled `OUT-2026-0690` against `ASY-2026-0005` **without error**: metal value **12,600.00** (ni only) − refining **180.00** − penalty **65.70** (F only; Cl has no term) = **12,354.30 USD** — the hand figures of fixture 262; a twin assay without F / Cl: metal value 12,600.00, penalty 0 |
| Sale quote | apl applied `ASY-2026-0007` (batch content now cl 0.004 · f 0.0123 · ni 20 — F recorded, not priced); sal quoted that batch (preset, 2026-08-14) **without error**: **3.8400 SGD / kg**, identical to a twin batch without F; reconciliation still 0.00 / 0.00 |
| Five indicators on both forms | rec recorded residual powder 0.85 % · foil purity 99.2 % · D10 3.1 µm · D50 11.4 µm · D90 28.75 µm on the output assay and on the inbound assay (`indicator_count` 5 each — the same `record_assay_result` both forms call); iv (batch view codes only) read back all ten |
| Untouched | pre-existing substances (apart from `role`), batches, content, assays, price requests, contracts, terms, formulas, sales orders, expenses, payments, journals, suppliers, customers, rates, quotes, indicator definitions and settings: fingerprint identical; pending documents unchanged (`CLM-2026-0004`); approvals on; reconciliation **0.00 / 0.00** at the end |

**Before / after readings** (`db/scripts/2026-10-10-mes6a2-after-readings.sql`, `postgres`, `BEGIN READ ONLY`, base tables; before
**14:12:18 CST** after the smoke, after **14:15:56 CST** after the proof; both `READ_OWN_EXIT=0`):

| Reading | Before | After |
|---|---|---|
| Substances | 7 × `payable_metal` + `f`, `cl` × `penalty_element` (sort 8 · 9, active) | identical |
| Indicator definitions | the five, active | identical |
| Left on live by me | indicator values 0 · penalty elements 0 · F / Cl contents 0 · F / Cl on price paths 0 · contracts 0 · assays 4 (the opening four) · probe rows 0 · `mes6a2probe` accounts 0 · throwaway accounts 0 · probe roles 0 | identical — **nothing of mine remains** |
| Accounts | admin@ admin (77) + cfo (33) · chooer@ finance (42) · fusheng@ warehouse (29) · phua@ cto (36) + operations (15) · sandra@ cco (44) · tim@ cfo (33) · vince@ gm (21); none banned or deleted | identical — **all 7 enabled, roles unchanged** (since the opening, `change_log` shows `user_roles` and `role_permissions` changes only for throwaway accounts and roles, each inserted and deleted; the migration's proof asserted no grant changed. The opening reading printed one role per account, so admin@'s cfo and phua@'s operations roles first appear in these two readings — they are not new) |
| Standing state | approvals ON (finance / cfo / 1,000) · `require_calibrated_since` **NULL** · catalogue 77 · admin 77 · pending 1 (`CLM-2026-0004` 1,000.00) | identical |
| Per-table digests (291 public base tables, `change_log` excluded) | — | **all 291 identical** to before |
| `change_log` since the opening (seq > 30,694) | the migration's 10 (7 substance UPDATEs · 2 INSERTs · 1 exception INSERT, 12:42 CST); the layout surveys' and smoke's throwaway roles, grants, employees and probation reviews and the smoke's scratch contract and terms — **every INSERT matched by a DELETE** (roles 8 / 8 · grants 616 / 616 · employees 18 / 18 · reviews 8 / 8 · contracts 4 / 4 · term rows 11 / 11 · penalty row 1 / 1); the smoke's COD probe: `cod_verification` deleted rate-limit row 171 (left by **MES-6a-1's** smoke, 2026-10-09 23:38:59 — its own window housekeeping) and wrote row 172 (14:07:41) | plus the proof's 13 roles and 308 grants, inserted and deleted (21 / 21 · 924 / 924) — nothing else |
| Reconciliation (tim@'s claims, `db/scripts/2026-10-05-at1d3-live-recon.sql`, 14:16:47 CST, `RECON_OWN_EXIT=0`) | — | AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** |

**Every pre-existing record is unchanged apart from the seven existing substances gaining `role = payable_metal`** (the migration's proof compared
35 tables byte-for-byte across the migration; the readings above cover everything since). The one row that is not a document, batch, assay,
contract, expense, payment or ledger row and did change: the COD rate-limit log (row 171 removed and 172 written by the function itself when the
smoke probed it) — the same documented behaviour MES-6a-1 reported.

## §7 · Role-by-role reading table (live, measured)

Read inside the live proof (`MES6A2_PROOF_EXIT=0`) **after** my own contract, assays and indicator values existed — live has none, so without
them every count would read 0. Each row is a **one-off clone of a real role** (`mintThrowaway { cloneOf }`: exactly that role's codes at that
moment); no real account read or acted. "Assay form" = the page's code (`module.inbound.edit` / `module.output.edit`); indicator definitions and
values = what the clone itself reads through RLS (five definitions; ten values on my two assays); penalty elements = rows the clone reads on my sell
contract (the read policy wants `module.customers.view` for a sell contract); penalty edit = `action.contract_terms`; metal-price page =
`module.pricing.view`, edit = `action.metal_prices`. Pages themselves render for these codes as already measured by the smoke (all codes) and the
surveys; disabled controls name their code (DBLOCK-1).

| Real role (live account) | Codes | Inbound assay form | Output assay form | Indicator definitions | Indicator values (my two assays) | Contract penalty elements | Edit penalty elements | Metal-price page | Record a metal price |
|---|---|---|---|---|---|---|---|---|---|
| admin (admin@) | 77 | **yes** | **yes** | 5 | 10 | 1 (F) | **yes** | open | **yes** |
| finance (chooer@) | 42 | **yes** | **yes** | 5 | 10 | 1 | no | open | **yes** |
| warehouse (fusheng@) | 29 | **yes** | **yes** | 5 | 10 | **0** (no customers view) | no | **refused** | no |
| cto (phua@) | 36 | **yes** | **yes** | 5 | 10 | 1 | no | open | no |
| cco (sandra@) | 44 | **yes** | **yes** | 5 | 10 | 1 | **yes** | open | no |
| cfo (tim@) | 33 | no | no | 5 | 10 | 1 | no | open | no |
| gm (vince@) | 21 | no | no | 5 | 10 | 1 | no | open | no |

How to read it: **recording F, Cl and the indicators is whoever records the assay** (admin · finance · warehouse · cto · cco); **naming F or Cl in a
contract is cco's and admin's** (the existing contract-terms code); **nobody can price them** — the refusal is the substance's role, not a code, so
admin's 77 codes change nothing (§6). Every role that can see a batch reads its indicators. No code, grant or approval was added (Q38).

## §8 · Decisions taken without asking

1. **Two layers on the price paths that have a function of their own.** The six tables carry a guard trigger (one function, `role, column` as
   arguments); `upsert_metal_prices` and the engine also refuse by name first, so the calculator — which writes no row — is covered, and a
   metal-price refusal reads the same either way. Fault injection proves the function layer alone and both together (§3.2).
2. **The engine refuses; the readers filter.** A penalty element handed to `calculate_metal_price_from_terms` is a wrong request
   (`SUBSTANCE_NOT_PAYABLE`); an assay that also measured fluorine is not, so apply, preview, committed-terms pricing, the quote, settlement, cost
   allocation and recovery drop it before pricing. `payable_metals_only` keeps an **unknown** code, so a typo still reaches the foreign key /
   engine and is refused there rather than silently dropped.
3. **Contract penalty elements take penalty elements only.** Q27 pairs the penalty-terms picker with penalty elements; I made the server say the
   same. Consequence: a payable metal (e.g. copper in nickel black mass) cannot be a contract penalty today — registered as
   `MES6A2-PAYABLE-METAL-NOT-A-PENALTY` (live has 0 penalty rows, 0 contracts). Fixtures 149 / 230 and the smoke's scratch contract used `cu` and
   were switched to `f` / `cl` with their numbers unchanged.
4. **Changing a substance's role does not re-judge existing rows** (same rule as `is_active`, D5); stated in the column comment.
5. **The ppm is a screen convention, not a stored value:** stored and entered in %, printed as stored (never rounded), ppm beside it for penalty
   elements only; the penalty rate keeps its contract unit and shows a per-ppm equivalent. The trail prints % only.
6. **`metals.f` / `metals.cl` message keys added**: pickers use dictionary names (Q30) but the sites that translate a code (assay detail, batch
   destinations, the calculator's result column) still use `metals.*`; check-i18n reads the seed, so the keys had to exist.
7. **Indicator definitions are not open to every reader:** read with an inbound, output or materials view code (fixture 249 pins the 44 open read
   policies — adding a 45th would change that count); written with `module.materials.edit`, the same code as the substances dictionary.
8. **Indicator values are written only through `record_assay_result`** (no write policy, like the metal lines); an inactive definition is still
   accepted by the function (the forms offer active ones only — D5).
9. **Batch pages show the latest recorded value per indicator** (by assay date, then code), each linking to its assay — read live from the
   assays, not a batch-level copy (Q3).
10. **The purchase-order estimate skips non-payables** before pricing instead of refusing, and says "no metals" when nothing payable is left.
11. **The metal-price and formula server actions still accept any dictionary code** — the database refuses a penalty element by name; the pages
    only offer payable metals.
12. **`assay_indicators` in the document-registry exceptions** (it has a `code` column but is a dictionary): one row the migration writes on live,
    next to the role column, the two substances and the five definitions.
13. **A penalty-element-only assay cannot be applied to a priced inbound batch** (`NO_METALS`, the whole apply rolls back) — left as it is and
    registered (`MES6A2-PENALTY-ONLY-ASSAY-NOT-APPLICABLE`).
14. **Arms ㉓–㉖ compare a field that does not exist** (`e.part`, always null, pinned as null) — registered (`MES6A2-TRAIL-WORDING-PART-NOT-COMPARED`),
    not fixed in this cut; ㉗ reads the real field.
15. **The required-metals status line** on the material page uses the same dictionary names as its checkboxes.
16. **Fold-in 2's guard throws rather than returns** (an ES module has no top-level return, and a module that quietly does half its work on import
    is harder to read); it is required as the **first** statement, checked by AST; the two shared libraries must stay free of top-level statements.
17. **A second new build check** (`check-substance-display`) pins the picker labels and the ppm text (the brief's fixture list asks for both; a
    fixture cannot see the app).
18. **Stale records corrected in files this cut touches** (Q45): `substanceQuery.ts` header (said names came from the database — they did not
    until now); `contract_penalty_elements` header and table comment (said F / Cl were not in the dictionary — the comment is updated by the
    migration); `docs/known-issues.md` (the same absence, struck through); the floating-point example in `lib/substances.ts` (0.0123 × 10000 is
    exactly 123 — the real case is 0.0029).
19. **In the live proof my own draft contract was activated through the owner path**, standing in for the CFO approval, so that settlement could
    run; it touched nothing but that contract and rolled back.
20. **The pre-window build used hand-spliced types** (no Docker here, so `gen types --db-url` cannot run); the generated file replaced them after
    the migration and the gate compares its bytes with live.
21. **The smoke's scratch penalty row changed from `cu` to `f`** — the first smoke run stopped at its own setup on `SUBSTANCE_NOT_PENALTY_ELEMENT|cu`
    (before any route; its cleanup ran: 0 accounts, 0 probe roles, 0 contracts on live afterwards).

## §9 · Assertions measured and found false or imprecise

- The brief's step 1.c listed arm ㉗ as if it existed — it is this cut's arm (built in step 2).
- My own comment in `lib/substances.ts` (written in this cut) said 0.0123 × 10000 gives 122.99999999999999 in floating point; measured, it gives
  exactly 123. Corrected to 0.0029 → 28.999999999999996 and 1.005 → 10049.999999999998, and the check's float fault now uses the real case
  (it did not go red on the false one — the cell caught it).
- My first description of the ㉓–㉖ blind spot said the part column was "never compared"; measured, it is compared — null against a pinned null.
- My first backup verdict ("hung") was wrong (§5 row 2).

## §10 · Docs updated

`docs/forward-queue.md` (item 48; MES table 9b closed, MES-6b next; both fold-ins closed) · `docs/known-issues.md` (three MES-6a-2 entries; the F / Cl
absence struck through) · `docs/role-matrix.md` (one row: no new code, no grant change) · `docs/change-log.md` (§24) · this hand-back.
