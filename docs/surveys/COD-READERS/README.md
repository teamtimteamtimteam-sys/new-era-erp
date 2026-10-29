# COD-READERS + LOGISTICS-MODULE — readings (2026-10-29, v1.4.81)

Brief: "COD-READERS — let cfo, cco, cto, finance and gm read certificates of destruction (read-only); make the budget-refusal rule permanent".
Tim's rulings of 2026-10-29 (12:49 CST reply to Step 0: grilling changes 1–8 accepted, Q1 (a), added scope D — Logistics as its own module) are
recorded verbatim at the end of `docs/system-map.md`. Started from `c5d01a11270ea20f2c21e1a8d1f17e782a491788`. One migration: `db/migrations/2026-10-29-cod-readers.sql`.

**Identity of every reading:** database reads were row counts and digests as `postgres` (`rolbypassrls`) on base tables; the dry run read as the real
cfo (tim@) and warehouse accounts and as a session with no role, inside one rolled-back transaction; the reconciliation line as tim@ (rolled back);
COD bytes through the Storage API (list + GET). Pages were read in a real browser through throwaway accounts made by the shared helper
(`scripts/ephemeral.mjs`, prefixes `codrprobe` / `survey` / `smoke`), each a clone of one real role's codes, one reader at a time; nothing was
pressed except menus. **No sub-agent was started in this cut.**

## Verify chain (each verdict is the script's own exit line)

| # | step | reading |
|---|---|---|
| 1 | offline gate | `GATE_OWN_EXIT=0` (`readings/gate-offline-1.txt`) |
| 2 | backup | `BACKUP_EXIT=0` — main dump 1,606 s, TOC 10,010 (previous 10,004), 22 change_log chunks, row and seq totals equal (`readings/backup.txt`) |
| 3 | live dry run (COMMIT→ROLLBACK) | `DRY_OWN_EXIT=0` (`readings/dry-run.txt`, script `db/scripts/2026-10-29-cod-readers-dry-run.py`): cfo 0 → 3 certificates · 2 file records · 2 stored objects; warehouse 3 · 2 · 2 before and after; no-role session 0 · 0 · 0; postgres digests of every certificate, file record and stored object identical before and after; the migration's own proof `COD_READERS_PROOF ok` |
| 4 | apply | `APPLY_OWN_EXIT=0`, **broken window from 2026-10-29 13:39:08 CST** (`readings/apply.txt`, `db/migration-windows.tsv`) |
| 5 | types | regenerated, byte-identical to `lib/database.types.ts` (no column or function changed) (`readings/types.txt`) |
| 6 | tsc · build | `TSC_OWN_EXIT=0` · `BUILD_OWN_EXIT=0` (`readings/tsc.txt`, `build.txt`; rebuilt on the final code before the proof: `build-final.txt`) |
| 7 | full gate | `GATE_EXIT=0`, three verdicts 865 s, fixtures 195 · 274 · 297 and live fixtures 265 · 297 ✓ (`readings/gate-full.txt`); re-run after the last change: `readings/gate-full-final.txt` |
| 8 | i18n · error-swallowing · single home | `I18N_OWN_EXIT=0` · `SWALLOW_OWN_EXIT=0` · `SINGLEHOME_OWN_EXIT=0` (141 entries, each exactly one home, 12 modules with menu entries) |
| 9 | layout survey | `/compliance/cod`, `/logistics`, `/sales`, the batch pages of COD-2026-0001 and of the pending certificate: **390 px 5/5, 0 overflow, 0 clipped**; **1280 px 5/5, 0 / 0** (`readings/layout-390.txt`, `layout-1280.txt`) |
| 10 | smoke | **`SMOKE_EXIT=1`: 343 ok · 25 skipped (no data) · 1 FAILED** — `/` → HTTP 503 with `data-auth-indeterminate`: the dev server's call to Supabase auth hit `ConnectTimeoutError … supabase.co:443, timeout 10000ms` (the smoke's own words: "auth unreachable, not this page broken"); `NETRETRY_TOTAL=0` (`readings/smoke.txt`). Watchdog (abort rules once a minute, anchored to the smoke's node process): never fired; in-database `select 1` ≤ 1.2 ms, db / rest healthy every minute; 4 single round trips over 1.5 s recorded (1,527–1,588 ms) (`readings/smoke-watchdog.txt`). Not re-run; `/` rendered for all seven readers in the live proof below |
| 11 | live proof | `CODR_PROOF_EXIT=0`, **106 PASS, 0 FAIL**, 2 warnings (single round trips 1,945 ms before cfo, 1,589 ms before finance), **0 budget refusals** (`readings/live-proof.txt`, JSON beside it). A first run was stopped by me after admin's first menu check (`readings/live-proof-run1-stopped.txt`, `CODR_PROOF_EXIT=143`): the script compared the Finance menu in array order, but Finance renders by its third-level groups; fixed to compare the rows as a set (order is still checked exactly for Logistics and Sales). Residue after the stopped run: 0 throwaway users, roles or grants |
| 12 | COD bytes | `COD_OWN_EXIT=0`: 34,701 `ba299a4f…f42101` and 34,746 `717661f6…13a4f9`, equal to the AGENTS.md baseline and to `cod_issues.sha256` (`readings/cod-bytes.txt`) |
| 13 | read-back | `READBACK_OWN_EXIT=0`: 7 users / 7 enabled, roles held admin · cco · cfo · cto · finance · gm · warehouse, 1 active cfo grant, 0 throwaway users / roles / orphan grants, approvals ON finance/cfo/1000, `require_calibrated_since` NULL, `data.view_cod` held by the seven ruled roles, reconciliation AP 0.00 · AR 0.00 unexplained (`readings/readback.txt`) |
| 14 | wrap check | `check-policy-permission-wrap` now accepts `(SELECT public.has_permission(…))` (storage policies name the schema); injection: the new storage policy unwrapped → red on that policy (`INJECTED_OWN_EXIT=1`), restored byte-identical → green (`readings/wrap-check-injection.txt`) |
| 15 | fresh clone, no `.env.local` | `readings/fresh-clone-build.txt` |

## Every place that decides who sees a COD (scope B)

| place | before | after |
|---|---|---|
| `certificates_of_destruction` read policy | `action.issue_cod` | `data.view_cod` |
| `cod_issues` read policy (PDF route reads the stored path and digest here) | `action.issue_cod` | `data.view_cod` |
| `cod-documents` storage read policy | `cod-documents read by issue_cod` (unwrapped) | `cod-documents read by view_cod`, `(SELECT public.has_permission('data.view_cod'))` |
| `/compliance/cod` gate (`lib/modules.ts`, `FN.codList`) | `action.issue_cod` | `data.view_cod` |
| PDF route GET `?cod=` (`app/inbound/[id]/cod/pdf/route.tsx`) | the three policies above | unchanged code, follows them |
| Certificate panel on `/inbound/[id]/edit` | drawn only for `action.issue_cod` | drawn for `data.view_cod`; write controls, internal copy and the "why not ready" reason only for `action.issue_cod` |
| Global search, "N more" count, related records, `/documents/cod` + export (`document_types.cod.view_permission`) | `action.issue_cod` | `data.view_cod` |
| Change history on the batch page (`record_trail`, COD and file-record events) | follows the table policies | follows them (readers now see those events) |
| Chain bar | no COD step in `lib/chains.ts`, 0 relation arms | — |
| Inbound list COD column (`app/inbound/inboundRows.ts`) | `action.issue_cod` | **unchanged** (feeds only the write-off button) |
| Write: issue (POST route + `issue_cod`), void request (`submit_cod_void_request`), void, refresh (automatic), `cod_certificate_data`, storage upload / delete, withdrawing a void request (`/inventory`) | `action.issue_cod` | **unchanged** |

## Per role (live proof, one reader at a time)

| role | `/compliance/cod` | detail (batch-page panel) | PDF (both issued) | write controls |
|---|---|---|---|---|
| admin | 3 rows, 2 PDF links | issuer panel | 200, bytes = baseline | Issue on the pending one · void request on both issued · internal copy on the pending one |
| warehouse | 3 rows, 2 PDF links | issuer panel | 200, bytes = baseline | same as admin |
| cfo | 3 rows, 2 PDF links | read-only panel | 200, bytes = baseline | none (0 buttons, no internal copy, read-only line shown) |
| cco | 3 rows, 2 PDF links | read-only panel | 200, bytes = baseline | none |
| cto | 3 rows, 2 PDF links | read-only panel | 200, bytes = baseline | none |
| finance | 3 rows, 2 PDF links | read-only panel | 200, bytes = baseline | none |
| gm | 3 rows, 2 PDF links | read-only panel | 200, bytes = baseline | none |

Every role: the bar is the ten buttons in order; every rendered row sits under exactly one module and matches the registry (open / restricted);
the Logistics menu is /logistics · containers · forwarders · lanes · shipping · /finance/freight, the Sales menu is /sales · quotes · orders · customers ·
commissions (restricted rows per role as the registry says); the 390 px drawer shows ten module rows plus Tools and Settings with no sideways overflow;
`/documents/cod` opens.

## Bar widths (scope D), page with the search box (`/tools/calendar`)

| width | en | zh |
|---|---|---|
| 1024 | menu drawer (forced row: last button 952 px over a right group at 760 px) | menu drawer (forced row would fit: 703 / 760) |
| 1280 | module row, 801.1 px; last button 952 px, right group 976 px — 24 px spare | module row, 552 px; 703 / 976 — 273 px spare |
| 1366 | 952 / 1062 — 110 px spare | 703 / 1062 |
| 1440 | 952 / 1136 — 184 px spare | 703 / 1136 |

Narrowest width where the row fits: 1256 px (en) · 1007 px (zh) — both below 1280, so the single breakpoint stays `xl` (1280). No sideways page scroll at any width.
Readings: `readings/widths-1.txt` (before the full gate) and the G lines of `readings/live-proof.txt` (identical numbers).
