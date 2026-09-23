# EMP-SELF-0 — can employees submit their own leave, medical claims and expense claims?

Survey only. Read-only. Nothing changed in `app/`, `lib/`, `db/`, `scripts/`, `messages/`.
Survey date: 2026-09-23. Tree measured: `0c92cac5b19f985d49bddae75f6ecbb7c04e4cb8`
(opening gate: tree clean, and `HEAD` = `origin/main` = `ls-remote` = that SHA).

## §0 · The answer in one paragraph

**Yes, all three already exist, end to end, and all three pass on live today.**
`/me` has a *Request leave* button, a *Submit a claim* button (medical) and a
*Submit* button (expense claims). Each calls a `SECURITY DEFINER` function whose
first line already accepts `p_employee_id = current_user_employee()` without any
module permission, and which refuses the same call for someone else. I proved both
directions on live as a user with no HR or finance permission (§1.4).

**So what Tim hit is almost certainly not missing code. It is findability**:
- the only way into `/me` is the avatar menu row labelled **"My profile" / 「我的档案」**;
- nothing on the home page or in any module menu says "leave" to an employee;
- `/hr/leave` is the only page with *leave* in its name, and an employee can't open it.

Two real gaps sit behind that, plus two findings that are not about self-service:

| # | finding | kind |
|--:|---|---|
| G1 | Findability: the self-service forms sit under "My profile" | UX, no DB |
| G2 | The employee **cannot see who decided**, and for leave and medical cannot see the decision note either | read path; needs DB |
| G3 | An employee can cancel their own pending leave **in the database**, but `/me` has no button for it. Medical claims have **no withdraw at all** (no function) | UI plus one function |
| F1 | ★ `expense_claim_status` returns **every** expense claim to **any** signed-in user | security; separate from self-service |
| F2 | ★ Expense tiers each have **exactly one** decider on live, so that person's own claim in their tier can **never be decided** | config; affects the end-to-end walk |

### §0.1 · How grilling was applied

`mattpocock-skills:grilling` was invoked by name, on this survey's scope. I applied
it the way BLOCKERS-0 did: its rule is **"Finding facts is your job, never the
user's."** The brief's premise ("employees have no way to submit a leave request")
was a fact to measure, not a question for Tim. **The measurement reversed it**
(see §0). So the first round was spent on measurement. Every decision it surfaced is
in §4, with evidence and a recommended answer, and **none is answered here**.
The grilling session is not closed.

### §0.2 · Claims from the brief I measured and found false (or narrower)

1. "Employees have no way to submit a leave request themselves": **false.** `/me` → *Request leave*
   (`app/me/MyLeavePanel.tsx:103-108`, form at `:131-135` with `fixedEmployeeId`).
   On live the database accepts it (§1.4).
2. "The only leave page is the HR page": **false as stated, true as experienced.**
   `/me` is a leave page, but it is titled "My profile" and reached only from the avatar menu.
3. "The same gap is likely for medical and expense claims": **false for submission** (both exist on
   `/me` and pass on live). **True for the read-back**: G2 and G3 apply to them too.

Claims from the brief I measured and found **true**: approvals ON on live (`approvals_enabled() = t`);
deciders are `module.hr.edit` for leave and medical, and the tiered finance approvers for expense claims
(§1.3); `SELF_APPROVAL_FORBIDDEN` blocks raiser = subject (§2.2).

---

## §1 · What exists today

### §1.1 · Identity for every live reading in this document

All live reads ran over direct psql, **each inside `BEGIN READ ONLY … ROLLBACK`**
(`transaction_read_only = on`, measured). The pooler ignores `PGOPTIONS`; I tried it
first and `transaction_read_only` came back `off`, so every query was wrapped instead.

- **Connection identity: `postgres`, `rolbypassrls = true`.** Reads of **base tables** under it
  (`relkind = 'r'`: `auth.users`, `employees`, `roles`, `user_roles`, `role_permissions`,
  `leave_requests`, `medical_claims`, `expense_claims`) are **true row counts**.
- **Simulated identity** where stated: `SET LOCAL ROLE authenticated` plus
  `request.jwt.claims.sub = <that user's id>`, confirmed each time by `auth.uid() = <id>` being true.
  Under it, a count is **what that person's RLS and view predicates let through**, not a true count.
- `medical_claim_status`, `expense_claim_status` and `my_profile` are **views** (`relkind = 'v'`), all
  `security_invoker = off` (owner rights). Their own `WHERE` decides what a reader gets.

### §1.2 · Live accounts, roles and employee links

Read as `postgres`, bypassing RLS, from base tables:

| account | roles | employee | status | `module.hr.edit` | `module.finance.view` | `data.view_prices` |
|---|---|---|---|:-:|:-:|:-:|
| `admin@swm-os.test` | admin, cfo | EMP-2026-0002 | active | ✓ | ✓ | ✓ |
| `chooer@evoltrya.test` | finance | EMP-2026-0001 | active | – | ✓ | ✓ |
| `fusheng@evoltrya.test` | warehouse | EMP-2026-0006 | active | – | – | – |
| `phua@evolytra.test` | cto | EMP-2026-0005 | active | – | ✓ | ✓ |
| `sandra@evoltrya.test` | cco | EMP-2026-0004 | active | ✓ | ✓ | ✓ |
| `vince@evoltrya.test` | gm | EMP-2026-0003 | active | ✓ | ✓ | ✓ |

- **6 of 6 accounts are linked to an employee record** (`employees.user_id`). 7 employees exist; one has no account.
  So on live nobody hits `/me`'s "not linked, see your administrator" branch.
- Role **`employee` exists with 0 permissions and 0 holders.** No account on live is "employee only".
  **`fusheng` (warehouse, no HR or finance permission) is the closest thing to a plain employee.**
- There is **no permission for the self section**: `permissions` has no code matching `self|my|.me`.
  `/me` checks no module permission by design (`app/me/page.tsx:5-7`); it runs on row-level
  "own rows" policies and `current_user_employee()`.
- Roles `hr` (hr.edit and hr.view) and `auditor` exist but **have no holders**.

### §1.3 · Per document: pages, gates, functions

#### Leave request

| surface | where | gate |
|---|---|---|
| create (HR, on behalf of anyone) | `/hr/leave/new` | `requireModule(MOD.hr)` → `module.hr.view` (`app/hr/leave/new/page.tsx:15`) |
| list (everyone's) | `/hr/leave` | same (`page.tsx:41`) |
| decide | `/hr/leave/[id]` → `DecideControls` | page `module.hr.view`; DB `decide_leave_request` → `require_permission('module.hr.edit')` |
| **create (self)** | **`/me` → *Request leave*** | **none at page or action level**; DB own-arm |
| **list (own)** | **`/me` leave table** | RLS `leave_requests select own rows` (`employee_id = current_user_employee()`) |
| cancel (self) | **no UI**; DB `cancel_leave_request` has the own-arm | — |

- Create function: `submit_leave_request`. First line (`db/functions/submit_leave_request.sql`, live identical):
  `IF NOT (has_permission('module.hr.edit') OR p_employee_id = current_user_employee()) THEN RAISE 'PERMISSION_DENIED|module.hr.edit'`.
  The HR-only extra (`p_is_exception`) is separately refused without `module.hr.edit`.
- Server action `submitLeave` (`app/hr/leave/actions.ts`) has no page gate. It passes the id through, and the DB decides.
- The form is shared: `LeaveForm` with `fixedEmployeeId` hides the employee picker and forces `allowException=false`.
- **Deciders on live (`module.hr.edit`): `admin`, `sandra`, `vince`.**

#### Medical claim

| surface | where | gate |
|---|---|---|
| create (HR) | `/hr/claims/new` | `module.hr.view` (page); DB own-arm or `module.hr.edit` |
| list / decide / pay | `/hr/claims`, `/hr/claims/[id]` | page `module.hr.view`; decide = DB `module.hr.edit`; pay = DB `module.finance.edit` (`pay_medical_claim`) |
| **create (self)** | **`/me` → *Submit a claim*** | none at page/action; DB own-arm (`submit_medical_claim`, same shape as leave) |
| **list (own) + balance** | **`/me`** | view `medical_claim_status` has `WHERE … AND (has_permission('module.hr.view') OR mc.employee_id = current_user_employee())`; `medical_claim_balance` own-arm |
| withdraw (self) | **nothing: no function, no UI** | — |

- **Deciders on live: `admin`, `sandra`, `vince`** (`module.hr.edit`). **Payers: `module.finance.edit`** holders.

#### Expense claim (CLAIM-1)

| surface | where | gate |
|---|---|---|
| **create (self)** | **`/me` → *Submit*** (`MyExpenseClaimsPanel`) | none at page/action; DB `submit_expense_claim`: `has_permission('module.finance.view') OR p_employee_id = current_user_employee()` |
| **list (own)** | **`/me`** | page filters `.eq('employee_id', employeeId)`; **the view itself does not** (F1) |
| **withdraw (self)** | **`/me` withdraw button** | DB `withdraw_expense_claim` own-arm |
| list / decide (finance) | `/finance/claims` | page `requireModule(MOD.finance)`; DB `decide_expense_claim`: `module.finance.view` and `data.view_prices`, then `forbid_self_approval`, then tier |

- **Tier deciders on live (approvals ON, threshold 1000 SGD, `>=` goes to L2):**
  L1 = real holders of role **`finance`** = **`chooer` only**; L2 = real holders of **`cfo`** = **`admin` only**.
  Probed each account against `require_approver_for(level)` as `postgres` with that user's claims.
  **Only `chooer` passes L1 and only `admin` passes L2**; every other account gets
  `APPROVAL_NOT_AUTHORISED|<level>|<role>`.

  > ★ **Two of my readings were blind, and I'm recording that.** A first loop ran as `authenticated`,
  > which cannot EXECUTE `require_approver_for`; the error was hidden by my `grep`, so the loop printed
  > "passes" for everyone. A second loop called the function in an unused subquery column, and the
  > planner skipped a STABLE call, so again everyone "passed". **Only the third form, with the call in
  > the select list, separated the accounts.** I trust the reading above because it has both outcomes.

### §1.4 · Can a plain employee do it today? Measured on live

Simulated identity: **`fusheng@evoltrya.test`** (`authenticated`, `auth.uid()` confirmed,
`has_permission('module.hr.view') = f`, `has_permission('module.finance.view') = f`).
Each call ran inside a read-only transaction, so an INSERT **cannot** happen. A call that
reaches its INSERT fails with *"cannot execute INSERT in a read-only transaction"*,
**which proves the permission gate and every earlier check passed.**

| call | result | meaning |
|---|---|---|
| `submit_leave_request(own, 'annual', 2026-12-01, 2026-12-01)` | `cannot execute INSERT in a read-only transaction` | ✓ gate and all validations (overlap, balance) passed |
| `submit_medical_claim(own, 2026-09-20, 10.00)` | same | ✓ |
| `submit_expense_claim(own, 2026-09-20, 10.00, 'SGD', …)` | same | ✓ |
| `submit_leave_request(EMP-2026-0001's uuid, …)` | `PERMISSION_DENIED\|module.hr.edit` | ✓ refused for someone else |
| `submit_medical_claim(EMP-2026-0001's uuid, …)` | `PERMISSION_DENIED\|module.hr.edit` | ✓ |
| `submit_expense_claim(EMP-2026-0001's uuid, …)` | `PERMISSION_DENIED\|module.finance.view` | ✓ |
| `submit_leave_request(NULL, …)` | `EMPLOYEE_NOT_FOUND` | refused, but see note |

> Note on the NULL row: with `p_employee_id` NULL the gate evaluates `NOT (false OR NULL)` = NULL,
> so **the `IF` doesn't fire**. The refusal comes from the next statement (`employees WHERE id = NULL`).
> It is safe today only because that line is there. The same shape is in all three functions.
> (My first "for someone else" attempt passed the uuid through a subquery that ran under RLS, came back
> NULL and tested **this** path, not the other-person path. I reran with the literal uuid; those are the
> rows above.)

Own reads as `fusheng` (simulated identity, so counts are what he can see):
`my_profile` 1 row · `leave_balance(own,'annual')` returns an object · `medical_claim_balance(own, 2026)`
= limit 1000, pro-rated 333, claimed 0, remaining 333 · `medical_claim_status` 0 rows (he has none;
true total of medical claims is 1, `postgres`) · `leave_requests` 0 rows (he has none) ·
**`approval_log` 0 rows**. That last 0 is **a policy refusal, not an absence**:
the table's SELECT policy is `CASE subject_type WHEN 'leave_request' THEN has_permission('module.hr.view') … END`,
with **no own-document arm**.

### §1.5 · What the employee sees on `/me` today

Reached **only** from the avatar menu row "My profile" / 「我的档案」 (`AvatarMenu.tsx:222`);
`grep` for a `'/me'` link finds no other entry in `app/components` or `lib`. Top to bottom:
avatar · profile card (department, job, manager, hire date, **annual leave available / accrued / rate**) ·
payslips · training · employment history · self-assessment (when open) · finished reviews ·
**Leave** (balance, per-grant breakdown, *Request leave* form, own requests) ·
**Medical claims** (limit / claimed / remaining, *Submit a claim* form, own claims) ·
**Expense claims** (*Submit* form, own claims, *Withdraw* on `submitted`) · KPIs · attendance.

| can the employee see… | leave | medical | expense |
|---|---|---|---|
| own balance | ✓ **annual only** (other types: none) | ✓ pro-rated limit, claimed, remaining | n/a |
| own requests | ✓ | ✓ | ✓ |
| status | ✓ `status` | ✓ `settlement_state` (includes paid / part-paid) | ✓ status + owing / paid / reversed |
| decision note | ✗ **not selected** (column exists, readable via own-rows RLS) | ✗ **not in the view** | ✓ `decision_notes` |
| **who decided** | ✗ | ✗ | ✗ |
| cancel / withdraw | ✗ **no button** (DB allows) | ✗ **no function** | ✓ |

**Why "who decided" can't just be selected:** `decided_by` is an `auth.users` id. Turning it into a name
means reading **another** employee's row, and `employees` RLS gives a non-HR reader only their own row
(`employees select own row`). So showing the decider needs an owner-rights read path (a view or function):
**a migration**.

---

## §2 · What self-service would need

### §2.1 · The smallest change, per document

**Submission itself: nothing.** The database already guarantees "for themselves only". The guarantee is
the first `IF` of each `submit_*` function, which compares the target to `current_user_employee()`
(derived from `auth.uid()`, not from anything the client sends). It is proven on live in §1.4.
The page passing `fixedEmployeeId` is convenience, not the guard; a forged id is refused by the DB.
**No new permission and no new function are needed to submit.**

What *is* missing, smallest first:

| gap | change | DB? |
|---|---|---|
| G1 findability | Add named entries that say *leave* and *claims*. Options in Q2 | no |
| G3a cancel own pending leave | a button on `/me` calling the existing `cancelLeave` action (`cancel_leave_request` own-arm is live) | no |
| G2 decision note (leave) | add `decision_notes` to the `/me` select (own-rows RLS already allows it) | no |
| G2 decision note (medical) | add `decision_notes` to `medical_claim_status` | **yes** (view; `db/views` mirror in the same commit) |
| G2 who decided (all three) | owner-rights read of the decider's display name for **own** documents only (Standing decision 3: a display label follows the document) | **yes** |
| G3b withdraw own medical claim | new `withdraw_medical_claim` with the same own-arm shape as `withdraw_expense_claim`, plus a button | **yes** (new function, mirror, fixture, i18n codes) |
| NULL-gate hardening | `IF p_employee_id IS NULL OR NOT (…)` in the three `submit_*` | yes (only worth it if the cut has a migration anyway, Q9) |

### §2.2 · How it meets the approval chain as built

- **`forbid_self_approval(created_by, employee_id)` is called by all three decide functions**
  (`decide_leave_request`, `decide_medical_claim`, `decide_expense_claim`; live bodies confirmed to contain
  `current_user_employee`/the guard). A self-submitted document has raiser = subject = the employee, so:
  - **the employee can never decide it.** Raiser leg: `created_by = auth.uid()`
    (`medical_claims` and `leave_requests` default `created_by` to `auth.uid()`;
    `submit_expense_claim` writes `auth.uid()` explicitly). Subject leg: `employee_id = current_user_employee()`.
    APR-3 §9 ⑤ already measured both legs raising on live.
  - **In practice a plain employee also fails earlier**, at `require_permission('module.hr.edit')` or
    `module.finance.view`. The self-approval leg only matters for employees who also hold the decider permission.
- **Deciders are unaffected.** Self-submission changes nothing about who may decide: same functions, same gates.
  **With one live exception, F2:**

  > ★ **F2: a single-holder tier can't decide its own holder's claim.**
  > `chooer` is the only L1 decider (< 1000 SGD); `admin` is the only L2 decider (≥ 1000 SGD).
  > So `chooer`'s own expense claim under 1000 SGD, and `admin`'s own claim of 1000 SGD or more,
  > **can be decided by nobody on live.** The self-leg blocks the holder, and no one else holds the role.
  > This is not new with self-service (HR entering a claim on their behalf lands the same way, because the
  > subject leg holds). But self-service makes it the **common** case. `approval_gate_intersections`
  > reports `dead=0` (APR-3) because it asks "does anyone hold this tier", not "does anyone **other than
  > the subject**". Leave and medical are fine: three `module.hr.edit` holders.

### §2.3 · What changes for HR's existing pages

**Nothing needs to.** `/hr/leave/new` and `/hr/claims/new` keep the employee picker and the
`module.hr.edit` arm; `LeaveForm`'s `allowException` stays HR-only (DB refuses it without `module.hr.edit`).
When HR enters on someone's behalf, `created_by` = HR and `employee_id` = employee, so both HR (raiser)
and the employee (subject) are barred from deciding. That's already the case and is correct.
If G2 lands, HR's pages could show the same decider name, but that's optional.

### §2.4 · Who can walk each flow end to end on live

| flow | submitter (works today) | decider (works today) | then |
|---|---|---|---|
| leave | **`fusheng`** (plain), or any of the six | `admin` / `sandra` / `vince` (not if they're the subject) | — |
| medical | **`fusheng`** | `admin` / `sandra` / `vince` | pay: a `module.finance.edit` holder (`admin`, `chooer`, `vince`, per APR-3 §4) |
| expense < 1000 SGD | **`fusheng`**, `phua`, `sandra`, `vince`, `admin` | **`chooer` only** | ✗ **`chooer` as submitter has no decider** (F2) |
| expense ≥ 1000 SGD | `fusheng`, `phua`, `sandra`, `vince`, `chooer` | **`admin` only** | ✗ **`admin` as submitter has no decider** (F2) |

**Nobody needs a new permission to submit.** Colleagues testing after APR-6 as plain employees need
**an account linked to an employee record**, and that's all. Only `fusheng` currently looks like one.

---

## §3 · F1: expense claims are readable by every signed-in user (not self-service, found on the way)

- `expense_claim_status` is owner-rights (`security_invoker = off`), so `expense_claims` RLS doesn't apply,
  and **its body has no row predicate**. `medical_claim_status`, by contrast, ends with
  `AND (has_permission('module.hr.view') OR mc.employee_id = current_user_employee())`.
- **Measured as `fusheng`** (simulated identity; `module.finance.view` = f): **4 rows visible, 1 his own,
  spanning 2 employees**. The true total of `expense_claims` read as `postgres` is **4**.
  So every row, with names, amounts and descriptions, is readable through PostgREST by anyone signed in.
  `/me` hides it only because the page adds `.eq('employee_id', …)`.
- The mirror's comment says the caller does the gating ("调用方按 module.finance.view 或本人把关"). COD-2's note there
  justifies not adding a predicate because the view "feeds `operations_now`". **I measured that as false for this
  view:** `grep expense_claim_status` over `db/views`, `db/functions`, `app` and `lib` finds **only** `app/me/page.tsx:165`
  and `app/finance/claims/page.tsx:40`, and no view or function reads it. So the predicate
  `has_permission('module.finance.view') OR employee_id = current_user_employee()` would hide nothing from any legitimate reader.
- All live data is test data, so nothing real is exposed. The defect would carry into production as-is.

---

## §4 · Questions for Tim (every one, none answered here)

**Q1 · Was it the discoverability?**
When you found no way to submit leave, were you looking in the module menus / home page, not the avatar menu's
"My profile"?
➡️ *Recommended:* assume yes and fix findability (Q2). Evidence: §0, §1.4 (all three submit on live as `fusheng`), §1.5.

**Q2 · Where should self-service live?**
(a) Rename the avatar row "My profile" to something like "Me: leave, claims, payslips" and add two more avatar rows,
"My leave" and "My claims", linking to anchors on `/me`;
(b) add a "Self service" module entry, visible to everyone and never 受限, in the module bar;
(c) home-page tiles;
(d) split `/me` into `/me/leave`, `/me/claims` pages.
➡️ *Recommended:* **(a)**. No new routes, no registry permission (`/me` has none), smallest diff.
(b) runs into `lib/modules.ts`'s rule that every module has a permission, which would need a ruling of its own.

**Q3 · Should the employee see who decided, and the note, for all three?**
➡️ *Recommended:* **yes, both, for all three.** Standing decision 3 (a display label follows the document) covers the
decider's name. Evidence: §1.5 table. This is the part that needs a migration (owner-rights read of own documents'
decider name, plus `decision_notes` in `medical_claim_status`).

**Q4 · Should `approval_log` get an own-document read arm, or should the decision be read from the document itself?**
➡️ *Recommended:* **from the document** (`decided_by`, `decided_at`, `decision_notes`). It answers "who decided and why" without
opening an audit table to every employee. `approval_log` stays permission-scoped. Evidence: §1.4 (0 rows is a policy refusal).

**Q5 · In the UI, cancel own pending leave?**
The DB already allows it (`cancel_leave_request` own-arm, live).
➡️ *Recommended:* **yes**, a button on pending rows on `/me`.

**Q6 · Withdraw own submitted medical claim?**
No function exists. Expense claims have one.
➡️ *Recommended:* **yes, same cut**, since Q3 already brings a migration. Mirror `withdraw_expense_claim`'s shape, with the same
own-arm and a `submitted`-only state check.

**Q7 · Leave balances other than annual on `/me`?**
Today only annual shows. Sick and hospitalisation limits exist as leave types.
➡️ *Recommended:* **not in this cut.** Register it in `docs/forward-queue.md`. It's a new read of `leave_balance` per type and a
design choice about which types have a meaningful balance.

**Q8 · F2: the single-holder tiers. What should the end-to-end walk after APR-6 do?**
(a) grant a second holder of `finance` and of `cfo` so every tier has a decider other than its subject;
(b) accept it, and walk with submitters who aren't tier holders (`fusheng`, `phua`, `sandra`, `vince`);
(c) widen `approval_gate_intersections`/`APPROVALS_POLICY_WOULD_STRAND` to count "a holder other than the subject".
➡️ *Recommended:* **(b) for the walk now, and (a) before real use.** (c) is a real fix but a separate cut: it changes the meaning of
the strand guard APR-3 just built. Evidence: §1.3 tier probe, §2.2.

**Q9 · Harden the NULL arm of the three `submit_*` gates?**
➡️ *Recommended:* **yes, only if this cut has a migration anyway** (it does if Q3 or Q6 is yes). Today it's safe only because the next line
refuses. Evidence: §1.4 note.

**Q10 · F1: fix `expense_claim_status` row exposure. In this cut or its own?**
➡️ *Recommended:* **its own cut, first.** Named reason: it's a security defect in a finance view with a different reviewer question
("who may read other people's claims"). Folding it into a UX cut would bury it in that cut's report. Fix: the predicate in §3, with the
mirror and a fixture reading as a non-finance, non-subject user. Evidence: §3.

**Q11 · Test accounts for colleagues.**
No account holds only `employee`, and `employee` has zero permissions. Should colleagues get their own accounts, each linked to an employee
record and holding only `employee`?
➡️ *Recommended:* **yes.** Only then does the walk test what a real employee sees; `fusheng`'s warehouse role adds module menus a
plain employee won't have.

---

## §5 · Proposed build and estimate

**One cut, EMP-SELF-1**: G1 + G2 + G3 (+ Q9 if a migration lands), assuming the recommended answers.
**F1 is split out** (Q10, named reason above), as **F1-FIX**, ideally first. **F2 is config or a separate cut** (Q8).

### §5.1 · Process floor (machine time, measured figures with their sources)

| step | cost | source |
|---|--:|---|
| grilling round trip | Tim's clock | — |
| `survey-phone.mjs` (one route, `/me`) | 102 s | AGENTS.md, measured |
| `npm run build` | ~22 s | AGENTS.md (19 checks 3 s + `next build` 19 s) |
| `db/gate.py --offline` | 44 s | AGENTS.md, measured 2026-09-05 |
| backup | ~10 min | AGENTS.md, measured 2026-08-14 |
| `apply_migration.sh` | < 1 min | not separately measured; single transaction |
| `db/gate.py` full | 310 s | AGENTS.md, measured 2026-09-05 (DRAFT-0 also records a 437 s run; **measure it again, don't quote either**) |
| `smoke-routes.mjs` | 765 s | AGENTS.md, measured 2026-09-05 |
| live proof (fixture-style probe as `fusheng` and a decider) | ~5 min | my estimate, not measured |
| **floor** | **≈ 37 min** of machine time, plus Tim's clock | |

### §5.2 · Measured work

| item | size of the change (measured) | estimate |
|---|---|--:|
| G1 avatar rows + label + `/me` anchors | `AvatarMenu.tsx` has 1 `/me` row (`:222`); 2 message files | 0.5 h |
| G3a cancel-leave button | action `cancelLeave` exists; `MyLeavePanel.tsx` 139 lines | 0.5 h |
| G2 leave note (select only) | one column in `app/me/page.tsx:158` | 0.25 h |
| G2 decider name + medical note (migration, view mirror, types regen, fixture) | 3 documents, 2 views + a new own-rows read | 2 h |
| G3b `withdraw_medical_claim` (function, mirror, fixture, i18n codes, button) | shape copied from `withdraw_expense_claim` | 1.5 h |
| Q9 NULL gates (3 functions, mirrors, fixture arm) | 3 × one line | 0.5 h |
| **work** | | **≈ 5.25 h** |

**Sum ≈ 5.25 h of work + ≈ 37 min floor ≈ 5.9 h**, plus Tim's grilling round trip.
If Q3 and Q6 are "no", there's no migration. The cut becomes G1 + G3a + leave note ≈ 1.25 h of work, with a floor of
≈ 15 min (no backup, no full gate needed for a UI-only cut: build, `--offline` gate, phone survey, smoke), **≈ 1.5 h** total.
