# MES-8b-1 close-out (2026-10-17) — step 1 of the "MES-8b-1 close-out + MES-8b-2 build" brief

No database change and no code change: the only writes are docs and the files beside this one. Live reads were read-only
(`BEGIN READ ONLY … ROLLBACK`, as `postgres`, `rolbypassrls = true`, base tables and the catalog — except where a line names a function read under a
session). The deployed-app page probe (item b) used throwaway clones of real roles (`mintThrowaway { cloneOf }`, prefix `mes8b1probe`, already registered
in `scripts/ephemeral.mjs`) — accounts, roles and grants created and removed by the shared ephemeral plan; read back afterwards (2026-10-17 ≈ 11:45 CST):
**0 throwaway accounts, 0 probe roles**, every change-log INSERT matched by a DELETE (two probe runs × five clones: roles 10 / 10 · user_roles 10 / 10 ·
role_permissions 468 / 468). No record that existed before was touched.

**Opening check.** First command **2026-10-17 11:24:50 CST** (`date`). Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`f084de524f05bc45504576d4913ef7f6245de3c7`. No git command was refused.

> ## ★ Result: item b found something not working — step 2 (MES-8b-2) was NOT started (brief step 1.5)
>
> **The stock section of `/finance/price-exposure` leaves out every batch whose material has no kind stated, silently.** On live that is **11 of the 12
> inbound batches on hand (115,288 of 115,388 kg; 5 of them carry metal content)** and **all 12 output batches on hand (3,816 kg)**. The deployed page
> reads, for every role that can see it: *"Value of what is measured and priced: USD 0.00. Incomplete …"*, with **one** batch under "not measured"
> (`ZZ-PROCCOST1-DEMO`, 100 kg, the only on-hand batch whose material has a kind). The other 23 batches appear nowhere on the page — not valued, not
> "not measured", not "unit not kg". Details and the recommendation in §2 b-3 below; registered as `MES8B1-EXPOSURE-SKIPS-UNKINDED-STOCK` in
> `docs/known-issues.md`. Not fixed (the brief: do not fix, do not start step 2).

## 1 · Broken window closed

Recorded in `docs/forward-queue.md` item 56, in the MES-8a format:
- start **2026-10-17 02:30:23 CST** (measured: `db/migration-windows.tsv`, `2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql`);
- end, lower bound **2026-10-17 03:23:30 CST** (measured: `git reflog show --date=iso refs/remotes/origin/main` →
  `f084de52 refs/remotes/origin/main@{2026-10-17 03:23:30 +0800}: update by push`; the push `debb6a7a..f084de52` carried exactly one commit, the cut's own
  `f084de52` (03:21:49));
- end, upper bound **2026-10-17 11:24:50 CST** (derived: this session's first command, holding Tim's "deployed" — a relay, not a measurement of Vercel).
- **Window: at least 53 min 07 s, at most 8 h 54 min 27 s.** The upper bound is long only because nothing measured the deploy between the push and this
  session; it is a bound, not a reading.
- **What landed on live inside the window** (`closeout-readings.sql`, 2026-10-17 11:29:39 CST, `READ_OWN_EXIT=0`): packs 0 · pack issues 0 · settings row 1
  (V26 / V27 empty) · `compliance-documents` 0 objects · `locked_before` = `system_start_date` = 2026-08-01; 196 views, **0** (view, role) pairs with a write
  grant. Change log from the window start: only MES-8b-1's own smoke / proof throwaways 02:47:42–03:16:26 (roles 23 / 23 · user_roles 25 / 25 ·
  role_permissions 874 / 874 · employees 3 / 3 · performance_reviews 1 / 1 (+1 update) · contracts 2 / 2 with their term rows · one
  `cod_verification_failures` row in and out), every INSERT matched by a DELETE; **0 rows between the push and this session**.
- **The deployed app is the MES-8b-1 code** (measured, item b): every clone that may opens `/compliance/packs`, the inbound batch page draws the margin
  section, `/finance/price-exposure` draws the inventory section, and the pending-values page lists V26 and V27 — all exist only from `f084de52`.

## 2 · Read-only verification

### a · The fixture list in the MES-8b-1 block, item by item

The block's list (MES-8b-1 brief, Verify: "Fixtures must cover every item restated in section 1, including: …", recovered verbatim from the MES-8b-1
session's transcript). Fixture 271 = `db/fixtures/271-an-incoming-batch-earns-through-what-is-made-and-sold-from-it-and-stock-is-valued-at-its-metals.sql`,
272 = `db/fixtures/272-a-locked-month-freezes-into-a-compliance-pack-that-carries-no-injury-and-is-corrected-by-another.sql`. **Re-run today on a fresh
local rebuild of HEAD's mirrors** (`db/verify_rebuild.py --skip-diff --offline`, `REBUILD_OWN_EXIT=0`): `FX271_OWN_EXIT=0` ("FIXTURE 271 全部通过: GATE · PATH ·
MARGIN · UNSOLD · REVENUE · NOCOMP · NOSALE · EXPO · LOG"), `FX272_OWN_EXIT=0` ("FIXTURE 272 全部通过: REG · V2627 · GATE · LOCK · ARM · SECT · NOINJ · NUM ·
PDF"); the cut's injection script `db/scripts/2026-10-17-mes8b1-fixture-injections.py` on the same rebuild: **`INJECTIONS_OWN_EXIT=0 (34 injections on
271 + 54 on 272, 0 wrong)`**. `check-trail-wording` `WORDING_OWN_EXIT=0`; `TRAIL_WORDING_FAULT=wording-drift-mes8b1` → exit 1, one red line (㉟, 1 place);
`wording-part-mes8b1` → exit 1, one red line (㉟, 4 places). `scripts/check-pdf-routes.mjs` `PDFROUTES_OWN_EXIT=0` (14 cases green, 15 fault cells each
biting — `cpk-render-live` → CPK-FROZEN, `cpk-no-409` → CPK-409, `cpk-orphan-left` → CPK-ARCHIVE).

| # | Item | Covered by |
|---|---|---|
| 1 | margin through a multi-stage path | 271 PATH `:226-244` (A through O1 / O2 in stage 1 and O3 in stage 2, share 0.75 each; every line's share, sold, revenue, cost, margin, on hand; A + B margins = the outputs' own) |
| 2 | the unsold share at cost | 271 UNSOLD `:253-257` (842.50, not in the margin) |
| 3 | "not computable" on an unpriced leg | 271 NOCOMP `:273-287` (no unit cost · cost incomplete · the inbound batch itself unpriced → NULL, never 0, each reason named) |
| 4 | revenue only from posted settlements | 271 REVENUE `:259-271` — revenue comes only from `sales_records` (Q11); an unposted sell-side settlement changes nothing. A settlement can never post today (SETTLE-1), so "posted settlement" is proved in the shape that exists (MES-8b-1 decision 18) |
| 5 | exposure by metal with price dates | 271 EXPO `:298-320` (Ni 76 kg × 15,000 = 1,140.00 at the price of 3 days ago, not tomorrow's; price older than content counted) |
| 6 | "not measured" and "no price" | 271 EXPO `:321-323` (Co no price, kg listed, not valued) · `:333-335` (B no content → not measured, 300 kg) · `:324-326` (two prices on one date → ambiguous) · `:336-337` (not in kg listed apart) · `:338-339` (the total adds only valued metals, complete false) |
| 7 | the price-view gate on both sections | 271 GATE `:214-224` (both functions: no price code / price code without either module → named refusal; finance + prices and processing + prices pass) |
| 8 | each pack section | 272 SECT `:243-293` (the frozen payload = the preview; §1 balance … §8 EU efficiency, one assertion per section) |
| 9 | injury and pay data absent | 272 NOINJ `:295-303` (no injury detail, no free text, no names; no price, amount, cost or pay) |
| 10 | the freeze refused for an unlocked month | 272 LOCK `:224-231` (`COMPLIANCE_PACK_MONTH_NOT_LOCKED\|<YYYY-MM>\|<locked_before>`, nothing written; empty month refused) |
| 11 | CPK numbering and the -2 re-issue with a required reason, old payload and bytes kept | 272 NUM `:305-334` (CPK-YYYY-MM; no reason → refused; with a reason → -2, the first superseded with who / when / why, its payload unchanged; immutable) |
| 12 | PDF from the frozen payload, hash stored and re-checked with 409 | 272 PDF `:336-354` (path, digest shape, lower-casing, bytes already recorded, versions, superseded, immutable, RLS); the route's half in `scripts/check-pdf-routes.mjs` CPK-FROZEN `:350`, CPK-409 `:367`, CPK-ARCHIVE `:378` and their fault cells `:420-423` (run today) |
| 13 | the not-frozen arm and the month-end warning | 272 ARM `:235-241` (each locked month without a pack, for `action.compliance_pack` only), `:356-360` (gone once frozen); the month-end line `compliance_pack_month_status` 272 GATE `:220-221`, LOCK `:229-231`, NUM `:308-310` |
| 14 | the compliance codes and the action-implies-view check | 272 REG `:130-140` |
| 15 | V26 and V27 rows | 272 V2627 `:202-212` (one row each from day one, behind `module.compliance.view`; half a pair refused) · `:362-372` (both given → no row; a frozen pack not rewritten) |
| 16 | the wording arm | `scripts/check-trail-wording.mjs:7577-7663` (㉟) — both faults run today, each red in ㉟ only |
| 17 | change-log exclusions at 8 | 271 LOG `:341-345`; 272 REG `:145-147` |

**Nothing on the list is uncovered.** (What the list did not ask for — a material with no kind — is item b-3.)

### b · Usability on the deployed app, as clones of admin, cfo, cto, finance and warehouse

**b-1 · Deployed app** — `mes8b1-closeout-pages.mjs` (`PAGES_PROBE_EXIT=0`, `X_OWN_EXIT=0`, 2026-10-17 ≈ 11:44 CST; clones = exactly each role's live codes:
admin 84 · cfo 35 · cto 41 · finance 43 · warehouse 31). GET only. **20 fetches, all HTTP 200, no application error.** Inbound batch: IN-2026-0001
(`662bfff7…`, consumed by 7 runs). (A first run read the freeze button's `disabled` from Tailwind's `disabled:` classes — a probe bug, fixed to read the
`disabled=""` attribute; the table is the second run.)

| Page | admin | cfo | cto | finance | warehouse |
|---|---|---|---|---|---|
| `/inbound/<IN-2026-0001>/edit` — margin section | 200 · "Not computable" + its reasons | 200 · same | 200 · same | 200 · same | 200 · **"Restricted · data.view_prices + module.finance.view / module.processing.view"** |
| `/finance/price-exposure` — stock section | 200 · "USD 0.00. Incomplete" (see b-3) | 200 · same | 200 · same | 200 · same | 200 · page refused (no `module.finance.view`) |
| `/compliance/packs` (default month 2026-09) | 200 · preview, 8 sections · "month not locked" notice · **Freeze button drawn, disabled** (month open) · list "No compliance pack has been frozen yet" · V26 / V27 panel | 200 · same, freeze inside a gate naming **`action.compliance_pack`** (fieldset disabled) | 200 · as admin | 200 · page refused (no `module.compliance.view`) | 200 · page refused |
| `/settings/pending-values` | 200 · V26 and V27 listed | 200 · V26, V27 | 200 · V26, V27 | 200 · neither (both behind `module.compliance.view`) | 200 · neither |

**b-2 · Local rebuild with my own data** (live has no frozen pack and no locked month) — a fresh rebuild of HEAD's mirrors (`co9`), the seven roles' live codes
as clones (`local-seed-clones.sql`, read from live today), MES-8b-1's own scenery (`docs/surveys/MES-8b-1/local-layout-seed.sql`: a computed and a
not-computable margin, exposure, `CPK-2026-09` superseded by `CPK-2026-09-2` with one stored version, `locked_before` 2026-10-01), `next dev` against the
harness gateway stub; `mes8b1-closeout-local.mjs` (`LOCAL_PAGES_EXIT=0`). **40 fetches, all HTTP 200, no application error.**

| Page | admin · cto | cfo | finance | warehouse |
|---|---|---|---|---|
| inbound A (computed) / C (not computable) | margin **337.50 SGD** / "Not computable" + reason | same | same | "Restricted" naming the codes |
| `/finance/price-exposure` | "USD 1,140.00. Incomplete" | same | same | page refused |
| packs `?month=2026-09` (has a live pack) | "Re-issue the pack" (disabled until a reason is typed) | gate `action.compliance_pack`, fieldset disabled | page refused | page refused |
| packs `?month=2026-08` (locked, no pack) | **"Freeze the pack" pressable** | gate `action.compliance_pack`, fieldset disabled | page refused | page refused |
| pack `CPK-2026-09-2` | 8 sections, PDF view + `?version=1`, versions list, **"Store a PDF of this pack" pressable** | same, the store control in a gate naming `action.compliance_pack` | page refused | page refused |
| pack `CPK-2026-09` (superseded) | 8 sections, notice "superseded by CPK-2026-09-2: <reason> … kept exactly as it was" | same | page refused | page refused |
| `/settings/pending-values` | V26, V27 | V26, V27 | neither | neither |

**b-3 · ★ Not working: the stock section skips stock whose material has no kind.** `inventory_metal_exposure()` builds stock with
`JOIN material_kinds k ON k.code = m.kind_code … WHERE k.may_ever_be_processed` (`db/functions/inventory_metal_exposure.sql:33-42`, and again in its second half `:101-110`).
`materials.kind_code` is deliberately nullable — "left empty means nobody has decided, and that is the truth" (`db/tables/materials.sql:189-199`;
`materials_kind_stated` is `NOT VALID`, so only new rows must state it). An inner join treats "nobody decided" as "may not be processed" and drops the row
without a word. Measured on live (2026-10-17 ≈ 11:40 CST, `postgres`, base tables): materials 9, **7 with no kind**; inbound batches on hand **12 / 115,388 kg**,
of which **11 / 115,288 kg** have a material with no kind (5 of those carry content rows, e.g. IN-2026-0181 8,000 kg with 6, IN-2026-0001 887 kg with 1);
output batches on hand **12 / 3,816 kg**, all with no kind. Read **as the admin account's session** (`request.jwt.claims` = `321f1819…`, inside
`BEGIN READ ONLY`): `inventory_metal_exposure()` → every payable metal "priced", 0.000 kg, value 0.00; total **0.00**; not measured: **1 batch, 100 kg**.
The page therefore tells every reader that the stock carrying metal is worth USD 0.00, while five batches with content are on hand and every payable
metal has a price.
- **Why the fixtures did not see it:** fixture 271 gives every material a kind (the shape the CHECK forces on new rows) — the rule's subject (the kind)
  is optional on live and the fixture has no arm for its absence (AGENTS.md "A fixture can be thorough about a rule and blind to the case where the rule's
  SUBJECT IS ABSENT").
- **Margin is not affected**: `inbound_batch_margin` does not read the kind (live: IN-2026-0001 reads "not computable" with its reasons, as it should).
- **Recommendation:** treat a material with no kind as its own visible line, never as "not processable": list such batches under a new heading
  "kind not stated" (code, kg) — not valued, and counted in `complete = false` — the same disposition as "not measured" and "not in kg"; plus a fixture
  271 arm for a material with no kind (on hand, with content) and its fault cell. Smallest alternative: count them in the existing "not measured" list with
  a reason. Either is a migration (one function) + the section component + messages. **Or**, if Tim prefers, accept it as test data that the cutover
  rebuild removes (`materials_kind_stated` forces a kind on every new row) and record it in `docs/known-wrong-until-cutover.md` — then step 2 can go ahead.

### c · The self-taken decisions in `docs/handbacks/MES-8b-1.md` §10, by title

1. The pack lives under the Safety nav, with its own `/compliance` scope and read code.
2. No `/margin/inbound` page — the margin is a section on the inbound batch page.
3. A price is "ambiguous" when the latest date has more than one price.
4. Exposure counts only materials whose kind may ever be processed.
5. Incidents in the pack carry no free text and no names.
6. Open findings at month end are keyed on the inspection date.
7. The reminder arm is gated on `action.compliance_pack`.
8. The month-end row reads "na" until the month is locked.
9. `set_compliance_settings` is gated on `action.compliance_pack` and takes each value as a pair.
10. The pack's `superseded_by` is `DEFERRABLE INITIALLY DEFERRED`.
11. The currency-message baseline was refreshed (five `USD/t` unit labels).
12. `PermissionGate` gained an optional `wrap` prop.
13. Hand-spliced types before the migration, replaced by `types:gen` after it.
14. "Not computable" for any leg without a cost; "nothing sold" reads NULL.
15. PDF sections keep their heading with their first lines (`minPresenceAhead`).
16. The smoke test sorts `compliance_packs` by `frozen_at` and skips the pack page and its `pdf` route.
17. The live proof's "no price" metal is its own payable substance.
18. "A sale with a posted settlement" in the live proof is a sale posted through `record_output_sale`.
19. The month-end page's 390 px overflow (6 px) is registered, not fixed.

(Decision 4 is where b-3 comes from: "materials whose kind may ever be processed" was implemented as an inner join, so a material whose kind nobody has
stated falls out instead of being shown.)

## 3 · Files

`closeout-readings.sql` (window and role-code readings, read-only) · `mes8b1-closeout-pages.mjs` (deployed-app probe) · `mes8b1-closeout-local.mjs` (local
probe) · `local-seed-clones.sql` (the seven roles' live codes as local clones).
