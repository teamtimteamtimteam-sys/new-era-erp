# 币种写死 —— 一次清点,之后交给检查

人扫了两轮,每轮都漏一处,第三处又是走查发现的。所以不再扫,改成
`scripts/check-currency-literals.mjs`(进 `npm run build` 与 `db/gate.py`)。

**首次运行:32 处,例外 0 处。** 名单没有变长 —— 说明规矩是对的,是代码不对。
(唯一的例外后来才出现:见文末。)

## 代码里的 32 处

### 一、活着的错(与 FIN-12 同一个病:把 USD 当本位币)

FIN-0 之后本位币是 SGD,这些 `=== 'USD'` 判断于是全反了:

| 位置 | 后果 |
|---|---|
| `finance/journal/new/NewEntryForm.tsx:68,70,191` | **手工凭证录不进本位币行** —— SGD 行被要求填汇率、金额算成 0;USD 行反倒按 1:1 折算 |
| `finance/journal/new/actions.ts:62,64` | 服务端同样:SGD 行被判为"需要汇率",提交直接报 FX_RATE_REQUIRED |
| `finance/expenses/page.tsx:182`、`journal/[id]/page.tsx:177`、`payments/page.tsx:170`、`receivables/[saleId]/page.tsx:166` | "非本位币才显示汇率"判成了"非 USD 才显示" —— SGD 行多显示一个汇率,USD 行反而不显示 |

### 二、写对了但仍是常量(`=== 'SGD'`)

`expenses/[id]/page.tsx:167`、`NewExpenseForm.tsx:56,135,220`、
`payments/[id]/page.tsx:201`、`PricingPanel.tsx:107,155`、`SalePanel.tsx:133`、
`purchasing/orders/[id]/page.tsx:215`、`NewOrderForm.tsx:259`、
`hr/payroll/[id]/page.tsx:57`

今天是对的,下次改本位币时会和第一类一起变成错的 —— 区别只是它们现在还没被踩到。

### 三、默认币种(`?? 'USD'` / `?? 'SGD'`)

`expenses/new/actions.ts:23`、`payments/new/actions.ts:23`、
`journal/new/actions.ts:62`、`pricingActions.ts:46`、`saleActions.ts:19`、
`purchasing/orders/new/actions.ts:50`、`hr/payroll/actions.ts:47`、
`hr/payroll/[id]/edit/page.tsx:60`

**这一类彼此还不一致**:有的默认 USD,有的默认 SGD。同一个概念两种答案。

### 四、银行账户 ↔ 币种映射

`NewExpenseForm.tsx:50`、`NewPaymentForm.tsx:98,104`、
`ImportStatementForm.tsx:105`、`hr/payroll/[id]/page.tsx:57`

其中 `NewPaymentForm.tsx:104` 是 **FIN-12 里我自己刚写下的** —— 检查装好当天
就抓到了它。这正是"别再靠人记得"的证据。

**处置**:一、二、三类改为 `getBaseCurrency()`(读 `currencies.is_base`,
每请求缓存;客户端组件由页面传 prop)。第四类收进 `lib/currencyMap.ts` 一处,
对应 `bank_native_currency()`。**最终:0 处未授权,1 处例外(即那份映射,写了理由)。**

## 译文里的币种 —— check-i18n 看不见的那一半

`check-i18n` 只验键在不在,从不看键说了什么,所以 `'Amount (SGD)'` 对它是透明的。

### 该改的:把币种当参数(已改)

`finance.colAmount`(两处)、`expense.amountPreview`、`expense.filteredTotal`、
`finance.monthEnd.cpfDetail`、`finance.costSettle.preview`

都改成 `{ccy}` 占位符,由调用方传【行的币种】或本位币 —— 与付款汇总现在的做法一致。
`purchasing.form.modeFixed` 原文直接是 `'USD'`(表示"定额"而非"百分比"),
已改为 `Fixed` / `定额`:它压根不是在说币种。

### 确实固定的:留着,理由在此

| 键 | 为什么固定 |
|---|---|
| `metalPricesDesc`、`colPrice`、`price`、`colTreatment`、`treatment`、`unitPrice`(USD/t、USD/kg) | 金属行情按国际惯例以 **USD/吨** 报价,库里的列名就是 `price_usd_per_tonne`。这不是本位币假设,是这个量本身的单位 |
| `bankAccounts.1000: 'Bank – SGD'` / `1010: 'Bank – USD'` | 账户的**专名**,就叫这个 |
| `fxHint`、`colRate`(`1 unit = ? SGD`)、`errFxMissing` | 汇率表的定义就是"每单位外币折多少本位币",列名 `rate_sgd_per_unit` 也把 SGD 写死了。**标签与 schema 是同一个假设**,单改标签只是化妆 —— 要改就连列名一起改,属于换本位币时的整体动作 |

### 已量过:标签错了,`*_usd` 没错

`pricing.colValue` 写着 `'Value (SGD)'`。手算与系统对过之后可以确定:**标签是错的。**

`calculate_metal_price_internal` 里【没有一处 fx_rate_for】(grep 计数 0)。
输入是 USD(`price_usd_per_tonne`、`treatment_charge_usd_per_tonne`),
输出也是 USD(`gross_value_usd` / `treatment_usd` / `discount_usd` /
`net_value_usd` / `unit_price_usd_per_kg`)。整条链路不换汇。

手算(PF-2026-0001,405 kg,含镍 10%,payable 70%,TC 800 USD/t,折扣 20%,
参考日 2026-07-30,均价口径 30 天 = 15,500):

| 步骤 | 手算 | 系统 |
|---|---|---|
| 含镍量 | 405 × 10% = 40.5 kg | 40.5 |
| 计价量 | 40.5 × 70% = 28.35 kg | 28.35 |
| 金属价值 | 28.35 ÷ 1000 × 15,500 = **439.43** | 439.43 |
| 加工费 | 405 ÷ 1000 × 800 = **324.00** | 324.00 |
| 折扣 | 439.43 × 20% = **87.89** | 87.89 |
| 净值 | 439.43 − 324.00 − 87.89 = **27.54** | 27.54 |
| 单价 | 27.54 ÷ 405 = **0.068** | 0.068 |

**逐项相符,且【没有乘任何汇率】。** 若按当日汇率折算,净值应是 27.54 × 1.35 ≈ 37.18。
所以:换汇是【缺失的】,`*_usd` 的命名是准确的(不是 FIN-0 遗留),
错的是 `'Value (SGD)'` 这个标签 —— 或者说,错的是"这条链路本该换汇却没换"。

### 缺行情时不拒绝,反而算出一个负单价

同一个公式,参考日换成 2020-01-01(那天没有任何镍报价):

```
metal_value_usd: 0        price_usd_per_tonne: null     skipped_metals: ["ni"]
treatment_usd: 324.00     net_value_usd: -324.00        unit_price_usd_per_kg: -0.8
```

**它照样返回了数**:金属一个都没定上价,加工费却照扣,于是净值 −324.00、
单价 **−0.8 USD/kg**,`negative_value: true`。缺数据没有变成拒绝,变成了一个
看起来像算过的数字。函数里那句注释写得很直白:「缺行情从来不是硬错误」。

另外 `spot` 口径取的是 `price_date <= 参考日 ORDER BY DESC LIMIT 1` ——
**正是 fx_rate_for 专门拒绝的"就近取上一天"**。同一个仓库里,两套相反的规矩。


## 公式价的每一个去处 —— 会不会换汇(FIN-15 清点)

`calculate_metal_price` 全程 USD 进 USD 出(行情本身按 USD/吨报价)。它的结果
流向四处,此前只有一处做了换算 —— 而漏掉的那处正是【对外报价】那条路。

| 去处 | 换汇? | 说明 |
|---|---|---|
| `apply_assay_result` → `reprice_inbound_batch` | ✅ 一直正确 | 显式传 `'USD'`,由 `reprice_inbound_batch` 按定价日 `tt_sell` 折本位币。进料定价这条路没问题 |
| **采购单行估算** `computeLineEstimate` | ❌ **曾经漏掉,FIN-15 已修** | 公式给的是 USD/kg,却直接填进【单据币种】的价格框。单据是 SGD 时等于把 USD 价当 SGD 价用 |
| **`create_purchase_order`** 存 `estimated_amount_ccy` | ❌ 同上(由上一行的入参决定) | 存的是 `数量 × 行单价`,不做换算 —— 行单价折对了,这里就对了 |
| `/pricing/calculator` 显示 | ⚠️ 标签错,数字对 | 全程 USD,标签却写 `Value (SGD)`。**已改为 `Value (USD)`** —— 计价器就是个 USD 报价工具,不是记账屏 |
| `PriceBreakdown`(计价器与化验页共用) | ⚠️ 同上 | 同一个组件,同一个标签,一并修正 |

### 代价有多大

走查里的 PO-2026-0002:405 kg × 3/kg,存成 **1,215.00**。它自己存着 `fx_rate = 1.26`
—— 机器一直都在,只是没人用它。若单据是 SGD,应为 **1,530.90**,
**报低了 20.6%**(rounded fixture 实测)。

### 换算口径

USD → 单据币种 = `usd_price × fx_rate_asof('USD', 下单日, 'tt_sell') /
fx_rate_asof(单据币种, 下单日, 'tt_sell')`。

* 采购是我们【买】外币,所以两边都取 `tt_sell`,与 `create_purchase_order` 自身
  给单据估值时用的口径一致;
* 单据本身是 USD 时,两个汇率是同一个,比值为 1 —— **不需要特判**,换算式自然退化;
* 单据是本位币时,分母为 1(`fx_rate_asof` 对本位币恒返回 1,不查表);
* 缺牌价按 FIN-13 的规矩【拒绝】,并说明取自哪一天。
* 界面把换算摊开:`0.068 USD/kg × 1.2600 = 0.0857 SGD/kg (取 2026-08-05 的牌价)` ——
  一个折算过的价格,必须能看出它是从哪来的。

---

## FIN-18(2026-08-05):把币种当【正文】印出去 —— 检查看不见的那一半

本文件此前只记录"币种被当成判断条件"的实例。走查 PO-2026-0003 的收货一步时,
在 `/finance/payments` 上发现另一类:币种既不在比较里,也不在分支里,而是直接
写在 JSX 正文上。

```tsx
{r.currency !== baseCurrency && <span>= {formatMoney(r.amount_base)} USD</span>}
```

同一行【左边刚拿 baseCurrency 比过】,右边照样印死 `USD`。FIN-0 之后本位币是
SGD,于是一笔 USD 1,400 的付款在列表上显示成 `USD 1,400.00 = 1,736.00 USD`。
`check-currency-literals.mjs` 的七条模式一条也不匹配 —— 它们全都在找判断 ——
于是 `db/gate.py` 的 `currency` 行报绿。

### 扩检之后一次扫出六处,写法完全相同

| 文件 | 显示的量 |
|---|---|
| `app/finance/payments/page.tsx:174` | 付款折算基准额 |
| `app/finance/payments/[id]/page.tsx:205` | 同上,详情页 |
| `app/finance/expenses/page.tsx:186` | 开支折算基准额 |
| `app/finance/expenses/[id]/page.tsx:171` | 同上,详情页 |
| `app/finance/payables/[batchId]/page.tsx:148` | 进料批次应付额(变量名 `amountUsd` 也一并改成 `amountBase`) |
| `app/finance/receivables/[saleId]/page.tsx:173` | 应收单据金额 |

六处全部改为 `{baseCurrency}`(五处该页本来就已经取了 `baseCurrency`,
只是没用在这里)。

### 顺带修掉与留下的

* `app/finance/bank/TransferForm.tsx` 的银行账户下拉写死 `1000 · SGD` /
  `1010 · USD` —— 全站别处都用 `t('finance.bank.1000')`,这里改为一致
  (顺带补上中文,原先是英文硬编码)。
* **留下并写明理由**(ALLOWLIST):医疗报销的 `*_sgd` 列(按决策以新元计,
  列名即语义)、金属报价的 `USD/kg`(市场惯例;`calculate_metal_price` 全程
  USD 进 USD 出【是设计,不是缺口】—— 换算在路径上,由 `computeLineEstimate`
  在数字变成价格之前完成,见上面 FIN-15 那一节)。这两处的币种标签都是真的,
  换成本位币反而会说谎 —— 与本文其余各条方向相反,所以写明。

### 教训

这道检查存在的理由,就是"人扫会漏第三处第四处"。它确实拦下了判断类的 32 处 ——
然后在一个它从没学会看的形状上,连着放过了六处。**盲区不在没人写的地方,
在检查解析不到的地方。**

## 换本位币要手改的地方(OPS-8,2026-08-07)

FIN-0 换过一次本位币(USD → SGD),下一次换的时候,下面这些地方【不会自己跟着走】,
因为它们所处的语法位置写不出 `currencies.is_base` 的子查询:

| 位置 | 现在写的 | 换本位币时会怎样 |
|---|---|---|
| `db/tables/fx_rates.sql` 的 `CHECK (currency <> 'SGD')` | 本位币对自己没有牌价 | 反过来拦住【新】本位币的牌价、放行【旧】本位币的牌价 —— CHECK 约束不允许子查询,没有第二种写法 |
| `db/tables/purchase_orders.sql` `currency DEFAULT 'USD'` | 采购单默认币种 | 列默认值同样写不出子查询;默认值本身是业务选择,不一定要跟着本位币走,但要【看一眼再决定】 |
| `db/tables/payroll_periods.sql` `currency DEFAULT 'SGD'` | 工资期间默认币种 | 同上(新加坡工资本来就是新元,多半不用改 —— 但这是一次决定,不是一次默认) |

`check-currency-literals.mjs` 的 ALLOWLIST 里逐条写了理由并指回本节。
判断类的字面量已经全部改成读 `currencies.is_base`
(`db/migrations/2026-08-07-ops8-currency-is-base.sql`)。

### 那两族已经收口(OPS-11,2026-08-07)

* **jsonb 分录负载 `'currency', 'SGD'`** —— 54 处 / 17 个过账函数,全部换成
  `base_currency_code()`(取自 `currencies.is_base`)。逐处核对过科目,54 处
  没有一处是别的意思。
* **顺带删掉 28 处 `'fx_rate', 1`** —— `post_journal_entry` 对本位币行
  【无条件覆盖】fx,那个 1 从来没被用过;但它不是无害的死负载:哪天某处币种
  改成外币,遗留的 1 会顺着 ELSE 分支【静默】按 1:1 记一条外币账。删掉之后,
  同样那次修改会当场 `FX_RATE_REQUIRED`。核验过 28 处每一处最近的 `'currency'`
  都是 `'SGD'` 字面量,没有一处坐在外币行上 —— 所以删除不改变任何行为。
* **`DEFAULT '<币种>'` 5 处** —— 只有 `record_expense` 的 `'SGD'` 是本位币假设,
  且是死的(唯一调用方一直显式传值),已删(需要 DROP+CREATE:PostgreSQL 不许
  `CREATE OR REPLACE` 去掉既有默认值)。另外四处【本来就不是本位币的意思】,
  各自进 ALLOWLIST 写明理由:采购单默认 USD 是商务选择、工资期间默认 SGD 是
  新加坡工资、两个金属计价参数默认 USD 是市场惯例。

**纠正 OPS-8 当时的一个判断**:"列默认值里写不出子查询"属实,但**函数调用写得出来**
—— 实测参数默认与列默认都接受。所以"表达不了"从来不是留着字面量的理由;
留着的理由只能是"它真的就是那个币种"。
(`CHECK` 约束仍然不行 —— 它要 IMMUTABLE,而 `base_currency_code()` 读表只能是
STABLE。`fx_rates.sql` 那条 `CHECK (currency <> 'SGD')` 因此仍在下面的手改清单里。)

## FIN-1a 的一条分类作废(FIN-28,2026-08-07)

`db/migrations/2026-08-04-fin1a-rename-base-columns.sql` 的抬头写着:

> 交易币种真是 USD 的列【保留原名】:金属报价(metal_prices/pricing_formulas)、
> 采购单据与付款条款(purchase_order*/payment_term_template_lines 的
> estimated_*/fixed_amount_usd)—— 那些是 USD 报价,不是本位币金额。

**后半句作废。** 金属报价那一半仍然成立(USD/吨是市场惯例,链路全程不换汇);
采购单据那一半是错的:`create_purchase_order` 把各行 `quantity ×
estimated_unit_price` 累加进去,**从来没有乘过表头的 `fx_rate`** —— 所以它既不是
本位币,也不是 USD,而是**单据自己的币种**。FIN-16/FIN-17 的注释早就点破过
(`v_cap = estimated_total × 1.5`,两边同币),列名拖到 FIN-28 才跟上。

四列已改名(`_usd` → `_ccy`)并补了列注释:
`purchase_orders.estimated_total_ccy`、`purchase_order_lines.estimated_amount_ccy`、
`purchase_order_payment_terms.fixed_amount_ccy`、
`payment_term_template_lines.fixed_amount_ccy`。至此**全库不再有 `*_usd` 结尾的列**。

FIN-1a 那个文件【不改】—— 迁移是"当时上了什么"的记录,改它等于让记录说谎
(同 OPS-7 对 FIN-23 那句提醒的处置)。作废记在这里。

### 顺手发现、按规矩【不修】的一个缺陷

`payment_term_template_lines.fixed_amount_ccy` 住在**模板**上,而模板不属于任何
单据 —— 所以它的币种在被 `apply_payment_term_template` 抄到某张 PO 之前是**没有
定义的**。同一个模板套到 USD 单和 SGD 单上,那个"定额 10,000"是两笔不同的钱,
而没有任何地方拦这件事。FIN-28 是纯改名,**报告但不修**(改名的提交里顺手修
一个缺陷,就再也说不清 fixture 若变红是哪一件事造成的)。要修是单独一切:
要么给模板行加币种列,要么把定额期改成只能按比例。

> **【已修 —— FIN-29,2026-08-07】** 选了第一条,但两处与当初的设想不同:
> ① 币种放在模板【头】上而不是行上 —— 一份模板整份套到一张单上,而那张单只有
> 一个币种,逐行各带币种既无处可用也无从校验;② 是**条件必填**:有定额腿才必须
> 声明,只有比例的模板不需要 —— 强行要求会逼人瞎填,而瞎填的字段迟早被当真。
> 这条规则跨父子两张表,CHECK 写不出来(不许子查询),由守卫触发器两侧各挂一道执行。
> 套用时币种不同**点名拒、不换算**(付款条款是谈定的承诺,不是算出来的量 ——
> 同 FIN-27);校验发生在 DELETE 之前,所以"被拒 = 什么都没写"是结构上成立的。
> 修的时候全库 **0 条定额腿**(1 张模板 / 3 行 / 9 条 PO 期次,全是比例),
> 所以不变量当场成立,无需回填、也无需豁免既有行。fixture 22 四臂钉住,
> 两次故障注入各红一次。
>
> 第二条候选(定额期只能按比例)**被否**:它靠删功能消灭缺陷,而 PO 侧仍然支持
> 定额,模板会比它模板化的东西更弱 —— 这种不对称迟早被人"修"回来,且不带币种。

---

## FIN-35 — the DEFAULT survey: which column defaults encode an ASSUMPTION

**Why this section exists.** `purchase_orders.fx_rate` carried `DEFAULT 1`. That is the `?? 1` the FX
work spent several cuts removing, written as a schema default — and `check-currency-literals.mjs`
could not see it, because it hunts currency **codes** and this is a rate **value**. The survey below
is the whole point of the cut: an instance is a bug, a class needs a check.

**Every column default in the schema was read** (28 numeric, 49 text/array, plus the identity and
`now()` families which cannot encode an assumption). Classified against the four defaults OPS-11
deliberately KEPT — `purchase_orders.currency 'USD'` (a commercial choice), `payroll_periods.currency
'SGD'` (Singapore payroll really is in SGD), and the two `set_inbound_unit_price` /
`reprice_inbound_batch` `'USD'` parameters (metal is quoted in USD by market convention). Those are
real business defaults: the value is *true*, not *assumed*.

### The distinguishing test

> **A multiplier's identity is invisible; an addend's is not.**
> A rate defaulting to **1** silently produces a number that looks exactly like a correct one. A
> percentage or an accumulator defaulting to **0** produces a visible zero — a reader sees "no tax",
> "nothing yet". The first hides a wrong answer; the second states an absent one.

### Findings

| column | default | verdict |
|---|---|---|
| `purchase_orders.fx_rate` | `1` | **ASSUMPTION — removed by FIN-35.** Dead on the only write path (`create_purchase_order` refuses a caller-supplied rate and derives it from `fx_rate_for(..., 'tt_sell')`), and loaded for every other. Two fixtures were quietly relying on it and now fail loudly |
| `purchase_orders.approval_status` | `'approved'` | **ASSUMPTION, deliberately reserved.** "No flow exists, therefore approved." Belongs to APR-2, which owns flipping it |
| `purchase_orders.status` | `'confirmed'` | **Assumption, but dead** — `create_purchase_order` passes `'confirmed'` explicitly. Every other document defaults to `'draft'`. Worth aligning whenever purchase orders are next touched; not worth a migration of its own |
| `processing_runs.allocation_basis` | `'metal_value'` | **BORDERLINE, reported not changed.** Nothing sets it at creation — all 9 live runs carry the default — so the *costing method* is chosen by a schema default, and FIN-25 proved the two bases give provably different unit costs (62.50 vs 27.50 on the same run). It is a legitimate house default and it is a *named method the reader can see*, not a number masquerading as a measurement. The fix, if wanted, is to surface it on the run screen, not to remove it |
| `finance_settings.gst_rate_pct` | `0` | **Real default, same shape lower severity.** 0 GST computes a plausible 0 tax — but it is an addend (visible as `0.00`), it is RUNTIME CONFIG seeded once, and it is operator-set. Allowlisted in the checker with that reason |
| `invoices.tax_rate_pct` | `0` | as above — a copy of the settings figure onto the document |
| accumulators: `journal_lines.debit/credit`, all `payroll_*_total`, `estimated_total_ccy`, `estimated_amount_ccy` | `0` | **Real.** "Nothing yet" is true at insert |
| `fixed_assets.residual_base`, `pricing_formulas.flat_discount_pct`, `treatment_charge_usd_per_tonne` | `0` | **Real.** "None" is a genuine business value |
| workflow initial states: `'draft'`, `'pending'`, `'open'`, `'submitted'`, `'todo'`, `'unmatched'`, `'provisional'` | — | **Real.** The initial state of a workflow is a fact, not a guess |
| jurisdiction and trade constants: `country 'Singapore'` / `'SG'`, `unit 'kg'`, `fx_rates.source 'DBS'`, `fixed_assets.depreciation_account_code '6700'` | — | **Real.** The last is an account choice and is already visible to `check_mirrors`' account-code scanner |
| policy figures: `fy_end_day 31`, `fy_end_month 12`, `carry_forward_months 12`, `medical_annual_limit_sgd 1000`, `working_days_per_week 5` | — | **Real**, and all RUNTIME CONFIG — an operator changes them and divergence from the file is the system working |

**So: one instance to remove, one reserved for APR-2, one dead-but-misaligned, one borderline
reported.** Not a large class — but large enough that a check is worth more than a memory.

### The checker now sees it — `rate-default`, the third class

`check-currency-literals.mjs` gained a third class alongside `branch` and `jsx-text`: a
**rate-shaped column name carrying a numeric DEFAULT**, scanned over `db/tables/*.sql`. Matching on
the *name* rather than the type is deliberate — the multiplier/addend distinction lives in the name,
and the point is to force the judgement to be written down rather than remembered. It finds three
today: `fx_rate` (fixed), and `gst_rate_pct` / `tax_rate_pct` (allowlisted, with the reason above).

**Fault-injected:** putting `DEFAULT 1` back on `purchase_orders.fx_rate` makes the checker report
`1 unallowed` and name the line; removing it again returns to clean.

**What it cannot see, stated so a green line is not read as "no assumptions anywhere":** it only
looks at column defaults in table mirrors whose column name contains `rate`. A rate stored in a
column named `conversion`, `multiplier` or `factor` would pass, as would an assumption expressed in
a function's parameter default (OPS-11's territory) or in application code. That residue is a review
question, in the same way the error-swallowing checker names its own blind spot.
