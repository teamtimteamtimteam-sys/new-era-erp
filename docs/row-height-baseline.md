# 行高基线 —— 390px,格子里有控件的表

> **这份文件存在的理由,一句话:**
> 下一族刀要动的是**会推动行高**的那一族控件;而表格那一族刚刚**逐张判过**
> 「390px 上哪几列装得下」—— 判的依据是**今天的行高**。
> **一次先于基线的施工,说不出自己有没有推翻那些判断。**
> ☞ 所以这份基线先落地,而产它的那一刀(INPUT-0)**一个控件都没有改**。
>
> ★★ **而这不是一句假想的担心:** 量出来 **36 个控件的高度已经被表格那一族改过了** ——
> `tableC.cell` 的 `text-[15px]` 经由 Tailwind preflight 的 `font: inherit`
> 传进格子里的控件,把 21 个从 42px 改成 39.4219px、10 个从 30px 改成 31.4219px、
> 5 个从 28px 改成 29px。**当时没有人量它。** 详见 INPUT-0 交回报告 §2.3。

| | |
|---|---|
| **量的那一天** | 2026-09-10T07:09:40.434Z |
| **量的那个 HEAD** | `618fb11b9d6c31f99b27021d76c99981cbe64ea3` |
| **量具** | `scripts/survey-controls.mjs` |
| **原样的命令** | `node scripts/survey-controls.mjs --mode=drift` 与 `--mode=edit` |
| **读数原件** | `.survey-out/controls-drift-FULL.json` · `.survey-out/controls-edit-baseline.json`(**不进仓库** —— `.survey-out/` 是生成物) |
| **视口** | phone **390×844**(dsf=3, mobile=true);桌面 1440×900 的同一读数一并附在机读块里 |
| **走到的路由** | **141 条静态路由**(desktop 141/141 · phone 141/141,其中 `/finance/freight/new` 在 phone 上首跑卡死,**单条重量后补齐**,见 §5) |

---

## 1 · ★ 这份基线【是什么】,以及它【不是什么】

**它是:** 上面那个 HEAD 上,**390px、真数据、水合之后**,每一张
**格子里真的有控件**的表,它的**表头行高**与**每一条表体行的高度**。

**它不是:**

* **不是一份"应当是多少"。** 它是一份"今天是多少"。**没有一个数是标准。**
* **不是全系统。** 只覆盖**静态路由**;带 `[id]` 的详情页与编辑页**一条都没走**
  (取 id 那套机制住在 `scripts/smoke-routes.mjs` 里,复制它就是仓库里第二份会漂的定义)。
  **那些页面上的表是【未测量】,不是【没有控件】。**
* **不是所有状态。** §3 掀开了 `<EditableTable>` 的行内编辑那一态;
  `AddRowPanel`(`useState` 后面那张表单)、对话框、折叠行**都没有打开**。

### ★ 判据:什么叫"格子里有控件"

**渲染层的 `el.closest('table')`** —— 不是"这个文件里同时出现了 `<input` 与 `<table`"。
两者不是一回事,而且**分歧就是这一族刀踩过的那个坑**:`<DataTable>` 的单元格由列的
render 函数画出来,**控件在源码里根本不住在 `<table>` 块里**
(TABLE-CONVERT-4 §「第七张是普查归错类的 B」正是这件事)。反过来也成立:
`AddRowPanel` 是**表下面的一个 `<div>`**,它的字段一个都不在格子里。

**三个数,量的是三件不同的事:**

| 判据 | 数 |
|---|---|
| 文件同居(源码里同一文件既有控件又有表格标记) | **334 / 877 代码点** · 53 / 188 文件 |
| **渲染归属(首屏)** | **145 / 628**(desktop,不含 label)= **23.1%** |
| 渲染归属(点开编辑之后) | 见 §3 |

---

## 2 · 首屏:格子里有控件的表(12 张,10 条路由)

| 路由 | # | 列 | 行 | 格子里的控件 | 表头行高 | 表体行高(390px) | 表自己横滚? |
|---|--:|--:|--:|--:|--:|---|---|
| `/finance/freight/new` | 0 | 4 | 15 | **15** | 42.42 | 63.84×14 · 85.77×1 | **是**(327 > 326) |
| `/finance/fx/bulk` | 0 | 4 | 7 | **21** | 97 | 39×7 | **是**(497 > 326) |
| `/finance/processing-costs` | 0 | 6 | 5 | **6** | 63.84 | 81×4 · 81.5×1 | 否 |
| `/finance/processing-costs` | 1 | 6 | 4 | **5** | 63.84 | 81×3 · 81.5×1 | 否 |
| `/hr/payroll/new` | 0 | 7 | 7 | **35** | 57 | 73×6 · 53×1 | **是**(740 > 326) |
| `/operation/orders/new` | 0 | 2 | 5 | **10** | 37 | 47×5 | (没有滚动壳) |
| `/operation/orders/new` | 1 | 4 | 3 | **12** | 97 | 47×3 | (没有滚动壳) |
| `/purchasing/payment-terms/new` | 0 | 5 | 1 | **5** | 41 | 63×1 | (没有滚动壳) |
| `/sales/quotes/new` | 0 | 3 | 5 | **15** | 42.42 | 52.42×4 · 52.92×1 | (没有滚动壳) |
| `/tools/pricing/calculator` | 0 | 2 | 7 | **7** | 42.42 | 60.42×6 · 60.92×1 | (没有滚动壳) |
| `/tools/pricing/formulas/new` | 0 | 2 | 7 | **7** | 42.42 | 60.42×6 · 60.92×1 | (没有滚动壳) |
| `/tools/pricing/metal-prices/bulk` | 0 | 3 | 7 | **7** | 42.42 | 128.11×6 · 128.61×1 | (没有滚动壳) |

**合计 73 条表体行,15 个不同的行高值,145 个控件。**

---

## 3 · ★★ 第二态:`<EditableTable>` 点开「编辑」之后

**首屏读数在这一族表上是 0 个控件 —— 它们的行要点一下才变成输入框。**
量具的 `--mode=edit` 把那一颗、且只有那一颗按钮点下去
(判据:住在 `tbody tr` 里 · className 含 `text-blue-600` · 不带 `aria-expanded`;
它的 `onClick` 是 `begin(row)`,**纯本地 state,一个请求都不发**),再量一遍。

| 路由 | 格子里的控件 | **只读那一行** | **编辑那一行** | 差 |
|---|--:|--:|--:|--:|
| `/hr/leave/types` #0 | **12** | 134.41px(中位) | **229px** | **+94.59px** |
| `/hr/reviews/scale` #0 | **14** | 45.5px(中位) | **255px** | **+209.50px** |

> ### ☞ 一条要紧的读法:**编辑态的行比只读行高一个数量级。**
> 所以「改一个控件的高度会把行推高多少」在这一族表上**不是几个像素的问题**。
> 一次施工必须把这一态一起量,而**首屏基线单独看不见它**。

**另外两条 `<EditableTable>` 路由点不动,而那也是一个读数,不是一次沉默:**

* `/hr/kpi/score` —— 候选按钮 **0 颗**,点了 **0 颗**,表内控件 0 → 0。**记成 `clickHadNoEffect`。**
* `/me` —— 候选按钮 **0 颗**,点了 **0 颗**,表内控件 0 → 0。**记成 `clickHadNoEffect`。**

---

## 4 · ★ 今天已经在哪里溢出 —— 「后来长高之后在哪里溢出」的参照点

### 4.1 整页横向溢出的路由(390px):**7 条**

| 路由 | 文档 scrollWidth | 视口 | 超出 |
|---|--:|--:|--:|
| `/finance/freight/new` | 417 | 390 | **+27** |
| `/logistics/lanes` | 402 | 390 | **+12** |
| `/operation/processing/new` | 806 | 390 | **+416** |
| `/purchasing/payment-terms/new` | 613 | 390 | **+223** |
| `/sales/orders/new` | 595 | 390 | **+205** |
| `/settings/accounts` | 425 | 390 | **+35** |
| `/tools/pricing/metal-prices/bulk` | 407 | 390 | **+17** |

> ★ 其中 **3 条同时是"格子里有控件"的路由**:
> `/finance/freight/new` · `/purchasing/payment-terms/new` · `/tools/pricing/metal-prices/bulk`
> —— **这几条今天就已经在边上了。**

### 4.2 表自己横滚的(390px):**11 张**

| 路由 | # | 列 | 格子里的控件 | 壳宽 | 内容宽 |
|---|--:|--:|--:|--:|--:|
| `/finance/assets` | 0 | 13 | 0 | 326 | **353** |
| `/finance/cash-forecast` | 0 | 14 | 0 | 326 | **1678** |
| `/finance/cash-forecast` | 1 | 14 | 0 | 326 | **1561** |
| `/finance/close` | 0 | 8 | 0 | 326 | **340** |
| `/finance/freight/new` | 0 | 4 | 15 | 326 | **327** |
| `/finance/fx/bulk` | 0 | 4 | 21 | 326 | **497** |
| `/finance/packs` | 0 | 10 | 0 | 326 | **339** |
| `/hr/payroll/new` | 0 | 7 | 35 | 326 | **740** |
| `/settings/reference` | 0 | 4 | 0 | 326 | **544** |
| `/settings/reference` | 1 | 4 | 0 | 326 | **544** |
| `/settings/reference` | 2 | 4 | 0 | 326 | **544** |

---

## 5 · ★ 后来的刀怎么用它

1. 重跑同一支量具:`node scripts/survey-controls.mjs --mode=drift`(以及 `--mode=edit`)
2. 比对:`node scripts/survey-controls.mjs --mode=compare --a=<旧读数> --b=<新读数>`
   —— 它**逐个成员比名单**(`视口|路由|表签名|行号`),**不比总数**;
   三个数(多出 / 少掉 / 值变)**全是 0 时它 EXIT 1**,判「这一次比对不作数」。
3. 然后就能说出那句话:**「这一行长高了 N 像素,而它现在在这里溢出」。**

> ### ⚠ 三条用之前必须知道的
> ① **行高是【内容决定的】。** 同一张表换一批数据,行高会变,**那不是一次样式回归**。
>    机读块里每一行都带着**它那一行的第一格文字**(截断到 32 字),
>    正是为了让「行长高了」与「换了一行数据」分得开。
>    **这是这份基线能给的最强保证,它不等于把数据钉死。**
> ② **表的身份是【表头文字签名】,不是序号。** 序号会因为页面上多一张表而整体错位。
> ②b ★ **而【行】的身份没有那么强,这一条必须说清楚:**
>    `rowFirstCell` 取的是**那一行第一格的文字**,而**第一格是控件的时候它是空的** ——
>    实测本份基线 **73 条行里有 24 条是空的**,集中在三张表:
>    `/finance/freight/new`(15/15)· `/finance/processing-costs` #0(5/5)· #1(4/4)。
>    ☞ **在这三张表上,行的对齐只能退回【下标】** —— 数据没变时下标是稳的,
>      数据变了就分不清"行长高了"与"换了一行"。
>    ☞ **我【没有】为此改量具再重量一遍**:那会让这份基线的一部分来自另一个版本的量具,
>      而**"照着提交的量具重跑一遍能得到同一份基线"比一个更好看的行标签值钱**。
>      要修就下一刀连量具一起改、整份重量。
> ③ **编辑态会插入额外的 `<tr>`**(手机上的展开面板行),于是**按下标对齐行是错的** ——
>    要按 `rowFirstCell` 对齐。§3 那张表就是这么算的。

**一条已知的修补,写在这里而不是藏起来:**
`/finance/freight/new` 在 phone 上**首跑渲染器卡死**(CDP timeout)。
**同一支量具、同一个 HEAD、单条重跑补齐**,并在读数文件的 `notes.repaired` 里留了记录。
**它不是一条被悄悄填上的空。**

---

## 6 · 机读块(给下一刀直接 diff 用)

### 6.1 首屏

```json
[
 {
  "route": "/finance/freight/new",
  "key": "h:/Batch/Quantity/Remaining",
  "idx": 0,
  "cols": 4,
  "bodyRows": 15,
  "controlsInCells": 15,
  "headH": 42.42,
  "rowH": [
   85.77,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84
  ],
  "rowFirstCell": [
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   ""
  ],
  "shellW": 326,
  "shellScrollW": 327,
  "overflowsShell": true,
  "desktopHeadH": 42.42,
  "desktopRowH": [
   42.92,
   42.42,
   42.42,
   42.42,
   42.42,
   42.42,
   42.42,
   42.42,
   42.42,
   42.42,
   42.42,
   42.42,
   42.42,
   42.42,
   42.42
  ]
 },
 {
  "route": "/finance/fx/bulk",
  "key": "h:Rate Date/TT buy (bank buy/TT sell (bank se/Mid",
  "idx": 0,
  "cols": 4,
  "bodyRows": 7,
  "controlsInCells": 21,
  "headH": 97,
  "rowH": [
   39,
   39,
   39,
   39,
   39,
   39,
   39
  ],
  "rowFirstCell": [
   "2026-09-04",
   "2026-09-05",
   "2026-09-06",
   "2026-09-07",
   "2026-09-08",
   "2026-09-09",
   "2026-09-10"
  ],
  "shellW": 326,
  "shellScrollW": 497,
  "overflowsShell": true,
  "desktopHeadH": 37,
  "desktopRowH": [
   39,
   39,
   39,
   39,
   39,
   39,
   39
  ]
 },
 {
  "route": "/finance/processing-costs",
  "key": "h://Run/Cost type/Amount/Recorded",
  "idx": 0,
  "cols": 6,
  "bodyRows": 5,
  "controlsInCells": 6,
  "headH": 63.84,
  "rowH": [
   81.5,
   81,
   81,
   81,
   81
  ],
  "rowFirstCell": [
   "",
   "",
   "",
   "",
   ""
  ],
  "shellW": 292,
  "shellScrollW": 292,
  "overflowsShell": false,
  "desktopHeadH": 42.42,
  "desktopRowH": [
   41.5,
   41,
   41,
   41
  ]
 },
 {
  "route": "/finance/processing-costs",
  "key": "h://Run/Cost type/Amount/Recorded",
  "idx": 1,
  "cols": 6,
  "bodyRows": 4,
  "controlsInCells": 5,
  "headH": 63.84,
  "rowH": [
   81.5,
   81,
   81,
   81
  ],
  "rowFirstCell": [
   "",
   "",
   "",
   ""
  ],
  "shellW": 292,
  "shellScrollW": 292,
  "overflowsShell": false,
  "desktopHeadH": 42.42,
  "desktopRowH": [
   41.5,
   41,
   41,
   41
  ]
 },
 {
  "route": "/hr/payroll/new",
  "key": "h:Employee/Gross pay/Employee CPF/Employer CPF/Deductions/Net pay/Check",
  "idx": 0,
  "cols": 7,
  "bodyRows": 7,
  "controlsInCells": 35,
  "headH": 57,
  "rowH": [
   73,
   53,
   73,
   73,
   73,
   73,
   73
  ],
  "rowFirstCell": [
   "EMP-2026-0001Choo Er Teh",
   "EMP-2026-0002Tim",
   "EMP-2026-0003Vince Goh",
   "EMP-2026-0004Sandra Yap",
   "EMP-2026-0005Cheng Siong Phua",
   "EMP-2026-0006Fu Sheng Wong",
   "ZZ-2BL-186301ZZ 2BL"
  ],
  "shellW": 326,
  "shellScrollW": 740,
  "overflowsShell": true,
  "desktopHeadH": 37,
  "desktopRowH": [
   39,
   39,
   39,
   39,
   39,
   39,
   39
  ]
 },
 {
  "route": "/operation/orders/new",
  "key": "h:Material/Planned",
  "idx": 0,
  "cols": 2,
  "bodyRows": 5,
  "controlsInCells": 10,
  "headH": 37,
  "rowH": [
   47,
   47,
   47,
   47,
   47
  ],
  "rowFirstCell": [
   "Select material…MAT-2026-0001 — ",
   "Select material…MAT-2026-0001 — ",
   "Select material…MAT-2026-0001 — ",
   "Select material…MAT-2026-0001 — ",
   "Select material…MAT-2026-0001 — "
  ],
  "shellW": null,
  "shellScrollW": null,
  "overflowsShell": null,
  "desktopHeadH": 37,
  "desktopRowH": [
   47,
   47,
   47,
   47,
   47
  ]
 },
 {
  "route": "/operation/orders/new",
  "key": "h:Material/Expected/Where it came fr/Evidence",
  "idx": 1,
  "cols": 4,
  "bodyRows": 3,
  "controlsInCells": 12,
  "headH": 97,
  "rowH": [
   47,
   47,
   47
  ],
  "rowFirstCell": [
   "NoneMAT-2026-0001 — NMC Cathode ",
   "NoneMAT-2026-0001 — NMC Cathode ",
   "NoneMAT-2026-0001 — NMC Cathode "
  ],
  "shellW": null,
  "shellScrollW": null,
  "overflowsShell": null,
  "desktopHeadH": 37,
  "desktopRowH": [
   47,
   47,
   47
  ]
 },
 {
  "route": "/purchasing/payment-terms/new",
  "key": "h:#/Label/Share/Trigger/",
  "idx": 0,
  "cols": 5,
  "bodyRows": 1,
  "controlsInCells": 5,
  "headH": 41,
  "rowH": [
   63
  ],
  "rowFirstCell": [
   "1Remove"
  ],
  "shellW": null,
  "shellScrollW": null,
  "overflowsShell": null,
  "desktopHeadH": 41,
  "desktopRowH": [
   51
  ]
 },
 {
  "route": "/sales/quotes/new",
  "key": "h:Material/Quantity/Unit price",
  "idx": 0,
  "cols": 3,
  "bodyRows": 5,
  "controlsInCells": 15,
  "headH": 42.42,
  "rowH": [
   52.92,
   52.42,
   52.42,
   52.42,
   52.42
  ],
  "rowFirstCell": [
   "Select materialMAT-2026-0001 — N",
   "Select materialMAT-2026-0001 — N",
   "Select materialMAT-2026-0001 — N",
   "Select materialMAT-2026-0001 — N",
   "Select materialMAT-2026-0001 — N"
  ],
  "shellW": null,
  "shellScrollW": null,
  "overflowsShell": null,
  "desktopHeadH": 42.42,
  "desktopRowH": [
   52.92,
   52.42,
   52.42,
   52.42,
   52.42
  ]
 },
 {
  "route": "/tools/pricing/calculator",
  "key": "h:Metal/Content %",
  "idx": 0,
  "cols": 2,
  "bodyRows": 7,
  "controlsInCells": 7,
  "headH": 42.42,
  "rowH": [
   60.92,
   60.42,
   60.42,
   60.42,
   60.42,
   60.42,
   60.42
  ],
  "rowFirstCell": [
   "Nickelni",
   "Cobaltco",
   "Lithiumli",
   "Manganesemn",
   "Coppercu",
   "Aluminiumal",
   "Ironfe"
  ],
  "shellW": null,
  "shellScrollW": null,
  "overflowsShell": null,
  "desktopHeadH": 42.42,
  "desktopRowH": [
   60.92,
   60.42,
   60.42,
   60.42,
   60.42,
   60.42,
   60.42
  ]
 },
 {
  "route": "/tools/pricing/formulas/new",
  "key": "h:Metal/Payable %",
  "idx": 0,
  "cols": 2,
  "bodyRows": 7,
  "controlsInCells": 7,
  "headH": 42.42,
  "rowH": [
   60.92,
   60.42,
   60.42,
   60.42,
   60.42,
   60.42,
   60.42
  ],
  "rowFirstCell": [
   "Nickelni",
   "Cobaltco",
   "Lithiumli",
   "Manganesemn",
   "Coppercu",
   "Aluminiumal",
   "Ironfe"
  ],
  "shellW": null,
  "shellScrollW": null,
  "overflowsShell": null,
  "desktopHeadH": 42.42,
  "desktopRowH": [
   60.92,
   60.42,
   60.42,
   60.42,
   60.42,
   60.42,
   60.42
  ]
 },
 {
  "route": "/tools/pricing/metal-prices/bulk",
  "key": "h:Metal/Price (USD/t)/",
  "idx": 0,
  "cols": 3,
  "bodyRows": 7,
  "controlsInCells": 7,
  "headH": 42.42,
  "rowH": [
   128.61,
   128.11,
   128.11,
   128.11,
   128.11,
   128.11,
   128.11
  ],
  "rowFirstCell": [
   "Nickelni",
   "Cobaltco",
   "Lithiumli",
   "Manganesemn",
   "Coppercu",
   "Aluminiumal",
   "Ironfe"
  ],
  "shellW": null,
  "shellScrollW": null,
  "overflowsShell": null,
  "desktopHeadH": 42.42,
  "desktopRowH": [
   60.92,
   60.42,
   60.42,
   60.42,
   60.42,
   60.42,
   60.42
  ]
 }
]
```

### 6.2 `<EditableTable>` 编辑态

```json
[
 {
  "route": "/hr/leave/types",
  "key": "h:/Code/Name/Standard days/Certificate afte/Paid/Accrues/Half days",
  "idx": 0,
  "cols": 10,
  "controlsInCells": 12,
  "headH": 41,
  "headH_readonly": 41,
  "rowH_readonly": [
   172.03,
   177.25,
   134.41,
   171.53,
   128.69,
   191.53,
   171.53,
   134.41,
   148.69,
   85.84,
   134.41,
   114.41,
   114.41
  ],
  "rowFirstCell_readonly": [
   "›",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›"
  ],
  "rowH_editing": [
   172.03,
   229,
   177.25,
   134.41,
   171.53,
   128.69,
   191.53,
   171.53,
   134.41,
   148.69,
   85.84,
   134.41,
   114.41,
   114.41
  ],
  "rowFirstCell_editing": [
   "›",
   "NameStandard daysCertificate aft",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›",
   "›"
  ],
  "overflowsShell_readonly": false,
  "overflowsShell_editing": false,
  "shellW": 326,
  "shellScrollW_readonly": 326,
  "shellScrollW_editing": 326
 },
 {
  "route": "/hr/reviews/scale",
  "key": "h:/Code/Name/Description/Sort/Active/Usually passes p/",
  "idx": 0,
  "cols": 8,
  "controlsInCells": 14,
  "headH": 41,
  "headH_readonly": 41,
  "rowH_readonly": [
   45.5,
   61,
   45,
   45
  ],
  "rowFirstCell_readonly": [
   "›",
   "›",
   "›",
   "›"
  ],
  "rowH_editing": [
   45.5,
   255,
   61,
   45,
   45
  ],
  "rowFirstCell_editing": [
   "›",
   "NameDescriptionSortActiveUsually",
   "›",
   "›",
   "›"
  ],
  "overflowsShell_readonly": false,
  "overflowsShell_editing": false,
  "shellW": 326,
  "shellScrollW_readonly": 326,
  "shellScrollW_editing": 326
 }
]
```

### 6.3 今天的溢出

```json
{
 "documentOverflow390": [
  {
   "route": "/finance/freight/new",
   "docScrollW": 417,
   "docClientW": 390
  },
  {
   "route": "/logistics/lanes",
   "docScrollW": 402,
   "docClientW": 390
  },
  {
   "route": "/operation/processing/new",
   "docScrollW": 806,
   "docClientW": 390
  },
  {
   "route": "/purchasing/payment-terms/new",
   "docScrollW": 613,
   "docClientW": 390
  },
  {
   "route": "/sales/orders/new",
   "docScrollW": 595,
   "docClientW": 390
  },
  {
   "route": "/settings/accounts",
   "docScrollW": 425,
   "docClientW": 390
  },
  {
   "route": "/tools/pricing/metal-prices/bulk",
   "docScrollW": 407,
   "docClientW": 390
  }
 ],
 "tableShellOverflow390": [
  {
   "route": "/finance/assets",
   "idx": 0,
   "cols": 13,
   "controlsInCells": 0,
   "shellW": 326,
   "shellScrollW": 353
  },
  {
   "route": "/finance/cash-forecast",
   "idx": 0,
   "cols": 14,
   "controlsInCells": 0,
   "shellW": 326,
   "shellScrollW": 1678
  },
  {
   "route": "/finance/cash-forecast",
   "idx": 1,
   "cols": 14,
   "controlsInCells": 0,
   "shellW": 326,
   "shellScrollW": 1561
  },
  {
   "route": "/finance/close",
   "idx": 0,
   "cols": 8,
   "controlsInCells": 0,
   "shellW": 326,
   "shellScrollW": 340
  },
  {
   "route": "/finance/freight/new",
   "idx": 0,
   "cols": 4,
   "controlsInCells": 15,
   "shellW": 326,
   "shellScrollW": 327
  },
  {
   "route": "/finance/fx/bulk",
   "idx": 0,
   "cols": 4,
   "controlsInCells": 21,
   "shellW": 326,
   "shellScrollW": 497
  },
  {
   "route": "/finance/packs",
   "idx": 0,
   "cols": 10,
   "controlsInCells": 0,
   "shellW": 326,
   "shellScrollW": 339
  },
  {
   "route": "/hr/payroll/new",
   "idx": 0,
   "cols": 7,
   "controlsInCells": 35,
   "shellW": 326,
   "shellScrollW": 740
  },
  {
   "route": "/settings/reference",
   "idx": 0,
   "cols": 4,
   "controlsInCells": 0,
   "shellW": 326,
   "shellScrollW": 544
  },
  {
   "route": "/settings/reference",
   "idx": 1,
   "cols": 4,
   "controlsInCells": 0,
   "shellW": 326,
   "shellScrollW": 544
  },
  {
   "route": "/settings/reference",
   "idx": 2,
   "cols": 4,
   "controlsInCells": 0,
   "shellW": 326,
   "shellScrollW": 544
  }
 ]
}
```

---

## 7 · ★★ INPUT-3 之后的读数(2026-09-11)—— **下一刀拿这一份比,不要再拿 §6** ★★

| | |
|---|---|
| **量的那一天** | 2026-09-11T01:15:42.350Z |
| **量的那一刀** | **INPUT-3**(控件族最后一刀;`docs/handbacks/INPUT-3.md`) |
| **量具** | `scripts/survey-controls.mjs`,与 §6 那一份**逐字同一支** |
| **原样的命令** | `SURVEY_OUT=.survey-out/input3-after node scripts/survey-controls.mjs --mode=drift` 与 `--mode=edit` |
| **视口** | phone **390×844**(dsf=3, mobile=true) |
| ★ **为什么另起一节而不是改 §6** | §6 是 **INPUT-0 那一天**的快照,它是 INPUT-2 / INPUT-2b / INPUT-3 三刀共同的参照点。**改掉它等于抹掉那三刀的判据。** 本节是**新的参照点**,给【字体/排版】那一刀。 |
| ★ **这里的行高【不是标准】** | 与 §1 逐字同一条:它是一份「今天是多少」。★ 而 INPUT-3 的裁定是**行高变化报告、不停手**(`docs/variant-c-spec.md` §4.1e)—— 所以下一刀拿它比,是为了**说得出变了多少**,不是为了把它钉死。 |

### 7.1 首屏:格子里有控件的表(12 张)—— 改前 → 改后

| 路由 | # | 列 | 行 | 格子里的控件 | 表头高(前→后) | 最大行高(前→后) | 滚动壳内容宽(前→后) | 判定 |
|---|--:|--:|--:|--:|---|---|---|---|
| `/finance/freight/new` | 0 | 4 | 15 | **15** | 42.42 → 42.42 | 85.77 → **85.77** | 327 → 330 | 不变 |
| `/finance/fx/bulk` | 0 | 4 | 7 | **21** | 97 → 97 | 39 → **41** | 497 → 497 | ★ 变高 |
| `/finance/processing-costs` | 0 | 6 | 5 | **6** | 63.84 → 63.84 | 81.5 → **81.5** | 292 → 292 | 不变 |
| `/finance/processing-costs` | 1 | 6 | 4 | **5** | 63.84 → 63.84 | 81.5 → **81.5** | 292 → 292 | 不变 |
| `/hr/payroll/new` | 0 | 7 | 7 | **35** | 57 → 57 | 73 → **73** | 740 → 740 | 不变 |
| `/operation/orders/new` | 0 | 2 | 5 | **10** | 37 → 37 | 47 → **49** | (没有滚动壳) | ★ 变高 |
| `/operation/orders/new` | 1 | 4 | 3 | **12** | 97 → 97 | 47 → **49** | (没有滚动壳) | ★ 变高 |
| `/purchasing/payment-terms/new` | 0 | 5 | 1 | **5** | 41 → 41 | 63 → **77** | (没有滚动壳) | ★ 变高 |
| `/sales/quotes/new` | 0 | 3 | 5 | **15** | 42.42 → 42.42 | 52.92 → **53.5** | (没有滚动壳) | ★ 变高 |
| `/tools/pricing/calculator` | 0 | 2 | 7 | **7** | 42.42 → 42.42 | 60.92 → **53.5** | (没有滚动壳) | ★ 变矮 |
| `/tools/pricing/formulas/new` | 0 | 2 | 7 | **7** | 42.42 → 42.42 | 60.92 → **53.5** | (没有滚动壳) | ★ 变矮 |
| `/tools/pricing/metal-prices/bulk` | 0 | 3 | 7 | **7** | 42.42 → 42.42 | 128.61 → **128.61** | (没有滚动壳) | 不变 |

### 7.2 机读块(给下一刀直接 diff 用)

#### 7.2.1 首屏

```json
[
 {
  "route": "/finance/freight/new",
  "idx": 0,
  "key": "h:/Batch/Quantity/Remaining",
  "cols": 4,
  "bodyRows": 15,
  "nControls": 15,
  "headH": 42.42,
  "rowH": [
   85.77,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84
  ],
  "rowFirstCell": [
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   ""
  ],
  "shellW": 326,
  "shellScrollW": 330
 },
 {
  "route": "/finance/fx/bulk",
  "idx": 0,
  "key": "h:Rate Date/TT buy (bank buy/TT sell (bank se/Mid",
  "cols": 4,
  "bodyRows": 7,
  "nControls": 21,
  "headH": 97,
  "rowH": [
   41,
   41,
   41,
   41,
   41,
   41,
   41
  ],
  "rowFirstCell": [
   "2026-09-05",
   "2026-09-06",
   "2026-09-07",
   "2026-09-08",
   "2026-09-09",
   "2026-09-10",
   "2026-09-11"
  ],
  "shellW": 326,
  "shellScrollW": 497
 },
 {
  "route": "/finance/processing-costs",
  "idx": 0,
  "key": "h://Run/Cost type/Amount/Recorded",
  "cols": 6,
  "bodyRows": 5,
  "nControls": 6,
  "headH": 63.84,
  "rowH": [
   81.5,
   81,
   81,
   81,
   81
  ],
  "rowFirstCell": [
   "",
   "",
   "",
   "",
   ""
  ],
  "shellW": 292,
  "shellScrollW": 292
 },
 {
  "route": "/finance/processing-costs",
  "idx": 1,
  "key": "h://Run/Cost type/Amount/Recorded",
  "cols": 6,
  "bodyRows": 4,
  "nControls": 5,
  "headH": 63.84,
  "rowH": [
   81.5,
   81,
   81,
   81
  ],
  "rowFirstCell": [
   "",
   "",
   "",
   ""
  ],
  "shellW": 292,
  "shellScrollW": 292
 },
 {
  "route": "/hr/payroll/new",
  "idx": 0,
  "key": "h:Employee/Gross pay/Employee CPF/Employer CPF/Deductions/Net pay/Check",
  "cols": 7,
  "bodyRows": 7,
  "nControls": 35,
  "headH": 57,
  "rowH": [
   73,
   53,
   73,
   73,
   73,
   73,
   73
  ],
  "rowFirstCell": [
   "EMP-2026-0001Choo Er Teh",
   "EMP-2026-0002Tim",
   "EMP-2026-0003Vince Goh",
   "EMP-2026-0004Sandra Yap",
   "EMP-2026-0005Cheng Siong Phua",
   "EMP-2026-0006Fu Sheng Wong",
   "ZZ-2BL-186301ZZ 2BL"
  ],
  "shellW": 326,
  "shellScrollW": 740
 },
 {
  "route": "/operation/orders/new",
  "idx": 0,
  "key": "h:Material/Planned",
  "cols": 2,
  "bodyRows": 5,
  "nControls": 10,
  "headH": 37,
  "rowH": [
   49,
   49,
   49,
   49,
   49
  ],
  "rowFirstCell": [
   "Select material…MAT-2026-0001 — ",
   "Select material…MAT-2026-0001 — ",
   "Select material…MAT-2026-0001 — ",
   "Select material…MAT-2026-0001 — ",
   "Select material…MAT-2026-0001 — "
  ],
  "shellW": null,
  "shellScrollW": null
 },
 {
  "route": "/operation/orders/new",
  "idx": 1,
  "key": "h:Material/Expected/Where it came fr/Evidence",
  "cols": 4,
  "bodyRows": 3,
  "nControls": 12,
  "headH": 97,
  "rowH": [
   49,
   49,
   49
  ],
  "rowFirstCell": [
   "NoneMAT-2026-0001 — NMC Cathode ",
   "NoneMAT-2026-0001 — NMC Cathode ",
   "NoneMAT-2026-0001 — NMC Cathode "
  ],
  "shellW": null,
  "shellScrollW": null
 },
 {
  "route": "/purchasing/payment-terms/new",
  "idx": 0,
  "key": "h:#/Label/Share/Trigger/",
  "cols": 5,
  "bodyRows": 1,
  "nControls": 5,
  "headH": 41,
  "rowH": [
   77
  ],
  "rowFirstCell": [
   "1Remove"
  ],
  "shellW": null,
  "shellScrollW": null
 },
 {
  "route": "/sales/quotes/new",
  "idx": 0,
  "key": "h:Material/Quantity/Unit price",
  "cols": 3,
  "bodyRows": 5,
  "nControls": 15,
  "headH": 42.42,
  "rowH": [
   53.5,
   53,
   53,
   53,
   53
  ],
  "rowFirstCell": [
   "Select materialMAT-2026-0001 — N",
   "Select materialMAT-2026-0001 — N",
   "Select materialMAT-2026-0001 — N",
   "Select materialMAT-2026-0001 — N",
   "Select materialMAT-2026-0001 — N"
  ],
  "shellW": null,
  "shellScrollW": null
 },
 {
  "route": "/tools/pricing/calculator",
  "idx": 0,
  "key": "h:Metal/Content %",
  "cols": 2,
  "bodyRows": 7,
  "nControls": 7,
  "headH": 42.42,
  "rowH": [
   53.5,
   53,
   53,
   53,
   53,
   53,
   53
  ],
  "rowFirstCell": [
   "Nickelni",
   "Cobaltco",
   "Lithiumli",
   "Manganesemn",
   "Coppercu",
   "Aluminiumal",
   "Ironfe"
  ],
  "shellW": null,
  "shellScrollW": null
 },
 {
  "route": "/tools/pricing/formulas/new",
  "idx": 0,
  "key": "h:Metal/Payable %",
  "cols": 2,
  "bodyRows": 7,
  "nControls": 7,
  "headH": 42.42,
  "rowH": [
   53.5,
   53,
   53,
   53,
   53,
   53,
   53
  ],
  "rowFirstCell": [
   "Nickelni",
   "Cobaltco",
   "Lithiumli",
   "Manganesemn",
   "Coppercu",
   "Aluminiumal",
   "Ironfe"
  ],
  "shellW": null,
  "shellScrollW": null
 },
 {
  "route": "/tools/pricing/metal-prices/bulk",
  "idx": 0,
  "key": "h:Metal/Price (USD/t)/",
  "cols": 3,
  "bodyRows": 7,
  "nControls": 7,
  "headH": 42.42,
  "rowH": [
   128.61,
   128.11,
   128.11,
   128.11,
   128.11,
   128.11,
   128.11
  ],
  "rowFirstCell": [
   "Nickelni",
   "Cobaltco",
   "Lithiumli",
   "Manganesemn",
   "Coppercu",
   "Aluminiumal",
   "Ironfe"
  ],
  "shellW": null,
  "shellScrollW": null
 }
]
```

#### 7.2.2 `<EditableTable>` 编辑态

```json
[
 {
  "route": "/hr/leave/types",
  "idx": 0,
  "key": "h:/Code/Name/Standard days/Certificate afte/Paid/Accrues/Half days",
  "nControls": 12,
  "headH": 41,
  "rowH_editing": [
   172.03,
   271,
   177.25,
   134.41,
   171.53,
   128.69,
   191.53,
   171.53,
   134.41,
   148.69,
   85.84,
   134.41,
   114.41,
   114.41
  ],
  "shellScrollW_editing": 326,
  "shellW": 326
 },
 {
  "route": "/hr/reviews/scale",
  "idx": 0,
  "key": "h:/Code/Name/Description/Sort/Active/Usually passes p/",
  "nControls": 14,
  "headH": 41,
  "rowH_editing": [
   45.5,
   307,
   61,
   45,
   45
  ],
  "shellScrollW_editing": 326,
  "shellW": 326
 }
]
```

#### 7.2.3 溢出

```json
{
 "documentOverflow390": [
  {
   "route": "/finance/freight/new",
   "docScrollW": 417,
   "docClientW": 390
  },
  {
   "route": "/operation/processing/new",
   "docScrollW": 584,
   "docClientW": 390
  },
  {
   "route": "/purchasing/payment-terms/new",
   "docScrollW": 534,
   "docClientW": 390
  },
  {
   "route": "/sales/orders/new",
   "docScrollW": 396,
   "docClientW": 390
  },
  {
   "route": "/settings/accounts",
   "docScrollW": 425,
   "docClientW": 390
  },
  {
   "route": "/tools/pricing/metal-prices/bulk",
   "docScrollW": 407,
   "docClientW": 390
  }
 ],
 "tableShellOverflow390": [
  {
   "route": "/finance/assets",
   "idx": 0,
   "cols": 13,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 353
  },
  {
   "route": "/finance/cash-forecast",
   "idx": 0,
   "cols": 14,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 1678
  },
  {
   "route": "/finance/cash-forecast",
   "idx": 1,
   "cols": 14,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 1561
  },
  {
   "route": "/finance/close",
   "idx": 0,
   "cols": 8,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 340
  },
  {
   "route": "/finance/freight/new",
   "idx": 0,
   "cols": 4,
   "nControls": 15,
   "shellW": 326,
   "shellScrollW": 330
  },
  {
   "route": "/finance/fx/bulk",
   "idx": 0,
   "cols": 4,
   "nControls": 21,
   "shellW": 326,
   "shellScrollW": 497
  },
  {
   "route": "/finance/packs",
   "idx": 0,
   "cols": 10,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 339
  },
  {
   "route": "/hr/payroll/new",
   "idx": 0,
   "cols": 7,
   "nControls": 35,
   "shellW": 326,
   "shellScrollW": 740
  },
  {
   "route": "/inbound",
   "idx": 0,
   "cols": 14,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 327
  },
  {
   "route": "/settings/reference",
   "idx": 0,
   "cols": 4,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 544
  },
  {
   "route": "/settings/reference",
   "idx": 1,
   "cols": 4,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 544
  },
  {
   "route": "/settings/reference",
   "idx": 2,
   "cols": 4,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 544
  }
 ]
}
```

> ⚠ **§5 的三条用法注记逐条仍然成立** —— 行高吃活数据 · 表的身份是三元组 · 编辑态会插额外的 `<tr>`。
> ★ 再加一条,是这一刀自己撞出来的:**`scripts/check-row-height-baseline.mjs` 现在有 `--row-height=stop|report`**。
> 拿本节比的时候,**横向差别任何档位下都退 1**;竖向差别要不要算数,由那个开关决定。

---

---

## 8 · ★★ FONT-1 之后的读数(2026-09-11)—— **下一刀拿这一份比,不要再拿 §7** ★★

| | |
|---|---|
| **量的那一天** | 2026-09-11(UTC 09:55:26 → 10:22:56 那一趟 `--mode=drift`) |
| **量的那一刀** | **FONT-1**(字体 / 字号表 / `<label>` / 链接色 / 数字等宽 / 控件字重;`docs/handbacks/FONT-1.md`) |
| ★ **这是 round 3 的【最终】读数** | ⚠ round 2 也写过这一节,而那一份量的是**一棵还没修完的树**(T3 的两处文件输入、T4 的控件字重、T5 的链接色**都还没落地**)。<br>★ **这一份逐字覆盖了它** —— §8 **从来没有被提交过**,它是这一刀的草稿,不是在案的历史快照。<br>★ **§6(INPUT-0)与 §7(INPUT-3)一个字节都没动。** |
| **量具** | `scripts/survey-controls.mjs`,与 §6 / §7 **逐字同一支**;★ **逐列宽度**由 FONT-1 自己那支探针补(仓库里的量具没有这个字段) |
| **原样的命令** | `SURVEY_OUT=.survey-out/font1-after-r3 node scripts/survey-controls.mjs --mode=drift` 与 `--mode=edit` |
| **视口** | phone **390×844**(dsf=3, mobile=true) |
| ★ **覆盖** | phone **141 条**路由全部 `ready=ok`(**not-ok 0 条**);带控件的表 **12 张**;编辑态 **2 张** |
| ★ **为什么另起一节而不是改 §7** | 与 §7 的理由逐字同一条:§7 是 **INPUT-3 那一天**的快照,是 FONT-1 的参照点。**改掉它等于抹掉本刀的判据。** |
| ★ **这里的行高【不是标准】** | 与 §1 / §7 逐字同一条:它是一份「今天是多少」。★ 本刀的裁定同样是**行高变化报告、不停手**(`docs/variant-c-spec.md` §4.1e / §4.7.7)。 |

### 8.1 首屏:格子里有控件的表(12 张)—— INPUT-3 之后 → FONT-1 之后

| 路由 | # | 列 | 行 | 格子里的控件 | 表头高 | 最大行高 | 滚动壳内容宽 |
|---|--:|--:|--:|--:|--:|--:|--:|
| `/finance/freight/new` | 0 | 4 | 15 | **15** | 42.42 | 85.77 | 336 |
| `/finance/fx/bulk` | 0 | 4 | 7 | **21** | 97 | 41 | 497 |
| `/finance/processing-costs` | 0 | 6 | 5 | **6** | 63.84 | 81.5 | 292 |
| `/finance/processing-costs` | 1 | 6 | 4 | **5** | 63.84 | 81.5 | 292 |
| `/hr/payroll/new` | 0 | 7 | 7 | **35** | 57 | 73 | 739 |
| `/operation/orders/new` | 0 | 2 | 5 | **10** | 37 | 49 | (没有滚动壳) |
| `/operation/orders/new` | 1 | 4 | 3 | **12** | 97 | 49 | (没有滚动壳) |
| `/purchasing/payment-terms/new` | 0 | 5 | 1 | **5** | 41 | 77 | (没有滚动壳) |
| `/sales/quotes/new` | 0 | 3 | 5 | **15** | 42.42 | 53.5 | (没有滚动壳) |
| `/tools/pricing/calculator` | 0 | 2 | 7 | **7** | 42.42 | 53.5 | (没有滚动壳) |
| `/tools/pricing/formulas/new` | 0 | 2 | 7 | **7** | 42.42 | 53.5 | (没有滚动壳) |
| `/tools/pricing/metal-prices/bulk` | 0 | 3 | 7 | **7** | 42.42 | 128.61 | (没有滚动壳) |

### 8.2 ★ 逐列宽度(colW)—— 本族第一次有这个读数

> **仓库里的量具读不到列宽**(`survey-controls.mjs` 没有这个字段);这一份由 FONT-1
> 自己那支探针读(表头行每一格的 `getBoundingClientRect().width`,390px)。
> ☞ 「给 `survey-controls.mjs` 加一个 colW 读数」已登记成队列里的一条 —— **加字段会让**
> **`--mode=compare` 的成员签名变化,与历史读数不可比**,所以它值得单独裁一次。

| 路由 | # | 每一列的宽度(390px,FONT-1 之后) |
|---|--:|---|
| `/finance/freight/new` | 0 | 40 · 114 · 84.98 · 96.8 |
| `/finance/fx/bulk` | 0 | 109 · 129 · 129 · 129 |
| `/finance/processing-costs` | 0 | 32 · 32 · 76 · 76 · 76 · 0 |
| `/finance/processing-costs` | 1 | 32 · 32 · 76 · 76 · 76 · 0 |
| `/hr/payroll/new` | 0 | 105.64 · 113 · 113 · 113 · 113 · 113 · 67.75 |
| `/operation/orders/new` | 0 | 180 · 145 |
| `/operation/orders/new` | 1 | 71.8 · 145 · 61.11 · 77.7 |
| `/purchasing/payment-terms/new` | 0 | 78.36 · 66.22 · 121 · 240 · 0 |
| `/sales/quotes/new` | 0 | 80.33 · 136 · 136 |
| `/tools/pricing/calculator` | 0 | 156.05 · 169.95 |
| `/tools/pricing/formulas/new` | 0 | 156.05 · 169.95 |
| `/tools/pricing/metal-prices/bulk` | 0 | 124.89 · 184 · 70.58 |

### 8.3 机读块(给下一刀直接 diff 用)

#### 8.3.1 首屏

```json
[
 {
  "route": "/finance/freight/new",
  "idx": 0,
  "key": "h:/Batch/Quantity/Remaining",
  "cols": 4,
  "bodyRows": 15,
  "nControls": 15,
  "headH": 42.42,
  "rowH": [
   85.77,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84,
   63.84
  ],
  "rowFirstCell": [
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   "",
   ""
  ],
  "shellW": 326,
  "shellScrollW": 336
 },
 {
  "route": "/finance/fx/bulk",
  "idx": 0,
  "key": "h:Rate Date/TT buy (bank buy/TT sell (bank se/Mid",
  "cols": 4,
  "bodyRows": 7,
  "nControls": 21,
  "headH": 97,
  "rowH": [
   41,
   41,
   41,
   41,
   41,
   41,
   41
  ],
  "rowFirstCell": [
   "2026-09-05",
   "2026-09-06",
   "2026-09-07",
   "2026-09-08",
   "2026-09-09",
   "2026-09-10",
   "2026-09-11"
  ],
  "shellW": 326,
  "shellScrollW": 497
 },
 {
  "route": "/finance/processing-costs",
  "idx": 0,
  "key": "h://Run/Cost type/Amount/Recorded",
  "cols": 6,
  "bodyRows": 5,
  "nControls": 6,
  "headH": 63.84,
  "rowH": [
   81.5,
   81,
   81,
   81,
   81
  ],
  "rowFirstCell": [
   "",
   "",
   "",
   "",
   ""
  ],
  "shellW": 292,
  "shellScrollW": 292
 },
 {
  "route": "/finance/processing-costs",
  "idx": 1,
  "key": "h://Run/Cost type/Amount/Recorded",
  "cols": 6,
  "bodyRows": 4,
  "nControls": 5,
  "headH": 63.84,
  "rowH": [
   81.5,
   81,
   81,
   81
  ],
  "rowFirstCell": [
   "",
   "",
   "",
   ""
  ],
  "shellW": 292,
  "shellScrollW": 292
 },
 {
  "route": "/hr/payroll/new",
  "idx": 0,
  "key": "h:Employee/Gross pay/Employee CPF/Employer CPF/Deductions/Net pay/Check",
  "cols": 7,
  "bodyRows": 7,
  "nControls": 35,
  "headH": 57,
  "rowH": [
   73,
   53,
   73,
   73,
   73,
   73,
   73
  ],
  "rowFirstCell": [
   "EMP-2026-0001Choo Er Teh",
   "EMP-2026-0002Tim",
   "EMP-2026-0003Vince Goh",
   "EMP-2026-0004Sandra Yap",
   "EMP-2026-0005Cheng Siong Phua",
   "EMP-2026-0006Fu Sheng Wong",
   "ZZ-2BL-186301ZZ 2BL"
  ],
  "shellW": 326,
  "shellScrollW": 739
 },
 {
  "route": "/operation/orders/new",
  "idx": 0,
  "key": "h:Material/Planned",
  "cols": 2,
  "bodyRows": 5,
  "nControls": 10,
  "headH": 37,
  "rowH": [
   49,
   49,
   49,
   49,
   49
  ],
  "rowFirstCell": [
   "Select material…MAT-2026-0001 — ",
   "Select material…MAT-2026-0001 — ",
   "Select material…MAT-2026-0001 — ",
   "Select material…MAT-2026-0001 — ",
   "Select material…MAT-2026-0001 — "
  ],
  "shellW": null,
  "shellScrollW": null
 },
 {
  "route": "/operation/orders/new",
  "idx": 1,
  "key": "h:Material/Expected/Where it came fr/Evidence",
  "cols": 4,
  "bodyRows": 3,
  "nControls": 12,
  "headH": 97,
  "rowH": [
   49,
   49,
   49
  ],
  "rowFirstCell": [
   "NoneMAT-2026-0001 — NMC Cathode ",
   "NoneMAT-2026-0001 — NMC Cathode ",
   "NoneMAT-2026-0001 — NMC Cathode "
  ],
  "shellW": null,
  "shellScrollW": null
 },
 {
  "route": "/purchasing/payment-terms/new",
  "idx": 0,
  "key": "h:#/Label/Share/Trigger/",
  "cols": 5,
  "bodyRows": 1,
  "nControls": 5,
  "headH": 41,
  "rowH": [
   77
  ],
  "rowFirstCell": [
   "1Remove"
  ],
  "shellW": null,
  "shellScrollW": null
 },
 {
  "route": "/sales/quotes/new",
  "idx": 0,
  "key": "h:Material/Quantity/Unit price",
  "cols": 3,
  "bodyRows": 5,
  "nControls": 15,
  "headH": 42.42,
  "rowH": [
   53.5,
   53,
   53,
   53,
   53
  ],
  "rowFirstCell": [
   "Select materialMAT-2026-0001 — N",
   "Select materialMAT-2026-0001 — N",
   "Select materialMAT-2026-0001 — N",
   "Select materialMAT-2026-0001 — N",
   "Select materialMAT-2026-0001 — N"
  ],
  "shellW": null,
  "shellScrollW": null
 },
 {
  "route": "/tools/pricing/calculator",
  "idx": 0,
  "key": "h:Metal/Content %",
  "cols": 2,
  "bodyRows": 7,
  "nControls": 7,
  "headH": 42.42,
  "rowH": [
   53.5,
   53,
   53,
   53,
   53,
   53,
   53
  ],
  "rowFirstCell": [
   "Nickelni",
   "Cobaltco",
   "Lithiumli",
   "Manganesemn",
   "Coppercu",
   "Aluminiumal",
   "Ironfe"
  ],
  "shellW": null,
  "shellScrollW": null
 },
 {
  "route": "/tools/pricing/formulas/new",
  "idx": 0,
  "key": "h:Metal/Payable %",
  "cols": 2,
  "bodyRows": 7,
  "nControls": 7,
  "headH": 42.42,
  "rowH": [
   53.5,
   53,
   53,
   53,
   53,
   53,
   53
  ],
  "rowFirstCell": [
   "Nickelni",
   "Cobaltco",
   "Lithiumli",
   "Manganesemn",
   "Coppercu",
   "Aluminiumal",
   "Ironfe"
  ],
  "shellW": null,
  "shellScrollW": null
 },
 {
  "route": "/tools/pricing/metal-prices/bulk",
  "idx": 0,
  "key": "h:Metal/Price (USD/t)/",
  "cols": 3,
  "bodyRows": 7,
  "nControls": 7,
  "headH": 42.42,
  "rowH": [
   128.61,
   128.11,
   128.11,
   128.11,
   128.11,
   128.11,
   128.11
  ],
  "rowFirstCell": [
   "Nickelni",
   "Cobaltco",
   "Lithiumli",
   "Manganesemn",
   "Coppercu",
   "Aluminiumal",
   "Ironfe"
  ],
  "shellW": null,
  "shellScrollW": null
 }
]
```

#### 8.3.2 `<EditableTable>` 编辑态

```json
[
 {
  "route": "/hr/leave/types",
  "idx": 0,
  "key": "h:/Code/Name/Standard days/Certificate afte/Paid/Accrues/Half days",
  "nControls": 12,
  "headH": 41,
  "rowH_editing": [
   172.03,
   271,
   177.25,
   134.41,
   171.53,
   128.69,
   191.53,
   171.53,
   134.41,
   162.97,
   85.84,
   134.41,
   114.41,
   114.41
  ],
  "shellScrollW_editing": 326,
  "shellW": 326
 },
 {
  "route": "/hr/reviews/scale",
  "idx": 0,
  "key": "h:/Code/Name/Description/Sort/Active/Usually passes p/",
  "nControls": 14,
  "headH": 41,
  "rowH_editing": [
   45.5,
   307,
   61,
   61,
   45
  ],
  "shellScrollW_editing": 326,
  "shellW": 326
 }
]
```

#### 8.3.3 今天的溢出(390px)

```json
{
 "documentOverflow390": [
  {
   "route": "/finance/freight/new",
   "docScrollW": 417,
   "docClientW": 390
  },
  {
   "route": "/operation/processing/new",
   "docScrollW": 567,
   "docClientW": 390
  },
  {
   "route": "/purchasing/payment-terms/new",
   "docScrollW": 539,
   "docClientW": 390
  },
  {
   "route": "/sales/orders/new",
   "docScrollW": 398,
   "docClientW": 390
  },
  {
   "route": "/tools/pricing/metal-prices/bulk",
   "docScrollW": 411,
   "docClientW": 390
  }
 ],
 "tableShellOverflow390": [
  {
   "route": "/finance/assets",
   "idx": 0,
   "cols": 13,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 353
  },
  {
   "route": "/finance/cash-forecast",
   "idx": 0,
   "cols": 14,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 1680
  },
  {
   "route": "/finance/cash-forecast",
   "idx": 1,
   "cols": 14,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 1563
  },
  {
   "route": "/finance/close",
   "idx": 0,
   "cols": 8,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 339
  },
  {
   "route": "/finance/freight/new",
   "idx": 0,
   "cols": 4,
   "nControls": 15,
   "shellW": 326,
   "shellScrollW": 336
  },
  {
   "route": "/finance/fx/bulk",
   "idx": 0,
   "cols": 4,
   "nControls": 21,
   "shellW": 326,
   "shellScrollW": 497
  },
  {
   "route": "/finance/packs",
   "idx": 0,
   "cols": 10,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 339
  },
  {
   "route": "/hr/payroll/new",
   "idx": 0,
   "cols": 7,
   "nControls": 35,
   "shellW": 326,
   "shellScrollW": 739
  },
  {
   "route": "/inbound",
   "idx": 0,
   "cols": 14,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 328
  },
  {
   "route": "/settings/reference",
   "idx": 0,
   "cols": 4,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 544
  },
  {
   "route": "/settings/reference",
   "idx": 1,
   "cols": 4,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 544
  },
  {
   "route": "/settings/reference",
   "idx": 2,
   "cols": 4,
   "nControls": 0,
   "shellW": 326,
   "shellScrollW": 544
  }
 ]
}
```
