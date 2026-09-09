# TABLE-STYLE-1 —— 交回报告(**一份共享样式,穿在 22 张【转不动】的表上**)

> **这一刀的一句话:** Tim 打开 `/finance/trial-balance` 问「为什么还是不一样」。
> 量出来的答案是:**那一页渲染的是变体 A(全边框、灰表头、无 Hawaiian Ocean 线),
> 不是 Tim 指的变体 C** —— 而它之所以是 A,与"它转不成组件"**没有任何关系**。
> 本刀把 variant C 的表格外观量成一份**共享定义**,穿在 22 张留在手搓的表上。
> **实测:量得到的 13 张表,四项全部落在标准值上,一张不差。**

---

## 1 · HEAD、树、与 `ba360c9` 的差别

| | |
|---|---|
| 分支 | `main` |
| **开工前 HEAD** | `ba360c963acd144e0593f6928abdb03369eafbc3` |
| 开工前 `origin/main` | `ba360c963acd144e0593f6928abdb03369eafbc3` —— **相等** |
| 开工前 `git status --porcelain` | **零行(树干净)** |
| **与 `ba360c9` 的差别** | **零。HEAD 就是 `ba360c9` 本身**,不是它之后的文档跟进提交。 |
| **收工后 HEAD** | `__HEAD_AFTER__` |
| 收工后树 | `__TREE_AFTER__` |

☞ 委托书 §0 的判据(树干净 · HEAD == origin/main · 差别只是文档提交)**三条全部成立,而第三条是"零差别"**:PROCEED。

---

## 2 · 共享定义:住哪、什么形状、为什么、怎么检查

### 2.1 它住在 `app/components/ui/table-style.ts`,导出一个 `tableC`

```ts
export const tableC = {
    root:     'border-collapse text-sm',                            // 行高的来源,见 2.4
    headRow:  'border-b-2 border-[color:var(--brand-ocean)]',       // 2px Hawaiian Ocean
    headCell: 'px-3 py-2.5 align-middle text-[15px] font-medium',   // 10/12 · 15px · 500
    cell:     'px-3 py-2.5 align-middle text-[15px]',               // 10/12 · 15px · 400
    bodyRow:  'border-b border-[color:var(--brand-border)]',        // 1px 行分隔线
} as const
```

每一个值都指向 `docs/variant-c-spec.md` §4.3 的一行(**实测值,不是重新推的**)。

### 2.2 为什么是【TS 里的 class 常量】,不是 `globals.css` 里的一个 `.table-c`

**因为本仓库刚刚为 CSS 那条路付过账,而账是量出来的:**
`variant-c-spec.md` §7.1 实测到 `table.tsx` 的 `[&_tr]:border-b`(后代选择器,特指度 0,1,1)
**压过**行自己的 `border-b-2`(0,1,0)—— 于是 C 的表头线在取样页上渲染成 **1px**,
而文档里写的是 2px:**一个从来没有在屏幕上出现过的数。**
☞ `.table-c th { … }` 会把那个特指度陷阱**原样复刻一遍**。
class 常量没有这个问题:它就是元素自己身上的类,**和组件今天的做法是同一种**。

### 2.3 ★ 组件能不能消费它 —— **能,而且差别只有一个 token**

| tableC | data-table.tsx 今天写死的 | 差别 |
|---|---|---|
| `headRow` | `:391` `border-b-2 border-[color:var(--brand-ocean)]` | **逐字节相同** |
| `headCell` | `:442` `px-3 py-2.5 align-middle text-[15px] font-medium …` | **相同**(组件另有字色与 `sm:whitespace-nowrap`) |
| `bodyRow` | `:497` `border-b border-[color:var(--brand-border)]` | **逐字节相同** |
| `root` | `:386` `border-collapse … text-sm …` | **相同**(组件另有 `table-fixed sm:table-auto`,那是它的手机机制,不是 C 的规格) |
| `cell` | `:526` `px-3 py-2.5 align-middle …` | ⚠ **差一个 `text-[15px]`** |

☞ **那一个 token 就是组件今天离标准的全部距离:组件的表体渲染 14px,标准要 15px。**
`variant-c-spec.md` §4.3 自己也记着这一条(「`<td>` 仍然是 14px —— STYLE-2 只动了表头」)。
**本刀没有改它**(委托书 R5:不许碰 `data-table.tsx` 的渲染路径)。
把 `:526` 的 `px-3 py-2.5 align-middle` 换成 `tableC.cell`,这一条就合上了 —— **那是一行改动,不是一刀。**

**实测对照(同一次跑,同一个视口):**

| | 表头线 | th | td |
|---|---|---|---|
| `/finance/journal`(DataTable) | **2px #008EBC** | 15px / 500 / 21.4286 / 10-12 | **14px** / 20px / 10-12 |
| `/finance/trial-balance`(本刀,手搓) | **2px #008EBC** | 15px / 500 / 21.4286 / 10-12 | **15px** / 21.4286 / 10-12 |

### 2.4 ★★ 一处【本刀自己写错、被探针抓回来】的事 —— 照直记 ★★

第一版把 `tableC.root` 写成 `text-[15px]`,理由是抄了 STYLE-2 的一句结论
(「Tailwind v4 的任意值字号会把 line-height 一并重置」)。**实测下来是反的:**

* `text-[15px]` 这类**任意值字号只设 `font-size`,不设 `line-height`**。
* 于是行高退回继承来的 **1.5 倍 → 22.5px**,而标准是 **21.43px**。
  **22 张表【全部】渲染成 22.5px,差 1.07px。**
* 已上线的组件之所以是对的,靠的正是这一条:它的表根写 `text-sm`,
  而 Tailwind v4 的 `text-sm` 带的是一个**无单位**的 line-height(1.25/0.875 = 1.42857);
  **无单位行高按倍数往下继承**,于是 `<th>` 上的 `text-[15px]` 得到 15 × 1.42857 = **21.4286px**。

☞ 改法:**字号住在【格子】上,行高的来源住在【表根】上。** 改完之后 26 次读数全部 21.4286px。
☞ **这一条只有真浏览器量得出来。** 读 class 串会读到 `text-[15px]`,然后写下一个
从来没在屏幕上出现过的 21.43 —— **和 §7.1 那个 2px 是同一种错,只是这次轮到我。**

### 2.5 它怎么检查 —— **两件仪器,都跑过负向对照**

1. **`scripts/check-component-library.mjs` 的新维度 `cellfont`**(见 §7),只减不增,进 `npm run build`。
2. **一支断言器**(住 scratchpad,不进仓库):对 22 张表的块 + 3 处块外行辅助件逐段断言
   「没有 `border-gray-*` · 没有钉字号 · thead 没有底色 · 有对应标签就必须用上对应的 `tableC` 那一段」。
   **25 段全绿;手工塞回一处 `border-gray-300`,它当场点名 `pnl/page.tsx:105`。**

---

## 3 · 逐表:改了什么、剥了几处字号、前后读数对标准

### 3.1 剥了什么(逐表,从改写器自己的日志里读回)

| 类 | 表 | 改写标签 | **剥掉钉字号** | 剥掉格子边框 |
|---|---|--:|--:|--:|
| A | `finance/freight/new/NewFreightForm.tsx:239` | 14 | **3** | 2 |
| A | `finance/invoices/[id]/CreateCreditNoteControl.tsx:117` | 18 | **3** | 15 |
| A | `finance/invoices/new/NewInvoiceForm.tsx:281` | 16 | **5** | 13 |
| A | `finance/payments/new/NewPaymentForm.tsx:514` | 14 | **3** | 11 |
| A | `finance/payments/new/NewPaymentForm.tsx:585` | 12 | **2** | 9 |
| A | `inbound/[id]/assays/new/AssayForm.tsx:243` | 8 | **0** | 5 |
| A | `output/[id]/assays/new/OutputAssayForm.tsx:177` | 10 | **1** | 7 |
| A | `purchasing/orders/[id]/amend/AmendOrderForm.tsx:151` | 16 | **1** | 13 |
| A | `sales/orders/[id]/amend/AmendOrderForm.tsx:156` | 20 | **4** | 17 |
| A | `sales/orders/[id]/amend/AmendOrderForm.tsx:302` | 10 | **1** | 7 |
| A | `sales/quotes/new/NewQuoteForm.tsx:127` | 10 | **1** | 7 |
| A | `tools/pricing/calculator/CalculatorForm.tsx:157` | 8 | **0** | 5 |
| A | `tools/pricing/formulas/FormulaForm.tsx:354` | 8 | **0** | 5 |
| A | `tools/pricing/metal-prices/bulk/BulkPricesForm.tsx:105` | 10 | **1** | 7 |
| E | `finance/balance-sheet/page.tsx:177` | 12 | **2** | 8 |
| E | `finance/cashflow/page.tsx:146` | 1 | **0** | 1 |
| E | `finance/payables/page.tsx:172` | 30 | **10** | 25 |
| E | `finance/pnl/page.tsx:161` | 12 | **2** | 8 |
| E | `finance/receivables/page.tsx:168` | 35 | **13** | 30 |
| E | `finance/trial-balance/page.tsx:147` | 26 | **7** | 20 |
| F | `finance/cash-forecast/ForecastGrid.tsx:168` | 8 | **1** | 5 |
| F | `finance/cost-variance/page.tsx:34` | 8 | **1** | 5 |
| | **22 张小计** | 306 | **61** | 225 |
| ＋ | `balance-sheet` 的 `sectionBlock`(块外) | 13 | **5** | 9 |
| ＋ | `cashflow` 的 `<Row>`(块外) | 3 | **2** | 2 |
| ＋ | `pnl` 的 `sectionBlock`(块外) | 9 | **3** | 6 |
| | **合计** | **331** | **71** | **242** |

★ 那 22 张的 **61 处,与 TABLE-CONVERT-0 §4 逐表列的「钉字号」一栏【逐格相同】**
(3·3·5·3·2·0·1·1·4·1·1·0·0·1 ＝ 25 · 2·0·10·2·13·7 ＝ 34 · 1·1 ＝ 2)。
**两支互不共用代码的量具,数出同一个数。**

### 3.2 ★ 三处【行渲染住在 `<table>` 块外面】—— 普查数不到,而不补上表会一半旧一半新 ★

`balance-sheet` / `pnl` / `cashflow` 的行不是写在 `<table>` 里的,而是住在
`sectionBlock()` / `<Row>` 这样的辅助件里。**普查按 `<table>` 块统计,于是它们的格子一个都没被数进去。**

☞ **这是本刀量出来的,不是读出来的:** 第一次改完之后探针报
`/finance/balance-sheet` 的 **55 个 `<td>` 里只有 4 个到位**,51 个还是 `8px/16px` + 1px 边框。
于是补了一支断言器,直接数「块外的 `<tr>/<td>/<th>`」——**三个文件、25 处,一个不漏。**
☞ 它也解释了本刀的 `cellfont` 量到 196 而普查记 186 的差额(**普查漏的正是这些**)。

### 3.3 前后读数对标准(desktop;**除标注外手机档逐字节相同**)

标准(`variant-c-spec.md` §4.3):表头线 **2px `#008EBC`** · th **15px / 500 / 21.4286 / 10-12**
· td **15px / 21.4286 / 10-12** · **格子无竖边框**。

| 表 | 表头线 | th 字号 | th 字重 | td 字号 | td 内边距 | td 竖边框 |
|---|---|---|---|---|---|---|
| A 运费分摊 | 0px→**2px** | 16→**15** | 700→**500** | 14/16→**15** | 8/12→**10/12** | 0→**0** |
| A 新建报价 | 0px→**2px** | 14→**15** | 700→**500** | 14→**15** | 8/8→**10/12** | 1→**0** |
| A 计价器 | 0px→**2px** | 16→**15** | 700→**500** | 16→**15** | 8/16→**10/12** | 1→**0** |
| A 计价公式 | 0px→**2px** | 16→**15** | 700→**500** | 16→**15** | 8/16→**10/12** | 1→**0** |
| A 批量金属价 | 0px→**2px** | 16→**15** | 700→**500** | 14/16→**15** | 8/16→**10/12** | 1→**0** |
| E 资产负债表 | 0px→**2px** | 16→**15** | 700→**500** | 14/16→**15** | 8/16→**10/12** | 1→**0** |
| E 现金流量表 | 无表头→无表头 | —(无 th) | — | 14→**15** | 8/12→**10/12** | 1→**0** |
| E 应付账龄 | 0px→**2px** | 16→**15** | 700→**500** | 12/14/16→**15** | 8/16·8/8→**10/12** | 1→**0** |
| E 损益表 | 0px→**2px** | 16→**15** | 700→**500** | 14/16→**15** | 8/16→**10/12** | 1→**0** |
| E 应收账龄 | 0px→**2px** | 16→**15** | 700→**500** | 12/14/16→**15** | 8/16·8/8→**10/12** | 1→**0** |
| **E 试算平衡表** ★ | 0px→**2px** | 16→**15** | 700→**500** | 12/14/16→**15** | 8/16·8/8→**10/12** | 1→**0** |
| F 现金预测·SGD | 0px→**2px** | 12→**15** | 700→**500** | 12→**15** | 4/8→**10/12** | 1→**0** |
| F 现金预测·USD | 0px→**2px** | 12→**15** | 700→**500** | 12→**15** | 4/8→**10/12** | 1→**0** |
| F 成本差异 | 0px→**2px** | 14→**15** | 700→**500** | 14→**15** | 8/12→**10/12** | 1→**0** |

**判合规(一支断言器逐项比,不是人眼):**
* **改之前:14 张 × 2 视口 = 28 次判定,【28 次全部不合格】,0 次合格。**
* **改之后:26 次合格,2 次不合格 —— 而那 2 次是同一张表的同一件事,见 §4。**

行高一并到位:th / td 全部 **21.4286px**(标准值),26 次读数无一例外。

---

## 4 · ★ 「穿上了却没渲染出来」的表 —— **一张都没有,而那 2 次 ✗ 是别的事**

委托书点名要查的那件事(STYLE-2 的教训:调用方的 className 会赢):
**本刀量到的 13 张表里,一张都没有发生。** 0 处「穿上了 `tableC` 却仍然渲染旧值」。

**那 2 次 ✗ 是 `/finance/cashflow` 表#0,原因是【它根本没有 `<thead>`】** ——
TABLE-CONVERT-0 §4.1 早就把它记成「枢轴/无头:no-thead,2 列(报表,不是账簿)」。
它的格子**四项全部合标准**(15px / 21.4286 / 10-12 / 无竖边框);
**没有表头线不是没画,是没有表头可画。** ☞ **这不是发现,是一次读得对的读数。**

### 4.1 ⚠ 但有一件必须说白:**22 张里只有 13 张【真的被渲染量过】**

| | 张数 | 为什么 |
|---|--:|---|
| **量到了**(desktop + 390px 各一遍) | **13** | 见 §3.3 那张表 |
| 量不到:路由带 `[id]` | **6** | `CreateCreditNoteControl` · `AssayForm` · `OutputAssayForm` · `purchasing AmendOrderForm` · `sales AmendOrderForm` ×2 —— `survey-variant-c.mjs` 的 AIM ④ 明写只走静态路由 |
| 量不到:静态路由,但**首屏没有这张表** | **3** | `NewInvoiceForm:281` · `NewPaymentForm:514` · `NewPaymentForm:585` —— 要先加一行明细表才出现,而探针只量首屏(AIM ②) |

☞ **那 9 张的依据是【源码层的断言】,不是像素:** 与量到的 13 张走的是**同一支改写器、同一份 `tableC`**,
`tsc --noEmit` 零错,断言器逐段判「没有 `border-gray-*` / 没有钉字号 / 用上了对应的 `tableC`」全绿。
**但那不是一次渲染 —— 照直说。**

---

## 5 · 390px 行高与横向溢出:**没有一张被本刀推进溢出**

**★ 委托书 §3.4 的闸:没有触发。**

| 路由 | docScrollW 前 → 后(clientW 390) | 判 |
|---|---|---|
| `/finance/freight/new` | **417 → 417** | **改之前就溢出 17px**,改之后**一个像素没变**——不是本刀造成的 |
| `/tools/pricing/metal-prices/bulk` | **437 → 407** | **改之前就溢出 47px**,改之后**少了 30px**——本刀把它**改小了**,没有改大 |
| 其余 15 条路由 | 390 → 390 | 不溢出 |

> ★ 那两处溢出**是开工前就在的**,本刀**没有去修**——修它要改列或改结构,
> 而这一刀只许改呈现。**登记在这里,不当作已解决。**

**行高(390px,每张表的体行高中位数):**

| 表 | 前 → 后 | 差 |
|---|---|---|
| `balance-sheet` | 65 → 63.84 | **−1.16**(变矮了) |
| `cash-forecast` SGD / USD | 25 → 42.42 | +17.42 |
| `cashflow` | 57 → 63.84 | +6.84 |
| `cost-variance` | 37 → 42.92 | +5.92 |
| `freight/new` ★ | 57 → 63.84 | +6.84 |
| `payables` ★ | 161 → 182.42 | +21.42 |
| `pnl` | 41 → 42.42 | +1.42 |
| `receivables` ★ | 181 → 218.42 | +37.42 |
| `trial-balance` ★ | 123 → 128.42 | +5.42 |
| `sales/quotes/new` | 47 → 52.42 | +5.42 |
| `calculator` / `formulas/new` | 59 → 60.42 | +1.42 |
| `metal-prices/bulk` | 117 → 128.11 | +11.11 |

★ = 带 TABLE-PHONE 列选判断的表。**行确实长高了**(字 12→15px、上下内边距 8→10px),
**但没有一张因此横向溢出**,而 §3.4 的闸问的正是这一件事。
最大的两处(`receivables` +37px、`payables` +21px)是**手机档的叠字格**:
那一格里叠着 7~5 个被拿掉的字段,字号一涨,整格跟着长——**它是纵向的,不是横向的。**

---

## 6 · R1:动作列在手机上【留】—— 三张表的**行为**变了

**这是一次行为改动,不是样式改动。**

| 表 | 动作 | 改了什么 |
|---|---|---|
| `suppliers/[id]/edit/CompliancePanel.tsx:110` | 删除钮 | 那一列去掉 `hidden sm:table-cell`;**叠在身份格里的那一份删掉** |
| `me/MyExpenseClaimsPanel.tsx:129` | 撤回钮 | 同上 |
| `sales/orders/[id]/amend/AmendOrderForm.tsx:156` | 移除列 | 同上 |

**为什么两边都要动:** 那一列一旦留在明面上,叠着的那一份就是**同一颗钮在同一行里画两遍**。
**实测:改完之后三处控件各只渲染 1 次**(`deleteControl(row)` / `withdrawControl(r)` / `{removeControl}` 各 1 处)。

**★ 提交路径一个字节没动 ——【查过,不是假设】:** `sales AmendOrderForm` 的移除复选框
**不带 `name`**,值由第一格里渲染一次的 `<input type="hidden" name="line_remove">` 携带。
全仓库 `name=` 属性数在改前改后**逐文件相等**。

**规矩写在两处 —— 下一个写表的人两条路都会撞上:**
* **`docs/base-components.md` §二十.1** —— 全文、判据、以及那次「两条在案判断打架」的经过。
* **`app/components/ui/data-table.tsx` 的 `Column.priority` 字段注释** —— 写表的人真正会看的地方。
  **只加注释,渲染路径一个字节没碰(R5)。**

**判据原文:**
> 一列如果画的是【要按的控件】(删除 / 撤回 / 移除 / 下载),它在手机上永远可见。
> 理由不是"这一列更值得读",而是**它不是一个要读的数,是一个要按的控件** ——
> 够不着的动作等于不存在(DBLOCK-1 用在版式上)。
> 「折」那三处当时写下的理由,讲的**全是读哪几列**,没有一条是关于那颗钮的。

**⚠ 三处【都没有渲染验证过】,照直说:** `CompliancePanel` 与 `sales AmendOrderForm` 在 `[id]` 路由上;
`/me` 是静态路由,但探针用的是一个**用完即删的新账号,它没有报销单**——`/me` 实测 `tables=0`。
依据是源码断言(各渲染 1 次)+ `tsc` 零错,**不是一次 390px 的截图**。

---

## 7 · R2:棘轮的第四维 `cellfont`

| | |
|---|---|
| **起始数** | **418 处 / 124 个文件** |
| 分账 | 标签上 **125** 处(`<table>`/`<th>`/`<td>`)· 列描述符里 **293** 处(`className: '…'`) |
| 本刀开工前(HEAD) | **489 处 / 140 个文件**(标签 196 + 列描述符 293) |
| **本刀还掉** | **71 处 / 16 个文件** |

★ **293 这个数,与 STYLE-2 从完全不同的一条路数出来的 293【相等】。**

**为什么两种拼法【合成一维】而不是两维:** 它们是同一件事的两种写法。
分成两维就等于允许「这边减、那边加」而闸仍然是绿的 —— 而这一族刀的题目
正是"同一个外观不许有两份定义"。收尾把两边的分账**分别印出来**,好让人读得到是哪一边在动。

**为什么它【只减不增】:** `data-table.tsx` 的 `cn()` 把 `c.className` 排在最后,
**调用方钉了字号,调用方赢**。不拦住它,一次机械的转换会把 140 处 `<td>` 字号原样搬进
`Column.className`,**转完仍然渲染 14px**,而 293 会涨到约 433 ——**债不是还了,是搬了个地方。**

**★ 两个方向都跑过:**
* 绿:`node scripts/check-component-library.mjs` **自己的退出码 0**。
* 红:手工往 `pnl/page.tsx` 塞回字号 → **自己的退出码 1**,点名 `app/finance/pnl/page.tsx:138` 与 `:179`。
* 缺这一维时:**自己的退出码 2**(「基线里没有 cellfont 这一维」)——**它不会把缺席当成零。**

**前三维一处都没有放宽 ——逐字节比过基线 JSON:**
`table` 66 文件/76 处 · `button` 11/18 · `linkbutton` 12/16,**三维全部逐字节相同。**

**盲区印在闸自己的收尾里**(不只写在报告里):运行期拼出来的 className ·
分不出 Column 与别的带 `className` 属性的对象 · **看不见常量背后的字号**
(`tableC.root` 自己带着一个 `text-sm`,那是行高的来源,本闸数不到它)·
看不见外层元素的字号往下继承。

---

## 8 · 那 9 张 UNMEASURED 的表:**动了 0 张,而其中 1 张【本来在本刀的工作单里】**

| 表 | 类 | 处置 |
|---|---|---|
| **`app/hr/payroll/PayrollGrid.tsx:202`** | **E(有 tfoot)** | ★ **它同时是 UNMEASURED 那 9 张之一,所以本刀【没有碰它】** |
| `output/[id]/edit/TraceabilitySection.tsx:68` · `:126` | C | 不在本刀工作单里 |
| `inbound/[id]/edit/AssaySection.tsx:87` | C | 同上 |
| `inbound/[id]/edit/PricingPanel.tsx:138` | C | 同上 |
| `logistics/forwarders/[id]/ForwarderPanels.tsx:167` | C | 同上 |
| `logistics/forwarders/[id]/page.tsx:203` | C | 同上 |
| `output/[id]/edit/OutputAssaySection.tsx:50` | C | 同上 |
| `stocktakes/[id]/page.tsx:226` | C | 同上 |

☞ **所以这一刀做的是 22 张,不是 23 张。** 委托书 §4 明写「如果工作单里有一张也是那九张之一,
留着它并且说出来 —— 量在先」;`known-issues.md` 的裁定 **R-Q6**(「不要在没量之前改它们」)同一条。
**`PayrollGrid` 因此仍然是变体 A,与另外 22 张不一致 —— 这是【写下来的余量】,不是漏掉的一张。**

---

## 9 · 用户看得见的字:**一句都没有新增、消失或改写**

一支断言器逐文件比 HEAD 与工作树的全部 `t('…')` key(集合 **与** 出现次数):

* 新增 key:**0** · 消失 key:**0** · i18n 文案文件:**一个都没动**。
* **出现次数变了的只有两处,而两处都是 R1 的【预期结果】:**
  `sales.amend.colRemove` 2 → 1 · `suppliers.compliance.colActions` 2 → 1
  —— 那一列自己回到明面上之后,叠在身份格里的**那一份标签**不再画。
  **不是少了一句话,是同一句话不再画两遍。**

---

## 10 · 我自己拿的主意(**都是细节,不是形状**)

1. **`<thead>` 上的 `bg-gray-100` 拿掉了(21 处)。** 依据:C 的 `headRow` 只有那条 ocean 线,
   **带底色的是变体 B**(`bg-[color:var(--brand-muted)]`,`brand-sampler/page.tsx` 里并排写着);
   已上线的 `data-table.tsx` 的 `<thead>` 也没有底色。留着它,这 22 张与那 98 个文件仍然不一样。
2. **分组抬头行 / tfoot 合计行的底色与字重【没有动】**(`bg-gray-50` · `bg-gray-100 font-bold` 原样)。
   依据:取样页里**没有**这些东西(spec §6),对它们的正确答案是「今天没有标准」,**不是一个我挑的值**。
3. **空态行不拼 `tableC.cell`,写死 `px-3 py-8`。** 依据:`py-2.5` 与 `py-8` 特指度相同,
   **class 串里的先后【不决定】谁赢**(那由 Tailwind 生成的顺序决定)——赌它是一次 STYLE-2 式的失败。
   `px-3 py-8` 是照抄 `data-table.tsx:486` 已上线的空态行,**不是我挑的数**。
4. **`ForecastGrid` 冻结首列的表头格,`bg-gray-100` → `bg-[color:var(--brand-bg)]`。**
   拿掉表头底色之后,那一格会变成一整排里**只有第一格**有灰底;而它必须不透明(后面要滚过去)。
   `--brand-bg` 是页面自己的底(`ListPage` 是一个裸 `div`,不是卡片 —— **读源码确认的**)。
5. **行上的旧分隔线拿掉了**(`NewFreightForm` 的 `border-t border-gray-200`)。
   留着会与 `tableC.bodyRow` 的 `border-b` 叠成两条,而且是两个颜色。
6. **`font-mono` / `tabular-nums` / 对齐 / 断点类一律留着。** 那是列的意思,不是表的外观。
   实测:`hidden sm:table-cell` 与 `sm:hidden` 的出现次数**逐文件改前改后相等**——
   **34 次列选判断一个字节都没动。**
7. **字色一个字节没碰。** spec §4.3 记的表头字色是 `--foreground`,而已上线的组件用的是
   `--brand-text`(§7.4:两个都明写过、都过 AA)。**本刀不替谁裁这一条。**
8. **改写用脚本做,不用手改。** 331 个标签手改必然漏;而脚本**在构造上**只重写
   `className=` 那一段的内容,别的字符原样透过 —— **"只改呈现"因此是一条结构性质,不是一句自律。**
   ★ 改写器自己抓到过一处**差一点上线的缺陷**:`'… font-mono text-sm ' + (x ? 'text-red-600' : '')`
   里那个**结尾的空格**被 split/join 吃掉,拼成 `font-monotext-red-600`(**两个类粘成一个,两个都失效**)。
   现在洗字符串时首尾空白原样保留。

---

## 11 · Tim 该去哪儿看

1. **★ `/finance/trial-balance`** —— **就是你打开的那一页。** 现在:表头下面一条 2px Hawaiian Ocean 线、
   格子之间没有竖线、表头 15px/500、正文 15px。把它和 **`/finance/journal`**(DataTable)并排开,
   两页的表头**应当一模一样**;正文那一栏 trial-balance 是 15px、journal 还是 14px ——
   **那一个像素就是 §2.3 说的那一个 token,它是下一刀的一行改动。**
2. `/finance/receivables` 与 `/finance/payables` —— 账龄桶抬头 + 手机叠字格都还在,只是穿了新衣服。
3. `/finance/cash-forecast` —— 冻结首列的枢轴表,**表头第一格的底色换过**(§10.4),请看它对不对。
4. **390px 上看 `/finance/receivables`** —— 行高涨了 37px,是本刀最大的一处纵向变化。
5. `/finance/pnl` 与 `/finance/balance-sheet` —— 分组小计行的灰底**故意留着**(§10.2)。
6. `/hr/payroll/[id]/edit` —— **它【故意】还是老样子**(§8),是那九张没量过的表之一。

---

## 12 · 我【没有】验证的东西 —— 说白

1. **22 张里 9 张没有被渲染量过**(6 张在 `[id]` 路由上,3 张首屏不出现)。见 §4.1。
2. **R1 那三处行为改动,一处都没有渲染验证过。** 见 §6 末段。
3. **`/me` 实测 `tables=0`** —— 探针的用完即删账号没有报销单/假期/工资条,
   于是 `/me` 上那 8 张表**本刀一张都没量到**(它们不在这 22 张里,但 R1 动了其中一张)。
4. **`survey-variant-c.mjs` 只量首屏、只走硬导航**(它自己的 AIM ② ③)。展开行、对话框、
   点开之后才出现的表,本刀一个字都答不了。
5. **`/finance/freight/new` 与 `/tools/pricing/metal-prices/bulk` 上那两处开工前就有的横向溢出,
   本刀没有去修**,也没有查清是哪一格撑出来的。见 §5。
6. **`data-table.tsx` 那个"画两遍"(:532/:548)本刀没有碰、也没有量**(R5)。
7. **没有查"哪些路由真的有人在手机上用"** —— TABLE-CONVERT-0 §11.6 说过没有任何记录,本刀没有再查。
8. **`cellfont` 这一维分不出 Column 描述符与别的对象**,也看不见运行期拼出来的 className。见 §7。
