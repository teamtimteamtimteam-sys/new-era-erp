# SEARCH-5 停止闸 —— 可点击的关联分组(**勘察,没有写一行代码**)

> **一句话:** 这一刀要造的那个地址,**形状是小的** —— 33 条列表路由里 **32 条**
> 已经走同一对共享组件(`<ListPage>` + `<DataTable>`),所以共享页是**复用**,
> 不是**重写**。而委托书里「39 个列表页」这句话**是假的**:**6 种单据今天
> 根本没有任何列表页**,另有 1 种的列表在它登记路由之外 —— 也就是说
> Tim 否掉的那个选项 (a)「教 39 个列表页加一个筛子」,对其中 7 种
> **按构造做不到**:你没法给一个不存在的页面加筛子。
>
> ★ 而**为分页定价的那个数被重量出来是另一个数**:委托书引的「最多 30 条关联行」
> 是**一条命中所有分组加起来**的 30;**一个分组自己最多是 11** —— 而后者才是
> 这一页要装的东西。

---

## 1 · 开工闸(§1.1)

| # | 判据 | 读数 |
|---|---|---|
| 1 | `git status --porcelain` | **空** |
| 2 | 本地 HEAD == `origin/main` == `git ls-remote origin main` | 三者同为 **`45f33c5d15ea179dba155df03f7bb16a7d14386c`** ✓ 且等于委托书点名的 `45f33c5…` |

`git log -1` 确认它就是 SEARCH-4 那一刀(`2026-09-14 01:20:08 +0800`)。

---

## 2 · ★ 委托书里的每一个数,当场重量一遍(§1.2)—— **包括量下来是对的那些**

**量法一律写在旁边;没有量法的数,下一刀重量不起来。**

| 委托书说的 | 实测 | 判 |
|---|--:|---|
| HEAD == origin == ls-remote == `45f33c5…` | 三个 40 字符 SHA 逐字相同 | ★ **CONFIRMED** |
| **39** 张登记的单据表 | **39** 张不同 `table_name` · **40** 个 key · **33** 条不同 route(`document_types` 线上现读) | ★ **CONFIRMED** |
| ★ 「**39 个列表页**」/「39 个筛子」 | ★★ **WRONG** —— 不存在 39 个列表页。**33 条 route**,其中 **32 条**渲染一张表;★ **6 种单据没有任何列表页**;另 1 种(`expense_claim`)的列表在**它登记路由之外**。见 §4.1 | ⚠ **WRONG —— 而它把裁定的理由变得更硬,不是更软** |
| 「搜 NMC 显示 **Output batches 10**」 | `MAT-2026-0001` = **NMC Cathode Foil**;`search_related('material', …)` 现读:**output_batch 10** · inbound_batch 9 · sales_order 4 · purchase_order 3 · quote 2 · pricing_formula 1 · work_order 1 | ★ **CONFIRMED,逐字** |
| 「SEARCH-4 measured **max 30** related rows today」 | **30 是【一条命中所有分组加起来】的行数**(`MAT-2026-0001`,7 组 30 行);★ **一个分组自己最多 11**(`supplier → inbound_batch`) | ⚠ **CONFIRMED,而它【数的东西和它的名字对不上】**,见 §2.1 |
| 「several relations are structurally unbounded」 | ★ **140 / 178** 条有向表对含至少一条无界边(`in` 65 + `bridge` 124;只有 **38** 对全是 `out` 因而 ≤1 行) | ★ **CONFIRMED,而「several」严重低估** |
| 一条命中最多 **7** 组 | **7**(`MAT-2026-0001` / `MAT-2026-0002`) | ★ **CONFIRMED** |
| 组数中位数 **1** | **1**(分母 = 全部 325 行单据,含 72 行零分组);**只看有分组的那些是 2** | ★ **CONFIRMED —— 而两个数的分母不同,并排报** |
| **397** 条外键 | **397**(`pg_constraint contype='f'`,public) | ★ **CONFIRMED** |
| **89** 组单据↔单据 | **178** 条有向表对 = **89** 组无向;`document_relations` **254** 条边 | ★ **CONFIRMED** |
| SEARCH-1 的过程底价 **88 分钟** | `docs/handbacks/SEARCH-1.md:38` 与 `:463` 逐字写着 **5259s ≈ 88 min** | ★ **引用 CONFIRMED · 数值本刀 NOT RE-MEASURED**(勘察没有跑门,跑门就是开工) |
| SEARCH-4 §14:这台机器在两次工具调用之间会睡过去,长活要前台轮询 | §14 逐字在;并点名 `nohup … & disown` 不够,**进程组才是那把刀的单位** | ★ **CONFIRMED** |
| SEARCH-4 §3 的四条筛子 | ① 端点必须登记 ② XOR 型 CHECK 作废假桥 ③ 操作人列不是关系 ④ 例外表 —— 三推导一声明 | ★ **CONFIRMED** |
| SEARCH-4 §6 ② 不链接的理由 | 逐字在;★ **而实测它比自己说的更糟**,见 §4.2 | ★ **CONFIRMED,并扩大** |
| SEARCH-4 §10 屏幕形状 | 外层 5、内层按目标种类每组一行、不展开行 | ★ **CONFIRMED** |
| 「上三刀各找到假断言;SEARCH-4 找到三条,其中一条错因是它自己的裁定」 | SEARCH-4 §2:**21 条 XOR → 19**(WRONG)· **15 组废桥 → 口径**(三个数同名)· **4 张零关联表 → 1 张**(WRONG,★ **错因正是本刀 Q4 的裁定**) | ★ **CONFIRMED,逐条** |
| 计数按 INVOKER、只显示读者看得见的 | `search_related` 镜像无 `SECURITY DEFINER` ⇒ INVOKER | ★ **CONFIRMED** |
| Tim 裁过 `employees → medical_claims` / `leave_requests` 给计数,依据是持 `module.hr.view` 的人在页面上本来就看得见 | 两张表的 SELECT 策略现读:`has_permission('module.hr.view')` **OR** `employee_id = current_user_employee()`;两条列表页(`/hr/claims` · `/hr/leave`)**都存在且真的在列** | ★ **CONFIRMED** |
| 「一个组件,两个入口」(SEARCH-1 裁定) | 本刀没有重量(它是 SEARCH-1 的停止条件,不是本刀任何判据的阈值) | **NOT RE-MEASURED** |
| (另测)登记单据表今天合计行数 | **325**(SEARCH-4 那天是 320) | 上下文 |

### 2.1 ⚠ 「最多 30 行」—— 它是对的,而它**不是这一页要装的那个数**

```
一条命中所有分组加起来最多:  30   ← SEARCH-4 §10 报的就是这个(MAT-2026-0001,7 组)
一个分组自己最多:            11   ← 一张关联页要装的是这个(supplier → inbound_batch)
```

★ **这两个数在委托书里合成了一个**,而它们回答的是两个问题:
前者回答「下拉会长多高」(SEARCH-4 的问题),后者回答「关联页要不要分页」(本刀的问题)。
☞ **照 30 排期会把这一页当成一件要立刻分页的活;照 11 会以为永远不用分页。两个都不对** ——
真正的答案在 §4.5:**今天 11,而 140/178 的关系结构上无界**,所以分页不是可选项,
只是它今天一次都不会触发。

**量法(可复算):** 对 `document_types` 的 39 张表逐行调 `search_related(key, id)`,
以 `postgres` 跑(**RLS 被绕过 ⇒ 这些是任何读者能看到的【上界】**),
`max(n)` 与 `max(sum(n)) GROUP BY (key,id)` 分别取。
⚠ **第一版的量具有一处假读数,记下来:** 我先用 `code LIKE prefix||'-%'` 去给 payments
两个 key 去重,而那一句**顺手丢掉了 44 条真单据**(`ZZ-*` 探针残骸等 9 张表上的非规范码)。
是「被丢掉的行按表分组」那一格把它拆穿的 —— **一次静默的过滤,和一次干净的测量,在读数上长得一模一样。**
最终读数取自**不过滤**的全集(325 行)。

---

## 3 · ★ grilling 改了什么(§3)

`mattpocock-skills:grilling` 按名调用,作用在 §2 的范围上。它改了三件事,
**三件都是它逼出来的、而不是委托书里写着的**:

| # | grilling 逼出来的那一问 | 它改变了什么 |
|---|---|---|
| ① | 「**39 个列表页**真的有 39 个吗?」 | ★★ **没有。6 种单据一个列表页都没有。** 于是 Tim 权衡的那两个选项里,(a) 对 7 种单据**按构造不可行** —— 他的裁定因此比他做裁定时**更对**,而理由是一条他没有被告知的事实 |
| ② | 「这一页会不会是某些单据行**第一次**被列出来?」 | ★ 是。**16 条边指向那 6 种没有列表页的单据。** 这把 §4 那个「有没有哪种关系的行不该列」的问题从一个假想变成一张点名清单(§4.6) |
| ③ | 「Tim 接受的那个代价,**具体是多少**?」 | ★ 量出来比想象的小得多:**导出 5 条路由 · 服务端排序 9 条 · 客户端排序 8 条 · 分页 17 条 · 批量动作 0 条 · 合计行 0 条**(§4.3)。**「批量动作」与「合计行」这两栏根本没有东西可失去** —— 而委托书把它们列成了要衡量的代价 |

★ 它**没有**改动的:Tim 选 (b) 这件事本身。**三条发现全部指向同一个方向 —— (b) 更对了。**

---

## 4 · 量出来的东西(§4)

### 4.1 ★★ 决定这一刀大小的那个问题:**39 个列表页里有多少是共享代码?**

> **答:33 条列表路由里 32 条走同一对共享组件。唯一的例外是 `/tools/tasks`,
> 而它不是一张表 —— 它是一块看板。**

```
33 条列表路由,逐条判(只看路由目录【自己】那一层的 .tsx,不看 [id] 子树):
  <DataTable> = Y 且 <ListPage> = Y   ……  32 条
  两者皆无(TaskBoard 看板)          ……   1 条  /tools/tasks
```

☞ **所以共享页是【填一个已有的槽】,不是【造一套新机器】。**
它要供的东西只有三样:**一份列定义 · 一句标题 · 一次取数**。
外壳(`<ListPage>` 的必填 `state`:ok / empty / restricted)与表格
(`<DataTable>` 的手机版列优先级、排序、分页开关)**今天就在树里,默认全关**
(`data-table.tsx` 抬头的 R4:四个开关一律默认 false)。

★ **而列定义那一份是【按单据种类】的,不是一份通用的。** 逐条量出来的约束:

| | 读数 | 对共享页的后果 |
|---|--:|---|
| 有 `label_column` 的单据种类 | **31 / 40** | ★ **9 种没有任何标签列** —— 对它们,共享页**只能画单据号**。这不是缺陷,是登记表的事实(`cash_forecast` · `collection_chase` · `customer_statement` · `traceability_report` · `contract` · `management_pack` · `attendance_period` · `gst_period` · `wht_remittance`) |
| 单据号(`code`)| 39 张表**全有**(登记表的存在前提) | 一列永远画得出来 |
| 房子的分页常量 | 树里 **17 处** `PAGE_SIZE`,★ **17 处全是 20** | 共享页照抄 20,不新造一个数 |

#### ★★ 而委托书那句「39 个列表页」是假的 —— **6 种单据一个列表页都没有**

| 单据种类 | 今天在哪能看到它的行 | 有系统级列表吗 |
|---|---|---|
| `assay_result` | 只有 `/inbound/[id]/assays/…`(按批) | ★ **没有** |
| `cod` | 只有 `/inbound/[id]/cod`(按批) | ★ **没有** |
| `traceability_report` | 只有 `/output/[id]/traceability` | ★ **没有** |
| `collection_chase` | 只有客户详情页上的 `ChasePanel` | ★ **没有** |
| `customer_statement` | 只有客户详情页上的 `StatementPanel` | ★ **没有** |
| `shipment` | ★ **`/sales/shipments` 目录下只有 `[id]`,连 `page.tsx` 都没有** | ★ **没有** |
| `expense_claim` | ★ 在 **`/finance/claims`** —— 而它登记的 route 是 `/hr/claims`,**那一页列的是医疗申报** | ⚠ **有,但不在它登记的地址上** |

☞ **这件事直接落在 §2 那次权衡上:** 选项 (a)「教 39 个列表页各加一个筛子」
**对这 7 种按构造做不到** —— 6 种没有页面可教,1 种教了也是教错那一页。
**Tim 是在不知道这一条的情况下选的 (b),而这一条让 (b) 成为唯一可行的那个。**

### 4.2 ★★ SEARCH-4 §6 ② 说对了,**而实情比它说的更糟**

§6 ② 写的是:「目标列表页的 `?q=` 过滤的是**单据号**,没有『这个供应商的进料批』这个地址」。
★ **实测:对 5 种 `list_q` 单据,那个 `?q=` 指着的列表页连【它们那张表】都不列。**

| 单据种类 | 命中链到 | 那一页 `?q=` 实际过滤的是 | 结果 |
|---|---|---|---|
| `assay_result` | `/inbound?q=ASY-2026-0001` | `inbound_batches.code.ilike.%…%` + 物料/供应商 id | ★ **永远 0 行** |
| `cod` | `/output?q=COD-…` | `output_batches.code.ilike` | ★ **永远 0 行** |
| `traceability_report` | `/output?q=TRC-…` | 同上 | ★ **永远 0 行** |
| `collection_chase` | `/sales/customers?q=CHASE-…` | `customers.code/legal_name/short_name/tax_id/country` | ★ **永远 0 行** |
| `customer_statement` | `/sales/customers?q=STMT-…` | 同上 | ★ **永远 0 行** |

前缀一个都不重叠(`ASY` vs `IN`,`COD`/`TRC` vs `OUT`,`CHASE`/`STMT` vs `CUS`),
所以这不是「今天恰好没有」,是**结构上匹配不上**。
☞ **也就是说「差不多的地方」今天【已经在生产上了】** —— 搜到一张化验单、点开,
落在一张空的进料批列表上,而屏幕上写的是「没有符合条件的记录」。
**这不是本刀造成的,而本刀造出来的那个地址恰好是它的解药。**(→ 开问 Q7)

⚠ **顺带一处与本刀无关、但必须点名留档的线上数据缺陷:**
`containers` 有一行,它的 `code` 列里存着一段 **JSON 报错**:
`{"code":"42501",…,"message":"permission denied for function next_container_code"}`
(`id = f21b293a-bc5c-46de-9b54-3f1a8a4e1329`,18 行里的 1 行)。
它会**作为一条单据进入搜索结果**。这是本仓库 `docs/machine-text-reaching-humans.md`
那一族的现场,**处置由人决定,本刀不碰**。

### 4.3 ★ 会失去什么 —— **逐页一行,不是一句小结**

「—」= 那一页今天就没有这样东西,**因此没有东西可失去**。

| 单据种类 | 今天的列表页 | 服务端排序 | 客户端排序 | 分页 | 导出 | 筛子(个) | 批量 | 合计行 | 行内编辑 |
|---|---|:--:|:--:|:--:|:--:|--:|:--:|:--:|:--:|
| `inbound_batch` | `/inbound` | **Y** | **Y** | **Y** | **Y** | **8** | — | — | — |
| `output_batch` | `/output` | **Y** | **Y** | **Y** | **Y** | **7** | — | — | — |
| `customer` | `/sales/customers` | **Y** | **Y** | **Y** | **Y** | 1 | — | — | — |
| `supplier` | `/suppliers` | **Y** | **Y** | **Y** | **Y** | 2 | — | — | — |
| `material` | `/materials` | **Y** | **Y** | **Y** | **Y** | 2 | — | — | — |
| `journal_entry` | `/finance/journal` | — | — | **Y** | **Y** | 2 | — | — | — |
| `processing_run` | `/operation/processing` | **Y** | — | **Y** | — | 2 | — | — | — |
| `employee` | `/hr/employees` | — | — | **Y** | — | 4 | — | — | — |
| `purchase_order` | `/purchasing/orders` | — | — | **Y** | — | 4 | — | — | — |
| `invoice` | `/finance/invoices` | — | — | **Y** | — | 4 | — | — | — |
| `expense` | `/finance/expenses` | — | — | **Y** | — | 4 | — | — | — |
| `payment_receipt` / `payment_out` | `/finance/payments` | — | — | **Y** | — | 3 | — | — | — |
| `credit_note` | `/finance/credit-notes` | — | — | **Y** | — | 0 | — | — | — |
| `stocktake` | `/stocktakes` | — | — | **Y** | — | 0 | — | — | — |
| `bank_statement` | `/finance/bank/statements` | — | — | **Y** | — | 2 | — | — | — |
| `leave_request` | `/hr/leave` | — | — | — | — | 5 | — | — | — |
| `medical_claim` | `/hr/claims` | — | — | — | — | 3 | — | — | — |
| `expense_claim` | ⚠ `/finance/claims` | — | — | — | — | 3 | — | — | — |
| `fixed_asset` | `/finance/assets` | — | — | — | — | 1 | — | — | — |
| `container` | `/logistics/containers` | — | — | — | — | 0 | — | — | — |
| `management_pack` | `/finance/packs` | — | — | — | — | 1 | — | — | — |
| `cash_forecast` · `payroll_period` · `pricing_formula` · `quote` · `sales_order` · `work_order` · `contract` · `attendance_period` · `gst_period` · `freight_document` · `wht_remittance` | 各自的 route | — | — | — | — | 0 | — | — | — |
| `task` | `/tools/tasks` | — | — | — | — | 0 | — | — | — |
| ★ `assay_result` · `cod` · `traceability_report` · `collection_chase` · `customer_statement` · `shipment` | ★ **没有列表页** | — | — | — | — | — | — | — | — |

**★ 谁失去得最多 —— 点名两条:**

1. ★★ **`/inbound`(8 个筛子 + 两种排序 + 分页 + 导出)与 `/output`(7 + 两种 + 分页 + 导出)。**
   这两页是整套系统里最重的列表,而它们**恰好是关联关系最密的两张表**
   (`supplier → inbound_batch` 最大分组 11 · `material → output_batch` 10 ——
   **Tim 那个例子本人**)。☞ **他点「Output batches 10」跳过去,拿到的是一张
   没有 7 个筛子、没有排序、没有导出的表。**
2. ★ **`/materials` · `/suppliers` · `/sales/customers`(各带导出)。**

**★ 而这两栏【本来就没有东西可失去】,委托书把它们列成代价是多余的:**

| | 全仓实测(独立路径复核) |
|---|---|
| **批量动作** | ★ **0 个列表页有**。全树只有 3 个文件出现选择态:`data-table.tsx`(组件自己的能力,默认关)· `CostSettlePanel` · 银行对账 `ReconcileWorkspace` —— **后两个都不是单据列表页** |
| **合计行(`<tfoot>`)** | ★ **0 个列表页有**。全树 15 个文件有 `<tfoot>`,**15 个全在详情页或组件里**(试算表、资产负债表、分录明细…) |
| **行内编辑** | ★ **0 个单据列表页用 `<EditableTable>`**(它只在 `/hr/leave/types` 与 `/hr/reviews/scale` 上,两者都不是单据表) |

☞ **所以 Tim 接受的那个代价,真实清单是三样:筛子、排序、导出。** 不是六样。

### 4.4 ★ 地址:它带什么,漏不漏

**建议的形状(→ 开问 Q1/Q2):**

```
/related/<subjectTypeKey>/<subjectId>/<targetTypeKey>
例:/related/material/1f2e…-…/output_batch
标题:「NMC Cathode Foil 的产出批」
```

**⚠ 权限必须从 URL 重新在服务端求值 —— 机制,逐条:**

| 层 | 机制 | 为什么够 |
|---|---|---|
| ① **主语看得见吗** | 用**会话身份**读 `subjectTable WHERE id = $1`。★ **读不到 ⇒ 整页拒绝(`<ListPage state=restricted>` / `<RefusalPage>`),不是空列表** | 主语读不到却照画标题,**标题本身就是一次披露**(见下) |
| ② **目标行看得见哪些** | 取数函数是 **INVOKER**,与 `search_related()` **同一个身份、同一张 `document_relations`、同一段边→SQL 翻译** | RLS 天生回答「你看得见几条」。**再在 TypeScript 里判第二遍,就是把同一条规则写第二遍** —— 本仓库为这个形状付过四次账(预览函数那一条) |
| ③ **模块闸** | **不另写。** `document_types.view_permission` 的每一个码,fixture 101 已经断言它**真的出现在该表 SELECT 策略的谓词里** ⇒ ② 的 RLS **就是**模块闸 | 写第三处判据就是造第三种方言 |

★★ **URL 自己漏什么 —— 照直说:**

* `subjectId` 用 **uuid**:uuid 是不透明的,**URL 本身不披露任何业务内容**。
  22 种 `link_mode='detail'` 的单据今天就是这么链的(`${route}/${row.id}`),所以这是**主流写法**。
* ⚠ **换成单据号(`SUP-2026-0002`)就会漏**:一个看得见链接的人(聊天记录、工单、
  浏览器历史、Referer)**不用打开就知道存在这张单据**。而 9 种 `list_q` 单据
  **今天已经在 URL 里放单据号了**(`?q=${code}`)—— **那是一处既存的、本刀不扩大的披露**。
* ★ **本仓库已经为同一个问题裁过一次,方向一致:** `/me/avatar` 的例外理由逐字写着
  「**地址里不再出现任何 uid —— 服务谁由会话说了算**」(UI-1d/COD-2)。
  ☞ **能由会话决定的,就不要写进地址。** 这里主语必须写进地址(这一页就是关于它的),
  而**把它写成 uuid 是这条规矩允许的最小披露**。
* ★ **真正会漏的那一格是【标题】,不是 URL**:「NMC Cathode Foil 的产出批」
  把主语的**标签**印在屏幕上。所以第 ① 层不是防御性的,**它是这个地址能不能存在的前提**。

**新路由要过的闸(量过):** `scripts/check-nav-routes.mjs` 判据 ② ——
文件系统上每条路由要么在 `FUNCTIONS` 注册表里,要么在 `EXCEPTIONS` 里**带一句理由**;
★ 而 SEARCH-1 · S6 已经把「前缀覆盖」这张通行证收掉了,**动态段也要被覆盖**。
☞ 所以要两条例外(`/related/[subject]/[id]/[target]` 及其父),理由是
「它不是菜单去处,入口只有搜索面板」。**一行字,不是一个机制。**

### 4.5 ★ 取行:`search_related()` 要扩,还是另起一支?——**另起一支,而这一刀【需要一次迁移】**

`search_related()` 今天的形状是:按 `document_relations` 把每条边翻译成一段
`SELECT t.id, t.code …`,`UNION ALL` 起来,再 `count(DISTINCT u.id)`。
★ **要的行就是它已经算出来那个 `DISTINCT u.id` 集合** —— 只是没返回。

| 选项 | 判 |
|---|---|
| (i) 给 `search_related()` 加参数、让它**有时**返回行 | ✗ 一支函数两种返回形状,而**计数那一路今天有五个调用点在依赖**。改签名会撞上 `preflight_migration.py` 的「重载不是替换」那条拒绝 |
| ★ (ii) **兄弟函数 `search_related_rows(p_key, p_id, p_target_key, p_limit, p_after_code)`** | ★ **推荐。** 与 `search_related` **同一段边→SQL 翻译**(同一张视图、同一套 `format()`、同一条 `shared` 前缀过滤、同一条自指排除),**INVOKER**,返回 `(id, code, label, href)` |
| (iii) 不迁移,在 TypeScript 里读 `document_relations` 自己拼查询 | ✗ **把边→SQL 那段翻译写第二遍。** 这正是本仓库付过四次账的形状,而且它要在应用层拼 SQL |

> ### ☞ 所以:**这一刀需要一次迁移,而它是纯增量的一支新函数。**
> 没有新表、没有新列、没有改任何现有对象 ⇒ **破窗属于迁移 A/C/D 那一族(什么都不会坏)**,
> 不是 B 那一族。

★★ **而「取行必须和计数用同一份可见性」这件事,必须【有一支 fixture 钉住】,
不能靠两支函数长得像:**
判据 = 同一个 `(key, id, target_key)`,`count(search_related_rows(...)) == search_related(...).n`,
**在同一个 `SET LOCAL ROLE authenticated` 的会话里**,而且**要有一格反面对照**
(撤掉目标表的策略 / 换一个看不见它的 sub,两个数**必须一起变**)。
⚠ 没有反面对照,「两个数一样」可能只是**两支函数都返回了全部** —— 而 fixture 以
`postgres` 跑、`rolbypassrls=t`,**那一格按构造是绿的**(AGENTS.md 记过的 fixture 26 那一课)。

### 4.6 ★ 空与陈旧 —— **不许把一次缺席画成一个答案**

读者点「10」,页面加载时只剩 9 条,或者 0 条。**四种零,处置完全不同:**

| 读到的 | 页面说什么 | 为什么 |
|---|---|---|
| 主语读不到(URL 是手敲的,或权限刚被撤) | ★ **整页拒绝**,走 `<RefusalPage>`,说出缺哪个权限 | 一个空列表读起来是「这个主语没有产出批」,那是一句**关于数据的断言** |
| 主语在,`target_key` 不在 `document_types` 里 | ★ **响亮报错**(`search_related` 已有先例:`SEARCH_UNKNOWN_DOCUMENT_TYPE`) | 拼错的 key 与真的没有关联,在屏幕上分不开 |
| 主语在、这一对**结构上没有边** | 「这两种单据之间没有关联」 | 与「有边但今天没有行」是两件事 |
| 主语在、有边、**今天 0 行** | ★ 「**这张单据现在没有关联的产出批。**」—— 现在时,肯定句 | SEARCH-3 为同一条理由删掉过 `search.recordsNotBuiltYet`;**不许写「还没建」** |

★★ **而「9 变 10」那一格的裁定应当是:页面【不回显】它被点的那个数。**
页面画它**此刻**数出来的行,并且那个数由**同一支函数**给出。
☞ 理由是本仓库自己的:**一个面板上的计数是一张快照,一张快照不是一道闸**
(INPUT-2b 那一条)。让页面去核对下拉里那个数,只会造出一个
「面板说 10、页面说 9」的假矛盾,而**两个都是真的**。

### 4.7 ★ 分页:一个分组到 500 怎么办

| | 读数 |
|---|--:|
| 今天**一个分组**最大 | ★ **11**(`supplier → inbound_batch`) |
| 今天 > 10 行的分组 | **1 个** |
| 今天 > 20 / 50 / 100 行的分组 | **0 / 0 / 0** |
| ★ **结构上无界的有向表对** | ★ **140 / 178**(`in` 边 65 + `bridge` 边 124;只有 38 对全 `out`,因而 ≤1 行) |

> ☞ **判词:分页不是可选项,而它今天一次都不会触发。**
> 「79% 的关系无界」与「今天最大 11」**两个都要报**,不拿前者吓人、也不拿后者当上界。

**建议(→ 开问 Q4):** `<DataTable>` 的分页开关本来就在,房子的 `PAGE_SIZE` 17 处全是 **20**。
★ **排序键用 `code`,不用 `created_at`** —— AGING-1 那一条:`created_at DEFAULT now()`
记的是**事务**不是行,同一笔事务写进去的两行**排不出先后**;而 `code` 在每张单据表上唯一。
★ **翻页用 keyset(`code < $after` )而不是 `OFFSET`**:取行那一段是
`UNION ALL` + `DISTINCT`,`OFFSET 480` 会把前 480 行**算出来再扔掉**。
⚠ **本刀【没有量】任何毫秒数,也不打算量**(325 行,规划器一律 Seq Scan)——
**前四刀都拒绝过,而它们是对的。** keyset 的理由是**形状**,不是一个读数。

### 4.8 ⚠ 有没有哪种关系,**给了计数、却不该给行**?

**Tim 的裁定原话(SEARCH-4 §7):**「一个持有 `module.hr.view` 的读者在页面上
本来就看得见那张列表,而搜索**永远不比它指向的那一页更严**。」

★ **这条理由的承重部分是「那一页」。所以判据是:【那一页存在吗】。**

**① 他点名的那两种 —— 开行【留在】他的理由之内:**

| 关系 | 目标表 SELECT 策略(现读) | 那一页 | 判 |
|---|---|---|---|
| `employee → medical_claim` | `has_permission('module.hr.view')` OR `employee_id = current_user_employee()` | ★ `/hr/claims` **存在,列的就是它**(`medical_claim_status`) | ★ **在理由之内** —— 关联页给的是那张全量列表的**子集** |
| `employee → leave_request` | 同上 | ★ `/hr/leave` **存在,列的就是它** | ★ **在理由之内** |

**② 而有 16 条边指向那 6 种【没有列表页】的单据 —— 对它们,「那一页」不存在:**

```
assay_result      ← inbound_batch · output_batch · sales_order · (自指)
cod               ← inbound_batch · (自指)
traceability_report ← output_batch
collection_chase  ← customer · (自指)
customer_statement ← customer · (自指)
shipment          ← container · output_batch · sales_order
expense_claim     ← employee · expense        (有列表,但在 /finance/claims)
```

★ **本刀把它们逐条量到底了,而结论分成两半:**

* **14 条**:主语的**详情页上今天已经有一块面板在列同样的行**(按同一个主语作用域)——
  `inbound_batch → assay_result`(`/inbound/[id]/assays`)· `inbound_batch → cod` ·
  `output_batch → traceability_report` · `customer → collection_chase`(`ChasePanel`)·
  `customer → customer_statement`(`StatementPanel`)· `sales_order → shipment` 与
  `container → shipment`(实测 `ShippingSection` / `ContainerPanels` 都在列)· 各条自指链。
  ☞ **关联页对它们是【同一份东西的第二个入口】,不是新的披露。**
* ★★ **3 条今天【没有任何地方在列】**,关联页会是它们第一次被列出来:
  **`employee → expense_claim`** · **`expense → expense_claim`** · **`sales_order → assay_result`**
  (实测:员工详情页、支出详情页都不提 `expense_claim`;订单详情页只列 `shipments`,不列化验单)。

★ **本刀量到的一条【减轻但不消除】的事实:** 这三条的目标表 RLS 分别是
`expense_claims`:`module.finance.view` OR 本人;`assay_results`:
`(inbound_batch_id IS NOT NULL AND module.inbound.view) OR (output_batch_id IS NOT NULL AND module.output.view)`。
☞ 也就是说**看得见这些行的人,都持有一个已经给了他全量列表的模块闸**
(`/finance/claims` 列全部报销申请;`/inbound/[id]/assays` 列该批全部化验单)。
**所以「更严/更松」那条总裁定不会被破;被破的是「那一页」这个措辞。**

> ### ★ 这是 Tim 的,不是我的。照委托书办,**我不裁它。**
> 要裁的那一句,写成他能一口答的形状:
> **「一个持有 `module.finance.view` 的人,在员工 EMP-2026-0003 的关联页上看见
> 『报销申请 3 条』并点开它 —— 这与他在 `/finance/claims` 上筛同一个员工,
> 是不是同一件事?」** 我量到的证据说「是」(同一份 RLS、同一批行、更窄的作用域),
> **而『那一页今天没有一个按员工筛的筛子』这一点,只有他能判它算不算一个区别。**

---

## 5 · ★ 每一条开问,连同我的建议与它的证据(§6 要求:**全部,不筛**)

> **形状问题 3 条(Q7 · Q8 · Q9),细节问题 12 条。** 见 §7 的判词。

### ★ 形状级(会改变这一刀长什么样)

❓ **Q1 — 地址的形状**
`/related/<subjectTypeKey>/<subjectId>/<targetTypeKey>` 三段,还是
`/related?subject=…&type=…&target=…` 查询串?
➡ **建议:三段路径。** 证据:`check-nav-routes` 判据 ② 按**路由**登记例外,一条路径写得出一条例外;
查询串形式会让一条例外覆盖无穷多种组合,**而那正是它 S6 收紧掉的那张通行证**。

❓ **Q2 — 主语在地址里用 uuid 还是单据号**
➡ **建议:uuid。** 证据:22 种单据今天就用 uuid 链详情(`${route}/${row.id}`);
`/me/avatar` 的例外理由逐字写着「地址里不再出现任何 uid,服务谁由会话说了算」。
单据号会让看得见链接的人**不用打开就知道这张单据存在**。
⚠ 照直说:9 种 `list_q` 单据**今天已经把单据号放进 `?q=`** —— 本刀不扩大它,也不修它。

❓ **Q3 — 取行是兄弟函数,还是扩 `search_related()`**
➡ **建议:兄弟函数 `search_related_rows(...)`,INVOKER,纯增量迁移一支。**
证据:§4.5 三选项对照;`preflight_migration.py` 会**拒绝**一次改签名的
`CREATE OR REPLACE`(它判成重载不是替换)。

❓ **Q7 — 那 5 种今天链到一张【永远 0 行】的列表页的单据,它们的命中链接要不要也改到这一页?**
(`assay_result` · `cod` · `traceability_report` · `collection_chase` · `customer_statement`;§4.2)
➡ **建议:本刀【不改】,单独立案。** 证据:它不在 §2 的范围里(§2 说的是**分组行**能不能点),
而它是**一处既存的生产缺陷**,改它要重开 `link_mode` 那条裁定(SEARCH-2b 的 T1)。
★ **但它必须被写下来**,否则下一份委托书会把「命中链接是好的」当成前提。
⚠ **而它与本刀相关:** 共享页正好是这 5 种单据**唯一可能的正确落点**,
所以 Tim 可能想把两件事并成一刀 —— 那是他的选择,我给的是默认值。

❓ **Q8 — 那 3 条今天【没有任何地方在列】的关系,要不要开行?**
(`employee → expense_claim` · `expense → expense_claim` · `sales_order → assay_result`;§4.8)
➡ ★ **这一条我不建议,我把它交出去** —— 委托书明写「If it goes past it, that is Tim's to rule, not yours」。
**我量到的证据(全部,两面都给):**
* 支持开:三条的目标行 RLS 已经把读者限在**持有相应模块闸**的人;
  而那些人在 `/finance/claims` / `/inbound/[id]/assays` 上**看得见更多**(全量,不是子集)。
* 反对开:Tim 那条理由的字面是「**在页面上本来就看得见那张列表**」,
  而对这三条**那张列表不存在** —— 理由的主语掉了。
➡ **如果一定要我给默认值:开。** 因为「搜索 ≤ 页面」这条总裁定是关于**权限**的,
而权限这一侧三条全部成立;不开会让共享页对同一个读者**比 RLS 更严**,
而「更严」这一侧本仓库还没有过裁定。**但这句话是建议,不是裁定。**

❓ **Q9 — `/tools/tasks` 是一块看板,不是一张表。关联页把任务画成表,行不行?**
➡ **建议:行,画成表。** 证据:`employee → task` 是**今天第二密的关系**
(15 个主语有这一组,最大 6 行);而关联页回答的是「这个人手上有哪几件事」,
**不是「这些事在哪一列」**。看板的价值是列与列之间的移动,而一个只读的、
按主语筛过的子集里没有那件事。⚠ **代价要写进报告:任务是唯一一种
「共享页的画法与它自己的页面不是同一种画法」的单据。**

### 细节级(不改形状,但要有人拍板)

❓ **Q4 — 分页:页大小与翻页方式**
➡ **建议:`PAGE_SIZE = 20`(树里 17 处全是 20),keyset 按 `code` 降序翻页,不用 `OFFSET`。**
证据:§4.7;`code` 唯一而 `created_at` 在同一笔事务里并列(AGING-1)。

❓ **Q5 — 每一行画什么**
➡ **建议:两列 —— 单据号(链到它自己的详情/落点)+ 标签(`document_types.label_column`)。**
证据:**31/40 有 label_column,9 种没有** ⇒ 对那 9 种只画一列,
**不拿别的东西顶上**(`records.ts` 的 `toHit` 已经是这条规矩:「没有标签就不给标签」)。
⚠ **不建议按单据种类各写一份列定义** —— 那就是 39 份清单,正是 Tim 否掉 (a) 的理由。

❓ **Q6 — 排序 / 筛选 / 导出:共享页给不给?**
➡ **建议:一样都不给(第一刀)。** 证据:§4.3 —— 真实代价只有三样,
而其中**导出只有 5 条路由有、服务端排序 9 条、客户端排序 8 条**;
`<DataTable>` 的四个开关**默认全关**,打开任何一个都要那一页自己答
「排的是不是全体」(A1 那条类型约束)。★ **给一个只排得了这一页的排序控件,
正是 `data-table.tsx` 抬头点名的那个静默失败。**

❓ **Q10 — 分组行是不是【全部】可点?**
➡ **建议:全部可点,包括计数为 1 的那些。** 证据:一条「有时是链接、有时不是」的规矩
需要一张清单来维护,而那正是 Tim 对 (a) 的反对理由;**而且 1 与 11 在屏幕上都是一个数字**。

❓ **Q11 — 这一页的返回路**
➡ **建议:`<ListPage breadcrumb>` 里放一条回到主语详情页的链接**(主语有详情页时),
**不放「回到搜索」** —— 搜索是一个下拉,没有可返回的地址。
证据:`list-page.tsx` 的 `breadcrumb` 槽是 CONV-8 为这件事开的,64 个既有调用点不受影响。

❓ **Q12 — 新路由怎么过 `check-nav-routes`**
➡ **建议:`EXCEPTIONS` 两条(父 + 动态段),理由写「入口只有搜索面板,不是菜单去处」。**
证据:`/my-reviews` + `/my-reviews/[id]` 就是这个形状的先例(S6 收紧之后补的那一条)。

❓ **Q13 — 文案要几条新键**
➡ **建议:4 条 × 2 语言。** ①标题(`{target} of {subject}`,两个参数)②结构上没有边
③有边但 0 行 ④分页的「第 m–n 条」。**40 条 `search.docType.*` 已经在**(SEARCH-4 交的),
所以标题里那个 `{target}` 不用新造。⚠ `check-i18n` 的后缀集合**从
`document_types.sql` 的种子现读** —— 加单据种类少一句译文当场红,这一条不用动。

❓ **Q14 — 探针加哪一格**
➡ **建议:`probe-search-results` 加一格【点击】而不是 `goto`。**
★ 证据是本仓库最贵的那一课(CONFIRM-1):`<SearchShell>` 住在根布局里,
**软导航不重画根布局**,于是一次 `page.goto` 的读数对每一个真实会话都不作数。
**要点,并且要在 `window` 上盖一个记号证明文档没有重新加载。**

❓ **Q15 — fixture 要断言什么**
➡ **建议:一支,四臂。** ①行数 == `search_related` 的计数(同一会话)
②★**反面对照**:换一个看不见的会话,**两个数一起变**(没有这一格,它可能只是两支函数都返回全部)
③主语读不到 ⇒ 函数**不返回行**(而页面据此拒绝)④未知 `target_key` ⇒ **RAISE**,不是空集。
⚠ fixture 以 `postgres` 跑、`rolbypassrls=t`,**①②必须 `SET LOCAL ROLE authenticated`**,
否则两臂按构造全绿(fixture 26 那一课)。

---

## 6 · 价钱(§5)—— **两个数,永远**

### 6.1 过程底价 —— **测量的出处逐条写清**

| | 读数 | 出处 |
|---|--:|---|
| SEARCH-1 报的过程底价 | **5259s ≈ 88 min** | `SEARCH-1.md:38` / `:463` ★ **引用 CONFIRMED,本刀 NOT RE-MEASURED** |
| `db/gate.py --offline`(迁移前相位) | **46s** | SEARCH-4 §14 · CONFIRMED(读) |
| `db/gate.py` 整门 | **514s** | SEARCH-4 §14 · CONFIRMED(读) |
| `smoke-routes.mjs` | **682.8s**(223 条路由) | SEARCH-4 §14 · CONFIRMED(读) |
| `npm run build`(冷) | AGENTS.md:28 支静态检查 + `next build` ≈ **22s** | CONFIRMED(读) |
| 备份 | ★ **8 分钟到 34 分钟,没有一个可以照着规划的数** | AGENTS.md 的备份那一节 · CONFIRMED(读) |

☞ **本刀是勘察,一支门都没跑 —— 上面每一个数都是【读来的】,不是【量来的】,照直标。**
★ 把它们加起来:**脚本时间约 1300s + 备份 480–2040s ≈ 30–56 分钟**,
而 SEARCH-1 那个 88 分钟是**含人工的全程底价**,两个数不可比,**并排放,不合并**。

⚠ **一条给下一刀的实测环境提醒(SEARCH-4 §14,CONFIRMED):**
这台机器在两次工具调用之间会睡过去;长活要**短的前台轮询**把它按醒,
而 `nohup … & disown` **不够 —— 进程组才是那把刀的单位**。
★ 本刀自己踩到一个同族的小号:一次跨 39 张表的 `search_related` 全扫
**墙钟 67 秒**,而它只是一条 HTTP 往返。

### 6.2 这一刀的工作量 —— **按量出来的件数报,不报一个小时数**

| 件 | 量 | 依据 |
|---|--:|---|
| 迁移 | **1 支新函数**,纯增量,无新表/新列/不改现有对象 | §4.5 |
| 镜像 | `db/functions/search_related_rows.sql` **1 份** | AGENTS.md 的镜像规矩 |
| fixture | **1 支,4 臂**(含 1 格反面对照) | Q15 |
| 新页面 | **1 条路由**;复用 `<ListPage>` + `<DataTable>`(**32/33 条列表页已经在用**) | §4.1 |
| 改既有文件 | `lib/search/types.ts`(`RelatedGroup` 加 `href`)· `records.ts`(拼 href)· `SearchEntry.tsx`(分组行变链接)—— **3 个** | 读树 |
| 闸 | `check-nav-routes.mjs` 的 `EXCEPTIONS` **2 行** | Q12 |
| 文案 | **4 键 × 2 语言 = 8 条** | Q13 |
| 探针 | **1 格**(点击式,带未重载记号) | Q14 |

★ **量级判词:这一刀比 SEARCH-4 小。** SEARCH-4 交了 2 张表 + 1 张视图 + 1 支函数 +
75 条索引 + 1 道新闸 + 80 条文案;本刀交 1 支函数 + 1 条路由 + 8 条文案。

### 6.3 ★ 在 Tim 答之前**定不了价**的那几件,点名

| 不确定的 | 卡在哪一问 | 它会改多少 |
|---|---|---|
| 那 5 种链到空列表的单据要不要一起修 | **Q7** | 要改的话多一次 `link_mode` 裁定 + 40 行登记表迁移 + fixture 100 要重跑 —— ★ **它会让这一刀从"小"变成"中"** |
| 那 3 条今天无人列出的关系开不开行 | **Q8** | ★ **不改代码量**(判据是同一条 RLS);但**不开**的话要一张按关系的名单 —— 而那是 Tim 否掉 (a) 的同一种东西 |
| 共享页给不给排序/筛选/导出 | **Q6** | 给排序要那一页答「排的是不是全体」;**给导出要一条新 route.ts** ⇒ 每样约等于再加一个 §6.2 里的「件」 |
| 任务画成表 | **Q9** | 不改代码量,改的是一句要写进报告的代价 |

★ **不报的那个数,第五次:一次关联查询要多久,没有量,也不打算量。**
325 行,规划器一律 Seq Scan。**前四刀都拒绝过,而它们是对的。**

---

## 7 · 一刀还是几刀(§6)

> ### ★ **一刀。合并。**

**理由(委托书要求点名,所以点名):**

1. **迁移只有一支函数,纯增量。** 拆成两刀会开**两个破窗**去换一个本来就什么都不会坏的窗口。
2. **32/33 条列表页已经共享同一对组件** —— 新页面是**填槽**,没有可拆的"先建基础设施"那一半。
3. ★ **前端与后端那两半【互相不可验证】**:分组行变成链接,链到一个还不存在的地址,
   就是本仓库点名拒绝的「差不多的地方」;而一个没有入口的地址,
   `check-nav-routes` 的判据 ② 会**当场问它为什么存在**。**两半必须同时落地。**

★ **唯一一条【真的】可以拆出去的:Q7 那 5 种链到空列表的单据。**
它改的是 `document_types` 的登记,不是这一页;它有自己的裁定要重开;
**而它今天已经坏着,再坏一周不会更坏。** ☞ 建议单独立案,不并进来 —— **除非 Tim 要它一起。**

---

## 8 · ★ 这一轮之后的前沿是什么(§6 最后一条)

> ### ★★ **形状级的问题还剩三条,不是零 —— 所以【不建议】直接开工。**

**Q7(那 5 种链到空列表的单据要不要一起修)· Q8(3 条无人列出的关系开不开行)·
Q9(任务画成表)** —— 这三条**都会改变这一刀交出去的东西是什么**,
而 Q8 是委托书自己明写「不许我裁」的那一条。

★ **而【其余 12 条全部是细节级的】,并且每一条都带着一个我量过的默认值。**
☞ 所以老实说:**这不是一份"还要再勘察一轮"的前沿,是一份"要三个回答"的前沿。**
Tim 答完 Q7 / Q8 / Q9,**剩下的 12 条按上面的建议走即可,不必再回来问**。

⚠ **一件要请他顺带看一眼、而与本刀无关的:** `containers` 里那一行
把一段 42501 报错 JSON 存成了单据号(§4.2)。**它会出现在搜索结果里。**

---

## 9 · 本刀没有做的事

* ★ **没有写一行代码,没有应用任何迁移,没有改任何镜像。** 本刀的 `git diff` 只有这一份文件。
* 没有跑 `db/gate.py`、`smoke-routes.mjs` 或任何探针 —— 跑它们就是开工。
* 线上只做了**只读**查询(Management API,`postgres` 身份),
  ★ **所以每一个关联计数都是【上界】**:它是"一个看得见全部的人"会看到的数,
  不是任何一个真实读者会看到的数。**照直标,不冒充一次按身份的测量。**

---

## 10 · 等什么

**等 Tim 回答 Q7 / Q8 / Q9,然后这一刀可以开工。**
这台机器够不到 Vercel(AGENTS.md 的常设规矩:一刀的终端活到推送为止)。
