# TABLE-CONVERT-2 交回报告 —— 而【那 45 张表分成 18 种形状,其中 20 张住在 server component 里,这个数此前没有人有】

两件事:**① 按结构给剩下的 45 张分了类**(上一刀欠的那一半),
**② 转了 finance 只读那一批里能转的 5 张** —— 第 6 张交回,理由在 §3.1。

> ⚠ **委托书本身是截断的**:第 5 节的报告清单停在第 9 条「Row」,后面没有了,
> 也没有收工那一节。第 9 条按 TABLE-CONVERT-1 的同位条目读成「390px 上的行高
> 与溢出」(§9);收工按本族既有的做法办(含闸 · 构建 · 提交 · 推送 · 部署)。
> **这是我的判读,不是委托书的原话。**

---

## 1 · HEAD、树、与预期的差别

| | |
|---|---|
| 开工前 HEAD | `2427121382b7e9f63f18c0bdd3a8ad338a817e4c` |
| 收工后 HEAD | 见末尾(本报告与代码同一次提交) |
| 树 | 开工前 `git status` 干净;`HEAD == origin/main` 逐字节相等 |

**与预期【没有】差别:** HEAD 正是 TABLE-CONVERT-1 那一次提交本身,
后面没有跟任何文档提交。三条前置(树干净 · HEAD==origin/main · /tmp 还在)全部满足。
`/tmp/TABLE-CONVERT-0-survey.md` 在(49094 字节)。

---

## 2 · ★ 任务一:剩下 45 张表的【结构】分类

### 2.1 先把人口对上 —— 45 这个数是【算出来的】,不是接受来的

自己写了一支扫描器(整标签花括号配平、先剥注释),在 `app/` 下数手搓 `<table>`:

```
扫到 68 张  ==  组件库棘轮基线的 68 张   ← 两支独立的工具,同一个数
  −22  <table> 标签自己用了 tableC 的(TABLE-STYLE-1 那一批)
  − 1  PayrollGrid(九张 UNMEASURED 之一,量之前不许动)
  ─────
   45  本次分类的人口
```

**旁证(不是我挑的,是撞上的):** 按【标签上钉死的字号】分组,
22 张 tableC 的合计 **0**、PayrollGrid **2**、这 45 张 **110** —— 加起来 **112**,
而棘轮自己报的标签侧总数**正是 112**。两支工具在两个维度上各自对上。

### 2.2 ★★ 委托书点名要的那个数:**20 / 45 住在 server component 里** ★★

| | 张 | 文件 |
|---|--:|--:|
| **server component** | **20** | **17** |
| client component | 25 | — |

☞ **这 20 张每一张都要一个新的 client 文件**(或者让现有的某个 client 件收下它)。
TABLE-CONVERT-1 量到的那条约束在这里第二次成立:列描述符的 `render` 是一个函数,
**函数跨不过 server→client 边界**,留在原地【编译不过】。本刀 5 张里有 4 张撞上,
做出来是 3 个新文件(两张同文件的合成一个)。
**按这个比例,剩下 40 张里大约还要建 15 个新文件** —— 这是此前没有计入的工作量。

### 2.3 十八种形状,最大的一种九张

形状 = 决定"这次转换要做多少活"的四件事拼起来:
**server/client · 格子里有什么控件 · 带不带列选判断 · 结构上的怪处**。

| 张 | server/client | 控件 | 列选判断 | 结构 |
|--:|---|---|---|---|
| **9** | SERVER | 链接 | 无 | 平表 |
| **5** | client | 只读 | ★ | 平表 |
| **5** | SERVER | 只读 | 无 | 平表 |
| 3 | client | 受控输入 | ★ | 平表 |
| 3 | client | 钮 | ★ | 平表 |
| 3 | client | 受控输入 | 无 | 平表 |
| 2 | client | 钮 | 无 | 平表 |
| 2 | client | 只读 | 无 | 平表 |
| 2 | SERVER | 链接 | ★ | 体内 colSpan |
| 2 | SERVER | 只读 | ★ | 表头由 map 生成 |
| 2 | client | 链接 | 无 | 平表 |
| 1 ×7 | (七种各一张) | | | |

**共 18 种形状。** 前 1 种盖 9 张、前 2 种盖 14 张、**前 3 种盖 19 张**、
前 4 种盖 22 张、前 5 种盖 25 张(45 张的 56%)。

> ☞ 与普查按【列头文字】分组的结果对照:那一轴只找到三组跨文件相同的。
> 本轴独立地把 **三个 AttachmentsPanel 归进了同一种形状**
> (client · 钮 · ★ · 平表)—— 普查用完全不同的判据找到的也是这一组。
> **两条互不相干的路指向同一堆,这一组是真的。**

### 2.4 其余几条轴(逐条实测)

| 轴 | 读数 |
|---|--:|
| 带列选判断(`hidden sm:table-cell`) | **19** |
| 带叠加块(`sm:hidden`) | 18 |
| **UNMEASURED —— 量之前不许动** | **8** |
| 行画在 `<table>` 块【外面】 | **1**(`hr/attendance/[id]/AttendanceGrid.tsx:48`,行由 `LineRow` 画) |
| 表头由 `.map()` 生成(列数机器读不出) | 3 |
| `<tfoot>` | **0** |
| 体内 colSpan 行 | 5 |
| 住在 `<form>` 里面 | 6 |
| **格子里有【带 `name` 的输入】—— 双画即双提交的隐患** | **2** |
| 格子里有受控输入(不带 name) | 8 |
| 格子里有钮 / ConfirmButton | 5 |
| 钉死的字号(标签侧) | **110 处,分布在 45 张里的 42 张** |

**空态的四种守法:** 三元一句话 **18** · **完全没有守 13** ·
`length > 0 &&`(空就整张不画)**7** · 别的条件块 **7**。

★ **那 2 张带 `name` 输入的都在 `logistics/containers/[id]/ContainerPanels.tsx`**
(`:119` 与 `:305`;实测 `:170` 有一个 `<input name="reason">` 就在格子里)。
**它们撞上的正是委托书说的那条隐患** —— 组件把非 priority 列画两遍,
带 `name` 的输入会提交两次。**谁转到它们,应当先停下来交回。**
(本刀的 6 张里没有这个形状 —— finance 那一批是只读的。)

### 2.5 ★ 这份分类【告诉不了】你什么

* **它读的是写法,不是行为。** 两张签名完全相同的表,仍然可能在"转换必须保住
  什么"上不一样 —— 一个 `title` 提示、一处按行变的格子底色(本刀就撞上一处,§7)。
* **"行在块外面"这一条只认【极端】情形。** 判据是"块里一个 `<td>` 都没有"。
  一张【一半格子写在块里、一半由子组件画】的表,在这里读成"行在块里"。
  TABLE-STYLE-1 撞上的那三处(balance-sheet / pnl 的 sectionBlock、cashflow 的 `<Row>`)
  都在 22 张 tableC 那一批里,**不在这 45 张内** —— 所以这 45 张里读到 1 处,
  不等于真的只有 1 处。
* **列数有 5 张读不出**(表头由 map 生成,或整张没有 `<thead>`)——
  与普查 §4.1 同一个限制,报"读不出",不报 0。
* **它不知道一次列选判断【对不对】**,只知道有没有。
* **它看不见提交路径。** 普查 §6.1 那条结论在这里仍然成立:两张列头一样、
  提交路径不一样的表,仍然是两次工作。
* **它看不见运行期拼出来的 className**(与 cellfont 棘轮自己声明的盲区同一条)。
* **它不知道一个 server 文件的数据取用能不能干净地切开。** 20 张要建新文件,
  而"在服务端把行压平"的工作量每张都不一样(本刀 `assets` 那张要压平 12 个字段,
  `PackBody` 那两张几乎不用压)—— 这一层在这份分类里【是看不见的】。

> ★ 本刀转掉 5 张之后,这 45 变成 **40**(手搓表 68 → 63 = 22 + 1 + 40)。
> 上面的分类是【开工时那 45 张】的,委托书要的就是这一份。

---

## 3 · 任务二:批次人口核对

普查 §4 第 29–34 行,六张全部**在今天的源码里对上了**:文件在、行号对、
还是手搓的、没有被别人动过。**六张都是 C 类(只读)、都在 `app/finance/`。**

| # | 文件:行 | 列 | 钉字号(普查/实测) | server? |
|---|---|--:|:-:|:-:|
| 29 | `app/finance/assets/page.tsx:137` | 12 | 7 / 7 | **SRV** |
| 30 | `app/finance/bank/import/ImportStatementForm.tsx:399` | 5 | 5 / 5 | client |
| 31 | `app/finance/close/page.tsx:253` | 7 | 5 / 5 | **SRV** |
| 32 | `app/finance/month-end/page.tsx:206` | 无表头 | 1 / 1 | **SRV** |
| 33 | `app/finance/packs/PackBody.tsx:78` | 9(表头由 map 生成) | 1 / 1 | **SRV** |
| 34 | `app/finance/packs/PackBody.tsx:186` | 5(同上) | 3 / 3 | **SRV** |

**钉字号合计 22,普查那一栏与本刀实测【逐张相等】。**
**六张【没有一张】在九张 UNMEASURED 里** —— 逐张比对过那份名单,可以动。
**普查这六行【没有一处过时】**(上一刀那种情形没有再出现)。

### 3.1 ★ 第 32 张 `month-end:206` —— **交回,没有转**

**它整张【没有 `<thead>`】。** 四列(序号 · 步骤链接 · 状态徽章 · 说明)是一张
月结清单,不是账簿;`<table>` 底下直接就是 `<tbody>`。

**而组件【永远】画一行表头**(`data-table.tsx:391` 那个 `<thead>` 不带任何条件),
于是转它只有两条路,**两条都动了委托书 §3 明令不许动的东西**:

* 给六个 `header: ''` → 屏幕上多出一条**空的表头带**(还带着 2px 的 Hawaiian Ocean 下边线);
* 给它编四个真列头 → **新增 4 个 i18n key**,而 §3 第一句就是"不许新增 i18n key"。

☞ 所以我停在这里,没有替 Tim 挑。**建议:它和普查点名的
`hr/reviews/cycles/page.tsx:157`(「卡内排版表」)是同一类** —— 用表格排版、
不是账簿。这一类更像 22 张 tableC 那一批的成员(穿上外观、留着自己的标记),
而不是转换的人口。**要不要把"无表头的排版表"整类从 53 张里划出去,是一次裁定。**

---

## 4 · ★ 每张表:手机上转换前留哪几列、转换后留哪几列

**读数来自真浏览器**:转换前的标记与转换后的组件,喂**同一份**行数据,
在 390×844 / dsf=3 各渲染一遍,读每个 `<th>` 的 `display`。量法与残留见 §8。

| 表 | 转换前 · 手机留下 | 转换后 · 手机留下 | 同一组? |
|---|---|---|:-:|
| `PackBody:78` | Side · Difference · Unexplained | Side · Difference · Unexplained | ✓ |
| `PackBody:186` | Entry · Counterpart · Amount | Entry · Counterpart · Amount | ✓ |
| `ImportStatementForm:399` | Line · Date · Description · Amount | Line · Date · Description · Amount | ✓ |
| `assets:137` | Code · Net book value · Status | Code · Net book value · Status **· Actions** | **差一列 —— 见 4.1** |
| `close:253` | Period end · Debits · Status | Period end · Debits · Status **·(重开钮那一列)** | **差一列 —— 见 4.1** |

折起来的那一组,五张逐张相等(assets 与 close 少了动作列,因为它上来了):

| 表 | 折进去的 |
|---|---|
| `PackBody:78` | Control account · Per the ledger · Per the documents · Raised but not posted · Applied in the ledger… · FX revaluation |
| `PackBody:186` | Date · Counterpart date |
| `ImportStatementForm:399` | Reference |
| `assets:137` | Description · Category · Acquired · In service · Cost · Amount (SGD) · Life · Accum. dep.(**转换前还有 Actions**) |
| `close:253` | Closed at · Entries · Credits(**转换前还有那个空列头**) |

### 4.1 ★★ 那两处差别是【动作列规矩】,而我把它当成一次决定报出来 ★★

**这两张的动作列转换前带着 `hidden sm:table-cell`,而那颗钮【另外画了一份在
身份格里】** —— 也就是说它在手机上**本来就不用点开任何东西就够得着**。
源码里两处都写着理由(assets:「一个在手机上够不着的处置钮,与没有这个钮是
同一回事」;close:「它叠进身份格里【画出来】,不是收进折叠区」)。

**而组件里没有"叠在身份格里画出来"这一档。** 一列只有两种去处:
priority(留在明面上)或者进【点一下才展开】的那一段。
折进去 = 要先点开一行才够得着那颗钮 = 正是 R1 判过的那件事。

☞ **所以两列都写成 `priority: true`。**「不点就够得着」这件事**没有变**;
变的是那颗钮从身份格里挪到了自己那一列 ——
与 TABLE-STYLE-1 对 `MyExpenseClaimsPanel` 撤回钮做的处置**逐字同形**。

**量出来的证据(390px,`canEdit=true`):**

```
after-close   Reopen 钮  visible=True  inExpandArea=False   格子 x=293..374(在 390 之内)
after-assets  动作那一格                                     格子 x=293..374(在 390 之内)
```

☞ **这不是"判断丢了",是同一条判断在新机制上的唯一活法。**
但它确实让手机上的可见列从 3 变成 4,所以我按委托书的要求当成差别报出来,
而不是悄悄记成"同一组"。

---

## 5 · 展开区:点开读过,每一列都带着自己的列头

点第一行的展开钮,等一帧,读 `<dl>` 里的 `<dt>/<dd>`:

| 表 | 点开之后 |
|---|---|
| `assets:137` | Description · Category · Acquired · In service · Cost(`128,000.00 USD@ 1.3421`)· Amount (SGD) · Life (months) · Accum. dep. —— **8 条,而 Actions 不在里面**(它 priority 了,正确) |
| `close:253` | `Closed at: 2026-09-03 09:14` · `Entries: 1284` · `Credits: 4,812,004.55 SGD` |
| `PackBody:78` | Control account · Per the ledger · Per the documents · Raised but not posted · Applied in the ledger… · FX revaluation(6 条) |
| `PackBody:186` | `Date: 2026-08-29` · `Counterpart date: 2026-09-02` |
| `ImportStatementForm:399` | `Reference: REF-889201` |

**值都对得上,标签都在。**

> ★ 读数里 `Category` 显示成 `assets.category.machinery` —— **是我的假数据造错了**,
> 不是缺陷:真实的类别只有 `equipment / vehicle / office / other`(`messages/en.ts:7541`)。
> 渲染那一句 ``t('assets.category.' + a.category)`` 转换前后**逐字节相同**。

---

## 6 · 空态:一张一张说

| 表 | 转换前 | 转换后 |
|---|---|---|
| `assets:137` | `assets.length === 0` → **两行 colSpan**(手机 3 列一行、桌面 12 列一行),同一句 `assets.empty` | 搬进 `empty` prop,**同一个 key,只剩一处**(组件自己算 colSpan) |
| `close:253` | 同形,两行 colSpan,同一句 `finance.closeHistoryEmpty` | 同上 |
| `ImportStatementForm:399` | `parsed.rows.length > 0 &&` —— **空就整张不画** | **原样保留那道闸,不给 `empty`** |
| `PackBody:186` | `split_reversal_pairs?.length > 0 &&` —— 空就整张不画 | **原样保留那道闸,不给 `empty`** |
| `PackBody:78` | **没有空态**(`sides` 为空时画出一张只有表头的表) | 用组件自带的 `table.empty` —— 见下 |

★ **`PackBody:78` 会多出一句 `table.empty`,而那个状态够得着:**
`sides = payload.control_reconciliation?.sides ?? []`,拿不到勾稽数据时就是空数组。
今天那种情形看到的是【一张只有表头、没有行的表】,转换后是同一张表加一行
`table.empty`。**这是本刀唯一一处会新出现在屏幕上的句子**,用的是组件既有的 key,
不是我造的新词。**与 TABLE-CONVERT-1 在 `MyLeavePanel:61` 上的处置同一条。**

★ **两处"空就整张不画"我【没有】塞 `empty`** —— 委托书点名不要发明空态,
上一刀在 `MyReviewsPanel` 上也是这么做的。

---

## 7 · ★ 一处组件缺口:**按【行】变的格子底色,今天表达不了**

`PackBody:78` 的「未解释」那一格,转换前是:

```jsx
<td className={'…text-right font-mono ' + (s.reconciled ? '' : 'bg-red-50 text-red-800 font-semibold')}>
```

**一个按行变的【整格底色】。** 而组件里:`Column.className` 是**每列一份静态字符串**,
`rowClassName` 管的是**整行**。**两个都不是"这一行的这一格"。**
全库找过:`rowClassName` 有 8 处以上先例,静态的列底色有 1 处
(`ForecastGrid:107` 的 `className: 'bg-amber-50'`)—— **按行的格子底色 0 处先例。**

☞ 处置:底色搬进 `render` 里的一个 `<span>`,并用 `block` + 与格子相同的内边距
+ 相反的负外边距(`-mx-3 -my-2.5 px-3 py-2.5`)把它撑回**整格**那么大 ——
红色的那块矩形因此不会缩成数字背后的一小条。**这一处是量过的:**

```
转换前  <td>   100.48 × 235      bg = lab(96.5005 4.18508 1.52328)
转换后  <span> 108.69 × 40       bg = lab(96.5005 4.18508 1.52328)   ← 同一个颜色
```

**两档的红都铺满了自己那一格**(高度差是因为行本身矮了 —— 叠加块没有了,
行高从 235px 掉到 41.5px,不是因为红块没撑开)。

⚠ **它对 `px-3 py-2.5` 是硬编码的**:组件的格子内边距一改,这里要跟着改。
**按名登记为一处缺口:组件缺【按行的格子 className】。** 不在本刀范围内修。

---

## 8 · 我量的是【组件】,不是那四条真实路由 —— 说白

**量法**:建了一条一次性路由 `app/tc2probe`(**量完已删,不在这次提交里**),
把 5 张表**转换前的标记**(逐字节抄自 `HEAD` 的四个文件)与**转换后的组件**
喂**同一份**假数据各画一遍,`chrome-headless-shell` + CDP,390×844 / dsf=3 / mobile。

**它是什么:** 对【组件在 390px 上怎么渲染】的一次真测量,而且转换前后是同一份输入。
**它不是什么:** 它不是 `/finance/assets`、`/finance/close`、`/finance/packs/[id]`、
`/finance/bank/import` 这四条路由。数据是我编的;登录用的是一次性 admin。
**真实数据下会不会溢出仍然是未测量的** —— 真实的说明文字比我编的长。

★ **`ImportStatementForm` 那一张还多一层间接:** 它的表住在一个要 CSV + 列映射
+ server action 才画得出来的组件中段,所以量测台上放的是**把同一份列定义原样
抄过去**单独画的一个件。**抄的是列定义,不是渲染路径。**

### 8.1 ★ 一次差点报错的读数 —— `canEdit` 决定结论,所以两档都量了

第一遍量测把 `canEdit={false}` 传给了 `AssetActions` / `ReopenForm`,
于是它们渲染出「Needs `module.finance.edit`」那句权限提示,里面有一串
不可断行的 `code`。读数是:**转换前 assets 宽 493px、close 宽 411px,整页溢出 119px**,
而转换后两张都被组件的 `overflow-x-auto` 收住了 —— 看起来像"转换修好了两处溢出"。

**改成 `canEdit={true}`(真正会去按那颗钮的人)之后,那个结论没了:**

```
canEdit=true   before-assets 358/358 不用拖   after-assets 358/377(19px)
               before-close  358/358 不用拖   after-close  358/364(6px)
```

☞ **转换前【没有】溢出,转换也【没有】修好什么。** 转换后两张各有十几像素的
内部横向余量(动作那一堆钮比它在定宽表里分到的 81px 略宽),由组件自己那层
`overflow-x-auto` 兜着,**整页不溢出**。
**照直记下来:第一版读数是对的读数配了错的输入,差一点就报成一条不存在的功绩。**

---

## 9 · 390px 上的行高与溢出(委托书第 9 条,按截断前的字面读)

| 表 | 表头字号 | 表体字号 | 行高(前) | 行高(后) |
|---|---|---|---|---|
| `assets:137` | 16 → **15px** | 14 → 14px | 505, 429 | 449.5, 325 |
| `close:253` | 16 → **15px** | 14 → 14px | 171, 141 | 81.5, 113 |
| `PackBody:78` | 14 → **15px** | 14 → 14px | 235, 235 | 41.5, 61 |
| `PackBody:186` | 14 → **15px** | 14 → 14px | 83 | 61.5 |
| `ImportStatementForm:399` | 16 → **15px** | 14 → 14px | 85, 49 | 101.5, 61 |

**溢出:整页 `clientWidth 390 · scrollWidth 390 · 溢出 0px`**(转换前后两半在同一页上)。
五张表的每一个可见格子,右边缘都在 390 之内(§4.1 有 assets/close 的逐格坐标)。
两张有十几像素的**表内**横向余量,见 §8.1。

**行高大多变矮**,因为常驻的叠加块收进了点开才展开的那一段;最明显的是
`PackBody:78` 的 **235px → 41.5px**。两张变高:`ImportStatementForm`(85/49 → 101.5/61,
它原来是 `py-1` 的紧凑档,换成了 C 的 `px-3 py-2.5`)与 `close` 的第二行
(141 → 113 仍是变矮;第一行 171 → 81.5)。

### 9.1 表体 14px vs 手搓表 15px —— 预料之中,报出来,**没有修**

五张转换后表体**全部 14px**,而穿了 `tableC` 的那 22 张是 **15px**。
原因仍是一个 token(`data-table.tsx:526` 缺 `text-[15px]`)。
**表头那一半合上了:五张转换后表头全部 15px**(三张是 16 → 15,两张 14 → 15)。
**本刀没有碰 `data-table.tsx`。**

---

## 10 · 棘轮:cellfont **405 → 384**,一处都没有涨

| 维 | 之前 | 之后 | 差 |
|---|--:|--:|--:|
| 手搓 `<table>` | 68 | **63** | −5(转掉的这五张) |
| **cellfont** | **405** | **384** | **−21** |

**−21 对得上账:** 六张的钉字号合计 22,减去没转的 `month-end` 那 1 处 = 21。
逐文件:assets 7→0 · ImportStatementForm 5→0 · close 5→0 · PackBody 4→0。

构建里那一行原文:

```
   基线:114 个文件在册。本次扫到 384 处。
   分账:标签上 91 处(<table>/<th>/<td>) · 列描述符里 293 处(className: '…')。
✓ 没有新增的格子钉死的字号(<table>/<th>/<td> 标签 + 列描述符的 className)。
```

☞ **列描述符那一栏停在 293,与开工前【一模一样】** —— 五张表的列定义里
**一个字号都没有**。被拿掉的是表根上的 `text-sm`、以及格子上的
`text-sm` / `text-xs`(`font-mono` 留着,那是列的意思不是字号)。

基线按工具自己的判词收紧(`--update-baseline`),diff **只有 8 行删除**,没有一行新增。
`check-datatable-phone`:调用点 **131 → 136**(正好 +5),`columns 模式 136(各自至少一列 priority)`。

---

## 11 · 用户看得见的字:**没有新词**;key 用量 120 → 112

**没有新增、没有改动任何一句用户看得见的话。** 字面 `t('…')`:**120 → 112,少 8**,
**没有一个 key 掉到 0**。而这 8 是两笔账加起来的:

**少的 14 处 —— 全是"同一个列头写了两遍"现在写一遍:**

| 来源 | key | 处 |
|---|---|--:|
| `assets` 叠加块的 8 个列头 | colDescription · colCategory · colAcquired · colInService · colCost · colLife · colAccum · colActions | −8 |
| `close` 叠加块的 3 个列头 | colClosedAt · entriesCount · colCredits | −3 |
| `ImportStatementForm` 叠加块 | bank.colReference | −1 |
| 两处**重复的空态行**(手机一份、桌面一份) | assets.empty · finance.closeHistoryEmpty | −2 |

**多的 6 处 —— 不是新用法,是【从动态调用变成了字面调用】:**
`PackBody` 的表头本来是一个 `[{k:'pack.colSide'},…].map(({k}) => t(k))`,
**`t(k)` 是动态的,我的字面 grep 数不到它**。搬进列定义之后写成了
`t('pack.colSide')` 这样的字面量,于是 colSide · colDifference · colUnexplained ·
colEntry · colCounterpart · colAmount 六个**从 0 变成 1**。
**同一句话、同一个 key、同样一次渲染 —— 只是从数不到变成数得到了**(这是好事:静态可查)。
折起来的那几个(colControl / colLedger …)本来就在叠加块里有字面量,所以**没有变化**。

`−14 + 6 = −8`,与 120 → 112 **对上**。

---

## 12 · 我自己拿的主意

**形状级(两条,都报在上面了):**

* **`month-end:206` 不转,交回** —— §3.1。转它必然踩 §3 的红线,该由 Tim 裁。
* **四张表搬进三个新的 client 文件**(`AssetsTable.tsx` · `CloseHistoryTable.tsx` ·
  `PackTables.tsx`)—— 不是风格选择,是 server component 的硬约束;
  全库 136 个调用点 100% 是这个形状(97 个 `<DataTable` 文件 + 4 个 `<EditableTable` 文件,
  逐个查过 `'use client'`)。

**细节:**

* **动作列的红线判断按 R1 走**,并把它当成一次可见差别报出来(§4.1),没有当成"同一组"。
* **未解释那一格的红底用 span + 负外边距撑回整格**,并量了矩形(§7);
  同时把"组件缺按行的格子 className"按名登记。
* **`ImportStatementForm` 的负数红字**也搬进了 span —— 那一处只有字色没有底色,
  所以不需要负外边距,不改几何。
* **`assets` 的「投用日那句话」仍然只算一次**:TABLE-PHONE-1 当初把它提到格子外面
  正是为了两个断点共用一个值,现在它提到了服务端的行构造里,同一条道理。
* **两个 server 页面里 `AssetActions` / `ReopenForm` 的 import 删掉了**
  (表搬走之后它们没人用了)—— 这是 eslint 冻结闸抓到的,见 §13。
* **两段 CONV-4 时期的抬头注释更新了**:它们写着"主表按兵不动""月结历史表按兵不动",
  而这两张现在转了 —— 原话留着,底下加一段说明为什么当时的判据换成了今天这一条。

---

## 13 · ★ 构建红过一次 —— 照直记

第一次 `npm run build` **`BUILD_EXIT=1`**:eslint 冻结闸报
`error 42 · warning 88 → 42 · 90`,两条**新的**文件+规则组合:

```
   app/finance/assets/page.tsx  @typescript-eslint/no-unused-vars  error 0 · warning 1
   app/finance/close/page.tsx   @typescript-eslint/no-unused-vars  error 0 · warning 1
```

表搬到新文件之后,两个页面里的 `AssetActions` / `ReopenForm` 成了没人用的 import。
删掉之后复跑 **`BUILD_EXIT=0`**,冻结闸回到 **42 / 88**。
☞ **这道闸抓到的正是它该抓的东西**:一次搬迁留下的残骸,人眼很容易放过。

---

## 14 · Tim 该在哪里走一遍

**四条路由,390px 与桌面各一遍:**

1. **`/finance/assets`** —— 390px:留 编号 · 净值 · 状态 **· 动作**;
   ★ **重点看动作那一格**:处置/投用/计划日那几颗钮应当**不用点开任何东西就够得着**
   (它们在 x≈293..374,屏幕之内),但那一格比它分到的宽度略宽,**表内可以横向拖十几像素**。
   点 `›` 展开:应当出现 8 条(描述 · 类别 · 购置日 · 在役日 · 成本 · 金额 · 寿命 · 累计折旧),
   **动作不在里面**。桌面:12 列全回来。**已处置的行仍然发灰。**
2. **`/finance/close`** —— 390px:留 期末日 · 借方 · 状态 **·(重开钮)**;
   重开钮同样不用展开就够得着。展开:关账时间 · 分录数 · 贷方。
3. **`/finance/packs/[id]`(或 `/finance/packs` 的预览)** —— 勾稽表 390px 留
   侧别 · 差额 · **未解释**;★ **未解释那一格不勾稽时应当整格发红**(不是数字背后一小条)。
   下面那张冲销对表:留 分录 · 对手件 · 金额。
   ☞ **需要一份有内容的包**:勾稽有数据、并且最好有一行 `reconciled=false`,
   否则红那一格看不到;拆分冲销对为空时那张表整张不画(那是原样保留的行为)。
4. **`/finance/bank/import`** —— 要**上传一个 CSV 并映射好列**才画得出预览表。
   390px 留 行号 · 日期 · 摘要 · 金额,参考号进展开区;**负数金额仍然是红字。**

**顺手看一眼字号**:表头 15px 已经到位;**表体仍是 14px**(§9.1)——
与手搓表的 15px 差一个 token,是登记在案的另一刀。

---

## 15 · 我【没有】验证的东西

* ★ **四条真实路由一次都没有渲染过。** 全部读数来自一次性量测台 + 我编的假数据(§8)。
* ★ **桌面宽度一次都没量。** 全部读数在 390×844。"桌面列全回来、顺序不变"是**读源码**
  得出的,不是读屏幕得出的。
* **`ImportStatementForm` 量的是【抄过去的同一份列定义】,不是它在页面里的渲染路径**(§8)。
* **只走了英文档。** 中文字宽不一样,没有单独量。
* **`PackBody:78` 那句 `table.empty` 的样子没有看过** —— 它是读 SQL 推出来够得着的(§6),
  没有渲染出来看。
* **`AssetActions` / `ReopenForm` 的对话框一次都没有打开过。** 量的是首屏。
* **任务一那份分类没有跑过任何"故障注入"** —— 它与棘轮在两个数上对上了(§2.1),
  但没有人独立地把它打瞎再看它会不会变红。
* **没有碰**:month-end(交回)· 其余 40 张 · 22 张 tableC · 九张 UNMEASURED ·
  组件的双画与那个缺的字号 token · 任何迁移(本刀零 SQL 改动)。

---

## 16 · 收工

* **含闸** `python3 db/gate.py`(经 `db/run_detached.sh`,判词只取日志自报那一行):
  **`GATE_EXIT=0`**,墙钟 **270s**(`17:50:25Z` → `17:54:55Z`,在 180–700s 窗口内)。
  四条判词原文:

  ```
  判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
  判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
  判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
  判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
  ```

  ☞ 本刀**一行 SQL 都没有改**,跑含闸是照本族的规矩,不是因为动了库。

* **构建** `npm run build`:**`BUILD_EXIT=0`**(40s;第一次红过,见 §13)。

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

* **一次性账号:干净。** 五次量测各建一个一次性 admin,**五次都自己删掉了**;
  收工时 `npm run reap:ephemeral` 报「没有滞留的清理计划」,线上按前缀查**零残留**。
* **量测路由 `app/tc2probe/` 已删**,不在这次提交里。
