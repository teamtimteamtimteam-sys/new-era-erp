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
measured 2026-08-30). `approval_level_for(p_amount_base)` compares `p_amount_base >= v_threshold`,
so **"at or above" is exact**: 999.99 → level 1, **1000.00 → level 2**, 1000.01 → level 2. Pinned by
`db/fixtures/151` arm T, with a fault injection that flips `>=` to `>` and asserts the
exactly-at-threshold case degrades — because that single value is the only one of the three that can
tell the two implementations apart.

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

★ **NOT BUILT IN APR-2 — Tim trimmed it out to keep that cut to one session.** It is queued for
**APR-3** in `docs/forward-queue.md`. Until then the screen keeps saying what it says today: editing
the policy while approvals are in force re-routes what is still pending, nothing locks it, and
`finance_settings_history` records the change.

### The cut split

**APR-0 §6.2's APR-2 → APR-6 split stands**, with N2's sales-order release approval joining
**APR-5**.

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
