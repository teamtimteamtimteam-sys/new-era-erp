# APR-3 — 报销单接上引擎,而委托书里的另外三条【接不上】(2026-09-22)

**开工闸(通过):** 工作区干净;`HEAD` = `origin/main` = `git ls-remote origin main`
= `034fb01aac7307b502f410b4cc378dc1b9a47dfb`(APR-2)。

**★ 破窗起点(取自 `db/apply_migration.sh` 自己打印的那一行):**
### ``2026-09-23 00:32:48 CST``
落盘记录:`db/migration-windows.tsv` → `2026-09-23T00:33:22+0800`。
**终点:PENDING —— 等 Tim 在 Vercel 面板上看到成功的那一刻。**

**★★ 这段时间里【什么是坏的】—— 说清楚,因为【审批是开着的】:**
库已经是新的,线上跑的还是旧代码。逐条:

| 谁 | 破窗期间 |
|---|---|
| ★★ **报销单的决定** | ★ **当场变了,而且是【收紧】** —— 门从 `module.finance.edit` 换成 `module.finance.view` + `data.view_prices`,并且**开始按金额分档**。它长在函数里,所以**不等部署**。☞ 线上唯一那张在途单 `CLM-2026-0004` 从此归**二级**:批得动的人从 {admin, vince} 收窄到 {admin}。★ 而旧代码的映射器**认不得** `SELF_APPROVAL_FORBIDDEN\|raiser` 这个带后缀的形状,也认不得 `APPROVAL_NOT_AUTHORISED` —— 它们会退到**共用兜底**(一句人话 + 一个可追查的短码),**不是一串生码,也不会静默通过**。 |
| ★ **盘点过账** | ★ **当场开始拒自批**。线上五张 `open` 全是 `admin` 建的,所以**破窗期间他过不了账**;另外五个持 `module.stocktakes.edit` 的人可以。旧映射器同样退到兜底。 |
| ★ **工单放行** | 留痕从 `auto_approved` 变成 `approved` —— **屏幕上看不出区别**(那一行不上屏),变的是库里记的那个值。 |
| ★ **策略编辑** | 多了一道 `APPROVALS_POLICY_WOULD_STRAND`。**破窗期间没有人会去编辑策略**,而真去编了,拒绝会退到兜底。 |
| `/settings/approvals` | 新的「逐链在途」那一块**不画**(旧代码不送它),其余原样。`approvals_readiness()` 多返回两个字段,旧页面不读它们,**不报错**。 |
| 开关 | ★ **仍然是开着的,本刀一刻也没有碰它。**(迁移自证 ① 就是这件事。)`can_disable` 的判据换了,而**今天两者算出同一个数**(会挡关闭的在途 = 0)。 |

☞ **一句话:破窗期间没有任何东西变坏。变紧的那几处都【先拒绝、后解释】** ——
最坏的表现是一句兜底人话,而不是一次静默通过。

---

## ★ 读数的身份,一次说清

**本文所有线上读数都是:以 `postgres` 身份、经 Management API 执行,`rolbypassrls = true`**
—— 除了**显式声明设了 `request.jwt.claims` 或切换了会话身份**的那几处,它们会逐处点名是【谁】,
并说明读的是**基表**还是**函数/视图**。

**每一个数字都是脚本自己那一行退出码报出来的**,不是启动器的状态。

---

## §0 ★★★ 本刀的头条:委托书交给它的那条【前提】是假的,而且假在危险的那一边

委托书写着:

> 「付款、开支、报销单今天都在 `module.finance.edit` 之下决定。二级那个角色是 `cfo`,
>   而 `cfo` 在线上【不持】`module.finance.edit`。所以二级在这些链上的交集看起来是空的。」

**前半句是真的。后半句是假的。** 实测(以 `postgres` 读基表 `user_roles` / `role_permissions` / `auth.users`):

| | 真持有人 |
|---|---|
| `module.finance.edit` | `admin@swm-os.test` · `chooer@evoltrya.test` · `vince@evoltrya.test` |
| `cfo`(被裁定的二级) | ★ **`admin@swm-os.test` —— 就是那个 admin 账号** |
| ⇒ 二级 ∩ `module.finance.edit` | **1,非空** |

> ### ☞ 于是:把门写成 `module.finance.edit`,**这道闸今天会全绿** ——
> ### 而它全绿靠的**只是** `docs/approvals.md` §0b 记着的那次撞车。

★★ **而 Tim 已经裁定他会亲手打破那次撞车**(独立 CFO 账号 → 从 admin 上收回 `cfo`)。
**那一天,`.edit` 那个门上的二级会当场归零**,`APPROVALS_CHAIN_HAS_NO_APPROVER` 让审批
关掉就开不回来,而**没有任何东西会说是这一刀造成的**。

★ **所以门取的是采购单那条链的形状:`module.finance.view` + `data.view_prices`**(Tim 的 Q1)。
实测 `cfo` 持这两个码 —— **独立 CFO 账号落地之后,二级仍然是 1。**

☞ **它今天一个人的权限都没有改**(chooer 与 admin 本来就持 `.edit`),
**而它在该起作用的那一天起作用。**

---

## §1 · 交付了什么

| # | 东西 | 在哪 |
|--:|---|---|
| ① | ★ `expense_claim` 成为一个 subject_type —— **APR-0 §3.2 的四格逐格走完** | `db/tables/approval_log.sql`(①枚举 + ★④读策略)· `record_approval_decision.sql`(②分支)· `decide_expense_claim.sql`(③决定路径) |
| ② | ★★ 报销那条链的门 = `module.finance.view` + `data.view_prices`,**不是** `.edit` | `approval_chain_gates.sql` |
| ③ | `expense_claim_amount_base(uuid)` —— 一张报销单值多少本位币,**唯一**一份定义,三个调用方 | `db/functions/expense_claim_amount_base.sql` |
| ④ | `approval_level_at(numeric, numeric)` —— 分档那个 `>=` 的**唯一**一份定义;`approval_level_for` 改为委托 | `approval_level_at.sql` · `approval_level_for.sql` |
| ⑤ | ★ 盘点:四眼 + 留痕(**不分档** —— 它没有金额) | `post_stocktake.sql` |
| ⑥ | ★ 工单:`auto_approved` → `approved`(Tim 的 Q7) | `release_work_order.sql` |
| ⑦ | ★★ `approval_pending_documents()` —— 在途单据逐行,**一份判据三个读它的人** | `db/functions/approval_pending_documents.sql` |
| ⑧ | ★★★ `APPROVALS_POLICY_WOULD_STRAND` + 关闭那道闸改读同一支函数 | `guard_approvals_switch.sql` |
| ⑨ | 逐链在途张数上屏 + en/zh 文案 | `approvals_readiness.sql` · `ApprovalsPanel.tsx` · `messages/{en,zh}.ts` |
| ⑩ | ★ 退休 `EXPENSE_CLAIM_SELF_APPROVAL`(连同两条文案),四眼改调全库唯一那一份 | `claimErrorCodes.ts` · `messages/{en,zh}.ts` · `decide_expense_claim.sql` |
| ⑪ | 四眼那两句人话接到报销与盘点两块屏幕上 | `claimErrorCodes.ts` · `stocktakeErrorCodes.ts` |
| ⑫ | 文档 | `docs/approvals.md`(§0 就地更正 · **新的 §3e / §3f** · N8 标记建成)· `docs/forward-queue.md`(**3b-0 / 3b-iii / 3b-iv**)· `docs/known-issues.md`(关一条)· `docs/handbacks/APR-1.md`(关那个差额)· `docs/handbacks/APR-2.md`(关破窗) |

**一个迁移:** `db/migrations/2026-09-22-apr3-the-claim-the-count-and-the-edit-that-strands.sql`。
**新 fixture:** `db/fixtures/204-the-claim-the-count-and-the-edit-that-strands.sql`(十二臂)。
**改过的既有 fixture:** `25` · `35` · `75` · `140` · `151` · `161` · `203`(见 §5)。

★ **本刀【没有】碰审批开关,一刻也没有。** 迁移自证 ① 就是这件事;
自证 ②③ 钉住"一行留痕都没写、每一条链的在途张数都没变"。

---

## §2 ★★ 委托书要五条链,量下来【三条接不上】—— 而三条的理由都不是接线

**判据是同一条,而且库里已经用过一次:N2 把「装柜」「发运」踢出审批清单时问的就是它 ——
要审批它,得先发明一个生命周期吗?**

| 项 | 实测 | 裁定 |
|---|---|---|
| ★ `payment` | `payments.status` 只有 `('posted','reversed')` —— **没有在途态**。`record_payment`(796 行)建单、过分录、核销、算已实现汇兑损益,**一个事务里全做完** | **Q2:移出本刀。** 先做建模改动 —— Tim 的说法:**要的是【钱出去之前有人点头】**(申请 → 批 → 付) |
| ★ `expense` | 同形。★ 而且它有一条**自引边**:`decide_expense_claim` 批准之后会代人建一张开支单 —— 两条链同刀接上,第二张单的提单人就是刚批完第一张的那个人,四眼会对着他开火 | 同上。豁免要写成**显式入参**,不是 GUC(Q9) |
| ★ `pricing_formula` | `pricing_formulas` **一个状态列都没有**,而且它由服务端动作**直插表**写出来,没有任何 RPC。`commit_pricing_terms` **不是**它的审批 | **Q3:踢出清单,理由与 N2 逐字同源。** 要那个业务管控的话,诚实的对象是**计价条款【承诺】** → APR-4 |

> ### ☞ 照直说 APR-0 §6.2 那句话错在哪
> 它写着 APR-3 这四个 subject_type「①②④ 已经就位,只差 ③」。
> ★ **①②④ 确实就位**(枚举有、`CASE` 分支有、读策略那一支有)——
> **而「只差 ③」对其中三条是假的:** ③ 的内容是「提交路径读 `approvals_enabled()`,
> 分岔成【等人批】/【直接盖章】」,**而它们没有可以分岔进去的那一半。**

⚠ **三个枚举值仍然留在 `approval_log` 的 CHECK 里,而且没有人写它们。**
★ 这正是 APR-0 §1.2 点名的形状:**枚举里有那个名字,读的人会以为那条路是通的。**
☞ 所以"它不通、以及为什么"写进了 `docs/approvals.md` §3e。

---

## §3 · 线上此刻的一张单据,它恰好落在刀刃上

```
CLM-2026-0004   submitted   1000.00 本位币(SGD)   ★ 恰好等于门槛
                主角 = EMP-2026-0001(chooer@evoltrya.test)
                提单人 = chooer@evoltrya.test      ← raiser 与 subject 是同一个人
```

`approval_level_for(1000.00)` = **2**(`>=`,fixture 151 的 T 臂存在的全部理由就是这一个数)。

| 时点 | 批得动它的人 |
|---|---|
| 本刀之前 | `admin@swm-os.test` · `vince@evoltrya.test`(两人都持 `module.finance.edit`,都不是 chooer) |
| ★ 本刀之后 | ★ **只有 `admin@swm-os.test`** —— 二级 = `cfo`,而 `cfo` 的唯一真持有人就是他 |
| ★★ Tim 拿到独立 CFO 账号之后 | ★ **那个新账号**(它持 `module.finance.view` + `data.view_prices`)。<br>☞ **而如果门当初写成 `module.finance.edit`,这一格会是【没有人】。** |

☞ **分档把批得动的人从两个收窄到一个。** 这是裁定的后果,照直记下来。

---
## §4 · 三条规矩,以及它们各自躲开的那个坑

### 4.1 ★★ 在途张数:两个长得一样的数,问的不是同一件事(Tim 的 Q6)

APR-2 的那个数同时干两件事:印在屏幕上,以及喂 `can_disable` 与关闭那道闸。
**放宽它会把两个问题合成一个 —— 而在今天的数据上,那会把审批【永久锁在开着】**:
线上有一张 `submitted` 的报销单。

> **判别的那一句话,写下来给下一刀:**
> **这条链的决定函数,在审批【关着】的时候还跑不跑得动?**
> * **跑不动** → 它的在途单据 `blocks_disable = true`。
>   (采购单:`approve_purchase_order` 开头就 `RAISE APPROVALS_NOT_ENABLED`,
>    而一张 `pending` 的采购单本来就是审批开着时才生成的 —— 关掉就没人推得动它。)
> * **跑得动** → `false`。
>   (报销单:`submitted` 是员工交了一张单,与开关无关;`decide_expense_claim`
>    开着关着都做得了决定,**只有分档那一步是条件性的**。)

★ **两个数都出自 `approval_pending_documents()`** —— 于是屏幕与闸不可能各读一份判据,
而那正是 `approvals_readiness()` 抬头一直声称、`db/fixtures/203` 的 I 臂一直钉着的性质。

### 4.2 ★★★ `APPROVALS_POLICY_WOULD_STRAND`:判的是【单据】,不是【链】(Tim 的 Q8)

Tim 在动手那天把规矩收紧了一格:**角色与门槛一起判** —— 拿新策略把每一张在途单据
**重新分一次档**,落在没有人批得动的那一档上就按名拒,并点出
【那张单 · 那一级 · 那个角色 · 那支函数 · 缺的码】。

> ☞ **粗的那一版为什么不够,而这是一次测量:** 只问「每条链每一级有没有人批得动」
> 的实现,**会放过一次【门槛】编辑** —— 而线上 `CLM-2026-0004` 恰好是 1000.00,
> 任何一次门槛改动都会把它在两级之间挪。

**它怎么复用那道既有的判据,而不是另立一条:** 调
`approval_gate_intersections(NEW.level1, NEW.level2)` —— **同一支函数,传 NEW 的角色码**,
理由与 `APPROVALS_CHAIN_HAS_NO_APPROVER` 逐字相同(本触发器是 `BEFORE UPDATE`,
读表读到的是 OLD,于是它会判上一版策略并且全绿)。
分档那个比较号也仍然只有一份:`approval_level_at(金额, 门槛)`。

★ **金额分不出来的那一张按【二级】判** —— 复用 Tim 的 N4(「不明金额的安全方向是往上」),
不发明第二条规矩。今天线上没有这样的单据。

★★ **反方向由 `db/fixtures/204` 的 J2 臂钉住:一次【无害的】策略编辑必须放行。**
少了它,一个"策略一律不许改"的实现会全绿 —— **而那正是 N8 要排除的东西**
(「拒绝要给出路,不是给一堵墙」)。

### 4.3 ★ 分档那个 `>=` 搬了家,而搬家有【两半】

`approval_level_at(numeric, numeric)` 现在是全库唯一那一句 `>=`;
`approval_level_for(numeric)` **签名与两句按名拒绝一字未改**,只是把比较交给它。

☞ **搬家的理由不是整理:** `guard_approvals_switch` 是 `BEFORE UPDATE`,
它要拿 **NEW** 的门槛重新分档,而旧入口自己去读表读到的是 **OLD**。

★★ **自证 ⑩ 断言【两半】:那个比较号在 `approval_level_at` 里【有】,
在 `approval_level_for` 里【没有】。** 少了后一半,一份"两处各写一遍 `>=`"的实现
会让前一半照样通过 —— 而两处 `>=` 的系统,迟早有一处被改成 `>`,
且只在【恰好等于门槛】那一个数上现形。

★ **`db/fixtures/151` 的注入④ 跟着搬到了 `approval_level_at`** ——
判据搬了家,注入的目标就得跟着搬,否则它会什么也替换不掉。
(那个文件抬头的 C-1 那一段记的正是同一件事。)
**断言仍然全部走 `approval_level_for` 这个产品入口**,所以那一臂证的依然是线上那条路。

---
## §5 ★★ 闸抓到的东西 —— 这一节是本刀最值钱的产出之一

**`db/gate.py --offline` 跑了三次,第一次抓到 7 支 fixture。
★ 其中【六支】是这一刀真实的后果,不是它的 bug —— 而第七支是我自己的。**

| # | 谁 | 抓到什么 | 处置 |
|--:|---|---|---|
| ① | `140` C 臂 | 断言 `EXPENSE_CLAIM_SELF_APPROVAL`,实得 `SELF_APPROVAL_FORBIDDEN\|raiser` | 换成新码。★ **而同一臂里那句"先证明这个人确实有权批"钉的是 `module.finance.edit`** —— 门换了,**那一句必须跟着换**,否则它证的是一个已经不在这条路上的码,而它仍然会全绿 |
| ② | `140` J 臂 | 目录断言钉着旧判据的调用形状 | 改成 `forbid_self_approval(v_c.created_by, v_c.employee_id)` |
| ③ | `25` · `161`(四处盘点) | `SELF_APPROVAL_FORBIDDEN\|raiser` —— 建单的人自己过账 | ★ **给每一处一个【别的】建单人,不是把规矩放松。** 那几臂要证的是业务日期与计值,**建单人是谁与它们无关** |
| ④ | `203` H2 臂 | `APPROVALS_CHAIN_HAS_NO_APPROVER\|decide_expense_claim\|1\|fx203-l1` | ★ 给两级角色补 `module.finance.view`。☞ **不补的话 H1 报出来的会是报销那条链,而不是它刻意造出来的采购那条** —— 那样它仍然会绿,而它证的已经是另一件事 |
| ⑤ | `35` | 同上 | 同上。☞ 它要的前提一直是"审批开得起来",**而那个前提的内容随着引擎接上的链一起长** |
| ⑥ | `75` E 臂 | 断言工单在审批关着时留一条 `auto_approved` 痕 | ★★ **这一臂断言的值【改了】,而改的是规矩本身**(Q7)。改写成:断言【有】一行 `approved`、【没有】 `auto_approved`、**而且决定人不为空** —— 三条一起,因为"没有 X"这种断言最容易空转 |
| ⑦ | `204`(我自己的) | `suppliers.country` / `counterparty_type` 非空 | 补上 |

### ★★★ 5.1 而第二轮抓到的那一件,是本刀最该被记住的:**我把 APR-2 §6⑤ 那个错又犯了一遍**

`204` 的 **J1** 臂要造一个"没有人批得动的二级"。第一版把那个新角色授给了 `u_l2` ——
**而他已经持着另一个带 `module.finance.view` 的审批角色。**

> ★★ **求交是按【人】算的,不是按角色算的:一个人的权限是他【所有】角色的并集。**

于是他经由旧角色拿到了那个门,交集非空,`WOULD_STRAND` **根本不开火**,J1 静静地变成空转。

☞ **这与 APR-2 §6⑤ 在 fixture 203 的 H1 上犯的是【同一个错】,隔了一刀又犯了一次。**
**所以处置不是在交回报告里记一笔,是在那一段代码旁边写下来,并加一条断言:**

```sql
-- 那个持有人【真的只持一个角色】,否则这一臂会静静空转
SELECT count(*) INTO v_n FROM user_roles WHERE user_id = u_l2b AND revoked_at IS NULL;
IF v_n <> 1 THEN RAISE EXCEPTION '…持了 % 个角色…', v_n; END IF;
```

### ★ 5.2 它是怎么被看出来的 —— 而这一格值得单独记

失败消息印的是 `实得 SELF_APPROVAL_FORBIDDEN|raiser` —— **一句来自【上一臂】的拒绝。**
`v_msg` 是复用的变量,而"根本没报错"那一支**没有清它**。

> ☞ **一条"拒了"的读数,拒的是另一件事** —— 与 APR-2 §5 那次(拿 chooer 去调
> `decide_leave_request`,撞上的是模块门)是同一个形状,只是这一次它出现在
> **失败消息**里,而不是出现在被测的那条路上。
> ★ **处置:每一臂在 `BEGIN` 之前 `v_msg := NULL`。** 否则一次空转会打扮成一次拒绝。

---
## §6 · fixture 204 钉了什么(十二臂)

| 臂 | 它断言的 |
|---|---|
| Q | ① 枚举:`expense_claim` 在 `approval_log` 的 CHECK 里 |
| R | ② 分支:`record_approval_decision` 认得它,**而且把金额冻结下来** |
| ★★ T | ④ **读策略那一支 —— 用【真身份】两头读**:持 `module.finance.view` 的读得到 1 行,**不持的读到 0 行而且不报错**。☞ 这是四格里【唯一一个漏掉也不会有任何东西变红】的 |
| A | raiser 那条腿 → `…\|raiser` |
| ★★ B | **subject 那条腿** → `…\|subject`(财务代人录入,两者是两个人 —— 合在一起写,B 会被 A 顺带通过) |
| C | **对照**:第三个人驳得回,而且正好落一行 `rejected` 的留痕 |
| ★★ D | 分档:**1000.00 恰好等于门槛 → 二级**,999.99 → 一级;★ 而**一级的人去批那张二级的单 → 按名拒**,同一个人去批那张一级的单 → 走得通 |
| ★★ E | 名册里报销那两行的门是 `view+prices`,★ **而且不是 `module.finance.edit`** |
| F | 盘点:建单人自己过不了账 · 第二个人过得了 · 留痕 `level` 是 `NULL` |
| ★ G | 工单:审批**关着**时写 `approved`、**不写** `auto_approved` |
| ★★ H | 在途三条边界:报销**在**且不挡关闭 · **open 的盘点不在** · 采购单**在**且挡关闭 |
| ★ I | 屏幕与闸读同一份判据;`can_disable` 跟着【窄】的那个数走 |
| ★★★ J | `WOULD_STRAND` **两个方向**:J1 会搁死单据的编辑 → 按名拒并点出那张单;★ **J2 无害的编辑 → 放行** |

**躲开的陷阱,逐条:**
(a) 两份实现碰巧一致 → 每一条拒绝都配一条**会成功**的对照(C 之于 A/B,D 的两档互为对照,F2,J2);
(b) 空集通过 → E 先断言那两行**在**再比码,H 断言的是**具体的数**;
(c) 一个"永远拒绝"的实现全绿 → C / F2 / **J2**;
(d) 断言为真却没有管辖权 → A/B 的演员**持有那条链的门**(C 当场证明);
(e) 读文件而不是读目录 → E 与 G 查的是 `pg_proc` 与真的落库行;
(f) ★ RLS 的断言**必须切到真身份**跑 —— 不切的话 T 臂整个空转(fixture 26 那一课)。

---

## §7 · 验证链,逐条 —— 每个数都是脚本自己那一行

| 步 | 结果 | 出处 |
|---|---|---|
| `scripts/check-i18n.mjs` | **`I18N_OWN_EXIT=0`** | 日志自报 |
| `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** | — |
| `scripts/check-error-swallowing.mjs` | **`SWALLOW_OWN_EXIT=0`**,**0 新增** | 日志自报 |
| `npm run build`(迁移前) | **`BUILD_OWN_EXIT=0`** | 日志自报 |
| `db/gate.py --offline`(第 1 次) | ★ `GATE_EXIT=4` —— **抓到 7 支 fixture** | 见 §5 |
| `db/gate.py --offline`(第 2 次) | `GATE_EXIT=4` —— **204 的 J1 空转**(§5.1) | 日志自报 |
| `db/gate.py --offline`(第 3 次) | **`GATE_EXIT=0`**,**50s**,干净 | 日志自报 |
| `~/evoltrya-backups/backup.sh` | **`BACKUP_EXIT=0`**,4.4M,TOC **5901**(上一份 5893,下限 5303);★ **第五次尝试**,见下 | 脚本自报那一行 |
| `db/apply_migration.sh` | **✓ committed atomically**(脚本自己那一行);预检 11 条 CREATE FUNCTION(**8 替换 · 3 新建**) | 脚本自报 |
| ↳ 迁移自己打的前后读数 | `BEFORE enabled=t approval_log=14 leave=2 medclaims=0 reviews=0 po_pending=0 wo_draft=0 expense_claims_submitted=1 stocktakes_open=5`<br>`AFTER` **逐字相同**,外加 `chains=6 dead=0 pending=1 blocking_disable=0`;**自证十条全过** | 迁移自报 |
| `npm run types:gen` | **`TYPES_OWN_EXIT=0`**,`lib/database.types.ts` **+23 行** | — |
| `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** | — |
| `npm run build` | **`BUILD_OWN_EXIT=0`** | — |
| `db/gate.py`(整门,第 1 次) | ★ **`GATE_EXIT=1`**,**674s** —— **抓到 1 条漂移**(见 §5.3) | 日志自报 |
| `db/gate.py`(整门,第 2 次) | **`GATE_EXIT=0`**,**571s** —— 三个判词全绿(可重建性 · 镜像 vs 线上 · 行为断言) | 日志自报 |
| `scripts/check-i18n.mjs`(迁移后) | **`I18N_OWN_EXIT=0`** | — |
| `scripts/check-error-swallowing.mjs`(迁移后) | **`SWALLOW_OWN_EXIT=0`**,**0 新增** | — |
| `scripts/smoke-routes.mjs`(detached) | ★ **`SMOKE_EXIT=0`** —— **250 ok · 6 skipped · 0 FAILED**;计时 225 条,合计 **651.4s**,中位数 **2601 ms** | 日志自己那一行 |

### ⚠⚠ 一件要照直记的:**备份跑了五次才拿到一份**,而五次里有三种不同的死法

**这一节写得比它"应该"的长,因为三种死法里有两种【在屏幕上长得像成功】。**

| # | 怎么起的 | 结果 | 判词从哪来 |
|--:|---|---|---|
| ① | `db/run_detached.sh`,**前台** | ★ **这个会话的前台调用在 10 分钟处被切断,把那支后台的活一起带走了** | 日志里 `pg_dump: terminated by user`,**没有 `BACKUP_EXIT=`** |
| ② ③ | `nohup setsid …` | ★★ **静默失败** —— 两次"起好了"的读数都是假的 | `ps` 里**一个 `pg_dump` 都没有** |
| ④ | harness 的后台模式 + `run_detached.sh` | ★ **真的跑了 ~15 分钟,然后网络断了** | ★ **`BACKUP_EXIT=1`** —— 脚本自己那一行 |
| ⑤ | 同上,立刻重试一次 | ★ **`BACKUP_EXIT=0`** —— 4.4M,TOC 5901,四道检查全过 | 同上 |

### ☞ 三条判词,逐条

**① `setsid` 在这台机器上【不存在】(macOS 没有它)。**
`nohup setsid …` 于是整条命令起不来,**而它不报错** ——
两次"已启动"的判断都是我自己编的,而 `ps` 里空空如也才是真的。
★ **判据:起一支后台活之后,第一件事是【去 `ps` 里把它找出来】,不是读启动器的回显。**
这与本仓库那条「启动器的退出码冒充脚本的退出码」是同一族,只是这一次
**连启动器都没有跑起来**。

**② 备份自己那三道检查【一道都没跑到】,而那正是 CHECK-1 预料到的。**
第 ① 次是被杀,第 ④ 次是 pg_dump 自己退 1 —— 两次都在"落盘 → 验证"之前结束。
★ **而 CHECK-1 的【隔离名优先】在两次里都兑现了:**
磁盘上留下的是 `*.INCOMPLETE`(第 ① 次,我手动删掉)或者**什么都没有**
(第 ④ 次,脚本自己删掉了),**两次都不可能被误认成一份好备份**。
☞ `ls -t evoltrya-backup-*.dump | head -1` 在两次之后给出的都是**上一份真的好备份**。

**③ ★★ 第 ④ 次死掉之后,线上留下了一笔【活着的事务】—— 而本机看不出来。**
实测:本机 `pg_dump` 进程**没有了**,而服务端 `pg_stat_activity` 里
`pid 1457203` 停在**同一句** `COPY public.inbound_batches`,
`xact_age = 30 分 45 秒`、`idle_for = 14 分 41 秒`。
★ **它拿着那些表的 ACCESS SHARE 锁,而本刀的迁移要对 `approval_log` 做 `ALTER TABLE`
(ACCESS EXCLUSIVE)** —— 两者冲突。**不处理的话,迁移会卡到 `statement_timeout`
(实测服务端是 120s)然后中止,而报错只会说"语句超时",一个字都不提在等谁。**
☞ 这正是 AGENTS.md 里 SO-3b 与 EQP-1c-a 那两条,**合起来在同一分钟里出现**。
★ **处置按仓库写好的那条:`pg_terminate_backend(1457203)`,不是 `pkill`。**
终止它是安全的 —— 一支 `pg_dump` 的事务是只读的,它本来的结局就是回滚。
★ **而且服务端【永远不会自己收掉它】:实测 `idle_in_transaction_session_timeout = 0`。**
终止之后复查:剩下的那一个 `idle in transaction` 是**新那一次备份自己的会话**
(它正在读 `pg_proc`,本机 `pg_dump` 同时存活)—— **那是健康的,不是又一个孤儿。**

> ### ★ 为什么只重试一次,而不是"等半小时再说"
> AGENTS.md(PAYEE-1a):**一次重试之前要等多久,答案只能来自"我观察到那次故障
> 已经过去了"。没有那个测量时,正确的做法是【立刻重试一次,然后停下来】。**
> ☞ 本刀量了链路(`select 1` 三次:**2.16s / 1.82s / 2.83s**),
> **这既不能证明故障过去了,也不能证明它还在** —— 于是照规矩:立刻重试一次。

---
## §8 · 本刀量过、并发现为假的断言

**(`AGENTS.md` 要求这一节存在,空着也要写。本刀不空 —— 其中三条是我自己写下的。)**

1. ★★★ 「`cfo` 不持 `module.finance.edit`,所以二级在这些链上的交集看起来是空的」
   (**委托书原话**)—— **后半句是假的,而且假在危险的那一边**:交集是 **1**,
   因为 **`cfo` 的唯一真持有人就是 `admin` 账号**,而 `admin` 角色带着那个码。
   ☞ 写成 `.edit` 的门**今天会全绿**,而 Tim 一拿到独立 CFO 账号就归零。
2. ★★ 「APR-3 这四个 subject_type ①②④ 已经就位,只差 ③」(**APR-0 §6.2 原话**)——
   **对其中三条是假的**:`payments` / `expenses` / `pricing_formulas`
   **没有可以分岔进去的那一半**,③ 不是接线,是建模。
3. ★ 「payments generated by payroll」(**委托书列的系统路径之一**)—— **假**:
   实测 `pay_payroll_lines` / `pay_payroll_cpf` / `pay_payroll_deductions`
   **既不写 `payments` 也不写 `expenses`**。`payments` 唯一的系统写入方是 `reverse_payment`。
4. ★★ 「报销那条链此前没有四眼」(**我开工时的假设**)—— **假**:它有,
   而且两条腿都对 —— 只是它是**第二份判据**(`assert_segregated` + 自己的码),
   而那个码的**唯一一句文案在其中一条腿上是假的**(「这张单是你提的」,
   而拒绝的理由是「你就是这张单说的那个人」)。
5. ★★ 我自己写的:「fixture 204 的 J1 把那个新角色授给现成的二级持有人就行」——
   **假**,**求交是按人算的**,他经由旧角色拿到了那个门,J1 静静空转(§5.1)。
   ☞ **这是 APR-2 §6⑤ 的同一个错,隔了一刀又犯了一次。**
6. ★ 我自己写的:「`nohup setsid …` 可以把备份放到前台超时够不着的地方」——
   **假**:**这台机器上没有 `setsid`**,而那条命令**不报错**,两次"起好了"都是假读数。
7. ★ 我自己写的第一版 `APPROVAL_NOT_AUTHORISED` 文案:「`{0}` 是单据编号」——
   **假**:那个码抛出来的形状是 `…|<级别>|<角色>`,**它根本不带单据编号**。
8. ★ 我自己写的 fixture 151 注入④ 的替换串:`'p_amount_base >= v_threshold'` ——
   **假**:判据搬家之后那个变量叫 `p_threshold`。
   ☞ **它是被那一臂自己那句「这个注入什么也没删」的自检抓住的** ——
   一条**会区分"注入了但没红"与"注入根本没生效"**的断言,比一条只说"失败"的值钱。

**量过、确认【为真】的(复核也要留痕):**

* 线上 `approvals_enabled = true` —— ✓ 迁移开工闸自己查了一遍。
* `cfo` 五个码:`data.view_pay` · `data.view_prices` · `module.finance.view` ·
  `module.logistics.view` · `module.purchasing.view` —— ✓ 实测,**`module.finance.edit` 不在其中**。
* `CLM-2026-0004` = `submitted` / 1000.00 本位币 / 提单人与主角都是 chooer —— ✓ 实测。
* 线上五张 `open` 盘点(`ST-2026-0082`…`0086`)**全部**由 `admin@swm-os.test` 建 —— ✓ 实测。
* `SELF_APPROVAL_FORBIDDEN` 两条腿在线上**各自举得起手、各报各的码**,
  **raiser 先判** —— ✓ 一次回滚探针实测(见 §9 的 carry-over ⑤)。
* 三支映射器把两个后缀都送进 `lib/selfApproval.ts`,两句文案 en/zh 都在 —— ✓ 读 HEAD。
* 自 APR-2 迁移(`21:29:01`)以来,**库里一个字节都没有被应用写过** —— ✓ 六张表实测。

---
## §9 · APR-2 交给本刀的那六条 carry-over,逐条交代

| # | 要的东西 | 状态 |
|--:|---|---|
| ① | 旧的「没有金额的单据一律走一级」就地划掉 + APR-2 Q1 的修订版并列,**记成 Tim 的** | ✓ `docs/approvals.md` §3c N7 **此前就在**(APR-2 写的);★ 本刀**补上了 `docs/forward-queue.md` 那一半**(新的 **3b-0**),因为排刀的人读的是队列,不是 approvals.md |
| ② | 医疗申报的门槛与年度额度撞车(都是 1000) | ✓ `docs/approvals.md` §3c **此前就在**(APR-2 写的),本刀复核逐字仍然成立 |
| ③ | `approval_log` 的 decision 列注释:**为什么 HR 的决定永远不写 `auto_approved`** | ★ **本刀补写**(此前只有结论,没有理由)。新增一整段:HR 三条链**自带引擎、从不读 `approvals_enabled()`**,一个人看过、按了准或不准,**开关开着关着这件事都发生了**;对照采购单则是**单据生下来就是 approved,没有人按过任何东西**。★ 并照直记下它的代价:开关关着时 HR 的留痕与开着时**长得一模一样**,所以这张表回答不了"这个决定是在审批生效期间做的吗" —— 那个问题要靠 `finance_settings_history` 的时间线交叉,**而那是对的:一行留痕该说的是那一刻真的发生了什么,不是当时的配置是什么** |
| ④ | Q4 的裁定(不做一刀切的锁;`APPROVALS_POLICY_WOULD_STRAND`) | ✓ **本刀建成**,见 §4.2。N8 那一节标记为 **BUILT**,并把 Tim 收紧的那一格(角色与门槛一起判)写进去 |
| ⑤ | **重新量**两条自批腿是否都到得了屏幕 | ✓ **下面单列** |
| ⑥ | APR-2 的破窗终点 + 一个带出处的上界 | ✓ **本刀记上**,见下面 |

### ★ carry-over ⑤ —— 重新量的读数,照录

**线上(一次以 `RAISE EXCEPTION` 收尾的回滚探针,以 `postgres` 执行,
`request.jwt.claims.sub` 设成 chooer —— `forbid_self_approval` 读的是 `auth.uid()`
与 `current_user_employee()`,两者都由 claims 决定):**

```
forbid_self_approval(raiser=chooer, subject=NULL)  →  SELF_APPROVAL_FORBIDDEN|raiser
forbid_self_approval(raiser=NULL,   subject=EMP)   →  SELF_APPROVAL_FORBIDDEN|subject
forbid_self_approval(raiser=chooer, subject=EMP)   →  SELF_APPROVAL_FORBIDDEN|raiser   ← 顺序成立
线上 prosrc:decide_leave_request 调 forbid_self_approval = true
线上 prosrc:decide_expense_claim 调 forbid_self_approval = false / 调 assert_segregated = true   ← ★ 本刀修的就是这一格
```

**部署中的映射器(读 `HEAD` = `origin/main` = 已部署的那个 SHA):**
`app/hr/leave/actions.ts:46`(同时服务请假与医疗申报)· `app/hr/reviews/reviewErrorCodes.ts:45`
· `app/operation/errorCodes.ts:87` —— **三支都把两个后缀送进 `lib/selfApproval.ts`**;
`common.selfApprovalRaiser` / `selfApprovalSubject` / `selfApprovalGeneric`
**在 `messages/en.ts` 与 `messages/zh.ts` 里都在**。

☞ **读数:两条腿都到得了屏幕。carry-over ⑤ 绿。**
★ 本刀又给它加了**第四个**调用点(报销)与**第五个**(盘点)。

### ★ carry-over ⑥ —— APR-2 的破窗终点,以及【为什么只有一个最松的上界】

**终点:已关闭 —— Tim 确认部署完成(他没有给钟点)。**
**上界 `2026-09-22 22:38:15 CST`,而它是三种上界里【最松】的那一种,照直标出来。**
出处:本次会话对着库跑的 `select now()`(经 Management API,以 `postgres`)——
**数据库服务器自己的钟**,不是"写这行字时的本地时间"。

> ★★ **APR-1 那一招在这里【不管用】,而这件事本身是一次测量。**
> APR-1 的上界是量出来的:`finance_settings_history` 里那唯一一行,
> **而那一行只能由部署之后的代码写出来**。
> ★ APR-2 的部署**不需要任何人做任何动作**,所以它没有留下这种痕迹。
> **实测:自 APR-2 的迁移(`21:29:01`)以来,库里一个字节都没有被应用写过** ——
> `finance_settings_history` 1 行(停在 `12:25:06`,APR-2 **之前**)·
> `approval_log` 14 行(停在 `09-11`)· 其余六张表全部 ≤ `09-20`。
>
> ☞ **所以【没有更紧的上界】,而这句话是一次测量的结果,不是一次放弃。**
> ★ **教训:** 一份报告能不能给出一个**量出来的**破窗终点,取决于那一刀的部署后面
> **恰好有没有一次会写库的人工动作** —— 而那是运气,不是方法。
> **方法只有一个:部署那一端的时刻由够得到 Vercel 的人给。**

---
## §10 · 交回给 Tim 的

1. ★ **部署,以及破窗的终点。** 破窗起点 `2026-09-23 00:32:48 CST`;
   **终点由你在 Vercel 面板上看到成功的那一刻给出** —— 这台机器够不到 Vercel,
   本刀不去查、也不去猜(AGENTS.md 的常设规矩)。

2. ★★ **要你亲手做的两件,而它们都不是代码:**

   ### ① 独立的 CFO 账号 —— **顺序是承重的,审批正开着**

   | # | 步骤 | 为什么是这个顺序 |
   |--:|---|---|
   | ① | 建那个账号(**只给 `cfo`**) | — |
   | ② | **登录一次** | 一个从未确认过的账号**不算持有人**(`real_role_holders` 的判据 ②)—— §3 那个"过期了三周没人发现"的阻塞条件就是这件事的故事 |
   | ③ | 在 `/settings/approvals` 上确认它是一个**真的二级持有人** | 屏幕与闸读同一份判据,所以这就是闸自己的答案 |
   | ④ | **这时才**从 `admin` 上收回 `cfo` | 提前做的话,二级在审批开着的时候当场掉到零个真持有人 |

   > ★★ **跟着来的那条规矩,容易漏:`admin` 账号【不要】提业务单据。**
   > **自批拒绝是按【账号】判的,不是按【人】判的。** 你一旦持有两个账号,
   > 一张从 `admin` 提出、由 CFO 账号批准的单据**会通过四眼** ——
   > 两条腿比的都是 `auth.uid()`,而那是属于同一个人的两个不同 uuid。
   > **数据库看不见这件事**,而 §0b 已经裁定这里不做机器规则。
   > **保护就是它被写下来了。**

   ★ **给那个账号发权限时:它要的是 `module.finance.view`,【不是】 `module.finance.edit`。**
   本刀正是为了这一天才把门取成 `view + prices`(见 §0)。

   ### ② `CLM-2026-0004` —— 线上那张在等的报销单

   它现在归**二级**,而二级今天唯一批得动的人是 `admin@swm-os.test`。
   ☞ **你可以放着不动**(它不挡审批关闭,见 §4.1),
   也可以用 `admin` 批掉或驳回 —— **两条路本刀都没有替你走。**

3. ★★ **仍然未决、等你的:**
   * ★ **`payment` / `expense` 那一刀什么时候排。** 规格写在 `docs/approvals.md` §3e Q2
     与 `docs/forward-queue.md`(「付款申请那一刀」)。**它不是接线,不要折进任何一刀。**
   * ★ **计价条款【承诺】要不要审批**(Q3 的去处,归 APR-4)。
   * ★ **工单要不要一个【真的】审批人** —— APR-2 挪过来的 3b-ii,**本刀没有碰**。
   * ★ **§0b 在【持有人】这一层仍然被违反着**:`cfo` 的唯一真持有人就是 `admin@swm-os.test`。
     ☞ 上面第 2 件正是它的解药,而那是你的动作。

4. ⚠ **一个【新的、真的】约束,照直说:** 从本刀起,**一次会把在途单据推到
   "没有人批得动"那一档的策略编辑会被按名拒**(`APPROVALS_POLICY_WOULD_STRAND`)。
   ☞ 今天它会咬到的**唯一**一种操作是:**把门槛或二级角色改成让 `CLM-2026-0004`
   落到一个没有人批得动的档上**。其余的策略编辑照常允许 —— 这正是 N8 要的形状。

5. ★ **没有人工走查,而这是你自己的裁定,记在这里免得下一刀又去要一次。**
   整条审批链由同事们在 **APR-6 之后**走一次,只走一次。
   **在那之前,每一刀的线上证据就是它那份【只证拒绝】的走证** ——
   本刀的那一份在 §11。
   ☞ **而它顺带关掉了 APR-1 那个差额**:那次采购单走查是在**测试环境**里做的,
   所以根本没有"线上痕迹"可找 —— **线上至今一次人工走查都没有发生过。**
   已写进 `docs/handbacks/APR-1.md`(就地结清)与 `docs/approvals.md` §3f。

6. ★ **一条已知问题关掉了:** `APR2-WORK-ORDER-AUTO-APPROVED-IS-A-HUMAN-PRESS` ——
   取你的出路 ①。★ **线上 2026-08-16 那一行没有被改写**(本表只增不改),
   所以这一列会同时存在两种写法,**分界是一个日期不是一条规则** —— 列注释里写着这句话。

---
## §11 · 线上走证 —— 一行都没有落地

**全部在一个【以 `RAISE EXCEPTION` 收尾的事务】里跑,所以整段回滚,一个字节都没有落地。**
★ **只证拒绝**(Tim 的常设裁定:整条链由同事们在 APR-6 之后走一次)。

**原样照录(以 `postgres` 执行,`request.jwt.claims` 逐人设成那个人 ——
`forbid_self_approval` 与 `require_approver_for` 读的都是 `auth.uid()`,
由 claims 决定,不由会话角色决定):**

```
BEFORE enabled=t approval_log=14 claims_submitted=1 stocktakes_open=5 po_pending=0 wo_draft=0 history=1

WIRED  decide_expense_claim  foureyes/tiering/log = true/true/true
WIRED  post_stocktake        foureyes/log        = true/true
WIRED  release_work_order    still_writes_auto_approved = * false

TIER   CLM-2026-0004  amount_base=1000.00  level=2        <- * 恰好等于门槛

FOUREYES  chooer                  -> SELF_APPROVAL_FORBIDDEN|raiser
TIERGATE  vince                   -> APPROVAL_NOT_AUTHORISED|2|cfo
STOCKTAKE admin (ST-2026-0082)    -> SELF_APPROVAL_FORBIDDEN|raiser

PENDING  total=1
PENDING  by_chain = expense_claim:1(blocks=f)
PENDING  stocktakes_counted = 0            <- * open 不算在途

CHAIN  approve_purchase_order/L1/finance=1   approve_purchase_order/L2/cfo=1
       decide_expense_claim /L1/finance=1   decide_expense_claim /L2/cfo=1
       reject_purchase_order/L1/finance=1   reject_purchase_order/L2/cfo=1

STRAND harmless_edit  = ALLOWED                        <- * 对照:不是一刀切的锁
STRAND stranding_edit = APPROVALS_POLICY_WOULD_STRAND|CLM-2026-0004|2|operations|decide_expense_claim|module.finance.view+data.view_prices

AFTER  enabled=t approval_log=14 claims_submitted=1 stocktakes_open=5 po_pending=0 wo_draft=0 history=1
```

| 臂 | 它证明的 |
|---|---|
| `WIRED` | ★ 那几支判据**就是**线上那三支函数现在在跑的(读 `pg_proc.prosrc`)—— 少了它,下面每一条读数都只是一个与产品路径无关的数 |
| `TIER` | ★ 线上那张真单据 `CLM-2026-0004` 折出来的本位币金额,以及它落在哪一档 |
| `FOUREYES` | ★ **chooer 被按名拒** —— 他正是那张在途单的提单人兼主角 |
| `TIERGATE` | ★★ **分档真的拦人,而且拦的就是那一层**:vince 持 `module.finance.view` + `data.view_prices`(**门过得去**)、也不是提单人或主角(**四眼过得去**),**而他不在 `cfo` 里** —— 实得 `APPROVAL_NOT_AUTHORISED` 第 2 级 `cfo`。☞ 少了这一臂,上面那条 `FOUREYES` 证明不了【分档】这件事本身 |
| `STOCKTAKE` | ★ admin 过不了他自己建的那张盘点 —— 线上五张 `open` 全是他建的 |
| `PENDING` | 逐链在途,**以及 `stocktake` 必须是 0**(open 不是"在等人批") |
| `CHAIN` | 每一条接上引擎的链**各有几个人批得动** |
| `STRAND` | ★★ **两个方向**:一次无害的门槛编辑**放行**;一次会把那张单推到没人批得动那一档的编辑**按名拒** |
| `BEFORE` / `AFTER` | ★ 七个数**逐字相同**:开关没被碰 · 一行留痕都没写 · 每一条链的在途张数都没变 · 策略留痕没多一行 |

---

## §12 · 这一刀留给后面每一刀的东西

1. ★★ **判别一条链要不要挡住"关掉审批"的那一句话**,写在
   `db/functions/approval_pending_documents.sql` 的抬头:
   **这条链的决定函数,在审批关着的时候还跑不跑得动?**
   ☞ 下一刀接一条链时照它回答一次,而不是照着今天这张表抄。
2. ★★ **`db/fixtures/204` 的 E 臂**把报销那条链的门钉成
   `module.finance.view + data.view_prices`,并**显式拒绝** `module.finance.edit`。
   ☞ **它防的是一件今天看不见的事**:写成 `.edit` 今天全绿,
   而独立 CFO 账号一落地就归零。
3. ★ **`approval_level_at` 是全库唯一那一句 `>=`**,而迁移自证 ⑩ 断言了**两半**
   (它在新函数里有、在旧入口里没有)。☞ 只断言前一半的话,
   一份"两处各写一遍"的实现会照样通过。
4. ★ **`db/fixtures/203` 的 E 臂仍然是这一族里最耐用的一条**,而本刀是它第一次
   真的咬人:接上报销这条链**必须**在 `approval_chain_gates()` 里加两行,
   漏了当场红。**本刀加了,所以它绿。**
