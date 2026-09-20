# DRAFT-0 —— 停止闸:B 类草稿模型表的勘察(2026-09-20)

> ### ★ 这份文件【没有改一行 `app/` / `lib/` / `db/` / `scripts/` / `messages/`】。
> 它到这里停住,等 Tim 的裁定。没有迁移、没有 gate、没有构建、没有冒烟、没有浏览器探针,
> 也**没有向线上发过一次查询**。全部读数来自**读源码**。

**开工闸(2026-09-20):** 工作树干净;
`HEAD` = `origin/main` = `git ls-remote origin main` = `bb7f69388fc6be1e805cfde71a8813cab4f30c25`(FA-HIST-1 close-out)。

**委托书的题目逐字:** 「把草稿模型表的真集定下来 · 每一张今天怎么编辑怎么保存 ·
以及让它们全部搬到同一个表格组件上、而不丢掉行为的那个【最小】共享能力。」

---

## 0 · 一句话的结论,以及那两件改变刀口形状的事

> ### ★★★ **① 那个缺的能力【大部分已经建好了】,而没有人知道。**
>
> 队列第 4 行与 `known-issues` §六-3 都写着这一刀缺的是
> **「行级编辑态 / 脏值追踪 / 逐行保存」**。
> **这三件 `app/components/ui/editable-table.tsx` 今天全都有**,而且它还有
> **`mode: 'all-rows'`(整格编辑)** 与 **`footer(drafts, anyDirty)`(把草稿递给页面自己提交)**
> —— 也就是 Tim 在 Q4 里要的「整格模式」**已经在树上,而且已经有一个消费者**
> (`app/me/MySelfAssessmentPanel.tsx`)。
>
> ☞ **真正缺的是四件小东西**(§3.2),不是一个状态机。

> ### ★★★ **② 变体 A 是一件衣服,不是一种行为 —— 于是那个 11 数的不是这一刀的分母。**
>
> 被双渲染拦住的**不是** 11 张,是 **27 张**。
> 那 16 张已经穿着 `tableC` 的表,**被同一个机制拦得一样死** ——
> 它们此前不在任何一份名单上,因为唯一那份名单的判据里混进了一个外观条件。

### ★ 本刀交出的四个更正(逐条带量法,§1.3)

| # | 记载 | 今天的实数 |
|---|---|---|
| ① | **25**(队列第 4 行,2026-09-11,`54451b16`) | ★ **可复现** —— 但只能用一把**带着两处本仓库已成文缺陷**的扫描器。见 §1.3 |
| ② | **11**(`known-issues` `TABLE-CONVERT-SWEEP` §三) | ★ **逐名复现,11/11 全中** —— 而它的判据里含【变体 A】,所以它是一份**外观债名单**,不是这一刀的分母 |
| ③ | **`<EditableTable>` 调用点 = 6** | ★★ **是 `grep -c` 的假象。真数 = 4** —— 两个文件各在注释里再命中一次。于是「6 → ~17」**两头都不对** |
| ④ | **`ContainerPanels:120` 是 B 类** | ★★ **假阳性** —— 那一格里**一个受控输入都没有**,它是一个**行内拆离确认表单**(`name="reason"`,非受控) |

---

## 1 · 真集

### 1.1 ★★ 三条判据,三个数 —— 它们数的不是同一件事

| 判据 | 得数 |
|---|--:|
| 手搓 `<table>`,格子里有**任何**输入(含包装组件与行组件) | **27** 张 / **23** 个文件 |
| ↳ 其中格子里有**受控**输入(`value=`/`checked=` + `onChange`,或 `DecimalInput`) | **23** 张 / **21** 个文件 |
| ↳ 其中**仍是变体 A**(没穿 `tableC`) | **11** 张 ← ★ **这正是 `known-issues` 那 11 张,逐名相同** |
| 只算**词法上夹在 `<table>…</table>` 之间**的格子,且**不剥注释** | **25** 张 ← ★ **这正是队列那个 25** |

**量法(可复跑):** 剥掉注释(保留行号)→ 按标签配对切出 `<table>` 区段与 `<td>` 区段 →
对每个 `<td>` 判定它含不含 `<input|select|textarea>` 或一个**自身渲染输入的组件**
(全树 `.tsx` 预扫出这类包装件)→ 再把**直接画在这张表 `<tbody>` 里的行组件**
(`LineRow` / `RowCost` / `SetReviewerControl`)的 `<td>` 也算进它所属的那张表。

### 1.2 ★★ 27 张 —— 逐张

> **「行从哪来」写的是【行的供给方式】,不是行数。** 行数取决于线上有多少数据,
> 而**本刀一次线上查询都没有发** —— ⚠ **所有「典型显示几行」一律 `NOT MEASURED`。**
> 写供给方式比写一个猜出来的行数有用:它决定这张表要不要加行、要不要空态。

| # | file:line | 路由 | 变体 | 行从哪来 | 每行受控格 | 输入改的是什么 | 保存形状 |
|--:|---|---|:-:|---|--:|---|---|
| 1 | `app/finance/fx/bulk/BulkFxGrid.tsx:89` | `/finance/fx/bulk` | **A** | `dates`(一周) | 3 | 三种牌价(`tt_buy`/`tt_sell`/`mid`)。★ **已在册的格子变成只读读数 + 一条「去哪里改」的链接** | 甲 · 整格一次 `recordFxRatesBulk(cells)`,**全有或全无** |
| 2 | `app/hr/attendance/[id]/AttendanceGrid.tsx:60` | `/hr/attendance/[id]` | **A** | `rows`(该期间的考勤行) | 4 | 三个加班桶 + 备注 | **乙 · 逐行** `recordAttendance()` → RPC `record_attendance` |
| 3 | `app/hr/payroll/PayrollGrid.tsx:214` | `/hr/payroll/new` · `/hr/payroll/[id]/edit` | **A** | `employees`(在职员工) | 5 | 工资五个数(`DecimalInput`) | 甲 · 隐藏 `lines_json` → `savePayrollPeriod` |
| 4 | `app/hr/reviews/GoalsEditor.tsx:155` | `/hr/reviews/[id]` · `/my-reviews/[id]` | **A** | `goals` | 5 | 目标 / 指标 / 单位 / 实际 / 评语 | **乙 · 逐行,而一行散成最多【三支】action** |
| 5 | `app/logistics/containers/[id]/ContainerPanels.tsx:125` | `/logistics/containers/[id]` | **A** | `attached`(装着的发货单) | **0** | ★ **不是草稿格** —— 一个只在某一行展开的拆离确认表单(`name="reason"`,非受控) | 丙 · 行内 `detachShipment()` |
| 6 | `app/operation/orders/new/NewWorkOrderForm.tsx:96` | `/operation/orders/new` | **A** | `Array.from({length: LINE_SLOTS=5})` | 2 | 投料物料 + 计划量 | 甲 · 整表 `createWorkOrder({…})`,空行**在客户端被过滤掉** |
| 7 | `app/operation/orders/new/NewWorkOrderForm.tsx:135` | 同上 | **A** | `EXPECTED_SLOTS=3` | 4 | 预期产出 + 依据 + 依据出处 | 同上(同一次提交) |
| 8 | `app/purchasing/orders/new/NewOrderForm.tsx:869` | `/purchasing/orders/new` | **A** | `terms` | 4 | 付款计划(名目 / 比例或定额 / 触发事件) | 甲 · 隐藏 `terms_json` → `createOrder` |
| 9 | `app/purchasing/payment-terms/TemplateForm.tsx:169` | `/purchasing/payment-terms/new` · `/[id]/edit` | **A** | `lines` | 4 | 付款条件模板行 | 甲 · 隐藏 `lines_json` → `saveTemplate` |
| 10 | `app/sales/quotes/[id]/QuoteLinesEditor.tsx:82` | `/sales/quotes/[id]` | **A** | `lines` | 2 | 数量 / 单价 | **乙 · 逐行** `updateQuoteLine`;加行与删行各自一支 |
| 11 | `app/settings/roles/PermissionMatrix.tsx:121` | `/settings/roles/[id]` | **A** | `modules`(**从权限目录推出来**) | 2 | 角色的 View / Edit | 甲 · `saveRolePermissions(roleId, codes)` |
| 12 | `app/finance/freight/new/NewFreightForm.tsx:244` | `/finance/freight/new` | C | `batches` | 2 | 运费摊到哪几批、各摊多少 | 甲 · `createFreightDocument` |
| 13 | `app/finance/invoices/[id]/CreateCreditNoteControl.tsx:119` | `/finance/invoices/[id]` | C | `lines` | 1(+3 非受控) | 贷项通知单的行:类别 / 数量 / 金额 | 甲 · `createCreditNote`(bound) |
| 14 | `app/finance/invoices/new/NewInvoiceForm.tsx:284` | `/finance/invoices/new` | C | `visible`(销售记录) | 1 | 选哪几条进这张发票 | 甲 · `createInvoice` |
| 15 | `app/finance/payments/new/NewPaymentForm.tsx:519` | `/finance/payments/new` | C | `pos`(采购单) | 3 | 这笔付款摊到哪几张单、各摊多少 | 甲 · `createPayment` |
| 16 | `app/finance/payments/new/NewPaymentForm.tsx:590` | 同上 | C | `items` | 3 | 同上(第二张表,同一次提交) | 同上 |
| 17 | `app/hr/reviews/cycles/page.tsx:161` | `/hr/reviews/cycles` | C | `noReviewer` | 1 | 指派评估人 | **乙 · 逐行** `setReviewer(reviewId, value)` |
| 18 | `app/inbound/[id]/assays/new/AssayForm.tsx:245` | `/inbound/[id]/assays/new` | C | `substanceOptions`(活跃物质字典) | 1 | 化验含量 | 甲 · ★ **并列数组**:每行一个隐藏 `name="assay_metal"` + 一个 `name="assay_content"` |
| 19 | `app/logistics/containers/[id]/ContainerPanels.tsx:311` | `/logistics/containers/[id]` | C | 里程碑 | **0** | ★ **不是草稿格** —— 表下的加一行表单(非受控) | 丙 · 行内 action |
| 20 | `app/output/[id]/assays/new/OutputAssayForm.tsx:179` | `/output/[id]/assays/new` | C | `substanceOptions` | 1 | 产出化验含量 | 甲 · 并列数组 |
| 21 | `app/purchasing/orders/[id]/amend/AmendOrderForm.tsx:153` | `/purchasing/orders/[id]/amend` | C | `lines` | 3 + 删除勾选 | 改单:数量 / 单价 / 价格状态 | 甲 · `amendWithId` |
| 22 | `app/sales/orders/[id]/amend/AmendOrderForm.tsx:165` | `/sales/orders/[id]/amend` | C | `lines` | 2 + 删除勾选 | 改单:数量 / 单价 | 甲 · bound action |
| 23 | `app/sales/orders/[id]/amend/AmendOrderForm.tsx:311` | 同上 | C | `NEW_SLOTS=3` | **0** | ★ **全非受控**:加行的三个空槽(`new_qty_${i}` …) | 甲 · 同一次提交 |
| 24 | `app/sales/quotes/new/NewQuoteForm.tsx:129` | `/sales/quotes/new` | C | `LINE_SLOTS=5` | **0** | ★ **全非受控**:报价行五个空槽 | 甲 · FormData 并列数组 |
| 25 | `app/tools/pricing/calculator/CalculatorForm.tsx:159` | `/tools/pricing/calculator` | C | `substanceOptions` | 1 | 试算用的化验值 | ★★ **它【不保存】** —— `calculatePrice` 只算不写 |
| 26 | `app/tools/pricing/formulas/FormulaForm.tsx:356` | `/tools/pricing/formulas/new` · `/[id]/edit` | C | `substanceOptions` | 1 | 计价公式的应付比例 | 甲 · 并列数组 |
| 27 | `app/tools/pricing/metal-prices/bulk/BulkPricesForm.tsx:107` | `/tools/pricing/metal-prices/bulk` | C | `substanceOptions` | 1 | 批量金属价 | 甲 · `saveBulkPrices`,并列数组 |

> ★ **那 11 张变体 A 的子名单(= `known-issues` 逐名相同,行号漂了 1–12 行):**
> 第 1 · 2 · 3 · 4 · 5 · 6 · 7 · 8 · 9 · 10 · 11 行。
> ⚠ **其中第 5 行(`ContainerPanels:125`)按它自己的判据【不该在】这份名单上**(更正 ④)。
> ☞ **照「变体 A + 受控输入」这条判据重数,它是【10】,不是 11。**

### 1.3 ★★ 两个数的和解 —— **两个都留着,一个都不替换**

#### ① 那个 **11** —— 复现了,而且是逐名复现

**它的规则是:「手搓 `<table>` · 格子里有输入 · 而且仍是变体 A」。**
跑出来的 11 张与 `TABLE-CONVERT-SWEEP` §三点名的 11 张**文件全同、顺序全同**,行号差 1–12 行
(`BulkFxGrid` 88→89 · `AttendanceGrid` 48→60 · `PayrollGrid` 202→214 · `GoalsEditor` 153→155 ·
`ContainerPanels` 120→125 · `NewWorkOrderForm` 95/134→96/135 · `NewOrderForm` 866→869 ·
`TemplateForm` 167→169 · `QuoteLinesEditor` 81→82 · `PermissionMatrix` 120→121)——
**那是 2026-09-10 之后的提交把行推下去了,不是数错了。**

★★ **但这条规则里有一个【外观】条件,而这一刀问的是一个【行为】问题。**
一张穿着 `tableC` 的表被双渲染拦得和变体 A 一样死。
☞ **所以 11 是一份【外观债】名单,不是这一刀的分母。**

#### ② 那个 **25** —— 复现了,而复现它需要一把**坏掉的**扫描器

**唯一跑得出 25 的规则是:**
> 只承认**词法上夹在 `<table>` 与 `</table>` 之间**的 `<td>`,**并且不剥注释**。

它比真集(27)少两张,而少掉的正好是这两张:

| 丢掉的 | 为什么丢 | 这个缺陷的出处 |
|---|---|---|
| `AttendanceGrid:60` | 它的格子住在 **`LineRow`** 里,而 `LineRow` 在 `</table>` 之后才声明 | ★ `TABLE-CONVERT-SWEEP` §五-③ 逐字写过:**「一张的输入连表块都不在(住在 `LineRow` 里)」** |
| `hr/reviews/cycles/page.tsx:161` | 文件第 12 行的**注释里**有一个 `<table>`,它把标签配对**整个顶歪** | ★ 同 §五-①:**「4 个文件的 `<table>` 只在注释里(假阳性)」** |

> ### ☞ 所以这一格的诚实说法是:
> **25 是可复现的,而复现它的那条规则,恰好踩中本仓库【已经写下来过两次】的两处扫描器缺陷。**
> ⚠ **这【不是】在说 2026-09-11 那天就是这么数的** —— 那天的推导**仓库里仍然一处都没有**,
> 本节是一次**重建**,不是一次考据。**标 `RECONSTRUCTED, NOT PROVENANCE`。**
>
> ★ **Tim 的裁定(2026-09-20,DRAFT-0 grilling Q1/Q2):分母取 27;25 与 11 都划掉留着,
> 把重建出来的规则与它的两处缺陷写在旁边。** —— 本节就是那段话。
>
> ★★ 而那句**「它们的外观已经是对的」仍然是【假】的**:那 11 张今天照旧是
> `border border-gray-300` 的全边框变体 A(实测)。**Q5 已裁:这一刀把它们一起换成 `tableC`。**

#### ③ 顺带更正:**`<EditableTable>` 调用点不是 6,是 4**

```
grep -c "<EditableTable"  →  6   ← 它数的是【命中的行】
真的 JSX 调用点            →  4
```
多出来的两处是 `LeaveTypesEditor.tsx:6` 与 `ScaleEditor.tsx:7` —— **两句注释**。
`git grep` 到 TABLE-CONVERT-7 那个提交(`1ae378fc`)结果逐字相同,**这不是后来改掉的,是当时就数错了**。

★ 四个真调用点:`app/me/MySelfAssessmentPanel.tsx:186` · `app/hr/kpi/score/ScoreEditor.tsx:213` ·
`app/hr/leave/types/LeaveTypesEditor.tsx:121` · `app/hr/reviews/scale/ScaleEditor.tsx:148`。

☞ **于是「从 6 个调用点扩到 ~17 个」两头都要改:起点是 4,终点由 §3.4 的刀序决定。**

---

## 2 · 每一张今天怎么保存

### 2.1 ★★ 三种保存形状(Tim 已在 Q3 裁定:三种都在射程里,而【甲-2】要显式声明)

| 形状 | 几张 | 是哪几行(§1.2 的编号) | 是什么 | 失败时屏幕上发生什么 |
|---|--:|---|---|---|
| **甲-1 · 整格一次,行是【服务端已有的行】** | **14** | 1 · 3 · 11 · 12 · 13 · 14 · 15 · 16 · 18 · 20 · 21 · 22 · 26 · 27 | 一次 action 收下整张表。`useActionState` + `<form action={formAction}>`,或 `useTransition` + 一次调用 | 页顶一条**具名**红框(`state.error` / `setError`),**打好的字留着** |
| **甲-2 · 整格一次,行是【还不存在那条记录的草稿行】** | **6** | 6 · 7 · 8 · 9 · 23 · 24 | 建单页/加行区的行编辑器 —— 那几行背后没有服务端行,**「脏」在这里没有意义** | 同上 |
| **乙 · 逐行保存** | **4** | 2 · 4 · 10 · 17 | 每行一颗保存钮,一次一行 | 页顶(**不是行上**)一条具名红框 |
| **丙 · 行内一次性动作**(不是保存这一行的编辑) | **2** | 5 · 19 | 拆离 / 加里程碑,一个只在某一行出现的小表单 | 页顶红框 |
| ★ **例外:一张【不保存】的** | **1** | 25 | `CalculatorForm:159` —— `calculatePrice` 只算不写。形状上属甲-1,**但它没有保存可言** | — |

> ★ **14 + 6 + 4 + 2 + 1 = 27,分母对得上。**
> ⚠ 第 23 行(`AmendOrderForm:311`)与第 22 行**同属一次提交**,但它的行是 `NEW_SLOTS` 空槽,
> **所以它归甲-2,不归甲-1** —— 这个区别正是 Q3 裁定要显式声明的那个模式。

### 2.2 ★ 逐条答委托书点名的五个问题

| 问题 | 今天的实数 |
|---|---|
| **整格 / 逐行 / 逐格?** | **没有一张是逐格的。** 整格 **21** 张(含那张只算不写的)· 逐行 **4** 张 · 行内一次性 **2** 张 |
| **走哪支 action / RPC?** | 逐张见 §1.2 末列。★ **三张用【隐藏 `*_json` 桥】**把整格草稿塞进一个 `<input type="hidden">` 再交给 form action:`PayrollGrid:119` · `NewOrderForm:371-372` · `TemplateForm:108` |
| **失败时会怎样?** | ★★ **27 张、23 个文件里:`role="alert"` = 0,`aria-invalid` = 0。** 失败一律是**页顶/面板顶一个红 div**,措辞是具名的(走各自的 `*ErrorCodes.ts`),**但它不指向任何一行、任何一格**。★ **没有一张会悄悄失败。** ★ `BulkFxGrid` 额外印一句「全有或全无」 |
| **有没有未保存提醒?** | ★★★ **27 张【一张都没有】。** 全树 `beforeunload` 只有 4 处命中,**全部在 `editable-table.tsx` 里**,而这 27 张**一张都没用它**。★ 两张挂了 `useFormDraft`(`NewOrderForm` · `FormulaForm`),但按 `editable-table.tsx:51-73` 写下的四条机械理由(没有 `<form>` 元素取值口、受控输入写不回 DOM、输入没有 `name`、一张网格有 N 个指纹),**IDLE-DRAFT 按构造盖不住格子里的草稿** —— ⚠ **恢复一份草稿会把抬头字段带回来、把那张网格丢掉。** 见 §4 的 Q6 |
| **要不要加行 / 删行?** | **要的:6 张。** `GoalsEditor`(加+删)· `QuoteLinesEditor`(加+删)· `NewOrderForm` 付款计划(加+删)· `TemplateForm`(加+删)· 两张 `AmendOrderForm`(**勾选标记删除**,不是就地删行)· `ContainerPanels:311`(加)。★ 另有 **4 张走【固定空槽】**(`LINE_SLOTS` / `EXPECTED_SLOTS` / `NEW_SLOTS`),空行在提交时被过滤掉 |

### 2.3 ★★ 分组的结论:**一个共享能力够了,但它要带一个【显式的模式开关】**

甲-1 与甲-2 的**界面行为完全一样**,差别只在**「有没有一份服务端基线可以比」** ——
而这正是 `EditableTable` 的 `toDraft` / `isDirty` 这两个口子在问的事。
☞ **甲-2 的做法就是把 `toDraft` 写成恒等、把 `isDirty` 写成恒真**,组件一个字不用改。
**Tim 在 Q3 已裁:它要【被声明】,不许靠推断。**

---

## 3 · 共享能力要做到什么

### 3.1 ★★★ 双渲染 —— 它是什么,以及**它已经被解掉了**

**机制,带 file:line:**

| 落点 | 代码 | 后果 |
|---|---|---|
| `app/components/ui/data-table.tsx:755` | `{c.render(row)}`,对**每一个** `shownCols` 画一次;非 priority 列靠 `hidden sm:table-cell` **藏起来,不是移出 DOM**(`:749`) | 第一份 |
| `app/components/ui/data-table.tsx:771` | `<dd …>{c.render(row)}</dd>`,对 `restCols`(`:704` = `shownCols.filter(c => !c.priority)`)**再画一次** | 第二份 |

☞ **一个非 priority 列的 `render` 每行被调用两次。** 输入写进 `render` 就有两份互相独立的 state ——
★ 而且**第二份只在 `isOpen` 时挂载**(`:760`),**收起展开区等于把那一份打好的字销毁**。
⚠ 对那 5 张**并列数组**表(§1.2 第 18 · 20 · 24 · 26 · 27 行)还有**第二重**后果:
同一个 `name` 在 FormData 里出现两次,**两列数组从此错位** —— 与 TABLE-STYLE-1 抬头点名的
「14 张的并列数组提交会被拆坏」是同一件事。

#### ★★★ 解法:**不在 `DataTable` 里,也不要第三个组件 —— 它在 `EditableTable` 里已经建好了**

`EditableTable` **照样画两遍**(`editable-table.tsx:418` 桌面格 · `:489` 手机展开区),
**而它不出问题**,因为两件事:

1. ★ **草稿住在组件的 `drafts: Record<rowKey, D>` 里,不住在回调的返回值里。**
   列描述符是 `edit?: (draft: D, set: (patch) => void) => ReactNode`(`:118`)——
   **它是一个纯投影,自己不持有任何 state。** 两份副本读同一个 store、写同一个 store。
2. ★ **同一个断点上编辑控件只存在一处**:`:417` 的 `<span className="hidden sm:block">` 与
   `:420` 的 `<span className="sm:hidden">{c.render(row)}</span>` —— **手机上格子永远是只读的**,
   编辑发生在展开区。

> ### ☞ 于是那条可复用的话是:
> **双渲染不是靠「少画一遍」治好的,是靠【把草稿抬到回调上面、让格子回调变成无状态的投影】治好的。**
> **`DataTable` 的 `render: (row) => ReactNode` 是一个纯只读契约,它没有地方放草稿** ——
> 要改它就等于把 CONV-2 明文拒绝过的那次分叉倒回去(`data-table.tsx:172-176`)。
> ★★ **裁决:`DataTable` 一个字节都不动。**

★ **而这个形状树上已经有一个手搓的先例:** `AttendanceGrid` 的 `LineRow` 把
`holiday` / `note` **各画两遍**(`:156`/`:182` 与 `:164`/`:186`),两份读写**同一个 `useState`**
—— 因为那个 `useState` 提在行组件里,不在格子里。**它今天就在生产上跑,而且是对的。**

### 3.2 ★★ 真正缺的四件 —— 逐件带「几张要它」

| # | 缺的能力 | 几张要 | 谁要 | 为什么 `EditableTable` 今天给不了 |
|--:|---|--:|---|---|
| **A** | **加行 / 删行**(页面自己供一颗行内动作钮) | **6** | `GoalsEditor` · `QuoteLinesEditor` · `NewOrderForm` 付款计划 · `TemplateForm` · 两张 `AmendOrderForm`(勾选标记删除) | `showActions`(`:322`)写死成**组件自己的**编辑/保存/取消三颗,**没有给页面留槽**;而且它 `mode === 'one-row'` 才为真 —— ☞ **`all-rows` 模式下整条动作列都不存在** |
| **B** | **`rowClassName`** —— 按行涂色 | **2**(+潜在更多) | `PayrollGrid`(`rowCheck` 不过就整行 `bg-red-50`,`:231`)· `AttendanceGrid`(未录入的行 `bg-amber-50`,`:144`) | ★ `DataTable` **有**这个 prop,`EditableTable` **没有**(全文 0 处命中) |
| **C** | **表尾合计行(`<tfoot>`)** | **1**(+3 张今天把合计写在表外) | `PayrollGrid`(五列合计) | `EditableTable` 全文**没有 `tfoot`**。★ TABLE-FOOTER-1 只给了 `DataTable`,**而那个能力至今【零个消费者】** —— 这一刀会是它的第一个 |
| **D** | **跨行写草稿** | **1** | `PermissionMatrix`:勾 Edit 要**顺手把同一行的 View 也勾上**,取消 View 要**连带取消 Edit**(`setModule`,`:76-93`) | `edit(draft, set)` 的 `set` 只 patch**这一行**的草稿。★ 而 `PermissionMatrix` 的状态其实**根本不是按行存的**,是一个扁平的 `codes: string[]`(`:40`) |

> ### ★ 而这四件之外,下面这些**看起来缺、其实不缺**,逐条写下来免得下一刀重新发明:
>
> | 看起来要加的 | 实际上 |
> |---|---|
> | **整格编辑模式** | ✅ **已有** —— `mode: 'all-rows'`(`:152`,理由写在 `:140-151`),`MySelfAssessmentPanel` 正在用 |
> | **把整格草稿交给页面自己提交** | ✅ **已有** —— `footer(drafts, anyDirty)`(`:166`,理由写在 `:158-165`)。★ **那三张隐藏 `*_json` 桥就写在这里**:`<input type="hidden" name="lines_json" value={JSON.stringify(drafts)} />` |
> | **一行的保存散成三支 action**(`GoalsEditor`) | ✅ **不用加** —— `onSave(draft, row)` 是页面自己给的 async 函数,散在里面 |
> | **某一格不可编辑 + 一句理由** | ✅ **不用加** —— 不给 `edit` 就是这一列不可编辑(`:118`);要画「—」或一条只读链接,`render` 里返回即可(`BulkFxGrid` 与 `PermissionMatrix` 今天就是这么干的) |
> | **固定空槽的行供给** | ✅ **不用加** —— `rows` 传 `Array.from({length: N})` 就是了 |
> | **枢轴 / 矩阵列**(`BulkFxGrid` 的三种牌价) | ✅ **不用加** —— `columns` 用 `TYPES.map(...)` 拼得出来,列数是常量不是数据 |
> | **排序 / 分页** | ✅ **不用加,而且不许加** —— `sorting?: never`(`:182`)/ `pageSize?: never`(`:184`)。★ **本刀逐张复核过这 27 张:没有一张有用户可控的排序或分页**,与 CONV-2 当年量的 10 张结论一致 |

### 3.3 ★ 这一刀顺带治好的一件(不是目标,是副产品)

**27 张表、23 个文件里 `role="alert"` = 0、`aria-invalid` = 0**(实测)。
`EditableTable` 把错误画在**那一行**下面并带 `role="alert"`(抬头 Q8)。
☞ **搬完之后,4 张逐行保存的表会第一次把「是哪一行出错了」说出来。**
⚠ **格子级的绑定仍然不做** —— 那是 PAGE-0 已排队的第 6 刀,本刀不碰。

### 3.4 ★★ 建议的刀序:**一刀,分四批落地,中间不推送**

> **默认是一刀,而本刀【没有找到分刀的理由】。** 四件缺的能力互相不打架,
> 27 张表共用同一个组件 —— 分两刀意味着 `EditableTable` 要在两个版本上各活一段时间。

| 批 | 装什么 | 几张 | 为什么排这个位置 |
|--:|---|--:|---|
| **① 组件** | A · B · C · D 四件加进 `EditableTable`;**`DataTable` 不动** | — | ★ 后面三批全压在它上面 |
| **② 乙类(逐行)** | 第 2 · 4 · 10 · 17 行 | 4 | ★ **它们正对着 `mode:'one-row'` 这条已经走通的路**,而且 `GoalsEditor` 是全场最难的一张(三支 action + 按权限分列 + 跨字段校验)—— **难的先走,它会把 A 这件能力的形状定下来** |
| **③ 甲类 · 有服务端基线** | 第 1 · 3 · 11 · 12 · 13 · 14 · 15 · 16 · 18 · 20 · 21 · 22 · 25 · 26 · 27 行 | **15** | `mode:'all-rows'` + `footer`,★ **三张隐藏 `*_json` 桥在这一批里被换成 `footer` 里的同一行代码** |
| **④ 甲类 · 建单页草稿行** | 第 6 · 7 · 8 · 9 · 23 · 24 行 | 6 | ★ **Q3 裁的那个显式模式在这里落地**;它们没有基线,所以排最后 —— 前三批会先把「脏」这件事的边界磨清楚 |
| ★ **贯穿** | 那 **11** 张变体 A 同时换上 `tableC`(**Q5 已裁**) | 11 | markup 本来就要重写,衣服跟着一起换是免费的 |

★ **两张丙类(第 5 · 19 行)【不进这一刀】** —— 它们不是草稿格,是行内一次性动作。
⚠ **但第 5 行要在 `known-issues` 上就地更正**(它被错记成 B 类),**这一条本刀写在 §4 Q1 里等裁定。**

---

## 4 · 要 Tim 答的(逐条带推荐答案与证据;**本刀不替任何一条作数**)

> ⚠ **以下每一条都【只是建议】。委托书明令不把建议写成裁定。**

### ❓ Q1 —— `ContainerPanels:120` 这条错记载怎么处置?

`known-issues` 的 B 类名单把它算成 11 张之一,**而它格子里一个受控输入都没有**:
那是一个只在 `detaching === s.id` 时出现的行内拆离确认表单(`ContainerPanels.tsx:165-180`,`name="reason"`,非受控)。
按它自己写的判据(「格子里有受控输入」),**真数是 10 不是 11**。
**➡ 推荐:按本仓库的规矩【划掉留着 + 旁注】,不删。** 理由是这份文件自己写过的那一条:
一条被悄悄改掉的旧读数,和一条从来没写过的读数,在读的人眼里没有区别。

### ❓ Q2 —— `PermissionMatrix` 要不要进这一刀?

它是 27 张里**唯一**一张状态根本不按行存的表(扁平 `codes: string[]`,`:40`),
而且它有**跨行联动**(能力 D)。为它加 D 这件能力,**只有它一个消费者**。
**➡ 推荐:进,而且 D 照建。** 证据:D 的成本是给 `set` 多开一个「写别的行」的口子,
而 `EditableTable` 的草稿本来就是一个 `Record<key, D>` —— **不是新机制,是把已有的容器多露一个把手。**
⚠ **但如果 Tim 要砍射程,这一张是最该先被砍掉的** —— 砍掉它,D 这件能力整件消失。

### ❓ Q3 —— `CalculatorForm:159` 那张【不保存】的表进不进?

它是 27 张里唯一一张不写库的(`calculatePrice` 只算)。它没有保存、没有脏、没有失败态。
**➡ 推荐:进,但只当它是「`all-rows` + 没有 `onSave` + 没有 `footer`」。**
证据:`EditableTable` 的 `onSave` 本来就是可选的(`:157`),`showActions` 在没有 `onSave` 时为 false(`:322`)——
**它落在一条已经存在的路上,不需要任何新能力。**

### ❓ Q4 —— 那 4 张**全非受控**的表(第 5 · 19 · 23 · 24 行)算不算射程内?

它们格子里是 `name=` + FormData,**一个 React 受控输入都没有**。
委托书写的是「受控输入」,严格读它们不在射程里;但第 23 · 24 行**与同一页上已经在射程里的表是同一张单据**。
**➡ 推荐:第 23 · 24 行【进】(它们是同一次提交的一部分,拆开会让同一页上两张表长得不一样);
第 5 · 19 行【不进】(它们是行内动作,不是格子)。**
⚠ **无论进不进,双渲染对它们都是【真】的危险** —— 同一个 `name` 画两遍会把并列数组错位。
☞ **这一条要写死在 `known-issues` 上,不管这一刀做不做它们。**

### ❓ Q5 —— 未保存提醒要不要跟着搬过来?

`EditableTable` 自带 `beforeunload`(`:272`),而它是一条**记录在案的【哑拒绝】例外**(抬头 Q7)——
浏览器拥有那段措辞,改不动。搬过去意味着 **27 张表一次性都长出这个对话框**,
而它们今天**一张都没有**。
**➡ 推荐:跟着搬,不单独开关。** 证据:Tim 当年对同一个问题的裁定逐字是
「把打好的字悄悄弄丢,比一次哑的拒绝更坏,而哑的那个至少看得见」——
**而这 27 张正是全系统最容易把字弄丢的地方。**
⚠ **它盖不住站内 `<Link>` 跳走**,这是一条已声明的限制,搬过去之后照旧成立。

### ❓ Q6 —— `NewOrderForm` / `FormulaForm` 那两份**半截草稿**怎么办?

两张表挂着 `useFormDraft`,而按 `editable-table.tsx:51-73` 的四条机械理由,
**IDLE-DRAFT 按构造读不到格子里的草稿**。
☞ 后果:**恢复一份草稿,抬头字段回来了,那张网格没回来** —— 而屏幕上没有一个字说这件事。
⚠ **本刀【没有】在浏览器里复现它** —— 标 `NOT MEASURED`,它是从两份源码推出来的。
**➡ 推荐:立一条 `known-issues`,不在这一刀修。** 理由:修它要么让 IDLE-DRAFT 认识网格草稿
(那是给 `useFormDraft` 加一个新契约),要么让 `EditableTable` 自己存草稿
(那是 Q7 那条明文限制的反面)—— **两条都比这一刀大。**

### ❓ Q7 —— `EditableTable` 长出四件能力之后,那条「不要把两个表格组件合起来整理」的警告还成立吗?

它的抬头写着后来的人不要把两者合并。这一刀让它更像 `DataTable`(`rowClassName` · `tfoot` · 行内动作)。
**➡ 推荐:成立,而且要在抬头就地补一段说明这次扩张【没有】动摇那条理由。**
证据:分叉的判据从来不是「功能多寡」,是**列描述符的契约** ——
`render: (row) => ReactNode` 对 `edit: (draft, set) => ReactNode`。**这一刀一个字都没有碰那条分界。**

### ❓ Q8 —— `PayrollGrid` 那 414px 的手机代价,搬家之后要不要重新量?

Tim 已经接受过它(横拖 414px、身份列先离场)。但 `EditableTable` 的手机做法
**与它今天的做法不是同一件事**:它会变成「priority 列留在表里 + 编辑在展开区」,
**而那正好治好「打字的人不知道这一行是谁」**。
**➡ 推荐:搬完之后量一次,并把新读数写在那条【已接受的代价】旁边。**
⚠ **不要把它读成「这一刀去修那个代价」** —— 它是搬家的副产品,而**副产品也要有读数才算数**。

### ❓ Q9 —— 这 27 张里有几张**从来没有在任何屏幕上渲染过**?

`TABLE-CONVERT-SWEEP` §四-1 点过名:`hr/reviews/cycles:158`(`review_cycles` 是空表)·
`PayrollGrid` 的空态行 · `ContainerPanels:120` 与 `:306` 并排的样子。
**它们三张在本刀的 27 张里。**
**➡ 推荐:这一刀开工前,先向线上发【一次只读计数】**,把「哪几张搬完之后没有任何办法看一眼」写成名单。
证据:本刀**一次线上查询都没有发**,所以这份名单今天**只能照抄 2026-09-10 那一份**,
而那一份**没有人复测过**。⚠ **绿构建不是读数。**

---

## 5 · 建这一刀要多久 —— **两个数,和它们的和**

> ★ **所有读数都带出处。没有出处的一律不写。**

### 5.1 工序底价(不论改多少代码都要付的)

| 项 | 时长 | 出处 |
|---|--:|---|
| 开工闸(三个 SHA + 工作树) | ~2 min | 本刀实测 |
| `npm run build` × 4 轮 | **~1.5 min** | `AGENTS.md:2711` 实测:19 条静态检查 3s + `next build` 19s ≈ **22s** |
| `node scripts/smoke-routes.mjs` × 1 | **~13 min** | `AGENTS.md:595` 实测 **765s**(12m45s,218 条路由,`SMOKE_OWN_EXIT=0`) |
| 交回报告 + 提交 + 推送 | ~20 min | 本刀实测(这一份) |
| **`python3 db/gate.py`** | ★★ **0 —— 不需要** | **这一刀零迁移**:`db/` 一个字节不动。★ 先例:FONT-3「一次迁移都没有,`db/` 一个字节没动」 |
| **备份** | ★★ **0 —— 不需要** | 同上:没有迁移就没有破窗,没有破窗就没有东西要回滚 |
| **线上取证** | ★ **不在这台机器上** | `AGENTS.md`「一刀的终端活【到推送为止】」—— 部署确认由 Tim 在 Vercel 面板上给 |
| **合计** | ★ **≈ 37 min 机器时间** | |

⚠ **另加两次【Tim 的钟】,不是机器的钟:** 一轮开工前的 grilling 往返 + 一次上线后的人工走查。
⚠ **`db/gate.py` 那个「~7 min」如果这一刀真的需要它:** `AGENTS.md:112` 记的是 **310s**(2026-09-05,193 fixtures),
而我的工作记录里另有一次 **437s**。**两个都是实测,日期不同;要用就现量一次,不要引这两个数。**

### 5.2 量过的工作量

| 批 | 射程(实测) | 估 |
|---|---|--:|
| ① 组件四件能力 | `editable-table.tsx` 今天 **555 行** | **~3 h** |
| ② 乙类 4 张 | 4 个文件 / **1,059 行**(`GoalsEditor` 410 行最重) | **~4 h** |
| ③ 甲类有基线 **15** 张 | **14** 个文件 / **4,611 行**;★ 其中 5 张是同一族(物质字典 + 并列数组),**做完第一张后面四张是复制** | **~9 h** |
| ④ 建单页草稿行 6 张 | **5** 个文件 / **2,166 行**(★ 其中 `AmendOrderForm` 与批 ③ **同一个文件**;`NewOrderForm` 1,080 行最重) | **~5 h** |
| ★ 11 张换 `tableC` | 与 ②③④ 同一次改写,**不另计** | **0** |
| **合计** | ★ 三批合起来 **22 个文件**(勘察射程是 **23 个文件 / 7,825 行**,多出来的那一个是丙类的 `ContainerPanels`,不进这一刀) | ★ **≈ 21 h** |

### 5.3 ★★ 两个数的和

> | | |
> |---|--:|
> | 工序底价 | **≈ 0.6 h**(机器)+ 2 次 Tim 的往返 |
> | 量过的工作量 | **≈ 21 h** |
> | ★★ **合计** | ★ **≈ 21.6 h**,外加两次 Tim 的往返 |

⚠ **这个估计会过期,而本仓库为此留过疤**(`forward-queue.md`「这里没有工时估计」那一节:
gate 写 32 秒实测 247 秒;`--reach` 写十到十五分钟实测 65 分 44 秒)。
☞ **它写在交回报告里、不写进队列**,正是因为队列那一节禁止把小时数存进仓库。

---

## 6 · 本刀【没有】做的事,逐条

* **没有跑构建、gate、冒烟、浏览器探针** —— 委托书明令。
* **没有向线上发过一次查询** —— 于是 §1.2 每一张的「典型显示几行」一律 `NOT MEASURED`。
* **没有改任何一个数** —— 25 与 11 都原样留着,§1.3 只在旁边写和解。
* **没有替 Tim 答 §4 那九条里的任何一条。**
* **没有动 `known-issues.md` 与 `forward-queue.md`** —— ⚠ 它们各有一处要就地更正
  (B 类名单里的 `ContainerPanels:120`;「`<EditableTable>` 调用点 = 6」),
  **等 Q1 裁完由建它的那一刀一起改。**
