# MES-6b-2 close-out (2026-10-15) — step 1 of the "MES-6b-2 close-out + MES-7a Step 0" brief

Read-only. No database change and no code change: the only writes are docs and the files beside this one. The page probes below used
throwaway clones of real roles (`mintThrowaway { cloneOf }`, prefix `mes6b2probe`) — accounts, roles and grants created and removed by the
shared ephemeral plan, the convention every earlier close-out used; read back afterwards: **0 throwaway accounts, 0 probe roles**, every
change-log INSERT matched by a DELETE (roles 4 / 4 · user_roles 4 / 4 · role_permissions 187 / 187). No record that existed before was touched.

**Opening check.** First command **2026-10-15 22:22:17 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`1ca90256a1057f9761a35cd9a928777b067c583d`.

## 1 · Broken window closed

Recorded in `docs/forward-queue.md` item 50, in the MES-6b-1 format:
- start **2026-10-15 20:45:44 CST** (measured: `db/migration-windows.tsv`, `2026-10-15-mes6b2-certificate-of-analysis.sql`);
- end, lower bound **2026-10-15 22:11:53 CST** (measured: `git reflog show --date=iso refs/remotes/origin/main` →
  `1ca90256 refs/remotes/origin/main@{2026-10-15 22:11:53 +0800}: update by push`);
- end, upper bound **2026-10-15 22:22:17 CST** (derived: this session's first command, holding Tim's relayed "deployed" — a relay, not a
  measurement of Vercel).
- **Window: at least 1 h 26 min 09 s, at most 1 h 36 min 33 s.**
- In the window (read 22:36 CST as `postgres`, `mes6b2-window-readings.sql`, `READ_OWN_EXIT=0`): certificates 0 · byte records 0 · `coa_void`
  requests 0 · `coa-documents` objects 0 · warehouse requests created 0 · assays 0 · NCRs 0 · stock movements 0 · CODs issued 0. Change log in the
  window: only MES-6b-2's own smoke / survey / proof throwaways (roles 69 / 69 · user_roles 74 / 74 · role_permissions 1,891 / 1,891 · employees
  10 / 10 · reviews 4 / 4 + 4 updates · scratch contracts 4 / 4 with their term rows · one `cod_verification_failures` row in and out — smoke's
  404 probe). Nothing anyone used could have broken (derived: the old app reads none of the new objects; `warehouse_requests` gained a NULL column
  and a kind the old app never sees — MES-6b-2 hand-back §8).
- **Deployed app is the MES-6b-2 code** (measured, item b): every clone's output batch page on `https://new-era-erp.vercel.app` draws the
  certificate section (`data-section="coa"`), which exists only from `1ca90256`.

## 2 · Read-only verification

### a · The fixture list in the MES-6b-2 block, item by item

The block's list ("Fixtures must cover every item restated above, including: …"), each with what covers it. Fixture 264 =
`db/fixtures/264-a-certificate-of-analysis-states-the-governing-assay-and-is-voided-only-through-the-cfo.sql`.

| # | Item | Covered by |
|---|---|---|
| 1 | each issue refusal | 264 REFUSE `:360-426` — code (`:362-363`), no final assay (`:367-368`), quality hold (`:370-373`), open dispute (`:375-379`), weighing out of calibration (`:381-384`), rule on + unweighed leg (`:386-389`), breach decided `rework` (`:392-400`), order not for the batch (`:411-412`), not an employee (`:414-415`), no position (`:416-417`), company name (`:419-421`), nothing left behind (`:424-426`); already issued in ISSUE `:466-471` |
| 2 | governing assay, three cases | 264 GOV `:293-340` — no order → our latest (`:299-300`), deleted never governs (`:301-303`), contract settles on the counterparty (`:331-332`), order without contract → ours (`:333-334`), resolved dispute governs (`:336-340`) |
| 3 | `is_final` required | 264 GOV `:341-347` (a newer preliminary result refuses by name; no reach-back) |
| 4 | `output_batch_metals` never read | 264 NEVER `:350-357` |
| 5 | one live CoA per batch × sales order | 264 ISSUE `:466-477` |
| 6 | sales-order section: limits, judgement, customer | 264 ISSUE `:452-465` |
| 7 | N38 ordering and gating | 264 N38 `:254-291` |
| 8 | snapshot frozen · PDF from snapshot · hash stored and re-checked, 409 | frozen: 264 FROZEN `:479-509`; hash stored: 264 BYTES `:511-528`. **PDF from snapshot and the 409 are route behaviour (TypeScript) — no SQL fixture can reach them**: `app/output/[id]/coa/pdf/route.tsx:56-57` (409), `:97-102` (renders the snapshot `issue_coa` returned, no re-read); proved once on live by `db/scripts/2026-10-15-mes6b2-live-proof.mjs:182-196` (render from snapshot, pypdf text = snapshot) and `:573-583` (tamper → sha mismatch), `MES6B2_PROOF_EXIT=0`. ★ weaker spot, recorded below (W1) |
| 9 | void only through the CFO request; snapshot and bytes kept; replacement linked | 264 VOID `:530-605` |
| 10 | `coa_facts_changed` appearing and clearing | 264 ARM `:607-628`; fixture 111 `:64` (the 66th arm) |
| 11 | `action.issue_coa` grants and action-implies-view | declared views 264 REG `:217-219`; action-implies-view for every role 264 REG `:248-252`. The grant to **cco** is not pinned by a fixture (the bootstrap gives admin every code, `db/tables/role_permissions.sql:69-71`, and no other role this code — the same as `action.ncr_decide`); it is pinned by the migration's in-transaction proof ("grants exactly admin + cco", MES-6b-2 hand-back §3 row 4) and measured live today (`HOLDERS|action.issue_coa=admin,cco`). ★ weaker spot W2 |
| 12 | F6's four part-only faults | `scripts/check-trail-wording.mjs:5814-5821` (`partFault` / `partFaultBit`), used by ㉓ `:5891,5905` · ㉔ `:6012,6026` · ㉕ `:6148,6162` · ㉖ `:6353,6367`; injection run: each fault reddens only its own arm (hand-back §3) |
| 13 | trail and wording arm ㉙ | 264 REG `:232-243`, TRAIL `:630-645`; `check-trail-wording.mjs:6692-6815` (drift fault `:6698`, part fault `:6800,6815`) |
| 14 | registry with COA | 264 REG `:220-222`; fixture 100 `:106,148,177` (`coa` → `COA`, `seq_year`, `next_coa_code`) |
| 15 | change-log exclusions at 8 | 264 REG `:223-225` |

Nothing on the list is uncovered. Two weaker spots, **recorded, not missing, not fixed**:
- **W1** — the 409 branch and "rendered from the snapshot" have no *repeatable* check: they were proved once on live (the proof script is in the
  repo but is a one-off, rolled back), and the hand-back's "local test" was a manual run that was never committed. This close-out's local probe
  (`mes6b2-closeout-local.mjs`, below) now exercises the issue route and the stored-bytes download for four roles, but not the 409.
- **W2** — as in item 11: the cco grant is a live grant, asserted by the migration and today's reading, not by a fixture on the rebuild.
- **Documentation gap (does not stop step 2)**: `docs/handbacks/MES-6b-2.md` §3 row 14 says the fresh-clone build is "see the final report"; the
  result exists only in that session's chat (`CI_OWN_EXIT=0`, `X_OWN_EXIT=0`, no `.env.local`). Recorded in `docs/forward-queue.md` item 50.

### b · Usability as clones of cco, warehouse, cfo and admin

**Deployed app** (`mes6b2-closeout-pages.mjs`, GET only, `PAGES_PROBE_EXIT=0`, 22:3x CST; clones = exactly each role's live codes: cco 46 ·
warehouse 29 · cfo 33 · admin 79). Live has 0 output assays, so the batch shown is OUT-2026-0380 (newest live output batch):

| Clone | `/output/[id]/edit` | `/quality/coa` | `/inventory` | `/output/[id]/coa/pdf` (preview) |
|---|---|---|---|---|
| cco | 200 · section drawn · "Feed chemistry: Not recorded (1 feed batches …)" · issue button present, **pressable** (no gate) · refusal shown before pressing: "Batch OUT-2026-0380 has no final governing assay to state …" | 200 · "Certificates of analysis" · empty | 200 · no request (live has none) | 200 PDF (18,065 B, preview watermark) |
| warehouse | 200 · section drawn · same chemistry and refusal · issue button **disabled, names `action.issue_coa`** | 200 | 200 | 200 PDF |
| cfo | 200 · same · issue button **disabled, names `action.issue_coa`** | 200 | 200 | 200 PDF |
| admin | 200 · same · issue button pressable | 200 | 200 | 200 PDF |

16 fetches, all 200, no application error.

**Local rebuild with an output batch and final assay of my own** (`mes6b2-closeout-local.mjs` + `-local-seed.sql` + `-local-clones.sql`; a
throwaway local cluster rebuilt from the mirrors at `1ca90256`, `REBUILD_OWN_EXIT=0`; PostgREST 16.4 and a stub gateway in the scratchpad;
`next dev` of this tree; clones carry the four roles' live codes and an employee with a position; approvals on with level 2 = the cfo clone's role;
`LOCALCLOSEOUT_EXIT=0`). Batch OUT-2026-0005 was made from three inbound batches (single, mixed, single) with a final assay:

| Step | cco | warehouse | cfo | admin |
|---|---|---|---|---|
| batch page before issue | 200 · "Feed chemistry: Known to be mixed (3 feed batches: 2 single and known, 1 known to be mixed …)" · no refusal · button pressable | 200 · same · button disabled, names `action.issue_coa` | 200 · same · disabled, names it | 200 · same · pressable |
| **issue through the route** (`POST /output/[id]/coa/pdf`) | **200 → COA-2026-0001** | **400** "This step did not happen, because it needs the "action.issue_coa" permission …", certificates still 0 | — | **200 → COA-2026-0002** (second batch) |
| stored PDF (`?coa=COA-2026-0001`) | 200 · paper says "Issued by Clone cco, Chief Commercial Officer" and "Feed chemistry Mixed (known to be mixed)" | 200 · same bytes | 200 | 200 |
| batch page after issue | 200 · COA-2026-0001 listed · refusal now "Certificate COA-2026-0001 is already issued for this batch and order …" | 200 · same · disabled | 200 · same | 200 · same |
| `/quality/coa` | 200 · both certificates | 200 · both · void control names `action.issue_coa` | 200 · both · names it | 200 · both |
| `/quality/coa/[id]` | 200 · "Issued: … · Clone cco, Chief Commercial Officer" · Download · Request void | 200 · Request void disabled, names `action.issue_coa` | 200 · same | 200 · Request void |
| coa_void raised by cco on COA-2026-0002 (`submit_coa_void_request`, the RPC the detail page calls) | 200 → "COA-2026-0002 · void #1", submitted | | | |
| `/inventory` CFO request list | 200 · "A certificate of analysis void is waiting for the CFO" · COA-2026-0002 · Approve · Withdraw | 200 · listed · Approve **disabled, names `module.finance.view`**; Withdraw names `action.issue_coa` | 200 · **listed; Approve pressable** | 200 · listed |

Everything each role's codes allow renders; everything they do not is shown disabled with the code named. Nothing missing or not working.

### c · MES6B2-ISSUED-WITHOUT-BYTES — who can issue today, and whether their paper renders

Read 22:28:32 CST as `postgres` (`closeout-readings.sql`, `READ_OWN_EXIT=0`): every account holding `action.issue_coa` through an unrevoked role,
resolved the way `issue_coa` resolves the issuer (`account_person`; name = preferred else legal; position = `positions.title`,
`db/functions/issue_coa.sql:44-47`). Glyph check with the repo's own guard (`lib/pdfFontCoverage.ts` `findUnrenderableText`, stack
**Google Sans (latin) + Noto Sans SC (cjk)**, 7,290 code points), run on the name, the position and the printed line; control «Lim ≤» →
unrenderable `≤` (the guard can say no):

| Account | Role | Employee | Name on the paper | Position | Renders |
|---|---|---|---|---|---|
| admin@swm-os.test | admin | EMP-2026-0002 | Tim | Chief Financial Officer | yes — 0 unrenderable |
| sandra@evoltrya.test | cco | EMP-2026-0004 | Sandra | Chief Commercial Officer | yes — 0 unrenderable |

Both live issuers render today; the residual stays a residual (it bites only when a holder's name or position carries a character outside the stack).

### d · Self-taken decisions in `docs/handbacks/MES-6b-2.md` §6 (titles)

1 Column-grant check batched · 2 N38 with no inbound leaves reads "not recorded" over 0 leaves · 3 N38 has an ungated base view under the gated
one · 4 The governing assay must be the latest one and final — no fallback · 5 An order whose contract names no settling party is governed by our
latest result · 6 The certificate's judgement is the recorded one · 7 The named order must have reserved or shipped the batch · 8 Issuer name =
preferred else legal; a position is required · 9 A void request touches only the certificate · 10 `/quality/coa` sits in the quality menu and needs
both views · 11 The inbound-batch trail reaches certificates one run deep · 12 A reissue links the latest unreplaced void certificate · 13 Bucket
delete policy only for objects not yet recorded · 14 Pre-issue font check in the route · 15 "Rendered from the snapshot" is proved by text, not
bytes · 16 The PDF route file is `route.tsx`, which smoke does not walk · 17 Wording arm ㉙'s six sentences · 18 Every PDF section is kept whole
across a page break · 19 The live proof drives one open transaction from Node · 20 Smoke prefix and skips · 21 Smoke's NCR id query ordered by
`opened_at` · 22 Fixture 264's assertions made null-safe.

## 3 · Verdict

a and b show nothing missing or not working; W1 / W2 are weaker spots and the fresh-clone line is a documentation gap — all recorded, none fixed
(step 1.4). c: both live issuers render. **Step 2 (MES-7a Step 0) goes ahead.**

## Standing state re-measured (22:28:32 and 22:36:14 CST, `postgres`, read only)

Approvals ON (finance / cfo / 1,000) · 7 accounts, 0 disabled, 0 deleted, each with its one role · catalogue 79, admin 79 · role code counts admin 79 ·
auditor 20 · cco 46 · cfo 33 · cto 37 · finance 42 · gm 21 · hr 8 · operations 15 · procurement 16 · sales 17 · warehouse 29 · `action.ncr_decide`
admin, cco, cto · `action.issue_coa` admin, cco · `require_calibrated_since` NULL · contracts 0 · quality limits 0 · NCRs 0 · CoAs 0 · byte records 0 ·
`coa_void` 0 · `coa-documents` 0 objects · output batches 14, output assays 0 · CODs 3 (2 issued, 2 byte records) · pending 1 (CLM-2026-0004) ·
throwaway accounts 0 · probe roles 0.
