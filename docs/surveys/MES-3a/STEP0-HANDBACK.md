# MES-3a Step 0 — hand-back (2026-10-06)

**Contents:** Tim's rulings on the MES-2 close-out §0 · what grilling changed §1 · the design (a)–(l) §2–§13 · every open question §14 ·
assertions found false §15 · stop §16.

**STOP GATE.** No code edit, no migration, no live write. The only writes are docs: this file, `docs/surveys/MES-3a/live-readings.sql`,
and the records of ruling 1 in `docs/handbacks/MES-2.md` §10.2 and `docs/change-log.md` §13, plus the queue row. Waiting on Tim's answers
to Q1–Q33 (§14).

**Opening check.** First command **2026-10-06 20:58:05 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` =
`git ls-remote origin main` = **`e2e48e0bdf4b482986c0776de4b4e35631961420`** (MES-2 close-out). Files staged by explicit path only.

**How the facts were gathered.** Five read-only sub-agents (ceilings; safety states and dwell; quarantine and landing points; the fold-ins
and registries; cut-duration calibration from the session transcripts and `~/mes2-work/logs/` file times). None connected to a database or
ran a build. The live readings I took myself (§0.1). Tags: **[M]** measured (file:line read, or a live query in `live-readings.sql` with its
identity) · **[I]** inferred from code reading · **[Q]** quoted from an earlier hand-back.

### §0.1 · Live readings (read-only)

`docs/surveys/MES-3a/live-readings.sql`, three blocks, each `BEGIN READ ONLY … ROLLBACK`, in a session started with
`default_transaction_read_only = on`; psql to the pooler **as `postgres`, `rolbypassrls = true`, base tables** (the identity line prints it:
`postgres | t | on | 2026-10-06 21:01:46`). Nothing was written. Results used below:

| reading | result [M] |
|---|---|
| holders of `action.price_receipts` | **admin · finance** (roles, `role_permissions`) |
| holders of `data.view_purchase_prices` | admin · auditor · cco · cfo · cto · finance · gm · procurement · sales · warehouse |
| accounts (active roles) | admin@ admin (cfo revoked) · chooer@ finance · fusheng@ warehouse · phua@ cto (operations revoked) · sandra@ cco · tim@ cfo · vince@ gm; **0 disabled** |
| accounts holding `action.price_receipts` | **admin@ and chooer@** |
| `approval_deciders('receipt_price_request', …, level 2, raiser, …, 'finance', 'cfo')` | raiser chooer@ → **tim@**; raiser phua@ → tim@; raiser admin@ → **none** (`RECEIPT_PRICE_NO_OTHER_DECIDER`) |
| `finance_settings` | approvals ON, level 1 finance, level 2 cfo, threshold 1000 |
| MES-2 rows | weighings **0** · tickets 0 · shares 0 · drafts 0 · calibrations 0 · `require_calibrated_since` **NULL** |
| `receipt_price_requests` | 0 rows |
| `company_compliance` (not deleted) | **1**: `gwdf`, WDL-21-2-5380, NEA, active, valid 2026-07-01 → 2028-09-01, `approved_storage_limit_tonnes` **500** (test data) |
| `waste_classifications` | 2: `focused` (controlled), `non_focused` |
| materials by class | 7 unclassified · 1 focused · 1 non_focused |
| `storage_locations` | 4 (1 active `SG2026081201`; three `ZZ-` inactive); no kind column; `storage_location_allowed_classes` 1 row |
| on site (Σ `qty_delta` per batch, all statuses) | **24 batches, all `kg`, 119,204 kg**: inbound unclassified 2 / 100,070 · inbound focused 6 / 14,488 · inbound non_focused 4 / 830 · output focused 6 / 2,528 · output non_focused 6 / 1,288 |
| where it sits | 23 batch × location buckets **unspecified** (119,203 kg) · 1 in `SG2026081201` (1 kg) |
| safety-state fact rows | inbound **1** (`discharged_verified`) · output **1** (`charged_not_discharged`); **0** `swollen_leaking` |
| batches | inbound 24 (15 not deleted) · output 20 (14 not deleted) |

---

## §0 · Tim's rulings on the MES-2 close-out (2026-10-06) — closed, recorded here

1. **Calibration (MES-2 close-out §10.2 conflict).** The MES-2 brief's "nothing refuses when it is NULL" was Claude's error; Tim's accepted
   Step 0 design stands and is restored. A linked reading from an instrument known to be out of calibration at capture time (expired, failed or
   never calibrated, Q25) **always** refuses pricing (`reprice_inbound_batch` and its preview) and `issue_cod` with
   `READING_INSTRUMENT_NOT_CALIBRATED`, regardless of `require_calibrated_since`. The switch governs only `READING_INSTRUMENT_NOT_RECORDED` and
   `RECEIPT_READING_NOT_RECORDED`: for receipts created on or after its date, those two also refuse. `require_calibrated_since` stays NULL on
   live. Recorded in `docs/handbacks/MES-2.md` §10.2 and `docs/change-log.md` §13 (this commit: as a ruling, with the build in MES-3a).
2. **Item a.** A receipt's own page shows, beside each share, the ticket's current net weight and the difference between the shares and that
   net, so a correction after sharing is visible on the receipt as well as on the ticket. No migration.
3. **1 and 2 are built in MES-3a, as fold-ins.**
4. **Pricing permission:** MES-3a Step 0 measures on live who holds `action.price_receipts` before the fold-in is decided. The rule is Tim's
   role matrix of 2026-09-23: finance prices, the CFO approves. (Measured — §9.)
5. **Fold-in:** correct the stale header comment at `db/functions/ingest_process_pending.sql:4` (the capture queue does not process the inbox
   on load).

---

## §1 · What grilling changed in MES-3a's scope

1. **There is no waste-category axis to key a ceiling on.** The only classification is `materials.waste_classification_code` ∈ `focused` ·
   `non_focused` (`db/tables/waste_classifications.sql:56-60`; live 7 of 9 materials unclassified); batches carry none. The existing
   `hazardous_qty_on_hand_tonnes()` returns NULL for exactly this reason: mapping those two onto NEA's approved categories would be "发明,不是建模"
   (`db/functions/hazardous_qty_on_hand_tonnes.sql:4-10,26`) [M]. Q32's "per licence × waste category" therefore needs a category
   dictionary that starts **empty** and a category per material — MES-0's **V29** — plus the limits table. **Q4.**
2. **The existing check contradicts Q33.** `licence_storage_within_limit()` **refuses to judge** on a missing limit
   (`LICENCE_STORAGE_LIMIT_NOT_SET`, R2, `:43-49`), takes no material or category, and picks `max(limit)` across every licence of any type
   (`:33-38`); Q33 says *allow and record*. It has no caller [M: grep db/ app/ lib/ scripts/]. It is replaced, not wired in; fixture 152's
   arms A–C pin the old function text and are rewritten. **Q11.**
3. **Two licence-selection rules exist** — the one above, and `cod_governing_licence` (gwdf only, active, both dates, in force on the date,
   overlapping periods refuse, `db/functions/cod_governing_licence.sql:20-131`). The ceiling uses the stricter one. **Q5.**
4. **Processing can raise a category's tonnage** (a non-hazardous input can yield a hazardous output; conservation is only total output ≤
   total input, `commit_processing_run.sql:270-272`) and a rollback restores consumed stock. Refusing a commit or a rollback on a ceiling would
   stop production after the material already changed form. They are flagged, not refused. **Q9, Q13.**
5. **Safety states are deleted and re-inserted on every save** (`set_inbound_safety_states.sql:26-33`), so `created_at` resets for states
   that did not change — Q35's clock would restart on every save — and the primary key `(batch, code)` makes history impossible
   (`inbound_batch_safety_states.sql`, `output_batch_safety_states.sql`) [M]. Q36 needs a surrogate id, a partial unique index on open rows and
   a **diff** writer. **Q22.**
6. **A rolled-back deep discharge leaves the batch `discharged_verified`.** Rollback touches no safety state (grep "safety" in both rollback
   functions → 0) [M]. With history it can be undone exactly. Safety-relevant (a battery shown discharged can be fed). **Q2.**
7. **Output batches' states are written straight from the browser** (`app/output/[id]/edit/safetyActions.ts:23-25,40-44`; RLS insert / delete
   by `module.output.edit`) — a hard delete with no reason. History needs a function, as the inbound side already has. **Q22.**
8. **Stock has no location column.** Location is the sum of `inventory_movements` per batch × location × status; a batch can sit in several
   places (`inventory_movements.sql:30,78-79`, `drain_stock.sql:42-53`) [M]. Quarantine is a property of where each leg lands.
9. **More landing paths than the four named:** besides the four `check_location_class` callers (both receipts, `create_output_batch`,
   `create_stock_transfer`), stock lands through **rollback restore** (original locations, unchecked, `mirror_consume_restore.sql:25-29`),
   **stocktake gains** and **processing outputs** (both unspecified), and a **client INSERT policy on `inventory_movements`**
   (`inventory_movements.sql:130-133`, `module.inventory.edit`) that bypasses every gate — no app code uses it [M]. **Q3, Q20.**
10. **The receipt functions check the location before they write the states** (`create_inbound_batch.sql:58` gate, `:86-88` states;
    `receive_inbound_batch_against_po.sql:41`, `:68-70`) [M]; the quarantine rule must read `p_safety_states`. **Q19.**
11. **Live has no quarantine location**, so once swollen / leaking requires one, such a receipt cannot be received until a location is marked.
    **Q21.**
12. **Fold-in 4's premise is false.** Finance already holds `action.price_receipts` and can price with tim@ approving; only admin@-raised
    requests are refused (one person). **No grant change is needed** (§10). **Q28.**
13. **Estimate:** MES-0 said 5 h 45 m – 10 h 45 m; recalibrated on MES-2's measured split to **floor ≈ 1 h 05 m – 1 h 55 m + work ≈ 1 h 45 m
    – 3 h 20 m** (§13).

---

## §2 · (a) Exactly what MES-3a contains, against the MES-0 cut plan

MES-0 §8.2 row 3 [M, `docs/surveys/MES-0/README.md:697`]: "`licence_storage_limits`; location kind; state → location rule and dwell days
on `inbound_safety_states`; state history (close instead of delete); hazardous on-hand; refusal at receipt; quarantine gate at the four
landing points; dwell arm and report — 3 / 3".

**New tables (3)** — Q4, Q10:

| table | purpose | read | write |
|---|---|---|---|
| `nea_waste_categories` | dictionary of NEA approved waste categories; **seeded empty** (RUNTIME CONFIG; V29) | everyone authenticated | `module.materials.edit` via `/settings/dictionaries` |
| `licence_storage_limits` | `licence_id → company_compliance`, `category_code → nea_waste_categories`, `limit_tonnes > 0`; unique (licence, category) | `module.suppliers.view` | `module.suppliers.edit` (licence page) |
| `receipt_ceiling_checks` | one append-only row per batch created by a receipt or a manual output batch: licence, category, on-hand before, this batch (t), limit, **outcome** | `module.inbound.view` / `module.output.view` by batch kind | functions only |

**Changed tables:** `materials` + `nea_waste_category_code` (nullable; V29) · `storage_locations` + `is_quarantine` · `inbound_safety_states`
+ `dwell_warning_days` (V3), `requires_quarantine` (V4) · `inbound_batch_safety_states` and `output_batch_safety_states` re-keyed: `id`,
`ended_at`, `ended_by`, `end_reason`, `ended_by_run_id`, partial unique on open rows (Q22) · `inventory_movements` loses its client INSERT
policy (Q3). Neither `materials` nor `storage_locations` is masked (`lib/maskedTables.ts`; only `inbound_batches` of these is) [M]; no
masked table gains a column.

**Functions** — new: `storage_licence_in_force(date)` (the COD selection rule as an outcome, Q5) · `category_on_hand_tonnes(category)` (Q7) ·
`record_receipt_ceiling_check(…)` (judge + write + refuse, Q9–Q10) · `set_output_safety_states` (Q22) · `close_safety_state` helper ·
`assert_quarantine_landing(batch kind, states, location)` (Q19). Changed: `create_inbound_batch`, `receive_inbound_batch_against_po`,
`create_output_batch`, `create_stock_transfer`, `set_inbound_safety_states`, `commit_processing_run`, `rollback_processing_run_internal`,
`guard_processing_input` (six reads, `processing_inputs.sql:105-249`), `save_storage_location`, master import (location kind),
`assert_receipt_reading_calibrated` and `reprice_inbound_batch` (fold-in 1). Dropped: `licence_storage_within_limit`,
`hazardous_qty_on_hand_tonnes` (Q11). Views: `operations_now` (+3 arms, 52 → 55), `pending_values` (+5 arms), `processing_wip`, new
`storage_safety_status`.

**Pages (1 new, 9 changed)** — Q1: new **`/inventory/storage-safety`** (ceilings: on-hand vs ceiling per licence × category; batches past
their dwell period; stock that should be in quarantine and is not). Changed: `/purchasing/licences` (ceilings per category) ·
`/settings/dictionaries` (number field, two new columns, the category dictionary) · material editor (category) · location editor
(quarantine) · receipt forms ×2 (refusal texts, the ceiling outcome) · `/inbound/[id]/edit` (intake panel history and dwell; ceiling record;
**TicketSharesPanel**, fold-in 2) · `/output/[id]/edit` (safety panel through the function, history, dwell) · `/operation/calibration`
(wording, fold-in 1).

**Left to later cuts:** quarantine **split** of failed modules into their own batch (MES-5a, MES-0 Q23) · incidents and holds from alarms
(MES-7b) · DG / UN data (MES-3b) · NEA return and the compliance pack (MES-8b) · a location dimension on stocktakes (none exists) · notifications
whose subject is a batch (the CHECK allows only material / location, `notifications.sql:47,72`; the reminder arms carry it instead).

---

## §3 · (b) Ceilings

**What on hand means (Q7)** [I, from the ledger model M]: for a category C at the moment of the receipt, Σ `inventory_movements.qty_delta`
over every inbound and output batch whose material's `nea_waste_category_code` = C, **all three statuses** (on hold and committed stock is
still on site), soft-deleted batches netting to zero by their write-off leg (`inventory_ledger_triggers.sql:156-173`), converted to tonnes
(Q8). "Now" is the receipt's own transaction; the new batch's quantity is added before comparing. There is no as-of-date version
(`inventory_valuation_snapshot` refuses past dates, `:49-57`), and none is needed.

**Why the existing check reads NULL today** — §1.1; its own header says so.

**Which licence (Q5):** the `gwdf` licence that is active and in force on the receipt's date (`cod_governing_licence`'s rule), answered as
an outcome rather than a raise. Live: WDL-21-2-5380, in force.

**Where the refusal sits (Q9):** in `create_inbound_batch` and `receive_inbound_batch_against_po` after the location check and before the
`INSERT` (`:58`→`:69`; `:41`→`:54`), and in `create_output_batch` (`:23`→`:27`) — the three ways stock enters the site from outside. Refusal
`STORAGE_CEILING_EXCEEDED|<licence>|<category>|<on hand t>|<this t>|<limit t>` **only when a set ceiling would be exceeded**. Not in
processing, rollback, stocktake or transfer (Q9). Two concurrent receipts cannot both slip under: the function takes `FOR UPDATE` on the
`licence_storage_limits` row it judges against [I].

**How "ceiling not set" is recorded (Q10):** a `receipt_ceiling_checks` row on every receipt, outcome one of `within` · `ceiling_not_set` ·
`category_not_set` (material has no NEA category — every material today) · `licence_not_in_force` · `unit_not_convertible`, shown on the
receipt page. Not a column on `inbound_batches` (masked: three changes in one migration, AGENTS.md) [M].

**Today on live, every receipt would record `category_not_set`** — no category exists (§0.1).

---

## §4 · (c) Dwell

- **Clock (Q15):** the open state row's `created_at` — the moment it was recorded. Kept honest by the diff writer (Q22): a state that stays
  ticked keeps its time. Counted in Singapore calendar days; only batches with stock on site (Σ movements > 0).
- **Period (Q14):** `inbound_safety_states.dwell_warning_days integer` (> 0, NULL = **Not yet set**, V3) — one per state, shared by inbound and
  output batches (the dictionary is shared, `inbound_safety_states.sql:28-31`). Edited on `/settings/dictionaries` under
  `module.materials.edit`; the registry's `ExtraField.kind` knows only boolean / text today (`app/settings/dictionaries/registry.ts` ~38-46)
  and gains `number`.
- **Reminder board (Q16):** arm `safety_state_dwell` — one row per batch × open state whose days ≥ the period; `item_date` = the date recorded,
  so `days_waiting` is the dwell; per-row permission `module.inbound.view` / `module.output.view`. Warning only (Q35).
- **Batch page (Q16):** each open state shows "recorded <date> by <who> · <n> days · warning after <x> days" or "· dwell period not yet set";
  amber past the period. Same line on `/inventory/storage-safety`.

---

## §5 · (d) Quarantine

- **Marking (Q17):** `storage_locations.is_quarantine boolean NOT NULL DEFAULT false`, set on the location editor (`module.inventory.edit`,
  `save_storage_location.sql:27`) and in master import (`master_import_apply.sql:32,204`).
- **Which states (Q18):** `inbound_safety_states.requires_quarantine boolean` — `swollen_leaking` **true** (Q34), `discharged_verified` **false**,
  `charged_not_discharged`, `damaged_deformed`, `water_exposed` **NULL = Not yet set (V4)**, treated as "not required".
- **Every landing path and its rule (Q19, Q20):**

| path | today | after MES-3a |
|---|---|---|
| `create_inbound_batch` · `receive_inbound_batch_against_po` | location class only; states written after (`:58`/`:86`; `:41`/`:68`) | refuses `QUARANTINE_LOCATION_REQUIRED\|<state>\|<location or unspecified>` when `p_safety_states` holds a requiring state and the location is not an active quarantine location (**unspecified is not quarantine**) |
| `create_stock_transfer` | class check on the in-leg (`:55`) | refuses moving a batch with an open requiring state to a non-quarantine location; into quarantine always allowed |
| `create_output_batch` | class check | no states exist at creation — nothing to check |
| processing outputs | land unspecified, no states | unchanged (no states at creation) |
| rollback restore | original locations, unchecked | **flagged, not refused** (Q20) |
| stocktake gain | lands unspecified | **flagged, not refused** (Q20) |
| client INSERT on `inventory_movements` | open to `module.inventory.edit` | **closed** (Q3) |
| a requiring state recorded on stock already placed elsewhere (intake panel, output panel) | nothing | **recording is never refused** — a hazard must always be writable; the stock is flagged (Q20) |

- **Flag (Q20):** arm `quarantine_required` — one row per batch × non-quarantine location bucket holding stock while the batch has an open
  requiring state; batch page banner; `/inventory/storage-safety` lists them.

---

## §6 · (e) Safety-state history

- **Shape (Q22):** both fact tables gain `id uuid` PK, `ended_at`, `ended_by`, `end_reason`, `ended_by_run_id`; the old PK becomes a partial
  unique index `(batch, code) WHERE ended_at IS NULL`; a guard refuses DELETE and any UPDATE except closing an open row once. Writes only
  through functions: `set_inbound_safety_states` becomes a **diff** (insert new codes, close removed ones), `set_output_safety_states` is new,
  and the direct INSERT / DELETE policies are dropped.
- **Who closes and why (Q23):** a person un-ticking a state gives a reason (required); a processing run closes resolved states with
  `ended_by_run_id` (`commit_processing_run.sql:355-363,405-413`); a rollback of that run **re-opens** them and closes the state it added (Q2).
- **Today's rows (Q24):** 1 inbound + 1 output row on live, both stay open with their `created_at`; no back-fill.
- **Readers:** every current reader adds `ended_at IS NULL` — the feed gate's six reads (`processing_inputs.sql:105-110,133-139,148-160,
  206-210,222-229,238-249`), `processing_wip.safety_states_recorded` (`:30-31`), both batch pages, `set_inbound_safety_states`'s return
  count. The dictionary registry's reference count keeps counting all rows (`registry.ts:124`).
- **Trail and change log:** both tables are logged keyed `('inbound_batch_id','safety_state_code')`
  (`zzz_change_log_triggers.sql:365-367,581-583`) → re-keyed to `id`. The renderer reads only INSERT/DELETE
  (`lib/trail/render.ts:1423-1427`): a close would render as "Safety state recorded"; a new branch renders "Safety state ended — <reason>"
  (Q25). `trail_prelog_sources.sql:65-66` gains the ended stamp.
- **Fixtures 114 and 115 delete states directly** (setup) and are rewritten; 158–160, 165, 167, 178, 182, 238 insert only [M: grep].
- PROC-3 §1 (`docs/known-issues.md:4363-4382`, "谁把它摘下来、为什么摘,一个字都没有") closes with this.

---

## §7 · (f) Fold-in 1 — the calibration rule restored

**The change** (`db/functions/assert_receipt_reading_calibrated.sql`) [M lines, I change]: today `:30-32` returns when the switch is NULL and
`:33-36` returns for receipts created before it. After: read the receipt (`IF NOT FOUND THEN RETURN`), compute
`v_applies := v_since IS NOT NULL AND created_on >= v_since`; in the loop `NOT_RECORDED` (`:44-45`) raises only `IF v_applies`;
`NOT_CALIBRATED` (`:46-47`) raises **unconditionally**; `RECEIPT_READING_NOT_RECORDED` (`:50`) only `IF v_n = 0 AND v_applies`. Callers
unchanged: `reprice_inbound_batch.sql:46`, `preview_reprice_inbound_batch.sql:26`, `issue_cod.sql:50`; through the engine it also fires at
**submit** (`receipt_price_submit_internal.sql:85` → dry run → `receipt_price_post_internal.sql:32` → engine). Body comment
`reprice_inbound_batch.sql:45` and the column comment `ingest_settings.sql:34-35` (compared by `check_mirrors`) are rewritten in the
migration.

**Consequences, named:** with the switch NULL, a ticket whose gross has no instrument and whose tare is out of calibration now refuses
(`NOT_CALIBRATED`); a **priced** `create_inbound_batch` on such a ticket refuses the whole receipt, because the share is written before pricing
(`create_inbound_batch.sql:94,106`) — the refusal text tells the person to receive without a price, then price (MES-2 Q27).

**Fixture 250 GATE** [M]: the switch-empty loop (`:575-586`) changes — `b_bad`, `b_old` and `cod_bad` (all on `t_bad`, gross from a
never-calibrated scale, `:528,553-554`) now expect `READING_INSTRUMENT_NOT_CALIBRATED|<s_never>|<d>`; `b_none` and `b_unl` still pass, which
now proves the switch governs only the absence codes. `:623-624` (pre-switch receipt) and `:630-634` (switch cleared) re-pointed at `t_none` /
unlinked receipts for the "not governed" leg, with `b_old` / `b_bad` as the new always-refused leg. Header `:2,19,526,575,596,630` reworded.
Injections (`db/scripts/2026-10-06-mes2-fixture-injections.py:122-134`): three targets change (`:122-123`, `:127-128`, `:133-134`), and one
injection is new — "`NOT_CALIBRATED` waits for the switch" (`ELSIF … AND v_applies`) must go red in the switch-empty loop. **No other fixture
creates a weighing, ticket or share** [M: grep], so nothing else changes.

**Live:** **0 weighings, 0 tickets, 0 shares**, switch NULL (§0.1) — the restored rule refuses nothing that exists.

**Wording** [M]: `calibration.ruleOffHint` (en `:10113`, zh `:9880` — "nothing is refused" becomes false), `ruleOnHint` `:10114`,
`ruleAppliesHere` `:10115`, `ruleNotHere` `:10116`, `requireSinceHint` `:10117`, `requireSince` `:10111`; file headers
`app/operation/calibration/page.tsx:9-10`, `TicketSharesPanel.tsx:3-5`, the gate header `:5-6`. Error texts stay correct. Proposed text in
Q26.

---

## §8 · (g) Fold-in 2 — the receipt panel

`app/inbound/[id]/edit/TicketSharesPanel.tsx`: replace the `weighbridge_tickets (id, code)` read (`:30`) with `weighbridge_ticket_weights`
(`ticket_id, code, status, net_kg, shared_kg, difference_kg` — same row predicate, inbound OR logistics view, `:55`), and under each share
line (`:48`) one more line, amber when the difference is not 0. Wording (one new key, `weighbridge.receiptTicketNow`), Q27:

- en: **"Ticket now: net {net} kg · all shares {shared} kg · difference {diff} kg"**
- zh: **「地磅单此刻:净重 {net} kg · 各份合计 {shared} kg · 差 {diff} kg」**

The difference is the ticket's (net − Σ shares), which is what moves when a weighing is corrected; the share line above it keeps "{kg} kg
shared to this receipt (quantity {qty} kg)".

---

## §9 · (h) Fold-in 4 — receipt pricing, measured

**Who holds what (live, §0.1):** `action.price_receipts` → roles **admin, finance**; accounts **admin@, chooer@**. `data.view_purchase_prices` →
10 roles (every role except operations); every live account holds it. `module.inbound.view` → every live account.

**What pricing requires** [M]: a door code — `set_inbound_unit_price.sql:10-11`, `reprice_from_committed_terms.sql:16-17`,
`create_inbound_batch.sql:25-26` (with a price) all `action.price_receipts` + `data.view_purchase_prices`; `apply_assay_result.sql:27`
`action.apply_assay` (cto, admin) with the engine asking `data.view_purchase_prices` (`reprice_inbound_batch.sql:38`). With approvals ON the
door files a request (`receipt_price_submit_internal`), refused `RECEIPT_PRICE_NO_OTHER_DECIDER` when nobody but the raiser's **person** can
decide at level 2 (`:65-72` → `approval_deciders`); the decider needs the level-2 role (cfo), `module.inbound.view` and
`data.view_purchase_prices` (`decide_receipt_price_request.sql:39-40,53-54`; `approval_chain_gates.sql:102-103`).

**Why finance can price today:** chooer@ holds both door codes, and `approval_deciders` for raiser chooer@ returns **tim@** (§0.1). ROLE-1
ran exactly this on live (chooer@ submitted, tim@ approved, JE-2026-0080; `docs/handbacks/ROLE-1.md:1115-1122`) [Q]. Only a request raised by
**admin@** is refused — admin@ and tim@ are one person (`ROLE-1.md:1130`).

**What change makes "finance prices, CFO approves" work:** **none — it already works.** The brief's premise ("only admin@ holds it; every price
request is refused") came from `docs/handbacks/MES-2.md:215`, which was false (§15). **What admin keeps:** every code (standing ruling
2026-09-24, `docs/role-matrix.md:158`); its own requests stay refused by the person rule, which is correct. The bootstrap mirror gives
`action.price_receipts` to finance only (`db/tables/role_permissions.sql:122`; its admin block holds no business codes) — live's extra admin
row is the standing ruling, not drift. Q28.

---

## §10 · (i) Approvals, change log, trail, masking

- **Approvals: none new** (Q30). A ceiling, a dwell warning, a quarantine refusal and a state close are records or rules, not documents that
  wait (`docs/approvals.md:1091-1093`). Ceilings are regulatory facts copied from the licence — no approval, like the licence row itself.
  Approvals ON / finance / cfo / 1,000 unchanged.
- **Change log:** the three new tables logged (two triggers each); the two fact tables re-keyed to `id`; new columns on logged tables ride their
  existing triggers. Exclusions stay 7.
- **Trail:** `licence_storage_limits` joins subject `company_licence` (`trail_subjects.sql:178`); `receipt_ceiling_checks` joins
  `inbound_batch` / `output_batch`; the category dictionary becomes a dictionary subject like `dictionary_inbound_safety_states`
  (`:235`); state closes render with their reason (§6). `scripts/check-trail-wording.mjs` gains an arm.
- **Masking: none.** No price, amount or personal identifier on any new column; no masked table gains a column (§2).

---

## §11 · (j) "Not yet set" values MES-3a adds

| # | value | page showing "Not yet set" | arm reads | permission | supplied by | when |
|---|---|---|---|---|---|---|
| V2 | Ceiling per licence × NEA category (t) | `/purchasing/licences` | each in-force storage licence × each active category with no `licence_storage_limits` row | `module.suppliers.view` | NEA licence conditions | NEA licence issued |
| V29 | The NEA category list, and each material's category | `/settings/dictionaries` · material editor | one row while `nea_waste_categories` has no active row; then each active battery-kind material with no category | `module.materials.view` | NEA licence categories | NEA licence issued |
| V3 | Dwell warning days per safety state | `/settings/dictionaries` | each active state with `dwell_warning_days` NULL | `module.materials.view` | Tim with the WSH officer; licence storage conditions | NEA licence issued or first swollen / leaking receipt |
| V4 | Whether damaged / water-exposed / charged states require quarantine | `/settings/dictionaries` | each active state with `requires_quarantine` NULL | `module.materials.view` | Tim / WSH officer | before the first receipt of damaged stock |
| V34 | A quarantine location (new) | `/inventory/locations` | one row while a state requires quarantine and no active location is marked | `module.inventory.view` | Tim / warehouse | before the first swollen / leaking receipt |

Each gets its arm in `pending_values` and its row in `docs/mes-pending-values.md` **in the same commit** (the Q2 rule). No number is
invented: every ceiling, period and per-state flag starts NULL except `swollen_leaking` = true (Q34) and `discharged_verified` = false.

---

## §12 · (k) Migration shape and broken window

**One migration**, `db/migrations/2026-10-0X-mes3a-storage-safety.sql` (date from `date`): the three tables; the column additions; the
fact-table re-key (add `id`, swap PK for the partial index, guards, drop direct policies, change-log re-binding); `inventory_movements` INSERT
policy dropped; functions §2 (signature changes via `DROP` + `CREATE` with new parameters last and defaulted, then `NOTIFY pgrst`); the two
old functions dropped; dictionary seeds (`requires_quarantine` for two states); `operations_now` 52 → 55; `pending_values` 4 → 9 arms;
`processing_wip`; new view; fold-in 1's function and comments; trail registry rows. Mirror-only: `ingest_process_pending.sql:4` (header outside
the body; `check_mirrors` compares `pg_get_functiondef`, `:31,929-939`) [M]. Registries that move (no question): fixture 111 (52 → 55),
fixture 152 (rewritten), fixture 250 (§7), fixtures 114 / 115, 249 / 250 PV, `scripts/check-document-registry.mjs:114` (256 → 259),
`lib/database.types.ts`, `lib/modules.ts` (one route), the PK message keys `messages/*.ts` (`inbound_batch_safety_states_pkey`, en
`:2652-2653`), `docs/dashboard-arm-inventory.md`, `docs/mes-pending-values.md`, `docs/role-matrix.md` (no new code), `docs/change-log.md` §14.

**Broken window (old app + new database)** [I]:
- **Output batch safety panel: broken** — it inserts / deletes the table directly and those policies are gone; adding or removing a state on
  an output batch fails until the deploy.
- **Intake panel:** ticking a new state works (the reason parameter is last and defaulted); **un-ticking a state is refused**
  (`SAFETY_STATE_END_REASON_REQUIRED`, Q23) because the old page cannot send a reason. Old pages read without `ended_at`, so a state closed in
  the window would still show as current; live has 2 rows.
- **Receipts:** new refusals (`QUARANTINE_LOCATION_REQUIRED`, `STORAGE_CEILING_EXCEEDED`) show as raw codes — neither can fire on live
  today (no swollen state requested in a normal receipt path, no ceiling set).
- **Pricing / COD:** the restored rule refuses nothing (0 weighings).
- **Trail:** the old renderer shows a close as "Safety state recorded".
- Expected window ≈ MES-2's (56 min – 1 h 03 min, verification inside it).

---

## §13 · (l) Time estimate — floor and work, as two numbers

**Calibration** (measured; transcripts and log times; pauses = waiting on Tim):

| cut | opening → push | pauses | **active** | estimate | active ÷ estimate |
|---|---|---|---|---|---|
| U1-A | 15:26:55 → 19:06:19 | 1 h 09 m 38 s | **2 h 29 m 46 s** | 5 h 30 m – 8 h 15 m | 0.45 – 0.30 [Q] |
| U1-B | 19:52:35 → 09:54:18 | 12 h 01 m 28 s | **2 h 00 m 15 s** | 4 h 30 m – 7 h 15 m | 0.45 – 0.28 [Q] |
| MES-1 | 10:39:40 → 16:07:50 | 2 h 49 m 10 s | **2 h 39 m 00 s** | 4 h 20 m – 8 h 35 m | 0.61 – 0.31 [Q] |
| **MES-2** | 16:52:22 → 20:40:21 | 17:29:45 → 18:31:08 (1 h 01 m 23 s) | **2 h 46 m 36 s** | 2 h 35 m – 5 h 10 m | **1.07 – 0.54** [M] |

**MES-2 split** [M boundaries from transcript timestamps; categories I]: building **69 m 10 s** (database layer 21 m 02 s for 7 tables /
32 functions; fixture 250 + 41 injections 13 m 46 s; 4 routes 10 m 38 s; changed pages 5 m 33 s; messages 3 m 55 s; trail arm 2 m 12 s;
proof scripts 12 m 04 s) · static checks 10 m 05 s · **clean floor 67 m 54 s** (Q31 probe ≈ 6 m; backup 10 m 31 s; full gate 9 m 13 s wall;
smoke 17 m 52 s; surveys 7 m 03 s; live proofs 3 m 17 s; the rest) · incidents 14 m 33 s · docs 4 m 54 s (+ 5 m 41 s inside the backup).
MES-2 is the first of four cuts to go over its estimate's low end; its floor ran at 1.04 of the low end, its work at 0.93.

**Process floor (MES-3a):** MES-2's clean floor less its Q31 probe (≈ 62 m), plus live proofs for ceilings, quarantine, dwell, history and
the restored calibration rule (≈ +3–5 m) → **≈ 1 h 05 m clean; ≈ 1 h 55 m with one incident** (MES-2's incidents 15 m, MES-1's 44 m).

**Work:**

| part | basis | low | high |
|---|---|---|---|
| orientation | | 5 m | 5 m |
| 3 tables + 5 table changes, ~8 new and ~14 changed functions, views | MES-2: 3 m / table, 39–53 s / function | 20 m | 35 m |
| state history through the commit, rollback and feed-gate paths; fixtures 114 / 115 | regression surface MES-2 did not have | 15 m | 35 m |
| fold-in 1 (gate + fixture 250 GATE + injections) | | 5 m | 10 m |
| 1 new route + 9 changed pages, messages | MES-2: ≈ 2 m per route or page with i18n | 20 m | 40 m |
| fixture 251 (≈ 7 arms) + ≈ 30 injections; fixtures 152, 111, PV | MES-2: 55 s / arm, 20 s / injection | 20 m | 35 m |
| live-proof scripts and role table | MES-2: 12 m | 10 m | 15 m |
| static checks | MES-2: 10 m | 5 m | 10 m |
| docs | MES-2: ≈ 10 m | 5 m | 15 m |
| **total** | | **1 h 45 m** | **3 h 20 m** |

**Estimate: floor ≈ 1 h 05 m – 1 h 55 m + work ≈ 1 h 45 m – 3 h 20 m = ≈ 2 h 50 m – 5 h 15 m of active time, plus any pause** — against
MES-0's 5 h 45 m – 10 h 45 m. MES-2 landed at 1.07 of its low end, so the low end is no longer the safe bet; the middle (≈ 3 h 45 m) is.

---

## §14 · Every open question, with a recommended answer and its evidence

Questions in one block are independent unless one names another. Where a question builds on another's recommendation it says so.

### A · Scope

❓ **Q1 — Contents and pages.** MES-0 said 3 tables / 3 pages.
➡️ **As §2: 3 new tables, 5 table changes; one new page `/inventory/storage-safety` (ceilings, dwell, quarantine in one place) and nine changed
pages; the fold-ins (1, 2, 4 = no change, 5).** Left out: §2's list.

❓ **Q2 — A rolled-back run should undo its safety-state changes.** Today a rolled-back deep discharge leaves `discharged_verified` and does
not restore `charged_not_discharged` (no "safety" in either rollback function) [M]; a battery shown discharged can be fed.
➡️ **Fold it in:** with `ended_by_run_id` the rollback closes the state the run added and re-opens the ones it closed. Fixture arm with a
fault injection.

❓ **Q3 — The client INSERT policy on `inventory_movements`.** It lets `module.inventory.edit` hand-build a transfer pair that passes the ledger
invariant and skips every gate (`inventory_movements.sql:130-133`); no app code uses it [M]; the batch tables closed theirs (fixture 58).
➡️ **Drop it in MES-3a** (refusal `MOVEMENTS_THROUGH_FUNCTION_ONLY`), or "every path refuses a swollen batch elsewhere" is not true.

### B · Ceilings

❓ **Q4 — The category axis.** Only `focused` / `non_focused` exist, per material [M]; NEA approved categories are a different vocabulary.
(a) a new dictionary `nea_waste_categories`, **seeded empty**, and `materials.nea_waste_category_code`; (b) add NEA categories as rows of
`waste_classifications` (which also drives location allowed-classes).
➡️ **(a).** Mixing would let a licence vocabulary change which racks accept which material. Categories and the per-material mapping are V29,
supplied from the NEA licence.

❓ **Q5 — Which licence carries the ceilings and which one applies to a receipt.**
➡️ **`gwdf` only, the one active and in force on the receipt's date — `cod_governing_licence`'s rule** (`:20-131`) **returned as an outcome**:
no licence, not in force or overlapping periods record `licence_not_in_force` and **allow** the receipt (an expired company licence does not
block receipts today, `operations_now.sql:622-632` is its only consumer besides COD [M]; blocking would be a new rule nobody asked for).

❓ **Q6 — The existing `approved_storage_limit_tonnes`** (one number per licence; live 500 t, test data).
(a) keep it as a licence-wide total across all NEA categories, checked too; (b) retire it in favour of per-category rows only.
➡️ **(a)** — licences commonly state an overall maximum as well as per-type limits; it costs one more comparison and the column already exists.
It counts only stock whose material has an NEA category (no category → not counted, outcome says so).

❓ **Q7 — What "on hand" counts.**
➡️ **Σ movements, all three statuses, inbound and output batches, by the material's current NEA category, soft-deleted batches netting to
zero, at the receipt's own transaction, including the new batch; serialized by `FOR UPDATE` on the limit row.**

❓ **Q8 — Units.** Batch units are free text (`kg`, `吨`, `克`, `件`; `app/materials/options.ts:26-31`); live is all `kg`.
➡️ **kg × 0.001, 吨 / t × 1, 克 / g × 0.000001 to tonnes. 件 or anything else: outcome `unit_not_convertible`; refuse
(`STORAGE_CEILING_UNIT_NOT_CONVERTIBLE`) only when a ceiling is set for that category**, because then the ceiling cannot be shown to hold
(the `UNIT_NOT_KG` precedent, `allocate_processing_costs.sql:90-107`).

❓ **Q9 — Where the refusal sits.**
➡️ **The three ways stock enters from outside: both receipt functions and `create_output_batch`, before the insert. Not processing, rollback,
stocktake or transfer** — those are recorded by the arm in Q13 instead (§1.4).

❓ **Q10 — How "ceiling not set" is recorded.**
➡️ **An append-only `receipt_ceiling_checks` row on every receipt and manual output batch, outcome `within` · `ceiling_not_set` ·
`category_not_set` · `licence_not_in_force` · `unit_not_convertible`, with the figures; shown on the batch page.** Not a column on masked
`inbound_batches`.

❓ **Q11 — The two old functions.** `licence_storage_within_limit` refuses to judge (R2) where Q33 allows; no caller [M].
➡️ **Drop both; replace with the outcome-returning internals of Q5–Q10; rewrite fixture 152's arms A–C** (D–G, import diligence and expiry,
stay). R2's principle survives where it belongs: nothing *assumes* a limit — an unset one is recorded, not treated as unlimited or zero.

❓ **Q12 — Who edits, and history.**
➡️ **Ceilings on `/purchasing/licences` under `module.suppliers.edit` (the licence's own code); categories on `/settings/dictionaries` and a
material's category in the material editor under `module.materials.edit`. History = the change log** (every row before / after with who and
when, HISTORY-1), not a separate `*_history` table — MES-0 Q93 predates the change log covering every table.

❓ **Q13 — Stock above a ceiling that did not arrive by receipt** (processing changed its category, a rollback, a ceiling lowered).
➡️ **Reminder arm `storage_ceiling_exceeded`** (per licence × category over its set ceiling, `module.inventory.view`) and the same row on
`/inventory/storage-safety`. Warning only.

### C · Dwell

❓ **Q14 — Where the period lives.**
➡️ **`inbound_safety_states.dwell_warning_days` (NULL = Not yet set, V3), one per state, shared by inbound and output batches; edited on
`/settings/dictionaries` (registry gains a number field).**

❓ **Q15 — The clock.**
➡️ **The open state row's `created_at`, kept by the diff writer (Q22); Singapore calendar days; only batches with stock on site.**

❓ **Q16 — How warnings show.**
➡️ **Arm `safety_state_dwell` (batch × state at or past its period; `item_date` = recorded date; per-row permission inbound / output view) and,
on each batch page, every open state with "recorded <date> · <n> days · warning after <x> days / not yet set", amber past it. No separate
dwell report beyond `/inventory/storage-safety`.**

### D · Quarantine

❓ **Q17 — Marking a location.**
➡️ **`storage_locations.is_quarantine` (default false), on the location editor and in master import, `module.inventory.edit`.**

❓ **Q18 — Which states require quarantine.**
➡️ **`inbound_safety_states.requires_quarantine`: `swollen_leaking` true (Q34), `discharged_verified` false, the other three NULL (V4) and treated
as not required.**

❓ **Q19 — The landing gates.**
➡️ **Receipts refuse `QUARANTINE_LOCATION_REQUIRED|<state>|<location>` when the requested states include a requiring one and the location is
not an active quarantine location — an unspecified location is not quarantine. Transfers refuse moving such a batch out to a non-quarantine
location; into quarantine is always allowed.**

❓ **Q20 — A hazard recorded on stock already placed, and the paths that cannot refuse** (rollback restore, stocktake gain).
➡️ **Never refuse recording a state** — a hazard must always be writable. **Flag** instead: arm `quarantine_required` (batch × non-quarantine
bucket with stock while a requiring state is open), a banner on the batch page, the row on `/inventory/storage-safety`; the next move can only
go into quarantine (Q19).

❓ **Q21 — Live has no quarantine location.** After MES-3a a swollen / leaking receipt is refused until one is marked.
➡️ **Accept, and add pending value V34 "no active quarantine location" while any state requires quarantine**, so the gap is on the page before
the first such delivery, not discovered at the scale.

### E · Safety-state history

❓ **Q22 — Shape.**
➡️ **Surrogate `id`, `ended_at`, `ended_by`, `end_reason`, `ended_by_run_id`; partial unique `(batch, code) WHERE ended_at IS NULL`; a guard
refusing DELETE and any UPDATE but one close; writes only through `set_inbound_safety_states` (now a diff) and a new
`set_output_safety_states`; the direct INSERT / DELETE policies dropped.**

❓ **Q23 — A reason for closing.**
➡️ **Required when a person un-ticks a state (`SAFETY_STATE_END_REASON_REQUIRED`), in the function, not only on the page; automatic for a run
("resolved by <run>") and a rollback.** Consequence: during the broken window the old intake panel cannot un-tick a state (Q33).

❓ **Q24 — Today's rows.**
➡️ **The two live rows stay open with their own `created_at`; no back-fill** (MES-0 Q94). Fixtures 114 / 115, which delete states directly
in setup, are rewritten.

❓ **Q25 — The trail.**
➡️ **Re-key the change-log binding to `id`; render a close as "Safety state ended — <reason>" (by whom, when); a run's close names the run.**

### F · Fold-ins

❓ **Q26 — Fold-in 1 wording** (the rule is ruled; only the text is open).
➡️ `ruleOffHint` → en "The calibration switch is off: a reading from an instrument out of calibration is still refused; a missing instrument
or a receipt with no weighing is only shown." / zh 「校准开关关着:不在校准期内的仪器读数照样拒;没记仪器、或收货单没挂称重,只标出来。」 ·
`ruleOnHint` / `ruleAppliesHere` / `ruleNotHere` → say the switch date governs **only** "no instrument" and "no weighing" ·
`requireSinceHint` → "Leave blank: out-of-calibration readings are still refused; missing ones are not." Fixture 250 and injections as §7.
Docs: `docs/handbacks/MES-2.md` §10.2 and `docs/change-log.md` §13 recorded now as a ruling; the as-built line lands with the build.

❓ **Q27 — Fold-in 2 wording.**
➡️ **One new key: en "Ticket now: net {net} kg · all shares {shared} kg · difference {diff} kg", zh 「地磅单此刻:净重 {net} kg · 各份合计
{shared} kg · 差 {diff} kg」, under each share line, amber when the difference is not 0; read from `weighbridge_ticket_weights`.**

❓ **Q28 — Fold-in 4.** Measured: finance holds the code and tim@ can decide finance's requests (§9).
➡️ **No grant change. Correct `docs/handbacks/MES-2.md:215` in place (struck, with this measurement). MES-3a's live proof also runs the
gated price path end to end on live — chooer@ submits, tim@ approves, inside the rolled-back transaction** — the path MES-2 said could not
run on live.

❓ **Q29 — Fold-in 5.**
➡️ **Mirror-only edit of `db/functions/ingest_process_pending.sql:4`** ("the Process received button on the inbox runs it; the capture queue
does not process on load") — the header sits outside the function body, so no migration and no drift.

### G · Approvals, log, values, migration

❓ **Q30 — Approvals, change log, masking.**
➡️ **No approval chain; all new tables logged; the fact tables re-keyed; no masking** (§10).

❓ **Q31 — Pending values.**
➡️ **V2, V29, V3, V4 and the new V34 (§11), each with its arm and its row in the same commit.**

❓ **Q32 — Who sees `/inventory/storage-safety`.**
➡️ **`module.inventory.view`** for the page; each section's rows carry their own predicate (ceilings `module.suppliers.view`, batches inbound /
output view). Today all seven roles hold inventory view [I: AT-1c reading as in MES-2 Q22] — to be confirmed in the role table at build.

❓ **Q33 — Broken window.**
➡️ **Accept §12:** for the length of the window the output batch safety panel cannot add or remove a state, the intake panel cannot un-tick
one, and new refusal codes show raw; nothing else breaks on today's live data.

---

## §15 · Assertions measured and found false or imprecise

1. **The brief: "On live, only admin@ holds the pricing permission … so every price request is refused as self-approval."** False. Live:
   admin and finance roles; admin@ and chooer@; chooer@'s requests are decided by tim@ (§0.1). The source is item 2.
2. **`docs/handbacks/MES-2.md:215`** "the holder of `action.price_receipts` (only admin@)" — false (same measurement). (Q28.)
3. **`docs/handbacks/MES-2.md:217`** "the dry run → preview" — imprecise: the submit-time dry run runs the **engine**
   (`receipt_price_submit_internal.sql:85` → `receipt_price_request_dry_run.sql:27` → `receipt_price_post_internal.sql:32` →
   `reprice_inbound_batch`), not the preview.
4. **MES-0 §1.2 row 5:** the output-unsold arm is now at `db/views/operations_now.sql:292-301`, not 277-285. **PROC-3 §1** is at
   `docs/known-issues.md:4363-4382`, not ~4349.
5. **MES-0 "quarantine gate at the four landing points".** Stock lands through more than four paths: rollback restore, stocktake gains,
   processing outputs and a client INSERT policy too (§1.9).
6. **MES-0 Q36 "close a state instead of deleting it, everywhere states change"** is right but incomplete: the inbound writer also re-inserts
   *unchanged* states on every save, and the output writer is the browser (§1.5, §1.7).
7. **Fold-in 1 survey:** `docs/surveys/MES-2/STEP0-HANDBACK.md:274,486` already state the restored rule ("also refuse") — the ruling restores
   that text, it does not add a new one.

Matched on re-measurement: the three SHAs; approvals ON finance / cfo / 1,000; 7 accounts, 0 disabled; `require_calibrated_since` NULL; 0
weighings; one live licence, gwdf, 500 t; 2 waste classes; 52 `operations_now` arms (`grep -c "AS item_type"`); 4 `pending_values` arms;
highest fixture 250; 75 permission codes; change-log doc's last section §13.

## §16 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q33.
