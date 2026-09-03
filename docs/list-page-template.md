# 列表页模板(CONV-1,2026-09-03)· **只读账簿**

> ### ☞ 姊妹篇:[`docs/editable-grid-template.md`](./editable-grid-template.md)(CONV-2)
> **这两份【必须一起读】。** 本篇管**只读账簿**(`DataTable`),姊妹篇管
> **可编辑网格**(`EditableTable`)。**一张表该用哪一个,是这两份合起来回答的问题**,
> 而那两个组件是一对**刻意的**分叉,不是需要"整理"掉的重复 ——
> 理由写在 `app/components/ui/editable-table.tsx` 抬头的 FORK DECISION。
>
> ★ **CONV-2 更正了本篇的一个数:下面那个「19 张可编辑网格」是错的,真数是 10。**
> 本篇当时把组件算给了【它所在的目录】,而不是【它挂载的那一页】——
> `GoalsEditor` 住在 `app/hr/reviews/` 却挂在 `/hr/reviews/[id]`(详情页),
> `TemplateForm` / `FormulaForm` / `PayrollGrid` 只挂在 `/new` 与 `/[id]/edit`(表单页)。
> **而那 10 张还是【五种】不同的东西,不是一种。** 详见姊妹篇的头条与 §①。

> **这一刀是一道停止闸。** 它只转换四页,而定下来的东西后面四刀要抄大约 190 次。
> PAGE-0 §⑤ 把返工面算过:模板在二十页之后被发现不对,代价是
> **已转页数 × 每页 7.4 个列描述符**。所以先小、先撞最坏的情况、先给 Tim 看。

**基线:** HEAD `5fd3c01`(CONV-0),树干净。

---

## ★★ 头条发现:PAGE-0 点名的三张「最典型列表页」里,两张不是只读账簿 ★★

**这一条在转换任何一页【之前】就出来了,而它决定了这一刀转哪四页。**

把 79 张「列表形状且渲染了表」的页面逐个分类(跟着 import 走进子组件里去看那张表
到底长什么样,判据是【表格单元里有没有 input / select / textarea】):

| | 页数 |
|---|---:|
| **只读账簿** | **60** |
| **可编辑网格**(格子里有输入控件) | **19** |
| 合计 | 79 |

**PAGE-0 点名的三张全部落在那 19 里:**

| 页 | 实际是什么 |
|---|---|
| `/hr/leave/types` | `LeaveTypesEditor` —— `'use client'`,9 列,编辑某一行时格子里是 `<input>` |
| `/hr/reviews/scale` | `ScaleEditor` —— 同一形状,252 行 |
| `/finance/claims` | 上半是**决定队列**(`<select>` / `<input>` / 提交),只有下半那张 5 列的「已决登记簿」是只读账簿 |

**为什么会这样:** PAGE-0 的典型度是一个**形状向量**(行数 · 文件数 · 表数 ·
`<th>` 数 · 控件数 · 查询数)到该类中位数的距离。**它从来没有问过「这张表是只读的吗」**。
于是它挑出的三张,在【形状】上确实最靠近中位数,而在【种类】上是另一类东西。

### 那 19 张是【另一套模板】,不是这一套的变体

`DataTable` 是一个**只读账簿的渲染器**:`render: (row) => ReactNode`。
往格子里塞一个 `<input>` 在类型上是可以的,但它没有建模任何编辑所需的东西。
**一个编辑模板至少要建模三件这一套完全没有的事:**

1. **行级编辑状态** —— 哪一行在编辑、草稿放在哪、取消要恢复成什么;
2. **脏值追踪** —— 哪几个字段改过;离开页面前要不要拦;
3. **逐行保存** —— 每一行自己的 pending / 错误 / 乐观更新,而不是一次表单提交。

再加上它们与排序、筛选、分页的**交互**(正在编辑第 3 行时点了排序会怎样?)。
**这三件都不该在 190 页要抄的那个组件里,靠两个例子设计出来。**

### 后面四刀里,谁会撞上这 19 张

按 PAGE-0 §⑩ 的切次提案(2–4 是列表页、5 是详情、6 是表单):

| 刀 | 范围 | 其中的可编辑网格 |
|---|---|---:|
| **2 · finance 列表页** | ~18 | **含 `/finance/claims` 这一类混合页** |
| **3 · hr + inventory + operation 列表页** | ~18 | **`/hr/leave/types` · `/hr/reviews/scale` 都在这一刀** |
| 4 · 其余列表页 + 报表页 | ~28 | 其余 |
| 5 · 详情页 | 36 | 详情页里也有就地编辑的面板 |

**也就是说第 3 刀会第一个整批撞上它们。** 在那之前需要一次
「可编辑网格模板」的裁定,否则那一刀会在中途停下来设计它 ——
**而那正是这道停止闸要避免的事。**

---

## ① 模板的形状:两个文件,不是一次替换

### ★ RSC 边界逼出来的:每一页要多一个文件 ★

`Column.render` 与 `sortValue` 都是**函数**,而 `DataTable` 是 `'use client'`。
**React Server Component 不能把函数当 prop 传过客户端边界。**
所以列描述符没有办法住在服务端的 `page.tsx` 里。

**于是每一页的形状是固定的两半:**

```
page.tsx（服务端）    守卫 · 取数 · 把行压平成【纯数据】 · <ListPage state={…}>
XxxTable.tsx（客户端）列描述符 + <DataTable>；文案走 @/lib/i18n/client
```

**转换一页 = 改一个文件 + 新建一个文件。**
PAGE-0 §⑤ 把代价记成「960 个列描述符」——那一栏是对的;
**它没有记的是【129 个新文件】**。这是本刀量出来、而勘察没有量到的一项。

### 通则:服务端算「这一格该显示什么」,客户端只管怎么画

`/inbound` 的来源列要三样**只有服务端知道**的东西(采购单号躲在
`module.purchasing.view` 后面、理由字典的本地化名字、两样都没有 = 未说明)。
把 `Map` 传过边界能跑,但会让列描述符去懂这一页的取数形状。
**所以在服务端压平成 `InboundTableRow`,一个函数、一个 Map 都不过边界。**

---

## ② 手机:三道网,各管各的

Tim 的 Q2 裁定把两件事分开,因为**只有其中一件表达得进类型系统**。

| # | 网 | 管什么 | 漏了会怎样 |
|---|---|---|---|
| **①** | **类型** —— `phone` 是 `DataTable` 的必填 prop,`PhoneTreatment` 联合类型 | **有没有声明** | **编译不过** |
| **②** | **闸** —— `scripts/check-datatable-phone.mjs`(已进 `npm run build`) | **声明得对不对**(columns 模式至少一列 `priority`) | **构建变红,点名 file:line** |
| **③** | **渲染期 throw** —— `DATATABLE_NO_PHONE_COLUMNS` | **运行期才拼出来的列**(闸是静态解析,读不出动态列) | 打开那一页时抛错 |

**为什么需要 ② —— 一个量出来的缺陷,不是整洁。**
BASE-1 把这条拒绝写成渲染函数里的 `throw`。判据是对的,**响的时机是错的**:
`next build` 不渲染这些页面,所以构建期它一声不响;它只在**有人真的打开那一页**
时才响,对一张少有人访问的列表页那可能是几个月之后,而且是在一个真实用户面前响。

**`scroll` 那一支强制带 `why: string`。** 没有它,`mode: 'scroll'` 就是一个比
「什么都不写」更方便的默认值 —— 正好把这条裁定倒过来。带上 `why`,选横向滚动就
必须当场写下这张表为什么值得让人横着拖,而这句话跟着代码走。

### 故障注入:两道网各自单独验过

```
① 类型 —— 拿掉 CommissionsTable 的 phone prop:
   tsc → EXIT 1
   app/commissions/CommissionsTable.tsx(77,10): error TS2322:
     Property 'phone' is missing … but required in type … phone: PhoneTreatment

② 闸 —— 保留 phone={{mode:'columns'}},拿掉全部 priority:
   tsc → EXIT 0   ← ★ 类型看不见这一种,这正是闸存在的理由 ★
   check-datatable-phone → EXIT 1
     app/commissions/CommissionsTable.tsx:77
       phone 是 columns 模式,但 columns={columns} 里没有任何一列 priority: true
```

**两次都恢复后回到 0。** ② 那一格的 `tsc EXIT 0` 是这一节最要紧的一行:
它证明这两道网不是互相重复的。

---

## ③ 页面外壳 `<ListPage>`:照 ChartCard 的办法,说不出来就画不出来

`state` 是**必填**的联合类型,页面必须在几件事之间做出选择:

| 分支 | 意思 |
|---|---|
| `ok` | 有内容 —— 画 children |
| `restricted` | 进不去 —— **渲染 CONV-0 的 `<RefusalPage>`,不另开一条路** |
| `empty` | 没有内容,而**为什么没有**说得出口 |
| `too-few` | 有行但不够用 —— **只在这个区别真的存在时才用** |

**一个可选的 `empty?` 会被跳过**,而 PAGE-0 数出今天正好有 **38 张账簿一句空态都没有**。
必填是这条判据存在的全部意义。

**两种空只在真的分得开时才分。** 一份佣金协议登记簿没有「太少所以说明不了问题」
这回事:三份协议就是三份协议,它不是一条要够多点才画得出的趋势线。
本刀四页**一处都没有用 `too-few`** —— 那是对的结果,不是漏了。

### ★ 一个被真实回归逼出来的槽:`notices` ★

转 `/commissions` 时,那两块**无条件**提示(「它不过账」「计提那一半没建」)
**掉了** —— 因为 `children` 只在 `state.kind === 'ok'` 时画。而那一页的抬头
白纸黑字写着它们必须无条件渲染:**「一条只在有数据时才出现的警告,等于没有警告。」**

**外壳的 ok/empty 分支【本身】会把这一类话吃掉,而且是静默地吃掉。**
所以 `notices` 画在状态分支【之前】。**这是模板在四页上就被抓到的一处缺陷 ——
如果它在第 4 刀才被发现,已经有几十页悄悄丢了它们的无条件警告。**

---

## ④ 加载态:四页里只有一页够格,而那是对的结果

Tim 的 Q5=B:只给**串行往返深度 ≥5** 的 28 页建 `loading.tsx`,按量出来的深度选。
本刀四页逐个数 `page.tsx` 里的 `.from()`:

| 页 | 深度 | 建了吗 |
|---|---:|---|
| `/inbound` | **10** | ✅ |
| `/finance/claims` | 3 | — |
| `/commissions` | 1 | — |
| `/sales/quotes` | 1 | — |

在一个 1 次往返的页面上,骨架屏一闪而过 —— **那不是反馈,那是闪烁。**
骨架的版式来自 `ListPageSkeleton`,与真外壳**同一个文件**:一个与真页面对不上的
骨架,会在真页面出现的那一刻整页跳一下,比没有骨架更难受。

---

## ⑤ 量出来的四个数

### 手机可用度(`survey-phone.mjs --routes=…`,两跑自检都 PASSED,不是卡死)

| | 之前 | 之后 |
|---|---:|---:|
| U1 不用横向拖 | 2 / 4 | **4 / 4** |
| U2 账簿没被裁 | 2 / 4 | **4 / 4** |
| **可用** | **2 / 4** | **4 / 4** |

之前失败的两页:`/inbound` **溢出 +944px**、13 列的表被非滚动祖先裁掉;
`/sales/quotes` 溢出 +269px、7 列被裁。**之后两页都是 0 溢出、0 裁切。**

### hydration 成本(真浏览器 · 真会话 · 禁用缓存 · dev 未压缩)

| 路由 | JS 之前 → 之后 | Δ | ScriptDuration 之前 → 之后 |
|---|---|---:|---|
| `/inbound` | 1093.8 → 1124.9 KB | **+31.1** | 18 → 20 ms |
| `/finance/claims` | 1089.7 → 1118.5 KB | +28.8 | 13 → 13 ms |
| `/commissions` | 1084.3 → 1117.0 KB | +32.7 | 14 → 13 ms |
| `/sales/quotes` | 1084.3 → 1116.5 KB | +32.2 | 13 → 13 ms |

**生产构建的口径(压缩后、拆过包):`.next/static` 合计 4604 KB → 4648 KB,
整刀 +44 KB。** 四页的 dev 增量彼此接近(+29~33 KB),**说明它几乎全部是
【共用的 DataTable / ListPage 模块】,而那一份是【付一次】的**;
每一页自己的边际成本是它那个列描述符模块。

**RSC / 文档字节反而降了:** `/inbound` 29.1 KB → 18.4 KB(**−10.7 KB**)——
旧的 13 列手写表每个格子都带着 `border border-gray-300 px-4 py-2`,
压平后的行数据 + DataTable 的标记比它小。

> **读法的边界:** dev 数是未压缩、未拆包的,不能当生产时延读;
> ScriptDuration 的 ±1–2ms 在噪声里。**能说的是:量级是几十 KB 的一次性共享成本,
> 不是每页几百 KB。** 按这个量级,Q6=A(接受客户端边界)不需要重开。

### Q7:服务端排序的行为【没有变】—— 证过,不是假定

对 **14 个 URL**(每个排序列 × 两个方向 · 第 2 页 · 一个筛选)在两棵树上取同一份
HTML,比较**批次号的渲染顺序**(排序真正决定的东西;不比标记,标记本来就该不同):

```
✓ Q7 PROVEN: 14 urls, 14 with rows — batch-code order identical before vs after,
  every sort column, both directions, page 2, and a filter.
```

### 转一页实际要动多少(给后面四刀定尺)

| | |
|---|---:|
| 四页改动 | **+175 / −344 行**(净 **−169 行**) |
| 新建文件 | **3 个**(`CommissionsTable` · `QuotesTable` · `InboundTable`)+ 1 个 `loading.tsx` |
| 列描述符 | 7 + 7 + 13 + 5 = **32 个** |
| 共用件(一次性) | `list-page.tsx` · `check-datatable-phone.mjs` · `data-table.tsx` 改动 |

**转换是【净删代码】的**:四页删掉的比加上的多 169 行。
`/finance/claims` 不需要新文件(它的面板本来就是 `'use client'`)——
**一页要不要多一个文件,取决于它的表是不是已经在客户端组件里了。**

---

## ⑥ 模板【做不到】的事 —— 这一节比上面所有数都值钱

1. **行内编辑。** 见头条:可编辑网格是另一套模板。**没有在这里设计它。**
   **☞ CONV-2(2026-09-03)做掉了它 —— [`docs/editable-grid-template.md`](./editable-grid-template.md)**,
   并且更正了本篇那个 19(真数 10,而且是五种不同的东西)。
   新组件是 `EditableTable`,与 `DataTable` 是**刻意的一对**;
   `scripts/check-datatable-phone.mjs` 现在同时看着两个。
2. **`too-few` 的判据是页面自己给的,组件不验算。** 传 `{kind:'too-few', n}` 时
   没有任何东西检查 `n` 真的是行数。CHART-1 的 `ChartCard` 同样如此。
3. **`empty` 与 `restricted` 用的是同一个琥珀块。** 两者的区别完全由【词】承担。
   本刀认为这是对的(读者要读的是同一类东西:这里为什么没有东西),
   **但它是一个判断,不是一个机制** —— 有人可能想让「你进不来」更重。
4. **服务端分页留在页面上,没有进外壳。** `/inbound` 的翻页控件仍是页面自己的
   `<Link>`。17 个分页页面各自有一份几乎相同的 `pageHref` —— **那是下一个可以收敛的形状**,
   本刀没有做,因为它不在四页里出现两次以上。
5. **`.limit()` 之上没有「显示了 N / 全体 M」。** `/sales/quotes` 取 `.limit(200)`
   而不报量。`DataTable` 的 `coverage` 只在**打开排序**时才要求回答 ——
   一个不排序但截断了的列表仍然可以静默地少给行。**这是 BASE-1 那条裁定的一个缺口。**
6. **列描述符里的文案全部走客户端 i18n。** 服务端 `getTranslations` 用不了,
   于是每一页的表格文案都在客户端 bundle 里。今天没有代价(两份 messages 本来就
   都在客户端可达),但它意味着**表头文案无法只在服务端存在**。

---

## ⑦ 只有人能确认的事

见 `docs/manual-walk-list.md` §22。**一处都还没有人走过。**

---

## ⑧ CONV-3(2026-09-03)· Kind-E 四页 + Kind-C 选择设计 + Kind-D 转换

**基线:** HEAD `edd850e`(CONV-2),树干净。

CONV-2 把 10 张「可编辑网格」拆成五种,只做了 A/B,把 C(勾选批量)、D(决定
队列)、E(只读账簿+表单)三种「说清楚该变成什么,一件都不建」。本刀做完
它们,同时执行 CONV-3 那份委托:把这一刀之前还没转换的读账簿(4 张 Kind-E +
64 张普通只读表)转上 CONV-1 的模板。**这一刀只做了 Kind-E 的 4 张 + Kind-C
的 2 张 + Kind-D 的 1 张 —— 普通的 64 张见 ⑧-6,留给下一刀。**

### ⑧-1 人口重新量过:68 张,不是 79-3-3=73

`AGENTS.md` 反复写的那条规矩(数东西前先问判据答的是不是标签上的那件事)
再验一次:跟着 CONV-2 的办法(反向 import 图,走到最近的 `page.tsx`)重新数
了 CONV-3 该转的人口 ——

| | 数 |
|---|---:|
| 普通只读列表/报表页(不含 Kind-E) | **64** |
| Kind-E(只读账簿 + 表下面一张表单) | **4** |
| **合计** | **68** |

与本刀委托的「~64」估计基本对上,**没有实质性更正**。但重新量的过程中
纠正了 CONV-2 自己的一处措辞:

> ★【`/pricing/calculator` 不属于任何一个模板的人口 —— CONV-2 说它"格子里
> 是隐藏输入"只说对了一半】★ `CalculatorForm.tsx:171-177` 那一格里【同时】有
> 一个 `<input type="hidden">` **和**一个真的、人手输的 `DecimalInput`
> (`assay_content`)。按"格子里有没有输入控件"这条全仓库统一的判据,它其实
> 不是只读账簿;但它也不是一张「持久化行的编辑器」—— 它是一个【计算工具】,
> 表格是它的输入区,不是一份数据库记录的列表。**两个模板的人口都不该数它**。

### ⑧-2 Kind-E 四页:套外壳,空态一律【恒为 ok】

四页:`/hr/leave/holidays` · `/settings/dictionaries` · `/purchasing/licences` ·
`/finance/cash-forecast`。全部走 CONV-1 的 `<ListPage>` + `<DataTable>`。

**没有新增一次 notices 槽的"发明"** —— CONV-1/CONV-2 已经把它扩成「渲染在
状态分支之前的任意内容」,这四页把子导航、GET 筛选表单、二级说明文字都
按这个既有口子放进去,没有再改 `list-page.tsx` 一个字。

**★★ 但四页【全部】撞上同一条判据,而且是 CONV-2 §⑧ 第 3 条那个"差一点发
出去的缺陷"的第 4/5/6/7 次现场 ★★** Kind-E 的定义就是"编辑在表下面的表单
里",而那张表单是这一页【唯一】能新增第一行的地方,天然住在 `children` 里。
一张表零行时,如果 `ListPage` 的 `state.kind` 是 `'empty'`,外壳只画
`RefusalBlock`、不画 `children`——那张新增表单会跟着空态一起消失,人被留在
一个自己走不出去的空页上。

**处置对四页统一:`state` 恒为 `{ kind: 'ok' }`,空态改由 `DataTable` 自己的
`empty` prop 说。** 这不是绕过 CONV-1 那条"必填 `empty`"的判据 —— 判据仍然
成立,只是【回答它的层】从外壳挪到了表格本身,因为出口在表格外面而不是在
外壳的 children 分支之外。`/purchasing/licences` 与 `/settings/dictionaries`
额外把"没有权限看这一节/这一页"的旧内嵌琥珀提示,改走 `ListPage` 的
`state:'restricted'`(与 CONV-0 的整页拒绝合成同一份实现)。

### ⑧-3 `/finance/cash-forecast`:六张表,一张【没有】换,理由写在代码里

CONV-2 的委托没点名这一页有多复杂 —— 它下辖 **6 张表**:期初/13 周现金桶
(每币种一张,共 N 张)、明细行、未定日款项、客户承诺(列表,非表格)、
OPEX 覆盖、经常性成本、已冻结历史。逐张过:

| 表 | 换了吗 | 为什么 |
|---|---|---|
| 13 周现金桶(每币种) | **没换** | 透视表,两根轴都不是"记录"——见 `ForecastGrid.tsx` 抬头的 CONV-3 说明,与本文档 §⑥ 已经拒绝过的"没有例子不设计"同一条理由,只是换成了"没有形状匹配不硬套" |
| 明细行 / 未定日款项 / OPEX 覆盖 | 换了 | 逐行记录,DataTable 的模型天然贴合 |
| 经常性成本(RecurringLines) | 换了 | 同上,新增表单走 `AddRowPanel` |
| 已冻结历史(FrozenForecastsTable) | 换了 | 服务端组件里的表,按 CONV-1 的规则新建了一个客户端文件 |

**手机适配靠透视表本来就有的 `overflow-x-auto`**,不是漏转 —— 这与 CONV-1 §②
的"三道网"不冲突,因为那三道网守的是【进了 DataTable 的表】,这张表从一开始
就没有进去。

### ⑧-4 Kind-C 选择设计:委托的假设被实测更正,而更正让设计变简单了

CONV-2 的委托原话是「`/finance/processing-costs` 有两个独立的选中集,所以
`selection` prop 不能假设『一张表一个选中集』」——听着像是要一个【命名分组】
的 prop。**实测(动手转换这一页时才看清)那两个选中集是两张【独立的
`<table>`】**(`CostSettlePanel.tsx` 里原本就是两段各自的 `<table><tbody>`,
各自的 `Record<id, boolean>` state),不是一张表要两组勾选框。

**于是最终设计是全仓库最简单的那个版本**:`DataTable` 的 `selection` prop
只管【一张表、一个选中集】——`{ selectedIds, onToggle, onToggleAll }`。两张
`DataTable` 实例各给一个 `selection`,天然就是两个互不相干的集合。这不是
"没有兑现委托",是委托要求的那件事(两个选中集不能互相干扰)在实测之后
发现**不需要新设计就能满足** —— 与 CONV-1/CONV-2 三次"按一个便宜代理指标
多算"是同一条教训在设计阶段的版本:**没有证据支持的复杂度不建**。

**与 EditableTable 的 FORK DECISION 是同一个判据,答案却相反,原因写在
`data-table.tsx` 抬头:** 行内编辑要建三件全新的东西(编辑态、脏值追踪、
逐行保存)——那是一个新的渲染契约,所以分岔。勾选只是多一列 UI,`render:
(row) => ReactNode` 一个字都不用改,而且默认 `undefined`、零处旧调用点受
影响 —— 所以它是一个 prop,不是第二个组件。

**`selection` prop 有一个刻意留白:它假设每一行都能选。**
`/finance/payroll-payments` 的已付行【没有】勾选框(转换前就是这样),这个
形状与 `selection` 的假设冲突,而全仓库只有它一页长这样。**一个例子不足以
设计"这一行能不能选"这个扩展**,所以那一页退回普通的自定义列(勾选框由
`Column.render` 自己画,与转换前逐字同形),`selection` prop 留给"整表可选"
这一种。将来第二个"部分行不可选"的页面出现,才是设计那个扩展的时候。

### ⑧-5 Kind-D `/finance/claims`:转换如实施,没有发现新能力缺口

按委托的要求,不为它另造模板:卡片队列(上半)一个字没动,只套了
`<ListPage>` 外壳。两个独立列表(待决队列 / 已决登记簿)的空态各自说各自
的话,用的正是 CONV-2 §⑧ 第 3 条已经踩过的"恒为 ok"处置 —— **不是重新发明,
是同一个判据的第二次应用**。逐项核对委托点名要看的东西(是否需要新能力):

* `ListPage` 的 `notices` 槽够用(承接备用金那句无条件提示);
* `RefusalPage`/`RefusalBlock` 够用(这一页本来就已经用 CONV-0 的
  `requireModule` 早退);
* 手机处置:下半的 `DataTable`(CONV-1 已转)不用动;上半卡片队列本来就是
  响应式的 flex 布局,不经过 DataTable 的三道网,也不需要经过。

**结论:没有发现需要新建的能力。** 这本身是一个值得记的发现 —— 委托原话
「如果诚实的答案需要新能力,那是一个发现,不要投机地建它」,而这一页诚实
的答案是"不需要"。

### ⑧-6 add-a-row:委托的又一处假设被实测推翻 —— 合并数是 4,不是 8

CONV-2 measured "10 张可编辑页里 4 张带 add-a-row",委托据此让本刀在 CONV-3
的人口里也数一次,如果两边合起来数字撑得住就建一个两个模板共用的组件。

**重新数之后:CONV-3 这一刀的人口(68 张)里带 add-a-row 形状的,正好就是
【这 4 张 Kind-E 页】—— 不是另外一群未被数过的页。** 而 Kind A/B/C/D 结构上
都不可能有这个形状(A 编辑既有行、B 是自填面板、C 是勾选批量、D 是决定
队列,没有一种会在页面上新增一行持久化记录)。**于是"两个模板合起来的
add-a-row 计数"从来不是 4+4=8,一直就是 4** —— 同一批物理页面被两份清单
各数了一次。

**处置:不建跨模板共用组件,只在 Kind-E 内部收敛出一个小外壳
`app/components/ui/add-row-panel.tsx`。** 它只管【盒子】(标题、错误位、
字段横排、保存/取消收在下面),不管字段本身 —— 四页的字段逐页不同(假期
四个字段;经常性成本六个带下拉;执照十个字段带编辑复用;字典六个基础字段
加逐字典声明的 extras),硬把字段也收进去会让这个组件被迫认识五种不同的
状态形状,正是 `EditableTable` 抬头拒绝对 `DataTable` 做的事,换了个更小
的场景。**这不是"没有做委托要求的收敛",是数字本身说了不该往哪个方向收。**

### ⑧-7 手机三道网:call site 数字交叉验证过,不是假设"模式会自动套对"

`AGENTS.md` 点名这一刀要检查:新模板的调用点是不是真的被闸【计入】了,不
要假设模式会自动转移干净。跑了 `npm run build`,`check-datatable-phone.mjs`
报告 **19 个调用点(DataTable 16 · EditableTable 3)**;用
`grep -rn "<DataTable" app` 独立核对,得到的物理 JSX 位置数**逐字符合**
(16 处,含本刀新增的 11 处)。**两条独立路径给出同一个数,这道闸没有安静
地漏掉任何一个新调用点。**

第一次跑 `npm run build` 时确实撞上了一件事,记下来因为它不是这一刀独有的
坑:所有新文件里给按钮/输入框套的 `base-pressable` 类名,被
`check-base-isolation.mjs`(BASE-1 的隔离闸)当场拦下 —— 那道闸守的是"这批
基础组件的类名不出现在 `app/components/ui/` 与取样页之外的任何地方",而它
对类名【没有】任何登记豁免的口子(与 import 那半不同,import 有
`KNOWN_CONVERSIONS` 可以登记)。**这不是闸坏了,是这批类名压根不该出现在
页面层代码里** —— 转换前的原代码本来就是普通 Tailwind 类,本刀在几个按钮上
"顺手"套用了 `data-table.tsx` 内部用的类名,而那些类名的隔离契约只对
`app/components/ui/` 内部成立。改法是把这几处 `base-pressable` 全部退回普通
类,不是去改这道闸。

**故障注入(与 CONV-1/CONV-2 同形,红后绿)**:拿掉 `HolidaysTable.tsx` 一张
表的全部 `priority: true`,`check-datatable-phone.mjs` 退出 1,精确点名
`app/hr/leave/holidays/HolidaysTable.tsx:56`;`shasum` 逐字节还原后重跑,
退出 0、19 个调用点、0 处问题。

### ⑧-8 模板【新照出来】的一处缺口:DataTable 没有整行样式的口子

`RecurringLines.tsx`(停用的经常性成本整行发灰)与 `ForecastGrid.tsx` 的
未定日款项表(整行琥珀底)转换前都是【整行】一种颜色,而 `DataTable` 的
契约是【逐列】`render`,没有"这一行整体什么样"的口子。

**处置:把同一个视觉判断挪进每一列自己的 `render`**(逐格套一个带颜色的
`<span>`/`className`)。代价:格与格之间会露出背景色不连续的缝(手机展开区
里那一格因为走的是 `<dd>` 而不是这套列描述符,完全不带底色)。**这是模板
今天做不到的事,记在这里、不是没看见** —— 与 CONV-1 §⑥、CONV-2 §⑧ 是
同一节的延续。整行样式如果将来在更多页面上重复出现,才是给 `DataTable`
加一个 `rowClassName?: (row) => string` 的时候;今天只有 2 处,不建。

### ⑧-9 只有人能确认的事

见 `docs/manual-walk-list.md` §24。**一处都还没有人走过。**

### ⑧-10 这一刀之后还剩什么(留给下一刀,按 Tim 的排序偏好:列表先于报表、finance 先)

68 张人口里,这一刀转完了 4 张 Kind-E + 2 张 Kind-C + 1 张 Kind-D = **7 张**。
剩下 **64 张普通只读列表/报表页**,一个都还没动,按模块列在这里(与人口
重量的方法与结果见 ⑧-1,完整清单是这次重量时得到的、不是估计的):

* **finance(23)**:`/finance/assets` · `balance-sheet` · `bank/statements` ·
  `cashflow` · `close` · `cost-variance` · `credit-notes` · `expenses` ·
  `freight` · `fx` · `gst` · `invoices` · `journal` · `month-end` · `packs` ·
  `payables` · `payments` · `pnl` · `price-exposure` · `receivables` ·
  `revaluation` · `trial-balance` · `wht`
* **hr(11)**:`attendance` · `claims` · `departments` · `employees` · `kpi` ·
  `leave` · `leave/balances` · `payroll` · `reviews` · `reviews/cycles` ·
  `training`
* **inventory(5)**:`locations` · `reports/ledger` · `reports/safety` ·
  `reports/snapshot` · `reports/violations`
* **operation(4)**:`handovers` · `orders` · `processing` · `wip`
* **其余(21)**:`settings/deleted` · `settings/import` · `settings/reference` ·
  `settings/roles` · `customers` · `customers/overlap` · `logistics/containers` ·
  `logistics/forwarders` · `pricing/formulas` · `pricing/metal-prices` ·
  `purchasing/orders` · `purchasing/payment-terms` · `stocktakes` ·
  `stocktakes/[id]/review` · `contracts` · `margin` · `materials` ·
  `my-reviews` · `output` · `sales/orders` · `suppliers`

四张(`/hr/reviews` · `/pricing/formulas` · `/purchasing/payment-terms` ·
`/settings/roles`)需要下一刀重复本刀 ⑧-1 用过的同一步核实:各自的目录里
住着一个编辑器组件(`GoalsEditor` / `FormulaForm` / `TemplateForm` /
`PermissionMatrix`),但那些组件挂载在详情/表单路由上,不在这几张列表页
自己身上 —— 与 CONV-1/CONV-2 撞见的殖民地归属错误同一条,下一刀开工前
应重新确认而不是继承这份清单的判断。
