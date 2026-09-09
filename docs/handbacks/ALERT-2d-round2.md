# ALERT-2d 第二轮交回 —— 仪器修好了,44 处做完了,对话框不再继承排版

**日期:** 2026-09-09 · 不带版本号、不写发布说明 · **本刀一条 SQL 都没有**

---

## 1 · 起止与树的状态

| | |
|---|---|
| 开工前 `git status` | **干净**(零条) |
| 开工前 HEAD | `417afecdf131db1b2d981d841962172353358d07` |
| 开工前 `origin/main` | `417afecdf131db1b2d981d841962172353358d07` —— **相等** |
| 工作提交 | **`559da63`** —— 本刀全部改动都在这一次里 |
| 交回时 HEAD | 本行由紧随其后的一次【只改这两行】的订正提交写入 —— 自指的哈希写不进它自己(与 ALERT-2c 同一处理) |

委托书给的期望值 `417afec` **实测正确**。它和本文件里其他每一个数一样被量过。

---

## 2 · 先修仪器 —— 而它把范围从 39 抬到了 47

### 2.1 改了什么

`scripts/survey-conflated-booleans.mjs` 的 `flat()`(原 :523,委托书点的 :541 是紧跟其后的那句 filter)。

**原来是这样坏的:** `flat()` 把 `ParenthesizedExpression` **原样 push 出来**,
紧接着那句 filter 又把它**整个丢掉**。于是

```
canAssess={canWrite && (r.status === 'draft' || r.status === 'self_review')}
```

摊平之后只剩 **一个**操作数(`canWrite`),`parts.length >= 2` 不成立,
**整条链一次都没有进过 `chains`** —— 不是分错桶,是**结构上看不见**。
而那正是旗舰家族自己的形状。

**改法(R-Q1 的 (a)):先剥括号再判。**

```js
const flat = (n, acc = []) => {
    while (ts.isParenthesizedExpression(n)) n = n.expression
    if (ts.isBinaryExpression(n) && n.operatorToken.kind === OP) { flat(n.left, acc); flat(n.right, acc) }
    else acc.push(n)
    return acc
}
```

剥出来若还是同一个运算符就继续摊平;若是**另一个**(`&&` 里套 `||`),
把它整个当一个操作数交给 `catsOfNode` —— 它对链取类别**并集**,
这正是"一个操作数里裹着几类"该有的读法(桶 ① 与桶 ④ 的分界就卡在这上面)。
filter 里那句 `!ts.isParenthesizedExpression(x)` 一并删掉:它就是那条丢东西的判据本身。

### 2.2 四个数,以及三个【脚本自己的】退出码

**先复现基线**(动仪器之前,在这棵树上重跑 ALERT-2c 的那一跑):

| 桶 | ALERT-2c 报的 | 本刀实测(修补前) |
|---|---:|---:|
| ① 权限 × 记录状态 | 6 | **6** |
| ② 纯记录状态 | 31 | **31** |
| ③ 纯权限 | 2 | **2** |
| ④ 掺了第三种东西 | 33 | **33** |

**逐字相同,`BASE_OWN_EXIT=0`。** 分母也一样:磁盘 877 / 解析 877,布尔链 1554,闸位 256。

**修补之后:**

| 桶 | 数 | 相对修补前 |
|---|---:|---|
| ① 权限 × 记录状态 | **13** | +7 |
| ② 纯记录状态 | **36** | +5 |
| ③ 纯权限 | **2** | 0 |
| ④ 掺了第三种东西 | **34** | +1 |

布尔链 1554 → **1667**,落在闸位上的 256 → **277**。

**三个退出码,都是脚本自己写进日志的那一行**(`OWN_EXIT=$?` 紧跟命令,不从管道尾巴读):

| 跑法 | 脚本自己的退出码 | 咬到了吗 |
|---|:--:|---|
| 干净跑 | **`CLEAN_OWN_EXIT=0`** | ✓ 覆盖率断言通过 |
| `--inject=blind-parser` | **`INJECT_PARSER_OWN_EXIT=1`** | ✓ 「类型检查器一个 boolean 都没认出来」+「AST 一个权限文件都没命中」 |
| `--inject=blind-taint` | **`INJECT_TAINT_OWN_EXIT=1`** | ✓ 「污点传播一个权限绑定都没找到 —— 种子瞎了」 |

### 2.3 范围到底是不是 44 —— **是**

**桶 ① 13 + 桶 ④ 34 = 47。**
其中委托书点名的三处假阳性(`WorkOrderActions.tsx:41 / :42 / :43`)**不是要转换的东西**,
它们是要照抄的样板。

> **47 − 3 = 44。与委托书逐字相符。**

新出现的 8 处(旗舰家族 5 处真的 + 3 处假阳性),与闸轮报的「五处真的、三处具名假阳性」逐条对上:

| # | 站点 | 进哪个桶 | 真的? |
|---|---|---|---|
| 1 | `app/hr/reviews/ReviewActions.tsx:64` | ① | ✔ |
| 2 | `app/hr/reviews/[id]/page.tsx:184` | ① | ✔ |
| 3 | `app/hr/reviews/[id]/page.tsx:185` | ① | ✔ |
| 4 | `app/hr/reviews/[id]/page.tsx:195` | ① | ✔ |
| 5 | `app/inbound/[id]/edit/SourceReasonPanel.tsx:62` | ④ | ✔ |
| 6–8 | `app/operation/orders/[id]/WorkOrderActions.tsx:41,42,43` | ① | **假阳性,见 §8** |

### 2.4 收工时的四个数(同一支仪器,同一份判据)

| 桶 | 开工 | 收工 |
|---|---:|---:|
| ① | 13 | **3**(全部是 WorkOrderActions 那三处假阳性) |
| ② | 36 | **43** |
| ③ | 2 | **1** |
| ④ | 34 | **4** |

`FINAL_CLEAN_OWN_EXIT=0`,两格注入仍然 **1 / 1**(收工后重跑过,没有靠开工那次的记忆)。

★ **② 从 36 涨到 43、③ 从 2 掉到 1,是【拆开】本身的直接后果**,不是漏抓:
一条 `perm && state` 拆成「闸 + 一条纯状态的布尔」之后,那条纯状态的自然落进 ②。
③ 少一个是因为 `hr/reviews/[id]/page.tsx:84` 的 `canWrite = canHrEdit || isReviewer`
**现在才第一次被看见**(它此前被那条括号判据吞掉了),而它正正是 ③ 该有的形状 ——
两个权限取或,`PermissionGate` 的 `alsoAllowedIf` 就是为它装的。

---

## 3 · 桶 ① —— 十处,逐处

**共同的改法:权限那一半变成一道闸(看得见、按不动、点名权限码、说出管理员在
Settings → Roles 里给);记录状态那一半保留它自己那句话,说清【这条记录】怎么了。**

★ **我自己定的一条判据,先说在前面(它管着下面每一处):【先问记录状态,再问权限】。**
一份已经批准/作废/转单的记录,对**任何人**都改不动;那时再叠一句"你还需要某项权限"
是一句**正确而无用**的话。所以:状态不许时只说状态;**状态许了,缺的才真的只剩权限。**

| # | 站点 | 那条布尔 | 现在做什么 |
|---|---|---|---|
| 1 | `finance/assets/[id]/DowntimePanel.tsx:113` | `canEdit && !openRow` | `!openRow` → 上闸的「记一段停机」钮;`openRow` 存在 → **就地**说「一次只能有一段没结束的停机」(`equipment.down.oneOpenOnly`,一个字没新写)。此前那句话被一层 `PermissionGate` 罩着,**没有权限的人两句都读不到** |
| 2 | `hr/reviews/ReviewActions.tsx:64` | `canWrite && (draft \|\| self_review)` | 状态不许 → `reviews.stateFlowLocked`(点名当前状态);状态许 → `<PermissionGate code="module.hr.edit" alsoAllowedIf={评估人}>` 包住「开启自评 / 提交」两个钮 |
| 3 | `hr/reviews/ReviewActions.tsx:109` | `canHrEdit && status !== 'void'` | 已作废 → `reviews.stateAlreadyVoid`;否则 → `<PermissionGate code="module.hr.edit">` 包住作废表单。**这一处刻意【不带】alsoAllowedIf** —— 作废真的只有 `module.hr.edit` 一条路,评估人开不了它;写一条不存在的第二条路,与写错原因是同一种坏 |
| 4 | `hr/reviews/[id]/page.tsx:183` | `canWrite && status==='draft'` | → `canEditGoals={stateGoals}`,权限交给外层闸 |
| 5 | 同上 `:184` | `canWrite && (draft\|\|self_review)` | → `canAssess={stateAssess}` |
| 6 | 同上 `:185` | `canWrite && (draft\|\|submitted)` | → `canSetActual={stateActual}` |
| 7 | 同上 `:195` | `canWrite && (draft\|\|self_review)` | → `ConclusionForm editable={stateConclusion}` + `stateNote` |
| 8 | `operation/orders/[id]/page.tsx:101` | `canEdit && ['draft','released'].includes(status)` | 状态不许 → 原来那句 `amendTerminal`(**一个字没改**);状态许 → `<PermissionGate code="module.processing.edit">` 包住 `AmendLinesControl`。**顺带修掉一个藏**:此前 `!editable` 时「改计划」那个钮整个被换成一行字 |
| 9 | `sales/quotes/[id]/page.tsx:81` | `canEdit && !isConverted && !isDeclined` | 见 §3.2 |
| 10 | 同上 `:195` | 同一条表达式**第二遍** | 见 §3.1 |

### 3.1 那条写了两遍的表达式 —— 怎么解决的,以及它本身就藏着一个真缺陷

`canEdit && !isConverted && !isDeclined` 在 `/sales/quotes/[id]` 出现过**两次**:
`:81` 的 `editable` 与 `:195` 的 `canIssue={…}`,逐字相同。

**而两份实现已经开始分开了,这是量出来的:**

| | `QuoteLinesEditor` 的 `reason` | `IssuePanel` 的 `blockedReason` |
|---|---|---|
| 转过了 | ✔ `linesLockedConverted` | ✔ `issueBlockedConverted` |
| 谢绝了 | ✔ `linesLockedDeclined` | ✔ `issueBlockedDeclined` |
| **没有 `module.sales.edit`** | ✔ `受限 — quotes.needsSalesEdit` | **✗ 什么都没有** |

也就是说,**一个没有销售编辑权限的人打开报价页,签发钮按不下去、旁边一片空白。**
☞ 所以"解决重复"这件事本身就修掉了一个真缺陷,不只是少写一行。

**解决法:记录状态那一半只算一次,权限那一半只写一次,两个消费者共用。**

```ts
const stateAllowsEdit = !isConverted && !isDeclined   // 记录状态,唯一一份
const editable = canEdit && stateAllowsEdit           // 不再写第二遍
```

`:195` 改成 `canIssue={stateAllowsEdit}` + 新的 `permission={{ code:'module.sales.edit', allowed:canEdit }}`。

### 3.2 `:81` 屏幕上那句话变了吗 —— **变了,而且是往好里变;记录状态那两句一个字没动**

委托书要求「别把它弄丢;若你的拆法说得比今天差,就保留今天的措辞并说明」。逐条对:

* **记录状态那两句(转过了 / 谢绝了)一个字都没改**,原样传给 `QuoteLinesEditor`。
* **权限那一句换掉了**,从
  `受限 — 编辑报价需要 module.sales.edit。`
  换成 `<PermissionGate>` 那一套:药丸上写 **`需要权限 module.sales.edit`**,
  title 里是 `common.actionMessage.permissionDenied` 的整句 ——
  它比今天多说了两件事:**记录一个字都没有改**,以及**管理员在「设置 → 角色」里勾这一项**。
  ☞ 这不是"说得比今天差",是严格更多。**而且它与按下去被拒之后 SILENT-1 说的是同一句话**,
    人能把两次遭遇认成同一件事。
* **另外修掉一个藏(这是可见变化,单独说):** 此前没有 `module.sales.edit` 的人看到的是
  **一张干净的只读表** —— 增行、改价、删行三个控件整个不存在。现在它们**画出来、按不动**。
  DBLOCK-1 的裁定原话:**藏起来的钮教人"这个功能不存在",看得见的钮教人"该去要什么"。**

### 3.3 扩展后的 `PermissionGate`,对考核这一族读起来是什么样

**新 prop:`alsoAllowedIf?: { label: string; why: string }`。**(R-Q3 的 (i))

为什么需要它,一句话:`canWrite = canHrEdit || isReviewer` 是**两种不同的授权**取或 ——
一边是管理员勾得出来的码,一边是**"这份考核点名的评估人是不是你"**,一次关系授权。
对一个被挡住的读者,**更可能为真的是后者,而没有任何管理员给得了它**。
只说 `module.hr.edit`,就是把人支去要一样**要来了也未必管用**的东西 ——
`DBLOCK-CONFLATED-BOOLEANS` 自己的原话:**说错原因比不说原因更坏。**

屏幕上(英文):

> **[开启自评] [提交]**  ← 都画着,都按不动
> 🏷 `Needs module.hr.edit — or: you are the reviewer named on this appraisal`
> (悬停 / 无障碍读出:`common.actionMessage.permissionDenied` 整句 + 换行 + 上面那句 `orReviewerWhy`)

中文:

> 🏷 `需要权限 module.hr.edit，或者：你是这份考核指定的评估人`

**它是一条【能力】,不是给考核写的一个组件。** 下一块关系授权的屏(任务参与人、
我的考核、谁被指派到这一行)只要给出两句话就能用,不需要它知道"关系授权"这四个字。
药丸自己是 `whitespace-nowrap`(单句时对),带上第二条路之后**明确放开换行** ——
否则两句话在手机上会横着溢出去。

---

## 4 · 桶 ④ —— 三族,三副药,逐处

### (a)「表单还没展开」—— 药:**闸装在【打开它的那个钮】上,`open`/`editing` 照旧管开合**

**为什么是这一副:** `open` / `editing` / `form === null` 是**这一次会话的开合位**,
不是一句拒绝。真正的缺陷在另一头 —— `canEdit` 为假时**整个控件不渲染**,而 DBLOCK-1 已裁定"显示 + 解释"。

★ **而这一族有一条边界,我逐处查过:面板里若有【取消】钮,面板自己【不能】再套一层闸** ——
`fieldset disabled` 会把取消一起禁掉,人就被关在一个既提交不了、也关不掉的表单里
(DBLOCK-1 当场在 `CloseReopenControls` / `MaintenancePanel` / `VoidInvoiceControl` 三处踩到过)。
而它也**不需要**:`open` 只能由那个已经上了闸的钮翻起来 —— 这一条我**逐个文件查过 setter**,
没有第二个入口(`ContactsPanel` 的行内「编辑」与 `LicencePanel` 的 `openEdit` 都已经在闸里)。

| 站点 | 布尔 | 现在 |
|---|---|---|
| `finance/assets/[id]/DowntimePanel.tsx:176` | `open && canEdit && !openRow` | `open && !openRow`;闸在触发钮上 |
| `finance/assets/[id]/MaintenancePanel.tsx:240` | `open && canEdit` | `open`;闸已在触发钮上(本来就有) |
| `finance/assets/[id]/ServiceIntervalPanel.tsx:312` | `editing && canEdit` | `editing`;同上 |
| `finance/cash-forecast/RecurringLines.tsx:67 / :72` | `canEdit && !open` / `canEdit && open` | `!open` 里的钮上闸(`module.finance.edit`);`open` 那块只留开合 |
| `sales/customers/ChasePanel.tsx:136 / :142` | 同形 | 同上(`module.finance.edit`) |
| `sales/customers/ContactsPanel.tsx:138 / :144` | 同形 | 同上(用本来就传进来的 `permissionCode`) |
| `purchasing/licences/LicencePanel.tsx:114` | `canEdit && form === null` | `form === null` 里的钮上闸(`module.suppliers.edit`) |
| `hr/reviews/GoalsEditor.tsx:150,161,173,185,200` | `on && canEditGoals` 等 | **由桶 ① 的拆分顺手解决**:那三个 prop 现在只装记录状态,`on` 只装开合位,一个操作数里再没有第二类东西 |

### (b)「瞬态混进权限」—— 药:**瞬态留在 `disabled` 里,权限上闸**

**为什么是这一副:** `isPending` 一秒后自己消失,"没有权限"不会。CMP-2 的房规只要求
**非瞬态**条件配一行常驻的解释;把瞬态也拆出去写一句拒绝,是为一个**会自己好**的状态道歉。

| 站点 | 布尔 | 现在 |
|---|---|---|
| `finance/assets/AssetActions.tsx:82` | `pending \|\| !canEdit` | 「记一个计划投用日」那个钮上闸(`module.finance.edit`),`disabled={pending}`。★ **同屏另外两个钮不动** —— 它们的 `commissionWhy`/`disposeWhy` 已经按【先权限、再终态、再业务前提】逐支给出了不同的话 |
| `materials/[id]/edit/RequiredMetalsPanel.tsx:84` | `!canEdit \|\| isPending` | 整张表单进 `<PermissionGate code="module.materials.edit">`(它没有取消钮),勾选框 `disabled={isPending}`。**顺带修掉一个藏**:提交钮此前在 `!canEdit` 时整个不画,旁边的注释还引着 AGENTS.md 那句已被 DBLOCK-1 推翻的话 |
| `hr/claims/[id]/ClaimControls.tsx:69` | `pending \|\| !canFinance \|\| !date` | 三样三处:`pending` 留在 disabled(钮上写「保存中…」);`canFinance` 上闸;**`!date` 得到一句新话**(见 §7)。原来那句 `claims.needsFinance` **留着** —— 它说的是【流程】(HR 审、财务转应付,两步两人),与闸上那句【缺哪个码、去找谁】不是一件事 |
| `hr/kpi/score/GenerateMissing.tsx:53` | `disabled \|\| busy===p.employeeId` | 由旗舰那一处的三分解决:页面现在传的 `disabled` **只装记录状态**(月份锁没锁 / 周期关没关),权限由外层闸挡 |
| `components/IssuePanel.tsx:101` | `isPending \|\| blocked` | 见下面 (c) —— 同一个组件一起改的 |
| `purchasing/orders/[id]/RetentionPanel.tsx:161` | `retention_state==='awaiting_confirmation' && canEdit` | **改了分类,见 §5**;按桶 ① 的药做 |

### (c)「还没选 / 还没有东西可操作」—— 药:**空态或一句陈述,不是一句拒绝**

**为什么是这一副:** 给"还没选月份""还没有行""还没填日期"写一句权限的话或一句状态的话,
**两句都是假话** —— 它要的根本不是一句拒绝。

| 站点 | 现在 |
|---|---|
| **`hr/kpi/score/page.tsx:148`(旗舰)** | 见 §4.1 |
| `components/IssuePanel.tsx:63` | 新 prop `nothingToIssueNote`:`!hasLines` 那一句从**琥珀色的拒绝格**搬到**中性灰的陈述格**。三个调用点(报价 / 发货单 / 发票)的句子**一个字都没改**,只是换了格 —— 它们本来就是「先加一行」这种话,被摆在了"你不可以"的颜色里 |
| `components/IssuePanel.tsx:101` | 新 prop `permission`,签发钮走 `<PermissionGate>`。★ **`blocked` 里【不再】叠 `!permission.allowed`** —— `fieldset disabled` 已经禁掉它了,再写一遍就是同一件事两份实现 |
| `finance/invoices/[id]/page.tsx:204` | 见 §4.2 |
| `hr/reviews/ReviewActions.tsx:85` | `status==='submitted' && canHrEdit && !isSubmitter` 三类三处:状态留条件、`canHrEdit` 上闸、`!isSubmitter` 那句四眼原则**本来就在**。★ 但它原先写着 `canHrEdit && isSubmitter`,于是**一个没有 HR 权限的提交人三句话一句都读不到** —— 去掉那个多余的条件 |
| `hr/reviews/HrDecisionForm.tsx:62` | 见 §4.3 |
| `inbound/[id]/assays/[assayId]/page.tsx:340` | `canSeeJournal && priceChange.journalId`。权限那一半上面本来就有一枚具名的「受限」药丸(而且它的 `why` 逐字写着"这不是一次没过账的改价");缺的是另一半 —— `journalId` 为空时**整行消失**,于是"你看不到"和"根本没有"长得一模一样。现在它自己说出来(`assay.noJournalEntry`) |
| `inbound/[id]/edit/SourceReasonPanel.tsx:62 & :117` | 见 §4.4 |
| `sales/customers/StatementPanel.tsx:150` | `canIssue && preview?.ties`。对不上账那一句(带差额)**本来就在**;`canIssue` 为假时整块签发表单消失 —— 现在它走 `<PermissionGate code="module.finance.edit">` |
| `tools/tasks/[id]/Participants.tsx:112` | 见 §4.5 |
| `tools/reminders/page.tsx:188 / :335` | 见 §8(这一页**本来就对**,只差一个臂) |
| `tools/tasks/[id]/page.tsx:98` | 见 §8(假阳性) |

### 4.1 旗舰:`hr/kpi/score/page.tsx:148` —— **它的第二个操作数是【死的】**

```ts
const canEdit = mayScore && !!chosen && !locked && chosen.status !== 'closed'
//              权限        还没选月份   记录状态(两条)
```

**量出来的事实(不是推的):`canEdit` 的两个消费者(`GenerateMissing` / `ScoreEditor`)
都住在下面那个 `{chosen && (…)}` 里面。** 走到它们的时候 `chosen` 必然非空 ——
**这个操作数从来没有独立生效过**,它只是让整条布尔再也说不清自己为什么是假。

而它的**意思**早就画对了:同一页 `{!chosen && …}` 那块蓝色的 `kpi.noMonthChosen`
正是委托书要的那个空态。**所以这里一句新话都没写** —— 三分之后:

| 原因 | 屏幕上 | 新的? |
|---|---|---|
| 还没选月份 | 蓝框 `kpi.noMonthChosen` | 否,本来就在 |
| 月份锁了 / 周期关了 | `kpi.lockedNotice` / `kpi.closedNotice` | 否,本来就在 |
| 没有 `module.hr.edit` | `kpi.readOnlyNotice` **+ 控件上的 `<PermissionGate>`** | 闸是新的(它多说了哪个码、管理员在哪儿给) |

`ScoreEditor` 与 `GenerateMissing` 各自被闸包住,`canEdit`/`disabled` 只剩记录状态。
表格里的【取消】只在按过「编辑」之后才画,而「编辑」就在那层 fieldset 里 —— 不触边界。

### 4.2 `finance/invoices/[id]/page.tsx:204` —— **DBLOCK-1 的正面反例**

`pdfBlocked = profileIncomplete || fontProblems.length > 0 || !showBanking`
—— **一个瞬态都没有**,三件事完全不同:

* `profileIncomplete` —— 公司抬头还没填,一个**还没做的准备**;
* `fontProblems` —— **系统自己印不出这几个字**。这句话的意思是「机器做不到」,
  既不是"你不可以",也不是"这张单子状态不对";
* `!showBanking` —— 一个货真价实的权限答复(`data.view_banking`)。

**而三者此前共用同一个后果:预览与下载两个钮整个不画。**
页面下方那三段横幅本来就各说各的 —— **缺的从来不是话,是那个控件。**

**现在:两个钮永远画。** 挡住时画的是**真的 `<button disabled>`,不是 `<a>`** ——
`fieldset disabled` **禁不掉链接**(AGENTS.md 那条边界的原话),
所以不能只把原来的 `asChild + <a>` 包起来了事。权限那一支再套一层 `<PermissionGate>`。
旁边一个原因一句话:权限那句 `pdfNeedsBanking` **留着**(它说的是「为什么这张纸需要银行权限」),
另外两句是新的(见 §7)。

★ **这一条布尔本身仍然是三者取或,而那是【必须的】** —— 三种情形下都不能画一条活链接。
但它的三个原因现在各有各的话,控件也在屏幕上。委托书 R-Q4 要的正是这个:
「**什么是缺的:那个 CONTROL,shown and unpressable。Keep those three sentences.**」

### 4.3 `hr/reviews/HrDecisionForm.tsx:62` —— DBLOCK-1 裁定的最坏那一种

`if (!showProbation && !canPay) return null` ——
一个只做年度考核、又没有看薪权限的 HR,**连"这里本来有一块 HR 的决定"都读不到**。

现在面板恒画:
* 试用期结论那一格 —— 只有 probation 型考核才有。这是记录状态,年度考核里它**本来就不存在**,不是被挡住,所以**不给它一句拒绝**;
* 薪酬那两格 —— 走 `<PermissionGate code="data.view_pay">`,而**值画成「受限」药丸,不是空白**。
  **空白读作「没定过工资」,受限读作「你看不到」** —— `lib/permissions.ts` 整个存在的理由就是这一句。

### 4.4 `SourceReasonPanel:62 / :117` —— **一个操作数里三类东西**

`showForm = canEdit && (state === 'unexplained' || editing)` —— 权限 × 记录状态 × 开合位,
而 `showForm` 又被 `:117` 当成一个操作数用。拆成:

```ts
const formOpen = state === 'unexplained' || editing   // 记录状态 + 开合位:它们回答同一个问题
```

权限那一半交给闸。**于是没有 `module.inbound.edit` 的人,在一张【未说明】的收货上
看得见那张表单、按不动、并读得到该去要哪个码** —— 此前他看到的是一个琥珀框和一片空白,
而那张收货正等着有人来补答案。(这张表单只有保存、没有取消,不触边界。)

### 4.5 `Participants.tsx:112` —— 那段注释写着「三种状态,三句话」,**实测是四种**

三个操作数三类东西:`canEdit`(页面传的是 `iAmParticipant`,一次**关系授权**)、
`mayAssign`(权限)、可选名单为空(还没有人可选)。后两句本来就在,
**而三行每一行都以 `canEdit &&` 开头** —— 于是一个不在这张任务上的人看到的是**一片空白**。

改成一条四选一,永远命中一句。★ 第四句**刻意不写成"去要某个权限码"**:
在不在这张任务上,**管理员给不了**。它说的是「让已经在上面的人把你加进来」。

---

## 5 · 我做的每一次重新分类(R-Q4)

委托书给了两条,我又量出三条。**分类决定用哪一副药,所以错的分类就是错的药。**

| # | 站点 | 从 | 到 | 为什么 |
|---|---|---|---|---|
| 1 | `components/IssuePanel.tsx:63` | ④(b) 瞬态 | **④(c) 还没有东西可操作** | 委托书给的。`!canIssue \|\| !hasLines` 里一个瞬态都没有 |
| 2 | `finance/invoices/[id]/page.tsx:204` | ④(b) | **自成一格** | 委托书给的。三个操作数无一瞬态;`fontProblems` 说的是【系统坏了】 |
| 3 | `purchasing/orders/[id]/RetentionPanel.tsx:161` | ④ | **①(权限 × 记录状态)** | `retention_state === 'awaiting_confirmation'` 是**一条不折不扣的记录状态**。判据那条 `\bstate\b` 卡不住 `retention_state`(`state` 前面是下划线,不是词边界),于是它被判成 OTHER |
| 4 | `hr/reviews/HrDecisionForm.tsx:62` | ④ | **①【在种类上】** | `showProbation = reviewType === 'probation'` 是记录属性,不是第三种东西(`reviewType` 同样不在 `STATE_FIELD` 名单里)。药仍按委托书 §3.3(c) 点名的那一副做(它是一个 HIDE),但**它为假的两个原因是权限与记录状态,不是三类** |
| 5 | `tools/tasks/[id]/page.tsx:98` | ④ | **假阳性** | `!!myEmployeeId && p.employee_id === myEmployeeId && !p.removed_at` 三个操作数**回答的是同一个问题**(「我此刻在不在这张任务上」),不是三个不同的拒绝理由。它是一个派生事实,不是一道闸 |

★ 第 3、4 条是**同一个根**:`STATE_FIELD` 那条正则要求词边界,而 `retention_state` / `reviewType`
两个真的记录状态字段都过不了它。**这是仪器的一个已知窄处,报出来,本刀没有改它**
—— 在一次刚被它绊倒的切次里现改判据,正是本仓库记过的"匆忙的检查者"形状。

---

## 6 · 对话框那一处修好了 —— 而**五个调用点都没有被走过**

### 改了什么

`app/components/ui/confirm-dialog.tsx` 的**面板** div,加五个 class:

```
whitespace-normal  text-left  normal-case  not-italic  tracking-normal
```

对应五个**可继承**属性:`white-space` / `text-align` / `text-transform` / `font-style` / `letter-spacing`。

**机制(诊断,不是猜想):** 本对话框**就地渲染、不走 portal**(CONFIRM-1 的刻意决定,
焦点归还与"动作跑在同一次用户手势里"两条保证都挂在上面),所以它在 DOM 里是
**触发它的那个元素的后代**;而 `position: fixed` **不打断继承** —— 继承走 DOM 树,不走布局树。

### 记在哪儿

`docs/base-components.md` §十一,新的一小节
**「★★【对话框不继承文字排版 —— 它是它自己的说话面】★★」**,
就在 `check-confirm-subject.mjs` 那一节之前。里面写了:五个 class 是承重的、机制、
Tim 的那句规矩、以及**闸上被否掉的两条路**(剥 `<td>` 的 class / 搬进 portal)——
免得下一个人重提。**一条只留在提交里的规矩活不下来。**

### 五个调用点 —— **按代码确认,不是走出来的**

| # | 站点 | 承载它的元素 |
|---|---|---|
| 1 | `sales/quotes/[id]/QuoteLinesEditor.tsx:123` | `<td … whitespace-nowrap>`(:108) |
| 2 | `hr/reviews/GoalsEditor.tsx:256` | `<td … whitespace-nowrap>`(:211) |
| 3 | `materials/[id]/edit/AttachmentsPanel.tsx:196` | `<td … whitespace-nowrap>`(:183) |
| 4 | `sales/customers/[id]/edit/AttachmentsPanel.tsx:203` | `<td … whitespace-nowrap>`(:190) |
| 5 | `suppliers/[id]/edit/AttachmentsPanel.tsx:203` | `<td … whitespace-nowrap>`(:190) |

`app/output/[id]/edit/SafetyStatePanel.tsx:89` 那一处**今天就是对的**(附近没有任何可继承的
文字属性),**重置对它是一次空操作**,所以它继续是对的。

> ### ★★ 可以说的与不可以说的
>
> **可以说的:** 五处都在 `whitespace-nowrap` 的 `<td>` 里(逐处读过源码);
> 重置落在面板本身;`npm run build` 自己的退出码 **0**;
> `scripts/check-confirm-subject.mjs` 随构建跑过,绿。
>
> **不可以说的:** 它们**被打开过、被看过**。**没有。**
> 照委托书 §4,本刀不装浏览器、不装任何自动化。**这五下欠你。**

---

## 7 · 每一句新的 / 改过的用户可见文字 —— 逐字,双语,按屏分组

**十一对新键,一对删掉。全部走 i18n,没有一处硬编码。**
每一条都只在 `messages/*.ts` 里出现一次 —— **你要改措辞,代价就是改这一行,别的什么都不用动。**

### 7.1 全站共用 —— `common.permissionGate`

| 键 | en | zh |
|---|---|---|
| `common.permissionGate.or` | `' — or: '` | `'，或者：'` |

(接在权限码后面,把「或者你是这份考核指定的评估人」引出来。**它不是第二条拒绝**,
是同一个条件的另一条路。)

### 7.2 绩效考核 —— `/hr/reviews/[id]` 与 `/my-reviews/[id]`

| 键 | en | zh |
|---|---|---|
| `reviews.gate.orReviewer` | `you are the reviewer named on this appraisal` | `你是这份考核指定的评估人` |
| `reviews.gate.orReviewerWhy` | `There is a second way in: this appraisal names a reviewer, and that person can edit it without the permission above. Being that reviewer is not something an administrator can grant — it is written on the appraisal itself, in the Reviewer field. If it should be you, ask HR to set you as the reviewer on this appraisal.` | `还有第二条路:这份考核点名了一位评估人,那个人不需要上面那项权限也改得动它。【是不是那位评估人,管理员给不了】—— 它写在这份考核自己的「评估人」那一栏里。如果那个人应该是你,请让 HR 把这份考核的评估人改成你。` |
| `reviews.stateGoalsLocked` | `Goals can be added, changed or removed only while this appraisal is a draft. It is “{0}” now.` | `目标只有在这份考核【还是草稿】的时候才能增删改。它现在是「{0}」。` |
| `reviews.stateConclusionLocked` | `The rating and the written conclusion can be changed only while this appraisal is a draft or in self-review. It is “{0}” now.` | `评级与书面结论只有在这份考核【是草稿或自评中】的时候才能改。它现在是「{0}」。` |
| `reviews.stateFlowLocked` | `Self-assessment can be opened, and the appraisal submitted, only while it is a draft or in self-review. It is “{0}” now.` | `只有在这份考核【是草稿或自评中】的时候,才能开启自评、提交考核。它现在是「{0}」。` |
| `reviews.stateAlreadyVoid` | `This appraisal has already been voided, so there is nothing left to void.` | `这份考核已经作废了,没有什么可以再作废的。` |

`{0}` 是**翻译过的状态名**(`reviews.status_<code>`),不是原始 code。

### 7.3 医疗报销 —— `/hr/claims/[id]`

| 键 | en | zh |
|---|---|---|
| `claims.needExpenseDate` | `Enter the expense date first. It decides the posting period and the exchange rate, so the system will not fill in a date for you.` | `先填费用日期。它决定这笔账落在哪个期间、按哪一天的汇率折算,所以系统不会替你补一个。` |

### 7.4 发票 —— `/finance/invoices/[id]`

| 键 | en | zh |
|---|---|---|
| `invoice.pdfBlockedFont` | `The PDF cannot be built: some characters on this invoice cannot be rendered, so the file would come out with blanks where they should be. They are listed below.` | `PDF 生成不出来:这张发票上有几个字印不出来,硬生成的话那几处会是空白。是哪几个字列在下面。` |
| `invoice.pdfBlockedProfile` | `The PDF cannot be built until the company details are filled in — Finance → Company.` | `PDF 要等公司抬头填好之后才生成得出来 —— 去「财务 → 公司信息」。` |

### 7.5 化验单的改价 —— `/inbound/[id]/assays/[assayId]`

| 键 | en | zh |
|---|---|---|
| `assay.noJournalEntry` | `No journal entry — this price change did not post one.` | `没有分录 —— 这次改价没有过账。` |

### 7.6 任务参与人 —— `/tools/tasks/[id]`

| 键 | en | zh |
|---|---|---|
| `tasks.participants.notOnTask` | `You are not on this task, so you cannot change who else is. Ask someone already on it to add you — this is not a permission an administrator can grant.` | `你不在这张任务上,所以改不了参与人。请让已经在上面的人把你加进来 —— 这一条不是管理员能给的权限。` |

### 7.7 删掉的一条(本刀自己造成的孤儿)

| 键 | 原文 |
|---|---|
| `materials.assayPolicy.needsEdit` | en `Changing the assay requirement needs module.materials.edit.` / zh `修改化验要求需要 module.materials.edit 权限。` |

那句话现在由 `<PermissionGate>` 说(而且多说了「管理员在哪儿给」)。
**留着它就是又一条没人渲染的死词条** —— ALERT-2c 刚为这个形状删过六条。

### 7.8 **搬了位置、一个字没改**的句子(说明白,免得被当成新写的)

* `quotes.issueBlockedNoLines` / `sales.shipDetail.issueBlockedNoLines` / `invoice.issueBlockedNoLines`
  —— 从 `blockedReason`(琥珀色的拒绝格)搬到 `nothingToIssueNote`(中性灰的陈述格)。
  它们本来就是「先加至少一行」这种话,只是被摆在了"你不可以"的颜色里。
* `equipment.down.oneOpenOnly` —— 从琥珀块里(被一层闸罩着)搬到「记一段停机」钮旁边。
* `processing.wo.blocked.amendTerminal` / `quotes.linesLocked*` / `quotes.issueBlocked*` / `claims.needsFinance` / `invoice.pdfNeedsBanking` —— **原位、原字**。

---

## 8 · 那三处假阳性 —— **它们是要照抄的样板,不是要转换的东西**

### 8.1 `app/operation/orders/[id]/WorkOrderActions.tsx:41 / :42 / :43`

```ts
const noPerm     = !canEdit ? `${t('common.restricted')} — ${t('processing.wo.needsEdit')}` : ''
const releaseWhy = noPerm || (status !== 'draft'    ? t('…releaseNotDraft',    { status }) : '')
const closeWhy   = noPerm || (status !== 'released' ? t('…closeNotReleased',  { status }) : '')
const cancelWhy  = noPerm || (!['draft','released'].includes(status)
                     ? t('…cancelTerminal', { status })
                     : hasRuns ? t('…cancelHasRuns') : '')
```

**普查看见 `PERM || STATE` 就报,而这里的 `||` 根本不是一道闸 —— 它是一次【取第一个非空的句子】。**
这个文件**逐个动作、逐条分支算出一句不同的话**,说清为什么这个动作现在做不了:
缺权限 / 状态不对(还点名当前状态)/ 底下挂着加工单。

> ### ★ 这正是本刀在别处装的那个答案,而它在这里【已经写好了】。
> 抄它的时候抄这三件事:
> 1. **能不能做,与为什么不能,一起算出来** —— 免得有一个分支只画了禁用、没画理由;
> 2. **顺序是【先权限、再终态、再业务前提】** —— 第一个为真的就是那句话;
> 3. **钮永远画出来**,禁用 + 旁边一句 —— 它比本刀新装的闸早,而且方向一致。

它的抬头注释还写着「永远不把注定失败的按钮画出来」,那句话已被 DBLOCK-1 推翻 ——
**本刀在同一个文件族里(`ReviewActions.tsx`)同步更正了那句抬头**,`WorkOrderActions` 的代码一个字没动。

### 8.2 第二块样板(我自己量到的):`app/tools/reminders/page.tsx`

`:188` 与 `:335` 也被报进桶 ④,而**这一页本来就把三类分得干干净净**:

| 分区 | 意思 | 画法 |
|---|---|---|
| `waiting` | 有事要办 | 按等待天数排的清单 |
| `quiet` | **看得见,此刻没事** | 单独一节,自己的标题、措辞、颜色 |
| `restricted` | **你看不见** | `<Refusal>` 药丸,**逐条带着那个权限码** |

它自己的注释逐字写着这条道理:「零与受限合成一堆,就是把"你看得见、此刻没事"与
"你看不见"说成同一句话」。`!canHr` 早就在 restricted 那一节里有一枚具名药丸。

★ **唯一漏掉的一个臂,我补了:HR 那一支的【安静】那一格。**
`canHr && hrAlerts.length === 0` 时,HR 那一行**既不在 quiet 也不在 restricted** ——
于是"HR 这边没事"与"我压根没让你看 HR"在屏幕上又合上了。补进 quiet 那一节,
**没有新造一套画法,也没有一句新文案**(用的是既有的 `reminders.hrSection`)。

### 8.3 `app/tools/tasks/[id]/page.tsx:98`

`iAmParticipant` 是一个**派生事实**,三个操作数回答同一个问题(见 §5 第 5 条)。
它不是一道混了两种理由的闸。它的**消费者**缺的那一句(「你不在这张任务上」)
已经在 `Participants.tsx` 里补上。

---

## 9 · 我自己定的(都是细节,不是形状)

1. **【先问记录状态,再问权限】的次序** —— §3 抬头那条。一份对所有人都改不动的记录,
   再叠一句权限的话是正确而无用的。它决定了桶 ① 每一处的分叉写法。
2. **有【取消】钮的面板,自己不套闸;闸装在打开它的那个钮上。** 逐个文件查过 setter,
   确认没有第二个入口。理由是 DBLOCK-1 量出来的第一条边界。
3. **`ReviewActions:109` 的作废闸【不带】`alsoAllowedIf`。** 作废真的只有 `module.hr.edit`
   一条路。写一条不存在的第二条路,与写错原因是同一种坏。
4. **`ReviewActions` 的四眼原则那一句去掉了 `canHrEdit &&`。** 四眼原则对提交人成立,
   与他有没有 HR 权限无关;带着那个条件,没有权限的提交人屏幕上一个字都没有。
5. **`IssuePanel` 的 `blocked` 里不叠 `!permission.allowed`。** `fieldset disabled` 已经禁掉它了;
   叠上去就是同一件事的第二份实现,而本仓库为这个形状付过四次账。
6. **发票那两个钮在挡住时画成真的 `<button disabled>`,不是被包起来的 `<a>`。**
   `fieldset disabled` 禁不掉链接 —— 这是 AGENTS.md 已经写下的边界。
7. **删掉本刀自己造成的孤儿词条**(`materials.assayPolicy.needsEdit`)。
8. **带两句话的拒绝药丸放开换行**(`whitespace-normal`)。`Refusal` 本身是 `nowrap`,
   那对单句是对的;两句话在手机上会横着溢出去。
9. **`Participants` 的第四句刻意不写成"去要某个权限码"。**「在不在这张任务上」管理员给不了。
10. **旗舰那一处一句新话都没写。** `!!chosen` 要的空态**早就在屏幕上**了;
    该做的是把那个死操作数拿掉,不是再写一句。

---

## 10 · 只报不改(两条,都是本刀量到的新发现)

### 10.1 ★ `MaintenancePanel.tsx` 里有【五道闸报错了权限码】

`app/finance/assets/[id]/page.tsx:451` 传的是 `canEdit={canRecordEquipment}`,
而 `canRecordEquipment = can('module.processing.edit')`。
可这个文件里有 **5 处** `<PermissionGate code="module.finance.edit" allowed={canEdit}>`
(:219 · :361 · :430 · :473,以及 :218/:219 那一处**双层嵌套**,外层写 processing、内层写 finance)。

**于是屏幕上对人说的是「去要 `module.finance.edit`」,而实际被检查的是 `module.processing.edit`。**
这正是 `DBLOCK-CONFLATED-BOOLEANS` 立案那句话的字面情形 —— **说错原因比不说原因更坏。**

★ 而其中 `CapitaliseControl` 那两处更值一提:`capitaliseMaintenance` 走 `record_expense`,
它**真的要 `module.finance.edit`**(`db/functions/record_expense.sql:54` 的
`require_permission('module.finance.edit')`)。也就是说**那两处的码是对的、布尔是错的**:
一个持 `module.processing.edit` 而无 `module.finance.edit` 的人,
会看到一个**能按**的「资本化」钮,按下去被服务端拒。

**没有改。** 它不在这 44 处里(它不是一条混合布尔),而修它要给页面加一次新的权限取数
并往下穿一个新 prop —— 那是**形状**,不是细节,按委托书 §5 该由你裁。

### 10.2 仪器的一个窄处:`STATE_FIELD` 的词边界

`\b(status|state|locked|…)\b` 认不出 `retention_state`、`reviewType` 这类真的记录状态字段
(下划线/驼峰不构成词边界)。它让两处桶 ① 掉进了桶 ④(见 §5)。
**没有改判据** —— 在一次刚被它绊倒的切次里现改,正是"匆忙的检查者"。

---

## 11 · 没有做的

* 桶 ②(43 处)与桶 ③(1 处)—— **一处没碰**。
* ALERT-2b 那 ~250 处裸行内色值,包括 ALERT-2c 登记的四个坐标 —— **一处没碰,没有采用 `Alert`**。
* 没有新增任何 build 闸或 `check-i18n` 分支。普查脚本仍是手工跑的 `survey-*`,不进构建链。
* 没有装浏览器、没有装任何自动化。
* 没有动 `gate.py` 抬头那句过期的 310s。
* **没有迁移,一条 SQL 都没有。**
* `DBLOCK-CONFLATED-BOOLEANS` **一个字都没删、没改写**(只许追加,而本刀没有追加 ——
  它的删除条件是「绩效考核那一族逐格给出两句区分得开的话」,那件事本刀做完了;
  要不要据此收掉那一条,是你的裁定,不是我顺手做的事)。

---

## 12 · 走查 —— 你欠的那几下,点这里(全是今天线上真有的记录)

★ **先说一句要紧的:`performance_reviews` 线上【零行】(实测)。**
所以本刀最大的那一族(扩展后的 `PermissionGate` + 四句状态话)**今天走不出来** ——
要走,得先在 `/hr/reviews` 建一份考核。这不是缺陷,是没有数据;写在这里免得你白点一趟。

| # | 去哪儿 | 看什么 |
|---|---|---|
| 1 | `/sales/quotes/8642da1b-1c78-44d7-bb1d-b4081036987a`(**QT-2026-0002**,issued,1 行明细) | 明细表的增行/改价/删行都在;删一行 → 对话框弹出,**正文那句 `hardDeleteNote` 应当【折行】,不再被拉成一行**(这是对话框那一处的主要走法)。用一个**没有 `module.sales.edit`** 的角色再看一次:三个控件**画着、按不动**,旁边药丸写 `需要权限 module.sales.edit`;签发那一排也一样(此前那里是**空白**) |
| 2 | `/operation/orders/5564bf06-ac59-44be-b372-b2ec92ed3f77`(**WO-2026-0001**,released) | 「改计划」那个钮现在**永远画着**。没有 `module.processing.edit` 时它禁用 + 药丸;有权限时照旧 |
| 3 | `/inbound/1912375d-3f25-489e-ae92-933c4f15e025/edit`(**IN-2026-0258**,`source_reason_code` 为 null 且**没有采购行** → 状态就是【未说明】) | 琥珀框下面那张「补说明」表单**现在对没有 `module.inbound.edit` 的人也画出来**,禁用 + 药丸。对比 `/inbound/065622f9-491d-439d-80ef-6d7904537da7/edit`(**IN-2026-0322**,对着采购行)—— 那一张不该出现「重新说明」 |
| 4 | `/finance/invoices/afe48c8d-c637-4608-84c8-14a479a4b6ee`(**INV-2026-0009**,issued) | 用一个**没有 `data.view_banking`** 的角色打开:预览与下载**画着、按不动**(此前是两个钮整个消失),旁边一句 `pdfNeedsBanking` + 药丸 `需要权限 data.view_banking` |
| 5 | `/finance/assets/a1560d88-de19-40fe-b78b-3bfa4079762b`(**FA-2026-0001**) | 停机那一块:没有未结束的停机时「记一段停机」钮上闸;**有**一段没结束时,钮的位置换成「一次只能有一段没结束的停机」——**而这句话现在没有权限的人也读得到** |
| 6 | `/hr/kpi/score`(不选月份)→ 再选 **2026-12**(`5c09b655-c6ab-4319-84ba-12f82922b246`,open、未锁) | 不选时:只有那块蓝色的「先选一个月份」(**没有任何一句拒绝**);选了之后,打分表与「生成」按 `module.hr.edit` 上闸 |
| 7 | `/sales/customers/fdfefcd3-d313-4314-b8fc-b6e0fc96afab`(**CUS-2026-0002 ST Engineering**) | 联系人「新增」、催收「记一次」两个钮:没有权限时**画着、按不动**(此前整个不见);对账单那一块:对得上账时签发表单上闸,对不上时仍是那句带差额的红字 |
| 8 | `/tools/tasks/813ab2c8-d6d2-4c05-b41f-03b60c8f9435`(**ZZ V2 task**,team) | 用一个**不在这张任务上**的账号打开参与人那一块:现在有一句「你不在这张任务上……」(此前**一片空白**) |
| 9 | `/tools/reminders` | 「安静」那一节现在会把 **HR 提醒**也列进去(当你有 `module.hr.view` 而此刻没有 HR 告警时) |
| 10 | 三份附件面板任选其一 —— 例如 `/materials/<任一物料>/edit`、`/suppliers/<任一供应商>/edit` | 删一个附件 → 对话框里那句 `softDeleteFileNote` **应当折行**,窄屏上不横着溢出 |

> **① / ⑩ 是对话框那一处的走法(五处里的两处)。另外三处同形。**
> 再说一遍:**这五处没有被走过,那笔账记在你名下。**

---

## 13 · 收尾

### 13.1 `db/gate.py` —— **它自己的退出码,以及四条判词逐字**

```
GATE_EXIT=0
```

(退出码取自 `db/run_detached.sh` 写进 `/tmp/gate-2d.log` 的那一行 ——
**被等的脚本自己写的**,不是启动器的状态。三个判词 wall-clock **136s**,**197 支 fixture**。)

四条判词,逐字:

```
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
```

`check_grants` 的两格常驻注入自检**都变红了**(基线打瞎 · 查询打瞎),
四个 universe 两条路一致(关系 333 · 函数 497 · 列 4120 · 桶 15)。
**本刀没有迁移,所以没有"破窗"那一栏的起点。**

### 13.2 `npm run build`

```
BUILD_OWN_EXIT=0
```

20 条静态检查 + `next build` 全绿 —— 其中与本刀直接相关的:
`check-i18n`(新加的十一对键 en/zh 双侧都在,`I18N_OWN_EXIT=0`)、
`check-confirm-subject`、`check-currency-literals`、`check-bilingual-concat`、
`check-permission-predicate`、`check-nav-routes`。
`npx tsc --noEmit` 一路 0 —— 但按本仓库的规矩,**判词是 `next build`,`tsc` 只是顺手**。

### 13.3 部署 —— **推了,到了,并且独立复核过**

> ⚠️ **这一节是【订正】的。** 它原本写着「`git push` 被本次会话的 auto-mode
> classifier 拦下,两次提交还在本地,没有部署 id」。**那句话在写下的那一刻是真的**,
> 而 Tim 在会话里把同一条命令重新发了一遍之后它就过了 —— 与 `ANON-0` / `FIX-2b`
> 记下的完全一样:**一次拦截不是一条常设的拒绝。**
> 原文不删掉、改成这一段,是因为「被拦过」这件事本身是下一个人要知道的:
> 不要自己去试它的变体,把那一行交回给 Tim。

```
git push  →  417afec..c55f95e  main -> main
```

| | |
|---|---|
| 工作提交 | `559da63` |
| 交回时 HEAD | **`c55f95e`**(`559da63` + 两次纯文档订正) |
| `origin/main` | **`c55f95ef167f99f4285866d95869a5c0a5344b63`** —— 与本地 HEAD **相等** |
| 部署 id | **6339884384** |
| state | **success** |
| success 时刻 | **2026-09-09 08:26:46 CST**(`2026-09-09T00:26:46Z`) |
| URL | `https://new-era-o03el0djx-tim-s-projects7.vercel.app` |
| 树 | **干净** |

**判词的来路,两条,分开说 —— 它们不是同一件事:**

1. `scripts/wait-for-deploy.sh` 自己的退出码 **`WFD_OWN_EXIT=0`**。
   部署记录在推送后 **58 秒**出现(这一次没有 GRN-1b 记的那种阵发滞后)。
2. **另外独立复核过一次**,不经过那个脚本:
   ```
   gh api …/deployments/6339884384/statuses  →  {"state":"success","created_at":"2026-09-09T00:26:46Z", …}
   gh api …/deployments/6339884384           →  {"sha":"c55f95ef167f99f4285866d95869a5c0a5344b63", …}
   ```
   ☞ 第二问是刻意加的:**"有一条 success 的部署"与"那条部署是【我这个提交】的"
   是两句话**,而本仓库那条「把标签念一遍、把判据念一遍」的规矩要求两句都问。
   `sha` 与本地 HEAD 逐字相同。

**本刀没有迁移,所以【没有破窗】** —— 从头到尾生产跑的都是与库一致的代码,
不存在「旧代码 + 新库」那个窗口。上面那个 success 时刻因此**不是**破窗的终点,
它只是这一刀到人手上的时刻。

> ⚠️ 与 ALERT-2c 同一条:**本节所述的部署是 `c55f95e` 的。**
> 紧随其后写下这一段的那次订正提交会另有一次部署,而它是**纯文档**改动 ——
> 上面的四个数、44 处转换、五处对话框重置,都不受它影响。
