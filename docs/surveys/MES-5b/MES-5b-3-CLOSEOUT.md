# MES-5b-3 close-out — step 1 of the MES-5b-3 close-out + MES-6a Step 0 brief (2026-10-09)

**Verdict: a, b, c, d, e pass. One part of d cannot be shown on the deployed app: live has 0 blending plans, so no plan page — and with it
no release control — exists to render. That is the live state, not a defect (the code and MES-5b-3's rolled-back live proof answer it; §2 d).
The brief's wording "the release action is … not [shown] to the plan's creator" is imprecise: by the standing DBLOCK-1 rule the creator sees
the control disabled with the reason, not hidden. Nothing missing or not working was found, so step 2 (MES-6a Step 0) goes ahead (brief 1.5).**
Nothing was fixed. The window close and the Vercel information line are in `docs/forward-queue.md` item 46.

**Opening check.** First command **2026-10-09 18:40:39 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`45ca694cb9ffb150b8887315d39c4e30ab92d273`. Files staged by explicit path only.

**Identities.**
- Live readings: `mes5b3-closeout-readings.sql` (beside this file) over direct psql to the pooler inside `BEGIN READ ONLY … ROLLBACK`, as `postgres`
  (`rolbypassrls = true`), base tables and the catalog — `READ_OWN_EXIT=0` at 18:45:23 CST, and again at 18:49:53 CST after the render probe.
- Page renders: `mes5b3-closeout-render.mjs` (beside this file) — three one-off clones of real roles (`mintThrowaway { cloneOf }`, prefix `mes5b3probe`,
  already registered) on the **deployed** app (`https://new-era-erp.vercel.app`), `RENDER_PROBE_EXIT=0`, about 18:47 CST. The browser half reads only:
  it presses nothing and submits nothing.
- Cleaned by the ephemeral plan. Afterwards: 0 `mes5b3probe` accounts, 0 `probe-` roles, 0 throwaway accounts, 7 real accounts, 0 disabled (read 18:49:53 CST).
- Static checks run on HEAD (read the repo only): `check-trail-wording`, `check-search-registry`, `check-document-registry`.

---

## 1 · Broken window — closed (bounded)

- **Start:** 2026-10-09 17:21:45 CST — measured, `db/migration-windows.tsv` (`2026-10-09-mes5b3-blending.sql`).
- **End, lower bound:** 2026-10-09 18:18:14 CST — measured, `git reflog show --date=iso refs/remotes/origin/main`:
  `45ca694c refs/remotes/origin/main@{2026-10-09 18:18:14 +0800}: update by push`.
- **End, upper bound:** 2026-10-09 18:40:39 CST — this session's first command, with Tim's "deployed" already in hand. It rests on what Tim said,
  not on a Vercel reading.
- **Window: 56 min 29 s – 1 h 18 min 54 s.**
- Close-out reading (18:45:23 CST, `postgres`, base tables): blending plans **0** · targets 0 · lines 0 · blending runs 0 · runs created since the
  window opened 0 · `require_calibrated_since` NULL. Nobody used the new feature in the window.
- **Information, no action:** the Vercel build of the docs-only commit `032f557a` ("MES-5b-2 close-out") **failed (1 m 49 s)**, while the later
  commit `45ca694c` deployed. Tim did not supply that build's log. Per AGENTS.md ("一刀的终端活【到推送为止】") this machine does not query, reproduce
  or investigate it. Recorded in `docs/forward-queue.md` item 46.

## 2 · Read-only verification

### a · The fixture list, item by item ✓

The brief for MES-5b-3 is not in the repo. Its fixture list is the one item 46 (`docs/forward-queue.md:657`) and Step 0 Q35 / §8
(`docs/surveys/MES-5b/STEP0-HANDBACK.md:367-381,703-706`) record, plus the fold-in "admin holds `module.tasks.view_all`".

| Item | Fixture · arm (file:line) | Fault-injection cell (`db/scripts/2026-10-09-mes5b3-fixture-injections.py`) |
|---|---|---|
| Plan numbering `BLD-YYYY-NNNN`, yearly, gapless | 259 PLAN `:186-192` | PLAN `:66` (off by one) |
| Create / amend need `action.wo_create` | 259 PLAN `:166-167`, `:201-202` | PLAN `:68`, `:72` |
| No other releaser → not born (`BLEND_NO_OTHER_RELEASER`) | 259 PLAN `:169-177` | PLAN `:70` |
| Draft replaced wholesale on amend | 259 PLAN `:196-200` | — (asserted, no own cell) |
| Output must be saleable (`BLEND_OUTPUT_NOT_SALEABLE`, with the form) | 259 SALE `:206-208` | SALE `:75` |
| Output form must be one blending makes; line form one blending takes; kg only; one line per batch; kg > 0; ≥ 1 line | 259 SALE `:209-223` | SALE `:77`, `:79`, `:81` |
| Targets: manual bounds; contract copy takes only applicable specs; snapshot; spec from another material / contract refused; bound rules | 259 TGT `:226-263` | TGT `:84`, `:86`, `:88`, `:90` |
| Prediction = mass-weighted mean; source counted; not measured → NULL; above max flagged, not refused | 259 PRED `:266-279` | PRED `:93`, `:95`, `:97`, `:99` |
| Release needs `action.wo_release`; creator never releases (`SELF_APPROVAL_FORBIDDEN\|raiser`); needs a target; frozen once released; cancel needs a reason | 259 REL `:282-309` | REL `:102`, `:104`, `:106`, `:108` |
| Blending only from the plan (`BLEND_RUN_FROM_PLAN_ONLY`); absent from the ordinary form (`started_from_run_page`); engine signature unchanged; actual vs planned shown; no content written | 259 EXEC `:312-356` | EXEC `:111`, `:113`, `:115`, `:117`, `:120`, `:122` |
| Blended batch content from an assay only (`BLEND_CONTENT_FROM_ASSAY_ONLY`); outcome within / above_max / metal_not_in_assay | 259 ASSAY `:359-381` | ASSAY `:125`, `:127`, `:129` |
| Content and prediction restricted without the batch's view code; base view unreadable; no plan without processing view | 259 READ `:384-406` | READ `:132`, `:134`, `:136`, `:138`, `:140` |
| Three tables change-logged, 8 excluded; trail subject + two members; plan's own trail | 259 LOG `:409-424` | LOG `:144`, `:146` |
| Fold-in: the bootstrap admin holds every code (incl. `module.tasks.view_all`) | 259 ADMIN `:427-443` · 257 FCHECK (header `:27`) | ADMIN `:149` · 257 `:156` |
| Registry 55 → 56 prefixes, 32 → 33 MAX+1 minting functions (23 called) | 100/1 `:168-172` · 100/2 `:98,203` · 100/3 `:274` · `:140,163` | 100 `:154` (BLD row gone) |
| (table, code) pairs 47 → 48 | 101 `:65-67` | — (count pin; no own cell) |
| Registry 56 rows, 13 on `output_batches` | 254 NUM `:281-283` | — (count pin; no own cell) |
| Change-log exclusions stay 8 | 235 `:134` · 259 LOG `:411` | 235's own O-cells (unchanged) |
| Search registry 56 rows | `scripts/check-search-registry.mjs:71-72` — run today on HEAD: **`SR_OWN_EXIT=0`**, "两条路各读到 56/56 行" | the script's own two-path coverage assertion |
| Document registry 286 tables, 87 with a code | `scripts/check-document-registry.mjs:130-133` — run today: **`DR_OWN_EXIT=0`**, "286 张表,其中带 code 列 87 张" | — |

The hand-back's own record (`docs/handbacks/MES-5b-3.md:111-115`): 37 cells on 259 + 1 on 100 + 1 on 257, each red in the arm it names, last run after the
last edit against a fresh rebuild: `INJECTIONS_OWN_EXIT=0` (17:47 CST). One cell deliberately not written (execute no longer asks
`action.processing_commit` — the engine asks the same code first; script header `:11`). Fixtures 101 and 254 are count pins with no own cell — their
red would come from a registry change, which 100/1's cell also catches. Not re-run here (the brief makes this block read-only; the gate is a
build-phase tool).

### b · Trail, wording arm, BLD in the search registry, exclusions ✓

- **Trail subject:** `db/functions/trail_subjects.sql:288-289` —
  `('blending_plan', ARRAY['module.processing.view'], 'blending_plans', 'id', 'table', NULL)`; members `db/functions/trail_subject_members.sql:518-519`
  (`blending_plan_targets`, `blending_plan_lines`, `down`, home). Live: all three lines present in `pg_get_functiondef` (`B|trail subject blending_plan on live=true|members targets=true|members lines=true`).
- **Renderer:** `lib/trail/render.ts:1136` — `blending_plan: ['blending_plans', 'blending_plan_targets', 'blending_plan_lines']`;
  `app/components/trail/AuditTrail.tsx:43,149`.
- **Wording arm ㉕:** `scripts/check-trail-wording.mjs:5993-5998` (fault `wording-drift-mes5b3`), `:6123-6125`. Run today on HEAD: clean
  **`TW_CLEAN_OWN_EXIT=0`** ("✓ check-trail-wording ㉕ MES-5b-3 的配料计划"); with `TRAIL_WORDING_FAULT=wording-drift-mes5b3` →
  **`TW_FAULT_OWN_EXIT=1`**, red in ㉕ only ("✗ … ㉕ MES-5b-3 的配料计划:4 处"; it is the only ✗ line).
- **BLD in the search registry:** `db/tables/document_types.sql:179-180` —
  `('blending_plan', 'BLD', 'blending_plans', 'gapless', NULL, '/operation/blending', 'detail', …, ARRAY['module.processing.view'])`;
  `scripts/check-search-registry.mjs:71-72` (`EXPECTED_ROWS = 56`). Live: `B|document_types BLD|blending_plan|BLD|blending_plans|gapless|/operation/blending`,
  56 rows.
- **Change-log exclusions at 8:** live `change_log_coverage_gaps()` = `{"gaps": [], "bound": 278, "examined": 286, "excluded": 8}`; fixture 235 `:134`,
  259 LOG `:411`.

### c · The +107 px overflow ✓ (before figure from the hand-back; not re-measurable)

- **Page and control:** the plan page `/operation/blending/[id]`, rendered through a temporary harness of its real components (live had no plan;
  the harness was never committed). Culprit: the permission notice beside the **cancel-reason input** — `PermissionGate inline` did not wrap.
- **Before / after:** 390 px **+107 px** → **0 px overflow, 0 clipped** at 390 and 1280 on every target (`LSURVEY390_OWN_EXIT=0`,
  `LSURVEY1280_OWN_EXIT=0`) — `docs/handbacks/MES-5b-3.md:161`; `docs/forward-queue.md:660`.
- **The fix in the code:** `flex-wrap` on both gates, `app/operation/blending/[id]/BlendingPlanActions.tsx:39`
  (`<PermissionGate code="action.wo_release" allowed={canRelease} inline className="flex-wrap">`) and `:56-57`
  (`{/* flex-wrap:…(390px 实测 +107px → 0) */}` / `<PermissionGate code="action.wo_create" allowed={canManage} inline className="flex-wrap">`).
- **What is not evidence here:** the before figure is the hand-back's reading; the harness was not committed, so it cannot be re-measured without
  rebuilding it. A documentation-level note, not a gap in the app.

### d · Usability on the deployed app — clones of warehouse, finance, admin ✓ (with one thing live cannot show)

| Clone of (codes) | `/operation/blending` | `/operation/blending/new` | `/operation/blending/<no such id>` | `/operation/processing/new` — operation picker |
|---|---|---|---|---|
| warehouse (28) | **200** · "New blending plan" is a live link (visible, 1) | **200** · form open, no gate | **404** (passes the gate, then notFound) | **200** · 7 options; **`blending` absent** |
| finance (41) | **200** · "New blending plan" a **disabled** button inside the gate: "New blending plan Needs action.wo_create" | **200** · the form's fieldset **disabled**, gate `action.wo_create` | **404** | **200** · 7 options; **`blending` absent** |
| admin (75) | **200** · live link | **200** · form open | **404** | **200** · 7 options; **`blending` absent** |

- The seven options read in the browser for every clone: `deep_discharge, manual_disassembly, electrode_line, electrode_powder_line,
  battery_powder_line, casing_removal, electrode_separation` — exactly the live list of active operations not `started_from_run_page`
  (`D|operations offered on the ordinary new-run form=…`, positive control: the fetch found all 7 `value="…"` and no `value="blending"`).
  Live: `D|operation blending|active=true|started_from_run_page=true|tolerance=NULL`.
- No error text on any of the 12 fetches.
- **Release — shown to finance, not to the creator: not renderable on the deployed app.** Live has **0** blending plans (`W|plans=0`), so no plan
  page exists; a non-existent id answers 404 after the gate for all three roles. What exists instead:
  - the control: `app/operation/blending/[id]/BlendingPlanActions.tsx:39-52` — the release button inside `PermissionGate code="action.wo_release"`;
    for the creator, `releaseBlockedReason` (`app/operation/blending/[id]/page.tsx:99`: `plan.created_by === myUserId`) disables it and prints
    "You created this plan, so you cannot release it. Someone else who holds the release permission must." (`messages/en.ts:11604`) through
    `Refusal`. **So the creator sees the control disabled with that sentence — not hidden** (AGENTS.md DBLOCK-1: visible, unpressable, with
    its reason). The brief's "not to the plan's creator" is right about pressing and imprecise about showing.
  - who can press it, measured: MES-5b-3's rolled-back live proof (`docs/handbacks/MES-5b-3.md` §2 and §6.1) — finance clone releases; the creator
    holding both codes is refused `SELF_APPROVAL_FORBIDDEN|raiser`; live holders of `action.wo_release` today: admin, finance (`D|holders|…`).
  - **Not measured on the deployed app** — it can be, the first time a plan exists on live.

### e · Self-taken decisions in `docs/handbacks/MES-5b-3.md` §7 (titles)

1. "Saleable powder" = the blending operation's own declared forms.
2. Blending accepts only `discharged_verified` batches.
3. No tolerance, field, machine or recipe set on `blending` (it appears under V1).
4. A database guard for "only from the plan page".
5. "Content from an assay only" is a guard on `output_batch_metals`.
6. The outcome compares the blended batch's latest valid recorded assay.
7. The prediction is restricted when the reader cannot view any one of the plan's batches.
8. Prediction on planned kg; the flag compares the unrounded value.
9. Actual kg is not stored on the lines.
10. `BLEND_NO_OTHER_RELEASER` at create.
11. Four-eyes is the creator only.
12. Release needs at least one target and one line.
13. Cancel is `action.wo_create`, draft or released, reason required.
14. A plan stays `executed` if its run is later rolled back.
15. Editing a draft replaces its targets and lines wholesale.
16. Copying a contract (applicable specs; explicit spec must belong to the plan's contract; snapshots).
17. Planned kg is not refused above a batch's stock.
18. The validator is INVOKER, not DEFINER.
19. The trail uses the generic wording family.
20. The plan page shows the contract as "Restricted" when the reader cannot read it.
21. `execute_blending_plan`: allocation basis `weight`, no machine, default notes.
22. The live proof's batches are output batches inserted as setup.
23. The layout survey used a temporary harness.
24. The step-1 probe script's two lint warnings were fixed in that cut.
25. One fixture (259) carries the admin arm too.

## 3 · Assertions measured and found false or imprecise

- **d, "the release action is shown to finance and not to the plan's creator"** — the creator sees it **disabled, with the reason** (DBLOCK-1), not
  absent; and on the deployed app no plan exists to show it at all (0 plans).
- **c** — the +107 px before figure is a hand-back reading of an uncommitted harness; the fix is in the code, the before is not re-measurable.
- Zero other assertions found false: SHA, clean tree, 7 accounts enabled, admin 75 / 75 codes (`D|catalogue=75|admin=75`), approvals ON finance / cfo /
  1,000 (`S|approvals_on=true|l1=finance|l2=cfo|threshold=1000`), `require_calibrated_since` NULL — all re-measured.
