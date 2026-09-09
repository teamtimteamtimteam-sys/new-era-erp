# TABLE-CONVERT-1 交回报告 —— 而【那八张表在 390px 上留下的列,是量出来的同一组,不是抄来的】

转换这一族的第一刀:`/me` 自助页 8 张表 / 6 个文件 → `DataTable`。
六次列选判断原样搬过去了,**而"原样"这两个字有读数**:转换前后各在真浏览器里
渲染一遍,读【390px 上看得见的那几个列头】—— 八张表逐张相等。

---

## 1 · HEAD、树、与委托书预期的差别

| | |
|---|---|
| 开工前 HEAD | `ca5a31c9480116d4312510b7fec7dd100e9c1be3` |
| 收工后 HEAD | 见末尾(本报告与代码同一次提交) |
| 树 | 开工前 `git status` 干净;`HEAD == origin/main` 逐字节相等 |

**与委托书预期的 `9f64bf1` 差一个提交:** `ca5a31c`,只动
`docs/handbacks/TABLE-STYLE-1-round2.md` 一个文件(+131/−3),是上一刀的交回报告。
**docs-only、树干净、HEAD == origin/main —— 按委托书 §0 的三条,PROCEED。**

`/tmp/TABLE-CONVERT-0-survey.md` 在(49094 字节),没有被清掉。

---

## 2 · 人口核对 —— 与普查的批次清单【逐张相符】

普查 §4 第 45–52 行就是这一批。**逐张开源码对过**:文件、行号、列数、
是不是还是手搓的、有没有被动过。

| # | 文件:行 | 列 | 带★列选判断 | 空态 | 钉字号 |
|---|---|--:|:-:|---|--:|
| 45 | `app/me/MyAttendancePanel.tsx:28` | 6 | ★ | `attendance.myEmpty` | 2 |
| 46 | `app/me/MyClaimsPanel.tsx:52` | 4 | · | `me.noClaims` | 2 |
| 47 | `app/me/MyExpenseClaimsPanel.tsx:129` | 6 | ★ | `expenseClaims.none` | 3 |
| 48 | `app/me/MyLeavePanel.tsx:61` | 6 | ★ | (无,在 `balance &&` 里面) | 1 |
| 49 | `app/me/MyLeavePanel.tsx:117` | 5 | ★ | `me.noLeave` | 2 |
| 50 | `app/me/MyReviewsPanel.tsx:82` | 5 | ★ | (无,外面一道 `myGoals.length > 0`) | 1 |
| 51 | `app/me/page.tsx:327` | 6 | ★ | `me.noPayslips` | 1 |
| 52 | `app/me/page.tsx:403` | 3 | · | `me.noTraining` | 1 |
| | **8 张 / 6 文件** | | **6 ★** | | **13** |

**8 张、6 个文件、6 次判断 —— 与委托书和批次清单三处都对得上。**
钉字号那一栏合计 13,与棘轮基线里 `app/me/` 六个文件的 cellfont 数(2+2+3+3+1+2)
**逐个文件相等**。

### 2.1 ★ 一处普查与源码【不一致】,按委托书以源码为准

普查 §5 把 `MyExpenseClaimsPanel:129` 的撤回钮记成【折进身份格】。
**今天的源码不是这样**:那一列没有 `hidden sm:table-cell`,叠在单号格里的那一份
已经被拿掉了(源码 :197–203 的注释写着经过)。

**这不是普查读错了 —— 是它跑在前面:** 普查文件时间 09-09 23:29,
而 TABLE-STYLE-1 那一刀的交回提交 `ca5a31c` 是 09-10 00:30。**普查记的是当时的源码。**
委托书 §2 已经点名了这一条,本刀按委托书与源码办:**那一列 `priority: true`。**

---

## 3 · ★★ 每张表:手机上【转换前】留哪几列、【转换后】留哪几列 ★★

**这一栏不是读源码读出来的,是在 390px 的真浏览器里读 `getComputedStyle` 读出来的**
—— 转换前的标记与转换后的组件,喂同一份行数据,各渲染一遍,
读每个 `<th>` 的 `display` 判可见性。量法与残留见 §6。

| 表 | 转换前 · 手机留下 | 转换后 · 手机留下 | 同一组? |
|---|---|---|:-:|
| `MyAttendancePanel:28` | Sheet · OT normal · Recorded | Sheet · OT normal · Recorded | ✓ |
| `MyClaimsPanel:52` | Ref · Date · Amount · State | Ref · Date · Amount · State | ✓ |
| `MyExpenseClaimsPanel:129` | Ref · Amount · Status · **(撤回钮那一列)** | Ref · Amount · Status · **(撤回钮那一列)** | ✓ |
| `MyLeavePanel:61` | Year · **Remaining** · State | Year · **Remaining** · State | ✓ |
| `MyLeavePanel:117` | Ref · Days · Status | Ref · Days · Status | ✓ |
| `MyReviewsPanel:82` | Objective · Target · Actual | Objective · Target · Actual | ✓ |
| `page.tsx:327`(工资条) | Period · Gross · Net pay | Period · Gross · Net pay | ✓ |
| `page.tsx:403`(培训) | Training · Completed · Expires | Training · Completed · Expires | ✓ |

**八张全部是同一组。折起来的那一组也逐张相等**(量的是同一次读数的另一半):

| 表 | 折进去的(前 = 后) |
|---|---|
| `MyAttendancePanel:28` | OT rest day · OT public holiday · Unpaid days |
| `MyLeavePanel:61` | Source · Days · Expires |
| `MyLeavePanel:117` | Type · Dates |
| `MyExpenseClaimsPanel:129` | Spent · What for |
| `MyReviewsPanel:82` | Employee result · Reviewer assessment |
| `page.tsx:327` | Employer CPF · Employee CPF · Deductions |
| `MyClaimsPanel:52` / `page.tsx:403` | **一列都不折**(转换前就没有 `hidden sm:table-cell`) |

### 3.1 ★ 两张没有判断的表:四列/三列【全部 priority】,那不是新判断

`MyClaimsPanel:52` 与 `page.tsx:403` 转换前**一个 `hidden sm:table-cell` 都没有**,
四列、三列在 390px 上全都看得见。所以它们的每一列都写了 `priority: true` ——
**那是把"今天手机上全都在"原样说了一遍,不是我给它们新做了一次判断。**
量出来的旁证:这两张表在转换后**一个展开钮都没有**(组件在没有可折的列时不画它),
而其余六张各有展开钮。

### 3.2 ★ 折起来的那几列【真的够得着】—— 点开量过,不是推的

源码上相等还不够:组件的展开区是【点一下才出现】的。
所以最后一次读数【点了展开钮,等一帧,再读展开区的 `<dt>/<dd>`】:

| 表 | 点开之后展开区里有 |
|---|---|
| attendance | `OT rest day: 4` · `OT public holiday: 8` · `Unpaid days: 1` |
| leave(余额) | `Source: …` · `Days: 18` · `Expires: 2026-12-31` |
| expense | `Spent: 2026-08-22` · `What for: 客户拜访的往返机票与市内交通Receipt attached` |
| reviews | `Employee result: …` · `Reviewer assessment: …` |
| payslips | `Employer CPF: 1,054.00 SGD` · `Employee CPF: 1,240.00 SGD` · `Deductions: 120.00 SGD` |

**每一列都带着自己的列头,值也对得上。**

> ★ 那次读数里 `Source` 显示成 `leave.grantType_annual_entitlement` —— **那是我的
> 假数据造错了**,不是缺陷:真实的 grant_type 只有 `entitlement / pro_rata /
> carry_forward / adjustment` 四种(`messages/zh.ts:959`)。渲染那一句
> ``t(`leave.grantType_${b.grant_type}`)`` 转换前后**逐字节相同**。

### 3.3 ★★ 动作列:撤回钮在 390px 上【留在明面上】,不在展开区 ★★

委托书点名要查的那一条,量出来了:

```
before-expense  Withdraw  visible=True   68×24px   inExpandArea=False
after-expense   Withdraw  visible=True   68×24px   inExpandArea=False
```

**转换后那颗钮仍然是 68×24、仍然看得见、而且 `closest('dl') === null`**
—— 它不在展开区里,不需要先点开一行才够得着。
TABLE-STYLE-1 / R1 那条裁定(够不着的动作等于不存在)**活过了这次转换。**

---

## 4 · 空态:一张一张说,**没有一句话被删掉**

| 表 | 转换前 | 转换后 |
|---|---|---|
| `MyAttendancePanel:28` | `rows.length===0` → `<p>` 里 `attendance.myEmpty` | 搬进 `empty` prop,同一个 key |
| `MyClaimsPanel:52` | 同形,`me.noClaims` | 搬进 `empty`,同一个 key |
| `MyExpenseClaimsPanel:129` | 同形,`expenseClaims.none` | 搬进 `empty`,同一个 key |
| `MyLeavePanel:117` | 同形,`me.noLeave` | 搬进 `empty`,同一个 key |
| `page.tsx:327` | 同形,`me.noPayslips` | 由页面把 key 传给客户端件的 `empty` |
| `page.tsx:403` | 同形,`me.noTraining` | 同上 |
| `MyReviewsPanel:82` | **外面一道 `myGoals.length > 0`:没有目标就【整张不画】** | **原样保留那道闸** —— 见下 |
| `MyLeavePanel:61` | **没有空态**(在 `balance &&` 里,空 breakdown 会画出一张只有表头的表) | 用组件自带的 `table.empty` —— 见下 |

**两处需要说清楚,因为它们不是"搬一句话":**

* **`MyReviewsPanel:82` 我【没有】用 `empty` prop。** 这张表本来就是"没有目标
  就一张表都不画",而不是画一张写着"空"的表。给它一个 `empty` 会**多出一句
  今天不存在的话** —— 搬一句没有的话不是搬,是加。所以外面那道闸原样留着。

* **`MyLeavePanel:61` 会多出一句 `table.empty`,而这是【够得着的】状态。**
  实测 `db/functions/leave_balance_internal.sql:15`:`v_break` 从 `'[]'` 起头,
  一个没有任何授予、也没有派生累积的员工**拿到的就是 balance 非空 + breakdown 为空**。
  今天那种人看到的是【一张只有表头、没有行的表】;转换后看到的是同一张表加一行
  `table.empty`。**这是本刀唯一一处会新出现在屏幕上的句子**,它用的是组件既有的
  key,不是我造的新词。自造一句"没有授予记录"要造两种语言的新词,那才是加东西。

---

## 5 · 棘轮:cellfont **418 → 405**,一处都没有涨

| 维 | 之前 | 之后 | 差 |
|---|--:|--:|--:|
| 手搓 `<table>` | 76 | **68** | −8(这八张) |
| **cellfont** | **418** | **405** | **−13** |

**−13 与 §2 那张表"钉字号"一栏的合计【逐个文件相等】**
(2+2+3+3+1+2 = 13,六个文件全部归零)。

构建里那一行原文:

```
   基线:118 个文件在册。本次扫到 405 处。
   分账:标签上 112 处(<table>/<th>/<td>) · 列描述符里 293 处(className: '…')。
✓ 没有新增的格子钉死的字号(<table>/<th>/<td> 标签 + 列描述符的 className)。
```

☞ **列描述符那一栏(293)一处都不是本刀加的。** 委托书说的那个失败模式
(机械转换把 `<td>` 的字号搬进 `Column.className`,债换个拼法)**没有发生**:
八张表的列定义里**一个字号都没有**。被拿掉的具体是:六张表根上的 `text-sm`/`text-xs`,
以及 `MyClaimsPanel`、`MyLeavePanel:117`、`MyExpenseClaimsPanel` 单号格上的
`text-xs`(`font-mono` 留着 —— 那是列的意思,不是字号)。

基线按工具自己的判词收紧了(`--update-baseline`),diff **只有 12 行删除**,
全部是 `app/me/` 那六个文件,**没有一行是新增或放宽**。

`check-datatable-phone`:调用点 **123 → 131**(正好 +8),
`columns 模式 131(各自至少一列 priority)`。

---

## 6 · 量到了什么、没量到什么 —— **/me 那一页我【没有】渲染出来**

### 6.1 ★ 照直说:真的 `/me` 我打不开,所以我没有假装量过它

委托书说的是实情,我又撞了一次:量具的一次性账号是【刚建出来的 admin】,
它**没有员工档案**,于是 `/me` 走 `if (!p)` 那条早返回,画的是"去找管理员" ——
**八张表一张都不渲染。** 要让它渲染出来,需要的状态是:
一个 `auth.users` 行 + 一个 `employees` 行(`user_id` 指向它,有 FK)+
假期授予 + 假期申请 + 医疗报销 + 一般报销 + `payroll_lines` + 培训记录 +
一次 approved 的评估与它的目标 + 考勤行 —— **横跨九张业务表的一整套人造数据。**
**往线上写这一套只为了量一次版式,我没有做**,那是一次不好撤的写入。

### 6.2 我做的是:把【组件自己】搬到 390px 底下量

建了一条一次性路由 `app/tc1probe`(**量完已删,不在这次提交里**),
把这八张表**转换前的标记**(逐字节取自 `HEAD` 的六个文件)与**转换后的组件**
**喂同一份假数据**各画一遍,再用 `chrome-headless-shell` + CDP 在
`390×844 / dsf=3 / mobile=true` 下读 `getComputedStyle` 的解析值。

**它是什么:** 对【组件在 390px 上怎么渲染】的一次真测量。
**它不是什么:** 它不是 `/me` 这条路由。数据是我编的,登录用的仍然是一次性 admin,
所以**"这一页在真实数据下会不会溢出"仍然是未测量的** —— 见 §11。

### 6.3 读数:行高与溢出

| 表 | 表头字号 | 表体字号 | 行高(前) | 行高(后) |
|---|---|---|---|---|
| `MyAttendancePanel:28` | 14 → **15px** | 14 → 14px | 93, 93 | 61.5, 61 |
| `MyClaimsPanel:52` | 14 → **15px** | **12 → 14px** | 65, 65 | 81.5, 81 |
| `MyExpenseClaimsPanel:129` | 14 → **15px** | **12 → 14px** | 196.3, 224.3 | 81.5, 81 |
| `MyLeavePanel:61` | **12 → 15px** | **12 → 14px** | 91.6, 91.6 | 41.5, 41 |
| `MyLeavePanel:117` | 14 → **15px** | **12 → 14px** | 71, 87 | 61.5, 61 |
| `MyReviewsPanel:82` | 14 → **15px** | 14 → 14px | 119, 67 | 101.5, 61 |
| `page.tsx:327` | 14 → **15px** | 14 → 14px | 141, 125 | 61.5, 61 |
| `page.tsx:403` | 14 → **15px** | 14 → 14px | 57, 37 | 61.5, 61 |

**溢出:一处都没有。** 转换前后、八张表,`scrollWidth > clientWidth` 全部为假;
整页 `documentElement`:`clientWidth 390 · scrollWidth 390 · 溢出 0px`。

**行高为什么大多变矮了:** 那三到六列本来是【常驻】叠在身份格下面的一小块,
现在收进了点一下才展开的那一段。最明显的是报销那张:**196/224px → 81px**,
因为消费日、事由与票据说明都进了展开区。
**两张变高的**是 `MyClaimsPanel`(65→81.5)与培训(57/37→61.5/61):
它们没有可折的列,变高来自字号从 12px 回到 14px、以及内边距换成 C 的 `px-3 py-2.5`。

> ★ 读数有一处我自己先量错了,照直记下来:第一版拿的是每张表**第一个** `<th>/<td>`
> 去读字号 —— 而组件在手机上会**多画一格展开钮**(`w-8 px-1`,没有文字),
> 于是读到的是那一格,不是一个真的内容格。改成"取看得见的、有字的、最长的那一格"
> 之后,`MyClaimsPanel` 的表体才从"14→14"变成真实的 **12→14**。

---

## 7 · ★ 表体 14px vs 手搓表 15px —— 预料之中,报出来,**没有修**

八张表转换后表体**全部渲染 14px**,而 TABLE-STYLE-1 穿上 `tableC` 的那 22 张
渲染 **15px**。委托书预告的就是这一条,而它现在有读数了。

**原因是一个 token:** `table-style.ts` 的 `tableC.cell` 是
`px-3 py-2.5 align-middle text-[15px]`,而 `data-table.tsx:526` 那一段
**没有 `text-[15px]`**,于是表体退回表根 `text-sm` 的 14px。
`table-style.ts` 自己的抬头已经把这处差额写下来了。

**表头那一半已经合上了:** 八张表转换后表头**全部 15px**(其中
`MyLeavePanel:61` 是 12 → 15px,跨度最大)。

**本刀没有碰 `data-table.tsx`** —— 委托书 §5 把它列为"自己的一刀"。
☞ 但请注意这一条现在**看得见了**:同一个 `/me` 页面上没有别的表可比,
可一旦哪一页同时有转换过的表和手搓表,14 与 15 会并排出现。

---

## 8 · 用户看得见的字:**没有新词**;key 用量 176 → 158,逐条对得上

**没有新增、没有改动任何一句用户看得见的话。** 八张表的每一个 i18n key
原样保留,`t()` 的调用形式(含 `` t(`leave.status_${r.status}`) `` 这类动态前缀)
逐字未改。

**字面 `t('…')` 调用数:`app/me/` 176 → 158,少 18。没有一个 key 掉到 0。**
少掉的 18 处**全部是同一件事**:手写的叠加块把列头又写了一遍,而组件的展开区
自己会用列的 `header` 当标签 —— 于是"同一个列头写两遍"变回一遍。

| 表 | 折起来的列数 | 少掉的 `t()` |
|---|--:|--:|
| `MyAttendancePanel:28` | 3 | 3 |
| `MyLeavePanel:61` | 3 | 3 |
| `MyLeavePanel:117` | 2 | 2 |
| `MyExpenseClaimsPanel:129` | 2 | **5** |
| `MyReviewsPanel:82` | 2 | 2 |
| `page.tsx:327` | 3 | 3 |
| **合计** | | **18** |

`MyExpenseClaimsPanel` 少 5 而不是 2,是因为叠加块里连**票据说明**也抄了一份:
`expenseClaims.hasReceipt` ×1 与 `noReceipt` ×2 是那段重复的内容,不是列头。
**两张没有折列的表(claims / training)一处没变** —— 与"它们没有叠加块"一致。

---

## 9 · 我自己拿的主意

**一条是形状,先说它:**

* ★ **`app/me/page.tsx` 的两张表搬进了两个新文件**
  (`MyPayslipsTable.tsx` / `MyTrainingTable.tsx`,都是 `'use client'`)。
  **这不是风格选择,是转换在这个文件上的唯一走法:** `page.tsx` 是
  server component(`export default async function`,await supabase / cookies),
  而列描述符带 `render: (row) => ReactNode` —— **函数过不了 server→client 的边界**,
  留在原地【编译不过】。
  **而它也不是我发明的形状:** 全库 131 个表格组件调用点,**client 组件 100%**;
  同一个模块里就有先例(`app/hr/leave/LeaveRequestsTable.tsx`),
  连"行在服务端压平再过界"这一条也有(`app/hr/leave/[id]/page.tsx:68` 的注释
  写的正是这件事)。**照抄了那个形状,没有另起一种。**

**其余是细节:**

* **日期与金额仍然在服务端格式化**,过界的只有已经格好的字符串。
  把 `toLocaleDateString` 挪到客户端会让 SSR 与水合可能给出两种字,那会改变屏幕上的字。
* **`MyLeavePanel` 的 `Breakdown.grant_id` 类型从 `string` 改成 `string | null`** ——
  它一直就是可空的(`leave_balance_internal.sql:76` 给派生累积那一行填的是 NULL),
  类型写错了。`rowKey` 相应写成 `grant_id ?? \`accrual-${leave_year}\``:
  转换前那里是 `key={null}`,React 退回按位置认行。**只改键,不改任何看得见的东西。**
* **工资条的 `rowKey` 同理**:`payroll_lines_masked` 是视图,生成的类型把 `id` 记成
  `string | null`,所以写了 `l.id ?? \`payslip-${i}\`` 的下标兜底。
* **`MyReviewsPanel` 的 `align-top` 从 `<tr>` 搬到了每一列的 `className`**:
  组件的格子钉死 `align-middle`,而 `cn()`(twMerge)把调用方排在最后。
  不搬,那张表的多行目标文字会和右边两个数字错开 —— `align-top` 当初就是为这个写的。
* **`MyExpenseClaimsPanel` 里 `withdrawControl` 上方那段注释改了**:它说的
  "同一颗钮要在两个断点各画一次"在 TABLE-STYLE-1 之后已经不成立。

---

## 10 · Tim 该在哪里走一遍

**两个宽度都走 `/me`:390px 与桌面。**

★ **而这一页需要一个【有东西】的账号,别走空页。** 需要的状态:
一个**已经关联员工档案**(`employees.user_id` = 该 auth 账号)的人,并且他名下有
**假期授予与假期申请**(上下两张表)· **医疗报销** · **一般报销**(至少一笔
`status='submitted'` 的,否则撤回钮不画)· **工资条**(`payroll_lines`)·
**培训记录** · **一次 approved 的评估和它的目标**。
少哪一样,对应那张表就只显示空态那一句 —— 那不是缺陷,但也验不到东西。

**逐处要看的:**

1. **390px,六张有折列的表**:身份列 + 那个要紧的数 + 状态还在明面上;
   右边那颗 `›` 点开,折起来的几列带着各自的列头出现。
2. **390px,报销那张**:**撤回钮应当直接够得着**,不需要先点开一行。
3. **390px,假期那两张**:余额表上「剩余」要在;申请表上「天数」要在。
4. **桌面**:六列/五列/四列全部回来,顺序与转换前一致。
   ☞ **桌面这一遍我【没有量】** —— 见 §11。
5. **顺手看一眼字号**:表头 15px 已经到位;**表体仍是 14px**(§7),
   与手搓表的 15px 有一个 token 的差 —— 那是登记在案的另一刀,不是这次的疏漏。

---

## 11 · 我【没有】验证的东西 —— 说白

* ★ **真的 `/me` 这条路由,一次都没有渲染过。** 上面所有读数来自一条一次性的
  量测路由 + 我编的假数据。**"这一页在真实数据下会不会溢出"是未测量,不是没问题** ——
  真实的事由、备注、描述比我编的长,而长文本正是把列撑宽的那种东西。
* ★ **桌面宽度一次都没量。** 全部读数都在 390×844。桌面上"六列全回来、顺序不变"
  是**读源码**得出的,不是读屏幕得出的。(组件对非 priority 列用的是
  `hidden sm:table-cell`,那条路有 123 个既有调用点在走,所以风险低 —— 但低不等于量过。)
* **只走了英文档。** 读数里的列头是 EN;中文档没有单独量,而中文字宽不一样。
* **`MyLeavePanel:61` 那个 `table.empty` 的样子没有看过** —— 它是推出来的
  (读了 `leave_balance_internal.sql` 判定那个状态够得着),没有渲染出来看。
* **没有跑 `scripts/survey-variant-c.mjs` 的 drift 模式。** 它只走静态路由清单,
  而这八张表在 `/me` 上,渲染不出来(§6.1)。所以本刀用的是自己那支一次性量具,
  量法不同,**不要把这里的数直接并进那支的读数**。
* **没有量任何 EditableTable 那一侧**,也没有碰其余七刀里的任何一张表。
* `check-datatable-phone` 报的那一处"静态读不出"
  (`app/me/MySelfAssessmentPanel.tsx:184`)**是本刀开工前就有的**,那个文件本刀一个字没动。

---

## 12 · 收工

* **含闸** `python3 db/gate.py`(经 `db/run_detached.sh`,判词只取日志自报那一行):
  **`GATE_EXIT=0`**,墙钟 **431s**(`17:00:57Z` → `17:08:08Z`,在 180–700s 窗口内,
  不需要放宽;闸自己报的三判词墙钟是 321s)。四条判词原文:

  ```
  判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
  判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
  判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
  判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
  ```

* **构建** `npm run build`:**`BUILD_EXIT=0`**(40s)。

  ```
  ── eslint 冻结闸 ─────────────────────────────────────────────
  基线  error 42 · warning 88
  现在  error 42 · warning 88

  ✓ 没有新增的 eslint 问题。
  ```

  元检查那一行原文:

  ```
  ✓ check-instrument-selfproof:33 支量具都写了瞄准线;其中 22 支(构建链里的,含本支)都带着覆盖断言。
  ```

  cellfont 那一维原文:

  ```
     基线:118 个文件在册。本次扫到 405 处。
     分账:标签上 112 处(<table>/<th>/<td>) · 列描述符里 293 处(className: '…')。
  ✓ 没有新增的格子钉死的字号(<table>/<th>/<td> 标签 + 列描述符的 className)。
  ```

* **一次性账号:干净。** 四次量测各建一个 `tc1probe-*@test.local` admin,
  **四次都自己删掉了**;收工时 `npm run reap:ephemeral` 报
  「没有滞留的清理计划」,线上按 `tc1probe`/`stylec` 前缀查**一个残留账号都没有**。
* **量测路由 `app/tc1probe/` 已删**,不在这次提交里。
