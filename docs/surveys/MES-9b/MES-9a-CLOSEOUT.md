# MES-9a close-out (2026-10-19)

Brief: "MES-9a close-out + MES-9b build: what a supplier sees in the portal (v1.4.61)", step 1. Docs only — no code edit, no database change, no live write.
Live reads: none were needed (every reading below is from git, from the repository, or from the MES-9a session's own transcript).

**Opening check (20:47:02 CST, this session's first command).** Tree clean. After `git fetch`: `HEAD` = `origin/main` = `git ls-remote origin main` =
`44e98fdd36faae920d67b9814fe7cb1cc8b5a09e`. No git command refused.

## 1 · Broken window (1.1)

| | Time (CST) | Source |
|---|---|---|
| start | **2026-10-19 18:00:11** | measured: `db/migration-windows.tsv` (`2026-10-19-mes9a-supplier-portal-identity.sql`), printed by `apply_migration.sh` (`docs/surveys/MES-9a/readings/apply.txt`) |
| end, lower bound | **2026-10-19 20:36:11** | measured: `git reflog show --date=iso refs/remotes/origin/main` → `44e98fdd refs/remotes/origin/main@{2026-10-19 20:36:11 +0800}: update by push`; the push `4aae8e98..44e98fdd` carried only the cut's own commit `44e98fdd` (committed 2026-10-19 20:34:26, `git log 4aae8e98..44e98fdd`) |
| end, upper bound | **2026-10-19 20:47:02** | derived: this session's first command (`date`), with Tim's "deployed" already in hand. That is Tim's report of what he saw, not a reading of Vercel |

**Broken window: at least 2 h 36 min 00 s, at most 2 h 46 min 51 s.**

What was broken inside it (derived — MES-9a hand-back §14, not measured on live here): nothing in use. The deployed app was MES-9a's predecessor over the new
database. Staff tokens were byte-identical with the hook on (measured, hand-back §3–§4), no portal UI was reachable, no portal account existed on live (the live
proof's throwaways were created and removed inside the window; closing reading §11: links 0), and `user_directory` lost only portal accounts, of which there were none.

## 2 · Tim's confirmation recorded (1.2)

- **Tim confirmed (2026-10-19, in this brief) that `44e98fdd` is deployed on Vercel and that the real staff accounts sign in normally with the hook enabled.** That is Tim's
  report, not a reading this session took. The 7 real accounts were never signed in by any cut (their passwords are not ours). The sign-in path itself was proved on throwaway copies of
  each role (MES-9a hand-back §4, `MES9A_SIGNIN_EXIT=0`).
- **The hook was switched off for 39 s during MES-9a**: 18:03:53 → 18:04:32 CST (`docs/surveys/MES-9a/readings/rotation-compare.txt`). The cut measured the refresh-token rotation
  sequence with the hook off and on, and both readings were identical. It was enabled at 18:00:43 and has stayed on since 18:04:32. Already in `docs/known-issues.md`
  `MES9A-HOOK-IS-A-PROJECT-SETTING`; now also in `docs/forward-queue.md` item 58.

## 3 · Read-only verification (1.3)

### a · The MES-9a brief's fixture list, item by item

The list is the brief's "Fixtures must cover every item restated above, including:" sentence. The brief exists only in the MES-9a session transcript
(`~/.claude/projects/-Users-timchen/2336b424-….jsonl`, user message 2026-10-19T08:48:43Z), quoted here in item order. Paths: `db/fixtures/275-a-supplier-portal-account-is-one-supplier-and-reaches-only-its-own-rows.sql`
(275), `db/check_portal.py` (verdict 8), `scripts/check-trail-wording.mjs`, the MES-9a live proof `docs/surveys/MES-9a/readings/live-proof.txt` (LP).

| # | Item | Covered by | Evidence |
|---|---|---|---|
| 1 | the supplier_portal role's privileges equal to the baseline, both ways | **verdict 8** (a gate check, not a fixture) · **275 GRANTS** | `db/check_portal.py:266-271` — extra → red, missing → red, on rebuild and live; `275:352-367` — `portal_*` executable by `supplier_portal` only, the hook by `supabase_auth_admin` only, not a member of `authenticated` / `anon` |
| 2 | two suppliers' portal users each refused the other's rows in every baseline function | **275 EVERY** | `275:218-254` — loops over every function `supplier_portal` can execute (from the catalogue); A sees A and nothing of B, B the reverse; a function with no case goes red |
| 3 | a portal account refused a role or an employee link, and the reverse | **275 SEP** | `275:152-174` — role · employee · additional account refused on a portal account; an account with a role or an employee refused a link |
| 4 | creation by action.manage_portal_users only | **275 LINK** · **275 CODE** | `275:127-143` — a `module.suppliers.view` holder refused `PERMISSION_DENIED`; a direct insert refused; `:119-125` the code is an action code declaring `module.suppliers.view`, admin holds it |
| 5 | forced password change on first sign-in | **no fixture arm** — database half only: **275 VIEW** reads the flag | `275:316-320` — `supplier_portal_accounts.must_change_password` true for A. The hold itself is the middleware (`lib/supabase/middleware.ts`), proved once by LP ② (`live-proof.txt:5-9`: held on the change-password form, a reload → `/set-password`, after the change → `/portal`) |
| 6 | revocation refusing the next call | **275 REVOKE** | `275:261-278` — reason required, viewer refused, sessions ended, A's next call `PORTAL_ACCESS_REVOKED`, B unaffected, second revoke refused, the hook keeps a revoked account in `supplier_portal` |
| 7 | route separation both ways | **no fixture arm** — database half only: **275 EVERY** (a staff session calls no portal function, 42501) | `275:234-238`. The route refusals are the root layout / `moduleGuard`, proved once by LP ③ ⑦ (`live-proof.txt:13-28` seven staff routes refused for each portal user; `:47` a staff copy on `/portal` refused) |
| 8 | the hook returning unchanged claims for every staff permission set and on internal failure | **275 HOOK** | `275:176-216` — every role on the rebuild, all codes, no role, `floor_display`: byte-equal; a bad `user_id` and an unreadable table: unchanged, never raises |
| 9 | portal_export_my_data returning only the caller's data | **275 EXPORT** · **275 EVERY** | `275:256-259` — B's export has B's email and phone, no internal note, nothing of A |
| 10 | anonymisation on request | **275 ANON** | `275:280-299` — refused before revoke; contact → Anonymised, fields cleared, soft-deleted; change-log images redacted (not vacuous: ≥ 3); account id kept; second refused |
| 11 | the trail wording | **275 TRAIL** (database half) · **check-trail-wording** (the sentences) | `275:301-314` — `trail_actor` → `portal` + supplier name, `portal_actor_labels` only portal accounts, the supplier's trail lists its link; `scripts/check-trail-wording.mjs:7670-7694` — the pinned sentences, with fault `wording-drift-mes9a` |
| 12 | V38 and V40 rows | **275 VALUES** | `275:327-346` — both pending for `action.manage_permissions`, hidden from others; shape and unknown key refused by name; V38 set → only V40 pending |
| 13 | the census check's fault cells | **verdict 8 self-tests** (a gate check, not a fixture) | `db/check_portal.py:249-296` — ① unreadable baseline raises, ② blinded query reads as blindness, ③ a probe grant is named, ④ a removed baseline line goes red; coverage floors `:53`, `:195-203`; all four run on every invocation |
| 14 | the approvals width fix | **no fixture arm** | `app/settings/approvals/ApprovalsForm.tsx:130`, `:167` (`max-w-full`); proved once by the layout survey (hand-back §8) and LP fold-in (`live-proof.txt:50`, `:52`: 1280 px widths unchanged 566 / 566; 390 px 298 → 0) |
| 15 | change-log exclusions at 8 | **275 LOG** | `275:145-150` — 0 gaps, `excluded` = 8, the link change-logged; `:348-350` `account_settings` change-logged |

Fault injection: the 36 cells (31 fixture-275 cells + 5 verdict-8 cells) bit on a fresh rebuild after the last database edit
(`docs/surveys/MES-9a/readings/injections-fresh-rebuild.txt`, `INJ_OWN_EXIT=0`).

**Result: nothing is missing in the behaviour.** 12 of 15 items have a fixture arm or a gate check. **3 items have no fixture arm** (5 the forced first-sign-in hold, 7 route
separation, 14 the approvals width). Each is an application half that a SQL fixture cannot reach (no JS / HTTP runner). Each was proved once by MES-9a's own
HTTP proof or survey, and items 5 and 7 have their database half in 275. The MES-9a hand-back never mapped the brief's list item by item and does not say
that these three have no fixture. **That is a gap in the record only, not in the behaviour.** It is the `MES8B2-APP-HALF-NO-REGRESSION-CHECK` shape, registered as
`MES9A-APP-HALF-NO-REGRESSION-CHECK` (`docs/known-issues.md`), not built. **Step 2 starts.**

### b · MES-9a's decisions taken without asking (`docs/handbacks/MES-9a.md` §10), titles only

1. The hook keys on the existence of a link, revoked or not.
2. The hook falls back to the unchanged event on any error and never raises.
3. Role check = role GUC and JWT claim both `supplier_portal`.
4. No explicit schema grant.
5. Session check through `auth.sessions`.
6. Revoke ends sessions in the database and bans the Auth user.
7. Anonymisation also redacts the change log's images and replaces the Auth email.
8. The export excludes staff notes.
9. V38 / V40 are stored in `account_settings` and not enforced.
10. `user_directory` excludes portal accounts.
11. `portal_actor_labels(uuid[])` is allowlisted in the definer check.
12. The portal account in a trail is a member of the supplier's trail.
13. The census excludes system-catalogue relations and functions.
14. The PostgreSQL 16 creator membership is mirrored.
15. The middleware recognises a portal account by `app_metadata.supplier_portal`.
16. The portal's layout and refusal.
17. Smoke registers `/portal/my-data` as `[403]`.
18. The rotation assertion was corrected after measuring hook off vs on.
19. The hook is enabled through the Management API.
20. The live proof runs a local `next` with this cut's code.
21. The live proof's "held on first sign-in" assertion was changed after two runs.
