# 损耗类别 · 形态取值 · 可售性(PROC-BUILD-1,2026-08-30)

**依据:** `docs/operation-model-scoping.md`(PROC-MODEL-0,`3ca72f9`)。
那份普查把七件事分成 **一个模型(五件) + 一件独立可发(损耗类别) + 一个动因(放电)**,
并建议 **「先建那件小的,其余等真炉次与 Tim 的答案」**。**本刀建的就是那件小的**,
外加它顺带需要的形态取值,以及 Tim 在本刀期间给出的可售性裁定。

## 本刀【没有】建什么 —— 边界写在最前面

**五件被挡住的一件都没建:** 工序类型与路由 · 一炉的时长 · 在制品 · heel ·
不过磅的循环流。**也没有建"只建那张表"的版本。**

> ### ★ 工序类型字典【本刀撤下】,而撤下它的那个发现比那张表值钱 ★
>
> brief 原本的 STEP 5 要建一张工序类型字典(不接线)。**grill 把它拆穿了:**
> 它要求每一行声明自己收哪些形态、出哪些形态 —— **那就是【路由】**,
> 而路由正是 scope 条款明令排除的那五件里的第一件。**brief 与自己矛盾。**
>
> **而决定它的是一条测量,不是一个偏好:**
>
> **【码】R3 那种工序(放电:同一批进、同一批出,只改状态,不产新批)
> 今天【没有任何东西跑得动它】** ——
> `db/functions/commit_processing_run.sql:101` 对空产出数组抛 `NO_OUTPUTS`:
>
> ```sql
> IF jsonb_array_length(p_outputs) = 0 THEN RAISE EXCEPTION 'NO_OUTPUTS'; END IF;
> ```
>
> 也就是说,那张字典最重要的一条表达力,指向的是一种**引擎拒绝提交的**工序。
> 建它等于建一张**没有人能行使**的表。
>
> ### 这两件事必须带进接线那一刀,别在这里丢掉
>
> 1. **`NO_OUTPUTS` 是接线刀的【范围内】事项,不是当前引擎的缺陷。**
>    今天它是对的:没有工序类型,一张"投了料没产出"的单确实没有意义
>    (`operation-model-scoping.md` 2d 已判)。R3 一进来它就必须被重新裁定 ——
>    **把它写进接线刀的 scope,而不是记成一条 bug。**
> 2. **那张字典的形状【已经不再是未知】了。** Tim 的 R1/R2/R4 回答了
>    `operation-model-scoping.md` 里挡着它的那几问:
>    * **Q1**(有序链还是无序集)→ **R1:无序集**,每道工序自己声明收什么、出什么;
>    * **Q2**(隔膜/电解液/壳体是位置还是出口)→ **R4:出口**;
>    * **Q4**(一炉是一台机器还是一条线)→ **R2:一台机器 = 一道工序**;
>    * **U7**(哪几道工序 Evoltrya 自己做)→ **R2 逐条列了**。
>    **所以接线那一刀是【可设计的】了,而它上一周还不是。**
>    这句话不能因为表没建就丢掉 —— 它是本刀最有价值的产出之一。

---

# 一 · 损耗类别 —— 唯一一件今天在【发声而且说错】的

## 改之前是什么(逐条带对象名)

**【码】`processing_runs.loss_qty`,一个 numeric,没有类别、没有理由。**
`db/functions/commit_processing_run.sql:192`:

```sql
COALESCE(p_loss_qty, v_total_input - v_total_output)
```

**于是【任何】差额都被静默记成损耗** —— 蒸发、粉尘、送去处置的残渣,
以及**一次过磅误差**,四件事进同一个数。唯一的守卫是
`LOSS_NEGATIVE`(`:103`)与 `OUTPUT_EXCEEDS_INPUT`(`:182`),
**没有任何东西断言 `loss_qty` 与「投入−产出」相等**。

**W2/F4 数过被它污染的四个数,逐个点名:**

| # | 被污染的数 | 怎么被污染的 |
|---|---|---|
| 1 | **含金属量** | `processing_metal_recovery_all` 拿**过磅重量 × 含量**算投入金属 |
| 2 | **回收率** | 建立在 ① 之上;而水(金属留着)与粉尘(金属走了)合在一个数里,**扣分方向取决于当天湿度** |
| 3 | **批次估值** | `allocate_processing_costs` 的 `metal_value` 分摊基准读 ① |
| 4 | **销售定价参考** | 读 ③ |

> **四个数会互相印证,因为它们错得一模一样。**

## 建了什么

| 对象 | 是什么 |
|---|---|
| `loss_metal_fates` | 金属去向字典,**3 行**:`stays` / `leaves` / **`unknown`** |
| `loss_categories` | 损耗类别字典,**4 行**,每行带 `metal_fate` + `is_true_loss` |
| `processing_run_losses` | 事实行,主键 `(run_id, loss_category_code)` |
| `processing_run_loss_breakdown` | 视图:**已解释 / 还没解释** |
| `guard_processing_run_losses` | 约束触发器:分类之和不许超过 `loss_qty` |

**四个类别:**

| code | 中文 | metal_fate | is_true_loss |
|---|---|---|---|
| `moisture` | 水与挥发物 | `stays` | true |
| `dust_spill` | 粉尘与洒漏 | `leaves` | true |
| `residue_disposal` | 残渣送处置 | `leaves` | **false** |
| `electrolyte_evaporation` | 电解液挥发 | **`unknown`** | true |

### 电解液为什么【自成一类】,不并进 `moisture`(brief 2b 要求作答)

**因为 `metal_fate`。** `moisture` 那一行断言 **「金属留着」**;
而电解液带不带走金属 **今天没有人知道** —— **【码】线上产出批上的化验记录是 0 条。**
并进去等于**免费送出一个未经证实的断言**,而那个断言会直接流进回收率 ——
**那正是 W2/F4 记过账的那一种污染,只是换了一个入口。**

`unknown` 因此是一个**说得出口的取值**,不是一个空:
「我们查过,而答案是不知道」与「没有人填过」分得开,后者由 NOT NULL 拦掉。

## 与 `loss_qty` 的关系(brief 2c 要求作答)

**`loss_qty` 本刀一列都没动。** 普查把这件事评为 CHEAP,理由正是那一列留着。

* **两者【不必相等】,而且现在【刻意】不要求相等。**
  产线还没开,没有人知道各类占多少;要求相等等于**逼操作员编一个数去凑平**,
  而编出来的数与量出来的数在报表里长得一模一样。
* **但分类之和【不许超过】 `loss_qty`。** 这条守得住,**因为它不需要知道真实配比** ——
  与 `OUTPUT_EXCEEDS_INPUT` 是同一个形状:**一条不等式可以在真值未知时断言,
  一条等式不行。** 违反时按名拒:`LOSS_CATEGORIES_EXCEED_LOSS_QTY|<单号>|<和>|<总量>`。
* **`loss_qty` 为空时不拦。** 空的意思是「没有人记过总量」,不是「总量是零」——
  拿 0 去比就是 METAL-1 的 `no_reference` 那个错。
* **差额** = `loss_qty − Σ已分类` = **还没有解释的质量**,由
  `processing_run_loss_breakdown.unexplained_qty` 说出来;
  **`loss_qty` 为空时它是 NULL 不是 0**(0 会读成「全部解释完了」)。

**什么时候该改成必须相等:** 真实炉次跑够、三类的量级被量出来之后 ——
那时等式才是一条**可执行**的判据,而不是一条逼人编数的规矩。

## 【它答不了什么】过磅误差不是损耗(brief 2d 要求作答)

**能分开的:** 「我们说得出这部分质量去哪了」(已分类)与
「还没有人说」(`unexplained_qty`)。

**分不开的:** `unexplained_qty` 里混着**两件事** ——
**还没有人去分类的损耗**,与**账本身对不上**。
要把它们分开,需要有人**断言**「这批数字对不上」,而**那个断言今天没有地方放**。

> ### 遗留缺口(具名):**称重差异没有位置**
> **本刀【刻意不建】一个叫「过磅误差」的损耗类别。**
> 那会把一个**记账问题**伪装成一件**物理事实** —— 而这正是 `loss_qty`
> 今天在犯的错的小号版本:一个把不同种类的事塞进同一个容器的容器。
> **归属:** 称重与对账那一刀。**返回条件:** 第一次真实过磅出现差异。
> **形状已有先例:** `declared_qty` / `quantity` + `grn_discrepancies`
> —— 两个值都活着,差异由一个视图说出来,**报告而不拒绝**。

---

# 二 · 形态取值

**【码】`materials.form_code` 与 `material_forms` 字典是 PROC-2 建的,本刀只加取值。**
加的七个,逐个对过既有六行(brief 3a):

| 新增 | 与谁最像 | 为什么不是同一行 |
|---|---|---|
| `de_cased_cell` 已开壳电芯 | `loose_cells` 散电芯 | 后者表注写着**「仍需要开壳」** —— 新的是它**之后**的一格 |
| `cathode_sheet` 正极片 | `electrode_scrap` 极片废料 | 后者是**边角料与废片**;新的是**产品**。而且**一个可售、一个可售性问题不同** |
| `anode_sheet` 负极片 | 同上 | 同上,**而且它不可售(R5)** |
| `separator` 隔膜 | —— | 既有六行里没有 |
| `casing` 壳体 | —— | 同上 |
| `structural_parts` 结构件 | `casing` | **R2 把两者并列点名**,而它们的材质与去向不必相同 |
| `electrolyte` 电解液 | —— | 同上;**它同时是一个损耗类别** |

**`implies_dismantling`:** 只有 `de_cased_cell` 为真(壳开了,极片还没分);
其余六个已经是散的了。

## 【没有回填】(brief 3b)

**【码】线上 9 行物料,`form_code` 非空的仍然是 **1** 行**(`ZZ-SMOKE-NTF`)。
**8 行留空,一行都没有猜。**

其中两行是本刀的关键:`MAT-2026-0001`「NMC Cathode Foil」与
`MAT-2026-0002`「Special Battery Material」。
**【Tim 裁定】两者都不设** —— 后者是一个占位符记录,它的形态是一条还没有答案的裁定。

---

# 三 · 可售性(R5)

## 它挂在【形态】上,不挂在物料上

**法律说的是【这个东西物理上是什么】,所以它属于记录"东西物理上是什么"的那张字典。**
说一次,每一种物料继承。理由写在
`db/tables/material_forms.sql` 的 `may_be_sold` 列注上。

**【码】`material_forms.may_be_sold`,`boolean NOT NULL`,【不给默认值】** ——
一个默认放行的取值会让「没有人想过」悄悄变成「可以卖」。**加一个形态必须当场回答。**

**三个 false:** `loose_cells`(电芯)· `de_cased_cell`(已开壳电芯)· `anode_sheet`(负极片)。
**`cathode_sheet` 是 true。**

> ### ★ 业务规则,法条出处待补 ★
> **Tim 陈述这是新加坡法律的要求,但没有给出法条出处。**
> 它以【业务规则-出处待补】的身份落地,而**硬拦是这条不确定性的安全一侧**:
> **将来放松它是改一行数据,将来收紧它是改一条逻辑** ——
> 而在收紧之前发生的每一笔交易都已经做完了。
>
> **它【不】带买方资格层、【不】带审批例外、【不】带豁免申请。**

## 四层入口,四个触发器 —— 逐个点名(brief 4b)

**为什么是触发器而不是改那八个 RPC:** `proc-reality.md` 对 N5 的自我更正写过 ——
**触发器对每一个写入者成立,包括直连 psql**。而「报价能挡、发货挡不住」那种半拦,
**比不拦更糟,因为它制造信心**。

| 层 | 触发器 | 建在 | 覆盖的 RPC | app 入口 |
|---|---|---|---|---|
| ① 报价 | `trg_quote_lines_form_saleable` | `quote_lines(material_id)` | 报价行创建 | `app/sales/quotes/new`、`quotes/actions.ts` |
| ② 订单 | `trg_sales_order_lines_form_saleable` | `sales_order_lines(material_id)` | `create_sales_order` · `amend_sales_order` · `convert_quote` | `app/sales/orders/actions.ts`、`[id]/amend/actions.ts`、`quotes/actions.ts` |
| ③ 占用 | `trg_so_reservations_form_saleable` | `sales_order_reservations(output_batch_id)` | `reserve_stock` | `[id]/ReserveControl.tsx`、`ReservationSection.tsx` |
| ④ 货真的离场 | `trg_sales_records_form_saleable` | `sales_records(output_batch_id)` | **`record_output_sale` 与 `ship_order` 共用** | `app/output/[id]/edit/saleActions.ts`、`[id]/ShippingSection.tsx`、`app/logistics/containers/actions.ts` |

> **④ 之所以一个触发器盖住两条路:【码】`sales_records.output_batch_id` 是 `NOT NULL`** ——
> 货真的离场的每一条商业路径都必须写这张表。

## 三种拒绝,一种都不许长得像另一种(brief 4c)

| 码 | 说的是 | 下一步动作 |
|---|---|---|
| `SALE_FORM_NOT_SALEABLE\|<形态>\|<zh>\|<en>` | **法律不许卖这个形态** | 没有下一步 —— 没有例外路径 |
| `SALE_FORM_NOT_SET\|<批号>` | **这一批是加工产出的而形态没设,所以【判断不了】** | 去把形态设上。**它不是在说这个东西不许卖** |
| `IOD_SALE_EXCEEDS_AVAILABLE` / `SO_RESERVE_EXCEEDS_AVAILABLE` / `OUTPUT_NOT_FOUND` / `OUTPUT_DELETED` | 库存类(**既有,本刀没动**) | 去找货 |

## 逐条【真的触发过】,原文照录

**不是推理出来的,是在线上一个会回滚的事务里逐条触发的**(2026-08-30):

```
① 不可售形态      >>> SALE_FORM_NOT_SALEABLE|anode_sheet|负极片|Anode sheet
② 加工产出、无形态 >>> SALE_FORM_NOT_SET|OUT-2026-0441
③ 正极片对照      >>> 成交,sales_record {"sold": 10, "state": "部分售出",
                       "amount_base": 50.00, "revenue_journal": "JE-2027-0004", …}
④ 普通库存不足    >>> IOD_SALE_EXCEEDS_AVAILABLE|999999|90|0|0
```

**三条拒绝的第一段互不相同**(`SALE_FORM_NOT_SALEABLE` / `SALE_FORM_NOT_SET` /
`IOD_SALE_EXCEEDS_AVAILABLE`),**而 ② 没有说"这个东西不许卖"** —— 它说的是哪一批、
以及判断不了。**③ 证明这不是一个"把所有人都拦住"的实现。**

## 那条刻意的不对称,以及它防的两件不同的事(A2)

**买进来的料、以及这条轴之前就存在的料:形态为空【照旧可售】。**
**加工产出的料:形态为空【拦】。**

* 前者的空 = 「这条轴比这行料还年轻」。**拦掉它等于停掉线上每一笔销售**,
  并且会教操作员随便填一个值去解锁 —— **那会毁掉这条轴本身**。
* 后者的空 = 产线跑起来那天,一个**从来没有人设过形态**的产出批会**悄悄变成可售**,
  而且没有任何信号。**这里的后果是法律上的。**

**两者防的不是同一件事:前者防【停线】,后者防【卖掉一件不许卖的东西】。**
这条与 PROC-3 的 D3 同源(安全状态缺席拦、化学确定度缺席放行),
**理由不同而形状相同,写在 `assert_output_batch_saleable` 的函数体里,不要"修"平它。**

## 线上实测的影响 —— **12 → 1,而这是预期的**

| | 可售批次 |
|---|---|
| **改之前** | **12** |
| **改之后** | **1** |

**被拦的 11 批全部报 `SALE_FORM_NOT_SET`,没有一批报 `SALE_FORM_NOT_SALEABLE`** ——
系统**没有**声称这些料不许卖,它说的是判断不了。

**【Tim 裁定】这 11 批全部是测试数据,是一个被接受的后果,不是回归。**
**产线从来没有跑过,所以线上每一个产出批都是 fixture 残留。**
它们全部挂在两行 **PROC-2 之前**的物料上(`MAT-2026-0001` / `MAT-2026-0002`,
`kind_code` 空、`form_code` 空、`status = draft`)。

> **A2 那条停机判据为什么会响:** 它假定「加工产出的」与「这条轴之前的」是两个
> 不相交的集合。**线上它们是同一个集合** —— 每一个产出批都坐在一行前 PROC-2 的物料上,
> 于是给旧料的豁免一次都没生效。**判据没有写错,它量出了一件真事。**

## ★ 两条实测撞出来的东西 —— 而它们改变了这条规则【实际在保护什么】

**按"定义之达成"的要求把三条拒绝逐条真的触发一遍时,撞出两件事。
两件都不是设计时想得到的,而第二件改变了这条规则的含义。**

### 一 · 【不适用】不是【没设】—— 一个死锁,已修(fu1)

**【码】`guard_material_condition_axes`(PROC-2)对形态有【两条相反】的规矩:**
* 种类**有**状态轴(`battery_material`)→ 形态**必填**;
* 种类**没有**状态轴(`ewaste` / `packaging` / `consumable` / `spare_part`)
  → 形态**必须留空**,`MATERIAL_KIND_HAS_NO_CONDITION_AXES` 拦着不许填。

于是本刀原来那条"形态为空就拒"的判据,对第二类物料**说了一句假话并且锁死了它**:
拒绝说「到物料页把形态设上」,而那个种类**根本不许设** —— 操作员照做会撞上另一条拒绝,
**两条互相指着对方**。

**而它不是假想分支:【码】线上 `ewaste` 就是 `may_ever_be_processed = true` 且
`has_condition_axes = false`** —— 一种**可以加工**、而形态**必须为空**的料。

**已修**(`db/migrations/2026-08-30-procbuild1-fu1-not-applicable-is-not-unset.sql`):
空的**意思**由 `material_kinds.has_condition_axes` 回答 ——
没有状态轴 → 不适用 → **放行**;有状态轴、或**查不到种类** → 没人决定过 → **拒**。
(与 `fixture 115` 的 F5 同一个理由,换了一条轴。fixture 154 的 **F4b** 钉住它。)

### 二 · 这条规则真正保护的是【那八行历史物料】,不是将来

**三条既有约束合起来,今天【造不出】一行"说了种类、却没有形态"的物料:**

| 约束 | 它要求什么 |
|---|---|
| `materials_kind_stated`(CHECK,NOT VALID) | 新行**必须说出种类** |
| `guard_material_condition_axes` · 有状态轴 | 形态**必填** |
| `guard_material_condition_axes` · 无状态轴 | 形态**必须为空**(= 不适用,fu1 放行) |

> **所以 `SALE_FORM_NOT_SET` 唯一到得了的对象,是线上那【八行前 PROC-2 的历史物料】**
> (`kind_code` 空、`form_code` 空)—— Tim 裁定的那 11 批产出批正坐在它们身上。
>
> **这值得照直说,因为它与 A2 给的理由不完全一样。** A2 的担心是
> *「产线跑起来那天,一个从来没有人设过形态的产出批会悄悄变成可售」* ——
> **那件事其实已经被 PROC-2 那个守卫挡住了**:一行新的电池料**不可能**没有形态。
> 这条规则真正兜住的,是**那八行还活着的历史物料**。
>
> **它仍然值得存在**(那 11 批是真的,而且 Tim 已经裁定拦它们是对的),
> **但它不是一道面向将来的闸,它是一道面向历史的闸** —— 而这两者的
> 退役条件完全不同:等那八行物料被分类或退役,这条判据就没有对象了。
> **写下来,免得下一个人以为它在防一件它其实防不到的事。**

**fixture 154 因此必须【特意造出】那个行形**:摘掉 `materials_kind_stated`、
插入那一行、再把约束装回去,全部在会回滚的事务里,并且**断言约束真的装回去了**
—— 否则后面每一臂都跑在一个被削弱的库上。

## 三支 fixture 【不需要改】—— 一条对我自己先前判断的更正

我先前说 `18-allocation-delta-split` / `25-movement-business-date` /
`68-shipment-turns-liability-into-revenue` 会因为本刀的规则而变红,需要各自补一个形态。
**实测:三支都已经把 `form_code` 设成 `black_mass`** —— 而 `black_mass` 非空且可售,
所以新规则碰不到它们。**它们本来就在正确地搭自己的世界,一个字都不用改。**

---

# 四 · M4:记下来,不修(brief STEP 6)

> ### 具名的【将来会成为缺陷】的东西:投料闸的不对称
>
> **【码】`guard_processing_input` 只问进料批,从不问产出批**,而且它自己写着理由:
> *「一个产出批【从来没有到过门口】—— 它是这里做出来的,没有『到货状态』可言。
> 而且它要能存在,喂它的那些进料批必然已经过了这道闸。」*
>
> **今天这条推理是完整的。** 在 Tim 的工艺路线(F2/R2)之下它会破:
> **极片既可以是我们产的,也可以是买进来的** —— 同一个 `materials` 行、同一种物质,
> **买来的那一批过安全状态闸,自产的那一批不过。**
>
> * **触发条件:** 第一次把**自产的**中间物(电芯 / 已开壳电芯 / 极片)重新投进一道工序。
> * **归属:** **接线那一刀**(与 5d 的 `operation_type_id` 同刀)——
>   因为在工序模型存在之前,自产中间物根本没有第二道工序可以进。
> * **本刀【不修】。** 修它需要判断"产出批要不要有到货状态",
>   而那个判断在工序模型落地之前问不出正确答案。

---

# 五 · 权限

| 对象 | 读 | 写 |
|---|---|---|
| `loss_metal_fates` · `loss_categories` | 所有已登录者 | `module.processing.edit` |
| `processing_run_losses` | `module.processing.view` | `module.processing.edit` |
| `material_forms.may_be_sold` | 跟着 `material_forms`(既有) | `module.materials.edit`(既有) |

**字典按加工模块判**(损耗是加工的事);**事实行跟着父单据判**
(与 `assay_result_metals` 同一条:哪个模块能读/写父,哪个就能读/写行)。

---

# 六 · 屏幕

* **损耗分类:`app/processing/[id]` 的「损耗分类」面板** ——
  **就在损耗被记下来的那一页**。分类如果住在别处,它就变成一件"另外要记得做的事",
  而这个仓库对"要记得做"的处置是把它换成机制。
  面板显示 **总量 / 已分类 / 还没解释**,而且**「还没解释」旁边写着它不是过磅误差**。
  `residue_disposal` 那一行带着**「不是损耗」**的标注 —— 那句话在行上,不在脚注里。
* **可售性:`app/materials` 的形态选择格** ——
  选中一个不可售的形态时,当场出现一条红色说明,写明**四条路都会被拒**,
  并且说明**真正拦它的是数据库**(屏幕拦不住第二条路)。

---

# 七 · GAP LIST 怎么动

**`proc-reality.md` 的 G5 关闭了一半:** 损耗**从一个列变成了一组带类型的行**。
**另一半(W2-(iii) 残渣变成一条带负价值的产出)仍然开着** —— 它等 **U6**,
而本刀用 `is_true_loss = false` 把「它还没到家」留在了数据里。

**G7 / G8 / G9 / G13 与 U4 / U5 / U7 一个字都不动。**
**U0/Q1、Q2、Q4 由 Tim 的 R1/R2/R4 答掉了** —— 见本文抬头。

**接长 `proc-reality.md` 的那一刀仍然没有被触发**:
它的触发条件是 `forward-queue.md:1340` 写的「工序模型(G7)落地那一刻」,
而**本刀没有让它落地**。
