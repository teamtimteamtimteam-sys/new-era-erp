# MES-9 Step 0 — the supplier portal (2026-10-19)

**STOP GATE.** Read-only survey and grilling. No code edit, no migration, no live write (the step-1 close-out's throwaways are in
`MES-8b-2-CLOSEOUT.md` and are gone). ~~Waiting on Tim's answers to Q0–Q30 (§12).~~ **Answered by Tim 2026-10-19 — closed rulings in §15.**

Tags: **[M]** measured (file:line, a grep, or a named live query with its identity) · **[I]** inferred · **[R]** a standing ruling · **[D]** from vendor
documentation (fetched 2026-10-19; Supabase docs carry no version date).

**Live readings** (read-only, `BEGIN READ ONLY … ROLLBACK`): `live-readings.sql` (as `postgres`, `rolbypassrls = true`, catalog + base tables, 10:21–10:31
CST, `READ_OWN_EXIT=0`) and `norole-session-readings.sql` (as **`authenticated` with the JWT of a random uuid that has no account, no role, no employee** —
RLS applies — 10:26 CST, `READ_OWN_EXIT=0`). Auth configuration: Management API `GET /v1/projects/<ref>/config/auth` (non-secret keys only) and the public
`GET /auth/v1/settings` with the anon key.

---

## Step 1 — MES-8b-2 close-out (full evidence: `MES-8b-2-CLOSEOUT.md`; committed and pushed as `2aadbdc8` "MES-8b-2 close-out")

- **Opening check:** tree clean; `HEAD` = `origin/main` = `git ls-remote origin main` = `4236db6a01d3328ed18cf9a594d9a18f5dd13b6f`; no git command refused.
- **1.1 Broken window:** start 2026-10-17 13:42:39 CST (measured) → end between 2026-10-19 09:49:03 (push, measured) and 09:59:02 (this session's first
  command; rests on Tim's "deployed") = **44 h 06 min 24 s – 44 h 16 min 23 s**. Long because the commit and push came two days after the migration.
  Landed on live inside it: only MES-8b-2's own throwaways (13:58–14:35, INSERT = DELETE per table); **0 change-log rows from 10-17 14:35:26 to this
  session**. Deployed app = `4236db6a`'s code (measured).
- **1.2** Tim's ruling recorded: `data.view_floor_board` held by floor_display · admin · cfo accepted as built (`docs/forward-queue.md` item 57,
  `docs/role-matrix.md` two rows).
- **1.3 SESSION-1 manual repro, deployed app, real browser, one throwaway account — all five steps PASS, no session regression.** Step 2 collides with an
  existing location's code (a new location could never be removed — no hard-delete path); step 4's successful submission is the avatar upload + removal
  on `/me` (another module; the only record is an object named after my own throwaway uid, removed); step 5 (`expires_at` an hour in the past) made the
  server refresh the session, and every assertion held again.
- **1.4 a** 14 fixture-list items: 8 by a fixture arm (271 KIND, 273 COUNTS / GATE / IDLE / V28 / LOG), 4 by a fixture for the database half only, **2 by no
  fixture** (other routes refusing a display session; the month-end width) — application halves proved once by MES-8b-2's HTTP proof and survey and
  re-measured today. A gap in the record, not in the behaviour: registered `MES8B2-APP-HALF-NO-REGRESSION-CHECK`, not built.
- **1.4 b** deployed app: display account `/display` 200 with 23 count tiles, "Refreshed at"; six other routes each the display refusal linking to
  `/display`; admin · cfo see the board + V28 panel, finance · warehouse refused; price exposure for admin · cfo · finance lists "Kind not stated — 23
  batch(es), 119,104 kg" with "Incomplete", warehouse refused; month-end at 390 px overflow 0 for all four clones. **Nothing missing or not working.**
- **1.4 c** the 16 decisions listed by title in the close-out §4 c.
- **1.5** first fresh-clone build of the commit went red on the eslint freeze gate (two unused variables in my own probe script) — fixed, amended before
  push; second fresh clone `CI_EXIT=0`, `BUILD_OWN_EXIT=0`; pushed `4236db6a..2aadbdc8`.
- Residue afterwards: 0 throwaway accounts, 0 probe roles, 0 `floor_display` holders, 0 orphan grants or avatar objects; 7 accounts enabled, roles unchanged.

---

## §0 · What the survey changed in MES-9's scope

1. **Urgent, independent of MES-9: public sign-up is open on live** [M]. `disable_signup = false`, `mailer_autoconfirm = true`, email provider on — read
   both from the Management API and from the public `/auth/v1/settings` with the anon key, i.e. **what any visitor sees**. The repo's own install
   checklist says to turn it off (`docs/fresh-install-checklist.md:84`, step 6, verified on a throwaway project 2026-08-02 `:215`); live never was.
   The app has no sign-up path (accounts are created by `auth.admin.createUser`, `app/settings/accounts/accountActions.ts:107-112`), so turning it off
   breaks nothing. **Not proved by signing up** (that would be a live write outside this block). Q0.
2. **What a signed-in session with no role reads today** [M, `norole-session-readings.sql`]: **38 of the 40 storage objects in 13 private buckets**
   (finance attachments, PO / invoice / quotation / sales-order / shipment / credit-note documents, CODs, supplier and customer attachments, the company
   logo, traceability reports); `user_roles` (9 rows, 7 users — who is admin), `roles` (14), `metal_prices` (12), `pricing_settings`, the chart of accounts
   (46), `company_profile`, `hr_settings`, `laboratories`. **35 storage policies** over 14 buckets grant read (14 buckets), upload (13) and update / delete (4 attachment buckets)
   to any `authenticated` session with no other condition [M, `STORAGE_POLICY` lines]. `collection_promise_status` is an owner-rights view (owner `postgres`,
   `rolbypassrls = true`) with **no predicate** and a SELECT grant to `authenticated`; it returned 0 only because `collection_promises` is empty on live [M].
   MES-0 counted the 44 `USING (true)` policies (re-measured: 44 on 44 tables) but not the storage half.
3. **MES-0's isolation plan (Q86: narrow every `authenticated` object to internal accounts) is a census of ≈1,100 objects that never ends** [M]: 279 tables
   granted to `authenticated` (RLS on all 321), 44 `USING (true)` policies, 170 readable views (6 owner-rights with no predicate in their body), 787
   functions executable by `authenticated` (511 SECURITY DEFINER), 35 bucket-only storage policies — and Supabase's default ACL grants **every future** table, view,
   sequence and function in `public` to `authenticated` (`DEFAULT_ACL` lines). Each later cut would have to remember "internal only".
4. **A separate Postgres role for supplier sessions starts at zero** [M + D]: `PUBLIC` holds **0** function EXECUTE and **0** relation grants in `public`
   (`PUBLIC_FUNC_EXEC|0`, `PUBLIC_REL_SELECT|0`), and the default ACLs name only `authenticated` / `anon` / `service_role`. Supabase's custom access token
   hook is on the **Free** plan; the auth server accepts any string as the `role` claim; PostgREST then `SET LOCAL ROLE`s to it (the role must be granted
   to `authenticator`) and Storage honours it (its own "Custom Roles" guide) [D]. So a portal role reaches **only what is granted to it by name** — the
   proof becomes "this one role's privileges equal this allowlist", decidable from the catalog, like the anon baseline (verdict 6). **Not proved yet:** no
   Supabase document shows the hook *changing* `role` (their examples add a `user_role` claim) — the first act of the cut is a dry run that proves it or
   falls back to Q86 (Q2).
5. **Revocation needs more than a ban** [D + M]: a ban stops the next refresh; the issued access token keeps working up to `jwt_exp = 3600` s, and even
   `auth.admin.signOut(global)` leaves issued access tokens valid until `exp` (`HISTORY1-DISABLED-TOKEN-HOUR`, `docs/known-issues.md:9909`). The portal's
   own functions can check that the token's `session_id` still exists in `auth.sessions` **and** that the portal link is not revoked — cut-off on the next
   call (Q85 [R] extended, Q8).
6. **Every document a supplier would see as a document already exists frozen** [M]: issued POs (`po_issues`, versioned, `po-documents`, sha256), CODs
   (`cod_issues`), supplier statements (`supplier_statement_issues`, versioned). Receipts, weighbridge nets and assay results are **records, not issued
   documents** — showing them is a live rendering to an outside party, which the frozen-snapshot rule has not covered before (Q14).
7. **The brief lists more than MES-0 Q84 ruled** [R]: Q84 = own POs, receipts (quantities, ticket net, status), final assays that set its price,
   statements, CODs, and **uploads of compliance certificates**. Delivery notices, dispute responses, scorecards, disputes as a page, and weighbridge
   tickets as their own page are additions (Q16–Q18).
8. **Today's supplier data is thin** [M]: 17 suppliers (1 approved), **0 supplier contacts**, 11 POs, 24 receipts with a supplier, 3 CODs, 0 statements,
   0 disputes, 0 weighbridge tickets, 4 compliance rows, 0 scorecard reviews. Every portal page will be proved on throwaway data.
9. **Size.** One cut is ≈ 11 h 15 – 19 h 00 of raw work (§11), beyond any measured cut. **Three cuts** are recommended: MES-9a identity and isolation,
   MES-9b what a supplier sees, MES-9c certificate uploads and staff review.

---

## §1 · (a) What MES-9 is in the MES-0 plan, and its exact contents

- **Place** [R]: the 15th and last cut of the MES group (`docs/surveys/MES-0/README.md:709`, order `:714-720`; `docs/forward-queue.md:7795`), function 27
  (`README.md:142`): "No external-user concept; `counterparty_contacts` has no login link; `PUBLIC_PATHS = ['/login','/verify/cod']`; idle logout 30 min".
  §8.3: "alone and last: the first external login and the largest security surface; its sweep touches policies across the whole schema" (`:726-727`).
- **Planned contents** (`README.md:709`): tables `supplier_portal_users`, `portal_invitations`; the `/portal` route group; the internal-only sweep of the 44
  `USING (true)` policies and of default `EXECUTE`; revocation checked inside portal functions. 2 tables / 5 pages; extras "sweep + external-session probe:
  3–5 h"; estimate 1h30–2h30 floor + 6h05–10h45 work = 7h35–13h15.
- **Rulings that bind it** [R] (`README.md:1062-1080`, all accepted 2026-10-05 `:1141`): Q84 what a supplier sees; Q85 every portal function checks
  `supplier_portal_users.revoked_at`; Q86 the internal-only sweep before the first supplier login; Q87 `action.manage_portal_users` → admin, cco; Q88
  `/portal` in the same app with its own layout; §4.1 "portal user invite: none (admin-only codes, change-logged)" (`:528`); §4.3 trail subject
  `portal_user` (`:550`); Q16 + MES-1 narrowing: paid plan before the first real data or real gateway (`docs/forward-queue.md:313`, `:7759-7763`).
- **Left to MES-9 by earlier cuts** [M]: no MES-1…MES-8b-2 entry names MES-9 (`grep`, forward-queue only `:1247`, `:7756`, `:7795`; known-issues 0). Two
  standing items point at "the day there is an outward portal": the avatars bucket's reopen trigger (`docs/anon-surface.md:251-282`; `docs/forward-queue.md:2785`
  — already private since COD-2) and PDPA item 3, how a counterparty contact proves who they are (`docs/pdpa.md:101-116`, `:161`). U1-B closed MES-0's named
  precondition `U1A-SELF-GATE-NULL-TRAP` (`docs/known-issues.md:10445-10459`; a portal account has no employee row — every "holds the code OR is me" gate
  is `COALESCE(…, false)`).
- **Left out** (recommended, Q16–Q18): delivery notices, dispute responses, scorecards, internal notes, other parties' assays, prices other than those on the
  supplier's own issued documents, staff names, health and pay data, a separate domain (Q88 [R]), email invitations (Q6).

## §2 · (b) Identity

| Question | Recommended answer | Evidence |
|---|---|---|
| Kind of user | An `auth.users` row like staff, **but its sessions run as a separate Postgres role `supplier_portal`** set by the custom access token hook. Never an employee, never a `user_roles` holder (a trigger refuses either link on a portal account, and refuses a portal link on an account with roles or an employee). | §0.3–0.4; `db/tables/user_roles.sql` (no FK to `auth.users`, `docs/known-issues.md:5450-5452`) |
| Created | By a holder of `action.manage_portal_users` (admin, cco — Q87 [R]) from the supplier's page: pick one of the supplier's **contacts** (the person), `auth.admin.createUser` with an initial password and `must_change_password` — the staff path (`accountActions.ts:63-181`, C-1 replaced invite-by-email because there is no SMTP). The password is handed over out of band. | Q5, Q6 |
| Linked to one supplier | `supplier_portal_users(user_id UNIQUE, supplier_id, contact_id, created_by, revoked_at/by/reason)`; one account = one supplier; a person who works for two suppliers gets two accounts. | Q5 |
| Disabled | `revoked_at` on the link (immediate on the next portal call) **plus** a ban and `auth.admin.signOut(global)` (no new token, no refresh). Every portal function checks the link and that `session_id` is in `auth.sessions`. | §0.5, Q8 |
| Removed | Never deleted (house rule: accounts are disabled, not deleted — `docs/known-issues.md:5228-5257`); contact data anonymised on request (Q20). | Q20 |
| Sign-in | The same `/login`; `landingPath` sends a portal session to `/portal`; first sign-in forces `/set-password`. | `lib/loginRoute.ts:180`, `lib/supabase/middleware.ts:316-321` |
| Idle logout | Unchanged: 30 min, one value (IDLE-DRAFT [R]; the only exception is `floor_display`, MES-8b-2). | `lib/session.ts:22` |
| Refresh-token rotation | Unchanged project-wide (on, reuse 10 s); Supabase recommends not changing it [D]. SESSION-1 ① (a reuse-interval decision "before colleague accounts go out", `docs/known-issues.md:3191-3192`) is Tim's and is now also due before the first outside account. | Q9 |
| Staff vs supplier apart | (1) **database**: different Postgres roles — the portal role has no grant on any internal object, and internal functions are not executable by it; (2) **routes**: the root layout refuses a portal session on every non-`/portal` route and every internal session on `/portal` (the `requireNotFloorDisplay` precedent, `app/components/moduleGuard.tsx:176-188`); (3) **permissions**: a portal account holds no permission code — `current_user_permissions()` is empty for it — and portal functions never call `has_permission`; their only judge is the link. | Q2, Q10 |

## §3 · (c) Isolation

**Recommended mechanism (Q2): a dedicated role.** Every object a supplier can reach is granted to `supplier_portal` **by name**:
- **functions**: `portal_*` SECURITY DEFINER functions only, each deriving the supplier from `auth.uid()` → `supplier_portal_users` (no supplier id is ever a
  parameter), each checking Q85 + session; EXECUTE granted to `supplier_portal`, revoked from `authenticated`, `anon`, `PUBLIC` in `zzz_function_grants.sql`;
- **tables / views**: none granted (the role reads nothing directly);
- **storage**: policies `TO supplier_portal` on the three document buckets (`po-documents`, `cod-documents`, `supplier-statement-documents`) and one new upload
  bucket (9c), each `USING (portal_can_read_object(bucket_id, name))` — a definer predicate that maps the object to an issue row of the caller's supplier.

**Proof for every reachable object, not sampled** (Q3):
1. **Census = allowlist.** A new gate check over the catalog enumerates *every* relation, column, function, schema, sequence and storage policy, asks
   `has_*_privilege('supplier_portal', …)` / `'supplier_portal' = ANY(policy roles)`, and compares the set to `db/portal-grants-baseline.tsv` — equal or red
   (the verdict-6 shape for `anon`, `db/check_grants.py`). Fault-injected both ways (grant one extra table → red; remove one baseline line → red), plus the
   two always-on injection cells verdict 6 carries (unreadable baseline, blinded query).
2. **Every allowlisted function, two suppliers.** A fixture builds suppliers A and B with a portal account each and one of every document; for **each**
   function in the baseline (looping over the baseline file, not a hand list) it asserts A's call returns A's rows and none of B's, a revoked link refuses,
   a missing session refuses, and an internal session refuses. A function added to the baseline without a case makes the fixture red.
3. **HTTP, live, throwaway**: a portal session against PostgREST and Storage — 0 rows / 403 on a sample of internal tables and every bucket, 200 on its own
   documents only, and the root layout's refusal on internal routes.

**Every existing object that grants to `authenticated` today**: unchanged by MES-9 under Q2 (the portal role never inherits from `authenticated` — it is not a
member). The no-role surface of §0.2 stays an **internal** least-privilege question, reachable only by staff once Q0 closes sign-up (Q4). Under Q86 as ruled
(Q2's alternative) every one of the ≈1,100 objects changes, and so does Supabase's default ACL (Q26 of MES-8 recorded why default privileges cannot be
changed for views without breaking 273 table mirrors).

**Residual risk named** (Q11): if the hook were disabled (a project setting, not a migration), a portal user's next token would carry `authenticated` and
reach the §0.2 surface. Mitigations: portal functions refuse unless `current_user = 'supplier_portal'` (so the portal visibly stops working instead of
quietly widening), the middleware logs out a session whose user has a portal link but whose JWT role is not `supplier_portal`, and the gate reads the hook
setting from the Management API when it can reach it.

## §4 · (d) What a supplier sees, and what is withheld

| Item | Shown (recommended) | Source | Withheld |
|---|---|---|---|
| Purchase orders | each issued version's PDF (frozen, sha256 checked on download), with code, date, status | `po_issues` + `po-documents` | unissued drafts; internal notes; landed cost |
| Receipts | code, date, material name, quantity and unit, weighbridge net where a ticket is linked, status | `inbound_batches` + `weighbridge_ticket_shares` (live record) | `unit_price`, valuation, safety states, location, internal notes, staff names |
| Weighbridge tickets | only as the net on a receipt (Q84) | — | the ticket page, photos, vehicle |
| Assays | the **final governing result** of its own batches (metals %, moisture), its date and the lab name | `assay_results` `is_final` | each party's own result, disputes' internal detail, other suppliers' assays |
| Disputes | not in MES-9 (Q17) | | |
| CODs | each issued COD's PDF | `cod_issues` + `cod-documents` | voided-in-flight requests |
| Statements | each issued statement version's PDF | `supplier_statement_issues` | unissued statements, AP ledger, other suppliers |
| Certificates | its own compliance rows (type, number, valid until) and its own uploads with their review status (9c) | `supplier_compliance` | staff review notes (Q19) |
| Scorecards | not shown (Q18) | | weights, grades, prepayment caps |
| Prices | only as printed on its own issued PO / statement (Q15) | frozen PDFs | metal prices, pricing settings, margins, valuation |
| People | none | | staff names, emails, health, pay |

## §5 · (e) What a supplier can submit

Recommended for MES-9 (Q84 [R]): **compliance certificate uploads only** (MES-9c): a file (type and size limits V39) + certificate type + number + valid-until
into `portal_certificate_submissions` (status `submitted → accepted | rejected`, reason required on reject) and a private bucket `portal-uploads`. **Staff review**:
a holder of `module.suppliers.edit` opens the submission on the supplier page; *accept* calls the existing compliance writer to create the `supplier_compliance`
row and copies the file into `supplier-attachments` (the record staff already keep); *reject* records the reason, which the supplier sees. **Nothing a supplier
submits touches stock, prices or the ledger**: the role's only writable surface is `portal_*` tables through `portal_*` functions; a fixture runs every portal
write function and asserts the fingerprints of every non-portal table are unchanged (the MES live-proof fingerprint pattern). Delivery notices and dispute
responses: Q16, Q17.

## §6 · (f) Privacy and records

- **Personal data of a portal user**: the contact's name, email, phone (already in `counterparty_contacts`), the auth account (email, sign-in times, IPs in
  Supabase's auth logs), the link row. Notification and consent are organisational, not code (`docs/pdpa.md:18`).
- **Access request**: a portal user can prove who they are by signing in — this closes PDPA open item 3 for portal users (`docs/pdpa.md:101-116`, `:161`)
  with a `portal_export_my_data()` (their contact row, link, submissions) (Q20).
- **Audit trail**: every portal write is change-logged with `actor_account` = the portal account (`db/tables/change_log.sql:12-15`); `ActorName` today renders
  an account with no employee as "account not linked to an employee record" (`docs/known-issues.md:1775-1819`) — the trail must render "Supplier portal user —
  <supplier>" instead (Q21). New trail subject `portal_user` (MES-0 §4.3 [R]) on the supplier page: created, revoked, password reset, submissions.
- **Reads of documents**: no access log exists by decision (`docs/pdpa.md:121-148`). For an outside party, recommend recording document downloads (who,
  which issue row, when) (Q22).
- **Offboarding**: revoke + ban + sign-out; the account and its trail stay; on request the contact is anonymised (name/email/phone replaced) while the trail
  keeps the account id (Q20). Retention otherwise unlimited (Tim 2026-08-24, `docs/forward-queue.md:1540-1548`).

## §7 · (g) Platform

- **Free plan** [D]: 50,000 MAU (ample); pause after 1 week of inactivity (internal daily use prevents it); **no backups and no PITR** (Pro: 7 days of daily
  backups; PITR add-on); session time-box / inactivity timeout and leaked-password protection are **Pro**; custom access token hook, TOTP MFA and custom SMTP
  are **Free**; built-in email sends 2 / hour and only to team members (`rate_limit_email_sent = 2`, `smtp_host` unset — measured).
- **What needs a plan change**: nothing to *build* MES-9. The standing rule (Q16 [R], narrowed by MES-1: paid before the first real data or real gateway,
  `docs/forward-queue.md:313`, `:7759-7763`) meets Tim's "stays on the free plan" at the first **real** supplier invitation (Q12).
- **Production domain (PUR-1 ②)** [M]: the verification URL printed on certificates is `new-era-erp.vercel.app`, "托管平台免费域名下的仓库名", and must be
  settled before the production database (`docs/forward-queue.md:2736-2750`). The portal adds a second reason: it is the address outside users bookmark.
  Vercel custom domains are free on Hobby, but Hobby is for non-commercial use (UNCONFIRMED, not fetched) (Q13).
- **Project settings measured**: `jwt_exp 3600` · rotation on, reuse 10 s · `sessions_inactivity_timeout 0`, `timebox 0` · `password_min_length 6`, no
  required characters, HIBP off · TOTP enroll/verify on · captcha off · `site_url` / allow-list `new-era-erp.vercel.app`.

## §8 · (h) Approvals, masking and the change log

- **Approvals**: none new [R §4.1]: creating / revoking a portal user is an admin-only security action, change-logged; a submission is a record whose staff
  review is the control. Approvals stay ON, finance / cfo / 1,000.
- **Codes**: `action.manage_portal_users` → admin, cco (Q87 [R]) — **declares `module.suppliers.view`** (the supplier page where it is used; both holders have
  it — `docs/role-matrix.md:134-143`); cfo does not get an action code ("CFO reads everything" covers view and data codes). Reading the portal panel on the
  supplier page: `module.suppliers.view` (no new view code). Reviewing submissions: `module.suppliers.edit` (existing).
- **Masking**: contact email / phone already sit behind `module.suppliers.view` (no `_masked` companion today); no new masked column.
- **Change log**: every new table bound (`gen_change_log_bindings.py`); the download log (if Q22) is itself append-only → exclusion 9 with a reason, or logged
  (Q22); `supplier_portal_users` changes appear on the supplier trail.

## §9 · (i) "Not yet set" values MES-9 adds

| # | Value | Page showing "Not yet set" | Supplied by | Trigger | Cut |
|---|---|---|---|---|---|
| V38 | How long an initial password is valid before first sign-in (days) | supplier page, portal panel | Tim | before the first real supplier account | 9a |
| V39 | Upload limits: max file size and accepted file types for supplier uploads | the submission form; settings | Tim (engineering values recommended, like V32: 10 MB · PDF / JPEG / PNG) | before the first real upload | 9c |
| V40 | Password minimum length (project-wide auth setting; today 6, the Supabase default) | — (an auth setting, listed on `/settings/pending-values` and in `docs/mes-pending-values.md`) | Tim | before the first real supplier account | 9a |

Until V38 is set an initial password never expires (stated on the panel); until V39 is set uploads refuse by name (`PORTAL_UPLOAD_LIMITS_NOT_SET`) — an
action may refuse; V40 is Tim's setting change, not a migration.

## §10 · (j) Migration shape and the broken window

**MES-9a** — one migration, COMMIT → ROLLBACK dry run on live first, code first and migrate last:
`CREATE ROLE supplier_portal NOLOGIN NOINHERIT` · `GRANT supplier_portal TO authenticator` · `GRANT USAGE ON SCHEMA public, storage` (+ the storage
grants the dry run proves are needed — Supabase's guide grants `anon` to the role; **not recommended**: `anon` holds 326 table grants and EXECUTE on
`cod_verification` / `ingest_submit`) · tables `supplier_portal_users`, `portal_session_events` (if Q22) · the hook function `portal_access_token_hook(jsonb)`
(EXECUTE to `supabase_auth_admin` only; SELECT on `supplier_portal_users` to `supabase_auth_admin` + an RLS policy for it) · `portal_*` functions ·
`action.manage_portal_users` · trail subject. **Outside the migration**: enabling the hook is a project auth setting (Management API `PATCH …/config/auth`
or the dashboard) — Tim's action or a recorded API call in the cut, **after** the deploy; `db/platform-prelude.sql` learns the role and
`supabase_auth_admin`; `docs/fresh-install-checklist.md` gains the hook step.
**Window**: nothing in use breaks — no existing object changes, no portal account exists, the hook is not enabled until after the deploy. **Effect on
existing grants and records**: none (`zzz_function_grants.sql` gains lines for the new functions only); no back-fill.
**The hook's blast radius** (Q11): it runs on **every** token issue for **every** user. If it raises, nobody can sign in or refresh (`AUTH-BLAST-RADIUS`
shape, `docs/known-issues.md:3384`). Recommended: fail closed (raise), keep it to one indexed lookup, prove it on live with throwaway accounts (internal and
portal) right after enabling, and record how to disable it in one step.

**MES-9b / 9c**: one migration each (functions, storage policies `TO supplier_portal`, the upload table and bucket); same window reasoning.

## §11 · (k) Time estimate

**Calibration** [M] (sources in the cut-duration table: `docs/surveys/MES-6b/STEP0-HANDBACK.md:243-262`, `MES-7a:279-286`, `MES-7b:260-267`, `MES-8:233-274`):
19 measured cuts MES-1 → MES-7b-2, median active **2h42** (2h01–3h55); median floor **1h24** (last five **1h40**); actual work ÷ estimated work-low **0.47**
(19 cuts) / **0.21** (last five). MES-8a, 8b-1 and 8b-2 have **no recorded active time** (no Step 0 has measured them) — the calibration stops at MES-7b-2.
The one security-surface cut measured, MES-1, took 2h42 (floor 1h24 / work 1h17) against 4h20–8h35.

| Cut | Raw work (tables × 30–60 m + pages × 25–45 m + extras) | Work, calibrated (×0.21 low · ×0.47 high) | Floor | **Floor + work** |
|---|---|---|---|---|
| **MES-9a Identity and isolation** | 2 tables 1h00–2h00 · 2 pages (supplier-page panel, `/portal` shell) 0h50–1h30 · role + hook + prelude + census gate verdict with fault injection 2h00–3h00 · live HTTP proof as a throwaway portal user (PostgREST + Storage + routes) 1h00–1h30 = **4h50–8h00** | **1h01 – 3h46** | **1h20 – 2h10** (median 1h24, last five 1h40, + the hook's live check) | **2h21 – 5h56** |
| **MES-9b What a supplier sees** | 0 tables · 5 pages (POs, receipts, assays, statements, CODs) 2h05–3h45 · `portal_*` readers + storage predicate + the two-supplier fixture over the baseline 1h30–2h30 = **3h35–6h15** | **0h45 – 2h56** | **1h15 – 2h00** | **2h00 – 4h56** |
| **MES-9c Certificate uploads** | 1 table 0h30–1h00 · 2 pages (submission form, staff review panel) 0h50–1h30 · bucket + accept path into `supplier_compliance` + fingerprint fixture 1h30–2h15 = **2h50–4h45** | **0h36 – 2h14** | **1h15 – 2h00** | **1h51 – 4h14** |
| **One cut instead** | **11h15–19h00** | 2h22 – 8h56 | 1h20 – 2h10 | **3h42 – 11h06** |

**Recommendation: split into three** (Q1). The single cut's high end (11 h) is beyond the largest measured cut, and 9a carries a project-wide auth change
(the hook) that must not share an open window with five new pages. MES-0's 7h35–13h15 is superseded by these figures (it priced the ≈1,100-object sweep).

---

## §12 · Every open question, with a recommended answer and its evidence

Rounds: Q0 is independent and urgent. Q1–Q4 are the frontier; Q5–Q30 hang off Q2 (marked) and are answered assuming the recommended Q2.

### Urgent, independent of MES-9

❓ **Q0 — Close public sign-up on live now.** `disable_signup = false` and `mailer_autoconfirm = true` (read from `/auth/v1/settings` with the public anon
key): anyone can create a confirmed account and read what §0.2 lists — 38 of 40 stored files across 13 buckets, who holds which role, metal prices, the chart
of accounts — and upload into 13 buckets and update / delete in 4. The app has no sign-up path; `docs/fresh-install-checklist.md:84` already says to turn it off.
➡️ **Tim turns off "Allow new users to sign up" in Supabase → Authentication → Sign In / Providers now** (a dashboard setting; this session does not change
project settings). Then read back `GET /auth/v1/settings` → `disable_signup: true`. Also count `auth.users` for accounts nobody created: today there are
exactly 7, all known (`ACCOUNTS|7`).

### Round 1 — the frontier

❓ **Q1 — Split MES-9 into three cuts?** (§11)
➡️ **Yes: MES-9a identity and isolation · MES-9b what a supplier sees · MES-9c certificate uploads and staff review**, in that order, each with its own brief (this Step 0 covers all three; no further Step 0).

❓ **Q2 — Isolation mechanism: a separate Postgres role (recommended) instead of MES-0 Q86's internal-only sweep.** Q86 [R] stands unless Tim changes it.
(a) Q86 as ruled: every `authenticated` object narrowed to internal accounts (≈1,100 objects, plus every future object, §0.3).
(b) **`supplier_portal` role via the custom access token hook** (§0.4): starts at zero privileges, reaches only what is granted by name; proof = census vs a
baseline (§3). Not documented by Supabase as a pattern — the first step of MES-9a is a dry run that proves it on live with a throwaway account (PostgREST and
Storage both switch role; an internal account's token is unchanged); if it fails, the cut stops and reports, and Q86 comes back.
(c) A separate Supabase project for the portal (2 free projects allowed [D]) fed with frozen documents — strongest isolation, but a second database, a sync
with no scheduler, and a second deploy.
(d) No sign-in at all: tokenised links per document (the `/verify/cod` precedent) — smallest, but gives no portal and contradicts "people outside sign in".
➡️ **(b), replacing Q86** — with Q4 deciding what happens to the no-role internal surface separately.

❓ **Q3 — Proof standard for isolation.** (§3)
➡️ **A new gate check: the portal role's privileges, enumerated from the catalog, must equal `db/portal-grants-baseline.tsv` (fault-injected both ways, two
always-on injection cells); a fixture loops over every baseline function with two suppliers; one live HTTP proof as a throwaway portal user.**

❓ **Q4 — The no-role internal surface (§0.2): fix inside MES-9 or separately?** After Q0 only staff can reach it; under Q2(b) suppliers cannot.
➡️ **Separately, as its own small cut after MES-9 (register `MES9-NOROLE-SURFACE`)**: the 35 bucket-only storage policies → module predicates, and
`collection_promise_status` → the finance predicate. The 44 `USING (true)` dictionary policies stay (they are reference data staff need) except `user_roles`
/ `roles` / `role_permissions`, which Tim may want behind `action.manage_permissions`.

### Round 2 — identity (assume Q2 b)

❓ **Q5 — Who a portal account is.** ➡️ **Exactly one supplier and exactly one of its contacts; the contact's email is the login; a portal account can never
hold a role or an employee link, and a staff account can never get a portal link (refused both ways by trigger).**

❓ **Q6 — How the account is handed over.** No SMTP is configured; built-in email reaches only team members, 2 / hour [D]. ➡️ **As for staff: admin or cco
creates it on the supplier page with an initial password, handed over out of band; first sign-in forces a new password. Custom SMTP (allowed on Free) and
email invitations are a later decision** (drop `portal_invitations` from the plan).

❓ **Q7 — Who manages portal accounts.** ➡️ **`action.manage_portal_users` → admin, cco (Q87 [R]), declaring `module.suppliers.view`; the panel on
`/suppliers/[id]` shows the accounts to every `module.suppliers.view` reader, the buttons only to holders.**

❓ **Q8 — Revocation.** Q85 [R] says check `revoked_at`. A ban leaves the current token valid up to 1 h [D].
➡️ **Every portal function checks the link is not revoked AND the token's `session_id` still exists in `auth.sessions`; revoking = link revoked + ban +
global sign-out, so the next call refuses (`PORTAL_ACCESS_REVOKED`).**

❓ **Q9 — Refresh-token reuse interval (SESSION-1 ①, Tim's open decision).** ➡️ **Keep 10 s (Supabase's default and its advice) and close SESSION-1 ① as decided;
the portal adds no new reason to change it.**

❓ **Q10 — A portal session on staff routes, and staff on `/portal`.** ➡️ **Root layout refuses both ways with a sentence and a link home (the
`floor_display` shape); landing after sign-in is `/portal` for portal sessions.**

❓ **Q11 — The hook's failure mode.** ➡️ **Fail closed (if the lookup errors, no token is issued — for everyone, briefly); portal functions refuse unless the
session's role is `supplier_portal`; the middleware logs out a portal-linked account whose token lacks that role; disabling the hook is a one-step
documented action.**

### Round 2 — platform

❓ **Q12 — Plan.** Tim: the project stays on Free. Standing rule: paid before the first real data or real gateway [R].
➡️ **Build and prove all three cuts on Free with throwaway suppliers; the first real supplier account waits for the paid plan (backups), recorded as the
trigger, like the gateway.**

❓ **Q13 — Domain (PUR-1 ②).** ➡️ **Choose the production domain before the first real supplier account and before production certificates; MES-9 builds
with relative paths and `site_url` from configuration, so the domain is a setting, not code.**

❓ **Q14 — Live records shown to an outside party.** The frozen-snapshot rule covers issued documents; receipts and assays are records.
➡️ **Documents (PO, statement, COD) only as their frozen issued PDFs; receipts and the final assay shown live as facts (no prices), labelled "as recorded today",
not as documents.**

❓ **Q15 — Prices on the supplier's own documents.** ➡️ **Only as printed on its own issued PO and statement PDFs; no live price field anywhere in the portal.**

### Round 2 — scope beyond Q84

❓ **Q16 — Delivery notices.** ➡️ **Not in MES-9** (Q84 did not include them; a later cut if wanted).

❓ **Q17 — Dispute responses / disputes page.** ➡️ **Not in MES-9.**

❓ **Q18 — Scorecards.** ➡️ **Not shown** (internal assessment; weights and caps are internal).

❓ **Q19 — Certificate review.** ➡️ **`module.suppliers.edit` reviews; accept creates the `supplier_compliance` row through the existing writer and copies the
file into `supplier-attachments`; reject needs a reason the supplier sees; no approval chain.**

### Round 2 — privacy and records

❓ **Q20 — PDPA for portal users.** ➡️ **A `portal_export_my_data()` for the signed-in user; offboarding = revoke + ban + sign-out, account kept; on request the
contact's name, email and phone are anonymised, the trail keeps the account id.**

❓ **Q21 — Trail wording for portal actors.** ➡️ **"Supplier portal — <supplier name>" wherever `ActorName` would say "account not linked to an employee
record".**

❓ **Q22 — Record document downloads?** ➡️ **Yes, for portal users only (who, which issue row, when), append-only, and excluded from the change log with a
reason (exclusions 8 → 9).**

❓ **Q23 — MFA for portal users.** TOTP is free and enabled on the project [D, M]. ➡️ **Not required in MES-9a; offered as a later setting** (it adds enrolment
pages). *(Or required from the first account — + ≈1–2 h raw work in 9a.)*

### Round 2 — values

❓ **Q24 — V38 initial-password validity.** ➡️ **Not yet set; supplied by Tim before the first real supplier account; until set the panel says passwords do not
expire.**

❓ **Q25 — V39 upload limits.** ➡️ **Not yet set; recommended engineering values 10 MB, PDF / JPEG / PNG (the V32 precedent: Tim may accept them or start
NULL); until set uploads refuse by name.**

❓ **Q26 — V40 password minimum length (project-wide, today 6).** ➡️ **Not yet set; Tim gives the number before the first real supplier account; it is a project
setting changed by Tim, listed on the pending page.**

### Round 2 — build

❓ **Q27 — Storage grants for the role.** Supabase's guide grants `anon` to a custom role. ➡️ **Do not; grant only the storage privileges the dry run proves
necessary, and put them in the baseline.**

❓ **Q28 — Fixtures and gates.** ➡️ **New gate check (portal census) with its own exit code or inside verdict 6; new fixtures 274 (9a: link, triggers, hook
claims, revocation, session check), 275 (9b: two suppliers × every baseline function), 276 (9c: submissions, accept/reject, fingerprints); every arm
fault-injected; injection run repeated on a fresh rebuild.**

❓ **Q29 — Throwaway portal accounts in proofs.** ➡️ **Extend `mintThrowaway` with a `{ portalOf: <throwaway supplier> }` shape in 9a (prefix `mes9aprobe`),
so the cleanup plan removes the link, the account and the throwaway supplier.**

❓ **Q30 — Order relative to `MES9-NOROLE-SURFACE` (Q4).** ➡️ **After MES-9c**, unless Tim wants it first; Q0 closes the outside door today either way.

---

## §13 · Assertions measured and found false or imprecise

1. MES-0 §0.5 / Q86: "the same 44 `USING (true)` policies and the default `EXECUTE` grant mean an external account would read internal tables" — **true but
   incomplete**: 35 storage policies give any `authenticated` session read on 14 buckets, upload on 13, update / delete on 4, measured 38 / 40 objects visible to a
   no-role session.
2. MES-0 §3.3: "a Supabase auth user per gateway — `authenticated` executes every function by default" — **imprecise today**: 787 of 986 functions (the
   rest revoked by `zzz_function_grants.sql`).
3. Brief §0: "There are 7 live accounts" and public sign-up is not mentioned — the 7 is **true** (`ACCOUNTS|7`), but the project accepts self-registration
   (§0.1), so the count is not guaranteed by anything.
4. MES-0 §4.1: "portal user invite" — there is no invitation mechanism to reuse (no SMTP, C-1 replaced invitations), so "invite" means "create with an
   initial password" unless Tim adds SMTP (Q6).
5. Brief (d)/(e): delivery notices, dispute responses, scorecards — **not in MES-0 Q84** (scope additions, Q16–Q18).
6. A sub-agent's duration table found **no recorded active time for MES-8a, 8b-1, 8b-2** — the calibration ends at MES-7b-2 (stated in §11, not hidden).

## §14 · Stop

No code edits and no migrations. ~~Waiting on Tim's answers to Q0–Q30.~~ Answered — §15.

## §15 · Tim's rulings (2026-10-19) — closed

Recorded by NOROLE-SURFACE Step 0 (`docs/surveys/NOROLE-SURFACE/STEP0-HANDBACK.md`), also in `docs/forward-queue.md` (the MES-8b-2 item and the MES-group table, rows
15-0 · 15a · 15b · 15c).

- **Q0** — done by Tim: "Allow new users to sign up" turned off. Read back 2026-10-19 11:45:44 CST with the anon key: `disable_signup: true`; `auth.users` = the 7
  known accounts, 0 created since this Step 0 (`docs/known-issues.md` `MES9-PUBLIC-SIGNUP-OPEN`, closed).
- **Q1** — **three cuts: MES-9a identity and isolation · MES-9b what a supplier sees · MES-9c certificate uploads and staff review.**
- **Q2** — **isolation by a separate `supplier_portal` Postgres role set by the access-token hook, replacing MES-0 Q86.** The first act of MES-9a is a **live dry run
  of the hook**; if it fails, MES-9a stops and reports, and **Q86 is the fallback**.
- **Q4 and Q30 (Tim)** — **the no-role internal surface is fixed first, as its own cut `NOROLE-SURFACE`, before MES-9a** (not after MES-9c as §12 recommended).
- **Q12** — all three MES-9 cuts are built and proved **on the free plan with throwaway suppliers**; **the paid plan is required before the first real supplier
  account**.
- **Q23** — **MFA is not required in MES-9a**; it is offered later.
- **Every other recommendation — Q3, Q5–Q11, Q13–Q22, Q24–Q29 — is accepted exactly as stated in §12.** (Q9 therefore closes SESSION-1 ① as decided: reuse
  interval stays 10 s — noted in `docs/known-issues.md`.)
- **Before the first real supplier account:** the production domain (Q13), **V38**, **V39**, **V40**, and the **paid plan**.

Order: **NOROLE-SURFACE → MES-9a → MES-9b → MES-9c.**
