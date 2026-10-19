# 角色与审批矩阵 · Role and approval matrix

**Tim 的裁定,2026-09-23。** 这是后面每一刀照着做的【唯一】参照 —— 谁做、谁批。
**Tim's ruling, 2026-09-23.** This is the single reference later cuts follow — who does, who approves.

来源 / Source:回答 `docs/handbacks/ROLE-MATRIX-0.md` 那张表;grilling 的十三条答复记在
`docs/handbacks/ROLE-1.md` §0。 The survey it answers is ROLE-MATRIX-0; the thirteen grilling
answers (Q1–Q13) are in `docs/handbacks/ROLE-1.md` §0.

## 怎么读 · How to read

| 标记 · Mark | 意思 · Meaning |
|---|---|
| **✅ done** | 已在线上生效(ROLE-1 Batch 1 / PAY-REQ-1 Batch A / Batch B,2026-09-23;ROLE-1 Batch 2a / Batch 2b / PAYROLL-APR-1,2026-09-24;ROLE-1 Batch 4a / 4b / 3a / 3b · APR-5a · APR-5b · APR-6,2026-09-25;APR-7 · APR-8,2026-09-26;APR-9 · APR-10,2026-09-27;OVERTIME-1,2026-09-28)· live since ROLE-1 Batch 1, PAY-REQ-1 Batch A or B, ROLE-1 Batch 2a or 2b, PAYROLL-APR-1, ROLE-1 Batch 4a, 4b, 3a or 3b, APR-5a, APR-5b or APR-6 |
| **B2a · B2b … B5** | 本矩阵里【不需要新生命周期】的部分,排在 ROLE-1 的第 2–5 批;第 3 批拆成两刀(Tim 2026-09-25,Batch 3 grilling Q13):**B3a** = 盘点录数与过账分离 + 四个登记的缺口(✅ done);**B3b** = 收货建单 · 工单 · 加工提交 · 回滚与注销的临时持有人(✅ done);第 2 批拆成两刀(Tim 2026-09-23,Batch B grilling Q1):**B2a** = 财务设置 · 客户信用 · 供应商审批 + 未批准供应商不付款;**B2b** = 合同条款 · 定价 · 直接销售 · 化验 · in scope of ROLE-1, a later batch |
| **[LC]** | 要先造一个「申请 → 批准 → 执行」的生命周期,不在 ROLE-1 里 · needs a request → approve lifecycle; queued separately |
| **= 不变 / unchanged** | 矩阵说保持现状 · the matrix keeps the status quo |

**[LC] 在它的生命周期落地之前,「谁做」那一半已经按矩阵生效或在 B2–B5 里生效;「谁批」那一半还不存在**
—— 那件事今天仍是一个人做完就生效。**Until an [LC] lifecycle ships, the "does" half is in force (or in a
batch) and the "approves" half does not exist yet** — the action still completes in one step.

职位 · Positions: 系统管理员 = `admin`(Tim 的 admin@;★ **角色持每一个码**(常设裁定 2026-09-24,见 §1 最后一行 —— 此前这里写着「只做系统管理」,OVERTIME-1 按 Tim 2026-09-28 的要求更正);admin@ 照惯例不开业务单据)· CFO = `cfo`(Tim 的 tim@,挂同一份员工档案)·
财务 = `finance`(Choo Er)· CCO = `cco`(Sandra)· CTO = `cto`(Phua)· 仓库 = `warehouse`(Fu Sheng)·
MD = `gm`(Vince,只读)。

## ★ 常设规矩 · Standing rule — 一个动作码与它那一页的查看码一起授 · an action code is granted together with its page's view code

**Tim 的裁定,2026-10-08(MES-5a-2 close-out 裁定 f,选项 A)。** 每一个动作码(`action.*`,以及在一页之内当动作用的 `module.*.edit`)
**都与【用它的那一页的门】要的查看码一起授**。页面**不放宽**:门照旧是查看码,只持动作码的人进不了那一页。
**Tim's ruling, 2026-10-08 (MES-5a-2 close-out ruling f, option A).** Every action code — `action.*`, and a `module.*.edit` used as an action
inside a page — is granted **together with the view code of the page where that action is used**. Pages are **not** widened.

**为什么:** MES-5a-2 close-out 在 HEAD 的本地重建上量过:只持 `action.manage_devices` / `action.confirm_capture` / `module.finance.edit` 一个码的会话,
三支函数都放行,三页都进不去(门是 `module.processing.view` / `module.finance.view`,`devices` 的读策略同一个码)——
`docs/surveys/MES-5b/MES-5a-2-CLOSEOUT.md` §2 f。**单独授一个动作码,给出去的是一个用不了的角色。**

**线上核对(2026-10-08 18:58 CST,只读,`postgres`,基表;`docs/surveys/MES-5b/ruling-f-readings.sql`,`READ_OWN_EXIT=0`)—— 七个有在册持有人的角色全部满足:**

| 页面 · 门 | 动作码 | 持它的角色(都同时持那个查看码)|
|---|---|---|
| `/operation/devices/[id]` · `module.processing.view` | `action.manage_devices` | admin · cto |
| 同上 | `action.confirm_capture` | admin · cto · warehouse |
| `/operation/processing/[id]` · `module.processing.view` | `action.processing_commit` · `action.processing_rollback` · `action.processing_aftercare` | admin · warehouse |
| 同上 | `module.processing.edit` | admin · cco · cto |
| `/finance/electricity` · `module.finance.view` | `module.finance.edit` | admin · finance |

cfo · gm 不持以上任何一个码。16 对(角色 × 动作码)全部同时持有查看码,0 对缺。

~~**机制(还没有建):** MES-5b 的并入 —— 一道自动检查(fixture 或 gate),任何角色持一个动作码而不持它那一页的查看码就红
(`docs/forward-queue.md` 的「⬜ ★ MES 组」第 8 行)。在它落地之前,这一条是一条要人记的规矩。~~

**★ 机制(✅ MES-5b-1,`v1.4.45`,2026-10-08,Step 0 Q30 · Q31):这一条从此是机制,不是要人记的规矩。**
* **读法是【任一】**(Q30):一个动作码用在门不同的几张页面上(15 个码如此,Step 0 §1.5),持【其中一张】的查看码就够。
  「全部」被否掉:它会撞上仓库不持 `module.sales.view`(APR-5b),而 `action.ship_goods` 也出现在 `/sales/orders/[id]` 上。
* **声明在目录里**:`permissions.requires_view_any`(text[])—— 33 个动作码各列出用它的页面的门;页面由这个码自己把门的列它自己
  (`action.bulk_import` · `action.manage_permissions` · `action.metal_prices` · `action.overtime_*` · `action.ship_goods`);
  `action.anonymise_employee` 没有屏幕,不声明。只有动作码声明;`module.*.edit` 仍由原来那一道 `EDIT_REQUIRES_VIEW`(同模块的查看码)管。
* **四处执行同一份声明:**
  ① `set_role_permissions` 按名拒 `ACTION_REQUIRES_VIEW|<动作码>|<查看码,…>`(角色页上一句话说出缺哪一个,`permissions.errActionRequiresView`);
  ② `role_permissions` 引导的自检(`BOOTSTRAP_ACTION_REQUIRES_VIEW`)与 `permissions` 目录自己的自检(`PERMISSIONS_REQUIRES_VIEW_INVALID` /
     `_UNDECLARED` —— 以后加一个动作码而不声明,重建当场失败);
  ③ fixture 257 FCHECK:重建库里【每一个】角色都满足;
  ④ 构建里的 `scripts/check-action-view-declared.mjs`:每一个声明的码真的是一张【用这个动作码】的页面的门,用到了却没声明的、声明了却没人用的都红。
* **线上核对(迁移自己的自证,2026-10-08 21:28 CST):七个有持有人的角色全部满足,0 对违反**(Step 0 §0 表 2 量的是 67 / 67)。
* **引导(全新安装)修了两处(Q31):** ~~引导的 admin 持目录里除 `module.tasks.view_all` 之外的每一个码(与 §13 的常设裁定一致 —— 那一条说的是
  「保留 + 每一个新码」,而 `module.tasks.view_all` 从来不在 admin 手里)~~ ★ **MES-5b-3(2026-10-09,Tim 裁定)起引导的 admin 持目录里【每一个】码,
  含 `module.tasks.view_all`;线上的 admin 同一支迁移补齐(75 / 75)**;引导的财务加上 `module.processing.view`(它持 `action.wo_release`,
  下达在 `/operation/orders/[id]`)。**线上的角色本刀一个都没动。**

---

## 1 · 权限、账号、审批设置 · Permissions, accounts, approval settings

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 权限、账号、角色码、账号↔员工关联、审批开关与策略 · permissions, accounts, role codes, account–employee links, the approvals switch and policy | admin 一个 · admin only | — | ✅ done(`cco` 交出 `action.manage_permissions`)|
| 停用 / 重新启用登录账号 · disable / re-enable a login account(HISTORY-1,Tim 的 Q22 · Q2)| admin 一个(`action.manage_permissions`)· admin only | — | ✅ done(HISTORY-1,2026-09-28:`/settings/accounts` 每一行一颗「停用 / 重新启用」,**没有删除钮**。判据在库里 `record_account_event`:不许停用自己(`CANNOT_DISABLE_SELF`)、不许停用最后一个真的管理员(`LAST_ADMIN_PROTECTED`,与 `guard_last_admin` 同一份判据)、已停用 / 未停用按名拒。每一次建号、停用、启用与建到一半的回滚删除都记进变更记录(`auth.users` 的账号事件)。冒烟与探针的一次性 `*@test.local` 号照旧删除,不在这条之内(Q4))|

## 2 · 财务 · Finance

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 付款与冲销付款 · payments and their reversals | 财务 · finance | CFO | 做:= 不变 · 批:✅ done(PAY-REQ-1 Batch A:付款申请 → CFO 批每一张 → 财务付;收款、整笔付已批准的报销 / 医疗申报不批)|
| 银行转账、预扣税缴纳 · bank transfers, WHT remittance | 财务 · finance | CFO | 做:= 不变 · 批:✅ done(PAY-REQ-1 Batch B:转账与其冲销、预扣税缴纳与其冲销都经付款申请 → CFO 批每一张 → 财务执行;缴纳冻结提交时的应缴额)|
| 采购质保金释放 · PO retention release | 财务 · finance | ~~CFO~~ **不批 · none** | 做:✅ done(门从 `purchasing.edit` 换成 `finance.edit`)· ~~批:[LC] 付款申请~~ **撤回(Tim,PAY-REQ-1 Q5,2026-09-23):释放不动钱、也不生应付(`release_purchase_order_retention` 只盖一个决定的戳,不过分录),所以没有东西可批;钱在它真正被付出去的那一刻受控 —— 那一笔走付款申请** · **withdrawn: release moves no money and creates no payable; the money is controlled when it is actually paid** |
| 费用、医疗申报付款、预付款冲抵、销售发票、运费单据、汇率 · expenses, medical-claim payment, prepayment application, sales invoices, freight documents, FX rates | 财务 · finance | 不批 · none | = 不变 · unchanged。★ PAY-REQ-1(Q2(c)):费用单与运费单**不许生下来就已付** —— 一律挂账,钱经付款申请离开 · expenses and freight documents are always recorded unpaid; the money leaves through a payment request |
| 贷项通知、作废发票 · credit notes, invoice voids | 财务 · finance | CFO | 做:= 不变 · 批:✅ done(APR-5a,2026-09-25:`invoice_requests` —— 财务提 `submit_credit_note_request` / `submit_invoice_void_request`,CFO 批每一张、不分档,**批即按冻结的日期过账**;提单人按人认永远不能批;提单人之外没人批得动时提交就拒 `INVOICE_REQUEST_NO_OTHER_DECIDER`;旧的 `create_credit_note` / `void_invoice` 按名拒 `INVOICE_NEEDS_APPROVED_REQUEST`;发票两张表没有直连写、`invoice_voided` 只由作废传播写、`reverse_journal_entry` 拒发票与贷项分录、挂着贷项的发票不作废;没有新码)|
| GST 申报与更正 · GST filing and correction | 财务 · finance | CFO | 做:= 不变 · 批:✅ done(APR-10,2026-09-27:`gst_filing_requests` —— **CFO 批的是报出去之前的那一组数**:财务提 `submit_gst_filing_request`(冻结那一季 F5 每一格;前置条件仍是那一季每个月都已关账),CFO 批每一张、不分档 —— 再判锁、再算一遍,逐字相等才抄进 `gst_return_boxes`,期间 `open → approved`;财务去 IRAS 报之后 `record_gst_filing` 一步记下申报日与参考号(`approved → filed`,不经批准)。`file_gst_return` 只会按名拒 `GST_FILING_NEEDS_APPROVED_REQUEST`。开更正件(F7)仍是一步;**报 F7 走同一张申请**,CFO 逐格看见与原件快照的差。在等时把锁挪回那一季(`reopen_period`、重开年度、手动锁)按名拒 `GST_FILING_WAITING_BLOCKS_REOPEN`;数字在等待中变了,批准拒 `GST_RETURN_CHANGED_SINCE_REQUEST`。提单人按人认永远不能批;提单人之外没人批得动时提交就拒 `GST_FILING_NO_OTHER_DECIDER`;审批关着时生下来就批准;在途挡关闭。没有新码)|
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
| 处置 · disposal | 财务 · finance | CFO | 做:= 不变 · 批:✅ done(APR-9,2026-09-27:处置申请 → CFO 批每一张、不分档 → 批准当场处置,处置日 = 批准日;`dispose_fixed_asset` 只会按名拒 `ASSET_DISPOSAL_NEEDS_REQUEST`;在等时卡上的价值列冻结;处置分录从凭证页冲不掉 —— 走源路径,而处置还没有撤销的路,见 known-issues `APR9-NO-DISPOSAL-REVERSAL-YET`)|

## 5 · 人事与薪资 · HR and payroll

~~**Sandra(cco)只管 KPI 与绩效评估;其余人事与薪资全部归财务。**~~
~~**Sandra (cco) owns only KPI and performance reviews; all other HR and payroll work is finance's.**~~
★ **已不成立(Tim 2026-09-28)**:Tim 2026-09-28 19:00:35 CST 以 admin@ 改了 `cco` 的码,加上 `module.hr.edit` 与 `action.decide_hr_requests`,是他本人所为、有意为之(LEAVE-BAL-1 收尾时读到,以 postgres 读基表 `role_permissions` 复核:cco 41 行,`created_at` 全是 19:00:35,`created_by` = admin@)。**cco 从此也持 `module.hr.edit`,并决定请假与医疗申报。** 划掉而不删 —— 一条撤回的规矩与一条从没写过的规矩,读起来一样。
★ **No longer true (Tim, 2026-09-28 19:00:35 CST):** Tim, signed in as admin@, added `module.hr.edit` and `action.decide_hr_requests` to `cco`; intended. **cco now also holds `module.hr.edit` and decides leave and medical claims.** Self-approval rules apply to cco as to every other approver: four eyes by person (never its own raise, never its own leave or claim); R2 covers only the CFO.

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 工资期与算薪、考勤完成与重开、员工档案(月薪除外)· payroll periods and calculation, attendance completion and reopen, employee records other than salary | 财务 · finance | 不批 · none | ✅ done(`module.hr.edit` 从 cco 移到 finance)· ★ **cco 2026-09-28 又拿回 `module.hr.edit`**(Tim 以 admin@ 改,有意为之,见本节开头)|
| 工资过账与撤销 · payroll posting and its reversal | 财务 · finance | CFO | 做:✅ done · 批:✅ done(PAYROLL-APR-1,2026-09-24:过账申请 / 撤销申请 → CFO 批每一张、不分档 → 财务执行;批之前什么都不过账。★ 工资期是公司的单据:主角那条腿对谁都不成立,CFO 批含他自己工资行的一期、留痕说出来;提单人那条按人认。R2 永远不覆盖工资)|
| 工资、CPF、扣款的付款 · payroll, CPF and deduction payments | 财务 · finance | 不批 · none | ✅ done(~~cco 不再持 `hr.edit`~~ ★ cco 2026-09-28 又持 `hr.edit`(Tim);这条路只认 `finance.edit`,cco 不持,所以仍只归财务)· ✅ **只能跟在一次批过的过账后面**(PAYROLL-APR-1:`posted` 只经批过的申请到达;挂着撤销申请时三支付款按名拒 `PAYROLL_REVERSAL_REQUESTED`)|
| 调薪 · salary changes | 只经绩效评估或调薪申请 · only through a performance review or a salary-change request | CFO | 直连写 `employees.monthly_salary` 一律拒:✅ done · 调薪申请:✅ done(APR-9,2026-09-27:财务提、不许给自己提;CFO 批,**CFO 这个人是提单人或主角时 cco 批** —— 与绩效评估同一份判据 `pay_decision_code`;不看审批开关,永远等人批;批准当场改月薪,履历带生效日;一个人一次在途调薪,跨评估)· **绩效评估的侧门关上**(APR-9 Q1:直连只许建草稿,生命周期列只经函数,提交之后调薪与转正结论冻结;评估不许录第一份月薪)· **第一份月薪**:财务录一次(Q7),✅ done |
| 绩效评估(做)· performance reviews (doing them) | cco | — | ✅ done(`action.hr_reviews`)|
| 绩效评估(批)· performance reviews (approving) | — | CFO;**CFO 是提交人或主角时 cco 批**(Q5)· CFO; cco when the CFO is the submitter or subject | ✅ done(`action.approve_review` · `review_approval_code`)|
| 请假与医疗申报(批)· leave and medical claims (deciding) | — | 财务;**CFO 也可以决定任何一张**(Q4);★ **cco 也决定**(Tim 2026-09-28,见本节开头)—— 按人认的四眼对 cco 与每一个审批人一样:提单人或当事人是自己就不能批;R2 只对 CFO · finance; the CFO may decide any; **cco also decides** (Tim, 2026-09-28) — self-approval rules apply as for every approver | ✅ done(`action.decide_hr_requests`)|
| 当事人正是审批人时 · when the designated approver is the subject | — | 交给 CFO · goes to the CFO | ✅ done(同上:CFO 持决定码)|
| Tim 自己的请假 · Tim's own leave | — | Tim 自己批,标记 `self_decided`(R2 扩到请假,只对 CFO)· Tim, flagged | ✅ done |
| Tim 自己的医疗申报 · Tim's own medical claim | — | R2 不变,标记 · unchanged R2, flagged | ✅ done(CFO 账号从此真的走得到这一步)|
| 员工匿名化 · employee anonymisation | admin 一个 · admin only | — | ✅ done(`action.anonymise_employee`)|
| 现场员工标记 · marking an employee as site staff | 财务 · finance(`module.hr.edit`,建档与编辑员工的同一个表单)| 不批 · none | ✅ done(OVERTIME-1,2026-09-28:`employees.is_site_staff`,默认否,迁移一个人都没标;**不是**工作类别 —— shopfloor 的 Fu Sheng 不是现场员工)|
| 现场员工加班(录)· site-staff overtime (entering) | 财务 · finance —— 按月一批,一个人一天一行:日期 + 小时 + 可选备注 | 仓库 · warehouse | 做:✅ done · 批:✅ done(OVERTIME-1,2026-09-28:`action.overtime_enter` → finance · admin;`/hr/overtime`。只录得进现场员工(提交与批准时再判);一个人一天一行(`OVERTIME_DUPLICATE_DAY`);一个月同一时刻一批开着的,批过之后可开补充批;提单人之外没有持批准码的人时建批与提交按名拒 `OVERTIME_NO_OTHER_APPROVER`;那个月考勤完成之后一切改动按名拒 `OVERTIME_MONTH_COMPLETE`;没有补发到后一个月)|
| 现场员工加班(批)· site-staff overtime (approving) | — | 仓库 · warehouse(Fu Sheng)—— 整批一次,驳回要备注 | ✅ done(OVERTIME-1:`action.overtime_approve` → warehouse · admin;**审批开关不管它**,开着关着都要人按;提交人按人认不能批(`\|raiser`),批里任何一个员工按人认不能批(`\|subject`);R2 永远不覆盖加班;没有 CFO 越级。批过的小时在那个月考勤完成时冻进底稿 —— 进工资的【唯一一次】;报小时,不报钱(政策 7.1))|
| 加班的冲销、撤回、丢弃 · overtime reversal, withdrawal, discard | 财务 · finance(`action.overtime_enter`)| 不批 · none | ✅ done(OVERTIME-1:撤回 = 在等批的回到草稿;丢弃 = 草稿或退回的批作废;冲销 = 批过的整批作废(要理由),只在那个月考勤还开着时 —— 然后重录一批、重新批)|
| 身份信息(NRIC、准证号)· identity data | 只归财务 · finance only(Q6)· ★ **CFO 也读得到**(Tim 2026-09-23,PAY-REQ-1:CFO 持每一个 view 码;录入与改动仍只归财务)| — | ✅ done(`data.view_identity` 从 cco / cto / admin 拿掉;cfo 加上)|

## 6 · 采购与供应商 · Purchasing and suppliers

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 开采购单,按品类 · raising a PO, by category | 工厂耗材:仓库 · 设备与货物:cco · 办公用品:财务 | 分级不变:< 1,000 财务、≥ 1,000 CFO | ✅ done(APR-10,2026-09-27:`purchase_orders.category`(`consumables` / `equipment_goods` / `office`,生下来就定死;线上 11 张全部回填 `equipment_goods` —— Step 0 量过每一张买的都是电池原料或设备);三个开单码 `action.raise_po_consumables` → warehouse · `action.raise_po_equipment` → cco · `action.raise_po_office` → finance,每一个也给 admin;warehouse 另拿 `module.purchasing.view`;`module.purchasing.edit` 不再开单(cto 因此开不了单);资产行与电池料行只能在「设备与货物」里(`PO_CATEGORY_LINE_MISMATCH`);提单人之外没人批得动时开单就拒 `PO_NO_OTHER_DECIDER`;四张采购表没有直连写(`PO_THROUGH_FUNCTION_ONLY`)。分级审批不变)|
| 修改、取消、关闭采购单 · amend, cancel, close | 开单人 · the raiser **或持这一类开单码的人** · or a holder of that category's raise code(Tim,APR-10 grilling Q7)| — | ✅ done(APR-10,2026-09-27:改 · 取消 · 关闭 · 重开 · 套付款条款模板都经 `assert_po_manager`(判据 `po_may_manage`:开单人本人按人认,或此刻持这张单那一类的开单码),其余按名拒 `PO_NOT_RAISER_OR_CATEGORY_HOLDER`;批准照旧)|
| 供应商建档 · supplier creation | cco · 仓库 · 财务 | — | ✅ done(ROLE-1 Batch 2a:warehouse 拿到 `module.suppliers.view` + `.edit`,Q5;cto 保留它的宽码)|
| 供应商批准、拉黑、恢复 · supplier approval, blacklisting, restoring | — | CFO;**建档人永远不能批自己建的** | ✅ done(ROLE-1 Batch 2a:`action.supplier_approve` · `set_supplier_status` · `supplier_status_moves()` · 按人拒自批 · `created_by` 不可改 · `approval_log` 加 `supplier` · `supplier_status_history` · `operations_now` 的 `supplier_pending_approval`;付款申请提 / 批 / 付与新采购单都按名拒未批准的供应商)。原计划:B2a(Q11:批准 / 驳回 / 拉黑 / 恢复归 CFO;送审 / 启用 / 暂停 / 归档归 `suppliers.edit`)。★ **Tim 2026-09-23:供应商批准落地之后,给一家【未批准】的供应商,付款申请提不了、批不了、付不了**;新开采购单也拒(Batch B grilling Q5–Q9)|
| 合同条款 · contract terms | cco | CFO | 做:✅ done(ROLE-1 Batch 2b:`action.contract_terms` 管建合同与七张条款表 —— `contracts` 与条款表的写策略和 `enforce_write_permission` 从 `suppliers.edit` / `customers.edit` 换过来;`/contracts/new` 的保存钮按码关上并说出码;把单据挂到合同上仍归开单据的码,`link_document_to_contract` 不动)· 批:✅ done(APR-8,2026-09-26:合同只有 active 有效力,**进入 active 的每一条路都经 CFO** —— `terms_requests` 的 `contract_activate`;新合同只建得出草稿(`CONTRACT_ACTIVATES_THROUGH_REQUEST`);生效中表头 `CONTRACT_ACTIVE_IS_FROZEN`、七张条款表 `CONTRACT_TERMS_FROZEN`,改 = 暂停(一步)→ 编辑 → 再申请,CFO 看见与上一次批准时那一份的差别;等待中冻结;批准时 fingerprint 再比;提单人之外没人批得动时提交就拒;审批关着时生下来就批准。条款表的编辑界面登记 `APR8-NO-TERM-EDITOR`)· 编辑界面:✅ done(TERMS-EDIT-1,2026-09-27:`/contracts/[id]` —— 表头与七张条款表,cco 增 / 改 / 删,生效中 / 在等 / 到期 / 终止时按不动并说出理由;卖方合同条款不齐时申请生效按名拒 `CONTRACT_TERMS_INCOMPLETE`;CFO 在同一页批)|
| 供应商评分卡与评审 · supplier scorecards and reviews | 记一次评审(V23 没给时读「Not graded — V23 not set」)、带理由更正、设 V23(权重 · 等级线 · 评审周期)与 V24(每个等级的预付上限 · 抽样级别):`action.supplier_review`(**admin · cco**)· recorded by holders of the review code | — | ✅ done(MES-8a,2026-10-16,`v1.4.56`,MES-0 Q90 · MES-8 Step 0 Q6:**一个新码 `action.supplier_review`**,授 admin · cco,声明 `module.suppliers.view`;线上授权只多了这两行。**读**:评分卡(现算的计数)、评审、`/suppliers/scorecards`、V23 / V24 两个待补的值都跟着供应商的查看码 `module.suppliers.view`;`supplier_review_due` 提醒只给持 `action.supplier_review` 的人(V23 的周期空着时一行都不出)。**采购单上的等级与预付警告**随下单的人(采购单表单要 `module.suppliers.view` 才看得见等级;建单的返回值里照样带警告)—— 警告从不拒绝。**收货页的抽样建议**跟着 `module.suppliers.view`,不加任何一项必须的化验。没有新审批。逐角色读数表在 `docs/handbacks/MES-8a.md`)|
| 供应商对账单 · supplier statements (SST-…) | 签发、带理由取代、存 PDF:`module.finance.edit`(admin · finance)· issued by holders of the finance edit code | — | ✅ done(MES-8a,2026-10-16,`v1.4.56`,MES-0 Q79 · MES-8 Step 0 Q7 · Q9:**没有新码、没有新审批**。读清单、对账单页与它的 PDF(私有桶 `supplier-statement-documents` 的读策略)随 `module.finance.view`;预览与签发另要 `data.view_purchase_prices` 与 `module.inbound.view`(缺一个按名拒:一份金额被遮或收货看不见的清单对不上总账)。对不上总账 2000 就不签发(`SUPPLIER_STATEMENT_DOES_NOT_TIE`);员工永远不会有一份。桶的上传随 `module.finance.edit`,删除只放行【还没被记下的】孤儿)|

## 7 · 定价 · Pricing

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 金属价格 · metal prices | 财务 · finance | — | ✅ done(ROLE-1 Batch 2b:`action.metal_prices` 管 `metal_prices` · `metal_price_indices` · `index_market_calendar` · `pricing_settings`(报价阈值)与 `upsert_metal_prices`;阈值面板改为看得见、按不动、说出码)|
| 定价公式 · pricing formulas | cco | CFO | 做:✅ done(ROLE-1 Batch 2b:`module.pricing.edit` 从 cto 与 finance 拿掉,只剩 cco 与 admin;两个无人持有的角色 procurement / sales 保留它,登记 `ROLE1B2B-UNHELD-PRICING-EDIT`;公式页补上 PermissionGate,关掉 `PAYREQB-FORMULA-PAGES-NO-DISABLED-GATE`)· 批:✅ done(APR-8,2026-09-26:新公式生下来停用、挂一张 `formula_create`;改在用的 = `formula_change`(完整拟议条款,批准时就地替换,等待中旧条款照旧生效;已承诺的单据读副本);重新启用 = `formula_reactivate`;停用 · 删除仍是 cco 一步;公式两张表的写策略拿掉,直连写按名拒 `PRICING_FORMULA_THROUGH_REQUEST_ONLY`;CFO 批每一张、不分档,门 = pricing.view + 两个价格码 + suppliers.view + customers.view)|

## 8 · 进料、库存、盘点 · Inbound, stock, stocktake

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 建收货单 · goods-receipt creation | 仓库 · warehouse | — | ✅ done(ROLE-1 Batch 3b,2026-09-25:`action.receive_goods` → 仓库与 admin,管 `create_inbound_batch` 与 `receive_inbound_batch_against_po`,先问它 —— 带价建单另要两个定价码,拒绝点名建单码(Batch 3b Q5);cco · cto · 财务交出建单;收货台、现场收货、采购单「按单收货」与加工页的入口看得见、按不动、说出码) |
| 收货定价与改价 · receipt pricing and repricing | 财务 · finance | CFO | 做:✅ done(ROLE-1 Batch 4a,2026-09-25:`action.price_receipts` 只归财务(与 admin),定价面板、按已承诺条款改价与建单带价都要它 **加** `data.view_purchase_prices`,两个都在库里问;定价引擎 `reprice_inbound_batch` 自己再问后者 —— 所以应用化验也要看得见采购价;cco、cto、仓库从此定不了价。三扇侧门关上:`price_history` 不能直连插、`purchase` 分录不能从凭证页冲销(`JE_REVERSE_USE_SOURCE_PATH`)、引擎不能直调)· 批:✅ done(ROLE-1 Batch 4b,2026-09-25:四扇门 —— 定价面板、按已承诺条款改价、收货台带价、应用化验 —— 都只提一张 `receipt_price_requests`;CFO 批每一张(二级,门 `module.inbound.view` + `data.view_purchase_prices`),**批准当场过账**,记在批准日、按那天的牌价;驳回要理由;提单人本人或财务可撤回;等待期间供应商 / 采购单 / 采购行 / 含量 / 注销 / 第二张申请都按名拒,批准时指纹再比;低于已付按名拒;提单人之外没人批得动时提交就拒;化验来源的申请批准后才升 `final`;审批关着时生下来就批准并过账)|
| 应用化验结果 · assay application | cto | — | ✅ done(ROLE-1 Batch 2b:`action.apply_assay` 管应用与撤销、进料与产出、连同两种试算;**记录**化验结果仍归 `inbound.edit` / `output.edit`;两扇侧门按名关 —— 直连写应用标记 `ASSAY_APPLY_THROUGH_FUNCTION_ONLY`、直连写出自化验的含量 `ASSAY_CONTENT_THROUGH_FUNCTION_ONLY`;「记录并应用」对无码者看得见、按不动。Tim 2026-09-23 确认:cto 应用化验,价随之重算并过应付 —— **ROLE-1 Batch 4b 起**:价随之重算并【提一张定价申请】,CFO 批了才过应付;`reprice_inbound_batch` 里嵌套的 `inbound.edit` 检查不拆,归 Batch 4)|
| 删除批次(报废入口)· batch deletion, the write-off path | 仓库提 · warehouse requests | CFO | 在生命周期之前只归仓库(Q10):✅ done(ROLE-1 Batch 3b,2026-09-25:`action.batch_write_off` → 仓库与 admin,管 `soft_delete_inbound_batch` 与 `soft_delete_output_batch`;两张表上的注销钮按码关上)· 批:✅ done(APR-7,2026-09-26:`warehouse_requests` 的 `write_off_inbound` / `write_off_output` —— 仓库提 `submit_inbound_write_off_request` / `submit_output_write_off_request`,CFO 批每一张、不分档,**批即注销**(流水与分录落在批准日、按那一刻的价值);还有料(计价与否)或挂着已签发证书才经 CFO,空批仓库照旧一步删;`deleted_by` = 提单人;在等的时候那一批上任何流水按名拒 `WAREHOUSE_REQUEST_FREEZES_BATCH`;欠款提交时与批准时各查一遍;提单人之外没人批得动时提交就拒 `WAREHOUSE_REQUEST_NO_OTHER_DECIDER`;一步删还有料的批次按名拒 `WAREHOUSE_NEEDS_APPROVED_REQUEST`;没有新码) |
| 盘点录数 · stocktake counting | 仓库 · warehouse | — | ✅ done(ROLE-1 Batch 3a,2026-09-25:`action.stocktake_count` → 仓库与 admin,管开单 `open_stocktake` 与录数 `record_stocktake_count`;每一次录数与重录连同录数的人追加进 `stocktake_counts`(只增不改,`counted_by` 由函数写);盘点三张表没有直连写(`STOCKTAKE_THROUGH_FUNCTION_ONLY`);取消仍归 `module.stocktakes.edit`)|
| 盘点过账 · stocktake posting | 财务 · finance;**录过数的人永远不能过账**(系统先要记下谁数的)| — | ✅ done(ROLE-1 Batch 3a,2026-09-25:`action.stocktake_post` → 财务与 admin;开单人 `SELF_APPROVAL_FORBIDDEN\|raiser`,`stocktake_counts` 里每一个录过数的人 `STOCKTAKE_COUNTER_CANNOT_POST`,都按人认)|
| 库存安全:上限、滞留、隔离 · storage safety: ceilings, dwell, quarantine | 见右 · see status | — | ✅ done(MES-3a,2026-10-06,Step 0 Q32:**没有新码、没有授权变动**。新页 `/inventory/storage-safety` 门 `module.inventory.view`,每一段的行带它自己的谓词(上限:`module.suppliers.view` 或 `module.inventory.view`;批:进料 / 产出查看);NEA 类别字典写 `module.materials.edit`;执照下每一类的上限写 `module.suppliers.edit`(与执照同一个码);库位的「隔离库位」写 `module.inventory.edit`;结束一个安全状态 —— 进料 `module.inbound.edit`、产出 `module.output.edit`(新函数 `set_output_safety_states`),理由必填;上限与隔离的拒绝落在收货(`action.receive_goods`)、转移与手工产出那几扇已有的门上。逐角色读数表在 `docs/handbacks/MES-3a.md`)|
| 标签与扫码 · labels and scanning | 见右 · see status | — | ✅ done(MES-3b,2026-10-07,Step 0 Q28:**没有新码、没有授权变动**。印标签 = 那样东西自己的查看码(进料批 `module.inbound.view` · 产出批 `module.output.view` · 库位 `module.inventory.view`),补印同一个码、理由必填;标签模板字典写 `module.inventory.edit`、读 `module.inventory.view`(`/settings/dictionaries` 的入口因此多认一个查看码 —— 没有角色因此新进得来);危险品 UN 编号字典与物料上的 UN / HS 编码写 `module.materials.edit`;`/inventory/scan` 门 `module.inventory.view`,搬货仍是 `create_stock_transfer` 的 `module.inventory.edit`;`/b/<批号>`、`/loc/<库位号>` 登录即可打开,看得见什么按那样东西自己的查看码分,看不见只说要哪个码;发货核对扫码走 `ship_order` 的 `action.ship_goods`;扫码日志读 `module.inventory.view`。逐角色读数表在 `docs/handbacks/MES-3b.md`)|
| 加工记录:时刻、参数、配方、平衡 · processing record: times, parameters, recipes, balance | 见右 · see status | — | ✅ done(MES-4a,2026-10-07,Step 0 Q34:**没有新码、没有授权变动**。提交一炉(连同开始 / 结束 / 班次、挑或敲的称重、配方与值)仍是 `action.processing_commit`;提交之后记值、记异常事件、结算物料平衡归 `action.processing_aftercare`;记 / 更正损耗归 `action.processing_aftercare` 或 `module.processing.edit`(与从前的损耗面板同一对);表头更正(六个字段)归 `action.processing_commit`;新页 `/operation/operation-types`(工序:字段、机器、容差、配方)读 `module.processing.view`、改 `module.processing.edit`(与那几张表的写策略同一个码);班次与异常事件种类两本字典写 `module.processing.edit`、读 `module.processing.view`(`/settings/dictionaries` 的入口因此多认一个查看码);月末那一行(平衡未结,只警告)读 `module.finance.view`;提醒臂 `processing_balance_unclosed` 读 `module.processing.view`。直连改三张加工表与损耗表一律按名拒。逐角色读数表在 `docs/handbacks/MES-4a.md`)|
| 电芯构造、新产品编号、损耗来由、交叉污染抽检 · cell construction, product numbering, loss basis, contamination checks | 见右 · see status | — | ✅ done(MES-4b,2026-10-08,Step 0 Q28:**没有新码、没有授权变动**。收货时选构造随收货本身的码(`create_inbound_batch` / `receive_inbound_batch_against_po` 原来的门);事后在批次页上补构造:进料批 `module.inbound.edit` 或 `action.processing_commit`,产出批 `module.output.edit` 或 `action.processing_commit`(`set_batch_cell_construction`);批次喂过一张已提交的单之后构造锁死,谁都改不了(`CELL_CONSTRUCTION_LOCKED`);算出电解液损耗、把它重算、记 / 更正抽检都归 `action.processing_aftercare`(与 MES-4a 记值、结平同一个码);工序页上的电解液那一段(勾 "Electrolyte evaporates in this step"、填份额)改 `module.processing.edit`;新页 `/operation/contamination`(每班一格 + 抽检清单)读 `module.processing.view` 或 `module.output.view`;两本新字典(电芯构造 · 交叉污染流)写 `module.processing.edit`,电芯构造读 `module.processing.view` / `module.inbound.view` / `module.output.view` 任一,交叉污染流读 `module.processing.view` / `module.output.view` 任一;提醒臂 `contamination_check_missing` 与 V10 · V11 读 `module.processing.view`。抽检表只开 SELECT,直写一律被拒。逐角色读数表在 `docs/handbacks/MES-4b.md`)|
| 逐模组放电、模组数、拆去隔离 · discharge by module, module count, quarantine split | 见右 · see status | — | ✅ done(MES-5a-1,2026-10-08,Step 0 Q10 · Q29:**没有新码、没有新审批、没有授权变动**。记 / 更正一个模组的放电结果 `action.confirm_capture`(采集那条管道的码,线上 admin · cto · warehouse);通道分配(分配 / 更正 / 撤下)与拆去隔离 `action.processing_aftercare`(线上 admin · warehouse),拆分记下的那一炉另照常要 `action.processing_commit`(同一批人持);模组数:收货时随收货本身的码(`create_inbound_batch` / `receive_inbound_batch_against_po` 原来的门),事后在批次页上补:进料批 `module.inbound.edit` 或 `action.processing_commit`,产出批 `module.output.edit` 或 `action.processing_commit`(`set_batch_module_count`);核实之后锁死,谁都改不了(`MODULE_COUNT_LOCKED`);V9 在物料编辑器里改 `module.materials.edit`,待补的值 V9 读 `module.materials.view`;提醒臂 `discharge_unverified` · `discharge_quarantine_pending` 读 `module.processing.view`;放电结果与进度(`discharge_module_rows` · `discharge_status_by_batch` 与三张新表)读 `module.processing.view` / `module.inbound.view` / `module.output.view` 任一;屏幕照片传进 `capture-photos` 要 `action.confirm_capture`、打开要 `module.inbound.view` 或 `module.logistics.view`(那个桶 MES-2 起的读规则,本刀没动);拆分表单里的隔离库位清单读 `module.inventory.view`(读不到的人看到"受限",不是"没有隔离库位")。三张新表只开 SELECT,直写一律被拒。逐角色读数表在 `docs/handbacks/MES-5a-1.md`)|
| 电表与读数、一炉的电量、电费单的分摊 · meters and readings, run energy, electricity bill allocation | 见右 · see status | — | ✅ done(MES-5a-2,2026-10-08,Step 0 Q19 · Q20 · Q27 · Q29 · Q30:**没有新码、没有新审批、没有授权变动**。把一台设备设成电表、挂到机器上或挂回共用池 `action.manage_devices`(设备页的同一支 `save_device`,线上 admin · cto);记 / 更正 / 撤回读数 `action.confirm_capture`(线上 admin · cto · warehouse);读数与一炉的电量(`meter_readings_current` · `processing_run_energy`)读 `module.processing.view`(读数视图另认 `module.finance.view`);电费单的预览读 `module.finance.view`,过账与 V25 的规则 `module.finance.edit`(线上 admin · finance);`/finance/electricity` 三页门 `module.finance.view`;分摊与它的行读 `module.finance.view` 或 `module.processing.view`,**金额在 `data.view_prices` 之后**(五列金额不在列级授权里,只经 `_masked` 视图;kWh 不遮);待补的值 V25 读 `module.finance.view`。付款走既有的付款申请(没有新审批,Q29)。四张新表只开 SELECT,直写一律被拒。逐角色读数表在 `docs/handbacks/MES-5a-2.md`)|
| 物料平衡与得率 · material balance and yield | 见右 · see status | — | ✅ done(MES-5b-1,2026-10-08,Step 0 Q32:**没有新码、没有新审批、没有授权变动**。月度物料平衡与库存滚动(`/operation/balance`)门 `module.processing.view`,读的两张外壳(`processing_balance_monthly` · `stock_rollforward_monthly`)认加工 / 财务 / 库存查看码任一 —— `/inventory` 的平衡合计与月末那一步靠它,与此前 `processing_run_lookup` 给同样几个数时同一组码;得率(`/operation/yield`,`processing_run_yield` · `processing_yield_summary`)门与读都是 `module.processing.view`,**供应商的名字只给持 `module.inbound.view` 的人**(不持的读到「受限」,标签跟着进料批自己的查看码走 —— 七个真角色今天都持它);批次的去向树(`/inbound/[id]/edit` · `/output/[id]/edit` 上的平衡面板,`batch_balance_tree`)认 `module.processing.view` 或那一批自己那一页的查看码;七张基视图谁都读不到。V37(工序页)改 `module.processing.edit`、待补的值读 `module.processing.view`。拆分那一炉自己结平,照旧在拆分函数的码之下(`action.processing_aftercare` + `action.processing_commit`)。逐角色读数表在 `docs/handbacks/MES-5b-1.md`)|
| 撤回电费单、冲销冲抵、结算戳 · reversing an electricity bill, reversing a month-end relief, settlement stamps | 见右 · see status | — | ✅ done(MES-5b-2,2026-10-09,Step 0 Q22 · Q24 · Q25 · Q26 · Q28 · Q32:**没有新码、没有新审批、没有授权变动**。撤回一张电费单 `reverse_electricity_allocation` 要 `module.finance.edit`(线上 admin · finance),理由必填,没有审批(Q25 —— 费用单与它的冲销都没有);`/finance/electricity/[id]` 门 `module.finance.view`,不持 edit 的人看得见撤回钮、按不下去、说出码;撤回记录的三列金额在 `data.view_prices` 之后(列级授权 + `_masked` 视图 + 遮蔽规则,同分摊),件数与理由不遮。过账电费单从此【也】要 `module.finance.view`(Q28,它不再比自己的预览少问一个码;线上持 edit 的都持 view)。冲销一张月结冲抵(`reverse_expense`,`module.finance.edit`)同一笔事务把它冲抵过的估计放回"未结";经付款结过的费用单【每一种】都按名拒,先经付款冲销申请冲掉付款(审批照旧在付款冲销申请那一侧)。结算戳(`remitted_*` / `relieved_*`)从此只经五支财务函数改 —— 加工编辑者(`module.processing.edit`,线上 admin · cco · cto)直连改按名拒,这一扇侧门本来就不该是加工的权限。逐角色读数表在 `docs/handbacks/MES-5b-2.md`)|
| 配料计划 · blending plans(将来那条线 · for the future line)| 见右 · see status | — | ✅ done(MES-5b-3,2026-10-09,Step 0 Q19 · Q32:**没有新码、没有新审批**;本刀唯一的授权改动是 admin 补 `module.tasks.view_all`(Tim,见 §13)。建与改一份计划 `action.wo_create`(线上 admin · warehouse);放行 `action.wo_release`(线上 admin · finance),**建单人永远不能放行**(按人认,`SELF_APPROVAL_FORBIDDEN\|raiser`;建单人之外没有别的持码人时建不出来,`BLEND_NO_OTHER_RELEASER`);取消 `action.wo_create`,理由必填;执行(从计划页记一炉 blending)`action.processing_commit`(线上 admin · warehouse);读 `/operation/blending` 与计划页 `module.processing.view`(七个真角色都持)。批次的金属含量与由它算出的预测只给持那一批查看码的人(进料 `module.inbound.view` / 产出 `module.output.view`,七个真角色今天都持),否则「受限」;混出来那一批的化验对着目标同一条(`module.output.view`)。预测出界只标不拒。逐角色读数表在 `docs/handbacks/MES-5b-3.md`)|
| 样品与保管、化验争议、实验室的供应商、费用冲销的理由 · samples and custody, assay disputes, a lab's supplier, the reason on an expense reversal | 见右 · see status | — | ✅ done(MES-6a-1,2026-10-09,Step 0 Q11 · Q12 · Q13 · Q23 · Q34 · Q38 · MES-0 Q90:**两个新码,没有新审批**。`module.quality.view` → admin · cco · cfo · cto · finance · warehouse(样品与争议两页的门;批次页与化验页上的质量面板对持这个码【或】那一批自己查看码的人都画);`module.quality.edit` → admin · cco · cto(取样、记保管、立争议、记仲裁、撤回、挂仲裁费、设 V16)。**仓库【不】拿编辑码**(Q12)—— 若将来由 Fu Sheng 经手样品,那是一行角色改动(给 warehouse 授 `module.quality.edit`)。**结案**要 `action.apply_assay`(线上 admin · cto;今天应用化验的人 —— 结案预先替他做了那个选择,Q13),它声明的查看码多了 `module.quality.view`。实验室指到供应商在字典编辑器里,随那一节的写码 `module.materials.edit`(Q23);仲裁费是一张普通费用单,`module.finance.edit`,付款照常走付款申请。费用冲销的理由随冲销本身的码,码之后第一件事查(Q34)。线上授权只多了这九行 —— 七个账号、其余角色的码一个没动)|
| 不合格报告与质量暂扣、合同的质量验收限 · non-conformance reports and quality holds, contract quality limits | 开:有 `module.quality.edit` 的人 · opened by a quality editor(或系统,在质量验收限越限时)| 决定:`action.ncr_decide`(admin · cco · cto),**永远不是开单人** · decided by a holder other than the opener | ✅ done(MES-6b-1,2026-10-15,Step 0 Q9 · Q25:**一个新码 `action.ncr_decide`**,授 admin · cco · cto,声明 `module.quality.view`;线上授权只多了这三行。暂扣不是一张审批单据 —— 不在在途单据里,不经 CFO;放行 / 拒收由决定那一下定。拒收之后的出路是既有的 CFO 注销申请(仓库提、CFO 批)。合同的质量验收限与 `quality_limit_basis` 随合同条款的码 `action.contract_terms` 写、随合同生效申请经 CFO 批;卖方合同不声明口径就申请不了生效)|
| 氟、氯与化验指标 · fluorine, chlorine and assay indicators | 见右 · see status | — | ✅ done(MES-6a-2,2026-10-10,Step 0 Q27 · Q38:**没有新码、没有新审批、没有授权变动**。在化验上记氟、氯与五个指标随化验本身的码(进料 `module.inbound.edit` · 产出 `module.output.edit`,两张表单同一支 `record_assay_result`);读指标值跟着化验的父批次(进料 / 产出查看码),读指标的定义要进料、产出或物料查看码之一;改、停用一个指标定义在字典编辑器里,`module.materials.edit`(与改物质同一个码)。把氟、氯写进合同的惩罚条款随条款本身的码 `action.contract_terms`;它们在行情(`action.metal_prices`)、公式与承诺(`module.pricing.edit`)、合同计价条款与精炼费(`action.contract_terms`)上一律按名拒 `SUBSTANCE_NOT_PAYABLE` —— 那是【物质的角色】在拒,不是码,所以持什么码都一样。七个真角色此刻能做什么,逐角色读数在 `docs/handbacks/MES-6a-2.md` §5)|
| 分析证书 · certificates of analysis | 签发:`action.issue_coa`(admin · cco)· issued by a holder of the issue code | 作废:CFO 二级审批的仓库申请 `coa_void`(提 = `action.issue_coa`;提单人这个人永远不能批)· voided only through a level-2 CFO request | ✅ done(MES-6b-2,2026-10-15,Step 0 Q20 · Q30 · Q32:**一个新码 `action.issue_coa`**,授 admin · cco,声明 `module.output.view` 与 `module.quality.view`;线上授权只多了这两行。看证书(批次页那一节、`/quality/coa` 清单与证书页、PDF 下载)跟着那一批的查看码 `module.output.view`;清单与证书页另要 `module.quality.view`(那是质量菜单)。没有一步作废的门:作废只经 CFO 申请,作废的证书留着快照与字节;重开是一张新号,旧的指向它)|
| 设备记录与可靠性 · equipment records and reliability | 记停机 / 保养 / 保养间隔、改停机原因字典:`module.processing.edit`(admin · cco · cto · operations)· recorded by holders of the processing edit code | 资本化一次保养:`module.finance.edit`,只在财务的资产卡上 · capitalised only on the finance asset card | ✅ done(MES-7a-1,2026-10-16,Step 0 Q3–Q7:**没有新码、没有授权变动**。表单搬到 `/operation/equipment/[id]`;写入只经五支函数,直连被拒;作废停机仍是自己的函数;读清单、机器页、`/operation/equipment/reliability` 与可靠性函数要 `module.processing.view`;停机原因字典读 `module.processing.view` 或 `module.finance.view`;机器页上的费用选择与成本只给 `module.finance.view`,员工选择只给 HR 的查看码;财务的资产卡照旧读这些记录。逐角色读数表在 `docs/handbacks/MES-7a-1.md`)|
| 备件出给保养 · spare parts issued to maintenance | 出备件 / 带理由退回(机器页的保养记录上):`module.inventory.edit`(线上 admin · cco · cto · finance · operations · sales · warehouse,开场读数)· issued and returned by holders of the inventory edit code | 金额(还挂着的件 × 落地单价)只给 `data.view_prices`;分录(借 6800 / 贷 1200)给读得到总账的人 · amounts only to price viewers | ✅ done(MES-7a-2,2026-10-16,Step 0 Q10 · Q12:**没有新码、没有授权变动、没有审批**。出库记录读 `module.processing.view` 或 `module.inventory.view`;备件库存的读视图 `spare_part_stock` 读 `module.inventory.view`(只有可用数量、有没有价、在不在暂扣 —— 不带钱);6800 是系统科目 —— 科目表的行对每一个登录的人都可读(`accounts` 的读策略是 `USING (true)`,一个科目名不是机密,本刀没改它);V21 读 `module.materials.view`。逐角色读数表在 `docs/handbacks/MES-7a-2.md`)|

## 9 · 加工 · Processing

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 工单 · work orders | 仓库建 · created by warehouse | 财务下达 · released by finance | ✅ done(ROLE-1 Batch 3b,2026-09-25:`action.wo_create` → 仓库与 admin;`action.wo_release` → 财务与 admin,建单人永远不能下达(`SELF_APPROVAL_FORBIDDEN\|raiser`,按人认);改 / 取消 / 关闭 = `action.wo_create` 或 `module.processing.edit`(Q6);建单人之外没有真持有人持下达码时建单按名拒 `WO_NO_OTHER_RELEASER`(Batch 3b Q3);工单页的下达钮对建单人自己的账号说出理由(Q6);改一张已下达的工单不送回重新下达,登记 `ROLE1B3-AMEND-RELEASED-WO`) |
| 加工提交 · processing commit | 仓库 · warehouse | — | ✅ done(ROLE-1 Batch 3b,2026-09-25:`action.processing_commit` → 仓库与 admin;仓库拿 `module.processing.view`、不拿 `module.materials.view`,建工单 · 提交加工 · 加工单详情三页改读 `material_lookup`(它的谓词加上 `module.processing.view`,Batch 3b Q4);加工三张表不许绕过函数写 —— runs / outputs 的 INSERT 与三张表的 DELETE 策略拿掉,直连插 / 删 / 改状态与改挂工单按名拒 `PROCESSING_THROUGH_FUNCTION_ONLY`(Q7 · Batch 3b Q1);损耗分类与交接班 = 新码 `action.processing_aftercare`(仓库与 admin)或 `module.processing.edit`(Batch 3b Q2);加工费用条目仍归 `module.processing.edit`) |
| 加工回滚 · rollback | 仓库提 · warehouse requests | CFO | 在生命周期之前只归仓库(Q10):✅ done(ROLE-1 Batch 3b,2026-09-25:`action.processing_rollback` → 仓库与 admin)· 批:✅ done(APR-7,2026-09-26:`warehouse_requests` 的 `rollback` —— 仓库提 `submit_rollback_request`,CFO 批每一张,**批即回滚**;在等的时候它的产出批冻结;落在已锁期间里的单照旧准许,CFO 那一块先说出来,连同会被一并作废的证书号;`rollback_processing_run` 一张都不回滚,按名拒 `WAREHOUSE_NEEDS_APPROVED_REQUEST`;没有新码) |
| 设备与网关、网关钥匙 · devices, gateways, gateway keys | cto · admin | — | ✅ done(MES-1,2026-10-06:新码 `action.manage_devices` → cto 与 admin;读与处理收件箱只要 `module.processing.view`;网关自己只经匿名函数 `ingest_submit`,凭钥匙、只插入) |
| 确认读数、手工称重、地磅单 · confirm readings, manual weighing, weighbridge tickets | warehouse · cto · admin | — | ✅ done(MES-2,2026-10-06:新码 `action.confirm_capture` → warehouse · cto · admin(Step 0 Q8);确认队列读 `module.processing.view`;地磅单页读 `module.inbound.view` 或 `module.logistics.view`;把一张单分给已有的收货单要 `action.receive_goods`、分给发货行要 `action.ship_goods`;记录与作废校准、校准开关与提前天数仍是 `action.manage_devices`(cto · admin)) |
| 事故登记 · incident register(安全 · Safety)| 记事故、记之后的事实(通报 NEA · 交书面报告 · 关闭 · 带理由的更正)、链 / 解批次、改事故种类字典、设 V19:`module.safety.edit`(线上 admin · cto · warehouse)· recorded by holders of the safety edit code | — | ✅ done(MES-7b-1,2026-10-16,Step 0 Q2 · Q6 · Q8:**两个新码,没有新审批**。`module.safety.view` → 每一个持 `module.processing.view` 的角色(线上 admin · auditor · cco · cfo · cto · finance · gm · operations · warehouse,九个);`module.safety.edit` → admin · cto · warehouse(编辑隐含查看)。**受伤的细节**(谁受伤、伤情、处置、损失天数、外人的名字)只给持 `data.view_health` 的人(线上 admin · cco · cfo · finance · hr,本刀没动)**和受伤的那名员工本人** —— 本人没有安全码时也读得到【自己那一件】(只那一件);审计记录里那几列对别人是「受限」。`data.view_health` 没有授给任何新角色。从一条有效的批次链接开一张来源 incident 的不合格报告随 `module.quality.edit`(admin · cco · cto),暂扣由另一个持 `action.ncr_decide` 的人决定 —— 链接本身从不扣货、不设安全状态。交接班引用事故随交接班自己的码(`action.processing_aftercare` 或 `module.processing.edit`);交接班页读引用要 `module.processing.view`,事故页读引用要 `module.safety.view`。线上授权只多了这十二行。逐角色读数表在 `docs/handbacks/MES-7b-1.md`)|
| 安全巡检与环境监测 · inspections and environmental monitoring(安全 · Safety)| 建 / 改巡检清单、记一次巡检(与带理由的更正)、记 / 关发现、设监测参数与限值(字典)、记监测结果:`module.safety.edit`(线上 admin · cto · warehouse)· recorded by holders of the safety edit code | — | ✅ done(MES-7b-2,2026-10-16,Step 0 Q13–Q16 · Q20:**没有新码、没有授权变动、没有新审批**。读:`module.safety.view`(巡检清单、巡检页、发现、环境页、V18 / V20 两个待补的值、`inspection_due` 与 `inspection_finding_open` 两支提醒)。写:`module.safety.edit`。**「生成任务」**按下的人要持 `module.safety.view`,外加 `module.tasks.view` 或 `module.tasks.edit`,任务记在按下的人名下(私人任务);关掉任务不关发现 —— 发现要持 `module.safety.edit` 的人写下做了什么才关。**从一条发现开一张来源 inspection 的不合格报告**随 `module.quality.edit`(admin · cco · cto),暂扣由另一个持 `action.ncr_decide` 的人决定。**超标的监测结果**在同一笔事务里开一件 `emission_exceedance` 事故,事故随事故登记的读写码。线上授权一行没动。逐角色读数表在 `docs/handbacks/MES-7b-2.md`)|

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
| 签发销毁证书 · issuing a certificate of destruction | 仓库 · warehouse(资格由系统算)| 不批 · none | ✅ done(`action.issue_cod` 从 cto ~~与 admin~~ 拿掉 —— ★ 更正(MES-6b-1,2026-10-15,MES-6b Step 0 Q41 · §14 第 3 条):**admin 自 2026-09-23 起持目录里的每一个码**(`role_permissions.sql` 的 admin 引导;线上 admin 77 / 77,迁移后 78 / 78),所以 admin 仍持 `action.issue_cod`;从 cto 拿掉那一半仍然成立)|
| 作废销毁证书 · voiding a COD | 仓库提 · warehouse requests | CFO | 在生命周期之前只归仓库(Q10,今天已是 —— Batch 3 Step 0 复核:`void_cod` 门 `action.issue_cod`,持有人 admin · warehouse;Q9:不改)· 批:✅ done(APR-7,2026-09-26:`warehouse_requests` 的 `cod_void` —— 仓库提 `submit_cod_void_request`,CFO 批每一张,**批即作废**、没有替代品;在等的时候公开核验页仍然说有效;`voided_by` = 提单人;`void_cod` 一张都不作废,按名拒 `WAREHOUSE_NEEDS_APPROVED_REQUEST`;一个批次、它的证书、消耗它的加工单同一时刻只挂一张在等的申请;没有新码) |
| 月度合规包 · monthly compliance pack (CPK-…) | 冻一个【已关账】月份的包、带理由重出 `-2`、存它的 PDF、设 V26 / V27:`action.compliance_pack`(**admin · cto**)· frozen by holders of the pack code | 不批 · none | ✅ done(MES-8b-1,2026-10-17,`v1.4.57`,MES-0 Q82 · MES-8 Step 0 Q15–Q17:**两个新码,没有新审批**。`module.compliance.view`(读包、实时预览、PDF、V26 / V27 两个待补的值)→ **admin · auditor · cco · cfo · cto · gm**;`action.compliance_pack`(声明 `module.compliance.view`)→ **admin · cto**。线上授权只多了这八行。包是以属主权限冻下来的,读者只要合规查看码就读得到一份完整的包 —— **事故一节没有任何受伤的细节、没有人写的经过、没有名字**(不论读者持不持 `data.view_health`),整份包里没有钱。`compliance_pack_not_frozen` 提醒只给持 `action.compliance_pack` 的人;月结页那一行警告给持 `module.finance.view` 或 `module.compliance.view` 的人,【从不挡关账】。只有关了账的月份冻得下来(`COMPLIANCE_PACK_MONTH_NOT_LOCKED`)。逐角色读数表在 `docs/handbacks/MES-8b-1.md`)|
| 车间大屏 · wall display (`/display`) | 看:只挂 `floor_display` 一个角色的账号(一块屏一个,由 admin 经 `/settings/accounts` 建 —— **本刀不建任何账号**);admin · cfo 也打得开 · viewed by a display account holding only `floor_display`; admin and cfo can open it too | 不批 · none | ✅ done(MES-8b-2,2026-10-17,`v1.4.58`,MES-0 Q83 · Q90 · MES-8 Step 0 Q19 · Q20 · Q29:**一个新角色 `floor_display`、一个新码 `data.view_floor_board`,没有新审批**。码授 **floor_display · admin**(每一个码都给 admin)**· cfo**(「CFO 读得到每一样东西」:每一个 `data.view_*` —— 本刀的决定,交回报告里写着);线上授权只多了这三行。大屏只读一支 `floor_board()`:加工 · 安全 · 库存 23 支提醒此刻各有几件 —— **只有数**,没有钱、没有名字、没有健康信息,也没有链接。★ **空闲登出的唯一豁免(Tim 2026-10-17 的 Q19,取代 IDLE-DRAFT「一个值不分角色」的【这一种】情形)**:会话的角色【恰好】是 `floor_display`、码【恰好】是 `data.view_floor_board` 时不被空闲登出;**账号多一个角色、或这个角色多一个码,豁免当场消失** —— 判据只有一份,在库里(`session_is_floor_display_only()`,由会话自己的 `auth.uid()` 求值),中间件只在一次请求【已经判成空闲过期】时问它,问不到就照今天的样子登出;别的每一个会话的空闲登出逐字不变。★ **这样一个会话只打得开 `/display`**:别的每一页给一句拒绝,出路指回 `/display`(根布局 + 六张不要码的页面;要码的页面按码本来就拒)。V28(刷新间隔与牌子)由持 `action.manage_permissions` 的人在大屏页底下给;没给时画全部牌子、不自动刷新。逐角色读数表在 `docs/handbacks/MES-8b-2.md`)|

## 12 · 主数据 · Master data

| 事项 · Action | 谁做 · Does | 谁批 · Approves | 状态 · Status |
|---|---|---|---|
| 批量导入 · bulk import | admin | — | ✅ done(cco / cto / finance 交出 `action.bulk_import`;导入不许带月薪)|
| 科目表、币种、公司银行资料、GST 登记、其余财务设置 · chart of accounts, currencies, company bank details, GST registration, other finance settings | **CFO 一个** · CFO only | — | ✅ done(ROLE-1 Batch 2a:`action.finance_settings`;`accounts` / `currencies` / `company_profile` 写权换码;`finance_settings` 列守卫 + `set_finance_settings`,锁期仍归财务;`company-assets` 桶的写上门)|

## 13 · 看得见什么 · Visibility

| 事项 · Action | 规则 · Rule | 状态 · Status |
|---|---|---|
| 仓库看采购价 · warehouse sees purchase prices | 看得见采购与供应商那一侧的价格,好开它的采购单;**看不见**销售价、工资或任何别的价格(Q9 画的线)| ✅ done(ROLE-1 Batch 4a,2026-09-25:新码 `data.view_purchase_prices` —— 采购单与采购行、质保金、付款条款、定价公式(按行:销售公式仍问 `view_prices`)与条款承诺、计价器、收货单价与改价历史、应付账龄;今天持 `data.view_prices` 的每一个角色一并拿到它,仓库只拿它。★ 仓库今天不持 `module.purchasing.view` / `pricing.view` / `finance.view`,所以它**实际多看见的只在收货那几屏**(单价、改价历史、化验改价的新旧价);采购单那几屏等 Batch 5 的开单码。~~★ 到岸成本经盘点那条例外它今天就读得到 —— 登记 `ROLE1B4A-LANDED-COST-STOCKTAKE-EXCEPTION`,Batch 3 修~~ ✅ **ROLE-1 Batch 3a 关掉**(2026-09-25,Q5):`inbound_batch_landed_unit_cost` 不再放行 `module.stocktakes.edit`;`batch_freight_base` 与 `batch_processing_cost_base` 先问 `data.view_prices`(不持的人读 NULL,收货页画「受限」);分摊改读 `_all`)|
| ~~系统管理员账号 · the admin account~~ | ~~**拿掉每一个业务码;只做系统管理。admin@ 从此读不到任何业务数据 —— Tim 的一切业务阅读与决定走 tim@**(Q8)~~ ★ **已不成立**:下一行(Tim 2026-09-23 撤回)与再下一行(常设裁定 2026-09-24:`admin` 持每一个码、拿到每一个新码)取代了它。划掉而不删 —— 一条撤回的规矩与一条从没写过的规矩,读起来一样(OVERTIME-1 按 Tim 2026-09-28 的要求划掉)| ~~✅ done~~ 已被取代 |
| ⚠ **系统管理员账号:Q8 已被 Tim 本人撤回 · the admin account: Q8 reversed by Tim himself**(2026-09-23 23:33:27 CST)| Tim 以 admin@ 登录,把 **全部 45 个码** 还给了 `admin` 角色(AP-RECON-0 以 `postgres` 读基表 `role_permissions` 复核:45 行,`created_at` 全是 23:33:27)。上一行的收窄**现已不成立**。Claude 建议撤回到只做系统管理,两条理由:① admin@ 与 tim@ 是同一个人,所以在 admin@ 上发起的申请不能在 tim@ 上批;② 一个被盗的 admin 密码现在带着每一项权力。**Tim 尚未裁定是否撤回 —— 角色保持现状,除非 Tim 自己提起,不再提** | 现状 · as is |
| ★ **admin 角色持【每一个】码 · the admin role holds every code**(Tim 常设裁定,2026-09-24,已关;★ **2026-10-09 Tim 裁定:连 `module.tasks.view_all` 也持 —— 没有例外**,MES-5b-3 落地:线上与引导都是 75 / 75,关掉 `MES5B1C-ADMIN-TASKS-VIEW-ALL-UNRULED`)| Tim 用 admin@ 做测试,所以 `admin` 角色**保留它全部的码,并拿到每一个新码**。**从 ROLE-1 Batch 2b 起,每一个新码都在【同一支迁移】里一并授给 `admin`** (幂等:`ON CONFLICT DO NOTHING`)。Batch 2b 因此把 Batch 2a 的三个码也补给了它(以 postgres 读基表 `role_permissions`:Batch 2b 之前 admin 一个都没有)。★ admin@ **不**持 `cfo` 角色(那一行 `revoked_at` = 2026-09-23 15:00:48),不改。~~★ 唯一例外,照直记:`module.tasks.view_all`(读别人的个人任务)admin 【从来没有】—— Tim 2026-09-23 23:33 还回去的 45 个码里就没有它;这条裁定说的是「保留 + 每一个新码」,所以 Batch 2b 没有替 Tim 加它。要不要加,是 Tim 的一句话~~ ★ **Tim 说了(2026-10-09):加。** admin 从 MES-5b-3 起读得到别人的个人任务 | ✅ done(Batch 2b 之后 admin 52 码 / 目录 53;MES-5b-3 之后 75 / 75)|
| CFO 读得到它要决定的东西 · the CFO can read what it decides | `module.hr.view` · `data.view_reviews` · `module.suppliers.view` · `module.customers.view` · `data.view_banking`;没有一个码让它开出它要批的单(Q3)| ✅ done |
| **CFO 读得到每一样东西 · the CFO reads everything**(Tim 2026-09-23,取代上一行的收窄)| **每一个 `module.*.view` 与 `data.view_*`,加 `module.tasks.view`**(只读;不带任何写码或决定码)。★ 取代 Q6「身份信息只归财务」在【读】这一侧(录入与改动仍只归财务),也取代「被删记录只授 admin 与 auditor」。★ `module.tasks.view` 让持有人【建、改自己的个人任务】—— APR-4 那条自己的任务的例外,不是读以外的业务权。`module.tasks.view_all`(读别人的个人任务)**不给** | ✅ done(PAY-REQ-1 Batch A;cfo 13 → 26 码)|

| **健康数据 · health details**(U1-A,Tim 的 UNBLOCK-1 Q8,2026-10-05)| 医疗报销的事由与金额、请假的事由 · 病假单号 · 例外理由只给持 **`data.view_health`** 的人(admin · hr · cco · cfo · finance = 决定 HR 申请的人)与**本人**。**cto · gm · warehouse 从此读不到别人的**(此前持 `module.hr.view` 的六个账号都读得到)。屏幕、API、审计记录与变更记录四处同一个判据;医疗额度(已用额 = 金额之和)同一道门。决定医疗报销的人不持它时,决定按名拒 `PERMISSION_DENIED\|data.view_health`。⚠ 一张已付的医疗报销生成的那张**费用单**在财务那一侧照旧读得到金额(常设裁定 1:持 `module.finance.view` 就看得见钱)—— 登记 `U1A-MEDICAL-EXPENSE-AMOUNT-ON-FINANCE-SIDE` —— ★ **U1-B 结案(Tim 的裁定):金额给财务保留;医疗报销的批准 / 驳回理由(在报销单上与审批留痕上)也收到 `data.view_health`(或本人),自批报表同一道判据** | ✅ done(U1-A,`v1.4.35`;U1-B,`v1.4.36`)|
| **工资的数 · pay figures**(U1-A,Tim 的 UNBLOCK-1 Q1 · Q9 · Q10,2026-10-05)| 工资分录(`source_type = 'payroll'` 的每一张:过账、发薪、公积金、扣款,以及它们的冲销)的**每一行金额**、工资期的五个合计、工资申请的快照与金额、审批留痕上工资申请那一行的金额,只给持 **`data.view_pay`** 的人(admin · cco · cfo · finance · hr)。**cto 与 gm 从此读到「受限」**(此前在分录页、工资期页与 API 上读得到一个人的实发工资)。分录行的**行摘要(员工编号 + 姓名)照常给**(Q3)。报表、余额与对账对每一个读者不变(试算表 · 关账预览 · 银行账面余额 · 科目明细合计 · 总账导出改成属主汇总)。★ **U1-B:工资分录的【冲销申请】的金额同一条规矩**(`journal_requests_masked` · 审批留痕 · 变更记录 · 函数返回值) | ✅ done(U1-A,`v1.4.35`;U1-B,`v1.4.36`)|
| **人事备注 · HR's notes**(U1-A,Q6 · Q7)| `employees.notes` 与 `separation_notes` 只给持 `module.hr.view` 的人 —— **被写的那个员工本人经屏幕与 API 都读不到**;个人数据导出照旧交给本人(Tim 的 PDPA 裁定,刻意的例外)| ✅ done(U1-A)|
| **还没结束的那一轮 KPI 分 · open-cycle KPI scores**(U1-A,Q5)| 本人只经 `my_kpi_entries` 读自己的 KPI(分数在关轮之后才有);`kpi_entries` 上的本人自读策略拿掉了 | ✅ done(U1-A)|
| **设备保养建议里的钱 · costs in the maintenance advice**(U1-A,Q13)| 维修花费、机器的记录成本与两者之比只给持 `module.finance.view` 的人;只持加工权限的人(warehouse)读得到记录与"够不够资本化"的建议,读不到钱 | ✅ done(U1-A)|

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
| `action.decide_hr_requests` | 决定请假与医疗申报 | finance · cfo · **cco**(Tim 2026-09-28 19:00:35 CST 以 admin@ 加上,有意为之)|
| `action.hr_reviews` | KPI 与绩效评估这一块;CFO 是提交人或主角时的批准 | cco |
| `action.anonymise_employee` | 员工匿名化 | admin |
| `module.hr.edit`(改义:不再含评估与 KPI)| 其余人事与薪资 | finance · **cco**(原文「cco 与 admin 已拿掉」;★ cco 由 Tim 2026-09-28 19:00:35 CST 以 admin@ 加回,有意为之)|
| `action.finance_settings` | 科目表、币种、公司资料(含银行资料与标志)、GST 登记与其余财务设置(锁期除外)(Batch 2a)| cfo |
| `action.customer_credit` | 客户信用限额与冻结(Batch 2a)| cfo |
| `action.supplier_approve` | 供应商批准、驳回、拉黑、恢复(拉黑后归档)(Batch 2a)| cfo |
| `action.supplier_review` | 记一次供应商评审(现算的计数 + 此刻的 V23 / V24 一起抄下;V23 没给读「Not graded」)、带理由更正一次评审、设 V23(权重 · 等级线 · 评审周期)与 V24(每个等级的预付上限 · 抽样级别);收到 `supplier_review_due` 提醒。声明的查看码 `module.suppliers.view`(MES-8a,MES-8 Step 0 Q6)| admin · cco |
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
| `action.batch_write_off` | 提注销申请(APR-7 起:还有料或挂着已签发证书的批次经 CFO;空批一步删)(Batch 3b · APR-7)| warehouse · admin |
| `action.wo_create` | 建工单;改 / 取消 / 关闭也认它(或 `module.processing.edit`)(Batch 3b)| warehouse · admin |
| `action.wo_release` | 下达工单;建单人永远不能下达(按人认)(Batch 3b)| finance · admin |
| `module.quality.view` | 质量:样品清单与样品页、化验争议清单与争议页、V16 的面板(读)(MES-6a-1,MES-0 Q90)| admin · cco · cfo · cto · finance · warehouse |
| `module.quality.edit` | 取样与记保管、立 / 记仲裁 / 撤回化验争议、挂仲裁费、设 V16(MES-6a-1,Q11 · Q12;结案另要 `action.apply_assay`);★ MES-6b-1 起也是【开】一张不合格报告的码(Q9)| admin · cco · cto |
| `action.ncr_decide` | 决定一张开着的不合格报告:接收 · 扣款接收(点名钱走的那张贷项通知申请 / 收货定价申请)· 返工 · 降级 · 拒收;除拒收外都放行那一批的质量暂扣。开单人永远不能决定自己开的那一张(按人认,`SELF_APPROVAL_FORBIDDEN`);系统因质量验收限越限开的那一张,任何持码人都能决定;声明的查看码 `module.quality.view`(MES-6b-1,Step 0 Q9)| admin · cco · cto |
| `action.issue_coa` | 签发一张分析证书(一批产出批,可选点名一张预留过或发过它的销售单);提作废申请(`coa_void`,CFO 二级审批);撤回自己那一类申请;收到 `coa_facts_changed` 提醒。桶 `coa-documents` 的上传与删除【还没被记下的】孤儿也认它。声明的查看码 `module.output.view` · `module.quality.view`(MES-6b-2,Step 0 Q30)| admin · cco |
| `action.processing_commit` | 提交加工(Batch 3b)| warehouse · admin |
| `action.processing_rollback` | 提回滚申请(APR-7 起经 CFO)(Batch 3b · APR-7)| warehouse · admin |
| `action.processing_aftercare` | 加工损耗分类与交接班(或 `module.processing.edit`);加工费用条目不在内(Batch 3b)| warehouse · admin |
| `action.request_shipping_release` | 提发货放行(与撤回任何一张在等的);批归 CFO,提单人永远不能批(APR-5b)| cco · admin |
| `action.ship_goods` | 发货(`ship_order`)与开具送货单(`record_shipment_issue`);发货队列 `/logistics/shipping`,不带价格(APR-5b)| warehouse · admin |
| `module.processing.view`(新增持有人)| 读加工模块;物料名只经 `material_lookup`,不拿 `module.materials.view`(Batch 3b,Q8)| + warehouse |
| `action.overtime_enter` | 按月录现场员工的加班:开批、加行 / 删行、交去批、撤回、丢弃、冲销批过的(OVERTIME-1)| finance · admin |
| `action.overtime_approve` | 整批批准或驳回现场员工的加班(驳回要备注);交的人与批里的人按人认不能批;审批开关不影响(OVERTIME-1)| warehouse · admin |
| `data.view_health` | 健康数据:医疗报销的事由与金额(及其额度、它生成的费用在报销页上的数)、请假单的事由 · 病假单号 · 例外理由;审批留痕上医疗报销那一行的金额;★ U1-B 起加上医疗报销的批准 / 驳回理由(`decision_notes` 与审批留痕的 `note`)。**每个人照旧看得见自己的**(U1-A,Tim 的 UNBLOCK-1 Q8,2026-10-05)| admin · hr · cco · cfo · finance(决定 HR 申请的人;**cto · gm · warehouse 不持** —— 他们从此读不到别人看病与请假的事由)|
| `data.view_change_log` | 变更记录 `/settings/change-history`:全系统每一次新增、修改、删除 —— 谁做的、改之前是什么;受遮蔽的值跟源屏幕问同一批数据码,别人的个人任务整行受限(HISTORY-1,Tim 的 Q10 · Q1)| cfo · admin(**只授这两个,不捆进任何别的角色**)|
| `action.manage_devices` | 采集层的写:登记 / 修改 / 停用设备与网关、发放与撤销网关钥匙(每把密钥只显示一次;停用网关连同它的钥匙一起撤)、收件箱里重试或带理由丢弃一行、改传输上限。**读**设备页、收件箱、传输日志与「待补的标准值」,以及按「Process received」处理收件箱,只要 `module.processing.view`(MES-1,2026-10-06,MES-1 Step 0 Q11)| cto · admin |
| `action.confirm_capture` | 采集的【确认】:确认一张草稿(改了读数要写理由,原值留着)或带理由驳回;手工录入一次称重;更正一次已确认的称重(新的一行指回原行);开 / 完成 / 作废地磅单;传、登记、撤下地磅单照片(私有桶 `capture-photos` 的上传策略问的就是这个码)。**读**确认队列与校准页只要 `module.processing.view`,地磅单页与照片只要 `module.inbound.view` 或 `module.logistics.view`(MES-2,2026-10-06,MES-2 Step 0 Q8 · Q21)| warehouse · cto · admin |
| `module.safety.view` | 安全:事故清单与事故页、V19 的面板、事故提醒两臂(通报 NEA · 书面报告)、批次与机器页上的「关联事故」、巡检清单与巡检页、发现、环境页、V18 / V20、巡检两支提醒(MES-7b-2)(MES-7b-1,Step 0 Q2)| 每一个持 `module.processing.view` 的角色:admin · auditor · cco · cfo · cto · finance · gm · operations · warehouse |
| `module.safety.edit` | 记事故与之后的事实、链 / 解批次、事故种类字典、设 / 确认 V19、巡检清单 · 巡检 · 发现 · 监测参数字典 · 监测结果(MES-7b-2)(MES-7b-1,Step 0 Q2;编辑隐含查看)| admin · cto · warehouse |
| `module.compliance.view` | 合规:合规包清单与包页、实时预览、PDF(看一眼 · 每一版存下的字节)、V26 / V27 的面板与两个待补的值、月结页的合规包那一行(MES-8b-1,MES-8 Step 0 Q17)| admin · auditor · cco · cfo · cto · gm |
| `action.compliance_pack` | 冻一个已关账月份的合规包(CPK-YYYY-MM)、带理由重出(-2 …)、存 PDF(私有桶 `compliance-documents`)、设 V26 / V27;收到 `compliance_pack_not_frozen` 提醒。声明的查看码 `module.compliance.view`(MES-8b-1,Step 0 Q17)| admin · cto |
| `data.view_floor_board` | 车间大屏 `/display`:读 `floor_board()`(加工 · 安全 · 库存 23 支提醒此刻各有几件,只有数)。★ 一个会话只经 `floor_display` 这一个角色持这一个码时:空闲不被登出、也只打得开 `/display`;多一个角色或多一个码,两样都没有了(MES-8b-2,MES-0 Q83 · Q90 · MES-8 Step 0 Q19 · Q20)| floor_display · admin · cfo |
