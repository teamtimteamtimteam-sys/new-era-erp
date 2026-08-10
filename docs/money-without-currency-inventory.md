# 没有币种的金额 —— 清查(ASY-3,2026-08-10)

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
