# MES-2 Step 0 — hand-back (2026-10-06)

**Contents:** Step 1 (MES-1 close-out) results §1 · what grilling changed §2 · MES-2 design (a)–(i) §3–§11 · every open question §12 ·
time estimate (j) §13 · assertions found false §14 · stop §15.

**STOP GATE.** No code, no migration, no live read or write. The only writes are docs: `docs/forward-queue.md` (close-out, commit
`e4318683`) and this file. Waiting on Tim's answers to Q1–Q35 (§12).

> **★ Tim's answers (2026-10-06, the MES-2 build brief):** "Every recommendation in docs/surveys/MES-2/STEP0-HANDBACK.md, Q1 to Q35, is accepted exactly as stated there." "All MES-0 (Q1–Q96) and MES-1 (Q1–Q30) rulings stand, as amended by these answers." Built as `v1.4.38`; hand-back `docs/handbacks/MES-2.md`. One conflict between §7 and the brief (whether `READING_INSTRUMENT_NOT_CALIBRATED` refuses while `require_calibrated_since` is empty) was resolved in the brief's favour — "nothing refuses when it is NULL" — and is listed there among the decisions taken without asking.

**Opening check.** This session's first command printed **2026-10-06 16:16:05 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` =
`git ls-remote origin main` = **`95b43594bf8e08c14735365568980e41c93d2e5c`** (MES-1, `v1.4.37`). Files staged by explicit path only.

**Live state — not re-measured.** This block made no database connection. The brief's live state (approvals ON finance / cfo / 1,000; 7
accounts enabled; EXP-2026-0010 by chooer@ untouched) is the last measured state (`docs/handbacks/MES-1.md` §5, 16:04:55 CST). Nothing of
anyone's was touched.

**How the facts were gathered.** Five read-only sub-agents (MES-1 as built and the 500-message timing; receipts, shipments and storage;
the calibration gate's pricing and certificate paths; permissions, change log, trail and registries; cut-duration calibration from git
reflog, log `stat`s and session transcripts). No sub-agent connected to a database or ran a build. I re-read the claims this hand-back rests
on at their cited lines (§14 lists the two the agents found false and I confirmed, and one agent claim I found false). Tags: **[M]** measured
(file:line, grep, reflog, `stat`) · **[I]** inferred from code reading · **[Q]** quoted from an earlier hand-back's measurement ·
**[S]** the specification PDF.

---

## §1 · Step 1 — MES-1 close-out, item by item

### 1.1 Broken window closed ✅ (written, `e4318683`)

`docs/forward-queue.md` item 36, in U1-B's format:
- start **2026-10-06 11:39:23 CST** [M] — `db/migration-windows.tsv`: `2026-10-06T11:39:23+0800	2026-10-06-mes1-entry-point.sql	ed6d2f11`;
- end, lower bound **2026-10-06 16:07:50 CST** [M] — `git reflog show --date=iso refs/remotes/origin/main`:
  `95b43594 refs/remotes/origin/main@{2026-10-06 16:07:50 +0800}: update by push`;
- end, upper bound **2026-10-06 16:16:05 CST** — this session's first command; it rests on Tim's "deployed", not on a Vercel reading.
- **Window: at least 4 h 28 min 27 s, at most 4 h 36 min 42 s.** Long because the live verification ran inside it and the session paused
  once at Tim's request (11:50:57 → 14:40:12, measured from the transcript, §13). Broken in it (derived, MES-1 §5.1): nothing; the two new
  reminder rows were invisible to the old reminders page.

### 1.2 MES-2 timing item ✅ (written, `e4318683`)

`docs/forward-queue.md`, MES block, row 2 (MES-2): «Tim(MES-1 close-out,2026-10-06):在线上给一次【满 500 条消息】的网关调用计时,对着 `anon`
角色 3 秒的语句上限;太慢就在本刀解决 —— `docs/known-issues.md` 的 `MES1-ANON-STATEMENT-TIMEOUT-3S`». Design: §8, Q31.

### 1.3 Read-only verification of what the MES-1 report did not mention

| | item | verdict | evidence [M] |
|---|---|---|---|
| a | `/settings/pending-values` lists V5 and V6 through `pending_values`, each arm with its own permission; both rows in the doc | ✅ | page `app/settings/pending-values/page.tsx:23` `requireFunction(FN.pendingValues)`, `:28-30` `mustRows(await supabase.from('pending_values').select('value_code, item_id, item_code, item_label, href')…)`; view `db/views/pending_values.sql:20-21` `SELECT 'V5'::text AS value_code, 'module.processing.view'::text AS permission`, `:29-30` the same for `'V6'`, `:37` `WHERE has_permission(p.permission)` (each arm carries its own `permission` column; both are `module.processing.view` today); fixture 249 arm PV `:446-456` (a reader without the code sees 0); `docs/mes-pending-values.md:21` (V5) and `:22` (V6) |
| b | Interface doc covers transport, envelope, heartbeat, responses, back-fill, key rotation, `connection_test` | ✅ | `docs/integration/gateway-interface.md` headings `:29` "## 2. Transport", `:67` "## 3. Sending readings — the message envelope", `:103` "## 4. Heartbeat", `:119` "## 5. Responses", `:170` "## 6. Retries and back-fill", `:198` "## 8. The `connection_test` class", `:218` "## 9. Key rotation" (plus §1 setup, §7 after receipt, §10 commissioning checklist) |
| c | Role matrix has the new code, device management with cto and admin; change-log doc records the excluded ingestion tables and the `never` rule | ✅ | `docs/role-matrix.md:125` "设备与网关、网关钥匙 · devices, gateways, gateway keys \| cto · admin \| — \| ✅ done(MES-1…新码 `action.manage_devices` → cto 与 admin…)"; `:217` code row "`action.manage_devices` … \| cto · admin". `docs/change-log.md:56-58` the three rows `gateway_outages` / `ingest_inbox` / `ingest_transmissions` "**ingestion log (MES-1)**…", `:60` "Ingestion logs are the second accepted kind of exclusion"; `:976` "### 12.2 The "never" mask rule", `:978` "gained a fourth rule form, **`never`**", `:983` "104 → 105" |
| d | `docs/known-wrong-until-cutover.md` has the probe-gateway line | ✅ | `:231` "设备 **DEV-2026-0001**(网关,`ZZ-PROBE-GW-1791270494758`)与 **DEV-2026-0002** … 两台都已停用 … 另有一行报上来的编号为 `ZZ-PROBE-GW-UNKNOWN-1791270494758` 的拒绝日志" |
| e | The device page shows the free-plan line | ✅ | `app/operation/devices/page.tsx:117` `notices={<p … data-free-plan-notice="1">{t('devices.freePlan')}</p>}` (always); `app/operation/devices/[id]/page.tsx:134` the same line inside `gatewayBlocks` (gateway pages); text `messages/en.ts:9678` "The database is on the free plan: it pauses when idle and has no point-in-time recovery. Move to a paid plan before a real device connects. Test gateways may run on the free plan." (`zh.ts:9445`). ⚠ measured, not a gap I counted: a **non-gateway** device's own page (`/operation/devices/[id]` for a scale) does not carry the line; the Devices page and every gateway page do — see §1.5 |
| f | The three stale GHOST-GRANTS / forwarder-Remove notes struck, pointing to U1-B | ✅ | `docs/forward-queue.md:3460-3463` (`~~…GHOST-GRANTS…仍然开着。~~` then "★ **划掉于 MES-1(2026-10-06,MES-1 Step 0 Q30,Tim):`GHOST-GRANTS` 已由 U1-B(2026-10-05)关闭**"); `docs/known-issues.md:8763-8764` (PROBE-KILL-LEAK header, `~~GHOST-GRANTS,仍然开着~~ ★ 划掉于 MES-1 … 已由 U1-B 关闭`); `docs/known-issues.md:8439-8442` (DRAFT-6 ForwarderPanels, `~~⚠ 这一笔【原样还在】~~ ★ 划掉于 MES-1 … U1-B 已把这张表换到共用的 DataTable,「Remove」常驻可见`) |
| g | Two reminder arms under `module.processing.view` | ✅ | `db/views/operations_now.sql:534-535` `SELECT 'gateway_silent'::text AS item_type, 'module.processing.view'::text AS permission`; `:544-545` the same for `'capture_inbox_failed'`; outer filter `:764` (neither arm is named in `arm_permission_widen` / `arm_permission_any` — grep of both function mirrors → 0); `lib/reminders.ts:212,214` `permission: 'module.processing.view'`; fixture 111 `:59,:64` |
| h | `ingest_submit` revoked from `authenticated` and `service_role`, asserted in the fixture | ✅ | `db/views/zzz_function_grants.sql:596` `GRANT EXECUTE … ingest_submit(text, text, jsonb) TO anon`, `:601` `REVOKE EXECUTE … FROM authenticated, service_role`; fixture 249 arm GRANT `:199-202` `IF has_function_privilege('authenticated', 'public.ingest_submit(text,text,jsonb)', 'EXECUTE') THEN RAISE EXCEPTION 'FIXTURE 249 GRANT: authenticated can execute ingest_submit (Q4)'` and the same for `service_role`; MES-1 §4.2 injections "granted back to authenticated · granted to service_role … each red in GRANT" [Q] |

### 1.4 MES-1's self-taken decisions (`docs/handbacks/MES-1.md` §6, titles)

1. The bootstrap admin holds `action.manage_devices`. 2. Throttled and over-budget authentication failures answer `refused`.
3. `too_large` / `too_many` / `malformed` are named only to authenticated callers. 4. Unknown, retired and other-gateway devices share
`DEVICE_NOT_ON_THIS_GATEWAY`. 5. Retiring a gateway also revokes its keys. 6. Discarding an inbox row keeps its error code. 7. Transform
functions are IMMUTABLE and take only the payload. 8. `save_device(p_fields jsonb, p_id uuid DEFAULT NULL)` parameter order. 9. The trail
shows a key by its 8-character prefix without `ngk_`. 10. The anomaly view has no out-of-hours arm until V6 is supplied. 11. The inbox sits
in the menu under Devices. 12. Settings › Pending values is gated `module.processing.view`. 13. No spec-appendix row per device. 14. The
heartbeat body is `{"heartbeat": true}` and nothing else. 15. The overflow bucket is a fixed 600 s. 16. At most two active keys per gateway.
17. `/operation/devices/[id]` came off smoke's expected-skip list. 18. The diagnostic script that found the 500 is committed. 19. The probe
also registered an unknown-gateway refusal under `ZZ-PROBE-GW-UNKNOWN-…`.

### 1.5 Judgement on the stop rule

**Every item a–h is present. Step 2 therefore ran.** One measured nuance, stated so it is not discovered later: item e reads "the device
page". The line is on the **Devices page** (`/operation/devices`, unconditional) and on **every gateway's page**; a scale's own detail page
does not carry it. MES-1 Step 0 Q26 said "the device page shows one line", and the risk it states ("before a real device connects") is a
gateway's act, so I judged e present. **If Tim reads e as "every device detail page", e is partly done and §2 onward should be set aside
until it is fixed** (a one-line move of the notice out of `gatewayBlocks`, `app/operation/devices/[id]/page.tsx:134`). Not fixed here.

---

## §2 · What grilling changed in MES-2's scope

1. **Seven tables, not six.** The photo bucket needs a metadata table (the house pattern: `finance_attachments`, every `*_attachments`),
   and the ticket → receipt / shipment link is its own table. **Q1.**
2. **A transformer cannot write the draft.** Transformers are IMMUTABLE and receive only the payload (`db/functions/ingest_transform_row.sql:49`;
   MES-1 decision 7), and the only place their output lands today is `ingest_inbox.transform_result` [M]. So the **dispatcher** must create the
   draft, and the class registry must say which classes produce one. **Q4.**
3. **The dispatcher never picks up `awaiting_transform` rows** (`ingest_process_pending.sql:23-24` selects `status='received'` only) [M].
   When `weighing` gets its transformer, any waiting weighing rows would need `retry_inbox_row` one by one, under `action.manage_devices`.
   **Q6.**
4. **The receipt quantity is immutable after creation** (`db/tables/inbound_batches.sql:163-167` `trg_inbound_batches_quantity_guard` →
   `QUANTITY_IMMUTABLE`) [M]. Q21's "defaults to the ticket's share and can be changed with a reason" can therefore only happen **at receipt
   creation**; linking a ticket to an existing receipt shows the difference and cannot change the quantity. **Q19.**
5. **Shipments do not take a ticket in their form.** `ship_order` books money from the reservation quantity, after an invoice that already
   exists (`ship_order.sql:118` `SO_SHIP_NOT_INVOICED`; `:86`, `:216-234`) [M]; the outbound ticket's tare-then-gross pair completes around
   loading. The share is linked to shipment lines **from the ticket page**, and changes no money. MES-0 §8.2 said "receipt and shipment
   forms pick a ticket". **Q20.**
6. **The calibration gate is two functions, not "3–4".** Every receipt-pricing path lands in one engine, `reprice_inbound_batch`
   (`reprice_inbound_batch.sql:30-34` "这是每一条定价路径(建单带价、定价面板、按已承诺条款改价、应用化验)都落进来的那一支引擎") [M], and the only
   certificate that certifies a weighed quantity today is the COD (`cod_certificate_data.sql:23,80` prints `ib.quantity`) [M]. Gate there,
   plus the preview that shares the engine's arithmetic. Nothing on the output side or in sales carries a reading until MES-4a. **Q27.**
7. **"Never calibrated" needs a ruling.** Q30 refuses "an instrument that was out of calibration"; an instrument with no calibration record at
   all is not covered by those words. **Q25.**
8. **The switch should be a date, not a boolean.** A boolean switched on refuses pricing for every older receipt that never had a reading
   link. **Q26.**
9. **The 500-message call has never been timed** — not even locally (§14 item 1). The first live step of MES-2 is that measurement, before
   any DDL, so that if it is too slow the fix rides in MES-2's one migration. **Q31.**
10. **`capture-photos` would be the first storage bucket whose READ is gated by a permission** (every existing bucket reads by `bucket_id`
    alone, the real gate being the metadata table — e.g. `db/migrations/2026-09-07-cod1b-the-bucket.sql:17-19`) [M]. Buckets are not in the
    mirrors, so its proof is a live rolled-back script, not a fixture (AGENTS.md "存储桶与它的策略【不在镜像里】"). **Q21.**
11. **Capacity** is on `devices` (`devices.sql:35`, NULL allowed) [M]. A reading above the instrument's capacity is not a measurement. MES-2
    can refuse it at confirmation when capacity is set, and list in-use instruments without capacity as a pending value. **Q12.**
12. **`ingest_data_classes` is not row-compared by `check_mirrors`**, though its header says it is (§14 item 2). MES-2 changes that seed
    (`weighing` gets its transformer), so a mis-seed would go unseen. **Q5.**
13. **Estimate:** MES-0 said 7 h 40 m – 13 h 30 m; recalibrated on MES-1's measured active time to **≈ 1 h 05 m – 1 h 55 m floor + 1 h 30 m –
    3 h 15 m work** (§13).

---

## §3 · (a) Exactly what MES-2 contains, against the MES-0 cut plan

MES-0 §8.2 row 2 [M, `docs/surveys/MES-0/README.md:696`]: "`capture_drafts`, `capture_draft_changes`, `weighings`, `weighbridge_tickets`
(+ links to receipts/shipments), `instrument_calibrations`, photo bucket; manual-capture path; weighing transform; calibration gate in
price-setting functions and `issue_cod`; receipt and shipment forms pick a ticket — 6 / 4".

### 3.1 Tables (7) — Q1

| table | purpose | change log | read | write |
|---|---|---|---|---|
| `capture_drafts` | one per transformed inbox row of a drafting class: `inbox_id` (unique), `data_class`, `device_id`, `source`, `station` (copied), `proposed jsonb` (transform output), `status` (`pending` · `confirmed` · `rejected`), `confirmed_by/at`, `rejected_by/at/reason`, `weighing_id` (the formal record) | logged | `module.processing.view` | functions only |
| `capture_draft_changes` | one per field changed at confirmation: `draft_id`, `field`, `original_value jsonb`, `confirmed_value jsonb`, `reason` NOT NULL non-blank | logged | `module.processing.view` | functions only; append-only |
| `weighings` | the formal record: `inbox_id` (unique), `draft_id` (unique), `device_id` (NULL = instrument not recorded), `source`, `weight_kg`, `role` (`gross` · `tare` · `net`), `ticket_id` (nullable), `site_from/to`, `site_dataset_ref`, `captured_at` (site time, else confirmation time), `confirmed_by/at`, `corrects_id` + `correction_reason` | logged | processing OR inbound OR logistics view (Q22) | functions only; append-only, statement-level DELETE refusal |
| `weighbridge_tickets` | `code` `WB-YYYY-NNNN` (gapped), `direction` (`inbound` · `outbound`), `vehicle_reg`, `device_id` (the weighbridge), `gross_weighing_id`, `tare_weighing_id`, `status` (`open` · `complete` · `voided`), `net_kg` (set at completion, gross − tare), `notes`, void fields | logged | inbound OR logistics view | functions only |
| `weighbridge_ticket_shares` | `ticket_id`, exactly one of `inbound_batch_id` / `shipment_line_id` (the `payment_allocations` XOR shape, `payment_allocations.sql:30`), `kg` > 0, `receipt_quantity_reason` (when the receipt's quantity differs from `kg`), unique (ticket, target) | logged | inbound OR logistics view | functions only |
| `weighbridge_ticket_photos` | `ticket_id`, `file_path`, `mime`, `bytes`, `uploaded_by/at`, `withdrawn_at/by/reason` | logged | inbound OR logistics view | functions only |
| `instrument_calibrations` | `device_id`, `calibrated_on`, `valid_until` (required, ≥ `calibrated_on`), `result` (`passed` · `failed`), `certificate_no`, `calibrating_body`, `notes`, `recorded_by/at`, `voided_at/by/reason` | logged (member of the `device` subject) | `module.processing.view` | `action.manage_devices` |

Settings: two columns on the existing `ingest_settings` row (Q26, Q30), not a new table. Bucket: `capture-photos` (Q21).

### 3.2 Functions

| function | gate | what |
|---|---|---|
| `transform_weighing_v1(payload) → jsonb` | internal | validates `{"weight_kg": n}` (Q7); IMMUTABLE, payload only, like `transform_connection_test_v1` |
| `ingest_transform_row` (changed) | internal | after `transformed`, creates the `capture_drafts` row when the class drafts (Q4) |
| `ingest_process_pending` (changed) | `module.processing.view` | also takes `awaiting_transform` rows whose class now has a transformer (Q6) |
| `submit_manual_capture(p_data_class, p_device_id, p_payload, p_site_from, p_site_to, p_subject)` | the class's `manual_entry_code` (weighing → `action.confirm_capture`, Q15) | inbox row `source='manual'` → same transformer → draft → confirmed in the same step (Q13) |
| `confirm_capture_draft(p_draft_id, p_overrides, p_reasons, p_subject)` · `reject_capture_draft(p_draft_id, p_reason)` | `action.confirm_capture` | §4 |
| `correct_weighing(p_weighing_id, p_weight_kg, p_reason)` | `action.confirm_capture` | new row with `corrects_id` (Q11) |
| `open_weighbridge_ticket` · `void_weighbridge_ticket` · `share_weighbridge_ticket` · `record_ticket_photo` · `withdraw_ticket_photo` | §6 | tickets |
| `record_instrument_calibration` · `void_instrument_calibration` | `action.manage_devices` | §7 |
| `instrument_calibration_status(p_device_id, p_at timestamptz) → text` | internal | `in_calibration` · `expired` · `failed` · `never_calibrated` (Q25) |
| `assert_receipt_reading_calibrated(p_batch_id)` | internal | the gate helper (Q26, Q27) |
| `reprice_inbound_batch`, `preview_reprice_inbound_batch`, `issue_cod` (changed) | unchanged | call the helper (Q27) |
| `create_inbound_batch`, `receive_inbound_batch_against_po` (changed) | unchanged | take an optional ticket share (Q19) — new parameters **at the end, with defaults**, so the deployed app's calls still resolve (§11) |

### 3.3 Pages (4 routes) — Q2

`/operation/capture` (the confirmation queue: pending drafts by age with station, confirm / reject; confirmed tab; **Record a weighing**,
the manual form) · `/operation/weighbridge` (tickets, open a ticket by hand) · `/operation/weighbridge/[id]` (gross, tare, net, vehicle,
direction, photos, shares with their sum against net, trail) · `/operation/calibration` (every in-use instrument with its status and
valid-until; record / void a calibration).
Changed, not new: `/operation/devices/[id]` (calibration section for instruments) · `/inbound/receive` and `/inbound/new` (pick a ticket,
Q19) · `/inbound/[id]` (ticket share, "instrument not recorded" flag, Q28) · the receipt pricing panel (refusal text) · the devices
page's settings panel (two settings) · `/settings/pending-values` (V8, V33).

### 3.4 Left to later cuts

- **MES-4a:** weighings attached to batches or run legs (Q22 of MES-0: output legs reference a weighing); every output-side quantity
  (`commit_processing_run`, `allocate_processing_costs`, `sale_settlement_compute`, `traceability_report_data`, `record_output_sale`); and with
  them the calibration gate on those paths.
- **MES-6b:** the CoA and its calibration precondition (MES-0 Q68).
- **Every other data class's transformer** (discharge 5a, controller / workstation 4a, meter 5a, scan 3b, inline quality 6a, alarm 7b).
- **Not in this group at all:** gating `ship_order` on a reading (Q20).
- **Calibration certificate files** (the scanned certificate): not in MES-2 (Q24).

---

## §4 · (b) The confirmation flow

**Shape of a draft** — §3.1. One draft per inbox row (`capture_drafts.inbox_id` unique), created by the dispatcher in the same subtransaction
as the `transformed` status (Q4), so a row is never `transformed` without its draft. `proposed` is the transformer's output, verbatim.

**Who confirms:** `action.confirm_capture` — warehouse, cto, admin (MES-0 Q11, ruled; `docs/surveys/MES-0/README.md:786-787`). Any holder,
any station; the station is shown. New code at `sort_order` 1230 after `action.manage_devices` (`db/tables/permissions.sql:174`) [M], granted
in the migration with the MES-1 before / after proof (`2026-10-06-mes1-entry-point.sql:82-95`, `:3673-3685`) [M]; the bootstrap mirror gives
it to warehouse and admin (it has no cto role, `docs/known-issues.md` ROLE1-BOOTSTRAP-MISSING-ROLES) [M].

**Original and new values with the reason:** `confirm_capture_draft` merges the overrides into `proposed`, **re-runs the same transformer**
on the merged payload (one validator, two callers), writes the `weighings` row from the result, and writes one `capture_draft_changes` row per
changed field — `original_value`, `confirmed_value`, `reason`. A change without a reason refuses `CAPTURE_CHANGE_REASON_REQUIRED|<field>`. Only
`weight_kg` and the subject (ticket and role, Q9) may change; device, gateway, sequence, source and site time range refuse
`CAPTURE_FIELD_FIXED|<field>` (MES-0 Q12). Precedent for "both values + required reason as a CHECK": `fx_rate_history.sql:22-44` [M].

**Rejection:** `reject_capture_draft(id, reason)` — reason required; the draft becomes `rejected` with who / when / why; no weighing; the
inbox row stays `transformed` (frozen by its guard). Final (Q10).

**Links:** `weighings.inbox_id` and `weighings.draft_id` (both unique) and `capture_drafts.weighing_id`; `weighings.device_id` = the inbox row's
device; the inbox row keeps `gateway_id`, `stream`, `seq`, `transmission_id`. So a confirmed weighing reaches its device, gateway call and
raw payload in one hop each.

**Drafts never expire** (MES-0 Q13): reminder arm `capture_draft_pending`, `item_date` = the draft's creation date, so `days_waiting` is its
age; gated `action.confirm_capture` (Q32).

---

## §5 · (c) Manual entry

- **Form:** "Record a weighing" on `/operation/capture` (instrument — optional picker of in-use scales and weighbridges; weight in kg; when
  it was weighed; subject). The ticket page's "Open a ticket" and "Add the second weighing" use the same function.
- **Source marking:** the inbox row has `source='manual'`, `entered_by = auth.uid()`, no gateway, stream or seq — the CHECK MES-1 built
  (`ingest_inbox.sql:51-54`) [M]. The draft and the weighing carry `source='manual'`.
- **Same transformer:** `submit_manual_capture` inserts the inbox row and calls `ingest_transform_row` — the same dispatcher and
  `transform_weighing_v1` a gateway's row goes through — then confirms the draft in the same transaction with `confirmed_by = entered_by`
  and no change rows (MES-0 Q10; MES-1 Q14). Permission: the class's `manual_entry_code` (Q15), which MES-1 built and left NULL
  (`ingest_data_classes.sql:13`) [M].
- **A failed manual transform refuses and stores nothing** (Q13). The person is standing there; the inbox is for what a machine sent while
  nobody was looking.

---

## §6 · (d) Weighbridge tickets

- **Lifecycle (Q16):** opened by its first weighing (inbound: gross, the loaded truck in; outbound: tare, the empty truck in), completed by the
  second; `net_kg` = gross − tare, set at completion, refused if ≤ 0 (`TICKET_NET_NOT_POSITIVE`). Voided only with a reason and only while
  it has no shares. Code `WB-` through `document_types` (MES-0 Q53), gapped like `DEV`.
- **Vehicle:** `vehicle_reg` text, required; no driver name or identity number (Q17).
- **Shares (Q18):** `weighbridge_ticket_shares` rows, each pointing at exactly one receipt or one shipment line with explicit kg; only from a
  complete ticket; direction must match (inbound → receipts, outbound → shipment lines). The ticket page shows Σ shares against net and the
  difference; **nothing forces them equal** (MES-0 Q19). Model: `freight_allocations` (`freight_documents.sql:103-131`) without its forced
  sum (`record_freight_document.sql:141-142`) [M], target XOR from `payment_allocations` [M].
- **Receipt default and override (Q19):** both receipt forms gain "Weighbridge ticket" (complete inbound tickets with net not yet fully
  shared). Choosing one fills the share (default: the unshared remainder) and **prefills the quantity with the share**. If the person types
  a different quantity, a reason is required and stored on the share row (`receipt_quantity_reason`); `inbound_batches.quantity` remains
  what the person entered — "the receipt keeps both" = share kg on the link, quantity on the receipt. The comment "数量始终归过磅的人"
  (`app/inbound/receive/ReceiveForm.tsx:4-6`) stays true. Linking a ticket to an **existing** receipt from the ticket page is allowed; it
  changes nothing on the receipt and shows the difference.
- **Shipments (Q20):** shares to shipment lines are made from the ticket page by `action.ship_goods` holders; `ship_order` unchanged.
- **Photos (Q21):** bucket `capture-photos`, private, `file_size_limit` 10 MB, `allowed_mime_types` jpeg / png / webp; storage SELECT policy
  `bucket_id = 'capture-photos' AND (has_permission('module.inbound.view') OR has_permission('module.logistics.view'))` (MES-0 Q20); INSERT
  `action.confirm_capture`; no UPDATE / DELETE. Upload from the browser, then a server action records the metadata row and re-checks the
  MIME type (the `finance_attachments` pattern, `financeAttachmentActions.ts:29-73`) [M]; reads by 60-second signed URL. A wrong photo is
  withdrawn with a reason; the object and row stay. Proof: `db/scripts/<date>-mes2-capture-photos-policy-proof.sql`, live, rolled back,
  every assertion RAISEs (the UI-1d precedent).
- **Who:** open / complete / void tickets and photos — `action.confirm_capture`; receipt shares — `action.receive_goods` (inside the receipt
  functions); shipment shares — `action.ship_goods`.
- **A soft-deleted receipt** keeps its share row; the ticket page shows it as "receipt deleted" and leaves it out of Σ (the house
  `deleted_at IS NULL` filter; `soft_delete_inbound_batch_internal.sql:68-71`) [M].

---

## §7 · (e) Calibration

**Instruments:** `devices` rows of kind `scale`, `weighbridge`, `meter`, `inline_instrument` (Q23) — `devices.kind` CHECK `devices.sql:28-30` [M].

**Records (Q24):** `instrument_calibrations` (§3.1); each carries its own valid-until, required (MES-0 Q31). Recorded and voided by
`action.manage_devices` (cto, admin). Append-only; a wrong record is voided with a reason, never edited. Shown on the device page and on
`/operation/calibration`.

**Status at a moment (Q25):** the latest non-void record with `calibrated_on ≤ the reading's date`; in calibration iff that record `passed` and
the date ≤ its `valid_until`. No record → `never_calibrated`, treated as out of calibration. Derived on read, so a certificate entered late
counts for the period it covers (the record itself is change-logged with who entered it and when).

**Which paths refuse — today and after (Q27):**

| path | today [M] | after MES-2 |
|---|---|---|
| receipt pricing — `set_inbound_unit_price`, `create_inbound_batch` with a price, `reprice_from_committed_terms`, `apply_assay_result`, `decide_receipt_price_request` (all through `receipt_price_submit_internal` / `receipt_price_post_internal` → **`reprice_inbound_batch`**) | nothing refuses on calibration; no quantity is linked to any instrument (grep `calibrat\|instrument\|scale_id\|device_id` across db/ → only `ingest_*`, `devices` and the unrelated `'calibrated'` work-order basis) | **refuses** `READING_INSTRUMENT_NOT_CALIBRATED\|<device code>\|<date>` when any linked weighing (gross and tare of every share's ticket) was taken by an instrument not in calibration at its capture time; the preview (`preview_reprice_inbound_batch`) shows the same refusal |
| certificate of destruction — `issue_cod` (certifies `inbound_batches.quantity`, `cod_certificate_data.sql:23,80`) | no calibration check | **refuses** the same way, after the licence gate (`issue_cod.sql:41-46`) and before the code is minted (`:48`); **not** in `cod_delivery_completion`, which `refresh_cod_for_batch` shares and which would then void certificates (`refresh_cod_for_batch.sql:31-38`) [M] |
| shipments, sales, settlements, processing, traceability report | no | no — no reading reaches them until MES-4a |
| CoA | does not exist | does not exist (MES-6b) |
| lab assays | out of scope (MES-0 Q30) | out of scope |

**"No instrument recorded" (Q26, Q28):** a linked weighing with `device_id` NULL is flagged "instrument not recorded" on the receipt page,
the pricing panel and the ticket page, and is **not** refused — until the switch. **The switch** is `ingest_settings.require_calibrated_since
date` (NULL = off; set by `action.manage_devices`): for receipts **created on or after** that date, pricing and COD also refuse
`READING_INSTRUMENT_NOT_RECORDED` when a linked weighing has no instrument, and `RECEIPT_READING_NOT_RECORDED` when the receipt has no weighing
link at all. Older receipts are unaffected. Precedent for a setting that turns a warning into a refusal: `certificate_types.disposition`
block / warn (`certificate_types.sql:15`; guard `inbound_batches.sql:197-212`) [M].

**Reminders (Q29):** `instrument_calibration_due` — an in-use instrument (`interface_status` ≠ `reserved`, not retired) not in calibration
today; `instrument_calibration_approaching` — valid-until within the lead days, **only when V8 is set**. 49 → 52 arms with
`capture_draft_pending` (Q32).

---

## §8 · (f) The 500-message timing

**How it will be measured (Q31)** — the first live step, before any DDL:
- a script `db/scripts/<date>-mes2-batch-timing.mjs` built from the MES-1 probe (`db/scripts/2026-10-06-mes1-live-probe.mjs`: throwaway staff
  via `mintThrowaway`, `save_device`, `issue_gateway_key`, anonymous HTTPS calls, retire at the end) [M], plus `performance.now()` around each
  call;
- one probe gateway and one `connection_test` device (no drafts); per call a fresh stream so every message does the full per-message work
  (envelope, device lookup, class check, prior-seq lookup, `ingest_submit.sql:190-249`) [M];
- **three calls of 500 small messages and three of 500 messages near the 256 KB cap**, each preceded by a heartbeat as the round-trip baseline;
  report each call's wall time, the heartbeat baseline, and the difference as the server-side estimate, against anon's 3 s
  (`docs/known-issues.md:10377`, measured as postgres from `pg_roles.rolconfig`) [Q];
- the 3,000 inbox rows, 6 transmission rows and the two devices stay (append-only), retired, one line in
  `docs/known-wrong-until-cutover.md` (the MES-1 Q25 precedent).

**What changes if it is too slow:**
- **≤ 1.5 s** (half the limit, the margin `MES1-ANON-STATEMENT-TIMEOUT-3S` names): nothing; close the known issue with the numbers.
- **> 1.5 s:** make the loop set-based in MES-2's migration — one query to resolve every message's device and class, one for the prior seqs
  of the batch, no per-message subtransaction for the timestamp casts (`:206-211`), no repeated `jsonb ||` (O(n²), `:244-248`) [I]; re-time on
  the new function.
- **still > 1.5 s:** lower `ingest_settings.max_messages` to the largest measured safe batch (runtime config, `set_ingest_settings`) and change
  the vendor document's limit table (`gateway-interface.md:57-63`).
- **Never**, without Tim: a function-level `SET statement_timeout` on `ingest_submit` (it raises the anonymous door's resource ceiling).

---

## §9 · (g) Approvals, change log, trail, masking

- **Approvals: none** (Q32). Weighings, tickets, calibrations are records of events (the house test, `docs/approvals.md:1091-1093`; MES-0 §4.1
  `README.md:519`) [M]. A draft waits for someone, but its "approval" is the operator's confirmation itself (spec §6.3 [S]), surfaced by the
  reminder arm, not by the approval engine. No change to approvals ON / finance / cfo / 1,000.
- **Change log (Q33):** all seven tables logged (two triggers each, `db/views/zzz_change_log_triggers.sql`), none excluded — drafts are one per
  weighing, not per heartbeat. Exclusions stay **7**; fixture 235 O1 unchanged.
- **Trail (Q33):** new subject `weighbridge_ticket` (root `weighbridge_tickets`; members: shares, photos, its weighings and their draft
  changes), view codes inbound OR logistics; `instrument_calibrations` joins the `device` subject; registered by the seven steps
  (`docs/change-log.md:446-471`) [M]; golden arm **⑯** `wording-drift-mes2` in `scripts/check-trail-wording.mjs`.
- **Masking: none.** No price, amount or personal identifier on any new table [I]. Vehicle registration is module-gated and unmasked (the
  `counterparty_contacts` precedent, `counterparty_contacts.sql:46-55,92-95`) [M]; Q17.
- **Open-policy count:** every new table reads through `has_permission(...)`; fixture 249 POL's 44 `USING (true)` stays 44 [M: `:239-251`].

---

## §10 · (h) "Not yet set" values MES-2 adds

| # | value | page showing "Not yet set" | pending-values arm reads | permission | supplied by | when |
|---|---|---|---|---|---|---|
| V8 | Calibration reminder lead days (one value, Q30) — each record's own valid-until is required at entry, so it is never pending | devices page settings panel; `/operation/calibration` | `ingest_settings.calibration_lead_days IS NULL` (one row) | `module.processing.view` | accredited calibration body / instrument vendor (MES-0 §5.1) | instrument installation |
| V33 | Capacity of each in-use measuring instrument (new, Q12) | the device page | instruments with `interface_status` ≠ `reserved`, not retired, `capacity IS NULL` | `module.processing.view` | instrument vendor (spec §8.2 [S]; MES-0 8.2c) | instrument installation |

Both get their arm in `pending_values` and their row in `docs/mes-pending-values.md` **in the same commit** (the Q2 rule,
`docs/mes-pending-values.md:11-12`) [M]. `require_calibrated_since` is **not** a pending value: it is a switch that is off by ruling.

---

## §11 · (i) Migration shape and broken window

**One migration**, `db/migrations/2026-10-0X-mes2-confirmation-weighing-calibration.sql` (date from `date`):
- the 7 tables (RLS, `has_permission` read policies, `REVOKE ALL … FROM anon`, guards, statement-level DELETE refusal), `capture-photos` bucket
  and its two storage policies;
- `action.confirm_capture` + grants (warehouse, cto, admin) with the before / after proof;
- functions §3.2; `ingest_data_classes` `weighing` row: `transform_function`, `manual_entry_code`, drafting flag (Q4);
- **`create_inbound_batch` and `receive_inbound_batch_against_po` change signature** — `preflight_migration.py` refuses a `CREATE OR REPLACE`
  whose signature differs (AGENTS.md OPS-7) [M], so each is `DROP FUNCTION` + `CREATE FUNCTION` with the new parameters **last and
  defaulted**, then `NOTIFY pgrst, 'reload schema'`;
- `document_types` `WB`; `operations_now` 49 → 52 arms; `pending_values` V8, V33; two `ingest_settings` columns; trail registry rows;
  change-log bindings;
- registries that move (no question): `scripts/check-search-registry.mjs:68` 42 → 43; `scripts/check-document-registry.mjs:111-112` tables
  249 → 256, code tables 78 → 79; fixture 100 (anchor, shape, the four `42`s → 43, gapped kinds 10 → 11); fixture 101 45 → 47 (`WB` declares two view codes, inbound and
  logistics, each a (table, code) pair); fixture 111's exact list; fixture 249
  PV (two new arms); `lib/maskedTables.ts` unchanged (no masked table); `lib/modules.ts` four routes; `lib/deepRoutes.generated.ts`;
  `scripts/gen-trail-catalogue.mjs` (table nouns, `devices#data_class` unchanged); `docs/role-matrix.md`; `docs/dashboard-arm-inventory.md`;
  `docs/integration/gateway-interface.md` (the `weighing` payload, Q7); `check_mirrors.py` `SEED_TABLES` (Q5).
- Sequence: timing probe (§8, live, no DDL) → code → layout survey → build → offline gate → backup → dry run → apply → full gate → bucket
  proof → smoke → live probe → push.

**Broken window [I]:** old app + new database. The deployed receipt forms call the two receipt functions without the new parameters — they
are defaulted, so the calls still resolve (after the schema reload). `reprice_inbound_batch` and `issue_cod` behave exactly as before while
no receipt has a weighing link and `require_calibrated_since` is NULL (both true until someone uses the new pages, which are not deployed).
The dispatcher now drafts `weighing` rows — none exist on live [Q: MES-1 §5, the probe sent only `connection_test`]. The three new arms are
invisible to the old reminders page (it draws from `REMINDERS`, MES-1 §5.1). **Expected breakage: none**, beyond the gap between the
`DROP` and the reload, inside one transaction plus seconds.

---

## §12 · Every open question, with a recommended answer and its evidence

Questions in one block are independent unless a question names another. Where a question builds on another's recommendation, it says so; a
different answer to the first reshapes the second.

### A · Scope

❓ **Q1 — Seven tables, not six.** MES-0 counted six; the photos need a metadata table (house pattern) and the ticket → receipt / shipment
link is its own table.
➡️ **Seven:** `capture_drafts`, `capture_draft_changes`, `weighings`, `weighbridge_tickets`, `weighbridge_ticket_shares`,
`weighbridge_ticket_photos`, `instrument_calibrations`. The two settings ride on the existing `ingest_settings` row (Q26, Q30).

❓ **Q2 — The four pages.**
➡️ **`/operation/capture` (queue + manual weighing), `/operation/weighbridge`, `/operation/weighbridge/[id]`, `/operation/calibration`**;
existing pages changed: device page, both receipt forms, receipt page, pricing panel, devices settings panel, pending values (§3.3).

❓ **Q3 — What MES-2 leaves out.**
➡️ **As §3.4:** weighings attached to batches and run legs and every output-side gate → MES-4a; CoA → MES-6b; other classes' transformers →
their cuts; calibration certificate files → later (Q24); no gate on `ship_order` (Q20).

### B · Drafts and confirmation

❓ **Q4 — Who creates the draft.** Transformers are IMMUTABLE and see only the payload (`ingest_transform_row.sql:49`), so they cannot.
➡️ **The dispatcher, in the same subtransaction as `transformed`, for classes whose new registry column `creates_draft` is true
(`weighing`; not `connection_test`).** A registry column rather than a hard-coded class name, so each later class turns it on in its own
migration.

❓ **Q5 — `ingest_data_classes` into `SEED_TABLES`.** Its header says `check_mirrors` compares it row by row (`ingest_data_classes.sql:11`);
`db/check_mirrors.py` `SEED_TABLES` (`:116` on) does not list it.
➡️ **Add it in MES-2**, which changes that seed. It is migration-only data that names functions executed by name; a drift there should be red.

❓ **Q6 — Waiting rows.** `ingest_process_pending` takes only `received` rows (`:23-24`).
➡️ **It also takes `awaiting_transform` rows whose class now has a transformer.** Otherwise each waiting row needs a manual retry by cto or
admin.

❓ **Q7 — The `weighing` payload.**
➡️ **`{"weight_kg": <number > 0>}` and nothing else**; the gateway converts units; role (gross / tare / net) and subject are chosen at
confirmation, not by the scale. The vendor document gains the schema.

❓ **Q8 — Who reads drafts.**
➡️ **`module.processing.view`** (MES-0 §3.10); confirm / reject `action.confirm_capture` (ruled: warehouse, cto, admin; bootstrap: warehouse,
admin).

❓ **Q9 — What may change at confirmation, for a weighing.** (Ruled in principle, MES-0 Q12; the subject list is the question.)
➡️ **`weight_kg`, and the subject: which ticket and which role (gross / tare / net).** No batch or run subject until MES-4a. Every change: a
`capture_draft_changes` row with original, confirmed and reason; the merged payload re-validated by the same transformer.

❓ **Q10 — Rejection.**
➡️ **Final, reason required; the inbox row stays; a wrongly rejected reading is re-entered by hand** (which is itself recorded as manual).

❓ **Q11 — Correction after confirmation.** Spec §4.2 [S]: corrections are new records referencing the original.
➡️ **`correct_weighing`: a new weighing with `corrects_id` and a required reason; a ticket moves to the newest; receipts keep their
quantity (immutable) and show the difference; the gate reads the newest.** In MES-2, not deferred.

❓ **Q12 — Capacity.** `devices.capacity` exists and may be NULL (`devices.sql:35`).
➡️ **A reading above a set capacity refuses at confirmation (`WEIGHING_ABOVE_CAPACITY`); unset capacity → no check, and a new pending value
V33 lists in-use instruments without it.** Capacity is a vendor fact, not an invented threshold.

### C · Manual entry

❓ **Q13 — A manual entry whose transform fails.**
➡️ **Refuse with the code and store nothing.** The inbox's failed rows are for unattended machines; the person entering can fix it at once.
(It also avoids failed manual rows that `capture_inbox_failed` cannot show — that arm joins `devices`, `operations_now.sql:546-559` [I].)

❓ **Q14 — Must a manual weighing name its instrument?**
➡️ **No; optional, flagged "instrument not recorded" when absent.** The switch (Q26) makes the absence refuse **pricing**, not entry.

❓ **Q15 — The weighing class's manual-entry code.**
➡️ **`action.confirm_capture`** (the ruled confirmer is the person who enters by hand).

### D · Weighbridge tickets

❓ **Q16 — Ticket lifecycle.**
➡️ **Open on the first weighing, complete on the second, net = gross − tare (refuse ≤ 0), void with a reason only while unshared; code
`WB-YYYY-NNNN`, gapped.** Inbound opens on gross, outbound on tare.

❓ **Q17 — What is recorded about the vehicle.**
➡️ **Registration only, required, unmasked, module-gated; no driver name or identity number.** Nothing downstream needs a person; a plate is
how a weighbridge clerk matches in and out.

❓ **Q18 — Shares.**
➡️ **One row per receipt or shipment line (XOR), explicit kg, only from a complete ticket, direction must match; Σ shown against net with the
difference, never forced** (MES-0 Q19).

❓ **Q19 — Receipt default and override.** The receipt quantity cannot change after creation (`inbound_batches.sql:163-167`).
➡️ **At receipt creation: pick a complete inbound ticket → share defaults to the unshared remainder → quantity prefilled with the share; a
different quantity needs a reason, stored on the share. From the ticket page an existing receipt may also be linked, changing nothing on it.**

❓ **Q20 — Shipments.**
➡️ **Shares to shipment lines are made from the ticket page by `action.ship_goods`; `ship_order` and the shipping queue are unchanged;
no money moves.** The outbound ticket completes around loading, after the order was invoiced.

❓ **Q21 — The photo bucket.**
➡️ **`capture-photos`, private, 10 MB, jpeg / png / webp; read `module.inbound.view` OR `module.logistics.view` (first permission-gated storage
read in the repo); upload `action.confirm_capture`; no update or delete — withdraw with a reason; proven by a live rolled-back script.**

❓ **Q22 — Who reads tickets and weighings.**
➡️ **Tickets, shares, photos: inbound OR logistics view. Weighings: processing OR inbound OR logistics view** (a weighing is shown on the
ticket page). Today all seven roles hold all three [I: AT-1c reading, `docs/surveys/AUDIT-TRAIL-1c/A-finance-docs.md:21`; warehouse
`role_permissions.sql:172`].

### E · Calibration

❓ **Q23 — Which instruments take calibration.**
➡️ **`scale`, `weighbridge`, `meter`, `inline_instrument`.** Only scales and weighbridges have readings in MES-2; the other two are registered
ahead of their cuts.

❓ **Q24 — The calibration record and who keeps it.**
➡️ **Calibrated on, valid until (required), passed / failed, certificate number, calibrating body, notes; append-only, void with a reason;
`action.manage_devices` (cto, admin); no certificate file in MES-2.**

❓ **Q25 — "Out of calibration at capture time", and "never calibrated".**
➡️ **Derived on read: the latest non-void record on or before the reading's date; in calibration only if it passed and the date ≤ valid-until.
An instrument with no record is out of calibration. A certificate entered late counts for the period it covers.** Spec §8.2 [S]: "All data
produced by an uncalibrated instrument is unreliable."

❓ **Q26 — The switch.** A boolean turned on would refuse pricing for every older receipt that never had a weighing link.
➡️ **`require_calibrated_since` (a date; NULL = off), set by `action.manage_devices`. For receipts created on or after it, pricing and COD also
refuse when a linked weighing has no instrument or the receipt has no weighing at all.**

❓ **Q27 — Where the gate sits.**
➡️ **`reprice_inbound_batch` (every receipt-pricing path), its preview, and `issue_cod` — nothing else in MES-2.** Codes
`READING_INSTRUMENT_NOT_CALIBRATED|device|date`, `READING_INSTRUMENT_NOT_RECORDED`, `RECEIPT_READING_NOT_RECORDED`. A priced
`create_inbound_batch` refused here rolls back the receipt (`create_inbound_batch.sql:73-76`), so the refusal text says "receive without a
price, then price it".

❓ **Q28 — Where "instrument not recorded" shows.**
➡️ **Receipt page, pricing panel, ticket page. Not on the COD certificate.**

❓ **Q29 — Calibration reminders.**
➡️ **`instrument_calibration_due` (in-use, not in calibration today) and `instrument_calibration_approaching` (within V8's lead days; silent
while V8 is not set).** "In use" = `interface_status` ≠ `reserved`, so a placeholder scale does not nag.

❓ **Q30 — V8: one lead-days value or one per instrument.**
➡️ **One value, `ingest_settings.calibration_lead_days`, NULL = "Not yet set".** Each certificate's own valid-until is already per instrument.

### F · Timing

❓ **Q31 — The 500-message timing and its remedy.**
➡️ **First live step, before any DDL: three calls of 500 small and three of 500 near-cap messages on a probe gateway, heartbeat baseline
each. ≤ 1.5 s: close the known issue. > 1.5 s: set-based loop in MES-2's migration, re-time. Still > 1.5 s: lower `max_messages` and the
vendor document. No function-level `statement_timeout` without Tim.** The 3,000 rows stay as test data.

### G · Approvals, log, trail

❓ **Q32 — Approvals and the draft reminder.**
➡️ **No approval chain. Arm `capture_draft_pending`, gated `action.confirm_capture`, dated by draft creation (age in `days_waiting`).**

❓ **Q33 — Change log and trail.**
➡️ **All seven tables logged; no masking; new trail subject `weighbridge_ticket`; calibrations join `device`; golden arm ⑯.**

### H · Records

❓ **Q34 — The false sentence in `docs/known-issues.md:10379`** ("fixture 249 的 SIZE 臂在本地跑过 500 条一批").
➡️ **Correct it in MES-2's commit, in place (struck, with the measurement), when the timing closes or keeps the entry.**

❓ **Q35 — Item e's reading** (§1.5).
➡️ **"The device page" = the Devices page and gateway pages, as built; no change.** If Tim wants it on every device's page, MES-2 moves the
notice out of `gatewayBlocks` (one line).

---

## §13 · (j) Time estimate — floor and work, as two numbers

**Calibration (measured from git reflog, log `stat`s and the session transcripts; pauses = the session idle and waiting on Tim):**

| cut | opening → push | pauses removed | **active** | estimate given | active ÷ estimate |
|---|---|---|---|---|---|
| U1-A | 15:26:55 → 19:06:19 | 17:29:12 → 18:38:50 (1 h 09 m 38 s) | **2 h 29 m 46 s** | 5 h 30 m – 8 h 15 m | 0.45 – 0.30 |
| U1-B | 19:52:35 → 09:54:18 | 21:09:40 → 09:11:08 (12 h 01 m 28 s) | **2 h 00 m 15 s** | 4 h 30 m – 7 h 15 m | 0.45 – 0.28 |
| MES-1 | 10:39:40 → 16:07:50 | 11:51:02 → 14:40:12 (2 h 49 m 10 s) | **2 h 39 m 00 s** | 4 h 20 m – 8 h 35 m | 0.61 – 0.31 |

**MES-1 split** (contiguous segments summing to 159 min): building **47 m 34 s** (7 tables + 18 functions + 5 views ≈ 14 m 49 s; 4 routes ≈
17 m 14 s; fixture 249 + 33 injections 8 m 33 s; orientation 5 m) · static checks 2 m 56 s · **clean process floor 61 m 32 s** (backup
4 m 56 s, apply 63 s, build 54 s, full gate 361 s verdict / 427 s wall, surveys, **smoke 24 m 55 s wall**, probe 47 s) · **incident 49 m 54 s
gross / ≈ 43 m 40 s net** (the 500 the layout survey found: fix, re-survey, i18n rerun, a gate run lost to a dropped pooler, gate run 3
9 m 37 s, smoke run 2 26 m 38 s). Its Step 0 had estimated work 3 h 00 m – 6 h 15 m: **0.26 – 0.13**; the floor held (0.77 – 0.80).

**Process floor (MES-2):** MES-1's measured clean floor 1 h 02 m, plus the timing probe (≈ 5 min of calls) and the bucket proof
(≈ 2 min) → **≈ 1 h 05 m clean; ≈ 1 h 55 m with one incident** (MES-1's incident cost 44–50 min; 12 of 37 database cuts had one [Q]).

**Work:** MES-1's building rate (≈ 2.1 min per table all-in; ≈ 4.3 min per route) applies to the new half; MES-2 also changes existing,
heavily tested paths — the pricing engine and COD (20 fixtures call `create_inbound_batch`, 6 `set_inbound_unit_price`, 6
`apply_assay_result`, 3 `issue_cod` [M]), two receipt forms and a storage policy no bucket has had:

| part | low | high |
|---|---|---|
| orientation | 5 m | 5 m |
| 7 tables, ~15 functions, views, registries | 15 m | 25 m |
| gate in the pricing engine, preview, COD; receipt-function signature change | 15 m | 30 m |
| 4 new routes | 17 m | 36 m |
| changed pages (receipt forms ×2, receipt page, device page, panel) | 10 m | 20 m |
| fixture + fault injections | 10 m | 20 m |
| bucket, its policies, proof script | 10 m | 15 m |
| timing probe; the set-based rewrite only if > 1.5 s | 5 m | 30 m |
| docs (vendor payload, pending values, role matrix, arms) | 5 m | 15 m |
| **total** | **1 h 32 m** | **3 h 16 m** |

**Estimate: floor ≈ 1 h 05 m – 1 h 55 m + work ≈ 1 h 30 m – 3 h 15 m = ≈ 2 h 35 m – 5 h 10 m of active time, plus any pause** —
against MES-0's 7 h 40 m – 13 h 30 m. The work range is about twice MES-1's measured rate per unit, for the regression surface above; the
three calibration cuts all landed at 0.28 – 0.61 of their estimates, so the low end is the likelier.

---

## §14 · Assertions measured and found false or imprecise

1. **`docs/known-issues.md:10379`: "fixture 249 的 SIZE 臂在本地跑过 500 条一批".** False. The arm sends **501** messages
   (`db/fixtures/249-…sql:289` `generate_series(1, 501)`), refused `too_many` at `ingest_submit.sql:126-127` before the per-message loop; no
   other batch in the fixture. **No accepted 500-message call has ever been timed, locally or live.** (Q34.)
2. **`db/tables/ingest_data_classes.sql:11`: "check_mirrors 逐行比对(SEED_TABLES)".** False: `db/check_mirrors.py` `SEED_TABLES` (`:116` on)
   does not list it (grep → no hit). (Q5.)
3. **MES-0 §8.2 "6 / 4".** Seven tables (Q1).
4. **MES-0 §8.2 "receipt and shipment forms pick a ticket".** Receipt forms yes; shipments cannot meaningfully (§2.5, Q20).
5. **MES-0 §8.2 "calibration gate regression in 3–4 existing functions".** Two gated functions plus one preview, with one helper (§2.6).
6. **A sub-agent: "No bucket today gates SELECT with `has_permission`"** — I re-checked it because the grep for `has_permission` in
   bucket migrations hits `pur1:79` and `cn1:246-250`; those are **table** policies (`po_issues`, `credit_notes`), not storage policies. The
   claim **holds**; recorded because the first reading of the grep says otherwise.
7. **`processing_settings` and `ingest_settings` are in neither `RUNTIME_CONFIG_TABLES` nor `SEED_TABLES`** (`db/check_mirrors.py`: only a
   comment at `:253` mentions `processing_settings`) — not false, but the tables' own comments call them runtime config. Their bootstraps are
   replayed, not row-compared, which is what runtime config gets anyway; no question, noted.
8. **Stale text, no question:** `docs/surveys/MES-1/STEP0-HANDBACK.md:284` cites the seven trail steps at `docs/change-log.md:437-461` (now
   `:446-471`); `scripts/check-trail-wording.mjs:25` "表数(238)"; `docs/handbacks/U1-B.md:19` pause "~21:05" (measured 21:09:40).
9. **The brief's "6 tables, 4 pages"** — the MES-0 figure, item 3.

Matched on re-measurement (repo, not live): the three SHAs; MES-1's window start; `WB` free in `document_types` (42 rows, last `DEV`); 74
permission codes; 49 `operations_now` arms; highest fixture 249; `action.receive_goods` and `action.ship_goods` held by warehouse and admin
(`docs/role-matrix.md:203,211`); shipments read by `module.sales.view` OR `action.ship_goods` (`shipments.sql:64-66`).

## §15 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q35.
