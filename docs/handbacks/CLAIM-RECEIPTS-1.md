v1.4.65 — Receipts on expense claims: an employee (or whoever submitted the claim for them) attaches a receipt to each item of a claim — PDF, JPEG or PNG up to 10 MB, a photo straight from the phone camera shrunk before it is sent — while the claim is waiting; each item needs its own receipt or its own no-receipt reason before it can be approved; finance opens the receipts on the claims page and on the expense the approved claim becomes; once decided, the receipts stay as the record.

# CLAIM-RECEIPTS-1 — hand-back (2026-10-21) · a receipt on each claim item

The brief "CLAIM-RECEIPTS-1" with Tim's rulings on Step 0 (Q1–Q14), 2026-10-21. Part 1 closed EXPENSE-MULTILINE-1 (`docs/handbacks/EXPENSE-MULTILINE-1.md` §5).
Started from `7636a66ca0c1079fcc8741b74962b10b409dcb68` (HEAD = origin/main = ls-remote, tree clean).
Survey: `docs/surveys/CLAIM-RECEIPTS-1/step0-survey.md`. Readings: `docs/surveys/CLAIM-RECEIPTS-1/readings/`.

## 1 · What changed, against each ruling

| Ruling | What | Proof |
|---|---|---|
| Q1 limits | `claim_receipt_begin` refuses by name before any byte is stored: type not PDF / JPEG / PNG (HEIC, Word, Excel included) · empty · over 10 MB · no name. The numbers are **the portal's own V39 columns** (`account_settings.portal_upload_max_bytes` / `portal_upload_types`) — "the same as the portal" is literally one figure; the bootstrap value is still correct. New private bucket `claim-receipts` with the same 10 MB · PDF / JPEG / PNG on the bucket itself. | fixture 287 A; live proof T2 |
| Q2 phone | A plain `<input type="file" multiple accept=…>` (PDF, JPEG, PNG, HEIC) — no `capture`, so the phone offers Take Photo · Photo Library · Files. | Tim's iPhone walk (§4) |
| Q3 shrink | `app/me/uploadClaimReceipt.ts` `prepareReceipt`: every image is drawn into a canvas whose longest side is ≤ 2,000 px and saved as JPEG (quality 0.85, white background for transparent PNGs); a HEIC Safari can decode becomes JPEG; one it cannot decode is refused with a sentence saying what to do. PDFs go as they are. | not measurable here (no browser) — Tim's iPhone walk |
| Q4 who uploads | Only the employee the claim is for, or its submitter (`expense_claims.created_by`), only while the claim is `submitted` (`CLAIM_RECEIPT_NOT_YOURS` / `CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED`). The storage INSERT policy admits only the caller's **own** `uploading` row's path, registered in the last ten minutes, while the claim is still submitted and the caller is still one of its people (`claim_receipt_can_upload`). The submitter-cannot-approve rule is unchanged. | fixture 287 A · B; live proof T2 · T3 |
| Q5 add / remove | While submitted the claim's people add files or remove one (`claim_receipt_remove`): the row becomes `removed` with who and when, it disappears from the claim and stops counting as evidence; **the object stays in the bucket** — `claim-receipts` has no UPDATE and no DELETE policy. | fixture 287 B · E |
| Q6 after the decision | Approved / rejected / withdrawn: nothing can be added or removed; the employee and the submitter keep reading their claim's attached receipts; every `module.finance.view` holder reads all (rows and objects, removed ones included). | fixture 287 D · G; live proof T6 |
| Q7 who reads | `module.finance.view` (admin · cco · cfo · cto · finance · gm today) — no new code. | fixture 287 D; live proof T4 |
| Q8 on the expense | The expense detail page of an approved claim's expense shows "Receipts from claim CLM-…", item by item, read in place from the claim (no copy). | live proof H3; layout survey |
| Q9 several files | No count cap; each file is judged on its own. | fixture 287 C (two on item 1) |
| Q10 900 MB | `claim_receipt_begin` sums every stored object's size (all buckets); at 900 MB (943,718,400 bytes) new receipts are refused, `CLAIM_RECEIPT_STORAGE_FULL`, the sentence names used / limit in MB. The number lives in that function on purpose (it ends at the paid plan). | fixture 287 A |
| Q11 resubmission | A resubmitted claim is a new claim; nothing carries receipts over. | by construction (receipts hang on items) |
| Q12 the form | Each item on `/me` has its own file picker; Submit is pressable only when every item has a file or a no-receipt reason; after the claim is created (`submit_expense_claim_items` now returns each item's id) the files upload one by one; failures are named in an amber notice and can be retried from the item in the table. The database still checks at approval. | local proof L1; build |
| Q13 claim-wide route | `finance_attachments.claim_id` dropped (0 rows on live), its index, its trail label; the one-parent CHECK has four parents; `expense_claim_status.has_receipt` dropped (it was one boolean for a whole claim); `decide_expense_claim_items` judges evidence per item from `expense_claim_receipts` (`attached` only). | fixture 287 F · I; fixtures 140 / 286 moved; migration self-proof |
| Q14 portal limit | Measured on production (§3), registered `PORTAL-UPLOAD-CAPPED-BY-VERCEL-4-5-MB`, go-live readiness group row 9. Not fixed. | `readings/q14-portal-upload-limit.txt` |
| Tim's three | No notification · a 60-second signed link to open · receipts in the claim's trail (`expense_claim` and `my_expense_claim` subjects; "Receipt attached · Item n · file"). | check-trail-wording ⑩ |

**Where MES-9c's design did not fit, and what replaced it:** the bytes do not go through a Next route. Vercel refuses a function request body above about 4.5 MB
(measured, §3), and a phone photo can be bigger than that before shrinking. So the browser uploads straight to Storage under the registered-path policy (the
finance-attachments pattern), and the file-type check moved from the route into the *finish* step: `finishReceipt` reads the stored object's first 16 bytes
(a 60-second signed link, `Range: bytes=0-15`) and abandons the receipt if they are not PDF / JPEG / PNG or not the declared type. begin / judge / finish /
abandon are MES-9c's shape unchanged.

## 2 · Verify chain (every exit read from the script's own line)

| # | Step | Result |
|---|---|---|
| 1 | offline gate | `GATE_EXIT=0` (124 s, third run; `readings/gate-offline.txt`). Run 1 red on B2: four new owner-rights functions had no caller check the gate recognises — finish / abandon / can_upload now re-check that the caller is still one of the claim's people (`current_user_employee()` / `created_by`); `claim_receipt_limits` allowlisted with its reason in both lists (`db/verify_rebuild.py`, `db/check_mirrors.py`). Run 2 green (128 s); run 3 after a fixture change, green. |
| 1b | fixture fault injections | **23 / 23** bite, `INJ_OWN_EXIT=0` (`readings/fixture-injections.txt`, `db/scripts/2026-10-21-claim-receipts-1-fixture-injections.py`). The first run was 21 / 23 and both misses were mine: (a) "the upload judge ignores who registered the path" did not bite — fixture 287 never tried the claim's *other* person on a path the first one registered; an assertion was added (the employee cannot upload into the path the submitter registered); (b) the 140 cell did bite (the fixture errors by name) and my expected line was wrong. |
| 2 | backup | `BACKUP_EXIT=0` — `evoltrya-backup-2026-10-21-2127.dump` (main dump 1,774 s, TOC 9,825, previous 9,782) + 17 change_log chunks, 75,425 rows = count, first / last seq 1 / 82,847; 21:27:36 → 22:06 CST |
| 3 | live dry run COMMIT→ROLLBACK | `DRY_OWN_EXIT=0` — inside: 328 tables, receipts table (0 rows), 7 receipt functions, authenticated executes / anon does not, `claim_id` gone, `has_receipt` gone, 58 storage policies, 21 buckets, `claim-receipts` 10485760 · PDF / JPEG / PNG, 40 objects, exclusions 9, gaps []; after rollback 327 / no table / `claim_id` back / 56 / 20 / 40 |
| 4 | apply | `APPLY_OWN_EXIT=0`; pre-flight 12 functions (3 replaced · 9 new), no account codes; **broken window start 2026-10-21 22:14:40 CST** (`db/migration-windows.tsv`) |
| 5 | types | `TYPES_OWN_EXIT=0` (after `NOTIFY pgrst` and 20 s — a column was dropped) |
| 6 | tsc | `TSC_OWN_EXIT=0` |
| 7 | build | `BUILD_OWN_EXIT=0`, third attempt. First red: `check-auth-error-swallowing` caught my `auth.getUser()` on `/finance/claims` dropping its error — now read, and on an auth error the page does not guess the submitter (no upload box; the database still judges). Second red (exit 2): `check-document-registry`'s pinned table count 327 → 328 (one real new table; the pin moved with its note). |
| 8 | full gate | `GATE_EXIT=0` (867 s), first run: rebuild · mirrors vs live (incl. generated types) · all fixtures (287 ✓) · live fixture 266 ✓ · anon (327) · no-role (126; storage mirror 21 buckets · 58 policies = live) · portal (42) |
| 9 | i18n | `I18N_OWN_EXIT=0` |
| 10 | error-swallowing | `SWALLOW_OWN_EXIT=0` |
| 11 | layout survey, 3 touched pages | 390 px: 3 / 3 usable, 0 overflow, 0 clipped; 1280 px: 3 / 3, 0, 0; self-test passed (`/me`, `/finance/claims`, the EXP-2026-0007 detail) |
| 12 | smoke | **`SMOKE_EXIT=1`** — 303 ok · 25 skipped (no data) · **1 failed: `/settings/dictionaries` HTTP 500**, `用量查询失败(materials): ` with an empty error message, in a slow run (278 timed routes 1,972 s). Not a page this cut touched. Re-measured on this cut's `next start` against live as an admin copy: **200 · 200 · 200 in 30.2 / 45.6 / 39.1 s** (`readings/smoke-dictionaries-recheck.txt`). Registered `SETTINGS-DICTIONARIES-30-SECOND-LOAD`. The smoke exit is reported as it was, not re-run into green. |
| 13 | live proof | `CR1_PROOF_EXIT=0`, first run (`PROOF_BASE` = `next start` on this commit, against live): H1–H5 over HTTP; T1–T6 inside one rolled-back transaction with real session claims (the platform's own `storage.can_insert_object` admits the registered path, refuses others). **Storage objects counted as postgres: claim-receipts 0 → 0, all buckets 40 → 40 — no byte uploaded.** Claim / expense numbers are gapless counters, rolled back with the transaction. |
| 14 | local-rebuild upload proof | `CR1_LOCAL_PROOF_EXIT=0` (`db/scripts/2026-10-21-claim-receipts-1-local-upload-proof.mjs`): the unchanged `submitClaim` / `decideClaim`, `claimReceiptActions` and `uploadReceipt` against a local rebuild with real storage RLS and bytes on disk — PDF attached · a GIF sent as JPEG refused by its first bytes and left abandoned (bytes stay) · another employee refused · PNG attached · remove hides it from the claimant, finance still opens it · approval refused on the item whose receipt was removed, approved once re-attached · nothing attachable after approval · the claimant opens the PNG afterwards, byte-identical. |
| 15 | fresh clone, no `.env.local`: `npm ci && npm run build` | in the close report (it builds the commit that contains this file) |

**Read back as postgres after every live step** (`readings/readback.txt`): approvals ON (finance / cfo / 1,000); 7 real accounts, 0 disabled, roles admin ·
finance · warehouse · cto · cco · cfo · gm unchanged; throwaway users 0 · roles 0 · employees 0 · orphan grants 0; both CODs (`ba299a4f…`, `717661f6…`)
unchanged; `require_calibrated_since` NULL; receipts 0, claim-receipts objects 0, all objects 40; `portal-uploads` bucket and its 3 policies untouched;
reconciliation (as tim@) AP 0.00 · AR 0.00 unexplained.

**Broken window — what is broken in it (derived):** the old app reads `expense_claim_status` with `select('*')`, so the dropped `has_receipt` is simply
undefined — every item shows "No receipt" (true: 0 receipts on live). The old approval panel calls `decide_expense_claim_items` (signature unchanged), whose
evidence rule now reads receipts per item — with 0 receipts the answer is the same as before (the reason or nothing). No old query references a dropped column
by name. The end of the window is Tim's reading on Vercel.

## 3 · Q14 — the portal upload limit on production

`db/scripts/2026-10-21-claim-receipts-1-q14-portal-upload-limit.mjs` → `readings/q14-portal-upload-limit.txt`, **`Q14_EXIT=0`**, 2026-10-21 ~21:30 CST, against
`https://new-era-erp.vercel.app`, one throwaway supplier + portal account (removed; read back 0). Every file was deliberately unrecognisable bytes, so each request
that reached the app was refused by `portal_submission_begin` (`PORTAL_UPLOAD_TYPE_NOT_ACCEPTED`) before anything was registered: portal submissions 0 → 0,
`portal-uploads` objects 0 → 0.

| file | request body | answer |
|---|---|---|
| 1 · 2 · 3 · 4 · 4.25 MB | … | 303 → `PORTAL_UPLOAD_TYPE_NOT_ACCEPTED` (reached the app) |
| **4,489,216 B (4.281 MB)** | **4,489,496 B** | **303 → reached the app — the largest accepted** |
| **4,505,600 B (4.297 MB)** | **4,505,880 B** | **413 `FUNCTION_PAYLOAD_TOO_LARGE` from Vercel — the first refused** |
| 4.313 · 4.375 · 4.5 MB | … | 413 |

So the platform cap sits between request bodies of 4,489,496 and 4,505,880 bytes (bisected to 16 KB) — consistent with Vercel's documented 4.5 MB. The portal page
promises 10 MB. Registered `docs/known-issues.md` § PORTAL-UPLOAD-CAPPED-BY-VERCEL-4-5-MB; the fix is go-live readiness group row 9 (before the first real supplier).

## 4 · Not measured, handed to Tim

- **The only real end-to-end upload** — the live proof cannot commit a claim, so no real bytes went through the Storage API into a real claim. Tim's iPhone walk:
  `docs/manual-walk-list.md` §34 (camera photo + a PDF from Files, both opened by finance on `/finance/claims` and on the approved expense).
- The photo shrinking (canvas) runs only in a browser; nothing here executed it.
- **Layout of the open claim form with file pickers at 390 px** — the survey measures first render; the form opens on a click and needs an employee profile.
  The pickers are `max-w-full` inside wrapping rows (the same construction as the other fields there). Part of §34's walk.

## 5 · Decisions taken without asking

1. **The receipt limits are the portal's V39 columns themselves**, not a copy — "the same as the portal" (Q1) as one number; changing V39 changes both (noted at the column).
2. **New bucket `claim-receipts`** (not `finance-attachments`): its own limits on the bucket, and its own read rule (finance, or the claim's own people).
3. **New table `expense_claim_receipts`**, not a sixth parent on `finance_attachments` — the upload needs a state (`uploading → attached | abandoned`, `removed`) that
   the shared attachments table does not have, and its write policies are `module.finance.edit`.
4. **Bytes straight from the browser; the type sniff in finish** (§1, and §3 is why).
5. **"The uploader may remove" (Q5) read as Q4's two people** (the employee and the submitter), not only the person who uploaded that one file.
6. **Every image is re-encoded to JPEG ≤ 2,000 px** (PNG screenshots too), white behind transparency.
7. **A removed receipt is still readable by finance** (the object stays; it is part of the record) but not by the claimant (it is hidden from the claim).
8. **The 900 MB figure lives in `claim_receipt_begin`**, not in a settings table — it ends at the paid plan (Q10's own words).
9. **`submit_expense_claim_items` returns each item's id** (same signature, a longer reply) so the form can upload right after submitting.
10. **The decided register on `/finance/claims` gets a "Receipts" column**, so receipts of rejected and withdrawn claims stay reachable (Q6).
11. **The submitter's upload box lives on `/finance/claims`** (that is where a finance submitter sees the claim); if `auth.getUser()` errors, it is not drawn.
12. **Opening a receipt opens a blank tab first, then points it at the signed link**, because phone browsers allow only windows opened in the tap itself.
13. **Removing a receipt has no confirmation dialog** — the record is kept and finance still sees it; nothing is destroyed.
14. **A new throwaway prefix `cr1probe`** in `scripts/ephemeral.mjs` (sweeps recognise it).
15. **Fixture number 287.**
