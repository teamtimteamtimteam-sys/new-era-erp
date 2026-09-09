# TABLE-CONVERT-3 交回报告 —— 而【"没有列头"的表【正好六张】,三种情形分开数过;转换人口从 40 掉到 34,再掉到 26】

两件事:**① 把 Tim 判出局的那一类【数出来】**(此前只有两次观察,没有测量),
**② 转掉 sales 那一批 8 张**(含三份 AttachmentsPanel —— 一次判断,三个文件)。

**这一刀是本族第一次【真的量了桌面档】。** 前两刀都在 §"没有验证"里写着"桌面没量"。

---

## 1 · HEAD、树、与预期的差别

| | |
|---|---|
| 开工前 HEAD | `e25a06d41212008f5daed7d9e54d46ce7595198e` |
| 收工后 HEAD | 见末尾(本报告与代码同一次提交) |
| 树 | 开工前 `git status` 干净;`HEAD == origin/main` 逐字节相等 |

**与预期【没有】差别:** HEAD 正是 TABLE-CONVERT-2 那一次提交本身,后面没有文档提交。
`/tmp/TABLE-CONVERT-0-survey.md` 在(49094 字节)。

---

## 2 · ★ 任务一:没有列头的那一类,到底几张

### 2.1 人口先对上

自己写的扫描器(整标签花括号配平、先剥注释)在 `app/` 下数手搓 `<table>`:

```
扫到 63 张  ==  组件库棘轮基线的 63 张     ← 两支独立工具,同一个数
  −22  <table> 标签自己用了 tableC 的
  − 1  PayrollGrid(九张 UNMEASURED 之一)
  ─────
   40  开工时的转换人口
```

### 2.2 ★★ 三种情形【分开数】,它们不是一回事 ★★

| | 判据 | 张数 |
|---|---|--:|
| **①** | **整张没有列头行** —— 没有 `<thead>`,而且整个块里**一个 `<th>` 都没有** | **6** ← Tim 判出局的就是这一类 |
| **②** | 有列头行,但**每一个**格子都是空的 | **0** |
| **③** | 列头由 `.map()` 生成,静态读不出文字 | **1** |
| (—) | 有列头行,**其中一格**是空的(动作列那种) | 6 |

* **② 是 0** —— 这一类**在这个仓库里不存在**。报 0 是一次测量,不是"没找到"。
* **③ 只剩 1 张**(`app/finance/fx/bulk/BulkFxGrid.tsx:88`)。普查当初记了 4 张这种,
  其中 `PackBody` 那两张**已经被 TABLE-CONVERT-2 转掉了**,`ForecastGrid` 在 tableC 那一批里。
  **③ 不是 ① —— 它有列头,只是机器读不出;它仍然在转换人口里。**
* **(—) 那 6 张也不是 ①**:它们有真的列头,只是动作列那一格照惯例留空
  (GoalsEditor · ContainerPanels:119 · NewOrderForm:909 · TemplateForm:167 ·
  ContactsPanel:102 · QuoteLinesEditor:81)。**本刀转掉的 ContactsPanel 正是其中一张,
  它转得动** —— 这条正好证明"空一格"与"整张没有列头"必须分开数。

### 2.3 ★ 那六张【实际上是什么】—— 逐张看过源码,不是按类名判的

| 文件:行 | 它实际上是什么 | server? | 备注 |
|---|---|:-:|---|
| `finance/month-end/page.tsx:206` | **月结清单**:序号 · 步骤链接 · 状态徽章 · 说明 | SRV | TABLE-CONVERT-2 交回的那一张 |
| `hr/reviews/cycles/page.tsx:157` | **红色警告卡里的"就地补"清单**:员工链接 + 指派评估人的控件 | SRV | 卡内排版,两列 |
| `inbound/[id]/edit/PrepaymentPanel.tsx:148` | **预付款核销历史条**:金额 · 时间 · 分录链接 | client | 一个 h3 底下的紧凑条 |
| `logistics/containers/[id]/ContainerPanels.tsx:305` | **单证清单**,每行带一个行内状态表单 | client | ★ 它就是分类报过的【带 `name` 输入】那两张之一 |
| `logistics/forwarders/[id]/ForwarderPanels.tsx:167` | **费率报价列表**:航线 · 金额 · 有效期 · 免箱期 · 删除钮 | client | ⚠ **UNMEASURED** |
| `logistics/forwarders/[id]/page.tsx:203` | **运费凭证列表**:单号链接 · 方向 · 日期 · 金额 · 状态 | SRV | ⚠ **UNMEASURED** |

★★ **而这里有一条要请 Tim 自己看的:委托书说"没有人问它的列叫什么名字",
前四张确实如此,但【后两张不是】。** `ForwarderPanels:167` 与 `forwarders/page:203`
各是五列**成条记录的清单**(报价、凭证),它们读起来就是账簿 —— 只是**从来没有人给它们
配过列头**。把它们判成"借用表格排版"是照类名判的,照东西判就不像。
☞ **委托书要的正是这个核对,所以我把它摆出来,没有替它圆场。**
**而这两张同时是 UNMEASURED,本来也不许动** —— 两条理由指向同一个处置:先别碰。

### 2.4 ★ 我【没有】在这一刀给它们穿 tableC —— 理由,以及新的人口数

委托书说「便宜就顺手做,超过一小把就自成一刀」。**它不便宜:**

* **六张里有两张是 UNMEASURED**,「量之前不许动」的裁定还在。一次只能落到 6 张里 4 张的
  "整类搬迁",不是一次干净的搬迁。
* **穿 tableC 对这几张是一次【看得见的改装】,不是换个写法**:它们每一格都带着
  `border border-gray-300`,而 variant C 是**素表**(格子之间没有竖线,只有 1px 行分隔)。
  TABLE-STYLE-1 给 22 张做这件事时是**整整一刀**,而且是量过的。
* **而 variant C 最显眼的那一条对它们【根本不适用】**:2px Hawaiian Ocean 是画在
  **表头行**上的,这六张没有表头行。它们能拿到的只有内边距、字号与行分隔线。

☞ **所以:登记成一刀,不在这里做。** 而任务一真正要交付的是那个数:

| | 张数 |
|---|--:|
| 开工时的转换人口 | 40 |
| − Tim 判出局的"整张没有列头" | −6 |
| **= 新的转换人口** | **34** |
| − 本刀转掉的 sales 那一批 | −8 |
| **= 收工时还剩** | **26** |

**手搓表总数 63 → 55**;其中 22 张已穿 tableC、1 张 PayrollGrid、
**6 张待穿 tableC(新登记的这一类)**、**26 张待转换**。22+1+6+26 = 55 ✓

---

## 3 · 批次人口核对(对今天的源码,不是对普查的快照)

普查 §6.3 的 C-3:「sales 6 张 + 三个 AttachmentsPanel」= **8 张**
(其中一份 AttachmentsPanel 本身就在 sales 底下,所以是 6+2,不是 6+3)。

| 文件:行 | 列 | server? | 钉字号(普查/实测) |
|---|--:|:-:|:-:|
| `app/materials/[id]/edit/AttachmentsPanel.tsx:164` | 6 | client | 4 / 4 |
| `app/sales/customers/ChasePanel.tsx:239` | 7 | client | 4 / 4 |
| `app/sales/customers/ContactsPanel.tsx:102` | 6 | client | 11 / 11 |
| `app/sales/customers/StatementPanel.tsx:180` | 4 | client | 3 / 3 |
| `app/sales/customers/[id]/edit/AttachmentsPanel.tsx:171` | 6 | client | 4 / 4 |
| `app/sales/customers/[id]/page.tsx:271` | 4 | **SRV** | 1 / 1 |
| `app/sales/orders/[id]/page.tsx:162` | 4 | **SRV** | 1 / 1 |
| `app/suppliers/[id]/edit/AttachmentsPanel.tsx:171` | 6 | client | 4 / 4 |
| | | | **合计 32 / 32** |

* **八张全部在今天的源码里对上**:文件在、行号对、还是手搓的。**普查这八行没有一处过时。**
* **一张 UNMEASURED 都没有**(逐张比对过那份九张的名单)。
* **一个带 `name` 的输入都没有** —— 八个文件逐个 grep,`<input|select|textarea … name=` **零处**。
  (分类报过的那两张带 `name` 的都在 `ContainerPanels.tsx`,不在本批。)
* **两张 server component**,各建了一个 client 文件(`OpenItemsTable.tsx` / `OrderLinesTable.tsx`)。

★ **三份 AttachmentsPanel 确实是【一次判断三个文件】,而这一条是 diff 出来的:**
三个文件互为移植,`diff` 之后只差 **bucket 名 · 实体 id 名 · i18n 命名空间 · 分类清单**,
**表格标记逐字相同**。所以三份用**同一段转换**改,一份不落。

---

## 4 · ★ 每张表:手机上转换前留哪几列、转换后留哪几列

**读数来自真浏览器**(390×844 / dsf=3 / mobile),转换前的标记与转换后的**真组件**
喂同一份行数据各画一遍,读每个 `<th>` 的 `display`。

| 表 | 转换前 · 手机留下 | 转换后 · 手机留下 | 同一组? |
|---|---|---|:-:|
| `AttachmentsPanel` ×3 | File · Category · **Actions** | File · Category · **Actions** | ✓ |
| `ChasePanel:239` | Ref · Owed at time of chase · Promised | 同左 | ✓ |
| `StatementPanel:180` | Statement · Period · Closing balance · Issued | 同左 | ✓ |
| `customers/[id]/page:271` | Document · Sale date · Open (SGD) · Days | 同左 | ✓ |
| `orders/[id]/page:162` | # · Material · Quantity · Unit price | 同左 | ✓ |
| `ContactsPanel:102` | Name · Phone · Primary | Name · Phone · Primary **·(动作那一列)** | **差一列 —— 见 4.2** |

折起来的那一组,逐张相等:AttachmentsPanel ×3 = Type · Size · Uploaded;
ChasePanel = Date · How · Reached · What was said;ContactsPanel = Role · Email
(转换前还多一个空列头 —— 那就是动作列);其余三张一列都不折。

### 4.1 ★ 三个 AttachmentsPanel 各自渲染,视觉列集【三份相同】

不是"看源码一样所以一样",是三份都画出来读的:

```
after-attachments              ['', 'File', 'Category', 'Actions']
after-attachments-customers    ['', 'File', 'Category', 'Actions']
after-attachments-materials    ['', 'File', 'Category', 'Actions']
```
(第一个空串是组件在手机上多画的那一格展开钮。)
**一次判断,三个文件,三份渲染结果相同 —— 这条断言现在有读数了。**

★ 而它的动作列**转换前就已经留在明面上**(源码里那一列没有 `hidden sm:table-cell`,
注释写着「够不着的下载/删除,与没有这两个动作是同一回事」)。
所以这里的 `priority: true` 是**原样搬过来**,不是 R1 又改了一次判断 ——
**R1 当初正是照着这一列的理由写的。**

### 4.2 ★★ ContactsPanel 那一列差别,是 R1,报成差别不藏进"同一组" ★★

转换之前那一列带着 `hidden sm:table-cell`,而两颗钮**另外画了一份在姓名格里**
(源码原注释:「这一条没有标签,而它在桌面档也没有 —— 两个钮自己带着字」)。
也就是说它在手机上**本来就不用点开任何东西就够得着**。
组件里没有"叠在身份格里画出来"这一档:要么 priority,要么进点一下才展开的那一段。
折进去 = 先点开一行才够得着 = R1 判过的那件事。
☞ **所以 priority:true,列头保持空的(与转换前逐字相同,没有新增 i18n key)。**

**量出来的旁证 —— 顺手把一处【同一颗钮画两遍】也消掉了:**

```
before-contacts  tbody 里 8 颗钮:4 颗看得见(叠加块那份)+ 4 颗看不见(桌面列那份)
after-contacts   tbody 里 4 颗钮:全部看得见,inExpandArea=false
```
**8 → 4:转换前每一行的 Edit/Remove 在 DOM 里存在两份**(两个断点各一份),
现在只有一份。够不够得着没有变,重复没有了。

---

## 5 · 展开区:点开读过,每一列都带着自己的列头

| 表 | 点开之后 |
|---|---|
| `AttachmentsPanel` ×3 | `Type: application/pdf` · `Size: 277.5 KB` · `Uploaded: 2026-08-14 10:22`(三份都读到,内容相同) |
| `ChasePanel:239` | `Date: 2026-09-01` · `How: Phone` · `Reached: 林会计` · `What was said: …Invoice INV-2026-0311` |
| `ContactsPanel:102` | `Role: 财务经理` · `Email: shufen.lim@acme-metals.example` |
| `StatementPanel` / `openItems` / `orderLines` | **没有展开块** —— 四列全部 priority,组件在没有可折的列时不画展开钮。**与"这三张没有列选判断"一致。** |

---

## 6 · 空态:一张一张说

| 表 | 转换前 | 转换后 |
|---|---|---|
| `AttachmentsPanel` ×3 | `rows.length === 0 ?` → `<p>` 里 `…attachments.empty` | 搬进 `empty` prop,同一个 key |
| `ChasePanel:239` | 同形,`chases.none` | 搬进 `empty`,同一个 key |
| `ContactsPanel:102` | 同形,`contacts.noneYet` | 搬进 `empty`,同一个 key |
| `StatementPanel:180` | 同形,`statements.noneIssued` | 搬进 `empty`,同一个 key |
| `customers/[id]/page:271` | **三支三元**:无权 → `common.restricted`;空 → `customers.status.noOpenItems`;否则表 | 空那一支搬进 `empty`;**无权那一支原样留着** —— 见下 |
| `orders/[id]/page:162` | **没有空态**(`lines.map()` 直接画) | 用组件自带的 `table.empty` —— 见下 |

★ **`customers/[id]/page` 的"无权"那一支【不是空态】,没有合并。**
「看得见限额不等于看得见账」与「还没有未结项」是两件事,合成一句就把权限答复
说成了"没有数据"。**只搬了空态那一支。**

★ **`orders/[id]/page:162` 会多出一句 `table.empty`。** 转换前订单一行都没有时,
画的是一张只有表头、没有行的表;现在多一行 `table.empty`。
**这是本刀唯一一处会新出现在屏幕上的句子**,用的是组件既有的 key,不是我造的新词
(与 TABLE-CONVERT-1 的 `MyLeavePanel:61`、TABLE-CONVERT-2 的 `PackBody:78` 同一条)。

### 6.1 ★ 一处我自己做错又抓回来的:空态搬了、旧那一支忘了拿掉

第一版改完 `customers/[id]/page` 之后,`customers.status.noOpenItems` 的用量
**从 1 变成 2** —— 因为我把空态搬进了 `empty` prop,**却把旧的
`openItems.length === 0 ? <p>…</p>` 那一支留在原地**。
后果不是报错:空态照旧由旧那一支画,而 `empty` prop **永远到不了**,是一段死代码。
☞ **是 key 用量那张表把它抓出来的**(其余 16 个 key 全在往下走,只有它往上跳),
拿掉旧分支之后回到 1。**一次"数不对"就是一次缺陷,这一条又应验了一次。**

---

## 7 · 棘轮与手搓表数

| 维 | 之前 | 之后 | 差 |
|---|--:|--:|--:|
| 手搓 `<table>` | 63 | **55** | −8 |
| **cellfont** | **384** | **352** | **−32** |

**−32 与 §3 那张表"钉字号"一栏的合计【逐张相等】**(4+4+11+3+4+1+1+4 = 32,八个文件全部归零)。

构建里那两行原文:

```
   基线:106 个文件在册。本次扫到 352 处。
   分账:标签上 59 处(<table>/<th>/<td>) · 列描述符里 293 处(className: '…')。
✓ 没有新增的格子钉死的字号(<table>/<th>/<td> 标签 + 列描述符的 className)。
```

☞ **列描述符那一栏停在 293,与开工前【一模一样】** —— 八张表的列定义里一个字号都没有。
基线按工具自己的判词收紧,diff **只有 16 行删除**,没有一行新增。
`check-datatable-phone`:调用点 **136 → 144**(正好 +8),`columns 模式 144(各自至少一列 priority)`。

---

## 8 · 我量的是什么、在什么状态下量的、以及量不到什么

**量法**:一次性路由 `app/tc3probe`(**量完已删**),转换前的标记(逐字节抄自 `HEAD`)
与**转换后的【真组件】**喂同一份假数据各画一遍,`chrome-headless-shell` + CDP。

★ **这一刀的"后"是【真组件】,不是抄过去的列定义。** TABLE-CONVERT-2 对
`ImportStatementForm` 只能量一份抄过去的副本(那张表要 CSV + 映射才画得出来);
本批八张的真组件都能直接喂 props 画出来,所以量的就是它们本身。

★★ **【我量的是哪一个状态】—— TABLE-CONVERT-2 §8.1 的教训,这次先答:**
**`canEdit` / `canIssue` 一律给 `true`**,也就是**真的会去按那些钮的人**看到的状态。
(上一刀把它给成 false,权限提示里那串不可断行的 `module.finance.edit`
把读数带偏,差一点报出一条不存在的功绩。)

**它不是什么:** 不是那六条真实路由。数据是我编的;登录用的是一次性 admin。
**真实数据下会不会溢出仍然是未测量的** —— 列宽由内容决定,而真实的文件名、
摘要、邮箱比我编的长或短。

### 8.1 ★ 量测台自己撞上了这一族的那条边界 —— 记下来

第一版量测台是个 **server component**,而我把一个 `money` 函数传给了 client 的
Before 件,于是 `next dev` 当场报:

```
Error: Functions cannot be passed directly to Client Components …
  <... rows={[...]} money={function money}>
```

**正是这一族反复撞的那一条**(列描述符的 `render` 是函数,过不了 server→client)。
量测台加上 `'use client'` 就好了 —— 但它值得记一笔:**这条边界不是"页面才会撞",
是【任何跨过那道线的函数】都会撞。**

---

## 9 · 390px 与桌面的行高、溢出 —— ★ 桌面这一遍【真的量了】

### 9.1 390px

| 表 | 表头字号 | 表体字号 | 行高(前) | 行高(后) |
|---|---|---|---|---|
| `AttachmentsPanel` ×3 | 16 → **15px** | 16 → 14px | 177, 177 | 81.5, 81 |
| `ChasePanel:239` | 14 → **15px** | **12 → 14px** | 157.7, 139 | 81.5, 81 |
| `ContactsPanel:102` | 14 → **15px** | 14 → 14px | 117, 157 | 81.5, 141 |
| `StatementPanel:180` | 14 → **15px** | **12 → 14px** | 97, 97 | 121.5, 141 |
| `customers/[id]/page:271` | 14 → **15px** | 14 → 14px | 57, 57 | 81.5, 81 |
| `orders/[id]/page:162` | 14 → **15px** | 14 → 14px | 57, 57 | 121.5, 101 |

**行高大多变矮**(常驻叠加块收进了点开才展开的那一段);两张变高
(`StatementPanel` / `orderLines` 本来就没有可折的列,变高来自字号 12→14 与 C 的 `px-3 py-2.5`)。

**溢出 —— 而这一条的方向是【转换之前那一半】:**

整页 `clientWidth 390 · scrollWidth 400 · 溢出 10px`,而逐元素走下来,
把东西推到 390 以外的是 **`before-statements`**:

```
before-statements  th 'Issued'      right=400   ← 转换【之前】的标记
                   td '2026-09-01'  right=400
after-statements   盒 358 / 内容 358,一个元素都没有超出
```

☞ **转换之前,对账单那张表的最后一列在 390px 上是【推出屏幕的】**(要横着拖整页);
**转换之后没有了** —— 组件在手机上用 `table-fixed`,并且把表包在自己的
`overflow-x-auto` 里。**整页那 10px 全部来自 before 那一半。**

⚠ **两条限定,免得这条被读大:**
① 列宽由内容决定,这是**在我这份行数据下**的读数;
② 三份 AttachmentsPanel 的 `Delete` 钮在转换后伸到 `right=402`,**但整页 scrollWidth 是 400 不是 402**
—— 说明它被组件自己那层 `overflow-x-auto` 收住了,是**表内**十几像素的横向余量,不是整页溢出。

### 9.2 ★ 桌面 1280px —— 本族第一次量

```
六张表:visibleHeaders 转换前后【集合与顺序都相同】(6/6)
整页:clientWidth 1280 · scrollWidth 1280 · 溢出 0px
```

转换后各多一个**隐藏**的空列头 —— 那是组件手机档那一格展开钮
(`<th class="w-8 px-1 sm:hidden">`),在桌面上正确地不显示。
☞ **前两刀写在"没有验证"里的那一条,这一刀补上了。**

### 9.3 表体 14px vs 手搓表 15px —— 预料之中,报出来,**没有修**

八张转换后表体**全部 14px**,穿了 `tableC` 的那 22 张是 **15px**,差一个 token
(`data-table.tsx:526` 缺 `text-[15px]`)。**表头那一半合上了:八张全部 15px。**
**本刀没有碰 `data-table.tsx`。**

---

## 10 · 用户看得见的字:没有新词;key 用量 212 → 196

**没有新增、没有改动任何一句用户看得见的话。** 字面 `t('…')`:**212 → 196,少 16**,
**没有一个 key 掉到 0,也没有一个 key 上升**(§6.1 那一处上升是我的缺陷,已修)。

**这 16 处【全部】是"同一个列头/同一句话写了两遍"现在写一遍:**

| 来源 | 处 |
|---|--:|
| 三份 AttachmentsPanel 的叠加块(colType · colSize · colCreated,各 ×3 文件) | −9 |
| `ChasePanel` 叠加块(colDate · colChannel · colWho · colSummary) | −4 |
| `ChasePanel` 的 `chases.notReached`(桌面格与叠加块各写了一份) | −1 |
| `ContactsPanel` 叠加块(colRole · colEmail) | −2 |
| **合计** | **−16** |

**没有"从动态变字面"那一笔**(上一刀 PackBody 那种情形本批没有)。

---

## 11 · 我自己拿的主意

* **任务一那六张【不在本刀穿 tableC】**,理由与新人口数见 §2.4 —— 这是形状级的,报在前面。
* **`customers/[id]/page` 的"无权"那一支不合并进空态**(§6)。
* **`orders/[id]/page` 的 `#` 列头保持字面量**,不给它编一个 i18n key(转换前就是字面的 `#`)。
* **`ContactsPanel` 动作列的空列头保持空的** —— 不借机给它起个名字,那会是新增 i18n key。
* **三份 AttachmentsPanel 用同一段脚本改**,只换命名空间 —— 它们是一次判断,
  改法也应当只有一份,免得三份日后各自漂。
* **量测台的权限旗标给 true**(§8),并且把"为什么是 true"写在了量测台的抬头里。

---

## 12 · Tim 该在哪里走一遍,以及每一页需要什么状态

**六处,390px 与桌面各一遍:**

1. **`/suppliers/<id>/edit`、`/sales/customers/<id>/edit`、`/materials/<id>/edit`** ——
   三份附件面板。**需要:该实体名下至少两个附件。**
   390px:留 文件名 · 分类 · **操作**;★ 下载/删除**不用展开就够得着**
   (那一列转换前后都在明面上)。点 `›`:类型 · 大小 · 上传时间。
   ⚠ 删除钮比它分到的格宽略宽,**表内可以横向拖十来像素**。
2. **`/sales/customers/<id>`** —— 三张表在同一页:
   * **催收记录(ChasePanel)**:需要**至少一条催收记录**,最好有一条带承诺、
     一条已被取代(会渲染成灰行)。390px 留 单号 · 当时欠多少 · 承诺。
   * **联系人(ContactsPanel)**:需要**至少一个联系人**,最好有一个 `is_primary`。
     ★ 390px 上 **Edit / Remove 应当直接够得着**(它现在是自己那一列),
     而且**每行只画一份**(转换前是两份)。
   * **未结清单**:需要**登录账号有 finance 权限 + 该客户有未结单据**;
     没有权限时那一段仍然显示"受限"那句话,**不是空表**。
   * **对账单(StatementPanel)**:需要**至少出过一份对账单**。
     ★ **重点看最后一列「Issued」** —— 转换前它在 390px 上是被推出屏幕的(§9.1),
     现在应当在屏幕之内。
3. **`/sales/orders/<id>`** —— 订单行表。**需要一张有行的销售订单。**
   四列在 390px 上全部看得见,没有展开钮。

**顺手看一眼字号**:表头 15px 已经到位;**表体仍是 14px** —— 与手搓表的 15px
差一个 token(§9.3),是登记在案的另一刀。

---

## 13 · 我【没有】验证的东西

* ★ **六条真实路由一次都没有渲染过。** 全部读数来自一次性量测台 + 我编的假数据(§8)。
* ★ **§9.1 那条"转换前推出屏幕"是【在我这份行数据下】的读数。** 列宽由内容决定,
  真实的对账单单号/日期长度不同,结论可能变。**它是一次真实测量,不是一条普遍定理。**
* **只走了英文档。** 中文字宽不一样,没有单独量。
* **`orders/[id]/page` 那句 `table.empty` 的样子没有看过** —— 推出来它够得着,没渲染出来看。
* **对话框一次都没打开过**(ConfirmButton 的删除确认、ContactsPanel 的编辑面板)。量的是首屏。
* **任务一那份计数没有做过故障注入** —— 它与棘轮在 63 这个数上对上了,
  但没有人把它打瞎再看它会不会变红。
* **②(列头全空)报 0 是【本仓库今天】的读数**,不是"这种写法不可能存在"。
* **没有碰**:那六张待穿 tableC 的 · 其余 26 张 · 22 张 tableC · 九张 UNMEASURED ·
  组件的双画与那个缺的字号 token · 按行的格子 className(本刀没有再撞上)· 任何迁移(零 SQL 改动)。

---

## 14 · 收工

* **含闸** `python3 db/gate.py`(经 `db/run_detached.sh`,判词只取日志自报那一行):
  **`GATE_EXIT=0`**,墙钟 **391s**(`18:40:09Z` → `18:46:40Z`,在 180–700s 窗口内)。
  四条判词原文:

  ```
  判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
  判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
  判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
  判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
  ```

  ☞ 本刀**一行 SQL 都没有改**,跑含闸是照本族的规矩。

* **构建** `npm run build`:**`BUILD_EXIT=0`**(40s,一次过 —— 上一刀那种
  "搬走之后留下没人用的 import" 这次开工前就先跑了一遍冻结闸,没有发生)。

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

  cellfont 那一行原文:

  ```
     基线:106 个文件在册。本次扫到 352 处。
     分账:标签上 59 处(<table>/<th>/<td>) · 列描述符里 293 处(className: '…')。
  ```

* **一次性账号:干净。** 四次量测各建一个一次性 admin,**四次都自己删掉了**;
  收工时 `npm run reap:ephemeral` 报「没有滞留的清理计划」,线上按前缀查**零残留**。
* **量测路由 `app/tc3probe/` 已删**,不在这次提交里。
