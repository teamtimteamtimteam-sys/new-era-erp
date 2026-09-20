# BTN-FOLLOWUP —— 交回报告(2026-09-20)

**一句话:** BTN-TRIGGER-1 停住的两件事,Tim 都裁了,两件都落地了 ——
`<EditableTable>` 手机档那颗钮取 `touch`(48px),三颗量了按回来的控件转回去。
**四颗控件,16 个对比度读数改后全绿;停止条件 (c) 按授权在【恰好三张表】上踩,
其余 201 张逐字未变。**

| | |
|---|---|
| **改了几个文件** | 4 个,46 行加 / 23 行减 |
| **迁移** | ★ **0 条**(`git diff --stat -- db/` 收工时 0 行,量过的) |
| **封存输出(d)** | ★ **5 个一字未动**(`git diff` 对那五个路径为空) |
| **(a)(b)(c) 横滚那一半** | `STOPRULE_ABC_OWN_EXIT=0` —— 282 组 · 184 张表 · 650 次字段比较 |
| **(c) 行高那一半** | ★ `ROWHEIGHT_OWN_EXIT=1` —— **按授权红的**,204 张表里恰好 3 张,见 §3 |
| **A1 那四条路由** | 单独量的(在册量具看不见那一格),见 §2 |

---

## 1 · 开工闸(§1.1)与 §1.2 的重量

**三个 SHA 逐字相同,等于 Tim 确认过的那一个:**

```
git status --porcelain   (空)
HEAD                     642ce03259b0330d482a841c64342bd48780bb04
origin/main              642ce03259b0330d482a841c64342bd48780bb04
git ls-remote origin main 642ce03259b0330d482a841c64342bd48780bb04
```

### 1.1 ★ 委托书里每一个数,开工前当场重量 —— 包括量下来是对的那些

| 委托书说的 | 实测 | 判词 |
|---|---|---|
| (b) 的 5 条:freight 27 · processing 177 · payment-terms 143 · orders 8 · bulk 24 | **27 · 177 · 143 · 8 · 24** | ✓ **五个数逐字相同** |
| (f) 顶栏:`1280x53` · `390x55` · nav field `200x32` · home `358x49.02` @390 与 `544x53.63` @1280 | 逐字相同(`probe-nav-geometry` 自己的断言行 N1–N4 · N10) | ✓ **五个读数逐字相同** |
| (e) `/brand-sampler` phone 成员数 ±1 不稳,BTN-TRIGGER-1 记的是 860·860·859·860 | **本刀三跑:860 · 860 · 860** | ✓ **众数 860**,见 §5 |
| A2 的三处行高差:+1.00 · +1.00 · +0.58 | **+1.00 · +1.00 · +0.58**(§3) | ✓ **三个数逐字相同** |
| A1「三条路都改行高,`touch` 是 +4.0」 | **真实路由上 +4.00 / +4.00**(§2) | ✓ 与复刻格里量到的 +4.0 对上 |

### 1.2 ★★ 量下来是【假】的那一条 —— A1 的「4 条路由」是 3 条,而其中 1 条按构造没有这颗钮

委托书与 `known-issues.md` 都写着那颗钮「**渲染在 4 条路由上**:
`/me` · `/hr/kpi/score` · `/hr/leave/types` · `/hr/reviews/scale`」。

★ **实测:`/me` 上那颗钮【按构造不存在】。**

`editable-table.tsx:321` 写着 `const showActions = canEdit && mode === 'one-row' && !!onSave`,
而 `/me` 的 `MySelfAssessmentPanel.tsx` 传的是 **`mode="all-rows"`**(:192),
并且**根本不传 `onSave`** —— 它用 `footer` 自己画提交区,理由就写在那几行注释里
(「提交同时要表外那段正文与两个不同的按钮,所以它不能是组件的 `onSave`」)。
☞ `showActions === false` ⇒ **`{showActions && !editing && …}` 那一支永远不渲染。**

| 路由 | 结构上有这颗钮吗 | 本刀在 390px 上量到 |
|---|---|---|
| `/me` | ★ **没有**(`mode="all-rows"` + 无 `onSave`) | 0 行(探针账号看不到任何目标) |
| `/hr/kpi/score` | **有**(`ScoreEditor` 有 `onSave`、默认 `one-row`) | 0 行(探针账号在这一页上没有数据) |
| `/hr/leave/types` | **有** | ★ **13 行,量到了** |
| `/hr/reviews/scale` | **有** | ★ **4 行,量到了** |

☞ **所以射程是 3 条,不是 4 条;而本刀在真实路由上量到的是其中 2 条。**
**第三条(`/hr/kpi/score`)本刀没有量到,照直说** —— 一次性 admin 在那一页上
一行都看不到,而造数据会写进线上,不在本刀范围。
★ **它的几何由 §2.2 的复刻格覆盖**(同一份编译出来的 CSS,同一段 class 串),
而那不是一次真实路由上的测量,两者在本报告里分开记。

---

## 2 · A1 —— `<EditableTable>` 手机档那颗钮走 `touch`

### 2.1 ★★★ 量具:第七支一次性探针,而这一支是【点开才量得到】那一格唯一的读数

BTN-TRIGGER-1 §6.2 把这件事说准过,本刀照它做:

* 那颗钮住在 `{isOpen && hasPhonePanel && (…)}` 里 —— **点开才渲染**;
* `survey-controls --mode=drift` 自己的 AIM §② 写着「**我量的是首屏**。
  对话框、下拉展开、Tab 面板、折叠行从不打开」。

☞ **一个绿的 (c) 不覆盖这一格,而那不是"覆盖面不够",是按构造读不到。**

**`phone-expand.mjs` 做什么:** 390px、一次性 admin、真的 `next dev`;
逐条路由找 `tbody tr td button[aria-expanded="false"]`,**点第一颗**
(它的 `onClick` 是 `toggleRow`,**纯本地 state,不发一个请求** ——
收窄候选的理由与 `survey-controls` §EDIT 那一条逐字相同),
然后量面板 `<tr>` 的高度、整组(base + panel)的高度、面板里**每一颗**按钮的盒子,
以及展开前后 390px 的整页横向溢出。

**覆盖断言(一支挑不到候选的普查必须说「我瞎了」):**
一条路由都没展开成功 → **EXIT 2**;逐条路由记 `rowsFound` / `clicked` /
`expandedGroups` / `editButtons`,**零是一次测量,不是一次沉默**;
登录断言逐字照搬 `survey-controls`(渲染出 `/login` 就当场抛,
`known-issues` · FONT3-PROBE-LOGIN-FALSE-ZERO)。

⚠ **它【不】量什么,照直说:** 它不判对错,只把读数写出来;
一条路由上读到 0 行,准确含义是「**这个探针账号在这一页上看不到任何一行**」,
不是「这一格不存在」。

### 2.2 ★ 实测,改前改后(`PHONEEXPAND_BEFORE_OWN_EXIT=0` · `PHONEEXPAND_AFTER_OWN_EXIT=0`)

| 路由 | 行数 | **面板 `<tr>` 高** | **整组高**(base+panel) | **钮高** | **字号** | 390px 整页溢出 |
|---|--:|--:|--:|--:|--:|--:|
| `/hr/leave/types` | 13 | **223 → 227(★ +4.00)** | 459.92 → 463.92(+4.00) | 44 → **48** | 14px → **16px** | **0 → 0** |
| `/hr/reviews/scale` | 4 | **231 → 235(★ +4.00)** | 276.5 → 280.5(+4.00) | 44 → **48** | 14px → **16px** | **0 → 0** |
| `/hr/kpi/score` | 0 | — 没有量到(见 §1.2) | | | | |
| `/me` | 0 | — **按构造没有这颗钮**(见 §1.2) | | | | |

**改后那颗钮自己:** `data-variant="secondary"` · `data-size="touch"` ·
高 48 · 宽 49.16 · 字号 16px · 圆角 8px · `min-height: 0px`(★ 高度从此由 `h-12` 给,
不再由 `min-h-11` 给)· 内边距 `0px / 10px` · 底 `transparent`。

★★ **+4.00 与 `known-issues` 里那张表记的「行 92.5 → 96.5(+4.0)」对上了** ——
那一份是在**复刻的手机展开格**里量的,这一份是在**两条真实路由**上量的。
**两份独立的读数给出同一个差值**,这比本刀自己报一个新数值钱。

### 2.3 ★ 代价照直记 —— 它是被告知之后接受的,不是被忽略的

* **钮高 44 → 48px(+4)**,**字号 14 → 16px**。
  字号不是本刀顺手加的:`button.tsx` 抬头写明「E6 的裁定原话把三样绑在一起……
  把字号留在调用点,等于让这一档只搬了裁定的一半」。
* **Tim 的理由**(委托书 A1 逐字):32px 与 36px **都会把它掉到 44px 触控靶以下**
  (WCAG 2.5.5 / Apple HIG),**宁可让它长高,也不要让它掉到一条标准以下**。
* ★ **顺带买到的一件事,而它此前没有被登记过:** 这颗钮**启用态**的字色今天是
  `text-blue-600`(`#155DFC`),坐在手机展开区的 `--brand-muted`(`#E5EEF4`)上 ——
  ★ **实测 4.463:1,过不了 AA(4.5)。** 转成 `secondary` 之后是 **15.254:1**。
  ☞ 也就是说这一颗**不只是禁用态不合格,它启用着就不合格**,
  而 BTN-TRIGGER-1 只量了禁用态,没有量到这一格。见 §4。

### 2.4 ★ 它没有弄瞎 `--mode=edit`(顺带查实,免得下一刀踩空)

`survey-controls` 的编辑钮判据 **FONT-1 已经从「className 含 `text-blue-600`」
换成「文字等于 `labels.edit`」**(`scripts/survey-controls.mjs:450` 起)。
本刀改掉的正是 `text-blue-600`,而判据不认它了 ⇒ **不受影响**。
⚠ **但那个文件抬头 §EDIT 的散文(第 70–74 行)【仍然写着旧判据】** ——
`BTNTRIGGER1-SURVEY-EDIT-PROSE-STALE` 今天仍然成立。**本刀不动量具,登记照旧。**

---

## 3 · A2 —— 三颗控件转回去,而 (c) 【按授权】踩在恰好三张表上

### 3.1 量具:BTN-TRIGGER-1 §7.1 那支行高比对器,先做两格注入再用

`check-stop-rules-abc.mjs` 自己的 AIM 写着它读 `docShow/docClientW` 与每张表的
`overflowsShell / shellScrollW / shellW / tableW` —— ★ **那是 (c) 的【横滚】那一半。**
(c) 的另一半是「**或者 ANY row height changes**」,**那一半它不读。**

**两格注入(用之前先证它会咬人):**

| 注入 | 期望 | 实测 |
|---|---|---|
| 同一份读数自比 | 干净 | ★ `ROWH_INJECT1_OWN_EXIT=0` —— **204 张表 · 0 处差异 · 0 个瞎掉的路由格** |
| 把一张表的 `rowH[0]` 加 7 | 当场红并点名 | ★ `ROWH_INJECT2_OWN_EXIT=1` —— 点名 `/finance/assets`、表签名、字段,并带着判别式「**rowFirstCell 没变 ⇒ 这是真的几何变化,不是数据换了一行**」 |

### 3.2 ★★★ 读数:`ROWHEIGHT_OWN_EXIT=1`,而这个 1 是【授权过的】

```
TABLES_COMPARED=204  FIELD_CHANGES=4  BLIND_ROUTE_CELLS=0
TABLES_ONLY_BEFORE=0  TABLES_ONLY_AFTER=0
```

| 路由 | 视口 | 表 | 字段 | 改前 → 改后 | 判词 |
|---|---|---|---|---|---|
| `/sales/customers` | desktop | `Code↕/Legal Name↕/…/Status` | `rowH`(3 行) | **42.92 / 42.42 / 42.42 → 43.92 / 43.42 / 43.42** | ★ **+1.00 逐行 —— 授权** |
| `/suppliers` | desktop | `Code↕/…/Created▼/Actions` | `rowH`(8 行) | **42.92 + 7×42.42 → 43.92 + 7×43.42** | ★ **+1.00,八行全中 —— 授权** |
| `/finance/close` | desktop | `Period end/…/Status` | `rowH` | **52.92 → 53.50** | ★ **+0.58 —— 授权** |
| `/finance/close` | phone | 同上 | `shellScrollW` | **343 → 336** | ★ **滚动范围【变小】,不是长大 —— (c) 判的是"长大"** |

### 3.3 ★★★ 断言:**除了这三张表,其余的一张都没有动**

**204 张表比过,4 处字段差,全部落在上面那三张表上 ⇒ 其余 201 张表的
`headH` / `rowH` / `nBodyRows` / `tableW` / `shellW` / `shellScrollW` / `overflowsShell`
【逐字未变】。**
★ 而 `BLIND_ROUTE_CELLS=0` 是这句话能成立的前提:**没有任何一个路由格是"没量到"** ——
否则「没有差异」会与「没有读数」在输出上长得一模一样。

★ **三个差值与 BTN-TRIGGER-1 §7.1 记的逐字相同**(52.92→53.50 · 42.92/42.42→43.92/43.42 · 343→336)。
**两刀、两次独立的运行、同一组数。**

### 3.4 ★ Tim 的理由,记在代码旁边而不只是记在这里

委托书 A2 逐字:**1px 在屏幕上看不见,而它买到的是三颗
「禁用之后不再读成【这里什么都没有】」的控件。** 三处的注释各自写下了这一条,
连同它换回来的那两个对比度读数 —— **一条带着理由的改动活得下来,一条不带理由的会被顺手整理掉。**

---

## 4 · A3 —— 四颗控件的对比度,按 §5 的样子逐个报

**量法与 BTN-TRIGGER-1 §5 同一套,一件都没有简化:**
`postcss` + `@tailwindcss/postcss` 编 `app/globals.css`(`optimize:false`,
**97,372 字节**,本刀自己编的);`<Button>` 的 class 串**不是抄的** ——
把 `button.tsx` 里那一整个 `cva(...)` **原样切出来**,用 `node_modules` 里真的
`class-variance-authority` + `tailwind-merge` 求值,并钉住基础串里必须还有
`border border-transparent` / `inline-flex` / `h-8`,少一个**当场抛**。
★ **改前那四串逐字从 `git show HEAD:<file>` 读出来**,不是敲进来的 ——
它们已经被这一刀换掉了,而工作区里找不到时最省事的处置(敲一遍)
等于在量具里再放一份会漂的定义。
★ **对比度是量的,不是算的**:把从元素到 `<html>` 的每一层 `opacity` 连乘,
再按组透明度把**字与底各合成一次**;颜色**让引擎栅格化一个像素再读回字节**
(Tailwind v4 发 `oklch()`,正则读成 null 当场崩 —— BTN-1 §10.5 那一课)。

### 4.1 逐个站点 × 两种态 × 两种底 = 16 个读数

| 控件 | 态 | 底 | 改前 | ★ 改后 | 判词 |
|---|---|---|--:|--:|---|
| `customers · Delete` | 启用 | 白 | 4.770 | **5.356** | ✓ → ✓ |
| | 启用 | `--brand-bg` | **4.480 ✗** | **5.030** | ✗ → ✓ |
| | 禁用 | 白 | **2.602 ✗** | ★ **14.132** | ✗ → ✓ |
| | 禁用 | `--brand-bg` | **2.443 ✗** | ★ **13.272** | ✗ → ✓ |
| `suppliers · Delete` | 启用 | 白 | 4.770 | **5.356** | ✓ → ✓ |
| | 启用 | `--brand-bg` | **4.480 ✗** | **5.030** | ✗ → ✓ |
| | 禁用 | 白 | **2.602 ✗** | ★ **14.132** | ✗ → ✓ |
| | 禁用 | `--brand-bg` | **2.443 ✗** | ★ **13.272** | ✗ → ✓ |
| `finance/close · Reopen` | 启用 | 白 | 4.770 | **17.928** | ✓ → ✓ |
| | 启用 | `--brand-bg` | **4.480 ✗** | **16.836** | ✗ → ✓ |
| | 禁用 | 白 | **2.557 ✗** | ★ **11.273** | ✗ → ✓ |
| | 禁用 | `--brand-bg` | **2.525 ✗** | ★ **11.273** | ✗ → ✓ |
| ★ `EditableTable · phone Edit` | 启用 | (手机展开区 `--brand-muted`) | ★ **4.463 ✗** | **15.254** | ✗ → ✓ |
| | 禁用 | 同上 | ★ **4.463 ✗** | ★ **11.273** | ✗ → ✓ |

> ★ **最后那一颗为什么两种底读数相同:** 它坐在手机展开区自己的底
> (`bg-[color:var(--brand-muted)]` = `#E5EEF4`)上 —— **外面那层底透不过来**,
> 所以"白底 / `--brand-bg`"这个区别在这一格里不成立。**照直报,不假装有两个数。**
> ⚠ 而它**今天在调用点上没有 `disabled` 属性**,所以那一行禁用态读的是
> **这一档在禁用时会是什么样**,不是一个今天到得了的状态。

**总账:16 个读数 · 改前 13 红 / 3 绿 · ★ 改后 16 全绿。**

★★ **11.273 与 BTN-1 记的 11.27、BTN-SIZE-1 与 BTN-TRIGGER-1 记的 11.273 逐字吻合;
14.132 / 13.272 与 BTN-TRIGGER-1 为行内档记的逐字吻合。**
☞ **四份独立的读数对上了同一组数。**

### 4.2 几何(同一跑读出来的,两个视口逐字相同)

| 控件 | 高 | 字号 | 字色 | 底 |
|---|---|---|---|---|
| `customers · Delete` | 20 → **22** | 14px → 14px | `#E7000B` → **`#AA4F48`** | 白 → 白 |
| `suppliers · Delete` | 20 → **22** | 14px → 14px | `#E7000B` → **`#AA4F48`** | 白 → 白 |
| `finance/close · Reopen` | 30 → **32** | 14px → 14px | `#E7000B` → **`#171717`** | 白 → 白 |
| `EditableTable · phone Edit` | 44 → **48** | ★ 14px → **16px** | `#155DFC` → **`#171717`** | `#E5EEF4` → `#E5EEF4` |

### 4.3 `SafetyStatePanel` 那一颗:**不动,而理由没有被重新打开**

`app/output/[id]/edit/SafetyStatePanel.tsx:89` 是**一个切换控件的一半**
(`on ? <ConfirmButton> : <button>`,两支共用同一个 `cls`)。
只转 `on` 那一支,会让**同一个控件的两个状态长得不一样** —— 而 Tim 在 POLISH-1 R2
给的理由逐字是「**功能相同的按钮必须长得一样**」。
☞ **Tim 没有重新打开它,本刀不动它。** 它那处 `disabled:opacity-50` 照旧活着,
登记在 `known-issues.md` 的 BTN-TRIGGER-1 ② 名下,去处不变(与 §16.4 A 那个真选择控件同一刀)。

---

## 5 · 停止条件,逐条

### 5.1 (a)(b)(c) 的横滚那一半 —— `STOPRULE_ABC_OWN_EXIT=0`

```
视口 2 个(desktop / phone)
路由×视口 282 组比过 · 表 184 张比过 · 字段比较 650 次
改前就在溢出的:5 组
✓ (a)(b)(c) 一条都没踩。
```

### 5.2 ★ (b) —— **5 of 5,而 `/finance/freight/new` 这一刀【没有】卡死**

委托书写着它「在 `next dev` 下四次连着卡死」。★ **本刀两侧都没有卡在它身上:**

| 路由 | 改前 | 改后 | 判词 |
|---|--:|--:|---|
| `/finance/freight/new` | **27** | **27** | ✓ 逐字未变(★ **两侧都是整跑读到的,不是补读的**) |
| `/operation/processing/new` | **177** | **177** | ✓ |
| `/purchasing/payment-terms/new` | **143** | **143** | ✓ |
| `/sales/orders/new` | **8** | **8** | ✓(已知不可修,本刀没有碰它) |
| `/tools/pricing/metal-prices/bulk` | **24** | **24** | ✓ |

★ **卡死这一刀落在【别的路由】上,而且两侧不是同一条:**

| | 卡死的是 | 处置 |
|---|---|---|
| 改前那一跑 | `/finance/fx/new` @ phone | 单条补读并并回去(`MERGE_FX_BEFORE_OWN_EXIT=0`) |
| 改后那一跑 | `/finance/fx/bulk` @ phone | 单条补读并并回去(`MERGE_AFTER_OWN_EXIT=0`) |

☞ **所以「`/finance/freight/new` 会卡死」这句话,今天更准的说法是
「`next dev` 的渲染器会偶发卡死,而它不挑路由」** —— 连着四刀都落在 freight 上
是一个足够强的印象,而本刀两跑一次都没落在它身上、却各落在另外一条上。
**这不是一个结论,是一个读数;写出来是因为下一刀会照委托书只去补读 freight。**

### 5.3 ★★ 补读出来的格子能不能信 —— 本刀量了一次,不再靠推理

一个格子从**整跑**读来、另一个从 `--only` 补读来,两边**能不能并排比**?
BTN-TRIGGER-1 把这件事当成显然的。★ **本刀把它量了:**

```
── ACQUISITION-PATH SELF-PROOF:同一棵树、同一个提交,整跑的格子 vs 补读的格子 ──
  ✓ desktop /finance/freight/new  identical  (overflow=0,  tables=1)
  ✓ desktop /finance/fx/bulk      identical  (overflow=0,  tables=1)
  ✓ desktop /finance/fx/new       identical  (overflow=0,  tables=0)
  ✓ phone   /finance/freight/new  identical  (overflow=27, tables=1)
    phone   /finance/fx/bulk      整跑那一格 FAILED —— 它正是补读要补的那一格
  ✓ phone   /finance/fx/new       identical  (overflow=0,  tables=0)
PATHPROOF_CELLS_COMPARED=5  PATHPROOF_DIFFERENCES=0
```

☞ **5 个格子逐字相同。** 补读与整跑读出的是同一份几何,
**所以把补读的格子并回整跑的读数里,不会引入一处假的差异。**

### 5.4 ⚠ 一条要照直说的:**单条路由的 `--only` 补读,它自己的退出码可以是 2**

改前那次 `--only=/finance/fx/new` 报 **`FX_BEFORE_DRIFT_OWN_EXIT=2`**,
而它红在**覆盖断言**上:`量到的表格:实测 0 个,而 1 是下界`。
★ **那条断言是对整跑设的下界,而 `/finance/fx/new` 这一页【本来就一张表都没有】** ——
它在**整跑的 desktop 格**里读到的也是 `tables=0`(那一跑十一条覆盖断言全绿)。
☞ 也就是说:**那个 2 说的是「这一跑的总体太小,我不敢替整跑背书」,
不是「这一格没读出来」。** 那一格的内容是完整的(`docScrollW=390/390`,`tables=0`)。
★ 本刀改后的补读因此**一次跑三条路由**(其中 freight 有表),
`POINTWISE_AFTER_OWN_EXIT=0` —— 同一件事,换一个不触发下界的口径。

### 5.5 (c) —— ★ **按授权在恰好三张表上踩**,见 §3;A1 那几条路由在它射程之外,单独量在 §2

### 5.6 (d) —— 五个封存输出逐个核过

```
git diff --stat -- app/components/ui/control-style.ts app/components/ui/input.tsx \
                   app/components/ui/textarea.tsx app/globals.css app/components/ui/table-style.ts
(空)
```
⚠ `editable-table.tsx` **import 了 `button.tsx`**,而 `button.tsx` 不在封存名单上,
并且**一个字节都没有改**。

### 5.7 ★ (e) —— `/brand-sampler`,三跑取众数

委托书写着它 **±1 不稳**(BTN-TRIGGER-1 在干净树上四跑得到 860 · 860 · 859 · 860),
并要求「跑够次数说出众数」。★ **本刀三跑:**

| 跑 | desktop 渲染成员 | phone 渲染成员 |
|---|--:|--:|
| 1 | 860 | **860** |
| 2 | 860 | **860** |
| 3 | 860 | **860** |

★ **众数 860,三跑一致,一次都没有出现 859。**
`SAMPLER_AFTER_1/2/3_OWN_EXIT=0`,三跑都印着同一个 `BUILD_ID=nDHqvAFgVbr8PRJbXsUo-`。
☞ **不稳的那一格(顶栏头像图的挂载自查)这一轮没有落在 859 那一侧** ——
**照直说:这是三次取样,不是"它已经稳了"的证据。** 那条登记不撤。
★ 顺带:`/brand-sampler` 上**没有 `<EditableTable>`**,本刀按构造碰不到它。

### 5.8 (f) —— 顶栏自己的盒子,逐字未变

| 判据 | 读数 |
|---|---|
| 1280 顶栏盒子 | `1280x53 @top=0 pad=0/0/0/0 sticky z=50` ✓ |
| 390 顶栏盒子 | `390x55 @top=0 pad=0/0/0/0 sticky z=50` ✓ |
| nav field @1280 | `200x32 @top=10 pad=0/12/0/12` ✓ |
| home entry @390 | `358x49.02 @top=329.05 pad=12.8/16/12.8/16` ✓ |
| home entry @1280 | `544x53.63 @top=370.36 pad=14.4/18.4/14.4/18.4` ✓ |

`NAV_AFTER_OWN_EXIT=0`。

### 5.9 ★ 零迁移 —— 量过之后为零,不是想不起来改过什么

`git diff --stat -- db/` 收工时 **0 行**。一条迁移都没有。
☞ 不存在「旧代码 + 新库」那个窗口。**破窗:本刀没有开窗。**

---

## 6 · 每一条命令,以及**它自己打出来的那一行退出码**

★ 照 AGENTS.md:**报的是脚本自己写下的那一行,不是启动它的东西的。**

| 命令 | 它自己那一行 |
|---|---|
| `npx tsc --noEmit`(代码改完 / 文档写完,各一次) | `TSC_OWN_EXIT=0` · `FINAL_TSC_OWN_EXIT=0` |
| `npm run build`(代码改完) | `BUILD_AFTER_OWN_EXIT=0` · `BUILD_ID=nDHqvAFgVbr8PRJbXsUo-` —— ★ **下面每一支探针读的都是这一个** |
| `npm run build`(文档写完再跑一次) | ★ `FINAL_BUILD_OWN_EXIT=0` · `BUILD_ID=l-pAmWsSWZLZITTAQwrQq` |

> ★ **为什么建两次,以及为什么 `BUILD_ID` 是两个不同的值:** 探针那一轮跑在第一次构建上,
> 而交回报告与 `known-issues` 是在那之后写的。**代码一个字节都没有再动**,
> 但一份"我建过"的断言必须指向**收工时树上那一份**,所以文档写完又建了一次 ——
> 两个 ID 都报出来,不拿旧的那个冒充新的。
> ★ **而文档【确实】改不动渲染,这一句是量过的不是抄的:**
> `app/globals.css:28–30` 写着 `@import "tailwindcss" source(none)` + `@source "../app"` + `@source "../lib"`
> —— `docs/` 不在扫描源里(BUGFIX-1a「文档里的散文被扫进生产 CSS」那一条的处置,今天仍然成立)。
| `python3 db/gate.py` | ★ `GATE_OWN_EXIT=0` —— 四个判词全绿(可重建性 · 镜像vs线上 · 行为断言 · 匿名面),wall-clock **382s** |
| `node scripts/smoke-routes.mjs` | `SMOKE_OWN_EXIT=0`(225 条计时 · 合计 543.5s · 中位数 2327ms) |
| `node scripts/check-component-library.mjs` | `COMPLIB_AFTER_OWN_EXIT=0` |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `node scripts/probe-nav-geometry.mjs` | `NAV_AFTER_OWN_EXIT=0` |
| `node scripts/probe-brand-sampler.mjs` ×3 | `SAMPLER_AFTER_1/2/3_OWN_EXIT=0` |
| `node scripts/check-stop-rules-abc.mjs` | ★ `STOPRULE_ABC_OWN_EXIT=0` |
| **行高比对器**(BTN-TRIGGER-1 §7.1 那一支) | ★ `ROWHEIGHT_OWN_EXIT=1` —— **授权的红**,204 张表 · 4 处差异 · 全在那三张表上 |
| ─ 它的注入格 ① 自比 | `ROWH_INJECT1_OWN_EXIT=0` |
| ─ 它的注入格 ② 扰动一行 | `ROWH_INJECT2_OWN_EXIT=1`(**它会咬人**) |
| **`phone-expand.mjs`**(本刀的第七支一次性探针) | `PHONEEXPAND_BEFORE_OWN_EXIT=0` · `PHONEEXPAND_AFTER_OWN_EXIT=0` |
| `survey-controls --mode=drift`(改前 / 改后) | `DRIFT_BEFORE_OWN_EXIT=0` · `DRIFT_AFTER_OWN_EXIT=0` |
| `--only=/finance/freight/new`(改前) | `FREIGHT_BEFORE_DRIFT_OWN_EXIT=0` |
| `--only=/finance/fx/new`(改前补读) | ⚠ `FX_BEFORE_DRIFT_OWN_EXIT=2` —— **覆盖断言的下界,不是那一格没读出来**,见 §5.4 |
| `--only=`(改后补读,三条路由一跑) | `POINTWISE_AFTER_OWN_EXIT=0` |
| 并回去(改前 ×2 / 改后 ×1) | `MERGE_BEFORE_OWN_EXIT=0` · `MERGE_FX_BEFORE_OWN_EXIT=0` · `MERGE_AFTER_OWN_EXIT=0` |

★ **每一支跑在生产构建上的探针都印了它读到的 `.next/BUILD_ID`** ——
SEARCH-1 §6 那次「`git stash pop` 之后没重建,于是对着旧构建量出一个干净的零」就是这么发生的。
★ **两支跑在 `next dev` 上的探针,开跑前 `.next` 都是删干净的**(它们对着生产构建会拿到 404)。

---

## 7 · 本刀登记了什么 / 结清了什么

### 结清

1. ★★★ **`BTNTRIGGER1-EDITABLETABLE-NO-44-STEP`** —— Tim 裁了 `touch`,落地了。**整条删除。**
   ★ 而它的「4 条路由」那一栏**在删之前先被更正**:射程是 3 条,`/me` 按构造没有这颗钮(§1.2)。
2. ★★ **`BTN-TRIGGER-1` ④ 的三处**(转过去、量了、按回来了)—— Tim 接受了三个差值,转回去了。
   那一小节删掉,本条的两个计数跟着更新:裸 `<button>` **4 → 1**,禁用态过不了 AA 的站点 **4 → 1**。

### 仍然登记着

3. ★ **`BTNTRIGGER1-SURVEY-EDIT-PROSE-STALE`** —— `survey-controls.mjs:70–74` 的散文
   仍然写着 FONT-1 早就换掉的判据。**不改量具,登记照旧**(§2.4)。
4. ★★ **`BTN-TRIGGER-1` 名下还剩两件**:`triggerVariant` 仍然是可选的(裸 `<button>` 分支还在,
   今天只剩 `SafetyStatePanel` 一个消费者)· `SafetyStatePanel` 那一处**故意不转**(§4.3)。
   ★ **本条因此【离整条删除只差一个消费者】** —— 写下来,因为那是下一刀最便宜的一格。
5. ★★ **`probe-brand-sampler` 的 phone 成员数 ±1 不稳**:本刀三跑全 860,**没有复现 859**。
   ☞ **三次取样不足以撤销那条登记**,它留着;下一刀若要收紧,判据应当是"跑够次数取众数",
   而不是"它已经稳了"。

### ★ 新登记的一条

6. ★★ **`BTNFOLLOWUP-NEXTDEV-WEDGE-NOT-ROUTE-SPECIFIC`** ——
   「`/finance/freight/new` 在 `next dev` 下反复卡死」这句话,本刀两跑一次都没有在它身上复现,
   而**两跑各在另外一条路由上卡了一次**(`/finance/fx/new` · `/finance/fx/bulk`)。
   ☞ **下一刀不要只去补读 freight** —— 补读的对象应当是**那一跑真的 FAILED 的那些格**,
   由读数决定,不由委托书点名。而补读与整跑读出的是同一份几何(§5.3 量过了)。

---

## 8 · 下一刀开工前要知道的

1. ★★★ **委托书里的「4 条路由」是从一份登记抄来的,而它错了一格**(§1.2)。
   ☞ 这是 AGENTS.md 那一族的又一次,而这一次错的**不是一个数,是一个射程** ——
   四条里有一条**按构造**没有那个主语。**判据便宜得很:`showActions` 那一行,
   连着每个消费者传的 `mode` 与 `onSave` 一起读。**
2. ★★ **一个「点开才渲染」的控件,在册的量具全都看不见它。** 这已经是第二刀在同一格上付账。
   ☞ 想把它接进在册量具的人:`survey-controls` 加一个 `--mode=` 不会改成员签名(不像加 `ROLE_SELECTORS`),
   所以**那条路是通的** —— 本刀没有走,理由是「改一支正在给自己出读数的量具」是本仓库明令不做的事。
3. ★ **`--only=` 单条路由跑在一张没有表的页面上,会红在覆盖断言的下界上**(§5.4)。
   ☞ 补读时**把几条路由凑成一跑**,或者读懂那个 2 再决定信不信它。
4. ★ **`docs/` 不在 Tailwind 的扫描源里**(`app/globals.css` 只 `@source "../app"` 与 `"../lib"`)——
   今天仍然成立,量过了。☞ 于是**写交回报告不会改变渲染**,可以在量具跑着的时候写。
5. ★ **那颗 `EditableTable` 编辑钮启用态此前就不合格(4.463:1)**,而 BTN-TRIGGER-1 只量了禁用态。
   ☞ **一次只量禁用态的对比度普查,它的分母里没有启用态。** 下一族控件的普查值得两态都量。

---

## 9 · 提交(按回滚爆炸半径切,不按大小切)

| # | 内容 | 为什么单独一笔 |
|---|---|---|
| **A** | A1 —— `app/components/ui/editable-table.tsx` | ★ 它是**一个共享组件**,回滚它不该把三个调用点的改动带走 |
| **B** | A2 —— 三个调用点文件 | 回滚它 = 回到三颗裸触发钮。**它碰不到任何共享组件。** |
| **C** | 文档 —— 本报告 · `known-issues.md` | 回滚文档不该动代码,回滚代码不该丢掉这份读数 |
