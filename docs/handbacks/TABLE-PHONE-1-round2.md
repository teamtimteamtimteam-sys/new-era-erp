# TABLE-PHONE-1 —— 手机档选列,首批 6 次判断 / 8 张表(交回报告)

2026-09-09。**没有 SQL,没有迁移,没有新的用户可见文案,`messages/` 一个字都没动。**

---

## 1. HEAD 与树

| | |
|---|---|
| 开工前 HEAD | `75a1122f70855f62c753c66f08a5abf3987d9027` |
| 开工前 `origin/main` | `75a1122f70855f62c753c66f08a5abf3987d9027` |
| 开工前 `git status` | `On branch main` · `nothing to commit, working tree clean` |
| **本刀提交后 HEAD** | 见 §11(推送与部署实测) |

★ **这一次委托书写的 `75a1122` 与实测一字不差** —— 前两刀各差一个提交,本刀不差。

---

## 2. 八张表,逐张:改前几列 · 手机留下什么 · 什么叠了进去 · **一个字段都没丢**

**判据(FIX-2b 原话):390px 上读得到的字段数与桌面【完全相同】,变的只是排布。**
**「拿掉」指的是【那一列】,不是【那个事实】** —— 每一条叠进身份格的值都**带着自己的列头**。

### 2.1 `/finance/receivables` —— 10 列(§3.1)
`app/finance/receivables/page.tsx:168`

| | |
|---|---|
| **手机留下(3)** | 单据 `finance.colDocument` · 未结 `finance.colOpen` · 账龄 `finance.colDays` |
| **叠进「单据」格(7)** | 往来单位 · 发票号 · 日期 · 到期日 · 金额 · 已结 · 已贷记 |

它是 payables 的孪生(= payables + 发票号 + 已贷记),**判断照抄,没有新判断。**
★ 一处**本刀自己拿的主意**:往来单位在桌面档只画在每组第一行(`ri === 0`),
**手机档每一行都画** —— 那一格的"合并"靠的是上下相邻,而手机上一行占一屏,
相邻关系没有了。不这么做,第二行往后的数字就没有主语。

### 2.2 `/finance/assets` —— 12 列,全系统最宽(§3.2)
`app/finance/assets/page.tsx:137`

| | |
|---|---|
| **手机留下(3)** | 编号 `finance.colCode` · 净值 `assets.colNbv` · 状态 `finance.colStatus` |
| **叠进「编号」格(9)** | 描述 · 类别 · 购置日 · 在役日 · 成本(原币)· 金额(本位币)· 寿命(月)· 累计折旧 · **动作** |

★ **留净值不留成本** —— 一个人在手机上问的是"这台机器**现在**值多少"。
★ **动作叠进去了,而那一块是【画出来的】,不是收进折叠区的** ——
`AssetActions`(投用 / 处置)在 390px 上照样按得到。
一个够不着的处置钮与没有这个钮是同一回事(DBLOCK-1 的道理用在版式上)。

### 2.3 `/inventory` —— 9 列 → **桌面 8 列**(§3.3;单位并列见 §3)
`app/inventory/page.tsx:386`

| | |
|---|---|
| **手机留下(3)** | 物料 `inventory.colMaterial` · 入库量 `inventory.colInboundStock` · 市价价值 `valuation.colMarketValue` |
| **叠进「物料」格(5)** | 类别 · 加权均价 · 库存价值 · 成品库存 · 成本价值 |

★ **成品库存那一条连着它的钻取链接一起叠进去** —— 手机上照样点得进
`/inventory/output/<id>`。

### 2.4 `AttachmentsPanel` ×3 —— 各 6 列(§3.4,**一次判断,三个文件**)
`app/materials/[id]/edit/AttachmentsPanel.tsx:164` ·
`app/sales/customers/[id]/edit/AttachmentsPanel.tsx:171` ·
`app/suppliers/[id]/edit/AttachmentsPanel.tsx:171`

| | |
|---|---|
| **手机留下(3)** | 名称 `colName` · 分类 `colCategory` · **操作 `colActions`** |
| **叠进「名称」格(3)** | 类型 · 大小 · 上传时间 |

★ **「操作」整列留在手机上,没有叠进去。** 下载与删除是这张表在手机上的**用处**;
够不着的动作等于不存在。
★ 三个文件用**三个不同的 i18n 命名空间**(`materials.` / `customers.` / `suppliers.`)
装同一组列名 —— **本刀没有合并它们**(那是一次文案改动,不在这一刀里)。

### 2.5 `/me` · 年假明细 —— 6 列(§3.5)
`app/me/MyLeavePanel.tsx:61`

| | |
|---|---|
| **手机留下(3)** | 年度 `leave.grantYear` · **剩余 `leave.remaining`** · 状态 `leave.grantStatus` |
| **叠进「年度」格(3)** | 来源 · 天数 · 到期 |

★ **剩余是这张表存在的唯一理由** —— 有人点开「我的年假」,要的就是这一个数。
★ **同一个文件里的第二张表(`:117`,5 列)没有动** —— §3 没有点它的名,
§6 说没点名的不碰。它留在队列里(见 §6 的 TABLE-PHONE-5)。

### 2.6 「一个字段都没丢」是**量出来的**,不是声称的

写了一支校验(`/tmp/tp0/nofieldlost.mjs`,**不在仓库里**):
逐张表数「手机档画出来的列数 + 叠起来那一块里的标签条数」,与桌面档列数相比。

```
✓ REFERENCE (FIX-2b, untouched)  desktop= 8  phone cols=3 + stacked=5 = 8
✓ §3.1  /finance/receivables     desktop=10  phone cols=3 + stacked=7 = 10
✓ §3.2  /finance/assets          desktop=12  phone cols=3 + stacked=9 = 12
✓ §3.3  /inventory               desktop= 8  phone cols=3 + stacked=5 = 8
✓ §3.4a materials Attachments    desktop= 6  phone cols=3 + stacked=3 = 6
✓ §3.4b customers Attachments    desktop= 6  phone cols=3 + stacked=3 = 6
✓ §3.4c suppliers Attachments    desktop= 6  phone cols=3 + stacked=3 = 6
✓ §3.5  /me 年假明细              desktop= 6  phone cols=3 + stacked=3 = 6
✓ 8 张表:手机档读得到的字段数 == 桌面档,一列都没有丢。   VERIFY_OWN_EXIT=0
```

★ **第一行是【没有动过的】 `/finance/payables`** —— 拿一张已知合格的表校准这支量具。
★ **而且它证明过自己会红:** 从 receivables 的叠加块里**删掉一条**「日期」标签再跑 ——

```
✗ §3.1  desktop=10  phone cols=3 + stacked=6 = 9
     stacked labels: colCounterparty | invoice.colCode | colDueDate | colAmount | colSettled | colCredited
✗ 1 张表对不上 —— 有字段在手机上丢了。          VERIFY_OWN_EXIT=1
```

**它点了名、列出了活着的标签(于是缺的那条认得出来),然后还原,退回 0。**
一条从来没有真的红过的断言,和一条不存在的断言,退出码相同。

---

## 3. ★ `/inventory` 的「单位」并列 —— **单独报,因为它把桌面档也改了**

**这一处不是手机档的改动。** 它是 R-Q5 单独批的,而它超出"手机档"这一刀本来的边界。

| | 改前 | 改后 |
|---|---|---|
| 桌面档列数 | **9** | **8** |
| 「单位」列 | 独立的第 9 列,与它修饰的那两个数中间**隔着五列** | **没有了** —— 并进数字里 |
| 入库量那一格 | `12.5` | `12.5 t` |
| 成品库存那一格 | `3.0` | `3.0 t` |
| 空态 `colSpan` | 9 | 桌面 **8** · 手机 **3** |

**理由(Tim 的原话):`12.5 t` 是一个值,此前被拆成了两列。**
☞ **桌面用户会看见这个变化** —— 它不是只在 390px 上发生的。走查时请分开归因:
`/inventory` 上看到的列数变化里,**有一处是这个,不是手机档那件事。**

★ 链接仍然只挂在**数**上,不挂在单位上 —— 单位不是另一个去处。
★ 副作用:`inventory.colUnit` 这个 key **今天没有使用者了**。
两份语言包里都还留着,**本刀没有删** —— 仓库没有"未使用 key"的检查,
而删 key 是一次文案改动。已在 known-issues 里记下。
(`materials.colUnit` 与 `reviews.colUnit` 仍在用,没有受影响。)

---

## 4. 每一条用户可见的字 —— **一个新字都没有**

**`git diff --stat messages/` 是空的。** 本刀没有加、没有改、没有删任何一条文案。
叠进身份格的每一条标签,用的都是**那一列自己原来的列头 key**,
所以中英两份**自动跟着已有翻译走**,不存在"手机上是一种说法、桌面上是另一种"的可能。

**下面按屏幕列出【被复用的 key】及其今天的中英文** —— 全部**未改动**,
列在这里是为了让走查的人知道手机上该看见什么字。

### `/finance/receivables`(叠进「单据」格)
| key | EN | ZH |
|---|---|---|
| `finance.colCounterparty` | Counterparty | 往来单位 |
| `invoice.colCode` | Invoice | 发票号 |
| `finance.colDate` | Date | 日期 |
| `finance.agingAsOf.colDueDate` | Due date | 到期日 |
| `finance.colAmount` | Amount ({ccy}) | 金额 ({ccy}) |
| `finance.colSettled` | Settled | 已结 |
| `finance.colCredited` | Credited | 已贷记 |

小计行手机档另外叠了三个合计,复用同样的 `finance.colAmount` / `colSettled` / `colCredited`。

### `/finance/assets`(叠进「编号」格)
| key | EN | ZH |
|---|---|---|
| `assets.colDescription` | Description | 描述 |
| `assets.colCategory` | Category | 类别 |
| `assets.colAcquired` | Acquired | 购置日 |
| `assets.colInService` | In service | 在役日 |
| `assets.colCost` | Cost | 成本 |
| `finance.colAmount` | Amount ({ccy}) | 金额 ({ccy}) |
| `assets.colLife` | Life (months) | 寿命(月) |
| `assets.colAccum` | Accum. dep. | 累计折旧 |
| `assets.colActions` | Actions | 动作 |

### `/inventory`(叠进「物料」格)
| key | EN | ZH |
|---|---|---|
| `inventory.colCategory` | Category | 类别 |
| `valuation.colAvgPrice` | Avg Price (SGD) | 加权均价 (SGD) |
| `valuation.colStockValue` | Stock Value (SGD) | 库存价值 (SGD) |
| `inventory.colOutputStock` | Finished stock | 成品库存 |
| `valuation.colCostValue` | Cost Value (SGD) | 成本价值 (SGD) |

★ 「单位」不再是一条标签 —— 它现在是数字后面的一截(`12.5 t`),
走的是既有的 `unitLabel(r.unit)`,**不是一条新文案**。

### `AttachmentsPanel` ×3(叠进「名称」格)
三个命名空间,**同样三条**(`materials.attachments.*` / `customers.attachments.*` /
`suppliers.attachments.*`):

| leaf key | EN | ZH |
|---|---|---|
| `colType` | Type | 类型 |
| `colSize` | Size | 大小 |
| `colCreated` | Uploaded | 上传时间 |

### `/me` 年假明细(叠进「年度」格)
| key | EN | ZH |
|---|---|---|
| `leave.grantType` | Source | 来源 |
| `leave.days` | Days | 天数 |
| `leave.expires` | Expires | 到期 |

---

## 5. 记录改写(`docs/known-issues.md` 的 `RAW-TABLE-PHONE-SWEEP`)

**没有把 54 换成 39 就算完 —— 两个方向的错各自写了【是什么、为什么、怎么发现的】。**

新的这一条现在说六件事:

1. **真数**:72 张表 / 62 个文件;≤4 列 **29 张免修**;≥5 列 **43 张 / 39 个文件**是工作单;
   其中 9 张已有滚动外壳,**33 张 / 30 个文件够不着**。
   **连判据一起写下来了**(剥注释与字符串、整份源码上跑不按行切、
   减掉 `hidden sm:table-cell`、行位置的组件解析到定义、双向钉住 79==79),
   **不是只写结论** —— 下一个人可以据此复算。
2. **① 四个假阳性**:`<table>` 只在**注释**里,而四条注释都在说"这一页已经转换掉了"。
   **四条修好的记录被当成四笔欠债**,而清单上那个 `<th>=0` **就是它在喊**。
   点名了是 CONV-8 那条具名教训的第四次,并写下解药(先剥注释再匹配)。
3. **② `<thead>` 通胀**:判据是 `count(/<th/)`,**没有词边界**,`<thead>` 也匹配。
   **54 条里 53 条精确等于这个数**,第 54 条是 PUR-1 事后加了一列(`git show` 验过)。
   **并写明这一条直接改工作单大小** —— 清单写 5 列的页真身是 4 列,按既有规矩不该被打开。
4. **③ 反方向的 12 个漏网**:`overflow-x` 是**按文件**问的,于是文件别处有一个
   `overflow-x` 就把它那张没外壳的表整个漏掉。逐个列了名,并写明判据该问的是**祖先**。
5. **选列不需要转 DataTable**:`priority` 只有 DataTable 读得到(点了四处行号),
   而 `/finance/payables` 是手搓表且已经选完列 —— 转换的代价(13 个服务端文件各要新建
   客户端文件、13 张表要去 `EditableTable`)也写下来了。
6. **R-Q2 的切法**(30 个够不着的是工作单;9 张能滚的够得着,归较轻的那一半、单独排队)
   与 **R-Q7 的决定**(`scroll` 分支 0 调用点也留着,并写明为什么,免得下一个人当死代码删掉)。

★ 还加了本刀做完的那张表(六次判断 / 八张表),以及**剩下 26 张 / 24 个文件**。
★ 并写明了一件容易数错的事:**7 张做完,但只有 6 个文件整个清干净** ——
`app/me/MyLeavePanel.tsx` 里还有第二张 5 列的表,这一刀没点名所以没动。

---

## 6. 队列(`docs/forward-queue.md`)

**旧条目整条换掉了** —— 它当中那张"甲/乙/丙三选一"的裁定表已经答完,留着会让人以为还要裁。

**① `RAW-TABLE-PHONE`** —— 裁定已下、首批已上线,**剩 26 张表 / 24 个文件**。
六条裁定(R-Q1/2/4/5/7/8)逐条写在条目里。**触发条件:没有了** —— 照 payables 做即可。
后续四批**正好把 26 张分完,不重不漏(数过的,见下)**:

| 批 | 内容 | 表数 / 判断数 |
|---|---|---|
| TABLE-PHONE-2 | 钱、只读账簿(packs ×2 · trial-balance · close · 工资条) | 5 / 5 |
| TABLE-PHONE-3 | **成对的那三组**(考勤 · 绩效 · 付款条款分期),按 R-Q4 两次判断一次讨论 | 6 / **3** |
| TABLE-PHONE-4 | 录入表单里的行编辑表 | 9 / 9 |
| TABLE-PHONE-5 | 其余(含 MyLeavePanel 第二张) | 6 / 6 |

```
batches total: 26   remaining total: 26
in batches but NOT remaining: []      remaining but NOT in batches: []      duplicates: []
```

**② `RAW-TABLE-PHONE-WRAPPED`** —— 那 9 张已有滚动外壳的表,**状态写成【UNMEASURED】**。
条目里说清三件事:它们**够得着**(所以是探针说的较轻的那一半);
"够得着 ≠ 读得懂"对它们**仍然成立**,所以大概也要选列或显式声明 `scroll`;
而**今天没有任何人量过它们在 390px 上读不读得懂** ——
**触发条件是先量(真浏览器探针或一次手走),再决定**(R-Q6)。

---

## 7. 本刀自己拿的主意(都是细节,不是形状)

1. **往来单位在手机档每一行都画**(桌面档只画每组第一行)。理由在 §2.1:
   合并靠的是相邻,而手机上没有相邻。
2. **`/finance/assets` 的动作叠进身份格,`AttachmentsPanel` 的操作整列留着。**
   两种画法,同一条道理(够不着 = 不存在)。差别只是列宽预算:assets 有 12 列要塞,
   Attachments 只有 6 列。
3. **把 `inServiceState` / 原币成本 / `AssetActions` / 入库量 / 成品库存等提成变量**,
   两个断点**共用同一份节点**。照抄两份的话,两处会各自漂 —— 而那种漂
   在桌面上看不见(桌面那份是对的),只在手机上错。
4. **`inventory.colUnit` 这个 orphan key 留着不删**(理由见 §3)。
5. **`AssetActions` 在 DOM 里会有两份**(手机一份、桌面一份,CSS 各藏一个)。
   查过:它没有固定 DOM id、没有 portal、没有 `useId`、没有 `useEffect`,
   状态全是自己的 `useState` —— 两份互不干扰。这是断点类这条路本身的代价,
   payables 对**值**也是这么做的。
6. **`/me` 那第二张 5 列的表没动** —— §3 没点名。
7. **校验量具不进仓库**(与 R-Q8 同一条理由)。

---

## 8. 走查:去哪儿看,以及**怎么才能真的看见手机档**

### ★★ 先说最要紧的一件:**把窗口拖窄【不一定】能看见手机档** ★★

断点是 Tailwind 的 `sm`,即 **640px**。`hidden sm:table-cell` 的意思是
「**视口宽度 < 640px 时不画**」。所以:

* **桌面浏览器把窗口拖窄到 640px 以下,是【能】看见的** —— 这些类走的是
  CSS media query(`min-width: 640px`),它只看**视口宽度**,不看设备。
* **但拖窄的窗口不是 390px 的手机**:字体缩放、滚动条占位、以及
  **本刀量不到的那件事 —— 真实文字在真实宽度下会不会把三列挤开**,都不一样。
* ☞ **要看真的手机档,用开发者工具的设备模拟(iPhone 12 / 390×844),
  或者直接用手机打开。** 三列在 390px 上够不够,**只有那样才算数**。

### 走查清单

| 页 | 路由 | 看什么 |
|---|---|---|
| 应收账龄 | `/finance/receivables` | 390px 上只剩**单据 / 未结 / 账龄**;单据格下面叠着七条,**每条都有列头**;小计行叠着金额/已结/已贷记 |
| 固定资产 | `/finance/assets` | 只剩**编号 / 净值 / 状态**;**「动作」在叠加块里,而且按得动**(投用 / 处置) |
| 库存 | `/inventory` | 只剩**物料 / 入库量 / 市价价值**;★ **桌面档也要看** —— 「单位」列没了,数字变成 `12.5 t` |
| 附件 ×3 | `/materials/<id>/edit` · `/sales/customers/<id>/edit` · `/suppliers/<id>/edit` | 只剩**名称 / 分类 / 操作**;**下载与删除在手机上够得着** |
| 我的年假 | `/me` | 余额明细那张表只剩**年度 / 剩余 / 状态** |

### 角色与真实记录

* `/me` 是**自助页**,任何登录用户都看得见自己的;年假明细要该员工**有年假授予记录**才画。
* 其余五页要相应模块的读权限;`/finance/assets` 的**动作**还要 `canEdit`。
* ★ **本刀没有查线上有哪些真实记录可走** —— 那要连库,而这一刀是纯前端、
  委托书也没有要求。**不编 id。** 下面是只读查询,Tim 自己跑或交给下一刀:

```sql
-- 三张附件表各挑一条【有附件的】母记录
select 'material' as kind, material_id::text as id from material_attachments where deleted_at is null limit 1;
select 'customer' as kind, customer_id::text as id from customer_attachments where deleted_at is null limit 1;
select 'supplier' as kind, supplier_id::text as id from supplier_attachments where deleted_at is null limit 1;

-- 固定资产:挑一台 active 且有成本的 —— 两个动作才都亮着
--（fixed_assets 没有 deleted_at 列,所以这里不过滤软删)
select id, code, status from fixed_assets where status = 'active' and cost_base > 0 limit 3;

-- 年假:挑一个有授予记录的员工
select employee_id, count(*) from leave_grants where deleted_at is null group by 1 order by 2 desc limit 3;
```

★ **表名与列名逐个对过 `db/tables/` 的镜像**(`material_attachments` /
`customer_attachments` / `supplier_attachments` / `fixed_assets` / `leave_grants`),
**并且核过软删列**:三张附件表与 `leave_grants` 有 `deleted_at`,
**`fixed_assets` 没有** —— 所以那一句不过滤,不是漏写。
**但本刀【没有把这几句真的跑过线上】** —— 这一刀是纯前端,没有连库。
所以它们是"照镜像写对的查询",不是"回过行的查询。

---

## 9. ★ 本刀**没有**验证的事 —— 说白

**这是这份报告里最要紧的一段。**

1. **一个像素都没有量过。** 本刀写的是**标记**,而问题问的是
   **一个人在 390px 上看得见什么**。这两件事不是同一件事。
2. **没有浏览器**(委托书禁止安装),所以 `scripts/survey-phone.mjs`
   —— 那支真浏览器读 `scrollWidth` 的探针 —— **一次都没有跑。**
3. **于是"一个字段都没丢"这句话的确切含义是:**
   **那些字段在标记里【在场】,并且各自带着列头。**
   它**不等于**它们在 390px 上**读得到** —— 三列仍然可能被长物料名、
   长单据号或一串金额挤开。**payables 那次的 480px 溢出就是这么来的。**
4. **`table-fixed` 没有加。** BASE-1 在 DataTable 上量出过:`auto` 之下
   一个格子能把整列撑宽。这几张手搓表**仍然是 `auto`** ——
   本刀不加,因为那是一次没有量过的版式改动,而 §4 说只改哪几列画出来。
   ☞ **如果走查看到三列被挤开,那多半是这一条,不是选列选错了。**
5. **那 9 张能滚的表一个都没碰**(R-Q6),而它们读不读得懂**仍然没量过**。

> ☞ **走查是今天唯一的证据。** 量具能证明的只有"字段在场、列数对得上";
> "读得懂"要一个人拿着手机看。

---

## 10. 闸 · 构建

### 10.1 `python3 db/gate.py` —— **它自己的退出码 0**

```
GATE_OWN_EXIT=0
GATE_WALL_SECONDS=466
```

**四条判词,逐字:**

```
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
```

★ **墙钟 466s 落在 `db/gate.py:38` 那个 180–700s 的区间【之内】,所以本刀【没有】动那个区间。**
(门自己在三条判词那一行印的是 `wall-clock 361s` —— 那是三条判词的耗时;
466s 是**整支脚本**的,多出来的是末尾 `db/check_grants.py` 那一相。
两个数都记在这里,免得下一个人拿其中一个去对另一个。)

★ 顺带记下门自己报的两件:`check_grants.py` 的**注入自检两格都变红**
(基线打瞎 · 查询打瞎);`anon` 够得着的函数仍然只有 `cod_verification(text)` 一个。

**本刀没有 SQL、没有迁移、没有 DDL** —— 门是照 §10 跑的,不是因为动了库。

### 10.2 `npm run build` —— **它自己的退出码 0**

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

★ 顺带:`check-datatable-phone` 仍然是 **123 个调用点(DataTable 119 · EditableTable 4)**,
一个都没变 —— **本刀没有转换任何一页**,这是它的旁证。

### 10.3 本刀在整个过程里另外跑过的两支(都不在仓库里)

| 量具 | 用途 | 自证 |
|---|---|---|
| `npx tsc --noEmit` | 每改完一张表跑一次 | **注入过一个真的类型错**(把 `t('finance.colOpen')` 改成 `t(12345)`)→ `TSC_OWN_EXIT=2` 并点名 `receivables/page.tsx(180,96)`;还原后回到 0 |
| `/tmp/tp0/nofieldlost.mjs` | 「一个字段都没丢」 | **删掉一条叠加标签** → `VERIFY_OWN_EXIT=1` 并点名那张表;还原后回到 0(见 §2.6) |

---

## 11. 推送与部署(实测)

**本节由紧随其后的一个提交补齐** —— 部署要先有提交才谈得上,
而交回报告必须与工作【同一个提交】进仓库(委托书 §9)。
本仓库对这件事已有两次先例(`df64373` NARROW-COVERAGE-1 §12.3、
`75a1122` SMALL-BATCH-1 §11),本刀照同一个办法做。

**要补的四件,一件都不少:**
1. `git push` 之后**用 fetch 比对哈希**确认推上去了 —— 不读 push 命令的输出
   (管道里的 push 报的是管道的退出码,不是 git 的)。
2. **分开问两个问题**:① 有没有一次 success 的部署;② 它的 sha 是不是本刀这个提交。
3. 部署 id · sha · success 时间。
4. 结束时树是干净的。

---

## 12. 收尾

* **没有 SQL,没有迁移,没有 DDL,没有新文案,没有版本行。**
* **只改了 7 个页面文件 + 2 份文档**(`docs/known-issues.md` · `docs/forward-queue.md`)
  + 本报告。
* **没有转换任何一页到 DataTable / EditableTable**(`check-datatable-phone` 的 123 一动没动)。
* **那 9 张已有滚动外壳的表一个都没碰**(R-Q6),它们的状态是 **UNMEASURED**。
* **普查量具没有进仓库**(R-Q8)。
