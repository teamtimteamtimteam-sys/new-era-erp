# BTN-TRIGGER-1 —— 交回报告(2026-09-20)

> ## 0 · 先读这六条
>
> 1. ★★★ **委托书那个「42」是错的,树上是 33。** 而这一条不是我发现的 ——
>    `docs/known-issues.md` 的 BTN-TRIGGER-1 **早就把 42 更正成 33 了**,更正的日期
>    比这份委托书还早。☞ 委托书抄的是 POLISH-1 **round 1** 的读数,而那一条自己
>    在同一个文件里写着「重量下来是 58 / 25 / 33」。**这是 AGENTS.md「委托书里的数
>    来自上一份报告,而不是来自一次测量」的第 N 次。**
> 2. ★★★ **而「26」也是错的,它少了 2 —— 少的方式比数值值钱。** 26 是
>    `13 + 13`,两个 13 来自一支**读 className 属性文本**的扫描器。树上有
>    **两处** `className={cls}` —— 一个**标识符**,而那个标识符的值里就写着
>    `disabled:opacity-50`。☞ 一支按属性文本判的扫描器**按构造**看不见它。
>    **我自己第一版也看不见**,是把 `className={X}` 回溯到同文件 `const X =` 之后
>    才多出来那 2 处。真值:`opacity-50` **15** · `text-gray-400` **13** = **28**。
> 3. ★★★ **而真正的总体是 33,不是 28。** 剩下那 5 处带着**第三种写法**
>    `disabled:bg-gray-400`(白字 on `#99A1AF` = **2.602:1**)—— 而那正是
>    `button.tsx` 抬头亲自点名、BTN-1 整刀要取代的那一种。登记只写了两种。
>    ☞ **实测:33 个站点 × 2 种底 = 66 个读数,66 个全部过不了 AA。**
> 4. ★★★ **委托书的「组件库棘轮这一刀应当大幅缩短」是【按构造】不可能的。**
>    棘轮数的是 `app/` 里**不含组件库自己**的手写 `<button`;而这 33 颗裸触发钮
>    是 `confirm-dialog.tsx`(**组件库自己**)渲染的,调用点上写的是 `<ConfirmButton`。
>    ★ 棘轮**没有 `ConfirmButton` 这一维**(脚本与基线里各 0 次命中)。
>    实测改前改后**四维逐字相同**:table 35/39 · button 10/17 · linkbutton 11/15。
>    ☞ **这一行不是「没缩短」,是「这道闸看不见这笔债」** —— 而那本身是一个发现。
> 5. ★★ **X3b 停住了,而这是委托书 §3 自己要的处置。** `<EditableTable>` 手机档
>    那颗钮今天 **44px**,而档位表是 24 / 28 / 32 / 36 / 48 —— **没有 44**。
>    三条路全部改变行高(见 §6)。⚠ 而且**在册的量具看不见它**:它住在
>    `{isOpen && hasPhonePanel && …}` 里,而 `--mode=drift` 只量首屏。
>    **一个绿的 (c) 不会覆盖这一格。**
> 6. ★★ **X3a 的主语在另一个文件里,而它是一个【解构默认值】。** 队列把那颗
>    `<select>` 记在 `FormulaForm` 名下 —— 那一页上三颗 `<select>` **早就**走
>    `CONTROL_SELECT` 了。那串 `w-full border border-gray-300 px-3 py-2 rounded`
>    一直住在 `IndexPicker` 的解构默认值里,**照 `<select>` 标签去找找不到它**。
>    ☞ 我自己先读了类型块(`className?: string`)并据此写下「没有默认值」——
>    **默认值在它上面三行**。这条更正记在这里,因为下一个人会犯同一个错。

---

## 1 · 开工闸(§1.1)

| | |
|---|---|
| `git status --porcelain` | 空 |
| 本地 `HEAD` | `e147d5bc52e08ddbda63d2b38a92164de4d49be3` |
| `origin/main` | `e147d5bc52e08ddbda63d2b38a92164de4d49be3` |
| `git ls-remote origin main` | `e147d5bc52e08ddbda63d2b38a92164de4d49be3` |

三个逐字相同,且等于 `e147d5b`。

---

## 2 · §1.2 —— 委托书里的每一个数,逐条重量

★ **量法写在这里,因为下一个人要重量。** 不是一条正则:剥掉注释 → 从开标签起
**逐字符**扫,跟踪引号 / 模板串 / 花括号深度,**深度 0** 上的第一个 `>` 才是开标签
的结尾;属性**只读深度 0 那一层**(否则 `details={<p className="…">}` 里孩子的
className 会被记到触发钮头上 —— round 1 就是这么把 9 处真缺陷藏起来的)。
★ **再加一层**:`className` 的值可以是一个**标识符**,所以还要回溯到同文件的
`const X =` 去读它真正的值 —— **这一层是登记的 26 漏掉 2 处的原因**。

| 委托书写的 | 实测 | 判词 |
|---|---|---|
| 42 raw triggers | **33**(77 原始命中 · 19 在注释里 · 58 真调用点 · 25 已给 `triggerVariant` · **33 裸**) | ★ **错**。42 是 POLISH-1 round 1 的读数,known-issues 早已更正为 33 |
| across ~45 files | **32 个文件** | ★ **错**(`CloseReopenControls.tsx` 占 2 处) |
| 「at least three visual shapes」 | **4 族 / 7 种指纹** | ✓ **对** |
| 「generic `bg-blue-600`/`bg-red-600`/`bg-green-600`」 | 实心泛色只有 **5 / 33**;红色文字链 **14**、描边盒 **12**、动态 **2** | ★ **错**(它描述的是少数派) |
| 26 disabled-state defects | ★ **28**(opacity-50 **15** + text-gray-400 **13**);★ 而**三种写法合计 33 处全部不合规** | ★ **错**,见 §0.2 / §0.3 |
| 原始计数里 12 × opacity-50 + 5 × gray-400 | = 17,与 known-issues 记的 round 1 读数逐字相同 | ✓ **对**(作为历史) |
| `disabled:text-gray-400` v4 是 2.60,不是 v3 的 2.54 | v4 `#99A1AF` **2.602** · v3 `#9CA3AF` **2.539** | ✓ **对** |
| BTN-1 的 11.27:1 | `#182B4B` on `#DDE7EF` = **11.273:1** | ✓ **对** |
| 2 inherited items | known-issues 在本条下登记 **4 件**;委托书划走 1 件(7 个对话框)⇒ **3 件**。★ 第三件(`StatusPanel.tsx:103` 那颗蓝描边钮)**今天已经不渲染了** —— 早前某一刀把那一支换成了 `<Button variant="secondary">`,剩下的是一段**到不了的三元分支** | ★ **错**(是 3,而其中 1 件的主语已经没了) |
| `<EditableTable>` 在 4 条路由上 | **4 条**:`/me` · `/hr/kpi/score` · `/hr/leave/types` · `/hr/reviews/scale`(`<EditableTable` 原始命中 6,其中 2 条在注释里) | ✓ **对** |

---

## 3 · 量具:第六支一次性探针,以及它为什么还是一次性的

BTN-SIZE-1 §8.4 写着「这已经是第五支」,并且建议单独立一条:
**今天没有任何一道在册的闸看得见按钮的渲染高度。** 那一条仍然成立,本刀是第六支。
不进仓库的理由与 BTN-SIZE-1 逐字相同:给 `survey-controls` 的 `ROLE_SELECTORS`
加一个 button 角色会**改掉 `--mode=compare` 的成员签名**。

**它量什么、怎么量:**

* **`<Button>` 的 class 串不是抄的。** 本支把 `button.tsx` 里那一整个 `cva(...)`
  调用**原样切出来,用 node_modules 里真的 `class-variance-authority` +
  `tailwind-merge` 求值**。☞ 抄一份 class 串进量具,就是在量具里再放一份会漂的
  库定义 —— 与 `check-datatable-footer` 把 `button.tsx` 放进 `REAL` 而不是
  `STUBS` 是同一条理由。★ 并且钉住:基础串里必须还有 `border border-transparent`
  / `inline-flex` / `h-8`,少一个**当场抛**(不是静默解析成别的)。
* **CSS 是真的。** 用 `postcss` + `@tailwindcss/postcss` 编 `app/globals.css`
  (`optimize:false`,理由见 `check-generated-css` 抬头),97,964 字节。
* **对比度是量的,不是算的。** ★ BTN-1 §10.5 记过这个坑:
  `getComputedStyle().color` 报的是**没有褪色的**值,于是 `disabled:opacity-50`
  照样绿。本支把**从元素到 `<html>` 的每一层 `opacity` 连乘**,再按「组透明度
  把元素画好的结果整体压在底上」合成 —— **字与底各合成一次**,然后取比值。
* ★ **颜色解析不认记法。** 第一版用 `rgba?\(…\)` 正则,而 Tailwind v4 发
  `oklch()`,`getComputedStyle` 会还回 `oklab()` / `color(srgb …)` ——
  正则**读成 null,当场崩**。改成**让引擎栅格化一个像素再读回字节**:
  它对浏览器画得出的**每一种**记法都成立,包括这支写完之后才加进去的那些。
  ☞ 记在这里,因为这是「一支扫描器的某一层,可以和它的另一层不一样瞎」的又一例。
* **覆盖断言。** 一跑量到 0 颗按钮**当场抛**;逐元素走出来的数必须对上一条
  不走同一段 JS 的独立计数。**一支挑不到候选的普查必须说「我瞎了」。**

⚠ **它【不】量什么,照直说:** 它量的是**控件自己那个盒子**在一个复刻的表格
单元格 / flex 行里的几何。**它不是在真实路由上量的** —— 33 处里有 23 处住在
`[id]` 详情页或一个特定状态背后(一个关掉的期间、一张过了账的薪资表)。
☞ **行高那一问由在册的量具回答**(`--mode=drift` 的逐表行高,141 条静态路由
× 2 视口),而那份读数的分母**不含 `[id]` 页**。两边的盲区在 §7 并排写出来。

---

## 4 · X1 —— 33 处逐条的档位判读

★ **判据是 `docs/base-components.md` §10.1,而且是【POLISH-1 R2 收窄之后】的那一版**
(§10.2 的就地修订):`destructive` 说的是「**按下去,一件已经生效的事会被推翻,
而那件事别人已经在用**」;`reversal` 说的是「**一个我自己刚做的、还没扩散出去的
状态回退一格**」。★ **「它删不删行」不再是判据。**

★★ **而颜色一次都没有当过判据 —— 两个方向都是:**
* `ApprovalControls.tsx:42` 今天是**绿的**,写着「批准」。它把采购单推到
  `confirmed`,**从此收得了货、付得了预付** —— 落在他以外的人身上 ⇒ `destructive`。
* `AttributeCustomerControl.tsx:94` / `CloseReopenControls.tsx:96` /
  `GstPanel.tsx:102` 今天是**蓝的**(`bg-blue-600`),三个都是 `destructive`。
* `UnreconcileControl.tsx:50` / `CloseReopenControls.tsx:149` 今天是**灰描边**,
  两个都是 `reversal`。

**档位判读(33 处全部判过):`destructive` 25 · `reversal` 7 · ★ 不转 1 = 33。**
★★ **而【落地】的是 29 处** —— 另外 3 处转过去之后量到它们推动表格行高,
按委托书 §3 **按回原样并报出差值**(见 §7.1)。落地那 29 处:`destructive` 23 · `reversal` 6;
按档位号 `inline` 12 · `xs` 2 · `default` 15。

### 4.1 ★★ 那一处【不转】,以及为什么不转比转更对

`app/output/[id]/edit/SafetyStatePanel.tsx:89`。

它**不是一颗按钮**,它是**一个切换控件的一半**:`on ? <ConfirmButton> : <button>`,
两支**共用同一个 `cls`**。而**另一半**就在 `docs/base-components.md` §16.4 A 的
余量表上(「多选切换组」),也在 `check-component-library` 的基线里
(`SafetyStatePanel.tsx: 1`)—— **那一条明写着不转它,理由是转过去会把一个
无障碍缺陷固化下来同时对外宣称"已统一"**。

☞ **只转 `on` 那一支,会让【同一个控件的两个状态】长得不一样** ——
而 Tim 在 R2 给的理由逐字是「**功能相同的按钮必须长得一样**」。
**那正是这一步会违反的那一条。**

★ **代价照直记:它那处 `disabled:opacity-50` 缺陷【活下来了】。**
实测 **2.722:1(白底)/ 2.757:1(`--brand-bg`)**,两个都过不了 AA。
**登记,不是藏起来** —— 见 §9。

### 4.2 ★★ 七处【没有决定】的档位,以及停止条件为什么没有触发

委托书:「**NOT IN SCOPE: the 7 dialogs whose confirm button still draws the dashed
`reversal` bar。……If converting a trigger makes its dialog's confirm button visibly
disagree with it, STOP and report rather than deciding.**」

这 7 个对话框的**触发钮就是这 33 里的 7 处**。处置:**全部取 `triggerVariant="reversal"`** ——
也就是**它们的对话框今天已经带着的那个 `tier`**。
☞ 于是触发钮与确认钮**画同一根虚线竖条**,**没有产生任何分歧**,
**停止条件按它自己的措辞没有触发**,而我**一条 `tier` 都没有碰**。

★★ **但有三处,照【收窄之后的判据】读下来是 `destructive`,照直报出来:**

| 站点 | 它做什么 | 为什么读起来是 destructive |
|---|---|---|
| `hr/payroll/[id]/PostControls.tsx:120` | **撤销一张已过账的薪资表** | 冲销的是**已经进了总账的分录** —— POLISH-1 把 `ReverseButton`(总账冲销)判成 destructive,同一条理由 |
| `finance/close/ReopenForm.tsx:56` | **重开一个已关账期间** | Tim 在 POLISH-1 把 `LockForm`(期间锁)**明确判成 destructive**,这是同一个形状 |
| `finance/close/YearClosePanel.tsx:72` | **重开一个已关的财年** | 同上,而且范围更大 |

☞ **要把这三处判成 `destructive`,就必须同时裁它们的对话框 `tier`** ——
而那 7 个对话框**明写不在本刀范围内**。
**所以这里不裁,只报。** 这一条等 Tim 一句话,和 `POLISH1-REVERSAL-DIALOG-TIERS` 一起。

★ **同一形状的第四处:`finance/settings/GstPanel.tsx:102`(Turn GST **on**)。**
照 §10.1 字面它是 `default`(「这一页存在的那个动作」),但它的对话框
`tier="destructive"`,给触发钮 `default` 会让**实心 ocean 钮**对上**破坏档确认钮**
—— 又是一次「看得见的分歧」。**取 `destructive`**(与它的孪生钮
`GstPanel.tsx:140` Turn GST **off** 今天的 `triggerVariant` 逐字相同),**并报出来**。

### 4.3 逐处的判读与读数(33 处,一处不漏)

> ★ **高度是在【真的编译出来的 CSS】上、在浏览器里量的**,不是从 class 串推的;
> **`<Button>` 的 class 串是把 `button.tsx` 里那个 `cva(...)` 原样切出来、用 node_modules 里
> 真的 `class-variance-authority` + `tailwind-merge` 求值得到的** —— 抄一份进量具,就是在量具里
> 再放一份会漂的库定义。
> ★ **对比度是白底那一列**(`--brand-bg` 那一列见 §5),**opacity 连乘之后合成再取比值**。
>
> ★★ **这张表是【33 处的判读与实测】,不是【落地清单】。** 其中三处
> (`sales/customers/DeleteButton.tsx:22` · `suppliers/DeleteButton.tsx:22` ·
> `finance/close/ReopenForm.tsx:56`)**转过去、量了、按回来了** —— 它们那一行的
> 「改后」是**那次测量**的读数,不是今天树上的样子。为什么按回去,见 §7.1。

| # | 站点 | 档 | size | 高度 改前→改后 | border-width | 禁用态对比度 白底 改前→改后 | 判据 |
|--:|---|---|---|--:|--:|--:|---|
| 1 | `components/finance/FinanceAttachmentsPanel.tsx:227` | destructive | inline | 20→22 (+2) | 0→1 | 2.602 → 14.132 (text-gray-400) | soft-deletes a finance attachment row others read; destroys a record -> destructive. Lives as a run of text in a DataTable cell -> inline (BTN-3 built that size for exactly this population). Dialog tier already destructive: agrees. |
| 2 | `components/metals/MetalContentPanel.tsx:177` | destructive | inline | 20→22 (+2) | 0→1 | 2.602 → 14.132 (text-gray-400) | HARD delete (.delete(), no copy anywhere) of a metal content row -> destructive. Text in a DataTable action cell -> inline. Dialog tier destructive: agrees. |
| 3 | `finance/assets/[id]/ServiceIntervalPanel.tsx:293` | destructive | xs | 22→24 (+2) | 1→1 | 3.022 → 11.273 (opacity-50) | stops a service interval that the maintenance board is driven from -> overturns something others rely on -> destructive. Sibling in the same flex row is already Button secondary size=xs; today it is text-xs py-0.5 -> xs is the matching step. Dialog tier destructive: agrees. |
| 4 | `finance/bank/statements/[id]/reconcile/ReconcileWorkspace.tsx:679` | destructive | default | 36→32 (-4) | 0→1 | 2.602 → 11.273 (bg-gray-400) | completes reconciliation of a whole statement - the ledger position everyone downstream reads. Its own dialog tier is destructive; making the trigger `default` (the page-purpose reading) would put a solid ocean trigger against a destructive dialog confirm = visible disagreement, which this cut is to |
| 5 | `finance/bank/statements/[id]/UnreconcileControl.tsx:50` | reversal | default | 30→32 (+2) | 1→1 | 3.022 → 11.273 (opacity-50) | one of the 7 whose DIALOG is tier=reversal and OUT OF SCOPE. reversal keeps trigger and dialog in agreement; any other variant creates the disagreement the delegation says to stop on. See the STOP note in the handback. |
| 6 | `finance/close/ReopenForm.tsx:56` | reversal | default | 30→32 (+2) | 1→1 | 2.557 → 11.273 (opacity-50) | same 7-dialog family. NOTE: under the amended criterion this one reads destructive (re-opening a locked period is exactly the shape Tim ruled destructive on LockForm). Deciding it means ruling on its dialog, which is out of scope -> reported, not decided. |
| 7 | `finance/close/YearClosePanel.tsx:72` | reversal | default | 30→32 (+2) | 1→1 | 2.778 → 11.273 (opacity-50) | same 7-dialog family; same flag as ReopenForm (re-opening a closed financial year). |
| 8 | `finance/invoices/[id]/VoidInvoiceControl.tsx:105` | destructive | default | 28→32 (+4) | 0→1 | 2.602 → 11.273 (bg-gray-400) | voids an invoice - AGENTS/BTN-1 line: voiding kills the DOCUMENT -> destructive. Dialog tier destructive: agrees. |
| 9 | `finance/receivables/[saleId]/AttributeCustomerControl.tsx:94` | destructive | default | 36→32 (-4) | 0→1 | 2.602 → 11.273 (bg-gray-400) | source comment: 'one-way and not undoable'. Attributes a receivable to a customer permanently -> destructive. Wears bg-blue-600 today: the colour is not the evidence. Dialog tier destructive: agrees. |
| 10 | `finance/settings/GstPanel.tsx:102` | destructive | default | 36→32 (-4) | 0→1 | 2.602 → 11.273 (bg-gray-400) | turns GST ON system-wide. By §10.1 alone this reads `default` (the action the panel exists for), but its dialog tier is destructive, and `default` would render a solid ocean trigger against a destructive confirm = visible disagreement -> not decided here. destructive agrees. Its sibling (Turn GST of |
| 11 | `hr/departments/DeleteDepartmentButton.tsx:20` | destructive | inline | 20→22 (+2) | 0→1 | 2.602 → 14.132 (text-gray-400) | soft-deletes a department - shared org master data -> destructive. text-link shape in a list row -> inline. |
| 12 | `hr/payroll/[id]/PostControls.tsx:120` | reversal | default | 34→32 (-2) | 1→1 | 2.557 → 11.273 (opacity-50) | same 7-dialog family. NOTE: un-posting a payroll run reverses journals already in the general ledger - the amended criterion's own example of destructive. Reported, not decided. |
| 13 | `hr/training/DeleteTrainingButton.tsx:19` | destructive | inline | 20→22 (+2) | 0→1 | 2.602 → 14.132 (text-gray-400) | soft-deletes a training record -> destructive; text-link in a list row -> inline. |
| 14 | `inbound/[id]/assays/[assayId]/ApplyAssayControls.tsx:84` | reversal | default | 34→32 (-2) | 1→1 | 2.557 → 11.273 (opacity-50) | same 7-dialog family; un-applies an assay. Stays reversal to agree with its dialog. |
| 15 | `materials/[id]/edit/AttachmentsPanel.tsx:193` | destructive | inline | 20→22 (+2) | 0→1 | 2.602 → 14.132 (text-gray-400) | soft-deletes a file -> destructive. Sits immediately beside an existing <Button variant=link size=inline> separated by a pipe - the inline pair already exists in this very cell. |
| 16 | `materials/DeleteButton.tsx:22` | destructive | inline | 20→22 (+2) | 0→1 | 2.602 → 14.132 (text-gray-400) | soft-deletes a material - shared master data -> destructive; text-link in a list row -> inline. |
| 17 | `operation/processing/[id]/CostPanel.tsx:101` | destructive | inline | 20→22 (+2) | 0→1 | 2.602 → 14.132 (text-gray-400) | soft-deletes a cost line on a processing run -> destructive. Beside an existing <Button variant=link size=inline> in the same cell. |
| 18 | `output/[id]/assays/[assayId]/OutputApplyControls.tsx:83` | reversal | default | 34→32 (-2) | 1→1 | 2.557 → 11.273 (opacity-50) | same 7-dialog family; mirror of ApplyAssayControls. |
| 19 | `purchasing/orders/[id]/ApprovalControls.tsx:42` | destructive | default | 34→32 (-2) | 1→1 | 2.108 → 11.273 (opacity-50) | APPROVES a purchase order - pushes it to confirmed, after which goods can be received and prepayments paid. It lands on other people, which is the amended criterion's whole test. It wears green today: the colour is not the evidence, in either direction. Dialog tier already destructive: agrees. |
| 20 | `purchasing/orders/[id]/CloseReopenControls.tsx:96` | destructive | default | 32→32 (0) | 0→1 | 2.602 → 11.273 (bg-gray-400) | closes a purchase order. Dialog tier destructive: agrees. Wears bg-blue-600 today. |
| 21 | `purchasing/orders/[id]/CloseReopenControls.tsx:149` | reversal | default | 34→32 (-2) | 1→1 | 3.022 → 11.273 (opacity-50) | same 7-dialog family; re-opens a closed PO. |
| 22 | `purchasing/payment-terms/DeleteTemplateButton.tsx:25` | destructive | inline | 20→22 (+2) | 0→1 | 2.602 → 14.132 (text-gray-400) | soft-deletes a payment-term template used by other documents -> destructive; text-link in a list row -> inline. |
| 23 | `sales/customers/[id]/edit/AttachmentsPanel.tsx:200` | destructive | inline | 20→22 (+2) | 0→1 | 2.602 → 14.132 (text-gray-400) | soft-deletes a file -> destructive; inline pair already in the cell. |
| 24 | `sales/customers/DeleteButton.tsx:22` | destructive | inline | 20→22 (+2) | 0→1 | 2.602 → 14.132 (text-gray-400) | soft-deletes a customer -> destructive; text-link in a list row -> inline. |
| 25 | `settings/dictionaries/DictSection.tsx:102` | destructive | xs | 22→24 (+2) | 1→1 | 3.022 → 11.273 (opacity-50) | deactivates a dictionary code that other documents reference (the dialog states the usage count) -> destructive. Its OWN else-branch sibling is already <Button variant=secondary size=xs>, and it is today text-xs py-0.5 -> xs is the matching step. Dialog tier destructive: agrees. |
| 26 | `suppliers/[id]/edit/AttachmentsPanel.tsx:200` | destructive | inline | 20→22 (+2) | 0→1 | 2.602 → 14.132 (text-gray-400) | soft-deletes a file -> destructive; inline pair already in the cell. |
| 27 | `suppliers/[id]/edit/CompliancePanel.tsx:84` | destructive | inline | 20→22 (+2) | 0→1 | 2.602 → 14.132 (text-gray-400) | soft-deletes a compliance certificate -> destructive; text-link, rendered twice (desktop column + phone stack) from one shared definition. |
| 28 | `suppliers/[id]/edit/StatusPanel.tsx:129` | destructive | default | 34→32 (-2) | 1→1 | 2.778 → 11.273 (opacity-50) | drives a supplier through a DESTRUCTIVE_TRANSITIONS status change - the non-destructive transitions in the same map already render <Button variant=secondary> at default size, so this is the matching step and puts one flex-wrap row into one paint. Dialog tier destructive: agrees. |
| 29 | `suppliers/DeleteButton.tsx:22` | destructive | inline | 20→22 (+2) | 0→1 | 2.602 → 14.132 (text-gray-400) | soft-deletes a supplier -> destructive; text-link in a list row -> inline. |
| 30 | `tools/pricing/formulas/[id]/edit/DeleteFormulaButton.tsx:17` | destructive | default | 38→32 (-6) | 1→1 | 2.557 → 11.273 (opacity-50) | soft-deletes a pricing formula that priced live documents -> destructive. It is a standalone box on an edit page, not a text run. |
| 31 | `tools/pricing/metal-prices/[id]/edit/DeleteButton.tsx:16` | destructive | default | 30→32 (+2) | 1→1 | 2.557 → 11.273 (opacity-50) | soft-deletes a metal price row -> destructive. Standalone box on an edit page. |
| 32 | `tools/tasks/[id]/TaskHeader.tsx:187` | destructive | inline | 20→22 (+2) | 0→1 | 2.778 → 14.132 (opacity-50) | soft-deletes a task -> destructive. It is a text run pushed to the end of the header action row by a flex-1 spacer; inline is the step that reproduces its geometry. Its neighbours are default-size boxes - reported as a shape inconsistency rather than silently resized. |
| 33 | `output/[id]/edit/SafetyStatePanel.tsx:89` | ★ 不转 | — | 34 未转 | 1→— | 2.722 → 仍是 2.722 (opacity-50) | NOT CONVERTED. This ConfirmButton is ONE HALF of a two-state toggle: `on ? <ConfirmButton> : <button>`, both taking the same `cls`. docs/base-components.md §16.4 A lists the other half as deliberately hand-written (multi-select toggle group), and check-component-library's baseline carries it. Conver |

---

## 5 · X2 —— 禁用态:33 个站点 × 2 种底 = 66 个读数,66 个全红

★ **委托书的警告是对的,而它比委托书说的还要紧:**
「`disabled:opacity-50` 没有一个比值 —— 它是把底下那层墨兑一半白」。
☞ **所以下面按【每一个站点 × 每一种底】报,一个合计数都不给。**

### 5.1 ★★ 三种写法,不是两种

| 写法 | 处数 | 它渲染成什么 | 白底 | `--brand-bg` 上 |
|---|--:|---|--:|--:|
| `disabled:text-gray-400` | **13** | `#99A1AF`(Tailwind **v4**) | **2.602 ✗** | **2.443 ✗** |
| `disabled:opacity-50` | ★ **15**(登记写的是 13) | 随底下那层墨变 | **2.108 – 3.022 ✗** | **2.045 – 2.970 ✗** |
| ★ **`disabled:bg-gray-400`** | ★ **5** —— **登记里没有这一种** | 白字 on `#99A1AF` | **2.602 ✗** | **2.602 ✗** |
| **合计** | ★ **33 / 33** | | **全部 ✗** | **全部 ✗** |

★ **第三种不是我新立的标准。** `button.tsx` 的抬头逐字写着
「而它要取代的那 62 处手写按钮用的是 `disabled:bg-gray-400` → **2.54:1**」——
**BTN-1 整刀就是为了取代它而存在的**,登记只是没把它数进这一条。
(2.54 是 v3 的 `#9CA3AF`;**这棵树是 v4**,实测 **2.602**。)

### 5.2 逐个站点的实测读数

★ **`opacity-50` 那 15 处按它压在什么墨上散开,而散开的样子复算了 known-issues 的表:**

| 压在什么上 | 白底 | `--brand-bg` 上 | known-issues 记的 |
|---|--:|--:|---|
| `text-red-600` | **2.557** | **2.525** | 2.55 / 2.52 ✓ |
| `text-red-700` | **2.778** | **2.745** | 2.77 / 2.73 ✓ |
| `text-green-700`(`ApprovalControls`) | ★ **2.108** | ★ **2.056** | 2.10 / 2.04 ✓ |
| 没有字色类(继承 `--brand-text`) | **3.022** | **2.970** | ★ 登记里没有这一档 |

### 5.3 改后

| 落到哪一档 | 实测 | 处数 |
|---|--:|--:|
| 盒子档(`--brand-disabled-bg #DDE7EF` + `--brand-text #182B4B`) | ★ **11.273:1 ✓** | 17 |
| 行内档(`size="inline"` 带 `disabled:bg-transparent`,字落在页面底上) | ★ **14.132(白底)/ 13.272(`--brand-bg`)✓** | 12 |
| ★ **没有改到的** | **2.108 – 3.022 ✗** | ★ **4** —— `SafetyStatePanel`(§4.1,故意)+ §7.1 那三处(量了按回来的) |

★ **11.273 与 BTN-1 记的 11.27、BTN-SIZE-1 记的 11.273 逐字吻合;
14.132 与 BTN-3 为行内档记的 14.13 逐字吻合。**
☞ **三份独立的读数对上了同一个数** —— 这比我自己报一个新数值钱。

**总账:66 个读数 → 改前 66 红;★ 改后 58 绿 / 8 红,而那 8 个是【4 个站点 × 两种底】** ——
1 个是故意不转的(§4.1),3 个是量到推动行高之后按回原样的(§7.1)。

---

## 6 · X3 —— 两件继承的小件,其中一件停住了

### 6.1 ★★ 那颗 `<select>`:主语在另一个文件里,而它是一个解构默认值

**队列「合并的小件 ④」记的是**:`/tools/pricing/formulas/new`,组件 `FormulaForm`,
`w-full border border-gray-300 px-3 py-2 rounded`。

★ **照 `<select>` 标签去 `FormulaForm.tsx` 里找,找不到它** —— 那一页上三颗
`<select>`(:139 / :296 / :314)**全部**已经写着 `CONTROL_SELECT`。

☞ **枚举 P 住的那个空间,不要枚举那个名字**(§BTN-2 的那一条)。
全树 `<select>` 元素 **257 个**:直接写 `CONTROL_SELECT` 的 **202**;
经一个同文件标识符(`fieldSelect` / `sel` / `selectCls` …)解析过去的再 **52**;
**剩 3 个**:2 个是 `IndexPicker` / `WasteClassPicker` 的 `className` **prop**,
1 族是 `ReceiveForm` 的 E6 触控档(**已登记在 `BTNSIZE1-E6-INPUTS-STILL-HANDWRITTEN`,不是本条**)。

★ **那串 class 住在 `app/tools/pricing/metal-prices/IndexPicker.tsx` 的解构默认值里**,
逐字就是队列写的那一串。`FormulaForm` 只是**渲染**它(`:159`),另外两个消费者是
`SourcePicker:76` 与 `EditMetalPriceForm:120` —— **三处都不传 `className`**,
所以三处拿的都是这个默认值。

> ★ **一处对我自己的更正,写出来免得下一个人重犯:** 我先读了类型块
> `className?: string` 并据此写下「它没有默认值,渲染出来是一颗裸 `<select>`」。
> **默认值在类型块上面三行**,在解构里。那条错误的读数还让我量了一组错的「改前」
> (19px)。**真的改前是 37px** —— 而 37 与 FONT-2 在真实路由上量到的 **38px**
> 对得上,**那反过来确认了「队列说的那一颗」就是这一颗**。

**实测(两个视口逐字相同):**

| 字段 | 改前 | ★ 改后 |
|---|--:|--:|
| 高度 | **37px** | ★ **32px**(−5) |
| ★ **宽度** | **320px** | ★ **320px(逐字未变)** —— `w-full` 两边都在 |
| 圆角 | 4px | **8px** |
| 左内边距 | 12px | **10px** |
| 边框 | 1px `border-gray-300` | 1px `border-input` |

☞ **改后三项(32px · 8px 圆角 · 10px 左内边距)与 `docs/variant-c-spec.md` §4.1 的
标准逐字相同。** 写法与同族的 `WasteClassPicker` 逐字相同 —— **它早就这么做了**,
所以这一步不是发明一种写法,是让两颗孪生的 picker 回到同一种。

⚠ **`control-style.ts` 一个字节都没有碰**(停止条件 (d))—— 只是 import 了它。

### 6.2 ★★★ `<EditableTable>` 手机档那颗钮:**停住,并报出差值**

委托书 §3:「**如果共享组件复刻不出当前几何,停下来把差值报出来,不要接受它。**」
**这一颗正是那一格,而且是三条路都不行。**

**它今天是什么:** `base-pressable min-h-11 rounded border … px-3 py-1.5 text-sm text-blue-600`
—— `min-h-11` = **44px**,而内容只有 20+12+2 = 34px,**所以 44 这个数是
`min-height` 给的,不是内容给的**(这正是 BTN-SIZE-1 §8.1 要我先问的那一问)。

★ **档位表是 `h-6`/`h-7`/`h-8`/`h-9`/`h-12` = 24 / 28 / 32 / 36 / 48。没有 44。**

**实测(在一个复刻的手机展开格里,两个视口逐字相同):**

| 走哪一档 | 钮高 | ★ 格高 / 行高 | 差 | 代价 |
|---|--:|--:|--:|---|
| **今天** | **44** | **92.5** | — | — |
| `secondary` + `touch`(h-12) | 48 | ★ **96.5** | ★ **+4.0** | 还搭着**字号 14 → 16px** |
| `secondary` + `default`(h-8) | 32 | **80.5** | **−12.0** | ★ **掉到 44px 触控靶以下**(WCAG 2.5.5 / Apple HIG) |
| `secondary` + `lg`(h-9) | 36 | **84.5** | **−8.0** | 同上 |

☞ **三条路全部改变 `<EditableTable>` 的行高,而它在 4 条路由上**
(`/me` · `/hr/kpi/score` · `/hr/leave/types` · `/hr/reviews/scale`)。
**那是停止条件 (c)。**

★★ **而且在册的量具【看不见这一格】,这一条要说清楚:**
那颗钮住在 `editable-table.tsx` 的 `{isOpen && hasPhonePanel && (…)}` 里 ——
**手机展开区,点开才渲染**。而 `--mode=drift` **只量首屏**。
☞ **一个绿的 (c) 不覆盖这一格。** 委托书为 `/finance/freight/new` 写过同一句话
(「不要让一个绿的退出码盖住一格从来没有被读过的数」),这里是同一个形状。

**这一条与 `POLISH1R3-DATATABLE-PAGER-NO-STEP` 是同一个形状**:分页那一对
也是「档位里没有这个数」。★ 而那一条**是等到 Tim 裁定(「取现成的 32px 档,
接受那 +2px」)之后才由 BTN-SIZE-1 落地的**。
☞ **这里没有对应的裁定,所以这里不落地。** 登记在 §9,等一句话。

> ⚠ **顺带查实的一件事,免得下一刀踩空:** 改这颗钮**不会**弄瞎
> `survey-controls --mode=edit`。它的候选判据 **FONT-1 已经从「className 含
> `text-blue-600`」换成「文字等于 `labels.edit`」**(`scripts/survey-controls.mjs:450` 起)。
> ★ **但那个文件抬头 §EDIT 的散文(第 70–74 行)【还写着旧判据】** ——
> 一条已经不成立的话,读起来和一条成立的话一模一样。**本刀不动量具,登记在 §9。**

---

## 7 · 停止条件,逐条 —— 而 (c) 【踩到了】,处置写在这里

### 7.1 ★★★ (c) 踩了,按 §3 的处置:转过去 → 量了 → 按回来 → 报出差值

★ **`check-stop-rules-abc.mjs` 报 (a)(b)(c) 全绿,而 (c) 【没有踩】这句话当时是【半句】。**
读它自己的 AIM:它读的是 `docShow/docClientW` 与每张表的
`overflowsShell / shellScrollW / shellW / tableW` —— ★ **那是 (c) 的【横滚】那一半。**
委托书 (c) 的另一半是「**或者 ANY row height changes**」,**那一半它不读。**

☞ 所以本刀另写了一支行高比对器(逐表比 `headH` / `rowH` / `nBodyRows` / 宽度 / 滚动范围,
表的身份取**表头签名**而不是序号 —— 序号会因为页面多一张表而整体错位)。
★ **它自己先做了两格注入**:同一份读数自比 → **204 张表比过 · 0 处差异 · EXIT 0**;
把一张表的 `rowH` 改一个值 → **EXIT 1**,点名路由、表签名、字段、以及
「**rowFirstCell 没变 ⇒ 这是真的几何变化,不是数据换了一行**」。

**第一次读数(32 处全转)—— 它红了,点名三张表:**

| 路由 | 视口 | 表 | 字段 | 改前 → 改后 |
|---|---|---|---|---|
| `/sales/customers` | desktop | `Code↕/Legal Name↕/…/Status` | `rowH`(3 行) | **42.92 / 42.42 / 42.42 → 43.92 / 43.42 / 43.42(+1.00 逐行)** |
| `/suppliers` | desktop | `Code↕/…/Created▼/Actions` | `rowH`(8 行) | **+1.00,八行全中** |
| `/finance/close` | desktop | `Period end/…/Status` | `rowH` | **52.92 → 53.50(+0.58)** |
| `/finance/close` | phone | 同上 | `shellScrollW` | 343 → **336**(★ **滚动范围【变小】,不是长大 —— (c) 判的是"长大"**) |

★★ **第三张是这一格最值钱的发现:`ReopenForm` 【渲染在一张表的格子里】** ——
`CloseHistoryTable.tsx:75` 逐行渲染它,而**从调用点那一侧完全看不出这件事**。
☞ 「它在一个 flex 行里,不在表里」这个判断,在读了它的**消费者**之后才是真的。

**处置(委托书 §3 逐字):「停下来把差值报出来,不要接受它。」**
☞ 三处**按回原样**,并在每一处写下它的差值与代价;**其余 29 处保留。**
☞ 按回去之后重跑:★ **`STOPRULE_ABC_OWN_EXIT=0` 且 `ROWHEIGHT_OWN_EXIT=0`
(204 张表 · 0 处字段差异 · 0 个瞎掉的路由格)。**

★ **为什么这三处是"库复刻不出它今天的几何",而不是"我挑了个不好的档":**
它们各自的高度今天由**一个档位表里没有的数**给:两处文字链是 **20px**(零边框的行盒),
`ReopenForm` 是 **30px**(20px 行盒 + `py-1` + 2×1px 边框)。
档位是 24 / 28 / 32 / 36 / 48 与 `inline`(`h-auto` + 基础串那 1px 边框 ⇒ 22px)。
**20 与 30 都不在里面。**

### 7.2 为什么另外 29 处没有推动任何一行

★ **不是运气,是量出来的:那些格子里【已经】坐着一颗库按钮,而它比转过来的这颗高或一样高。**

| 已经在那一格里的 | 实测高 | 于是 |
|---|--:|---|
| `<Button asChild variant="link" size="inline">`(`DepartmentsTable` · `TemplatesTable` 的动作格) | **22px** | 转过来的也是 22px ⇒ 那一格的内容高**本来就是 22** |
| `<Button variant="secondary" size="xs">`(`DictSection` 的"重新启用"那一支 · `ServiceIntervalPanel` 的"编辑") | **24px** | 转过来的 `xs` 也是 24px |
| `<Button variant="secondary">`(`StatusPanel` 的非破坏跳转 · `CloseReopenControls` 的取消 · `TaskHeader` 的取消) | **32px** | 转过来的 default 也是 32px;`TaskHeader` 取 `inline`(22px)**更矮**,那一行仍由 32px 的邻居定高 |

### 7.3 其余各条

| 条 | 判据 | 读数 | 判词 |
|---|---|---|---|
| **(a)** | 390px 上 0 溢出的路由升到 0 以上 | 282 组比过 · 184 张表 · 650 次字段比较 | ✓ `STOPRULE_ABC_OWN_EXIT=0` |
| **(b)** | 5 条本来就在溢出的长大 | **5 条两侧都量到了,而且是【逐条断言过的】,不是打印过的**(脚本自己这么说) | ✓ 见下 |
| **(c)** | 横滚 / 行高 | 见 §7.1 | ✓(按回三处之后) |
| **(d)** | S2 封存输出未变 | `git diff --name-only` 里 `control-style.ts` · `input.tsx` · `textarea.tsx` · `globals.css` · `table-style.ts` **一个都没有**(逐个核过,不是假设) | ✓ |
| **(e)** | `/brand-sampler` | 见 §7.5 | ✓ |
| **(f)** | 顶栏自己的盒子 | 见 §7.6 | ✓ |

### 7.4 ★ (b) —— **5 of 5,不是 4 of 5**,而这一句是买来的

`/finance/freight/new` **第四次**在 `next dev` 下把渲染器卡死
(`CDP timeout: Runtime.evaluate (ready=null)`)。★ 委托书点名要求:
「如果它又卡了,再逐点读一遍并合并,**并且明说 (b) 是 5 of 5 还是 4 of 5** ——
不要让一个绿的退出码盖住一格从来没有被读过的数。」

☞ 照办:改前改后**各单独跑了一次** `--only=/finance/freight/new`(两次都 `DRIFT_EXIT=0`),
把那一格并回各自那份读数。**★ 于是 (b) 是 5 of 5。**

| 路由(phone) | 改前溢出 | 改后溢出 | 委托书写的 |
|---|--:|--:|--:|
| `/finance/freight/new` | ★ **27**(417/390) | **27** | 27 ✓ |
| `/operation/processing/new` | **177** | 177 | 177 ✓ |
| `/purchasing/payment-terms/new` | **143** | 143 | 143 ✓ |
| `/sales/orders/new` | **8** | 8 | 8 ✓ |
| `/tools/pricing/metal-prices/bulk` | **24** | 24 | 24 ✓ |

★ **五个数全部复算成功,一条都没有长大。** `/sales/orders/new` 是已知不可修的那条,**本刀没有碰它**。
⚠ **而那次卡死每一刀都要多付一次跑** —— 这件事本身该有人管,不是本刀的范围。

### 7.5 ★★ (e) —— 856…860 那一个成员,**是量出来的,不是放过去的**

委托书:「⚠ **取样页会展示按钮变体**,所以有些成员可能是合法地变了。
**说出哪些动了、为什么;不要放过去,也不要把一次真的回归当成预期。**」

**逐成员比(不是比总数 —— STYLE-1 的 `pick-a` 致盲证过总数比对器会说"没变化"):**

| | 改前 | 改后 | 成员级差异 |
|---|--:|--:|---|
| desktop | **860 / 903** | **860 / 903** | ★ **多 0 · 少 0** |
| phone | **860 / 903** | **859 / 902** | ★ **多 0 · 少 1** |

少掉的那一个是:
`img | absolute inset-0 h-full w-full object-cover transition-opacity duration-150 opacity-0 | 30x30`
—— ★ **顶栏 `AvatarMenu` 那张头像图**(顶栏那一堆 43 → 42)。

★★ **它【不是】本刀造成的,而这句话是证出来的,不是推出来的:**

1. **先推了一遍,而那次推理不够**:「我一个 nav 文件都没碰」「它只在 phone 上少、desktop 上还在,
   而我的改动与视口无关」—— ☞ **两条都成立,而它们证不了因果。**
2. ★ **所以把改动整个 `git stash` 掉,在【干净的 HEAD】上重建并重跑了四次:**

| 树 | phone 成员数 |
|---|---|
| ★ **干净 HEAD(e147d5b)** | **860 · 860 · ★ 859 · 860** |
| 本刀(29 处) | 859 · 859 · 859 |

☞ ★★★ **干净树第 3 跑自己就是 859。** 那个成员是 `AvatarImage`(UI-1d)在挂载时自查
「图取不到就把 `<img>` 摘掉」的结果 —— **它在不在 DOM 里,取决于那次取图有没有赶在普查之前落定**,
而探针每一跑都新建一个一次性账号。**一场赛跑,在两棵树上都跑得出两种结果。**

> ### ☞ 顺带一条给下一刀的,登记在 §9
> ★ **`probe-brand-sampler` 的 phone 成员数【±1 不稳】。** 拿它当逐字相等的判据,
> 会报出一次假的回归。☞ 与 INPUT-2b 那条「一份基线文档是一张快照,不是一道闸」同形:
> **一个 ±1 不稳的量,停的是运气,不是回归。**

★ **而【按钮变体】那一侧:一个成员都没动,两个视口都是 0/0。**
原因说得清:取样页自己渲染的是 `<Button>`,而**本刀一个库文件都没碰** ——
改的全是调用点,而那些调用点一个都不在 `/brand-sampler` 上。

### 7.6 (f) —— 顶栏自己的盒子,**逐字未变**

`diff` 改前改后那两份 `header=` / `trigger=` 读数:**IDENTICAL,一个字节都没差。**

| | 委托书写的 | 实测(改前 = 改后) |
|---|---|---|
| 1280 顶栏盒子 | 1280x53 | **1280x53** ✓ |
| 390 顶栏盒子 | 390x55 | **390x55** ✓ |
| 搜索那一格 | 200x32 | **200x32** ✓ |
| 首页入口 @390 | 358x49.02 | **358x49.02** ✓ |
| 首页入口 @1280 | 544x53.63 | **544x53.63** ✓ |

★ **五个数全部复算成功。** `NAV_AFTER_OWN_EXIT=0`。

---

## 8 · X1 / X2 / X3 —— 开会之前逐条走一遍(§6 要的那一步)

> POLISH-1 round 2 在裁定里点了十六件、在清单里写了九件,**差的七件悄悄没做**。
> 所以这里**一条一条**对着**实际改了的东西**走,每条给 DONE / NOT DONE + 证据。

| | 它要什么 | 判词 | 证据 |
|---|---|---|---|
| **X1** | 把裸触发钮路由到共享 `<Button>`,**每一处各自判档**,报出判据 | ★ **DONE(判档 33 / 33;落地 29 / 33)** | 逐条判读见 §4 与 §4.3 附表;`triggerVariant` 计数 **25 → 54**,裸 `<button>` **33 → 4** |
| **X1 余** | 那 4 处 | ★ **NOT DONE —— 1 处故意,3 处量了按回来** | `SafetyStatePanel.tsx:89`(§4.1)+ §7.1 那三处;两者登记见 §9 |
| **X2** | 26 处禁用态缺陷,**与 X1 同一遍修掉** | ★ **DONE(29 / 33),而总体是 33 不是 26** | 66 个读数改前全红 → ★ 改后 **58 绿 / 8 红**;三种写法逐条见 §5 |
| **X2 余** | 那 4 处 | ★ **NOT DONE** | 同上;四处的实测比值逐个写在 §4.1 与 §7.1,**照直登记** |
| **X3a** | 那颗没采用共享样式的 `<select>` | ★ **DONE** | `IndexPicker.tsx` 解构默认值 → `${CONTROL_SELECT} w-full`;37→32px,**宽度不变** |
| **X3b** | `<EditableTable>` 手机档那颗蓝钮 | ★ **NOT DONE —— 停住并报出差值,这是 §3 自己要的处置** | 44px 无对应档位;三条路全部改行高(+4 / −12 / −8);登记 `BTNTRIGGER1-EDITABLETABLE-NO-44-STEP` |
| **★ 不在范围** | 7 个 `tier="reversal"` 的对话框 | ★ **一个字节都没碰** | `git diff` 里 `tier=` 出现 **0 次**;7 处触发钮全部取 `reversal`,与对话框一致 ⇒ **没有产生分歧,停止条件未触发** |

---

## 9 · 本刀登记了什么(不是藏起来,是写下来)

1. ★★★ **`BTNTRIGGER1-EDITABLETABLE-NO-44-STEP`** —— 44px 没有档位,三条路都改行高,
   而**在册的量具看不见那一格**。要 Tim 一句话。
2. ★★ **`BTN-TRIGGER-1` 名下剩的 3 件**(裸分支仍在 · `SafetyStatePanel` 那 1 处 ·
   三处档位没裁)—— 本条**改写成"做了什么/还剩什么",不整条删**,因为它的
   删除条件两半都没满足。
3. ★ **`BTNTRIGGER1-SURVEY-EDIT-PROSE-STALE`** —— `survey-controls.mjs:70–74` 的散文
   写着一条 FONT-1 早就换掉的判据。**不改量具,登记。**
4. ★★ **`probe-brand-sampler` 的 phone 成员数【±1 不稳】。** 实测:**干净的 HEAD 上四跑
   得到 860 · 860 · 859 · 860**。不稳的那一个是顶栏头像图(`AvatarImage` 挂载自查
   在取图落定之前/之后摘不摘 `<img>`),而探针每跑新建一个一次性账号。
   ☞ **拿它当逐字相等的判据会报出一次假的回归** —— 与 INPUT-2b 那条
   「一份基线文档是一张快照,不是一道闸」同形。**下一刀要么多跑两次取众数,
   要么把那个成员从签名里排除并写明理由。**
5. ★★ **三处【转过去了、量了、按回来了】** —— 登记在 `BTN-TRIGGER-1` 名下的 ④,
   带着各自的行高差值与对比度读数,等一句「接受这 +1.00 / +1.00 / +0.58px」。
6. ★★ **`check-component-library` 对这一族债【按构造】是瞎的。** 它数的是
   `app/` 里不含组件库的手写 `<button`;这 33 颗是 `confirm-dialog.tsx` 渲染的,
   调用点写的是 `<ConfirmButton`,而棘轮**没有这一维**。
   ☞ **委托书「这一刀应当大幅缩短它」是不可能的,而这句话要写在能被读到的地方。**
   **下一刀若要给它加这一维:判据是 `<ConfirmButton` 且【没有】`triggerVariant`**,
   而那需要本报告 §3 那种逐字符的开标签扫描,不是一条正则。

---

## 10 · 下一刀开工前要知道的

1. ★★★ **`BTN-TRIGGER-1` 的「42」与「26」都是从上一份报告抄下来的,两个都错。**
   这已经是 AGENTS.md 那一条(「委托书里的数来自上一份报告」)第 N 次命中,
   而这一次**更正就写在同一个文件里、日期更早** —— 委托书抄的是被更正掉的那一版。
   ☞ **开工前把每一个数当场量一遍,包括那些"看起来没问题"的。**
2. ★★ **一支读 `className` 属性文本的扫描器,对 `className={someConst}` 按构造是瞎的。**
   本刀的 26→28 就是这么多出来的,**而我自己第一版也瞎**。
   加一层:回溯到同文件的 `const X =`。
3. ★★ **`getComputedStyle().color` 不含元素自己的 `opacity`。** BTN-1 §10.5 记过,
   本刀第三次复述:量褪色的字要把**从元素到 `<html>` 的每一层 `opacity` 连乘**,
   再按组透明度把**字与底各合成一次**。
4. ★ **颜色解析不要写正则。** Tailwind v4 发 `oklch()`,`getComputedStyle` 会还回
   `oklab()` / `color(srgb …)`。**让引擎栅格化一个像素再读回字节**,它对每一种记法都成立。
5. ★ **`docs/` 不在 Tailwind 的扫描源里**(`app/globals.css` 只 `@source "../app"` 与
   `"../lib"`)—— 这是 BUGFIX-1a 那条「文档里的散文被扫进生产 CSS」的处置,**今天仍然成立,量过了**。
   ☞ 于是**写交回报告不会改变渲染**,可以在量具跑着的时候写。
6. ★ **`/finance/freight/new` 第四次在 `next dev` 下把渲染器卡死。**
   处置照委托书:`--only=/finance/freight/new` 单独再读一遍、把那一格并回去。
   本刀两遍都并成功了,**所以 (b) 是 5 of 5,不是 4 of 5**。
   ⚠ 但它**每一刀都要付这一次额外的跑**,而这件事本身该有人管。

---

## 11 · 每一条命令,以及**它自己打出来的那一行退出码**

★ 照 AGENTS.md 那一条:**报的是脚本自己写下的那一行,不是启动它的东西的。**

| 命令 | 它自己那一行 |
|---|---|
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build`(改前基线) | `BUILD_BEFORE_OWN_EXIT=0` · `BUILD_ID=JgDxCv0N3k8C-UGNfVTJ7` |
| `npm run build`(改后) | `BUILD_AFTER_OWN_EXIT=0` · `BUILD_ID=ab4YeXyJ77AHfKzLrOtyW` |
| `python3 db/gate.py` | ★ `GATE_OWN_EXIT=0` —— 四个判词全绿(可重建性 · 镜像vs线上 · 行为断言 · 匿名面),wall-clock 274s |
| `node scripts/smoke-routes.mjs` | `SMOKE_OWN_EXIT=0` |
| `node scripts/check-component-library.mjs` | `COMPLIB_AFTER_OWN_EXIT=0` |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `node scripts/probe-search-results.mjs` | `SEARCH_AFTER_OWN_EXIT=0` |
| `node scripts/probe-nav-geometry.mjs` | `NAV_AFTER_OWN_EXIT=0` |
| `node scripts/probe-brand-sampler.mjs` | `SAMPLER_AFTER_OWN_EXIT=0` |
| `node scripts/check-stop-rules-abc.mjs` | ★ `STOPRULE_ABC_OWN_EXIT=0` |
| **行高比对器**(本刀的一次性量具) | ★ `ROWHEIGHT_OWN_EXIT=0` —— 204 张表 · 0 处差异 |
| `survey-controls --mode=drift`(改前 / 改后) | `DRIFT_EXIT=0` · `DRIFT_EXIT=0` |
| `--only=/finance/freight/new`(改前 / 改后) | `FREIGHT_BEFORE_DRIFT_EXIT=0` · `FREIGHT_AFTER2_DRIFT_EXIT=0` |

★ **每一支跑在生产构建上的探针都印了它读到的 `.next/BUILD_ID`** —— SEARCH-1 §6 那次
「`git stash pop` 之后没重建,于是对着旧构建量出一个干净的零」就是这么发生的。

### 11.1 ★ 组件库棘轮:**四维逐字未变,而那【不是】没做事**

| 维度 | 改前 | 改后 |
|---|---|---|
| 手搓 `<table>` | 35 文件 / **39** 处 | 35 / **39** |
| 手写 `<button>` | 10 文件 / **17** 处 | 10 / **17** |
| 按钮态 `<Link>`/`<a>` | 11 文件 / **15** 处 | 11 / **15** |
| 格子钉死的字号 | 91 文件 / **309** 处 | 91 / **309** |

★★ **委托书写着「这一刀应当大幅缩短它」,而那是【按构造】不可能的** —— 理由见 §0.4。
☞ **这一行不是"没缩短",是"这道闸看不见这笔债"。** 而那本身是一个发现,
登记在 §9.4,连同给下一刀的判据。

### 11.2 破窗 —— **这一刀没有开窗,而这句话有证据**

★ `git diff --stat -- db/` **0 行**(量过的,不是想不起来改过什么)。一条迁移都没有。
☞ 不存在「旧代码 + 新库」那个窗口。**这一行不是空着,是量过之后为零。**

---

## 12 · 提交(按回滚爆炸半径切,不按大小切)

| # | 内容 | 为什么单独一笔 |
|---|---|---|
| **A** | X1 + X2 —— 31 个调用点文件(29 处转换 + 3 处按回原样时写下的注释 + `StatusPanel` 那段死代码) | 回滚它 = 回到 33 处裸触发钮。**它碰不到任何共享组件。** |
| **B** | X3a —— `IndexPicker.tsx` | ★ 它是**三条录入路线共用的一个 picker**,回滚按钮那一批**不该**把它带走 —— 委托书 §6 点名的正是这个形状 |
| **C** | 文档 —— 交回报告 · `known-issues` · `base-components` | 回滚文档不该动代码,回滚代码不该丢掉这份读数 |

★ **`<EditableTable>` 一个字节都没碰**(X3b 停住了),所以委托书担心的那条
「回滚按钮的活会把共享组件带走」**在这一刀里没有主语** —— 照直说,不假装避开了它。
