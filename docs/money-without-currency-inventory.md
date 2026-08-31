# 没有币种的金额 —— 清查与整改(ASY-3 清查 / CCY-1 整改,2026-08-10)

**规则:屏幕上的每一个金额都要能就近读出币种** —— 单元格里、列头里、行标签里,
或者面板顶上一句"以下为 {ccy}"。尤其是**同一块面板中途换币种**时,必须标出分界。

起因:化验影响面板。上半截是行情口径的 USD(列头写着 `Price (USD/t)`、
`Value (USD)`),下半截的当前/新单价、差额、调整总额、计入存货、计入销售成本
全是**本位币且一个字都没有** —— 6.34 USD/kg 与 8.1152 SGD/kg 相隔三行,
中间没有任何标记。ASY-1 之前这一块**连数都是错的**(少乘一次汇率),
所以两个毛病是叠在一起的。

## 已修(ASY-3)

| 文件 | 修法 |
|---|---|
| app/inbound/[id]/assays/AssayImpactPreview.tsx | 六个金额的标签都带 `{ccy}`(本位币来自 `currencies.is_base`,页面 `getBaseCurrency()` 后传入);块顶加**分界线**:「以下为本位币 SGD,按 1.30(tt_sell,2026-08-10)自 USD 折算 —— 上方明细是 USD 口径」。汇率与取价日是 ASY-1 起 DB 一并返回的,所以分界线不只说"换了",还说清**怎么换的** |
| 化验录入页 / 化验详情页 / 批次编辑页的重计价面板 | 三个消费方都把 `baseCurrency` 传进去(同一组件,三处入口) |
| app/finance/processing-costs/CostSettlePanel.tsx | **不是漏标,是坏字**:文案是 `'Accrued selected: {accrued} {ccy}.'`,调用只传了 `accrued`,而解析器对认不出的占位符原样保留 —— 屏幕上真的印着「1,234.00 {ccy}。」。补传币种 |

## 整改(CCY-1):把默认翻过来

**病不在"无币种存在",而在"无币种是默认"**。一列同币种的数字、列头写了币种,
不必每格重复 —— 这是对的。错的是 `formatMoney(n)` 打起来最省事,于是 23 个屏幕
一路裸奔。

`lib/format.ts` 现在是:

* **`formatAmount(n, ccy)` —— 平常的那个**,渲染「1,234.56 SGD」。
* **`formatMoneyBare(n, ccyStatedIn)` —— 省掉币种要多写一句话**:第二个参数是
  **必填的**,内容是"币种写在哪儿"的人话,例如
  `formatMoneyBare(x, '列头「金额 ({ccy})」')`。说不出来,就说明这里本该用
  `formatAmount`。于是**漏标从"少打几个字"变成了类型错误** —— 全部 185 个旧调用点
  一次性变红,只能逐个做决定。

**扫过之后**(三个方向并行,`npx tsc --noEmit` 全绿):

| 方向 | 加币种 `formatAmount` | 保持无币种、写明出处 |
|---|---|---|
| app/finance/** | 63 | 44 |
| purchasing / inbound / processing / inventory | 24 | 30 |
| hr / me / margin / pricing / components 等 | 23 | 32 |

**混着两种币的面板按规则三处理:给下半截加标签,而不是让它去指一个与自己矛盾的
抬头。** 采购单详情(抬头声明单据币种、预付款与收货区是本位币)、采购单列表
(预计总额是单据币种、已预付是本位币,并排;列表查询原本连 `currency` 都没取,
一并补上)、加工单详情、进料预付款面板、日记账详情、重估、固定资产、
应收/应付的顶部汇总条 —— 都是这一类。

**顺带挖出来的两处写死币种**:采购单详情的定额腿与付款条款模板列表,都在模板
字符串里给任意币种的金额缀了个 `USD`。**`check-currency-literals` 看不见它们**——
`stripLiterals()` 会把字符串内容整个剥掉再扫 jsx-text。已补一个 `template-text` 类
(只认"插值紧贴币种"这一形状,`USD/t` 这类惯例不误伤),并注伤验过:把那处
改回 `${…} USD` 即报红。计价器那段**纯文本明细**(供复制进邮件)是正当例外 ——
复制出去就没有列头了,每行必须自带单位 —— 已进 ALLOWLIST 并写明理由。

## 留给下一刀的两件事

1. **约 8 个文案键把币种烤进了标签本身**(`valuation.col*`、
   `processing.cost.colAmount`、`processing.detail.colAllocatedCost` 等写着
   `金额 (SGD)`)。现在有 `formatMoneyBare` 的出处说明指着它们 —— 标签一旦撒谎,
   出处说明就跟着撒谎。本位币再改一次,这些键与指向它们的说明会一起错。
   应当改成 `{ccy}` 参数。
2. **`invoices/[id]` 可能一直在错标**:`subtotal_base / tax_base / total_base` 与
   `payment_allocations.allocated_base` 按镜像是**本位币**,而页面既有的两处
   `formatAmount(…, inv.currency)` 是拿**单据币种**标它们的。本刀按文件既有惯例
   保持一致(没有改动既有那两处),但**若 `inv.currency ≠ 本位币,这一页从改动之前
   就在说谎**。要单独查一次:到底哪几个字段是本位币、哪几个是单据币种。

## 未修:这是一个**类**,不是两块面板 —— 23 个文件

清查跑遍 `app/**`,判据是"用户能否就近看出这是哪种货币"(数量、百分比、
公斤、天数不算;列头/行标签/邻近说明已标出币种的不算)。

**采购与批次**:`purchasing/orders/page.tsx`(单据币种的预计总额与本位币的预付款
**并排**,且列表查询根本没取 `currency`)、`purchasing/orders/[id]/page.tsx`
(抬头声明了单据币种,下方预付款/收货区却是本位币;另有一处硬写的 `USD`)、
`purchasing/orders/[id]/CloseReopenControls.tsx`、`inbound/[id]/edit/PrepaymentPanel.tsx`、
`processing/[id]/page.tsx`(同一页里产出腿的表**标了** (SGD),成本三行没标)。

**财务**:`finance/page.tsx`(试算表)、`balance-sheet`、`close`、`journal/[id]`
(列表页标了 `Amount ({ccy})`,详情页没标)、`journal/new/NewEntryForm.tsx`
(每行有币种选择器,合计却是本位币且不标)、`invoices/page.tsx`、`invoices/[id]`
(小计与总计**标了**、中间的税额没标)、`invoices/new`、`cost-variance`、
`revaluation`(原币列对了,后两列本位币只标了一列)、`processing-costs/CostSettlePanel`
(那张表**没有表头**,无处可标)、`payroll-payments/PayPanel`、
`month-end/page.tsx`(CPF 那行传了 `{ccy}`,折旧那行没传 —— 同一张清单里不一致)。

**人事与自助**:`hr/reviews/[id]`、`me/MyReviewsPanel.tsx`、`me/page.tsx`(工资条
五个金额都没标,而 `/hr/payroll` 有币种列、`/hr/payroll/[id]` 抬头印
`{currency} @ {fx}`)。

**边缘四处**(同屏能推出来,但数字旁边没有):`components/pricing/PriceBreakdown`
汇总四行、`finance/receivables` 与 `finance/payables` 的顶部汇总条、
`hr/payroll/PayrollGrid` 的合计行、`inventory/page.tsx` 的汇总条。

## 为什么会漂成 23 处,以及唯一的单点治法

`lib/format.ts` 里本来就有一对:`formatMoney(n)` **故意不带币种**(注释写着
"列头标注币种"),被调用约 120 次;`formatAmount(n, ccy)` 返回「1,234.56 SGD」,
注释写着"凡是币种随数据变化的地方"用它。**每一处发现都是一个本该是
`formatAmount` 的 `formatMoney`。**

挡住"一把梭"的不是助手函数,是**参数**:`formatMoney` 是纯客户端函数,手里没有
币种;`getBaseCurrency()` 是服务端读 `currencies.is_base`。所以本位币金额得把
币种**穿进去**(`journal/page.tsx`、`pnl`、`payables`、`assets`、`margin` 已经这么
做),或者引入一个客户端 provider 换成一次改动;而**随行币种**(`*_ccy`、采购单
行、发票行)根本不能从全局拿,必须读行自己的列。

**执行层的缺口**:`scripts/check-currency-literals.mjs` 管的是**写死**的
'SGD'/'USD',没有任何东西管**漏标**。真要根治,只有两条:给 `formatMoney` 加一条
"结果必须与某个已渲染的币种相邻"的 lint(难),或者**弃用 `formatMoney`、
统一走 `formatAmount(n, ccy)`**(23 个文件的机械改动,但从此漏标是类型错误)。
这是下一刀的选择题,本刀只报数。

---

# 续:**币种标错了**的那一类(FX-DISPLAY-1,2026-08-31)

上面整篇治的是「**没有**币种」。这一节治的是它的姊妹病,而且更坏:
**币种写了,而且写错了。** 一个没有币种的数字会让人停下来问;
一个标着 SGD 的 USD 数字不会 —— 它会被直接抄进决策。

## 缺陷(INV-VAL-0 §1.1 记录,当时刻意不修,以免与存货计值那一刀纠缠)

`marketValuePerKg()` 读 `metal_prices.price_usd_per_tonne`,**全程没有折算**,
返回的是 **USD/kg**。两个消费方都把它标成 SGD:

| 位置 | 从前 | 现在 |
|---|---|---|
| `/inventory` 合计条 | `formatAmount(totalMarketValue, baseCurrency)` → **「1,870.00 SGD」** | 「Finished market value **(USD)** : 1,870.00」+ 分界线 + 一句说明 |
| `/inventory` 表格列头 | `Market Value (SGD)` | `Market Value **(USD)**` |
| `/inventory/output/[materialId]` 列头 | 同上(**同一个 i18n 键**) | 同上,一处改两页 |
| 同页合计行 | `Market Value (SGD) : …` | `Market Value (USD) : …` |

**实测(线上,2026-08-31)**:该数是 **1,870.00 USD**
(OUT-2026-0004 1,000.00 + OUT-2026-0007 570.00 + OUT-2026-0187 300.00),
从前印成 **「1,870.00 SGD」**,就摆在 `185,703.48 SGD` 与 `388.20 SGD` 中间 ——
**三个数看起来可以相加,而其中一个不是同一个币种,也不是同一类数。**

★ **合计条那一处是最坏的**:它的 "SGD" 是 `formatAmount(…, baseCurrency)`
在**运行时从 `currencies.is_base` 取出来贴上去的** —— 不是写死的标签,
所以它读起来比一句硬编码更像是系统算出来的结论。

## 裁定:**标对,不折算**(R1 / R2)

**折不了,这是实测出来的,不是偷懒:**

* `fx_rate_asof('USD', CURRENT_DATE, 'mid')` 返回 **零行**;
* USD 的 `mid` 牌价**总共只有一条**:**2026-07-31,1.255**,今天 **31 天**前;
* 而 `fx_rate_asof` 的回溯上限是 **4 个自然日**(`v_cap := 4`)—— 差了近 8 倍。
  (`tt_buy`/`tt_sell` 新一些,2026-08-17,仍在上限外,而且它们是买卖价不是中间价。)

要折就得**放宽上限**或**编一个汇率**,两条都被 R2 禁掉,而且都是拿一个假数
换掉一个真数。所以:**照实标 USD,并把它与账面数分开。**

### 【什么都不拒绝 —— 这是一个决定,不是一处遗漏】

委托书第 3b 条要求"拒绝与零不许长得一样"。这一刀**没有任何东西拒绝**:
改成 USD 之后就**不存在一个 SGD 数字**,也就没有什么要与零区分。
另一种写法是保留一个"SGD 等值"格子并让它具名拒绝 —— **那是在造一个 FX 特性,
只为了宣布这个 FX 特性用不了**,R2 明禁。缺席记在文档里(见下),不记在屏幕上。

### 要让它**真的**变成 SGD,缺的只有一样

**一条落在回溯上限之内的 USD `mid` 牌价。** 不是新的汇率源、不是改报价存储、
不是放宽上限 —— 就是有人把当天的中间价录进 `fx_rates`。
录进去之后,`marketValuePerKg` 之上加一层折算即可,而**在那之前,
这个数标 USD 是它唯一诚实的样子。**

## 报价本身的币种:结构上唯一,来源上无凭

`metal_prices` **没有币种列** —— 币种烤在列名 `price_usd_per_tonne` 里,
所以它**不可能逐行不同**,函数"只有一种币"的假设结构上成立,不是撞运气。

但诚实到底:线上 10 条报价**全部** `source='unknown'`、`price_index` 为空。
**Schema 断言了单位,没有任何证据支持它。** 这是金属报价的溯源问题,
自成一条,不在本刀里以 UI 提示的形式扩写(R2)。

## 顺手改掉的三行注释(**只有注释,没有行为**)

同一个模块里另有三处**反向**的币种谎话,INV-VAL-0 §6 第 7 项排过:

* `InboundValuation.unitPrice` 注释写 `USD/kg`,而它是 **SGD/kg**
  (`reprice_inbound_batch` 存的是 `original_price × fx_rate`;
  线上 IN-2026-0181 = 6.34 USD × 1.28 = **8.1152**,存下来就是 8.1152)。
  **屏幕一直是对的**(列头写「单价 (SGD)」),只有注释在撒谎;
* `OutputValuation.unitCost` 同样(`unit_cost_base`,`_base` 就是本位币);
* `lib/format.ts` 的 `formatUnitCost` 注释写「单位成本(USD/kg)」,
  而它和 `formatMoneyBare` 一样**根本不知道币种** —— 八个调用点里
  `unit_price`/`unit_cost_base` 是本位币,`estimated_unit_price` 跟着采购单走。
  一个**宣称币种的格式化函数**会让调用点省掉"这是什么币"这个问题,
  而那正是本刀所修缺陷的成因。
