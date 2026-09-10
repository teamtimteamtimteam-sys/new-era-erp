# INPUT-2 交回报告 —— 【全系统的手搓控件改从一处共享定义拿样子;`/logistics/lanes` 的宽度由这一刀设定】

> **屏幕上变了什么,一句话:**
> 全系统 **195 个**手搓控件(文本 / 日期 / 数字 / 原生下拉 / 多行框 / 勾选框 / 单选框 /
> `<DataTable>` 的筛选框)从各写各的 class 串,换成**一处共享定义**的样子 ——
> 高 32px · 圆角 8px · 1px `#AEBAC9` 边 · 左内边距 10px;勾选框与单选框从浏览器默认的
> 13×13 变成 **16×16 的品牌样式**(未选中 `#62738C` 边,选中 `#007FAD` 填 + 白勾 / 8px 圆点);
> 收货与盘点两页的触控档**高度一个像素没动**,只换了边框色 / 圆角 / 焦点环 / 底色;
> 而 `/logistics/lanes` 那一页的控件**拿到了三个宽度类**,把它 390px 上的整页溢出
> 从 **+76px** 按回 **+4px**(基线是 +12px)。

---

## 0 · 状态,一句话说清

| | |
|---|---|
| 开工前 HEAD | `37eed5ea3a6128d07f8d2dd7254602dd744008c3` = `origin/main` ✓(§1.1 三条全部核对) |
| 树 | 50 个文件改动(+758 / −162),其中 **2 个新文件** |
| **停止条件** | ★ **(a)–(e) 五条【全部】没有触发** —— 逐条读数见 §3 |
| **回退过吗** | ★ **没有。** 一个字节都没有回退,也没有调表、没有改列宽 |

---

## 1 · §1.5 的数字核对 —— 委托书里的数逐条重量

> **规矩(AGENTS.md「委托书里的【数】来自上一份报告」):委托书里的数字一个都不许直接引用。**
> 下面每一条都注明 **confirmed / wrong / not re-measured**,并带量法。

| 委托书(来自第二轮报告)的数 | 判定 | 重量的结果与量法 |
|---|---|---|
| 树:48 个文件、+511/−160 | ★ **confirmed** | `git diff --stat` 开工时逐字相同 |
| 两个新文件(`control-style.ts` · `check-row-height-baseline.mjs`) | ★ **confirmed** | `git status --porcelain` 恰好两条 `??` |
| `/logistics/lanes` 390px 溢出 **+12 → +76** | ★ **confirmed** | 本刀改宽度**之前**独立量过:`466/390 = +76`;基线 `docs/row-height-baseline.md` §6.3 记着 402/390 = +12 |
| 14 条 INPUT-3 路由 **520 个控件成员,0 个变动** | ★ **confirmed** | 逐成员比 before/after:**520 个,变了 0 个** |
| **12/12** 基线表逐项相同 | ★ **confirmed** | `check-row-height-baseline.mjs` 退 0:12/12 + 编辑态 2/2 |
| 勾选/单选框对比度 **4.53:1** | ★ **confirmed(算式复核)** | `#62738C` 对实测底色 `rgb(241,249,254)` = **4.53:1**;白勾对 `#007FAD` = **4.53:1** |
| 「220 个控件里 **114** 个宽度变了」 | ⚠ **wrong —— 但那是【口径】不同,不是错** | 本刀量到 **220 个【成员】**变宽,其中 **107 个是 `<label>`** → **控件本身 113 个**。第二轮的 220 是「控件总数」,本刀的 220 是「变宽的成员数」,两个 220 **不是同一个东西** |
| 「**26** 个本地样式常量」 | ⚠ **wrong** | 实测 **49 个**常量、**25 个**文件(`grep -rnE '^\s*(const\|let)\s+\w+\s*=\s*.*CONTROL_' app --include='*.tsx'`,排除模块自身)。「26」重现不出来 |
| 「覆盖 ~190 个调用点」 | ★ **confirmed(195)** | 逐字扫描 `.tsx` 的 `<input>/<select>/<textarea>` 开标签(按大括号深度找标签结尾,**不按行切**——`onChange={(e) => …}` 里的 `>` 会截断正则):**195 个**接了模块 |
| 「**18** 个一个 className 都没写的勾选/单选框」 | ★ **confirmed** | 同一支扫描器分别喂工作树与 `HEAD`:checkbox 无 className **34 → 18**(−16)、radio **7 → 5**(−2)= **18** |
| 「去掉 **8** 处 `rows=`」 | ★ **confirmed** | `git diff -U0 \| grep -c '^-.*rows={'` = **8**,而 `^+` 侧 = **0** |
| 「第二轮 **204/220** 合标准」 | ○ **not re-measured** | 本刀没有重跑第二轮那份逐项判据(它自己报告说那 16 个"不合"全部是判据写错)。本刀换了一条更硬的路:**逐成员比 before/after**,报的是「谁变了」,不是「谁合格」 |
| INPUT-2b 分类 **401 A / 2 B / 12 C = 415** | ○ **not re-measured** | 本刀没有重跑分类器。⚠ 它自己写着「A 类是抽查(15/401),A 类里有没有假阴性【这次没查】」 |
| eslint 冻结 42 错 / 88 警 | ⚠ **wrong(降了)** | 现在 **42 错 / 87 警** —— 少的那一条正是删掉的 `DecimalInput` 死 import。**没有上升** |
| 「量具比之前多一支」 | ★ **confirmed** | `HEAD` 上 35 支 → 现在 **36 支**(`ls scripts \| grep -cE '^(check\|survey)-.*\.mjs$'`) |

---

## 2 · §2 的裁定与「已经做完的」—— 逐条对着 diff 核

### 2.1 裁定(全部 DONE,证据是 diff 与读数,不是转述)

| 裁定 | 判定 | 证据 |
|---|---|---|
| 一处共享定义 `control-style.ts`,**不换组件** | **DONE** | 45 个文件 import 它;`<input>/<select>/<textarea>` 原生标签一个都没换成组件 |
| `<Input>` / `<Textarea>` 读同一模块,class 串**逐字节不变** | **DONE** | 把模块求值出来的串与 `git show HEAD:` 的原串逐字比:**35 / 28 个 token,全等** |
| 单行 / 日期 / 数字 / 原生 select:32px · 8px · 1px `#AEBAC9` · 左 10px | **DONE** | after 读数里转换过的成员签名逐字为 `32px\|4px\|10px\|4px\|10px\|1px\|1px\|rgb(174, 186, 201)\|8px\|…` |
| 字号焦点环禁用照 `<Input>`(手机 16 / 桌面 14) | **DONE** | 同上签名末段 `16px`(phone)/ `14px`(desktop) |
| 原生 select **保持原生**、留浏览器箭头、右内边距 24px | **DONE** | `appearance` 未改;`pr-6` 实测 `paddingRight: 24px` |
| 多行框:64px 下限 · 随内容长 · 竖向拖拽 · 去掉 `rows=` | **DONE** | `min-h-16` + `field-sizing-content`;`rows=` 删 8 处、加 0 处 |
| 勾选框 16×16 · 4px 圆角 · `#62738C` 未选中 · `#007FAD` + 白勾 / 白横 | **DONE** | `/settings/roles/<admin>` 实测 29 个 **16×16 · 圆角 4px · appearance:none** |
| 单选框 16px 圆 · 同色边 · 选中 `#007FAD` 边 + 8px 点 | **DONE** | 第二轮四态截图(`/tmp/input2/shots/radio-*.png`)+ 本刀读数 |
| 文件选择钮 = Button default 档,用 `file:*` | **DONE(已定义,0 个消费者)** | `CONTROL_FILE_BUTTON` 在模块里;本刀名下 6 处文件上传**全部**是 inline 站点 → 归 INPUT-2b |
| DataTable **只有 473 行**那个筛选框 | **DONE** | diff 里 `data-table.tsx` 只有两处:一句 import + 那一行 className |
| **宽度类从不碰** | ★ **DONE,一处例外且是 Tim 点名的** | 除 `/logistics/lanes` 那三个调用点(Tim 2026-09-10 单独裁的)之外,一个 `w-*` 都没动 |
| E1 `/login` 保持 44px | **DONE(未触碰)** | `git status --porcelain app/login` **空** |
| E6 触控档:9 个输入框只拿四样 | **DONE** | 3 处站点(2 个 `fieldCls` + 1 个直写),`min-h-[48px] py-3 text-base` 与宽度类**原样保留** |
| Q13 `ExpectedDateControl` 不动 | **DONE(未触碰)** | `git diff --stat` 对该文件**无输出** |
| Q11 `uppercase` 留 · Q12 灰字按 readOnly/disabled 处置 · Q14 三元改写 | **DONE** | 见第二轮 diff,本刀复核未改动 |
| `<label>` 一个都不动 | **DONE** | diff 里没有一处 `<label>` 的类串改动;而 **107 个 label 的渲染宽度变了** —— 那是它们**包着的控件**变宽了,不是有人动了 label |

### 2.2 「已经做完的」清单 —— 从 diff 里验,不是信

| 第二轮说做了 | 核对结果 |
|---|---|
| 模块 + `<Input>`/`<Textarea>` 接线 | ✓ 45 个文件 import;两个组件的串逐字未变 |
| 26 个常量覆盖 ~190 个调用点 | ✓ 覆盖数对(**195**);**常量数不对(实测 49 / 25 个文件)** |
| 18 个无 className 的勾选/单选框 | ✓ 34→18 与 7→5,合计 **18** |
| E6 的 9 个输入框 | ✓ 三处站点全部只拿四样 |
| DataTable 筛选框 | ✓ 只有 473 行 |
| CycleForm 两处死宽度(`w-48` / `w-56` 删,`w-full` 留) | ✓ diff 里三行齐全 |
| EmployeeForm 死 `DecimalInput` import | ✓ 删除行在 diff 里;eslint 警告因此 88 → 87 |
| 8 处 `rows=` | ✓ −8 / +0 |
| INPUT-2b 分类写进 forward-queue | ✓ 在册(**本刀未重量那 415**) |
| Step E 三份文档 | ✓ 在册,**并已按新裁定更正**(见 §6) |

---

## 3 · ★★ 停止条件 (a)–(e) —— 逐条读数 ★★

> 量具:`scripts/survey-controls.mjs --mode=drift/--mode=edit/--mode=compare` ·
> `scripts/check-row-height-baseline.mjs` · 一支一次性几何探针(仓库外)。
> 对照:`.survey-out/input2-before/controls-drift-MERGED.json`(第二轮的改前读数,已并入补量)。
> **成员总数 2112 → 2112,多出 0、少掉 0** —— 名单本身没有变化,所以下面比的是【值】。

| | 条件 | 判定 | 读数 |
|---|---|---|---|
| **(a)** | 390px 新增溢出,或已有溢出**比基线大** | ★ **没有触发** | 基线 **7 条**,今天 **7 条**,**路由完全相同**;六条**逐字不变**(416 / 223 / 205 / 35 / 27 / 17),第七条 `/logistics/lanes` **12 → 4,变小了** |
| **(b)** | 已按裁定横滚的表多出滚动范围 | ★ **没有触发** | **11 张,一张都没长**(比对器逐张核) |
| **(c)** | 12 张基线表的表头高 / 行数 / 最大行高 / 滚动壳内容宽 | ★ **没有触发** | **12/12 逐项相同**;`--mode=edit` 的 **2/2** 也相同 |
| **(d)** | 14 条 INPUT-3 路由上有任何东西变了 | ★ **没有触发** | **520 个成员,签名与渲染宽度都变了 0 个**。外壳改动:**0**(本刀没碰 `app/layout.tsx` 或外壳) |
| **(e)** | `<Input>` / `<Textarea>` 的 class 串变了 | ★ **没有触发** | **35 / 28 个 token,与 `git show HEAD:` 逐字节相同** |

`check-row-height-baseline.mjs` 自己那句判词,原文照抄:

```
✓ check-row-height-baseline:12 张含控件的表逐项与基线相同(表头高 · 行数 · 最大行高 · 滚动壳内容宽);
  390px 整页溢出没有新增也没有长大;11 张已裁定横滚的表一张都没有多出滚动范围。
· 变小了的(不是回归,登记在案):
    · /logistics/lanes:整页横向溢出变小了(不是回归,但要知道) 12 → 4
```

---

## 4 · 控件宽度的变化 —— **报告,不是停手**

**2112 个成员逐个比 `rectW`:变了 220 个,逐字未变 1762 个。**
★ **那 1762 个里,凡是调用点上写了宽度类的,一个都没动** —— 这正是本节的证据。

### 4.1 按变化量

| Δ | 成员数 | 谁 |
|--:|--:|---|
| **−24** | 4 | `input.text` 2 · `label` 2 |
| **−4** | 16 | `input.text` 4 · `select.native` 4 · `label` 8 ← **含 `/logistics/lanes` 加宽度类之后变窄的那几个** |
| **−3** | 2 | `select.native` 1 · `label` 1 |
| **+3** | 22 | ★ **勾选框 10 · 单选框 4**(13→16px,**裁定值本身**)· `label` 8 |
| **+4** | 62 | `input.date` 8 · `input.text` 23 · `label` 31 |
| **+18 / +19** | 42 | `select.native` 13 · `input.date` 8 · `label` 21 |
| **+22 ~ +33** | 14 | `select.native` 7 · `label` 7 |
| **+24** | 46 | `input.text` 23 · `label` 23 |
| **+41 / +50 / +52** | 10 | `select.native` 5 · `label` 5 |

**按角色:** `label` 107(**跟着它包的控件动**)· `input.text` 52 · `select.native` 31 ·
`input.date` 16 · `input.checkbox` 10 · `input.radio` 4 → **控件本身 113 个**。

### 4.2 按路由(13 条)

`/logistics/lanes` **68** · `/hr/leave/holidays` 24 · `/logistics/containers` 24 ·
`/hr/leave` 20 · `/hr/reviews/cycles` 20 · `/hr/reviews` 16 · `/finance/bank` 12 ·
`/hr/claims` 8 · `/logistics/forwarders` 8 · `/materials/new` 8 ·
`/hr/departments/new` 6 · `/inventory/locations/new` 4 · `/operation/handovers/new` 2

> ★ **只有 `/logistics/lanes` 一条把页面撑破了,其余 12 条一条都没有。**

---

## 5 · `/logistics/lanes` —— 前后、两个视口、加了什么、加在哪

**为什么只有这一页:** 它顶上那两张表单是 `flex items-end gap-2`,**没有 `flex-wrap`** ——
控件一变宽,整行就往右顶,而别的页要么写了宽度类、要么会换行。

### 5.1 三份读数(同一支量具 `survey-controls.mjs --mode=drift`)

| | desktop 1440 | phone 390 |
|---|---|---|
| **① 基线**(采用标准前) | 1440/1440(**+0**);15 个文本框各 **164px** · 2 个下拉各 **140px** · `w-28` 那个 **112px**(高 30 / 28px) | **402/390(+12)**;同左 |
| **② 采用标准后、加宽度类前** | 1440/1440(+0);文本框 **168px** · 下拉 **158px** | ★ **466/390(+76)**;文本框 **188px** · 下拉 **172px** |
| **③ 交付的这一版** | 1440/1440(**+0**);`name` **168px** · 下拉各 **160px** · 其余 14 个 168px · `w-28` 仍 112px | ★ **394/390(+4)** —— **比基线还小**;`name` **160px** · 下拉各 **136px** · 其余 14 个 188px |

★ **`w-28` 那一个从头到尾 112px** —— 它写了宽度类,所以标准改字号与内边距时它一个像素都没动。
**这一行本身就是「宽度变化只落在没有宽度类的控件上」的证据。**

### 5.2 加了什么,加在哪

`app/logistics/lanes/LanesPanel.tsx` 的**三个调用点**:

| 行 | 控件 | 加的类 | 手机 | 桌面 |
|--:|---|---|--:|--:|
| 69 | `name` 输入框 | `w-40 md:w-42` | 160px | 168px |
| 84 | `origin` 下拉 | `w-34 md:w-40` | 136px | 160px |
| 90 | `destination` 下拉 | `w-34 md:w-40` | 136px | 160px |

**证明它只落在这一条路由上:** `grep -rn "LanesPanel" app --include="*.tsx" --include="*.ts"`
命中 **3 行,全部在 `app/logistics/lanes/` 里**(`page.tsx:12` import · `page.tsx:47` 渲染 ·
组件自身的 `export default`);`grep -rn "logistics/lanes"` 在别处只命中**一句注释**。
☞ **所以这三个宽度不会漏到任何别的页面上。**

**`md:` 那一档为什么存在(实测逼出来的,不是对称好看):**
Chromium 给 `<select>` 的箭头留的位置**在 `padding-right` 之外**,实测约 **27px**
(两次自动宽反算:14px 那次 `140 = 文字 + 8 + 8 + 2 + 27`;16px 那次 `172 = 文字 + 10 + 24 + 2 + 27`,
两次算出同一个数)。于是「文字装得下」要的宽度是 `文字 + 左 + 右 + 边框 + 27`,
而 **390px 上这一页给不起**(两颗下拉合起来不能超过 279.5px,否则整页又溢出)。
**桌面有的是余地**(那一行最右 738px / 1440px),所以 `md:` 贴着**标准不加宽度类时
自己算出来的宽度**(168px / 158px)——**桌面上这一页等于没被这一刀动过**,
手机那一档才是真正的修复。

★ **说明白:字号、内边距、边框、圆角一个都没动**,那些是标准。
★ **代价照直说:手机上那两颗下拉的「SG Singapore」会被截掉尾巴**(见 §6 与截图)。

---

## 6 · 原生 `<select>`:文字与箭头挤不挤(几何检查,**Chromium only**)

**量法:** 每一颗**首屏渲染出来的**原生 `<select>`,拿**选中项的文字宽**
(canvas `measureText`,用那颗 select 自己的 `getComputedStyle().font`)
比它的**内容宽**(`clientWidth − padding-left − padding-right`)。

| | desktop 1440 | phone 390 |
|---|--:|--:|
| 量到的原生 `<select>` | **168**(57 条路由) | **168**(57 条路由) |
| 装得下 | **167** | **156** |
| ★ 装不下 | **1** | **12** |

> ### ★★ 这个几何判据【把问题说小了】—— 截图证明的 ★★
> 上面那张表用的是 `clientWidth − padL − padR`,而 Chromium 的箭头保留区
> (实测 ~27px)**在 padding-right 之外** → **真实可用宽度比它少约 27px**。
> ☞ **所以 1 / 12 是【下界】,不是精确值。**
> 证据:`/logistics/lanes` 那颗按几何只差 **0.51px**,而截图上它是
> **「SG Singapo」**——`re` 两个字母整个不见了。
>
> ⚠ **这是一次几何检查,不是视觉检查;而且只在 Chromium 上量过。**

**12 颗装不下的(390px),按归属:**

| 路由 | 颗数 | 归谁 | 本刀动过它的宽度吗 |
|---|--:|---|---|
| `/logistics/lanes` | 2 | ★ **INPUT-2** | ★ **动过 —— 宽度就是这一刀设的** |
| `/operation/orders/new` | 3 | INPUT-3 | 没有(14px 字号,42.8px 的框) |
| `/sales/quotes/new` | 5 | INPUT-3 | 没有(15px 字号,53.36px 的框) |
| `/tools/pricing/formulas/new` | 1 | INPUT-3 | 没有 |
| `/operation/processing/new` | 1 | INPUT-2b | 没有 |

☞ **13 条有宽度变化的路由里,只有 `/logistics/lanes` 与这份名单相交** ——
另外 10 颗**采用标准之前就装不下**,本刀既没制造也没加重。
desktop 唯一那一颗是 `/tools/pricing/formulas/new`(INPUT-3)。

**截图(12 张,仓库外):** `/tmp/input2-r3/shots-select/misfit-01 … misfit-12.png`

---

## 7 · PermissionMatrix —— `/settings/roles/40aad47d-a2e1-468b-98c1-823680b5ae8b`(`admin`,与前读数**同一个 id**)

| | **改前** | **改后** | |
|---|---|---|---|
| 表 `h:Module/View/Edit` | 3 列 **15 行** | 3 列 **15 行** | 不变 |
| 表头行高 | **37px** | **37px** | 不变 |
| 每一条表体行 | **37px** | ★ **38px** | ★ **+1px —— 报告,不停手**(裁定原文) |
| 格子里的勾选框 | **29 个,13×13**,`appearance:auto` | **29 个,16×16**,圆角 4px,`appearance:none` | 裁定要的 |
| 整页横向溢出 | **0 / 0** | ★ **0 / 0** | ★ **没有新增 → 不停手** |

★ 那 29 个的边框实测 `rgb(0, 127, 173)` = `#007FAD`,**因为 `admin` 每一格都是勾上的**
(`checked:border-primary` 正确生效)——**这是判据要认得的一件事,不是不合规。**
★ 同页另有 **10 个 13×13 / `appearance:auto`** 的勾选框(不在这张表的格子里),
来自 `data-table.tsx`,**归 INPUT-3,本刀一个字节没碰**。
☞ **+1px 的来源:** 勾选框 13→16px,那 3px 里有 1px 顶到了行上。
**这正是 forward-queue 早就写着的「勾选框变大会推高格子所在的行」在一张
【没有任何量具看得见】的表上兑现了 —— INPUT-3 那两张 81px / 81.5px 的表要按这个数预期。**

---

## 8 · 按控件类型:转换 / 留给 INPUT-2b / 留给 INPUT-3 / 未测量

**渲染层(phone 首屏,`--mode=drift` 的成员,不含 label):**

| 类型 | INPUT-2 转换 | 留给 INPUT-2b | 留给 INPUT-3 | 合计 |
|---|--:|--:|--:|--:|
| `input.text` | 52 | 82 | 97 | 231 |
| `select.native` | 27 | 107 | 34 | 168 |
| `input.date` | 12 | 60 | 10 | 82 |
| `input.number` | 7 | 29 | 21 | 57 |
| `input.checkbox` | 5 | 14 | 28 | 47 |
| `textarea.native` | 3 | 19 | 4 | 26 |
| `input.radio` | 2 | 2 | 7 | 11 |
| `input.file` | 0 | 3 | 1 | 4 |
| `input.lib`(`<Input>`) | 2 | 0 | 0 | 2 |
| **合计** | **110** | **316** | **202** | **628** |

**代码层(全树 `.tsx` 静态扫描,逐字符找标签结尾):接了模块 195 个站点。**

> ★ **两个数为什么不一样,说清楚:110 是【手机首屏上渲染出来的】,195 是【代码点】。**
> 差额住在:桌面独有的、点开才出现的(对话框 / 折叠 / `<details>`)、
> 以及**58 条 `[id]` 动态路由**上的站点。

**★ 未测量(不是"没问题"):**
* **58 条带 `[id]` 的详情/编辑页** —— 量具结构上走不到(`survey-controls.mjs` 抬头 ①)。
  本刀名下确知住在那里的有:`ContainerPanels` · `ForwarderPanels` · `MaintenancePanel` ·
  `ReconcileWorkspace` · `ImportDiligencePanel` · `RequiredMetalsPanel` · `CostPanel` ·
  `EditCustomerForm` · `NodeTree` —— **改过,没量过。**
  (例外:`PermissionMatrix` 用一次性探针单独量了,见 §7。)
* **点开才出现的**:对话框、折叠行、`<details>` 里的列显隐面板。
* **`/purchasing/discrepancies` @ phone** 在整跑里渲染器卡死 → 单条补量后并入(见 §10)。

---

## 9 · 闸与门

| 步 | 判词 | 退出码 |
|---|---|---|
| `node scripts/check-i18n.mjs` | 代码引用的每一个键 en 与 zh 都在;**`messages/` 一个字节未改** → 新增 0 / 删除 0 | ★ **0** |
| `node scripts/smoke-routes.mjs`(不带 `--reach`) | ★ **预检拒绝,0 秒,一条路由都没跑** —— 见 §11 | ★ **1** |
| `npm run build`(第一次) | `check-datatable-footer` 拒绝开跑:**「没有为 `@/app/components/ui/control-style` 准备桩 —— 量具自己不完整」** | **1** |
| `npm run build`(补桩后) | 24 条静态检查 + `next build` 全绿 | ★ **0** |
| eslint 冻结 | 基线 **42 错 / 88 警** → 现在 **42 错 / 87 警**(**降了一条**,即删掉的死 import)。**没有上升** | ★ 绿 |
| `check-instrument-selfproof` | **36 支量具**都写了瞄准线;其中 23 支(构建链里)带覆盖断言 —— `HEAD` 上是 **35 支**,**恰好多一支**(行高比对器) | ★ **0** |
| `python3 db/gate.py`(经 `db/run_detached.sh --timeout 2700`) | 四条判词全绿,**197 支 fixture 全过**,wall-clock **403s** | ★ **0** |

**★ 那次 build 失败值得单独说一句,因为它是【本刀造成的】:**
`data-table.tsx` 新增了一句 `import { CONTROL_INPUT } from '@/app/components/ui/control-style'`,
而 `check-datatable-footer.mjs` 自己维护一张模块桩表,那张表不认得这个新模块。
**它没有假装通过,它说「量具自己不完整」然后退 1** —— 正是 AGENTS.md
「一个瞎掉的检查必须说【我瞎了】」那一条在起作用。
**修法不是加桩,是加进 `REAL` 真载进来** —— 与 `table-style.ts` 逐字同一个理由:
本支靠**读类串**判断一格在哪个断点上可见,**桩掉它就是自己编一份类名再拿它证明类名是对的**。
`control-style.ts` 是一个只有字符串常量、零 import 的模块,真载进来没有代价。

**四条判词(逐字抄自 `/tmp/input2-r3/gate.log`):**

```
== 三个判词(wall-clock 403s)
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
   判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
```

**迁移:0 支。** 本刀**一个数据库对象都没动**(`db/` 下零改动),
所以「破窗」这一栏**不适用** —— 没有迁移,就没有「旧代码 + 新库」那个窗口。

---

## 10 · 量的时候撞见的事 —— 照直记

### 10.1 ★ 我自己的探针在跑完 39 分钟之后【把结果丢了】

第一支几何探针整跑 142 条路由 × 2 视口,**只在结尾写一次文件**。
`/purchasing/discrepancies` @ phone 把渲染器卡死,之后 39 条全成 `CDP timeout`,
最后 `Target.closeTarget` 也超时 → **退 2,`sweep-after.json` 一个字节都没写出来**。
**2337 秒(38m57s)的读数,全没了。**

☞ **教训两条,第二版都落实了:**
① **每量完一条路由就落一次盘** —— 部分结果也是结果;
② 渲染器卡住 → **换标签页**;标签页也开不出来 → **整个浏览器重启并重连**。
☞ 顺带:**出错时不许覆盖输出文件** —— 第一版的错误处理会写一个 `{error:…}` 的桩子,
那会把已经落盘的部分结果**再毁一次**。

### 10.2 ★ 官方量具撞上**同一处**卡死,而它自己爬起来了

`survey-controls.mjs` 在 `/purchasing/discrepancies` @ phone 上报
`renderer wedged`,然后 **`↻ 重开 chrome(标签页换不动)`**,继续走完 141 条。
**它比我的第一版探针强的地方正是那一行** —— 这也是第二版探针照着改的方向。
那一条路由的读数**单条补量**后并入(`--only=/purchasing/discrepancies,/finance/fx/bulk`,
**陪跑那条的读数不取**),并入后 **2112 个成员、0 条 not-ok**,与改前读数**同规模**。

### 10.3 委托书点名的那个已知卡死,这次**没有发生**

`/finance/freight/new` @ phone「三刀连着卡死」——**本轮整跑里它 ready=ok**。
按委托书要求仍然跑了 `--only=/finance/freight/new`(**退 0,77 秒**),
读数与整跑一致,**故未并入**(并入等于拿一份好读数替换另一份好读数)。
**真正需要补量的是另一条**(§10.2),而那一条正是第二轮报告预告过会撞上覆盖断言的形状。

### 10.4 第二轮点名的四个测量陷阱 —— 逐条落实

| 陷阱 | 本刀怎么避开的 |
|---|---|
| `transition-colors` 让 `getComputedStyle` 读到半路的颜色 | 本刀**没有改状态再读色**(四态截图沿用第二轮的)。新读的颜色都是静止态 |
| `captureScreenshot` 的 clip 是**页面坐标** | 截图前 `r.left + window.scrollX` / `r.top + window.scrollY`;**12 张全部核验过不是空白** |
| Tailwind 只认**字面量** | 新加的 `w-34 / w-40 / w-42` 都是字面类名;并且**离线用 `@tailwindcss/postcss` 验过生成得出来**,再由浏览器实测宽度复核(136/160/168px) |
| 判据要认得 E6 / 默认勾上的框 / `rounded-full` 报 3.35544e+07px | 本刀**不重跑那套逐项判据**,改用「逐成员比 before/after」——**它对这四件事天然免疫**,因为它比的是"变没变",不是"合不合格" |

### 10.5 ★ 一条新陷阱,本刀踩到并记下

**按行切开再匹配,会漏掉多行的 JSX 开标签** —— 这是 AGENTS.md 已经记了三次的形状,
本刀的第一版静态计数器又踩了一次:`<input ... onChange={(e) => …}` 里的 `>`
把正则截断,于是"没有 className 的站点"被数多了。
**改法:逐字符扫描,按大括号深度与引号找标签真正的结尾。**
两版的差是 41 vs 36(非 hidden 的无 className 站点),**而结论(18 个被接上)两版一致**。

---

## 11 · ★ 一条【本刀修不了】的红:冒烟今天一条路由都跑不到

```
✗ /verify/cod/[token]
    段 [token] 【不在】 ID_SOURCES 里
SMOKE_OWN_EXIT=1        ← 0 秒,连 dev server 都没起
```

**它不是本刀造成的,而这句话是量出来的:**

| 查的是什么 | 结果 |
|---|---|
| `git status --porcelain app/verify` | **空** —— 本刀一个字节没碰 |
| `git status --porcelain scripts/smoke-routes.mjs` | **空** |
| 那条路由是谁建的 | `9b71b4e` **COD-2,2026-09-08** —— 早于本刀的 HEAD |
| `git show HEAD:scripts/smoke-routes.mjs \| grep -c '\[token\]'` | **0** |

☞ **这道闸自 2026-09-08 起对每一刀都是红的,而 INPUT-2 是第一个真去跑它的。**
(第二轮那份 `smoke1.log` 里装的其实是 PermissionMatrix 探针的输出,**冒烟那一轮没跑过**。)

**为什么本刀不顺手修:** `ID_SOURCES` **一律 `select=id`**,而 `[token]` 是一枚
**122 位随机令牌**,不是任何一行的 `id` —— 它**结构上走不了那条路**,
只能进 `SPECIAL_ID_ROUTES` 或 `EXPECTED_SKIPS`。而选哪一条要先答一个**属于 COD 的问题**:
那条路由有 **200 / 404 / 429 / 503** 四种状态(作废的证书是 404,限流是 429),
**挑错一个就是一次会绿的假断言**。在一刀刚被它绊倒时现写这个判据,
正是 AGENTS.md 点名的「匆忙的检查者」形状。
☞ **已登记:`docs/known-issues.md` → `SMOKE-PREFLIGHT-COD-TOKEN`,带去处。**

**★ 那么渲染层这一刀靠什么证?** 靠两次真实渲染,而它们比冒烟更贴近本刀要证的东西:
`--mode=drift` 走了 **141 条静态路由 × 2 视口**、`--mode=edit` 又走了一遍编辑态,
**每一条都断言了「文档 complete + body 有字 + React 已水合」**,
最终 **282 格读数里 not-ok 0 条**。
⚠ **但它不是冒烟的替代品**:它**不断言 HTTP 状态码**,也不管 `EXPECTED_SKIPS` 那套覆盖断言。
**这一栏的诚实说法是:冒烟没跑成,而本刀有另一份更窄的证据。**

---

## 12 · Tim 该去看哪儿

> 全部用 **admin** 就够(下面每一条都注明它真正需要的权限)。手机档一律 **390px**。

| 路由 | 视口 | 看什么 | 需要的权限 |
|---|---|---|---|
| ★ **`/logistics/lanes`** | ★ **390px** | 顶上两张表单**不再横向溢出**(+4px,基线是 +12px);★ **两颗下拉的「SG Singapore」尾巴被截掉了** —— 那是 390px 上给不起的宽度,不是 bug | `module.purchasing.edit` |
| `/logistics/lanes` | 1440px | 桌面**看起来和以前一样**(`name` 168px、下拉 160px,文字装得下) | 同上 |
| `/hr/leave/holidays` | 两个 | **勾选框**:16×16、圆角 4px、未选中 `#62738C` 边、选中 `#007FAD` 填 + 白勾 | `module.hr.view` |
| `/materials/new` | 两个 | **单选框**:16px 圆、选中 = `#007FAD` 边 + 8px 圆点(底仍透明) | `module.materials.edit` |
| ★ **`/inbound/receive`** | ★ **390px** | **E6 触控档**:高度仍是 **48px**(没有掉到 32px);★ **底色从白变成页面底 `#F1F9FE`** —— 裁定要的,但看得见 | `module.inbound.edit` |
| `/settings/dictionaries` | 两个 | **DataTable 的筛选框**(表上方那个搜索框)采用了新样子 | `module.settings.view` |
| `/finance/journal/new` | 两个 | **原生下拉**(6 颗):32px 高、8px 圆角、**浏览器自己那颗箭头还在** | `module.finance.edit` |
| `/settings/roles/<admin 角色>` | 两个 | 表里 29 个勾选框变成 16×16;**行高 37 → 38px** | `module.settings.edit` |
| `/hr/reviews/cycles` | 两个 | 多行框:64px 下限、随内容长、**右下角竖向拖拽手柄还在** | `module.hr.edit` |

---

## 13 · 每一步的实测时长

| 步 | 起(UTC) | 止 | 秒 | 退出码 |
|---|---|---|--:|--:|
| `/logistics/lanes` 改前几何读数 | 11:59:49 | 12:00:09 | **20** | 0 |
| ⚠ 第一支几何探针整跑(**结果全丢**,§10.1) | 12:03:42 | 12:42:39 | **2337** | **2** |
| **`--mode=drift`**(141 条 × 2 视口) | 12:44:40 | 13:09:25 | ★ **1485** | 0 |
| 单条补量 `/finance/freight/new` | 13:09:25 | 13:10:42 | **77** | 0 |
| **`--mode=edit`** | 13:10:42 | 13:13:07 | **145** | 0 |
| 单条补量 `/purchasing/discrepancies`(+ 陪跑) | 13:14:41 | 13:15:58 | **77** | 0 |
| 并入 + 行高比对器 + `--mode=compare` + 宽度分析 | 13:16 | 13:18 | **~15** | 0 / 0 / 0 |
| 下拉几何 + PermissionMatrix(59 条 × 2 视口) | 13:18:12 | 13:27:59 | **587** | 0 |
| 12 张不合身截图 | 13:29:55 | 13:30:37 | **42** | 0 |
| `/logistics/lanes` 复量 ×2(加 `md:` 前后) | 13:33:23 | 13:34:59 | **26 + 23** | 0 / 0 |
| `check-i18n` | 13:36:42 | 13:36:42 | **<1** | 0 |
| 冒烟(预检当场拒) | 13:36:52 | 13:36:52 | **0** | **1** |
| `npm run build`(第一次,量具缺桩) | 13:39:05 | 13:39:08 | **3** | **1** |
| `npm run build`(补桩后) | 13:39:35 | 13:40:13 | **38** | 0 |
| `db/gate.py` | 13:40:43 | 13:47:26 | **403** | 0 |

---

## 14 · INPUT-2b 的估价 —— **两个数,分开报**

### 14.1 流程那一半(来自**本次会话实测**)

| 项 | 秒 | 来源 |
|---|--:|---|
| `--mode=drift` | 1485 | 本次实测 |
| `--mode=edit` | 145 | 本次实测 |
| 单条补量 ×2 | 154 | 本次实测 |
| 比对器 + compare + 分析 | ~15 | 本次实测 |
| `npm run build` | 38 | 本次实测 |
| `db/gate.py` | 403 | 本次实测 |
| **合计(不含施工与写文档)** | ★ **≈ 2240 秒 ≈ 37 分钟** | |

⚠ **上面**不含**:一次整跑失败重来的可能(本次就发生了一回,烧掉 2337 秒),
以及冒烟(今天跑不成,§11)。

### 14.2 施工那一半(来自**第二轮实测的每站点秒数**)

**第二轮实测:C.3「转换 190 个站点」= 780 秒 → 4.1 秒/站点。**
按委托书要求,把它套到 INPUT-2b 的 **401 A / 2 B / 12 C**:

| 算法 | 结果 |
|---|---|
| **① 照字面套**(415 × 4.1s) | **≈ 1702 秒 ≈ 28 分钟** |
| ★ **② 修正后(这一个才可信)** | ★ **≈ 2.0 – 2.5 小时** |

**为什么①偏低,而修正是必须的:**
INPUT-2 那 190 个站点**不是 190 次编辑** —— 它们由 **49 个常量**覆盖,
改一个常量就动一批站点。**真实的每次编辑成本 ≈ 780 / 49 ≈ 16 秒。**
而 INPUT-2b 的 **A 类 401 处是【各写各的 inline class 串】,每一处都是独立的一次编辑**。

* **A 类:401 × 16s ≈ 6400 秒 ≈ 1 小时 47 分**
* **B 类:2 处手改**(模板 / 三元 / 字符串加法)≈ 10 分钟
* **C 类:12 处**(6 个文件上传接 `CONTROL_FILE_BUTTON` · 5 处字色照 Q12 留 / 1 处剥)≈ 30 分钟
* **合计 ≈ 2 小时 20 分**,再加 §14.1 的流程 ≈ **37 分钟**。

⚠ **两条不确定,照直说:**
① 那 415 是第二轮分类器给的,**本刀没有重量**,而它自己写着 A 类只抽查了 15/401;
② 它还欠一件 INPUT-2 没做的事:**给 `INPUT_COMPONENT_CLASS` / `TEXTAREA_COMPONENT_CLASS`
做一道常驻的闸**(本刀是**手工**证的逐字节相同)。

---

## 15 · 我不能核实的

* **58 条 `[id]` 动态路由**上的控件 —— 量具走不到(§8)。**改过,没量过。**
* **点开才出现的**控件:对话框、折叠行、`<details>` 里的列显隐面板。
* **HTTP 状态码与冒烟的覆盖断言** —— 冒烟今天跑不成(§11)。
* **别的浏览器**:全部读数只在 **chrome-headless-shell** 上取得;
  原生 `<select>` 的箭头位置与保留区**其他浏览器一次都没验证**。
* **那 415 处 INPUT-2b 站点**的分类(未重量),以及 **A 类里有没有假阴性**。
* **第二轮那份「204/220 合标准」** —— 本刀换了判据(逐成员比),没有重跑它。
* **真人的手**:所有结论来自 CDP 的读数与截图,**没有人真的用手机点过这些控件**。

---

## 16 · 给测试的人(counts toward v1.4.17; released after INPUT-2b and INPUT-3)

When you open a form on your phone, the boxes you type in, the dropdowns you pick from and the tick-boxes you tap should now all look like one another — the same height, the same rounded corners, the same grey outline — except on the receiving and stock-count screens, where they stay deliberately taller so you can still hit them while holding a scanner; if you find a box that still looks like the old style, that is expected for now, because the remaining screens are being converted in the next two rounds.

---

pbcopy < docs/handbacks/INPUT-2.md
