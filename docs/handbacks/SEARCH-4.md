# SEARCH-4 交回 —— 关联单据搜索(2026-09-13)

> **一句话:** 搜 "Acme" 现在返回那条供应商命中,**并且带着它的关联记录** ——
> `进料批 11 · 付款 8 · 采购单 4 · 支出 3` —— 按目标单据种类分组、每组一行一个
> 计数、一行业务数据都没有取回来。关系图由 `pg_constraint` **现算**,没有任何
> 一份手写的关系副本;而"新表必须登记"那道闸也在这一刀里建起来了,并且**故意
> 红过五次**。

---

## 1 · 开工闸

| # | 判据 | 读数 |
|---|---|---|
| 1 | `git status --porcelain` | **空** |
| 2 | 本地 HEAD == `origin/main` == `git ls-remote origin main` | 三者同为 **`6b429327fbec9d765b004ecfe78e3121a189a16d`** ✓ 且等于委托书点名的 `6b42932…` |

---

## 2 · ★ 委托书里的每一个数,开工前当场重量一遍 —— **包括量下来是对的那些**

> 委托书 §1.2:「RE-MEASURE EVERY NUMBER BEFORE RELYING ON IT and report each as
> confirmed or wrong, including the ones that come back right.」

| 委托书说的 | 实测 | 判 |
|---|--:|---|
| **397** FKs | **397**(`pg_constraint contype='f'`,public) | ★ **CONFIRMED** |
| **89** 组单据↔单据 | **89** = 53 直接 + 36 过桥(其中 3 组自对) | ★ **CONFIRMED** |
| **36** 组只存在于桥上 | **36** | ★ **CONFIRMED** |
| **21** 条 XOR 型 CHECK | ★ **19**(`num_nonnulls(…)=1` 14 + `<=1` 3 + `(a IS NULL)<>(b IS NULL)` 2),分布 **19** 张表 | ⚠ **WRONG,而它是一条【判据宽窄】的差**,见 §2.1 |
| **15** 组被作废的桥 | ★ **净减 14 组**(与勘察 §3.3 自己算的 14 一致);**24 条被杀的桥【边】,横跨 20 组** | ⚠ **口径**,见 §2.2 |
| **84 / 162** 缺索引 | **84 / 162**(单据表外键列 67 + 桥表连接列 95;已有索引 78) | ★ **CONFIRMED** |
| **134 / 134** 列级可读 | **134 / 134**,带 5 格正反对照(`employees.identity_no`=f · `work_pass_no`=f · `purchase_order_lines.estimated_unit_price`=f;`employees.id`=t · `purchase_order_lines.material_id`=t) | ★ **CONFIRMED** |
| 一条命中最多 **7** 组 | **7** —— ★ 而这一次是**用真的视图 + 真的函数、对 39 张表 320 行逐行跑出来的**:最多 7 组 / 最多 30 行 / 组数中位数 1 | ★ **CONFIRMED** |
| **4** 张表零关联 | ★ **1 张**(`bank_statements`) | ★ **WRONG —— 而错的是【这一刀的裁定改了它】**,见 §2.3 |
| (另测)39 张单据表合计行数 | **320** | CONFIRMED(勘察 §13 ③ 说的 319 已经是旧的) |
| (另测)Acme = `SUP-2026-0002` | `inbound_batches` **11** · `payments` **8** · `purchase_orders` **4** · `expenses` **3** | CONFIRMED |
| (另测)有 code 列而非单据表 | **36 张**(全库 75 张带 code,39 张在册) | CONFIRMED |

### 2.1 ⚠ 「21 条 XOR」为什么是 19

三条 CHECK 长得像 XOR,而**它们一条桥都作废不了**:

```
equipment_service_intervals_at_least_one  num_nonnulls(interval_kg, interval_days) >= 1   ← 至少一个,两个都有也合法
shift_handover_ack_paired                 num_nonnulls(acknowledged_at, acknowledged_by) <> 1  ← 要么都有要么都没有
shifts_hours_paired                       num_nonnulls(starts_at, ends_at) <> 1                ← 同上
```

`>= 1` 与 `<> 1` **不是互斥**,后者恰恰是"成对出现"。一支把它们收进来的正则会
数出 22 条(我第一版的正则就是),而**下游一条边都不会变** —— 那三张表的那几列
根本不是指向单据表的外键。

☞ **判:数错了,而这个错【没有后果】。** 19 这个数与勘察自己写的「19 张表」对得上,
所以多半是那份报告把 `19 条 / 19 张表` 誊成了 `21 条 / 19 张表`。**照直记,不掩饰。**

### 2.2 ⚠ 「15 组被作废的桥」的口径

* 被 XOR 杀掉的桥**边**:**24 条**,横跨 **20 组**表对;
* 其中**另有别的路活着**的:6 组(`expense_claims↔expenses` · `expenses↔payments` ·
  `expenses↔purchase_orders` · `freight_documents↔inbound_batches` ·
  `inbound_batches↔payments` · `inbound_batches↔purchase_orders`);
* ★ **净减 14 组** —— 与勘察 §3.3 自己算的「净减 14」逐字一致。

勘察写的 15 = 14 + 它自己点名的那一条例外(`expense_claims ↔ expenses`:桥被杀、
直接外键还在)。☞ **数没错,是三个不同的数各被叫成同一个名字。**
本刀在 fixture 103 的 B 臂把这件事钉死了(见 §5)。

### 2.3 ★★「4 张表零关联」→ 1 张,而改变它的是【本刀自己的裁定】

勘察数的是**不含自指边**的可能关联;而委托书 §2 的 **Q4 裁定「显示作废/冲销链」**。
于是:

| 表 | 它的自指边 | 今天算不算"有关联" |
|---|---|---|
| `cash_forecasts` | `superseded_by` | ★ **算** —— 那是作废链 |
| `gst_periods` | `corrects_period_id` | ★ **算** |
| `management_packs` | `superseded_by` | ★ **算** |
| `bank_statements` | (没有) | **不算 —— 全库唯一一张** |

☞ **「4」在勘察写下它的那天是对的,而 Q4 的裁定把它变成了 1。**
一个被抄走的数字,它的判据掉在了原地 —— 这正是 AGENTS.md 记过的那一族,所以
逐条写出来而不是悄悄改掉。★ 而 Q15 的文案不受影响:「这张单据没有关联记录」
对 1 张和对 4 张**同样成立**,也对"有路但今天没有行"的那些成立(组数中位数是 1,
所以那才是常态)。

---

## 3 · 形状 —— 裁定落地成了什么

**一句话,而它是机读的:** 节点 = `document_types` 登记的 39 张表;非单据表只当
边,不当端点。一跳 = 单据 →(0 或 1 张非单据表)→ 单据。

**四条筛子,三条推导、一条声明:**

| # | 筛子 | 推导还是声明 | 实测效果 |
|---|---|---|--:|
| ① | 端点必须登记 | 推导 | 按构造消掉查找表(17 条外键指向 `currencies`)与行表(158 条外键来自非单据表) |
| ② | XOR 型 CHECK 作废假桥 | 推导,**两种写法都认** | 杀 24 条桥边 / 净减 14 组 |
| ③ | ★ 操作人列不是关系(Q5) | 推导 | 见 §3.1 |
| ④ | `document_relation_exceptions` | **声明,6 条,逐条带理由** | 见 §3.2 |

### 3.1 ★★ Q5 落地成了一条判据,而它的【第二半】是承重的

委托书采纳了 Q5「actors are not relations」。落成代码是:

> **一个连接列是【操作人】列,当且仅当 它的名字以 `_by` 结尾(或就是 `user_id`)
> 【并且】它的外键指向 `employees`。**

★ **那个「并且指向 employees」不是装饰 —— 去掉它会当场杀掉 6 条真关系:**

```
assay_results.superseded_by · cash_forecasts.superseded_by
collection_chases.superseded_by · customer_statements.superseded_by
journal_entries.reversed_by · management_packs.superseded_by
```

**六条全都以 `_by` 结尾,而六条全都是 Q4 明写【要显示】的作废/冲销链。**
它们指向的是**同一张单据表**,不是 `employees`。
☞ fixture 103 的 E 臂把这两面一起钉住:操作人边一条都不许在图里,
而 `journal_entries.reversed_by` **必须**在图里。**注入验证过(§5)。**

**这条判据的实测代价:去掉 15 条噪音边,而【一组关系都没少】。**
`employees ↔ tasks` 照样在 —— 它走的是 `task_participants(employee_id, task_id)`
与 `task_history(employee_id, task_id)`,两条都不是 `*_by`。

⚠ **一条【差一点就被它抓到、而我没有扩判据】的列,点名留档:**
`equipment_maintenance.performed_by_employee_id` 指向 `employees`,语义上是
"谁做的维修",但它以 `_id` 结尾,判据认不出来。**我没有为它把判据改宽** ——
为一个语义特例加一条正则,正是那种会长成隐形名单的改法。**它今天在图里,
理由写在这儿,下一刀要动就动得明白。**

### 3.2 声明了哪 6 条,以及为什么键是【边】不是【对】

```
containers.forwarder_id                                     Q10 · LOG-1b
employees.manager_id                                        Q4
purchase_order_lines(asset_id, pricing_formula_id)          Q3 残渣
equipment_maintenance(capitalised_expense_id, expense_id)   Q3 残渣
performance_reviews(employee_id, reviewer_employee_id)      Q3 残渣
shift_handovers(incoming_employee_id, outgoing_employee_id) Q3 残渣
```

★★ **委托书说的是「三组噪音【对】」,而表里写的是六条【边】,这是刻意的。**
勘察 §3.3 的实测教训逐字适用:`expense_claims ↔ expenses` 的桥是假的、直接外键
是真的 —— **一支作用在"对"上的筛子会在这里安静地删掉一条真关系,而没有任何东西
会红。** 所以:

* `employees ↔ employees` 这一【对】由**两条边**产生(考核人、交接班上下家),
  两条各写一行、各带一句理由;
* `expenses ↔ expenses` 这一【对】的桥边被声明作废,而**这一对照样成立** ——
  `expenses.reversed_by_expense` 是真的冲销链。**这正是"筛边不筛对"的现场。**

⚠ 而 `journal_entries ↔ journal_entries` **没有**进例外表:它的两条桥边
(`bank_transfers(journal_entry_id, reversal_entry_id)` ·
`year_closes(closing_journal_id, reversal_journal_id)`)**是冲销关系**,Q4 说显示。

---

## 4 · 交出去的东西

| | 东西 | 形状 |
|---|---|---|
| 迁移 A | `document_type_exceptions`(36 行)· `document_relation_exceptions`(6 行)· `document_relations` **视图** · `search_related()` **函数(INVOKER)** | 纯增量 |
| 迁移 B | ★ **75 条**外键列索引 | 纯增量 |
| 闸 | `scripts/check-document-registry.mjs`(进 `npm run build`)· fixture 102 · fixture 103 | — |
| 应用层 | `lib/search/types.ts` 加 `RelatedGroup` · `records.ts` 取分组、**上限 8 → 5** · `SearchEntry.tsx` 画分组行 | 填已有的槽,**没有第二个面板** |
| 文案 | en + zh:`noRelated` · `relatedOnlyWhatYouCanSee` · **`docType.*` 40 条 × 2** | check-i18n 从登记表现读后缀集合 |
| 探针 | `probe-search-results` 加 R7/R7b/R7c/R7d · `probe-nav-geometry` 加 N18a/b/c(停止条件 g) | — |

### 4.1 ★ 迁移 B 是 **75** 条,不是 84 —— 分母掉了一层

勘察量的 162 列 / 缺 84 条,是在**应用 Q5 与 Q3 之前**量的。裁定落地之后,
`document_relations` 真正走到的连接列是 **148**,其中缺索引 **75**。
差的 9 条逐条点名,**九条全是操作人列(或那条被声明作废的交接班噪音桥)**:

```
shift_handovers.acknowledged_by · shift_handovers.incoming_employee_id ·
shift_handovers.outgoing_employee_id · task_history.changed_by ·
task_nodes.created_by · task_nodes.done_by · task_nodes.updated_by ·
task_participants.added_by · task_participants.removed_by
```

☞ **不建它们的理由不是省事,是"本仓库对『先建着,回头用』付过账"** ——
一条没有消费者的索引不该在这一刀里建。★ **这是一处偏离,连同数一起写在这里。**

### 4.2 ★ 不报的那个数

**一次关联查询要多久,没有量,也不打算量。** 39 张单据表今天 320 行,规划器
一律 Seq Scan;报一个毫秒数就是编一个数。**前三刀都拒绝过,而它们是对的。**
75 条索引建的理由与迁移 A/C 逐字同族:**为将来的体量,不为今天的读数。**

---

## 5 · ★★★ 那道闸(V3)—— 它**红过五次**,每次红在不同的地方

> 委托书:「A gate that has never been red is not a gate.」

`scripts/check-document-registry.mjs`,跑在 `npm run build` 里。
判据照 SEARCH-1 收紧后的 `check-nav-routes` 判据 ② 的形状:
**`db/tables/` 的镜像里每一张有 `code` 列的表,要么在 `document_types`,
要么在 `document_type_exceptions` 里【带一句理由】,否则构建红。**

### 5.1 覆盖断言:**四条,两两独立**

| 断言 | 路 A | 路 B | 今天 |
|---|---|---|--:|
| 表的条数 | 按 `CREATE TABLE public.X (` 切块 | 按 `^CREATE TABLE ` 数行 | **220 = 220** |
| 表的条数(对着声明) | 同上 | `EXPECTED_TABLES` 常量 | **220** |
| 带 code 列的表 | 块内 `^\s+code\s+[a-z]` | 全语料 `^\s+code\s+[a-z]` 行数 | **75 = 75** |
| 两段种子的行数 | 逐行判据正则 | 块内 `^\s*\('` 粗计数 | **40 · 36** |

★ **最后那一条是本判据开工当天自己挣来的:** 第一版的行正则要求行尾是 `),` 或 `);`,
而种子最后一行结尾是 `')`(后面接 `ON CONFLICT`)。于是它少读一行,
**把 `wht_natures` 报成"既没登记也没例外"—— 一条【假的 exit 1】**。
☞ 加上粗计数之后,同一个毛病落在 **exit 2(量具瞎了)**上,而那才是对的分类:
改正则,不是改种子。**两种在屏幕上分不开,而处置完全相反。**

### 5.2 ★ 五次故意的红,连同它自己的退出行

| 注入 | 期待 | 实得 |
|---|---|--:|
| ① 镜像里加一张有 code 列、既没登记也没例外的新表 | 判据 ① 红 | `REGISTRY_OWN_EXIT=1` ✓ |
| ② 把一条例外的 `reason` 抹成空串 | 判据 ③ 红 | `REGISTRY_OWN_EXIT=1` ✓ |
| ③ 删掉一条例外(`tax_codes`) | 判据 ① 红 | `REGISTRY_OWN_EXIT=1` ✓ |
| ④ `EXPECTED_TABLES` 改错一格 | **覆盖断言** 红 | `REGISTRY_OWN_EXIT=2` ✓ |
| ⑤ 例外表里放一条指着【已登记】表的死条目 | `assertAllowlistLive` 红 | `REGISTRY_OWN_EXIT=2` ✓ |
| 全部复原 | 绿 | `REGISTRY_OWN_EXIT=0` ✓ |

⚠ **注入 ② 第一次【没有真的注入进去】** —— 我的 `sed` 模式没匹配上,
脚本照常返回 0,而那个 0 看起来和"通过"一模一样。**是那次注入自带的
`grep -c` 计数(数出 0)把它拆穿的。**
☞ 记在这里,因为它正是这份委托书要防的那一类:**一次没有发生的注入,
与一次被判据放过的注入,在退出码上是同一个字节。** 重做之后它红了。

### 5.3 两支,而它们看的不是同一个东西

| | 看什么 | 抓得住什么 | 抓不住什么 |
|---|---|---|---|
| `scripts/check-document-registry.mjs` | `db/tables/` 的**镜像文本** | 构建期就红,不必连库 | 镜像与线上分家(那是 `check_mirrors.py` 的活) |
| `db/fixtures/102-…` | **真的 `pg_catalog`**,跑在门重建出来的库上 | 镜像文本骗过了正则、而真库里那一列确实存在 | 同上 |

★ fixture 102 还带一格**反面对照**:它往例外表里插一行空理由,断言库里那条
`CHECK (btrim(reason) <> '')` **把它挡回来**。没有这一格,「理由非空」这件事
在 CHECK 被人摘掉的那天照样全绿。

### 5.4 ★ fixture 103:四次注入,四次都红

| 注入 | 哪一臂应当响 | 实得 |
|---|---|---|
| 删掉 `containers.forwarder_id` 那条例外 | 反面对照(Q10) | `FIXTURE 103 失败:containers.forwarder_id 还在图里(2 条)` ✓ |
| 把操作人判据关掉(`WHERE false`) | E 臂 | `FIXTURE 103 失败:30 条【操作人】边混进了关系图` ✓ |
| 删掉 `(a IS NULL)<>(b IS NULL)` 那一支解析 | A 臂 | `FIXTURE 103 失败:inbound_batches ↔ output_batches 还在图里(4 条边)` ✓ |
| (102)删掉一条例外 | 判据 ① | `FIXTURE 102 失败:1 张有 code 列的表既没登记也没例外:tax_codes` ✓ |

☞ **四条断言都证明了它们真的在断言**,而不是四句没被求值的话。

---

## 6 · ★ 偏离委托书的地方,逐条 —— **连理由一起**

> 委托书:「YOUR OWN RECOMMENDATIONS IN §10 ARE ADOPTED unless this block says
> otherwise. Follow them, and report in the handback anywhere you departed and why.」

| # | 委托书/建议说的 | 我做的 | 为什么 |
|---|---|---|---|
| ① | Q8:「Inbound batches 8 **(some you cannot see)**」——挂在**那一行**上 | 挂在**整节**上:「这些计数只算你看得见的那些」 | ★ 按行说要先判定某一类的策略是在闸【之内】收窄还是在闸【之外】放宽。**实测 8 张单据表的 SELECT 谓词含闸以外的东西,而其中 4 张(`employees`/`expense_claims`/`leave_requests`/`medical_claims`)是 `OR 本人` 的【放宽】—— 持闸的人一行都不少看。** 一个会在【沉默那一侧】判错的标记,正好把 Q8 要防的那个缺陷原样再发一次。☞ 整节那一句**永远成立**,而且一个字的代价 |
| ② | 「The shape is 『Inbound batches 11 →』」 | 分组行**不是链接**,没有箭头 | 一条「进料批 11」要链去哪?目标列表页的 `?q=` 过滤的是**单据号**,没有"这个供应商的进料批"这个地址;链到未过滤的列表就是 `records.ts` 抬头点名拒绝过的「差不多的地方」。而在下拉里就地展开是第二个面板的活,委托书明写不开。☞ **「rows are fetched only if opened」那一半照做了:一行业务数据都没取回来** |
| ③ | 迁移「the 84 indexes」 | **75 条** | 分母掉了一层,九条差额逐条点名(§4.1),九条全是操作人列 |
| ④ | 「21 XOR CHECKs」 | 判据认 **19** 条 | `>= 1` 与 `<> 1` 不是互斥,收进来一条桥都不作废(§2.1) |
| ⑤ | 「4 tables with zero relations」 | **1 张** | Q4 裁定「显示作废链」把另外三张变成了有关联(§2.3)。**Q15 的文案不变,对两个数都成立** |
| ⑥ | Q5「actors are not relations」 | 判据是 `_by$|user_id$` **并且指向 employees** | 少了后半句会杀掉 6 条真的作废/冲销链(§3.1) |
| ⑦ | Q3「三组噪音【对】进例外表」 | 六条【边】进例外表 | 筛边不筛对 —— 筛对会安静地删掉 `expenses.reversed_by_expense`(§3.2) |

---

## 7 · ★ 一个计数本身就是一次披露 —— **这次交换要留档,不许下一刀重新推一遍**

> 委托书 V2 / Q9:「⚠ RECORD THE EXCHANGE in the handback — that a count is itself
> a disclosure, that this was put to Tim explicitly, and that he ruled counts are given.
> A later UAT question must not have to re-derive it.」

**被问到的那件事,逐字:**

> `employees` 有 10 类关联目标,其中两类是 `medical_claims` 与 `leave_requests`,
> 两者的闸都是 `module.hr.view`。屏幕上一行「EMP-2026-0003 · 病假申报 2 条」——
> **不用打开任何一条,你已经知道这个人报过病。**
> 勘察拒绝给这一条建议,理由是:它不是「搜索比页面松不松」,它是
> **「一个计数本身算不算一次披露」**,而这套系统对后者还没有过裁定。

**Tim 的裁定:计数照给,包括 `employees → medical_claims` 与
`employees → leave_requests`。**

**他给的理由,而这条理由管着这一族的每一个问题:**

> **一个持有 `module.hr.view` 的读者在页面上本来就看得见那张列表,
> 而搜索【永远不比它指向的那一页更严】。**

☞ 三件事因此被钉住,写下来是为了下一份委托书不必重推:

1. **「计数是披露」这个命题成立** —— 它不是一次显示细节。承认它,然后裁它。
2. **裁的方向是"给"**,而依据是 *搜索 ≤ 页面* 这条总裁定 —— 不是"数字比内容轻"。
3. ★ **它与 SEARCH-2 §2.3 那次(`identity_no`)【方向一致但依据不同】**:
   那一次的遮蔽**写在 GRANT 里**,推得出来;而「有没有病假」推不出来 ——
   持闸的人在页面上本来就看得见。**所以那一次是显示裁定,这一次是披露裁定。**

⚠ **而它落地成了什么:什么都没做。** 关联图里**没有**一条按单据种类过滤的分支,
因为裁定是"给"。★ 这一行很重要:**一个"不用改代码"的裁定,在树里留不下任何痕迹**
—— 它只活在这份报告里,而这正是委托书要求记下来的原因。

---

## 8 · 权限:没有加任何新授权,而这是量出来的

| | 读数 |
|---|--:|
| 关联计数要读的列(桥表连接列 95 + 单据表 `id` 39) | **134** |
| `authenticated` 列级 SELECT 拿得到的 | **134 / 134** |
| 正面对照(必须是 t) | `employees.id` · `purchase_order_lines.material_id` |
| ★ 反面对照(必须是 f) | `employees.identity_no` · `employees.work_pass_no` · `purchase_order_lines.estimated_unit_price` |

★ **没有反面对照,"全绿"可能只是那支函数恒真。**

**身份:`search_related()` 是 INVOKER(Q13)。** 它数的是「**你**看得见几条」,
而那正是 RLS 天然回答的问题。`search_documents_withheld()` 仍然是 DEFINER ——
「你**看不见**几条」RLS 按构造答不了。**两支函数,两种身份,没有合并。**

### 8.1 ★ 门当场抓到的一处 —— 而它是本刀最有价值的那一次红

`db/gate.py --offline` 第一次跑就红了:

```
迁移前相位:✗ 1 个 fixture 失败:
   196-…: B1 失败:匿名请求从 337 个关系里读到了行:document_relations(254)
GATE_EXIT=4
```

☞ **而线上实测 anon 【拿不到】这张视图** —— `pg_default_acl` 里 `postgres` 在
`public` 上给视图的默认权限**不含 anon**。**重建出来的那个库里含。两处不是同一份。**

★ **这不是"门误报",这是门抓到了一件真事:我的视图靠的是【环境的默认权限】,
而不是一句自己写下的收口。** 而 `db/views/collection_promise_status.sql` 早把这一课
写下来了,逐字可抄:**「一条只住在迁移里的 REVOKE,重建出来的库【是开着的】。」**

**处置:三条 `REVOKE ALL … FROM anon` 写进【镜像】**(视图 + 两张例外表),
于是线上与重建两边都收口。★ 视图没有 RLS —— 两张表有策略挡着,**这张只有 GRANT 这一层**。

**同一条推理再走一遍,落在函数上:** 实测线上五支 `search_*` 的 `proacl` 都是
`postgres | authenticated | service_role`(没有 PUBLIC),所以 `search_related`
**多半**不写也对。**而"多半"正是刚刚栽跤的那个词**,所以迁移里显式写了
`REVOKE EXECUTE … FROM PUBLIC, anon` + `GRANT … TO authenticated, service_role`;
重建那一侧由 `db/views/zzz_function_grants.sql` 原样兜底(镜像里不写第二遍)。

---

## 9 · ★ 破窗 —— 必填字段,而它这次是【良性】的

> 委托书 §4:「FILL IN THE FIELD with what was actually true. Do not leave it blank,
> do not write "none", and do not reuse SEARCH-3's "the window was never opened".」

**窗口开在哪一刻:** `db/apply_migration.sh` 提交迁移 A 的时刻(脚本自己打的时间戳)。
**窗口关在哪一刻:** Vercel 部署 `state=success` —— ★ **那一端的读数从 Tim 那里来**,
这台机器够不到 Vercel(AGENTS.md 的常设规矩)。

**期间生产上是什么状态,以及【什么是坏的】:**

| | |
|---|---|
| 生产跑的 | **旧代码 + 新库** |
| 新库多出来的 | 2 张表 · 1 张视图 · 1 支函数 · 75 条索引 —— **全是新对象,一个现有对象都没改** |
| ★ 旧代码碰得到它们吗 | **碰不到。** 部署在跑的那一版 `lib/search/records.ts` 里**没有** `search_related` 这个字符串,`document_relations` 同理。RPC 名对不上就不会被调用 |
| ★ 期间【什么是坏的】 | ★ **没有。** 这是迁移 A / C / D 那一族(纯增量),**不是迁移 B 那一族**(B 改过现有函数的返回类型,于是旧调用方当场错) |
| 时长 | 见 §12 —— 迁移那一端已经量到,部署那一端等 Tim |

⚠ **而窗口里【确实】发生了一件不得不发生的事,照直说:**
`lib/database.types.ts` 是从**线上**生成的,所以 `npx tsc --noEmit` 与
`npm run build` **只能在迁移之后跑** —— 一支还不存在的 RPC,类型里就没有它的名字。
☞ 于是 build 与整门都落在窗口里面。**这与 AGENTS.md 的「code first, migrate last」
不冲突:除了这一步,别的都在迁移前做完了**(闸红过五次、文案、探针、
`gate.py --offline` 绿、改前 drift 读数)。窗口因此是"build + 整门 + 探针"这一段,
而不是"从头到尾"。

---

## 10 · ★ 屏幕上的形状,以及它为什么长这样

```
单据
  SUP-2026-0002  Acme Battery Recycling Pte Ltd        Purchasing
     进料批 11   付款 8   采购单 4   支出 3
  ⋯
  这些计数只算你看得见的那些。
```

**外层 5 条(8 → 5),内层按目标单据种类分组、每组一行、不展开行。**

| | 实测 |
|---|--:|
| 一条命中最多几组 | **7**(`materials` / `employees` 各有一条) |
| 组数中位数 | **1** |
| 一条命中最多带出几行(若展开) | **30** |
| 最坏的下拉 | 5 × 7 = **35 行分组行** |
| 若按【每条外键】而不是按目标种类分组 | 一条命中最多 **24** 组 ⇒ 8 × 24 = **192 行** |
| 若不动上限 8 | 8 × 7 = **56 行** |

☞ **「按目标单据种类去重」把最坏情况从 24 组压到 7 组**,而且它读起来才是人话:
「3 个任务」,不是「1 个 owner_id、2 个 task_history、3 个 task_nodes、…」。

**零关联那一格:** 「这张单据没有关联记录。」 —— **不许写"还没建"**。
SEARCH-3 刚刚为了同一条理由删掉 `records.built` 与 `search.recordsNotBuiltYet`。
⚠ 而这一句对**两种空**都成立,而且第二种才是常态:
① 结构上就没有关联(今天 1 张:`bank_statements`);
② 有关联的路,今天一条关联记录都没有(组数中位数 1)。

**40 条单据种类的名字,而它们【不能】复用导航标签:**
40 个 key 只有 **33 条不同的 route** —— `/inbound` 同时是化验单与进料批,
`/output` 同时是销毁证书、产出批与追溯报告,`/finance/payments` 同时是付款与收款。
拿 route 当名字,那几组会显示成同一个词。
☞ 于是 40 条 × 2 语言,**而后缀集合由 `check-i18n` 从
`db/tables/document_types.sql` 的种子现读**(MANIFEST 的 `'search.docType.'`)——
加一种单据而少一句译文当场红,不会在屏幕上画一个空标签。

---

## 11 · 立案的、没做的、以及量不到的

| | |
|---|---|
| **Q11 · 多态列** | ★ **这一刀不进,已立案为一条 (ii) 类声明。** 4 对多态列(`approval_log.subject_type` · `journal_entries.source_type` · `collection_chase_documents.subject_type` · `notifications.subject_type`)各带着一条枚举合法取值的 CHECK,**是机读的**;真正谁也看不见的只是「类型串 → 表名」那张映射(`'purchase_order' → purchase_orders` 推得出,`'purchase' → ?` 推不出) |
| **策略谓词的按行析取** | SEARCH-2b §14 已经立案并命名,比这一刀大。本刀在屏幕上把它说出来了(§6 ①),没有修它 |
| ★ **`equipment_maintenance.performed_by_employee_id`** | 语义上是操作人,而判据认不出来(它以 `_id` 结尾)。**没有为它扩判据**,理由在 §3.1 |
| ★ **每条查询的延迟** | **没有量,也不打算量**(320 行,一律 Seq Scan) |
| ★ **`app/` 里"只写在 TypeScript 里的 join"** | 勘察没有普查,本刀也没有。勘察给的是一条**上界论证**(键的空间被两张表穷举),**不是一次测量** —— 原样转录,不升格 |
| ⚠ **`operations` 角色已退休** | AGENTS.md 的 `--reach` 那一节仍列它为三角色之一。**第四次登记**,处置由人决定 |
| ⚠ **两份陈旧的 `.INCOMPLETE` 备份** | `~/evoltrya-backups/` 里躺着 2026-09-01 与 2026-09-06 两个 0 字节的 `.INCOMPLETE` —— **不是本刀造成的**,但它说明备份中途死过两次而没有人清。点名留档 |

---

## 12 · 验证 —— 每一条都报**脚本自己的那一行退出码**

| 量具 | 读数 |
|---|---|
| `npx tsc --noEmit` | `TSC_OWN_EXIT=0` |
| `npm run build`(28 支静态检查 + `next build`) | `BUILD_OWN_EXIT=0` · `BUILD_ID=BETcm120_a8HRawkreTO4` |
| `db/gate.py --offline`(迁移前相位) | ★ 第一次 **`GATE_EXIT=4`**(见 §8.1,它抓到了真东西)· 修好后 **`GATE_EXIT=0`**(46s) |
| 备份闸 | `TOC 5708 条(上一份 5675,下限 5107)✓` · `pg_restore --list` 读出 5723 行 · `evoltrya-backup-2026-09-13-2317.dump` |
| `db/apply_migration.sh` A | `✓ committed atomically` · 破窗起点 **2026-09-13T23:55:21+0800** |
| `db/apply_migration.sh` B | `✓ committed atomically` · 2026-09-13T23:56:14+0800 |
| `db/gate.py` 整门 | ★ 第一次 **`GATE_EXIT=1`**(50 处镜像漂移,全是那 75 条新索引)· 补齐 50 个表镜像后 **`GATE_EXIT=0`**(514s) |
| ┗ 三个判词 | 可重建性 ✓ · 镜像 vs 线上 ✓ · 行为断言 ✓ · 匿名面 ✓(线上 anon 够得着的函数只有 `cod_verification`) |
| `scripts/check-document-registry.mjs` | `REGISTRY_OWN_EXIT=0` —— 且**故意红过五次**(§5.2) |
| `scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `scripts/check-search-registry.mjs` | `SEARCHREG_OWN_EXIT=0` · 两条路各读到 40/40 行 |
| `scripts/probe-search-results.mjs` | `PROBE_SEARCH_OWN_EXIT=0` —— **15 格,0 红** · `BUILD_ID=jzQJwuY2ucRH33jAOtQzI` |
| `scripts/probe-nav-geometry.mjs` | `PROBE_NAV_OWN_EXIT=0` —— **27 格,0 红** · `BUILD_ID=BETcm120_a8HRawkreTO4` |
| `scripts/probe-brand-sampler.mjs` | `PROBE_BRAND_OWN_EXIT=0` · `BUILD_ID=BETcm120_a8HRawkreTO4` |
| `scripts/smoke-routes.mjs` | `SMOKE_EXIT=0` —— 223 条路由,合计 682.8s,中位数 2848ms |
| `survey-controls --mode=drift` 改前 | `DRIFT_EXIT=0`(3,228,305 B) |
| `survey-controls --mode=drift` 改后 | `DRIFT_EXIT=0`(3,228,238 B) |
| `scripts/check-stop-rules-abc.mjs` | `ABC_OWN_EXIT=0` |

### 12.1 ★ 那一格 Acme,它**真的找到了东西**

```
✓ R7.a-hit-carries-its-grouped-relations
  搜「Acme」→ 命中 1 条 · SUP-2026-0002 带 4 组:
  inbound_batch 11 · payment_out 8 · purchase_order 4 · expense 3
  · 现读期望 {"inbound_batches":11,"payments":8,"purchase_orders":4,"expenses":3}
```

★ **那四个期望值是探针在跑的时候从 REST 现读的,不是写死的**(SEARCH-3 的 R3 教训)。
两条路不共用代码:屏幕那一侧走 admin 会话 + `search_related()`,期望值那一侧走
service role + REST 计数。

### 12.2 ⚠ **两次把"没量到"当成"通过"的未遂,都记下来**

1. **改前 drift 第一版拿到的是一份【11 号的旧文件】。** 脚本先 `npm run build`
   再跑 drift —— 而 `survey-controls --mode=drift` 跑在 `next dev` 上,
   **`.next` 里有生产构建它就拒绝开跑**(两支探针前提相反的同一族)。
   它 `DRIFT_EXIT=2` 退出,而我的 `cp` 照样把**上一刀留下的** 85,772 B 文件
   复制成了"改前读数"。☞ 是那个**文件大小**拆穿的(真读数 3.2 MB)。
   处置:`rm -rf .next` + 先删旧文件再跑,重来一趟。
2. **注入 ② 第一次没有真的注入进去**(§5.2)。

☞ 两次是同一个形状:**一次没有发生的测量,与一次通过的测量,在退出码上是同一个字节。**

---

## 13 · 停止条件,逐条

| | 判据 | 读数 |
|---|---|---|
| **(a)** | 390px 上本来 0 溢出的路由升到 0 以上 | ★ **没有。** `ABC_OWN_EXIT=0`,281 组路由×视口 · 181 张表 · 643 次字段比较 |
| **(b)** | 本来就在溢出的那几条长大 | ★ **没有** —— 而**只比对到 4 条,不是 5 条**,见 §13.1 |
| **(c)** | 不横滚的表开始横滚 / 横滚的范围变大 | ★ **没有** |
| **(d)** | S2 的封存产物未变 | ★ **一个字节都没动** —— `control-style.ts` · `input.tsx` · `textarea.tsx` · `globals.css` · `table-style.ts` 都不在 `git diff --stat` 里 |
| **(e)** | `/brand-sampler` 未变 | ★ **860 渲染 / 903 计数**,两个视口都是 —— 与基线逐字相同。★ **量在 `next start` 上**(探针要求 `.next/BUILD_ID` 存在) |
| **(f)** | 顶栏自己的盒子 | ★ **逐条相同:** `1280x53` · `390x55` · nav 字段 `200x32` · 首页入口 `358x49.02`@390 与 `544x53.63`@1280 |
| ★ **(g)** | **下拉自己的高度** | ★ **没踩,而且理由比"今天装得下"更硬** —— 见 §13.2 |

### 13.1 ⚠ (b) 的五条里,**一条两侧都没量到** —— 不许算成"没变"

```
改前就在溢出的:4 组
  phone|/operation/processing/new = 177px
  phone|/purchasing/payment-terms/new = 143px
  phone|/sales/orders/new = 8px
  phone|/tools/pricing/metal-prices/bulk = 24px
⚠ 只有一侧量到、因此【不作数】的:1 组
  · phone /finance/freight/new:(改前 failed · 改后 failed)—— 这一格【不作数】,不是"没变"
```

★ **`/finance/freight/new`(基线 27px)在改前与改后【两趟都把渲染器卡死了】**,
报错逐字相同:`renderer wedged: CDP timeout: Runtime.evaluate (ready=null)`。

☞ **两件事要分开说:**
* **不是这一刀弄的** —— 同一条路由、同一条报错、在**改前那趟(HEAD 的树)**就已经发生;
* **但它确实意味着 (b) 对这条路由今天【没有被验证】。** 比对器拒绝把它算成"没变",
  而那是对的 —— 委托书要的正是这条纪律。**报成"(b) 全绿"是不诚实的:
  是 4/5 绿,第 5 条没有主语。**
⚠ 立案:那条路由在 `next dev` 上稳定卡死渲染器,而它在 `smoke-routes`
(跑在 `next start` 上)里 **HTTP 200**。两个服务器上表现不同,值得有人看一眼。

### 13.2 ★★ (g):下拉**按构造**跑不出屏幕底下,而这是量出来的

**刺激用了两个,而第二个是量出来的、不是挑的:**
委托书点名的 `Acme` 今天只有 **1 条命中 / 4 个分组行** —— 拿它量 (g) 会得出一个
好看却没有判别力的读数。于是对着线上把 14 个候选查询逐个跑过
`search_documents(q,5)` + `search_related()`,取"命中行 + 分组行"最大的那个:

```
in  5 命中 / 16 组 = 21 行   ← 用它
o   5 / 16 = 21 · PO 5 / 13 = 18 · e 5 / 12 = 17 · SUP 5 / 11 = 16 · Acme 1 / 4 = 5
```

**九格读数(三个位置 × 空查询 / Acme / in):**

| 位置 | 空查询 | 「Acme」 | ★「in」(今天最高) | 跑出底下 |
|---|--:|--:|--:|--:|
| 1280 顶栏 | h=282 | h=262 | **h=834** bottom=884 | **false** |
| 390 首页 | h=358 | h=332 | **h=497.94** bottom=884 | **false** |
| 1280 首页 | h=282 | h=262 | **h=452.02** bottom=884 | **false** |

★ **三个位置的 bottom 都正好停在 884 = 视口 900 − 16px 边距** —— 那不是巧合,
是 `place()` 写的 `maxHeight = vh - top - 16`。**下拉被夹在视口里,按构造。**

★★ **而"夹住"只有在它【真的会滚】的时候才是好消息** —— 一个夹住了却不滚的面板
把结果安静地裁掉,**而它在"跑出底下=false"那一格上和一个装得下的面板长得一模一样。**
于是加了 N18d:

```
✓ N18d.a-clamped-dropdown-scrolls 被夹住的 3 格:
  1280 顶栏「in」(内容 1446 > 可视 832,overflow-y=auto) ·
  390 首页「in」(内容 1716 > 可视 496,overflow-y=auto) ·
  1280 首页「in」(内容 1348 > 可视 450,overflow-y=auto)
```

★★★ **这一刀自己给下拉加了多高 —— 逐格量了,因为 1716 这个数会被读错:**

| 位置 · 查询 | 内容总高 | ★ 本刀加的 | 几块 / 几组 |
|---|--:|--:|--:|
| 390 首页 · 空 | 356 | **0** | 0 / 0 |
| 390 首页 · Acme | 330 | **34px** | 1 / 4 |
| ★ 390 首页 · in | 1716 | ★ **116px** | 5 / 16 |
| 1280 顶栏 · in | 1446 | **98px** | 5 / 16 |
| 1280 首页 · in | 1348 | **80px** | 5 / 16 |

☞ **1716 里本刀只占 116** —— 其余 1600 是"两个字符的查询本来就会匹配一大片
页面与手册段落"。**没有这一栏,那个 1716 会被读成本刀的账。**
⚠ 而 **116px 是今天的数据能到的最高,不是结构上的最坏**(5 × 7 = 35 行分组行)。
两个数都报,不拿前者冒充后者。

---

## 14 · 价钱,实测

| | 读数 |
|---|--:|
| `db/gate.py --offline` | **46s** ×2 |
| `db/gate.py` 整门 | **514s** ×2 |
| `smoke-routes.mjs` | **682.8s** |
| `survey-controls --mode=drift` | 改前 + 改后各一趟 |
| `npm run build`(冷) | ×3 |
| 备份 | 一趟(★ 这一台机器上**比平时慢很多**,见下) |
| 四支探针 | `probe-nav-geometry` 跑了 **4 趟**(每加一格读数就重跑) |

⚠ **一条关于这台机器的实测,记下来给下一刀:**
**这个后台会话在两次工具调用之间会让机器睡过去。** 实测:同一次 `pg_dump`,
在我"等待"的二十分钟里只前进了 20 KB;而当一条前台命令把机器按醒之后,
drift 在 110 秒里走完了 20 条路由。
☞ **处置:长活要么用短的前台轮询把机器按醒,要么就认下那个墙钟。**
★ 而 `nohup … & disown` **不够** —— 一条前台命令超时被杀时,
带走了同一个进程组里那趟已经跑到 120/141 的 drift(`(cmd &)` 子 shell 里起才活下来)。
**这一条与记忆里那句「长活要 nohup + disown」是同一族,而它更严:
进程组才是那把刀的单位。**

---

## 15 · 等什么

**等 Tim 确认部署。** 这台机器够不到 Vercel(AGENTS.md 的常设规矩:一刀的终端活到推送为止)。

★ **破窗那一行的终点要 Tim 给:** 起点是 **2026-09-13T23:55:21+0800**
(`db/migration-windows.tsv` 里落着),终点是部署 `state=success` 的时刻。
**期间生产跑旧代码 + 新库,而【什么都没坏】** —— 两支迁移纯增量,
部署在跑的那一版代码里连 `search_related` 这个字符串都没有(§9)。
