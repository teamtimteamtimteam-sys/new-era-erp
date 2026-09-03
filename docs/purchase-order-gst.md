# PO-GST-1 · 采购单开始携带税(2026-09-03)

**FA-PO-1 查清了 GST-2 把税放在【费用/发票】那一层,采购单上一列税都没有 ——
那描述的是【建成了什么】。Tim 裁定建成的这个是错的。**

采购单是**供应商拿到的那张纸**。它的总额必须是供应商将要开票的那个数;
承诺出去的现金是含税的那一个 —— 否则差 9%。
**证据已经在数据里:PO-2026-0008 的取消理由原文就是 `GST not included`。**
一张真实的单据因为这件事被取消掉了。

---

## 一 · 四条裁定,建成了什么

| 裁定 | 建成的样子 |
|---|---|
| **①a 税码在【行】上,由供应商播种** | `purchase_order_lines.tax_code`,下单时由 `suppliers.default_tax_code` 经 **`resolve_tax_code`**(费用那一层用的同一支)播下来;本行可覆盖。**没有铸任何新税码** —— 用的就是 GST-1 那九个 |
| **①b 供应商的「默认税码」字段就是判据** | 不看国别、不看 `tax_residence`、没有新字段。OP / ZP 行贡献**零**新加坡 GST(实测,下表);没有设默认码的供应商**按名拒**(`TAX_CODE_REQUIRED|supplier`) |
| **①c 税是【存下来】的,不是读的时候再算** | 行上三列:`tax_code` · `tax_rate_pct` · `tax_amount_ccy`;表头 `tax_total_ccy` |
| **①d PDF 在这一刀里改** | 供应商手里那张纸现在印净额 / GST / 应付总额三行,并在有 OP 行时印那句进口 GST 的说明 |

---

## 二 · 加了哪些字段,各自存什么

| 字段 | 存什么 | 遮蔽 |
|---|---|---|
| `purchase_order_lines.tax_code` | 这一行的**进项**税码(TX/ZP/EP/BL/OP)。可空 —— NULL 只出现在本刀之前的历史行与 GST 未注册时开的行 | 不遮蔽(是分类,不是钱) |
| `purchase_order_lines.tax_rate_pct` | **下单那一天**这个税码的税率,冻在行上 | 不遮蔽(法定税率) |
| `purchase_order_lines.tax_amount_ccy` | 这一行的税额,**单据币种**,逐行取整两位小数 | **随 `data.view_prices`** |
| `purchase_orders.tax_total_ccy` | = Σ 行 `tax_amount_ccy` | **随 `data.view_prices`** |

**含税额【不落库】。** 它是导出量:`net + COALESCE(tax, 0)`,由
`purchase_orders_masked.gross_total_ccy`(屏幕与清单读它)与
`po_document_data`(PDF 读它)各算一次,而 **fixture 190 E 臂断言两者逐分相等**。
存第三个数就是给自己第三个会漂的地方 —— 净额改了而它没跟上,是一个看起来完全正常的错数。

### `estimated_total_ccy` **仍然是净额,一个字节都没动** —— 而这是本刀最要紧的决定

逐处查过,**三样东西挂在这一列上**:

| 挂着的东西 | 在哪 |
|---|---|
| **审批级别** | `approval_level_for(round(estimated_total_ccy × fx_rate, 2))` —— `approve_purchase_order:52` · `reject_purchase_order:34` · `void_approval_on_amount_increase:21-22` |
| **付款里程碑的百分比** | 「percentage 是对该 PO 的 `estimated_total_ccy` 而言」(`purchase_order_payment_terms.sql:9` 的原话) |
| **现金预测** | `cash_forecast_data:73` 拿它乘百分比 |

**把它改成含税,这三样会对【既有单据】同时移位** —— 审批阈值上下翻越、里程碑金额变大、
预测跳 9%。而委托书 ④ 明确要求"任何既有单据显示的总额都不应改变"。
所以:**净额留在原处,税另立一列。**
**这三样今天仍然按净额走 —— 而那是三个【要 Tim 裁】的问题,见第六节。**

---

## 三 · 一份实现:税额算式的提取

**提取之前它有四份,逐字相同,而它决定钱:**
`record_expense:256` · `create_invoice:163` · `create_order_invoice:161` · `f5_return:86`。

```sql
CREATE OR REPLACE FUNCTION public.tax_amount_for(p_amount numeric, p_rate_pct numeric)
 RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT round(p_amount * p_rate_pct / 100.0, 2)
$$;
```

**四处全部改成调用它**,表达式一个字符没变(所以任何值都不可能变)。
与 TOOLS-1 提取 `convert_weight_basis` 是同一条判据。
实测:提取之后全库 `round(… × tax_rate … / 100)` 的内联写法 **0 处**。

### 取整口径,以及它的出处

**逐【行】算、逐【行】取整;单据头的税 = Σ 行税,不是 `round(Σ 净额 × 税率)`。**

出处是 `create_order_invoice.sql:154` 的原话:

> 【逐行算税、逐行取整】表头的税 = Σ 行税,不是 round(Σ 行净额 × 税率):
> **两种算法差几分,而客户手里那张纸上印的是行。**

**采购单原样照搬这一条** —— 只是那张纸在**供应商**手里。
两种算法在一张多行单据上差几分;选逐行,是因为对方核对的是行。

---

## 四 · ★ 供应商手里那张纸上,一字不差印着什么 ★

**Tim 在寄出第一张之前可以否掉这里的任何一句。**

### PDF 的总额区(`PurchaseOrderDocument.tsx`)

```
Subtotal (excl. GST) (SGD)              333,049.50
GST (SGD)                                29,974.46
Total payable (incl. GST) (SGD)         363,023.96      ← 加粗
```

**不带税的历史单据只印一行**,与从前逐字相同:

```
Estimated total (SGD)                   333,049.50
```

> **为什么不给历史单据印一行「GST 0.00」** —— 那是一句**断言**(算过了,是零),
> 而真相是"这张单没有算过税"。一个 0.00 会把后者说成前者。

### 有 OP 行时,PDF 多印这一段(逐字)

> **Lines marked out-of-scope (OP) carry no Singapore GST payable to you.
> Import GST on these goods, if any, is paid by us to Singapore Customs
> at the point of clearance.**

**为什么必须有这一句:** 一条 OP 行的 GST **不是零 —— 是【不付给这家供应商】**。
不说,一个读到「GST 0.00」的海外供应商会以为这批货完全不涉税。

### 屏幕上的三句(英文原文)

| 何时 | 原文 |
|---|---|
| 这张单带税 | *GST is shown per line at the rate in force on the order date, and is frozen on the order — a later rate change does not alter this document. The supplier invoices the total payable shown above.* |
| 这张单没算过税 | *This order was raised before purchase orders carried GST, so no tax was calculated on it. That is not the same as zero GST — the amount above is exclusive of any tax the supplier may charge.* |
| 有 OP 行 | *Lines marked out-of-scope (OP) carry no Singapore GST payable to this supplier. Import GST on those goods, if any, is paid by us to Singapore Customs at the point of clearance.* |

**FA-PO-1 那一句被取代了。** 它说的是「本单不含税,税在录发票时产生」——
在 Tim 裁定采购单必须携带税之后,**它不再为真**。
留着一句过期的解释比没有解释更坏:它会让人相信屏幕上那个数是全部。

---

## 五 · ①d 那个发现:屏幕与 PDF 本来就算自不同的地方

**说出来的那一半:**

| 谁 | 读哪里 |
|---|---|
| **PDF** | `po_document_data()`(SECURITY DEFINER rpc,fixture 36 读的也是它) |
| **屏幕 / 清单** | 直接读 `purchase_orders_masked` / `purchase_order_status` |

**它们今天一致,靠的是两条路碰巧落在同一列 `estimated_total_ccy` 上 —— 不是靠构造。**
加了税之后,`net` 与 `tax` 仍是同两列(不会漂),但 `gross = net + tax` 这次加法会出现在两处。

**处置:**
* `gross_total_ccy` 与 `carries_tax` 放进 `purchase_orders_masked` 与 `purchase_order_status`
  —— **屏幕与清单自己不做加法**;
* **fixture 190 E 臂断言三处对同一张单逐分相等**,而不是靠人去看两张纸。
  外部故障注入把 PDF 那一侧的含税额漂了一分,E 臂当场变红(见第七节)。

---

## 六 · ★ 留给 Tim 的三个决定(本刀刻意没有替他做)★

这三样今天**仍然按净额走**。改动都是一行,判断不是。

| # | 问题 | 今天 | 改成含税会怎样 |
|---|---|---|---|
| **1** | **审批级别按净额还是含税额?** | 净额 | 一张净额 9,500 的单今天是一级;含税 10,355 就跨过 10k 门槛变二级。**这会改变【既有单据】的审批归属** |
| **2** | **付款里程碑的百分比,是净额的百分比还是含税额的?** | 净额(列注释明写) | 新加坡实务里,一张 50% 定金发票**是要开 GST 的**。按净额算,定金那一期会少收 9%。**这一条我认为最可能是真缺陷,但它改的是既有单据的里程碑金额** |
| **3** | **现金预测承诺出去的是净额还是含税额?** | 净额(跟着 ②) | 委托书那句「承诺的现金是含税的那一个 —— 否则差 9%」正指这里。它跟着 ② 走,单独改会与里程碑不一致 |

**②③ 是同一个决定的两半**(预测读的就是里程碑),①是独立的。

---

## 七 · 证明

**七条全部实测,fixture `db/fixtures/190-…sql`,`FIX190_EXIT=0`。**

| 臂 | 钉什么 | 实测 |
|---|---|---|
| **A** | 本地(TX)供应商标准税率;gross = net + tax | 净额 1000 → 税 90.00 → 含税 1090.00;税率由 `tax_rate_for('TX', 下单日)` 解析,不写死 |
| **B** | **OP 供应商零新加坡 GST**,且单据知道自己带 OP 行 | 税 **0.00**;`has_out_of_scope_line=true`,而不带 OP 的单报 `false`(一个恒真的标志说明不了任何事) |
| **C** | 没有默认税码 → **按名拒** | `TAX_CODE_REQUIRED|supplier`。而本行显式给码仍开得出来 —— 拒的是"没有人回答过",不是"这家不能下单" |
| **D** | **存下来的税不随税率漂移** | 在回滚事务里把 TX 现行税率改成 30%:既有单税额**一分未动**;**同时**断言新开的单变成 300 —— 少了这一句,"没动"可能只是因为根本没在算 |
| **E** | **屏幕与 PDF 是同一个数** | `po_document_data` vs `purchase_orders_masked` vs `purchase_order_status`,net/tax/gross 逐分相等,且 gross = net + tax |
| **F** | **费用路与采购单路对得上分** | 同净额、同税码、同日期:`record_expense` 的 `tax_base` 与采购单行的 `tax_amount_ccy` 逐分相同 |
| **G** | **既有单据没有凭空长出税** | `tax_total_ccy` 为 NULL 时 `carries_tax=false`,含税额 = 净额 |

### 故障注入

**三次内建**(在 fixture 里,每次改完还原):

| 注入 | 做法 | 守的是 |
|---|---|---|
| 1 | `tax_amount_for` 恒返回 0 | A 臂读到的税**确实是这支函数算的** |
| 2 | 把 OP 的税率改成 9% | B 臂那个零**来自 OP 的税率**,不是写死的 |
| 3 | 给那家供应商设上默认码 | C 臂拒的是"没有人回答过",不是别的 |

**三次外部**(跑在 scratchpad 的**副本**上,**工作树自始至终没脏过**,没用过 `git checkout --`):

| 注入 | 结果 |
|---|---|
| **B(委托书点名第一个做的)** 让下单忽略供应商税码、一律按 TX | **红:`FIXTURE 190B 失败:…实得 90.00`,`exit 3`** |
| **C** 没有默认码时悄悄当成 ZP | **红:`FIXTURE 190C 失败:…实得 (收下了)`,`exit 3`** |
| **E** 让 PDF 那一侧的含税额漂一分 | **红:`FIXTURE 190E 失败:…必须逐分相等`,`exit 3`** |
| 干净重跑 | **`FIX190_EXIT=0`** |

### 既有单据:实测没有任何一个数字动过

| 单据 | 净额 | 税额 |
|---|---:|---|
| PO-2026-0001 … PO-2026-0008 | **与迁移前逐字相同** | **全部 NULL** |

`purchase_order_lines` **8 行,带任何税值的:0 行**。
`purchase_orders` **税额非 NULL 的:0 张**。**迁移不回填,一行都不碰。**

---

## 八 · ★ 一件会立刻咬到 Tim 的事 ★

**线上 16 家供应商里,只有 1 家设了默认税码**(`SUP-2026-0095` Bosch Rexroth = TX)。
**其余 15 家全是 NULL** —— 包括那家中国供应商 `SUP-2026-0003`。

**于是从这一刀起,给那 15 家里任何一家开采购单,都会按名拒 `TAX_CODE_REQUIRED|supplier`。**

这**正是 ①b 要求的行为**(「refuse by name rather than silently treating it as zero」),
而且与费用那一层**逐字同一条规矩**。但它意味着:

> **发第一张新采购单之前,Tim 要先把供应商的「默认税码」补上** ——
> 本地设 `TX`,海外设 `OP`。系统**刻意不从国别推断**这件事(那是 ①b 的裁定)。

一条补救的路已经在:**本行显式给税码**仍然开得出单来(fixture 190 C 臂第二段钉住)。

---

## 九 · 改单之后,存下来的税怎么走

| 情形 | 处置 |
|---|---|
| **改数量 / 改单价** | 税额按**新的净额**重算,**但税率不重解析** —— 用行上冻着的 `tax_rate_pct`。改单改的是金额,不是这一行的税务性质,也不是这张单的日期 |
| **改单加进来的新行** | 税率按**这张单的下单日**解析,不是按今天 —— 同一张纸上不该出现两个税率 |
| **历史行(`tax_rate_pct` 为 NULL)** | **保持 NULL**。改一改数量,不该让一张本刀之前的单凭空长出一个它当时没有的税额 |
| **表头** | 与净额**在同一条语句里**算完(原因与旧注释逐字相同:作废触发器盯着净额那一列,两个数必须来自同一批行);`SUM` 不套 `COALESCE(…,0)`,所以全 NULL 时合计仍是 NULL |

---

## 十 · 一个我自己开的洞,以及它为什么没有被闸拦住

主迁移里我写了:

```sql
GRANT SELECT (tax_total_ccy) ON public.purchase_orders TO authenticated;
```

**那是错的。** `purchase_orders` 的两列钱(`estimated_total_ccy` / `fx_rate`)
**刻意都不在列清单授权里** —— 它们只经 `purchase_orders_masked` 读,
视图里那个 `CASE` 才是 `data.view_prices` 那道门。
我发了表级授权,等于让任何持 `module.purchasing.view` 的人**绕过遮蔽直接读到税额**
—— 而知道税额与税率,净额就是 `tax / rate × 100`。

**处置:** `fu1` 迁移当场收回(实测授权数 1 → 0)。洞存在约 **2 分钟**。

> **★ 为什么没有任何一道闸拦住它 ★**
> `colgrant` 那道闸问的是「遮蔽表的每一列**要么**被列授权、**要么**在 `_masked` 里」——
> 它防的是**读不出来**,不是**读得太多**。一个多发的授权对它完全合法。
> **那道闸的方向是单向的**,记在这里,因为下一个给遮蔽表加列的人会以为它两头都守。

---

## 十一 · 只有人走得了的那几处

1. **`/purchasing/orders/[id]` 的表尾** —— 三行(不含税小计 / GST / 应付总额),
   最后一行加粗。**PO-2026-0007 与 0008 应当仍然只有一行「估算总额」**(它们没算过税)。
2. **那三句说明**(带税 / 没算过税 / 有 OP 行)读起来是不是人话,中英两版都要看。
3. **★ 下载一张真的 PDF ★** —— 这是本刀的重点。要读到 `Subtotal (excl. GST)` /
   `GST` / `Total payable (incl. GST)` 三行,以及 OP 那一段。
   **在寄给任何供应商之前,Tim 要逐字看过第四节那些英文。**
4. **`/purchasing/orders` 清单**多了两列(GST · 应付总额);
   没算过税的行 GST 那一格应当是 **「—」而不是 0.00**。
5. **给一家没有默认税码的供应商开单** —— 应当读到一句**具名的**拒绝,
   而不是一张税额为零的单。**这一条最该先走**(见第八节)。
6. **中英切换**:本刀新增 7 条文案键。
