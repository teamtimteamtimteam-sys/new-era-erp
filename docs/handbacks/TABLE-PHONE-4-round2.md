# TABLE-PHONE-4 交回报告 —— 录入表单里的行编辑表

**九张里做了八张,八次判断。** 第九张 `NewOrderForm:786` **不是行编辑表,
而且整张没有 `<thead>`** —— 它是 `ContainerPanels:119` 的第二例,登记不动。

---

## 1 · HEAD、与 e516194 的差别、树

| | |
|---|---|
| HEAD(开工前) | `8f319ac` |
| origin/main(开工前) | `8f319ac` —— **相等** |
| 树 | 干净(`git status --porcelain` 0 行) |
| HEAD(收工后) | 见文末 §12 |

**与 e516194 的差别:恰恰是委托书 §0 预测的那一种,一条,而且只有一条。**

```
8f319ac TABLE-PHONE-3 交回报告 §12:补齐推送与部署的实测记录 —— 部署 6346131737
        success,两个问题分开问过,窗口 150s(第三个数据点,150-165s 已成规律)
 docs/handbacks/TABLE-PHONE-3-round2.md | 103 +++++++++++++++++++++++++++++++++
 1 file changed, 103 insertions(+)
```

**纯文档,只动上一刀自己的交回报告,`git merge-base --is-ancestor e516194 HEAD` = 是。**
按 §0 的授权 PROCEED。**这是连续第五刀了 —— 委托书里的哈希稳定地落后一格,
而原因已经查明并写在 §0 里,不必再查。**

---

## 2 · 人口普查 —— 对着文件量,不照委托书抄

**★ 委托书 §3 说批次表权威。逐条量下来,批次表的九个文件路径与行号【全对】,
而它对其中一张表【说的是什么】是错的。**

| # | 文件:行 | 桌面列数 | 还没包过? | 还没动过? | 判定 |
|---|---|---|---|---|---|
| 1 | `finance/invoices/new/NewInvoiceForm:272` | 6 | 是 | 是 | 做 |
| 2 | `finance/payments/new/NewPaymentForm:504` | 5 | 是 | 是 | 做 |
| 3 | `finance/invoices/[id]/CreateCreditNoteControl:101` | 7 | 是 | 是 | 做 |
| 4 | `finance/bank/import/ImportStatementForm:390` | 5 | 是 | 是 | 做 |
| 5 | `finance/freight/new/NewFreightForm:225` | **5 / 4(有条件)** | 是 | 是 | 做(只做 5 列支) |
| 6 | `sales/orders/[id]/amend/AmendOrderForm:141` | 8 | 是 | 是 | 做 |
| 7 | `purchasing/orders/[id]/amend/AmendOrderForm:135` | 6 | 是 | 是 | 做 |
| 8 | `sales/quotes/[id]/QuoteLinesEditor:65` | **6 / 5(有条件)** | 是 | 是 | 做(两支同一组) |
| 9 | `purchasing/orders/new/NewOrderForm:786` | 5 | 是 | 是 | ★ **不做 —— 整张无 `<thead>`** |

**开工前树里 8 个文件的 `sm:table-cell` / `sm:hidden` 命中数 = 0**,`colSpan` 只有 1 处
(`QuoteLinesEditor:148`)—— 与「还没动过」一致。

### 2.1 · 行号对得上,但要说清它们是【哪一版】的行号

`NewOrderForm` 现在的两张表在 `:804` 与 `:876`,不在 `:786` / `:858`。
**批次表用的是 TABLE-PHONE-3 之前的行号**(`git show e516194^:…` 逐字为 786 / 858),
那一刀在文件靠前处加了 18 行。**两个都对得上,不是漂移。**

### 2.2 · ★ 本刀量过、并发现【为假】的断言:一条

> **委托书 §3:「`NewOrderForm:786` …… **THIS CUT FINISHES THAT FILE**。Say so.」**
> **量下来:做不完,而且原因不是工时。**

`:786` 那张表是这样的:

```jsx
{l.calc && l.calcOpen && (
    <div className="mt-2 bg-gray-50 rounded p-3 text-xs space-y-1">
        <p …>{l.calc.formula_code} — {l.calc.formula_name} · {l.calc.reference_date}</p>
        <table className="border-collapse">
            <tbody>                                   ← ★ 直接就是 tbody
                {l.calc.lines.map((cl) => (
                    <tr key={cl.metal}>
                        <td>{t('metals.' + cl.metal)}</td>   金属
                        <td>{cl.content_pct}%</td>           含量%
                        <td>× {cl.payable_pct}%</td>         计价%
                        <td>… USD/t</td>                     单价
                        <td>… </td>                          金属价值
```

* **整张没有 `<thead>`,一个 `<th>` 都没有**(实测该区段 `thead|<th ` 命中 **0**);
* **它不是行编辑表** —— 是「计算估价」折叠面板里一段**只读的算式明细**,
  五列全是数字和百分号,没有一个是自带文字的控件;
* 折叠任何一列都要**现造一句话**,而委托书 §5 明写「No new i18n keys」。

☞ **处置照 §3 的既定做法:登记,跳过这一张,做完其余八张,不停批。**
☞ **量具独立复核过这个判断**(见 §5.4):它对着这张表给出的是
  **「★ 整张表没有 `<thead>` —— 拒绝判定」+ 退出码 1**,
  **不是一句"没有折叠块"的静默 0。**
☞ 所以 **`purchasing/orders/new/NewOrderForm` 今天仍然是半张脸**,
  而这一次卡住它的是**裁定**,不是排期。已拆成 TABLE-PHONE-7(§7)。

---

## 3 · 八次判断,一行一个理由

**通例:录入表留四列(Tim 裁定)。第四格给【要打字的】,不给【算出来的】(TABLE-PHONE-3 先例)。**

| # | 表 | 桌面列 | 手机留的四列 | 折叠掉的 | **理由(一行)** |
|---|---|---|---|---|---|
| 1 | `NewInvoiceForm:272` | 6 | 勾选 · 品名 · 日期 · 金额 | 数量 · 单价 | 这张表**要动手的只有第一列那个勾**,而勾之前人核的是「哪一笔」(品名+日期)和「会开多少钱」(金额);数量×单价是金额的来路,读得到就够。 |
| 2 | `NewPaymentForm:504` | 5 | 单据 · 估算总额 · 已预付 · 本次冲销 | 下单日期 | 能预付多少由**「估算总额 − 已预付」**决定,**两个数缺一个这一格就填不成**;下单日期只是认单据,而单据号已经在。 |
| 3 | `CreateCreditNoteControl:101` | 7 | # · 发票行 · 数量 · 冲减 | 尚未交付 · 已交付可冲减 · 类型 | ★ **不是偏好,是正确性**:`cn_qty` 带 `name`,折叠它就会重复提交(§4.2);类型那个 `<select>` 不带 name,是这张表唯一能安全画两份的控件。 |
| 4 | `ImportStatementForm:390` | 5 | 行号 · 日期 · 摘要 · 金额 | 参考号 | **上面那条报错清单指的就是行号**(「行号 7: …」),拿掉它清单在手机上就指不着东西;参考号是核对时才查的第二身份。 |
| 5 | `NewFreightForm:225` | **5**(stated 支) | 勾选 · 批次 · 数量 · 分得 | 剩余 | 分摊运费分的是「这一票走了多少」,**数量就是分母**;剩余是仓里还剩多少,那是另一件事。末列是唯一要打字的地方,必留。 |
| 6 | `sales/…/AmendOrderForm:141` | 8 | # · 物料 · 已订 · 单价 | 已开票 · 已预留 · 已发 · 删除 | 改一张销售单,**手指落在已订与单价上**,两个输入框都留住;三个「已」是读的数,而**下限告警本来就印在数量框底下**,所以「已发多少」在真要用它的那一刻仍在眼前。 |
| 7 | `purchasing/…/AmendOrderForm:135` | 6 | # · 数量 · 单价 · 价格(定价状态) | 已收 · 删除 | ★ **三条并列数组**(`line_quantity`/`line_price`/`line_price_status`)**全部带 name,一列都折叠不得**(§4.2);折叠的两个里,删除那个复选框不带 name。 |
| 8 | `QuoteLinesEditor:65` | **6 / 5** | # · 物料 · 数量 · 单价 | 金额 · 动作列 | **金额 = 数量 × 单价,两个乘数都在明面上而且都要动手**;一个读得到的算式结果放折叠区不多花点击 —— 这正是「第四格给要打字的」那条。**两支留同一组**,于是人在两种状态下看的是同一张表。 |

### 3.1 · 两处的第一列是硬编码的 `#`,处置是【留在明面上】

`CreateCreditNoteControl` 与两张 `AmendOrderForm` 的第一列列头写的是字面量 `#`,
**没有 i18n key**。委托书 §3 把这一类列成「登记、跳过整张表」。

☞ **本刀的判断:一列【不被折叠】就不需要标签,于是一句都不用造。**
把 `#` 留在四列之内,**新增 key 0 个、现造文案 0 处**,规矩一个字没破。
而行号本来就是这几张表跟人对话时用的号码 —— 报错、审计、`ConfirmButton` 的主语
(`#${l.line_no} · ${l.material}`)指的都是它。
☞ **另一条路是照 `ContainerPanels` 那样整张跳过。为一个 `#` 跳掉三张能干净做完的表,不值。**
☞ **这是我自己下的判断,登记在 §8。** `NewOrderForm:786` 那种「整张没有列头」
  没有这条出路 —— 它要折叠的是**四列数据**,只能停下。

### 3.2 · 两张有条件列,两支各量一次(GoalsEditor 先例)

* **`NewFreightForm`** —— `basis === 'stated'` 5 列,否则 4 列。
  **四列那一支本来就在免修档里,所以折叠只在 5 列那一支生效**:
  列头与单元格共用一个 `const stacked = basis === 'stated'`,
  **写在一处** —— 两边各写一个条件,就是让它们将来各走各的。
* **`QuoteLinesEditor`** —— `editable` 6 列 / 只读 5 列,**两支留的是同一组四列**。
  `colSpan` 因此写两份(R-Q1 的代价):手机档恒为 `4`,桌面档 `editable ? 6 : 5`。

---

## 4 · ★ 折叠区里的【输入框】怎么摆,以及【一个控件存在两份】会怎样

### 4.1 · 版式:读的数一行一个,能点的东西单独一行、标签在左

折叠块沿用 `/finance/payables` 那一块的骨架
(`sm:hidden mt-1 space-y-* font-sans text-xs text-gray-600`),但**分成两种行**:

```jsx
{/* 读的数:标签 + 值,同一行,和 payables 一样 */}
<div className="font-mono">
    <span className="font-sans text-gray-500">{t('cn.colUnreleased')}: </span>
    {unreleasedText}
</div>

{/* 能点的控件:自己占一行,flex,标签 shrink-0 不被挤扁 */}
<div className="flex items-center gap-1">
    <span className="text-gray-500 shrink-0">{t('cn.colKind')}: </span>
    {kindSelect}
</div>
```

**理由,按委托书 §2 的要求说出来:**
* **读的数**沿用旧写法就够 —— 它们本来就是一行字。
* **能点的控件**(`<select>`、复选框、按钮组)给一整行,而且
  **标签 `shrink-0`**:一个被挤在窄缝里的下拉框不算"还能用",而 flex 默认会压缩它。
  `space-y-0.5` 也放宽成 `space-y-1`,因为这一行里有一个有高度的控件。
* **`items-center` 用在 `<select>` 上,`items-baseline` 用在复选框 + 文字上** ——
  前者是个盒子,后者是一行字。
* **没有动任何输入框的高度、内边距、边框、字号**(§7)。折叠区里的控件与桌面档
  **逐字是同一个元素**(见下),所以它连改的机会都没有。

### 4.2 · ★★ 一个控件存在两份会怎样 —— 量出来的,不是推的

**先说结论:本刀【一个带 `name` 的输入框都没有被复制】,而这不是运气,是选列的判据之一。**

`app/components/forms/DecimalInput.tsx` 文件头自己写着:

> 「给了 `name` 时额外渲染一个**同名 hidden input**,保证 `<form action>` 的非受控提交照常拿到值。」

而**折叠一列是用 CSS 藏**(`hidden sm:table-cell`)—— `display:none` 的 input
**照样在 DOM 里,照样提交**。于是:

> ### **凡是格子里有【带 name 的输入框】的列,一律留在明面上。**
> 把它折叠 = 每行往那条并列数组里多塞一格 = 整组配对当场错位。

**这不是理论。`purchasing/…/amend/AmendOrderForm` 的原注就写着 PUR-1 刚修掉的
同一个错位**(下标前移一格,勾掉最后一行时不发作,所以它活了很久)。
**折叠 `line_price_status` 会把它原样装回去,而且是无声的。**

逐表点名(实测每一处 `name=` 的归属):

| 表 | 带 name 的控件 | 在哪一档 | 被复制? |
|---|---|---|---|
| `NewInvoiceForm` | `sale_id`(hidden,勾选时才画) | **留** | 否 |
| `NewPaymentForm` | `alloc_id` · `alloc_kind` · `alloc_amount` | **留** | 否 |
| `CreateCreditNoteControl` | `cn_line_id` · `cn_kind`(第一格) · `cn_qty` · `cn_amount` | **全留** | 否 |
| `ImportStatementForm` | 无(整张只读) | — | — |
| `NewFreightForm` | `batch_id` · `stated_amount` | **留** | 否 |
| `sales/…/AmendOrderForm` | `line_id` · `line_remove`(第一格) · `line_quantity` · `line_price` | **全留** | 否 |
| `purchasing/…/AmendOrderForm` | 同上 + `line_price_status` | **全留** | 否 |
| `QuoteLinesEditor` | **一个都没有**(受控 state + server action 参数) | — | — |

**被复制的那三个控件,逐个查过它们经不经得起复制:**

| 控件 | 为什么复制是安全的 |
|---|---|
| `cn.colKind` 的 `<select>` | **不带 `name`** —— 值由第一格里**渲染一次**的 `<input type="hidden" name="cn_kind">` 携带。两份共用同一个 `k` / `setKind`,受控值一致。 |
| 两张 `AmendOrderForm` 的删除复选框 | **不带 `name`** —— 值由第一格里渲染一次的 `line_remove` hidden 携带。两份共用 `remove[l.id]` / `setRemove`。 |
| `QuoteLinesEditor` 的保存钮 + `ConfirmButton` | 见下。 |

**`ConfirmButton` 经不经得起复制(照 TABLE-PHONE-2 的判据重查了一遍,结论相同):**
* `id` 来自 **`React.useId()`**(`confirm-dialog.tsx:124-125`)—— 每个实例各不相同,**没有写死的 DOM id**;
* **不开 portal**(全文 `createPortal` 命中 0)—— 对话框就地渲染在那个 `<td>` 里;
* `keydown` 监听器**只在对话框组件挂载时才装**,而它只在 `open` 为真时渲染(`open` 是 per-instance 的 `useState`);
* **`display:none` 那一份点不开、也 tab 不到**,所以它的 `open` 永远是 `false`,那个全局监听器永远不会装第二个。

**★ 而防漂移靠的不是"两份写得一样",是【提出来写一次】。** 八张表里凡是两档都要出现的
内容,一律先在 `map` 回调里做成 `const`,两处**引用同一个描述**:
`unreleasedText` / `releasedText` / `kindSelect`(CCNC)·
`invoicedText` / `reservedText` / `shippedText` / `removeControl`(销售)·
`receivedText` / `removeControl`(采购)· `lineTotalText` / `rowActions`(报价)。
**抄成两份就是让两份将来各走各的,而漂移在桌面上是看不见的 —— 桌面那一份永远是对的那一份。**

---

## 5 · 一个字段都没丢 —— 校准、全表、两次咬人

量具:`nofieldlost.mjs`,**不进仓库**(裁定 R-Q8)。判据五条,全部会红:

1. `thead` 里的 `<th>` 数 = 桌面列数;带 `hidden sm:table-cell` 的是被折叠的。
2. **折叠块的【直接子项】数 = 被折叠的列数** —— 数**项**不数标签(一个 `<div>` 里套三个 `<span>` 仍是一项)。
3. **每一项都要带标签**,除非在这张表自己的 self-labelling 白名单里。
4. **覆盖率是一条断言**:读出 0 个 `<th>`、找不到 `<thead>`、找不到折叠块、折叠块 0 项 —— **一律红**,绝不当成 0。
5. **scope 必须显式声明并印在结果行里。**

**注释先剥掉**(带字符串/模板串识别,长度与行号都不移)。
**`t()` 的参数用【括号配平】读,不用正则** —— TABLE-PHONE-3 的标签正则错了三次,
配平写法对 `t('cn.colAmount', { ccy: currency })` 与 `t('x', {0: y})` 都成立。

### 5.1 · 校准行(未改动的 `/finance/payables`)先跑

```
  绿  CALIBRATION /finance/payables 桌面 8 列 · 手机留 3 · 折叠 5 · 叠加项 5 · 无标签 0/白名单 0
      [scope: 行内 —— 行渲染在同一个组件里(page.tsx 的 groups.map)]
CALIB_OWN_EXIT=0
```
**8 = 3 + 5,五项全带标签 —— 与那张表已知的事实逐字相符。**

### 5.2 · 全表(校准行 + 八张)

```
  绿  CALIBRATION payables       桌面 8 列 · 手机留 3 · 折叠 5 · 叠加项 5 · 无标签 0/白名单 0  [scope: 行内(groups.map)]
  绿  NewInvoiceForm             桌面 6 列 · 手机留 4 · 折叠 2 · 叠加项 2 · 无标签 0/白名单 0  [scope: 行内(visible.map)]
  绿  NewPaymentForm(预付)         桌面 5 列 · 手机留 4 · 折叠 1 · 叠加项 1 · 无标签 0/白名单 0  [scope: 行内(pos.map);同文件 :566 那张 4 列免修,不在本批]
  绿  CreateCreditNoteControl    桌面 7 列 · 手机留 4 · 折叠 3 · 叠加项 3 · 无标签 0/白名单 0  [scope: 行内(lines.map)]
  绿  ImportStatementForm        桌面 5 列 · 手机留 4 · 折叠 1 · 叠加项 1 · 无标签 0/白名单 0  [scope: 行内(parsed.rows.slice(0,20).map)]
  绿  NewFreightForm(stated 支)   桌面 5 列 · 手机留 4 · 折叠 1 · 叠加项 1 · 无标签 0/白名单 0  [scope: 行内(batches.map);列数有条件,本行量的是 basis==='stated' 的 5 列支]
  绿  AmendOrderForm(销售)         桌面 8 列 · 手机留 4 · 折叠 4 · 叠加项 4 · 无标签 0/白名单 0  [scope: 行内(lines.map);同文件 :250 那张 3 列免修,不在本批]
  绿  AmendOrderForm(采购)         桌面 6 列 · 手机留 4 · 折叠 2 · 叠加项 2 · 无标签 0/白名单 0  [scope: 行内(lines.map)]
  绿  QuoteLinesEditor           桌面 6 列 · 手机留 4 · 折叠 2 · 叠加项 2 · 无标签 1/白名单 1  [scope: 行内(lines.map);列数有条件,量的是 editable 的 6 列支(只读支 5 列,留的是同一组四列)]

全绿:9 张表,一个字段都没丢。
NOFIELD_OWN_EXIT=0
```

**白名单只有一条**:`QuoteLinesEditor` 末列的**列头是真的空**,格子里两个按钮各自带着
自己的字(保存 / 删除)—— 照既定做法在折叠区里原样画出来,不现造文案。
**其余七张表里被折叠的每一列都有自己的列头 key,所以一条白名单都不需要。**

★ **两个「删除」列本来可以走白名单**(复选框自带文字),**本刀选了照旧贴列头**,
理由是让断言保持最严:`删除: ☐ 删掉这一行` 略嫌重复,但**它让"每一项都有标签"这条
判据一个例外都不用开**,而一条不用开例外的判据更难被将来放松。登记在 §8。

### 5.3 · 咬人两次,两种咬法,各带自己的退出码

**咬法一 —— 整条删掉一个叠加项**(销售 `AmendOrderForm` 的「已预留」那一块):

```
★ 红  AmendOrderForm(销售)  桌面 8 列 · 手机留 4 · 折叠 4 · 叠加项 3 · 无标签 0/白名单 0
        └─ 折叠项 3 ≠ 被折叠列 4
★ 1 张表红。
BITE1_OWN_EXIT=1
```

**咬法二 —— 只删【标签】,值原样留着**(同一处,只拿掉那个 `<span>{t('…colReserved')}: </span>`):

```
★ 红  AmendOrderForm(销售)  桌面 8 列 · 手机留 4 · 折叠 4 · 叠加项 4 · 无标签 1/白名单 0
        └─ 无标签项 1 ≠ 白名单 0
★ 1 张表红。
BITE2_OWN_EXIT=1
```

★ **咬法二正是这条量具存在的理由:项数等式 `4 = 4` 【照样成立】,是标签断言把它咬红的。**
一个只数项数的量具会给这次改动发合格证 —— 而屏幕上会留下一个**没有主语的数字**。

**还原:**
```
RESTORE_OWN_EXIT=0        全绿:9 张表,一个字段都没丢。
cmp 原件 vs 还原件 → 逐字节相同
```

### 5.4 · ★ 量具对着 `NewOrderForm:786` 说了什么

```
★ 红  NewOrderForm:786(计价明细)  ★ 整张表没有 <thead> —— 拒绝判定(scope: 行内(l.calc.lines.map))
NOTHEAD_OWN_EXIT=1
```

**它红了,而且说出了自己为什么答不了** —— **不是一句静默的「叠加项 0」。**
这就是 TABLE-PHONE-3 那条教训(「找不到叠加块」不许读成「没有叠加块」,因为 0 条正好会静静通过)
在本刀的兑现,也是 §2.2 那个跳过决定的独立复核。

---

## 6 · 复用的 i18n key —— 一个都没新增、没改、没删

**`messages/` 的 diff 是 0 行**(见 §12 的 `git show --stat`)。

| key | English | 中文 | 用在 |
|---|---|---|---|
| `invoice.colQuantity` | Quantity | 数量 | NewInvoiceForm 折叠 |
| `invoice.colUnitPrice` | Unit price | 单价 | NewInvoiceForm 折叠 |
| `purchasing.colOrderDate` | Order date | 下单日期 | NewPaymentForm 折叠 |
| `cn.colUnreleased` | Not yet delivered | 尚未交付 | CCNC 折叠 |
| `cn.colReleased` | Delivered, creditable | 已交付、可冲减 | CCNC 折叠 |
| `cn.colKind` | Reason type | 类型 | CCNC 折叠(标签 + `<select>`) |
| `bank.colReference` | Reference | 参考号 | ImportStatementForm 折叠 |
| `finance.freight.colRemaining` | Remaining | 剩余 | NewFreightForm 折叠 |
| `sales.amend.colInvoiced` | Invoiced | 已开票 | 销售 AmendOrderForm 折叠 |
| `sales.amend.colReserved` | Reserved | 已预留 | 销售 AmendOrderForm 折叠 |
| `sales.amend.colShipped` | Shipped | 已发 | 销售 AmendOrderForm 折叠 |
| `sales.amend.colRemove` | Remove | 删除 | 销售 AmendOrderForm 折叠(标签 + 复选框) |
| `purchasing.amend.colReceived` | Received | 已收 | 采购 AmendOrderForm 折叠 |
| `purchasing.amend.colRemove` | Remove | 删除 | 采购 AmendOrderForm 折叠(标签 + 复选框) |
| `quotes.colLineTotal` | Amount | 金额 | QuoteLinesEditor 折叠 |

**全部是那一列自己的列头 key,原样搬进折叠区** —— 一处都没有借用别的列的 key。
`check-i18n` 在构建里绿(§11)。

---

## 7 · 队列与档案

**`docs/forward-queue.md`** 与 **`docs/known-issues.md` 的 RAW-TABLE-PHONE-SWEEP** 都已更新。

* **TABLE-PHONE-4 划掉:8 次判断 / 8 张表 / 8 个文件。**
* **剩下:2 张表 / 2 个文件** —— `10 − 8 = 2`,对得上。
* `NewOrderForm:786` **从 TABLE-PHONE-4 拆出来,单列 TABLE-PHONE-7**(1 张 / 判断数 0 / 待裁定),
  理由与 `ContainerPanels:119` 的 TABLE-PHONE-6 逐字相同。
* **`purchasing/orders/new/NewOrderForm` 【没有】做完** —— 委托书要求「say so」,
  说清楚了:`:858` TABLE-PHONE-3 做了,`:786` 卡在裁定上,**它今天仍然是半张脸**。

### ★★ Tim 需要知道的那个状态,照直说:

> **除掉这两张缺列头的表 + 那 9 张 UNMEASURED 的带滚动外壳的表,
> `RAW-TABLE-PHONE` 这一族【已经空了】。**

而**这两张剩下的,卡的都是【同一个裁定】,不是工时:**

| 批 | 表 | 要批几个 key |
|---|---|---|
| TABLE-PHONE-6 | `ContainerPanels:119` | 4(发货单号 / 订单号 / 客户 / 发货日) |
| TABLE-PHONE-7 | `NewOrderForm:786` | 5(金属 / 含量% / 计价% / 单价 / 金属价值) |

**触发条件因此从「没有了」变回【要一个裁定】:这 9 个 key 批不批?**
批了,两张各是一次判断、半刀的工;不批,这一族到此为止 ——
**而那也是一个可以接受的结局,只要它是说出来的。**

---

## 8 · 我自己定的、属于细节而不是形状的几件事

1. **两处硬编码的 `#` 留在明面上,而不是整张跳过。**(§3.1)
   **这是本刀最大的一个自决**,虽然它没有改变任何形状 ——
   新增 key 0、现造文案 0,而它让三张表能干净做完。**另一条路写在 §3.1 里。**
2. **两个「删除」列贴上自己的列头,不走 self-labelling 白名单。**(§5.2)
   略有重复(`删除: ☐ 删掉这一行`),换来的是「每一项都有标签」这条判据一个例外都不开。
3. **折叠块挂在哪一格。** 通例是身份格;**采购 `AmendOrderForm` 没有物料列**,
   于是挂在 `#` 那一格 —— 它是那张表唯一的身份。**代价见 §10。**
4. **`NewFreightForm` 的折叠做成有条件的**(`const stacked`),而不是两支都折。
   四列那一支本来就免修,**一刀不动它**比"顺手也折了"更守规矩。
5. **两个 JSX 注释改写成 JS 注释。** `NewInvoiceForm` 与 `ImportStatementForm` 的表
   住在**表达式位置**(一个三元、一个 `&&`),那里 `{/* */}` 不合法 ——
   `tsc` 当场报 8 条语法错。改成裸 `/* */`,内容一字未动。
6. **保留列的内边距一律 `px-2 sm:px-3`(或 `sm:px-4`,随原值)**,照 payables 的做法;
   **被折叠的列保持原样**(反正手机上不画)。

---

## 9 · Tim 该去哪儿走 —— 390px 设备模拟,**每一张都要先让它长出行来**

★ **录入表的坑在这里:表单要处在【渲染得出行】的状态,否则那张表根本不出现。**
逐张写清楚**先做什么**,以及**线上今天有没有东西可看**:

| # | 走到哪儿 | ★ 先要有 / 先要选什么 | 线上今天有货吗 |
|---|---|---|---|
| 1 | `/finance/invoices/new` | **先在下拉里选一个客户** —— 没选客户只有一句「请先选客户」;选完还要那个客户名下**有待开票的销售**。 | 有(销售记录若干) |
| 2 | `/finance/payments/new` | 选**付款方向 + 供应商**;那张预付表**只在该供应商有可预付的采购单时出现**(`partyId && pos.length > 0`)。 | **不确定** —— 要有未预付完的 PO |
| 3 | 某张发票详情 → **开立贷记单** | 打开一张**未作废的**发票,点「开立贷记单」把面板展开 —— 表在面板里。 | 有发票 |
| 4 | `/finance/bank/import` | ★ **要真的选一个 CSV 文件并把日期/金额列映射好** —— 预览表只在 `parsed.rows.length > 0` 时出现。**不选文件永远看不到它。** | 需自带一个 CSV |
| 5 | `/finance/freight/new` | **方向选【进境】**(出境没有批次表),**并且把分摊口径选成「指定金额」**才是 5 列那一支;选重量/价值是 4 列(免修档)。 | 有批次 |
| 6 | 某张销售订单 → `/amend` | 订单要**可改**(未冻结);表里要**有明细行**。 | 有 |
| 7 | 某张采购订单 → `/amend` | 同上。 | 有 |
| 8 | 某张报价单详情 | 报价单要**有行**;`editable` 为真才有末列动作(保存/删除),为假是 5 列只读支 —— **两支都值得看一眼,因为它们留的是同一组四列**。 | 有 |

★ **诚实地说一句:第 2 张和第 4 张我【没法保证线上有东西可看】。**
第 4 张(银行导入)必须自带一个 CSV 才看得到那张表;第 2 张要供应商名下有可预付的 PO。
**与其把 Tim 支去看一个空页面,不如先说清楚。**

---

## 10 · ★ 我【没能验证】的东西

**通例(这一族一直如此):没有浏览器,一个像素都没量过。下面每一条都是"写出来的标记",
不是"看到的结果"。** 委托书 §1.E 明写这一点,这里逐条落到具体的表上。

### 10.1 · 最要紧的一条:采购 `AmendOrderForm` 大概仍然放不下

**四列里三列是控件**:两个 `w-28`(7rem = 112px)的 `DecimalInput` + 一个 `<select>`,
加上第一格那个带折叠块的 `#`。**光三个控件就 336px 上下,再加边框与内边距,
390px 大概率不够。**

* 它是**本批最挤的一行**,而且**这三列一列都折叠不得**(§4.2 的正确性约束)。
* **收窄输入框是 §7 明说归样式普查的事**(输入框高度/内边距那一条),本刀一个字没动。
* **登记了,没有量。**

### 10.2 · `NewFreightForm` 那个 `overflow-y-auto` 可能已经让它能横滚了

批次表外面套着 `<div className="border … max-h-96 overflow-y-auto">`。
按 CSS 规范,`overflow-y` 非 `visible` 而 `overflow-x` 是 `visible` 时,
**`overflow-x` 的计算值会变成 `auto`** —— 也就是说它**事实上可能已经能横向滚动**,
那会让它更接近 `RAW-TABLE-PHONE-WRAPPED` 那一族(UNMEASURED)而不是这一族。
**批次表是权威的,所以照做了;但这条观察登记下来。没有量。**

### 10.3 · 折叠区里那三个控件在 390px 上够不够点

`<select>`(CCNC 的类型)与两个复选框(两张 AmendOrderForm 的删除)现在住在折叠区里。
**版式是照 §4.1 那样摆的(整行、标签 `shrink-0`),但"够不够点、会不会换行"没有量过。**

### 10.4 · ★ 会换行的列头 —— 英文是风险,中文短得多

**沿用 TABLE-PHONE-3 的做法逐个点名。留在明面上的列头里,英文最长的这几个:**

| key | English | 中文 | 在哪一张 | 风险 |
|---|---|---|---|---|
| `purchasing.colEstimatedTotal` | **Estimated total**(15) | 估算总额(4 字) | NewPaymentForm | ★ **最长的一个**,右对齐的钱列,英文八成换行 |
| `sales.amend.colPrice` / `quotes.colUnitPrice` / `purchasing.amend.colPrice` | **Unit price (USD)**(16 含币种) | 单价(USD) | 三张 | ★ 带 `{ccy}` 参数,**实际比字面更长** |
| `bank.colDescription` | Description(11) | 摘要(2 字) | ImportStatementForm | 中 |
| `invoice.colDescription` | Description(11) | 品名(2 字) | NewInvoiceForm | 中 |
| `finance.colAllocate` | Allocate(8) | 本次冲销(4 字) | NewPaymentForm | 低 |
| `cn.colAmount` | **Credit (USD)** | 冲减(USD) | CCNC | 中,带参数 |
| `purchasing.colPrepaid` | Prepaid(7) | 已预付(3 字) | NewPaymentForm | 低 |

☞ **`NewPaymentForm` 一张表上就占了三个**(估算总额 / 已预付 / 本次冲销),
而它还留着四列 —— **英文档下这一张最可能被列头撑开**。
☞ **被折叠掉的那些列头不在这张风险表里** —— 它们只作为折叠区里的行内标签出现,
在那里换行是正常的、也没有代价。
☞ **中文档普遍短一半以上**,所以**英文才是这一族的风险面**,与 TABLE-PHONE-3 的结论一致。

### 10.5 · 其余

* **`sm:` 断点是否恰好落在 640px、`hidden sm:table-cell` 在 `<td>` 上的表格布局行为** —— 照 payables 抄的,没有量。
* **条件列那两张在【另一支】上的实际观感** —— 逻辑上复量过(4 列支免修 / 只读支同一组),但没有量过像素。
* **`ImportStatementForm` 与 `NewInvoiceForm` 那两张【整行没有输入框】** ——
  四列是本批统一的档(委托书 §2 说该裁定管整批),而**"录入表留四列"的理由(少点一次)
  在这两张上并不成立**。照批做了,登记这个观察。

---

## 11 · 收尾判词

### `db/gate.py` —— **本刀没有 SQL,按 §11 照跑**

```
GATE_OWN_EXIT=0            wall-clock 277s   (180–700s 之内,不必放宽)
```

四条判词,逐字:

```
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
   判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
```

### `npm run build`

```
BUILD_OWN_EXIT=0
```

```
── eslint 冻结闸 ─────────────────────────────────────────────
基线  error 42 · warning 88
现在  error 42 · warning 88
✓ 没有新增的 eslint 问题。
```

**元检查:**
```
✓ check-instrument-selfproof:32 支量具都写了瞄准线;其中 22 支(构建链里的,含本支)都带着覆盖断言。
```

**`check-datatable-phone` —— 仍然 123,证明一张都没转:**
```
✓ 手机声明:123 个调用点(DataTable 119 · EditableTable 4) —— columns 模式 123(各自至少一列 priority)· scroll 模式 0(各自带 why) · 静态读不出 1(由渲染期那道网兜着)
```

**另:`npx tsc --noEmit` 也是 0**(它是便利品不是闸,但那 8 条 JSX 注释语法错就是它先报出来的)。

