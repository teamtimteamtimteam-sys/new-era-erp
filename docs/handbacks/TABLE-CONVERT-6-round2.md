# TABLE-CONVERT-6 交回报告 —— 十八张【读】完了,而【只有四张真的能转】

> ### ☞ 一句话的读数
> **任务一的答案是 4,不是 18。** 逐张读下来,**十四张归错了类** ——
> 九张是 B(格子里住着受控输入,只是【不带 `name`】,所以上一刀那支筛子看不见)、
> 三张是 E(组间小计 / 分节合计行)、两张是 F(枢轴表:列数就是数据)。
> **那支只问「块里有没有带 `name` 的输入」的筛子,漏报率是 78%。**
>
> **活下来的四张全部转完,而它们正好是全仓库溢出最厉害的一批:**
> **390px 上合计 1,847px 的横向滚动【一张不剩地归零】。**
>
> ★ **而且这一次【桌面也变好了】**(139→15 · 122→0 · 31→0 · 51→0,合计少了 328px)——
> 与 TABLE-CONVERT-5 那次「桌面从 0 变成 292px」正好相反,原因见 §8.3。

---

## 1 · HEAD、树、与预期的差别

| | |
|---|---|
| 分支 | `main` |
| `git fetch origin` | 干净返回 |
| **开工 HEAD** | `f0b5d3318a08ad4a4b4faafc2c337aeb3954f037` |
| **开工 origin/main** | 同上 —— **逐字相等** |
| 开工 `git status --porcelain` | **零行(树干净)** |
| **与预期的差别** | 委托书说 HEAD 应是 `0d558c1` 或其后一个纯文档提交。实测:`f0b5d33` **正是那一个纯文档提交** —— `git diff --name-only 0d558c1 HEAD` 只有一个文件:`docs/handbacks/TABLE-CONVERT-5-round2.md`。☞ **正是它允许的那一种,PROCEED。** |
| 迁移 | **零个。** 零 SQL 改动。 |

---

## 2 · ★★ 任务一:十八张,一张一张读过 ★★

**读法:不是扫描。** 每一张都打开源码读:行是就地 `.map()` 画的还是交给子组件画的
(交给子组件就【进去读那个子组件】)· 格子里有没有受控输入 / select / 钮 / 确认框 ·
有没有 `tfoot` / 分组抬头 / 不是空态的 `colSpan` · 文件是不是 server component。

### 2.1 判决表

| # | 文件:行 | 上一刀记的 | **读完之后** | 证据 |
|--:|---|:-:|:-:|---|
| 1 | `components/audit/BatchAuditTrail.tsx:66` | C | **✅ C 可转** | server;行就地 `.map()`;零输入零钮;无 tfoot;`colSpan` 一个都没有 |
| 2 | `components/inventory/MovementTimeline.tsx:34` | C | **✅ C 可转** | server;行就地 `.map()`;零输入零钮;合计段在 `</table>` 之后(:81) |
| 3 | `components/metals/MetalContentPanel.tsx:123` | C | **✅ C 可转** | client;行就地 `.map()`;**格子里有一颗 `ConfirmButton`(删除)**——那是 R1 的动作列,不是 B 的输入;录入用的 `select`/`DecimalInput`/保存钮全在 `</table>`(:191)【之后】(:208–233) |
| 4 | `components/pricing/PriceBreakdown.tsx:105` | C | **✅ C 可转** | client;行就地 `.map()`;零输入零钮;表整个在 105–141,后面没有合计行 |
| 5 | `finance/cash-forecast/ForecastGrid.tsx:169` | C | **❌ F 枢轴** | **列是数据**:`{weeks.map((w) => <th …>)}`;行是四个固定指标。且它已穿 `tableC`,第一列 `sticky left-0` + `min-w-max` —— 源码自己写着「横向滚动是它【本来就在用】的答案」 |
| 6 | `finance/cost-variance/page.tsx:35` | C | **❌ F 枢轴** | **列是数据**:`{months.map((m) => <th …>)}`;行是成本类型 |
| 7 | `finance/fx/bulk/BulkFxGrid.tsx:88` | C | **❌ B** | **`<input>` 在表块里(:118),绑 `values` state,【不带 name】** |
| 8 | `finance/payables/page.tsx:173` | C | **❌ E** | 明细行之间夹着**每组小计行**(`<tr key={subtotal-…}>`,`colSpan={4}`)——不是空态 |
| 9 | `finance/pnl/page.tsx:160` | C | **❌ E** | `sectionBlock()` 画分节抬头行;另有毛利、净利两条合计行(`colSpan={2}`) |
| 10 | `finance/receivables/page.tsx:169` | C | **❌ E** | 与 ⑧ 同形,小计行 `colSpan={5}` |
| 11 | `hr/attendance/[id]/AttendanceGrid.tsx:48` | C | **❌ B** | **`<tbody>` 里只有一行 `<LineRow …/>`** —— 格子由子组件画,里面 4 个受控 `useState` + 逐行保存钮。**TABLE-CONVERT-4 §2.4 早已交回过它** |
| 12 | `hr/reviews/GoalsEditor.tsx:153` | C | **❌ B** | 表块 153–353 里有行内编辑:`textarea`(:246/279/335)· `input`(:262/296/308/320)· 保存/取消/编辑三颗 `Button` · `ConfirmButton` |
| 13 | `operation/orders/new/NewWorkOrderForm.tsx:95` | C | **❌ B** | 表块 95–124 里 `select`(:106)+ `input`(:116),绑 `lines` state,**不带 name** |
| 14 | `operation/orders/new/NewWorkOrderForm.tsx:134` | C | **❌ B** | 表块 134–185 里 `select`(:147/166)+ `input`(:157/176),绑 `expected` state,**不带 name** |
| 15 | `purchasing/orders/new/NewOrderForm.tsx:866` | C | **❌ B** | 表块里 `input` ×3 + `DecimalInput` ×2 |
| 16 | `purchasing/payment-terms/TemplateForm.tsx:167` | C | **❌ B** | 表块里 `input` ×3 + `DecimalInput` ×2 + `select` |
| 17 | `sales/quotes/[id]/QuoteLinesEditor.tsx:81` | C | **❌ B** | 表块 81–201 里受控 `input`(:159/166)绑 `qty`/`price` state,**不带 name**;另有保存钮与 `ConfirmButton` |
| 18 | `settings/roles/PermissionMatrix.tsx:120` | C | **❌ B** | 表块 120–175 里受控复选框(`checked`+`onChange={setModule}`),**不带 name** |

### 2.2 ☞ **真正能转的是【4 张】。十四张归错类,逐条点名如上。**

| 归到 | 张数 | 为什么上一刀的筛子看不见 |
|---|--:|---|
| **B(受控输入网格)** | **9** | 筛子只找 `<input … name=…>`。**这九张的输入一个 `name` 都没有** —— 它们靠 `value`/`onChange` 绑 React state。⑪ 更进一步:它的输入连表块都不在,住在 `LineRow` 里 |
| **E(小计 / 分节 / 合计行)** | **3** | 筛子只把 `tfoot` 当结构行。**⑧⑨⑩ 一个 `tfoot` 都没有** —— 它们把小计写成 `<tbody>` 里的普通 `<tr>` + `colSpan`,而筛子分不出「小计行的 colSpan」与「空态行的 colSpan」 |
| **F(枢轴)** | **2** | 筛子数不出「列数是数据」。⑤⑥ 的 `<th>` 是 `weeks.map` / `months.map` 出来的 |

> ### ★ 这就是委托书说的那件事:**扫描器回答「这段文字在不在这个范围里」,
> 而「这张表是不是只读的」是一个关于【行为】的问题。**
> **同一个盲区,连续三刀:** TABLE-CONVERT-2 量到过「行画在块外面:1 张」·
> TABLE-CONVERT-4 逮住 `AttendanceGrid` · TABLE-CONVERT-5 自己写下警告却仍报了 18。
> **本刀把它读完了,数字从 18 落到 4。**

---

## 3 · 四张的手机判断 —— **四张【都没有】既有判断,四个都是新做的**

四个文件 `hidden sm:table-cell` 实测**全为 0**,没有一张进过 TABLE-PHONE 家族的清单。

| 表 | priority(手机上留下) | 折进展开区 | 理由(一句) |
|---|---|---|---|
| `MovementTimeline:34` | **时间 · 类型 · 数量** | 桶 · 加工单 · 业务日 · 备注 | 身份是时间(行按 occurred_at DESC 排);结论是那个带符号的增减;而少了「类型」,一行就只剩"某时某刻 ±N kg"——**什么事**没了 |
| `BatchAuditTrail:66` | **时间 · 事件 · 明细** | 谁 · 出处 | ★ **「明细」是被源码自己的两条规矩留下来的**,不是我挑的 —— 见 §3.1 |
| `MetalContentPanel:123` | **金属 · 含量% · 动作** | 出处 · 更新时间 | 身份 + 结论 + **R1 强制**:动作列画的是一颗【硬删除】钮(走 `.delete()`,没有墓碑),够不着的动作等于不存在 |
| `PriceBreakdown:105` | **金属 · 金额(USD)** | 含量% · 计价% · 含金属量 · 计价量 · 单价 | 身份 + 结论;中间五列是【算给你看的过程】,**只有连起来读才有意义**(含量→含金属量→计价%→计价量→单价→金额),整组折比拆开留一两列诚实 |

### 3.1 ★ 一处【由源码的规矩决定、不是由我决定】的列选

`BatchAuditTrail.tsx` 抬头写着管每一行的三条规矩,**其中两条都住在「明细」那一格里**:
> ① **接缝画在行里**,而且【绝不省略那一行】—— 那几行 ⚠ 就在明细格内;
> ② **受限不是空** —— 「受限」连同它点名的模块码,也在明细格内。

☞ 把明细折进展开区,等于把这两条规矩要人**第一眼看见**的东西藏到一次点击之后。
**所以它留在明面上,哪怕它是最长的一列**(390px 上行高到 229px)。
★ 而 ② 还有第二层保险:**整行发灰原样搬过来了** ——
转换前是 `<tr className={r.may_view ? '' : 'bg-gray-50'}>`,现在走组件的 `rowClassName`
(CONV-4 建的那个 prop)。**「受限不是空」在 390px 上因此仍然一眼看得出来。**

### 3.2 ★ 一处【我自己拿的主意,与源码的一条注释有张力】

`MovementTimeline` 的「桶」我折了。而源码抬头写着 SO-2 的理由:
> 「成对流水的两条腿在此之前读起来完全一样 —— 暂扣与预留都是『状态变更(出/进)』」。

**桶正是为了拆开这种同形而加的列,而我把它折了。** 照直摆出来:
* 桶带着自己的列头躺在展开区里(§4 读回来的原话:`Bucket: Available` / `Bucket: Committed`),一点就到;
* 而在 390px 的 `table-fixed` 下,第四列要吃掉四分之一屏宽,代价落在
  【时间/类型/数量】三列的折行上 —— 那三列是每一行都要读的。
☞ **如果 Tim 认为桶必须与类型同屏,那是把它提成 `priority` 的事,一行改动。**

### 3.3 `mode: 'scroll'` —— **本刀一处都没用**

四张全部 `columns` 档。最像 scroll 场合的是 `PriceBreakdown`(七列一条算式),
**但它正是 390px 上溢出最狠的一张(+397px)** —— scroll 会把那 397px 原样留下。

---

## 4 · 展开区:六个实例逐颗点开,读回来的原话

量具对每张表的 `tbody button[aria-expanded]` **逐颗 `click()`**,再读回 `<dl>`。
**一共点开 75 颗,读回 75 个 `<dl>`。**

| 表 | 钮 | 读回来的原话(前一两行) |
|---|--:|---|
| `MetalContentPanel:123` | 1 | `Source: unknown` · `Updated: 8/1/2026, 12:00:13 AM` |
| `MovementTimeline`(inbound) | 10 | `Bucket: Available` · `Run: PROC-2026-0164` · `Business Date: 2026-08-10` · `Notes: —` |
| `MovementTimeline`(output) | 8 | **`Bucket: Committed`** · `Run: —` · `Business Date: 2026-08-14` · `Notes: shipped SHP-2026-0001` |
| `BatchAuditTrail`(inbound) | 33 | `Who: Tim` · `Source: inventory_movements` |
| `BatchAuditTrail`(output) | 16 | `Who: Tim` · `Source: PROC-2026-0106` |
| `PriceBreakdown:105` | 7 | `Content %: 10` · `Payable %: 70` · `Contained kg: 100` · `Payable kg: 70` · **`Price (USD/t): 15,000.00 2026-07-30 – 2026-07-30 single-day window`** |

☞ **每一个折走的列都带着自己的列头回来了。** 两处特别点名:
* `Bucket: Available` / `Bucket: Committed` —— §3.2 那条取舍的兑现:**桶没有丢,它一点就到。**
* `PriceBreakdown` 的单价格子把 **`single-day window`(取样窗口太薄的警告)** 一并带进了展开区 ——
  折的是列,不是那句话。
* ★ `Who:` 那一格读回来的是 **`Tim`**,不是一串 uuid ——
  `ActorName` 的四种答法一个字没改(§10-3)。

---

## 5 · 空态:一张一张说,而【旧那一支都拿掉了】

| 表 | 转换前 | 转换后 | 旧分支 |
|---|---|---|---|
| `MovementTimeline:34` | `rows.length === 0 ?` → `<p>` 里 `movements.empty` | 搬进 `empty` prop,**同一个 key** | **已删** |
| `BatchAuditTrail:66` | 同形,`auditTrail.empty` | 搬进 `empty`,**同一个 key** | **已删** |
| `MetalContentPanel:123` | **没有空态**:`{rows.length > 0 && (…)}`,空就整块不画 | **守卫原样留着**,没给 `empty` | 不适用 |
| `PriceBreakdown:105` | **没有空态**:`res.lines.map()` 直接画 | 没给 `empty` —— 见下 | 不适用 |

★ **`MetalContentPanel` 的守卫【故意留着】。** 委托书:今天画什么都不画的,不要发明一句。
把它去掉会让组件自带的 `table.empty` 新出现在屏幕上 —— 那是发明。**守卫留着,一个字没多。**

★ **`PriceBreakdown` 会多出一句,照直说。** 它转换前空的时候画一张只有表头的表;
现在组件在 `rows` 为空且没有 `empty` 时退到自带的 `t('table.empty')`。
**用的是组件既有的 key,不是我造的新词**(与 TC-3 的 `orders/[id]/page:162` 同一条)。
⚠ 实际够不够得到这条路存疑:`res.lines` 来自算价结果,而算不出价时页面根本不渲染这一块。

★ **两处「不是空态」的东西一个字没动**:`MovementTimeline` 的结余段
(`{rows.length > 0 && <p>…</p>}` —— 它守的是**合计**,不是空态)、
`BatchAuditTrail` 的具名脚注(六张够不到批次的历史表,本来就在条件之外)。

---

## 6 · 棘轮与手搓表数

| 维 | 之前 | 之后 | 差 |
|---|--:|--:|--:|
| 手搓 `<table>` | 43 | **39** | **−4** |
| **cellfont** | 330 | **313** | **−17** |
| 其中:标签上(`<table>/<th>/<td>`) | 37 | **20** | −17 |
| 其中:**列描述符里(`className: '…'`)** | 293 | **293** | **±0** |
| `datatable-phone` 调用点 | 156 | **160** | +4 |

★ **−4 就是这四张。**
★ **−17 与四个文件的钉字号【逐张相等】**:
  `BatchAuditTrail 2 + MovementTimeline 6 + MetalContentPanel 3 + PriceBreakdown 6 = 17`,
  **四个文件全部归零**(基线 diff 是 8 行【纯删除】,零行新增)。
★ **列描述符那一栏停在 293 —— 四张表的列定义里一个字号都没有。**

---

## 7 · 我渲染的是什么 · 什么状态 · 水合怎么证的

★ **三条真实路由,线上真数据,没有建任何 probe 路由,没有临时改任何清单。**

| 路由 | 喂出来的表 | 行数 |
|---|---|--:|
| `/inbound/662bfff7…/edit`(`IN-2026-0001`,draft) | MetalContentPanel · MovementTimeline · BatchAuditTrail | 1 / 10 / 33 |
| `/output/12dd44fb…/edit`(`OUT-2026-0118`,draft) | MovementTimeline · BatchAuditTrail(MetalContentPanel 线上 0 行,守卫不画) | 8 / 16 |
| `/tools/pricing/calculator` | **PriceBreakdown** —— ★ 要驱动才画得出,见 §7.1 | 7 |

★ **状态:一次性 admin(全权限)。** 这几页是编辑页,权限旗标真的会改表体
(`BatchAuditTrail` 的「受限」行、`MetalContentPanel` 的删除钮都要写权限)。

★ **除了展开钮与计价器那一次提交,我没点任何东西。**
`calculate_metal_price` 是 `require_permission` + 纯计算,**不写库**
(`db/migrations/2026-08-01-perm2b-field-masking.sql:1083` 读过),所以按那颗钮是安全的。

### 7.1 ★ 计价器【按下去没反应】,而根因量出来是两条,不是一条

`PriceBreakdown` 只有两条路能上屏:`AssayImpactPreview`(线上**零条未应用化验**,走不到)
与计价器。而计价器第一次驱动**按了等于没按**。写了一支专门的探针问清楚:

1. **`DecimalInput` 画【两个】`<input>`**:一个**可见、没有 `name`、带 `required`**,
   一个 **`hidden`、带 `name`**(源码抬头写着理由:number 输入框读不出 `"975."` 这种中间态)。
   我先只设了 hidden 那个 —— **React state 没动,可见那个仍是空的 `required`,
   浏览器当场拦下提交,而且【不报错、不出红框】。**
   ☞ 探针读回 `checkValidity: false` + `invalid: [{name:'INPUT', msg:'Please fill out this field.'}]` 才认出来。
2. 改设可见框之后 `checkValidity: true`,**仍然没有结果**。探针把提交后的红框文字带回来:
   > `No metal price on file for li, mn, al, fe as at 2026-07-02. Enter the price under Metal Prices — a quote that silently drops a metal is priced too low.`
   ☞ **不是缺陷,是一次具名拒绝**:七种金属我全填了,而其中四种那天没有牌价。
   查库后改用 **2026-08-10**(`price_basis=average` / `average_days=30`,回看窗口盖住
   七种金属都有牌价的 2026-07-30)—— **表画出来了。**

☞ **两条都是"按了没反应"**,而它们的区别只有量具问得出来。照直记下来。

### 7.2 水合:**功能性证明**

`<dl>` 只在 `isOpen` 为真时渲染,而 `isOpen` 来自组件里 `useState` 的 `open` 集合。
**一个没水合的页面上,展开钮画得出来但按下去什么都不会发生。**
§4 那 75 个 `<dl>` 是点完之后读回来的 —— **它们的存在本身就是水合的证明。**

计数那一层(数宿主元素上的 `__reactFiber$…`):

```
                  before(early→late)     after(early→late)
/inbound/…/edit       27→164                27→201      ← 早/晚差 174,水合过程本身被抓到
/output/…/edit       152→152               178→178
/tools/pricing/calculator  60→71             60→79
```

**六个读数没有一个是 0。** 导航全程走 `localhost`(TC-4 §7.1 / TM-1 §8 那条)。

---

## 8 · 行高与溢出:390px 与桌面,前后各一遍

### 8.1 ★ 390×844 —— **六个实例【全部归零】**

| 表 | **前:要横拖** | **后** | **差** | 行高 |
|---|--:|--:|--:|---|
| `MetalContentPanel:123` | +107px | **0** | **−107** | 77 → **41.5px** |
| `MovementTimeline`(inbound) | +389px | **0** | **−389** | 77 → **61.5px** |
| `MovementTimeline`(output) | +372px | **0** | **−372** | 97–117 → **61px** |
| `BatchAuditTrail`(inbound) | +281px | **0** | **−281** | 57–225 → 61.5–229 |
| `BatchAuditTrail`(output) | +301px | **0** | **−301** | 97–261 → 61–197 |
| `PriceBreakdown:105` | **+397px** | **0** | **−397** | 97 → **41px** |

> ### ☞ **合计拖没了 1,847px,六个实例的 `maxScroll` 全部读到 0。**
> **手机上推一把,一张都不动。** 行高五处变矮,最猛的是 `PriceBreakdown` 97→41px（掉了 58%)。
> ⚠ 一处基本持平、局部略高:`BatchAuditTrail`(inbound)最长那几行 225→229px ——
> 它是唯一一张**三列 priority**的表(§3.1 说明了为什么),而明细本来就是最长的一列。

### 8.2 为什么有的格子字变大了 —— **规矩要的,不是漏掉的**

四个文件转换前有 **17 处 `text-xs` / `text-sm` 钉在 `<table>/<th>/<td>` 上**,
**一处都没有搬进列定义** —— 搬了正是棘轮存在的理由(「不是还债,是把债换了个拼法」)。
☞ 那些格子回到组件表体的 **14px**,字大了行就高了(§8.3 桌面那一栏看得最清楚)。
**这是一处看得见的、已报的变化**,与 TC-4/TC-5 报过的同一条。

### 8.3 ★★ 1280×844 —— **这一次桌面【变好了】,与 TABLE-CONVERT-5 相反**

| 表 | 前溢出 | 后溢出 | 差 |
|---|--:|--:|--:|
| `MetalContentPanel:123` | 0 | **0** | 0 |
| `MovementTimeline`(inbound) | 139px | **15px** | **−124** |
| `MovementTimeline`(output) | 122px | **0** | **−122** |
| `BatchAuditTrail`(inbound) | 31px | **0** | **−31** |
| `BatchAuditTrail`(output) | 51px | **0** | **−51** |
| `PriceBreakdown:105` | 0 | **0** | 0 |

★ **这四张【转换前桌面上本来就在滚】** —— 那是本族第一次遇到这种表。
转换后合计少滚 **328px**,四处里三处归零。

**而它与 TC-5 那次「0 → 292px」的差别是可以指认的,不是运气:**
组件在 ≥sm 上给 `<th>` 加 `sm:whitespace-nowrap`(`data-table.tsx:456`),
**所以决定桌面宽度的是【列头能不能一行装下】。**
TC-5 那张七列表的列头是 `Output content from` 这种长句,七个加起来要 900px;
**本刀这四张的列头是 `Time` / `Type` / `Qty` / `Who` / `Source` 这种短词** ——
不折行也装得下,于是转换反而把此前靠"每格塞满"撑出来的宽度收了回来。

### 8.4 ★ 列宽:**登记第五例**(委托书 §4:见到就登记,不要调整)

> **`MovementTimeline`(inbound)在 1280px 上仍余 15px 溢出**(139 → 15,没有到 0)。
> 七列 + 展开钮那一格,在 `/inbound/[id]/edit` 的 `max-w-2xl`(608px)容器里差最后一点。
> **与 `/finance/balance-sheet`、供应商合规表、TM-1 §9 的 `Traceability:126`、
> TC-5 §8.4 的 `table-fixed` 等宽是同一个形状。登记为第五例。不动。**

### 8.5 整页溢出

**三条路由 × 两个视口 × 前后 = 12 个读数,`documentElement` 溢出【全部 0px】。**

---

## 9 · i18n key 用量:**两个方向都对上**

四个文件用到的**全部 67 个 key**,转换前后各在 `app/ lib/ scripts/` 全量数一遍:

```
合计用量  before = 204      after = 204      差 = 0
往上跳的 key:0 个      往下掉的 key:0 个      掉到 0 的 key:0 个
```

☞ **每一个 key 都是一比一搬家**:列头从组件搬进 client 文件,空态从三元的一支搬进 `empty` prop。
**「没有一个 key 往上跳」正是 TC-3 §6.1 那处死代码的反面证据。**

★ **TC-5 §9.1 那个坑本刀【没有踩】。** 上一刀因为在 JSDoc 里写了 key 名字,
让三个 key 从 2→3 假性上跳,然后改掉了注释而不是解释掉。
**本刀写注释时一开始就避开 key 字面量 —— 67 个 key 一次就是 0 差。**

---

## 10 · 我自己拿的主意

1. **`ActorName` 的那一格【传渲染好的节点,不传名字字符串】。**
   它是**异步服务端组件**,进不了客户端的 `render`。而 `ActorName.tsx` 抬头明写
   「谁做的只有一种答法 … 本刀不再造第二套词汇」——在客户端重算一遍名字正好是造第二套。
   所以服务端把 `<ActorName/>` 渲染好,作为 `whoNode` 随行传过去(RSC 支持把元素当 prop)。
   §4 读回来的 `Who: Tim` 证明它照常工作。
2. **两处「按行算的 className」搬进格子里那层 `<span>`**(`MovementTimeline` 的正绿负红、
   `PriceBreakdown` 无)—— 组件今天没有按行的格子 `className`(已登记的缺口,本刀不修)。
   **而整行的 `className` 有 prop**,所以 `BatchAuditTrail` 的发灰走 `rowClassName`,不是绕道。
3. **`MetalContentPanel` 的「出处」列是【条件列】**(`showSource` 为假时整列不画)——
   转换后用 `...(showSource ? [ … ] : [])` 拼列数组,与转换前逐格相同。
4. **棘轮基线顺手收紧**(`--update-baseline`)—— 基线抬头写着「少一处 → 顺手收紧」。
5. **建了一个 `git worktree` 去查 §12 那 10 张空表**,查完即删(`git worktree remove`),
   **仓库里没有留下任何痕迹**。

---

## 11 · Tim 该去哪儿走一遍,每一页要什么状态

| 走哪 | 要什么状态 | 看什么 |
|---|---|---|
| `/inbound/662bfff7…/edit` | 任意登录者;**有 `module.*.view` 才看得到轨迹里那几行**,否则它们照样占行、写「受限」 | 金属含量(留 金属·含量%·**删除钮**)· 库存流水(留 时间·类型·数量)· 审计轨迹(留 时间·事件·**明细**)。**390px 上推一把:一张都不该动。** |
| `/output/12dd44fb…/edit` | 同上 | 库存流水与审计轨迹的另一组数据(8 行 / 16 行)。**金属含量在这一页不画** —— 线上 0 行,守卫拦着(§5) |
| `/tools/pricing/calculator` | 需要 `data.view_prices` | ★ **要自己填表**:公式 `PF-2026-0001`、数量 1000、**参考日 2026-08-10**(别用 07-02,那天四种金属没牌价,会被具名拒绝 —— §7.1)、七个含量都填。按 Calculate 才出计价明细 |

---

## 12 · 我【没有】验证的东西

* ★★ **一处我【查不出来】的读数差,照直摆着:转换前 `/inbound/[id]/edit` 上有
  **10 张 0 列 0 行 0 宽的空 `<table>`**,转换后没有了。**
  已经确定的四件事:
  1. 它们**什么都没画**(0 列 / 0 行 / 宽 0 / 没有滚动外壳);
  2. **没有丢任何一张有内容的表** —— 前后都是同样 5 张,列头逐字相同;
  3. **不是这两个组件按行产生的**:`/output/[id]/edit` 跑同样的 `MovementTimeline`
     与 `BatchAuditTrail`、行数更多(8 / 16),**空表 0 张**;
  4. TABLE-MEASURE-1 两刀之前就量到过它们(§9 记作「10 张 0 宽的折叠表」)。
  ☞ **我建了一个指向转换前 HEAD 的 worktree 想抓它们,但那次探针整页读到 0 张表
  (页面在那个 worktree 里没渲染出来),所以【没有抓到】。**
  **我不知道它们是谁画的,也不知道为什么消失。照直登记,不编一个解释。**
* **`PriceBreakdown` 的另一条路(`AssayImpactPreview`)没渲染过** —— 线上零条未应用化验。
* **`PriceBreakdown` 空表那一句 `table.empty` 没见过** —— 走不到(§5)。
* **`MetalContentPanel` 在 output 侧没渲染过** —— 线上 0 行,守卫拦着。
* **权限为 false 的那些状态没量**:轨迹的「受限」行、`MetalContentPanel` 无编辑权时的样子。
* **只走英文档**;**只量首屏**;**硬导航,不是软导航**。
* **触控目标尺寸、可访问性、颜色对比**一律没量。
* **§3.2 折「桶」是不是对的,我证明不了** —— 给的是理由,不是读数。

---

## 13 · 剩下的人口 —— ★ **任务一把估算改小了多少** ★

**手搓 `<table>` 今天 39 张**(扫描 + 逐块分类):

| 类 | 张数 | 是什么 |
|---|--:|---|
| **B** | **16 + 9 = 25** | 受控输入网格。**其中 9 张是本刀新认出来的**(§2.1) |
| **E** | **3 + 3 = 6** | 带 `tfoot` 的 3 张 + 本刀认出的小计/分节 3 张 |
| **F** | **2** | 枢轴表(列数是数据)—— 本刀认出 |
| **H** | **6** | 无列头 —— Tim 已裁定走各自穿 tableC 那一刀 |
| **C(真正还能转的)** | **0** | ☞ **四张转完之后,可转的 C 类【清空了】** |

> ### ★★ **这才是任务一最要紧的产出:**
> **上一刀交出的估算是「还有 18 张可转,大概还要两三刀」。**
> **读完之后是【0 张】——转换这条线【到此为止】。**
> 剩下的 39 张没有一张是"再转一刀就好"的:
> * **25 张 B** 要先有草稿模型 —— 那是 **B-1 / B-2** 两刀的活(EditableTable 从 4 个调用点扩到 ~12 个),
>   **不是转换刀能顺手做的**(TC-4 §2.4 已经写清楚:组件把非 priority 列画两遍,
>   输入写进 `render` 会得到两份互相独立的 state);
> * **6 张 E** 要组件先长出 `tfoot` / 分组抬头 —— **那是一次能力缺口,不是工作量**;
> * **2 张 F** 要先回答 Q3(枢轴表怎么办),那个问题今天还开着;
> * **6 张 H** 已有裁定,走 tableC。
>
> ☞ **给下一刀:不要再排"转换"了。排 B-1(草稿模型)或 E(组件加 tfoot),二选一。**

**其余人口(本刀一个字没碰):** 穿着 `tableC` 的 22 处 ·
Tim 裁定过的 `PayrollGrid:202` / `ForwarderPanels:167` / `forwarders/page:203` ·
`OutputAssaySection:50` 带数据的读数仍然 UNMEASURED。

---

## 14 · 收工

* **含闸** `python3 db/gate.py` —— **退出码读的是脚本自己的 `$?`**,写进日志再读回来:

  ```
  GATE_OWN_EXIT=0
  GATE_WALL_SECONDS=312          ← 落在 180–700s 窗口内,不需要放宽
  ```

  **四条判词,逐字抄回来:**

  ```
  判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
  判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
  判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
     判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
  ```

  ☞ 本刀**一行 SQL 都没改**,跑含闸是照本族的规矩。

* **构建** `npm run build`:**`BUILD_OWN_EXIT=0`** · `✓ Compiled successfully in 8.4s`

  eslint 冻结那一行原文:

  ```
  ── eslint 冻结闸 ─────────────────────────────────────────────
  基线  error 42 · warning 88
  现在  error 42 · warning 88

  ✓ 没有新增的 eslint 问题。
  ```

  元检查那一行原文:

  ```
  ✓ check-instrument-selfproof:33 支量具都写了瞄准线;其中 22 支(构建链里的,含本支)都带着覆盖断言。
  ```

  cellfont 那两行原文:

  ```
     基线:94 个文件在册。本次扫到 313 处。
     分账:标签上 20 处(<table>/<th>/<td>) · 列描述符里 293 处(className: '…')。
  ```

* **没有 probe 路由、没有临时改过任何清单。** §10-5 那个 worktree **查完即删**
  (`git worktree remove`),`git worktree list` 里没有本刀留下的条目。
* **一次性账号:线上剩 0 个**(前后两次量测 + 两支探针各建各的,全部由
  `ephemeral.mjs` 的计划自删)。★ TC-5 §14.3 那条教训**这一刀带着走**:
  量具的 `finally` 里是 **`await runPlan()`** 再 `process.exit()`,不是不 await 就退。
  `.ephemeral/` 收工时是空的。

### 14.2 推送与部署 —— 两个问题**分开问**,并且**等到 SHA 对上才问第二个**

**推送窗口(两边都用 `date -u` 卡):**

| | |
|---|---|
| 推送前 | **2026-09-10T04:22:50Z** |
| 推送后 | **2026-09-10T04:22:53Z** |
| **工作提交** | **`8151341a99827504242d72745073b7aca1684872`** |

**推送是【取回来核】的,不是读 `git push` 的输出:**

```
git rev-parse HEAD                     8151341a99827504242d72745073b7aca1684872
git rev-parse origin/main              8151341a99827504242d72745073b7aca1684872   → MATCH ✓
git ls-remote origin refs/heads/main   8151341a99827504242d72745073b7aca1684872   → 远端自己也这么说 ✓
```

**问题一:最新那次部署是哪一次,它是给哪个 SHA 的?**(推送后 9 秒问的,04:23:02Z)

```json
{"id":6364102209,"sha":"f0b5d3318a08ad4a4b4faafc2c337aeb3954f037","created_at":"2026-09-10T03:43:56Z"}
```

**那是 `f0b5d33` —— TABLE-CONVERT-5 的那个纯文档提交,不是我的。**
**所以我没有去问它的状态**:那一刻的「成功」会是**上一刀部署的成功**,
把它记成本刀的成功,就是这一族反复交代过的那种假绿。

**于是等到 SHA 对上为止:**

| | |
|---|---|
| 推送完成 | **04:22:53Z** |
| 部署登记出现 | **04:25:34Z** |
| **登记滞后** | **161 秒**(TC-4 是 165s、TC-5 是 178s —— 同一个量级) |
| 部署 id | **6364542485** |
| **它的 SHA** | **`8151341a99827504242d72745073b7aca1684872`** ← **与 `origin/main` 逐字相同 ✓** |

☞ 先核 id 与 sha 的绑定(`deployments/6364542485` → `sha: 8151341…`),
免得「问了一个 id 的状态,而那个 id 是另一次部署的」。

**问题二(SHA 对上之后才问):这次部署是什么状态?**

```json
{"created_at":"2026-09-10T04:25:34Z","description":"Deployment has completed","state":"success"}
```

> ### ★ **`state=success`,而且是【本刀这个 SHA】的那一次。** ★

### 14.3 收工核对

| | |
|---|---|
| **开工前 HEAD** | `f0b5d3318a08ad4a4b4faafc2c337aeb3954f037` |
| **工作提交** | `8151341a99827504242d72745073b7aca1684872`(**工作 + 交回报告同一个提交**,委托书 §6 要求) |
| **本提交** | 纯文档 —— 只把 §14.2/§14.3 的推送与部署实测填上 |
| 树 | 收工时 `git status --porcelain` **空** |
| 迁移 | **没有**(零 SQL 改动) |
| probe 路由 / 临时改清单 | **一个都没有** |
| worktree | §10-5 那个查完即删;`git worktree list` 里没有本刀留下的条目 |
| 一次性账号 | **线上 0 个**(`.ephemeral/` 空)。★ 本刀的量具 `finally` 里是 **`await runPlan()`** 再 `process.exit()` —— TC-5 §14.3 那条教训带着走了,**没有再泄漏一个** |
| 新增/改动的用户可见字符串 | **没有新 key**;唯一可能新出现的是组件自带的 `table.empty`(§5,且实际够不够得到存疑),以及 §8.2 那 17 处从 12/14px 回到 14px 的格子 |

> ### ★ **一个提交写不进它自己的哈希。递归在这里停。**
> §14.2 那张表里的部署是**工作提交**那一次的;**本提交自己的哈希与它自己的部署不在本文里** ——
> 要它,`git log -1` 即可。
>
> ☞ **给下一刀:委托书里写的哈希会指向这两个里的某一个。**
> 照 §0 那条规矩办:**树干净 + `HEAD == origin/main` + 差别只是一个纯文档提交 → 继续。**
> **本刀开工时就是这么办的**(实测差别正是一个纯文档提交)。
>
> ★ **而下一刀不该是"转换刀"** —— 理由见 §13:可转的 C 类已经清零。
