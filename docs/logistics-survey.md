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

   > ★**【COMM-1 复核,2026-08-30:推迟仍然成立,但【前提已经变了】—— 记在这里
   > 而不是让那条推迟看起来没人再看过】**★
   >
   > 队列里那一行写的是「滞期费实际发生额 —— **折进物流候选清单**,第一船真货
   > 之后重排」,而它是在**免柜期还没有家**的时候写下的。今天三件事都变了:
   >
   > * **免柜期已经在【对的层级】上了。** 本文件 §2 当时点名
   >   `forwarder_details.free_time_terms` 是**自由文本、挂在货代身上、线上零行**,
   >   并断定"一个挂在货代身上的单值,对第二条航段就已经不成立"。
   >   **LOG-5a 照那个诊断修了**:`forwarder_rate_quotes.free_days`(整数,
   >   逐货代 × 逐航段 × 带有效期,线上 11 行),而且**保住了 NULL ≠ 0**
   >   —— NULL = 这份报价没写免柜期,告警**保持沉默**;0 = 零个免费天,**第一天就该响**。
   >   **§2 那条反对意见到此为止,它已经被兑现了。**
   > * **系统已经在【说】滞港费正在发生。** 看板第 **23** 支 `free_time_expiring`
   >   在剩余免柜天 **≤ 2(含负数)** 时响,负数那一段的措辞就是"已经在产生滞港费";
   >   而且它经 `arm_permission_widen` **放宽给了 `module.finance.view`** ——
   >   理由白纸黑字:**滞港费是钱的事**。
   > * **一笔滞港费【今天就记得下来】。** `expenses` 是一张完整的应付单据:
   >   `expense_date`(**必填、永不默认**,`EXPENSE_DATE_REQUIRED`)、科目、
   >   金额与币种与汇率、`supplier_id`(收款方就是那家货代)、过账、冲销、税与 WHT。
   >   **不需要新建任何表就能记下"哪一天、被charge了多少"。**
   >
   > ★**所以缺的【不是一个写下来的地方】。缺的是一条【会计裁定】:**★
   > **进项滞港费要不要像运费那样【进落地成本】(`docs/landed-cost-scoping.md` /
   > `freight_documents.allocation_basis` 那一套),还是当期费用?**
   > 两个答案会走向两套不同的建法,而**这一条没有人裁过**。
   > COMM-1 因此**一行都没有建**,并且**刻意不在代码里替它作答** ——
   > 与 PRICE-1 对 §9(采购侧指数联动)的处置逐字相同:
   > **一条被暗示的裁定,比一个敞着的问题坏。**
   >
   > **触发条件原样保留:第一船真货。** 而在它到来之前,真收到一笔滞港费的人
   > **记一张 `expenses` 就是对的**,不必等这一刀。
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

---

# 第 4 层勘察:出口运费的钱去哪儿(LOG-3-SURVEY)

**2026-08-20,只读。** 本节没有改动任何代码、任何数据库对象、任何数据。
勘察基线:`HEAD = 6d78893`(LABEL-FIX:集装箱号的英文标签改为 Container number),
工作区干净。所有"线上"数字来自 Management API 的实时查询,所有结构断言都同时
对过【镜像文本】与 `information_schema` / `pg_catalog`。

## 0 · 一处命名更正(先说,免得后面每一句都要绕)

brief 里的 `freight_document_lines` **这张表不存在**。分摊行叫
`public.freight_allocations`。镜像也不是单独一个文件 —— 两张表都住在
`db/tables/freight_documents.sql` 里(文件头第一行就写着
`-- db/tables/freight_documents.sql + freight_allocations`)。
下文一律用真名。

---

## 1 · `freight_documents` 与 `freight_allocations` 的原样

### 1.1 两张表的列(线上 = 镜像,逐列比对无漂移)

`public.freight_documents`,19 列,attnum 顺序:

| # | 列 | 类型 | 空 | 默认 |
|---|---|---|---|---|
| 1 | `id` | uuid | NOT NULL | `gen_random_uuid()` |
| 2 | `code` | text | NOT NULL | — |
| 3 | `doc_date` | date | NOT NULL | — |
| 4 | `supplier_id` | uuid | NOT NULL | — |
| 5 | `amount_ccy` | numeric | NOT NULL | — |
| 6 | `currency` | text | NOT NULL | — |
| 7 | `fx_rate` | numeric | NOT NULL | — |
| 8 | `amount_base` | numeric | NOT NULL | — |
| 9 | `allocation_basis` | text | NOT NULL | — |
| 10 | `payment_status` | text | NOT NULL | — |
| 11 | `bank_account_code` | text | NULL | — |
| 12 | `notes` | text | NULL | — |
| 13 | `journal_entry_id` | uuid | NULL | — |
| 14 | `status` | text | NOT NULL | `'posted'` |
| 15 | `deleted_at` | timestamptz | NULL | — |
| 16 | `created_at` | timestamptz | NOT NULL | `now()` |
| 17 | `created_by` | uuid | NULL | `auth.uid()` |
| 18 | `updated_at` | timestamptz | NOT NULL | `now()` |
| 19 | `updated_by` | uuid | NULL | `auth.uid()` |

**这张表上没有任何一列指向集装箱、发运单、航段或销售订单。** 第 6 节全部建立在这一条上。

`public.freight_allocations`,8 列:
`id` / `freight_document_id`(NOT NULL)/ `inbound_batch_id`(NOT NULL)/
`amount_base`(NOT NULL)/ `basis_qty`(NULL)/ `in_stock_ratio`(NOT NULL)/
`created_at`(NOT NULL)/ `created_by`(NULL)。

### 1.2 外键 —— 全部五条,一条不漏

出去的(本族 → 别人):

* `freight_documents.supplier_id → suppliers(id)`(无 ON DELETE 子句)
* `freight_documents.currency → currencies(code)`
* `freight_documents.journal_entry_id → journal_entries(id)`
* `freight_allocations.freight_document_id → freight_documents(id) ON DELETE RESTRICT`
* `freight_allocations.inbound_batch_id → inbound_batches(id)`

进来的(别人 → 本族),只有两条:

* `freight_allocations.freight_document_id`(同上)
* `payment_allocations.freight_document_id → freight_documents(id)`(FIN 侧的核销去处)

**注意 `supplier_id` 的 FK 上没有"必须是货代"的约束。** 货代身份在
`containers.forwarder_id` 和 `forwarder_rate_quotes.supplier_id` 上都由触发器守着
(`guard_container_forwarder` / `guard_forwarder_rate_quote`,两者都按名拒:
`CONTAINER_FORWARDER_NOT_A_FORWARDER` / `RATE_QUOTE_VENDOR_NOT_A_FORWARDER`),
**唯独运费单没有**。FRT-1 早于 LOG-1a 的 `counterparty_type`,这是时间差留下的一个
不对称,不是一个决定。

### 1.3 触发器与守卫 —— 只有一个

```
CREATE TRIGGER trg_freight_documents_updated_at BEFORE UPDATE ON public.freight_documents
    FOR EACH ROW EXECUTE FUNCTION update_updated_at()
```

`freight_allocations` 上**一个触发器都没有**。所以:

* 分摊行**不是 append-only**(与 `container_milestones`、`payment_allocations` 不同 ——
  后者有 `trg_payment_allocations_immutable` 明确 `ALLOCATION_IMMUTABLE`);
* `status` 的 `'posted' → 'reversed'` **没有状态机守卫**,只有 CHECK 约束;
* 软删 `deleted_at` **没有 provenance 守卫**(`guard_soft_delete_provenance` 存在,
  但没挂在这张表上),也没有 `delete_reason` / `deleted_by` 两列可写。

CHECK 约束共 7 条(线上原文):`amount_ccy > 0`、`fx_rate > 0`、
`allocation_basis IN ('weight','value','stated')`、`payment_status IN ('paid','unpaid')`、
`bank_account_code IN ('1000','1010')`、`status IN ('posted','reversed')`,
以及形状约束 `freight_documents_payment_shape`(已付必有银行科目 / 未付必无)。
分摊行两条:`amount_base >= 0`、`in_stock_ratio BETWEEN 0 AND 1`,
加一条 `UNIQUE (freight_document_id, inbound_batch_id)`。

**冲销路径不存在。** 全库没有 `reverse_freight_document`;`status = 'reversed'`
是一个只能被手工 UPDATE 写进去的值,而那条 UPDATE 除了 `updated_at` 之外没有人看着。
(对照:`reverse_expense`、`reverse_payment`、`reverse_journal_entry` 都有。)

### 1.4 过账路径

**唯一的写入口是 `record_freight_document(...)`**(`SECURITY DEFINER`,
`search_path = public, pg_temp`,进门第一句 `require_permission('module.finance.edit')`)。
它调 `post_journal_entry(p_doc_date, 'Freight ' || v_code, 'freight', v_doc_id, v_lines)`。
`'freight'` 是 `journal_entries_source_type_check` 里 21 个允许值之一。

分录的科目,原样:

* **借 `1200`**(存货-原料)—— 金额 = Σ `round(share × in_stock_ratio, 2)`,
  行备注 `'freight — in-stock share'`,币种恒为本位币;
* **借 `5000`**(材料成本 / COGS)—— 金额 = 单据金额 − 上面那笔,
  行备注 `'freight — consumed share'`,币种恒为本位币;
* **贷 `1000` 或 `1010`(已付)/ `2000`(未付)** —— 金额是
  **单据币种的 `amount_ccy`**,带 `fx_rate`,行备注 `'freight payable — forwarder'`。

两条借方任一为 0 时那一行**不发**(`IF round(...) <> 0`),不是发一条零行。

取整误差**归到最后一批**:`v_alloc_tot <> v_base` 时 UPDATE 最后一条分摊行补差,
并重算在库/已耗两半 —— 分摊之和【等于】单据金额,不是约等于。

### 1.5 `fx_rate` 在哪里锁

在 `record_freight_document` 内,**单据落地之前**:

```
IF p_currency = base_currency_code() THEN v_fx := 1;
ELSE v_fx := fx_rate_for(p_currency, p_doc_date, 'tt_sell'); END IF;
v_base := round(p_amount * v_fx, 2);
```

三件事各自要紧:

1. **锚是 `doc_date`,不是今天** —— 与 FIN-10 一族同规矩,日期决定期间【和】汇率;
2. **口径是 `tt_sell`**(行方卖出价),理由写在函数注释里:我们付钱出去;
3. **锁在凭证上,不锁在报价上** —— `forwarder_rate_quotes` 的表注释明写
   「汇率在这里【不锁】:报价只带币种,锁率发生在实际运费凭证上」。
   第 6 节的"实际 vs 报价"因此**天然是一个跨汇率的比较**,而不是两个数直接相减。

缺率即拒:`fx_rate_for` 抛 `FX_RATE_MISSING`,已在 `freightErrorCodes.ts` 的具名集合里。

### 1.6 反问:`inbound_batch_id NOT NULL` 是不是唯一的绑定?

**不是。** 除了那条 NOT NULL + FK,还有【六】条把这一族钉死在进料侧,
每一条都要单独拆:

1. **RPC 的入参形状**:`p_allocations` 为 NULL / 非数组 / 空数组 → `FREIGHT_NO_BATCHES`;
   每个元素都必须解析成一行活着的 `inbound_batches` → 否则 `INBOUND_NOT_FOUND`。
   **一张不指向任何进料批的运费单,今天根本造不出来。**
2. **分摊数学的读数全部来自 `inbound_batches`**:`quantity`(weight 口径)、
   `quantity × unit_price`(value 口径)、`unit`(混合单位拒收)、
   `remaining_qty`(拆账比例)。三个口径没有一个是形状无关的。
3. **借方的拆分口径是进料批的在库比例**:`in_stock_ratio = remaining_qty / quantity`,
   在库进 1200、已耗进 5000。**这不是一个 FK,这是借方科目本身的形状** ——
   出口运费没有"这批货还剩多少在库"这个概念可读。
4. **唯一的读者签名是进料批**:`batch_freight_base(p_inbound_batch_id uuid)`。
5. **加工侧的过期判定**:`processing_run_allocation_status` 把
   `freight_allocations → processing_inputs.inbound_batch_id` 连起来,
   迟到的运费把吃过那批货的加工单标为 stale。
6. **RLS 的读权限带着进料模块**:两张表的 SELECT 策略都是
   `has_permission('module.inbound.view') OR has_permission('module.finance.view')`。
   出口运费给进料模块看,没有理由。

**结论:进料绑定有七处,FK 只是其中最容易看见的一处。**

---

## 2 · `allocation_basis` 与 `batch_freight_base()`

### 2.1 「`allocation_basis`」是**两个不同的词表共用一个列名**

线上三条 CHECK,原文:

| 表 | 允许值 |
|---|---|
| `freight_documents` | `weight` / `value` / `stated` |
| `processing_runs` | `weight` / `metal_value` |
| `finance_settings.default_allocation_basis` | `weight` / `metal_value` |

`finance_settings.default_allocation_basis` 线上是 `metal_value` ——
**它只喂加工单,与运费无关**。运费那一列 FIN-36 起【逐单申报、没有 schema 默认值】,
这条不能被"反正 finance_settings 里有个默认"顺手推翻。
`stamp_allocation_basis_changed()` 触发器同理:它挂在 `processing_runs` 上,
不在运费单上。

### 2.2 `batch_freight_base()` 的全部调用方

```sql
CREATE OR REPLACE FUNCTION public.batch_freight_base(p_inbound_batch_id uuid)
RETURNS numeric LANGUAGE sql STABLE   -- FRT-1 fu2 起 SECURITY INVOKER
SELECT COALESCE(SUM(fa.amount_base), 0) FROM freight_allocations fa
  JOIN freight_documents fd ON fd.id = fa.freight_document_id
 WHERE fa.inbound_batch_id = p_inbound_batch_id
   AND fd.deleted_at IS NULL AND fd.status = 'posted';
```

全仓搜索,**生产代码里只有一个调用方**:

* `db/functions/allocate_processing_costs.sql:110` —— 材料成本口径
  `unit_price + batch_freight_base(ib.id) / ib.quantity`,把落地成本带进产出批的
  `unit_cost_base`,再经 `batch_margin` 到毛利。

其余命中都不是调用:`db/migrations/2026-08-11-frt1c-*.sql`(同一段代码的迁移原文)、
`db/migrations/2026-08-11-frt1-fu2-*.sql`(改 INVOKER)、
`lib/database.types.ts:15632`(生成的类型)。

**没有任何页面调用它。** 落地成本在屏幕上不是一个可以直接读到的数字 ——
它只以"产出批单位成本"的形式间接现身。

### 2.3 分摊数学是 inbound-specific,不是 shape-agnostic

逐条:

* `weight` → `inbound_batches.quantity`,并且跨不同 `unit` 直接拒
  (`FREIGHT_MIXED_UNITS`,不是近似);
* `value` → `quantity × unit_price`,遇 `unit_price IS NULL` **点名拒**
  (`FREIGHT_BATCH_UNPRICED`)—— 理由写在函数里:给零份额等于把它那份悄悄摊给别人;
* `stated` → 人直接列明,必须**正好**加总到单据金额(`FREIGHT_STATED_SUM_MISMATCH`),
  `basis_qty` 留空;
* 三个口径之后,**无条件**再按 `remaining_qty / quantity` 拆一次 1200/5000。

**只有 `stated` 这一个口径在数学上与"被分摊的东西是什么"无关。**
另外两个口径 + 拆账那一步,全部是进料批的形状。

---

## 3 · `docs/landed-cost-scoping.md` 对本层的约束

那份文件 79 行,四节。**它已经定下、并且约束第 4 层的**:

1. **运费资本化进批次成本,是"第二个成本组件",绝不并进 `unit_price`。**
   原文:「那是应付之锚,并进去等于让系统以为欠材料供应商更多钱,而运费欠的是货代」。
2. **未付运费即成为一张应付单据**,原文点名
   「`ap_open_items.doc_kind = 'freight'`」。
3. **资本化的代价被明写为一条判据**:
   > 资本化之后,一次错的分摊【藏在存货里】,而不是显示在损益表上。
   > 费用化的错误看得见,资本化的错误看不见。
4. **关税不是"另一种分摊口径"**:
   > 关税是按【那一批货】的完税价格课的,而且税率常常随材料而异。
   > 所以在一张混装货上把它分摊出去【是错的】,不是"换一个口径"。
   > **不要因为"都是落地成本"就把它接进运费的表单。** 运费的表单允许分摊,
   > 而关税允许分摊就是允许出错。
5. **进口 GST 永远不资本化**:
   > 进口 GST 是【可抵扣的进项税】(科目 1400),它永远不资本化。
   > 资本化它会同时高估存货【并】毁掉抵扣。
   登记之后的走法也已写死:「GST 部分单独借 1400、**不参与任何分摊**,只有净额进 1200/5000。
   那时这道闸门从"一律拒收"改成"拆出来",而不是"放行"」。
6. **保险悬而未决,且不许被读成有结论** —— 按航次投保与年度保单是两种形状,
   Tim 没答之前【不建】。

### 3.1 出口运费**不是**落地成本 —— 盲目复用会把它资本化的三条具体路径

这份文件通篇假设"运费 = 进货运费"。它**从未讨论过出口运费**,
所以下面三条不是它写错了,是它不适用而形状又恰好接得上 —— 这才是危险处:

* **路径 A(最直接)**:用 `record_freight_document` 记一张出口运费单。
  它的借方**写死**是 `1200` / `5000` 两选,没有第三条分支。
  出口运费于是【一定】进存货或材料成本,没有任何拒绝会响。
* **路径 B(最隐蔽)**:`allocate_processing_costs:110` 把
  `batch_freight_base(ib.id) / ib.quantity` 加进材料成本。
  只要那张出口运费单挂在任何一个还会被投料的进料批上,
  出口运费就会**穿过加工单进入产出批的 `unit_cost_base`**,
  再经 `batch_margin` 抬高"成本"、压低毛利 —— 而且是对**别的**订单。
  这正是那份文件自己说的"藏在存货里的错误",只是主语换了。
* **路径 C(会计口径)**:`batch_margin` 的 `cogs_posted_base` 是按
  `accounts.account_type = 'cogs'` 抓 `journal_lines` 加总的。
  出口运费若落在任何一个 `cogs` 科目上(`5000`–`5200` 全是),
  它就会被算进**那张销售记录**的已过账 COGS —— 不管它是不是那一票货的运费。

**另有一条不属于"资本化",但同样是盲目复用的账**:
`record_freight_document` 的 GST 闸门(`FREIGHT_GST_NOT_CAPITALISABLE`)
是照着"运费资本化"这个前提写的。出口运费如果费用化,
那条闸门的措辞("不可资本化")对它就不成立 —— 出口服务多半 zero-rated,
那是**另一个理由**得出的同一个动作。复用那句拒绝,等于把对的结论配上错的理由。

---

## 4 · 科目 —— 今天有什么,缺什么

线上 `accounts` 共 **44** 行。与本层相关的:

### 4.1 出口运费能落在哪

**只有一个现成的**:

| 科目 | 名 | 类型 | is_monetary | is_system | is_active |
|---|---|---|---|---|---|
| `6300` | Transport & Logistics / 运输物流费 | `expense` | false | **false** | true |

`6300` 是**建账的人的地盘**(`db/tables/accounts.sql:121` 明写:
「6300/6400/6500/6600/6900【故意不在这里】:它们是建账的人的地盘」),
即 `is_system = false`,可以停用、可以改名。
全仓只有一处代码提到它:`db/fixtures/77-*.sql:132`,一次 `record_expense` 的固定装置。
**生产路径上没有任何一处往 `6300` 过账。**

`expenses.account_code` 是对 `accounts(code)` 的裸 FK(没有 `account_type` 限制),
所以**今天就能**用 `record_expense(..., '6300', ...)` 把一张出口运费单记成
普通挂账开支,贷 `2000`,并自动出现在 `ap_open_items` 的 `expense` 支上。
**这条路今天是通的** —— 它换来的是:没有集装箱/航段的引用、没有与报价的比较、
没有"这一票货的运费"这个概念。

### 4.2 缺什么

* **没有销售/分销费用分组**。`6000`–`6900` 是一个平的行政费用带
  (租金、工资、公积金、福利、水电、运输物流、专业服务、银行手续费、折旧、杂项)。
  出口运费若要与"卖东西的成本"区分开,今天没有一个位置说它是分销费用而不是行政费用。
* **没有关税科目**。44 行里一条都没有(`duty` / `customs` / `关税` 零命中)。
* **`5000`–`5200` 全是 `cogs`**,且 `5100`–`5190` 全部被"加工成本"占满
  (人工/电力/气体/折旧/耗材/废物处理/其他),`5200` 是存货调整损益。
  **`cogs` 段里没有一个空位天然属于"出口运费"**,而借用任何一个都会被
  `batch_margin` 的 `account_type = 'cogs'` 汇总抓走(见 3.1 路径 C)。

### 4.3 关税与进口 GST 今天记在哪 —— 哪儿都没有

* **关税**:**没有科目、没有表、没有列、没有函数、没有一行数据。**
  `docs/landed-cost-scoping.md` 第二节把它的形状写下来了,但**一个对象都没建**。
* **进口 GST**:科目 `1400`(GST Input Tax,`asset`,`is_monetary = true`,
  `is_system = false`)**存在**,并且 `2026-08-04-fin3-fu2-chart-bootstrap.sql`
  专门把它和 `2100` 标成货币性(所以它**会**被 `revalue_foreign_balances` 重估)。
  但全仓搜索 `'1400'`:**只有三处命中,全是科目表的定义与 bootstrap,
  没有任何一处过账。**
* 线上 `finance_settings`:`gst_registered = false`、`gst_rate_pct = 0`、
  `gst_registration_no = null`。
* 承载它们的对象:**没有。** 今天唯一提到进口 GST 的生产代码是
  `record_freight_document` 里那道**拒绝**(`FREIGHT_GST_NOT_CAPITALISABLE`),
  它不承载 GST,它只是不让 GST 进来。

**所以 brief 第 4 问的答案是:关税与进口 GST 今天没有任何去处,
一个"路由到不同收款方"的层要连它们的容器一起造,而不是接进一个已有的容器。**

---

## 5 · `ap_open_items.doc_kind` —— 线上、代码里、以及加一种会撞到什么

### 5.1 现状

`ap_open_items` 是**视图**(不是表),`security_invoker = off`,
整表挂 `has_permission('module.finance.view')`,三支 UNION ALL:

| `doc_kind` | 来源 | 应付额 |
|---|---|---|
| `inbound` | `inbound_batches_masked`(已计价、在册) | `quantity × unit_price` − 付款核销 − 预付冲抵 |
| `expense` | `expenses`(unpaid + posted,排除冲销镜像行) | `amount_base` − 核销 |
| `freight` | `freight_documents`(unpaid + posted + 未软删) | `amount_base` − 核销 |

三支都带 `counterparty_kind` / `counterparty_id` / `counterparty_name`(PAYEE-1a),
运费支恒为 `'supplier'`。行的存在判据是 `open_ccy > 0`。

标签在 `messages/{en,zh}.ts` 的 `finance.docKind.*`:
`inbound` / `expense` / `freight` / `sale` / `invoice` 五个都在。

### 5.2 加一种(或复用 `'freight'`)会触到什么

**账龄 —— 自动跟上,不用改。**
`days_outstanding` 与 `bucket`(`b0_30` / `b31_60` / `b61_90` / `b90_plus`)
在最外层按 `doc_date` 算,与 `doc_kind` 无关。新的一支只要给出
`doc_date` / `open_ccy` / `currency` 就落进桶里。

**重估 —— 不按 `doc_kind` 走,不用改。**
`revalue_foreign_balances` / `preview_revalue_foreign_balances` 完全不认识
`ap_open_items`;它按 `accounts.is_monetary` 逐科目逐币种算。
**决定重估行为的是贷方落在哪个科目**(`2000` 是 `is_monetary = true`),
不是 `doc_kind`。若出口运费未付走 `2000`,它自动被重估;
若走 `2200`(应计费用,也是货币性)同理。

**核销 —— 这里有一个【已经存在的】洞,加一种会把它加宽。**

`record_payment` **完全不认识运费**。全函数搜索 `freight`:零命中。
它的 XOR 是五选一:

```
num_nonnulls(v_sale_id, v_batch_id, v_expense_id, v_po_id, v_invoice_id) <> 1
    → ALLOC_INVALID
```

而 `payment_allocations` 的 CHECK 是**六**选一(含 `freight_document_id`),
`ap_open_items` 的运费支也确实按 `pa.freight_document_id` 去减已结清额。
**表和视图都准备好了,写入函数没有。**

顺着 UI 走一遍,后果是具体的:
`app/finance/payments/new/page.tsx:86` 原样读出视图的 `doc_kind`,
`NewPaymentForm.tsx:562` 把它塞进 `alloc_kind` 隐藏域;
`app/finance/payments/new/actions.ts:78-82` 只认 `expense` 与 `purchase_order`,
**其余一律落进 `else` 分支,当作 `inbound_batch_id` 送下去**。
于是选中一张未付运费单去付款,送给 `record_payment` 的是
`{ inbound_batch_id: <freight_document_id> }`,批次查不到 →
`ALLOC_INVALID|<uuid>`。

**这是一次按名拒绝,不是静默错账** —— 但它拒绝的名字指着错的东西
(说"这个进料批不合法",而人选的是一张运费单),
而且**未付运费今天在这套系统里没有任何一条路可以结清**。
线上暂时看不出来,只因为运费单一张都没有(第 7 节)。

**看板 —— 已经有一个洞。**
`operations_now` 的 `ap_over_90` 支原样透出 `ap.doc_kind`,
`app/page.tsx:132-134` 只映射 `inbound` → `/finance/payables/`、
`expense` → `/finance/expenses/`,**其余返回 `null`(不给链接)**。
`freight` 已经落在这个 `null` 里。写法本身是对的
(注释明写「认不出的种类【不给链接】,绝不猜一个 —— 猜错就是拿一个合法 uuid
开错人的单据」),但结果是:一张逾期 90 天的运费应付在看板上**有行、无门**。
`/finance/freight/[id]` 这个页面是存在的,只是没人把它接上。
再加一种 `doc_kind`,就是第三条无门的行。

**对账单 —— 没有这个东西。**
全仓没有供应商对账单(supplier statement)。`reconcile_statement` /
`import_bank_statement` 是**银行对账单**,按银行流水行匹配,不按 `doc_kind` 分支。
所以 brief 第 5 问里的"statements"这一项:**今天不存在可被触到的对象。**

**其余读者**:`/finance/payables` 页面(`app/finance/payables/page.tsx:18`)
的类型已经是 `'inbound' | 'expense' | 'freight'`,并且三支都有分支渲染 ——
加第四种要同时改类型与分支,否则新种类会落进它的兜底。

---

## 6 · 比较之锚 —— "实际运费 vs 这条航段的报价"要哪些 join,以及缺什么

### 6.1 两端今天的形状

**报价端**(`forwarder_rate_quotes`,LOG-1a):
`supplier_id`(必须是货代,触发器守着)+ `lane_id` + `amount_ccy` + `currency`
+ `valid_from` / `valid_to`。同一家 × 同一航段**有效期不许重叠**
(`FORWARDER_RATE_QUOTE_OVERLAP`),所以给定(货代,航段,日期)最多一份报价。
表注释明写它**什么都不入账**、**汇率不锁**。

**航段端**(`lanes`):`origin_port_id` + `destination_port_id`,仅此。
**没有 `mode`、没有 `container_size`、没有 `service`。**

**箱子端**(`containers`,LOG-2a):`lane_id`(**可空**)、`forwarder_id`(**可空**,
非空时触发器要求是货代)、`departure_date`(NOT NULL)、`container_number`、
`vessel` / `voyage` / `bl_number`。

**实际端**(`freight_documents`):`supplier_id` + `doc_date` + `amount_ccy` + `currency`。

### 6.2 要把两个数放在一起,需要的 join

```
freight_documents fd
  → ??? → containers c            -- 【这一跳今天不存在】
  → lanes l              ON l.id = c.lane_id                      -- c.lane_id 可空
  → forwarder_rate_quotes q
        ON  q.supplier_id = fd.supplier_id      -- 或 c.forwarder_id?两者可以不同
        AND q.lane_id     = c.lane_id
        AND <某个日期> BETWEEN q.valid_from AND q.valid_to
        AND q.deleted_at IS NULL
  → currencies / fx_rate_for(...)  -- 币种可能不同,报价没锁率
```

### 6.3 缺什么 —— 五条,每一条都足以让这个 join 停下

1. **`freight_documents` 上没有集装箱(或发运单、或航段)引用。**
   19 列里一条都没有。第一跳就断。今天唯一的公共键是
   `freight_documents.supplier_id = containers.forwarder_id`,
   而那不是一个连接,那是**同一家货代的所有箱子**。
2. **`containers.lane_id` 与 `containers.forwarder_id` 都可空。**
   线上 4 个箱子里 2 个 `forwarder_id` 为空(见第 7 节)。
   航段缺失时 `container_overview` 已经明说是 `'no_lane'` 而不是空白 ——
   同一条纪律要在这里再走一遍:**"没有报价可比"与"报出来比多了"是两种空,
   不能显示成同一个空。**
3. **报价没有单位。** `amount_ccy` 是"一箱多少"还是"一票多少"还是"一 CBM 多少"?
   表里没有这个维度,`lanes` 里也没有 `container_size`。
   **不知道分母的两个数不能相减。**
4. **有效期用哪个日期取?** 候选至少三个:`containers.departure_date`(世界侧)、
   `freight_documents.doc_date`(凭证侧)、里程碑里的实际开航日。
   三者可以落在不同的报价有效期里,给出**三个不同的"报价"**。
   这是一个必须被决定的口径,不是一个可以取默认值的字段 ——
   而世界侧的日期按房规【永不预填】。
5. **币种与汇率。** 报价带币种不带汇率(明写不锁),实际单据把汇率锁在
   `doc_date` 的 `tt_sell`。所以"差多少"至少有两个都说得通的答案:
   **按报价币种比**(不涉汇率,但两张单据币种不同时无法相减),
   **按本位币比**(要给报价选一个汇率日,而那正是那张表拒绝回答的事)。

**还有一条不算"缺",但会咬人**:权限模块不同。
`containers` / `lanes` / `forwarder_rate_quotes` 全部挂 `module.purchasing.*`
(`lib/modules.ts:126-127` 明写物流暂借采购的码,「将来那个码是 `module.logistics.view`」),
而 `freight_documents` 挂 `module.finance.edit` + (`module.inbound.view` OR `module.finance.view`)。
**任何把"实际"与"报价"放在一起的视图,都跨了两个模块的边界** ——
按 OPS-14 的先例,这类视图要么整块挂一条明写的谓词,要么会对某些角色
**静默丢行**,而那是这个仓库点过名的病。

---

## 7 · 线上数据

查询时间 2026-08-20,Management API,以 `postgres` 身份(绕过 RLS)。

| 对象 | 数量 |
|---|---|
| `freight_documents` | **0** |
| `freight_allocations` | **0**(0 张单、0 个批次) |
| `forwarder_rate_quotes` | **0** |
| `lanes` | 6 |
| `containers` | 4(其中 **3 已软删**,1 在册) |
| `shipments` | 3(**0 挂在箱子上**) |
| `suppliers` where `counterparty_type='forwarder'` | 4 |

**运费单的状态分布:没有状态可报 —— 一张都没有过。**
`FRT-1` 建于 2026-08-11,九天来生产上一次都没被用过。
`docs/known-issues.md:804` 的冒烟跳过清单与此一致:
`/finance/freight/[id]` 因 `freight_documents 空` 被 SKIP。

**四个箱子:**

| code | container_number | lane | forwarder | departure | 状态 |
|---|---|---|---|---|---|
| `CTR-2026-0001` | ZC7382U1 | 有 | 无 | 2026-08-21 | 软删 |
| `CTR-2026-0002` | GXCU5738405 | 有 | 有 | 2026-08-20 | **在册** |
| `CTR-2026-0003` | ZB6016U1 | 有 | 无 | 2026-08-21 | 软删 |
| (见下) | ZZ2BU0000001 | 有 | 有 | 2026-08-20 | 软删 |

**顺带记下一条,不属于本次 scope,但看见了就写下来:**
第四行的 `code` 列里装着的**不是**一个箱号,是一个 106 字符的 PostgREST 错误负载:

```
{"code":"42501","details":null,"hint":null,"message":"permission denied for function next_container_code"}
```

`created_by` 为 NULL,`delete_reason` 写着「LOG-2b 验证用的临时箱子;里程碑只增不改,
所以它只能软删」。**它是 LOG-2b 的验证残留,已软删,而且因为不以 `CTR-` 开头,
`CTR-` 号段的无缝性没有被它破坏**(在册与软删的三条真行是 0001/0002/0003,连续)。
但它证明了一件事:**存在一条绕过 `create_container` DEFINER 的直插路径,
而且那条路径把 RPC 的错误对象当成字符串写进了 `code` 列。**
处置是人的决定,本节只报告。

**这一节最要紧的一句话:第 4 层的两端今天都是空的。**
没有一张运费单、没有一份报价、没有一个箱子挂着发运单。
**任何"实际 vs 报价"的东西造出来之后,第一眼看到的必然是空状态** ——
所以按房规,那些空状态必须各自说清是**哪一种**空:
没有箱子 / 箱子没有航段 / 航段上这家货代没有报价 / 有报价但不覆盖那个日期 /
有报价但币种不同无法相减。这五种今天会长得一模一样。

---

## 8 · 岔口(不提议,只把问题与赌注写清楚)

**岔口一:出口运费费用化,还是"资本化到销售成本"?**
今天 `record_freight_document` 的借方写死 `1200` / `5000`,没有第三条分支。
若出口运费费用化,它与 `record_expense` 同形(贷 2000,借某个费用科目),
`freight_documents` 这张表**它一列都用不上**;
若要它跟着那一票货走进 COGS,那就要回答"跟着哪一票"——
而 `shipments → sales_orders` 已经有答案,`freight_documents` 没有。
**赌注:** 前者意味着第 4 层的主要工作是**科目与对手方**(第 4 节的缺口),
运费那一族原样不动;后者意味着要在 `freight_documents` 上开一条与
`freight_allocations` 平行的**出口分摊**,而那条分摊的分母是发运单不是进料批 ——
`in_stock_ratio` / `basis_qty` / `FREIGHT_MIXED_UNITS` 三样全部要重新定义。

**岔口二:复用 `freight_documents`,还是另起一张单据?**
复用能白拿:无缝 `FRT-` 号段、`fx_rate` 锁点、`payment_shape` 约束、
`ap_open_items` 的第三支、`payment_allocations.freight_document_id` 那条已存在的 FK、
以及 `freightErrorCodes.ts` 那 18 个具名拒绝。
另起则要把这些**逐样再造一遍**。
**赌注:** 复用的代价是那张表上每一条"进料"的假设都变成一个必须加判别的地方
(第 1.6 节七条),而且**借方那两个写死的科目是最脏的一处** ——
一次漏判就是把出口运费记进存货,而那正是
`docs/landed-cost-scoping.md` 说的"看不见的错误"。
另起的代价是**两张形状相近的运费单从此各自漂移**,
以及 `batch_freight_base` 之外要不要再有一个 `shipment_freight_base`。

**岔口三:比较之锚挂在箱子上,还是挂在运费单上?**
(甲)给 `freight_documents` 加 `container_id` —— 一张运费单对一个箱子;
(乙)给箱子加一张"这个箱子花了多少"的汇总 —— 一个箱子可以有多张单
(海运费 + THC + 文件费 + 滞港费,货代的账单本来就是这样开的)。
**赌注:** 甲简单,但**它假设了一箱一单**,而这个假设一旦不成立,
第二张单要么造第二个箱子(假的),要么挂不上(丢的);
乙诚实,但"报价"是一个数而"实际"是一堆数,
**比较就从"两数相减"变成"哪些费目算在报价里"** ——
而 `forwarder_rate_quotes` 今天没有费目这个维度,`notes` 是自由文本。

**岔口四:报价的分母是什么?**
`forwarder_rate_quotes.amount_ccy` 今天没有单位。
若定为"每箱",那 `lanes` 上缺 `container_size`(20GP 与 40HQ 不是一个价);
若定为"每票",那一个箱子装两张订单时报价与实际的口径就错开了;
若定为"每重量单位",那要回答按毛重还是净重 —— 而 §B7「哪个重量说了算」
在第 0 层就已经把这个问题标成未决。
**赌注:** 这个答案决定 `forwarder_rate_quotes` 要不要迁移加列。
**在它被回答之前,任何"实际 vs 报价"的比较都只是把两个数并排放着,
而不是在比较** —— 并排放着的两个数,读的人会自己相减。

**岔口五:关税与进口 GST 的收款方是"另一个 payee",还是"另一类单据"?**
brief 说要把它们路由到不同的收款方。但今天 `suppliers.counterparty_type`
的取值里(线上三种:`forwarder` / `goods_supplier` / `service_vendor`)
**没有"海关"这一类**,而海关也不是一个可以走 `ap_open_items` 账龄的对手方
(关税通常在放行前付清,不存在 30/60/90 天的账龄)。
报关行(customs broker)才是那个真正被欠钱的人,而它今天多半会被建成
`service_vendor`。
**赌注:** 若答案是"另一个 payee",那第 4 层要新增的是
`counterparty_type` 的第四个值 + 一个关税科目,而 `freight_documents` 不动;
若答案是"另一类单据"(`docs/landed-cost-scoping.md` 第二节倾向的那条 ——
【逐批】、只许 `stated`),那要造的是一张新表,
而那份文件已经明说这**是一次决定,不是一个开关**。

**岔口六:`record_payment` 那个洞现在补,还是跟着第 4 层一起补?**
未付运费进得了账龄、出不了门(第 5.2 节)。
现在补是一次小刀:`record_payment` 的 XOR 从五扩到六 + 敞口校验 +
`actions.ts` 的 `alloc_kind` 分支 + `app/page.tsx` 的看板链接。
跟着第 4 层一起补,则那把刀要同时容纳还没定形状的出口运费。
**赌注:** 分开做,第 4 层的迁移窗口小、fixture 边界干净;
一起做,`record_payment` 只动一次,但它是全仓最长的写入函数之一,
一次改两种新单据,fixture 的"注入必须咬"会更难保证咬的是哪一条。

---

# 第 5 层勘察:告警的地基(LOG-5-SURVEY)

**2026-08-20,只读。** 没有改动任何代码、任何数据库对象、任何数据。
基线 `HEAD = 992572c`,工作区干净。所有线上数字来自实时查询。
**跟踪仍然只有手工录入 —— 没有对接、没有轮询**(`container_milestones` 表注释里
原话:「跟踪只有手工录入 —— 没有对接、没有轮询、没有自动状态机。所以这里的每一行
都有一个人」)。本节的一切都建立在那一句上。

## 1 · 今天的告警机制:【两套】,而且它们不是一回事

这个仓库已经有两套并行的机制,而**把它们分开正是 NTF-1 那一刀的全部内容**。
`db/tables/notifications.sql` 的表注释把区别写死了:

> **事件 ≠ 仪表盘的臂,别合并**
> * 臂(`operations_now`)是一个【持续成立的状态】,补上货它自己就消失了;
> * 事件是一件【发生过的事】,它不会消失,只能被读过。

### 1.1 `operations_now` —— 计算出来的【臂】,不存行

一张视图,**22 支** UNION ALL,每次读都重算:
`awaiting_assay` / `assay_unapplied` / `batch_unpriced` / `allocation_stale` /
`po_awaiting_receipt` / `stocktake_open` / `qualification_expiring` /
`qualification_missing` / `credit_over_limit` / `output_unsold_aging` /
`safety_stock_below` / `leave_pending` / `claim_pending` / `review_submitted` /
`invoice_overdue` / `fx_rate_gap` / `bank_unmatched` /
`margin_cost_not_allocated` / `metal_quote_stale` / `orders_unfulfilled` /
`work_order_overdue` / `work_order_variance_beyond`。

* **不产生任何行**,所以【没有去重问题,也没有已读概念】—— 条件不成立那一支就消失;
* 每支自带 `permission`(+ `arm_permission_any`),读者看不见的支不出现;
* 每支给 `item_type / item_id / doc_kind / item_code / subject / item_date`,
  最外层算 `days_waiting = CURRENT_DATE - item_date`;
* **安全库存(SS-1)就是其中一支**,不是通知:
  `WHERE msa.safety_stock_qty IS NOT NULL AND msa.available_qty < msa.safety_stock_qty`。
  阈值 NULL 一次都不响,而那个"不响"【不可以被读成"查过了没问题"】(METAL-1 那一课)。

### 1.2 `notifications` —— 只增不改的【事件】,由触发器/RPC 写

* **谁写**:`notify_class_violations()` 与 `notify_landing_warnings()`,都是
  `SECURITY DEFINER`、对 `authenticated` 收权。
  发射点是**触发器**(`trg_materials_notify_reclassified` 挂在 `materials`、
  `trg_slac_notify_written` 挂在 `storage_location_allowed_classes`)与
  **四个建批次 RPC 的函数体内**(`create_inbound_batch` / `receive_inbound_batch_against_po`
  / `create_stock_transfer` / `create_output_batch`)。
  **不是轮询,不是读的时候算** —— 事情发生的那一刻写一行。
* **表上没有 INSERT 策略**:唯一写入口就是那两个属主权限函数。
* **去重规则(brief 问的那一条)**,原文在 `notify_class_violations`:
  ```
  v_fp := material_id || '|' || location_id || '|' || class_code;
  -- 同指纹且【未读】的已经在 → 不再写
  IF EXISTS (SELECT 1 FROM notifications n
              WHERE n.payload->>'fingerprint' = v_fp
                AND NOT EXISTS (SELECT 1 FROM notification_reads nr
                                 WHERE nr.notification_id = n.id))
  THEN CONTINUE; END IF;
  ```
  **指纹 + 未读**。所以一个条件在被读掉之前只有一行;读掉之后若仍然成立,
  下一次事件会再写一行。**而"每次页面加载写一行"这件事根本无从发生 ——
  因为写入点不在读路径上**。这一点值得说清楚:brief 的问法预设了 on-read 生成,
  而这个仓库不是那样做的。
  索引 `idx_notifications_fingerprint ON (payload->>'fingerprint')` 就是为它建的。
* **已读**:单独一张 `notification_reads (notification_id, user_id, read_at)`,
  主键是两者。**刻意不写在 `notifications.read_at` 上** —— 表注释:已读是【每个读者
  自己的】状态,写在事件行上今天更省,但第二个用户出现那天会静默变错
  (一个人读过 = 所有人已读)。三条 RLS 全锁 `user_id = auth.uid()`,
  而且这张表**允许客户端直写**(它记的是"我看过了",那句话只有读者自己说得出)。
* **`event_type` 与 `subject_type` 都是 CHECK 白名单**;RLS 按 `subject_type`
  分派模块权限码,**`ELSE false`** —— 新主体在有人给它声明模块之前不可见。
  **这一条对第 5 层是硬约束**:任何 `container` 主体的通知,必须同时改这两条 CHECK
  与那条 RLS `CASE`,否则它写得进、读不出。
* **被遮蔽的表**(REVOKE + 列清单 GRANT):将来加的列必须同时进那个清单。

### 1.3 它们各自在屏幕上出现在哪

| 机制 | 出口 |
|---|---|
| `operations_now` | 首页看板(`app/page.tsx`,按 `itemType` 逐支给门牌) |
| `notifications` | `/notifications` 一页 + `app/components/NotificationBell.tsx` 的铃铛 |

铃铛**刻意不给精确数**:它只扫最近 `BELL_LIMIT` 条再减去已读,注释写着
「同 operations_now 那条"人人都开的页面上不许无界扫描"」——
精确数字在 `/notifications` 那一页上。

### 1.4 还有第三处,形状不同,值得记一笔

`metal_prices.anomaly_check` —— 行情异常**持久在那一列上**并有自己的确认流程,
`notifications` 表注释【明确把它排除在外】,理由是本层最该记住的一句:

> **要接第三个来源,先问它是不是已经有一份持久记录 —— 如果是,通知应当【指向】它,
> 而不是【复制】它。** 复制过来 = 同一件事的第二份状态,而两份状态迟早各说各话。

---

## 2 · 免柜期(free time):有一个字段,但它不是一个数

`db/tables/forwarder_details.sql:8`:

```sql
free_time_terms text,
```

**自由文本,可空,没有 CHECK、没有单位、没有默认值、没有锚点。**

要算"从某个里程碑起 N 个免费天",需要两样东西,而**两样都不在**:

1. **一个数**(N)。今天只有一段人写的话("14 days free at destination,
   thereafter USD 75/day" 之类)。从自由文本里解析出数字是把一句话当成一个字段用,
   而这个仓库对那类做法点过名。
2. **一个锚点**(从哪一天起数)。`free_time_terms` 里没有任何东西指向
   `container_milestones` 的哪一个值。

**而且它挂错了层级 —— 这是本节最要紧的一条**:`free_time_terms` 挂在
**货代**身上(`forwarder_details.supplier_id` 是主键),不是挂在**航段**或**箱子**上。
同一家货代在不同航段、不同船公司、不同目的港的免柜期常常不同;
一个挂在货代身上的单值,对第二条航段就已经不成立了。
**报告这一点,不提议形状**(brief 明令)。

**线上实况:`forwarder_details` 一行都没有。** 所以今天不只是"没有数字",
是**连一条自由文本都没有**。

---

## 3 · 预计到达:**确认 —— 全库没有任何 ETA 字段**

全库 `db/tables/*.sql` 搜 `eta` / `expected_arrival` / `expected_date` /
`estimated_arrival` / `arrival_estimate`:**零命中**(唯一形似的
`purchase_order_lines.expected_assay` 是化验成分,与日期无关)。

`containers` 的日期只有一个:`departure_date`(NOT NULL)。
`container_milestones` 记的是 **`event_date` —— 这一步是哪天【发生】的**,
表注释原话。**没有任何一列表达"我们预期它哪天到"。**

### 3.1 一个"逾期"告警需要一个可比的期望,而 FIN-10 对它有话说

`container_milestones.event_date` 的列注释已经把这条界划得很清楚,而它**直接决定**
第 5 层能不能给 ETA 一个默认值:

> * 世界那一侧的事件(departed / arrived / customs_cleared)系统【无从知道】,
>   必须有人录;**给它一个 CURRENT_DATE 默认值,会让"没填"比"填对"更容易通过。**
> * 系统自己见证的事件日期是【已知的】,由那个调用方显式传今天。
> **区别在于【谁知道这件事】,不在于用了哪个函数。**

一个 ETA **属于第一类**:它是世界那一侧的一个说法(船公司给的、货代转述的)。
所以按 FIN-10 一族的规矩,它**必填、永不预填、永不由系统推算**——
特别是**不可以**由"开航日 + 航段平均天数"算出来:那会造出一个看起来像事实的估计,
而没有人说过那句话。同一条规矩已经在 `create_container` 上兑现过:
`CONTAINER_DEPARTURE_DATE_REQUIRED`,HINT 写着「开航日是世界那一侧的事实,
系统无从代填」。

### 3.2 已经存在的、拿"期望"比"现实"的三支 —— 可抄的形状在这里

| 支 | 期望从哪来 | 判据 |
|---|---|---|
| `work_order_overdue` | `work_orders.scheduled_date`(**表上的一个可空日期列**) | `status='released' AND scheduled_date IS NOT NULL AND scheduled_date < CURRENT_DATE` |
| `invoice_overdue` | `invoice_status.due_date`(从付款条件推出来) | `WHERE i.overdue` |
| `qualification_expiring` | `supplier_compliance.valid_until` + **每类证书自己的提前期** | `valid_until <= CURRENT_DATE + ct.warn_lead_days` |

**第三支的形状对第 5 层最有参考价值**:`certificate_types` 是一张
**RUNTIME CONFIG** 表,每一类证书自带 `warn_lead_days`(提前多少天上看板)
**和 `disposition`(`block` 挡收货 / `warn` 只提醒 / `ignore` 不管)**——
「加一种证书是编辑一行,不是跑一次迁移」。
也就是说:**"提前几天响"与"响了之后拦不拦"在这个仓库里已经是数据,不是常量。**

**另记一条 `work_order_overdue` 留下的、至今开着的问题**(视图里原文):
「"放行了三个月、从没排过期"该不该有别的支管 —— 仍然是一个开着的问题…
这一支不假装回答它:它只报"排了期而且过了期"的。」
**ETA 会原样继承这个问题**:一个从来没人填过 ETA 的箱子,是"没问题",还是
"最该被问的那一个"?

---

## 4 · 缺单据:`pending` 有了,而"迟"没有锚

`container_documents`:

```sql
document_type text NOT NULL,
regime        text,
status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','received','not_applicable')),
na_reason     text,
from_lane     boolean NOT NULL DEFAULT false,
created_at    timestamptz NOT NULL DEFAULT now(),
```

**没有 `received_at`,没有 `doc_date`,没有 `due_date`。**
所以一份单据从 `pending` 变成 `received` 的**那一刻没有被记下来**——
今天只知道"现在是什么状态",不知道"什么时候变的"。

「迟」可以锚到哪里,以及各自的代价(**只列,不选**):

* **`container_documents.created_at`** —— 系统侧,清单被实例化的那一刻。
  好处:一定存在。坏处:它是**系统的日子**,不是世界的日子;
  清单晚建三周,所有单据就都"晚了三周才开始计时"。
* **`containers.departure_date`** —— 世界侧,NOT NULL,一定存在。
  坏处:有些单据(装箱单、订舱确认)在**开航之前**就该到,
  以开航日为零点会让它们永远不迟。
* **某一个 `container_milestone`** —— 世界侧,语义最准
  (「提单应当在 departed 之后 N 天内到」)。坏处见 4.1。

### 4.1 里程碑当锚点有一个【实测到的】麻烦:同一个里程碑可以有多行

`container_milestones` 是 **append-only**,表注释明写「记错了就再记一条并在 note 里
说清楚,绝不回头改一行」。线上就是这样:

| 箱子 | 里程碑 | event_date |
|---|---|---|
| CTR-2026-0002 | `departed` | 2026-08-20 |
| CTR-2026-0002 | `departed` | **2026-08-21** |
| CTR-2026-0004 | `loaded` | 2026-08-13 |
| CTR-2026-0004 | `loaded` | **2026-08-15** |

**两个在册箱子,每一个的同一个里程碑都有两行。**
所以"从 departed 起算"必须先回答**哪一个 departed**:最早的?最晚的?
最后录入的?`container_overview` 已经有一个既成惯例可抄 ——
`ORDER BY m.event_date DESC, m.recorded_at DESC LIMIT 1`(**最晚的事件日,
同日则取最后录入的**)—— 但那是给"现在走到哪一步了"用的,
**不等于**它就是计时的正确起点(一次把 08-21 改成 08-20 的更正,会让免柜期
**往回**跳一天,而告警可能已经响过)。

### 4.2 有没有现成的「状态 X 在事件 Y 之后 N 天仍然成立」可抄?

**有两支,但形状差一截:**

* `output_unsold_aging`:
  `remaining_qty > 0 AND (CURRENT_DATE - COALESCE(output_date, created_at::date)) >= 60`
  —— **"状态仍然成立" + "距某个日期已过 N 天"**,N 是**写死的 60**;
* `ar_over_90` / `ap_over_90`:靠 `ap_open_items.bucket = 'b90_plus'`,
  账龄桶在视图里算,**阈值同样写死**。

所以:**这个形状存在,而且有两个现成实现;但它们的 N 都是常量。**
唯一把 N 做成**数据**的是 `certificate_types.warn_lead_days`(§3.2),
而那正是免柜期最需要的性质 —— 免柜期本来就是逐货代、逐航段不同的。

---

## 5 · 线上实况:day one 这三个告警**都没有话可说**

| | |
|---|---|
| 在册集装箱 | **2**(CTR-2026-0002、CTR-2026-0004) |
| 其中有航段的 | 2 |
| 其中有货代的 | **1** |
| 里程碑(在册箱子上) | **4** —— 而且是 2 个箱子 × 同一里程碑各 2 行(见 4.1) |
| 已录的里程碑种类 | 只有 `departed` 与 `loaded`。**没有一条 `arrived` / `customs_cleared` / `delivered`** |
| `container_documents`(在册箱子上) | **0**,其中 pending **0** —— 清单**一次都没有被实例化过** |
| `lane_document_requirements` | **1**(有一条航段定义了一项清单) |
| `forwarder_details` | **0 行** —— 所以 `free_time_terms` 全库为空 |
| 挂在在册箱子上的发货单 | **0** |
| `notifications`(有史以来) | **2** |

**逐条对着第 5 层的三个告警看:**

* **免柜期**:货代侧一行条款都没有,而且唯一有货代的箱子只有 1 个。
  **无论做成什么形状,day one 都是零条。**
* **预计到达**:字段不存在,所以连"未填"都还不是一个可以被数出来的状态。
* **缺单据**:在册箱子上**一份单据都没有**,pending 恒为 0。
  而 `lane_document_requirements` 有 1 行 —— 也就是说清单**定义了却没被实例化**,
  `container_overview.lane_checklist_state` 会把这种情形报成
  `defined_empty` 那一档(LOG-2b 已经把三种"空"分开了)。

**所以这一层最先会被看见的,不是告警本身,而是它的空状态。**
按房规,那些空必须各自说出是哪一种空 —— 而这里至少有五种:
没有箱子 / 箱子没货代 / 货代没条款 / 清单没实例化 / 没人录过里程碑。

---

## 6 · 岔口(不提议,只把问题与赌注写清楚)

**岔口一:告警住在哪 —— `operations_now` 的臂,还是 `notifications` 的行?**
两者在这个仓库里是【被刻意分开的两种东西】,判据也已经写死:
**臂 = 持续成立、补上就消失的状态;事件 = 发生过、只能被读过的事实。**
「免柜期还剩 2 天」是一个持续状态(卸了柜它自己就消失)→ 看着像臂;
「免柜期已经开始计费」是一件发生过的事(事后补录不会让那一天没发生)→ 看着像事件。
**赌注:** 做成臂,就没有已读、没有历史,也**永远不会有人在事后被问到"你什么时候
知道的"**;做成事件,就要同时改 `notifications` 的两条 CHECK 与那条 `ELSE false`
的 RLS `CASE`(加 `container` 主体),并回答**指纹是什么**——
而免柜期的"同一个条件"每天都在变(还剩 3 天 / 2 天 / 1 天),
指纹若含天数就是每天一行,不含天数就只响一次。

**岔口二:免柜期从哪一个里程碑起算?**
候选:`arrived`(到港)/ `customs_cleared`(放行)/ `delivered`(交付)/
`departure_date`(表上唯一 NOT NULL 的日子)。
**赌注:** 线上**一条 `arrived` 都没有** —— 选它,告警在有人开始录到港日之前恒为零,
而"从不响"与"没问题"在屏幕上长得一样(METAL-1 那一课);
选 `departure_date` 则一定算得出来,但**它算的不是免柜期**,只是"离港多久了"。
外加 4.1 那条:**同一个里程碑可以有多行**,所以还要选"哪一个"——
而一次事后更正会让已经响过的告警往回跳。

**岔口三:ETA 是箱子上的一列,还是里程碑表里的一个类型?**
(甲)`containers.eta date`(可空)—— 与 `work_order_overdue` 读
`work_orders.scheduled_date` 完全同形,现成的抄法;
(乙)`container_milestones` 里加一个 `expected_arrival` 类型,
让**"预期"与"已发生"住在同一张表**。
**赌注:** 甲简单,但一个箱子的 ETA **会变**(船期一改就变),而
`containers` 是可改的行 —— 改掉就没有痕迹,"上周他们说的是 15 号"查不回来;
乙自带历史(append-only,改期就是再记一条),但它会让那张表的语义从
**"发生过的事"**变成**"发生过的事 + 说过的话"**,而表注释目前把它定义成前者
(`event_date`:「这一步是哪天发生的」)。**那句注释会因此变成半真的**——
要么改语义并把注释改掉,要么另立一张表。

**岔口四:N 是常量还是数据?**
仓库里两种先例并存:`output_unsold_aging` 写死 60、账龄桶写死 90;
`certificate_types.warn_lead_days` 是 RUNTIME CONFIG,逐类可编辑,还配一个
`disposition`(block / warn / ignore)。
**赌注:** 写死最省,但免柜期**按定义**就是逐货代、逐航段不同的,
写死一个数等于对所有航段说同一句话;做成数据则要先回答**它挂在哪一层**——
而 §2 已经指出 `free_time_terms` 今天挂在【货代】上,那一层多半就是错的。

**岔口五:缺单据的"迟"锚在哪?**
`created_at`(系统侧,一定有,但清单晚建就整体后移)/ `departure_date`
(世界侧,一定有,但开航前该到的单据永远不迟)/ 某个里程碑(语义最准,
但线上还没有 `arrived`,且有 4.1 那个多行问题)。
**赌注:** 前两个能保证"算得出来",第三个能保证"算的是对的东西"。
而且在册箱子上**一份单据都没有**,所以无论选哪个,第一眼看到的都是空状态 ——
那个空必须说清是"这条航段没定义清单""定义了但没实例化"还是"实例化了但都收齐了"。

**岔口六(brief 没点,但它先于上面五条):这三个告警的读者是谁?**
`operations_now` 每一支都自带 `permission`,而物流今天借的是
`module.purchasing.view`(`lib/modules.ts:126-127` 明写「将来那个码是
`module.logistics.view`」)。免柜期是**钱**的事(滞港费),
它的读者更像财务;而录里程碑的人在操作侧。
**赌注:** 挂 `module.purchasing.view`,财务看不见一笔正在发生的费用;
挂 `module.finance.view`,那个每天录里程碑、最该被提醒的人看不见它。
`arm_permission_any` 已经支持一支挂多个码 —— 但**那是一个决定,不是一个开关**。
