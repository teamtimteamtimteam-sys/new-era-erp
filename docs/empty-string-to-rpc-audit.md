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

## 【重要】不要把这些 REJECTED 的"顺手修成" `|| undefined`

`hr/claims/actions.ts` 的 `pay_medical_claim(p_expense_date)` 现在是 REJECTED:
空串直达 Postgres 报 22007,看得见。但它的 SQL 里有
`COALESCE(p_expense_date, CURRENT_DATE)` —— **谁哪天顺手把它改成 `expenseDate || undefined`,
它就立刻变成上表那种看不见的错。** 要修就加必填校验,不要改成传 undefined。

同样形状还有:`submit_medical_claim(p_claim_date)`、`submit_leave_request(p_start/p_end)`、
`commit_processing_run(p_process_date)`、`record_bank_transfer(p_transfer_date)`。

## REJECTED(看得见)与 SAFE

其余约 60 处参数要么由动作层先校验(`Date.parse`、`Number.isFinite`、正则、枚举成员、
早退),要么由 SQL 自己挡(`REASON_REQUIRED`、`AMOUNT_INVALID`、`CURRENCY_INVALID`、
`LINE_QTY_INVALID`、`currencies` 外键),要么参数根本来自库里已有的行而非表单。
它们会报错,而报错是可见的 —— 不构成静默错账。
