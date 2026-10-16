# MES-8a close-out (2026-10-17) — step 1 of the "MES-8a close-out + MES-8b-1 build" brief

No database change and no code change: the only writes are docs and the files beside this one. Live reads were read-only
(`BEGIN READ ONLY … ROLLBACK`, as `postgres`, `rolbypassrls = true`, base tables and the catalog). The deployed-app page probe (item b) used
throwaway clones of real roles (`mintThrowaway { cloneOf }`, prefix `mes8aprobe`, already registered at `scripts/ephemeral.mjs:250`) — accounts,
roles and grants created and removed by the shared ephemeral plan; read back afterwards (2026-10-17 ≈ 00:31 CST): **0 throwaway accounts, 0 probe
roles**, every change-log INSERT matched by a DELETE (two probe runs × five clones: roles 10 / 10 · user_roles 10 / 10 · role_permissions 476 / 476).
No record that existed before was touched.

**Opening check.** First command **2026-10-17 00:11:44 CST** (`date`). Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`556ef6f44c0599d6d32f5abd6bea281ed7daeb10`. No git command was refused.

## 1 · Broken window closed

Recorded in `docs/forward-queue.md` item 55, in the MES-7b-2 format:
- start **2026-10-16 22:46:29 CST** (measured: `db/migration-windows.tsv`, `2026-10-16-mes8a-supplier-scorecards-and-statements.sql`);
- end, lower bound **2026-10-16 23:54:00 CST** (measured: `git reflog show --date=iso refs/remotes/origin/main` →
  `556ef6f4 refs/remotes/origin/main@{2026-10-16 23:54:00 +0800}: update by push`; the cut's commit `1ec4bc44` (23:50:39) was never pushed alone —
  it went out in this same push, `d99da62e..556ef6f4`);
- end, upper bound **2026-10-17 00:11:44 CST** (derived: this session's first command, holding Tim's "deployed" — a relay, not a measurement of Vercel).
- **Window: at least 1 h 07 min 31 s, at most 1 h 25 min 15 s.**
- **What landed on live inside the window** (`closeout-readings.sql`, 2026-10-17 00:21:10 CST, `READ_OWN_EXIT=0`): reviews 0 · statements 0 · statement
  issues 0 · settings row 1 with V23 / V24 all empty · `supplier-statement-documents` 0 objects · purchase orders 11, 0 created since the window opened;
  196 views, **0** (view, role) pairs with a write grant. Change log from the window start: only MES-8a's own smoke / proof throwaways 23:04:35–23:46:46
  (roles 61 / 61 · user_roles 66 / 66 · role_permissions 2,042 / 2,042 · employees 3 / 3 · performance_reviews 1 / 1 (+1 update) · contracts 2 / 2 with
  their term rows · one `cod_verification_failures` row in and out), every INSERT matched by a DELETE; **0 rows between the push and this session**.
- **The deployed app is the MES-8a code** (measured, item b): every clone opens `/suppliers/scorecards`, the supplier page's scorecard panel and
  `/finance/supplier-statements`, the PO form draws the grade line, and the pending-values page lists V23 — all exist only from `1ec4bc44`.

## 2 · Read-only verification

### a · The fixture list in the MES-8a block, item by item

The block's list (MES-8a brief, Verify: "Fixtures must cover every item restated in section 1, including: …", recovered verbatim from the
MES-8a session's transcript). Fixture 269 = `db/fixtures/269-a-supplier-is-counted-a-review-copies-what-it-graded-and-a-grade-only-ever-warns.sql`,
270 = `db/fixtures/270-a-supplier-statement-ties-to-the-ledger-is-frozen-and-is-corrected-by-another.sql`. **Re-run today on a fresh local rebuild of
HEAD's mirrors** (`db/verify_rebuild.py --skip-diff --offline`, `REBUILD_OWN_EXIT=0`): `FX269_OWN_EXIT=0` ("FIXTURE 269 全部通过: REG · MEAS · NOTCMP ·
BREACH · WINDOW · GATE · NOTGR · V23 · V24 · GRADED · CORR · LATEST · PO · SAMPLE · DUE · F17"), `FX270_OWN_EXIT=0` ("FIXTURE 270 全部通过: GATE · PERIOD ·
LINES · TIE · NOTIE · ISSUE · SUPER · NUM · PDF"); the cut's injection script `db/scripts/2026-10-16-mes8a-fixture-injections.py` on the same rebuild:
**`INJECTIONS_OWN_EXIT=0 (44 injections on 269 + 28 on 270, 0 wrong)`**. `check-trail-wording` `WORDING_OWN_EXIT=0`; `TRAIL_WORDING_FAULT=wording-drift-mes8a`
→ exit 1, one red line (㉞, 2 places); `wording-part-mes8a` → exit 1, one red line (㉞, 7 places). `scripts/check-pdf-routes.mjs` `PDFROUTES_OWN_EXIT=0`
(11 cases green, 12 fault cells each biting — `sst-render-live` → SST-FROZEN, `sst-no-409` → SST-409, `sst-orphan-left` → SST-ARCHIVE).

| # | Item | Covered by |
|---|---|---|
| 1 | each scored measure | 269 MEAS `:231-250` (short on the closed order only, over, discharge mismatch, NCRs by disposition, disputes, certificate-lapse days — each with compared / not compared; window and supplier bound) |
| 2 | "not compared" | 269 NOTCMP `:253-260` (null, never 0; NCR and dispute counts a real 0) |
| 3 | grade breaches shown and not scored | 269 BREACH `:263-284` (count, `scored: false`, caveat CONTRACT-1; scored block unchanged; `SCORE_WEIGHT_UNKNOWN|grade_breaches`) |
| 4 | a review copying its inputs | 269 NOTGR `:313-316` (measures copied, nothing else); GRADED `:360-363` (measures, weights, lines, caps), `:369-372` (a later settings change leaves it) |
| 5 | "Not graded — V23 not set" | 269 NOTGR `:309-319` (`V23_NOT_SET`, no grade; advice reviewed, not graded, no warning) |
| 6 | a correcting review citing the old one | 269 CORR `:377-396` (reason required, reason without a correction, other supplier, unknown, already corrected; corrected one unchanged; immutable) |
| 7 | the latest non-superseded review used | 269 CORR `:390-391`; LATEST `:399-408` (by `seq`, three reviews sharing one `recorded_at`) |
| 8 | the prepayment-cap warning not refusing | 269 PO `:411-438` (50 % vs 30 % → one warning, order exists; 20 % none; form preview = creation; fixed amount as a share; no total → not computable) |
| 9 | sampling advice adding no assay | 269 SAMPLE `:441-448` |
| 10 | `action.supplier_review` and the action-implies-view check | 269 REG `:137-138` (declares `module.suppliers.view`); GATE `:296-305` (refusals by name; every held action code has its declared view) |
| 11 | SST numbering beyond 9,999 | 270 NUM `:310-325` (0003 → 9999 → 10000 → 10001, numeric compare) |
| 12 | the statement lines | 270 LINES `:200-231` (opening, charges, credits, payments, prepayments, closing; each line's kind, document, amount, provisional flag; open items; on account) |
| 13 | `SUPPLIER_STATEMENT_DOES_NOT_TIE` | 270 NOTIE `:247-262` (a cent too many → named refusal, nothing written); TIE `:233-245` (ledger side summed independently) |
| 14 | provisional and unpriced lines | 270 LINES `:214-228` (receipts `:true` provisional; unpriced listed with quantity only, not an open item) |
| 15 | supersede with a reason | 270 SUPER `:289-308` (reason required; new code, old one superseded with the reason and its figures; reason without a supersede refused; immutable) |
| 16 | no statement for employee counterparties | 270 PERIOD `:198` (an employee id → `SUPPLIER_NOT_FOUND`); LINES `:219-222` (an employee claim never appears) |
| 17 | PDF from the frozen row, hash stored and re-checked with 409 | 270 PDF `:327-345` (path, digest shape, lower-casing, bytes already recorded, versions, superseded, immutable); 270 ISSUE `:275-283` (the row does not move with live data); the route's half in `scripts/check-pdf-routes.mjs` SST-FROZEN `:281`, SST-409 `:299-306`, SST-ARCHIVE `:310-323` and their fault cells `:349-352` (run today) |
| 18 | F17's three checks | 269 F17 `:466-478` (path prefix, upper-case stored lower, a second set of bytes refused by name) |
| 19 | the review-due arm silent while V23 is unset | 269 DUE `:451-463` (silent with no window; then never reviewed / due; drafts and forwarders not listed; review code only) |
| 20 | V23 and V24 arms | 269 V23 `:322-345` (one row while any part is empty; behind `module.suppliers.view`; every malformed input refused by name); V24 `:348-351`; `:373-374` (all given → no row) |
| 21 | the wording arm | `scripts/check-trail-wording.mjs:7425-7431` (drift fault), `:7559-7574` (part fault and both must bite) — run today, each red in ㉞ only |
| 22 | change-log exclusions at 8 | 269 REG `:146-151` (`change_log_coverage_gaps()` gaps 0, excluded 8; the four new tables carry `zzz_change_log`) |
| 23 | after every finance case, AP list = ledger and 0.00 unexplained | 270 `f270_agree` `:91-99`, called after every step `:138-182`, `:287`, `:348` |

**Nothing on the list is uncovered.**

### b · Usability on the deployed app, as clones of admin, cco, finance, warehouse and cfo

`mes8a-closeout-pages.mjs` (`PAGES_PROBE_EXIT=0`, `X_OWN_EXIT=0`, 2026-10-17 ≈ 00:28 CST; clones = exactly each role's live codes: admin 82 · cco 48 ·
finance 43 · warehouse 31 · cfo 34). GET only, plus two Chrome steps that press nothing that writes: choosing a supplier on the PO form (the grade
line asks `supplier_grade_advice`) and pressing **Preview** on the statement list (`supplier_statement_data`). **25 fetches, all HTTP 200, no
application error.** Supplier: SUP-2026-0003 (`42951a0a…`, the one approved goods supplier on live).

| Page | admin | cco | finance | warehouse | cfo |
|---|---|---|---|---|---|
| `/suppliers/scorecards` | 200 · list + settings form · notice "V23 not set" · no gate | same, no gate | same · settings form **gated `action.supplier_review`** (×1) | same as finance | same as finance |
| `/suppliers/<SUP-2026-0003>/edit` | 200 · scorecard panel + review form, no gate | same, no gate | 200 · review form **gated `action.supplier_review`** (×1) | same as finance | same, plus the page's own `module.suppliers.edit` gates (×4) |
| `/purchasing/orders/new` · grade line (Chrome: choose SUP-2026-0003) | 200 · 7 suppliers listed · **"This supplier has not been reviewed."** | same | same | same | same · the raise-code gate (×1, pre-existing) |
| `/finance/supplier-statements` · issue action (Chrome: SUP-2026-0003, 01/08/2026–16/10/2026, Preview) | 200 · preview closing 6,101.12, ties · **"Issue the statement" pressable** | 200 · same preview · "Issue the statement" **drawn disabled, `module.finance.edit` named** | 200 · pressable | **refused** (no `module.finance.view`) | 200 · drawn disabled, `module.finance.edit` named |
| `/settings/pending-values` | 200 · **V23** listed ("Supplier scorecard: weight per measure, grade lines and review interval …") · no V24 (no grade lines yet) | same | same | same | same |

Live holds no review, no V23 / V24 value and no statement, so a graded line, the review history, a statement page and the issue action on a
statement-bearing supplier were measured on a **local rebuild of HEAD's mirrors** seeded with `docs/surveys/MES-8a/local-seed-clones.sql` and
`docs/surveys/MES-8a/local-seed-data.sql`, `next dev` against the harness gateway stub: `mes8a-closeout-local.mjs` (`LOCAL_PAGES_EXIT=0`). **35 fetches,
all 200, no application error.**

| Page | admin · cco | finance · cfo · warehouse |
|---|---|---|
| graded supplier (SURV-S1) | scorecard + review history + "Grade A" + the superseded first review; review form **not gated** | review form **gated `action.supplier_review`**; same history and grade |
| not-graded supplier (SURV-S2) | "Not graded" · "Not compared" ×4 · form not gated | gated `action.supplier_review` |
| PO form, grade line (Chrome: choose SURV-S1) | **"Supplier grade A — advice only."** | same |
| statement list + issue (Chrome: SURV-S1, last 30 days, Preview) | admin: closing 1,450.00, ties, **pressable**; cco: **disabled, `module.finance.edit` named** | finance: pressable; cfo: disabled, `module.finance.edit` named; warehouse: **refused** |
| statement SST-2026-0002 | summary · lines · open items · on account · unpriced · PDF · versions; admin no gate, cco archive **gated `module.finance.edit`** | finance no gate; cfo gated `module.finance.edit`; warehouse refused |
| pending values | V24 listed (grade C lacks its cap and level), V23 not (set) | same |

The review action is offered to the holders of `action.supplier_review` (admin, cco) only; the statement issue action to `module.finance.edit`
(admin, finance) only — both drawn disabled with their code for everyone else who may enter the page. **Nothing missing, nothing broken.**

### c · The two pre-existing 390 px overflows (registered by MES-8a)

Measured today on the same local rebuild with `scripts/survey-phone.mjs`'s own `MEASURE` string and Chrome at 390 px (overflow self-test bit on every
run, +400 px), the culprit walk naming the elements whose right edge passes the viewport:

| Page | Control | Overflow at 390 px |
|---|---|---|
| `/suppliers/[id]/edit` (`app/suppliers/[id]/edit/page.tsx`, the status panel) | the `PermissionGate` chip of the status actions — a `whitespace-nowrap` pill holding the `<code>` permission code (157 px) inside an `inline-flex flex-row` row (381 px) | active supplier (SURV-S1): **+40 px** for cco · finance · warehouse · gm (`action.supplier_approve` named); approved supplier (SURV-S2): **+30 px** for gm (`module.suppliers.edit` ×2); admin 0 |
| `/purchasing/orders/new` (`app/purchasing/orders/new/NewOrderForm.tsx:600-614`) | the supplier `<select>` (`w-full`), whose intrinsic width is its longest option ("Survey Cells Supplier (a long legal name, Pte. Ltd.)", 492 px) in a `flex-1 min-w-[16rem]` column | **+134 px** cco · finance, **+120 px** warehouse, **+246 px** gm (gm also carries three nowrap permission gates); admin 0 |

Both numbers equal MES-8a's (`docs/known-issues.md` `MES8A-390-SUPPLIER-STATUS-CHIP`, `MES8A-390-PO-SUPPLIER-SELECT`). Live's supplier names are short, so
live does not show the second one today.

### d · Decisions MES-8a took without asking (`docs/handbacks/MES-8a.md` §8, titles only)

1. `grn_discrepancies` split into a base view and a wrapper.
2. A third trail subject, `supplier_score_settings`.
3. The reminder is gated on `action.supplier_review` and lists approved and active goods suppliers.
4. Measure semantics (per order line, short only on closed orders, lapse in days, NCRs by opened date, withdrawn disputes shown only).
5. Null counts are not scored.
6. Grading needs only weights + lines; the review window drives only the reminder.
7. V24 entries may be partly set; a grade missing either value is its own V24 row.
8. The PO warning is previewed on the form; the PO page does not repeat it.
9. Sampling advice on the batch page and both receipt forms.
10. Statement semantics (entry-date periods, the tie on the closing balance, "unpriced" as of the period end, recipient and letterhead frozen, named refusals, its own issue guard).
11. SST in the payables nav group; statements under finance, not on the supplier page.
12. The statement list shows the frozen supplier code and name.
13. Period dates have no defaults.
14. Hand-spliced types before the migration.
15. The statement's English comes from `MESSAGES.en`.
16. Bucket policies (read finance.view; upload finance.edit; delete only unrecorded; no update).
17. "Today" for the measures window is the Singapore date.
18. The PDF render moved into `renderStatement.ts`.
19. Live-proof scenery (priced receipts through a CFO-approved price request; own approved POs).
20. The lapsed certificate in the proof is an ISO (warn) one.
21. View grants: `REVOKE ALL … FROM authenticated, anon` then `GRANT SELECT`.
22. PDF period separator "to" / "至" and a wider Currency column.
23. Smoke: the statement page and its `pdf` route mapped and listed in `EXPECTED_SKIPS`.
24. RUNTIME CONFIG bootstraps restated as correct (`role_permissions`, `supplier_score_settings`).

## 3 · Verdict

a and b: **nothing missing, nothing broken** — step 2 (MES-8b-1) goes ahead (brief item 1.4). c is the fold-in of step 2. No documentation-only gap found.
