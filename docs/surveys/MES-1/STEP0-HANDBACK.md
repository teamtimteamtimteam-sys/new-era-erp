# MES-1 Step 0 — hand-back (2026-10-06)

**Contents:** Step 1 (U1-B close-out) results §1 · what grilling changed §2 · MES-1 contents and design (a)–(i) §3–§11 · every open
question §12 · time estimate (j) §13 · assertions found false §14 · stop §15.

**STOP GATE.** No code, no migration, no live write. The only writes are docs: `docs/forward-queue.md` (close-out, commit `fa1317ef`;
the Q16 timing line, this commit) and this file. Waiting on Tim's answers to Q1–Q30 (§12).

**Opening check.** This session's first command printed **2026-10-06 09:59:51 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` =
`git ls-remote origin main` = **`57893aa766d318e63dfdfbd4f5d5f65466a6e43b`** (U1-B, `v1.4.36`). Files staged by explicit path only.

**Live state — NOT re-measured this session.** A read-only `psql` session (`BEGIN READ ONLY … ROLLBACK`, `default_transaction_read_only=on`)
was refused by this machine's permission classifier ("Production Reads"). I did not retry it or route around it. Every live figure below is
therefore **quoted from an earlier measurement, with its source**, or derived from the mirrors and marked so. Nothing was written to live.
The brief's live state (approvals ON finance / cfo / 1,000; 7 accounts enabled) is the last measured state (U1-B §5, 2026-10-06 09:49:08 CST);
this block changes neither.

**How the facts were gathered.** Four read-only sub-agents (anonymous surface and the COD precedent; permissions, navigation and registries;
change log, trails and fixtures; cut-duration calibration). I re-read every claim this hand-back rests on at its cited line; the
calibration agent also parsed the session transcripts under `~/.claude/projects/-Users-timchen/` (read-only) to find pauses. Tags:
**[M]** measured (file:line, grep, `stat`, reflog) · **[I]** inferred from code reading · **[Q]** quoted from an earlier hand-back's
measurement · **[S]** the specification PDF.

---

## §0 · A ruling that existed only in the brief, now written down

**Q16 timing (Tim, this block's brief):** the paid Supabase plan waits until **real business data or the first real gateway**; it is **not** a
prerequisite for building or proving MES-1 with **test gateways** on the current project. The repo said "before MES-1's gateway path is used
on live" (`docs/forward-queue.md` MES block; `docs/handbacks/U1-B.md:28-29`; MES-0 §12), which read literally would forbid MES-1's own live
probe. Written into `docs/forward-queue.md` beside the old line (this commit), per AGENTS.md "一条只活在聊天里的裁定…就是还没答".

---

## §1 · Step 1 — U1-B close-out, item by item

### 1.1 Broken window closed ✅ (written, `fa1317ef`)

`docs/forward-queue.md` item 35, in U1-A's format:
- start **2026-10-05 20:46:41 CST** [M] — `db/migration-windows.tsv`: `2026-10-05T20:46:41+0800	2026-10-05-u1b-workflow-fixes.sql	4995f49b`;
- end, lower bound **2026-10-06 09:54:18 CST** [M] — `git reflog show --date=iso refs/remotes/origin/main`:
  `57893aa7 refs/remotes/origin/main@{2026-10-06 09:54:18 +0800}: update by push`;
- end, upper bound **2026-10-06 09:59:51 CST** — this session's first command; it rests on Tim's "deployed", not on a Vercel reading.
- **Window: at least 13 h 07 min 37 s, at most 13 h 13 min 10 s.** It ran overnight (the session paused after the migration).
  Broken in it (derived, not measured on live): **the old `/finance/journal` errored for every reader on `journal_requests.amount_base`
  (revoked from `authenticated`) for the whole window, overnight**; the old deep-discharge control still could not save; old close / reopen
  wrote the reason to the new columns, which the old page does not show.

### 1.2 Privacy-pass item ✅ (written, `fa1317ef`)

`docs/forward-queue.md`, after the MES block: «⬜ 下一次隐私整理(Tim 排期)» — one item carrying both U1-B registrations:
`U1B-LEAVE-DECISION-NOTE-HEALTH-TEXT` (sick-leave decision notes) and `U1B-EXPENSE-CLAIM-DESCRIPTION-IN-EXPENSE-NOTES` (an ordinary claim's
description copied into its expense's notes).

### 1.3 Read-only verification of what the U1-B report did not mention

| | item | verdict | evidence [M] |
|---|---|---|---|
| a | Q14 add lines to a shipped order, entry on the order page | ✅ | `app/sales/orders/[id]/page.tsx:116` `amendable = !deleted && ['draft','confirmed','partially_shipped','shipped'].includes(o.status)`; `:119` `o.status === 'shipped' ? t('sales.amend.addLinesAction')`; `:181-189` the `<Link href=…/amend>` with its hint; `messages/en.ts:4010-4011` "Add lines" / "This order is fully shipped. You can only add new lines…"; `amend/AmendOrderForm.tsx:84` `addOnly = status === 'shipped'`; `db/functions/amend_sales_order.sql:35,40` |
| b | Q15 downtime correct + void; no hard delete; both in the trail | ✅ | `db/functions/void_equipment_downtime.sql`; `db/functions/guard_downtime_write.sql:23-24` `IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'DOWNTIME_NEVER_DELETED'`; `db/tables/equipment_downtime.sql:128-131` `BEFORE DELETE … FOR EACH STATEMENT`; `:55-56` void CHECK; trail `lib/trail/text.ts:252-253` `'eq.downCorrected': 'Downtime corrected'`, `'eq.downVoided': 'Downtime voided'`; goldens `scripts/check-trail-wording.mjs:4283-4293`; panel `app/finance/assets/[id]/DowntimePanel.tsx:142-161` (Voided badge + reason). Fixture 248 DT1–DT4 |
| c | Q16 forwarder rates on the shared DataTable, Remove always visible | ✅ | `app/logistics/forwarders/[id]/ForwarderPanels.tsx:8` imports `DataTable`; `:111` `key: 'actions', … priority: true`; `:117-126` `ConfirmButton` "Remove"; `:225-229` `<DataTable … phone={{ mode: 'columns' }}>`; `actions.ts:71-75` `.select('id')` then `refuseNothingChanged` on zero rows. ⚠ see 1.5 (a dated note elsewhere still calls it open) |
| c′ | Q17 KPI "Show targets" | ✅ | `app/hr/kpi/score/ScoreEditor.tsx:115-116` `<details …><summary …>{t('kpi.showTargets')}</summary>`; title, weight and the provisional tag stay outside (`:101-109`); `messages/en.ts:2362` |
| d | Q18 `docs/operations/admin-break-glass.md`, impersonal, declarative | ✅ | exists (4,050 bytes); `grep -cE "\b(I|we|you|my|our)\b"` → **0**; headings "When this procedure applies / What is needed / Procedure" |
| e | Q19 withdrawal closed as not a defect; Q22 reconcile moved out of 甲 | ✅ | `docs/known-issues.md:9817` "✅ 已关闭(U1-B…)· AT0-WITHDRAW-PAYMENT-REQUEST-NO-REQUESTER-CHECK", in-place correction `:9819-9824`. `docs/forward-queue.md` 甲 row struck "【U1-B 挪到丙(Tim 的 Q22)】" (甲 section `:4426-4446`, row `:4438`), 丙 row added (`:4476`), body note `:2390` |
| f | Q20 deep-discharge judgement saves (purchasing edit, non-cancelled PO) | ✅ | `db/functions/set_po_line_deep_discharge.sql:20` `SECURITY DEFINER`, `:26` `require_permission('module.purchasing.edit')`, `:36-37` `PO_CANCELLED`, `:39-40` never back to empty; `app/purchasing/orders/[id]/actions.ts:129` `.rpc('set_po_line_deep_discharge'…)`; control gated `DeepDischargeJudgementControl.tsx:62` `<PermissionGate code="module.purchasing.edit" …>`; fixture 248 DD1 (`:281-286`) "a purchasing editor could not record the judgement" arm; live proof ③ (U1-B §5) |
| g | Q21 optional machine picker | ✅ | `app/operation/processing/new/page.tsx:125-131` reads `equipment_usage` `.neq('equipment_status','disposed')`; `NewProcessingForm.tsx:349` `<option value="">{t('processing.form.machineNone')}</option>`; `actions.ts:69` `p_equipment_id: payload.equipment_id || null`; live proof ④ PROC-2026-0711 |
| h | Q23 GHOST-GRANTS finished (scripts); Q24 three actions deleted | ✅ | `scripts/ephemeral.mjs:277` `export async function mintThrowaway`, `:214` `THROWAWAY_REFUSES_SYSTEM_ROLE`; `package.json:7` build runs `check-throwaway-grants.mjs`; `grep -rln "code=eq.admin" scripts` → only `ephemeral.mjs` and the checker; `render-pdf-samples.mjs:37,41` takes the live-lock; `docs/known-issues.md:5153` "✅ 已关闭(U1-B…)· GHOST-GRANTS". Q24: `grep -rnw "deleteEmployee\|updateQuoteHeader\|softDeleteCommissionAgreement" app lib scripts` → **0**; the `rollback_processing_run` stub kept (`app/operation/processing/[id]/DeleteButton.tsx:9`). ⚠ see 1.5 |
| i | Q25 PO close / reopen reasons in their own columns, not Notes | ✅ | `db/tables/purchase_orders.sql:88-92` five columns; `db/functions/close_purchase_order.sql:66-78` sets `close_reason`, history row `'closed'`, notes untouched; `reopen_purchase_order.sql:44-56`; `purchase_orders_masked.sql:82,85`; page `:731-747` shows them |
| j | Other U1-B hand-back items | ✅ built or closed with reason | `PERIOD_LOCKED` / `YEAR_CLOSED` shared mapping `lib/machine-text.ts:125` `SHARED_DATE_CODE_RE`, `:137`; claim other-decider `submit_expense_claim.sql:54-56` `assert_other_decider_for_subject(…'EXPENSE_CLAIM_NO_OTHER_DECIDER|'…)`, `assert_other_decider.sql:30` delegates; month-end `close_period.sql:35-38` and `app/finance/month-end/page.tsx:84,121,179` both read `processing_runs_blocking_close`; `app/operation/errorCodes.ts:87-91` allocation + equipment codes. Closed in known-issues: `ROLE1B3A-…` `:210` · `AT0-DEEP-DISCHARGE-…` `:9805` · `AT0-RUN-EQUIPMENT-…` `:9836` · `AT0-ACTIONS-WITHOUT-CALLER` `:9846` · `AT0-PO-CLOSE-REASON-…` `:9856` · `SO-1b` `:3597` · downtime `:4701` · `U1A-PAYROLL-REVERSAL-…` `:10294` · `U1A-MEDICAL-EXPENSE-…` `:10308` · `U1A-SELF-GATE-NULL-TRAP` `:10326`; `PERIOD-LOCK-RAW-CODE` struck in the queue `:4329`, `:4444`. Left open **with reason**: `AT1C3-LIVE-MONTH-CLOSE-…` `:10052` (Tim's own data entry, Q26 — the code half shipped, written in the entry); registered: `U1B-ALLOCATION-PRICE-INDEX-LEGS` `:10364` |
| k | Payroll reversal amounts Restricted without `data.view_pay` — screen, API, trail | ✅ | API: `db/tables/journal_requests.sql:128-131` `REVOKE SELECT … FROM authenticated` + column grant without `amount_base`; view `db/views/journal_requests_masked.sql:19-21` `WHEN journal_request_amount_visible(id) THEN amount_base`; trail `db/functions/change_log_mask_rules.sql:59` `('journal_requests','amount_base','jr_amount')`, `change_log_rule_visible.sql:37-38`; screen `app/finance/journal/JournalRequestsPanel.tsx:84-85` `<Refusal …>{t('common.restricted')}</Refusal>`; reads `journal_requests_masked` (`[id]/page.tsx:98-100`). Role table U1-B §1 (cto, gm → Restricted) [Q]; fixture 248 JR1–JR5 |
| l | Nine leave functions refuse an account with no employee record | ✅ | all nine carry `COALESCE(p_employee_id = current_user_employee(), false)` (grep: `accrued_annual_leave_detail` · `accrued_annual_leave` · `annual_leave_rate_per_year` · `annual_leave_available_from` · `available_annual_accrual` · `compute_leave_encashment` · `consumed_from_accrual` · `leave_balance` · `leave_balance_internal`; plus U1-A's `medical_claim_balance`). The four other self-gated functions were checked: three already `COALESCE` (EMP-SELF-1), `attendance_unpaid_days` is `CASE WHEN … THEN` (NULL falls to no branch → NULL, closed). Fixture 248 LV `:330-343` loops the nine expecting `PERMISSION_DENIED|module.hr.view` |
| m | Shared throwaway helper; smoke and probes use it | ✅ | `scripts/ephemeral.mjs:277`; `grep -rln mintThrowaway scripts | wc -l` → **42**; per script: smoke-routes 5 · survey-phone 3 · probe-avatar 4 · probe-u1a 2 · probe-role-crash 4 · probe-brand-sampler 3 · probe-search-shell 3 · probe-search-results 3 · probe-nav-geometry 3. Their remaining `/rest/v1/user_roles` references are reads and cleanup deletes only |
| n | MES-0 README carries Tim's answers; queue has the 15 MES cuts in order with estimates, scheduling out of scope, Q16 as Tim's prerequisite | ✅ | `docs/surveys/MES-0/README.md:1139-1145` §12; `docs/forward-queue.md` MES block — 15-row table MES-1 … MES-9 with estimates, total ≈ 97 h 40 m – 174 h 45 m; "排程…不在范围内(Q2)"; "★★ 硬前提(Q16,Tim 自己的动作)". ⚠ the recorded Q16 wording was stricter than Tim's timing in this brief — written down beside it (§0) |
| o | Role table from U1-B's live verification in `docs/handbacks/U1-B.md` | ✅ | `docs/handbacks/U1-B.md:32-63` §1 — 7 accounts × 9 columns, method `db/scripts/2026-10-05-u1b-live-role-table.sql`, `ROLETABLE_OWN_EXIT=0`, 2026-10-06 09:47:47 CST |

### 1.4 U1-B's self-taken decisions (`docs/handbacks/U1-B.md` §6, titles)

1. The claim-decider check uses a new function, `assert_other_decider_for_subject`. 2. A claim whose base amount cannot be computed is not
refused at submit. 3. Tim's R2 self-exception counts. 4. Downtime correction stays a direct UPDATE under the existing policy. 5. Every
downtime DELETE is refused by name, as a statement-level trigger. 6. A voided period freezes. 7. Correct cannot close an open period or reopen
a closed one. 8. PO close / reopen columns describe the latest close and reopen. 9. The deep-discharge judgement can never go back to empty.
10. The machine picker leaves disposed assets out entirely. 11. The medical-claim expense rule was applied where the health text actually
travels. 12. The self-approval report asks the same two judgements. 13. A masked reason in the trail reads "Restricted". 14. A derived status
flip ranks below an amendment in the same operation. 15. The KPI provisional note also folds. 16. `PERIOD_LOCKED` / `YEAR_CLOSED` mapped once,
in the shared fallback. 17. The month-end lock step is also blocked by unallocated runs. 18. Smoke `--reach` and role-loop probes clone each
real role into a throwaway role. 19. `sweep-ghost-grants` deletes only accounts and `probe-` roles older than 2 h. 20. The throwaway checker
uses the shared `selfproof` assertions. 21. Fixture 233's setup reads as its HR user. 22. The role table reads the 7 real accounts by JWT inside
a rolled-back transaction. 23. Leave decision notes are registered, not masked.

### 1.5 Judgement on the stop rule, and what I found that is not a missing item

**Every item a–o is built or closed with its reason. Step 2 therefore ran.** Three **dated notes in other entries** still describe two of
these items as open — the repo's «文档活得比它的对象久» shape, in prose that predates U1-B, not in the items' own entries (which are closed):
- `docs/forward-queue.md:3437-3438` (a LEAK-1 note): "**`GHOST-GRANTS`**(66 → 21 → 8,第三次清扫),**仍然开着**";
- `docs/known-issues.md:8760` (the PROBE-KILL-LEAK header note): "幽灵授权本身是另一条(`GHOST-GRANTS`,仍然开着)";
- `docs/known-issues.md:8437-8439` (a DRAFT-6 note): "`ForwarderPanels:167`:删除钮只露一半 … ⚠ 这一笔【原样还在】".

I judged these not to make h or c "missing or partly done" — the work and its home entries are complete — and **did not fix them**
(the brief's step-1 writes are items 1–2 only). If Tim reads them as "partly done", this hand-back's §2 onward should be set aside until the
three notes are struck. Recommended: strike them in MES-1's first commit with a pointer to U1-B (Q30).

---

## §2 · What grilling changed in MES-1's scope

1. **The anonymous call writes, and only appends.** The heartbeat and "last seen / last sequence" state moves **off `devices`** (which is
   change-logged) into the excluded logs, so `ingest_submit` writes **only** to `ingest_transmissions`, `ingest_inbox` and `gateway_outages`,
   **INSERT only** (plus one counter upsert on heartbeat bucket rows, Q8). Without this every heartbeat would write a change-log row
   (`change_log_capture` logs every UPDATE that changes a column, `db/functions/change_log_capture.sql:48-56`) — ≈ 525,600 rows per gateway per
   year at one per minute (MES-0 Q6's own figure) — the volume Q14 exists to avoid. **Q7.**
2. **Transformation leaves the anonymous call** (recommended): `ingest_submit` stores; validation and conversion run under a staff session.
   The anonymous path then executes no transform code with definer rights, and "it reads nothing" becomes provable. **Q11.**
3. **The gate list in MES-0 §3.3 item 5 was incomplete.** Five more places must learn about `ingest_submit` / the new tables, or the gate goes
   red: fixture 196 B2 (anon may execute **exactly** `cod_verification(text)`, `db/fixtures/196-…:495-502`); B2's
   `DEFINER_UNCHECKED_EXEC_ALLOWED` (`db/verify_rebuild.py:378`); check_mirrors' `DEFINER_NO_CHECK_ALLOWED` (`db/check_mirrors.py:319`);
   fixture 235 O1 (exactly **4** exclusions, `db/fixtures/235-…:134`); and `ANON_EXECUTE_ALLOWED` lives in `db/verify_rebuild.py:346`, not
   `db/check_grants.py` as MES-0 says. Plus stale text: `db/tables/change_log.sql` comment ("四张"), `docs/change-log.md:14` (238 / 242) and
   `:197-198` ("A screen-state table … is the only accepted kind so far").
4. **No gate watches `authenticated` on an anon-allowed function.** B2 would, but `ingest_submit` must sit in B2's allowlist, which blinds it;
   `check_grants.py` and fixture 196 watch only `anon` / `PUBLIC`. MES-1's fixture must assert `ingest_submit` is **not** executable by
   `authenticated` (and `service_role`, Q4) — the per-function precedent is fixtures 231:264-266 and 246:396-398.
5. **Hashing without pgcrypto.** pgcrypto is installed on live in `extensions` but **not** in the rebuild prelude (`db/platform-prelude.sql:144-152`
   installs only `pg_trgm`); no function in the repo hashes in SQL today. Recommended: PostgreSQL's built-in `sha256(bytea)` (core since 11) and
   `gen_random_uuid()` (core since 13) — no extension, no search-path change. The live server version is **not measured** this session (§0
   preamble); the cut measures it first. **Q5.**
6. **The rate limit needs a global ceiling.** A per-presented-code budget lets anyone rotate invented codes and write unbounded log rows.
   **Q9.**
7. **A data class to prove the framework:** none of the eight MES-0 classes has a target before MES-2; recommended a `connection_test` class
   (vendor commissioning) plus the eight registered as awaiting. **Q12.**
8. **Sequence reuse after a gateway reset** would be silently acknowledged as "duplicate" — data loss. A stream (boot) identifier joins the key.
   **Q13.**
9. **Outages cannot appear in the audit trail** through the existing mechanism (excluded tables contribute nothing after the change log began,
   `db/functions/record_trail.sql:233`); the device page lists them directly. **Q21.**
10. **The key hash needs a "nobody" mask form** — none exists; `change_log_mask_gaps()` reports a rule without a `<table>_masked` column as
    `stale_rule` (`db/functions/change_log_mask_gaps.sql:39-40`). **Q20.**
11. **`DEV-` through `document_types`** (Q53, ruled) moves pinned counts in five places (§9). Listed so the cut does not discover them at gate
    time; no question.
12. **"3 pages" is 4 routes:** `/operation/devices`, `/operation/devices/[id]`, `/operation/capture/inbox` (MES-0 §8.2's three) **and**
    `/settings/pending-values` (in MES-0's MES-1 row and the queue). **Q1.**
13. **CFO cannot hold `action.manage_devices`** under the written rule ("只读;不带任何写码或决定码", `docs/role-matrix.md:158`); MES-0 already
    proposed admin + cto only. No question; recorded.
14. **Interface document** for vendors does not exist and is part of MES-1 (§10). **Q24.**
15. **Live HTTPS probe leaves permanent rows** (the logs are append-only). **Q25.**
16. **Estimate:** MES-0's 7 h 15 m – 13 h 45 m counted pauses as work; recalibrated to **≈ 1 h 20 m – 2 h 20 m floor + 3 h 00 m – 6 h 15 m work**
    (§13).

---

## §3 · (a) Exactly what MES-1 contains

### 3.1 Tables (7) — MES-0 §3.2, adjusted by §2

| table | purpose | change log | anon | notes |
|---|---|---|---|---|
| `devices` | every physical source incl. gateways (`kind`), `code` `DEV-YYYY-NNNN`, `gateway_id` (which gateway carries it), `equipment_id → fixed_assets` (nullable), `station`, `data_class`, `capacity` / `resolution` / `unit`, `interface_status` (`reserved` · `manual_only` · `connected`), the six §8.1 contract terms as columns (NULL = "Not yet confirmed"), `heartbeat_interval_s` (gateways; NULL = "Not yet set", V5), `is_active`, `retired_at/by/reason` | **logged** | REVOKE ALL | no `last_*` columns (§2.1) |
| `gateway_keys` | `gateway_id`, `key_prefix` (8 chars, displayable), `key_hash bytea` (SHA-256 of the secret), `issued_at/by`, `revoked_at/by/reason` | **logged**, `key_hash` masked "never" (Q20) | REVOKE ALL | column grant without `key_hash`; `gateway_keys_masked`; ≤ 2 active per gateway (guard) |
| `ingest_settings` | one row (`id boolean … CHECK (id)`, the house pattern, e.g. `processing_settings.sql:13`): failure budget per code (30 / 10 min), global rejected budget (Q9), payload cap (256 KB), messages per call (500) | **logged** (history = change log, Q22) | REVOKE ALL | RUNTIME CONFIG |
| `ingest_data_classes` | dictionary: `code`, `transform_function` (NULL = awaiting), `target` (text, for display), `manual_entry_code` (NULL until MES-2), `is_active` | **logged** | REVOKE ALL | INSTALL SEED (migration-only, Q12) |
| `ingest_inbox` | one row per accepted message: `id` identity (orderable), `gateway_id` (NULL for manual), `stream`, `seq`, `source` (`device` · `manual`), `entered_by`, `device_id`, `data_class`, `payload jsonb`, `payload_bytes`, `payload_sha256`, `site_from`, `site_to`, `site_dataset_ref`, `received_at`, `status` (`received` · `transformed` · `failed` · `awaiting_transform` · `discarded`), `transform_version`, `error_code`, `attempts`, `last_attempt_at/by`, `discarded_at/by/reason`; unique `(gateway_id, stream, seq)` | **excluded** (Q14, ruled) | REVOKE ALL | guard: insert-only except the status columns; statement-level DELETE refusal (U1-B lesson) |
| `ingest_transmissions` | one row per **data** call and per rejected call, plus heartbeat hour buckets (Q8): `kind` (`data` · `heartbeat_hour` · `rejected_overflow`), presented code (truncated), `gateway_id`, presented key prefix, `received_at`, `bytes`, `message_count`, first / last seq, `result`, `client_address` (Q18-measured, else "not available"), bucket `count` / `first_at` / `last_at` | **excluded** | REVOKE ALL | guard: insert-only; bucket counters may only grow, only through the function |
| `gateway_outages` | `gateway_id`, `silent_from`, `silent_to`, `recorded_at`, `interval_s_at_the_time` | **excluded** | REVOKE ALL | written on reconnect; insert-only |

### 3.2 Functions

| function | caller | what |
|---|---|---|
| `ingest_submit(p_gateway text, p_key text, p_body jsonb) → jsonb` | **anon only** (EXECUTE revoked from `authenticated`, and `service_role` per Q4) | the only gateway entry (§4, §10) |
| `issue_gateway_key(p_gateway_id) → jsonb` | `action.manage_devices` | returns the secret once; stores prefix + hash |
| `revoke_gateway_key(p_key_id, p_reason)` | `action.manage_devices` | effective at the next call |
| `save_device(…)`, `retire_device(…)` | `action.manage_devices` | registry writes (direct writes refused by RLS) |
| `set_ingest_settings(…)` | `action.manage_devices` | the one settings row |
| `ingest_process_pending(p_limit int)` | holders of `module.processing.view`? → **Q11** | runs the class transform on `received` rows |
| `retry_inbox_row(p_id)`, `discard_inbox_row(p_id, p_reason)` | `action.manage_devices` | never delete |
| `transform_connection_test_v1(payload jsonb) → jsonb` | internal (REVOKE from authenticated) | the proving class (Q12) |
| views `gateway_health`, `ingest_sequence_gaps`, `ingest_transmission_anomalies` | `module.processing.view` | status on read; gaps; anomalies (Q19) |
| `operations_now` arms `gateway_silent`, `capture_inbox_failed` | reminder page | Q23 |
| `pending_values` view | per-arm permission | `/settings/pending-values` (Q2) |

### 3.3 Pages (4 routes, Q1)

`/operation/devices` (register + status list) · `/operation/devices/[id]` (device, keys, transmissions, gaps, outages, contract-term checklist,
the free-plan risk line until Q16's trigger, trail) · `/operation/capture/inbox` (rows by status, payload, retry / discard) ·
`/settings/pending-values` (read-only register). Docs: `docs/mes-pending-values.md`, the interface document (§10).

### 3.4 Deliberately left out

- **MES-2:** `capture_drafts`, `capture_draft_changes`, `confirm_capture_draft` / `reject_capture_draft`, **`submit_manual_capture`** (MES-0 §8.2 puts
  "manual-capture path" in MES-2 — Q14), the weighing class's transform and target, weighbridge tickets, calibration, `action.confirm_capture`.
- **Later cuts:** every other class's transform and target (discharge MES-5a, controller / workstation MES-4a, meter MES-5a, scan MES-3b,
  inline quality MES-6a, safety alarm MES-7b); the 44 open read policies and the default `EXECUTE` grant (MES-9).
- **Never in this group:** any reverse channel (spec §7 [S]).

---

## §4 · (b) The security proof

What the build must demonstrate, and how. **One fixture (249) on the rebuild, every arm fault-injected; one live HTTPS probe as a throwaway
gateway; the gate's verdict 6 fault-injected the COD-2 way.**

| claim | proof |
|---|---|
| **The anonymous function only appends to the inbox and the transmission log** (and to `gateway_outages` on reconnect — Q9 of MES-0 makes that a third table; said, not hidden) | Fixture arm APPEND: as `anon` (`SET LOCAL ROLE anon` + empty claims — fixture 196's form, `:232-235`), make data, heartbeat, duplicate, rejected and reconnect calls, then read **`pg_stat_xact_user_tables`** for the current transaction: every public table other than the three must show `n_tup_ins = n_tup_upd = n_tup_del = 0`, and the three must show `n_tup_upd = 0` except the heartbeat-bucket counter (Q8) and `n_tup_del = 0`. [I: per-transaction counters exist in PostgreSQL; the cut proves the arm can go red by injecting an `UPDATE devices` into the function] |
| **It reads nothing** (returns nothing of any table) | Arm RESP: the response's key set ⊆ `{ok, accepted, duplicates, rejected, code, retry_after_seconds}`, and every value is the caller's own seq or a fixed code — injection: add a `devices` column to the response → red. The function's own internal reads (key hash lookup, budget count, settings) are named in its header, not hidden |
| **A wrong, revoked or unknown key is refused; identically** | Arm AUTH: unknown gateway · wrong key · revoked key · retired gateway · inactive device → each a `ingest_transmissions` row with its exact reason, and the **same** answer to the caller (Q10). Injection: accept a revoked key → red |
| **Revoking one gateway never stops another** | Arm ISO: two gateways; revoke A; B's next call accepted |
| **Rotation without a stop** | Arm ROT: second key works beside the first; a third active key refused; revoke the first, the second keeps working |
| **Rate and size limits hold** | Arm LIM: 31st failure in 10 min for one code → `throttled`, not logged individually; global ceiling (Q9) with rotated codes; 256 KB + 1 byte → `too_large`; 501 messages → `too_many`; a valid key is **not** throttled by someone else's failures (Q9) |
| **No other new function or table is callable or readable without login** | ① `db/anon-grants-baseline.tsv` gains exactly one line, `function\tingest_submit(text,text,jsonb)`; gate verdict 6 fault-injected (remove the line → exit 6, as COD-2, `AGENTS.md:1166-1170`). ② fixture 196 B2 widened to **exactly** `{cod_verification(text), ingest_submit(text,text,jsonb)}` (still an exact set, not a superset). ③ every new table's mirror carries `REVOKE ALL … FROM anon` (`scripts/check-anon-grant-decision.mjs`, build); new views likewise. ④ fixture 196 arm B already counts zero anon-readable rows over **every** public relation, so new ones are covered automatically. ⑤ arm GRANT: `NOT has_function_privilege('authenticated', 'ingest_submit(text,text,jsonb)', 'EXECUTE')` (and `service_role`, Q4) — the gap §2.4 names; injection: re-grant → red. ⑥ every helper (`transform_*`, `ingest_process_pending` internals) not anon-executable (zzz line 28 revokes all from anon; asserted) |
| **The 44 open read policies are untouched** | Mirror count before and after (`CREATE POLICY … USING (true)` on SELECT/ALL for `authenticated` in `db/tables` + `db/views`: **44** today, agent grep, = MES-0's live figure [Q]); arm POL asserts the rebuild's count is 44 and **none is on a MES-1 table**; live count read before and after the migration in the live readings. No gate counts them today, so the fixture is the only mechanism — Q27 asks whether to make it a permanent gate line |
| **HTTPS and certificate** | The live probe uses Node's `fetch` with default certificate verification against `https://wvywpohbwkiinmipmuku.supabase.co`; a deliberately wrong host name must fail TLS. Pinning is not used (Q17, ruled) |
| **POST only** | [I] PostgREST serves `GET /rpc/…` only for STABLE / IMMUTABLE functions; `ingest_submit` is VOLATILE, so the key never travels in a query string. The probe asserts a GET is refused |

**The live HTTPS probe** (`scripts/probe-mes1-gateway.mjs`, `mintThrowaway` for the staff side, live-lock held): registers a throwaway gateway
`ZZ-PROBE-GW-<stamp>`, issues a key through the staff function, then over real HTTPS as `anon`: data call · duplicate · gap · back-fill ·
heartbeat · revoked key · unknown gateway · too large · a read attempt (`GET /rest/v1/ingest_inbox` and `/devices` → no rows / 401) · GET on the
RPC. Its rows stay (Q25). It also measures **Q18** (what `current_setting('request.headers', true)` carries) and the `anon` statement timeout.

---

## §5 · (c) The transformation-layer framework

- **Registration:** a class is a row in `ingest_data_classes` (install seed, migration-only — the registry names functions that are executed by
  name, so it is not runtime-editable, Q12). `transform_function` names a function `transform_<class>_v<n>(payload jsonb) RETURNS jsonb` that
  validates and normalises **only its argument**; a format change is a new `_v<n+1>` plus a registry update in a migration; business tables do
  not change (spec §6.4 [S]).
- **Dispatch:** `ingest_process_pending` takes `received` rows in `id` order, looks up the class, and calls the function by its registered
  `regprocedure` (cast, so a name that is not a function fails the cast). NULL function → `awaiting_transform`. Each row in its own exception
  block: a coded error → `failed` + `error_code`; any other error → `failed` + `TRANSFORM_UNEXPECTED|<sqlstate>`. `attempts` and
  `last_attempt_at/by` on the row.
- **Failures stay visible:** status on the row; `/operation/capture/inbox` lists failed rows with payload and code; reminder arm
  `capture_inbox_failed` (Q23); `retry_inbox_row` after a transform fix; `discard_inbox_row` with a reason; **never delete** (statement-level
  DELETE guard).
- **Manual entry enters the same path:** the inbox carries `source`, `entered_by`, `gateway_id` NULL with a CHECK
  (`source='manual'` ⇔ `gateway_id IS NULL AND entered_by IS NOT NULL`); `submit_manual_capture` itself lands in MES-2 with the targets (Q14).
- **Proving class:** `connection_test` (Q12) — `{ "text": <≤ 200 chars> }` → transformed, no target; a payload without `text` → `failed` with
  `CONNECTION_TEST_TEXT_REQUIRED`. The eight MES-0 classes are registered with `transform_function` NULL → their rows wait as
  `awaiting_transform`.

---

## §6 · (d) Gateway administration

| who | what | code | where it sits |
|---|---|---|---|
| admin, cto | register / edit / retire devices and gateways; issue and revoke keys; retry and discard inbox rows; edit ingest settings | **`action.manage_devices`** (new; MES-0 Q90 ruled holders admin, cto; admin by the standing rule `docs/role-matrix.md:156`) | `docs/role-matrix.md`: a new row at the end of "已经生效的码 · Codes in force" (after `data.view_change_log`, `:215`), and a row in §9 Processing (`:118-124`): "登记设备、发 / 撤钥匙 · register devices, issue / revoke keys — cto, admin — 不需审批 · none (MES-0 §4.1)" |
| every holder of `module.processing.view` (incl. cfo by "CFO reads everything", `:158`) | read devices, status, keys (prefix only), inbox, transmissions, gaps, outages | none new (MES-0 §3.10, ruled) | §13 Visibility row: "设备与采集层 · devices and ingestion — `module.processing.view`; key hashes never shown" |
| cfo | **no** management | — | `:158` "只读;不带任何写码或决定码" — giving it to cfo would need a ruling; not recommended |

`action.manage_devices` is a migration-level code (`db/tables/permissions.sql:4-8`): mirror row in `permissions.sql` (action band, after
`overtime_approve … 1210`), grants to admin and cto in the migration with a before / after grant proof (OVERTIME-1 precedent,
`2026-09-28-overtime1-…sql:93-101, 1926-1936`). The mirror bootstrap has no `cto` role (`ROLE1-BOOTSTRAP-MISSING-ROLES`,
`docs/known-issues.md:279`), so on a rebuild only admin holds it — same as every other cto grant.

**Status page:** `/operation/devices` for every `module.processing.view` holder; controls visible-but-disabled with their reason for
non-holders (`PermissionGate`, DBLOCK-1).

---

## §7 · (e) Heartbeats and outages

- A heartbeat is a body with no messages (`{"heartbeat": true, "stream": …, "last_seq": n}`) — Q8. It upserts the gateway's current
  **hour bucket** row in `ingest_transmissions` (`count + 1`, `last_at = clock_timestamp()`; `first_at` on insert) and writes nothing else.
- **Status on read** (`gateway_health`, owner view, `module.processing.view`): `last_heard = greatest(last data call, last bucket last_at)`;
  `heartbeat_interval_s` NULL → **"Not yet set — silence cannot be judged"**; else `silent = now() − last_heard > interval`. Never heard →
  "Not yet heard from". No scheduler is involved (none installed, MES-0 §0 6 [Q]).
- **Outage on reconnect:** inside `ingest_submit`, before writing this call, if the gateway's previous `last_heard` is older than its interval,
  insert `gateway_outages(silent_from = previous last_heard, silent_to = now)`. With the interval not set, no outage is recorded and the device
  page says why. A failed gateway and an idle one stay distinguishable: idle still heartbeats.
- **Seen from outside:** the `gateway_silent` arm in `operations_now` (Q23).

---

## §8 · (h) Change log, trails, masking (Q14 ruled)

- **Logged:** `devices`, `gateway_keys`, `ingest_settings`, `ingest_data_classes` — two triggers each (shape `gen_change_log_bindings.py:71-76`;
  generated after the tables exist, or copied), mirrored in `db/views/zzz_change_log_triggers.sql`.
- **Excluded:** `ingest_inbox`, `ingest_transmissions`, `gateway_outages`, each with the reason MES-0 §4.2 wrote ("an append-only log itself;
  logging it again doubles the volume the specification warns about and adds no fact; its status changes are recorded on the row") —
  `change_log_exclusions()` 4 → 7; fixture 235 O1 4 → 7; `docs/change-log.md` §2 and §7 reworded to accept a second kind (ingestion logs).
- **Masking:** `gateway_keys.key_hash` → a new explicit `never` rule form (Q20) + `gateway_keys_masked` (`CASE WHEN false THEN key_hash END AS
  key_hash`) + column grant without it, in one migration (AGENTS.md three-changes rule); trail `HIDE` so no "Key hash: Restricted" line.
- **Trail subjects:** `device` (root `devices`, `module.processing.view`, rule `table`; member `gateway_keys` down by `gateway_id`) and
  `ingest_settings` (single-row root, the `processing_settings` precedent `trail_subjects.sql:126-130`), registered by the seven steps
  (`docs/change-log.md:437-461`): `labels.csv` rows for every column, `render.ts` family + case, `text.ts` titles ("Device registered",
  "Gateway key issued", "Gateway key revoked", "Device retired", "Ingestion limits changed"), catalogue regenerated, a golden arm ⑮ with
  `TRAIL_WORDING_FAULT=wording-drift-mes1`. Retry / discard of inbox rows are on the row (excluded table). Outages: Q21.

---

## §9 · Registries and checks the cut must move (no question — listed so they are not discovered at gate time)

| place | change |
|---|---|
| `db/anon-grants-baseline.tsv` | + `function\tingest_submit(text,text,jsonb)` |
| `db/verify_rebuild.py:346` `ANON_EXECUTE_ALLOWED`, `:378` `DEFINER_UNCHECKED_EXEC_ALLOWED` | + `ingest_submit` with reason |
| `db/check_mirrors.py:319` `DEFINER_NO_CHECK_ALLOWED` | + `ingest_submit` |
| `db/views/zzz_function_grants.sql` | `GRANT … ingest_submit … TO anon`; `REVOKE … FROM authenticated` (+ `service_role`, Q4); REVOKE helpers from authenticated |
| fixture 196 B2 | exact set of two |
| fixture 235 O1 | 4 → 7 exclusions |
| `document_types` `DEV` (Q53 ruled) | `check-search-registry.mjs:67` 41 → 42 · `check-document-registry.mjs:108-109` 242 → 249 tables, 76 → 77 code tables (and a reasoned exception for `ingest_data_classes.code`) · fixture 100 (anchors, `SHAPE`, arm 5 count if `MAX(split_part)` shape, arm 6 literal ban, arm 8 grants) · fixture 101 `v_n <> 44` → 45 · fixture 199 F · `search.docType.device` i18n · route resolves in `lib/modules.ts` |
| `operations_now` | arms 47 → 49 (Q23) · fixture 111's exact arm list · `lib/reminders.ts` · `docs/dashboard-arm-inventory.md` · `dashboard.item.*` keys · `arm_permission_widen` if widened |
| `lib/modules.ts` `FUNCTIONS` | three static routes each need their own entry (`scripts/check-nav-routes.mjs:237-299`); `/operation/capture/inbox` is a deep route → `lib/deepRoutes.generated.ts` regenerated |
| `permissions` mirror + `docs/role-matrix.md` | `action.manage_devices` |
| `lib/maskedTables.ts` | regenerated (`gateway_keys`) |
| text | `db/tables/change_log.sql` comment, `docs/change-log.md:14`, `:197-198`; `db/apply_migration.sh:18` "1 GRANT + 9 REVOKE" (now 2 / 133) |

---

## §10 · (f) How a real gateway calls the function — and where the document lives

Recommended location: **`docs/integration/gateway-interface.md`**, English, written for a device vendor or integrator, versioned with the
interface (Q24). Outline (the cut writes it; every field below is the recommended design, settled by Q8–Q13, Q18):

1. **Endpoint:** `POST https://wvywpohbwkiinmipmuku.supabase.co/rest/v1/rpc/ingest_submit`, headers `apikey: <project public key>` and
   `Content-Type: application/json` (whether `Authorization: Bearer <same key>` is also required depends on the key format, not determined from
   the repo — `NEXT_PUBLIC_SUPABASE_ANON_KEY` is the variable, `lib/supabase/server.ts:36-37`; measured by the probe). The public key is
   configuration, **not** a secret. TLS 1.2+, standard CA verification, no pinning (Q17).
2. **Body:** `{"p_gateway": "<DEV code>", "p_key": "<secret>", "p_body": {...}}`. The secret travels only in the POST body; never in a URL.
3. **`p_body` for data:** `{"stream": "<id the gateway generates at each start-up>", "messages": [ { "seq": <int ≥ 1, strictly increasing per
   stream>, "device": "<DEV code of the scale/controller>", "class": "<data class>", "site_from": "<ISO 8601 with offset>", "site_to": "…",
   "dataset_ref": "<gateway's own pointer to raw data>", "payload": { … per class … } } … ] }` — at most 500 messages and 256 KB per call.
4. **Heartbeat:** `{"heartbeat": true, "stream": "…", "last_seq": <n>}` every `heartbeat_interval_s` (set per gateway at commissioning, V5).
5. **Responses** (always HTTP 200 from the RPC; the body decides): `{"ok": true, "accepted": [seq…], "duplicates": [seq…], "rejected":
   [{"seq": n, "code": "UNKNOWN_DEVICE|DEVICE_NOT_ON_THIS_GATEWAY|CLASS_UNKNOWN|ENVELOPE_INVALID|SEQ_REUSED"}]}` · `{"ok": false, "code":
   "refused"}` (any authentication failure, one answer, Q10) · `{"ok": false, "code": "throttled", "retry_after_seconds": n}` ·
   `{"ok": false, "code": "too_large" | "too_many"}`.
6. **Buffering and back-fill:** keep every message until it is in `accepted` or `duplicates`; send oldest first; resend on any network error or
   non-`ok`; a resend is safe (duplicates are acknowledged); never renumber a sent message; after a restart start a **new stream** at seq 1.
7. **Rotation:** an operator issues a second key, the gateway is reconfigured, the first is revoked — no stop.
8. **Clock:** NTP-synchronised; `site_to` more than 5 minutes after the server's receive time is flagged (Q13).
9. **Classes:** `connection_test` defined; the rest listed "reserved — payload schema published with its cut".
10. **No commands flow back.** The response carries acknowledgements only.

---

## §11 · (i) Migration shape and broken-window assessment

- **One migration** (`db/migrations/2026-10-0X-mes1-entry-point.sql`, filename from `date`): 7 tables (RLS, policies, grants, guards), the
  masked view, the functions, `action.manage_devices` + grants, `document_types` `DEV`, the `operations_now` arms (`CREATE OR REPLACE VIEW`, same
  seven columns — `db/views/operations_now.sql:151-160`), the pending-values view, trail registry rows, change-log bindings and exclusions,
  settings and class seeds; `zzz_function_grants.sql` replayed inside it by `apply_migration.sh` (`:67-74`). Dry run first (COMMIT → ROLLBACK
  on live, the house rule). Code first, migrate last.
- **Broken window [I]:** everything is new; no deployed code reads a new object. `operations_now` keeps its seven columns, and the old
  `/tools/reminders` builds its tiles from `REMINDERS` (`app/tools/reminders/page.tsx:180,188-189`), so the two unknown arms are skipped, not
  printed as keys. `trail_subjects` / `change_log_exclusions` are replaced in place with the same signatures. **The anonymous function is live
  from COMMIT, but no gateway can authenticate until an admin issues a key through a page that is not deployed yet.** Expected breakage in the
  window: none; the cut measures the old reminder page during the window to confirm.

---

## §12 · Every open question, with a recommended answer and its evidence

Questions in one block are independent unless a question names another.

### A · Scope

❓ **Q1 — Four routes or three.** MES-0 §8.2 says "7 / 3" and lists `/operation/devices`, `/operation/devices/[id]`, `/operation/capture/inbox`;
the same row and the queue add `/settings/pending-values`.
➡️ **Four routes, all in MES-1.** The pending-values page is where every later cut's "Not yet set" lands; setting its pattern once now costs one
page.

❓ **Q2 — What `/settings/pending-values` lists in MES-1.** Only V5 (heartbeat interval per gateway) and V6 (working hours for anomaly listing,
which reads `shifts.starts_at/ends_at`, NULL by design) exist after MES-1.
➡️ **A `pending_values` view with one arm per value (like `operations_now`), each arm carrying its own permission; MES-1 seeds V5 and V6;
each later cut adds its arms and its `docs/mes-pending-values.md` rows in the same commit.** Gate: `module.processing.view` OR any arm's code.

❓ **Q3 — The data classes registered in MES-1.**
➡️ **The eight of MES-0 §3.2 plus `connection_test`; the eight with `transform_function` NULL.** A device can then be registered against its
real class today; its rows wait visibly.

### B · Grants and hashing

❓ **Q4 — Revoke `ingest_submit` from `service_role` too?** MES-0 §3.3 says yes; no function in the repo has ever revoked from `service_role`
(`zzz_function_grants.sql:31` grants it everything). The app's service-role client is limited to `auth.admin` (`lib/supabase/admin.ts`).
➡️ **Yes, and assert it in the fixture.** No legitimate server path calls it; a revoke costs one line and removes a second door.

❓ **Q5 — How to hash and generate keys.** pgcrypto is on live in `extensions` but not in the rebuild prelude (`platform-prelude.sql:144-152`).
(a) core `sha256(bytea)` + `gen_random_uuid()`; (b) add pgcrypto to the prelude and call `extensions.digest` / `gen_random_bytes`.
➡️ **(a).** Secret = `ngk_` + two `gen_random_uuid()` without hyphens (244 random bits); stored: first 8 characters as prefix and
`sha256(convert_to(secret,'UTF8'))`. No extension, no search-path change. The cut first reads the live server version; if it is below 13 the
answer becomes (b).

### C · The anonymous call

❓ **Q6 — Message envelope and ownership.** May a gateway submit for a device that is not registered as carried by it?
➡️ **No.** Every message names its device; the device must be active and `gateway_id` = the caller's gateway, else that message is rejected
`DEVICE_NOT_ON_THIS_GATEWAY` (the call goes on). A compromised gateway cannot write as another gateway's scale.

❓ **Q7 — Where per-call state lives.** MES-0 put `last_seen_at`, `last_heartbeat_at`, `last_seq` on `devices`, which is change-logged.
➡️ **Nowhere mutable: derive them on read** from `ingest_transmissions` (last call, last bucket) and `ingest_inbox` (max seq per stream). The
anonymous path then INSERTs only (bucket counters aside, Q8), and the change log takes no row per heartbeat.

❓ **Q8 — Heartbeat logging shape** (Q6 of MES-0 ruled "hourly bucket rows").
➡️ **Bucket rows in `ingest_transmissions` (`kind = 'heartbeat_hour'`), upserted by `(gateway, hour)`: count, bytes, first_at, last_at. The guard
lets only those four columns grow, only through the function.** Keeps seven tables; one row per gateway per hour.

❓ **Q9 — Rate limit shape.** Ruled: 30 failed calls / 10 min per presented gateway code. Two gaps: (i) invented codes rotate past a per-code
budget and write unbounded rows; (ii) a stranger presenting a real gateway's code with bad keys would throttle the real gateway.
➡️ **(i) A global ceiling on rejected calls — 300 per 10 minutes, editable in `ingest_settings` — above which rejected calls are counted in one
`rejected_overflow` bucket row per 10 minutes instead of a row each. (ii) A call with a valid active key is never throttled** (keys are 244-bit
random; the budget protects the log, not the key — the same reasoning as `cod_verification` never throttling a valid token,
`db/functions/cod_verification.sql:20-22`). Presented codes truncated to 64 characters.

❓ **Q10 — What a refused caller is told.**
➡️ **One answer, `{"ok": false, "code": "refused"}`, for unknown gateway, wrong key, revoked key and retired gateway; the exact reason only in
the log and on the device page.** Telling them apart lets anyone enumerate gateway codes (COD returns identical answers for every failure,
fixture 196 arm E). The integrator reads the reason from the admin.

❓ **Q11 — Where transformation runs.** (a) inside `ingest_submit`, per row in an exception block (MES-0 §3.3 (iv)); (b) deferred: the
anonymous call stores `received`; `ingest_process_pending` runs under a staff session — a "Process received" button on the inbox page in MES-1,
and MES-2's confirmation queue calls it on load.
➡️ **(b).** The anonymous path then runs no transform code with definer rights, so "it reads nothing and writes only these rows" is a property of
one short function, provable by the APPEND arm; a buggy transform cannot be reached by an outsider; the specification puts conversion on the
ERP side anyway (§6.4 [S]). Cost: a row waits as `received` until someone processes it — visible, and MES-2 removes the wait. Caller: holders
of `module.processing.view` (processing is idempotent and changes only status).

❓ **Q12 — The proving class and the registry's nature.**
➡️ **`connection_test` (`{text}` → transformed, no target; missing text → failed) proves dispatch, success, failure, retry and discard, and
gives vendors an end-to-end check before any business class exists. `ingest_data_classes` is an INSTALL SEED (migration-only):** it names
functions executed by name.

❓ **Q13 — Sequence identity and reuse.** With `(gateway, seq)` unique, a gateway that resets its counter after a reinstall would have new
messages silently acknowledged as duplicates.
➡️ **Key `(gateway, stream, seq)`; the gateway generates a new stream id at each start; within a stream a re-sent seq with the same payload hash
is a duplicate and with a different hash is rejected `SEQ_REUSED` (logged, shown on the device page). Gaps are listed per stream. A message
whose `site_to` is more than 5 minutes ahead of the server's receive time is flagged "clock ahead".** Gaps never block (Q8 ruled).

❓ **Q14 — Manual entry in MES-1 or MES-2.** MES-0 §3.5 describes it with the transformation layer; §8.2 puts the manual-capture path in MES-2.
➡️ **MES-2.** MES-1 builds the columns and the CHECK (`source='manual'` ⇔ no gateway, an enterer); manual entry needs a target to confirm into,
and no class has one before MES-2.

❓ **Q15 — Envelope errors vs payload errors.**
➡️ **An envelope error (no seq, unknown class, unknown device, wrong gateway) rejects that message, listed in the response and counted on the
transmission row; it is not stored. A payload error is stored and fails at transformation, visibly.** The gateway's job is the envelope; the
ERP's is the content.

### D · Status and anomalies

❓ **Q16 — "Never heard from".** A registered gateway that has never called.
➡️ **Status "Not yet heard from", no reminder** — a reserved device is the normal state before commissioning.

❓ **Q17 — A silent gateway with no interval set.**
➡️ **"Not yet set — silence cannot be judged"; no outage rows, no reminder.** No number is assumed (V5 is the integrator's).

❓ **Q18 — Recording the caller's address** (ruled: record it if available, else "not available"). `request.headers` is read nowhere in the repo
today; `X-Forwarded-For` can be set by the caller.
➡️ **The probe measures what `current_setting('request.headers', true)` carries; the column stores the raw forwarded chain as reported, labelled
"reported address (not verified)", else "not available".**

❓ **Q19 — What counts as an anomaly** (spec §7 "Logged" [S]).
➡️ **The anomaly view lists: calls from unknown codes; wrong / revoked keys; throttled and overflow buckets; size refusals; `SEQ_REUSED`; clock-
ahead flags; data calls outside working hours only once V6 is set (until then that column reads "Not yet set").** No byte threshold is invented.

### E · Change log, trail, settings

❓ **Q20 — A mask that nobody passes.** No rule form means "nobody" (`change_log_rule_visible.sql:53` returns false for an unknown rule —
closed by accident, not by statement).
➡️ **Add an explicit `never` branch, plus `gateway_keys_masked` and a column grant without `key_hash`, in the one migration.** A rule that works
only because it is unrecognised is the comment-borne contract AGENTS.md warns about.

❓ **Q21 — Outages in the trail.** `gateway_outages` is excluded (ruled), and excluded tables contribute nothing to `record_trail` after the log
began (`record_trail.sql:233`). MES-0 §4.3 listed `outage_recorded` as a trail event.
➡️ **List outages in their own section on the device page (from the table), not in the trail; amend MES-0 §4.3's event list.** A second trail
mechanism for one event is not worth it.

❓ **Q22 — History of the settings row.** Q93 ruled "a history table (`finance_settings_history` precedent)"; that precedent predates the change
log (HISTORY-1), which now records every edit and renders it in the trail.
➡️ **Change log + trail subject `ingest_settings` as the history; no history table.** Same fact, one mechanism, seven tables.

❓ **Q23 — Reminder arms.**
➡️ **Two: `gateway_silent` (interval set and exceeded) and `capture_inbox_failed` (failed rows), both `module.processing.view`.** Not
`awaiting_transform` — that is the normal state of every class whose cut has not shipped.

### F · Documents, probe, process

❓ **Q24 — Interface document.**
➡️ **`docs/integration/gateway-interface.md`, English, vendor-facing, with a version line; MES-1 writes the transport, envelope, heartbeat,
responses, back-fill, rotation and `connection_test`; each class's payload schema is added by its cut.**

❓ **Q25 — The live probe's rows.** The ingestion logs are insert-only, so the throwaway gateway's inbox, transmission and outage rows cannot be
reaped.
➡️ **They stay, as test data (Tim's ruling that every live row is test data); the throwaway gateway is retired at the end and named
`ZZ-PROBE-GW-…`; one line in `docs/known-wrong-until-cutover.md`.** Adding a delete path for "probe" rows would weaken the guard the proof is
about.

❓ **Q26 — The free plan on the device page.** Q16 now says the paid plan waits for real data or the first real gateway.
➡️ **The device page shows one line while the plan is free: "Database on the free plan (pauses when idle, no point-in-time recovery). Move to a
paid plan before a real device connects." — removed by Tim's word.** The page cannot read the plan; it is a dated statement.

❓ **Q27 — A permanent gate line for the 44 open policies.** Today no gate counts them.
➡️ **Not in MES-1.** MES-1's fixture asserts 44 and "none on a MES-1 table" for this cut; a permanent count belongs to MES-9, which changes it.

❓ **Q28 — Where device codes come from.** Q53 ruled `DEV-` through `document_types` (five pinned counts move, §9).
➡️ **`DEV-YYYY-NNNN`, gapped, generated on `save_device`; the device's own human label (e.g. "Line 1 bench scale A") is a separate `name`.**

❓ **Q29 — Equipment link for processing readers.** `fixed_assets` is finance-only (`db/tables/fixed_assets.sql:109-111`).
➡️ **Resolve the linked machine's label through `equipment_usage` (finance OR processing, `db/views/equipment_usage.sql:45`), as
`/operation/processing/new` does.** A processing-only reader otherwise sees a bare uuid.

❓ **Q30 — The three stale notes from §1.5.**
➡️ **Strike them in MES-1's first commit with a pointer to U1-B**, old text kept struck through (the house rule).

---

## §13 · (j) Time estimate — floor and work, as two numbers

**Calibration (measured by the calibration agent from reflog, log `stat`s and session transcripts; re-checked at the cited lines):**

| cut | opening → push | pauses removed | **active** | estimate given | active ÷ estimate |
|---|---|---|---|---|---|
| U1-A | 15:26:55 → 19:06:19 = 3 h 39 m | Tim's pause 17:29 → 18:38:50 (1 h 10 m) | **2 h 30 m** | 5 h 30 m – 8 h 15 m (`STEP0-HANDBACK.md` UNBLOCK-1 §8) | 0.30 – 0.45 |
| U1-B | 19:54:21 → 09:54:18 = 13 h 59 m 57 s | overnight 21:09 → 09:11 (12 h 01 m) | **2 h 00 m** | 4 h 30 m – 7 h 15 m | 0.28 – 0.44 |
| COD-2 (the anonymous-surface analogue) | 00:19 → 01:33 | ≈ 5 m | **1 h 09 m** | — | — |
| October DB cuts AT-1c-1 … AT-1d-3 | 2 h 28 m – 9 h 50 m raw | pauses 0 – 6 h 35 m | **2 h 23 m – 3 h 16 m** (median ≈ 2 h 42 m) | — | — |

MES-0's `cut-durations.md` spans include Tim's pauses (and its U1-A §2.7 reads a pause as 75 minutes of work) — that is why MES-0's
per-table (45–60 m) and per-page (25–45 m) rates run 2–4× high.

**Process floor (machine + hand-back):** backup median ≈ 15.5 min (October dumps) · offline gate 66–75 s · apply incl. dry run 4–5 min ·
builds ≈ 5–7 min · full gate 419 s median (wall +27–36 %) · survey 5–8 min · smoke 15–18 min wall · probes / readings ≈ 5 min · hand-back
≈ 20–30 min → **≈ 1 h 20 m clean; ≈ 2 h 20 m with one incident** (12 of 37 database cuts had one).

**Work:** base ≈ 50 min (median pre-backup work of the October cuts) + 11 units (7 tables + 4 pages) × 10–20 min (the September rate when a
Step 0 had pinned the design; no measured cut has more than 2 new tables, so the top of the range is widened) + security fixture and fault
injections 30–60 min (COD-2's whole anonymous proof sat inside 1 h 09 m) + live HTTPS probe 20–40 min + interface document 15–30 min + the §9
registry moves 15–30 min → **≈ 3 h 00 m – 6 h 15 m.**

**Total ≈ 4 h 20 m – 8 h 35 m of active time, plus any pause** — against MES-0's 7 h 15 m – 13 h 45 m. Applying the U1-A / U1-B ratio
(0.28–0.45) to MES-0's figure gives 2 h 00 m – 6 h 10 m; MES-1 is the first new subsystem since the calibration cuts, so the range above sits
higher than that.

---

## §14 · Assertions measured and found false or imprecise

1. **MES-0 §1.0 / §3.3: "`ANON_EXECUTE_ALLOWED` in `db/check_grants.py`".** It is in `db/verify_rebuild.py:346`.
2. **MES-0 §3.3 item 5's gate list is incomplete** — fixture 196 B2, `DEFINER_UNCHECKED_EXEC_ALLOWED`, `DEFINER_NO_CHECK_ALLOWED`, fixture 235 O1 (§2.3).
3. **MES-0 §3.2: "SHA-256 via `pgcrypto.digest`", `SET search_path = public`.** No schema `pgcrypto`; on live it is `extensions`; the rebuild has
   no pgcrypto at all (`platform-prelude.sql:151-152`); house functions use `search_path 'public','pg_temp'`.
4. **MES-0 §0 item 1: "`operations_now`, 46 arms".** 47 today (`grep -c "AS item_type"`).
5. **MES-0 `cut-durations.md`: spans are working time; §2.7 "17:28→18:43 … 75 min work".** The spans include pauses; 17:29 → 18:38 was Tim's
   pause (transcript).
6. **The brief: "7 tables, 3 pages".** Four routes (Q1).
7. **The brief, (b): "only append to the inbox and the transmission log".** With MES-0 Q9 ruled, `gateway_outages` is a third append target
   (§4 says so rather than hiding it).
8. **U1-B §5.1: pause "~21:05 → 09:11".** Measured: `pause` queued 21:08:29, acknowledged 21:09:26; `continue U1-B` 09:11:08 (transcript).
   Immaterial to the window.
9. **The repo's Q16 wording** ("before MES-1's gateway path is used on live") was stricter than Tim's timing (§0).
10. **`db/apply_migration.sh:18`: "1 GRANT + 9 REVOKE".** The file now has 2 GRANTs and 133 REVOKEs.
11. **Three dated notes call GHOST-GRANTS and the ForwarderPanels button open** (§1.5).

Matched on re-measurement (repo and mirrors, not live): the three SHAs; U1-B's window start; the 44 open read policies (mirror count = MES-0's live figure); 73 permission
codes (30 / 11 / 32); 41 document types; 242 tables in the registry check; highest fixture 248.

## §15 · Stop

No code edits and no migrations. Waiting on Tim's answers to Q1–Q30.
