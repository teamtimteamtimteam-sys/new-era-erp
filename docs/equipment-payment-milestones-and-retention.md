# 设备付款里程碑与质保金(EQP-PAY-1,2026-09-01)

**这份文件记的是两件事:一个字典的诞生,和一种"另一种形状的里程碑"。**
它同时收着两条【本刀之前不成立的假设】——写下来是因为它们看起来完全成立,
而下一个人会照样继承它们。

---

## 0 · 委托书里的两个前提,量出来是错的

### (i) 【没有里程碑字典】——"加几行"当时执行不了

委托书说"把设备里程碑作为**字典行**加进去,不要写在代码里"。而那时候**没有字典**。
那五个值住在**九个地方、零行数据**里:

| # | 位置 | 形状 |
|---|---|---|
| 1 | `db/tables/purchase_order_payment_terms.sql` | `CHECK (trigger_event IN (...))` |
| 2 | `db/tables/payment_term_template_lines.sql` | **同一份清单,抄了第二遍** |
| 3 | `app/purchasing/orders/new/actions.ts` | `const TRIGGERS = new Set([...])` |
| 4 | `app/purchasing/orders/new/NewOrderForm.tsx` | `const TRIGGER_OPTIONS = [...]` |
| 5 | `app/purchasing/payment-terms/actions.ts` | **第三份** `TRIGGERS` 集合 |
| 6 | `app/purchasing/payment-terms/TemplateForm.tsx` | **第四份** `TRIGGER_OPTIONS` |
| 7 | `messages/en.ts` | `purchasing.trigger.*` 标签 |
| 8 | `messages/zh.ts` | 同上 |
| 9 | `app/purchasing/orders/[id]/pdf/PurchaseOrderDocument.tsx` | `TRIGGER_PHRASE` 介词映射 |

> **设计问答里我说的是"六处"。那也是错的 —— 实际是九处。**
> 漏掉的三处是 payment-terms 那一对(模板表单自己的常量与它自己的校验集合)
> 与第二个 messages 文件。**一个数错了的清单与一个没数过的清单,在报告里长得一样**,
> 所以这里把它逐行列出来,而不是再给一个总数。

处置:建 `payment_trigger_events` 字典表,两条 CHECK 退役换成外键,九处全部指向它。
**标签也搬进表里**(`name_en` / `name_zh`)—— 若标签留在 `messages/`,加一种里程碑
就仍然要改代码,而委托书要的是"第七种里程碑必须是一行数据",那就包括它叫什么。

### (ii) 【"一张设备采购单"不是 schema 叫得出名字的东西】

`purchase_orders` **没有任何类型列**。设备与材料的区别在**行**上
(`purchase_order_lines.asset_id` XOR `material_id`,EQP-1a),而付款计划挂在**表头**上。
所以"在设备单上拒绝 after assay"这句话,在有人给"设备单"下定义之前,写不出判据。

本刀的定义:**一张单的种类由它的行决定**(`purchase_order_kind()`)。

> **★ 而我在设计问答里说"今天没有任何东西禁止混装单" —— 那句话也是错的。★**
> EQP-1a 早就建了 `trg_po_lines_single_kind`(延迟约束触发器,
> 报 `PO_LINES_MIXED_KINDS`),`db/fixtures/103` 的 F4 臂**在两个方向上都断言它**,
> 而 `PO_LINES_MIXED_KINDS` 在 `purchasingErrorCodes.ts` 里早就有文案。
> 我没有量就写下了"没有",于是主刀那一支加了**第二道同义的闸**。
> `-b-fu1` 把它撤掉了 —— 详见下面第 4 节。

---

## 1 · 字典:一张表,两个适用性布尔量

`payment_trigger_events`:

| code | 材料 | 设备 | 可作质保金的锚 |
|---|---|---|---|
| `on_order` | ✓ | ✓ | |
| `on_shipment` | ✓ | **✓** | |
| `on_arrival` | ✓ | ✓ | |
| `post_assay` | ✓ | **✗** | |
| `installation_complete` | ✗ | ✓ | |
| `acceptance_complete` | ✗ | ✓ | **✓** |
| `training_complete` | ✗ | ✓ | |
| `fixed_date` | ✓ | ✓ | |

**为什么是一张表配两个布尔量,不是两部字典。** `on_order` 与 `fixed_date` 对材料和设备
**是同一个概念**。拆成"材料集"与"设备集"两张表,就是把同一个概念写成两行,而两行会漂 ——
改了一边忘了另一边,同一个词在两张单上开始表示不同的事。

**排除的判据是"这件事会不会发生在它身上",不是"清单上有没有列"。**
委托书 R4 列的设备集是"下单 / 到货 / 安装 / 验收 / 培训 / 固定日"(它说"至少"),
而 `on_shipment` 对一台进口机器**完全成立** —— 凭装运单据付款是设备进口的常规。
R5 说一个用不上的选项比一个缺失的更糟(因为它选得中);**反过来,把一个用得上的
选项拿掉同样是错的**。所以设备侧排除的只有 `post_assay` 一个。
`db/fixtures/176` 的 G 臂钉着这一条:一份把设备集砍成 R4 那六个的实现在那里变红。

**"交付/到货"没有新开一行** —— 既有的 `on_arrival` 就是它(委托书 R4 让确认,确认了)。

---

## 2 · 两道闸,而这一层是【新增的】,不是收紧

实测:`create_purchase_order` **此前对 `trigger_event` 一个字都不校验** —— 它直接
INSERT,让表上那条 CHECK 去炸,于是屏幕上拿到的是一条裸约束原文。所以:

| 闸 | 位置 | 拒绝 |
|---|---|---|
| 门 | `create_purchase_order` | `PO_TERM_EVENT_NOT_APPLICABLE` / `TERMS_EVENT_UNKNOWN` |
| 表 | `trg_po_payment_terms_event_applicable` | 同上,**直连 PostgREST 也逃不掉** |

**一个禁用掉的下拉选项不是控制。** 屏幕那一层(按 `orderKind` 过滤)只是把话说得
早一点、好听一点。

**主语缺席那一格不放行**:一张没有行的单判不出种类 → `PO_TERM_KIND_UNKNOWN`。
"判不出就放行"正是本仓库记过的那条病(守卫对主语缺席这一格是瞎的)。

**为什么表上那道闸的 UPDATE 侧只挂在 `trigger_event` 上。** 见第 5 节 PO-2026-0007:
挂在整行 UPDATE 上会让那一行**连别的列都改不动**,而 CASHFLOW-1 的 `expected_date`
恰好要落在 `post_assay` 这类期次上 —— 一个与本刀无关的功能会因为一条历史数据坏掉。

---

## 3 · 质保金:另一种形状

### 3.1 为什么它不在 `purchase_order_payment_terms` 里

两个理由,任何一个都够:

1. **那张表存不下"某事之后 N 个月"。** 它只有 `due_date`(一个字面日期,而且
   `fixed_date` 那一种**必须**有它)与 `expected_date`(一个明说了是估计的值)。
   把算好的到期日写进 `due_date`,会让一个推导值长得和一条合同条款一模一样,
   并在验收日改变的那一刻**悄悄地错**。
2. **那张表的抬头自己声明它不是账**:"计划不是债权……也没有已付/未付状态列",
   并且不参与任何结算。而放款确认(谁、何时、放了多少、扣了多少、为什么)恰恰是一本账。
   把结算列螺到一张写着"我不做结算"的表上,是让它自相矛盾。

所以:`purchase_order_line_retentions`,**挂在【行】上**。四台机器是四条行,
各有各的资产卡与验收日 —— 挂在表头上就说不出"这台有质保金、那台没有",
而那是 Tim 强调了两次的要求。

### 3.2 可选性是【结构性】的

> **"0% 质保金"与"没有质保金"是两个不同的事实,而在这套系统里它们连长得一样的
> 机会都没有 —— 因为第二个【存不进去】。**

`percentage` 的 CHECK 是 `> 0`。所以"没有质保金"唯一的表达方式就是**没有那一行**。
屏幕上:没有质保金的单印**一句明说的话**("这张单没有质保金条款"),
不是留白(读起来像"还没填"),更不是一个 0%。

`db/fixtures/177` 的 A 臂断言这一条,并且故障注入过:把 CHECK 放成 `>= 0`,它当场变红。

### 3.3 到期【提示】,不【付款】

到期只让状态变成 `awaiting_confirmation`。**库里没有任何一条到期自动结算的路径。**
放款只经 `release_purchase_order_retention`,而它:

* 未到期 → `RETENTION_NOT_MATURE`(**提前放款等于把质保金废掉**);
* 没验收 → `RETENTION_CLOCK_NOT_STARTED`(这不是"还没到期",是时钟没起算);
* 放款 + 扣留 ≠ 总额 → `RETENTION_RELEASE_DOES_NOT_BALANCE`(差额会没有下落);
* 扣了钱不说理由 → `RETENTION_WITHHOLDING_NEEDS_REASON`;
* 放过一次再放 → `RETENTION_ALREADY_RELEASED`。

**两个金额都不给默认值。** 给一个"全额放款"的默认值,等于把"这台机器没出过毛病"
这个判断替人做了 —— 而那正是这次确认要问的唯一问题。

### 3.4 到期日是【推导】的

`maturity_date = fixed_assets.acceptance_date + retention_months`,活在
`purchase_order_retention_status` 视图里,**不存**。
`fixtures/177` 的 C 臂断言的是**差值**:验收推后 3 个月 → 到期推后 3 个月;
月数 12 → 18 → 到期推后 6 个月。故障注入(把到期日改成落单时算一次就冻住)当场变红。

**断言差值而不是字面日期**,是因为字面量会在有人改了 fixture 起始日时一起过期,
而读的人分不清是回归还是过期(fixtures README 第 1 条)。

---

## 4 · 锚:`fixed_assets.acceptance_date` —— 一列【新加的】,而它有理由

**实测:全库没有任何地方记录验收。** `fixed_assets` 上有 `acquisition_date`、
`in_service_date`、`planned_in_service_date`,没有验收。

### ★ 为什么不能拿 `in_service_date` 顶替 —— 它会错一整年,而且不出声

`FA-2026-0001`(Bosch 深放电机)实测:

| 列 | 值 |
|---|---|
| `acquisition_date` | 2026-08-21 |
| `planned_in_service_date` | 2027-01-01 |
| `in_service_date` | **NULL**(两台机器都是 —— 厂子没开工) |

若 2026 年 9 月验收合格,质保金应当 **2027 年 9 月**到期;锚在投用日上,
它会算成 **2028 年 1 月**。**差一年,在一笔真实的应付上,没有任何提示。**
验收合格是**商务/合同**上的事;投用是**会计**上的事(折旧从那天起算)。
它们是两件事,而这台机器就是那个证明。

### ★ 为什么它不会变成第二个 `planned_in_service_date`

那一列的病根写在它自己的注释里:**没有一条规则读它**,所以没填也没有任何后果,
于是它烂掉。委托书 4e 的警告针对的正是这一类("不要发明一个没人会填的验收字段")。
`acceptance_date` 恰恰相反:

* **一条规则读它** —— 到期日由它算出来;
* **一笔钱等着它** —— 没有它,质保金停在 `clock_not_started`,放不了款;
* **交易对方会来催** —— 供应商等着那笔尾款,他会盯着这个日子。

**一个空着就会有人来问的字段不会烂。**

**留空 = 质保期未起算。** 不是缺数据,不是零,不是错误 —— 今天对线上两台机器**都为真**。
**永不默认**:不从 `in_service_date`、不从 `acquisition_date`、不从任何东西推出来。
入口是 `set_asset_acceptance`(要 `module.finance.edit`,与 `set_asset_in_service` 同一道门)。

`can_anchor_retention` 是字典上的一格:**只有系统真的记得住日期的事件才能当锚**。
今天只有 `acceptance_complete`。锚在 `training_complete` 上 → `RETENTION_ANCHOR_HAS_NO_DATE`
—— 因为到期日算不出来,而算不出来的到期日会诱人去编一个。

---

## 5 · PO-2026-0007:一份真实单据上的一个用不上的里程碑

**实测,而且它就是 Tim 用系统时撞见的那个缺陷的实体:**

| 单据 | PO-2026-0007,SGD 400,000,一条设备行 → `FA-2026-0001` |
|---|---|
| 第 1 期 | 30% `on_shipment` — 设备侧适用 ✓ |
| 第 2 期 | 40% `on_arrival` — 设备侧适用 ✓ |
| **第 3 期** | **30% "Within 14 Days" `post_assay` — 设备侧【不适用】** |

**本刀【没有改它】,而这是一个决定,不是一次遗漏。**

* **迁移不因为它受阻。** 外键指向 `code`(`post_assay` 在字典里,只是设备侧
  `applies_to_equipment = false`),而适用性是**触发器**,只在 INSERT 与
  **改动 `trigger_event`** 时触发。所以这一行照旧读得出、印得出。
* **为什么不顺手改成 `acceptance_complete`。** 那一期的标签是"Within 14 Days"——
  合同上到底写的是"验收后 14 天"、"培训完成后 14 天",还是一个固定日期,
  **只有 Tim 知道**。系统里没有任何东西能回答它。**改一份真实单据的条款,
  要有人知道那份合同上写的是什么;猜一个,是把一次编造伪装成一次修复。**

**三个选项与各自的代价:**

| | 做什么 | 代价 |
|---|---|---|
| **A(本刀所采)** | 留着,报出来,由 Tim 按合同改 | 这一行在报表上仍是一个用不上的里程碑,直到有人动它。**改动它需要经过新的闸**(改 `trigger_event` 会被拒,除非改成设备侧适用的值)—— 也就是说,**下一次有人碰它时,系统会强迫他改对** |
| B | 迁移里直接改成 `acceptance_complete` | 便宜、干净、**而且可能是错的**;更糟的是它会**看起来是对的**,没有人会再去查合同 |
| C | 改成 `fixed_date` + 一个日期 | 要**编一个日期**。比 B 更糟 |

**怎么修(交给 Tim 的一步):** 打开 PO-2026-0007,把第 3 期的里程碑按合同改成
`acceptance_complete` / `training_complete` / `installation_complete` 之一,或者
`fixed_date` 加上合同上的那个日子。**改完这一行,线上就没有任何一条用不上的里程碑了。**
在此之前,可以用这一句查出所有这类行:

```sql
SELECT po.code, t.seq, t.label, t.trigger_event
FROM purchase_order_payment_terms t
JOIN purchase_orders po ON po.id = t.purchase_order_id
JOIN payment_trigger_events e ON e.code = t.trigger_event
WHERE CASE WHEN purchase_order_kind(po.id) = 'equipment'
           THEN e.applies_to_equipment ELSE e.applies_to_material END = false;
```

---

## 6 · 那道重复的闸(`-b-fu1`)

主刀那一支加了 `guard_po_lines_not_mixed` + `trg_po_lines_not_mixed`,理由是
"今天没有任何东西禁止混装单"。**那句话是错的**(见第 0 节 (ii))。

**为什么必须撤掉,而不是"多一道闸更保险":** 本仓库为"两份实现在写下来那天一致、
之后悄悄分开"已经付过四次账。两道判同一件事的闸是同一个病 —— 改了规矩的人只会改到
其中一道,而另一道会继续按旧规矩拒绝或放行,**谁都不会发现,因为它们平时给出同一个答案**。

**留既有的那一道**,理由不是它先来,是**它有断言**(fixture 103 F4 两个方向)。

**门上那一句留下,但改成同一个错误码。** 按名拒是本仓库的成文写法(与
`PO_LINE_KIND_INVALID` 逐字同源);它**不是**第二份实现,是同一条规矩**更早、
更好说话**的一次陈述 —— 既有那道是 `DEFERRABLE INITIALLY DEFERRED`,在 COMMIT
时才炸,那时整张单已经建完。参数形状也对齐成 `|单号|材料行数|设备行数`。
**一条规矩只能有一个错误码**,否则屏幕上会有一半的拒绝印出裸码。

---

## 7 · 仪表板臂:【不发】,连同它的触发条件

**判据是 `docs/dashboard-arm-inventory.md` 自己的三条,以及本刀验收标准里
"入口靠手走一遍确认"那一句。**

一条 `operations_now` 的臂("质保金到期,等人确认")**本刀不发**,理由:

1. **今天线上一条质保金都没有**,所以那条臂**恒空**。`operations_now` 是每个人
   落地就读的那一页;一条永远渲染零行的臂,与一条**坏掉的**臂在屏幕上一模一样。
2. **它今天没法用手走一遍确认。** 验收标准要求"入口靠手确认",而要让它出一行,
   得在线上造一条带质保金、且验收日在 13 个月前的记录 —— **那是往线上塞测试数据**,
   而线上已有的测试残留正是本仓库在册的问题之一。

> **可以证明它会判别 ≠ 应该现在发。** 一份回滚掉的 fixture **确实**能让它一行/零行
> 地区分开(`fixtures/177` 就在这么做)。但那证明的是**判据写对了**,
> 不是**这条臂今天能被看见**。两者不是一回事,而 `dashboard-arm-inventory.md`
> 要的是后者。

**替代的提示面(已发):** 采购单详情页上的质保金卡 —— 到期时它渲染的是一个
**要人回答的问题**(确认放款 / 扣留多少 / 为什么),不是一笔已经发生的付款。
**它的弱点要说出来:一个只在单据页上的提示,要有人去打开那张单才看得见。**
一笔 12 个月后才到期的钱,正是最容易被忘掉的那一类。这就是那条臂的价值,
也是下面这条触发条件存在的理由。

**触发条件(照 APR-2c 的写法):**

> **线上出现第一条 `purchase_order_line_retentions` 记录的那一天,把这条臂建出来。**
> 那一天它就能被手走一遍确认,前提也就成立了。
> 建的时候在 `docs/dashboard-arm-inventory.md` 的表格里加一行(那份文件自己的规矩),
> 权限用 `module.purchasing.view`,来源 `purchase_order_retention_status`,
> 判据 `retention_state = 'awaiting_confirmation'`,界限是"未放款的质保金"(天然很少)。

---

## 8 · R7:【不接维保模块】,连同它的触发条件

一条设备故障记录(`equipment_maintenance` / `equipment_downtime`)是扣留质保金
最自然的证据,把两者接起来值得做。**本刀不做**,而这是委托书自己的裁定(R7)。

理由不止"这是另一个决定":**厂子没开工,两台机器都没有投用,库里连一条故障记录都没有。**
在零条记录上设计一条"故障 → 扣留"的证据链,等于设计一个无法被检验的东西。

**触发条件:**

> **第一台机器投用(`in_service_date` 落地)、并且产生了第一条维保或停机记录之后**,
> 再决定这条链怎么接。届时要回答的具体问题是:
> 一次扣留要不要**必须**指向一条故障记录(强制),还是**可以**指向(可选);
> 以及质保期内已经修好的故障算不算扣留理由。
> **两个问题都要 Tim 的裁定,而它们在今天都没有可以据以判断的事实。**

今天的替代:`withholding_reason` 是**自由文本且必填**(扣了钱就要说为什么)。
它记得下"调试期间两次停机,备件费由供方承担"这句话 —— 记不下的是那条**指回故障记录的链接**。

---

## 9 · 本刀声明【不做】的

* **模板不按种类过滤。** 一份模板不属于任何一张采购单(它的抬头就是这么写的),
  所以它没有种类可言;判据落在**套用的那一刻**(往 `purchase_order_payment_terms`
  插行时由触发器按名拒)。代价:可以建出一份对设备单用不上的模板,而它要到套用时才被拒。
  **给模板加一个"种类"是一次真实的改进,但它需要 Tim 说清"一份模板可不可以两边都用"**,
  而没有人被问过。
* **质保金不产生应付。** 放款确认记的是一个**决定**,不过分录 —— 与
  `purchase_order_payment_terms`"计划不是债权"是同一条。把它接进 AP 是另一刀。
* **`payment_event_owners` 没有为新的三种事件加保管人。** 那张表的 CHECK 只认
  `on_shipment` / `on_arrival` / `post_assay`(需要**估计**的那三种)。
  安装/验收/培训完成日今天没有人在估,加三个名字进去会是**替三个人认领一件他们
  没被问过的事**(那张表自己的抬头正是这么论证 owner 为什么是文本而不是外键的)。
