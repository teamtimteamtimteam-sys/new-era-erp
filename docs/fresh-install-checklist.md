# Fresh install checklist

Standing up a new Evoltrya OS project from this repository.

> **Note.** No such checklist existed in this repository before OPS-2 C0 —
> `bootstrap-first-admin` is named as a step below but **has no script in this repo**
> (see "Known gaps"). This file records the agreed order so it is not carried around
> in someone's head.

## The checklist

1. **Create the Supabase project.**
2. **Run the rebuild** — `db/platform-prelude.sql`, then `db/functions/`, then
   `db/tables/` in dependency order, then `db/views/`. See the prelude's header for
   the exact procedure and the two caveats (the missing trailing semicolons, and the
   platform objects the mirrors do not contain).
3. **Run any C0.5 scripts.** *Currently none* — every intended default is expressible
   as a bootstrap seed and is applied by step 2. If that ever stops being true, the
   script's invocation goes here.
4. **Run bootstrap-first-admin** — link the first `auth.users` row to the `admin`
   role. Until this runs, `user_roles` is empty and nobody can read anything.
5. **Verify login.**
6. **Disable public signup** in Supabase Auth.
7. **Enter the per-install values** (these cannot be seeded — they are this company's
   data, not a design default):
   - `company_profile` — legal name, registration number, address, city, postal code,
     country, phone, email, website, logo, invoice footer text.
   - `company_profile` banking — bank name, account name, account number, SWIFT,
     bank address. These print on invoices.
   - `finance_settings` — GST registration number and rate, **once the company is GST
     registered**. The seeded default is "not registered, 0%", which is the correct
     starting state, not a placeholder to be overwritten immediately.
   - `hr_settings` — only if this company's figures differ from the seeded defaults
     (medical limit SGD 1,000, 5-day week, 12-month carry-forward).
8. **Update Vercel environment variables** — project URL, anon key, service role key.

## What step 2 already gives you

The bootstrap defaults are the *intended design*, not a snapshot of any particular
install. After step 2 a fresh database has:

| | |
|---|---|
| permission catalog | 33 codes (INSTALL SEED, row-compared) |
| chart of accounts | the 22 engine-referenced accounts (INSTALL SEED, row-compared) |
| currencies | SGD, USD (INSTALL SEED, row-compared) |
| roles | the nine working roles + the retained inert `employee` row |
| role grants | 159, separation of duties intact, `edit` always paired with `view` |
| leave types | the 13 handbook types |
| public holidays | 2026, 14 days |
| review rating scale | 4 levels |
| leave accrual rates | office 24 / shopfloor 18 days per year |
| HR settings | medical SGD 1,000, 5-day week, 12-month carry-forward |

Everything above is applied by plain `INSERT` during the replay, so **step ordering
inside step 2 is handled by the mirror toposort** — `permissions` (22) and `roles` (27)
both replay before `role_permissions` (51). No manual ordering is required.

## Known gaps

- **`bootstrap-first-admin` has no script in this repo.** `db/tables/user_roles.sql`
  carries the shape in a comment:
  ```sql
  INSERT INTO user_roles (user_id, role_id)
  SELECT u.id, (SELECT id FROM roles WHERE code='admin') FROM auth.users u;
  ```
  Until it exists as a checked-in script, step 4 is a manual paste, and a fresh
  install has a window where no account can read anything. `guard_last_admin`
  protects the *last* admin from being removed; nothing creates the *first* one.
