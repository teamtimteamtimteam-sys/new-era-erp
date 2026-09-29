# AUDIT-TRAIL-0 + DATE-PICK-0: Step 0 handback (stop gate)

Tim: the survey is done, nothing was changed, and every open question is below with my recommendation. I need your answers to Q1–Q43 (or a "go with the recommendations") before any build.

**Opening check passed.** The working tree is clean, and `HEAD`, `origin/main` and `ls-remote` are all `d93c083b0c0b6192fd2638c058e266e0050da6eb`. No edits, migrations or commits were made; the only files written are in my scratchpad.

**How it was measured.** Every live query ran read-only as `postgres`, which bypasses row security, so row counts are true totals. Nine read-only sub-agents did the survey. Their full outputs are in `docs/surveys/AUDIT-TRAIL-0/ (copied from the Step 0 scratchpad)`:
- the operation map: `ops-finance.md`, `ops-commercial.md`, `ops-production.md`, `ops-people-settings.md`
- the event catalogue: `events.md`
- labels and values: `values-labels.md` and `labels.csv`
- the reader and masking: `reader-masking.md`
- mock-up data: `mockup-data.md`
- dates: `dates.md`
- time estimate: `estimate-basis.md`

The scratchpad is temporary. I can copy these into `docs/surveys/AUDIT-TRAIL-0/` in the build commit if you want them kept.

---

## 1. What grilling changed in this scope

1. **A processing run has no "running → completed" status.** Its status is either `committed` or `reversed`, and a run is written in one transaction. "Processing started" only exists on the batch: its stage goes from awaiting processing to in progress, and that stage value is stored in Chinese. There is **no weighing step** anywhere; weight is captured once, at receipt.
2. **The change log starts at 28/09/2026 23:58.** It holds 180 rows. 173 are the smoke test's writes, 4 come from a since-deleted smoke account and 3 are the migration's own. None is a real business write. If trails read only the change log, every existing record's trail is empty. The inbound batch trail's current 292 rows (over 44 batches) would also disappear, which breaks your "keep everything it shows" ruling. → Q1.
3. **Hiding columns is not enough; some rows must be hidden too.**
   - HISTORY-1's rule list hides columns only. Some tables instead hide whole rows from some readers.
   - Example: `salary_change_requests` rows can only be read with `module.hr.view` plus `data.view_pay`. On an employee page's trail, those rows would reach anyone who can open the page.
   - 16 read policies on 13 tables are "own rows only".
   - So a trail must re-check each child row against its own table's read rule. → Q4.
4. **Finding a record's child rows needs a two-step lookup.** An edit stores only the changed columns, so a price edit on a PO line doesn't carry the PO's id. The reader must first collect the child rows' keys, then fetch every log row for those keys. → Q6.
5. **The scope is large:**
   - **about 320 user operations** (finance 93, commercial 76, production 104, people and settings 47 groups)
   - **87 host routes**
   - **233 business events**, of which 196 need new wording
   - **2,268 displayable fields**; 890 have no English label anywhere
   - **134 native date inputs in code** (8 more mentions sit in comments)

   → I propose a split (§7).
6. **Period lock and GST settings live on `/finance/settings`, not `/settings`.** They share one database row with the approval policy, so each settings panel's trail must show only the fields that panel owns. The approval policy is editable; the comment in `lib/modules.ts:843` says it isn't, and that comment is wrong.
7. **Some records lose their page at exactly the moment their trail matters.** A reversed run, a written-off batch, a deleted formula or material, a deleted customer or supplier: their pages all filter out deleted rows. → Q21.
8. **The date format conflicts with your earlier DATE-1 rulings:**
   - DATE-1 (D4) made screen display "01 Sep 2026".
   - D2 kept audit timestamps as `2026-09-01 14:33`.
   - This brief asks for DD/MM/YYYY in the trails and in the date boxes.
   - No formatter prints DD/MM/YYYY today.

   → Q15, Q16.
9. **English-only trails need their own wording catalogue.** The i18n check requires every message key in both `en.ts` and `zh.ts`. Also, the database stores machine-written Chinese: automatic approval notes, the batch stage values and output batch states. → Q7, Q8.
10. **Permission names come from the database** (`permissions.name_en`, all 72 filled), not from the message files. That makes role trails easy to label.
11. **The existing date checks can't simply be set to zero.** Both stop with "my measure is broken" once zero native inputs remain; they need re-aiming at the new picker. → Q38.

**Assertions in the brief that I measured as false:**
- "running → completed" doesn't exist, and "weighing" has no step (item 1).
- The finance slice has no settings page for approvals under `/settings`… Correction: approvals *are* at `/settings/approvals`. **Period lock and GST are not in /settings** (item 6).
- `set_role_permissions` "deletes and re-inserts". Two sub-agents claimed this; it has been false since HISTORY-1 (`db/functions/set_role_permissions.sql:62-67` only removes codes no longer wanted and adds new ones).

**Measured true:** the three SHAs · approvals ON, finance / cfo / 1,000 (`finance_settings`) · 7 accounts, 0 disabled (`auth.users`) · 238 tables bound to the change log (`information_schema.triggers`).

---

## 2. The operation map (a), by where each trail lives

Every row in the per-slice files has the operation's UI entry (route and file), its server action, RPC, permission, tables written, the record it acts on, its host page, and whether it is a key event or a field edit.

**Permissions are enforced only in the database.** 0 of about 300 writing server actions check a permission themselves (grep). Every permission code in the map therefore comes from the function body or the table's access policy.

| Area | Operations | Host pages (route → `app/<route>/page.tsx`) |
|---|---|---|
| Purchasing | Raise, approve, reject, amend, cancel, close, reopen, issue PDF, expected date, retention, contract link | `/purchasing/orders/[id]` (+`/amend`), `/purchasing/payment-terms/[id]/edit` |
| Sales | Quote create, issue, convert, decline · order amend, reserve, release, ship, invoice · shipment · customer edit, credit, contacts, statements, chasing | `/sales/quotes/[id]`, `/sales/orders/[id]` (+`/amend`), `/sales/shipments/[id]`, `/sales/customers/[id]` (+`/edit`), `/sales/commissions/[id]/edit` |
| Suppliers and logistics | Supplier review, activate, suspend, archive, compliance, attachments · container milestones and documents · forwarder details and rates | `/suppliers/[id]/edit`, `/logistics/containers/[id]`, `/logistics/forwarders/[id]` |
| Receiving and batches | Receive, batch facts, safety state, metal content, assay record/apply/unapply, price receipt, price request, write-off request, COD issue | `/inbound/[id]/edit`, `/inbound/[id]/assays/[assayId]`, `/output/[id]/edit`, `/output/[id]/assays/[assayId]` |
| Processing | Complete a run, add and edit cost entries, allocate costs, roll back (through a warehouse request) · work orders create, release, amend, close, cancel | `/operation/processing/[id]`, `/operation/orders/[id]` |
| Warehouse | Stocktake count, post, cancel · storage locations · materials | `/stocktakes/[id]` (+`/review`), `/inventory/locations/[id]/edit`, `/materials/[id]/edit` |
| Pricing and tools | Metal prices, formulas and terms requests, tasks | `/tools/pricing/metal-prices/[id]/edit`, `/tools/pricing/formulas/[id]/edit`, `/tools/tasks/[id]` |
| Finance documents | Journal and its requests, invoices, credit notes, payments and payment requests, expenses, freight, receivables and payables attachments, assets and equipment, bank statements and reconciliation, GST periods and filing, FX rates, packs, contracts | `/finance/journal/[id]`, `/finance/invoices/[id]`, `/finance/credit-notes/[id]`, `/finance/receivables/[saleId]`, `/finance/payables/[batchId]`, `/finance/payments/[id]`, `/finance/payment-requests/[id]`, `/finance/expenses/[id]`, `/finance/freight/[id]`, `/finance/assets/[id]`, `/finance/bank/statements/[id]`, `/finance/gst/[periodId]`, `/finance/fx/[id]/edit`, `/finance/packs/[id]`, `/contracts/[id]` |
| Finance period-end and settings | Period lock, GST settings, month and year close/reopen, company profile, revaluation, depreciation run, bulk FX, forecasts, payroll payments, processing-cost settlement, WHT, transfers, claims, import profiles | `/finance/settings`, `/finance/close`, `/finance/company`, `/finance/revaluation`, `/finance/assets`, `/finance/fx`, `/finance/cash-forecast`, `/finance/payroll-payments`, `/finance/processing-costs`, `/finance/wht`, `/finance/bank`, `/finance/claims`, `/finance/bank/import`, `/finance/bank/statements`, `/finance/gst`, `/finance/packs`, `/finance/journal` |
| HR | Employee edit and link, training, leave request/decide/cancel, carry-forward, leave types, holidays, medical claims, overtime, attendance, payroll, reviews, KPI | `/hr/employees/[id]` (+`/edit`), `/hr/departments/[id]/edit`, `/hr/training/[id]/edit`, `/hr/leave/[id]`, `/hr/leave/grants`, `/hr/leave/types`, `/hr/leave/holidays`, `/hr/claims/[id]`, `/hr/overtime/[id]`, `/hr/attendance/[id]`, `/hr/payroll/[id]`, `/hr/reviews/[id]`, `/my-reviews/[id]`, `/hr/reviews/cycles`, `/hr/reviews/scale`, `/hr/kpi/score`, `/me` |
| Access and settings | Role permissions, role grants, accounts (create, disable, enable), approval policy, dictionaries, bulk import | `/settings/roles/[id]`, `/settings/accounts`, `/settings/approvals`, `/settings/dictionaries`, `/settings/import` |

**Operations with no fitting page, and the home I recommend:**

| Operation | Recommended home |
|---|---|
| New-entry journal requests | `/finance/journal` (per request), then the posted entry's page |
| Expense claims | `/finance/claims` per claim, `/me` for the claimant, then the expense page |
| Bank transfers · WHT remittances | Their payment-request page, plus `/finance/bank` or `/finance/wht` |
| Cash forecasts · bank import profiles · deleted statements | Their list page |
| Depreciation, revaluation and bulk-FX runs | The page with the button (each asset or rate also shows its own row) |
| Warehouse requests (write-off, rollback, COD void) | The subject's page (batch or run), plus a short block on `/inventory` |
| Shift handovers | New `/operation/handovers/[id]` (→ Q23) |
| Equipment servicing and downtime | New `/operation/equipment/[id]` (→ Q22) |
| Processing, pricing and receiving thresholds | Under the panel that edits each |
| Ports, lanes, company licences | `/logistics/lanes`, `/purchasing/licences` |
| Departments, leave carry-forward runs, review cycles, KPI generation | Their list pages |
| Account events, role grants to an account, account–employee links | Per-account trail on `/settings/accounts`, mirrored on the employee page (→ Q24) |
| Login, logout, set password | Nothing is recorded anywhere (`auth.audit_log_entries` has 0 rows); out of scope |
| Avatar, notification read, COD verification counter | No trail (→ Q19) |
| Operations with no UI caller (`deleteEmployee`, `updateQuoteHeader`, `softDeleteCommissionAgreement`, `rollback_processing_run`) | None |

## 3. Pages (b)

There are **87 host routes**: commercial 16, production 16, finance 32, people and settings 23. They are listed in §2. Each page's child tables and join paths are in the per-slice files; examples:
- the PO page rolls up lines, payment terms, retentions, term commitments, PO issues, contract terms and approvals;
- the batch page rolls up metals, assays and their metals, safety states, price history, price requests, prepayments, movements, stocktake lines, run inputs, allocations, COD, warehouse requests, freight and payment allocations, attachments and journals.

**Who reads each trail:** anyone who passes that page's own access check (`requireModule(MOD.x)`, recorded per page).

## 4. Key-event catalogue (c): the wordings that matter most

The full catalogue is `events.md` §5: **233 events**, 37 with an existing English key and 196 new. **Every wording is for you to confirm (Q9).**

| Event | Wording | Detail line |
|---|---|---|
| PO created | Purchase order raised | lines · total with currency |
| PO auto-approved (approvals off) | Approved automatically (approvals were switched off) | — |
| PO approved / rejected | Purchase order approved (level 1) / Purchase order rejected | note |
| PO amended | Purchase order amended · N changes | field lines · reason |
| PO cancelled / closed / reopened | Purchase order cancelled / closed / reopened | reason |
| PO issued | Purchase order PDF issued | issue number |
| Goods received | Goods received · 405 kg | PO, material |
| Processing started (batch) | Processing started on this batch | run number, quantity used |
| Run committed | Processing completed | used, produced, loss |
| Cost entry added / changed | Processing cost added · Labour 200.00 SGD | journal |
| Costs allocated | Processing costs allocated · by metal value | per output batch, capitalised amount |
| Run rolled back | Processing rolled back | reason, approver |
| Assay recorded / applied / unapplied | Assay recorded / Assay applied to this batch / Assay result withdrawn | lab, metals |
| Write-off | Batch written off | reason, approver |
| Stocktake posted | Stocktake posted | adjustments |
| Quote converted | Quote converted to sales order SO-… | — |
| Shipped | Goods shipped · SH-… | lines |
| Invoice issued / voided | Invoice issued / Invoice voided | reason |
| Payment | Payment recorded / Payment reversed | amount, allocations |
| Journal reversed | Journal entry reversed | reversing entry |
| Month closed / reopened | Month closed up to 31/08/2026 / Month reopened from 01/08/2026 | — |
| Period lock moved | Period lock moved: 31/07/2026 → 31/08/2026 | — |
| Approval policy | Approval settings changed | each setting |
| Role permissions | Permissions changed · 2 added, 1 removed | Added: … Removed: … (names from `permissions.name_en`) |
| Roles granted | Roles changed | Given: CFO · Removed: … |
| Account events | Account created / disabled / re-enabled | — |
| Leave | Leave requested / approved / rejected / cancelled | days, decider's note |
| Salary change | Salary change approved · effective 01/10/2026 | amounts, or Restricted |
| Supplier | Supplier submitted for review / approved / suspended / reinstated / archived | reason |
| Fallback, any table | Created / Edited / Deleted *thing* | field changes |

**Ambiguities, resolved by the old value or by which function wrote the row** (`events.md` §6.1, 20 cases). For example, a PO moving to `receiving` means "first goods received" or "reopened", depending on the old status. A requests row inserted as `approved` is an **automatic** approval, not a human one. A `deleted_at` stamp can mean deleted, withdrawn, taken out of use or reversed, depending on the writer.

**Several rows, one entry:** every write in one database transaction is one entry (`events.md` §6.2, 26 patterns).

## 5. Readable values, labels and system writes (d, e, f)

**Resolving each kind of value** (2,962 columns on the 238 logged tables):

| Kind | Count | Shown as | Resolved from |
|---|---|---|---|
| Created/updated stamps | 446 | Hidden | — |
| Technical columns (ids, sequence, hashes, paths) | 248 | Hidden | — |
| References to documents | 226 of 444 references | Document number | `public.document_types` (41 rows): number prefix and detail route |
| References to dictionaries | 79 | `name_en` | The dictionary table |
| References to currencies | 34 | Currency code | `currencies` |
| References to other tables | 63 | A composed description | Per target |
| People | 25 with a foreign key, plus 309 bare ids | Preferred name, else legal name | `loadActorNames` / `<ActorName>` (`app/components/ActorName.tsx:49`) |
| Enums | 164 | English value labels | 79 are registered in the i18n check; 69 inferred; 16 partly or not covered |
| Money | 166 | Amount with its currency | 14 have no currency column; each resolves by an existing convention (base currency, bank currency, the PO's currency) |
| Dates / timestamps | — | DD/MM/YYYY (HH:MM) in Singapore time | A new formatter |
| JSON columns | 43 | A dedicated renderer or "Details changed", never raw JSON | — |

**A deleted referenced record** is named from its last image in the log: "PO-2026-0010 (since deleted)". If that isn't recoverable (deleted before 28/09, or anonymised), it reads "a supplier that has since been deleted".

**Field labels:** of 2,268 displayable columns, **640** have a label a page demonstrably uses next to that column, **738** only have similar wording elsewhere in `en.ts`, and **890** have none. Proposed labels for all of them are in `labels.csv`. Three per-field label maps already exist to copy the pattern from: `assets.history.field.*`, `contractDetail.field.<table>.<col>` and `termsRequest.field.*`.

**System writes:**
- Every write with no login reads **"System (automatic)"**: migrations (`postgres`) and service jobs (`service_role`).
- **Smoke-test writes** are 173 of the 180 log rows. Nothing distinguishes them from other system writes, and they touch only smoke records that have since been deleted. They can only ever appear on the summary page, so I recommend no special wording.
- **A deleted account** is named from the employee recorded with the write, even if that employee was later deleted (from the log's last image). With no person at all, it reads **"Removed account"**; the 4 smoke rows are this case.
- **A disabled account** reads as the person's name, with nothing added.
- **Rolled-back fixtures** leave nothing in the log.

## 6. Layout (g): proposal and three mock-ups from live data

**The proposal:**
- **Position:** a section titled "Audit trail" at the very bottom of each page, newest first, times in Singapore time.
- **Three columns:** When (`DD/MM/YYYY HH:MM`) · Who · What happened.
- **One entry per operation (database transaction):**
  - first line: the event title, with a short summary where useful;
  - under it: one line per changed field, `Label   old → new`;
  - a child line is introduced by its own heading, such as "Line 1 · Mobile Discharging Solution";
  - the reason always shows last.
- **Long entries:** the first 4 detail lines are shown, then "Show N more" expands in place. Long text is cut at 120 characters with "more".
- **Paging:** 20 entries, then "Show older entries".
- **At 390px:** each entry becomes a card with the title first, then "time · person", then each field on its own line with `old → new` beneath it.
- **Masking:** a hidden value shows as a "Restricted" pill. A genuinely empty value shows as "(empty)", never as a blank or "null".

**A. `/purchasing/orders/[id]` — PO-2026-0010, Bosch Rexroth, SGD.** Read by someone who holds the purchase-price code. Real rows from `purchase_order_history` and `approval_log`, all from before the change log began.
```
Audit trail                                        Newest first · Singapore time
When              Who      What happened
08/09/2026 10:47  Sandra   Purchase order cancelled
                           Reason: Too many errors - will redo one
08/09/2026 10:41  Sandra   Purchase order amended · 3 changes
                           Order date   03/09/2026 → 08/09/2026
                           Incoterm     CIF → CIF or otherwise specified
                           Notes        (empty) → Payment schedule 50% Advanced, 40% upon
                                        delivery, 10% upon completion of training
                           Reason: To change the payment schedule, order date and leaving
                           Incoterms open
03/09/2026 16:51  Tim      Purchase order raised · 1 line · 305,550.00 SGD
                           Approved automatically (approvals were switched off)
─ Before 29/09/2026 only key steps and amendments were kept; single-field edits were not. ─
```
No purchase order in live data has a line change (10 history rows over 6 POs, 0 line rows). **Illustrative only**, showing a line change read by someone *without* the purchase-price code:
```
dd/mm/yyyy hh:mm  Sandra   Line 1 changed · Mobile Discharging Solution (FA-2026-0002)
                           Quantity              1 → 2 units
                           Estimated unit price  Restricted
```
The same amendment at 390px:
```
┌─────────────────────────────────┐
│ Purchase order amended          │
│ 08/09/2026 10:41 · Sandra       │
│ Order date                      │
│   03/09/2026 → 08/09/2026       │
│ Incoterm                        │
│   CIF → CIF or otherwise spec…  │
│ Show 2 more (notes, reason)     │
└─────────────────────────────────┘
```

**B. `/operation/processing/[id]` — PROC-2026-0164.** The richest of 14 runs; real rows.
```
10/08/2026 17:38  Tim   Processing costs allocated · by metal value
                        OUT-2026-0186 NMC Cathode Foil          809.14 SGD (4.0457 SGD/kg)
                        OUT-2026-0187 Special Battery Material  134.86 SGD (2.2477 SGD/kg)
                        Capitalised 944.00 SGD · journal JE-2026-0045
10/08/2026 17:37  Tim   Processing cost added · Electricity 300.00 SGD (estimate)
                        Journal JE-2026-0044
10/08/2026 17:36  Tim   Processing cost added · Labour 200.00 SGD · journal JE-2026-0043
10/08/2026 17:36  Tim   Processing completed · process date 10/08/2026
                        Used      IN-2026-0001 NMC Cathode Foil           300 kg
                        Produced  OUT-2026-0186 NMC Cathode Foil          200 kg
                                  OUT-2026-0187 Special Battery Material   60 kg
                        Loss 40 kg
```
Without `data.view_prices`, every amount and rate shows "Restricted". The run's inputs and outputs record no person of their own, so the entry takes its person from the run.

**C. `/settings/roles/[id]` — the CFO role.** Real change-log row (seq 3, the HISTORY-1 migration):
```
28/09/2026 23:58  System (automatic)  Permission added · View change history
```
**Illustrative only** (the only role save in the log so far belongs to the smoke test):
```
dd/mm/yyyy hh:mm  Tim   Permissions changed · 2 added, 1 removed
                        Added    View purchase prices · Suppliers (edit)
                        Removed  Stocktakes (edit)
```
For cco, the only real record is the pre-log stamp on its 41 grants:
```
28/09/2026 19:00  Tim   Permissions set · 41 permissions
                        The list before this was not kept.
```

## 7. Reading, permission, cost; summary page; batch trail; dates; migration (h–m)

**(h) Reading and masking: a new server-side reader, `record_trail(subject, id)`.**
- **Scope comes from the server.** The page names a registry subject, never a table. The registry, kept on the server, defines the record's root table and its child and related tables.
- **Authorisation:**
  - the page's own view code;
  - the root row's own read rule;
  - each child row checked against its own table's read rule, done by re-checking that table's access policy on the server.
  - This works because none of the 287 read policies depends on the database role: 0 are restrictive, and all resolve the person from the login.
- **Masking:** HISTORY-1's masking step, pulled out into one shared function that both readers call. No new rules.
- **Refusals:** an unknown subject or a refused reader raises an error, never returns an empty list.
- **Query cost (measured on the live 180-row log):**
  - root lookup: an index scan, 1–4.5 ms;
  - child-key discovery: a filter on the table name.
- **At scale (inferred):** a partial GIN index on insert/delete row images.

**(i) Summary page `/settings/change-history`** (still admin + cfo only):
- **Filters:** date range (new picker) · area (module) · record type (English display names) · record, searched by document number or name · who (people, "System (automatic)", "Removed account") · key events only.
- **Columns:** When · Who · Record (document number, linked) · What happened, grouped by operation, in the same wording as the trails.
- **Machine language it prints today, all to be removed:** raw table names, `role_id=uuid` keys, column codes, raw JSON, ISO timestamps, "No session · service_role".

**(j) Inbound and output batch trail.**
- **Today:** 20 row kinds (18 occur in live data), 11 warning types, fixtures 181–183.
- **Defects in it:**
  - 39 dead links to `/processing/{id}`;
  - table names and codes on screen;
  - the restricted-amount sentence names the wrong permission code;
  - no rows at all for assays, metal content, safety states, requests or COD issues.
- **The unified trail keeps every kind** (they become child and related rows) **and adds the missing ones.**

**(k) Dates.**
- **Inputs:** 134 native inputs in code: 125 date, 5 month, 4 date-and-time, across 90 files and 81 routes. There are also 4 wrapper components (`DateFilterInput`, `ContractDateInput`, `PaymentDateInput`, a local helper). There is no date library.
- **The shared picker:**
  - **Building blocks:** built in-house on Radix Popover (already installed). It reuses `MonthGrid` (already starts on Monday) and the strict DD/MM/YYYY parser in `lib/bankCsv.ts`.
  - **Typing:** you can type D/M/YYYY, DD/MM/YY (read as 20YY), DDMMYYYY, or paste an ISO date.
  - **Calendar:** keyboard use is arrows, PageUp/PageDown, Enter and Esc. Days outside min/max are disabled.
  - **Posting:** the form posts an ISO value through a hidden input.
  - **Invalid dates:** an invalid date blocks the submit instead of silently posting empty.
  - **Size:** a fixed width, 32px tall.
- **DATE-0 Q1** asked "do the picker half at all?". Your D1 answer then was "its own cut"; this brief now commissions it.
- **The native-date check** changes from "may only go down" to **zero native date, month or date-and-time inputs**, with an independent second count so a blind scanner fails loudly. `check-date-data-paths.mjs` gets re-aimed at the picker's props.

**(l) New operations.** Only one: **reading a record's trail**.
- Page: every host route in §2/§3 (file `app/<route>/page.tsx`).
- Permission: that page's own view code plus the row checks above.
- Proposed refusal codes: `TRAIL_SUBJECT_UNKNOWN` and `TRAIL_NOT_PERMITTED` (English).
- No write operation is added or changed.

**(m) Migration and broken window.**
- **Additive only:** a registry function, `record_trail`, the shared masking function, and one GIN index on `change_log`.
- **Unchanged:** the capture triggers are not rebound, and `change_log_rows` stays as it is.
- **Batch trail views:** `batch_audit_trail` and `_all` stay in place (the new UI simply stops reading them) and get retired later.
- **Broken window:** nothing breaks inside it; old code keeps working against the new database.

## 8. Time estimate (n): two numbers

- **Process floor per migration cut that changes pages** (measured, `estimate-basis.md`):
  - backup: 18–29 min
  - full gate: 8–15 min (HISTORY-1's was 908 s)
  - smoke: 31–35 min
  - layout survey: about 75 min
  - plus dry run, apply, proof and retries (6 of the last 10 cuts retried a step)
  - **Total: about 2.5–3.5 h.**
- **Work for the whole scope: about 16–26 h (inferred).** Calibrated on measured rates: HISTORY-1 took about 3.5 h for the change-log engine, DATE-1 swept 393 sites in one cut, and replacing a control takes 1–2.5 min per site.

**One session can't hold this; recent cuts took 2–6 h each.**

**Proposed split.** Every part leaves operator-usable pages; pages not yet converted keep working exactly as today.

| Part | Content | Work + floor |
|---|---|---|
| 1 · AT-1a | Reader, registry, row checks, value resolvers, English wording catalogue, trail component, machine-token check · summary page rewrite · first pages: PO, processing run, roles | 4–6 h + 3 h |
| 2 · AT-1b | Commercial and production pages · batch trail replaced · pre-log records merged in · new equipment and handover pages if approved | 4–6 h + 3 h |
| 3 · AT-1c | Finance and contracts pages | 3–5 h + 3 h |
| 4 · AT-1d | HR, settings and accounts pages · `/me` | 3–5 h + 3 h |
| 5 · DATE-PICK-1 | Picker and all 134 sites · the zero check (no migration) | 4–6 h + 2 h |

---

## 9. Open questions: all of them, each with my recommendation

**Content and sources**

❓ **Q1 — History before the log.** Should trails merge earlier history (the 17 domain history tables, approval decisions, lifecycle stamps, the batch trail's sources) for dates before 28/09/2026 23:58, under a divider line?
➡️ **Yes.** Otherwise every existing record's trail is empty, and the batch trail's 292 rows disappear, which breaks your "keep everything" ruling. After the log starts, domain history rows only add meaning (reasons, approval levels) and are never shown twice.

❓ **Q2 — One entry per operation.** Should "one operation" mean one database transaction?
➡️ **Yes.** All 26 multi-row patterns in `events.md` §6.2 are single transactions.

❓ **Q3 — What a record's trail includes.** Its own row and child lines, plus events caused by related documents, such as a payment applied to an invoice, a journal posted by a document, or stock movements on a batch?
➡️ **Yes, for related events registered per subject.** Each reads as one line linking to the other record, and shows on both pages. The batch trail already works this way.

❓ **Q4 — Rows this reader can't see.** Child or related rows the reader couldn't open themselves, such as salary-change rows without `data.view_pay`:
➡️ **Keep the entry with its time, and "Restricted" in place of what happened and who.** Existence stays visible and content does not; this follows the batch-trail precedent and your "Restricted is not empty" rule.

❓ **Q5 — The reader.** Should trails use a new reader keyed by a registry subject, authorised by the page's own access check, with one shared masking step? The summary page's reader stays as it is.
➡️ **Yes.** Widening `change_log_rows` instead would let any holder read any table's history.

❓ **Q6 — Finding child rows.** Find them at read time with a GIN index, or add a parent key to every captured row?
➡️ **Read time.** A parent key means rebinding 238 triggers, which blocked writes for about 143 s in HISTORY-1's dry run.

**Language**

❓ **Q7 — English in a Chinese interface.** Should the trail stay English when the interface is in Chinese, with its wording in an English-only catalogue that has its own completeness check, and the queued "table display names" item amended from bilingual to English-only?
➡️ **Yes.** It follows your English-only ruling. The i18n check would otherwise demand a Chinese copy of every trail string.

❓ **Q8 — Chinese text in data.** Show text people typed (reasons, notes, names) as written, even when it's Chinese, and replace machine-written Chinese stored in the database with English?
➡️ **Yes.** The machine-written cases are automatic-approval notes, the batch stage values (待加工 / 加工中 / 已加工完) and output batch states. What a person typed is their own words; what the system wrote is the system's language.

❓ **Q9 — The event wordings.** Confirm the §4 table and the full catalogue (233 events, 196 of them new wording) in `events.md` §5.
➡️ **Confirm the §4 table now.** I'll list every other wording in the build handback for you to spot-check.

❓ **Q10 — Processing events.** Re-map your running → completed example to what the system records:
- "Processing completed" = the run recorded;
- "Processing started on this batch" = the first partial use of the batch;
- "Processing rolled back";
- no "Weighed" event: receipt reads "Goods received · 405 kg", and a weighbridge upload reads "Weighbridge ticket attached".

➡️ **Yes.**

❓ **Q11 — Field labels.** Use the page's own label first, then similar wording from `en.ts`, then the labels proposed in `labels.csv` (890 of them)?
➡️ **Yes.** You review the proposed labels in the build handback.

❓ **Q12 — What never shows.** Never show created/updated stamps, technical columns (ids, sequence, hashes) or raw JSON. JSON columns show through a dedicated renderer, or as "Details changed".
➡️ **Yes.**

❓ **Q13 — Deleted referenced records.** "PO-… (since deleted)", or "a supplier that has since been deleted" when the number can't be recovered.
➡️ **Yes.**

❓ **Q14 — Person names.** Use preferred name, else legal name, everywhere, including the summary page (which shows email + employee code today).
➡️ **Yes.** The repo currently has three different styles.

❓ **Q15 — Times in trails.** `DD/MM/YYYY HH:MM`, Singapore time, in trails, on the summary page and on `/settings/deleted`. This replaces your DATE-1 ruling D2 for these screens.
➡️ **Yes.**

❓ **Q16 — Every other date shown on screen.** DATE-1 made them "01 Sep 2026" / "2026年9月1日". Should screens also switch to DD/MM/YYYY in both languages, with PDFs and documents keeping "01 Sep 2026"?
➡️ **Yes.** It is one formatter change, and it stops a single page showing two date shapes, which was your original complaint.

**System writes**

❓ **Q17 — Actor wording.**
- "System (automatic)" for every write with no login;
- no special wording for smoke-test writes;
- "Removed account" when neither an account nor a person is left;
- disabled accounts show the plain name.

➡️ **Yes.**

❓ **Q18 — Migrations.** Should migrations also read "System (automatic)", or "System (maintenance)"?
➡️ **"System (automatic)"**, as you ruled; there has been one migration row group per cut.

❓ **Q19 — Trails that would only be noise.** Leave the COD verification counter, notification reads and avatar changes out of every page trail? The summary page still lists the COD counter.
➡️ **Yes.**

**Pages**

❓ **Q20 — The host list.** Approve the 87 host routes in §2/§3, including the list pages that host records with no page of their own.
➡️ **Yes.**

❓ **Q21 — Records that lose their page.** A reversed run, a written-off batch, a deleted formula, material, customer or supplier currently hides its page.
➡️ **Keep such pages openable read-only, with a banner** ("Reversed on DD/MM/YYYY by …") and the trail:
- records ended by a business event (reversal, write-off): for the page's normal readers;
- plain deletions of master data: for holders of `data.view_deleted`.

❓ **Q22 — Equipment.** Its only page is `/finance/assets/[id]` (finance access), but servicing and downtime are processing operations.
➡️ **Add a read-only `/operation/equipment/[id]`** (processing access) with the equipment's trail, in part 2.

❓ **Q23 — Shift handovers.** There is no detail page today.
➡️ **Add `/operation/handovers/[id]` in part 2.** The lighter alternative is a trail per row on the list page.

❓ **Q24 — Accounts.** A per-account trail on `/settings/accounts` (an expandable row), mirrored on the linked employee's page?
➡️ **Yes.**

❓ **Q25 — Shared settings row.** The period lock, GST settings and approval policy share one row. Should each panel show only its own fields' history, and the lock's trail also show month close and reopen?
➡️ **Yes.**

❓ **Q26 — Existing history sections.** Replace the pure change histories with the unified trail, and keep sections that are working lists:
- replace: PO amendment history (currently mid-page, and shows no person), sales-order and quote history, work-order history, the asset history panel, the task change history, the batch Audit Trail;
- keep: settlement history tables, request panels, close-history tables, employment history on the employee page and `/me`.

➡️ **Yes.**

❓ **Q27 — The layout.** Approve the layout and mock-ups in §6.
➡️ **Approve.**

❓ **Q28 — A "key events only" toggle on page trails?**
➡️ **No.** Field details are already collapsed; the summary page does get this toggle (Q30).

❓ **Q29 — Paging.** 20 entries, then "Show older entries".
➡️ **Yes.**

❓ **Q30 — Summary page.** Approve the filters and columns in §7(i).
➡️ **Yes.**

❓ **Q31 — Everything on the summary page.** It keeps listing every write, including system and smoke writes.
➡️ **Yes.** It is the complete record.

**Batch trail**

❓ **Q32 — Old batch trail views.** Keep the two database views unused in this cut, port fixtures 181–183's intent to new fixtures, and drop the views in a later cleanup cut?
➡️ **Yes.** Dropping them now would break the batch pages until the deploy lands.

❓ **Q33 — Batch trail contents.** Keep all 20 kinds and add the missing ones: assays, metal content, safety states, requests, COD issues, pre-post stocktake counts.
➡️ **Yes.**

**Defects found along the way**

❓ **Q34 — What to do with them.**
1. `setDeepDischargeJudgement` does a direct update that APR-10's guard refuses; 0 of 11 PO lines have a judgement.
2. `withdraw_payment_request` has no check that the person withdrawing is the requester; the other 5 withdraw functions have one.
3. The approvals comment in `lib/modules.ts:843` is false.
4. `equipment_id` is never passed when a run is recorded (0 of 14 runs).
5. Three actions have no UI caller.
6. Closing or reopening a PO writes its reason into Notes.

➡️ **Register all six in `docs/known-issues.md`.** Fix only the comment (item 3) in this cut; the others are separate decisions.

**Dates**

❓ **Q35 — The picker itself.** One in-house picker on Radix Popover, no new library, typing and picking, Monday start, DD/MM/YYYY in both languages, posting ISO dates.
➡️ **Yes.**

❓ **Q36 — Month and date-and-time inputs.** Should the 5 month inputs (shown MM/YYYY) and the 4 date-and-time inputs (`DD/MM/YYYY HH:MM`) also move to the picker?
➡️ **Yes.** The date-and-time inputs move from the browser's time zone to Singapore time.

❓ **Q37 — Typing rules.** Accept D/M/YYYY, DD/MM/YY, DDMMYYYY and pasted ISO. An impossible date (31/02) shows a message and blocks the submit. Days outside min/max are disabled, with the reason shown.
➡️ **Yes.**

❓ **Q38 — The date check.** "Zero native date inputs anywhere", counted two independent ways, with `check-date-data-paths.mjs` re-aimed at the picker. Fault-inject both.
➡️ **Yes.**

❓ **Q39 — Chinese interface.** Calendar month and weekday names in Chinese when the interface is Chinese; the typed format stays DD/MM/YYYY.
➡️ **Yes.**

**Mechanics and delivery**

❓ **Q40 — Where wording lives.** The database resolves ids to document numbers, names, labels and "Restricted". The app writes the English sentences, using the shared date and money formatters.
➡️ **Yes.** Currency and date formatting already live in the app.

❓ **Q41 — The machine-token check.**
- A build-time check runs the trail wording over every registered subject, column and event with sample values.
- A smoke assertion checks real trail pages.
- Both fail on a uuid, a column or table name, a raw code, JSON, "null" or a database role name; "Restricted" is allowed.
- Both get fault-injected.

➡️ **Yes.**

❓ **Q42 — The migration.** Additive only (§7 m), with nothing broken in the window.
➡️ **Yes.**

❓ **Q43 — The split and version numbers.** Approve the 5-part split in §8, in the order AT-1a → AT-1b → AT-1c → AT-1d → DATE-PICK-1 (or DATE-PICK first if you'd rather), each part with its own version starting at v1.4.33. Each part's tester line then describes that part rather than the whole.
➡️ **Approve the split, trails first**, since the trails are what you rejected.

---

**Stopped at the gate.** I'm waiting on your answers to Q1–Q43 before any edit or migration.
---

## Tim's answers, 2026-09-29: all Q1–Q43 accepted as recommended; split approved in the order above

Every recommendation Q1–Q43 is accepted exactly as stated, and the scope changes in §1 (items 1–11) are accepted. The 5-part split is approved in the order AT-1a → AT-1b → AT-1c → AT-1d → DATE-PICK-1, each part with its own version number starting at v1.4.33 for AT-1a.
