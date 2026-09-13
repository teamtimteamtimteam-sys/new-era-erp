# SEARCH-4 停止闸 —— 关联单据搜索的勘察(2026-09-13)

> ## ⛔ 先读这一节:委托书里有【三条断言是假的】,而三条各是一种假
>
> AGENTS.md 的常设要求:**委托书里的每一个数、每一条事实,开工前当场重量一遍,
> 并把结果写进报告 —— 包括量下来是对的那些。** 逐条在 §13。
>
> | # | 委托书说的 | 实测 | 它是哪一种假 |
> |---|---|---|---|
> | ① | 「Searching a purchase order should surface its supplier, its **inbound batches**, its **invoices**」 | ★★ **「its invoices」没有任何外键路径。** `invoices` 只有 `customer_id` / `entry_id` / `sales_order_id`;采购单与发票唯一能碰面的地方是 `payment_allocations`,而那张表带着 `CHECK (num_nonnulls(sales_record_id, inbound_batch_id, expense_id, purchase_order_id, freight_document_id, invoice_id) = 1)` —— **同一行上永远不可能同时有采购单与发票**。供应商那一侧是 `payments` + `expenses`(AP),`invoices` 是客户那一侧(AR)。其余三个例子都对:PO→supplier ✓ · PO→inbound_batches ✓ · material→batches ✓ | ★ **一条【看起来像业务常识】的断言,而这套库的账不是那么记的**。四个例子里三个对,所以它读起来完全可信 |
> | ② | 「`(\"Acme — 12 inbound batches, 3 invoices\")`」 | ★ **实测 Acme = `SUP-2026-0002`** —— `inbound_batches` **11** · `payments` **8** · `purchase_orders` **4** · `expenses` **3** · `invoices` **0(无路径)**;合计 **26 行 / 4 组**(11 条候选边里 4 条今天非空) | 同 ①,而这一次连数也一起错了。**它是个示意,不是一次测量** —— 但它正是"结果长什么样"那一节要引用的东西 |
> | ③ | 「a polymorphic `source_type`/`source_id` pair(**SEARCH-2's jargon sweep named at least one**)」 | ★ **引文是假的,事情是真的。** `grep -rn "source_type\|source_id" docs/handbacks/SEARCH-*.md` → **0 命中**;`grep "行话\|术语\|jargon" docs/handbacks/SEARCH-2-stopgate.md` → **0 命中**,那份报告里没有「jargon sweep」这一节。<br>★ 而线上**确实有 4 对**多态列(§4.3),所以本刀照样把它量了 | ★ **一条【关于上一刀做了什么】的断言** —— AGENTS.md 记过两次(FONT-3 ②「那份要复用的读数根本不存在」)。☞ 处置逐字同一条:**说「上一刀做过 X」时,先去看 X 在不在。** |
>
> ★ 另有两条**不是假、但口径要说清**,以及一条**这台机器够不到**:见 §13。

---

## 1 · 开工闸(§1.1 的两条)

| # | 判据 | 读数 |
|---|---|---|
| 1 | `git status --porcelain` | **空** |
| 2 | 本地 HEAD == `origin/main` == `git ls-remote origin main` | 三者同为 **`3c401bd8e1281db8788b3a01dda489c0008050c0`** ✓ 且等于委托书点名的 `3c401bd…` |

**★ 零迁移,零代码。** 本刀是勘察:`git diff` 只有这一份文件。**不存在破窗。**

---

## 2 · ★★ grilling 改了什么 —— 一条,而它改的是这一刀的【形状】

`mattpocock-skills:grilling` 按 §2 的范围逐轮走了下来。**改变了工作形状的只有一轮,
但它改的是最上面那一格**,所以先说它:

> ### ☞ **「一跳」不能按外键算,只能按【单据】算。**
>
> 委托书的裁定 ② 写着「ONE STEP ONLY」,而它下面的裁定 ③ 写着「从真外键推导」。
> **把这两句照字面合起来 —— 一条真外键 = 一步 —— 是错的,而错在两个相反的方向,
> 两边都是量出来的:**
>
> | 方向 | 实测 |
> |---|--:|
> | ★ **多出来的**:一跳会把【查找表】当成关联记录 | 39 张单据表**向外**的 **120** 条外键里,★ **53 条指向非单据表** —— 其中 **17 条**指向 `currencies`,其余是 `tax_codes` · `accounts` · `material_forms` · `leave_types` · `auth.users` …… ☞ **一张发票会"关联"到一行 `SGD`** |
> | ★ **多出来的(第二种)**:一跳会把【行表】当成关联记录 | **指向**单据表的 **225** 条外键里,★ **158 条来自非单据表** —— `invoice_lines` · `purchase_order_lines` · `journal_lines` · `*_history` · `*_issues` · `*_attachments` …… ☞ 「PO-2026-0012 关联 4 条 purchase_order_lines」不是任何人想看的东西,那是这张单据**自己的内脏** |
> | ★★ **漏掉的**:一跳**看不见** 36 组真关联 | 89 组单据↔单据关系里,**36 组只存在于一张行表的两侧**:`materials ↔ sales_orders`(via `sales_order_lines`)· `materials ↔ purchase_orders` · `output_batches ↔ shipments`(via `shipment_lines`)· `invoices ↔ payments`(via `payment_allocations`)· `inbound_batches ↔ stocktakes` …… ☞ **委托书自己举的「searching a material should surface…」有一半落在这 36 组里** |
>
> ### ☞ 于是判据变成一句可以机读的话:
> **【节点】只能是 `document_types` 登记的 39 张表;【非单据表】只能当边,不能当端点。**
> 一跳 = 单据 → (0 或 1 张非单据表) → 单据。
>
> ★ **而这句话同时把上面两种"多出来"按构造消掉了**:查找表不是单据,所以它不会
> 成为一条结果;行表不是单据,所以它只会成为一条边。**不需要一张"不要显示这些表"
> 的名单** —— 那正是裁定 ③ 要杀的那种手写副本。

**其余各轮没有改变形状,但各自换来了一个数或一条判据**,逐条在 §3–§9。
**grilling 提出的每一个问题,连同建议与证据,全部在 §10,一条都没有筛掉。**

---

## 3 · ★★★ 关系图 —— 从真外键推导出来的,双向,逐表

**量法:`pg_constraint.contype='f'`,不看列名,不看 JOIN,不看代码。**
(委托书点名的那次前科 —— SEARCH-2「31 张里至少 8 张错」—— 正是因为按 JOIN 推导;
本刀一条 JOIN 都没读。)

### 3.1 底数

| | 读数 | 量法 |
|---|--:|---|
| `public` 里的外键约束 | **397** | `pg_constraint contype='f'` |
| 其中指向 `public` 的 | **389** | 目标 schema |
| 其中指向 `auth` 的 | **8** | 同上(`employees.user_id`、`suppliers.created_by/updated_by/owner_id`、`inbound_batches` 两条……) |
| 单据表 / 单据种类 | **39 张 / 40 种** | `document_types`(`payments` 一张表两个前缀) |
| 单据表今天合计行数 | ★ **320** | 39 张逐张 `count(*)` 求和 —— ⚠ **委托书与 SEARCH-2b/3 写的是 319**,见 §13 |

### 3.2 边,按三类分

| 类 | 条数 | 说明 |
|---|--:|---|
| **单据 → 单据**(直接,非自指) | **56 条边 / 53 组无序对** | `inbound_batches.supplier_id → suppliers` 这一族 |
| **单据 → 自己**(同表自指) | **11 条** | 作废/冲销链:`superseded_by` ×5 · `reversed_by*` ×3 · `replaced_by_cod_id` · `corrects_period_id` · `employees.manager_id` |
| **单据 ↔ 单据,经一张非单据表**(桥) | **81 条边 / 50 组无序对**,其中 **36 组是直接边没有的** | `sales_order_lines` · `payment_allocations` · `shipment_lines` …… |
| ★ **被 XOR 型 CHECK 按构造作废的桥** | **15 组**(★ **净减 14 组** —— 1 组另有直接外键) | 见 3.3 |
| ★ **合计:单据↔单据无序对** | ★ **89**(含 3 组自对) | 53 直接 + 36 新增 |

### 3.3 ★★★ 桥不能照收 —— 而筛掉假桥的判据【也是推导出来的】

一张非单据表同时指向 A 与 B,**不等于**有哪一行真的把 A 与 B 连在一起。
`counterparty_contacts` 同时指向 `customers` 与 `suppliers`,而它带着

```
CHECK (num_nonnulls(customer_id, supplier_id) = 1)
```

—— **同一行上只能有一个**。于是「客户关联到供应商」按构造不存在。

☞ **判据:两列若同时出现在一条 `num_nonnulls(...) = 1`(或 `<= 1`,或
`(a IS NULL) <> (b IS NULL)`)里,这一组桥不成立。** 实测解析出 **21 条**这样的
约束(`num_nonnulls` 形 **19** 条 + `IS NULL <>` 形 **2** 条,分布在 **19** 张表上)。

★ **两种写法必须都认** —— `inventory_movements_one_batch` 与 `stocktake_lines_one_batch`
写的是 `(inbound_batch_id IS NULL) <> (output_batch_id IS NULL)`,**只认
`num_nonnulls` 的解析器会把它们整组放过去**,而那正好是 `inbound_batches ↔ output_batches`
这一组假关联。(AGENTS.md「一支扫描器的【切词】那一层」的同一族。)

**它作废的桥有 15 组,逐条 —— 而【净减少 14 组】,差的那一组要说清楚:**

```
customers ↔ suppliers              expenses ↔ freight_documents    freight_documents ↔ purchase_orders
employees ↔ suppliers              expenses ↔ inbound_batches      inbound_batches ↔ invoices
expense_claims ↔ inbound_batches   expenses ↔ invoices             inbound_batches ↔ output_batches
expense_claims ↔ payments          fixed_assets ↔ materials        invoices ↔ purchase_orders
freight_documents ↔ invoices       purchase_orders ↔ sales_orders
★ expense_claims ↔ expenses  ← 桥被杀,但【它有一条真外键】(expense_claims.expense_id),关系照样成立
```

★ **最后那一行值得读两遍:一条桥被作废【不等于】那一组关系消失。**
`expense_claims ↔ expenses` 经 `finance_attachments` 的那条桥是假的
(`num_nonnulls(sales_record_id, inbound_batch_id, payment_id, expense_id, claim_id) = 1`),
而它经 `expense_claims.expense_id` 的那条直接外键是真的。
☞ **所以判据必须作用在【边】上,不能作用在【对】上** —— 一支把整组关系一起删掉的
筛子,会在这里安静地删掉一条真关系,**而没有任何东西会红。**

★ `inbound_batches ↔ output_batches` 被杀掉是**对的**:一个进料批与一个产出批
的关系走的是 `processing_runs`,**不是**直接关系 —— 而那条路两跳,裁定 ② 不许。

### 3.4 ★ 逐表:一条命中能带出哪几类单据(按目标【单据种类】去重)

| 可能的组数 | 张数 | 哪些表 |
|--:|--:|---|
| **14** | 1 | journal_entries |
| **11** | 1 | inbound_batches |
| **10** | 2 | customers · employees |
| **9** | 5 | expenses · output_batches · payments · purchase_orders · suppliers |
| **8** | 2 | materials · sales_orders |
| **7** | 1 | fixed_assets |
| **6** | 2 | pricing_formulas · processing_runs |
| **5** | 3 | contracts · freight_documents · invoices |
| **3** | 4 | assay_results · containers · quotes · shipments |
| **2** | 6 | credit_notes · expense_claims · medical_claims · payroll_periods · stocktakes · work_orders |
| **1** | 8 | attendance_periods · certificates_of_destruction · collection_chases · customer_statements · leave_requests · tasks · traceability_report_issues · wht_remittances |
| ★ **0** | ★ **4** | ★ **bank_statements · cash_forecasts · gst_periods · management_packs** |

(合计 39 张 ✓ —— 这一列本身就是一条覆盖断言。)

★ **四张表一条关联单据都没有。** 一次命中落在它们上面,那一节**是空的** ——
而 SEARCH-3 刚刚删掉 `records.built` 的理由逐字适用于这里:
**空必须画成"这张单据没有关联记录",不许画成"这一半还没建"。**

**读起来对不对,看这几行(实测,不是推理):**

```
suppliers  → containers, contracts, expenses, fixed_assets, freight_documents,
             inbound_batches, payments, pricing_formulas, purchase_orders
materials  → contracts, inbound_batches, output_batches, pricing_formulas,
             purchase_orders, quotes, sales_orders, work_orders
employees  → attendance_periods, expense_claims, expenses, fixed_assets,
             journal_entries, leave_requests, medical_claims, payments,
             payroll_periods, tasks
```

☞ 供应商那一行正是 Tim 说的「这个供应商现在什么情况」。
☞ **而员工那一行里有 `medical_claims` 与 `leave_requests`** —— 见 §9。

---

## 4 · ★★ 裁定 ③:下个月有人加一张表,这套东西还剩多少 —— 三类,带数

### 4.1 (i) DERIVABLE —— **按构造自动**

| | 读数 |
|---|--:|
| 真外键约束(`public`) | **397** |
| 单据↔单据无序对(直接 + 过桥,XOR 筛过) | **89** |
| 参与其中的连接列 | **162** = 单据表上的外键列 **67** + 桥表上的连接列 **95** |
| ★ 关联计数真正要读的那 **134** 列(桥表连接列 **95** + 单据表 `id` **39**),`authenticated` **列级 SELECT 拿得到**的 | ★ **134 / 134**(见 §7.1,带 5 格正面对照) |

★★★ **而这一类比预想的还要好:关系图可以在【查询时】由一支 INVOKER 函数现算,
不需要构建步骤,不需要缓存,不需要任何副本。** 实测(`SET LOCAL ROLE authenticated`
的回滚事务里):

```
authenticated can read pg_constraint FKs   | 397
authenticated can read document_types      | 40
authenticated can read pg_get_constraintdef| 125 (bytes)
```

☞ **建议:一张 `document_relations` 视图**(`db/views/`),它 `SELECT` 自
`pg_constraint` + `document_types`。视图落在 `check_mirrors` / `gate` 已经盯着的
那一层里;**而它按定义不可能与线上不一致,因为它就是线上**。
**不要建表** —— 一张物化的关系表就是裁定 ③ 点名要杀的那份手写副本。

### 4.2 (ii) DECLARABLE —— **推不出来,但闸看得见缺席**

**已知成员两个,而委托书只点了一个:**

| 成员 | 今天由谁管 | 新表来了会怎样 |
|---|---|---|
| `match_columns`(SEARCH-2 按人的判断逐表设的) | `db/fixtures/100-…sql` 第 8 臂 | ⚠ **它只检查【已声明的】列拿不拿得到 SELECT,不检查【有没有声明】。** 一条 `match_columns = '{}'` 的新种子**一路绿** |
| ★ **一张新表【是不是一张单据表】** | ★ **今天没有任何东西管** | 见下 |

★ **第二条是本刀新点名的,而它比第一条要紧** —— 关联搜索的节点集就是
`document_types`,所以**一张没有登记的新单据表,不只是搜不到它自己,
它还会让所有指向它的关联边一起消失,而且是安静地消失。**

**「有 code 列」不是判据:实测 36 张有 `code` 列的表不是单据表**
(`accounts` · `currencies` · `material_forms` · `positions` ……)。

☞ **今天唯一在替这件事把关的是一条【运行时】的链,而它是完整的(实测):**

```
函数体里出现的 document_type_prefix('<key>') 字面量  → 40 个
其中已登记                                         → 40 个
登记了却没有任何函数引用                            → 0 个
```

`document_type_prefix()` 读不到就 `RAISE EXCEPTION`(SEARCH-2b §5.1),所以
**一张会铸码的新单据表若没登记,生产上第一次开单就响。** 这条链是真的,
但它**管不到"code 由应用层 TypeScript 填"的那种新表**。

☞ **建议:照 SEARCH-1 收紧后的 `check-nav-routes` 判据 ② 的形状写一道新臂** ——
委托书问的「是不是那个先例」,答案是**是**,而且形状可以逐字照抄:

> 判据 ②:「文件系统上每一条路由,**要么在注册表里,要么在 EXCEPTIONS 里
> 【带理由】**」;SEARCH-1 的 S6 把它收紧成「前缀覆盖不再是一张通行证」。

新臂:**`public` 里每一张【有 code 列】的表,要么在 `document_types` 里,
要么在一张带理由的例外表里(今天 36 行,每行一句话),否则构建红。**
并且照 AGENTS.md 那条法则,**它自己的覆盖数必须是一条断言**(用两条独立的路数,
对不上就报「我瞎了」),而不是一个印出来给人看的数。

### 4.3 (iii) ★ INVISIBLE —— **只活在应用代码里的关系**

> ⚠ 委托书写着「**这些是任何闸都看不见的。数出来、点名,并且照直说裁定 ③ 是不是
> 真的做得到 —— 如果 (iii) 很大,不许报成满足**。」

**量法:枚举【它住的那个空间】,不枚举调用点**(AGENTS.md BTN-2 那一条)。
一条关系要存在,必须有一列装着对方的键。键只有两种:`uuid` 主键,或 `text` 的 code。

| | 读数 |
|---|--:|
| `public` 表里的 `uuid` 列 | **731** |
| 其中是主键的 | 174 |
| 其中带外键约束的 | 293 |
| ★ **既非主键、又无外键** | ★ **280** |
| ┗ 其中是【操作人】列(`*_by` / `user_id`) | ★ **265** —— 指向 `auth.uid()`,不是指向一条单据 |
| ┗ 其中**长得像一条引用** | ★ **14** |
| ┗ 其余 | **1** |
| `text` 的 `*_code`/`*_ref`/`*_no`/`*_number` 列,无外键无主键 | **31**,而其中**只有 10 条是系统内部引用**(`bank_account_code` ×5 · `subject_code` ×3 · `contract_document_terms.contract_code` · `pricing_term_commitments.source_formula_code`);其余 **21** 条是**外部**编号(证书号、准证号、提单号、身份证号……) |

**那 14 条,逐条点名:**

```
approval_log.subject_id            collection_chase_documents.subject_id
notifications.subject_id           journal_entries.source_id
inventory_movements.pair_id        sales_order_reservations.pair_id
sales_order_reservations.release_pair_id
pricing_term_commitments.source_formula_id
purchase_order_history.purchase_order_line_id
sales_order_history.sales_order_line_id
task_history.node_id               work_order_history.material_id
work_order_history.work_order_expected_id
work_order_history.work_order_line_id
```

★★ **而这里有一个【比委托书预期的好】的发现:那 4 对多态列【是机读的】。**
它们各自带着一条枚举了合法取值的 CHECK:

```
approval_log.subject_type  ∈ {leave_request, medical_claim, performance_review,
                              purchase_order, payment, expense, pricing_formula,
                              stocktake, work_order}          -- 9 个,7 个是登记表的 key
journal_entries.source_type ∈ {manual, purchase, sale, …, invoice, shipment,
                              credit_note, wht_remittance}    -- 22 个
collection_chase_documents.subject_type ∈ {sales_record, invoice, statement}
notifications.subject_type ∈ {material, storage_location}
```

☞ **所以 (iii) 里真正"谁也看不见"的部分,是【类型字符串 → 表名】那张映射** ——
`'purchase_order' → purchase_orders` 推得出,`'purchase' → ?` 推不出。
**那是一条 (ii) 类的声明,不是一条 (iii) 类的黑箱。**

### 4.4 ☞ 判词:**裁定 ③ 是【大部分做得到】,不是完全做得到 —— 而缺口有名字**

| | |
|---|---|
| ★ **做得到的** | 关系图本身。新表带上真外键的那一刻,它**自动**进入关联搜索,一行代码都不用改。**这一条是本刀最硬的结论**,而它靠的是「节点必须是单据表」那条判据(§2)——不是靠任何名单 |
| ★ **要靠闸的** | ① 新表**是不是**单据表(今天无人管,建议见 4.2)· ② `match_columns`(今天只检查已声明的,不检查缺席)· ③ 多态列的类型串→表名映射 |
| ★ **真的看不见的** | ★ **14 条无约束 uuid 引用 + 10 条系统内部 text 引用 = 24 条**。⚠ 而这 24 条里**没有一条**连接两张单据表:它们连的是行表、历史表、同表配对、或科目表 |
| ⚠ **本刀【没有】量的** | ★ **「一个 join 建在 TypeScript 里」这一类,我没有对着 `app/` 做穷举。** 我论证的是它的**上界**:一条关系要存在必须有一列装着键,而键的空间已被上面两张表穷举。**这是一条关于上界的论证,不是一次对代码的普查** —— 照直记 |

---

## 5 · ★ 一条结果会变多大 —— 逐种,线上真实数据

> ⚠ **这份数据【只证明形状,不证明体量】。** 39 张单据表今天合计 **320** 行;
> 一个结构上无上界的关系(一个供应商对多少个批次)今天可能只有 3。
> **下面每一行都要按"形状"读,不许按"规模"读。**

**按【目标单据种类】分组(推荐的形状),max / 中位数 / 零:**

| 表 | 行数 | 可能组数 | 实际最多组数 | 组数中位数 | 一条命中最多带出几行 |
|---|--:|--:|--:|--:|--:|
| materials | 9 | 8 | **7** | 1 | ★ **30** |
| suppliers | 16 | 9 | 4 | 1 | ★ **26** |
| customers | 7 | 10 | 5 | 1 | **13** |
| employees | 22 | 10 | **7** | 1 | 12 |
| inbound_batches | 24 | 11 | **6** | 3 | 10 |
| purchase_orders | 11 | 9 | **6** | 3 | 7 |
| output_batches | 20 | 9 | 4 | 2 | 5 |
| journal_entries | 80 | **14** | 2 | 1 | 2 |
| tasks | 20 | 1 | 1 | 1 | 6 |
| 其余 30 张 | — | **0–6** | ≤4 | 0–3 | ≤7 |

★ **不按目标种类、而按【每一条外键】分组的话,同一份数据读出来是另一个量级** ——
`employees` 有 **44** 条边(6 条通向 `tasks`:`owner_id` + `task_history` ×2 +
`task_nodes` ×3 + `task_participants` ×3),一条命中最多 **24** 个分组、**45** 行。
☞ **「按目标单据种类去重」把最坏情况从 24 组压到 7 组**,而且它读起来才是人话
(「3 个任务」,不是「1 个 owner_id、2 个 task_history、…」)。**这是一条建议,见 Q7。**

★ **结构上无上界的那些,即使今天只有 3,也要按无上界设计:**
一个供应商 → 进料批 / 采购单 / 付款 / 支出;一个物料 → 批次 / 订单 / 报价 /
工单;一个客户 → 发票 / 销售单 / 报价。**反过来,`*.supplier_id → suppliers`
这一族按构造最多 1 条** —— 外键列只装得下一个 id。
☞ **所以"入边"与"出边"是两种东西:出边是【一行】,入边是【一叠】。**

**Acme 那一条,具体到底:**
```
SUP-2026-0002  Acme Battery Recycling Pte Ltd
  inbound_batches 11 · payments 8 · purchase_orders 4 · expenses 3
  contracts 0 · freight_documents 0 · pricing_formulas 0 · containers 0
  ── 4 组 / 26 行,候选 11 条边(9 类目标)
```

---

## 6 · ★★ 结果长什么样 —— 而 8 这个上限【被这一刀重开了】

**SEARCH-3 的上限 8 是在「一条命中 = 一行」的时候定的**(`export const RECORD_LIMIT = 8`,
`lib/search/records.ts:37`;裁定原文在 SEARCH-2 §3「排序…上限 8」。★ 连字符串一起写,因为**行号会漂,字符串不会**)。

**今天的数据摆在一起就是这条上限的讣告:**

| | |
|---|--:|
| 一条命中最多带出多少【组】(按目标种类) | **7** |
| 8 条命中都满载 | **56 行分组行** |
| 若不按目标种类去重 | 一条命中最多 **24** 组 ⇒ 8 条 = **192 行** |

☞ **建议(Q7):两层各有自己的上限,而且它们不是同一个数。**
外层(命中)从 8 **降到 5**,内层(每条命中的关联)**按目标种类分组,每组一行,
不展开行**。一行的形状是 **「进料批 11 条 →」**,点开才去取那 11 条。
**理由不是省地方,是:一个分组行答得出「这个供应商现在什么情况」,
而 11 行批号答不出 —— 那正是 Tim 否掉小改法的那句话。**

### 6.1 ★ 那个数【拿得到,而且不用把行取回来】—— 委托书问的正是这一句

**拿得到,而且机制已经在树里了。** 两条证据:

1. `search_documents()` 已经在做同一件事的兄弟版:`count(*) OVER ()` 在 `LIMIT`
   **之前**求出 `total`(SEARCH-2b §7.2:「一个 `LIMIT n+1` 答不出还有几条」)。
2. **本刀就是这么量的 §5 那张表的** —— 39 张表 × 每条边一支相关子查询
   `(SELECT count(*) FROM y WHERE y.fk = x.id)`,**一行业务数据都没有取回来**。

⚠ **但它与 `withheld` 那个数【不是同一种数】,这一点必须说死:**
`search_documents_withheld()` 是 **DEFINER**,因为「他看不见的还有几条」RLS 按构造
答不了。**关联分组的计数相反:它要的正是「他看得见几条」,所以它必须是 INVOKER。**
☞ **两支函数,两种身份,不要合并。**

### 6.2 ⚠ 形状的代价,照直说

按目标种类分组、每组一个计数 ⇒ **每条命中最多 14 支相关子查询**(`journal_entries`),
**5 条命中 ⇒ 最多 70 支**。今天 320 行、规划器一律 Seq Scan。
★ **不报毫秒数**(SEARCH-2b §11 与 SEARCH-3 都拒绝过,而它们是对的)。
**但有一个结构性的数可以报:**

| | 读数 |
|---|--:|
| 参与关联的连接列 | **162** |
| 其中**以该列打头的索引存在** | **78** |
| ★ **其中没有** | ★ **84** |

★ 没有索引的里面就有 **`inbound_batches.supplier_id`** —— **Acme 那个例子要走的
正是这一条**。还有 `payments.supplier_id` · `purchase_order_lines.material_id` ·
`sales_order_lines.material_id` · `shipment_lines.output_batch_id` ……
☞ **所以这一刀多半要一支迁移,而那支迁移的内容是索引**,形状与 SEARCH-2b
的迁移 A(39 条 trigram GIN)与 C(22 条 recents 索引)**逐字同族,纯增量**。
**它的理由同样是"为将来的体量",不是"为今天的毫秒数"** —— 迁移 A 的抬头
量过那个拐点(合成 20 万行:12.0ms vs 33.4ms)。

---

## 7 · 权限 —— 而这里有【一个数】把问题的性质说清楚了

### 7.1 先把一条差点被我写错的读数放在最前面

**第一版量的是表级 `has_table_privilege('authenticated', …)`,读数是:
6 张单据表【不可读】**(`employees` · `inbound_batches` · `invoices` ·
`pricing_formulas` · `processing_runs` · `purchase_orders`),35 张桥表里 **7 张**不可读。

★★ **那个数【数的东西和它的名字对不上】** —— 这几张表是**列级授权**的
(`data.view_*` + `_masked` 视图,SEARCH-2 §2.3 量过那一族)。
表级函数在「有一列没授权」时就返回 `false`,它答的不是「这张表能不能读」。

**按列重量(关联搜索真正要用的那些列:桥表的两个外键列 + 单据表的 `id`):**

| | 读数 |
|---|--:|
| 要用到的连接列(桥表连接列 **95** + 单据表 `id` **39**) | **134** |
| `authenticated` 列级 SELECT 拿得到的 | ★ **134**(100%) |
| 拿不到的 | ★ **0** |

★ **正面对照(没有它,"全绿"可能只是函数恒真)——** 同一次运行里:

```
employees.identity_no                     | f     ← 必须是 f
employees.work_pass_no                    | f     ← 必须是 f
purchase_order_lines.estimated_unit_price | f     ← 必须是 f
employees.id                              | t
purchase_order_lines.material_id          | t
```

☞ **结论:关联计数不需要任何新授权。** 而那 6 张表的表级红是一条真读数,
只是它回答的是另一个问题 —— 照直记在这里,免得下一份委托书把它抄成
「6 张表读不了」。

### 7.2 ★★★ 现有的 withheld 规则,哪里合用、哪里不合用

| 情形 | 现有规则怎么办 | 合不合用 |
|---|---|---|
| 命中看得见,关联的那一类**整类被模块闸扣下** | 模块闸是**按单据种类**判的,不按行 —— 所以「这一类你能不能看」的**判断**在两层上**逐字相同**,顶层那一次 `search_documents_withheld()` 已经把它说过了。⚠ **但两层的【数】不是同一个数**:顶层数的是**匹配面**,关联层数的是**关联面**。☞ 建议**不在关联层再报一次数**(否则同一件事在屏幕上出现两次,而两个数不一样,读起来像矛盾) | ★ **合用,而且不必改那支函数一个字** |
| 命中看得见,关联的那一类看得见,**但其中若干行被归属/行别扣下** | T4 明写**不数** | ★ **不合用** —— 那一格会变成:屏幕上写「进料批 8 条」,而库里是 11 条,**而没有任何东西说出那 3 条的存在**。这与 recents 的「看不见的行静默消失」是同一条裁定,但**recents 不带计数,关联带** |
| 命中**看不见**,但关联记录看得见(反向) | 按构造不会发生 —— 命中看不见就不会出现在结果里,那一层根本不展开 | 合用 |
| ★ 命中看得见,**而关联计数本身就是一次披露** | 没有规则 | ★ **见 §9 —— 这是 Tim 的,不是我的** |

### 7.3 `assay_results` / `contracts` 那一格少报,关联搜索让它【变好、变坏、还是不变】

> SEARCH-2b §11:两张表的 SELECT 策略是**按行析取**的
> (`customer_id IS NOT NULL AND has_permission('A') OR supplier_id IS NOT NULL AND has_permission('B')`),
> 于是「一个码都不持有才计」这条规则在它们上面偏在**少报**那一边。

**答:对那支函数本身【不变】,而它【新添一个同形状的格子】。**

* **不变**:`search_documents_withheld()` 逐表按 `view_permission` 判,关联搜索
  一个字都不会改它的输入或它的规则。
* ★ **新添**:关联计数是 INVOKER,它数的是「RLS 放给你看的那些」——
  **数字本身是对的**,但它对「因为按行析取而被挡下的那几条」**一声不吭**。
  ☞ 所以它不是同一个缺陷的恶化,而是**同一个形状在第二个地方出现**:
  `assay_results` 有 3 类关联目标,`contracts` 有 5 类 —— 每一类都是这个形状的一格。
* ☞ **而根治它的那件活,SEARCH-2b §14 已经立案并命名**(「让策略谓词的按行析取
  变成可机读的东西」),**比这一刀大**。**本刀建议:不在这一刀里做,但在屏幕上
  把这件事说出来**(见 Q8)。

### 7.4 ★ 一条结构性的数,它决定了权限是不是个边角问题

```
86 组单据↔单据关系(不含自对)
  ├─ 两端的 view_permission 有交集(同一道模块闸)  →  25 组
  └─ ★ 没有交集(跨模块闸)                        →  61 组  = 71%
```

☞ **权限不是这一刀的边角,是它的主干。** 十组关联里七组会跨过一道模块闸。

---

## 8 · 现有的查询函数:**扩,不是换 —— 而且它一个字都不用改**

`search_documents()` 的返回列里**已经有 `id`**:

```
RETURNS TABLE(key text, id text, code text, label text, route text,
              link_mode text, updated_at timestamptz, total bigint)
```

☞ **所以第二层只要一支新函数** `search_related(p_key text, p_id uuid)`
(或一支吃一批 `(key,id)` 的版本),它按 §4.1 那张 `document_relations` 视图现算。
**`search_documents()` 不动,`search_documents_sql()` 不动,`search_documents_withheld()` 不动。**

**这一刀要不要迁移:★ 要,而且是两件:**

| | 内容 | 形状 |
|---|---|---|
| 1 | `document_relations` **视图** + `search_related()` **函数**(INVOKER) | **纯增量** |
| 2 | ★ **84 条外键列索引** | **纯增量** |

★ **两件都是纯增量,旧代码看不见也碰不到** —— 破窗按 SEARCH-2b §9 的口径是
**良性**的(与迁移 A / C / D 同族,不与 B 同族)。**但它仍然是一个必填字段。**

---

## 9 · ★ 有没有哪一条关系【不该显示】—— 找到三条,而三条都不是我能裁的

| # | 关系 | 证据 | 为什么它是 Tim 的 |
|--:|---|---|---|
| ① | `containers.forwarder_id → suppliers` | ★ `app/inbound/inboundQuery.ts:116` 写着 **「LOG-1b:货代不进供应商名单(他们保留 supplier id 只为账上那条链)」** —— **页面刻意把货代排除在供应商之外** | 外键是真的,而**页面已经裁过一次相反的话**。搜索比页面松还是紧,是那条总裁定管的事 |
| ② | `employees → medical_claims` · `employees → leave_requests` | 实测:`employees` 的 10 类关联目标里有这两类;`medical_claims` / `leave_requests` 的闸是 `module.hr.view` | ★★ **一个计数本身就是一次披露。** 「EMP-2026-0003 · 病假申报 2 条」——**不用打开任何一条,你已经知道这个人报过病**。<br>☞ 而 SEARCH-2 §2.3 立过的那条判据**方向是一样的**:「若搜索匹配 `identity_no`,他就能拿着一个身份证号确认它是谁的 —— 那正是页面刻意扣住的映射」。**这里是同一句话,换成了计数。**<br>★ 但它与那次**不同**的地方在于:`identity_no` 的遮蔽**写在 GRANT 里**,推得出来;**「有没有病假」推不出来** —— 持 `module.hr.view` 的人在页面上**本来就看得见**那张列表。☞ **所以这是一条披露裁定,不是一条显示裁定** |
| ③ | `employees.manager_id`(自指)及全部 11 条自指边 | 作废/冲销链 5 条 `superseded_by` · 3 条 `reversed_by*` · `replaced_by_cod_id` · `corrects_period_id` · `manager_id` | 「这张单据被哪一张作废了」**大概率该显示**;「这个员工的上级是谁」是另一回事。**两者共用一条判据(同表自指),而它们不是同一件事** |

★ **我没有替这三条做决定,一条都没有。** 委托书写着「if it is a disclosure
question rather than a display one — that is Tim's」,而 ①②③ 三条**都是**。

---

## 10 · ★★★ 全部未决问题 —— **一条都没有筛掉**,各带建议与证据

> 委托书:「bring back EVERY open question with your recommendation and its
> evidence — all of them, not triaged down to what is needed to start.」

### Q1 · 关联记录的【端点】只能是单据表吗?
➡️ **建议:是。** 非单据表只当边,不当端点。
**证据:**这一条按构造同时消掉了查找表(`currencies` 会挂到每一张发票上)与行表
(`purchase_order_lines` 会挂到每一张采购单上),**而且不需要任何名单** ——
名单正是裁定 ③ 要杀的东西。**代价:它把「关联」的定义绑在 `document_types` 上,
于是 4.2 那道「新表要不要登记」的闸从"锦上添花"变成"承重"。**

### Q2 · 经一张行表的两跳,算不算【一步】?
➡️ **建议:算,且只算一层桥。** 否则 **89 组里的 36 组**会消失,包括
`materials ↔ sales_orders` / `output_batches ↔ shipments` / `invoices ↔ payments`
—— **委托书自己举的例子有一半在这 36 组里。**
**证据:**§3.2 的计数;§2 那张表。

### Q3 · 假桥怎么筛?
➡️ **建议:用 XOR 型 CHECK 约束筛,不用人判。** 实测 **21** 条(两种写法),
作废 **15** 条假桥(**净减 14 组**,见 §3.3 那条例外),而它们逐条都是人会点头的假(`customers ↔ suppliers`…)。
⚠ **而它筛不干净,照直说:** `fixed_assets ↔ pricing_formulas`(via
`purchase_order_lines`)· `employees ↔ employees`(via `task_history`)·
`expenses ↔ expenses`(via `equipment_maintenance`)**活了下来,而它们像噪音**。
**三条都是【同一张桥上两列都可空、且没有 XOR】的形状。**
☞ **备选判据:要求桥的两列都 `NOT NULL`** —— 实测只留 **15 组**,噪音全灭,
**但它同时杀掉 `materials ↔ purchase_orders`(`material_id` 可空,因为一条 PO 行
也可以是固定资产)、`invoices ↔ payments`、`inbound_batches ↔ stocktakes`** ——
**三条都是真的。** ☞ **所以 NOT NULL 太严,XOR 刚好偏松。建议先用 XOR,
把活下来的 3 条噪音写进一张带理由的例外表,由闸盯着它不许长大。**

### Q4 · 自指边(作废链、`manager_id`)显示吗?
➡️ **建议:显示作废/冲销链,不显示 `manager_id`。** 但 **11 条自指边今天共用
一个形状**,机器分不开它们 —— **要么两种都显示,要么加一条声明。**
**证据:**§9 ③ 的名单。**这一条我没有推荐的推导法,它需要一个字。**

### Q5 · 「操作人」算不算关联?
➡️ **建议:不算。** 265 个 `*_by` / `user_id` 列指向 `auth.uid()`,不指向一条单据;
`employees.user_id → auth.users` 是唯一一条通到单据表的,而它是**身份**,不是**关系**。
☞ 而「我最近编辑过什么」这件事 **`recents` 已经建好了**(SEARCH-2b 迁移 C/D)。

### Q6 · 关联要不要参与【匹配】?
➡️ **建议:不要 —— 关联只【挂在命中上】,不产生命中。**
**证据:**这正是 Tim 在 §2 里**亲自否掉**的小改法(「把供应商名加进 inbound 的
match_columns,批次就找得到了,但它们会平铺着混在供应商旁边」)。
☞ **推论:搜 "Acme" 的结果仍然只有一条命中(实测 `total = 1`),
变的是那一条命中【带着什么】。**

### Q7 · 上限 8 怎么办?结果分几层?
➡️ **建议:外层 8 → 5;内层按【目标单据种类】分组,每组一行一个计数,不展开行。**
**证据:**按种类分组,一条命中最多 **7** 组(实测);不去重则最多 **24** 组。
8 × 24 = 192 行,那不是一个下拉。**5 × 7 = 35 行**,而中位数是 1–3 组。
⚠ **「8 → 5」是一次【裁定重开】,不是一次实现细节** —— 我把它摆出来,不替它决定。

### Q8 · 被行级规则挡下的那几条,说不说?
➡️ **建议:说,而且用一句不带数的话。** 「进料批 8 条(另有若干条你看不到)」。
**理由:**T4 不许数它(数它要逐行读内容),但**一个不提它的计数会被当成全部** ——
这正是 SEARCH-2b §7.2 那条「一个说了个小数的截断提示,与一个不提截断的结果,
读起来一样错」。⚠ **而"若干条"也是一种模糊,我知道。两个坏里挑一个,请 Tim 挑。**

### Q9 · 员工 → 病假/医疗申报的计数,给不给?
➡️ **建议:我不推荐,请 Tim 裁。** 见 §9 ②。**这是唯一一个我认为不该由我
给建议的问题** —— 它不是「搜索比页面松不松」,它是「一个计数本身算不算披露」,
而这套系统对后者还没有过裁定。

### Q10 · 货代(`containers.forwarder_id`)显示为供应商的关联吗?
➡️ **建议:不显示,而且照 LOG-1b 的理由写进例外表。**
**证据:**`inboundQuery.ts:116` 那句注释是**页面已经做过的相反的决定**。

### Q11 · 那 4 对多态列(`subject_type`/`source_id`)进不进关联图?
➡️ **建议:这一刀不进,但把那张「类型串 → 表名」的映射作为 (ii) 类声明立案。**
**证据:**4 张表今天合计 **96 行**(`journal_entries` 80 · `approval_log` 14 ·
`notifications` 2 · `collection_chase_documents` 0),而 `journal_entries` 已经有
**14 类**真外键关联 —— **多态那一条加不了多少,却要一张新的手写映射。**

### Q12 · 84 条索引,这一刀建还是下一刀建?
➡️ **建议:这一刀建,与功能同一支迁移。**
**证据:**`inbound_batches.supplier_id` 没有索引,而它正是 Acme 那条路。
⚠ **而"它现在慢"这句话我【没有】量,也不会量** —— 320 行上规划器一律 Seq Scan。
理由与迁移 A 逐字相同:**为将来的体量,不为今天的毫秒数。**

### Q13 · 计数用 INVOKER 还是 DEFINER?
➡️ **建议:INVOKER。** 关联计数要回答的是「**你**看得见几条」,而那正是 RLS
天然回答的问题。**DEFINER 只属于 `withheld`,因为「你看不见几条」RLS 按构造答不了。**
**证据:**§6.1。**两支函数,两种身份,不要合并。**

### Q14 · 关系图存成视图还是表?
➡️ **建议:视图。** `authenticated` 实测读得到 `pg_constraint` 与
`pg_get_constraintdef`,所以它可以在查询时现算。**一张物化的关系表就是裁定 ③
点名要杀的那份手写副本。**

### Q15 · 4 张一条关联都没有的表,那一节画什么?
➡️ **建议:画一句「这张单据没有关联记录」,不许画「还没建」。**
**证据:**`bank_statements` · `cash_forecasts` · `gst_periods` · `management_packs`
实测 0 类关联目标;而 SEARCH-3 刚刚为了同一条理由删掉 `records.built`
与 `search.recordsNotBuiltYet`。

### Q16 · 这一刀要不要顺手补上 4.2 那道「新表必须登记」的闸?
➡️ **建议:要,并且它是这一刀里【唯一一件不做就会让裁定 ③ 落空】的事。**
**证据:**今天没有任何东西看得见「有人加了一张单据表却没登记」;
而关联图的节点集就是登记表,**所以漏登记一次,漏掉的不是一条结果,是一片边。**

---

## 11 · 价钱 —— 两个数,以及【哪几块 Tim 不答就算不出来】

### 11.1 过程底价(**本刀重量的是出处,不是数本身**)

| 量具 | 读数 | 身份 |
|---|--:|---|
| 底价合计(SEARCH-0 报,SEARCH-1 §6 复核) | **5259s ≈ 88 min** | ★ **CONFIRMED —— `docs/handbacks/SEARCH-1.md:38` 与 `:463` 逐字** |
| `db/gate.py` 整门 | **354s**(SEARCH-3)· 194–254s(SEARCH-2b)· 365s(SEARCH-1) | CONFIRMED · **区间两到六分钟,带肥尾** |
| `smoke-routes.mjs` | **642.2s**(SEARCH-3)· 533.1s(SEARCH-2b) | CONFIRMED |
| `survey-controls --mode=drift` 一趟 | **1543s ≈ 26 min**(SEARCH-3) | CONFIRMED |
| ┗ **而一刀要两趟** | ★ **≈ 52 min** | CONFIRMED |
| `npm run build` | 冷 **40s** | CONFIRMED |
| `npx tsc --noEmit` | 冷 **11s** / 增量 **1s** | CONFIRMED |
| 四支探针各一趟 | 各 **50–70s** | CONFIRMED |
| ★ **改前读数要 `git stash` + 重建** | SEARCH-3 一共建了 **6 次** | CONFIRMED |

### 11.2 这一刀量出来的活

| 块 | 依据 | 估 |
|---|---|--:|
| `document_relations` 视图 + `search_related()` | §8;`search_documents_sql()` 是现成的形状 | 中 |
| **84 条索引**的迁移 + 镜像 | §6.2;形状同迁移 A/C,机械 | 小 |
| 4.2 那道新闸(含两条独立的覆盖断言 + 故障注入) | SEARCH-2b §6.1/§6.6 的先例:**一条从没红过的判据不算判据**,注入是必付的 | ★ **中偏大** |
| 应用层:`types.ts` 加一层 · `records.ts` 取关联 · `SearchEntry.tsx` 画分组 | 三处都是**已有的槽**,不开新面板 | 中 |
| 文案(en + zh)· `check-i18n` | 分组行 + 空态 + Q8 那句话 | 小 |
| `probe-search-results.mjs` 新格 | SEARCH-3 的 R1–R6 已经在那里 | 小 |

### 11.3 ★ Tim 不答就算不出来的几块,逐条点名

| 算不出来的 | 卡在哪 |
|---|---|
| 应用层与文案的量 | ★ **Q7**(上限与两层形状)—— 5×7 的分组行与 8×24 的展开行不是同一个 UI |
| 闸的臂数与注入次数 | ★ **Q16**(补不补那道闸)· **Q3**(例外表要不要) |
| 要不要第二支函数 / 第二条文案 | ★ **Q8**(行级扣下说不说) |
| **整块要不要做** | ★ **Q9**(员工→病假的计数)—— 若裁定是"不给",那 `employees` 的 10 类目标要按类过滤,**那是一条声明,不是一条推导**,又多一道闸 |
| ★ **延迟** | ★ **永远算不出来,而且不该算** —— 320 行上规划器一律 Seq Scan,**报一个毫秒数就是编一个数**(SEARCH-2b §11 · SEARCH-3 §8,两刀都拒绝过) |

---

## 12 · ★ 一刀还是几刀 —— **一刀,而理由是它们共用同一条判据**

**默认合并,而这里没有分刀的理由:**

* 视图、函数、索引、闸、应用层 —— **五块共用「节点必须是单据表」那一条判据**。
  拆开做,第一刀会留下一个**没有闸看着**的关系图,而那正是裁定 ③ 要防的状态。
* 索引那一支若单独走,它是一次**没有消费者的纯增量迁移** —— 本仓库对
  「先建着,回头用」已经付过账。
* ⚠ **唯一可以单独先走的是 4.2 那道闸**(它不依赖关联搜索的任何东西,
  而它今天就已经是个缺口)。**但它也没有必须先走的理由**,而多一次破窗、
  多一趟整门(354s)、多一趟 smoke(642s)是真的代价。

☞ **建议:一刀。**

---

## 13 · ★ 委托书里的每一个数 / 每一条事实,逐条

| # | 委托书说的 | 读数 | 判 |
|--:|---|---|---|
| 1 | HEAD == origin/main == ls-remote == `3c401bd…` | 三者同为 `3c401bd8e1281db8788b3a01dda489c0008050c0` | ★ **CONFIRMED** |
| 2 | `git status --porcelain` 空 | 空 | ★ **CONFIRMED** |
| 3 | 「39 张单据表 **319** 行」 | ★ **320** —— 39 张逐张 `count(*)` 求和,今天 | ⚠ **差 1**。SEARCH-2b/3 写的 319 在**它们写下的那天**是对的;**这是一条会漂的数,引用它必须带日期** |
| 4 | 「for each of the **39 document types**」 | ★ **39 张表 / 40 种**(`payments` 一张表两个前缀:`RCPT` + `PMT`) | ⚠ **口径错一格** —— 而它会改变"逐种量一遍"的分母 |
| 5 | 「SEARCH-3 caps records at **8**」 | `export const RECORD_LIMIT = 8`(`lib/search/records.ts:37`)· `search_documents(p_limit integer DEFAULT 8)` | ★ **CONFIRMED** |
| 6 | 「SEARCH-1 put [the floor] at **88 minutes**」 | `SEARCH-1.md:38` 与 `:463`:**5259s ≈ 88 分钟** | ★ **CONFIRMED** |
| 7 | 「SEARCH-2's route deriver got at least **8 of 31** wrong by inferring from JOINs」 | `SEARCH-2-stopgate.md:96` 逐字:「**31 张里至少 8 张错**」 | ★ **CONFIRMED** |
| 8 | 「SEARCH-2b §11 记着计数函数在 `assay_results` 与 `contracts` 上少报」 | §11 逐字,理由是**按行析取**的策略 | ★ **CONFIRMED**(处置见 §7.3) |
| 9 | 「the nine modules」 | `SEARCH-0-stopgate.md:174`「就用这 9 个模块」· `SEARCH-1.md:156` | ★ **CONFIRMED** |
| 10 | 「SEARCH-1's tightened `check-nav-routes` criterion ②」 | `scripts/check-nav-routes.mjs:23` 判据 ② · `:219`「★★【SEARCH-1 · S6:判据 ② 收紧了 —— 前缀覆盖不再是一张通行证】★★」 | ★ **CONFIRMED**,而且**它正是那个先例**(§4.2) |
| 11 | 「Searching \"Acme\" today returns the supplier record and nothing else」 | ★ **CONFIRMED,实测:**`search_documents('Acme',20)` → **1 行**,`supplier\|SUP-2026-0002\|Acme Battery Recycling Pte Ltd\|total=1` | ★ **CONFIRMED** |
| 12 | 「the Inbound list on screen SHOWS 'Acme…' in its supplier column」 | ★ **CONFIRMED:**`app/inbound/InboundTable.tsx:103` —— `{ key: 'supplier', header: t('inbound.colSupplier'), render: (b) => b.supplierName }` | ★ **CONFIRMED** |
| 13 | 「PO → its supplier, its inbound batches, **its invoices**」 | ★ **前两个真,第三个假** —— 见停止闸 ① | ★ **WRONG** |
| 14 | 「Acme — 12 inbound batches, **3 invoices**」 | ★ **11 / 0** —— 见停止闸 ② | ★ **WRONG** |
| 15 | 「a polymorphic source_type/source_id pair(**SEARCH-2's jargon sweep named at least one**)」 | ★ **引文假,事情真** —— 见停止闸 ③ | ★ **WRONG(引文)** |
| 16 | 「Search shipped in **three cuts**」 | ★ **口径问题:**`git log` 里有 **6** 次 SEARCH 提交(SEARCH-0 / 1 ×2 / 2 / 2b / 3);**真的动了树的是 3 次**(SEARCH-1 · SEARCH-2b · SEARCH-3),SEARCH-0 与 SEARCH-2 是停止闸 | ⚠ **按"建过东西的刀"算是对的** |
| 17 | 「live as **v1.4.21**」 | ★ **树里不存在** —— `git grep "1\.4\.21"` **0 命中**,`git tag` **空**,`package.json` 是 `0.1.0` | ⚠ **NOT MEASURABLE HERE** —— 那是 Vercel 面板上的东西,**这台机器够不到**(AGENTS.md 的常设读数:五项逐条 ABSENT)。**不判真假,判"够不到"** |
| 18 | 「Tim confirmed the deployment of 3c401bd」 | ★ **转述,不是测量** —— 本机无从核实,照 AGENTS.md 的要求**把这件事写出来** | ⚠ **转述** |

**★ 本刀自己量出来的数,逐条(全部 CONFIRMED,量法写在数旁边):**

| 数 | 读数 | 量法 |
|---|--:|---|
| `public` 外键约束 | **397**(→public 389 · →auth 8) | `pg_constraint contype='f'` |
| 单据表向外的外键 | **120**,其中 **53** 指向非单据表(`currencies` 占 **17**) | `pg_constraint` 按 src/tgt 分类 |
| 指向单据表的外键 | **225**,其中 **158** 来自非单据表 | 同上 |
| 单据↔单据无序对 | **89**(53 直接 + 36 过桥) | §3.2 的推导脚本 |
| 自指边 | **11** | 同上 |
| XOR 型 CHECK | **21**(num_nonnulls 19 · IS NULL<> 2)· 分布 **19** 张表 | `pg_get_constraintdef` 正则,两种写法 |
| 被 XOR 作废的桥 | **15 组**,净减 **14** 组(1 组另有直接外键) | 同上 |
| 跨模块闸的关系对 | ★ **61 / 86 = 71%** | `document_types.view_permission` 两端求交 |
| 参与关联的连接列 | **162**(单据表外键 67 + 桥表连接列 95),其中**以该列打头的索引缺席 84** | `pg_index.indkey[0]` |
| 关联计数要读的 **134** 列(桥表 95 + 单据 `id` 39)的 `authenticated` 列级 SELECT | ★ **134 / 134**,带 5 格正面对照 | `has_column_privilege` |
| `uuid` 列 | **731**(PK 174 · 带 FK 293 · **孤儿 280**) | `pg_attribute atttypid='uuid'` |
| 孤儿里是操作人列的 | **265**;像引用的 **14**;其余 **1** | 列名分桶,三桶都报出来 |
| 有 `code` 列但不是单据表 | **36 张** | `pg_attribute attname='code'` |
| `document_type_prefix('…')` 字面量 → 已登记 | **40 → 40**,未被引用的 key **0** | `pg_get_functiondef` 正则 |
| `*Query.ts` 里已经做「名字→id→`.in()`」的 | ★ **2 / 21**(`inboundQuery` · `outputQuery`) | `find app -name "*Query.ts"` 逐个 grep |
| 一条命中最多几组(按目标种类) | **7**;不去重则 **24** | §5 的相关子查询 |
| 一条命中最多几行 | **30**(一个物料)· 26(一个供应商) | 同上 |

**★ 本刀【没有】量的,逐条点名:**

* ★ **「一个 join 只写在 TypeScript 里」这一类,没有对 `app/` 做普查。**
  §4.3 给的是一条**上界论证**(键的空间被两张表穷举),**不是一次测量**。
* ★ **一次关联查询在生产上要多久,没有量,也不打算量。** 320 行。
* ★ **并发 / 缓存行为**没有碰。
* ★ **`document_relations` 视图的实际写法没有写过一行** —— 本刀零代码。
* ⚠ **`operations` 这个角色在线上已退休**(SEARCH-1 §5.4),而 `AGENTS.md` 的
  `--reach` 那一节仍列它为三角色之一。**第三次登记,处置由人决定。**

---

## 14 · ★ 下一轮的前沿是【细节】还是【形状】

> 委托书:「If a later round's frontier is detail-level rather than shape-level,
> say so plainly and recommend proceeding to the build.」

**★ 形状这一层已经收口了,而它收在一句话上:**
**节点是单据表,非单据表只当边,桥用 XOR 筛。** §3 与 §4 是这句话的全部证据。

**但前沿【还不是纯细节的】,而卡住它的是三个字:**

| | 为什么它不是细节 |
|---|---|
| ★ **Q7**(上限 8 与两层形状) | 它重开一条在案裁定,而 5×7 与 8×24 是两个不同的 UI |
| ★ **Q9**(员工 → 病假的计数) | 它决定关联图要不要一层**按类过滤**,而那是一条声明 + 一道闸 |
| ★ **Q16**(补不补那道「新表必须登记」的闸) | 它决定裁定 ③ 到底算不算满足 |

☞ **建议:这三个字给下来之后【直接开工,不必再来一轮勘察】。**
其余 13 个问题我都给了建议,而它们的证据都在这份文件里 ——
**照建议走、把偏离写进报告,比再花一刀问一遍更便宜。**

---

## 15 · 等什么

**等 Tim。** 这台机器够不到 Vercel(AGENTS.md 的常设规矩:一刀的终端活到推送为止)。
**本刀零迁移、零代码,破窗【不存在】,而这一行是量出来的**(`git diff` 只有这一份文件)。
