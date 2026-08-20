# 设备台账勘察 —— EQP-0

**2026-08-20,只读。** 没有改动任何代码、数据库对象或数据。
基线 `HEAD = 17b877f`。所有"线上"数字来自实时目录查询;所有结构断言都指到
具体的文件与对象名。**查不到的写 UNKNOWN,不写猜测。**

---

## 0 · grill 对 scope 做了什么

`mattpocock-skills:grilling` 对本 scope 的树做了一轮,产出如下(装好的技能叫
`mattpocock-skills:grilling`,不叫 `grill-me` —— 名字差异记在这里)。

### 0.1 它【删掉】的前提:两条,都是事实层面站不住的

* **「(ii) 竣工前支出 —— 在资产存在【之前】累积」** —— **这个前提不成立**。
  FIN-22 里资产【先】存在,支出【后】追加:`record_expense(p_asset := {asset_id})`
  是追加模式,`fixed_asset_cost_entries` 就是那个累积桶。桶已经有了,
  而且它挂在资产上,不是挂在一个"尚不存在的资产"上。
* **「A4 · 如果没有界面就直说」** —— **有界面**:`app/finance/assets/`(列表 +
  折旧面板 + 处置/投用动作),外加 `/finance/month-end` 上的折旧步骤。
  scope 预期的"DB 完备而无门"这一次不成立。

### 0.2 它【加进来】的:四项

1. **资本化事件本身**(WIP → 资产、定投用日、折旧起算)是 (i) 与 (ii) 之间的铰链,
   而原 scope 三样里没有它。已建:`set_asset_in_service`。见 A2。
2. **线上有没有数据**(day-one 现实检查)—— LOG-5 那一课:一个"上线即空"的模块,
   第一眼看到的是空状态而不是功能。见 A7。
3. **采购单能不能承载设备** —— B3 问了预付,却没问"这台机器能不能开一张 PO"。
   答案是不能,见 B3b,而这直接决定了押金那条路怎么走。
4. **1210 陷阱** —— `1210 存货-在制品` 是【存货】的在制品,不是资产的在建工程。
   名字像,科目类别不同。见 B1。

### 0.3 它【改了措辞】的

"construction expenditure" 在本仓库里没有对应物;既有的叫法是
**成本明细 / 追加(`fixed_asset_cost_entries`)**。本文档用后者,以免造出第二个词。

### 0.4 它【没有改】的

A、C、D、E、F 五节的问题本身照原样执行。

---

## A · 已经存在什么

### A1 · 全部对象(逐个点名,不概括)

**表(3)**
* `fixed_assets` —— 21 列:`id / code / description / category / acquisition_date /
  in_service_date / cost_ccy / currency / fx_rate / cost_base / useful_life_months /
  residual_base / depreciation_account_code / status / disposal_date /
  disposal_proceeds_base / disposal_journal_id / expense_id / notes / created_at / created_by`
* `fixed_asset_cost_entries` —— 9 列:`id / asset_id / expense_id / amount_ccy /
  currency / fx_rate / amount_base / created_at / created_by`
* `fixed_asset_depreciation` —— 7 列:`id / asset_id / period_end / amount_base /
  journal_entry_id / created_at / created_by`

**约束(要紧的几条)**
* `fixed_assets.expense_id` **NOT NULL** → `expenses(id)`:**一台资产必须由一笔支出生出来**;
* `fixed_assets_status_check`:`active | disposed` —— **没有 written_off**;
* `fixed_assets_category_check`:`equipment | vehicle | office | other`;
* `fixed_assets_service_after_acquisition`:`in_service_date IS NULL OR >= acquisition_date`;
* `fixed_assets_residual_below_cost`、`cost_base > 0`、`useful_life_months > 0`;
* `fixed_assets_disposal_fields`:active ⇔ 处置三列全空;
* `fixed_asset_cost_entries_one_per_expense` **UNIQUE(expense_id)** —— 一笔支出只能进一台资产一次;
* `fixed_asset_cost_entries.amount_base > 0` —— **不能记负数(见 F6)**。

**函数(4)**
`depreciate_fixed_assets(p_period_end date)` ·
`preview_depreciate_fixed_assets(p_period_end date)` ·
`dispose_fixed_asset(p_asset_id, p_disposal_date, p_proceeds, p_bank_account, p_notes)` ·
`set_asset_in_service(p_asset_id, p_date)`。
**没有"新建资产"的函数** —— 入口是 `record_expense` 的资本分支(见 A2)。

**触发器:三张表上一个都没有。**

**RLS 策略:三张表各只有一条 SELECT 策略**,谓词都是
`has_permission('module.finance.view')`。**没有 INSERT/UPDATE/DELETE 策略** ——
所以 authenticated 写不进去,写入只能经 DEFINER 函数。

**授权**:三张表对 `authenticated` 与 `anon` 都是表级全权限(SELECT/INSERT/
UPDATE/DELETE/…)。**挡住写入的是 RLS 缺策略,不是授权。**

**视图:0 个**(`information_schema.views` 里没有 `%asset%` / `%deprec%`)。

### A2 · 生命周期逐段

| 段 | 状态 | 由谁实现 |
|---|---|---|
| 取得(新建) | **有** | `record_expense(p_account_code := '1500', p_asset := {...})` —— 1500 与 `p_asset` 【互相要求】 |
| 追加成本 | **有** | 同一个函数,`p_asset->>'asset_id'` 非空即追加 → 写 `fixed_asset_cost_entries` 并累加 `cost_base` |
| 投用日 | **有** | `set_asset_in_service`;`in_service_date` 可空 = "还没投用" |
| 折旧 | **有** | `depreciate_fixed_assets` + 同源预览;直线法,**从投用日按天**,封顶 成本−残值 |
| 重估 | **刻意不做** | 固定资产是【非货币性】,`revalue_foreign_balances` 按 `accounts.is_monetary` 扫,1500/1510 不在其中。fixture 16D 反向断言了这一点 |
| 处置 | **有** | `dispose_fixed_asset` —— 解除 1500/1510,差额进 7200 |
| 报废 / 减值 | **没有** | `status` 只有 `active|disposed`;**UNKNOWN:报废是否被当作"零对价处置"使用过**(线上 0 台资产,无从观察) |

### A3 · 科目与 is_system

`1500` 固定资产-设备 · `1510` 累计折旧 · `6700` 折旧费用 · `7200` 资产处置损益 ·
`2000` 应付账款(未付的资本支出)。
**前四个都是 `is_system = true`**(`db/tables/accounts.sql`,注释写明
「FIN-22b 升 system:函数写死引用」);`2000` 同样 is_system。

### A4 · 界面 —— 有

* `app/finance/assets/page.tsx` —— 资产列表 + 折旧面板(`?date=`,预览走
  `preview_depreciate_fixed_assets`,与过账同一份算术);
* `app/finance/assets/AssetActions.tsx` · `DepreciateButton.tsx`;
* `app/finance/month-end/` —— 折旧、处置、投用三个动作的调用点。

**门是 `requireModule(MOD.finance)`。**
**UNKNOWN:`/finance/assets` 是否在导航里有入口** —— 未逐条走查
(`--reach` 是那条一小时的检查,本次只读勘察没跑)。

### A5 · fixture(3 份)

* `16-fixed-assets-straight-line` —— 从投用日按天(3/16 投用、3/31 期末 = 51.61,
  而从购置日算会是 100)、同期重跑提 0 且不多发分录、寿命尽头恰好封顶、
  外币按购置日定格、**且反向断言重估扫不到 1500/1510**;
* `17-year-end-close` —— 年结涉及;
* `77-a-machine-accumulates-cost-until-it-is-commissioned` —— **本次最相关的一份**:
  未给投用日则留空「机器先到、后调试、再投产,中间那段它不该折旧」;
  未投用不提折旧;`asset_id` 走追加模式且不造出第二台;
  三笔支出一台资产、成本明细三行、两种原币(USD 机器 + SGD 运费);
  **明细合计必须等于表头 `cost_base`**。

### A6 · 权限

`module.finance.view`(读,三张表的 RLS)/ `module.finance.edit`(写,经函数)。
**没有独立的设备权限码。**

### A7 · 线上现实(grill 加的一节)

`fixed_assets` **0** 行 · `fixed_asset_cost_entries` **0** 行 ·
`fixed_asset_depreciation` **0** 行。
**这套东西从未被真的用过。** 四台机器会是它的第一批数据。

---

## B · 竣工前的桶

### B1 · 有没有"在建"结构

**有,但形状与 scope 假设的不同**:不是一个独立的在建科目,而是
**资产先建卡、成本往上追加**(`fixed_asset_cost_entries`),
`in_service_date` 为空即"还没投用、不提折旧"。借方从第一笔起就在 **1500**。

**没有独立的 CIP / 在建工程科目。**
**【1210 陷阱】** `1210 存货-在制品` 是【存货】的在制品(`account_type='asset'`,
服务于加工),**不是**资产的在建工程;拿它当 CIP 会把设备支出混进存货口径。

### B2 · 成本单据能不能挂到某一台机器上(逐条路径)

| 路径 | 能否携带资产引用 | 证据 |
|---|---|---|
| `record_expense` | **能** | `p_asset jsonb`;1500 ↔ `p_asset` 互相要求;追加写 `fixed_asset_cost_entries` |
| 进货运费 `record_freight_document` | **不能** | 分摊行 `freight_allocations.inbound_batch_id` **NOT NULL** → `inbound_batches`;没有资产列 |
| 出口运费 `record_export_freight_document` | **不能**(对资产而言) | 它只有 `container_id`;借方写死 6300 费用 |
| 应付链 `ap_open_items` / `payment_allocations` | **不能** | 六个去处:sales_record / inbound_batch / expense / purchase_order / freight_document / invoice —— **没有资产** |

**结论**:今天把成本挂到机器上,**只有 `record_expense` 一条路**。

### B3 · 押金 / 里程碑付款

**预付概念存在**:`payment_allocations.purchase_order_id` 那一支就是预付
(借 **1300 预付款项**,不是 2000);`prepayment_applications` + `apply_prepayment()`
在货到并计价后把它挪到具体批次的应付上(借 2000 / 贷 1300)。
栏杆是「累计预付 ≤ PO 估算总额 × 1.5」。线上 `purchase_orders` 6 张、
`prepayment_applications` 1 条。

### B3b · 但采购单【装不下设备】(grill 加的一条,而且是硬的)

`purchase_order_lines.material_id` **NOT NULL** → `materials(id)`。
**一张采购单的每一行都必须是一个物料。** 机器不是物料;
把它建成 materials 行会同时进入收货、库存、化验、安全库存那一整套(见 F5)。
**所以"对着一张设备 PO 付押金"这条路今天不存在。**

### B4 · 那么付 30% 押金,今天实际会落到哪里(逐步)

按现有机制,能走通的只有一条,而且它有代价:

1. 建不了设备 PO(B3b)→ 走不了 `purchase_order_id` 那支预付 → **进不了 1300**;
2. 于是押金只能记成一笔 `record_expense`:
   * 若记 `p_account_code='1500'` + `p_asset={新建}` → **押金当场变成一台在册资产**,
     金额只有 30%,而机器还在对方厂里。之后余款用 `asset_id` 追加。
     账上"资产"在所有权与实物都未到位时就存在了;
   * 若记成别的费用科目 → 押金落进损益,**日后没有任何机制把它挪进 1500**
     (`fixed_asset_cost_entries` 只从 `record_expense` 的资本分支写,而那要求科目是 1500)。
3. `record_expense` 的 `p_payment_status='paid'` 会贷银行 —— 付款本身记得下。

**UNKNOWN**:是否存在第三条我没找到的路。已检查 `record_expense`、
运费族、AP 链、PO 链四处。

---

## C · 维护与维修

### C1 · 今天有没有"对机器做的工作"

**没有。** 工单的主体是【物料】,证据是外键不是名字:
* `work_order_lines.material_id` **NOT NULL** → `materials(id)`
* `work_order_expected_outputs.material_id` **NOT NULL** → `materials(id)`
* `work_orders` 表头本身**没有任何指向物理对象的外键**(只有 code/status/
  scheduled_date/notes 与生命周期列)。

所以工单**结构上无法承载一台机器**:它的两张子表都强制要求物料。
(表头没有主体列 —— 主体是由子表定义的,这一点值得记住:
往表头加一个 `asset_id` 并不会让它变成设备工单,子表仍然只认物料。)

### C2 · 周期性义务的既有形状(报告形状,不提建议)

**`certificate_types`(CMP-1)是这个仓库里唯一的"到期提醒"先例**,形状是:

* 一张 **RUNTIME CONFIG** 表,操作员在界面上增改 ——「加一种是编辑一行,不是跑一次迁移」;
* 每一类自带 **`warn_lead_days`**(提前多少天上看板)**和 `disposition`**
  (`block` 挡收货 / `warn` 只提醒 / `ignore` 不管)—— **提前期与后果都是数据**;
* 实例挂在 `supplier_compliance.valid_until` 上;
* 看板那一支是 `qualification_expiring`:`valid_until <= CURRENT_DATE + ct.warn_lead_days`;
* 另有 `qualification_missing` 一支,专管"根本没有这份证书"——
  **"缺席"与"快过期"是两支,不是一支**。

物流那四支(LOG-5a)是同一族的另一种:阈值 2/14/7 **写死**,
而 `dashboard-arm-inventory.md` 里点名 `warn_lead_days` 作为"要可调时抄哪里"。

### C3 · 支出单据与"批次以外的物理对象"的既有连接

**一般模式:支出单据指向【单据】或【批次】,极少指向物理对象。** 全库:
* `expenses` → `fixed_assets`(经 `p_asset`,**唯一指向物理对象的**)
* `freight_documents` → `containers`(LOG-4a 加的,可空)
* `freight_allocations` → `inbound_batches`
* `processing_cost_entries` → `processing_runs`(过程,不是物体)
* `payment_allocations` → 六种**单据**

也就是说 **B2 那条路(expense → asset)本身就是这个仓库里唯一的先例**。

---

## D · 进口这一头(只报地面,不做决定)

### D1 · 进货运费绑在批次上 —— 确认

`freight_allocations.inbound_batch_id` **NOT NULL** → `inbound_batches(id)`;
`UNIQUE(freight_document_id, inbound_batch_id)`;索引 `idx_freight_allocations_batch`。
`record_freight_document` 的分摊数学也全部读 `inbound_batches`(quantity / unit /
unit_price / remaining_qty),借方按在库比例拆 1200/5000。
`freight_documents` 自己的外键只有:supplier / currency / journal_entry /
reversal_entry / **container**。

**直接回答:一台进口机器的运费,今天【没有】家。**
进货那一支强制要求进料批次(机器不是批次);出境那一支借 6300 费用,
且语义是"我们发出去的货"。**要把它计入机器成本,只剩 `record_expense` +
`p_asset` 追加这一条**,而那条不经过运费族、也不产生运费单据。

### D2 · 集装箱只接出境 —— 确认

`shipments.sales_order_id` **NOT NULL** → `sales_orders(id)`;
`shipments.container_id` 可空 → `containers(id)`。
**能挂进箱子的只有发货单,而发货单必须属于一张销售订单。**
进口的箱子因此**在系统里表示不出来** —— 没有"进货侧的发货单"这种东西。
(`containers` 自己不区分方向:它只有 lane / forwarder / departure_date /
expected_arrival_date 与里程碑;**把它用于进口所缺的是"装什么"那一头**。)

### D3 · 一台进口机器要像集装箱那样被跟踪,缺什么(陈述,不设计)

1. 一个能挂进 `containers` 的**非销售单据**(今天只有 `shipments`,而它 NOT NULL 指向销售订单);
2. 一条把**机器**(而非批次)与那个箱子相连的路径;
3. 运费那一族的一个**非批次分摊去处**(今天 `freight_allocations` NOT NULL 指向批次);
4. 里程碑与单据清单本身**不需要改** —— 它们只认 `container_id`,与装的是什么无关。

---

## E · 编号与身份

### E1 · 已占用的前缀

`ASY- BS- CN- CTR- EMP- EXP- FA- FRT- INV- JE- LV- MC- PAY- PF- PO- QT- SHP- SO- TRC- WO-`

**`FA-` 已经是固定资产的前缀**(`record_expense` 里 `fixed_asset_code_` 的 advisory 锁 +
`FA-YYYY-NNNN`)。设备如果要单独一族号,得另挑;若沿用资产台账,`FA-` 就是它。

### E2 · 序列号 / 制造商 / 型号

**全库没有。** `db/tables/*.sql` 搜 `serial_number` / `manufacturer` / `model` 零命中
(`pricing_formula` 的匹配已排除)。
`fixed_assets` 能承载这类信息的只有 `description text` 与 `notes text` 两个自由文本列。

---

## F · 读系统读不出来的东西(只列,不决定)

1. **资本化边界**:哪些支出进机器成本、哪些当期费用化?
   运保关税、安装、调试、试车料、培训、自有人工 —— 每一项都是一次判断。
2. **大修 vs 日常维护**:什么样的支出延长寿命(资本化、可能改折旧年限),
   什么样的只是维持(费用化)?
3. **折旧起算**:`in_service_date` 由谁按什么事实来定?
   到货?安装完?试车通过?第一次投产?(`set_asset_in_service` 已经把这个日子
   做成一个【人的动作】,但没有规定它对应哪个事实。)
4. **一台机器 = 一张卡,还是可拆分?** 主机 + 输送线 + 电控柜可能寿命不同。
   今天 `fixed_assets` 没有父子关系。
5. **机器要不要建成 `materials` 行?**(B3b 的后果)建了就能开 PO、能走预付,
   但也同时进入收货 / 库存 / 化验 / 安全库存那一整套 —— 它们对一台机器都无意义。
6. **押金与未完工项目**:押金付了而机器最终没来,那笔已经在 1500 的钱怎么退场?
   `fixed_asset_cost_entries.amount_base > 0` **不允许负数行**,
   而 `dispose_fixed_asset` 是"处置",语义不是"这台机器从来没存在过"。
7. **谁记维护?** 操作侧的人做保养,而记录落在财务模块下(资产在 finance)——
   权限码是一个决定(参照免柜期那一支用 `arm_permission_widen` 放宽给两边)。
8. **四台机器值不值得一个模块?** 量很小;而"值不值得"是业务判断,不是读得出来的。

---

## 停在这里的税务问题(按标准规矩,本刀不碰)

* **进口机器的 GST**:与进口 GST 同一族 —— 可抵扣进项税(1400),**永不资本化**。
  今天 `finance_settings.gst_registered = false`、税率 0,且**全库没有任何一处往 1400 过账**。
* **资本免税额 / Capital allowances**(新加坡 S19/S19A):与账上折旧是**两套数**。
  今天系统只有账上折旧(6700),没有任何税务折旧的概念。
* **进口关税**:与 LOG-3 勘察记的一样 —— 没有科目、没有表、没有列、没有函数、没有数据。
  机器进口若有关税,它今天无处可去。

**三条都不是本刀的 scope,也不该被顺手做掉。** 记在这里,是因为它们会在
【第一台机器到岸时】第一次被人问起。

---

## 非阻塞的设计问题(记下来,不进聊天报告)

* `fixed_assets` 三张表**都没有 `deleted_at`**,也没有软删门 —— 一台错建的资产
  今天只能"处置"掉,而那与"它从来不该存在"不是一回事(与 F6 同源)。
* 三张表**一个触发器都没有**:`cost_base` 与成本明细之和的一致性
  完全靠 `record_expense` 自己维持(fixture 77B 断言了这一条,但那是行为断言,
  不是结构保证)。
* `fixed_assets.category` 的四个取值是 CHECK 而不是 RUNTIME CONFIG 表 ——
  与 `certificate_types` 的做法相反;加一类要跑迁移。
* `depreciation_account_code` 逐资产可设(默认 6700),但**没有界面暴露它**。
* `fixed_asset_cost_entries` 没有"这一笔是什么"的分类列(运费?安装?培训?)——
  只有金额与来源支出;日后要回答"这台机器的成本里安装占多少"答不出来。
