# 角色与审批矩阵 · Role and approval matrix

**Tim 的裁定,2026-09-23。** 这是后面每一刀照着做的【唯一】参照 —— 谁做、谁批。
**Tim's ruling, 2026-09-23.** This is the single reference later cuts follow — who does, who approves.

来源 / Source:回答 `docs/handbacks/ROLE-MATRIX-0.md` 那张表;grilling 的十三条答复记在
`docs/handbacks/ROLE-1.md` §0。 The survey it answers is ROLE-MATRIX-0; the thirteen grilling
answers (Q1–Q13) are in `docs/handbacks/ROLE-1.md` §0.

## 怎么读 · How to read

| 标记 · Mark | 意思 · Meaning |
|---|---|
| **✅ done** | 已在线上生效(ROLE-1 Batch 1 / PAY-REQ-1 Batch A / Batch B,2026-09-23;ROLE-1 Batch 2a / Batch 2b / PAYROLL-APR-1,2026-09-24;ROLE-1 Batch 4a / 4b / 3a / 3b · APR-5a · APR-5b · APR-6,2026-09-25)· live since ROLE-1 Batch 1, PAY-REQ-1 Batch A or B, ROLE-1 Batch 2a or 2b, PAYROLL-APR-1, ROLE-1 Batch 4a, 4b, 3a or 3b, APR-5a, APR-5b or APR-6 |
| **B2a · B2b … B5** | 本矩阵里【不需要新生命周期】的部分,排在 ROLE-1 的第 2–5 批;第 3 批拆成两刀(Tim 2026-09-25,Batch 3 grilling Q13):**B3a** = 盘点录数与过账分离 + 四个登记的缺口(✅ done);**B3b** = 收货建单 · 工单 · 加工提交 · 回滚与注销的临时持有人(✅ done);第 2 批拆成两刀(Tim 2026-09-23,Batch B grilling Q1):**B2a** = 财务设置 · 客户信用 · 供应商审批 + 未批准供应商不付款;**B2b** = 合同条款 · 定价 · 直接销售 · 化验 · in scope of ROLE-1, a later batch |
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
| 贷项通知、作废发票 · credit notes, invoice voids | 财务 · finance | CFO | 做:= 不变 · 批:✅ done(APR-5a,2026-09-25:`invoice_requests` —— 财务提 `submit_credit_note_request` / `submit_invoice_void_request`,CFO 批每一张、不分档,**批即按冻结的日期过账**;提单人按人认永远不能批;提单人之外没人批得动时提交就拒 `INVOICE_REQUEST_NO_OTHER_DECIDER`;旧的 `create_credit_note` / `void_invoice` 按名拒 `INVOICE_NEEDS_APPROVED_REQUEST`;发票两张表没有直连写、`invoice_voided` 只由作废传播写、`reverse_journal_entry` 拒发票与贷项分录、挂着贷项的发票不作废;没有新码)|
| GST 申报与更正 · GST filing and correction | 财务 · finance | CFO | 做:= 不变 · 批:[LC] |
| 报销单 · expense claims | = 不变 · unchanged | = 不变(分级:< 1,000 财务、≥ 1,000 CFO)| = 不变 |

## 3 · 总账 · General ledger

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 手工凭证与冲销 · manual journals and their reversal | 财务 · finance | CFO | 做:= 不变 · 批:✅ done(APR-6,2026-09-25:`journal_requests` —— 财务提 `submit_journal_request`(手工凭证,过出来永远是 `manual`,`source_id` = 申请)/ `submit_journal_reversal_request`(冲一张没有自己冲销路径的分录);CFO 批每一张、不分档(N1 对分录退休),**批即按冻结的日期过账**;提单人按人认永远不能批;提单人之外没人批得动时提交就拒 `JOURNAL_REQUEST_NO_OTHER_DECIDER`;期间锁永远赢,锁上之后批准按 `PERIOD_LOCKED` 拒;1100 / 2000 按名拒 `JE_MANUAL_CONTROL_ACCOUNT`,贷银行准许并标出来;`post_journal_entry` 对 authenticated 收回、两张分录表没有直连写(`JOURNAL_THROUGH_FUNCTION_ONLY`)、`reverse_journal_entry` 一张都不冲(有自己路径的 `JE_REVERSE_USE_SOURCE_PATH`,其余 `JOURNAL_NEEDS_APPROVED_REQUEST`);职责分离认提单人;系统生成的分录一律不经这里(N5);没有新码)|
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
| 工资过账与撤销 · payroll posting and its reversal | 财务 · finance | CFO | 做:✅ done · 批:✅ done(PAYROLL-APR-1,2026-09-24:过账申请 / 撤销申请 → CFO 批每一张、不分档 → 财务执行;批之前什么都不过账。★ 工资期是公司的单据:主角那条腿对谁都不成立,CFO 批含他自己工资行的一期、留痕说出来;提单人那条按人认。R2 永远不覆盖工资)|
| 工资、CPF、扣款的付款 · payroll, CPF and deduction payments | 财务 · finance | 不批 · none | ✅ done(cco 不再持 `hr.edit`,这条路只剩 `finance.edit`)· ✅ **只能跟在一次批过的过账后面**(PAYROLL-APR-1:`posted` 只经批过的申请到达;挂着撤销申请时三支付款按名拒 `PAYROLL_REVERSAL_REQUESTED`)|
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
| 合同条款 · contract terms | cco | CFO | 做:✅ done(ROLE-1 Batch 2b:`action.contract_terms` 管建合同与七张条款表 —— `contracts` 与条款表的写策略和 `enforce_write_permission` 从 `suppliers.edit` / `customers.edit` 换过来;`/contracts/new` 的保存钮按码关上并说出码;把单据挂到合同上仍归开单据的码,`link_document_to_contract` 不动)· 批:[LC] |

## 7 · 定价 · Pricing

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 金属价格 · metal prices | 财务 · finance | — | ✅ done(ROLE-1 Batch 2b:`action.metal_prices` 管 `metal_prices` · `metal_price_indices` · `index_market_calendar` · `pricing_settings`(报价阈值)与 `upsert_metal_prices`;阈值面板改为看得见、按不动、说出码)|
| 定价公式 · pricing formulas | cco | CFO | 做:✅ done(ROLE-1 Batch 2b:`module.pricing.edit` 从 cto 与 finance 拿掉,只剩 cco 与 admin;两个无人持有的角色 procurement / sales 保留它,登记 `ROLE1B2B-UNHELD-PRICING-EDIT`;公式页补上 PermissionGate,关掉 `PAYREQB-FORMULA-PAGES-NO-DISABLED-GATE`)· 批:[LC] |

## 8 · 进料、库存、盘点 · Inbound, stock, stocktake

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 建收货单 · goods-receipt creation | 仓库 · warehouse | — | ✅ done(ROLE-1 Batch 3b,2026-09-25:`action.receive_goods` → 仓库与 admin,管 `create_inbound_batch` 与 `receive_inbound_batch_against_po`,先问它 —— 带价建单另要两个定价码,拒绝点名建单码(Batch 3b Q5);cco · cto · 财务交出建单;收货台、现场收货、采购单「按单收货」与加工页的入口看得见、按不动、说出码) |
| 收货定价与改价 · receipt pricing and repricing | 财务 · finance | CFO | 做:✅ done(ROLE-1 Batch 4a,2026-09-25:`action.price_receipts` 只归财务(与 admin),定价面板、按已承诺条款改价与建单带价都要它 **加** `data.view_purchase_prices`,两个都在库里问;定价引擎 `reprice_inbound_batch` 自己再问后者 —— 所以应用化验也要看得见采购价;cco、cto、仓库从此定不了价。三扇侧门关上:`price_history` 不能直连插、`purchase` 分录不能从凭证页冲销(`JE_REVERSE_USE_SOURCE_PATH`)、引擎不能直调)· 批:✅ done(ROLE-1 Batch 4b,2026-09-25:四扇门 —— 定价面板、按已承诺条款改价、收货台带价、应用化验 —— 都只提一张 `receipt_price_requests`;CFO 批每一张(二级,门 `module.inbound.view` + `data.view_purchase_prices`),**批准当场过账**,记在批准日、按那天的牌价;驳回要理由;提单人本人或财务可撤回;等待期间供应商 / 采购单 / 采购行 / 含量 / 注销 / 第二张申请都按名拒,批准时指纹再比;低于已付按名拒;提单人之外没人批得动时提交就拒;化验来源的申请批准后才升 `final`;审批关着时生下来就批准并过账)|
| 应用化验结果 · assay application | cto | — | ✅ done(ROLE-1 Batch 2b:`action.apply_assay` 管应用与撤销、进料与产出、连同两种试算;**记录**化验结果仍归 `inbound.edit` / `output.edit`;两扇侧门按名关 —— 直连写应用标记 `ASSAY_APPLY_THROUGH_FUNCTION_ONLY`、直连写出自化验的含量 `ASSAY_CONTENT_THROUGH_FUNCTION_ONLY`;「记录并应用」对无码者看得见、按不动。Tim 2026-09-23 确认:cto 应用化验,价随之重算并过应付 —— **ROLE-1 Batch 4b 起**:价随之重算并【提一张定价申请】,CFO 批了才过应付;`reprice_inbound_batch` 里嵌套的 `inbound.edit` 检查不拆,归 Batch 4)|
| 删除批次(报废入口)· batch deletion, the write-off path | 仓库提 · warehouse requests | CFO | 在生命周期之前只归仓库(Q10):✅ done(ROLE-1 Batch 3b,2026-09-25:`action.batch_write_off` → 仓库与 admin,管 `soft_delete_inbound_batch` 与 `soft_delete_output_batch`;两张表上的注销钮按码关上)· 批:[LC] |
| 盘点录数 · stocktake counting | 仓库 · warehouse | — | ✅ done(ROLE-1 Batch 3a,2026-09-25:`action.stocktake_count` → 仓库与 admin,管开单 `open_stocktake` 与录数 `record_stocktake_count`;每一次录数与重录连同录数的人追加进 `stocktake_counts`(只增不改,`counted_by` 由函数写);盘点三张表没有直连写(`STOCKTAKE_THROUGH_FUNCTION_ONLY`);取消仍归 `module.stocktakes.edit`)|
| 盘点过账 · stocktake posting | 财务 · finance;**录过数的人永远不能过账**(系统先要记下谁数的)| — | ✅ done(ROLE-1 Batch 3a,2026-09-25:`action.stocktake_post` → 财务与 admin;开单人 `SELF_APPROVAL_FORBIDDEN\|raiser`,`stocktake_counts` 里每一个录过数的人 `STOCKTAKE_COUNTER_CANNOT_POST`,都按人认)|

## 9 · 加工 · Processing

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 工单 · work orders | 仓库建 · created by warehouse | 财务下达 · released by finance | ✅ done(ROLE-1 Batch 3b,2026-09-25:`action.wo_create` → 仓库与 admin;`action.wo_release` → 财务与 admin,建单人永远不能下达(`SELF_APPROVAL_FORBIDDEN\|raiser`,按人认);改 / 取消 / 关闭 = `action.wo_create` 或 `module.processing.edit`(Q6);建单人之外没有真持有人持下达码时建单按名拒 `WO_NO_OTHER_RELEASER`(Batch 3b Q3);工单页的下达钮对建单人自己的账号说出理由(Q6);改一张已下达的工单不送回重新下达,登记 `ROLE1B3-AMEND-RELEASED-WO`) |
| 加工提交 · processing commit | 仓库 · warehouse | — | ✅ done(ROLE-1 Batch 3b,2026-09-25:`action.processing_commit` → 仓库与 admin;仓库拿 `module.processing.view`、不拿 `module.materials.view`,建工单 · 提交加工 · 加工单详情三页改读 `material_lookup`(它的谓词加上 `module.processing.view`,Batch 3b Q4);加工三张表不许绕过函数写 —— runs / outputs 的 INSERT 与三张表的 DELETE 策略拿掉,直连插 / 删 / 改状态与改挂工单按名拒 `PROCESSING_THROUGH_FUNCTION_ONLY`(Q7 · Batch 3b Q1);损耗分类与交接班 = 新码 `action.processing_aftercare`(仓库与 admin)或 `module.processing.edit`(Batch 3b Q2);加工费用条目仍归 `module.processing.edit`) |
| 加工回滚 · rollback | 仓库提 · warehouse requests | CFO | 在生命周期之前只归仓库(Q10):✅ done(ROLE-1 Batch 3b,2026-09-25:`action.processing_rollback` → 仓库与 admin)· 批:[LC] |

## 10 · 销售 · Sales

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 从产出批次直接销售 · direct sale from an output batch | cco 一个 · cco only | — | ✅ done(ROLE-1 Batch 2b:`record_output_sale` 换成 `action.direct_sale`;`sales_records` 的 INSERT 与 UPDATE 两条写策略拿掉 —— 四个写入方全是 SECURITY DEFINER —— 直连写按名拒 `SALE_THROUGH_FUNCTION_ONLY`,关掉 `PAYREQB-SALES-RECORDS-FINANCE-INSERT`)|
| 销售订单 · sales orders | cco | — | = 不变(`sales.edit` 本来只有 admin 与 cco;admin 已拿掉)|
| 发货 · shipping | 仓库执行,在 CFO 放行之后 · warehouse, after CFO release | CFO | 做:✅ done · 批:✅ done(APR-5b,2026-09-25:`shipping_releases` —— cco 提 `action.request_shipping_release`,CFO 批每一张、不分档,**批准就是放行**(不另执行,仓库照它分一次或几次发);点名已开票的发票行,覆盖 = 批准且发票行未作废,**作废自动失效**,之后开票的行要它自己的放行;一张订单同时只挂一张在等的;提单人按人认永远不能批,提单人之外没人批得动时提交就拒 `SHIPPING_RELEASE_NO_OTHER_DECIDER`;CFO 决定时看得见敞口、额度、冻结、开放余额与逐行毛利(没有成本写「未计成本」)。发货 = `action.ship_goods`(仓库与 admin,**cco 从此不发货**,也不开送货单),在 `/logistics/shipping` 一页不带价格的队列里发(带送货地址 —— Tim 5b Q6);冻结的客户、没有放行、超过【开票 − 未发货取消的数量 − 已发】都按名拒;仓库**不**拿 `module.sales.view`,读得到自己发的货与送货单。集装箱挂发货单仍归 `module.purchasing.edit`(5b Q9,登记 `APR5B-CONTAINER-ATTACH-NOT-WAREHOUSE`))|
| 客户信用额度与冻结 · customer credit limits and holds | **CFO 一个** · CFO only | — | ✅ done(ROLE-1 Batch 2a:`action.customer_credit` · `set_customer_credit` · 列守卫;客户页上的信用一块;编辑表单与批量导入不再带这两列)|

## 11 · 合规 · Compliance

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 签发销毁证书 · issuing a certificate of destruction | 仓库 · warehouse(资格由系统算)| 不批 · none | ✅ done(`action.issue_cod` 从 cto 与 admin 拿掉)|
| 作废销毁证书 · voiding a COD | 仓库提 · warehouse requests | CFO | 在生命周期之前只归仓库(Q10,今天已是 —— Batch 3 Step 0 复核:`void_cod` 门 `action.issue_cod`,持有人 admin · warehouse;Q9:不改)· 批:[LC] |

## 12 · 主数据 · Master data

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 批量导入 · bulk import | admin | — | ✅ done(cco / cto / finance 交出 `action.bulk_import`;导入不许带月薪)|
| 科目表、币种、公司银行资料、GST 登记、其余财务设置 · chart of accounts, currencies, company bank details, GST registration, other finance settings | **CFO 一个** · CFO only | — | ✅ done(ROLE-1 Batch 2a:`action.finance_settings`;`accounts` / `currencies` / `company_profile` 写权换码;`finance_settings` 列守卫 + `set_finance_settings`,锁期仍归财务;`company-assets` 桶的写上门)|

## 13 · 看得见什么 · Visibility

| 事项 · Action | 规则 · Rule | 状态 · Status |
|---|---|---|
| 仓库看采购价 · warehouse sees purchase prices | 看得见采购与供应商那一侧的价格,好开它的采购单;**看不见**销售价、工资或任何别的价格(Q9 画的线)| ✅ done(ROLE-1 Batch 4a,2026-09-25:新码 `data.view_purchase_prices` —— 采购单与采购行、质保金、付款条款、定价公式(按行:销售公式仍问 `view_prices`)与条款承诺、计价器、收货单价与改价历史、应付账龄;今天持 `data.view_prices` 的每一个角色一并拿到它,仓库只拿它。★ 仓库今天不持 `module.purchasing.view` / `pricing.view` / `finance.view`,所以它**实际多看见的只在收货那几屏**(单价、改价历史、化验改价的新旧价);采购单那几屏等 Batch 5 的开单码。~~★ 到岸成本经盘点那条例外它今天就读得到 —— 登记 `ROLE1B4A-LANDED-COST-STOCKTAKE-EXCEPTION`,Batch 3 修~~ ✅ **ROLE-1 Batch 3a 关掉**(2026-09-25,Q5):`inbound_batch_landed_unit_cost` 不再放行 `module.stocktakes.edit`;`batch_freight_base` 与 `batch_processing_cost_base` 先问 `data.view_prices`(不持的人读 NULL,收货页画「受限」);分摊改读 `_all`)|
| 系统管理员账号 · the admin account | **拿掉每一个业务码;只做系统管理。admin@ 从此读不到任何业务数据 —— Tim 的一切业务阅读与决定走 tim@**(Q8)| ✅ done |
| ⚠ **系统管理员账号:Q8 已被 Tim 本人撤回 · the admin account: Q8 reversed by Tim himself**(2026-09-23 23:33:27 CST)| Tim 以 admin@ 登录,把 **全部 45 个码** 还给了 `admin` 角色(AP-RECON-0 以 `postgres` 读基表 `role_permissions` 复核:45 行,`created_at` 全是 23:33:27)。上一行的收窄**现已不成立**。Claude 建议撤回到只做系统管理,两条理由:① admin@ 与 tim@ 是同一个人,所以在 admin@ 上发起的申请不能在 tim@ 上批;② 一个被盗的 admin 密码现在带着每一项权力。**Tim 尚未裁定是否撤回 —— 角色保持现状,除非 Tim 自己提起,不再提** | 现状 · as is |
| ★ **admin 角色持【每一个】码 · the admin role holds every code**(Tim 常设裁定,2026-09-24,已关)| Tim 用 admin@ 做测试,所以 `admin` 角色**保留它全部的码,并拿到每一个新码**。**从 ROLE-1 Batch 2b 起,每一个新码都在【同一支迁移】里一并授给 `admin`** (幂等:`ON CONFLICT DO NOTHING`)。Batch 2b 因此把 Batch 2a 的三个码也补给了它(以 postgres 读基表 `role_permissions`:Batch 2b 之前 admin 一个都没有)。★ admin@ **不**持 `cfo` 角色(那一行 `revoked_at` = 2026-09-23 15:00:48),不改。★ 唯一例外,照直记:`module.tasks.view_all`(读别人的个人任务)admin 【从来没有】—— Tim 2026-09-23 23:33 还回去的 45 个码里就没有它;这条裁定说的是「保留 + 每一个新码」,所以 Batch 2b 没有替 Tim 加它。要不要加,是 Tim 的一句话 | ✅ done(Batch 2b 之后 admin 52 码 / 目录 53)|
| CFO 读得到它要决定的东西 · the CFO can read what it decides | `module.hr.view` · `data.view_reviews` · `module.suppliers.view` · `module.customers.view` · `data.view_banking`;没有一个码让它开出它要批的单(Q3)| ✅ done |
| **CFO 读得到每一样东西 · the CFO reads everything**(Tim 2026-09-23,取代上一行的收窄)| **每一个 `module.*.view` 与 `data.view_*`,加 `module.tasks.view`**(只读;不带任何写码或决定码)。★ 取代 Q6「身份信息只归财务」在【读】这一侧(录入与改动仍只归财务),也取代「被删记录只授 admin 与 auditor」。★ `module.tasks.view` 让持有人【建、改自己的个人任务】—— APR-4 那条自己的任务的例外,不是读以外的业务权。`module.tasks.view_all`(读别人的个人任务)**不给** | ✅ done(PAY-REQ-1 Batch A;cfo 13 → 26 码)|

## 14 · 后果较轻的动作 · Lower-consequence actions

ROLE-MATRIX-0 §3 附表那些:**保持现状**,只有一条例外 —— **每一个和价格有关的动作都从仓库拿掉**。
(Q2:只有主表里的动作换人,而且经由各自的码;cto 与 cco 留着它们的宽码,管附表那些。)
The ROLE-MATRIX-0 appendix stays as it is, except that every price-related action is removed from
warehouse (B4 — ✅ ROLE-1 Batch 4a, 2026-09-25: receipt pricing was the last one; direct sale and assay application left warehouse in Batch 2b). cto and cco keep their broad `.edit` codes for these.

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
| `action.contract_terms` | 建合同与七张条款表(Batch 2b)| cco · admin |
| `action.metal_prices` | 金属行情、指数、指数交易日历与报价阈值(Batch 2b)| finance · admin |
| `action.direct_sale` | 从产出批次直接销售(Batch 2b)| cco · admin |
| `action.apply_assay` | 应用 / 撤销应用化验(进料与产出)与两种试算(Batch 2b)| cto · admin |
| `module.pricing.edit`(改义:只剩定价公式)| 定价公式(Batch 2b:金属行情移走)| cco · admin(finance 与 cto 已拿掉;无人持有的 procurement / sales 保留)|
| `module.output.edit`(改义)| 产出批次与它的化验结果;直接销售与化验应用已移走(Batch 2b)| 不变 |
| Batch 2a 三码的新增持有人 | 同上(Batch 2b,Tim 的常设裁定)| + admin |
| `data.view_purchase_prices` | 采购那一侧的价格:采购单与采购行、质保金、付款条款、采购与两用公式的条款、条款承诺、计价器、收货单价与改价历史、应付账龄(Batch 4a)| 今天持 `data.view_prices` 的每一个角色(admin · auditor · cco · cfo · cto · finance · gm · procurement · sales)+ **warehouse** |
| `action.price_receipts` | 收货定价与改价(定价面板、按已承诺条款改价、建单带价);库里同时要 `data.view_purchase_prices`(Batch 4a)| finance · admin |
| `data.view_prices`(改义)| 从此只管销售与成本那一侧:销售、发票、应收、到岸成本、存货计值、加工成本、毛利、运费单据(Batch 4a)| 不变(仓库不持)|
| `action.stocktake_count` | 开盘点单与录数、重录(Batch 3a)| warehouse · admin |
| `action.stocktake_post` | 盘点过账;开单人与录过数的人永远不能过账(Batch 3a)| finance · admin |
| `module.stocktakes.edit`(改义)| 从此只剩取消一张未过账的盘点单(Batch 3a;描述改写)| 不变(admin · cco · cto · finance · operations · warehouse)|
| `action.receive_goods` | 建收货单(收货台与现场按单收货);带价另要 `action.price_receipts` + `data.view_purchase_prices`(Batch 3b)| warehouse · admin |
| `action.batch_write_off` | 注销进料与产出批次(注销申请落地之前一个人做完)(Batch 3b)| warehouse · admin |
| `action.wo_create` | 建工单;改 / 取消 / 关闭也认它(或 `module.processing.edit`)(Batch 3b)| warehouse · admin |
| `action.wo_release` | 下达工单;建单人永远不能下达(按人认)(Batch 3b)| finance · admin |
| `action.processing_commit` | 提交加工(Batch 3b)| warehouse · admin |
| `action.processing_rollback` | 回滚加工(回滚申请落地之前一个人做完)(Batch 3b)| warehouse · admin |
| `action.processing_aftercare` | 加工损耗分类与交接班(或 `module.processing.edit`);加工费用条目不在内(Batch 3b)| warehouse · admin |
| `action.request_shipping_release` | 提发货放行(与撤回任何一张在等的);批归 CFO,提单人永远不能批(APR-5b)| cco · admin |
| `action.ship_goods` | 发货(`ship_order`)与开具送货单(`record_shipment_issue`);发货队列 `/logistics/shipping`,不带价格(APR-5b)| warehouse · admin |
| `module.processing.view`(新增持有人)| 读加工模块;物料名只经 `material_lookup`,不拿 `module.materials.view`(Batch 3b,Q8)| + warehouse |
