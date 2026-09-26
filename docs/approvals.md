# Approvals — the decisions, and the states you will meet

**This file exists so that three things are met as DECISIONS rather than as unfinished work.**
Each of them looks, to a fresh reader, like something to go and fix. None of them is.

The precedent for writing them down at all is the anonymisation function: it **permanently refuses
by decision** (employee data is retained by ruling), and without its note the next reader meets a
refusal and starts "fixing" it. The three below have exactly that shape.

Mechanism and history: `docs/approvals-scoping.md` (note its §3 and decision rows 1–2 are
**superseded** as of 2026-08-30 — superseded in place, not deleted).

---

## 0 · THE CONFIGURED CHAIN — set 2026-08-30 (CHAIN-CONFIG-1)

| | level 1 | level 2 |
|---|---|---|
| **role** | `finance` | `cfo` |
| **applies to** | amounts **below** the threshold | amounts **at or above** it |
| **threshold** | **SGD 1,000** — `finance_settings.approval_threshold_base = 1000` | |

**The threshold is in BASE currency, and the base currency is SGD** (`currencies.is_base`,
measured 2026-08-30). ~~`approval_level_for(p_amount_base)` compares `p_amount_base >= v_threshold`~~
— ★ **APR-3 (2026-09-22) moved that one comparison into `approval_level_at(amount, threshold)`**, and
`approval_level_for(amount)` now delegates to it. **The rule did not change a character**: `>=`, so
**"at or above" is exact** — 999.99 → level 1, **1000.00 → level 2**, 1000.01 → level 2.

> **Why it moved, because "tidying" is the wrong reason and someone will assume it.**
> `guard_approvals_switch` is a `BEFORE UPDATE` trigger, so a function that reads
> `finance_settings` itself sees the **OLD** row. `APPROVALS_POLICY_WOULD_STRAND` has to re-tier
> pending documents under the **NEW** threshold — with the old entry point it would have judged the
> previous policy and gone green. Same trap `approval_gate_intersections` records in its own header,
> same remedy: pass the NEW value in as a parameter.
> ☞ **The repository still contains exactly one `>=` for tiering**, and the migration's self-proof
> ⑩ asserts both halves: it is present in `approval_level_at` **and absent from
> `approval_level_for`**. Without the second half, an implementation with two copies would pass.

Pinned by `db/fixtures/151` arm T, with a fault injection that flips `>=` to `>` and asserts the
exactly-at-threshold case degrades — because that single value is the only one of the three that can
tell the two implementations apart. ★ **APR-3 re-pointed that injection at `approval_level_at`**:
the predicate moved house, so the injection had to move with it, or it would have replaced nothing
and the arm would have gone quiet. (The same lesson C-1 left in that file when the holder predicate
moved to `real_role_grants`.) **The assertions still call `approval_level_for`** — the production
entry point — so the arm still proves what it claims to.

**`cfo` was created holding exactly two permission codes** — `module.purchasing.view` and
`data.view_prices` — which is the measured minimum to approve a purchase order (`approve_purchase_order`
checks both; the document page needs the first). **It deliberately does NOT hold
`module.purchasing.edit`:** an approver who can raise the document he approves is not a control.

> ### ★ EQP-PAY-1 (2026-09-01): `cfo` now holds FOUR codes — and the two added ones need a WRITTEN reason
>
> Tim's ruling, verbatim: **"the CFO reviews payroll expenditure."** Granted:
> **`module.finance.view`** and **`data.view_pay`**. Measured before and after with a
> real-role probe (a session holding `cfo` and nothing else):
>
> | | before | after |
> |---|---|---|
> | `module.purchasing.view` | ✓ | ✓ |
> | `data.view_prices` | ✓ | ✓ |
> | `module.finance.view` | — | **✓** |
> | `data.view_pay` | — | **✓** |
> | total | 2 | **4** — the migration's own self-check refuses any other number |
>
> > ### ★ APR-0 (2026-09-22): **`cfo` holds FIVE codes today, not four.**
> > Measured as `postgres` from `role_permissions`: `data.view_pay` · `data.view_prices` ·
> > `module.finance.view` · ★ **`module.logistics.view`** · `module.purchasing.view`.
> > ☞ **The fifth is accounted for and is not a drift**: `2026-09-01-navreg1-logistics-gets-its-own-code.sql`
> > carved logistics out into its own permission code **the same day**, granting it to the six roles
> > that could already see those pages — its own header says 「可见性不变」. So `cfo` gained a code
> > and gained **no** new visibility.
> > ★ **What IS worth keeping:** that migration's self-check "refuses any other number" was true for
> > about as long as it took a second migration on the same date to make it false. **A self-check
> > pinned to a total is pinned to a number that another cut can move for an unrelated and perfectly
> > good reason** — and the sentence it leaves behind reads like an invariant.
> > ☞ **The structural thing this table asserts is still true and is the part that matters:**
> > `cfo` still does **not** hold `module.purchasing.edit`. The approver still cannot raise the
> > document he approves.
>
> **Why the CFO sees INDIVIDUAL pay figures and not an aggregate staff-cost line.**
> Reviewing payroll expenditure means being able to answer *"why is this month twenty
> thousand higher?"* — and that answer is always one person's one item: a raise, a bonus,
> a mid-month joiner. **An aggregate shows the question and hides the cause, and a review
> that can see a problem but cannot reach its cause is not a review.**
>
> **Why this is written down rather than left in the grants table.** Employee remuneration
> is personal sensitive data. **Who may see it has to be answerable in words, not inferred
> from a join table** — a grants table can say *who can look*, never *on what grounds*.
> The same sentence is in the migration header (`2026-09-01-eqppay1-a-the-cfo-grant.sql`);
> both copies are deliberate, because the two readers arrive from different directions.
>
> **What was NOT granted:** nothing else. Probed and confirmed absent for a cfo-only
> session: `module.finance.edit`, `module.hr.view`, `action.manage_permissions`.
> The CFO can **read** payroll detail; it cannot edit finance, cannot open HR, and
> cannot grant itself anything.
>
> **It closes a known issue.** `docs/known-issues.md` CFO-NO-FINANCE-VIEW —
> `gl_control_reconciliation` and `management_pack_data` refused `cfo` outright.
> Both probed as a cfo-only session after the grant: **OK**.
>
> **A gap this does NOT close, recorded rather than fixed:** the `cfo` role is **absent
> from the bootstrap** (`db/tables/roles.sql` seeds nine roles and `cfo` is not among them;
> `role_permissions.sql` therefore grants it nothing). It was created live by CHAIN-CONFIG-1.
> So **a rebuilt database has no `cfo` at all**, and this ruling would not survive a fresh
> install. That predates this cut and fixing it means seeding a role *and* its grants —
> deliberately out of scope here (the cut's own rule was "grant nothing not named"),
> but it is a real divergence and someone should rule on it.

**`finance` was accepted as level 1 as-is** — no third role was built for two people, and
`module.purchasing.edit` was **not** removed from it. The consequence is visible on the settings
panel as `level1_holders_who_cannot_raise = 0` and is reported, not enforced (SOD-1 fu2's standing
decision).

> **A present-state limitation, recorded rather than designed around.** Tim holds **`admin` and
> `cfo`**, and permissions are the **union** of a user's roles — `admin` carries
> `module.purchasing.edit`. So excluding that code from `cfo` **buys nothing today**. Its value is
> that the chain no longer names a person: the control becomes real the day someone other than Tim
> holds `cfo`. **Expiry condition: a second person holds `cfo`.**

---

## 0b · NEITHER LEVEL MAY BE POINTED AT `admin` — a decision, deliberately NOT machine-blocked

**Ruled 2026-08-30. This is the tempting wrong answer, so it is written down rather than left to
judgement.**

CHAIN-BUILD-1 measured that **`admin` is the only role that passes every readiness check today** —
it is the sole role with an account that can actually sign in. That makes it the obvious way to get
the switch to flip, and it is **rejected on principle**:

> **`admin` is *system administration* — it is the only holder of `action.manage_permissions`.
> Making it an approval level conflates "can configure the system" with "can commit the company's
> money".** The person who can grant themselves any permission must not also be the person who
> approves the spending.

> ### ★★ APR-0 (2026-09-22): **`admin` is NOT the only holder of `action.manage_permissions`. `cco` holds it too — and that is now a RECORDED DECISION, not a discovery left lying around.**
>
> **Measured as `postgres`, reading the tables `roles` / `role_permissions` / `user_roles`:**
>
> | role | `action.manage_permissions` | `module.finance.edit` | real holders | total codes |
> |---|---|---|---|---|
> | `admin` | ✓ | ✓ | 1 (`admin@swm-os.test`) | — |
> | ★ `cco` | ★ **✓** | ✗ | 1 (`sandra@evoltrya.test`) | ★ **37** |
>
> ☞ **`cco` is admin-equivalent in every way that matters to this page**: it can open
> `/settings/approvals` (gated on `action.manage_permissions`), and it also holds
> `module.purchasing.edit` **and** `data.view_prices` — so it can raise a purchase order *and*
> see its amount.
>
> ★ **Tim's ruling, 2026-09-22: ACCEPT this for now, and WRITE IT DOWN. Do not revoke in this
> work** — revoking `action.manage_permissions` from a 37-code role has a blast radius far beyond
> approvals and belongs to its own cut.
>
> ☞ **What this does NOT change:** §0b still stands in full. Neither approval *level* may be
> pointed at `admin` — **or at `cco`**, for the identical reason and now with a sharper edge:
> `cco` can raise the document it would approve, which `cfo` deliberately cannot.
> ☞ **Why it is recorded rather than noted in passing:** the sentence above ("it is the only
> holder") is the kind of premise later cuts reason *from*. It was true when written. This file
> has now been caught twice carrying a stale fact past its expiry — see the strike in §3.

> ### ★★ APR-2 (2026-09-22): the rule is satisfied in its LETTER and violated in its SUBSTANCE — **the `cfo` role's only real holder IS the `admin` account**
>
> **Measured as `postgres`, reading the tables `user_roles` / `roles` / `role_permissions` /
> `auth.users` through `real_role_holders()`:**
>
> | role | real holders |
> |---|---|
> | `admin` | 1 — `admin@swm-os.test` |
> | ★ `cfo` (the configured LEVEL 2) | 1 — ★ **`admin@swm-os.test`, the same account** |
>
> §0b is a rule about **role codes**, and by that measure it is kept: level 2 points at `cfo`, not
> at `admin`. **The collision is one level down, at the HOLDER.** The sentence this section is
> built on — *"the person who can grant themselves any permission must not also be the person who
> approves the spending"* — is about a **person**, and today that is one person.
>
> ★ **Recorded as a known fact awaiting Tim, NOT fixed in APR-2 and NOT to be machine-blocked.**
> The remedy is a second human holding `cfo`, which is Tim's call and not a code change; and §0b
> already rules that a machine rule here would be a second, narrower definition of who may approve.
> ☞ It is written down for the same reason as the strike in §3 and the correction above:
> **this file has now been caught three times carrying a premise past its expiry.** Whoever reads
> "level 2 is `cfo`, so system administration and spending approval are separated" is reasoning
> from something that is not true of the live data on 2026-09-22.

This was already the position in `docs/approvals-scoping.md` §3, and **that part of §3 is not
superseded** — only the rows about *who* level 2 is were.

**It is deliberately not enforced in code.** A rule forbidding one role code would be a second,
narrower definition of who may approve, sitting beside `real_role_holders()` — and this repository
has paid repeatedly for two definitions of the same thing. It would also be trivially sidestepped by
granting `admin`'s codes to another role. **The protection is that it is written here**, not that
the database refuses it.

**Do not** point either level at `admin`, **do not** propose it as a temporary measure to make the
switch flippable, and **do not** build a rule forbidding it.

---

## 1 · There is deliberately NO DEPUTY and NO ESCALATION

**Ruled 2026-08-30. Implemented in CHAIN-BUILD-1.**

The chain has two levels. **Each level stands alone.**

> **If the holder of a level is unavailable, documents at that level WAIT.
> Nothing routes around them. That is the accepted outcome, not a gap.**

There is no deputy, no escalation, no timeout, no auto-approve, no break-glass path. **Do not build
one.** If you are reading this because approvals appear to be stuck, the system is doing what it was
told to do; the fix is a person, not a code change.

**Mutual deputising was considered and rejected**, and the reason is worth keeping because it is not
obvious: two approvers who can each cover the other's level **make the amount threshold meaningless**
— the whole point of a second level is that a larger commitment needs a different person, and mutual
cover erases exactly that distinction. Adding a second approver is a **division of labour**, not a
deputy arrangement.

**How the stall is made visible instead of routed around:** the settings panel names the role for
each level, says how many people hold it, and distinguishes the three states below. The stall is
therefore *named*, which is the only thing this design owes you.

> ### ★ APR-2 (2026-09-22) adds the half this paragraph could not see
>
> "How many people hold the role" is **not** the same question as "how many people can actually
> approve". A holder who cannot open the document approves nothing. `/settings/approvals` now shows,
> per wired chain and level, **how many real people hold the approver role AND the permission the
> action itself requires** — and the switch refuses to turn on while any of those is zero.
> ☞ Without it, "the stall is named" was only true of the stalls this paragraph imagined.
> The work-order chain stalled for a reason nothing named (see §3c N7).

---

## 2 · A holder who CANNOT SIGN IN is deliberately NOT a holder

**Ruled 2026-08-30 (R3). Implemented in CHAIN-BUILD-1 as `real_role_holders()`.**

"Who counts as an approver" has **exactly one definition**, and it is that function. Four clauses:

| # | clause | where it comes from |
|---|---|---|
| ① | the grant is not revoked (`user_roles.revoked_at IS NULL`) | **a defect fix**, see §4 |
| ② | the account is confirmed (`auth.users.confirmed_at IS NOT NULL`) | R3 |
| ③ | the account is not banned | R3 |
| ④ | the account is not deleted | R3 |

**Why ② matters more than it looks.** Before this, the predicate joined `auth.users` on *existence*.
An account row that had never confirmed its email — an account that **cannot sign in at all** —
counted as a working approver. Enabling approvals would then have **succeeded**, and every document
would have queued to somebody who could never open them. The refusal you now get instead is the
system telling the truth earlier.

**This is what makes the enable-time refusal honest.** A gate that counts people who cannot arrive
is not a gate.

> **On ③, two facts recorded so nobody mistakes it for the clause doing the work:** it is **not**
> load-bearing on today's data (the banned accounts are excluded by ① anyway), and `banned_until`
> appears **nowhere else in this repository** — those bans were applied outside the codebase. It is
> kept only because R3's words are "can actually sign in", and a banned account cannot.

---

## 3 · ~~TODAY, APPROVALS CANNOT BE SWITCHED ON~~ — ★ **THE BLOCKER EXPIRED. APPROVALS CAN BE SWITCHED ON TODAY** (APR-0, 2026-09-22)

> ### ★★ **APR-0 (2026-09-22) — struck in place, with the receipt** ★★
>
> **The blocker this section named is gone. `can_enable` is `true`.** Not because anything was
> loosened — **because the expiry condition written below was met and nobody noticed.**
>
> **Measured 2026-09-22, as `postgres` over the Management API (RLS bypassed), reading the
> TABLES `auth.users` and `user_roles` and the function `real_role_holders()`:**
>
> | level | role | holders_total | real_holders | can_see_amounts | state |
> |---|---|---|---|---|---|
> | 1 | `finance` | 1 | ★ **1** ★ | true | **a working holder** — `chooer@evoltrya.test` |
> | 2 | `cfo` | 1 | **1** | true | a working holder — `admin@swm-os.test` |
>
> **All six live accounts are confirmed, none banned, none deleted.** So
> `blocking = []` · **`can_enable = true`** · `pending_purchase_orders = 0` · **`can_disable = true`**.
>
> **Read what that second pair means before flipping anything:** nothing is in flight, so turning
> approvals ON strands no document, and turning them back OFF is free **for exactly as long as that
> stays true**. The moment one purchase order is pending, `guard_approvals_switch` refuses to
> disable by name (`APPROVALS_CANNOT_DISABLE_WITH_PENDING`).
>
> **The account named below as the expiry condition is not the one that satisfied it.** This section
> said the nearest candidate was `chef1949@126.com` confirming her email. Live carries no such
> account today; `finance` is held by **`chooer@evoltrya.test`**, which **is** confirmed. Whether
> that is the same person on a new address or a different grant entirely is not something this
> survey can tell from the schema, and it is **not** guessed at here.
>
> ### ☞ The lesson, which is why this is struck in place rather than rewritten
>
> ★ **An expiry condition written into a document does not fire.** This one was stated precisely,
> it came true, and the document went on asserting the opposite for three weeks — while
> `docs/approvals.md` §3 is the exact page someone reads to answer "can we turn approvals on yet".
> The three cuts between CHAIN-CONFIG-1 and APR-0 all read this section and all inherited a
> blocker that had expired.
> ☞ **Nothing in this repository watches an expiry condition.** The cheap habit is the one this
> cut used: **a survey re-measures every premise its brief hands it, including the ones that are
> written down as settled facts** — and APR-0's brief handed it this one as a settled fact.
>
> **APR-1 is the cut that acts on this** (the RPC, the guard, the history table, the write path).
> **Approvals stay OFF until then** — Tim's ruling, 2026-09-22: they get turned on **once, from a
> screen, by a person**, not by a direct database write. Turning them on today by hand would be the
> very thing that cut exists to end.

<details>
<summary>★ The original note, kept verbatim — it is the argument for why the refusal was honest while it lasted</summary>

> **Updated 2026-08-30 (CHAIN-CONFIG-1): the chain is now CONFIGURED, and it still cannot be
> enabled — for a sharper reason than before.** The blocker is no longer "nothing is set"; it is
> that **level 1's only holder cannot sign in**. Measured on the configured chain:
>
> | level | role | holders_total | real_holders | state |
> |---|---|---|---|---|
> | 1 | `finance` | **1** | **0** | ★ **a holder exists but cannot sign in** ★ |
> | 2 | `cfo` | 1 | 1 | a working holder |
>
> `blocking = ["approval_level1_holder_cannot_sign_in"]`, `can_enable = false`.
> Attempting to enable refuses, verbatim:
>
> ```
> APPROVALS_LEVEL1_HOLDER_CANNOT_SIGN_IN|finance|1
> ```
>
> **Note which of the three states this is.** It is *not* "nobody holds `finance`" — somebody does
> (Choo Er Teh). Granting the role to somebody again **would change nothing**; the account needs to
> become able to sign in. That distinction is the whole reason the two counts exist.
>
> **Expiry condition: a second account can actually sign in** — in practice, `chef1949@126.com`
> confirming her email. That is an open item owned by Tim and is deliberately not touched by any
> cut. When it happens, `finance` gains a real holder and the chain becomes enableable with no code
> change.

</details>

**The original note below is kept — it is why the refusal was honest rather than a bug.**

> ### ★ APR-0 (2026-09-22): **the three readings below are SUPERSEDED. The reasoning is not.**
> **`finance` reads `real_holders = 1` today, not 0, and `admin` is no longer the only role that
> passes.** So the sentence *"pointing either level at any role other than `admin` will refuse on
> enable"* and the sentence *"the truth is that nobody can approve"* are **both false as of
> 2026-09-22** — see the struck section at the top of §3 for the measured replacement.
> ☞ **What survives unchanged is everything the block was actually arguing**: the four-clause
> predicate, why ② matters, and the `Do not` list that follows it. **Those were never about the
> numbers.** The numbers were the occasion; the predicate is the point.

**Present state, measured 2026-08-30. EXPECTED. Do not "fix" it by loosening the predicate.**

After CHAIN-BUILD-1, **exactly one account in the entire system is an eligible approver**
(`admin@swm-os.test`). Measured, per role:

| role | counted before this cut | after ① (revoked filter) | after ②③④ (R3) |
|---|---|---|---|
| `admin` | **6** | 1 | **1** |
| `finance` | 1 | 1 | **0** |

So **pointing either level at any role other than `admin` will refuse on enable**, by name.

**The truth is that nobody can approve.** The old predicate hid that behind a number; this one says
it out loud, at the moment the state is fully knowable and the consequence is total.

> **Expiry condition: a second account becomes able to sign in.**
> The nearest one is `chef1949@126.com` (Choo Er Teh, holds `finance`), whose email has never been
> confirmed. That is an open item owned by Tim and is **deliberately not touched by any cut** —
> confirming it is not an engineering decision.
>
> ★ **APR-0: this condition has been MET** (by `chooer@evoltrya.test`, not by the account named
> here). It is the second time in this file that a written expiry condition came true silently.

**Do not**, in order to make the switch flippable today: loosen `real_role_holders`, add an
override flag, add a "force enable", or point a level at `admin` merely because it is the role that
happens to pass. The last one is not blocked by the machine and is the tempting one — it would make
*system administration* the approver of *company money*, which `approvals-scoping.md` §3 already
rejected on principle, and that part of §3 is **not** superseded.

---

## 3b · THE SWITCH NOW HAS A DOOR — and the door is `action.manage_permissions` (APR-1, 2026-09-22)

**Ruled by Tim, 2026-09-22 (APR-0 Q2). Built by APR-1.** Approvals were still **OFF** when this
shipped and this cut deliberately never turned them on: Tim turns them on himself, once, from the
screen.

### What exists now

| | |
|---|---|
| **the only write path** | `set_approvals_policy(enabled, level1, level2, threshold)` — `SECURITY DEFINER`, checks **`action.manage_permissions`** |
| **the guard** | `trg_approvals_policy_write_gate` → `guard_approvals_policy_write()` on `finance_settings`, **column-scoped**, refuses by name: `APPROVALS_POLICY_DIRECT_WRITE|<the columns that changed>` |
| **the trail** | `finance_settings_history`, append-only, written by the same RPC |
| **the screen** | `/settings/approvals` — reads, writes, and shows the last ten changes |

**Why the code is `action.manage_permissions` and not `module.finance.edit`.** The table's own
write gate is `enforce_write_permission('module.finance.edit')`, and that code is held by
`admin`, `finance` and `gm` — ★ **`finance` is the ruled level-1 approver.** A control its own
approver can rewrite is not a control. That is the whole of `APR0-APPROVALS-SWITCH-WRITE-GATE`.

### ★★ How the guard knows a change came through the RPC — and the part that is NOT the boundary

**Two tests. The load-bearing one is identity; the marker is precision inside the owner boundary
and could never have been the boundary.** This is written out rather than summarised, because the
tempting design is the other way round.

**Measured live, 2026-09-22, in a rolled-back probe, as `postgres` over the Management API:**

```
row_security_active('public.finance_settings')   as postgres       →  false
                                                 as authenticated  →  true
set_config('evoltrya.apr1_forge_probe','1',true) as authenticated  →  ★ SUCCEEDED,
                                                    read back '1', no error
SET LOCAL row_security = off                     as authenticated  →  accepted, but
   row_security_active is STILL true, and any read errors with
   "query would be affected by row-level security policy for table finance_settings"
```

☞ **A custom-namespace GUC is not a permission. It is a value anybody with a SQL channel can
write.** So the flag can only ever mean *"this write path said out loud that it is writing these
four columns"* — it can never mean *"this caller is allowed to"*.

☞ **`row_security_active` cannot be armed.** It is not a value; it is a fact about who the caller
is. Becoming exempt means *being* the table owner or running inside a `SECURITY DEFINER` function
owned by it — a grant, not a setting. The obvious attack closes the door harder rather than
opening it.

★ **The guard is INVOKER-rights, deliberately.** `row_security_active` has to reflect the
**caller**; `enforce_write_permission` carries the identical sentence in its own header and is the
only other guard in the repository that is not `SECURITY DEFINER`. A `DEFINER` guard here would ask
about itself, answer "RLS is not in force", and **pass everything while staying green**.
`db/fixtures/202` arm P pins it.

★ **Consumed on use.** `set_config(..., true)` is **transaction**-local, not statement-local —
PUR2-FU2 (2026-08-11) was caught by its own probe on exactly this. So the guard clears the flag on
the first row it passes: one arming authorises one write, never "the rest of the transaction".
`finance_settings` is a single-row table, so one statement is one row and this is exact.

### ★★ SAY THIS PLAINLY: the guard does NOT stop `postgres`, and nothing can

The owner can drop the trigger. **The boundary this builds is: no RLS-bound caller can change
those four columns — including the level-1 approver who holds `module.finance.edit`.** That is the
hole that was registered, and it is the hole that is closed.

Migrations and fixtures can still write those columns directly, and they must **arm the flag** to
do it — which means every direct write states its intent in the source. **Five fixtures do, at 23 sites** (`35`×3 · `52`×1 · `75`×1 · `127`×8 · `151`×10). That is the
same idiom as `evoltrya.po_status_ctx` in fixture 127. A 24th arming lives in fixture `202` and is
not a legitimate write: it is the **forgery attempt** — arm the flag as `authenticated` and confirm
the write is still refused, because the boundary is not that value.

### Considered and rejected: revoking the column privilege

`REVOKE UPDATE (the four columns) ON finance_settings FROM authenticated` is a real privilege
boundary. **Column privileges are checked before triggers fire**, so the caller would get
`42501 permission denied for table finance_settings` — an **unnamed** refusal that eats the named
one. Tim ruled against it, 2026-09-22: the named refusal is the requirement.

### What the screen says, and to whom

* **All four values are saved together**, because `guard_approvals_switch` judges them together.
* **`can_enable` / `can_disable` and their reasons are shown before anything is pressed**, read
  from the same `approvals_readiness()` the gate reads. The screen is not a second gate — bypass
  it and the database still refuses by name.
* ★ **`admin` and `cco` ARE listed in the role pickers**, with §0b's sentence beside them. §0b
  rules that this must not be machine-blocked; **a dropdown that quietly drops them enforces the
  rule while leaving no trace of it**, and the next reader would assume the database refuses it.
* ★ **There is no read-only viewer of this page, by construction.** The page gate, the RPC gate and
  (after N6) `approvals_readiness()`'s internal check are the **same code**. The screen says so.
* **Editing the policy while approvals are ON is allowed** and says what it does to pending
  documents. Whether it should be locked is an open question for APR-2 — `guard_approvals_switch`
  only forbids *clearing* a value while on.

### N6 — the screen and the function it calls now read one judgement

`approvals_readiness()`'s internal check moved from `module.finance.view` to
**`action.manage_permissions`**, matching the page gate. Today `admin` and `cco` hold both, so
nothing visible changed; the day someone holds one and not the other, that page would have
rendered as `readError` — which reads like "could not load", not like "you may not".

### The trail is deliberately empty on the day it shipped

`finance_settings_history` records changes **made through the RPC**. The live row
(`false · finance · cfo · 1000`) was set by a direct database change before this screen existed,
and **that change is not invented here**. Blank is better than fabricated — the same rule as
`pricing_formula_history`'s "edits before the trigger have no rows". The screen's empty state says
this in words, because an empty trail otherwise reads as *"this policy has never been changed"*,
which is a false assertion about internal control.

---

## 3c · RULINGS THAT SHAPE APR-2 ONWARD — Tim, 2026-09-22

**Recorded here because they were made in conversation and must not live only there.** They answer
the six open questions APR-0 §5.2 handed back. **Sequencing lives in `docs/forward-queue.md`; the
reasoning lives here.**

### N1 — documents with no header total get a maintained base-currency total

> ★★ **SUPERSEDED for `sales_orders`, `quotes` and `credit_notes` (Tim, 2026-09-25, APR-5 grilling Q1).**
> Tim's role matrix (2026-09-23) routes none of the three by amount: sales orders, quotes and sales invoices need
> **no** approval, and the two sales-side decisions that do — the pre-shipment release (N2) and credit notes / invoice
> voids — go to the CFO **every one, fixed at level 2, no threshold**. There is no tier for a line edit to cross, so the
> reason below has nothing left to protect. Every amount the CFO sees or the log records already exists stored:
> a credit note's `amount_base` comes from the engine's dry run, a void's from `invoices.total_base`, a release's from the
> covered invoice lines. A line changed after a release cannot happen: a release covers invoiced lines, and those are
> frozen (`SO_AMEND_LINE_INVOICED`). **N1 stands for `journal_entries` only, with N5's cut.** See §3q.
>
> ★★ **RETIRED for `journal_entries` too (Tim, 2026-09-25, APR-6 grilling Q2).** Every manual journal and every reversal goes to the
> CFO, fixed at level 2, no threshold — there is no tier for an edit to cross, and a request's lines are frozen on the request while a
> posted entry's lines are immutable. The amount the CFO sees and the log records is Σ debits in base currency from the submit-time
> dry run (then the posted entry's). **N1 is now retired everywhere.** See §3s.

`sales_orders`, `quotes`, `credit_notes` (and `journal_entries` when its turn comes) **get a
maintained base-currency header total, the same shape as `purchase_orders.estimated_total_ccy`**.
Schema change plus maintenance triggers — **its own cut.**

**Why, and it is not tidiness:** `void_approval_on_amount_increase` — "an increase to a higher tier
voids and re-routes" — reads the **header column's** OLD/NEW. Compute the total on the fly instead,
and a line-level edit is **invisible to that trigger**: an approved document could be edited up into
a higher tier with nothing voiding it. That is precisely the thing this engine already built a
mechanism to prevent.

### N2 — "container loading" and "shipments" are removed from the approval list

They are **records of events, not documents**. There is no `load_container()`; `containers` has no
status column and loading is a `container_milestones` row. `shipments` has no status column at all.
Approving them would mean **first inventing a lifecycle for them**, which changes what they *are*.

**The business need behind them is met instead by a pre-shipment release approval on the SALES
ORDER** — which is a document, has a status, and is where "someone must approve before goods leave"
actually belongs. It joins **APR-5**.

### N3 — purchase-order amendments keep the existing mechanism

An increase to a higher tier voids and re-routes; the same tier or lower does not. **No second
approval mechanism.** Two mechanisms governing one event would disagree on the down-tier case (the
existing one says no re-approval is needed; a new one would say every amendment needs approval).
If "every amendment needs a nod" is ever wanted, it **replaces** that trigger's rule rather than
stacking on it — and the replacement has to rule on the case it currently handles.

### N4 — payroll routes on `gross_total`; an incomplete processing cost routes to LEVEL 2

**Payroll routes on `gross_total`** — the most direct statement of "what this period commits to
paying". Net is moved by deductions, so the same employment cost would land in different tiers.

**A processing run whose cost is incomplete (`cost_incomplete`) routes to LEVEL 2 and is labelled
cost-incomplete.** ★ **Never refused** — production is not blocked — and **never routed low on a
figure that is not yet true.** This is Tim's ruling and it departs from APR-0's recommendation
(which was to refuse): refusing stops the factory, and the safe direction for an unknown amount is
*upward*.

### N5 — journal entries come last, in their own cut, after N1

Only **manually entered** journals need approval. **System-generated journals are exempt** —
month-end, FX revaluation, year-end close and similar. ★ **Without that distinction, approvals
would stall month-end itself**, because manual journals are the vehicle those mechanisms use.

> ✅ **Built in APR-6 (2026-09-25), §3s.** The line is drawn by privilege: the posting core is no longer callable by people, every
> system poster runs as the owner, and a person's only door is `submit_journal_request`.
`journal_entries` also carries the largest blast radius in the system (`balance_sheet`,
`pnl_statement`, `account_ledger`, `cash_flow_statement` all read it) and the most rows.

### ★★★ N7 — **STRUCK AND REVISED:** ~~a document with no amount routes to LEVEL 1~~ — role-based tiering applies to **MONEY documents only** (Tim, 2026-09-22, APR-2)

> **The earlier rule — "a document with no amount routes to level 1" — is struck in place rather
> than edited away.** It was Tim's ruling and it was applied (WO-1b put `require_approver_for(1)`
> into `release_work_order` on exactly that reasoning). Deleting it would leave the next reader
> unable to understand why the code ever looked like that.

**What replaced it:**

> **The approvals engine gives every chain three things: the on/off switch, the `approval_log`
> trail, and the universal self-approval refusal. It gives ROLE-BASED TIERED ROUTING
> (`require_approver_for`) to MONEY documents only. A document with no money amount keeps its own
> module permission as the definition of who may approve it.**

**Why the earlier rule had to be revised — and it is a measurement, not a preference.**
`require_approver_for(N)` asks *"are you in level N's ROLE?"*. Every decision function separately
asks *"do you hold this MODULE's permission?"*. **Nothing anywhere asserted those two sets
intersect.** Measured 2026-09-22 (as `postgres`, reading the tables `user_roles`,
`role_permissions`, `auth.users`, plus `require_approver_for`'s own per-user verdict):

| chain | module gate | real holders of that gate | level-1 role `finance` | ∩ |
|---|---|---|---|---|
| purchase order | `module.purchasing.view` + `data.view_prices` | admin · chooer · phua · sandra · vince | chooer | **chooer ✓** |
| ★ **work order** | `module.processing.edit` | admin · phua · sandra · vince | chooer | ★ **EMPTY** |
| leave / claim / review | `module.hr.edit` | admin · sandra · vince | chooer | ★ **EMPTY** |

★ **So from the moment approvals were switched on (12:25:06 on 2026-09-22) nobody on live could
release a work order** — the screen would have said `APPROVAL_NOT_AUTHORISED|1|finance`, a sentence
that sounds like "your level is too low" and was in fact true of every single person. Work orders in
`draft` were 0 at the time, so nothing was stranded; the next one could never have been released.
**WO-1b shipped that with all three gates green.** The purchase-order chain works only because
`finance` happens to hold `module.purchasing.view` — alignment by luck, not by design.

**What APR-2 did with it:** `release_work_order` no longer calls `require_approver_for`. It keeps
`module.processing.edit`, gains the self-approval refusal, and its `approval_log` row now carries
`level = NULL` (writing `1` claimed an authorisation step that no longer runs — a false record).

☞ **The cost, stated plainly: work orders lost a nominal level-1 gate that nobody could pass.**
Giving them a real one means giving them their own approver role — a modelling change, not putting
that line back. Queued in `docs/forward-queue.md`.

**And the class of defect is now machine-checked, which is the durable half:**
`approval_chain_gates()` names every chain wired to `require_approver_for` and its own module gate;
`approval_gate_intersections()` counts, per chain and level, how many real people hold **both**;
`guard_approvals_switch` refuses to switch approvals **on** while any of them is zero
(`APPROVALS_CHAIN_HAS_NO_APPROVER|<function>|<level>|<role>|<permissions>`); and
`approvals_readiness()` puts the same figures on `/settings/approvals`, so the screen and the gate
read one judgement. `db/fixtures/203` pins the registry against `pg_proc` — **add a chain to
`require_approver_for` without registering it and the fixture goes red.**

### ★ The medical-claim threshold collides with the medical-claim LIMIT — both are 1000

**Measured 2026-09-22.** `hr_settings.medical_annual_limit_sgd = 1000` and
`finance_settings.approval_threshold_base = 1000` are **the same number**, and
`decide_medical_claim` refuses anything above the employee's remaining entitlement
(`CLAIM_EXCEEDS_LIMIT`). With `system_start_date = 2026-08-01` the 2026 limits pro-rate to
**333–417 per employee**.

☞ **So for 2026, level 2 is UNREACHABLE for medical claims**: every claim that can be approved at
all is below 1000, and every claim at or above 1000 is refused before routing. From 2027 the branch
is reachable at exactly one value — a claim of precisely 1000.00 against an untouched annual
entitlement.

**It is recorded rather than fixed** because under N7 medical claims are not tiered at all (no
money-tiered routing for HR documents). **If HR is ever folded into tiered routing, the medical
threshold must be a different number from the annual limit, or the tier is decoration.**

### N8 — no blanket lock on policy edits; the refusal is TARGETED (Tim, 2026-09-22) — **queued for APR-3**

The question deferred from APR-1: should the roles and threshold be frozen while approvals are on
and documents are pending?

> **Tim's ruling: NO blanket lock.** The case where you most need to edit the policy is exactly the
> case where a chain is mis-configured and documents are stuck — a lock turns a recoverable state
> into an unrecoverable one, which is the failure `guard_approvals_switch`'s own header says it
> exists to avoid (*"拒绝要给出路,不是给一堵墙"*).
>
> **The right shape is one targeted refusal:** a policy edit that would leave a chain with pending
> documents and no possible approver is refused by name
> (`APPROVALS_POLICY_WOULD_STRAND`), and everything else stays allowed. The pending count shown
> beside the form widens to cover every wired chain rather than purchase orders alone.

~~★ **NOT BUILT IN APR-2 — Tim trimmed it out to keep that cut to one session.**~~
★★ **BUILT IN APR-3 (2026-09-22).** The refusal is `APPROVALS_POLICY_WOULD_STRAND`, and Tim
sharpened the rule when it was built (Q8):

> **Judge the roles and the threshold TOGETHER.** Re-tier every pending document under the NEW
> policy and refuse if any of them lands on a level that has no approver. Name the document, the
> level, the role and the missing permission codes in the refusal.

**Why the coarse version is not enough, and it is a measurement rather than a preference.** A rule
that only asks *"does every chain have an approver at every level"* passes a **threshold** edit that
pushes a waiting document into a level nobody holds — and live carries exactly that document:
`CLM-2026-0004` sits at **1000.00 base, exactly on the threshold**, so any threshold edit moves it
between levels.

**How it reuses the intersection check rather than defining a second rule:** it calls
`approval_gate_intersections(NEW.level1, NEW.level2)` — the same function, with the **NEW** role
codes, for the same reason `APPROVALS_CHAIN_HAS_NO_APPROVER` already passes them (the guard is
`BEFORE UPDATE`, so reading the table gives OLD and it would judge the previous policy and pass).
The tiering comparison also stays single-sourced: `approval_level_at(amount, threshold)` is the
only `>=` in the repository, and `approval_level_for(amount)` now delegates to it.

☞ **A document whose base amount cannot be resolved is judged at LEVEL 2** — reusing N4's ruling
(*"the safe direction for an unknown amount is upward"*) rather than inventing a second rule.
Today no pending document is in that state.

★ **And the opposite direction is pinned too** (`db/fixtures/204` arm J2): a **harmless** policy
edit is allowed. Without that arm, an implementation that refuses every policy edit would go green
— and that is precisely the blanket lock this ruling rejects.

### The cut split

**APR-0 §6.2's APR-2 → APR-6 split stands**, with N2's sales-order release approval joining
**APR-5**.

> ★★ **The sales side of the APR-0 extension list is SUPERSEDED by Tim's role matrix (2026-09-23; recorded at the APR-5
> grilling, 2026-09-25).** APR-0 put sales orders, quotes, credit notes and sales-order amendments into APR-5, all waiting
> on N1. The matrix replaces that: **raising and amending sales orders (cco), quotes and sales invoices (finance) need NO
> approval.** What needs the CFO is (a) **N2 — shipping**: the warehouse ships only after the CFO releases the sales order
> (until APR-5b, cco ships — ROLE-1 Q10 interim); and (b) **credit notes and invoice voids** — finance raises, the CFO
> approves every one, no threshold. APR-5 was split (grilling Q14): **APR-5a** = (b), shipped 2026-09-25 (§3q);
> **APR-5b** = (a), next.


---

## 3d · FOUR EYES — one definition, two legs, every chain (APR-2, 2026-09-22)

**Tim's ruling (APR-0 Q6, sharpened by Q8 on 2026-09-22):** self-approval is refused **universally**,
reusing `SELF_APPROVAL_FORBIDDEN`, in every chain that exists and every chain added later.
**And "self" is TWO people, not one.**

| leg | who | code |
|---|---|---|
| **raiser** | whoever raised it — `created_by` / `submitted_by` | `SELF_APPROVAL_FORBIDDEN\|raiser` |
| ★ **subject** | whoever the document is **about** — the employee on the leave request, the claim, the review | `SELF_APPROVAL_FORBIDDEN\|subject` |

**One definition, one place:** `db/functions/forbid_self_approval.sql`. Not five copies of an `IF`
— a rule written five times is a rule the sixth chain will be missing, and the shape of that miss is
**nothing happening at all**.

### ★★ The subject leg is new, and it closed a live path that moved money

`approve_review` refused only `submitted_by`. So **"someone else submits, the person being reviewed
approves it"** ran end to end — and `approve_review` writes `employees.monthly_salary` and an
`employment_history` salary-change row. **A person could approve their own pay rise.** Measured
2026-09-22: all three live holders of `module.hr.edit` are on the employee register, so this was
reachable, not theoretical.

### What each chain refuses now

| chain | raiser | subject | note |
|---|---|---|---|
| leave request | ✓ `created_by` | ✓ `employee_id` | ★ both legs matter: HR raises on an employee's behalf, so the two are different people |
| medical claim | ✓ `created_by` | ✓ `employee_id` | — |
| performance review | ✓ `submitted_by` | ★ ✓ `employee_id` | the leg that closed the pay-rise path |
| work order release | ✓ `created_by` | — | a work order is about a batch of material, not a person; the second argument is `NULL`, and `NULL` never matches |
| purchase order approve / reject | ✓ `created_by` (bare code, unchanged) | — | ★ **deliberately not touched** (Tim: *leave them*). A PO has no subject person, so there was no gap — only the code shape differs, and all three mappers accept the bare form as well as the suffixed one |

**Order is fixed and stated:** raiser is judged first. When both are true the screen says `|raiser`,
because that is the earlier, narrower and more intelligible sentence ("you raised this"). It is not
left to chance.

**`NULL` never matches, on purpose.** An old row with no `created_by`, or a decider who is not on the
employee register, passes that leg. Comparing two `NULL`s to refuse would turn *"I don't know"* into
*"it is you"* — the shape this repository keeps paying for. ★ The cost, stated: for historical rows
with an empty `created_by`, the raiser leg does not apply.

**Two sentences on screen, not one with a parameter** (`lib/selfApproval.ts`) — because the NEXT STEP
differs. The raiser finds a colleague. The subject has to find someone who is neither of them, and
there may be no second holder of that permission at all, which is a real configuration problem a
generic sentence would hide.

---

## 3e · APR-3 (2026-09-22) — what the engine now covers, and the three chains that could NOT be wired

**Tim's rulings, recorded here because they were made in conversation and must not live only there.
Sequencing lives in `docs/forward-queue.md`; the reasoning lives here.**

### ★★★ Q1 — the approver's gate on a MONEY chain is `module.finance.view` + `data.view_prices`, **never** `module.finance.edit`

**This is the most important sentence in this cut, and it exists because a premise handed to the
cut as settled turned out to be false in the dangerous direction.**

The brief said: *"cfo does not hold `module.finance.edit`, so the intersection for level 2 on these
chains looks empty."* **The first half is true. The second half is false.** Measured 2026-09-22 as
`postgres`, reading the tables `user_roles` / `role_permissions` / `auth.users`:

| | real holders |
|---|---|
| `module.finance.edit` | admin · chooer · vince |
| `cfo` (the configured LEVEL 2) | ★ **admin@swm-os.test — the same account** |
| ⇒ level 2 ∩ `module.finance.edit` | **1, non-empty** |

☞ **So a chain gated on `module.finance.edit` goes GREEN today — and it is green only because of
the §0b holder collision.** `cfo`'s sole real holder is the `admin` account, which carries
`module.finance.edit` through the `admin` role, and the intersection is counted **per person, as
the union of their roles** (the mirror of the defect APR-2 §6⑤ caught in its own fixture).

★★ **And Tim has already ruled that he will break exactly that collision** — see the CFO-account
ruling below. **The day `cfo` is revoked from `admin`, a chain gated on `.edit` goes to zero
approvers**, `APPROVALS_CHAIN_HAS_NO_APPROVER` makes approvals unswitchable-back-on, and nothing
would have named this cut as the cause.

**So the gate is the purchase-order shape, copied verbatim:** `approve_purchase_order` requires
`module.purchasing.view` + `data.view_prices` and **deliberately not** `.edit`, on §0's principle
— *an approver who can raise the document he approves is not a control.* Measured: `cfo` holds
`module.finance.view` **and** `data.view_prices`, so **a cfo-only account still counts as a level-2
approver**. It changes nothing today (chooer and admin both hold `.edit` anyway) and everything on
the day it is supposed to.

> ### ☞ Write this down for whoever provisions the CFO account
> **A payment / expense / expense-claim approver needs `module.finance.view`, NOT
> `module.finance.edit`.** Grant `.edit` to a CFO account and you hand the approver the ability to
> raise the documents they approve — which is the control this chain exists to be.

⚠ **The cost, stated plainly because it is real.** `decide_expense_claim` is `SECURITY DEFINER` and
its approve branch creates an expense through `record_expense`. So a person holding
`module.finance.view` + `data.view_prices` but **not** `module.finance.edit` can, through this one
path, cause an expense to exist — on live that is `phua` and `sandra`. **That is the ruling, not an
oversight:** the person who decides and the person who does are meant to be different, and the
"doing" here is the engine acting on a decision, not that person writing to the table.

★ Pinned by `db/fixtures/204` arm E and the migration's self-proof ⑤, both of which fail if the
registry ever names `module.finance.edit` on this chain.

### ★★ Q2 — `payment` and `expense` are NOT wired, and the reason is modelling, not wiring

> ★ **Built by PAY-REQ-1 Batch A (2026-09-23) — see §3j.** The reasoning below stands: the chain was not wired onto
> `payments`; a pending state (`payment_requests`) was built in front of it. Bank transfers and WHT remittance follow in Batch B.

**Measured:** `payments.status` and `expenses.status` are each `('posted','reversed')`. **There is
no pending state.** `record_payment` (796 lines) creates the payment, the journal entry, the
allocations and the FX realisation in one transaction; `record_expense` does the same.

APR-0 §3.2's cell ③ is *"the submit path reads `approvals_enabled()` and forks into wait-for-approval
/ auto_approved stamp"*. **There is nothing to fork into.** Cells ① ② ④ really are in place — the
enum value, the `CASE` branch, the `approval_log` RLS branch — which is what made APR-0 §6.2 call
this "only ③ is missing"; **that premise is false for these two.**

> **Tim's ruling: take them out of APR-3 and give them their own cut.** The control he wants stated
> in his words: **approval BEFORE the money leaves** — a *payment request → approve → pay*
> lifecycle. ★ **CONFIRMED by Tim, 2026-09-23 (APR-ROUTE-1 brief).** Until then this was his
> phrasing relayed through the APR-3 handback; it is now his confirmed framing, and the payment
> request cut is scheduled after APR-4 (`docs/forward-queue.md`). That cut means a real pending state, journal posting deferred to approval time,
> decision functions and screens.

☞ **Why wiring them anyway would have been worse than not wiring them:** the only cheap options
were (a) gate at creation, where the raiser *is* the decider so the self-approval refusal can never
fire, or (b) approve after the money has already moved. **Both ship a control that cannot refuse
anything**, while the enum name makes the next reader believe the path is connected — the exact
failure APR-0 §1.2 named about these four subject types in the first place.

### ★ Q3 — `pricing_formula` is dropped, by N2's own test

**Measured:** `pricing_formulas` has **no status column at all** (`is_active` boolean,
`deleted_at`, and nothing else), and it is written by **direct table INSERT/UPDATE from a server
action** (`app/tools/pricing/formulas/actions.ts`) — there is no RPC. `commit_pricing_terms` is
**not** its approval: it copies a formula's terms onto a PO line or an inbound batch, and its
subject is a `pricing_term_commitments` row.

☞ **Approving it would mean first inventing a lifecycle for it — which is word for word the test
N2 used to throw "container loading" and "shipments" off the approval list.** Same ruling, same
reason, recorded beside it.

★ **If the business control is wanted, the honest target is the pricing-terms COMMITMENT** — a real
decision that fixes what will be paid — and that belongs with the purchasing batch in **APR-4**, not
here. Queued in `docs/forward-queue.md`.
⚠ **APR-4 (2026-09-23) did NOT take it up** — the APR-4 brief named five documents and not this one.
It is still queued, unscheduled, for Tim to place (§3h).

⚠ **The enum value `pricing_formula` stays in `approval_log`'s CHECK**, unwritten, exactly as
`payment` and `expense` do. **A name in the enum makes a reader believe that path is connected**
(APR-0 §1.2), so the fact that it is *not*, and *why*, is written here rather than left to be
rediscovered.

### ★ Q4 — `stocktake` is wired, and `open` is deliberately NOT "pending"

`post_stocktake` is a real decision point with a real screen (`/stocktakes/[id]/review`). It gets
the switch, the trail and the self-approval refusal — **and no tiered routing**, because a stocktake
has no amount (the table has no money column at all), so revised-N7 leaves `module.stocktakes.edit`
as the definition of who may approve. Its `approval_log` row carries `level = NULL`.

★ **`open` means "being counted", not "waiting for a decision".** A stocktake has no state between
counting and posting. So `approval_pending_documents()` does **not** list stocktakes — counting the
five open ones as in-flight would put a false sentence on the screen and, if it also fed the
disable gate, would lock approvals on.

⚠ **The consequence on live data, stated because it lands the day this ships.** All five open
stocktakes — **ST-2026-0082 · 0083 · 0084 · 0085 · 0086** — were created by **`admin@swm-os.test`**,
and in fact every stocktake on live was. **So `admin` can no longer post any of them.** The five
other real holders of `module.stocktakes.edit` can: `chooer` · `fusheng` · `phua` · `sandra` ·
`vince`. That is the four-eyes rule doing its job, not a regression.

### ★★ Q5 — the expense-claim chain had a SECOND definition of four-eyes, and its copy lied

`decide_expense_claim` refused self-approval through
`assert_segregated('EXPENSE_CLAIM_SELF_APPROVAL', [beneficiary, raiser], code)` — the same two legs
as `forbid_self_approval`, under a different name, pre-dating §3d's "one definition, one place".
**Measured live from `pg_proc.prosrc` before the change:** `decide_leave_request` called
`forbid_self_approval`; `decide_expense_claim` did not, and called `assert_segregated` instead.

★ **And one of its two legs said something false on screen.** The single shared sentence was
*"You submitted claim {0}, so you cannot be the one who approves it."* When the refusal fired
because the approver was the **beneficiary** rather than the submitter, that sentence was wrong —
and it sent the reader to fix the wrong thing. **That is precisely why §3d split the message in
two**: the raiser finds a colleague; the subject has to find someone who is neither of them, and
there may be no second holder of that permission at all.

**APR-3 replaces the call with `forbid_self_approval` and retires `EXPENSE_CLAIM_SELF_APPROVAL`
together with both its message entries, in the same commit.** `assert_segregated` itself stays — it
has three other legitimate callers (`guard_payment_sod`, `guard_finance_settings_sod`,
`sod_supplier_creator`).

### ★★ Q6 — "how many are waiting" and "what would be stranded" are TWO questions, from ONE function

APR-2's pending count did two jobs at once: it was printed on `/settings/approvals`, and it fed
`can_disable` and the disable gate. Widening it to every wired chain would have merged two
different questions — **and on today's data it would have locked approvals ON permanently**, because
live carries one `submitted` expense claim.

> **The rule, written down so the next cut can apply it without re-deriving it:**
> **Does this chain's decision function still run while approvals are OFF?**
> * **No** → its pending documents set `blocks_disable = true`. (Purchase orders:
>   `approve_purchase_order` raises `APPROVALS_NOT_ENABLED` at its top, and a `pending` PO only
>   exists because approvals were on — switch off and nobody can move it.)
> * **Yes** → `false`. (Expense claims: `submitted` means an employee filed a claim, which has
>   nothing to do with the switch; `decide_expense_claim` decides either way, and only the
>   *tiering* step is conditional.)

**Both numbers come out of `approval_pending_documents()`**, so the screen and the gate cannot read
two different judgements — the property `approvals_readiness()`'s own header has always claimed and
`db/fixtures/203` arm I pins. The screen shows a per-chain breakdown (including how many documents
cannot be valued in base currency, reported separately rather than counted as zero); `can_disable`
and `guard_approvals_switch` read only the `blocks_disable` subset.

### ★ Q7 — work-order release writes `approved`, not `auto_approved`

Closes `APR2-WORK-ORDER-AUTO-APPROVED-IS-A-HUMAN-PRESS`. Releasing a work order is a person pressing
a button — and since APR-2 that person must also clear four-eyes — so the note saying *"the system
stamped this, nobody made this decision"* was false, with the decider's id recorded beside it. Both
branches now write `approved` with `actor_user_id = auth.uid()` and `level = NULL`; only the note
differs, and it now says what is actually true (no level-based authorisation step ran).

★ **The 2026-08-16 row is NOT rewritten.** `approval_log` is append-only by design, and rewriting a
record that was true when it was made is forgery. **So the column carries two spellings, and the
boundary between them is a DATE rather than a rule** — the column comment now says so, and the
definition of `auto_approved` is narrowed to what remains true of it: *the document was born
approved; nobody pressed anything.*

### ★ Q9 — an exemption for system-created documents is an explicit PARAMETER, never a GUC

Moot in this cut (Q2 took `expense` out of scope), **recorded so the payment-request cut inherits
it rather than re-deciding it.** When `expense` is wired, three writers must be exempted —
`decide_expense_claim`, `pay_medical_claim` and `relieve_processing_accruals` (month-end, N5's
reasoning verbatim) — and the mechanism must be an explicit parameter on `record_expense` that every
call site passes. **A custom-namespace GUC is not a permission**: APR-1 §3b measured that anybody
with a SQL channel can set one. An explicit parameter makes every exemption state itself in the
source, the same reasoning as `check-anon-grant-decision`: refuse silence.

★ **And one correction to the record while it is here.** The brief listed "payments generated by
payroll" among the system paths. **Measured: it does not exist** — `pay_payroll_lines`,
`pay_payroll_cpf` and `pay_payroll_deductions` write neither `payments` nor `expenses`. The only
system writer of `payments` is `reverse_payment`.

---

## 3f · TWO STANDING RULINGS ABOUT PEOPLE, not code (Tim, 2026-09-22)

### ★★ There is no human walk after each cut. The whole chain gets walked ONCE, after APR-6.

**Tim cannot operate his colleagues' accounts**, so the per-cut hand-walk that earlier handbacks
asked for cannot happen. **Until the colleagues walk the chain end to end after APR-6, each cut's
live evidence is its refusal-only live proof** — refusals demonstrated in a rolled-back transaction,
with before/after readings proving nothing landed.

☞ **State this in every handback rather than implying a walk happened.** A refusal-only proof is
honest evidence of a narrower thing, and the narrower thing has to be named.

> ### ★★ This closes the APR-1 reconciliation gap, with a fact rather than a sentence
> `docs/handbacks/APR-1.md` §2b records that APR-1's purchase-order walk **left no trace on live**,
> and it has stood as OPEN ever since. **The explanation is now known: that walk was done in a TEST
> ENVIRONMENT.** So there is no missing live trace to find — **no human walk has yet happened on
> live at all.** The gap is closed by that fact, not by a measurement, and it is recorded here
> because it was the kind of discrepancy later cuts would otherwise keep reasoning from.

### ★★ The CFO account: the ORDER matters, and so does what follows it

Tim will get a **separate CFO-only account**, after which `cfo` is removed from
`admin@swm-os.test`. **Approvals are ON, so the order is not cosmetic:**

| # | step | why this order |
|--:|---|---|
| ① | create the account | — |
| ② | sign in once | an account that has never confirmed is **not** a holder — `real_role_holders` clause ② exists for exactly this, and §3's expired blocker is the story of getting it wrong |
| ③ | confirm `/settings/approvals` shows it as a **real level-2 holder** | the screen and the gate read one judgement, so this is the gate's own answer |
| ④ | **only then** revoke `cfo` from `admin` | revoking first would take level 2 to zero real holders while approvals are on |

> ### ★★ And the rule that follows from it, which is easy to miss
> **The `admin` account must not raise business documents.**
> **The self-approval refusal is judged per ACCOUNT, not per person.** Once Tim holds two accounts,
> a document raised from `admin` and approved from the CFO account passes four-eyes — both legs
> compare `auth.uid()`, and those are two different uuids belonging to one person. The database
> cannot see that, and §0b already rules that a machine rule here would be a second, narrower
> definition of who may approve. **The protection is that it is written here.**
>
> ★★ **Superseded in part by Tim's R3 (APR-ROUTE-1, 2026-09-23):** the self-approval refusal and
> the R2 flag must recognise the **person**, not only the account. APR-ROUTE-1 Batch A put the one
> definition in place (`account_person` → `self_leg`); **Batch B** teaches it that one employee can
> own several accounts. **Until Batch B ships, the paragraph above is still literally true**, and
> Tim will not create the CFO-only account before then — so the gap never opens on live.

> ### ★★ Finding from the APR-ROUTE-1 grilling (2026-09-23) — the rule above already bites TODAY
> **A purchase order the `admin` account raises at 1,000 SGD or more can be approved by nobody.**
> Level 2's only real holder is `admin@swm-os.test` (the `cfo` role), the raiser leg refuses him on
> his own document, and **R2's exception does not cover purchase orders** — only expense claims and
> medical claims. Measured as `postgres` (`rolbypassrls = t`) against `real_role_holders('cfo')` and
> `approval_chain_gates()`; `/settings/approvals` now shows it as a red line under
> *"Whose own documents have nobody else to decide them?"* (`approvals_readiness().own_document_gaps`,
> `approve_purchase_order` and `reject_purchase_order` at level 2, `self_exception = false`).
> ☞ **This is why the standing rule holds: the `admin` account must not raise business documents.**
> It stops being true only when level 2 has a second person.

★ **This is Tim's action, not the terminal's** — no cut creates accounts or revokes roles.

---

## 3g · APR-ROUTE-1 (2026-09-23) — higher decides lower, one flagged exception, "someone OTHER than the subject"

Tim's rulings R1–R5, closed before the cut. Batch A shipped R1, R2, R4 and R5. **R3 (one person,
several accounts) is Batch B** — Batch A only laid the single definition it will change.

### R1 — a level-2 holder may decide level-1 documents (tiered money chains only)
**One definition: `approval_level_eligible(level, l1, l2)`** = the level's own role holders, plus
the level-2 holders when the level is 1. `require_approver_for` (the runtime check) and
`approval_deciders` (→ `approval_gate_intersections`, the switch guard and the panel) both read it.
☞ **A chain added later inherits R1 by doing what it must do anyway:** call `require_approver_for`
and add its row to `approval_chain_gates()` (fixture 203 E pins "roster = catalogue").
It exists so that a level-1 holder's own documents have a decider — `chooer`'s own expense claims
under 1,000 SGD could be decided by nobody (EMP-SELF-0 F2). **It points down only**: a level-1
holder still gets `APPROVAL_NOT_AUTHORISED|2|<role>` on a level-2 document.

### R2 — the one exception to "nobody decides their own": flagged, never prevented
- **Rule:** `self_approval_exception(type, subject, user, l2)` — the document is an `expense_claim`
  or `medical_claim`, the account belongs to the person the document is about, and it is a real
  holder of the level-2 role **at decision time**. Nothing else is ever covered: payroll,
  performance reviews, salary changes, leave and every other type stay refused.
- **The raiser leg is waived only when the raiser is that same person.** A claim the level-2 holder
  raised *for someone else* is still `SELF_APPROVAL_FORBIDDEN|raiser`.
- **It never widens a module gate (Q5).** `decide_medical_claim` checks `module.hr.edit` first, so a
  CFO-only account (which holds no `hr.edit`) is refused before the exception is ever asked.
  **Who actually decides Tim's own medical claim:** any other `module.hr.edit` holder — on live
  today `sandra` (cco) or `vince` (gm). `admin@swm-os.test` also holds `hr.edit` and could decide
  it itself; that decision would be flagged.
- **Fact, not rule:** `approval_log.self_decided` is computed by `record_approval_decision` for
  `approved` / `rejected` as "was the decider the raiser or the subject (by person)". The CHECK
  `approval_log_self_decided_scope` allows `true` only on the two covered types — if any other path
  ever lets a self-decision through, the log insert fails loudly.
- **Report:** `/finance/self-approved` (registered under finance **and** HR), reading
  `self_approved_decisions()`, gated by the new code **`data.view_self_approvals`** — granted to
  `admin`, `gm` (the MD, Vince) and `auditor`. A reader without it gets `PERMISSION_DENIED`, never
  zero rows (zero rows there means "nobody has self-approved").

### R4 — "can anyone decide it" asks for someone OTHER than the subject
**One definition: `approval_deciders(subject_type, action_function, level, raiser, subject, l1, l2)`**
= eligible (R1) ∩ holds the chain's gate ∩ (not the raiser or subject **by person**, or the R2
exception applies). It counts **people**, not accounts. Three readers:

| reader | asks with | effect |
|---|---|---|
| `approval_gate_intersections` → switch guard `APPROVALS_CHAIN_HAS_NO_APPROVER` and the panel | no raiser, no subject | "does this level have anyone at all" (now counting people, R1 included) |
| `approvals_readiness().own_document_gaps` | each decider in turn as raiser + subject | **advisory**: whose own documents have no other decider (`self_exception` = only R2 lets them self-decide) |
| `APPROVALS_POLICY_WOULD_STRAND` | each pending document's real raiser and subject | refuses a policy edit that leaves a pending document with nobody but its own parties |

★ **Readiness is advisory, not blocking — Tim's ruling (Q10).** Tim will revisit making it block
**once the CFO-only account exists and level 2 has a second person.** Blocking today would flag the
live policy itself.

### ★★ Batch B (2026-09-23) — one person, several accounts; and `gm` made read-only (Tim's rulings)
- **R3, done.** Additional accounts live in `employee_accounts` (the main account stays
  `employees.user_id`); two guards stop one account from sitting in both places; `account_person()`
  falls back to the new table and `current_user_employee()` **is** `account_person(auth.uid())`.
  The raiser check (`self_leg`), the two bare purchase-order checks, `assert_segregated` and the R2
  flag all recognise the **person**. Linking and unlinking go through `link_additional_account` /
  `unlink_additional_account` (`action.manage_permissions`, on `/settings/accounts`), each writing an
  append-only `employee_account_history` row. **An account that already has `approval_log` rows as
  the decider cannot be linked (Q1)** — its past decisions about that person would become unflagged
  self-approvals that the append-only log cannot correct. Unlinking keeps past `self_decided` values.
  The readiness panel now shows **accounts and people** per level (Q3).
- **`gm` is read-only (Tim, 2026-09-23).** All 14 `module.*.edit` codes removed; 20 read codes kept;
  nothing added. Decision effects: leave · medical · performance reviews go from {admin, sandra,
  vince} to **{admin, sandra}** (Tim's own medical claim now goes to Sandra, or admin@ as a flagged
  self-approval); work-order release {admin, phua, sandra}; stocktake posting 5 people; the tiered
  chains (expense, purchase orders) are unchanged — gm holds neither approver role. No chain is left
  with only its subject; no pending document on live was raised by Vince or is about him.
  Supersedes C-1's "gm stays exactly as it is" (`docs/accounts-roles-and-permissions.md` §三 Q3).

### ~~★★ Finding (Batch B live proof): the `cfo` role cannot decide purchase orders~~ — ★★ **FALSE. Corrected by APR-4 (2026-09-23).**

> **Measured (APR-4, 2026-09-23, as `postgres`, `rolbypassrls = t`, base table `role_permissions`):
> `cfo` holds FIVE codes — `data.view_pay`, `data.view_prices`, `module.finance.view`,
> `module.logistics.view`, `module.purchasing.view`.** Their `created_at` is 2026-08-30 / 2026-09-01,
> before APR-3; no migration since has touched `cfo`'s grants. **APR-3's reading was right.**
> **The Batch B claim below was never measured:** its live-proof script contains no query of `cfo`'s
> codes — the claim is a comment, written before a scratch role with `purchasing.view` was added
> pre-emptively. **A CFO-only account CAN decide purchase orders. No decision and no fix is needed.**
> ☞ The lesson: **a handback's "Measured" must cite the query that measured it** (written into
> `docs/handbacks/APR-4.md` and the AGENTS.md family "委托书里的数来自上一份报告").
> The original text is kept, struck, because a removed claim and a never-made claim read the same:

~~`cfo` holds `module.finance.view` and `data.view_prices` only — **not `module.purchasing.view`**,
which both purchase-order actions require. Today purchase-order level 2 is decided through
`admin@swm-os.test` only because that account also holds `admin`. **A CFO-only account will decide
expense claims at level 2, but not purchase orders** — so revoking `cfo` from `admin@` would leave
purchase-order level 2 with nobody. This is a decision for Tim (grant `module.purchasing.view` to
`cfo`, or keep `cfo` on `admin@` for now); the CFO steps in `docs/handbacks/APR-ROUTE-1.md` stop at
exactly that point.~~

### R5 — `expense_claim_status` carries its own row predicate (F1)
`has_permission('module.finance.view') OR employee_id = current_user_employee()` — the same shape as
`medical_claim_status`. Before it, any signed-in user could read every expense claim through
PostgREST; only `/me`'s own page filter hid it.

---

## 3h · APR-4 (2026-09-23) — the five documents that do not wait, and the own-task exception

### ★★★ Q1 — none of the five can be wired, for the reason APR-3 dropped payments

The brief asked for goods receipts, invoices, freight documents, fixed-asset disposals and
processing-run commits, each through APR-0 §3.2's four cells. **The test is the one APR-3 used:
does the document have a state in which it waits for someone, or is creating it the act?**
**Measured, all five: creating it is the act.** Status constraints read from the live catalog
(`pg_constraint`); row counts as `postgres` (`rolbypassrls = t`) from the base tables:

| document | status on live | what creating it does | live rows | waiting |
|---|---|---|---|---|
| goods receipt · `inbound_batches` | `status` has **no CHECK and is never written** — `draft` on all 24 rows; the only constrained column is `pricing_status` | the insert moves stock at once (trigger); the payable is posted later when a price is set, and setting it *is* the posting (`reprice_inbound_batch`) | 24 (15 live) | none — no such state |
| invoice · `invoices` | `issued` / `void` | born `issued`; `create_order_invoice` posts to the GL in the same transaction; a trigger freezes every column except `issued → void` | 9 | none |
| freight document · `freight_documents` | `posted` / `reversed` | born `posted`; posts the journal and capitalises into inventory in the same transaction | 4 (all reversed) | none |
| fixed-asset disposal · `fixed_assets` | `active` / `disposed` | `dispose_fixed_asset` posts the journal and sets `disposed` in one step; no "disposal requested" state | 2 (both active; 0 ever disposed) | none |
| processing run · `processing_runs` | `committed` / `reversed` (the table says so: 没有'编辑中'状态) | commit creates the run, consumes stock and creates output batches in one transaction; cost allocation is a separate, repeatable act | 14 (10 committed) | none |

The only later transition on any of them is a **correction by one person** (void · reverse ·
soft-delete · roll back), not a decision on somebody else's document.

> **Tim's ruling (Q1): drop all five from the approval extension. `approval_log`'s subject-type list
> stays untouched** — APR-3 already found three names in it that nothing writes (§3e Q2/Q3), and five
> more would make the "a name in the enum means the path is connected" misreading worse.

**APR-0 §6.2's premise for APR-4** — *"these five have usable header amounts or clearly none, so no
new routing ruling is needed"* — is **true and beside the point**: routing was never the obstacle;
there is nothing waiting to route. Recorded in `docs/handbacks/APR-4.md` as a claim measured and
found false.

**Consequences that fall out, recorded so nobody re-derives them:**
* **No system-created path needs an exemption** — every one of the five is created only by a
  signed-in person through a server action (grep of `db/functions` for INSERTs + callers).
* **No chain joins the disable gate** (`approval_pending_documents`) — nothing is added.
* **N4 cannot be judged at commit time as it stands.** `processing_outputs.cost_incomplete` is
  per output leg and written only by `allocate_processing_costs`; cost entries can only be added
  after the run exists, and allocation goes stale later. **If a processing run is ever given a real
  decision point, N4 needs a trigger point other than commit.** N4's ruling stands; its assumption
  about *when* the figure is known does not.

### ★ Q2 — one lifecycle candidate queued; two named, not queued

* **Queued:** a **fixed-asset disposal request** (request → approve → dispose). Today one
  `module.finance.edit` holder can write off a 400k asset in one click; 0 disposals so far, so no
  history to migrate.
* **Named, not queued:** goods-receipt **pricing** (setting a price posts the payable) and
  processing-run **cost allocation** (posts the capitalisation journal). Both are one person
  finishing their own entry today.
* Tim may add any of the five later as its own lifecycle cut. `docs/forward-queue.md`.

### ★ Q3 — five findings from the survey, registered, none fixed here

`docs/known-issues.md`: `APR4-RECEIPT-PRICED-AT-CREATION-NO-PAYABLE` (★ **the next cut**, ahead of
the payment request, because it produces a wrong number — ~~live instances IN-2026-0011 / 0012~~ ★ **INB-PAY-1 corrected this: those two were priced through the pricing step on 2026-07-05, before payable posting began; no live receipt was ever priced at creation. Fixed and closed by INB-PAY-1**, `docs/handbacks/INB-PAY-1.md`) ·
`APR4-DISPOSAL-REVERSAL-LEAVES-ASSET-DISPOSED` · `APR4-RECEIPT-SUPPLIER-CHANGEABLE` ·
`APR4-RECEIPT-DEAD-STATUS-COLUMN` · `APR4-FREIGHT-REVERSAL-DATED-TODAY`.

### ★★ Q4–Q8 — the own-task exception (built)

> **Tim (2026-09-23):** Vince keeps his personal to-dos; `gm` stays read-only — do **not** give it
> `module.tasks.edit` back. Instead: a person may create and edit tasks that are their own.

* **Own task = `task_type = 'personal' AND owner_id = current_user_employee()`** — one definition,
  `task_is_own(task_type, owner_id)`, judged on the row's own columns. Not `created_by` (account
  space, client-writable, forgeable); not "participant" (would let a read-only person edit someone
  else's team task).
* **Allowed without `module.tasks.edit`** (still needs `module.tasks.view`): create a task (forced
  personal, owned by yourself) · edit its header and status · add / edit / tick / delete its steps ·
  soft-delete it. **Not allowed:** promote it to a team task · add participants · change its owner.
* **For everyone, editors included:** a new task's owner must be yourself (`TASK_OWNER_NOT_SELF`);
  an owner never changes (`TASK_OWNER_IMMUTABLE`). No feature transfers tasks, so nothing loses a path.
* **Mechanism.** `can_write_task(id)` = `can_edit_task(id)` OR the own-task exception — read by
  the write policies, the per-row guards and `task_board_rows.may_write`. Three per-row BEFORE
  guards (`trg_tasks_guard_write`, `trg_task_nodes_guard_write`, `trg_task_participants_guard_write`)
  refuse by name.
  ★ **One deviation from Q7's wording, forced by a measurement:** the statement-level
  `enforce_write_permission` could not simply be replaced — row triggers **do not fire on zero rows**
  (its own header), and fixture 198 requires a trigger of that name on every table with a write
  policy. So it stays (on `tasks` / `task_nodes` it also accepts `module.tasks.view`), and the
  UPDATE/DELETE `USING` widens to "rows you can see" so a refused row reaches the per-row guard and
  is **refused by name** instead of vanishing as a silent zero-row success. Net effect is what Q7
  asked for.
* **Behaviour change for editors, named:** an editor who is **not on** a visible team task used to
  get a silent 0-row update; now it is `TASK_NOT_EDITABLE`. Fixtures 92 and 95 asserted the old
  zero and were updated to assert the named refusal (and still assert nothing changed).
* **Screens:** one "may edit this task" source — `lib/taskAccess.ts` reads `may_write` / `may_manage`
  from the database; it never compares permission codes to decide. Controls stay visible, disabled,
  with the reason (DBLOCK-1) — two different reasons, two sentences: *needs `module.tasks.edit`
  (or it is your own personal task)* vs *not on this task* (not something an administrator grants).
* **Proof:** `db/fixtures/207`, 8 of 8 fault injections red at the arm meant to catch each.

---

## 3i · ROLE-1 Batch 1 (2026-09-23) — Tim's role matrix: who decides the HR chains now, and what `admin` no longer is

The matrix itself is `docs/role-matrix.md`; the cut is `docs/handbacks/ROLE-1.md`. This section records only what
changes **for approvals**.

### The HR chains have their own decision codes now
| chain | decided by (code) | held by | the designated approver is the subject → |
|---|---|---|---|
| leave request | `action.decide_hr_requests` | finance · cfo | the CFO decides it (Q4: the CFO may decide any) |
| medical claim | `action.decide_hr_requests` | finance · cfo | the same |
| performance review | `review_approval_code(submitted_by, employee_id)` → `action.approve_review` | cfo | **cco** decides it (`action.hr_reviews`) when the CFO is the **submitter or** the subject (Q5) |

☞ `review_approval_code` is the single definition; `approve_review` and both review pages ask it. "The CFO" is the
same predicate R2 uses: a real holder of `finance_settings.approval_level2_role_code`, **by person**.
☞ Why "submitter OR subject", not just subject: Choo Er's manager is Tim, so Tim is the reviewer who **submits** her
review, and the raiser leg would refuse him (measured at Step 0 from `employees.manager_id`).

### R2 now covers the CFO's own leave
§3g R2 said the exception "never covers … leave". **Tim reversed that for leave only** ("Tim's own leave — Tim approves it
himself, flagged self_decided"). `self_approval_exception` lists `leave_request`; `approval_log_self_decided_scope` allows
it; `self_approved_decisions()` names the subject of a leave row. Payroll, performance reviews and salary changes are still
never covered. ~~The exception never covers leave~~ — struck, not deleted, because a withdrawn rule and a never-written
rule read the same.
☞ **R2 on medical claims finally reaches the CFO account.** Before, `decide_medical_claim` required `module.hr.edit`
first and a cfo-only account never got as far as the exception (§3g Q5). The CFO now holds the decide code.

### `admin` holds no business code — and `cco` no longer holds `action.manage_permissions`
* `admin`: `action.manage_permissions`, `action.bulk_import`, `action.anonymise_employee`, **nothing else** (Q8).
  **admin@ can no longer read business data; Tim does all business reading and deciding as tim@.**
  ☞ §3f's standing rule — *"the admin account must not raise business documents"* — is now enforced by the grants
  rather than only written down. The Step 0 gap *"a PO admin@ raises at ≥ 1,000 has nobody to decide it"* cannot arise.
* `cco`: `action.manage_permissions` removed. **APR-0's "cco is admin-equivalent … ACCEPT this for now" (§0b) is
  superseded** — the approvals switch, the policy and every grant are admin-only again.
* **The approvals switch and policy were not touched.** Level 1 `finance`, level 2 `cfo`, threshold SGD 1,000, ON.

### No pending document lost its decider — measured before and after
`approval_deciders` answers the tiered chains only (it reads `approval_chain_gates()`); the HR, work-order and stocktake
chains were measured from the same parts (`real_role_grants`, `self_leg`, `self_approval_exception`) against each decision
function's real gate. As `postgres` (`rolbypassrls = t`), base tables, 2026-09-23:

| pending item | before | after |
|---|---|---|
| CLM-2026-0004 (expense claim, Choo Er's own, SGD 1,000 → level 2) | tim@ | tim@ |
| LV-2026-0001 · LV-2026-0003 (Choo Er's own leave) | admin@ · sandra@ | **tim@** |
| MC-2026-0001 (approved, unpaid — payment) | admin@ · chooer@ | chooer@ (no self-check on payment; recorded in known-issues) |
| ST-2026-0082…0086 (open stocktakes, raised by admin@) | chooer@ · fusheng@ · phua@ · sandra@ | the same |

The migration asserts this in its own transaction: any pending item with zero deciders rolls the whole cut back.

## 3j · PAY-REQ-1 Batch A (2026-09-23) — money leaves only after approval: the payment-request chain

§3e Q2 dropped payments because *"recording a payment IS the payment"* — there was no state in which a payment existed
and had not yet moved money. **PAY-REQ-1 built that state** (`payment_requests`), so the chain can now refuse something.
The cut is `docs/handbacks/PAY-REQ-1.md`; this section records only what changes **for approvals**.

### The lifecycle
`submitted → approved → paid`, plus `rejected` (reason required) and `withdrawn` (submitted **or approved** — an approved
request whose document was voided or paid elsewhere would otherwise hold that document forever).
* **Raise:** finance (`module.finance.edit`). `submit_payment_request` (an outgoing payment, same arguments as
  `record_payment`, with a *planned* date) and `submit_payment_reversal_request` (any posted payment, in **or** out — Q6;
  a reason is required).
* **Approve:** the CFO, **every one, no threshold**. `decide_payment_request` calls `require_approver_for(2)` directly and
  never calls `approval_level_for` — so there is still **one** definition of routing (`approval_level2_role_code`), and a
  level-1 holder cannot decide it (R1 lifts level-2 holders into level 1, never the reverse).
* **Pay:** finance, the raiser included (Q3). `pay_payment_request` hands the frozen arguments to the posting engine; the
  payer supplies only the actual payment date (required — no default to today) and, cross-currency, the bank's dealt rate.
  **The journal posts here and nowhere else** — submit and approve touch no ledger row (fixture 210 B1/C3 assert it).
* **Approvals OFF:** a request is **born approved** with an `auto_approved` log row — the purchase-order shape (Q8).
  Nobody pressed "approve", so the log must not say anyone did.

### How it registers in the engine
| piece | what was added |
|---|---|
| `approval_chain_gates()` | **one** row: `payment_request / decide_payment_request / level 2 / {module.finance.view, data.view_prices}` — the expense-claim gate, for the same two reasons (edit is the raiser's code; R4) |
| `approval_pending_documents()` | an arm for `status = 'submitted'`, `blocks_disable = true` (the decide function refuses while approvals are off → switching off would strand them), and a **new column `fixed_level`** |
| `guard_approvals_switch` / `APPROVALS_POLICY_WOULD_STRAND` | reads `fixed_level` before re-tiering by amount — **the trap Step 0 found**: without it a SGD 100 request re-tiers to level 1, finds no level-1 gate row, and passes unchecked |
| `approval_log` | subject type `payment_request` (CHECK, `record_approval_decision` branch with `created_by` as raiser and the payee employee as subject, RLS read branch on `module.finance.view`) |
| `self_approval_exception` | **unchanged** — `payment_request` is not in it, so R2 does not apply: a level-2 holder can never approve a request they raised (fixture 210 C1) |

### What does NOT need a request
* receipts (`direction = 'in'`);
* **Q1:** an outgoing payment to an employee **wholly** allocated to expenses created by an approved expense claim or by
  `pay_medical_claim` — same currency, allocations summing exactly to the amount. `payment_request_required()` is the one
  judgement; `record_payment` refuses on it and the payment form asks it. Cross-currency claim payments and payments with an
  unallocated remainder need a request (written narrow on purpose: a wrong answer on the narrow side costs one extra request);
* payroll, CPF, deduction, processing-fee payments — their functions never go through `record_payment`.

### No bypass parameter (Q9)
No function pays money without a person (measured at Step 0: `record_payment` had one caller, the payments form). The only
doors are `record_payment` (receipts + the Q1 exemption) and `pay_payment_request`; the engine bodies
(`record_payment_internal`, `reverse_payment_internal`, `payment_request_dry_run`) are revoked from `authenticated`.

### Before approval, the request is checked by the engine that will pay it
Submit and approve each **dry-run** the real engine inside a sub-transaction that always rolls back (`payment_request_dry_run`):
over-allocation, a voided document, a closed period, a missing rate — the refusal the CFO sees is the engine's own words,
not a second copy of its rules. Two further checks the dry run cannot see: a document may sit on **one** open request at a
time (`PAYMENT_REQUEST_TARGET_RESERVED`), and a **blacklisted or suspended** supplier is refused at submit, approve and pay
(`PAYMENT_REQUEST_SUPPLIER_BLOCKED`, Q4). Rejecting is never checked — rejecting a broken request is the way out.

### Not in this batch
~~Bank transfers and WHT remittance are **Batch B** — until it ships they still leave **without approval**.~~ **Shipped in
Batch B — see §3k.** PO retention release was **withdrawn** from the lifecycle (Q5): it moves no money and creates no payable.

### Four build decisions Batch A took on its own — **accepted by Tim (2026-09-23)**
1. An **approved** request can be withdrawn too, not only a submitted one.
2. **One open request per document** (`PAYMENT_REQUEST_TARGET_RESERVED`).
3. The **Q1 exemption is narrow**: same currency, allocations summing exactly to the amount.
4. Only **blacklisted or suspended** suppliers are refused. ☞ Superseded for the next session: once the CFO approves
   suppliers (ROLE-1 Batch 2 (c)), **no payment may be requested, approved or paid to a supplier that is not approved**
   (Tim, 2026-09-23; `docs/forward-queue.md` § ROLE-1 Batch 2a).

## 3k · PAY-REQ-1 Batch B (2026-09-23) — bank transfers and WHT remittance through the same chain

The cut is `docs/handbacks/PAY-REQ-1.md` § Batch B; this section records only what changes **for approvals**.

**Nothing in the engine changed.** Four new kinds of `payment_requests` — `bank_transfer`, `bank_transfer_reversal`,
`wht_remittance`, `wht_remittance_reversal` — ride the chain §3j built: same `decide_payment_request` (level 2, every one,
no threshold; the raiser can never approve), same `approval_pending_documents` arm (`blocks_disable = true`,
`fixed_level = 2`), same `approval_chain_gates` row, same `approval_log` subject type. Each of those reads only the columns
every request has (`status`, `created_by`, `amount_ccy`, `currency`, `amount_base`), and each was read to confirm it.

* **No payee.** Transfers move money between the company's own accounts; WHT is paid to IRAS. `counterparty_type` is NULL
  for these four kinds, so the payee checks do not apply and the approval subject (`employee_id`) is NULL — the only
  four-eyes leg is the raiser.
* **What the CFO approves is frozen.** A transfer: both accounts, both amounts (each in its own account's currency), the bank
  reference. A WHT remittance: the month and **the amount owed at the moment it was raised**, read from
  `wht_liability_by_month`. If what is owed changes before payment, approve and pay both refuse by name
  (`WHT_REMIT_AMOUNT_CHANGED`) — nobody can pay an amount nobody approved.
* **Execution takes a date and nothing else.** Transfer date, remittance date or reversal date — required, never defaulted
  (FIN-10); no exchange rate (`PAYMENT_REQUEST_TAKES_NO_RATE`).
* **One open request at a time** per transfer (reversal), per WHT month (remittance) and per remittance (reversal).
* **Correcting a WHT remittance** now goes through a `wht_remittance_reversal` request; `reverse_journal_entry` refuses a
  `wht_remittance` entry by name, as it already did for payments and transfers.
* **An unknown kind is refused by name** (`PAYMENT_REQUEST_KIND_UNKNOWN`) at dry run and at pay. Batch A's bare `ELSE` would
  have treated any new kind as a payment reversal; fixture 211 F injects one to prove the refusal.

## 3l · PAYROLL-APR-1 (2026-09-24) — payroll posting and its reversal wait for the CFO

The cut is `docs/handbacks/PAYROLL-APR-1.md`; this section records only what changes **for approvals**. Tim accepted all nine
grilling recommendations (Q1–Q9).

### The lifecycle
`submitted → approved → executed`, plus `rejected` (reason required) and `withdrawn` (submitted **or** approved) — the
PAY-REQ-1 shape, on a new table `payroll_requests` (kind `post` or `reversal`). `payroll_periods.status` stays `draft` / `posted`,
so none of its six readers changed (Q2).
* **Raise:** finance (`module.hr.edit`, the code payroll periods already use). `submit_payroll_request(period, kind, notes)`;
  a reversal needs a reason. **One open request per period.**
* **Approve:** the CFO, **every one, no threshold**. `decide_payroll_request` calls `require_approver_for(2)` directly and never
  `approval_level_for` — still **one** definition of routing. Gate `{module.hr.view, data.view_pay}` (Q8): the payroll page's
  code plus the code that shows the pay figures being approved (§5). **Not** `module.hr.edit` — that is the raiser's code.
* **Execute:** finance, the raiser included. `post_payroll_period` / `unpost_payroll_period` became doors: without an approved
  request **for that period and that kind** they refuse by name (`PAYROLL_NEEDS_APPROVED_REQUEST`, Q3). The bodies moved to
  `post_payroll_period_internal` / `unpost_payroll_period_internal`, which `authenticated` cannot execute.
  ☞ `unpost_payroll_period` is now `(uuid)`: the reason is the one on the approved request, so the executor gives none.
* **The journal posts at execute and nowhere else.** Submit and approve each dry-run the real engine inside a sub-transaction
  that always rolls back (`payroll_request_dry_run`) — a missing attendance sheet, a closed period, a paid line are refused in
  the engine's own words before the CFO ever sees the request (Q7).
* **Approvals OFF:** born `approved` with an `auto_approved` row (Q7) — nobody pressed approve.

### ★★ Q1 (A) — a payroll period is a COMPANY document: the subject leg applies to nobody
Every period contains every employee, the CFO included. Judged as a subject, the CFO could approve **no** period that
contains his own line — measured at Step 0 as tim@: `forbid_self_approval(chooer, <Tim>, 'payroll_period')` →
`SELF_APPROVAL_FORBIDDEN|subject`; R2 excludes payroll; level 2 has one real holder. Every month would stall.
> **Tim's ruling and his reasoning, recorded because it is the reason the code looks like this:** the CFO cannot change his
> own salary at this step — a monthly salary changes only through a performance review (Tim's own is approved by cco) or a
> salary-change request — and **the control that matters is that the preparer is not the approver.**
* The call is `forbid_self_approval(created_by, NULL, 'payroll_request')` — the work-order shape. The **raiser** leg is still
  judged **by person**: a request raised from `admin@` (Tim's other account) cannot be approved by `tim@`.
* The approver's own line is **said, not flagged**: the period page shows "this period includes your own pay line", and the
  `approval_log` note records it with the employee code. `self_decided` stays `false` —
  `approval_log_self_decided_scope` would refuse `true` for this type, and that is the same ruling's second lock.
* `self_approval_exception` is **untouched**: R2 never covers payroll.

### How it registers in the engine (Q8)
| piece | what was added |
|---|---|
| `approval_chain_gates()` | **one** row: `payroll_request / decide_payroll_request / level 2 / {module.hr.view, data.view_pay}` |
| `approval_pending_documents()` | an arm for `status = 'submitted'`: `blocks_disable = true` (the decide function refuses while approvals are off), `fixed_level = 2`, subject `NULL`, amount = `gross_total` in base currency (N4) |
| `approval_log` | subject type `payroll_request` (CHECK), `record_approval_decision` branch (raiser `created_by`, subject `NULL`, amount = gross in the period's currency at the period's rate), RLS read branch on `module.hr.view` |
| `operations_now` / reminders | `payroll_request_pending` (`data.view_pay`), linking to the period page |
| `self_approval_exception` | **unchanged** |

☞ **The consequence for fixtures:** every fixture that switches approvals on must give its level-2 role a holder of
`module.hr.view` + `data.view_pay`, or `APPROVALS_CHAIN_HAS_NO_APPROVER|decide_payroll_request` refuses the switch. Eleven were
updated in this cut; fixture 206 gives the codes to a second holder rather than to the reader it tests.

### While a request waits, what it approves is frozen (Q4 · Q6)
`payroll_requests.snapshot` = `payroll_period_fingerprint`: five totals, line count, a per-line digest, payment date, currency,
rate. Saving the period refuses (`PAYROLL_REQUEST_OPEN`); reopening that month's attendance refuses
(`ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL_REQUEST`); approve and execute each compare again (`PAYROLL_CHANGED_SINCE_REQUEST`).
While a **reversal** request is open, `pay_payroll_lines` / `pay_payroll_cpf` / `pay_payroll_deductions` refuse
(`PAYROLL_REVERSAL_REQUESTED`). Salaries are not in it: neither posting nor saving reads `employees.monthly_salary`.

### Three side doors closed (Q5)
Measured at Step 0 as chooer@ in a rolled-back transaction: a direct `UPDATE payroll_periods SET status` and a direct edit of a
posted period's line both went through. Now: `PAYROLL_STATUS_THROUGH_FUNCTION_ONLY` (status and the five posting/remittance
columns, and an INSERT born posted) · `PAYROLL_LINES_FROZEN` (lines and approved figures of a posted or requested period) ·
`reverse_journal_entry` refuses a period's posting entry **and its reversal** (`JE_REVERSE_USE_SOURCE_PATH`). Payroll
**payment** entries are left open on purpose: they have no proper reversal path (`docs/known-issues.md` §
PAYROLL-PAYMENT-NO-REVERSAL-PATH).

## 3m · ROLE-1 Batch 4a (2026-09-25) — two price codes, and what that does to the approval gates

The cut is `docs/handbacks/ROLE-1.md` § Batch 4a; this section records only what changes **for approvals**. Tim accepted all
thirteen grilling recommendations (Q1–Q13) and split the cut in two (Q13): **4a** (this one) moves no approval; **4b**, next,
adds the receipt-pricing chain.

* **Two price codes.** `data.view_prices` now covers the sales-and-cost side only; `data.view_purchase_prices` covers the
  purchase side (POs and their lines, retentions, payment terms, purchase formulas and committed terms, the calculator, receipt
  unit prices and price history, AP ageing). **Every role that held `data.view_prices` was given the new code in the same
  migration** (the migration's own proof asserts it), and warehouse got only the new one.
* **`approve_purchase_order`'s gate** — both rows in `approval_chain_gates()` — is now `module.purchasing.view` +
  `data.view_purchase_prices` (a PO's amounts are purchase prices). `reject_purchase_order`, the expense-claim rows and the
  payment-request row are unchanged (`data.view_prices`). The migration asserts both PO levels still have a real decider.
* **`role_can_see_amounts(role)` now requires both codes.** The two approval levels are shared by every chain, so a level role
  must see PO amounts *and* claim / payment amounts; the switch refuses `APPROVALS_LEVEL{1,2}_ROLE_CANNOT_SEE_AMOUNTS` otherwise.
  ☞ **Consequence for fixtures:** every fixture that switches approvals on must give its level roles both codes; eighteen were
  updated (the same shape as PAYROLL-APR-1's eleven).
* **`list_ledger_reconciliation()` asks per side**: AP needs `data.view_purchase_prices`, AR `data.view_prices` — each side's
  list is masked only by its own code (`inbound_batches_masked` and `prepayment_applications_masked` moved together, so AP
  never reads a masked prepayment as 0).
* **No switch, policy, chain or pending document was touched.** Before and after, as `postgres` from base tables:
  `approvals_enabled` t; every pending document unchanged and each still has a decider who is not its own party.
* **Between 4a and 4b, receipts are priced by finance in one step, without approval** — the matrix's usual [LC] interim.
  ☞ Closed by §3n (Batch 4b, 2026-09-25).

## 3n · ROLE-1 Batch 4b (2026-09-25) — a receipt price reaches the ledger only when the CFO approves it

The cut is `docs/handbacks/ROLE-1.md` § Batch 4b; this section records only what changes **for approvals**. The shape was ruled at
the Batch 4 grilling (Q2–Q8); Tim accepted all twelve Batch 4b grilling recommendations (Q1–Q12).

### The lifecycle
`submitted → approved`, plus `rejected` (reason required) and `withdrawn`, on a new table `receipt_price_requests`.
**There is no `executed`: the CFO's approval posts at once** (Q2 (A)) — the engine `reprice_inbound_batch` runs inside
`decide_receipt_price_request`, dated the approval day at that day's `tt_sell`.
* **Four raising doors**, each asking its own code first: the pricing panel (`set_inbound_unit_price`, source `manual`), repricing
  from committed terms (`reprice_from_committed_terms`, `committed_terms`) and the desk form (`create_inbound_batch` with a price,
  `desk`) — all `action.price_receipts` + `data.view_purchase_prices`; applying an assay (`apply_assay_result`, `assay`,
  `action.apply_assay`), which still applies content, supersede chain and `applied_at` in full and raises the request in the same
  transaction, **raised by the person who applied it**. One open request per receipt.
* **Frozen:** the price in its original currency (`unit_price_ccy` + `currency`) and a fingerprint (`receipt_price_fingerprint`:
  quantity, supplier, PO, PO line, unit price, metal content, committed terms, latest applied assay). The rate is **not** in it (Q4).
* **Approve:** the CFO, every one, no threshold. `require_approver_for(2)` directly. Gate `{module.inbound.view,
  data.view_purchase_prices}` (4b Q2) — the receipt page's code plus the code that shows the price being approved (§5); **not**
  `action.price_receipts`, which is the raiser's code.
* **Submit and approve each dry-run the real posting** (`receipt_price_request_dry_run`, a sub-transaction that always rolls back),
  and each refuses `RECEIPT_PRICE_BELOW_SETTLED` when quantity × the new base price is below posted allocations + prepayment
  applications (Q6 · Q12), at **that day's** rate (Q4). Approve also re-checks the fingerprint (`RECEIPT_PRICE_CHANGED_SINCE_REQUEST`).
* **Withdraw:** the raiser's person or any holder of `action.price_receipts` (Q7); unapplying an assay withdraws that assay's open
  request, and a superseding assay withdraws the waiting assay request and raises its own (Q5) — each with the reason on the row.
  A withdrawal writes no `approval_log` row: it is not a decision (the payment- and payroll-request rule).
* **Approvals OFF:** born `approved`, posted at once, `auto_approved` row.
* ★ **Nobody-but-the-raiser refuses at submit** (4b Q1): with approvals on, if `approval_deciders` at level 2 minus the raiser's
  person is empty → `RECEIPT_PRICE_NO_OTHER_DECIDER`. On live today that is **admin@**: it is tim@'s other account (one person) and
  tim@ is level 2's only real holder. Without this, an admin@ request would sit with no decider and, through `blocks_disable`, keep
  approvals from being switched off. The same gap on payroll requests is registered, not fixed (`docs/known-issues.md` §
  ROLE1B4B-PAYROLL-RAISER-NO-DECIDER).

### How it registers in the engine (Q8)
| piece | what was added |
|---|---|
| `approval_chain_gates()` | **one** row: `receipt_price_request / decide_receipt_price_request / level 2 / {module.inbound.view, data.view_purchase_prices}` |
| `approval_pending_documents()` | an arm for `status = 'submitted'`: `blocks_disable = true`, `fixed_level = 2`, subject `NULL`, amount = \|Δ payable\| in base currency |
| `approval_log` | subject type `receipt_price_request` (CHECK); `record_approval_decision` branch (raiser `created_by`, subject `NULL`, amount = \|Δ payable\| in base, currency = base, rate 1 — the `submitted` row at the submit day's rate, the `approved` row at the approval day's = what was posted); RLS read branch on `module.inbound.view` + `data.view_purchase_prices` |
| `operations_now` / reminders | `receipt_price_request_pending` (`data.view_purchase_prices`, 4b Q10), linking to the receipt page |
| `self_approval_exception` | **unchanged** |

☞ **Consequence for fixtures:** every fixture that switches approvals on must give its level-2 role a holder of `module.inbound.view`
+ `data.view_purchase_prices`, or `APPROVALS_CHAIN_HAS_NO_APPROVER|decide_receipt_price_request` refuses the switch. Eleven were
updated (the PAYROLL-APR-1 eleven); fixture 205's own-document-gap count went 5 → 6.

### While a request waits, what it approves is frozen (Q5)
Changing the receipt's supplier, PO or PO line, soft-deleting it (`guard_inbound_batch_price_request`), writing its metal content
(`guard_inbound_batch_metals_price_request`, insert / update / delete), a second request, or applying an assay under a non-assay
request → `RECEIPT_PRICE_REQUEST_OPEN`. Both guards ask `receipt_price_open` (DEFINER — an INVOKER read of the request table by a
writer without the purchase code would see zero rows and let the write through). `pricing_status` is now written through functions
only (`PRICING_STATUS_VIA_FUNCTION`); `final` is set only when the CFO approves an assay request whose assay `is_final` (4b Q3).

### The list-vs-ledger check
A waiting request moves neither side: the list reads `inbound_batches.unit_price`, the ledger reads account 2000, and a request
stores only a proposed price. Approval moves both by the same `round(qty × Δ, 2)` — the rehearsal and the live proof measured
AP list +1,360.00 and ledger +1,360.00, unexplained 0.00 on both sides. (A 0.01 rounding gap between `round(q×new)−round(q×old)` and
`round(q×Δ)` remains possible, as it was before this cut.)

## 3o · ROLE-1 Batch 3a (2026-09-25) — the counter never posts, and a request nobody else can decide is refused at submit

The cut is `docs/handbacks/ROLE-1.md` § Batch 3a; this section records only what changes **for approvals**.

### Stocktake posting: a four-eyes rule with two legs, still outside the engine
Posting moves to `action.stocktake_post` (finance · admin); counting to `action.stocktake_count` (warehouse · admin).
`post_stocktake` refuses **the opener** (`SELF_APPROVAL_FORBIDDEN|raiser`, unchanged) **and every person who counted a line**
(`STOCKTAKE_COUNTER_CANNOT_POST|<code>`), both judged per person through `self_leg` / `account_person`. Who counted is read from
the new append-only `stocktake_counts` — a recount adds a row, so the first counter is never erased. Stocktakes are still **not** in
`approval_chain_gates()` or `approval_pending_documents()` (an open stocktake is "being counted", not "waiting for someone"); the
log row stays `approved`, level NULL. The migrations' pending-decider proof now asks `action.stocktake_post` minus opener and counters.

### A request nobody but its raiser could decide is refused when it is raised
`assert_other_decider(subject, action function, level, refusal)` — with approvals on, if `approval_deciders` for that chain and level,
raiser = the caller, returns nobody, it raises the named refusal; with approvals off it does nothing. Used by `submit_payroll_request`
(`PAYROLL_NO_OTHER_DECIDER|<period>`) and the six payment-request submits (`PAYMENT_REQUEST_NO_OTHER_DECIDER`), before any code is
minted. The shape is 4b's `RECEIPT_PRICE_NO_OTHER_DECIDER` (which keeps its own copy). On live the case is admin@: it holds every code
and is the same person as tim@, the only level-2 holder. Still open for purchase orders ≥ 1,000 and expense claims
(`ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE`).

### Recorded ruling
A request's withdrawal is recorded **on the request row** (`withdrawn_at` · `withdrawn_by` · `withdraw_reason`), not in
`approval_log` — a withdrawal is not a decision. Tim accepted this for receipt price requests on 2026-09-25, consistent with payment
and payroll requests.

## 3p · ROLE-1 Batch 3b (2026-09-25) — a work order is released by someone other than the person who wrote it

The cut is `docs/handbacks/ROLE-1.md` § Batch 3b; this section records only what changes **for approvals**.

### Work-order release: its own code, the same four-eyes leg
Releasing moves from `module.processing.edit` to `action.wo_release` (finance · admin); creating moves to `action.wo_create`
(warehouse · admin). The self-release refusal was already there (APR-2: `forbid_self_approval(created_by, NULL, 'work_order')`,
per person) — only the code on the gate changed. Work orders stay out of `approval_chain_gates()` (no amount, so no tiered chain —
Tim's APR-2 Q1) and out of `approval_pending_documents()` (a draft is not "waiting"); the log row stays `approved`, level NULL.
The migrations' pending-decider proof now asks `action.wo_release` minus the creator.

### A work order nobody but its creator could release is refused when it is created
`create_work_order` raises `WO_NO_OTHER_RELEASER` unless a real holder (`real_role_grants`: unrevoked · confirmed · not banned ·
not deleted) of `action.wo_release` is a different person (`self_leg = 'none'`). It is an inline check, not `assert_other_decider`,
because that helper asks `approval_deciders` for a tiered chain and work orders are not one. Like the release-side four-eyes rule it
does **not** depend on the approvals switch. On live today: Fu Sheng creates → Choo Er or admin@ releases; admin@ creates → Choo Er.

## 3q · APR-5a (2026-09-25) — a credit note or an invoice void reaches the ledger only when the CFO approves it

The cut is `docs/handbacks/APR-5.md` § APR-5a; this section records only what changes **for approvals**. Tim accepted all
fourteen grilling recommendations (Q1–Q14) and split APR-5 in two (Q14): **5a** (this one) = credit notes, invoice voids and
every direct path; **5b** = the pre-shipment release and warehouse shipping.

### The lifecycle
`submitted → approved`, plus `rejected` (reason required) and `withdrawn`, on a new table `invoice_requests` (kind
`credit_note` or `void`). **There is no `executed`: the CFO's approval posts at once** (Q9, the receipt-price shape), **on the
date frozen at submit** — the credit note date or the reversal date the raiser gave, because it decides the GST period.
* **Raise:** finance (`module.finance.edit`). `submit_credit_note_request(invoice, note date, reason, lines)` and
  `submit_invoice_void_request(invoice, reason, reversal date)` — the same arguments as the old one-step functions.
  One open request per invoice (`INVOICE_REQUEST_OPEN`).
* **Approve:** the CFO, every one, no threshold. `decide_invoice_request` goes to level 2 directly and never through the
  amount router — still **one** definition of routing. Gate `{module.finance.view, data.view_prices}` — the payment-request
  pair (edit is the raiser's code; §5). The raiser leg is judged per person: `forbid_self_approval(created_by, NULL,
  'invoice_request')` — an invoice is nobody's "own document", so the subject leg applies to nobody.
* **Withdraw:** the raiser's person or any `module.finance.edit` holder. Written on the row, not in `approval_log`.
* **Submit dry-runs the real posting** (`invoice_request_dry_run`, PQ004): over the open balance, over a line's ceiling,
  fully settled, shipped, settled, carrying credit notes, a locked period — refused at submit in the engine's own words.
  Approval is the real posting, so the same refusals apply again there and the whole approval rolls back.
* **Approvals OFF:** born `approved`, posted at once, `auto_approved` row.
* **Nobody-but-the-raiser refuses at submit** (`assert_other_decider` → `INVOICE_REQUEST_NO_OTHER_DECIDER`). On live that is
  admin@ (tim@'s other account; tim@ is level 2's only real holder).
* **The old doors refuse everyone:** `create_credit_note` / `void_invoice` keep their signatures and raise
  `INVOICE_NEEDS_APPROVED_REQUEST` (after `PERMISSION_DENIED` for someone without the code). Because approval executes, an
  approved-but-unexecuted request never exists — so the doors have no "with a request" branch. The bodies are
  `create_credit_note_internal` / `void_invoice_internal`, EXECUTE revoked from `authenticated`.

### While a request waits (Q10)
Receipts are **never** blocked — money coming in is not refused; if a receipt makes the request impossible, approval says so
in the engine's words (`CN_EXCEEDS_OPEN`, `INVOICE_HAS_SETTLEMENTS`) and the CFO rejects or finance withdraws and raises
again. **Shipping is blocked** against an invoice with a void waiting (`INVOICE_VOID_REQUESTED`) and against a line in an
unshipped-cancel credit request (`INVOICE_CREDIT_REQUESTED`) — otherwise a shipment made while it waits would turn the void
into `INVOICE_SHIPPED_NOT_VOIDABLE` or cancel goods that already left.

### Five direct paths closed (Q11)
`invoices` / `invoice_lines` INSERT and UPDATE policies dropped; any direct write → `INVOICE_THROUGH_FUNCTION_ONLY`
(statement-level guard, replaces the two `enforce_write_permission` triggers) · `invoice_voided` may only be written by the
void propagation (`INVOICE_IMMUTABLE` otherwise, owner path included) · `reverse_journal_entry` refuses `invoice` and
`credit_note` entries and their reversals (`JE_REVERSE_USE_SOURCE_PATH`) · a void of an invoice carrying credit notes →
`INVOICE_HAS_CREDIT_NOTES`.

### How it registers in the engine (Q13)
| piece | what was added |
|---|---|
| `approval_chain_gates()` | **one** row: `invoice_request / decide_invoice_request / level 2 / {module.finance.view, data.view_prices}` |
| `approval_pending_documents()` | an arm for `status = 'submitted'`: `blocks_disable = true`, `fixed_level = 2`, subject `NULL`, amount = `amount_base` |
| `approval_log` | subject type `invoice_request` (CHECK); `record_approval_decision` branch (raiser `created_by`, subject `NULL`, base currency, rate 1); RLS read branch on `module.finance.view` |
| `operations_now` / reminders | `invoice_request_pending` (`module.finance.view`), linking to the invoice page |
| `self_approval_exception` | **unchanged** |

☞ **Consequence for fixtures:** none switched off — the gate pair is the payment-request pair every approvals-on fixture already
gives its level-2 role. Fixture 205's own-document-gap count went 6 → 7; fixture 111 has 39 arms; nine fixtures that called the
two doors now call the `*_internal` engines (their subject is the engine's arithmetic, not the door).

## 3r · APR-5b (2026-09-25) — the CFO releases an order before it ships; the warehouse ships from a price-free queue

The cut is `docs/handbacks/APR-5.md` § APR-5b; this section records only what changes **for approvals**. The shape was ruled at
the APR-5 grilling (Q2–Q8, Q13's `shipping_release`); Tim accepted all twelve 5b grilling recommendations, adding one ruling
(5b Q6: the warehouse queue shows the delivery address).

### The lifecycle
`submitted → approved`, plus `rejected` (reason required) and `withdrawn`, on `shipping_releases` with its named lines in
`shipping_release_lines` (one row per **invoice line**). **There is no `executed`: the approval IS the release** — the warehouse
then ships against it, in one or several shipments. Nothing posts at approval; revenue posts when goods ship.
* **Raise:** cco (`action.request_shipping_release`, new; also admin). `submit_shipping_release(order, invoice_line_ids)` —
  `NULL` names every invoiced line not yet covered (5b Q2). One **submitted** release per order (`SHIPPING_RELEASE_OPEN`);
  several approved ones may coexist, and a line already covered cannot be named again (`SHIPPING_RELEASE_LINE_ALREADY_RELEASED`).
* **Approve:** the CFO, every one, no threshold. `decide_shipping_release` goes to level 2 directly. Gate
  `{module.sales.view, data.view_prices}` — the order page's code plus the price code (the raise code is not the gate; §5).
  Raiser leg judged per person: `forbid_self_approval(created_by, NULL, 'shipping_release')`; an order is nobody's "own
  document". The CFO reads `shipping_release_context` (same gate): exposure, credit limit and hold, the invoice's open balance
  and whether it is paid, per-line margin — **NULL ("not costed") when any reserved batch has no cost, never 0**.
* **Withdraw:** the raiser's person or any `action.request_shipping_release` holder. Written on the row, not in `approval_log`.
* **Coverage is derived, not stored:** a line may ship ⟺ an approved release names its invoice line **and** that invoice line
  is not voided. So voiding the invoice lapses the release by itself (Q3; 5b Q4 — the only thing that lapses one); a line
  invoiced later needs its own release.
* **Approvals OFF:** born `approved`, `auto_approved` row.
* **Nobody-but-the-raiser refuses at submit** (`assert_other_decider` → `SHIPPING_RELEASE_NO_OTHER_DECIDER`). On live: admin@.

### What `ship_order` now refuses (the release is only half of it)
Gate `action.ship_goods` (warehouse, admin — new; cco no longer ships, Q7) · customer on credit hold **at shipping time** →
`SO_SHIP_CUSTOMER_ON_HOLD` (Q6; the release stays valid) · line not covered → `SO_SHIP_NOT_RELEASED` · more than invoiced −
unshipped-cancel credits − already shipped → `SO_SHIP_EXCEEDS_RELEASABLE` (Q8; the one derivation is the base view
`sales_order_line_releasable_all`). Unshipped-cancel credit requests must now carry a quantity (`CN_UNSHIPPED_CANCEL_QTY_REQUIRED`
· `…_EXCEEDS`, 5b Q1). Its return value carries no money (5b Q5).

### How it registers in the engine (Q13)
| piece | what was added |
|---|---|
| `approval_chain_gates()` | **one** row: `shipping_release / decide_shipping_release / level 2 / {module.sales.view, data.view_prices}` |
| `approval_pending_documents()` | an arm for `status = 'submitted'`: `blocks_disable = true`, `fixed_level = 2`, subject `NULL`, amount = Σ named invoice lines' `amount_base` |
| `approval_log` | subject type `shipping_release` (CHECK); `record_approval_decision` branch (raiser `created_by`, subject `NULL`, base currency, rate 1); RLS read branch on `module.sales.view` |
| `operations_now` / reminders | `shipping_release_pending` (`module.sales.view`, to the order page) · `shipping_release_ready` (`action.ship_goods`, to `/logistics/shipping`) |
| `self_approval_exception` | **unchanged** |

☞ **Consequence for fixtures:** unlike 5a, the gate pair is new — **thirteen approvals-on fixtures** (35 · 52 · 127 · 151 · 202 ·
203 · 204 · 206 · 210 · 211 · 218 · 220 · 223) now give their level-2 role `module.sales.view`, or the switch refuses with
`APPROVALS_CHAIN_HAS_NO_APPROVER|decide_shipping_release`. Fixture 205's own-document-gap count 7 → 8; fixture 111 has 41 arms;
fixtures 68–71 raise a born-approved release before each shipment; fixture 224 pins the lifecycle.

## 3s · APR-6 (2026-09-25) — a manual journal and its reversal reach the ledger only when the CFO approves them

The cut is `docs/handbacks/APR-6.md`; this section records only what changes **for approvals**. Tim accepted all twelve grilling
recommendations (Q1–Q12). N5 is now built; N1 is retired for `journal_entries` (below).

### Where "manual" ends and "system" begins (Q1) — drawn by privilege, not by the label
Measured at Step 0 (as `postgres`, live `pg_proc`): **all 30 functions that call `post_journal_entry` are SECURITY DEFINER, owned by
`postgres`**; only `post_journal_entry` itself runs as its caller, and `authenticated` could execute it with any `source_type`. So the
label proved nothing. The cut takes the posting core away from people instead: `post_journal_entry` EXECUTE revoked from
`authenticated`; both journal tables lose their INSERT policies and refuse any direct write by name (`JOURNAL_THROUGH_FUNCTION_ONLY`,
statement-level guards). The system paths — month-end, FX revaluation, depreciation, year-end close and every document's own function —
run as the owner and are untouched; the migration asserts before COMMIT that no INVOKER function calls `post_journal_entry`.
The one door a person has left is `submit_journal_request`, which always posts `'manual'` with `source_id` = the request.

### The lifecycle
`submitted → approved`, plus `rejected` (reason required) and `withdrawn`, on `journal_requests` (kind `entry` or `reversal`).
**There is no `executed`: the CFO's approval posts at once, on the date frozen at submit** (the APR-5a / 4b shape).
* **Raise:** finance (`module.finance.edit` — the matrix's "does: unchanged"). `submit_journal_request(date, memo, lines)` ·
  `submit_journal_reversal_request(entry, reversal date, reason)`. One open reversal request per entry (`JOURNAL_REQUEST_OPEN`).
* **Approve:** the CFO, every one, no threshold. `decide_journal_request` goes to level 2 directly and never through the amount
  router. Gate `{module.finance.view, data.view_prices}` — the payment-request pair (edit is the raiser's code; §5). Raiser leg per
  person: `forbid_self_approval(created_by, NULL, 'journal_request')`; a journal is nobody's "own document".
* **Withdraw:** the raiser's person or any `module.finance.edit` holder. Written on the row, not in `approval_log`.
* **Submit dry-runs the real posting** (`journal_request_dry_run`, PQ005, with the deferred balance check flushed): unbalanced,
  inactive account, currency / rate, locked period, closed year, beyond the current month, 1100 / 2000 — refused in the engine's
  words before the CFO sees it. Approval is the real posting, so the same refusals apply again and the whole approval rolls back.
* **Approvals OFF:** born `approved`, posted at once, `auto_approved` row.
* **Nobody-but-the-raiser refuses at submit** (`assert_other_decider` → `JOURNAL_REQUEST_NO_OTHER_DECIDER`). On live: admin@.

### ★ The period lock always wins (Q4)
Nothing refuses a lock because a request waits — approvals must never stall month-end (N5). A request whose frozen date falls into a
period locked after it was raised is refused **at approval** in the engine's own words (`PERIOD_LOCKED` / `YEAR_CLOSED`) and stays
waiting; the CFO rejects it, or finance withdraws it and raises it again with an open date. The CFO panel says so before anyone presses.

### ★★ Who "posted a manual journal" is the RAISER (Q5)
Approval posts the entry, so `journal_entries.created_by` is the approving CFO. `sod_manual_posters_in` (the `SOD_POST_AND_CLOSE`
question) now reads `COALESCE(journal_requests.created_by, journal_entries.created_by)` through `result_journal_entry_id` — otherwise
the CFO (and admin@, the same person) could no longer lock the month while the raiser could, and with finance as raiser nobody could.
Its scope also covers a system entry reversed through a request (the reversal copies e.g. `'sale'`): that reversal was a person's choice.

### Reversal (Q6) — one judgement, three readers
`journal_entry_reversal_route(entry)` → `source_path` (payment, transfer, wht_remittance, purchase, invoice, credit_note, expense,
freight, allocation, processing_cost, year_close, payroll postings) · `request` (manual, and every system entry with no path of its
own: sale, stocktake, writeoff, prepayment, revaluation, depreciation, asset_disposal, shipment, payroll payment entries) · `reversed`.
`reverse_journal_entry` keeps its signature and **reverses nothing**: `JE_REVERSE_USE_SOURCE_PATH` or `JOURNAL_NEEDS_APPROVED_REQUEST`.
The document functions' own reversals (`reverse_expense`, `reverse_freight_document`, the processing rollback, the payment / payroll /
invoice request engines) still call `reverse_journal_entry_internal` and are unchanged. The journal page greys the button by the same
function (it used to know three types; the database refused more).

### Control accounts (Q7)
A request whose posted lines touch 1100 or 2000 → `JE_MANUAL_CONTROL_ACCOUNT` (a reversal of a `revaluation` entry excepted — the
list-vs-ledger check names revaluation by `source_type`). Bank accounts are allowed with approval and flagged (`credits_bank`).
Inventory accounts are registered, not refused (`docs/known-issues.md` § APR6-INVENTORY-ACCOUNTS-MANUAL).

### How it registers in the engine (Q8)
| piece | what was added |
|---|---|
| `approval_chain_gates()` | **one** row: `journal_request / decide_journal_request / level 2 / {module.finance.view, data.view_prices}` |
| `approval_pending_documents()` | an arm for `status = 'submitted'`: `blocks_disable = true`, `fixed_level = 2`, subject `NULL`, amount = Σ debits (base) |
| `approval_log` | subject type `journal_request` (CHECK); `record_approval_decision` branch (raiser `created_by`, subject `NULL`, base currency, rate 1); RLS read branch on `module.finance.view` |
| `operations_now` / reminders | `journal_request_pending` (`module.finance.view`), linking to `/finance/journal#jr-<id>` |
| `self_approval_exception` | **unchanged** |

☞ **Consequence for fixtures:** none switched off — the gate pair is the payment-request pair every approvals-on fixture already gives
its level-2 role. Fixture 205's own-document-gap count 8 → 9; fixture 111 has 42 arms; fixture 122's back-door arms now expect the
door itself to refuse (`JOURNAL_THROUGH_FUNCTION_ONLY`, with a new JE-APPEND arm in an open period); five fixtures that reversed through
the journal door now call `reverse_journal_entry_internal` (their subject is the reversal arithmetic); fixture 225 pins the lifecycle.

## 3t · APR-7 (2026-09-26) — a write-off, a processing rollback and a COD void happen only when the CFO approves them

Tim's matrix (`docs/role-matrix.md`: batch deletion · processing rollback · voiding a COD — warehouse requests, CFO approves, no
threshold) replaces ROLE-1 Q10's interim, in which warehouse (and admin) did each of them in one step. The grilling (Q1–Q9) was
accepted in full; `docs/handbacks/APR-7.md` has the cells.

### What needs a request, and what does not (Q1)

| subject | needs the CFO | one step, as before |
|---|---|---|
| inbound batch | stock left (priced **or** unpriced — stock moves either way), **or** an issued certificate of destruction the delete would void | empty, no issued certificate |
| output batch | stock left | empty |
| processing run | always | — |
| certificate of destruction | always (only an issued one can be voided) | — |

One judgement, `batch_write_off_needs_request`, read by the one-step doors, the submit and the two tables' buttons.

### The lifecycle

`warehouse_requests` — one table, four kinds (`write_off_inbound` · `write_off_output` · `rollback` · `cod_void`), exactly one subject
column per kind (`kind_shape`, plus a `num_nonnulls = 1` twin the relation graph reads). `submitted → approved` (takes effect at once) ·
`rejected` (reason required) · `withdrawn` (the raiser's person, or anyone holding that kind's code). Submit dry-runs the very path
approval takes (`warehouse_request_dry_run`), so a still-owed payable, a live reservation, a moved output or a certificate that is no
longer issued is refused at submit in the engine's own words. With approvals off a request is born approved and takes effect
(`auto_approved`).

* **Dated and valued on the approval day** (Q4): the write-off trigger already uses `deleted_at` and `CURRENT_DATE`. `amount_base` is
  the dry-run's Σ debits at submit and the posted Σ debits after approval; an unpriced write-off and a certificate void are a true 0.
* **`deleted_by` / `voided_by` = the raiser** (Q6). The CFO is on the request (`decided_by`) and in `approval_log`; entries the approval
  posts carry the CFO as `created_by`. A certificate voided **automatically** by an approved write-off or rollback carries the approving
  CFO (registered as part of APR7-AUTO-VOID-REASON-READS-AS-REVERSAL).
* **Locked period** (Q5): a run dated inside a locked period may still be rolled back — value is reversed today, quantity on the run's
  own date (FIN-32) — and the snapshot says so, together with the certificate numbers the rollback will void.

### What is frozen while a request waits (Q3)

* Every stock movement touching the subject batch — or any output of a run whose rollback waits — is refused
  `WAREHOUSE_REQUEST_FREEZES_BATCH` (`guard_warehouse_request_freeze` on `inventory_movements`; one table, so no side door). A new price
  request on a frozen receipt is refused by the same guard on `receipt_price_requests`. Only the execution of that very request passes
  (`evoltrya.warehouse_request_ctx`).
* A batch, its certificate and a run that consumes it carry at most **one** waiting request (`warehouse_request_touches` /
  `warehouse_request_conflict` → `WAREHOUSE_REQUEST_OPEN`). Without it, a waiting void could be orphaned by an approved write-off or
  rollback that voids the same certificate automatically, and would then block switching approvals off forever.

### Doors (Q7)

`rollback_processing_run` and `void_cod` do nothing any more — `WAREHOUSE_NEEDS_APPROVED_REQUEST|kind|code` (after their code check).
`soft_delete_inbound_batch` / `soft_delete_output_batch` keep only the empty-batch case. The bodies moved to `*_internal`, and
`void_cod_internal` gained `p_voided_by`; every internal is revoked from `authenticated`. Already closed and re-asserted: direct
`deleted_at` (`guard_soft_delete_provenance`), direct run status (`guard_processing_direct_write`), certificate status (no write
policy). The direct-movement probe: a `writeoff` movement inserted directly, or `remaining_qty` updated directly, each fails the deferred
ledger invariant on its own — one PostgREST call is one table. **Named, not closed:** a stocktake counted to zero is a second way stock
leaves, through the stocktake chain (APR7-STOCKTAKE-IS-A-SECOND-WRITE-OFF-PATH).

### How it registers in the engine (Q8)

| where | what |
|---|---|
| `approval_chain_gates()` | **one** row: `warehouse_request / decide_warehouse_request / level 2 / {module.finance.view, data.view_prices}` — the same pair for all four kinds |
| `approval_pending_documents()` | an arm for `status = 'submitted'`: `blocks_disable = true`, `fixed_level = 2`, subject `NULL`, amount = the latest estimate |
| `approval_log` | subject type `warehouse_request` (CHECK); `record_approval_decision` branch (raiser `created_by`, base currency, rate 1); RLS read branch on `module.finance.view` |
| `assert_other_decider` | `WAREHOUSE_REQUEST_NO_OTHER_DECIDER` at submit (live: admin@ is refused — the same person as tim@) |
| `operations_now` / reminders | `warehouse_request_pending` (`module.finance.view`), linking to `/inventory#wr-<id>` |
| readers | the screen reads `warehouse_requests_visible()` (`module.inventory.view`; amount `NULL` without `data.view_prices`); the CFO reads the submit-time `snapshot`, never the certificate table |

No new permission code. **Q9:** the migration's "every pending document has a decider who is not its own party" proof now asks
`approval_deciders` document by document for every request chain (payment, payroll, receipt price, invoice, shipping release, journal,
warehouse), not only "does this chain have anyone".

☞ **Consequence for fixtures:** fixture 205's own-document-gap count 9 → 10; fixture 111 has 43 arms; fixture 103 needed the
`num_nonnulls` twin; fixtures whose subject is the write-off / rollback / void arithmetic call the `*_internal` bodies (or, where
approvals are off, the new submit doors, which take effect at once); fixtures 85 · 195 · 222 keep their door arms and now expect
`WAREHOUSE_NEEDS_APPROVED_REQUEST` or the request path; fixture 226 pins the lifecycle (A–N, including the fault injection).

## 3u · APR-8 (2026-09-26) — contract terms and pricing formulas take effect only when the CFO approves them

Tim's matrix (`docs/role-matrix.md`: contract terms · pricing formulas — cco raises, the CFO approves, every one, no threshold) replaces
ROLE-1 Batch 2b's interim, in which cco (and admin) made a contract active or changed a formula in one step. The grilling (Q1–Q11) was
accepted in full; `docs/handbacks/APR-8.md` has the cells.

### What "takes effect" means (Q1 · Q2)

Nothing already priced or committed can change retroactively — documents copy terms when they commit (a PO line or receipt gets an
immutable `pricing_term_commitments` row; a linked PO / SO gets a `contract_document_terms` snapshot; a sale copies its price into
`price_provenance`). So "takes effect" means **what the next read of the live row returns**:

| subject | live readers | what needs the CFO | one step, as before |
|---|---|---|---|
| pricing formula | `calculate_metal_price` (calculator, new-PO estimate) · `price_output_sale` · `commit_pricing_terms` (PO creation, assay application) — all through `pricing_terms_of_formula`, which refuses an inactive formula | a new formula (born **inactive**) · any change to an active one (the full proposed terms, replaced **in place** on approval; `pricing_formula_history` logs it) · putting an inactive one back in use | stop using (`deactivate_pricing_formula`) · delete (`delete_pricing_formula`) |
| contract | `link_document_to_contract`, which accepts only `active` | every route **into** `active` (`draft → active`, `suspended → active`) | suspend · expire · terminate |

While a formula change waits, the old terms stay in effect. To change an active contract: suspend (one step), edit, request activation
again — the CFO sees the terms now on the contract next to those at the last approval. No status column was added to formulas.

### The lifecycle

`terms_requests` — one table, four kinds (`formula_create` · `formula_change` · `formula_reactivate` · `contract_activate`), exactly one
subject column (`kind_shape` + the `num_nonnulls = 1` twin); formula kinds carry `proposed` (normalised by `formula_terms_normalize`).
`submitted → approved` (takes effect at once) · `rejected` (reason required) · `withdrawn` (the raiser's person, or anyone holding the
kind's code: `module.pricing.edit` / `action.contract_terms`). Submit dry-runs the approval path (`terms_request_dry_run`, SQLSTATE
PQ006), so a term that breaks a CHECK is refused at submit in the table's own words. With approvals off a request is born approved and
takes effect (`auto_approved`). A change identical to the terms in use is refused `TERMS_REQUEST_NO_CHANGE`.

### What is frozen while a request waits (Q5)

* One waiting request per subject (`TERMS_REQUEST_OPEN`; partial unique indexes are the second line). A formula with a waiting request
  cannot be stopped or deleted (withdraw first).
* A contract with a waiting request: header `TERMS_REQUEST_FREEZES_CONTRACT`, the seven term tables `CONTRACT_TERMS_FROZEN`. An active
  contract: header `CONTRACT_ACTIVE_IS_FROZEN` (only a status change to suspended / expired / terminated passes), terms
  `CONTRACT_TERMS_FROZEN|code|active`. One judgement, `contract_terms_lock_reason`, for both guards.
* **Fingerprint** (receipt-price / payroll pattern): `terms_request_fingerprint` is stored at submit and recomputed inside the execution —
  a subject changed since (only possible on the owner path) is refused `TERMS_CHANGED_SINCE_REQUEST`, and the request stays waiting.

### Doors (Q6)

The six write policies on `pricing_formulas` / `pricing_formula_metals` are gone; a statement-level guard refuses any direct write by
name, zero rows included (`PRICING_FORMULA_THROUGH_REQUEST_ONLY`; `enforce_write_permission` still fires first, so a non-holder reads the
missing code). `contracts` keeps its insert / update policies — a direct insert may only be a draft (`CONTRACT_ACTIVATES_THROUGH_REQUEST`),
a direct update may never make it active. Owner paths (the DEFINER functions, migrations, fixture set-up) pass all three guards.
`link_document_to_contract` is unchanged (Batch 2b Q1). No new permission code, so the "new codes also go to admin" ruling granted nothing.

### How it registers in the engine (Q9)

| where | what |
|---|---|
| `approval_chain_gates()` | **one** row: `terms_request / decide_terms_request / level 2 / {module.pricing.view, data.view_prices, data.view_purchase_prices, module.suppliers.view, module.customers.view}` — all four kinds; cfo holds all five (measured) |
| `approval_pending_documents()` | an arm for `status = 'submitted'`: `blocks_disable = true`, `fixed_level = 2`, subject `NULL`, amount `NULL` (terms, not money) |
| `approval_log` | subject type `terms_request` (CHECK; the never-written `pricing_formula` value is left alone); `record_approval_decision` branch without amounts (the `work_order` shape); RLS read branch on `module.pricing.view` |
| `assert_other_decider` | `TERMS_REQUEST_NO_OTHER_DECIDER` at submit (live: admin@ is refused — the same person as tim@) |
| `operations_now` / reminders | `terms_request_pending` (`module.pricing.view`), `doc_kind` formula → `/tools/pricing/formulas#tr-<id>`, contract → `/contracts#tr-<id>` |
| readers | `terms_requests_visible()`: formula requests to `module.pricing.view` with `snapshot` / `proposed` masked by `pricing_formula_terms_visible(direction)`; contract requests by the contract's side, as `contracts` reads |

☞ **Consequence for fixtures:** every fixture that switches approvals on grants its level-2 role the three extra gate codes (16 files; in
127 · 151 · 35 · 203 the existing grant array was extended, because the new statement would otherwise sit inside a savepoint the fixture
expects to fail); fixture 205's own-document-gap count 10 → 11; fixture 111 has 44 arms; fixture 217 creates its formula through the new
door and its existing contract as a draft; fixture 227 pins the lifecycle (A–K, including the fault injection).

## 4 · A REVOKED grant used to count as a holder — fixed here

**Found while building CHAIN-BUILD-1; folded into the same predicate.**

`user_roles` records `revoked_at`, and `user_directory` filters on it — but the approvals holder
predicate **did not**, in any of its three copies. Live carried **5 revoked grants out of 15**, which
is the whole reason `admin` read **6** holders when only **1** was real.

The consequence was not cosmetic: **a role whose grants had all been deliberately taken away still
satisfied the zero-holder guard**, so approvals could be enabled on the strength of authority that
had been withdrawn — and the person who withdrew it would reasonably believe they had closed that
door. The authorisation path had the same hole: a revoked grant could still approve a document.

Both paths now read `real_role_holders()`, so there is one definition and it filters revocation.
Pinned by `db/fixtures/151`, arms A and F, with fault injection.

---

## 5 · An approver must be able to SEE THE AMOUNT

**Ruled 2026-08-30 (R4). Two guards, deliberately.**

Purchase-order amounts are masked behind `data.view_prices`. Approval **routes by amount**. So an
approver without price visibility approves a figure rendered to them as 「受限」.

* **At enable time** the guard asks *"can this ROLE see amounts?"* and refuses by name if not — the
  state is fully knowable and the consequence is total.
* **At approve time** `approve_purchase_order` asks *"can this USER see amounts?"* — permissions are
  the union of a user's roles, so this is a different question about a different subject.

**This is not the same rule twice**; it is the two-guard shape AGENTS.md already requires for values
that decide a period. **Unmasking the amount on the approval path was considered and rejected**: it
would open a second route to price data that bypasses the `_masked` convention, and that convention
carries its own gate verdicts (`colgrant`, `colreader`).

Roles that would fail the enable-time check today: `employee`, `hr`, `operations`, `warehouse`.
**This is not what blocks the chain today** — §3 is.

---

## 6 · What CHAIN-BUILD-1 did NOT do — and what CHAIN-CONFIG-1 then did

**CHAIN-BUILD-1 configured nothing.** It made the chain *configurable by role at both levels* and
left every value NULL; choosing the roles was a separate, business decision.

**CHAIN-CONFIG-1 (2026-08-30) made that choice** — see §0 for the configured chain. It changed **no
schema and no code**: it created a role, granted two permission codes, set three settings values and
granted a role to one account. **Approvals remain OFF**, and enabling them still refuses, for the
reason in §3.
