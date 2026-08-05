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

## A verdict that reports but does not enforce is not a gate

**Whatever verdict you add next, the first thing you do is make it fail on
purpose and confirm `db/gate.py` stops.** Not "read the output and see the
warning" — confirm the exit code is non-zero and the run is red.

This is not hypothetical. `verify_rebuild` has returned **3** for a failed
B1/B2 invariant assertion since OPS-5, and `db/gate.py` branched only on 1 and
2 — so 3 fell through `structural_drift = (3 == 1)` and **the gate exited 0
while printing a violation**. It did exactly that on 2026-08-04: the run
printed `B1 VIOLATION … anon can EXECUTE it` and passed. The violation got
fixed because a human read the output, which is precisely the property a gate
is supposed to remove. Nobody had ever made that verdict fail on purpose, so
nobody knew it did not bite.

The fixtures verdict (exit 4) was fault-injected before being trusted: fixture
07's lock date was inverted, the gate returned 4 and named the fixture. Do the
same for the next one. A check never observed failing is not known to work —
it is only known to be quiet.

## Entitlement is DERIVED; consumption is RECORDED — so a fresh database gives everything away

This is the shape behind every fresh-install bug we have found, and it makes the
list predictable instead of remembered:

> An **entitlement** is computed from first principles — a policy figure, a rate,
> a hire date. A **consumption** exists only because someone recorded a row.
> A rebuilt database carries the principles perfectly and the records not at all.
> So every entitlement resets to full while every obligation against it vanishes.

The asymmetry is the whole problem. Both halves being missing would be visibly
wrong; only the recorded half being missing looks *exactly like a new employee
with a clean slate*, and produces a plausible number with no error.

Instances found so far, all the same shape:

* **annual leave carry-forward** — accrual runs from hire date whether or not
  this database was operating that year, so a 2020 hire gets a full year
  conjured out of a year that never happened here (HR-5, now refuses);
* **medical claim limit** — the annual allowance is derived from
  `hr_settings`, consumption comes from `medical_claims` rows, so pre-cutover
  claims are invisible and the *entire* allowance becomes available again.
  Worse than display: `decide_medical_claim` gates approval on that figure, so
  it approves claims it should refuse (HR-6, now bounded);
* **monthly leave accrual** when the start date falls mid-year — accrues
  January onward for months this database did not cover.

**The rule of thumb: anything computing an allowance per period is a
candidate.** A limit per year, an accrual per month, a quota per cycle — ask
what records the consumption, and whether those records exist for the whole
period. If the period is only partly covered, the derived half must be bounded
to the covered portion or refused outright; never left whole against a
consumption of zero.

`finance_settings.system_start_date` is the boundary all of these consult:
**the date from which this database holds a COMPLETE record.** Not the install
date and not necessarily the cutover date — if pre-cutover transactions are
being re-entered, it is the earliest real transaction, which can be months
earlier. It is declared rather than inferred from the earliest row, because an
inferred line moves the instant someone back-dates a document and nobody
notices. Getting it wrong raises no error; it silently puts every guard in the
wrong place.

## The third verdict: db/fixtures — does the rebuilt database WORK

`verify_rebuild` asks whether the repo can build a database and whether it
matches live. **`db/fixtures/*.sql` asks whether the thing it built behaves
correctly.** Different questions, same relationship as `check_mirrors` to
`verify_rebuild`, so it gets its own verdict and its own exit code.

```
python3 db/gate.py     # 0 clean · 1 mirror drift · 2 cannot build
                       # 3 B1/B2 invariant · 4 behavioural fixture failed
```

Fourteen fixtures, ~30 assertions, on the paths where a silent break costs money:
settlement closing to exactly zero (including cross-currency), revaluation
idempotence, confirmation not touching leave, accrual not applying a category
change retroactively, one bank line per employee, realised 7100 never crossing
unrealised 7110, period lock, over-allocation in both currency spaces, the
bounded FX reach-back, the three `system_start_date` bounds, and a fully
allocated payment leaving **exactly zero** on account even when the rate moved
between booking and settlement (FIN-18 — that one asserts the *old* formula
differs too, so it cannot pass by both answers agreeing). Deliberately small: every retained fixture is
maintenance on every schema move, and the HR-2c accrual change already cost one
round of "is this staleness or regression?" judgement.

**Read `db/fixtures/README.md` before adding one.** Four rules, each of which
this repo learned the hard way:
1. assert invariants, not literals — and where a literal IS the assertion,
   write down how it was derived;
2. each case owns its data, no resetting between cases;
3. a failure must fail the GATE, not print a differing string;
4. depend only on STABLE bootstrap data (chart of accounts, currencies, roles,
   leave types) and never on TIME-BOUND state — `public_holidays` is seeded a
   year at a time and `finance_settings.locked_before` moves with month-end.
   Set what you need; do not inherit it.

Note the gate previously **swallowed verify_rebuild's exit 3**, so a B1/B2
invariant failure printed a violation and still exited 0. Fixed in the same
change that added verdict 4 — which is rule 3 applied to a check that predates
the rule.

## THE FX RULE — one rule, of which the rest are instances

> **Any amount not in the base currency converts at the rate. If no rate
> exists for that date, the system refuses and prompts for it to be
> entered. Never a fallback, never an assumption.**

Everything below is a consequence, not a separate rule. They were built one
at a time; a new screen should inherit the rule rather than rediscover it.

* **Reaching back is allowed only when the TRANSACTION DATE ITSELF is a
  non-publication day, and it must say so** (FIN-13, corrected by FIN-19).
  A Saturday transaction uses Friday's rate — that is correct, because the
  market did not publish on Saturday. **A business day with no rate on file
  refuses, exactly as an exact-match rule would.** Precisely: every day from
  the rate date (exclusive) through the transaction date **inclusive** must be
  a non-business day (weekend or active SG public holiday). A hard cap of
  **4 calendar days** backstops a mis-maintained holiday table. Beyond either,
  `fx_rate_for` raises `FX_RATE_MISSING|ccy|date|type`, unchanged.
  `fx_rate_asof` returns the rate **and the date it came from**; every screen
  showing a converted figure shows that date when it differs from the
  transaction date.
  The original FIN-0 defect was that the nearest-date lookup was **silent**,
  not that it reached back at all.

  > **How FIN-13 was wrong, because the shape recurs.** It said "every day
  > *strictly between* the rate and the transaction must be a non-business
  > day" and implemented `generate_series(v_when + 1, p_date - 1)`. For
  > **consecutive dates that interval is empty**, so the condition is
  > vacuously true and *every* business day silently accepted yesterday's
  > rate. That is the exact silent nearest-date lookup FIN-0 removed from
  > `pay_medical_claim`, reintroduced with a blessing on it — and it read as
  > a strict rule, which is why nobody re-derived it. Live proof: 5 Aug had a
  > rate, 6 Aug did not, and a 6 Aug receipt booked at 5 Aug's 1.24.
  > **A guard phrased over the interior of a range is vacuous at the
  > boundary. State such conditions over the closed range and check the
  > endpoint explicitly.** The fix was one token; finding it took a human
  > noticing a number on a screen.
  >
  > Note this also made the London/Singapore bullet below *true for the first
  > time*: before FIN-19, a UK bank holiday that SG treats as a business day
  > did not produce a conservative refusal — it silently took the previous
  > day's rate whenever one existed.
* **The London/Singapore calendar is a deliberate approximation.** Metal
  quotes follow London; the only holiday table we have is Singapore's. The
  failure mode is a false *refusal* on a UK bank holiday — conservative and
  self-announcing — never a silently wrong rate. Reasoned where the
  reach-back lives (`db/functions/fx_rate_asof.sql`).
* **`public_holidays` is load-bearing for two modules.** It drives
  `calculate_leave_days` (leave entitlement, silently wrong if a year is
  missing) and now `fx_rate_asof` (loudly wrong — it refuses). It is seeded
  a year at a time, so `hr_alerts` raises `holiday_calendar_missing` from
  October if next year has no rows. `is_business_day()` is the single
  definition both use.
* **Refusal is surfaced, not swallowed.** The revaluation banner names the
  date and the currencies that are missing, and disables the post button.
  Copy that shape: say what is missing, where to enter it, and disable the
  action.
* **The side is part of the rate.** Receipts convert at `tt_buy`, payments
  at `tt_sell` — `record_payment` decides it and every screen follows.
  A receipt valued at the selling rate is wrong every single time.
* **One implementation.** The screen asks the database for the rate; it
  does not compute one. See the ask-the-database rule below.
* **No `?? 0`, no `?? 1`, no defaulting to today's date** — a fabricated
  rate and a fabricated date are the same failure wearing different hats.
* **The base currency is data** (`currencies.is_base`), never a literal.
  See the currency-literal rule below.

**Known exception, deliberate and bounded:** cross-currency settlement,
where the bank actually converted. There the rate is the *actual dealt
rate* from the bank slip, not a board rate — `record_payment` requires it
and refuses to look one up. That is still the rule: the real rate, never an
assumed one.

**The metal pricing path: closed (FIN-15), and the shape of the answer is
worth keeping.** This paragraph used to read "known gap, NOT yet fixed" and
list three things. All three are settled, and only one of them turned out to
be a defect:

* **The function still does not convert — and that is correct.**
  `calculate_metal_price` is USD in, USD out: quotes are USD/tonne, treatment
  charges are USD/tonne, and it neither takes nor applies a rate. **The
  conversion belongs to the path, not the function.**
  `computeLineEstimate` now converts before the number becomes a price —
  `usd_price × fx(USD) / fx(document currency)`, both legs `tt_sell` on the
  order date via `fx_rate_asof`, refusing and naming date/currency/side when a
  rate is missing. A USD document needs no special case: the two rates are the
  same and the ratio is 1. The calculator label reads `Value (USD)`, which is
  the truth — the old `(SGD)` label was the actual lie.
* **A missing quote refuses on the quoting path and still skips inside the
  function — deliberately, in both places.** Skipping keeps one unpriced metal
  from halting production for `allocate_processing_costs`; refusing keeps a
  quote from silently going to a supplier priced too low. Same function, two
  callers, two dispositions. **Do not unify them.** Each side's comment names
  the other: `db/functions/allocate_processing_costs.sql` (first line) and
  `app/pricing/calculator/actions.ts`; `computeLineEstimate` inherits the
  refusal and points at the calculator for the reasoning.
* **`spot` reaching back to the nearest earlier price is a decision, not a
  fallback.** Metal markets do not quote at weekends, so a price series *must*
  reach back — the same reasoning as FIN-13's bounded FX reach-back. What was
  missing was never the refusal; it was saying **which date's price was used**,
  and each line now returns `price_date` (`price_from`/`price_to` for
  `average`). Reaching back silently was the defect; reaching back is not.

Full call-site inventory in `docs/currency-literals-audit.md`.

**The general lesson, which is why this paragraph was rewritten rather than
deleted:** a note describing a hazard that no longer exists is the same defect
as a comment asserting a hazard that cannot occur. It costs a reader the same
wrong belief and nothing in any gate will ever catch it. **Retire a "known
gap" in the place it lives, in the commit that closes it.**

## Currency codes are data, not constants

`'USD'` / `'SGD'` must never appear in a comparison, branch or default in
app code. The base currency comes from `currencies.is_base` via
`lib/currency.ts` (`getBaseCurrency()`, cached per request; client
components take it as a prop). The bank-account mapping lives in exactly
one file, `lib/currencyMap.ts`, mirroring `bank_native_currency()`.

`scripts/check-currency-literals.mjs` enforces it — in `npm run build`
(fast feedback) and in `db/gate.py` (`currency` line). Exceptions go in its
ALLOWLIST **with a written reason**, the same way `check_mirrors` handles
account codes and `check-i18n` handles dynamic suffixes: the list is
derived and visible, not remembered. Allowlist entries are `{path, match?,
reason}` — `match` pins the exemption to one *shape* on that path rather than
excusing the whole file.

**It checks two classes, and the second was added late (FIN-18).** The first
only ever looked at *judgements* — comparisons, branches, `??`/`||` defaults,
`{USD: …}` maps, `'SGD' AS`. But the most direct way to lie about a currency
never passes through a judgement; it is JSX body text:

```tsx
{payment.currency !== baseCurrency && <>= {formatMoney(amount_base)} USD</>}
```

That line **has the base currency in its hand** — the left side just compared
against it — and prints `USD` anyway. After FIN-0 the base is SGD, so the
screen read `= 1,736.00 USD`. No judgement pattern matched, the check reported
clean, and `db/gate.py` reported clean with it. The `jsx-text` class scans
`.tsx` for bare `USD`/`SGD` surviving after string literals and comments are
stripped; currency-picker `<option value="USD">USD</option>` is exempt
(the value and the text are the same code — that control exists to name
currencies). Adding it found **six** live instances of the identical
construction — payments list and detail, expenses list and detail, the AP
batch page and the AR document page. Two manual sweeps had missed all six.
**"Currency clean" meant less than it looked; assume the next blind spot is
whatever the check does not parse rather than whatever nobody wrote.**

Why a check and not care: FIN-0 changed the base from USD to SGD, and the
constants left behind broke four screens over four separate sweeps —
`/finance/payments` valued a base-currency payment at 0.00 and a USD one at
1:1 (FIN-12), and manual journal entry demanded an FX rate for base-currency
lines. Two full manual sweeps each missed a site. The check found 32 in one
run, including one I had just written myself.

**Message files too.** `check-i18n` validates that a key exists, never what
it says, so `'Amount (SGD)'` is invisible to it. A label that names a
currency must take it as a `{ccy}` parameter from the row (or the base
currency), unless the string is genuinely about one currency by decision —
metal prices are quoted `USD/t` by market convention, and account names
like `Bank – SGD` are proper nouns. Those stay.

## Making the page agree with the server is only right when the server is right

A page that offers something the server will reject is **a question about the
rule**, not automatically a bug in the page. Ask which one is wrong before
changing either.

This has now gone the wrong way once, and it cost a real feature. The payment
screen listed documents that `record_payment` refused with
`ALLOC_CURRENCY_MISMATCH`, so the list was filtered to match. But the
constraint was itself too strict — a customer owing USD 6,000 who pays in SGD
**has settled that invoice**. Filtering the page made the mistake harder to
see: the option simply stopped existing, and a missing feature looks exactly
like a deliberate restriction. FIN-16 removed the constraint and the filter
together.

So when the two disagree:

* **If the server is right**, do not offer the action — disable the control
  and say why. (An over-allocated payment, a closed period, a settled cost
  entry: the server is right, and the page should not present a button whose
  only outcome is an error.)
* **If the server is wrong**, fix the server. A UI filter over a wrong rule
  buries it — the rule stops producing errors, so nothing ever prompts the
  question again.

The tell for the second case: the rejected action is one a person would
reasonably want to take, and the error message describes a *policy* rather
than an inconsistency. `ALLOC_CURRENCY_MISMATCH` said "this document is USD
and your payment is SGD", which is a policy statement. `ALLOC_EXCEEDS` says
"you are allocating more than is outstanding", which is an inconsistency.

## A screen that previews a posting ASKS the database what it will be

**Never re-implement a posting rule in TypeScript so a page can show a
preview.** Call the function that will do the posting — or a read-only
companion that shares its arithmetic — and render what it returns.

This has now been the same bug four times:

1. the assay impact preview (Phase 4 cut 5b),
2. the GrantRunner leave formula (deleted in HR-2c),
3. the revaluation preview (FIN-9 — the page's own aggregation had already
   drifted from `revalue_foreign_balances`, and the number it showed was
   about to be posted),
4. `/finance/payments` (FIN-12 — the form computed its own FX rate with a
   base-currency constant left over from before FIN-0 flipped the base to
   SGD, so a base-currency payment valued at **0.00** and a USD payment
   valued at **1:1**).

The failure is always the same shape: the two implementations agree on the
day they are written and drift silently afterwards, and the screen is the
one people trust because it is the one they can see.

**The pattern that works** is already in the repo: `reprice_split` shared
by `reprice_inbound_batch` and `preview_reprice_inbound_batch`;
`preview_revalue_foreign_balances` called by both the page and
`revalue_foreign_balances`. Add a preview function beside the writer, or
call the writer's own helper. One implementation, two callers.

**Corollary — the page must not disagree with the server about units or
eligibility either.** If the server validates in document currency, the
page shows document currency (`/finance/payments` was subtracting
document-currency allocations from a base-currency amount). If the server
will reject a combination, the page must not offer it: never render a
submit control for an action the server is guaranteed to refuse.

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
