# APR-2 — 没有人批自己的单,而且每一条链真的有人批得动(2026-09-22)

**开工闸(通过):** 工作区干净;`HEAD` = `origin/main` = `git ls-remote origin main`
= `196f579c577198f6150b1475a0d3c809f2844e3b`(APR-1)。

**★ 破窗起点(取自 `db/apply_migration.sh` 自己打印的那一行):**
### ``2026-09-22 21:28:19 CST``
落盘记录:`db/migration-windows.tsv`。
**终点:PENDING —— 等 Tim 在 Vercel 面板上看到成功的那一刻。**

**★★ 这段时间里【什么是坏的】—— 而这一次要说清楚,因为【审批是开着的】:**
库已经是新的,线上跑的还是旧代码。两件事会在这段时间里真的不一样:

| 谁 | 破窗期间 |
|---|---|
| ★ **工单放行** | ★ **当场修好** —— 新库摘掉了那句谁都过不去的授权检查。旧代码只是调同一支函数,所以这件事**不等部署**。破窗对它是【好的】那一边。 |
| ★ **四眼(自批拒绝)** | ★ **当场生效** —— 同理,它长在函数里。于是破窗期间自批会被按名拒,而**旧代码的错误码映射器认不得 `SELF_APPROVAL_FORBIDDEN\|raiser` 这个带后缀的形状**:请假与工单那两处会退到共用兜底(一句人话 + 一个可追查的短码),不是一串生码,也不会静默通过。绩效那一支旧映射器认裸码、不认后缀,同样退到兜底。 |
| `/settings/approvals` | 新的「真的有人批得动吗」那一块**不画**(旧代码不送它),其余原样。`approvals_readiness()` 多返回两个字段,旧页面不读它们,不报错。 |
| 开关 | ★ **仍然是开着的,本刀一刻也没有碰它。** 而它现在多了一道闸:若哪条链没有人批得动,**关掉之后就开不回来**。今天四条链全部有人批得动(见 §5),所以这个风险今天是零 —— 但它是一个新的、真的约束,照直写下来。 |

☞ **一句话:破窗期间没有任何东西变坏,而有一件东西提前变好了。**

---

## ★ 读数的身份,一次说清

**本文所有线上读数都是:以 `postgres` 身份、经 Management API 执行,`rolbypassrls = true`**
—— 除了**显式声明设了 `request.jwt.claims` 或切换了会话身份**的那几处,它们会逐处点名是【谁】,
并说明读的是**基表**还是**函数/视图**。

**每一个数字都是脚本自己那一行退出码报出来的**,不是启动器的状态。

---

## §1 · 交付了什么

| # | 东西 | 在哪 |
|--:|---|---|
| ① | `forbid_self_approval(uuid, uuid)` —— 四眼的**唯一**一份定义,两条腿(raiser / subject),**不是** `SECURITY DEFINER` | `db/functions/forbid_self_approval.sql` |
| ② | `approval_chain_gates()` —— 哪些链接上了 `require_approver_for`,以及每一支动作**自己的**模块门(合取) | `db/functions/approval_chain_gates.sql` |
| ③ | `approval_gate_intersections(text, text)` —— 逐条求交:这条链这一级**有几个人批得动** | `db/functions/approval_gate_intersections.sql` |
| ④ | 请假 · 医疗申报:补四眼(两条腿) | `db/functions/decide_leave_request.sql` · `decide_medical_claim.sql` |
| ⑤ | ★ 绩效:补 **subject** 那条腿 —— 此前"别人提交、被评的那位自己批准"一路通到底,而那条路会写调薪 | `db/functions/approve_review.sql` |
| ⑥ | ★★ 工单:**摘掉 `require_approver_for(1)`**、层级改 `NULL`、补四眼 | `db/functions/release_work_order.sql` |
| ⑦ | 开关那道新闸 + 就绪面板 + `/settings/approvals` 的那一块 + en/zh 文案 | `guard_approvals_switch.sql` · `approvals_readiness.sql` · `ApprovalsPanel.tsx` · `messages/{en,zh}.ts` |
| ⑧ | 四眼那两句人话,跨三个模块**只写一遍**;三支映射器接上它 | `lib/selfApproval.ts` · `app/hr/leave/actions.ts` · `app/hr/reviews/reviewErrorCodes.ts` · `app/operation/errorCodes.ts` |
| ⑨ | ★ `check-anon-grant-decision.mjs` —— 建表时必须对 anon **显式表态**,进 `npm run build` | `scripts/check-anon-grant-decision.mjs` |
| ⑩ | 文档:`docs/approvals.md`(§0b · §1 · §3c N7/N8 + 阈值撞车 · 新的 §3d)· `docs/forward-queue.md` · `docs/known-issues.md`(开一条)· `docs/handbacks/APR-1.md`(关破窗 + 记未决) | — |

**一个迁移,增量式:** `db/migrations/2026-09-22-apr2-self-approval-and-the-approver-that-nobody-is.sql`。
**新 fixture:** `db/fixtures/203-nobody-approves-their-own-and-somebody-can-approve-at-all.sql`。
**改过的既有 fixture:** `12` · `30` · `32` · `74` · `75` · `79` · `90`(见 §6)。

★ **本刀【没有】碰审批开关,一刻也没有。** 迁移的自证 ① 就是这件事;
自证 ②③ 钉住"一行留痕都没写、每一条链的在途张数都没变"。

---

## §2 ★★★ 本刀最值钱的发现:**一把当时就锁在线上的锁**

**它不在委托书上。它是闸轮里量出来的,而量它只花了两条 SQL。**

`require_approver_for(N)` 问的是「你在不在第 N 级那个**角色**里」。
每一支决定函数**另外**问一句「你持不持有本**模块**那个权限码」。
★ **在本刀之前,没有任何东西断言这两个集合有交集。**

**实测 2026-09-22(以 `postgres` 读基表 `user_roles` / `role_permissions` / `auth.users`,
外加 `require_approver_for` 自己逐人给出的答案):**

```
require_approver_for 的判词,逐人:
  admin@swm-os.test     L1=APPROVAL_NOT_AUTHORISED|1|finance   L2=PASS
  chooer@evoltrya.test  L1=PASS                                L2=APPROVAL_NOT_AUTHORISED|2|cfo
  fusheng / phua / sandra / vince                L1=拒  L2=拒
```

| 链 | 模块门 | 门的真持有人 | 一级 = `finance` | ∩ |
|---|---|---|---|---|
| 采购单 | `purchasing.view` + `data.view_prices` | admin · chooer · phua · sandra · vince | chooer | **chooer ✓** |
| ★ **工单** | `processing.edit` | admin · phua · sandra · vince | chooer | ★ **空** |
| 请假 / 医疗 / 绩效 | `hr.edit` | admin · sandra · vince | chooer | ★ **空** |

> ### ☞ 于是:Tim 在 12:25:06 打开审批的那一刻起,**线上没有任何人放行得了一张工单。**
> 屏幕上会出现 `APPROVAL_NOT_AUTHORISED|1|finance` —— 一句听起来像"你级别不够"、
> 而实际上**对每一个人都成立**的话。
> ★ 当时 `work_orders` 的 `draft` = **0**,所以没有单据卡住;**下一张就再也放行不了。**
> ★★ **WO-1b 写下那一行的时候,三道闸全绿。**

**采购单那条链走得通,靠的是运气:** `finance` 这个角色**碰巧**持有
`module.purchasing.view` 与 `data.view_prices`。**没有任何东西在维护这个巧合。**

### 2.1 Tim 的裁定,以及它【修订】了他自己早前的一条规矩

> **按角色分级(`require_approver_for`)只管【带钱的单据】。**
> 不带钱的单据,谁能批仍由它自己的模块权限说了算。

这条**修订**了 APR-0 Q4/Q5 那句「没有金额的单据一律走一级」——
那句话是 Tim 的裁定,也被照做过(WO-1b 正是据它写下那一行)。
**所以它在 `docs/approvals.md` §3c 是【就地划掉 + 修订并列】,不是删掉** ——
删掉会让下一个读代码的人看不懂那一行当初为什么在那里。

### 2.2 ★ 而真正耐用的是那道闸,不是这一次的修法

一次手工修复只修今天这一条。本刀同时装上:

```
approval_chain_gates()          名册:哪些链接上了引擎,各自的门是什么(手写,而它被核对)
approval_gate_intersections()   求交:这条链这一级有几个人同时持有【角色】与【门】
guard_approvals_switch          开的那一刻,0 → 按名拒 APPROVALS_CHAIN_HAS_NO_APPROVER|函数|级别|角色|码
approvals_readiness()           屏幕读【同一份】判据 —— 本函数抬头写着的正是这句话
db/fixtures/203 的 E 臂         ★ 名册 vs pg_proc:逐字相等,否则红
```

★ **E 臂是这一族里最耐用的一条:** 一张手写名册迟早与代码漂开,而漂开的那一刻它仍然全绿。
E 臂让「下一刀接了一条链却忘了登记」**当场变红**,而不是等到某天有人发现一条链谁都批不动。

⚠ **照直说这道闸带来的一个【新的真约束】:** 从今天起,**若哪条链没有人批得动,
审批关掉之后就开不回来。** 今天四条链全部有人批得动,所以风险是零;
而这是一个真的、此前不存在的约束,不是一句装饰。

---

## §3 · 四眼:「自己」是两个人

| 腿 | 谁 | 码 |
|---|---|---|
| **raiser** | 提这张单的人(`created_by` / `submitted_by`) | `SELF_APPROVAL_FORBIDDEN\|raiser` |
| ★ **subject** | 这张单**说的是谁**(请假/报销/绩效的那位员工) | `SELF_APPROVAL_FORBIDDEN\|subject` |

**一份定义,四个调用点。** 写成四遍的规矩,第五条链一定会漏掉它 ——
而漏掉的形状是【什么都不发生】。

### ★★ 3.1 subject 那条腿关掉的是一条【会动钱】的路

`approve_review` 此前**只**拒 `submitted_by`。于是
**「别人提交、被评的那位自己批准」** 一路通到底 —— 而 `approve_review` 会写
`employees.monthly_salary` 与一行 `employment_history` 调薪记录。
☞ **一个人批得了自己的加薪。** 实测 2026-09-22:线上三个持 `module.hr.edit` 的人
(`admin` · `sandra` · `vince`)**全部**在员工册上,所以它不是理论上的。

### 3.2 哪些【没有】改,以及为什么

★ `approve_purchase_order` / `reject_purchase_order` **一个字都没动**(Tim 的委托书:*leave them*)。
采购单没有"这张单说的是谁"这条腿,所以那里**没有缺口**,只有码的形状不同 ——
三支映射器同时认**裸码**与**带后缀**的形状。

### 3.3 两句话,不是一句带参数的

**因为【下一步动作不同】:** 提单的人去找同事批;单据的主角要找的是"既不是他、
也不是提单人"的第三个人 —— **而那个人可能根本不存在**,那是一次真的配置问题,
一句通用的话会把它藏起来。文案住在 `lib/selfApproval.ts`,三个模块共用一份。

### 3.4 `NULL` 一律不匹配,而这是刻意的

老数据没有 `created_by`、或者决定人根本不在员工册上时,那一条**放行**。
拿两个 `NULL` 相等去拒绝,等于把"我不知道"变成"就是你"。
★ **代价照直说:`created_by` 为空的历史单据,raiser 那条腿对它们不生效。**

### 3.5 顺序是【定的】,不是碰运气

raiser 先判。两条同时成立时屏幕上出现 `|raiser` —— 那是更早、更窄、也更好懂的那一句。

---

## §4 · 那支新检查:建表时必须对 anon 表态

**FA-HIST-1(2026-09-20)与 APR-1(2026-09-22)两天之内各踩了一次同一个坑**,
而 APR-1 自己的交回报告写着:两次的教训住在两份表镜像的注释里,
**那是"碰巧打开那个文件的人"才读得到的地方**,并照直记下「这一条没有闸」。
**`scripts/check-anon-grant-decision.mjs` 就是那道闸。**

**判据:** 一张表必须**显式表过态** —— 镜像里有一句**点名这张表**的
`REVOKE … FROM … anon`,**或者** `db/anon-grants-baseline.tsv` 里有一行 `relation<TAB><表名>`。
两样都没有 = **没有人想过这件事**。★ 它**不**规定该选哪一种(那是业务判断),它只拒绝【沉默】。

**落地当天的读数(它能这么严的全部理由):**
`222 张表 · 34 张带点名的 REVOKE · 216 张在基线里 · **0 张没表态**`。
一支上线就红 222 行的检查,教给人的只有怎么跳过这道门。

**它为什么不与现有的三样重复,逐个点名:**
* `db/check_grants.py`(判词六)断言**线上 ⊆ 基线**;这个坑的方向**正好相反**(线上少、重建多),它全绿;
* `db/check_mirrors.py` 在自己的【不比】清单里写着:**不比 GRANT**;
* `db/gate.py` 整门**会**抓到它 —— 而那已经是**迁移之后**,每次都要多付一次破窗里的往返。

**故障注入(三格,当场做的,不是声称的):**

| 注入 | 读数 |
|---|---|
| 从基线里拿掉 `accounts`(它没有点名的 REVOKE) | ✗ **exit 1**,点名 `public.accounts` |
| 把 `finance_settings_history` 镜像里那句 REVOKE 拿掉(★ **就是 APR-1 那次事故的形状**) | ✗ **exit 1**,点名那张表 |
| 把 REVOKE 判据弄瞎 | ★ **exit 2 —— 它说"我瞎了",不说"干净"** |
| 全部还原 | ✓ exit 0 |

★ 外加**七格常驻注入,每一次运行都跑**(沉默的表认得出 · 点名的 REVOKE 算表态 ·
函数的 REVOKE 不算 · 别的表的 REVOKE 不算这一张 · 一份镜像两张表都数到 ·
**基线读不到必须抛而不是读成空集** · 注释掉的建表两条路都不认)。
★ 总体用**两条独立的路**各数一遍(行首锚定的 `CREATE TABLE` vs 剥掉注释后任意位置),
两个数不等就红 —— 差额意味着"有一种写法我没想到"。

---

## §5 · 线上走证 —— 一行都没有落地

**全部在一个【以 `RAISE EXCEPTION` 收尾的事务】里跑,所以整段回滚,一个字节都没有落地。**

**★ 第一版的走证是【错的】,而它错得很安静 —— 照直记下来。**
第一版拿 `chooer`(一级审批人、也是那两张在途请假单的提单人**和**主角)去调
`decide_leave_request`,以为会撞上四眼。**实得 `PERMISSION_DENIED|module.hr.edit`** ——
★ **chooer 根本不持 `module.hr.edit`**(闸轮里就量到过),于是模块那道门先响,
**四眼那一步一次都没有被跑到**。一条"被拒了"的读数,拒的是另一件事。
☞ 这正是本仓库那条「把标签念出来,再把判据念出来,两句话说的是同一件事吗」。
**第二版改成直接跑那支判据本身,并先证明它【就是产品路径在跑的那一支】。**

**原样照录,2026-09-22(以 `postgres` 执行,`request.jwt.claims` 逐人设成那个人 ——
`forbid_self_approval` 读的是 `auth.uid()` 与 `current_user_employee()`,
两者都由 claims 决定,不由会话角色决定):**

```
BEFORE as=postgres(rolbypassrls) 读基表 | enabled=t approval_log=14 leave_pending=2
                                         claims=0 reviews=0 po_pending=0 wo_draft=0
SUBJECT LV-2026-0001  raiser=chooer@evoltrya.test  subject_employee=EMP-2026-0001
WIRED  decide_leave_request 调 forbid_self_approval = t      ← ★ 先证它是产品路径那一支

FOUREYES admin@swm-os.test     hr_edit=t  →  PASS(四眼放行)
FOUREYES chooer@evoltrya.test  hr_edit=f  →  ★ SELF_APPROVAL_FORBIDDEN|raiser
FOUREYES fusheng@evoltrya.test hr_edit=f  →  PASS(四眼放行)
FOUREYES phua@evolytra.test    hr_edit=f  →  PASS(四眼放行)
FOUREYES sandra@evoltrya.test  hr_edit=t  →  PASS(四眼放行)
FOUREYES vince@evoltrya.test   hr_edit=t  →  PASS(四眼放行)

CONTROL 以提单人本人跑 raiser 那条腿  →  SELF_APPROVAL_FORBIDDEN|raiser
CONTROL 以主角本人跑 subject 那条腿   →  SELF_APPROVAL_FORBIDDEN|subject

LOCK   release_work_order 线上 prosrc:按级别授权=f  四眼=t
CHAIN  approve_purchase_order L1 role=finance gate=purchasing.view+data.view_prices approvers=1
CHAIN  approve_purchase_order L2 role=cfo     gate=purchasing.view+data.view_prices approvers=1
CHAIN  reject_purchase_order  L1 role=finance gate=purchasing.view                  approvers=1
CHAIN  reject_purchase_order  L2 role=cfo     gate=purchasing.view                  approvers=1

AFTER  as=postgres(rolbypassrls) 读基表 | enabled=t approval_log=14 leave_pending=2
                                         claims=0 reviews=0 po_pending=0 wo_draft=0
```

| 臂 | 它证明的 |
|---|---|
| `WIRED` | ★ 那支判据**就是**线上 `decide_leave_request` 现在在跑的那一支(读 `pg_proc.prosrc`)—— 少了它,下面逐人的答案只是一个与产品路径无关的数 |
| `FOUREYES` | ★ **chooer 被按名拒**,而他正是那两张在途单的提单人兼主角;**三个持 `module.hr.edit` 的人放行** —— 这一半同样要紧:**这条规矩没有【过度】拒绝** |
| ★ 两条 `CONTROL` | **两条腿各自举得起手**,而且**各报各的码**。少了它们,上面那一片 `PASS` 可能只说明这支函数整个不开火 |
| `LOCK` | ★ **线上目录里,那句按级别授权的检查真的没有了**,而四眼在 —— 读的是库,不是这个仓库里的文件 |
| `CHAIN` | 四条链**各有 1 个人批得动**。审批因此仍然关得掉、也开得回来(见 §2.2 那个新约束) |
| `BEFORE` / `AFTER` | ★ 七个数**逐字相同**。开关没被碰、一行留痕都没写、每一条链的在途张数都没变 |

### ⚠ 走证够不到的那一格,照直说

★ **`|subject` 那条腿在【线上的真单据上】证不出来** —— 线上那两张在途请假单的
**提单人与主角是同一个人**(都是 chooer),而 raiser 先判,所以真单据永远走到
`|raiser` 就停了。上面那条 `CONTROL` 是把 raiser 传成 `NULL` 单独跑那条腿,
**它证明的是判据会开火,不是"一张真单据上它会开火"。**
☞ **真单据上那一格由 `db/fixtures/203` 的 B / D / F 三臂钉住**(那里 HR 代人提单,
raiser 与 subject 是两个人)。两处合起来才是完整的形状,单独任何一处都不是。

---

## §6 ★★ 闸与门抓到的东西 —— 这一节是本刀最值钱的产出之一

**六件,而其中四件是【我自己写下的东西被实测推翻】。**

### ① `--offline` 抓到:新规矩在【九支既有 fixture】上现了形

七支既有 fixture(`12` · `30` · `32` · `74` · `75` · `79` · `90`)里,
**提单的人和做决定的人是同一个**。它们验的都不是审批,而它们全部当场
`SELF_APPROVAL_FORBIDDEN|raiser`。

☞ **这是这条规矩【真实的成本】,所以处置是给每一支配一个【第二个人】,
不是把规矩放松。** 做法:直插的单据显式给一个别的 `created_by`(`12` · `32`);
经 RPC 建的则在做决定那一刻切到第二个身份(`30` · `74` · `75` · `79` · `90`,
共 22 处),那个人**没有 `auth.users` 那一行** —— 于是 `real_role_holders`
不会把他算进去,本支里任何按"真持有人"计数的断言都不受影响。

### ② ★ 而其中一处【绝不能】换人 —— 换了它就变成空转

`db/fixtures/74` 有一臂验的是**「只有 `processing.view` 的角色放行不了工单」**。
批量换人会把它换成那个全权限的第二个人,于是它**成功**,而那条断言当场失去意义
(它仍然会绿 —— 因为它等的是"被拒",而那时它会红得莫名其妙;更坏的一种是它恰好通过)。
**这一处显式留着原身份,并在旁边写明为什么。**
☞ 一次批量修改必须逐处问一句:**这一处的身份,是不是它要证的那件事本身?**

### ③ ★★★ **一句注释污染了读它的检查 —— 同一天,两次**

**(a) `app/finance/financeErrorCodes.ts`。** 我在那个 `new Set([...])` 块里写了一句注释,
里面带着一个**加了单引号的大写码**。`check-i18n` 的 `tsSet` 把这个块里
**每一对单引号**都当成一个码收走 —— **注释也不例外**。
于是它为一个**根本不存在的码**报"缺 en 与 zh 翻译",而那个码是我用来解释另一件事的。

**(b) `db/functions/release_work_order.sql`。** 我把"这里【原来】有一句按级别授权的检查、
为什么摘掉"整段写在**函数体里**。而 `pg_proc.prosrc` **是带注释的** ——
`db/fixtures/203` 的 P 臂与迁移自证 ⑥ 断言的正是
`prosrc NOT LIKE '%require_approver_for%'`,**于是它们被这段解释自己点亮**,fixture 当场红。

> ### ☞ 判词
> ★★ **要解释一件"这里【没有】什么"的事,就不要在它旁边写出那个名字。**
> 这是 AGENTS.md「一句注释可以污染将来对它自己的计数」的**第五次与第六次**,
> 而这一次两个受害者是**两支不同的检查**(一支读源码文本,一支读数据库目录)。
> **处置:** (a) 改写注释,不写出那个字符串,并在原地记下这一课;
> (b) 把整段解释搬到**函数体外面**的文件抬头 —— 那里读得到、而 `prosrc` 够不着。

### ④ `--offline` 抓到:新的 DEFINER 函数欠一条豁免

`approval_gate_intersections` 是 `SECURITY DEFINER` 且没有调用者检查(那是**对的** ——
它的两个调用方一个自己带门、一个是属主身份跑的触发器,而属主没有 claims)。
按既有成规写进 `db/check_mirrors.py` 的 `DEFINER_NO_CHECK_ALLOWED`,理由与
`real_role_holders` 逐字同源;收权写在 `db/views/zzz_function_grants.sql`
(★ 写在迁移里不算数 —— C-1 实测过,`apply_migration.sh` 会在 COMMIT 之前重放那个文件)。

### ⑤ ★★ fixture 203 自己的一个缺陷,而它是本刀主题的【镜像】

H1 那一臂要的是"一条没有人批得动的链"。第一版让**同一个人持有两个审批角色**,
而二级那个角色带着 `module.purchasing.view` —— **于是他经由第二个角色拿到了那个门**,
求交非空,H1 静静地变成空转(开关开起来了)。
★ **求交是按【人】算的,不是按角色算的:一个人的权限是他【所有】角色的并集。**
☞ 这正是本刀在修的那件事的镜像,而它在我自己的 fixture 里又犯了一次。
**它被抓到,是因为那条断言的错误消息把"实得"印成了空** —— 也就是
**一次都没有报错**,而不是"报错了但报错了另一句"。**一条会区分这两者的断言,
比一条只说"失败"的断言值钱。**

### ⑥ ★ 对照臂被它自己要证的那条规矩拦住

`203` 的 F 臂要"第三个人批得动那份绩效"。而「一名员工只有一份未作废的试用期评估」
逼着第二份挂到员工 C 身上,**而我挑的那个第三方恰好就是员工 C** ——
subject 那条腿当场开火,对照臂被自己要证的规矩拦住。
☞ **"找个第三方来批"这句话,要先确认那个第三方不是单据的主角。**
这正是这条新规矩在现实里会咬到的那个形状,记在 fixture 里那一处的旁边。

---

## §7 · 验证链,逐条 —— 每个数都是脚本自己那一行

| 步 | 结果 | 出处 |
|---|---|---|
| `db/gate.py --offline`(第 1 次) | ★ `GATE_OWN_EXIT=1`,**49s** —— **抓到 9 支 fixture + 1 条 definer** | 见 §6 |
| `db/gate.py --offline`(第 2 次) | `GATE_OWN_EXIT=4` —— 203 的 F 对照臂(§6⑥) | 日志自报 |
| `db/gate.py --offline`(第 3 次) | `GATE_OWN_EXIT=4` —— 203 的 H1 空转(§6⑤) | 日志自报 |
| `db/gate.py --offline`(第 4 次) | **`GATE_OWN_EXIT=0`**,**48s**,干净 | 日志自报 |
| `npm run build`(迁移前) | **`BUILD_OWN_EXIT=0`** —— 含新加的 `check-anon-grant-decision` | 日志自报 |
| `~/evoltrya-backups/backup.sh` | **`BACKUP_EXIT=0`**,4.4M,TOC **5893**(上一份 5876,下限 5288);21:09:33 → 21:27:55 = **18m22s** | 脚本自报那一行 |
| `db/apply_migration.sh` | **`APPLY_OWN_EXIT=0`**;预检 9 条 CREATE FUNCTION(**6 替换 · 3 新建**);自证八条全过 | 脚本自报 |
| ↳ 迁移自己打的前后读数 | `BEFORE enabled=t approval_log=14 leave_pending=2 claims=0 reviews=0 po_pending=0 wo_draft=0`<br>`AFTER` **逐字相同**,`chains=4 dead=0` | 迁移自报 |
| `npm run types:gen` | **`TYPES_OWN_EXIT=0`**,`lib/database.types.ts` +24 行 | — |
| `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** | — |
| `npm run build` | **`BUILD_OWN_EXIT=0`** | — |
| `db/gate.py`(整门) | **`GATE_EXIT=0`**,★ **734s** —— 四个判词全绿(可重建性 · 镜像 vs 线上 · 行为断言 · 匿名面) | 日志自报 |
| ↳ 匿名面那一格 | 注入自检两格都变红;universe 关系 339 / 函数 515 / 列 4211 / 桶 15(**两条路一致**);anon 够得着:关系 326 · 函数 1 · 桶 0 · 列级 ACL 0 | 日志自报 |
| `scripts/check-i18n.mjs` | **`I18N_OWN_EXIT=0`** | — |
| `scripts/check-error-swallowing.mjs` | **`SWALLOW_OWN_EXIT=0`**,**0 新增** | — |
| `scripts/smoke-routes.mjs`(detached) | ★ **`SMOKE_EXIT=0`** —— **250 ok · 6 skipped · 0 FAILED**;计时 225 条,合计 **743.2s**,中位数 **3001 ms** | 日志自己那一行 |

### ⚠ 一个要照直记的数:**整门 734s,是本仓库至今最慢的一次**

AGENTS.md 那张表记着「两到六分钟,肥尾,超过 ~400s 先量再下结论」,而区间写的是
**183–650s**。**734s 越过了那个上界**,所以它按规矩单独记一笔、不平均进去:

* fixture 从 205 支长到 **206 支**(本刀 +1),★ **+0.5% 的支数解释不了 +86% 的时长**;
* 上一次实测是 APR-1 的 **394s**,同一台机器、同一天(2026-09-22),相隔约十小时;
* 同一轮里备份跑了 **18m22s**(实测区间 8–34 min 的中段偏上),冒烟 **743.2s**
  (APR-1 是 725.2s,**同量级**)—— ★ **冒烟几乎没变而整门快了一倍,
  这与 GRN-1a/1b 那一对(同一天、同一支 fixture 集、3 倍差)指向同一个结论:
  变量不在 fixture 支数上。**

☞ **一次测量,记下日期,不改那张表的结论。** 要改结论,得有**一串**这个量级的读数,
不是这一条。

---

## §8 · fixture 203 钉住了什么(九臂)

| 臂 | 它断言的 |
|---|---|
| P | 四眼是**一份**判据、**不是** DEFINER、四支决定函数都调它;★ 工单那一行**真的摘掉了**(读 `pg_proc.prosrc`,不读文件) |
| ★★ E | **名册 vs 目录逐字相等** —— 先断言名册非空,再比。下一刀漏登记一条链,这里当场红 |
| A | 请假 · 提单的人自己批 → `…\|raiser` |
| ★★ B | 请假 · **单据说的那位**自己批 → `…\|subject`(HR 代人提单时两者是不同的人) |
| C | **对照** · 第三个人批得动,而且正好落一行留痕、`level` 是 `NULL` |
| D | 医疗申报 · 两条腿 + 对照 |
| ★★ F | 绩效 · subject 那条腿(会写调薪的那条路)+ raiser 那条腿仍在 + 对照 |
| ★★ G | 工单 · 审批**开着**时,一个持 `processing.edit` 而**不在**一级审批角色里的人**放行得了**;外加留痕的 `level` 是 `NULL` |
| ★★ H | 开关那道新闸**两个方向**:H1 没人批得动 → 按名拒(点出函数·级别·角色·缺的码);**H2 补上那个码 → 开得起来**(少了它,一个"永远不许开"的实现全绿) |
| I | 屏幕与闸读同一份判据:面板的 `chain_gates` 条数与"死了几条"必须与判据逐字相同 |

---

## §9 · 本刀量过、并发现为假的断言

**(`AGENTS.md` 要求这一节存在,空着也要写。本刀不空 —— 而且其中四条是我自己写下的。)**

1. ★★ 「APR-2 是四格里【只动 ③】的那一刀,所以它最便宜」(APR-0 §6.2 的原话:
   *"四格里只动 ③,不动 ①②④"*)—— **假**。它**一个 `subject_type` 都不加**是真的,
   而它**悄悄改变了【谁可以批】** —— 那不是那四格里的任何一格,
   **而那四格的清单里没有任何东西会把它报出来**。
2. ★★ 「没有金额的单据一律走一级」(Tim 自己早前的裁定,WO-1b 据它落地)——
   **在效果上是假的**:一级那个角色的人**打不开**工单,于是那道闸对每一个人都成立。
   Tim 在闸轮之后**修订**了这条规矩(§2.1),而它在 `docs/approvals.md` §3c 是
   **就地划掉 + 修订并列**,不是删掉。
3. ★★ 「`approve_review` 拒自批」(APR-0 §1.5 的 **★ 拒**)—— **半假**:
   它只拒 `submitted_by`。**"别人提交、被评的那位自己批准"一路通到底,而那条路会写调薪。**
4. ★ 「医疗申报带金额,所以它真的会分档」(APR-0 §3.1)—— **实践上是假的**:
   `hr_settings.medical_annual_limit_sgd = 1000` 与 `approval_threshold_base = 1000`
   **是同一个数**,而 2026 年折算后的额度是 **333–417**。
   ☞ **2026 年【没有一笔批得出来的医疗申报到得了二级】。**
5. ★ 我自己写的:「`prosrc NOT LIKE '%require_approver_for%'` 是一条
   『那一句真的摘掉了』的断言」—— **假**,只要那段解释还写在函数体里(§6③b)。
6. ★ 我自己写的:「fixture 里让一个人同时持两个审批角色是无所谓的」—— **假**。
   **一个人的权限是他所有角色的并集**,于是 H1 那一臂静静地空转(§6⑤)。
7. ★★ 我自己写的第一版线上走证:「拿 chooer 去调 `decide_leave_request` 会撞上四眼」——
   **假**。**chooer 不持 `module.hr.edit`**,模块那道门先响,四眼一次都没跑到(§5)。
8. ★ 我自己写的注释:「在 `new Set([...])` 块的注释里举一个码作例子是无害的」——
   **假**:`check-i18n` 的 `tsSet` 把它当成了一个真的码(§6③a)。

**量过、确认【为真】的(复核也要留痕):**

* 线上 `approvals_enabled = true`,走证前后一致;`approval_log` **14 行**,前后一致;
  五条链的在途张数(2 / 0 / 0 / 0 / 0)前后一致 —— ✓ 迁移自己打了一遍,走证又打了一遍。
* 四条接上引擎的链**各有 1 个人批得动** —— ✓ 线上实测。
* 线上目录里 `release_work_order` **没有**按级别授权、**有**四眼 —— ✓ 读 `pg_proc.prosrc`。
* `decide_leave_request` 线上**确实**调 `forbid_self_approval` —— ✓ 同上。
* 四眼两条腿**各自举得起手、各报各的码** —— ✓ 两条对照臂实测。
* ★ 它**没有过度拒绝**:三个持 `module.hr.edit` 的人对那张在途单**全部放行** —— ✓ 实测。
* `222` 张表镜像里,对 anon **没表态的是 0 张**(34 张带点名的 REVOKE · 216 张在基线里)
  —— ✓ 用两条独立的路各数一遍,两条都是 222。
* `cfo` 的唯一真持有人**就是** `admin@swm-os.test` —— ✓ 实测,已记进 `docs/approvals.md` §0b。

---

## §10 · 交回给 Tim 的

1. ★ **部署,以及破窗的终点。** 破窗起点 `2026-09-22 21:28:19 CST`;
   **终点由你在 Vercel 面板上看到成功的那一刻给出** —— 这台机器够不到 Vercel,
   本刀不去查、也不去猜(AGENTS.md 的常设规矩)。
   ☞ 破窗期间**没有任何东西变坏,而工单放行提前修好了**(见文首那张表)。

2. ★★ **要你亲手走一遍的,连同账号:**

   | 走什么 | 用哪个号 | 预期 |
   |---|---|---|
   | ★ **放行一张工单** | `sandra@evoltrya.test` 或 `vince@evoltrya.test` | **走得通** —— 今天之前这件事对每一个人都是不可能的 |
   | 批一张**不是自己**的请假单 | `sandra` 或 `vince` | 与今天一样,照常 |
   | ★ 批一张**自己的**请假单 / 报销 | `admin@swm-os.test`(他是 `EMP-2026-0002`,且持 `module.hr.edit`) | ★ **现在被拒**,屏幕上是一句人话:「这张单说的就是你……」 |
   | 采购单那条流 | 照你上次的走法 | 不变 |
   | `/settings/approvals` | `admin` 或 `sandra` | 多一块「真的有人批得动吗」,四行全绿 |

   ⚠ **一个请求:走采购单那条流时,请留下一张 pending 的单,或者告诉我你把它取消了** ——
   这样 §3 那个对不上的差额就能用数据关掉,而不是用一句话。

3. ★★ **仍然未决、等你的:**
   * **APR-1 那次采购单走证在线上找不到痕迹**(`docs/handbacks/APR-1.md` §2b,已按你说的记成 **OPEN**)。
     **本刀没有从"采购链已经证过了"这个前提往下推过一次** —— 它另外量了权限结构(§5 的 `CHAIN` 四行)。
   * ★ **§0b 在【持有人】这一层被违反了**:`cfo` 的唯一真持有人就是 `admin@swm-os.test` ——
     也就是说**二级审批人就是那个能给自己授任何权限的人**。
     已按你说的记成「一个等你的已知事实」,**没有修、也没有做成机器规则**
     (§0b 自己就禁止后者)。解药是第二个持 `cfo` 的人,而那是你的决定。
   * ★ **工单要不要一个【真的】审批人**:本刀摘掉的那道闸谁都过不去。要给它一个,
     得给工单**自己的审批角色**(建模改动)。登记在 `docs/forward-queue.md` 3b-ii。

4. ★ **你亲自划出 APR-2 的那一件,记成【挪走的】而不是【漏掉的】:**
   `APPROVALS_POLICY_WOULD_STRAND` 那条定向拒绝 → **APR-3**
   (`docs/approvals.md` §3c N8 讲理由,`docs/forward-queue.md` 3b-i 讲顺序)。

5. ⚠ **一个【新的、真的】约束,照直说:** 从今天起,**若哪条链没有人批得动,
   审批关掉之后就开不回来**(`APPROVALS_CHAIN_HAS_NO_APPROVER`)。
   今天四条链**各有 1 个人**,所以风险是零;而它是一道会真的拦人的闸,不是装饰。

6. ★ **新开的一条已知问题:** `APR2-WORK-ORDER-AUTO-APPROVED-IS-A-HUMAN-PRESS` ——
   工单在审批关着时写的留痕说「没有人做过这个决定」,**而放行是一个人按下去的**。
   它与本刀给 HR 三条链定的规矩正面冲突。**本刀没有修**(不在范围里,而且会改变
   已落库那一类行的读法),两条出路都写在 `docs/known-issues.md` 里等你裁。

7. ★★ **一件留给所有后续刀的东西,而它是本刀最耐用的产出:**
   `db/fixtures/203` 的 **E 臂** 把 `approval_chain_gates()` 那张**手写名册**
   与 `pg_proc` 里**真正调用 `require_approver_for` 的那组函数**钉成逐字相等。
   ☞ **下一刀接一条链上引擎却忘了登记,fixture 当场红** ——
   而 WO-1b 当年漏掉的正是这一格,它当时三道闸全绿。
