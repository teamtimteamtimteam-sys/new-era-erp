# As-built divergences

Where the code and the planning documents disagree.

**The three documents are not edited.** `Evoltrya-OS-Doc1/2/3` are Tim's planning record — what was
decided, and when. Rewriting them to match the code would destroy the only account of what the plan
actually said, and would make every later reference to them subtly false. Same call as the FIN-1a
migration header (whose classification of the purchase-order estimate columns turned out to be wrong
and was retired in `currency-literals-audit.md`, not edited) and the FIN-23 commit message (retired in
`AGENTS.md` §OPS-7, not rewritten). **The record stays; the divergence is recorded next to it.**

**A divergence is not automatically a defect.** Each entry states which way it points:

| | |
|---|---|
| **DOCUMENT AHEAD** | the plan describes something not built yet — a gap, scheduled or not |
| **DOCUMENT WRONG** | the plan states as already-true something that is not, and never was |
| **DOCUMENT BEHIND** | the code went further than the plan, deliberately, for a stated reason |
| **RESOLVED IN FAVOUR OF THE CODE** | the plan recorded a decision, the code does otherwise, and **the difference has since been ruled on**: the code stands and the document is the artefact now out of date. Kept rather than deleted — a reader arriving at the document would otherwise conclude the decision was never noticed. Entry 6 is the first of these |

Add an entry when a cut discovers a difference. Remove one when the difference closes, and say in
the commit which side moved.

---

## 1 · The ownership / entity dimension does not exist — DOCUMENT WRONG

> **Doc 2, The four foundations:** "Permission-segregated — each user accesses only what their
> permissions allow. The current model is module-level permission (can/cannot enter a module) plus a
> **department/function ownership dimension**."
>
> **Doc 2, Multi-entity:** "data is partitioned by Singapore/EU entity. The two entities are independent
> P&L entities that can each keep their own books and also be consolidated for group analysis."
>
> **Doc 2, sufficient-not-excessive:** "Permission implementation is deferred to a later phase, but
> **from the outset the data layer carries the ownership dimension and RLS hooks**."
>
> **Doc 2, Principle 10:** every module carries "… ownership fields, and operation log."

**As built: neither dimension exists.** Checked against the live catalog:

* `department_id` appears **only on HR tables** (`employees`, `employment_history` and their views).
  It is an org-chart field consumed by HR and by review routing — it is not an ownership scope, and no
  RLS policy anywhere filters on it.
* `entity` appears on **no table at all**. It was on `tasks` until **TASK-1c-a (2026-08-19)** retired
  it along with four other columns (`visibility`, `shared_with`, `editors`, `assigned_to`); measured
  again on **2026-08-24**, the count of columns named `entity` anywhere in `public` is **0**.
  **This bullet used to say "exactly one table — `tasks`", and that sentence outlived the column by
  five days** — corrected here rather than annotated, because a register that describes a column
  which no longer exists misleads exactly the reader who came to it for the current state.
* There is **one** chart of accounts, **one** base currency (`currencies.is_base`, singular), and one
  set of books.

Why this one matters more than the others: Doc 2 states it as *already true*, and Doc 3's Final Phase
is written on top of it — "Data filtered by the department/function ownership dimension every record
has carried, and by entity (SG/EU), **activated through the RLS hooks already in place**." There are no
hooks to activate. When that phase is planned, the first task is a migration across every business
table, not the activation of something dormant.

> **The claim is now a MEASUREMENT rather than a reading (APPROVALS-SOD, 2026-08-24).** Against the
> live catalog: **0 of 447** RLS policies reference a department in `USING` or `WITH CHECK`; **1 of
> 40** soft-deletable business tables carries `department_id` (it is `employees`, and it is an
> org-chart field); `departments` holds **1 row**; **1 of 6** employees points at it; and columns
> named `entity` number **0**. **"There are no hooks" was true when it was written and it is now a
> number somebody can re-run.**
>
> **The sizing lives in `docs/department-scope-survey.md`** — the four costs, the named list of 40
> tables, the question that has to be answered before any schema can be designed (what a row's
> department *means* when the row is not a person), and the order the measurement implies. **It is a
> phase, not a cut**, and the forward queue carries it as a sized item for that reason.
> This entry states the divergence; that file states the size. Neither restates the other.
>
> **What the size then did:** it fired the APPROVALS-SCOPE cut's stop-gate on 2026-08-24, so that
> cut surveyed both of its items and **built neither** — no migration, no schema change, and the
> approvals switch left off. Also measured that day and worth carrying here because it changes what
> "activate the hooks" would have to touch: **362 of the 447 policies are `has_permission(...)`
> predicates**, and **98 tables carry `created_by`** — the only ownership-shaped column that exists
> today, and not the same thing as a department.

It also reaches Doc 3 Phase 3, which specifies "Chart of accounts (**two sets, SG/EU**)" and
"multi-entity consolidated statements (the two independent P&L entities pulled together)". With one
chart and one base currency, consolidation is not a report to write but a schema change to make first.

**The as-built permission model is a different mechanism, not a subset.** What perm1/perm2a/perm2b
shipped is *module access* (`module.<x>.view|edit`) plus *column-level masking by data class*
(`data.view_prices`, `data.view_pay`, `data.view_identity`, …) enforced through `_masked` companion
views. Doc 2 describes *row scoping by ownership*. The two answer different questions — "may you
see this column" versus "is this row yours" — and having built the first does not advance the second.
See `AGENTS.md` §"Adding a column to a masked table".

**The column-level layer is deliberately bounded, and the bound was decided on 2026-08-08.**
Doc 2 says field-level granularity "was not selected"; the code has it anyway, which is the code going
further than the plan. What OPS-14 established is **how much further, and where it stops**:

> **`module.finance.view` implies price visibility.** The general ledger *is* the price data —
> `journal_lines` / `journal_entries` / `expenses` / `payments` / `accounts` carry no column-list
> SELECT grant, so a role holding `module.finance.view` alone reads `unit_price = null` on
> `sales_records_masked` and the same revenue in full off account 4000 (probed: 33,176.00, with
> unmasked quantities beside it). Masking prices from someone who can read every journal line is
> theatre. **`data.view_prices` is therefore a control for non-finance roles only**, and the GL's lack
> of column masking is **accepted**, not a hole to be closed.

This does not contradict any of the three documents — Doc 2 never claims field-level control exists,
so there is nothing here for it to be wrong about. It is recorded next to entry 1 because this is where
a reader asking "how does the permission model actually work" arrives, and because the answer to
"why isn't the ledger masked?" must not have to be re-derived. Full reasoning, plus the two companion
decisions (batch-margin predicate; master-data labels follow the document), in `AGENTS.md`
§"Three standing decisions about what the permission model actually protects".

### `module.pricing.view` covers two different sensitivity classes — RECORDED, not acted on (OPS-15)

**Not a defect today, and deliberately not fixed here.** It is written down because it is the kind of
thing that gets re-derived from scratch the first time someone asks for it, and because OPS-15 stood
directly on top of it.

One module code, `module.pricing.view`, currently answers for two things that are not equally
sensitive:

| | what it is | how the data itself is gated |
|---|---|---|
| **market quotes** | `metal_prices` — the LME-style USD/tonne series | RLS `SELECT … USING (true)`. **Public to any authenticated reader**, no column-list revoke, no masked view |
| **negotiated terms** | `pricing_formulas.treatment_charge_usd_per_tonne`, `.flat_discount_pct`, `pricing_formula_metals.payable_pct` | RLS `USING (has_permission('module.pricing.view'))`, **plus** a perm2b column-list revoke — readable only through `pricing_formulas_masked` / `pricing_formula_metals_masked`, gated on `data.view_prices` |

The first is a market fact anyone may see. The second is **what this company agreed to pay a specific
counterparty** — the commercial terms of a deal, and by FIN-27 they are copied onto the committing
record precisely because they are a commitment rather than a computed quantity.

**The permission catalogue's description of `module.pricing.view` — "formulas, calculator and market
quotes" — names all three, so the code reads as one thing.** The database does not treat it as one
thing: it puts the quotes behind `USING (true)` and the terms behind two locks.

**Why it surfaced now.** OPS-15's page guards were derived from the module catalogue, so all four
`/metal-prices` pages got `requireModule(MOD.pricing)` — a page-level refusal in front of data whose
own RLS declares it public. The rule was restated in code (`lib/modules.ts`, the `/pricing` entry):
**the guard follows the data's own RLS, not the module catalogue.** `/pricing` itself stays gated,
because that is where the terms are.

Applying that rule splits the four pages, because a table's RLS has **two** answers and
`metal_prices`' two differ — `SELECT … USING (true)` against
`INSERT/UPDATE/DELETE … has_permission('module.pricing.edit')`. So the read page carries no guard and
the three editors carry `requireEditPermission('module.pricing.edit', …)`. **Two answers under one
directory is the rule applied twice, not an exception to it** — stated at all four sites so the next
reader sees a distinction rather than an inconsistency. The refusal copy differs too
(`common.editDenied`): someone stopped by the write half can usually *see* the data, and telling them
they have no access to the module would be false.

**What is still unresolved, stated so it is not mistaken for settled:** there is no way to grant
someone the quotes without also offering them the module code that names the terms. Nothing is
leaking — the terms have their own second lock in `data.view_prices`, and OPS-15's removal of the
guard changed no database permission — so this is a **shape** problem, not an exposure. It becomes a
real question the first time a role needs market quotes and must not have the module: the answer will
be either a `module.metal_prices.view` of its own, or an explicit statement that the quotes are
outside module gating altogether, which is what the code now does de facto for the four pages.

---

## 2 · Principle 7 is stated absolutely; five paths delete physically — DOCUMENT AHEAD

> **Doc 2, Principle 7:** "Soft delete, never hard delete. All business records are soft-deleted with
> `deleted_at`, recoverable and retained for audit. **The system performs no physical deletion** — the
> compliance and audit requirements of recycling demand that data remain traceable and recoverable."

**As built, five app paths issue a physical `DELETE`:**

| path | what it deletes | reading |
|---|---|---|
| `app/purchasing/payment-terms/actions.ts` | `payment_term_template_lines` — delete-all-and-reinsert on every template edit | defensible: a template line has no independent identity, the plan *is* the edit unit |
| `app/pricing/formulas/actions.ts` | `pricing_formula_metals` when a metal is cleared | "not in the table" **is** the meaning of "not payable"; but FIN-27 had to add `pricing_formula_history` precisely so this deletion leaves a trace |
| `app/components/metals/metalContentActions.ts` (×2) | assay / batch metal content rows | same shape as above |
| `app/hr/leave/types/actions.ts` | `public_holidays` | calendar reference data, not a business record |

None is a transaction or a ledger row, so nothing audit-bearing is lost today. The divergence is that
the principle is stated with no exception and the code has four kinds of exception — so the principle
cannot be used as a decision rule without re-deriving the carve-out each time.

**One table was moved onto the principle's side deliberately:** FIN-31 added
`guard_cost_entry_no_hard_delete` to `processing_cost_entries`, because a hard delete there skipped
the reversing journal, skipped the history row, and let the allocation staleness flag move *backwards*.
Before that it was blocked only incidentally, by a foreign key from the audit table. Principle 7 endorses
that fix independently — it is the principle the code was quietly violating.

### PDPA 与原则 7 正面相撞,而【就地匿名化】同时满足两边(PDPA-1,2026-08-24)

**这不是上面那五条"物理删除"里的第六条 —— 它一行都不删,而它看起来像是在删。**

原则 7 说:**软删,永不硬删,系统不做任何物理删除。**
PDPA 的保留限制说:**目的结束之后,不再保留个人数据。**
而**一行软删掉的员工仍然带着他的身份证号** —— `deleted_at` 置上了,
`identity_no` 一个字节都没动。**于是这两条不可能同时按字面满足。**

**调和的办法:`anonymise_employee()` 做【就地匿名化】—— 把身份列覆盖掉,行留着。**

理由是**原则 7 的目的是【可审计】,不是"名字的那几个字节"**:

| 原则 7 真正要的 | 匿名化之后 |
|---|---|
| 外键不断 | **不断** —— 行还在,`employee_id` 的每一个引用都还指得到 |
| 每一笔过账都还在 | **都还在** —— 总账、工资行、假期、报销一行未动 |
| 历史读得回来 | **读得回来** —— 编号、雇佣类型、工种、入离职日、部门全部保留 |
| 可恢复 | **不可恢复,而这正是 PDPA 要的** —— 见下面那一行 |

**四项里前三项完整成立,第四项【故意不成立】。** 那一格就是这次调和的全部代价:
原则 7 承诺"可恢复并留档以备审计",而匿名化**不可逆** —— 覆盖掉的身份列
没有任何一条路把它们取回来。**这不是实现上的缺憾,是 PDPA 的要求本身**:
一份还能恢复的个人数据,并没有"不再保留"。

**所以本条的判词是:原则 7 在【可审计】这个目的上被完整遵守,
在【可恢复】这个措辞上被刻意突破一次,而突破的授权来自一条法律义务。**
读的人不需要每次重新推导这个碰撞 —— 它就在这里。

> **它保留的那些列【不指向一个人】**:编号、雇佣类型、工种、入离职日、部门。
> 这是"化名化"(pseudonymisation)与"匿名化"的分界线所在:身份列一旦从
> `employees` 这一行拿掉,**其余每一张表都只按 `employee_id` 引用他** ——
> 那些行不再指向一个可识别的自然人。**这条推理是"为什么只动两张表"的全部理由**
> (`employees` 与 `employment_history`;后者的薪资额与备注本身是个人数据)。
>
> **它是关着的,而且在今天的裁定之下【将一直关着】。** 保留期
> (`hr_settings.personal_data_retention_months`)没有默认值也没有设,函数按名拒绝
> `PDPA_RETENTION_PERIOD_NOT_SET`。**Tim 于 2026-08-24 裁定:员工个人数据无限期保留**,
> 所以那一列保持 NULL,而这支函数是一件**建好了、刻意休眠**的机制,不是没做完的活。
> 裁定全文、范围、待决项与那四条按名拒绝见 `docs/pdpa.md`,**本条不复述**。
> **本条的判词不因此改变**:这次调和仍然成立,只是它今天没有被行使。

**同一个碰撞在 `employment_history` 上更硬一档,而处置是同一个(PDPA-1-fu)。**
那张表不只是软删的,它是**不可变的** —— `trg_employment_history_immutable` 对
UPDATE 与 DELETE 一律 `RAISE`。而薪资两列与备注是个人数据,匿名化必须动得了它们。

**PDPA-1 的第一版没有看见这一点,于是它在真实数据上的成功率是【零】** ——
每个员工入职就有一条履历行,而函数里那句 `UPDATE employment_history` 撞上守卫
必然抛 `EMPLOYMENT_HISTORY_IMMUTABLE`。**三道门(预检、`colgrant`、库上应用)
一道都没有看见它:它们检查结构,而这是一条只在运行时才存在的路。**
抓到它的是 `db/fixtures/126` 的 E 臂 —— 它刻意造了一个**涨过薪的离职者**,
也就是最可能走到保留期满的那种人。

**处置:不可变【不是】不可匿名化,而那条例外由【形状】定义,不由开关定义。**
唯一放过的 UPDATE 是:`anonymised_at` 从 NULL 变成非 NULL、三个个人数据列全部变
NULL、**其余每一列逐个断言一字不动**;DELETE 永远拒绝。一个
`set_config('anonymising','on')` 式的旁路会让任何人在声称自己在匿名化的时候改历史;
一个形状检查不会。`employment_history_salary_shape` 同时多了一个析取项 ——
**已匿名化的调薪行有权说不出新薪资。** 例外有多窄,由 fixture 126 的 I 臂证明
(普通 UPDATE、DELETE、以及**披着匿名化外衣却顺手改了别的列**的那一种,全部仍被拒)。

---

## 3 · Principle 6's approval chains — DOCUMENT AHEAD, and deferred by plan, not dropped

> **Doc 2, Principle 6:** "Every value-bearing action in the system (purchase orders, payments, price
> changes, stock issue, expense claims) passes through an approval chain. … Approval is two-level: the
> requester raises the request and the supervisor approves; above a threshold (e.g. 10k) it escalates to
> CFO approval."

**As built when this entry was written:** approval chains existed **only in HR** — leave requests,
medical claims, performance reviews (`submit_leave_request`, `submit_medical_claim`, `submit_review` /
`approve_review`, with a four-eyes rule on reviews). On the finance and purchasing side there were
none: `create_purchase_order` wrote `approval_status = 'approved'` unconditionally, and payments,
price changes and stock issue had no approval step at all.

> **UPDATED 2026-08-24 (APR-3 survey) — the second sentence is no longer true, and leaving it would
> make this entry lie in the direction that costs most: it would read as "nothing is built".**
>
> **APR-1 and APR-2 built the purchase-order chain in full**: `approval_log` (append-only, subject
> pair, amount frozen at the decision), `approvals_enabled()` / `approval_level_for()` /
> `require_approver_for()`, `approve_purchase_order` / `reject_purchase_order` (four-eyes
> `SELF_APPROVAL_FORBIDDEN`, base-currency routing on the document's own rate),
> `void_approval_on_amount_increase`, `guard_po_amendable` (so a direct write cannot set
> `approval_status`), and three enforcement points — receiving, prepayment/payment, and **issuing
> to the supplier** (`record_po_issue`, which did not exist when APR-2 wrote "there is nothing to
> gate"). `create_purchase_order` is now **conditional**: `draft`/`pending` when the flag is on,
> `confirmed`/`approved` + a log row saying `auto_approved` when it is off.
>
> **What is still DOCUMENT AHEAD, stated precisely so the gap is not read as bigger or smaller than
> it is:** the flag `finance_settings.approvals_enabled` is **false**, the three policy columns are
> **NULL**, **`approve_purchase_order` and `reject_purchase_order` have no caller anywhere in
> `app/`** (so there is no screen to approve on), eleven refusal codes have no bilingual sentence,
> and payments, price changes and stock issue still have no approval step. **Doc 2 Principle 6 names
> five actions; one of them now has an engine that is switched off and has no operator surface.**
> Measured in full in `docs/approvals-scoping.md` §APR-3.

**This is deferred by plan, not dropped.** Doc 3's Final Phase lists "Approval workflows activated —
the value-bearing-action approvals designed into procurement, sales, and finance are bound to the role
structure — requester to supervisor, above-threshold to CFO — with approval delegation and audit
trail." The `purchase_orders.approval_status` column and its `pending/approved/rejected` values are
the reserved interface; the flow is the Final Phase's work.

**What was wrong was the code's own note about it.** The PO screen said the workflow "activates with
the permissions system" — and the permissions system shipped, so the screen was pointing at a
condition that had already passed, which is the same defect as a comment describing a hazard that
cannot occur (`AGENTS.md` §"a note describing a hazard that no longer exists"). Corrected: the
copy now says auto-approved for now, two-level approval with the Final Phase. The permissions cut
delivered module access, which is a different thing from who approves an order.

### Segregation of duties — where the `action.*` reservation actually lives, and the one measured path SOD-1 closed (2026-08-24)

**The citation correction first, because a wrong pointer costs the next reader a search.** The
reservation of the `action.*` permission category for *posting, month-end close and payroll posting*
is **not** recorded in this file. It lives in the header comment of
**`db/tables/permissions.sql`** (line 14): *"'action' 留给过账、关账、薪资过账这类动作级权限 ——
到时候【只是加行】"*. This entry is where a reader looking for it will arrive, so the pointer is
recorded here; the sentence itself is not copied, because the same fact stated in two places drifts.

**As built, that category holds exactly two codes** — `action.manage_permissions` and
`action.bulk_import` (IMPORT-1). **None of the three reserved action-level permissions was ever
built**, so posting, month-end close and payroll posting are gated by `module.finance.edit` and
`module.hr.edit` alone.

**The measured consequence, and it is the reason the control exists rather than a separate defect.**
Probed against `role_permissions` on 2026-08-24:

> **The `finance` role holds `module.suppliers.edit` AND `module.finance.edit`.** One person in that
> role could create a payee and pay it, end to end, with nothing in the database refusing. Not a
> hypothetical shape — a row in the live role matrix. `admin` and `gm` hold both as well.

The same measurement found `post_journal_entry` and `close_period` gated by the *same single code*,
so one person could post a discretionary adjustment and then lock the period that would have exposed
it.

**SOD-1 (2026-08-24) closed those two paths in the database**, with one shared rule
(`assert_segregated`) asked two different questions, and the guards on the **base tables** rather
than in the server actions — GO-2 measured that `authenticated` holds table privileges and that
`/finance/settings`' manual lock is a direct `UPDATE` that never passes through `close_period`.
**Tim accepted the operational cost**: the single `finance` account can no longer do both halves, and
the refusal names the route out rather than presenting a wall.

**What is NOT closed, so this does not read as finished:** payroll posting and the HR self-approval
paths still have no such rule (they wait on the approvals engine and on a level-2 approver existing),
and **who may change the approvals switch is still the same key as who may change the lock date**.
Both are in `docs/known-issues.md` — `SOD-ONE-PERSON` and `APPROVALS-SWITCH-UNGUARDED` — with the
measurements. **This entry states the divergence from Doc 2's Principle 6; it does not restate them.**

---

## 4 · Principle 8 — DOCUMENT BEHIND: the code went further, on purpose

> **Doc 2, Principle 8:** "The system is fully bilingual (EN/ZH), with English/Chinese key parity
> enforced at build time **via `satisfies Messages`** — a missing or mismatched translation key fails the
> build."

**This is the one where the document is behind the code, not ahead of it.** The intent — parity
enforced at build time, build fails on a miss — is met and exceeded. Only the named mechanism is
out of date, and it was replaced for a reason that was paid for three times.

`satisfies Messages` is a *type-level* check. It can only see keys written as literals. The i18n resolver
returns the key itself when a translation is missing, so a miss prints `hr.alertType.salary_not_set` on
screen and **nothing fails** — and all three historical bugs lived in exactly the keys a type constraint
cannot see: **dynamically built** ones, `t('hr.alertType.' + a.alert_type)`.

So the as-built enforcement is `scripts/check-i18n.mjs`, run inside `npm run build` (and therefore
unskippable), with two halves:

* **static** — every `t('…')` literal must exist in both `messages/en.ts` and `messages/zh.ts`;
* **dynamic** — every `t('prefix' + x)` construction must be classified in the script's `MANIFEST`, and
  for enumerable suffix sets the checker **reads the source of truth at check time** (a `CHECK (col IN
  (…))` in `db/tables/*.sql`, a `new Set([…])` in an `*ErrorCodes.ts`, an `as const` array). Adding an
  enum value widens the check automatically; a resolver that parses zero suffixes **fails**, because a
  broken parser is not an empty set.

An unclassified dynamic prefix is a failure, not a pass. `satisfies Messages` would report clean on
every one of the three bugs this replaced.

**Read this entry as a decision, not a lapse.** If Doc 2 is ever revised, Principle 8's *intent* stands
unchanged and only its mechanism sentence needs updating. Full reasoning in `AGENTS.md`
§"The i18n key check runs on every cut that touches the app".

---

## 5 · The allocation basis has two implementations, Doc 2 names three — DOCUMENT AHEAD

> **Doc 2, processing module:** the redesigned module makes the allocation basis an explicit,
> configurable choice rather than an implicit assumption — **by weight, by metal value, and by
> MARKET VALUE of each output** — because the answer directly determines the reported gross margin
> of each output batch.

**As built there are two:** `processing_runs.allocation_basis CHECK (allocation_basis IN
('weight','metal_value'))`, and `allocate_processing_costs` branches on exactly those two.
**Market value of each output does not exist.**

Found while doing FIN-36, which made the *choice* explicit (it was previously a schema default
nobody could see). The two halves of Doc 2's sentence had different fates: **"explicit, configurable
choice" is now true; "three bases" is still not.**

**Why it was not built in the same cut, deliberately:** metal value is derivable from data the run
already has — output metal content plus the metal price series. **Market value of the finished
output is not**: nothing in the schema records what an output batch is worth on the market before
it is sold. It would need either a price series per output material or a valuation entered per run,
which is a data-capture decision rather than an arithmetic one. Building it as a third `CASE` branch
over data that does not exist would produce a third basis that silently returns the same answer as
one of the other two.

**What to check when it is built:** FIN-25's discrimination test. A third basis that cannot be shown
to produce a *different* unit cost from the other two on some constructed run is not a third basis —
`db/fixtures/34` already asserts weight and metal value diverge and would extend naturally.

---

## 回收率表的两侧【认识论上不对等】—— 机制已由 PROC-1 关上;产出侧【测什么】仍是 Doc 1 的空白(REC-1 报告 2026-08-10,PROC-1 收窄 2026-08-12)

REC-1 记下的不对等:`processing_metal_recovery` 一行两个数,读起来像同一种事实的
两次测量,而投入侧是化验结果(有单号、有取代链、可撤销),产出侧只有手工格子
(没有单号、没有出处)。它当时提出三问,**PROC-1(2026-08-12)把三问都答了**:

1. **同一张 assay_results 表**,可空的 `output_batch_id` + `num_nonnulls = 1`
   (processing_inputs 的形状)。记录、编号、取代链共享;**应用拆开**——
   `apply_output_assay` 只抄含量,不藏在 `apply_assay_result` 的 IF 里。
2. **产出化验不影响定价。** 进料化验的应用就是重述应付;产出批没有应付可重述。
   它动的是"这批东西是什么";metal_value 分摊因此过期(第六过期源),金额只由
   人显式重跑分摊来动 —— FIN-8 以来的分工不变。已售批次的 COGS 不被化验触碰。
3. **含量带出处**:两张 `*_batch_metals` 都有 `content_source`('assay'/'manual')
   + `source_assay_id` —— FIN-26 的答案原样适用,出处是记录的,绝不推断。
   回收率视图每侧带聚合出处(assay / manual / mixed / unknown),守恒警告从此
   分得出"实验室 vs 手敲"与"实验室 vs 实验室"。守恒**仍然只是提示,绝不设闸**:
   化验是对事实的测量,因为它与期望矛盾就拒绝落账,压掉的恰恰是证据。

**仍然开着的,点名记在这里 —— 产出侧【必须测哪些指标】,Doc 1 在此处空白,
Tim 未决。** 机制接受任意金属子集:一份只报 ni 的产出化验照常落账、照常取代
全部旧含量(化验是完整陈述,不是差量)。"哪些金属必须测、缺了算不算完整证书"
是一条尚不存在的规则 —— 等第一张真产出化验单来定,不预先编造。在那之前,
**回收率仍是有用的估数而非可审计的 KPI**,只是现在它能说出自己除的是哪一种数。

~~**第二个还开着的口,小一号(PROC-1b 查明,报告而不顺手修):回收率视图的
出处列没有任何屏幕在读。**~~ **【已关,PROC-1c,2026-08-12 —— 移动的是代码那一侧】**
`/processing/[id]` 现在把 `input_source` / `output_source` 一并取来,两处用它:
每一侧的数字下面标出处(回收率是产出÷投入,"这个百分比除的是哪一种数"是
**每一侧各自**的事实),以及守恒警告里 —— 警告先照直说两侧出处(事实),
再给一句该先看哪里(判断),两句分开写,因为那句判断遇上 `mixed` / `unknown`
必然粗糙,而粗糙的判断不该把事实一起吃掉。三种情形分开:两侧都是化验
= 打错字解释不了它,真异常;任一侧出处未记 = 说不出是哪一种,不猜;
其余 = 先去看不是化验的那一侧。**这一刀不碰机制,视图一个字没动。**


---

## 收货拦截读的是【供应商】,而合规是按【物料】判的(MAT-1 报告,2026-08-12)

不是缺陷,是一个**尚未表达出来的区分** —— 记在这里,因为决定它形状的那个理由
比设计本身更要紧,而下一个接这一刀的人应当先撞见理由。

CMP-1 的 `guard_supplier_qualification` 问的是:**这个供应商有没有一张过期的、
处置为 block 的证书**。它一个字都没提物料。于是一张 Basel 证会为这家供应商的
**每一批货**背书 —— 不管来的是重点物料还是一箱包装材料。

MAT-1 把分类放到了物料上,于是下面这句话**第一次变得可以表达**,而今天仍然不能:

> **"这家供应商是有证的,但不是【这一类】物料的证。"**

### 三条路,以及为什么其中一条被否掉

| | 范围记在哪 | 结果 |
|---|---|---|
| (a) | `certificate_types`(证书**类型**上) | **否掉** —— 见下 |
| (b) | `supplier_compliance`(**每一张证**上) | 倾向,但要等见过真证 |
| (c) | 不建范围,只在收货页提示"这批是重点物料,请人工核对证书范围" | 现在就能做,且不堵住 (b) |

**(a) 被否掉的理由是它的失败模式,不是它的复杂度。** 把范围记在类型上,等于断言
"所有 Basel 证覆盖的范围都一样" —— 而范围是**签发机关写在那一张证上的**,
不是证书类型的属性。第一张范围较窄的证进来,系统就会让它**看起来覆盖了它并不
覆盖的物料**:一个安静的**假阴性**。

**而一个假阴性比没有拦截更坏**,理由与这份文件里反复出现的那一条相同:
没有拦截时,人知道自己在自己判断;有一个不会响的拦截时,人以为系统在替他判断。
后者把"没人看过"伪装成"看过了、没问题" —— 与 `restricted-is-not-zero`、
`no_reference`、以及 MAT-1 自己那条"未分类不是非受控"是同一种病。

### 还有一个必须一并回答的问题

做 (b) 的那一刀会**立刻长出第二个 NULL 陷阱**:一张**没有声明范围**的旧证,
在新规则下算"覆盖一切"还是"什么都不覆盖"?

按这个仓库的一贯答案:**两者都不对**。它应当是第三种状态 —— 既不放行、
也不静默拦截,而是**让人去看那张证**。这与 MAT-1 里 `NULL` 的处理、
METAL-1 的 `no_reference`、METAL-2 的 `price_index IS NULL` 是同一条。
在决定 (a)/(b)/(c) 之前先把这一句想清楚,否则新拦截会带着一个和它要修的问题
一模一样的洞上线。

完整分析(含与 `category` / `chemistry` 的分工、以及明写不做的四件编码体系)在
`docs/material-classification-scoping.md`。

---

## WO-1a:工单落地时,三份蓝图里有一处【文档是错的】,另有两处读法要写下来

WO-1 的调查把 Doc 1 / Doc 2 / Doc 3 关于工单的每一句都读了一遍。落地时有三件事
必须在这里留档,否则下一个人会拿文档去对代码,然后以为代码错了。

### 一 · Doc 2 说加工单从 draft 走到 submitted —— **文档是错的**

Doc 2 的运营审计那一节写着:

> document status-change history (e.g. the full progression of a **processing run
> from draft to submitted**)

**这个系统里的加工单没有草稿态,而且那是记录在案的设计,不是遗漏。**
`processing_runs.status` 的 CHECK 只有 `committed` / `reversed`,镜像抬头写着
"加工一经提交只能整体冲销(rollback_processing_run),没有'编辑中'状态"。
理由是实的:提交那一刻库存真的被扣掉、产出批真的建出来,一个"草稿加工单"要么
不动库存(那它就不是加工单,是计划),要么动了库存又说自己还没发生(那台账就说了谎)。

**WO-1a 之后,那些计划态在【工单】上:** draft / released / closed / cancelled。
Doc 2 想要的那件事因此是有的 —— 只是它在计划那张单据上,不在实绩这张上。
**所以这不是"尚未实现",而是文档描述的对象错了。**

### 二 · Doc 3 的 "the work order becomes the unit that carries cost" —— 读作【归拢】

> Work order and execution. … **The work order becomes the unit that carries cost.**

这句话有两种读法,而它们的工作量差着一个数量级:

* **(a) 成本的载体从加工单搬到工单** —— `allocate_processing_costs`、
  `processing_run_allocation_status`(四个过期源)、`batch_margin`、以及两个
  仪表盘支(`allocation_stale`、`margin_cost_not_allocated`)全都以加工单为主体,
  搬家是一次重构;
* **(b) 成本仍然记在加工单上,工单层面的毛利是【把挂上来的加工单加起来】** ——
  纯增量。

**取 (b)。** 判据是 Doc 3 自己的 Milestone 3:"true per-batch and per-work-order
gross margin" —— 一个**归拢**同样满足这句话,而且满足得更早。(a) 要付的代价没有
任何一份文档要求过,而这个仓库反复得到的结论是:**没有被要求的重构不要顺手做。**
若将来出现"同一笔成本要按工单而不是按加工单分摊"的真实需求,这一行就是要改的地方。

### 三 · 计划【不扣料】—— 一处刻意的缺席,有证据才回来

「为一张计划中的工单扣住料」今天表达不出来,而 WO-1a **没有去把它做出来**:

* `on_hold` 桶有理由(自由文本)、**没有归属列** —— 一次暂扣说不出"为哪张工单";
* `committed` 桶在结构上属于销售(`sales_order_reservations.sales_order_line_id`
  是 `NOT NULL`),不是一个通用的"许出去了"的桶;
* 流水表的注释还记着一个刻意的决定:**`on_hold` 与 `committed` 之间没有直达的边**,
  因为系统无从判断跨过去之后那个暂扣的理由还成不成立。

三条路(什么都不扣 / 给 `on_hold` 加归属 / 第四个桶)各有代价,而**今天没有任何
证据说哪一条对**:线上 `on_hold` 至今**只有一对流水、净额为零**(实测 2026-08-16)。
在这种时候造一个桶,造出来的是一个没人用、却要被后面每一次库存改动照顾的机制。

**回来的判据写在这里,免得它变成一句"以后再说":出现第一例"计划中的料被别的单
吃掉、而计划因此做不成"** —— 那时才知道该扣在哪个桶、扣多久、谁能放。

### 四 · 放行是那个可审批的动作,而默认是关的(WO-1b)

Doc 2 的运营审计原则点名要 "**who approved the work order**"。WO-1b 把
`'work_order'` 加进 `approval_log.subject_type` 的枚举(那份镜像自己写着"这个枚举
【就是】将来加动作时唯一要改的地方"),并把审批挂在 **`release_work_order`** 上。

**为什么是放行,而不是新建或收工:**

* **新建**不是承诺 —— 一份草稿谁都可以写,拦它只会让人不写计划;
* **收工**是事后记录 —— 那时料已经下去了,批准或不批准都改变不了已经发生的事;
* **放行**的意思正是"可以下料开工了"。那是要有人负责的那一下,而且它【之后】
  才允许挂加工单(`commit_processing_run` 拒 `WO_NOT_RELEASED`)—— 所以这道
  审批真的站在物理动作前面,不是一个盖在既成事实上的章。

**层级是 1,不按金额分档。** `approval_level_for` 是按 `amount_base` 分档的,
而工单没有金额 —— 它是一份要做什么的计划,不是一笔钱。与 `leave_request` /
`performance_review` / `stocktake` 同一类,它们的层级也不由金额决定。留痕里那四个
金额列因此**留空,而不是塞 0**:0 会让它在按金额筛的报表里排到最前面,那是一句假话。

**默认是关的,所以这一刀不改变任何人今天的操作。** `approvals_enabled` 默认
`false`;关着的时候放行照走,只是留下一条 `auto_approved` 的痕,写着"审批流未启用
—— 系统直接盖章,没有人做过这个决定"(与 `create_purchase_order` 逐字同一句)。
**结构有了,而没有强加流程** —— 什么时候打开是运营的决定,不是这一刀的。

---

## 6 · Stock valuation: the documents say moving weighted-average, the system does batch-level specific identification — **RESOLVED IN FAVOUR OF THE CODE (2026-08-23)**

> **Doc 1, inventory module, marked as a decision to be made:** "`[DESIGN DECISION] Stock-valuation
> method? — € Weighted average — € FIFO — V Moving weighted average`", annotated "*(Directly bears on
> the inventory value in financial statements; must align with accounting standards.)*" **The tick is
> on Moving weighted average.**
>
> **Doc 3, Phase 2, stated as settled:** "*Metal-content-based valuation. **Stock valued on a moving
> weighted-average basis**, with valuation linked to assay results, metal percentage, moisture, and
> impurity*"; and, under the same phase's connections: "***Moving weighted-average valuation feeds
> finance (Phase 3).***"

**As built: specific identification at batch level.** Each inbound and output batch carries its own
cost; cost of sales is the cost of the specific batch sold. `record_output_sale` takes COGS from the
sold output batch's own `unit_cost_base`; `output_batches` has never carried an average-cost column;
`allocate_processing_costs` allocates per output batch and re-allocation posts per-batch deltas
(FIN-24). There is no average struck across batches anywhere in the schema or the functions.

**Resolution — Tim, 2026-08-23: the code is right; the founding documents are the artefacts now out of
date.**

The accounting reason, which is the part that matters to an auditor: weighted-average costing suits
inventories of items that are **ordinarily interchangeable**. Battery scrap batches are not — each
carries its own assay, and is bought and sold on the strength of it. Averaging cost across batches
severs the link between a lot's cost and its metal content, which is the figure the business is priced
and managed on. The standards call for specific identification where items are not ordinarily
interchangeable, which is the case here.

**Why this entry exists even though the difference is closed.** Doc 1 put the question to a vote and
Doc 3 built two phases of narrative on the answer. Without this entry, a reader arriving at either
document would find a stated method the books do not follow, and would reasonably conclude the ballot
was never noticed. **It was noticed and it was reversed.** Per this file's opening rule the documents
are not edited; the reversal is recorded here.

Stated as policy, with its enforcement points, in `docs/accounting-policies.md` §2.1.

**This entry is not an open difference.** It requires no action.
