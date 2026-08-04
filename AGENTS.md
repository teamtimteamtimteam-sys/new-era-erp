<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

# Database mirrors

`db/tables/`, `db/functions/`, `db/views/` mirror the live schema so it can be rebuilt from the repo. **Any migration that touches a table must update that table's mirror file in the same commit** — same for functions and views. Single-function files under `db/functions/` are exact `pg_get_functiondef` bytes; table mirrors are first-run CREATE scripts with columns in live ordinal order (ALTER-added columns stay at the end).

When in doubt run `python3 db/check_mirrors.py` — it replays the whole mirror set into a scratch schema inside a rolled-back transaction and diffs the catalogs against live (exit 0 = clean). Never paste a table mirror into the live DB directly: table mirrors contain `CREATE OR REPLACE FUNCTION` and would silently overwrite live functions — the script's header explains both hazards.

## RUNTIME CONFIG bootstraps: what the harness cannot see

`check_mirrors.py` classifies seeded tables two ways (see `SEED_TABLES` /
`RUNTIME_CONFIG_TABLES`). RUNTIME CONFIG tables — the ones an operator can change
through the app — are **deliberately not row-compared against live**, because live
diverging from the file is the system working correctly, not drift.

That exemption is drawn in the right place, but it has an edge. The harness does
still **replay** each bootstrap into a scratch schema, so it already catches:

* a seeded column that was renamed or dropped (replay fails — proven against the
  `days_per_month` → `days_per_year` change);
* a seeded value that violates the table's own constraints (replay fails);
* a `NOT NULL` column added since, with no default, that the seed omits (replay fails);
* a bootstrap that seeds **zero** rows overall (`bootstrap` line, fails);
* a bootstrap referencing a permission code, role code or account code that its own
  mirror set does not define (`integrity` line, fails).

**What it cannot see, and you must check by reading:**

> **When a migration changes the MEANING of a column that a RUNTIME CONFIG table
> seeds, without changing its name or type, nothing will tell you the bootstrap is
> now wrong.** Re-read every affected bootstrap in the same commit.

The case that prompted this rule: HR-2c changed `leave_accrual_rates` from a monthly
figure to an annual one. It happened to rename the column, so a stale bootstrap would
have failed the replay — but had the column kept its name, the file would still have
said `2.0` and `1.5`, a rebuilt production database would have given every office
employee **2 days of annual leave a year instead of 24**, and `check_mirrors` would
have reported a clean bill of health.

So: **a migration that touches a RUNTIME CONFIG table must state, in the same commit,
whether its bootstrap default is still correct.** Not "still valid" — the harness
answers that. Still *correct*, meaning the numbers in it still mean what they meant.

## Verifying the rebuild path

`check_mirrors.py` asks "do the mirrors match live". **`db/verify_rebuild.py` asks the
other question: can this repository actually build a database at all.** OPS-1 ran that
experiment for the first time and the answer was no — three separate walls, none of
them written down anywhere (see `db/platform-prelude.sql`). Having fixed them, the
experiment needs to stay repeatable rather than have been done once.

```
python3 db/verify_rebuild.py --target "<dsn of an EMPTY database>"
python3 db/verify_rebuild.py --target "<dsn>" --skip-diff     # build only, no live comparison
```

Exit codes: **0** = builds and matches live · **1** = builds but differs · **2** = does
not build.

Prerequisites: `psql` on PATH; an **empty** target database (it gets written to — never
point it at live); network access to live if you want the diff. A throwaway local
cluster:

```
initdb -D /tmp/pg -U postgres --no-locale --encoding=UTF8
pg_ctl -D /tmp/pg -o "-p 55432 -k /tmp/pgsock -c listen_addresses=''" -l /tmp/pg.log start
createdb -h /tmp/pgsock -p 55432 -U postgres scratch
```
The socket directory must be short (< 103 bytes) — a deep temp path fails with
"Unix-domain socket path is too long".

**It also answers whether `db/platform-prelude.sql` is still sufficient.** When a replay
fails on a missing schema, role, relation, function, type or extension, the script names
the object and says the prelude is not sufficient, rather than leaving a bare psql error.
That matters because the prelude is the only written record of what the mirrors expect
the platform to provide, and nothing else notices when that expectation grows.

## Mirror function signatures: built-in types only

**A mirror function signature — `RETURNS` and every parameter type — must name only
built-in types. Never a table's composite type.**

This is not style. The replay order is `db/functions` → `db/tables` → `db/views`, and
`SET check_function_bodies = off` exempts a function's **body** but not its
**signature**: the return and parameter types must already exist when `CREATE FUNCTION`
runs. A table composite type in a signature therefore *can never work* in a rebuild,
whatever order you try. `%ROWTYPE` inside the body is fine — that is the part the
exemption covers.

Caught the hard way: `require_reviewer_of` was written `RETURNS performance_reviews`.
`check_mirrors` passed it; `verify_rebuild` failed with
`type "performance_reviews" does not exist`. An audit of all 100 function mirrors and
the live catalog found it to be the only instance, and no table column anywhere uses a
composite type.

## The database gate runs on every cut that touches the database

```
python3 db/gate.py        # ~2 minutes, no large payloads over the network
```

One LOCAL rebuild, two separately-reported verdicts (OPS-6 merged the two older
tools — their build steps were identical and check_mirrors was shipping a
~14,000-line replay through the pooler, taking 40+ minutes and dying on DNS and
socket exhaustion):

| verdict | exit | question it answers |
|---|---|---|
| 可重建性 | 2 on fail | can this repository build a database **at all** (prelude sufficiency, B1/B2 on live AND rebuild) |
| 镜像 vs 线上 | 1 on fail | do the mirrors match live — structure, seed rows, bootstrap counts, cross-file integrity, definer caller checks |

The verdicts stay separate because they are different failures with different
fixes. `check_mirrors.py` and `verify_rebuild.py` remain as the engine (gate.py
imports/spawns them); run verify_rebuild alone when you only need one side.

## Route smoke test — run on demand, whenever the render layer changed

```
node scripts/smoke-routes.mjs      # ~2-4 min: renders all ~130 routes as admin
```

Builds compile pages but never render them — two pages were broken for months
with every gate green (an RSC serialization error and an inverted currency
filter), each found by a human clicking. This script starts the dev server,
signs in with a throwaway admin session, requests every route under app/
with real ids pulled live from the database, and for each failure captures
the SERVER-side error and stack, not the browser message. It also runs one
REVIEWER-VIEW check: /my-reviews/[id] is a contract-404 for admin, so it
would otherwise never render — the script builds a scratch fixture (two
ZZ-SMOKE-* employees plus one probation review; scratch business rows are
NAMED as scratch because they surface on HR screens) and requests the page
as the actual reviewer, expecting exactly 200. Status-guarded routes get
their expected status COMPUTED from the picked row's status column, not a
loose "either is fine" list. Design redirects and contract-404s are declared
in the script's EXPECTED map — each entry was individually verified before
being allowed. Cleanup runs at START as well as at end: a finally block
does not survive a kill, and this script drives HTTP against a live server,
so a startup sweep of smoke-*/ZZ-SMOKE-* leftovers is the only rollback it
can have.
The skip list is ASSERTED, not printed: EXPECTED_SKIPS names the routes
allowed to skip for lack of data, and drift in either direction fails the
run — a route moving from ok to skipped is a coverage regression that looks
identical to "no data yet" (four finance routes silently lost coverage that
way). For the same reason a failed id query aborts loudly naming the route
and error instead of counting as a skip: a failed query is not an empty
table, just as a resolver parsing zero suffixes is not an empty set.
Deliberately NOT part of db/gate.py: it needs a dev server and minutes — a
slow gate is a skipped gate (the check_mirrors lesson). Run it after touching
page-level rendering, and after any bug a human finds by clicking.

## Adding a column to a masked table: extend the grant, or it is invisible

`perm2b` converted the masked tables to **column-list** SELECT grants
(`REVOKE SELECT ON t; GRANT SELECT (a, b, c) ON t`). PostgreSQL treats the two
verbs differently, and this asymmetry is the whole hazard:

* table-level **INSERT/UPDATE** grants *auto-extend* to columns added later;
* a column-list **SELECT** grant does **not** — the list is frozen.

So `ALTER TABLE ... ADD COLUMN` on a masked table produces a column the app can
write but cannot read. Every query selecting it, **or merely filtering on it**,
fails `42501`. FIN-6 did exactly this to `processing_cost_entries`, and
`/finance/processing-costs` plus the month-end cost step were empty from the day
they shipped, with every gate green.

**Adding a column to a masked table therefore means, in the same migration:**
1. add it to the column-list SELECT grant (non-sensitive), or deliberately leave
   it out (sensitive — readable only through the `_masked` view); and
2. add it to the `<table>_masked` view.

`db/gate.py` now asserts this (`colgrant` line, both live and rebuild): every
column of a masked table must be either SELECT-granted or present in the masked
view. Anything else is named and fails the gate. `check_mirrors` cannot see it —
it does not compare GRANTs — which is why the check lives in the gate.

## Dates and amounts that decide a period: required, never defaulted

A field that decides an **FX rate**, a **posting period**, or an **amount**
needs BOTH guards, and they are the mechanism:

1. the submit control is **disabled while the value is empty**, and
2. the **server action rejects empty independently**, so bypassing the UI
   cannot post.

(A UI-only `required`/`onBlur` is a third layer, not the protection. React
never compares a controlled input's value prop against the live DOM, so a
field can display a date the app does not have — that is exactly how the
cost-settlement bug submitted `""` from a filled-looking box.)

**Never give these a server-side default.** `COALESCE(p_date, CURRENT_DATE)`
substituting today is the failure mode, not the fallback: today's date can
never hit `PERIOD_LOCKED`, so entering the correct closed-period date fails
loudly while leaving the field blank glides into the open month. The path
rewards leaving it empty. Full inventory in
`docs/empty-string-to-rpc-audit.md`.

### The `CURRENT_DATE` defaults are gone (FIN-10)

This section used to warn against "tidying" five call sites into
`|| undefined`, because each sat on a `COALESCE(..., CURRENT_DATE)` that
would turn a visible error into a silently wrong period. **Those defaults
have been removed.** Eleven functions now raise a named error instead:
`PAYMENT_DATE_REQUIRED`, `EXPENSE_DATE_REQUIRED`, `SALE_DATE_REQUIRED`,
`PROCESS_DATE_REQUIRED`, `ORDER_DATE_REQUIRED`, `REFERENCE_DATE_REQUIRED`,
`REVERSAL_DATE_REQUIRED`.

So the trap is gone rather than documented — which is the point. If you add
a new function whose date decides a posting period or a rate, **do not give
it a `CURRENT_DATE` default**; make it required and raise a named error.
Defaults that genuinely belong (code-numbering years, `p_as_of` read
queries, `create_invoice`) are listed in
`docs/empty-string-to-rpc-audit.md` so the distinction is on the record.

## A failed query must fail — never `?? []`

`lib/db-helpers.ts` exports `mustRows` / `mustOne` / `mustCount`. **Use them for
every query result.** They throw on `error` and return the empty value only when
the query genuinely succeeded with no rows.

The rule they enforce is the same one `scripts/smoke-routes.mjs` applies in
`restRows` and `scripts/check-i18n.mjs` applies to suffix parsing: **a failure is
not an empty set.** Written in three places, it is one policy.

Why it matters here specifically: `entriesRes.data ?? []` turns a permission
error into an empty array, so the page returns **HTTP 200 saying "nothing
outstanding"**. The route smoke test asserts 2xx and sails straight past it — a
page that cannot read its data must *error*, or no gate can ever catch it.

`?? []` remains correct for things that are not query results: nested relation
fields on an already-fetched row, `Map.get(...) ?? 0`, client-side state.

## Test data that reads wrong on purpose

Anything that looks wrong in the test database but is known, accepted, and
disappears on the production rebuild gets ONE LINE in
`docs/known-wrong-until-cutover.md` — instead of being re-explained every time
someone notices it. Known structural issues that would SURVIVE a rebuild —
accepted for now, to be fixed deliberately — live next door in
`docs/known-issues.md`; remove the entry when the fix lands.

## Migrations apply over direct psql, never the Management API

```
./db/apply_migration.sh db/migrations/<file>.sql
```

One connection, one transaction, all-or-nothing: any error aborts before
COMMIT and the database is left untouched (proven in OPS-6 with a deliberately
failing migration). The Management API caps payloads at ~15KB and drops
connections — FIN-0 and FIN-1a both got chunked through it and both left the
database half-migrated until the gates caught it. Credentials are in ~/.pgpass;
the API remains fine for small interactive queries and rolled-back fixtures.

## The i18n key check runs on every cut that touches the app

`node scripts/check-i18n.mjs` (also `npm run check:i18n`; `npm run build` runs it
before `next build`, so the build gate cannot pass without it).

The i18n resolver returns the KEY when a label is missing, so a missing
translation prints `hr.alertType.salary_not_set` on screen and nothing fails.
It bit three times before this check existed, all in **dynamically built keys**
(`t('hr.alertType.' + a.alert_type)`), which a plain grep can never connect to
the message files.

The check therefore has two halves and one discipline:

* **Static**: every `t('...')` literal, plus key-shaped literals feeding
  `t(variable)` (`key:`/`labelKey:`/`titleKey=` props and the like), must exist
  in **both** `messages/en.ts` and `messages/zh.ts` — failure names file and line.
* **Dynamic**: every `t('prefix' + x)` construction must be classified in the
  script's `MANIFEST`. For enumerable suffix sets the checker reads the **source
  of truth at check time** — `CHECK (col IN (...))` in `db/tables/*.sql`,
  `'x'::text AS alias` in views, `new Set([...])` in `*ErrorCodes.ts`, `as const`
  arrays — so adding an enum value automatically widens the check. A resolver
  that parses 0 suffixes fails (a broken parser is not an empty set).
* **The discipline**: a dynamic prefix missing from `MANIFEST` is a FAILURE, not
  a pass — a new dynamic call site must be classified (wire a source, or mark it
  `kind:'data'` with a written reason, which is reported as a named gap every
  run). Dead keys (defined, never referenced) are reported but never fail:
  failing on them would push people to delete keys that dynamic code needs.

As of 2026-08-03 all 62 dynamic prefixes are enumerable; the named-gap list is
empty. Keep it that way where possible — the three historical bugs all lived in
exactly the keys a static-only scan cannot see. (Two call shapes exist and both
are scanned: named `t(...)`, and the direct `(await getTranslations())(...)`
form the `*ErrorCodes.ts` files use — the latter hid eight error families from
the first version of this scan.)

**Neither substitutes for the other.** `check_mirrors` replays into a scratch schema
*inside live*, so an unqualified reference silently resolves against live's `public` and
passes — the check is green on a repo that cannot rebuild. `verify_rebuild` builds into
a genuinely empty database, where there is nothing to borrow. It has now caught one
such bug that `check_mirrors` was structurally unable to see.

## Migration filenames come from the system date

**Run `date`. Do not increment the previous filename.**

Incrementing compounds: HR-3a was dated 2026-08-03 while the clock said 2026-08-01, and
every later cut stepped forward from the *filename* rather than the clock, reaching
2026-08-10 on a day the clock said 2026-08-03.

**Known discrepancy, left in place deliberately.** `2026-08-03-hr3a` through
`2026-08-09-hr3c` were all committed on **2026-08-02** (verifiable with
`git log --diff-filter=A -- db/migrations/<file>`). Their dates are fiction; their
*sequence* is correct. Renaming them to the true date would collapse seven files onto
`2026-08-02`, and the resulting alphabetical order —
`hr2c-fu1, hr2c-fu2, hr2c, hr3a, hr3b, hr3c, ops1` — contradicts the real order
`hr3a, hr3b, ops1, hr2c, hr2c-fu1, hr2c-fu2, hr3c`. Renaming any subset is worse still,
inverting the relationship with the files left alone. Since nothing replays migrations
by filename (they are changelog-only; the install path is entirely mirror-based), the
misleading dates cost nothing while a rename would destroy real ordering information.
