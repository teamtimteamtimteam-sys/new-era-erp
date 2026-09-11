# INPUT-3 交回报告 —— 控件族最后一刀(2026-09-11)

> ## ★ 屏幕上变了什么,一句话
> **那 14 条表格路由上的每一个输入框、下拉、日期、数字、多行框、勾选框、单选框与文件选择钮,
> 现在和系统其余部分长得一模一样(32px 高 · 8px 圆角 · 一种边框色),
> 而两条在手机上一直横着溢出去的页面(`/operation/processing/new` 416→194 · `/purchasing/payment-terms/new` 223→144)现在收了回来。**

| | |
|---|---|
| 开工 HEAD | `22d6d9459b879e8e7d16d1127d284cb4f4776012` = `origin/main`,树干净 |
| 轮次 | **ROUND 2**(round 1 停在停止闸,产出 `/tmp/INPUT-3-stopgate.md` 的 24 个问题;本轮执行 Tim 9/11 的答复) |
| ★ 站点 | **287**(268 A · 14 B · 5 C)· **36 个文件** |
| ★ R6 的结果 | **(a) 0 条长大 · (b) 0 张新横滚 · (c) 1 张(正是 Q1 裁过的例外,已证)· (d) 逐字未变** |
| ★ 判的范围 | **全仓库 141 条静态路由 × 2 视口**,两边读不到 **0 条** |
| ★ R2 逐项合规 | **接了模块并量到的 274 个 × 2 视口 —— 合 274 · 不合 0** |
| 量具改动 | 只 `scripts/check-row-height-baseline.mjs` 一支(Q17) |
| 迁移 | **零** |

---

## 0 · §1 开工闸与通读

| 项 | 结果 | 证据 |
|---|---|---|
| §1.1 HEAD = origin/main、树干净 | ★ **DONE** | `git rev-parse HEAD` 与 `origin/main` 三者相同 = `22d6d94…`;`git status --porcelain` 空。**exit 0**(01:00:16 UTC) |
| §1.2 round 1 的 12 件产物 + 14 张改前截图 | ★ **DONE** | 逐个 `-f` 核过,**一件不缺**;`/tmp/input3/shots-before/` **14 张 PNG** |
| §1.3 通读 | ★ **DONE** | 停止闸全文(1052 行)· INPUT-2 / INPUT-2b 交回报告 · spec §2A/§2A.2/§4.1/§4.1a/b/c/§6/§9 · forward-queue 两节 · known-issues · AGENTS 四节 · row-height-baseline §1–§5 · 5 个源文件 · `check-row-height-baseline.mjs` 全文 · 两支量具抬头 |

### §1.4 —— 本块里被我当成【阈值】用的数,逐条重量

> **规矩(AGENTS.md):委托书里的数一个都不许直接引用。下面每一条都标 confirmed / wrong / not re-measured。**

| # | 委托书里的数 | 判定 | 重量的方法与结果 |
|--:|---|---|---|
| 1 | HEAD `22d6d94…` = origin/main,树干净 | ★ **confirmed** | `git rev-parse` ×2 + `git status --porcelain` |
| 2 | round 1 的 14 张改前截图 | ★ **confirmed** | `ls` 数到 14 张,逐张有字节 |
| 3 | 比对器「12 张含控件的基线表 / 编辑态 2 张」 | ★ **confirmed** | 比对器自己打印「比过的表:12 / 基线 12 张;编辑态 2 / 2 张」 |
| 4 | 基线 §6.3「7 条整页溢出路由 / 11 张横滚表」 | ★ **confirmed 为基线值;今天是 6 条 / 12 张** | 比对器打印「整页溢出:基线 7 条,读数 6 条」;横滚表本刀实测**改前 12 张**(基线那天之后多了 `/inbound #0`,**不是本刀造成的**) |
| 5 | `/operation/processing/new` 改前 390px 溢出 **416** | ★ **confirmed** | 本刀 `p-repair.mjs` 实测转换后 435 → 修复后 **194**;改前那个 416 与 round 1、与 `docs/row-height-baseline.md` §4.1 三处一致 |
| 6 | `/purchasing/payment-terms/new` 改前 **223** | ★ **confirmed** | 同上,转换后 247 → 修复后 **144** |
| 7 | `/finance/freight/new` 壳 326 / 内容 **327**、范围 1 | ★ **confirmed** | 改后读数 330 / 范围 4;§5.4 把框按回 13×13 之后**回到 327** |
| 8 | ScaleEditor 四个框渲染 **159 / 135 / 135 / 135** | ★ **confirmed,两个视口逐字相同** | Q14 步骤(1) 的专门读数,见 §3 |
| 9 | `<DecimalInput>` **52 个调用点 / 23 个文件** | ★ **confirmed** | 转换器按行定位到 52 个;改后重扫仍是 52 |
| 10 | `data-table.tsx` 三枚勾选框在 **295 / 494 / 640** | ★ **confirmed(本 commit)** | 按内容定位后读行号,与 round 1 相同;**已在 spec 与 forward-queue 就地更正**(Q24) |
| 11 | 箭头保留区 **20.3px** | ○ **not re-measured** | round 1 已自量(20.06–20.75,均值 20.34)。★ **本轮沿用 20.3 作判据,没有再量一次** |
| 12 | drift 冷跑 **782 秒**(round 1 实测) | ★★ **wrong —— 本轮实测 1037 秒** | 01:15:37 → 01:32:54 = **1037s**,`DRIFT_OWN_EXIT=0`。☞ 三个数各不相同(1669 / 782 / 1037),**已登记进 `docs/known-issues.md`** |
| 13 | 冒烟 **871 秒** | ○ **not re-measured 为估价输入;本轮自己跑了一次,读数见 §7.3** | Q20 说不为估价单独跑;而 §F 要求真跑一次,那一次的读数在 §7.3 |
| 14 | 「`min-w-0` 让下拉 364 → 70px」 | ○ **not re-measured** | 与 round 1 同:**当禁令接受,不当可引用的读数**。本刀**一次都没有用过** `min-w-0` / `max-w-full` |
| 15 | `<DataTable>` 自己的按钮「约 15 个」 | ★ **confirmed 为渲染计数;代码点是 4** | `grep -c '<button' app/components/ui/data-table.tsx` = **4**。★ 三档高度 20/28/30px **本刀没有重量** —— 已照直登记进「合并的小件那一刀」 |
| 16 | 「36 个控件从 `tableC` 继承 15px」 | ★★ **wrong —— round 1 实测 51 个** | 本轮沿用 round 1 的 51(它是在**本刀这棵树**上量的);那个 36 来自 INPUT-0 的另一个 HEAD。**已登记进 forward-queue 的字体刀** |

---

## 1 · §2 的裁定(R1–R6)与 §3 的答复(Q1–Q24)—— 逐条 DONE / NOT DONE

> **判据照委托书 §8:「代码里有」不算 done,「操作员在屏幕上看得见」才算。**

### R1–R6

| 条 | 状态 | 证据 |
|---|---|---|
| **R1** 一处样式模块;手搓控件保持原生,只从 className 拿样子 | ★ **DONE** | 287 个站点**一个都没有换组件**;`<Input>` / `<Textarea>` 的 class 串**逐字未变**(见 R6(d)) |
| **R2** 只用模块已有的值 + Q11 抄来的那一条 hover | ★ **DONE** | §5.6 实测 **274 × 2 视口全合**;唯一的新增是 `hover:file:bg-primary-hover`,**逐字抄自 `button.tsx` 的 `variant.default`**(见 Q11) |
| **R3** 宽度类一个都不动(两处例外) | ★ **DONE** | 转换器的 keep 清单里宽度类**原样保留**;动过的只有 ScaleEditor 四处死宽度(Q14)与 4 个 `flex-wrap`(R6 的修复) |
| **R4** `/login` · `<label>` · 按钮 · hidden · `data-table.tsx:473` 不动 | ★ **DONE** | `/login` 与 473 行**一个字节都没碰**;`<label>` 0 处;`type="hidden"` 37 个**全部排除**;`<button>` 0 处 |
| ↳ **E6 在本刀有没有站点** | ★ **DONE —— 0 个,照直说** | 全刀 287 个站点里 `min-h-[48px]` **0 处**;`<DecimalInput>` 52 个调用点也**一个都没有**。**E6 这一条在本刀是空的** |
| **R5** 剥/留清单、字色、三元表达式、两张清单都有则留赢 | ★ **DONE** | 「两张清单都没有」的 3 条 class 由 Tim 在 Q9/Q10/Q11 裁掉 → **剩 0 条**;字色站点 0 处、inline style 站点 0 处 |
| **R6** 停止条件 | ★ **DONE** | 见下面 §4 —— (a)(b)(d) 一次都没响,(c) 响一次且是裁过的例外 |

### Q1–Q24 —— Tim 9/11 的 24 条答复,逐条

| # | 答的是什么 | 状态 | 证据 / 读数 |
|--:|---|---|---|
| **Q1** | freight 的滚动范围增长走 R6(c) 例外,须证明**全部**来自框的尺寸 | ★ **DONE** | §5.4 的归因证:390px 上把**只有**那 15 个勾选框按回 13×13,内容宽 **330 → 327**(= 改前值)、范围 **6 → 3**(探针口径,= 改前值);还原后回到 330。1440px 上那张表**仍然不横滚**(范围 0 → 0)。**增长 100% 由框的尺寸解释** |
| **Q2** | payment-terms 的格内 `flex-wrap`,按次序试 (1) 再 (2) | ★ **DONE —— 用的是选项 (1)** | 加在 `TemplateForm.tsx` 那个**住在 `<td>` 里的 `<div className="flex items-center gap-2">`** 上。390px 溢出 **247 → 144**(验收 ≤223 ✓)· 1440px **0 → 0** ✓;**行高 63 → 77**;★ **没有任何一个圈和它的字分家**(两个 `<label>` 自己仍是 `nowrap`,labelH 20 = lineHeight 20,圈与字同行)。截图 `/tmp/input3/shots-extra/q2-payment-terms-390.png`。**选项 (2) 没有用上** |
| **Q3** | processing/new 的三个 `flex-wrap` 可以做 | ★ **DONE** | `NewProcessingForm.tsx` 三个行容器(两个 `div.flex gap-2 items-start` + 一个 `div.flex items-center gap-2`,按类串与元素定位)各加 `flex-wrap`。390px **435 → 194**(验收 ≤416 ✓,而且**比改前的 416 小一半还多**)· 1440px **0 → 0** ✓。★ **这是一次会被看见的改善** |
| **Q4** | R6 按全仓库 141 条判 | ★ **DONE** | `--mode=drift` 141 条 × 2 视口;**两个视口读不到 0 条** |
| **Q5** | 转列显隐勾选框;spec §6 那一句就地更正;不碰 `app/brand-sampler/` | ★ **DONE** | 已接 `CONTROL_CHECKBOX`;`docs/variant-c-spec.md` §6 那一句**保留原文 + 划掉 + 标明谁/哪天/什么方法**;`app/brand-sampler/` **一个字节都没有改**(`git diff --stat` 里没有这个目录) |
| **Q6** | 把 `<details>` 点开再量那 13 枚 | ★ **DONE** | 两个视口各一次:`<details>` 2 个全部点开,**13 枚全部 16×16 · 圆角 4px · 边框 1px · `appearance: none`**;边框与底都是 **#007FAD** —— 因为**13 列默认全部显示 = 全部勾上**,而选中态的边框本来就是品牌蓝(判据认得这一条)。**13 枚只有一种形态**。截图两张 |
| **Q7** | `/hr/kpi/score` 与 `/me` 编辑态当 UNMEASURED,点名 15 个 | ★ **DONE** | `--mode=edit` 两个视口各一次:两页**候选「编辑」钮都是 0 颗**,`clickHadNoEffect`。15 个站点逐条见 §5.9。★ **没有放宽点击判据** |
| **Q8** | 接受 DecimalInput 表内/表外的源码读法(22 / 30) | ★ **DONE** | **照直标:源码读出来的**,不是量出来的。首屏量到的那一部分另行报出(§5.6 的 274 个里含 DecimalInput 调用点) |
| **Q9** | `read-only:bg-gray-100` 留,登记为唯一一个 | ★ **DONE** | `PayrollGrid.tsx` 那个 `readOnly` 月份框写成 `` `${CONTROL_INPUT} read-only:bg-gray-100` ``;判据认得它(§5.6 判它合规);已登记进 forward-queue 的「合并小件那一刀」 |
| **Q10** | `base-pressable` 留 | ★ **DONE** | `data-table.tsx` 两枚勾选框写成 `` `${CONTROL_CHECKBOX} w-4 base-pressable` `` |
| **Q11** | 读 Button default;有 hover 底色就抄 | ★ **DONE —— 抄了** | `button.tsx` 的 `variant.default` 写着 **`hover:bg-primary-hover`** → 模块加 **`hover:file:bg-primary-hover`**(完整字面量)。★ **实测两边逐字相同:** 文件钮 **#007FAD → #00709D**;一颗真的 default 档 `<Button>`(`/hr/payroll/new`)**#007FAD → #00709D**。★ **不动 `<Input>`/`<Textarea>`**(它们发的是 `INPUT_FILE_RESET`)——**两条组件串逐字未变**。两处 INPUT-3 文件输入的 `hover:file:bg-blue-700` **已去掉**。T3 名单见 §6 |
| **Q12** | 多行框剥 `min-h-*`,落到 64px | ★ **DONE** | 13 个多行框:剥掉 `min-h-[3.5rem]`(×2,ScoreEditor 的 `ta` 常量)· `min-h-14` · **`min-h-24`**;去掉 **8 个 `rows=`**。★ **`app/me/MySelfAssessmentPanel.tsx` 那个自评框 96px → 64px(矮 32px)** —— 空着时矮,写了字之后不矮(`field-sizing: content`) |
| **Q13** | CostSettlePanel:75 留错误类、改写、登记、不调和 | ★ **DONE** | 改写成 `` className={`${CONTROL_INPUT} block` + (value === '' ? ' border-red-400 bg-red-50' : '')} ``。★ 实测那个框空值时**边框渲染 #B75B53**(模块自己的 `aria-invalid:border-destructive` 压过了 `border-red-400`)—— **两条错误样式确实叠着,本刀没有调和**,已与 `PayPanel` 那一条**并排登记** |
| **Q14** | ScaleEditor 分两步 | ★ **DONE** | ①**只删四处死宽度**(`w-32`/`w-40`/`w-40`/`w-20`,留 `w-full`)→ 四个框仍然渲染 **159 / 135 / 135 / 135**,**两个视口逐字相同、与转换前完全一致** → **前提成立**;②再转换 → 宽度变化按 R6 报出(`/hr/reviews/scale` 首屏 8 个成员 **+53 ~ +69**) |
| **Q15** | `cn(CONTROL_INPUT, className)`,调用点赢 | ★ **DONE** | `DecimalInput.tsx` 第 73 行;`cn` 从 `@/lib/utils` import。★ 受控小数的行为**一个字节没动**(正则、中间态、hidden 伴生框、`parseDecimal` 全部原样)。52 个调用点此后只留自己的宽度/对齐类 |
| **Q16** | 51 个继承 15px 的控件改用标准字号;记进字体刀 | ★ **DONE** | 转换之后它们由控件自己给字号;已在 `docs/forward-queue.md` **`<label>` 那一节旁边**加了一整格,与 label 的注记**并排** |
| **Q17** | 改比对器:横向/竖向分桶 + `--row-height=stop\|report` | ★ **DONE** | 见 §2。**五条自证全绿** |
| **Q18** | 陪跑路由照 R6(a) | ★ **DONE** | 本轮需要补量的是 `/purchasing`(phone 卡死),用 `--only=/purchasing,/tools/pricing/calculator`。★ **前缀匹配确认过:实际跑了 8 条**(7 条 `/purchasing*` + 陪跑 1 条),**并入时只替换 `/purchasing` 一条,其余 7 条读数丢掉** |
| **Q19** | 把 drift 冷跑的差异登记进 known-issues | ★ **DONE** | 新条目 `INPUT3-DRIFT-COST-UNEXPLAINED`。★ **而本轮又量出第三个数:1037 秒** —— 三个数(1669 / 782 / 1037)都写进去了,**不挑一个** |
| **Q20** | 接受 871 秒作估价,不为估价单独跑 | ★ **DONE** | 没有为估价跑冒烟;§F 要求的那一次真跑见 §7.3 |
| **Q21** | 行高表,带 round 1 的预测 | ★ **DONE** | 见 §5。**12 张里预测中了 11 张** |
| **Q22** | 不修有宽度类的下拉,登记 20 颗 | ★ **DONE** | 一颗都没修。已写进 forward-queue「合并小件那一刀 → ③」,**6 种被截的形状逐个列了短多少**,并加了**双向指针**。★ **而本刀把它重量了一遍,读数变坏了 —— 照直报在 §7** |
| **Q23** | 14 条之外的可见改动按 T3 列出 | ★ **DONE** | **7 条路由**(量出来的,不是推的)+ **6 条文件钮多出 hover 的已上线路由**。见 §6 |
| **Q24** | 四处数字就地更正,不动交回报告 | ★ **DONE** | spec §2A.2(行号)· spec §6(13 枚 13×13)· forward-queue(freight 的 15 枚归因 · DataTable 那批的尺寸 · 三个行号 · ScaleEditor 行号)。**`docs/handbacks/INPUT-2.md` 一个字节都没动** |

---

## 2 · §4.2 —— 比对器(Q17),以及它的五条自证

**改的只有 `scripts/check-row-height-baseline.mjs` 一支,`scripts/` 里别的一个字节都没动。**

| 改了什么 | |
|---|---|
| 硬差别拆两桶 | **横向** = 整页溢出新增/长大 · 已裁定横滚的表多出范围 · **滚动壳内容宽** · 表不见了/基线里没有(含编辑态的同名项);**竖向** = 表头高 · 行数 · 最大行高(+ 编辑态那三项) |
| `--row-height=stop\|report` | **默认 `stop`** —— 此前几刀的行为逐字不变。`report` 时竖向**另起一段打印、不影响退出码**;★ **横向任何档位下都退 1** |
| 认不出的 `what` | **一律算横向** —— 宁可多退一次 1,**不许静默降级** |
| ★ 另修一处**本刀自己造出来的**问题 | 基线文档新增 §7 之后全文有 **6 个** ```json 块,而本支断言「正好三个」→ 会当场退 2。改成**先按小节切、再取块**(`--baseline-heading=`,默认「机读块」= §6),**那条断言原样保留** |

### 五条自证(全部在动 `app/` 之前跑过一遍,改完 §7 之后**又跑了一遍**)

| 证 | 期望 | 实测 |
|---|---|---|
| ① 默认档 · 未改动的改前读数 | 与**改量具之前**的输出**逐字相同**、退 0 | ★ `diff` **exit 0**(逐字相同)· `P1_OWN_EXIT=0` |
| ② 一个行高被改过的副本(73 → 75) | `stop` 退 1 / `report` 退 0,两档都要**把差别打出来** | ★ `P2A=1` · `P2B=0`,两档都打印了「`/hr/payroll/new #0`:最大行高 73 → 75」 |
| ③ 一个滚动壳内容宽被改过的副本(740 → 743) | **两档都退 1** | ★ `P3A=1` · `P3B=1` |
| ④ `check-instrument-selfproof` | 仍然绿 | ★ `P4=0` —— **36 支量具都写了瞄准线;其中 23 支(构建链里的,含本支)带覆盖断言** |
| ⑤(新增)小节切法自己 | 指错小节要退 2;指 §7 要跑得通 | ★ 指一个不存在的小节 **退 2** 并点名;★ 拿改后读数对 §7 比 → **退 0**(§7 是一份**用得起来**的基线,它对自己自洽) |

---

## 3 · §4.3 —— ScaleEditor 步骤(1):四处死宽度确实是死的

| 视口 | 四个框的渲染宽 | 与 159/135/135/135 |
|---|---|---|
| phone 390 | **[159, 135, 135, 135]** | ★ **逐字相同** |
| desktop 1440 | **[159, 135, 135, 135]** | ★ **逐字相同** |

**判词:`w-full` 赢,四个 `w-*` 是死的 —— 删掉它们,一个像素都没有动。**
（`SCALE1_VERDICT=PASS`,`SCALE1_OWN_EXIT=0`,18 秒。)
**步骤(2) 的转换之后**,`/hr/reviews/scale` 首屏 **8 个成员的宽度变了(+53 ~ +69)** —— 按 R6「报告,不停手」。

---

## 4 · §5.3 —— R6 (a)–(d) 的结果

### R6(a) · 390px 整页横向溢出 —— ★ **0 条新增或长大**

| 视口 | 走到的路由 | 变了 | ★ 长大 | 变小 |
|---|--:|--:|--:|--:|
| phone 390 | **141** | 2 | ★ **0** | **2** |
| desktop 1440 | **141** | **0** | ★ **0** | 0 |

**两条变小的,都是 Tim 点过头的修复:**

| 路由 | 改前 | 转换后 | ★ 最终 | 1440px |
|---|--:|--:|--:|---|
| `/operation/processing/new` | **416** | 435 | ★ **194** | 0 → 0 |
| `/purchasing/payment-terms/new` | **223** | 247 | ★ **144** | 0 → 0 |

☞ **1px 复量规则:一次都没有用到** —— 没有任何一条路由长大 1px(长大的条数是 0)。

### R6(b) · 不横滚的表开始横滚 —— ★ **0 张**

390px 上自己横滚的表:**改前 12 张 / 改后 12 张,逐条是同一批**(新出现 0 · 消失 0)。

### R6(c) · 已横滚的表多出滚动范围 —— **1 张,而它是 Q1 裁过的例外**

| | 改前 | 改后 |
|---|--:|--:|
| `/finance/freight/new` #0 内容宽 | **327** | **330** |
| 滚动范围(drift 口径) | **1** | **4** |

**§5.4 的归因证(390px,仓库外探针):**

| 步骤 | 内容宽 | 滚动范围(探针口径) |
|---|--:|--:|
| 改后读数 | **330** | **6** |
| ★ 只把那 15 个勾选框按 inline style 设回 13×13,等 500ms | ★ **327** | ★ **3** |
| 还原 | **330** | **6** |

★ **内容宽回到了改前那个 327,滚动范围回到了改前那个值 —— 增长【全部】由框的尺寸解释。**
★ **1440px:那张表改前改后都不横滚(范围 0 → 0),按回 13×13 也是 894 → 894。**
☞ 那 15 个框是**一处**手搓 `type="checkbox"` 在 `batches.map` 里渲染 15 次(**不是 `<DataTable>` 的 selection 框** —— 那条归因错误已在 forward-queue 就地更正)。

### R6(d) · `<Input>` / `<Textarea>` 的 class 串 —— ★ **逐字未变**

用 `git show HEAD:app/components/ui/control-style.ts` 取原串,与工作区逐段 `diff`:
**`INPUT_COMPONENT_CLASS` 与 `TEXTAREA_COMPONENT_CLASS` 两段 diff 都是空的。**
☞ 机制上也成立:它们发的是 `INPUT_FILE_RESET`,而 Q11 的 hover 加在 `CONTROL_FILE_BUTTON` 上 —— **不是同一条**。

### 比对器(§5.2)

| 跑的是什么 | 退出码 | 读数 |
|---|---|---|
| `--mode=compare`(drift,改前 vs 改后) | **0** | 成员 **多出 0 · 少掉 0 · 值变 645**(两视口合计);「✓ 这一条作数」 |
| `--mode=compare`(edit) | **0** | 同样「作数」 |
| ★ **`check-row-height-baseline.mjs --row-height=report`(对着 `docs/row-height-baseline.md`)** | **1** | ★ **竖向 9 处(报告,不影响退出码)· 横向 2 处 —— 而那 2 处是【同一个】`/finance/freight/new #0`**(滚动壳内容宽 327→330 与滚动范围 1→4 的两种说法)。**没有任何【别的】横向差别** —— 照 Q17 的字面,那一项由 Q1 + §5.4 的证接住 |
| 同一份读数在默认档(`stop`) | **1** | 两桶都算数,合计 11 处 —— **作对照用,说明开关确实在起作用** |

★ **这一行照委托书 §5.2 单独报出来:比对器退 1,而退 1 的【唯一】原因是那一张裁过的表。**

---

## 5 · §5.3 Q21 —— 行高表:改前 / round 1 的预测 / 改后实测

### 390px(那 12 张「格子里有控件」的表)

| 路由 | # | 行 | 表头高 前→后 | 最大行高 改前 | round 1 预测 | ★ 改后实测 | 判定 | 预测中了吗 |
|---|--:|--:|---|--:|--:|--:|---|---|
| `/finance/freight/new` | 0 | 15 | 42.42 → 42.42 | 85.77 | 85.77 | **85.77** | 不变 | ✓ 逐字命中 |
| `/finance/fx/bulk` | 0 | 7 | 97 → 97 | 39 | 41 | **41** | ★ 变高 | ✓ 逐字命中 |
| `/finance/processing-costs` | 0 | 5 | 63.84 → 63.84 | 81.5 | 81.5 | **81.5** | 不变 | ✓ 逐字命中 |
| `/finance/processing-costs` | 1 | 4 | 63.84 → 63.84 | 81.5 | 81.5 | **81.5** | 不变 | ✓ 逐字命中 |
| `/hr/payroll/new` | 0 | 7 | 57 → 57 | 73 | 73 | **73** | 不变 | ✓ 逐字命中 |
| `/operation/orders/new` | 0 | 5 | 37 → 37 | 47 | 49 | **49** | ★ 变高 | ✓ 逐字命中 |
| `/operation/orders/new` | 1 | 3 | 97 → 97 | 47 | 49 | **49** | ★ 变高 | ✓ 逐字命中 |
| ★ `/purchasing/payment-terms/new` | 0 | 1 | 41 → 41 | 63 | 63 | **77** | ★ 变高 | ✗ **预测 63,实测 77** |
| `/sales/quotes/new` | 0 | 5 | 42.42 → 42.42 | 52.92 | 53.5 | **53.5** | ★ 变高 | ✓ 逐字命中 |
| `/tools/pricing/calculator` | 0 | 7 | 42.42 → 42.42 | 60.92 | 53.5 | **53.5** | ★ **变矮** | ✓ 逐字命中 |
| `/tools/pricing/formulas/new` | 0 | 7 | 42.42 → 42.42 | 60.92 | 53.5 | **53.5** | ★ **变矮** | ✓ 逐字命中 |
| `/tools/pricing/metal-prices/bulk` | 0 | 7 | 42.42 → 42.42 | 128.61 | 128.61 | **128.61** | 不变 | ✓ 逐字命中 |

> ### ★★ 预测对账:**12 张里中了 11 张,逐字。**
> 唯一没中的是 `/purchasing/payment-terms/new`(**63 → 77**,预测 63)——
> **那 14px 来自 Q2 授权的那次格内 `flex-wrap`(选项整块换到第二行),而 round 1 的预测器里【没有】那次修复。**
> ☞ **预测器本身没有错**:它预测的是「只转换、不修复」那一态,而那一态实测就是 **63**(`p-repair.mjs` 的 `after-convert` 读数)。

### 1440px(同一批表)

| 路由 | # | 表头高 前→后 | 最大行高 前→后 | 判定 |
|---|--:|---|---|---|
| `/finance/freight/new` | 0 | 42.42 → 42.42 | 42.92 → **42.92** | 不变 |
| `/finance/fx/bulk` | 0 | 37 → 37 | 39 → **41** | ★ 变高 |
| `/finance/processing-costs` | 0 | 42.42 → 42.42 | 41.5 → **41.5** | 不变 |
| `/finance/processing-costs` | 1 | 42.42 → 42.42 | 41.5 → **41.5** | 不变 |
| `/hr/payroll/new` | 0 | 37 → 37 | 39 → **41** | ★ 变高 |
| `/operation/orders/new` | 0 | 37 → 37 | 47 → **49** | ★ 变高 |
| `/operation/orders/new` | 1 | 37 → 37 | 47 → **49** | ★ 变高 |
| `/purchasing/payment-terms/new` | 0 | 41 → 41 | 51 → **49** | ★ 变矮 |
| `/sales/quotes/new` | 0 | 42.42 → 42.42 | 52.92 → **53.5** | ★ 变高 |
| `/tools/pricing/calculator` | 0 | 42.42 → 42.42 | 60.92 → **53.5** | ★ 变矮 |
| `/tools/pricing/formulas/new` | 0 | 42.42 → 42.42 | 60.92 → **53.5** | ★ 变矮 |
| `/tools/pricing/metal-prices/bulk` | 0 | 42.42 → 42.42 | 60.92 → **53.5** | ★ 变矮 |

### 编辑态(`<EditableTable>`,两条走得到的路由)

| 视口 | 路由 | 表内控件 前→后 | 最大行高 前→后 | 判定 |
|---|---|---|---|---|
| phone | `/hr/leave/types` | 12 → 12 | 229 → **271** | ★ **变高 +42** |
| phone | `/hr/reviews/scale` | 14 → 14 | 255 → **307** | ★ **变高 +52** |
| desktop | `/hr/leave/types` | 12 → 12 | 114.41 → **114.41** | 不变 |
| desktop | `/hr/reviews/scale` | 14 → 14 | 69.5 → **89.5** | ★ 变高 +20 |

> ☞ **编辑态那两行本来就比只读行高一个数量级**(基线 §3 早写着),
> 所以这里的 +42 / +52 在屏幕上**不像 +42px 那么显眼** —— 它是一行 229px 变成 271px。

### 截图(改前 / 改后,**同一支量具、同一种取景**)

| # | 路由 · 表 · 态 | 改前 | ★ 改后 |
|--:|---|---|---|
| 01 | `/finance/freight/new` #0 首屏 | `/tmp/input3/shots-before/before-01-finance_freight_new-t0-first.png` | `/tmp/input3/shots-after2/after-01-finance_freight_new-t0-first.png` |
| 02 | `/finance/fx/bulk` #0 首屏 | `before-02-finance_fx_bulk-t0-first.png` | `after-02-finance_fx_bulk-t0-first.png` |
| 03 | `/finance/processing-costs` #0 首屏 | `before-03-…-t0-first.png` | `after-03-…-t0-first.png` |
| 04 | `/finance/processing-costs` #1 首屏 | `before-04-…-t1-first.png` | `after-04-…-t1-first.png` |
| 05 | `/hr/leave/types` #0 **编辑态** | `before-05-hr_leave_types-t0-edit.png` | `after-05-hr_leave_types-t0-edit.png` |
| 06 | `/hr/payroll/new` #0 首屏 | `before-06-…` | `after-06-…` |
| 07 | `/hr/reviews/scale` #0 **编辑态** | `before-07-hr_reviews_scale-t0-edit.png` | `after-07-hr_reviews_scale-t0-edit.png` |
| 08 | `/operation/orders/new` #0 首屏 | `before-08-…-t0-first.png` | `after-08-…-t0-first.png` |
| 09 | `/operation/orders/new` #1 首屏 | `before-09-…-t1-first.png` | `after-09-…-t1-first.png` |
| 10 | `/purchasing/payment-terms/new` #0 首屏 | `before-10-…` | `after-10-…` |
| 11 | `/sales/quotes/new` #0 首屏 | `before-11-…` | `after-11-…` |
| 12 | `/tools/pricing/calculator` #0 首屏 | `before-12-…` | `after-12-…` |
| 13 | `/tools/pricing/formulas/new` #0 首屏 | `before-13-…` | `after-13-…` |
| 14 | `/tools/pricing/metal-prices/bulk` #0 首屏 | `before-14-…` | `after-14-…` |

★ **改后那 14 张是用 round 1 自己的 `shots3.mjs` 拍的**(整份复制,只改输出目录与文件名前缀),
所以取景逻辑(clip = 那张表的滚动壳矩形 + 4px,页面坐标)**逐字相同**;
**14 张的编号、路由、表序号、状态与 round 1 一一对上,格子里的控件数也一一对上**(15 / 21 / 6 / 5 / 35 / 10 / 12 / 5 / 15 / 7 / 7 / 7)。
⚠ **一处照直说的改动:** 那支脚本的「目标控件」判据原本是「**还没接模块的**控件」——
改后每个控件都接了模块,照原样跑只拍得出 6 张。**我把那一句改成「格子里有控件」,取景逻辑一个字节都没动。**

★ **§5.8 要的另外两张(390px 视口取景):**
`/tmp/input3/shots-after/after-15-operation_processing_new-t0-first.png` ·
`/tmp/input3/shots-after/after-16-purchasing_payment-terms_new-t0-first.png`
(这一组 16 张用的是**视口取景**,与上面那 14 张的**表格取景**是两种,两组都留着。)

---

## 6 · 控件宽度的变化(R6:报告,不停手)与 T3

### 成员名单:**2112 → 2112,多出 0 · 少掉 0**(两视口各 1056)

| 视口 | 宽度变了的成员 | 签名变了的成员 | 宽度变了的路由 |
|---|--:|--:|--:|
| phone 390 | **132** | **280** | 20 条 |
| desktop 1440 | **182** | **281** | 19 条 |

**变化最大的几条(phone):** `/finance/freight/new` 22 个(−4 ~ +10)·
`/tools/pricing/formulas/new` 14 个(**+3 ~ +180.88**)· `/purchasing/orders/new` 13 个(−4 ~ +31)·
`/hr/reviews/scale` 8 个(**+53 ~ +69** —— ScaleEditor 那四个删掉死宽度的框在里面)。
**desktop 最大的一处是 `/operation/processing/new` +103。**

### T3(Q23)—— 14 条之外,**7 条**路由的控件在屏幕上变了样

判据是 Tim 2026-09-11 的 T3:**那条路由的基线表四个字段与它的 390px 整页溢出都没有变。**

| 路由 | 签名变了(phone / desktop) | 表有变化 | 整页溢出 |
|---|--:|---|---|
| `/purchasing/orders/new` | 17 / 17 | **0 张** | 没变 |
| `/finance/journal/new` | 14 / 14 | **0 张** | 没变 |
| ★ `/operation/processing/new` | 12 / 12 | **0 张** | ★ **416 → 194**(变小 —— Tim 在 Q3 点的头) |
| `/finance/bank/import` | 9 / 9 | **0 张** | 没变 |
| `/finance/expenses/new` | 9 / 9 | **0 张** | 没变 |
| `/finance/payments/new` | 7 / 7 | **0 张** | 没变 |
| `/finance/invoices/new` | 6 / 6 | **0 张** | 没变 |

**七条全部满足 T3 的条件 —— 不是范围泄漏。**

### T3 之二(Q11)—— **6 处已上线的文件选择钮从此有 hover**

`hover:file:bg-primary-hover`(逐字抄自 `button.tsx` 的 `variant.default`)落在这些路由上:

| 路由 | 来自哪个文件 |
|---|---|
| `/settings/import` | `app/settings/import/ImportForm.tsx` |
| `/finance/company` | `app/finance/company/CompanyProfileForm.tsx` |
| `/materials/[id]/edit` | `app/materials/[id]/edit/AttachmentsPanel.tsx` |
| `/suppliers/[id]/edit` | `app/suppliers/[id]/edit/AttachmentsPanel.tsx` |
| `/sales/customers/[id]/edit` | `app/sales/customers/[id]/edit/AttachmentsPanel.tsx` |
| `/finance/receivables/[saleId]` · `/finance/payments/[id]` · `/finance/expenses/[id]` · `/finance/payables/[batchId]` | `app/components/finance/FinanceAttachmentsPanel.tsx` |

★ **它只加了一个【悬停时变深一点】的反馈,静止态一个像素都没动**(#007FAD 逐字不变)。

---

## 7 · §5.5–§5.7 的四项额外读数

### Q6 · `/brand-sampler` 的 13 枚列显隐勾选框(`<details>` **点开之后**)

| 视口 | `<details>` | 枚数 | 尺寸 | 圆角 | 边框 | `appearance` | 形态种数 |
|---|--:|--:|---|---|---|---|--:|
| phone 390 | 2 个(全部点开) | **13** | **16×16** | **4px** | **1px #007FAD** | **none** | ★ **1 种** |
| desktop 1440 | 2 个(全部点开) | **13** | **16×16** | **4px** | **1px #007FAD** | **none** | ★ **1 种** |

★ **边框是 #007FAD 而不是 #62738C,因为那 13 列默认全部显示 = 13 枚全部勾上** ——
而选中态的边框本来就是品牌蓝(`checked:border-primary`)。**判据认得这一条,它不是一处不合规。**
截图:`/tmp/input3/shots-extra/q6-brand-sampler-{phone,desktop}.png`。
☞ **转换之前它们是 13×13、`appearance: auto`** —— spec §6 那一句已就地更正。

### indeterminate · `/finance/processing-costs`

**第一步 —— 先证「点一行只是本地 state」,两条独立的路子:**

| 路子 | 结果 |
|---|---|
| ① 读代码 | `CostSettlePanel.tsx` 的 `selectionFor()`:`onToggle: (id) => setSel({ ...sel, [id]: !sel[id] })` —— **一个纯 `useState` 写入,没有 server action、没有 fetch** |
| ② 录网络请求 | 点击前后录到 **30 个请求,非 GET 【0 个】** |

**第二步 —— 点一行(不是表头),等 500ms:**

| 表 | 行 / 框 | 表头那枚 | 底 | 边框 | 背景图 | 尺寸 · 圆角 |
|---|---|---|---|---|---|---|
| #0 | 5 行 / 6 枚 | ★ **`indeterminate = true`** | **#007FAD** | **#007FAD** | ★ **白横那一张(`M4 8H12`)** | 16×16 · 4px |
| #1 | 4 行 / 5 枚 | `indeterminate = false` | 透明 | **#62738C** | none | 16×16 · 4px |

★ **两张表各有各的选中集 —— 点 #0 不会动 #1,这一点顺带证了。**
**第三步:清掉选中 → 两枚都回到 `false`;然后重新加载页面。**
截图:`/tmp/input3/shots-extra/indeterminate-processing-costs.png`。
☞ **这是全仓库唯一一处 `indeterminate` 的消费者,而它此前【从来没有被任何量具看见过】。**

### Q11 · 文件选择钮的 hover(1440px,CDP 真悬停,等 500ms)

| | 静止 | ★ 悬停 |
|---|---|---|
| **文件选择钮**(`::file-selector-button`,`/finance/bank/import`) | **#007FAD** | ★ **#00709D** |
| **一颗真的 default 档 `<Button>`**(`/hr/payroll/new`) | **#007FAD** | ★ **#00709D** |

★★ **两边逐字相同 —— 静止态相同,悬停态也相同。** 这正是「文件钮 = Button 的 default 档」那条裁定要的。
文件钮的其余读数:高 **32px** · 圆角 **8px** · 字色 **#FFFFFF** · 字号 **14px** · 字重 **500**。
截图:`/tmp/input3/shots-extra/q11-file-button-hover.png`。

### Q2 · `/purchasing/payment-terms/new` @390px,修复之后

| | 读数 |
|---|---|
| 那个 `<div>` 行容器 | `flex-wrap: wrap` ✓(**`<td>` 自身一个字节没动**) |
| 整页溢出 | **144**(验收 ≤223 ✓) |
| 那一行的行高 | **63 → 77** |
| ★ **有圈和它的字分家吗** | ★★ **没有。** 两个选项 `<label>` 自己仍然是 `flex-wrap: nowrap`,`labelH = 20px = lineHeight`,圈与字**同一行**(圈的中线与文字行的中线差 <8px) |

截图:`/tmp/input3/shots-extra/q2-payment-terms-390.png` —— 屏幕上是「◉ % ◯ Fixed」在第一行,
数值框换到第二行。**选项 (2)(给 `<label>` 自己加 wrap)没有用上。**

### §5.6 · 改后首屏控件逐条对 R2

| 视口 | 接了模块并量到 | ★ 合 | 不合 |
|---|--:|--:|--:|
| phone 390 | **274** | ★ **274** | ★ **0** |
| desktop 1440 | **274** | ★ **274** | ★ **0** |

**按类(每个视口):** `input.text` 124 · `select` 64 · `input.checkbox` 30 · `input.number` 21 ·
`input.date` 18 · `input.radio` 9 · `textarea` 5 · `input.file` 2 · `input.month` 1。

**判据认得委托书点名的那四件事(每一件都真的遇到了):**

| 要认得的 | 实际遇到 |
|---|---|
| ① 默认勾上的框边框是 **#007FAD** | `/brand-sampler` 13 枚 · `/purchasing/payment-terms/new` 的 Active 框等 |
| ② `rounded-full` 报 **3.35544e+07px** | 9 个单选框 |
| ③ Q9 的只读底色 | `PayrollGrid` 那个月份框 |
| ④ Q13 的错误分支 | `/finance/processing-costs` 两个空值日期框(边框实测 **#B75B53**) |

> ### ⚠ 一处【我自己的量具错过一次】,照直说
> 第一版判据把 `rgba(0,0,0,0)` 十六进制化成 `#000000`,于是**把「透明」读成了「黑」** ——
> 274 个里 227 个被报成「底色不是透明」。同一版还把 class 串截断到 260 字,
> 于是 Q13 那两处的错误类**落在截断之后**,被报成「边框色不对」。
> ★ **两处都是量具的错,不是树的错。** 修好之后重量:**274 / 274 全合,0 不合。**
> ☞ 顺带给探针加了一条**覆盖断言**:「DOM 里有控件而『接了模块的』是 0」→ 重新导航一次,再不行标 `suspect`。
> **本轮 `suspect` 0 条、重试 0 次。**(它是被一次真的空读逼出来的:中间有一跑整片读成 0,而当时**没有任何东西会喊**。)

### §5.7 · 原生 `<select>` 装不装得下(判据 §4.1b:文字宽 ≤ clientWidth − padL − padR − 20.3px)

| | phone 390 | desktop 1440 |
|---|--:|--:|
| 首屏原生 `<select>` | 65 颗 | 65 颗 |
| 改前装不下 | **20** | **7** |
| ★ 改后装不下 | ★ **25** | ★ **1** |

> ### ★★ 照直说:**手机上这一刀把下拉截得【更厉害】了;桌面上把它【修好】了。**
> **机制:** 手机字号 **14/15 → 16px**,而这几颗**全都写着宽度类** —— R3 明写宽度类一个都不动。
> 桌面那一档字号落到 14px、内边距归一,于是 7 颗里 6 颗回到装得下。

**phone 上逐颗(按短多少排):**

| 路由 | 选中项 | 渲染几颗 | 改前短 | ★ 改后短 | 本刀改过它的样式吗 |
|---|---|--:|--:|--:|---|
| `/operation/processing/new` | Pick an operation — it decides what this machine… | 1 | 128.55 | ★ **138.51** | 是 |
| `/operation/orders/new` | Nobody has said | 3 | 99.63 | ★ **132.49** | 是 |
| `/sales/quotes/new` | Select material | 5 | 84.55 | ★ **109.12** | 是 |
| `/tools/pricing/formulas/new` | Index not stated (same series as the existing…) | 1 | 100.76 | **100.72** | ✗ 否 |
| `/operation/orders/new` | None | 3 | 18.81 | ★ **41.55** | 是 |
| `/tools/pricing/metal-prices/bulk` | — only for a published-index quote — | 1 | 24.05 | **24.01** | 是(样式;**宽度没动**) |
| ★ `/operation/orders/new` | Select material… | 5 | (装得下) | ★★ **15.12** | 是 —— **本刀新造出来的** |
| ★ `/purchasing/orders/new` | From the line | 1 | (装得下) | ★★ **5.67** | 是 —— **本刀新造出来的** |
| `/finance/freight/new` | Unpaid (payable) | 1 | 0.19 | **0.15** | 是 |
| ★ `/purchasing/orders/new` | Apply template | 1 | (装得下) | **0.14** | 是 —— 新造(**「正好装满」那一档**) |
| ★ `/finance/fx/bulk` | CNY | 1 | (装得下) | **0.08** | 是 —— 同上 |
| ★ `/hr/kpi/score` | — choose a month — | 1 | (装得下) | **0.04** | 是 —— 同上 |
| `/finance/expenses/new` | Unpaid | 1 | 0.04 | **0** | 是 |
| `/finance/expenses/new` | SGD | 1 | 0.01 | ★ **(装得下)** | 是 —— **修好了** |
| `/finance/freight/new` | SGD | 1 | 0.01 | ★ **(装得下)** | 是 —— 修好了 |
| `/finance/journal/new` | Credit | 1 | 0.02 | ★ **(装得下)** | 是 —— 修好了 |
| `/hr/payroll/new` | SGD | 1 | 0.01 | ★ **(装得下)** | 是 —— 修好了 |

**desktop:唯一一颗装不下的是 `/tools/pricing/formulas/new`(短 100.72px)—— 而本刀【没有】改过它的样式;
改前那 7 颗里另外 6 颗全部修好了。**

⚠ **整套判据只在 `chrome-headless-shell 152.0.7977.54` 上成立。**
☞ **全部名单与「归哪一刀」已写进 `docs/forward-queue.md` 的「合并的【小件】那一刀 → ③」,施工判据归【字体/排版】那一刀(Q22)。**

---

## 8 · §5.9 · UNMEASURED —— 转换了、但【没有任何量具看得见】的站点

### ① 只渲染在**动态路由**上的:**68 个站点 / 10 个文件**

| 文件 | 站点 | 控件类型 | 只渲染在这些动态路由上 |
|---|--:|---|---|
| `app/purchasing/orders/[id]/amend/AmendOrderForm.tsx` | 17 | text×6 · date×3 · checkbox×2 · DecimalInput×2 · select×3 · textarea×1 | `/purchasing/orders/[id]/amend` |
| `app/inbound/[id]/assays/new/AssayForm.tsx` | 10 | date×1 · select×3 · number×1 · text×3 · checkbox×1 · DecimalInput×1 | `/inbound/[id]/assays/new` |
| `app/output/[id]/assays/new/OutputAssayForm.tsx` | 10 | date×1 · select×3 · number×1 · text×3 · checkbox×1 · DecimalInput×1 | `/output/[id]/assays/new` |
| `app/sales/orders/[id]/amend/AmendOrderForm.tsx` | 9 | text×1 · checkbox×1 · DecimalInput×2 · select×1 · number×2 · textarea×2 | `/sales/orders/[id]/amend` |
| `app/output/[id]/edit/SalePanel.tsx` | 8 | select×4 · DecimalInput×2 · date×1 · text×1 | `/output/[id]/edit` |
| `app/components/inventory/HoldReleaseControls.tsx` | 4 | DecimalInput×2 · text×2 | `/inbound/[id]/edit` · `/output/[id]/edit` |
| `app/components/inventory/TransferControl.tsx` | 3 | DecimalInput×1 · select×1 · text×1 | `/inbound/[id]/edit` · `/output/[id]/edit` |
| `app/purchasing/orders/[id]/RetentionPanel.tsx` | 3 | DecimalInput×2 · text×1 | `/purchasing/orders/[id]` |
| `app/components/metals/MetalContentPanel.tsx` | 2 | select×1 · DecimalInput×1 | `/inbound/[id]/edit` · `/output/[id]/edit` |
| `app/inbound/[id]/edit/PrepaymentPanel.tsx` | 2 | date×1 · DecimalInput×1 | `/inbound/[id]/edit` |

**两支量具结构上都走不到带 `[id]` 的路由**(取 id 那套机制住在 `smoke-routes.mjs` 里,复制它就是仓库里第二份会漂的定义)。

### ② Q7 的 15 个 —— `/hr/kpi/score`(6)与 `/me`(9)的编辑态

| 路由 | 站点 | 控件类型 | 为什么量不到 |
|---|--:|---|---|
| `/hr/kpi/score` | **6** | number×2 · select×1 · textarea×3 | `--mode=edit` 两个视口:**候选「编辑」钮 0 颗**,`clickHadNoEffect`,整页 0 张表 |
| `/me` | **9** | date×1 · file×1 · number×2 · text×3 · textarea×2 | 同上 |

★ **那两页今天的数据里根本没有可编辑的行 —— 不是判据太窄。**
**没有放宽点击判据**:放宽换来的是一次**可能改数据**的点击,而拿到的只是两页的行高。
☞ 首屏上这两页仍各量到 2 个成员(`/hr/kpi/score` 2 个 · `/me` 2 个宽度变化),所以**不是完全没看见**。

### ③ 还有一处:`/settings/roles/[id]` 的 `PermissionMatrix`

INPUT-2 已经转过它(29 个格子里的勾选框 13×13 → 16×16,行高 37 → 38px),
**本刀一个字节都没碰**;而它仍然**没有任何量具看得见**。**请 Tim 用眼睛看一次**(见 §10)。

---

## 9 · 逐类:转了什么 / 按裁定没动 / 量不到

| 控件类型 | 本刀的站点 | 转了 | 按裁定没动 | 首屏/编辑态量到并判过 |
|---|--:|--:|---|--:|
| `select`(原生下拉) | **79** | 79 | — | 64 × 2 视口 |
| `input.text` | **58** | 58 | — | (含在 124 里) |
| ★ `<DecimalInput>` 调用点 | **52** | 52 | — | (基础样式由组件给;调用点只留宽度) |
| `input.date` | **27** | 27 | — | 18 × 2 |
| `input.number` | **21** | 21 | — | 21 × 2 |
| `input.checkbox` | **19** | 19 | — | 30 × 2(含 DataTable 的与 brand-sampler 的) |
| `input.radio` | **15** | 15 | — | 9 × 2 |
| `textarea` | **13** | 13 | — | 5 × 2 |
| `input.file` | **2** | 2 | — | 2 × 2 |
| `input.month` | **1** | 1 | — | 1 × 2 |
| **`<DecimalInput>` 组件自己** | **1** | 1(`cn(CONTROL_INPUT, className)`) | — | 经每一个调用点 |
| **`<label>`** | — | — | ★ **R4:一个都不动**(归字体刀) | — |
| **`<button>`** | — | — | ★ **R4:一个都不动** | — |
| **`type="hidden"`** | 37 | — | ★ **R4:一个都不动** | — |
| **`/login`** | — | — | ★ **R4 / E1:一个字节不动** | — |
| **`data-table.tsx:473`** | — | — | ★ **R4:INPUT-2 已做,不碰** | — |
| **E6 触控档** | ★ **0** | — | ★ **本刀名下一个站点都没有 —— 照直说,不当成"做到了"** | — |

### `<DecimalInput>`:组件 + 52 个调用点

| | |
|---|---|
| **组件** | `app/components/forms/DecimalInput.tsx`:`className={className}` → **`className={cn(CONTROL_INPUT, className)}`**;新增 `import { cn } from '@/lib/utils'` 与模块 import |
| ★ **合并顺序** | `cn` = `twMerge(clsx())`,`cn(模块, 调用点)` → ★ **调用点赢** —— 这正是 §4.1c「两张清单都有就留赢」要的方向 |
| ★ **行为** | **一个字节没动**:`type="text" + inputMode="decimal"`、`/^-?\d*\.?\d*$/`、`""`/`"-"`/`"975."` 等中间态、`allowNegative`、`parseDecimal`、以及给了 `name` 时那个 hidden 伴生框 |
| **52 个调用点** | 各自的样式类照 R5 剥掉,**宽度与对齐类原样留着**(`w-16`/`w-20`/`w-24`/`w-28`/`w-32`/`w-36`/`w-40`/`text-right`)。其中 5 个经 `PayrollGrid` 的 `cell` 常量(`'w-24 border … rounded text-right'` → **`'w-24 text-right'`**) |
| **服务端** | 23 个调用点文件**全部 `'use client'`**,而这是结构上必然的(`onChange` 是函数 prop)。`cn` 只 import `clsx` 与 `tailwind-merge` |

### `<DataTable>` 的三枚勾选框(**按内容定位,不认行号**)

| 那一枚 | 改前 | ★ 改后 | 量到了吗 |
|---|---|---|---|
| **表头全选**(带 `indeterminate`,全仓库唯一的消费者) | `base-pressable h-4 w-4` → 16×16 · `appearance:auto` · 圆角 0 · 无边框 | `` `${CONTROL_CHECKBOX} w-4 base-pressable` `` → **16×16 · 4px · 1px · `appearance:none`** | ★ **量到了,连不确定态一起**(§7) |
| **每一行的选择框** | 同上 | 同上 | ★ 量到了(`/finance/processing-costs` 9 枚) |
| **列显隐面板里那一枚** | ★ **一个 className 都没有** → **13×13 · `appearance:auto`** | `className={CONTROL_CHECKBOX}` → **16×16 · 4px** | ★ **量到了 —— 把 `<details>` 点开之后**(Q6) |

★ **前两枚今天就已经是 16×16(它们写着 `h-4 w-4`)—— 转换只改样子,不改几何;只有第三枚改了几何。**
☞ 这一条是本刀的新失效模式之一,已写进 `AGENTS.md`(「同一个组件里的三个同类控件,可以有两种几何」)。

### `ScaleEditor` 的两步

① **只删四处死宽度**(`w-32` / `w-40` / `w-40` / `w-20`,`w-full` 留着)→ 四个框仍是 **159 / 135 / 135 / 135**(两视口逐字相同)→ **它们确实是死的**;
② **再转换** → `/hr/reviews/scale` 首屏 8 个成员宽度 **+53 ~ +69**(phone)/ **+33 ~ +37**(desktop),编辑态最大行高 **255 → 307**(phone)。按 R6 报出,**不停手**。

---

## 10 · Tim 该去哪儿看 —— 路由 · 视口 · 需要什么权限

> **全部读数来自 CDP 与截图。★ 没有人真的用手指点过这些控件。**

| # | 去哪儿看 | 视口 | 需要什么 | 看什么 |
|--:|---|---|---|---|
| 1 | ★ `/finance/freight/new` | **390px** | `module.finance.edit` | 那一列 **15 个勾选框从 13×13 变成 16×16**;那张表**本来就在横滚**,现在滚动范围从 1px 变 4px。**这是唯一一处踩到 R6(c) 的地方** |
| 2 | ★★ `/purchasing/payment-terms/new` | **390px** | `module.purchasing.edit` | 「% / Fixed」两个单选**整块换到了两行**,而**圈没有和字分家**;整页溢出 223 → **144**;那一行**变高 63 → 77** |
| 3 | ★★ `/operation/processing/new` | **390px** | `module.operation.edit` | **横向溢出从 416 掉到 194** —— 这一页在手机上本来要横着拖很久 |
| 4 | ★ `/finance/processing-costs` · **点【某一行】而不是全选** | 1440 或 390 | `module.finance.edit` | 表头那枚勾选框变成**蓝底白横**(不确定态)。**这是全仓库唯一一处 indeterminate**,而它此前从来没有被任何量具看见过 |
| 5 | ★ `/hr/reviews/scale` · **点一行的「编辑」** | **390px** | `module.hr.edit` | 行内的输入框全部变成 32px 标准档;**编辑那一行从 255px 高到 307px**;顶上「新增一档」那张表单的四个框**变宽了**(死宽度删掉了) |
| 6 | `/hr/leave/types` · 点「编辑」 | 390px | `module.hr.edit` | 同上,编辑行 229 → **271px** |
| 7 | ★ `/me` | 390px | 任何登录用户 | **自评那个多行框空着时矮了 32px**(96 → 64);头像那个**文件选择钮**现在是品牌蓝、悬停会变深 |
| 8 | 一个文件上传页(`/finance/bank/import` 或 `/settings/import`) | **1440px**(要用鼠标悬停) | `module.finance.edit` / `settings` | 文件钮 **#007FAD → 悬停 #00709D**,**和旁边真的 Button 一模一样** |
| 9 | ★ `/brand-sampler` · **把「列」那个面板点开** | 两个都看 | 无 | 面板里那 **13 枚勾选框从 13×13 变成 16×16 品牌样式**。☞ **标准自己那一页上的控件也跟着变了 —— 这是 Q5 点过头的** |
| 10 | ★★ `/settings/roles/[id]`(挑一个角色) | 两个都看 | `settings.roles` | **两种勾选框的样子**:格子里那 29 个(INPUT-2 改的,全勾上 → **蓝边蓝底白勾**)与页面上另外 10 个来自 `data-table.tsx` 的(**本刀改的**)。☞ **这一页【没有任何量具看得见】** —— 要靠眼睛 |
| 11 | `/tools/pricing/calculator` 与 `/tools/pricing/formulas/new` | 390px | `module.tools` | 表格的行**变矮了 7.42px** —— 格子会紧一点 |
| 12 | ⚠ `/operation/orders/new` 与 `/sales/quotes/new` | **390px** | 相应模块 | ★ **下拉里的字被截得比以前厉害**(「Nobody has said」短 99.63 → **132.49px**;「Select material」84.55 → **109.12px**)。**这是手机字号 14/15 → 16px 的必然结果,而那几颗都写着宽度类(R3 不许动)** —— 已登记给【字体/排版】那一刀 |

---

## 11 · 每一步的实测时长与【它自己的】退出码

> **规矩:包装脚本的退出码不是被包住那一支的退出码。下面每一行都是被跑的那支自己打出来的。**

| 步 | 起(UTC) | 止 | 秒 | 退出码 |
|---|---|---|--:|---|
| §1.1 开工闸 + §1.2 产物核对 | 01:00:16 | 01:00:17 | **1** | 0 |
| §1.3 通读(停止闸 1052 行 + 两份交回报告 + spec 七节 + forward-queue 两节 + AGENTS 四节 + 基线 + 5 个源文件 + 比对器全文) | 01:00:17 | 01:03:00 | **163** | — |
| §4.1 分类 + 24 条答复落地(`finalise.mjs`) | 01:03:00 | 01:03:40 | **40** | ★ `FINALISE_OWN_EXIT=0` |
| §4.2 比对器改前基准读数 | 01:03:57 | 01:03:57 | **<1** | ★ `ROWHEIGHT_OWN_EXIT=0` |
| §4.2 改比对器 + 四条自证 | 01:03:57 | 01:05:43 | **106** | ★ `P1=0 · P2A=1 · P2B=0 · P3A=1 · P3B=1 · P3C=2 · P4=0` |
| §4.3 ScaleEditor 步骤(1) + 两视口复量 | 01:07:23 | 01:07:41 | **18** | ★ `SCALE1_OWN_EXIT=0`(`VERDICT=PASS`) |
| §4.4 转换 264 处 + 6 个常量 + 5 处手改(`convert3.mjs`) | 01:11:13 | 01:11:13 | **<1** | ★ `CONVERT_OWN_EXIT=0` |
| §4.4 Q11 改模块 + R6(d) 逐字核对 | 01:11:13 | 01:12:03 | **50** | — |
| §4.7 `npx tsc --noEmit` | 01:12:03 | 01:12:12 | **9** | ★ **0** |
| §4.4 改后重扫对账(`scan3.mjs`) | 01:12:12 | 01:12:20 | **8** | ★ `RESCAN_OWN_EXIT=0` |
| §4.5 两条路由改前读数(`p-repair.mjs`) | 01:13:33 | 01:14:00 | **27** | ★ `REPAIR_BEFORE_OWN_EXIT=0` |
| §4.5 加 4 个 `flex-wrap` + `tsc` | 01:14:00 | 01:14:54 | **54** | ★ `TSC=0` |
| §4.5 修复后读数 | 01:14:54 | 01:15:19 | **25** | ★ `REPAIR_AFTER_OWN_EXIT=0` |
| ★ §5.1 `--mode=drift`(141 × 2 视口) | 01:15:37 | 01:32:54 | ★ **1037** | ★ `DRIFT_OWN_EXIT=0` |
| §5.1 `--mode=edit` | 01:32:54 | 01:35:05 | **131** | ★ `EDIT_OWN_EXIT=0` |
| §5.1 单条补量 `--only=/purchasing,/tools/pricing/calculator` | 01:35:49 | 01:37:26 | **97** | ★ `REPAIRONLY_OWN_EXIT=0` |
| §5.1 并入 | 01:37:26 | 01:37:27 | **<1** | ★ `MERGE_OWN_EXIT=0` |
| §5.2 `--mode=compare` ×2 + 行高比对器 ×2 | 01:37:27 | 01:38:20 | **53** | ★ `COMPARE_DRIFT=0 · COMPARE_EDIT=0 · ROWHEIGHT_REPORT=1 · ROWHEIGHT_STOP=1` |
| ★ §5.4 + §5.6/5.7 + §5.8(`p-after.mjs`) | 01:38:27 | 01:42:18 | **231** | ★ `AFTER_OWN_EXIT=0` |
| §5.6/5.7 **重量**(量具修好之后) | 01:51:59 | 01:54:44 | **165** | ★ `CONFORM_OWN_EXIT=0` |
| §5.5 四项额外读数(`p-extras.mjs`) | 01:56:26 | 01:57:09 | **43** | ★ `EXTRAS_OWN_EXIT=0` |
| §5.5 Q11 hover 与真 Button 对比(`p-hover.mjs`) | 01:57:52 | 01:58:18 | **26** | ★ `HOVER_OWN_EXIT=0` |
| §5.8 改后 14 张截图(round 1 自己的取景) | 02:02:39 | 02:04:02 | **83** | ★ `SHOTS_OWN_EXIT=0` |
| §6 五份文档 | 01:05:43 | 02:06:00 | ~**900**(与量测交错) | — |
| §7.1 `check-i18n.mjs` | 02:06:00 | 02:06:01 | **<1** | ★ **0** |
| §7.2 `npm run build`(含 24 道静态闸 + eslint 冻结闸) | 02:06:01 | 02:06:37 | **36** | ★ **0** |
| §7.3 `smoke-routes.mjs`(不带 `--reach`) | 02:07:05 | 见 §12 | 见 §12 | 见 §12 |

---

## 12 · §7 的闸、提交、上线

| 闸 | 命令 | 退出码 | 时长 | 读数 |
|---|---|---|--:|---|
| **§7.1 i18n** | `node scripts/check-i18n.mjs` | ★ **0** | <1s | ★ **缺键 0 · 新增 0 · 删除 0** —— 改动里**一个 i18n / 文案文件都没有**(`git status` 里 0 个)。「代码引用的每一个键(含可枚举的动态键)en 与 zh 都在」 |
| **§7.2 build** | `npm run build` | ★ **0** | **36s** | **24 道静态闸全绿**;`next build` 编译 8.4s、TypeScript 9.4s、161 个静态页全部生成 |
| ↳ eslint 冻结闸 | `check-lint.mjs` | ★ **0** | — | **基线 error 42 · warning 88;本次 error 42 · warning 87** → ★ **没有超过基线,而且【少了 1 条】**(`app/hr/employees/EmployeeForm.tsx` 的 `no-unused-vars` warning 1→0)。**一处新增都没有** |
| ↳ `check-instrument-selfproof` | 同上 | ★ **0** | — | ★ **36 支量具都写了瞄准线;其中 23 支(构建链里的,含本刀改的那一支)带着覆盖断言** |
| **§4.7 tsc** | `npx tsc --noEmit` | ★ **0** | 9s | — |
| **§7.3 冒烟** | `node scripts/smoke-routes.mjs`(**不带 `--reach`**) | ★ **0** | ★ **641s** | ★ **248 ok · 6 skipped(无数据)· 0 FAILED**;计时 223 条 · 合计 509.0s · 中位数 2101ms |
| ↳ 冒烟之后 `cod_verification_failures` | REST `count=exact` | — | — | ★ **1 行**(`Content-Range: 0-0/1`) |
| **§7.4 db 闸** | `bash db/run_detached.sh --log … --timeout 2700 -- python3 db/gate.py` | ★ **`RUN_EXIT=0`**(**脚本自己打的那一行**) | **209s** | 见下面四条判词 |

### §7.4 的四条判词(逐字)

```
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
   判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
```

★ **闸是在 push 【之前】跑的。** **零迁移** —— 本刀一个 `.sql` 都没有碰。

### §7.5 暂存范围

**43 个文件,全部落在 `app/` · `scripts/` · `docs/` · `AGENTS.md` 之内,一个都没有例外:**

| | 数 |
|---|--:|
| `app/` | **37** |
| `docs/` | **4**(`variant-c-spec.md` · `row-height-baseline.md` · `forward-queue.md` · `known-issues.md`) |
| `scripts/` | **1**(`check-row-height-baseline.mjs`) |
| `AGENTS.md` | **1** |

---

## 13 · §6 的五份文档(与工作在同一个提交里)

| 文档 | 改了什么 |
|---|---|
| ★ **`docs/variant-c-spec.md`** | ① **§4.1d 的修复次序:删掉 (ii)**,并把 INPUT-2b 的 `min-w-0` 实测(364→70px、6 个选项全被截、顺手取消换行;`max-w-full` 单独用无效)**放在规则【旁边】当理由**;原文一节标为「已升格成规则本身」<br>② ★ **新增 §4.1e** —— INPUT-3 的停止条件(**行高报告不停手**,连它的理由:12 张有控件的基线表**全部**在 INPUT-3 的路由上,而标准按设计就会改控件高度)· **Q1 的例外**(只覆盖勾选/单选框的 16×16,连它的证法)· **Q2 的格内 `flex-wrap` 允许**(连禁止清单与实测读数)· DecimalInput 的基础样式 · DataTable 三枚勾选框 · ScaleEditor 的死宽度 · **Q11 的 hover 结果**<br>③ **Q5 的就地更正**(§6 那句「13 个 13×13」)· **Q24 的就地更正**(§2A.2 那个行号 291 → 295/494/640 的三元对照表)。**两处都是:保留原句 + 划掉 + 标明谁 / 哪天 / 什么方法** |
| ★ **`docs/row-height-baseline.md`** | ★ **新增 §7「INPUT-3 之后的读数」**:一张人读的改前→改后表(12 张)+ **三个机读块**(首屏 / 编辑态 / 溢出),给【字体/排版】那一刀直接 diff。**§1–§6 一个字节都没动**(它们是 INPUT-2 / 2b / 3 三刀共同的参照点,改掉等于抹掉那三刀的判据) |
| ★ **`docs/forward-queue.md`** | ① **控件族整族关闭**,抬头加了五刀的落地表与「还开着的三类都不归这一族」<br>② **INPUT-3 标 ✅ 已完成**,原文折进 `<details>`<br>③ **INPUT-3 节里的修复次序就地更正**(与 spec 同步)<br>④ ★ **新增「合并的【小件】那一刀」**:DataTable 自己的按钮(**4 个代码点 / 约 15 个渲染,高度没有重量**)· 卡片样式(**带那个坑:变体 C 的 card 写了边框色而实测 `border-width: 0px`**)· **Q22 的 20 → 25 颗下拉**<br>⑤ **Q9 与 Q13 的登记**(状态样式,等一次单独裁定)· **Q16 的注记**(`tableC.cell` 的 15px 不再穿透,与 label 那条并排)<br>⑥ **Q24 的三处就地更正** + **T4 那一条的双向指针** |
| **`docs/known-issues.md`** | ★ 新条目 **`INPUT3-DRIFT-COST-UNEXPLAINED`**:drift 冷跑 **1669 / 782 / 1037** 三个数,「冷热」解释不了;列了**没有验证过**的混淆变量;给下一刀的用法是「拿最近一次实测排期,但不要当常数」 |
| ★ **`AGENTS.md`** | ① CONFIRM-1 命中清单加 **INPUT-3 一行**(三个数:「差 1px 就横滚」方向反了 · 「约 15 个按钮」代码点是 4 · 「36 个继承字号」实测 51)<br>② ★ 新增两节失效模式:**「一条【已经触发】的停止条件,被措辞读成一条【还有余量】的」**(连它的处置:阈值读数必须带着它在阈值的哪一侧;开工前先问「它今天是不是已经开着」)· **「同一个组件里的三个同类控件,可以有【两种几何】」**(连它的处置:按渲染出来的那一个清点,不按文件清点) |

---

## 14 · 我不能核实的 / 没有做到的

* ★★ **真人的手。** 全部结论来自 CDP 读数与截图 —— **没有人真的用手机点过这些控件。**
* ★★ **别的浏览器。** 保留区 20.3px、整套 select 判据、每一个几何读数,**只在 `chrome-headless-shell 152.0.7977.54` 上量过。**
* ★ **68 个站点 + Q7 的 15 个 = 83 个站点从来没有被任何量具看见过**(§8)。它们**转了**,而「转对了」只能靠 `tsc` 与同族站点的类比,**不是靠读数**。
* ★ **`/settings/roles/[id]`** 仍然没有任何量具看得见 —— 本刀一个字节没碰它,但它上面那 10 个来自 `data-table.tsx` 的勾选框**确实变了**。
* ★ **`<DataTable>` 自己那几个按钮的三档高度(20/28/30px)本刀没有重量** —— 照直登记,不冒充读数。
* ★ **变体 C 的 card「边框色设了而宽度是 0」那个坑本刀没有重量** —— 它要在 `/brand-sampler` 上量,而 `--mode=drift` 结构上跳过那一页。原样转述 spec §7.2。
* ★ **箭头保留区 20.3px 本轮没有重量** —— round 1 自己量过(20.06–20.75),本轮直接拿来当判据用。
* ★ **`min-w-0` 那条禁令本刀没有重量** —— 当禁令接受,**而本刀一次都没有用过它**。
* ⚠ **`/purchasing` 在 phone 上卡死过一次**(整跑中);单条补量后并入,**并完之后两个视口读不到 0 条**。★ 这是这一族第 5 次撞上渲染器卡死,而**这一次卡的不是 `/finance/freight/new`** —— 换了一条路由。
* ⚠ **我自己的量具错过两次,都改好了并重量**:① `rgba(0,0,0,0)` 被十六进制化成 `#000000`,把「透明」读成「黑」(227 个假不合规);② class 串截断到 260 字,Q13 的错误类落在截断之后。**两次都是量具的错,不是树的错** —— 而第一次之后我给探针加了一条**覆盖断言**(「DOM 里有控件而接了模块的是 0」= 瞎,要重来)。
* ⚠ **改后那 14 张截图用的脚本改了一句判据**(「还没接模块的控件」→「格子里有控件」),否则改完之后只拍得出 6 张。**取景逻辑一个字节没动。**

---

## 15 · §7.6–§7.9 · 推送 · 部署 · 残留

### 7.6 推送 —— 三方 40 位全等

| | |
|---|---|
| 工作提交 | `918f0942a5eb8533c1c501fa0f7e9b76f4fce175`(44 个文件 · +2047 / −306) |
| `git rev-parse HEAD` | `918f0942a5eb8533c1c501fa0f7e9b76f4fce175` |
| `git rev-parse origin/main` | `918f0942a5eb8533c1c501fa0f7e9b76f4fce175` |
| `git ls-remote origin refs/heads/main` | `918f0942a5eb8533c1c501fa0f7e9b76f4fce175` |
| ★ 判定 | ★ **三者全等,长度 40** ✓(`PUSH_OWN_EXIT=0`,02:26:11 → 02:26:17 UTC) |

### 7.7 部署 —— `state=success`,**先绑 id→sha,再问状态**

| | |
|---|---|
| 等法 | ★ `db/wait_for.sh --timeout 900 --interval 10 --label "Production deployment 登记 for 918f0942…"`(**有上限、会报名字**,不是手写 until 循环) |
| 等了多久 | ★ **173 秒**(`✓ 等到了:…(173s)`,`WAITFOR_OWN_EXIT=0`) |
| ★ **① 先把 id 绑到 sha 上** | `id=6385183091` · `sha=918f0942a5eb8533c1c501fa0f7e9b76f4fce175` · `environment=Production` · `created_at=2026-09-11T02:28:58Z` —— ★ **是【这个】SHA 的,不是上一个**(`GH_DEPLOY_EXIT=0`) |
| ★ **② 绑定之后才问状态** | ★ **`state=success`**,`created_at=2026-09-11T02:28:59Z`(`GH_STATUS_EXIT=0`) |
| ★ **状态记录数** | ★ **1** |
| **破窗** | ★ **不适用 —— 本刀零迁移**,不存在「旧代码 + 新库」那个窗口 |

### 7.8 残留 —— 逐格,连判据一起

| 项 | 判据(说清楚查的是什么) | 结果 |
|---|---|---|
| ★ **一次性账号** | 拉线上**全部**账号(**6 个**),逐个匹配 **11 种式样**:`input0-*`(量具自己的)· 本刀七支探针各自的前缀 `input3s1-* / input3r2-* / input3a-* / input3c-* / input3x-* / input3h-* / input3d-*` · 截图探针 `input3s-*` · `smoke-*` · 以及**任何** `@test.local` | ★ **11 种全部 0 个** ✓<br>线上那 6 个全是真人账号(`chooer@` · `phua@` · `sandra@` · `vince@` · `fusheng@` · `admin@swm-os.test`) |
| ★ **幽灵授权** | `user_roles` 的 `user_id` 去重后,逐个与**现存账号**求差 —— ☞ **round 1 明写这一格【没查】,本轮补上** | `user_roles` **8 行 / 6 个不同 user_id** · 现存账号 **6 个** → ★ **幽灵授权 0 条** ✓ |
| ★ **`.ephemeral/`** | `ls -A` | ★ **空(0 个文件)** ✓ |
| ★ **`reap-ephemeral`** | ★ **真的跑了一遍**,不是「量成 0 就当跑过」 | ★ `REAP_OWN_EXIT=0` —— 「✓ 没有滞留的清理计划(`.ephemeral/` 是空的)」 |
| ★ **本刀自己的进程** | `pgrep -fl 'chrome-headless-shell\|next dev\|survey-controls\|smoke-routes\|p-after\|p-conform\|p-extras\|p-hover\|p-diag\|p-repair\|p-scale1\|shots3\|repair-probe\|probe3'` | ★ **一个都没有** ✓ |
| ★ **本刀自己的端口** | 逐个 `lsof -ti tcp:` | ★ **六个全空**:3196(survey)· 3218(截图)· 3219(本刀六支探针)· CDP 9335 · 9356 · 9357 |
| ★ **孤儿 headless chrome** | 先证明再动手(ppid=1 · CDP 端口无人连 · 没有探针在跑) | ★ **一个 `chrome-headless-shell` 进程都没有** —— ☞ **那三条判据【没有用上】:没有东西要处置,一个信号都没有发。** |
| **`cod_verification_failures`** | service_role + `Prefer: count=exact` | ★ **1 行**(`Content-Range: 0-0/1`)—— 正是本轮冒烟插的那一行;它由下一次调用自己清掉,表封顶 30 行 |
| ⚠ **不是本刀的残留,但看见了就报** | 冒烟自己的临时行体检 | 报了**滞留的 `ZZ-SMOKE-*` 业务行**,脚本自己写着「本检查只报告,不删除;其中有些**仍被真单据引用**,删掉比留着坏」。★ **一条都不是本刀的**,照直报出来,**不处置** |
| **树** | `git status --porcelain` | ★ **空** ✓ |

### 7.9 收尾提交(docs-only)

| | |
|---|---|
| 它做什么 | 把 §15 这一节(部署与残留)填进本文件 —— 它们的读数在工作提交**之后**才存在 |
| 范围 | ★ **只有 `docs/handbacks/INPUT-3.md` 一个文件** |

---

## 16 · 给测试的人 —— 一句英文(v1.4.17,涵盖 INPUT-2 + INPUT-2b + INPUT-3)

> Every text box, dropdown, date, number and multi-line field, every checkbox, radio button
> and file-picker button across the whole system now shares one look — 32px tall, 8px rounded
> corners, one border colour — so a form no longer looks assembled from several different
> systems; please look on purpose at the five pages that changed the most on a phone
> (New freight, New payment term, New processing job, New work order and New quote), where
> rows are now slightly taller, two pages that used to drag sideways no longer do, and a few
> long dropdown labels are now cut off sooner than before.

---

pbcopy < docs/handbacks/INPUT-3.md
