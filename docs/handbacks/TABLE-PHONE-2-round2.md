# TABLE-PHONE-2 —— 钱、只读账簿,5 次判断 / 5 张表 / 4 个文件(交回报告)

2026-09-09。**没有 SQL,没有迁移,没有新的用户可见文案,`messages/` 一个字都没动。**
**没有转换任何一页到 DataTable / EditableTable。没有加 `table-fixed`。没有动桌面档的任何一列。**

---

## 1. HEAD 与树

| | |
|---|---|
| 开工前 HEAD | `fbef9ac739ab75ed381c50128b8f5050f780c9e3` |
| 开工前 `origin/main` | `fbef9ac739ab75ed381c50128b8f5050f780c9e3` |
| 开工前 `git status` | `On branch main` · `nothing to commit, working tree clean` |
| **本刀提交后 HEAD** | 见 §10(推送与部署实测) |

### ★ 委托书写的 `75899e4` 与实测差一个提交 —— 而这一次【不是】停的理由

委托书 §0 说预期 HEAD 是 `75899e4`,实测是 `fbef9ac`。查过了:

```
fbef9ac  TABLE-PHONE-1 交回报告 §11:补齐推送与部署的实测记录 —— 部署 6344829856 success
75899e4  TABLE-PHONE-1:手机档选列首批六次判断、八张表,一个字段都没丢
```

`git merge-base --is-ancestor 75899e4 HEAD` → **是**;`fbef9ac` 只动了
**一个文件、且是文档**(`docs/handbacks/TABLE-PHONE-1-round2.md`,+63/−11)。
**它就是 TABLE-PHONE-1 自己那条"部署要先有提交"的补记**(那一刀 §11 末尾写明了这个办法,
并列了 `df64373` / `75a1122` 两次先例)。

☞ **委托书的停机条件是【树脏】或【HEAD != origin/main】,两条都不成立**
(树干净,两个哈希相等),所以本刀**没有停**。
★ 但这仍然是**第三刀里第二次**委托书上的 HEAD 与实测对不上 ——
根子是同一件事:**交回报告的补记提交发生在委托书写完之后**。
下一份委托书如果照着"上一刀的工作提交"写预期 HEAD,还会差这一个。

---

## 2. ★ 先确认人口 —— 委托书要求的那一步

**批次表(`docs/forward-queue.md:1655`,改前)说的:**

```
| TABLE-PHONE-2 | 钱、且是只读账簿:finance/packs/PackBody.tsx:78,136 ·
  finance/trial-balance:147 · finance/close:253 · me/page.tsx:327(工资条) | 5 张 / 5 |
```

**逐个开文件量到的:**

| # | 位置 | 批次表说 | 实测行号 | 实测列数 | 有没有滚动外壳 / 动过 |
|---|---|---|---|---|---|
| 1 | `app/finance/packs/PackBody.tsx` | `:78`,9 列 | **:78** ✓ | **9** ✓ | 无 `overflow-x` / 无 `sm:hidden` |
| 2 | `app/finance/packs/PackBody.tsx` | `:136`,5 列 | **:136** ✓ | **5** ✓ | 同上 |
| 3 | `app/finance/trial-balance/page.tsx` | `:147`,5 列 | **:147** ✓ | **5** ✓ | 同上 |
| 4 | `app/finance/close/page.tsx` | `:253`,7 列 | **:253** ✓ | **7** ✓ | 同上 |
| 5 | `app/me/page.tsx` | `:327`(工资条),6 列 | **:327** ✓ | **6** ✓ | 同上 |

**五处行号一个不差,列数一个不差,五张都还是没外壳、没动过的。**
另外查过**祖先**(不是只查本文件 —— 那正是 TABLE-PHONE-0 漏掉 12 张的判据错):
`PackBody` 的两个调用方 `app/finance/packs/page.tsx:99` 与
`app/finance/packs/[id]/page.tsx:90` **都没有 `overflow`**。

### 2.1 ★ `trial-balance` 的真列数:**5**

TABLE-PHONE-0 把它标成 **"unparsed: Fragment"** —— 它的行确实从一个 `Fragment` 里出来,
当时那支量具读不进去。**读进去之后,它就是 5 列**:编号 · 科目 · 借方 · 贷方 · 净额。

☞ **那个 `Fragment` 裹的是【按科目类型的分组抬头行】**(一个 `colSpan={5}` 的整行,
`{t('finance.accountType.' + g.type)}`),**不是更多的列**。
**批次表写的 5 是对的,普查那条"读不出"不是"读错了"。**

### 2.2 ★ 第五张:批次表说 `me/page.tsx:327`,而委托书 §2 写的是 `app/hr/payroll/…`

委托书 §2 第 5 条写的是「`app/hr/payroll/…` **the payslip table named in the queue's batch table**」
—— 它把权威**明确交给了批次表**,而批次表点的是 `me/page.tsx:327`。

**本刀做的是 `app/me/page.tsx:327`,理由有两条,不是只有"照批次表办":**

1. `app/me/page.tsx:327` 就是工资条表(6 列:期间 · 应发 · 雇主公积金 · 个人公积金 · 其他扣除 · 实发),**它是批次表点的那一张**。
2. ★ **`app/hr/payroll/PayrollGrid.tsx:202`(7 列)属于【那 9 张已有滚动外壳的表】** ——
   见 `forward-queue.md` 的 `RAW-TABLE-PHONE-WRAPPED` 条目,它列在第一位。
   那一族的状态是 **UNMEASURED**,而委托书 §4 与 §6 都明令**不碰**。
   ☞ **所以两处指向不同不是模棱两可:照 `hr/payroll` 做会正好踩进禁区。**

### 2.3 `app/me/page.tsx` 里的第二张表(`:380`)**没有动**

它是培训表,**3 列** —— 落在普查那 29 张 **≤4 列免修**里,批次表没点它,本刀没碰。
(这与 TABLE-PHONE-1 留下 `MyLeavePanel:117` 是同一条规矩:没点名的不碰。)

---

## 3. 五张表,逐张:改前几列 · 手机留下什么 · 什么叠了进去 · **判断的理由**

**判据(FIX-2b 原话,一路沿用):390px 上读得到的字段数与桌面【完全相同】,变的只是排布。**
**「拿掉」指的是【那一列】,不是【那个事实】** —— 每一条叠进身份格的值都**带着自己的列头**。

### 3.1 `app/finance/packs/PackBody.tsx:78` —— 控制科目勾稽,9 列

| | |
|---|---|
| **手机留下(3)** | 侧别 `pack.colSide` · 差额 `pack.colDifference` · 未解释 `pack.colUnexplained` |
| **叠进「侧别」格(6)** | 控制科目 · 总账口径 · 单据口径 · 起了单但没进总账 · 总账冲了单据没冲 · 汇兑重估 |

> **★ 一行理由:** 这张表存在的理由就是「两边对不对得上、对不上的部分**解释不掉多少**」——
> 差额是那个口子,未解释是那个口子里没人认领的部分,**而「未解释」那一格自己带着红色**
> (`s.reconciled` 驱动 `bg-red-50`),所以状态不在另一列里,**就在那个数上**。

### 3.2 `app/finance/packs/PackBody.tsx:136` —— 拆在两个月的冲销对,5 列

| | |
|---|---|
| **手机留下(3)** | 分录 `pack.colEntry` · 对手件 `pack.colCounterpart` · 金额 `pack.colAmount` |
| **叠进「分录」格(2)** | 日期 · 对手件日期 |

> **★ 一行理由:** 这张表的一行**就是一对**,所以两个单号**一起**才构成身份 ——
> 只留一半的话,剩下那半没有对手,这张表也就没有意义了;金额是它把这个月搅歪了多少。

☞ 两个日期虽然叠了进去,但**它们正是"跨了两个月"这件事本身**,所以本刀在代码注释里
写明了不能再往下砍。

### 3.3 `app/finance/trial-balance/page.tsx:147` —— 试算表,5 列

| | |
|---|---|
| **手机留下(3)** | 编号 `finance.colCode` · 科目 `finance.colAccount` · 净额 `finance.colNet` |
| **叠进「编号」格(2)** | 借方 · 贷方 |

> **★ 一行理由:** **身份在这里占两格是有理由的** —— 一个科目由编号与名字**一起**认出来
> (编号是拿来引用的把手,名字才是它的意思),光留编号就是一串没有主语的数字;
> 而净额**正是借贷两方的差**,所以留它、叠那两个,没有丢掉任何一个事实。

★ 这张表另外三处也按断点写了两份:**分组抬头行**(手机 `colSpan={3}` / 桌面 `colSpan={5}`)、
**空态**(3 / 5)、以及 **`tfoot` 合计行** —— 合计行手机档标签格跨 2 列,
**并把借贷两个合计叠了进来**(照 receivables 小计行的做法),因为"借贷相不相等"正是试算表的用处。

### 3.4 `app/finance/close/page.tsx:253` —— 关账历史,7 列

| | |
|---|---|
| **手机留下(3)** | 期末日 `finance.colPeriodEnd` · 借方 `finance.colDebits` · 状态 `finance.colStatus` |
| **叠进「期末日」格(4)** | 关账时间 · 分录数 · 贷方 · **重开钮**(画出来的) |

> **★ 一行理由:** 关账历史问的是「哪个月关了、锁了多大一笔、**现在还锁着没有**」;
> 一次关账**借贷按构造相等**,所以留一侧就说清了它的大小,贷方与分录数叠进去照样读得到。

### ★★ 3.4a 第七列:桌面档**本来就没有列头** —— 说清楚,但**没有**停 ★★

委托书 §4:「**如果一列因为列头写死而没有 key,说出来并停下**,不要发明一个。」

**本刀查过,这一处【不是】那一类,所以没有停:**

* 那一列在桌面档是 `<th className="border border-gray-300 px-4 py-2 text-left" />` ——
  **一个空的 `<th />`,桌面上就没有字。**
* 「列头写死、没有 key」那一类的毛病是**桌面上有字、而那个字不在语言包里**;
  **这一列桌面上没有字**,所以不存在"要复用哪个 key"的问题,也就不存在发明一个的诱惑。
* 它装的是 `ReopenForm` —— **一个自己带着字的钮**(`finance.reopenButton`)。

**处置:那个钮叠进身份格里【画出来】,不是收进折叠区,也【不另加标签】。**
照的是 TABLE-PHONE-1 在 `/finance/assets` 上的先例:
**一个够不着的重开钮与没有这个钮是同一回事**(DBLOCK-1 的道理用在版式上)。
`PermissionGate`(`module.finance.edit`)与 `ConfirmButton` 的理由输入框**一个字没动**。

☞ **结论:没有新增、没有改动任何一条 i18n key。**(`git diff --stat messages/` 是空的。)

### 3.5 `app/me/page.tsx:327` —— 我的工资条,6 列

| | |
|---|---|
| **手机留下(3)** | 期间 `me.period` · 应发 `me.gross` · 实发 `me.net` |
| **叠进「期间」格(3)** | 雇主公积金 · 个人公积金 · 其他扣除 |

> **★ 一行理由:** **这张表没有状态列**,所以第三格给了第二个要紧的数 ——
> 一个人在手机上翻自己的工资条,问的是「这个月**应发**多少、**真正到手**多少」,
> 两头都要,少一头就没法自己对;中间那三条正是两头之间的明细,叠着照样读得到。

★ 这是本批唯一一张**自助页**上的表,也是唯一一张 `finance` 之外的。

---

## 4. 「一个字段都没丢」—— **量出来的**,而且**看着它红过两次**

量具:`…/scratchpad/tp2/nofieldlost.mjs`,**不在仓库里**(R-Q8)。
**判据:每张表 `手机档画出来的列数 + 叠进身份格的条目数 == 桌面档列数`。**

**方法**(与 TABLE-PHONE-1 那支同源,但多了两件事):

1. **先剥注释,再匹配**(`{/* */}` 与整行 `//`)—— 理由见 §4.2,它是被自己咬出来的。
2. 按**标签深度**取第 n 个 `<table>…</table>`,不靠缩进(`PackBody` 一个文件里有两张)。
3. 列数**两种写法都认**:字面 `<th>` 列表,或 `{ k: 'x', phone: true }` 数组
   (`PackBody` 的抬头是 `.map()` 生成的 —— **只数 `<th` 的量具在这里会读成 1 列**)。
4. 叠加条目数 = 明细行里第一个 `sm:hidden` 折叠块的**直接子 `div`**,按标签深度数。
   **数的是条目,不是标签** —— 一个自己带字的动作钮也算一条(它在桌面档也没有列头)。
5. ★ **多了一条断言:叠加块里【没有标签的条目】直接判红**,
   唯一显式准许的例外是 `/finance/close` 那个重开钮(白名单里写死 1 条,并写明理由)。
   理由是委托书 §2C 那句话 —— **一个没有主语的数字,比那一列原来的样子更糟**。

### 4.1 结果 —— **第一行是校准**

```
✓ REFERENCE (FIX-2b, untouched)      desktop= 8  phone cols=3 + stacked=5 = 8
✓ §2.1  packs 勾稽 (PackBody:78)       desktop= 9  phone cols=3 + stacked=6 = 9
✓ §2.2  packs 冲销对 (PackBody:136)     desktop= 5  phone cols=3 + stacked=2 = 5
✓ §2.3  /finance/trial-balance       desktop= 5  phone cols=3 + stacked=2 = 5
✓ §2.4  /finance/close               desktop= 7  phone cols=3 + stacked=4 = 7   [1 条无标签,准许 1]
✓ §2.5  /me 工资条                      desktop= 6  phone cols=3 + stacked=3 = 6

✓ 5 张表(外加 1 张校准):手机档读得到的字段数 == 桌面档,一列都没有丢。
VERIFY_OWN_EXIT=0
```

★ **第一行是【没有动过的】 `/finance/payables`** —— 拿一张已知合格的表校准这支量具,
它报 `8 = 3 + 5`,与 FIX-2b 当初做的一致。**校准不过,后面五行不值一看。**

### 4.2 ★★ 它自己先【绿错了一次】—— 这一段比上面那六行要紧 ★★

**第一版没有剥注释。** 本刀在 `/finance/close` 的抬头注释里写了一句
「(空的 `<th />`)」来解释第七列 —— 那个 `<th />` **被量具当成了第八列**。
于是它当时印的是:

```
✓ §2.4  /finance/close               desktop= 8  phone cols=4 + stacked=4 = 8
```

**绿的。** `8 == 4 + 4` 对得上 —— 而 `/finance/close` **只有 7 列**,
那两个 8 和那个 4 全是错的。

☞ **一条在【错的数】上对上的等式,和一条没有断言,值一样。**
☞ 这是 **CONV-8 那条具名教训的第五次**(前四次记在 known-issues 的 `RAW-TABLE-PHONE-SWEEP` §二,
那里写的解药就是"先剥注释再匹配")。**已把这一次也记进那一条。**
剥注释之后它才印出真话:`desktop=7  phone cols=3 + stacked=4 = 7`。

### 4.3 ★ 它证明过自己会红 —— **两次,两种红法**

**红法一:整条删掉一个叠加条目**(从 trial-balance 的折叠块里删掉「贷方」那一条)

```
✗ §2.3  /finance/trial-balance       desktop= 5  phone cols=3 + stacked=1 = 4
     stacked items: finance.colDebits
     ↑ 数对不上:3 + 1 != 5 —— 有字段在手机上丢了
✗ 1 张表对不上 —— 有字段在手机上丢了。
VERIFY_OWN_EXIT=1
```
**还原后 `VERIFY_OWN_EXIT=0`。**

**红法二:只拿掉标签,值留着**(工资条折叠块里删掉「个人公积金」那个 `<span>`)
—— 这一种**上一版量具抓不到**,是本刀新加的那条断言抓的:

```
✗ §2.5  /me 工资条                      desktop= 6  phone cols=3 + stacked=3 = 6   [1 条无标签,准许 0]
     stacked items: me.employerCpf | (无标签) | me.deductions
     ↑ 1 条叠加值没有列头(只准许 0 条)—— 数字失去了主语
✗ 1 张表对不上 —— 有字段在手机上丢了。
VERIFY_OWN_EXIT=1
```
**还原后 `VERIFY_OWN_EXIT=0`。**

**两次都点了名、列出了活着的标签(于是缺的那条认得出来),然后还原,退回 0。**
注入与还原之后 `git status --porcelain` 只剩本刀该动的那几个文件,没有残留。

---

## 5. 每一条用户可见的字 —— **一个新字都没有**

**`git diff --stat messages/` 是空的(0 行)。** 本刀没有加、没有改、没有删任何一条文案。
叠进身份格的每一条标签,用的都是**那一列自己原来的列头 key**,
所以中英两份**自动跟着已有翻译走**。

**下面是【被复用的 key】及其今天的中英文** —— 全部**未改动**,
列在这里是为了让走查的人知道手机上该看见什么字。
(这两列是拿仓库自己的 `scripts/check-i18n.mjs` 那支 loader 读出来的,不是手抄的。)

### `PackBody:78` 控制科目勾稽(叠进「侧别」格)
| key | EN | ZH |
|---|---|---|
| `pack.colControl` | Control account | 控制科目 |
| `pack.colLedger` | Per the ledger | 总账口径 |
| `pack.colSubledger` | Per the documents | 单据口径 |
| `pack.colOrigination` | Raised but not posted | 起了单但没进总账 |
| `pack.colSettlement` | Applied in the ledger, not against a document | 总账冲了、单据没冲 |
| `pack.colRevaluation` | FX revaluation (ledger only) | 汇兑重估(仅总账) |

*(手机档留在列上的三条:`pack.colSide` Side/侧别 · `pack.colDifference` Difference/差额 ·
`pack.colUnexplained` Unexplained/未解释。)*

### `PackBody:136` 冲销对(叠进「分录」格)
| key | EN | ZH |
|---|---|---|
| `pack.colDate` | Date | 日期 |
| `pack.colCounterpartDate` | Counterpart date | 对手件日期 |

*(留在列上:`pack.colEntry` Entry/分录 · `pack.colCounterpart` Counterpart/对手件 ·
`pack.colAmount` Amount/金额。)*

### `/finance/trial-balance`(叠进「编号」格,合计行同样复用这两条)
| key | EN | ZH |
|---|---|---|
| `finance.colDebits` | Debits | 借方 |
| `finance.colCredits` | Credits | 贷方 |

*(留在列上:`finance.colCode` Code/编号 · `finance.colAccount` Account/科目 ·
`finance.colNet` Net/净额。)*

### `/finance/close`(叠进「期末日」格)
| key | EN | ZH |
|---|---|---|
| `finance.colClosedAt` | Closed at | 关账时间 |
| `finance.entriesCount` | Entries | 分录数 |
| `finance.colCredits` | Credits | 贷方 |

*(留在列上:`finance.colPeriodEnd` Period end/期末日 · `finance.colDebits` Debits/借方 ·
`finance.colStatus` Status/状态。第四条叠加项是那个重开钮,**它没有标签,而它在桌面档也没有** ——
钮面上的字走既有的 `finance.reopenButton`。)*

### `/me` 工资条(叠进「期间」格)
| key | EN | ZH |
|---|---|---|
| `me.employerCpf` | Employer CPF | 雇主公积金 |
| `me.employeeCpf` | Employee CPF | 个人公积金 |
| `me.deductions` | Deductions | 其他扣除 |

*(留在列上:`me.period` Period/期间 · `me.gross` Gross/应发 · `me.net` Net pay/实发。)*

☞ **确认:没有新增 key,没有改动 key,没有删除 key。**
构建链里的 `check-i18n` 照跑通过,它是这句话的第二个证人。

---

## 6. 队列与记录

### 6.1 `docs/forward-queue.md`

* **TABLE-PHONE-2 整条从批次表里划掉**,并在上面加了一条"已上线"(照 TABLE-PHONE-1 的格式)。
* **剩下的从「26 张表 / 24 个文件」改成「21 张表 / 20 个文件」。**
* 批次表由四批变三批,**合计行改成 `21 张 = 6 + 9 + 6`**。

**★ 这个账是重算过的,不是减出来的:**

```
BEFORE  tables=26  files=24   (queue claimed 26 / 24)   ← 独立数出来,与队列原话一致
BATCH-2 tables=5   files=4
AFTER   tables=21  files=20
per-batch after: 6 + 9 + 6 = 21
batch-2 files still needed by a later batch: none
```

★ **表数 21 而文件数 20,差的那一个不是数错了:**
`purchasing/orders/new/NewOrderForm` 在 TABLE-PHONE-3(`:858`)与 TABLE-PHONE-4(`:786`)里
**各有一张表**。**这一句已经写进队列条目**,免得下一个人拿 21 去对 20 时以为哪里漏了。

★ **本批 4 个文件【整个】清干净** —— 上面那行 `still needed by a later batch: none` 就是这句话的凭据。
(与 TABLE-PHONE-1 不同:那一刀 7 张表只清干净 6 个文件。)

### 6.2 `docs/known-issues.md`

`RAW-TABLE-PHONE-SWEEP` 加了 **§七 · TABLE-PHONE-2 第二批做完的**:五张表的选列表格、
`trial-balance` 那个 Fragment 的交代、`close` 第七列为什么没停、
以及 **§4.2 那次绿错**(记成 CONV-8 的第五次)。抬头也从"TABLE-PHONE-0 + 1"改成带上第二批。

---

## 7. 本刀自己拿的主意(都是细节,不是形状)

1. **`/finance/close` 的重开钮叠进身份格里画出来,不另加标签。** 理由见 §3.4a。
   —— 这是本批离"形状"最近的一次,所以单写了一节而不是一行。
2. **把两个断点会共用的值提成变量**(`closedAt` / `credits` / `reopen`;
   `ledger` / `subledger` / `origination` / `settlement` / `revaluation`)。
   照抄两份的话两处会各自漂,**而那种漂在桌面上看不见(桌面那份是对的),只在手机上错**
   —— TABLE-PHONE-1 §7.3 已经付过这个账。
3. **`PackBody` 两张表的抬头从 `['key', ...]` 改成 `[{ k, phone }, ...]`。**
   列名、顺序、`t()` 调用、`className` 的其余部分**一个字没变**,只多了一个断点标志。
4. **`trial-balance` 的 `tfoot` 合计行手机档把借贷两个合计叠了进来**(照 receivables 小计行)。
   委托书 §3 点名要求"总计行的数字也要叠"。
5. **`px-4` → `px-2 sm:px-4`(以及工资条的 `px-3` → `px-2 sm:px-3`)只加在手机档留下的那几列上。**
   桌面档的内边距**一个像素没变**(`sm:` 之上仍是原值)。这是 payables 就在用的写法。
6. **`app/me/page.tsx:380` 的培训表没动**(3 列,免修,批次表没点名)。
7. **量具不进仓库**(R-Q8),但它的方法与输出写在上面 §4。
8. ★ **`ReopenForm` 在 DOM 里会有两份**(手机一份、桌面一份,CSS 各藏一个)——
   这是断点类这条路本身的代价,TABLE-PHONE-1 对 `AssetActions` 也是这么做的。
   **查过了,两份互不干扰:**
   * `ReopenForm` 自己没有固定 DOM id、没有 portal、没有 `useId`、没有 `useEffect`,
     状态只有一个 `useTransition`。
   * 它里面的 `ConfirmButton` **用了 `React.useId()`** —— 而 `useId` 正是**每个实例各给一个**,
     这是这种场合该用的 API,不是固定 id,**复制不会撞**。
   * `ConfirmButton` 那个**全局 `keydown` 监听器(Escape / Tab 关焦点)在
     `{open && <ConfirmDialog …/>}` 里面** —— 对话框**开着的时候才挂**。
     被 CSS 藏掉的那一份按不到,也就永远不会 `open`,**所以任何时刻最多只有一个监听器**。
   ☞ 这一条是**读代码读出来的,不是在浏览器里点出来的**(见 §9.5)。

---

## 8. 走查:去哪儿看,以及**怎么才能真的看见手机档**

### ★★ 先说最要紧的一件:**把窗口拖窄【不一定】能看见手机档** ★★

断点是 Tailwind 的 `sm`,即 **640px**;`hidden sm:table-cell` 的意思是
「**视口宽度 < 640px 时不画**」。

* 桌面浏览器把窗口拖窄到 640px 以下**是能看见的** —— 这些类走 CSS media query,只看视口宽度。
* **但拖窄的窗口不是 390px 的手机**:字体缩放、滚动条占位、
  以及**本刀量不到的那件事 —— 真实文字在真实宽度下会不会把三列挤开**,都不一样。
* ☞ **要看真的手机档,用开发者工具的设备模拟(iPhone 12 / 390×844),或者直接用手机开。**
  **三列在 390px 上够不够,只有那样才算数。**

### 走查清单

| 页 | 路由 | 角色 / 权限 | 看什么 |
|---|---|---|---|
| 管理报表包(**实时预览**) | `/finance/packs` | `module.finance` 读 | 勾稽表只剩**侧别 / 差额 / 未解释**;侧别格下面叠着六条,**每条都有列头**;未解释对不上时**那一格仍然是红的** |
| 管理报表包(**已存档**) | `/finance/packs/<id>` | 同上 | **同一份 `PackBody`,所以两条路由一起变** —— 两边都要看一眼 |
| 冲销对表 | 同上两条 | 同上 | 只在 `split_reversal_pairs` 非空时才画;只剩**分录 / 对手件 / 金额**,两个日期叠在分录格里 |
| 试算表 | `/finance/trial-balance` | `module.finance` 读 | 只剩**编号 / 科目 / 净额**;借贷叠在编号格里;**分组抬头行**(资产/负债/…)手机上跨 3 格;**底部合计行**把借贷两个合计叠了进来 |
| 关账历史 | `/finance/close` | `module.finance` 读;**重开钮还要 `module.finance.edit`** | 只剩**期末日 / 借方 / 状态**;★ **重开钮在叠加块里,而且按得动** —— 按下去对话框要**点名那个期间**并要那句理由 |
| 我的工资条 | `/me` | **自助页,任何登录用户看自己的** | 工资条那张只剩**期间 / 应发 / 实发**;公积金与扣除叠在期间格里。★ 同一页的**培训表(3 列)本刀没动**,它在手机上应当和以前一模一样 |

★ **`/me` 上还有 TABLE-PHONE-1 改过的年假明细表** —— 那一张这一刀没碰,
但它就在同一页上,走查时**别把它记到本刀头上**。

### 真实记录:**本刀没有连库,不编 id**

`/finance/trial-balance` · `/finance/close` · `/me` **不需要 id**,直接开即可。
`/finance/packs` 的**实时预览**也不需要 id。只有**已存档**那条要一个包 id,
而 `/finance/close` 与冲销对表要有行才看得出效果 —— 下面是**只读**查询,Tim 自己跑或交给下一刀:

```sql
-- 已存档的管理报表包:挑一个,用于 /finance/packs/<id>
--（时间列是 produced_at,不是 created_at;superseded_at 非空的是被顶掉的旧版)
select id, code, period_month, produced_at
from management_packs
where superseded_at is null
order by produced_at desc
limit 3;

-- 关账历史要有行才看得出选列;顺带挑一个【已重开】的,
-- 因为重开与未重开两种状态在手机上画得不一样(重开的那一行没有钮)
select period_end, closed_at, entries_count, reopened_at
from period_closes
order by period_end desc
limit 5;

-- 工资条:挑一个【有工资条】的员工,再用那个人的账号开 /me
select employee_id, count(*) as payslips
from payroll_lines
group by 1
order by 2 desc
limit 3;
```

★ **表名与列名逐个对过 `db/tables/` 的镜像**(`management_packs` / `period_closes` /
`payroll_lines`),**并核过软删列:这三张【都没有】 `deleted_at`,所以三句都不过滤,不是漏写。**
★ 第一句原先写的是 `created_at` —— **镜像里那一列叫 `produced_at`**,已改;
这正是"照镜像写"与"凭印象写"的差别。
**但本刀【没有把这几句真的跑过线上】** ——
这一刀是纯前端,没有连库。所以它们是"照镜像写对的查询",**不是"回过行的查询"**。
★ **勾稽表两侧(AR / AP)在任何一份包里都会有**,所以那一张不需要挑数据。

---

## 9. ★ 本刀**没有**验证的事 —— 说白

**这是这份报告里最要紧的一段,而它和上一刀一个字都没变 —— 因为情况一点都没变。**

1. **一个像素都没有量过。** 本刀写的是**标记**,而问题问的是
   **一个人在 390px 上看得见什么**。这两件事不是同一件事。
2. **没有浏览器**(委托书禁止安装),所以 `scripts/survey-phone.mjs`
   —— 那支真浏览器读 `scrollWidth` 的探针 —— **一次都没有跑。**
3. **于是"一个字段都没丢"这句话的确切含义是:**
   **那些字段在标记里【在场】,并且各自带着列头**(唯一的例外是那个自己带字的重开钮)。
   它**不等于**它们在 390px 上**读得到**。
4. **`table-fixed` 没有加,五张表仍然是 `width-auto`。** 本刀不加,因为那是一次**没有量过**的
   版式改动,而委托书 §4 明令不加。
   ☞ **如果走查看到三列被挤开,那多半是这一条,不是选列选错了。**
   ★ 本批**尤其**要留意这一点:`pack.colSettlement` 的英文是
   **"Applied in the ledger, not against a document"** —— 这是全系统最长的列头之一,
   而它现在是**叠加块里的一条标签**。它在 390px 上会不会自己折成三行、把那一格撑开,
   **本刀量不到。**
5. **本刀没有在浏览器里点过那个重开钮。** "它在手机上按得着"是从**标记**推的
   (它被画出来、没有被 `hidden` 掉、`PermissionGate` 与 `ConfirmButton` 一个字没动),
   **不是按过的**。
6. **那 9 张能滚的表一个都没碰**(R-Q6,含 `app/hr/payroll/PayrollGrid.tsx`),
   而它们读不读得懂**仍然没量过**,状态仍然是 **UNMEASURED**。

> ☞ **走查是今天唯一的证据。** 量具能证明的只有"字段在场、列数对得上";
> **"读得懂"要一个人拿着手机看。**

---

## 10. 闸 · 构建

### 10.1 `python3 db/gate.py` —— **它自己的退出码 0**

```
GATE_OWN_EXIT=0
GATE_WALL_SECONDS=480
```

**四条判词,逐字:**

```
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
```

★ **墙钟 480s 落在 `db/gate.py:38` 那个 180–700s 的区间【之内】,所以本刀【没有】动那个区间。**
(门自己在三条判词那一行印的是 `wall-clock 373s` —— 那是**三条判词**的耗时;
**480s 是整支脚本的**,多出来的是末尾 `db/check_grants.py` 那一相。
两个数都记在这里,免得下一个人拿其中一个去对另一个 —— TABLE-PHONE-1 也记过同一件事。)

★ 顺带记下门自己报的两件:`check_grants.py` 的**注入自检两格都变红**
(基线打瞎 · 查询打瞎);`anon` 够得着的函数仍然只有 `cod_verification(text)` 一个。

**本刀没有 SQL、没有迁移、没有 DDL** —— 门是照委托书 §10 跑的,不是因为动了库。

### 10.2 `npm run build` —— **它自己的退出码 0**

```
BUILD_OWN_EXIT=0
BUILD_WALL_SECONDS=37
```

**eslint 冻结闸,逐字:**

```
── eslint 冻结闸 ─────────────────────────────────────────────
基线  error 42 · warning 88
现在  error 42 · warning 88

✓ 没有新增的 eslint 问题。
```

**元检查(`check-instrument-selfproof`),逐字:**

```
✓ check-instrument-selfproof:32 支量具都写了瞄准线;其中 22 支(构建链里的,含本支)都带着覆盖断言。
```

**`check-datatable-phone`,逐字 —— ★ 委托书要求的那个 123:**

```
✓ 手机声明:123 个调用点(DataTable 119 · EditableTable 4) —— columns 模式 123(各自至少一列 priority)· scroll 模式 0(各自带 why) · 静态读不出 1(由渲染期那道网兜着)
```

★ **123 一个没变(DataTable 119 · EditableTable 4)** —— 这是
**本刀没有把任何一页转成 DataTable / EditableTable** 的旁证,也是委托书点名要的那一条。

### 10.3 本刀在过程里另外跑过的两支(都不在仓库里)

| 量具 | 用途 | 自证 |
|---|---|---|
| `npx tsc --noEmit` | 每改完一个文件跑一次 | 五张表做完 `TSC_OWN_EXIT=0` |
| `…/tp2/nofieldlost.mjs` | 「一个字段都没丢」 | **红过两次**(删条目 / 只删标签),各自点名那张表,还原后回 0 —— 见 §4.3。**而且它自己先绿错过一次** —— 见 §4.2 |

---
