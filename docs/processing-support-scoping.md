# 加工支撑四件普查(PROC-SUPPORT-0)—— 勘察,不建任何东西

**本次会话【不实现任何东西】。唯一允许的写入是这份文件。**
不动库、不动代码、不建 fixture、不排迁移、不做备份、不开窗口。

## 标记,沿用 `docs/operation-model-scoping.md` 与 `docs/proc-reality.md` 的那一套

| 标记 | 意思 |
|---|---|
| **【码】** | 从仓库或线上读出来的事实,带对象名 |
| **【Tim】** | Tim 自己的话 —— 唯一的权威 |
| **(A)** | **现在就能建,而且不管产线最后怎么跑都是对的** |
| **(B)** | **现在就能建,但没人被要求填它就会永远空着** —— 必须点名【谁】【什么时刻】【什么强迫他】 |
| **(C)** | **产线真的跑起来之前答不了** |

> **产线没有开。零真实炉次、零化验、零实测收率。**【码】线上 14 张加工单
> (10 张未软删)全部是测试残留。一个照着想象出来的运营拟合出来的模型,
> 是这个仓库记过账的那一种失败。**"现在少建一点"是一个被允许的结论。**

---

# 零 · 这份 brief 本身就是问题的一部分 —— **先读这一节**

## 0.1 第【五】次:brief 点名要建的东西,已经建好了

**这是连续第五次,一份 brief 要求建造仓库里已经存在的东西。** 前四次是
质量暂扣、牌照登记簿、在制品、运费成本载体。本刀是第五次,而且一次命中三件。

| # | brief 要的 | 【码】已经存在的对象 | 由哪一刀建的 |
|---|---|---|---|
| ① | 预期产出比例 | `work_order_expected_outputs` | **WO-1a** |
| ② | 副产品产出 | `loss_categories`(`metal_fate` / `is_true_loss`)+ `processing_run_losses` | **PROC-BUILD-1** |
| ③ | 成本中心 | `processing_runs.equipment_id` **与** `processing_runs.operation_type_code` —— **两个,不是一个** | **EQP-2a** / **PROC-WIRE-1B-i** |
| ④ | 交接班 | 交接班本身**没有**;但它六项内容里的两项已存在/已排队 —— `equipment_downtime`(设备状态)、WSH 事故登记簿(已排队) | **EQP-2a** / `forward-queue.md:1198` |

**【Tim】"记下这个次数;这是关于这些 brief 怎么被写出来的一个规律,不是巧合。"**

规律是什么,照直说:**brief 是照着"一个 ERP 应该有什么"写的,不是照着
"这个仓库里已经有什么"写的。** 四件里三件的名字与仓库里的名字不一样
(「预期产出比例」vs `work_order_expected_outputs`;「成本中心」vs
`operation_type_code`),于是按名字搜索搜不到,而按**问题**搜索搜得到。
**下一份 brief 的第一步应当是:把每一件事翻译成"它要回答哪个问题",
再去问仓库那个问题已经被谁回答了。**

## 0.2 三件已经有【写下来的裁定】,而 brief 与其中一条正面冲突

| brief 的要求 | 仓库里已有的裁定 | 出处 |
|---|---|---|
| 预设值可以从行业经验播种 | **"一个在有数据之前发明出来的标准是虚构"** —— 说了三遍 | `forward-queue.md:117`、`:1355`、`:1563` |
| 副产品成本 | 它**就是 G10**「处置流(成本而非产品)」,阻塞在 **U6** | `proc-reality.md:605` |
| 负价值产出 | 它**就是 W2-(iii)**「残渣变成一条带负价值的产出」,阻塞在 **U6** | `proc-loss-and-saleability.md:395` |
| 交接班 | 阶段 7,无 G 号,**"真的开两班时才有内容可记"** | `forward-queue.md:1358` |

第一条的冲突已在盘问里解掉,解法见 §2.1 —— **仓库禁的是【标准】,
不是【带出处的估计】**,而 Tim 要的是后者。**两者不冲突,冲突的是措辞。**

## 0.3 这是一个【捆】,不是一刀 —— **捆本身就是那个毛病**

**【Tim】"这是一个捆,不是一刀。"** 证据:

| 件 | 它属于哪一族 | 它在等什么 | 谁能解开 |
|---|---|---|---|
| ① 预期产出 | 工单族(WO-1a/1b/1c) | 真实炉次(校准),**但播种不等** | 产线 |
| ② 副产品 | 损耗/产出族(G10) | **U6 ← 工艺流程图定稿** | **Tim** |
| ③ 成本中心 | 加工单族(EQP-2a / PROC-WIRE-1B-i) | **什么都不等** | 无 |
| ④ 交接班 | 人事/车间族(全新) | 车间人员存在 | 招聘 |

**四件、四个互不相干的阻塞项、三个不同的主人,共享的只有一个队列位置。**

> **给下一个读这份文件的人:不要把它们重新捆起来。**
> 捆在一起的唯一后果,是让 ③(什么都不等、最小、最有杠杆)被 ②(等一张
> 还没画完的图)拖住。**这正是本次普查最该产出的那一句话。**

---

# 一 · STEP 1 · 盘问改了什么

盘问按名调用 `mattpocock-skills:grilling`,一轮五问,Tim 全部接受。

## 1.1 被删掉的假前提(四条)

| # | brief 里的假前提 | 【码】实测 |
|---|---|---|
| F1 | 「加一张预期产出/配方表」 | `work_order_expected_outputs` 已存在,**而且它自己的表注释已经规定了标准该怎么来**:「新列 basis/source,或另一张表,**不覆盖这一张**」 |
| F2 | 「成本中心是一个缺失的维度」 | 维度存在**两个**,而且**都是 0/10 填充率** —— 缺的不是维度,是**填它的强制力** |
| F3 | 「副产品成本可以现在设计」 | 它是 G10,阻塞链 G10 → U6 → 工艺流程图,**Tim 确认图没定稿** |
| F4 | 「交接班要记设备状态与事故」 | 两者都已有/已排队的载体;交接班**引用**它们,再记一遍就是两份会打架的记录 |

## 1.2 盘问改变的结论

**最有价值的一条是 ③ 的重构。**「加一个成本中心」是错的指令:
维度已经存在两次,一个第三维度是**同一个问题的第二个答案**,而且会因为
同样的理由空着。③ 因此从**加维度**变成**让已有的那一维被强制填上**。

**【Tim】"『加一个成本中心』是错的指令。"** 已接受。

---

# 二 · STEP 2 · 逐件测量(对象名 + 线上计数)

## 2.0 本次用到的线上计数,一张表

| 对象 | 计数 | 说明 |
|---|---|---|
| `processing_runs`(全部) | **14** | 含 4 张已软删 |
| `processing_runs`(未软删) | **10** | 全部 `status='committed'` |
| ├ `operation_type_code IS NOT NULL` | **0** | **0%** |
| ├ `equipment_id IS NOT NULL` | **0** | **0%** |
| └ `work_order_id IS NOT NULL` | **1** | 10% |
| `processing_outputs` | **17** | 一单最多 **2** 条产出腿 |
| `processing_cost_entries`(未软删) | **10** | `electricity` 6 笔 /1303.45,`labour` 4 笔 /900 |
| └ `amount_base < 0` | **0** | 允许为负,**从未用过** |
| `batch_processing_cost_allocations` | **1** | |
| `output_batches` | **20** | |
| `work_orders` | **1** | |
| `work_order_lines`(计划投料) | **2** | |
| `work_order_expected_outputs` | **1** | |
| `operation_types`(启用) | **5** | 字典**完整** |
| `material_forms` | **13** | |
| `materials`(未软删) | **5** | 其中有 `form_code` 的 **1**,有 `chemistry` 的 **2**(全 9 行口径) |
| `fixed_assets` | **2** | **两台都是深度放电机**,`in_service_date` 均为 NULL |
| `equipment_downtime` | **1** | |
| `loss_categories` / `processing_run_losses` | **4** / **0** | 字典建好,一行实绩都没有 |
| `assay_results` | **4** | |
| `employees`(未软删) | **6** | 2 真(财务/CFO)+ 4 张 ZZ 刮擦行 |
| └ `work_category='shopfloor'` | **0** | **车间人员为零** |
| `output_batch_safety_states` | **0** | 已知,缺失即阻断 |
| `public` schema 里 `time` 类型的列 | **0** | **全库没有任何时刻维度** |

> **一处与仓库文档的出入,照直记:** `docs/proc-operations-wired.md` 与
> brief 都说「13 张加工单没有工序」。**实测今天是 14 张(10 张未软删)。**
> 差的那一张是那份文档写完之后新增的。**不改那份文档**(本刀只写一份文件),
> 但下一个引用「13」这个数的人应当重新数一遍 —— **一个写下来的数必须是一个量过的数**。

---

## 2.1 ① 预期产出比例

### 2.1a 今天有没有东西记录"预期产出"?**有。**

【码】`db/tables/work_order_expected_outputs.sql`(WO-1a 建):

```sql
CREATE TABLE public.work_order_expected_outputs (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    work_order_id uuid NOT NULL REFERENCES public.work_orders (id) ON DELETE RESTRICT,
    material_id   uuid NOT NULL REFERENCES public.materials (id),
    expected_qty  numeric NOT NULL CHECK (expected_qty > 0),
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT work_order_expected_one_per_material UNIQUE (work_order_id, material_id)
);
```

**而它的表注释已经把本刀要做的决定做完了**,一字不改地引用:

> 【将来有了 BOM 怎么办】它作为【另一个带标签的来源】进来(新列 basis/source,
> 或另一张表),【不覆盖这一张】。覆盖会把"人估的"与"标准算的"混成一个数,
> 而那两个数错的时候要找的人不是同一个。

**这就是 Tim 要的"播种的猜测 vs 校准过的数字"那条分界,已经被写下来了。**
本刀要做的不是发明它,是**兑现它**。

### 2.1b 比例该键到什么上?

Tim 的要求:**比例是【逐投料种类】的,不是一套全局数字。**

【码】这个要求**已经被满足**,但要走两跳,所以必须说出来而不是默认它成立:

```
work_order_expected_outputs.work_order_id
  → work_orders
  → work_order_lines.material_id          ← 【计划投料】,表注释:"WO-1a:计划投料。按物料,不按批次"
  → materials.form_code / materials.chemistry
```

`work_order_lines` 就是**这张工单吃什么**。所以一张工单的预期产出
**天然是"这一种投料的预期产出"** —— 每张工单一套数字,而不是一套全局数字。
**Tim 的"per input kind"要求因此是被结构满足的,不是被放弃的。**

> **但要说出它今天有多虚:**【码】`materials` 未软删 5 行里 **只有 1 行有
> `form_code`**,全 9 行里 **只有 2 行有 `chemistry`**(一行 NMC、一行 LFP)。
> 也就是说:**"投料种类"这个概念的两个承载列,今天几乎全是空的。**
> 这不挡住 ① 的建造(键在 `material_id` 上,那是 NOT NULL 的),
> 但它意味着**按 NMC/LFP 分组去比较收率,今天分不出组**。记为一条 (B)。

### 2.1c 有没有可抄的"出处/置信度"先例?**有三条,而且它们不一样。**

| 先例 | 对象 | 形状 | 可不可抄 |
|---|---|---|---|
| **`metal_prices.source`** | `db/tables/metal_prices.sql:25` | `text NOT NULL CHECK (source IN ('published_index','broker_quote','internal_estimate','unknown'))`,**没有默认值** + `source_reference` 自由文本作凭据 | **★ 最贴的一条** |
| `inbound_batch_metals.content_source` | `db/tables/inbound_batch_metals.sql:35` | `CHECK (content_source IN ('assay','manual'))` + `source_assay_id` + **`NOT VALID` 约束让新行必填、老行放过** | **★ 迁移形状抄这一条** |
| `batch_processing_cost_allocations.basis_qty` | 该表 | 记下**算这个数用的分母**,让分摊可被重新导出而不是被相信 | 概念相通,形状不同 |

`metal_prices.source` 的列注释把理由说得最清楚,值得照抄进新列的注释里:

> 四取一,没有默认值 —— 漏填就是一次失败,而不是悄悄补上一个看起来像答案的值。
> `internal_estimate`=我们自己的估计(它不是市场价,**把它当市场价正是本列要防的事**)

**"把内部估计当市场价"与"把播种的猜测当校准过的收率"是同一个毛病。**

---

## 2.2 ② 副产品产出

### 2.2a `allocate_processing_costs` 今天怎么摊?**每条产出腿一视同仁。**

【码】`db/functions/allocate_processing_costs.sql:417-462`,核心是一句 CTE:

```sql
SELECT po.id AS leg_id, po.output_batch_id, po.quantity_produced,
       CASE WHEN v_basis = 'weight' THEN po.quantity_produced::numeric
            ELSE COALESCE((
                SELECT SUM(po.quantity_produced * obm.content_pct / 100.0 / 1000.0
                           * COALESCE(pr.price_usd_per_tonne, 0))
                FROM output_batch_metals obm ...
            ), 0)
       END AS basis_value
FROM processing_outputs po WHERE po.run_id = p_run_id
...
round(v_total * basis_value / NULLIF(v_total_basis, 0), 2) AS alloc_raw
```

**没有任何一列说"这条腿是副产品"。** 分摊只认两个基准
(`processing_runs.allocation_basis IN ('weight','metal_value')`,FIN-36 建),
**而基准是【整单】一个,不是【逐腿】一个**。

### 2.2b worked example —— 线上真单 `PROC-2026-0164`

【码】这是线上产出腿最多、且成本已摊的一单(2 条腿):

| | 产出批 | 物料 | 量 (kg) | `allocated_cost_base` | `unit_cost_base` | 份额 |
|---|---|---|---|---|---|---|
| 主 | OUT-2026-0186 | NMC Cathode Foil | 200 | 809.14 | **4.0457** | 85.71% |
| 次 | OUT-2026-0187 | Special Battery Material | 60 | 134.86 | 2.2477 | 14.29% |

`material_cost_base` 444.00 + `process_cost_base` 500.00 = **`total_cost_base` 944.00**,
`allocation_basis = 'metal_value'`。

**把 OUT-2026-0187 当成副产品处理,主产品单位成本会变成什么:**

| 处理方式 | 主产品吸收 | 主产品单位成本 | 相对今天 |
|---|---|---|---|
| **(a) 今天:一视同仁** | 809.14 | **4.0457** | — |
| **(b) 按可变现净值贷记**(设 0.50/kg × 60 = 30.00) | 944 − 30 = 914 | **4.5700** | **+12.9%** |
| **(c) 副产品计零值** | 944 − 0 = 944 | **4.7200** | **+16.7%** |
| **(d) 负价值(设处置 1.00/kg × 60 = −60)** | 944 + 60 = 1004 | **5.0200** | **+24.1%** |

**(a) 与 (d) 之间差 24.1%,在一张真的线上单据上。** 这不是一个理论差异。

### 2.2c 现有形状**能**表达 (c),**不能**表达 (b) 和 (d) —— **本节是给后来人的**

**能表达的:(c) 零值副产品 —— 但它是【意外】,不是【声明】。**
在 `metal_value` 基准下,一条没有 `output_batch_metals` 行的产出腿
`basis_value = 0` → `alloc_raw = 0` → `unit_cost_base = 0`,余数由
`rn = 1`(最大份额那一腿)吸收。**壳体、结构件、隔膜正是没有金属含量的那些东西。**

> **但这【不能】被当成"副产品支持"**,三个理由:
> 1. 它不是**声明**出来的,是"这批货碰巧没登记金属含量"的副作用 ——
>    与 `content_source` 那条"出处是记录的,绝不推断"正相反;
> 2. 它是**整单基准**的函数:同一批壳体在 `weight` 基准下会拿到**足额按重量份额**;
> 3. 「没登记金属含量」与「确实不含金属」是两件事,而这里把它们折叠了 ——
>    **正是 `output_batch_safety_states` 零行那条"缺失即阻断"要防的同一种折叠。**

**不能表达的:(b) 与 (d),而 (d) 是硬墙。**

> ★ **给将来建 G10 的人的那一句话:现有形状【不可能】表达一条负价值产出,
> 因为 `basis_value` 要么是 `quantity_produced`,要么是"含量 × 单价"的和 ——
> 【两者都不可能小于零】。所以那一次建造需要【新结构】,不是新数据行。** ★

补一句免得被误读:`processing_cost_entries.amount_base` 与
`batch_processing_cost_allocations.amount_base` **都刻意允许负数**
(源表注释原话:"Deliberately no sign check: by-product / disposal offsets may be
negative"),【码】线上 **0 笔负数**。但那是**成本池那一侧**的负数:
它把**整个池子**变小,再按份额摊给**所有**腿。
**它无法把一笔处置成本归到【那一条】产出腿上** —— 而那正是副产品要的。
**"能记一笔负数"与"能表达一条负价值产出"是两件事。**

### 2.2d ② 的真实阻塞链

```
② 副产品/处置产出  =  G10「处置流(成本而非产品)」   proc-reality.md:605
                          ↓ 阻塞于
                     U6「哪几条产出流存在,其中哪几条是【处置成本】」  proc-reality.md:585
                          ↓ 阻塞于
                     ★ 工艺流程图定稿 ★     ← 【Tim 确认:没有定稿】
```

**触发条件写成"工艺流程图定稿",而不是"产线跑起来"** —— 因为
**那是一件 Tim 控制的东西,不是一件产线产出的东西**。这个区别决定了谁被催。

同一条链上还挂着 **W2-(iii)**(`proc-loss-and-saleability.md:395`):
残渣要从"一种损耗"变成"一条带负价值的产出"。**在那之前
`loss_categories.is_true_loss = false` 让"它还没到家"留在数据里** —— 那是
PROC-BUILD-1 已经做对的一半,不要动它。

---

## 2.3 ③ 成本中心 → **让 `operation_type_code` 在提交时必填**

### 2.3a 一条加工成本条目今天有哪些维度?**逐一点名。**

【码】`db/tables/processing_cost_entries.sql`:

| 列 | 是什么维度 |
|---|---|
| `cost_type` | **花在什么科目上**(`labour`/`electricity`/`gas`/`depreciation`/`consumables`/`waste_treatment`/`other`)|
| `run_id` | **属于哪一炉** → 由此**继承**加工单上的一切维度 |
| `amount_base` / `is_estimate` / `remitted_at` / `relieved_at` | 金额与结算状态,不是分析维度 |

**"花在哪里"不在这张表上,它在 `processing_runs` 上**,而那里有两列:

| 列 | 建于 | 语义 |
|---|---|---|
| `processing_runs.equipment_id` | **EQP-2a** | 这一炉是**哪台机器**跑的 |
| `processing_runs.operation_type_code` | **PROC-WIRE-1B-i** | 这一炉跑的是**哪一道工序** |

### 2.3b 「电极粉料线每吨成本」今天答得出来吗?**结构上答得出,数据上答不出。**

查询本身是现成的,两跳:

```sql
SELECT r.operation_type_code,
       SUM(ce.amount_base) / NULLIF(SUM(r.total_input), 0) AS cost_per_kg
FROM processing_cost_entries ce
JOIN processing_runs r ON r.id = ce.run_id
WHERE ce.deleted_at IS NULL AND r.deleted_at IS NULL AND r.status = 'committed'
GROUP BY 1;
```

**【码】它今天返回一行,`operation_type_code = NULL`,因为 10/10 张单都是 NULL。**

> ★ **所以一个新的 `cost_centres` 维度是【同一个问题的第二个答案】,
> 而且它会因为完全相同的理由空着。不要建它。** ★
> 佐证不是猜的:`inbound_movements` 的 `location` **105/106 未指定**,
> `arrival_date` **58.7% 的价值上缺失**。**一个没人被要求填的维度会一直空着** ——
> 而 `equipment_id`(0/10)与 `operation_type_code`(0/10)**已经是这个病的第三、第四例**。

### 2.3c 强制力放在哪里 —— **今天:哪儿都没有**

【码】`docs/proc-operations-wired.md:138-150`,原文:

> `processing_runs.operation_type_code` **可空**。
> * **界面必填**(下拉,不预选);
> * **数据库不拦。**
> 一条 `NOT NULL` 会把线上 13 张历史单**就地冻住**,而它们是测试残留 ——
> **绝不给它们猜一个工序**。
> 一条 `NOT VALID` 的 `CHECK` 可以只管新行,但那要一次裁定:
> "**从今天起加工单必须说出工序**"。**那是产线跑起来那天的事。** 记为具名缺口。

【码】函数签名确认了这一点 —— `db/functions/commit_processing_run.sql:1`:

```sql
CREATE OR REPLACE FUNCTION public.commit_processing_run(
    ..., p_equipment_id uuid DEFAULT NULL::uuid, p_operation_type_code text DEFAULT NULL::text)
```

且函数体里整个工序分支被一个 `IF` 包着(`:54`),函数头自己写着:

> 【没有工序类型 → `v_consumes` / `v_produces` 都是 true,今天的行为一个字不变。】

**★ 本刀提出把那次裁定【提前到现在】,理由与那份文档给的理由不冲突,而是更强:★**
那份文档说"那是产线跑起来那天的事"。**但在产线跑起来【之后】立规矩,
意味着第一批真实炉次正是没被规矩管住的那些。**【码】今天真实炉次为 **0**,
界面**已经必填**,所以**现在立规矩的迁移成本是零,而晚立的成本是不可回收的**。
**强制力应当先于流量到场,不是随流量到场。**

### 2.3d 必填之后,**什么变得不再被允许**(线上实测)

不是"多一个必填框"这么简单。【码】今天 `operation_type_code IS NULL` 会
**一次性绕过四道已经建好的闸**:

| 闸 | 位置 | NULL 时的行为 |
|---|---|---|
| 产出有无由工序说了算 | `commit_processing_run.sql:129-138` | `v_produces` 默认 true → **一张"放电还产出了黑粉"的单悄悄成立** |
| 状态改变型损耗必须为零 | `:230-236` | 跳过 → 一张放电单可以记一笔损耗,**报告它把碰过的东西全毁了** |
| 逐工序安全状态受理(起火闸) | `:306`、`:356` | 跳过 → 未放电电池可以被喂进任何一道工序 |
| 工序必须启用且存在 | `:58-62` | 跳过 |

> **这才是 ③ 真正的价值,而它不是会计上的:** 一个空的
> `operation_type_code` 不只是"少一个分析维度",**它是四道安全与守恒闸门的总开关**。
> 「成本中心」这个名字把这件事的重要性说小了。

### 2.3e 那 14 张历史单怎么办?**不回填,而且这是对的。**

**【Tim】"那 13 张既有加工单是测试残留,不许用一个猜出来的工序回填。"**

做法:**`NOT VALID` 的 `CHECK`,或者(更好)把守卫放在
`commit_processing_run` 里**,只管**新提交**的单。抄的是
`inbound_batch_metals_content_source_required` 那条 `NOT VALID` 约束
(FIN-32 形状),它的注释已经把理由写好:「新行必填、老行放过」。

**为什么留着是对的,三条:**
1. 猜出来的工序**与真的工序长得一模一样**,而它会流进设备用量、回收率、工单实绩
   —— `proc-operations-wired.md` 的原话;
2. `NULL` 在这里是一个**具名类别**(未归属),不是零 —— 与
   `processing_runs.equipment_id` 的列注释同一条:「空是一个具名类别(未归属),不是零」;
3. 回填会让 §2.3d 那四道闸**对这些单看起来生效过**,而它们从未生效过。

**代价要说出来:** 那 10 张(未软删)会**永远**落在
`operation_type_code IS NULL` 这一组里。任何按工序分组的报表都必须把它显示成
**【未归属】**,而不是丢掉或归零。**这与 EQP-2c 已经做过的
`unattributed_runs_in_window` 一列是同一条,可以直接抄。**

### 2.3f **`equipment_id` 该不该同样处理?—— 不该。两边都论证。**

**支持对称(要求它):** 成本要落到"电极粉料线**这台机器**"上,机器才是折旧与
保养的主体;`equipment_id` 与 `operation_type_code` 空得一样厉害(都 0/10)。

**反对对称(不要求它),而这一边赢,靠的是一条实测:**

【码】线上 `fixed_assets` **只有 2 行,而且两行都是深度放电机**:

| code | description | acquisition_date | in_service_date |
|---|---|---|---|
| FA-2026-0001 | Bosch Deep Discharging Machine | 2026-08-21 | **NULL** |
| FA-2026-0002 | Mobile Discharging Solution | 2026-08-25 | **NULL** |

于是**"一台机器一道工序"这个假设,在线上是假的,两个方向都假**:

* `deep_discharge` ↔ **两台**机器 → **工序推不出机器**,所以
  `equipment_id` **不可派生**,不能"顺手带出来";
* 另外**四道**工序(`manual_disassembly`、`electrode_line`、
  `electrode_powder_line`、`battery_powder_line`)**一台登记的机器都没有**
  → 一旦 `equipment_id` 必填,**这四道工序的加工单一张都提交不了**。

**结论:`operation_type_code` 可以必填,因为它的字典【完整】(5 道工序全部已播种);
`equipment_id` 不可以,因为它的字典【残缺】(5 道工序里 4 道无资产可指)。**
**这不是一次对称性判断,是一次字典完整性判断。** 两台机器
`in_service_date` 均为 NULL(未投用),也印证现在要求它为时过早。

`equipment_id` 的强制力应当排在**资产登记补齐之后**,并记为一条独立的 (B)。

### 2.3g 必填之后,「电极粉料线每吨成本」答得出来了吗?**答得出,但只对新单,且有两个洞。**

**答得出的部分:** §2.3b 那个查询,对 `operation_type_code` 非空的单**直接可用**,
不需要任何新表、新列、新视图。

**仍然缺的两样,照直说:**

1. **【分母】** 上面那个查询用 `r.total_input` 当吨数。**那是【投料】吨数,
   不是【产出】吨数**,而"每吨成本"问的是哪一个,是一次未裁定的口径选择。
   `processing_runs` 同时有 `total_input` 与 `total_output`,**两个都在,没人选过**。
   → **一条 (B),需要 Tim 裁定,不需要建任何东西。**
2. **【共用成本】** 一笔电费如果同时供两道工序,今天它必须挂在**某一张**加工单上,
   于是它整笔落进那一道工序。**跨工序共用成本没有载体** —— 但这个问题
   **今天不存在**(产线没开、没有共用),**而且发明一个分摊规则正是本仓库
   记过账的那种失败**。→ **一条 (C),记下来,不建。**

---

## 2.4 ④ 交接班

### 2.4a 今天有没有任何东西记录"班次"?**没有,而且比"没有"更彻底。**

| 找什么 | 【码】结果 |
|---|---|
| 名字带 shift 的表/列 | **0**(全库唯一一处 "shift" 是 `leave_requests` 注释里提到"六天工作制或轮班"这一种例外情形) |
| `public` schema 里 `time`/`timetz` 类型的列 | **0 —— 全库没有任何时刻维度** |
| 加工族的世界侧时间 | **只有 `processing_runs.process_date`,一个 `date`** |
| 考勤的时间粒度 | `attendance_periods` = **每月一行**;`attendance_lines` = **每人每月一行** + 三列加班工时。**没有日期,更没有时刻** |
| `work_category='shopfloor'` 的员工 | **0**(6 人全是 `office`:2 真 + 4 张 ZZ 刮擦行) |

> **这条实测早就被记过一次,而且它当时被用来做了一个决定:**
> `forward-queue.md:124` ——「加工这一族里没有任何开始/结束/班次/工时列
> (实测:唯一的世界侧日期是 `process_date`,一个 date)。**所以 EQP-2b 的保养
> 间隔按公斤走。这是一个测量结果,不是一次选择。**」
> **同一条实测,这一次决定的是:交接班记录建得起来,但它【连不到加工单】。**

### 2.4b 那么第一天的交接班记录里会有什么?**照直说。**

Tim 列了六项确定内容。逐项对账:

| # | 内容 | 能不能建 | 【码】第一天会是什么 |
|---|---|---|---|
| 1 | 哪个班、几点到几点 | **能** | 新建 `shifts` 字典(早/晚 + 起止**时刻**)。**这会是全库第一个 `time` 列。** |
| 2 | 谁交给谁 | **能** | 外键指向 `employees`。**今天可选的人:0 个 shopfloor 员工。** |
| 3 | 处理了什么、多少 | **能建,但接不上** | ★ **加工单只有 `date`,没有时刻** → **一张加工单归不到某一个班次上** ★ |
| 4 | 设备状态(运行/停机及原因) | **不建 —— 引用** | `equipment_downtime`(EQP-2a):一行一段,`ended_at` 可空表示"还没结束" |
| 5 | 未完成工作(料还在机器里、批次喂了一半) | **能** | **这一项没有任何现成载体**,是本件里唯一全新的实质内容 |
| 6 | 事故 | **不建 —— 引用** | 指向 WSH 事故与未遂事件登记簿(**尚未建**,已排队) |
| 7 | 接班人签收 | **能** | `acknowledged_at` / `acknowledged_by`,抄 `attendance_lines.recorded_at` 那条"没记 vs 记了是零"的形状 |

> ★ **第 3 项是这一件的硬伤,必须写在最前面而不是脚注里:**
> **交接班要说"这个班处理了什么",而系统无法判断一张加工单属于哪个班,
> 因为 `process_date` 是一个 `date`。** 三条出路,evidence 不足以定案:
>
> * **(i)** 给 `processing_runs` 加 `shift_id` —— 由**提交的人**选。诚实,但**又多一个没人被要求填的维度**(见 §2.3b 的病历)。
> * **(ii)** 给 `processing_runs` 加开始/结束 `timestamptz`,班次由时刻**推导**。最干净,但**改的是加工单**,超出交接班这一刀的范围,而且它就是排在阶段 7 的 **G8「一炉的时长 / 跨班次」**。
> * **(iii)** 交接班上**自己手写**"处理了什么"(自由文本 + 数量)。**不与加工单对账**,于是两个数会打架 —— 而这正是 §2.4c 第 4/6 项要避免的那种打架。
>
> **推荐 (ii),但它是 G8,不是本刀。** 也就是说:**④ 的第 3 项内容
> 真正阻塞在 G8 上**,而 G8 排在阶段 7。**在 G8 之前建交接班,
> 第 3 项只能是 (iii),而 (iii) 已知会产生分歧数据。**

### 2.4c 内容必须是【数据】不是【代码】 —— 形状

**【Tim】"第七个交接班字段将来必须是一行,不是一次改代码。"**

仓库里已经有**同形的现成先例**,直接抄,不发明:

* `operation_type_input_forms` / `_output_forms` / `operation_type_safety_states`
  —— **同一个 N×M 形状被用了三次**,`operation_types` 的表注释明令:
  「不许把"受理的形态"与"受理的安全状态"做成两种不一致的形状」;
* `output_batch_purposes.is_saleable_stock`、`operation_kinds.consumes_input/produces_outputs`
  —— **规则列**:行为由**数据**回答,不由写死的字符串回答。

→ 形状建议:`handover_item_types`(字典,RUNTIME CONFIG,带规则列如
`is_required` / `requires_acknowledgement`)+ `shift_handover_items`(逐条内容)。
**加第七项 = 字典里加一行。**

### 2.4d NEA 义务今天由谁承载?**没有人。而它【不该】落在交接班上。**

【码】全仓搜索"两个工作日 / two working days / WSH / 事故报告":

| 命中 | 是不是这个义务 |
|---|---|
| `kpi_position_templates` 两行、`kpi-framework.md` 两行(红色问题 2 个工作日内上报、开票 2 个工作日) | **不是** —— KPI 措辞的巧合 |
| `docs/index-pricing-spec.md:177` 「3 个工作日内出最终结算单」 | **不是** —— 计价条款 |
| `company_compliance`(**0 行**,空是事实) | 装**牌照**,不装**事故** |
| `forward-queue.md:1198` 「第一个技师上岗 → **WSH 事故与未遂事件登记簿**」 | **★ 就是它,而且已经排队了,触发条件已具名 ★** |

**结论:立即通报 + 两个工作日内书面报告这项义务,今天由【任何东西都没有】承载,
它应当落在那本已排队的 WSH 登记簿上。**

> ★ **给后来人的一句话,请不要图省事:**
> **交接班【指向】一次事故,不【复述】一次事故。**
> 一次事件两份记录,迟早会不一致,而**人们读到的那一份会是错的那一份**。
> 法定时限(立即通报 / 两个工作日内书面报告)只能有**一个**载体,
> 那就是 WSH 登记簿。**不要因为"交接班里填一下更方便"就把它抄过去。**
> 同样的论证,`forward-queue.md` 已经对保险用过一次:
> 「保险【就是一种证书】,不是第二套到期机制」。

**还有一条要说出来:** WSH 登记簿的触发条件是「**第一个技师上岗**」,
而交接班的前提也是有车间人员。**两者同时解锁。**
所以 ④ 建的时候,那本登记簿**还不存在** → 第 6 项只能先记为一个
**具名缺口**(留一列指向一张还不存在的表 = "忘了填",EQP-2a 已经拒绝过这种做法:
「与保养记录的那条外键刻意留给 EQP-2b —— 留一个指向不存在的表的空列,
读起来像'忘了填'」)。**照抄那条:第 6 项现在【不留列】,等登记簿建好再加。**

---

# 三 · STEP 3 · (A)/(B)/(C) 逐件拆分,推理写出来

## 3.1 ① 预期产出比例

| 部分 | 类 | 推理 |
|---|---|---|
| `basis`/`source` 列(`planner_estimate`/`seeded_industry`/`calibrated`) | **(A)** | 三个值的**含义**不取决于产线怎么跑。表自己的注释已经规定了这个形状。抄 `metal_prices.source`:NOT NULL、无默认。 |
| 播种一组行业经验预设值 | **(A)**,**但只在 `seeded_industry` 标签下** | Tim 已接受它是低置信占位符。**带着标签它就不是"发明一个标准"**,所以与仓库那三条裁定不冲突。 |
| 让 `calibrated` 真的出现 | **(C)** | 需要真实炉次。**0 张。** |
| 按 NMC/LFP 分组比较收率 | **(B)** | 见下 |

**(B) 的点名:** `materials.form_code` 5 行里填了 **1**、`chemistry` 9 行里填了 **2**。
* **谁填:** 建立物料主数据的人(今天是 Tim)。
* **什么时刻:** **新增一个物料的那一刻**,不是事后补。
* **什么强迫他:** 今天**没有东西**。`materials.form_code` 与 `chemistry` 都可空。
  → **如果不给它强制力,按投料种类比较收率将永远做不到。**
  最小的强制力:新物料**必填 `form_code`**(`NOT VALID` 形状,老行放过)。
  **这一条不在本刀范围内,但必须写下来,否则 ① 建完仍然分不出组。**

## 3.2 ② 副产品产出

| 部分 | 类 |
|---|---|
| 全部 | **(C)** |

**推理:** 哪几条产出流存在、其中哪几条是处置成本(**U6**),
决定的是**要不要有 by-product 这个概念**本身,不只是它的参数。
在 U6 之前设计形状,就是**照着想象出来的运营拟合一个模型**。
**【Tim 确认:工艺流程图没有定稿】→ (C),不提形状。**

**唯一现在就该落纸的,是 §2.2c 那条测量结论**(现有形状不可能表达负价值产出,
将来那一刀要的是新结构不是新行)—— **它是一条【测量结果】,不是一个设计,
所以它不受 U6 阻塞,而且必须留下来免得被重新发现。**

## 3.3 ③ `operation_type_code` 必填

| 部分 | 类 | 推理 |
|---|---|---|
| `commit_processing_run` 拒绝无工序的新单 | **★ (A) ★** | 工序字典**完整**(5/5 已播种);界面**已经必填**;真实炉次 **0**,所以迁移代价为零。**不管产线最后怎么跑,一张加工单都必须说出它跑的是哪道工序。** |
| 14 张历史单保持 NULL | **(A)** | 不回填是一条已经被写下来的裁定 |
| 报表把 NULL 显示成【未归属】 | **(A)** | 抄 EQP-2c 的 `unattributed_runs_in_window` |
| 「每吨」的分母:投料 vs 产出 | **(B)** | 见下 |
| `equipment_id` 必填 | **(B)** | 见下 |
| 跨工序共用成本的分摊 | **(C)** | 今天不存在共用成本;发明一条规则是虚构 |

> **③ 是四件里唯一一件【纯 (A)】的主体。** 它什么都不等 —— 不等 Tim 的裁定,
> 不等产线,不等一张图。**这就是它该先做的全部理由。**

**(B) ①「每吨」的分母 —— 谁、何时、什么强迫他:**
* **谁:** Tim(这是一次会计口径裁定,不是设计决定)。
* **什么时刻:** **第一次有人要看"每吨成本"之前**,也就是建那个视图的那一刀。
* **什么强迫他:** 建视图的人**必须在两列里选一列**,`total_input` 与 `total_output`
  **都在表上**。**选不了就建不出视图** —— 强制力是天然的,不需要新机制。
* **代价:零**(不建任何东西,只是一句裁定)。

**(B) ② `equipment_id` 必填 —— 谁、何时、什么强迫他:**
* **今天不可能**:5 道工序里 4 道没有登记资产(§2.3f)。
* **谁:** 登记固定资产的人(财务)。
* **什么时刻:** **一台机器进场并投用的那一刻**(`in_service_date` 落下的那一刻
  —— 两台现有机器该列**都是 NULL**)。
* **什么强迫他:** 今天**没有东西**。折旧会强迫资产被登记,但**不会**强迫
  它被关联到加工单上。→ **必填只能排在"每道工序至少有一台在册机器"之后**,
  而那是一个**可以被查询的条件**,不是一次感觉:

  ```sql
  SELECT ot.code FROM operation_types ot WHERE ot.is_active
    AND NOT EXISTS (SELECT 1 FROM fixed_assets fa WHERE fa.status='active' /* ← 还需要一条工序↔资产的关联,今天不存在 */);
  ```
  **括号里那句话本身是一个缺口:今天没有任何东西说"这台机器跑哪道工序"。**
  记为具名缺口 —— 它是 `equipment_id` 必填的**真正前置条件**。

## 3.4 ④ 交接班

| 部分 | 类 | 推理 |
|---|---|---|
| `shifts` 字典(哪个班、起止时刻) | **(A)** | 【Tim】"会有两个班"。班次的**定义**不取决于产线怎么跑。 |
| `shift_handovers`(谁交给谁、签收) | **(A)** | 形状抄 `attendance_lines.recorded_at` 的"没记 vs 记了是零" |
| `handover_item_types` 字典 + 逐条内容 | **(A)** | 内容是数据不是代码,加第七项 = 加一行 |
| 未完成工作(料还在机器里) | **(A)** | 唯一全新的实质内容,无现成载体 |
| 设备状态 | **(A) —— 但是【引用】** | `equipment_downtime` 已存在 |
| **"这个班处理了什么"** | **★ (C),阻塞在 G8 ★** | 加工单只有 `date`,归不到班次。见 §2.4b 三条出路 |
| 事故 | **(C)** | WSH 登记簿尚未建,与 ④ **同时**解锁;现在**不留列** |
| **整件东西真的被填** | **★ (B) ★** | 见下 |

> ★ **(B) —— 而且这一条是四件里最硬的一条 ★**
>
> **谁填:** 交班的车间技师。**今天:0 人**(`work_category='shopfloor'` 计数为 0)。
> **什么时刻:** 每个班结束、离开厂区之前。
> **什么强迫他:**
>
> **【今天:什么都没有,而且"操作员应该记得"不是一个答案。】**
> `inbound_movements.location` **105/106 未指定**就是那份证据 ——
> **一个没人被要求填的字段会一直空着。**
>
> 能想到的**机械**强制力,逐个测过可行性:
>
> | 候选强制力 | 可不可行 | 理由 |
> |---|---|---|
> | 接班人**签收**才算完成,未签收进看板 | **可行** | `operations_now` 已有 31 支臂,加一支"未签收的交接班"是现成机制 |
> | 上一班未交接则下一班**不能提交加工单** | **可行,但很硬** | 需要加工单↔班次的关联 → **阻塞在 G8**(同 §2.4b) |
> | 考勤/工资挂钩 | **不可行** | `attendance_lines` 是**每月一行**,粒度差了两个数量级 |
> | "技师应当记得" | **★ 不是一个答案 ★** | location 字段已经证明过 |
>
> **推荐:签收 + 看板一支臂。它是今天唯一既可行又不阻塞在 G8 上的强制力。**
> **但要诚实:它强迫的是【接班的人去看】,不是【交班的人去写】。**
> 真正强迫交班的人写字的,只有"不交接就不能开工",而**那一条阻塞在 G8**。
> → **④ 建出来之后,在 G8 落地之前,它的填充率取决于纪律,而这个仓库
> 已经量过纪律的效果:105/106。**

---

# 四 · STEP 4 · 代价、形状、建议

## 4.1 代价,按表与行数

| 件 | 新表 | 新列 | 新函数/改函数 | 播种行数 | 迁移触及的现有行 |
|---|---|---|---|---|---|
| ① | **0** | **1**(`work_order_expected_outputs.basis`)(+ 可选 `basis_reference`) | 0(可选:一条 `NOT VALID` CHECK) | 0(值域在 CHECK 里)+ **N 行播种预设值**(N 由 Tim 定,可为 0) | **1 行**(线上唯一那行 → 标 `planner_estimate`) |
| ② | **—** | **—** | **—** | **—** | **不建** |
| ③ | **0** | **0** | **改 1 个**(`commit_processing_run`:去掉 `p_operation_type_code` 的 DEFAULT + 一条拒绝);**可选 1 视图**(每工序每吨成本) | 0 | **0 行** —— 14 张历史单**一个字不动** |
| ④ | **3**(`shifts`、`shift_handovers`、`handover_item_types` + `shift_handover_items` = 3~4) | 0(**不动** `processing_runs`) | 1~2(提交/签收) | `shifts` **2 行**、`handover_item_types` **~5 行** | **0 行** |

**总计如果全做:新表 3~4、新列 1、改函数 1、新函数 1~2。**
**③ 单独做:改一个函数,新增零个对象,触及零行。**

## 4.2 提议的形状

### 4.2a ① —— 一列,不是一张表

```sql
ALTER TABLE public.work_order_expected_outputs
    ADD COLUMN basis text CHECK (basis IN ('planner_estimate','seeded_industry','calibrated'));
```

* **抄 `metal_prices.source`**:值域在 CHECK 里、**没有默认值**
  ——「漏填就是一次失败,而不是悄悄补上一个看起来像答案的值」;
* **抄 `inbound_batch_metals` 的 `NOT VALID` 形状**:新行必填、线上那 1 行标
  `planner_estimate`(它**确实**是排计划的人估的,这不是猜测,是那张表的定义);
* **可选第二列 `basis_reference`**(自由文本),抄 `metal_prices.source_reference`
  ——「**自由文本是刻意的:它是证据,不是数据**」。哪份行业报告、哪次校准跑批。

**这一列【就是】Tim 要的"播种的猜测 vs 校准过的数字"那条分界。**
在文件头写明:**这是把"零 vs 不适用"那条标准,施加到【置信度】上** ——
六个月后 Tim 打开一行,能看见这个数是**被真实生产验证过的**,还是**当初那个猜测**。

**替代方案(evidence 不足以完全排除):** 独立的
`expected_yield_ratios(form_code, chemistry, output_form_code, ratio, basis)` 表。
**不推荐**,两条理由:(1) 与该表**自己的注释**明写的"不覆盖这一张"相抵触;
(2)【码】`materials.form_code` 5 行里只填了 1 行、`chemistry` 只填了 2 行 ——
**这张表的主键今天几乎无处可挂**。若 Tim 将来要它,它作为
**第三个 `basis` 值的来源**进来,仍然不覆盖 `work_order_expected_outputs`。

### 4.2b ③ —— 一个函数的一次拒绝

```sql
-- commit_processing_run 里,紧接现有的 PROCESS_DATE_REQUIRED / ALLOCATION_BASIS_REQUIRED
IF p_operation_type_code IS NULL THEN
    RAISE EXCEPTION 'OPERATION_TYPE_REQUIRED'
      USING HINT = '从今天起每一张加工单必须说出它跑的是哪一道工序 —— 产出有无、损耗守恒、'
                   '安全状态受理三道闸全都读它。历史上那 14 张没有工序的单是测试残留,'
                   '刻意不回填,报表把它们显示成【未归属】。';
END IF;
```

* 与 `PROCESS_DATE_REQUIRED`、`ALLOCATION_BASIS_REQUIRED` **形状完全一致** ——
  这两条已经在同一个函数里,所以这不是一个新习惯;
* 新错误码需要进 `app/processing/errorCodes.ts`(今天 13 个)与 `messages/`;
* **界面一个字都不用改** —— 它**已经必填**;
* **`p_operation_type_code` 的 `DEFAULT NULL` 应当一并去掉**,让**签名**也说实话。

**替代方案:** 表上一条 `NOT VALID CHECK`。
**两者都对,而且可以【都做】** —— 函数那条给出**可本地化的错误信息**,
表那条对**任何写入者**都成立(与 `work_orders_closed_consistent` 的注释同一条理由:
「函数是唯一写入口**今天**成立,而约束对任何写入者都成立」)。
**推荐两条都上。**

### 4.2c ④ —— 三张表,内容是行

```
shifts                 (code, name_en, name_zh, starts_at time, ends_at time, is_active, sort_order)
                        ★ 全库第一个 time 列 ★
shift_handovers        (id, shift_id, handover_date, outgoing_employee_id, incoming_employee_id,
                        submitted_at, acknowledged_at, acknowledged_by, notes)
                        ★ acknowledged_* 抄 attendance_lines.recorded_at 的"没记 vs 记了是零" ★
handover_item_types    (code, name_en, name_zh, is_required, sort_order)   ← RUNTIME CONFIG
shift_handover_items   (handover_id, item_type_code, body, ...)            ← 第七项 = 字典加一行
```

**明确【不】建的:**
* **不**在 `shift_handovers` 上记设备状态 → 读 `equipment_downtime`;
* **不**记事故内容与法定时限 → 那是 WSH 登记簿的;
* **不**给事故留一列外键指向尚不存在的登记簿(EQP-2a 已拒绝过这种做法);
* **不**动 `processing_runs`(第 3 项内容阻塞在 G8,不在这里发明一条捷径)。

## 4.3 什么阻塞在【Tim 的裁定】上,什么阻塞在【产线跑起来】上

| 阻塞项 | 挡住哪一件 | 类型 |
|---|---|---|
| **工艺流程图定稿** | **② 全部**(G10 ← U6) | **★ Tim 的裁定 ★** |
| 「每吨」的分母:`total_input` 还是 `total_output` | ③ 的那个视图(不挡主体) | **Tim 的裁定** |
| 要不要播种预设值、播几条 | ① 的播种部分(不挡那一列) | **Tim 的裁定** |
| 新物料是否必填 `form_code` | ① 的"按投料种类分组" | **Tim 的裁定** |
| 真实炉次 | ① 的 `calibrated` 值真的出现 | **产线** |
| 车间人员到岗 | ④ 真的被填;WSH 登记簿的触发 | **产线/招聘** |
| **G8(一炉的时长/跨班次)** | ④ 的"这个班处理了什么" | **一次已排队的建造** |
| 工序↔资产的关联 + 资产登记补齐 | `equipment_id` 必填 | **产线/资产登记** |

**③ 的主体不在这张表上 —— 它什么都不等。**

## 4.4 建议的建造规模

> ### **★ 建议:做 ③,做 ①,不做 ②,④ 按 Tim 已下的裁定做 —— 但【分成三刀】,不要捆。★**

| 顺序 | 件 | 规模 | 为什么是这个顺序 |
|---|---|---|---|
| **1** | **③** | **最小**:改 1 函数 + 1 条 CHECK + 1 个错误码。**零新表、零新列、零行被触及。** | **什么都不等**,而且它**打开另外三件的可测量性** —— 在工序被记录之前,任何按工序的收率、成本、设备用量都是空的。**它也是四道安全闸的总开关**(§2.3d),这比"成本中心"这个名字重要得多。 |
| **2** | **①** | **小**:1 列 + 可选 1 列 + 1 条 `NOT VALID` CHECK + N 行预设 | 兑现 `work_order_expected_outputs` 表注释**已经写好**的设计。不发明任何东西。 |
| **3** | **④** | **中**:3~4 张新表 | Tim 已裁定"照建",本文件只是把它建成**引用而非复述**,并把它第 3 项内容的阻塞(G8)说清楚。 |
| **—** | **②** | **不做** | (C)。阻塞在一张还没定稿的图上。§2.2c 那条测量结论留在本文件里,免得被重新发现。 |

**如果只做一件,做 ③。** 它是四件里唯一 evidence 完全支持的一件:
维度已存在、字典已完整、界面已必填、真实数据为零(所以代价为零)、
而且不填它会同时关掉四道闸。

**"现在少建一点"的具体所指:** 不建 `cost_centres` 表(§2.3b)、
不建独立的收率比例表(§4.2a)、不建副产品结构(§3.2)、
不在 ④ 里复述设备状态与事故(§2.4d)。**四个"不建"里有三个是因为
那个东西已经存在,第四个是因为决定它形状的那个问题还没有答案。**

---

# 五 · 对 brief 每一条的交代

| brief 的条款 | 交代 |
|---|---|
| STEP 0 状态检查 | 【码】HEAD `9e9f081`(EQP-PAY-1);`HEAD == origin/main`(同一 SHA `9e9f081a…`);`git status --porcelain` **零行**。三项全部相符,未做任何和解。 |
| STEP 1 按名调用 grilling | 已调用 `mattpocock-skills:grilling`。一轮五问,Tim 全部接受。删掉的假前提 4 条,见 §1.1。 |
| 「四件是否已存在」 | **三件已存在**,第四件的两项内容已存在/已排队。**第五次连续发生。**见 §0.1。 |
| 「四件是否属于一起」 | **不属于。** 四个互不相干的阻塞项、三个不同的主人。见 §0.3。 |
| 「副产品能否在负价值裁定之前设计」 | **不能**,而且阻塞项比 brief 假设的更靠上游:是 **U6 / 工艺流程图**,不是"负价值"这一个问题。见 §2.2d。 |
| 「成本中心是否重复既有维度」 | **重复,而且是重复【两个】。** 且两个都 0/10 填充。见 §2.3b。 |
| 2a 预期产出 / 键 / 出处先例 | §2.1,三条先例点名,推荐 `metal_prices.source`。 |
| 2b 分摊如何铺开 / 是否一视同仁 / worked example / 能否表达负值 | §2.2。**一视同仁**;真单 `PROC-2026-0164` 上主产品单位成本 4.0457 → 5.0200(**+24.1%**);**负值不可表达,需要新结构**。 |
| 2c 既有维度点名 / 能否靠 join 回答 | §2.3a–b。`cost_type` + `run_id` →(`equipment_id`, `operation_type_code`)。**结构上能,数据上不能。** |
| 2d 是否有班次 / 时刻维度 / NEA 义务载体 | §2.4a、§2.4d。**全库 0 个 `time` 列**;NEA 义务**无载体**,应落在已排队的 WSH 登记簿。 |
| STEP 3 (A)/(B)/(C) + (B) 的人与时刻与强制力 | §3.1–3.4。每条 (B) 都点了人、时刻、强制力,并说明**今天没有强制力**的那几条。 |
| 「操作员应该记得」不是答案 | §3.4 的强制力表把它单列为**不是一个答案**,证据是 `location` 105/106。 |
| STEP 4 代价按表与行数 | §4.1。 |
| STEP 4 形状 + 替代方案 | §4.2,①与③各给了替代方案并说明为何仍推荐主方案。 |
| STEP 4 阻塞在裁定 vs 阻塞在产线 | §4.3。 |
| STEP 4 建造规模 + 是否有些不该现在建 | §4.4。**②不建**,并列出四个"不建"。 |
| 只写一份文件,只读 | 本次会话唯一写入的文件是 `docs/processing-support-scoping.md`。无迁移、无 fixture、无备份、无窗口、未动库。 |
| 不许"修"那些刻意的现状 | 未动。13/14 张无工序的单、`ZZ-*` 刮擦行(含 4 张 ZZ 员工)、`output_batch_safety_states` 零行、`company_compliance` 零行、两台未投用的机器,**全部按刻意状态引用,未报为缺陷、未清理**。 |
| 线上日期是模拟的 | 本文件未从任何日期推断紧迫性。 |
