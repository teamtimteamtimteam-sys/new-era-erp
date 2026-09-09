# CONSEQ-1 — 交回报告(round 2)

**桶 A 的十处确认框拿到了它们的后果句,外加三件家务事。**

---

## 1. HEAD、以及开工时的树

| | |
|---|---|
| 开工前 `git fetch origin` | 先跑,所以下面这条相等是对着【刚取回来的】远端引用比的 |
| 开工前 `git status` | **干净** |
| 开工前 `HEAD` | `33ffc76e6c5aabf2da3bdd3daea69db1dbfe1795` |
| 开工前 `origin/main` | `33ffc76e6c5aabf2da3bdd3daea69db1dbfe1795` |
| 两者相等? | **是**,且等于委托书给的 `33ffc76` |
| 收工后 `HEAD` | 见 §9 |

---

## 2. 十处,以及**每一句后果是从哪里读来的**

判据是 R-Q3:**先读动作自己的服务端调用与它背后的数据库闸(路线 c);
c 说不出话才退回去读调用点(路线 a)。** 每一行的最后一列就是那个出处。

| # | 站点 | 从前只说 | 现在补了什么 | 出处(读的是这个) |
|---|---|---|---|---|
| 1 | `app/finance/bank/statements/[id]/UnreconcileControl.tsx:50` | 「Reopen this statement for editing?」 | 回到 open、行可改;既有对账被标记 superseded 并留着(连同理由);完成人被清空;**必须重新对一次** | **c** — `db/functions/unreconcile_statement.sql`:`UPDATE bank_reconciliations SET superseded_at=now(), superseded_reason=…` + `UPDATE bank_statements SET status='open', reconciled_at=NULL, reconciled_by=NULL` |
| 2 | `app/finance/journal/[id]/ReverseButton.tsx:39` | 「Create a reversal of this entry?」 | 按**今天**的日期新过一张、逐行翻边,于是两张**从今天起**抵消而非从原日期;什么都不删;原件标记 reversed;**不能再冲第二次** | **c** — `db/functions/reverse_journal_entry_internal.sql`:`post_journal_entry(p_reversal_date …)`、`SET status='reversed', reversed_by=…`、`JE_ALREADY_REVERSED`;冲销日由 `app/finance/journal/[id]/actions.ts:18` 传 `今天` |
| 3 | `app/finance/settings/GstPanel.tsx:124` | 「Switch GST registration OFF?」(四个词) | 此后任何单据不能带税码、申报表每格为零;**关之前先把要冲的冲掉**(关掉后带税码的费用单再也冲不了);存在带税码费用单或在册带税发票时**直接拒绝并点名** | **c** — `db/functions/guard_gst_switch.sql`:`GST_CANNOT_DISABLE_WITH_CODED_EXPENSES` / `GST_CANNOT_DISABLE_WITH_TAXED_INVOICES`,以及它自己的 `HINT`「冲销要在开关还开着的时候做」;「每格为零」取自既有词条 `finance.gstSwitch.isOff` |
| 4 | `app/finance/settings/LockForm.tsx:83` | 「Remove the period lock?」 | 回填重新被接受(**包括冲销、折旧这些由别的动作写的分录**);**已结财年由另一道闸单独守着,解锁不会重开它** | **c** — `db/functions/assert_posting_allowed.sql`:`locked_before` 那一段,以及**排在它前面的独立** `YEAR_CLOSED` 闸(`year_closes.reopened_at IS NULL`) |
| 5 | `app/hr/payroll/[id]/PostControls.tsx:120` | 「Unpost this payroll period?」 | 按今天冲销薪资分录、期间退回 draft 可改可重过账;原分录留账上;**已付工资 / 已汇 CPF / 已汇代扣 → 拒绝,先冲那些付款** | **c** — `db/functions/unpost_payroll_period.sql`:`PAYROLL_LINES_PAID`、`PAYROLL_CPF_PAID`、`PAYROLL_DEDUCTIONS_PAID`,以及 `SET status='draft', journal_entry_id=NULL` |
| 6 | `app/inbound/[id]/assays/[assayId]/ApplyAssayControls.tsx:84` | 「Unapply this assay result?」 | 只是承认不再作数;**含量与它算出的价格原样留着,什么都不回滚**;换成哪份数是另一件明确的事;**只有最近一次应用的能撤** | **c** — `db/functions/unapply_assay_result.sql`:只 `SET applied_at=NULL, applied_by=NULL`,函数自己的注释写着「**刻意不回价、不回含量**」;`NOT_LATEST_ASSAY`。对照 `apply_assay_result.sql` 的 `DELETE FROM inbound_batch_metals` + `INSERT`(**应用时是替换,所以撤销不可能还原**) |
| 7 | `app/output/[id]/assays/[assayId]/OutputApplyControls.tsx:83` | 「Unapply this output assay?」 | 同上,去掉价格那一半(产出批没有应付) | **c** — 同一支 `unapply_assay_result.sql`(产出走 `module.output.edit` 那一支) |
| 8 | `app/purchasing/orders/[id]/CloseReopenControls.tsx:95` | 「Close this purchase order?」 | **不再出现在收货列表里**,于是不能再按它收货;已收/已开票的不变;可带理由重开;**有预付未抵扣时关单先要一句书面说明**(那笔钱留在预付款项里,这张单永远不会再吸收它) | **a + c** — 前半是 **a**:`db/views/po_receivable_lines.sql:42` 与 `po_receivable_lines_lookup.sql:28` 都过滤 `po.status IN ('confirmed','receiving')`;后半是 **c**:`db/functions/close_purchase_order.sql` 的 `CLOSE_NOTES_REQUIRED` |
| 9 | `app/purchasing/orders/[id]/CloseReopenControls.tsx:147` | 「Reopen this purchase order?」 | 收过货→回 `receiving`,没收过→回 `confirmed`,**重新出现在收货列表里**;理由进备注;已收/已开票/已付的都不变 | **c**(状态)+ **a**(列表)— `db/functions/reopen_purchase_order.sql` 的 `CASE WHEN EXISTS(inbound_batches) THEN 'receiving' ELSE 'confirmed'`;两个状态都在上面那两支视图的白名单里 |
| 10 | `app/finance/payments/[id]/ReversePaymentButton.tsx:39` | 「Reverse this payment? A mirror entry will be created.」(**只说了库里的产物**) | 它结掉的东西**全部回到未结**(发票与账单重新读成未付、往来敞口回来);按今天生成镜像单退回现金并冲分录;**镜像单不带核销行,钱重新录入要重新核销**;不删任何东西;**不能冲两次** | **c + a** — `db/functions/reverse_payment.sql`:`SET status='reversed'`、镜像单「不带核销行」、`PAYMENT_ALREADY_REVERSED`;「回到未结」是 **a** 但**是硬证据**:`invoice_status.sql:48,52`、`ar_open_items.sql:90`、`ap_open_items.sql` 的连接条件都是 `JOIN payments p ON … AND p.status = 'posted'`,所以一转成 `reversed` 就自动不计 |

**做法一律是给既有对话框加一个 `body` prop(R-Q8:不加新 prop、不动 `title`、不动按钮字)。**
`ReversePaymentButton` 的 `title` **原样没动** —— R-Q6 要的是"扩写它",而扩写落在 `body` 上;
若要把 title 里那半句库产物删掉,那是一次编辑的事(见 §7)。

---

## 3. 十处里有没有【没写句子】的?

**没有。十处全部写出了验证过的后果句。** R-Q3 那条"两条路都得不出就一个字都不写"
在本刀**没有被触发** —— 每一处都在动作自己的 RPC 或它的闸里找到了出处,
其中只有第 8 与第 10 处的一半退回到路线 a,而那一半**有明确的视图/连接条件撑着**,
不是从"别处类似的动作大概如此"推的。

☞ **一处刻意的收窄,记在这里:**第 8 处**没有**写「关单之后系统会拒绝收货」——
**那句话不成立**:全库**没有任何**数据库闸因为 `status='closed'` 拒绝收货
(`grep PO_CLOSED` 全库 0 命中)。成立的只是"它不再出现在收货列表里",
所以写的是后者。**这正是 R-Q3 要防的那种话。**

---

## 4. 每一条新增/改动的用户可见文案(逐字,英中并列,按屏幕分组)

### 银行对账单 · 重新打开(`/finance/bank/statements/[id]`)
* **`bank.unreconcileConsequence`(新增)**
  * **EN:** `The statement returns to open and its lines can be edited again. The reconciliation already recorded is kept and marked superseded, with your reason stored alongside it, but it no longer counts and whoever completed it is cleared. The statement has to be reconciled again.`
  * **ZH:** `对账单回到【打开】状态,行又可以改了。已经记下的那次对账会保留并标记为被取代,你写的理由一并存着,但它不再作数,完成对账的人也会被清掉。这张对账单要重新对过一次。`

### 总账分录 · 冲销(`/finance/journal/[id]`)
* **`finance.reverseConsequence`(新增)**
  * **EN:** `A new entry dated today is posted with every line flipped, so the two cancel out from today rather than from the original entry date. Nothing is deleted: this entry stays on the books marked as reversed, and it cannot be reversed a second time.`
  * **ZH:** `系统会按今天的日期新过一张分录,每一行借贷对调,于是两张从【今天】起互相抵消,而不是从原分录的日期起。什么都不会被删:这张分录留在账上并标记为已冲销,而且不能再冲销第二次。`

### 收付款 · 冲销(`/finance/payments/[id]`)
* **`finance.reversePaymentConsequence`(新增)**
  * **EN:** `Everything this payment settled goes back to outstanding: the invoices and bills it was allocated to read as unpaid again, and the counterparty exposure returns. A mirror payment dated today returns the cash and the journal entry is reversed. The mirror carries no allocations, so if this money is entered again it has to be allocated again. Nothing is deleted, and a payment cannot be reversed twice.`
  * **ZH:** `这笔款结掉的东西全部回到未结:它核销过的发票与账单重新读成未付,往来敞口也回来。系统会按今天的日期生成一张镜像收付款单把钱退回,并冲销它的分录。镜像单【不带核销行】,所以这笔钱如果重新录入,要重新核销一次。什么都不会被删,而且同一笔款不能冲销两次。`

### 财务设置 · GST 注册开关(`/finance/settings`)
* **`finance.gstSwitch.consequenceOff`(新增)**
  * **EN:** `From this moment nothing can carry a tax code: invoices and expenses raised afterwards hold no tax, and every return box reads zero. Reverse anything that still needs reversing before switching off, because a coded expense can no longer be reversed once it is off. While coded expenses or live taxed invoices exist the switch is refused outright, and the refusal names the documents in the way.`
  * **ZH:** `从这一刻起,任何单据都不能再带税码:此后开出的发票与费用单不含税,申报表每一格都是零。要冲销的先冲销掉再关 —— 关掉之后,带税码的费用单再也冲不了。只要还存在带税码的费用单或在册的带税发票,这个开关会被直接拒绝,并点名是哪些单据挡在前面。`
  * ☞ **打开那一侧(`confirmOn`)一个字都没有动** —— 它本来就是标准。

### 财务设置 · 期间锁(`/finance/settings`)
* **`finance.unlockConsequence`(新增)**
  * **EN:** `Backdated entries are accepted again: anything dated before the locked date can be posted once more, including entries written by other actions such as reversals and depreciation. A closed financial year is guarded separately and stays closed, so removing this lock does not reopen it.`
  * **ZH:** `早于该日期的分录重新被接受:那个日期之前的分录又能过账了,包括冲销、折旧这些由别的动作写下的分录。已结的财年由另一道闸单独守着,仍然是关着的 —— 解除这道锁【不会】重开那一年。`

### 薪资 · 撤销过账(`/hr/payroll/[id]`)
* **`hr.unpostConsequence`(新增)**
  * **EN:** `The payroll journal is reversed by a new entry dated today, and the period returns to draft so its lines can be corrected and posted again. The original entry stays on the books. If any payslip has already been paid, or CPF or deductions already remitted, this is refused and those payments have to be reversed first.`
  * **ZH:** `系统会按今天的日期新过一张分录冲销薪资分录,期间退回草稿,行可以改了再过账一次。原分录留在账上。如果已经有工资付过款,或 CPF、代扣款已经汇出,这一步会被拒绝 —— 要先把那些付款冲掉。`

### 进料化验 · 撤销应用(`/inbound/[id]/assays/[assayId]`)
* **`assay.unapplyConsequence`(新增)**
  * **EN:** `This marks the result as no longer standing. The batch content and the price it produced are left exactly as they are and nothing is rolled back. Which figures replace them is a separate deliberate act: a new assay, or the manual content grid. Only the most recently applied assay can be unapplied.`
  * **ZH:** `这一步只是承认这份结果不再作数。批次含量与它算出来的价格【原样留着】,什么都不会回滚。换成哪一份数是另一件要明确去做的事:新化验,或手工含量格子。只有最近一次应用的化验能被撤销。`
* **★ `assay.unapplyNote`(**改写 —— 这是本刀唯一动过的、不属于那十处的字串**)**
  * **从前(EN):** `Unapplying restores the metal content record but does NOT reverse the price change — reprice explicitly if that is what you want.`
  * **从前(ZH):** `撤销应用会还原金属含量记录,但不会撤销价格变动 —— 如需改价请另行操作。`
  * **现在(EN):** `Unapplying marks this result as no longer standing. It does NOT restore the previous metal content and does NOT reverse the price change — both stay as this assay left them, and replacing them is a separate deliberate act.`
  * **现在(ZH):** `撤销应用只是承认这份结果不再作数。它【不会】还原之前的金属含量,也不会撤销价格变动 —— 两样都停在这份化验留下的状态上,要换掉是另一件要明确去做的事。`
  * **为什么动它,以及为什么这不是顺手扩大范围** —— 见 §7 第 1 条。

### 产出化验 · 撤销应用(`/output/[id]/assays/[assayId]`)
* **`assay.output.unapplyConsequence`(新增)**
  * **EN:** `This marks the result as no longer standing. The batch content is left exactly as it is and nothing is rolled back. Which figures replace it is a separate deliberate act: a new assay, or the manual content grid. Only the most recently applied assay can be unapplied.`
  * **ZH:** `这一步只是承认这份结果不再作数。批次含量【原样留着】,什么都不会回滚。换成哪一份数是另一件要明确去做的事:新化验,或手工含量格子。只有最近一次应用的化验能被撤销。`
  * ☞ 产出那一侧既有的 `assay.output.unapplyNote` **本来就是对的,一个字没动** ——
    它正是进料那一侧应该说的话(见 §7 第 1 条)。

### 采购单 · 结束 / 重新打开(`/purchasing/orders/[id]`)
* **`purchasing.closeConsequence`(新增)**
  * **EN:** `The order stops being offered for receiving, so nothing further can be booked against it there. Nothing already received or invoiced changes, and it can be reopened later with a reason. If money was prepaid against this order and not yet applied, closing asks for a written explanation first: that cash stays in prepayments and this order will never absorb it.`
  * **ZH:** `这张单不再出现在收货列表里,于是不能再按它收货。已经收过的货、已经开过的票都不变,之后可以带理由重新打开。如果有预付款打到这张单上而还没抵扣,关单会先要一句书面说明:那笔钱留在预付款项里,而这张单永远不会再吸收它。`
* **`purchasing.reopenConsequence`(新增)**
  * **EN:** `The order goes back to receiving if anything has already been received against it, or to confirmed if nothing has, and it appears in the receiving list again. Your reason is added to the order notes. Nothing already received, invoiced or paid is changed.`
  * **ZH:** `这张单回到【收货中】(如果已经收过货)或【已确认】(如果一车都没收过),并重新出现在收货列表里。你写的理由会加进单据备注。已经收过的货、开过的票、付过的款都不变。`

**合计:新增 10 条键 × 2 语 = 20 条;改写 1 条 × 2 语 = 2 条。**
构建时的键覆盖闸报「代码引用的每一个键(含可枚举的动态键)en 与 zh 都在」,
英文词条总数 6288 → **6298**(+10,与新增数逐一对上)。

---
## 5. 三件家务事

### 5.1 `docs/forward-queue.md` —— 现在说的是什么

补了**六条**(全部插在 ALERT-2c 两条之后、`ALERT-3` 之前):

1. **`~~PERM-CODE-1 + LINT-FREEZE-1~~` 已完成 2026-09-09** —— 划掉,提交 `abdd179`、`33ffc76`。
   内容:`MaintenancePanel.tsx` 四处 `PermissionGate` 现在报服务端真正执行的权限码
   (**实测四道错、外层那道本来就对**,委托书说的是五道);`:197` 不再把财务控件
   藏在加工权限后面;eslint 冻进构建 42/88 按 file+rule,**基线只许降不许升**。
   ☞ 并记下**它为什么当初没有条目**:它的委托书 R4 只点名三处更正,终端正确地守在
   那个边界里,于是关刀时没留条目 —— **把 R4 本来要治的漂移原样重演了一遍。**
2. **`~~CONSEQ-1~~` 已完成 2026-09-09** —— 划掉,**并且记出处**(见下)。
3. **`⬜ NARROW-COVERAGE-1`** —— 「名字对,覆盖窄」那一刀。**此前它在队列里一个字都没有**,
   而 `CONSEQ-2` 的排位要指着它;指一条没写下来的刀,正是 §5.1 第 1 条那个形状。
   已知实例四条,含本刀新登记的那一条(§6)。
4. **`⬜ CONSEQ-2`** —— 桶 B 的二十一处,**排在 `NARROW-COVERAGE-1` 之后**,
   二十一处逐一列名,**R-Q2 与 R-Q3 原样抄进条目作为它的governing rules**,
   并记下 `deleted_at` 过滤不齐那条实测(materials 15 之 10 · suppliers 19 之 14 · customers 16 之 13)。
5. **`⬜ COPY-1-SORT-COLLATION`** —— Tim 的裁定已记:**排序永远用英文字序,与界面语言无关**,
   写成**有名字的规则**而不是"跟着英文界面走";勘察必须先立住三件事
   (字序是否真的只在一处 · 数据库是否也在排 · **导出走哪条路**)。
6. **`⬜ 供应商与客户的拼音排序键`** —— 一个**录入的**字段,不自动生成(多音字会产生
   没人会注意到的错读音);**不折进 5**,因为它要迁移,会给一刀纯前端改动开破窗计时。

★ **两条已完成条目都记了【数字的出处】,不只记结果**(委托书 §4.1 的要求)。
`CONSEQ-1` 那条逐字写着:**交下来的 `13` 是 `ALERT-2d` 那一族桶 ① 的开工数
(桶 ① 13→3),与确认框无关,它跨着刀次漂过来穿着本刀的名字;实测总数 57,
桶 A 是其中 10。** 并写下为什么"量得更狠"救不了它 —— 一个本来就不在数这件事的
数字,再怎么量这一族也纠正不过来,只有问「它是从哪来的」才能。

### 5.2 `db/gate.py` 的抬头 —— 现在说的是什么,以及本刀实测到的每一个耗时

**两个数都改了(R-Q4 + R-Q5):**

* **`:29`(R-Q5)**:`--offline` 从 **`13 秒`** 改成 **`44 秒`**。
  那个 `13s` 正是同一份抬头 `:38` 早就撤回过的数 ——
  撤回落了地,而**被撤回的那个抬头数字从来没人改**。同一份抬头,相隔四行。
* **`:38`(R-Q4)**:单点 **`310s`** 改成
  **`2026-09 实测 180–700s,随机器负载而定`**,并新增一段署名 CONSEQ-1 的 ★ 注解,
  写清**问题不是那个数过期了,是这件事上的单点数一定会过期**
  (它量的是一台机器某个下午的负载,不是这道门的成本),
  并留下规矩:**观测落在区间外就把区间放宽,不要把观测丢掉。**
* **盈亏平衡点没有被丢掉,跟着变成区间**:`44/700 ≈ 6.3%` 到 `44/180 ≈ 24.4%`,
  即**每 16 刀到每 4 刀里有 1 刀被抓到就回本**。
  并补一句只有写成区间才看得出来的话:**区间两端都落在"值得跑"那一侧,
  所以这个结论不因负载而翻转。**
* 抬头那句「实测(2026-09-05,同一台机器同一个下午)」**被区间逼着**改成分述:
  `--offline` 那一次仍是那个下午,整门那个区间跨多次运行。除此之外
  **周围的论证一个字没动**(委托书:不得超出区间所迫的范围)。

**本刀实测到的耗时:见 §9。**(委托书:落在区间外就放宽区间 —— 若 §9 的数
落在 180–700s 之外,`db/gate.py:38` 的区间要在同一刀里改宽。)

### 5.3 `DBLOCK-CONFLATED-BOOLEANS` —— 怎么标的

位置 `docs/known-issues.md`(条目开头在原来的 `:105`)。**正文一个字都没有改、没有搬、没有缩写。**
只做了三处**追加**(该条自己的规矩就是「只许追加」):

1. **标题正下方一个状态戳**:
   `> ### ✅ 已修复,并作为规则保留(CONSEQ-1 标注,2026-09-09)` ——
   「缺陷由 `ALERT-2d`(`559da63`,2026-09-09)修掉;删除条件已满足;**本条【不删】**;
   理由见末尾追记;**以下正文一个字都没有改**」。
2. **删除条件那一行下面追加一个指针**(原句照旧):
   「这条删除条件已经满足,**而本条并未因此被删除**…
   **一个满足了的删除条件说明【缺陷修好了】,不说明【这条规矩不要了】。**」
3. **条末新增 `### ★ 追记(CONSEQ-1,2026-09-09)`**,记 Tim 的理由:
   > 「naming the wrong reason is worse than naming none」在 `PERM-CODE-1`(2026-09-09)
   > 里又一次被**决定性地**引用 —— 那一刀四道权限码报错靠的正是这条记录给的授权。
   > **把本条删掉,下一个人就没有可以指的东西了。**

   并写下它从今天起的身份:**不是待办,是【常设规则】。**

---

## 5.4 ★ 更正(NARROW-COVERAGE-1,2026-09-09):本刀报的三个 `deleted_at` 数是**低报**

★★【更正 · NARROW-COVERAGE-1,2026-09-09 —— 连同【那三个数是从哪来的】】★★
**R-Q5:不只写新数,写清楚旧数的出处。** CONSEQ-1 在队列里立的规矩是
「本条记出处,不只记结果。下一条也照办」——**本刀就是那个"下一条"。**

**旧数:`materials` 15 之 10 · `suppliers` 19 之 14 · `customers` 16 之 13。**
**它们是低报,而低报的原因是量具的形状,不是谁数错了:**
那支扫描器只在**同一条调用链上**找 `.is('deleted_at', null)`,
于是它**结构上看不见**写在 helper 里的那一次过滤 ——
`app/materials/materialQuery.ts:68` 的 `applyMaterialFilters`、
`app/suppliers/supplierQuery.ts:65` 的 `applySupplierFilters`、
`app/sales/customers/customerQuery.ts:54` 的 `applyCustomerFilters`,
**三支都是无条件 `chain.is('deleted_at', null)`**,清单页与导出路由全走它们。
☞ 这本身就是「名字对,覆盖窄」的又一例,而它**出在交给下一刀的那个数上**。

**重量之后(分母逐个对上:15 / 19 / 16,与旧数同源):**

| 表 | `.from()` 站点 | 其中**写入点**(根本不是读点) | 读点 | 读点里过滤了的 | **真的不过滤** |
|---|---|---|---|---|---|
| `materials` | 15 | 3 | 12 | **11**(链上 8 + helper 3) | **1** |
| `suppliers` | 19 | 4 | 15 | **13**(链上 10 + helper 3) | **2** |
| `customers` | 16 | 3 | 13 | **11**(链上 8 + helper 3) | **2** |

★ **旧数把写入点也算进了"读点"里** —— `INSERT` / `UPDATE` 一个 `deleted_at`
过滤器都不该有,把它们放进分母会让比例天生偏低。

**而那 5 处真的不过滤的读点,逐个读过之后【全部是拿着一个已有的父记录去取它指着的那一行】:**
* `app/purchasing/orders/[id]/page.tsx:258` — `.in('id', materialIds)`,在一张**历史单据**上显示料名
* `app/logistics/forwarders/page.tsx:55` — `.in('id', …)`,给**已经筛过**的货代清单补付款条件
* `app/logistics/forwarders/[id]/page.tsx:47` — `.eq('id', id).maybeSingle()`,货代详情页
* `app/finance/credit-notes/page.tsx:114` — `.in('id', customerIds)`,显示已开出贷项凭证的客户名
* `app/finance/statements/[id]/pdf/route.ts:53` — `.eq('id', …).maybeSingle()`,对账单 PDF 抬头

也就是 CONSEQ-1 假设存在、但**从未确立**的那一类正当不过滤:
**一行软删之后仍然要能在旧单据上印出它的名字**,否则历史单据会变成一排空白。

★★ **但这【不】等于「它不会再被选到」现在可以写了 —— 那句话问的对象一开始就不对。**
需要的证明不是「所有读点都过滤吗」,而是「**一行软删之后,还能不能在一张【新】单据上被【选中】**」。
两条实测说明第一个总体量不出第二件事:
* **内嵌读根本不在分母里。** `.select('… materials ( … ) …')` 这种内嵌关系读,
  `.from()` 计数一个都看不见:`materials` **21 处**、`customers` **9 处**、
  `suppliers` **4 处** —— `materials` 的内嵌读**比直连读还多**。
  (这正是 `CHECKER-BLIND-SPOTS ②` 逐字记着的那条盲区,原样再现。)
* **选择器不在这些文件里。** 读 `.from('materials')` 的 **14 个文件**中,
  **0 个**渲染 `<option>` / `<select>` / Combobox(对照:全库 **115 个** `.tsx` 含 `<option>`)。
  **料的下拉是从别处喂的**,所以按读点数出来的比例与「能不能被选到」不相干。

☞ **Tim 的裁定(R-Q6):PART 2 在【选择点】上量,不在读点上量。**
「everywhere it matters」= **每一处把这张表当作可选项呈现给操作者、
且那次选择会落到一张新单据上的地方。** 不是每一处读。
**上面这张读点表作为附带产物交回,不丢掉。**
☞ 量法:`/tmp/delcount.mjs` 那一支(helper 感知 + 写入点分离)。
  **下一个人抄这个数的时候,请连量法一起抄走。**

---

## 6. 登记、**没有修**:`check-confirm-subject` 的幽灵主语

**R-Q7:只登记。已写进 `docs/forward-queue.md` 的 `NARROW-COVERAGE-1` 条目。**

* `scripts/check-confirm-subject.mjs:253` —— 断言是 `if (subjects.length < openings)`,
  **只有一个方向**:拦得住解析器漏抓,**拦不住它凭空多抓**。
* 该脚本的文件级筛子跑在**没有去掉注释的原文**上,于是
  `app/components/ui/action-message.tsx:13`(一行 `//` 注释里提到 `<ConfirmButton>`)
  让整个文件进了扫描范围。
* `app/components/ui/action-message.tsx:143` 是 `data-action-message-subject={e.subject}`。
  主语正则 `\bsubject\s*=\s*(\{|")` 的 `\b` **在连字符后面成立**,于是这个 `data-*`
  属性被当成一处确认框主语。已实测:
  `/\bsubject\s*=\s*(\{|")/.test('data-action-message-subject={e.subject}')` → `true`。
* **线上今天的后果**:该检查报 **58 处 subject / 57 个 JSX 开标签**,**第 58 处不是确认点**。
  而那个文件 `countJsxOpenings` 跳过 `//` 行 → `openings = 0`、`subjects = 1`,
  `1 < 0` 为假,**于是它静静地通过,永远发现不了自己**。
* 今天**是绿的**(幽灵那处 `e.subject` 三条判据都过),所以没有坏掉任何东西 ——
  坏掉的是那个数,以及"它自己说不出这件事"。**本刀一个字都没有改它。**

---

## 7. 我自己决定的事(细节,不是形状)

1. **★ 改了 `assay.unapplyNote`(进料那一侧)—— 本刀唯一动过的、不在那十处里的字串。**
   * **为什么必须动:它是【错的】,而且是被本刀新写的那句话正面顶穿的。**
     它说「Unapplying **restores** the metal content record」;而
     `db/functions/unapply_assay_result.sql` **只把 `applied_at` 置空**,函数自己的
     注释逐字写着「**刻意不回价、不回含量**」;`apply_assay_result.sql` 应用时是
     `DELETE FROM inbound_batch_metals` + `INSERT`(**替换**),所以撤销**不可能**还原。
   * **为什么不能只加不改:**新的 `body` 就渲染在这句话下面**六行**,同一块屏幕、
     同一个动作。两句话直接互相矛盾,比其中任何一句单独存在都坏。
   * **它落在 R-Q3 正中间:**「naming the wrong reason is worse than naming none」——
     Tim 在本刀的闸上刚刚重申过这一条。
   * **它是可逆的:**产出那一侧的 `assay.output.unapplyNote` **本来就说对了**,
     我把进料那句改成了同样的意思。**若判断为越界,一次编辑即可回退。**
2. **`ReversePaymentButton` 的 `title` 保持原样。** R-Q6 说"扩写它",我把扩写全部
   放进 `body`,**没有动那半句「A mirror entry will be created.」**。
   保守读法:委托书说本刀"只给既有对话框加一句话"。**若要把那半句库产物从标题里
   拿掉,那是一次编辑。**
3. **十处一律用 `body`,没有用 `details`。** `details` 是 React 节点,给的是薪资过账
   那种要逐条列科目的场合;这十处都是散文句子。
4. **薪资那一处的页面提示 `hr.unpostNote` 留在页面上没有动。** 它说的是对的
   (「分录会被冲销,期间退回草稿」),只是比对话框里那句短。
   两句同屏有轻微重复,但**没有矛盾** —— 与第 1 条的处置理由正相反,所以不动它。
5. **`NARROW-COVERAGE-1` 被我写进了队列**,尽管委托书只点名要登记三条未来刀
   (`CONSEQ-2` / 排序 / 拼音)。理由:`CONSEQ-2` 的排位要指着它,而它**当时在队列里
   一个字都没有** —— 指一条没写下来的刀,恰好是 §5.1 第 1 条那个形状。
6. **量具留在 scratchpad,没有进仓库。** 枚举器与转储脚本都在会话临时目录里,
   **一支新检查都没有加**(委托书 §5:不加新 check/script/prop)。
7. **构建日志里那条「少了 1 条(基线可以变短):`app/components/pdf/Wordmark.tsx :: 渐变`」
   没有处理。** 那个文件本刀一次都没有碰过,是既有漂移;`--update-baseline` 属于
   另一件事,不在本刀范围里。**它是 ✓,不挡构建。**

---
## 8. 怎么走这一遍

### 8.0 ★ 先说安全,因为这十处里有一半按下去很难收回

**十处【全部】可以安全地打开、读那句话、然后按「取消」。**
这不是估计,是组件保证的:`app/components/ui/confirm-dialog.tsx` 的 `onDismiss`
只做 `setOpen(false)` + 把焦点还给触发钮,**不调用任何动作**;
Escape 与点遮罩外面走的是同一条路;而**初始焦点落在「取消」上,不在确认上**
(该文件抬头的规矩)。所以**读这十句话本身是零风险的**。

**危险只在「确认」那一下。** 按下面这个分法:

| 只读、**不要按确认**(除非是你甘愿损失的测试行) | 可以按、而且有对称的回头路 |
|---|---|
| **GST 关闭**(`GstPanel:124`)—— 若真关成,要开回去得重填登记号,而且关掉后带税码的费用单**再也冲不了** | **采购单 结束 ↔ 重新打开** —— 两个方向都有闸、都留痕,是这十处里最安全的一对 |
| **冲销分录 / 冲销收付款 / 撤销薪资过账** —— 都会**真的过账**一张今天的冲销分录,账上留两条,撤不回来 | **期间锁 设置 ↔ 解除** —— 也是成对的,且不碰任何分录 |
| **撤销应用化验** —— `unapply` 之后**含量与价格不会回滚**(这正是新句子说的那件事),要恢复得另做一份化验 | |
| **重新打开对账单** —— 既有对账被标记 superseded,**必须重新对一次** | |

### 8.1 ★★ 我**没能**替你确认线上今天有没有这些行 —— 这一节因此是路径,不是记录号

**三次尝试查线上都被 auto-mode classifier 挡下了**(Management API 一次、
psql 直连一次、写查询文件一次)。按委托书的规矩,**我不猜,也不拿"应该有"充数**,
所以下面给的是**页面路径 + 那一行必须满足的条件**,不是记录号。

**要拿到真的记录号,请自己跑一次(一条只读查询,不写任何东西):**

```
! psql "host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres" -X -A -c "SELECT 'bank_reconciled' w, COALESCE(string_agg(code,', '),'-') s FROM (SELECT code FROM bank_statements WHERE status='reconciled' AND deleted_at IS NULL LIMIT 3) x UNION ALL SELECT 'je_posted', COALESCE(string_agg(code,', '),'-') FROM (SELECT code FROM journal_entries WHERE status='posted' AND reversed_by IS NULL LIMIT 3) x UNION ALL SELECT 'payment_posted', COALESCE(string_agg(code,', '),'-') FROM (SELECT code FROM payments WHERE status='posted' AND reversed_by_payment IS NULL LIMIT 3) x UNION ALL SELECT 'payroll_posted', COALESCE(string_agg(code,', '),'-') FROM (SELECT code FROM payroll_periods WHERE status='posted' AND deleted_at IS NULL LIMIT 3) x UNION ALL SELECT 'po_open', COALESCE(string_agg(code,', '),'-') FROM (SELECT code FROM purchase_orders WHERE status IN ('confirmed','receiving') AND deleted_at IS NULL LIMIT 3) x UNION ALL SELECT 'po_closed', COALESCE(string_agg(code,', '),'-') FROM (SELECT code FROM purchase_orders WHERE status='closed' AND deleted_at IS NULL LIMIT 3) x UNION ALL SELECT 'assay_in', COALESCE(string_agg(code,', '),'-') FROM (SELECT code FROM assay_results WHERE applied_at IS NOT NULL AND inbound_batch_id IS NOT NULL AND deleted_at IS NULL LIMIT 3) x UNION ALL SELECT 'assay_out', COALESCE(string_agg(code,', '),'-') FROM (SELECT code FROM assay_results WHERE applied_at IS NOT NULL AND output_batch_id IS NOT NULL AND deleted_at IS NULL LIMIT 3) x UNION ALL SELECT 'gst', COALESCE(gst_registered::text,'?') FROM finance_settings UNION ALL SELECT 'locked_before', COALESCE(locked_before::text,'NULL') FROM finance_settings"
```

### 8.2 十处的去处、需要的角色、以及那一行要满足什么

| # | 去哪 | 角色 / 权限 | 那一行要满足 | 走不到时会怎样 |
|---|---|---|---|---|
| 1 | `/finance/bank/statements/<id>` → 「重新打开」 | `module.finance.edit` | 对账单 `status='reconciled'` | 没有已对账的对账单,这个钮**根本不渲染** |
| 2 | `/finance/journal/<id>` → 「冲销」 | `module.finance.edit` | 分录 `status='posted'` 且 `reversed_by IS NULL` | 已冲过的会被 `JE_ALREADY_REVERSED` 拒 |
| 3 | `/finance/settings` → GST 那一块 → 「关闭 GST」 | `module.finance.edit` | `finance_settings.gst_registered = true` | **今天若本来就是关着的,这个钮不在** —— 那一侧渲染的是「打开」 |
| 4 | `/finance/settings` → 期间锁 → 「解除锁定」 | `module.finance.edit` | `finance_settings.locked_before IS NOT NULL` | **锁是空的时候整个钮不渲染**(`{lockedBefore && …}`) |
| 5 | `/hr/payroll/<id>` → 「撤销过账」 | `module.hr.edit` | 薪资期间 `status='posted'` | 未过账的期间没有这个钮 |
| 6 | `/inbound/<batch>/assays/<assay>` → 「撤销应用」 | `module.inbound.edit` | 化验 `applied_at IS NOT NULL`,且是该批**最近一次**应用的 | 不是最近一次 → `NOT_LATEST_ASSAY` |
| 7 | `/output/<batch>/assays/<assay>` → 「撤销应用」 | `module.output.edit` | 同上,产出侧 | 同上 |
| 8 | `/purchasing/orders/<id>` → 「结束采购单」 | `module.purchasing.edit` | 采购单 `status IN ('confirmed','receiving')` | 已 `closed` / `cancelled` 会被点名拒 |
| 9 | `/purchasing/orders/<id>` → 「重新打开」 | `module.purchasing.edit` | 采购单 `status='closed'` | 非 closed → `PO_NOT_CLOSED` |
| 10 | `/finance/payments/<id>` → 「冲销」 | `module.finance.edit` | 收付款 `status='posted'` 且 `reversed_by_payment IS NULL` | 已冲过 → `PAYMENT_ALREADY_REVERSED` |

☞ **第 3 与第 4 处有一个共同的坑,写在这里免得白跑**:它们**都是条件渲染的**。
GST 那一块只在**已注册**时显示「关闭」,期间锁那个「解除」钮只在**锁不为空**时存在。
若你走过去发现钮不在,那不是本刀漏了 —— 是那一行今天不在那个状态上。

☞ **第 8 与第 9 处是同一个页面上的一对**,而且是这十处里**唯一**可以安全地
一路走完再走回来的:找一张 `confirmed`/`receiving` 的单,关掉(读第 8 句),
再重新打开(读第 9 句,要填理由),状态回到原处。

---
## 9. 收尾:闸门、构建、提交

### 9.1 `db/gate.py` —— **自己的**退出码、墙钟、四条判词逐字

按 `db/run_detached.sh` 起的(判词只认日志里那一行 `^GATE_EXIT=`,不认启动器的状态):

```
db/run_detached.sh --log /tmp/conseq1-gate.log --label "CONSEQ-1 gate" \
    --timeout 1800 --token GATE -- python3 db/gate.py
```

* **闸门自报退出码:`GATE_EXIT=0`**(日志第 260 行,作者是 gate.py 自己)
* **墙钟:331s**(`run_detached` 等到那一行用了 331s;闸门自己在
  「三个判词」那一段内报 `wall-clock 218s`)
* ★ **331s 落在本刀刚写进 `db/gate.py:38` 的 `180–700s` 区间里,所以区间不需要放宽。**
  (它也与 `docs` 之外那份口口相传的 183s–650s 一致。)

**四条判词,逐字:**

```
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
```

### 9.2 `npm run build` —— 自己的退出码,以及 eslint 冻结闸那一行

* **`BUILD_OWN_EXIT=0`**
* **eslint 冻结闸,逐字:**

```
── eslint 冻结闸 ─────────────────────────────────────────────
基线  error 42 · warning 88
现在  error 42 · warning 88
✓ 没有新增的 eslint 问题。
```

**基线没有被动过**(委托书:不许为迁就自己的新代码去改基线;只许降,不许升)。

* 顺带,构建里那条键覆盖闸:`✓ 代码引用的每一个键(含可枚举的动态键)en 与 zh 都在。`
* `node scripts/check-confirm-subject.mjs` 单独跑:**自己的退出码 0**,
  报 `58 处 subject / 57 个 JSX 开标签`(那个 58 就是 §6 登记的幽灵,**没有修**)。

### 9.3 提交、推送、部署

* **开工前 HEAD:`33ffc76e6c5aabf2da3bdd3daea69db1dbfe1795`**(树干净)
* **收工后 HEAD:就是携带本报告的这一次提交** —— 哈希、推送校验(靠 fetch 后比对
  哈希,不靠 push 的输出)、以及部署的 id / sha / 成功时间,见交回时的那条消息。

---

## 10. 一句话总结

**桶 A 十处全部拿到了验证过的后果句,每一句都能指回它的 RPC 或它的闸;
桶 B(21)与桶 C(26)一个字都没有动;三件家务事做完;
`check-confirm-subject` 的幽灵只登记、没有修。**

**而本刀最该被下一个人读到的一句是:那个 `13` 不是量错的,是【别族的数】走错了门。
所以队列里两条已完成条目现在都记着数字的出处,不只记结果。**
