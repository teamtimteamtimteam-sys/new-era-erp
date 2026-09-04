# 详情页模板(CONV-8,2026-09-04)· **一条记录 + 它的若干子表**

> ### ☞ 必须与两篇姊妹篇一起读
> * [`docs/list-page-template.md`](./list-page-template.md)(CONV-1)—— 只读账簿 `DataTable`
> * [`docs/editable-grid-template.md`](./editable-grid-template.md)(CONV-2)—— 可编辑网格 `EditableTable`
>
> **本篇【不是】第三套模板。** 它是那两套加上**一个新组件**(`RecordHeader`)
> 与**一条判据**(详情页的 `state` 恒为 `'ok'`)。那个裁定的证据在 §②。

**基线:** HEAD `68eb8cc`(CONV-6),树干净。

---

## ★★ 头条:人口是 **37**,不是 36;而「几张子表」这个前提是错的 ★★

**两件事都是在转换任何一页【之前】量出来的,而第二件改了这一刀的设计前提。**

### 人口 37,按 import 重新建的清单

委托写的是「大约 36 张」。按**路由末段是不是 `[param]`** 逐条数:**37 张**。
(58 张 page.tsx 路径里带 `[`,其余 21 张是 `/edit` `/amend` `/new` `/reconcile`
`/review` —— 表单页与子页,归第 6 刀。)

**37 张里【一张都没有转过】**:`<DataTable>` 0 · `<EditableTable>` 0 · `<ListPage>` 0。
这一刀是详情页这一支的起点,没有继承任何半成品。

> ★【本刀第一版的普查是【错的】,自己照出来的 —— 记下来免得下一刀照抄】★
> 第一版跟着 import 走的时候**没有把 `app/components/**` 那些共用件排除掉**,
> 于是它们随着每一条 import 链进了每一页的闭包:
> * `list-page.tsx` 自带 3 处 `<RefusalPage|RefusalBlock>` → **37 页里 36 页的
>   「拒绝」计数【恒为 3】**;
> * `data-table.tsx` 自带 1 处 `<table` → **每一页的表数都被多算了 1**。
>
> **一列【恒定不变】的数,和一列【全是 0】的数,是同一个信号:判据坏了,不是发现。**
> (`AGENTS.md` 那条「一个全 0 的测量结果要当成脚本坏了」的孪生形状。)
> 排除共用件之后,表数从 65 降到 **60**,拒绝计数从 108 降到 **2**。

### ★ 「详情页 = 一个抬头 + 【好几张】子表」是错的:中位数是 **1 张** ★

委托描述的形状是「a header of fields, then several sub-tables」。逐页量下来:

| 一页上的表数 | 页数 |
|---:|---:|
| 0 | 2 |
| **1** | **22** |
| 2 | 6 |
| 3 | 5 |
| 4 | 1 |
| 7 | 1 |
| **合计** | **37 页 · 60 张表** |

**22 / 37(59%)只有一张表。** 只有 7 张页面有 3 张以上的表。
这件事直接决定了 (a)/(b)/(c) 的答案:**「好几张子表」如果成立,可能真的需要
一个管分节的外壳;而它不成立 —— 大多数详情页就是【一个抬头 + 一张表】。**

### 子表比列表页【窄得多】

60 张表的列数分布:**≤4 列 28 张 · ≥5 列 32 张**,最宽 11 列
(`/inventory/output/[materialId]`)。对比 CONV-1 量的列表页:最宽 13 列、
众数 5、≥7 列有 52 张。**详情页的表将近一半根本不触发手机那条规矩**
(≤4 列不必声明 priority 也留得下)。

---

## ① 分类:9 张有【格子里的输入控件】,而其中两处只有按组件扫才看得见

判据用的是 CONV-1 那条(**格子里有没有 input / select / textarea**),
而机械实现按 CONV-5 §⑩-1 的教训做:**扫组件,不扫标签名**,并且把格子里出现的
每一个大写组件**解析到它的定义**再去里面找控件。

**9 / 37 页在格子里够得到一个输入控件:**

| 页 | 控件在哪 | 只按标签名 grep 能看见吗 |
|---|---|---|
| `/hr/reviews/[id]` · `/my-reviews/[id]` | `GoalsEditor`(同一个组件挂两页) | 能 |
| `/settings/roles/[id]` | `PermissionMatrix` | 能 |
| `/sales/quotes/[id]` | `QuoteLinesEditor` | 能 |
| `/finance/invoices/[id]` | `CreateCreditNoteControl` | 能 |
| `/logistics/containers/[id]` | `ContainerPanels` | 能 |
| **`/hr/attendance/[id]`** | **`<LineRow>`** —— 输入藏在一个同文件的组件里 | **不能** |
| **`/purchasing/orders/[id]`** | **`ExpectedDateControl` · `DeepDischargeJudgementControl`** | **不能** |

> ★【CONV-2 点名的两处重新指派,逐字确认了】★
> `GoalsEditor` 确实挂 `/hr/reviews/[id]` 与 `/my-reviews/[id]`;
> `PermissionMatrix` 确实挂 `/settings/roles/[id]`。两处都是详情页,
> 与 CONV-2 §头条那张表一致 —— **这一次继承来的判断是对的**。

> ★【一处本刀自己踩到的、值得写下来的量测事故】★
> 用 `grep -c "<\(input\|select\|textarea\)[ >]"` 去查那几个控件组件,得到
> **0**。而 `ExpectedDateControl` 里明明有一个 `<input type="date">` ——
> 它写成 `<input` **换行**再接属性,而那个字符类 `[ >]` **只认空格和 `>`,不认换行**。
> 判据差一个 `\n`,答案就从「这一页有就地编辑」变成「没有」。
> **与本文件头条那条是同一句话:一个可疑的 0 要先怀疑判据。**

### 那 9 张分别归谁

* **`/purchasing/orders/[id]`(以及任何「只读表 + 一个格子里的控件」)→ 仍然是 `DataTable`。**
  Tim 在本刀 Q3 的裁定,理由见 §④。
* **其余 → CONV-2 的 `EditableTable`**,不改进、不改写,回那一篇。
  其中 `PermissionMatrix` 属于 CONV-2 分类里的 **B(全行同时可编辑)**,
  不是 A —— 它是一屏勾选 + 一个页级「保存」,与 `/me` 同形,
  因此要用 `all-rows` 模式加 `footer` 槽(CONV-2 §⑧ 第 5 条)。
  **本刀没有转它**,把这个判断留在这里,免得下一刀重新分类。

---

## ② ★★ (a)/(b)/(c) 的裁定:**(b) —— 一个新组件,不是第三套模板** ★★

委托要求在转换任何一页之前先答这道题,并且「除非证据逼着,否则推荐 (a) 或 (b)」。

**答案是 (b),而它由两个量出来的事实撑着:**

### 为什么【不是】(c) 第三套模板

**外壳的契约一处都没有破。** 详情页要的东西 `ListPage` 全都已经有:
守卫 → 整页拒绝(`state:'restricted'`)、标题、动作、无条件话语(`notices`)、
容器宽度。而子表要的东西 `DataTable` / `EditableTable` 也全都已经有 ——
`render: (row) => ReactNode` 原样容得下详情页格子里那些副标签、徽章、链接、
甚至一个会写库的控件(§④)。

CONV-2 分岔是因为**渲染契约真的伸不过去**(只读的 `render` 没有地方存放行编辑态);
CONV-3 拒绝为「勾选」分岔是因为**一个 prop 就够**。同一条判据用在这里:
**没有任何一件详情页要做的事,是现有契约表达不了的。**

### 为什么【不是】(a) 什么都不建

**那个「记录抬头」今天有 25 张页面在写,而它们是【四种不同的写法】:**

| 写法 | 处数 |
|---|---:|
| `flex flex-wrap gap-x-8` 的一排 标签:值 | 17 |
| `bg-gray-50 rounded p-4` 的一块面板 | 19 |
| `grid grid-cols-N` | 12 |
| `<dl>` | 5 |

(一页可以同时命中几种,所以列和大于 25。)

同一样东西四种写法,而本仓库对「同一个形状第三次出现」的处置是把它收敛掉 ——
`DataTable` 的 `rowClassName` 是**第 5 处**才建的(CONV-4 §⑨-3)。**25 处远过了那道坎。**

不建它的代价不是「多写几行」,而是**抬头会被塞进 `notices` 槽** ——
而 CONV-2 §⑧ 第 2 条已经点名那个槽正在替两样别的东西站岗(子导航、二级标题)。
**再加一样,它就是第三个了。**

### 于是本刀建了【两样】,而第二样是一个 prop 不是一个组件

1. **`app/components/ui/record-header.tsx`** —— 见 §③。
2. **`ListPage` 多一个 `breadcrumb` 槽** —— 画在标题【之上】。
   **37 张详情页里 23 张**今天把返回链接画在 `<h1>` 之上,全仓库 58 张 page.tsx
   用着 `common.back`。塞进 `notices` 能跑,但那会把链接挪到标题下面 ——
   一次版式回归,而 CONV-5 §⑩-9 已经为「外壳硬编码 `p-8`」记过两次同类的账。
   **不给就不画,64 个既有 `ListPage` 调用点一个字都不用改。**

---

## ③ `RecordHeader`:只管盒子,而且【不是】客户端组件

```tsx
<RecordHeader
    fields={[{ label, value, mono? }, …]}
    actions={<ReverseButton … />}       // 可选
/>
```

### 只收到【盒子】为止 —— 与 CONV-3 的 `AddRowPanel` 逐字同一条判据

25 张抬头的字段**逐页不同**(分录是 单号/日期/来源/状态;采购单是
供应商/日期/交期/币种/贸易术语/状态/总额;字段数 2–8,格子里有徽章、有链接、
有 `MaskedValue`)。**把字段也收进来,会逼这个组件去认识二十五种记录形状** ——
那正是 `editable-table.tsx` 抬头拒绝对 `DataTable` 做的事,换了个更小的场景。

### ★ 它留在服务端,于是「详情页多一个文件」这件事**只由有表的那一半承担** ★

CONV-1 §① 记下那个没人算过的代价:`Column.render` 是**函数**,RSC 传不过客户端
边界,所以**每一张只读列表页都要多一个客户端文件**(129 个)。
**`RecordHeader` 的 props 全是数据与 ReactNode,一个函数都没有**,所以它是
服务端组件,页面直接在 `page.tsx` 里用。

**后果是可以算的:** 2 张纯抬头的页面(0 张表)与 22 张只有 1 张表的页面里,
抬头这一半的新文件成本是 **0**。

### 动作是一个具名槽,不是一个字段

列表页的出口是筛选栏/新建钮;**详情页的出口是这条记录的动作**(冲销、取消、
批准、重开)。实测它们今天就住在抬头那一块里(`/finance/journal/[id]` 的
`<ReverseButton>` 就在抬头 `div` 内)。混进 `fields` 会让一个**动作**被当成一个
**值**排版,并且在手机上跟着字段一起换行。

---

## ④ ★ 「只读表 + 格子里一个写库控件」仍然是 `DataTable`(Tim 的 Q3) ★

`/purchasing/orders/[id]` 的明细行表里挂着 `DeepDischargeJudgementControl`,
付款计划表的最后一列是 `ExpectedDateControl`(一个直接写库的 `<input type="date">`)。
**而两张表的其余部分是彻底只读的。**

**裁定:走 `DataTable` 的 `render`,不升级成 `EditableTable`。**

**理由:`EditableTable` 存在的三件事 —— 行级编辑态、脏值追踪、逐行保存 ——
这两个控件【自己全都有】。** 再套一层意味着两个状态机同时管一行,
而 `EditableTable` 还会在类型上禁掉排序与分页(CONV-2 §②d)。
与 CONV-3 把「勾选」做成一个 prop 而不是第二个组件,是同一条判据的同一个答案:
**这个改动会不会污染只读那条路?不会 —— `render` 一个字都不用改。**

---

## ⑤ ★★ 详情页的 `state` 恒为 `'ok'`,而这【不是】一个权宜之计 ★★

> **一条记录存在与否由 `notFound()` 回答,不由空态回答。**
> 页面画得出来就说明这条记录在;空的只可能是它下面某一张子表,
> 而那句空态归**那张表自己**说(`DataTable` / `EditableTable` 的 `empty` prop)。

CONV-3 §⑧-2 为 Kind-E 定下「恒为 ok」时,理由是**出口住在 children 里**;
CONV-4 §⑨-4 与 CONV-5 §⑩-3 把它推广到筛选栏、子导航、设置面板,共 15 张页面。
**详情页把它变成了一条结构性的事实而不是一次逐页的判断:**
`empty` 这一支在详情页上**根本没有主语**。

**于是委托点名要逐页检查的那一类(「出口被空态吃掉」的详情页版本)
在这套形状下【构造上不可能发生】** —— 因为那个会吃掉 children 的分支永远不成立。
本刀仍然逐页看过 37 张的动作清单(冲销 / 取消 / 批准 / 重开 / 收货 / 修改 /
签发 / 导出),**没有一处的唯一出口住在一个会被隐藏的分支里**。

☞ 推论,写给下一刀:**详情页不要用 `state:'empty'`。** 要用的只有两支:
`'ok'`(记录在)与 `'restricted'`(你进不来)。

---

## ⑥ 手机:★ 元凶【多数不是表】—— 而这一条是量出来的,不是引用来的 ★

委托的原话是「A DETAIL PAGE'S PHONE PROBLEM IS PROBABLY THE HEADER, NOT THE TABLE」。
**实测把它证实了,而且比那句话更强。**

30 张可测详情页里 **9 张溢出**,探针逐张点名了元凶:

| 溢出 | 页 | 元凶 | 是表吗 |
|---:|---|---|---|
| +664px | `/inventory/output/[materialId]` | `span.px-2 py-1 bg-gray-200 rounded text-xs` | **不是** |
| +506px | `/inventory/inbound/[materialId]` | 同上(一枚徽章) | **不是** |
| +204px | `/hr/payroll/[id]` | `th.…text-right` | 是 |
| +123px | `/finance/invoices/[id]` | `a.text-blue-600` | **不是** |
| +99px | `/finance/receivables/[saleId]` | `button.text-red-600` | **不是** |
| +65px | `/operation/orders/[id]` | `span.text-amber-700` | **不是** |
| +35px | `/finance/expenses/[id]` | 状态药丸 `span` | **不是** |
| +30px | `/finance/payables/[batchId]` | `th.…text-left` | 是 |
| +4px | `/finance/credit-notes/[id]` | `th.…text-right` | 是 |

> **9 张里 6 张的元凶不是表。`DataTable` 只管表,所以它一张都修不了那 6 张。**
> 那 6 张的元凶(徽章、药丸、链接、按钮)**正是住在记录抬头里的东西** ——
> 这就是 `RecordHeader` 在构造上不许顶宽的理由(`flex-wrap` + `min-w-0` +
> `break-words`),也是 CONV-5 在 `/settings/deleted` 上撞见那 27px 的同一族。

### ★★ 先做 tableCount 交叉核对 —— 而这一次盲区是【四成】 ★★

按 CONV-3 §④ / CONV-5 §⑩-14 的规矩,引用可用度之前先看表画出来没有:

| | 张数 |
|---|---:|
| 37 张详情页 | 37 |
| **探针【根本测不了】**(没有活数据行 / 没有 id 来源映射) | **7** |
| 测了,但 **`tableCount = 0`**(表一次都没画出来) | **12** |
| **真正量到过一张表的** | **18** |

**那 12 张【全部】被探针记成 usable** —— 一张没有画出来的表既不会溢出、
也不会被裁。所以这一刀的数必须分两行写:

| | |
|---|---:|
| 探针自己报的 USABLE(U1 ∧ U2) | **21 / 30** |
| 其中【表根本没画出来】的 | **12** |
| **真正量到过一张表、且可用的** | **9 / 18** |

**7 张连测都测不了,是比 CONV-5 那个盲区【更前面】的一个盲区** ——
CONV-5 记的是「表没渲染」,这里还有一层「这条路由压根拿不到 id」。
逐条列出,留给下一刀(修法是给 `smoke-routes.mjs` 的 `ID_SOURCES` 补映射,
或者承认那张表今天没有活数据):
`/finance/ledger/[account]` · `/finance/packs/[id]` · `/hr/attendance/[id]` ·
`/hr/claims/[id]` · `/hr/leave/[id]` · `/hr/reviews/[id]` · `/my-reviews/[id]`

### 本刀转的两页:探针 id 与 tableCount 都写出来

| 页 | 探的哪一行 | tableCount | 溢出 | 裁切 |
|---|---|---:|---:|---:|
| `/finance/journal/[id]` | `bc3b3db0-5b34-49d9-a6f9-9cd8923237ed` | **1**(应为 1 ✓) | 0 | 0 |
| `/purchasing/orders/[id]` | `861fe74b-14d8-45f7-992c-92aa9aaaac90` | **3**(应为 3 ✓) | 0 | 0 |

**两张都真的画出来了,所以这两个 0 是可以引用的。**

---

## ⑦ ★★ 转换照出一个【闸的洞】,而它是被本刀自己的注释触发的 ★★

故障注入(拿掉 `PoLinesTable` 全部 `priority: true`)时,
**`check-datatable-phone.mjs` 仍然 EXIT 0,并且报「各自至少一列 priority」。**

**原因:** 那道闸的判据是

```js
const declIdx = src.search(/(const|let)\s+columns\b/)   // ← 找【文本】里第一处
const decl = src.slice(declIdx, declIdx + 20000)
if (!/priority:\s*true/.test(decl)) { …报错… }
```

而 `PoLinesTable.tsx` 的**抬头注释里正好写着**「闸找的是 `const columns` 的声明
文本里有没有 `priority: true`」—— 于是:

1. `declIdx` 落在**注释里**(偏移量 558),不是那个真的声明上;
2. 紧接着的注释文字里又有 `priority: true` 这几个字;
3. 判据通过 —— **而那张表一列 priority 都没有。**

> **它不会变红,它会安静地少查一张表** —— 正是本仓库反复付账的那种失败。
> 而 `tsc` 在同一格是 **EXIT 0**(类型没有办法要求「数组里至少一个元素某字段为 true」),
> 所以**没有任何别的网兜得住它**。

### 修了,因为这是同一个病的【第三次】

| | 闸 | 怎么被散文骗过去的 |
|---|---|---|
| ① | `check-masked-reads` 的内嵌扫描 | 没剥注释,**恰好漏掉了被拿来当例子的那个文件** |
| ② | `check-permission-predicate`(CONV-5 §⑩-12) | 正则只认单/双引号,反引号模板串隐形 |
| ③ | **本处** | 注释里的 `const columns` 冒充了声明 |

`AGENTS.md` 的门槛是「同一个形状撞第二次,就不再写注解,而是换成机制」。
**处置:定位声明与检 priority 之前,先把注释抹成空格。**
**抹成空格而不是删掉** —— 删掉会让后面所有偏移量位移,而 `lineOf()` 与
`propsBlockAt()` 都按偏移量工作,点名的行号会集体错位。
**一道报错行号的闸,报错了行号比不报错更难查。**

### 故障注入(先红、点名、再逐字节还原)

```
A 干净树      → EXIT 0 · 89 个调用点(DataTable 86 · EditableTable 3)
B 拿掉全部 priority:
    tsc                   → EXIT 0   ← ★ 类型看不见这一种,这正是闸存在的理由
    check-datatable-phone → EXIT 1
      app/purchasing/orders/[id]/PoLinesTable.tsx:188   ← 真行号,抹注释没有让它错位
C 还原        → shasum 逐字节相同(c6cfea0e…)· EXIT 0 · 仍然 89
```

**补上这个洞【没有照出任何别的东西】** —— 修好之后干净树仍然是 89 个调用点、
0 处问题。也就是说它是一个**潜伏的**洞,不是正在遮着别处的缺陷。

### 调用点计数:两条独立路径对上了

| | DataTable | EditableTable | 合计 |
|---|---:|---:|---:|
| CONV-5 收尾 | 82 | 3 | 85 |
| **本刀之后** | **86** | 3 | **89** |

**+4 = 本刀新建的 4 张表**,与 `grep` 独立复核**逐字相符**。

> ★【复核的第一版是错的,而错法值得记】★
> `grep -rn "<DataTable\|<EditableTable"` 得到 **94**,与闸的 89 差 5。
> 差的不是漏查,是**我的判据问了另一个问题**:那 5 处是**注释散文里**提到的
> `<DataTable>`(以及类型位置的 `<DataTableProps`)。
> 用闸自己的正则(带 `(?=[\s\n<])` 前瞻)重数,得到 **86 / 3 / 89**,逐字相符。
> **两条独立路径给出同一个数,这个数才可以引用。**

---

## ⑧ 分组/小计能力:**本刀新增 0 处,总数仍然是 5 处 / 2 种形状**

按委托要求数了,没有建。37 张详情页里**带分组表头行 + 组内小计的表:0 张**。
(机械扫 `groupBy` / `group_by` / `groups` 惯用法:37 张全 0;逐张复核过
带「合计」字样的页面,全部是**表尾的一行总计**或**表外的一个数字**,
不是组内小计。)

**所以那个悬着的能力仍然停在 CONV-4 §⑨-2 量到的 5 处、2 种形状,一处都没有增加。**
Tim 在 CONV-5 Q3 的裁定原样成立,不必重新决定。

### 而 `<tfoot>` 是另一件事,它增加了

**9 张详情页带 `<tfoot>` 表尾合计,共 18 处。** `DataTable` 没有表尾概念。
Tim 在本刀 Q4 的裁定:**沿用 CONV-4 §⑨-3 的写法(合计行当数据塞进 `rows`,
带 `isTotal`,用 `rowClassName` 加粗),不给 `DataTable` 加 `footer` 槽。**

> **理由是【一种东西一个写法】:** 合计已经有一个能用的表达方式,再加一个
> 只会让两种写法同时活着。数字(9 页 / 18 处)记在这里,
> 将来真要建 `footer` 槽时不必重数。

**代价照直写:** 合计标签不再紧贴数字右对齐(转换前是 `colSpan={5}` 顶到右边),
而是落在**名称列**。`/purchasing/orders/[id]` 的三行合计(净额 / 税额 / 含税总额)
就是这样。**这是本刀唯一一处看得见的版式让步**,列进人工走查清单。

---

## ⑨ 一页长什么样 —— `/finance/journal/[id]`(给不打开浏览器的人看)

* **桌面。** 标题上方一行「← 返回」(新的 `breadcrumb` 槽);标题「分录详情」;
  两条冲销关系横幅(有才画,走 `notices`);然后是**记录抬头**——
  一块浅蓝底、圆角、描边的盒子,里面横排四项:
  编号(等宽)· 日期 · 来源(可点)· 状态(绿/灰药丸),
  **而「冲销」按钮收在这一排的最右边**(`actions` 槽,`ml-auto`)。
  抬头下面是摘要那一句,再下面是 5 列的行表(科目 · 借 · 贷 · 原币 · 行摘要),
  **最后一行是加粗的合计行,底色与表头同族。**
* **手机(390px)。** 抬头**换行**成两三排,不横向滚动(`flex-wrap` + `min-w-0`)。
  表里留三列:**科目 · 借 · 贷**;原币与行摘要进展开区。
  **留三列而不是两列是一个判断:** 一条分录行只说「科目 + 金额」不成话 ——
  同一个数字在借方与在贷方是相反的两件事,留一列会逼人展开每一行才知道方向,
  而那正好毁掉 `DataTable` 抬头说的「顺着一列往下比」。
  **实测 0 溢出、0 裁切**(§⑥)。
* **进不去。** 没有 `module.finance.view` 的人在任何查询【之前】就被
  `requireModule` 挡住,看到 CONV-0 的整页拒绝。
* **记录不在。** `notFound()` —— **不是**一句空态。见 §⑤。

---

## ⑩ 本刀做了多少,以及【没有】做什么

**转了 2 页**(委托允许「两到三页」),而其中一页是委托点名必须撞的最坏情况。

| | |
|---|---:|
| 转换的页 | **2**(`/finance/journal/[id]` · `/purchasing/orders/[id]`) |
| 新建共用件 | **1**(`record-header.tsx`)+ `ListPage` 的 `breadcrumb` 槽 |
| 新建的每页客户端表文件 | **4** |
| 新增 `<DataTable>` 调用点 | **4**(85 → 89,两条路径复核) |
| 闸的修补 | `check-datatable-phone.mjs` 加 `blankComments()`(§⑦) |
| 新增 i18n 键 | 3(`finance.noJournalLines` · `purchasing.noLines` · `purchasing.noPaymentTerms`) |

### `/purchasing/orders/[id]`:最坏情况撞过了,**能转**

委托说「如果它转不了,那本身就是发现」。**它转得了**,而过程照出四样东西,
逐条记在 `PoLinesTable.tsx` 抬头:条件列(设备单没有计价公式那一轴)、
三行 colSpan 合计、格子里的写库控件、格子里带颜色的副标签。
**`DataTable` 的契约一个字都没有改。**

> ★【一处必须更正的继承数字】★ 委托(与 PAGE-0)记它是 **1745 行**。
> 今天它是 **1036 行**(`wc -l`),转换后 **1183 行**(多出来的是三张表的行数据
> 在服务端压平的那段);它那个目录合计 2639 行。
> **1745 这个数在今天的树上对不上任何一个口径** —— 它仍然是全仓最大的 `page.tsx`
> (第二名 `/operation/processing/[id]` 768 行),那句话是对的,只是那个数字过期了。

### 没有做的,逐条

1. **另外 35 张详情页没有转。** 分类做完了(§①),按 import 建的清单在本文件,
   下一刀不必重量。
2. **9 张可编辑页里一张都没转** —— 它们归 CONV-2 的模板,而本刀的预算花在了
   证明外壳 + 抬头 + 最坏那张表上。`PermissionMatrix` 属于 B(all-rows)
   这个判断已经做完,写在 §①。
3. **`loading.tsx` 一个都没建**(Tim 本刀 Q2)。`.from()` 计数说 22 张够格,
   **但那是一个会高估的代理**:37 张里 22 张用 `Promise.all`,并行往返不是串行深度。
   全仓库今天只有 **1 个** `loading.tsx`(`/inbound`),而 CONV-1 记的是「28 页够格」——
   **那 28 页从来没有被建出来过**,这本身是一个没人记下的缺口。
   真要建,先做一次**真的串行深度**测量,不要用 `.from()` 计数。
4. **分组/小计能力没有建**,也不该建 —— 本刀新增 0 处(§⑧)。
5. **`ListPage` 的边距槽**(CONV-5 §⑩-9 记的两处 `p-8` 回归)没有动。

---

## ⑪ 只有人能确认的事

见 `docs/manual-walk-list.md` §29。**一处都还没有人走过。** 最要紧的三条:

1. **`/purchasing/orders/[id]` 的三行合计**现在落在【名称列】而不是紧贴数字右侧(§⑧)——
   读起来是不是还认得出那是合计?
2. **记录抬头在 390px 上换行之后**,那一排「标签:值」还读得成话吗?
   动作钮(`ml-auto`)换行之后落在哪儿?
3. **`/finance/journal/[id]` 手机上留了三列(科目/借/贷)**而不是两列(§⑨)——
   三列在 390px 上会不会太挤?**闸测得出「有没有声明」,测不出「留下来的是不是对的那几列」。**

---

# ⑫ CONV-9(2026-09-04)· 19 张详情页 —— 而【委托对那道表尾槽的记述是反的】

**基线:** HEAD `baeba16`(CONV-8),树干净。**转了 19 张,还剩 16 张。**

## ⑫-0 ★★ 头条:委托说「`DataTable` 的 footer 槽现在有了」——它【没有】★★

**这是在转换任何一页【之前】量出来的,而它改了这一刀的前提。**

委托原文:「The DataTable footer slot exists now (CONV-8, after Tim overrode the
isTotal-row idiom at 9 pages / 18 rows). Use it for grand totals. CONV-4's two
isTotal pages were migrated onto it, so the old idiom should be GONE — if you find
it surviving anywhere, that is a finding, report it.」

**逐条实测:**

| 委托说 | 树上实际是什么 |
|---|---|
| `DataTable` 有 `footer` 槽 | **没有。** `grep -n "footer" app/components/ui/data-table.tsx` → 0 行 |
| 那个槽是 CONV-8 建的 | `footer` 槽属于 **`EditableTable`**(`editable-table.tsx:163`),CONV-2 建的,用途是 `all-rows` 模式下页级提交 |
| CONV-4 那两页已迁走 | **没有迁。** `revaluation` 与 `assets` 今天仍然是 `isTotal` |
| 旧写法应该消失了 | **它是现行写法**,落地时 3 张表在用 |

**而 CONV-8 §⑧ 白纸黑字记着相反的裁定:** Tim 在那一刀的 Q4 说的是
**沿用 `isTotal` + `rowClassName`,不给 `DataTable` 加 footer 槽**,理由是
「一种东西一个写法」;而委托引用的「9 页 / 18 处」**正是 CONV-8 用来支持
【不建】的那个测量**。

> **处置:照文档里那条裁定办,不建。**
> 委托描述的那个世界不存在,而「9 页 / 18 处」这个数一个字都没变 ——
> **Tim 拍板时手里就是这个数,所以没有任何新证据要求重开它。**
> 本刀新增 6 处 `isTotal`,连同代价(合计标签落在第一个 priority 列,
> 不再紧贴数字)一起记在 `manual-walk-list` §30.2。

## ⑫-1 CONV-8 的分类:**抽查确认,而人口是 28 + 7,不是 26 + 9**

委托说「35 张里 9 张可编辑」。CONV-8 §① 的**正文写 9,而它自己那张表只列出 8 页**
(`GoalsEditor` 挂两页,所以 7 行 = 8 页),其中 `/purchasing/orders/[id]`
**已经被 CONV-8 转过、而且裁定留在 `DataTable`**。

    35 = 28 只读 + 7 可编辑
    7 = /finance/invoices · /hr/attendance · /hr/reviews · /my-reviews
        · /logistics/containers · /sales/quotes · /settings/roles

**抽查用的是【独立重算】,不是复读:** 按 import 闭包(排除 `app/components/**`
共用件)逐页数表 —— **35 页 56 张表**,而 CONV-8 记的是 37 页 60 张、
已转的两页占 4 张。**56 = 60 − 4,逐字对上**;分布也逐格对上
(0 张→2 页 · 1 张→22 · 2 张→6 · 3 张→5 · 4 张→1 · 7 张→1)。
**两条独立路径给出同一个数,所以 CONV-8 的普查可以引用。**

> ★【抽查的第一版判据是错的,而它错成了 CONV-8 警告过的那个样子】★
> 第一版扫「import 闭包里有没有 `<input|select|textarea>`」,得到 **24 页**可编辑。
> 那正是 CONV-8 点名「产生过三次错数」的那个「出现在任何地方」判据 ——
> 逐页打开之后,`/finance/assets/[id]` · `/logistics/forwarders/[id]` ·
> `/operation/processing/[id]` · `/sales/customers/[id]` 等 5 页
> **全部是「只读表 + 表【下面】一张新增表单」**,输入一个都不在 `<td>` 里。
> **判据要问的是「格子里」,而不是「文件里」。** CONV-8 的 8 页站得住。

## ⑫-2 转了哪 19 张(附:一张【刻意不转】)

| 模块 | 页 |
|---|---|
| finance(11,全部只读页转完) | `credit-notes` · `freight` · `payments` · `payables` · `receivables` · `expenses` · `bank/statements` · `ledger` · `packs`(只套外壳)· `gst` · `assets` |
| hr(4,全部只读页转完) | `payroll` · `claims`(0 张表)· `leave` · `employees` |
| inventory(2) | `inbound/[materialId]` · `output/[materialId]` |
| 其余(2) | `sales/shipments` · `tools/tasks` |
| **共用件(1)** | **`FinanceAttachmentsPanel`** —— 见 ⑫-5,它一处修好四页 |

**`/inbound/receive/done/[id]` 刻意没有转**,理由写在那一页的抬头:
它是 37 张里**唯一一张本来就照 390px 设计的**(`p-4 max-w-md mx-auto text-center`、
48px 触控目标、居中的大字批次号)。`ListPage` 的 `<h1>` 是左对齐、住在一个
`justify-between` 里的 —— 套上去会把这一刀要修的病亲手造出来。
**这不是漏转,是 CONV-3 §⑧-3「没有形状匹配不硬套」的一个新形状:
被拒绝的是【外壳】那一半,不是表那一半。**

## ⑫-3 ★ 建了一个槽:`ListPage` 的 `padding` —— 而逼着建它的是【方向】,不是数量 ★

CONV-5 §⑩-9 量到 2 处外壳硬编码 `p-8` 造成的回归,按「第三次才建」搁置。
**本刀在 35 张里一次量到 5 处**(合计 7 处):

    p-6            /finance/assets/[id]
    p-4 sm:p-8     /inbound/[id]/assays/[assayId]
    p-4 sm:p-8     /output/[id]/assays/[assayId]
    p-4 sm:p-8     /stocktakes/[id]
    p-4 …          /inbound/receive/done/[id]

**其中 3 处写的是 `p-4 sm:p-8` —— 它们【已经是为手机调过的】。**
硬套 `p-8` 会在 390px 上**各夺走 32px 可用宽度**,而这一刀的全部目的
正是量并改善手机可用度。**那不是"一处可接受的版式让步",
那是这一刀亲手制造出它自己要修的那个病。**

槽是一个可选 prop,不给就是 `p-8` —— **64+ 个既有调用点一个字都不用改**,
与 CONV-8 的 `breadcrumb` 槽逐字同一条判据。

## ⑫-4 ★ 一个形状收敛了:结算历史表,而它是【第三次】出现 ★

`/finance/payables/[batchId]` · `/finance/receivables/[saleId]` ·
`/finance/expenses/[id]` 三页的「结算历史」**逐列相同**
(付款单 · 日期 · 冲销额 · 状态,同一批 i18n 键,同一条「已冲销的行留下但不计入
已结额」的规矩)。收进 `app/components/finance/SettlementHistoryTable.tsx` ——
**`FinanceAttachmentsPanel` 就在隔壁,同样被这几页共用**,所以这一族的住址是现成的。

> **这不违反「第三次才建」那道坎 —— 那条坎管的是【设计一个新能力】。**
> 这里没有任何设计:同一个组件、三个调用点。**把它抄三份才是要付账的那件事。**

☞ 顺带一条计数规矩(CONV-5 §⑩-5 已有,这里再验一次):
**它是【一个】调用点,被三页渲染。闸数的是调用点,不是渲染次数。**

## ⑫-5 ★★ 手机:**先说探针的数,再说真的量到过的数** ★★

**19 张里只有 11 张是真的量到过的,而探针会说 15 张全好。**

| | |
|---|---:|
| 本刀转的页 | **19** |
| 全跑里根本没被探到(`unresolved`,无活数据行/无 id 来源) | **4** — `ledger/[account]` · `packs/[id]` · `hr/claims/[id]` · `hr/leave/[id]` |
| 探到了,而**页面根本没画出来**(见下) | **3** — `hr/employees/[id]` · `tools/tasks/[id]` · `bank/statements/[id]` |
| 探到了,页面画出来了但**这一页今天没有表**(设计如此) | **1** — `freight/[id]`(出境单据走具名缺席那一句,不画表) |
| **真正量到过一张表的** | **11** |

| | |
|---|---:|
| 探针自己会报的 USABLE | **15 / 15** |
| **真正量到过一张表、且可用的** | **11 / 11 · 0 溢出 · 0 裁切** |

**11 张逐页(探的哪一行 / tableCount):**

| 页 | 探针 id | tc | 溢出 | 裁切 |
|---|---|---:|---:|---:|
| `/finance/assets/[id]` | `c20e3ba1…` | 3 | 0 | 0 |
| `/finance/credit-notes/[id]` | `a4d827ce…` | 1 | 0 | 0 |
| `/finance/expenses/[id]` | `cc8e30c5…` | 2 | 0 | 0 |
| `/finance/gst/[periodId]` | `a08fd421…` | 1 | 0 | 0 |
| `/finance/payables/[batchId]` | `065622f9…` | 2 | 0 | 0 |
| `/finance/payments/[id]` | `bcc4c794…` | 2 | 0 | 0 |
| `/finance/receivables/[saleId]` | `9c4da4e2…` | 2 | 0 | 0 |
| `/hr/payroll/[id]` | `b3784931…` | 1 | 0 | 0 |
| `/inventory/inbound/[materialId]` | `5d4c059f…` | 1 | 0 | 0 |
| `/inventory/output/[materialId]` | `5d4c059f…` | 1 | 0 | 0 |
| `/sales/shipments/[id]` | `6256bcb7…` | 1 | 0 | 0 |

**对照 CONV-8 §⑥ 的基线,本刀修好的:**
`/hr/payroll/[id]` **+204px → 0**(元凶是表,`DataTable` 正好管这一种)·
`/finance/expenses/[id]` +35px → 0 · `/finance/payables/[batchId]` +30px → 0 ·
`/finance/credit-notes/[id]` +4px → 0 · `/finance/receivables/[saleId]` **+99px → 0**(见下)。
**没有一张从可用变不可用。** finance 模块整体 **43/53 → 44/53**
(两跑逐条对拍,差异【只有】`receivables/[saleId]` 一条)。

### ⑫-5a ★ 「元凶不是表」要读细一点:**一枚徽章可以【既是】徽章【又在】表里** ★

CONV-8 §⑥ 记「9 张溢出页里 6 张的元凶不是表,所以 `DataTable` 一张都修不了」。
**探针点名的那个元素每一次都是对的;错的是把它直接读成「不在表里」。**

* `/inventory/output/[materialId]`(+664px)与 `/inventory/inbound/[materialId]`
  (+506px)的元凶 `span.px-2 py-1 bg-gray-200 rounded text-xs`
  **住在这两张表的「状态/阶段」那一格里**。它不是 priority 列,
  于是 390px 上整格进展开区,徽章跟着走 —— **`DataTable` 够得着它。**
* `/finance/receivables/[saleId]`(+99px)的元凶 `button.text-red-600`
  **住在一个【四页共用的组件】里**(`FinanceAttachmentsPanel`),
  不是那一页自己的表。**修那一个组件,四页一起好。**
  实测:转换后该页 **+99px / 1 张被裁 → 0 / 0**,而同一跑里别的页一格没动。

**所以更准的说法是:元凶多数不是【那一页自己的主表】,
而那不等于它不在【某一张表】里,也不等于 `DataTable` 修不了它。**

### ⑫-5b ★★ 探针的第三层盲区,而这一层此前没人命名:**它把一张 404 记成「可用」** ★★

CONV-2 命名了「表没画出来」(`tableCount: 0`);CONV-8 命名了「这条路由压根拿不到 id」
(`unresolved`)。**本刀量到第三层,而它比前两层更难看见:
id 取到了、页面也返回了 200,但那是 `notFound()` 的 404 页。**

判据是现成的、而且尖锐:**全跑 189 条路由里,9 条动态路由的 `textLen`
【恰好都是 76】** —— 一字不差的同一个数,那就是 Next 的
"This page could not be found."。对比:真页面的 `textLen` 中位数是 **682**,最大 8467。

    76  /hr/employees/[id]        76  /hr/employees/[id]/edit
    76  /inbound/[id]/assays/[assayId]   76  /output/[id]/assays/[assayId]
    76  /logistics/containers/[id]  76  /logistics/forwarders/[id]
    76  /sales/customers/[id]     76  /sales/customers/[id]/edit
    76  /tools/tasks/[id]

**这 9 条【全部】被记成 USABLE** —— 一张 404 页既不溢出,也没有被裁的表。

**它不是"页面坏了":同一棵树上冒烟是 242 ok / 0 FAILED。**
两边各自取了一个不同的 id,而页面自己的查询把探针那一行滤掉了。
**也就是说:`ID_SOURCES` 回答的是「这张表里有没有行」,
而页面问的是「这一行,这一页收不收」—— 两个问题。**

> ☞ **修法留给一次专门的刀,不在这里顺手做**(CONV-5 §⑩-12 对反引号那个洞
> 用的是同一条克制):正确的信号不是 `textLen` 这个启发式,而是
> **让探针记下 CDP 那次导航的 HTTP 状态**。在那之前,读这份数的规矩多一条:
> **先看 `tableCount`,再看 `textLen`,最后才看 U1/U2。**

## ⑫-6 分组/小计能力:**本刀新增 0 处,总数仍然是 5 处 / 2 种形状**

19 张转过的页里带「分组表头行 + 组内小计」的表:**0 张**。
逐张复核过带「合计」字样的页面,全部是**表尾的一行总计**(走 `isTotal`)
或**表外的一个数字**,不是组内小计。**Tim 在 CONV-5 Q3 的裁定原样成立,不必重新决定。**

## ⑫-7 出口检查(委托点名的那一类):逐页做过,**19 张全部通过**

判据用的是委托的形式:**这一页唯一能动手的地方,会不会住在一个被空态吃掉的分支里。**
详情页 `state` 恒为 `'ok'`(CONV-8 §⑤),所以 `children` 永远画 —— 但仍然逐页看了动作清单:

* **住 `actions` 槽(画在状态分支之前,天然安全):** 冲销(freight/payments/expenses)·
  对账工作台(bank/statements)· 改+过账(payroll)· 记培训+改(employees)·
  导出(packs)· 删除对账单 · 徽章。
* **住 `notices` 槽(必须无条件):** 假别子导航(`/hr/leave/[id]` —— CONV-5 §⑩-3
  点名的那一类)· 重新打开对账(bank/statements)· 各种冲销横幅。
* **住 `children`,靠 `state` 恒为 `'ok'` 撑着:** 签发 PDF(credit-notes/shipments)·
  上传凭据(四页)· 补挂客户(receivables)· 冲抵定金(expenses)· 申报/更正(gst)·
  批准/驳回(leave/claims)· 反过账(payroll)· 发起转正评估(employees)·
  任务那一页的五个出口。

**一处都没有出口住在会被隐藏的分支里。**
顺带修好一处**方向相反**的缺陷:`/hr/employees/[id]` 的绩效评估表
转换前整节写着 `{empReviews.length > 0 && …}`,**一份评估都没有时整节消失**
—— 而 PROBATION-1 早就把标题与那扇门拆出来过。现在表【无条件】画,
空态由表自己说,与 PROBATION-1 同向。

## ⑫-8 手机闸:调用点数【两条独立路径对上了】,而洞也重新注过一次

| | DataTable | EditableTable | 合计 |
|---|---:|---:|---:|
| CONV-8 收尾 | 86 | 3 | 89 |
| **本刀之后** | **108** | 3 | **111** |

**+22 = 本刀新增的 22 张表**,与独立重算(自己剥注释 + 闸那条带前瞻的正则)
**逐字相符**。⚠️ 复核不能用 `grep -E`:POSIX ERE 没有前瞻,`(?=…)` 那条会得到 **0**
—— 那是判据坏了,不是一个发现。

**故障注入(五格,先红、点名、再逐字节还原):**

```
A 干净树                        → EXIT 0 · 108 个调用点
B 拿掉 OutputBatchesTable 全部 priority:
    tsc                        → EXIT 0   ← ★ 类型看不见这一种,这正是闸存在的理由
    check-datatable-phone      → EXIT 1
      app/inventory/output/[materialId]/OutputBatchesTable.tsx:111
C 还原                          → shasum 逐字节相同(08ea5258…)· EXIT 0
D ★ 重演 CONV-8 自己那次「被注释骗过去」:
    拿掉全部真 priority,并在真声明【之上】种一句注释,
    里面同时写着 `const columns` 与 `priority: true`
                               → EXIT 1,仍然点名 :112  ← blankComments 是承重的
E 还原                          → shasum 逐字节相同 · EXIT 0
```

**D 那一格是本节最要紧的一行:** 它证明 CONV-8 §⑦ 补的那个洞**今天仍然是补着的**,
而且**新调用点确实被计入**(B 与 D 都精确点到本刀新建的那个文件)。

## ⑫-9 一页长什么样 —— `/hr/payroll/[id]`(给不打开浏览器的人看)

**挑它是因为它是 CONV-8 实测溢出的三张「元凶真的是表」之一(+204px)。**

* **桌面。** 标题上方一行「← 返回」;标题「工资明细」后面跟着月份(等宽灰字)与期间编号;
  标题右边是两个出口:「编辑」与「过账」(未过账时才有)。
  然后是**记录抬头**——一块浅蓝底、圆角、描边的盒子,横排:发放日 · 币种(等宽,带汇率)·
  状态(绿/琥珀药丸)· 关联分录(可点)· 来源说明。
  抬头下面是备注与那句「薪酬数据受限」,再下面是 6 列的明细表
  (员工 · 应发 · 个人公积金 · 公司公积金 · 其他扣款 · 实发),
  **最后一行是加粗的合计行**,底色与表头同族,右边还带一句「共 N 行」。
* **手机(390px)。** 抬头**换行**成三四排,不横向滚动。
  表里留两列:**员工 · 实发**;四个中间量进点开的展开区。
  **留「实发」不是随手挑的** —— CONV-5 §⑩-13 给 `/hr/payroll` 列表页挑的第二列
  就是「实发合计」(「这个月到底付出去多少」),这里是它逐行的版本。
  **实测 0 溢出、0 裁切(转换前 +204px)。**
* **一行都没有的期间。** 合计行**仍然画**(转换前的 `<tfoot>` 也是无条件的)——
  一个 0 行的期间要说出它的合计是 0,**那不是空,那是一个答案**;
  明细的空态由表自己说。
* **进不去。** 没有 `module.hr.view` 的人在任何查询【之前】就被挡住,看到 CONV-0 的整页拒绝。
* **记录不在。** `notFound()` —— **不是**一句空态。

## ⑫-10 本刀照出来、但【不属于本刀】的三处

1. **`MaintenancePanel` 的表 5 个 `<th>` 对 6 个 `<td>`** —— 资本化按钮那一列没有表头,
   表体比表头宽一列。`DataTable` 的契约要求每列都有 header,所以**本刀无法不修**
   (给了空字符串,视觉与转换前一致)。
2. **`scripts/currency-messages-baseline.json` 有 2 条【指向一个已经不存在的键】的记录**
   (`metalPricesDesc`,en/zh 各一)。检查自己会说「有人改好了,基线可以收紧」。
   **与本刀无关**(本刀的 diff 一个字都没碰它),但棘轮松着就不是棘轮 —— 本刀顺手收紧。
3. **`survey-phone` 与 `smoke-routes` 只共用了一半的 id 定义。**
   前者刻意 import 后者的 `ID_SOURCES`(避免两份漂开),
   而 `SPECIAL_ID_ROUTES`(4 条,含 `/finance/ledger/[account]`)**在那张表之外** ——
   于是冒烟测得了、探针测不了。**这是「一份定义」这个说法今天只成立一半。** 记而不建。

## ⑫-11 这一刀之后还剩什么(下一刀不必重量)

**16 张:9 只读 + 7 可编辑。**

**只读(9):**

| 页 | 表 | 备注 |
|---|---:|---|
| `/sales/customers/[id]` | 4 | 三个面板都是「只读表 + 表下面一张表单」 |
| `/operation/processing/[id]` | 7 | **全仓表最多的一页**;`CostPanel`/`LossPanel` 同上 |
| `/operation/orders/[id]` | 3 | |
| `/logistics/forwarders/[id]` | 2 | `ForwarderPanels` 同上 |
| `/output/[id]/assays/[assayId]` | 2 | 用得上新的 `padding` 槽(`p-4 sm:p-8`) |
| `/inbound/[id]/assays/[assayId]` | 1 | 同上 |
| `/stocktakes/[id]` | 1 | 同上;`CountList` **不是表**(移动端展开式录入清单),不要硬套 |
| `/sales/orders/[id]` | 1 | |
| `/inbound/receive/done/[id]` | 0 | **刻意不转,理由在那一页抬头** |

**可编辑(7,归 CONV-2 的 `EditableTable`):**
`/finance/invoices/[id]` · `/hr/attendance/[id]` · `/hr/reviews/[id]` ·
`/my-reviews/[id]` · `/logistics/containers/[id]` · `/sales/quotes/[id]` ·
`/settings/roles/[id]`。
**`PermissionMatrix` 属于 B(全行同时可编辑),用 `all-rows` + `footer` 槽**
—— CONV-8 §① 已经分类过,不必重来。
☞ 其中 `/finance/invoices/[id]` 今天实测 **+123px、2 张表被裁**,
元凶 `a.text-blue-600` —— 是这 16 张里唯一一张【已知不可用且量得到】的。

**三件留给设计时间,不留给下一刀"顺手做":**
1. **分组/小计能力**:仍然 5 处 / 2 种形状,本刀新增 0(⑫-6)。
2. **探针把 404 记成可用**(⑫-5b):修法是记 CDP 的 HTTP 状态,不是 `textLen` 启发式。
3. **`SPECIAL_ID_ROUTES` 不在共用的那张表里**(⑫-10 第 3 条)。

## ⑫-12 只有人能确认的事

见 `docs/manual-walk-list.md` §30。**一处都还没有人走过。**
最要紧的是 §30.1:**那 9 条 `textLen=76` 的路由,在有人真的打开之前,
它们的 390px 表现没有任何证据。**

---

# ⑬ CONV-10(2026-09-04)· 补 CONV-9 欠的三件 + 修那把尺 —— 而【尺坏在取 id,不在启发式】

**基线:** HEAD `f5441f0`(CONV-9),树干净。**本节记 §0 与 §1;转换记在 §⑭。**

## ⑬-0a CONV-9 那一轮提问:**记录【没有了】,而这句话本身是答案**

委托要求逐字复现 CONV-9 开工时那一轮问题。**逐处找过,一处都没有:**

| 找过哪里 | 结果 |
|---|---|
| `docs/detail-page-template.md` §⑫(CONV-9 自己的文档) | 只有「Tim 在 CONV-5 Q3 / CONV-8 Q4 的裁定」这类**回指**,没有本刀的提问 |
| `git log -1 f5441f0`(完整 commit message) | 没有问答段 |
| `docs/manual-walk-list.md` §30 | 只有走查项,没有提问 |
| 全仓 grep `Q1/Q2/Q3/Q4` | 命中的全部是 **CONV-5 / CONV-8** 的历史裁定 |

**所以:CONV-9 的提问轮没有留下任何记录。** 委托说「Tim 睡着了、一条都没看见」——
树上的证据与这句话一致:**那一轮如果发生过,它只发生在一次没有落盘的对话里。**
按委托的规矩,**不从记忆里重建**。

> ★【这一条要留成一条规矩,而不是一次抱怨】★
> CONV-8 的四个 Q 今天还读得到,**因为它把裁定写进了文档正文**(§④ 标题里就写着
> 「Tim 的 Q3」)。CONV-9 的读不到,因为它只把**结论**写进了文档,没写**问题**。
> **一个只记结论的文档,下一刀无法分辨「这是拍过板的」与「这是它自己决定的」** ——
> 而这一刀的 §⑬-0b 正好撞上这个分辨问题。
> 于是本刀把自己那一轮**连问带荐**写在 §⑭-0,不管 Tim 有没有回。

## ⑬-0b 转换顺序:**CONV-9 【照做了】,而委托这一次记错的是【排序键】**

委托问:既然「子表最多的模块优先」,为什么 7 张表的 `operation/processing`、
4 张表的 `sales/customers` 被留到最后?

**因为 CONV-9 拿到的排序键不是「子表最多」,是「详情页最多」——而那是两把不同的尺。**
按路由末段是 `[param]` 逐条数,**每个模块有几张详情页**:

    finance 13 · hr 6 · sales 4 · operation 2 · logistics 2 · inventory 2
    inbound 2 · tools 1 · stocktakes 1 · settings 1 · purchasing 1 · output 1 · my-reviews 1

**CONV-9 转的是:finance 的只读 11 张(全部)· hr 的只读 4 张(全部)· inventory 2 张
· 两张单页模块。** 那正是 **13 → 6 → 2** 的降序,**一格不差**。

而 `operation` 只有 **2 张**详情页 —— 按这把尺它排在倒数第四。
它「重」是因为 **`operation/processing/[id]` 一页上有 7 张表**,
即**每页的表数**最多,而那**不是** CONV-9 被给的那把尺。

> **结论:CONV-9 没有违反指令;是「模块里的页最多」与「一页上的表最多」
> 这两把尺在这份人口上【方向相反】。** finance 有 13 张页、但每页多是 1 张表;
> operation 有 2 张页、其中一张扛着全仓最多的 7 张表。
> **委托本刀用的是第二把尺(「留下的三个最重的」),这一次是对的 ——
> 因为剩下的 16 张里,页数已经不再区分得开谁先谁后。**

## ⑬-0c 出口检查:**19 张全查,0 处出口住在会被吃掉的分支里**

☞ **先更正一句委托的前提:CONV-9 【报过】这项检查** —— §⑫-7 白纸黑字,
逐页列了 `actions` / `notices` / `children` 三个槽的动作清单,结论 19/19 通过。
本刀**没有复读它**,而是**换一条独立的机械路径重算**。

**判据升级(而这一步抓到了 grep 抓不到的一处):**
第一版用 `grep '\.length.*&&'`,得到 5 处 —— 但它只认「`&&` 守卫」这一种形状。
改成**按括号栈解析**(收成 `scripts/survey-hidden-exits.mjs`,`npm run survey:exits`)之后,
每一个动作元素都被解析到它**真正的**外层条件,于是**三元的 else 分支也算在内**。

    19 页 → 34 个文件(含 CONV-9 抽出的子表组件)· 29 个文件带动作
    被「空集形状」的条件包住的动作:3 处

**三处逐条,全部无害 —— 而无害的理由三处相同:**

| 处 | 守卫 | 裁定 |
|---|---|---|
| `finance/payables/[batchId]:221` | `mustRows(journalsRes).length > 0` | 包住的只是**指向那些分录的链接**。没有分录 → 没有可指的东西。真出口 `FinanceAttachmentsPanel` 在守卫**外面**、无条件 |
| `finance/receivables/[saleId]:265` | `journals.length > 0` | 同上;真出口(发票链接 / 补挂客户)在外面 |
| `finance/credit-notes/[id]:181` | `issues.length === 0 ? … : …` | 三元的 **else** 分支列**已签发的历史版本**。真出口 `IssuePanel`(预览 / 签发 PDF)在三元**上方**、无条件 |

**一条共通的判据,值得写下来:**
> **守卫住「指向 X 的链接」而 X 不存在,不是藏出口 —— 那是不画一个死链。
> 藏出口是守卫住「创建 X 的按钮」。** 三处全部是前者。

> ★【为什么它是【普查】不是【闸】—— 而这是一次刻意的克制】★
> 它找到的形状**本身不是缺陷**(见下表:三处全部正确)。
> 一道**会对着正确代码变红**的闸,两刀之内就会被人加白名单绕过去 ——
> **那比没有这道闸更坏**,因为白名单会连同真缺陷一起盖住。
> 所以它印给人判,**不 exit 1**,也**不进 `npm run build`**。

**故障注入(先红、点名、再逐字节还原):**

```
A 干净树 → 3 处(全部已判无害)
B 把 /hr/leave/[id] 唯一的真出口 <DecideControls> 搬进
  {consumptionRows.length > 0 && …} 里
    → 4 处,点名 app/hr/leave/[id]/page.tsx:165
      guards: consumptionRows.length > 0@160          ← ★ 判据看得见这一种
C 还原 → shasum 逐字节相同(46ceb36d…)· 回到 3 处
```

**B 那一格证明的正是委托点名的那一类**:`/hr/leave/[id]` 的批准/驳回
如果住进那个分支,一张【没有消耗行】的假单就再也批不了 ——
而 CONV-9 把它放在守卫**外面**,还留了一句 `{/* ★ 出口:批准 / 驳回 */}`。

## ⑬-1 ★★ 那把尺修好了 —— 而病根【不是】启发式,是【取 id 少做了三件事】★★

CONV-9 §⑫-5b 把现象命名得很准(「探针把一张 404 记成可用」),
但它给的修法(「记 CDP 的 HTTP 状态」)只治**看得见**那一半。
**本刀量到的是【为什么会有 404】,而那一半更要紧:**

### 病根:两个 `firstId()`,一个做了四件事,另一个只做了一件

| | 冒烟 `smoke-routes.mjs:1186` | 探针 `survey-phone.mjs`(修前) |
|---|---|---|
| 选 id | `?select=id&limit=1` | `?select=id&limit=1` |
| **软删过滤** | `&deleted_at=is.null` | **无** |
| **按行过滤** | `ID_FILTERS`(tasks 必须 `task_type=eq.team`;forwarders 必须 `counterparty_type=eq.forwarder`) | **无** |
| **排序** | `&order=created_at.desc,id.desc`(+ 按表覆盖) | **无** |
| 父子配套 / 段里不是 uuid | `SPECIAL_ID_ROUTES` 4 条单独处理 | **无** |

而 `SOFT_DELETED` 里躺着 **`customers` · `employees` · `tasks` · `containers`** ——
**CONV-9 点名的那 9 条 `textLen=76`,一条不多一条不少地由这四张表 + 父子配套解释完。**

> **所以那句「探针和页面各取了一个不同的 id」说得太温和了:
> 是探针取的 id【这一页按定义不可能接受】。**
> 一行软删的客户,页面自己的查询一定把它滤掉,一定 `notFound()`。
> **这不是巧合,是必然** —— 而必然的东西不该用启发式去认。

### 修法:把那四张表【一起】读过来,与原来读 `ID_SOURCES` 同一条判据

`survey-phone.mjs` 原本就**刻意不抄** `ID_SOURCES`,而是运行时从冒烟里读
(注释写着「抄一份正是这仓库付过四次账的那个病」)。**它只是少读了四张。**
`loadIdSources()` → `fromSmoke(name)`,一个通用的括号配平提取器,
现在读 **5 样**:`ID_SOURCES` · `SOFT_DELETED` · `ID_FILTERS` · `ORDER_OVERRIDES` ·
`ORDER_DEFAULT`,外加 `specialUrl()` 复刻那 4 条特例。
读回来是空集就**当场炸**(「一个全 0 的测量结果要当成脚本坏了」)。

    · id filters from smoke: 27 soft-deleted tables · 2 row filters · 2 order overrides

### 结构性的锚:HTTP 状态,而这需要先修一个更基础的洞

委托要求「锚在结构上,不要锚在 textLen」。**做得到,但先得修 CDP 客户端本身:**
`class Cdp` 的 `onmessage` **只处理带 `id` 的命令回执,把【事件】整个丢掉**。
于是 `Network.enable` 一直开着,**却没有任何一行代码收得到 `responseReceived`** ——
CONV-9 只好去猜 `textLen`,**它没有别的办法**。加了 8 行事件分发之后,
`Network.responseReceived`(`type === 'Document'`)的 `status` 直接可读。

### 处置:**单独一桶,退出分母,并且【让整跑变红】**

* **不记成 usable** —— 一张 404 既不溢出也没有表可裁,记成 usable 是这份数里最坏的谎:
  **把「没量到」说成「量到了,很好」。**
* **不记成 FAILED-U1/U2** —— 一张 404 对这一页的手机表现**两个方向都不是证据**。
* **退出分母**,与 `redirected` 逐字同一条处置。
* **但整跑 EXIT 1**,并逐条点名路由与 URL。
  **理由:404 是【探针的缺陷】,不是这一页的属性。** 一个只在桶里躺着不叫的桶,
  下一刀照样没人看 —— **`unresolved` 那 4 条就是这么静静过去了一整刀的。**

### 故障注入(先红、点名、再逐字节还原)

```
A 干净树,--routes=/sales/customers/[id],/finance/journal/[id]
                              → 2 条都真的量到,EXIT 0
B 让 firstId() 对 /sales/customers/[id] 返回一个不存在的 uuid
                              → EXIT 1
     !! survey-phone FAILED: 1 route(s) returned HTTP >= 400.
        404  /sales/customers/[id]  ← /sales/customers/00000000-0000-0000-0000-000000000000
     measured: 1(而不是 2)—— 那一条【退出了分母】,没有被记成 usable
C 还原                        → shasum 逐字节相同(1658d78a…)· EXIT 0
```

**★ B 那一格正是 CONV-9 全刀的处境:** 修前的同一份代码,对同一个坏 id,
会印出 `ovf=0 clip=0`、把它算进 `USABLE 2/2`,**而且 EXIT 0**。

### 顺带解决的:`SPECIAL_ID_ROUTES` 与 `/finance/ledger/[account]`

CONV-9 §⑫-10 第 3 条记的「一份定义只成立一半」——**这一刀补齐了另一半**。
`/finance/ledger/[account]` 从「探针测不了」变成**第一次测得到**
(段里是科目号,从 `journal_lines` 反查一个真有分录的科目)。

    修前:50 条动态路由里 9 条静静地在测一张 404
    修后:那 9 条里 7 条测到了真记录 · /output/[id]/assays/[assayId] 诚实地
          报 unresolved(线上确实没有产出父的化验行,冒烟同样 SKIP 它)

## ⑬-1d ★★ 修好的尺回头量 CONV-9 的 19 张:**没有一张掉下来,而它自己的数报少了 4 张** ★★

CONV-9 报了两个数:探针会说 **15/15**,真正量到过一张表的是 **11/11**。

**用修好的探针重量(28 条一跑,`BASELINE_OWN_EXIT=0`):**

| | |
|---|---:|
| CONV-9 转的页 | **19** |
| 仍然 `unresolved`(线上零行,诚实的没有数据)| **3** — `packs/[id]` · `hr/claims/[id]` · `hr/leave/[id]` |
| 第一次解析得到,但带 `?mode=bs` 被重定向剥掉 → 退出分母 | **1** — `ledger/[account]` |
| **真的量到了** | **15** |
| **其中可用(0 溢出 · 0 裁切)** | **15 / 15** |

    finance/assets · bank/statements · credit-notes · expenses · freight · gst
    payables · payments · receivables · hr/employees · hr/payroll
    inventory/inbound · inventory/output · sales/shipments · tools/tasks
    —— 15 张,ovf=0 clip=0,一张不例外

**★ 这个 15/15 与 CONV-9 那个 15/15 是【同一个数、不同的内容】,而差别要说清楚:**
CONV-9 那 15 里有 **3 张是 404**(`hr/employees` · `tools/tasks` · `bank/statements`,
它自己诚实地归进「探到了、页面没画出来」那一桶,所以只敢认 11)。
**修好之后,这 3 张拿到真记录、真的画出来了、而且真的是 0/0** ——
再加上 `freight/[id]`(设计上就没有表)。**11 + 4 = 15。**

> **所以对 CONV-9 的裁定是:它的工作站得住,而它【低报了自己】。**
> 它不敢认的那 4 张,不敢认得有道理(当时确实没有证据);
> 现在有证据了,**它们是好的**。
> **一张也没有从可用变不可用 —— 修尺子没有推翻 CONV-9 的任何一条结论。**

## ⑬-1e ★★ 而修好的尺【照出了两张新的坏页】,两张都在本刀要转的 16 张里 ★★

    +133px · 2 张表被裁   /finance/invoices/[id]      culprit: a.text-blue-600
    + 90px · 0            /logistics/containers/[id]  culprit: button.bg-blue-600
    + 65px · 1 张表被裁   /operation/orders/[id]      culprit: span.text-amber-700

**`/logistics/containers/[id]` 此前【就在那 9 条 404 名单里】** ——
也就是说它一直是坏的,而旧尺子把它记成「可用」。
**这就是修尺子的全部回报:委托说「那个数分不出『活儿没用』和『尺子坏了』」——
现在分得出了,而答案是【两者都有一点】:CONV-9 的活儿是好的,尺子确实坏了,
而坏尺子藏起来的是【另外两张没人知道坏了的页】。**

☞ 顺带更正一个小数:委托记 `/finance/invoices/[id]` 是 **+123px**,
本刀实测 **+133px**。差 10px 的原因就是这一刀修的东西 ——
**两跑取的不是同一张发票**(修前无 `order`,PostgREST 按物理顺序返回)。

---

# ⑭ CONV-10 转换那一半 —— 而【转换第二次当场照出一个「列错位」】

## ⑭-0 ★ 本刀开工那一轮提问,连问带荐,不管有没有人回 ★

§⑬-0a 记下 CONV-9 那一轮没有留下记录。**所以本刀把自己那一轮写在这里。**
Tim 没有回;下面每一条都是**本刀自己按推荐答案办的**,而这句话本身就是要写下来的东西。

| # | 问题 | 推荐 / 实际怎么办的 |
|---|---|---|
| **Q1** | 探针那把尺:全修(补齐四张过滤表 + 记 HTTP 状态),还是只加 404 断言? | **全修。** 病根是取 id 少做三件事,只加断言等于给一个必然的现象加一个启发式。~40 行,远在 30 分钟的闸内。→ §⑬-1 |
| **Q2** | 404 怎么记?算 FAILED,还是单独一桶? | **单独一桶 + 退出分母 + 整跑 EXIT 1。** 一张 404 对手机表现两个方向都不是证据,所以不进 U1/U2;但它是探针的缺陷,所以必须叫。→ §⑬-1 |
| **Q3** | `/finance/invoices/[id]` 的可编辑网格**收在 `useState(false)` 后面**,探针从不点开它 —— 那 +133px 【不是】它。转换与测量是同一页上的两件事,做哪一件? | **两件都做,并且【分开报】。** 把转换说成"修好了那 133px"是假的。 |
| **Q4** | 委托说 CONV-9 没报出口检查、没报三个退出码 —— 实测两条都报了(§⑫-7 / commit message)。复读还是独立重算? | **独立重算,并且更正委托的前提。** 换括号栈判据,抓到 grep 看不见的一处。→ §⑬-0c |
| **Q5** | 修好的尺若把 CONV-9 的页降级,本刀修吗? | **修,量力而行。** 实测一张都没降级(§⑬-1d),这条没用上。 |
| **Q6** | 16 张排不完时先做哪些? | **先重后轻,但【已知坏的优先于已知好的】。** 见 §⑭-3 的实际取舍与偏离说明。 |

## ⑭-1 `/operation/processing/[id]` —— 全仓子表最多的一页,7 张全转

**这一页转换【前】就是 0 溢出 / 0 裁切。** 所以这次转换**不修任何手机缺陷**,
它买的是别的东西:空态由表自己说、手机列由每张表自己声明、7 张表说同一种话。
**一次不修任何东西的转换要说清楚它不修任何东西**,否则下一刀会以为它修过。

    5 张收进 ProcessingTables.tsx(差异 / 血缘 / 投入 / 产出 / 回收率)
    2 张就地转(CostPanel · LossPanel —— 它们本来就是客户端组件,不必多一个文件)
    闸:111 → 118,+7,与新建的 7 张逐字相符

**顺手修好的两处,都是【转换逼出来的】:**
1. **差异表转换前【没有表头】** —— 一张 5 列的无头表,靠读者数第几列是什么。
   `DataTable` 的契约要求每列都有 header,于是补上了五个真列名。
2. **`CostPanel` 与 `LossPanel` 的表转换前被空集守卫整个包着**
   (`{entries.length > 0 && …}` / `{rows.length === 0 ? <p> : <table>}`)——
   一条都没有时**整张表连同表头一起消失**。现在表无条件画,空态由表自己说。
   出口检查从 **3 处降到 0 处**(§⑬-0c 的判据,同一把尺)。

**手机上留哪两列(本刀拍板,请人推翻 —— 记进 manual-walk-list §31):**

| 表 | 列数 | 手机上留 | 理由 |
|---|---:|---|---|
| 工单差异 | 5 | 料 · 差异 | 差异是这张表的主语,赶进展开区等于把表的意思拿掉 |
| 血缘 | 4 | 被耗批次 · 耗用量 | |
| 投入 | 3 | 投入批 · 耗用量 | 「再加工」徽章跟着身份列留在手机上 —— 它改变整行的读法 |
| 产出 | 6 | 产出批 · 产出量 | **钱那三列一列都没留**,与 CONV-9 给 `/inventory/output` 的裁定同条 |
| 回收率 | 4 | 金属 · 回收率 | 算不出时这一格说【为什么】,那同样是答案 |
| 成本条目 | 5 | 类型 · 金额 | |
| 损耗分类 | 4–5 | 类别 · 数量 | 「删」那一列只在有权限时存在(转换前的 `{canEdit && <th/>}` 同条) |

## ⑭-2 ★★ `/operation/orders/[id]` —— 转换当场照出【一对镜像的列错位】★★

**这是本节的头条,而它不是版式问题,是【读错数】。**

    转换前  投入侧  4 个 <th> 对 **5** 个 <td>  ——「出处」那一格【没有表头】
            产出侧  **5** 个 <th> 对 4 个 <td>  —— 声明了 colBasis 表头、【却没有那一格】

**两张表逐字互为镜像** —— 同一次复制粘贴把「出处」列留在了错的一侧。
后果:**产出侧的「实产」画在「出处」表头底下,「差异」画在「实产」底下** ——
整张表右移一格,而每一格里都还是一个像样的数字,
**所以它不像坏了,只像在说别的话。**
`processing.wo.colBasis` 这个键**一直存在**,投入侧从没用过它。

> ☞ **这是 CONV-9 §⑫-10 第 1 条(MaintenancePanel 5 th 对 6 td)的第二次。**
> 两次都不是被人眼看出来的 —— 两次都是**「每一列都必须有名字」这个契约**逼出来的。
> **一条要求列有名字的规矩,顺手把「列错位」变成了不可能。**
> 这是第 2 处;第 3 处出现时,值得给它一道独立的闸(th 数 == td 数)。

**手机:元凶【在】表里 —— CONV-9 §⑫-5a 的又一例。**
探针的判词是 **+65px / 1 张表被裁**,culprit `span.text-amber-700`;
那枚琥珀字住在投入表的「计划外」标记与两张表的负差异里,**全部在 `<td>` 中**。
所以这一页正是 `DataTable` 够得着的那一种。

    闸:118 → 121,+3(投入侧 · 产出侧 · 挂上来的加工单)

**三张表手机上留:** 料 · 差异(两侧同)· 加工单号 · 状态。
留状态而不是留数量,因为**一张已冲销的加工单仍然列在这里,而它的消耗哪儿都不算**
——「这一行算不算数」比「这一行有多少」要紧。
