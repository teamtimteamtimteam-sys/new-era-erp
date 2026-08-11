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
* `entity` appears on **exactly one table — `tasks`**. No business table is partitioned by entity.
* There is **one** chart of accounts, **one** base currency (`currencies.is_base`, singular), and one
  set of books.

Why this one matters more than the others: Doc 2 states it as *already true*, and Doc 3's Final Phase
is written on top of it — "Data filtered by the department/function ownership dimension every record
has carried, and by entity (SG/EU), **activated through the RLS hooks already in place**." There are no
hooks to activate. When that phase is planned, the first task is a migration across every business
table, not the activation of something dormant.

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

---

## 3 · Principle 6's approval chains — DOCUMENT AHEAD, and deferred by plan, not dropped

> **Doc 2, Principle 6:** "Every value-bearing action in the system (purchase orders, payments, price
> changes, stock issue, expense claims) passes through an approval chain. … Approval is two-level: the
> requester raises the request and the supervisor approves; above a threshold (e.g. 10k) it escalates to
> CFO approval."

**As built:** approval chains exist **only in HR** — leave requests, medical claims, performance reviews
(`submit_leave_request`, `submit_medical_claim`, `submit_review` / `approve_review`, with a four-eyes
rule on reviews). On the finance and purchasing side there are none: `create_purchase_order` writes
`approval_status = 'approved'` unconditionally, and payments, price changes and stock issue have no
approval step at all.

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
