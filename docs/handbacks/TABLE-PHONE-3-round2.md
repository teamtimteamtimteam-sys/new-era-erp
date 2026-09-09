# TABLE-PHONE-3 —— 成对的三组 + 其余,9 次判断 / 11 张表 / 11 个文件(交回报告)

2026-09-09。**没有 SQL,没有迁移,没有新的用户可见文案,`messages/` 一个字都没动
(`git diff messages/` = 0 行)。没有转换任何一页到 DataTable / EditableTable。
没有加 `table-fixed`。没有动桌面档的任何一列。NO VERSION NUMBER。**

> ★ **十二张里做了十一张。** 第十二张(`ContainerPanels:119`)**整张没有列头**,
> 折叠它要现造 4 条文案 —— 委托书 §4 明令不许。**没有做,登记在案**,详见 §2.3 与 §7。

---

## 1. HEAD 与树

| | |
|---|---|
| 开工前 HEAD | `0fef3678be67cc47401a4b662c9c1a91013e90c8` |
| 开工前 `origin/main` | `0fef3678be67cc47401a4b662c9c1a91013e90c8`(**相等**) |
| 开工前 `git status` | `On branch main` · `nothing to commit, working tree clean` |
| **本刀提交后 HEAD** | 见 §10(推送与部署实测) |

### ★ 委托书预期的 `ee29e96` 与实测差一个提交 —— 而委托书自己预言对了

```
0fef367  TABLE-PHONE-2 交回报告 §11:补齐推送与部署的实测记录 —— 部署 6345272633 success
ee29e96  TABLE-PHONE-2:钱、只读账簿五次判断、五张表、四个文件整个清干净
```

`git diff --stat ee29e96 HEAD` → **一个文件,而且是文档**
(`docs/handbacks/TABLE-PHONE-2-round2.md`,+95/−0)。树干净,两个哈希相等。
☞ **委托书 §0 说的三个放行条件全部成立,所以本刀【没有】停。**

★ **这是连着第四刀了。** 根子委托书自己写明了:交回报告的部署补记提交
发生在下一份委托书写完之后。**下一份委托书如果照"上一刀的工作提交"写预期 HEAD,还会差这一个。**

---

## 2. ★ 先确认人口 —— 委托书要求的那一步

### 2.1 批次表说什么(`docs/forward-queue.md`,改前)

委托书 §2.2 说"最后一批,除掉录入表"。批次表里最后一批是 **TABLE-PHONE-5**(其余六张);
**TABLE-PHONE-4 才是录入表那一批**,不在本刀口子里。于是本刀的工作单 =
**TABLE-PHONE-3(成对的 6 张)+ TABLE-PHONE-5(其余 6 张)= 12 张 / 9 次判断**,
与委托书标题的"十二张表、九次判断"**对得上**。

### 2.2 逐个开文件量到的 —— **行号、列数、有没有动过**

| # | 位置 | 批次表说 | 实测列数 | 滚动外壳 / 已动过 |
|---|---|---|---|---|
| 1 | `hr/attendance/[id]/AttendanceGrid.tsx:48` | 6 张组之一 | **7** | 无 `overflow-x` · 无 `sm:hidden` |
| 2 | `me/MyAttendancePanel.tsx:28` | 同上 | **6** | 同上 |
| 3 | `hr/reviews/GoalsEditor.tsx:153` | 同上(**条件列**) | **7 或 8**,见 §2.4 | 同上 |
| 4 | `me/MyReviewsPanel.tsx:82` | 同上 | **5** | 同上 |
| 5 | `purchasing/orders/new/NewOrderForm.tsx:858` | 同上 | **6** | 同上 |
| 6 | `purchasing/payment-terms/TemplateForm.tsx:151` | 同上 | **5** | 同上 |
| 7 | `sales/customers/ChasePanel.tsx:239` | 其余 | **7** | 同上 |
| 8 | `sales/customers/ContactsPanel.tsx:88` | 其余 | **6** | 同上 |
| 9 | `suppliers/[id]/edit/CompliancePanel.tsx:85` | 其余 | **5** | 同上 |
| 10 | `logistics/containers/[id]/ContainerPanels.tsx:119` | 其余 | **5** | 同上,**但没有列头** —— §2.3 |
| 11 | `me/MyExpenseClaimsPanel.tsx:108` | 其余 | **6** | 同上 |
| 12 | `me/MyLeavePanel.tsx:117` | 其余(同文件第二张) | **5** | 同文件第一张是 TABLE-PHONE-1 做的 |

**十二处一个不差,全部还是没外壳、没动过的**(第 12 处所在文件的**另一张**动过,这一张没有)。
**批次表与本刀实测没有分歧**,不存在 TABLE-PHONE-2 撞到的那种"委托书指一处、批次表指另一处"。

### 2.3 ★★ 第 10 张没有做 —— `ContainerPanels:119` **整张没有列头** ★★

那张表(装着的发货单)**从头到尾没有 `<thead>`,一个 `<th>` 都没有**。5 列全部裸奔:

```
发货单号(Link) | 订单号 | 客户 | 发货日 | 拆离钮
```

☞ 折叠**任何一列**都要给它现造一句话。查过两处,都没有可复用的 key:
* 这几列**自己没有 key**(桌面上根本没印过字);
* 这个组件的文案走 `labels: Record<string,string>` 这个 props,而
  `app/logistics/containers/[id]/page.tsx:134-164` 那**一整个 `labels` 字面量**里
  **没有任何一条对得上这四列**(逐条比过)。

☞ 委托书 §4:**列头写死、没有 key,就说出来并停,不要现造。**
**没有列头比写死更彻底**,所以本刀**一个字没改**。
★ 它与 `/finance/close` 那个空列头**不是同一类** —— 那一类只有**一列**是空的、
装的还是**自己带字的控件**;这里是**四列数据**没有主语。
借用别处的 key(比如 `sales` 那边的"客户")**也是现造**,只是绕了个弯,而且会印错词。

☞ 处置:**登记进 `docs/known-issues.md` 与队列(新的 TABLE-PHONE-6,判断数 0 / 待裁定)。
要做它就要先批 4 个 i18n key。** 其余十一张不受影响,所以本刀把它们做完了,
而不是为一张停掉十一张。

### 2.4 ★ 哪一半是录入版 —— **读出来的,不是照名字猜的**

| 组 | 录入版(有输入框) | 只读版 | 判据 |
|---|---|---|---|
| 考勤 | **`AttendanceGrid`**(7 列) | `MyAttendancePanel`(6 列) | 前者 `open` 时三个数 + 备注都是 `<input>`;后者文件抬头自己写着"【只读】",全是纯文本 |
| 绩效 | **`GoalsEditor`**(7/8 列) | `MyReviewsPanel`(5 列) | 前者行内改:`textarea`/`input` + 保存/取消;后者纯 `<span>` |
| 分期 | **两半都是** | **没有只读版** | 见下 |

★★ **第三组不是"一版填、一版读"** ★★
委托书 §2.1 把三组都写成"一版管理员填、一版本人读自己"。**第三组读出来不是这样:**
`TemplateForm` **整张表都是输入框**(名目 `input` · 比例 radio + `DecimalInput` ·
触发 `select` · 移除钮),它**不是**"本人读自己"的那一半。
两者真正的区别是:**付款条款模板(可复用的定义,没有钱)** vs.
**落到一张真实采购订单上的分期(算得出金额)**。

☞ **这不影响裁定怎么落**:R-Q4 说录入版留四列,于是**两半都留四列**,
而且**留的是同一组**(序号 + 名目 + 比例/定额 + 触发)。
**"两次判断、一次讨论"这件事在这一组反而更实了** —— 两张表最后选出来的列完全相同。

### 2.5 ★ `GoalsEditor` 的真实列数 —— **两种条件各量了一次**

```js
const editable = canEditGoals || canAssess || canSetActual
```

| 条件 | 桌面档列数 | 第 8 列是什么 |
|---|---|---|
| `editable === true` | **8** | 一个**空列头**的动作列(`<th className="… w-28"></th>`),装编辑 / 删除 / 保存 / 取消 |
| `editable === false` | **7** | 动作列**整个不画**(`{editable && <th…>}`) |

☞ **本刀是按 8 列那一支选的列**(它是超集,手机档的排布必须在两支下都成立),
并对 7 列那一支**单独复量过一次**:`7 = 4 + 3`,见 §5 最后一行。

---

## 3. 每一张表:选了什么,为什么 —— **一行一个理由**

**通例:身份 + 那个要紧的数 + 一个状态;没有状态列的,第三格给第二个要紧的数
(TABLE-PHONE-2 工资条留了应发和实发的那条先例)。录入版按 R-Q4 留四列。**

### 3.1 三组成对的(6 张 / 3 次判断)

| # | 表 | 桌面档 | 手机档留下 | 叠进身份格 | **理由(一行)** |
|---|---|---|---|---|---|
| 1a | `AttendanceGrid`(**录入**) | 7 | 员工 · 平日加班 · 休息日加班 · 记了没有 | 公共假期加班 · 备注 · 无薪假天数 | **两格给最常填的两个输入框**;"记了没有"这一列既是状态、又装着保存钮,动不得(文件抬头自己写着这张表最重要的一列是"记了没有") |
| 1b | `MyAttendancePanel`(只读) | 6 | 底稿 · 平日加班 · 记了没有 | 休息日加班 · 公共假期加班 · 无薪假天数 | 本人来看"公司替我报了什么",**最常非零的那个数 + 报没报**就够,其余三个数各带列头叠下去 |
| 2a | `GoalsEditor`(**录入**) | 7/8 | # · 目标 · 指标 · 实际 | 单位 · 本人结果 · 评估人评语 ·(动作) | **指标与实际必须并排**,少一个另一个判断不了;评语是长文本,叠下去反而比挤成一列宽 |
| 2b | `MyReviewsPanel`(只读) | 5 | 目标 · 指标 · 实际 | 本人结果 · 评估人评语 | 同一条道理的只读版:**这张表没有状态列,第三格就给第二个要紧的数** |
| 3a | `NewOrderForm:858`(**录入**) | 6 | 序号 · 期次名称 · 比例/定额 · 触发事件 | 金额 ·(移除钮) | 一条付款分期就是"叫什么、多少、什么时候"三问;**金额是算出来的只读数,读一眼不花点按次数**,所以让它下来 |
| 3b | `TemplateForm`(**也是录入**) | 5 | 序号 · 期次名称 · 比例/定额 · 触发事件 | (移除钮) | **与 3a 选的是同一组** —— 两张一起判的;模板没有金额可算,所以只少那一条 |

### 3.2 其余(5 张做完 / 1 张登记未做)

| # | 表 | 桌面档 | 手机档留下 | 叠进身份格 | **理由(一行)** |
|---|---|---|---|---|---|
| 4 | `ChasePanel` | 7 | 编号 · 催收当时欠 · 承诺 | 日期 · 方式 · 联系到 · 对方说了什么 | **催收这件事的结果就在"承诺"那一列**:欠多少、对方许了什么,是这张表回答的问题 |
| 5 | `ContactsPanel` | 6 | 姓名 · 电话 · 主联系人 | 职能 · 邮箱 ·(编辑/移出) | 这张表**没有数**,留的是**手机上打得通的那一条**;邮箱叠下来反而占得开(它在桌面档就带着 `break-all`) |
| 6 | `CompliancePanel` | 5 | 证书类型 · 证书编号 · 有效期 | 签发机构 ·(删除) | 这张表也没有数,问题是"**哪一张证、还作不作数**";光有类型分不清换发前后那两张,过期是红在有效期这一列上的 |
| 7 | **`ContainerPanels:119`** | 5 | **未做** | — | **整张没有列头,折叠要现造文案 —— §2.3** |
| 8 | `MyExpenseClaimsPanel` | 6 | 编号 · 金额 · 状态 | 花钱日 · 花在什么上 ·(撤回钮) | 报销就三问:**哪一单、报了多少、批没批** |
| 9 | `MyLeavePanel:117` | 5 | 编号 · 天数 · 状态 | 假别 · 日期 | 天数就是**上面那张余额表被扣掉的东西**,批没批是它的状态;这一张做完,**这个文件整个清干净** |

### 3.3 合计行 / 小计行 —— **本批一处都没有**

十一张表**都没有 `<tfoot>`、也没有任何 `colSpan`**(量过:`grep -c colSpan` 十一个文件全 0)。
**每一张的空状态都写在 `<table>` 外面**(`rows.length === 0 ? <p> : <table>`),
所以委托书 §2B 那条"`colSpan` 写两份"**在本批一次都没有用上**,
§3 那条"合计行的数字也要叠"**在本批没有对象**。

---

## 4. 三组各自的两次判断 —— **录入版为什么多留一列**

| 组 | 只读版留 3 列 | 录入版留 4 列 | **多出来的那一列是什么、为什么** |
|---|---|---|---|
| 考勤 | 底稿 · 平日加班 · 记了没有 | 员工 · 平日加班 · **休息日加班** · 记了没有 | 多的是**第二个最常填的输入框**。R-Q4 的理由是"把输入框收进折叠区等于填一格要点两下",所以这一格给**输入框**,不给只读的无薪假天数(它在录入版里本来就是只读的,占这一格是浪费) |
| 绩效 | 目标 · 指标 · 实际 | **#** · 目标 · 指标 · 实际 | 多的是序号。★ 见下面那条:它是**被 §4 的规矩逼出来的**,不是随手留的 |
| 分期 | (没有只读版) | 序号 · 名目 · 比例/定额 · 触发 | 两半都是录入版,**都留四列,而且是同一组** |

★ **绩效那一组多留的是 `#`,理由要说清楚:**
`GoalsEditor` 的第一列列头是**写死的字面量 `#`**,没有 i18n key。
把它折叠下去就得给它一个标签,而那正是委托书 §4 禁止的"现造"。
**留在列上就一个标签都不需要** —— 而且它是本批最窄的一列(`w-8`,390px 上约 24px),
代价几乎为零,又正好是人嘴上指认一条目标的那个号("第 3 条")。
☞ **这个写死的列头本身,登记了、没有动。**

★ **动作列去哪了:** 三处(`GoalsEditor` / `ContactsPanel` / 两张分期表 / `MyExpenseClaimsPanel`)
的动作列在**桌面档本来就没有列头**,照 TABLE-PHONE-2 那个重开钮的先例处置:
**控件叠进身份格里原样画出来,自己带着字,不另造一句话。**
`CompliancePanel` 的动作列**有 key**(`suppliers.compliance.colActions` = Actions / 操作),
所以它叠下去时**带着自己那条 key**。

---

## 5. 「一个字段都没丢」—— **量出来的,而且看着它红过两次**

量具:`…/scratchpad/tp3/nofieldlost.mjs`,**不在仓库里**(R-Q8)。
**判据:每张表 `手机档画出来的列数 + 叠进身份格的条目数 == 桌面档列数`。**

**方法**(与前两刀同源,并把 TABLE-PHONE-2 加的两条都带上了):

1. **先剥注释,再匹配**(`{/* */}` 与整行 `//`)—— TABLE-PHONE-2 就是在这里绿错过一次。
2. 按**标签深度**取第 n 个 `<table>…</table>`,不靠缩进(`NewOrderForm`、`MyLeavePanel` 各有两张)。
3. 叠加条目数 = 明细行里第一个 `sm:hidden` 折叠块的**直接子 `div`**,按标签深度数。
   **数的是条目,不是标签。**
4. **叠加块里没有标签的条目直接判红**,白名单逐表写死条数并写明理由
   (全部是"桌面档本来就没有列头"的控件)。
5. **第一行是校准** —— 拿没动过的 `/finance/payables` 先量。

### 5.1 结果 —— **第一行是校准,最后一行是条件列复量**

```
✓ REFERENCE (FIX-2b, 没动过)    desktop= 8  phone cols=3 + stacked=5 = 8
✓ §2.1a 考勤录入 AttendanceGrid   desktop= 7  phone cols=4 + stacked=3 = 7   [行是子组件,叠加块在文件作用域找]
✓ §2.1b 考勤自助 MyAttendance     desktop= 6  phone cols=3 + stacked=3 = 6
✓ §2.2a 绩效录入 GoalsEditor      desktop= 8  phone cols=4 + stacked=4 = 8   [1 条无标签,准许 1]
✓ §2.2b 绩效自助 MyReviewsPanel   desktop= 5  phone cols=3 + stacked=2 = 5
✓ §2.3a 分期(订单)NewOrderForm  desktop= 6  phone cols=4 + stacked=2 = 6   [1 条无标签,准许 1]
✓ §2.3b 分期(模板)TemplateForm  desktop= 5  phone cols=4 + stacked=1 = 5   [1 条无标签,准许 1]
✓ §2.4  催收 ChasePanel           desktop= 7  phone cols=3 + stacked=4 = 7
✓ §2.5  联系人 ContactsPanel      desktop= 6  phone cols=3 + stacked=3 = 6   [1 条无标签,准许 1]
✓ §2.6  合规 CompliancePanel      desktop= 5  phone cols=3 + stacked=2 = 5
✓ §2.7  报销 MyExpenseClaims      desktop= 6  phone cols=3 + stacked=3 = 6   [1 条无标签,准许 1]
✓ §2.8  假期申请 MyLeavePanel     desktop= 5  phone cols=3 + stacked=2 = 5
✓ §2.2a 同表 editable=false     desktop= 7  phone cols=4 + stacked=3 = 7   [动作列整个不画,0 条无标签]

✓ 11 张表(外加 1 张校准、1 次条件列复量):手机档读得到的字段数 == 桌面档,一列都没有丢。
VERIFY_OWN_EXIT=0
```

★ **第一行是没有动过的 `/finance/payables`**,它报 `8 = 3 + 5`,与 FIX-2b 当初做的一致。
**校准不过,后面那些行不值一看** —— 而这一次校准行**真的先红了**,见 §5.2。

### 5.2 ★★ 量具自己错了两处,**都是校准行和条件行咬出来的** ★★

**错法一:标签正则不认带参数的 `t()`。**
`payables` 那条列头是 `t('finance.colAmount', { ccy: baseCurrency })` —— **带参数**。
第一版正则要求 `t()` 紧接着闭合,于是把一条**有标签**的条目报成"无标签",校准行红:

```
✗ REFERENCE (FIX-2b, 没动过)    desktop= 8  phone cols=3 + stacked=5 = 8
     stacked items: finance.colCounterparty | finance.colDate | finance.agingAsOf.colDueDate | (无标签) | finance.colSettled
     ↑ 1 条叠加值没有列头(只准许 0 条)—— 数字失去了主语
```
(第二版改成 `[^}]*` 仍然不够 —— 参数里还套着一层 `{}`;第三版用有界惰性匹配才对。)

**错法二:`AttendanceGrid` 的行是一个独立子组件(`<LineRow/>`),叠加块【不在 `<table>` 里】。**
第一版报 `stacked=0`,于是 `4 + 0 != 7` 红。
☞ 改法是**显式声明作用域并把它印在结果行里**(`[行是子组件,叠加块在文件作用域找]`),
**不做静默兜底** —— 否则"找不到叠加块"会被读成"没有叠加块",而 **0 条正好会静静通过**,
那就是 TABLE-PHONE-2 那条教训换了个形状。

☞ **两处都是量具的错,不是代码的错**,而**两处都是"先拿一张已知合格的表校准"抓到的**。

### 5.3 ★ 它证明过自己会红 —— **两次,两种红法**

**红法一:整条删掉一个叠加条目**(从 `ChasePanel` 折叠块里删掉「方式」那一条)

```
✗ §2.4  催收 ChasePanel           desktop= 7  phone cols=3 + stacked=3 = 6
     stacked items: chases.colDate | chases.colWho | chases.colSummary
     ↑ 数对不上:3 + 3 != 7 —— 有字段在手机上丢了
✗ 1 张表对不上 —— 有字段在手机上丢了。
VERIFY_OWN_EXIT=1
```
**还原后 `VERIFY_OWN_EXIT=0`。**

**红法二:只拿掉标签,值留着**(`MyLeavePanel` 折叠块里删掉「假别」那个 `<span>`)

```
✗ §2.8  假期申请 MyLeavePanel     desktop= 5  phone cols=3 + stacked=2 = 5
     stacked items: (无标签) | leave.dates
     ↑ 1 条叠加值没有列头(只准许 0 条)—— 数字失去了主语
✗ 1 张表对不上 —— 有字段在手机上丢了。
VERIFY_OWN_EXIT=1
```
★ **这一种最值得看:等式 `5 = 3 + 2` 照样成立**,数字一个不少 ——
**红的是那条标签断言**。没有它,一个失去主语的值会静静通过。
**还原后 `VERIFY_OWN_EXIT=0`。**

**两次都点了名、列出了活着的标签(于是缺的那条认得出来),还原后退回 0;
`git status --porcelain` 只剩本刀该动的那些文件,没有残留。**

---

## 6. 每一条用户可见的字 —— **一个新字都没有**

**`git diff messages/` 是空的(0 行)。** 叠进身份格的每一条标签,
用的都是**那一列自己原来的列头 key**。

★ **下面这两列是拿量具读 `messages/*.ts` 读出来的,不是手抄的** ——
而**第一版读错过**:`messages/en.ts:4714` 把好几对 `key: value` 写在**同一行**上,
行解析器只认到第一对,于是把 **8 个存在的键报成"缺"**。
改成**真的把模块求值**(剥掉 `import type` / `as const` / `satisfies Messages` 再交给 node)之后
`MISSING=0`。**这是 TABLE-PHONE-2 那条教训的同一个形状:量具在错的数上说话。**


#### §2.1a 考勤录入 AttendanceGrid(叠进「员工」格)
| key | EN | ZH |
|---|---|---|
| `attendance.colOtHoliday` | OT public holiday | 公共假期加班 |
| `attendance.colNote` | Note | 备注 |
| `attendance.colUnpaidDays` | Unpaid days | 无薪假天数 |

#### └ 留在列上
| key | EN | ZH |
|---|---|---|
| `attendance.colEmployee` | Employee | 员工 |
| `attendance.colOtNormal` | OT normal | 平日加班 |
| `attendance.colOtRestDay` | OT rest day | 休息日加班 |
| `attendance.colRecorded` | Recorded | 记了没有 |

#### §2.1b 考勤自助 MyAttendancePanel(叠进「期间」格)
| key | EN | ZH |
|---|---|---|
| `attendance.colOtRestDay` | OT rest day | 休息日加班 |
| `attendance.colOtHoliday` | OT public holiday | 公共假期加班 |
| `attendance.colUnpaidDays` | Unpaid days | 无薪假天数 |

#### └ 留在列上 
| key | EN | ZH |
|---|---|---|
| `attendance.colCode` | Sheet | 底稿 |
| `attendance.colOtNormal` | OT normal | 平日加班 |
| `attendance.colRecorded` | Recorded | 记了没有 |

#### §2.2a 绩效录入 GoalsEditor(叠进「目标」格)
| key | EN | ZH |
|---|---|---|
| `reviews.colUnit` | Unit | 单位 |
| `reviews.colEmployeeResult` | Employee result | 本人结果 |
| `reviews.colAssessment` | Reviewer assessment | 评估人评语 |

#### └ 留在列上  
| key | EN | ZH |
|---|---|---|
| `reviews.colObjective` | Objective | 目标 |
| `reviews.colTarget` | Target | 指标 |
| `reviews.colActual` | Actual | 实际 |

#### └ 叠加块里那个动作(钮面自带字)
| key | EN | ZH |
|---|---|---|
| `common.save` | Save | 保存 |
| `common.cancel` | Cancel | 取消 |
| `reviews.edit` | Edit | 编辑 |
| `common.delete` | Delete | 删除 |

#### §2.2b 绩效自助 MyReviewsPanel(叠进「目标」格)
| key | EN | ZH |
|---|---|---|
| `reviews.colEmployeeResult` | Employee result | 本人结果 |
| `reviews.colAssessment` | Reviewer assessment | 评估人评语 |

#### §2.3a 分期(订单)NewOrderForm(叠进「序号」格)
| key | EN | ZH |
|---|---|---|
| `purchasing.colAmount` | Amount | 金额 |

#### └ 留在列上   
| key | EN | ZH |
|---|---|---|
| `purchasing.colSeq` | # | # |
| `purchasing.colLabel` | Label | 期次名称 |
| `purchasing.colShare` | Share | 比例/定额 |
| `purchasing.colTrigger` | Trigger | 触发事件 |

#### └ 两张分期表的删除钮(钮面自带字)
| key | EN | ZH |
|---|---|---|
| `purchasing.form.removeLine` | Remove | 移除 |

#### §2.4 催收 ChasePanel(叠进「单号」格)
| key | EN | ZH |
|---|---|---|
| `chases.colDate` | Date | 日期 |
| `chases.colChannel` | How | 方式 |
| `chases.colWho` | Reached | 联系到 |
| `chases.colSummary` | What was said | 对方说了什么 |

#### └ 留在列上    
| key | EN | ZH |
|---|---|---|
| `chases.colCode` | Ref | 编号 |
| `chases.owedAtChase` | Owed at time of chase | 催收当时欠 |
| `chases.colPromise` | Promised | 承诺 |

#### §2.5 联系人 ContactsPanel(叠进「姓名」格)
| key | EN | ZH |
|---|---|---|
| `contacts.colRole` | Role | 职能 |
| `contacts.colEmail` | Email | 邮箱 |

#### └ 留在列上     
| key | EN | ZH |
|---|---|---|
| `contacts.colName` | Name | 姓名 |
| `contacts.colPhone` | Phone | 电话 |
| `contacts.colPrimary` | Primary | 主联系人 |

#### └ 动作(钮面自带字)
| key | EN | ZH |
|---|---|---|
| `common.edit` | Edit | 编辑 |
| `contacts.remove` | Remove | 移出名单 |

#### §2.6 合规 CompliancePanel(叠进「种类」格)
| key | EN | ZH |
|---|---|---|
| `suppliers.compliance.colIssuer` | Issuing Body | 签发机构 |
| `suppliers.compliance.colActions` | Actions | 操作 |

#### └ 留在列上      
| key | EN | ZH |
|---|---|---|
| `suppliers.compliance.colType` | Certificate Type | 证书类型 |
| `suppliers.compliance.colNo` | Certificate No. | 证书编号 |
| `suppliers.compliance.colValidity` | Validity | 有效期 |

#### §2.7 报销 MyExpenseClaimsPanel(叠进「单号」格)
| key | EN | ZH |
|---|---|---|
| `expenseClaims.colSpent` | Spent | 花钱日 |
| `expenseClaims.colDescription` | What for | 花在什么上 |

#### └ 留在列上       
| key | EN | ZH |
|---|---|---|
| `expenseClaims.colRef` | Ref | 编号 |
| `expenseClaims.colAmount` | Amount | 金额 |
| `expenseClaims.colStatus` | Status | 状态 |

#### └ 撤回(钮面自带字)
| key | EN | ZH |
|---|---|---|
| `expenseClaims.withdraw` | Withdraw | 撤回 |

#### §2.8 假期申请 MyLeavePanel(叠进「单号」格)
| key | EN | ZH |
|---|---|---|
| `leave.type` | Type | 假别 |
| `leave.dates` | Dates | 日期 |

#### └ 留在列上        
| key | EN | ZH |
|---|---|---|
| `leave.code` | Ref | 编号 |
| `leave.days` | Days | 天数 |
| `leave.status` | Status | 状态 |


☞ **确认:没有新增 key,没有改动 key,没有删除 key。**(量具报 `MISSING=0`;
构建链里的 `check-i18n` 照跑通过,它是这句话的第二个证人。)

---

## 7. 队列与记录

### 7.1 `docs/forward-queue.md`

* 标题 `剩 26 张表 / 24 个文件` → **`剩 10 张表 / 10 个文件`**。
* 新增「**已上线 —— TABLE-PHONE-3**」一段,与 TABLE-PHONE-1 / 2 同一个体例。
* 原来的三批表(6 + 9 + 6 = 21)→ **两批表(9 + 1 = 10)**:
  * **TABLE-PHONE-4** 原样留着(9 张 / 9 次判断);
  * **TABLE-PHONE-6(新)= `ContainerPanels:119`,1 张 / 判断数 0(待裁定)** ——
    它从原 TABLE-PHONE-5 里**拆出来单列一批**,因为**它缺的是一个裁定,不是工时**。
  * 原 TABLE-PHONE-5 的另外五张**已做完,划掉**。

**账对得上:** `21 − 11 = 10`,而 `10 = 9 + 1`。写进队列里了,免得下一个人自己去减。

### 7.2 ★ `NewOrderForm` 没有做完 —— **说在前头**

`app/purchasing/orders/new/NewOrderForm.tsx` **有两张表,分属两批**:

| 表 | 批 | 状态 |
|---|---|---|
| `:858` 付款分期 | TABLE-PHONE-3(本刀) | **已做** |
| `:786` 行编辑 | TABLE-PHONE-4 | **未做** |

☞ **所以这个文件今天是半张脸,这是排期使然,不是漏了。**
队列里写明了,并且**剩下的 10 张表落在 10 个文件上**
(`NewOrderForm` 只按 TABLE-PHONE-4 那一张算,不重复计)。
★ 这与 TABLE-PHONE-2「4 个文件整个清干净」的情况**不同**,不要拿那一刀的话套本刀。
**本刀确实清干净的是 `me/MyLeavePanel.tsx`** —— 它的第一张表是 TABLE-PHONE-1 做的,
第二张是本刀做的,到此这个文件没有表再被后面的批次点到。

### 7.3 `docs/known-issues.md`

`RAW-TABLE-PHONE-SWEEP` 加了「**三批之后 —— TABLE-PHONE-3**」一节,记下:
第三组两半都是录入版、`GoalsEditor` 的条件列两支各量一次、
**`ContainerPanels:119` 为什么没做**、以及量具这一次被校准行咬出来的那两处自己的错。
标题里的批次说明改成「TABLE-PHONE-0 普查 + TABLE-PHONE-1/2/3 三批」。

---

## 8. 本刀自己定的、属于细节而不是形状的事

1. **把在两个断点各画一次的控件提成了一个局部常量**
   (`actionControls` / `removeControl` / `removeTermControl` / `rowControls` /
   `deleteControl` / `withdrawControl`)。
   理由:同一组钮要在桌面档那一列和手机档折叠块里各画一次,**照抄两份迟早走散**。
   ☞ **动作、权限闸、禁用条件、确认框一个字没改** —— 都是同一个函数体搬了个家。
   `withdrawControl` 连它自己那句 `r.status === 'submitted'` 一起搬,
   所以**两个断点服从同一条规矩**。
2. **`TemplateForm` 的折叠块补了一层 `<div>`**,让它与其余十张**同一个形状**
   (容器 div + 每条一个子 div)。原来它是 `<div className="sm:hidden">{钮}</div>`,
   量具按"直接子 div"数会数出 0 条。**改标记让形状统一,比给量具加一条特例好。**
3. **叠加块的间距**:含输入框的用 `space-y-1`,纯文本的用 `space-y-0.5`
   (照 `/finance/payables` 的既有写法)。
4. **`ContactsPanel` 邮箱那一条叠下去时保留了 `break-all`** —— 它在桌面档就带着,
   长邮箱在窄格子里不断行会顶宽整格。
5. **`ChasePanel` 的"对方说了什么"叠下去时,把它那条附属的单据列表一起带上了** ——
   它在桌面档就是同一格里的第二行,不是另一列。

---

## 9. Tim 该在哪里走,以及**怎么看到手机档**

### ★ 怎么看:**设备模拟 390px,不是把窗口拖窄**

Chrome DevTools → **Toggle device toolbar(⌘⇧M)** → 选 **iPhone 12 Pro(390 × 844)**。
**断点是 640px(`sm:`),把桌面窗口拖到 390px 宽【也会】切换** ——
但字号、点按目标、滚动条占位都不是手机的,**看不出"够不够按"**。委托书 §1D 就是这个意思。

### 路线与角色

| # | 路线 | 角色 / 权限 | 看什么 |
|---|---|---|---|
| 1 | `/finance/payables` | 财务 | **先看这一张** —— 它是没动过的参照,手机档长什么样心里有个底 |
| 2 | `/me` | 任何员工账号 | **一页看三张**:考勤自助(§1b)· 报销(§2.7)· 假期申请(§2.8,页面下半)· 另有 TABLE-PHONE-1 做的年假余额与工资条 |
| 3 | `/hr/attendance/<期间 id>` | `module.hr.edit` | 考勤录入(§1a)。期间**开着**时是输入框,**关了**是纯文本 —— 两种都值得看一眼 |
| 4 | `/hr/reviews/<考核 id>` | 评估人 / HR | 绩效录入(§2a)。★ **`editable` 真假两种都看**:有权编辑时第 8 列(动作)会叠进「目标」格 |
| 5 | `/purchasing/payment-terms/<模板 id>` | 采购 | 分期模板(§3b),5 列 → 4 列 + 移除钮叠下来 |
| 6 | `/purchasing/orders/new` | 采购 | 分期(§3a)。**选一张付款条款模板**才会有行;**同页上面那张行编辑表是 TABLE-PHONE-4 的,今天还没做** |
| 7 | `/sales/customers/<客户 id>` | 销售 | 同一页两张:联系人(§2.5)与催收(§2.4,催收面板) |
| 8 | `/suppliers/<供应商 id>/edit` | 采购 | 合规证书(§2.6),页面下半 |

**都用现成的 id,不要编** —— 从各自的列表页点进去即可
(`/hr/attendance`、`/hr/reviews`、`/purchasing/payment-terms`、`/sales/customers`、`/suppliers`)。

### ★★ 考勤与绩效这两组**要有真实的行才画得出来** ★★

**本刀没有连线上库查过有没有行**(本刀这一刀没有碰数据库,只跑了闸)。
这两张表都写着"没有行就整个不画表":

```js
{rows.length === 0 ? <p>{t('attendance.myEmpty')}</p> : <table>…}     // MyAttendancePanel
{goals.length === 0 ? <p>{t('reviews.noGoals')}</p> : <table>…}       // GoalsEditor
{myGoals.length > 0 && <table>…}                                      // MyReviewsPanel
```

☞ **所以:如果线上还没有考勤期间、或者那份考核还没加过目标,这两页会是一句"还没有",
不是一张表。** 那**不是本刀改坏了** —— 走查前先在列表页确认有数据,
或者先建一条再看。**与其让你点进去看见空页再来问,不如先说这一句。**

同样地:`ChasePanel` 要那个客户催过款、`CompliancePanel` 要那个供应商传过证书、
`MyExpenseClaimsPanel` / `MyLeavePanel` 要那个员工报过销 / 请过假。

---

## 10. ★ 本刀**没有**验证的事 —— 说白

**这一段和前两刀几乎一个字没变,因为情况一点都没变。**

1. **一个像素都没有量过。** 本刀写的是**标记**,而问题问的是**一个人在 390px 上看得见什么**。
   这两件事不是同一件事。
2. **没有浏览器**(委托书禁止安装),所以 `scripts/survey-phone.mjs`
   —— 那支真浏览器读 `scrollWidth` 的探针 —— **一次都没有跑。**
3. **"一个字段都没丢"的确切含义是:那些字段在标记里【在场】,并且各自带着列头**
   (例外是几个自己带字、桌面档也没有列头的控件)。**它不等于它们在 390px 上读得到。**
4. **`table-fixed` 没有加,十一张表仍然是 `width-auto`。**
   ☞ **如果走查看到三四列被挤开,那多半是这一条,不是选列选错了。**
5. **本刀没有在浏览器里按过任何一个叠进折叠块的钮。**
   "它在手机上按得着"是从**标记**推的(它被画出来、没有被 `hidden` 掉、
   `PermissionGate` / `ConfirmButton` / 禁用条件一个字没动),**不是按过的**。
6. **那 9 张能滚的表一个都没碰**(R-Q6),状态仍然是 **UNMEASURED**。
7. **`ContainerPanels:119` 没做**,它在手机上**仍然是坏的**(§2.3)。

### ★ 长到可能折行、把身份格撑开的列头 —— **点名**

委托书要求像 TABLE-PHONE-2 点 `pack.colSettlement` 那样点名。本批最长的几条:

| key | EN | 长度 | 它在哪 | 风险 |
|---|---|---|---|---|
| `chases.owedAtChase` | **Owed at time of chase** | 21 | **留在手机档【列上】** | ★ **本批最该看的一条** —— 它是 `ChasePanel` 三列里的一列的**列头**,在 390px 上很可能折成两三行,把整行撑高、把另两列挤扁 |
| `reviews.colAssessment` | Reviewer assessment | 19 | 叠加块标签(两处) | 折行会把「目标」格顶宽 |
| `attendance.colOtHoliday` | OT public holiday | 17 | 叠加块标签(两处) | 同上 |
| `suppliers.compliance.colType` | Certificate Type | 16 | **留在手机档【列上】** | 它是身份列的列头,折行会顶宽身份格 |
| `reviews.colEmployeeResult` | Employee result | 15 | 叠加块标签(两处) | 同上 |

☞ **这五条本刀一个都量不到** —— 中文那一份普遍短得多(「催收当时欠」5 字、「评估人评语」5 字),
**所以英文档比中文档更容易出事**,走查请**两种语言都切一次**。

---

## 11. 闸 · 构建

### 11.1 `python3 db/gate.py` —— **它自己的退出码 0**

```
GATE_OWN_EXIT=0
GATE_WALL_SECONDS=367
```

**四条判词,逐字:**

```
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
   判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
```

★ **墙钟 367s 落在 `db/gate.py` 那个 180–700s 的区间【之内】,所以本刀【没有】动那个区间。**
(门自己在判词那一行印的是 `wall-clock 266s` —— 那是**三条判词**的耗时;
**367s 是整支脚本的**,多出来的是末尾 `db/check_grants.py` 那一相。
两个数都记在这里,免得下一个人拿其中一个去对另一个 —— 前两刀也记过同一件事。)

★ 顺带记下门自己报的两件:`check_grants.py` 的**注入自检两格都变红**
(基线打瞎 · 查询打瞎);`anon` 够得着的函数仍然只有 `cod_verification(text)` 一个。

**本刀没有 SQL、没有迁移、没有 DDL** —— 门是照委托书 §10 跑的,不是因为动了库。

### 11.2 `npm run build` —— **它自己的退出码 0**

```
BUILD_OWN_EXIT=0
BUILD_WALL_SECONDS=37
```

**eslint 冻结闸,逐字:**

```
── eslint 冻结闸 ─────────────────────────────────────────────
基线  error 42 · warning 88
现在  error 42 · warning 88

✓ 没有新增的 eslint 问题。
```

**元检查(`check-instrument-selfproof`),逐字:**

```
✓ check-instrument-selfproof:32 支量具都写了瞄准线;其中 22 支(构建链里的,含本支)都带着覆盖断言。
```

**`check-datatable-phone`,逐字 —— ★ 委托书要求的那个 123:**

```
✓ 手机声明:123 个调用点(DataTable 119 · EditableTable 4) —— columns 模式 123(各自至少一列 priority)· scroll 模式 0(各自带 why) · 静态读不出 1(由渲染期那道网兜着)
```

★ **123 一个没变(DataTable 119 · EditableTable 4)** —— 这是
**本刀没有把任何一页转成 DataTable / EditableTable** 的旁证,也是委托书点名要的那一条。

### 11.3 本刀在过程里另外跑过的三支(都不在仓库里)

| 量具 | 用途 | 自证 |
|---|---|---|
| `npx tsc --noEmit` | 每改完一个文件跑一次 | 十一张做完 `TSC_OWN_EXIT=0` |
| `…/tp3/nofieldlost.mjs` | 「一个字段都没丢」 | **红过两次**(删条目 / 只删标签),各自点名那张表,还原后回 0 —— §5.3。**而且它自己被校准行咬出过两处错** —— §5.2 |
| `…/tp3/keys.mjs` | 把复用的 key 连中英文读出来 | `MISSING=0`;**第一版行解析器把 8 个存在的键读成"缺"**,改成求值模块才对 —— §6 |

---

## 12. 推送与部署(实测)

