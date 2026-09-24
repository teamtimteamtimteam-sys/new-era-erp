# 角色与审批矩阵 · Role and approval matrix

**Tim 的裁定,2026-09-23。** 这是后面每一刀照着做的【唯一】参照 —— 谁做、谁批。
**Tim's ruling, 2026-09-23.** This is the single reference later cuts follow — who does, who approves.

来源 / Source:回答 `docs/handbacks/ROLE-MATRIX-0.md` 那张表;grilling 的十三条答复记在
`docs/handbacks/ROLE-1.md` §0。 The survey it answers is ROLE-MATRIX-0; the thirteen grilling
answers (Q1–Q13) are in `docs/handbacks/ROLE-1.md` §0.

## 怎么读 · How to read

| 标记 · Mark | 意思 · Meaning |
|---|---|
| **✅ done** | 已在线上生效(ROLE-1 Batch 1 / PAY-REQ-1 Batch A / Batch B,2026-09-23;ROLE-1 Batch 2a,2026-09-24)· live since ROLE-1 Batch 1 or PAY-REQ-1 Batch A or B |
| **B2a · B2b … B5** | 本矩阵里【不需要新生命周期】的部分,排在 ROLE-1 的第 2–5 批;第 2 批拆成两刀(Tim 2026-09-23,Batch B grilling Q1):**B2a** = 财务设置 · 客户信用 · 供应商审批 + 未批准供应商不付款;**B2b** = 合同条款 · 定价 · 直接销售 · 化验 · in scope of ROLE-1, a later batch |
| **[LC]** | 要先造一个「申请 → 批准 → 执行」的生命周期,不在 ROLE-1 里 · needs a request → approve lifecycle; queued separately |
| **= 不变 / unchanged** | 矩阵说保持现状 · the matrix keeps the status quo |

**[LC] 在它的生命周期落地之前,「谁做」那一半已经按矩阵生效或在 B2–B5 里生效;「谁批」那一半还不存在**
—— 那件事今天仍是一个人做完就生效。**Until an [LC] lifecycle ships, the "does" half is in force (or in a
batch) and the "approves" half does not exist yet** — the action still completes in one step.

职位 · Positions: 系统管理员 = `admin`(Tim 的 admin@,只做系统管理)· CFO = `cfo`(Tim 的 tim@,挂同一份员工档案)·
财务 = `finance`(Choo Er)· CCO = `cco`(Sandra)· CTO = `cto`(Phua)· 仓库 = `warehouse`(Fu Sheng)·
MD = `gm`(Vince,只读)。

---

## 1 · 权限、账号、审批设置 · Permissions, accounts, approval settings

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 权限、账号、角色码、账号↔员工关联、审批开关与策略 · permissions, accounts, role codes, account–employee links, the approvals switch and policy | admin 一个 · admin only | — | ✅ done(`cco` 交出 `action.manage_permissions`)|

## 2 · 财务 · Finance

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 付款与冲销付款 · payments and their reversals | 财务 · finance | CFO | 做:= 不变 · 批:✅ done(PAY-REQ-1 Batch A:付款申请 → CFO 批每一张 → 财务付;收款、整笔付已批准的报销 / 医疗申报不批)|
| 银行转账、预扣税缴纳 · bank transfers, WHT remittance | 财务 · finance | CFO | 做:= 不变 · 批:✅ done(PAY-REQ-1 Batch B:转账与其冲销、预扣税缴纳与其冲销都经付款申请 → CFO 批每一张 → 财务执行;缴纳冻结提交时的应缴额)|
| 采购质保金释放 · PO retention release | 财务 · finance | ~~CFO~~ **不批 · none** | 做:✅ done(门从 `purchasing.edit` 换成 `finance.edit`)· ~~批:[LC] 付款申请~~ **撤回(Tim,PAY-REQ-1 Q5,2026-09-23):释放不动钱、也不生应付(`release_purchase_order_retention` 只盖一个决定的戳,不过分录),所以没有东西可批;钱在它真正被付出去的那一刻受控 —— 那一笔走付款申请** · **withdrawn: release moves no money and creates no payable; the money is controlled when it is actually paid** |
| 费用、医疗申报付款、预付款冲抵、销售发票、运费单据、汇率 · expenses, medical-claim payment, prepayment application, sales invoices, freight documents, FX rates | 财务 · finance | 不批 · none | = 不变 · unchanged。★ PAY-REQ-1(Q2(c)):费用单与运费单**不许生下来就已付** —— 一律挂账,钱经付款申请离开 · expenses and freight documents are always recorded unpaid; the money leaves through a payment request |
| 贷项通知、作废发票 · credit notes, invoice voids | 财务 · finance | CFO | 做:= 不变 · 批:[LC] APR-5 |
| GST 申报与更正 · GST filing and correction | 财务 · finance | CFO | 做:= 不变 · 批:[LC] |
| 报销单 · expense claims | = 不变 · unchanged | = 不变(分级:< 1,000 财务、≥ 1,000 CFO)| = 不变 |

## 3 · 总账 · General ledger

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 手工凭证与冲销 · manual journals and their reversal | 财务 · finance | CFO | 做:= 不变 · 批:[LC] APR-6 |
| 锁期、月结、外币重估、折旧、冻结管理月报、加工费计提冲回与付款 · period lock, month-end close, FX revaluation, depreciation, management-report freeze, accrual reversal and processing-fee payment | 财务 · finance | 不批 · none | = 不变 · unchanged |
| 加工成本分摊 · processing-cost allocation | 财务 · finance(原 cco / cto)| 不批 · none | ✅ done(门从 `processing.edit` 换成 `finance.edit`)|
| 重开已关的月、年结、重开已结的年度 · reopening a closed month, year-end close, reopening a closed year | **CFO 一个** · CFO only | — | ✅ done(`action.finance_reopen`;手动锁那扇越过已关月份的侧门按名拒)|

## 4 · 固定资产 · Fixed assets

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 登记 · registration | 财务 · finance | 不批 · none | = 不变 · unchanged |
| 处置 · disposal | 财务 · finance | CFO | 做:= 不变 · 批:[LC] 处置申请(已排队)|

## 5 · 人事与薪资 · HR and payroll

**Sandra(cco)只管 KPI 与绩效评估;其余人事与薪资全部归财务。**
**Sandra (cco) owns only KPI and performance reviews; all other HR and payroll work is finance's.**

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 工资期与算薪、考勤完成与重开、员工档案(月薪除外)· payroll periods and calculation, attendance completion and reopen, employee records other than salary | 财务 · finance | 不批 · none | ✅ done(`module.hr.edit` 从 cco 移到 finance)|
| 工资过账与撤销 · payroll posting and its reversal | 财务 · finance | CFO | 做:✅ done · 批:[LC] |
| 工资、CPF、扣款的付款 · payroll, CPF and deduction payments | 财务 · finance | 不批 · none | ✅ done(cco 不再持 `hr.edit`,这条路只剩 `finance.edit`)|
| 调薪 · salary changes | 只经绩效评估或调薪申请 · only through a performance review or a salary-change request | CFO | 直连写 `employees.monthly_salary` 一律拒:✅ done · 调薪申请:[LC] · **第一份月薪**:财务录一次(Q7),✅ done |
| 绩效评估(做)· performance reviews (doing them) | cco | — | ✅ done(`action.hr_reviews`)|
| 绩效评估(批)· performance reviews (approving) | — | CFO;**CFO 是提交人或主角时 cco 批**(Q5)· CFO; cco when the CFO is the submitter or subject | ✅ done(`action.approve_review` · `review_approval_code`)|
| 请假与医疗申报(批)· leave and medical claims (deciding) | — | 财务;**CFO 也可以决定任何一张**(Q4)· finance; the CFO may decide any | ✅ done(`action.decide_hr_requests`)|
| 当事人正是审批人时 · when the designated approver is the subject | — | 交给 CFO · goes to the CFO | ✅ done(同上:CFO 持决定码)|
| Tim 自己的请假 · Tim's own leave | — | Tim 自己批,标记 `self_decided`(R2 扩到请假,只对 CFO)· Tim, flagged | ✅ done |
| Tim 自己的医疗申报 · Tim's own medical claim | — | R2 不变,标记 · unchanged R2, flagged | ✅ done(CFO 账号从此真的走得到这一步)|
| 员工匿名化 · employee anonymisation | admin 一个 · admin only | — | ✅ done(`action.anonymise_employee`)|
| 身份信息(NRIC、准证号)· identity data | 只归财务 · finance only(Q6)· ★ **CFO 也读得到**(Tim 2026-09-23,PAY-REQ-1:CFO 持每一个 view 码;录入与改动仍只归财务)| — | ✅ done(`data.view_identity` 从 cco / cto / admin 拿掉;cfo 加上)|

## 6 · 采购与供应商 · Purchasing and suppliers

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 开采购单,按品类 · raising a PO, by category | 工厂耗材:仓库 · 设备与货物:cco · 办公用品:财务 | 分级不变:< 1,000 财务、≥ 1,000 CFO | B5(品类列 + 每类一个开单码,Q12)|
| 修改、取消、关闭采购单 · amend, cancel, close | 开单人 · the raiser | — | B5 |
| 供应商建档 · supplier creation | cco · 仓库 · 财务 | — | ✅ done(ROLE-1 Batch 2a:warehouse 拿到 `module.suppliers.view` + `.edit`,Q5;cto 保留它的宽码)|
| 供应商批准、拉黑、恢复 · supplier approval, blacklisting, restoring | — | CFO;**建档人永远不能批自己建的** | ✅ done(ROLE-1 Batch 2a:`action.supplier_approve` · `set_supplier_status` · `supplier_status_moves()` · 按人拒自批 · `created_by` 不可改 · `approval_log` 加 `supplier` · `supplier_status_history` · `operations_now` 的 `supplier_pending_approval`;付款申请提 / 批 / 付与新采购单都按名拒未批准的供应商)。原计划:B2a(Q11:批准 / 驳回 / 拉黑 / 恢复归 CFO;送审 / 启用 / 暂停 / 归档归 `suppliers.edit`)。★ **Tim 2026-09-23:供应商批准落地之后,给一家【未批准】的供应商,付款申请提不了、批不了、付不了**;新开采购单也拒(Batch B grilling Q5–Q9)|
| 合同条款 · contract terms | cco | CFO | 做:B2b · 批:[LC] |

## 7 · 定价 · Pricing

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 金属价格 · metal prices | 财务 · finance | — | B2b |
| 定价公式 · pricing formulas | cco | CFO | 做:B2b · 批:[LC] |

## 8 · 进料、库存、盘点 · Inbound, stock, stocktake

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 建收货单 · goods-receipt creation | 仓库 · warehouse | — | B3 |
| 收货定价与改价 · receipt pricing and repricing | 财务 · finance | CFO | 做:B4(**看不见价格的人不能定价,在库里挡**)· 批:[LC] |
| 应用化验结果 · assay application | cto | — | B2b(Tim 2026-09-23 确认:cto 应用化验,价随之重算并过应付)|
| 删除批次(报废入口)· batch deletion, the write-off path | 仓库提 · warehouse requests | CFO | 在生命周期之前只归仓库(Q10):B3 · 批:[LC] |
| 盘点录数 · stocktake counting | 仓库 · warehouse | — | B3 |
| 盘点过账 · stocktake posting | 财务 · finance;**录过数的人永远不能过账**(系统先要记下谁数的)| — | B3 |

## 9 · 加工 · Processing

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 工单 · work orders | 仓库建 · created by warehouse | 财务下达 · released by finance | B3 |
| 加工提交 · processing commit | 仓库 · warehouse | — | B3 |
| 加工回滚 · rollback | 仓库提 · warehouse requests | CFO | 在生命周期之前只归仓库(Q10):B3 · 批:[LC] |

## 10 · 销售 · Sales

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 从产出批次直接销售 · direct sale from an output batch | cco 一个 · cco only | — | B2b |
| 销售订单 · sales orders | cco | — | = 不变(`sales.edit` 本来只有 admin 与 cco;admin 已拿掉)|
| 发货 · shipping | 仓库执行,在 CFO 放行之后 · warehouse, after CFO release | CFO | 在生命周期之前 cco 保留(Q10)· 放行:[LC] APR-5 |
| 客户信用额度与冻结 · customer credit limits and holds | **CFO 一个** · CFO only | — | ✅ done(ROLE-1 Batch 2a:`action.customer_credit` · `set_customer_credit` · 列守卫;客户页上的信用一块;编辑表单与批量导入不再带这两列)|

## 11 · 合规 · Compliance

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 签发销毁证书 · issuing a certificate of destruction | 仓库 · warehouse(资格由系统算)| 不批 · none | ✅ done(`action.issue_cod` 从 cto 与 admin 拿掉)|
| 作废销毁证书 · voiding a COD | 仓库提 · warehouse requests | CFO | 在生命周期之前只归仓库(Q10,今天已是)· 批:[LC] |

## 12 · 主数据 · Master data

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 批量导入 · bulk import | admin | — | ✅ done(cco / cto / finance 交出 `action.bulk_import`;导入不许带月薪)|
| 科目表、币种、公司银行资料、GST 登记、其余财务设置 · chart of accounts, currencies, company bank details, GST registration, other finance settings | **CFO 一个** · CFO only | — | ✅ done(ROLE-1 Batch 2a:`action.finance_settings`;`accounts` / `currencies` / `company_profile` 写权换码;`finance_settings` 列守卫 + `set_finance_settings`,锁期仍归财务;`company-assets` 桶的写上门)|

## 13 · 看得见什么 · Visibility

| 事项 · Action | 规则 · Rule | 状态 · Status |
|---|---|---|
| 仓库看采购价 · warehouse sees purchase prices | 看得见采购与供应商那一侧的价格,好开它的采购单;**看不见**销售价、工资或任何别的价格(Q9 画的线)| B4 |
| 系统管理员账号 · the admin account | **拿掉每一个业务码;只做系统管理。admin@ 从此读不到任何业务数据 —— Tim 的一切业务阅读与决定走 tim@**(Q8)| ✅ done |
| ⚠ **系统管理员账号:Q8 已被 Tim 本人撤回 · the admin account: Q8 reversed by Tim himself**(2026-09-23 23:33:27 CST)| Tim 以 admin@ 登录,把 **全部 45 个码** 还给了 `admin` 角色(AP-RECON-0 以 `postgres` 读基表 `role_permissions` 复核:45 行,`created_at` 全是 23:33:27)。上一行的收窄**现已不成立**。Claude 建议撤回到只做系统管理,两条理由:① admin@ 与 tim@ 是同一个人,所以在 admin@ 上发起的申请不能在 tim@ 上批;② 一个被盗的 admin 密码现在带着每一项权力。**Tim 尚未裁定是否撤回 —— 角色保持现状,除非 Tim 自己提起,不再提** | 现状 · as is |
| CFO 读得到它要决定的东西 · the CFO can read what it decides | `module.hr.view` · `data.view_reviews` · `module.suppliers.view` · `module.customers.view` · `data.view_banking`;没有一个码让它开出它要批的单(Q3)| ✅ done |
| **CFO 读得到每一样东西 · the CFO reads everything**(Tim 2026-09-23,取代上一行的收窄)| **每一个 `module.*.view` 与 `data.view_*`,加 `module.tasks.view`**(只读;不带任何写码或决定码)。★ 取代 Q6「身份信息只归财务」在【读】这一侧(录入与改动仍只归财务),也取代「被删记录只授 admin 与 auditor」。★ `module.tasks.view` 让持有人【建、改自己的个人任务】—— APR-4 那条自己的任务的例外,不是读以外的业务权。`module.tasks.view_all`(读别人的个人任务)**不给** | ✅ done(PAY-REQ-1 Batch A;cfo 13 → 26 码)|

## 14 · 后果较轻的动作 · Lower-consequence actions

ROLE-MATRIX-0 §3 附表那些:**保持现状**,只有一条例外 —— **每一个和价格有关的动作都从仓库拿掉**。
(Q2:只有主表里的动作换人,而且经由各自的码;cto 与 cco 留着它们的宽码,管附表那些。)
The ROLE-MATRIX-0 appendix stays as it is, except that every price-related action is removed from
warehouse (B4). cto and cco keep their broad `.edit` codes for these.

---

## 已经生效的码 · Codes in force (Batch 1)

| 码 · Code | 放行 · Unlocks | 持有 · Held by |
|---|---|---|
| `action.finance_reopen` | 重开已关的月、年结、重开年度 | cfo |
| `action.approve_review` | 批准绩效评估(CFO 不是提交人或主角时)| cfo |
| `action.decide_hr_requests` | 决定请假与医疗申报 | finance · cfo |
| `action.hr_reviews` | KPI 与绩效评估这一块;CFO 是提交人或主角时的批准 | cco |
| `action.anonymise_employee` | 员工匿名化 | admin |
| `module.hr.edit`(改义:不再含评估与 KPI)| 其余人事与薪资 | finance(cco 与 admin 已拿掉)|
| `action.finance_settings` | 科目表、币种、公司资料(含银行资料与标志)、GST 登记与其余财务设置(锁期除外)(Batch 2a)| cfo |
| `action.customer_credit` | 客户信用限额与冻结(Batch 2a)| cfo |
| `action.supplier_approve` | 供应商批准、驳回、拉黑、恢复(拉黑后归档)(Batch 2a)| cfo |
| `module.suppliers.view` / `.edit`(新增持有人)| 供应商建档与编辑(Batch 2a,Q5)| + warehouse |

> ★ **更正(ROLE-1 Batch 2a,2026-09-24,以 postgres 读基表 `user_roles` 实测):admin@ 的 `cfo` 授权【已撤销】**
> (`revoked_at = 2026-09-23 15:00:48 CST`)。Batch 2a Step 0 说"admin@ 同时持 cfo"—— 那条查询没有过滤 `revoked_at`,是错的。
> admin@ 今天只持 `admin` 角色(45 码),**不**持本批三个新码。
