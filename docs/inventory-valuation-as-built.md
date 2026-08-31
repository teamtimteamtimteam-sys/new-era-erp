# 存货计值 —— 实建(INV-VAL-1,2026-08-31)

**INV-VAL-0 是普查(只读、只写一份文档)。这一份记的是【建成了什么】,以及
【哪些事情建之前就已经是真的】。** 口径、拒绝码、退休掉的第二定义、关账闸够不够,
都在这里。规格与测量在 [inventory-valuation-scoping.md](inventory-valuation-scoping.md)。

---

## 0 · 委托书的四件事里,有一件【建之前就已经建好了】

R9 要求"到货日与业务日在收货时成为必填"。**实测四条创建路径,四条都已经拒**:

| 路径 | 拒绝码 | 来自 |
|---|---|---|
| `create_inbound_batch` | `ARRIVAL_DATE_REQUIRED` | IOD-2-fu1 |
| `receive_inbound_batch_against_po` | `ARRIVAL_DATE_REQUIRED` | IOD-2-fu1 |
| `create_output_batch` | `OUTPUT_DATE_REQUIRED` | IOD-2-fu1 |
| `commit_processing_run`(产出日取 `p_process_date`) | `PROCESS_DATE_REQUIRED` | 既有 |

而且 `inbound_batches` / `output_batches` **没有 INSERT 策略**,那几支 RPC 是唯一入口
—— 所以那个拒绝是真的,不是表单层的。IOD-2-fu1 的注释里甚至已经写着本刀准备重写的
那句理由:「**不给默认值:`CURRENT_DATE` 会让留空比填对更容易通过**」。

**另一条被删掉的前提:`business_date` 不是一个独立字段。**
`inventory_ledger_triggers.sql:54` 把收货流水的 `business_date` 直接写成
`NEW.arrival_date`。实测 24 条进料收货流水,两者的空/非空 23/24 一致;唯一的例外
**IN-2026-0001** 是一条 **2026-07-03 补写**的流水(触发器当时还不存在)——
那正是 INV-VAL-0 §3c 说的 `business_date` 下限本身,**不是泄漏**。
所以 R9 的"两个字段"在进料这条路上是【一个字段 + 一次触发器复制】。

### 那么 R9 真正缺的是什么

**建的时候拦得住,改的时候拦不住。** `app/inbound/[id]/edit/actions.ts:28,53`
直接 `UPDATE` 表,空字符串写成 `null`,而 RLS 的 UPDATE 策略只问
`module.inbound.edit`。于是【收货时必填,收货后可以清掉】。

本刀补的就是这一半:`guard_receipt_date_not_cleared()` 转移守卫。

> ★ **为什么不是 `NOT NULL`** —— 线上 7 张进料批没有到货日,全部早于 IOD-2-fu1,
> 而 R9 明写【不许回填】。`NOT NULL` 会把那 7 张行**锁死**:连改个备注都提交不了。
> 所以只拒【由有变无】,让 `NULL` 保持 `NULL` 的更新照过。
> **fixture 172 E 臂同时钉这两件事** —— 只钉"改回空被拒"的话,一个 `NOT NULL`
> 实现也会通过,而它会把那 7 张历史行锁死。

### R9 打破了什么 —— 逐条,而且第一次数漏了一条

预先扫描的结论是"60 份插 `inbound_batches` 的 fixture 全部带 `arrival_date`,
0 份插 NULL"。**那个扫描是错的**:它 grep 的是字面量 `NULL`,
而 fixture 88 是把 `NULL` 直接写在 `VALUES` 里的第七个位置上 ——
**gate 抓到了它(退出码 4),不是我抓到的。**

`db/fixtures/88`(供应商收货规律)的 D 臂需要【无日期收货】存在,
因为 `supplier_receipt_pattern` 要把它们分成第三类(既不进分母、也不算 excluded)。
两处都改了,而改法本身是一条发现:

* **D1 从前断言"拒它的是 `business_date` 那条约束"。那个拦截是个巧合,而且漏了一半。**
  它是【间接】的:收货触发器把 `arrival_date` 抄成流水的 `business_date`,
  于是**带货的**无日期收货撞上流水那条 `NOT VALID` 约束。而
  **`remaining_qty = 0` 的收货不产生流水**(`emit_batch_receipt_movement` 提前返回),
  于是它畅通无阻 —— **线上那 7 张历史无日期行正是这么来的。**
  R9 之后拒绝是【直接且具名】的:`ARRIVAL_DATE_REQUIRED`,带货零货一视同仁。
  D1 现在**两半都钉**,新增的那一半从前是漏的。
* **D2 造的两条无日期收货现在只能当【历史行】造**(插入时关掉守卫),
  并在注释里说明为什么:新的无日期收货再也进不来,而历史的那些按 R9 会一直在,
  所以那张视图仍然必须把它们分类对。

**判据:一次 grep 不是一次测量。** 真正的枚举是 gate 跑一遍。

---

## 1 · 建了什么(以及扩了哪张已有的面,而不是新起一张)

**没有新报表。** 三张已有的面各自长出这一刀要的那一节:

| 面 | 加了什么 | 权限 |
|---|---|---|
| `gl_control_reconciliation` | 第三、第四条腿:`inventory_raw`(1200)、`inventory_fg`(1220) | `module.finance.view` |
| RPT-1 `/inventory/reports/snapshot` | 金额列、库龄节、产出三态、"看不见什么" | `module.inventory.view` |
| `management_packs` | 自动 —— 见 §4 | `module.finance.view` |
| `/inventory` + 两个钻取页 | 口径搬到到岸成本;退休第二份库龄定义 | 既有 |

**为什么是两张面而不是一张**(委托书原本设想一张):
`operations` 与 `warehouse` 实测 **有 `module.inventory.view`、没有 `data.view_prices`**
—— 而他们正是 R1 的读者。一张面同时服务审计与作业,给作业方的会是**一张整列受限的
报表**。所以审计那节(账面/明细/具名差异/未解释)在 finance 权限后面,
作业那两节(物料×库位×状态、库龄)在 inventory 权限后面,**共用一个口径**。

---

## 2 · 口径:一个,而且是哪一个

`inbound_batch_landed_unit_cost` = 采购价 + 运费 + 已资本化加工成本(÷ `quantity`)。
注销、盘点、勾稽、`/inventory`、RPT-1 **五处读同一支函数**。

**搬 `/inventory` 的实测(STEP 3a):16 张批次逐批比对,`basis_differs = false`,
合计两侧都是 185,703.48,未计价批次两侧都是 5 张。一个现有数字都没有变。**
—— 与 INV-VAL-0 的预测一致(运费与加工成本载体今天全部被冲销,所以两个口径今天恰好
相等)。M2「两个估值基准并存」就此关闭,**而它关得正是时候**:它今天为零,
在第一张不被冲销的运费单过账的那一刻就不为零。

### 屏幕为什么读一张视图,而不是直接调那支函数

★ **`inbound_batch_landed_unit_cost` 是 `SECURITY DEFINER`,直接读基表的
`unit_price`,绕过 `inbound_batches_masked` 的 `data.view_prices` 遮蔽,
而且它自己不做任何权限判断。** 它今天安全只靠一件事:**没有授给 `authenticated`**
(实测 `proacl` = postgres, service_role)。

**授权是一个会被下一个人改掉的配置,不是一道控制。** 所以本刀开
`inbound_batch_valuation` / `output_batch_valuation` 两张视图把遮蔽加回来
(属主权限 + 体内 `has_permission`,与 `stock_snapshot` 同形),
而两支新读取器**各自 `require_permission`** —— 即便哪天有人把那支函数授了出去,
它们也不会因此多透出一分钱。**这条写在函数抬头里,不只写在这份文档里。**

---

## 3 · 勾稽:四条具名成因,零兜底桶

实测(线上,SGD,2026-08-31,as-at = 今天):

```
inventory_raw  1200   账面 74,687.92 · 明细 185,703.48 · 差 111,015.56
  never_capitalised              +23,300.00   IN-0002 / IN-0012,计价早于过账通路
  orphaned_reprice_delta         +49,312.76   IN-0003 48,000 + IN-0001 1,312.76
  relief_without_capitalisation  +40,444.00   IN-0013 40,000 + IN-0001 444
  unallocated_consumption         −2,041.20   IN-0152(PROC-0107 已提交未分摊)
  stranded_capitalisation              0.00   M3 LANDED-DENOM
  freight_split_residue                0.00   M4
  UNEXPLAINED                          0.00   ✓ reconciled

inventory_fg   1220   账面 134.86 · 明细 388.20 · 差 253.34
  costed_before_1220_path          +253.34   OUT-2026-0007(PROC-2026-0003)
  UNEXPLAINED                          0.00   ✓ reconciled
```

AR/AP 两条腿**未变**(43,002.12 / 57,443.00 与 372,450.04 / 430,037.62,两侧 0.00)。

### ★ 归因必须【原分录优先】,否则 unexplained 当场不为零

1200 上 18 行里有 4 行是冲销,而**冲销分录的 `source_id` 指向原分录,不是批次**。
写成 `COALESCE(je.source_id, orig.source_id)` 会让那 4 行归因失败 ——
原分录算进了批次、它的冲销没有,净额错成 `+原分录`。正确顺序是
`COALESCE(orig.source_id, je.source_id)`。**实测:18 行全部归因,归因合计
= 74,687.92 = 1200 的余额本身**(所以没有任何一行落在归因之外)。

### 没有兜底桶,而这一条是被【注入】证明过的

fixture 172 A 臂往 1200 打一笔 `source_type='manual'` 的手工分录 ——
它不匹配任何一条具名成因,于是 `unexplained` 当场变成 −333、`reconciled` 变成 false;
冲掉它之后回到 0。**一个给存货侧留了"其他"兜底桶的实现,在这一臂上会报 0。**

---

## 4 · 月末:整份勾稽本来就冻在包里了

`management_pack_data` 早就在调 `gl_control_reconciliation(v_aging)` 并把
**整个返回值**存进 `control_reconciliation`。勾稽长出两条存货腿之后,
管理包**自动**冻住了存货的账面、明细、每一条具名差异与 `unexplained` —— 一行没改。
那是 GLEXPORT-1 把包做成整块 `jsonb` 而不是拆成列的回报。

本刀只补 `caveats` 里确实缺的两件:

* **`control_unexplained_sides`** —— 四条腿之后,"有一条没解释干净"必须说得出
  **是哪一条**(4b)。此前只有一个合计。
* **`inventory_section_refused` / `_refusal`** —— `SUM` 会跳过 `NULL`,于是一条
  **被拒绝、根本没评估过**的腿会让 `control_unexplained` 显示 `false`,
  **那是一句假话**。拒绝单独记一条(4c)。

**已关账的月份会看到什么**:`v_aging = LEAST(月末, 今天) = 月末`(过去),
于是存货明细侧重建不出来,冻下来的是**一句具名拒绝**,而不是一个今天重算、
却摆在历史月份名下的数字。那正是 R3 要的。

---

## 5 · as-at:能答的答,答不了的具名拒绝(R5)

* `p_as_of >= 今天` → 用 `remaining_qty`,精确,`subledger_basis='live_position'`;
* `p_as_of < 今天` → 先证明重建算得出来,证不出来就拒:
  * 范围内有任何一行 `business_date` 为空 → `BUSINESS_DATES_INCOMPLETE|<n>|<下限>`
  * 范围内有任何一笔资本化发生在 as-at 之后 → `CAPITALISATION_AFTER_AS_OF|<n>`
  * 此时数字为 `NULL`、`reconciled` 为 `NULL` —— **答不上来不是对不上**。

实测:`inventory_valuation_snapshot(DATE '2026-06-30')`
→ `AS_OF_NOT_RECONSTRUCTABLE|2026-06-30|2026-07-03`。
**它会随数据变好而自己打开** —— 不是一条永久关闭的路。

> **【时区那一刀差点让这条判词每天拒八小时】** 线上 DB 的 `TimeZone` 是
> **Asia/Singapore**,而 Next.js 侧 `toISOString()` 给的是 **UTC** 日期。
> 每天 00:00–08:00(SGT)两者差一天,应用会把"昨天"当作 as-at 送进来,
> 于是这张页面会被自己的判词拒掉。**修法不是放松判词,是把"今天"的权威还给
> 数据库**(`p_as_of DEFAULT NULL` = 此刻)。见 fu3 / fu4。
> 判据:**需要在 TS 里 cast 才能调用的 RPC,通常说明 SQL 侧的契约没写完整。**

---

## 6 · 库龄:第二份档位定义被【删掉】,不是绕开(R4)

库里曾有两份:

* `aging_bucket`(DB,`IMMUTABLE`,**0-30 / 31-60 / 61-90 / 90+**,AGING-1 明写它被抽
  出来正是因为边界写过三遍);
* `lib/valuation.ts` 的 `AGING_BANDS`(TS,**30 / 90**,两档半)。

**两份的边界本来就不一样**:一批 75 天的货在 DB 里是 `b61_90`,在屏幕上是 `warn`。
没人报过这个 bug,因为 TS 那份只用来上色 —— **而那正是第二份定义最能活得久的形态。**

处置:两张估值视图把 `aging_bucket` 的结果**带出来**,TS 侧只把档位映射成颜色
(`toneForBucket`)。`AGING_BANDS` **和 `agingDays` 一起删掉了**,不是留着不调用:
**一份留着不调用的第二定义,下一个人一定会调用它。**

缺到货日进 `no_date` 档,**它是一个被渲染出来的档位**。实测线上 4 张在库批次
落在这一档,占在库价值 **108,969.12 / 185,703.48 = 58.7%**。

---

## 7 · 产出侧三态(R6)

| 状态 | 渲染 | 线上 |
|---|---|---|
| 计过价、在库 | 数字 | OUT-2026-0187 = 134.86 |
| 计过价、卖光了 | **0.00** | OUT-2026-0001 |
| **从未分摊** | **`—`** | 12 张在库产出批里 **10 张,3,661kg / 3,816kg** |

`output_batch_valuation.cost_value_base` 对从未分摊的腿返回 **NULL 而不是 0**。
fixture 172 B 臂**分别**断言 `0.00` 与 `NULL`,并显式禁止两者相等 ——
一个把"不适用"写成 0.00 的实现,会让那 3,661kg 读起来像是已经计过价了。

---

## 8 · 关账第五闸,以及它【关不住】什么(R8 / STEP 5c)

`close_period` 的第五条拒绝:**`PROCESSING_COSTS_UNALLOCATED|<月末>|<张数>|<单号…>`**

拒绝里**点名那些加工单** —— 第一个撞上它的人会被 8 张八月的测试单挡住,
而补救办法必须从拒绝这句话本身看得出来,否则它是一堵没有门的墙。

### 实测会挡住哪些月末

| 月末 | 会被挡住的加工单 | 实际发生什么 |
|---|---|---|
| 2026-06-30 | PROC-2026-0001 | 先撞 `ALREADY_CLOSED`(锁线已在 2026-08-01) |
| 2026-07-31 | + PROC-2026-0009 | 同上;**该月已关,本闸不追溯** —— 但重开再关会被拒 |
| **2026-08-31** | + 0106 / 0107 / 0108 / 0162 / 0163 / 0225 = **8 张** | ★ **下一次关账会被真的挡住** |

实测拒绝原文:
`PROCESSING_COSTS_UNALLOCATED|2026-08-31|8|PROC-2026-0001, PROC-2026-0009, PROC-2026-0106, PROC-2026-0107, PROC-2026-0108, PROC-2026-0162, PROC-2026-0163, PROC-2026-0225`

### ★★ 这条闸【不】足以让 1200 保持被正确解除 ★★

**它只关掉 M1(消耗只在分摊那一刻解除 1200)。闸开绿之后,以下四条仍然会让
1200 与批次侧分开:**

| # | 机制 | 今天 | 什么时候不为零 |
|---|---|---:|---|
| **M3** | `LANDED-DENOM` —— 资本化落在【已被部分消耗】的批次上,分母是 `quantity`,残值搁浅在 1200 | 0.00 | **分摊【做过了】,闸是绿的** —— 一旦产线真的开动**必然**不为零。**这是最要紧的一条。** |
| **M4** | 运费按过账当刻的 `in_stock_ratio` 劈分,之后不再重算 | 0.00 | 任何落在部分消耗批次上的运费。**闸根本不看运费。** |
| **M5** | `remaining_qty > quantity`(盘盈)使解除**过头** | 0.00(金额) | IN-2026-0003 现在是 **80 / 50**;它一旦挂上资本化成本,会多解除 **60%**。**方向与 M3 相反、落在不同批次上,所以两者不会互相抵消。** |
| **M7** | 注销 / 盘点不检查成本是否进过账 | +40,000(cutover) | 任何计过价却从未资本化的批次 |

**所以这条闸按【它检查的那件事】命名,不按结果命名。**
一个叫 `INVENTORY_NOT_RECONCILED` 的闸会宣称一份它并不具备的完整性 ——
fixture 172 D 臂**显式断言拒绝文本里不含那个名字**。
这四条也印在报表自己的 `cannot_see.close_gate_does_not_cover` 里,
**不只写在这份文档里** —— 一个只写在文档里的限制,读报表的人看不见。

---

## 9 · 本刀发现、但**没有修**的(具名,连同不修的理由)

1. ★ **`inbound_batch_landed_unit_cost` 是一支没有权限检查的 `SECURITY DEFINER`,
   且绕过价格遮蔽。** 今天安全**只**因为没授给 `authenticated`。本刀不动它
   (改它的授权面超出本刀范围),但**本刀新建的读取器一律自己判权限**,
   并把这件事写进了函数抬头。**下一个在它上面加读取器的人必须知道这件事** ——
   这正是把它写下来的理由。
2. **`cfo` 角色打不开财务勾稽** —— 它没有 `module.finance.view`(实测)。
   **早于本刀**。今天不可见,因为该角色是给同时持有 admin 的 Tim 建的;
   **换一个人拿 cfo 的那天它就会现形**。排进开账前的权限清理。
3. **`marketValuePerKg()` 返回 USD/kg 却被标成 SGD**(INV-VAL-0 §1.1,按 1.28 少报约 22%)。
   **本刀刻意不碰**,也**没有让新的估值面去消费它** —— §5 的 A0 已裁定市价不进
   这张成本报表。紧接本刀的下一刀。
4. **五支 RLS 盲的函数**(`bank_book_balance_asof`、`attendance_unpaid_days`、
   `sale_settlement_compute`、`resolve_review_reviewer`,以及
   `journal_activity_lines` 之上那一层 / M11)。存货两条腿**继承** M11,
   不因此变坏,也没被修好。
5. **M3 `LANDED-DENOM`** —— 需要载体表表达不了的子批次身份,是**一个特性,不是一次更正**。
   已作为具名成因**从第一天就列在报表上**,而不是等它不为零那天再加。

---

## 10 · 判词(gate / build / 实测)

* **fixture 172**(五臂,逐臂先证注入改变了什么):勾稽动得开(−333)、
  三态互不相同(150.00 / 0.00 / NULL)、受限具名、第五闸点名加工单、
  两个日期改不回空**而历史缺失活着**。
* **受限读者实测**(以只有 `module.inventory.view` 的主体):
  `restriction = PRICE_COMPONENTS_RESTRICTED|data.view_prices`,
  `by_location` 每一行 `value_base` **IS NULL**,**而数量照常给全**。
* **金额表与数量表数出同样的量**:`by_location` 合计 = `stock_snapshot` 合计
  = **119,304**(fu2 之前只数进料腿,两张表会在同一页上互相矛盾)。

---

## 11 · ★ 一处回归:INV-VAL-1 让 /inventory 整页报错约两小时(fu6,2026-08-31)

**由紧接的下一刀(FX-DISPLAY-1)"亲眼看一遍渲染出来的页面"这一步抓到,不是被任何一道门抓到。**

症状:任意 `authenticated` 用户打开 `/inventory` 或 `/inventory/inbound/[materialId]`,
整页渲染成红框:`42501 permission denied for function inbound_batch_landed_unit_cost`。
**HTTP 状态 200。**

### 成因 —— 而这条规矩仓库里早就写着,我读过还是踩了

`inbound_batch_valuation` 是 `security_invoker = off` 的视图,体内调那支
**刻意未授权给 `authenticated`** 的成本函数。而
`db/functions/aging_bucket.sql` 的抬头写得清清楚楚:

> 属主权限替得了**表**,替不了**函数的 EXECUTE** —— 那仍按当前用户判。
> 收掉它,两页会当场 42501。

**视图的属主权限不改变 `current_user`;`SECURITY DEFINER` 才改变。**
这正是为什么同样调那支函数的 `inventory_valuation_snapshot`(definer + 已授权)
一直好好的 —— 那也是修法的来源。

### 为什么三道判据同时没看见

| 判据 | 为什么绿 |
|---|---|
| 我在 INV-VAL-1 的探针 | 写的是 `SELECT count(*)` —— **计划器把用不到的列剪掉了**,那次函数根本没被调用。实测对照:`WHERE remaining_qty > 0` 的 `count(*)` **通过**,而一旦 SELECT 到 `landed_unit_cost` 或按 `unpriced` 过滤就 42501 |
| gate 的 fixture | 以 `postgres` 身份跑,postgres 有 EXECUTE —— 照不到这条 |
| 冒烟 | 判据是 2xx,而那一页把错误画成红框,**HTTP 200** |

### 修法:一层**已授权的 definer 包装**,而不是给那支函数授权

委托书明令那支成本函数排在开账前的权限清理里、**本刀不许给它授任何东西**
(授了它,采购单价就发给每一个 `authenticated` 用户,而
`operations` / `warehouse` 实测正是没有 `data.view_prices` 的两个角色)。
所以新开 `inbound_batch_valuation_rows()`:`SECURITY DEFINER`、授给 `authenticated`、
**自己 `require_permission` + 自己按 `data.view_prices` 遮蔽**;
体内以属主身份调那支未授权函数 —— `current_user` 变了,EXECUTE 就过得去。
视图改成读它,**列名列序授权全不变,应用一个字没改**。

### 判据补上了

`db/fixtures/173` **以真实用户身份**(`SET LOCAL ROLE authenticated`)钉四件事,
并且:

* **明确 SELECT 那几个计算列,不用 `count(*)`** —— 写成 `count(*)` 的话,
  这份 fixture 在缺陷仍然存在时也会通过(实测如此);
* **注入**:收掉包装函数的 EXECUTE → 视图当场变红,再授回来 → 恢复。
  不做这一步,绿灯可能只是"碰巧没人拦";
* **钉住那条禁令**:`has_function_privilege('authenticated', …landed_unit_cost…)`
  必须为假 —— 因为**给它授权同样能让前一臂变绿**,而那是错的修法。

### 顺带一处:`CREATE OR REPLACE VIEW` 会悄悄丢掉 reloptions

fu6 第一版没写 `WITH (security_invoker = off)`,live 上那一句就**没了**
(姊妹视图 `output_batch_valuation` 还留着,两张同族视图从此长得不一样)。
行为没变(属主权限本来就是默认),红的是镜像文本与"下一个人看不看得出这是刻意声明过的"。
AGENTS.md 记着 PAYEE-1a 为同一件事付过一次账。已在提交前补回。
