# AT-1c survey E: event wordings, field labels, timing calibration (2026-10-03, read-only)

Repo `new-era-erp` @ `e0a7b20e`. No edits, no DB access. Scripts: `(Step 0 scratchpad, not kept) fields.mjs` (label stats), `tl.py` (transcript timeline), `ov.cjs` (overrides per cut). Raw label output: `fields.out`.

---

## 1. Event wordings

### 1.1 Rows in the catalogue (`docs/surveys/AUDIT-TRAIL-0/events.md` §5). All Measured by grepping the source column.

| Block | Rows | EXISTS | STATE | NEW | Status |
|---|--:|--:|--:|--:|---|
| F01–F72 (payments, transfers, WHT, bank, expenses, freight, journals, close, settings, GST, FX, assets, forecasts, packs) | 72 | 6 | 29 | 37 | AT-1c |
| F83–F86 (contracts) | 4 | 0 | 3 | 1 | AT-1c |
| D21–D29 (invoice, credit note, invoice request) | 9 | 3 | 4 | 2 | AT-1c. D21/D23/D24 already have **sales-order-side** keys (`so.invoiced`, `so.invoiceVoided`, `so.creditNoted`), but the invoice subject needs its own keys |
| **AT-1c core** | **85** | **9** | **36** | **40** | |
| G12–G15 expense claims, G23–G31 payroll | 13 | | | | Belongs to AT-1c only if payroll and claims count as finance. The forward queue puts HR in AT-1d |
| F73–F82 pricing formula and terms requests | 10 | | | | Done in 1b-3 (`pf.*`, `tr.*`). The "Contract activation" kind of a terms request (F78/F80) still needs contract-side wording |
| F87–F91 receipt price, F92–F96 warehouse requests | 10 | | | | Done in 1b-1 (`batch.price*`, `wr.*`) |
| F97 master import, F98 metal prices | 2 | | | | F98 done in 1b-3 (`mp.*`). F97 is not done (it is settings/AT-1d) |
| D30–D31 sales record and attribution | 2 | | | | Done in 1b-1 (`batch.sold`, `batch.saleAttributed`) |

**Scope conflict (Measured, `docs/forward-queue.md:6571-6573`):** the queue puts the settings panels in **AT-1d**: the approvals policy, the GST settings, the period lock, and month-end close/reopen ("锁期那一块再加上月结 / 反结", per Q25). If the brief keeps "period-end/settings" in AT-1c, then F34–F48 (15 rows) move from AT-1d to AT-1c. Without them, the AT-1c core is 70 rows.

**Gap in the catalogue (Measured):** `reverse_wht_remittance_internal` exists, and so does `payment_requests.kind = wht_remittance_reversal`, but §5 has **no "WHT remittance reversed" row**. The function changes nothing on `wht_remittances`. Its only effect is a reversal JE (`reverse_journal_entry_internal`), so the event is visible only through `journal_entries.reversed_by` and the request.

### 1.2 `lib/trail/text.ts` keys added per cut. Measured with `git show <c> -- lib/trail/text.ts | grep -E "^\+ *'[^']*':"`.

| Commit | Cut | Keys + / − |
|---|---|---|
| 77776f76 | AT-1a | +117 / 0 (about 45 of them layout, generic, account and summary keys) |
| e0e1a789 | AT-1b-1 | +123 / 0 |
| f8530f1d | AT-1b-2 | +114 / −1 (net 113) |
| 24b913fd | AT-1b-3 | +54 / 0 |
| (close-outs 039ff877, ac03576f, e0a7b20e; HISTORY-1 d93c083b) | — | 0 |
| **File total** | | **407** (matches `grep -c` at HEAD) |

The file already has these finance-flavoured keys: `journal.posted / reversal / reversedBy / laterReversed / edited`, `approval.submitted / approved / approvedLevel / rejected / auto / other` (generic `{Thing}` approval sentences, reusable for every *_request), `batch.prepayment / freight / payment / invoiced`, `so.invoiced / invoiceVoided / creditNoted`, `cus.limitChanged / holdOn / holdOff`, `banner.reversed*`, `tr.*`, `eq.cardCreated / cardEdited`. There are **no** keys for payment, payment request, bank, expense, GST, FX, period/year close, settings, forecast, pack, contract or invoice subjects.

### 1.3 Estimate of new keys for AT-1c (Inferred)

- Keys per subject: 1b-1 17.6, 1b-2 10.3, 1b-3 6.8.
- Keys per catalogue row: roughly 1.2–1.5. Each subject also has created/edited/deleted/changed fallbacks, kind nouns and detail labels.
- Likely subjects: about 20–24. Journal entry, journal request, invoice, credit note, invoice request, payment, payment request, bank transfer, WHT remittance, expense, freight document, fixed asset (finance view), asset disposal request, bank statement (+ reconciliation), GST period/filing, FX rate, management pack, cash forecast, contract (+7 term tables), period close, year close, finance settings panel(s), plus payroll period and expense claim if they are in scope.
- **Estimate: 130–170 new keys** (85 rows × ~1.2 plus ~22 subjects × ~2–3 fallbacks). Payroll and claims add about 15–20. The `{Thing}` approval keys save about 5 per request type.

### 1.4 Ambiguous wordings: one change, several events (Measured from function source unless marked)

| # | Field change / write | Possible meanings | How to tell them apart |
|--:|---|---|---|
| 1 | `*_requests` INSERT with status `approved` (payment F02, journal F25, GST F54, disposal F65, invoice D26) | auto-approved because approvals are off, **not** a human approval | `approval_log.decision = auto_approved` in the same txid (§6.1 #12). The existing key `approval.auto` fits |
| 2 | `payment_requests.status` →approved / →paid | approved and waiting to be paid (F03) / paid (F06: `pay_payment_request` UPDATEs the request and inserts the payment + JE) | value, writer. There are 6 kinds (payment_out, payment_reversal, bank_transfer, bank_transfer_reversal, wht_remittance, wht_remittance_reversal), so "approved" of a *reversal* kind must read "Payment reversal approved", not "Payment approved" |
| 3 | `payments` reversal | the original flips posted→reversed **and** `reverse_payment_internal` INSERTs a **new opposite payments row** (`reversed_by_payment`) | render once, on the original: "Payment reversed". The new row must not read as "Payment received/made" |
| 4 | `expenses` reversal | `reverse_expense` INSERTs a **new expense row**, UPDATEs the original to reversed and UPDATEs `fixed_assets` (capitalised) | same txid. Suppress the new row's "Expense recorded" (F20/F21) |
| 5 | `freight_documents` / `bank_transfers` reversal | UPDATE only, plus a reversal JE | simple, but the JE INSERT in the same txid must fold into the detail line (F33) |
| 6 | `journal_entries` INSERT | fresh posting (F29/F31/F32) / reversal of an earlier entry (F30). `reverse_journal_entry_internal` UPDATEs the original's `reversed_by` and inserts the reversal | §6.1 #15: render once as "Journal entry reversed". Existing keys `journal.reversal` / `journal.reversedBy` are batch-side wordings, so check that they fit a JE subject |
| 7 | invoice void vs credit note | `void_invoice_internal`: invoices issued→void + `sales_order_history invoice_voided` + reversal JE (D23). Credit note: a separate document (`credit_notes`/`credit_note_lines`/`cn_issues` + JE, D24). Both come from `invoice_requests` with a different `kind` | the `invoice_requests.kind` of the executed request. Note D24 lists `cn_issues + credit_note_lines` but the header table is `credit_notes` |
| 8 | invoices INSERT | order invoice (D21, `create_order_invoice`, SO history `invoiced`) / sales invoice grouping posted sales (D22, `create_invoice`) | `invoices.kind` (sale/order). Today it has **no** English value labels (§2.3) and its field label is wrong ("Reason type") |
| 9 | FX rate: `record_fx_rate` is an upsert | new (INSERT fx_rates + history `created`, F58) / correction (UPDATE + history `corrected`, needs a reason, F59) / `withdraw_fx_rate` sets `deleted_at` + history `withdrawn` (F60; §6.1 #9: not "deleted") | `fx_rate_history.action`. Caveat: the existing-row lookup filters `deleted_at IS NULL`, so re-recording a withdrawn date **creates a second fx_rates row** with the same key, and a per-row subject splits the story (Inferred consequence) |
| 10 | `gst_periods` INSERT status open | period opened (F49 `open_gst_period`) / return reopened for correction (F50 `correct_gst_return`, sets `corrects_period_id`) | writer, or `corrects_period_id IS NOT NULL` (§6.1 #11) |
| 11 | `management_packs` / `cash_forecasts` supersede | `freeze_management_pack` UPDATEs the old pack (superseded_*) and INSERTs the new one. `freeze_cash_forecast` does the same | one txid, two rows. "Produced/frozen" on the new row, "Replaced by {code}" on the old. Do not show "edited" on the old row |
| 12 | `bank_statement_lines.match_status` →unmatched | unmatched (F15: `unmatch_bank_line` **DELETEs** `bank_line_matches` + UPDATE) / no longer ignored (F17) | old value matched vs ignored (§6.1 #10). Match = INSERT `bank_line_matches` + UPDATE (F14): render once. Ignore carries a reason |
| 13 | `bank_statements` reconciled→open | `unreconcile_statement`: UPDATE `bank_reconciliations` (superseded) + statements status (F19) | render as "Reconciliation undone", not two edits |
| 14 | `finance_settings` UPDATE | `set_finance_settings` builds **dynamic SQL** (`EXECUTE format('UPDATE finance_settings SET %s …')`) from the keys present, so one row change can carry F38–F44 at once | per-column events from change_log old/new. `gst_registered` false→true vs true→false are different sentences |
| 15 | `finance_settings` approvals | `set_approvals_policy` UPDATEs 4 columns **and** INSERTs `finance_settings_history` (double record) | collapse to one "Approval policy changed" entry (§6.2) |
| 16 | `finance_settings.locked_before` | changed by `close_period` (INSERT period_closes, F34) and `reopen_period` (UPDATE period_closes reopened_*, F35) | always fold into the period-close event. Never "settings edited". Year close (F36/F37) is a JE + year_closes |
| 17 | asset disposal | `asset_disposal_requests` approved+executed / `fixed_assets` active→disposed + JE (F63/F66) | one entry: "Asset disposal approved", with the disposal as the detail (§6.2 "any request decided") |
| 18 | `contracts.status` →active | `terms_request_execute_internal` (F84, via an approved terms request) / suspended by a direct app UPDATE (F85, change_log only). expired/terminated have no writer (F86) | writer. The terms-request side already reads `tr.approved` ("CFO approved the terms") |
| 19 | WHT remittance reversed | JE only (see §1.1 gap) | needs a catalogue row and a decision on which subject shows it |

---

## 2. Field labels on the 60 AT-1c tables (59 listed + `payment_trigger_events`)

Method (Measured): `lib/trail/catalogue.generated.ts` TRAIL_FIELDS. "Shown" means kind ∉ {technical, audit_std, own_key, text_code, uuid_nofk} (the `HIDDEN` set in `scripts/check-trail-wording.mjs:146`) and the column is not in the generator's `HIDE`. "Override" means a hand label in `OVERRIDES` (`scripts/gen-trail-catalogue.mjs:82`). "pageLabel" means labels.csv has `label_confidence` high/medium.

### 2.1 Totals (Measured)

| | Tables | Shown columns | Hand overrides | page-measured labels |
|---|--:|--:|--:|--:|
| Already reached by an existing subject (`trail_subject_members` shown=true, or root) | 11 | **121** | **45** | 22 |
| New to AT-1c | 48 | **558** | 0 | 164 |
| **All 59 listed** | 59 | **679** | 45 | 186 |
| + `payment_trigger_events` | 1 | 7 | 0 | 0 |

The 11 already-shown tables, with their subjects:
- `journal_entries` 6 (inbound_batch / output_batch / stocktake)
- `invoice_lines` 14, `sales_records` 13, `sales_attribution_log` 7 (output_batch)
- `payment_allocations` 12 (inbound / output)
- `freight_allocations` 5, `finance_attachments` 9, `prepayment_applications` 8 (inbound_batch)
- `fixed_assets` 20 (equipment root, rule `page`)
- `contract_document_terms` 12 (purchase_order / sales_order; all 12 overridden)
- `terms_requests` 15 (pricing_formula)

Of those 121, only the 45 overrides were hand-checked. The other 76 passed only the automated machine-word arm.

**Calibration:**

| Cut | Shown columns | Tables | Override labels added | Enum values added |
|---|--:|--:|--:|--:|
| AT-1a | 197 | 18 | 219 | 42 |
| 1b-1 | 385 | 43 | +91 | +43 |
| 1b-2 | 311 | 38 | +91 | +78 |
| 1b-3 | 145 | 17 | +62 | +46 |

Sources: shown columns and tables are Measured from the handbacks (1a:428, 1b-1:396, 1b-2:834, 1b-3:508). Override counts are Measured by `ov.cjs`, which evaluates OVERRIDES at each commit; the AT-1a figure is the starting set. **AT-1c's 558 new columns are 1.45× 1b-1, the largest cut so far.** `fixed_asset_history` alone has 42 shown old_/new_ columns. Like the other `*_history` tables, it probably wants HIDE plus old→new rendering, which would drop about 40.

### 2.2 Generated labels that read wrong (Measured from TRAIL_FIELDS; judgment is mine)

**Wrong noun or meaning:**
- `invoices.status` = "All" (a filter option)
- `invoices.kind`, `invoice_requests.kind`, `credit_note_lines.kind` = "Reason type"
- `payment_requests.payment_id` = "Planned payment date" (it is an FK to a payment)
- `bank_transfers.to_account` = "Accounts"
- `fx_rate_history.action` = "Actions"
- `expense_claims.no_receipt_reason` = "Number receipt reason" (the WORD map turns `no` into "Number")
- `journal_lines.tax_code`, `credit_note_lines.tax_code`, `expense_claims.tax_code` = "Tax ID" (while `expenses.tax_code` = "Tax code")
- `gst_filing_requests.boxes` = "F5 box"
- `cash_forecasts.buckets` = "Bucket"
- `fixed_asset_history.fixed_asset_id` = "Fixed assets"
- `management_packs.base_currency` and `cash_forecasts.base_currency` = "Currency"

**Form or option text:**
- `period_closes.reopen_reason` and `year_closes.reopen_reason` = "Reason (required)"
- `contract_pricing_terms.qp_months` = "M (the base month itself)"
- `contract_pricing_terms.base_event` = "Base month from"
- `cash_forecasts.week_start` = "Starting Monday"
- `fx_rates.rate_type` = "Side"

**State word where a timestamp is meant:**
- `payment_requests.decided_at` "Decided", `withdrawn_at` "Withdrawn"
- `management_packs.produced_at` "Produced", `superseded_at` "Superseded"
- `cash_forecasts.frozen_at` "Frozen", `superseded_at` "Superseded"

**"at" vs "on" inconsistency:**
- `freight_documents.reversed_at` "Reversed at"
- `bank_statements.reconciled_at` "Reconciled at"
- `period_closes.closed_at` and `year_closes.closed_at` "Closed at"

**Casing or language suffix (the forward queue already names the first three):**
- `gst_return_boxes.label_en` / `label_zh` = "Label en" / "Label zh"
- `payment_trigger_events.phrase_en` = "Phrase en"
- Casing: "Gst period number", "Wht remittance number", "Rate Date", "Fy end day", "Fy end month", "First fy end", "Approval level1 role", "Approval level2 role", "Bank swift", "Prev rate", "Sha256" (`invoice_issues.sha256` and `cn_issues.sha256` should be HIDE, like `qt_issues` and `so_issues`)

**Duplicate labels within one table (the trail cannot tell the columns apart):**
- `payments`, `payment_requests` and `freight_documents`: `amount_base` and `amount_ccy` are both "Amount"
- `expenses`: `tax_base` and `tax_ccy` are both "Tax"
- `gst_periods`: `filed_at` and `filed_on` are both "Filed on"

**Jargon or raw names:**
- "Result journal entry", "Result entry", "Target entry", "Entry" (on invoices and credit notes)
- "Amount in (dest ccy)", "Amount out (source ccy)", "Credits bank", "Bill to snapshot"
- "Snapshot", "Estimate", "Result", "Payload", "Mapping" (JSON columns; these probably need HIDE or a summariser)
- "Label" on 4 request tables (earlier cuts overrode it to "Request")
- `fixed_asset_history` "New created on", "New created by", "Old disposal proceeds"

### 2.3 Enum columns with no English value labels (Measured by the same method as the wording check's arm ③: CHECK values vs TRAIL_ENUMS)

**24 columns, 54 values missing:**
- `invoices.kind` (sale, order), `invoices.status` (issued, void)
- `payments.status`, `freight_documents.status` (posted, reversed)
- `payments.counterparty_type`, `payment_requests.counterparty_type` (customer, supplier, employee)
- `bank_account_code` / `from_account` / `to_account` on payments, bank_transfers, expenses, freight_documents, bank_import_profiles (1000, 1010; these are account codes, so they want the account name, not an enum label)
- `fixed_asset_history.changed_by_kind`
- `gst_periods.status` (open, approved, filed)
- `fx_rate_history.action` (created, corrected, withdrawn)
- `cash_forecast_lines.direction`
- `finance_settings.default_allocation_basis`
- `contract_insurance_obligations.insured_by`
- `contract_volume_commitments` committed_by_party, direction, period
- `contract_settlement_terms` penalty_basis, refining_charge_basis, settling_party

**A further 12 enum/enum_like columns have no CHECK values and no map**, so they would humanize:
- `invoice_lines.unit`, `expenses.wht_payee_residence`
- `fixed_asset_history` old/new category and status
- `fx_rates.source`, `fx_rate_history.rate_type` and `source`
- `contracts.side`, `contract_insurance_obligations.cover_type`, `contract_volume_commitments.unit`

---

## 3. Timing calibration

Sources:
- Session transcripts `~/.claude/projects/-Users-timchen/*.jsonl`: message timestamps (UTC, +8 applied) and Bash tool_use → tool_result times (`tl.py`).
- Handbacks, `db/migration-windows.tsv`, and `git reflog refs/remotes/origin/main` (push times).

M = Measured, I = Inferred.

### 3.1 Sessions

| Cut | Session (file) | Brief pasted | Tim's answer / build start | Backup launched | Apply committed | Push of the cut | Idle gaps > 10 min |
|---|---|---|---|---|---|---|---|
| AT-1 Step 0 | 0c0d03c2 | 09-29 10:00:12 (M) | — | — | — | (survey copied into the repo by 1a) | ends 11:00:40 (M) |
| AT-1a | fb669b61 | 09-29 11:08:58 (M; answers in the brief) | 11:08:58 | 12:59:15 (M) | 13:30:45 (M, tsv) | 18:55:08 (M, reflog) | **15:12:18 → 18:20:35, 3 h 08 m 17 s** (user interrupt, then "continue") (M); 11:46 → 11:59 (13 m) |
| AT-1b Step 0 + 1b-1 | 7ccb027b | 19:12:26 (M) | 19:50:15 (M; Step 0 hand-back 19:31:31, Tim waiting 18 m 44 s) | 20:54:54 (M) | 21:15:05 (M) | 23:26:55 (M) | 3 × ~10 min (waits) |
| 1b-1 close-out + 1b-2 | 76703917 | 23:40:07 (M; first command 23:40:39 per handback) | 23:53:42 (M; stopped at step 1, Tim answered) | 00:45:20 (M) | 01:06:27 (M) | 02:57:40 (M) | 02:16 → 02:26 (probe-injection wait) |
| 1b-2 close-out + 1b-3 | 00569e2c | 10-03 09:17:57 (M) | 09:17:57 | 10:12:15 (M) | 10:31:01 (M) | 12:24:10 (M) | none. Context compacted at 12:09 (same file). The close-out e0a7b20e was pushed 12:33:43 from another session |

**No cut spanned multiple build sessions (M).** Each close-out ran at the start of the *next* cut's session. AT-1a's session contains a 3 h 08 m idle gap. 1b-2's deploy confirmation came 3 days later (the window's upper bound is 80 h), but that is not work time.

### 3.2 Wall clock and phases

| Cut | Brief → push | Active (minus idle / Tim waits) | Build start → backup launch ("work", migration + most code) | Backup → push ("floor + fixes", active) | Subjects | Shown columns | text.ts keys | Overrides |
|---|---|---|---|---|--:|--:|--:|--:|
| AT-1a | 7 h 46 m 10 s (M) | **4 h 37 m 53 s** (M) | 1 h 50 m 17 s (M) | 2 h 47 m 36 s (M) | 3 + mechanism + summary page | 197 | 117 | 219 |
| 1b-1 | 4 h 14 m 29 s incl. Step 0 (M) | 3 h 55 m 45 s; build only **3 h 36 m 40 s** (M) | 1 h 04 m 39 s (M) | 2 h 32 m 01 s (M) | 7 | 385 | 123 | 91 |
| 1b-2 | 3 h 17 m 33 s incl. close-out (M) | build only **3 h 03 m 58 s** (M) | 51 m 38 s (M) | 2 h 12 m 20 s (M) | 11 | 311 | 113 | 91 |
| 1b-3 | 3 h 06 m 13 s incl. close-out (M) | **3 h 06 m 13 s** (M) | 54 m 18 s incl. 1b-2 close-out (M) | 2 h 11 m 55 s (M), of which ~10 m waiting on a mistaken second backup (M: 591 s wait, 12:13 → 12:23) | 8 + deleted-records read-only | 145 | 54 | 62 |

Code continues during the detached backup, so "work" before the backup undercounts it (I).

### 3.3 Process steps (Measured unless marked)

| Step | AT-1a | 1b-1 | 1b-2 | 1b-3 |
|---|---|---|---|---|
| Offline gate | 62 s | 68 s | 64–66 s | 66 s |
| Dry run on live | 185 s; red once, ~7 min total | 2 m 13 s | 17 s | 1 m 47 s; red once |
| Backup | ~27 min | ~17 min | ~18 min | 16 min (10:12 → 10:28) |
| apply_migration | ~3.5 min, + index 9.7 s | ~(21:12 → 21:15) | 134 s | ~2 min |
| types:gen | 3 runs (PostHog line) | 1 | 1 | 1 |
| tsc + build | 11 s + 7 s fail + 99 s | build fail once | 49 s rerun | 55 s × 2 |
| Full gate | 611 s | 461 s | 521 s | 445 s |
| Layout surveys 390 + 1280 | ~30 min with iteration (13:57 → 14:27) | 12 routes | 11 routes, rerun | 18 routes, rerun |
| Route smoke | run 1 failed (network + 500), run 2 after the idle gap | run 1 network fail, run 2 ok | full + 358 s trail-only rerun | **1,264 s** + trail-only rerun |
| Page probe | — | first run 6 own-criteria fails, ~16 min of fixes | 162 s + 603 s injections | 22/0/3, rerun |
| Live readings / proof | 18:51 → 18:52 | 23:18 → 23:21 | 02:28 → 02:30 | 11:39 → 11:42 |

**Floor estimate (I):**
- backup 16–27 min, apply 2–4 min, types/tsc/build ~3 min, full gate 7.5–10 min, surveys ~10–15 min, smoke ~21 min, probe ~5–10 min, readings/proof ~5 min, final build + commit ~3 min.
- That is about **75–100 min of unavoidable process per cut**. The measured backup→push phase is 2 h 12 m – 2 h 48 m active, so about 35–70 min per cut went on fixes found by the proof, probe or smoke (decisions 22–28 in the 1b handbacks).

### 3.4 Rates

| Cut | Build active / subject | Keys / h | Shown columns / h |
|---|---|---|---|
| AT-1a | 93 min (mechanism-dominated) | 25 | 43 |
| 1b-1 | 31 min | 34 | 107 |
| 1b-2 | 16.7 min | 37 | 102 |
| 1b-3 | 23.3 min (incl. close-out and deleted-records) | 17 | 47 |

All of these are Inferred from the M figures above.

**Projection for AT-1c (I):**
- Scope: 558 new shown columns (~400 if `fixed_asset_history` is hidden or collapsed), 85 catalogue rows (70 without settings/close), ~20–24 subjects, 130–170 keys.
- At the 1b-2 rate, that is about 6–7 h of build in one cut, beyond what any single session has held.
- Split like 1b into 2–3 cuts: each costs ~2 h 12 m of floor-plus-fixes plus ~1 h of pre-backup work, so **~3 h 15 m per cut, about 6.5–10 h total**. The original Step 0 estimate was "3–5 h + 3 h" (README §8).
