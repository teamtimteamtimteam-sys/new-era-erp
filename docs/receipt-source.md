# 收货来源(RECV-SOURCE-1,2026-09-01)

**一张收货必须说得出它从哪来 —— 采购行,或一个具名理由,永远不许两者皆无。**
建于 `HEAD = 102eaa9`(AUDIT-1)之上。所有【码】均为 2026-09-01 当日线上实测。

> 缺陷从来不是"没有 PO 的收货" —— 客户退货、免费样品、盘盈、(将来)来料加工
> 都是【正当地】没有采购单的收货。缺陷是 **"本来就不该有 PO"与"没人填"在
> 数据里一模一样**(EFF-0 §4.4 缝 1 量的:16 个未软删进料批,8 个不带采购行),
> 而这一次它长在审计轨迹的第一环:这批料从哪来。

---

## 一 · Tim 的裁定(已结,不再重开)

| # | 裁定 | 落在哪 |
|---|---|---|
| R1 | 收货时必须给出【采购行 或 字典理由】之一,永不两者皆无。**至少其一,不互斥**(对着采购单又附送样品是现实);规则钉在 `purchase_order_line_id` 上 —— 只挂单头说不出对着哪一行,不算答案 | `guard_receipt_source_stated`(触发器) |
| R2 | 理由字典是【可扩展的数据】,播 4 行(return / sample / stocktake_gain / other);第五个理由是一行,不是一次改码 | `inbound_source_reasons`(RUNTIME CONFIG,已登进 `/settings/dictionaries`) |
| R3 | "other" 必须带书面说明 —— 由**规则列** `requires_explanation` 执行,不是写死的 `code = 'other'`(否则"第五个也要说明的理由"变成改码,R2 与 R3 打架) | 同一触发器读字典 |
| R4 | 既有 8 张不回填 —— 猜一个理由是伪造历史。它们留着、屏幕上读作【未说明】(琥珀),永远不是空白格、不是默认理由 | 触发器只拒 INSERT + 拒【由有变无】 |
| R5 | 拒绝在服务端 —— 触发器在库里,postgres / service_role 直插(rolbypassrls,RPC 与 RLS 都够不到的那条路)一样被拒 | 同上;fixture 184 B1 臂钉住 |

### ★ 一次被接受的推翻:brief 点名的 `CHECK … NOT VALID` 是错的形状 ★

NOT VALID 对 **UPDATE 也强制**,而本表有**七个**函数会 UPDATE 它
(`commit_processing_run` / `rollback_processing_run` / `apply_assay_result` /
`reprice_inbound_batch` / `reprice_from_committed_terms` / `post_stocktake` /
`soft_delete_inbound_batch`),IN-2026-0001 此刻正在加工中(余 887kg)。
NOT VALID 会让那 8 张**加工不了、化验不了、改价不了、注销不了**,直到有人给它们
编一个理由 —— 把 R4 的"留着不说明"改写成"留着不能用",亲手制造 R4 禁止的回填
压力。这笔账仓库付过:`materials_kind_stated` 至今冻着 **7 行**(assay_results
的表注为同一件事把"必填"从 NOT VALID 改成了触发器,PROC-5)。
本刀照抄本表自己的先例 `guard_arrival_date_not_cleared`:**只拒 INSERT +
拒【由有变无】,历史的缺失活着、而且照样改得动**。fixture 184 的 E 臂专门钉
"历史行仍然改得动" —— 只钉"新行被拒"的话,一个 NOT VALID 的实现也能通过。

---

## 二 · 字典(R2/R3)

`inbound_source_reasons` —— RUNTIME CONFIG(check_mirrors 不逐行比对),
编辑权 `module.inbound.edit`,已登进 `/settings/dictionaries`
(`app/settings/dictionaries/registry.ts`)。

| code | zh | requires_explanation |
|---|---|---|
| return | 客户退货 | 否 |
| sample | 免费样品 | 否 |
| stocktake_gain | 盘盈 | 否 |
| other | 其他 | **是**(R3) |

**与 `material_sources` 不是同一张表,不设外键,永远不要"统一"。** 基数就不对:
那张答"这一【种】物料从哪来"(物料种类的属性,含 `customer_return` 一值),
本表答"这一【张】收货为什么没挂采购行"(这一票货的属性)。一种厂内边角料的货
完全可以以盘盈的方式出现在收货台上。论证原文在两张表的表注上。

**登记缺口的更正:** `material_sources` 与 `loss_categories` 当年**没有**登进
DICT-ADMIN 的 registry —— 那是那两刀的缺口,**不是先例**。R2 的全部意义是
"第五个理由不需要工程师",而一张没登记的字典在实践里需要一个拿着 psql 的工程师。
本表照 registry 抬头那句"加一张新字典 = 在这里加一条"做了;那两张的补登记留给
它们自己的刀。

---

## 三 · 建批路径(2a),逐条与覆盖

【码】`pg_proc` 里 INSERT 本表的函数恰好两个;第三条路是角色属性,不是代码。

| # | 路径 | 谁走它 | 规则够到吗 |
|---|---|---|---|
| 1 | `create_inbound_batch()`(DEFINER) | `/inbound/new` | ✅ 触发器(RPC 原样透传参数,不抄判断) |
| 2 | `receive_inbound_batch_against_po()`(DEFINER;名字带 PO,但 `p_purchase_order_id DEFAULT NULL`,**它也建无单批**) | `/inbound/receive` | ✅ 同上 |
| 3 | postgres / `service_role` 直插(迁移、fixture、Management API、`lib/supabase/admin.ts`;两者 `rolbypassrls`) | 脚本与运维 | ✅ 触发器对它们照样开火(fixture 184 B1) |

`authenticated` 的 REST 直插不是一条路:本表 RLS 开、无 INSERT 策略(IOD-1b,
刻意),fixture 58 F 臂持续钉着 —— 本刀给那一臂的插入补了理由,让 RLS 仍然是
那一臂唯一被测的东西。

**具名拒绝清单**(全部进了 `purchasing.errors.*` 文案):
`RECEIPT_SOURCE_REQUIRED`(两者皆无;UPDATE 侧同名带批号 = 不许由有改无)、
`SOURCE_REASON_EXPLANATION_REQUIRED|理由码`(R3)、
`SOURCE_PROVENANCE_REQUIRED|批号`(事后补理由必须走门盖章)、
`SOURCE_PROVENANCE_NOT_AT_INTAKE`(当场的理由不许冒充事后记录)、
`PO_HEADER_WITHOUT_LINE|批号`(A3 顺手落的第二道闸:只挂单头不挂行,自己的
拒绝,不混进来源规则;线上实测 0 行,今天免费,以后不可能)。

---

## 四 · 那"八张"的处置(2b)—— 诚实的说法是 7 + 1 + 6

线上 `purchase_order_id IS NULL` 共 **14** 行;裁定在结构上盖住全部 14
(谁都不回填、谁都不冻),但账要分开记:

**七张业务收货(未软删,R4 的主角):**

| code | 供应商 | 物料 | 到货 | 量 | 阶段 |
|---|---|---|---|---|---|
| IN-2026-0001 | SUP-2026-0003 | NMC Cathode Foil | 2026-06-09 | 4800kg | 加工中 |
| IN-2026-0002 | SUP-2026-0002 | Special Battery Material | — | 100kg | 待加工 |
| IN-2026-0003 | SUP-2026-0003 | Special Battery Material | — | 50kg | 待加工 |
| IN-2026-0011 | SUP-2026-0002 | NMC Cathode Foil | — | 14kg | 已加工完 |
| IN-2026-0012 | SUP-2026-0002 | Special Battery Material | 2026-07-03 | 50kg | 待加工 |
| IN-2026-0153 | SUP-2026-0003 | Special Battery Material | — | 680kg | 已加工完 |
| IN-2026-0258 | SUP-2026-0002 | NMC Cathode Foil | 2026-08-13 | 1kg | 待加工 |

**系统里没有任何东西暗示它们为什么没有单**:notes 全空、declared_qty 全空、
created_by 全是 Tim、供应商全是真的供货商(recycler/dismantler/trader)——
不是退货或样品的形状;其中五张早于 PO 模块本身(cut 4a,2026-07-31)。
最诚实的读法就是"当时可以不填,没人填" —— 这正是 R4 说猜不得的理由。

**一张具名 scratch(未软删):** `ZZ-PROCCOST1-DEMO` —— 它在"8 个未软删无单批"
的计数里,但它是 live-state 清单点名不许清理的演示批,**不是业务收货**。
后来的读者不要把"八"数成八张业务收货。

**六张已软删:** IN-2026-0013(delete_reason "Testing")、IN-2026-0191、
IN-2026-0221、IN-2026-0222、IN-2026-0267、ZZ-SMOKE-IB25 —— 全是测试/走查残留。
列表只显示未软删行,事后补说明的门也不为已删行而建。

**屏幕上:** 列表页来源列渲染三态 —— 对着采购行(蓝,单号)/ 有理由(灰,
字典标签)/ **未说明(琥珀,字面写【未说明 / Unexplained】)**,永远不是空白格。
批次页的来源面板同三态,外加事后补说明的门。

**补说明之后,区别仍然看得出(A7 采纳时点名要记下的):**
`source_reason_recorded_at` **非空 = 事后补的**,NULL = 收货当场说的。
收货当场的出处就是 `created_by`/`created_at`,所以 intake 不写 recorded 对
(想冒充会被 `SOURCE_PROVENANCE_NOT_AT_INTAKE` 按名拒);事后的门
(`explain_inbound_source`)必然盖章(谁 = `auth.uid()`,何时 = `now()`,
同生同灭由 `inbound_source_recorded_pair` 钉住)。于是 8 张被逐一补完之后,
"哪张是当年说的、哪张是后来补的"仍然是数据里的事实,不是记忆里的。

---

## 五 · fixture 的账(2c)—— 本刀最大的一笔成本,预先报过价

**77 份 fixture 建进料批**(66 份直插 175 条 INSERT + 16 份走 RPC,有交集),
其中 **58 份完全不提采购单** —— 规则落地那一刻,它们全都在制造一个不可能的世界。

处置按 A6:**全部编辑,不开任何侧门**(按角色豁免 = IOD-1b 关掉的那扇门;
`test_fixture` 字典值 = 会漏进生产的桶)。理由的选择:对凭空造出的测试库存,
`stocktake_gain` 并不是真话 —— **真话是 `other` + 一句点名 fixture 的说明**
(`'fixture NN 自带数据'`),这正是 other 存在的用途,而且让 R3 的路径在每一次
gate 里被走 185 次。

**顺带修的两处别的刀的 fixture(按 A6 的要求分开报,它们不是本刀的缺陷):**
* fixture 35(审批)与 147(合同条款):各有 3+1 条**只挂单头不挂行**的收货 ——
  在 `PO_HEADER_WITHOUT_LINE` 之下会被拒,而 35 的 C 臂断言的是
  `PO_NOT_APPROVED`(会被preempt)。两份 fixture 本来就各自建了带行的 PO,
  改法是让那几条 INSERT 挂上真实的行(scalar 子查询取行 id),断言全部原样成立。
* fixture 58(一扇门)F 臂:直插测的是"RLS 拒",而来源触发器在 RLS 之前开火 ——
  给那条插入补上理由,让 RLS 仍然是唯一被测的东西。

新 fixture:**184-a-receipt-must-say-where-it-came-from.sql** —— 九个臂
(字典 / 三路拒 / R3 两式+对照 / 两个成功控制 / 单头拒 / 出处两式 / 历史行
活着且不被填 / 事后盖章换人验 / 不许清),每一臂先证注入改变了什么;
历史态用 fixture 172 的 DISABLE TRIGGER 先例制造。对线上跑过一遍(回滚),全绿。

---

## 六 · 面向下一刀的两句话

* **tolling(来料加工)到货时**,它的收货同样无单 —— 那一刀要做的是
  在本字典**加一行**(R2 的兑现),不是改触发器。
* `material_sources` / `loss_categories` 的 DICT-ADMIN 补登记:缺口已点名
  (§二),归它们自己的刀。
