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
| 16 | `metal_quote_stale` | a metal whose **latest quote** is older than `pricing_settings.metal_quote_stale_days` (default **14**). **Keyed on `price_date`, never `created_at`** — back-entry is measured and real (the 25 Jun quotes were entered 2 Jul), and `created_at` would make a back-fill look freshly maintained. `item_id` points at that latest quote row; `item_date = max(price_date)`, so `days_waiting` reads "days since last maintained". **The boundary is `>`, not `>=`** — fixture 30's C arm pins it by pushing a quote to exactly the threshold and requiring the arm to vanish. **The thin-window half is deliberately NOT here** (ASY-3: it changes the number's *meaning*, not its age, and belongs on the pricing panel — two readers, two places) | `module.pricing.view` | `metal_prices` + `pricing_settings` | live quotes only (`deleted_at IS NULL`) |
| 17 | `orders_unfulfilled` | a sales order in `confirmed` or `partially_shipped` — **the goods-still-owed reading**. No scheduling concept is invented: `shipments` has no status column and a shipment row exists only once goods actually moved, so "pending shipment" has no referent in this schema. **Per-order completeness is not computed here** — that is `sales_order_fulfilment_status()`, one derivation, and this repo has paid five times for copying a Σ-vs-Σ | `module.sales.view` | `sales_orders` | live orders only; `item_date = order_date`, verbatim the `po_awaiting_receipt` convention |
| 7c | `safety_stock_below` | material whose **available** stock is under its own `safety_stock_qty`. **NULL threshold never appears** — not monitored is a decision nobody has made, not a threshold of zero, and that silence must never read as "checked and fine" (METAL-1's `no_reference` again). **Held stock does not count**: the threshold asks how much is *usable*, and a hold that hides a shortage would mute the alert at the exact moment it should speak | `module.inventory.view` | `material_stock_available` | materials with a threshold set (opt-in, small) |
| 8 | `leave_pending` | leave request awaiting a decision | `module.hr.view` | `leave_requests` | pending only |
| 9 | `claim_pending` | medical claim submitted, not decided | `module.hr.view` | `medical_claims` | submitted only |
| 10 | `review_submitted` | performance review submitted, awaiting approval | `module.hr.view` | `performance_reviews` | submitted only |
| 11 | `invoice_overdue` | issued invoice past `due_date` with `open_base > 0` | `module.finance.view` | `invoice_status` | non-void invoices |
| 12 | `ar_over_90` | receivable in the **oldest ageing bucket** (`b90_plus`) | `module.finance.view` | `ar_open_items` | open items only; oldest bucket. **SO-3a: AR now has two document kinds** — `doc_kind` is `'sale'` (item_id = sales record → `/finance/receivables/[id]`) or `'invoice'` (item_id = posted order-flow invoice → `/finance/invoices/[id]`); unrecognised kinds get no link, same rule as `ap_over_90` |
| 13 | `ap_over_90` | payable in the oldest ageing bucket (`b90_plus`) | `module.finance.view` | `ap_open_items` | open items only; oldest bucket |
| 14 | `fx_rate_gap` | a day with foreign-currency postings and a missing rate | `module.finance.view` | `fx_rate_gaps` | **`rate_date >= CURRENT_DATE - 45`** |
| 15 | `bank_unmatched` | imported statement line still unmatched | `module.finance.view` | `bank_statement_lines` | statement side only — see below |
| 23 | `free_time_expiring` | free time on an arrived container is down to **2 days or fewer, including negative** (already accruing demurrage) | `module.purchasing.view` **+ `module.finance.view` via `arm_permission_widen`** — 滞港费是钱的事,而录里程碑的人在操作侧 | `containers` × 最晚的那条 `arrived` 里程碑 × `forwarder_rate_quotes.free_days` | 排除软删箱子。**`free_days IS NULL` 一支不响**(报价没写免柜期 ≠ 零个免费天);阈值 **2** 写死 |
| 24 | `container_no_arrival` | 开走 **14 天**,而没有任何 `arrived` 里程碑 | `module.purchasing.view` | `container_milestones` | 排除软删箱子。**这一支是第 23 支的 companion**:没有到港记录时第 23 支永远安静,而安静与"没问题"长得一样 |
| 25 | `container_eta_overdue` | `expected_arrival_date < CURRENT_DATE` 且尚无 `arrived` | `module.purchasing.view` | `containers` | 排除软删箱子。**ETA 为 NULL 时沉默** —— 与 `work_order_overdue` 逐字同形的【已知局限】 |
| 26 | `container_documents_late` | 有 `pending` 单据,且开航已 **7 天** | `module.purchasing.view` | `container_documents` | 排除软删箱子。**从没实例化过清单的箱子沉默**(pending 数为 0)—— 屏幕上由 LOG-5b 的第六句话点名 |
| 27 | `equipment_service_due` | 一台机器的一条保养间隔【到了】—— 距上一次那一种保养的公斤数或天数,**任一个**达到它自己的间隔 | `module.processing.view` **+ `module.finance.view` via `arm_permission_widen`** —— 机器卡在财务、干活的人在加工,而底下每一张表/视图的读者本来就是这两个码的 OR | `equipment_service_status`(读 `equipment_service_intervals` × `equipment_maintenance` × `processing_runs`) | **间隔是自愿配的**,所以扫描量跟着【间隔行数】走,不跟机器数走 —— 未监控的机器不触发那两个 LATERAL。与 `safety_stock_below` / `credit_over_limit` 同一条 opt-in 的界。`disposition = 'ignore'` 与已处置的机器都不上牌 |
| 28 | `equipment_service_approaching` | 同一条间隔【快到了】—— 达到 `interval − lead`,但**还没**到期 | 同上 | 同上 | 同上。**与第 27 支互斥**:`is_approaching` 自带 `AND NOT is_due`,所以一台到期的机器不会同时出现在两支里(同一件事数两遍,正是 fixture 30 那句话要抓的东西) |



### 保养那两支:为什么是【两支】,而它们的提前量为什么不在一张类型表上(EQP-2c,2026-08-21)

**两支而不是一支带等级。** `operations_now` 的九列契约里没有"严重程度"这一列,
所以唯一在【结构上】分得开"到期"与"将到期"的办法就是两个 `item_type` ——
一支带一个文字等级,在任何按支计数的地方都会重新塌回一个不分轻重的告警。
同形先例:`qualification_expiring` / `qualification_missing`,
`container_no_arrival` / `container_eta_overdue`。

**提前量(`lead_kg` / `lead_days`)与后果(`disposition`)落在【间隔行】上,
不落在一张按 `kind` 的类型表上** —— 这是对 `certificate_types` 形状的一处刻意偏离,
两条理由:

1. `kind` 的域【已经】写在 `equipment_maintenance.kind` 那条 CHECK 上。再建一张按
   `kind` 的目录表,就是同一个域的第二份定义 —— 本仓库为"两份定义必然漂开"付过很多次账。
2. **一个固定的提前量服务不了两个量级的间隔。** 500 公斤的间隔与 50,000 公斤的间隔,
   "提前 1,000 公斤"分别是【永远亮着】与【几乎不亮】。间隔行本来就是这件事最细的
   配置粒度,提前量跟它走才对得上。

`certificate_types` 真正要的东西一个没丢:**提前量是行,后果也是行**,改一行数据
就改行为,fixture 111 的 F6 在同一笔事务里两个方向都验过。

**`disposition` 只有 `warn` / `ignore`,没有 `block`。** `certificate_types` 的 `block`
是有人兑现的(收货闸门读它);EQP-2c 什么都不拦,一个没有任何地方兑现的枚举值只会是
一句谎。**返回条件:哪天有一道门要按"保养逾期"拦住什么,连同那道门一起把它加进来。**

**三个状态,别压成两个。** 没有间隔行 = 【未监控】(没人决定要盯它);
`disposition='ignore'` = 【盯着,不吵】;`warn` = 上看板。用删行去关灯会把前两者混掉。
未监控的机器在 `equipment_service_status` 里【仍然有一行】,每个量度都是 **NULL**,
**绝不是 `false`** —— fixture 111 的 F4 正面钉住这一条。

**牌子在 EQP-2d。** 这一刀落的是两支的【行】与 `dashboard.item.*` 那两个键
(后者是被迫同刀:check-i18n 的后缀集合现读 `db/views/operations_now.sql` 的
`item_type` 字面量,少了键 `npm run build` 当场红)。首页的两块牌子、机器页上的
那一块、以及配间隔的表单,都在 2d。

### 物流四支的【补救在哪一页】(LOG-5b,2026-08-20)

**四支的门牌全部指向 `/logistics/containers/[id]`,而且补救确实都在那一页上** ——
这是这张表要求每一支回答的那个问题,四支的答案一致:

| 支 | 补救动作 | 在那一页上? |
|---|---|---|
| `free_time_expiring` | 录到港里程碑 / 修正到港日 / 把免柜天数写进报价 | **是**(里程碑面板;报价在 `/logistics/forwarders/[id]`,箱子页把它的状态说出来) |
| `container_no_arrival` | 录一条 `arrived` | **是**(里程碑面板) |
| `container_eta_overdue` | 录到港,或撤回/更新 ETA | **是**(头部的预计到达可改、可清空) |
| `container_documents_late` | 实例化清单 / 把单据标为已收或不适用 | **是**(单据面板) |

**唯一不完全在那一页上的是免柜天数本身**:`forwarder_rate_quotes.free_days` 编辑在
货代那一页。箱子页因此【说出它是哪一种缺】(报价没写免柜期 / 这条航段没有有效报价 /
箱子没有货代),而不是留白 —— 那三句话就是通往正确那一页的指路。

**三个阈值 2 / 14 / 7 全部写死(v1,Tim 定)。** 要可调时抄
`certificate_types.warn_lead_days`:一张 RUNTIME CONFIG 表,每类自带提前期【和】后果
(block / warn / ignore),"加一种是编辑一行,不是跑一次迁移"。

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

## The fourth property: a destination (LINKS-1, 2026-08-11)

Until LINKS-1 every arm pointed at a **list**. The tile said "3 batches awaiting assay" and
the click landed you on all the batches, to find the three yourself — the count was right and
*which ones* was thrown away. So every arm now carries `item_id`, and the page links each
waiting item to its own page.

> **Adding an arm means naming its destination in the table below, in the same commit** —
> the same rule as adding its row at all. An arm with no declared destination is an arm whose
> link nobody chose.

### The test: does the remedy live on that page?

**The URL's name is not the signal.** This is worth stating flatly because the obvious
category — "is it an edit form?" — classifies by URL and gets the answer wrong in both
directions:

* `/inbound/[id]/edit` and `/output/[id]/edit` are **document hubs**, not forms. They carry
  assays, pricing, prepayments, the movement timeline, the sale panel. Sending someone there
  is sending them to the batch.
* `/suppliers/[id]/edit` is close to a plain form — and it is a **right** destination anyway,
  because it carries `CompliancePanel`, and renewing the certificate is exactly what the
  qualification arms are waiting for.

So the question is never what the route is called. It is: **can the person do, on that page,
the thing that makes this row go away — and does doing it change the fact rather than the
signal?**

### Two tests, not one — conflating them is what produced the URL version

1. **The remedy being on the page is what justifies the link.** That is the whole test for
   whether an arm gets a row destination.
2. **A signal-clearing control also being on the page is a hazard to NAME, not a reason to
   withhold the link.** Naming it is the mitigation; withholding the link costs the remedy too.

`output_unsold_aging` is the case that separates them. `/output/[id]/edit` carries SalePanel,
which renders precisely when `remaining_qty > 0` — the arm's own predicate — so the remedy is
guaranteed present for every row the arm emits. **The same page can also edit `output_date`,
and moving that date makes the tile go quiet while not one kilogram has moved.** That is the
credit-limit shape (raise the limit, the alarm stops, the exposure is untouched) — but the
credit *edit form* carries no remedy at all, which is why `credit_over_limit` points at the
read-only position page `/customers/[id]` instead. Here the remedy is on the page and merely
sits beside a wrong button. A reader who understands why the link exists will not reach for
that field.

### What `item_id` names

> **`item_id` names the row whose page carries the remedy.**

That is the waiting row in seventeen arms, and its **parent** in two:

| arm | waiting row | `item_id` | why the parent |
|---|---|---|---|
| `bank_unmatched` | an unmatched statement **line** | the **statement** | a line has no page; matching happens in the reconcile workbench. `reconcile_statement` raises `LINES_OUTSTANDING` while any line is unmatched, so a statement this arm emits is always `open` and the link never lands on a read-only document |
| `margin_cost_not_allocated` | a sold output **batch** | the **run** | the remedy is allocating the run's costs, and `AllocateButton` is on the run page |

**Where it is the parent, several rows can share one `item_id`, and that is correct rather
than a duplicate** — two unmatched lines on one statement are two waiting things with one
door. This is exactly why fixture 47 cannot assert one id per row, and cannot assert
distinctness. It asserts that `item_id` resolves to a row **of the expected table for that
arm** — an employee id where a review id belongs fails it; a shared parent does not.

Note also that two arms' `item_code` names a **neighbour** by design, so code and id are not
the same row and must not be asserted to be: `review_submitted` shows the *employee* code
(reviews have no `code` column), and `bank_unmatched` shows the *bank account* code.

### `doc_kind` is disclosure, not accommodation

Accounts payable genuinely has two document kinds. `ap_open_items` has branched on `doc_kind`
per row since it was written, and `/finance/payables` draws its links that way. `operations_now`
simply was not saying so out loud; it does now. The column is NULL for the eighteen arms whose
subject has one kind. **An unrecognised kind gets no link at all** — never a guessed route,
because a valid uuid pointed at the wrong table opens someone else's document without erroring.

### The destinations

| arm | destination | why |
|---|---|---|
| `awaiting_assay` | `/inbound/[id]/edit` | AssaySection → record an assay |
| `assay_unapplied` | `/inbound/[id]/edit` | AssaySection links the unapplied assay |
| `batch_unpriced` | `/inbound/[id]/edit` | PricingPanel |
| `allocation_stale` | `/processing/[id]` | AllocateButton |
| `po_awaiting_receipt` | `/purchasing/orders/[id]` | the order document |
| `stocktake_open` | `/stocktakes/[id]` | the count screen |
| `qualification_expiring` | `/suppliers/[id]/edit` | CompliancePanel — renewal changes the fact |
| `qualification_missing` | `/suppliers/[id]/edit` | same panel, first certificate |
| `credit_over_limit` | `/customers/[id]` | the read-only position. **Not** `/edit`: raising the limit clears the light and moves no exposure |
| `output_unsold_aging` | `/output/[id]/edit` | SalePanel. Hazard named above |
| `leave_pending` | `/hr/leave/[id]` | the decision |
| `claim_pending` | `/hr/claims/[id]` | the decision |
| `review_submitted` | `/hr/reviews/[id]` | the approval. `item_code` is the employee's |
| `invoice_overdue` | `/finance/invoices/[id]` | the invoice |
| `ar_over_90` | `/finance/receivables/[saleId]` | the AR document — whose number *is* the output batch code, by design |
| `ap_over_90` | `/finance/payables/[id]` or `/finance/expenses/[id]` | by `doc_kind`; unknown kind → no link |
| `fx_rate_gap` | `/finance/fx?currency=<ccy>` | **no row exists** — the subject is a missing rate. An honestly-filtered list, which is not the same thing as a code search |
| `bank_unmatched` | `/finance/bank/statements/[id]/reconcile` | where matching happens |
| `margin_cost_not_allocated` | `/processing/[runId]` | where allocation happens |

### One mechanism, not two

The link is built from `item_id`. **It is never a search by `item_code`.** Searching by code
works today only because codes happen to be unique and the data happens to be small — and it
translates "open this row" into "look for rows that resemble this one", which are different
answers on the day either of those stops holding. `fx_rate_gap` is not an exception to this:
it filters a list by a currency column, which is a filter, not a search for a code.

## Considered and left out — with the reason, so they are not silently re-proposed

| candidate | why not |
|---|---|
| **Batch margin** | **WITHDRAWN as an arm (EXEC-3a verdict).** A low margin on a sold batch is a **state, not a to-do**: there is no clearing action — you cannot "handle" a margin that has already happened, so the tile could never go out. `operations_now` holds things waiting for someone to act (its name says so); the margin's home is `/margin`. **The actionable half is already an arm**: #15 `margin_cost_not_allocated` — cost not allocated, and allocating is a real action that turns the light off. The open design questions (which qualifiers travel with the number; posted COGS vs current cost) belong to `/margin`'s own cut, not to a dashboard arm. Predicate, if ever needed elsewhere: `AGENTS.md` standing decision 2. |
| **The seven month-end signals** | `/finance/month-end` is their hub and states their true dependency order. Copying them here would be a second implementation of a sequence whose whole value is being ordered correctly. The dashboard links to it instead. |
| **`hr_alerts` contents** | Already a view with its own screen and its own severity model. The dashboard shows its **count** as one tile and links out; it does not re-derive the arms. |
| **Full bank reconciliation difference** | Requires the ledger-side whole-table scan. See the bound above. |
| ~~**Stale metal quotes (ASY-3)**~~ | **BUILT — EXEC-1a, 2026-08-16.** Arm 16 above. The threshold landed as `pricing_settings.metal_quote_stale_days` exactly where METAL-1 left room for it; the thin-window half stays queued for the pricing panel (EXEC-1b). |
| ~~**Supplier / company qualification expiry (CMP-1)**~~ | **BUILT — CMP-2 already shipped both arms** (`qualification_expiring`, `qualification_missing`), with `warn_lead_days` per certificate type and **no −30-day floor** (fixture 37C pins the 730-days-expired case). **This row said "Candidate, not built — gated on the A3 decision" until 2026-08-16, and that was stale**: EXEC-3a trusted it and added two DUPLICATE branches to `operations_now`. The duplicates were caught the same hour — by fixture 37C (one supplier, 2 rows instead of 1) and fixture 30A (25 rows instead of 21), i.e. by exactly the "某支把同一件事数了两遍" message fixture 30 carries for this purpose — and removed in `exec3a-fu1`. **A stale spec costs the same as a wrong one.** A3 itself is also settled and shipped: its conclusion was per-`cert_type` disposition (block/warn/ignore), which CMP-2 built, along with `supplier_receiving_blocked` gating receipt. |
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


---

## margin_cost_not_allocated(MAR-1,2026-08-10)

| | |
|---|---|
| 含义 | 已售出、但所属加工单的成本【尚未分摊】的产出批 —— 毛利因此算不出来 |
| 权限 | `data.view_prices` **且**(`module.finance.view` **或** `module.processing.view`) |
| 门 | `/margin` |
| 界 | `batch_margin.margin_status = 'no_unit_cost'` |
| 线上 | 3 批(收入 10,573) |

**这是第一支需要【谓词】而不是【一个码】的支。** 收入在财务、分摊成本在加工,
而除 admin / auditor / gm 外没有任何 live 角色同时持有两个模块。视图因此多了一列
`permission_any`(任意持有其一),由 `arm_permission_any(item_type)` 一处声明,
SELECT 与 WHERE 共用;首页 TILES 的 `permissionAny` 与它同义,fixture 45 钉住
两侧对同一个人给出同一个答案。

**被排除的:`no_run`。** 那种批次压根不是加工单产出的,事后无从补救 ——
放上看板就是一盏关不掉的灯(与 `awaiting_assay` 对已投产批次、REC-1 对未化验投入
是同一条教训)。它仍然作为一行留在 `/margin` 上,那是它该在的地方。

**被排除的:合成一个新权限码**(如 `report.margin.view`)。它会在权限目录里多出
一条没人授过的条目,日后读起来像一条真的权限;更要命的是它会成为"谁能看毛利"的
第二份定义,与 `batch_margin` 自己的谓词必然漂开。理由写在
`db/migrations/2026-08-10-mar1-arm-level-predicate.sql` 的文件头。

## 工单的两个候选支(WO-1c 记,2026-08-16,**未建**)

WO-1b 的 `work_order_fulfilment` 让这两个数第一次算得出来,但**这一刀没有建任何仪表盘支** ——
记在这里是为了让"没建"是一个决定,而不是一次遗漏。

| 候选 | 含义 | 权限 | 数据源 | 需要先回答的问题 |
|---|---|---|---|---|
| ~~`work_order_overdue`~~ **BUILT(EXEC-3a)** | `status = 'released'` 且 `scheduled_date < CURRENT_DATE` 的工单 | `module.processing.view`(数据自己的 RLS,OPS-15 那条) | `work_orders` | **排产日可以为空**,而空【不是逾期】—— 它是"没排期"。一个 `COALESCE(scheduled_date, ...)` 会把没排期的全部报成逾期或全部漏掉,两种都错。这一支必须显式 `scheduled_date IS NOT NULL`,并且要想清楚:一张放行了三个月、从没排过期的工单,该不该有别的支去管它? |
| ~~`work_order_variance_beyond`~~ **BUILT(EXEC-3a)** | 差异超过某个阈值的工单 | 同上 | `work_order_fulfilment` | **阈值从哪来?** 这个库里没有任何配置项承载它,而写死一个百分比等于替所有人做了一个"多少算多"的判断(与 FIN-36 的分摊基准同一条)。它需要 `finance_settings` / 一张新配置表里的一个显式值,以及 Tim 对"投入超耗"与"产出短交"是否用同一个阈值的一句话 —— 它们是两种不同的坏消息。 |

**EXEC-3a(2026-08-16)把这两支建了。** 阈值落在 `processing_settings` 的【两列】
(`wo_input_overrun_pct` / `wo_output_shortfall_pct`)—— 上面那个"是否用同一个阈值"
的问题,答案是【不是】:投入超耗是成本问题、产出短交是收率问题。触发时机也不同 ——
超耗在【放行中】的单上就报(它发生那一刻就可处理),短交【只报收了工的】
(收工之前"少"只是"还没做完")。没记录预期的行永远不报。fixture 79 逐条钉住。
**排产日为空仍然【不是】逾期,而"放行了很久、从没排过期"那个子问题仍然开着** ——
它没有被这一刀回答,留在下面。

**代码要改的地方:`app/page.tsx` 的 `TILES` 数组**(与批次毛利那一条同一处),
外加各自的谓词。两支都读单模块的数据,所以不涉及 `xmodule` 那一类问题。

---

## 读者是谁 —— 见 `docs/exec-views-plan.md`(EXEC-0b,2026-08-16)

这份清单回答"有哪些支、各自读什么、权限是什么"。**它不回答"谁需要看哪一支"** ——
那个问题的答案在 `docs/exec-views-plan.md`:四个人的职责锚点、十二个数的归类,
以及三条已定的判词(高管视图 = **四个授权包 + 臂级谓词**,不新建模块也不新增权限码;
两处权限颗粒度**现在都不拆**、触发条件已写下;客户审计报告是**签发档族的单据**)。

**那份文件【引用】本文件的支规格,不复制它们。** 加一支新臂时,规格写在这里;
它属于谁的第一屏,写在那里。
