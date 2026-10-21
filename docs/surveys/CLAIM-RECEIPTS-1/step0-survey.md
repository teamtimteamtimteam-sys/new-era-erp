# CLAIM-RECEIPTS-1 — Step 0 survey (2026-10-21)

Started from `7636a66ca0c1079fcc8741b74962b10b409dcb68` (HEAD = origin/main = `git ls-remote origin main`, tree clean).
Read directly; no browser sweep, no route census. Live numbers read as `postgres` (`rolbypassrls = t`) on base tables, 2026-10-21 10:19 SGT —
`readings/step0-live-readings.txt`.

## 1 · What the claim side looks like after EXPENSE-MULTILINE-1

| Fact | Where |
|---|---|
| A claim = header `expense_claims` + items `expense_claim_items` (date · receipt amount · description · `no_receipt_reason` · account / tax set once at approval). Items are immutable after submit: every column except the one-time account / tax write raises `EXPENSE_CLAIM_ITEM_IMMUTABLE`; rows cannot be deleted. So **`no_receipt_reason` cannot be added after submit.** | `db/tables/expense_claim_items.sql` (trigger `guard_expense_claim_item_mutation`) |
| Item read rule: `module.finance.view` OR the claim is about you (`current_user_employee()`). No write policy; writes only through owner-rights functions. | same file, policy `expense_claim_items select by permission` |
| Submit: the employee themself **or anyone holding `module.finance.view`** may submit for an employee (`created_by` = raiser). No check that an item has a receipt or a reason at submit. | `db/functions/submit_expense_claim_items.sql:36` |
| Withdraw: `module.finance.edit` or the employee, only while `submitted`. | `db/functions/withdraw_expense_claim.sql` |
| Approval evidence check is **claim-level** for the attachment arm: `v_has_att` = any non-deleted `finance_attachments` row with `claim_id`; then per item: `NOT v_has_att AND no reason` → `EXPENSE_CLAIM_NO_EVIDENCE|code|line`. | `db/functions/decide_expense_claim_items.sql:162`, `:191` |
| `expense_claim_status.has_receipt` is also claim-level (same `finance_attachments.claim_id` test). Both screens print it on every item. | `db/views/expense_claim_status.sql:77`; `app/me/MyExpenseClaimsPanel.tsx:127`; `app/finance/claims/ClaimDecisionPanel.tsx:165` |
| Approval creates one expense (`record_expense_document`), linked by `expense_claims.expense_id`. The expense detail page shows `FinanceAttachmentsPanel` for `expense_id` only. | `db/functions/decide_expense_claim_items.sql` (end); `app/finance/expenses/[id]/page.tsx:393` |
| Trail: `finance_attachments` via `claim_id` is already a member of both `expense_claim` and `my_expense_claim` subjects. | `db/functions/trail_subject_members.sql:380`, `:383` |
| Live: 4 claims (approved 1 · rejected 1 · submitted 1 = CLM-2026-0004 · withdrawn 1); 4 items, 1 with a reason; `finance_attachments` with `claim_id` = **0** (4 rows total, 1 on an expense). | readings |

## 2 · The attachment model

* `finance_attachments` — one row per file, exactly one parent of five (`sales_record_id · inbound_batch_id · payment_id · expense_id · claim_id`), soft delete,
  no status column. Read `module.finance.view`; insert / update / delete `module.finance.edit` (`db/tables/finance_attachments.sql:59-77`), plus the SILENT-1
  statement trigger.
* App type `FinanceAttachmentParent.kind` = `sale | inbound | payment | expense` — **no `claim`** (`app/components/finance/financeAttachmentTypes.ts:35`);
  allowed types include Word / Excel.
* Upload pattern: **the browser uploads straight to Storage** (`FinanceAttachmentsPanel.tsx:101`), then a server action records the row; a 60 s signed link to open
  (`financeAttachmentActions.ts:83`). The bytes never pass through Vercel.
* Bucket `finance-attachments`: private, **no size limit, no type list** (`db/storage/buckets-and-policies.sql:62`); policies read `finance.view`, upload `finance.edit`,
  delete-unrecorded `finance.edit` (`:174-188`).

## 3 · Storage today

* 20 buckets, 56 storage policies (live = mirror). **40 objects, 2,422 kB in total**; largest object 268 kB. Database 127 MB.
* Six buckets carry limits; `portal-uploads` = 10 MB · PDF / JPEG / PNG (MES-9c V39).
* **Every signed-in account already writes to storage:** `avatars` has four own-path policies (`name = auth.uid() || '.webp'`, `buckets-and-policies.sql:365-383`),
  used by `app/me/avatarActions.ts:188` with the user's own session (256 kB, WebP, re-encoded server-side).

## 4 · The MES-9c upload path, and where it fits

| MES-9c piece | Fits claims? |
|---|---|
| **begin** — the DB judges size / type limits **before any byte is stored**, registers one `uploading` row and its path | Yes, as is |
| **storage judge** `portal_can_upload_object(bucket, name)` — INSERT (and read-back SELECT) policy admits only the caller's own `uploading` path, registered in the last 10 minutes; never raises | Yes — same shape, keyed on `auth.uid()` and the claim being `submitted` |
| **finish** — object must exist; size and declared type must match the registered row → `PORTAL_UPLOAD_MISMATCH` | Yes |
| **abandon** on a failed upload | Yes |
| **bytes go through a Next Route Handler** (`request.formData()` → `arrayBuffer()`, `app/portal/certificates/upload/route.ts:65-71`), type sniffed from the first bytes there | **No.** On Vercel a function request body is capped (Vercel's published limit is 4.5 MB — **from Vercel's documentation, not measured on this deployment**); a phone photo is often 3–8 MB. A Server Action is capped at 1 MB by default (`node_modules/next/dist/docs/01-app/03-api-reference/05-config/01-next-config-js/serverActions.md:26`). Claims need the bytes to go **browser → Storage directly** (the finance-attachments pattern), with the sniff moved to *finish* (the server reads the stored object's first bytes). |
| **No delete policy** — leftover bytes of an abandoned upload stay (`MES9C-ABANDONED-UPLOAD-BYTES-STAY`) | Partly — see Q-grill |
| **Side finding:** if the Vercel limit is as documented, the **portal's own 10 MB promise fails above ~4.5 MB on production** — MES-9c's 10.2 MB refusal was proved against a local `next start`, not Vercel (`docs/handbacks/MES-9c.md` §7). Inferred, not measured. | Question for Tim |

## 5 · Who "finance" is, measured

`role_permissions` (as postgres): `module.finance.view` is held by **admin · cco · cfo · cto · finance · gm** (6 of the 7 real roles; not warehouse), and by
`auditor` (0 holders). `module.hr.view` is held by the same six. `data.view_prices` (needed to decide) by the same six. Approvals ON (`finance_settings.approvals_enabled = true`).
So "finance can read the receipts" via the existing gate = **everyone except warehouse**; an HR arm would add nobody today.

## 6 · Phone

No `capture=` attribute anywhere in `app/` (`grep -rn 'capture='` → 0). The weighbridge / discharge photo inputs are plain `<input type="file" accept=…>`
(`app/operation/weighbridge/[id]/TicketControls.tsx:181`). On iOS and Android a plain file input already offers *Take Photo · Photo Library · Files*;
`capture` would force the camera and remove the library and PDFs (platform behaviour from my knowledge, not measured here — Tim's iPhone walk is the measurement).

## 7 · Assertions in the brief I measured and found false (or narrower)

1. **"It gives employees write access to storage for the first time"** — false as written: every signed-in account already writes its own avatar
   (§3). True version: it is the first time an employee writes a **document that someone else reads and that is evidence for money**.
2. **"Finance can read the receipts"** — the gate the system calls finance (`module.finance.view`) is held by six of the seven real roles (§5).
3. **"Reuse the MES-9c design"** — the begin / judge / finish / abandon half fits; the bytes-through-a-route half does not (§4).
4. Brief numbers re-measured: offline gate 125 s and full gate 931 s ✓ (`docs/handbacks/EXPENSE-MULTILINE-1.md` §2); backup ≈ 30 min ✓ (22:01:50 → 22:32);
   **smoke ≈ 25 min — not re-measurable** from the readings (file times bound it at ≤ 45 min); V39 = 10 MB · PDF / JPEG / PNG ✓ (live bucket row);
   `known-wrong-until-cutover.md` CLM-2026-0004 line ✓ at 226.
