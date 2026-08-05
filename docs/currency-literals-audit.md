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

### 未决:需要一个判断,没有替你猜

`pricing.colValue` 现为 `'Value (SGD)'`,但它渲染的是 `calculate_metal_price`
的结果,而那套返回值的列名是 `unit_price_usd_per_kg`。**标签说 SGD、数据说 USD,
至少有一个是错的**,而哪个错取决于计价口径的原意。已保持原样并记在这里,
等一个决定,而不是改成看起来对的样子。
