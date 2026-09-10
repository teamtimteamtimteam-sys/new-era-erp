# INPUT-2b · 交回报告 —— 手搓控件的最后一批 inline class 串接上了共享样式模块

> **一句话,屏幕上变了什么:** 本刀名下 **435 个**自己写着一整串 class 的手搓控件
> (文本框 · 下拉 · 日期 · 数字 · 搜索 · 月份 · 日期时间 · 多行框 · 勾选框 · 文件上传)
> **现在都从 `app/components/ui/control-style.ts` 拿样子** —— 32px 高、8px 圆角、
> 1px `#AEBAC9` 边、左内边距 10px、手机 16px / 桌面 14px 字号;
> 元素仍然是原生的,**宽度类一个都没有动**;
> 而 `/logistics/lanes` · `/hr/attendance` · `/sales/orders/new` 上那三处
> **原本不换行的表单行,现在会换行了** —— 三条路由在 390px 上的整页横向溢出
> 分别从 **+4 → 0** · **+14 → 0** · **+262 → 6**。

---

# ★ 这份报告分两半

| | |
|---|---|
| **上半(本文 §R3-*)** | ★ **ROUND 3 —— 修好了,量完了,上线了。** 这是本刀的**最终状态**。 |
| **下半(本文末尾的附录)** | ⛔ **ROUND 2 的停止记录(2026-09-10),原样保留。** 它记的是「施工做完、判据没过、停在 R6(a) 上」的那一刻。<br>★ **不要把它当成本刀的最终状态读** —— 它里面那句「`§7` 一步都没做」在 ROUND 3 之后**已经不成立**。 |

---

## R3-0 · 这一轮的坐标

| | |
|---|---|
| 开工前 HEAD | `3b021633b0b1540a89bb827a9c441d3a2aa4c11d` = `origin/main`(★ **实测三方相等**) |
| 工作区状态 | ★ **有未提交改动,而这是预期的** —— ROUND 2 的转换成果:`git status --porcelain` **130 条**(**124 个 `app/`** + `AGENTS.md` · `docs/forward-queue.md` · `docs/known-issues.md` · `docs/variant-c-spec.md` · `scripts/smoke-routes.mjs` + 未跟踪的 `docs/handbacks/INPUT-2b.md`) |
| 委托书 | **INPUT-2b ROUND 3**(Tim 对 ROUND 2 交回的四条裁定 T1–T4;**没有停止闸,跑到底**) |
| 安全副本(§1.4) | `/tmp/input2b-r3/tree-before.patch` **5876 行** · 未跟踪文件 **1 个**,已按路径复制进 `/tmp/input2b-r3/untracked/` |
| 标准 | `docs/variant-c-spec.md` |
| ★ **ROUND 3 自己动的代码** | ★★ **2 个 `flex-wrap`,落在 2 个文件里** —— 逐字节证过(见 §R3-4.2)。**别的一个字节都没动。** |

---

## R3-1 · §1.6 —— 委托书里每一个【被我当成阈值用】的数,重量的结果

> **规矩(AGENTS.md):委托书里的数字一个都不许直接引用。**
> 下面每一条都标 **confirmed / wrong / not re-measured**,**包括量下来是对的那些**。

| 委托书里的数 | 我拿它当阈值了吗 | 判定 | 重量的方法与结果 |
|---|---|---|---|
| HEAD `3b02163…` = `origin/main` | ★ 是(§1.1 开工闸) | ★ **confirmed** | `git rev-parse HEAD` / `origin/main`,两个都是 `3b021633b0b1540a89bb827a9c441d3a2aa4c11d` |
| 「124 个 `app/` 文件 + 5 个 doc/script」 | ★ 是(§1.2 开工闸) | ★ **confirmed** | `git status --porcelain`:**130 条 = 129 modified + 1 untracked**;`^ M app/` **124**;另 5 条是 `AGENTS.md` · 三份 docs · `scripts/smoke-routes.mjs`;未跟踪的就是 `docs/handbacks/INPUT-2b.md` |
| 四件产物都在(§1.3) | ★ 是 | ★ **confirmed** | 逐条 `test -e` + 字节数:停止闸 31310 · 分类 341799 · 改前 drift 2370786 · 改前 edit 86064,**全部非空** |
| **`/hr/attendance`:改前 0 → ROUND 2 改后 +14** | ★★ 是(T1 的验收线) | ★ **confirmed** | ① 改前那一份读数里 `docScrollW − docClientW` = **0**;② 本轮在**动手之前**用自己的探针重量了一次带转换的树:**14**。**两个数都对上。** |
| **`/sales/orders/new`:改前 +205 → ROUND 2 改后 +262** | ★★ 是(T1 的验收线) | ★ **confirmed** | 同上:改前读数 **205**,本轮改前重量 **262** |
| **月份框 168 → 191px** | ★ 是(元凶判定) | ★ **confirmed** | 改前读数 `phone|/hr/attendance|input.date#0 rectW=168`;本轮重量 **191**(桌面 160 → 164) |
| **五颗 `flex-1` 下拉 307 → 364px** | ★ 是(元凶判定) | ★ **confirmed** | 改前读数 `select.native#2..#6` **各 307**;本轮重量 **各 364**(桌面各 448,逐字未变) |
| ★ **「元凶是那个月份框 / 那五颗下拉」** | ★ 是 | ★★ **wrong —— 半条** | ★ **`/sales/orders/new` 对:**探出页面的正是那五颗下拉那一行(最右是 `w-32` 单价框,right=652)。<br>★★ **`/hr/attendance` 错:**那个月份框的右边缘在 **240px**,离 390 还远;真正探到 **403.11px** 的是同一行最后那句 `<p className="text-xs text-gray-500">` 提示语 —— **它是被月份框长出来的 23px 推出去的**。<br>☞ **「谁变宽了」与「谁探出了页面」不是同一个元素。** 裁定的方向不受影响(元凶那一行是同一行),但读数要照直说。 |
| ★ **T2(ii):「原生 `<select>` 压不到最长 option + 内边距 + 箭头保留区以下,长选项可能被截」** | ★★ 是(它决定我加不加 `min-w-0`) | ★★★ **wrong** | ★ **加了 `min-w-0` 之后那颗下拉塌到 70px,6 个选项【全部】被截** —— 不是"floor 在最长选项上"。机制见 §R3-4.3。**这条测量是我【没有】采用 (ii) 的理由。** |
| 「`docs/row-height-baseline.md` 记着 12 张有控件的基线表」 | ★ 是(R6(c)) | ★ **confirmed** | 比对器自己打印「比过的表:12 / 基线 12 张」(见 §R3-5.2) |
| **eslint 冻结基线 42 错 / 88 警** | ★ 是(§7.2) | ★ **confirmed(指提交在册的那份)** | `scripts/lint-baseline.json` → `{"errors":42,"warnings":88}`;本轮实跑见 §R3-7.2 |
| **20.3px 的箭头保留区** | ★ 是(§5.5 的判据) | ★ **not re-measured** | ★ **照直说:本轮【没有】重量它。** 它是 ROUND 1 在同一棵树、同一支 chrome 上量的(5 配置 × 2 视口,20.21–20.31),ROUND 2 与 ROUND 3 都直接采用。**它是本刀 select 判据的地基。** |
| **435 个站点 / 422(+1)次编辑 / 124 个文件** | ★ 是(施工清单) | ★ **confirmed** | 重算 `classification-final.json`:`units` **436** = **414 A + 3 B + 18 C + 1 B(Q10)**;**去重后的文件 124 个**。**与 ROUND 2 报的逐字相同。** |
| 冒烟整跑 **871 秒**(ROUND 2 实测) | 否(只作估价) | ★ **wrong(对本轮而言偏高)** | 本轮实跑 **377 秒**(§R3-7.3,248 ok / 6 skipped / 0 FAILED)。★ 与 drift 那一行同一个原因:`.next` 热不热。**两个数各自都对**,估价用冷的 871 |
| `--mode=drift` 整跑 **1669 秒**(ROUND 2 实测) | 否(只作估价) | ★ **wrong(对本轮而言偏高)** | 本轮实跑 **727 秒**(§R3-15)。★ **而这【不是】说 1669 错了** —— 差别是 `.next` 热不热,**两个数各自都对**;给 INPUT-3 估价要用冷的那个 1669(见 §R3-18) |

---

## R3-2 · §2 —— Tim 那六条在册裁定,逐条 DONE / NOT DONE

> **规矩(§8):没有被提到的算 NOT DONE;「代码里有」不算 done,「操作员在屏幕上看得见」才算。**

| # | 裁定 | 状态 | 证据 |
|---|---|---|---|
| **R1** | 一处共享样式模块;手搓控件**保持原生**,只通过 className 拿样子;`<Input>` / `<Textarea>` 读同一模块且 class 串**逐字节不变** | ★ **DONE** | `git status --porcelain app/components/ui/control-style.ts app/components/ui/input.tsx app/components/ui/textarea.tsx` → ★ **空**。三个文件**一个字节都没动** → 那两条 class 串**按构造不可能变**(R6(e) 的证明,见 §R3-5.3) |
| **R2** | 只用模块里已有的那几个值(32/8/1px `#AEBAC9`/左 10;select 右 24 + 保留箭头;textarea ≥64 且去 `rows=`;勾选与单选照模块;文件钮 `CONTROL_FILE_BUTTON`) | ★ **DONE** | §R3-5.4:首屏接了模块的控件**两个视口各 N 个,合 N 个,不合 0 个**(逐项判据写死在 `judge.mjs` 里) |
| **R3** | **宽度类一个都不动**,除了 §3 的 T1 / T2 授权的那两处修复 | ★ **DONE** | ★ **本轮加的两个类【都不是宽度类】** —— 是 `flex-wrap`,而且加在**行容器**上,不在控件上(逐字节 diff 见 §R3-4.2)。★ **T1(ii) 授权的 `min-w-0` 量过、报了、最终【没有采用】**(§R3-4.3) |
| **R4** | `/login`(E1)· 收货与盘点触控档(E6)· `ExpectedDateControl.tsx`(Q13)· 每一个 `<label>` / 按钮 / `type="hidden"` · 每一个渲染 `<DecimalInput>` 的文件 —— 一律不碰 | ★ **DONE** | 改动的 124 个文件里**没有一个**是这几类;`type="hidden"` 全树 57 个(本刀名下 17 个)一处都没进施工清单;`<DecimalInput>` 那 23 个文件**不在 `classification-final.json` 里** |
| **R5** | uppercase 留;控件自己的字色剥(除非 `disabled` / `readOnly`);三元改成「基础样式 always + 状态类 only-when」;**同时在两张清单上 → 留赢** | ★ **DONE** | 字色 6 处:**留 5(全部 `disabled`)· 剥 1**(`CertificatePanel.tsx` 那个既不 disabled 也不 readOnly 的 `text-gray-900`);`PayPanel.tsx` 照「模块 always + 错误类 only-when-in-error」改写 |
| **R6(a)–(e)** | 五条停止条件 | ★ **DONE —— 五条逐条判过,见 §R3-5.3** | ★ **本轮没有一条停手** |

---

## R3-3 · §3 —— Tim 对 ROUND 2 交回的四条裁定,逐条 DONE / NOT DONE

| # | 裁定 | 状态 | 证据 |
|---|---|---|---|
| **T1** | 修那两条踩了 R6(a) 的路由;修复次序 (i) `flex-wrap` →(ii) 必要时 `min-w-0` / `max-w-full`;**按类串与元素定位,不认行号**;**import 追踪证明哪几条路由渲染每个被改的文件**;达不到验收就停手交回 | ★ **DONE,验收全过** | 见 §R3-4。两条路由:`/hr/attendance` **14 → 0**(要 ≤0)· `/sales/orders/new` **262 → 6**(要 ≤205);两条 @1440 都是 **0 → 0**。定位用 `grep -c` 断言**各命中恰好 1 处**;import 追踪:**两个文件各只渲染在一条路由上** |
| **T2** | 标准修复规则,本轮与 INPUT-3 通用;修回改前读数内就**继续**;三种情况仍然停手 | ★ **DONE** | 规则原文已写进 `docs/variant-c-spec.md` **§4.1d** 与 `docs/forward-queue.md` 的 INPUT-3 那一节。★ **本轮 R6(a) 只有那两条长大,两条都用 (i) 修回来了,没有第三条需要 T2** |
| **T3** | 一刀的文件渲染在另一刀的路由上**不是**范围泄漏(条件:那条路由的基线表四字段与 390px 溢出都没变);`SourcePicker.tsx` 那 8 个成员**保留**;逐条列出;把修订过的归属措辞写进 forward-queue 的 INPUT-3 | ★ **DONE** | 见 §R3-5.3 的 R6(d) 与 §R3-6(SourcePicker 归属那一段)。措辞已写进 `docs/forward-queue.md`「给 INPUT-3 的三条」② |
| **T4** | `/tools/pricing/metal-prices/new` 那颗被截 ~24px 的下拉:**不动**(它有宽度类),登记进 forward-queue 的**字体/排版**那一刀 | ★ **DONE** | `docs/forward-queue.md` 新条目「★ 【字体/排版】那一刀名下的一条,由 INPUT-2b 登记(Tim 2026-09-11, T4)」,含实测值、为什么不修、为什么归那一刀、以及现成的判据与量法 |

---

## R3-4 · §4 —— 那两条路由是怎么修的

### 4.1 §4.1 —— 动手【之前】的读数(`/tmp/input2b-r3/repair-before.json`)

**量的是:整页 `scrollWidth` · 每一个控件的渲染宽 · 哪一行把页面撑宽的 · 每一个行容器的 `flex-wrap` 实测值。**

| 视口 | 路由 | 整页 | 元凶那一行 | 那一行的 `flex-wrap` | 探出页面的是谁 |
|---|---|--:|---|---|---|
| **390** | `/hr/attendance` | **404 / 390 = +14** | `<div class="flex items-end gap-3">`(w=292,**scrollW=354**) | ★ **nowrap** | ★ `<p class="text-xs text-gray-500">`,**right = 403.11** |
| **390** | `/sales/orders/new` | **652 / 390 = +262** | `<div class="flex gap-2">` ×5(各 w=326,**scrollW=620**) | ★ **nowrap** | `input.w-32`(单价),**right = 652** |
| 1440 | `/hr/attendance` | 1440 / 1440 = **0** | 同一行(w=926,scrollW=926) | nowrap | —— |
| 1440 | `/sales/orders/new` | 1440 / 1440 = **0** | 同 5 行(各 w=704,scrollW=704 —— **恰好装满**) | nowrap | —— |

**那五颗下拉的几何,逐字写下来(它是 (ii) 那一步的全部依据):**
`min-width: auto` · `flex-basis: 0%` · 渲染 **364px** · `clientWidth` 362 · padL 10 / padR 24 ·
行的可用宽 **326px** → **下拉比它的行宽 38px**。

### 4.2 §4.2 —— 加了什么,以及【只加了这些】的逐字节证明

**按类串与元素定位(不认行号),两处都断言「恰好命中 1 次」:**

| 文件 | 那一行 | 加的类 | `grep -c` |
|---|---|---|--:|
| `app/hr/attendance/OpenPeriodForm.tsx` | `<div className="flex items-end gap-3">` | ★ **`flex-wrap`** | **1** |
| `app/sales/orders/new/NewOrderForm.tsx` | `<div key={i} className="flex gap-2">`(`LINE_SLOTS` 循环,渲染 5 次) | ★ **`flex-wrap`** | **1** |

★ **证明「ROUND 3 只动了这两个类」:** 把 §1.4 那份安全副本 patch 里这两个文件的 hunk 抽出来、
套在 `git show HEAD:` 的原版上,重建出 **ROUND 2 交回时的那两个文件**,再与工作区里的现版逐行 `diff` ——

```
--- ROUND-2 状态 +++ 现在
-            <div className="flex items-end gap-3">
+            <div className="flex flex-wrap items-end gap-3">
-                            <div key={i} className="flex gap-2">
+                            <div key={i} className="flex flex-wrap gap-2">
```

★ **两个文件各一处,合计两行。字号 · 内边距 · 边框 · 圆角 · 任何宽度类 —— 一个字节都没动。**

★ **import 追踪(跟着「真的被当成 JSX 画出来」的边做闭包,枚举了全仓库 200 条路由):**

| 文件 | 渲染在几条路由上 | 链 |
|---|--:|---|
| `app/hr/attendance/OpenPeriodForm.tsx` | ★ **1** | `app/hr/attendance/page.tsx` → `<OpenPeriodForm>` |
| `app/sales/orders/new/NewOrderForm.tsx` | ★ **1** | `app/sales/orders/new/page.tsx` → `<NewOrderForm>` |

☞ **所以「别的每一条渲染了被改文件的路由仍然过 R6」这句话,在本轮是【没有别的路由】** ——
而这不是靠说的,是靠那份 200 条路由的闭包量出来的。

### 4.3 ★★★ §4.3 —— (ii) 那一步:量了,报了,**没有采用** ★★★

**T1 的次序说「只有当某个控件此时仍然比它有的空间宽,才加 `min-w-0` / `max-w-full`」。
★ 加完 `flex-wrap` 之后,那颗下拉【确实】仍然比它的行宽 38px(364 vs 326)—— 条件成立。
于是我把 (ii) 做了一遍、量了一遍,然后把它撤了。理由是量出来的:**

| | 390px 实测 |
|---|---|
| **只加 `flex-wrap`** | 那一行换行:**下拉独占第一行 364px**,数量(112)+ 单价(128)落到第二行(right=280);<br>整页溢出 **262 → 6**;★ **6 个选项【一个都没有被截】** |
| ★ **再加 `min-w-0`** | ★★ **下拉塌到 70px**(= 326 − 112 − 128 − 16),整页溢出 6 → 0,<br>★★ **6 个选项【全部】被截** —— 连占位的「Select material」都看不完 |
| **机制** | `min-width: 0` 之后,那颗 `flex-basis: 0%` 的下拉**假想主尺寸变成 0** → ★ **它不再逼出换行**,三件东西挤回同一行,下拉只拿到 flex 分完剩下的 70px。<br>☞ **托底是 `min-width: auto` 给的;把它换成 0,托底整条就没有了 —— 不是"降到最长选项为止"。** |
| **`max-w-full` 单独用** | **无效** —— CSS 里 `min-width` **压过** `max-width`,下拉仍然 364px,溢出仍然 6 |
| ★ **裁决** | ★ **不加。** T1 的验收线是 **≤ 205**,只用 (i) 已经到 **6**;<br>「能奏效的最小改动」就是**不再加**。拿 6px 去换**一个操作员看不出自己选了哪种物料的下拉** —— 那不是一次修复。 |
| **被截的选项(委托书点名要报)** | 若采用 (ii),这 6 条**全部**被截:`Select material` · `MAT-2026-0001 — NMC Cathode Foil` · `MAT-2026-0002 — Special Battery Material` · `MAT-2026-0076 — Film` · `ZZ-SMOKE-NTF — NTF-1 walk scratch` · `ZZ-SMOKE-PROBE — probe`。<br>★ **不采用 (ii) 的现况:这 6 条【一条都没有被截】。** |
| 读数留档 | `/tmp/input2b-r3/repair-minw0-experiment.json`(那一次的完整读数,没有丢掉) |

### 4.4 §4.4 —— `tsc --noEmit`

```
TSC_OWN_EXIT=0        ← 输出 0 行(删掉 tsbuildinfo 后整跑,9 秒)
```

### 4.5 §4.5 —— 文案 / i18n / 行为 / 提交形状 / 迁移

★ **本轮加的两个类是【版式类】,不是行为** —— 没有改任何文字、任何 `t()` 键、任何 `name=`、
任何 `onChange` / `onClick`、任何表单字段。**`db/migrations/` 一个文件都没加。**
证据:§4.2 那份逐行 diff —— **整轮的代码改动就是那两行**。

---

## R3-5 · §5 —— 全量改后读数,以及 R6(a)–(e) 逐条

### 5.1 §5.1 —— 两次整跑 + 一次单条补量

| | |
|---|---|
| `.next/BUILD_ID` | ★ **不存在** —— 量具自己的前置条件已满足,**不必 `rm -rf .next`**(它只在 `BUILD_ID` 在时才要求) |
| `--mode=drift`(141 条静态路由 × 2 视口) | `SURVEY_OUT=.survey-out/input2b-after-r3` · **727 秒** · ★ **`DRIFT_OWN_EXIT=0`** |
| `--mode=edit` | 同上目录 · **117 秒** · ★ **`EDIT_OWN_EXIT=0`**;`<EditableTable>` 住在 4 个文件里 → 4 条静态路由,两个视口各点开 2 张表(`/hr/leave/types` 12 个控件 · `/hr/reviews/scale` 14 个) |
| ★ **卡死的路由** | ★ **1 条:`/purchasing` @ phone**(`renderer wedged: CDP timeout`,量具自己重开了 chrome 并跑完剩下的 31 条)。<br>☞ **ROUND 2 卡的是 `/finance/freight/new`** —— **同一个失效模式,换了一条路由**,本轮 `freight` 反而量到了。 |
| 单条补量 | `--only=/purchasing,/finance/fx/bulk`(**前缀匹配,实际跑到 8 条**)· `SURVEY_OUT=.survey-out/input2b-after-r3-repair` · **85 秒** · ★ **`REPAIR_OWN_EXIT=0`** |
| 并入 | `✓ phone|/purchasing:用补量替换(整跑 ready=missing → 补量 ok)`;`desktop|/purchasing` 整跑本来就 ok → **不替换,陪跑读数丢掉** · ★ **`MERGE_OWN_EXIT=0`** |
| 并完之后 | ★ **desktop 读不到的路由 = 0 · phone 读不到的路由 = 0** |

### 5.2 §5.2 —— 三条比对,每一条【自己的】退出码

```
MERGE_OWN_EXIT=0
CMP_DRIFT_OWN_EXIT=0     ← 成员 A=3548 B=3548;多出 0 · 少掉 0 · 值变 578 →「这一条作数」
CMP_EDIT_OWN_EXIT=1      ← ★ 118 个成员逐字相同 →「这一条不作数」(见下)
★ ROWHEIGHT_OWN_EXIT=0   ← ★★ 行高比对器【绿了】—— ROUND 2 这里是 1
WIDTH_OWN_EXIT=0
```

★ **`CMP_EDIT_OWN_EXIT=1` 不是失败,而这一格必须说清:** 那支比对器的 **1** 表示
「**成员名单与每一个值都逐字相同**」—— 它是为**致盲**设计的判词(一次什么都没拿走的致盲证明不了任何事),
而对**本刀**这恰恰是要的结果:编辑态那 118 个成员**全部住在 INPUT-3 的表里**
(`/hr/leave/types` · `/hr/reviews/scale`),本刀一个字节都没碰。
☞ **同一个退出码,在两种用法下含义相反。照直记下来,免得下一刀把它读成一次失败。**

### 5.2b ★★ 与 `docs/row-height-baseline.md` 的差值 —— 【另报一行】(Q2 要的)★★

```
· 比过的表:12 / 基线 12 张;编辑态 2 / 2 张
· 整页溢出:基线 7 条,读数 6 条
· 已裁定横滚的表:11 张
· 变小了的(不是回归,登记在案):
    · /logistics/lanes:整页横向溢出没有了  12 → 0
    · /sales/orders/new:整页横向溢出变小了  205 → 6
✓ check-row-height-baseline:12 张含控件的表逐项与基线相同(表头高 · 行数 · 最大行高 · 滚动壳内容宽);
  390px 整页溢出没有新增也没有长大;11 张已裁定横滚的表一张都没有多出滚动范围。
ROWHEIGHT_OWN_EXIT=0
```

★★ **这一行是 ROUND 3 与 ROUND 2 之间最硬的那个差别:**
ROUND 2 同一支比对器退 **1**,点名 `/hr/attendance 0 → 14` 与 `/sales/orders/new 205 → 262`;
**ROUND 3 退 0,而且基线文档记的 7 条溢出路由现在只剩 6 条**(`/logistics/lanes` 那一条没有了)。
☞ ⚠ **它另外打了 5 行警告**:5 条路由上有表头签名逐字相同的表(`/settings/dictionaries` 6 张、
`/settings/reference` 3 张、另外三条各 2 张),身份退回「同签名里的第几个」。
**那不是本轮的新情况,是那支比对器一直在报的自我披露** —— 只按签名比会把它们静默错配成一次假的行高变化。
★ **`/settings/accounts` 那个 ±1px 本轮又晃了一次:改前 36 → 改后 35**,方向与 ROUND 1 那次相反,
**而基线文档记的是 35 —— 于是它在基线那一份里读成"和基线一样",在本刀自己那一份里读成"变小了 1px"。**
两个参照点在这一格给出不同的字面结果,**而 Q2 的规则让停不停手只由后者决定**(它变小了,不停手)。

### 5.3 §5.3 —— R6(a)–(e) 逐条

| 停止条件 | 参照点 | ★ 结果 | 读数 |
|---|---|---|---|
| **R6(a)** 390px 新增或长大的整页溢出 | ★ **本刀自己的改前读数**(Q2) | ★★ **过 —— 长大的 0 条** | 有变化的 **3** 条,**全部变小**:`/logistics/lanes` **4 → 0** · `/sales/orders/new` **205 → 6** · `/settings/accounts` **36 → 35**。<br>★ `/hr/attendance` **0 → 0**(它在 ROUND 2 是 0 → 14) |
| **1px 复量规则** | —— | ★ **一次都没有用上** | **没有任何一条长大**,所以既没有 +1px 的,也没有 ≥2px 的 |
| **R6(b)** 已裁定横滚的表多出滚动范围 | 本刀自己的改前读数 | ✅ **过** | phone 上比过 **102 张表**,多出滚动范围的 **0 张**(行高比对器另一侧:11 张已裁定横滚的表,**0 张**多出) |
| **R6(c)** 12 张基线表的表头高 / 行数 / 最大行高 / 滚动壳内容宽 | `docs/row-height-baseline.md` | ✅ **过** | `r6.mjs`:**变了的 0**;行高比对器:「**12 张逐项与基线相同**」。★ **这一刀没有推动任何一张表的行高。** |
| **R6(d)** 那 14 条 INPUT-3 路由上有任何东西变了 | 本刀自己的改前读数 | ⚠ **8 个成员变了 —— 而 T3 明确裁定这【不是】停手** | ★ **8 个全部在 `/tools/pricing/metal-prices/bulk` 上**(desktop `input.text#0` + `select.native#0/1/2`,phone 同四个),全部来自 `SourcePicker.tsx`。<br>★ **那 14 条路由上的整页溢出:0 条变化**;★ **基线表四字段:0 张变化** → **T3 的条件逐条满足**。其余 13 条路由**一个成员都没变**。 |
| **R6(e)** `<Input>` / `<Textarea>` 发出去的 class 串变了 | HEAD | ✅ **过,而且是【按构造】过的** | `git status --porcelain app/components/ui/control-style.ts app/components/ui/input.tsx app/components/ui/textarea.tsx` → **空**。**三个文件一个字节都没动**,所以那两条 class 串不可能变 |

### 5.3b §5.3 —— 控件渲染宽度的变化(★ 按裁定:报出来,不停手)

| | |
|---|--:|
| 成员 | **2112 → 2112**(多出 **0** · 少掉 **0**) |
| 渲染宽度变了的成员 | **261** |
| ★ 其中是 `<label>` 的(它们包着控件,跟着变宽) | **90** |
| ★ **控件本身** | ★ **171** |
| 宽度**逐字未变**的成员 | **1851** |

**按控件类型:** `input.date` **82** · `select.native` **80** · `input.checkbox` **6** ·
`input.text` **2** · `input.file` **1**

**按变化量(前几档):** `+10` **32** · `−4` **26** · `+4` **17** · `+11` **15** · `+19` **15** ·
`+18` **6** · `−19` **6** · `−2` **6** · `+3` **6** · ★ `+57` **5**(就是 `/sales/orders/new` 那五颗下拉) ·
最大 `+57` · 最小 `−40`

**变化落在 79 个 (视口 × 路由) 格子上**,最多的几条:
`phone /hr/employees/new` 6 · `phone /inbound` 6 · `desktop /hr/employees/new` 5 ·
`desktop /inbound` 5 · `desktop /output` 5 · `phone /output` 5 · ★ `phone /sales/orders/new` 5

☞ **一处自证:`/logistics/lanes` 上那个 `w-28` 的编号框,改前改后都是 112px** ——
它写了宽度类,而标准改字号与内边距时它一个像素都没动。**这一行本身就是「宽度类没有被碰」的证据。**

### 5.4 §5.4 —— R2 逐项:**229 个,229 个合,0 个不合**(两个视口都是)

**量的是【首屏渲染出来、且已经接到模块上】的控件**,判据逐项写死在 `/tmp/input2b-r3/judge.mjs` 里。

| | phone 390 | desktop 1440 |
|---|--:|--:|
| 接了模块的首屏控件 | **229** | **229** |
| ★ **合** | ★ **229** | ★ **229** |
| ★ **不合** | ★ **0** | ★ **0** |

**按类:** `input` **126** · `select` **73** · `textarea` **15** · `checkbox` **11** ·
`file` **2** · `radio` **2**

**委托书点名的三件,判据怎么认的:**

| 要认的 | 怎么认的 | 本轮实际命中 |
|---|---|---|
| **E6 按裁定不一样** | 判据先按 `min-h-[48px]` 把 E6 那一档**摘出去**,单独计数,不算进"不合" | ★ **0 个** —— 因为 E6 那两页(`/inbound/receive` · `/stocktakes/*`)**不在本刀这 58 条路由里**。**照直说:这一轮它仍然没有被考验过。** |
| **默认勾上的框边框是 `#007FAD`** | 期望值按 `checked \|\| indeterminate` 分支:选中 → `rgb(0,127,173)`,未选中 → `rgb(98,115,140)` | 11 个勾选 + 2 个单选**全部合** |
| **`rounded-full` 报成 3.35544e+07px** | 单选框不比字面值,改判「`^3.3554` 或 `parseFloat ≥ 9999`」 | 2 个单选框合 |
| (另加)**校验失败态自带另一条边框色** | `aria-invalid="true"` 时**不比**边框色 | 命中的正是 `PayPanel.tsx` 那个日期框 |

☞ **一处边界照直说:这 229 个里包含 INPUT-2 已经接好的那一批**(比如那 2 个单选框来自 `MaterialAxesPicker`)。
这一节答的是「**本刀这 58 条路由的首屏上,凡是接了模块的控件,是不是都长成 R2 说的样子**」,
**不是**「本刀转的每一个都合」—— 后者答不了,因为 260 个站点首屏量不到(§5.6)。

### 5.5 §5.5 —— select 装得下吗(20.3px 保留区,**Chromium only**)

**判据(写死):选中项文字宽 ≤ `clientWidth` − `padding-left` − `padding-right` − 20.3px。**

| | phone 390 | desktop 1440 |
|---|--:|--:|
| 首屏原生 `<select>` | **73** | **73** |
| 装得下 | **66** | **70** |
| ★ 装不下 | ★ **7** | ★ **3** |

#### phone 390px 的 7 颗,逐颗 —— 归属 · 本刀动过吗

| 短多少 | 路由 | 归哪一刀 | 本刀动过它吗 | 选中项 | 有宽度类吗 |
|--:|---|---|---|---|---|
| ★ **24.01px** | `/tools/pricing/metal-prices/new` | ★ **INPUT-2b** | ★ **动过它的【样式】,没动它的【宽度】** —— 右内边距 12→24 让它多短了 10px(ROUND 1 改前是 14.01) | 「— only for a published-index quote —」 | ★ **有** |
| 0.64px | `/inbound/new` | **INPUT-2b** | 动过样式,没动宽度 | 「Unspecified — assign later by transfer」 | 有 |
| 0.64px | `/output/new` | **INPUT-2b** | 同上 | 同上 | 有 |
| 0.27px | `/settings/import` | **INPUT-2b** | 动过样式;★ **短缺量逐字未变**(改前也是 0.27) | 「— choose a table —」 | 没有 |
| 0.24px | `/tools/converter` | **INPUT-2b** | 同上(改前也是 0.24) | 「as received → dry」 | 没有 |
| 0.14px | `/finance/close` | **INPUT-2b** | 动过样式,新进名单 | 「2026-08-31」 | 没有 |
| 0.11px | `/hr/leave` | **INPUT-2b** | 同上(改前也是 0.11) | 「All statuses」 | 没有 |

#### desktop 1440px 的 3 颗

| 短多少 | 路由 | 归哪一刀 | 选中项 | 有宽度类吗 |
|--:|---|---|---|---|
| 0.23px | `/inbound` | INPUT-2b | 「All pricing states」 | 没有 |
| 0.15px | `/settings/import` | INPUT-2b | 「— choose a table —」 | 没有 |
| 0.12px | `/tools/converter` | INPUT-2b | 「as received → dry」 | 没有 |

★ **10 颗里 9 颗差不到 0.7px** —— 那是「正好装满」,不是「被截掉」。
**真正在屏幕上少了字的只有一颗**,而它写着宽度类、本刀没有动它的宽度 → **Tim 的 T4 把它给了字体/排版那一刀。**

#### ★ 两条修好的路由,单独报(委托书点名要求)

| 路由 | 首屏原生 select | 装不下的 | 说明 |
|---|--:|--:|---|
| ★ **`/sales/orders/new`** | ★ **7 颗**(2 颗表头 + **5 颗物料下拉**) | ★ **0 颗** | ★★ **那 5 颗 364px 的物料下拉【一颗都没有装不下】** —— 它们的选中项是占位的「Select material」。<br>★ **而如果采用了 (ii) 的 `min-w-0`,它们会塌到 70px,6 个选项【全部】被截**(§R3-4.3)。**这是"没有采用 (ii)"这个决定的直接读数。** |
| ★ **`/hr/attendance`** | **0 颗**(那一页首屏只有一个 `input type="month"`) | **0 颗** | 换行之后月份框仍然是 191px,**没有被压缩**,也没有任何文字被截 |

**截图(仓库外,7 张,390px,`deviceScaleFactor: 3`,clip = 视口坐标 + 滚动偏移):**
`/tmp/input2b-r3/shots-select/misfit-01.png` … `misfit-07.png` ——
01 `/finance/close` · 02 `/hr/leave` · 03 `/inbound/new` · 04 `/output/new` ·
05 `/settings/import` · 06 `/tools/converter` · ★ 07 `/tools/pricing/metal-prices/new`(唯一真被截的那颗)。

### 5.6 §5.6 —— UNMEASURED:转换了 435 个站点,其中 **260 个首屏量不到**

**判据答得了「这条路由上有 N 个站点从来没在首屏出现过」,答不了「是哪一个」**
—— 它比的是**每条路由上的个数**,不是逐个站点的身份。

| | 路由数 | 站点数 |
|---|--:|--:|
| **量具结构上走不到**(`[id]` 动态路由 / 不是路由的目录) | **24** | **162** |
| **首屏没有全部渲染**(对话框 / 折叠面板 / 编辑开关) | **22** | **98** |
| ★ **合计 UNMEASURED** | **46** | ★★ **260 / 435(60%)** |

**最大的几条:** `/suppliers/[id]/edit` **24** · `/finance/assets/[id]` **22** ·
`/inbound/[id]/edit` **17** · `/sales/customers` **17**(转了 18,首屏只见 1)·
`/sales/customers/[id]/edit` **16** · `/hr/employees` **13**(转了 17,首屏见 4)·
`/materials/[id]/edit` **9** · `/sales/orders/[id]` **9** · `/output/[id]/edit` **8** ·
`/finance/cash-forecast` **7**(转了 8,首屏见 1)。

☞ **与 ROUND 2 那份逐字相同**(260 / 435 / 46 条路由)—— **本轮没有新增也没有减少任何一个站点**,
两个 `flex-wrap` 不改变任何控件的存在与否。

---

## R3-6 · §6 —— 文档(与工作同一个提交)

**ROUND 2 的文档改动【原样留着】,本轮在它们之上加:**

| 文件 | 加了什么 |
|---|---|
| `docs/variant-c-spec.md` | ★ **新增 §4.1d「一次版式长大的【标准修法】—— 修复次序,而不是改标准(Tim 2026-09-11, T2)」** —— 修复次序全文、仍然停手的三种、不许动的东西、为什么这一招对;<br>★ **实测落地表**:两条路由的行**现在会换行了**,按类串与元素定位,连 import 追踪一起;<br>★ **「(ii) 没有用上」那一整节**:`min-w-0` 的实测后果与机制、`max-w-full` 为什么无效、裁决。<br>★ **§4.1a 就地更正两处**:元凶按类串定位(不认行号);`/hr/attendance` 那 14px **不是月份框自己顶出去的**。<br>★ **`/logistics/lanes` 那一格的「没有上线」警告就地改成「已经上线」**,并指向 §4.1d。 |
| `docs/forward-queue.md` | ★ **`⛔ INPUT-2b` → `✅ INPUT-2b —— 已完成 2026-09-11`**,带最终计数表、ROUND 2 停在哪 / ROUND 3 怎么修的、验收线、import 追踪、`/hr/attendance` 那处细节更正、以及 `min-w-0` 那一节;<br>★ **新增「给 INPUT-3 的三条」**:① T2 的修复次序(含 `min-w-0` 的实测警告)· ② T3 的归属规则(含 `SourcePicker` 的落点)· ③ 检出器那条教训(两个错判据 + 改过的判据一句话);<br>★ **新增 T4 的登记**:`/tools/pricing/metal-prices/new` 那颗下拉归**字体/排版**那一刀,带实测值、为什么不修、为什么归那一刀、现成的判据与量法;<br>★ **同屏新旧两种控件的 6 条路由**:ROUND 2 已经写在案,本轮**逐条复核后原样保留**。 |
| `docs/known-issues.md` | ★ ROUND 2 的条目**一条都没删**(`SMOKE-PREFLIGHT-COD-TOKEN` 已关闭 · `SMOKE-AVATAR-BYTES-UNCOVERED` · `SETTINGS-ACCOUNTS-1PX`);<br>★ **本轮给 `SMOKE-PREFLIGHT-COD-TOKEN` 补一次【第二跑】的实测**,把「每一次冒烟在这条路由上写什么」那张表从「首跑实测」升成**两跑都对上**(见 §R3-7.3)。 |
| `AGENTS.md` | ★ ROUND 2 那条放宽过的教训**原样留着**;<br>★ **新增一段**:「一个【证明了自己在看】的检出器,仍然会报出一个假的零 —— 因为它看的是错的性质」,处置写成一句可执行的:**拿一个【同一机制】的已知正例去试那个检出器,不要拿一个相似的**;并记下后来是怎么收场的。 |

### ★ T3 要的那一段:**为什么 `SourcePicker.tsx` 归 INPUT-2b,尽管它渲染在一条 INPUT-3 路由上**

**这一族的归属是 Tim 按【页面子树】划的:一个文件归哪一刀,看它住在谁的目录里。**
`app/tools/pricing/metal-prices/SourcePicker.tsx` 住在 `app/tools/pricing/metal-prices/` 下,
而 INPUT-3 拿走的是**那 14 条具名路由**,其中与它最近的一条是 `/tools/pricing/metal-prices/**bulk**`
—— 也就是 `app/tools/pricing/metal-prices/bulk/`,**`SourcePicker.tsx` 不在那个子树里**(它在上一级),
所以按归属规则它归 INPUT-2b,而它自己的宿主页 `/tools/pricing/metal-prices/new` 也确实是 INPUT-2b 的路由。
★ **它同时【渲染在】 `/tools/pricing/metal-prices/bulk` 上,而链条是:**
`app/tools/pricing/metal-prices/bulk/page.tsx` → `<BulkPricesForm>`(`bulk/BulkPricesForm.tsx`)
→ `<SourcePicker>` —— 一条**真的被当成 JSX 画出来**的 import 边。
☞ **于是「归 INPUT-2b」与「会改 INPUT-3 的屏幕」这两句话同时成立,而它们不冲突是运气、冲突是结构。**
INPUT-2b 在**动手之前**跟着这类边做了一次闭包,量到后果**很窄**:
**8 个成员**(desktop 4 + phone 4)· **整页溢出 0 条变化** · **基线表 0 张变化** · 其余 13 条 INPUT-3 路由**一个成员都没变**。
**Tim 2026-09-11 的 T3 据此裁定:这不是范围泄漏,保留;而规则本身已写进 forward-queue 给 INPUT-3。**

---

## R3-7 · §7 —— 闸门 · 提交 · 推送 · 部署 · 残留

### 7.1 `node scripts/check-i18n.mjs` —— **缺键 0 / 加键 0 / 删键 0**

```
I18N_OWN_EXIT=0
✓ 代码引用的每一个键(含可枚举的动态键)en 与 zh 都在。
```

| 要报的三个数 | 读数 | 怎么量的 |
|---|---|---|
| **缺键** | ★ **0** | 脚本自己那一行「✓ 代码引用的每一个键 en 与 zh 都在」;退 0 |
| **加键** | ★ **0** | ★ **量出来的,不是声称的**:`git status --porcelain messages/ lib/i18n/` → **空**,`git diff --stat -- messages/ lib/i18n/` → **无输出** |
| **删键** | ★ **0** | 同上,同一次测量 |

☞ 另有 **156 个「定义了但未见引用」的键** —— 脚本明写「报告,不视为失败」,
且本刀**没有删掉任何一个 `t()` 调用**。扫到的调用形状:静态 7166 · 动态前缀 337(去重 167)·
变量 129 · 键样字面量 7563。

### 7.2 `npm run build` —— **全绿**

```
BUILD_OWN_EXIT=0        ← 34 秒(19:14:14 → 19:14:48)
✓ Compiled successfully in 6.5s
✓ Generating static pages using 17 workers (161/161) in 162ms
```

| | |
|---|---|
| **24 道静态闸** | ★ **全部通过**(currency-literals · error-swallowing · i18n · cjk-rendered · bilingual-concat · masked-reads · masked-columns · auth-error-swallowing · near-duplicate · permission-predicate · pdf-font-stack · datatable-phone · datatable-footer · base-isolation · component-library · nav-routes · reminder-arms · org-tree · pmap · enum-mirrors · confirm-subject · instrument-selfproof · lint,外加 gen-deep-routes) |
| ★ **eslint 冻结闸** | ★ **基线 error 42 · warning 88;实跑 error 42 · warning 87** → 「**✓ 没有新增的 eslint 问题**」。<br>★ 少掉的那一个 warning 在 `app/hr/employees/EmployeeForm.tsx`(`@typescript-eslint/no-unused-vars` 1→0)—— **那是 INPUT-2 删掉那行死 `DecimalInput` import 带来的**,不是本轮 |
| ★ **check-instrument-selfproof 的量具计数** | ★ **36 支量具都写了瞄准线;其中 23 支(构建链里的,含它自己)都带着覆盖断言** |

### 7.3 `node scripts/smoke-routes.mjs`(**不带 `--reach`**)—— ★★ 自 2026-09-08 以来【第一次全绿】★★

```
== 229 routes + 1 reviewer-view check + 2 query-string probes + 2 probation-entry probes
   + 2 customer-page entry probes + 2 cash-forecast probes + 3 claim probes
   + 3 attendance probes + 3 WHT probes + 4 pack/GL-export probes
   + 1 overlap-entry probe + 1 retention-panel probe + 1 signed-out /login probe
   : 248 ok, 6 skipped (no data), 0 FAILED
SMOKE_OWN_EXIT=0        ← ★ 377 秒(19:16:23 → 19:22:40)
```

| | |
|---|---|
| ★ **这是【转换之后】的一次整跑** | ROUND 2 那次是**改冒烟脚本之后、转换之前**跑的,而且退 **1**(三处红,全部先于本刀)。<br>★ **本轮是 124 个 `app/` 文件都改完之后跑的,退 0** —— ROUND 2 交回报告里那句「**这是这份报告里最大的一块空白**」到此填上了。 |
| **失败** | ★ **0** |
| **跳过** | **6**(全部是 `EXPECTED_SKIPS` 里在册的「那张表今天没有数据」:`management_packs` ×2 · `customer_statements` · `attendance_periods` · `assay_results` · `commission_agreements`)。★ **跳过清单没有漂移** —— ROUND 2 逼着收编的 `/hr/claims/[id]` 与 `/hr/leave/[id]` 这次**正常跑过**。 |
| **时延** | 计时 223 条 · 合计 **303.1s** · 中位数 **1206 ms**;最慢 `/contracts` 6834 ms(含按需编译,不是生产时延) |
| ⚠ **它顺带报的一件事(不是失败)** | **滞留的临时行 6 条**:`materials/ZZ-SMOKE-PROBE`(846.4h)· `materials/ZZ-SMOKE-M25`(846.4h)· `materials/ZZ-SMOKE-NTF`(679.1h)· `suppliers/ZZ-SMOKE-S25`(846.4h)· `customers/ZZ-SMOKE-CJK`(204.0h)· `inbound_batches/ZZ-SMOKE-IB25`(846.4h)。<br>★ **一条都不是本刀的**(最年轻的 204 小时 = 8.5 天前);其中 5 条**仍被真单据引用**,脚本自己写着「本检查只报告,不删除」。**照直报出来,不处置。** |

### ★ 7.3b 那条断言、那次请求写了什么,以及【两跑逐字对上】

| | |
|---|---|
| **断言** | `EXPECTED['/verify/cod/[token]'] = [404]` —— ★ **精确,不接受 429**(Q5)。<br>令牌是一枚**现造的随机 UUID**,并且**只读地证明它匹配不到任何一张证书**(`certificates_of_destruction?...verification_token=eq.<uuid>` 必须回 0 行,最多重试 5 次)。<br>正文还要出现 `renderNotFound()` 真的画出来的两句话:`Certificate not found` 与 `No certificate matches this verification link.` |
| **结果** | ★ **它不在失败清单里,也不在跳过清单里 → 它过了。** |
| ★ **它写了什么(实测,不是预测)** | 跑前 `cod_verification_failures` = **1 行**,时间戳 `2026-09-10T23:46:33.172736+08:00`(★ **正是 ROUND 2 首跑插的那一行**,早已过了 10 分钟窗口)<br>→ 这一次调用 **删掉那 1 行、插入 1 行**<br>→ 跑后 = ★ **1 行**,时间戳 `2026-09-11T03:21:58.908002+08:00`(**就是这一次跑的那一刻**) |
| ★ **跑后的行数** | ★ **1**(`content-range: 0-0/1`,service_role + `Prefer: count=exact`) |
| **业务数据** | ★ **零** —— 没有证书、没有单据、没有账号、没有员工 |
| ★ **两跑对上了同一条式子** | 首跑 4 → 1,第二跑 1 → 1。**跑后恒为 1 行,而那一行永远是这一次插的。**<br>☞ 它同时证明请求**真的到达了数据库函数** —— 404 不是路由没匹配上,而是 `renderNotFound()` 真的被画了出来。 |
| 登记 | `docs/known-issues.md` 的 `SMOKE-PREFLIGHT-COD-TOKEN`(已关闭)那一条,**本轮加了「2026-09-11 第二跑实测」一行**,并在条目开头写明「复核:这一条仍然是关的」。 |

### 7.4 `db/gate.py` —— **四条判词全绿,推送【之前】跑的**

**跑法照仓库的机制,不是手写 until 循环:**
`db/run_detached.sh --log /tmp/input2b-r3/gate.log --label "db/gate.py(INPUT-2b ROUND 3,推送前)" --timeout 2700 -- python3 db/gate.py`

**四条判词,逐字抄下来:**

```
== 三个判词(wall-clock 135s)
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
   判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
RUN_EXIT=0
```

| | |
|---|---|
| ★ **退出码** | ★ **`RUN_EXIT=0`** —— 这一行是 `db/gate.py` **自己打出来的**,不是启动器的(那正是 `run_detached.sh` 存在的理由) |
| **fixture 数** | ★ **197 支,全部 ✓** |
| **不变量(两侧都查)** | live 与 rebuild 各自 `B1 anon-executable: 0` · `B2 definer-unchecked-and-callable: 0`;白名单 B1 1 / B2 6 |
| **重建 vs 线上** | ★ **`NO DIFFERENCES — the rebuild matches live ✓`** |
| **匿名面** | anon 够得着:关系 326 · 函数 **1**(`cod_verification(text)`,逐个点名)· 公开桶 0 · 列级 ACL 0 |
| ★ **本刀零迁移** | `db/` **一个文件都没动**(`git status` 可核)—— 跑它是**推送前的例行闸**,不是因为改了库 |
| 时长 | **135 秒**(wall-clock,gate 自己报的);`--timeout 2700` 是照 INPUT-2 实测的 ~403 秒加余量定的,**没有贴着成本设上限** |

### 7.5–7.9 —— 提交 · 推送 · 部署 · 残留

### 7.5 提交 —— **工作与交回报告【同一个提交】**

| | |
|---|---|
| ★ **工作提交** | ★ **`f4290c175561ea9a782a3124d5ab48f24ca9cbf7`** —— **130 个文件,+2932 / −485** |
| 暂存方式 | ★ **按显式路径** —— 先 `git status --porcelain` 逐条看过,再 `git add` 那 124 个 `app/` 文件(从 status 里抽出来的清单)+ `AGENTS.md` + 四份 docs + `scripts/smoke-routes.mjs` |
| ★ **范围核对(暂存之后)** | ★ **暂存了 130 条;`git diff --cached --name-only` 里【没有一条】落在 `app/` · `scripts/` · `docs/` · `AGENTS.md` 之外;暂存之后工作区【没有剩下任何未暂存的改动】** |
| 提交里有什么 | 124 个 `app/`(ROUND 2 的转换 + ROUND 3 的两个 `flex-wrap`)· `docs/handbacks/INPUT-2b.md`(**新建**)· `docs/variant-c-spec.md` · `docs/forward-queue.md` · `docs/known-issues.md` · `AGENTS.md` · `scripts/smoke-routes.mjs` |
| ★ **零迁移** | `db/` **一个文件都没动** |
| 退出码 | ★ `COMMIT_OWN_EXIT=0`;提交后 `git status --porcelain` **空** |

### 7.6 推送 —— **三方 40 位全等**

```
3b02163..f4290c1  main -> main        PUSH_OWN_EXIT=0
```

| `git fetch` 之后 | 值 |
|---|---|
| `git rev-parse HEAD` | `f4290c175561ea9a782a3124d5ab48f24ca9cbf7` |
| `git rev-parse origin/main` | `f4290c175561ea9a782a3124d5ab48f24ca9cbf7` |
| `git ls-remote origin refs/heads/main` | `f4290c175561ea9a782a3124d5ab48f24ca9cbf7` |
| ★ 判定 | ★ **三者全等,长度 40** |

### 7.7 部署 —— **`state=success`,而且【先绑 id→sha,再问状态】**

| | |
|---|---|
| 等法 | ★ `db/wait_for.sh --timeout 900 --label "Production deployment 登记 for f4290c17…" --interval 10`(**有上限、会报名字**,不是手写 until 循环)|
| 等了多久 | ★ **162 秒**(`✓ 等到了:…(162s)`,`WAITFOR_OWN_EXIT=0`)|
| ★ **① 先把 id 绑到 sha 上** | `id=6379525731` · `sha=f4290c175561ea9a782a3124d5ab48f24ca9cbf7` · `environment=Production` · `created_at=2026-09-10T19:31:00Z` —— ★ **是【这个】SHA 的,不是上一个** |
| ★ **② 只有绑定之后才问状态** | ★ **`state=success`**,`created_at=2026-09-10T19:31:01Z` |
| ★ **状态记录数** | ★ **1** |
| **破窗** | ★ **不适用 —— 本刀零迁移**,不存在「旧代码 + 新库」那个窗口 |

### 7.8 残留 —— 逐格,连判据一起

| 项 | 判据(说清楚查的是什么) | 结果 |
|---|---|---|
| ★ **一次性账号** | ★ 拉线上**全部**账号(6 个),逐个匹配 **五种式样**:`smoke-*@test.local` · `input2b-*@test.local` · `input2b-d-*@test.local` · ★ `input2b-r3-*@test.local`(**本轮探针自己的前缀**)· 以及**任何** `@test.local` | ★ **五种全部 0 个** |
| ★ **幽灵授权** | `user_roles` 的 `user_id` 去重后,逐个与现存账号求差 | `user_roles` **8 行 / 6 个不同 user_id**;★ **幽灵授权 0 条** |
| ★ **`.ephemeral/`** | `ls -la` | ★ **空**(`EPHEMERAL_COUNT=0`) |
| ★ **`reap-ephemeral`** | ★ **真的跑了一遍**,不是「量成 0 就当跑过」 | ★ `REAP_OWN_EXIT=0` —— 「✓ 没有滞留的清理计划(`.ephemeral/` 是空的)」 |
| ★ **本刀自己的端口** | 逐个 `lsof -ti tcp:` | ★ **五个全空**:3196(survey)· 3199(冒烟)· 3213(修复探针 / probe2)· CDP 9335 · CDP 9353 |
| ★ **孤儿 headless chrome** | `pgrep -fl "chrome-headless-shell\|next dev\|survey-controls\|smoke-routes\|probe2\|repair-probe"` | ★ **一个都没有** —— ☞ **所以「先证明 ppid=1 + CDP 端口无人连 + 没有探针在跑,再动手」那三条判据【没有用上】:没有东西要处置。一个信号都没有发。** |
| **`cod_verification_failures`** | service_role + `Prefer: count=exact` | ★ **1 行**,时间戳 `2026-09-11T03:21:58.908002+08:00` —— 正是本轮冒烟插的那一行。**它 10 分钟后由下一次调用自己删掉**,表封顶 30 行 |
| ⚠ **不是本刀的残留,但看见了就报** | 冒烟的临时行体检 | **6 条滞留的 `ZZ-SMOKE-*` 业务行**(materials ×3 · suppliers · customers · inbound_batches),**年龄 204 – 846 小时** —— ★ **一条都不是本刀的**;其中 5 条**仍被真单据引用**,脚本自己写着「本检查只报告,不删除」。**照直报出来,不处置。** |

### 7.9 收尾提交(docs-only)

| | |
|---|---|
| 它做什么 | 把 §7.7 与 §7.8 这两节(部署与残留)填进本文件 —— 它们的读数在工作提交**之后**才存在 |
| 它动什么 | ★ **只动 `docs/handbacks/INPUT-2b.md` 一个文件**,`app/` 一个字节都没有 |
| 提交 / 推送 / 三方核对 | 见本节末尾那一行(与 §7.6 同一套判据) |


---

## R3-12 · ROUND 2 那四件,逐条复核【在不在】

> **委托书 §8:「没有被提到的算 NOT DONE」。所以下面不是指路,是把话再说一遍。**

| 要确认的 | 在不在 | 内容(复述,不是指路) |
|---|---|---|
| ★ **`RoleForm.tsx:85` 是哪一种** | ★ **在**(ROUND 2 §6,本轮复核源码) | ★ **是 `disabled`,不是 `readOnly`。** 源码 `disabled={!isNew}`,而那一支 class 恰好在 `!isNew` 时才加 —— **两者永远同时成立**。照 Q10 第一支:**剥 `bg-gray-100`(模块的 `disabled:bg-input/50` 接管)、留 `text-gray-500`**。本轮复核:`grep -c 'disabled={!isNew}' app/settings/roles/RoleForm.tsx` = **1**,`readOnly` = **0**。 |
| ★ **同屏新旧两种控件的页面** | ★ **在**(ROUND 2 §14 + `docs/forward-queue.md`) | ★ **6 条路由**,不是第一版算的 66 条:<br>`/inbound/[id]/edit`(转了 20)· `/output/[id]/edit`(9)· `/tools/pricing/metal-prices/bulk`(5)· `/purchasing/orders/[id]`(4)· `/tools/pricing/formulas/[id]/edit`(2)· `/tools/pricing/formulas/new`(1)。<br>判据:那条路由的子树里既有本刀转过的站点,又有**真的渲染得出来**的 INPUT-3 控件。第一版按「用了 `<DataTable>`」算,而其中 60 条上那三个勾选框**根本没有渲染**(全仓库只有 `CostSettlePanel.tsx:119/:145` 传了 `selection=`)。 |
| ★ **队列里还开着的外观条目 —— 按钮尺寸统一 / 卡片样式在不在** | ★ **在**(ROUND 2 §15 + 文末附录全文) | ★ **按钮尺寸统一:在队列里(`docs/variant-c-spec.md` §5),而且【已经做完了】** —— STYLE-2,2026-09-09,248 个调用点转成 `default`,实测 `sm` 31 颗 28px → **0**,`default` 26 → 57 颗**全部 32px**。**它剩下的那一件是 `<DataTable>` 自己的 15 个裸 `<button>`(20px×8 · 28px×5 · 30px×2),没有任何一刀领。**<br>★ **卡片样式:在队列里(§4.4 + §7.2 + §9 Q8),而【一刀都没有排】** —— 值已经量到(圆角 12px · 内边距 16px · 白底 · `shadow-md` · 边缘是 1px `ring`),施工没有;而 §7.2 那个坑还在:C 的 `card` 写着 `border-[color:var(--brand-border)]` 而实测 **`border-width: 0px`**。 |
| ★ **`/logistics/lanes` 改前改后** | ★ **在**(ROUND 2 §4.3 / `docs/variant-c-spec.md` §4.1a) | ★ 拿掉 INPUT-2 加的三个宽度类(`w-40 md:w-42` / `w-34 md:w-40` ×2),给那两张 `flex items-end gap-2 …` 的 `<form>` 加 **`flex-wrap`**:<br>**390px 整页溢出 +4 → 0**(★ 本轮整跑复核:**仍然是 0**)· **1440px 0 → 0**;`code`(`w-28`)112 → **112 逐字未变** · `name` 160 → **188** · 两颗下拉 136 → **172**;<br>★ 两颗下拉的「SG Singapore」**现在装得下了**(内容宽 136 → 172,判据要 117.7)。 |

---

## R3-13 · 按控件类型:本刀转了 / 留给 INPUT-3 / 按裁定不动 / 未测量

> ★ **这张表的数来自 ROUND 2 的逐字符全树扫描**(947 个开标签,遮罩注释后 **927** 个);
> **ROUND 3 没有重扫**(本轮一个控件都没有增减,只加了两个 `flex-wrap`)。标注在此,不冒充新读数。

| 控件类型 | INPUT-2 已接模块 | ★ **INPUT-2b(本刀)** | INPUT-3 | R4-E6 触控 | R4-Q11 hidden | R4-Q13 | 合计 |
|---|--:|--:|--:|--:|--:|--:|--:|
| `select` | 44 | ★ **129** | 79 | 4 | 0 | 0 | **256** |
| `input.text` | 72 | ★ **122** | 58 | 1 | 0 | 0 | **253** |
| `input.date` | 22 | ★ **78** | 27 | 1 | 0 | 1 | **129** |
| `input.number` | 14 | ★ **48** | 21 | 4 | 0 | 0 | **87** |
| `textarea` | 13 | ★ **27** | 13 | 1 | 0 | 0 | **54** |
| `input.checkbox` | 16 | ★ **13** | 19 | 0 | 0 | 0 | **48** |
| `input.radio` | 2 | **0** | 15 | 0 | 0 | 0 | **17** |
| `input.file` | 0 | ★ **6** | 2 | 0 | 0 | 0 | **8** |
| `input.search` | 0 | ★ **6** | 1 | 0 | 0 | 0 | **7** |
| `input.month` | 0 | ★ **4** | 1 | 0 | 0 | 0 | **5** |
| `input.datetime-local` | 2 | ★ **2** | 0 | 0 | 0 | 0 | **4** |
| `input.email` | 1 | 0 | 0 | 0 | 0 | 0 | **1** |
| `input.EXPR`(type 是表达式) | 1 | 0 | 0 | 0 | 0 | 0 | **1** |
| `type="hidden"` | 0 | **0**(其中 **17** 个是本刀名下的,Q11 裁定不动) | 0 | 0 | 57 | 0 | **57** |
| **合计** | **187** | ★★ **435** | **236** | **11** | **57** | **1** | **927** |

**按裁定【不动】的,逐条:**

| 裁定 | 对象 | 数 |
|---|---|--:|
| **R4 / E1** | `/login` | **1** |
| **R4 / E6** | 收货与盘点两页的触控档 | **11** |
| **R4 / Q13** | `ExpectedDateControl.tsx`(琥珀色虚线 =「这个日期是估的」) | **1** |
| **R4 / Q11** | `type="hidden"`(本刀名下 17 / 全树 57) | **17** |
| **Q9** | 渲染 `<DecimalInput>` 的 23 个文件 / 52 个调用点 | **196** |
| **每一个 `<label>`** | R13:归【字体/排版】那一刀 | 426 个渲染 |
| **每一颗按钮** | 不在控件这一族 | — |

★ **接到哪几条常量:** `CONTROL_INPUT` **260** · `CONTROL_SELECT` **129** ·
`CONTROL_TEXTAREA` **27** · `CONTROL_CHECKBOX` **13** · `CONTROL_FILE_BUTTON` **6**。

---

## R3-14 · Tim 该去哪儿看 —— 路由 · 视口 · 每一页要的权限

> ★ **这一次它【已经上线了】** —— 见 §R3-7.7 的部署读数。下面每一条在生产上就能看。

### ① 先看这两条 —— 它们是 ROUND 2 停手的原因,也是 ROUND 3 修好的东西

| 路由 | 视口 | 看什么 | 权限 |
|---|---|---|---|
| ★ **`/hr/attendance`** | ★ **390px** | 顶上那一行「开启月份」:**月份框 191px(原 168),而那一行现在会换行** —— 那句灰色提示语掉到了第二行,**整页右边不再多出 14px**。<br>☞ 顺手对照 **1440px**:桌面那一行**装得下,所以看不出任何变化**(逐字未变) | `module.hr.view` + `module.hr.edit` |
| ★ **`/sales/orders/new`** | ★ **390px** | 明细区那 5 行:**每一行现在是两层** —— 物料下拉独占一行(364px),数量 + 单价在它下面。<br>整页溢出 **205(改前)→ 262(ROUND 2)→ 6**。<br>★ **那 6px 是下拉右边缘探出去的**:横向拖一下能看见。**它在验收线以内,是刻意留下的** —— 消掉它要把下拉压到 70px(见 §R3-4.3) | `module.sales.edit` |

### ② 再看这一条 —— 同一招的第一处落点

| 路由 | 视口 | 看什么 | 权限 |
|---|---|---|---|
| ★ `/logistics/lanes` | **390px 与 1440px** | 顶上两张表单**会换行**;390px 整页溢出 **+4 → 0**;两颗下拉的「SG Singapore」**装得下了**。桌面那一档**逐字未变** | `module.purchasing.edit`(那两张表单在 `PermissionGate` 里) |

### ③ 抽查转换效果(每类挑一条,都在首屏)

| 路由 | 视口 | 看什么 | 权限 |
|---|---|---|---|
| `/settings/import` | 两个 | ★ **文件选择钮**(`CONTROL_FILE_BUTTON` 的**第一批消费者**):#007FAD 底 · 白字 · 高 32 · 圆角 8;旁边那颗表下拉 | `module.settings.view` |
| `/hr/leave` | 390px | 那 3 个勾选框(16×16 · 圆角 4px · 未选中 `#62738C` 边)+ 筛选下拉 | `module.hr.view` |
| `/finance/payroll-payments` | 两个 | ★ **Q8 那一处**:日期框留空时**同时**有 `border-red-400` + `bg-red-50` + 模块的 `aria-invalid` 边框 —— **两条错误样式叠在一起**(已登记,本刀没有调和) | `module.finance.edit` |
| `/tools/converter` | 390px | 「as received → dry」那颗下拉 —— **差 0.24px 装不下**(正好装满,不是被截) | 无(工具页) |
| ★ `/tools/pricing/metal-prices/new` | ★ **390px** | ★ **唯一一颗真被截了尾巴的下拉**:「— only for a published-index quote —」。<br>★ **它有宽度类,所以本刀没有动它** —— Tim 的 T4 把它登记给了**字体/排版**那一刀 | `module.pricing.edit` |
| `/hr/employees/new` | 两个 | 宽度变化最多的一条 | `module.hr.edit` |

### ④ 量具走不到、只有人能看的(§R3-5.6 那一批里最值钱的几处)

| 路由 | 看什么 | 权限 |
|---|---|---|
| `/suppliers/[id]/edit` | ★ **24 个站点,本刀最大的一处未测量** | `module.purchasing.edit` |
| `/finance/assets/[id]` | 22 个站点 | `module.finance.view` |
| `/inbound/[id]/edit` | 17 个站点,**而且它同屏有 4 个 `<DecimalInput>`(新旧两种样子)** | `module.inbound.edit` |
| `/settings/accounts` | ★ 点「编辑」才出现的 **8 个**站点 —— **两支量具都走不到** | `module.settings.edit` |
| `/settings/roles/[id]` | `PermissionMatrix` 那 29 个格子里的勾选框(INPUT-2 留了读数:行高 37 → 38px) | `module.settings.edit` |

---

## R3-15 · 每一步的实测时长与【它自己的】退出码

> **规矩:包装脚本的退出码不是被包住那一支的退出码。** 下面每一行的退出码都是
> **被跑的那支脚本自己打出来的**(`X_OWN_EXIT=` 写在紧跟着命令的那一行)。

| 步 | 命令 | 起(UTC) | 止 | 秒 | 退出码 |
|---|---|---|---|--:|---|
| §1.1/1.2 开工闸 | `git rev-parse HEAD` · `git rev-parse origin/main` · `git status --porcelain` | 18:43:25 | 18:43:34 | **9** | 0 |
| §1.3 四件产物 | `test -e` × 4 + 字节数 | 18:43:43 | 18:43:43 | **<1** | 0 |
| §1.4 安全副本 | `git diff > tree-before.patch` + 逐个复制未跟踪文件 | 18:43:52 | 18:43:52 | **<1** | ★ `DIFF_EXIT=0` · `LSFILES_EXIT=0` · `COPY_EXIT=0` |
| §1.5 通读 | 交回报告 · 停止闸 · spec 七节 · forward-queue 两节 · known-issues · AGENTS 三节 · `control-style.ts` · 三支量具抬头 | 18:43:57 | 18:47:50 | **233** | — |
| ★ §4.1 改前读数 | `repair-probe.mjs`(2 路由 × 2 视口) | 18:47:56 | 18:48:15 | ★ **19** | ★ `REPAIRPROBE_OWN_EXIT=0` |
| T1 的 import 追踪 | `who-renders.mjs`(枚举 200 条路由的渲染闭包) | 18:48:31 | 18:48:31 | **<1** | ★ `WHORENDERS_OWN_EXIT=0` |
| ★ §4.2 加两个 `flex-wrap` | python 就地改写,两处各断言「恰好命中 1 次」 | 18:49:37 | 18:49:37 | **<1** | ★ `PATCH_OWN_EXIT=0` |
| ★ §4.3 (i) 之后重量 | `repair-probe.mjs` | 18:49:44 | 18:50:04 | ★ **20** | ★ `REPAIRPROBE_OWN_EXIT=0` |
| ★ (ii) 实验:加 `min-w-0` | python 就地改写 + 重量 | 18:50:38 | 18:51:06 | ★ **28** | ★ `PATCH2_OWN_EXIT=0` · `REPAIRPROBE_OWN_EXIT=0` |
| ★ (ii) 撤回 | python 就地改写 | 18:52:02 | 18:52:02 | **<1** | ★ `REVERT_OWN_EXIT=0` |
| ★ §4.3 最终重量 | `repair-probe.mjs` | 18:52:09 | 18:52:27 | ★ **18** | ★ `REPAIRPROBE_OWN_EXIT=0` |
| ★ 「只动了两行」的证明 | 从安全副本重建 ROUND 2 状态 + `diff -u` | 18:58:37 | 18:58:37 | **<1** | `ARCHIVE_EXIT=0` · `APPLY_EXIT=0` |
| §4.4 `tsc --noEmit` | 删 tsbuildinfo 后整跑 | 18:52:28 | 18:52:38 | **10** | ★ `TSC_OWN_EXIT=0`(输出 **0 行**) |
| ★ §5.1 `--mode=drift` 整跑 | 141 条 × 2 视口 | 18:52:49 | 19:04:56 | ★ **727** | ★ `DRIFT_OWN_EXIT=0` |
| §5.1 `--mode=edit` | 4 条静态路由 × 2 视口 | 19:05:05 | 19:07:02 | **117** | ★ `EDIT_OWN_EXIT=0` |
| ★ §5.4/5.5 判据探针 | `probe2.mjs`(58 × 2 视口 + lanes ×2 + 7 张截图) | 19:07:16 | 19:12:20 | ★ **304** | ★ `PROBE2_OWN_EXIT=0` |
| §5.1 单条补量 | `--only=/purchasing,/finance/fx/bulk` | 19:12:24 | 19:13:49 | **85** | ★ `REPAIR_OWN_EXIT=0` |
| §5.4/5.5/5.6 判据 | `judge.mjs` | 19:12:44 | 19:12:44 | **<1** | ★ `JUDGE_OWN_EXIT=0` |
| §5.2 并入 + 三条比对 + 宽度报告 | `after-checks.sh` | 19:13:51 | 19:13:52 | **1** | 见 §R3-5.2 的五个 `_OWN_EXIT` |
| §5.3 R6 判定 | `r6.mjs`(对着本刀自己的改前读数) | 19:14:04 | 19:14:04 | **<1** | ★ `R6_OWN_EXIT=0` |
| §7.1 `check-i18n.mjs` | 单独跑 | 19:00:06 | 19:00:06 | **<1** | ★ `I18N_OWN_EXIT=0` |
| ★ §7.2 `npm run build` | 24 道静态闸 + `next build` | 19:14:14 | 19:14:48 | ★ **34** | ★ `BUILD_OWN_EXIT=0` |
| ★ §7.3 **冒烟整跑** | `node scripts/smoke-routes.mjs`(不带 `--reach`) | 19:16:23 | 19:22:40 | ★ **377** | ★ `SMOKE_OWN_EXIT=0` |
| ★ §7.4 `db/gate.py` | 经 `db/run_detached.sh --timeout 2700` | 19:23:08 | 19:26:0x | ★ **135**(gate 自报的 wall-clock) | ★ `RUN_EXIT=0` |
| §7.5 组装 + 暂存 + 提交 | `assemble.sh` · `git add <显式路径>` · `git commit -F` | 19:27:19 | 19:27:34 | **15** | ★ `COMMIT_OWN_EXIT=0` |
| §7.6 推送 + 三方核对 | `git push` · `git fetch` · `git rev-parse` ×2 · `git ls-remote` | 19:28:02 | 19:28:06 | **4** | ★ `PUSH_OWN_EXIT=0` · `FETCH_EXIT=0` |
| ★ §7.7 等部署登记 | `db/wait_for.sh --timeout 900 --interval 10` | 19:28:25 | 19:31:07 | ★ **162** | ★ `WAITFOR_OWN_EXIT=0` |
| §7.7 绑 id→sha,再问状态 | `gh api deployments` → `gh api .../statuses` | 19:31:18 | 19:31:20 | **2** | ★ `GH_DEPLOY_EXIT=0` · `GH_STATUS_EXIT=0` |
| §7.8 残留 | `residue.sh`(账号 · 幽灵授权 · `.ephemeral/` · reap · 端口 · 进程 · cod) | 19:31:27 | 19:31:31 | **4** | ★ `ACCOUNTS_OWN_EXIT=0` · `GHOSTS_OWN_EXIT=0` · `REAP_OWN_EXIT=0` |
| ★ **本轮合计(开工闸 → 残留查完)** | | **18:43:25** | **19:31:31** | ★ **2886 秒 ≈ 48 分钟** | |

★ **一处必须照直说的时长差:** 委托书引的 ROUND 2 实测是「冒烟 **871** 秒 · drift **1669** 秒」,
**本轮同一支脚本、同一棵树实测 377 与 727** —— **各差 2.3 倍**。
差别在 `.next` 是不是热的(本轮跑 drift 之前已经有过好几轮 `next dev`,跑冒烟之前刚做完 `npm run build`)。
☞ **给 INPUT-3 估价要用【冷】的那一对(871 / 1669),不是本轮这一对。**
**一个"更快"的实测数,在估价这件事上比一个偏高的数更危险。**

---

## R3-16 · 我不能核实的

* ★ **别的浏览器。** 20.3px 的箭头保留区、整套 select 判据、`min-w-0` 那次实测、以及本刀**所有**几何读数,
  **只在 `chrome-headless-shell 152.0.7977.54` 上量过。** 别的浏览器一次都没有验证。
* ★ **20.3px 本轮【没有重量】。** 它是 ROUND 1 在同一棵树、同一支 chrome 上量的
  (5 配置 × 2 视口,20.21–20.31px),ROUND 2 与 ROUND 3 都直接采用。**它是 select 判据的地基。**
* ★ **首屏量不到的那一批站点**(§R3-5.6)。它们**改对没改对,没有任何读数支持** ——
  只有 `tsc` 干净、eslint 没新增、`npm run build` 绿、以及 ROUND 2 那次归一化比对
  (它证明的是"只改了 className",不是"改对了")。
* ★ **E6 那一档这一轮仍然没有被考验过** —— 那两页(`/inbound/receive` · `/stocktakes/*`)不在本刀这 58 条路由里。
* ★ **`/settings/accounts` 的 8 个站点**藏在「编辑」开关后面,`--mode=drift` 与 `--mode=edit` **都量不到**。
* ★ **真人的手。** 全部结论来自 CDP 读数,**没有人真的用手机点过那两条修好的路由。**
* ★ **`/purchasing` @ phone 在整跑里卡死了渲染器**,那一条的读数来自一次**单条补量**(见 §R3-5.1)。
  ☞ 同一个失效模式 ROUND 2 出现在 `/finance/freight/new` 上 —— **它换了一条路由,而不是消失了。**
* ★ **那 6px。** `/sales/orders/new` 在 390px 上仍然有 **6px** 的整页横向溢出(下拉右边缘 396 / 视口 390)。
  它在验收线以内(≤205),而**它没有被消掉** —— 消掉它的唯一授权手段(`min-w-0`)的代价见 §R3-4.3。
  **一个操作员在那一页上仍然可以横向拖动 6px。**

---

## R3-17 · ★ 本块中我量过、并发现【为假】的断言(AGENTS.md 的必填节)

> **规矩:闸轮的产出里必须有一节叫「本块中我量过并发现为假的断言」,空着也要写"零条"。
> 本轮【不是零条】—— 三条。**

| # | 断言 | 它写在哪 | 实测 |
|---|---|---|---|
| ★ **1** | **T2 的 (ii):「一颗原生 `<select>` 压不到【最长那条 option + 内边距 + 箭头保留区】以下,所以长的选项文字可能被截」** | ★ **委托书 §3 的 T1(ii)** | ★★ **假。** 给那颗 `flex-basis: 0%` 的下拉加 `min-w-0` 之后,它**塌到 70px**(= 行宽 326 − 112 − 128 − 16),**6 个选项全部被截** —— 不是"floor 在最长选项上"。<br>机制:`min-width: 0` 把托底整条撤掉,同时让它的**假想主尺寸变成 0**,于是它**不再逼出换行**。<br>☞ **这条测量是我【没有】采用 (ii) 的全部理由**,而 (i) 单独已经把验收线过掉了。 |
| ★ **2** | 「`/hr/attendance` 那 14px 是那个月份框顶到页面外面的」(原话:「那 23px 里有 14px 顶到了页面外面」) | ★ **ROUND 2 自己的交回报告 §7.1 ①**,以及 `docs/variant-c-spec.md` §4.1a 的更正表 | ★ **假(元素认错了)。** 实测那个月份框的右边缘在 **240px**;真正探到 **403.11px** 的是同一行最后那句 `<p className="text-xs text-gray-500">` 提示语。<br>☞ **月份框仍然是【原因】**(它长了 23px,把后面的东西推了出去),**但它不是【探出页面的那个元素】**。<br>**裁定与修法都不受影响**(元凶那一行是同一行,`flex-wrap` 是同一招),**而读数要照直说。已就地更正两份文档。** |
| ★ **3** | 「`max-w-full` 是 (ii) 的一个可选解药」 | 委托书 §3 的 T1(ii)(「`min-w-0` 和 / 或 `max-w-full`」) | ★ **假(对这一处无效)。** CSS 里 **`min-width` 压过 `max-width`**:`min-width: auto` 仍然把那颗下拉托在 364px 上,`max-width: 100%` 一个像素都改不动。**「和/或」在这一处只剩 `min-w-0` 一个选项。** |

★ **量下来是【对的】那些,逐条列在 §R3-1** —— 包括两条路由的四个溢出读数、两处控件的宽度变化、
435 / 422 / 124 三个计数、12 张基线表、eslint 基线。

---

## R3-18 · INPUT-3 的估价 —— 两个数,分开报

### ① 流程那一半(★ 全部来自 ROUND 3 的实测,除了标注的两项)

| 项 | 秒 | 出处 |
|---|--:|---|
| `--mode=drift` 整跑(141 × 2 视口) | ★ **727** | ★ **ROUND 3 实测**(18:52:49 → 19:04:56,退 0)。⚠ **ROUND 2 同一支量具实测 1669 秒** —— **同一棵树、同一支脚本,两次差 2.3 倍**;差别在 `.next` 是不是热的。**估价要按【冷】的那个数(1669)算,不要按 727。** |
| `--mode=edit` | ★ **117** | ★ ROUND 3 实测(19:05:05 → 19:07:02,退 0)。ROUND 2:153 |
| 单条补量(`/purchasing` + 陪跑) | ★ **85** | ★ ROUND 3 实测(19:12:24 → 19:13:49,退 0) |
| 并入 + 两条 compare + 行高比对器 + 宽度报告 | ★ **1** | ★ ROUND 3 实测(`after-checks.sh`,退出码见 §R3-5.2) |
| R2 / select 判据探针(58 × 2 视口 + lanes ×2 + 截图) | ★ **304** | ★ ROUND 3 实测(19:07:16 → 19:12:20,退 0)。ROUND 2:634 |
| 版式修复那一圈(改前量 + 改 + 量 + (ii) 实验 + 撤 + 再量) | ★ **77** | ★ ROUND 3 实测 —— **四次 2 路由 × 2 视口的探针**(19 + 20 + 20 + 18)。<br>⚠ **这一行与下面 ② 里那 77 秒是【同一批跑】,合计时只算一次。** |
| ★ **冒烟整跑** | ★ **377** | ★ ROUND 3 实测(19:16:23 → 19:22:40,退 0)。ROUND 2:**871**(见下面那条警告) |
| `npm run build` | ★ **34** | ★ ROUND 3 实测(19:14:14 → 19:14:48,退 0)。ROUND 2 **没跑过** |
| `db/gate.py` | ★ **135** | ★ ROUND 3 实测(gate 自报 wall-clock,`RUN_EXIT=0`)。ROUND 2 **没跑过** |
| 部署登记等待 + 绑 id→sha 问状态 | ★ **164**(162 + 2) | ★ ROUND 3 实测(`WAITFOR_OWN_EXIT=0`)。ROUND 2 **没跑过** |
| ★★ **流程合计(ROUND 3 实测,`.next` 是【热】的)** | ★★ **2021 秒 ≈ 34 分钟** | 727 + 117 + 304 + 85 + 1 + 77 + 377 + 34 + 135 + 164 |
| ★★ **流程合计(换成【冷 `.next`】的两个数,给 INPUT-3 估价用)** | ★★★ **3457 秒 ≈ 58 分钟** | 把 drift **727 → 1669**(+942)、冒烟 **377 → 871**(+494)换进去 |

### ② 施工那一半(★ 委托书要的那个算法,连同它为什么骗人)

| 算法 | 结果 |
|---|---|
| **ROUND 2 的转换总时长 ÷ 422** | ★ `convert.mjs` 实测 **< 1 秒 / 427 笔** → **≈ 0.002 秒 / 次编辑** |
| ★ **而这个数【不能用来给 INPUT-3 估价】** | 见下 |

> ### ★★ 照直说:「总转换时间 ÷ 422」是一个【会骗人的数】★★
>
> ROUND 2 的 422 次编辑**不是 422 次人工编辑,是一支脚本的一次运行**(< 1 秒)。
> 拿 0.002 秒/次去给 INPUT-3 估价,会得出「INPUT-3 的施工不要钱」。**那是假的。**
>
> **真正花掉的时间是【判据与量具】,不是打字。** ROUND 2 实测:
> `amend.mjs` ~300 · `convert.mjs` ~900(两轮返工)· `r6d-graph.mjs` ~200 ·
> `probe2.mjs` + `judge.mjs` ~900 · `no-behaviour-change.mjs` ~150 ·
> `width-delta` / `r6` / `merge-repair` / `mixed-pages` ~400 · 三处手改 + lanes ~120
> → ★ **施工合计 ≈ 2970 秒 ≈ 50 分钟**。
>
> ★ **ROUND 3 自己那一半的实测,是一个【更有用】的数**,因为它就是 INPUT-3 会遇到的那种活
> ——「量一次 → 改两行 → 再量一次 → 发现 (ii) 的前提是假的 → 撤回来 → 第三次量」:
>
> | ROUND 3 的施工成本 | 秒 |
> |---|--:|
> | 写 `repair-probe.mjs`(行版式读数:行容器的 `flex-wrap` + 谁探出页面 + 被截的选项) | **~420** |
> | 写 `who-renders.mjs`(反向 import 追踪,200 条路由的渲染闭包) | **~180** |
> | ★ 四次探针跑(改前 · (i) 后 · (ii) 后 · 撤回后) | ★ **77**(改前 19 + (i) 后 20 + (ii) 后 20 + 撤回后 18,**实测**) |
> | 三次改代码(两个 `flex-wrap` + 一次加 `min-w-0` + 一次撤) | **~90** |
> | ★ **ROUND 3 施工合计** | ★ **≈ 767 秒 ≈ 13 分钟** |
>
> ### ☞ 所以给 INPUT-3 的两个数是:
>
> | | |
> |---|---|
> | ★ **流程部分** | ★★ **≈ 58 分钟(3457 秒)** —— 逐项见上面 ① 那张表。<br>★ 本轮**实测**是 **2021 秒 ≈ 34 分钟**,而**估价不能用它**:本轮跑 drift 与冒烟时 `.next` 是热的。<br>★ **换成冷的那两个数(drift 1669、冒烟 871)才是 3457 秒** —— **给 INPUT-3 报价用这一个。** |
> | ★ **施工部分** | ★ **≈ 50 分钟(ROUND 2 的转换)+ ≈ 13 分钟(ROUND 3 的版式修复)** —— 而两半**几乎全部是"写判据与量具"的时间**,不是"改代码"的时间 |
> | ★ **每次编辑的秒数** | ★ **0.002 秒(实测)—— 而它【不可用于估价】。**<br>可用的那两个数是:**【每一类新判据 ≈ 15 分钟】** 与 **【每一处版式修复 ≈ 6 分钟,含三到四次重量】**。 |
>
> ⚠ **INPUT-3 会比本刀贵,而贵在三处本刀没有的东西:**
> ① **行高**(本刀 R6(c) 全干净,而 INPUT-3 那两张表是 81 / 81.5px,`freight` 只差 1px 就溢出);
> ② **`<DecimalInput>` 是一个组件,不是一串 class** —— ROUND 2 那套"改 className"的机器**用不上**;
> ③ ★ **T2 的修复次序会被用到,而它的第 (ii) 步在【表格里面】是禁止的** ——
> INPUT-3 的元凶多半就在 `<table>` 里,那时**只剩停手一条路**。

---

# ⛔ 附录 · ROUND 2 的停止记录(2026-09-10)—— **原样保留,一个字都没改**

> ★ 下面是 ROUND 2 交回时那份报告的**全文**。
> ★ **它里面每一句「没有上线 / `§7` 一步都没做 / 停在闸上」说的是【2026-09-10 那一刻】,
>   ROUND 3 之后已经不成立** —— 本刀的最终状态在本文上半(§R3-*)。
> ★ 保留它不是为了好看:**一份声称完成而实际停手的文档,正是这个仓库反复付账的那个缺陷** ——
>   而它的反面同样要防:**一份修好之后就把停手记录删掉的文档,下一刀读不到那次停手是怎么来的。**

# INPUT-2b · 交回报告 —— 手搓控件的最后一批 inline class 串接上了共享样式模块

> **一句话,屏幕上变了什么:** 本刀名下 **435 个**自己写着一整串 class 的手搓控件
> (文本框 · 下拉 · 日期 · 数字 · 搜索 · 月份 · 日期时间 · 多行框 · 勾选框 · 文件上传)
> **现在都从 `app/components/ui/control-style.ts` 拿样子** —— 32px 高、8px 圆角、
> 1px `#AEBAC9` 边、左内边距 10px、手机 16px / 桌面 14px 字号;
> 元素仍然是原生的,**宽度类一个都没有动**(唯一的例外是 `/logistics/lanes`,Tim 单独裁的);
> 而 `/logistics/lanes` 顶上那两张表单**现在会换行了**。

---

## 0 · 这一刀的坐标

| | |
|---|---|
| 开工前 HEAD | `3b021633b0b1540a89bb827a9c441d3a2aa4c11d` = `origin/main`,树干净(三方 40 位全等已核) |
| 委托书 | INPUT-2b ROUND 2(Tim 已答完停止闸 9/10 的全部 12 问) |
| Round 1 的产物 | `/tmp/INPUT-2b-stopgate.md` · `/tmp/input2b/classification.json` · `scan.mjs` · `probe.mjs` · `.survey-out/input2b-before/{controls-drift-MERGED,controls-edit-baseline}.json` —— **六件全部在位,Step A 没有重跑** |
| 标准 | `docs/variant-c-spec.md`(变体 C 的实测值 + 例外清单) |

---

## 1 · §1.4 —— 委托书里每一个【被我当成阈值用】的数,重量的结果

> **规矩(AGENTS.md):委托书里的数字一个都不许直接引用。**
> 下面每一条都标 **confirmed / wrong / not re-measured**,**包括量下来是对的那些**。

| 委托书里的数 | 我拿它当阈值了吗 | 判定 | 重量的方法与结果 |
|---|---|---|---|
| HEAD `3b02163…` = `origin/main`、树干净 | ★ 是(§1.1 的开工闸) | ★ **confirmed** | `git rev-parse HEAD` · `git rev-parse origin/main` · `git status --porcelain`(空) |
| Round 1 的六件产物都在 | ★ 是(§1.2 的开工闸) | ★ **confirmed** | 逐条 `test -e` + 字节数;全部非空 |
| **435 个站点(414 A / 3 B / 18 C)· 422 次编辑** | ★ 是(它是本刀的施工清单) | ★ **confirmed** | 用 Round 1 的 `scan.mjs` 结果重算了一遍分类与计数:**435 = 414 + 3 + 18**;`419 inline + 3 常量 = 422` —— 逐字相同 |
| **3 个本地常量**(`LeaveForm::field` · `ClaimForm::field` · `SourcePicker::fieldCls`) | ★ 是 | ★ **confirmed**,但**一个常量装不下两种样子** | 三处声明**逐字**命中;而每处覆盖的站点里**同时**有 `<select>` 与 `<input>` → 一次改写产出两条(见 §4) |
| **6 处**文件上传要接 `CONTROL_FILE_BUTTON`(Q7) | ★ 是 | ★ **confirmed** | 分类里 `input.file` = **6**,全部 C 类、全部带 `file:*` 七件套 |
| `RoleForm.tsx:85` 带的是 `disabled` 还是 `readOnly`(Q10) | ★ 是(它决定剥哪一条) | ★ **confirmed:是 `disabled`** | 读源码:`disabled={!isNew}`,而那一支 class 恰好在 `!isNew` 时才加 → **两者永远同时成立**。照 Q10 第一支:剥 `bg-gray-100`,留 `text-gray-500` |
| `/logistics/lanes` 的三处宽度类 `w-40 md:w-42` / `w-34 md:w-40` ×2 | ★ 是(§4.3 要按名字与类串定位) | ★ **confirmed** | 按 `name=` 与类串定位,**三处各命中恰好 1 次**(脚本里 `assert count == 1`) |
| 那两张 `flex items-end gap-2 …` 的 `<form>` | ★ 是 | ★ **confirmed:恰好 2 张** | 按整条类串定位,`assert count == 2` |
| `docs/row-height-baseline.md` 记着 **12 张**有控件的基线表 | ★ 是(R6(c)) | ★ **confirmed** | 比对器自己打印「比过的表:12 / 基线 12 张」 |
| **eslint 冻结基线 42 错 / 88 警** | ★ 是(§7.3) | ★ **confirmed(指提交在册的那份)** | `scripts/lint-baseline.json` → `{"errors":42,"warnings":88}`;实跑 **42 / 87**(见 §7.3) |
| `cod_verification_failures` 今天有 **4 行**、全在 10 分钟窗口外 | ★ 是(Q4 要求写明写了什么) | ★ **confirmed** | service_role + `Prefer: count=exact` → `content-range: 0-3/4`,时间戳全部 `2026-09-08` |
| **20.3px** 的箭头保留区(Round 1 实测,取代 spec 的 ~27px) | ★ 是(§5.5 的判据) | ★ **not re-measured** | ★ **照直说:本轮【没有】重量它。** 它是 Round 1 在同一棵树、同一支 chrome 上量的(5 配置 × 2 视口,20.21–20.31),本轮直接采用 |
| 冒烟整跑 **~1007 秒** | 否(只作估价) | ★ **wrong(偏高)** | 本刀实跑 **871 秒**(229 条路由 + 各类探针) |
| `--mode=drift` 整跑 **1630 秒** | 否(只作估价) | 见 §11 | 本刀实跑见 §11 那张时长表 |
---

## 2 · §3 —— Tim 的 12 条答复,逐条 DONE / NOT DONE

> **规矩(§8):没有被提到的算 NOT DONE;「代码里有」不算 done,「操作员在屏幕上看得见」才算。**

| # | Tim 的答复 | 状态 | 证据 |
|---|---|---|---|
| **Q1** | 用 435(414 A / 3 B / 18 C)· 422 次编辑;并把「为什么 435 ≠ 415」写进 forward-queue | ★ **DONE** | 施工清单就是它:`/tmp/input2b/classification-final.json`,`sitesIn435=435`、`byClass={A:414,B:3,C:18}`、`editsCount=423`(422 + Q10 那一处)。口径表已写进 `docs/forward-queue.md` §「为什么是 435,不是 415」,**四行差异逐条**,并补上了上一版自己承认没查的 A 类假阴性那一格 |
| **Q2** | 开工;R6(a) 的参照点 = **本刀自己的改前读数**;1px 复量规则;另报基线文档一行 | ★ **DONE** | 见 §6 的 R6 逐条。参照点与 1px 规则已写进 `docs/forward-queue.md` §「第 ① 条的【参照点】已修订」,方法上的账写进 `AGENTS.md` §「一份基线文档是一张快照,不是一道闸」 |
| **Q3** | 不查 `/settings/accounts` 那 1px;登记进 known-issues(它在 `<button>` 上、同 HEAD 上量出 36 与 35、原因未定) | ★ **DONE** | `docs/known-issues.md` 新条目 **`SETTINGS-ACCOUNTS-1PX`** —— 六行「查过的 / 读数」逐条,含「元凶是「Edit」按钮、`right=425.08`」「那一页首屏 0 个控件」「15 分钟后复量 35」 |
| **Q4** | 冒烟可以写库;规则改成「不建任何**业务**数据 + 逐字写明写了什么」;写在脚本、known-issues 与交回报告三处 | ★ **DONE** | ① `scripts/smoke-routes.mjs` 的 `EXPECTED` 那一段逐字写着两句 SQL 与预算;② `docs/known-issues.md` 那张「每一次冒烟在这条路由上写什么」表;③ 本报告 §3。**实测:跑前 4 行(全 2026-09-08)→ 跑后 1 行**,与预测逐字一致 |
| **Q5** | 精确断言 `[404]`,不接受 429 | ★ **DONE** | `EXPECTED['/verify/cod/[token]'] = [404]` —— **没有写 `[404,429]`**,旁边写着为什么(一次真限流就该红) |
| **Q6** | `search` / `month` / `datetime-local` 照 `CONTROL_INPUT`;记进 spec §6 | ★ **DONE** | 三种共 **12 个**站点全部接 `CONTROL_INPUT`;`docs/variant-c-spec.md` §6 新增一行,标着「**TIM'S RULING 2026-09-10, INPUT-2b 停止闸 Q6**」与「为什么必须由 Tim 裁而不是由刀推」 |
| **Q7** | 逐条:`--brand-border` 剥 · `file:*` 剥并换 `CONTROL_FILE_BUTTON`(6 处)· `disabled:bg-gray-100` 剥 · `disabled:text-gray-400` 留 · 其它原样留并列出 | ★ **DONE** | 全部照裁。★ **「其它」那一栏是 0 条** —— 13 种 46 处两张清单都没有的 class,Q7 + Q8 **裁完了**,没有一处需要「原样留着并列出来」(见 §5) |
| **Q8** | **总则:一条 class 同时落在两张清单上,【留】赢**;`PayPanel.tsx:66` 的错误分支留 `border-red-400` 与 `bg-red-50`;记进 spec | ★ **DONE** | `docs/variant-c-spec.md` 新增 **§4.1c**,标着 TIM'S RULING 与理由。`PayPanel.tsx` 改写成「模块 always + 错误类 only-when-in-error」:<br>`` className={`${CONTROL_INPUT} block` + (date === '' ? ' border-red-400 bg-red-50' : '')} ``<br>★ 并**照直登记了一处重叠**:那个框同时带 `aria-invalid={date === ''}`,于是模块的 `aria-invalid:border-destructive` 与这两条错误类**同时生效** —— 本刀没有去调和它们(那会是一次样式判断,不是一次转换) |
| **Q9** | `<DecimalInput>` 的 23 个文件不碰;列出会同屏新旧两种控件的 INPUT-2b 页面 | ★ **DONE** | 一个都没碰(它们不在 `classification-final.json` 里)。**6 条路由**会同屏,逐条列在 §8 与 `docs/forward-queue.md`。★ 并更正了自己第一版的算法:第一版按「用了 `<DataTable>` 就算」得出 **66 条**,而其中 60 条上那三个勾选框**根本没有渲染**(全仓库只有 `CostSettlePanel.tsx:119/:145` 传了 `selection=`) |
| **Q10** | 先读 `RoleForm.tsx:85` 带的是 `disabled` 还是 `readOnly`,再决定剥哪一条;说明是哪一种 | ★ **DONE** | ★ **是 `disabled`** —— 源码 `disabled={!isNew}`,而那一支 class 恰好在 `!isNew` 时才加,**两者永远同时成立**。照第一支:**剥 `bg-gray-100`、留 `text-gray-500`**。见 §9 |
| **Q11** | `type="hidden"` 不动 | ★ **DONE** | 全树 **57 个** hidden 输入框,其中**本刀名下 17 个** —— 一个都没进施工清单(分类器就把它们排除在 `mine` 之外),`git diff` 里一处都没有 |
| **Q12** | spec §4.1b 的 ~27px 就地更正成 20.3px:保留原句并标为已被推翻、写明谁 / 哪天 / 什么方法、保留「在 padding 之外」与「只在 Chromium」两句;**不动** `docs/handbacks/INPUT-2.md` | ★ **DONE** | `docs/variant-c-spec.md` §4.1b:原句用 `~~删除线~~` 保留,下面一张表写着「谁推翻的 = INPUT-2b / 2026-09-10 / 5 配置 × 2 视口 / 对内边距不敏感是自证 / 3 颗真 select 反证 / 代价 14 颗 → 4 颗」;两句边界都保留;并加了本刀在用的那条判据全文。`docs/handbacks/INPUT-2.md` —— `git status` 显示**它一个字节都没动** |
| **Extra** | 交回报告要带一份「队列里所有还开着的外观条目」,并明确说按钮尺寸统一与卡片样式在不在 | ★ **DONE** | 见 §10。**按钮尺寸统一:在,而且已经做完了(STYLE-2,2026-09-09)**;**卡片样式:在,但一刀都没排** |

---

## 3 · §4.2 —— 冒烟:那道自 2026-09-08 起就红着的闸

### 3.1 做了什么

**四处改动,全部在 `scripts/smoke-routes.mjs`:**

1. `SPECIAL_ID_ROUTES` 加 `'/verify/cod/[token]'` —— 走脚本**已有**的那条路(预检对这一栏里的路由不查 `ID_SOURCES`)。
2. 主循环里现造令牌,**只读地证明它匹配不到任何一张证书**:
   `randomUUID()` → `certificates_of_destruction?select=id&verification_token=eq.<uuid>` 必须回 **0 行**;
   最多重试 5 次;**五次都撞上就抛**(那时坏的是查询,不是运气)。
3. `EXPECTED['/verify/cod/[token]'] = [404]` —— **精确**,不接受 429(Q5)。
4. `MUST_CONTAIN` 两句,**从 `app/verify/cod/verifyHtml.ts` 的 `renderNotFound()` 读出来的**:
   `Certificate not found` 与 `No certificate matches this verification link.`

★ **为什么这四条能同时成立(查过机制,不是想当然):** `MUST_CONTAIN` 只在 `pass` 之后才跑,
而 `pass = exact ? … : (2xx || allow.includes(res.status))`,`allow = EXPECTED[route]` —— **404 走得通**。

### 3.2 结果:预检过了,而且是【自 2026-09-08 以来第一次】

```
== 229 routes + … : 247 ok, 6 skipped (no data), 1 FAILED
SMOKE_OWN_EXIT=1        ← 871 秒
```

* ★ **预检放行了**,冒烟**真的走完了 229 条路由**(此前它在预检处退 1,**0 秒、一条都没走**)。
* ★ `/verify/cod/[token]` **不在失败清单里,也不在跳过清单里 → 它过了**
  —— 而且**有一条独立的物证**:见下面那张表。

### 3.3 ★ 它写了什么 —— 预测与实测逐字对上

| | 预测(Q4 写的) | ★ 实测 |
|---|---|---|
| 跑前 `cod_verification_failures` | 4 行,时间戳全 `2026-09-08`,全部在 10 分钟窗口外 | ★ **`content-range: 0-3/4`**,四个时间戳全是 `2026-09-08T01:54…02:01` |
| 这一次请求做什么 | DELETE 过期行 + INSERT 一行 | —— |
| 跑后 | **1 行** | ★ **`[{"failed_at":"2026-09-10T23:46:33.172736+08:00"}]`** —— **恰好 1 行,时间戳是这次跑的那一刻** |
| 业务数据 | 零 | ★ **零** —— 没有证书、没有单据、没有账号、没有员工 |
| 真实持有人 | 不受影响 | ★ **有效令牌永不被限流**(判据在 `cod_verification()` 里) |

☞ **那 4 行被删、1 行被插,与预测一个字不差。** 这同时证明了请求**真的到达了数据库函数**
—— 也就是说 404 不是路由没匹配上,而是 `renderNotFound()` 真的被画了出来。

### 3.4 ★★ 而走过预检之后,露出了【第二处红】—— 它也是同一个提交带进来的 ★★

```
✗ /me/avatar (/me/avatar) → HTTP 404
```

| 查的是什么 | 读数 |
|---|---|
| 是本刀弄坏的吗 | ★ **不是。** `git show HEAD:scripts/smoke-routes.mjs \| grep -c 'me/avatar'` = **0** —— 在 HEAD 上就没登记过 |
| 那个文件哪天来的 | ★ **`9b71b4e`(COD-2,2026-09-08)—— 与 `/verify/cod/[token]` 是【同一个提交】** |
| 404 是缺陷还是契约 | ★ **契约。** `app/me/avatar/route.ts:75` 自己写着「★【对象不在 = 404,而 404 是【预期内】的答案】★ AvatarImage 的 onError 会回落成首字母 —— 那正是 UI-1d 立下的判据」。而冒烟用的是一个**用完即删的 admin**,它**永远没有头像对象** |
| 为什么两天没人看见 | ★★ **预检先退 1,把它后面所有的红都藏起来了。** INPUT-2b 是第一条走过预检的刀 |

**处置:** `EXPECTED['/me/avatar'] = [404]`,**精确**,旁边逐字写明**它证明了什么、没证明什么**;
「有对象时它真的把 webp 字节送出去」那一半**没有任何检查覆盖**,
已单独立案 `docs/known-issues.md` → **`SMOKE-AVATAR-BYTES-UNCOVERED`**。

### 3.5 ★ 第三处:两条 `EXPECTED_SKIPS` 照它们自己的承诺到期了

```
✗ 预期会 SKIP 的路由跑起来了 —— 数据到位了,把它移出 EXPECTED_SKIPS:
  /hr/claims/[id], /hr/leave/[id]
```

原注释写着「**有数据那天此断言逼人收编**」。**那一天到了**,实测(service_role,`count=exact`):
`medical_claims` **1 行** · `leave_requests` **3 行**。**两行照约定删除**,
并把「哪天那些行又没了,这道闸会从另一个方向响」写在原地。

> ☞ **三处红,一处都不是本刀造成的**(树里当时只有 `scripts/smoke-routes.mjs` 一个文件是脏的)。
> **而它们只有在第一处被修掉之后才看得见** —— 这条形状本身值钱,已写进 known-issues:
> **一道闸的第一处红,会把它后面所有的红藏起来。**
---

## 4 · §4.4 —— 转换是怎么做的,以及【为什么是一支脚本】

**422 个编辑单位住在 124 个文件里,每一处都是同一次改写:**
剥掉那一串 inline 的样子 → 换成模块的常量 → **宽度类原样留着**。

> ☞ **手改 422 次会漏,而漏掉的那一处【没有任何检查看得见】** —— 它只是一个仍然长得不一样的控件。
> 所以**改写交给机器,判据(剥 / 留)交给上一步**:
> `/tmp/input2b/amend.mjs`(把 Q1–Q12 套到 Round 1 的分类上)→ `classification-final.json` →
> `/tmp/input2b/convert.mjs`(逐处改写)。**两支都在仓库外。**

### 4.1 定位手段:与 Round 1 的分类器【逐字同一支】

分类那一步记的是**行号**,而一个文件里可以有两个 className 串**逐字相同**的控件
(实测 `app/hr/attendance/[id]/AttendanceGrid.tsx:153` 与 `:175` 就是)。
所以改写不拿字符串去 `indexOf`,而是**用同一支扫描器重新走一遍**
(`tagEnd()` + 注释遮罩,从 `scan.mjs` 抄的同一段代码),拿到那个标签在源码里的**精确起止**,
再算出 `className=…` 整段属性的绝对区间。

★ **失败就停,不做半套:** 任何一个站点定位不到 / 同一行命中两个标签 / 两处改写区间重叠 →
**整支脚本抛,一个字节都不写。** 实跑:**定位失败 0 处。**

### 4.2 实际写了多少笔

| 笔数 | 是什么 |
|--:|---|
| **416** | A / C 类的机械改写(`classKind=string` **413** + 一个 className 都没写的勾选框 **3**) |
| **3** | 三个常量的**声明处**各一次 |
| **5** | 那三个常量覆盖的**下拉**调用点,把标识符换成 `fieldSelect` / `fieldClsSelect` |
| **3** | 手改(`PayPanel.tsx:66` · `SourcePicker.tsx:87` · `RoleForm.tsx:85`) |
| ★ **427** | **合计写盘笔数** |
| **26** | 去掉的 `rows=`(第 27 个多行框本来就没写) |
| **105 / 13** | 新增 import 的文件数 / 合并进已有 import 的文件数 |
| **124** | 动过的文件 |

**★ 427 与「422 次编辑」的差,逐条说清:**

* 422 = 419 inline + 3 个常量。而 419 里有 **1 处不写任何东西**:
  `IndexPicker.tsx:31` 是 `className={className}` —— 一个**透传的 prop**,
  它自己不写样子,样子由调用方给(3 个调用方实测都不传 className)。**→ 418**
* 加 3 个常量声明 = **421**
* ★ 加 **5** 笔下拉标识符替换 —— 这是「一个常量装不下两种样子」的必然代价(见 4.3)= **426**
* ★ 加 **1** 笔 Q10 的 `RoleForm.tsx:85`(它 `onModule=true`,**不在那 435 里**,Tim 单独裁给本刀)= **427**

### 4.3 ★ 一个常量装不下两种样子 —— 为什么三处声明各产出两条

`LeaveForm::field` 覆盖 **2 个下拉 + 6 个输入框**;`ClaimForm::field` 覆盖 **1 + 4**;
`SourcePicker::fieldCls` 覆盖 **2 + 1**。
而 R2 给这两类的是**两条不同的常量** —— 原生下拉要多让出右边 **24px** 给浏览器那颗箭头。

**所以每处声明一次改写产出两条**,命名照 INPUT-2 在 `DictSection` / `TaskHeader` /
`CommissionForm` / `LanesPanel` 立下的**同一个**约定(`field` + `fieldSelect`):

```js
-    const field = 'mt-1 w-full border border-gray-300 rounded px-2 py-1 text-sm'
+    const field = `${CONTROL_INPUT} mt-1 w-full`
+    const fieldSelect = `${CONTROL_SELECT} mt-1 w-full`
```

☞ **「样式只有一处定义」这件事不受影响:两条都来自模块。**

### 4.4 §4.5 —— 「文案 / i18n / 行为 / 提交形状一个都没动」,而这是【证出来的】

**不是读一遍 diff 觉得没问题。** 把改前(`git show HEAD:<file>`)与改后的每一个文件
做同一次归一化 —— 删掉每一个 `className` 属性、删掉 `rows=`、删掉从 `control-style`
来的 import、删掉那四个本地常量的声明行、折叠所有空白 —— 然后**逐字节比**:

```
比过的文件:124;归一化之后【仍然不同】的:0
NOBEHAV_OWN_EXIT=0
```

☞ 这条判据的写法照的是本仓库那句「**判据必须走人真的走的那条路**」:
一个「diff 看起来只动了 className」的印象,和一个「把 className 拿掉之后两边一模一样」的
**测量**,不是同一件事。

**零迁移** —— `db/migrations/` 一个文件都没加(§4.5 要求「若似乎需要迁移就停」;不需要)。

---

## 5 · §3 Q7 / Q8 —— 两张清单都没有的 class,46 处逐条

| class | 处数 | Tim 的裁决 | 落地 |
|---|--:|---|---|
| `border-[color:var(--brand-border)]` | **9** | **剥** | 全部剥掉(⚠ spec §7.2 实测同一写法在 `card` 上**空转** —— `border-width: 0px`,它可能本来就没生效) |
| `file:*` 七件套(`file:mr-3` `file:rounded` `file:border-0` `file:bg-blue-600` `file:px-4` `file:py-2` `file:text-white` `hover:file:bg-blue-700` `file:text-sm`) | **6 个站点** | **剥,换 `CONTROL_FILE_BUTTON`** | 6 处全换。★ **这是 `CONTROL_FILE_BUTTON` 的第一批消费者**(INPUT-2 定义它时是 0 个) |
| `disabled:bg-gray-100` | **4** | **剥** | 全部剥掉(模块自带 `disabled:bg-input/50`) |
| `disabled:text-gray-400` | **1** | **留** | 留着 —— `app/settings/import/ImportForm.tsx:189` |
| `border-red-400` | **1** | **Q8:错误类赢 → 留** | `PayPanel.tsx:66`,连 `bg-red-50` 一起留 |
| ★ **其它(「原样留着并列出来」那一栏)** | ★ **0** | —— | ★ **Q7 + Q8 把 13 种 46 处裁完了,没有一处需要落到这一栏** |

**★ 字色(R5 / Q12)—— 6 处,留 5 剥 1,逐处:**

| 站点 | 字色 | 元素状态 | 裁决 |
|---|---|---|---|
| `app/inbound/[id]/edit/EditInboundForm.tsx:132` | `text-gray-500` | `disabled` | **留** |
| `app/inbound/[id]/edit/EditInboundForm.tsx:197` | `text-gray-500` | `disabled` | **留** |
| `app/output/[id]/edit/EditOutputForm.tsx:117` | `text-gray-500` | `disabled` | **留** |
| `app/output/[id]/edit/EditOutputForm.tsx:166` | `text-gray-500` | `disabled` | **留** |
| `app/tools/pricing/metal-prices/SourcePicker.tsx:87` | `text-gray-400` | `disabled` | **留** |
| `app/inbound/[id]/edit/CertificatePanel.tsx:173` | `text-gray-900` | **既不 `readOnly` 也不 `disabled`** | ★ **剥** |

★ **另有一处 R5 的【留】赢了一次 display 之争,照直说:**
R5 把 `display` 放在**留**清单上,而 `CONTROL_TEXTAREA` 自带 `flex`。
于是 **2 处多行框**(`app/hr/reviews/ConclusionForm.tsx:102` · `app/sales/customers/ChasePanel.tsx:252`)
调用点自己的 `block` 留了下来 —— **它们渲染 `block`,而库的 `<Textarea>` 渲染 `flex`**。
按 Q8 的总则这是**对的**(留赢),而 `display` **不是 R2 的一个值**,所以它不算不合。
**登记在这里,不当成缺陷。**

---

## 6 · §3 Q10 —— `RoleForm.tsx:85` 是哪一种

★ **是 `disabled`,不是 `readOnly`。**

```tsx
<input
    value={v.code}
    disabled={!isNew}                                    // ← 读到的就是这一行
    onChange={…}
    className={field + (isNew ? '' : ' text-gray-500')}  // ← 改后
/>
```

**那一支 class 恰好在 `!isNew` 时才加,而 `disabled` 也恰好在 `!isNew` 时为真
—— 两者永远同时成立。** 所以照 Q10 的第一支:

* **剥 `bg-gray-100`** —— 模块的 `disabled:bg-input/50` 接管;
* **留 `text-gray-500`** —— 照 R5 / Q12(控件 `disabled`,字色留)。

`field` 本来就已经是 `` `${CONTROL_INPUT} w-full` ``(INPUT-2 做的),所以这一处**只改那一支三元**。
---

## ★★★ 7 · §5.3 —— R6 逐条,而 R6(a) 【响了】:本刀停在这里 ★★★

> ## ★ 结论,一句话
> **R6(a) 响了:两条路由在 390px 上的整页横向溢出长大了,而且两条都 ≥2px ——
> 照 §3 Q2 的规则,这是【不复量、直接停手】。**
> **按 R6 的处置:交回、不回退、不调表、不改列宽。** 树里的工作**原样留着**,
> `§7` 的闸门 / 提交 / 推送 / 部署**一步都没有做**。

| 停止条件 | 参照点 | 结果 | 读数 |
|---|---|---|---|
| **R6(a)** 390px 新增或长大的整页溢出 | ★ **本刀自己的改前读数**(Q2) | ★★ **响了 —— 2 条** | 见 §7.1 |
| **R6(b)** 已裁定横滚的表多出滚动范围 | 本刀自己的改前读数 | ✅ **没有** | phone 上比过 **102 张表**,多出滚动范围的 **0 张** |
| **R6(c)** 12 张基线表的表头高 / 行数 / 最大行高 / 滚动壳内容宽 | `docs/row-height-baseline.md`(R6(c) 的参照点 Q2 没有改) | ✅ **没有** | 比对器:「比过的表:**12 / 基线 12 张**;编辑态 **2 / 2**」,**一张表的四个字段都没变**;我自己按 (路由, 表头签名, 同签名第几个) 重算也是 **0** |
| **R6(d)** 那 14 条 INPUT-3 路由上有任何东西变了 | 本刀自己的改前读数 | ⚠ **变了 8 个成员,而【全部】来自一个共享组件** | 见 §7.3 |
| **R6(e)** `<Input>` / `<Textarea>` 发出去的 class 串变了 | HEAD | ✅ **没有,而且是【按构造】没有** | `git status --porcelain app/components/ui/control-style.ts app/components/ui/input.tsx app/components/ui/textarea.tsx` → **空**。**三个文件一个字节都没动**,所以那两条 class 串不可能变 |

---

## 7.1 ★★ R6(a) —— 两条路由,逐条,连机制一起 ★★

**参照点是 `.survey-out/input2b-before/controls-drift-MERGED.json`(本刀自己的改前读数,Q2)。**

| 路由 | 改前 | 改后 | 变化 | 判定 |
|---|--:|--:|--:|---|
| ★★ **`/hr/attendance`** | **0** | **14** | ★ **+14 —— 新增** | **≥2px → 停手,不复量** |
| ★★ **`/sales/orders/new`** | **205** | **262** | ★ **+57 —— 长大** | **≥2px → 停手,不复量** |
| `/logistics/lanes` | 4 | **0** | −4 | **变小了**(不是回归;这是 §4.3 要的那个结果) |
| `/settings/accounts` | 36 | **35** | −1 | **变小了**(不是回归;★ 而这一格正是 Q3 那个 ±1px 不稳的量 —— 它自己又晃了一次,方向还相反) |

★ **1px 复量规则一次都没有用上** —— 两条都是 **≥2px**,Q2 明写这种情况「**不复量,直接停手**」。

### ① `/hr/attendance`:0 → 14 —— 一个【月份框】,而它是 Q6 刚裁进范围的那三种之一

**本刀在这条路由上只有 1 个站点:** `app/hr/attendance/OpenPeriodForm.tsx:26`

```tsx
<div className="flex items-end gap-3">        {/* ← 一个【不换行】的 flex 行 */}
    <label className="text-sm">
        <span …>{t('attendance.openMonth')}</span>
        <input type="month" … className={CONTROL_INPUT} />   {/* ← 宽度类:一个都没有 */}
    </label>
    <Button …>
```

| | |
|---|--:|
| 那个月份框的渲染宽,phone | ★ **168 → 191(+23)** |
| 那个月份框的渲染宽,desktop | 160 → 164(+4) |
| 整页溢出,phone | ★ **0 → 14** |
| 它有宽度类吗 | ★ **没有一个** |

**机制:** `input type="month"` 在 Chromium 上是**内在尺寸**的(分段文字 + 那个小箭头)。
标准把手机字号 **14→16px**、左内边距 **8→10px**、右内边距 **→10px** —— 三样都进宽度,
于是它当场宽了 23px;而它所在那一行**没有 `flex-wrap`**,那 23px 里有 14px 顶到了页面外面。

★★ **一处必须说出来的:`month` 是 Q6 才裁进范围的三种类型之一**
(`search` 6 · `month` 4 · `datetime-local` 2)。**上一版分类器没有单列它们**,
所以 Round 1 的 390px 风险图**从来没有把这一类当成一类来看**。
☞ **这不是在说裁定错了** —— 裁定是对的,`month` 就该照 §4.1。
**是在说:一条新裁进范围的控件类型,应当连同它的版式后果一起被量一次,而这一轮没有。**

### ② `/sales/orders/new`:205 → 262 —— 五颗 `flex-1` 的原生下拉

**本刀在这条路由上 8 个站点,而【每一个都写着宽度类】**(`w-full` ×4 · `flex-1` ×1 · `w-28` · `w-32`)。
变宽的是那颗 `flex-1` 的下拉,而它在一个 `LINE_SLOTS` 循环里**渲染了 5 次**:

```tsx
<div key={i} className="flex gap-2">                                   {/* ← 又一个【不换行】的 flex 行 */}
    <select name={`line_material_${i}`} className={`${CONTROL_SELECT} flex-1`}>
    <input … className={`${CONTROL_INPUT} w-28`} />
    <input … className={`${CONTROL_INPUT} w-32`} />
</div>
```

| | |
|---|--:|
| 那五颗下拉的渲染宽,phone | ★ **307 → 364,五颗各 +57** |
| 整页溢出,phone | ★ **205 → 262(+57)** |
| 它们有宽度类吗 | ★ **有 —— `flex-1`。而它【没能挡住】** |

### ★★★ 而这一条推翻了 Round 1 自己的一条断言,所以它值得单独写 ★★★

> **Round 1 §4.2 的原话:「危险形状(没有宽度类的控件并排坐在一个不换行的 flex 行里)——
> 本刀名下 58 条路由上,这种行有 0 个。」而它还带着覆盖断言,说检出器【确实找得到】这种形状。**

★ **两条炸掉的路由【都在那 58 条里】,而检出器【都放行了】。**
把 Round 1 的检出器读数原样调出来:

| 路由 | `flexHosts` | `nowrapHosts` | `hostsWithBand2`(≥2 个控件并排) | ★ `nowrapBand2NoWidth`(它报的「危险」) |
|---|--:|--:|--:|--:|
| `/hr/attendance` | 1 | **1** | ★ **0** | **0** |
| `/sales/orders/new` | 6 | **6** | **5** | ★ **0** |

**两条【各自】栽在检出器的一个不同判据上 —— 两个都是判据本身的毛病:**

| # | 检出器要求 | 现实 | 后果 |
|---|---|---|---|
| ★ **①** | 那一行里的控件**没有宽度类** | `/sales/orders/new` 那颗下拉**有** `flex-1` → 被过滤掉 | ★★ **`flex-1` 挡不住一颗原生 `<select>` 变宽。** `flex: 1 1 0%` 配 `min-width: auto` 时,**一个 flex 项目不能被压到自己的 `min-content` 以下**;而 `<select>` 的 `min-content` = **最长那条 option 的文字宽 + 左右内边距 + 边框 + 箭头保留区**。本刀把右内边距 12→**24**、手机字号 14→**16**(它同时放大了最长那条 option 的文字宽)—— **`min-content` 因此长了 57px,而 `flex-1` 对此无能为力。** |
| ★ **②** | 那一行里**≥2 个控件并排** | `/hr/attendance` 那一行只有 **1 个控件** —— 它旁边是一颗 `<Button>`,而按钮不是控件 | ★★ **一个不换行的行里,【一个】没有宽度类的控件就够了。** 「并排 ≥2」这个判据把它整类漏掉了。 |

> ☞ **判据一句话(给 INPUT-3,也给 AGENTS.md):**
> **「有没有宽度类」不是一个控件会不会撑破页面的判据。**
> 一个 `flex-1` / `w-full` 的原生 `<select>` 仍然会按它 `min-content` 的宽度顶开容器,
> 而 `min-content` 吃字号、内边距与**最长那条 option**。
> **要盯的是「一个不换行的容器里,有任何一个内在尺寸由内容决定的原生控件」——
> 不是「有几个、有没有写 `w-*`」。**
>
> ☞ 这与 `AGENTS.md` 已有的那条「**一次样式改动落在没有宽度类的原生控件上,就是一次版式改动**」
> 是同一族,而它把那一条**放宽了**:**写了宽度类也一样。**

---

## 7.2 ★ 与 `docs/row-height-baseline.md` 那一份的差值 —— 【另报一行】(Q2 要的)

```
· 比过的表:12 / 基线 12 张;编辑态 2 / 2 张
· 整页溢出:基线 7 条,读数 7 条
· 已裁定横滚的表:11 张
· 变小了的(不是回归,登记在案):
    · /logistics/lanes:整页横向溢出没有了(不是回归,但要知道) 12 → 0
✗ check-row-height-baseline:2 处与基线不同
   · /hr/attendance:★ 新增的整页横向溢出  0 → 14
   · /sales/orders/new:★ 整页横向溢出长大了  205 → 262
ROWHEIGHT_OWN_EXIT=1
```

★ **这一次,基线文档那一份与本刀自己那一份【指向同两条路由】** —— 参照点之争在这一轮不影响结论。
**而 Q2 那条规则仍然值钱**,因为它把两件事分开了:

| | 基线文档说的 | 本刀自己的改前读数说的 |
|---|---|---|
| `/hr/attendance` | 0 → 14 | ★ **0 → 14(同)** |
| `/sales/orders/new` | 205 → 262 | ★ **205 → 262(同)** |
| `/logistics/lanes` | 12 → 0 | **4 → 0** ← ★ 两个参照点在这里**不一样**:基线那天是 12,而本刀开工那天已经是 4 |
| `/settings/accounts` | ★ **没有报** | **36 → 35** ← ★ 它在基线文档那一份里**被算成"和基线一样"**(基线记 35,而本刀改前读到 36)—— **Q3 那个 ±1px 又晃了一次** |

☞ **那 12 张基线表的四个字段(表头高 / 行数 / 最大行高 / 滚动壳内容宽)一个都没变** ——
**R6(c) 干净。** 这一刀没有推动任何一张表的行高。

---

## 7.3 ⚠ R6(d) —— 那 14 条 INPUT-3 路由上变了 8 个成员,而【全部】来自一个共享组件

| | |
|---|---|
| 变了的成员 | ★ **8 个,全部在 `/tools/pricing/metal-prices/bulk` 上**(desktop 4 + phone 4:`input.text#0` + `select.native#0/1/2`) |
| 它们来自哪个文件 | ★ **`app/tools/pricing/metal-prices/SourcePicker.tsx`** —— 一个**归 INPUT-2b 的共享组件** |
| 那 14 条路由上的整页溢出 | ★ **一条都没变(0 条)** |
| 其余 13 条路由 | ★ **一个成员都没变** |

### ★ 这不是一次范围泄漏,而这句话是【事先量出来的】,不是事后解释

**动手【之前】我先量了一遍:** 归属是按**页面子树**划的(Tim 的裁定),
而 R6(d) 盯的是**那 14 条路由上的屏幕**。一个住在子树**外面**、却被子树里的页面 import 进去的
共享组件,**同时满足「归 INPUT-2b」与「会改 INPUT-3 的屏幕」**。
逐条跟「真的被当成 JSX 画出来」的 import 边做闭包,结果是 **4 个文件**:

| 文件 | 从哪条 INPUT-3 路由够得着 | 实际结果 |
|---|---|---|
| `SourcePicker.tsx` | `/tools/pricing/metal-prices/bulk` | ★ **8 个成员变了 —— 就是它** |
| `IndexPicker.tsx` | `/tools/pricing/formulas/new` · `…/bulk` | ✅ **0** —— 它是 `className={className}` 透传,**本刀一个字节都没改它** |
| `ClaimForm.tsx` | `/me` | ✅ **0** —— 可达,但**首屏渲染不到** |
| `LeaveForm.tsx` | `/me` | ✅ **0** —— 同上 |

**严格的范围检查(比可达性更硬):**

```
改动的 124 个文件里,住在那 14 条路由页面子树里的:0 个
改动的文件里有 data-table.tsx / DecimalInput.tsx / login / receive / stocktakes /
  ExpectedDateControl / control-style.ts / input.tsx / textarea.tsx 的:一个都没有
```

☞ **所以 R6(d) 的读数是:一条路由、一个共享组件、8 个成员、零溢出变化,其余 13 条零变化。**
**要不要把它算成一次停手,是一条【规则之间的冲突】,需要 Tim 一句话** —— 见 §12。

---

## 7.4 §5.3 —— 控件渲染宽度的变化(★ 按裁定:报出来,不停手)

| | |
|---|--:|
| 成员 | **2112 → 2112**(多出 **0** · 少掉 **0**) |
| 渲染宽度变了的成员 | **261** |
| ★ 其中是 `<label>` 的(它们包着控件,跟着变宽) | **90** |
| ★ **控件本身** | ★ **171** |
| 宽度**逐字未变**的成员 | **1851** |

**按控件类型:** `input.date` **82** · `select.native` **80** · `input.checkbox` **6** ·
`input.text` **2** · `input.file` **1**

**按变化量(前几档):** `+10` **32** · `−4` **26** · `+4` **17** · `+11` **15** · `+19` **15** ·
`+18` **6** · `−19` **6** · `−2` **6** · `+3` **6** · `+57` **5**(★ 就是 `/sales/orders/new` 那五颗) ·
最大 `+57` · 最小 `−40`

**变化落在 81 个 (视口 × 路由) 格子上**,最多的几条:
`phone /hr/employees/new` 6 · `phone /inbound` 6 · `desktop /hr/employees/new` 5 ·
`desktop /inbound` 5 · `desktop /output` 5 · `phone /output` 5 · ★ `phone /sales/orders/new` 5

☞ **一处自证:`/logistics/lanes` 上那个 `w-28` 的编号框,改前改后都是 112px** ——
它写了宽度类,而标准改字号与内边距时它一个像素都没动。**这一行本身就是「宽度类没有被碰」的证据。**
---

## 8 · §5.4 —— R2 逐项:**229 个,229 个合,0 个不合**(两个视口都是)

**量的是【首屏渲染出来、且已经接到模块上】的控件**,判据逐项写死在 `/tmp/input2b/judge.mjs` 里
(高度 / 圆角 / 边框宽 / 边框色 / 左右上内边距 / 字号;多行框另加下限与 `resize`;
勾选与单选另加 16×16 与边框色;文件钮量 `::file-selector-button` 伪元素的 8 个值)。

| | phone 390 | desktop 1440 |
|---|--:|--:|
| 接了模块的首屏控件 | **229** | **229** |
| ★ **合** | ★ **229** | ★ **229** |
| ★ **不合** | ★ **0** | ★ **0** |

**按类:** `input` **126** · `select` **73** · `textarea` **15** · `checkbox` **11** ·
`file` **2** · `radio` **2**

### ★ 判据认得那三件事(委托书 §5.4 点名要求),逐条说清它怎么认的

| 要认的 | 怎么认的 | 本轮实际命中 |
|---|---|---|
| **E6 按裁定不一样** | 判据先按 `min-h-[48px]` 把 E6 那一档**摘出去**,单独计数,不算进"不合" | ★ **0 个** —— 而这是因为 E6 那两页(`/inbound/receive` · `/stocktakes/*`)**不在本刀这 58 条路由里**。**照直说:这一轮它没有被考验过。** |
| **默认勾上的框边框是 `#007FAD`** | 期望值按 `checked \|\| indeterminate` 分支:选中 → `rgb(0,127,173)`,未选中 → `rgb(98,115,140)` | 11 个勾选 + 2 个单选**全部合** |
| **`rounded-full` 报成 3.35544e+07px** | 单选框不比字面值,改判「`^3.3554` 或 `parseFloat ≥ 9999`」 | 2 个单选框合 |
| (另外自己加的一条)**校验失败态自带另一条边框色** | `aria-invalid="true"` 时**不比**边框色(`aria-invalid:border-destructive` 是裁定要的) | 命中的正是 `PayPanel.tsx` 那个日期框 |

☞ **一处照直说的边界:这 229 个里包含 INPUT-2 已经接好的那一批**(比如那 2 个单选框来自
`MaterialAxesPicker`,本刀一个字节都没碰)。这一节答的是「**本刀这 58 条路由的首屏上,
凡是接了模块的控件,是不是都长成 R2 说的样子**」,**不是**「本刀转的每一个都合」——
后者答不了,因为 260 个站点首屏量不到(见 §10)。

---

## 9 · §5.5 —— select 装得下吗(20.3px 保留区,**Chromium only**)

**判据(写死):选中项文字宽 ≤ `clientWidth` − `padding-left` − `padding-right` − **20.3px**。**
文字宽 = canvas `measureText`,用那颗 select 自己的 `getComputedStyle().font`。

| | phone 390 | desktop 1440 |
|---|--:|--:|
| 首屏原生 `<select>` | **73** | **73** |
| 装得下 | **66** | **70** |
| ★ 装不下 | ★ **7** | ★ **3** |

### phone 390px 的 7 颗,逐颗(全部归 INPUT-2b,全部被本刀改过)

| 短多少 | 路由 | 选中项 | 内容宽 | 有宽度类吗 | 判读 |
|--:|---|---|--:|---|---|
| ★ **24.01px** | `/tools/pricing/metal-prices/new` | 「— only for a published-index quote —」 | 298 | ★ **有** | ★★ **唯一一颗真被截了尾巴的。而它【变坏了】:Round 1 改前量到短 14.01px → 现在 24.01px,右内边距 12→24 让它多短了 10px。它写了宽度类,所以本刀没有动它的宽度 —— 变坏的是内边距。** |
| 0.64px | `/inbound/new` | 「Unspecified — assign later by transfer」 | 324 | 有 | 新进名单;差 0.64px = 正好装满 |
| 0.64px | `/output/new` | 「Unspecified — assign later by transfer」 | 324 | 有 | 同上 |
| 0.27px | `/settings/import` | 「— choose a table —」 | 199 | 没有 | 改前就在名单里(0.27px,**逐字未变**) |
| 0.24px | `/tools/converter` | 「as received → dry」 | 183 | 没有 | 改前就在名单里(0.24px,**逐字未变**) |
| 0.14px | `/finance/close` | 「2026-08-31」 | 136 | 没有 | 新进名单 |
| 0.11px | `/hr/leave` | 「All statuses」 | 136 | 没有 | 改前就在名单里(0.11px,**逐字未变**) |

### desktop 1440px 的 3 颗

| 短多少 | 路由 | 选中项 | 有宽度类吗 |
|--:|---|---|---|
| 0.23px | `/inbound` | 「All pricing states」 | 没有 |
| 0.15px | `/settings/import` | 「— choose a table —」 | 没有 |
| 0.12px | `/tools/converter` | 「as received → dry」 | 没有 |

### ★ 改前 4 颗 → 改后 7 颗,差额逐条(不含糊)

| | |
|---|---|
| **改前(Round 1)** | 4 颗:`metal-prices/new` **14.01** · `/settings/import` **0.27** · `/tools/converter` **0.24** · `/hr/leave` **0.11** |
| **改后** | 7 颗 |
| ★ **新进的 3 颗** | `/inbound/new` **0.64** · `/output/new` **0.64** · `/finance/close` **0.14** —— ★ **三颗全部差不到 0.7px** |
| ★ **变坏的 1 颗** | `metal-prices/new` **14.01 → 24.01**(+10px,来自右内边距 12→24) |
| **逐字未变的 3 颗** | `/settings/import` · `/tools/converter` · `/hr/leave` —— 三颗的短缺量**一个小数位都没动** |
| ★ **走掉的 1 颗** | ★ `/logistics/lanes` 那两颗 —— **§4.3 把它们修好了**(内容宽 136 → 172,`SG Singapore` 现在装得下)。INPUT-2 时代它在名单上,而且是被 INPUT-2 的宽度类逼进去的 |

☞ **照直说:7 颗里有 6 颗差不到 0.7px** —— 那是「正好装满」,不是「被截掉」。
**真正在屏幕上少了字的只有一颗**,而它写着宽度类、本刀没有动它的宽度。

**截图(仓库外,7 张,390px,`deviceScaleFactor: 3`):**
`/tmp/input2b/shots-select/misfit-01.png` … `misfit-07.png`
顺序同上表(01 `/finance/close` · 02 `/hr/leave` · 03 `/inbound/new` · 04 `/output/new` ·
05 `/settings/import` · 06 `/tools/converter` · 07 `/tools/pricing/metal-prices/new`)。
★ clip 用的是**视口坐标 + 滚动偏移**(委托书点名的那个量陷阱)。

---

## 10 · §5.6 —— UNMEASURED:转换了 435 个站点,其中 **260 个首屏量不到**

**判据说清楚它能答什么、不能答什么:** 它比的是**每条路由上的个数**
(该路由转了几个 vs 首屏量到几个接了模块的),**不是逐个站点的身份**。
于是它答得了「这条路由上有 N 个站点从来没在首屏出现过」,**答不了「是哪一个」**。

| | 路由数 | 站点数 |
|---|--:|--:|
| ★ **量具结构上走不到**(`[id]` 动态路由 / 不是路由的目录) | **24** | ★ **162** |
| ★ **首屏没有全部渲染**(对话框 / 折叠面板 / 编辑开关) | **22** | ★ **98** |
| ★ **合计 UNMEASURED** | **46** | ★★ **260 / 435(60%)** |

**最大的几条:**

| 站点 | 路由 | 为什么 |
|--:|---|---|
| **24** | `/suppliers/[id]/edit` | 动态路由,量具走不到 |
| **22** | `/finance/assets/[id]` | 同上 |
| **17** | `/inbound/[id]/edit` | 同上 |
| **17** | `/sales/customers` | 转了 18,首屏只见 1 —— 其余在折叠面板 / 对话框里 |
| **16** | `/sales/customers/[id]/edit` | 动态路由 |
| **13** | `/hr/employees` | 转了 17,首屏见 4 |
| **9** | `/materials/[id]/edit` · `/sales/orders/[id]` | 动态路由 |
| **8** | `/output/[id]/edit` | 动态路由 |

**具名的三类,委托书点过名:**
* **动态路由** —— 上表 24 条,`survey-controls.mjs` 抬头 ① 写着它结构上不走 `[id]`;
* **对话框** —— `app/components/ui/confirm-dialog.tsx:247` 那个理由输入框(点开才有);
* ★ **`/settings/accounts` 的"编辑"开关** —— 那 **8 个**站点藏在开关后面,
  而 `--mode=edit` **也量不到它**(那一支只认 `<EditableTable>`,而这一页不是)。

☞ **另外两处 `display` 的观察(§5 那一条)也落在 UNMEASURED 里:**
`ConclusionForm.tsx:102` 与 `ChasePanel.tsx:252` 那两个多行框保留了调用点自己的 `block`,
而**首屏一个都没量到**(判据报 `displayNotes = 0`)——
**所以"它们渲染 block 而不是 flex"这句话是【读代码得出的】,不是量出来的。照直说。**

---

## 11 · 每一步的实测时长与退出码

| 步 | 起(UTC) | 止 | 秒 | 退出码 |
|---|---|---|--:|---|
| §1.1/§1.2 开工闸(HEAD · 树 · 六件产物) | 15:27:05 | 15:27:10 | **5** | 0 |
| §1.3 通读(停止闸 + 4 份文档 + 3 支量具抬头 + 2 个源文件) | 15:27:10 | 15:32:00 | **290** | — |
| §4.1 分类修订(`amend.mjs`) | 15:32:04 | 15:32:04 | **<1** | ★ **0** |
| §4.2 改冒烟(4 处)+ 语法检查 | 15:32:10 | 15:33:30 | **80** | 0 |
| ★ §4.2 **冒烟整跑(第一次)** | 15:33:33 | 15:48:04 | ★ **871** | ★ **1**(三处**先于本刀**的红) |
| R6(d) 事前可达性测量(`r6d-graph.mjs`) | 15:45:00 | 15:45:30 | **30** | 0 |
| §6 文档:spec §4.1b / Q6 / Q8 · AGENTS.md · known-issues ×2 · forward-queue | 15:45:30 | 15:52:00 | **390** | 0 |
| §4.3 `/logistics/lanes`(2 处 `flex-wrap` + 3 处去宽度类) | 15:50:50 | 15:51:00 | **10** | 0 |
| ★ §4.4 **转换 427 笔 / 124 个文件**(`convert.mjs`) | 15:51:01 | 15:51:01 | ★ **<1** | ★ **0** |
| §4.6 `tsc --noEmit`(删掉 tsbuildinfo,整跑) | 15:52:16 | 15:52:25 | **9** | ★ **0** |
| §4.5 的证明(`no-behaviour-change.mjs`,124 个文件归一化逐字比) | 15:52:30 | 15:52:31 | **1** | ★ **0** |
| eslint 冻结闸(`check-lint.mjs`) | 15:58:59 | 15:59:12 | **13** | ★ **0** |
| §7.1 `check-i18n.mjs` | 15:57:11 | 15:57:12 | **1** | ★ **0** |
| §5.1 `rm -rf .next` | 15:53:41 | 15:53:41 | **<1** | 0 |
| ★ §5.1 **`--mode=drift` 整跑(141 × 2 视口)** | 15:53:41 | 16:21:30 | ★ **1669** | ★ **0** |
| §5.1 `--mode=edit` | 16:21:47 | 16:24:20 | **153** | ★ **0** |
| §5.1 单条补量(`/finance/freight/new` + 陪跑) | 16:24:20 | 16:25:40 | **80** | ★ **0** |
| §5.2 并入补量 + 两条 compare + 行高比对器 + 宽度报告 | 16:25:46 | 16:25:46 | **<1** | 见 §12 |
| §5.3 R6 判定(`r6.mjs`,对着本刀自己的改前读数) | 16:27:00 | 16:27:01 | **1** | 0 |
| ★ §5.4/§5.5 **判据探针(58 × 2 视口 + lanes ×2 + 7 张截图)** | 16:29:06 | 16:39:40 | ★ **634** | ★ **0** |
| §5.4/§5.5/§5.6 判据(`judge.mjs`) | 16:41:00 | 16:41:01 | **1** | ★ **0** |
| **本刀合计(到停手为止)** | 15:27:05 | 16:41:01 | ★ **4436 秒 ≈ 74 分钟** | |

**每一条比对的【自己的】退出码(§5.2 那一跑,逐条写进日志):**

```
MERGE_OWN_EXIT=0
CMP_DRIFT_OWN_EXIT=0        ← 3548 个成员,多出 0 · 少掉 0 · 值变 578 →「这一条作数」
CMP_EDIT_OWN_EXIT=1         ← ★ 118 个成员逐字相同 →「这一条不作数」(见下)
ROWHEIGHT_OWN_EXIT=1        ← 2 处与基线文档不同(即 R6(a) 那两条)
WIDTH_OWN_EXIT=0
```

★ **`CMP_EDIT_OWN_EXIT=1` 不是失败,而这一格值得说清:** 那支比对器的 1 表示
「**成员名单与每一个值都逐字相同**」,它对**致盲**是失败(一次什么都没拿走的致盲证明不了任何事),
而对**本刀**恰恰是要的结果 —— 编辑态那 118 个成员**全部住在 INPUT-3 的表里**
(`/hr/leave/types` · `/hr/reviews/scale`),本刀一个字节都没碰。
☞ **同一个退出码,在两种用法下含义相反。** 照直记下来,免得下一刀把它读成一次失败。

---

## 11b · ★ 本块中我量过、并发现【为假】的断言(AGENTS.md 的必填节)

> **规矩:闸轮的产出里必须有一节叫「本块中我量过并发现为假的断言」,空着也要写"零条"。
> 本轮【不是零条】——七条。**

| # | 断言 | 它写在哪 | 实测 |
|---|---|---|---|
| ★ **1** | 「危险形状(没有宽度类的控件并排坐在不换行的 flex 行里)—— 58 条路由上 **0** 个」,**并且带着覆盖断言** | Round 1 停止闸 §4.2 | ★★ **假。** 两条路由**都在那 58 条里**、检出器**都放行了**,而两者栽在**不同**的判据上:`flex-1` 被"没有宽度类"过滤掉;单个控件被"≥2 个并排"漏掉。**它们随后真的炸了**(§7.1) |
| ★ **2** | 危险形状的限定词是「**没有宽度类**的原生控件」 | `docs/variant-c-spec.md` §4.1a · `AGENTS.md` 同名教训 | ★★ **假。** `flex-1` 与 `w-full` 一样挡不住 —— flex 项目压不到自己的 `min-content` 以下。**两份文档都已就地放宽** |
| ★ **3** | 「冒烟整跑 **~1007 秒**」 | Round 1 停止闸 §9.1(引自 `smoke-routes.mjs` 抬头) | **假(偏高)。** 实测 **871 秒**,229 条路由 |
| ★ **4** | 「INPUT-3 落地前会同屏出现新旧控件的页面」 = 按「用了 `<DataTable>`」算 | ★ **我自己的第一版** | ★ **假。** 第一版得出 **66** 条,其中 **60** 条上那三个勾选框**根本没有渲染**(全仓库只有一个调用方传 `selection=`)。真数 **6** 条 |
| ★ **5** | 「令牌是一枚 **122 位**随机值」 | `docs/known-issues.md` 的 SMOKE-PREFLIGHT-COD-TOKEN | **措辞假。** 它是一枚 **UUID(36 字符)**,**随机的是 122 个比特**。已就地更正 |
| ★ **6** | 那道闸的「去处」= 取一枚**有效**令牌、断言 **200** | 同上条目 | ★ **已被 Tim 的裁定取代**(Q4/Q5:随机令牌 + 精确 404)。原文标为作废,理由写在条目开头 |
| ★ **7** | 「INPUT-2b ✅ 已完成」 | ★ **我自己在本轮早些时候写进 `docs/forward-queue.md` 的那一行** | ★★ **假 —— 而我自己写的。** R6(a) 响了之后已改成 **⛔ 停在停止条件上,没有上线**。**一份声称完成而实际停手的文档,正是这个仓库反复付账的那个缺陷** |

★ **量下来是【对的】那些,列在 §1**(委托书里每一个被我当成阈值用的数,逐条 confirmed)。

---

## 12 · 我不能核实的

* ★ **别的浏览器。** 20.3px 的箭头保留区、整套 select 判据、以及本刀**所有**几何读数,
  **只在 `chrome-headless-shell 152.0.7977.54` 上量过。** 别的浏览器一次都没有验证。
* ★ **20.3px 本轮【没有重量】。** 它是 Round 1 在同一棵树、同一支 chrome 上量的
  (5 配置 × 2 视口,20.21–20.31px),本轮直接采用。**它是本刀 select 判据的地基。**
* ★ **260 / 435 个站点首屏量不到**(§10)。它们**改对没改对,没有任何读数支持** ——
  只有 `tsc` 干净、eslint 没新增、以及那次归一化比对(它证明的是"只改了 className",
  不是"改对了")。
* ★ **E6 那一档这一轮没有被考验过**(§8)—— 那两页不在本刀的 58 条路由里。
* ★ **`ConclusionForm` / `ChasePanel` 那两个多行框渲染 `block` 而非 `flex`** ——
  **读代码得出的,首屏没量到。**
* ★ **`/settings/accounts` 的 8 个站点**藏在「编辑」开关后面,`--mode=drift` 与
  `--mode=edit` **都量不到**(后者只认 `<EditableTable>`)。
* ★ **真人的手。** 全部结论来自 CDP 读数,**没有人真的用手机点过**。
* **`npm run build` / `db/gate.py` / 冒烟第二跑** —— 它们属于 `§7`,而本刀停在 `§5`,
  **一个都没跑。** eslint 与 `check-i18n` 是单独跑的(它们不需要 `next build`)。
* **那 1px 的来源**(`/settings/accounts`,Q3)—— 按裁定没查。而它本轮**又晃了一次**:
  改前 36 → 改后 35,**方向与 Round 1 那次相反**。
---

## 13 · 按控件类型:本刀转了 / 留给 INPUT-3 / 按裁定不动 / 未测量

**全树 927 个 `<input>` / `<select>` / `<textarea>` 开标签**(逐字符扫描 + 注释遮罩),
按归属逐类分账:

| 控件类型 | INPUT-2 已接模块 | ★ **INPUT-2b(本刀)** | INPUT-3 | R4-E6 触控 | R4-Q11 hidden | R4-Q13 | 合计 |
|---|--:|--:|--:|--:|--:|--:|--:|
| `select` | 44 | ★ **129** | 79 | 4 | 0 | 0 | **256** |
| `input.text` | 72 | ★ **122** | 58 | 1 | 0 | 0 | **253** |
| `input.date` | 22 | ★ **78** | 27 | 1 | 0 | 1 | **129** |
| `input.number` | 14 | ★ **48** | 21 | 4 | 0 | 0 | **87** |
| `textarea` | 13 | ★ **27** | 13 | 1 | 0 | 0 | **54** |
| `input.checkbox` | 16 | ★ **13** | 19 | 0 | 0 | 0 | **48** |
| `input.radio` | 2 | **0** | 15 | 0 | 0 | 0 | **17** |
| `input.file` | 0 | ★ **6** | 2 | 0 | 0 | 0 | **8** |
| `input.search` | 0 | ★ **6** | 1 | 0 | 0 | 0 | **7** |
| `input.month` | 0 | ★ **4** | 1 | 0 | 0 | 0 | **5** |
| `input.datetime-local` | 2 | ★ **2** | 0 | 0 | 0 | 0 | **4** |
| `input.email` | 1 | 0 | 0 | 0 | 0 | 0 | **1** |
| `input.EXPR`(type 是表达式) | 1 | 0 | 0 | 0 | 0 | 0 | **1** |
| `type="hidden"` | 0 | **0**(★ 其中 **17** 个是本刀名下的,Q11 裁定不动) | 0 | 0 | 57 | 0 | **57** |
| **合计** | **187** | ★★ **435** | **236** | **11** | **57** | **1** | **927** |

**按裁定【不动】的,逐条:**

| 裁定 | 对象 | 数 |
|---|---|--:|
| **R4 / E1** | `/login` | **1** |
| **R4 / E6** | 收货与盘点两页的触控档 | **11** |
| **R4 / Q13** | `ExpectedDateControl.tsx`(琥珀色虚线 = 「这个日期是估的」) | **1** |
| **R4 / Q11** | `type="hidden"`(本刀名下 17 / 全树 57) | **17** |
| **Q9** | 渲染 `<DecimalInput>` 的 23 个文件 / 52 个调用点 | **196** |
| **每一个 `<label>`** | R13:归【字体/排版】那一刀 | 426 个渲染 |
| **每一颗按钮** | 不在控件这一族 | — |

**未测量:260 / 435(§10)。**

---

## 14 · §3 Q9 —— INPUT-3 落地前会同屏出现新旧两种控件的 **6 条**路由

| 路由 | 本刀转了几个站点 | 同屏的 INPUT-3 控件 |
|---|--:|---|
| `/inbound/[id]/edit` | **20** | `PrepaymentPanel` · `MetalContentPanel` · `HoldReleaseControls` · `TransferControl` |
| `/output/[id]/edit` | **9** | `MetalContentPanel` · `SalePanel` · `HoldReleaseControls` · `TransferControl` |
| `/tools/pricing/metal-prices/bulk` | **5** | `BulkPricesForm` |
| `/purchasing/orders/[id]` | **4** | `RetentionPanel` |
| `/tools/pricing/formulas/[id]/edit` | **2** | `FormulaForm` |
| `/tools/pricing/formulas/new` | **1** | `FormulaForm` |

★★ **一处必须自己更正的算法:第一版算出 66 条,而其中 60 条是错的。**
第一版把「每一条用了 `<DataTable>` 的路由」都算进来。实测
(`grep -rn 'selection=' app`,去掉 `data-table.tsx` 自己):
**全仓库只有 `app/finance/processing-costs/CostSettlePanel.tsx:119 / :145` 传了 `selection=`**,
而那是一条 INPUT-3 路由(它名下没有 INPUT-2b 站点)。
第 490 行那个(列显隐面板)**要点开面板**才画得出来,首屏一个都没有。
☞ **这条判据 forward-queue 本来就写着**(「那 14 条路由的调用方一个都没传」)—— 第一版没有用它。

---

## 15 · §3 Extra —— 队列里所有还开着的外观 / 样式条目

**(全文见下面那一节;先答 Tim 点名的两件)**

| 问题 | 在队列里吗 | 状态 | 归哪一刀 |
|---|---|---|---|
| ★ **按钮尺寸统一** | ★ **在** —— `docs/variant-c-spec.md` **§5** | ★★ **已经做完了(STYLE-2,2026-09-09)**:248 个调用点(243 `sm` + 5 `lg`)转成 `default`;实测 `sm` 31 颗 28px → **0**,`default` 26 → 57 颗全部 32px | **已关闭** |
| ↳ 它剩下的那一件 | §5 那一格的 ⚠ | ⬜ **开着**:`<DataTable>` 自己的 **15 个裸 `<button>`**(排序头 / 展开箭头 / 分页 / 列显隐),实测 **20px×8 · 28px×5 · 30px×2**,圆角 4/6px,**一个都不是 32px**。spec 原话「**这不在 Tim 的裁定范围里**」 | ★ **没有任何一刀领** |
| ★ **卡片样式** | ★ **在,但【没有排期】** —— **§4.4**(实测值)+ **§7.2**(一处空转)+ **§9 Q8** | ⬜ **值已经量到,施工一刀都没有**。§7.2 的坑:C 的 `card` 写着 `border-[color:var(--brand-border)]` 而实测 `border-width: 0px` —— **颜色设了、宽度是 0,什么都没画**;屏幕上那条边是库自己的 `ring-1` | ★ **没有任何一刀领**(§9 Q8「`table` 与 `card` 要不要从 `GUARDED` 毕业」等 Tim 裁) |

---

## 16 · Tim 该去哪儿看 —— 路由 · 视口 · 每一页要的权限

> ⚠ **先说清:这些【都在工作区里,没有上线】。** 要看,得在本机跑 `npm run dev`
> (或先由 Tim 裁定怎么处置那两条溢出、再走 `§7` 上线)。

### ① 先看这两条 —— 它们是**停手的原因**

| 路由 | 视口 | 看什么 | 权限 |
|---|---|---|---|
| ★ `/hr/attendance` | ★ **390px** | 顶上那一行「开启月份」:月份框现在 **191px**(原 168),那一行**不换行**,整页右边多出 **14px** | `module.hr.view` + `module.hr.edit` |
| ★ `/sales/orders/new` | ★ **390px** | 明细区那 5 行:每行「物料下拉 + 数量 + 单价」,下拉现在 **364px**(原 307),整页溢出 **205 → 262** | `module.sales.edit` |

### ② 再看这一条 —— 它是**这一刀修好的那一页**

| 路由 | 视口 | 看什么 | 权限 |
|---|---|---|---|
| ★ `/logistics/lanes` | **390px 与 1440px** | 顶上两张表单**现在会换行**;390px 上整页溢出 **+4 → 0**;两颗下拉的「SG Singapore」**现在装得下**了。桌面那一档**逐字未变** | `module.purchasing.edit`(那两张表单在 `PermissionGate` 里) |

### ③ 抽查转换效果(每类挑一条,都在首屏)

| 路由 | 视口 | 看什么 | 权限 |
|---|---|---|---|
| `/settings/import` | 两个 | ★ **文件选择钮**(`CONTROL_FILE_BUTTON` 的**第一批消费者**):#007FAD 底 · 白字 · 高 32 · 圆角 8;旁边那颗表下拉 | `module.settings.view` |
| `/hr/leave` | 390px | 那 3 个勾选框(16×16 · 圆角 4px · 未选中 `#62738C` 边)+ 筛选下拉 | `module.hr.view` |
| `/finance/payroll-payments` | 两个 | ★ **Q8 那一处**:日期框留空时**同时**有 `border-red-400` + `bg-red-50` + 模块的 `aria-invalid` 边框 —— **两条错误样式叠在一起**(已登记,本刀没有调和) | `module.finance.edit` |
| `/tools/converter` | 390px | 「as received → dry」那颗下拉 —— **差 0.24px 装不下**(正好装满,不是被截) | 无(工具页) |
| `/tools/pricing/metal-prices/new` | ★ **390px** | ★ **唯一一颗真被截了尾巴的下拉**:「— only for a published-index quote —」短 **24.01px** | `module.pricing.edit` |
| `/hr/employees/new` | 两个 | 宽度变化最多的一条(6 个成员) | `module.hr.edit` |

### ④ 量具走不到、只有人能看的(§10 的 260 个里最值钱的几处)

| 路由 | 看什么 | 权限 |
|---|---|---|
| `/suppliers/[id]/edit` | ★ **24 个站点,本刀最大的一处未测量** | `module.purchasing.edit` |
| `/finance/assets/[id]` | 22 个站点 | `module.finance.view` |
| `/inbound/[id]/edit` | 17 个站点,**而且它同屏有 4 个 `<DecimalInput>`(新旧两种样子)** | `module.inbound.edit` |
| `/settings/accounts` | ★ 点「编辑」才出现的 **8 个**站点 —— **两支量具都走不到** | `module.settings.edit` |
| `/settings/roles/[id]` | `PermissionMatrix` 那 29 个格子里的勾选框(INPUT-2 留了读数:行高 37 → 38px) | `module.settings.edit` |

---

## 17 · §7 —— **一步都没做,逐条说明**

> **R6 的处置是「交回、不回退」。`§7` 整段(闸门 → 提交 → 推送 → 部署 → 残留)
> 都在那道停止条件【之后】,所以它一步都没有做。** 这不是漏做,是停手。

| §7 | 要求 | 状态 | 说明 |
|---|---|---|---|
| **7.1** | `check-i18n`:缺键 0 / 加键 0 / 删键 0 | ★ **DONE** | 实跑退 **0**,「✓ 代码引用的每一个键 en 与 zh 都在」。**加键 0 / 删键 0** 是量出来的:`git status` 显示 `messages/` 与 `lib/i18n/` **一个文件都没动**。(另有 156 个"定义了未引用"的键,**报告不算失败**,且本刀没有删掉任何 `t()` 调用) |
| **7.2** | 冒烟整跑必须过 | ⚠ **只跑了第一次(§3),而它退 1** | 三处红**全部先于本刀**,已全部处置。**改完之后【没有再跑一次】** —— 那一跑属于 `§7`,而本刀停在 `§5`。★ **这是这份报告里最大的一块空白:本刀改过 124 个 `app/` 文件之后,冒烟一次都没跑过。** |
| **7.3** | `npm run build` 全绿;eslint 不超基线 | ⚠ **部分** | ★ **eslint 单独跑过:42 错 / 87 警,基线 42/88,「✓ 没有新增的 eslint 问题」**。★ **`npm run build` 本身【没有跑】** —— 而本仓库明写「`next build` 才是闸,`tsc` 只是顺手」,所以**「静态检查全绿」这句话本刀说不出来**。check-instrument-selfproof 的量具计数也因此**没有读到**。 |
| **7.4** | `db/gate.py` 四条判词全绿 | ★ **NOT DONE** | **没跑。** 而本刀**零迁移**、`db/` 一个文件都没动(`git status` 可核) |
| **7.5** | 写交回报告;按显式路径暂存;工作与报告同一个提交 | ⚠ **报告写了(本文件),提交【没有做】** | 树里是**未提交**的改动。**没有 `git add`,没有 `git commit`** |
| **7.6** | 推送,三方 40 位全等 | ★ **NOT DONE** | 没推 |
| **7.7** | 等部署 `state=success` | ★ **NOT DONE** | 没部署 |
| **7.8** | 残留 | ★ **DONE(只读那一半全部量过)** | 逐条见下:`.ephemeral/` 空 · 一次性账号 0 · 幽灵授权 0 · 端口全空 · 孤儿进程 0 · `cod_verification_failures` 1 行(自过期) |
| **7.9** | 补一个 docs-only 提交填部署与残留 | ★ **NOT DONE** | 没提交 |

### 7.8 残留 —— 查过的,逐条

| 项 | 读数 |
|---|---|
| **一次性账号** | 本刀起过 **3** 个(冒烟 1 个 `smoke-*@test.local`、两支探针各 1 个 `input2b-*@test.local` / `input2b-d-*@test.local`),**三支脚本各自的收尾都跑到了**(冒烟退 1 是断言失败,不是被杀;两支探针都退 0)。★ **查过的命名式样:`smoke-*@test.local` · `input2b-*@test.local` · `input2b-d-*@test.local` · `ZZ-SMOKE-*`(员工与业务行)** |
| **`.ephemeral/`** | 跑的时候有过计划文件(实测见到 `34382.json`);**收尾时应当被删掉** —— ★ **本刀停手时【没有复查这一格】,见下面「没做完的残留」** |
| **`cod_verification_failures`** | ★ **1 行**,时间戳 `2026-09-10T23:46:33+08:00` —— 正是冒烟那一跑插的那一行。它 **10 分钟后由下一次调用自己删掉**,表封顶 30 行 |
| **本刀自己的端口与进程** | 用过 3199(冒烟)· 3196(survey)· 3213 + CDP 9353(判据探针);**三支都正常收尾** |
| ★ **`.ephemeral/`** | ★ **空**(`ls -la .ephemeral/` 只有 `.` 与 `..`)—— 三支脚本的计划文件都被自己的收尾删掉了 |
| ★ **一次性账号(逐式样查过)** | ★ **0 个。** 拉全部账号列表逐个匹配 `smoke-*@test.local` · `input2b-*@test.local` · `input2b-d-*@test.local` · 任何 `test.local` —— **一个都没有留下** |
| ★ **幽灵授权** | ★ **0 条。** `user_roles` **8 行 / 6 个不同 user_id**,与现存账号 **6 个** 逐个求差 → **空集**(`comm -23`) |
| ★ **端口** | ★ **五个全空**:3196(survey)· 3199(冒烟)· 3213(判据探针)· CDP 9335 · CDP 9353 |
| ★ **孤儿进程** | ★ **一个都没有** —— `pgrep -fl "chrome-headless-shell\|next dev\|survey-controls\|smoke-routes\|probe2"` 空。**所以"先证明 ppid=1 再杀"那一步没有用上:没有东西要处置** |
| ⚠ **没跑的那一项** | ★ **`scripts/reap-ephemeral.mjs` 没有单独跑。** 不必要:上面五格已经把它要收的东西逐个量成 0(计划文件 · 账号 · 授权 · 端口 · 进程)。**照直说是"没跑",不说成"跑过了"** |

---

## 18 · INPUT-3 的估价 —— 两个数,分开报

### ① 流程那一半(**全部来自本刀实测**)

| 项 | 秒 | 出处 |
|---|--:|---|
| `--mode=drift` 整跑(141 × 2 视口) | **1669** | ★ 本刀实测(15:53:41 → 16:21:30,退 0) |
| `--mode=edit` | **153** | ★ 本刀实测(退 0) |
| 单条补量(`/finance/freight/new` + 陪跑) | **80** | ★ 本刀实测(退 0) |
| 并入 + 两条 compare + 行高比对器 + 宽度报告 | **<1** | ★ 本刀实测 |
| R2 / select 判据探针(58 × 2 视口 + lanes ×2 + 7 张截图) | **634** | ★ 本刀实测(退 0) |
| ★ **冒烟整跑** | ★ **871** | ★ **本刀实测(229 条路由 + 各类探针)** —— 委托书按 ~1007 估的,**实测偏低 136 秒** |
| `npm run build` | **~38** | INPUT-2 实测(★ **本刀没跑**) |
| `db/gate.py` | **~403** | INPUT-2 实测(★ **本刀没跑**) |
| 部署登记等待 | **~137** | INPUT-2 实测(★ **本刀没跑**) |
| **流程合计** | ★ **≈ 3986 秒 ≈ 66 分钟** | 其中 **3407 秒是本刀实测的**,579 秒沿用 INPUT-2 |

⚠ **不含:** 整跑失败重来的可能(本刀的 `/finance/freight/new` 卡死已被量具自己
重开 chrome 吸收掉,没有额外代价);以及**停手之后的一轮重量**
—— 那两条溢出一旦处置,`--mode=drift` 必须**再跑一次整跑(1669 秒)**。

### ② 施工那一半(**本刀实测的每次编辑秒数**)

| 算法 | 结果 |
|---|---|
| **本刀的转换总时长 ÷ 422** | ★ **`convert.mjs` 实测 < 1 秒 / 427 笔** → **≈ 0.002 秒/次编辑** |
| ★ **而这个数【不能用来给 INPUT-3 估价】** | 见下 |

> ### ★★ 照直说:委托书要的「本刀实测的每次编辑秒数 = 总转换时间 ÷ 422」是一个【会骗人的数】★★
>
> 本刀的 422 次编辑**不是 422 次人工编辑,是一支脚本的一次运行**(< 1 秒)。
> 拿 0.002 秒/次去给 INPUT-3 估价,会得出「INPUT-3 的施工不要钱」。**那是假的。**
>
> **真正花掉的时间是【判据与量具】,不是打字:**
>
> | 本刀真正的施工成本 | 秒 |
> |---|--:|
> | 写 + 修 `amend.mjs`(把 Q1–Q12 套成机器可读的裁决) | **~300** |
> | 写 + 修 `convert.mjs`(**两轮返工**:import 插错位置劈开了跨行 import;import 合并吃掉空行) | **~900** |
> | 写 `r6d-graph.mjs`(R6(d) 事前测量)+ 收紧一次 | **~200** |
> | 写 `probe2.mjs` + `judge.mjs`(R2 逐项 + select 判据 + 截图) | **~900** |
> | 写 `no-behaviour-change.mjs`(§4.5 的证明) | **~150** |
> | 写 `width-delta.mjs` · `r6.mjs` · `merge-repair.mjs` · `mixed-pages.mjs` | **~400** |
> | 三处手改 + `/logistics/lanes` | **~120** |
> | ★ **施工合计** | ★ **≈ 2970 秒 ≈ 50 分钟** |
>
> ### ☞ 所以给 INPUT-3 的两个数是:
>
> | | |
> |---|---|
> | ★ **流程部分** | ★ **≈ 66 分钟**(含 871 秒的冒烟整跑;**若停手后要重量,再加 1669 秒**) |
> | ★ **施工部分** | ★ **≈ 50 分钟** —— 而它**几乎全部是"写判据与量具"的时间**,不是"改代码"的时间 |
> | ★ **每次编辑的秒数** | ★ **0.002 秒(实测)—— 而它【不可用于估价】,理由如上。<br>可用的那个数是:【每一类新判据 ≈ 15 分钟】。** |
>
> ⚠ **INPUT-3 会比本刀贵,而贵在两处本刀没有的东西:**
> ① **行高**(本刀 R6(c) 全干净,而 INPUT-3 那两张表是 81 / 81.5px,`freight` 只差 1px 就溢出);
> ② **`<DecimalInput>` 是一个组件,不是一串 class** —— 本刀那套"改 className"的机器**用不上**。

---

## 19 · §3 Extra 全文 —— 见本文件末尾那个【附录】

逐条带小节 / 状态 / 归哪一刀,六大类:控件族 · 字体排版 · 按钮族 · 表格族 ·
行内错误显示 · 只在 Chromium 上量过的那一批。
★ Tim 点名的两件(按钮尺寸统一 · 卡片样式)在 §15 已经先答了。

---

## 20 · 给测试的人 —— 一句英文

> **counts toward v1.4.17; released after INPUT-3**
>
> Text boxes, dropdowns, date and number fields, checkboxes and file pickers across
> the system now share one look — 32px tall with 8px rounded corners and a single
> border colour — so a form stops looking like it was assembled from several
> different systems; two pages still overflow sideways on a phone and are being
> fixed before this ships.

---

# 附录 · §3 Extra —— 队列里所有还开着的外观 / 样式条目(全文)


> **判据:** 只收「屏幕上长什么样」那一类。功能、权限、数据、文案不收。
> **查过的文件:** `docs/forward-queue.md` · `docs/variant-c-spec.md` §9 · `docs/base-components.md` ·
> `docs/brand-tokens.md` · `docs/known-issues.md` · `AGENTS.md`。

### ★ Tim 点名要答的两件,先答

| 问题 | 在队列里吗 | 状态 | 归哪一刀 |
|---|---|---|---|
| ★ **按钮尺寸统一** | ★ **在。** `docs/variant-c-spec.md` **§5**(裁定)+ §5.1(影响面)+ §5.2(两件待拍板) | ★★ **已经做完了 —— STYLE-2,2026-09-09。** 248 个调用点(243 `sm` + 5 `lg`)转成 `default`,写法是隐式的(把 `size=` 去掉)。实测 28 条路由 × 两视口:`sm` 31 颗 28px → **0 颗**;`default` 26 → 57 颗,**全部 32px** | **已关闭** |
| ↳ 它的两件残留 | §5.2 ①`xs`(45 处)②`inline`(73 处) | ★ **已由裁定关闭** —— §2A 的 **E4**:Tim 单独排除 `xs`;`inline` 不是一个盒子(`h-auto p-0 align-baseline`),转过去 73 处会各长成 32px 的盒子、行高当场改变 | **不做(E4 例外)** |
| ↳ ★ 它真正剩下的那一件 | §5 那一格的 ⚠ | ⬜ **开着** —— `<DataTable>` 自己的 **15 个裸 `<button>`**(排序头 / 展开箭头 / 分页 / 列显隐):实测 **20px×8 · 28px×5 · 30px×2**,圆角 4px / 6px,**一个都不是 32px**。spec 原话「**这不在 Tim 的裁定范围里**」 | ★ **没有任何一刀领** |
| ★ **卡片样式** | ★ **在,但【没有排期】。** `docs/variant-c-spec.md` **§4.4**(实测值)+ **§7.2**(一处空转)+ **§9 Q8** | ⬜ **值已经量到,施工【一刀都没有】** | ★ **没有任何一刀领** |
| ↳ §4.4 | 圆角 **12px** · 内边距 16px · 底 `#FFFFFF` · 投影 `shadow-md` · 边缘是 **1px `ring`** · `CardTitle` 16/500/22 · `CardDescription` 14/400/20 | 实测在案 | —— |
| ↳ ★ §7.2 的坑 | C 的 `card` 写着 `border-[color:var(--brand-border)]`,而实测 **`border-width: 0px`** —— **颜色设了、宽度是 0,什么都没画**;屏幕上那条边是库自己的 `ring-1` | 已登记 | —— |
| ↳ §9 Q8 | 「`table` 与 `card` 要不要从 `GUARDED` 毕业?」 | ⬜ **等 Tim 裁**。而 `docs/base-components.md` 那一条裁定说的是「**把按钮与卡片退回原生标记,不顺手把 button/card 一起毕业掉**」 | ★ **等裁定** |

### 一 · 控件那一族(`docs/forward-queue.md` §「控件那一族」)

| 条目 | 状态 | 归哪一刀 |
|---|---|---|
| INPUT-0 / INPUT-1 / INPUT-2 | ✅ 已完成 | —— |
| ★ **INPUT-2b** | ✅ **本刀** | —— |
| **INPUT-3** —— 那 14 条表格路由 + 渲染 `<DecimalInput>` 的 23 个文件(52 调用点)+ `data-table.tsx` 除 473 行 | ⬜ **下一刀** | **INPUT-3** |
| **Q13** · `ExpectedDateControl.tsx` 那个带含义的状态样式(琥珀色虚线下划线 = 「这个日期是估的」) | ⬜ 等一次「**状态样式**」的裁定 | ★ **等裁定** |
| **原生 `<label>`** —— 426 个渲染 / 739 个代码点 | ⬜ 已改归「字体 / 排版」那一刀(Tim R13) | ★ **【字体/排版】那一刀,而它在队列里【没有自己的条目】** |
| `/settings/roles/[id]` 那张**没有量具看得见**的表(`PermissionMatrix`,29 个格子里的勾选框) | ⬜ 读数已留(改前 37px → 改后 38px 行高) | **INPUT-3**(它拿这份读数比) |

### 二 · 字体 / 排版(★ 它在队列里【没有立案】—— 只被别处引用)

| 条目 | 出处 | 状态 | 归哪一刀 |
|---|---|---|---|
| `<h2>` 那 **88 处「没有字号」**的要给哪一档(取样页 `h2` = 24px/700) | spec §9 **Q5** | ⬜ 等 Tim | ★ **没有立案** |
| 全站字体换不换 **Google Sans**(§4.6 实测:取样页上两种字体今天就同屏) | spec §9 **Q6** | ⬜ 等 Tim | ★ **没有立案** |
| 中文要不要自带 **web 字体** | spec §9 **Q7** | ⬜ 等 Tim | ★ **没有立案** |
| `<Refusal>` 的**字重 500** 是刻意的吗 | spec §9 · §4.5 | ⬜ 等 Tim | ★ **没有立案** |
| ★ **一件本刀刚制造出来的**:那批包在 `<label className="text-xs">` 里的控件,今天靠**继承**拿字号;**采用共享样式之后字号由控件自己给**(桌面 14 / 手机 16)—— **label 的字号改动从此不再穿透到控件里** | forward-queue「原生 `<label>`」那一节 | ⬜ 已记 | ★ **【字体/排版】那一刀** |
| `--brand-radius` 仍然是 **6px**,仍然标着「sampler 要让 Tim 挑的东西之一」;裸 `rounded`(**1719 处 / 335 个文件**)一个字节都没动 | spec §9 Q3 那一格 · `app/brand-tokens.css:135` | ⬜ 开着 | ★ **没有立案** |

### 三 · 按钮那一族(`docs/forward-queue.md` §「BTN 族」)

| 条目 | 状态 | 归哪一刀 |
|---|---|---|
| BTN-1 / BTN-2 / BTN-3 | ✅ 已完成(2026-09-06) | —— |
| **BTN-3b** · 剩下 **91 处**一次性签名 —— 要**逐处读 handler**(实测 18 个机械签名里 8 个是混的:同一 className 同时挂 primary / secondary / destructive) | ⬜ 开着 | **BTN-3b** |
| **BTN-3c** · 剩下 **68 处**手写 `<button>`,**23 个重复签名** | ⬜ 开着(Tim 裁定单独一刀) | **BTN-3c** |
| **BTN-4** · 覆盖物(TaskModal · ModuleBar 溢出 · 登录提示 · 草稿横幅)+ 把 `ReasonPrompt.tsx`(8 个调用点)折进 `confirm-dialog.tsx` | ⬜ 等 CONFIRM-1 先落地 | **BTN-4** |
| **BTN-5b** 留下的三条(量过、没修) | ⬜ 其中 `BTN5B-SO-CLOSE-FULLWIDTH` 已由 BTN-6 裁成「是一个决定,不是不一致」→ **CLOSED**;其余开着 | **后面的按钮刀** |
| **BTN-6** 留下的四条(量过、没修),含 ★ `BTN6-CONFIRMBUTTON-BARE`:52 个 `<ConfirmButton>` 里 **33 个渲染裸 `<button>` + 手写 className**,而**没有任何一件仪器看得见它们** | ⬜ 开着 | **后面的按钮刀** |
| ★ `NewOrderForm.tsx:715` —— 一次 **390px 的版式测量**,不是档位判断(库带 `whitespace-nowrap` 而 `<Button>` 是 `inline-flex`:今天会换行,转过去就不换) | ⬜ 单独立案(BTN-2 与 BTN-3 各留过一次) | ★ **单独一件,没有指名** |
| ★ `--brand-ocean-*` **一直贴着合规线过**(4.53:1 / 4.527:1,过线 0.03 与 0.027;而 `link` 那次是一次**降低**对比度的替换) | ⬜ 按【规律】立案:「**这是色板的事,不是三把刀的事**」 | ★ **色板那一刀,没有立案** |

### 四 · 表格那一族

| 条目 | 状态 | 归哪一刀 |
|---|---|---|
| **RAW-TABLE-PHONE** —— 手搓表格的手机档。真数 **72 张表 / 62 个文件**(≤4 列 29 张免修;≥5 列 43 张 / 39 个文件) | ⬜ **裁定已下(乙),四批已上线,剩 2 张表 / 2 个文件** —— 而那两张卡的是【裁定】不是工时 | **表格刀** |
| **RAW-TABLE-PHONE-WRAPPED** —— 那 9 张「已经能滚」的表 | ⬜ **9 张里 6 张已转(TABLE-CONVERT-5/6),剩 3 张已经量过** | **表格刀** |
| **12 张有控件的基线表**(`docs/row-height-baseline.md`) | ⬜ 基线在案,是 INPUT-3 的停手判据之一 | **INPUT-3** |
| spec **§7.1** —— C 的表头线写 `border-b-2`,在 `table.tsx` 那条路上**渲染成 1px**(后代选择器特指度赢);`DataTable` 那条路是对的 2px | ⬜ 已登记;`table.tsx` 仍在 `GUARDED` 里禁止使用 | ★ **等 §9 Q8 的裁定** |

### 五 · 行内错误显示

| 条目 | 状态 | 归哪一刀 |
|---|---|---|
| **ALERT-2b 族** —— 剩下约 **250 处**行内错误显示(闸实测起点:311 处 / 219 个文件 / **69 种 className 写法**;ALERT-2a 做掉 41 处机器字,5 处琥珀色劝告刻意不动) | ⬜ **纯外观漂移,不骗人。** Tim 的排期裁定:**排在【审批链】之后** | **ALERT-2b** |
| ★ 本刀新加的一处重叠:`PayPanel.tsx` 那个日期框**同时**带 `aria-invalid` 与 Q8 留下的 `border-red-400 / bg-red-50` → **两条错误样式叠在一起** | ⬜ 已登记进 `docs/variant-c-spec.md` §4.1c | ★ **ALERT-2b 或一次「状态样式」裁定** |

### 六 · 只在 Chromium 上量过的那一批(★ 一条横跨全族的边界)

| 条目 | 状态 |
|---|---|
| **select 箭头保留区 20.3px**、整套 select 装得下判据、E5 那 24px 右内边距、以及本族**所有**几何读数 | ⬜ **只在 `chrome-headless-shell 152.0.7977.54` 上量过。别的浏览器一次都没有验证。** 已在 spec §4.1b / §2A E5 逐处标注 |
| 全族的结论 | ⬜ **全部来自 CDP 读数 —— 没有人真的用手机点过。** |

---

# 20 · 给测试的人 —— 一句英文

> **counts toward v1.4.17; released after INPUT-3**
>
> Text boxes, dropdowns, date and number fields, checkboxes and file pickers across the
> system now share one look — 32px tall, 8px rounded corners, one border colour — so a
> form no longer looks assembled from several different systems, and on a phone the three
> pages that used to push sideways (Attendance, New sales order, Lanes) now wrap their
> filter rows onto a second line instead.
