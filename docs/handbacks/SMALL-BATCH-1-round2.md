# SMALL-BATCH-1 交回报告 —— 四件小事并成一刀

> **本刀没有版本号。** Tim 压着版本线,等手搓表格手机档一起发一个号,两刀共用。
> 队列条目与本报告都不写版本行。

> ★★【一句话读完本刀:**它做完了三件、读回一件、登记四件,而其中两件的
> 前提被本刀自己的测量证伪了** —— 「整个系统按中文排」是假的,「期间锁仍然静默」
> 也是假的。两处证伪都在停止闸上发生,Tim 据此重裁了范围,本报告按新范围写。】★★

---

## 1 · 现场

| | |
|---|---|
| 分支 | `main` |
| 开工时树 | **干净**(`git status --porcelain` 空) |
| HEAD before | `e848965fe9690369651e32c0345f73bd5727bf3f` |
| `origin/main` before | `e848965fe9690369651e32c0345f73bd5727bf3f`(**相等**) |
| HEAD after | 见 §11 |

委托书写的 `e848965` **这一次是对的** —— 上一份委托书的 `77586ea` 过期一格,
本份没有。照旧量了才说。

---

## 2 · 第 2 件 · `STATE_FIELD` 的词表

### 2.1 四个桶,前后各一次,各带脚本自己的退出码

| | ① 权限×状态 | ② 纯状态 | ③ 纯权限 | ④ 掺第三种 | **脚本自己的退出码** |
|---|---|---|---|---|---|
| **BEFORE**(`e848965`) | 3 | 43 | 1 | 4 | **0** |
| **AFTER**(本刀) | **3** | **48** | **1** | **4** | **0** |

BEFORE 与 ALERT-2d 的收工数逐格吻合,所以两次跑的是同一棵树。

★ **桶 ①/③/④ 的【成员清单】与 BEFORE 逐行相同** —— 不是"数相同",是拿 `--list`
把清单 diff 过,输出是空的。**所以 PIECE 2 的待修清单一件都没有变。**

### 2.2 判据改了什么

`\b(…)\b/i` → **先把驼峰摊成下划线并转小写,再用一条「下划线/`.` 都算分隔符」的边界**。
`reviewType` 以 `review_type` **逐个具名**进词表;**裸词 `type` 刻意没有收**。

### 2.3 新看见的 5 处 —— **一处都没有修(量不是修)**

| 站点 | 表达式 | 判 |
|---|---|---|
| `app/finance/bank/statements/[id]/reconcile/ReconcileWorkspace.tsx:124` | `l.match_status === 'unmatched'` | 真 |
| `app/finance/processing-costs/CostSettlePanel.tsx:180` | `payStatus === 'unpaid'` | 真 |
| `app/finance/processing-costs/CostSettlePanel.tsx:181` | 同上(相邻那条链) | 真 |
| `app/hr/employees/actions.ts:70` | `!statusChanged` | 真 |
| `app/hr/training/TrainingForm.tsx:41` | `!!lockedEmployeeId` | **假阳性,见 §8** |

**5 处全部落在桶 ②(不在范围内)。** 本刀没有碰其中任何一处的代码。

### 2.4 ★ 裸词 `type` 为什么没有收 —— 停止闸上量出来的代价

加一个裸 `type`:桶 ① 3 → 4,而多出来的那一处**不是 `reviewType`**,是
`app/tools/reminders/page.tsx:188` 的
`armAllowed.get(r.itemType) && (byType.get(r.itemType)?.length ?? 0) === 0`。
`itemType` 是**提醒臂的种类判别器**,`.length === 0` 是**空表判断** —— 而普查自己的
抬头把 `rows.length > 0` 逐字列为桶 ④ 的样板。
☞ **那个裸词会把一处本来正确坐在桶 ④ 的站点,提升进【在范围内】的桶 ①** ——
也就是往下一刀的待修清单里塞进一件不是缺陷的东西。
★ **同一个 `itemType`,同一个「词收得太泛」的病,这是第二次**(第一次:
`NARROW-COVERAGE-1 ⑬`,独立计数把 `itemType: string` 这条**类型声明**也数了进去)。

### 2.5 ★★ 一次致盲,而它证明了【总数对不上任何事】★★

把归一化那一步(驼峰摊平 + 转小写)摘掉、判据其余不动,再跑:

> **四个桶的数一模一样:① 3 · ② 48 · ③ 1 · ④ 4。而成员换了两处。**
>
> · **少了两处真的**:`CostSettlePanel.tsx:180`/`:181`(不摊平就没有小写的 `status` 可认);
> · **多了两处假的**:`HoldReleaseControls.tsx:85`/`:119` 的 `holdBlocked !== null`
>   —— `holdB|locked` 里那个**大写 `B` 当了左边界**,于是 `locked` 被认了出来。
>   摊平之后它是 `hold_blocked`,`locked` 根本不存在。

☞ **一次只看总数的对照会把这次致盲判成「没有差别」。**
这正是委托书 §5 点名的那件事:覆盖断言证的是**灵敏度**,不是**瞄准**。
**拿成员清单去对,不要拿数去对。**

### 2.6 量法(在 /tmp,所以方法写在这里)

三支一次性探针,都是把 `scripts/survey-conflated-booleans.mjs` 整份复制、
只改判据那一段,**复制到仓库根跑**(node 的 ESM 解析要在仓库里才找得到
`typescript`;在 `/tmp` 里跑会 `ERR_MODULE_NOT_FOUND`),**跑完立刻删**,
每次都复核 `git status --porcelain` 为空。
`--list` 原样只印桶 1/4/3,所以探针里把桶 2 也印出来才做得成成员差分 ——
**这个改动只在探针里,仓库那一支没有动。**

---

## 3 · 第 3 件 · 排序字序

### 3.1 ★★ 诚实的说法:本刀【钉下了一条已经成立的裁定】,它【没有】修好一个正在错的系统 ★★

按 R-Q1,这句话必须出现在交回报告里,而且它是本节最重要的一句。理由是三条实测:

* 那个写死的 `'zh-Hans-CN'` **只在 `sorting.mode === 'client'` 下求值得到**,
  而全仓 98 个消费方里只有 8 个传 `sorting=`、7 个是 `'server'`,
  **唯一的 `'client'` 是 `app/brand-sampler/Base1.tsx:105` —— 取样页,它自己的抬头
  写着「数据是编的」。**
* **真正在排序的是数据库**(`app/`+`lib/` 413 处 `.order()`,`db/` 864 处 `ORDER BY`),
  而线上库 `datcollate = en_US.UTF-8`,`db/` 里没有任何列级 `COLLATE`。
  实测同一组样本:Postgres 与 Node 的英文序**逐字吻合**
  (`Alpha | beta | 张三 | 李四 | 陈一`);`zh-Hans-CN` 则是
  `陈一 | 李四 | 张三 | Alpha | beta`。
* **导出走的就是屏幕那条路**:`app/suppliers/export/route.ts` 与列表页共用
  `supplierQuery.ts`,`applySupplierFilters` 的最后一句就是 `.order(sort, …)`;
  materials / customers 同一形状。

☞ **所以裁定在真正排序的那一层今天就已经生效。** 本刀做的是把它**写下来**,
并关掉两个反例。**不要把本刀读成一次修复。**

### 3.2 规矩住在哪:`lib/sortCollation.ts`

导出 `SORT_COLLATION = 'en'` 与 `compareForSort(a, b, options?)`。
**抬头逐字如下**(节选那三段承重的):

> ★★【规矩本身:排序【永远】用英文字序,与界面语言无关】★★
> Tim 的裁定(COPY-1-SORT-COLLATION):**不论界面是中文还是英文,排序都用英文字序。**
>
> 【为什么是这一条,而不是"跟着界面语言走"】
> 这是一套**多人共用**的系统。六个人隔着桌子互相说「第三行」「某某上面那个」;
> 而一份导出的文件必须与**发信人屏幕上看到的顺序**一致 —— 否则收件人按行号
> 回话时,两个人说的根本不是同一行。**一致性压过舒适度**,这是裁定的全部理由。
>
> 【它的代价,Tim 已经接受,写在这里免得被当成缺陷"修"掉】
> 中文名字会按字符编码排 —— 那既不是拼音序,也不是笔画序,对中文读者不说明任何事。
>
> ★★【为什么写成一个具名标识符,而不是一句"跟着英文界面走"】★★
> 后者会在将来某一次改【英文界面行为】的刀里**被顺手一起改掉** —— 而这条规矩
> 与界面语言这件事**没有关系**。☞ **改英文界面的那一刀:这里不归你。**
>
> ★★【不给 locale ≠ 英文。不给 locale = 【运行时默认】,而它会跟着部署环境变。】★★
> 实测(2026-09-09,本机):`Intl.Collator().resolvedOptions().locale` = `en-SG`,
> 它排出来的顺序与 `en-US` 逐字相同 —— **所以那些不给 locale 的站点今天是对的,
> 而它们是【碰巧】对的。**

★ `compareForSort` 的 `options` **刻意不给默认值**:表格那一处本来就带
`{ numeric: true }`,其余五处本来就没有。**悄悄给所有人加上 `numeric` 会让
"item2 / item10" 的顺序在五张屏幕上一起变,而走查说不清那是字序改的还是数字序改的。
这一刀只改字序。**

### 3.3 现在指着它的站点

| 站点 | 原来 | 现在 |
|---|---|---|
| `app/components/ui/data-table.tsx:310` | `localeCompare(…, 'zh-Hans-CN', { numeric: true })` | `compareForSort(…, { numeric: true })` |
| `app/inventory/page.tsx:252` | `localeCompare(…, 'zh-CN')` | `compareForSort(…)` |
| `app/hr/kpi/score/page.tsx:134` | `localeCompare(…)` ×2(无 locale) | `compareForSort(…)` ×2 |
| `app/hr/kpi/score/page.tsx:145` | `localeCompare(…)`(无 locale) | `compareForSort(…)` |
| `app/tools/calendar/sources.ts:228` | `label.localeCompare(…)`(无 locale) | `compareForSort(a.label, b.label)`(`date` 那一半没动,它是 ISO) |
| `lib/orgTree.ts:220` | `localeCompare(…)` ×2(无 locale) | `localeCompare(…, ORG_SORT_COLLATION)` ×2 —— **见 §3.4** |

### 3.4 ★ `lib/orgTree.ts` 不能 import 那条规矩 —— 一条结构限制,本刀第一次把它写下来

**第一次构建是红的**(`BUILD_EXIT=1`),错误是
`ERR_MODULE_NOT_FOUND: Cannot find package '@/lib' imported from lib/orgTree.ts`。
查下去,它不是我写错了 import,是一条**没有人写下来过的不变量**:

* `lib/orgTree.ts` 被 `scripts/check-org-tree.mjs` 用**裸 node** 直接加载
  (`import … from '../lib/orgTree.ts'`)。
* 两个加载器要的东西**是打架的**:node 的类型剥离要求相对路径**带 `.ts` 后缀**
  (实测可行);而 `tsc` 在没有 `allowImportingTsExtensions` 时**拒绝**带后缀的路径
  (实测:`error TS5097`)。`@/…` 那个别名 node 根本不认。
* ☞ **这就是为什么被检查脚本直接加载的那四个 lib 文件
  (`orgTree` · `nearDuplicate` · `homeGreetingCore` · `pMap`)一个 import 都没有。**
  逐个查过,四个都是零 import。**本刀把这条不变量写进了 `orgTree.ts` 的抬头。**

**处置:** 保住零 import,把字序写成本地常量 `ORG_SORT_COLLATION = 'en'` 并**导出**;
然后在 `scripts/check-org-tree.mjs` 里**同时** import 副本与正本,不相等就红 ——
那是本仓库既有的「两条独立路互相钉住」的做法,而 `check-org-tree.mjs`
**是全仓唯一同时够得着这两份的地方**。
断言条数按 `selfproof` ④ 那条刻意的摩擦从 38 改成 39。

**这颗钉子做过故障注入,而它咬住了:**

| 臂 | `check-org-tree.mjs` 自己的退出码 | 它说了什么 |
|---|---|---|
| 把 `ORG_SORT_COLLATION` 改成 `'zh'` | **1** | `scripts/check-org-tree.mjs:217:1 ⑪ 排序字序:orgTree 的副本 == lib/sortCollation.ts 的正本 —— orgTree=zh sortCollation=en` |
| 改回 `'en'` | **0** | ✓ |

### 3.5 刻意【没有】改的,以及理由

* **其余 10 处 `localeCompare`** —— 排的是 ISO 日期 / 分录号 / 科目码 / 币种码 /
  工号 / `period_month`,**全是 ASCII,字序无关**。改它们不会改变任何一个字节的输出,
  而**一次不改变任何输出的改动是最难走查的**。
  逐处:`tools/tasks/[id]/actions.ts:112,113` · `me/page.tsx:195` ·
  `inventory/reports/snapshot/snapshotQuery.ts:97` · `hr/attendance/[id]/page.tsx:60` ·
  `hr/payroll/[id]/page.tsx:69` · `hr/leave/page.tsx:69` ·
  `hr/employees/[id]/page.tsx:124` · `finance/payments/new/NewPaymentForm.tsx:257`
  (币种码 SGD/USD)· `finance/bank/.../ReconcileWorkspace.tsx:138` · `lib/orgTree.ts:230`。
* **`finance/journal/export/route.ts:85-87`** —— 已另立条目 `JOURNAL-EXPORT-JS-SORT`,
  带着它那条**会过期**的前提。
* **全仓那一批 `locale === 'zh' ? 'zh-CN' : 'en-US'`** —— 那些是
  `toLocaleDateString` / `toLocaleString`,**日期与数字的格式**,不是字序。
  **格式本来就该跟着界面语言走**,它们不在这条裁定的射程内。
* **`app/brand-sampler/Base1.tsx:41` 的 `toLocaleString('zh-Hans-CN')`** —— 同上,
  是数字格式,而且那是取样页。

---

## 4 · 第 4 件 · 期间锁那五句

### 4.1 强制那一侧本来就带着两个日期

`db/functions/assert_posting_allowed.sql` 的 `locked_before` 支:
`RAISE EXCEPTION 'PERIOD_LOCKED|%|%', p_entry_date, v_locked;`
→ `{0}` = 试图落的日期,`{1}` = 锁定日。**掉的是句子,不是数据。**

### 4.2 改了五个命名空间,**四个已经说出锁定日的一个字都没碰**

**没碰的四个**(`finance.errors` · `expense.errors` · `hr.errors` · `assay.errors`)——
改动前后逐字比对过,**byte 相同**。

### 4.3 权限那一问题

**没有碰。** Tim 已裁定 Choo Er 可以改那个字段,该问题关闭。
本刀没有提议收窄、没有新建权限码、没有重提。

---

## 5 · 每一句新的/改过的用户可见文案,逐字,中英并排,按屏幕分组

> 五句,五个命名空间,中英各五。**`{0}` = 你填的那个日期,`{1}` = 锁定日。**

### 5.1 预提税(`wht.errors.PERIOD_LOCKED`)· 屏幕:`/finance/wht`

| | |
|---|---|
| **EN 原** | `That accounting period is closed ({0}).` |
| **EN 新** | `That accounting period is closed — {0} is before the lock date {1}.` |
| **ZH 原** | `该会计期间已关账({0})。` |
| **ZH 新** | `该会计期间已关账 —— {0} 早于锁定日 {1}。` |

### 5.2 凭证包(`pack.errors.PERIOD_LOCKED`)· 屏幕:`/finance/packs`

| | |
|---|---|
| **EN 原** | `That accounting period is closed ({0}).` |
| **EN 新** | `That accounting period is closed — {0} is before the lock date {1}.` |
| **ZH 原** | `该会计期间已关账({0})。` |
| **ZH 新** | `该会计期间已关账 —— {0} 早于锁定日 {1}。` |

### 5.3 贷项凭证(`cn.errors.PERIOD_LOCKED`)· 屏幕:`/finance/invoices/[id]` 上开贷项凭证

**★ 这一句此前【一个日期都没有】。**

| | |
|---|---|
| **EN 原** | `That period is closed, so nothing was posted. Use a date in an open period, or reopen the period first.` |
| **EN 新** | `That period is closed, so nothing was posted: {0} is before the lock date {1}. Use a date in an open period, or reopen the period first.` |
| **ZH 原** | `那个会计期间已经关账,所以什么都没过账。请用一个未关账期间的日期,或者先重开那个期间。` |
| **ZH 新** | `那个会计期间已经关账,所以什么都没过账:{0} 早于锁定日 {1}。请用一个未关账期间的日期,或者先重开那个期间。` |

### 5.4 货运(`finance.freight.errors.PERIOD_LOCKED`)· 屏幕:`/finance/freight`

| | |
|---|---|
| **EN 原** | `That period is closed ({0}).` |
| **EN 新** | `That period is closed — {0} is before the lock date {1}.` |
| **ZH 原** | `该期间已封账({0})。` |
| **ZH 新** | `该期间已封账 —— {0} 早于锁定日 {1}。` |

> ★ 这一处保留它自己的动词「封账」,没有拉平成其余几处的「关账」——
> **统一动词是一次文案清扫,不是本刀的范围**,而顺手改会让走查说不清它看见的是什么。

### 5.5 发票(`invoice.errors.PERIOD_LOCKED`)· 屏幕:`/finance/invoices/new`

| | |
|---|---|
| **EN 原** | `That date falls in a locked period ({0}). Pick a date in the open month, or reopen the period first.` |
| **EN 新** | `That date falls in a locked period: {0} is before the lock date {1}. Pick a date in the open month, or reopen the period first.` |
| **ZH 原** | `这个日期落在已锁期间({0})。选开放月份里的日期,或先重开那个期间。` |
| **ZH 新** | `这个日期落在已锁期间:{0} 早于锁定日 {1}。选开放月份里的日期,或先重开那个期间。` |

> **没有别的用户可见文案被本刀新增或改动。** 第 3 件一个字都没改文案
> (它只改比较函数);第 2 件改的是一支普查脚本,不上屏。

---

## 6 · 队列 · 五条,每条都记着它的数从哪来

1. **`NARROW-COVERAGE-2 ①`** —— 正文**原样保留**,底下加一整块 `☞ SMALL-BATCH-1 实测`
   (与 `known-issues.md` ⑤–⑧ 同一条房规)。里面装着:分桶数的**取代**与**成因**
   (BEFORE/AFTER 两行 + 各自的退出码 + "桶 ①③④ 成员清单逐行相同")·
   新看见的 5 处按名 · 裸 `type` 的代价与 `itemType` 第二次 ·
   那处已知假阳性 · **§2.5 那次致盲** · **R-Q8 的出处不明表** ·
   以及「那两处源码注释没有动,因为它们是 ALERT-2d 的病历」。
   标题改成「① 已由 SMALL-BATCH-1 做掉,②③④ 仍开着」,触发条件同步。
2. **`COPY-1-SORT-COLLATION`** —— 关闭。三条勘察结论各带证据,
   并把 §3.1 那句诚实的话写进条目本身:**这一刀钉的是一条已经成立的裁定。**
   带着「32 行主数据里 1 行有汉字」这个数,以及它指向的下一个时刻(批量导入)。
3. **`COPY-MONTHEND-FILTER-KEY`** —— **新立**。记着它此前**两次登记都没进队列**
   (`docs/btn4-handover.md:122-123` 与 `docs/base-components.md:1362`),
   记着 Tim 的裁定(走 (甲):`finance.monthEnd.*` 下新开自己的键),
   记着**为什么不折进本刀**(本刀已在改一批文案,混进来走查就说不清)。
4. **`PERIOD-LOCK-RAW-CODE`** —— **新立**。42 支 `*ErrorCodes.ts` / 11 支带 / 31 支不带 /
   38 支写分录的函数,**外加那条已确认的真路**
   (`month-end/actions.ts:64,85` → `operation/errorCodes.ts` 不带码 →
   `remit_processing_costs.sql:50` 用人填的日期 → 屏幕上出现
   `PERIOD_LOCKED|2026-07-15|2026-08-01`)。并写明本刀已经做掉的那一半,免得重做。
5. **`JOURNAL-EXPORT-JS-SORT`** —— **新立**,带着**会过期的前提**:
   今天不咬人**只因为被排的三列全是 ASCII**,「第一次给它加一列人读的字」就是触发条件。
6. **`SMALL-BATCH-1` 自己那一条** —— 在关闭它的这次提交里写进队列,四件事各一行,
   并记下本刀两次被自己的测量改了形状。

---

## 7 · 本刀自己裁掉的(都是细节,不是形状)

* 三支一次性探针复制到仓库根跑、跑完立刻删,每次复核树干净(§2.6)。
* 探针里给 `--list` 加印桶 2 才做得成成员差分 —— **仓库那一支没有动**。
* `lib/orgTree.ts` 的处置(§3.4):零 import 不变量 + 导出副本 + 在
  `check-org-tree.mjs` 里钉住。**替代方案是把字序在那里再写一遍而不钉** ——
  那会造出第二个事实;也考虑过开 `allowImportingTsExtensions`,
  但那是一个动全仓 tsconfig 的改动,不该由一刀小活顺手做。
* `finance.freight` 的「封账」没有拉平成「关账」(§5.4)。
* 线上只跑只读查询(库字序、CJK 计数、锁定日、单据 id),**没有写**。
* **没有碰任何一张手搓表格**(委托书 §4 要求碰了要说)。**一张都没碰。**

---

## 8 · 本刀找到、按名登记、【没有修】的窄覆盖实例

1. **`app/hr/training/TrainingForm.tsx:41` —— 一处假阳性。**
   `!!lockedEmployeeId` 被认成 STATE。那个 `locked` 是真的那个词,
   但它说的是「员工这一格是钉住的」(从某位员工页进来的),**不是一条记录被锁**。
   ☞ **这是语义,不是词法** —— 判据分不开它,而为一处观察去特判一个词,
   正是本仓库禁止的「给阈值编一个出处」。它落在桶 ②(不在范围内),
   **所以它不会被塞进任何人的待修清单。** 已写进脚本抬头与队列。
2. **`scripts/check-org-tree.mjs` 之外的三个零 import lib 文件**
   (`nearDuplicate` · `homeGreetingCore` · `pMap`)—— 它们受同一条结构限制,
   而**在本刀之前没有任何地方写下过这条不变量**。本刀把它写进了 `orgTree.ts` 的抬头;
   另外三个**没有加注释**(它们今天不需要 import 任何东西,加一段解释等于
   为一个不存在的问题写文档)。**登记在这里,免得下一个人重新踩一次构建红。**
3. **`PERIOD-LOCK-RAW-CODE` 的 31 支** —— 见 §6 第 4 条,已按名立条目。

---

## 9 · Tim 怎么走这一刀 —— **以及哪些部分【根本看不见】**

> ★★ 先说看不见的那一半,因为它比看得见的那一半大。★★

### 9.1 ★ 排序:今天几乎【看不见任何变化】,而这是预期,不是失败

线上可排序主数据里带汉字的名字:`suppliers` **0/16** · `customers` **1/7** ·
`materials` **0/9** —— **32 行里 1 行**。而那 1 行是
`ZZ-SMOKE-CJK` / **上海金属回收有限公司**(`ZZ-` 前缀,是冒烟留下的行)。

**唯一看得见的一处,而且它证明的是「没变」:**
* 打开 **`/sales/customers`**,按 **Name** 那一列排序(升序)。
* **要读到的:上海金属回收有限公司 排在【最后】**,在 `ZZ2B Customer 2` 后面。
  那是英文字序(汉字排在拉丁字母之后)。**中文字序下它会排在第一个。**
* **角色:** 任何能看客户列表的人(`module.sales.view`)。
* ☞ 这一页是 `mode: 'server'`,**排序是数据库做的** —— 所以它证明的正是 §3.1
  那句话:**裁定在真正排序的那一层本来就已经成立。本刀没有改这一页的行为。**

**真正被本刀改了行为的那两处,今天都看不出来:**
* `/inventory` 的物料名排序 —— **9 个物料 0 个带汉字**,换字序顺序不变。
* `/brand-sampler` 的表格 —— 那是取样页,数据是编的。

☞ **所以这一件的走查结论只能是"没有东西坏掉",不可能是"我看见它变好了"。**
它的价值在批量导入真实中文主数据那一天才看得见。

### 9.2 期间锁的五句 —— **线上今天就有那个状态,不需要造数据**

**已读到的线上状态(只读查询):`finance_settings.locked_before = 2026-08-01`。**
所以任何早于 2026-08-01 的单据日期都会被拒。

**最短的一条路(走 §5.5 那一句,发票):**
1. 以带 **`module.finance.edit`** 的账号(Choo Er 或 Tim)打开 **`/finance/invoices/new`**;
2. 把 **Issue date 填成 `2026-07-15`**(任何 2026-08-01 之前的日子都行),其余照常填;
3. 提交。
4. **要读到的(英文界面):**
   `That date falls in a locked period: 2026-07-15 is before the lock date 2026-08-01. Pick a date in the open month, or reopen the period first.`
   **中文界面:**
   `这个日期落在已锁期间:2026-07-15 早于锁定日 2026-08-01。选开放月份里的日期,或先重开那个期间。`
   ☞ **要看的就是 `2026-08-01` 这个数出现在句子里** —— 改动之前它不在。

**第二条路(走 §5.3 那一句,贷项凭证 —— 那一句此前【一个日期都没有】):**
1. 打开 **`/finance/invoices/afe48c8d-c637-4608-84c8-14a479a4b6ee`**
   (`INV-2026-0009`,`issued`,开票日 2026-08-26);
2. 开一张贷项凭证,**日期填 2026-07-15**;
3. **要读到的:** 那句话现在带着 `2026-07-15` 与 `2026-08-01` 两个日期。

**另外三句(预提税 `/finance/wht` · 凭证包 `/finance/packs` · 货运 `/finance/freight`)**
形状相同,都要一个早于 2026-08-01 的日期。**如果这三条路今天没有可用的单据,
不必造** —— 它们与上面两条走的是同一个 `PERIOD_LOCKED|{0}|{1}`,
上面两条读到了,这三句的参数就是对的。

**如果 `locked_before` 后来被改了,重新读它的只读查询:**

```sql
SELECT locked_before FROM finance_settings;
```

### 9.3 第 2 件(普查脚本)—— **不上屏,没有可走的**

它是一支不在构建链里的普查脚本。要看它,跑:

```bash
node scripts/survey-conflated-booleans.mjs
```

**要读到的:** `① 3 · ② 48 · ③ 1 · ④ 4`,末行 `✓ 覆盖率断言通过`。

---

## 10 · 闸门

### 10.1 `db/gate.py`

| | |
|---|---|
| **脚本自己的退出码** | `GATE_EXIT=0`(从日志里那一行读的,不是启动器的状态) |
| **wall-clock** | **541s**(外层计时);门自己报的是 `425s` |
| **`db/gate.py:38` 的区间** | 180–700s —— **541s 落在区间内,本刀不需要加宽** |

**四条判词,逐字:**

```
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
```

> **本刀没有 SQL,没有迁移。** 镜像那一条判词绿是应该的 —— 它证明的是本刀没有
> 意外碰到库,而不是本刀改对了库。

### 10.2 `npm run build`

| | |
|---|---|
| **脚本自己的退出码** | `BUILD_EXIT=0` |
| **eslint 冻结线** | `基线  error 42 · warning 88` → `✓ 没有新增的 eslint 问题。` |
| **元检查那一行** | `✓ check-instrument-selfproof:32 支量具都写了瞄准线;其中 22 支(构建链里的,含本支)都带着覆盖断言。` |

★ **第一次构建是红的(`BUILD_EXIT=1`),原因与处置见 §3.4。** 记在这里因为
**一次红了又绿的构建,如果只报最后那次,就把一条刚发现的结构限制藏起来了。**

---

## 11 · 推送与部署

见本节末尾(提交之后补齐)。
