# MES-7a-2 close-out (2026-10-16) — step 1 of the "MES-7a-2 close-out + MES-7b Step 0" brief

No database change and no code change: the only writes are docs and the files beside this one. Live reads were read-only
(`closeout-readings.sql`, `BEGIN READ ONLY … ROLLBACK`). The deployed-app page probe (item b) used throwaway clones of real roles
(`mintThrowaway { cloneOf }`, prefix `mes7a2probe`, already registered in `scripts/ephemeral.mjs`) — accounts, roles and grants created and removed by
the shared ephemeral plan, the same way the MES-7a-1 close-out did; read back afterwards: **0 throwaway accounts, 0 probe roles**, every change-log
INSERT matched by a DELETE (roles 5 / 5 · user_roles 5 / 5 · role_permissions 229 / 229, 13:36:44–13:38:36 CST). No record that existed before was touched.

**Opening check.** First command **2026-10-16 13:31:34 CST**. Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`c5d4cf674bd39a91b261a8d4c870f5bce98d524d`.

## 1 · Broken window closed

Recorded in `docs/forward-queue.md` item 52, in the MES-7a-1 format:
- start **2026-10-16 12:30:24 CST** (measured: `db/migration-windows.tsv`, `2026-10-16-mes7a2-spare-parts.sql`);
- end, lower bound **2026-10-16 13:24:18 CST** (measured: `git reflog show --date=iso refs/remotes/origin/main` →
  `c5d4cf67 refs/remotes/origin/main@{2026-10-16 13:24:18 +0800}: update by push`; `afd9977b` was never pushed alone — it went out in this same push);
- end, upper bound **2026-10-16 13:31:34 CST** (derived: this session's first command, holding Tim's "deployed" — a relay, not a measurement of Vercel).
- **Window: at least 53 min 54 s, at most 1 h 01 min 10 s.**
- **What landed on live inside the window** (read 13:39:55 CST as `postgres`, `rolbypassrls = true`, base tables; `closeout-readings.sql`,
  `READ_OWN_EXIT=0`): part issues 0 · maintenance movements 0 · `maintenance_part` entries 0 · 6800 journal lines 0 · spare-part materials 0 · spare-part
  batches 0 · stock movements created in the window 0 · maintenance records 2 (created or changed in the window 0). Change log from the window start:
  1,159 rows 12:44:46–13:15:55, all MES-7a-2's own smoke / proof throwaways (roles 11 / 11 · user_roles 11 / 11 · role_permissions 536 / 536 · employees 7 / 7 ·
  performance_reviews 3 / 3 (+3 updates) · contracts 2 / 2 with their term rows · one `cod_verification_failures` row in and out), every INSERT matched
  by a DELETE; **0 rows between the push and this session**; then this close-out's own probe (above).
- **The deployed app is the MES-7a-2 code** (measured, item b): every clone's machine page draws `data-section="spare-parts"`, and every clone's
  `/operation/balance` shows the column "Issued to maintenance (net of returns)" — both exist only from `afd9977b`.

**Tim's rulings recorded** (brief item 1.2): the missing maintenance void and fixture 266's VOID guard are accepted as built
(`docs/known-issues.md` `MES7A2-MAINTENANCE-HAS-NO-VOID`, ruling appended); the Chinese name 维修保养费 for 6800 stands unless Tim changes it
(forward-queue item 52); the live spare-part dictionary note and the two under-counting build checks become fold-ins **F12** and **F13** for the next
build cut (forward-queue MES group row 12; known-issues `MES7A2-SPARE-PART-NOTE-LIVE-STALE` and `MES7A2-ENUM-PARSERS-STOP-AT-A-COMMENT`, rulings appended).

## 2 · Read-only verification

### a · The fixture list in the MES-7a-2 block, item by item

The block's list ("Fixtures must cover every item restated above, including: …", MES-7a-2 brief, Verify). Fixture 266 =
`db/fixtures/266-a-spare-part-is-issued-to-a-repair-at-landed-cost-and-comes-back-with-a-reason.sql`; 263 = `…263-a-quality-hold-is-an-open-ncr-…`;
257 = `…257-every-kilogram-goes-somewhere-and-every-level-adds-up.sql`. **Re-run today on a fresh local rebuild of HEAD's mirrors**
(`db/verify_rebuild.py --skip-diff --offline`, `REBUILD_OWN_EXIT=0`): `FX266_OWN_EXIT=0` ("FIXTURE 266 全部通过: REG · PERM · REFUSE · VOID · ISSUE · RETURN ·
DIRECT · CAPITAL · REPRICE · HOLD · ROLL · V21 · RECON · TRAIL"), `FX263_OWN_EXIT=0`, `FX257_OWN_EXIT=0`; the cut's injection script
`db/scripts/2026-10-16-mes7a2-fixture-injections.py` on a second fresh rebuild: **`INJECTIONS_OWN_EXIT=0` (34 injections on 266 + 1 on 263, 0 wrong)**;
`check-enum-mirrors` `_OWN_EXIT=0` ("MOVEMENT_TYPES ↔ movement_type:14 个值,两个方向都对得上"), `check-i18n` `_OWN_EXIT=0`.

| # | Item | Covered by |
|---|---|---|
| 1 | issue and return postings at landed cost | 266 ISSUE `:241-272` — 4 issued → Dr 6800 / Cr 1200 = 4 × `inbound_batch_landed_unit_cost_all` (`:246`, `:257-262`), source `maintenance_part`, source_id = the issue row (`:259`); RETURN `:299-303` — the reverse, Dr 1200 / Cr 6800 = 1 × landed |
| 2 | the 6800 system account | 266 REG `:171-174` (`code = '6800' AND is_system AND is_active AND account_type = 'expense' AND name_en = 'Repairs & Maintenance'`) |
| 3 | only spare_part materials | 266 REFUSE `:216-217` (`PART_NOT_SPARE_PART|…|battery_material`) |
| 4 | voided and capitalised maintenance refused | capitalised: 266 REFUSE `:212-213` (`PART_ISSUE_CAPITALISED|FX266-M|…`); voided: **no subject** — 266 VOID `:231-239` asserts the table has no void / delete / cancel column and delete is refused, so a void added later turns it red (`MES7A2-MAINTENANCE-HAS-NO-VOID`; Tim 2026-10-16: accepted as built) |
| 5 | capitalising a record with parts refused | 266 CAPITAL `:330-337` (`MAINTENANCE_HAS_PARTS|FX266-M|…|1`) |
| 6 | quantity above available refused | 266 REFUSE `:222-225` — single line 11 > 10, and two lines 6 + 6 summed per batch (`PART_ISSUE_EXCEEDS_AVAILABLE|…|10|12`); nothing written `:226-229` |
| 7 | `SPARE_PART_UNPRICED` | 266 REFUSE `:218-219` |
| 8 | a provisional price accepted | 266 ISSUE `:243-245` (the batch is `provisional`) then the issue at `:247` goes through |
| 9 | reprice sends the issued share's difference to 6800 through `reprice_split` | 266 REPRICE `:342-370` — unit arithmetic of `reprice_split` (`:345-355`), the preview (`:356-359`), the real reprice 5 → 6 posting 1200 Dr 7 · 6800 Dr 3 · 2000 Cr 10 and nothing to 5000 (`:360-366`) |
| 10 | quality hold blocks issue, allows return | 266 HOLD `:372-381`; 263 HOLD `:363` (`maintenance_issue` → `QUALITY_HOLD_OPEN`) and `:382` (`maintenance_return` → `ALLOWED`); injection cell "the quality hold lets an issue to maintenance through" bites 263 |
| 11 | return requires a reason and cites its issue | 266 RETURN `:278-279` (`PART_RETURN_REASON_REQUIRED`), `:293-298` (the row cites its issue, carries its reason, one +1 `maintenance_return`), `:306-307` (a return of a return refused) |
| 12 | roll-forward and balance tree tie with the new column | 266 ROLL `:383-398` (issued to maintenance −3 and closing = stock; tree `maintenance` 2, `unexplained` 0); 257 ROLL `:407` (the identity includes `issued_to_maintenance`) |
| 13 | the movement-type list check and translations | 266 REG `:175-178` (the CHECK names both types); `scripts/check-enum-mirrors.mjs:43-50` pins `MovementMixChart.tsx:40` `MOVEMENT_TYPES` to the CHECK (14 values today); `scripts/check-i18n.mjs:710` reads `movements.type.*` from the CHECK; `messages/en.ts:8062-8063` · `messages/zh.ts:7849-7850` |
| 14 | V21's arm | 266 REG `:195-197` (the view carries a V21 arm); V21 `:400-413` (received spare part listed, never-received not, gone once a minimum is set; empty for `postgres`, who carries no JWT) |
| 15 | the rewritten `material_kinds` note | 266 REG `:179-184` (rebuild: new wording, old "不按批次追溯】" absent) — **live still carries the old note** (`MES7A2-SPARE-PART-NOTE-LIVE-STALE`, now fold-in F12) |
| 16 | wording arm ㉛ | `scripts/check-trail-wording.mjs:6951-7055` — drift fault `wording-drift-mes7a2` `:6957` with its bite check `:7054`, part fault `partFault('mes7a2', …)` `:7040` / `partFaultBit` `:7055`, ≥ 2 part sentences `:7052` |
| 17 | change-log exclusions at 8 | 266 TRAIL `:421-424` (`change_log_coverage_gaps()` gaps 0, excluded 8); the return is in the change log with its reason `:417-420` |
| 18 | after every finance case AP list = ledger, 0.00 unexplained, inventory control reconciled | 266 `pg_temp.f266_recon` `:94-110` (both `list_ledger_reconciliation` sides 0.00; `gl_control_reconciliation` inventory_raw unexplained 0.00 and reconciled), called after the receipts `:159`, the issue `:272`, the return `:308`, the reprice `:367`, a return at the new price `:370` and the hold `:381` |

**Nothing on the list is uncovered.** Weaker spots, **recorded, not missing, not fixed**:
- **W5** — item 13's two checks read the type list from the CHECK with a regex that stops at the first `)` (`check-enum-mirrors.mjs:58-66`, strips `--`
  comments only after that cut) or keeps comments (`check-i18n.mjs:188-193`). Green today because the one comment still inside the list
  (`inventory_movements.sql:30-31`, IOD-1) contains no `)` or `'`. This is exactly fold-in **F13**.
- **W6** — item 4's "voided" half has no subject; the VOID arm is a guard, not a refusal (Tim: accepted as built).

### b · Usability on the deployed app, as clones of warehouse, cco, finance and admin (+ cfo)

`mes7a2-closeout-pages.mjs` (GET only, `PAGES_PROBE_EXIT=0`, `X_OWN_EXIT=0`, 2026-10-16 13:36:40–13:38:39 CST; clones = exactly each role's live codes:
admin 79 · cco 46 · finance 42 · warehouse 29 · cfo 33). **cfo was added** because all four of the brief's roles hold `module.inventory.edit` on live
(admin · cco · cto · finance · operations · sales · warehouse), so "disabled with the code named to others" has no subject among them; cfo is the one role
held by one of the seven real accounts (tim@) that lacks it (gm, vince@'s role, also lacks it). Machine = FA-2026-0001.
**20 fetches, all HTTP 200, no application error.**

| Clone | Machine page (FA-2026-0001) | `/operation/balance` | `/finance/trial-balance?all=1` (no chart-of-accounts page exists) | `/settings/pending-values` |
|---|---|---|---|---|
| admin | 200 · "Spare parts issued to maintenance" section · **"Issue spare parts" pressable** (no gate in the section) · "No spare parts have been issued to this machine's work records." | 200 · roll-forward column **"Issued to maintenance (net of returns)"** | 200 · row `6800 … Repairs & Maintenance` (0.00); **no word marks it as a system account** | 200 · no V21 row (live has no spare-part material — the arm's condition) |
| cco | 200 · same as admin — pressable | 200 · column shown | 200 · 6800 listed, not marked system | 200 · no V21 row |
| finance | 200 · parts section, "Issue spare parts" **pressable**; the page's 6 gates all name `module.processing.edit` (the MES-7a-1 downtime / maintenance / interval forms) | 200 · column shown | 200 · 6800 listed, not marked system | 200 · no V21 row |
| warehouse | 200 · parts section, "Issue spare parts" **pressable**; "Amounts are shown only to people who can see prices."; 6 `module.processing.edit` gates as above | 200 · column shown | 200 · **refused page** (`data-access-denied`; no `module.finance.view`) | 200 · no V21 row (and no `module.materials.view`) |
| cfo | 200 · parts section, "Issue spare parts" **disabled, naming `module.inventory.edit`** (1 gate in the section) | 200 · column shown | 200 · 6800 listed, not marked system | 200 · no V21 row |

**Local rebuild with data of my own** for what live has none of — issues and returns on a work record, V21 rows, 6800 with a balance. HEAD's mirrors
rebuilt locally, seeded with `docs/surveys/MES-7a-2/local-seed.sql` (spare-part batches priced / unpriced / held, two issues and a return on a repair,
a reprice after the issue, an NCR hold) plus `local-seed-finance.sql` (a finance clone; the other four clones' codes re-read on live read-only and
identical to the seed's), harness gateway stub + local PostgREST + `next dev` on :3197; `mes7a2-closeout-local.mjs` (GET, server-rendered HTML,
`LOCAL_PAGES_EXIT=0`). **25 fetches (5 clones × 5 pages), all HTTP 200, no application error.**

| Clone | Machine page (2 issue rows) | Trial balance | Pending values | Batch page (balance tree) | `/operation/balance` |
|---|---|---|---|---|---|
| admin · cco · finance | issue entry pressable; **2 "Return" buttons pressable**; "Still out, at landed cost" column shown | `6800 … Debits 355.00 · Credits 85.50 · Repairs & Maintenance`; not marked system | **V21 rows for both received spare parts** | fate line "Issued to maintenance (net of returns)" | **page says only "No processing run has been recorded yet." — no roll-forward** |
| warehouse | issue + 2 returns pressable; value column absent, "Amounts are shown only to people who can see prices." | refused (no `module.finance.view`) | no V21 row (no `module.materials.view`) | fate line shown | same — no roll-forward |
| cfo | **3 controls disabled naming `module.inventory.edit`** (issue + 2 returns); value column shown | 6800 listed, not marked system | V21 rows shown | fate line shown | same — no roll-forward |

**Two things found, neither caused by MES-7a-2, neither stopping step 2 (my judgement, stated so Tim can overrule it):**
1. **There is no chart-of-accounts page, and no page anywhere says which account is a system account** (`MES7A2CO-NO-CHART-OF-ACCOUNTS-PAGE`). The brief's
   "the chart of accounts shows 6800 as a system account" has no subject today: `grep -rn "from('accounts')" app lib` → 11 reads (trial balance,
   journal, bank, expenses, assets, claims), none of them `is_system`; `is_system` in `app/` is read only for **roles**. 6800 *is* a system account in the
   database (`ACCT6800|6800|Repairs & Maintenance|维修保养费|expense|system=true|active=true`) and is listed by name on the trial balance. MES-7a-2's
   hand-back already said so (decision 16). **Recommendation:** not a fold-in for MES-7b (no MES-7b record needs it); if Tim wants the flag visible, a
   one-column "System" badge on the trial balance (or a read-only chart-of-accounts page under Finance) as its own small item.
2. **On a database with no processing run, `/operation/balance` hides the stock roll-forward entirely** (`MES7A2CO-ROLLFORWARD-HIDDEN-WITHOUT-RUNS`):
   `app/operation/balance/page.tsx:106` keys the whole page's empty state on processing data only. Live has runs, so the deployed page shows the column
   (table above). The line dates from MES-5b-1 (`00744eff`, v1.4.45). MES-7a-2's own local layout survey measured that empty page without noticing.
   **Recommendation:** fold it into MES-7b as **F14** (≈ 10–15 min: the empty state requires all three sources empty; one page-probe check on a
   runs-less rebuild) — or leave it registered; Tim's call (Step 0 open question).

### c · The known-issues entries (quoted, `docs/known-issues.md`, line numbers as of the close-out commit)

- **The two under-counting build checks** — `:10869-10879` `MES7A2-ENUM-PARSERS-STOP-AT-A-COMMENT`:
  > `:10871` **是什么:** `scripts/check-enum-mirrors.mjs` 与 `scripts/check-i18n.mjs` 都从 `db/tables/*.sql` 的 `CHECK (col IN (...))` 现读取值。第一稿把两种新流水类型
  > `:10872` 写在 IN 列表里一句 `--` 注释的【后面】,两支解析器都在注释那儿停下:`check-enum-mirrors` 报"12 个值,两个方向都对得上",`check-i18n` 没有要
  > `:10873` `movements.type.maintenance_issue` 的句子 —— **两张绿,而图上会少两根条、屏幕上会印两个键名**。…
  > `:10875` **删除条件:** 一刀专门让两支解析器在 IN 列表里认得注释(或者在读到一个注释时自己红),并带着"往列表中间塞一句注释"那一格故障注入。
  > `:10876` ★ **Tim 的裁定(2026-10-16,MES-7a-2 close-out):并入下一个建库的刀,作 F13** …
- **Parts into a capitalised overhaul** — `:10845-10850` `MES7A2-PARTS-INTO-CAPITALISED-OVERHAUL`:
  > `:10847` **是什么:** 资本化一次大修走费用单(`record_expense` 带 `p_maintenance_id`,回填 `capitalised_expense_id`);从库里出的件按落地单价进 6800 维修费。
  > `:10848` 两条路之间没有桥,所以 `issue_spare_parts` 拒往一条资本化了的记录上出件(`PART_ISSUE_CAPITALISED`),表上的守卫拒把一条还挂着件的记录资本化
  > `:10849` (`MAINTENANCE_HAS_PARTS`)—— 两个方向都按名拒,而不是把件悄悄照费用记掉、让资产少计。
  > `:10850` **删除条件:** 第一次真的大修用到库里的件时,一次裁定:那些件怎么进资产成本(借 1500 / 贷 1200 的一条资本化出库,还是先出给保养再改分类),以及它与费用单那一笔怎么不重复。
- **Machine ↔ part list** — `:10852-10856` `MES7A2-NO-MACHINE-PART-LIST-OR-CRITICALITY`:
  > `:10854` **是什么:** 旧的 `material_kinds` 说明许诺备件"挂在一台机器上、有关键度";MES-0 两样都没有排进任何一刀。今天每一次出库通过它那一条保养记录记下了机器,
  > `:10855` 但没有一张"这台机器的推荐备件 × 关键度"的表,于是也没有"关键备件缺货"的提醒(V21 只给一种备件一个最低库存,不分机器)。
  > `:10856` **删除条件:** 第一份设备供应商的推荐备件清单到来时(V21 的同一个时刻)。

### d · The self-taken decisions of `docs/handbacks/MES-7a-2.md` §6 (titles)

1. The Chinese name of 6800 is 维修保养费 (Tim 2026-10-16: stands unless he changes it).
2. An issue's amount is the difference of two valuations.
3. A return is valued at today's landed cost.
4. No void was built for maintenance records (Tim 2026-10-16: accepted as built).
5. Capitalising is refused only while parts are still out.
6. `material_kinds` on live is not updated (Tim 2026-10-16: fold-in F12).
7. The table carries no money.
8. `spare_part_stock` — a new owner-rights read view.
9. Returns land in "unspecified location".
10. `maintenance_part` journals are `source_path`.
11. `inventory_control_reconciliation` M3 / M4 add the net maintenance quantity back.
12. One line per issue in the form.
13. The live proof prices through the engine.
14. The comment explaining the new movement types sits outside the CHECK's `IN (...)` list (Tim 2026-10-16: fold-in F13).
15. Layout fixes in MES-7a-1 files.
16. The role table uses the trial balance for "the chart of accounts".
17. Fixture 257's added term is vacuous on its own data.
18. A new throwaway prefix `mes7a2probe`.

## 3 · So

a: nothing uncovered. b: every page the brief names answers 200 with what it should show, on the deployed app and on a local rebuild; the two findings
above are recorded and registered, not caused by MES-7a-2, and do not stop step 2 (a judgement, stated). **Step 2 (MES-7b Step 0) goes ahead** (brief 1.5).
