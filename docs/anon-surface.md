# ANON-0 · What an anonymous request can actually read

**Measured 2026-09-07 against live (`wvywpohbwkiinmipmuku`), before any public route exists.**
This document answers one question: *if a request arrives with no session, what comes back?*

It is deliberately not the same question `docs/cod-survey.md` § S10 answered. S10 read the
catalogue and reported what is **granted**. A grant is not an answer — row-level security,
view definitions, function privileges and column privileges all sit between the two. S10 said
so itself, in its last paragraph: *"This survey did not verify what any of the eleven return to
an anonymous caller; that requires an actual anon-key request, which is a different kind of
test than the ones run here."* This is that test.

---

## Method — and what would make each number wrong

Every number below is stated with how it was counted. Two paths were run, per relation, and
their failure modes are different on purpose.

| | Path A | Path B |
|---|---|---|
| What it is | A real HTTPS request to PostgREST carrying the anon key and no session | `SET LOCAL ROLE anon` inside a `BEGIN … ROLLBACK` transaction |
| What it sees | Exactly what a browser outside the application gets | The database's own answer, with the API layer removed |
| What it would miss | Anything PostgREST does not route (unexposed schema, schema-cache miss) | Anything the API layer adds or rewrites on top of the database |
| Script | `scripts/anon-surface-probe.py --phase relations` | same script, same phase |

**The catalogue was used as the roll-call, never as the answer.** It had to be: `GET /rest/v1/`
with the anon key returns **HTTP 401 — "Only the `service_role` API key can be used for this
endpoint"**, so the API will not enumerate itself for an anonymous caller. Relations were
therefore listed from `pg_class`, and then every one of them was *asked*.

**Coverage:** 332 relations in `public` — 216 tables and 116 views, `relkind IN ('r','v','m','p','f')`,
no materialised views exist. Path A issued 332 requests; path B issued 332 reads. Both
returned 332 results. **A number that would make this wrong:** if either path had returned
fewer than 332 rows, the sweep went blind somewhere — that is why the two counts are printed
rather than assumed, and it is the same defect this repository has been bitten by before
(a line-oriented cross-check reporting 311 against a parser's 470).

**What this method does not cover, stated rather than implied:**

* Reads were `SELECT *` with `LIMIT 5`. A relation where `anon` held **column-level** grants
  only would refuse `select=*` and still answer a narrower request. Checked separately:
  **0 column-level ACLs mentioning `anon` exist** (`pg_attribute.attacl`), so `select=*` is
  a complete test here. It would stop being one the day a column grant is made.
* Writes were not probed. `anon` holding INSERT/UPDATE grants is a separate question from
  what it can read, and this cut measured reads.
* One live row-count per relation was taken **as `postgres`** as well, because "returned 0
  rows" means two completely different things depending on whether the relation has rows at
  all. That distinction is the whole of § 2 below.

---

## The headline

**No anonymous request returns a single row from any relation in this schema today, and no
function in this schema can be called by `anon` at all.**

| Measurement | Value | How counted |
|---|---:|---|
| Relations returning data to an anonymous request | **0** | of 332, both paths |
| Relations answering with an empty result | **193** | 188 tables, 5 views |
| Relations refusing the request outright | **139** | 111 views, 28 tables |
| Relations where the two paths disagreed | **0** | verdicts compared per relation |
| Functions in `public` | **492** | `pg_proc`, extension-owned excluded |
| Functions `anon` may execute | **0** | `has_function_privilege`, all 492 |
| Functions that actually executed as `anon` | **0** | 324 real calls, path B, rolled back |
| Functions that answered an anonymous HTTP RPC | **0** | 116 real calls, path A, all HTTP 401 |
| Public storage buckets | **1 of 15** | `storage.buckets.public` |

---

## List 1 · RETURNS DATA

**Empty. Nothing in `public` returns rows to an anonymous request.**

The relations one would most expect to be exposed — `suppliers`, `materials`, `currencies`,
`permissions`, `roles`, `certificates_of_destruction` — are all granted to `anon` and all
return an empty set. The grants are real; the rows do not come.

There is exactly one thing an anonymous caller can read anywhere in the system today, and it
is not a relation. See § 5.

---

## List 2 · GRANTED, BUT RETURNS NOTHING — 298 relations

This is the list that matters for the future, because *what* stops each one is not the same
thing, and a later change converts one kind into another silently.

`anon` holds SELECT on **298** of 332 relations (`has_table_privilege`). Not one of them
answers. Four different mechanisms are doing that work:

### (a) Row-level security — 140 relations, and the test is not vacuous

All 216 tables have RLS enabled (**0 with it disabled**), and their policies are written
`TO authenticated`, which does not apply to `anon`. For these 140, the relation **has rows**
under owner rights and the anonymous read returned zero — so RLS is doing observable work,
not merely declared.

### (b) The function lockdown — 104 relations

This is the mechanism S10 could not see, and it turns out to be carrying most of the views.

Every function in `public` has an explicit ACL of the shape
`{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}`. **`anon` appears in
none of them, and `PUBLIC` holds no EXECUTE either.** So a view that runs with owner rights
but whose body calls `has_permission(...)` fails for an anonymous caller before it can return
anything — not with an empty set, but with *permission denied for function has_permission*.

Counted by the function named in the refusal: `has_permission` 81, `current_user_employee` 13,
`fx_rate_asof` 2, and one each for `has_any_permission`, `can_view_task`, `arm_permission_widen`,
`journal_activity_lines`, `attendance_period_status_rows`, `bank_reconciliation_rows`,
`bank_reconciliation_record_rows`, `inbound_batch_valuation_rows`.

**This corrects S10 on a point of substance.** S10 named eleven owner-rights views granted to
`anon` "with no permission predicate at all" — the eleven are confirmed exactly (re-derived
independently here), but *"no predicate in the view body"* turned out not to mean *"no
predicate"*. Six of them (`my_*`) resolve identity through `current_user_employee()`, and three more delegate to a guarded function that raises `PERMISSION_DENIED` itself (`attendance_period_status_rows`, `inbound_batch_valuation_rows`, `can_view_task`) — leaving the two in class (d). `inbound_batch_valuation`
— the one S10 singled out by name as *"not a `my_*` view, and its name says what it holds"* —
refuses even a `postgres` read, because `inbound_batch_valuation_rows()` checks
`module.inventory.view` before returning anything. **It is not an open door.**

### (c) A base object the caller cannot reach — 1 relation

`processing_run_loss_breakdown` is the only `security_invoker=true` view whose refusal comes
from the base table's grant rather than from a function.

### (d) ★ Nothing at all is stopping them — 2 views

**`collection_promise_status` and `expense_claim_status`.**

Both are owner-rights views (`security_invoker = off`), both are granted to `anon`, both
contain no permission predicate and call no guarded function, and both returned **HTTP 200
with an empty array**. They returned nothing for one reason only: **`collection_promises` and
`expense_claims` have no rows yet.**

What they would return on the day they do:

* `collection_promise_status` — customer legal name and code, the promised amount and currency,
  the promise date, whether it is overdue, the chase code and channel. That is commercial
  (what a named customer owes and has failed to pay on time), counterparty-identifying, and it
  links a named party to a dated event.
* `expense_claim_status` — employee legal name and code, spend date, amount, the free-text
  description, the *no-receipt reason*, decision notes, and whether it has been paid. That is
  personal data about a named colleague, including a manager's written decision notes.

**These two are the finding of this cut.** They are not leaking. They are armed. Nothing
between here and the first recorded collection chase or the first expense claim will produce a
warning, and neither will any check that exists in this repository today.

### (e) The 48 empty tables — where the measurement proves nothing

48 further tables answered empty because they are empty (`contracts`, `leave_requests`,
`shift_handovers`, `medical_claims`, `cod_issues`, `company_compliance`, and 42 others). RLS is
enabled on all of them with policies `TO authenticated`, so they *should* behave like class (a)
once they fill — but **today's measurement does not demonstrate that, and this document will
not claim it does.** They are listed apart for that reason alone.

---

## List 3 · NOT GRANTED — 34 relations

A count, per the brief, rather than a list. `anon` holds no SELECT at all on 34 relations —
among them `employees`, `employment_history`, `payroll_lines`, `performance_reviews`,
`purchase_orders` and its lines, `pricing_formulas` and its history, `processing_cost_entries`,
`price_history`, `invoices`, `sales_records`, `company_profile`, and the six `*_all` views.
These are the relations where an earlier cut revoked rather than relied on RLS. The full
per-relation data is in the probe output, not reproduced here.

---

## Functions — all three tiers

**Tier (i), reading the bodies.** 492 functions in `public`, none extension-owned. 327 are
`SECURITY DEFINER`; of those, 182 contain a write statement. 168 return `trigger`. If `anon`
could execute the definer functions, the unguarded ones would be the whole exposure — which is
why this tier was run first.

**Tier (ii), real HTTP calls.** 116 functions that are `STABLE` or `IMMUTABLE` *and* contain no
write statement were called for real over `POST /rest/v1/rpc/…` with the anon key. PostgreSQL
forbids a non-volatile function from executing a data-modifying statement, so this class cannot
write even if the call succeeds. **All 116 returned HTTP 401.**

**Tier (iii), real calls to the dangerous class.** The remaining functions — the volatile ones,
the writers, `issue_cod` and `void_cod` among them — were called **for real** inside a single
`BEGIN … ROLLBACK` transaction as `SET LOCAL ROLE anon`, with `statement_timeout` and
`lock_timeout` set. 324 non-trigger functions were called. **All 324 raised SQLSTATE 42501,
insufficient privilege. Zero executed.** Nothing was written; the transaction was rolled back
regardless. (Checked before running: no `pg_net`, `dblink`, `pg_notify`, `pg_sleep` or
`COPY … TO PROGRAM` appears in any function body, so a rolled-back call has no external effect.)

**The catalogue was not trusted here either** — the probe deliberately ignores
`has_function_privilege` when choosing what to call, because "the catalogue says anon cannot
execute anything" is the claim under test, not a filter to apply to the test.

---

## The other doors

A table grant describes one door. Four others were measured.

| Door | Result |
|---|---|
| **PostgREST schema exposure** | Only `public` and `graphql_public` are exposed. `Accept-Profile: storage` / `auth` / `extensions` → **HTTP 406**. `anon` holds grants on 7 relations in `storage`, 2 in `extensions` and 1 in `realtime`, and **none of them are reachable through the REST API.** |
| **GraphQL** (`POST /graphql/v1`) | Reachable, and answers *"pg_graphql extension is not enabled."* The extension list confirms it: `pg_stat_statements`, `pgcrypto`, `plpgsql`, `supabase_vault`, `uuid-ossp`. **No GraphQL surface.** |
| **Realtime** | One publication, `supabase_realtime`, carrying **0 tables**. Nothing to subscribe to. |
| **Storage — listing** | 42 policies on `storage.objects`, **none naming `anon` or `public`**. `POST /storage/v1/object/list/avatars` and `…/cod-documents` both return `[]`. No bucket can be enumerated anonymously. |
| **Storage — public bucket** | **1 of 15 buckets is public: `avatars`.** See below. |

---

## § 5 · The one thing an anonymous caller can read today

`GET /storage/v1/object/public/avatars/<uuid>.webp` **with no API key at all** returns
HTTP 200 and 7,532 bytes of `image/webp`. Two objects exist. Their names are not random keys —
they are `<auth.users.id>.webp`, and one of the two is the owner's own account.

**This is not a defect, and it is not new.** It was ruled deliberately in UI-1d, and the
migration that created the bucket writes the consequence down in full, unprompted:

> *"**任何人猜中一个 user_id,就能不登录取到那个人的脸。** …
> **地址本身把 auth uid 说了出去。**"*
> — `db/migrations/2026-09-05-ui1d-avatar-bucket.sql`

The reasoning recorded there is that a private bucket costs a signed-URL round trip on every
page load for the hottest render in the system, and that six colleagues inside one company do
not justify it. The rejected alternative (b) — a private bucket behind a Next route that proxies
the bytes, taking the uid out of the public address — is written down as *"the road to take once
there are more people"*, together with the condition for reopening the decision:

> *"人一多、或者哪天有了对外的门户,就重开这一条,并照 (b) 改。"*
> — *when the number of people grows, or the day there is an outward-facing portal, reopen this
> and change it to (b).*

**The verification page is that outward-facing portal.** So the honest report is not "you have
a leak" — it is that a decision you made deliberately named the moment it should be revisited,
and that moment is the next cut. The practical exposure today is bounded: the object name is a
122-bit uuid, no anonymous path enumerates it (the storage list API returns `[]`, and every
relation carrying a `user_id` refuses `anon`), and there are two photographs in the bucket.

**Nothing else in the system returns anything to an anonymous caller.**

---

## What the verification page actually needs

**One function, and no table grant at all.** That is achievable with what COD-1 already built.

`certificates_of_destruction` freezes `snapshot jsonb` at issue and carries `verification_token
uuid` under a unique index. The snapshot holds every value the certificate prints — batch code,
material code and name, quantity and unit, arrival date, PO code, supplier name and code, the
processing completion date, the company's own details, and the licence number, issuing body and
validity dates copied rather than referenced. **It contains no price, no cost, no assay content,
and no metal grade.** The page therefore needs no live row: everything it renders is already in
one column of one row.

So the shape is a single `SECURITY DEFINER` function taking the token and returning that
snapshot, with `anon` granted EXECUTE on it and on nothing else.

**What has to change for that to work:** `anon` currently holds EXECUTE on **zero** of 492
functions. This would be the first — a grant, not a revocation. Nothing needs to be opened on
any table, and nothing needs to be opened on `certificates_of_destruction` itself.

**A property worth noticing:** the page *cannot* be built the other way by accident. A page that
tried to read the table directly would get an empty result, because the table's RLS policy is
written by permission and `anon` matches none of it. The current state forces the right design.

**What the function must strip from the snapshot before returning it**, none of which is
sensitive to the certificate's own reader but none of which belongs in a public payload either:

* `provenance.run_ids` — internal processing-run uuids, useless to a supplier and an id leak;
* `certificate.id` and `inbound_batch.id` — internal uuids;
* the echoed `certificate.verification_token`.

**What the page must not be able to reach, and does not:** prices (`metal_prices`, `price_history`,
`pricing_formulas`), costs (`processing_cost_entries`, `batch_processing_cost_allocations`), assay
content (`assay_results`, `assay_result_metals`), the batch's valuation (`inbound_batch_valuation`),
any other certificate, and any list or index of certificates. A function that takes one token and
returns one snapshot has no list to expose — there is no endpoint to enumerate.

---

## Proposed narrowing — a plan, not an action

**Nothing was revoked in this cut, `PUBLIC_PATHS` was not touched, and no page was built.**

The measurement changes what a narrowing is worth. `anon` holds 2,272 table-grant rows across
329 relations, and **not one of them yields a row**. Revoking them therefore buys no immediate
confidentiality — it buys the removal of a class of future accident. That is worth having, but
it is not urgent, and the cost of getting it wrong is a broken feature for five people who are
using the system today.

| # | Proposal | What it costs if it turns out to be needed | How to reverse |
|---|---|---|---|
| 1 | **Revoke SELECT on `collection_promise_status` and `expense_claim_status` from `anon`** | Nothing measurable. Both views are read by the app as `authenticated`; `anon` has never been a legitimate reader of either. | One `GRANT SELECT … TO anon`. |
| 2 | **Or instead: add a permission predicate to those two view bodies**, matching the pattern the other nine owner-rights views already follow | Slightly more work, and it changes a view definition (mirror must be updated in the same commit) | Revert the migration. |
| 3 | **Revoke SELECT from `anon` across `public` wholesale**, then grant back only what a public route needs | **This is the one I am unsure about, and I will not pretend otherwise.** 298 relations are involved. Nothing measured says any of them is needed by `anon` — but "nothing returns rows today" is not the same as "no code path expects the grant", and a Supabase client that loses a grant fails differently from one that gets an empty set: it errors instead of returning `[]`. Some UI may currently render an empty state where it would then render an error. | `GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon` restores it in one statement, but the reversal is coarse — it would also restore the 34 that are currently revoked, so the exact prior state must be captured first. |
| 4 | **Alter the default privileges** so newly created relations are not granted to `anon` automatically | Every future migration must grant deliberately; a forgotten grant becomes a broken feature rather than a silent opening | Restore the default privilege. |
| 5 | **Leave the avatars bucket alone until the verification page ships, then apply UI-1d's own alternative (b)** | Deferring costs nothing today; doing it now costs a server hop per avatar render for no measured benefit | n/a |

**My recommendation, if you want one:** do 1 (or 2) and 4 now, alongside the verification page.
Both are small, both are reversible in one statement, and together they close the only real gap
— the one where a relation that is safe today becomes unsafe the moment somebody records a
collection promise. **Hold 3** until a check exists that would tell you which grant broke what.

---

## The check that should have been watching

`db/check_mirrors.py` states at line 59, in its own `【不比】` list, that it does not compare
GRANTs. That is accurate and it is the reason none of the above was being watched. This
repository has already paid for that gap once: `db/views/batch_lineage_all.sql` records a
`REVOKE` that lived in a migration and never reached the mirror — *"线上收着,重建出来的库开着"*,
live is closed and a rebuild is open.

**Two existing scripts have names that suggest they already cover this, and neither does.**
`scripts/sweep-ghost-grants.mjs` is about `user_roles` rows whose `user_id` no longer exists in
`auth.users` — application role assignments, not SQL GRANTs; the word "grant" means something
different in its name. `scripts/check-permission-predicate.mjs` is a pure text check over `app/`
and `lib/` asking whether permission evaluation happens in one place in the *front end*; it never
looks at a view body or a role. Anyone searching the repo for "is somebody watching grants?" will
hit both of these first. **Nobody is watching.**

**What it would assert.** A baseline file naming every relation `anon` may hold a grant on, and
every function `anon` may execute. The check reads live, compares, and **fails if the live set
is not a subset of the baseline.** The baseline may only shrink: removing a line is a normal
commit, adding one is a deliberate act that has to be written down. The function half starts at
zero entries today, which makes it the strongest assertion in the file — anything appearing
there is new.

**How it fails safe.** This repository's law is that a parser going blind and a clean tree both
print `EXIT 0`, so **coverage itself must be asserted**. Three requirements:

1. The check counts the relations it examined and compares that count against a second,
   independently derived count in the same run — `pg_class` on one side, `information_schema`
   on the other. A mismatch is a failure, not a warning.
2. If the live query returns zero rows, that is a **failure**, never a pass. An empty result is
   what a broken connection looks like.
3. **"Blind the parser" is a mandatory injection cell:** point the check at a baseline it cannot
   read, and at a query that returns nothing, and assert that both go red.

**Where it belongs: its own script, `db/check_grants.py`, invoked by `db/gate.py`.** Not inside
`check_mirrors.py` — that script's entire safety argument rests on replaying mirrors into a
scratch schema inside a rolled-back transaction, and grants are not a mirror question: the
mirrors do not carry GRANTs at all, which is exactly why a rebuilt database can differ from live
here without anything noticing. Bolting a live-only, non-replaying comparison onto it would
weaken a header that is currently true. `gate.py` already owns "three verdicts from one run" and
is the natural caller.

**It needs a live database.** The offline half of the gate cannot run it, and it should not
pretend to: the mirrors have no grant information to check, so an offline version would assert
nothing while printing green — the precise failure this repository keeps writing down.

---

## Files

* `scripts/anon-surface-probe.py` — both paths, all three function tiers, the other doors.
* `scripts/anon-surface-report.py` — joins the probe output into the three lists. Reads files
  only; connects to nothing, so the verdicts can be recomputed without touching live.

Neither is wired into any gate. They are probes, run by hand.
