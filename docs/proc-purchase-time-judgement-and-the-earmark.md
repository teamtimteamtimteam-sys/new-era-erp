# PROC-1B-iii · 采购时的那个判断,以及客户承诺压过工序指定

> 应用日期 2026-08-31。一支主迁移 + 一支 fu(遮蔽表三件事)。
> **一刀两件事,它们没有逻辑联系** —— 合刀的理由是运维上的(两件都小,而备份是
> 最贵的一步),不是逻辑上的。★ 不要从"它们在同一支迁移里"推出它们有关系。★

---

## 零 · 两条被删掉的前提 —— 任务书自己写错了,改正记在这里

写在最前面,因为下一个读的人会从任务书出发,而任务书这两句话是错的。

### 错 1 ·「今天这个冲突只在发货时才浮出来,太晚了」—— 不成立

实测:`sales_order_reservations` 上挂着 `trg_so_reservations_form_saleable`
(BEFORE INSERT → `guard_batch_form_saleable` → `assert_output_batch_saleable`),
另有三个同胞挂在 `quote_lines` / `sales_order_lines` / `sales_records` 上。
于是【先指定、后预留】这个方向**今天就在预留那一刻按名拒绝**,
抛的是 `SALE_BATCH_EARMARKED`。**发货根本不是它落地的地方。**

### 错 2 ·「镜像用例(先指定、后预留)没有定义」—— 它早就定义了

它不但有定义,而且已经建好、上线、有 fixture 166 钉着。

### 真正的缺口是【单向】的

| 方向 | 本刀之前 | 本刀之后 |
|---|---|---|
| 先**指定** → 后**预留** | **已经拒**(`SALE_BATCH_EARMARKED`) | **一个字没动** |
| 先**预留** → 后**指定** | **悄悄成功** ← 缺口 | 按名拒(`BATCH_PROMISED_TO_CUSTOMER`) |

---

## 一 · 件一:采购时的那个判断(R1 / R2 / R3)

### 取值集合:三值字典 + 可空外键 —— 以及为什么不是 boolean

"能不能深度放电"看着是二值的,而在**路由**那一刻它是三值的,
三个值对应三个**不同的下一步动作**:

| 取值 | 路由到 |
|---|---|
| `can` | **深度放电**(专用设备)→ 人工拆解 → 电芯 → 开壳 → 极片分离 |
| `cannot` | **整电池粉料线**(旁路;它与极片粉料线是两台设备,两道工序) |
| `not_assessed` | **不可路由** —— 没有人看过,而你不许照着一个猜测去路由 |

★★ 而**两种缺席是两件不同的事,不许压成同一个 NULL** ★★

* **列上是 NULL** = 这一行比这条轴还老。**不回填,不拦人。**
* **`not_assessed` 这一行** = 有人打开了表单,**并且没有下判断**。
  那是一个 positive 的、被记下来的事实,它必须存得下。

可空 boolean 装得下三个值,但它把这两者压成同一个 `NULL`。
这个仓库为这件事付过账:`materials.may_be_processed` 就是可空 boolean,
于是"没人裁定过"只好写在散文里(`known-wrong-until-cutover.md` 那两批计价库存)。
**字典让"一个没设的判断永远不许被读成『不能』"成为结构性的,而不是一条要靠人记着的约定。**

字典是 **RUNTIME CONFIG**(`module.materials.edit` 可写),所以加第四个取值
(比如 `can_with_precautions`)真的只是加一行 + 更新镜像,不是一支迁移。

### 为什么没有 `routes_to_operation_type_code` 这一列 —— 这是一个决定

上表那三行路由**写在注释里,不写成列**。理由:**今天没有"下一道工序"这个概念**
(`operation-model-scoping.md` 的 F1:"路线是一棵树……【码】今天说不出口")。
一列没有消费者的东西,会教下一个人"这件事已经在管了" ——
与 `inbound_safety_states` 抬头对"存放要求"的处置逐字同一条。

**唯一有消费者的规则列是 `is_a_claim`**,`grn_discrepancies` 现读它。

### 两个值都活着,谁也不覆盖谁(R2)

| 事实 | 落点 |
|---|---|
| 买的时候判的 | `purchase_order_lines.deep_discharge_judgement_code` |
| 实际到的货 | `inbound_batches.deep_discharge_actual_code` |

★ **R1 的落点理由**:这个判断是在**买的时候**做出的,在货到之前 ——
那一刻**进料批还不存在**。仓库里已有同一个理由的先例:`work_order_lines`
按【物料】排产而不按批次。

### 它【不是】安全状态那条轴 —— 2e 的答复(没有触发"说了就停")

| | 问的是 | 谁读它 |
|---|---|---|
| `inbound_batch_safety_states` | 这批料**现在**放没放电(**状态**) | **起火闸** `guard_processing_input` |
| `deep_discharge_*_code` | 这批料**压根能不能**放电(**能力**) | 路由,**不拦任何东西** |

**不是同一个事实记两遍**,而证据就在 `operation_type_safety_states` 里:
整电池粉料线**受理 `charged_not_discharged` 而【不】解决它** —— 因为它专收
**放不了电**的料。也就是说两件事必须能同时说出口:

* 带电 + **能**放电 → 深度放电线
* 带电 + **放不了**电 → 整电池粉料线

**同一本字典**让采购侧与到货侧可比;**不同的表**让能力轴离起火闸远远的。
把"实际"做成 `inbound_safety_states` 的一行,就是给同一件事造第二种说法。

### 差异走 `grn_discrepancies`,不另起机制(2c)

**扩视图比另起一对列便宜,而且是量过的**:视图的 FROM 里**已经同时握着两侧**
(`pol` 与 `b`)。扩它 = 两个 LEFT JOIN + 三列 + `kinds` 一个分支;
**零新表、零新 RLS、零新权限裁定、零新屏幕**(差异页本来就在渲染 `kinds`)。
另起一套要重新裁一次跨模块属主权限(inbound × purchasing,OPS-14 的 xmodule 陷阱),
外加一个屏幕、一份 i18n —— 严格更贵,而且正是任务书禁止的第二套差异机制。

**一次差异要【两次互相矛盾的主张】。** 任一侧是 NULL,**或**任一侧是 `not_assessed` →
`deep_discharge_contradicted` 是 **NULL**,不是 false,更不是 true。
判据读字典的 `is_a_claim`,**不在视图里写死 `'not_assessed'` 这个字面量**。

★ **而"未评估 vs 不能"与"没设 vs 不能"的布尔一模一样(都是 NULL)** ★
所以分辨力**不在那个布尔上** —— 视图同时露出两侧的原始码
`deep_discharge_judged` / `deep_discharge_actual`:没设是 NULL,
看了没判是字面量 `not_assessed`。屏幕上是两个不同的字。

#### 线上实测(2026-08-31,整段 ROLLBACK,线上零改动)

| 采购侧 | 到货侧 | `contradicted` | `kinds` 点名 |
|---|---|---|---|
| (基线:8 条真实收货,两侧全空) | | **全部 NULL**,0 个假阳性 | 0 |
| `can` | (NULL) | NULL | 否 |
| (NULL) | `cannot` | NULL | 否 |
| `not_assessed` | `cannot` | NULL | 否 |
| `can` | `cannot` | **true** | **是** |
| `can` | `can` | **false** | 否 |

### R3:它不拦收货

`receive_inbound_batch_against_po` **一个字都没为它改过**。fixture 168 钉着:
一张收货,实际与判断**矛盾**,**仍然成功**;而且同一条采购行**再收一次也成功** ——
一次矛盾不许变成后续收货的闸。记下一个"打脸的实际"同样不许被拦:
拦住它只会让操作员回头去改那个**判断**,把证据抹掉,
**而那正是要拿去跟供应商谈的东西**。

---

## 二 · 件二:客户承诺压过工序指定(R4)

### 排序是【有方向的】—— Tim 的裁定,3c 的答复

"客户的承诺压过工序指定"与"要许货给客户,先把工序指定释放掉"是**同一条排序**;
差别只在于**释放这个动作由谁做**,而 Tim 裁定:**由操作员做。**

于是镜像那一侧**原样留着**。三个候选做法里选的是第一个:

| 候选 | 选了吗 | 理由 |
|---|---|---|
| **预留【拒绝】**(现状) | ★ **选它** | 一句响亮的、带一步旁路的拒绝 |
| 预留成功并**清掉指定** | 否 | 系统**悄悄毁掉一项没人同意毁掉的安排** |
| 预留成功、**两者并存** | 否 | 正是"太晚才浮出来"那个缺陷本身 |

### 部分预留:**整批拒** —— 3d 的答复

100kg 的批许出去 40kg → **指定整批被拒**,不在"未预留的 60"上放行。

判据**不是保守,是今天的模型说不出那句话**:`purpose_code` 是
`output_batches` 上的**一个列,作用于整批**。没有部分指定这种东西,
也**没有子批模型**(它被明确挂起了)。"在余量上放行"落到库里只能是把
**整批**翻成非可售 —— 连同已经许给客户的那 40kg;而那 40kg 接着会被
`assert_output_batch_saleable` 拦在**发货**门外。

★★ **一次"部分放行"会把一句守住了的承诺变成一句毁约** ★★ —— 那正是 R4 要防的。

旁路与镜像侧同一条:把预留释放掉(将来子批模型落地了,就是把批拆开),再指定。

### 守卫在【触发器】上,函数只负责把话说得更好听

`output_batches` 有一条敞开的 UPDATE 策略(`module.output.edit`),
一句直插的 `UPDATE ... SET purpose_code` **整个绕开** `set_output_batch_purpose`;
而 CHECK 约束读不了另一张表。镜像那一侧**已经是触发器** ——
把一条规则的两半用两种强度执行,正是它被绕过去的方式。

**`SECURITY DEFINER` 不是装饰。** `sales_order_reservations` 的 SELECT 策略要
`module.sales.view`。一个只有 `module.processing.edit` 的加工员**看不见任何预留行**,
于是一个 INVOKER 的守卫会查到零行、**安静地放行** ——
那会原样重演 PROC-WIRE-1B-ii 刚修掉的缺陷。
**fixture 170 用一个没有 `sales.view` 的用户撞它,那一臂就是这句话的凭据。**

### 按名拒,而且这个名字是新的

`BATCH_PROMISED_TO_CUSTOMER|<批号>|<许出去的量>|<订单号>`

它与 `assert_output_batch_saleable` 那**五条销售拒绝**都不一样:
那五条讲"这一批能不能**卖**";本条讲反方向的一句话:"能不能被**拿去投料**"。
共用一个码,操作员读到的是一句与他正在做的事无关的话。

---

## 三 · 遮蔽表加一列 = 三件事,而主刀又只做了一件(fu1)

**同一个形状,一天之内第二次**(上一次是 `procwire1bi-fu1`)。
两列加上了,但**列级授权与 `_masked` 伴生视图都没做**,实测:

```
has_column_privilege('authenticated','purchase_order_lines',
                     'deep_discharge_judgement_code','SELECT') = false
has_column_privilege('authenticated','inbound_batches',
                     'deep_discharge_actual_code','SELECT') = false
```

**每一个登录用户都读不到这两列**,而且**一个字的报错都不会有**。

★ 这一刀最要命的地方:那个"永远读不到"会显示成"未记录 / 未填写",
  而差异会永远是 NULL —— **与本刀刻意设计的"缺一侧就是 NULL"长得一模一样。**
  缺陷会藏在正确行为的背后。★

**它是被机械检查抓到的,不是被人记住的**:`check-masked-reads` 先拒了直连读取,
改读 `_masked` 之后 **tsc 当场说那张视图上没有这一列**。两道检查接力,
把一条要靠人记着的规矩变成了一次编译失败。

---

## 四 · 入口与权限

| 做什么 | 在哪 | 权限 |
|---|---|---|
| 下**采购时的判断** | 采购单详情页,每条**料**行(设备行没有这条轴) | `module.purchasing.edit` |
| 记**实际到的货** | 进料批编辑页,"这批料能不能深度放电?"一块 | `module.inbound.edit` |
| 看**差异** | 收货差异页 / 采购单详情 / 进料批详情(同一个组件) | `module.purchasing.view` |
| 改**字典** | 直接改表(本刀没有为它做设置页) | `module.materials.edit` |

**进料批页把"买的时候判的"摆在实际值旁边** —— 而采购行躲在
`module.purchasing.view` 后面(OPS-14 的 xmodule)。所以那一块分三句话说:
**没挂采购行** / **你看不到采购侧**(去要权限) / **采购行上没填**。
把前两者印成"未填写",说的就是假话。

---

## 五 · 仍然挂起的(本刀【没有】碰)

* **子批模型** —— 写销分母(÷ quantity)在成本资本化到已部分消耗的批上时会少释放;
  部分预留"在余量上指定"也在等它。已知、继承来的,不是本刀的题。
* **路由本身** —— 没有"下一道工序"这个概念(F1)。本刀记下判断,**不路由**。
  这正是字典里没有 `routes_to_operation_type_code` 一列的理由。
* **五个 RLS 盲函数** —— `bank_book_balance_asof`、`attendance_unpaid_days`、
  `sale_settlement_compute`、`resolve_review_reviewer`,以及 `journal_activity_lines`
  之上那一层。排在开账前的清理里,本刀刻意不动。
* **11 条指向已删 auth 用户的孤儿管理员授权** —— 已报告,未清理。
* **`water_exposed` 没有任何工序受理它** —— Tim 还没裁定进过水的料怎么处理。
* **tolling(TOLL-0)**、`index_market_calendar` 为空、10 条来源为 `unknown`
  的金属行情、`company_compliance` 为空、`waste_classifications.is_controlled`
  零消费者 —— 均维持原状。
