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

## Both database checks run on every cut that touches the database

| | question it answers |
|---|---|
| `python3 db/check_mirrors.py` | do the mirrors match live, including seed rows and cross-file integrity |
| `python3 db/verify_rebuild.py --target "<empty db>"` | can this repository build a database **at all** |

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
