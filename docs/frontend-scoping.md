# 前端勘察 —— FE-0

**READ ONLY,2026-09-01。HEAD `22c22f0`(RECV-SOURCE-1),HEAD == origin/main,
工作树干净。** 本文件只报告【现在是什么样】与【统一要花多少】,不改任何组件、
不装任何依赖、不提议 token 值。所有数字都是当天在仓库里数出来的,不是估的;
数不准的地方给区间并说明为什么不准。

除本文件外没有任何写入。

---

## PART A · 对 brief 本身的意见(先于测量)

grilling 先跑了一轮 EXISTENCE FIRST。三条前提查完之后【不成立】,照直写在最前面 ——
其中两条会改变 Phase 8 的大小。

### A1 「导航是按模块加进来的顺序一条条堆起来的」——**不成立**

`lib/modules.ts`(196 行)是**一份有序、已分组的注册表**,字段
`section: 'masterData' | 'operations' | 'reports' | null`,顶栏与首页卡片
**共用同一份**。`app/components/NavLinks.tsx` 抬头(OPS-15)写着两份清单
是被【故意合并成一份】的,理由是"两份清单必然漂,而漂了的后果是
【有人看见一个他进不去的入口】"。

**表达一套分类法的机制已经存在**,新架构落进一个注册表即可,不必先造一个。
这是好消息,记在这里。

但 brief 对 ② 的**描述**已由 Tim 更正:NAV-1 不是"重排条目",而是
**把每一页重新分层成一套站得住的信息架构** —— 什么是一级概念、什么是二级、
哪些页合并、哪些页拆开。改注册表分类法是那件事的**最后一步**,不是那件事。
所以撤回的是**我原本对 ② 的收窄**,不是 ② 本身。见 PART F。

### A2 「item ③ 可能与 item ① 纠缠」——**不成立,而且是本轮最有用的排期事实**

PDF 路径是**另一个渲染器**:`@react-pdf/renderer`,自带 `StyleSheet.create`,
没有 DOM、没有 Tailwind、没有 className。19 个文件:

```
app/finance/invoices/[id]/pdf/InvoiceDocument.tsx      app/sales/orders/[id]/pdf/SalesOrderDocument.tsx
app/finance/credit-notes/[id]/pdf/CreditNoteDocument.tsx  app/sales/quotes/[id]/pdf/QuotationDocument.tsx
app/finance/statements/[id]/pdf/StatementDocument.tsx  app/sales/shipments/[id]/pdf/DeliveryNoteDocument.tsx
app/purchasing/orders/[id]/pdf/PurchaseOrderDocument.tsx  app/inventory/reports/ReportDocument.tsx
app/components/CompanyLetterhead.tsx                   app/inventory/reports/pdfShared.tsx
+ 9 个 route.ts(数据取数与字体覆盖检查)
```

**逐个查过 import:没有任何一个 PDF 文档引入过一个 web 组件。**
`CompanyLetterhead.tsx` 虽然放在 `app/components/` 下,它自己就是 react-pdf 的,
只被 PDF 文档引用(4 处)。共享的只有 `INVOICE_FONT_FAMILY` 这一个常量与
`lib/invoiceFontCoverage.ts` 的字体覆盖检查 —— 两者都与视觉样式无关。

**结论:重新设计 web 的样式,一个字都碰不到 PDF。item ③ 可以与 ① 完全并行,
由碰不到同一批文件的人做。**

### A3 「231 routes」——**这个数这个仓库已经更正过一次了**

`docs/efficiency-group-scoping.md:50` 白纸黑字:
「231 routes exist」→ **216**(`app/**/page.tsx` **187** + `route.ts(x)` **29**)。
今天重数一遍,仍然是 187 + 29 = 216。brief 把一个已被撤回的数字又带了回来。

### A4 「logistics 借用 purchasing 的权限码挂在那里」——**成立,而且是写下来的**

`lib/modules.ts:136-139`:`permission: 'module.purchasing.view'`,
上一行注释「【将来那个码是 module.logistics.view】—— LOG-0 的勘察把物流定在商务线」,
`lib/modules.ts:194-195` 又写「将来铸出 module.logistics.view 时只改 MODULES 那一行」。
这是一个**有意的、单点可换的**权宜,不是遗留脏东西。

### A5 「统计 distinct implementations」是否是一个良定义的问题

不完全是,所以按 grilling 商定的口径两种都数:

* **(b) 归一化签名 —— 主数字。** 去掉不承载视觉身份的工具类
  (`w-/h-/m-/flex/grid/gap/absolute/...`),保留承载身份的
  (`bg-/text-/border/rounded/font-/px-/py-/shadow/hover:/disabled:`),
  去重后**排序**再拼成签名。两处归一化到同一个签名 = 同一个实现。
* **(c) 意图判读 —— 解释。** 对活下来的每一族判一次:差别是否**承载意义**
  (危险按钮本来就该与中性按钮不同),还是**漂移**(两个一模一样的保存按钮,
  一个 `rounded` 一个 `rounded-md`)。

> **【必须写在这里,否则后来的人会把 N 读成工作量】**
> **统一的代价跟的是 N−M(漂移),不是 N(签名总数)。** 一个模块里
> `<td>` 有 112 个签名,但其中承载意义的只有寥寥几种(左对齐/右对齐/等宽数字),
> 剩下的是 `px-3` 与 `px-4` 的差别。把 N 当成工作量会把这件事高估一个量级。

---

## PART B · Q1–Q4:测量

### Q1 它是用什么写的?

| 项 | 测得 |
|---|---|
| 样式技术 | **Tailwind v4**(`tailwindcss: ^4`,`@tailwindcss/postcss`),`app/globals.css` 一行 `@import "tailwindcss"` |
| CSS Modules | **0 个** |
| CSS-in-JS(styled-jsx / emotion / styled-components) | **0 个** |
| 内联 `style={{}}`(web,排除 PDF) | **2 处,2 个文件** |
| Tailwind 任意值 `[12px]` / `[#abc]` | **55 处** |
| **设计 token 层** | **不存在** |
| shadcn/ui | **完全不存在**:无 `components.json`、无 `cn()`、无 `clsx`、无 `tailwind-merge`、无 `class-variance-authority`、无 Radix |
| 样式指南文档 | **不存在**。61 篇 docs 里没有一篇讲 UI;`AGENTS.md` 2513 行全是领域规矩,**零条 UI 约定** |

**`app/globals.css` 是 `create-next-app` 的默认文件,一个字没改过** ——
只定义了 `--background` / `--foreground` 两个变量,而这两个变量
**只被 `body` 用**(全仓库组件里 `var(--` 出现 **0 次**)。

**声明了但 UI 相关的依赖,实际被 import 的:**

| 依赖 | 引用它的文件数 |
|---|---|
| `@react-pdf/renderer` | 19 |
| `papaparse` | 2 |
| `qrcode` | 2 |
| `@dnd-kit/core` | 1 |
| `@dnd-kit/sortable` | **0 —— 装了没用** |

**没有任何 UI 组件库是依赖。** 没有 MUI、antd、Chakra、Radix、Headless UI、
TanStack Table、Recharts。

> **【这一条比本勘察里任何别的发现都更能改变 Phase 8 的大小】**
> **没有地基需要拆。** `globals.css` 是未改动的 create-next-app 默认文件,
> 而 Tailwind v4 + React 19.2.4 + Next 16.2.6 **正好是 shadcn/ui 支持的目标**。
> `shadcn init` 做的事是**往下垫一层**(写 `components.json`、`cn()`、
> 把 token 写进 `@theme`),不是**替换**什么。这是纯增量。

### Q2 它有多大?

| 项 | 数 |
|---|---|
| **route(地址模式)** | **216** = `page.tsx` 187 + `route.ts(x)` 29 |
| **page(页面文件)** | **187** 个 `page.tsx` |
| 其中静态段 / 含动态段 `[id]` | 129 / **58** |
| **地址骨架**(把 `/new`、`/edit`、`/[id]` 折掉之后) | **110** |
| layout | **1 个,只有根布局** |
| `error.tsx` / `not-found.tsx` / `loading.tsx` | **0 / 0 / 0** |
| app 下 `.tsx`(排除 PDF) | **454** |
| 其中 `'use client'` / 服务端组件 | **237 / 217** |
| `<form>` 标签 / 含 `<form>` 的文件 | **97 / 87** |
| `*Form.tsx` / `*Panel.tsx` / `*Editor.tsx` 组件 | **113** |
| **app/ 总行数** | **93,704** |
| **lib/ 总行数** | **27,538** |
| i18n 文案(`messages/en.ts` + `zh.ts`) | **13,775 行** |

**route ≠ page,差在哪:** 216 个 route 里 29 个是 `route.ts(x)`(PDF 与导出端点,
**没有界面**)。剩下 187 个 `page.tsx` 里 58 个含动态段 —— 一个
`app/finance/invoices/[id]/page.tsx` 是**一个页面文件**,却是**成千上万个地址**。
所以三个数是三件事:**地址模式 216 / 页面文件 187 / 要设计的界面 187**。
再往下,`/new`、`/edit`、`/[id]` 常常是**同一件事的三个地址**;折掉之后剩
**110 个骨架**。真正的「功能数」比 110 还低 —— 但那是信息架构勘察的活,见 PART F。

**`layout.tsx` 只有一个(根),`error.tsx` / `not-found.tsx` / `loading.tsx` 一个都没有。**
这有两层意思:(一)Next 的分段布局机制**一次都没被用过**,新架构要挂子布局是
从零开始而不是改造;(二)**每一个加载态与错误态都是页面里手写的**。

### Q3 同一件事有几种做法?

口径见 A5。**「签名」= 归一化后排序去重的工具类串。**

| 种类 | 出现次数 | 带 className 的 | **归一化签名 N** | 只用过一次的签名 | 涉及文件 |
|---|---|---|---|---|---|
| **按钮** `<button>` | 384 | 198 | **68** | **40** | 198 |
| **输入** `<input>` | 599 | 271 | **28** | 11 | 169 |
| **下拉** `<select>` | 244 | 107 | **13** | 7 | 109 |
| **多行文本** `<textarea>` | 48 | 36 | **5** | 3 | 38 |
| **标签** `<label>` | 715 | 706 | **18** | 6 | 151 |
| **表格** `<table>` | 201 | 201 | **9** | 1 | 161 |
| `<thead>` | 186 | 148 | **3** | 0 | — |
| `<th>` | 990 | 990 | **24** | 5 | 152 |
| `<td>` | 1,215 | 1,212 | **112** | — | 161 |
| `<tr>` | 462 | 108 | **46** | 32 | 161 |
| `<form>` | 97 | 86 | **5** | 3 | 87 |
| **页头** `<h1>` | 237 | 237 | **17** | — | 191 |
| **空状态**(`.length === 0` 分支) | 252 | — | **20+ 长尾** | — | 174 |
| **徽章 / 状态片** `rounded-full` | **6** | 6 | **4** | — | **5** |
| **模态 / 浮层** | **1** | — | **1** | — | **1** |

**按种类的判读(N 对 M):**

* **按钮 —— N=68,承载意义的 M≈5,漂移 N−M≈63。** 真正有意义的只有五族:
  主行动(蓝底白字)、次行动(灰边)、危险(红)、危险-文字型(红下划线)、
  链接型。最大的一族 `bg-blue-600 … px-4 py-2 rounded text-white` 用了 **55 次**,
  说明**主按钮其实已经很一致**;问题在 **40 个只用过一次的签名**上。
* **输入 —— N=28,M≈3(常规 / 紧凑 / 右对齐数字),漂移≈25。** 最大一族
  `border border-gray-300 px-3 py-2 rounded` 用了 **131 次**。
* **标签 —— N=18,M≈2(主标签 / 辅助说明),漂移≈16。** 最大一族
  `font-medium text-sm` 用了 **354 次**。
* **页头 —— N=17,归一化掉外边距之后只剩 3 个**
  (`text-2xl font-bold` 110+47+26+16+14=213 次、`text-2xl font-semibold` 5 次、
  `text-2xl font-bold font-mono` 4 次)。**M≈2,漂移≈15,且全是纯机械。**
* **`<td>` —— N=112 是本表最大的数,但它最具误导性。** 差别几乎全在
  `px-2/px-3/px-4` 与 `py-1/py-2` 之间。承载意义的只有三件事:
  左对齐(文字)、右对齐 + `font-mono`(数字)、`text-sm/text-xs`(密度)。**M≈3。**
* **徽章 —— N=4,但总共只有 6 处、5 个文件。** 这个系统**基本没有状态片**;
  状态是当纯文字印的。shadcn 的 `Badge` 在这里是**净新增**,不是收敛。
* **模态 —— 全仓库只有一个**(`app/tasks/TaskModal.tsx:94`,手搓
  `fixed inset-0 … bg-black/40`)。`role="dialog"` **0 处**,`<dialog>` **0 处**。
  这个系统是**内联面板式**的,不是弹窗式的。

**加载态 —— 两套机制并存:**

| 机制 | 文件数 |
|---|---|
| `useTransition` / `isPending` | **124** |
| 自己 `useState` 的 `pending/saving/busy/loading/submitting` | **64** |
| `useFormStatus` | **0** |
| `<Suspense>` | 19 处 |
| `loading.tsx` | **0** |

**横幅 / 提示条 —— 有一套颜色语义,没有一个组件:**
`bg-amber-50`/`bg-yellow-50` **147** 处、`bg-red-50` **90** 处、
`bg-blue-50` **32** 处、`bg-green-50` **26** 处。**没有 toast**(无库、无 portal)。
颜色的用法**是一致的**(琥珀=警示/未决,红=错误/拒绝,蓝=说明,绿=成功),
**这套语义值得原样保留** —— 缺的只是把它收进一个组件。

**每个文件自己发明的迷你设计系统 —— 这是本勘察最锋利的一条:**

**44 个局部 class 常量,散在 36 个文件里,用了 14 个不同的名字,
归一化后只有 12 个签名。**

```
名字:field ×14, inp ×7, card ×4, label ×3, dd ×3, sel ×3, labelCls ×2,
      cell ×2, inputCls ×1, errCls ×1, btn ×1, cls ×1, item ×1, fieldCls ×1
```

| 归一化签名 | 用了几次 | 被叫成 | 例 |
|---|---|---|---|
| `border border-gray-300 px-2 py-1 rounded text-sm` | **17** | `field` / `inp` / `sel` | `app/commissions/CommissionForm.tsx:89`、`app/settings/permissions/roles/RoleForm.tsx:69`、`app/tasks/[id]/TaskHeader.tsx:69` |
| `font-medium text-sm` | **8** | `label` / `labelCls` / `dd` | `app/commissions/CommissionForm.tsx:88`、`app/tasks/TaskModal.tsx:34` |
| `border border-gray-300 px-3 py-2 rounded` | **5** | `inputCls` / `field` / `fieldCls` | `app/tasks/TaskModal.tsx:33`、`app/hr/employees/EmployeeForm.tsx:112` |
| `border border-gray-200 p-4 rounded` | **4** | `card` | `app/me/page.tsx:181`、`app/hr/leave/[id]/page.tsx:63` |
| `border border-gray-300 px-1 py-0.5 rounded text-xs` | **3** | `inp` | `app/hr/reviews/GoalsEditor.tsx:23`、`app/hr/reviews/scale/ScaleEditor.tsx:22` |
| 其余 7 个签名 | 各 1 | `cell` / `btn` / `errCls` / `item` / `cls` | — |

**三个概念(field / label / card)占了 44 个常量里的 34 个。**
这不是「设计过的变体」,这是**二十把刀各自把同一个想法重写了一遍,还各起了名字**。
`app/settings/permissions/roles/RoleForm.tsx:69` 与
`app/commissions/CommissionForm.tsx:89` 的字符串**逐字符相同,只是工具类顺序不同**。

**这 36 个文件是 shadcn 迁移里最便宜、收益最高的一批** —— 每个文件删两三行常量、
改一个 import。

### Q4 表格是怎么搭的?

**手写标记。没有库,没有共享组件。**

| 项 | 测得 |
|---|---|
| `<table>` 标签 / 涉及文件 | **201 / 161** |
| 表格库(TanStack / ag-grid / MUI / antd) | **0** |
| 共享表格组件 | **0** |
| **客户端排序** | **0** —— `sortBy` / `sortKey` / `sortDir` / `toggleSort` 全仓库 **0 次命中** |
| 服务端排序 `.order()` | 397 处 —— **顺序是写死的,用户改不了** |
| **列显隐** | **0** —— `visibleColumns` / `columnVisibility` / `toggleColumn` **0 次命中** |
| 分页 `.range()` | 28 处 |
| `.limit()` | 38 个文件 |
| 筛选:服务端 `searchParams` | 70 个文件 |
| 筛选:客户端 `useState` + `.filter()` | 44 个文件 |
| 空状态 | 每张表**各写各的**(见 Q3) |
| 表格横向滚动 `overflow-x-auto` | **161 个含表文件里只有 27 个有** |

**逐条答 brief 的四问:**

* **排序:一个都没有。** 用户在任何一张表上都**不能点表头重排**。这不是样式问题,
  是**功能缺口**。
  > ### ★ 更正(BASE-1,2026-09-02):**这一条的数没错,结论错了** ★
  > 上面那句「`sortBy` / `sortKey` / `sortDir` / `toggleSort` 全仓库 0 次命中」
  > **是对的**。但由它推出「用户不能点表头重排」**这一步不成立** ——
  > 真正的实现叫 **`sortableTh`**,走 URL 参数(`?sort=&dir=`)+ 数据库 `ORDER BY`,
  > 上面 grep 的那四个名字**一个都不是它**。
  >
  > 逐页实测:**8 页的用户可以点表头重排** ——
  > `/inbound` · `/materials` · `/output` · `/customers` · `/suppliers` ·
  > `/processing` · `/metal-prices` · `/finance/fx`。
  > **分页同理:17 页有用户可用的翻页**(不是「局部有」那么少)。
  > **列显隐确实是 0 ——这一条 FE-0 说对了。**
  >
  > **教训不是"grep 少写了一个名字",是【按标识符名字找机制,找到的是命名习惯,不是机制】。**
  > 这是本仓库连着第三次「以为不存在、其实已经在了」。
  >
  > **它改了 BASE-1 的形状:** 那 8 页的排序是在**数据库里对全体**排的,
  > 而一个客户端表格组件只能对**取回来的这一页**排 ——
  > 换过去**是一次降级**。所以 `<DataTable>` 有两种排序模式,
  > 服务端那一档就是为这 8 页 / 17 页留的。见 `docs/base-components.md` §1。
* **筛选:两套范式并存**,70 个文件走 URL(服务端过滤,可分享、可刷新),
  44 个文件走本地 state(不可分享)。没有一条规矩说什么时候用哪一种。
* **分页:局部有,大部分没有。** 28 处 `.range()`;更多的地方是
  `.limit()` 截断(38 个文件)—— 也就是**截断而不告诉人被截断了**,
  或者干脆整表全出。
* **列显隐:一个都没有。**(BASE-1 复核:**这一条成立** —— 实测仍然是 0 页。)
* **空状态:252 个分支散在 174 个文件里**,签名 20+ 条长尾。两大族:
  表外的说明文字(`text-sm text-gray-500`,40 次)与
  表内居中的整行空格(`border border-gray-300 px-4 py-8 text-center text-gray-500`,23 次)。

> **这是整个 Phase 8 里最大的一块。** 系统「大部分是表格」这句话在数字上成立:
> **161 个文件、1,215 个 `<td>`、990 个 `<th>`**。而且因为一张共享表格组件
> 会同时补上排序与列显隐这两个**今天完全没有的能力**,这一项的收益也最大。

---

## PART C · a–e:Phase 8 会撞上的东西

### a. 拒绝的词汇表

**结论:词汇是共享的,呈现不是。**

`common.restricted`(「受限」)在 **42 处**被引用,是**同一个 i18n 键**,
从没有第二个说法。`lib/permissions.ts:9` 的抬头把这条规矩写死了:
「无权限 + null → t('common.restricted')「受限」」。这套东西是对的,别动。

**但它被印成了 10 种不同的样子:**

| className | 次数 |
|---|---|
| `text-sm text-gray-600` | 3 |
| `text-sm text-gray-500` | 3 |
| `text-gray-500` | 3 |
| `font-sans text-gray-500` | 2 |
| `text-gray-500 font-sans` | **1 —— 与上一行逐字相同,只是顺序不同** |
| `text-gray-600` / `text-gray-400` / `text-gray-400 italic` / `italic` / `text-3xl font-bold text-gray-300` | 各 1 |
| **同一行没有 className(继承父级)** | **13** |

`text-gray-500 font-sans` 与 `font-sans text-gray-500` 并存,是本仓库
**「两把刀各写一遍」**最干净的一个标本。

**ActorName.tsx —— 是**真的只有一处,**没有被复制。** 已逐键核对:

| 状态 | i18n 键 | 除 ActorName.tsx 外还有谁引用 |
|---|---|---|
| ③ 没记过是谁 | `actor.unrecorded` | **无**(仅 `auditTrailTypes.ts` 里一个同名类型 token) |
| ② 账号没关联档案 | `actor.noEmployeeRecord` | **无** |
| ② 档案已不在(employee 空间) | `actor.employeeGone` | **无** |
| ④ 你看不到人事 | `common.restricted` | 共用全站那一个键(对的) |

文件抬头自己写着「**没有第二个取名器**」,而测量证实了这句话。
它其实是**四个状态、五种渲染结果**(② 按 `space` 参数分成两句)。

**其余几种拒绝的分布 —— 各有各的归口,没有混:**
未记录(`actor.unrecorded`,ActorName 独占)、
受限(`common.restricted`,42 处共用一个键)、
字段级遮蔽(`MaskedValue.tsx`,9 个引用方)、
不允许的操作(各模块 `*ErrorCodes.ts`,**11 个文件**把服务端错误码译成人话,
其中 `PERMISSION_DENIED` 一律译成 `common.restricted` —— 这也是一致的)。

> **判断:拒绝词汇表是这个前端最有价值的资产,而且它没有开始漂。**
> 漂的是**它的字体颜色**。这正好是 Phase 8 该修的那一半,也正好是
> **最不该在迁移里丢掉的那一半**。

### b. i18n

| 项 | 测得 |
|---|---|
| 两份文案 | `messages/en.ts` **6,907 行 / 504 KB**,`messages/zh.ts` **6,868 行 / 479 KB** |
| 字符串叶子(近似) | en **≈5,772**,zh **≈5,799** |
| 构建门禁 | `scripts/check-i18n.mjs`,**在 `npm run build` 里**,今天跑**绿** |
| 门禁强度 | 静态键、**可枚举的动态键**、占位符未传 —— 都 FAIL;后缀集合每次从 `db/tables/*.sql`、`*ErrorCodes.ts` 等**真源现读** |

**有没有不走文案的用户可见字符串?**

* JSX 里的英文字面量:**全仓库 1 处** —— `app/page.tsx:398` 的 `EVoltrya OS`。
  那是**品牌名**,不翻译是对的。
* JSX 里的中文字面量:**0 处**。
* `<input>` 的 `placeholder`:全部走 `t()`(抽查 login 与主要表单,均走)。

> **i18n 这一项基本不需要 Phase 8 做任何事。** 这是「比预期需要改的更少」
> 在本勘察里最强的一条证据。**唯一的注意事项:重排样式时不要把
> `t('...')` 调用挪进 `className` 之外的意外位置,门禁不检查这个。**

### c. PDF 路径

见 A2。补充三条 Phase 8 需要知道的:

1. **渲染器**:`@react-pdf/renderer` v4.5.1,19 个文件。样式是
   `StyleSheet.create({...})` 的 JS 对象,**与 Tailwind 无关**。
2. **与 web 组件的共享面**:只有 `INVOICE_FONT_FAMILY` 一个常量
   (被 6 个文档文件从 `InvoiceDocument.tsx` 引入)与 `CompanyLetterhead.tsx`
   一个 react-pdf 组件(4 个引用方)。**没有一个 web 组件跨界。**
3. **有一道字体门禁**:`lib/invoiceFontCoverage.ts` 的
   `findUnrenderableText` / `checkInvoicePdfCoverage` 在**每个** PDF route 里跑,
   拦「字体渲染不出这个字」。**item ③ 换排版时这道检查必须继续跑** ——
   换字体是 item ③ 最可能踩的雷,而这道门禁正好是踩到时会响的那个铃。

> **item ③ 的独立性是本勘察最有用的排期事实:它可以从第一天就开工,
> 与信息架构、与 ①、与 ② 都不冲突,因为它碰的 19 个文件谁也不碰。**

### d. 可及性与输入基本功

**先说好消息 —— 键盘可用性其实是好的,而且是「因为用了朴素 HTML」而好的:**

| 项 | 测得 | 判读 |
|---|---|---|
| `outline-none` / `focus:outline-none` | **0** | **浏览器默认焦点框完好** —— 键盘走查看得见自己在哪 |
| `<div onClick>`(假按钮) | **0** | 所有可点的东西都是真 `<button>` 或 `<a>` —— **Tab 到得了,Enter 按得动** |
| `tabIndex` | **0** | 没有人手工干预过 Tab 顺序,DOM 顺序即阅读顺序 |
| `onKeyDown` | **0** | 没有自造键盘处理 —— 也意味着 TaskModal **Esc 关不掉** |

**表单**:97 个 `<form>` 全部是原生表单 + server action,`type="submit"`。
**Enter 提交是天然可用的。**

**坏消息 —— 标签关联:**

| 关联方式 | 数 |
|---|---|
| `<label>` 块总数 | **713** |
| 包着控件(隐式关联) | **207** |
| 有 `htmlFor`(显式关联) | **32** |
| **两种都不是 —— 无关联** | **474(66%)** |

474 个标签**点了不会聚焦到输入框**,读屏软件也念不出它属于谁。
`aria-label` 7 处、`aria-describedby` **0** 处、`aria-invalid` **2** 处。
`role="alert"` **0** 处、`aria-live` **1** 处 —— 意味着
**42 处「受限」和 90 处红色错误条,读屏软件一句都不会主动播报**。

**`/login` 能不能被密码管理器填?**

`app/login/page.tsx:72-92`:

```tsx
<label className="block text-sm font-medium mb-1">{t('login.email')}</label>
<input type="email" name="email" required placeholder={...} className="..." />
...
<label className="block text-sm font-medium mb-1">{t('login.password')}</label>
<input type="password" name="password" required placeholder={...} className="..." />
```

* **没有 `id`,没有 `htmlFor`,标签也没包住 input** → 无关联。
* **没有 `autoComplete`**(全仓库 `autoComplete` 只有 **2** 处,都不在 login)。

**照直说:多半能填,但没有一处是【声明】它能填的。**
Chrome / Safari 的内建密码管理器靠 `type="password"` + `type="email"` +
表单会 POST 这几条启发式,通常认得出来;但 1Password / Bitwarden 这类扩展
在缺 `autocomplete="username"` / `autocomplete="current-password"` 时
**保存与填充都会变得看运气**,尤其是「更新已存密码」那一步。
**这是两行属性的修复**,`/login` 反正要重做,顺手补上。

### e. 手机

**结论:基本上没有做过响应式,而且有一个会在手机上真出问题的 bug。**

| 项 | 测得 |
|---|---|
| 用到任何断点的文件 | **50 / 454(11%)** |
| `sm:` / `md:` / `lg:` / `xl:` 出现次数 | 49 / 29 / **3** / **0** |
| 161 个含表文件里有 `overflow-x-auto` 的 | **27(17%)** |
| viewport meta | `app/layout.tsx` 没有 `export const viewport` —— **但 Next 16 默认注入 `width=device-width, initial-scale=1`,所以这一条没问题** |

**具体在手机上会怎样:**

* **表格:161 个含表文件里 134 个没有横向滚动容器。** 990 个 `<th>` 里
  最常见的一族是 `px-4 py-2`,一张八列的表在 390px 宽的屏上**会把整页撑宽**,
  于是**整个页面横向滚动**,顶栏和内容一起跑掉。这是手机上最痛的一条。
* **`TopNav`** 自己是照顾过的(`app/components/TopNav.tsx:50,81` 用 `hidden sm:inline`
  在窄屏藏掉说明文字),所以导航条本身不是问题。
* **50 个响应式文件覆盖到的**:首页 `app/page.tsx`、`/me` 那一族、
  `TaskModal`、`ReasonPrompt`、几个 processing / output 详情页。
  **绝大多数 finance 与 hr 页面(两者合计 87 个 page.tsx)一个断点都没有。**

**一个会在手机上真发作的 live bug —— 深色模式:**

`app/globals.css` 保留着 create-next-app 的默认块:

```css
@media (prefers-color-scheme: dark) {
  :root { --background: #0a0a0a; --foreground: #ededed; }
}
```

而全仓库 **`dark:` 变体出现 0 次**,`bg-white` 出现 **125 次、59 个文件**,
显式深色文字(`text-gray-900` / `text-black`)只有 **13 处**。

**于是:系统深色模式开着的时候,`body` 变成近黑底 + `#ededed` 近白字,
而所有 `bg-white` 的卡片仍然是白底 —— 卡片里没有显式指定颜色的文字
(包括 `/login` 的 `<h1 className="text-2xl font-bold">`)会变成【白底白字】。**

手机默认开深色模式的比例远高于桌面,而 Tim 在手机上用这个系统。

> ### ★ 已修复 —— DARK-FIX-1(2026-09-01)★
>
> **这个仓库【没有深色模式】,而且是刻意没有的。** 那个 `@media` 块已经删掉,
> 两个变量与它们的浅色值原样留着(Phase 8 可能要用)。
> **不要因为看着像一次疏漏就把它加回来** —— 要做主题是 **Phase 8 的决定**,
> 而那个决定要对着**还不存在的品牌 token** 去做;**半个主题比没有更坏。**
> 理由与实测数字写在 `app/globals.css` 那段注释里,读它的人正是可能加回来的人。
>
> **修复前后的实测(CDP 模拟 `prefers-color-scheme`,读 `getComputedStyle`):**
>
> | 探针 | 修复前(深色) | 修复后(深色) |
> |---|---|---|
> | `/login` 的 `<h1>`(具名实例) | `#ededed` on `#ffffff` — **1.17:1** | `#171717` on `#ffffff` — **17.93:1** |
> | `/finance/invoices` 的 `thead.bg-gray-100` | `#ededed` on `#f3f4f6` — **1.06:1** | `#171717` on `#f3f4f6` — **16.29:1** |
> | 顶栏 `nav`(**每一页都有**) | `#ededed` on `#ffffff` — **1.17:1** | `#171717` on `#ffffff` — **17.93:1** |
>
> **勘察当时低估了它的范围:** 上面写的是「`bg-white` 的卡片」,而实测最坏的一处
> 是表头(`bg-gray-100`,**1.06:1**,比 `/login` 还低),并且**顶栏在每一页上**,
> 所以它不是几页的毛病,是全站的。
>
> **浅色外观未变是【测】出来的,不是推出来的:** 同一套探针在
> `prefers-color-scheme: light` 下跑修复前与修复后,两份输出**逐行相同**;
> 而修复后的**深色**输出与**浅色**输出也逐行相同,唯一的差别是浏览器自报的那一行
> 偏好 —— 也就是说深色设备现在拿到的就是浅色外观,不再有第二套行为。

---

## PART D · 统一要花多少(STEP 3)

口径:**「碰的文件数」**。每一项标注**机械**(能用脚本改完再人眼过一遍)还是
**逐处判断**(必须一处一处想)。风险按**触达面**分 —— 一个用在五十页上的组件
和一个用在两页上的不是一回事。

| # | 收敛什么 | 碰的文件 | 机械 / 判断 | 风险 | 说明 |
|---|---|---|---|---|---|
| 1 | **36 个文件的局部 class 常量 → 共享 primitive** | **36** | **机械** | **低** | 每个文件删 2–3 行常量、加一个 import。44 个常量 → 3 个概念。**最划算的第一刀。** |
| 2 | **页头 `<h1>`** | **191** | **机械** | **低** | 17 签名归一化后只剩 3 个,差别几乎全在外边距。可脚本替换成 `<PageHeader>`。 |
| 3 | **表单控件 → `<Field>` / `<Input>` / `<Select>` / `<Textarea>`** | **186**(input/select/textarea 文件并集) | **机械 90% / 判断 10%** | **中** | 414 个调用点。判断的那 10% 是右对齐数字格、`uppercase` 的编号格、只读格。**顺带把 474 个未关联标签一次修掉** —— 因为 `<Field>` 会自己发 `id`/`htmlFor`。 |
| 4 | **按钮 → `<Button variant>`** | **198** | **判断** | **中** | 68 签名 → 5 个变体,但 **40 个只用过一次的签名每一个都要判一次**:它是危险操作、次要操作,还是当年随手写的。**不能纯机械做** —— 把一个删除按钮判成中性按钮是真的会伤人的错。 |
| 5 | **表格 → `<DataTable>`** | **161** | **判断** | **高** | 本项最大。1,215 个 `<td>` / 990 个 `<th>`。112 个 `<td>` 签名归一化后只剩 3 类语义(左/右+等宽/密度),但**每一列要判一次它是哪一类**。同时补上今天完全没有的排序与列显隐。 |
| 6 | **空状态 → `<EmptyState>`** | **174** | **判断** | **中** | 252 个分支。**每一处都要判「这句话是在说没有数据,还是在说你看不到」** —— 这正是本仓库付过多次账的那条分界,不能机械替换。 |
| 7 | **横幅 → `<Alert variant>`** | ~120(amber/red/blue/green 的并集) | **机械 70% / 判断 30%** | **中** | 颜色语义**已经一致**,直接映射成四个 variant。判断在于哪些该升级成 `role="alert"`。 |
| 8 | **加载态 → 一种机制** | **64**(自己 useState 的那批) | **判断** | **中** | 把 64 个手写 `pending` 收敛到 `useTransition`(已有 124 个文件在用)。**判断点:哪些 `pending` 其实还兼管着别的状态。** |
| 9 | **「受限」的呈现 → 一个 `<Restricted>`** | **~30**(42 个引用点去重后) | **机械** | **低** | 10 种 className → 1 种。**词汇本身不动**,只统一字体颜色。 |
| 10 | ~~**深色模式冲突**~~ | ~~1~~ | — | — | **已由 DARK-FIX-1(2026-09-01)做掉** —— 那个 `@media` 块已删,深色模式**刻意缺席**。①a 写 token 时不要把它带回来。 |
| 11 | **`/login` 的 `autoComplete` + 标签关联** | **1** | **机械** | **低** | 两行属性。 |
| 12 | **手机:表格横向滚动** | **134**(含表但无 overflow-x) | **机械** | **低** | `<DataTable>` 自带滚动容器 → **被第 5 项顺带修掉,不必单独做。** |
| 13 | **徽章 / 状态片** | **5** | — | — | **不是收敛,是净新增。** 今天只有 6 处。 |
| 14 | **模态** | **1** | — | — | 只有 `TaskModal`。换成 shadcn `Dialog` 顺带拿到焦点陷阱与 Esc 关闭。 |

**机械 vs 判断的分界总结:**

* **纯机械(可脚本 + 人眼复核)**:1、2、9、10、11、12 —— 合计约 **360 个文件**,
  但其中 134 个由第 5 项顺带完成。
* **必须逐处判断**:4(按钮的 40 个孤儿签名)、5(表格每一列的语义)、
  6(空状态是「没有」还是「看不到」)、8(pending 是否兼管别的状态)。

**按触达面的风险:**

* **最高触达 —— `moduleGuard`(171 个引用方)。** 它不是 UI,是权限守卫。
  **Phase 8 不要碰它。** 记在这里是因为它是全仓库触达面最大的东西,
  任何「顺手重构一下」的念头都必须在这里停住。
* **高触达 UI**:`<DataTable>`(161)、`<Button>`(198)、`<Field>`(186)、
  `<PageHeader>`(191)。这四个一旦定错接口,改一次要动一两百个文件。
  **它们的接口值得在写第一个调用点之前先想清楚。**
* **低触达但高价值**:`ActorName`(8)、`MaskedValue`(9)、`ReasonPrompt`(9)、
  `IssuePanel`(8)、`DraftBanner`(7)。**改起来便宜,改坏了代价最大** ——
  它们承载的是语义,不是样式。

---

## PART E · Phase 8 的次序、大小,与 shadcn 摆在哪(STEP 4)

### 建议次序

```
第 0 步  信息架构 —— 单独勘察 + Tim 拍板          ← 见 PART F,不属于 FE-0
         │
         ├─ 并行 ①a  品牌 token + shadcn init      ← 不依赖架构
         ├─ 并行 ③   对外单据排版(19 个 PDF 文件)  ← 证明与其余全部无交集
         └─ 并行 /login 重做 + 视差                 ← 单页,独立
         │
第 1 步  ①b  primitive 与外壳(照批准的架构做)
第 2 步  ②   架构落地:注册表分类法 + 它要求的外壳
第 3 步  ①-bulk  逐页转换
```

**为什么架构在最前(接受 Tim 的更正,并给一条更强的理由):**

Tim 给的理由是「架构决定了哪些组件存在」。测量之后有一条**更硬**的:
**架构决定了哪些页存在。** 187 个 `page.tsx` 折成 110 个骨架,而信息架构会
合并与拆分其中一部分。**在架构定下来之前做 ①-bulk,转换的不是「会被重做的页」,
是「会被删掉的页」** —— 那不是做两遍,那是白做。

**我提出的一处切分(与 Tim 的次序不冲突,只是把 ① 拆开):**

**①a(token 层)不依赖架构。** 一个颜色 token、一个圆角刻度、一套字号,
不关心导航是顶栏还是侧栏。`shadcn init` 写的 `components.json` + `cn()` +
`@theme` 里的 token 也不关心。**所以 ①a 可以与信息架构勘察并行**,
和 ③、`/login` 一起,**从第一天就有三条独立的活可以开工**。

**①b(primitive 与外壳)依赖架构** —— 侧栏、多级菜单、面包屑、工作台首页
是架构的后果,不是样式的选择。这一条完全接受。

### 次序做错会坏掉什么(brief 明确要求)

| 如果这样做 | 会坏掉什么 |
|---|---|
| **①-bulk 早于架构** | 转换会被合并/删除的页。187 页里被架构动到的那部分**白做**。这是最大的一种浪费。 |
| **①b(外壳)早于架构** | 顶栏做完才发现架构要侧栏 + 面包屑 → 外壳做两遍。Tim 的原话,成立。 |
| **② 早于 ①a** | 新导航先用旧的临时样式落地,token 出来之后**全站最显眼的那一条**要重刷一遍。 |
| **表格(第 5 项)早于按钮与 field(第 3、4 项)** | 表格里就有按钮和输入格。先做表格 = 在表格内部把按钮再发明一次,然后被第 4 项推翻。**依赖方向是 primitive → 表格,不能反。** |
| **`<EmptyState>` 机械替换** | 「没有数据」与「你看不到」会被压成同一句。**这个仓库为这条分界付过多次账**(`lib/permissions.ts` 抬头、`mustRows`/`restRows`、`ActorName` 状态 ④)。**252 个分支必须逐处判**。 |
| **把十二个领域组件「顺手」溶进 shadcn** | 拒绝词汇表**唯一被写下来的地方**没了。见下。 |
| **③ 被排在 ① 后面** | 纯粹的等待。它与任何东西都不冲突,排在后面只是让一条本可以并行的活闲着。 |

### shadcn/ui 摆在哪 —— 以及摆在哪不合适

**合适,而且是纯增量:**

**没有地基需要替换。** 没有任何 UI 库是依赖;`globals.css` 是未改动的
create-next-app 默认;Tailwind v4 + React 19.2.4 + Next 16.2.6 正是 shadcn 的
支持目标。`shadcn init` 是**往下垫一层**,不是拆一层。
**这把 Phase 8 的规模从「换地基」降到「加一层」—— 是本勘察里最重要的一条。**

映射得上的:`Button`(68→5 变体)、`Input`/`Select`/`Textarea`/`Label`
(直接吃掉 36 个文件的局部常量)、`Table`(161 个文件的地基)、
`Alert`(四种颜色语义已经一致)、`Dialog`(唯一那个 TaskModal,顺带拿到
焦点陷阱和 Esc)、`Card`(4 个 `card` 常量)。

**摆不上去、或者需要小心的:**

* **十二个领域组件按【选项 (ii)】处理:在 shadcn primitive 上重建内部,
  冻结 public props 与那些具名状态。**
  `ActorName`、`MaskedValue`、`ReasonPrompt`、`IssuePanel`、`DraftBanner`
  编码的不是样式,是**拒绝语义** —— 「受限」vs 未记录 vs 该账号未关联员工档案
  vs 这份档案已不在,是这个仓库花了很多刀才分清的四句话。
  **shadcn 对这些一个意见都没有。**

  > **不能把它们溶掉。这十二个组件是拒绝词汇表【唯一被写下来的地方】,
  > 溶进调用点等于把仓库花了很多刀才挣到的语义撒回一百八十个文件里。**

  已核实:**`ActorName` 的四个状态没有被复制**,三个 `actor.*` 键只在
  `ActorName.tsx` 里出现。它是干净的,冻结 props 重建内部即可,8 个调用点一处不动。

* **Tremor 做图表 —— 今天没有图表可换。** 全仓库没有任何图表库,
  也几乎没有图表。Tremor 是**净新增**,应该按新功能排期,不是按迁移排期。
* **`Badge` 也是净新增** —— 今天只有 6 处 `rounded-full`。
* **motion.dev** 按 brief 的约束(内部页只用于状态反馈)在这里正好落得下:
  **252 个空状态、90 处红色错误条、124 个文件的 `isPending`** 就是那些「状态反馈」
  的落点,而且它们**已经在**,不需要为了动效再造位置。

### 每一项建议的建造规模

| 项 | 规模 | 理由 |
|---|---|---|
| **第 0 步 信息架构勘察** | **一刀(勘察)+ Tim 拍板** | 问的问题与 FE-0 不同,见 PART F |
| **①a token + shadcn init** | **一刀,小** | 一个 css 文件、一个 `components.json`、一个 `cn()`。可与第 0 步并行 |
| **③ 对外单据排版** | **一到两刀** | 19 个文件,自成一体。注意保住字体覆盖门禁 |
| **`/login`** | **一刀,小** | 单页 + 两行 autoComplete + 视差 |
| **①b primitive 与外壳** | **一到两刀** | primitive 本身不多,外壳大小由架构决定 |
| **② 架构落地** | **无法定 —— 取决于第 0 步** | 注册表那一步是小的;外壳那一步可能是大的 |
| **①-bulk 逐页转换** | **明确不止一刀。按模块切,一刀一到两个模块** | 见下 |

**①-bulk 按模块切的建议顺序(按文件数,先小后大练手):**
logistics(5 页)→ customers/suppliers/materials(11 页)→ inbound/output(12 页)
→ purchasing/processing/sales(26 页)→ inventory/settings(18 页)
→ **hr(33 页)→ finance(54 页)最后**。

> **对 brief 那两个「允许的结论」的回答:两个都成立,但分在不同的项上。**
>
> * **「比一刀大」** —— **①-bulk 与表格(第 5 项)确实比一刀大得多。**
>   161 个含表文件、198 个含按钮文件、186 个含表单控件文件;
>   按模块切也要 **6–8 刀**。
> * **「需要改的比预期少」** —— **在四个地方明确成立,而且是重要的四个:**
>   (1) **没有地基要拆**,shadcn 是纯增量;
>   (2) **i18n 已经做完了** —— 门禁绿,全仓库 1 处硬编码字符串;
>   (3) **拒绝词汇表没有漂** —— 42 处共用一个键,`ActorName` 确认单一;
>   (4) **PDF 完全独立** —— item ③ 白拿一条并行线。
>   另外**导航注册表已经存在**,新架构有地方落。

---

## PART F · Phase 8 的前置:信息架构勘察

**FE-0 刻意不回答下面这些。** 它们需要的是另一种测量,以及一部分只有 Tim 能答。
按 Tim 的更正,这是 Phase 8 真正的第 0 步。

它必须回答的四个问题,以及 FE-0 能先交过去的东西:

1. **~216 个 route 到底是多少个「功能」?**
   *FE-0 交底:* 216 个地址模式 = 187 个 `page.tsx` + 29 个无界面端点。
   把 `/new`、`/edit`、`/[id]` 折掉之后剩 **110 个骨架**(清单可复现:
   `find app -name page.tsx | sed -E 's#/(new|edit)$##; s#/\[[^]]+\]$##' | sort -u`)。
   **110 是折叠后的上界,不是功能数** —— 还有一批骨架是同一条工作流的几块面板。

2. **今天的分组逻辑到底是什么?(要测,不要猜。要检验的假说是「它跟的是构建顺序,
   不是任何人干活的方式」)**
   *FE-0 交底:* **这条假说对顶层注册表【不成立】。** 拿 `lib/modules.ts` 里
   15 个模块的位置对 `git log --diff-filter=A` 的首次提交日期:

   | 位置 | 模块 | 首次提交 |
   |---|---|---|
   | 1–9 | suppliers / purchasing / customers / materials / pricing / inbound / output / processing / inventory | 多数 2026-06-11(初始),purchasing 07-31、pricing 07-30 |
   | 10 | stocktakes | 2026-07-05 |
   | 11 | **sales** | **2026-08-13** |
   | 12 | **finance** | **2026-07-06** |
   | 13 | **tasks** | **2026-06-26** |
   | 14 | hr | 2026-08-01 |
   | 15 | logistics | 2026-08-19 |

   顺序**不是**构建日期单调的(sales 08-13 排在 finance 07-06 之前,
   tasks 06-26 排到第 13 位)。也就是说**顶层顺序有过语义安排**,
   只有**队尾(logistics,最新)像是追加的**。
   **真正该测构建顺序假说的是模块【内部】的页面层级,不是顶层顺序** ——
   那是架构勘察的活。

3. **哪些页从任何入口都到不了?**
   *FE-0 交底:* 需要把 187 个 `page.tsx` 与 `lib/modules.ts` 的 `href` 加上
   页内链接做可达性对图。`AGENTS.md:597` 记着这条路踩过一次
   (「一个被 CSS 藏起来的链接对走查器是可达的,对人是看不见的」),
   **所以这个测量要按「人看得见」判,不是按「DOM 里有」判**。
   `NavLinks.tsx` 抬头点名 `/margin` 与 `/deleted`
   **「装不进 lib/modules.ts 的形状」** —— 这两个是已知的特例,起点在这。

4. **六个具名的人每天各自需要哪些页?**
   *FE-0 不作答,这是裁定不是勘察。* 可由 Tim 直接答,或从权限矩阵推
   (`app/settings/permissions/`)。**分层必须跟着人怎么干活走,
   不是跟着数据库怎么建的走** —— 这一句是 Tim 的,原样记在这里。

---

## PART G · 逐条对照 brief

| 条款 | 状态 |
|---|---|
| STEP 0 状态检查 | ✅ HEAD `22c22f0`、HEAD == origin/main、树干净,三项全对,未做任何调和 |
| STEP 1 具名调用 grilling | ✅ 已调用;删掉三条假前提(A1 导航堆叠、A2 PDF 纠缠、A3 231 routes),确认一条(A4 logistics 权限码) |
| STEP 1 · EXISTENCE FIRST | ✅ PART A + Q1:**没有共享组件层**(12 个组件,引用数全是个位数)、**没有 token 文件**、**没有样式指南** |
| STEP 1 · 「distinct implementations」是否良定义 | ✅ A5:不完全是;定了归一化口径,两种都数,并写明**代价跟 N−M 不跟 N** |
| STEP 1 · shadcn 兼容还是要换地基 | ✅ **兼容,纯增量,没有地基要拆**(Q1) |
| STEP 1 · 三项是否可分 / 有序 | ✅ 挑战并重答:接受架构在最前;新增证据 **③ 完全独立**;提出 **①a/①b 切分** |
| STEP 2 · Q1 用什么写的 | ✅ PART B/Q1 |
| STEP 2 · Q2 有多大 | ✅ PART B/Q2,route 216 与 page 187 分开报并解释差别 |
| STEP 2 · Q3 几种做法 | ✅ PART B/Q3,逐种给数与文件名 |
| STEP 2 · Q4 表格怎么搭 | ✅ PART B/Q4,排序/筛选/分页/列显隐/空状态逐项 |
| STEP 2 · a 拒绝词汇表 | ✅ PART C/a,`ActorName` 确认**未被复制** |
| STEP 2 · b i18n | ✅ PART C/b,不走文案的字符串:**1 处**(品牌名) |
| STEP 2 · c PDF 路径 | ✅ PART C/c |
| STEP 2 · d 可及性 | ✅ PART C/d,含 `/login` 密码管理器的照直回答 |
| STEP 2 · e 手机 | ✅ PART C/e,含深色模式 live bug(**该 bug 已由 DARK-FIX-1 于 2026-09-01 修复**;深色模式此后是**刻意缺席**,主题留给 Phase 8 对着品牌 token 决定) |
| STEP 3 · 代价、机械 vs 判断、按触达面的风险 | ✅ PART D |
| STEP 4 · 文档 / 次序 / shadcn 位置 / 每项规模 | ✅ PART E |
| STEP 4 · 次序做错会坏掉什么 | ✅ PART E「次序做错会坏掉什么」 |
| 更正后新增:信息架构勘察作为前置 | ✅ PART F |
| 只写这一个文件 | ✅ 无其他写入 |

