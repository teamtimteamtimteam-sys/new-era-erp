# BUGFIX-1a · 交回报告(2026-09-12)

> ## ★ 一句话:开发服务器又起得来了,日历重新读得到集装箱到港日,请假单不再印出一个 i18n 键,任务步骤的日期选择器不再把焦点从你手里抢走,而打字不再把多行框越撑越宽。

> ### ★★ 本刀【不发版本】。`v1.4.18` 在 BUGFIX-1b 落地之后才发。 ★★
> ★ **数据库一个字节都没有改**:没有迁移、`db/` 下一个文件都没有动、线上业务数据**一行都没有写过**。

---

## 0 · 一页纸

| 条 | 它坏在哪 | 判词 | 本刀做了什么 |
|---|---|---|---|
| ★ **X** 开发服务器 | 一份**交回报告**里的一句散文被 Tailwind 扫成了一条**非法 CSS 声明**,`next dev` 每条路由 500 | ★ **PROVEN(两臂控制实验)** | 把扫描源限死在 `app/` 与 `lib/`;新增 `check-generated-css` 进构建链 |
| **a** 日历读不到 Container ETA | `container_no` **从来没有存在过**;挡住类型闸的是 6 句 `as never` | ★ **PROVEN(屏幕两臂 + 类型注入)** | 改列名 + 空值回落 `code` + 拿掉全部 cast;新增 `check-select-columns` 进构建链 |
| **c** 请假来源印出 i18n 键 | 值由**函数体**合成,而闸从**表的 CHECK** 枚举 —— 按构造看不见 | ★ **PROVEN(屏幕两臂 + 闸的两臂)** | 补两个键;把那道闸接上**两个源** |
| **e** 日期选择器关不掉 | `disabled={pending}` 切在**人正在操作的那一颗**上,焦点当场销毁且不归还 | ★ 机制 **PROVEN(按住请求实测两臂)**;「于是浮层关得掉」**SUSPECTED** | 不再 disable 正在操作的控件;两颗日期框都改 |
| **g** 多行框越打越宽 | `field-sizing: content` **管两个轴**,表格按 max-content 分列宽 → 宽度从邻居那一列抢 | ★ **PROVEN(复现出来了,带读数)** | `CONTROL_TEXTAREA` 加 `max-w-0 min-w-full` |
| **f** 日期浅色 | — | — | ★ **Tim 2026-09-12:去掉。** 不修、不转、不排队 |
| **b · d** | — | — | ⬜ **BUGFIX-1b**(裁定已写进队列,不再只活在聊天里) |

---

## 1 · §1 开工闸 —— 每一项都重查过

| 判据 | 读数 | 判词 |
|---|---|---|
| §1.1 `HEAD` | `54451b16abc21332c161593e715ee959c6e06a35` | ★ **等于 `origin/main`**(`git fetch` 之后复查),`git status --porcelain` **一行都没有** |
| §1.2 `git diff --stat 0f66f3e7… HEAD -- app/ lib/ scripts/ messages/` | ★ **空**(退出码 0) | ★ **FONT-2 的改后读数就是本刀的改前读数** |
| §1.3 round 1 的产物 | ★ **全部在**,只有一处路径对不上 | ⚠ 委托书写的是 `/tmp/bugfix1/tw/tw-proof2.sh`,**文件实际在 `/tmp/bugfix1/tw-proof2.sh`**(680 字节,`tw/` 的**同级**,不在它里面)。★ **文件在,所以不是「缺失」,是委托书的路径多了一段** —— 照直记,不停刀 |
| §1.3 FONT-2 的改后读数 | ★ **三份都在**:`controls-drift-merged.json`(2,100,392 B)· `controls-edit-baseline.json`(101,577 B)· `docs/row-height-baseline.md`(57,434 B) | 不必补量 |

---

## 2 · §1.5 —— 委托书里当作阈值用的每一个数,逐条重量

> **规矩(AGENTS.md CONFIRM-1):委托书里的数字一个都不许直接引用。下面每一行都带量法。**

| # | 委托书 / round 1 写的 | 本刀实测 | 判词 |
|---|---|---|---|
| 1 | 旧 `FIX-1` 被引用 **157 行 / 59 个文件**(`.md` 9 · `app/` 32) | ★ **157 / 59(.md 9 · app/ 32)**<br>量法:`git grep -n "FIX-1" HEAD` 再排掉 `UI-FIX-1` · `MANUAL-FIX-1` · `GUARD-FIX-1` · `GST-FIX-1` · `DARK-FIX-1` 五个同形前缀 | ★★ **CONFIRMED —— 逐个数字对上**。⚠ **不排那五个前缀就得 203 / 68**,所以这个数**离不开它的量法** |
| 2 | 委托书自己的「约 94 处 / 15 个文档」 | **157 行 / 59 个文件** | ★ **WRONG**(低估,且口径漏掉 32 个 `app/` 下的代码文件) |
| 3 | 「静态路由 141,而 glob 漏掉 `app/page.tsx`,真数 142」 | ★★ **机制是错的。** `/` **在**名单里;141 与 142 的差额是 **`/brand-sampler`**:<br>`skip brand-sampler : static 141 · has "/" = true`<br>`include brand-sampler: static 142 · has "/" = true` | ★★ **WRONG(而它是一次【被更正过的更正】)** —— 差额存在是真的,替它编的原因是假的。登记进 `docs/known-issues.md` 的 `STATIC-ROUTE-COUNT-141-vs-142` |
| 4 | `container_no` 是被删或被改名的 | ★ **从来没有存在过**(`git log -G` 在 `db/` 下 0 次提交);`containers` 今天 **18 列**,叫 `container_number`(**可空**),另有 `code`(**NOT NULL**) | ★★ **WRONG,而它改变了 item a 的形状** |
| 5 | `check-i18n` 的动态前缀「166 个,72 个只读表枚举」 | ★ **167 个**;**只读表约束的 70 个**(本刀之前 71)· 表约束+另一个源 **3** · 不读表约束 **94**<br>量法:解析 `MANIFEST`,按每条调用了哪支解析器分类 | **WRONG(差 1 / 差 1)** |
| 6 | item a 的表×列普查「3693 条对,去重 1749,缺 1」 | ★ **修完之后:3694 条(去重 1748),缺 0**。<br>⚠ **改前那棵树上我没有重跑这支闸** —— 冒烟当时正开着,而把 `sources.ts` 改回去会触发一次重编译,**那会污染正在跑的那一趟**。<br>☞ 两个数**对得上**(那一句 select 从 3 列变 4 列 → 对数 +1),但**「3693 / 1749」这两个数本刀【没有】亲自量过。** | ★ **NOT RE-MEASURED(一致,但不是我量的)** |
| 7 | 「55 处写入点」 | ★★ **130 处**(insert 47 · update 74 · upsert 9) | ★★ **WRONG** |
| 8 | item c:「余额表上 6/6 行用的是那个缺键」 | ★ **NOT RE-MEASURED** —— 本刀改从**屏幕**证:`/hr/leave/[id]` 上那个键出现 **2 次**(en 与 zh 各 2 次),补键之后变成「Monthly accrual」/「按月累计」各 2 次 | **没有重量那个 6/6,说明白** |
| 9 | item e:`NodeTree.tsx:195` = Steps 标题 · `hr/leave/[id]/page.tsx:73` 的动态键 | ★ `page.tsx:73` **CONFIRMED**(⚠ 而 `check-i18n` 报的是 **:68** —— 那是**提到这个前缀的那句注释**,不是渲染点) | ★ **CONFIRMED,附一条差异** |
| 10 | item g:「`/hr/kpi/score` 上进不去、11 颗按钮里没有 Edit」 | ★★ **原因不是权限,是 `?cycle=`。** 带上 `?cycle=<2026-09>` 之后:**1 张表 · 30 行都有 Edit 钮**;admin 实测持有 `module.hr.edit` **与** `data.view_reviews` | ★★ **WRONG(而它是 round 1 三次失败的全部原因)** |
| 11 | `next dev` 上「141 / 142 条 500」 | ★ **本刀重量的是 5 条**(`/` · `/tools/calendar` · `/hr/leave` · `/finance` · 一条 DataTable 列表页 `/suppliers`):**改前 0/5 是 200(五条全 500)· 改后 5/5 是 200** | ★ **CONFIRMED(在一个更小的样本上)** |
| 12 | `npm run build` 38 秒 | 见 §8 | 见 §8 |

★ **合计:CONFIRMED 3 · WRONG 6 · NOT RE-MEASURED 2 · 见 §8 的 1。**

---

## 3 · ★ X —— 开发服务器的 CSS 故障

### 3.1 病因(PROVEN)

| # | 断言 | 证据 |
|---|---|---|
| 1 | `app/globals.css:1` 是 `@import "tailwindcss";`,**没有任何 `@source`** | 源码 |
| 2 | Tailwind v4 的自动源探测于是把**整个项目**当类名来源,**包括 `docs/*.md`** | 官方机制;下面第 4 行是它的直接后果 |
| 3 | `docs/handbacks/FONT-2.md` 里有**一句散文**,把「品牌色那一族的任意值类名」写成一个**带星号通配**的简写 | 全仓库只有那一处 |
| 4 | 于是生成出来的 CSS 里**真的**多出一条 `color:` 值里带裸星号的非法声明 | ★ **本刀按构建的走法重编一遍(`postcss` + `@tailwindcss/postcss`,cwd = 仓库根,from = `app/globals.css`)→ 输出 101,335 字节,那条非法声明在【第 1966 行】** —— 与 dev server 报的 `./app/globals.css:1966:24` **逐字对上** |
| 5 | 后果 | ★ **改前 `next dev` 上 5/5 条路由 HTTP 500**,dev 日志里 `Parsing CSS source code failed`(`/tmp/bugfix1a/devcheck-before.log`) |
| 6 | ★ **生产构建不受影响** | 同一条在 `next build` 里只是一句 warning —— **线上一直是好的** |

### 3.2 修法

```css
@import "tailwindcss" source(none);
@source "../app";
@source "../lib";
```

★ **语法是从 `node_modules/tailwindcss/dist/lib.js`(v4.3.1)里读出来的,不是猜的**:
`source(…)` 由 `@tailwind utilities` 的参数(以及 `@import` 转成的 `@media …` 包装)解析;
`@source` 的路径**必须带引号**,相对**这个 CSS 文件**解析,所以写 `../app` 而不是 `./app`。

### 3.3 §X 第一问 —— **哪些目录里有类名**(实测,不是假设)

| 目录 | 带 `.ts/.tsx/.js/.jsx/.mdx/.css` 的在册文件 | 里面有类名吗 | 收不收 |
|---|--:|---|---|
| `app/` | **900** | **598 个**文件里有类名样的文本 | ★ **收** |
| `lib/` | **46** | **5 个**命中,而**真类名只有 `lib/valuation.ts` 那三条状态色**(`bg-green-100` / `bg-amber-100` / `bg-red-100`);另外 4 个是散文与内联 `style` | ★ **收** |
| `messages/` | **2** | ★ **0 个** —— 唯一一条命中是注释里那个文件名 `machine-text-reaching-humans.md`(被 `text-` 撞上) | 不收 |
| 仓库根 | **2**(`next.config.ts` · `proxy.ts`) | ★ **0 个**(`className` / `class=` / `@apply` 全部 0 次) | 不收 |
| `public/` `assets/` `supabase/` | **0** | — | 不收 |

### 3.4 §X 第二问 —— **有没有类丢掉**(逐条比对)

| | 改前 | 改后 |
|---|--:|--:|
| 生成出来的 CSS | **101,335 字节** | **96,780 字节** |
| **唯一选择器** | ★ **998** | ★ **954** |
| 非法声明 | **1** | ★ **0** |

★ **少 44 条,多 0 条(998 − 44 = 954)。** 44 条逐条列在 `/tmp/bugfix1a/css/removed.txt`:

```
animate-pulse · bg-blue-500 · bg-blue-700 · bg-green-500 · bg-yellow-50 · blur ·
border-[color:...] · border-[color:…] · collapse · disabled:bg-gray-100 ·
file:bg-blue-600 · file:bg-gray-800 · file:px-4 · file:py-2 · file:rounded ·
file:text-white · flex-shrink · focus:outline-none · invisible · lg:block · lg:hidden ·
md:w-40 · md:w-42 · min-h-14 · min-h-24 · min-h-[3.5rem] · ordinal · outline-ring ·
outline-ring/50 · overflow-auto · pr-4 · ring · ring-2 · shadow · sm:flex-row ·
sm:px-4 · sm:table-row · static · text-[color:var(--brand-*)] · text-black ·
text-gray-300/400 · w-34 · w-42 · w-screen
```

**★ 每一条都对着【收进来的那两个目录】查过:0 条是活着的类。**

> ### ★ 这份报告自己就带着那个字符串 —— 而它现在是安全的,这一点值得看一眼
> 上面那张名单里逐字写着 `text-[color:var(--brand-*)]`(**委托书要求把 44 条【逐条】列出来**,
> 少一条就不是一份完整的证据)。
> ★ **在这一刀之前,把它写进 `docs/` 下任何一份文件,都会把同一条非法声明生成回来。**
> 现在不会了 —— 而这句话**不是推理,是量出来的**:本文件带着这两处字符串落盘之后,
> `node scripts/check-generated-css.mjs` 仍然 **EXIT=0**
> (`1104 条规则 / 1453 条声明,两支解析器都没有一条告警`)。
> ☞ **这就是「一个纯文档的提交不能再改变渲染」那句话的实测形态。**
判据是**整颗候选**,不是子串 —— `bg-blue-700` 出现在 `hover:bg-blue-700` 里是**另一个候选**
(它生成的是 `.hover\:bg-blue-700:hover`)。
★ **控制组**:4 条正例(`flex` · `text-[color:var(--brand-muted-text)]` · `md:text-sm` · `bg-primary`)
全部报 PRESENT;2 条反例(`flex-shrink` · `bg-blue-700` —— 树里只写过 `flex-shrink-0` /
`hover:bg-blue-700`)全部报 ABSENT。**没有这两组,那个 0 就是一个说不清的 0。**

> ### ★ 三条原始命中,以及为什么它们不是反例 —— 这一格值得读两遍
> 粗比对报了 3 条「还活着」:`blur`(`app/login/login.module.css` 的一句注释)·
> `outline-ring/50`(`app/brand-tokens.css` 的一句注释)· `text-[color:var(--brand-*)]`
> (★ **我自己刚写进 `app/globals.css` 注释里的那一句**)。
> ★ **三条全部在 `.css` 文件里,而目录形式的 `@source` 【不扫 `.css`】** —— 这是**量出来的**:
> `app/__twprobe.css` 里的 `bg-fuchsia-950` → **生成 0 条**;
> `app/__twprobe.tsx` 里的 `text-lime-950` → **生成 1 条**。两个探针文件都已删除。
> ★ 即便如此,**我把自己那句注释改掉了**,不照抄那个字符串 ——
> **把同一颗雷埋进正在拆它的那个文件,是这一族最容易犯的第二次错。**

### 3.5 §X 第三问 —— `next dev` 真的起得来吗

同一支脚本、同一个一次性 admin、同一个端口(3211),**两臂**:

| 路由 | 改前 | 改后 |
|---|--:|--:|
| `/` | **500** | ★ **200**(6931ms) |
| `/tools/calendar` | **500** | ★ **200**(2501ms) |
| `/hr/leave` | **500** | ★ **200**(2141ms) |
| `/finance` | **500** | ★ **200**(2453ms) |
| `/suppliers`(DataTable 列表页) | **500** | ★ **200**(2053ms) |
| dev 日志里的 `Parsing CSS source code failed` | ★ **有** | ★ **没有** |
| 脚本退出码 | `1` | ★ **0** |

### 3.6 回归检查 `scripts/check-generated-css.mjs`

* **它做什么**:用 `postcss` + `@tailwindcss/postcss`(`postcss.config.mjs` 里那唯一一个插件)
  按构建的走法编译 `app/globals.css`,再把结果交给 **`lightningcss`** ——
  **`next build` 用来优化生成 CSS 的正是它** —— 开 `errorRecovery` 解析,
  ★ **把 warnings 与 errors 一起当失败**(AGENTS.md:健康检查的阈值默认是零)。
* **在构建链里**:`npm run build` 的 `check-instrument-selfproof` 之后、`check-lint` 之前;
  另有 `npm run check:css`。
* **它通过**:`✓ … 生成出 1102 条规则 / 1451 条声明,postcss 与 lightningcss 两支解析器都没有一条告警(88ms)`,`EXIT=0`
  <br>⚠ 那是**做 item g 之前**跑的;收工时构建链里同一支报的是 **1104 条规则 / 1453 条声明** ——
  多的两条正是 item g 加的 `.max-w-0` 与 `.min-w-full`。**两个数都对,它们量的是两棵不同的树。**
* ★ **故障注入 ①(委托书点名的那一条)**:往 `app/` 放一个临时文件,里面写上那种散文 →
  ★ **EXIT=1**,并点名 `app/globals.css(生成后)第 1906 行第 24 列`。**临时文件已删除。**
* ★ **故障注入 ②(把它弄瞎)**:拿掉 `@source "../app"` → ★ **EXIT=2**,
  `覆盖断言失败 —— 这一次读数不作数`,并逐条列出 5 条**必须生成得出来**的工具类一条都没命中。
  **已还原,还原后 EXIT=0。**
* **覆盖断言**:① 生成出来的声明数 > 0;② **两条独立的路数同一批规则**
  (postcss 的 AST ↔ 按文本数规则开头)—— 实测 **1102 ↔ 1102**;
  ③ 一张**必须生成得出来**的工具类名单(`.flex` `.text-sm` `.rounded-lg` `.font-medium` `.border`)。
* `check-instrument-selfproof`:★ **37 支量具都写了瞄准线,其中 24 支(构建链里的)带覆盖断言**,EXIT=0。

---

## 4 · item a —— 日历读不到 Container ETA

### 4.1 病因(PROVEN)

★ **`container_no` 这一列从来没有存在过。** 不是被删,也不是改名 ——
TOOLS-1(2026-09-03)一出生就拼错(`git log -G'container_no'` 在 `db/` 下 **0 次提交**)。
☞ **Container ETA 从那天起一天都没有出现在日历上。**

**线上只读实测(2026-09-12):** `containers` **18 列**,`container_number`(**可空**)、
`code`(**NOT NULL**);**没有** `container_no`。
`leave_calendar` **15 列**,有 `legal_name` 与 `employee_code`;**没有** `employee_name`
—— 于是 `sources.ts:150` 那句 `employee_code ?? employee_name` 的**第二支是死代码**,
日历上永远只画得出工号。

### 4.2 修法(Tim 2026-09-12 的裁定,逐条)

| 裁定 | 落地 |
|---|---|
| `containerEta` 选 `container_number` 与 `code` | `select('id, code, container_number, expected_arrival_date')` |
| 显示 `String(r.container_number ?? r.code)` | 逐字照做 |
| 请假显示 `legal_name`,回落 `employee_code`,再回落 `'—'` | `String(r.legal_name ?? r.employee_code ?? '—')` |
| 拿掉 `as never` 并给查询补真类型 | ★ **6 句全部拿掉**;`Spec.run` 的返回类型 `Promise` → **`PromiseLike`**(PostgREST 的构造器**不是** Promise,是 thenable —— **那就是那 6 句 cast 存在的唯一原因**)。**没有动第二个文件,`lib/database.types.ts` 一个字节没碰。** |
| `tsc` 必须过 | ★ `npx tsc --noEmit` **EXIT=0,0 行输出** |

### 4.3 ★★ 类型闸现在真的咬得动 —— 这一格是本条最值钱的证据

把 `container_no` 放回去再跑一次:

```
TSC_INJECTED_OWN_EXIT=2
app/tools/calendar/sources.ts(196,24): error TS2322: …
  SelectQueryError<"column 'container_no' does not exist on 'containers'.">
```

☞ **一句为了让类型过关而加的 cast,关掉的正是那个会抓住这个错的检查。**
(已写进 `AGENTS.md` 的失效模式清单。)

### 4.4 屏幕两臂

| | `/tools/calendar?month=2026-08` |
|---|---|
| **改前**(`sources.ts` 在 HEAD 上) | ★ `data-calendar-failures` **2 处**;横幅逐字:<br>「One or more sources could not be read, so this month is INCOMPLETE: `containerEta: column containers.container_no does not exist`. This is not the same as "nothing scheduled".」<br>★ **一个集装箱号都没有** |
| **改后** | ★ **0 处** `data-calendar-failures`;★ **四个集装箱号全部渲染**(`GXCU58721373` · `MRXL43829465` · `FIBU45362785` · `ZZLOG5BU00001`,各 8 次) |
| **改后 `/tools/calendar`(当月,2026-09)** | ★ **0 处** `data-calendar-failures` |

### 4.5 ★★ 一条必须先说的读数 —— 别把空当成故障

**线上只读:`expected_arrival_date` 落在 2026-09 的集装箱 = ★ 0 条。**
四条带 ETA 的全部在 **2026-08**。
☞ **九月的日历上 Container ETA 是空的,那【不是】故障。** 要看见它,把月份翻到 **2026-08**。

⚠ **顺手量到、刻意不修的一条**:那四条里 `CTR-2026-0005` / `ZZLOG5BU00001` 是**软删的**,
而 `containerEta` 那一支**没有 `deleted_at` 过滤**(同一个文件里 `task` 那一支有)。
★ 加过滤是一次**看得见的行为改动**,Tim 的裁定里没有它 —— 登记进
`docs/known-issues.md` 的 `CALENDAR-CONTAINER-SOFT-DELETED`,**本刀不改**。

### 4.6 回归检查 `scripts/check-select-columns.mjs`

**它比的是**:`app/` 与 `lib/` 里每一处 `.from('<表>')` 的**读列**与**写键**,
对着 `lib/database.types.ts` 的 `Tables` + `Views` 两节(`Row` / `Insert` / `Update`)。

| 读数(2026-09-12) | |
|---|--:|
| 镜像里的表与视图 | **333** |
| `app/`+`lib/` 下的 `.ts/.tsx` | **941** |
| `.from('<表>')` 站点 | **997** |
| · 读得准并查过的 `select` 站点 | **833** |
| · `select('*')`(按定义没有列可查) | **46** |
| · `.select(变量)` 解析不出 · 列串里有 `${}` | **0 · 0** |
| ★ **查过的表×列对** | ★ **3694**(去重 **1748**),内嵌关系上的 **181** |
| 写入点(insert 47 · update 74 · upsert 9) | **130** |
| · 读得准的(花括号字面量,含 9 处带展开) | **102** |
| ★ **查过的写入键** | ★ **397**(去重 **302**) |
| ★ **读不准的写入点(逐条打印、计数,不当作通过)** | ★ **28** |
| ★★ **对不上的** | ★★ **0**(分母 3694 + 397) |

**覆盖断言(三条,都是同一次运行里的第二条独立路径):**
① 镜像里按缩进读出的关系数 ↔ 文件里 `Row: {` 的块数 —— **333 ↔ 333**;
② 链行走器数出的 `.from` 站点 ↔ 纯文本数出的 —— **997 ↔ 997**;
③ 不含括号的列串:char 行走器 ↔ 按逗号切开 —— 相等;
外加一张**必须查得到**的表×列名单(`containers.container_number` · `containers.code` ·
`leave_calendar.legal_name` · `tasks.due_date`)。

**故障注入,三格全咬:**

| 注入 | 退出码 | 它说了什么 |
|---|--:|---|
| 一份**临时副本**,把 `container_number` 换回 `container_no` | ★ **1** | `app/tools/calendar/__bugfix1a-copy.ts:196 containers.container_no —— 镜像里没有这一列` |
| 一个临时文件 `insert({ title, no_such_column })` | ★ **1** | `tasks.no_such_column —— 镜像的 Insert 里没有这个键` |
| 把镜像里的 `Row: {` 改名(**弄瞎它**) | ★ **2** | `覆盖断言失败 —— 这一次读数不作数`(333 ↔ 0) |

★ **三处临时改动全部还原**,还原后 EXIT=0;`git status` 里一条都没剩。

> ### ★★ 它自己的故障注入抓住了它自己的一个瞎点 —— 记下来
> **第一版用 `git ls-files` 列文件,于是一个【还没有加进索引的新文件】它一个字都看不见**,
> 两格注入**双双报绿**。改成走文件系统之后两格都咬。
> ☞ **一道闸要看的是「这棵树现在是什么样」,不是「索引里记着什么」。**

---

## 5 · item c —— 请假单的「Source」列印出一个 i18n 键

### 5.1 病因(PROVEN)

`leave.grantType_` 的后缀集合此前**只**从 `db/tables/leave_grants.sql` 的 `CHECK` 枚举 ——
拿到 4 个值,**每一个都有翻译**,于是 `check-i18n` 报「缺键 0」。
而屏幕上真正用到的是**第 5 个**值 `monthly_accrual`,它由
`db/functions/leave_balance_internal.sql:76` 的 `jsonb_build_object` **在函数体里现合成**,
**不在那条 CHECK 里**。

> ★★ **最值钱的一格:同一个 `jsonb_build_object` 吐出来的另一个键(`'status'` → `leave.grantStatus_`)
> 配了一支专门去扒函数体字面量的解析器 —— 就在 `MANIFEST` 的隔壁一行。**
> **同一种形状,一个接对了源,一个没有。**

### 5.2 修法

* `messages/en.ts` → `grantType_monthly_accrual: 'Monthly accrual'`
* `messages/zh.ts` → `grantType_monthly_accrual: '按月累计'`
  (★ 刻意与 `pro_rata` 的「按月折算」分开:一个是**挣到的**,一个是**折算的**)
* `scripts/check-i18n.mjs`:新增通用解析器 `jsonbLiteralValues(file, key)`,
  `grantTypeValues()` 用它读 `'grant_type'`;`MANIFEST` 的 `leave.grantType_` 改成
  `union(sqlEnum(leave_grants 的 CHECK), grantTypeValues)` —— **与 `grantStatus_` 同一个形状**。
  ★ 解析出 0 个就**抛**(一支解析不出东西的解析器不是一个空集合)。

### 5.3 ★ 证它会咬人(委托书点名的四步)

| 步 | 命令 | 退出码 | 它说了什么 |
|---|---|--:|---|
| 1 | 把两行新键**拿掉**,`node scripts/check-i18n.mjs` | ★ **1** | ★ `app/hr/leave/[id]/page.tsx:68  leave.grantType_monthly_accrual —— 缺于 en 与 zh(后缀自真源枚举)` |
| 2 | 放回去再跑 | ★ **0** | `✓ 代码引用的每一个键(含可枚举的动态键)en 与 zh 都在。` |
| 3 | `git diff messages/` | — | ★ 两行**都在**(见下) |

```diff
+        grantType_monthly_accrual: 'Monthly accrual',
+        grantType_monthly_accrual: '按月累计',
```

⚠ **一处差异,照直说**:`check-i18n` 报的行号是 **:68**,那是**提到这个前缀的那句注释**;
**真正的渲染点在 :73**。两个数都对得上各自的东西,但它们不是同一个东西。

### 5.4 屏幕两臂(一条只读的请假单 id)

路由:`/hr/leave/7c4aecce-89f5-4d32-aeb1-9784cae5d65a`(`LV-2026-0003`)

| | en | zh |
|---|---|---|
| **键不在的时候** | ★ 生的 `leave.grantType_` 印出 **2 次** | ★ 生的 `leave.grantType_` 印出 **2 次** |
| **键在的时候** | ★ **`Monthly accrual` × 2** | ★ **`按月累计` × 2** |

### 5.5 ⚠ 第二个渲染点 **没有**在屏幕上验证到 —— 说明白

`app/me/MyLeavePanel.tsx:58` 是同一个动态键的第二处。
★ **`/me` 本身是可达的(HTTP 200,en 与 zh 都是)**,但那块面板**不渲染** ——
一次性 admin **没有员工档案**,而 `/me` 把这件事**说了出来**:

> **“Your account is not linked to an employee record yet — Ask an administrator to link it,
> and your profile, payslips and training will appear here.”**

☞ **那一处代码点是【未测量】,不是【不存在】。** 它与 `/hr/leave/[id]` 是**同一个键、同一个前缀**,
而 `check-i18n` 覆盖的是**键**,不是渲染点。

### 5.6 覆盖注记(登记,不在这一刀里修)

`check-i18n` 的 **167** 个动态前缀里,★ **70 个只从表约束枚举**(本刀之前 71),
**3 个接了两个源**(`leave.grantType_` 本刀接上的 · `leave.grantStatus_` · `claims.state_`),
**94 个完全不读表约束**。
round 1 逐个找过渲染点,**命中 1 / 72**(当时的分母)—— 就是本条。
★ **通用检出器 round 1 做过两版,两版都不能用**(477 条噪音;收窄之后 411 条**而且弄丢了真正那一个**)。
**照直说:这一族的通用检出器还没有做出来。**
登记在 `docs/known-issues.md` 的 `I18N-DYNAMIC-PREFIX-TABLE-ONLY-70`。

---

## 6 · item e —— 任务步骤的日期选择器

### 6.1 病因(机制 PROVEN)

`disabled={pending}` 切在**人正在操作的那一颗** input 上。
本刀用 CDP **把那次保存的 POST 按住不放**,在「保存还在飞」的那一刻读控件:

| 读数(同一支脚本、同一个步骤、两臂) | 改前 | 改后 |
|---|---|---|
| `hasAttribute('disabled')` | ★ **true** | ★ **false** |
| `el.disabled` | ★ **true** | ★ **false** |
| `document.activeElement === 这颗 input` | ★ **false**(activeElement = **BODY**) | ★ **true** |
| 600ms 之后再读一次 | 同上 | ★ **仍然 true** |

☞ **焦点当场销毁,而且切回来也不还**(同一个 DOM 节点,没有 remount)。
★ **原生日期浮层靠的就是【这颗 input 上的】失焦 / 外部点击去关掉它**,而它那一刻已经不是焦点。

### 6.2 ★ R3 —— 一个字节都没有写进去

* 那次 server action 的 POST 被 **`Fetch.failRequest`** 失败掉,**从来没有到过服务器**。
* 事后用只读查询复查那一行:

```
LIVE BEFORE : {"id":"560bb669-…","title":"Dinner","target_date":"2026-09-12","updated_at":"2026-09-11T22:38:59.627691+08:00"}
LIVE AFTER  : {"id":"560bb669-…","title":"Dinner","target_date":"2026-09-12","updated_at":"2026-09-11T22:38:59.627691+08:00"}
LIVE ROW UNCHANGED: true
```

★ **两臂各跑一次,两次都 `UNCHANGED: true`**(连 `updated_at` 都逐字相同)。

### 6.3 修法 —— **最小的那一个**

**不再 disable 人正在操作的那颗控件**;防重复提交改成「pending 时忽略后续的 change」:

```diff
-   disabled={pending}
-   onChange={(e) => run(() => setNodeDate(taskId, n.id, e.target.value || null))}
+   onChange={(e) => { if (pending) return; run(() => setNodeDate(taskId, n.id, e.target.value || null)) }}
```

★ **`disabled` 是把控件从人手里拿走;这一句只是不听第二次。**

### 6.4 同形状的站点,全树普查

**判据**:一个 JSX 开标签**同时**带 `disabled={…}` 和一个**发起保存**的 `onChange`。
分母摆出来:**619 个 `.tsx` 文件 / 13,048 个 JSX 开标签 / 其中 386 个带 `disabled={…}`。**

| 站点 | 控件 | 处置 |
|---|---|---|
| `app/tools/tasks/[id]/NodeTree.tsx:101` | `<input type="date">` | ★ **改了** |
| `app/purchasing/orders/[id]/ExpectedDateControl.tsx:40` | `<input type="date">` | ★ **改了**(同一个形状) |
| `app/inbound/[id]/edit/DeepDischargePanel.tsx:90` | 原生 `<select>` | **列出来,没有改** |
| `app/purchasing/orders/[id]/DeepDischargeJudgementControl.tsx:42` | 原生 `<select>` | **列出来,没有改** |
| `app/tools/tasks/[id]/NodeTree.tsx:77` | `<input type="checkbox">` | **列出来,没有改** |

★ **改完之后同一支普查:带这个形状的日期框 5 → 3(日期框那一类 2 → 0)。**

★ **新增步骤那一行(`NodeTree` 的 `addForm`)【没有】这个形状** —— 它的日期框
**不带 `disabled=`**,`onChange` **只改本地 state、不发保存**。所以那里没有东西要改。

### 6.5 ⚠ 我【没能】验证的,以及 Tim 要试哪一下

★ **原生日期浮层在无头浏览器里观察不到** —— 它**不在 DOM 里**,headless Chrome 也不弹它。
☞ **机制是 PROVEN;「于是浮层现在关得掉」仍然是 SUSPECTED。**

> ### ★ 请 Tim 亲手试这一下
> 打开 **`/tools/tasks/5968e9c4-c59b-40c4-b2b0-b2d72c4fe081`**(任务 **“Chicken Duck Talk”**),
> 找到步骤 **“Dinner”**(它今天的日期是 **2026-09-12**),
> **点它的日期、挑一个新日期,然后点浮层外面** —— 浮层应当关上。

⚠ **另一件顺手看到、本刀没有改的**:那颗日期框是**受控于服务端数据**的,
所以在那一次往返回来之前,**你挑的日期会先弹回原值**(两臂都是这样,值停在 `2026-09-12`)。
**这不是本刀造成的,也不是这一条要修的东西。**

---

## 7 · item g —— 多行框越打越宽 · ★ **本刀修了**

### 7.1 §3 G 第 1 步 —— 读 `ScoreEditor.tsx`,两颗多行框差在哪

★★ **它们【逐字相同】。** 两颗都用同一个常量
`const ta = \`${CONTROL_TEXTAREA} w-full\``,两列的 `className` 都是 `align-top text-xs`。
☞ **差别不在类串上,在【内容】上。**

**哪些行会渲染出来,以及为什么一次性 admin 看不到 —— 答案不是权限:**
★ **`/hr/kpi/score` 没有 `?cycle=<真的 id>` 就【不画表】。** 那是这一页自己的裁定
(抬头逐字:「月份【永远】不默认成当月 …… 没有默认值」)。
★ 实测 admin **持有** `module.hr.edit` **与** `data.view_reviews` 两个码 ——
带上 `?cycle=` 之后:**1 张表 · 30 行,每一行都有 Edit 钮**。
☞ **round 1 三次失败的全部原因就是那个缺席的 `?cycle=`。**

### 7.2 §3 G 第 2 步 —— 复现(★ **PROVEN**)

`?cycle=0dd108ad-…`(周期 **2026-09**,30 条),行 **Cheng Siong Phua / C1
“Equipment delivery & installation”**,桌面 **1440**,编辑态,
★ 用 **`Input.insertText`** 打字,**一次都没有提交**;
★ 探针把**每一个**带 `Next-Action` 头的 POST 都 `failRequest` 掉;
★ 事后只读复查 `kpi_entries`:**30 条里带 evidence_note / feedback_note 的仍然是 0 / 0,`LIVE UNCHANGED: true`**。

| 状态 | Evidence | Feedback | 封顶理由 |
|---|--:|--:|--:|
| 空 | **50.25px** / h64 | **54.33px** / h64 | **500.09px** / h64 |
| 往 Evidence 打 **109** 个字 | ★ **235.20px** / h98 | 54.33px | 353.44px |
| 再往 Feedback 打一个 **65** 字的不可断行长词 | 100.47px / **h238** | ★ **467.66px** / h64 | 141.94px |

☞ **宽度跟着内容长,而且那点宽度是从【邻居那一列】抢来的** ——
Tim 截图里「Evidence 窄得换行、Feedback 宽得一行到底」正是这一格。

### 7.3 §3 G 第 3 步 —— 是不是控件那一族造成的:**是**

`CONTROL_TEXTAREA` 的 `field-sizing: content`(**INPUT-2 于 `115340c`,2026-09-10 引入**)
**管两个轴**;而 `<table>` 的自动布局**按各格的 max-content 分宽度**。
☞ 于是多行框的 max-content 贡献 = 它里面的字,**那就是列宽**。

### 7.4 候选宣告,逐个在页面里量 —— ★ **每一条都回读过,证明它真的生效了**

| 候选 | 回读(生效了吗) | 打字之后 Evidence / Feedback | 判词 |
|---|---|--:|---|
| 基线 | — | 100.47 / 467.66 | — |
| `max-width:100%` | ★ 生效(`max-w=100%`) | **100.47 / 467.66** | ★★ **一点作用都没有** |
| `min-width:0` | ★ 生效(`min-w=0px`) | **100.47 / 467.66** | 没用 |
| 两条一起 | ★ 生效 | **100.47 / 467.66** | 没用 |
| ★ **`max-width:0` + `min-width:100%`** | ★ 生效(`max-w=0px` `min-w=100%`) | ★ **50.25 / 54.33** | ★ **成** |
| `width:0` + `min-width:100%` | ★ 生效 | 50.25 / 54.33 | 同一个结果 |
| `max-width:16rem` | ★ 生效(256px) | 118.44 / 256 | 能封顶,★ **但它把【空态】也改了**(封顶理由 500.09 → 256)—— **否掉** |
| `field-sizing:normal` | ★★ **没能通过 CSSOM 应用**(回读仍是 `content`) | — | ★ **不评价**(没应用过的声明,和无效的声明,读数上长得一样) |

★ **机制:百分比的 `max-width` 在【内在尺寸】计算里当 `none`** —— 而决定这一列宽度的正是内在尺寸。
☞ **这是 FONT-1 在 `<fieldset>` 上付过的那笔账的第二张脸**(`docs/variant-c-spec.md` §4.7.9)。

> ### ★★ 这一步自己栽过一次,记下来
> 头一版用 `el.style.setProperty('maxWidth', …)` —— ★ **`setProperty` 不认驼峰名**,
> 于是那一轮「三个候选全都无效」的读数里**有三个根本没有被应用过**。
> **是那一列回读把它抓住的。** ☞ **每一次「它没有效果」的结论,都要先证明「它真的生效了」。**

### 7.5 落地的那一条

```diff
-export const CONTROL_TEXTAREA = ['flex field-sizing-content min-h-16', SHAPE, …]
+export const CONTROL_TEXTAREA = ['flex field-sizing-content min-h-16 max-w-0 min-w-full', SHAPE, …]
```

★ **为什么写 `max-width` 而不是 `width:0`**:两者实测**效果完全相同**,
而**调用点上普遍写着 `w-full`** —— 在共享模块里再写一次 `width` 就是**同一个属性的第二处声明**,
胜负要靠生成出来的 CSS 顺序,那是不可预测的。`max-width` / `min-width` 与 `w-*` **不冲突**。
生成出来的 CSS 已核对:`.max-w-0 { max-width: 0 }` · `.min-w-full { min-width: 100% }`。

### 7.6 改后读数(同一支探针、同一行、同一段字)

| 状态 | Evidence | Feedback |
|---|--:|--:|
| 空 | **50.25px** / h64 | **54.33px** / h64 —— ★ **与改前逐字相同** |
| 109 个字 | ★ **50.25px** / **h598**(改前 235.20 / h98) | 54.33 / h64 |
| 再打 65 字长词 | 50.25 / h598 | ★ **54.33px** / **h338**(改前 467.66 / h64) |
| 表宽 · 整页横向溢出 | **1376 / 1376**,**1440 / 1440**(**0**) | ★ **两项都与改前逐字相同** |

☞ **宽度由容器封顶,高度照长 —— 正是裁定要的那件事。**

### 7.7 R5 —— 关掉的那一族一个字节都没有动

* `TEXTAREA_COMPONENT_CLASS`(`<Textarea>` 组件自己发的那一串):★ **未改**。
  `<Textarea>` 今天唯一的使用者是 `app/brand-sampler/Variant.tsx`(**R5 关掉的文件**)。
* `INPUT_COMPONENT_CLASS`:★ **未改**。
* `table-style.ts` · FONT-1/FONT-2 的 base 层 · 链接 token · 字体栈 · `app/login/` ·
  `app/brand-sampler/`:★ **一个都没有碰**。
* 原生 `<select>` 上那条 `min-w-0` / `max-w-full` 禁令:★ **原样有效,一点都没有放宽。**

### 7.8 ⚠ 一条【报出来、但不是停手理由】的后果

那两列不再向表格要宽度,于是它们**回落到表头那点宽**(约 50px),
于是 109 个字变成**一格 598px 高**。
★ **空态逐字未变**;列宽是**表格自己的分配**,不是这条规则给的。
☞ **给这两列一个宽度是 `POLISH-1` 的事**,已写进队列。

### 7.9 ⚠ 390px 上量不到,而那个 0 的含义要说清楚

`<EditableTable>` 的手机档(`phone={{ mode: 'columns' }}`)把**非 `priority`** 的列收起来,
于是那三颗多行框在 390px 首屏上是 **0×0**。
★ **回读 `getComputedStyle` 证明类确实生效了**(`max-width:0px` / `min-width:100%`)——
所以那个 0 是**「首屏上不显示」**,不是「量具失灵」。
两臂的整页读数都是 **390 / 390**、滚动壳 **326 / 326**,**逐字相同**。

---

## 8 · §7 检查、闸与量具 —— 每一条带它【自己】的退出码与实测时长

| 步 | 命令 | 退出码 | 实测时长 | 读数 |
|---|---|--:|--:|---|
| §7.1 | `node scripts/check-i18n.mjs` | ★ **0** | **<1s** | ★ **缺键 0** —— `✓ 代码引用的每一个键(含可枚举的动态键)en 与 zh 都在。` |
| §7.2 | `npm run build` | ★ **0** | ★ **37s**(19:24:47 → 19:25:24 UTC) | ★ **26 条静态检查全绿,含两支新的**;`next build` 通过 |
| — | · `check-generated-css`(**新**) | 0 | 81ms | `生成出 1104 条规则 / 1453 条声明,postcss 与 lightningcss 两支解析器都没有一条告警` |
| — | · `check-select-columns`(**新**) | 0 | — | `3694 个表×列对(去重 1748)与 397 个写入键全部对得上`;另报 46 处 `select('*')` · 28 处读不准的写站点 |
| — | · `check-instrument-selfproof` | 0 | — | ★ **38 支量具都写了瞄准线;其中 25 支(构建链里的)带覆盖断言** |
| — | · **eslint 冻结闸** | 0 | — | ★ **基线 error 42 · warning 88;现在 error 42 · warning 87** —— ☞ **没有超过基线,而且【少了一条 warning】**(`app/hr/employees/EmployeeForm.tsx` 的 `no-unused-vars`,**不是本刀碰过的文件**)。★ **本刀【没有】跑 `--update-baseline`** —— 收紧基线是修那一处的人的事,不是顺手做的 |

### 8.0 ★★ 冒烟跑了两趟 —— 第一趟是我自己废掉的,照直说 ★★

★ **19:31:35Z,我在一条 `python3 -c "…"` 的参数里留了一对反引号,而 zsh 把它当成命令替换
跑掉了 —— 跑的正是 `npm run build`。** 那一跑**重写了 `.next`**,
而当时**冒烟的 dev server 正开着**。

☞ **这正是 `smoke-routes.mjs` 自己抬头上写着的那个坑**
(「`npm run build` 会重写 `.next`,把正在跑的 dev server 搞死」),
也正是 `docs/known-issues.md` 里记过的那一次。

★ **处置:第一趟的读数【不作数】,整趟作废重跑。**

| 步 | 读数 |
|---|---|
| 停掉第一趟 | `SMOKE_OWN_EXIT=143`(SIGTERM) |
| ★ **活下来的进程,先证明它们是孤儿再杀** | `next dev` **pid 10159 · ppid=1** · `next-server` **pid 10174 · ppid=1** —— ★ **两个都是 `ppid=1`,而且都在冒烟自己的端口 3199 上**。证完才 `kill -9` |
| 清理计划 | `reap-ephemeral` → `✓ 没有滞留的清理计划`,`.ephemeral/` 空 |
| live-lock | 已释放 |
| ★ 线上一次性账号 | ★ **`smoke-%@test.local` 0 个 · `bugfix1a-%@test.local` 0 个** |
| 重跑前 | `rm -rf .next` |
| 第二趟 | 19:32:58Z 起跑,读数见下 |

> ### ★ 一句要记住的 —— 已写进 `AGENTS.md`
> **一个量具的读数,可以被【别的地方一条毫不相干的命令】悄悄废掉,而它的日志里看不出来。**
> 第一趟的日志里没有任何一行说「我的服务器被换掉了」—— 它会照常跑完,照常给一个数。

### 8.2 §7.3 冒烟(**第二趟,干净的那一趟**)

```
node scripts/smoke-routes.mjs        （没有 --reach）
SMOKE2_OWN_EXIT=0
```

| 读数 | |
|---|---|
| 起 → 止 | **19:32:58 → 19:39:45 UTC** |
| ★ **实测时长** | ★ **407 秒(6 分 47 秒)** —— ⚠ FONT-2 记的是 **1007s**。**同一棵树、同一支脚本,差 2.5 倍**;本刀这一跑是**冷 `.next`**。☞ **照它排节奏可以,照它设超时不行。** |
| ★ **结果** | ★★ **248 ok · 6 skipped(没有数据)· 0 FAILED** |
| 走了多少 | 229 条路由 + 16 支附加探针(评估人视角 · 查询串 · 试用期入口 · 客户页入口 · 现金预测 · 报销 · 考勤 · WHT · 管理包/总账导出 · 重叠入口 · 留存面板 · 登出态 `/login`) |
| 请求计时 | **223 条计时 · 合计 339.6s · 中位数 1427 ms** |
| ⚠ 顺手报的滞留临时行 | ★ **不是这一刀的** —— 那是在案的 `SMOKE-SCRATCH-ROWS-STALE`(6 条 `ZZ-SMOKE-*`,其中 5 条仍被真单据引用)。**那道检查自己写着「只报告,不删除」,本刀照规矩:报出来,不顺手删。** |
| `--reach` | ★ **没有跑**,照委托书与 `AGENTS.md`(它在这棵树上结构性地红着,且要一小时以上) |

### 8.3 §7.4 `db/gate.py` —— 整门,**零迁移也跑,而且在推送【之前】**

```
db/run_detached.sh --log /tmp/bugfix1a/gate.log \
    --label "db/gate.py 整门(BUGFIX-1a,零迁移)" --timeout 2700 --token GATE \
    -- python3 db/gate.py
GATE_EXIT=0
```

★ **判词【逐字】抄在这里,四条:**

> **判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)**
> **判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)**
> **判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)**
> **判词【匿名面】:✓ 线上是基线的子集(基线 327 条)**

| 读数 | |
|---|---|
| 起 → 止 | **19:41:06 → 19:44:2x UTC** |
| ★ 它自己报的 wall-clock | ★ **141s** |
| 重放 | `db/functions` **437** 个 · `db/tables` **215** 个 · `db/views` **117** 个 |
| 不变量 B1 / B2 | ★ **线上 0 / 0,重建库 0 / 0**(白名单 B1 1 · B2 6) |
| 匿名面 | 关系 **326** · 函数 **1**(`cod_verification(text)`)· 公开桶 **0** · 列级 ACL **0** |
| `check_grants` 的自检 | ★ **两格注入都变红**(基线打瞎 · 查询打瞎) |
| ★ **为什么零迁移也要跑** | 委托书点名要求,而理由在 `AGENTS.md`:**门是绿的这件事本身是一条要写进报告的事实**,而「这一刀没动数据库」是一句**断言**,不是一次测量。★ **这一跑就是那次测量** |

### 8.1 §7.2 的两条顺带读数,照直说

* `check-cjk-rendered` 也报「少了 1 条(基线可以变短)」—— ★ **同样不是本刀造成的**,同样没有收紧。
* `npm run build` 之后 `.next/BUILD_ID` 存在;★ **跑冒烟之前 `rm -rf .next`** ——
  `next dev` 压在一个生产构建上会发 404(这是在案的坑)。

---

## 9 · ★ Tim 该去哪儿看 —— 路由 · 视口 · 需要什么身份

> **每一条都写清楚它需要什么权限,以及【看什么】。**

| # | 去哪儿 | 视口 | 需要什么 | 看什么 |
|--:|---|---|---|---|
| 1 | **`/tools/calendar`** | 桌面 | `module.logistics.view`(看 Container ETA) | ★ **月视图顶上那条红字 INCOMPLETE 横幅【不见了】。**<br>⚠ **当月(2026-09)Container ETA 是空的,那不是故障** —— 线上这个月一条 ETA 都没有 |
| 2 | **`/tools/calendar?month=2026-08`** | 桌面 | 同上 | ★ **四条 Container ETA 出现了**:`GXCU58721373` · `MRXL43829465` · `FIBU45362785` · `ZZLOG5BU00001`。<br>⚠ 最后那一条是**软删的过渡期测试数据**,已登记(`CALENDAR-CONTAINER-SOFT-DELETED`),**本刀刻意没改** |
| 3 | **`/hr/leave/7c4aecce-89f5-4d32-aeb1-9784cae5d65a`**(`LV-2026-0003`) | 桌面 | `module.hr.view` | ★ 余额表 **Source** 列:英文界面写 **“Monthly accrual”**,中文界面写 **「按月累计」** —— **不再是 `leave.grantType_monthly_accrual`** |
| 4 | 同上,**切成中文** | 桌面 | 同上 | ★ 同一列读作 **「按月累计」**,与 `pro_rata` 的「按月折算」**分得开** |
| 5 | ★★ **`/tools/tasks/5968e9c4-c59b-40c4-b2b0-b2d72c4fe081`**(任务 **“Chicken Duck Talk”**) | 桌面 | `module.tasks.edit` | ★★ **这一条只有人能确认:** 找到步骤 **“Dinner”**(日期 **2026-09-12**),**点它的日期、挑一个新日期,再点浮层外面 —— 浮层应当关上。**<br>⚠ 无头浏览器**看不到**原生浮层,所以这一格必须由你来判 |
| 6 | **`/hr/kpi/score?cycle=0dd108ad-1059-4d1b-8471-1586ba252931`**(“Scores for 2026-09”) | 桌面 | `module.hr.edit` **且** `data.view_reviews` | ★ 找 **Cheng Siong Phua** 的 **“Equipment delivery & installation”**,点 **Edit**,往 **Evidence** 里打一长串字 —— ★ **那一格【不再变宽】,字换行,格子往下长。**<br>⚠ **没有 `?cycle=` 就看不到表** —— 那是这一页自己的裁定,不是故障 |
| 7 | **`/hr/kpi/score?cycle=…`** | **390px** | 同上 | ⚠ **Evidence / Feedback 两列在手机上本来就收起来**(非 `priority` 列),所以这一条在手机上**看不到** |
| 8 | 任意一条路由 | 任意 | 任意 | ★ **`npx next dev` 现在起得来** —— 改这一刀之前,它上面**每一条路由都是 500** |

---

## 9b · §5.4 截图(★ **全部在仓库外**:`/tmp/bugfix1a/shots/`)

| 文件 | 拍的是什么 | ★ 它证明了什么(我逐张看过) |
|---|---|---|
| `calendar-2026-08.png` | `/tools/calendar?month=2026-08`,桌面 | ★★ **没有红字横幅**;**四条 Container ETA 都画出来了** —— 8/15 的 `GXCU58721373` 与 `MRXL43829465`,8/17 的 `FIBU45362785` 与 `ZZLOG5BU00001`。页脚写着 `8 item(s) this month, gathered from 6 sources concurrently in 351 ms` |
| `calendar-current-month.png` | `/tools/calendar`(2026-09),桌面 | ★ **没有横幅**;Container ETA 那一类**这个月是空的 —— 因为线上这个月一条都没有** |
| `leave-detail-zh.png` | `/hr/leave/…`(`LV-2026-0003`),**中文** | ★★ **「来源」列读作「按月累计」** —— 不是生键,而且与 `pro_rata` 的「按月折算」**一眼分得开** |
| `leave-detail-en.png` | 同上,**英文** | ★ 同一列读作 **“Monthly accrual”** |
| `task-steps-dinner.png` | `/tools/tasks/…`(“Chicken Duck Talk”),桌面 | ★ Tim 要手试的那一屏与那一步(**Dinner**)的样子 |
| `e-before-inflight.png` · `e-after-inflight.png` | item e 两臂,**保存被按住的那一刻** | 见 §6.1 |
| `g-before-1440.png` · `g-after-1440.png` | item g 两臂,桌面 | 见 §7.2 / §7.6 |
| `g-before-390.png` · `g-after-390.png` | item g 两臂,390px | 两张**字节数逐字相同** —— 与「那两列在手机上本来就收起来」对得上(§7.9) |

---

## 10 · §2 规矩,逐条 DONE / NOT DONE

| 规矩 | 判词 | 证据 |
|---|---|---|
| **R1** 线上数据库只读:不建、不改、不删业务数据 | ★ **DONE** | 全程只读查询;两次会写的操作(改一个步骤的日期 · 往 KPI 格子里打字)都被 **CDP `Fetch.failRequest`** 拦在浏览器里,**请求从来没有到过服务器**;事后各自用只读查询复查,**行逐字未变**(含 `updated_at`) |
| **R1** 不迁移、`db/` 下不改 | ★ **DONE** | `git status` 里 `db/` 一个文件都没有;提交时按显式路径暂存,**不含 `db`** |
| **R2** 一次性账号只走 `scripts/ephemeral.mjs`,并且要清干净 | ★ **DONE** | 每一支探针都先 `openPlan()` 落一份清理计划再动手,收尾 `runPlan()`;残留见 §12 |
| **R3** 不许让用户的写到达服务器 | ★ **DONE** | 见上;两处各留了一份两臂读数 |
| **R4** 每条结论标 PROVEN / SUSPECTED | ★ **DONE** | §3–§7 每一格都带判词;唯一的 SUSPECTED 是「原生浮层关得掉」(§6.5) |
| **R5** 关掉的那一族不许动 | ★ **DONE** | `table-style.ts` · `<Input>`/`<Textarea>` 的类串(含 `TEXTAREA_COMPONENT_CLASS`)· FONT-1/2 的 base 层 · 链接 token 与类 · 字体栈 · `docs/handbacks/**` · `app/login/` · `app/brand-sampler/` —— ★ **一个字节都没有改**(见 §11 的改动清单)。`control-style.ts` 里只动了 `CONTROL_TEXTAREA`,而且是按 §3 G |
| **R6** 出了范围的不做 | ★ **DONE** | **item b** 一行代码都没碰 · **item d 的兜底**一行都没碰 · **item f** 按 Tim 的裁定**去掉** · FONT-3 / POLISH-1 的条目**一件都没做** |

---

## 11 · 改了哪些文件 —— 逐个,以及【为什么它在这份清单里】

| 文件 | 归哪一条 | 改了什么 |
|---|---|---|
| `app/globals.css` | **X** | 第一行加 `source(none)` + 两条 `@source`,外加一段说明它修的是什么 |
| `app/tools/calendar/sources.ts` | **a** | 列名 · 空值回落 · 请假显示姓名 · 拿掉 6 句 `as never` · `run` 的类型 `Promise`→`PromiseLike` |
| `messages/en.ts` · `messages/zh.ts` | **c** | 各加一个键 |
| `scripts/check-i18n.mjs` | **c** | 新增 `jsonbLiteralValues()` / `grantTypeValues()`;`leave.grantType_` 接两个源 |
| `app/tools/tasks/[id]/NodeTree.tsx` | **e** | 日期框不再 disable 自己;pending 时忽略 change |
| `app/purchasing/orders/[id]/ExpectedDateControl.tsx` | **e** | 同上(同一个形状的第二处) |
| `app/components/ui/control-style.ts` | **g** | ★ **只有 `CONTROL_TEXTAREA` 加了 `max-w-0 min-w-full`**,外加它的理由 |
| ★ `scripts/check-generated-css.mjs` | **X** | **新文件** —— 生成 CSS 的解析闸 |
| ★ `scripts/check-select-columns.mjs` | **a** | **新文件** —— 表×列 / 写入键的对账闸 |
| `package.json` | X · a | 两支新闸进 `npm run build`;两个 `check:` 别名 |
| `docs/forward-queue.md` | 全部 | 改名 · 拆分 · 逐条结果 · BUGFIX-1b 的四条裁定 · item f 去掉 |
| `docs/known-issues.md` | 全部 | 5 条新条目(1 条关闭 + 4 条登记) |
| `docs/variant-c-spec.md` | **g** | 新增 §4.1f:多行框的宽度规则与它的读数 |
| `AGENTS.md` | 全部 | CONFIRM-1 表加一行;4 段新的失效模式 |
| `docs/handbacks/BUGFIX-1a.md` | — | 本文件 |

---

## 12 · §5 改后读数 —— 全量控件普查 · 行高闸 · 停止条件

### 12.1 §5.1 普查(`SURVEY_OUT=.survey-out/bugfix1a-after`)

| | 读数 |
|---|---|
| `--mode=drift` | ★ **`DRIFT_OWN_EXIT=0`**;desktop **141** 条 + phone **141** 条;8 条覆盖断言全过 |
| ⚠ **phone 上卡死了 2 条** | `/finance/gst` · `/hr/employees/new` —— ★ **这是在案的 `FONT2-PROBE-WEDGE-390`**(约 1/141,每趟 1 条,**每次卡的不是同一条**,共同点只有「都在 phone」)。**不是这一刀造成的。** |
| ★ **补量** | `SURVEY_OUT=.survey-out/bugfix1a-repair --only=/finance/gst,/hr/employees/new,/tools/pricing/calculator` → ★ **`REPAIR_OWN_EXIT=0`,三条都读出来了** |
| ★ **合并** | ★ **只把那两条的 phone 读数并进来;伴随路由 `/tools/pricing/calculator` 的读数按规矩【丢掉】。**<br>合并之后 `routes still unread: 0`。<br>☞ **覆盖率仍然是 282 / 282,而其中 2 个是【第二次】才读到的** —— 写出来,不藏起来 |
| `--mode=edit` | ★ **`EDIT_OWN_EXIT=0`**;全树只有 **4** 条静态路由住着 `<EditableTable>`:<br>`/hr/kpi/score` **0 颗候选**(★ 没有 `?cycle=` 就没有行,所以**这一刀改到的那几颗多行框根本不在这份基线里**)· `/hr/leave/types` 13 颗候选 → 表内控件 0→12 · `/hr/reviews/scale` 4 颗 → 0→14 · `/me` 0 颗 |

### 12.2 §5.2 `--mode=compare`(对 FONT-2 的改后读数)

| 比什么 | 成员 | 多出来 | 少掉 | ★ **值变了** |
|---|--:|--:|--:|--:|
| `drift`(FONT-2 merged ↔ 本刀 merged) | **3552 ↔ 3552** | **0** | **0** | ★★ **0** |
| `edit`(FONT-2 ↔ 本刀) | **118 ↔ 118** | **0** | **0** | ★★ **0** |

> ⚠ **两跑的退出码都是 `1`,而那不是失败。** 这支比对器是**给致盲用的**:
> 「三个数全是 0 → EXIT 1」说的是**「这次致盲什么都没拿走,证明不了任何事」**。
> ★ **用在改前 / 改后上,同一个 0 的意思正好相反:【一个渲染出来的控件都没有变】。**
> 这一格写在这里,是因为**一个不带解释的 `EXIT 1` 会被下一刀读成一次回归**。

### 12.3 §5.2 行高闸

```
node scripts/check-row-height-baseline.mjs \
  --now=.survey-out/bugfix1a-after/controls-drift-merged.json \
  --edit=.survey-out/bugfix1a-after/controls-edit-baseline.json \
  --row-height=report --baseline-heading="FONT-2 之后的读数"
ROWHEIGHT_OWN_EXIT=0
```

> ✓ **12 张含控件的表逐项与基线相同(表头高 · 行数 · 最大行高 · 滚动壳内容宽);
> 390px 整页溢出没有新增也没有长大;12 张已裁定横滚的表一张都没有多出滚动范围。**

比过:**12 / 基线 12 张**;编辑态 **2 / 2 张**;整页溢出 **基线 5 条 ↔ 读数 5 条**。
(输出里那 5 条「表头签名逐字相同」是**量具自己的身份说明**,不是发现。)

### 12.4 §3 G 的停止条件,逐条对**每一条路由**

| 停止条件 | 读数 | 判词 |
|---|---|---|
| 390px 上原本是 0 的整页溢出变成 >0 | ★ **一条都没有**(行高闸:溢出没有新增) | ★ **没有触发** |
| 390px 上原本 >0 的整页溢出长大 | ★ **一条都没有**(基线 5 条 ↔ 读数 5 条,逐条相同) | ★ **没有触发** |
| 原本不横滚的表开始横滚 / 已横滚的表多出滚动范围 | ★ **12 张已裁定横滚的表,一张都没有多出范围** | ★ **没有触发** |
| 表头高 · 行数 · 最大行高变了 | ★ **12 张逐项相同** | ★ **没有触发** |
| `<Input>` / `<Textarea>` 的类串变了 | ★ **与 HEAD 逐字相同**(`diff` 退出码 **0**) | ★ **没有触发** |
| 「控件渲染宽度变了」 | ★ **一个都没变**(3552 个成员,值变 0) | **本来就只报告,不停手** |

### 12.5 §5.2 归因 —— **没有东西要归因**

★ **3552 + 118 = 3670 个成员,值变了的是 0。**
☞ X · a · c · e · g 五条,**没有一条在这两支量具看得见的范围里改变了任何一个渲染读数**。
这句话本身是可以解释的,而且解释要写下来:

* **X** 拿掉的 44 条选择器**没有一条是活着的类**(§3.4)—— 所以屏幕上什么都不会变;
* **a / c** 改的是**数据与文案**,不是几何;
* **e** 改的是**保存过程中的那一瞬间**,而探针从不触发保存;
* **g** 改的是**内在尺寸的贡献**,而 `max-w-0 min-w-full` 在一个**块级容器**里
  算出来的使用宽**就是** `w-full` 那个宽 —— 于是那 40 多个表单里的多行框**逐字不变**;
  ★ **它唯一改变行为的地方是【表格格子里 + 有内容】**,而那一格**这两支量具都够不到**(见 §13)。

---

## 13 · §5.5 UNMEASURED —— 改了、而这一趟【没有在屏幕上看见】的

| # | 什么 | 为什么没量到 |
|--:|---|---|
| 1 | ★★ **`/hr/kpi/score` 编辑态的那三颗多行框**(item g 真正改变行为的那一格) | ★ **两支常驻量具都够不到它**:`--mode=drift` 读首屏,而这一页**没有 `?cycle=` 就不画表**;`--mode=edit` 在这条路由上报 **0 颗候选**(没有行就没有 Edit 钮)。<br>☞ **本刀用一支一次性探针补量了它**(§7),读数写在这里,**而它不在任何一份常驻基线里** |
| 2 | `app/me/MyLeavePanel.tsx:58` 的 `leave.grantType_` | 一次性 admin **没有员工档案**,那块面板不渲染(§5.5) |
| 3 | ★ **40 多个表单里的多行框**(`CONTROL_TEXTAREA` 的其余调用点) | 它们**都在块级容器里且带 `w-full`**,而 `min-w-full` 在那里算出来的使用宽**就是** `w-full` 那个宽 —— 普查里 **3552 个成员值变 0** 已经把这一条量到了,但**没有一处是「打了字之后」的读数** |
| 4 | `app/me/MySelfAssessmentPanel.tsx:220` 那一颗多行框 | ★ 它是**唯一一处不写 `w-full`** 的 `CONTROL_TEXTAREA` 调用点(写的是 `block mt-1`)。`min-w-full` 会让它**填满容器**,而不再按内容取宽 —— ☞ **这是一处【渲染宽度可能变了】的地方,而它住在 `/me` 上,本刀的一次性身份进不去那块面板。报告,不是停手**(裁定:控件渲染宽度变了不是停手的理由) |
| 5 | 58 条带 `[id]` 的动态路由 | 两支普查**结构上只走静态路由**(取 id 那套机制住在 `smoke-routes.mjs` 里,复制它就是第二份会漂的定义) |
| 6 | 首屏之外的一切 | 对话框、展开的下拉、Tab 面板、折叠行从不打开 |
| 7 | ★ **原生日期浮层** | 不在 DOM 里,headless Chrome 不弹它(§6.5) |
| 8 | ★ **`/tools/calendar` 上请假条目显示姓名** | ★ **线上 `leave_calendar` 今天 0 行** —— 改法是对的(列名实测存在),但**屏幕上今天看不出区别** |

---

## 14 · 这一刀每一步的实测时长(UTC,`date -u` 逐步打的点)

| 步 | 起 → 止 | 秒 |
|---|---|--:|
| §1 开工闸(HEAD / diff / round 1 产物 / 改前读数) | 18:19:33 → 18:20:11 | **38** |
| §1.4 读文档(停止闸 · 队列 · 已知问题 · 交回报告 · AGENTS.md · 6 个源文件 · 4 支量具的抬头) | 18:20:11 → 18:23:02 | **171** |
| ★ **X** 开发服务器的 CSS 故障(含两臂 dev 实测 + 新闸 + 两格注入) | 18:23:02 → 18:32:41 | ★ **579** |
| ★ **a** 日历(含线上只读、类型注入、屏幕两臂、新闸 + 三格注入) | 18:32:41 → 18:42:38 | ★ **597** |
| **c** + **e**(含 check-i18n 两臂、屏幕两臂、CDP 按住请求的两臂) | 18:42:38 → 18:49:32 | **414** |
| ★ **g**(含复现、7 个候选逐个注入回读、落地、改后复量、两个视口) | 18:49:32 → 19:00:04 | ★ **632** |
| §6 文档(队列改名+拆分+四条裁定 · 5 条 known-issues · spec §4.1f · AGENTS.md 5 处) | 19:00:04 → 19:12:00 | **716** |
| ★ 全量普查 `--mode=drift`(**与写文档并行**) | 19:00:32 → 19:19:31 | ★ **1139** |
| 补量 `--only=`(两条卡死的 + 伴随路由) | 19:20:00 → 19:21:2x | **约 85** |
| `--mode=edit` | 19:21:30 → 19:22:4x | **约 75** |
| `--mode=compare` ×2 + 行高闸 | 19:22:5x → 19:24:3x | **约 100** |
| `check-i18n` | 19:24:40 → 19:24:40 | **<1** |
| ★ `npm run build` | 19:24:47 → 19:25:24 | ★ **37** |
| ★ `smoke-routes`(无 `--reach`) | 19:26:25 → 见 §8 | 见 §8 |

> ⚠ **「并行」那一行要说清楚**:全量普查是 `nohup` 起在后台的,而写文档不碰 `app/`,
> 所以它不会污染读数(★ 而且**这一刀之后,`docs/` 按构造已经不可能影响渲染了** —— 那正是 X 修掉的东西)。

---

## 15 · ★ 我【没能】验证的

| # | 没验证什么 | 为什么 |
|--:|---|---|
| 1 | ★★ **「日期浮层现在关得掉」** | 原生浮层**不在 DOM 里**,headless Chrome 也不弹它。机制 PROVEN(焦点不再被销毁),结论 **SUSPECTED**。☞ **要 Tim 手上确认**,路径写在 §9 第 5 行 |
| 2 | ★ **`/me` 上那第二个 `leave.grantType_` 渲染点** | 一次性 admin 没有员工档案(`/me` 自己把这件事说了出来) |
| 3 | ★ **日历上「请假显示姓名」** | 线上 `leave_calendar` 今天 **0 行** |
| 4 | ★ **`app/me/MySelfAssessmentPanel.tsx:220` 那颗多行框的渲染宽度** | 它是唯一不写 `w-full` 的调用点,而它住在进不去的那块面板上(§13 第 4 行) |
| 5 | **58 条动态路由 · 首屏之外 · 第二个视口之外的交互** | 两支普查结构上的边界(与 FONT-2 §15 逐字同一条) |
| 6 | ★ **Windows 上的表现** | 只在 macOS + `chrome-headless-shell` 上量过 |
| 7 | ★ **item b / item d 的任何东西** | **不在这一刀的范围里**(BUGFIX-1b) |
| 8 | **`/hr/kpi/score` 上「打了字之后」的那三颗多行框的【手机档】表现** | 手机档把那几列收起来,首屏上是 0×0 |

---

## 15b · §3–§7 逐条 DONE / NOT DONE

> **规矩:没有被提到的一条 = NOT DONE。所以下面把委托书的每一条都摆出来。**

### §3 X —— 开发服务器

| 要求 | 判词 | 在哪儿 |
|---|---|---|
| 先列出每一个**有类名**的目录(docs/ db/ scripts/ node_modules/ .next/ 之外) | ★ **DONE** | §3.3(5 个目录,各带分母) |
| 用**装着的那一版** Tailwind 自己的机制,**去 node_modules 读文档,不许假设语法** | ★ **DONE** | §3.2(从 `dist/lib.js` 读出的三条规则) |
| **不许改任何一份交回报告** | ★ **DONE** | `git status` 里 `docs/handbacks/` 只有**本文件**(新建) |
| 按构建的走法生成改前 / 改后 CSS,比选择器集合 | ★ **DONE** | §3.4(998 → 954) |
| **逐条列出**被拿掉的选择器 | ★ **DONE** | §3.4(44 条全列) |
| 每一条被拿掉的 token **必须不在收进来的目录里**;若在 → **STOP** | ★ **DONE,0 条命中** | §3.4(含 4 正例 + 2 反例,以及 `.css` 不被扫的实测) |
| 解释新增的选择器(预期 0) | ★ **DONE —— 新增 0 条** | §3.4 |
| `next dev` 起来,5 条路由都 200 | ★ **DONE(两臂)** | §3.5 |
| 新增 `scripts/check-generated-css.mjs` 进 `npm run build` | ★ **DONE** | §3.6 · §8 |
| 它在修好的树上通过 | ★ **DONE**(EXIT 0) | §3.6 |
| 它在**收进来的目录**里放一个带那种散文的临时文件时**变红**,之后删掉那个文件 | ★ **DONE**(EXIT 1,已删) | §3.6 |
| 它满足 `check-instrument-selfproof` | ★ **DONE** | §8(38 支 / 25 支) |

### §3 A —— 日历

| 要求 | 判词 | 在哪儿 |
|---|---|---|
| `containerEta` 选 `container_number` 与 `code`;显示 `String(r.container_number ?? r.code)` | ★ **DONE** | §4.2 |
| **先确认 `leave_calendar` 真正的列**;显示 `legal_name` → `employee_code` → `'—'` | ★ **DONE**(线上只读查过 15 列) | §4.1 · §4.2 |
| 拿掉 `as never` 并给查询补真类型;`tsc` 必须过 | ★ **DONE**(6/6,EXIT 0) | §4.2 |
| **不许改别的文件,不许改 `lib/database.types.ts`** | ★ **DONE** | §11 |
| 若某一句 cast 拿掉之后在 `sources.ts` 里修不了,就留着并说明 | ★ **不适用 —— 6 句全拿掉了** | §4.2 |
| 改完之后 `/tools/calendar` 在 dev 上**没有** INCOMPLETE 横幅 | ★ **DONE** | §4.4 |
| 只读查一次:日历这个月有多少条 ETA,免得把空当成故障 | ★ **DONE —— 0 条**,并写进「Tim 该去哪儿看」 | §4.5 · §9 |
| 新增 `scripts/check-select-columns.mjs` 进 `npm run build` | ★ **DONE** | §4.6 · §8 |
| 它比**表 × 列**,对着 `lib/database.types.ts` 的**表与视图两者** | ★ **DONE**(333 个关系) | §4.6 |
| 处理别名 · 内嵌关系 · `'*'`;**读不准的形状逐条列出并计数,不许静默放过** | ★ **DONE** | §4.6 |
| 也查 insert/update/upsert 的键(若同一支扫描器读得可靠),否则登记缺口与数目 | ★ **两件都做了**:查了 **397** 个键;**读不准的 28 处登记进 `known-issues`** | §4.6 |
| 覆盖断言:对数 > 0,且等于一个**独立**计数 | ★ **DONE(三条)** | §4.6 |
| 在修好的树上通过 | ★ **DONE** | §4.6 |
| 在一份**选 `container_no` 的临时副本**上变红,之后删掉 | ★ **DONE**(EXIT 1,已删) | §4.6 |
| 满足 `check-instrument-selfproof` | ★ **DONE** | §8 |
| **报出查过的对数与分母** | ★ **DONE** | §4.6 |

### §3 C —— 请假来源键

| 要求 | 判词 | 在哪儿 |
|---|---|---|
| 加 `leave.grantType_monthly_accrual`(en / zh) | ★ **DONE** | §5.2 |
| `check-i18n` 的 `leave.grantType_` 从**表 CHECK 与 `leave_balance_internal` 的字面量两者**枚举,与 `grantStatus_` 同形 | ★ **DONE** | §5.2 |
| 证它会咬人:拿掉两行 → 红且点名;放回去 → 绿;`git diff messages/` 里两行都在 | ★ **DONE(四步全做)** | §5.3 |
| 把另外那些「只从表约束枚举」的前缀登记成覆盖注记;**不在这里造通用检出器** | ★ **DONE** —— 登记 **70 个**(分母 167),**没有造检出器** | §5.6 |
| 两个渲染点在 en / zh 都显示译文 | ★ **一处 DONE,一处 NOT DONE 并说明** | §5.4 · §5.5 |
| 若 `/me` 对一次性 admin 不可达,**说出来** | ★ **DONE** —— 可达但那块面板不渲染,原文照抄 | §5.5 |

### §3 E —— 日期选择器

| 要求 | 判词 | 在哪儿 |
|---|---|---|
| 不再 disable 人正在操作的那颗控件;换一个办法防重复提交 | ★ **DONE** | §6.3 |
| **用最小的改动,并报出来** | ★ **DONE**(一个属性 + 一句 `if (pending) return`) | §6.3 |
| 全树找同形状的日期框(**含新增步骤那一行**) | ★ **DONE**(分母 619 / 13048 / 386) | §6.4 |
| 修掉同形状的**日期框** | ★ **DONE(2 处)** | §6.4 |
| 列出同形状的**别的控件类型**(select · 勾选框),**不改** | ★ **DONE(3 处)** | §6.4 |
| 不写库地验证:按住 server action,读 `disabled` 与 `activeElement` | ★ **DONE(两臂)** | §6.1 |
| 失败掉那次请求 | ★ **DONE** | §6.2 |
| 只读复查那一行的日期没有变 | ★ **DONE(两臂各一次)** | §6.2 |
| **说明白原生浮层测不到**,并写出 Tim 要试的那个任务与步骤 | ★ **DONE** | §6.5 · §9 |

### §3 G —— 多行框

| 要求 | 判词 | 在哪儿 |
|---|---|---|
| 1 读 `ScoreEditor.tsx`,解释两颗的差别;读**哪些行会渲染**、为什么一次性 admin 看不到 | ★ **DONE**(两颗类串**逐字相同**;是 `?cycle=`,不是权限) | §7.1 |
| 2 不写库地复现(`Input.insertText`,不提交);标 PROVEN / SUSPECTED | ★ **DONE —— PROVEN** | §7.2 |
| 3 若复现且元凶是 `CONTROL_TEXTAREA` → 改它;**候选宣告要在页面里逐个量,不许假设 `max-w-full` 有用** | ★ **DONE**(8 个候选,逐个回读) | §7.4 |
| 3 原生 `<select>` 的 `min-w-0` / `max-w-full` 禁令**不许放宽** | ★ **DONE —— 一点都没有放宽** | §7.7 |
| 3 `<Textarea>` 的类串**不许变** | ★ **DONE —— 与 HEAD 逐字相同** | §7.7 · §12.4 |
| 4 若没复现 → 转 POLISH-1 | ★ **不适用 —— 复现了** | §7.2 |
| 停止条件逐条 | ★ **DONE —— 五条全部没有触发** | §12.4 |

### §3 OTHER · §4 · §6

| 要求 | 判词 | 在哪儿 |
|---|---|---|
| 队列条目改名 `FIX-1` → `BUGFIX-1`,带一行理由;**2026-09-05 那个 FIX-1 不动** | ★ **DONE** | `docs/forward-queue.md` |
| 拆成 BUGFIX-1a / BUGFIX-1b | ★ **DONE** | 同上 |
| 把 Q2 / Q13 / Q3(含条件)/ Q14 写进 BUGFIX-1b 条目 | ★ **DONE(四条全写)** | 同上「BUGFIX-1b 的裁定」 |
| item f 记为**去掉**,带 Tim 的原话 | ★ **DONE** | 同上 item f |
| 登记 141 / 142 那条 | ★ **DONE,而且【更正了它的机制】** | `known-issues` `STATIC-ROUTE-COUNT-141-vs-142` · §2 |
| §4 工序 X → A → C → E → G → `tsc` | ★ **DONE**,每一步之后写 `/tmp/bugfix1a/progress.md` | §14 |
| §6 四份文档 | ★ **DONE** | §11 |

---

## 16 · 部署与残留

> ★ **这一节在紧随工作提交之后的一次【纯文档】提交里填** —— 与 FONT-1 / FONT-2 逐字同一条做法:
> **部署与残留的读数要等那一次推送真的上线之后才存在。**

### 16.1 §7.5–7.6 提交与推送

> ### ⚠ 一处**偏离委托书**的地方,先说出来
> 委托书 §7.5 写的暂存路径是:`app/` · `lib/` · `scripts/` · `messages/` · `docs/` · `AGENTS.md`。
> ★ **那份清单里没有 `package.json`,而本刀必须带上它** ——
> 两支新闸(`check-generated-css` · `check-select-columns`)是**写在 `npm run build` 那一串里**的,
> 不提交 `package.json`,它们就**只是仓库里两个没有人跑的文件**。
> ☞ **照做的话,这一刀的两道回归闸等于没有装。** 所以我把 `package.json` 一起暂存了,并在这里写明白。
> ★ **`db/` 下仍然一个文件都没有。**

| | |
|---|---|
| ★ **工作提交(工作 + 交回报告同一个)** | ★ **`fde508dab762dcbac6767aaa16a96e010af13868`** —— **16 个文件**,**+2027 / −41** |
| 暂存的办法 | ★ **逐条显式路径**:`git add -- app lib scripts messages docs AGENTS.md package.json`。<br>★ **`db/` 下一个文件都没有**(提交前后各查一次 `git diff --cached --name-only \| grep "^db/"` → 空) |
| ★ **`lib/` 实际改了几个文件** | ★ **0** —— 它在暂存清单里是因为委托书点名,而这一刀没有需要改它的东西 |
| ⚠ **§7.6 推送** | ★ **第一次尝试被自动模式的分类器挡下**(照在案的办法:**不自己换着花样重试**)。★ **Tim 在 2026-09-12 00:40 UTC 亲手把它推了出去。** |
| ★ **§7.6 三方 SHA** | ★★ **三个逐字相同,都是完整 40 字符:**<br>`HEAD        dd9be64ec8cfe349de1e80421aae4bfea60d7090`<br>`origin/main dd9be64ec8cfe349de1e80421aae4bfea60d7090`<br>`ls-remote   dd9be64ec8cfe349de1e80421aae4bfea60d7090`<br>(`git fetch` 之后测的,长度逐个数过:40 / 40 / 40) |
| 推送时刻 | **2026-09-12 00:40:26 UTC** |

### 16.2 §7.7 部署 —— ★★ **失败了。这一刀【没有】上线。** ★★

> ### ★★ 一句话:推送成功,而 **Vercel 的构建失败**。`v1.4.18` 这一半**没有**到生产上。
> ★ **生产【没有】坏** —— 失败的构建**不会被提升**,别名仍然服务上一次成功的那个版本。

**照委托书 §7.7 的三步做的,读数逐条:**

| 步 | 读数 |
|---|---|
| ① **有上限地等**(`db/wait_for.sh --timeout 900 --interval 20`,条件写在**完整 40 字符 SHA** 上) | ★ `✓ 等到了:Production deployment for dd9be64…(1s)`,`WAIT1_OWN_EXIT=0` |
| ② ★ **先把 deployment id 绑到 SHA**(问那一次部署**自己**,不是列表最新那条) | `id=6404122473` · ★ `sha=dd9be64ec8cfe349de1e80421aae4bfea60d7090` · `env=Production` · `created=2026-09-12T00:40:26Z` |
| ③ **绑好之后才问【它】的状态** | ★★ **`state=failure`** |
| ★ **它的状态记录有几条** | ★ **1 条** —— 只有 `failure` 那一条 |
| 它自己说的话(逐字) | `Deployment has failed — run this Vercel CLI command: npx vercel inspect dpl_5yckcANhgJMAyuoWR2hXt5VxKJEf --logs` |
| 面板链接 | `https://vercel.com/tim-s-projects7/new-era-erp/5yckcANhgJMAyuoWR2hXt5VxKJEf` |

#### ★ 它是不是本刀造成的 —— 量过,答案是【很可能是】

| 判据 | 读数 |
|---|---|
| 前四次 Production 部署的状态 | ★ **`success` · `success` · `success` · `success`**(`6397595033` `6397299064` `6397224637` `6392675820`) |
| 本刀这一次 | ★ **`failure`** |
| ☞ | **这是这条时间线上第一次失败,而本刀是第一次把两支新闸放进构建链的提交。** |

#### ★ 生产现在是什么状态 —— 实测,不是推理

| 判据 | 读数 |
|---|---|
| ★ **生产别名 `https://new-era-erp.vercel.app/`** | ★★ **HTTP 200**(1.94s) —— **生产是好的**,它服务的仍然是上一次成功的构建 |
| 失败那一次的部署 URL | `HTTP 302`(登录跳转,正常) |

#### ★★ 我为什么【没有】动手修 —— 以及我排除掉了什么

★ **本机够不到 Vercel 的日志。** AGENTS.md 记着「部署的真源是 Vercel」,而本刀把那五项**逐项重量**,
与 FONT-2 量到的**逐字相同**:

```
vercel CLI: ABSENT · vercel in package.json: ABSENT · .vercel/project.json: ABSENT
VERCEL_TOKEN: ABSENT · ~/.vercel: ABSENT · .env.local 里没有任何 VERCEL 变量
```

GitHub 那一侧也没有更细的东西:commit status **只有 1 条**(就是上面那句),check-runs **0 条**。

☞ **于是我做了唯一一件能做的事:把 Vercel 的构建在本机【尽可能忠实地】复现一遍。**

| 复现的办法 | 读数 |
|---|---|
| 把仓库 clone 到 **`/tmp/bugfix1a/repro`**(★ **不碰 Tim 机器上的 `node_modules`**),checkout 到 `dd9be64…` | ✓ |
| ★ **冷装:`npm ci`(照 `package-lock.json`,全新 `node_modules`)** | ★ `NPMCI_OWN_EXIT=0` |
| ★ **冷构建:`npm run build`** | ★★ **`REPROBUILD_OWN_EXIT=0` —— 全绿,26 条静态检查 + `next build` 全过** |

**逐条排除掉的假设(每一条都带读数):**

| 假设 | 判词 |
|---|---|
| 我的新闸 `require` 了**没有声明**的 `postcss` / `lightningcss`,冷装解析不到 | ★ **排除** —— 冷装里三个模块**全部 resolve 得到**(`postcss` · `@tailwindcss/postcss` · `lightningcss`)。<br>⚠ **但它们确实【没有声明】**,见下面那条留给下一刀的事 |
| `lightningcss` 的 **linux-x64 原生包不在锁文件里** | ★ **排除** —— 锁文件里 **12 条** `lightningcss*` 条目,**`lightningcss-linux-x64-gnu` 与 `-musl` 都在** |
| `@source "../app"` / `"../lib"` 指到一个**没有提交**的目录 | ★ **排除** —— 干净 clone 里 `app/` **901** 个在册文件、`lib/` **46** 个、`scripts/` **71** 个;`git check-ignore` 一个都不命中 |
| 两支新脚本**没有提交进去** | ★ **排除** —— 干净 clone 里两个文件都在,`scripts/lib/selfproof.mjs` 也在 |
| `package.json` 的 build 串被我改坏了(隐形字符 / 换行) | ★ **排除** —— 1056 个字符,**非 ASCII 字符 0 个**,纯 `&&` 串 |
| 大小写陷阱(macOS 不分大小写,Linux 分) | ★ **排除** —— 两支脚本只 import `./lib/selfproof.mjs`,磁盘上逐字是 `scripts/lib/selfproof.mjs` |
| 换行符是 CRLF | ★ **排除** —— 两个文件 **0 个 `\r`** |

> ### ★★ 于是我停在这里,而【停下来】本身是一条裁定
> **我能证明的是:这个提交在一次【冷装 + 冷构建】里是绿的(macOS / arm64)。
> 我不能证明的是:它在 Vercel(Linux / 他们的 Node / 他们的装法)上为什么红。**
> ☞ **在拿到那份日志之前动手改,就是这个仓库反复付账的那一件事** ——
> 「一条写进报告的修法读起来像一条裁定,而它仍然只是一个没有被量过的猜测」。
> **我不打算贡献第二次。**

#### ⬜ 拿到日志之前**不做**、但已经看出来的一件事(留给下一刀,别顺手做)

★ **`postcss` 与 `lightningcss` 在 `package.json` 里【没有声明】**,而
`scripts/check-generated-css.mjs` **直接 `require` 它们**。
今天它们靠 npm 的提升(hoisting)落在顶层,冷装实测也 resolve 得到 ——
**所以这【不是】已证实的病因**。
☞ 但**一支进构建链的脚本依赖【没有声明】的传递依赖,本身就是一处缺陷** ——
**它该被声明**。⚠ **而那要改 `package-lock.json`,是一次独立的、要自己验的改动;
在病因查清之前把它塞进来,只会让下一次失败更难归因。**

#### ☞ 要往下走,需要那份日志(一条命令)

```
npx vercel inspect dpl_5yckcANhgJMAyuoWR2hXt5VxKJEf --logs
```

★ **或者面板:** `https://vercel.com/tim-s-projects7/new-era-erp/5yckcANhgJMAyuoWR2hXt5VxKJEf`

#### ⚠ 在修好之前,`main` 是什么状态 —— 照直说

* ★ **生产没坏**(别名 HTTP 200,服务的是上一次成功的构建)。
* ⚠ **但 `main` 上现在有一个【构建失败】的提交**,而下一刀会从它开始。
* ★ **要立刻让 `main` 回到绿的**,办法是回退这两条提交:
  `git revert --no-edit dd9be64ec8cfe349de1e80421aae4bfea60d7090 fde508dab762dcbac6767aaa16a96e010af13868`
  ☞ **本刀【没有】这么做** —— 那是一次要 Tim 裁的取舍(生产没坏,而回退会把五条修好的东西一起撤掉)。

### 16.3 §7.8 残留 —— ★ **已经量完了,与推送无关的那一部分**

> **本刀跑过 9 支带【用完即删 admin】的量具**:`devcheck` ×2(两臂)· `devfetch` ×3 ·
> `e-probe` ×2(两臂)· `g-probe` ×6 · 截图 ×1 · `survey-controls` ×3(drift · 补量 · edit)·
> `smoke-routes` ×2(废掉的那一趟 + 干净的那一趟)。
> **每一支都先 `openPlan()` 落一份清理计划再动手。**

| 判据 | 读数 | 怎么查的 |
|---|---|---|
| ★ **用完即删的账号** | ★ **0** | 在册账号**共 6 个**(分母摆出来),按 **11 个模式**逐个比:`bugfix1a-` · `smoke-` · `input0-` · `input2` · `input3` · `font1-` · `font2-` · `probe` · `pgprobe-` · `style-c` · 以及**任何** `%@test.local` —— ★ **11 个模式全部命中 0** |
| ★ **幽灵授权** | ★ **0** | `user_roles` 共 **8** 行,**没有一行**指向不存在的账号(左连 `auth.users` 反查) |
| ★ **`reap-ephemeral`** | ★ **干净** | `✓ 没有滞留的清理计划(.ephemeral/ 是空的)`,`REAP_OWN_EXIT=0` |
| ★ **`.ephemeral/`** | ★ **空(0 个条目)** | `ls -A .ephemeral` |
| **live-lock** | ★ **已释放(文件不存在)** | `ls .live-lock` |
| ★ **我自己的进程** | ★ **0** | `pgrep -fl "next dev\|next-server\|chrome-headless-shell\|smoke-routes\|survey-controls\|gate.py\|wait_for.sh\|run_detached"` → 无输出 |
| ★ **我自己的端口** | ★ **0**,逐个查了 **10 个** | HTTP `3196`(普查)· `3199`(冒烟)· `3211`(dev 检查/取数)· `3212`(item e)· `3213`(item g)· `3214`(截图);CDP `9335` · `9346` · `9347` · `9348` —— **每一个 0 个 listener** |
| ★ **一次性本地 postgres** | ★ **0 —— 而且是按【命令行】查的** | `pgrep -fl postgres` → 无输出。☞ **不是按 `pg_ctl -D <猜的路径> status` 查的** —— round 1 正是在那上面查错过一次(查了 `/tmp/bugfix1/pg`,而数据目录是 `/tmp/bugfix1/pg/pg`,进程当时还活着)。**一个查错了路径的检查,和一个没做的检查,在日志里长得一模一样。** |
| ★ **孤儿 chrome** | ★ **0 —— 没有可杀的** | `pgrep -fl chrome-headless-shell` 无输出 |
| ⚠ **本刀杀过进程,而每一个都先证过是孤儿** | ★ **3 个** | 废掉那一趟冒烟留下的:`next dev` **pid 10159 · ppid=1** · `next-server` **pid 10174 · ppid=1** · 以及 10159 的子进程 10173。★ **先 `ps -o ppid=` 读出 `ppid=1` 才 `kill -9`**(见 §8.0) |
| ★ **仓库里的临时文件** | ★ **0** | 提交之后 `git status --porcelain` **一行都没有**。量具与中间产物全部在 **`/tmp/bugfix1a/`**(仓库外) |
| ★★ **线上业务数据** | ★★ **一个字节都没有改** | 全程只读。两处**会写的操作**都被 CDP 拦在浏览器里;收工再读一遍:<br>· `task_nodes` 那一行:`Dinner` · `target_date 2026-09-12` · `updated_at 2026-09-11 22:38:59.627691+08` —— ★ **与开工时逐字相同**<br>· `kpi_entries` 那 30 条:`with_evidence 0` · `with_feedback 0` · `max(updated_at) 2026-09-05` —— ★ **没有一条是今天动的** |
| ⚠ **6 条滞留的 `ZZ-SMOKE-*` 行** | ★ **不是这一刀的** | 最年轻的 **228.5 小时(≈9.5 天)**,而本刀从开工到收工不到 **1.5 小时**。★ **按年龄就不可能是它留下的**;其中 5 条**仍被真单据引用**。那道检查自己写着「只报告,不删除」—— **报出来,不顺手删**(在案条目 `SMOKE-SCRATCH-ROWS-STALE`) |
| ⚠ **构建产物 `.next/`** | **当前不存在**(跑冒烟之前删掉了) | 它是构建输出,在 `.gitignore` 里 |

---

## 17 · ★★ v1.4.18 交给测试者的那一份说明 —— **本刀这几条的草稿** ★★

> ### ⚠ **draft —— 完整的 `v1.4.18` 说明要在 BUGFIX-1b 落地之后才写。**
> 下面只是**本刀这五条**的部分,BUGFIX-1b 会往里加「医疗报销开得出费用单了」与
> 「看不懂的错误码换成了人话」两条。

---

**What changed in this part of v1.4.18**

* **The calendar can read container arrivals again.** On `/tools/calendar`, the red
  “this month is INCOMPLETE” banner is gone, and Container ETA entries show up.
  *One thing that is not a fault:* there are **no container arrivals in September** —
  the four we have are all in **August**, so switch the month to August to see them.
* **The leave record no longer prints a code at you.** On a leave request, the
  **Source** column used to read `leave.grantType_monthly_accrual`. It now reads
  **“Monthly accrual”** (and **「按月累计」** in Chinese).
* **The date picker on task steps lets go of you.** Changing the date on a step that
  already had one used to leave the calendar pop-up stuck open, because the field
  took itself away from you mid-save. It does not do that any more.
  **Please try this one by hand** — it is the one thing we could not test automatically.
* **Notes boxes stop stretching.** In the KPI scoring grid, typing into **Evidence**
  or **Feedback** used to make that column grow wider and squeeze its neighbours.
  The box now keeps its width and wraps the text instead.
* **(For us, not for you)** The development server was returning an error on every
  page. It did not affect the live site, but it blocked our own testing. It is fixed,
  and there is now a check that stops it happening again.

**★ One thing we are asking you NOT to report:** the typeface work is being done
**in steps and is not finished yet**. On this version some screens still show **two
different fonts** — that is known, it is already booked as **v1.4.19**, and that
release is the one that finishes it. **Please do not report mixed or inconsistent
fonts.** Anything else that looks wrong, please do tell us.

---

★ **Tim 点名的三件,逐条对上:**
1. 字体正在**分步**统一 → “being done in steps and is not finished yet”
2. `v1.4.19` 会做完 → “already booked as v1.4.19, and that release is the one that finishes it”
3. 字体不一致**不要报** → “Please do not report mixed or inconsistent fonts”

