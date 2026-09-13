# SEARCH-3 —— 那个面板变成了一个【下拉】(2026-09-13)

> ## ⛔ 先读这一节:委托书里有【两条断言是假的】,而它们不是同一种假
>
> AGENTS.md 的常设要求:**委托书里的每一个数、每一条事实,开工前当场重量一遍,
> 并把重量的结果写进报告 —— 包括量下来是对的那些。** 逐条在 §1。
>
> | # | 委托书说的 | 实测 | 它是哪一种假 |
> |---|---|---|---|
> | ① | 「★ THE EXISTING SEARCH PROBES ASSERT MODAL BEHAVIOUR AND WILL GO RED。」 | ★★ **一支都没有红。** 在 HEAD 的应用代码上跑改后的两支探针:`probe-search-shell` **7 格 0 红**;`probe-search-results` **11 格 1 红,而那一红是本刀【新写】的 R6**,原有 10 格全绿。**改前在册的搜索断言里,没有一条断言过模态。** | **一条【关于树里有什么】的断言**,而它指的那些断言不存在 —— 与 AGENTS.md 记的 FONT-3 ②「要复用的读数根本不存在」同族 |
> | ② | 「home entry — 358x49.02」放在「nav bar box 1280x53 / 390x55」旁边,读起来像同一组视口的读数 | ★ **数字是对的,而它的【视口】掉了**:`358x49.02` 只在 **390px** 上成立;**1280px 上同一格是 `544x53.63`**。两个数本刀都量过,都没有变。 | **一个数被抄走时,它的【分母】掉了** —— 这一次掉的是视口 |
>
> ★ ①**不是**"这一刀没事干":委托书要的那件事(**把现在为真的断言写下来**)照做了,
> 只是它的形状变了 —— **不是替换一条红的,是补上六条【从来没有人在看】的**。
> 逐条在 §5,连同它们**改前的红**。
>
> ★★ 而 ① 值得读两遍,因为它是 AGENTS.md 那一族里**最贵**的一种:
> 「一支探针会红」是一条**关于将来**的断言,而它读起来像一条已经量过的事实。
> 照它做的人会去**改**那几支探针;而真相是**那里根本没有东西可改,缺的是新写**。
> ☞ **处置(给下一份委托书):说「某支检查会红」时,先跑一次那支检查。**

---

## 0 · 开工闸(§1.1 的三条)

| # | 判据 | 读数 |
|---|---|---|
| 1 | `git status --porcelain` | **空** |
| 2/3 | 本地 HEAD == `origin/main` == `git ls-remote origin main` | 三者同为 `aa1bc611591e39d327f28a745bce34459c955163` ✓ 且等于委托书点名的 `aa1bc61…` |

**★ 零迁移,而这一行是量出来的:** `git diff --stat -- db/` **空** ·
`git status --porcelain -- db/` **空**(收尾时再量一次,见 §9)。
☞ **不存在破窗**:没有「旧代码 + 新库」那个窗口。

---

## 1 · 委托书里的每一个数,开工前当场重量一遍

> 量法一律写在数的旁边 —— AGENTS.md:「一个数写进报告时,把【它是怎么量出来的】
> 和它写在一起」,以及「一个数被抄走时,它的【分母】掉了」。

| 数 / 断言 | 委托书说的 | ★ 本刀实测 | 量法 |
|---|--:|--:|---|
| 顶栏盒子 @1280 | `1280x53` | ★ **1280x53** ✓ | `probe-nav-geometry` N1/N2,`getBoundingClientRect` |
| 顶栏盒子 @390 | `390x55` | ★ **390x55** ✓ | 同上 N3/N4 |
| 顶栏那一格搜索框 | `200x32` | ★ **200x32** ✓ | 同上,`[data-nav="search-trigger"]` 的盒子 |
| 首页那个入口 | `358x49.02` | ★ **358x49.02 ✓ —— 而那是【390px】的读数**;1280px 上是 **544x53.63** | 同上 N10 / 逐条读数表 |
| 改前就在溢出的 5 条 @390 | 27 · 177 · 143 · 8 · 24 | ★ **逐条对上** ✓ `/finance/freight/new=27` · `/operation/processing/new=177` · `/purchasing/payment-terms/new=143` · `/sales/orders/new=8` · `/tools/pricing/metal-prices/bulk=24` | 直接读 SEARCH-2b 的基线 JSON(`.survey-out/search2b-after/controls-drift-merged.json`,`at=2026-09-13T11:19:29Z`,**282 组 · failed 0**) |
| `/brand-sampler` | 860 渲染 / 903 计数 | ★ **860 / 903,两个视口都是** ✓ | `probe-brand-sampler`,**`next start`**(那条分母见 §6.2) |
| 「现有搜索探针会红」 | 会红 | ★ **假 —— 一支都没红**,见上面那个停止闸 | 在 HEAD 的应用代码上跑改后的探针(`git stash` + **重建** + 量) |
| U2「今天渲染的是链接手型」 | 是 | ★ **真** ✓ 两个入口 computed `cursor` 都是 `pointer` | `probe-nav-geometry` N11/N12 改前读数 |
| U3「问候语透过遮罩、与面板打架」 | 是 | ★ **真,而且量到了**:重叠处取 9 个点,**9 个点最上面的都是问候语,0 个是搜索面** | `probe-nav-geometry` N16(`elementFromPoint`,带一次注入 —— 量法与它证不了的东西见 §3.3) |
| U4「文案还在说单据搜索没建 / 只搜得到号」 | 是 | ★ **真,而且比委托书说的多一条** —— 见 §4 | `git diff messages/*.ts` 逐条 |

★ **一条【委托书没写、而它是这一刀最硬的一处发现】**:
`search.emptyNoRecentsYet` 写着「remembering what you last opened **is not built**」——
**而 SEARCH-2b 的迁移 C/D 把它建起来了**,连它自己的交回报告 §7.1 都写着这一格
空的时候该说「因为你还没编辑过任何东西」。**文案文件里那一句没有跟着改。**
☞ 一句**在册的、今天是假的**话,而它每天都画在屏幕上。见 §4。

---

## 2 · U1:两个入口都变成下拉 —— 改前 / 改后,同一支探针

### 2.1 ★ 一张表就把 U1 说完了(`probe-nav-geometry`,两个视口)

| | 改前(`BUILD_ID=SuBwLQdInOLsA2n16SMNU`) | ★ 改后(`BUILD_ID=73xhakv61KMDq3i7hy_KN` —— **发出去的那一次**) |
|---|---|---|
| **顶栏 @1280**:触发格 | `200x32` @left=976 right=1176 bottom=42 | ★ **逐字相同** |
| ……结果面在哪 | `576x315` @top=**96** left=352 **right=928** | ★ `448x282` @top=**50** left=728 **right=1176** |
| ……Δ(顶边 − 触发格底边) | **54px** | ★ **8px** |
| ……Δ(右边缘) | **−248px** | ★ **0px** |
| ……全屏遮罩 | **在**(`fixed inset-0 bg-black/40`) | ★ **不在** |
| ……`position` | `static`(它被一层 `fixed` 遮罩装着) | ★ `fixed`(坐标是量出来的) |
| **首页 @390**:触发格 | `358x49.02` @bottom=378.06 | ★ **逐字相同** |
| ……结果面在哪 | `358x391` @top=**16**(居中模态) | ★ `358x358` @top=**386.06** |
| ……Δ(顶边 − 触发格底边) | **−362.06px**(它在触发格【上面】) | ★ **8px** |

☞ **改前那个面板与【触发它的那一格】没有任何位置关系** —— 这不是一句评价,
是两行读数:顶边差 54px、右边缘差 248px。

### 2.2 ★★ 难的那一半:200px 的触发格,结果【不许】是 200px 宽

宽度是**算出来的**,算法只有三行(`SearchEntry.tsx` 的 `place()`):

```
宽 = clamp(触发格自己的宽, MIN_DROPDOWN=448, 视口 − 2×16)
左 = 触发格右边缘 − 宽            （右对齐;夹回视口内)
顶 = 触发格下边缘 + 8
```

| 入口 / 视口 | 触发格宽 | ★ 下拉宽 | 左 / 右 | 视口 |
|---|--:|--:|---|--:|
| 顶栏 @1280 | 200 | ★ **448** | 728 / 1176 | 1280 |
| 首页 @1280 | 544 | ★ **544** | 368 / 912 | 1280 |
| 首页 @390 | 358 | ★ **358** | 16 / 374 | 390 |

☞ 三条分别验的是三件不同的事:**比触发格宽**(顶栏)·**触发格已经够宽就不凭空多出一截**
(首页桌面)·**被视口夹住而不越界**(首页手机)。判据 N14 / N15a / N15b / N15c。

### 2.3 ★★ 为什么是 `position: fixed` + 一次**测量**,而不是 `absolute` + 几个类

两个真麻烦,**都不是理论上的**:

* **祖先的 `overflow` 会裁掉它。** 顶栏这一条今天没有 `overflow`,而"今天没有"
  不是一条不变量 —— 下一个给顶栏加一句 `overflow-x-hidden` 的人,不会知道
  他顺手关掉了搜索结果。
* **右对齐 + 视口夹取算不出来。** 触发格右边缘离视口右边只有约 100px
  (实测 1280 上 right=1176),一句 `right-0 max-w-[calc(100vw-2rem)]`
  会把左边缘推到视口外面:`1176 − (1280−32) = **−72px**`。
  夹回来需要知道触发格【在哪】,而那是一次测量,不是一个类。

★★★ 而这里有一处**不推理、只测量**的兜底,值得单独记:

> **`position: fixed` 的包含块【不一定是视口】** —— 任何一个带 `transform` /
> `filter` / `backdrop-filter` / `contain` 的祖先都会把它接管过去。
> **而顶栏正好是这一族的常客**:`app/components/TopNav.tsx` 的抬头逐字记着
> CHART-0 为什么把 `.nav-glass` 从 `<header>` 挪到一个子元素上 ——
> 「它成为 fixed 后代的【包含块】,手机抽屉的 `fixed inset-0` 于是对齐顶栏而不是
> 视口,实测在 390×844 上只有 94px 高」。

☞ 所以 `place()` **摆完之后再量一次**,差多少补多少(`getBoundingClientRect()` 与
目标坐标的差直接补回 `style.left/top`)。**它不需要知道是哪个祖先干的,
也不会在下一个人加回一层 filter 时失灵。**

---

## 3 · U2 与 U3

### 3.1 U2 —— 光标

| | 改前 | 改后 |
|---|---|---|
| 顶栏那一格 computed `cursor` | `pointer` | ★ `text` |
| 首页那一格 computed `cursor` | `pointer` | ★ `text` |

判据 **N11 / N12**,读的是 `getComputedStyle(...).cursor`,不是 class 串
——(FONT-1 记过那一族:**一条吊在"这一刀自己要改掉的样式类"上的判据**)。

### 3.2 ★ 它现在真的是一个输入框,而这有一条比光标更硬的判据

**R6.you-type-in-the-field-you-clicked**(`probe-search-results`,本刀新写):

| | 全页 `[data-search-input]` 个数 | 它在触发格里面吗 |
|---|--:|---|
| 改前 | 1 | ★ **false** —— 那一个住在模态里,而你点的那一格在遮罩底下 |
| 改后 | 1 | ★ **true** |

☞ **两个读数合起来才是 U1 那句话。** 缺了「只有一个」那一半,
「输入框在触发格里」在一个**同时还开着第二个输入框**的面板上照样成立 ——
而那正是改前的形状。

### 3.3 ★★★ U3 —— 问候语压在搜索面上面:机制、读数,以及这次注入证不了什么

**机制,一句话。** `.shell` 是 `position: relative; z-index: 1`,**所以它是一个层叠
上下文**;面板写在它里面,面板那个 `z-[150]` 因此被关在里面,对外只值 `z-index: 1`。
而 `.greeting` 也是 `z-index: 1`,**并且排在 `.shell` 后面** —— 同级同值,后来者在上。

**读数(N16,`elementFromPoint`,9 个取样点):**

| | 最上面是【问候语】的 | 是【搜索面】的 |
|---|--:|--:|
| **改前** | ★ **9 / 9** | **0** |
| **改后** | ★ **0** | ★ **9 / 9** |

改前那一趟还顺手印出了它的构造:`z=1 position=relative`,与上面那段机制逐字对上。

**修法是一句 CSS**:`.shell` 的 `z-index: 1 → 2`。
**为什么 2 就够,而且这个"够"有分母**:这一页上会造层叠上下文的只有三个 ——
`.mark`(1)· `.shell` · `.greeting`(1),`.pulse` 没有 z-index。
**不写一个 999**:一个凭感觉的大数字会在下一次有人排层叠时说不出理由。

> ### ⚠ 这一格带着一次【注入】,量法必须说清楚
>
> `getHomeGreeting()` 对一个**没有员工档案**的账号返回 `null`
> (`lib/homeGreeting.ts` 抬头【三】写着这条裁定:「一句『Good morning, admin@…』
> 比没有问候语更冷,所以缺席就是缺席」)—— **而这支探针起的正是那种一次性账号。**
> ☞ **于是真的那一行,在探针眼里从来不渲染。**
>
> 所以 N16 **照着它的构造复制一个**:
> · 同一个 CSS module 类名 —— **从样式表里现找**(`document.styleSheets` 扫
>   `.[…]greeting[…]`),**不写死那串 hash**,而且找到的不是恰好 1 个就退 2;
> · 同一个父元素(`.stage`,取自 `[data-home-search="shell"].parentElement`);
> · 同一个位置(排在 `.shell` **之后**,服务端就是这么画的)。
> **它要量的性质只由这三样决定 —— 两个层叠上下文的先后。**
>
> ★ **它证不了的,照直说:** 真实那一行的**文字宽度与换行**(那取决于句子本身)。
> 它证的是【压不压得住】,不是【长什么样】。
>
> ★★ **而这次注入【咬人了】** —— 改前它当场报出 9/9。
> AGENTS.md:**一次没有咬人的故障注入才是需要查到底的那一种。**
>
> ⚠ 三条覆盖断言护着它,少一条它就可能以一个漂亮的零蒙混过去:
> ① 那个类名找到的不是 1 个 → 退 2;② 重叠面 0 个 → 退 2;③ 取点 0 个 → 退 2。

---

## 4 · U4 —— 文案扫了一遍,逐条报出来(en 与 zh)

> ⚠ **`search.manualEnglishOnly` 一个字都没动** —— 委托书点名的那条常设裁定,
> 而且它今天仍然是真的(R4 实测:中文查询 → 手册 0 段,那句话在)。

### 4.1 改掉的(5 条键 × 2 个语言)

| 键 | 改前 | ★ 改后 | 为什么它是假的 |
|---|---|---|---|
| `search.placeholder`(en) | `Search pages, actions and the manual` | `Search documents, pages, actions and the manual` | **漏掉【单据】** —— SEARCH-2b 把那一半建起来了 |
| `search.placeholder`(zh) | `搜页面、动作,以及手册` | `搜单据、页面、动作,以及手册` | 同上 |
| `search.emptyWhatYouCanFind`(en) | `Type to find a page, an action, or a passage of the operations manual.` | `Type to find a document, a page, an action, or a passage of the operations manual.` | 面板顶上那一句 —— 读的人拿它当"这里能干什么"的清单,**而它漏掉单据** |
| `search.emptyWhatYouCanFind`(zh) | `打字找一个页面、一个动作,或者操作手册里的一段解释。` | `打字找一张单据、一个页面、一个动作,或者操作手册里的一段解释。` | 同上 |
| `search.emptyWhatYouCanFindRecords`(en) | `Type a document number — the whole thing, or just the last four digits.` | `Type a document number — the whole thing or just the last few digits — or a name from the document itself.` | ★ **只说【号】** —— 而 `search_documents()` 同时匹配每张表自己声明的 `match_columns`(名称/描述/备注那一类标签列)。一句只提号的提示,会让人以为记不住号就搜不到,**而他记得住名字** |
| `search.emptyWhatYouCanFindRecords`(zh) | `打一个单据号 —— 整个都行,只打后四位也行。` | `打一个单据号 —— 整个都行,只打后几位也行;打单据上的名字也找得到。` | 同上。★ 顺带:「后四位」是一个**写死的数**,而 SQL 那一侧没有"四位"这条规则 —— 改成「后几位」 |
| ★★ `search.emptyNoRecentsYet`(en) | `There is nothing recent to show here yet — remembering what you last opened is not built.` | `Nothing here yet — this fills up with the documents you edit.` | ★★★ **一句在册的、今天是假的话**:SEARCH-2b 的迁移 C(22 条 `(updated_by, updated_at DESC)` 索引)与迁移 D(`search_recents()`)**把它建起来了**,而它自己的交回报告 §7.1 写着这一格空的时候该说「因为你还没编辑过任何东西」——**文案文件里那一句没有跟着改** |
| ★★ `search.emptyNoRecentsYet`(zh) | `这里还没有"最近看过" —— 记住你上次打开了什么这件事还没有建。` | `这里还是空的 —— 你编辑过的单据会出现在这里。` | 同上 |

### 4.2 删掉的(2 条键 × 2 个语言)

| 键 | 它说的 | 为什么删,而不是改 |
|---|---|---|
| ★ `search.recordsNotBuiltYet` | en:`Searching for records … **is not built yet**. This is where it will appear.` · zh:「……还没有建。它会出现在这里。」 | **它的分支永远画不出来**:`actions.ts` 里 `built` 是两处写死的 `true`。☞ 留一个恒真的布尔 + 一条死分支 + 一句说"没建"的文案,**就是把区别删掉之后还留着一块牌子**。★ 而本仓库对这件事有一次**逐字可抄**的先例:SEARCH-1 删 `home.searchNotYetBadge` / `home.searchNotYet` 时写的是「**留着一句写着『搜索还没有建』的文案,下一个读到它的人会据此断定这件事还没做**」 |
| `search.close` | `Close` / `关闭` | 下拉没有那颗钮了(Esc / 点别处 / Tab 出去,而那一格**自己**始终在屏幕上)。**留一个没人用的键,下一个人会以为屏幕上还有那颗钮** |

☞ 连带:`lib/search/types.ts` 的 `records.built` 与 `actions.ts` 的两个 `built: true`
一起删。**它删掉的不是那条区别,是那条区别的【左边】** ——「还没建」这个状态
今天产生不出来了。

### 4.3 新增的(1 条键 × 2 个语言)

| 键 | en | zh | 为什么它必须是新的一条 |
|---|---|---|---|
| `search.emptyWhatYouCanFindPages` | `Type the name of a page or an action — or a piece of its address.` | `打一个页面或动作的名字 —— 打它地址里的一段也行。` | 【页面那一节】此前**复用**顶上那一句,于是它在一节标着「Pages and actions」的标题底下说「也能找单据和手册」。**一句放错了节的话,读起来像这一节什么都找得到。** 两句话拆开,各说各那一节 |

**`check-i18n` 自报:`I18N_OWN_EXIT=0`** —— 新键 en/zh 都在;删掉的两个键
**没有留下任何引用**(它的「定义了但未见引用」名单里没有 `search.*`)。

---

## 5 · ★ 判据:替换了哪些、新写了哪些,以及它们改前红在哪

> 委托书:「REPLACE each one with the assertion that is now true …
> Report which assertions you replaced and what they assert now.」

### 5.1 先把那条假前提落地:**没有一条在册的断言需要替换**

在 **HEAD 的应用代码**上(`git stash` 掉应用侧改动 + **重建** ·
`BUILD_ID=SuBwLQdInOLsA2n16SMNU`)跑改后的两支探针:

| 探针 | 读数 |
|---|---|
| `probe-search-shell.mjs` | **7 格 0 红** —— 它量的是「顶栏那一格在哪些页上看得见」,与模态无关 |
| `probe-search-results.mjs` | **11 格 1 红**,而那一红是**本刀新写的 R6**;R0/R1/R1b/R2/R3/R4/R5/R5b/R5c/R5d **全绿** |
| `probe-nav-geometry.mjs` | **23 格 6 红**,而 6 红**全部是本刀新写的**;N1–N10 原有十格全绿 |

☞ 所以这一刀做的不是「删一条 / 改一条」,是 **把六件【从来没有人在看】的事写成判据**。
**而每一条都先在改前红过** —— AGENTS.md:一条从没红过的判据不算判据。

### 5.2 六条新判据,以及它们各自的改前 / 改后

| 格 | 它断言什么 | 改前 | 改后 |
|---|---|---|---|
| **N11** | 顶栏那一格 computed `cursor === 'text'` | ✗ `pointer` | ✓ `text` |
| **N12** | 首页那一格 computed `cursor === 'text'` | ✗ `pointer` | ✓ `text` |
| **N13** | 下拉**贴着**顶栏那一格:`0 ≤ 顶边−触发格底边 ≤ 16` **且**(右边缘对齐 ±2px **或** 被视口夹住) | ✗ Δy=54 · Δx=−248 | ✓ Δy=8 · Δx=0 |
| **N13b** | 同上,首页那一格 @390 | ✗ Δy=−362.06 | ✓ Δy=8 · Δx=0 |
| **N17** | **没有全屏遮罩**(`[data-search-overlay]` 不在) | ✗ 在 | ✓ 不在 |
| **N16** | 首页那行问候语**不许压在搜索面上**(`elementFromPoint` × 9) | ✗ 9/9 是问候语 | ✓ 9/9 是搜索面 |
| **R6** | **你在你点的那一格里打字**:全页只有 1 个输入框,且它在触发格里面 | ✗ `inside=false` | ✓ `inside=true` |

★ **另加两条,而它们改前【就是绿的】—— 照直记,不假装它们是修复:**

| 格 | 它断言什么 | 改前 | 改后 |
|---|---|---|---|
| **N14** | 下拉比它的触发格宽 | ✓(模态 576 > 200) | ✓(下拉 448 > 200) |
| **N15a/b/c** | 下拉整个在视口里,三个视口/入口组合 | ✓ | ✓ |

> **N14 为什么还是要写下来:** 改成下拉之后,**"跟着触发格一样宽"是最容易犯的
> 那个错**(一个 `w-full` 就够了),而拦得住它的只有一条断言。
> 它不是为了变绿而写的,是为了**将来会变红**而写的。

### 5.3 ★ 还有一条判据是给【比对器】加的,而它治的是一个真的绿灯谎

`scripts/check-stop-rules-abc.mjs`:**(b) 点名的那几条路由,两侧都必须量到,
少一条退 2。**

理由是实测的,而且就在上一刀:SEARCH-2b 的改后那一趟里
`phone /finance/freight/new` **整格 `failed`**(渲染器卡死),
于是它落进 `blindRoutes`、只出现在 notes 里,**而退出码照样是 0** ——
而那条路由正是 (b) 点名的 5 条之一。**那个 0 的意思是「比过的都没踩」,
不是「那条路由没长大」。**

⚠ 判据用的是**改前那份读数算出来的名单**,不是一张写死的 5 条清单 ——
写死的名单会在树变了的那天悄悄过期。

★ **故障注入(先说它该红在哪,再跑):**

| 注入 | 预期 | 实测 |
|---|---|---|
| A=B,不动 | 绿,并印出「(b) 点名的 5 条两侧都量到了」 | ★ `ABC_NOOP_OWN_EXIT=0`,那一行在 |
| 把 `phone /finance/freight/new` 在 B 侧标成 `failed` | **退 2**,并**点名它** | ★ `ABC_INJ_OWN_EXIT=2` · `其中 1 条【只有一侧量到】: · phone|/finance/freight/new` |

---

## 6 · 停止条件,逐条,改前改后

### 6.1 ★★ (f) —— 这一刀的主要风险,而它【抓到了一次真的移位】

| 读数 | SEARCH-2b | 中途(第一版) | ★ 最终 |
|---|---|---|---|
| 顶栏盒子 @1280 | `1280x53` | `1280x53` | ★ **1280x53** |
| 顶栏盒子 @390 | `390x55` | `390x55` | ★ **390x55** |
| 顶栏那一格搜索框 | `200x32` | `200x32` | ★ **200x32** |
| 首页那个入口 @390 | `358x49.02` | ⚠ **`358x47.59`(矮 1.43px)** | ★ **358x49.02** |
| 首页那个入口 @1280 | `544x53.63` | ⚠ **`544x50.78`(矮 2.85px)** | ★ **544x53.63** |

> ### ★★★ 那 1.43 / 2.85px 是怎么来的,以及为什么它值得一整段
>
> 改前那一格里是一个 `<span>`,它从 `<body>` 继承 `line-height`,而那是一个
> **比值**(`calc(20 / 14)`,`app/globals.css` 有一整段写它为什么必须是比值而不是长度)
> —— 比值继承下去,**每个元素拿自己的字号去乘**。1rem 的 span 因此高
> 16 × 1.428571 ≈ **22.86px**。
>
> ★ 换成 `<input>` 之后,**Tailwind preflight 给表单控件写的是 `font: inherit`**,
> 而 `font:` 简写继承的是父元素的**计算值** —— 父元素 `.box` 是 14px 字号,
> 它的计算 line-height 是 **20px(一个长度)**。☞ **那个长度不再随字号走。**
> 两处的差额恰好是 `22.86 − 20` 与 `21.43 − 20`。
>
> ☞ **修法是把那个比值再写一次,并且【读同一个变量】,不抄一个数字**:
> `.prompt { line-height: var(--text-sm--line-height, calc(20 / 14)) }`。
> 于是它仍然只有一个源,而这一格的高度回到**逐字相同**。
>
> ★★ **这正是委托书 §3(f) 存在的理由被兑现的样子:** 那 1.43px
> 不会被任何一道闸抓住(它不造成溢出、不动表、不进取样页),
> **只有一支专门量这三个盒子的探针看得见它。**

### 6.2 ★★ (e) `/brand-sampler` —— 逐成员、逐字段

`scripts/probe-brand-sampler.mjs`,**跑在 `next start` 上**(★ 委托书要求说出这句话:
同一支探针在 `next dev` 上给的是 916 —— 两个数都对,拿错一个就会把"没变"读成"变了")。

| | desktop @1440 | phone @390 |
|---|--:|--:|
| 渲染成员(SEARCH-2b → 本刀) | **860 → 860** | **860 → 860** |
| 连不渲染的一起数 | **903 → 903** | **903 → 903** |
| ★ **取样页自己** | ★ **817 → 817 · 多出签名 0 种 · 少掉 0 种** | ★ **817 → 817 · 0 · 0** |
| 顶栏那一堆(允许动) | 43 → 43 · **多 2 少 2** | 43 → 43 · **多 2 少 2** |

**比过成员 3440 个 · 签名比较 1156 次 · `SAMPLER_E_OWN_EXIT=0`。**

顶栏那 2 多 2 少,**逐条就是这一刀干的事**:
`−button(cursor-pointer)` / `+label(cursor-text font-normal)` ·
`−span.truncate「Search for something」` / `+input`。

> ### ★★ 而这一格上,普查**抓到了一处我没有打算做的改动**
>
> 第一次比对报的是 **多 5 少 5**,多出来的三条是 `svg` / `circle` / `path`
> —— **它们的 `font-weight` 从 400 变成了 500。**
>
> ☞ 查到底:`app/globals.css` 的 base 层写着 `label { font-weight: 500 }`,
> 而这一格今天是一个 `<label>`。**FONT-1 T4 为同一族付过账**(它那次的读数是
> 「240 个控件 / 42 条路由的输入文字从 400 变成 500,而没有任何人裁过控件要变」),
> 当时的药是 `input, select, textarea { font-weight: 400 }` ——
> ★ **那条今天仍然管着里面那个输入框(实测它是 400);够不着的是 label 自己
> 和它的 svg 子元素。**
>
> **处置:在【调用点】挡一次**(`font-normal` / `.box { font-weight: 400 }`)。
> `app/globals.css` 是 S2 的关闭输出(停止条件 (d)),**一个字节都没碰**。
> 补上之后,svg / circle / path 三条签名**回到逐字相同**,差额从 5/5 缩到 2/2。
>
> ★ **值得记的是它怎么被抓到的:** 不是我想到了 `<label>` 会带来一条 base 规则,
> 是**一支逐元素比签名的普查把它吐了出来**。**换一个标签名,就是继承树换了一段。**

### 6.3 (a)(b)(c) —— `scripts/check-stop-rules-abc.mjs`

`scripts/check-stop-rules-abc.mjs`,基线是 **SEARCH-2b 的改后读数**
(`.survey-out/search2b-after/controls-drift-merged.json`,`at=2026-09-13T11:19:29Z`,
**282 组 · failed 0**);本刀那一份在 `.survey-out/search3-after/controls-drift-merged.json`
(`at=2026-09-13T12:59:46Z`)。

```
视口 2 个(desktop / phone)
★ (b) 点名的 5 条【两侧都量到了】—— 逐条断言过,不是打印过。
路由×视口 282 组比过 · 表 184 张比过 · 字段比较 650 次
改前就在溢出的:5 组 —— phone|/finance/freight/new=27px · phone|/operation/processing/new=177px
                     · phone|/purchasing/payment-terms/new=143px · phone|/sales/orders/new=8px
                     · phone|/tools/pricing/metal-prices/bulk=24px
✓ (a)(b)(c) 一条都没踩。          STOPRULE_ABC_OWN_EXIT=0
```

★ **委托书点名的那 5 条,逐条重量、逐条对上**;`/sales/orders/new`(8px,已知修不动)
**本刀一个字都没碰**。

#### ★ 而这一趟第一次比出来的是 **281 组**,不是 282 —— 处置照 SEARCH-2b 的先例

`phone /finance/freight` 那一格 **改后 `failed`**(`renderer wedged … CDP timeout:
Runtime.evaluate`),于是比对器**自己把它说了出来**:「这一格【不作数】,不是"没变"」。

| | |
|---|---|
| 定点复读(`--mode=drift --only=/finance/freight`) | `DRIFTFIX_EXIT=0` |
| 读数 | `docScrollW=390 · docClientW=390` ⇒ **溢出 0px** |
| SEARCH-2b 基线同一格 | `docScrollW=390 · docClientW=390` ⇒ **溢出 0px** —— ★ 逐字相同 |
| 合并(★ 合并时断言「一格 failed 都不许剩」+「该换几格就换几格」) | 282 组 · failed **0** |
| 合并之后重比 | ★ **282 组 · `STOPRULE_ABC_OWN_EXIT=0`** |

⚠ **这条路由的卡死是【第四次】了**:SEARCH-1 改前改后**两趟都**卡在它上面
(`FONT2-PROBE-WEDGE-390`),SEARCH-2b 卡的是 `/finance/freight/new`,本刀又是它。
**BTN-SIZE-1 当年记的是「卡的不是同一条」——那句话今天已经不成立了。**
☞ 三条记载并排放着,不要合成一句。

> ### ★★★ 一件【我自己制造的风险】,照直记 —— 而它与上面那次卡死分不开
>
> **drift 跑在 `next dev` 上,而 `next dev` 会热重编译。**
> 手机那一趟跑到第 10 条左右时,**我为了修一处 `onBlur` 的边界条件改了
> `SearchEntry.tsx`** —— 也就是说,**我在一支长量具正在读的树上动了源码。**
> 这正是 AGENTS.md 记着的那一条:「**一次长量具的读数,可以被别处一条毫不相干的
> 命令悄悄废掉**」,而 SEARCH-1 §6 末尾也为它付过一次账。
>
> ★ **卡死就发生在那前后,而我【分不出】它是那次重编译造成的,还是这条路由
>   自己那个已经卡过三次的老毛病。** 两种可能我都不排除,也不挑一个写进报告。
> ☞ **处置不是辩解,是测量**:那一格定点复读之后**与基线逐字相同**,
>   合并之后 **282 组、0 格不作数**,于是这条风险**被读数收掉了,不是被推理收掉的**。
> ☞ **写给下一刀的规矩,一句话:`--mode=drift` 开跑之后,到它吐出 `DRIFT_EXIT=` 为止,
>   【一个源文件都不要碰】。** 想改就等它跑完 —— 它自己会说自己什么时候结束。

### 6.4 (d) S2 的五份关闭输出 —— **一字未动**,逐个 `git diff --numstat`

`control-style.ts` **0** · `input.tsx` **0** · `textarea.tsx` **0** ·
`globals.css` **0** · `table-style.ts` **0**。

### 6.5 ★ 零迁移

`git diff --stat -- db/` **空** · `git status --porcelain -- db/` **空**。
☞ **这一行不是空着,是量过之后为零。**

---

## 7 · ★ 「还是一个面板,两个入口」—— 一个读代码的人怎么在三十秒内确认

> Tim 把这条列为整套搜索设计里他**最先说、也说得最多**的一条。
> 委托书:「Say in the handback how a reader can verify it is still one.」

**三条,全部是【数一数】,不需要读懂那个文件:**

```
① grep -rn 'data-search-hit="' app/ lib/ | grep -vE ':[0-9]+://' | wc -l
   → 4，而且四条全部在 app/components/search/SearchEntry.tsx 里
     (四种结果各一处:recent · record · page · manual)

② grep -rn "from '@/app/components/search/SearchEntry'" app/ lib/
   → 2 处:app/page.tsx:121 · app/components/nav/SearchShell.tsx:63

③ 两个入口能传的只有五样，全部是外观：
   triggerClassName · wrapperClassName · inputClassName · glyphClassName · markers
   —— 类型就是这么定的，所以"措辞漂开"在【类型这一层】就没有地方发生。
```

> ### ★★★ 而这三条【被自己咬过两次】,照直记 —— 它是 AGENTS.md 那一族的第七、第八次
>
> AGENTS.md:「**一句注释可以污染将来对它自己的计数**」(已记到第六次)。
> 它在这一段上**连着咬了两次**,而两次都是实测撞出来的:
>
> | 第几次 | 我写的 | 实测 | 多出来的是什么 |
> |---|---|---|---|
> | ① | `grep -rln 'data-search-slot' app/ lib/` → **1 个文件** | ★ **3 个** | `lib/search/types.ts:19` 与 `lib/search/records.ts:7` **各在注释里提过它** |
> | ② | 换成 `data-search-hit=`,写 → **4 次** | ★ **7 次** | ★ **多出来的 3 次就是我刚写下的那段说明自己** |
>
> ☞ **药不是"再换一个记号",是 fixture 100 第 5/6 臂用过的那一味:
> 扫之前先把注释行剥掉**,只数【会被渲染的那些字节】。
> ★ 而最后一条更硬:**不剥注释的那个原始数【不许写进文档里】** ——
> 它会随着有没有人编辑这段话而变(实测第二版 7、第三版 5),
> **一个会被自己的文档改掉的读数不是读数。**

---

## 8 · ★ 我【没有】做的事,逐条点名

* ★ **一条迁移都没有**(§6.5)。
* ★ **没有动 S2 的五份关闭输出**(§6.4,逐个 `git diff --numstat` = 0)。
* ★ **没有碰 `hidden md:block`**,没有给手机加任何顶栏搜索入口(S3,Tim 明说接受)。
* ★ **没有在 `/sales/orders/new` 上尝试任何修补**(已知修不动,委托书点名 STOP)。
* ★ **U5 的三件一件都没做**:记录页内的限定搜索 · 标签列的 trigram 索引 ·
  `assay_results` / `contracts` 上被扣下计数的少报。**三件都已在册**
  (前两件在 `docs/forward-queue.md`,第三件在 SEARCH-2b §11 与 §14),
  本刀把它们在队列里**再点一次名**,见 §10。
* ⚠ **`home.searchPrompt`(屏幕上那句占位符)没有改** —— 它今天是
  `Search for something` / `搜点什么`,**既没有说"还没建",也没有说"只搜得到号"**,
  所以它不在 U4 的射程里。☞ 它必须短到放得进 200px 那一格,而
  「这里能找到什么」那句完整的话由 `aria-label`(`search.placeholder`)承担。
* ⚠ **`home.module.css` 里两处 `<summary>` 年代的遗留没有清扫** ——
  `list-style: none` 与 `.box::-webkit-details-marker`,以及一条选不中任何东西的
  `.shell[open] .box`。**它们今天无害且无用**,而一次顺手的删除会让下一个人以为
  有人核过整个文件。**报告,不清扫**(AGENTS.md)。
* ⚠ **那一格里的 `<input>` 是手写的,没有走 `<Input>`** —— 理由与 SEARCH-1
  拒绝 `<Button>` 的那一条逐字相同(库组件自带高度档位与圆角,套上去这两格的
  几何当场就变,而顶栏在每一页上)。**登记进 `docs/base-components.md` §十六**,
  并且照直说:`check-component-library` **数的是 `<button` 与 `<table`,
  它看不见一个手写的 `<input>`。**
* ★ **一处【没有判据看着】的边界条件,照直记:** `onBlur` 里 `relatedTarget === null`
  时**不关**下拉。浏览器在两种情形下给 `null` —— 点面板里一段没法聚焦的文字
  (小节标题、「还有 N 条没画出来」),以及切到别的窗口;而 `contains(null)` 是
  `false`,照字面判就会**在面板内部点一下把它关掉**。
  ⚠ **这一条是读代码想到的,不是量出来的** —— 它今天**没有一格判据看着**
    (在册的探针都用 `.click()` / `.focus()`,走不出这条路)。
    **写在这里而不是假装它被证过。** 真要证它,要一支会发真指针事件的探针。
* ⚠ **没有量"一次搜索在生产上要多久"** —— 理由与 SEARCH-2b §11 逐字相同
  (39 张单据表合计 319 行,规划器永远选 Seq Scan;**报一个毫秒数就是编一个数**)。
* ⚠ **`operations` 这个角色在线上已经退休**(SEARCH-1 §5.4 量到),
  而 `AGENTS.md` 的 `--reach` 那一节还把它列为三个角色之一。
  **本刀仍然没有改那一节** —— 不是本刀射程。**第二次登记,处置由人决定。**

---

## 9 · 每一条命令,以及**它自己打出来的那一行退出码**

> ★ 长活一律走 `db/run_detached.sh` —— 判词只认脚本自己写进日志的那一行。
> ★ 每一支探针现在**开头就印 `.next/BUILD_ID`**(SEARCH-1 §6 末尾那条建议,
> 本刀落地了)—— 一份读数必须说得出**它量的是哪一次构建**。

| # | 干什么 | 它自己那一行 | 备注 |
|--:|---|---|---|
| 1 | 开工闸:`git status` 干净,三个 SHA 相同 | `aa1bc611591e39d327f28a745bce34459c955163` ×3 | |
| 2 | **改前** `probe-nav-geometry.mjs`(在 HEAD 的构建上) | ★ **`NAVBEFORE_OWN_EXIT=1`** | 22 格 **5 红** · `BUILD_ID=fam8vWSBKqOAqB7ua649O` |
| 3 | `npx tsc --noEmit` | ★ **`TSC_OWN_EXIT=0`** | |
| 4 | `npm run build`(28 条静态检查 + `next build`) | ★ **`BUILD1_OWN_EXIT=0`** | `BUILD_ID=h9H2ejtQXiTh-qBm_-dLz` |
| 5 | **改后(第一版)** `probe-nav-geometry.mjs` | `NAVAFTER_OWN_EXIT=0` | ⚠ **22 格 0 红,而 (f) 的读数【变了】**:首页那一格 49.02 → 47.59 |
| 6 | 补上 `.prompt` 的 `line-height` 之后重建 | ★ **`BUILD2_OWN_EXIT=0`** | `BUILD_ID=BPb1WFyUEoxjF0Y01iXgD` |
| 7 | 再量 `probe-nav-geometry.mjs` | ★ **`NAVAFTER2_OWN_EXIT=0`** | ★ 首页那一格回到 **358x49.02 / 544x53.63**,逐字相同 |
| 8 | `check-component-library --update-baseline` | `UPDATE_OWN_EXIT=0` | 基线 **缩短一条**(`SearchEntry.tsx: 1` 删掉),棘轮只会缩短 |
| 9 | ★ `git stash` 掉应用侧 + **重建**(★ stash 换树之后【下一次量之前必须重建】) | ★ **`BUILDBEFORE_OWN_EXIT=0`** | `BUILD_ID=SuBwLQdInOLsA2n16SMNU` —— 这是**改前**那几格的构建 |
| 10 | **改前** `probe-nav-geometry.mjs`(含新加的 N17) | ★ **`NAV_N17_BEFORE_OWN_EXIT=1`** | 23 格 **6 红** —— 6 红全部是本刀新写的 |
| 11 | **改前** `probe-search-results.mjs`(含新加的 R6) | ★ **`SEARCHRES_BEFORE_OWN_EXIT=1`** | 11 格 **1 红**,而那一红是 R6;★ **原有 10 格全绿 —— 委托书那条「现有探针会红」在此作废** |
| 12 | `git stash pop` + **重建** | ★ **`BUILD3_OWN_EXIT=0`** | `BUILD_ID=Wa9n2T2FHG5Xwd2x4yxA6` |
| 13 | `probe-brand-sampler.mjs`(第一次比) | `SAMPLER_E_OWN_EXIT=0` | ⚠ 取样页 0 差异,而**顶栏那一堆多 5 少 5** —— svg/circle/path 的字重 400→500 |
| 14 | 挡掉那次继承(`font-normal` / `.box { font-weight: 400 }`)后重建 | ★ **`BUILD4_OWN_EXIT=0`** | `BUILD_ID=-RVUPRYMUQLlBt5ABH-w8`(★ 下面所有读数都在这一次构建上) |
| 15 | `probe-brand-sampler.mjs` 重量 + 比对 | ★ **`SAMPLER_E_OWN_EXIT=0`** | 860 / 903 两视口 · **取样页自己 817→817,0 差异** · 顶栏 43→43 多 2 少 2 |
| 16 | `probe-nav-geometry.mjs`(最终) | ★ **`NAVAFTER_FINAL_OWN_EXIT=0`** | **23 格 0 红** |
| 17 | `probe-search-shell.mjs` | ★ **`PROBESHELL_OWN_EXIT=0`** | 7 格 0 红 |
| 18 | `probe-search-results.mjs` | ★ **`SEARCHRES_AFTER_OWN_EXIT=0`** | **11 格 0 红** · R6 绿 |
| 19 | `node scripts/check-i18n.mjs` | ★ **`I18N_OWN_EXIT=0`** | 新键 en/zh 都在;删掉的两个键没有留下引用 |
| 20 | `python3 db/gate.py` | ★ **`GATE_EXIT=0`** | wall-clock **354s**(run_detached 等了 471s);**四个判词全绿**(可重建性 · 镜像 vs 线上 · 行为断言 · 匿名面基线 327 条) |
| 21 | `node scripts/smoke-routes.mjs` | ★ **`SMOKE_EXIT=0`** | **248 ok · 6 skipped(没数据)· 0 FAILED**;计时 223 条,合计 **642.2s**,中位数 2765 ms |
| 22 | `check-stop-rules-abc` 故障注入 ×2(A=B / 把 (b) 点名的一条标成 failed) | ★ `ABC_NOOP_OWN_EXIT=0` · ★ **`ABC_INJ_OWN_EXIT=2`** | 注入那一次**点名了 `phone|/finance/freight/new`** |
| 23 | `rm -rf .next` + `survey-controls --mode=drift`(141 × 2) | ★ **`DRIFT_EXIT=0`** | **1543s ≈ 26 分** · 覆盖断言 11 条 · ⚠ phone `/finance/freight` 卡死一格 |
| 24 | `check-stop-rules-abc`(第一次) | `STOPRULE_ABC_OWN_EXIT=0` | ⚠ **281 组**,而它**自己点出** 1 组不作数(§6.3) |
| 25 | drift 定点复读 `--only=/finance/freight` | ★ **`DRIFTFIX_EXIT=0`** | `docScrollW=390 · docClientW=390` ⇒ 0px,与基线逐字相同 |
| 26 | 合并(断言「一格 failed 都不许剩」)+ 重比 | ★ **`STOPRULE_ABC_OWN_EXIT=0`** | ★ **282 组 · 不作数 0 组 · (a)(b)(c) 一条都没踩** |
| 27 | `npm run build`(收尾,`.next` 被 drift 换成 dev 之后重建) | ★ **`BUILDFINAL_OWN_EXIT=0`** | ★ **`BUILD_ID=73xhakv61KMDq3i7hy_KN`** —— **下面四支探针量的都是它** |
| 28 | `npx tsc --noEmit`(收尾) | ★ **`TSC_FINAL_OWN_EXIT=0`** | |
| 29 | `probe-nav-geometry.mjs`(收尾) | ★ **`NAVFINAL_OWN_EXIT=0`** | 23 格 0 红 · 首页那一格仍然 `358x49.02` |
| 30 | `probe-search-results.mjs`(收尾) | ★ **`SEARCHRESFINAL_OWN_EXIT=0`** | 11 格 0 红 |
| 31 | `probe-brand-sampler.mjs`(收尾,重量 + 比) | ★ **`SAMPLER_E_FINAL_OWN_EXIT=0`** | 860 / 903 两视口 · 取样页自己 **0 差异** |
| 32 | `probe-search-shell.mjs`(收尾) | ★ **`PROBESHELLFINAL_OWN_EXIT=0`** | 7 格 0 红 |

> ★★ **为什么收尾要把四支探针【再跑一遍】,而不是引用前面那几行:**
> 第 14 行那次构建之后,我又改了一处 `onBlur` 的边界条件(§8 那条「relatedTarget
> 为 null 时不关」)。**一份读数必须说得出它量的是哪一次构建** ——
> 上面第 15–18 行量的是 `-RVUPRYMUQLlBt5ABH-w8`,而**发出去的是
> `73xhakv61KMDq3i7hy_KN`**。两者之间树动过,所以那几行不作数,重跑。
> ☞ 这正是 SEARCH-1 §6 末尾那条「stash 换树之后下一次量之前必须重建」的另一面:
> **不是换树才要重量,【改了树】就要重量。**

★ **一笔 SEARCH-1 §6 记过、而本刀又付了一次的账:** 为了拿改前读数,
树要 `git stash` 回 HEAD 再构建一次 —— **本刀连同中途两次修正,一共构建了 6 次。**
☞ 而 SEARCH-1 留的那条建议(**探针开头印出它读到的 `BUILD_ID`**)本刀落地了,
四支探针都印。**它当场就有用:上表第 9 行与第 12 行的两个 BUILD_ID 不同,
所以"改前"那几格量的确实是改前那棵树。**

---

## 10 · 下一刀开工前要知道的

1. ★★ **那个下拉的摆放是【算出来的 + 量回来的】,不是几个 Tailwind 类。**
   `SearchEntry.tsx` 的 `place()`:宽 `clamp(触发格宽, 448, 视口−32)` · 右对齐 ·
   摆完 `getBoundingClientRect()` **再量一次,差多少补多少**。
   ☞ 那一次回量**不是保险,是承重的**:祖先里任何一个 `transform` / `filter` /
   `backdrop-filter` / `contain` 都会把 `position: fixed` 的包含块从视口接管过去,
   **而顶栏正是这一族的常客**(CHART-0 为它付过一次账,记在 `TopNav.tsx` 抬头)。
   **不要把它"简化"成几个类** —— 那等于把一条量出来的事实换成一条推理。
2. ★★ **换一个标签名,就是继承树换了一段。**
   这一刀把 `<button>` 换成 `<label>`,于是 `app/globals.css` 的
   `label { font-weight: 500 }` 当场落到那一格与它的 svg 上(400 → 500)——
   **而它是被一支逐元素比签名的普查吐出来的,不是想出来的。**
   ☞ 下一次改一个元素的**标签名**时,先问:base 层有没有一条规则按标签名选中它?
3. ★ **`.prompt` 上那一句 `line-height` 是承重的,不是格式。**
   Tailwind preflight 给表单控件写 `font: inherit`,而 `font:` 简写继承的是父元素的
   **计算值** —— 一个**长度**,不再随字号走。删掉它,首页那一格当场矮 1.43 / 2.85px。
   判据在 `probe-nav-geometry` 的 N10 与逐条读数表上。
4. ★ **`records.built` 与 `search.recordsNotBuiltYet` 删了。** 单据那一节今天只有两种
   画法:有命中 / 没命中。**再想加一个"这一半还没建"的状态,要先让它【产生得出来】。**
5. ★ **`check-stop-rules-abc` 现在会为「(b) 点名的路由只有一侧量到」退 2。**
   下一刀的 drift 若有一格 `failed` 而它恰好是那 5 条之一,**比对器会拒绝给判词**,
   不再印一个绿色的零。修法照它自己打出来的那一行:定点复读 + 合并。
6. ⚠ **`operations` 这个角色在线上已经退休**(SEARCH-1 §5.4 量到),而 `AGENTS.md`
   的 `--reach` 那一节还把它列为三个角色之一。**第二次登记,处置由人决定。**
7. ⚠ **那一格里的 `<input>` 是手写的**,而 `check-component-library` **数的是
   `<button` 与 `<table`,它按构造看不见一个手写的 `<input>`。**
   理由(库组件自带几何)写在 `docs/base-components.md` §十六。

---

## 11 · 等什么

**等 Tim 确认部署。**
⚠ 这台机器够不到 Vercel(五项逐条实测全部 ABSENT,记在 `AGENTS.md`),
而 2026-09-12 立的常设规矩写着:**一刀的终端活到推送为止,面板由 Tim 自己看。**
☞ 所以这份报告**到推送为止**,而**破窗那一栏写着「不存在」,它是量出来的**
(`git diff --stat -- db/` 空)。
