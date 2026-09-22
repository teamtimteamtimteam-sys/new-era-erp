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
