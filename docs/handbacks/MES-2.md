v1.4.38 — Weighing and calibration: scale readings now arrive as drafts for staff to confirm (with any change and its reason kept), weights can also be entered by hand, weighbridge tickets record gross, tare and net with photos and can be shared across receipts and shipments, and every scale and instrument carries a calibration record — once the calibration rule is switched on, prices and destruction certificates refuse readings from instruments out of calibration.

# MES-2 — confirmation, weighing, calibration (MES group, second cut; 2026-10-06)

Tim answered MES-2 Step 0 on 2026-10-06: every recommendation for Q1–Q35 in `docs/surveys/MES-2/STEP0-HANDBACK.md` accepted exactly as
stated; MES-0 Q1–Q96 and MES-1 Q1–Q30 stand as amended. This cut builds all of it. **MES-2 is closed. The next cut is MES-3a · Storage
safety.**

**Opening state:** `HEAD` = `origin/main` = **`31e3b3e4`** ("MES-2 Step 0: hand-back (docs only)"). Files were staged by explicit path only.

**Live state, before and after:** approvals ON throughout; the 7 accounts enabled throughout, each with the same role; one pending
document before and after (CLM-2026-0004, 1,000.00 — not mine, untouched). No real account was created, disabled or deleted; no
pre-existing document was decided, edited or deleted, not even inside a rolled-back transaction. `require_calibrated_since` is **NULL** on
live after the cut (it was set only inside rolled-back proofs). Reconciliation: payables and receivables **0.00 unexplained** before and
after (§6).

Every figure below is a script's own exit line or a query naming who ran it. "As postgres" means psql as `postgres`
(`rolbypassrls = true`), reading base tables. Working logs are in `~/mes2-work/logs/` (outside the repo).

---

## §1 · Role-by-role reading table (live, measured)

`db/scripts/2026-10-06-mes2-live-role-table.sql` (`ROLETABLE_OWN_EXIT=0`, 2026-10-06 20:32 CST, 112 cells). One rolled-back transaction:
it first creates, **as the real accounts through the real functions**, what the three pages show — a probe gateway sends a 777 kg
reading (anon), fusheng@ processes it into a pending draft, phua@ records a calibration on the probe scale, fusheng@ opens and completes an
inbound ticket (12,000 / 4,000) and records a photo row — then reads each page's data sources as each of the 7 accounts
(`SET LOCAL ROLE authenticated` + that account's JWT — what PostgREST does on every request). Nothing it made survives the ROLLBACK.

| what the page reads | admin@ (admin) | chooer@ (finance) | fusheng@ (warehouse) | phua@ (cto) | sandra@ (cco) | tim@ (cfo) | vince@ (gm) |
|---|---|---|---|---|---|---|---|
| door: capture queue + calibration page (`module.processing.view`) | opens | opens | opens | opens | opens | opens | opens |
| door: weighbridge pages (`module.inbound.view` OR `module.logistics.view`) | opens | opens | opens | opens | opens | opens | opens |
| confirm / reject / manual / correct / ticket void / photo (`action.confirm_capture`) | pressable | disabled, names the code | pressable | pressable | disabled, names the code | disabled, names the code | disabled, names the code |
| record / void calibration, calibration settings (`action.manage_devices`) | pressable | disabled, names the code | disabled, names the code | pressable | disabled, names the code | disabled, names the code | disabled, names the code |
| capture queue: the pending draft | pending 777 kg | pending 777 kg | pending 777 kg | pending 777 kg | pending 777 kg | pending 777 kg | pending 777 kg |
| capture queue: recent weighings of the probe scale (status) | 2 · in_calibration | 2 · in_calibration | 2 · in_calibration | 2 · in_calibration | 2 · in_calibration | 2 · in_calibration | 2 · in_calibration |
| base view `weighing_calibration_all` | 42501 | 42501 | 42501 | 42501 | 42501 | 42501 | 42501 |
| ticket page: status · gross / tare / net | complete · 12000 / 4000 / 8000 | same | same | same | same | same | same |
| ticket page: weighing rows · photo rows | 2 · 1 | 2 · 1 | 2 · 1 | 2 · 1 | 2 · 1 | 2 · 1 | 2 · 1 |
| ticket page: the ticket row | 1 row | 1 row | 1 row | 1 row | 1 row | 1 row | 1 row |
| calibration page: probe scale now | in_calibration · in use | same | same | same | same | same | same |
| calibration page: records of the probe scale | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| calibration page: settings (switch · lead days) | off · not set | off · not set | off · not set | off · not set | off · not set | off · not set | off · not set |
| pending values visible (V8 · V33) | V8 1 · V33 0 | same | same | same | same | same | same |
| reminder `capture_draft_pending` rows | **1** | 0 | **1** | **1** | 0 | 0 | 0 |
| staff session calling `capture_confirm_internal` | 42501 | 42501 | 42501 | 42501 | 42501 | 42501 | 42501 |

**Measured, and worth saying:** all seven roles hold `module.processing.view`, `module.inbound.view` and `module.logistics.view` today, so
all seven open all four pages and read the same rows. The differences are only in what they can press: confirming is warehouse · cto ·
admin (Q8), calibration is cto · admin (MES-1's code). The draft reminder reaches exactly the three who can confirm. V33 reads 0 because
live's only instruments are the retired probe scales (an instrument that is retired or `reserved` is not asked for a capacity).
No real account lacks both inbound and logistics view, so the "reader without either is refused" cell is in the photo proof (§6.3),
with an invented identity holding no code.

---

## §2 · Q31 — the 500-message timing (the first live step, before any DDL)

Run **2026-10-06 16:54–17:03 CST**, after the before readings (16:53:08) and before the backup and migration.

| measurement | how | result |
|---|---|---|
| **server-side statement time** | `db/scripts/2026-10-06-mes2-batch-timing-server.sql`, rolled back: admin@'s JWT issues a key to a probe gateway inside the transaction, then `SET LOCAL ROLE anon` with the JWT cleared (the identity PostgREST gives a gateway); `clock_timestamp()` before and after `ingest_submit` itself | 500 small messages (batch 51,827 B): **234.3 / 218.9 / 219.6 ms**; 500 messages near the 256 KiB cap (257,827 B): **252.1 / 253.2 / 253.5 ms**. All six `ok true · accepted 500 · rejected 0`. `SERVERTIME_OWN_EXIT=0` |
| whole call over HTTPS | `db/scripts/2026-10-06-mes2-batch-timing.mjs`, probe gateway DEV-2026-0003, device DEV-2026-0004, through `/rest/v1/rpc/ingest_submit` | small 47,456 B: 2,338 / 2,169 / 1,250 ms client wall time; near-cap 252,459 B: **25,462 ms** — all four HTTP 200, accepted 500. The 25 s is **this machine's upload** (the heartbeat round trip at the same moment was 350 ms; the statement itself is ≈ 250 ms, row above). The statement limit governs the statement, not the upload |

**Decision (Q31's rule):** the slowest server-side statement, 253.5 ms, is far under the ~1.5 s threshold and the 3 s anon limit →
**nothing changes**: `max_messages` keeps its bootstrap 500 and no function-level `statement_timeout` was added (that one always needs Tim).
`MES1-ANON-STATEMENT-TIMEOUT-3S` is closed in `docs/known-issues.md`, and the false sentence at `:10379` is struck in place with the
measurement beside it (Q34). The probe's rows stay as test data (§7, decision 13; `docs/known-wrong-until-cutover.md`).

**Incident inside it:** the fifth HTTPS call died on this machine's network (`TypeError: fetch failed`), so the script's own cleanup could not
reach live either (`TIMING_OWN_EXIT=6`, three cleanup steps unconfirmed). The cleanup plan was on disk (`.ephemeral/49237.json`);
`npm run reap:ephemeral` replayed it. The server-side measurement was then taken in the rolled-back script above, and
`db/scripts/2026-10-06-mes2-batch-timing-finish.mjs` processed the 2,000 received rows (all `transformed`, `connection_test`) and retired the
gateway (0 active keys) — `MES2_FINISH_EXIT=0`. Its throwaway role is in the change log as created 17:02:55 and deleted 17:03:02.

---

## §3 · Every item built

**Database** (`db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql`, built from the mirrors by
`db/scripts/build_mes2_migration.py`; 32 `CREATE FUNCTION` — 8 replacements, 24 new):

| item | where |
|---|---|
| 7 tables: `capture_drafts` · `capture_draft_changes` · `weighbridge_tickets` (`WB-YYYY-NNNN`, gapped) · `weighings` · `weighbridge_ticket_shares` · `weighbridge_ticket_photos` · `instrument_calibrations` — each with its guard trigger, RLS predicate and change-log binding | `db/tables/*.sql` |
| 2 settings on `ingest_settings`: `require_calibrated_since date` (NULL = off; stays NULL on live) · `calibration_lead_days integer > 0` (V8) | `db/tables/ingest_settings.sql`, `set_ingest_settings` |
| `ingest_data_classes.creates_draft`; the `weighing` row now `transform_weighing_v1` · `action.confirm_capture` · creates drafts; the table joins `SEED_TABLES` | `db/tables/ingest_data_classes.sql`, `db/check_mirrors.py` |
| dispatcher writes a draft for a transformed row of a drafting class; "Process received" also takes `awaiting_transform` rows whose class now has a transformer | `ingest_transform_row`, `ingest_process_pending` |
| weighing payload `{"weight_kg": n}` only (`WEIGHING_PAYLOAD_INVALID` / `WEIGHING_WEIGHT_INVALID`) | `transform_weighing_v1` |
| confirm (with any change + reason, re-validated by the same transformer, capacity check `WEIGHING_ABOVE_CAPACITY`, subject = none / new ticket / open ticket) · reject (reason) · manual entry (instrument optional and flagged; a failed transform stores nothing) · `correct_weighing` | `capture_confirm_internal`, `confirm_capture_draft`, `reject_capture_draft`, `submit_manual_capture`, `correct_weighing` |
| tickets: inbound first = gross, outbound first = tare; net ≤ 0 refused; complete on the second weighing; void with reason only while unshared | `capture_confirm_internal`, `void_weighbridge_ticket`, view `weighbridge_ticket_weights` |
| shares: to an existing receipt (`action.receive_goods`) or a shipment line (`action.ship_goods`); only from a complete ticket in the right direction; shared total shown against net, never refused | `share_weighbridge_ticket`, `weighbridge_share_internal` |
| receipt default and reasoned override **at receipt creation only**: three new trailing parameters on `create_inbound_batch` and `receive_inbound_batch_against_po` (`p_ticket_id`, `p_ticket_share_kg`, `p_quantity_reason`, all defaulted) | those two functions (DROP + CREATE) |
| photos in the private bucket `capture-photos` (read: inbound or logistics view; upload: `action.confirm_capture`; no update, no delete); register / withdraw with reason | `record_ticket_photo`, `withdraw_ticket_photo`; bucket + 2 policies in the migration only |
| calibrations: record / void (`action.manage_devices`); status derived on read (`calibration_status_from`: in_calibration · expired · failed · never_calibrated; `not_recorded` when a weighing has no instrument) | `record_instrument_calibration`, `void_instrument_calibration`, views `weighing_calibration_all` (owner, revoked) · `weighing_calibration` · `instrument_calibration_now` |
| the gate: `assert_receipt_reading_calibrated` in `reprice_inbound_batch`, `preview_reprice_inbound_batch` and `issue_cod` — three codes `READING_INSTRUMENT_NOT_RECORDED` · `READING_INSTRUMENT_NOT_CALIBRATED` · `RECEIPT_READING_NOT_RECORDED`, **only when the switch is set and the receipt was created on or after it** | those four functions |
| new code `action.confirm_capture` → warehouse · cto · admin | `db/tables/permissions.sql`, `role_permissions.sql` |
| 3 reminder arms (`capture_draft_pending` · `instrument_calibration_due` · `instrument_calibration_approaching`) → 52 arms; V8 · V33 in `pending_values` | `db/views/operations_now.sql`, `pending_values.sql` |
| trail subject `weighbridge_ticket` (weighings, shares, photos); calibrations under `device` | `trail_subjects`, `trail_subject_members` |
| document type `weighbridge_ticket` (43 types; search) | `db/tables/document_types.sql` |
| fixture 250 (15 arms) + 41 fault injections | `db/fixtures/250-…sql`, `db/scripts/2026-10-06-mes2-fixture-injections.py` |

**Bootstrap check (AGENTS.md RUNTIME CONFIG rule):** `ingest_settings` gained two columns whose bootstrap value is NULL — "off" and "not
yet supplied (V8)" — which is what they mean. Its other values (30 · 600 · 300 · 262,144 · 500) did not change meaning; Q31 measured
that 500 per call is still right. `ingest_data_classes` is now seed-compared, not runtime config: its 9 rows match live (gate line
`seed:ingest_data_classes live 9 mirrored 9 drifted 0`).

---

## §4 · Pages — every new or changed route, with its file

| route | file(s) | what |
|---|---|---|
| `/operation/capture` (new) | `app/operation/capture/page.tsx` · `CaptureControls.tsx` · `actions.ts` · `captureFields.ts` · `captureErrorCodes.ts` (+ `inbox/InboxControls.tsx`'s Process received) | pending drafts by age with Confirm (change + reason, subject) / Reject; manual weighing; recent weighings with changes, corrections and calibration status; Correct |
| `/operation/weighbridge` (new) | `app/operation/weighbridge/page.tsx` · `actions.ts` · `ticketFields.ts` | tickets with gross / tare / net, shared and difference, status; "Open a ticket" (the manual form, new-ticket subject) |
| `/operation/weighbridge/[id]` (new) | `app/operation/weighbridge/[id]/page.tsx` · `TicketControls.tsx` | the ticket: weighings, shares (receipt quantities through `inbound_batches_masked`, "Restricted" where unreadable), share form, photos (60-second signed links, upload, withdraw), void, audit trail |
| `/operation/calibration` (new) | `app/operation/calibration/page.tsx` · `CalibrationControls.tsx` · `actions.ts` | every instrument's status today and certificate history; record / void; the two settings (switch, lead days) |
| `/operation/devices/[id]` (changed) | `app/operation/devices/[id]/page.tsx` | a calibration section for instrument kinds |
| `/inbound/receive` (changed) | `page.tsx` · `ReceiveForm.tsx` · `actions.ts` · `app/inbound/TicketShareFields.tsx` · `app/inbound/ticketQuery.ts` | choose a complete inbound ticket; share defaults to what is left; quantity prefilled; reason required when it differs |
| `/inbound/new` (changed) | `page.tsx` · `NewInboundForm.tsx` · `actions.ts` (+ the two shared files) | same |
| `/inbound/[id]/edit` (changed) | `page.tsx` · `TicketSharesPanel.tsx` | the receipt's ticket shares and what the calibration rule will say (hidden when settings are unreadable) |
| pricing and certificate refusals | `app/inbound/pricingErrorCodes.ts` · `codErrorCodes.ts` | delegate the three gate codes to `localizeCaptureError` |
| `/settings/pending-values` | (no file change) | V8 and V33 rows come from the view |
| menu, reminders, search | `lib/modules.ts` (capture, weighbridge, calibration) · `lib/reminders.ts` (3 arms) · search type `weighbridge_ticket` | weighbridge sits under Operation, Inventory and Logistics |
| trails | `lib/trail/render.ts` · `lib/trail/text.ts` · `app/components/trail/AuditTrail.tsx` · `lib/trail/catalogue.generated.ts` | subject `weighbridge_ticket`; calibrations in the device trail |

Messages in `messages/en.ts` and `messages/zh.ts` (`capture.*`, `weighing.*`, `weighbridge.*`, `calibration.*`, receive ticket keys,
three dashboard items, V8 / V33, one search type).

---

## §5 · Verification, in the brief's order

| # | step | result | source |
|---|---|---|---|
| 0 | Q31 timing | §2 — before any DDL | `timing*.log` |
| 1 | offline gate | `GATEOFF_EXIT=0` (72 s) on the final mirrors | `gate-offline-final.log` |
| 2 | backup (background) | `BACKUP_EXIT=0` — `evoltrya-backup-2026-10-06-1928.dump`, 6.2 MB, TOC 7635 (previous 7465) | `backup.log` |
| 2b | live dry run (COMMIT → ROLLBACK) | `DRY_OWN_EXIT=0`, 19:41:39; reached `DRY_RUN_REACHED_COMMIT` with the function-grant replay | `dryrun.log` |
| 3 | apply_migration | committed atomically with the grant replay; **window start 2026-10-06 19:44:03 CST** (`db/migration-windows.tsv`; the script printed 19:42:08 at its start); pre-flight: 32 CREATE FUNCTION — 8 replacements, 24 new | `apply.log` |
| 4 | types | `TYPES_OWN_EXIT=0` after `NOTIFY pgrst` and 20 s | `typesgen.log` |
| 5 | tsc | first run 2 errors (`subjectJson` typed `Record<string, unknown>`, not the generated `Json`) → fixed → `TSC_OWN_EXIT=0`; again 0 after the layout fix | `tsc1–3.log` |
| 6 | build | first run red on the eslint freeze (1 new `react-hooks/purity`: `Date.now()` in the capture page's render) → moved to a module-level helper → `BUILD_OWN_EXIT=0`; again 0 after the layout fix | `build1–3.log` |
| 7 | full gate | `GATE_EXIT=0` (436 s) — 可重建性 ✓ · 镜像 vs 线上 ✓ (seed `ingest_data_classes` 9 / 9, drift 0) · 行为断言 ✓ (fixture 250) · 匿名面 ✓ (anon functions exactly `cod_verification`, `ingest_submit`; live ⊂ baseline 328) | `gate-full.log` |
| 7b | seed drift injection | gate's own `rows_json` + `SEED_TABLES` against live and a rebuild copy: clean drift 0; `creates_draft` flipped on `weighing` → drift 2 → a `problems` entry, which fails 镜像 vs 线上 (`gate.py:541`, `:776`). `SEED_DRIFT_OWN_EXIT=0` | `seed-drift.log` |
| 8 | i18n | `I18N_OWN_EXIT=0` | `i18n.log` |
| 9 | error swallowing | `SWALLOW_OWN_EXIT=0` (0 unallowed) | `swallow.log` |
| 10 | layout survey | 390 px first run **8 / 10**: `/operation/capture` and `/operation/weighbridge` overflowed **+103 px** (the manual weighing form, §5.1) → fixed → **10 / 10 at 390 px and 10 / 10 at 1280 px** (`SURVEY_EXIT=0` ×2). Routes: the four list routes, inbox, receive, new receipt, pending values, two instrument device pages, a receipt's edit page. `.next` removed before each run | `survey390*.log`, `survey1280.log` |
| 11 | smoke (background) | `SMOKE_EXIT=0` — 267 ok · 10 skipped (no data; `/operation/weighbridge/[id]` among them) · 0 FAILED; 241 timed routes, 840.6 s | `smoke.log` |
| 11b | scratch cleanup reading | `npm run check:scratch` after smoke: **the same 6 stale rows as every recent cut** (ZZ-SMOKE-PROBE, -M25, -NTF, -S25, -CJK, -IB25; 821–1464 h old, four still referenced) — none from this cut; `.ephemeral/` empty; no live lock | `scratch-after-smoke.log` |
| 12 | live verification | §1, §6 | |

**Re-runs after a file changed:** the layout fix (`CaptureControls.tsx`, class names only) landed after the build and the full gate; tsc
and the build (which carries the swallow, currency, i18n and every other static check) were re-run green, and both surveys ran on the
fixed tree. The gate's database verdicts read no app file; nothing it reads changed after it ran. The live-proof scripts changed after
the gate (they are not read by it).

### §5.1 · A defect the survey caught

At 390 px the manual weighing form put instrument, weight and time on one `flex-wrap` row, each label `flex-1 min-w-0` with no basis — so
the row never wrapped; each label shrank to about a third of the width and the date-time picker (fixed 9.75 rem + 4.75 rem, `shrink-0`)
stuck out of its label by ~100 px. Culprit named by the survey: the picker's input and its calendar icon. **Fix:** the first two labels
got minimum widths (`min-w-[10rem]`, `min-w-[7rem]`) and the time label takes its content width (`shrink-0`), so on a phone the time wraps
to its own line and on a desktop all three still share one. Both pages use the same form, so one fix cleared both.

### §5.2 · Security proof — fixture 250, arm by arm, each fault-injected

`db/scripts/2026-10-06-mes2-fixture-injections.py`: **41 injections, 0 wrong** (`INJECTIONS_OWN_EXIT=0`) — each mutates one function or
view, reruns the fixture on the local rebuild and requires it to go red **in the arm it names**; a clean run comes first.

| arm | what it pins | injections |
|---|---|---|
| DRAFT | weighing rows become pending drafts; connection_test does not | 2 |
| AWAIT | Process received picks up waiting rows whose class now has a transformer, and only those | 2 |
| CONFIRM | the code; change needs a reason; fixed fields stay fixed; re-validated by the transformer; one confirmation | 5 |
| REJECT | reason required; final; drafts never deleted | 2 |
| CORRECT | a new row keeping instrument and capture time; one correction per row | 2 |
| MANUAL | same path; failed transform stores nothing; the class's code is asked | 2 |
| CAP | capacity refuses when set; the instrument's unit counts | 2 |
| TICKET | gross / tare by direction; net ≤ 0 refused; no third weighing; no void once shared | 3 |
| SHARE | only from complete tickets; direction checked; over-share shown, never refused | 3 |
| RECEIPT | reason required when quantity ≠ share; none kept when equal | 2 |
| CAL | the four statuses; a late-entered certificate counts; a voided one does not | 3 |
| GATE | nothing refuses with the switch empty; three codes when set; preview and certificate gated too; receipts before the switch date not gated | 6 |
| ARMS | draft reminder only for confirmers; calibration-due skips reserved placeholders | 2 |
| PV | V33 skips reserved; each arm's code still asked | 2 |
| READ | drafts need processing view; the base calibration view and the inner confirm stay closed | 3 |

The first draft of two injections did not bite ("capture time" — the correction path never read it; and a PV check that ran after the
assertion it was meant to precede). Both were replaced (the first by "a correction loses the reading's instrument"), with a comment
saying why. **Trail wording:** `scripts/check-trail-wording.mjs` arm **⑯** pins 10 sentences (ticket opened / completed / voided,
weighing recorded / corrected, share, photo recorded / withdrawn, calibration recorded / voided); its fault `wording-drift-mes2` goes red
only in ⑯.

---

## §6 · Live verification — before and after

All three scripts run on live **inside one transaction each that ends in ROLLBACK**; every cell RAISEs on failure (`ON_ERROR_STOP`).

### §6.1 · The weighing path, the ticket, the gate — `db/scripts/2026-10-06-mes2-live-proof.sql`

`LIVEPROOF_OWN_EXIT=0`, 2026-10-06 20:30:58 CST:

| arm | reading |
|---|---|
| ① gateway | probe gateway (registered by phua@ in the transaction, key issued) sends **1,520 kg** as `anon` → fusheng@ processes → `{"processed": 1, "transformed": 1}` → draft pending. Confirm with 1,500 and no reason → `CAPTURE_CHANGE_REASON_REQUIRED\|weight_kg`. Confirm with 1,500 and "re-weighed after taring" → change row **1520 → 1500 · "re-weighed after taring"**. `correct_weighing` to **1,490** ("pallet was on the scale") → a new row pointing at the original; the original still reads 1,500 |
| ② manual | fusheng@ enters **12.5 kg** with no instrument → `source = manual`, status `not_recorded`; 0 kg → `WEIGHING_WEIGHT_INVALID` |
| ③ ticket + receipt | fusheng@ opens inbound ticket WB-2026-0003 ("ZZ 1234"): 12,000 then 4,000 → **complete, net 8,000**. A receipt (new material and supplier made in the transaction) with share 8,000 and quantity 7,950: no reason → `RECEIPT_QUANTITY_REASON_REQUIRED\|7950\|8000`; with "moisture drained before weighing in" → quantity 7,950, share 8,000, reason kept |
| ④ calibration and the gate | phua@ records a calibration on the weighbridge (warehouse is refused `PERMISSION_DENIED\|action.manage_devices`). A second receipt whose gross came from a never-calibrated scale. Both receipts fully processed by fusheng@ → two pending certificates. **Rule off:** the never-calibrated receipt — preview (tim@) OK, engine (tim@) OK, certificate (fusheng@) OK. phua@ sets `require_calibrated_since` = today. **Rule on, in calibration:** preview, engine, certificate all OK. **Rule on, out of calibration:** preview, engine and certificate all refused **`READING_INSTRUMENT_NOT_CALIBRATED\|DEV-2026-0012\|2026-10-06`** |

**Pricing on live is proven at the preview and the engine, not through a price request — measured, and not this cut's doing.** With
approvals on, a price is a request by the holder of `action.price_receipts` (only admin@) approved by the CFO (only tim@). admin@ and tim@
are **one person** (`account_person` equal), so every submission on live is refused `RECEIPT_PRICE_NO_OTHER_DECIDER` — ROLE-1 measured the
same (`docs/handbacks/ROLE-1.md:1130`); this run measured it again (`…|IN-2026-0478`). Both the submit and the approve path call the two
places the gate sits (the dry run → preview; the posting → engine), so the gate is proven where both paths pass. The full
**request → approval → posting** path, gated, was run once on a local rebuild with the 7 accounts replayed with their live roles and
approvals on: admin@ submitted, tim@ approved, the price posted; the out-of-calibration request was refused at submit with the same code.

### §6.2 · Roles — §1.

### §6.3 · Photos — `db/scripts/2026-10-06-mes2-capture-photos-policy-proof.sql`

`PHOTOPROOF_OWN_EXIT=0`, 2026-10-06 20:31:58 CST, on the real `storage` schema. Identities **by permission**: fusheng@ (confirm + both views),
tim@ (both views, no confirm), an invented UUID holding only `module.inbound.view`, one holding only `module.logistics.view` (two probe
roles granted inside the transaction — `user_roles.user_id` has no foreign key, so **no account was created**), and an invented UUID with
no code at all.

| cell | reading |
|---|---|
| C1 upload | fusheng@ OK · tim@ 42501 · inbound-only 42501 · logistics-only 42501 · no-code 42501 |
| C2 register | fusheng@ OK · tim@ `PERMISSION_DENIED` · a path outside the ticket `TICKET_PHOTO_PATH_INVALID` |
| C3 / C4 read (object / record) | fusheng@ 1/1 · tim@ 1/1 · inbound-only 1/1 · logistics-only 1/1 · **no-code 0/0 — refused** |
| C5 withdraw | fusheng@ OK (reason kept; object and record stay) · tim@ `PERMISSION_DENIED` · blank reason refused |
| C6 bucket | fusheng@ updating or deleting the object: **0 rows** each (no update or delete policy) |

C6 needs `session_replication_role = replica` to get the platform's statement-level delete trigger out of the way (as UI-1d did). Live
refused `set_config` of it inside a DO block ("permission denied to set parameter"); a top-level `SET LOCAL` is allowed, so C6 runs in a
second block after C1–C5, which therefore ran with every trigger on. **The script's fault injection** (`-v inject=1`: the read policy
loses its permission predicate; C4 must RAISE) was run on a local stub of `storage.objects` carrying the migration's two policies,
where it went red at C4 — **not on live** (§7, decision 17).

### §6.4 · Before and after

**Before** 2026-10-06 16:53:08 CST (before the timing probe, the backup and the migration), **after** 2026-10-06 20:32:40 CST (after the
three live scripts) — `db/scripts/2026-10-06-mes1-live-readings.sql` as postgres, one line per public base table (row count + digest).

**Tables: 249 before, 256 after; every difference explained:**

| table | before → after | why |
|---|---|---|
| the 7 new tables | — → **0 rows each** | the live proofs rolled back |
| `devices` | 2 → 4 | DEV-2026-0003 / 0004, the Q31 probe (retired) |
| `gateway_keys` | 2 → 3 | its key (revoked) |
| `ingest_transmissions` | 11 → 16 | its 4 calls + 1 heartbeat bucket |
| `ingest_inbox` | 5 → 2,005 | its 2,000 `connection_test` messages, all transformed |
| `ingest_settings` | 1 → 1, digest changed | the two new columns (both NULL) |
| `ingest_data_classes` | 9 → 9, digest changed | the `weighing` row: transformer, code, `creates_draft` |
| `permissions` · `role_permissions` · `document_types` | 74 → 75 · 345 → 348 · 42 → 43 | the migration: one code, its three grants, one document type |
| `cod_verification_failures` | 1 → 1, digest changed | smoke's `/verify/cod/[token]` probe writes its rate-limit row by design (MES-1, U1-A, U1-B saw the same) |
| everything else | identical | — |

**Change log:** 9,269 → 10,142 rows (+873), max seq 10,495 → 11,375 (+880). By table: the migration's 6 rows; the timing probe's 6
(devices, key); 7 throwaway roles each created and deleted — timing probe ×2 (16:54, 17:02), the accidental smoke start (19:11, §7
incident), survey ×3 (19:59, 20:03, 20:06), smoke (20:11) — with their grants (role_permissions +381 / −378: the +3 are the migration's)
and user_roles 7 / 7; smoke's own fixtures (employees 12 / 12, reviews 5 / 5 / 5, contracts and their terms, all created and deleted);
the COD rate-limit row. The 7 missing sequence numbers are mine and rolled back: **10507** (the server-side timing script's key, 17:02) and
**10698–10703** (the six rows of the migration dry run, 19:41). Nobody else wrote to live in the window.

**Summary lines identical before and after:** 7 accounts · 0 disabled · 0 throwaway · approvals ON · 0 grants without account; the same
role per account; 1 pending document, CLM-2026-0004, 1,000.00. **`require_calibrated_since` is NULL** (role table row "off · not set").
**Reconciliation** (`db/scripts/2026-10-05-at1d3-live-recon.sql` as tim@): payables 422,188.32 list / 381,604.42 ledger, **0.00
unexplained**; receivables 57,545.87 / 43,002.12, **0.00 unexplained** — before and after, identical.

**Nothing of mine remains** apart from the Q31 probe gateway's own rows (its two devices, key, transmissions and inbox) — the live
verification itself left nothing. Gapped document numbers used by the rolled-back runs are gone, as gapped numbering allows (the first
real ticket will be WB-2026-0008; `docs/known-wrong-until-cutover.md`).

### §6.5 · Broken window

**Start 2026-10-06 19:44:03 CST** (measured: `db/migration-windows.tsv`). **End = the moment Tim sees the deployment succeed on Vercel**
(a report, not a measurement from this machine — the next close-out records it). Inside it, the verification after the migration ran
(types, tsc, build, full gate, surveys, smoke, the three live scripts, the readings).

**What was broken inside it** (derived from the old code and this migration, not measured on live): **nothing.** The two receipt functions
were dropped and re-created with three new trailing parameters, all defaulted, so the old app's calls resolve unchanged (after
`NOTIFY pgrst`); pricing and certificates give the old result while the switch is empty; the old app reads none of the new tables or
views; `operations_now` keeps its columns, so the old reminders page skips the three new arms. The one behaviour change — a `weighing`
inbox row now becomes a draft — had nothing to act on: live has no `weighing` inbox rows.

---

## §7 · Decisions taken without asking

1. **The calibration gate refuses only when the switch applies — all three codes.** Step 0 §7 had `READING_INSTRUMENT_NOT_CALIBRATED`
   refusing regardless of the switch; the brief says "nothing refuses when it is NULL". I followed the brief: with the switch empty, or for a
   receipt created before the switch date, nothing refuses (fixture GATE pins both directions).
2. **No `capture_drafts.weighing_id`.** The weighing carries `draft_id` (unique); one direction of the link is enough and cannot disagree.
3. **Choosing a subject (none / new ticket / open ticket) is not a "change"** — no change row; only measured fields (`weight_kg`) are.
4. **Gross or tare is derived from the ticket's direction**: inbound — first weighing gross, second tare; outbound — first tare, second
   gross. Nobody picks it.
5. **Vehicle registration is upper-cased** on the way in, so "zz 1234" and "ZZ 1234" are one vehicle.
6. **Capacity units:** kg, t (× 1,000), g (× 0.001); an instrument with no unit is read as kg.
7. **A correction keeps the original reading's instrument and capture time** — it corrects the number, not when or on what it was weighed.
8. **Shares and photos are append-only.** A photo is withdrawn with a reason (row and object stay). A share cannot be removed in this cut,
   and a ticket with a share cannot be voided (`TICKET_HAS_SHARES`) — so a wrong share stays, and the ticket page shows the shared total
   against net. Undoing a share is named here, not built.
9. **The two calibration settings live on `/operation/calibration`**, not on the devices page's settings panel.
10. **The capture queue does not process the inbox when it loads** (a GET should not write); it carries the Process received button.
11. **Bucket objects cannot be deleted** (no delete policy). The server action re-checks the type before registering; a refused object
    would stay in the bucket unregistered — the bucket's own type and size limits stop that before it happens.
12. **The weighbridge menu entry sits under Operation, Inventory and Logistics** (one function, three owner modules).
13. **The Q31 probe's rows stay as test data** — they are append-only by design; one line in `docs/known-wrong-until-cutover.md`.
14. **The gateway arm of the live proof ran as `anon` inside the rolled-back transaction, not over HTTPS**, so nothing of it remains. The
    HTTPS path itself was exercised the same day by the Q31 probe (four HTTP 200s); the `weighing` class has not been sent over HTTPS.
15. **Pricing on live proven at the preview and the engine** (§6.1) — the request path cannot run on live (one person holds both ends);
    it was run on a local rebuild.
16. **`/operation/weighbridge/[id]` was not surveyed or smoke-tested with a row.** Live has no ticket and a ticket cannot be deleted, so
    surveying it would leave a document of mine on live, which the brief forbids. Its data sources are covered by the role table (§1:
    status, weights, weighings, photos, ticket row — all seven roles) and fixture 250; **its rendering with a real ticket is unmeasured** —
    the first real ticket's page is the first time it renders with data.
17. **The photo proof's fault injection was not run on live.** It drops and re-creates a policy on `storage.objects` inside the
    transaction, which locks the table for every live user while it runs; colleagues are testing on live. It ran on a local stub carrying
    the migration's own two policies, and went red at C4.
18. **C6 (no update / delete on bucket objects) runs in its own top-level block** (§6.3) — the measured constraint, not a preference.
19. **A product bug the fixture found, fixed:** `set_ingest_settings` raised a raw cast error on an impossible date; the date is now
    validated in its own block and refused `INGEST_SETTING_INVALID|require_calibrated_since`.
20. **The local scratch cluster** used for fixture and injection reruns was kept running during the cut and stopped at the end.

**Incidents (both before the migration, both cleaned up and measured):**
- **The Q31 HTTPS probe died on the network mid-run** (§2) — reaped from its on-disk plan; its throwaway account, role and grant are
  created-and-deleted in the change log.
- **An accidental smoke run, 19:11–19:14 CST.** `node scripts/smoke-routes.mjs --preflight-only` was meant as a pre-flight check;
  `--preflight-only` is not a flag, so a full smoke started against live. Stopped with SIGTERM, which runs smoke's cleanup path; afterwards
  0 throwaway users, 0 probe roles, 0 orphan grants, `.ephemeral/` empty, no lock. In the change log as `probe-smoke-all-1791285113916`
  created 19:11:55, deleted 19:14:04, with its fixture rows created and deleted in the same span.

---

## §8 · Assertions measured and found false or imprecise

- **`docs/known-issues.md:10379`** "fixture 249 的 SIZE 臂在本地跑过 500 条一批" — false (the arm sends 501, refused before the loop); struck
  in place with the measurement (Q34).
- **`db/functions/record_ticket_photo.sql` header** said the server action deletes an object whose type it refuses — false: nothing can
  delete from this bucket. Corrected before the migration was built.
- **The repo's own hand-back §7 vs the brief** on whether `READING_INSTRUMENT_NOT_CALIBRATED` refuses with the switch empty — §7, decision 1.
- **The brief's "send a weighing through a probe gateway … leave the probe gateway's own inbox and transmission rows"** — the proof leaves
  none (decision 14); the only probe rows on live are Q31's.

---

## §9 · Docs updated

`docs/forward-queue.md` (item 37; MES-2 ✅; MES-3a next) · `docs/mes-pending-values.md` (V8, V33 and what each holds back) ·
`docs/integration/gateway-interface.md` (§7a, the weighing payload) · `docs/role-matrix.md` (`action.confirm_capture`) ·
`docs/change-log.md` (§1 count 249 of 256; §13) · `docs/dashboard-arm-inventory.md` (M2a–M2c and their links) ·
`docs/known-issues.md` (Q34 strike; `MES1-ANON-STATEMENT-TIMEOUT-3S` closed with the timing) · `docs/known-wrong-until-cutover.md`
(the Q31 probe's rows; the gapped numbers) · `docs/surveys/MES-2/STEP0-HANDBACK.md` (Tim's acceptance) ·
`docs/surveys/AUDIT-TRAIL-0/labels.csv` (+86 rows) · this file.
