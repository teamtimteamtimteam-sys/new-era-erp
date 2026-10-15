v1.4.50 — Quality holds: a batch can be put on hold by opening a non-conformance report (NCR-…), which stops it being consumed, shipped, settled or blended until someone other than the opener decides it; sell contracts can set moisture and particle-size limits that automatically open an NCR when a reserved batch's assay is outside them; copper and other payable metals can now be contract penalty elements; an assay that only measures fluorine or chlorine is added on top of the existing result instead of replacing it; and assay entry forms now show the ppm beside fluorine and chlorine as they are typed.

# MES-6b-1 — quality hold through NCRs, contract quality limits (V17), F4 · F5 · F7 · F8 (MES group, fourteenth cut; 2026-10-15)

Tim's brief of 2026-10-15 (MES-6b-1): quality hold through non-conformance reports, V17 contract quality limits, F4 (payable metals as penalty
elements), F5 (penalty-only assay = supplement), F7 (ppm readout on entry forms), F8 (five injection cells). Every ruling in the brief (MES-6b Step 0
Q2–Q9 · Q15 · Q16 · Q18 · Q19 · Q21–Q28 · Q33–Q42, `docs/surveys/MES-6b/STEP0-HANDBACK.md`) was built as stated; MES-6b-2 (CoA, N38, F6, CoA void,
Q10–Q14 · Q17 · Q29–Q32) is next. **Q13 recorded** (`docs/forward-queue.md` row 10b): the certificate says "Issued by <name>, <position>" and the
issue time; no signature image. Migration `db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql` (5,698 lines, built from the mirrors by
`db/scripts/build_mes6b1_migration.py`). Opening SHA: HEAD = origin/main = `git ls-remote origin main` = `eb8d68931bd44ad7e20d449cba1624e29534b8a8`
(tree clean).

---

## §1 · Opening live readings (before anything changed)

Read **2026-10-15 14:06:06 CST** as `postgres` (`rolbypassrls = true`), `BEGIN READ ONLY … ROLLBACK`, base tables
(`db/scripts/2026-10-15-mes6b1-opening-readings.sql`, `READ_OWN_EXIT=0`). Reconciliation read in tim@'s session
(`db/scripts/2026-10-05-at1d3-live-recon.sql`, `RECON_OWN_EXIT=0`).

| Reading | Value |
|---|---|
| Contracts | **0** (none by side or status) · settlement terms 0 · pricing 0 · penalty 0 · grade specs 0 · quality-limits table absent |
| Assays | **4**, all inbound, 0 on output batches, 0 with moisture · metal lines 14 · indicator values 0 |
| Reservations | 3 (open 0 · released 2 · consumed 1) |
| On-hold / committed stock | on_hold rows 2, net 0, 0 batches with on_hold > 0 · committed rows 6, net 0 |
| Disputes · blending · warehouse requests | 0 · none · 0 |
| NCR registry | table absent · `action.ncr_decide` 0 · document type NCR 0 · ncr_decide roles none · `module.quality.edit` roles admin, cco, cto |
| Approvals | ON — level 1 finance · level 2 cfo · threshold 1,000 |
| Accounts | **7**, 0 disabled, 0 deleted: admin@swm-os.test admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm |
| Role code counts | admin 77 · auditor 20 · cco 44 · cfo 33 · cto 36 · employee 0 · finance 42 · gm 21 · hr 8 · operations 15 · procurement 16 · sales 17 · warehouse 29 |
| Catalogue | 77 codes, admin holds 77 · throwaway accounts 0 · `require_calibrated_since` NULL |
| Pending documents | **1** — expense claim CLM-2026-0004, 1,000.00 |
| change_log · document_types · public base tables | 31,145 rows, max seq 34,275 · 57 · 292 |
| Reconciliation (tim@) | AP 422,188.32 list / 381,604.42 ledger / **0.00** unexplained · AR 57,545.87 / 43,002.12 / **0.00** |

(Unlike the MES-6a-2 readings, admin@ now holds only admin and phua@ only cto — not changed by me; I read it as I found it.)

## §2 · What was built

**Hold = an open NCR** (or a rejected one while stock remains). `nonconformance_reports`: NCR-YYYY-NNNN, gapless yearly; inbound XOR output batch;
source `manual` · `customer_complaint` · `quality_limit` (system only; `inspection` reserved); description required; optional links to an assay,
dispute, sales order (output only) or judgement; `open → decided` only through `decide_ncr`; append-only otherwise; change-logged; several open per
batch. One predicate (`ncr_holds`, used by `batch_quality_hold` and `ncr_rows`). One BEFORE INSERT trigger on `inventory_movements`
(`guard_quality_hold`) refuses `QUALITY_HOLD_OPEN|<batch>|<ncr>` for processing consumption, sale, the shipment leg, status changes into committed and
a write-off outside a CFO request; allows transfers, adjustments, available ↔ on_hold, committed → available, receipts, production, reversals and the
CFO write-off. Sale settlement (preview and record) and blending (create / amend / release) ask explicitly. `hold_stock` unchanged.

**Deciding:** `action.ncr_decide` (admin · cco · cto; declares `module.quality.view`). The opener never decides their own (per person,
`SELF_APPROVAL_FORBIDDEN|raiser`); any holder decides a system NCR; an NCR cannot be opened when nobody but the opener could decide it
(`NCR_NO_OTHER_DECIDER`). Accept · accept with penalty (names the credit-note request on the sale side or the receipt price request on the purchase
side) · rework · downgrade release; reject holds while stock remains — the way out is the existing CFO write-off request.

**V17:** `contract_quality_limits` (sell contracts; optional material; moisture or an `assay_indicators` code; min / max) written under
`action.contract_terms`, frozen with the contract, in the CFO's terms state, snapshotted at link. `contract_settlement_terms.quality_limit_basis`
(`none_agreed` · `per_parameter` · NULL = not set) is on the activation checklist; `per_parameter` with no rows refuses `QUALITY_LIMITS_NOT_FILED`.
Judged at `record_assay_result` (output batch reserved to an order with limits) and at `reserve_stock_internal` (batch already assayed): the settling
party's latest live result, or the governing assay after a resolved dispute; one append-only `quality_limit_judgements` row per parameter with the
limits copied (`within` · `below_min` · `above_max` · `not_measured`); never re-judged. A breach keeps the reservation and opens a system NCR in the
same transaction.

**F4:** penalty elements accept `payable_metal` or `penalty_element` (other refused); a substance both priced and penalised on one contract is
refused at both term tables (`SUBSTANCE_PRICED_AND_PENALISED|<code>`) and again at activation; settlement skips a penalised payable metal in the price
loop; ppm only for penalty elements; the sale quote is unchanged (registered). **F5:** an assay measuring no payable metal is a supplement on both
sides — replaces only what it measured, prices nothing, supersedes nothing and is superseded by nothing; unapply removes only its own rows; both
previews say so; a full assay still replaces everything. **F7:** `PpmReadout` beside the penalty-element content input on both assay forms, the
batch content manual entry and the contract penalty threshold; `scripts/check-substance-display.mjs` names the four and goes red when one loses it
(faults `ppm-entry`, `typing`). Grade specs and blending targets stay in %. **F8:** five injection cells in the same run (§4, the injections line).

Plus: three reminder arms (`ncr_open` · `quality_hold_reserved` narrowed to output view and widened to sales view · `quality_prompt_ncr` for grade
breaches, contamination above V11, failed discharge modules); V17 pending value; trail subject `ncr` (and NCRs under both batch subjects,
judgements under the output batch, limits under the contract); trail-wording arm ㉘ reading `titlePart` with its own fault; document registry NCR;
change-log exclusions stay 8; no masked column.

## §3 · Pages (route · file)

| Route | File(s) | What changed |
|---|---|---|
| `/quality/ncr` | `app/quality/ncr/page.tsx` · `NcrTable.tsx` | new — the NCR list (holding flag) |
| `/quality/ncr/new` (`?batch=inbound:<id>` / `output:<id>`) | `app/quality/ncr/new/page.tsx` · `NcrForm.tsx` | new — pick a batch, open an NCR |
| `/quality/ncr/[id]` | `app/quality/ncr/[id]/page.tsx` · `DecideForm.tsx` | new — report, judgement, decision (+ audit trail) |
| `/contracts/[id]` | `app/contracts/[id]/page.tsx` · `TermSection.tsx` · `termSpecs.ts` · `actions.ts` | Quality limits section, quality-limit basis, penalty elements accept payable metals, live ppm on the threshold |
| `/inbound/[id]/edit` · `/output/[id]/edit` | `app/components/quality/QualityPanel.tsx` · `app/components/metals/MetalContentPanel.tsx` | hold banner, NCR list, judgements (output); ppm beside manual content entry |
| `/inbound/[id]/assays/new` · `/output/[id]/assays/new` | `app/inbound/[id]/assays/new/AssayForm.tsx` · `app/output/[id]/assays/new/OutputAssayForm.tsx` | ppm beside penalty-element content as typed |
| `/inbound/[id]/assays/[assayId]` · `/output/[id]/assays/[assayId]` | the two `page.tsx` | supplement preview text |
| `/sales/orders/[id]` | `app/sales/orders/[id]/ReservationSection.tsx` | held reserved batches named with their NCR |
| `/tools/reminders`, home | `lib/reminders.ts` | three arms |
| `/settings/pending-values` | messages only | V17 row |

## §4 · Verification

| # | Step | Result |
|---|---|---|
| 1 | Offline gate | `GATEOFF_EXIT=0` (86 s) |
| 2 | Backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-10-15-1524.dump`, 8,051,073 bytes, TOC 8,857 |
| 3 | Dry run on live (COMMIT → ROLLBACK, with the grants replay) | first run `DRY_OWN_EXIT=3`: `decide_ncr` declares `nonconformance_reports%ROWTYPE` and was created before the table — the builder now creates only the four functions the new tables need before them; second run `DRY_OWN_EXIT=0`, probe: 78 codes · ncr_decide admin, cco, cto · 58 document types · 295 tables · 0 NCRs; every pending document listed with a decider |
| 4 | Apply | run by Tim (my apply was refused by the permission check): `apply_migration.sh` exit 0, preflight passed, committed atomically; **window start 2026-10-15 16:50:30 CST** (`db/migration-windows.tsv`, head at apply `eb8d6893`) |
| 5 | Types | `npm run types:gen` `TYPES_OWN_EXIT=0` (+768 lines; the pre-window hand splice replaced) |
| 6 | tsc | `TSC_OWN_EXIT=0` |
| 7 | Build | `BUILD_OWN_EXIT=0` (pre-window and again after the types) |
| 8 | Full gate | **not obtained.** Two runs (`GATE_EXIT=1` both) died at the same step, the live side of the column-grant check (`check_grant_gaps`): `SSL SYSCALL error: EOF detected / connection to server was lost`. Measured: the same query run directly drops at 1 min 38 s and 1 min 34 s (also with TCP keepalives), while the server keeps running it (seen active at 1 min 44 s and 4 min 10 s; server up since 2026-07-29, no restart); a silent `pg_sleep(130)` over the same pooler survives. Everything before that step passed in both runs (rebuild, mirrors, seeds, bootstrap, chart, integrity). The direct database host is IPv6-only and unreachable from this machine. The gate's own comment records this query at 136 s in August and names `pg_catalog` + `aclexplode` as the real fix; I did not rewrite it in this cut |
| 9 | i18n | in the build — every key in en and zh |
| 10 | Error swallowing | in the build — clean |
| 11 | Layout | live: 14 pages × 390 / 1280 px, **0 overflow · 0 clipped** (`S390_EXIT=0` · `S1280_EXIT=0`, self-test bit). Pages live has no rows for, on a local rebuild of the migrated mirrors with data of my own (PostgREST 16.4 binary and a stub gateway in the scratchpad): 17 pages × 390 / 1280 px, **0 / 0** (`H390_EXIT=0` · `H1280_EXIT=0`, self-test bit); text read off those pages (`CONTENT_EXIT=0`): hold banners, judgements, `0.005% (50 ppm)`, `150 per %` for copper, supplement wording; typing 0.005 beside Fluorine reads `= 50 ppm`, Nickel none; contract threshold 0.0025 with Fluorine `= 25 ppm`, with Copper none |
| 12 | Smoke | `SMOKE_EXIT=1`: 212 routes, ok 198 · skipped 13 · **failed 1 — `/output` 500**, whose server log line is `TypeError: fetch failed` (the request to Supabase failed, the same network). `/output` re-measured in a real session: HTTP 200, 14 rows, 0 overflow (`SOUT_EXIT=0`). Scratch report: the same 6 stale rows from earlier cuts (1,034–1,676 h old), none of mine |
| 13 | Live proof | `MES6B1_PROOF_EXIT=0` (second run; the first stopped at invoicing on `TAX_CODE_REQUIRED|customer` — live is GST-registered — and rolled back; the probe customer now carries `SR`). §5 |
| 14 | Fresh-clone build | see the final report |

Fixtures: 263 new; 30 · 54 · 100 · 101 · 102 · 111 · 119 · 149 · 230 · 254 · 262 changed without weakening. Injections
(`db/scripts/2026-10-15-mes6b1-fixture-injections.py`, on a fresh rebuild after the last mirror edit): **85 cells (67 on 263 + 18 on the others, F8's
five among them), 0 wrong** (`INJECTIONS_OWN_EXIT=0`).

## §5 · Live proof (one transaction, ROLLBACK; throwaway accounts only)

`db/scripts/2026-10-15-mes6b1-live-proof.mjs` → `.sql`. Throwaways (prefix `mes6b1probe`): cco · sal · fin · rec · apl · wh · wo · pc · qe (quality
edit **and** decide) · qd (decide) with exactly the codes they need; cfo = the real cfo role (`realRole`, a `user_roles` row, the role's codes untouched);
seven clones of the real roles for the read-only table. Rehearsed first on a local copy with simulated accounts (`PROOF=0`).

| Step | Result |
|---|---|
| Activation (V17) | CON-2026-0088 refused with the basis unset (`CONTRACT_TERMS_INCOMPLETE|…|quality_limit_basis`) and with per_parameter and no row (`QUALITY_LIMITS_NOT_FILED`); moisture ≤ 8 filed → request → the CFO approved → active |
| F4 | copper as a penalty element accepted; copper priced as well refused `SUBSTANCE_PRICED_AND_PENALISED|cu`; at the end a draft with copper in both tables (the guard switched off for one insert, on again) → checklist `priced_and_penalised:cu`, activation refused by name |
| Judged at reservation | ASY on OUT-2026-0696 (moisture 9.2, ni 20, cu 3); sal reserved 9,000 kg → `above_max` (9.2 > 8, trigger reserved), reservation kept, system NCR opened: "Quality limit breached: OUT-2026-0696 moisture (%) is 9.2 (limit min -, max 8) under contract CON-2026-0088, sales order SO-2026-0005, assay ASY-2026-0005." |
| Held output batch | settlement preview and record refused `QUALITY_HOLD_OPEN|OUT-2026-0696|NCR-2026-0001`; invoiced INV-2026-0010; release approved by the CFO; shipping refused by name; a 10 kg transfer allowed |
| Held inbound batch | qe opened a manual NCR on IN-2026-0504: processing consumption and a blending plan refused by name; transfer allowed; qe deciding their own → `SELF_APPROVAL_FORBIDDEN|raiser` |
| Decided | qd accepted the system NCR → shipped 8,990 kg; settlement computes metal value 12,712.00 USD (ni only) − refining 0 − penalty 1,362.00 (cu only, 1 point over on 9,080 kg) = 11,350.00 USD; qd rejected the manual NCR → still held, consumption still refused → wh's write-off request approved by the CFO → batch written off, no longer held |
| F5 | inbound IN-2026-0505 (ni 30 manual, f 0.02) and output OUT-2026-0697 (ni 20 manual, f 0.02): assays measuring only f 0.0123 and cl 0.004 → both previews "supplement, replaces cl, f"; applied → cl 0.004 · f 0.0123 · ni unchanged; no price request |
| Reconciliation after each finance step (c_cfo) | AP 422,188.32 / 381,604.42 / **0.00**; AR 68,445.87 / 53,902.12 / **0.00** inside the transaction (my invoice); start and after rollback 57,545.87 / 43,002.12 / 0.00 |
| Untouched | pre-existing rows identical (contracts, terms, batches, content, assays, movements, reservations, orders, settlements, releases, invoices, plans, runs, requests, disputes, expenses, payments, journals, parties, materials, quotes, substances, permissions, grants, settings); pending unchanged (CLM-2026-0004); approvals on |
| After (outside the transaction) | NCRs 0 · quality limits 0 · judgements 0 · probe suppliers / customers / contracts / batches / materials 0 · ni quotes in September 2026 0 · pricing guard enabled (`O`) · `require_calibrated_since` NULL |

**Role table** (clones of the seven real roles' codes after the migration; read-only, while both proof batches were held):

| Role (codes) | NCR list | NCR rows readable | batch-page hold lines | contract quality limits | inbound assay form | output assay form | open an NCR | decide an NCR |
|---|---|---|---|---|---|---|---|---|
| admin (78) | yes | 2/2 | 2/2 | 1 | yes | yes | yes | yes |
| finance (42) | yes | 2/2 | 2/2 | 1 | yes | yes | no | no |
| warehouse (29) | yes | 2/2 | 2/2 | 0 (no customer view) | yes | yes | no | no |
| cto (37) | yes | 2/2 | 2/2 | 1 | yes | yes | yes | yes |
| cco (45) | yes | 2/2 | 2/2 | 1 | yes | yes | yes | yes |
| cfo (33) | yes | 2/2 | 2/2 | 1 | no | no | no | no |
| gm (21) | no | 2/2 (through batch view) | 2/2 | 1 | no | no | no | no |

## §6 · After live readings

Read **2026-10-15 17:53 CST** (`postgres`; `db/scripts/2026-10-15-mes6b1-opening-readings.sql` re-run and `…-after-readings.sql`, both `READ_OWN_EXIT=0`);
reconciliation as tim@ (`RECON_OWN_EXIT=0`).

| Reading | Value |
|---|---|
| Nothing of mine remains | NCRs 0 · limits 0 · judgements 0 · basis set 0 · probe rows 0 · probe accounts 0 · probe roles 0 · throwaway accounts 0 |
| Pre-existing unchanged | contracts 0 · assays 4 (all inbound) · reservations 3 / 0 open · on_hold and committed nets 0 · disputes 0 · warehouse requests 0 |
| Accounts | 7, all enabled, none deleted; each with the same single role as at the opening |
| Roles | changed **only** by the three `action.ncr_decide` grants: admin 77 → 78 · cco 44 → 45 · cto 36 → 37; everything else as opened |
| Catalogue · document types · tables | 78, admin 78 · 58 · 295 |
| Pending | 1 — CLM-2026-0004 (unchanged) |
| `require_calibrated_since` | NULL · approvals ON finance / cfo / 1,000 |
| change_log since the opening (seq > 34,275) | the migration's 6 (permissions 1 INSERT + 1 UPDATE · role_permissions 3 · document_types 1) plus the layout surveys' and smoke's throwaway roles, grants, accounts, employees, probation reviews and scratch contract with its terms — every INSERT matched by a DELETE (roles 38 / 38 · user_roles 40 / 40 · role_permissions 997 / 994, the 3 being the migration's · employees 9 / 9 · reviews 4 / 4 · contracts 2 / 2 · term rows 7 / 7); the proof's rows were rolled back and never logged |
| Reconciliation (tim@) | AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** — identical to the opening |

## §7 · Docs

`docs/forward-queue.md` item 49, MES group header and rows 10a (✅) / 10b (⬜ MES-6b-2 with Q13), G29 entry · `docs/mes-pending-values.md` V17 row and
notes · `docs/known-issues.md` new MES-6b-1 section (four findings: output assay replaces across parties · unapply leaves stale provenance · COD PDF
renders live data · `is_final` unread on the output side; plus the sale-quote limitation and downgrade / rework recording only), the two MES-6a-2
entries closed by F4 and F5, and the stale records corrected in place (SETTLE-1 ②, CONTRACT-1 ③ with its new return condition, N38's destination,
PROC-4 item 1) · `docs/role-matrix.md` (`action.ncr_decide`, the NCR row, the `action.issue_cod` line corrected for admin holding every code) ·
`docs/change-log.md` §25 · `docs/dashboard-arm-inventory.md` (three arms).

## §8 · Decisions taken without asking

1. **One hold predicate, pure.** `ncr_holds(status, disposition, deleted_at, remaining)` is IMMUTABLE and reads nothing; `batch_quality_hold` (INVOKER)
   and the owner view `ncr_rows` both call it, so an owner view never borrows an INVOKER function's reader-blind join.
2. **`quality_hold_reserved` narrowed to `module.output.view` and widened to `module.sales.view`** — its predicate reads output batches as the reader;
   a quality-only reader would otherwise read rows with no batch.
3. **Quality limits travel inside the settlement-terms snapshot** (`settlement_terms.quality_limits` jsonb on `contract_document_terms`), not a new column.
4. **One system NCR per breaching parameter**; its description is English written by the database, naming the parameter in words (`moisture (%)`,
   an indicator's English name and unit).
5. **Trigger names `…_unpenalised` / `…_unpriced`** so the role guard fires first (BEFORE triggers fire in name order).
6. **`QUALITY_HOLD_OPEN` translated once in the shared fallback** (`lib/machine-text.ts`, message key `common.shared.QUALITY_HOLD_OPEN` — the
   i18n check looks for the code's own name), not in each module's word list.
7. **F7 as one component** (`PpmReadout`, `lib/substances.ts` `typingPpm`): shown only for penalty elements; a half-typed "0." reads 0; anything
   unreadable shows nothing. The contract threshold readout follows the substance chosen in the same form. The build check pins a closed list of four.
8. **Contract penalty rows:** ppm and per-ppm only for penalty elements; a payable metal's threshold prints `2%` and its rate `150 per %`.
9. **Supplement previews:** inbound says "nothing is repriced, the batch is still priced on the applied assay"; output shows unmeasured contents as
   kept, not "will be removed".
10. **Trail labels for the new tables** (`docs/surveys/AUDIT-TRAIL-0/labels.csv` rows): the dispute link, the judgement id and the two penalty-request
    ids are hidden (no stable number; the report page shows them); a parameter reads "Moisture" by override, an indicator code as stored with the
    indicator's name on its own line.
11. **The prompt arm links to `/quality/ncr/new?batch=<kind>:<id>`** — the form with the batch already chosen.
12. **The decide form lists only waiting or approved money documents**; the receipt price requests are this batch's own.
13. **Constraint names mapped** (`CONTRACT_QUALITY_LIMIT_*`); an unknown parameter (indicator FK) reads as an invalid choice.
14. **Migration order:** after the first dry run caught `decide_ncr`'s `%ROWTYPE`, only `ncr_holds`, `next_ncr_code`, `guard_ncr_mutation` and the
    term guard are created before the new tables.
15. **Pre-window types were spliced from the local rebuild**, then replaced byte-for-byte by `types:gen` after the migration.
16. **Local layout harness:** no Docker, and brew could not link PostgREST's dependencies; I used the PostgREST 16.4 release binary in the scratchpad
    against a local copy of the migrated mirrors with my own data, behind a small stub gateway — I did not touch brew links.
17. **Live proof:** the priced-and-penalised activation check needs a state the guards forbid, so it switches one trigger off for one insert inside the
    rolled-back transaction, placed last because it holds a lock on `contract_pricing_terms` until the rollback (`lock_timeout` 10 s).
18. **The proof's opener also holds the decide code**, so "the opener cannot decide" is shown by `SELF_APPROVAL_FORBIDDEN`, not by a missing code.
19. **Settlement figures in the proof are checked by construction** (penalty = points over × settlement tonnes × rate; amount = value − refining − penalty),
    not hard-coded — the settlement weight is the function's own (the whole batch, dry).
20. **Smoke:** `/quality/ncr/[id]` joins EXPECTED_SKIPS (live has 0 reports); `mes6b1probe` added to the throwaway prefixes.
21. **Downgrade and rework record only** (registered), since Q65 named the dispositions without saying what each does to a batch.
22. **The gate's slow live check was not rewritten** in this cut (its own comment forbids doing that in a cut it just tripped); reported in §4 row 8.
