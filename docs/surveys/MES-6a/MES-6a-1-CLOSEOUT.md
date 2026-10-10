# MES-6a-1 close-out — step 1 of the MES-6a-1 close-out + MES-6a-2 brief (2026-10-10)

**Verdict: a, b, c and d pass; e measured 0 px overflow at both widths on both pages (nothing to fix); f lists the twenty decisions. Nothing
missing or not working was found, so step 2 (the MES-6a-2 build) goes ahead (brief 1.4).** One thing of the brief's 1.c cannot pass yet by
construction: wording arm ㉗ belongs to MES-6a-2 and does not exist on HEAD — it is built in step 2 (§2 c). Nothing was fixed in this step.
The window close is in `docs/forward-queue.md` item 47.

**Opening check.** First command **2026-10-10 09:46:07 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`d645d5a79b6257e1235b0acf1061523095d3d917`. Files staged by explicit path only.

**Identities.**
- Live readings: `mes6a1-closeout-readings.sql` (beside this file) over direct psql to the pooler inside `BEGIN READ ONLY … ROLLBACK`, as `postgres`
  (`rolbypassrls = true`), base tables and the catalog — `READ_OWN_EXIT=0` at 09:53:09 CST (a first run at 09:52:48 stopped on my own typo, a
  `deleted_at` column `expenses` does not have; read-only, nothing written).
- Page renders: `mes6a1-closeout-render.mjs` (beside this file) — four one-off clones of real roles (`mintThrowaway { cloneOf }`, prefix
  `mes6a1probe`, already registered) on the **deployed** app (`https://new-era-erp.vercel.app`). The browser half presses nothing that writes:
  every non-GET request the pages make is failed in the browser and counted (count **0**). First run (09:55 CST) **`RENDER_PROBE_EXIT=6`**: the
  machine's network dropped mid-run (`fetch failed`; Vercel `000` after 30 s), so two clones' cleanup could not reach live. Measured recovery
  (Supabase 1.5 s, Vercel 3.3 s), then `node scripts/reap-ephemeral.mjs` → `REAP_OWN_EXIT=0` (one plan, six steps, 0 failed); read back on live
  0 throwaway accounts · 0 `probe-` roles · 0 grants without an account · no live-lock. Retried once immediately (house rule):
  **`RENDER_PROBE_EXIT=0`** (~10:13 CST). Afterwards (10:15:32 CST): 0 throwaway accounts, 0 probe roles, 7 real accounts, 0 disabled,
  `EXP-2026-0010` still `posted` with no reversal reason, 0 reversed expenses. **After the run** the probe was given the MES-6a-2 fold-in's
  "run only when executed directly" guard (its two library imports and exit hooks moved into `main()`, nothing else changed), so that
  importing this file starts nothing; `check-lint` `LINT_OWN_EXIT=0` (no new eslint problem).
- Layout (item e): a **local** rebuild of HEAD's mirrors (`verify_rebuild.py --offline`, `VR_OWN_EXIT=0`, never live) with data of my own, read
  by a scratch copy of HEAD outside the repo (details in §2 e).
- Static checks on HEAD (read the repo only): `check-search-registry` · `check-document-registry` · `check-trail-wording` (clean and fault).

---

## 1 · Broken window — closed (bounded)

- **Start:** 2026-10-09 22:33:44 CST — measured, `db/migration-windows.tsv` (`2026-10-09-mes6a1-samples-and-disputes.sql`).
- **End, lower bound:** 2026-10-09 23:55:45 CST — measured, `git reflog show --date=iso refs/remotes/origin/main`:
  `d645d5a7 refs/remotes/origin/main@{2026-10-09 23:55:45 +0800}: update by push`.
- **End, upper bound:** 2026-10-10 09:46:07 CST — this session's first command, with Tim's "deployed" already in hand. It rests on what Tim said,
  not on a Vercel reading.
- **Window: 1 h 22 min 01 s – 11 h 12 min 23 s.** The upper bound is long because it is the next morning's first command, not because anything
  was seen broken.
- What was broken in it (**derived**, MES-6a-1 hand-back §6.4, not measured on live): the old expense page sends no reason, so every expense
  reversal on the old app was refused `EXPENSE_REVERSAL_REASON_REQUIRED`; old assay forms worked (named arguments, `p_sample_id` defaulted);
  dispute refusals need a dispute the old app could not open.
- Close-out reading (09:53:09 CST, `postgres`, base tables): samples **0** · custody events 0 · disputes 0 · V16 NULL · assays naming a sample 0 ·
  laboratories linked to a supplier 0 · V14 set 0 · reversed expenses **0** · reversal reasons 0 · expenses created since the window opened 0 ·
  assays created since 0 · `require_calibrated_since` NULL · approvals ON (finance / cfo / 1,000) · 7 accounts, 0 disabled.
  **Nobody used the new features, and nobody tried an expense reversal, in the window.**

## 2 · Read-only verification

### a · The fixture list, item by item ✓

The MES-6a-1 brief is not in the repo. Its fixture list is the one Step 0 §4 and Q44 record (`docs/surveys/MES-6a/STEP0-HANDBACK.md:176-191, 535-538`)
and the hand-back §3.2 confirms. Injection cells are in `db/scripts/2026-10-09-mes6a1-fixture-injections.py`.

| Item | Fixture · arm (file:line) | Fault-injection cell (script line) |
|---|---|---|
| 260 SMP — SMP- yearly gapless; registry row | 260 SMP `:146-162` | `:86`, `:88` |
| 260 CUST — custody append-only, states, lab active, disposal reason, no direct insert | 260 CUST `:163-225` | `:91`–`:106` (8 cells) |
| 260 RET — keep-until copied at creation (contract → V16 → not set), never re-dated | 260 RET `:226-284` | `:110`–`:124` (6) |
| 260 ASSAY — sample of the same batch only (function + table guard), stored | 260 ASSAY `:285-312` | `:128`, `:130`, `:133` |
| 260 EARLY — early disposal flagged; `sample_retention_due` arm | 260 EARLY `:313-338` | `:136`, `:138` |
| 260 CODES — two codes; `action.apply_assay` declares quality view; warehouse view only (Q12) | 260 CODES `:339-368` | `:141`, `:143`, `:145` |
| 260 READ — samples / custody / `sample_rows` readers | 260 READ `:369-395` | `:148`, `:151`, `:154` |
| 260 LOG — four tables change-logged, exclusions 8, trail subjects | 260 LOG `:396-416` (`:398` exclusions = 8) | `:157`, `:159` |
| 260 PV — V16 arm | 260 PV `:417-434` | `:162` |
| 261 OPEN — opening rules | 261 OPEN `:203-220` | `:168`–`:175` (4) |
| 261 HOLD — apply, preview, waiting request held; manual / committed repricing not | 261 HOLD `:221-273` | `:180`–`:189` (5) |
| 261 RESOLVE — `action.apply_assay`, applies nothing | 261 RESOLVE `:274-296` | `:192`, `:194`, `:198` |
| 261 D4 — same party only, inbound and output | 261 D4 `:297-334` | `:202`, `:204` |
| 261 SELL — settlement refused; limit copied | 261 SELL `:335-383` | `:207`, `:209` |
| 261 FEE — fee expense, lab supplier, finance-view masking, V14 share, unapproved supplier | 261 FEE `:384-442` | `:212`–`:222` (6) |
| 261 DISAGREE — sell-side prompt arm | 261 DISAGREE `:443-472` | `:225`, `:227` |
| 261 V14 — V14 arm, CHECK | 261 V14 `:473-489` | `:230`, `:232` |
| 261 F3 — reason required, stored on the original, mirror notes machine-only, guard, CHECK | 261 F3 `:490-546` | `:235`–`:251` (6) |
| 40 — preview / apply parity under a dispute | 40 F `:186-205` | `:256` |
| 118 — applying a counterparty / umpire result does not supersede ours | 118 F5 `:201-231` | `:258` |
| 149 — sell dispute refuses settlement; withdrawn → same amount | 149 J `:344-354` | `:260` |
| 220 — a waiting assay request cannot be approved while a dispute is open | 220 I6 `:349-359` | `:262` |
| 256 — single-argument `reverse_expense` calls gain a reason (assertions unchanged) | 256 `:2-3`, `:428` | — (a changed call, no new assertion) |
| 258 — the same, plus the F3 arm | 258 `:2-3`; F3 `:240-258` | `:264`, `:266` |
| 100 · 101 · 254 — registries 56 → 57 (SMP) | 100 `:9`, `:100`, `:360` · 101 `:66` (48 → 49) · 254 `:282` (57) | 100: `:269`; 101 and 254 pin counts, no cell of their own (the MES-5b-3 precedent) |
| 111 — sixty-two reminder arms | 111 `:56-57`, `:94` | `:271` |
| 235 · 234 · 102 — new tables bound; exclusions stay 8 | 235 `:134` (excluded = 8); 260 LOG `:398` | the LOG cells above |

Hand-back §3.2 records the run: **70 cells, 0 wrong**, `INJECTIONS_OWN_EXIT=0`, on a fresh rebuild after the last database edit. Re-run today
not needed for a read-only close-out; the cells and arms above were re-read at the lines given.

### b · The nine quality grants and action-implies-view ✓

Live, `postgres`, base tables (`B|` lines, 09:53:09 CST):

| Role | `module.quality.view` | `module.quality.edit` |
|---|---|---|
| admin | ✓ | ✓ |
| cco | ✓ | ✓ |
| cto | ✓ | ✓ |
| cfo | ✓ | — |
| finance | ✓ | — |
| warehouse | ✓ | — (Q12) |
| gm, and every other role | — | — |

**9 grants exactly** (`quality grants total=9`); catalogue 77, admin 77 / 77; `action.apply_assay` declares
`module.inbound.view, module.output.view, module.quality.view`. **Action-implies-view (the fixture 257 FCHECK predicate, read on live): 0 violations
across the 67 (role × action code) pairs of the seven roles with a real holder, and 0 across every role.** Codes per live role: admin 77 · cco 44 ·
cfo 33 · cto 36 · finance 42 · gm 21 · warehouse 29 — the same as MES-6a-1's after-reading.

### c · Registries, V16 / V14, known issues, forward queue, wording ✓ (㉗ is this cut's)

- **Registries at 57 with SMP:** live `document_types` 57 rows, `sample|SMP|samples|gapless|/quality/samples`; `check-search-registry`
  `SR_OWN_EXIT=0` (57 / 57); `check-document-registry` `DR_OWN_EXIT=0` (290 tables, 88 with a code); mirror `db/tables/document_types.sql`
  carries the row; fixture 100 / 254 above.
- **V16 and V14 as arms and docs rows:** live `pending_values` has both arms (`C|pending_values arms V16=true|V14=true`); rows in
  `docs/mes-pending-values.md:40-41` with their "what it holds back" notes `:144-156`; fixtures 260 PV and 261 V14.
- **Reminder arms:** live `operations_now` has `sample_retention_due`, `assay_dispute_open`, `assay_results_disagree`.
- **known-issues:** `MES6A1-APPLY-SUPERSEDES-ACROSS-PARTIES` (the superseded bug, D4) and `MES6A1-TRAIL-COUNTERPARTY-IS-THE-BUYER` ("The buyer")
  are both struck and marked "✅ 登记并关闭于 MES-6a-1" (`docs/known-issues.md:10642-10655`).
- **forward-queue:** the Q12 note (`docs/forward-queue.md:707-708`), V17 and N38 under MES-6b (`:718`, and the MES table row 10 `:7249`).
- **Wording:** ㉖ clean `TW_CLEAN_OWN_EXIT=0`; fault `TRAIL_WORDING_FAULT=wording-drift-mes6a1` → `TW_FAULT_OWN_EXIT=1`, red in ㉖ only.
  **㉗ does not exist on HEAD** — it is the MES-6a-2 wording arm (Step 0 Q39: "㉖ (6a-1) and ㉗ (6a-2)"); it is built in step 2.
- Trail subjects `sample`, `assay_dispute`, `quality_settings` on live; change-log coverage `{"gaps": [], "bound": 282, "examined": 290, "excluded": 8}`.

### d · Usability on the deployed app ✓

Four clones of real roles (codes at that moment: warehouse 29 · finance 42 · cco 44 · admin 77). HTTP status from a fetch with the clone's cookie;
the rest read in a real browser after hydration, at 1280 px.

| Clone of | `/quality/samples` | `/quality/disputes` | new sample (`/quality/samples/new?batch=inbound:…`) | `/finance/expenses/EXP-2026-0010` |
|---|---|---|---|---|
| warehouse | **200** · "Record a sample" a disabled button: "Needs module.quality.edit" | **200** · "Open a dispute" disabled: "Needs module.quality.edit" | **200** · form shown, fieldset **disabled** inside the gate | **200, refused at the gate** (no `module.finance.view`); no Reverse control |
| finance | **200** · disabled, names `module.quality.edit` | **200** · disabled, names the code | **200** · fieldset disabled | **200** · Reverse pressable → dialog on `EXP-2026-0010`: reason box "Reason (required)", body "…do not write anyone's health details here", **confirm disabled while blank, still disabled with spaces only, enabled with text**; Cancel closed it |
| cco | **200** · "Record a sample" a live link | **200** · "Open a dispute" a live link | **200** · form open | **200** · Reverse visible, **disabled, "Reverse Needs module.finance.edit"** |
| admin | **200** · live link | **200** · live link | **200** · form open | **200** · as finance: blank / spaces disabled, text enabled, Cancel closed it |

Step one of the new-sample page (no batch) answers **200** for all four (a batch picker, no gate). No error text on any of the 20 fetches.
**Non-GET requests attempted by the pages: 0** (all four roles) — nothing was submitted; `EXP-2026-0010` read back `posted`, no reason.

### e · Layout of `/contracts/[id]` and the output assay page (local rebuild) ✓ — 0 px

- **Data of my own on a local rebuild of HEAD** (`/tmp/m6a2`, port 55440, `verify_rebuild.py --offline` `VR_OWN_EXIT=0`; never live): a **draft sell
  contract** with **all seven term sections filled** (5 grade specs incl. material-specific ones, 2 insurance, 2 volume commitments, 3 pricing
  terms, the settlement row with every field incl. the V14 rule, 3 refining charges, 3 penalty elements; 50–90-character titles, notes, document ref
  and material names) and an **output batch** (18,750.5 kg) with two assays (ours applied-able, the counterparty's provisional one **unapplied**,
  7 metals each, all header fields filled), **two samples** and **an open dispute** (so the quality panel has rows), recorded through the functions
  as an all-codes user.
- **How it was rendered:** a scratch copy of HEAD outside the repo whose `lib/supabase/server.ts` answers **only** the tables and RPCs these two pages
  read from a JSON dump of that rebuild (read as the same user, through the views' own predicates); everything else — the session, `can()`,
  `requireModule` — went to live as usual. The pages themselves are HEAD's, unmodified, at their real routes. Measured with HEAD's
  `scripts/survey-phone.mjs` (self-test passed: +510 px injection read and named; clipped-table injection read 1).
- **Result:**

| Page | 390 px | 1280 px |
|---|---|---|
| `/contracts/[id]` (7 tables, all with rows; 11 columns at most) | **0 px overflow, 0 clipped** (`S390_EXIT=0`) | **0 / 0** (`S1280_EXIT=0`) |
| `/output/[id]/assays/[assayId]` (metals + apply preview, 7 rows; header strip; quality panel) | **0 / 0** | **0 / 0** |

  **No overflow → nothing to fix in step 2 for these two pages.** The harness was never committed. Two first attempts at 390 px stopped on the
  survey's own self-test (`S390_EXIT=1`: no viewport meta — the scratch copy's `node_modules` was a symlink that Turbopack refuses, so the dev
  server never served a page; replaced by an APFS clone) — a harness problem, not a reading.

### f · Self-taken decisions in `docs/handbacks/MES-6a-1.md` §7 (titles)

1. Two-step "new" pages (pick a batch, then the form).
2. V16 lives on `/quality/samples` as a panel with its own trail.
3. The quality panel is drawn for holders of either code; links are plain text without `module.quality.view`.
4. The assay forms' sample picker lists every sample of the batch, disposed ones included.
5. Reminder links: retention due → sample page; open dispute → dispute page; disagreeing results → output batch page.
6. The fee picker lists only posted expenses to the umpire lab's supplier, only for finance-view holders.
7. The resolve picker lists every live result of the batch.
8. Neutral labels everywhere the party is named.
9. The expense page reads the banner's reason, who and when from the original.
10. The reason hint sits in the dialog body; the placeholder is an example.
11. Trail: generic family for samples / custody / disputes; settings family for V16; a new Quality area.
12. The reversal reason on the trail is read from the original's `reversal_reason`.
13. `sample_rows.state` is the first branch column.
14. Smoke: list pages mapped; both `[id]` pages in `EXPECTED_SKIPS`; `/quality/samples` trail `emptyOk`.
15. Layout survey of the `[id]` pages on temporary copies.
16. The live proof inserts its own USD rate, ni quote and LME September calendar / quotes; suppliers get input tax code `OP`.
17. The CFO decision in the proof is taken by a throwaway holding the real cfo role.
18. The backup was retried once after the SSL drop.
19. `dict.noSupplier` reads "Not linked"; the dispute list shows "largest difference · limit L" or "limit not set".
20. `setQualitySettings` refuses a non-integer before calling the database.

## 3 · Assertions measured and found false or imprecise

- **1.c "wording arms ㉖ and ㉗"** — ㉗ is MES-6a-2's arm (Step 0 Q39) and cannot exist on HEAD; ㉖ verified.
- Zero other assertions found false: SHA, clean tree, approvals ON finance / cfo / 1,000, 7 accounts enabled, admin holding every code (77 / 77),
  `require_calibrated_since` NULL, no sample / dispute / lab-supplier link / V14 / V16 set — all re-measured.
- **Something of mine, recorded so it is not mistaken for nothing:** the first render-probe run lost the network mid-run and left two throwaway clones
  (warehouse, finance) on live for about 15 minutes, holding exactly those roles' codes; reaped by their own cleanup plan, read back 0 (§ Identities).
