v1.4.60 — Supplier portal accounts: admin or the CCO can now give a supplier's contact a portal sign-in from the supplier page, which lands on a separate supplier portal that can only ever see that supplier's own records and none of the company's internal pages; the account is handed over with a first password that must be changed, and can be revoked at once. Staff sign-in and idle logout are unchanged.

# MES-9a — hand-back (2026-10-19) · identity and isolation

The brief "NOROLE-SURFACE close-out + MES-9a build: supplier portal identity and isolation (v1.4.60)". MES-9a answers the identity-and-isolation third of
`docs/surveys/MES-9/STEP0-HANDBACK.md` with Tim's §15 rulings: Q1 (three cuts — 9a identity and isolation, 9b, 9c) · Q2 (a separate database role
`supplier_portal`, chosen by a custom access-token hook; first act a rolled-back live dry run; Q86 fallback not needed) · Q12 (free plan, throwaway suppliers
only) · Q23 (no MFA) · Q3, Q5–Q11, Q20, Q21, Q24, Q26–Q29 as written in the hand-back. Fold-in: `/settings/approvals` at 390 px.

## ★ To disable the access-token hook — one step

The hook (`public.portal_access_token_hook`) runs on every token issue for every user. It returns every staff user's claims unchanged and never
raises; if anything about sign-in looks wrong, switch it off — **one step, either of these**:

* **Supabase dashboard** → project `wvywpohbwkiinmipmuku` → **Authentication → Hooks → "Customize Access Token (JWT) Claims hook" → Disable**
  (toggle off, save); or
* **one Management API call**:
  ```
  PATCH https://api.supabase.com/v1/projects/wvywpohbwkiinmipmuku/config/auth
  {"hook_custom_access_token_enabled": false}
  ```

Disabling it only ever narrows access: staff tokens are the same either way; a supplier portal account then gets an `authenticated` token that
reaches no portal function, and the middleware signs it out (`/login?reason=portal_unavailable`). The same text is in
`docs/fresh-install-checklist.md` step 6b. **This section and the checklist step were written before the hook was enabled** (18:00:43 CST).

## 0 · Step 1 — NOROLE-SURFACE close-out (committed and pushed first)

Commit **`4aae8e98`** "NOROLE-SURFACE close-out" (`c61acce6..4aae8e98`), fresh-clone build of that commit `CI_EXIT=0` · `BUILD_OWN_EXIT=0`. Evidence in full:
`docs/surveys/MES-9a/NOROLE-SURFACE-CLOSEOUT.md`.

- **Opening check** (16:48:51 CST, first command): tree clean; `HEAD` = `origin/main` = `git ls-remote` = `c61acce68242e29d8a8737f5977839693bd26228`.
- **Broken window closed** in `docs/forward-queue.md` (the MES-8b-2 format): start **14:46:11** (measured, `db/migration-windows.tsv`) · end lower bound
  **16:36:39** (measured, reflog of the push) · upper bound **16:48:51** (derived — this session's first command, with Tim's "deployed" already in hand; a report of
  what Tim saw, not a reading of Vercel) → **at least 1 h 50 min 28 s, at most 2 h 02 min 40 s**.
- **Tim's ruling recorded:** `NOROLE-PO-ORPHAN-FILE` is left for Tim to delete; no cut deletes it (`docs/known-issues.md`, `docs/forward-queue.md`). It is still
  there, byte-identical (§11).
- **Read-only verification:** the NOROLE-SURFACE brief's fixture list, 10 items, each mapped to an arm (items 1–8 → fixture 274 REL / OWN / TRAIL / PROMISE /
  BUCKET / NOUPDATE / DELETE and live fixture 266; 9–10 → verdict 7's self-tests and storage comparison), each with file:line; the decisions (Q21 + (a)–(j))
  matched against the shipped code. Nothing found wrong.

## 1 · Opening live readings (17:39:14 CST, `docs/surveys/MES-9a/live-readings.sql` → `readings/live-before.txt`)

Read as `postgres` (`rolbypassrls = true`) on base tables inside `BEGIN READ ONLY … ROLLBACK`.

| What | Reading |
|---|---|
| Approvals | on · L1 finance · L2 cfo · 1,000; pending: **`CLM-2026-0004`** only (not mine; raiser tim@, eligible approvers exist — see the dry run's pending list) |
| Accounts | 7 real accounts, 0 disabled: admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm; throwaways 0 |
| Codes per role | admin 85 · auditor 22 · cco 49 · cfo 36 · cto 41 · finance 43 · floor_display 1 · gm 23 · hr 8 · operations 16 · procurement 16 · sales 17 · warehouse 31; `role_permissions` md5 `e44e8194…` |
| Calibration | `require_calibrated_since` NULL |
| Portal | role `supplier_portal` absent · link table absent · `account_settings` absent |
| CODs | `COD-2026-0001` sha256 `ba299a4f…f42101` · `COD-2026-0002` `717661f6…13a4f9` |
| Storage | 19 buckets, all private · **40 objects**, listing md5 `2ff2f65e…` · 52 storage policies |
| Change log | 59,298 rows, max seq 66,215 |
| Reconciliation | AP 422,188.32 / 381,604.42 / **0.00** unexplained · AR 57,545.87 / 43,002.12 / **0.00** · inventory raw / fg **0.00** |

## 2 · What was built

- **A separate database role.** `supplier_portal` — `NOLOGIN NOINHERIT`, not a member of `authenticated` or `anon`, granted to `authenticator` (`INHERIT FALSE,
  SET TRUE`) so PostgREST can switch to it. Everything it can reach is listed line by line in `db/portal-grants-baseline.tsv` (§6).
- **The access-token hook** `portal_access_token_hook(jsonb)` (invoker, `STABLE`, executable by `supabase_auth_admin` only): if the user has a portal link — revoked
  or not — it sets `claims.role = 'supplier_portal'`; for everyone else it returns the event **unchanged**; on **any** internal error it returns the event unchanged
  (`EXCEPTION WHEN OTHERS → RETURN event`) — it never raises, so a fault in it can never stop a staff sign-in. Enabled in the project's Auth config (§4).
- **The link** `supplier_portal_users` — one auth account ↔ one supplier ↔ one contact (FKs `RESTRICT`); one live link per contact; created_by / revoked_by /
  revoke reason (required) / anonymised_at; change-logged; readable by `module.suppliers.view`. **Separation is enforced both ways** by
  `guard_portal_account_separation` on `user_roles`, `employees`, `employee_accounts` and the link itself: a portal account can hold no role, be no employee and no
  additional account; an account that has any of those can never get a link (`PORTAL_ACCOUNT_HAS_ROLE` · `_IS_EMPLOYEE` · …).
- **Portal functions** (each `SECURITY DEFINER`, each opens with `portal_require_link()`): the caller's role GUC **and** JWT role must be `supplier_portal`
  (`PORTAL_ROLE_REQUIRED`), the link must exist (`PORTAL_NOT_A_PORTAL_ACCOUNT`), not revoked and the auth user not banned (`PORTAL_ACCESS_REVOKED`), and the
  token's `session_id` must still be in `auth.sessions` (`PORTAL_SESSION_ENDED`). Executable by `supplier_portal`: **`portal_me()`** (own supplier code/name, own
  contact, sign-in email) and **`portal_export_my_data()`** (Q20 — own contact, link, account and supplier; **no staff notes**). Nothing else.
- **Staff functions** (code `action.manage_portal_users`, admin · cco, declares `module.suppliers.view`): `portal_user_create_link` (contact must belong to the
  supplier, have an email, and be the account's email; one live link per contact and per account) · `portal_user_revoke` (reason required; ends every session in
  the database at once) · `portal_contact_anonymise` (only after revoke; contact → "Anonymised", fields cleared, soft-deleted; the change log's images of that
  contact redacted). The server actions add the Auth side: create the account through the Admin API (`app_metadata.supplier_portal = true`,
  `must_change_password`), ban it on revoke (`876000h`), replace its email with `anonymised-<8>@portal.invalid` on anonymise.
- **Supplier page** `/suppliers/[id]/edit`: a "Supplier portal accounts" section — list (contact, sign-in, state, created / revoked by and when), create (contact +
  initial password, handed over in person), revoke (reason), anonymise (after revoke). Readers with `module.suppliers.view` see it; without the code the controls are
  shown, unpressable, naming the code.
- **`/portal`**: its own shell (no staff top bar, menus or search), the caller's own supplier and contact, "Download my data" (`/portal/my-data`, JSON), sign out.
  Idle logout applies exactly as for staff (the portal is not exempt).
- **Route separation**, both ways, on the server: a portal session on any staff route → the refusal page with the way back to `/portal`; a staff session on
  `/portal` → refused with the way back home; `/login` lands a portal account on `/portal`; a portal account whose token is **not** `supplier_portal` (hook off) is
  signed out with `/login?reason=portal_unavailable`.
- **`/settings/accounts`**: a line saying portal accounts are not listed here (they are on each supplier's page; `user_directory` no longer lists them), and the
  "Account settings still to be supplied" panel for **V38** (initial password validity, days) and **V40** (password minimum length, a record of the Supabase
  setting) — `account_settings`, one bootstrap row, both empty; `set_account_setting` (`action.manage_permissions`).
- **Audit trail**: the supplier's trail shows its portal accounts being created, revoked and anonymised; a portal account as an actor reads "Supplier portal ·
  <name>" (`trail_actor` + `portal_actor_labels`).
- **Fold-in — `/settings/approvals` at 390 px**: the two approver selects get `max-w-full` (the smallest change: a class on the two culprits). §8.

## 3 · Hook dry run — live, rolled back (17:51:02 CST, `db/scripts/2026-10-19-mes9a-hook-dry-run.sh` → `readings/hook-dry-run.txt`, `DRY_OWN_EXIT=0`)

The whole migration plus the hook, in one transaction on live, then `ROLLBACK`. The hook was called with the event GoTrue would send for each account; "unchanged" =
the returned event is byte-equal (`jsonb =`) to the input.

| Account | Codes | Claims unchanged | Role in the token |
|---|---|---|---|
| each of the 7 real accounts (admin@ · chooer@ · fusheng@ · phua@ · sandra@ · tim@ · vince@) — hook only, nothing signed in | — | **true** ×7 | — |
| copy of admin | 86 | true | authenticated |
| copy of cco | 50 | true | authenticated |
| copy of cfo | 36 | true | authenticated |
| copy of cto | 41 | true | authenticated |
| copy of finance | 43 | true | authenticated |
| copy of gm | 23 | true | authenticated |
| copy of warehouse | 31 | true | authenticated |
| no role | 0 | true | authenticated |
| display only (`floor_display`) | 1 | true | authenticated |
| internal failure (`user_id` not a uuid) | — | **true** (fell back, did not raise) | — |
| throwaway portal account | 0 | all other claims unchanged | **supplier_portal** |

As `supplier_portal` inside the same transaction: `portal_me()` → its own supplier; `SELECT FROM suppliers` → 42501; `current_user_permissions()` → 42501.
After `ROLLBACK`: role absent, table absent, 0 throwaway roles. (Admin's and cco's code counts are 86 / 50 here and in every later reading because the migration
adds `action.manage_portal_users` to both.)

Every pending document has an eligible approver other than its submitter (the dry run lists them): `CLM-2026-0004` → tim@ · `MC-2026-0001` (pay) → admin@,
chooer@ · stocktakes `ST-2026-0082…0089` → chooer@.

## 4 · Migration, hook enabled, sign-in checks

- **Migration dry run** COMMIT→ROLLBACK (17:54:15, `readings/migration-dry-run.txt`, `DRY_OWN_EXIT=0`): inside — tables 323, codes 86, `supplier_portal` executes
  `portal_export_my_data, portal_me`, `manage_portal_users` holders `admin, cco`, pending V38/V40 rows 2; after rollback — role absent, tables 321.
- **Backup** before it: `BACKUP_EXIT=0` (17:30 → 17:50, 9.0 MB, TOC 9,669 entries).
- **Apply** (`readings/apply.txt`, `APPLY_OWN_EXIT=0`): pre-flight passed (14 functions: 3 replaced, 11 new); **committed 18:00:11 CST — the broken window starts here**
  (`db/migration-windows.tsv`).
- **Hook enabled** 18:00:43 CST through the Management API (`PATCH …/config/auth` with `hook_custom_access_token_enabled: true` and
  `hook_custom_access_token_uri: pg-functions://postgres/public/portal_access_token_hook`); only the two `hook_*` fields were ever printed.
- **Immediately after: sign-in and refresh as every copy** (`db/scripts/2026-10-19-mes9a-signin-checks.mjs`). First run (18:01, `readings/signin-checks.txt`): every
  sign-in, every refresh and every idle check **passed**; the script then stopped (`MES9A_SIGNIN_EXIT=3`) on **my own wrong assertion** about refresh-token reuse —
  it expected the just-rotated parent to be refused, and GoTrue returned 200. That is not a sign-in failure, so the hook was not left disabled; instead I measured the
  same sequence **with the hook off and on** (`readings/rotation-compare.txt`: hook off 18:03:53 → on 18:04:32): **identical** both ways — reusing the parent of the
  active token returns the active child (200); reusing a grandparent → 400 `refresh_token_already_used`. The assertion was corrected to that (GoTrue's own reuse
  interval behaviour) and the checks rerun.
- **Second run** (18:05:28, `readings/signin-checks-2.txt`, **`MES9A_SIGNIN_EXIT=0`**):

| Account (throwaway copy) | Sign-in | Codes | Refresh | Rotation | Idle |
|---|---|---|---|---|---|
| admin | ok · authenticated | 86 | ok · rotated | grandparent → 400, active → 200 | 29 min → `/` 200 · 31 min → 307 `/login?reason=ended` |
| cco | ok · authenticated | 50 | ok | same | same |
| cfo | ok · authenticated | 36 | ok | same | same |
| cto | ok · authenticated | 41 | ok | same | same |
| finance | ok · authenticated | 43 | ok | same | same |
| gm | ok · authenticated | 23 | ok | same | same |
| warehouse | ok · authenticated | 31 | ok | same | same |
| display only | ok · authenticated | 1 | ok | same | 31 min → `/display` 200 (exempt, as before) |
| portal (throwaway) | ok · **supplier_portal** | — (`current_user_permissions` 403) | ok · supplier_portal | same | the portal's idle logout is app code — §5 |

No staff sign-in or refresh failed at any point, so the hook stayed on (apart from the 39 s measurement above).

## 5 · Live verification (20:20:43–20:29:44 CST, `db/scripts/2026-10-19-mes9a-live-proof.mjs` → `readings/live-proof.txt`, **`MES9A_PROOF_EXIT=0`**)

Over HTTP, against live, on a local `next start` (port 3196) built from this cut's tree (the app code is not deployed until the push); browser
chrome-headless-shell. Every account and record is a throwaway (prefix `mes9aprobe`, suppliers `ZZ-PROBE`), each registered for deletion before or the moment it
exists; none of the 7 real accounts was used. Every line below is a `PASS` in the log.

| # | What | Result |
|---|---|---|
| ① | A cco clone (50 codes) opens two throwaway suppliers' pages (A `SUP-2026-0453`, B `SUP-2026-0454`), each with a throwaway contact, and creates a portal account for each contact **through the page** | both created ("Portal account created for … Hand the initial password …"); one link each |
| ② | Each portal user signs in on `/login` with the initial password | **held on the change-password form**; after a reload the address is `/set-password` (navigations `/login → /login → /portal → /set-password → /set-password`); after changing the password it lands on **`/portal` showing its own supplier**; token role **`supplier_portal`** |
| layout | `/portal` as a portal user | page overflow **0 px at 390** and **0 px at 1280** |
| ③ | Each portal session on `/` · `/suppliers` · `/settings/accounts` · `/me` · `/finance/journal` · `/inventory` · `/suppliers/<own>/edit` | each **refused** (the refusal page, no staff navigation, way back to `/portal`); `/portal` shows its own supplier and nothing of the other's (code, name, email) |
| ④ | Through PostgREST with each portal token: `portal_me` · `portal_export_my_data` | **own supplier / own data only** — nothing of the other |
| ④ | Every relation a no-role session can read (`db/norole-surface-baseline.tsv` rows) + the internal ones (roles, permissions, prices, accounts, suppliers, contacts, links, POs, inbound, COD/PO issues …) — 57 relations | **refused all** (none returned a row, none returned an empty 200) |
| ④ | Staff functions `current_user_permissions` · `session_is_floor_display_only` · `approvals_enabled` · `portal_actor_labels` | **refused all** |
| ④ | Storage: list each of the 19 buckets | **lists nothing** |
| ⑤ | `/portal/my-data` | 200 `application/json`, **its own data only** |
| ⑥ | The cco clone revokes A **through the page** (reason given) | row state `revoked`; **A's still-unexpired token → HTTP 400 `PORTAL_ACCESS_REVOKED`** on the next call; A signs in again → **400 `user_banned`**; A's browser session on `/portal` → 307 `/login?reason=ended`; **B still works** (`portal_me` 200) |
| ⑥b | The cco clone anonymises A's contact through the page (after the revoke) | contact "Anonymised", email cleared, `anonymised_at` set; A's sign-in email → `anonymised-061e0eb6@portal.invalid`; account kept |
| ⑦ | A staff session (the cco clone) on `/portal` | **refused** |

**Two earlier runs** of the same script (19:59, 20:10 — `readings/live-proof-run1.txt`, `-run2.txt`) each ended `MES9A_PROOF_EXIT=1` on **one assertion, ② "held
on /set-password"**, for both A and B; every other line passed. The assertion read the address bar. Run 2 recorded it: the change-password form **was** on screen
while the address said `/portal`. To tell whether that was the portal's doing I ran the same first sign-in with a throwaway **staff** account (gm clone,
`must_change_password` set) — `db/scripts/2026-10-19-mes9a-first-signin-address.mjs` → `readings/first-signin-address.txt`, `MES9A_ADDR_EXIT=0`: **identical** —
form on screen, address `/` (its landing path), after a reload `/set-password`. It is the existing shape of the login action's `redirect()` followed by the
middleware's redirect, not this cut's; the assertion was changed to what holding someone actually means (form on screen, and a reload goes to `/set-password`),
and run 3 above passed. Registered as `MES9A-FIRST-SIGNIN-ADDRESS`. Each run's throwaways were removed (closing reading, §11).

## 6 · `supplier_portal` privileges — the baseline, line by line (`db/portal-grants-baseline.tsv`, verdict 8)

| Kind | Object | Privilege |
|---|---|---|
| role | `supplier_portal` | nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls |
| held by | `authenticator` | member, admin=false inherit=false set=true |
| held by | `postgres` | member, admin=true inherit=false set=false (PostgreSQL 16 makes a non-superuser creator an ADMIN member automatically; grantor `supabase_admin`) |
| schema | `public` · `pg_catalog` · `information_schema` | USAGE (PUBLIC defaults — nothing granted) |
| function | `public.portal_me()` | EXECUTE |
| function | `public.portal_export_my_data()` | EXECUTE |

**That is all.** No table, view, sequence, column or policy; not a member of any role. Verdict 8 (`db/check_portal.py`, `db/gate.py` exit 8) enumerates the role's
reach from the catalogue — attributes, memberships both ways (with their options), schemas, relations, columns, functions, policies — on live **and** on the rebuild
and requires it to equal this file line for line: one more is red, one fewer is red. Floors (≥300 relations, ≥400 functions examined) and four always-on injection
cells (unreadable baseline · blinded query · a probe grant · a removed line) run on every invocation.

## 7 · Role table — who sees the portal section, who can create (throwaway clones, read-only; `readings/live-proof.txt` `ROLES|` lines)

Each of the 7 live roles cloned code for code into a throwaway account, which opens supplier B's page and `/settings/accounts`. Nothing is written.

| Role (clone) | Codes | Supplier page | Portal accounts section | Can create (`action.manage_portal_users`) | `/settings/accounts` | Portal note + V38/V40 panel |
|---|---|---|---|---|---|---|
| admin | 86 | 200 | sees | **yes** | opens | both shown |
| cco | 50 | 200 | sees | **yes** | refused (as before — no `action.manage_permissions`) | — |
| cfo | 36 | 200 | sees | no — shown, unpressable, names the code | refused | — |
| cto | 41 | 200 | sees | no — shown, unpressable, names the code | refused | — |
| finance | 43 | 200 | sees | no — shown, unpressable, names the code | refused | — |
| gm | 23 | 200 | sees | no — shown, unpressable, names the code | refused | — |
| warehouse | 31 | 200 | sees | no — shown, unpressable, names the code | refused | — |

All seven hold `module.suppliers.view`, so all seven see the section; only admin and cco can create, revoke or anonymise.

## 8 · Layout

Survey (`.survey-out/`, not committed) at 390 and 1280 px, page overflow:

| Page | Before | After |
|---|---|---|
| `/settings/approvals` 390 px | **+117 px** (survey; culprit: the two approver selects, sized by their longest option) | **0 px** |
| `/settings/approvals` 1280 px | 0 | 0, select widths unchanged (566 / 566 px) |
| `/portal` (staff session → refusal) | — | usable at 390 and 1280 |
| `/suppliers/42951a0a-…/edit` (SUP-2026-0003), portal section | — | usable at 390 and 1280 |
| `/settings/accounts` | — | usable at 390 and 1280 |
| `/portal` as a portal user | — | 0 px at 390 · 0 px at 1280 (live proof) |

**The approvals fix, measured on one DOM** (live proof, admin clone): with the class removed / present / put back — **1280 px**: selects 566 / 566 · 566 / 566 ·
566 / 566 px, page overflow 0 · 0 · 0 (the fix changes nothing on a desktop); **390 px**: selects 639 / 639 → 292 / 292 → 292 / 292 px, page overflow **298 → 0 → 0**.
298 there and 117 in the survey are both measurements of the unfixed page; they differ because the select is as wide as its longest role name and the roles list
differs between the two moments (the proof's own throwaway roles were in it — derived, not itemised). NOROLE-SURFACE had measured 114 px.

## 9 · Pages (route → file)

| Route | New / changed | Files |
|---|---|---|
| `/portal` | new | `app/portal/layout.tsx` · `app/portal/page.tsx` · `app/portal/portalErrorCodes.ts` |
| `/portal/my-data` | new (JSON download) | `app/portal/my-data/route.ts` |
| `/suppliers/[id]/edit` | changed — portal accounts section | `app/suppliers/[id]/edit/page.tsx` · `PortalAccountsPanel.tsx` · `PortalAccountForms.tsx` · `portalActions.ts` |
| `/settings/accounts` | changed — portal note, V38 / V40 panel | `app/settings/accounts/page.tsx` · `AccountSettingsPanel.tsx` · `accountSettingsActions.ts` |
| `/settings/approvals` | changed — 390 px fit | `app/settings/approvals/ApprovalsForm.tsx` |
| `/login` | changed — portal landing, `portal_unavailable` notice | `app/login/page.tsx` · `app/login/actions.ts` |
| `/set-password` | changed — portal lands on `/portal` | `app/set-password/actions.ts` |
| every route | changed — portal/staff separation, no staff chrome for portal | `lib/supabase/middleware.ts` · `app/layout.tsx` · `app/components/moduleGuard.tsx` · `lib/loginRoute.ts` · `lib/portalSession.ts` |
| every audit trail | changed — portal actor label, supplier trail members | `app/components/ActorName.tsx` · `lib/trail/render.ts` · `lib/trail/text.ts` · `lib/trail/catalogue.generated.ts` · `lib/deepRoutes.generated.ts` |

## 10 · Decisions taken without asking

1. **The hook keys on the existence of a link, revoked or not.** A revoked account still gets `supplier_portal` (never `authenticated`), so revoking can never widen
   it into a no-role staff session; it is refused by `portal_require_link` and banned in Auth.
2. **The hook falls back to the unchanged event on any error and never raises** — the brief's sign-in-safety rule, which I took to override Step 0 §12's "fail
   closed" for the hook. The fail-closed half lives in `portal_require_link`, which every portal function calls.
3. **Role check = role GUC and JWT claim both `supplier_portal`.** Either alone is weaker (a definer function sees its owner as `current_user`, so `current_user` is no
   test; `current_setting('role')` is unchanged inside definer).
4. **No explicit schema grant** — `supplier_portal` uses `public` through PostgreSQL's PUBLIC default; Q27 "only what the dry run needs".
5. **Session check through `auth.sessions`** (the token's `session_id` must still exist) — that is what makes "revoke → next call refused" immediate rather than at
   token expiry.
6. **Revoke ends sessions in the database and bans the Auth user** (`876000h`) — the ban stops new sign-ins and refreshes; deleting the sessions stops the token
   already in the browser.
7. **Anonymisation** also redacts the change log's images of that contact (`change_log_redactable_columns` + the contact's columns) and replaces the Auth email with
   `anonymised-<8>@portal.invalid`; the account itself is kept (it is the actor of past rows).
8. **The export excludes staff notes** about the contact.
9. **V38 / V40 are stored in `account_settings`** and **not enforced** (`MES9A-V38-NOT-ENFORCED`, `MES9A-V40-IS-A-RECORD`).
10. **`user_directory` excludes portal accounts**; `/settings/accounts` says where they are instead.
11. **`portal_actor_labels(uuid[])` is allowlisted in the definer check** (it raises without a user, and labels only portal accounts — a display label, the
    document-follows-the-row rule).
12. **The portal account in a trail is a member of the supplier's trail**, and its actor label is shown, not "Restricted".
13. **The census excludes system-catalogue relations and functions** (PUBLIC defaults, identical for every role, metadata only, not exposed by PostgREST); their
    schema USAGE is listed.
14. **The PostgreSQL 16 creator membership is mirrored** in `db/platform-prelude.sql` and in the baseline (found by verdict 8 going red on live — §12).
15. **The middleware recognises a portal account by `app_metadata.supplier_portal`** (set by the create action, not editable by the user) to sign it out when its
    token is not `supplier_portal`.
16. **The portal's layout and refusal**: no staff chrome at all; the same refusal component as staff refusals, with the way back pointing to `/portal`.
17. **Smoke registers `/portal/my-data` as `[403]`** — the smoke's session is staff, and 403 is the route's correct answer to it.
18. **The rotation assertion was corrected after measuring hook off vs on** (§4); the hook was disabled for 39 s for that measurement.
19. **The hook is enabled through the Management API**, not the dashboard (the same setting; the one-step disable works either way).
20. **The live proof runs a local `next` with this cut's code** against live (the app code is not deployed until the push); accounts created through the page are
    registered for deletion the moment they exist.
21. **The live proof's "held on first sign-in" assertion was changed after two runs**, from "the address is `/set-password`" to "the change-password form is on
    screen and a reload goes to `/set-password`", **after** a staff throwaway showed the same address-bar shape (§5). The address-bar behaviour is registered, not
    fixed (`MES9A-FIRST-SIGNIN-ADDRESS`) — fixing it changes the staff login path.

## 11 · Closing live readings (20:30:04 CST, the same `live-readings.sql` → `readings/live-after.txt`, `READ_OWN_EXIT=0`)

Diffed line by line against the opening reading (§1). **Every difference is the migration:** admin 85 → 86 and cco 49 → 50 codes, `permissions` 85 → 86,
`role_permissions` 388 → 390 rows (md5 changed accordingly), `supplier_portal` role present, links **0**, `account_settings` NULL / NULL, holders admin · cco, tables
321 → 323, views 197 → 198 (writable pairs 0), pending arms 34 → 36 — and the change log, 59,298 → 64,239 rows (append-only; the smoke's, the proofs' and the
throwaways' rows, plus anyone else working on live).

**Unchanged:** 7 accounts, 0 disabled, each with its role (admin@ admin · chooer@ finance · fusheng@ warehouse · phua@ cto · sandra@ cco · tim@ cfo · vince@ gm) —
enabled and unbanned; they were not signed in (their passwords are not mine), the sign-in path itself was proved on their copies (§4) · throwaways: probe roles
0, `test.local` accounts 0, `mes9aprobe` accounts 0, `ZZ-PROBE` suppliers 0, contacts 0, orphan grants 0 · portal links 0 · contacts fingerprint identical ·
pending: `CLM-2026-0004` only (not mine; none of mine pending) · `require_calibrated_since` NULL · both CODs' recorded sha256 and their objects' eTags identical ·
**all 40 stored objects identical** (every line, md5 `2ff2f65e…`), including `NOROLE-PO-ORPHAN-FILE` · 19 buckets, all private · 52 storage policies ·
every other table fingerprint identical · reconciliation AP **0.00** · AR **0.00** · inventory raw **0.00** · fg **0.00** unexplained.

**The hook** (20:30:43, Management API, only the two `hook_*` fields read): enabled, `pg-functions://postgres/public/portal_access_token_hook`.

**Smoke's scratch reading** (at its start, `readings/smoke.txt`): 6 stale `ZZ-SMOKE` rows, 1,132–1,775 h old, five still referenced — **pre-existing, not mine,
not touched**; the same six as the first smoke run.

## 12 · Things found

- **PostgreSQL 16 creator membership.** `CREATE ROLE supplier_portal` run by `postgres` (not a superuser on Supabase) makes `postgres` an ADMIN member of it
  (inherit false, set false, grantor `supabase_admin`). Verdict 8 went red on live for exactly that line; it is now recorded with its options and the rebuild prelude
  grants the same membership.
- **First sign-in address bar** (`MES9A-FIRST-SIGNIN-ADDRESS`): held on the change-password form, the address shows the login's landing path until a reload — for
  staff exactly as for the portal (§5).
- **GoTrue refresh reuse.** Reusing the parent of the active refresh token returns the active child (200); only a grandparent is refused. Identical with the hook on
  and off — it is GoTrue's own behaviour, not something this cut changed.

## 13 · Verification, in the brief's order

| # | Step | Result |
|---|---|---|
| 1 | offline gate (`db/gate.py --offline`) | `GATE_EXIT=0` (127 s) |
| 2 | backup (background) | `BACKUP_EXIT=0` |
| 3 | hook / role live dry run, rolled back | `DRY_OWN_EXIT=0` (§3) |
| 4 | migration dry run COMMIT→ROLLBACK | `DRY_OWN_EXIT=0` (§4) |
| 5 | apply | `APPLY_OWN_EXIT=0`, window start 18:00:11 |
| 6 | enable hook + immediate sign-in / refresh checks | enabled 18:00:43; `MES9A_SIGNIN_EXIT=0` (second run; §4 for the first) |
| 7 | types | `TYPES_OWN_EXIT=0` |
| 8 | tsc | `TSC_OWN_EXIT=0` |
| 9 | build | `BUILD_OWN_EXIT=0`; rebuilt after every later file change — last 20:31 (`BUILD_OWN_EXIT=0`) |
| 10 | full gate | `GATE_EXIT=0` (717 s): colgrant live / rebuild 521 relations in 14 batches, 40 masked · viewwrite 198 both sides · change log 323 / 315 / 8 · fixture 275 ✓ · live fixtures ✓ · anon 327 · no-role 126 · **portal (verdict 8) 8 lines equal on both sides** |
| — | injections on a fresh rebuild after the last DB edit | **36 / 36 bit** (31 fixture-275 cells + 5 verdict-8 cells), `INJ_OWN_EXIT=0` (`readings/injections-fresh-rebuild.txt`) |
| 11 | i18n | `I18N_OWN_EXIT=0` |
| 12 | error swallowing | `SWALLOW_OWN_EXIT=0` |
| 13 | layout survey | §8 |
| 14 | smoke | first run `SMOKE_EXIT=1` — the only failure `/portal/my-data` → 403, which is the route's correct answer to the smoke's staff session; registered `[403]` (decision 17) and rerun: **`SMOKE_EXIT=0`**, 299 ok · 25 skipped (no data) · 0 failed, 273 timed, median 4,696 ms (`readings/smoke.txt`) |
| 15 | live verification | §5, `MES9A_PROOF_EXIT=0`; closing reading §11 |
| 16 | fresh-clone build of the commit being pushed | §15 |

Files changed after the full gate: `scripts/smoke-routes.mjs` (one expected status), the two proof scripts under `db/scripts/`, docs and readings — none is read by
the database half of the gate; the static half runs inside `npm run build`, rerun after the last of them (step 9).

## 14 · Broken window

Start **2026-10-19 18:00:11 CST** (measured, `db/migration-windows.tsv`). End = the moment Tim sees the deploy succeed in Vercel (a report, filled in at the next
close-out). **What is broken inside it** (derived): the deployed app is MES-9a's predecessor over the new database — staff pages work as before (the hook leaves
staff tokens unchanged, measured §4); there is no portal UI to reach and no portal account exists; `user_directory` no longer lists portal accounts (there are none).
Nothing in use is broken.

## 15 · Commit, fresh-clone build, push

One commit, staged by explicit path (`.survey-out/` and `.next/` are not committed). Before the push: `git clone` into a scratch directory outside the repository,
checkout of **the commit being pushed**, no `.env.local`, `npm ci`, `npm run build`, judged only by each command's own exit code written into its log; the local
server started for the live proof was stopped before that build (3196: 0 listeners). A file cannot carry the result of building itself, so that result — and
`HEAD` · `origin/main` · `git ls-remote origin main` after the push — is in the report that closes this cut, not here.
