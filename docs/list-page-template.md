# 列表页模板(CONV-1,2026-09-03)· **只读账簿**

> ### ☞ 第三篇:[`docs/detail-page-template.md`](./detail-page-template.md)(CONV-8,2026-09-04)
> **详情页【不是】第三套模板** —— 它是本篇 + 姊妹篇,加一个 `RecordHeader` 组件
> 与一条判据(详情页的 `state` 恒为 `'ok'`,因为记录在不在由 `notFound()` 回答)。
> 本篇的 `ListPage` 因它多了一个 `breadcrumb` 槽(画在标题之上,23 张详情页要它);
> **既有 64 个调用点一个字都不用改。**
> ★ 那一刀还补了本篇 §② 那道手机闸的一个洞:它此前会把**注释里**的
> `const columns` 当成声明,于是一张一列 priority 都没有的表照样变绿。详见那一篇 §⑦。

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

> ### ☞ 【本节已被后两刀走完 —— 更正与结果见 §⑩-2 与 §⑩-14】
> * **那 64 张全部转完:** CONV-4 转 finance 的 23 张,CONV-5 转其余 41 张
>   (hr 11 · inventory 5 · operation 4 · 其余 21)。23 + 41 = 64 ✓,
>   §⑧-10 的清单没有任何一张遗留。
> * **★ 上面点名要核实的那四张,CONV-5 逐张按 import 查过 —— 四张全是误记,
>   四张都是纯只读账簿。** 外加一张本节没点名、同一个形状的 `/hr/payroll`
>   (`PayrollGrid` 只挂 `/new` 与 `/[id]/edit`)。**五张全部是"殖民地归属"
>   错误,这个仓库为这条栽了三次。** 详见 §⑩-2 —— 下一刀请**按 import 建清单,
>   不要按目录**。

---

## ⑨ CONV-4(2026-09-04)· finance 23 张 —— 而【分类比⑧-1的一句话粗糙得多】

**基线:** HEAD `3427c13`(CONV-3),树干净。

CONV-3 §⑧-10 把 finance 的 23 张记成"普通只读列表/报表页,一个都还没动"。
本刀开工前重新按 §③"这是机械活,但这句话本身要验证"的要求逐页打开,发现
那个记法把好几种真实不同的形状压成了一句话——不是数量错了,是**形状分类
太粗**,细看之后 23 张里没有一张是"直接套模板"这么简单。

### ⑨-1 逐页重新分类:23 张里【没有一张】是简单的"是/否 DataTable 候选"

- **11 张**整页转成 DataTable(`credit-notes` · `expenses` · `freight` ·
  `fx` · `bank/statements` · `invoices` · `journal` · `payments` · `gst`
  两张表 · `wht` 三张表 · `revaluation`)。
- **5 张**混合(部分表转、部分表按兵不动):`assets`(主表因
  `AssetActions` 行内表单不是这套模板的人口,折旧预览表转)·`close`
  (主表因 `ReopenForm` 行内表单同理,年结历史表转)·`cashflow`(固定
  六行汇总表按兵不动,明细分录表转)·`price-exposure`(叙述性文字为主,
  唯一一张卖方向头寸表转)·`packs`(报告体是透视/汇总不转,存档登记簿转)。
- **7 张**只套 `ListPage` 外壳、表本身一个字没动:`balance-sheet` ·
  `pnl` · `trial-balance` · `payables` · `receivables`(五张撞上同一个
  分组缺口,见 ⑨-2)· `cost-variance`(透视表,同 §⑧-3 的 `ForecastGrid`
  判据)· `month-end`(十步写死的工作流清单,0 个 `<th>`,不是查出来的
  记录集)。

11+5+7 = 23,与委托的数字对上,**但委托原句"一个都还没动"这句话本身
是不对的**——如果不逐页打开验证,套用它会漏掉至少 5 张页面里【真正】
不该被强套 DataTable 的表。

### ⑨-2 分组/小计缺口:CONV-3 §⑧-8 记过的那个形状,这一刀发现它不只在
`payables`/`receivables` 上出现

委托原本只提过 `payables`/`receivables` 是"分组 + 小计"的账龄报表。
逐页打开 `balance-sheet` / `pnl` / `trial-balance` 才发现它们是**同一个
形状**——按科目类型动态分组、组内小计、末尾还有跨组的资产合计/负债权益
合计(或毛利/净利派生行)。`DataTable` 的契约是"一行 = 一条记录,渲染
一次",没有"动态分组表头 + 组内小计 + 跨组合计"的口子。

**于是这个缺口这一刀量到 5 处,不是 2 处**——按 §⑧-8 用过的"第三次才建"
同一条判据本该清了这道坎,但没有建:5 处里有 2 种明显不同的分组形状
(`payables`/`receivables` 是【运行期算出来的】动态分组,按往来对象;
`balance-sheet`/`pnl`/`trial-balance` 是【固定的】三段分组,按科目类型,
外加派生的毛利/净利/合计行)。给这两种形状设计一套通用能力,至少要先
想清楚它们能不能共用同一套 API——这是一次专门的设计决定,不是这一刀
能在转换页面的同时顺手做出来的判断。**5 处记录在这里,留给下一次设计
时间,不是留给下一次"顺手建了"。**

### ⑨-3 `rowClassName`:§⑧-8 的"第三次才建",这一刀一次量到 5 处

CONV-3 §⑧-8 量到 2 处整行样式(`RecurringLines` 停用行发灰、
`ForecastGrid` 未定日款项整行琥珀),裁定"2 处不建,第三次才建"。
本刀转 finance 时一次性量到 5 处:`freight` 冲销单据整行发灰、`close`
年结历史已重开行发灰、`invoices` 已作废发票整行发灰、`assets` 折旧
预览的合计行加粗、`revaluation` 预览的合计行加粗——同一个形状,不是
新形状,清过了"第三次才建"那道坎。

`DataTable` 加了 `rowClassName?: (row: T) => string | undefined`,应用在
主行与手机展开区两处 `<tr>` 上,不给就不加 className,零处旧调用点受
影响。**合计行走的是同一个口子**:`assets` 的折旧预览与 `revaluation`
的重估预览此前各有一行 `<tfoot>` 表尾合计,`DataTable` 没有表尾概念——
处置是把合计行当成【数据】塞进 `rows` 数组(带 `isTotal` 标记),用
`rowClassName` 加粗它,而不是给组件另开一个"表尾"槽位。

### ⑨-4 一个跨 6+ 张页面的判断:筛选工具栏是【出口】,`state` 恒为 `'ok'`

`expenses` · `bank/statements` · `invoices` · `journal` · `payments` ·
`fx` 六张列表页都带一个真实的筛选工具栏(URL 参数驱动、GET 表单或
`useSearchParams` 客户端组件)。如果按【当前筛选后的行数】驱动
`ListPage` 的 `state:'empty'` 分支,会把工具栏也一起藏起来——正是
CONV-3 §⑧-2 记过的"空态吞掉出口"同一个缺陷,只是这次的出口是【筛选】,
不是【新增表单】。

处置与 Kind-E 相同:`state` 恒为 `{ kind: 'ok' }`,工具栏与表格一起
无条件可见,空态由 `DataTable` 自己的 `empty` prop 说——而这本来就是
这几页转换前的真实行为(工具栏此前从不在任何行数判断里面)。这不是
一页一页各自的决定,是同一条判据在 6 张页面上的应用,只写一次、
在这里说明,不在每一页的注释里重复整套推理(只留一句指回这里)。

### ⑨-5 一张页面的典型样子(供 Tim 一眼看出这一批转换长什么样)

`/finance/payments`:收付款登记簿,8 列(单号/日期/方向/往来对象/金额/
银行账户/状态),筛选工具栏(日期区间 + 方向)+ 服务端 `.range()` 分页
一个字没变。手机上留【单号】与【金额】,其余 6 列进展开区——单号是
身份,金额是这张登记簿存在的理由。转换净删代码(手写 `<table>` 90 行
换成客户端列描述符 74 行 + 服务端 page.tsx 精简)。这是这一批 11 张
"整页转 DataTable"里最不需要特殊处理的一张,也是最典型的一张。

### ⑨-6 手机可用度(`survey-phone.mjs --routes=/finance`,两跑都 PASSED)

★ 按 CONV-3 §④ 的规矩,先做 tableCount 交叉核对,再引用可用度数字 ★
逐页核对 `.survey-out/phone-390.json` 里的 `tableCount`:`gst`=2、
`wht`=3、`cashflow`=2、`packs`=3(报告体自带 2 张 + 登记簿 1 张)—— 与
每页实际的表数逐一对上,没有漏数或多数的表。`price-exposure` 的
`tableCount=0`(前后两跑都是)不是漏转——这一页的卖方向头寸表只在有
合同数据时才渲染,今天的测试数据里一份合同都没有,这张表【从来没有
被真实渲染过】,记在 §⑨-9 的人工核对清单里。

| | 之前 | 之后 |
|---|---:|---:|
| 本刀 23 张范围内 U1∧U2 可用 | **8 / 23** | **18 / 23** |
| finance 模块全体 53 条路由(含 `[id]` 详情页与 CONV-2/3 已转页) | 29 / 53 | 39 / 53 |

**23 张范围内,10 张从不可用变可用**(`bank/statements` · `credit-notes` ·
`expenses` · `freight` · `fx` · `gst` · `invoices` · `journal` · `payments` ·
`revaluation`),**5 张前后都不可用、而且不可用的原因一个字没变**
(`assets` · `close` · `packs` · `payables` · `receivables`——全部是
⑨-1 里主表按兵不动或 ⑨-2 分组缺口的那几张),**8 张前后都可用**
(`balance-sheet` · `cashflow` · `cost-variance` · `month-end` · `pnl` ·
`price-exposure` · `trial-balance` · `wht`)。**没有一张从可用变不可用**——
"按兵不动"的表格没有被本刀的改动意外弄坏。

### ⑨-7 hydration/字节成本(生产构建口径,`.next/static` 总字节数,worktree 对拍)

| | 之前(3427c13) | 之后(本刀) | Δ |
|---|---:|---:|---:|
| `.next/static` 总字节 | 4,408,387 B | 4,583,038 B | **+174,651 B(≈+171 KB)** |

23 张页面共新增 17 个客户端文件(11 张单表 + `gst`/`cashflow`/`packs`
各 2、`wht` 3、`assets`/`close`/`price-exposure`/`revaluation` 各 1),
量级与 CONV-1 的判断一致——大部分是共用的 `DataTable`/`ListPage` 模块
(那一份已经在 CONV-1 付过),每页自己的边际成本是它那份列描述符。
测法:`git worktree` 在 3427c13 上跑一次干净的 `next build`,与当前树
的构建产物按字节数逐一比较(`stat -f%z` 累加,不是 `du` 的块近似值)。

### ⑨-8 只有人能确认的事

见 `docs/manual-walk-list.md` §25。**一处都还没有人走过。**

### ⑨-9 这一刀之后还剩什么(留给下一刀)

finance 23 张这一刀全部处理完(11 转 + 5 混合 + 7 外壳)。剩下
**hr(11) · inventory(5) · operation(4) · 其余(21) = 41 张**,清单与
⑧-10 逐字相同(本刀没有触碰这几个模块,清单未变)。下一刀开工前仍然
要重新核实 ⑧-10 点名的那四张(`/hr/reviews` · `/pricing/formulas` ·
`/purchasing/payment-terms` · `/settings/roles`)——理由不变。

**另外三件事留给设计时间,不留给下一刀"顺手做"**:
1. ⑨-2 的分组/小计缺口,5 处,两种形状,需要专门的 API 设计讨论;
2. `price-exposure` 的卖方向头寸表至今没有被真实数据渲染过,第一份
   真实合同数据到场时应有人走一遍(与 `/finance/wht` 页顶注同一条
   "返回条件");
3. `/finance/packs` 的 `PackBody` 报告体(2 张内部表)本刀没有触碰,
   如果它的手机可用度将来要处理,那是另一次设计,不是本刀 §⑨-1
   已经交代过的"按兵不动"范围。

---

## ⑩ CONV-5(2026-09-04)· hr 11 · inventory 5 · operation 4 · 其余 21 —— 而【CONV-3 点名的那四张"殖民地",四张全是误记】

**基线:** HEAD `bf4986b`(CONV-4),树干净。**41 张全部处理完。**

**分类判据用的是【表】,不是【页】,因为那是可以核实的那个单位:**
转换后在这 41 张 `page.tsx` 里 grep `<table`,**只剩一处**(见下)。

| | 张数 |
|---|---:|
| 页上每一张表都变成了 `DataTable` | **40** |
| 只套外壳、表一个字没动(`/hr/reviews/cycles`,诊断见下) | **1** |
| **合计** | **41** |

**新建客户端表文件 40 个,`<DataTable>` 调用点 47 个** —— 两个数不一样,
而差在哪里值得写清楚:

* **40 = 41 − 1**:除了只套外壳的 `/hr/reviews/cycles`,每一张转换页各得一个
  客户端表文件(CONV-1 §① 那个"一页两个文件"的形状,41 张一次没破例)。
* **47 − 40 = 7**:四个文件各导出不止一个表组件 ——
  `ContractsTables.tsx` **5** 个、`OverlapTables.tsx` / `SnapshotTables.tsx` /
  `ViolationsTables.tsx` 各 **2** 个。
* **而"一个组件用了几次"不进这个数**:`settings/reference` 的表组件被三个
  权限类别各用一次、`my-reviews` 的被"手上有活/已了结"两段各用一次 ——
  它们是**同一个调用点**。闸数的是调用点,不是渲染次数。

**那 40 张里有 9 张是【报告体 + 登记簿】** —— 表全部换了,而卡片、散文、
覆盖率块、合计条这些【不是表】的东西一个字没动(Tim 在本刀 Q2 的裁定):
`hr/kpi` · `inventory/reports/safety` · `inventory/reports/snapshot` ·
`inventory/reports/violations` · `contracts` · `customers/overlap` ·
`margin` · `stocktakes/[id]/review` · `settings/import`。
**`/contracts` 是其中最极端的一张:它是一屏报告,里面装着【五张】真登记簿**
(违反 / 合同清单 / 指数计价条款 / 结算口径 / 已记录结算)——
五张全换,覆盖率块与两个"建了什么、还不能做什么"的琥珀块全留。

**混合页(主表里带真表单)这一刀是 0 张** —— 与 CONV-4 的 finance 段(5 张)不同。
理由见 ⑩-1:判据一样,而这四个模块的表单都在 `/new` 与 `/[id]/edit` 上。

### ⑩-1 开工前的分类:先量,而【第一次量错了,自己照出来】

CONV-4 §⑨ 立的规矩是"标签不是页面,逐页分类"。本刀照做,而**第一遍的机械
判据自己就是错的**,值得写下来,因为下一刀还会想用同一个 grep:

第一遍用的判据是 CONV-1 原话——【表格单元里有没有 `input` / `select` /
`textarea`】。41 张跑下来**全是 0**,于是"这一刀一张可编辑网格都没有"。

**那个数是假的。** `/hr/reviews/cycles` 的表格单元里确实有一个会改数据的
`<select>` ——它藏在 `<SetReviewerControl>` 这个**组件**里面,而按标签名 grep
的判据**看不见组件**。改成"扫 `<table>` 区域里的大写 JSX 标签"之后才照出来。

**判据本身没错,它的机械实现漏了一整类。** 记在这里,因为剩下的详情页/表单页
两刀会重复用它。

> 【另一处同类的自我更正】开工时那个测量脚本在 zsh 下写成了
> `cat $all`(未加引号的变量)。**zsh 不做词分割**,于是 41 张页面的表数、
> `<th>` 数、控件数【全部量成 0】,而 0 看起来像一个答案。
> 是"目录总行数也是 0"这一格不合常理才把它照出来的。
> **一个全 0 的测量结果要当成脚本坏了,不是当成发现。**

### ⑩-2 CONV-3 §⑧-10 点名要核实的四张:**四张全部是误记**

按 `page.tsx` 的 import 逐张核实(相对 `./X` 与 `@/app/...` 两种写法都查了):

| 页 | 目录里那个编辑器 | 它实际挂在哪 | 结论 |
|---|---|---|---|
| `/hr/reviews` | `GoalsEditor` | `/hr/reviews/[id]` 详情页 | 只读账簿 |
| `/pricing/formulas` | `FormulaForm` | `/new` 与 `/[id]/edit` | 只读账簿 |
| `/purchasing/payment-terms` | `TemplateForm` | `/new` 与 `/[id]/edit` | 只读账簿 |
| `/settings/roles` | `PermissionMatrix` | `/settings/roles/[id]` | 只读账簿 |

**外加一张 CONV-3 没点名、但同一个形状的:** `/hr/payroll` 目录里住着
`PayrollGrid`(CONV-2 的可编辑网格),而 `/hr/payroll/page.tsx` **一个本地组件
都不 import**。

**五张全部是"殖民地归属"错误** ——与 CONV-1 / CONV-2 撞见的是同一条。
把组件算给它所在的**目录**、而不是它挂载的**那一页**,这个仓库现在栽了三次。
**建议下一刀直接按 import 建清单,不要按目录。**

### ⑩-3 一条跨【15 张】页面的判断:出口不能被空态吞掉,`state` 恒为 `'ok'`

CONV-4 §⑨-4 在 6 张 finance 页面上立过"筛选工具栏是出口"这条。**本刀量到 15 张
带筛选出口的页面**,2.5 倍的爆炸半径,所以它不再是一条"finance 的经验",
而是列表页模板的默认判据。

而本刀把它推广成了 Tim 交代的**一般形式**:

> **如果这一页唯一能动手的地方住在 `empty` 分支会吞掉的位置,那个分支就不能用。**

出口不止是筛选栏。本刀实际遇到的出口有五种:

| 出口种类 | 页数 | 例子 |
|---|---:|---|
| 筛选 / 排序工具栏 | 15 | `hr/employees` · `materials` · `output` · `suppliers` … |
| 抬头新建按钮(住 `actions`,天然安全) | 11 | `hr/departments` · `sales/orders` … |
| **页内的新增表单** | 5 | `OpenPeriodForm` · `NewContainerForm` · `NewForwarderForm` · `CycleForm` · `ImportForm` |
| **子导航** | 2 | `LeaveSubnav`(`/hr/leave` 与 `/hr/leave/balances`) |
| **设置面板** | 2 | `WoThresholdPanel` · `ThresholdPanel` |

**41 张里 39 张 `state` 恒为 `'ok'`。** 两处例外见 ⑩-4。

### ⑩-4 两张【真的用上 empty 分支】的页面,以及它们为什么可以

`ListPage` 的 `actions` / `intro` / `notices` 三个槽**都画在状态分支之前**,
只有 `children` 被 `state==='ok'` 关着。于是:

* **`/inventory/reports/safety`** —— 两个出口(CSV / PDF 导出)是抬头动作,
  住 `actions`。`monitored === 0` 因此可以如实走 `empty`,渲染成 `RefusalBlock`。
  **而这一页原本就把两种空分开说**(「没有人设过任何阈值」≠「所有物料都在
  阈值之上」)——本刀没有把这个区别压平。
* **`/my-reviews`** —— 这一页**没有任何出口**(没有筛选、没有新建),
  空态吞不掉任何东西。顺带:它那句"你的账号还没有关联员工档案"改走
  `state: 'restricted'`,渲染 CONV-0 的 `<RefusalPage>` —— 读者要读的是同一类
  东西(**这里为什么没有东西给我看**),不该另开一条路。

**推论(写给下一刀):** 想用 `empty` 分支,先把出口挪进 `actions` / `notices`。
挪不动的,就恒为 `'ok'`。

### ⑩-5 分组/小计缺口:**仍然是 5 处,不是 6 处**——而第三种排法根本不需要它

机械普查把 `/inventory/reports/snapshot` 标成新的一处(`groupBy` ×2 + 合计 ×3)。
逐行读过之后**判定它不算**:

* §⑨-2 的两种形状都是**一张表里**夹着分组表头行与组内小计行
  (`payables`/`receivables` 运行期按往来对象动态分组;`balance-sheet`/`pnl`/
  `trial-balance` 固定三段 + 派生合计行)——那是 `DataTable`「一行 = 一条记录」
  的契约表达不了的东西。
* `snapshot` 不是:它按库位切成**一段一个 `<section>`、每段一张完整的表**,
  表里没有分组行、没有组内小计,唯一的合计是页顶那条**在所有表之外**的合计条。
  **它用今天的 `DataTable` 就画得出来,一个新口子都不需要。**

另外四处带「合计」字样的(`/hr/payroll` · `/purchasing/payment-terms` ·
`/stocktakes/[id]/review` · `/customers/overlap`)逐个看过,都是**页级的一个数字**
或表外的一句话,不是组内小计。

**缺口计数保持 5 处、两种形状,能力仍然不建。**
Tim 在本刀 Q3 把裁定的理由写成了可以引用的一句话,免得下一刀重新决定:

> **第三种形状是【不建】的证据,不是建的证据。知道得更多,不等于知道得够多。**
> 一套服务三种不同分组形状的通用能力,最可能的结果是三种都服务得很差。

### ⑩-6 RSC 边界:这一刀用满了【三种】过界办法,而不是一种

CONV-1 §① 只写了第一种。本刀 41 张逼出另外两种,三种都记在这里:

| # | 办法 | 什么时候用 | 本刀的例子 |
|---|---|---|---|
| ① | **在服务端压平成纯数据** | 默认。判据、`locale`、`Map`、货币格式一律不过界 | 全部 41 张 |
| ② | **让服务端渲染好的元素当 `ReactNode` 过界** | 那一格的逻辑住在一个**服务端组件**里,重写它就是"殖民地"错误 | `/settings/deleted` 的「谁」列 —— `<ActorName>` 是 async 服务端组件,四种状态里两种要画 `<Refusal>` 药丸、第 ② 种**刻意不画**。把这套判断在客户端重写一遍是这个仓库付过三次账的形状,所以传的是**元素**,不是字符串 |
| ③ | **把函数留在客户端,只传它需要的纯参数** | prop 是**函数**,函数过不了界 | 5 张服务端排序页的 `href(key, dir)` —— 页面传 `filterQuery`(纯对象)+ `sort`/`dir`,链接由客户端拼(CONV-1 在 `/inbound` 先走过) |

### ⑩-7 Q7:服务端排序的 6 张,行为一个字没变

| 页 | 转换前 | 转换后 |
|---|---|---|
| `/suppliers` · `/customers` · `/materials` · `/output` · `/pricing/metal-prices` | 手写 `sortableTh`,表头是带 ▲▼ 的链接 | `DataTable` 的 `sorting.mode: 'server'`,表头仍是链接;`href` 用办法 ③ |
| `/operation/processing` | `sort`/`dir` 由 `ProcessingToolbar` 写 URL,表头是**普通文字** | **不传 `sorting` prop** —— 表头仍是普通文字,排序仍归工具栏 |

**最后一行是一个刻意的不对称**:给 `/operation/processing` 也套上 `sorting`
会凭空多出一套表头排序,而这一页的排序出口本来在工具栏上。
**一张表有两套排序,迟早各说各话。**

**★ 而这一条是【对拍出来的】,不是断言的 ★**
写了一个探针:建一个临时管理员会话,用它的 cookie **真的去 fetch 渲染好的
HTML**,把行序抽出来比:

```
  OK  /suppliers?sort=code             desc == reverse(asc)   (7 行)
  OK  /customers?sort=code             desc == reverse(asc)   (3 行)
  OK  /materials?sort=code             desc == reverse(asc)   (5 行)
  OK  /output?sort=code                desc == reverse(asc)   (14 行)
  OK  /pricing/metal-prices?sort=price_date   desc == reverse(asc)  (10 行)
  OK  /operation/processing?sort=process_date  asc 非递减 · desc 非递增
  OK  /pricing/metal-prices?sort=price_date    asc 非递减 · desc 非递增
  OK  /output?sort=output_date                 asc 非递减 · desc 非递增
```

> **★ 探针的第一版是错的,记下来免得下一刀照抄 ★**
> 第一版对每一页都用"`desc` 是不是 `asc` 的逆序"这一条,于是
> `/operation/processing` 报 FAIL。**错的是判据,不是页面:**
> ① 它按 `process_date` 排,而我抽的是**单号**那一列 —— 日期排序不会让单号有序;
> ② 这一页**分页**(20/页),总行数超过一页时,`desc` 的第 1 页本来就不可能是
> `asc` 第 1 页的逆序。
> 换成"**把排序键那一列抽出来,验它在两个方向上各自单调**"之后全绿 ——
> 这条判据在分页下也成立,而前一条不成立。

### ⑩-8 手机闸的调用点覆盖:数出来的,不是假设的

| | 调用点 |
|---|---:|
| 本刀开工前 | **38**(DataTable 35 · EditableTable 3) |
| hr 段之后 | **48**(+10 = hr 段新建的 10 张表) |
| **41 张全部之后** | **85**(DataTable 82 · EditableTable 3)—— **+47 张新表** |

47 > 41,因为 6 张页面各带多张表(`contracts` 5 张、`snapshot` 2、`violations` 2、
`customers/overlap` 2、`hr/kpi` 1 of 3 段、`settings/reference` 1 个组件用 3 次)。

**故障注入**(拿掉 `AttendanceTable` 全部 `priority`):

```
tsc                      → EXIT 0   ← ★ 类型看不见这一种,这正是闸存在的理由
check-datatable-phone    → EXIT 1
  app/hr/attendance/AttendanceTable.tsx:72
    phone 是 columns 模式,但 columns={columns} 里没有任何一列 priority: true
```

恢复后回到 EXIT 0。**两道网不互相重复,这一次也验了一遍。**

### ⑩-9 两处已知的版式回归,照直写出来

`ListPage` 外壳**硬编码 `p-8`**。41 张里有两张此前用的是更小的边距:

| 页 | 转换前 | 转换后 | 后果 |
|---|---|---|---|
| `/inventory/locations` | `p-4 sm:p-8` | `p-8` | 390px 上左右各多 16px,可用宽度少 32px |
| `/settings/import` | `p-6` | `p-8` | 同上,少 16px |

**两处不建槽**(§⑧-8 那条"第三次才建"的同一条判据)。记在
`manual-walk-list` §26.4;如果人眼确认读不下去,那是 `ListPage` 要开边距槽,
不是这两页各自改回去。

### ⑩-10 关于"信脚本自己的退出码"这条规矩,本刀撞了【三次】

标准规矩是【只信脚本自己日志里的退出码】。本刀三次拿到**外层报告的 exit 0
而脚本自己是失败或根本没跑完**:

1. 基线手机普查:包一层 `sh -c '… ; echo EXIT=$?'`,**最后一条命令是 `echo`**,
   于是外层永远 0;而 `EXIT=` 那行因为引号嵌套根本没写进日志;
2. worktree 里的基线重跑:外层报 exit 0,而日志第一行就是
   `!! survey-phone failed: self-test FAILED`(worktree 用符号链接借
   `node_modules`,Next 认错了项目根);
3. 被我杀掉的那次冒烟:外层报 exit 0,日志里没有任何退出码。

**三次都是"外层壳的退出码"冒充"脚本的退出码"。**
本刀之后一律写成 `cmd > log 2>&1; echo "X_OWN_EXIT=$?" >> log`,
**`echo` 紧跟在被测命令后面、中间不隔任何东西**,再从日志里读那一行。

### ⑩-11 一条被我自己违反、然后照规矩纠正的:一棵树,一次一个冒烟

`docs/concurrency-one-tree-one-smoke.md` 写着冒烟期间这棵树不能变。
本刀第一次跑冒烟时**我一边跑一边继续改文件**——dev server 每次改动都要重编译,
那次运行测的是一棵移动中的树。**结果作废,进程杀掉,改完之后重跑。**
记在这里,因为它不是一条只对并行会话成立的规矩:**一个会话自己也能违反它。**

### ⑩-12 ★ 转换照出一个【闸的洞】:`check-permission-predicate` 认不出反引号

转 `/margin` 时构建变红:

```
✗ 权限不变量被破坏了:
  [② 一个功能几个模块] app/margin/MarginTable.tsx:手写了一个 <Link href="/output">
```

**而这条链接【转换前就在那儿】。** 转换前它写成

```jsx
<Link href={`/output`} className="...">   // 反引号模板串
```

而那道闸的判据是

```js
new RegExp(`<Link[^>]*href=["']${href}["']`)   // 只认单/双引号
```

**于是这个手写的跨模块入口从 `/margin` 建成那天起就没有被看见过。**
本刀把它改成从注册表取(`FN.output.href`,并给 `FN` 补了 `output` 这个访问器)——
既满足不变量,也不改变链接今天指向的地方。

**逐条查过其余三条跨模块条目**(`/commissions` · `/inbound` · `/finance/freight`):
**反引号形式一处都没有,今天没有别的东西藏在这个洞后面。**

**洞本身没有补。** 把正则放宽到认模板串是一次跨 196 页的改动,而本刀已知
它后面是空的 —— **按这个仓库"记而不建"的同一条规矩,记在这里,留给
一次专门的决定。** 补它的那一次要连着跑一遍全仓,因为它可能照出别的东西。

### ⑩-13 手机列的选择:一张可复核的表,而不是四十次追问

Tim 在本刀 Q4 裁定:由本刀按 CONV-4 的启发式(**身份列 + 这张登记簿存在的
理由**)自己挑,把全表列出来供他一次推翻,而不是逐页追问 ——
**四十次阻塞式追问是最差的选项,一张可复核的表是最好的。**

其中 **6 处是本刀自己拍的板、而不是显然的**,已单独点名请人确认;
最值得看的两处:

* **`/hr/kpi` 的联动矩阵故意【不】把「权重合计」放进手机列。**
  页顶那句 `matrixNotWeights` 明说这张矩阵不是权重表 —— 把权重单独留在
  小屏上,会正好造成那句话要防的误读。**这是一次"少给一列"的决定。**
* **`/inventory/reports/snapshot` 与库龄表都留【数量】而不是【价值】。**
  依据是这一页抬头写明它最主要的读者(operations / warehouse)**看不到价**;
  给他们留一列印着"受限"的格子,等于把小屏上两个名额之一浪费掉。

**全表(47 张,`★` = 本刀自己拍的板):**

| 页 | 表 | 留在 390px 的两列 | 挑第二列的理由 |
|---|---|---|---|
| /hr/attendance | AttendanceTable | 期间编号 · 未记行数 | 抬头写明读者第一件要看的是"这个月记满了没有" |
| /hr/claims | ClaimsTable | 单号 · 状态 | settlement_state 回答"钱到底付了没有" |
| /hr/departments | DepartmentsTable | 编号 · 英文名 | 名字是找部门的理由 |
| /hr/employees | EmployeesTable | 工号 · 姓名 | 准证到期徽章挂在工号格里,不会掉进展开区 |
| /hr/kpi | KpiMatrixTable | 职位 · KPI 条数 | ★ 故意不留"权重合计":页顶 matrixNotWeights 明说它不是权重表 |
| /hr/leave | LeaveRequestsTable | 单号 · 状态 | 这是待办清单,状态就是它存在的理由 |
| /hr/leave/balances | BalancesTable | 员工 · 可用天数 | 批准人据以拍板的那一个数 |
| /hr/payroll | PayrollPeriodsTable | 期间 · 实发合计 | 这个月到底付出去多少 |
| /hr/reviews | ReviewsTable | 员工 · 状态 | 在 submitted 里躺三周的评估就是一件待办 |
| /hr/training | TrainingTable | 员工 · 到期日 | 证书过期 = 这个人暂时不能上那道工序 |
| /inventory/locations | LocationsTable | 库位号 · 可存放分类 | 页顶 recordsOnlyNotice 整段在讲那一列 |
| /inventory/reports/ledger | LedgerTable | 批次 · 数量 | 台账存在的理由是"动了多少" |
| /inventory/reports/safety | SafetyTable | 物料 · 缺口 | 4 列表;缺口是"要补多少" |
| /inventory/reports/snapshot | SnapshotGroupTable | 物料 · 数量 | ★ 不留价值:主要读者(operations/warehouse)看不到价 |
| /inventory/reports/snapshot | AgeingTable | 库龄档 · 数量 | 同上 |
| /inventory/reports/violations | ViolationsTable | 库位 · 物料 | ★ 身份是两者【合起来】,少一个这一行读不成话 |
| /inventory/reports/violations | UndecidedTable | 首列 · 数量 | 3 列表;首列是该段主语 |
| /operation/handovers | HandoversTable | 日期 · 签收 | 抬头第一句:未签收的必须一眼看得出来 |
| /operation/orders | WorkOrdersTable | 工单号 · 完成度 | "计划这一侧的入口",还差多少没投 |
| /operation/processing | ProcessingTable | 加工单号 · 损耗 | ★ 拍板项:proc-loss-and-saleability.md 把损耗当一等关切;状态多数时候相同 |
| /operation/wip | WipTable | 批次 · 等哪一道工序 | 这一页回答"下一炉该跑什么" |

★ = 本刀自己拍的板,不是显然的;列进 manual-walk-list §26.1 请人确认。

**其余 21 张(接上表):**

| 页 | 表 | 留在 390px 的两列 | 挑第二列的理由 |
|---|---|---|---|
| /sales/orders | SalesOrdersTable | 单号 · 客户 | 这一单是谁的 |
| /my-reviews | MyReviewsTable | 被评估人 · 状态 | 这一份轮到我做了没有 |
| /logistics/containers | ContainersTable | 箱号 · 最新里程碑 | 这只箱现在到哪了 |
| /logistics/forwarders | ForwardersTable | 货代 · 未结应付 | 与供应商共用 ap_open_items 的全部意义 |
| /settings/reference | PermissionReferenceTable | 权限 · 谁持有 | 这一页就是"谁能看见什么"的答案 |
| /settings/import | ImportHistoryTable | 什么时候 · 哪张表 | 回头查一次导入时先要确定的两件事 |
| /settings/roles | RolesTable | 角色码 · 持有人数 | 改它的后果有多大 |
| /settings/deleted | DeletedTable | 编号 · 为什么 | AUDEL-1b/2 把"为什么删"问出来,那是这一页的目的 |
| /customers | CustomersTable | 编号 · 客户名 | 名单被打开的理由 |
| /customers/overlap | ByTaxTable | 税号 · 客户 | 税号是配对的身份(两侧凭它认成同一家) |
| /customers/overlap | ByNameTable | 客户 · 供应商 | 2 列表;少任何一侧都不成话 |
| /materials | MaterialsTable | 物料号 · 物料名 | 四处"具名的缺席"在展开区里仍是那四句话,不是空白 |
| /output | OutputTable | 批次号 · 可用余量 | 还能卖/还能投多少 |
| /suppliers | SuppliersTable | 编号 · 供应商名 | 名单被打开的理由 |
| /purchasing/orders | OrdersTable | 单号 · 应付总额 | ★ PO-GST-1 之后有三个金额列,应付总额才是"要付多少" |
| /purchasing/payment-terms | TemplatesTable | 模板名 · 付款条件 | 那一串"几成/什么时候"就是模板【是什么】 |
| /pricing/formulas | FormulasTable | 公式号 · 计价基准 | 这条公式算的是什么 |
| /pricing/metal-prices | MetalPricesTable | 金属 · 价格 | ★ 四个判词徽标挂在价格格里,小屏上不会掉进展开区 |
| /stocktakes | StocktakesTable | 盘点单号 · 状态 | 盘完了没有、过账了没有 |
| /stocktakes/[id]/review | ReviewDiffTable | 批次 · 差异 | 差异【就是】这张表存在的理由 |
| /margin | MarginTable | 批次 · 毛利 | Doc 2 说"生意最需要"的那个数 |
| /contracts | BreachesTable | 单据 · 实测 | 实测值是"违反"这件事的证据 |
| /contracts | ContractListTable | 合同号 · 标题 | 这是哪一份合同 |
| /contracts | PricingTermsTable | 合同号 · 指数 | 按什么计价 |
| /contracts | SettlementTermsTable | 合同号 · 计重口径 | SETTLE-1 这一段存在的理由 |
| /contracts | SettlementsTable | 合同号 · 金额 | 4 列表;一条已记录结算的要点 |

**判据本身是可以推翻的**,而推翻它只需要改那一列的 `priority: true` ——
选择住在列描述符里,不住在文档里。

### ⑩-14 手机可用度:★ 先做 tableCount 交叉核对,而这一次它推翻了一半的"之前" ★

按 CONV-3 §④ 的规矩先核对 `tableCount`,再引用可用度数字。

**★ 委托点名的那个盲区,在本刀是一半的量级,不是零星几张 ★**
基线里 **41 张有 9 张 `tableCount = 0`** —— 它们的表**一次都没有被真实渲染过**
(今天的测试数据让它们走了空分支,而一张画不出来的表既不会溢出、也不会被裁):

`/contracts` · `/customers/overlap` · `/hr/attendance` · `/hr/claims` ·
`/hr/leave` · `/hr/reviews` · `/hr/reviews/cycles` · `/inventory/reports/safety` ·
`/my-reviews`

**这 9 张在基线里【全部计为可用】。** 所以"之前"的数必须分两行写:

| | 之前 | 之后 |
|---|---:|---:|
| `survey-phone` 自己报的 USABLE(U1 ∧ U2) | **18 / 40** | **40 / 40** |
| 其中【表根本没画出来】的 | **9** | **5** |
| **真正量到过一张表、且可用的** | **9 / 31** | **35 / 35** |

(41 张里 `/stocktakes/[id]/review` 是动态路由,`--routes=` 只收静态路由,
所以逐路由那一栏是 40。之后仍有 5 张 `tc=0`,**五张全部解释得通**:
`/hr/reviews/cycles` 只套外壳没有 DataTable;`/inventory/reports/safety` 与
`/my-reviews` 走了 `empty` 分支(⑩-4);`/contracts` 与 `/customers/overlap`
各段行数都是 0、由页面自己的"具名缺席句"顶掉了表。**没有一张是漏转。**)

**22 处不可用【全部】是 U1 与 U2 同时失败** —— 基线里 U1 与 U2 的失败集合
恰好重合(各 18/40 通过)。也就是说:这些页面的表比屏幕宽,既把整页顶出
横向滚动(U1),又因为祖先不滚动而把右侧的列彻底裁掉(U2)。
**U2 是那条安静的、也是更坏的:被裁掉的列在屏幕上没有任何东西说它存在。**

转换后 **U1 40/40 · U2 40/40**,溢出量从最多 744px 归零:

| 页 | 之前溢出 | 之后 |
|---|---:|---:|
| `/materials` | +744px | 0 |
| `/purchasing/orders` | +729px | 0 |
| `/output` | +659px | 0 |
| `/pricing/formulas` | +500px | 0 |
| `/hr/training` | +474px | 0 |
| …其余 17 张同样归零 | | |

**一张【不是表格】造成的溢出,单独记一笔:** `/settings/deleted` 转换后仍
溢出 27px,而 `clippedTables` 已经是 0 —— 表那一半修好了,**顶宽的是那条
日期区间筛选行**(`ml-auto` 后面两个日期框 + 按钮排成不折行的 385px)。
加了 `flex-wrap` 之后归零。**记在这里是因为它说明了一件事:
`DataTable` 只管表;一页的手机可用度还可能被表以外的东西毁掉。**

> ★【一处量测方法上的自我更正,写下来免得下一刀重蹈】★
> 本刀第一版打分脚本把 U1 写成 `pageScrollW <= innerW + 1`。
> **那是一个恒真式** —— `innerW` 会随内容撑开(基线 40 条里有 22 条
> `innerW !== vw`,最宽的到 417px),于是"页面有没有超出视口"永远是"没有"。
> 正确的判据是拿 **目标视口 `vw`(390)** 去比,也就是 `overflowPx <= 1`。
> 改对之后,本地打分与 `survey-phone` 自己打印的 `U1 18/40 · USABLE 18/40`
> **逐字对上** —— 那才是这个数可以引用的理由。**工具是对的,我的复算是错的。**

### ⑩-15 这一刀之后还剩什么 —— §⑧-10 那份清单到此清空

**算式是干净的,核对过:** §⑧-1 量到的人口是 **68 = 64 张普通只读列表/报表页
+ 4 张 Kind-E**。CONV-3 转的 7 张里,4 张是那批 Kind-E(在 68 之内),
另外 3 张(Kind-C ×2、Kind-D ×1)**不在这 68 之内**。所以 §⑧-10 留下的正是
那 64 张普通页,而

> CONV-4 的 **23**(finance) + 本刀的 **41**(hr 11 · inventory 5 ·
> operation 4 · 其余 21) = **64** ✓

**列表页这一支到此结束,§⑧-10 的清单没有任何一张遗留。**

按 PAGE-0 §⑩ 的切次提案,后面还剩:

* **第 5 刀 · 详情页(36 张)** —— 它们里面【有就地编辑的面板】,
  所以开工前必须先做本刀 ⑩-1 那一步:**按组件扫,不要按标签名 grep**,
  否则又会得到一个"零张可编辑网格"的假数。
* **第 6 刀 · 表单页** —— CONV-2 的可编辑网格模板管这一支。

**三件留给设计时间,不留给下一刀"顺手做":**

1. **分组/小计能力**:5 处、两种形状(⑩-5 复核过,`snapshot` 不算第六处)。
   Tim 在本刀 Q3 的裁定连理由一起写下了,下一刀不必重新决定。
2. **`check-permission-predicate` 的反引号洞**(⑩-12):今天它后面是空的,
   补它要连着跑一遍全仓。
3. **`ListPage` 的边距槽**(⑩-9):两处回归,按"第三次才建"不建。

### ⑩-16 只有人能确认的事

见 `docs/manual-walk-list.md` §26。**一处都还没有人走过。**
其中最要紧的一条是 §26.1:**30 张表各自留在 390px 上的那两列是一个判断,
不是一个测量** —— 闸测得出"有没有声明",测不出"留下来的是不是对的两列"。
