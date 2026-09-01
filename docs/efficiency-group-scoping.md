# 效率类四件普查(EFF-0)—— 勘察,不建任何东西

**本次会话【不实现任何东西】。唯一允许的写入是这份文件。**
不动库、不动代码、不建 fixture、不排迁移、不做备份、不开窗口。

**基线:`HEAD = e940f3a`(PROC-SUPPORT-1),`HEAD == origin/main`,工作树干净。**
所有【码】均为 2026-09-01 当日实测。

## 标记,沿用 `docs/processing-support-scoping.md` 与 `docs/proc-reality.md` 的那一套

| 标记 | 意思 |
|---|---|
| **【码】** | 从仓库或线上读出来的事实,带对象名 |
| **【Tim】** | Tim 自己的话 —— 唯一的权威 |
| **(A)** | **现在就能建,而且不管产线最后怎么跑都是对的** |
| **(B)** | **现在就能建,但没人被要求填它就会永远空着** —— 必须点名【谁】【什么时刻】【什么强迫他】 |
| **(C)** | **产线真的跑起来之前答不了** |

> **产线没有开。零真实炉次、零化验、零实测收率。**【码】线上 14 张加工单
> (10 张未软删)全部是测试残留。**"现在少建一点"是一个被允许的结论**,
> 而本次四件里有一件的结论正是它。

---

# 零 · 这份 brief 本身就是问题的一部分 —— **先读这一节**

## 0.1 第【六】次,而且这一次是四中三

`docs/processing-support-scoping.md` 把上一次记成**第五次**。这是**第六次**
一份 brief 点名要建仓库里已经存在的东西,**而且四件里命中三件**。

| # | brief 要的 | 【码】已经存在的对象 | 由哪一刀建的 | 还缺什么 |
|---|---|---|---|---|
| ① | 全局搜索 | **没有** —— 但六个模块各有自己的搜索(`app/{inbound,suppliers,customers,materials,output,hr/employees}` 的 `*Toolbar.tsx` + `*Query.ts`) | 各模块自己 | **跨模块的那一层**,真的不存在 |
| ② | 参考数据版本化 | **两处线上先例已经在做"写入时钉住字典"**:`kpi_entries.source_template_version` → `kpi_position_templates.version`;`pricing_term_commitments.source_formula_code` / `_name`(反范式快照) | KPI 那一族 / PRICE-TERM 那一刀 | 形状已有,**缺的是把它用到被把关的记录上** |
| ③ | 跨模块审计查询 | **一条脊柱已经在**:`batch_lineage_all` → `batch_lineage` → `traceability_report_data()` → `/output/[id]/traceability` + PDF + `traceability_report_issues`(带 `version`,追加式) | **FIN-25** / **AUD-1** | 它**只走物料、只向上、只对产出批**;没有成本、没有流水、没有销售、没有分录 |
| ④ | 盘点抽样 | **盘点整台机器全建好了**:`stocktakes` + `stocktake_lines` + `post_stocktake()` + `/stocktakes`、`/stocktakes/[id]`、`/stocktakes/[id]/review`,RLS 按 `module.stocktakes.view/edit`,AUDEL-1a/1b 硬删守卫 | **Phase 2 · cut 4(2026-07-03)** | **只缺【抽样规则】那一件** |

【码】线上 `stocktakes` **5 行(4 张已过账、1 张已取消)**,`stocktake_lines` **4 行**
—— 这台机器**不是没用过**,它跑过四次。

## 0.2 brief 的四条前提,三条是错的,一条是陈的

| brief 说 | 【码】实测 |
|---|---|
| ④「105 of 106 movements carry no location」 | **99 / 106。** 有 **7** 条流水带着 `location_id`,分布在 **4 个不同的** `storage_locations` 行上(LOC-1,2026-08-12) |
| ④ 把抽样说成一件新东西 | 盘点已全建(见 0.1),**只缺选取规则** |
| ③「今天要靠人手跨模块拼」 | 脊柱已在(见 0.1),**要拼的是它没覆盖的那几段** |
| ②「今天有没有东西记录写入当时字典说了什么」 | **有,两处,而且已经在线上跑**(见 0.1) |
| (顺带)「231 routes exist」 | **216**:`app/**/page.tsx` **187** + `route.ts(x)` **29** |

**【Tim】"我的 brief 的框架是一个假设,而它五分之四是错的。"**

**这一节存在的理由,和上一刀是同一条:brief 是照着"一个 ERP 应该有什么"写的,
不是照着"这个仓库里已经有什么"写的。** 名字对不上是它最稳定的症状 ——
「盘点抽样」对 `stocktakes`,「跨模块审计查询」对 `batch_lineage_all`,
「参考数据版本化」对 `source_template_version`。**先查存在,再谈建造。**

## 0.3 一个已经踩过的坑,而它正好长在 ① 的正前方

`db/views/batch_lineage_all.sql` 的抬头记着 **AUD-1(2026-08-17)** 那次:

> 一个只持 `module.sales.view` 的读者,经由 `traceability_report_data()` 去读
> **带判据的** `batch_lineage`,拿到的是**零行** —— 而零行在这里的意思变成了
> **"这个批次没有来源"**,一个**错的好消息**。

修法是把判据挪到外层视图、内层基视图**不授权给任何人**,fixture 83 钉住。
**这就是 ① 要复用的先例,不是要重新推导一遍的东西。**
`app/components/moduleGuard.tsx` 的抬头记着同一条的另一半(OPS-15):
没有模块权限的人打开该模块任意一页,RLS 返回零行,**"你没有权限"与"确实还没有数据"
在屏幕上长得一模一样**。

**这个仓库已经为这一条形状付过至少两次账。第三次不该由全局搜索来付。**

---

# 一 · 这四件不是一件 —— **别再把它们捆回去**

`docs/forward-queue.md:1237` 把阶段 7 的效率类六个名字写在一口气里,
`:1339–1341` 又把「全局搜索」「给缺少生效日期的参考数据补上生效日期」「LME 半自动取数」
分开列。**读起来像一个包,实际上不是。**

| 件 | 它是什么形状 | 底座 |
|---|---|---|
| ① 全局搜索 | **一条读路径** | 无(要新写) |
| ② 参考数据版本化 | **一个写入时刻的决定** | 两处先例已在 |
| ③ 跨模块审计查询 | **一张要接长的现存视图** | `batch_lineage_all` |
| ④ 盘点抽样 | **一台已建成机器上的选取规则** | `stocktakes` 全套 |

**四者之间没有共享底座。** 唯一的重叠是 ①③ 都要"给一个编号,找到那条记录" ——
**那是一个小函数,不是一个包**;而 ③ 已经有它的脊柱,① 一点都没有。

**结论:四件独立排期,分四刀。** 把它们捆成一刀的唯一后果,是最该做的那件
(③)被最不该做的那件(④)拖住。

---

# 二 · ① 全局搜索

## 2.1 今天有什么

**【码】没有任何跨模块搜索。** 六个模块各有自己的一套,形状统一:

| 模块 | 工具条 | 查询逻辑 | 搜索打在哪些列 |
|---|---|---|---|
| `/inbound` | `InboundToolbar.tsx` | `inboundQuery.ts` | `code` + 先查 `materials.name` / `suppliers.legal_name` 的 id 再 OR 本表 FK |
| `/suppliers` | `SupplierToolbar.tsx` | `supplierQuery.ts` | `code`、`legal_name`、`short_name`、`tax_id`、`country` |
| `/customers` | `CustomerToolbar.tsx` | `customerQuery.ts` | 同形 |
| `/materials` | `MaterialToolbar.tsx` | `materialQuery.ts` | 同形 |
| `/output` | `OutputToolbar.tsx` | `outputQuery.ts` | 同形 |
| `/hr/employees` | `EmployeesToolbar.tsx` | 页面内 | 同形 |

**六份都是 PostgREST 的 `.or(... ilike ...)`,都跑在登录者自己的 JWT 上。**

## 2.2 有多少种记录带人能读的编号

**【码】`public` 里 74 张基表有 `code` 列**(含字典)。其中**线上有行、且带人能读的编号的业务记录 23 种**,合计 **约 249 行**
(另有 `sales_records` 9 行**没有 `code`**;`contracts` 与 `expense_claims` 线上 0 行):

| 前缀 | 表 | 【码】行数 | | 前缀 | 表 | 【码】行数 |
|---|---|---|---|---|---|---|
| `JE-` | `journal_entries` | 77 | | `SUP-` | `suppliers` | 8 |
| `EMP-` | `employees` | 21 | | `PO-` | `purchase_orders` | 7 |
| (无前缀) | `containers` | 17 | | `SO-` | `sales_orders` | 6 |
| `IN-` | `inbound_batches` | 16 | | `EXP-` | `expenses` | 6 |
| `TASK-` | `tasks` | 16 | | `MAT-` | `materials` | 5 |
| `OUT-` | `output_batches` | 14 | | `ST-` | `stocktakes` | 5 |
| `PMT-` | `payments` | 13 | | `SG…` | `storage_locations` | 4 |
| `PROC-` | `processing_runs` | 10 | | `ASY-` | `assay_results` | 4 |
| `INV-` | `invoices` | 9 | | `SHP-` | `shipments` | 3 |
| — | `sales_records`(**无 code**) | 9 | | `CUS-` | `customers` | 3 |
| | | | | `FA-` `WO-` `CN-` `QT-` | 各 | 2/1/1/1 |

**`sales_records` 没有 `code`** —— 它是唯一一种"发生过、但叫不出名字"的记录。
搜索找不到它,不是搜索的缺陷。

## 2.3 现有页面怎么把关,搜索能不能直接用

**能,而且这正是决定性的一条。** 可见性今天有**两层,一份定义**:

1. **数据库层(唯一的安全边界)**:RLS `has_permission('module.x.view')` + 遮蔽视图 +
   函数里的 `require_permission`。所有六个模块搜索都跑在登录者的 JWT 上,**自动继承**。
2. **页面层(说话的那一层,不是边界)**:`lib/modules.ts` 的 `MODULES`(**15 条**,
   每条一个 `module.*.view` 权限码)+ `lib/moduleAccess.ts` 的 `canEnterModule()`
   + `app/components/moduleGuard.tsx` 的 `requireModule()`。
   `moduleGuard.tsx` 的抬头写得很明白:**"拒绝要来自权限判断,不能是从空结果倒推出来的"**,
   拒绝屏带机器标记 `data-access-denied="1"`。

**全局搜索要做的,是把这两层【原样】用一遍,不是发明第三层。**

## 2.4 ★ 决定:复用 RLS、按模块扇出、**永远不建索引** ★

**理由不是性能,是这个仓库已经被烧过两次的那条:**
一张物化搜索索引,或一个 `SECURITY DEFINER` 的搜索函数,**就是"谁可以看见什么"的
第二份定义**。而第二份定义会漂 —— OPS-14 的 xmodule 漂过一次,AUD-1 漂过一次。

**形状:**

```
searchAll(q):
  for each mod of MODULES:                      // 15 条,一份定义
     if (!await canEnterModule(mod.permission))  // ← 查询【之前】的权限答复
         → 记为「未展示」,不发查询
     else
         → 发一条本模块的 PostgREST 查询(复用现成的 *Query.ts 谓词)
         → 零行记为「无结果」
```

**扇出成本,照实记下来,免得后来的人把它"优化"成一张索引:**

* 每次搜索 **≤15 次往返**(仅对读者进得去的模块发),线上总量约 **249 行**。
* **即便到 100 倍(约 25,000 行)这仍是对的交易**:每条查询都是单表 `ilike` +
  已有索引,而**省下的那点延迟买不到"第二份可见性定义"的代价**。
* 真要优化,先优化的是**并发发出**(`Promise.all`),不是**合并成一张表**。

## 2.5 ★ 缺席规则是【界面义务】,不只是查询义务 ★

**「Inbound 里没有结果」与「Inbound 没有展示给你」必须是屏幕上两句不同的话。**

这不是措辞讲究,这是 AUD-1 那条的复发预防:零行读成"没有这个东西"是**一个错的好消息**,
而搜索是最容易产生它的地方 —— 用户搜一个他明知存在的编号,得到"没找到",
于是他相信**记录不存在**,而真相是**这个模块不归他看**。

设计要求(三条,缺一条这件事就白做):

1. 结果页**按模块分组**,读者进不去的模块**仍然出现在页面上**,写着「未展示 · 需要 `module.x.view`」。
2. 权限答复来自 `canEnterModule()`,**在查询之前**;不许从空结果倒推。
3. 沿用 `moduleGuard.tsx` 的机器标记(`data-access-denied`),让按角色的可达性走查
   (`--reach`)认得出来,**不靠认文案字符串** —— REACH-1 首跑就因为认字符串误报过一次。

## 2.6 成本

**新表 0,新行 0。** 一条纯读路径:
1 个 `lib/search.ts`(扇出 + 权限答复)、1 个 `/search` 路由、
15 条(或按需的子集)复用现成 `*Query.ts` 的解析器、1 个结果组件。

---

# 三 · ② 参考数据版本化

## 3.1 哪些字典【把关】,哪些只是【贴标签】

**判据用得住的只有一条:这张字典有没有【规则列】** —— 除 `code`/`name*`/`sort_order`/
`is_active`/`notes` 之外,还有没有一列会改变"这次写入准不准"或"算出来是多少"。

**【码】把关的字典 —— 20 张:**

| 字典 | 规则列 |
|---|---|
| `operation_types` | `kind_code`, `resulting_safety_state_code` |
| `operation_kinds` | `consumes_input`, `produces_outputs` |
| `operation_type_safety_states` | `operation_type_code`, `safety_state_code`, `resolves` |
| `operation_type_input_forms` / `_output_forms` | `operation_type_code`, `form_code` |
| `inbound_safety_states` | `may_be_fed` **(PROC-SUPPORT-1 之后已无消费者,排队移除;本刀不动)** |
| `inbound_chemistry_certainties` | `may_be_fed` |
| `material_forms` | `implies_dismantling`, **`may_be_sold`** |
| `material_kinds` | `may_ever_be_processed`, `has_condition_axes` |
| `material_sources` | `implies_never_charged` |
| `loss_categories` | `metal_fate`, `is_true_loss` |
| `output_batch_purposes` | `is_saleable_stock` |
| `waste_classifications` | `is_controlled` **(零消费者 —— 有规则列而无人读)** |
| `storage_location_allowed_classes` | `location_id`, `classification_code` |
| `tax_codes` | `side`, `f5_supply_box`, `f5_purchase_box`, `f5_tax_box`, `is_claimable` |
| `certificate_types` | `disposition`, `warn_lead_days` |
| `handover_item_types` | `is_required` |
| `leave_types` | `is_paid`, `is_accrued`, `default_days_per_year`, `requires_certificate_after_days`, `requires_approval`, `allows_half_day`, `gender_restriction` |
| `review_rating_scale` | `is_probation_pass` |
| `metal_price_indices` | `quote_currency`, `quote_currency_basis` |

**只贴标签的:** `output_batch_states`、`material_size_formats`、`battery_chemistries`、
`laboratories`、`loss_metal_fates`、`substances`(`symbol` 是标签)。
**这一半永远不需要版本化,而 brief 的问法把它们一起拖了进来。**

**已经带生效日期的,不在讨论范围内:** `tax_rates`(`effective_from`/`_to`)、
`wht_rates`(同)、`leave_accrual_rates`(`effective_from`)、`fx_rates`(按 `rate_date`)、
`contracts`(`effective_from`/`_to`)、`commission_agreements`(`valid_from`/`_to`)、
`forwarder_rate_quotes`(同)。**费率那一族早就做对了。**

## 3.2 ★ 结构发现:三张表连"什么时候改的"都答不了 ★

**【码】`operation_type_safety_states`、`operation_type_input_forms`、
`operation_type_output_forms` 一列元数据都没有** —— 没有 `created_at`,没有 `updated_at`,
没有 `is_active`,没有 `sort_order`。而多数其它字典也只有 `is_active` + `sort_order`,
**没有时间戳**:只有 `accounts`、`leave_types`、`metal_price_indices`、
`review_rating_scale`、`roles`、`waste_classifications` 带 `created_at`/`updated_at`。

**后果说清楚:「这条字典是什么时候改的」这个问题,【从数据里答不了】,
只能从 `db/migrations/` 里答。** 这是一条关于 schema 的发现,**不是本刀的活**。

## 3.3 实测:字典到底变过没有

既然数据答不了,就从**迁移**答。逐张扫 `db/migrations/*.sql` 里对上述字典的
`INSERT` / `UPDATE` / `DELETE`:

| 变化种类 | 【码】实测次数 |
|---|---|
| **从任何把关字典 `DELETE`** | **0** |
| **把任何把关字典的行 `is_active = false`** | **0** —— 全仓唯一一处 `is_active=false` 是会计科目 `6600`(FIN-3-FU-2,2026-08-04),而 **`journal_lines` 引用它的行数是 0** |
| **改任何把关字典的显示名** | **0** |
| **加行(放宽)** | 有:`material_forms` +6(2026-08-30)、`operation_type_safety_states` +1(2026-08-31 PROC-COST-1) |
| **加规则列并回填** | **2 次**(见 3.4、3.5) |

**★ 结论:brief 说的那个暴露 —— "一张加工单在上个月的受理规则下提交,今天再读
看起来像违反了一条当时还不存在的规则" —— 【线上零实例】。★**

三条支撑:

1. **每一次实测到的变化都是【放宽】。** 放宽不可能回溯性地打破一条记录 ——
   那条记录满足的是**更窄**的规则,它当然也满足更宽的。
2. `operation_type_safety_states` 的表注把不变式写死了:**「只许收紧,不许默认放宽」**
   —— 加一行是**逐工序的、明写的**放宽,正是这张表存在的方式。
3. **【码】线上 0 张未软删加工单带 `operation_type_code`**(10 张全是 NULL,
   刻意不回填)。**那张受理规则表今天一条历史记录都没有把关过。**
   `operation_type_safety_states` 有 9 行,而读它的历史记录是 0 条。

**为一类发生过零次的变化去版本化 19 张字典,是错的形状。**

## 3.4 ★ 唯一的真实例外:`material_forms.may_be_sold` —— 一条被回溯适用的【法律】规则 ★

**这一条单独成节,因为它不是清单里的一行。**

**【码】事实链:**

* **2026-08-22**(`2026-08-22-proc2-intake-condition-axes.sql`)`material_forms` 建表并播种
  **6 行**:`whole_pack`、`module`、`loose_cells`、`electrode_scrap`、`black_mass`、`mixed_unsorted`。
  当时的规则列只有 `implies_dismantling`。**这 6 行没有任何关于"能不能卖"的判断。**
* **2026-08-30**(`2026-08-30-procbuild1-loss-categories-forms-and-saleability.sql`)
  加 **7 行**新形态,然后:

  ```sql
  ALTER TABLE public.material_forms ADD COLUMN may_be_sold boolean;
  UPDATE public.material_forms SET may_be_sold = CASE code
      WHEN 'loose_cells'   THEN false
      WHEN 'de_cased_cell' THEN false
      WHEN 'anode_sheet'   THEN false
      ELSE true
  END;
  ALTER TABLE public.material_forms ALTER COLUMN may_be_sold SET NOT NULL;
  ```

  列注写着这是**【R5,Tim 的裁定】:法律上允许不允许把这个形态卖给任何人**。

**为什么它与别的变化不同类,三条:**

1. **它是【收紧】,不是放宽。** 13 行里 3 行被判 `false`,而其中 **`loose_cells` 是
   2026-08-22 就存在的老行** —— 它在 **8 天里**从"无判断"变成"法律禁止出售"。
   另两行(`de_cased_cell`、`anode_sheet`)是同一刀新生的,一出生就带着判断,不构成回溯。
2. **它是一条【法律】规则,不是运营规则。** 一个运营规则改错了,料走错一条线;
   一条法律规则回溯适用,**改写的是"我们当时是不是在合法经营"这个问题的答案**。
3. **它被回填到了每一行**,包括那 6 行在裁定作出之前就已存在、并且已经被引用的行。
   【码】`materials.ZZ-SMOKE-NTF`(创建于 **2026-08-13**,早于裁定 **17 天**)
   带 `form_code = 'module'`,今天读出来 `may_be_sold = true` ——
   **一条它被写下来时并不存在的法律判断。**(它是刻意保留的测试残留,
   所以没有商业后果;**但形状是真的**。)

**★ 要知道"哪些形态是什么时候被判的",要付什么代价 ★**

* **从数据库里:不可恢复。** `material_forms` **没有 `created_at`,没有 `updated_at`**
  (见 3.2),`may_be_sold` 没有历史表,`ALTER ... SET NOT NULL` 之后连"曾经是 NULL"
  这个痕迹都没了。**库里今天说的是"这 13 行一直都是这样",而那不是真的。**
* **从仓库里:可以恢复,而且精确。** 两支迁移各自列全了行与裁定
  (`2026-08-22-proc2-…:62–68` 六行;`2026-08-30-procbuild1-…:256–289` 七行 + `CASE`)。
  **分界线是 2026-08-30。**
* **所以准确的说法是:【库不可恢复,仓库可恢复】。** 这也正说明为什么答案是
  写入时快照而不是字典版本化 —— **如果当初被把关的那条记录上带着一个 `decided_under` 戳,
  这件事根本不用去翻迁移。**

**同形但轻得多的第二例(记下来,不单列):** `material_kinds.has_condition_axes`
在 2026-08-22 被 `UPDATE ... WHERE code='battery_material'` 设真 —— 但那是建表**次日**,
在任何真实引用之前,且它是运营规则不是法律规则。**不构成同一件事。**

## 3.5 ★ 决定:写入时快照,不做字典版本化 ★

**形状 —— 在【被把关的那条记录】上盖一个戳,不在字典上开一条时间轴。**

线上两处先例,原样照抄:

* `kpi_entries.source_template_version` → `kpi_position_templates.version`(**钉版本号**)
* `pricing_term_commitments.source_formula_code` / `_name` / `_id`(**反范式快照**)

**该盖在哪:** 一条记录在写入时**被字典的规则列拒绝过或放行过**,就该带上
"我是在哪一版规则下被放行的"。今天符合这个描述的**只有加工单的受理判断**
(`processing_runs` × `operation_type_safety_states`)。

**成本:新表 0,新行 0,新列 1**(`processing_runs` 上一列)。

**但是:【今天不建】。** 【码】0 张加工单带工序类型 → 这一列今天会写进 10 个 NULL,
而**戳的价值完全等于"被把关过的记录数",今天是 0**。
它的正确时刻是 **G7 工序模型真正被使用的那一刻** —— 也就是第一张带工序类型的
真实加工单被提交时,而不是之前。

---

# 四 · ③ 跨模块审计查询

## 4.1 今天记着什么

**【码】没有任何通用审计表。** 有的是 **13 张按模块各长各样的历史/日志表**,
全部带追加式守卫(`guard_*_append_only`):

| 表 | 【码】行数 | 主键的对象 | 行为人列 | 时间列 |
|---|---|---|---|---|
| `approval_log` | 8 | `subject_type` + `subject_id`(多态) | `actor_user_id` | `decided_at` |
| `price_history` | 14 | **`inbound_batch_id`** | `created_by` | `created_at` |
| `purchase_order_history` | 2 | `purchase_order_id` / `_line_id` | `changed_by` | `changed_at` |
| `sales_order_history` | 22 | `sales_order_id` / `_line_id` | `changed_by` | `changed_at` |
| `processing_cost_entry_history` | 7 | `entry_id` + `run_id` | `changed_by` | `changed_at` |
| `quote_history` | 3 | `quote_id` | `changed_by` | `changed_at` |
| `work_order_history` | 2 | `work_order_id` | `changed_by` | `changed_at` |
| `task_history` | 16 | `task_id` | `changed_by` | `changed_at` |
| `customer_credit_history` | 1 | `customer_id` | `changed_by` | `changed_at` |
| `employment_history` | 3 | `employee_id` | `created_by` | `created_at` |
| `sales_attribution_log` | 1 | `sales_record_id` | `attributed_by` | `attributed_at` |
| `traceability_report_issues` | 1 | `output_batch_id` | `issued_by` | `issued_at` |
| `fx_rate_history` / `pricing_formula_history` | 0 / 0 | `fx_rate_id` / `formula_id` | `changed_by` | `changed_at` |

加上 **`inventory_movements`(106 行)** —— 它不是历史表,但它是唯一一条
**逐事件、带批次、带行为人**的台账(`created_by` / `occurred_at`)。

**行为人一律是 `uuid`(`auth.users`),页面靠 `app/components/ActorName.tsx` 显示成人名。**

## 4.2 ★ 不要去接长 `traceability_report_data()` ★

**它是一份【交给客户的证书】,而审计轨迹不是证书。** 两条证据:

* 它有 `/output/[id]/traceability/pdf` 出 PDF,发出去的每一份在
  `traceability_report_issues` 里留 `code` + `version` + `sha256` + `file_path`。
* 它在没有血缘时 **`RAISE EXCEPTION 'NOTHING_TO_REPORT'`**,函数注释写得很清楚:
  **"这时候不能发一份'来源不详'的报告去糊弄审计 —— 空表比空报告诚实"**。

**这个拒绝对一份单据是对的,对一条轨迹是错的。**
审计要的恰恰是"这个批次身上什么都没发生"这个答案本身。
**两者合并的后果,是一份寄给客户的证书开始装内部成本与分录。**

**所以:另起一张只读视图,与它并排,不动它一个字。**

## 4.3 实测:拿 IN-2026-0001 走一遍全链

选它是因为它是**线上链条最长的一个**:【码】10 条流水、被 7 张加工单吃过、
8 个下游产出批、其中 4 个卖掉过。

| 段 | 【码】答得上来吗 | 对象 |
|---|---|---|
| 收货 | ✅ | `inbound_batches` — 到货 2026-06-09,4800,余 887,`created_by = 321f1819…`(Tim) |
| **采购来路** | ❌ **断** | `purchase_order_line_id` **IS NULL** |
| 定价 | ✅ | `price_history` 2 行 |
| 流水 | ⚠️ **半断** | 10 条:`receipt` / `processing_consume` ×6 / `reversal_restore` / `adjustment`;**其中 2 条 `created_by IS NULL`** |
| 加工 | ⚠️ **半断** | 7 张单,**其中 `PROC-2026-0002` 已软删** |
| 成本 | ✅(空) | `batch_processing_cost_allocations` 0 行 —— 真的没分摊过,不是查不到 |
| 血缘 | ✅ | 8 个产出批,`depth = 1`,经 `PROC-2026-0001/0003/0106/0162/0163/0164` |
| 销售 | ✅ | `OUT-2026-0007`×1、`0118`×1、`0185`×2、`0186`×2 = **6 笔** |
| **分录** | ❌ **断**(下详) | `JE-2026-0003` 找得到;**它的冲销 `JE-2026-0004` 找不到** |

## 4.4 ★ 逐条点名:五道缝 ★

**一份藏起自己接缝的轨迹,比一份把接缝画出来的更坏。** 五道,全部实测:

### 缝 1 —— 采购那一端是可选的,而且一半是空的

**【码】16 个未软删进料批里,8 个带 `purchase_order_line_id`,8 个不带。**
`IN-2026-0001` 属于不带的那一半。**"我们当初订的是什么"对一半的批次答不了。**

### 缝 2 —— 11 条流水没有行为人

**【码】106 条流水里 11 条 `created_by IS NULL`**,横跨 5 种类型:
`adjustment`、`processing_consume`、`processing_produce`、`receipt`、`writeoff`。
`IN-2026-0001` 身上占 2 条。

**★ 但这一条【不是】(B),而这个区别很重要 ★** `created_by DEFAULT auth.uid()`
—— 这些 NULL 的成因是**迁移与 fixture 以 `postgres` 身份写入**,不是**人忘了填**。
真实用户经界面写入时它自动填好。**它是测试残留的产物,会随切换自己消失,
没有任何人需要被强迫做任何事。**(**与库位那一格恰好相反,见 5.2。**)

### 缝 3 —— 一次被冲销的加工单,有三份互相不一致的说法

`PROC-2026-0002` 吃过 `IN-2026-0001`,后被软删。今天:

* `processing_inputs` —— **还看得见**那次消耗(不看 `deleted_at`)
* `batch_lineage_all` —— **看不见**(它 `JOIN … AND pr.deleted_at IS NULL`)
* `inventory_movements` —— **两边都看得见**:`processing_consume`(2026-06-11)
  + `reversal_restore`(2026-06-24)

**三个数据源,三种说法。** 轨迹必须挑一个**并且说出自己挑的是哪一个** ——
默认建议挑流水,因为**只有它把"冲销"本身记成了一件发生过的事**。

### 缝 4 —— ★ 分录只能经 15 种多态 `source_type` 够到批次,而没有一种是批次 ★

**【码】`journal_entries.source_type` 的 15 个取值:**
`payment`(13)、`purchase`(10)、`processing_cost`(9)、`sale`(9)、`freight`(8)、
`invoice`(6)、`expense`(6)、`payroll`(4)、`allocation`(3)、`prepayment`(2)、
`revaluation`(2)、`writeoff`(2)、`stocktake`(1)、`shipment`(1)、`credit_note`(1)。
**没有 `inbound_batch`,也没有 `output_batch`。**

更糟的是,**`source_type` 命名的是一个【概念】,不是一张【表】** —— 实测解析:

| `source_type` | `source_id` 实际指向 | 【码】 |
|---|---|---|
| `purchase` | **`inbound_batches`** | 8 |
| `purchase` | **`journal_entries`** ← **同一个 type,第二张表** | 2 |
| `sale` | `sales_records` | 9 |
| `processing_cost` | **`processing_cost_entries`**,**不是** `processing_runs` | 9(`→processing_runs` = **0**) |
| `stocktake` | `stocktakes` | 1 |

**一张按批次 join `source_id` 的轨迹,必须手写 15 条臂,而且其中一条要分叉成两张表。**

### 缝 5 —— ★ 而缝 4 会产出一个"错的好消息",实测到了 ★

【码】`JE-2026-0003`:`source_type='purchase'`,`source_id = IN-2026-0001 的 id`,
**`status = 'reversed'`**。
【码】`JE-2026-0004`:`source_type='purchase'`,`memo = "REVERSAL: Pricing IN-2026-0001"`,
**`source_id = JE-2026-0003 的 id`**。

**于是:一张 `WHERE source_id = 批次.id` 的轨迹看得见那笔过账,看不见它的冲销。**
屏幕上这个批次**看起来还挂着一笔定价分录,而那笔其实已经被冲掉了。**
**这与 AUD-1 是同一个家族的错的好消息**,只是这次长在审计轨迹里。

**恢复得了 —— 但要多走一跳:** `journal_entries.reversed_by` **确实**从
`JE-2026-0003` 指向 `JE-2026-0004`。**轨迹必须知道去跟这一跳。**
**唯一能靠自己认出这条关系的东西,今天是那句英文 `memo`。**

### 顺带:两个更小的洞

* **【码】9 条 `sales_records` 里只有 2 条带 `cogs_entry_id`** ——
  批次 → 销售 → 分录这条路 **7/9 是断的**。
* **13 张历史表的列名互相不一致**:行为人是
  `changed_by` / `created_by` / `actor_user_id` / `attributed_by` / `issued_by` 五种之一;
  时间是 `changed_at` / `created_at` / `decided_at` / `attributed_at` / `issued_at` / `occurred_at`
  六种之一。**一张 union 视图要手写 13 段别名。**
  而且 **13 张里只有 1 张(`price_history`)直接带批次外键** —— 其余全是按单据主键的,
  只能靠遍历够到批次。

## 4.5 成本与形状

**新表 0,新行 0,新视图 2**(照抄 AUD-1 的拆法,**这是硬要求**):

* `batch_audit_trail_all` —— **无判据基视图,不授权给任何人**。
  一条 `UNION ALL`,每段一个 `event_kind`:
  `receipt` / `movement` / `price_change` / `run_input` / `run_output` /
  `cost_allocation` / `stocktake_line` / `sale` / `journal_entry`。
  统一成五列:`batch_kind`、`batch_id`、`occurred_at`、`actor_id`、`event_kind` + 一个 `detail jsonb`。
* `batch_audit_trail` —— **外层带判据**,`security_invoker = off`。
  判据取 **OR**(`module.processing.view` OR `module.inventory.view` OR `module.finance.view`),
  与 `traceability_report_data()` 的 OR 同理:**AND 会让每一个单模块读者拿到零行,
  而零行在这里的意思是"这个批次什么都没发生过"。**

**外加一件不能省的:那五道缝必须【出现在视图里】,不是出现在文档里。**
建议做法:视图带一列 `completeness`,把"无采购来路"「行为人缺失」「有被冲销的加工单」
「分录经多态解析」四种情形逐行标出来。**一条不标出接缝的轨迹,是一份看起来完整的假证据。**

---

# 五 · ④ 盘点抽样

## 5.1 机器全在,只缺选取规则

见 0.1:`stocktakes` / `stocktake_lines` / `post_stocktake()` / 三个页面 / RLS /
硬删守卫 —— **Phase 2 cut 4(2026-07-03)全部建好,而且跑过 4 次。**
`post_stocktake()` 拿点数与**当前** `remaining_qty` 比,差额出 `adjustment` 流水
(【码】`journal_entries` 里有 1 笔 `source_type='stocktake'`)。

**抽样要的是两件:一个【总体】,一个【分层依据】。总体有,分层依据没有。**

## 5.2 ★ 两个测出来的理由,都指向"现在不要建" ★

### 理由一 —— 总体太小,抽样比全盘还贵

**【码】可点的批次:进料 13 + 产出 12 = 25 个**(`remaining_qty > 0`,未软删)。

**25 个的全盘点是一个下午的活。** 抽样要付的额外代价是:一套选取规则、
一张排期、一个"这次抽中哪些"的载体、以及**每次都要向审计解释为什么没点另外那些**。
**在 25 这个数量级上,抽样【花的比省的多】。** 这不是保守,这是算术。

### 理由二 —— ★ 分层依据不存在,而且不是填充率问题,是 schema 问题 ★

**库位挂在【流水】上,不挂在【批次】上。**
【码】带 `location_id` 的表:`inventory_movements`、`sales_order_reservations`、
`shipment_lines`、`storage_location_allowed_classes` + 三张视图。
**`inbound_batches` / `output_batches` 上一列都没有。**

而唯一把库位聚起来的那张视图 **`stock_snapshot` 是【物料 × 库位 × 状态】,
批次身份在聚合里被丢掉了**(`db/views/stock_snapshot.sql`)。

**所以「IN-2026-0001 这批货在哪个库位」不是一个填充率不够的问题 ——
它是一个 schema 答不出来的问题**,抽不抽样都一样。

### ★ 而填充率本身,证明了"让操作员记得"不是一个答案 ★

`stock_snapshot.sql` 的抬头记着 **RPT-1(2026-08-13)** 当天的实测:
**"线上 85 行流水里 79 行没有库位"**(92.9% 空)。

**【码】今天:106 行里 99 行没有库位(93.4% 空)。**

**也就是说 —— 那之后新增的 21 条流水里,有 20 条【仍然】没有库位。**
19 天,一条都没有变好。**这一格不是慢慢在填,它根本没有在填。**
**这就是 (B) 的定义本身,而且是这个仓库里证据最硬的一个 (B)。**

## 5.3 ★ 决定:不建。而且记成【触发条件】,不是【否决】 ★

**两个条件必须【同时】成立,抽样才值得建:**

| 条件 | 今天 | 它是什么性质 |
|---|---|---|
| **① 可点总体大到全盘点不划算** | **25 个** | **填充率/业务量问题** —— 产线开起来自己会到 |
| **② 一个批次【定位得到】** | **答不了** | **★ schema 变更 ★** —— 要么批次上加一列库位,要么由流水推出"当前库位"并让它成为一个可查的东西 |

**★ 第二个条件不会因为产线开起来就自动满足。★**
它需要一次明确的建造决定:**"库存的位置,是批次的属性,还是流水的推论?"**
—— 而那个问题今天没有人问过。**在它被回答之前,抽样连排期都不该排。**

**成本:0。本刀什么都不建。**

---

# 六 · (A) / (B) / (C) 的划分

| 件 | 划分 | 理由(实测) |
|---|---|---|
| **① 全局搜索** | **(A)** | 它搜的是**自动生成的单据号**(`IN-` / `OUT-` / `JE-` …),不依赖任何人填任何格。产线怎么跑都不改变它是对的。**唯一的正确性风险是缺席语义,而那是设计要求不是填充率。** |
| **② 快照戳** | **机制 (A),内容 (C)** | 戳由**施加把关的那段代码自己写**,没有人类参与 → 不是 (B)。但【码】0 张加工单带工序类型 → **今天写进去的全是 NULL**。**它的时刻是 G7 被真正使用的那一刻。** |
| **③ 审计轨迹** | **(A),带两个 (B) 的洞** | 主体 (A):它**只读已经记下来的东西**。<br>**缝 2(11 条无行为人)不是 (B)** —— 见 4.4,那是 `postgres` 身份写入的残留,会自己消失。<br>**缝 1(8/16 无采购来路)是 (B)**。<br>**缝 5(冲销跳一跳)是纯 (A)**,靠 `reversed_by` 就够。 |
| **④ 抽样** | **(C) + 一次 schema 变更** | 见 5.3。**不是"等产线跑起来"那么简单**,第二个条件是建造决定。 |

## 6.1 (B) 的那一项,点名【谁】【什么时刻】【什么强迫他】

**缝 1 —— 进料批没有采购来路(8/16):**

* **谁:** 建进料批的那个人。今天是 Tim;切换后是收货文员。
* **什么时刻:** **收货那一刻**,不是事后。
* **什么强迫他:** **今天什么都没有。** 唯一能强迫的形状是:
  当这批料对应的物料**存在一张未关闭的采购订单行**时,
  `purchase_order_line_id` 变成**必填**(按名拒绝,不是必填星号)。
* **★ 这是一个 Tim 的裁定,不是本刀的活 ★** —— 因为它等于宣布
  **"不带采购单的收货是异常"**,而这个仓库里今天有 8 个反例,
  并且**没有任何人说过它们是错的**。**在裁定之前不要加这个闸。**

**对照组(为什么把这一条与库位分开写):** 库位那一格 19 天里 20/21 没人填(5.2);
采购来路那一格是 8/16 —— **一半的人做对了。** 这两种空是不同的病:
一种是**没人被要求**,另一种是**要求本身还没定**。

---

# 七 · 建议:建多大,先建哪个,谁挡着谁

| 顺位 | 件 | 建多大 | 阻塞在 |
|---|---|---|---|
| **1** | **③ 跨模块审计轨迹** | **一刀,中等。** 2 张视图(AUD-1 拆法)+ 1 个页面 + fixture 钉住"缝要看得见"。新表 0,新行 0 | **不阻塞任何人。今天就能建,今天就有价值。** |
| **2** | **① 全局搜索** | **一刀,小到中等。** 新表 0,新行 0;1 个 `lib/search.ts` + 1 个 `/search` + 复用现成 `*Query.ts` | **建议排在 Phase 8 导航重建【之后】或与它同刀** —— 它要复用 `MODULES` 与 `canEnterModule()`,而那两样正是 Phase 8 要动的东西。**先建会撞一次。** |
| **3** | **② 快照戳** | **★ 现在不要建 ★**,写下规则即可(本文件 3.5)。将来 1 列,新表 0 | **G7 工序模型被真正使用的那一刻。** 今天写进去的是 10 个 NULL |
| **4** | **④ 盘点抽样** | **★ 不建 ★** | **两个条件(5.3),第二个是一次 schema 决定,而那个问题还没有人问过** |

## 7.1 一句话结论,逐件

* **① 建,但排在 Phase 8 之后。** 唯一必须写死在设计里的一条:
  **缺席是界面义务** —— 「无结果」与「未展示」是两句话(2.5)。
  **永远不要把它优化成一张索引**,理由在 2.4,而这个仓库已经为它付过两次账。
* **② 不建机制,建的是【一条被写下来的规则】。** 暴露实测为零,而且每一次
  实测到的变化都是放宽。**唯一的真实例外(`may_be_sold`)是一条被回溯适用的
  法律规则,它库里不可恢复、仓库里可恢复,而它恰恰是快照戳本该拦下的那一个。**
* **③ 建,而且是四件里最该现在建的。** 脊柱已经在,缺的五段都实测出来了,
  **且它不依赖产线跑不跑 —— 它读的是已经写下来的东西。**
* **④ 不建,而且这是四件里最强的一个"现在少建一点"。**
  25 个批次全点一遍比抽样便宜;而它要分层的那个东西,schema 答不出来。

## 7.2 挡在【Tim 的裁定】上的 vs 挡在【产线跑起来】上的

| 挡在什么上 | 哪几条 |
|---|---|
| **Tim 的裁定** | ① 排在 Phase 8 之前还是之后;缝 1 的必填闸(要不要宣布"不带采购单的收货是异常");④ 的第二条件("库存位置是批次的属性,还是流水的推论") |
| **产线跑起来** | ② 的内容(要有带工序类型的真实加工单);④ 的第一条件(可点总体) |
| **谁都不挡** | **③ 全部;① 的技术部分全部** |

