# 空值直达 RPC —— 全量清点

走查里的一只虫:成本结算表单日期留空,`invalid input syntax for type date: ""`。
空串原样递到了 Postgres。据此把【表单空值以裸字符串进 RPC】这个形状全仓扫了一遍。

**判词只分两类,而要紧的是第二类:**

| 判词 | 含义 |
|---|---|
| REJECTED(看得见) | Postgres 拒绝:类型转换失败(22007/22P02)、CHECK 或外键违反。操作员当场看到报错 |
| **ACCEPTED(看不见)** | 数据库【收下了】,而值是错的。没有任何提示。**这一类才是真正危险的** |

## 为什么"看不见"那类几乎都长同一个样

`p_x: value || undefined` —— 空值时这个键【整个不传】,于是 SQL 侧的
`COALESCE(p_x, CURRENT_DATE)` 生效,悄悄换成【今天】。

**它比填错更危险,原因很具体:** 换成"今天"的日期【永远撞不上 PERIOD_LOCKED】。
把正确的(已关期间的)日期填进去会当场报错;留空反而顺顺当当滑进未关的当月。
也就是说,这条路径专门奖励留空。

## ACCEPTED(看不见)—— 8 处,全部已修

| 位置 | 留空时实际发生什么 |
|---|---|
| `finance/month-end/actions.ts` `pay_payroll_lines` | 整月薪资分录按【今天】过账,七月的薪资结进八月 |
| 同上 `pay_payroll_cpf` | CPF 分录按今天过账并把 `cpf_paid_at` 戳成今天。CPF 【按设计】就是次月汇缴,所以这一处最可能需要回填日期、也最可能被留空 |
| 同上 `pay_payroll_deductions` | 同上,`deductions_paid_at` 一并落在今天 |
| `output/[id]/edit/saleActions.ts` `record_output_sale` | 最重的一处:销售日不只是个戳 —— 它同时决定 `fx_rate_for(币种, 日期, 'tt_buy')` 取哪天牌价(于是 `amount_base` 也错)、库存流水业务日期、以及【收入与 COGS 两张分录】落在哪个期间。而表单里旁边的数量/单价都标了 required,唯独日期没有 |
| `hr/reviews/actions.ts` `save_self_assessment(p_self_assessment_text)` | 空白自评定稿后 `self_assessment_submitted_at` 被无条件盖上,此后一律 `SELF_ASSESSMENT_LOCKED` —— **一份空文档被永久锁死**,评估人那页还显示"已提交",正文是 `''` 不是 null,连「—」都不显示 |
| `hr/leave/actions.ts` `carry_forward_annual_leave(p_leave_year)` | 非数字年份 → NaN → JSON null → 每个人余额算成 NULL、循环全部跳过 → 返回 `0/0`,界面**报成功**。年末结转"跑过了",一个人都没结转 |
| `finance/processing-costs` `relieve_processing_accruals` | 走查报的那只(它是 REJECTED,见下),其**同胞** `remit_processing_costs` 才是这一类:按今天过账 |

已修方式统一:**日期/年度必填**,按钮在填好之前禁用,服务端动作也各自挡一道
(界面被绕过也进不去)。**一律不给服务端默认值** —— 默认成今天正是病根。

## 未修,已记录

- `hr/reviews/actions.ts` `save_self_assessment(p_goal_results[].result_text)` ——
  前端总是传这个键(`?? null` 实为 `''`),破坏了函数头写明的"不传该键 = 保持原值"
  契约,把未作答的 NULL 覆盖成 `''`。数据质量问题,不影响金额或期间。
- `hr/reviews/actions.ts` `set_goal_assessment(p_reviewer_assessment_text)` —— 同上,
  清空评语存成 `''` 而非 NULL,于是 `?? '—'` 渲染成空白。轻微。
- `inbound/[id]/assays/actions.ts` `calculate_metal_price(p_reference_date)` ——
  只影响【预览】报价取哪天的价;真正 apply 时用库里的 `assay_date`。误导,不误记。

## ~~【重要】不要把这些顺手修成 `|| undefined`~~ —— FIN-10 已从根上解决

**这条告诫已失效,保留是为了留下缘由。** 它当时说:`pay_medical_claim` 等几处
虽然是 REJECTED(看得见),但 SQL 里蹲着 `COALESCE(..., CURRENT_DATE)`,谁把调用
改成 `|| undefined` 就会把可见错误变成静默错账。

FIN-10 把那些默认值【删掉了】,所以现在改成 `|| undefined` 只会得到
`EXPENSE_DATE_REQUIRED` 之类的具名错误 —— 陷阱不存在了,不必再靠人记住。
这也是本轮的要点:**与其警告别踩,不如把坑填掉。**

## REJECTED(看得见)与 SAFE

其余约 60 处参数要么由动作层先校验(`Date.parse`、`Number.isFinite`、正则、枚举成员、
早退),要么由 SQL 自己挡(`REASON_REQUIRED`、`AMOUNT_INVALID`、`CURRENCY_INVALID`、
`LINE_QTY_INVALID`、`currencies` 外键),要么参数根本来自库里已有的行而非表单。
它们会报错,而报错是可见的 —— 不构成静默错账。

## FIN-10:默认值本身已被删除

上面那些"看不见"的错,根都在函数里蹲着的 `COALESCE(p_date, CURRENT_DATE)`。
只要它还在,任何调用方都能碰到,而文档只保护先读文档的人。**11 个函数的默认值
已删除,缺日期即抛具名错误**(逐一以回滚 fixture 验证过会抛):

`pay_payroll_lines` / `pay_payroll_cpf` / `pay_payroll_deductions` /
`remit_processing_costs` / `record_payment` / `pay_medical_claim` →
`PAYMENT_DATE_REQUIRED` · `EXPENSE_DATE_REQUIRED`;
`record_output_sale` → `SALE_DATE_REQUIRED`;
`commit_processing_run` → `PROCESS_DATE_REQUIRED`;
`create_purchase_order` → `ORDER_DATE_REQUIRED`;
`calculate_metal_price_internal` → `REFERENCE_DATE_REQUIRED`;
`reverse_bank_transfer` → `REVERSAL_DATE_REQUIRED`。

调用方已先查后删:`calculate_metal_price_internal` 的两个库内调用方都不依赖默认值
(`apply_assay_result` 传 `COALESCE(p_reference_date, v_assay.assay_date)`,而
`assay_date` 是 NOT NULL —— 结构上不可能为空);其余 10 个没有库内调用方。

## 该留的默认值 —— 记录在案,不是漏改

这些日期【既不决定过账期间也不决定汇率】,默认成今天是对的:

| 函数 | 这个日期决定什么 |
|---|---|
| `next_employee_code` / `next_payroll_code` / `next_purchase_order_code` / `next_medical_claim_code` | 只取年份用于编号序列 |
| `leave_balance` / `leave_balance_internal` / `accrued_annual_leave` / `accrued_annual_leave_detail` / `available_annual_accrual` / `annual_leave_available_from`(`p_as_of`) | 只读查询的"截至哪天",不写任何东西 |
| `create_invoice`(`p_issue_date`) | 发票号年份与到期日(= 签发日 + 账期)。**不过账、不取汇率** —— 收入在销售时点就已入账 |

`create_invoice` 是这里最接近边界的一个:签发日会影响应收账龄。但它不决定
任何分录的期间,也不选任何汇率,所以按本文的判据留下默认值 —— 把它写在这里,
是为了让"为什么没动它"有据可查,而不是靠"没被碰过"去猜。
