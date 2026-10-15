v1.4.51 — Certificates of analysis: an output batch can now be issued a certificate of analysis (COA-…) stating its governing assay, quality indicators and how certain its chemistry is, optionally for a named sales order with that contract's limits and result; it downloads as a PDF fixed at the moment of issue, cannot be issued while the batch is on hold or in dispute, and can only be voided through a CFO request.

# MES-6b-2 — certificate of analysis, chemistry certainty (N38), wording-arm fix (F6), CoA void (MES group, fifteenth cut; 2026-10-15)

Tim's brief of 2026-10-15: close out MES-6b-1, then build MES-6b-2 — MES-6b Step 0 Q10–Q14 · Q17 · Q20 · Q29–Q32 · Q38–Q42 as ruled
(`docs/surveys/MES-6b/STEP0-HANDBACK.md`). Q13: the certificate prints "Issued by <name>, <position>" and the issue time, no signature image.
Migration `db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql` (3,824 lines, built from the mirrors by `db/scripts/build_mes6b2_migration.py`).
Opening SHA: HEAD = origin/main = `git ls-remote origin main` = `b7d39271a4333bc098323d2852b7f27783a21cd3` (tree clean); step 1 pushed
`d57edf37` ("MES-6b-1 close-out").

---

## §0 · Step 1 — MES-6b-1 close-out (committed and pushed as `d57edf37` before step 2 began)

**1.1 · Broken window closed** in `docs/forward-queue.md` item 49 (MES-6a-2 format): start **2026-10-15 16:50:30 CST** (`db/migration-windows.tsv`) ·
end lower bound **18:29:32 CST** (measured: `git reflog show --date=iso refs/remotes/origin/main`, the push moving `origin/main` to `b7d39271`) ·
end upper bound **18:40:05 CST** (derived: the first command of the close-out session, holding Tim's relayed "deployed" — a relay, not a
measurement of Vercel). **Window: at least 1 h 39 min 02 s, at most 1 h 49 min 35 s.** Read-only readings at 19:03:24 CST as `postgres`
(`docs/surveys/MES-6b-2/opening-readings.sql`, `READ_OWN_EXIT=0`): since the window opened 0 NCRs, 0 contracts, 0 quality limits, 0 judgements,
0 assays, 0 reservations, 0 stock movements; change_log 2,674 rows, all throwaway (every INSERT matched by a DELETE).

**1.2 · Column-grant check, live half — 0 mismatches.** The single query dropped at ~95 s on the live connection; I split it into batches of 40
relations without changing what it compares (same predicate, `AND cp.table_name = ANY(batch)`): **473 relations · 13 batches · longest 37.4 s ·
`COLGRANT_EXIT=0`**. The `db/gate.py` change (batches of 40, a universe count that must be > 0, at least 20 column-listed tables seen) is in this
cut's commit, reason: the unbatched query cannot finish on this connection. Offline rebuild side after the change: 478 relations · 12 batches ·
39 column-listed tables, no gap.

**1.3 a · Fixtures, item by item** — every item listed in the MES-6b-1 block is covered by a fixture arm (or the F7 / ㉘ build checks). Weaker spots,
**recorded, not missing, not fixed**: fixture 263's AGREE arm was never fault-injected (absent from the injection script's "every arm red at least
once" list); its header claims all four wrong-batch links are refused, but only the assay one is asserted (the dispute / sales-order / judgement
refusals at `open_ncr.sql:70,80,86` are asked by no fixture); its header says both transfers cover the committed bucket, the `transfer_out` cell
does not.

**1.3 b · Usability on the deployed app** (clones of cco · cto · warehouse · finance · admin, `docs/surveys/MES-6b-2/mes6b1-closeout-pages.mjs`,
`PAGES_PROBE_EXIT=0`): NCR list, new (empty and with a batch chosen), `/output`, both batch pages, the sales order page — **35 fetches, all 200**;
`/output` 14 rows for every role. Live has no NCRs and no contracts, so on a local rebuild with my own data: NCR detail (three states), the hold banner
on both batch pages, the held reservation on the sales order, the contract's quality-limits section and basis field — **45 fetches**: each role saw
what its codes allow and was told the code where they do not (warehouse cannot enter sales or contracts, matching its codes).

**1.3 c · Self-taken decisions in `docs/handbacks/MES-6b-1.md` §8 (titles):** 1 One hold predicate, pure · 2 `quality_hold_reserved` narrowed to
`module.output.view` and widened to `module.sales.view` · 3 Quality limits travel inside the settlement-terms snapshot · 4 One system NCR per
breaching parameter · 5 Trigger names `…_unpenalised` / `…_unpriced` · 6 `QUALITY_HOLD_OPEN` translated once in the shared fallback · 7 F7 as one
component · 8 Contract penalty rows · 9 Supplement previews · 10 Trail labels for the new tables · 11 The prompt arm links to
`/quality/ncr/new?batch=<kind>:<id>` · 12 The decide form lists only waiting or approved money documents · 13 Constraint names mapped · 14 Migration
order · 15 Pre-window types were spliced from the local rebuild · 16 Local layout harness · 17 Live proof · 18 The proof's opener also holds the
decide code · 19 Settlement figures in the proof are checked by construction · 20 Smoke · 21 Downgrade and rework record only · 22 The gate's slow live
check was not rewritten.

**1.4 / 1.5** — no grant mismatch and nothing in a/b missing or broken, so step 2 started.

---

## §1 · Opening live readings (step 2, before anything changed)

Read 2026-10-15 19:03:24 CST as `postgres` (`rolbypassrls = true`), read-only, base tables and catalog
(`docs/surveys/MES-6b-2/opening-readings.sql`, `READ_OWN_EXIT=0`).

| Reading | Value |
|---|---|
| Output batches | 14 (not deleted) |
| Inbound batches · chemistry certainty | 15 · 1 `single_known`, 14 not recorded |
| Assays | 4, all inbound, all final · disputes 0 |
| Reservations · sales orders | 3 (0 open) · 6 |
| Certificates of destruction | 3 (2 issued) · `cod_issues` 2 |
| CoA objects | none (tables, views, functions, permission, document type, bucket all absent) |
| Storage buckets | 16 (`cod-documents` 2 objects; no `coa-documents`) |
| Warehouse requests | 0 · kind CHECK has 4 kinds |
| Approvals | ON — level 1 finance · level 2 cfo · threshold 1,000 |
| Accounts | 7, 0 disabled |
| Role code counts | admin 78 · auditor 20 · cco 45 · cfo 33 · cto 37 · employee 0 · finance 42 · gm 21 · hr 8 · operations 15 · procurement 16 · sales 17 · warehouse 29 |
| Catalogue | 78 codes, admin holds 78 · `action.issue_coa` held by no role · throwaway accounts 0 · `require_calibrated_since` NULL |
| Pending documents | 1 — expense claim CLM-2026-0004, 1,000.00 |
| change_log · document_types · public base tables | 33,825 rows, max seq 37,243 · 58 · 295 |
| Reconciliation (tim@) | AP 422,188.32 list / 381,604.42 ledger / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** |

## §2 · What was built

- **Tables.** `certificates_of_analysis` (code COA-YYYY-NNNN, gapless per year, minted at issue · output batch · optional sales order · governing
  assay · status issued / void · issued_at / by · frozen `snapshot` jsonb · void reason / when / by · `replaced_by_coa_id`; one live certificate per
  batch × order (or no order) by a partial unique index; read policy `module.output.view`; no write policy — functions only; a guard trigger allows
  exactly issued → void and then one replacement link) and `coa_issues` (one row per certificate: storage path under `<certificate id>/`, sha256;
  append-only). `warehouse_requests` gains kind `coa_void` and the column `coa_id` (column grant and `_masked` view in the same migration).
- **Functions.** `coa_governing_assay` (Q11 order) · `coa_output_calibration_problem` · `coa_issue_blockers` (Q29, in order) · `coa_assemble` (the one
  assembly) · `coa_certificate_data` (preview: the assembly plus the blockers, `module.output.view`) · `issue_coa` (`action.issue_coa`; refuses with
  the first blocker; issuer = the caller's employee, preferred name else legal name, position required; mints the number; freezes the snapshot;
  links the latest unreplaced void certificate of the same batch × order) · `record_coa_issue` · `submit_coa_void_request` · `void_coa_internal`
  (reachable only from the CFO request's execution). Warehouse-request engine extended for `coa_void` (submit, snapshot, touches, conflict, execute,
  withdraw). `next_coa_code`.
- **Views.** `output_batch_chemistry_certainty_all` (ungated, revoked from everyone) → `output_batch_chemistry_certainty` (owner rights,
  `module.output.view`) · `coa_rows` (the list, owner rights, `module.output.view`; customer short name else legal name — the label follows the
  document) · `operations_now` arm `coa_facts_changed` (66 arms).
- **Registries.** Permission `action.issue_coa` (declares `module.output.view`, `module.quality.view`) granted to admin and cco · document type `coa`
  → `COA` (`/quality/coa`) · trail subject `coa` and members under both batch subjects · change-log bindings for both tables · search registry ·
  reminders (`/quality/coa/[id]`) · bucket `coa-documents` (private, PDF only, 10 MB) with three policies: read `module.output.view`, upload
  `action.issue_coa`, delete `action.issue_coa` **and** only an object not yet recorded in `coa_issues` (no update policy).
- **App.** The batch page gains a certificates section (list, chemistry certainty, issue form with an optional order, live preview PDF, refusals named
  before pressing); `/quality/coa` list and `/quality/coa/[id]` detail (what the certificate stated, from the snapshot; download; void request);
  the sales order page lists its certificates; the inventory requests panel shows `coa_void` requests; the PDF route issues (with a pre-issue font
  check), streams stored bytes with a sha256 re-check (409 on mismatch) and previews. English-only PDF, one page for a typical certificate; each
  section is kept whole across a page break.
- **F6.** Wording arms ㉓–㉖ now read `titlePart`; each has a part-only fault (`wording-part-mes5b1/mes5b2/mes5b3/mes6a1`), ㉔ gained a sample that
  carries a part (a run's energy share) and ㉓ ㉕ ㉖ inject a fake part into a generic-family sentence; arm ㉙ for the certificate (6 sentences,
  faults `wording-drift-mes6b2`, `wording-part-mes6b2`).
- **Fold-in.** `db/gate.py` column-grant check in batches (see §0 1.2).
- **Fixtures.** New 264 (11 arms). Changed without weakening: 100 (58 → 59 prefixes, 35 → 36 numbering functions, `coa` / `COA` anchors), 101
  (50 → 51 declared gates), 111 (the 66th arm), 254 (58 → 59 document types). 264's comparisons were made null-safe during the injection run (§3).

## §3 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | Offline gate | `GATEOFF_EXIT=0`, 89 s — rebuild, B1/B2 rebuild side, every fixture, colgrant/colreader/xmodule rebuild side, swallow, currency, definer |
| 2 | Backup | first attempt died on a dead connection (server backend gone, local `pg_dump` asleep; terminated the local process, the script removed its partial file, `BACKUP_EXIT=1`); retried once at once: **`BACKUP_EXIT=0`**, `evoltrya-backup-2026-10-15-2023.dump`, 7.8 MB, 8,961 TOC entries (previous 8,857) |
| 3 | Dry run on live | pre-flight green (20 functions: 8 replaced, 12 new; 1 column on a masked table); 20:40:08–20:42:48 CST, the migration and its proof ran and were rolled back: `DRYPROBE\|permissions=79\|issue_coa=admin,cco\|doc_types=59\|tables=297\|coas=0\|bucket=1`; `DRY_OWN_EXIT=0` |
| 4 | apply_migration | **window start 2026-10-15 20:45:44 CST** (committed; `db/migration-windows.tsv`), `APPLY_OWN_EXIT=0`; proof inside the transaction: grants exactly admin + cco, admin 79/79, accounts and pending documents unchanged, pre-existing rows byte-identical, change_log moved by exactly 5, every pending document still has a decider |
| 5 | Types | `npm run types:gen` exit 0 — the generated file is 775 lines longer than my pre-window splice: relationship entries PostgREST infers through the two new views; generated file committed |
| 6 | tsc | `TSC_OWN_EXIT=0` (again after the route fix) |
| 7 | build | `BUILD_OWN_EXIT=0` (again after the route fix) |
| 8 | Full gate | **`GATE_EXIT=0`**, 614 s — all four verdicts green; colgrant live **478 relations · 12 batches · 39 column-listed tables, no gap**; types match live; GUCs match; anon surface a subset of the 328-line baseline |
| 9 | i18n | `I18N_OWN_EXIT=0` |
| 10 | Error swallowing | `SWALLOW_OWN_EXIT=0` (no new swallowing) |
| 11 | Layout | live, 5 changed pages with data (`/quality/coa`, a batch page, a sales order, `/inventory`, `/tools/reminders`) × 390 / 1280 px: **0 overflow · 0 clipped** (`S390_OWN_EXIT=0` · `S1280_OWN_EXIT=0`, self-test bit). Local rebuild with my own data (states live has none of: issued, void with replacement, waiting void request, the reminder): 9 pages × 390 / 1280: **0 / 0** (`H390_EXIT=0` · `H1280_EXIT=0`, self-test bit). PDF: a typical certificate with an order is 1 page; a worst case (10 substances, 7 indicators, limits) is 2 pages with the limits section moved whole and the statement + issuer kept together (it had first orphaned the issuer line, then a table header — both fixed) |
| 12 | Smoke | first run `SMOKE_EXIT=1`: it walked 214 routes with **0 failures**, then aborted on its own id query for `/quality/ncr/[id]` — `nonconformance_reports` has `opened_at`, not `created_at`, and MES-6b-1 registered it without an order key, so that query could never succeed; fixed with an order override (the other two tables without `created_at` already had one). Rerun **`SMOKE_EXIT=0`: 286 ok, 18 skipped (no data, including `/quality/coa/[id]` and `/quality/ncr/[id]`), 0 failed**. Scratch report: the same 6 stale rows from earlier cuts (1,038–1,681 h old, four still referenced), none of mine |
| 13 | Live verification | §4 |
| 14 | Fresh-clone build | run from the pushed commit, no `.env.local` — see the final report |

**Fault injection.** `db/scripts/2026-10-15-mes6b2-fixture-injections.py` on a fresh rebuild made after the last database edit (the migration):
**58 cells on fixture 264, every one red in its own arm, all 11 arms red at least once; 4 cells on 100 / 101 / 111 / 254, each red; clean runs
green** (`INJECTIONS_OWN_EXIT=0`). The first run found a real weakness in 264: three cells (issuer position dropped, N38 not frozen, customer
name dropped) did not go red because `x <> 'value'` is NULL, not true, when the field is missing — the assertions now use `IS DISTINCT FROM` and
`COALESCE`, and all three bite. Wording faults: the six faults each redden only their own arm (㉓ ㉔ ㉕ ㉖ ㉙ ㉙), clean run green.

## §4 · Live verification (rolled back; `db/scripts/2026-10-15-mes6b2-live-proof.mjs`, `MES6B2_PROOF_EXIT=0`)

One psql transaction held open from start to `ROLLBACK`, every action by a `mes6b2probe` throwaway (issuer with an employee row and position
inserted inside the transaction; the second approver holds the real cfo role; seven read-only clones of the real roles' codes). Between SQL steps
the driver rendered with the route's own `renderCoaPdf`, uploaded as the issuer through the Storage API, and read the stored PDF back with pypdf.

| Step | Reading |
|---|---|
| N38 | feeds single_known + mixed → **mixed** (2 leaves); + one not recorded → **not_recorded** (3 leaves); a reader without `module.output.view`: 0 rows; the base view refuses staff |
| Refusals | `COA_NO_FINAL_ASSAY\|OUT-2026-0715\|-` · `QUALITY_HOLD_OPEN\|OUT-2026-0716\|NCR-2026-0001` · `ASSAY_DISPUTE_OPEN\|OUT-2026-0717\|…`; no certificate left behind |
| Issue, no order | COA-2026-0001: governing assay ours, feed chemistry Mixed, issuer «Lim (probe), Quality Manager (probe)»; rendered from the returned snapshot (1 page) → uploaded by the issuer → sha256 recorded (sent upper-case, stored lower) → downloaded, sha matches → the paper says the number, batch, assay, "Issued by Lim (probe), Quality Manager (probe)", the company and "Mixed" |
| Issue, order with limits | contract with moisture ≤ 8 activated through the CFO; order reserved 500 kg → judged within; the pre-issue font check refused a customer name containing «≤» before anything was issued; COA-2026-0002 for SO-2026-0005: customer, contract, limit, judgement **within**; a second for the same batch × order refused `COA_ALREADY_ISSUED\|COA-2026-0002`; stored PDF says customer, order, contract, Moisture, Within limits |
| Frozen | customer renamed live → snapshot identical, stored bytes identical, the paper still says the old name; the preview (live data) says the new one |
| 409 | COA-2026-0001's bytes overwritten with the service role (stored size changed to the new length) → downloaded sha ≠ recorded sha → the route's 409 branch |
| Bucket policy | as the issuer, deleting COA-2026-0002's recorded object touches 0 rows; a reader without the code deletes 0; an unrecorded orphan: the issuer deletes it (in SQL, rolled back) and removes it through the Storage API (HTTP 200) |
| Void | a direct `void_coa_internal` as the issuer: permission denied; the issuer raised `COA-2026-0002 · void #1` → submitted, still issued; the issuer approving it: refused; the cfo throwaway approved → void, `voided_by` = the raiser, snapshot kept, bytes kept and still downloadable; reissued → COA-2026-0003, COA-2026-0002 → replaced by COA-2026-0003 |
| Reminder | a newer assay → `coa_facts_changed` lists COA-2026-0001 and COA-2026-0003 for the issuer (not the void one); a reader without the code sees 0 |
| Untouched | pre-existing rows identical (fingerprint over 34 tables and the settings); pending documents «expense_claim:CLM-2026-0004» unchanged; approvals on; `require_calibrated_since` NULL; reconciliation AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** |
| After | after ROLLBACK: certificates 0 · byte records 0 · coa_void requests 0 · probe rows 0; bucket: 0 entries (Storage API) · 0 rows in `storage.objects`; throwaway accounts 0 |

**Four failed attempts before the green one, all rolled back:** (1) a variable-name clash in the proof's own helper; (2) the proof opened its NCR
with source `inspection`, which is reserved (`NCR_SOURCE_RESERVED`); (3) **a product finding** — the contract title "(moisture ≤ 8)" contains a
character the PDF font cannot draw, and because the route issues first and renders second, the real app would have left an issued certificate with
no PDF. Fixed: the route now runs the same assembly through the font guard before issuing and refuses with nothing issued (shown on live in the
green run and locally through the route: HTTP 400, certificate count unchanged; a normal issue still stores its PDF). The residual (the issuer's
own name) is registered (`MES6B2-ISSUED-WITHOUT-BYTES`). In the same run the cleanup timed out deleting the issuer account because my still-open
transaction held its row lock — the driver now ends the transaction before cleanup; the account was removed by the next run's reaper. (4) the
tamper step read back the original bytes from the storage cache — downloads now carry a one-time query string and the stored size is read from
`storage.objects`. The reaper also counted the Storage API's 400 NoSuchKey for an already-removed object as a failure; planned object deletes now
use the bulk endpoint (200 when already gone), and the two stale plans were repaired the same way and reaped.

### Role table (clones of the seven real roles' codes after the migration, read-only)

| Role | Codes | Batch-page certificates | Certificate row | Byte record | Storage download | Issue | `coa_void` in the CFO request list | May raise a void |
|---|---|---|---|---|---|---|---|---|
| admin | 79 | 3 | 1 | 1 | yes | yes | 1 | yes |
| finance | 42 | 3 | 1 | 1 | yes | no | 1 | no |
| warehouse | 29 | 3 | 1 | 1 | yes | no | 1 | no |
| cto | 37 | 3 | 1 | 1 | yes | no | 1 | no |
| cco | 46 | 3 | 1 | 1 | yes | yes | 1 | yes |
| cfo | 33 | 3 | 1 | 1 | yes | no | 1 | no |
| gm | 21 | 3 | 1 | 1 | yes | no | 1 | no |

All seven hold `module.output.view` and `module.inventory.view`, so all see certificates and the request list; only admin and cco can issue or raise
a void; deciding a void goes by holding the cfo role (level 2), not by a code — the cfo throwaway with the real role decided it above.

## §5 · Pages new or changed (route → file)

| Route | File | What |
|---|---|---|
| `/quality/coa` | `app/quality/coa/page.tsx` (+ `CoaTable.tsx`) | new — the certificate list (gate: `module.quality.view` and `module.output.view`) |
| `/quality/coa/[id]` | `app/quality/coa/[id]/page.tsx` (+ `CoaContentTables.tsx`) | new — what the certificate stated (from its snapshot), download, void request, trail |
| `/output/[id]/coa/pdf` | `app/output/[id]/coa/pdf/route.tsx` | new — GET `?coa=` stored bytes with sha256 re-check (409), GET `?so=` preview, POST issue |
| `/output/[id]/edit` | `app/output/[id]/edit/page.tsx` + `CoaSection.tsx` · `CoaIssueForm.tsx` | changed — certificates section with chemistry certainty and the issue form |
| `/sales/orders/[id]` | `app/sales/orders/[id]/page.tsx` + `SalesOrderCoas.tsx` | changed — the order's certificates |
| `/inventory` | `app/inventory/page.tsx` + `WarehouseRequestsPanel.tsx` | changed — `coa_void` requests in the CFO request list |
| `/tools/reminders` | `lib/reminders.ts` | changed — the `coa_facts_changed` reminder |
| trail pages | `app/components/trail/AuditTrail.tsx`, `lib/trail/render.ts` · `text.ts` | changed — subject `coa`, certificate sentences on both batch trails |

## §6 · Decisions I took without asking

1. **Column-grant check batched** (40 relations per query, same predicate; a universe count > 0 and ≥ 20 column-listed tables, or it fails).
2. **N38 with no inbound leaves reads "not recorded" over 0 leaves**, and an unrecognised certainty code ranks below every known one and is reported as
   itself (a new dictionary value never makes a batch look more certain).
3. **N38 has an ungated base view** (`_all`, revoked from everyone) under the gated one — the certificate assembly reads the base, readers read the gate.
4. **The governing assay must be the latest one and final — no fallback.** If the latest live result of the governing party is preliminary, the
   certificate is refused naming it, rather than reaching past it to an older final one.
5. **An order whose contract names no settling party (or no contract at all) is governed by our latest result.**
6. **The certificate's judgement is the recorded one** (latest per parameter for that batch × order), not re-judged at issue; a breach clears only by
   an NCR on that judgement decided accept / accept_with_penalty (registered: `MES6B2-COA-JUDGEMENT-IS-THE-RECORDED-ONE`).
7. **The named order must have reserved or shipped the batch** (`COA_SALES_ORDER_NOT_FOR_BATCH`).
8. **Issuer name = preferred name, else legal name; a position is required** (`COA_ISSUER_NOT_AN_EMPLOYEE`, `COA_ISSUER_POSITION_MISSING`); a missing
   company legal name refuses too (`COMPANY_LEGAL_NAME_MISSING`) — the letterhead comes from the snapshot.
9. **A void request touches only the certificate** (`touches` = `coa`), so it never conflicts with batch write-offs or rollbacks.
10. **`/quality/coa` sits in the quality menu and needs both `module.quality.view` and `module.output.view`**; the batch-page section and the
    download follow the batch's view code alone (Q30).
11. **The inbound-batch trail reaches certificates one run deep** (inbound → run → output leg → output batch → certificate).
12. **A reissue links the latest unreplaced void certificate of the same batch × order**; the link is set once.
13. **Bucket delete policy only for objects not yet recorded** — so the route can remove its own orphan when recording the hash fails, and recorded
    bytes cannot be deleted by anyone through the API; there is no update policy.
14. **Pre-issue font check in the route** (found by the live proof): the same assembly is run through the font guard before `issue_coa`.
15. **"Rendered from the snapshot" is proved by text, not bytes** — react-pdf's font subset tags make two renders of the same snapshot differ in
    bytes, so the proof extracts the paper's text with pypdf and compares it with the snapshot (and the route never re-reads after issue).
16. **The PDF route file is `route.tsx`, which the smoke enumerator does not walk** (it walks `page.tsx` / `route.ts`) — same as the COD route; the
    route is covered by the live proof and the local test.
17. **Wording arm ㉙'s six sentences** and, for F6, the part-only fault reddens every entry of its arm that carries a part.
18. **Every PDF section is kept whole across a page break**, and the certifying statement stays with the issuer line.
19. **The live proof drives one open transaction from Node** (psql coprocess) because storage writes do not roll back; object deletions are planned
    before each upload through the shared throwaway helper, and the bucket is read back empty by two independent routes.
20. **Smoke prefix and skips:** `mes6b2probe` added to the throwaway prefixes; `/quality/coa/[id]` joins the expected skips (live has no certificates).
21. **Smoke's NCR id query ordered by `opened_at`** — a fix to MES-6b-1's smoke registration found by this cut's smoke (§3 row 12).
22. **Fixture 264's assertions made null-safe** (`IS DISTINCT FROM`, `COALESCE`) after the injection run showed three cells passing on NULL.


## §7 · Closing live readings

Read **2026-10-15 22:08:45 CST** as `postgres` (`rolbypassrls = true`), same query file as the opening (`READ_OWN_EXIT=0`); reconciliation in
tim@'s session (`db/scripts/2026-10-05-at1d3-live-recon.sql`, `RECON_OWN_EXIT=0`).

| Reading | Opening → closing |
|---|---|
| Certificates · byte records · `coa_void` requests | objects absent → **0 · 0 · 0** (tables, views, functions, code, document type and bucket now exist) |
| Bucket `coa-documents` | absent → private, **0 objects** |
| Output · inbound batches · assays · disputes · reservations · sales orders | 14 · 15 (1 single_known) · 4 · 0 · 3 (0 open) · 6 → **unchanged** |
| Certificates of destruction · `cod_issues` | 3 (2 issued) · 2 → **unchanged** |
| Approvals | ON, finance / cfo / 1,000 → **unchanged** |
| Accounts | 7, 0 disabled → **7, 0 disabled, 0 deleted** (same seven, same roles) |
| Role code counts | admin 78 → **79**, cco 45 → **46** (the two `action.issue_coa` grants); every other role unchanged |
| Catalogue · `require_calibrated_since` | 78 / admin 78 · NULL → **79 / admin 79 · NULL** |
| Throwaway accounts · probe roles | 0 · 0 → **0 · 0** |
| Pending documents | CLM-2026-0004 → **CLM-2026-0004 only** |
| document_types · public base tables | 58 · 295 → **59 · 297** |
| change_log since the opening (seq > 37,243) | the migration's **5** (permissions 1 INSERT + 1 UPDATE · role_permissions 2 · document_types 1) plus throwaway roles, grants, accounts, employees, probation reviews and scratch contracts from the surveys, the proof's accounts and smoke — every INSERT matched by a DELETE (roles 69 / 69 · user_roles 74 / 74 · role_permissions 1,893 / 1,891, the 2 being the migration's · employees 10 / 10 · reviews 4 / 4 · contracts 4 / 4 · contract term rows matched); the proof's own rows were rolled back and never logged |
| Reconciliation (tim@) | AP 422,188.32 / 381,604.42 / **0.00** · AR 57,545.87 / 43,002.12 / **0.00** → **identical** |

Nothing of mine remains in the database or in storage; nothing that existed before this session was decided, edited, reversed or deleted.

## §8 · Broken window

Start **2026-10-15 20:45:44 CST** (`db/migration-windows.tsv`). End: Tim's confirmation of the deployment. What breaks inside it (derived from the
migration, not measured): nothing the old app reads changed shape — `warehouse_requests` gained a column (all NULL) and a fifth kind the old app
never sees; the new tables, views, functions and bucket are unread by it; the old reminder page skips the unknown `coa_facts_changed` arm (0 rows).

