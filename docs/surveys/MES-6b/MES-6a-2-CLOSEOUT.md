# MES-6a-2 close-out — step 1 of the MES-6a-2 close-out + MES-6b Step 0 brief (2026-10-14)

**Verdict: a, b and d pass; c found one thing missing — the assay forms do NOT show ppm beside % for fluorine and chlorine (measured on the
deployed app, all three clones, both forms, before and after a value is entered).** A second part of c could not be measured on live: the
contract's penalty-element picker lives on `/contracts/[id]`, and live has **0 contracts**. Under brief 1.4, **step 2 (MES-6b Step 0) was NOT
started** — no grilling hand-back, no `docs/surveys/MES-6b/STEP0-HANDBACK.md`. Nothing was fixed. The window close is in
`docs/forward-queue.md` item 48.
**★ Then (2026-10-15, §3a): Tim accepted the close-out — the ppm readout becomes MES-6b fold-in F7, item a's weaker spots F8 — and the penalty
picker was rendered on a local rebuild of HEAD: it offers Fluorine and Chlorine only.** Step 2 went ahead in the next block.

**Opening check.** First command **2026-10-14 21:53:54 CST** (`date`). Tree clean. After `git fetch`: `HEAD` = `origin/main` =
`git ls-remote origin main` = `1026dc94d1e20e39b221f2a104168c6de8d38e0c`. Files staged by explicit path only.

**Identities.**
- Live readings: `mes6a2-closeout-readings.sql` (beside this file) over direct psql to the pooler inside `BEGIN READ ONLY … ROLLBACK`, as
  `postgres` (`rolbypassrls = true`), base tables and the catalog — `READ_OWN_EXIT=0` at **21:59:20 CST**. Nothing written.
- Page renders: `mes6a2-closeout-render.mjs` (beside this file) — three one-off clones of real roles (`mintThrowaway { cloneOf }`, prefix
  `mes6a2probe`, already registered) on the **deployed** app (`https://new-era-erp.vercel.app`). Every non-GET request the pages make is failed in
  the browser and counted. It runs only when executed directly (`onlyWhenRunDirectly`, first statement after the imports; its library imports are
  inside `main()`), so `check-import-inert` can import it safely.
  - Pass 1 (~22:00 CST): **`RENDER_PROBE_EXIT=0`**, 0 requests blocked — the HTTP half and the metal-price pages read; my selector for the assay
    forms' metal table matched nothing (it tested `innerText` for `ni|co|li`), so the table half was not read. Fixed the selector (match the table by
    its "Nickel" row, read `textContent`) and ran once more.
  - Pass 2 (~22:07 CST): every reading taken, 0 requests blocked; **`RENDER_PROBE_EXIT=6`** — the cleanup of two throwaway roles (cco, admin
    clones) timed out (`The operation was aborted due to timeout`; the network was slow: Supabase auth health 4.5 s, Vercel /login 8.5 s, measured
    right after). `node scripts/reap-ephemeral.mjs` → `REAP_OWN_EXIT=1` (`fetch failed`), retried once immediately → **`REAP_OWN_EXIT=0`** (one plan,
    nine steps). Read back on live at **22:13:53 CST** (`postgres`, read only): **0 throwaway accounts · 0 `probe-` roles · 0 grants without an
    account · 7 real accounts · 0 disabled** · contracts 0 · assays 4 · indicator values 0; no live-lock. The two throwaway roles existed on live,
    with no account holding them after the accounts were removed, for about six minutes.
  - **This is the MES-6a-2 app:** the forms carry the "Quality indicators" panel (`data-panel="indicator-fields"`) and F / Cl rows — neither exists
    in the MES-6a-1 app — so the readings below are of the deployment Tim confirmed (`1026dc94`), not of the old `0565de86`.

---

## 1 · Broken window — closed (bounded)

- **Start:** 2026-10-10 12:45:10 CST — measured, `db/migration-windows.tsv` (`2026-10-10-mes6a2-penalty-elements-and-indicators.sql`, head 0565de86).
- **End, lower bound:** 2026-10-14 21:46:34 CST — measured, `git reflog show --date=iso refs/remotes/origin/main`:
  `1026dc94 refs/remotes/origin/main@{2026-10-14 21:46:34 +0800}: update by push` (HOTFIX-6A2, the first commit whose build passes on Vercel).
- **End, upper bound:** 2026-10-14 21:53:54 CST — this session's first command, with Tim's "deployed and Ready" for `1026dc94` already in hand. It
  rests on what Tim said, not on a Vercel reading.
- **Window: 4 d 9 h 01 min 24 s – 4 d 9 h 08 min 44 s** (105 h 01 min 24 s – 105 h 08 min 44 s). The old "≈ deploy time" premise of the migration
  header did not hold: the 8ea0875e build failed at 14:22 CST on 2026-10-10 and production kept serving the MES-6a-1 app until HOTFIX-6A2.
- What was broken in it (**derived**, migration header and item 48, not measured on live): the old pricing pages' pickers offered `f` / `cl`
  (labelled `metals.f` / `metals.cl`) and choosing one was refused `SUBSTANCE_NOT_PAYABLE`; the old dictionary page could not create a new substance
  (`role` NOT NULL); old assay forms worked (no `p_indicators` → its default).
- Close-out reading (21:59:20 CST, `postgres`, base tables): substances `ni co li mn cu al fe` = `payable_metal`, `f cl` = `penalty_element` (as the
  migration left them) · **substance rows changed since the window opened (change_log) 0** · indicator definitions the five, values **0** ·
  penalty-element rows 0 · contracts **0** (all, deleted or not) · F / Cl content rows on assays, inbound and output batches **0** · assays 4,
  **created since the window opened 0** · metal prices created since 0 · approvals ON (finance / cfo / 1,000) · 7 accounts, 0 disabled, 0 throwaway ·
  `require_calibrated_since` NULL · catalogue 77, admin 77 (admin 77 · cco 44 · cfo 33 · cto 36 · finance 42 · gm 21 · warehouse 29) · document types 57.
  **Nobody recorded an assay, a metal price, a contract or a substance in the window**; refusals are not logged, so whether anyone met the
  `SUBSTANCE_NOT_PAYABLE` refusal cannot be read.

## 2 · Read-only verification

### a · The MES-6a-2 brief's fixture list, item by item ✓ (with the injection gaps named)

The MES-6a-2 brief is not in the repo; its fixture list (brief "Verify", read from the session transcript of 2026-10-10) is the nine items below.
F262 = `db/fixtures/262-fluorine-is-recorded-and-penalised-never-priced-and-an-assay-carries-its-indicators.sql`; INJ =
`db/scripts/2026-10-10-mes6a2-fixture-injections.py` (41 cells, `docs/handbacks/MES-6a-2.md:94`); CSD = `scripts/check-substance-display.mjs`;
CII = `scripts/check-import-inert.mjs`. Each line re-read today.

| # | Item | Fixture · arm (file:line) | Injection cell (INJ line) |
|---|---|---|---|
| 1 | the role column on every substance | F262 ROLE `:138-160` (NOT NULL, no default; every row in the three roles; `:148` `'f|Fluorine|氟|F|8|t;cl|Chlorine|氯|Cl|9|t'`; no-role and unknown-role inserts refused); 119 F1 `:86-90` (seven `payable_metal`) | `:91-96` (default set · f made payable · CHECK dropped) |
| 2 | `SUBSTANCE_NOT_PAYABLE` on each price path | F262 PAY `:174-200` — metal price, calculator, new formula, formula change, contract pricing term, refining charge; f and cl refused by name, a payable passes, nothing left behind; 119 F2P `:211-233` adds the engine on terms and the commitment copy | `:98-110` (+ layered `:177-179`, green by design); 119 `:183-191` |
| 3 | F and Cl accepted as contract penalty elements, refused as payable metals | F262 PEN `:204-218` (`:209` / `:217` `SUBSTANCE_NOT_PENALTY_ELEMENT|cu`); the payable half is PAY's loop over f, cl; 119 F2P `:204-208`, `:238-241`; 149 `:125`; 230 `:161-162` | `:112-115`; 119 `:186-187` |
| 4 | F on a sale assay and an output batch — settlement payables, sale quote, price-from-terms, metal recovery, costs unaffected | F262 SETTLE `:253-283` (`:271` 12,600.00 / 180.00 / 65.70 / 12,354.30) · QUOTE `:288-312` · APPLY `:314-354` · RECOV `:374-378` · COST `:386-389`; 149 (F 2.5 on three assays, 11,542.50 / 11,567.50 unchanged) | `:117-140`; 149 `:193-194` |
| 5 | % storage with ppm display, not rounded | storage: F262 PPM `:391-402` (`:394` `'0.0123'`); display: **build check only**, CSD `:50-62` (`:50` `'0.005% (50 ppm)'`) + the no-`toFixed` rule `:110-112` | storage `:141-142`; display: CSD's own faults and self-proof cells |
| 6 | picker labels from the dictionary | **build check only**: CSD `:64-67` (`:65` `'Nickel|Fluorine|Chlorine|Retired thing'`), `:107`, `:113`; F262 ROLE `:146-149` pins the dictionary data | CSD fault `labelkey`, self-proof cells |
| 7 | the five indicators entered on both assay forms, no limits | F262 IND `:404-472` — five definitions, no limit column (`:411-413`); inbound records all five (`:428`); output records two (`residual_powder_pct` 0, `d50_um` 1,000,000 — no upper limit) `:421-433`; named refusals; reads follow the parent batch | `:144-164` (nine cells) |
| 8 | importing the smoke script starts nothing | **build check only** (app side): CII — first statement must be the guard, the smoke named (`:224`), every live-acting script really imported in a trapped child and must refuse `NOT_RUN_ON_IMPORT` | CII fault `unguard:<path>` + six self-proof cells; HOTFIX-6A2 re-ran both faults in both environments |
| 9 | change-log exclusions at 8 | F262 LOG `:476-489` (`:477` `excluded <> 8`); 235 O1 `:133-137` | `:166-173` (gaps, bindings, trail) |

**Every item is covered by a fixture arm or (app-side items 5-display, 6, 8) a build check.** Weaknesses found while mapping — recorded, not
"missing", none fixed here:
- the engine's terms-side `SUBSTANCE_NOT_PAYABLE` (`calculate_metal_price_from_terms.sql:66-71`) and the formula-*change* path have no injection
  cell of their own (INJ's header says 119 F2P covers the first; none of the 119 cells patches the engine);
- the "exclusions = 8" half of item 9 is asserted (F262 `:477`, 235 `:134`) but never fault-injected (every LOG cell attacks gaps or bindings);
- item 7's output path records 2 of 5 indicators in the fixture (the full five on both forms was shown only in the rolled-back live proof,
  `db/scripts/2026-10-10-mes6a2-live-proof.sql:201-209`); the forms themselves have no fixture or build check;
- 119 F1's seven-payable assertion has no cell.

### b · The three MES-6a-2 known issues and HOTFIX6A2-BUILD-READS-ENV-LOCAL ✓

All in `docs/known-issues.md`, section "MES-6a-2 留下的(2026-10-10 记录)":

- **`MES6A2-PAYABLE-METAL-NOT-A-PENALTY`** `:10661-10670` — open. `:10663-10664`: "合同的惩罚条款(`contract_penalty_elements`)从 MES-6a-2 起只收
  `role = penalty_element` 的物质,别的按名拒 `SUBSTANCE_NOT_PENALTY_ELEMENT|<码>`(守卫 `guard_substance_role`)。于是一份【既按镍计价、又罚铜】的合同
  …… 写不进来". Delete condition `:10669-10670`: Tim decides (guard takes a set of roles, or a per-contract role).
- **`MES6A2-PENALTY-ONLY-ASSAY-NOT-APPLICABLE`** `:10672-10679` — open. `:10674-10675`: "`apply_assay_result` 把一份化验的含量【整份】换进批次
  (先删后抄),再把其中的可计价金属交给计价引擎。一份只记了氟、氯的化验 …… 交给引擎的是一张空清单 → `NO_METALS`,整笔回滚".
- **`MES6A2-TRAIL-WORDING-PART-NOT-COMPARED`** `:10681-10690` — open. `:10683-10686`: "㉓ ㉔ ㉕ ㉖ 四臂 …… 读的是 `e.part`(`:5885` · `:5981` ·
  `:6116` · `:6320`)—— `buildEntries` 吐出来的条目上没有这个字段(那一栏叫 `titlePart` ……),于是 `got.part` **永远是 null**". Re-read today:
  `scripts/check-trail-wording.mjs:5885`, `:5981`, `:6116`, `:6320` each read `part: e.part?.text ?? null`; ㉗'s comment at `:6467` names the defect.
- **`HOTFIX6A2-BUILD-READS-ENV-LOCAL`** `:10693-10707` — struck and "✅ 关闭于 HOTFIX-6A2(仍是 `v1.4.49`,2026-10-14)". `:10699`:
  "`scripts/ephemeral.mjs` 在【模块顶层】读 `.env.local`"; `:10704`: "`ephemeral.mjs` 改为第一次真要用到时才读(`liveEnv()`……)"; `:10707` the
  standing rule (cold clone before every push), also AGENTS.md `:2124-2145` and the sequence line `:2098`.

### c · Usability on the deployed app (the MES-6a-2 app) — ✗ one thing missing, one thing unmeasurable

Three clones (codes at that moment: finance 42 · cco 44 · admin 77). HTTP status from a fetch with the clone's cookie; the rest read in a browser
after hydration, at 1280 px. Inbound batch `ZZ-PROCCOST1-DEMO` and output batch `OUT-2026-0381` (the newest live, not-deleted ones, D| lines).

| Clone of | `/inbound/[id]/assays/new` | `/output/[id]/assays/new` | `/tools/pricing/metal-prices` | `/tools/pricing/metal-prices/new` | `/contracts` |
|---|---|---|---|---|---|
| finance | **200** · F and Cl in the HTML; browser: metal table header **"Metal · Content %"**, nine rows `Nickel ni … Iron fe · Fluorine f · Chlorine cl`; **no "ppm" anywhere on the page**, also after 0.0123 was put into the F box; "Quality indicators" with the five (Residual powder on foil (%) · Foil purity (%) · Particle size D10 / D50 / D90 (µm)), each `min=0`, no max | **200** · same: nine rows, header "Content %", **no ppm** before or after (`Fluorine f 0.0123` in the row, nothing beside it); five indicators, no max | **200** · picker "All metals" + the seven payable metals; **no Fluorine / Chlorine anywhere** | **200** · `metal` select: the seven payable metals only | **200** · empty (0 contracts) |
| cco | **200** · HTML: F, Cl, the indicator panel, no "ppm"; browser read of the table **not taken** (both passes: the page had no `h1` and no table when read — a probe artefact on the role's first navigation, not a refusal; the HTML fetch is the reading) | **200** · browser: as finance — nine rows, "Content %", **no ppm** after entering F; five indicators | **200** · seven payable metals, no F / Cl | **200, refused at the page** ("Metal Prices", no `action.metal_prices`) — no F / Cl | **200** · empty |
| admin | **200** · HTML as cco (browser table read not taken, same artefact) | **200** · as finance — **no ppm**; five indicators | **200** · seven, no F / Cl | **200** · seven payable metals only | **200** · empty |

No error text on any of the 30 fetches. **Non-GET requests attempted by the pages: 0** in both passes (all three roles; putting a value into the F
box started no request — no preview call was made for these batches).

- ✓ **The assay forms offer F and Cl** (dictionary names "Fluorine" / "Chlorine" with their codes) **and the five indicators** (no upper bound) — both
  forms, all three clones.
- ✗ **"with ppm shown beside %" — not on the forms.** The metal column is labelled "Content %" and the row shows the typed value only; no ppm text
  appears on the page before or after a value is entered. Code agrees: the content cell renders `r.content` / a `DecimalInput`
  (`app/inbound/[id]/assays/new/AssayForm.tsx:197-207`; `app/output/[id]/assays/new/OutputAssayForm.tsx:136-139`). MES-6a-2 put ppm on the
  **display** pages only — assay detail (`app/inbound/[id]/assays/[assayId]/page.tsx:321`, `app/output/[id]/assays/[assayId]/page.tsx:275,305,314`),
  the batch content panel (`app/components/metals/MetalContentPanel.tsx:138`) and the contract's threshold (`app/contracts/[id]/page.tsx:151-156`)
  — and its decision 5 says so ("stored and entered in %, printed as stored … ppm beside it for penalty elements only",
  `docs/handbacks/MES-6a-2.md:259-260`). Live has 0 F / Cl content rows and 0 output assays, so those display pages have nothing to show on live
  (their ppm text was read on the MES-6a-2 harness, hand-back §5 row 10).
  **Recommendation:** add a live ppm echo beside the content box for penalty elements on both assay forms (`ppmOf` of the typed string, the same
  `lib/substances.ts` function the detail pages use; nothing stored differently; one CSD rule that the two forms call it) — **as a fold-in to
  MES-6b (F7)**, or Tim rules that ppm on the detail pages satisfies Q29 and step 2 may start as briefed. Entering 0.0050 % for 50 ppm is exactly
  the order-of-magnitude slip the specification warns about (§3.2: "12.5 recorded as 125"), so I recommend the echo.
- **Not measured on live: the contract's penalty-element picker.** It is on `/contracts/[id]` and live has **0 contracts** (`W|` line); creating one
  is outside this block. What the code says (not a rendering): `app/contracts/[id]/page.tsx:94` `penaltyElements: pickable(penaltyOnly(substances))`,
  labels from the dictionary through `toSubstanceOptions` (`lib/substances.ts:35-37`), pinned by CSD `:150` and `:159`; the server refuses anything
  else (F262 PEN). **Recommendation:** render it on a local rebuild of HEAD with a draft contract of my own (the MES-6a-1 close-out item e harness),
  or on live once a colleague has a contract.
- ✓ **The metal-price pages do not offer F or Cl** (list filter and "new" form, all three clones; cco is refused the "new" page by code and sees no
  F / Cl either).

### d · Self-taken decisions in `docs/handbacks/MES-6a-2.md` §8 (titles)

1. Two layers on the price paths that have a function of their own.
2. The engine refuses; the readers filter.
3. Contract penalty elements take penalty elements only.
4. Changing a substance's role does not re-judge existing rows.
5. The ppm is a screen convention, not a stored value.
6. `metals.f` / `metals.cl` message keys added.
7. Indicator definitions are not open to every reader.
8. Indicator values are written only through `record_assay_result`.
9. Batch pages show the latest recorded value per indicator.
10. The purchase-order estimate skips non-payables.
11. The metal-price and formula server actions still accept any dictionary code.
12. `assay_indicators` in the document-registry exceptions.
13. A penalty-element-only assay cannot be applied to a priced inbound batch.
14. Arms ㉓–㉖ compare a field that does not exist.
15. The required-metals status line uses the same dictionary names.
16. Fold-in 2's guard throws rather than returns.
17. A second new build check (`check-substance-display`).
18. Stale records corrected in files this cut touches.
19. In the live proof my own draft contract was activated through the owner path.
20. The pre-window build used hand-spliced types.
21. The smoke's scratch penalty row changed from `cu` to `f`.

## 3 · Stop (brief 1.4)

Item c shows something missing (ppm beside % on the assay forms) → **step 2 not started**. Item a's injection gaps are test-strength weaknesses,
not missing coverage; the contract picker is unmeasurable on live, not broken. Waiting on Tim: (1) the ppm echo as F7 in MES-6b, or a ruling that
the detail pages satisfy Q29; (2) whether to measure the penalty picker on a local harness; then the MES-6b Step 0.

## 3a · Tim's rulings on this close-out (2026-10-15) and the penalty-picker render

**Rulings (Tim, MES-6a-2 close-out rulings + MES-6b Step 0 brief):** the close-out is accepted; the missing ppm readout on the assay entry
forms is **not a stop** — it becomes **fold-in F7** of MES-6b; the weaker test spots of item a become **fold-in F8**; the penalty-element picker,
unmeasurable on live, is rendered now on a local rebuild of HEAD (below). F7 and F8 are recorded under MES-6b in `docs/forward-queue.md`.

**The penalty-element picker, rendered on a local rebuild of HEAD (2026-10-15 00:04–00:08 CST) — ✓ offers Fluorine and Chlorine, no payable metal.**
- **Rebuild:** a throwaway local cluster (`/tmp/m6b`, socket only), `python3 db/verify_rebuild.py --target … --offline` → `VR_OWN_EXIT=0`
  (B1 / B2 0). Never live.
- **Data of my own** (owner inserts on that rebuild): a customer `ZZH-CUST`, a **draft sell contract `CON-2026-0003`** (offtake), one pricing term (ni),
  settlement terms with `penalty_basis = per_element`, and two penalty elements — **F 0.005 % at 1,000** and **Cl 0.0025 % at 425.5** per settlement
  tonne per point over. On the same rebuild, adding `cu` as a penalty element is refused by the table's guard: `SUBSTANCE_NOT_PENALTY_ELEMENT|cu`.
- **How it was rendered** (the MES-6a-1 close-out item e precedent): a scratch copy of HEAD outside the repo (`/tmp/m6b/app`, `node_modules` an
  APFS clone) whose `lib/supabase/server.ts` answers **only** the contract page's tables and RPCs (the contract, its customer label, the seven term
  tables, `substances`, materials, currencies, indices, the lock reason, the activation list, terms requests, the trail) from a JSON dump of that
  rebuild read as an all-codes user through the views' own predicates; everything else — the session, `can()` (`current_user_permissions`),
  `requireModule` — went to live as usual, with one-off clones of real roles (`mintThrowaway { cloneOf }`, prefix `mes6a2probe`). The page is
  HEAD's, unmodified, at its real route, served by `next dev`; requests were GETs only. The harness and its probe were never committed.
- **Result** (server-rendered HTML of `/contracts/<id>`, the "add a row" forms, which are always rendered for a draft):

| Clone of | Page | Penalty elements — `substance` options | Pricing terms / refining charges — `metal` options | Threshold and rate text |
|---|---|---|---|---|
| cco (44 codes) | **200**, `CON-2026-0003`, no error | `— Choose —` · **`f` = Fluorine** · **`cl` = Chlorine** — nothing else | the seven payable metals (Nickel … Iron), **no F / Cl** | `0.005% (50 ppm)` · `1000 per % (0.1 per ppm)` · `0.0025% (25 ppm)` · `425.5 per % (0.04255 per ppm)` |
| admin (77 codes) | **200**, same | same: Fluorine, Chlorine only | same: seven payable metals | same |

  The penalty `<select>` carries no `disabled` attribute for either clone (both hold `action.contract_terms`). (A first reading said "disabled" — my
  regular expression matched the Tailwind class text `disabled:cursor-not-allowed`; the tag itself, captured in a third pass, has no attribute.)
- **Runs:** three probe passes (`PICKER_OWN_EXIT=0` each; the first read no form because I looked for the marker `contract_penalty_elements:new`
  — the form's marker is `penalty_elements:new`; the second read the options; the third captured the tags). The first two passes left the scratch
  `next dev` running after exit; killed by hand (`pkill`), confirmed gone. Read back on live at **00:08:58 CST** (`postgres`, read only):
  **0 throwaway accounts · 0 `probe-` roles · 0 grants without an account · 7 real accounts · 0 disabled · 0 contracts.**
- **No fold-in needed from this:** the picker behaves as ruled.

## 4 · Assertions measured and found false or imprecise

- **Brief 1.2 c "an assay form offers F and Cl with ppm shown beside %"** — the forms offer F and Cl; ppm is shown on the display pages, not on the
  forms (§2 c).
- **Brief 1.2 c "a contract's penalty-element picker"** — cannot be rendered on live: 0 contracts.
- Zero other assertions found false: SHA, clean tree, 7 accounts enabled, approvals ON finance / cfo / 1,000, admin holding every code (77 / 77),
  `require_calibrated_since` NULL — each re-measured.
- **Something of mine, recorded so it is not mistaken for nothing:** the second render pass's cleanup timed out on a slow network and left two
  throwaway roles (clones of cco and admin, no account holding them) on live for about six minutes; reaped by their own plan on the second reap
  attempt, read back 0 (§ Identities).
