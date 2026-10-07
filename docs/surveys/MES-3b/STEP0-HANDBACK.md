# MES-3b Step 0 — hand-back (2026-10-07)

**Contents:** the MES-3a close-out, item by item §0 · what grilling changed §1 · the design (a)–(h) §2–§9 · the time estimate (i) §10 ·
every open question §11 · assertions found false or imprecise §12 · stop §13.

**STOP GATE.** No code edit, no migration, no live write. The only writes are docs: the close-out (`8bf70218`: `docs/forward-queue.md`
item 38, `docs/handbacks/MES-3a.md` §5.4), this file and `docs/surveys/MES-3b/live-readings.sql`. Waiting on Tim's answers to Q0–Q31 (§11).

**Opening check.** First command **2026-10-07 10:08:13 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
**`34d7690b501e7f9a5751f61dd5df9be0a8861dbd`** (MES-3a, v1.4.39). Files staged by explicit path only.

**How the facts were gathered.** Four read-only sub-agents (labels and QR; DG marks, HS codes and shipping documents; the four scanning flows;
cut-duration calibration from the session transcripts and `~/mes3a-work/logs/` file times). None connected to a database or ran a build. I
re-read every load-bearing claim at its file:line before using it (the label QR payload, the material-name gap, the absence of safety checks
in `ship_order` / `reserve_stock_internal`, the absence of a quarantine check in `commit_processing_run`, `nea_waste_categories` in
`db/check_mirrors.py`, the batch-code `LPAD`). Live readings I took myself (§0.2). Tags: **[M]** measured (file:line read, an exact grep, or a
live query in `live-readings.sql` with its identity) · **[I]** inferred from code reading · **[Q]** quoted from an earlier hand-back.

---

## §0 · Step 1 — the MES-3a close-out

### §0.1 · Broken window — closed (`docs/forward-queue.md` item 38)

| | time (CST) | source |
|---|---|---|
| start | **2026-10-07 09:07:01** | measured — `db/migration-windows.tsv:221` (`2026-10-06-mes3a-storage-safety.sql`) |
| end, lower bound | **2026-10-07 09:49:19** | measured — `git reflog show --date=iso refs/remotes/origin/main`: `34d7690b … {2026-10-07 09:49:19 +0800}: update by push` |
| end, upper bound | **2026-10-07 10:08:13** | this session's first command (`date`), holding Tim's "deployed" — **a report, not a Vercel reading**; it also stands for the remote reading the MES-3a session could not take |
| **window** | **42 min 18 s – 1 h 01 min 12 s** | |

What was broken in it (derived, MES-3a Step 0 Q33, not measured on live): the output batch page's safety panel could not add or end a state;
the intake panel could not un-tick one; new refusal codes showed raw. The two live state rows were still open at the ~09:50 after-reading.

### §0.2 · Live readings (read-only)

`docs/surveys/MES-3b/live-readings.sql`, one `BEGIN READ ONLY … ROLLBACK` block, session `default_transaction_read_only = on`; psql to the
pooler **as `postgres`, `rolbypassrls = true`, base tables** (identity line: `postgres | t | on | 2026-10-07 10:14:57`; `LIVE_OWN_EXIT=0`).

| reading | result [M] |
|---|---|
| accounts | 7, **0 disabled**: admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm |
| approvals | ON, level 1 `finance`, level 2 `cfo`, threshold 1000 |
| MES-3a state | NEA categories **0** · ceilings **0** · quarantine locations **0** · dwell periods **0** · `require_calibrated_since` **NULL** |
| `module.materials.view` | admin · auditor · cco · cfo · cto · finance · gm · operations · procurement · sales — **not warehouse** |
| `module.suppliers.view` | admin · auditor · cco · cfo · cto · finance · gm · procurement · warehouse (not operations, sales) |
| `module.inventory.view` / `.edit` | view: 11 roles incl. warehouse · edit: admin · cco · cto · finance · operations · sales · warehouse |
| `module.logistics.view` | 11 roles incl. warehouse · `action.ship_goods`: admin · warehouse · `action.receive_goods`: admin · warehouse |
| `module.processing.edit` | admin · cco · cto · operations (not warehouse) |
| permission codes | 75 |
| materials | 5 live (7 rows): **1 `battery_material`** (`has_condition_axes`), 1 `packaging`, 3 with no kind |
| batches | inbound 15 live (24 rows), codes `IN-2026-0001` … · output 14 live (20 rows), `OUT-2026-0001` … `OUT-2026-0381`; **0 codes shared** between the two tables |
| shipments | 3 shipments, 1 shipment line |
| `ingest_data_classes.scan` | present: "Scan events (MES-3b)", `transform_function` **NULL**, `manual_entry_code` NULL, `creates_draft` false |
| `document_types` | 43 rows |
| storage locations | 4 (1 active), columns end `zone, is_active, is_quarantine` |

### §0.3 · Items a–h, read-only

**a. `/inventory/storage-safety` exists, sections filtered by their own permissions — PRESENT** [M].
- `app/inventory/storage-safety/page.tsx:36` `const denied = await requireModule(MOD.inventory)`; the three sections read three owner-rights views,
  each with its own predicate:
  - `db/views/storage_ceiling_status.sql:67` `WHERE has_permission('module.suppliers.view'::text) OR has_permission('module.inventory.view'::text);`
  - `db/views/safety_state_dwell.sql:46` `… AND has_permission('module.inbound.view'::text)` · `:60` `… has_permission('module.output.view'::text)`
  - `db/views/quarantine_exposure.sql:35` `has_permission('module.inbound.view'::text)` · `:52` `has_permission('module.output.view'::text)`
- **One difference from Q32's letter**, not among `docs/handbacks/MES-3a.md` §6's decisions: Q32 said "ceilings `module.suppliers.view`"; the
  view admits **suppliers.view OR inventory.view** (its header `:6` gives the reason: the licence side or the stock side). Measured effect on
  live: none — all 7 accounts hold `module.suppliers.view` (§0.2); the widening reaches only `operations` and `sales`, which no live account
  holds. It matches the `storage_ceiling_exceeded` arm's `module.inventory.view` (Q13). → **Q0.**

**b. Dwell line on batch pages; the three reminder arms — PRESENT** [M].
- `app/components/safety/SafetyStateHistory.tsx:70-74` — each open state: `recorded {date} · {days} days on site` · `warning period {n} days` /
  `warning period: Not yet set` (`messages/en.ts:10412-10414`), amber + "past its warning period" when `dwell_status = 'past'` (`:65-68`).
  Mounted on `app/inbound/[id]/edit/page.tsx:904` and `app/output/[id]/edit/page.tsx:481`.
- `db/views/operations_now.sql:609` `'storage_ceiling_exceeded'` (`module.inventory.view`) · `:619` `'safety_state_dwell'` (inbound / output view by
  row) · `:632` `'quarantine_required'`; `grep -c "AS item_type"` = **55**. `lib/reminders.ts:235-243` renders all three.

**c. Q3 — direct insert on stock movements dropped, refuses `MOVEMENTS_THROUGH_FUNCTION_ONLY` — PRESENT** [M].
- `db/migrations/2026-10-06-mes3a-storage-safety.sql:478` `DROP POLICY "inventory_movements insert by permission" ON public.inventory_movements;`
- `db/tables/inventory_movements.sql:123` "RLS: authenticated may SELECT only"; `:134-136` `trg_inventory_movements_through_function BEFORE INSERT`.
- `db/functions/guard_movement_direct_insert.sql:17-18` `IF row_security_active(TG_RELID) THEN RAISE EXCEPTION 'MOVEMENTS_THROUGH_FUNCTION_ONLY|%'`.
- Fixture 251 arm MOVE (`db/fixtures/251-…sql:483-490`): a hand-built transfer pair as a session user must fail with exactly
  `MOVEMENTS_THROUGH_FUNCTION_ONLY|transfer_out`.

**d. Fold-in 1 — calibration rule restored; Q26 wording — PRESENT** [M].
- `db/functions/assert_receipt_reading_calibrated.sql:38` `v_applies := v_since IS NOT NULL AND (…created_at…)::date >= v_since;`
  `:46-49` `NOT_RECORDED` raises only `IF v_applies`; `:50-51` any other non-`in_calibration` status raises
  `READING_INSTRUMENT_NOT_CALIBRATED` **unconditionally**; `:54-55` `RECEIPT_READING_NOT_RECORDED` only `IF v_n = 0 AND v_applies`.
- Callers: `reprice_inbound_batch.sql:46`, `preview_reprice_inbound_batch.sql:26`, `issue_cod.sql:50`.
- Fixture 250 GATE, switch NULL (`db/fixtures/250-…sql:584-605`): `b_bad`, `b_old` refused by the preview **and** pricing with
  `READING_INSTRUMENT_NOT_CALIBRATED|<never>|<d>`; `cod_bad` refused by `issue_cod`; `b_none`, `b_unl`, `b_oldn`, `b_oldu`, `cod_none`, `cod_unl`
  pass. Switch on (`:618-640`): `NOT_RECORDED` and `RECEIPT_READING_NOT_RECORDED` refused for receipts on/after the date.
- `ruleOffHint` verbatim as Q26 — en `messages/en.ts:10158` "The calibration switch is off: a reading from an instrument out of calibration is
  still refused; a missing instrument or a receipt with no weighing is only shown." · zh `messages/zh.ts:9926` 「校准开关关着:不在校准期内的仪器读数照样拒;
  没记仪器、或收货单没挂称重,只标出来。」 · `requireSinceHint` en `:10162` verbatim.

**e. Fold-in 2 — ticket line, Q27 wording, amber when ≠ 0 — PRESENT** [M].
- `app/inbound/[id]/edit/TicketSharesPanel.tsx:34` reads `weighbridge_ticket_weights`; `:54-63` under each share line:
  `const off = Number(tk.difference_kg ?? 0) !== 0` → `text-amber-700`, `data-ticket-now={off ? 'differs' : 'matches'}`.
- `messages/en.ts:10114` `'Ticket now: net {net} kg · all shares {shared} kg · difference {diff} kg'` · `messages/zh.ts:9882`
  `'地磅单此刻:净重 {net} kg · 各份合计 {shared} kg · 差 {diff} kg'` — both verbatim as Q27. (The data is fixture 251 TICKET; the amber
  styling is not exercised by a fixture — live has no ticket — as the MES-3a hand-back §4 already says.)

**f. Fold-in 5 — `ingest_process_pending` header corrected — PRESENT** [M].
- `db/functions/ingest_process_pending.sql:4-5` "确认队列打开时【不】调它(MES-2 §7 决定 10:一次 GET 不该写 —— 此前这一行写着'确认队列打开时会调它',那是假的;
  MES-3a 按 Tim 的裁定 5 改正)".

**g. Pending values V2, V29, V3, V4, V34; change-log doc — PRESENT** [M].
- `db/views/pending_values.sql:72` V2 · `:85`, `:95` V29 · `:108` V3 · `:117` V4 · `:126` V34; labels and "supplied by" lines
  `messages/en.ts:10176-10191`. `docs/mes-pending-values.md:25-29` (five rows) and `:49-66` (what each holds back).
  Live (MES-3a hand-back §5.2 [Q]): as fusheng@ one row V34; as admin@ V29 ×1, V3 ×5, V4 ×3, V34 ×1.
- `docs/change-log.md:1019` "## 14. Storage safety (MES-3a …)", `:1037` "### 14.2 Safety-state history (Q22–Q25)", `:1059` "### 14.3 The
  calibration rule, as restored (ruling 1)"; `:994` §13's ruling marked "Landed (MES-3a …)".

**h. Decisions taken without asking (`docs/handbacks/MES-3a.md` §6), titles only:**
1. Two extra columns on the safety-state tables (`created_by_run_id`, `reopened_from_id`).
2. The outcome is judged by the category ceiling; the licence total is checked too.
3. The check runs after the receipt's INSERT and locks licence and limit rows.
4. `receipt_ceiling_checks` is append-only by a statement-level guard.
5. The concurrency proof is a script on a throwaway rebuild, not a fixture.
6. `storage_licence_in_force` is SECURITY DEFINER and on the B2 allowlist.
7. The dwell line does not say who recorded the state.
8. Ceilings are offered only on waste-disposal (gwdf) licences.
9. `save_storage_location`'s `p_is_quarantine` defaults NULL = keep.
10. V29's material rows count only battery-kind materials, and appear only once a category exists.
11. Fixture 114 F3 now proves the delete is refused.
12. The arrival check is a trail member of `output_batch` with `home = false`.
13. Ruling 2 reuses the weighbridge panel's keys plus one new key.
14. The MES-2 injection script's GATE cases re-targeted for ruling 1.
15. `trail_prelog_sources` unchanged.
16. "Safety state recorded / reopened" are key events on the trail.
17. The live licence was not edited for the ceiling proof.
18. Wording written by the session (beyond Q26/Q27).
19. The old `inbound_batch_safety_states_pkey` message removed.
20. A defect found by the dry run fixed in the builder.

**Verdict: a–g all present, none partly done** — so step 2 ran. The one deviation (a, ceiling predicate) is put to Tim as Q0.

---

## §1 · What grilling changed in MES-3b's scope

1. **The label QR is still the internal edit URL.** `app/inbound/[id]/label/route.ts:44` `request.nextUrl.origin + \`/inbound/${id}/edit\``
   (output `:44` the same) [M]; no `/b/` route exists (`find app -name b` → none; `next.config.ts` no rewrites) [M]. Q29's short link is new
   work, and labels already printed must keep working. **Q9.**
2. **Today's label is a GET that prints and records nothing** (`labelHtml.ts:68` `window.print()`; `grep -rni reprint app lib db scripts` → 0;
   `printed_at|printed_by` → 0) [M]. Logging a print cannot be done in that GET — the house rule is that a GET does not write (MES-2 §7
   decision 10, quoted in `db/functions/ingest_process_pending.sql:4-5`). The print flow becomes a page + action. **Q6.**
3. **A live defect in today's labels: warehouse labels print no material name.** The route embeds `materials ( name )` under the reader's RLS
   (`route.ts:34`); `materials` SELECT needs `module.materials.view` (`db/tables/materials.sql:110-113`); warehouse does not hold it (§0.2);
   an RLS-filtered embed is NULL and `labelHtml.ts:63` prints `'—'`. The role that receives and labels goods gets labels without the material.
   Same for the supplier row for readers without `module.suppliers.view`. AGENTS.md decision 3 ("a display label follows the document")
   says the name should travel with the batch. **Q2 (fold-in).**
4. **No template concept exists** (no label / print / document templates; `grep` hits only in survey docs) [M]. The dictionary registry
   holds 7 tables sharing `code, name_en, name_zh, is_active, sort_order, notes` with extras of kind `boolean | text | number`
   (`app/settings/dictionaries/registry.ts:30-49`) — enough for a *small* template (object kind, page size, which blocks), not for layout
   bodies. **Q5.**
5. **A DG code cannot be derived from anything on a material** — `battery_chemistries` has no lithium-metal row and no ion/metal flag
   (`battery_chemistries.sql:65-74`); "contained in equipment" (3481/3091) is not captured; black mass, electrolyte and electrode scrap are
   not "batteries" [M/I]. It must be **chosen per material**, which is a new "Not yet set" value (**V35**) beside MES-0's V30 and V31. **Q12, Q29.**
6. **Nothing marks a shipment as an export.** `shipments` has no country, incoterm or export flag (live columns, §0.2); incoterm lives on
   customers, suppliers, POs and contracts as free text; destination is reachable only through container → lane → `ports.country` [M].
   A refusal "missing DG on an export" has nothing to key on in this cut. **Q15.**
7. **The only shipping document is the delivery note PDF** (`app/sales/shipments/[id]/pdf/route.ts`, `DeliveryNoteDocument.tsx:88-97`, issued
   into `shipment_issues` with sha256); no packing list, commercial invoice or shipping marks exist (`grep -rniE "packing list|commercial
   invoice|shipping mark|loading plan|bill of lading" app db/tables db/functions` → 0) [M]. DG and HS go there and on its data function
   `shipment_document()`. **Q13, Q17.**
8. **A receipt has no batch to scan** — it creates one. What can be scanned at receipt is the location (and a ticket code typed off paper). **Q21.**
9. **Transfer has no page of its own** — it is a control per stock bucket on each batch page (`StockStatusPanel.tsx:196-228`,
   `TransferControl.tsx:98-106`) [M]. A scan-driven transfer needs a place to start from a scanned code: MES-0's `/inventory/scan`. **Q22.**
10. **A shipment's batch is chosen at reservation, not at shipping** (`ReserveControl.tsx:83-94` → `reserve_stock`; the shipping queue's
    `ShipQueueControl.tsx` has only quantity and date) [M]. Scanning at shipping can only *verify*; scanning at reservation *fills*. **Q24.**
11. **Reserve and ship check no safety state or quarantine** (`grep -c "safety\|quarant"` → `ship_order.sql` 0, `reserve_stock_internal.sql` 0)
    [M]. A batch with an open swollen / leaking state can be reserved and shipped today. MES-3a guarded *landing*; leaving the site was never
    asked. **Q16.**
12. **Feed has no location field and no quarantine check** — `commit_processing_run` drains `available` buckets itself
    (`drain_stock(..., ARRAY['available'])`, `commit_processing_run.sql:339-342`); the safety-state feed gate (`guard_processing_input`,
    `processing_inputs.sql:40-266`) is what decides whether a damaged battery may be fed [M]. A scan fills the batch only. **Q23.**
13. **The `scan` ingest class exists with no transform** (§0.2); with a NULL transform, device rows wait as `awaiting_transform`
    (`ingest_transform_row.sql:36-40`) [M]. No fixed reader exists and its payload format would be invented. **Q25.**
14. **`nea_waste_categories` (MES-3a) is in neither `SEED_TABLES` nor `RUNTIME_CONFIG_TABLES`** (`grep -c nea_waste db/check_mirrors.py` → 0)
    [M], while its own comment calls it RUNTIME CONFIG; `BOOTSTRAP_MAY_BE_EMPTY = set()` (`:312`) would fail an empty bootstrap, which is
    the likely reason it was left out [I]. A new DG dictionary seeded with four rows classifies normally. **Q3.**
15. **Estimate:** MES-0 said 6 h 00 m – 10 h 15 m; recalibrated on MES-1/2/3a's measured active times to **floor ≈ 0 h 55 m – 1 h 20 m +
    work ≈ 1 h 55 m – 3 h 00 m** (§10).

---

## §2 · (a) Exactly what MES-3b contains, against the MES-0 cut plan

MES-0 §8.2 row 4 [M, `docs/surveys/MES-0/README.md:698`]: "`label_templates`, `label_prints` (reprint reason), `dangerous_goods_codes`,
material UN/HS columns, `scan_events` + scan transform; `/inventory/scan` (wedge + camera); label routes take templates — 4.5 / 3".

**New tables (4):**

| table | purpose | read | write |
|---|---|---|---|
| `dangerous_goods_codes` | dictionary: `code` (UN3480 · UN3481 · UN3090 · UN3091), names, `dg_class` ('9'), `marking_text`, `packing_instruction`, `label_size` (the last three NULL = V30); RUNTIME CONFIG, seeded 4 rows | every authenticated reader of materials / inventory / logistics | `module.materials.edit` via `/settings/dictionaries` (Q11) |
| `label_templates` | dictionary: `object_kind` (inbound_batch · output_batch · storage_location), `page_size` (A6 · A5), `show_dg` ; seeded one A6 default per kind = today's layout | as above | `module.inventory.edit` via `/settings/dictionaries` (Q5) |
| `label_prints` | append-only: object (one of inbound batch · output batch · location), template, copies, `is_reprint`, `reprint_reason`, QR payload, printed-fields snapshot (jsonb), `printed_by`, `printed_at` | the object's view code | `record_label_print` only (Q6–Q8) |
| `scan_events` | append-only: `scanned_by`, `scanned_at`, `context` (lookup · receipt · transfer · feed · reserve · ship), `raw_value`, `method` (keyboard · camera), resolved kind / id, `outcome` | `module.inventory.view` | `resolve_scan_code` only (Q19–Q20) |

**Changed tables:** `materials` + `dg_code` (FK → `dangerous_goods_codes`, nullable; V35) + `hs_code` (text, nullable, format CHECK; V31).
Not masked (`lib/maskedTables.ts:10-46` has no `materials`) [M] — no three-change rule applies.

**Functions** — new: `record_label_print(kind, id, template, copies, reason)` (SECURITY DEFINER: checks the object's view code, decides
reprint, refuses `LABEL_REPRINT_REASON_REQUIRED`, writes the row, **returns the label data** — material name and supplier name follow the
document, Q2) · `resolve_scan_code(value, context, method)` (SECURITY DEFINER: parses a bare code, `/b/<code>`, `/loc/<code>` or an old edit URL;
returns kind, code, id only if the reader may view it, a `restricted` flag; writes `scan_events`; returns outcomes rather than raising so the log
row survives — the `ingest_submit` / `cod_verification` reason) · `label_data_preview(kind, id)` (read-only, same body, for the print page
before the press). Changed: `shipment_document` (+ `dg_code`, `dg_class`, `hs_code` per line) · `ship_order` (optional `scanned_code` per line,
`SHIP_SCAN_MISMATCH`, Q24) · `shipping_queue_rows` (+ `dg_code`, Q13; fixture 224 re-pinned) · `pending_values` (+3 arms) · trail registry.
Not built: `transform_scan_v1` (Q25).

**Pages / routes — 3 new, ~12 changed:** new **`/b/[code]`** (batch short link), **`/loc/[code]`** (location short link), **`/inventory/scan`**
(scan → open or transfer). Changed: the two label routes become print pages (`/inbound/[id]/label`, `/output/[id]/label`) + new
`/inventory/locations/[id]/label` · `/inbound/[id]/edit` and `/output/[id]/edit` (a "Labels" line: printed n times, last reprint and reason) ·
`/inbound/receive`, `/inbound/new` (scan the location) · `/operation/processing/new` (scan per input row) · `/sales/orders/[id]` reservation
(scan selects the bucket) · `/logistics/shipping` (scan verifies the row) · material editor ×2 (DG code, HS code) + list / export ·
`/settings/dictionaries` (two dictionaries) · `/sales/shipments/[id]` + delivery note PDF (DG / HS per line). One shared client component
`ScanField` (keyboard wedge + typing always; camera button only where `BarcodeDetector` exists).

**Left to later cuts:** thermal printers / ZPL (D10) · regulated DG package marks (class-9 hazard label, lithium battery mark) and their sizes
(V30, Q14) · shipment / package labels · an export flag and the refusal "no DG on an export" (the first-export / Basel item,
`docs/forward-queue.md:1778`) · fixed scanners through the `scan` class (Q25) · packing list, commercial invoice · batch-code width beyond 4
digits (`CODE-WIDTH-4`, MES-4b; §12.4).

---

## §3 · (b) Labels

- **Today** [M]: two GET route handlers returning A6 landscape HTML (`labelHtml.ts:39` `@page { size: 148mm 105mm }`), bilingual fixed text,
  batch code, material, quantity + unit, supplier (inbound) or purity (output), a 70 mm QR of the edit URL, auto `window.print()`. Gate: only
  `auth.getUser()` plus RLS on the batch table (`route.ts:25-41`) — no permission means 404, indistinguishable from "does not exist". Linked
  from five places (`inbound/[id]/edit/page.tsx:707`, `output/[id]/edit/page.tsx:330`, `receive/done/[id]/page.tsx:107`,
  `InboundTable.tsx:172`, `OutputTable.tsx:101`).
- **Template model (Q5):** `label_templates` as a dictionary — per object kind a page size (A6 / A5) and whether the DG block prints; the
  layout itself stays in one builder (`labelHtml.ts`), so a template chooses among fixed shapes and can never inject markup. Default = the
  active row with the lowest sort order for that kind.
- **Which objects (Q4):** inbound batch, output batch, **storage location** (new — a transfer or receipt needs a location to scan). No
  shipment / package label in this cut.
- **Print flow (Q6):** the label link opens a print page (preview, template, copies, and — if this object was printed before — a required
  reason) → **Print** calls `record_label_print`, which writes the row and returns the data → the page renders the label and calls
  `window.print()`. Recorded is "a label was issued for printing", not "paper came out" — the browser does not tell us; the wording says so.
- **Reprint (Q7):** any print of an object after its first, whatever the template, is a reprint and needs a reason
  (`LABEL_REPRINT_REASON_REQUIRED`, in the function, not only the page). Shown on the batch / location page ("Labels: printed 3 times · last
  reprint 2026-… by … — <reason>") and on the trail as a member of the object's existing subject (`inbound_batch`, `output_batch`,
  `storage_location`, `db/functions/trail_subjects.sql:160-161,181`), like `cod_issues` / `traceability_report_issues`
  (`trail_subject_members.sql:69,117`) [M].
- **Short link (Q9):** the QR encodes `<origin>/b/<code>` (batches) and `<origin>/loc/<code>` (locations). `/b/<code>` is a signed-in page
  (not in `PUBLIC_PATHS`, `lib/loginRoute.ts:50`): someone not signed in is sent to `/login?next=/b/<code>` by the existing middleware
  (`lib/supabase/middleware.ts:316-332`) and brought back after login [M]. Signed in: `resolve_scan_code` → reader may view → redirect to the
  batch page; may not → a named refusal ("IN-2026-0012 is an inbound batch. Viewing it needs Inbound — an administrator grants it."), no other
  field; unknown code → "No batch has this code." Labels already printed keep working: the edit routes are unchanged.

## §4 · (c) Dangerous-goods marks

- **Where the number lives (Q12):** on the **material** (`materials.dg_code`), chosen per material; batches inherit it through their material;
  not on batch or shipment (a batch of a material is the same goods; a per-batch override has no evidence of need) [I].
- **Dictionary (Q11):** `dangerous_goods_codes` seeded UN3480, UN3481, UN3090, UN3091, class 9 (MES-0 Q38), with their UN proper shipping
  names; `marking_text`, `packing_instruction`, `label_size` NULL = **V30** (forwarder, first export). Editable list.
- **How it reaches documents (Q13):** batch label — one line "UN3480 · Class 9 · Lithium ion batteries" when the template shows the DG block
  and the material has a code; `shipment_document()` lines and the delivery note — UN number, class, HS; the shipping queue — the UN number
  beside the material (fixture 224 pins `shipping_queue_rows`' column list, so it is re-pinned with an injection).
- **What is not printed (Q14):** the regulated package marks themselves. The label says the data, not "this is a DG mark".
- **Missing (Q15):** no refusal (no export notion, §1.6). Warned: label "DG code: not set" for a battery-kind material; delivery note line
  "DG: not set"; pending value **V35** per battery-kind material.
- **Hazard leaving the site (Q16):** reserve / ship check nothing (§1.11). Recommended: **flag, not refuse** — the shipping queue row and the
  delivery note line name an open state that requires quarantine; disposition of damaged batteries in transport is the forwarder's (V30).

## §5 · (d) Scanning

**Input (Q18):** `ScanField` — a text input that takes a keyboard-wedge scanner (it types and sends Enter) or typing; a camera button only
when `'BarcodeDetector' in window` (formats `qr_code`, `code_128`), using `getUserMedia` (HTTPS, which Vercel serves). No library (Q28).
Every scan goes to `resolve_scan_code(value, context, method)`; the page never decides identity itself. iOS Safari has no `BarcodeDetector` →
wedge or typing (Q26). Controls use the 48 px touch size (`CONTROL_TOUCH`, `app/components/ui/control-style.ts:169-175`) [M].

| flow | where | the scan fills | looked up | refused / told (existing refusals stay where they are) |
|---|---|---|---|---|
| **receipt** | `/inbound/receive`, `/inbound/new` | the **location** (location label, `/loc/<code>`); the weighbridge ticket by typed `WB-` code | location by code | at scan: not a location · inactive · restricted. At submit, unchanged: `IOD_RECEIPT_LOCATION_INACTIVE`, `IOD_CLASS_EXCLUDED`, **`QUARANTINE_LOCATION_REQUIRED`** (MES-3a) |
| **transfer** | `/inventory/scan` (new) | the **batch** → its buckets; then the **destination** location | batch and location by code | at scan: unknown · restricted · no stock on site; scanned source location holds none of this batch. At submit, unchanged: `IOD_TRANSFER_*`, `IOD_CLASS_EXCLUDED`, **`QUARANTINE_LOCATION_REQUIRED`** (open requiring state → only into quarantine), `WAREHOUSE_REQUEST_FREEZES_BATCH` |
| **feed** | `/operation/processing/new`, each input row | the **batch** (selects its option) | batch by code, matched against the page's options | at scan: unknown · restricted · not among feedable options (no remaining stock). At commit, unchanged: `IOD_CONSUME_EXCEEDS_AVAILABLE` (on-hold refused), `MATERIAL_NOT_PROCESSABLE`, the safety-state feed gate `INPUT_SAFETY_STATE_NOT_*` / `PRODUCED_SAFETY_STATE_NOT_*` |
| **shipment** | reservation `/sales/orders/[id]`; shipping `/logistics/shipping` | reservation: the **batch** (selects a bucket); shipping: a **verification** scan per row | batch by code | reservation: unchanged `SO_RESERVE_*` (output only, material match, available only). Shipping: **`SHIP_SCAN_MISMATCH`** in `ship_order` when a scanned code is sent and differs (Q24); the open-quarantine-state flag (Q16) |

## §6 · (e) HS codes

`materials.hs_code` text, nullable, CHECK digits with optional dots, 6–12 digits (a structural check, not a standard) — **V31** (customs
broker, first export). Shown: material editor, list, export; `shipment_document()` and the delivery note line. Not on labels, not on the
sales invoice in this cut (Q17).

## §7 · (f) Approvals, change log, trail, masking

- **Approvals: none** (MES-0 §4.1 lists label prints and scans as event records). Approvals ON / finance / cfo / 1,000 unchanged.
- **Change log:** `dangerous_goods_codes`, `label_templates`, `label_prints` logged (two triggers each); **`scan_events` excluded** with a
  reason in `change_log_exclusions()` — it is itself an append-only log (the MES-0 Q14 precedent for `ingest_inbox`). New `materials` columns
  ride its triggers.
- **Trail:** `label_prints` a member of `inbound_batch`, `output_batch`, `storage_location` ("Label printed" / "Label reprinted — <reason>");
  the two dictionaries as dictionary subjects; `check-trail-wording` gains an arm.
- **Masking: none.** No price, amount or personal datum in any new column; the print snapshot holds code, material, quantity, supplier name
  (the document's own label, decision 3).
- **Anonymous surface:** every new table gets an explicit anon decision (REVOKE ALL FROM anon); no new anonymous function.

## §8 · (g) "Not yet set" values MES-3b adds

| # | value | page | arm reads | permission | supplied by | when |
|---|---|---|---|---|---|---|
| V30 | Marking text, packing instruction, label size per DG code | `/settings/dictionaries` | each active `dangerous_goods_codes` row with any of the three NULL | `module.materials.view` | DG-qualified forwarder | first export |
| V31 | HS code per material | material editor | each live battery-kind material with `hs_code` NULL | `module.materials.view` | customs broker | first export |
| V35 (new) | DG code per material | material editor | each live battery-kind material with `dg_code` NULL | `module.materials.view` | the forwarder, with Tim | first export or first DG shipment |

Each with its arm in `pending_values` and its row in `docs/mes-pending-values.md` in the same commit (the Q2 rule of MES-1). Today on live:
V30 ×4, V31 ×1, V35 ×1 [I, from §0.2's 4 seeded codes and 1 battery-kind material].

## §9 · (h) Migration shape and broken window

**One migration**, `db/migrations/2026-10-0X-mes3b-labels-scanning.sql` (date from `date`): four tables (+ change-log bindings, the
exclusion, anon decisions, `document_type_exceptions` rows for the two dictionaries' `code` columns); `materials` two columns; the new functions;
`shipment_document`, `ship_order`, `shipping_queue_rows` (same signatures; new jsonb keys / new optional jsonb field / two new trailing columns
via drop-and-create with `NOTIFY pgrst`); `pending_values` 9 → 12 arms; trail registry rows; dictionary seeds. `db/check_mirrors.py`: both
dictionaries in `RUNTIME_CONFIG_TABLES` (+ Q3's fold-in). Registries that move: fixture 224, the new fixture 252, `check-document-registry`
count, `lib/database.types.ts`, `lib/modules.ts` (three routes), `docs/mes-pending-values.md`, `docs/change-log.md` §15,
`docs/role-matrix.md` (no new code).

**Broken window (old app + new database)** [I]: **nothing breaks** — old label routes keep printing (without a log row, which is simply absent
for the window); the old shipping page sends no `scanned_code` (optional); old pages ignore new jsonb keys; the old shipping page reads
`shipping_queue_rows` by named columns, so two trailing columns do not disturb it. Expected window ≈ MES-3a's (42 min – 1 h 01 min, verification
inside it).

---

## §10 · (i) Time estimate — floor and work, as two numbers

**Calibration** (measured by a sub-agent from the transcripts `~/.claude/projects/-Users-timchen/{a8f6087b…,379044eb…,5b351376…}.jsonl`, the
`refs/remotes/origin/main` reflog and `~/mes3a-work/logs/` mtimes; pauses = waiting on Tim):

| cut | opening → push | pauses | **active** | estimate | active ÷ estimate (low – high) |
|---|---|---|---|---|---|
| MES-1 | 10:39:40 → 16:07:50 | 2 h 49 m 10 s | **2 h 39 m 00 s** | 4 h 20 m – 8 h 35 m | 0.61 – 0.31 |
| MES-2 | 16:52:22 → 20:40:21 | 1 h 01 m 23 s (+ a 1 m 33 s interruption not deducted) | **2 h 46 m 36 s** | 2 h 35 m – 5 h 10 m | 1.07 – 0.54 |
| **MES-3a** | 21:18:39 → 09:49:19 | 1 h 09 m 56 s (Tim's pause) · 34 s · 8 h 33 m 17 s (overnight, after the backup) = 9 h 43 m 47 s | **2 h 46 m 53 s** | 2 h 50 m – 5 h 15 m | **0.98 – 0.53** |

**MES-3a split** [M boundaries, I categories]: building **1 h 36 m 42 s** (database layer 33 m 37 s · fixtures + 81 injections + concurrency
proof 18 m 13 s · pages 31 m 59 s · messages 6 m 10 s · proof scripts 6 m 43 s) · static checks 1 m 50 s · **clean floor 54 m 54 s** (backup
counted only where nothing overlapped it: 13 m 37 s of its 25 m 12 s; full gate 8 m 12 s; surveys 7 m 06 s; smoke 15 m 31 s; dry run + apply
+ types 4 m 17 s; live proofs and readings 3 m 25 s; offline gate 1 m 37 s; commit 49 s) · incidents 5 m 51 s · docs 6 m 55 s. Work
(building + static + docs) = **1 h 45 m 27 s**, the low end of its estimate; floor + incidents 1 h 00 m 45 s, under its 1 h 05 m.

**Process floor (MES-3b):** MES-3a's clean floor with the backup overlapped again, smoke +3 routes, the 390 px survey adding the scan and print
pages, live proofs for print / reprint / resolve as the 7 accounts (+3–5 m) → **≈ 0 h 55 m clean; ≈ 1 h 20 m with one incident** (MES-2's
incidents 15 m, MES-3a's 6 m).

**Work:**

| part | basis | low | high |
|---|---|---|---|
| orientation | | 5 m | 5 m |
| 4 tables, 2 columns, 3 new + 3 changed functions, pending arms, trail rows, `check_mirrors` | MES-3a: 33 m for 3 tables + 5 changes + ~22 functions | 20 m | 30 m |
| fixture 252 (≈ 8 arms: DG · HS · PRINT · REPRINT · RESOLVE · SCANLOG · SHIP · PV) + ≈ 25 injections; fixture 224 re-pin | MES-3a: 18 m for 11 arms + 81 injections + concurrency | 12 m | 20 m |
| 3 new routes, 3 print pages, `ScanField` + camera, 4 flows wired, material editor, dictionaries, delivery note + shipment page, batch pages | MES-3a: 32 m for 1 new + 9 changed pages; this cut is more page-heavy | 50 m | 80 m |
| messages en / zh | MES-3a: 6 m | 8 m | 12 m |
| live-proof script and role table | MES-3a: 7 m | 8 m | 12 m |
| static checks | MES-3a: 2 m; MES-2: 10 m | 3 m | 8 m |
| docs | MES-3a: 7 m | 7 m | 12 m |
| **total** | | **1 h 53 m** | **2 h 59 m** |

**Estimate: process floor ≈ 0 h 55 m – 1 h 20 m + work ≈ 1 h 55 m – 3 h 00 m = ≈ 2 h 50 m – 4 h 20 m of active time, plus any pause** —
against MES-0's 6 h 00 m – 10 h 15 m. The last two cuts landed at 1.07 and 0.98 of their low ends, so the low end is likely but not safe;
the middle (≈ 3 h 30 m) is the honest single number. **Not measurable here:** the camera path needs a real phone (headless Chrome is not a
camera); it is listed for Tim's own check after deploy, not counted. Each fold-in Tim declines (Q2, Q3, Q16's flag) takes 5–10 m off.

---

## §11 · Every open question, with a recommended answer and its evidence

Questions in one block are independent unless one names another.

### 0 · From the MES-3a close-out

❓ **Q0 — The ceiling section's predicate.** Q32 said ceilings `module.suppliers.view`; built `module.suppliers.view OR module.inventory.view`
(`db/views/storage_ceiling_status.sql:67`), not in MES-3a §6. Live effect: none (all 7 accounts hold suppliers.view); it widens to `operations`
and `sales`. It matches the `storage_ceiling_exceeded` arm's code (Q13).
➡️ **Accept as built and record it in `docs/handbacks/MES-3a.md` §6 as decision 21** — ceilings are regulatory facts copied from the licence, the
reminder arm already shows them to inventory viewers, and narrowing would make the page and its own reminder disagree.

### A · Scope

❓ **Q1 — Contents.** MES-0 said 4.5 tables / 3 pages.
➡️ **As §2: 4 new tables, 2 material columns; 3 new routes (`/b/[code]`, `/loc/[code]`, `/inventory/scan`), the label routes turned into print
pages plus a location label, ~12 changed pages; fold-ins Q2, Q3.** Left out: §2's list.

❓ **Q2 — Fold-in: warehouse labels print no material name** (§1.3). The label reads `materials ( name )` under RLS; warehouse lacks
`module.materials.view`; the label prints "—".
➡️ **Fold it in:** the label's data comes from `record_label_print` / `label_data_preview` (SECURITY DEFINER, gated by the batch's own view
code), carrying the material name and supplier name as the document's display labels (AGENTS.md decision 3). No grant change.

❓ **Q3 — Fold-in: `nea_waste_categories` is in neither mirror-checker list** (§1.14).
➡️ **Fold it in:** add it to `RUNTIME_CONFIG_TABLES` and to `BOOTSTRAP_MAY_BE_EMPTY` with its written reason ("seeded empty by design, V29"),
fault-injected once (a seed row added to the bootstrap must not be required; an unlisted empty RUNTIME CONFIG table must still fail).

### B · Labels

❓ **Q4 — Which objects get labels.**
➡️ **Inbound batch, output batch, storage location.** No shipment / package label until the first export brings V30's sizes.

❓ **Q5 — Template model.** (a) a `label_templates` dictionary choosing among fixed shapes (object kind, A6 / A5, DG block on/off) with the
layout in one builder; (b) templates in code only; (c) free-form template bodies.
➡️ **(a).** It satisfies MES-0 Q40's "templated A6/A5", fits the dictionary registry (`registry.ts:30-49`), lets a print record which
template it used, and cannot inject markup. Edited under `module.inventory.edit`.

❓ **Q6 — Print flow.** Today a GET prints and records nothing; a GET must not write.
➡️ **The label link opens a print page (preview, template, copies, reason when a reprint); Print calls `record_label_print`, which writes the row
and returns the data; the page then renders and calls `window.print()`.** The record says "issued for printing" — the browser cannot report paper.

❓ **Q7 — What a reprint is, and where it shows.**
➡️ **Any print of the same object after its first, any template; reason required in the function (`LABEL_REPRINT_REASON_REQUIRED`); anyone who
may print may reprint (MES-0 Q40). Shown on the object's page ("Labels: printed n times · last reprint <date> by <who> — <reason>") and on its
trail as a member of the existing subject.**

❓ **Q8 — What a print records.**
➡️ **Object, template, copies, reprint flag and reason, the QR payload, a jsonb snapshot of the printed fields, who, when. No PDF, no sha256**
(nothing is archived — the label is HTML printed by the browser).

❓ **Q9 — The short link.**
➡️ **`<origin>/b/<code>` for batches, `<origin>/loc/<code>` for locations; signed-in pages (not public): not signed in → login and back; may view →
redirect to the page; may not → a named refusal saying what the code is and which module is needed, nothing else; unknown → "no batch has this
code". Old labels keep working (edit routes unchanged).**

❓ **Q10 — What else the batch label prints.**
➡️ **Today's fields (now never blank, Q2) plus one DG line when the material has a code and the template shows it. No HS on labels.** Fixed
bilingual text stays.

### C · Dangerous goods

❓ **Q11 — The DG dictionary.**
➡️ **`dangerous_goods_codes`: UN3480, UN3481, UN3090, UN3091, class 9, with their UN proper shipping names; marking text, packing instruction,
label size NULL (V30); editable on `/settings/dictionaries` under `module.materials.edit`; RUNTIME CONFIG.**

❓ **Q12 — Where the UN number lives.** Material, batch or shipment.
➡️ **On the material (`materials.dg_code`), chosen per material** — nothing on a material can derive it (§1.5); a batch inherits; no per-batch or
per-shipment override until a case needs one.

❓ **Q13 — How it reaches the documents.**
➡️ **Batch label (Q10); `shipment_document()` lines and the delivery note (UN number, class, HS); the shipping queue (UN number beside the
material, fixture 224 re-pinned).** It is a material attribute, not a customer one, so APR-5b Q6's one-attribute rule on that reader is not
touched — but the column list changes, so it is put here.

❓ **Q14 — Regulated package marks** (class-9 hazard label, lithium battery mark).
➡️ **Not printed in this cut.** Their size and form are V30's (forwarder); the system prints the data, never something that looks like a compliant
mark.

❓ **Q15 — A missing DG code.** No export notion exists (§1.6).
➡️ **Warn, do not refuse:** label "DG code: not set" for a battery-kind material, delivery note line "DG: not set", pending value V35. The
refusal arrives with the export flag (the first-export / Basel item).

❓ **Q16 — Shipping a batch with an open state that requires quarantine.** Reserve and ship check nothing today (§1.11).
➡️ **Flag, do not refuse:** the shipping queue row and the delivery note line name the open state. Whether damaged batteries may travel, and how,
is the forwarder's (V30); refusing would also block sending them to a licensed recycler.

### D · HS

❓ **Q17 — HS codes.**
➡️ **`materials.hs_code` text, nullable, CHECK digits with optional dots, 6–12 digits (structure, not a standard); V31. Shown on the material
editor, list and export, and on `shipment_document()` / the delivery note. Not on labels or the sales invoice in this cut.**

### E · Scanning

❓ **Q18 — The scan input.**
➡️ **One `ScanField`: wedge and typing always; camera only where `BarcodeDetector` exists (`qr_code`, `code_128`); accepts a bare code,
`/b/<code>`, `/loc/<code>` and an old `/inbound|output/<id>/edit` URL.** No library (Q28).

❓ **Q19 — The lookup.**
➡️ **One SECURITY DEFINER `resolve_scan_code(value, context, method)`: returns kind, code, the id only if the reader may view it, a restricted
flag; outcomes, not raises.** The page never decides identity.

❓ **Q20 — The scan log.**
➡️ **`scan_events`, one append-only row per resolve, with context, raw value, method (keyboard / camera — a wedge and typing look the same to a
page), resolved object, outcome; excluded from the change log (it is a log); readable with `module.inventory.view`; shown as "your recent
scans" on `/inventory/scan` only.**

❓ **Q21 — Receipt.**
➡️ **The scan fills the location (location label); the weighbridge ticket accepts a typed or scanned `WB-` code against the same options.
Refusals stay at submit, unchanged** (quarantine included).

❓ **Q22 — Transfer.**
➡️ **`/inventory/scan` (`module.inventory.view`): scan a batch → its buckets → pick one (or scan the source location, refused if the batch has
no stock there) → scan the destination → quantity → `create_stock_transfer` (`module.inventory.edit`, its refusals unchanged).** Also an
"Open" action.

❓ **Q23 — Feed.**
➡️ **A scan button per input row selects the matching option; a code that is not among the options says why (unknown · restricted · no
stock). Commit refusals unchanged; feeding from a quarantine location stays allowed — the safety-state feed gate decides.**

❓ **Q24 — Shipment.**
➡️ **Reservation: the scan selects the bucket. Shipping: an optional verification scan per queue row; `ship_order` takes an optional
`scanned_code` per line and refuses `SHIP_SCAN_MISMATCH` when it differs.** Not required (no scanners on site); making it required later is a
setting, not code.

❓ **Q25 — Fixed scanners through the `scan` ingest class.**
➡️ **Not built in this cut.** No reader exists and its payload would be invented; rows wait as `awaiting_transform` by design (MES-1). D6 stays.

❓ **Q26 — Camera without `BarcodeDetector` (iOS Safari).**
➡️ **Wedge or typing; no library** (Q28 stands). The camera path is checked by Tim on an Android phone after deploy — headless Chrome cannot
prove it.

### F · Approvals, log, values, migration

❓ **Q27 — Approvals, change log, trail, masking.**
➡️ **As §7: no approval; three tables logged, `scan_events` excluded with a reason; `label_prints` on the three existing subjects; no masking.**

❓ **Q28 — Permissions.**
➡️ **No new code.** Print = the object's view code; DG / HS = `module.materials.edit`; templates = `module.inventory.edit`; `/inventory/scan` =
`module.inventory.view`; each action keeps its own code (`create_stock_transfer` `module.inventory.edit`, `ship_order` `action.ship_goods`).

❓ **Q29 — Pending values.**
➡️ **V30, V31 and the new V35 as §8, each with its arm and its row in the same commit.**

❓ **Q30 — Migration and broken window.**
➡️ **Accept §9: one migration, additive; nothing breaks in the window except that old label pages print without a log row.**

❓ **Q31 — Codes for the new records.**
➡️ **No new document prefix:** label prints and scans carry no code (like weighings); the two dictionaries get `document_type_exceptions` rows.

---

## §12 · Assertions measured and found false or imprecise

1. **MES-0 cites `docs/forward-queue.md:1682` and `:2096`** for the HS/UN/DG item and the barcodes item. They are now at **`:1778`** and
   **`:2192`** [M].
2. **MES-0 §1.2 row 8: "Phone camera reads the label QR and opens the batch page"** — true, but that is the phone's own camera app reading a URL,
   not the ERP scanning anything; no ERP page decodes anything today (`BarcodeDetector|getUserMedia|mediaDevices` → 0) [M].
3. **The label route's own 401 branch** (`route.ts:25-30`) is unreachable for a browser: the middleware redirects to `/login` first
   (`lib/supabase/middleware.ts:316-332`) [I].
4. **`CODE-WIDTH-4` (`docs/known-issues.md:3267`) names three numbering functions; the batch code triggers have the same shape** —
   `LPAD(nextval('inbound_code_seq')::TEXT, 4, '0')` (`inbound_batches.sql:142`), the same for output (`output_batches.sql:98`) [M]. PostgreSQL
   `lpad` truncates a longer string, so past 9,999 the code would repeat and the UNIQUE constraint would refuse the receipt [I]. Live is at
   OUT-…-0381. Short links and labels now depend on these codes — one more reason MES-4b's width fix covers the batch triggers too. Not a
   question for this cut.
5. **MES-0's MES-3b row "4.5 / 3"** — measured scope is 4 tables + 2 columns and 3 new routes with ~12 changed pages (§2).
6. **The brief: "MES-0 found batch QR labels already exist in part"** — true [M]; the part that exists also has the material-name gap (§1.3).

Matched on re-measurement: the three SHAs; 7 accounts, 0 disabled; approvals ON finance / cfo / 1,000; `require_calibrated_since` NULL; nothing
set by MES-3a (0 categories, ceilings, quarantine locations, dwell periods); 55 `operations_now` arms; the `scan` class present with no transform;
`qrcode` the only barcode dependency (`package.json:68`); `PUBLIC_PATHS = ['/login', '/verify/cod']`.

## §13 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q0–Q31.
