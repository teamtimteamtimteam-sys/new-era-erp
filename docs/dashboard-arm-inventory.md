# The dashboard's arm inventory — the specification for `operations_now`

**This file exists because the Phase 6 scoping report lived only in a conversation, and four
arms were lost between scoping it and building it (OPS-18 → OPS-19).** That is the same defect
as the planning documents not being in the repo: a decision nobody can read is a decision that
gets re-made, badly. The rule that follows from it:

> **Adding an arm to `operations_now` means adding a row to the table below in the same commit.**
> The next person is extending a list, not guessing at one. Removing an arm means moving its row
> to "Considered and left out" with a reason — never deleting it, because the reason it was
> dropped is the thing that stops it being re-proposed.

`operations_now` answers exactly one question: **what is waiting for a human right now.** One row
per waiting item, one arm per waiting state, `hr_alerts`' proven shape. It is not a metrics view,
not a report, and not a place for totals — a number that is merely *interesting* belongs on the
module's own page.

## The three properties every arm must have

1. **A waiting state, not a status.** The condition must describe something a person can act on
   and then clear. `status = 'draft'` is someone still typing; `status = 'confirmed'` with no
   receipt is a queue. If nothing a human does can make the row go away, it is not an arm.
2. **A module permission it declares.** Each arm carries its own `permission` column and the
   view's single outer `WHERE has_permission(a.permission)` enforces it. An arm the reader
   cannot see is **absent**, never zero (OPS-14 remedy (a)). The page turns absence into 「受限」
   by checking the *same* code — the two must agree, which is why the code is written in both
   places and asserted by fixture 30.
3. **A bound, or a written reason it needs none.** This view is read on the page everyone lands
   on. An unbounded scan here is paid for by every user on every visit.

## The arms

| # | `item_type` | means | permission | source | bound |
|---|---|---|---|---|---|
| 1 | `awaiting_assay` | in-register inbound batch with **no assay at all** (`assay_count = 0`) | `module.inbound.view` | `batch_assay_status` | open batches only (soft-deleted excluded by source) |
| 2 | `assay_unapplied` | assay recorded but **not yet applied** to the batch (`has_unapplied_assay`) | `module.inbound.view` | `batch_assay_status` | as above |
| 3 | `batch_unpriced` | `pricing_status = 'unpriced'` — **money not yet recognised**; the batch is in the yard and its cost is not on the books | `module.inbound.view` | `batch_assay_status` | as above |
| 4 | `allocation_stale` | run allocated before its costs last moved, **or** costs exist and it was never allocated | `module.processing.view` | `processing_run_allocation_status` | live runs only |
| 5 | `po_awaiting_receipt` | PO `confirmed`/`receiving` — goods owed to us. `draft` is deliberately **not** here | `module.purchasing.view` | `purchase_orders` | open statuses only |
| 6 | `stocktake_open` | a count started and not posted or cancelled | `module.stocktakes.view` | `stocktakes` | open only |
| 7 | `output_unsold_aging` | finished output with `remaining_qty > 0` sitting **≥ 60 days** | `module.output.view` | `output_batches` | the 60-day threshold **is** the bound |
| 7b | `credit_over_limit` | customer with a limit set whose AR exposure ≥ limit (SAL-B). NULL-limit customers never appear — no limit set is not over limit. `credit_hold` deliberately not an arm: a hold is a decision someone made, not a thing waiting | `module.customers.view` | `customers` + `customer_ar_exposure_base()` | customers with a limit set (opt-in, small) |
| 8 | `leave_pending` | leave request awaiting a decision | `module.hr.view` | `leave_requests` | pending only |
| 9 | `claim_pending` | medical claim submitted, not decided | `module.hr.view` | `medical_claims` | submitted only |
| 10 | `review_submitted` | performance review submitted, awaiting approval | `module.hr.view` | `performance_reviews` | submitted only |
| 11 | `invoice_overdue` | issued invoice past `due_date` with `open_base > 0` | `module.finance.view` | `invoice_status` | non-void invoices |
| 12 | `ar_over_90` | receivable in the **oldest ageing bucket** (`b90_plus`) | `module.finance.view` | `ar_open_items` | open items only; oldest bucket |
| 13 | `ap_over_90` | payable in the oldest ageing bucket (`b90_plus`) | `module.finance.view` | `ap_open_items` | open items only; oldest bucket |
| 14 | `fx_rate_gap` | a day with foreign-currency postings and a missing rate | `module.finance.view` | `fx_rate_gaps` | **`rate_date >= CURRENT_DATE - 45`** |
| 15 | `bank_unmatched` | imported statement line still unmatched | `module.finance.view` | `bank_statement_lines` | statement side only — see below |

### The two bounds that were argued rather than assumed

* **`fx_rate_gap` — 45 days.** `fx_rate_gaps` runs `fx_rate_asof` per `(date, currency)` group and
  is unbounded by period; over years of postings that is a growing scan on the busiest page in the
  system. The dashboard answers *"has anything been missed lately"*; the complete history belongs
  to `/finance/month-end`, which walks it a month at a time. The predicate sits on the grouping key
  so it pushes down into the aggregate.
* **`bank_unmatched` — statement side only.** This arm counts `bank_statement_lines`, whose row
  count is bounded by import volume. It deliberately does **not** read
  `bank_reconciliation_status`, whose ledger-side `LATERAL`s scan `journal_lines` whole. That is
  the reconciliation page's work, not the home page's.

### `output_unsold_aging`: 60 days is a PROPOSAL, and here is the evidence

The threshold is the whole arm — *"an age that makes every batch an alert is the same as no
alert."* Measured against live on 2026-08-09, seven output batches have `remaining_qty > 0`,
aged 4 · 5 · 37 · 45 · 58 · 60 · 60 days:

| threshold | batches flagged | reading |
|---|---|---|
| 30 days | 5 of 7 (71%) | most of the yard is an alert — indistinguishable from no filter |
| 45 days | 4 of 7 (57%) | still a majority |
| **60 days** | **2 of 7 (29%)** | **proposed** — surfaces the genuinely stalled batches only |
| 90 days | 0 of 7 | permanently dark on current data; nothing to act on, so nobody would trust the tile |

60 is one constant in one arm; changing it is a one-line migration. It is chosen to *discriminate*,
not because 60 is a business rule — **if Tim has a real ageing policy for finished goods, that
number wins over this one.** Recorded as a proposal rather than presented as a decision.

### `credit_over_limit`: one arm, not two — "approaching" reported and not built (SAL-B §6)

An "approaching limit" second arm needs a threshold percentage (80%? 90%?), and that number would
be a constant nobody sees — FIN-36's schema-default lesson in dashboard form. One arm at the hard
boundary is honest; if Tim wants an early warning, the percentage belongs in configuration
(`certificate_types`-style, visible and editable), and THEN a second arm earns its place. Recorded
here so the next person extends deliberately rather than hardcoding 80.

## Considered and left out — with the reason, so they are not silently re-proposed

| candidate | why not |
|---|---|
| **Batch margin** | Open design questions: which qualifiers travel with the number, and posted COGS versus current cost. It gets its own cut; the predicate is already fixed in `AGENTS.md` standing decision 2 (owner rights, `data.view_prices AND (module.finance.view OR module.processing.view)`). The `TILES` array in `app/page.tsx` is where it will slot in. |
| **The seven month-end signals** | `/finance/month-end` is their hub and states their true dependency order. Copying them here would be a second implementation of a sequence whose whole value is being ordered correctly. The dashboard links to it instead. |
| **`hr_alerts` contents** | Already a view with its own screen and its own severity model. The dashboard shows its **count** as one tile and links out; it does not re-derive the arms. |
| **Full bank reconciliation difference** | Requires the ledger-side whole-table scan. See the bound above. |
| **Supplier / company qualification expiry (CMP-1)** | **Candidate, not built — gated on the A3 decision in `docs/compliance-scoping.md`.** Two arms when it lands: `qualification_expiring` (window + escalation, the `work_pass_expiry` shape but with NO −30-day floor for blocking instruments — live already has a certificate 2.5 years expired that a floored alert would have silently dropped) and `qualification_missing` (absence, the `holiday_calendar_missing` shape — "this supplier has no Basel certificate at all"). Permission `module.suppliers.view`: the data's own RLS (OPS-15's rule), and procurement — who chases the renewal — holds it. NOT a new compliance module for one arm; if Phase 5 builds one, this line is where the code changes. |
| **An AR/invoice arm as the `sales` role's tile** | Does not work: `sales` does not hold `module.finance.view`, so an AR arm renders 「受限」 for exactly the role it was meant to serve. This mistake was made once (OPS-18's report) and is recorded so it is not made twice. `output_unsold_aging` is the arm that actually reaches `sales`. |

## Two hazards a reader of this view must know

**1 · Absence is a permission answer, so the page must never render it as `0`.** The view emits
nothing for an arm the reader cannot see. On screen, `0` and "you cannot see this" are the same
pixels — the identical disease `moduleGuard` exists to cure, one level down. `app/page.tsx`
therefore checks the module permission **before** rendering each tile and shows 「受限」
(`common.restricted`), and a restricted tile opens **no door at all**: never try one source and
fall back to another when it comes back empty, because here an empty set *is* the answer.
Fixture 30 arm B asserts this with all other arms' conditions deliberately true, so absence can
only come from permission.

**2 · The three finance arms rest on price-masked columns — a LATENT under-report.** `ap_over_90`,
`ar_over_90` and `invoice_overdue` read `ap_open_items` / `ar_open_items` / `invoice_status`, whose
row *existence* is filtered on amounts derived from `inbound_batches_masked.unit_price`,
`sales_records_masked.unit_price` and `invoices_masked.total_base` — all masked by
`data.view_prices`. A reader holding `module.finance.view` **without** `data.view_prices` would see
those rows silently vanish and the tile under-report rather than say 「受限」.

**Not reachable on any live role today, and measured rather than assumed (2026-08-09):** every role
holding `module.finance.view` also holds `data.view_prices` (admin, auditor, finance, gm) — which is
`AGENTS.md` standing decision 1 working as intended. The hazard is recorded because the two codes
are granted separately and nothing enforces the pairing. **If a finance role is ever created without
`data.view_prices`, these three arms need their declared permission revisited** — and note the
naive fix is wrong: declaring `data.view_prices` as the arm's permission would show `procurement`
and `sales` (who hold prices but not finance) a `0` that means "you cannot see AP at all".

---

## Reported, not built: the approvals tile while the flag is off (APR-2c)

**A tile counting "orders awaiting approval" reads `0` when approvals are switched off — and that
`0` means "not in force", not "none waiting".** That is the restricted-is-not-zero defect in a
fourth costume, and this file's §"two hazards" already names the first three:

| costume | what `0` / absence really meant |
|---|---|
| OPS-15 | a module you cannot enter renders an empty table |
| OPS-18 | an arm you cannot see contributes no rows, so the tile shows 0 |
| OPS-20 | a margin with no cost basis prints 100%, or would print 0 if COALESCEd |
| **APR-2c** | **a queue that does not exist because the control is switched off** |

**The recommendation, for whoever adds the arm:**

* **Do not add an `approval_pending` arm that is silently empty while the flag is off.** It would be
  correct-by-accident (there genuinely are no pending orders) and wrong-by-meaning (there is no
  approval step at all).
* The tile needs the **same three states the engine has**, not two:
  * **off** → render the tile as **not in force** — the `受限` treatment's sibling, distinct in
    wording (`受限` means *you* cannot see it; this means *nobody* is being asked). A separate
    string, not a reused one, for the reason FIN-35 gives: the identity of a multiplier is
    invisible, and so is a zero that means something else.
  * **on, policy unset** → render as **misconfigured**, because that is what it is. This state
    refuses at the database, so an operator seeing `0` here would be seeing a control that is
    enabled and inert.
  * **on, policy set** → the ordinary count, with `0` finally meaning zero.
* The arm's `permission` is `module.purchasing.view`, which `procurement` holds — so the requester
  sees their own queue depth. That is the point of the tile.

**Why it is not built in APR-2c:** the flag is off, so every state but the first is unreachable
today, and an arm whose only observable behaviour is "not in force" cannot be shown to
discriminate — the standard `db/fixtures/34` established for a third allocation basis. It belongs
in the cut that turns approvals on, alongside the delegation and HR four-eyes work, all three of
which are gated on the same decision.


---

## awaiting_assay 的两处缺口(REC-1 复核,2026-08-10)—— 记录,本刀不动

Tim 在 REC-1 里问:预防那一半是不是已经由 `awaiting_assay` 覆盖了?复核结论是
**覆盖了主干,但有两处缺口**,而且其中一处正是"关不掉的灯"那个病 —— 所以更要
先写下来再决定,不能顺手改。

该支的谓词是 `batch_assay_status.assay_count = 0`,对每个未软删的进料批成立。

**缺口一(已经在发生):它不排除【已经投产】的批次。** `IN-2026-0011` 与
`IN-2026-0153` 都是零化验、零金属行,而且**都已被已提交的加工单消耗掉**,
`remaining_qty` 已经是 0。它们此刻挂在牌上,而**没有任何操作能让它们落牌** ——
货已经处理完了,补化验无从谈起。这正是 OPS-14 记的 `hr_alerts` 那盏常亮灯的形状,
只是换了个地方,而且是**本来就存在的**,不是 REC-1 加进去的。
可能的修法(留待决定):谓词加上"尚未被任何已提交加工单消耗"或 `remaining_qty > 0`。
**没有在 REC-1 里顺手改**,因为改看板支的含义要连着这份清单一起改,而它值得
自己的一刀与自己的 fixture。

**缺口二:它是【每批】而不是【每金属】。** 一个批次只要有过任何一张化验单,
`assay_count > 0`,这支就不再报它 —— 哪怕那张化验只测了一个金属。走查那一单正是
这种:`IN-2026-0001` 有一张只测了 cu 的化验,钴从未被测过,而该支对此完全无感。
要覆盖它就得回答"一张化验单该测哪些金属"——那是化验政策问题,不是看板问题
(Doc 1 在"产出侧测什么指标"上同样是空白,见 as-built-divergences.md)。

**结论**:REC-1 不加任何看板支。投产之后无从补救的事实只写在单据上;
预防的时刻归 `awaiting_assay`,而它的这两处缺口按上面记录,各自等一刀。
