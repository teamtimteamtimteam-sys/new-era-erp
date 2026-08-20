# 物流(运输)勘察 —— LOG-0

**READ ONLY,2026-08-19。** 本文件只报告【现在是什么样】,不提议表、不提议权限码、
不改任何东西。所有结论都来自当天的仓库与线上 schema;拿不准的地方写"未知",不猜。

---

## PART A · 对 scope 本身的意见(先于勘察)

### A0 提出来的两条反对,自己查完之后撤回了

诚实起见先写这两条 —— 它们是我原本准备提的,查过之后【不成立】:

* **「Incoterms 缺失」——不成立。** `incoterm` 已经在 `customers`、`suppliers`、
  `purchase_orders`、`invoices` 上,并且 `purchase_order_history` 记它的变更。
  (仍有一个真问题,见 A4.5,但不是"缺失"。)
* **「Basel 没被想过」——不成立。** `docs/compliance-scoping.md:140` 已经把
  Basel/TFS 定成**交易级**:一次物理发运一套文件,生命周期是
  通知 → 同意 → 转移 → 处置确认,并点名 `po_issues` 作为"记录而非视图"的先例。

### A1 问得不成立 / 无法作答的

| 项 | 问题 | 为什么 |
|---|---|---|
| **B9** | 「按 2026 年 8 月组织架构……仓库在运营线下、有一个横跨两边的 lead」 | **仓库里没有这份组织架构文件。** 能找到的最接近的一句是 `docs/exec-views-plan.md:18`:物流 HC 在 CCO(Sandra YAP)那里。**"仓库在运营线下"与"一个横跨两边的 lead"在仓库里查无实据。** 我不会照着一句无法核对的前提去写权限建议。 |
| **B9** | 「permissions **应该**走哪条线」 | 这是一个**裁定**,不是一条勘察结论;而同一段又写着不许建码、不许提角色改动、没有人在岗。可答的那一半是:**现有权限模型的形状会逼出什么**(见 B9)。"应该"留给 Tim。 |
| **B6** | 「排队中的 危废转移联单 那一项」 | **`危废转移联单` 这几个字在整个仓库里搜不到。** `docs/exec-views-plan.md:48` 排队的是另一件事(危废**存储天数** vs 牌照时限,因 NEA 牌照未持有而 PARKED)。所以 B6 的"同一件事还是两件事"**只能答未知**,除非 Tim 指出它排在哪里。 |

### A2 答了也改变不了任何决定的(应删 / 应收窄)

* **B3 要求把 `suppliers` 提供的东西逐项列出**(联系人、付款条件、应付、合规状态)。
  那份清单不改变任何事 —— 会改变决定的只有**应付**那一条,而 scope 自己已经点名了它。
  **收窄:只报应付链上真正卡住的那几列,不做全列清单。**
* **B9 如上,收窄不删。**

其余各条(B1、B2、B4、B5、B7、B8)**问得是好的**,我不为了显得周全而制造反对。
B6 尤其问得好 —— 因为它明写了"拿不准就说未知"。

### A3 scope 夹带的、被当成已定的假设

1. **「Forwarders 不进 suppliers 表」被当成已定,B3 只让我估价。**
   **实况是:货代【今天已经在 suppliers 表里】,而且是生产代码在用的路径** ——
   `freight_documents.supplier_id` 是 **NOT NULL 外键指向 suppliers**,
   并且 `ap_open_items` 里有一支 `doc_kind='freight'`。
   也就是说这条"不进 suppliers"不是一个待建的新规矩,而是一次**对已上线设计的推翻**。
   估价见 B3 —— 价钱高到值得把这个决定重新打开。
2. **假设存在"第 3 层(发运单据)/第 4 层(钱)"的分层计划。** 仓库里找不到这份计划,
   所以"哪一层会踩到什么"只能按我自己的判断说,不能按那份计划说。
3. **假设运输是一个"要新建"的模块。** 实况:`shipments` / `shipment_lines` /
   `shipment_issues` / `freight_documents` / `freight_document_lines` 【已经存在并在用】。
   B2 的"什么合并进来"因此少了一个前提:**合并的目标物今天并不存在。**
4. **B7 假设三种重量都已经在系统里。** 实况:入库侧有两种(申报 vs 磅秤),
   出库侧**只有一种**,客户回称重量【无处可存】。

### A4 缺了、而且拖到第 3/4 层才发现会很贵的

1. **`docs/landed-cost-scoping.md` 已经存在,而 scope 一次都没提它。**
   运费进存货成本正是那份文档的主题,`freight_documents.allocation_basis`
   (weight/value/stated)就是它的落地。第 4 层若另起一套分摊,会与它正面相撞。
2. **期末运费暂估(accrual)。** 货已发、发票未到,而这个库有硬性的 `PERIOD_LOCKED`
   与"决定期间的日期永不默认"的规矩(FIN-10 一族)。没有暂估,期间就是错的。
3. **滞期费 / 滞箱费(demurrage / detention)。** 它们在发运之后好几周才来,
   常常在那张运费应付**已经结清之后**。它决定"一次运输成本什么时候才算封账"。
4. **在途货权(goods in transit)。** 货离开仓库、尚未被对方收到时,存货挂在哪里?
   出库已经写 `sales_records` 与库存台账,月结时这一段的估值归属没有被问过。
5. **`incoterm` 是【自由文本】,而且不在发运单上。** 它在交易对手与 PO 上,没有 CHECK。
   而"运费到底是不是我们的应付"这件事**由它决定** —— EXW 与 CIF 下答案相反。
6. **关税 / 进口 GST 与运费是【不同的收款方】。** 报关行、海关不是货代。
   scope 把"运费"当成一张应付看待。

### A5 我据此对 scope 做的修改(Part B 按修改后的执行)

* **B3 收窄**:只报应付链上真正卡住的部分,不做 `suppliers` 全列清单;
  并且先陈述"货代已经在 suppliers 里"这一实况,再估价。
* **B9 拆两半**:可答的部分(现有权限形状逼出什么)照答;"应该走哪条线"退回给 Tim,
  并声明组织架构前提在仓库里无法核对。
* **B6 明确以"未知"作答**其身份问题,并把可查证的部分(Basel 已被定为交易级)写清楚。
* **新增 B10**:时序与暂估(上面 A4.2 / A4.3),因为它决定第 4 层能不能收口。
* **新增 B11**:incoterm 与"谁付运费",因为它决定第 4 层**有没有应付**这件事本身。

---

## PART B · 勘察

### B1 · 运输今天住在哪里

| 对象 | 写它的人 | 读它的人 | 说明 |
|---|---|---|---|
| `shipments` | `record_shipment` 路径(销售/仓库) | 销售、财务(收入期间) | **只有出库。** `sales_order_id` NOT NULL;`ship_date` 必填、永不默认,**它决定收入落进哪个期间** |
| `shipment_lines` | 同上 | 同上 | 每行:一条订单行 + 一条**唯一**预留 + **一个产出批** + 一条 `sales_records` |
| `shipment_issues` | `record_shipment_issue()` | 客户(送货单 PDF) | 只增不改,`version` + `sha256`,重签 = 新行。**没有"已送达"标志** —— 系统不知道对方收没收到 |
| `freight_documents` | `record_freight_document()` | 财务、采购 | **只有入库运费。** 带 `currency`/`fx_rate`/`amount_base`、`allocation_basis`、`payment_status`、`journal_entry_id` |
| `freight_document_lines` | 同上 | 同上 | **只指向 `inbound_batch_id`** —— 出口运费无处可去 |
| `purchase_orders.expected_delivery_date` | 采购 | 采购 | 期望到货日,单值 |
| `inbound_batches.arrival_date` | 收货 | 全链 | 物理到货日 |
| `inbound_batches.quantity` / `declared_qty` | 收货 RPC | 收货、财务 | 磅秤数 vs **供应商申报数**;`declared_qty` NULL = 没记录过,**永不推断** |
| `grn_discrepancies` | (视图) | 收货、采购 | 把申报与实收的差**说出来,不拒绝** |
| `customers/suppliers/purchase_orders/invoices.incoterm` | 主数据维护 | 人眼 | **自由文本,无 CHECK,不在发运单上** |

**没有的东西:** 承运人/货代字段、提单号、集装箱号、船名航次、里程碑时间戳、
出口运费单据、客户回称重量、在途状态。

### B2 · 按 Tim 的判据逐项裁

判据:**读者是物流的人 且 搬走不切断会计/追溯链** → 才搬;否则留下并加链接。

| 项 | 裁定 | 理由 |
|---|---|---|
| `shipments` 头 | **留下 + 链接** | `ship_date` **决定收入期间**;搬走就是把会计事件搬进物流模块 |
| `shipment_lines` | **留下** | 每行坐在预留、产出批、`sales_records` 上 —— **追溯链的关节** |
| `shipment_issues` | **留下,物流只读** | 送货单是给客户的对外文件,签发档是审计物 |
| 承运人 / 提单 / 集装箱 / 里程碑 | **搬(新建时归物流)** | 读者纯物流;不挂任何会计或追溯 |
| `freight_documents` | **留下(财务)** | 它是一张**会计凭证**:有分录、有应付、有分摊基准 |
| 运费的**录入界面** | **判据不决定** | 录的人可能是物流,读的是财务。判据两半打架 —— **不硬裁**,留给 Tim |
| `expected_delivery_date` | **留下 + 链接** | 采购的承诺日,不是运输事实 |
| `arrival_date` | **留下** | 收货事件,批次上的会计/追溯锚点 |
| `declared_qty` / `grn_discrepancies` | **留下** | 供应商申报是**采购**事实,差异是采购/财务在判 |

### B3 · 货代作为一类交易对手 —— 实况先于估价

> **实况:货代今天【就在】`suppliers` 表里,而且是已上线的路径。**
> `freight_documents.supplier_id` 是 **NOT NULL 外键 → suppliers**,
> 并且 `ap_open_items` 有一支 `doc_kind = 'freight'`。

因此"货代不进 suppliers"不是新规矩,是**推翻现状**。价钱:

* **应付链整条以 `supplier_id` 为键。** `ap_open_items`(三类单据 UNION)、
  `payment_allocations`、`prepayment_applications`、账龄、以及外币重估的口径,
  全部认这把键。货代换一张表 = 这条链要么**再分叉一支**,要么**换成多态键**。
* **具体的会计后果(scope 点名要的那一条):运费会变成一笔"付给非供应商的应付"。**
  今天它不是 —— 今天它就是一笔供应商应付,和入库单据、费用单并排躺在同一个账龄里。
  拆出去之后,**应付账龄要么少了一类,要么要在两个主数据域之间做 UNION**;
  付款、预付冲抵、外币重估每一处都要跟着分叉。
* **真正卡住的列(收窄后只报这些):** `suppliers.id`(应付链的键)、
  `payment_terms`(账龄起算)、`currency` 相关(外币重估口径)。
  联系人、合规状态那些**不卡链**,复制或共享都行。

**没有裁定权的部分:** 是否值得为"货代不是供应商"这条概念上的干净,
换来应付链分叉 —— 那是 Tim 的判断。本条只报价。

### B4 · 已经存在、可以承载新东西的结构

* **单据签发族(只增不改 + `sha256`):** `so_issues`、`po_issues`、`qt_issues`、
  `invoice_issues`、`cn_issues`、`shipment_issues`、`traceability_report_issues`。
  形状统一:`version` + `file_path` + `sha256` + `issued_at/by` + `UNIQUE(doc, version)`。
  **提单、装箱单、Basel 转移文件、危险品申报都是"发出去的一份具体版本",与这个形状同型。**
* **通知中心:** `notifications` + `notification_reads`(已读是**每人一行**,不是布尔位)。
  里程碑到期、单据缺失都能挂上去,不需要新机制。
* **分摊:** `freight_documents.allocation_basis` ∈ (weight / value / stated) +
  `freight_document_lines` + `batch_freight_base()` —— **落地成本分摊已经有实现**。
* **差异陈述:** `grn_discrepancies` 是"把差说出来、不拒绝"的现成范式。
* **合规证书:** `docs/compliance-scoping.md` 已把 Basel/TFS 定为**交易级**、
  一次发运一套、并点名 `po_issues` 作先例。

### B5 · 钱链 —— 今天在哪里断

**入库方向是通的:** 运费单据 → `fx_rate` 锁在单据上 → `amount_base` →
分录 → `ap_open_items` 的 freight 支 → 付款/预付冲抵 → 外币重估。

**断点:**

1. **报价(quote)没有任何落点。** 系统里没有"货代报了多少"这个对象,
   所以**报价 vs 实际运费的差异无处比对**。
2. **出口运费无处可去。** `freight_document_lines.inbound_batch_id` 是 NOT NULL 且只认入库批。
   一笔出口运费今天**没有单据类型可用**。
3. **暂估缺位**(A4.2):发票晚到,期间会错。
4. **滞期费缺位**(A4.3):封账之后才来的费用没有归属。

**汇率在哪里锁 —— 逐段:**

| 段 | 今天锁在哪 |
|---|---|
| 报价 | **无对象,无锁点** |
| 实际运费单据 | `freight_documents.fx_rate`(单据自带,`amount_base = round(amount_ccy × fx_rate, 2)`) |
| 应付余额 | 按单据的 `amount_ccy` + 币种进 `ap_open_items`,**余额留在外币** |
| 付款 | `payment_allocations`,按付款日的率结算 |
| 期末 | `revalue_foreign_balances()` / `preview_revalue_foreign_balances()` |

**结算与重估机器能不能原样复用:能** —— 只要运费仍然是**一笔供应商应付**。
它已经在 `ap_open_items` 里,重估读的就是那张视图的外币余额。
**唯一会让它不能复用的,是 B3 那个决定**:货代若不再是 supplier,
这条链就不再认得它,那时要么分叉、要么改键 —— 不是"机器不行",是**键被抽走了**。

### B6 · 危险品跨境文件

* **可查证的:** Basel/TFS 已被定为**交易级**——`docs/compliance-scoping.md:140`:
  "一次物理发运一套文件,生命周期 通知 → 同意 → 转移 → 处置确认",
  自然外键落在批次上,先例是 `po_issues`。这与 scope 说的
  "与提单、装箱单同属一套文件、不是两套"**一致**。
* **无法查证的:** **`危废转移联单` 在仓库里搜不到。**
  排队的是另一件事(`exec-views-plan.md:48`:危废**存储天数** vs 牌照时限,
  因 NEA 牌照未到而 PARKED)。
* **结论:未知。** 它是不是同一件事,系统与文档**没有给出依据**。
  按 scope 自己的要求:**答未知,不选。**

### B7 · 哪个重量说了算

| 重量 | 今天存在吗 | 谁用 |
|---|---|---|
| 供应商申报量 | **有** —— `inbound_batches.declared_qty`(NULL = 没记过,永不推断) | 采购/收货比对 |
| 我们的磅秤量 | **有** —— `inbound_batches.quantity` | **入账、且喂追溯与回收率** |
| 差异 | **有家** —— `grn_discrepancies`(**陈述,不拒绝**) | 人判断 |
| 出库发运量 | `shipment_lines.qty`(=预留量) | 入账 + 追溯 |
| 货代磅单量 | **无处可存** | — |
| 客户回称量 | **无处可存** | — |

**今天入账与追溯用的是同一个数**(入库:我们的磅秤;出库:预留量)。

**若一直不裁定的后果(scope 问的那一条):**
出库侧只有一个数,任何运输途中的损耗一旦被记进来,**只能记进批次量本身** ——
于是**运输差异会直接污染回收率**:一批料的产出/投入比会因为路上少了两吨而变难看,
而那两吨根本不是加工损失。入库侧不会有这个病(申报与磅秤是**两列**,差异有独立的家);
**出库侧没有第二列,所以它没有免疫力。**

### B8 · 基数(cardinality)

* **schema 允许的:** 一张 `shipments` → 多条 `shipment_lines`;
  每条 line → **恰好一个** `output_batch_id`、**恰好一条**预留(`reservation_id` **UNIQUE**)、
  一条 `sales_record_id`。所以 **一次发运 : 批次 = 一对多**。
* **一张发运只能属于一张订单**(`sales_order_id` NOT NULL,单值)——
  **跨订单合并装运在 schema 层就不可表示。**
* **app 今天做的:** 与 schema 一致,没有更窄。
* **对第 3 层的影响:** 文件挂在**发运**上是自然的(`shipment_issues` 已是这个形状);
  但**一个集装箱装两张订单的货**今天**表示不出来** —— 若真实业务会这样,
  这是第 3 层之前要先解决的形状问题,不是文件挂载方式的问题。

### B9 · 谁来读(拆成可答的一半)

**可查证的:** `docs/exec-views-plan.md:18` —— **物流 HC 在 CCO(Sandra YAP)那里**,
与客户履约、质量体系并列,并注明这是**客户的要求**,不是内部偏好。
**"仓库在运营线下"与"一个横跨两边的 lead"在仓库里查无实据。**

**现有权限形状逼出什么:** 这套模型是**按模块**发码的
(`module.<x>.view` / `.edit`),数据类另有 `data.*`。因此:
* 若物流跟**商务**线,它天然与销售/客户履约同域,发运单据的读权与销售重叠;
* 若物流跟**运营**线,它与仓库/加工同域,而**发运单据的收入期间含义会落在运营手里**。

**不作裁定。** 没有人在岗,scope 也禁止建码 —— 而这条要按【谁为发运日的会计后果负责】
来定,不是按谁离仓库近。那是 Tim 的判断。

### B10 · 时序与暂估(新增)

* 发票晚于发运,而 `PERIOD_LOCKED` 是硬的、且"决定期间的日期永不默认"是本库的明规矩;
  **今天没有运费暂估对象**,所以晚到的发票只能落进它到达的那个期间。
* 滞期/滞箱费在结清之后才来 —— **今天没有"重开一张已结运费"的路径**,
  `freight_documents.status` 只有 `posted` / `reversed`。

### B11 · incoterm 与"谁付运费"(新增)

* `incoterm` 在 `customers` / `suppliers` / `purchase_orders` / `invoices` 上,
  **自由文本、无 CHECK、不在 `shipments` 上**。
* 它决定的是**这笔运费是不是我们的应付** —— EXW 与 CIF 下答案相反。
* 今天没有任何检查把 incoterm 与运费单据关联起来:
  **一笔本该由对方承担的运费,系统不会拦。**

---

## 只有 Tim 能回答的问题(附:不答时的默认)

1. **货代到底进不进 `suppliers`?** 它今天**已经在里面**(`freight_documents.supplier_id`
   NOT NULL → suppliers,且 `ap_open_items` 有 freight 支)。
   *不答的默认:维持现状,货代仍是 supplier,应付链不分叉。*
2. **出口运费用哪张单据?** `freight_document_lines` 今天只认入库批。
   *不答的默认:出口运费无处入账,继续手工在账外处理。*
3. **客户回称重量要不要有家?** 出库侧只有一个数。
   *不答的默认:不建,运输差异继续会污染回收率(B7)。*
4. **一个集装箱能不能装两张订单的货?** 今天 schema 表示不出来。
   *不答的默认:不能,一次发运仍绑一张订单。*
5. **`危废转移联单` 与 Basel/TFS 是同一套还是两套?** 仓库里查无此项。
   *不答的默认:按 `compliance-scoping.md` 已定的交易级 Basel/TFS 一套处理,
   境内转移另议。*
6. **运费录入归物流还是财务?** B2 的判据在这一项上两半打架。
   *不答的默认:留在财务(它是一张带分录的凭证)。*
7. **物流权限跟商务线还是运营线?** 组织架构在仓库里无法核对。
   *不答的默认:跟商务(`exec-views-plan.md:18` 是唯一有据的一句)。*
8. **要不要运费暂估?** 没有它,晚到的发票落错期间。
   *不答的默认:不做,接受期间错配。*

---

# 第 3 层勘察:发运单据的地基(LOG-2-SURVEY)

**READ ONLY,2026-08-19。** 只报告现状,不提议。
本节存在的理由是一句已经裁定的话:**Tim 确认一个集装箱可以装两个客户的订单** ——
而今天 `shipments.sales_order_id` 是 `NOT NULL` 的单值。下面把改这件事的价钱摊开。

## 1 · shipments 与 shipment_lines 的现状

**`shipments`**(SO-3b):`id` · `code`(`SHP-YYYY-NNNN`,无缝,自己的咨询锁)·
**`sales_order_id uuid NOT NULL REFERENCES sales_orders(id)`** · `ship_date date NOT NULL` ·
`notes` · `created_at` · `created_by`。
索引 `idx_shipments_order (sales_order_id, ship_date)`。
触发器 `trg_shipments_append_only`(BEFORE UPDATE OR DELETE → `guard_shipment_append_only()`)。
RLS:**只有 SELECT 策略**,没有 INSERT/UPDATE/DELETE —— 唯一写入口是 `ship_order`
(DEFINER,`module.sales.edit`)。抬头写着这是前提不是遗漏。

**`shipment_lines`**:`shipment_id`(ON DELETE RESTRICT)· `sales_order_line_id` ·
**`reservation_id UNIQUE`** · `output_batch_id` · `location_id` · `qty > 0` · `sales_record_id`。
同样只增不改,同样只有 SELECT 策略。
**一行 = 消耗掉一条【整条】预留**,`qty` 恒等于那条预留的全部数量 —— 这条不变量
让「committed 桶 = Σ 活预留」成立。

**读 `shipments.sales_order_id` 的函数:**
* `ship_order()` —— 写入它,并用它校验每条预留确实属于这张单;
* `sales_order_fulfilment_status()` —— **整个判据就架在它上面**(见 §3)。

## 2 · `sales_order_id` 的读者(逐个文件)

**库这一侧(迁移历史除外)——3 处:**
| 文件 | 怎么用 |
|---|---|
| `db/tables/shipments.sql` | 列定义 + 索引 |
| `db/functions/ship_order.sql:67` | INSERT,并比对预留归属 |
| `db/functions/sales_order_fulfilment_status.sql:22` | `WHERE s.sales_order_id = p_sales_order_id` |

**fixture ——2 个文件 4 处:** `68-shipment-turns-liability-into-revenue.sql`(:337, :346)、
`69-a-line-remembers-what-it-already-shipped.sql`(:156, :252)。

**app ——【零处直接读它】,但有两处经它取客户:**
`app/sales/shipments/[id]/pdf/route.ts:26` 走
`sales_orders ( code, customers ( code, legal_name ) )` 拿客户抬头;
`app/sales/orders/[id]/ShippingSection.tsx:84` 按订单反查发货单。
`app/sales/shipments/[id]/page.tsx` 读单头。

**合计:库 3 + fixture 4 + app 3 = 10 个必须走访的点位。**
比"到处都是"少得多 —— 因为 `sales_order_id` 从一开始就只被两个函数用。

## 3 · ship_order 与「这张单发完了没有」

`ship_order(p_sales_order_id, p_ship_date, p_lines)` 一次建一张单头 + N 行,
每行必须坐在一张**在册且已过账**的订单流发票上(派生检查,不是状态位),
并按那张票**存下来的汇率**释放合同负债。

完成度判据(`sales_order_fulfilment_status`)今天是:

```sql
sum(sl.qty) FROM shipment_lines sl JOIN shipments s ON s.id = sl.shipment_id
 WHERE s.sales_order_id = p_sales_order_id
>= sum(l.quantity) FROM sales_order_lines l WHERE l.sales_order_id = p_sales_order_id
```

**一张发货单跨两张订单之后,这条 SQL 就问错了对象。**
可用的替代真源【已经在行上】:`shipment_lines.sales_order_line_id → sales_order_lines.sales_order_id`。
也就是说完成度应当从**行**往上数,而不是从**单头**往下数。
这不是新增数据,是换一个 JOIN —— 那条 FK 从 SO-3b 起就在。

## 4 · ship_date 与会计期间

`ship_date` 在 `ship_order` 里被用了 **6 次**,其中 3 次是 `post_journal_entry(p_ship_date, …)`
(收入侧 + COGS 侧),1 次喂 `next_shipment_code(p_ship_date)`,1 次进单头,1 次进返回的 jsonb。
app 侧 4 处都是**显示**(详情页、送货单 PDF、订单页发运区),不参与记账。

**关键:`post_journal_entry` 今天【每张发货单调用一次】,拿的是单头那一个日期。**
只要「一次物理离场 = 一个日期」成立,跨两张订单本身不会让期间出错 ——
两张订单的收入落进同一个期间,而它们本来就是同一天离场的。
**会出错的是另一种形状**:如果"发货单"将来变成一个跨两天装载的集装箱,
单头那个日期就不再是每一行的收入日期了。见 §7 的第三个岔口。

## 5 · 线上数据

```
SHP-2026-0001 · 2026-08-14 · SO-2026-0001 · Test Customer-2 · 1 行
```

**全库只有一张发货单、一行、一张订单、一个客户。**
**没有任何一行在新形状下会变得含混** —— 这次改形状不需要数据迁移。

## 6 · 单据族与号段

签发族现有七个:`so_issues` / `po_issues` / `qt_issues` / `invoice_issues` /
`cn_issues` / `shipment_issues` / `traceability_report_issues`。
形状统一:`version` + `file_path` + `sha256` + `issued_at/by` + `UNIQUE(单据, version)`。

**第七个(可追溯报告)与另外六个的唯一不同,正是本层要复用或避开的那一点:**
> 另外六个族的号在**单据本身**上(发票有 code、发货单有 code),
> 而可追溯报告**没有一张"单据"** —— 它是围着一个产出批临时组装出来的,
> 所以报告号住在签发档里。**code 属于"这个批次的报告",不属于每一版**:
> 第 1 版铸号,重发沿用同一个号(客户引用的是那个号)。

`shipment_issues` **没有 code**,因为发货单自己有 `SHP-`。
**一个"发运单据"要不要重复第七个的做法,取决于它挂在谁身上** —— 见 §7。

**号段现状(已占用):** `ASY- BS- CN- CUS- EMP- EXP- FA- FRT- IN- INV- JE- LV-
MAT- MC- OUT- PAY- PF- PO- PROC- QT- SHP- SO- ST- SUP- TASK- TRC- WO-`。
序列共 10 条,其中 `shipment_code_seq` 归发货单。
**空着的、语义贴切的:`CTR-`(集装箱)、`BL-`(提单)、`MF-`(舱单)、`CNS-`(consignment)。**
**`CN-` 已被贷项凭证占用**,所以 `CNS-` 虽然空着,但与它只差一个字母 —— 视觉上会撞。

---

## 这块地基暴露出来的三个岔口(不提议,只把问题和赌注写清楚)

**岔口一:一个集装箱装两张订单,到底改成什么形状?**
(甲)`shipments` 直接与订单**多对多** —— 去掉 `sales_order_id`,订单从
`shipment_lines → sales_order_lines.sales_order_id` 推出来;
(乙)在 `shipments` **之上**加一层(集装箱/consignment),一张发货单仍然一张订单,
两张发货单共用一个箱子。
**赌注:** 甲要走访 §2 那 10 个点位、重建 `idx_shipments_order`、把
`sales_order_fulfilment_status` 换成从行往上数,并回答"送货单 PDF 的客户抬头从哪来";
乙一个既有点位都不用动,代价是多一层对象,而且「一次物理离场」被拆成两条记录 ——
`ship_date`、分录、`shipment_issues` 都会各有两份。

**岔口二:送货单是一张还是两张?**
今天 `shipment_issues` 没有 code,因为发货单有。
**一个箱子装着两个客户的货时,一张列着两家货的送货单,谁都不能给。**
**赌注:** 若"一张发货单 = 一个客户",甲方案就必须在文件这一层再分一次;
若送货单改为**按客户**签发,它就变成第八个签发族成员,并且要不要像第七个那样
**把号放进签发档**,取决于它挂在一个有 code 的单据上还是一个没有 code 的组合上。

**岔口三:`ship_date` 留在单头,还是下沉到行?**
今天它在单头,`post_journal_entry` 每张发货单调一次。
**只要「一次装载 = 一天」,跨订单不影响期间。** 但如果这一层的"箱子"是跨天装载的,
单头那个日期就不再是每一行的收入日期。
**赌注:** 它决定收入期间是**一次**决定还是**每行**决定 —— 而这个仓库对
"决定期间的日期"有一条硬规矩(必填、永不默认、FIN-10 一族),
下沉意味着那条规矩要在行上再实现一遍。
