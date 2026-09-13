# SEARCH-1 —— 面板、两个入口,以及那些【不需要数据库】的活(2026-09-13)

> ## ⛔ 先读这一节:委托书里有【三条断言是假的】,而它们不是同一种假
>
> AGENTS.md 的常设要求:**委托书里的每一个数,开工前当场重量一遍,并把重量的结果
> 写进报告 —— 包括量下来是对的那些。** 照办,逐条在 §1。
>
> | # | 委托书说的 | 实测 | 它是哪一种假 |
> |---|---|---|---|
> | ① | 「`probe-search-shell.mjs` 已经把现状钉在 S2/S3b」「硬导航 present=true,软导航 not in DOM」 | ★★ **HEAD 上七格全绿,`PROBEBEFORE_EXIT=0`** —— `S3b` 报 `present=true visible=true box=200x32` | **一个正确诞生、然后安静过期的数**(CONFIRM-1 那一刀自己把它修好了) |
> | ② | 「SearchShell 住在根布局里,所以那个会话带着 null 走遍全系统」 | ★ **今天开着的不是 SearchShell,是它的孪生**:根布局那个 `bare` 布尔(`CONFIRM-1-ROOT-LAYOUT-HEADER`) | **一条描述指错了对象** |
> | ③ | 「S6:让它红,然后让它绿」 | ★ **收紧后的判据 ② 当场对着【那 18 条真的】变红**,不需要先造一个假的 | **不是假,是它比委托书以为的更强** —— 照直记 |
>
> ★ ①② 合起来的后果**不是**"这一刀没事干":**那条缺陷是真的,只是它住在另一行代码上。**
> 它修了,判据在 §3,改前改后的读数并排。

---

## 1 · 委托书与 SEARCH-0 里的每一个数,开工前重量一遍

> **量法一律写在数的旁边** —— AGENTS.md:「一个数写进报告时,把【它是怎么量出来的】
> 和它写在一起」,以及「一个数被抄走时,它的【分母】掉了」。

| 数 | SEARCH-0 / 委托书说的 | ★ 本刀实测 | 量法 |
|---|--:|--:|---|
| `app/` 下路由 | 232 | ★ **232** ✓ | 本刀自写枚举器(与 `check-nav-routes` 同形:`page.tsx`/`route.ts`/`route.tsx`) |
| 注册表 `FUNCTIONS` 条目 | 83 | ★ **83** ✓ | 同上 + `check-nav-routes` 自报 |
| 动态段 `[id]` | 73 | ★ **73** ✓ | 同上 |
| 只靠前缀覆盖的静态路由 | 67 | ★ **67** ✓ | 同上 |
| ……其中动作型 | 49 | ★ **49** ✓ | 叶子词实测恰好是 `new/export/pdf/bulk/import` 五个 |
| ★ **埋着的屏幕** | **18** | ★ **18** ✓ **逐条同名** | 同上 |
| 静态孤儿(靠例外表兜住) | 9 | ★ **9** ✓ | 同上 |
| 手册锚点 | 101(4 PART / 31 小节 / 70 三级) | ★ **101** ✓(31 + 70;**PART 不是锚点**,它没有自己的正文) | `scripts/gen-manual-index.mjs`,双向钉住(切段 vs 数行) |
| 手册里的拒绝码 | 0 | ★ **0** ✓ | `grep -cE '[A-Z]{2,}_[A-Z_]{2,}' docs/manual-draft.md` |
| `MODULES` | 9 | ★ **9** ✓ | 本刀 |
| ★ `/brand-sampler` 成员 | 916 | ★ **916 · 两个视口都是** ✓ | `survey-controls --urls=/brand-sampler` 的 `totalElements`,以及本刀新加的逐元素普查 |
| ★ 改前就在溢出的 390px 路由 | 「5 条」 | ★ **5 条,逐条列名** ✓ | 见 §4.2 |
| 验证底价 | 5259s ≈ 88 min | ★ **本刀实测见 §6**,并**更正了两项 NOT MEASURED** | 每一支脚本自己那一行 |

★ **一条【量下来是假的】,而它不在上面那张表里 —— 它是委托书自己的前提**:见上面那个停止闸。

★★ **一条【SEARCH-0 没量、而本刀量了】的新读数,它改变了 S5 的做法:**
**那 18 个埋着的屏幕,今天每一个都【从它父页面上点得进去】** ——
实测 **18/18 各有 ≥1 处链接**,出处一律是父页面或父页面的页内子导航
(控制组 `/hr/employees` 也是 1 处,所以那个零不是扫描器瞎了)。
★ 而**手册自己早就这么写着**:§3.10「Twenty-one working pages are not listed in any
menu. **Each is one click from a page that is.**」
☞ **所以它们缺的不是入口,是【名字】。** 这句话决定了 S5 的落地形状,见 §2 的 S5。

---

## 2 · 逐条 S1–S10:DONE / NOT DONE,各带证据

> ★ 委托书:「walk S1–S10 one by one against what you actually changed and state
> DONE or NOT DONE for each with its evidence. **Anything you cannot mark DONE is NOT DONE.**」

### S1 · 一个面板,两个入口,外加一个快捷键 —— ★ **DONE**

* **同一个组件**:`app/components/search/SearchEntry.tsx`。顶栏画它一次
  (`app/components/nav/SearchShell.tsx`),首页画它一次(`app/page.tsx`)。
  **不是一个后端两个结果面** —— 结果那一段 JSX 只有一份,所以措辞漂不了。
* **两个入口永远不同时在屏幕上**:顶栏那一格在首页上返回 `null`
  (`usePathname()`,UI-1c ③ 的规矩一个字没动)。
* **快捷键 ⌘K / Ctrl-K**,而它的判据是 ★ **「这个入口的触发钮此刻看不看得见」**
  (`triggerRef.current?.offsetParent == null`)—— **直接问 CSS,不在 TS 里再写一遍
  Tailwind 的 `md` 断点**。一个源。
* 证据:`probe-nav-geometry.mjs` **N7**(面板打开、三节都在)· **N9**(390px 上
  ⌘K 什么都不做)· `probe-search-results.mjs` **R1/R1b/R2**(真的打字,真的有结果)。

### S2 · 面板按【三件活】定形,job ① 返回空 —— ★ **DONE**

* 三节**只要面板开着就在**,顺序固定:
  `<section data-search-slot="records">` → `"pages"` → `"manual"`。
* ★ **一个读代码的人怎么看出 job ① 插在哪** —— 三处,各带一段指名 SEARCH-2 的注释:
  1. `lib/search/types.ts` 的 `records:` 字段(类型这一侧);
  2. `app/components/search/actions.ts` 的 `records:` 分支(服务端这一侧);
  3. `SearchEntry.tsx` 里 `data-search-slot="records"` 那一节(屏幕这一侧)。
  **SEARCH-2 要做的是把 `built` 改成 `true` 并填 `hits`,不是再开一个面板。**
* ★ **它画的是「这一半还没建」,不是「没找到」**(`data-search-records-state="not-built"`)
  —— 一处缺席不许被渲染成一个答案。
* ★ **这一格差点做错,而是探针抓到的**:第一版把三节包在「有结果才渲染」里,
  于是 N7 实测读到 `slots = []` —— **面板开着,而三节一个都不在**,job ① 的槽
  只活在代码里、不活在屏幕上。改了之后 N7 读 `["records","pages","manual"]`。
* 证据:`probe-nav-geometry.mjs` **N7** · `probe-search-results.mjs` **R0/R3**。

### S3 · 手机上没有顶栏入口 —— ★ **DONE(而且是【有名字的限制】,不是缺陷)**

* `hidden md:block` ★ **一个字都没动**;**没有**加任何手机触发器。
* 三格判据钉住 Tim 接受的那三件事:
  | 格 | 读数 |
  |---|---|
  | **N8** | 390px 顶栏那一格 `display:none` |
  | **N9** | 390px 上 ⌘K 之后面板 `open=false` —— **快捷键在手机上不存在** |
  | **N10** | ★ 390px **首页那个入口画着**:`358x49.02` —— 手机上那唯一的一条路 |
* ★ **写进了两个地方,免得下一次走查把它记成缺陷**:
  `docs/forward-queue.md` 的「全局搜索」条目(连同它 CONFIRM-1 时代那条预判的
  **兑现情况**),以及 `SearchShell.tsx` / `app/page.tsx` 两处的抬头。

### S4 · 修 `CONFIRM-1-ROOT-LAYOUT-HEADER` —— ★ **DONE**(独立提交,自带证据)

见 §3。**改前 `NAVBEFORE_EXIT=1`(13 格 3 红)· 改后 `NAVAFTER_EXIT=0`(13 格 0 红)。**

### S5 · 18 个埋着的屏幕各有一条 FUNCTIONS 条目 —— ★ **DONE**

* **扩的是现有注册表**:`FUNCTIONS` **83 → 101**,`check-permission-predicate`
  自报 `FUNCTIONS 101 条(5 条跨模块,18 条带 parent)`。**没有第二份清单。**
* ★ **一个新字段 `parent`,而它的理由是量出来的**(见 §1 末尾那条新读数):
  那 18 条今天都从父页面点得进去,所以它们缺的是**名字**不是**入口**。
  带 `parent` 的条目**不画在菜单里**,而**搜索与判据 ② 都认它**。
* ★★ **「菜单一个字没变」是一个可以数出来的数,不是一句自述**:
  `MENU_FUNCTIONS = FUNCTIONS.filter(f => !f.parent)` = ★ **83 条,顺序逐字相同**。
  两个导航消费者都只读它(`lib/moduleAccess.ts` 的菜单那一支、`lib/navTrail.ts`
  的 `entryForPath`)。
* ★★ **而这里藏着这一刀最值钱的一处发现,它差点变成一道【射程被悄悄缩窄】的闸** ——
  见 §5.1。
* **零个新文案键**:那 18 条的 navKey 全部复用它们父页面今天已经在用的那一个
  (逐条核过,en/zh 都在:`overlap.entryLink` · `bank.statements` ·
  `reports.*.title` ×4 · `leave.subnav.*` ×5 · `reviews.*Title` ×2 ·
  `hr.subnav.kpiScore` · `pricing.*Card` ×3 · `receive.entry`)。
* 证据:`check-nav-routes` 自报 · `check-permission-predicate` 自报 ·
  `probe-search-results.mjs` **R1**(`/inbound/receive`)与 **R1b**(`/hr/leave/balances`)。

### S6 · 收紧判据 ②,并且【先让它红】 —— ★ **DONE**,四次注入

见 §3.2。★ **委托书要的是「造一个第十九个」;实测比它更强:收紧的那一刻,
判据对着【那 18 条真的】就红了。两件都做了,读数都在。**

### S7 · job ③ 上半:拿词搜手册 —— ★ **DONE**

* 101 个锚点,**在内存里搜,一行数据库都不读**。
* ★★ **Tim 没说、而面板必须处理的那个后果**:一个用中文搜的人在手册那一节里
  **什么都匹配不到**,那读起来是"搜索坏了"。
  ☞ 所以那一节的抬头上**常年**画一句 `search.manualEnglishOnly`(**不管有没有命中**),
  两个文案文件里都有。
* 证据:`probe-search-results.mjs` **R2**(「partially shipped」→ 手册有命中)与
  ★ **R4**(中文查询 → 手册 0 段,而那句「这一节是英文的」在)。
* ⚠ **下半(拒绝码 → 手册)【没做,而且是按裁定没做】**,已单列进
  `docs/forward-queue.md`,连同它的地基(101 个稳定锚点 + 手册版本号)与
  那条要用 **869 不要用 909** 的口径说明。

### S8 · 手册版本 v1.0.1 —— ★ **DONE**

* `docs/manual-draft.md` 前置区两行 `version: v1.0.1` / `issued: 2026-09-13`。
* **一份真源,两个读者**:`scripts/build-manual.py` 把它印在封面上
  (新增 `strip_front_matter()` + `.cover .version`,并把字体覆盖检查改成只查正文
  —— 前置区从不排版);`scripts/gen-manual-index.mjs` 把它带进索引。
* **每一条手册结果都显示它**(`search.manualVersion`)。证据:**R2** 断言
  手册那一节的文字里含 `v1.0.1`。
* ⚠ **它是手册自己的版本,与系统版本不耦合** —— 这句话写在前置区的注释里、
  生成文件的注释里、以及 `build-manual.py` 的 `strip_front_matter` 文档串里。
* **过期就红**:`node scripts/gen-manual-index.mjs` 进了 `npm run build`,
  改了手册不重跑,构建当场红(与 `gen-deep-routes` 同一条路)。

### S9 · 权限诚实的结果 —— ★ **DONE**

* 内容不给、存在说出来,**带计数、带模块名**;模块名 ★ **一定是九个一级模块之一**
  (`MODULES` 是唯一来源)。
* ★ **多属主的条目报哪个模块,是一条写下来的规则**:取声明顺序的第一个属主。
  理由写在 `actions.ts` 抬头(`activeModuleForPath` 那条规则在这里**没有答案**,
  因为这条条目被扣下正是由于他一个属主都进不去)。
* ★★ **计数必须在服务端算,而那不是性能考虑**:要数出那个「3」,就得拿
  **他看不见的那些条目的标签**去比对他打的字 —— 把那些标签发到浏览器里,
  等于把"内容不给"那一半也给了。
* **求值只有一处**:`allows()`。本刀新增的三个文件里 `perms.includes(` **0 处**,
  `check-permission-predicate` 判据 ① 自报绿。
* ★★ **证据必须走【那个真的被挡住的人】走的路** —— 一个 admin 什么都看得见,
  所以他那一侧的被扣下计数**恒为 0**,一支只跑 admin 的探针会对着一条
  **从来没有被求值过的代码路径**报绿。所以 `probe-search-results.mjs`
  起**两个**一次性账号,S9 那四格(**R5 / R5b / R5c / R5d**)跑在 **operations** 上。
  · **R5d** 是配对的那一条:他自己进得去的东西照样找得到 ——
  否则 R5 可能只是"他什么都搜不到"。

### S10 · 空状态 —— ★ **DONE**(而「最近看过」与「限定在本页主语」**不在这一刀里**)

* 空状态**不留白**:三节各自画出来,每一节说出它能找到什么;
  ★ 另有一行 `data-search-empty-recents` **明说「还没有『最近看过』」**。
* ⚠ 它们要 ~21 条索引(SEARCH-0 §Q5 实测:那 21 张表上 `updated_at` 索引 **0** 个、
  `updated_by` 索引 **0** 个)—— 索引是 schema 改动 = SEARCH-2。
* ★ **面板的形状给它们留了位置**:类型里**没有**一个恒空的 `recents` 字段 ——
  一个永远是空数组的 recents,与"还没建"在屏幕上长得一模一样,而那正是这个仓库
  反复在修的那种谎。**处置是把它说出来,不是留一个空字段。**
* 证据:`probe-search-results.mjs` **R0**。

---

## 3 · S4:那条在册的缺陷,以及它的两个方向

### 3.1 改前 / 改后,同一支探针,同一条路

| | 硬进 `/` | ★ 点着走到 `/me`(真软导航,记号验过) |
|---|---|---|
| **改前** | `[data-app-chrome]` **读不到** | **读不到** —— 根布局**不记录**它按哪条路径判的,**因为它只判过一次** |
| **改后** | `data-app-chrome="/"` | ★ **`data-app-chrome="/me"`** —— **判断跟着人走了** |

`NAVBEFORE_EXIT=1`(13 格 **3 红**:N5 · N6b · N7,**恰好是这一刀要修的三件事**)
→ `NAVAFTER_EXIT=0`(13 格 **0 红**)。

### 3.2 ★ 两个方向,两种药 —— 而第二种【客户端治不了】

* **走进 bare 路径时外壳还跟着** → `app/components/AppChrome.tsx`,`usePathname()`,
  每次软导航重新求值。
* **从 bare 路径软导航出去时外壳回不来** → ★ **治不了**:服务端那一刻没画外壳,
  客户端就没有外壳可显。
  ☞ 所以它由**一道闸**治:`check-nav-routes` 的**判据 ⑦** ——
  任何 `<Link>` / `router.push` 指向 bare 路径都变红。
  **实测开工时全树 0 处**(`<Link href="/login">` 0 · `router.push('/login')` 0 ·
  `/set-password` 同)—— 本条把那个 0 **从一次观察变成一条不变量**。
* ⚠ **服务端那一行 `bare` 留着,而且是故意的**:把外壳无条件交给客户端去藏,
  会让 `/login` 与 `/set-password` 照样跑权限/档案/未读数三次查询,并把整段导航
  渲进 RSC 载荷 —— 而 `/set-password` 上那个人**是登录着的**。
  LOGIN-1-fu1 要的是**结构性地排除**,不是"画出来再藏起来"。
* ⚠ **`display: contents` 不是随手写的**:`<body>` 是 flex,套一个普通 `<div>` 会把
  顶栏/面包屑/告知区三个 flex 子项合成一个 —— 那是一次落在**每一页**上的版式改动。
  ☞ **而这条由读数兜底,不由"我认为它不会变"兜底**:见 §4.4,顶栏盒子改前改后逐字相同。

### 3.3 四次故障注入,每一次都【先说它该红在哪一行】再跑

| 注入 | 预期 | 实测 |
|---|---|---|
| 收紧判据 ②(还没补那 18 条) | 红,并**逐条点名** | ★ `NAVROUTES_OWN_EXIT=1`,18 条各带修法 |
| 补完 18 条 | 绿 | ★ `0` |
| ★ **造一个第十九个**(`app/hr/leave/zz-gate-injection/page.tsx`) | 红,并点名**它** | ★ `NAVROUTES_INJECTED_OWN_EXIT=1`,点名 `/hr/leave/zz-gate-injection` |
| 撤掉它 | 绿 | ★ `NAVROUTES_RESTORED_OWN_EXIT=0`,路由数回到 232 |
| ★ **判据 ⑦**:往 `SearchShell.tsx` 里塞一个 `<Link href="/login">` | 红,并点名 **file:line** | ★ `NAVROUTES_ARM7_INJECTED_OWN_EXIT=1`,`SearchShell.tsx:68` |
| 撤掉它 | 绿 | ★ `NAVROUTES_ARM7_RESTORED_OWN_EXIT=0` |

判词那一行现在带着它的分母:
`bare 路径 3 条,软导航到它们的 0 处 · 埋着的屏幕 0 个(静态 159 条路由里)`。

---

## 4 · 停止条件,逐条,改前改后

> ★ 每一条都带着它的**分母**与它的**视口** —— AGENTS.md 两条:
> 「一个数被抄走时,它的【分母】掉了」与「一份『0 个不合规』的读数,
> 它的分母是【它量过的那些视口】」。

### 4.0 两趟全量普查的覆盖

| | 路由×视口 | 卡死 | 判词 |
|---|--:|---|---|
| **改前** | 142 × 2 = **284** | phone `/finance/freight`(`FONT2-PROBE-WEDGE-390`) | `DRIFTBEFORE_EXIT=0` + 补量 `BREPAIR_EXIT=0` |
| **改后** | 142 × 2 = **284** | ★ **同一条路由,又是 phone** | `DRIFTAFTER_EXIT=0` + 补量 `AREPAIR_EXIT=0` |

★ **142 = 141 条静态路由 + `/brand-sampler`**(它由 `--urls=` 补进来,
`walk()` 在目录那一层就跳过它)。两趟都覆盖断言 11 条。
⚠ **一条给下一刀的读数:这一族的卡死这次【两趟都落在同一条路由上】** ——
BTN-SIZE-1 记的是「卡的不是同一条」。**两条记载并排放着,不要合成一句。**

### 4.1 ★ (f) 顶栏自己的盒子 —— 改前改后【逐字相同】

`scripts/probe-nav-geometry.mjs`(本刀新建,**进仓库**),两个视口 × 10 次读数:

| 视口 | 改前 | 改后 |
|---|---|---|
| 1280 | `1280x53 @top=0 pad=0/0/0/0 sticky z=50` | ★ **完全相同** |
| 390 | `390x55 @top=0 pad=0/0/0/0 sticky z=50` | ★ **完全相同** |

☞ **`display: contents` 那一层没有改变顶栏的几何** —— 而这句话是量出来的,
不是"我认为它不会变"。

★ **顺带量到的两处,都在意料之中、而且都要说出来:**
* 顶栏那一格搜索框的盒子 **`200x32` → `200x32`**(class 串逐字复用);
* **首页那个入口 `358x52.38` → `358x49.02`(矮了 3.36px)** ——
  ☞ **那个差额就是「尚未启用」那个标记**。它删了,因为搜索建起来了,
    留着它会是一句假话。**这是一次有名有姓的改动,不是一次漂移。**

### 4.2 (a)(b)(c) —— `scripts/check-stop-rules-abc.mjs`(本刀新建,**进仓库**)

```
视口 2 个(desktop / phone)
路由×视口 284 组比过 · 表 194 张比过 · 字段比较 672 次
改前就在溢出的:5 组 —— phone|/finance/freight/new=27px · phone|/operation/processing/new=177px
                       · phone|/purchasing/payment-terms/new=143px · phone|/sales/orders/new=8px
                       · phone|/tools/pricing/metal-prices/bulk=24px
✓ (a)(b)(c) 一条都没踩。          STOPRULE_ABC_OWN_EXIT=0
```

★ **委托书说的「5 条已经在溢出的路由」——【逐条重量,逐条对上】**,
而 `/sales/orders/new`(8px,已知修不动)本刀**一个字都没碰**。

★ **三次故障注入,每一次都先说它该红在哪一条,再跑:**

| 注入 | 实测 |
|---|---|
| 给一条 0 溢出的 phone 路由 +1px | ★ `INJ_a_OWN_EXIT=1` —— `[(a)] phone /:整页横向溢出 0 → 1px` |
| 给 `/sales/orders/new` +5px(8 → 13) | ★ `INJ_b_OWN_EXIT=1` —— `[(b)] …(+5)一条本来就在溢出的路由长大了` |
| 把一张不横滚的表翻成横滚 | ★ `INJ_c_OWN_EXIT=1` —— 两条各自点名了表头签名 |

### 4.3 ★★ (e) `/brand-sampler` —— 逐成员、逐字段

`scripts/probe-brand-sampler.mjs`(本刀新建,**进仓库** —— 这是第六次写它,
而前五次都是一次性脚本,BTN-SIZE-1 §8.4 点过名)。

| | desktop @1440 | phone @390 |
|---|--:|--:|
| 渲染成员(改前 → 改后) | **860 → 860** | **860 → 860** |
| 连不渲染的一起数 | 903 → 903 | 903 → 903 |
| ★ **取样页自己** | ★ **817 → 817 · 多出签名 0 种 · 少掉 0 种** | ★ **817 → 817 · 0 · 0** |
| 顶栏那一堆(允许动) | 43 → 43 · 多 3 少 3 | 43 → 43 · 多 3 少 3 |

**比过成员 3440 个 · 签名比较 1158 次 · `SAMPLER_E_OWN_EXIT=0`。**

顶栏那一堆的 3 多 3 少,**逐条就是这一刀干的事**:
`+div.contents`(AppChrome)· `+div.relative hidden md:block`(原来是 `details`)·
`+button`(原来是 `summary`);`−details` · `−summary` · `−p.nav-glass…`(「还没建」那句话)。
★ 而那个外壳的盒子 **`200x32` 两侧相同**。

★ **故障注入**:把**一个** page 侧成员的 `font-size` 从 14px 改成 15px
→ `INJ_e_OWN_EXIT=1`,逐条列出那一多一少。**它抓得住一个元素的一项属性。**

> ### ★★★ 而这一格上,委托书给的那个 916 【差点把一次正确的读数判成故障】
>
> 委托书写「916 members per viewport」,本刀开工也实测到 916 —— ★ **两个都是真的,
> 而它们都来自 `survey-controls.mjs`,那一支跑在 `next dev` 上。**
> 本刀这支新探针跑在 `next start` 上,同一页同一视口实测 **903**(连不渲染的一起数)。
> 差的 13 个是 **`next dev` 自己注入的开发期元素**。
> ☞ 第一版照抄 916 当下界,探针当场 `EXIT 2`:「实测 903,而 916 是下界」——
>   **一个正确的读数,被一个借来的门槛判成了故障。**
> ☞ **处置:下界不借别的量具的数**(只问"量到了吗" + 两侧量级对得上),
>   而**两个数并排报出来,各带它的量具与服务器**。
> ★ 这是 AGENTS.md「一个数被抄走时,它的【分母】掉了」的一张新脸:
>   **掉的这一次是【它跑在哪个服务器上】。**

### 4.4 (d) S2 的五份关闭输出 —— **一字未动**,逐个 `git diff --numstat`

`control-style.ts` **0** · `input.tsx` **0** · `textarea.tsx` **0** ·
`globals.css` **0** · `table-style.ts` **0**。

### 4.5 ★ 面板【真的找得到东西吗】—— `scripts/probe-search-results.mjs`(本刀新建,**进仓库**)

**`SEARCHRES_EXIT=0`,10 格 0 红。** 逐格读数:

| 格 | 读数 |
|---|---|
| R0 空状态 | 三节 `["records","pages","manual"]` · 「还没有最近看过」那一句**在** |
| ★ R1 | 「**field receiving**」→ `Field Receiving · Purchasing · /inbound/receive` —— **Tim 自己举的那个例子,现在搜得到** |
| R1b | 「leave balances」→ `Balances · HR · /hr/leave/balances` |
| ★ R2 | 「**partially shipped**」→ 手册 **3 段**,首条 `2.4.1 The order flow`,而版本行里有 **v1.0.1** |
| R3 | 单据那一节 `state=not-built`,说的是「还没建」不是「没找到」 |
| ★ R4 | 中文查询 → 手册 **0 段**,而「这一节是英文的」那一句**在** |
| ★★ R5 | **warehouse** 搜「payments」→ **「2 more matches in Finance — you do not have permission to view them.」** |
| R5b | 模块 = `["finance"]` —— 九个一级模块之一 |
| R5c | 每一行都带着数目 |
| ★ R5d | warehouse 搜「stocktakes」→ **1 条可见**(`Stocktakes · Inventory · /stocktakes`)· 被扣下 0 行 |

> ### ★★★ 而 R5d 那条配对断言,买到的东西比它自己大得多 —— 见 §5.4

### 4.6 §5 的其余几支

| | 判词 |
|---|---|
| `npx tsc --noEmit` | ★ `TSC_OWN_EXIT=0` |
| `npm run build` | ★ `BUILDAFTER_EXIT=0` · **最终状态** ★ `BUILDFINAL_EXIT=0`(**27** 条静态检查 + `next build`) |
| `python3 db/gate.py` | ★ `GATE_EXIT=0` —— wall-clock **365s**;四个判词全绿(可重建性 · 镜像 vs 线上 · 行为断言 · 匿名面基线 327 条) |
| `scripts/check-nav-routes.mjs` | ★ 红 → 绿 → 红 → 绿,四次,见 §3.3 |
| `scripts/probe-search-shell.mjs` | ★ 改前 `PROBEBEFORE_EXIT=0` · 改后 `PROBEAFTER2_EXIT=0` |
| `scripts/smoke-routes.mjs` | ★ `SMOKE_EXIT=0` —— **248 ok · 6 skipped(没数据)· 0 FAILED**(229 条路由 + 19 项专门探针);计时 **223** 条,合计 **648.1s** |

### 5.4 ★★★ 一个【已经退休】的角色,让三条绿灯证明不了它们声称的那件事

`probe-search-results.mjs` 第一版拿 **`operations`** 当那个"被挡住的人"——
`AGENTS.md` 的 `--reach` 那一节把它列为三个角色之一,所以它读起来是一个安全的选择。

★ **实测:它在线上是 `is_active=false` · `deleted_at=2026-09-10`。**
而 `current_user_permissions()` 的 WHERE 里写着
`AND r.is_active AND r.deleted_at IS NULL` —— ☞ **那个账号解析出来是【零权限】。**

★★ **后果值得读两遍:R5 / R5b / R5c 三格【照样全绿】。**
一个零权限的人当然看得到「N more matches in X」,模块名当然是九个之一,
那句话当然带着数目。**三条断言一条都没有说谎,而它们证明的是一个极端情形,
不是 S9 要的那个一般情形**(一个人**一部分看得见、一部分看不见**)。
☞ **把它们读成「S9 通过了」,就是拿极端冒充一般。**

★★★ **抓住它的是 R5d —— 那条配对的断言:「他自己进得去的东西照样找得到」。**
它红了,而**它红的理由不是产品坏了,是探针挑错了角色**。

> ### **判词:一条「它被挡住了」的断言,必须配一条「而它没被全挡住」。**
> 单独的前者,对一个【什么都看不见】的主语恒真 —— 而那个主语可以是
> 一个退休的角色、一个没落地的授权、一次失败的登录。
> **三条绿灯加起来的强度,不如那一条配对的断言。**

**处置:换成 `warehouse`**(线上活着,12 条权限:inbound / inventory / output /
stocktakes / logistics / tasks,**没有 finance**)。于是两侧都不是空的:
「payments」→ 被扣下 1 行(Finance,2 条);「stocktakes」→ **可见 1 条**。

⚠ **一条【不属于这一刀、而这一刀看见了】的事,照直记,不清扫:**
`AGENTS.md` 的 `--reach` 那一节仍然把 `operations` 写成三个角色之一
(「admin | operations | finance」,并带着它 25m28s 的实测耗时),
★ **而那个角色已经退休了**。本刀**没有改 AGENTS.md 的那一节** ——
它不是这一刀的射程,而一次顺手的编辑会让下一个人以为有人核过整节。
**登记在这里,处置由人决定。**

---

---

## 5 · 四件【本刀量到、而委托书没有写】的事

### 5.1 ★★★ 一道闸的射程,被【另一处的改动】悄悄缩窄了 —— 而两边都没有报错

`scripts/gen-deep-routes.mjs` 从 `FUNCTIONS` 算「面包屑还缺哪些段名」
(`BREADCRUMB_SEGMENTS`),而 `check-i18n` 的 MANIFEST **从那份清单现读**。

★ **补上那 18 条之后,它当场从 25 条掉到 7 条:**

```
- ['amend','balances','bulk','calculator','calendar','cycles','done','edit','formulas',
   'grants','holidays','import','ledger','metal-prices','new','overlap','receive',
   'reconcile','safety','scale','score','snapshot','statements','types','violations']   25
+ ['amend','bulk','done','edit','import','new','reconcile']                              7
```

☞ **后果不是少了一份清单**:运行时的 `entryForPath()` 读的是 `MENU_FUNCTIONS`,
所以它**照旧**要 `breadcrumb.balances` 那 18 段 —— 而 `check-i18n`
**从此不再检查它们**。少一句谁都不会红,而屏幕上会印出一串 `breadcrumb.balances`。

> ### **这正是 AGENTS.md 那条「一道闸只守它当时那条路 —— 换了推导来源,闸就要跟着搬」。**
> **判据必须与运行时那一支【同源】。** 生成器现在也只看 menu 那一层,
> 于是 `lib/deepRoutes.generated.ts` **一个字节都没变** ——
> ★ **而那份"没变"本身就是「面包屑一截都没动」的证明。**

★ 并且给它配了一条**空集断言**:解析出 0 条 `parent` 时那句过滤什么都没过滤,
而它与"注册表里没有 parent 条目"在输出上一模一样 —— 两者都要红。

### 5.2 ★★ 一个记号被两个不同的东西戴着,就不再是一个记号

第一版把 `data-nav="search-shell"` 写死在共享组件上,于是**首页那个入口也戴上了它**。
`probe-search-shell.mjs` 的 **S1 与 S6 当场变红** —— 而它们断言的
「**顶栏**那一格在首页上不画」**仍然成立**,只是判据再也分不出两者。

☞ 处置:**记号由入口给**(`markers` prop),而且给的就是它们改前戴的那一个:
顶栏 `data-nav="search-shell"` · 首页 `data-home-search="shell"`。
**于是两支在册的探针一个字都不用改。**

★ 同一课的第二面:`probe-nav-geometry` 第一版**只认顶栏那个记号**,于是在**首页**上
把 shell 与 trigger 都读成 `null` —— 而那读起来像「首页那个入口没画」,**那是一句假话**。
**一支看不见的探针必须说"我没看见",不许说"它不在"。** 改了之后改前读数是
`358x52.38`,真实且可比。

### 5.3 ★ 两颗按钮,两种处置,而分界是【有没有一段必须保住的几何】

`check-component-library` 拦下了本刀两颗手写 `<button>`。

* **「关闭」那一颗 → 走了库**(`<Button variant="ghost" size="sm">`):它没有任何几何要保,
  而且它住在面板里,面板关着时根本不渲染。
* ★ **触发钮 → 留成手写的,并登记进基线**(理由整段写进 `docs/base-components.md` §十六):
  它的 class 由**入口**给,而那两串正是这一刀**必须保住不变**的东西
  (顶栏 `h-8 w-[200px] rounded-full`,与改前那个 `<summary>` 逐字相同;
  首页 `home.module.css` 的 `.box`)。`<Button>` 自带 `rounded-lg` 与自己的高度档位,
  套上去**这两格的几何当场就变** —— 而顶栏在**每一页**上。
  ☞ **走库会把一次「接上搜索」的改动变成一次全树版式改动,而那正是停止条件 (f) 盯的东西。**
  **停止条件与组件库规矩撞在一起时,先量,再决定。**

⚠ **基线这一次同时【收紧了 6 处】**,而那 6 处**不是这一刀改出来的**:
把本刀的改动 `git stash` 掉、在干净的 HEAD 上重跑,**同样报出那 6 处**。
照这道闸自己的规矩(基线只会缩短)顺手收紧,并把这次核对写在这里。

---

## 6 · 这一刀的验证花了多久 —— **只记量到的**

> SEARCH-0 报的过程底价是 **5259s ≈ 88 分钟**,并把两项标成 NOT MEASURED。
> ★ **本刀补上了其中一项,另一项照旧照直记。**

| 量具 | 实测 | 身份 |
|---|--:|---|
| `npm run build`(27 条静态检查 + `next build`) | ★ **40s**(冷) | ★ **CONFIRMED —— SEARCH-0 标的是 NOT MEASURED,本刀补上** |
| `npx tsc --noEmit` | ★ **11s** 冷 · **1s** 增量(`tsconfig.tsbuildinfo`) | ★ **CONFIRMED —— 同上,而它【有两个数】,因为它有缓存** |
| `--mode=drift` 142 × 2(**一趟**) | ★ **1322s**(改前)· **1383s**(改后) | CONFIRMED |
| ……而一刀要**两趟** | ★ **2705s ≈ 45 min** | CONFIRMED |
| 卡死路由的补量 ×2 | ~**120s** | CONFIRMED |
| `db/gate.py` | ★ **365s**(脚本自报 wall-clock) | CONFIRMED |
| `scripts/probe-nav-geometry.mjs` ×2(本刀新建) | 各约 **60s** | CONFIRMED |
| `scripts/probe-search-shell.mjs` ×2 | 各约 **60s** | CONFIRMED |
| `scripts/probe-brand-sampler.mjs` ×2(本刀新建) | 各约 **50s** | CONFIRMED |
| `scripts/probe-search-results.mjs`(本刀新建) | 约 **70s** | CONFIRMED |
| `scripts/smoke-routes.mjs` | ★ **648.1s**(计时 223 条) | CONFIRMED | CONFIRMED |

★★ **一笔 SEARCH-0 没有列、而本刀真的付了的账:为了拿到「改前」那几份读数,
树要被 `git stash` 回 HEAD 再构建一次 —— 本刀做了【三次】**
(nav 几何一次、取样页两次,因为中间改了那支探针的口径)。
☞ **每一次都是一次完整的 `next build` + 一趟探针。**
**下一刀要给一支新探针拿改前读数时,把这一笔算进去。**

⚠ **而这里有一次【差点作废的读数】,照直记:**
第二次取样页普查跑完之后,树已经 `git stash pop` 回来了,**而 `.next` 还是
HEAD 那一份** —— 于是那一趟"改后"普查量的是**改前的构建**。
比对器给出一个漂亮的全零。
★ **抓住它的不是任何一道闸,是【一个我知道该动而它没动的数】**:
顶栏那一堆报 `43 → 43`,而我知道那一格刚刚从 `<details>` 换成了 `<button>`、
并且少了一个 `<p>`。☞ 重建之后重量,读数才对上(43 → 43,而多 3 少 3)。
**AGENTS.md 那条「一次长量具的读数,可以被别处一条毫不相干的命令悄悄废掉」——
这一次那条"毫不相干的命令"是【我自己为了拿改前读数而跑的那次构建】。**
☞ **处置写给下一刀:`git stash` 换树之后,【下一次量之前必须重建】,
而且最好在探针里印出它读到的 `BUILD_ID`。**

---

## 7 · 每一条命令,以及**它自己打出来的那一行退出码**

> ★ 长活一律走 `db/run_detached.sh` —— 判词只认脚本自己写进日志的那一行。

| # | 干什么 | 判词 |
|---|---|---|
| 1 | 开工门:`git status` 干净,三个 SHA 相同 | `f9e68d5d7146feb5333e86189f77d5adb8fa8082` ×3 |
| 2 | **改前** `probe-search-shell.mjs` | ★ **`PROBEBEFORE_EXIT=0`** —— 7 格 **0 红**(★ 委托书前提在此作废) |
| 3 | **改前**全量 drift(141 静态 + `/brand-sampler`)× 2 视口 | ★ **`DRIFTBEFORE_EXIT=0`** · 覆盖断言 11 条 · ⚠ phone `/finance/freight` 撞 `FONT2-PROBE-WEDGE-390` |
| 4 | 改前补量 `--only=/finance/freight,…` | ★ **`BREPAIR_EXIT=0`** —— **只并卡住的那一条**,陪跑读数丢弃;并完 failed **0 / 0** |
| 5 | **改前** `probe-nav-geometry.mjs`(新,进仓库) | ★ **`NAVBEFORE_EXIT=1`** —— 13 格 **3 红**(N5 · N6b · N7 = 这一刀要修的三件) |
| 6 | `npx tsc --noEmit` | ★ **`TSC_OWN_EXIT=0`** |
| 7 | `npm run build`(27 条静态检查 + `next build`) | ★ **`BUILDAFTER_EXIT=0`** |
| 8 | **改后** `probe-nav-geometry.mjs` | ★ **`NAVAFTER_EXIT=0`** —— 13 格 **0 红** |
| 9 | **改后** `probe-search-shell.mjs` | ★ **`PROBEAFTER2_EXIT=0`** —— 7 格 **0 红** |
| 10 | **改后**全量 drift 142 × 2 | ★ **`DRIFTAFTER_EXIT=0`** · 补量 **`AREPAIR_EXIT=0`** |
| 11 | 停止条件 (a)(b)(c) 比对器(新,进仓库) | ★ **`STOPRULE_ABC_OWN_EXIT=0`** —— 284 组 · 194 张表 · 672 次字段比较 · 踩线 **0** |
| 12 | 停止条件 (e) `/brand-sampler` 逐元素普查(新,进仓库) | ★ **`SAMPLER_E_OWN_EXIT=0`** —— 成员 **3440** · 签名比较 **1158** 次 · **取样页自己 0 处差异** |
| 13 | `probe-search-results.mjs`(新,进仓库) | ★ **`SEARCHRES_EXIT=0`** —— 10 格 **0 红** |
| 14 | `python3 db/gate.py` | ★ **`GATE_EXIT=0`** —— wall-clock **365s**;四个判词全绿 |
| 15 | `node scripts/smoke-routes.mjs` | ★ **`SMOKE_EXIT=0`** —— 248 ok · 6 skipped · **0 FAILED**;计时 223 条,合计 648.1s |
| 16 | ★ **故障注入 ×10** | 闸 4 次(§3.3)· 停止条件 (a)(b)(c) 各 1 次 · (e) 1 次 · **每一次都先说它该红在哪一条,再跑**;另有 2 次【注入了却没咬人】的,见 §8 |

## 8 · 两次【注入了却没咬人】的,以及它们各自是哪一种

> AGENTS.md:**一次没有咬人的故障注入是【信息】,不是麻烦。** 它说的是两件事之一,
> 而两件都要查到底:① 你注入的不是你以为的那个故障;② 这条断言本来就看不见这个性质。

| # | 看起来 | 查到底之后 | 哪一种 |
|---|---|---|---|
| ① | `probe-brand-sampler` 第一版报 `EXIT 2`:「实测 903,而 916 是下界」 | ★ **916 是【另一支量具在另一台服务器上】的数**(`survey-controls` 跑 `next dev`) | ★ **①** —— 注入的不是故障,是一个**借来的门槛** |
| ② | 第二次取样页比对给出一个漂亮的全零 | ★ **那一趟"改后"量的是 HEAD 的构建**(`git stash pop` 之后没重建) | ★ **①** —— 那次读数**根本没有看见这一刀** |

★ **两次都不是"断言写松了",而是【我喂给它的东西不对】** —— 而两次都是被
**一个我知道该动、而它没动的数**抓住的(第一次是 903 vs 916,第二次是顶栏那一堆 43 → 43)。
☞ **处置写在 §6 末尾。**

---

## 9 · 我【没有】做的事,逐条点名

* ★ **一条迁移都没有。** `git diff --stat -- db/` 空,`git status -- db/` 空。
* ★ **没有动 S2 的五份关闭输出**(逐个 `git diff --numstat` = 0,见 §4.4)。
* ★ **没有碰 `hidden md:block`,没有给手机加任何搜索入口**(S3,Tim 明说接受)。
* ★ **没有在 `/sales/orders/new` 上尝试任何修补**(已知修不动,委托书点名 STOP)。
* ★ **没有做 job ①**(找单据)—— 它要迁移,属于 SEARCH-2。**槽留好了,三处各带注释。**
* ★ **没有做 job ③ 的下半**(拒绝码 → 手册)—— Tim 已裁定本刀只做上半;
  已单列进 `docs/forward-queue.md`,连同 869 / 909 的口径说明。
* ★ **没有改那三份与注册表重复的页内清单**(`LeaveSubnav` / `reports` / `pricing`)——
  理由与改法逐条写进了队列。**它们今天是【两处写着同一件事】,这一条照直记。**
* ★ **没有改 `AGENTS.md` 里那条把 `operations` 列为三个角色之一的记载** ——
  那个角色已经退休(§5.4),但改它不是这一刀的射程。**报告,不清扫。**
* ⚠ **没有量"一次搜索在生产上要多久"** —— SEARCH-0 §4.2 已经说明今天量不了
  (那 21 张单据表合计 196 行,`EXPLAIN` 全是 Seq Scan)。
  ☞ 而本刀的 job ② / job ③ **一行数据库都不读**,所以今天这支服务端动作的成本
  = **一次权限查询**。job ① 进来那天,这句话要重写。
* ⚠ **防抖 200ms 与「一次显示 8 / 5 条」是【挑】出来的,不是量出来的** ——
  SEARCH-0 §8 把它们列在下一轮,而它们的前提(Q3/Q4)还没答。
  **挑一个数的代价由 `more` 那一行带回去:不许静默截断。**
* ⚠ **排序只有一条规则**(标题/标签命中的排在正文/地址命中的前面),
  **其余的排序不在这一刀里**,理由同上。

---

### ★ 破窗 —— 这一刀没有开窗,而这句话有证据

`git diff --stat -- db/` = **空**。一条迁移都没有。
☞ 不存在「旧代码 + 新库」那个窗口。**这一行不是空着,是量过之后为零。**

---

## 10 · 两个提交,以及它们为什么分开

> 委托书:「Split by revert blast radius, not by size.」

| 提交 | 内容 | 为什么它自己一个 |
|---|---|---|
| **①** | **S4 一条** —— `AppChrome.tsx` · `app/layout.tsx` · `check-nav-routes` 判据 ⑦ · `probe-nav-geometry.mjs` · `known-issues.md` 那一条 | ★ 它是一条**先于这一刀就存在**的缺陷,带着**自己的**改前/改后读数。**撤掉搜索面板不该把它一起撤掉,反过来也一样。** |
| **②** | S1 S2 S3 S5 S7 S8 S9 S10 · S6 的闸 · 全部文档与量具 | 它们互相依赖:面板要注册表,注册表要闸,闸要那 18 条。**撤一个就得撤全部。** |

---

## 11 · 下一刀开工前要知道的

1. ★★ **SEARCH-2 填的是一个【已经存在的槽】,三处各有一段指名它的注释:**
   `lib/search/types.ts` 的 `records:` · `app/components/search/actions.ts` 的
   `records:` 分支 · `SearchEntry.tsx` 的 `data-search-slot="records"`。
   **把 `built` 改成 `true` 并填 `hits`。不要再开一个面板。**
   ⚠ 它要的三样东西(`document_types` · `pg_trgm` + GIN · ~21 条索引)**全部是迁移**,
   所以那一刀**有破窗**,要按成文的顺序走(迁移 → gate 绿 → 推送)。
2. ★★ **`parent` 这个字段今天有 18 个住户,而它的两个消费者是写死的**
   (`lib/moduleAccess.ts` 的菜单那一支、`lib/navTrail.ts` 的 `entryForPath`)。
   **再加第三个导航消费者时,记得问它读 `FUNCTIONS` 还是 `MENU_FUNCTIONS`** ——
   §5.1 那一条就是这么被抓到的,而它差一点让一道 i18n 闸的射程缩掉 18 段。
3. ★ **`operations` 这个角色在线上已经退休**(`is_active=false` · `deleted_at=2026-09-10`),
   而 `AGENTS.md` 的 `--reach` 那一节还把它列为三个角色之一。**处置由人决定。**
4. ★ **给一支新探针拿"改前"读数,要付一次 `git stash` + 一次完整构建的账**,
   而且 **stash 换树之后下一次量之前必须重建**(§6 末尾那次差点作废的读数)。
   建议:下一支探针在开头就印出它读到的 `.next/BUILD_ID`。
5. ★ **手机上的搜索入口只有首页那一条**(Tim 在 S3 上明说接受)。
   要不要给顶栏加一个手机形态,是一件独立的活,Tim 没有裁过 ——
   已连同它的判据(N8/N9/N10)记进 `docs/forward-queue.md`。
6. ⚠ **那三份与注册表重复的页内清单**(`LeaveSubnav` / `inventory/reports` /
   `tools/pricing`)—— 改法是机械的,顺序与文案键**已经对齐过**,但它**动渲染**,
   所以要配一次版式普查。已进队列。

---

## 12 · 等什么

**等 Tim 确认部署。**
⚠ 这台机器够不到 Vercel(五项逐条实测全部 ABSENT,记在 `AGENTS.md`),
而 2026-09-12 立的常设规矩写着:**一刀的终端活到推送为止,面板由 Tim 自己看。**
☞ 所以这份报告**到推送为止**,破窗那一栏写着「不存在」,而它是量出来的。
