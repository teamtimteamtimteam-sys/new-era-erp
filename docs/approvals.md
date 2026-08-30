# Approvals — the decisions, and the states you will meet

**This file exists so that three things are met as DECISIONS rather than as unfinished work.**
Each of them looks, to a fresh reader, like something to go and fix. None of them is.

The precedent for writing them down at all is the anonymisation function: it **permanently refuses
by decision** (employee data is retained by ruling), and without its note the next reader meets a
refusal and starts "fixing" it. The three below have exactly that shape.

Mechanism and history: `docs/approvals-scoping.md` (note its §3 and decision rows 1–2 are
**superseded** as of 2026-08-30 — superseded in place, not deleted).

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

## 3 · TODAY, APPROVALS CANNOT BE SWITCHED ON — and that is the control working

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

## 6 · What this cut did NOT do

It **configured nothing**. Approvals are **OFF**, and the chain is **UNCONFIGURED**: no level-1 role,
no level-2 role, no threshold. CHAIN-BUILD-1 made the chain *configurable by role at both levels*;
choosing the roles is a separate, business decision.
