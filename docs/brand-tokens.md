# 品牌 token · shadcn/ui · 样式取样页 —— BRAND-1

**2026-09-02。HEAD 见提交。没有 DDL,没有迁移,没有备份,没有窗口。**
本刀只动前端:新增 token、装 shadcn/ui、加一个临时取样页。
**已上线的 187 个页面,一个像素都没有变** —— 证明在下面 §5。

---

## 0 · 一句话

给这个前端**造地基**:一层带出处的品牌 token、九个 shadcn 组件、
以及一个让 Tim **指着挑**的临时取样页。**不转换任何页面。**

---

## 1 · ★ 不要跑 `npx shadcn init` ★

**BRAND-1 在一份用完即弃的仓库副本上真跑了一次 `shadcn@4.19.1 init`,
diff 了它写的每一个字节。它违反 R3 与 R5,一共五处 —— 全部是量出来的,不是推的。**

| # | init 写了什么 | 后果 |
|---|---|---|
| ① | `@custom-variant dark (&:is(.dark *))` + 整块 30 行 `.dark { … }` token | **把 DARK-FIX-1 特意删掉的深色模式又装了回来。**这是一条已经关掉的裁决,而一个随手跑 init 的人会把它推翻,自己都不知道 |
| ② | `--foreground` 从 `#171717` 改成 `oklch(0.145 0 0)` | 换算出来是 **`#0a0a0a`**,不是 `#171717`。**187 个页面的正文颜色全变** |
| ③ | 删掉 `body { font-family: Arial… }`,写 `html { @apply font-sans }` | **全站字体一次换掉**,而 `--font-sans` 被重指到一个悬空的 `var(--font-sans)` |
| ④ | `* { @apply border-border outline-ring/50 }` | 给**每一个元素**定默认边框色与**焦点框颜色**。18 处裸 `border` 会变;`outline-ring` 那一半碰的是**全站每一个可聚焦元素** —— 而 FE-0 明确记着「浏览器默认焦点框完好」是这个前端为数不多的可及性资产 |
| ⑤ | 把 **`shadcn` 自己**(一个 CLI)写进 `dependencies` | 连同 `radix-ui` / `lucide-react` / cva / clsx / tailwind-merge / `tw-animate-css` |

它**没有**碰 `app/layout.tsx`(实测)。
`shadcn/dist/tailwind.css` 也**无害**:629 行,全是 `@theme inline` 的 keyframes 与
`@custom-variant` 声明,**没有任何元素级选择器**。

> **所以坏的不是 init 写的那些东西,是它把 token 层**放在** `:root` / `*` / `body` 上。**
> BRAND-1 因此**手工安装**:`components.json`、`lib/utils.ts`、依赖、token 层
> 各自手写,九个组件用 `shadcn add` 装(实测它**只**建那九个文件,
> **不碰 globals.css,也不碰 package.json**)。

**下一个想跑 `init` 的人:先读这一节。**

---

## 2 · 一条对 FE-0 的更正

FE-0 说样式技术是 Tailwind v4、字体是 `next/font` 的 Geist。前半对,后半**不完整**:

```css
/* app/globals.css */
@theme inline { --font-sans: var(--font-geist-sans); }   /* 接上了 */
body { font-family: Arial, Helvetica, sans-serif; }      /* ← 但 body 自己写死了 */
```

`--font-geist-sans` 接进了 `@theme`,**却从来没走到 body 上**。
全站只有显式写了 `font-sans` 的元素才会用到 Geist。

> **所以今天屏幕上真正的字体是 Arial / Helvetica,不是 Geist。**
> Geist 每一页都在下载,而基本没被用。
> 实测佐证:`/login` 的 `<h1>` 光栅出来就是 Arial 字形(§5 的基线图)。

这一条要紧,因为**「换成 Google Sans」的对照物是 Arial,不是 Geist**。

---

## 3 · Token:【指南】与【推导】分开

全部在 `app/brand-tokens.css`,每一行都标了类别。这里只讲**为什么**。

### 3.1 指南给的五个值(逐字,不许近似)

| token | 值 | 出处 |
|---|---|---|
| `--brand-ocean` | `#008EBC` | Pantone Hawaiian Ocean |
| `--brand-forest` | `#6B8D54` | Pantone Forest Green |
| `--brand-bg` | `#F1F9FE` | BACKGROUND |
| `--brand-accent` | `#E1F5FF` | ACCENT |
| `--brand-text` | `#182B4B` | TEXT |

Tim 给的两个 SVG(`public/brand/`)已按这五个值校正过。
**BRAND-1 没有信这句话,而是量了**:光栅之后逐像素统计,
wordmark 里 `#008EBC` 6,968 px、`#6B8D54` 962 px;sphere 里 `#6B8D54` 48,123 px。
其余是抗锯齿边缘。**没有色彩管理漂移。**

### 3.1.1 ★ 球体只作为字标里的「O」出现 —— 界面里没有水印 ★

**这一条写在这里,是因为【品牌指南自己的措辞会把下一个人引回去】。**
指南里有一节讲**水印的许可用法**(Forest Green、50% 不透明度、原描边粗细)——
照着做完全合规,**BRAND-1 就是照着做的**:取样页右下角曾经有一个 26rem 的球体水印。

> **Tim 的裁定(LOGIN-1,2026-09-02):球体属于印刷品**(名片一类),
> **ERP 的界面里没有它的位置。** 不做背景、不放大、不着色、不浮在任何东西后面。
> **界面里球体只以一种方式出现:完整字标 `evoltrya-wordmark.svg` 里的那个「O」。**

`evoltrya-sphere.svg` **仍然留在仓库里** —— 给那些**连字标都放不下**的地方:
favicon、主屏图标。**那是尺寸问题,不是装饰。**

已落实:取样页那个水印已删除(原处留了一整段注释说明为什么不许加回来);
实测 `app/`、`lib/` 下引用 `evoltrya-sphere` 的地方现在是 **0 处**。
完整记述见 **`docs/login-page.md` §1**。

### 3.2 ★ 一个必须照直说的发现:指南主色扛不动白字 ★

```
白字 on #008EBC = 3.75:1        白字 on #6B8D54 = 3.77:1
WCAG AA 正文要求 = 4.5:1
```

**直接拿指南主色当按钮底、上面印白字,达不到 AA。**
这不是算错,是品牌本身的性质。

处置(R1 正好授权了这一类):**主色一个字节不动**,另推一档**专用于填充**的值 ——
OKLCH 里色相 H 与彩度 C 保持不变,**只把明度 L 往下压,压到刚好够 4.5:1**
(二分到 0.0005;压多少是解出来的,不是挑的)。

| 用途 | token | 值 | 白字对比度 |
|---|---|---|---|
| 文字 / 图标 / 描边 | `--brand-ocean`(指南) | `#008EBC` | — |
| 按钮底 | `--brand-ocean-fill`(推导) | `#007FAD` | **4.53:1 ✓** |
| 按钮底 | `--brand-forest-fill`(推导) | `#5E8047` | **4.51:1 ✓** |

### 3.3 危险色:指南没有给红色

不借一个 Tailwind 红 —— 那会是这套配色里唯一一个不属于它的颜色。
做法:取 `--brand-ocean` 的 OKLCH,**L 与 C 原样保留,只把 H 转到 27°**。
于是这个红与主色**视觉分量相等**:它是警告,不是比品牌本身还响的东西。
`--brand-destructive` `#C0635A`(文字/描边)、`--brand-destructive-fill` `#B75B53`(白字 4.53:1)。

### 3.4 中性档:由指南的 TEXT 与 BACKGROUND 插值

在 OKLab 里按比例插值,所以这几个灰**带着品牌的蓝底子**,不是 Tailwind 的中性灰。
比例写在每一行末尾,照着能复算:
`--brand-border` = mix(bg→text, 16%) · `--brand-border-strong` 28% ·
`--brand-muted` 5% · `--brand-muted-text` = mix(text→bg, 38%)(on bg = 4.53:1 ✓)。

### 3.5 禁用态达不到 AA —— 而这是对的

`--brand-disabled-text` on bg = **2.35:1**。**WCAG 1.4.3 明文把「失效的界面组件」
排除在对比度要求之外**,所以这是一次明写的判断,不是漏检。

### 3.6 ★ 一个踩到的坑:`--radius` 不许进 `@theme` ★

BRAND-1 写过一次 `--radius: var(--brand-radius);`,**当场违反 R3**:
Tailwind v4 里 `--radius` **就是裸 `rounded` 那个工具类的值**,于是
`.rounded` 从 `.25rem` 变成 `.375rem` —— 而 `rounded` 在 app/ 下用了
**1,719 次、横跨 335 个文件**。几乎每一页的圆角都会变,而那一行看起来只是"接一个 token"。

**它是怎么被抓到的,比它本身更值得记:** 第一版比对脚本用手写的花括号切分,
`@layer` 嵌套把选择器错配到别的块上,于是它吐出一串**解析假象**,
把这条**真的**改动淹没在里面。换成 **postcss 真解析器**之后,
934 条声明里精确地剩下 2 条,就是它。
**一个吵闹的检查和一个瞎掉的检查一样坏 —— 它让人学会忽略输出。**

---

## 4 · 字体:Google Sans 载入了,但**不套到 body 上**

### 4.1 R2 与 R3 冲突,R3 赢

R2 说产品字体是 Google Sans;R3 说这一刀不许改任何已上线页面的样子。
**把 Google Sans 套到 body 上就是改 187 个页面。** 两条不能同时守。

处置:**载入它、定义它、在取样页里演示它,但不切 body**。
换全站字体是一行代码的事,而它值得是**一次单独的、看得见的决定** ——
由 Tim 看过取样页之后再做,而不是当作地基刀的副作用。

### 4.2 它是真的能用(查过,不是记忆)

* `next/font/google` 导出 `Google_Sans`(与 `Google_Sans_Code` / `Google_Sans_Flex`);
* Google Fonts 真的在发:`css2?family=Google+Sans` → **HTTP 200**,可变字重 400–700;
* 构建期由 `next/font` **取回并自托管**(线上不打 Google 的服务器,没有第三方请求)。
  实测构建产物里有真的 `@font-face`,带 unicode-range 分片。

**只在取样页加载** —— 别的页面连下载都不会发生。

### 4.2.1 LOGIN-1 把它用到了一个【真页面】上 —— 以及推广的代价

`/login` 现在也用 Google Sans(与取样页同样的作用域写法)。**全站仍然是 Arial。**
构建产物层面的证据:那个 Google Sans 的 CSS 分块被 **exactly 2 个页面清单**引用
(`app/login`、`app/brand-sampler`),**其余 217 个里没有**。

★ 而这一页的文案默认是中文,所以它实际改掉的字形只有:标题里的 `EVoltrya OS`、
**人自己打进去的邮箱地址**、以及英文 locale 下的按钮字。**中文一个字都没变。**

**推广到全站换来的是英文与数字的字形,中文那一半原样不动** —— 见 4.3。
真要推广,那是**两个**决定(品牌拉丁字体 + 一个明写的中文字体),不是一个。
完整记述与字体账(latin 可变字重分片 35 KB)见 **`docs/login-page.md` §5**。

### 4.3 ★ 中文用什么字渲染 ★

**Google Sans 有 25 个 subset,没有 `chinese-simplified`。**
实测构建产物:**75 个 `Google Sans` 的 `@font-face` 块,覆盖 CJK 汉字(U+4E00–9FFF)的:0 个。**

于是 fallback 链是:

```
Google Sans → ui-sans-serif → system-ui → -apple-system
            → PingFang SC → Microsoft YaHei → Noto Sans SC → sans-serif
```

**说白话:中文会用【那台机器碰巧有的那个字体】渲染 —— Mac 上和 Windows 上长得不一样。**

**这是今天就已经如此的事,不是本刀造成的退化**:body 现在是
`Arial, Helvetica, sans-serif`,中文一样落到系统字体。

> **留一个明写的未决问题(A3 的 (b)):要不要把 Noto Sans SC 也做成 web 字体,
> 让中文在每台机器上一样?** 这是一个真的改进,但它带着约 2 MB 的页面重量、
> 一份字体授权判断、以及一轮 subset 工作。`assets/fonts/NotoSansSC-*.ttf` 确实已经在仓库里,
> 但它们是**给 PDF 渲染器**用的、由 `lib/invoiceFontCoverage.ts` 把门,
> **拿来喂 web 是另一件事**。它不属于一把 token 刀。

---

## 5 · ★ R3 的证明:三个页面不够,所以证了全部 187 个 ★

### 5.1 为什么可以做到"构造上成立"

FE-0 量过、BRAND-1 复量过:**全仓库组件里 `var(--` 出现 0 次**;
shadcn 用到的 **12 个语义名**(background/foreground/card/popover/primary/
secondary/muted/accent/destructive/border/input/ring)在 app/ 下**每一个都出现 0 次**。

> **没有人读的东西,不可能改变任何东西的外观。**
> 于是往 `:root` 新增 `--brand-*`、往 `@theme` 新增那 12 个名字,**在渲染上是惰性的**。
> 三条硬规矩由此而来(写在 `app/brand-tokens.css` 抬头):
> ①只新增 `--brand-*`;②`--background`/`--foreground` 逐字节不动;
> ③**不写任何 `*` / `body` / `html` 选择器**。

### 5.2 判据一:声明级比对(用 postcss,不是手搓)

编译产物两两对比,**上下文(每一层 at-rule)+ 选择器 + 属性** 三元组为键:

| 对比 | 既有声明 | **改值** | **消失** | 新增 |
|---|---|---|---|---|
| 只加 token | 934 | **0** | **0** | 24 |
| 加 token + 装 shadcn(修 `--radius` 前) | 934 | **2 ← 真违规,见 §3.6** | 0 | 311 |
| **最终态(token + shadcn + 取样页)** | **934** | **0** | **0** | 343 |

`--background:#fff` 与 `--foreground:#171717` 逐字节还在。
全局元素选择器数量:改前 1(既有的 `body`),改后 1 —— **没有新增。**

### 5.3 判据二:像素

WebKit 光栅化,PNG 逐字节比对。**"一致"必须先排除"两张都是空白"这种真空通过** ——
所以每张都先量了内容量(320–1,001 种颜色、非底色占比 16.6%–54.9%)。

| 探针 | 是什么 | 结果 |
|---|---|---|
| `/login` | **真的服务端渲染 HTML**(取自跑起来的生产构建)+ 真的编译 CSS | **逐字节相同** |
| `/finance/invoices` | 该页 9 个文件里**逐字符照抄**的 149 个 className | **逐字节相同** |
| `/purchasing/orders` | 同上,14 个文件 215 个 className | **逐字节相同** |
| **全 app** | **463 个既有文件、1,842 个不重复 className** | **逐字节相同** |

最后一行是要点:**它覆盖的不是三个页面,是全部 187 个页面用到的每一个 class 串。**

`/login` 的服务端 HTML 本身也逐字节相同(剔掉每次构建必变的资源哈希与 buildId)。

> **一处诚实的边界:另外两个页面用的是【照抄 className 的探针】,不是抓下来的整页 HTML。**
> 抓它们要一个真会话,而那会把**真实的客户与员工数据**渲染进 /tmp 里的截图
> (见 `docs/pdpa.md`)。为一次样式比对付这个代价不值得,而 §5.2 的声明级判据
> 本来就比任何三页抽样更强 —— 它覆盖全部。

### 5.4 R5:没有深色模式,而且**这一行是拆它的,不是加它的**

`app/brand-tokens.css` 里有一行 `@custom-variant dark (&:is(.dark *));`。
**它看起来像 init 写的那一行,作用却相反,删掉会出事:**

vendored 进来的九个组件带着 **19 条 `dark:` 工具类**。
而 **Tailwind v4 的 `dark:` 默认是媒体查询** —— 实测(在 probe2 里编译、grep 产物):
不写那一行时,编译出来的是 `@media (prefers-color-scheme:dark){ … }`。
也就是说**任何一台系统开着深色模式的机器**上,这些组件会自己变半套深色 ——
正是 DARK-FIX-1 花力气删掉的那个「半个主题比没有更坏」。**Tim 在手机上用这个系统。**

那一行把 `dark:` 改绑到一个 class 上,而全仓库 `.dark` 出现 **0 次**、
也没有任何东西会加它。实测结果:

| | `prefers-color-scheme` | 受 `.dark` 祖先约束的规则 |
|---|---|---|
| 不写那一行 | **1**(会真的生效) | 0 |
| 写了那一行 | **0** | 19(**死代码**) |

**它没有定义任何深色 token 值**,所以 R5 的两条都守住了。

---

## 6 · 装了哪九个,以及为什么**不装**别的

判据是**这个系统实际上是什么**:161 个文件里有表、97 张表单、
**总共只有 6 个徽章**、**整仓库只有 1 个模态**。

| 组件 | 为什么 |
|---|---|
| `button` | 68 个签名 → 真正承载意义的只有 5 族 |
| `input` / `label` / `select` / `textarea` | 28 / 18 / 13 / 5 个签名;而且 44 个局部 class 常量里有 34 个就是 field / label / card 这三个概念 |
| `table` | 1,215 个 `<td>`、990 个 `<th>`,**没有任何库、没有任何共享组件** |
| `card` | 收敛那个被抄了 4 次的 `card` 常量 |
| `badge` | **净新增。** 这个系统把状态当纯文字印;FE-0 明确说 Badge 在这里是新增,不是收敛。**留着它,因为取样页正是要让 Tim 判断拒绝态怎么画** |
| `alert` | 横幅的颜色语义**已经是一致的**(琥珀=警示、红=错误、蓝=说明、绿=成功) —— 缺的不是配色,是一个组件 |

### 不装的,以及理由(**这两条原样留着,因为将来一定会被重新提出来**)

* **`form` —— 它会把 react-hook-form 与 zod 拉进来,对上的是 97 张【原生】表单 + server action。
  那是一次架构赌注,需要它自己的一刀,不能顺手装。**
* **`data-table` 不是一个组件 —— 排序与列显隐是【缺失的功能】,不是样式。
  把它们打扮成一次组件选择,会把这个事实盖住。**
  (FE-0 实测:`sortBy` / `sortKey` / `toggleSort` 全仓库 **0** 次命中,
  `visibleColumns` / `columnVisibility` 同样 **0**。)
* `dialog` —— 全仓库**只有一个**模态。这是一个**内联面板式**系统,不是弹窗式的。
* `toast` —— 没有任何 toast 基础设施(无库、无 portal)。加一个是 UX 决定,不是样式决定。
* `dropdown-menu` / `popover` / `tooltip` / `sheet` / `sidebar` —— 今天没有对应用法可收敛。

### `tw-animate-css` 也没装 —— 一次明写的取舍

`select` 用到 `animate-in` / `animate-out`,它们来自 `tw-animate-css`。
**不装**的理由:装它意味着往 `globals.css` 再加一个**全局 CSS import**,
而本刀的全部安全性来自"不往全局加东西"。代价是**下拉浮层没有入场动画** ——
纯装饰,功能不受影响。将来要补是一行、且是孤立的。

### 装进来的文件,逐个

| 文件 | 谁写的 |
|---|---|
| `app/components/ui/{button,input,label,select,textarea,table,card,badge,alert}.tsx` | `shadcn add` 原样生成,**未改动** |
| `lib/utils.ts` | 手写(`cn()` = clsx + tailwind-merge) |
| `components.json` | 手写(aliases 指向 `@/app/components/ui`) |
| `app/brand-tokens.css` | 手写 —— token + `@custom-variant dark` + `@theme` 接线 |
| `app/globals.css` | **只加了 4 行**(一句注释 + 一条 `@import`),其余逐字节未动 |
| `package.json` | 新增 5 个运行时依赖:`clsx` `tailwind-merge` `class-variance-authority` `lucide-react` `radix-ui`。**没有把 `shadcn`(CLI)写进去**,init 会那么干 |

---

## 7 · 取样页 —— 它是干什么的,以及什么时候删掉它

**`/brand-sampler`。临时。用完即删。**

**为什么存在:样子没法用散文选。** 三个成体系的变体渲染**同一份内容**,
Tim 指一个就行 —— 不是"每个排列组合摆一遍"的组件动物园,他要能**指**,不是**拼**。

| | 密度 | 按钮 | 表格 | 卡片 | **拒绝态** |
|---|---|---|---|---|---|
| **A · Ledger** | 紧凑 | 实心 | 全边框 | 无投影 | 灰斜体 |
| **B · Workbench** | 宽松 | 描边 | 斑马纹 | 轻投影 | 描边小标签 |
| **C · Brand-forward** | 宽松 | 品牌实心 | 素表 + Hawaiian Ocean 表头线 | 明显投影 | 浅色填充片 |

**内容是真的形状,不是 lorem ipsum**:批次号 `IN-YYYY-NNNN`、物料号 `MAT-YYYY-NNNN`、
阶段三值(待加工/加工中/已加工完)、计价三值(unpriced/provisional/final)、
化学体系字典(NMC/NCA/LFP/LCO)—— 每一个都取自 `db/tables/` 的真源。
**数字与供应商是编的,取样页不连库**(一个选样式的页面不需要、也不应该把真实客户与员工渲染出来)。

**拒绝态是这一页的重点。** 四种,含义各不相同,**而它们今天被印成十种样子**:

| | 键 | 它说的是 |
|---|---|---|
| 受限 · Restricted | `common.restricted`(全站 42 处共用) | 你没有权限看这个值 ≠ 这个值是空的 |
| 未记录 · not recorded | `actor.unrecorded`(ActorName.tsx 独占) | 当时没有人记下是谁做的 ≠ 这个人不存在 |
| 未说明 · Unexplained | 早于来源规则,既无订单行也无理由 | **刻意不回填:猜一个会伪造历史** |
| 无库存 · out of stock | 余量为 0 | **这是一个事实,不是一次拒绝** —— 把它和上面三个画成一样,就是在说系统不知道,而它知道 |

### 它怎么被挡在系统外面

* **不在导航里** —— `lib/modules.ts` 一个字没动;
* **不在冒烟的路由清单里** —— `scripts/smoke-routes.mjs` 的 `walk()` 里一条**具名排除**。
  **刻意不用 `EXPECTED_SKIPS`**:那一栏的含义是「这张表今天没有数据」,而且它的漂移断言
  会在有数据的那天响、逼人删掉它。**用在这里是一句假话** ——
  把一件「故意不测」的事记成一件「暂时没数据」的事,下一个读清单的人会得到错的印象;
* **仍然在登录后面**(`PUBLIC_PATHS` 没动),所以它不是公网可达的;
* 页面顶上一条红色虚线横幅明说它是临时的、该怎么删。

> ### 删除清单(Tim 挑完之后)
> 1. `rm -rf app/brand-sampler/`
> 2. 删掉 `scripts/smoke-routes.mjs` 里的 `SMOKE_EXCLUDED_DIRS` 那几行
> 3. **token、九个组件、`lib/utils.ts`、`components.json` 全部留下** —— 它们是地基,不是取样页的一部分

**为什么它和系统里别的页字体不一样:** 它用 Google Sans,**全站仍然是 Arial**(§4.1)。
这一点也印在页面上,免得看起来像 bug。

---

## 8 · 这一刀之后的未决问题

1. **换不换全站字体** —— 等 Tim 看过取样页。一行代码,但要是一个明写的决定。
2. **中文要不要自带 web 字体**(§4.3)—— 约 2 MB + 授权 + subset,不属于 token 刀。
3. **主色扛不动白字**(§3.2)已经用推导填充档解决了。但**指南本身**有这个性质,
   将来做别的物料(PPT、名片)的人会再撞一次 —— 记在这里,免得他从头再算一遍。
4. **`data-table`** —— 排序与列显隐今天**一个都没有**。那是功能,不是样式,需要它自己的一刀。
