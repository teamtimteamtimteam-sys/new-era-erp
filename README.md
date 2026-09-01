# EVoltrya OS

An ERP for a lithium-battery recycling business, built around one axiom: **a conventional ERP starts
from accounting documents; this one starts from physical materials.** Financial results are produced by
material movement, production conversion, batch yields and compliance decisions — so the system
traces the whole chain, from supplier batch through processing to output batch, sale and general
ledger, and generates the accounting from it rather than having it re-keyed.

Next.js 16 + TypeScript on Supabase (PostgreSQL), bilingual EN/ZH, deployed on Vercel.

## Read these first

The plan is not summarised here — it lives in three documents, and they are the source of truth for
what the system is and what order it gets built in:

| | |
|---|---|
| [`docs/Evoltrya-OS-Doc1-Requirement Discovery.pdf`](docs/Evoltrya-OS-Doc1-Requirement%20Discovery.pdf) | **Document 1 — Requirement Discovery.** The exhaustive functional scope, open questions and business decisions, module by module. |
| [`docs/Evoltrya-OS-Doc2-System-Blueprint.pdf`](docs/Evoltrya-OS-Doc2-System-Blueprint.pdf) | **Document 2 — System Blueprint.** Architecture, the ten design principles, the module map, and current-state positioning. |
| [`docs/Evoltrya-OS-Doc3-Roadmap.pdf`](docs/Evoltrya-OS-Doc3-Roadmap.pdf) | **Document 3 — Roadmap.** The phased build plan: Phase 0 through Phase 6 plus a final unified-permissions pass, each with deliverables, dependencies and a definition of done. |

**[`docs/as-built-divergences.md`](docs/as-built-divergences.md)** sits beside them: the places where
the code and the documents disagree, each quoting the document and stating the as-built position, and
each marked with which way it points — document ahead of the code, document simply wrong, or
document behind a deliberate improvement. **The three documents are never edited to match the
code** — they are the record of what was planned; the divergence is recorded next to them instead.

**[`AGENTS.md`](AGENTS.md) is required reading before changing anything.** It is a different kind of
document from the three above: where those state the plan, `AGENTS.md` records the rules that were
learned by getting things wrong — the FX rule, the database gate, the mirror convention, why a check
that reports but does not enforce is not a gate. Nearly every rule in it exists because something broke.
It is prescriptive and it overrides habit.

Where the two disagree, `AGENTS.md` describes what the code does today and the documents
describe where it is going; neither silently wins. The differences are enumerated in
`docs/as-built-divergences.md`.

## Working on it

```bash
npm run dev                      # dev server
npm run build                    # runs check-currency-literals + check-i18n, then next build
python3 db/gate.py               # the database gate: rebuildability, mirror drift, behavioural fixtures
node scripts/smoke-routes.mjs    # renders every route against a real dev server
./db/apply_migration.sh db/migrations/<file>.sql   # the only sanctioned way to change the database
```

`db/` mirrors the live schema so it can be rebuilt from the repository — tables, functions and views,
plus `db/fixtures/` (behavioural assertions that run on a rebuilt database) and `db/migrations/`
(changelog only; the install path is entirely mirror-based). `db/gate.py` must exit 0 before any commit
that touches the database.

## Other documentation

* `docs/known-issues.md` — structural problems that survive a rebuild: known, accepted, deliberately unfixed.
* `docs/known-wrong-until-cutover.md` — things that look wrong in the test database and vanish on a production rebuild.
* `docs/fresh-install-checklist.md` — what a brand-new database needs before it is usable.
* `docs/currency-literals-audit.md`, `docs/empty-string-to-rpc-audit.md`, `docs/error-swallowing-audit.md` — full call-site inventories behind three of the standing checks.
