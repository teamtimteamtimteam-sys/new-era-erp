# 批次审计轨迹(AUDIT-1,2026-09-01)

**一条键在【批次】上的跨模块只读轨迹。** 建于 `HEAD = e2b28bf`(TIDY-1b)之上。
所有【码】均为 2026-09-01 当日线上实测。

> **本文件与 `docs/efficiency-group-scoping.md` 第四节并读。** EFF-0 是勘察,
> 本文件是建成之后的账:**它更正了 EFF-0 的三处计数**,逐条标在下面。

---

## 零 · 它是什么,以及【它不是什么】

| | |
|---|---|
| **是** | 一个批次身上发生过的每一件事,**一条排好序的时间线**,从收货到分录 |
| **不是** | 全局搜索(按【编号】找记录)—— 那件排在 Phase 8 之后,**刻意与本刀分开** |
| **不是** | `traceability_report_data()` 的延长线 —— 那是一份**交给客户的证书** |

**为什么不去接长那个函数(Tim 的 R2)** 它在没有血缘时 `RAISE 'NOTHING_TO_REPORT'`,
函数注释写得很清楚:「不能发一份'来源不详'的报告去糊弄审计」。
**这个拒绝对一份单据是对的,对一条轨迹是错的** —— 审计要的恰恰是
「这个批次身上什么都没发生」这个答案本身。两者合并的后果,是一份寄给客户的
证书开始装内部成本与分录。所以另起两张视图,与它并排,**没有动它一个字**。

---

## 一 · 对 EFF-0 的三处更正

| EFF-0 说 | 【码】实测 |
|---|---|
| 13 张历史/日志表 | **16 张**。EFF-0 漏了 `sales_record_movements`(9 行),并把 `traceability_report_issues` 另算了一处 |
| 冲销那道缝「恢复得了 —— 但要多走一跳」,未说是否需要 schema 改动 | **不需要任何 schema 改动**。`reversed_by` 在线上 **13 对冲销上全部有值**,且 13 对里冲销件的 `source_id` 都等于过账件的 `id` |
| 「一张 union 视图要手写 13 段别名」 | **13 段里只有 10 段够得到批次**;6 张在 schema 上【根本没有路】通向批次。硬凑成 16 支,会多出 6 支永远空的臂 |

**还有一件 EFF-0 与 brief 都没有点到的:** 五张源表有**列级遮蔽**
(`price_history` / `sales_records` / `processing_runs` /
`processing_cost_entry_history` / `inbound_batches` 的金额列被从 `authenticated`
手里收回)。本视图是**属主权限**,会绕过它 —— 所以金额一律不进 `detail`,
由 `data.view_prices` 判,并标 `amount_restricted`。**不是置 NULL**:
`null` 在这套系统里本来就有含义(未分摊/未填/未定价)。

---

## 二 · 16 张表,谁够得到批次

| 表 | 行 | 够到批次 | 经由 |
|---|---|---|---|
| `inventory_movements` | 106 | **直接** | `inbound_batch_id` / `output_batch_id`(两种都带) |
| `price_history` | 14 | **直接** | `inbound_batch_id` |
| `traceability_report_issues` | 1 | **直接** | `output_batch_id` |
| `batch_processing_cost_allocations` | 1 | **直接** | `inbound_batch_id` |
| `sales_records` | 9 | **直接** | `output_batch_id` |
| `processing_cost_entry_history` | 7 | 传递 → **7** | `run_id` → run → inputs/outputs |
| `sales_record_movements` | 9 | 传递 → **9** | `movement_id` → 流水 → 批次 |
| `approval_log` | 8 | 传递 → **10 + 1** | `purchase_order` → 批次;`work_order` → run → 批次 |
| `work_order_history` | 2 | 传递 → **2** | `work_order_id` → run → 批次 |
| `sales_attribution_log` | 1 | 传递 → **1** | `sales_record_id` → 销售 → 批次 |
| `purchase_order_history` | 2 | 结构上通,**今天 0** | `purchase_order_id` / `_line_id`(两条路都是 0) |
| `sales_order_history` | 22 | 结构上通,**今天 0** | `sales_order_line_id` → 销售 → 批次 |
| `quote_history` | 3 | **没有路** | — |
| `task_history` | 16 | **没有路** | — |
| `customer_credit_history` | 1 | **没有路** | — |
| `employment_history` | 3 | **没有路** | — |
| `fx_rate_history` | 0 | **没有路** | — |
| `pricing_formula_history` | 0 | **没有路** | — |

**★ 那 6 张【不建成臂】,而是渲染成一条具名脚注 ★**(Tim 的 A1)
一支永远空的臂在屏幕上读成「这里什么都没发生过」—— 正是 AUD-1 那个**错的好消息**,
故意重建一遍。**而两支今天 0 行的【要建】**:它们在结构上是通的,等有人在
已经收过货的采购单上做一次修订就会亮;省掉它们之后,
「这个批次的采购单从没改过」与「这条路没建」在屏幕上长得一模一样。

---

## 三 · 二十支臂,以及每一支的判据【抄自哪里】

**Tim 的 R4:不新造第二套"谁能看什么"。** 每一支的 `module_code` 一律抄自
那张源表**自己的 SELECT 策略**。实测抄来的,其中四条与直觉相反:

| 表 | 它自己的策略 | 直觉会猜 |
|---|---|---|
| `output_batches` | `module.output.view` | processing ✗ |
| `sales_records` | **`module.finance.view`** | sales ✗ |
| `sales_record_movements` / `sales_attribution_log` | **`module.finance.view`** | sales ✗ |
| `traceability_report_issues` | sales **OR** processing | processing ✗ |

**抄错任何一条,这张属主权限视图就会绕过那张表的 RLS 泄露行。**

---

## 四 · 两层判据,各管一件事(Tim 的 R5)

```
batch_audit_trail_all   无判据基视图 · 【不授权给任何人】
        ↓
batch_audit_trail       security_invoker = off · GRANT SELECT TO authenticated
        ├── 外层 WHERE has_any_permission([8 个模块])   → admission:进不进得来
        └── 逐行 may_view = has_permission(module_code) → 这一段是【内容】还是【「受限」】
```

**为什么不能只用一个 OR 判据** 它只有两种坏法,而两种都不能接受:
* 判据放宽 → 把财务行**泄露**给一个只持 inventory 的读者;
* 判据收紧 → 财务那一段**整段消失**,读起来是「这个批次没有分录」,
  而真相是「你不能看」。**这正是 AUD-1 那个错的好消息**,只是长在模块粒度上。

**受限的行【仍然占着那一行】**,但 `detail` / `source_id` / `source_code` /
`href` / `actor_id` **一律为空** —— 一个说「受限」却把值带出来的视图,
比一个直接泄露的更坏:**它看起来是安全的**。由 fixture 183D 逐列钉住。

### 实测:三个读者,同一个批次(IN-2026-0001,33 行)

| 读者 | 拿到 | 可见 | 受限 | 泄露 |
|---|---|---|---|---|
| `admin` | 33 | 33 | 0 | 0 |
| `finance` | 33 | 31 | 2(`run_input` / `cost_entry_change`) | 0 |
| **只持 `module.inventory.view`** | **33 —— 一行没少** | 10 | **23** | **0** |
| 只持 `module.hr.view`(不沾本轨迹) | **0 —— admission 挡住** | — | — | — |

**最后两行是一对**:进得来的人**一行不少**,进不来的人**拿零行**。
只持 inventory 的读者身上,那 9 笔分录**仍然是 9 行**,写着
「受限 · 需要 module.finance.view」—— **不是一段消失的区块**。

---

## 五 · 十一种接缝,画在【行里】(Tim 的 R3)

> 一份藏起自己接缝的轨迹,比一份把接缝画出来的更坏。

| 接缝 | 意思 | 【码】 |
|---|---|---|
| `no_purchase_order` | 批次不带采购单行,「当初订的是什么」答不了 | 16 个未软删进料批里 **8 个** |
| `actor_unrecorded` | 这一行没记过经办人 | 见第六节 |
| `actor_unresolvable` | 记了,但解析不到任何在册的人 | **13 个 actor 里 12 个** |
| `polymorphic_source` | 分录经 `source_type` 多态解析够到批次 | 全部 77 笔分录 |
| `reversed` | 这笔分录已被冲销,冲销件在下面 | 13 对 |
| `is_reversal` | 这一行**就是**那笔冲销 | 13 对 |
| `run_voided` | 那支加工单后来被冲销 | `PROC-2026-0002` 等 |
| `has_masked_amount` | 金额来自一张有列被遮蔽的表 | 5 张源表 |
| `amount_restricted` | 金额不予显示 —— 读者不持 `data.view_prices` | 按读者现算 |
| `no_policy_admits` | **没有任何行策略接纳这条记录** | 见下 |
| `no_cogs_entry` | 这笔销售不带 COGS 分录 | **9 条销售里 7 条** |

### ★ `no_policy_admits`:一条本刀顺手撞见的、【不属于本刀】的事实 ★

`approval_log` 的 SELECT 策略是一个按 `subject_type` 分支的 `CASE`,
它有 `leave_request` / `medical_claim` / `performance_review` / `purchase_order` /
`payment` / `expense` / `pricing_formula` / `stocktake` 八支,
**没有 `work_order` 这一支** —— 落到 `ELSE false`。
于是线上那 **1 行 work_order 审批,对每一个读者都不可见**。

**本刀不擅自放行**(那会绕过 RLS,而且审批模块是关着的),
也不悄悄省略 —— 它如实渲染成「受限」并标 `no_policy_admits`。
**要不要给它一支策略,是审批那一刀的事。**

---

## 六 · 冲销必须出现(3d),以及【为什么不解析 memo】

**实测的那个错的好消息:**

```
JE-2026-0003  source_type='purchase'  source_id = IN-2026-0001 的 id   status='reversed'
JE-2026-0004  source_type='purchase'  source_id = JE-2026-0003 的 id   memo='REVERSAL: …'
```

一张老老实实 `WHERE source_id = 批次.id` 的轨迹**看得见那笔过账,看不见它的冲销**——
屏幕上这个批次还挂着一笔定价分录,而它已经被冲掉了。

**修法:跟 `reversed_by` 那一跳。** 线上 13 对全部有值,**不需要 schema 改动**。

**绝不解析 memo。** 今天唯一能靠自己认出这层关系的东西是那句英文
`'REVERSAL: …'`,而 memo 是**人打的自由文本** —— 依赖它拼法的轨迹,
会在第一个换个说法的人手上**安静地**坏掉。fixture 181D 造了一对 memo 里
一个 `REVERSAL` 字样都没有的,要求它照样两条都在。

---

## 七 · 「谁做的」今天基本答不上来 —— 本刀只负责【如实渲染】

**这是这一刀里最重要的一个发现,而它【不是本刀能修的】。**
详见 `docs/known-issues.md` 的 `ACTOR-UNRESOLVABLE` 条目。一句话:
**13 个 actor uuid 里只有 1 个(Tim)解析得到人**,其余 12 个连
`auth.users`(共 7 行)里都没有。

本刀的职责只是**把这份答不上来如实说出来**:一律走
`app/components/ActorName.tsx`(它已经把「查得到 / 账号未关联档案 /
未记录 / 受限」分成四句不同的话,并写死了**绝不裸印 uuid**)。
**没有为同一个概念造第二套词汇。**

---

## 八 · 这条轨迹【答不了】什么

| 答不了 | 为什么 | 要动什么才能答 |
|---|---|---|
| 「这个批次现在在哪个库位」 | **库位记在【流水】上,不记在批次上**;106 条流水里 99 条没有库位 | schema:批次持有当前库位,或流水强制填库位 |
| 「这批料当初订的是什么」(一半的批次) | `purchase_order_line_id` 可空,16 个里 8 个空 | 不是 schema 问题,是产线跑起来之后的填写纪律 |
| 「这笔销售的成本进了哪张凭证」(9 分之 7) | `sales_records.cogs_entry_id` 只有 2 条有值 | 结账流程补齐 |
| 「谁做的」(绝大多数) | 见第七节 | 发出同事账号之后重建,**不是 schema 问题** |
| **按编号找任何一条记录** | **刻意不做** —— 那是全局搜索的职责(Tim 的 R1) | Phase 8 之后那一刀 |
| 跨过血缘边、把父批的时间线并进子批 | **刻意不做**(Tim 的 A3)—— 那会让同一张屏幕在不同深度意思不同 | 血缘那一跳作为**一条具名事件**出现,带链接 |

### 要 schema 改动才能修的,只有一件

**库位。** 「这个批次在哪个 bin」在今天的形状下**不可答**,
而且不是填充率问题:库位是**流水的属性**,不是批次的属性。
本刀**没有**动它 —— 点名,留给库位那一刀。

---

## 九 · 入口

* `/inbound/[id]/edit` —— 进料批的单据主页(**`/inbound/[id]` 不存在**)
* `/output/[id]/edit` —— 产出批的单据主页(**`/output/[id]` 不存在**)

两处都排在既有的 `MovementTimeline` **之后**:流水只答库存那一段,
审计轨迹把八个模块串成一条。**两者不合并** —— 流水是一份台账,轨迹是一条叙事。

## 十 · 钉住它的三支 fixture

| # | 钉的是 | 故障注入 |
|---|---|---|
| 181 | 冲销**两条都在** | 造一对少了 `reversed_by` 的 → 冲销必须缺席;造一对 memo 不提冲销的 → 必须照样在 |
| 182 | 三种接缝**标在行里** | 接上采购单行 → `no_purchase_order` 必须消失(证明它不是恒真的) |
| 183 | 受限读者拿到**具名受限**,不是空区块 | 补上 `module.finance.view` → 受限必须消失;并逐列断言受限行**不带任何源表的值** |

**183G 抓到过一个真缺陷:** 前一支迁移的抬头写着「不授权给任何人」,
而 Supabase 在 `public` 上的 DEFAULT PRIVILEGES 让每一张新视图自动带上
`anon` 与 `authenticated` 的全部权限 —— **那句话当时是假的,判据可以被绕过去**。
由 `2026-09-01-audit1-revoke-inner-view.sql` 补上 `REVOKE`。
**一句写在抬头里的断言,不等于一条被执行的规矩。**
