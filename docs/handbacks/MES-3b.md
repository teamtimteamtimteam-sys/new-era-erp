v1.4.40 — Labels and scanning: batch and location labels now print from a preview page with a choice of A6 or A5 template, every reprint asks for a reason and is recorded, warehouse labels show the material name again, the QR on a label opens the batch or location for anyone allowed to see it, materials can carry a UN dangerous-goods number and an HS code that appear on labels and shipping documents, and stock can be moved, fed and shipped by scanning a barcode with a handheld scanner or, on Android, the phone camera.

# MES-3b — labels and scanning (MES group, fourth cut; 2026-10-07)

Tim answered MES-3b Step 0 on 2026-10-07: every recommendation for Q0–Q31 in `docs/surveys/MES-3b/STEP0-HANDBACK.md` accepted exactly
as stated, with the two fold-ins (Q2: labels carry the material and supplier names through the print function, no grant change; Q3:
`nea_waste_categories` in `RUNTIME_CONFIG_TABLES` and `BOOTSTRAP_MAY_BE_EMPTY`, with one injected fault). Q0: the MES-3a ceilings
predicate stays as built — recorded as decision 21 in `docs/handbacks/MES-3a.md` §6.
Migration `db/migrations/2026-10-07-mes3b-labels-scanning.sql` (built from the mirrors by `db/scripts/build_mes3b_migration.py`).

---

## §1 · Role-by-role reading table (live, measured)

`db/scripts/2026-10-07-mes3b-live-role-table.sql`, run 2026-10-07 13:33 on live as `postgres` inside **one transaction that ends in
ROLLBACK** (`ROLES_OWN_EXIT=0`) — opening a short link writes a `scan_events` row, so this cannot be a READ ONLY transaction; those rows
vanished with the rollback (`scan_events` is 0 rows on live afterwards). The existing batch is the first `IN-` batch, **IN-2026-0001**
(material NMC Cathode Foil); the existing location is the first active one, **SG2026081201**. Each of the 7 real accounts is read as
`SET LOCAL ROLE authenticated` + that account's JWT (what PostgREST does per request).

| account | role | `/b/IN-2026-0001` | id returned | `/loc/SG2026081201` | id returned | label preview | material name on the label | print page (`module.inbound.view`) | `/inventory/scan` (`module.inventory.view`) | move by scan (`module.inventory.edit`) | DG dictionary (`module.materials.view`) | templates dictionary | V30 / V31 / V35 rows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| admin@swm-os.test | admin | found → batch page | yes | found → location page | yes | ok | NMC Cathode Foil | yes | yes | yes | yes | yes | 6 |
| chooer@evoltrya.test | finance | found → batch page | yes | found → location page | yes | ok | NMC Cathode Foil | yes | yes | yes | yes | yes | 6 |
| fusheng@evoltrya.test | warehouse | found → batch page | yes | found → location page | yes | ok | **NMC Cathode Foil** | yes | yes | yes | **no** | yes | **0** |
| phua@evolytra.test | cto | found → batch page | yes | found → location page | yes | ok | NMC Cathode Foil | yes | yes | yes | yes | yes | 6 |
| sandra@evoltrya.test | cco | found → batch page | yes | found → location page | yes | ok | NMC Cathode Foil | yes | yes | yes | yes | yes | 6 |
| tim@evoltrya.test | cfo | found → batch page | yes | found → location page | yes | ok | NMC Cathode Foil | yes | yes | no (shown, disabled) | yes | yes | 6 |
| vince@evoltrya.test | gm | found → batch page | yes | found → location page | yes | ok | NMC Cathode Foil | yes | yes | no (shown, disabled) | yes | yes | 6 |

How each cell was read: the two links = `resolve_scan_code('/b/<code>' | '/loc/<code>', 'lookup', 'link')` → `outcome` and whether an
`id` came back (`/b/` and `/loc/` redirect on `found`); label preview = `label_print_preview('inbound_batch', <id>)` (ok or its error);
material name = that preview's `data.material_name`; the permission columns = `has_permission(...)`; V30 / V31 / V35 = rows of
`pending_values` (as admin@: V30 ×4 · V31 ×1 · V35 ×1).
**What the table shows:** every real account may view batches and locations, so on live today nobody gets the restricted refusal — that
outcome (no id, the needed code named) is proved by fixture 252 LINK with a throwaway reader. The warehouse account, which holds no
`module.materials.view` (it cannot read the materials table — §5.1 step 2e reads 0 rows), sees the material name on the label (Q2). It does
not see V30 / V31 / V35 (they are behind `module.materials.view`, Q29). No grant changed in this cut.

---

## §2 · Every item built

**Tables (4 new):** `dangerous_goods_codes` (dictionary, RUNTIME CONFIG; seeded UN3480 · UN3481 · UN3090 · UN3091, class 9, with their UN
proper shipping names; marking text, packing instruction and label size **empty** — V30) · `label_templates` (dictionary of fixed shapes:
object kind × A6/A5 × DG line on/off; seeded six rows, an A6 and an A5 per kind) · `label_prints` (one row per print, **append-only**:
object, template, paper, copies, reprint flag and reason, QR path, printed-fields snapshot, who, when) · `scan_events` (one row per
resolve, **append-only**, **not change-logged**: context, method, raw value, parsed code, resolved kind, id only when found, outcome).

**Table changes:** `materials.dg_code` (FK to the DG dictionary; V35) and `materials.hs_code` (CHECK `materials_hs_code_shape`: 6–12 digits,
dots allowed between groups; V31) · `document_type_exceptions` +2 rows (the two dictionaries' `code` columns) · the change-log binding of
`nea_waste_categories` re-keyed `'id'` → `'code'` (a MES-3a defect, §6).

**Functions:** new `label_object_data` (internal: what a label prints — material and supplier names read as owner, Q2) ·
`label_print_context` (internal: kind, the object's own view code, found, template, prints so far) · `label_print_preview` (read-only) ·
`record_label_print` (copies; reprint needs a reason; writes the row; returns what to print) · `resolve_scan_code` (four ways of writing a
code, four outcomes, never raises, no id to a reader who may not view; writes `scan_events`) · `batch_quarantine_states` (internal) ·
`guard_append_only_log` (trigger). Changed: `ship_order` (optional `scanned_code` per line → `SHIP_SCAN_MISMATCH`) · `shipment_document`
(per line: DG code, class, names, `dg_missing`, HS code, quarantine states) · `shipping_queue_rows` (three trailing columns — return type
changed, so dropped and re-created; fixture 224 re-pinned) · `change_log_exclusions` (+`scan_events`) · `trail_subjects` (+2 dictionary
subjects) · `trail_subject_members` (+3: `label_prints` under inbound batch, output batch, storage location).

**Views:** `pending_values` +3 arms (10 → **13**): **V30, V31, V35**. `operations_now` unchanged (55 arms).

**Mirror-checker (fold-in Q3):** `nea_waste_categories`, `dangerous_goods_codes`, `label_templates` in `RUNTIME_CONFIG_TABLES`;
`nea_waste_categories` in `BOOTSTRAP_MAY_BE_EMPTY` with its reason.

**App:** the three print pages and the shared print screen; the two short-link pages; `/inventory/scan`; one `ScanField` used on the receipt
forms (location), the processing form (each input row), the reservation control and the shipping queue (verification); the material editor,
list and export (UN number, HS code); the two dictionaries (with a new `choice` field kind); the shipping queue, the shipment page and the
delivery note (DG, HS, quarantine flag); the labels line on batch and location pages; the audit trail (label prints, the two dictionaries;
`check-trail-wording` arm ⑱); English and Chinese for everything.

---

## §3 · Pages — every new or changed route, with its file

| route | what changed | files |
|---|---|---|
| **`/inbound/[id]/label`** (was a GET route handler) | print page: preview, template (A6 / A5), copies, reprint reason; Print records the print, then prints; `?template=` preselects | `app/inbound/[id]/label/page.tsx` (the old `route.ts` deleted), `app/components/labels/{LabelPrintScreen,LabelPrinter,labelHtml,actions,labelErrorCodes}.ts(x)` |
| **`/output/[id]/label`** (was a GET route handler) | the same, for output batches | `app/output/[id]/label/page.tsx` (old `route.ts` deleted), the same shared files |
| **`/inventory/locations/[id]/label`** (new) | the same, for storage locations (no DG line; "QUARANTINE LOCATION" when marked) | `app/inventory/locations/[id]/label/page.tsx`, the same shared files |
| **`/b/[code]`** (new) | batch short link: signed out → login and back; may view → the batch page; may not → a named refusal (what the code is, which code is needed); unknown → "No batch has the code …" | `app/b/[code]/page.tsx`, `app/components/scan/ShortLinkScreen.tsx`; nav exception in `scripts/check-nav-routes.mjs` |
| **`/loc/[code]`** (new) | location short link, the same four outcomes | `app/loc/[code]/page.tsx`, `ShortLinkScreen.tsx` |
| **`/inventory/scan`** (new) | scan a batch → its stock by location and status → pick or scan the source → scan the destination → move (`create_stock_transfer`); "your recent scans" | `app/inventory/scan/{page,ScanTransfer,actions}.ts(x)`, `app/components/scan/{ScanField,actions}.ts(x)`; registry `lib/modules.ts` |
| `/inbound/receive`, `/inbound/new`, `/output/new` | location picker gets a scan field; weighbridge ticket by typed / scanned `WB-` number | `app/components/inventory/LocationPicker.tsx`, `app/inbound/TicketShareFields.tsx` |
| `/operation/processing/new` | a scan field on each input row selects the batch | `app/operation/processing/new/NewProcessingForm.tsx` |
| `/sales/orders/[id]` | reservation: a scan narrows the buckets to the scanned output batch (one bucket → selected) | `app/sales/orders/[id]/ReserveControl.tsx` |
| `/logistics/shipping` | per line: UN number or "DG code not set"; per reservation: the open quarantine state (flagged, not refused); an optional verification scan (match / mismatch shown; sent to `ship_order`) | `app/logistics/shipping/{page,ShipQueueControl,actions}.ts(x)`, `app/sales/orders/salesOrderErrorCodes.ts` |
| `/sales/shipments/[id]` and its delivery note PDF | a "Dangerous goods / HS" column (UN number · class, or "DG code not set"; HS; open quarantine state); the PDF prints the same under each material, in English | `app/sales/shipments/[id]/{page,ShipmentLinesTable}.tsx`, `pdf/{route,DeliveryNoteDocument}.ts(x)` |
| `/inbound/[id]/edit`, `/output/[id]/edit`, `/inventory/locations/[id]/edit` | a "Labels" line: printed n times, first date, last reprint and reason, a link to the print page; label prints on the audit trail | `app/components/labels/LabelPrintHistory.tsx`, the three pages, `lib/trail/{render,text}.ts` |
| `/materials`, `/materials/new`, `/materials/[id]/edit`, `/materials/export` | UN dangerous-goods number (picker, "Not set") and HS code; a "UN / HS" list column; two trailing export columns | `app/materials/{DgHsFields,dgOptions,dgQuery,MaterialsTable,page,materialErrorCodes}.ts(x)`, `new/*`, `[id]/edit/*`, `export/route.ts` |
| `/settings/dictionaries` | two dictionaries (UN dangerous-goods numbers; label templates) and a `choice` field kind | `app/settings/dictionaries/{registry,DictSection,actions,page}.ts(x)`; `lib/modules.ts` (`P_DICTIONARIES` + `module.inventory.view`) |
| `/settings/pending-values` | V30, V31, V35 | `messages/{en,zh}.ts` (the page itself unchanged) |

---

## §4 · Verification, in the brief's order

Logs are in `~/mes3b-work/logs/` (outside the repo).

| # | step | result | log |
|---|---|---|---|
| 1 | offline gate | first run `GATEOFF_EXIT=4`: fixture 103 (the new `label_prints` constraint read as a false inbound↔output "bridge" — split into the `num_nonnulls(...) = 1` shape plus `label_prints_kind_matches`, decision 18) and fixture 252 (a scanned value with a trailing newline was not trimmed — `btrim(x, E' \t\r\n')` in `resolve_scan_code` and `ship_order`; and the fixture's own LOG count and reserve set-up). Then `GATEOFF_EXIT=0` ×2 (72 s, 70 s) | `gate-off0.log`, `gate-off1.log`, `gate-offline.log` |
| — | Q3 fault | `nea_waste_categories` taken out of `BOOTSTRAP_MAY_BE_EMPTY` → `GATEOFF_EXIT=1`, the `bootstrap` line naming it; restored | `gate-off-q3inject.log` |
| — | fixture injections | `db/scripts/2026-10-07-mes3b-fixture-injections.py`: **38 cases, every one red in its named arm of fixture 252** (`INJECTIONS_OWN_EXIT=0`); plus `check-trail-wording` arm ⑱ fault `wording-drift-mes3b` → exit 1 | `injections.log`, `trail-wording-inject.txt` |
| — | dry run of the migration file (COMMIT → ROLLBACK) | `DRY_OWN_EXIT=0` ×2 | `dryrun.log`, `dryrun2.log` |
| 2 | backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-10-07-1143.dump`, 6.4 MB, 7,890 TOC entries; 11:43 → 11:53. Before applying I re-read live: `change_log` 10,650 rows / max seq 12,048, identical to the before readings | `backup.log` |
| 3 | apply_migration | `APPLY_OWN_EXIT=0`. **Window start 2026-10-07 11:56:14 CST** (`db/migration-windows.tsv`) | `apply.log` |
| 4 | generate types | `TYPES_EXIT=0` (after the migration's `NOTIFY pgrst`) | `types.log` |
| 5 | tsc | first run: a stale `.next` validator still named the deleted label `route.ts` files (→ `.next` removed) and a `mustOne` result read as nullable in the scan actions (→ throws); then `TSC_EXIT=0` | `tsc.log` |
| 6 | build | `BUILD_OWN_EXIT=0` (the static checks had been made green before the migration: deep-routes regenerated, a CJK glyph in the label body, a masked read, a dropped auth error, component-library className, a raw `<button>`, two nav exceptions, a lint `set-state-in-effect`) | `build.log`, `static0.txt` |
| 7 | full gate | `GATE_EXIT=0`, 450 s (12:40 → 12:49) — rebuildable ✓ · mirrors vs live ✓ · fixtures ✓ (252 ✓) · anon surface ✓ (baseline 328) | `gate-full.log` |
| 8 | i18n | `I18N_EXIT=0` — every key in en and zh; 241 dynamic prefixes, all enumerable | `i18n.txt` |
| 9 | error swallowing | `SWALLOW_EXIT=0` | `swallow.txt` |
| 10 | layout survey, 23 pages (§3's routes, the three print pages at A6 and again with `?template=…_a5`, and the edit pages carrying the labels line) | **1280 px 23 / 23 usable**; **390 px 22 / 23 usable** — `/operation/processing/new` overflows +177 px (culprit: the batch `<select>`). **Pre-existing:** the same survey of the HEAD version of `NewProcessingForm.tsx` reads the same +177 px (`survey390-before-processing.log`), so it is not from this cut and is reported, not fixed. `SURVEY_EXIT=0` ×3; `.next` removed before each | `survey390.log`, `survey1280.log` |
| — | label paper size | the print document rendered by `chrome-headless-shell --print-to-pdf`: **A6 = 148.2 × 105.2 mm, A5 = 209.9 × 148.2 mm**, one page per copy | — |
| 11 | smoke | first run stopped by me at 13:06 (`SMOKE_EXIT=143`): every route 500 because `next dev` could not fetch the Google font at its first compile (`Can't resolve '@vercel/turbopack-next/internal/font/google/font'`) — not app code; its throwaway account, role and grants were removed (live read straight after: 0 throwaway accounts, 0 probe roles). Google Fonts answered (HTTP 200, 1.5 s), so retried once at once: **`SMOKE_EXIT=0` — 270 ok, 12 skipped, 0 failed**, 13:07 → 13:30. `/b/[code]` and `/loc/[code]` skipped by design (decision 28) | `smoke.log`, `smoke-attempt1-fonts.log` |
| 12 | live verification | §5 | |

**Scratch cleanup reading (step 11).** `check:scratch` before the first smoke run and after the second reads the **same six** stale rows,
all weeks old and none from this session: materials `ZZ-SMOKE-PROBE` (1,480 h, referenced by 1 inbound batch), `ZZ-SMOKE-M25` (1,480 h,
1 inbound + 2 output), `ZZ-SMOKE-NTF` (1,313 h, 2 inbound), supplier `ZZ-SMOKE-S25` (1,480 h, 1 inbound), customer `ZZ-SMOKE-CJK` (838 h,
unreferenced), inbound batch `ZZ-SMOKE-IB25` (1,480 h, 1 processing input). Reported, not removed (the check's rule). Both smoke runs' own
throwaway account, role and grants were removed: after them live has 7 accounts, 0 throwaway, 0 grants without an account.

**Security proof — fixture 252, 12 arms** (PRINT · GATE · NAME · LINK · RESOLVE · LOG · MOVE · SHIP · DG · HS · QUAR · PV), each
fault-injected (above). Coverage against the brief: `record_label_print` first print / reprint refused without a reason / reprint with a
reason and what each row records (PRINT); the label carrying material and supplier names for a reader without `module.materials.view`
(NAME — with a control read proving that reader gets zero material rows directly); `/b/` and `/loc/` signed out · may view · may not view ·
unknown code · an old edit-page URL (LINK); `resolve_scan_code` outcomes including restricted, and no id to a reader who may not view
(LINK, RESOLVE); `scan_events` append-only and excluded from the change log (LOG); the transfer path — a source location holding none of
the batch refused, `create_stock_transfer`'s refusals including MES-3a quarantine unchanged (MOVE); `SHIP_SCAN_MISMATCH` and shipping
without a scan still allowed (SHIP); the DG warning on a battery material with no code, DG data on the shipment document and the shipping
queue (DG); the HS format check (HS); the quarantine flag on the shipping queue and delivery-note data with no refusal (QUAR); V30, V31,
V35 (PV). Fixture 224 re-pinned for the three new `shipping_queue_rows` columns; fixture 235's excluded count 7 → 8.

---

## §5 · Live verification

### §5.1 · Rolled-back proofs — `db/scripts/2026-10-07-mes3b-live-proof.sql` (`PROOF_OWN_EXIT=0`, one transaction, ROLLBACK)

Approvals stayed ON throughout. Everything the proof used it made itself (`ZZ-PROBE-MES3B-*`: two materials, two locations, a supplier, a
customer, and the batches, order, invoice, release and shipment that grew from them). The probe supplier was inserted as the owner, as
set-up, the same as the MES-3a proof did: a real account's direct insert must be a draft (`guard_supplier_direct_write`), and sending it for
approval would leave a document waiting for someone's decision. After the ROLLBACK the script re-reads: probe materials 0, `label_prints`
0, `scan_events` 0. Two earlier attempts stopped on set-up errors before any step completed (the supplier insert above; the probe customer
needed a default tax code — `TAX_CODE_REQUIRED|customer`, given `ZR`); each aborted transaction left nothing (`live-proof-attempt1.log`,
`-attempt2.log`).

| step | who | action | result |
|---|---|---|---|
| 1 | admin@ | HS code `85493` (five digits) on my own battery material | refused — `materials_hs_code_shape` |
| 1 | admin@ | DG `UN3480`, HS `8549.31.00` on it | set |
| 2a | fusheng@ (warehouse) | receive 200 kg into L1 (IN-2026-0487); first print | print 1, not a reprint, template `inbound_a6`, material "MES-3b probe battery packs", DG UN3480 |
| 2b | fusheng@ | reprint with no reason | `LABEL_REPRINT_REASON_REQUIRED\|IN-2026-0487` — nothing written |
| 2c | fusheng@ | reprint with a reason, A5, 2 copies | print 2, reprint, `inbound_a5`, copies 2 |
| 2d | — | `label_prints` for the batch | 2 rows: `inbound_a6/A6/1/false/-` ; `inbound_a5/A5/2/true/MES-3b live proof: label smudged` |
| 2e | fusheng@ | read the material directly; read the label preview | 0 rows; the label shows material "MES-3b probe battery packs" and supplier "MES-3b probe supplier" |
| 3a | fusheng@ | scan `in-2026-0487` (lower case, keyboard), `ZZ-PROBE-MES3B-L1` (keyboard), `/loc/ZZ-PROBE-MES3B-L2` (camera) | batch found · L1 found · L2 found, the ids those scans returned |
| 3b | fusheng@ | move 50 kg L1 → L2 with the scanned ids (`create_stock_transfer`) | L1 = 150, L2 = 50 |
| 3c | — | `scan_events` rows from those scans | 3 |
| 4a | sandra@ (cco) | customer, order for 20 kg of my own output batch OUT-2026-0674, confirm; chooer@ (finance) invoices; sandra@ asks for the shipping release | `submitted` |
| 4b | tim@ (cfo) | decides the release | `approved` |
| 4c | sandra@ reserves; fusheng@ reads the shipping queue | | the row: batch OUT-2026-0674, DG code none, **DG missing true** (a battery material with no UN number), quarantine — |
| 4d | fusheng@ | ship with a mismatching scan (`IN-2026-0488`) | `SHIP_SCAN_MISMATCH\|IN-2026-0488\|OUT-2026-0674` — no shipment row |
| 4e | fusheng@ | ship with a matching scan (`OUT-2026-0674`) | shipment SHP-2026-0002, 1 line, order `shipped` |
| 4f | — | `shipment_document` line | batch OUT-2026-0674, DG missing true, HS — |

The codes printed (IN-2026-0487/0488, OUT-2026-0674, SHP-2026-0002) were taken from sequences inside the rollback; no document carries them.
Steps 3 and 4 are the database half of two screens: `/inventory/scan` resolves the three scans and calls `create_stock_transfer` with the
ids they returned (step 3); the scan field on `/logistics/shipping` sends `scanned_code` to `ship_order` (steps 4d–4e).

### §5.2 · Read-only

- **A batch label as the warehouse account:** §1 — material name "NMC Cathode Foil" for IN-2026-0001 as fusheng@, who reads 0 material rows
  directly (step 2e is the same fact on a probe batch).
- **`/b/<code>` and `/loc/<code>` for an existing batch and location as each of the 7 real accounts:** §1 (inside a rollback, because each
  resolve writes a scan row).

### §5.3 · Before and after

Before: 2026-10-07 10:30:49 (`~/mes3b-work/logs/before.txt`); after: 2026-10-07 13:34:01 (`after.txt`, `after-mes3b.txt`); same query
(`db/scripts/2026-10-06-mes1-live-readings.sql`, row count + digest of every public base table, as `postgres`, `rolbypassrls = true`) plus
`db/scripts/2026-10-07-mes3b-live-readings.sql`.

- **Every pre-existing table identical** except the three below.
- `materials`: digest changed only because it has two new columns; recomputed over its **pre-MES-3b columns** it is `e1d3980fbc9d` —
  **equal to before**. No material has a UN number (0) or an HS code (0).
- `document_type_exceptions` 38 → 40: the migration's two rows.
- `cod_verification_failures` 1 → 1, digest changed: the public verification page's failure budget (not a document); the smoke's `/verify`
  probe rotated its single row (one DELETE + one INSERT in the change log), as at MES-3a.
- New tables: `dangerous_goods_codes` 4 (the seed: UN3090/3091/3480/3481, class 9; marking, packing and label size empty on all four) ·
  `label_templates` 6 (the seed) · `label_prints` 0 · `scan_events` 0.
- `change_log` 10,650 → 11,499 rows (max seq 12,048 → 12,988; sequence gaps are the rolled-back transactions): the migration's 2
  `document_type_exceptions` rows, the `/verify` rotation, and the throwaway set-up and teardown of the three surveys and the two smoke
  runs — **balanced in every table** (roles 5/5, user_roles 5/5, employees 12/12, role_permissions 375/375, performance_reviews 5/5 (+5
  updates), contracts 4/4 and their six child tables 2–4 each way). Nothing of mine remains.
- **Nothing set by this cut beyond the seeds:** DG codes on materials 0 · HS codes 0 · DG marking/packing/size 0 · MES-3a categories 0 ·
  ceilings 0 · dwell periods 0 · quarantine locations 0 · **`require_calibrated_since` NULL**.
- **Accounts:** 7, 0 disabled, 0 throwaway, `roles` and `user_roles` digests equal to before (admin · finance · warehouse · cto · cco · cfo ·
  gm); approvals ON; 0 grants without an account.
- **Pending documents:** 1, CLM-2026-0004 1,000.00 — unchanged; its decider (tim@) is not its submitter. I leave no pending document.
- **Reconciliation** (as tim@): AP list 422,188.32 / ledger 381,604.42 / **unexplained 0.00**; AR 57,545.87 / 43,002.12 / **0.00** —
  identical to before.

### §5.4 · Broken window

Start **2026-10-07 11:56:14 CST** (measured, `db/migration-windows.tsv`). End = the moment Tim sees the deployment succeed on Vercel (a
report from Tim, to be recorded at the next close-out). Everything from step 4 on ran inside the window. What is broken in it
(**derived**, not measured on live): nothing. What the old app reads changed only by addition — three more columns from
`shipping_queue_rows`, more keys per `shipment_document` line, two more `materials` columns — and `ship_order`'s new key is optional; the
old label route handlers read `inbound_batches` / `output_batches` with their material and supplier, unchanged, so they still print (without
recording a print and without a DG line) until the deploy replaces them.

---

## §6 · Decisions taken without asking

1. **Six seeded templates, not three:** an A6 and an A5 for each of inbound batch, output batch and storage location (the location ones
   with the DG line off). Q5 named A6 as the default; A5 is the alternative the brief's survey asked for.
2. **`label_prints` is a trail member of all three subjects; its home is the inbound batch** (`home = false` under output batch and
   storage location). The location page's trail routes label prints to the location renderer.
3. **The stored QR path is unencoded and relative** (`/b/<code>`, `/loc/<code>`); the browser adds its own origin when it draws the QR,
   so a label printed on a preview deployment opens that deployment.
4. **Print = record, then print through an off-screen iframe;** the preview is the same HTML, zoomed to fit. Nothing prints if the record
   is refused.
5. **The labels line on a batch page does not name who printed;** the audit trail does.
6. **`scan_events.method` has a third value, `link`,** for a short link opened from a QR (Q20 named keyboard and camera).
7. **A signed-out `/b/` or `/loc/` visit is not logged** — there is no user to write `scanned_by`.
8. **A deleted batch resolves as `unknown`,** not restricted.
9. **Codes:** batch codes match case-insensitively; location codes exactly, then case-insensitively only if that is unique.
10. **`/b/` resolves only batches and `/loc/` only locations;** a bare code tries batches first.
11. **`label_print_preview` and `record_label_print` carry an outer "any of the three view codes" check** (the definer caller-check
    scanner requires one in the body); the exact per-object check is in `label_print_context`.
12. **No upper bound on copies** (≥ 1 only).
13. **The DG dictionary's English names are the official UN proper shipping names in capitals;** the Chinese names are my translations.
14. **HS codes:** 6–12 digits, dots allowed only between digit groups (`materials_hs_code_shape`).
15. **The delivery note prints DG / HS / quarantine as sub-lines under each material, in English** (the document is English), quarantine
    with the state names.
16. **The shipping queue gained three columns** (`dg_code`, `dg_missing`, `quarantine_states`), not two — §7.
17. **The `nea_waste_categories` change-log binding was re-keyed `'id'` → `'code'`** (a MES-3a defect: 1 of 252 bindings whose key was not
    the table's primary key), and the migration's proof now asserts every binding's key equals its PK.
18. **`label_prints`' one-object constraint is written `num_nonnulls(...) = 1`, with the kind match a separate constraint** — the shape
    `document_relations`' XOR detection recognises (fixture 103 had read the first draft as a false bridge).
19. **A `choice` field kind in the dictionary editor** (object kind, paper size and DG class are fixed lists).
20. **`P_DICTIONARIES` widened by `module.inventory.view`** so the label-templates dictionary is reachable by whoever edits it; measured:
    no live role gains entry (every role that holds `module.inventory.view` already reached the page).
21. **The label's code is set at 8.5 units** (11 wrapped a 13-character code on A6 — screenshot-checked).
22. **The print pages take `?template=`** to preselect A5 (used by the survey, and by a bookmark).
23. **A weighbridge ticket is matched by its typed or scanned `WB-` code on the client** from the list the form already loads.
24. **The receipt scan is also on `/output/new`** (it shares `LocationPicker`).
25. **`ship_order`'s `scanned_code` is trimmed and compared case-insensitively.**
26. **The materials list gained a "UN / HS" column and the export two trailing columns.**
27. **The two label route handlers were replaced by pages** (a GET must not write, and printing now writes).
28. **Smoke and the layout survey skip `/b/[code]` and `/loc/[code]`:** opening them writes an append-only `scan_events` row that nothing
    can delete. They are proved by fixture 252 LINK and by §1's role table (inside a rollback). `EXPECTED_SKIPS` carries the reason.
29. **A location's in-use and quarantine flags come back only when it is found** (not to a restricted reader).
30. **Wording I wrote:** the print screen, the labels line, the scan field and `/inventory/scan`, the short-link refusals, the DG / HS
    fields and their hints, the shipping-queue and shipment DG / quarantine lines, the delivery-note sub-lines, the two dictionaries, the
    error texts, and V30 / V31 / V35's "supplied by" lines (from Step 0).

---

## §7 · Assertions measured and found false or imprecise

1. **MES-3a's change-log binding for `nea_waste_categories` used key `'id'`** — the table's key is `code`. Fixed here (decision 17).
2. **Step 0: "two trailing columns" on `shipping_queue_rows`.** It is three (`dg_code`, `dg_missing`, `quarantine_states`).
3. **Step 0's function name `label_data_preview`.** Built as `label_print_preview` (read) + `label_print_context` and `label_object_data`
   (internal).
4. **Step 0: the dictionaries' existing text kinds would carry the templates.** They do not — fixed lists needed the `choice` kind.
5. **The 390 px overflow on `/operation/processing/new`** is not from this cut (§4 step 10).

---

## §8 · Docs updated

`docs/forward-queue.md` (item 39: MES-3b closed; MES-4a next; the MES group table) · `docs/handbacks/MES-3a.md` (§6 decision 21) ·
`docs/mes-pending-values.md` (V30, V31, V35) · `docs/change-log.md` (§15: `scan_events` excluded; `label_prints` and the two
dictionaries captured) · `docs/role-matrix.md` (labels and scanning row — no grant change) · `docs/known-issues.md` (CODE-WIDTH-4 note) ·
`docs/surveys/AUDIT-TRAIL-0/labels.csv` (trail labels for the new tables and columns).
