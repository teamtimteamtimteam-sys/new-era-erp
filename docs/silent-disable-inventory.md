# 只灰不说的提交钮 —— 清查(CMP-2,2026-08-10)

**规则(由这次清查确立):禁用提交钮的每一个非瞬态条件,都必须有紧邻按钮的
一行可见文字说出【是什么在拦、去哪解决】。** `disabled={isPending}` 自明(钮文
切成"保存中"),豁免;其余条件一律要配文字。财务月结一族(CostSettlePanel、
PayPanel、ReconcileWorkspace、RevalueButton、两处 pctOver 表单)全都认真这么做
—— 所以这是房风,下面 14 处是漏网,不是另一种风格。

起因:PO-2026-0003 的收货表单保存钮点不动(到货日空,钮灰,零解释),Tim 说不出
为什么。灰而不语的钮,操作员分不清系统拦截和自己的漏填 —— 与"什么都不说的拒绝"
同族(refusal-names-the-numbers 的反面)。

## 已修

| 表单 | 条件 | 修法 |
|---|---|---|
| app/inbound/new/NewInboundForm.tsx | `!arrivalDate`;另证书拦截原先只在触发器 | 到货日未填一行字点名;被拦供应商红框点名证书与过期日(supplier_receiving_blocked 视图) |
| app/inbound/receive/ReceiveForm.tsx | 同上 | 同上 |
| app/processing/new/NewProcessingForm.tsx | `!processDate` | 同一句式点名加工日期;保留预填今天 |
| app/finance/settings/LockForm.tsx | `!date` | 同一句式点名锁定日期;【不】预填 |
| app/finance/bank/TransferForm.tsx | `!date \|\| !out \|\| !inn` | 三个条件各自一行点名;转账日期新增预填今天 |

**预填的判断(逐表,不求一致)**:预填只在【今天确实是最可能的答案】时才对 ——
它是便利不是默认值(受控值,清空即禁钮并点名;与服务端偷偷补 CURRENT_DATE 是两回事)。

* 现场收货(移动)与加工单:【预填】—— 操作的人就在事件现场,事件就是现在。
* 银行转账:【预填】—— 录的人通常刚在银行端做完这笔,是公司自己的当天动作。
* 桌面收货(/inbound/new):【不预填】—— 桌面录入常是事后补录,到货日往往不是
  今天;预填会静默写错 business_date(FIN-32),比一个会解释自己的灰钮更坏。
* 期间锁:【不预填】—— 锁定日是期间边界(通常上月末),今天几乎不会是答案。

## 未修,按伤害排序(9 处)

最恶劣的两处:

1. **app/hr/reviews/SetReviewerControl.tsx:55** — `!value || value === currentReviewerId`:
   重选已是当前评审人的那个人,钮永久死,【一个字都不显示】。
2. **app/finance/payments/new/NewPaymentForm.tsx:636** — 跨币种付款没填成交价时
   `effectiveFx === null`/`unallocated === null`,界面只在合计条显示"—"。
   (同表单的 fxError/docFxError/overAllocated 腿【有】横幅 —— 只漏了这一腿。)

加行式小表单的裸 `!field` 门(无标记、无文字):

6. app/finance/processing-costs/CostSettlePanel.tsx:129 — `variance === null` 与
   `unpaid && !supplier` 两腿没说(同文件其它字段有红框必填样式 —— 内部不一致,
   显系疏漏)
7. app/settings/permissions/InvitePanel.tsx:135 — `email === ''`(两个可选字段
   反而有提示,把门的没有)
8. app/hr/leave/LeaveForm.tsx:210 — `!start || !end || !employeeId`
9. app/hr/claims/ClaimForm.tsx:66 — `!date || !amount || !employeeId`
10. app/hr/leave/holidays/HolidaysEditor.tsx:96 — `!en || !zh`(且 `date` 是行键
    却【不】在条件里 —— 既不说话又漏门,修时一并)
11. app/hr/reviews/cycles/CycleForm.tsx:70 — 五个字段四个把门,没标哪个
12. app/hr/reviews/scale/ScaleEditor.tsx:243 — `!nCode || !nEn || !nZh`

修的模板就是收货表单那两张:条件对应的文字紧邻按钮,新增禁用条件必须同步新增
它的那行字(按钮旁的注释写明)。证书类的"问数据库"模式见
supplier_receiving_blocked(谓词与触发器成对,fixture 37F 钉一致)。
