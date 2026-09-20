# BLOCKERS-0 · 停止闸 —— 四件【挡人】的勘察

> ★ **这是一次勘察。没有写一行代码,没有一次迁移,没有动 schema。**
> 线上只读,写入零次。**它停在这里等 Tim。**

---

## §1.1 · 开工闸

```
git status --porcelain      → 空
local HEAD                  → 1ae378fc4745bd276821c86f67020eeeac188f1b
origin/main(跟踪引用)      → 1ae378fc4745bd276821c86f67020eeeac188f1b
git ls-remote origin main   → 1ae378fc4745bd276821c86f67020eeeac188f1b
```
三个完整 40 字符 SHA 逐字相同,且等于 Tim 确认过的那次部署(QUEUE-RECONCILE)。
**闸过,未等待即继续。**

---

## §0 · ★★★ 先说最要紧的三句 ★★★

> **① 四件里有两件,它们的正文在今天是【假的】。**
> `MKT-CCY-1` 早在 2026-08-31 就被 `FX-DISPLAY-1` 修好了(`f8a2f028`);
> 「八行物料全部改不动」今天的真数是 **3 行**,其中~~**只有 2 行是真的业务物料**~~
> ★ **【全部线上数据都是测试数据 —— Tim,2026-09-20】** —— **那 2 行同样是测试数据**;`ZZ-` 与非 `ZZ-` 是**两种测试数据**,不是假 / 真。原文留着划掉。
> **只有 2 行是真的业务物料**,
> 而**编辑表单自己就要求填种类** —— 门不是关着的,是**在问一个没人答的问题**。
>
> **② 那个把它们送进【甲】的动作,没有重新量过。**
> QUEUE-RECONCILE §8 写着「委托书举的那个例子本刀查实了」——
> 它查实的是 `docs/forward-queue.md`「阶段 0」那段**散文**,不是 `app/inventory/page.tsx`。
> ☞ **一份索引按正文分档,而正文过期了,那个档就是过期的。**
>
> **③ 这四件【不是】一刀。** 分法与理由在 §5。

---

## §2 · grilling 改了什么

★ **`mattpocock-skills:grilling` 按名调用了,作用在 §3 的范围上。**

它对这一刀的改动是**一条**,而那一条决定了整份报告的形状:

> **「Finding _facts_ is your job, never the user's.」**
>
> 委托书的 §3 把四件事描述成四个**已知的缺陷**,然后请我为它们排代价。
> grilling 的规矩把第一轮问题全部**挡了回去** —— 在把任何一个问题递给 Tim 之前,
> 先去环境里把事实取回来。

**它买到的东西是具体的,不是方法论上的:**

| 如果按委托书直接问 Tim | 重新量过之后,那个问题 |
|---|---|
| 「B1 用哪个汇率、以哪一天为准?」 | ★ **不该问** —— 屏幕上今天写着 `(USD)`,没有一个错的数在等一个汇率 |
| 「B2 那八行物料各是什么种类?」 | ★ **问错了行数,也问漏了问题** —— 是 3 行不是 8 行,而且光答「种类」不够,还要答形态与来源 |
| 「B3 补策略还是走函数?」 | ★ **可以问,但少了一个前提** —— 那张表**没有 `updated_by`/`updated_at`**,所以「能不能留痕」不是两条路的附带性质,是其中一条路的**唯一**卖点 |
| 「B4 谁可以挪合同状态?」 | ★ **可以问,而它今天挡不住任何人** —— 线上 `contracts` **零行** |

☞ **所以本报告把 grilling 的第一轮【整轮】换成了测量,**
把它提出的每一个问题带着**证据**放在 §7,而不是带着**假设**放在这里。
**grilling 的会话没有结束:frontier 上的决定仍然是 Tim 的,一件都没有替他答。**

---

## §3 · 逐件重新测量 —— **每一条都说「正文今天还成不成立」**

### ★★ B1 · MKT-CCY-1 —— **正文【不成立】。它在 2026-08-31 就被修好了。**

**委托书说**:`marketValuePerKg()` 返回 USD/kg,`/inventory` 标成 SGD,按 1.28 少报约 22%。

**函数那一半,CONFIRMED,原样成立:**
`lib/valuation.ts:100` 的 `marketValuePerKg()` 返回的确是 **USD/kg**
(`metal_prices.price_usd_per_tonne ÷ 1000 × 含量%`,**全程没有折算**)。

**而「标成 SGD」那一半,CONFIRMED 为【假】。**

#### 消费点普查 —— **全树 2 个,一个不多**

```
grep -rn "marketValuePerKg" --include=*.ts --include=*.tsx  →  6 命中
  lib/valuation.ts:100            定义
  app/inventory/page.tsx:19,244   消费点 ①
  app/inventory/output/[materialId]/page.tsx:15,200  消费点 ②
  messages/zh.ts:4061             注释
  scripts/check-currency-literals.mjs:515  注释
```
**没有第三个消费点。** 两个消费点一共把这个数印到**四个落点**上:

| # | 落点 | 今天的标签 | 键 / 证据 | 判词 |
|--:|---|---|---|---|
| 1 | `/inventory` 合计条 | **成品市价价值 (USD)** | `valuation.totalMarketValue`(`messages/zh.ts:4082`)· `formatMoneyBare` 裸印 · 左边加了一条 `border-l` 竖线 | ★ **对** |
| 2 | `/inventory` 表格列头 | **市价价值 (USD)** | `valuation.colMarketValue`(`zh.ts:4061`)→ `InventoryTable.tsx:93` | ★ **对** |
| 3 | `/inventory/output/[materialId]` 列头 | **市价价值 (USD)** | 同一个键 · `page.tsx:240` | ★ **对** |
| 4 | `/inventory/output/[materialId]` 合计行 | **市价价值 (USD)** | `page.tsx:267,270` | ★ **对** |

外加一句**写在屏幕上**的话(`valuation.marketValueNote`,中英双语):
> 「未实现的市价指示,直接取自 USD 金属报价 ——【没有折算成 SGD】。
> 左边两个是账面金额(SGD);这一个**既不是同一个币种,也不是同一类数**。」

**它是什么时候修的** —— `git log -S` 定位:

```
f8a2f028  FX-DISPLAY-1:一个 USD 数字顶着 SGD 的名字 —— 以及去看它一眼时撞见的两件更坏的事
```
**2026-08-31。** 也就是说 `MKT-CCY-1` 在「阶段 0」那段散文写下之后、
在 QUEUE-RECONCILE 立索引之前,**已经被另一刀顺手做掉了**,
而「阶段 0」那一条**没有人去划掉**。

#### ★ 那么今天还剩什么 —— **剩的是【折不折算】,而那才是 Tim 的那一句**

**不折算是一次【有记录的、当时量过的】选择,不是遗漏:**
代码注释与 i18n 注释都写着同一条实测 ——
> 线上唯一一条 USD 中间价是 **2026-07-31**,而 `fx_rate_asof` 的回溯上限是 **4 个自然日**;
> `fx_rate_asof('USD', 今天, 'mid')` 返回**零行**。**折不出来就不折。**

☞ **所以 B1 今天【不是甲】。** 屏幕上没有一个错的数。
它是**乙** —— 等一句「这个数要不要变成 SGD,按哪一天的哪个汇率」,
而那正是委托书自己说的「一个发生在真实世界里的日期,软件不替人填」。

> ⚠ **一处必须说清楚,免得本条被读成「没事了」:**
> **22% 那个数今天仍然是真的** —— 一个 USD 数字和两个 SGD 数字确实差着约 22%(@1.28)。
> 变了的是:**它们不再假装可以相加。** 屏幕上说了三次它是 USD,还说了一次它不是同一类数。

---

### ★★ B2 · 那些改不动的物料 —— **正文【部分成立】,而每一个数都要更正**

**委托书说**:8 行live 物料全部拒绝任何编辑,包括改一条备注。

#### 约束本体 —— CONFIRMED,逐字

```sql
-- pg_constraint,线上只读
materials_kind_stated | convalidated = false
  CHECK (((kind_code IS NOT NULL) AND (may_be_processed IS NOT NULL))) NOT VALID
```
★ **一处措辞更正**:委托书说它「re-evaluates the whole row」。
**行为上对,描述上要更准** —— Postgres 在 UPDATE 时重新求值**整条 CHECK**,
而这条 CHECK **只看两列**:`kind_code` 与 `may_be_processed`。
☞ 这个区别有后果:**只要这两列在同一次 UPDATE 里被填上,那次 UPDATE 就过。**

#### ★★ 那个「8」—— **真数是 3,而~~真的业务物料是 2~~**

> ★ **【全部线上数据都是测试数据 —— Tim,2026-09-20】** —— 那 2 行**也是测试数据**。原文留着划掉,不删。

线上 `public.materials` 全表(只读):

| 计数 | 值 |
|---|--:|
| 全表行数 | **9** |
| 未软删(`deleted_at IS NULL`) | **5** |
| ★ **未软删【且】违反约束** | ★ **3** |
| 已软删且违反约束 | 4 |
| 满足约束(两列都有值) | 2 |

**逐行:**

| code | name | kind_code | may_be_processed | 软删? | 判词 |
|---|---|---|---|---|---|
| **MAT-2026-0001** | NMC Cathode Foil | **NULL** | **NULL** | 否 | ★★ **挡着 —— 真业务物料** |
| **MAT-2026-0002** | Special Battery Material | **NULL** | **NULL** | 否 | ★★ **挡着 —— 真业务物料** |
| **ZZ-SMOKE-PROBE** | probe | **NULL** | **NULL** | 否 | ★ 挡着 —— **ZZ 验证残留行** |
| MAT-2026-0076 | Film | `packaging` | `false` | 否 | ✓ 改得动 |
| ZZ-SMOKE-NTF | NTF-1 walk scratch | `battery_material` | `true` | 否 | ✓ 改得动 |
| ZZ-1BCONF-M | 1b conf material | NULL | NULL | **是** | 违反,但没人编辑软删行 |
| ZZ-IODCONF-M | IOD confirmation material | NULL | NULL | **是** | 同上 |
| ZZ-SMOKE-M25 | ZZ-SMOKE mid | NULL | NULL | **是** | 同上 |
| ZZ-STK1CONF-M | ZZ-STK1CONF confirmation material | NULL | NULL | **是** | 同上 |

☞ **「8/8」是 2026-08-21 那天的读数,而它从那天起动过三次:**
两行被填了种类、一行是约束之后新建的、四行被软删。
**known-issues 那一条的正文没有错 —— 它只是一张 2026-08-21 的快照。**

#### ★★★ 而最要紧的更正是这一条:**门不是关着的,编辑表单【自己就在问那个问题】**

`app/materials/[id]/edit/actions.ts` 实测:

```ts
const kind_code       = kindRaw === '' || kindRaw === KIND_UNCHOSEN ? null : kindRaw   // :27-28
const may_be_processed = parseProcessableField(formData.get('may_be_processed'))       // :29
...
if (!kind_code)               fieldErrors.kind_code        = t('materials.form.errKind')        // :56
if (may_be_processed === null) fieldErrors.may_be_processed = t('materials.form.errProcessable') // :57
...
.update({ name, kind_code, may_be_processed, ... })   // :76-89
```

☞ **也就是说:`/materials/<id>/edit` 这扇门【打得开、按得动】,而且它【不许】你不答种类。**
一个人**改不了一条备注**,准确的说法不是「数据库拒绝他」,而是:
> ★ **表单要他在同一次保存里把种类和可不可投料一起说出来** —— 而**他不知道答案**。

**这正是那条约束存在的全部理由。** 委托书说得对:**B2 的修法是【数据】,不是代码。**
★ 而本刀量到的比那更强一句:**它连一次数据库写入都不需要工程师去做。**
**Tim(或者认得这些物料的人)在应用里点两次就能把它解开。**

#### ★★★ 逐行要答的那张单子 —— **不必读一行 SQL**

> ⚠ **本刀【不替任何一行作答】。** 下面给的是**选项**与**跟着来的追问**,不是建议值。
> 委托书明令:**不要从名字猜种类。** 照办。

**每一行都从同一个问题开始:**

> **问 ①(必答)· 这是哪一类东西?** 五选一:
> | 选 | 中文 | 说明(取自字典 `material_kinds.notes`) |
> |---|---|---|
> | `battery_material` | **电池料** | 整颗电芯与模组、极片废料、以及**我们买进来的黑粉** |
> | `ewaste` | **电子废料** | 非电池的电子废料 |
> | `packaging` | **包装材料** | 吨袋一类;可能随货出去、也可能可回收 |
> | `consumable` | **耗材辅料** | 被工艺消耗掉、成为生产成本的那些 |
> | `spare_part` | **备件** | 机器的备件;不按批次追溯 |

> **问 ②(必答)· 这一种东西,我们许不许把它投料加工?** 是 / 否
> ⚠ **一条硬规矩**(守卫 `guard_material_kind_processable`):
> **只有 `battery_material` 与 `ewaste` 答得了「是」。**
> 另外三类答「是」会被按名拒(`MATERIAL_KIND_NOT_PROCESSABLE`)。

> **问 ③ · 只在问 ① 答了 `battery_material` 时才要答**(守卫 `guard_material_condition_axes`):
> ☞ 其余四类**必须把这三列留空**,填了会被按名拒(`MATERIAL_KIND_HAS_NO_CONDITION_AXES`)。
>
> **③-a 形态(必答,13 选 1)**:
> 整包 `whole_pack` · 模组 `module` · 散电芯 `loose_cells` · 已开壳电芯 `de_cased_cell` ·
> 混合未分选 `mixed_unsorted` · 正极片 `cathode_sheet` · 负极片 `anode_sheet` ·
> 极片废料 `electrode_scrap` · 黑粉 `black_mass` · 隔膜 `separator` ·
> 电解液 `electrolyte` · 壳体 `casing` · 结构件 `structural_parts`
>
> **③-b 来源(必答,3 选 1)**:
> 退役料 `end_of_life` · 厂内边角料 `production_scrap` · 客户退货 `customer_return`

> **问 ④ · 只在问 ③-a 选了【需要拆解】的五个形态之一时才要答**:
> **需要拆解的五个**:`whole_pack` · `module` · `loose_cells` · `de_cased_cell` · `mixed_unsorted`
> **④ 规格尺寸(必答,5 选 1)**:
> 电动车动力电池 `ev_traction` · 储能与后备电源 `ess_ups` · 两轮与轻型出行 `two_wheeler` ·
> 消费电子与电动工具 `consumer_electronics` · 工业车辆与设备 `industrial_equipment`
> ⚠ **另外八个形态(黑粉、极片废料…)必须把规格尺寸留空** —— 填了按名拒
> (`MATERIAL_SIZE_FORMAT_NOT_APPLICABLE`)。

**于是那张单子是:**

| 行 | 屏幕上现在看得到的事实(**不是提示,是事实**) | 要答 |
|---|---|---|
| ★★ **MAT-2026-0001 · NMC Cathode Foil** | 单位 `kg` · 化学体系已填 **NMC** · **8 个进料批 / 余 14,488 kg** | ① ② ,若 ①=电池料 则加 ③ab,若 ③a 需拆解则加 ④ |
| ★★ **MAT-2026-0002 · Special Battery Material** | 单位 `kg` · 化学体系**空着** · **5 个进料批 / 余 830 kg** | 同上 |
| ★ **ZZ-SMOKE-PROBE · probe** | 单位 `kg` · **1 个进料批 / 余 99,970 kg** · ★ **`ZZ-` 前缀 = 验证残留行** | ★ **先答一个不同的问题:它该被答,还是该被退役?**(见下) |

> ★★ **第三行是一个不同的问题,不要混进前两行。**
> `ZZ-SMOKE-PROBE` 是 `known-issues`「验证残留:线上那些 ZZ 行」那一族的成员,
> 而它上面挂着 **99,970 kg** 的进料余量 —— 它**污染库存合计**。
> **本刀不处置它,也不建议在这一刀里处置它**;按名记进队列,与那一族一起裁。

#### ★★ 「这也顺手把加工打开吗?」 —— **是同一件事,一列,而它带一个条件**

**加工那道闸读的是同一列。** `db/tables/processing_inputs.sql:69-82`(PROC-1):
```sql
SELECT m.may_be_processed, m.code INTO v_may, v_code FROM materials m WHERE m.id = v_material_id;
IF v_may IS NOT TRUE THEN
    RAISE EXCEPTION 'MATERIAL_NOT_PROCESSABLE|%|%', v_code,
        CASE WHEN v_may IS NULL THEN 'undecided' ELSE 'false' END;
END IF;
```
**线上逐料的进料余量(只读):**

| 物料 | `may_be_processed` | 进料批 | 余量 | 今天投得了料吗 |
|---|---|--:|--:|---|
| MAT-2026-0001 | **NULL** | 8 | **14,488** | ✗ `MATERIAL_NOT_PROCESSABLE\|…\|undecided` |
| MAT-2026-0002 | **NULL** | 5 | **830** | ✗ 同上 |
| ZZ-SMOKE-PROBE | **NULL** | 1 | 99,970 | ✗ 同上 |
| MAT-2026-0076 Film | `false` | 0 | 0 | ✗(**答过了:不投**,而且它本来没货) |
| ZZ-SMOKE-NTF | `true` | 1 | 100 | ✓ |

☞ **判词:不是第二件事,是同一件。**
~~**全部真实库存(13 批 / 15,318 kg)都压在那两行 `NULL` 上。**~~

> ★ **【全部线上数据都是测试数据 —— Tim,2026-09-20】** —— **「真实库存」在今天是假的**,那 13 批全部是测试数据。
> ⚠ **数字没变,变的是它的意思。** 原文留着划掉。
在同一次保存里把 `may_be_processed` 答成**是**,**编辑与加工同时活过来**。

> ⚠ **而条件必须写出来:**
> ① 答成**否**,那一行的编辑活过来、**加工仍然关着** —— **那是对的,不是残留**;
> ② 「加工全关着」这句话**结构上**已经不成立 —— `ZZ-SMOKE-NTF`(100 kg)今天就投得了料。
> 准确的说法是:★ **没有任何一批【真实】库存投得了料。**

---

### ★★ B3 · FIXED-ASSETS-NO-UPDATE-POLICY —— **正文成立,而线上比它写的更空**

**策略仍然缺席,CONFIRMED,而且不止缺一条:**

```
pg_class:   fixed_assets  relrowsecurity = true   relforcerowsecurity = false
pg_policies(schemaname='public', tablename='fixed_assets'):
  ┌ "fixed_assets select by permission" | SELECT | {authenticated} | has_permission('module.finance.view')
  └ ★ 全表就这【一条】
```
☞ **没有 UPDATE 策略,也没有 INSERT 策略,也没有 DELETE 策略。**
委托书说「没有 UPDATE 策略」—— **对,而它其实是「只有一条 SELECT 策略」。**

★ **镜像没有漂移**:`db/tables/fixed_assets.sql:108-109` 写的也正是这一条,不多不少。

#### 写入点普查 —— **全树【1 个】直连写,其余全走函数**

线上所有函数体里提到 `fixed_assets` 的,**16 支,`prosecdef` 全部为 `true`**(SECURITY DEFINER,绕过 RLS):
`create_fixed_asset` · `set_asset_in_service` · `set_asset_acceptance` · `dispose_fixed_asset` ·
`depreciate_fixed_assets` · `preview_depreciate_fixed_assets` · `next_fixed_asset_code` ·
`record_expense` · `reverse_expense` · `close_period` · `preview_close_financial_year` ·
`amend_purchase_order` · `create_purchase_order` · `release_purchase_order_retention` ·
`po_document_data` · `commit_processing_run`

| 屏幕 / 动作 | 怎么写的 | 受不受影响 |
|---|---|---|
| `/finance/assets/new` 建卡 | `rpc('create_fixed_asset')` | ✓ **不受影响** |
| `/finance/month-end` 投用(**事件**) | `rpc('set_asset_in_service')` | ✓ **不受影响** |
| `/finance/month-end` 折旧 | `rpc('depreciate_fixed_assets')` | ✓ **不受影响** |
| `/finance/month-end` 处置 | `rpc('dispose_fixed_asset')` | ✓ **不受影响** |
| 验收 | `rpc('set_asset_acceptance')` | ✓ **不受影响** |
| ★★ **`/finance/assets/[id]` ·「计划投用日」** | ★ **`supabase.from('fixed_assets').update(...)` 直连表** —— `app/finance/assets/[id]/actions.ts:231` | ★★ **死的。对所有人,包括 admin。** |

**全树只有这一处。** 它自己的注释写着为什么它**故意**不走 `set_asset_in_service`:
> 「**它不走 `set_asset_in_service`** —— 那支函数管的是【事件】(而且会拒未来的日期)。
> **计划是另一件事**:直连表 + RLS。」
☞ **两列是两件事,而那个区分是对的**:`planned_in_service_date` 可以在未来,
那正是它存在的全部理由(`guard_asset_in_service_not_future` 只看 `in_service_date`)。

**DBLOCK-1 那一半,CONFIRMED 已落地**:零行不再报告成功,走 `refuseNothingChanged`。
☞ **门仍然是关的,而它现在会说出自己关着。**

#### 它今天挡着多少 —— **两张卡**

```
fixed_assets:  2 行 | 有计划投用日 1 行 | 有实际投用日 0 行 | status='in_service' 0 行
```
> ★ 那 1 行的计划日**不可能是通过这扇门录进去的**(它从落地那天起就是死的)——
> 只可能来自 `create_fixed_asset` 建卡时那一笔,或者一次直连数据库的编辑。
> **本刀没有追它的出处** —— `NOT TRACED`。

#### ★★ 两种形状,以及**一个委托书没有说的前提**

> ★★ **线上实测:`fixed_assets` 【没有】 `updated_at`,也【没有】 `updated_by`。**
> (全 23 列:… `notes` · `created_at` · `created_by` · `planned_in_service_date` · `acceptance_date`)
> ★ **而且它没有 `enforce_write_permission` 语句级触发器** —— 那张表上只有两支守卫触发器
> (`guard_asset_acceptance_not_future` · `guard_asset_in_service_not_future`),
> 两支都**不管权限**。
>
> ☞ **所以「能不能留痕」不是两条路的附带差别,是其中一条路的【唯一】卖点。**

| | **甲 · 补一条 UPDATE 策略** | **乙 · 走一支 SECURITY DEFINER 函数** |
|---|---|---|
| **改动面** | 一次迁移 + `db/tables/fixed_assets.sql` 镜像(AGENTS.md 同刀规矩)+ 一支回滚 fixture | 一次迁移 + `db/functions/set_asset_planned_in_service.sql` 镜像 + fixture + ★ **一处应用改动**(`actions.ts` 从 `.from().update()` 换成 `.rpc()`) |
| **谁说了算** | **RLS 说了算** —— 谓词写死在策略里,改它要再来一次迁移 | **函数说了算** —— 可以判得更细(例如「已投用的卡不许再改计划」) |
| **留痕** | ★★ **没有,而且加不上** —— 那张表没有 `updated_by`/`updated_at`。要留痕就得**另外再加两列**,那是第二次迁移面 | ★★ **有** —— 函数体里想写什么就写什么,不必动表结构 |
| **被拒时会不会说话** | ⚠ **数据库那侧不会** —— 没有 `enforce_write_permission` 触发器,不合谓词就是零行。**今天靠应用侧 `refuseNothingChanged` 兜着**(DBLOCK-1) | ✓ **会** —— `require_permission` 按名抛 |
| **一致性** | ★ 让 `fixed_assets` 变成**唯一一张有两扇写门、两套规矩**的资产表 | ★ **与既有 5 支资产写函数同一个形状** |

★★ **本刀的建议:走【乙】。**
**证据,不是品味:**
① 这张表上**其余每一次写入都已经是 SECURITY DEFINER 函数**(16 支,`prosecdef` 全 true);
② 补策略会造出第二扇门,而 `known-issues` 的 `LINK-1` 正是为「**两扇门,两套规矩**」立的案;
③ 那张表**没有 `updated_by`**,所以【甲】要么不留痕,要么把一次迁移变成两次。

> ⚠ **而这仍然是 Tim 的裁定,不是本刀的。** 【甲】有一个真实的论据:
> **它更便宜,而且不动应用**。如果「谁改了计划投用日」不需要被记住,【甲】就够了。
> ☞ **那正是要答的那一句(见 §7 Q3)。**

---

### ★ B4 · 合同状态机没有出口 —— **正文成立,而它今天【挡不住任何人】**

**零支写入,CONFIRMED,两侧都查过:**

| 查法 | 结果 |
|---|---|
| 线上 `pg_proc`,函数体匹配 `contracts` | **3 支**:`link_document_to_contract` · `po_document_data` · `price_exposure_report` —— ★ **没有一支写 `contracts.status`**(`link_*` 只**读**它) |
| 全树 `from('contracts')` | **4 处**:`app/contracts/page.tsx:67`(读)· `app/purchasing/orders/[id]/page.tsx:142,149`(读)· ★ `app/contracts/new/actions.ts:105`(**`.insert`**) |
| 全树 `.update(` on contracts | ★ **0 处** |

**建成什么就是什么,CONFIRMED,而且屏幕自己承认这件事:**
`app/contracts/new/NewContractForm.tsx:149-161` 只给两个选项(`active` / `draft`),
下面印着一句 `contracts.form.statusIsFinal`;
`actions.ts:12` 的注释逐字写着「**2026-09-07 实测,零处**」。
☞ ★ **它不是一个骗人的控件,是一个诚实的死胡同。**

#### schema 允许什么 vs 到得了什么

```sql
status text NOT NULL DEFAULT 'draft'
  CHECK (status IN ('draft','active','suspended','expired','terminated'))
```
| 状态 | 到得了吗 | 怎么到的 |
|---|---|---|
| `draft` | ✓ | 建单时选 |
| `active` | ✓ | 建单时选 |
| **`suspended`** | ✗ | ★ **没有任何路** |
| **`expired`** | ✗ | ★ **没有任何路**(★ 注意:`effective_to` 过期**不会**自动改它 —— 没有任何作业跑) |
| **`terminated`** | ✗ | ★ **没有任何路** |

**下游依赖 CONFIRMED,而且只有一处:**
`link_document_to_contract` 里那条拒绝 ——
```sql
IF v_con.status <> 'active' THEN
    RAISE EXCEPTION 'CONTRACT_NOT_ACTIVE|%|%', v_con.code, v_con.status
      USING HINT = '…要挂上去,先把合同置为 active';
```
☞ ★★ **那句 HINT 指向一个不存在的动作。** 一份建成 `draft` 的合同**永远**挂不上单据,
而系统请他去做一件系统不让他做的事。**这是这一条里唯一真的锋利的地方。**

#### ★★ 而它今天挡着谁 —— **零个人**

```sql
SELECT count(*) FROM public.contracts;   →  0
```
★★ **线上一份合同都没有。**
☞ **所以 B4 不是【甲】** —— 判据是「今天有一个人打不开、按不动、或者读到一个错的数」,
而今天没有任何一行数据落在这条缺陷上。
**它是【乙】**,而且**它会在第一份合同被建出来的那一天变成【甲】**。

> ★ **顺带查实、与本条相邻的一件**(**登记,不做**):
> 甲档另有一行写着「**合同单据挂接** · `link_document_to_contract` …
> `app/` 与 `lib/` 里**一个调用点都没有**」。
> ★ **那一行今天也是假的**:`app/purchasing/orders/[id]/contractActions.ts:41`
> 就是 `supabase.rpc('link_document_to_contract', …)`,外加一个完整的
> `ContractLinkPanel.tsx` 面板。**按 §4「不要扩散,登记它」处理 —— 已登记,本刀不动。**

#### 形状(**不裁,只摆出来**)

| | 改动面 | ★ 要不要迁移 | 谁说了算 | 留痕 |
|---|---|---|---|---|
| **甲 · 加一个屏幕上的状态控件** | 纯前端:一个 server action `.from('contracts').update({status})` | ★★ **不要** —— `contracts` **已经有** UPDATE 策略 | `module.customers.edit` / `module.suppliers.edit`(跟归属那一侧走) | `updated_at` / `updated_by` ✓ **表上已经有这两列** |
| **乙 · 一支转移函数** | 迁移 + 函数镜像 + fixture + 前端 | **要** | 函数可以判**哪些转移合法**(例如 `terminated` 不许回 `active`) | 可以写一行审计 |
| **丙 · 加一张状态流水表** | 迁移 + 新表镜像 + fixture + 前端 | **要** | 同乙 | ★ **完整历史**(谁、什么时候、从什么到什么) |

★ **注意甲与 B3 的不对称,它是本刀的一个具体发现:**
`contracts` 有 UPDATE 策略 **+** `enforce_write_permission` 语句级触发器 **+** `updated_by`/`updated_at`;
`fixed_assets` **三样一样都没有**。
☞ **所以「加个控件就行」在合同上是真的,在资产上是假的。两件事不能按同一个直觉排。**

---

### ★★ B5 · 审批策略那三列 —— **读到了。2026-09-02 那份记载是对的。**

**一次只读查询,`public.finance_settings`(单行表,`id = true`):**

| 列 | ★ **线上今天的值** | 2026-08-24 记载 | 2026-09-02 记载 |
|---|---|---|---|
| `approvals_enabled` | **`false`** | NULL | false ✓ |
| `approval_level1_role_code` | **`finance`** | NULL | finance ✓ |
| `approval_level2_role_code` | **`cfo`** | NULL | cfo ✓ |
| `approval_threshold_base` | **`1000`** | NULL | 1000 ✓ |

☞ **判词:2026-09-02 那份记载【逐格相符】。2026-08-24 那份在今天是【假】的。**
**没有出现第三种值。** 矛盾**解决**,而解决它的是**一次查询**。

> ★ 同一行里顺带读到、与本条相关的两格(**只报,不动**):
> `updated_at = 2026-08-30 19:05:55+08` · `updated_by = d41c214d-9ef0-4463-8dae-fea39518fba9`
> ☞ **与「2026-09-02 由一次直接改库设定」那句话【对不上一个日期】** ——
> 时间戳说是 **08-30**,记载说是 09-02。⚠ 但 `finance_settings` 是**整行一个时间戳**,
> 它记的是这一行**最后一次**被改的时刻,**不是这四列各自的**。
> ☞ **所以它证不伪那条记载,也证不实它。标 `UNCERTAIN`,本刀不追。**

#### ★ 顺带结清 QUEUE-RECONCILE「解不了」清单上的另外两件

委托书说那十五件里有三件落在本刀的射程内。**三件都答了:**

| # | 解不了的是什么 | ★ 本刀的答案 |
|--:|---|---|
| **1** | 那三条审批策略列今天是什么值 | ★ **见上。RESOLVED。** |
| **2** | DATE-1 那三个提交有没有被确认部署 | ★ **RESOLVED —— 有。** `1085f192` · `4d4e6287` · `530fb7fb` 三个 `git merge-base --is-ancestor <sha> HEAD` **全部 YES**,而 HEAD(`1ae378fc`)正是 Tim 确认过的那次部署。 |
| **5** | 考勤底稿今天有没有行 | ★ **RESOLVED —— 没有。** `attendance_periods` **0 行** · `attendance_lines` **0 行**。 |

---

## §4 · 那么「它今天挡不挡得住一个人」—— **重新分档**

| | 委托书/索引说它是 | ★ **重新量过之后** | 为什么 |
|---|---|---|---|
| **B1** | 甲(屏幕上一个错的数) | ★ **乙**(等一句裁定) | 屏幕上四个落点全写着 `(USD)`,2026-08-31 起 |
| **B2** | 甲(8 行改不动) | ★ **乙**,而且是**最纯的一条乙** | 软件没挡任何人;**它在等一个人答两个问题**。3 行,其中 2 行是真物料 |
| **B3** | 甲 + 等裁定 | ★ **甲**(原样成立) | 一个控件对所有人改零行,今天 2 张卡 |
| **B4** | 甲 | ★ **乙**(会变成甲) | 线上 `contracts` **零行** |

> ★★ **四件里只有一件仍然是【甲】。**
> ⚠ **而这【不是】在说另外三件不重要。** B2 押着 **15,318 kg** ~~真实~~库存的加工闸 ——
> (★ **【全部线上数据都是测试数据 —— Tim,2026-09-20】**:那 15,318 kg 是**测试**库存)
> 它挡的不是一个屏幕,是一条产线。**它只是不该由一个工程师去排,该由一个认得物料的人去答。**

---

## §5 · 价钱 —— **两个数,逐件;以及它们能不能同行**

### 过程地板(**本仓库量出来的,不是估的**)

| 量具 | 墙钟 | 出处 |
|---|--:|---|
| `npm run build`(31 条静态检查 + `next build`) | **40s** | `DATE-1.md §6` |
| `python3 db/gate.py`(三判词) | **366s** | 同上(而 `evoltrya-db-access` 记的区间是 183–650s) |
| `scripts/smoke-routes.mjs` | **864s** | 同上 |
| `npx tsc --noEmit` | — | 同上 |
| `survey-controls --mode=drift` 一跑 | **1164–1372s** | 同上 |
| 备份闸(迁移前必做) | 未计时 | `~/evoltrya-backups/backup.sh` + `pg_restore --list` |

★ **而 QUEUE-RECONCILE 量到的那一条,本刀照用:**
**一刀【只改文档】,`gate.py` · `smoke` · `survey-*` / `probe-*` · `--reach` 一条都不必跑** ——
理由不是省事,是 `app/globals.css` 用 `@import "tailwindcss" source(none)` 把扫描源
限死在 `../app` 与 `../lib`,`docs/` **不在里面**(BUGFIX-1a 立的处置,复量过三次)。
☞ **跑它们要花约 75 分钟去证明一个恒等式。**

### 逐件

| | **过程地板** | **量出来的活** | ★ **要迁移吗** |
|---|---|---|---|
| **B1** | ★ **~0**(若按「不折算,现状即终态」结案 → 改两份 `.md`)<br>若裁「要折算」→ `tsc` + `build` **40s** + smoke **864s** | ★ **结案:~30 分钟**(在两份文件里划掉它并写明 `f8a2f028` 做掉了它)<br>折算:**未勘察** —— 它要先有一条汇率来源,而线上 USD 中间价停在 2026-07-31。★ **NOT MEASURED** | ★ **不要**(两种走法都不要) |
| **B2** | ★★ **零** —— 没有代码改动,没有迁移。**一次应用内的数据录入** | ★ **Tim 侧:2 行 × 2–4 个问题。**<br>工程侧:**~0**;若要一份「答完之后线上长什么样」的复核,再加一次只读查询(**<1 分钟**) | ★★ **不要** |
| **B3** | `tsc` + `build` **40s** + ★ **`gate.py` 366s**(动了库,必须跑)+ 备份闸<br>☞ smoke:**走【乙】要跑**(动了应用),**走【甲】可以不跑**(零应用改动) | **甲**:一条策略 + 镜像 + 一支回滚 fixture<br>**乙**:一支函数 + 镜像 + fixture + `actions.ts` 一处改 + 错误码映射<br>★ 两种都 **NOT ESTIMATED**(本刀不报没量过的工时) | ★★ **要 —— 两种形状都要** |
| **B4** | **甲**:`tsc` + `build` **40s** + smoke **864s**(新控件)<br>**乙/丙**:再加 `gate.py` **366s** + 备份闸 | **甲**:一个控件 + 一个 server action + 状态文案<br>**乙/丙**:函数/新表 + 镜像 + fixture + 前端<br>★ **NOT ESTIMATED** | ★ **甲:不要**(策略已在)<br>**乙/丙:要** |
| **B5** | ★ **零** —— 已完成,产出是**本文件里那张表** | ★ **已做完**(一次查询) | ★ **不要** |

### ★★ 这是一刀还是几刀 —— **几刀,而分界线是【迁移】**

> ★ **委托书问得对:要不要迁移,决定了它们能不能同行。**

| 刀 | 装什么 | 为什么这样切 |
|---|---|---|
| ★ **一 · 文档刀(零迁移、零代码)** | B1 结案 · B5 的读数 · B2 那张问题单 · 本刀登记的两条(`link_document_to_contract` 的假读数、`ZZ-SMOKE-PROBE` 的 99,970 kg) | ★★ **它按构造不必跑 `gate` / `smoke` / `survey`** —— 与任何一件带迁移的东西同行,就会把这个豁免弄丢,白付 ~20 分钟 |
| ★ **二 · B2(不是一刀,是一次【问答】)** | Tim 或认得物料的人在 `/materials/<id>/edit` 上答两行 | ★★ **它根本不是一次软件改动。** 把它排进任何一把刀,都是把一个**判断**伪装成一件**工时** |
| ★ **三 · B3(带迁移)** | 补策略 **或** 建函数,**先有裁定再动手** | 动库 → 备份闸 + `gate.py` 366s。**它自己一把** |
| ★ **四 · B4(先裁形状,再决定要不要迁移)** | 若裁【甲】→ 可以**并进任何一把前端刀**;若裁【乙/丙】→ **必须与三分开** | ★ 它今天挡着 0 个人,**没有理由挤进前面任何一把** |

★★ **三与四即使都要迁移,也【不建议】合成一刀:**
两条迁移碰的是**两张互不相干的表**,而 `gate.py` 是**全库一次**的判词 ——
合起来跑省不下那 366s,**却让一次回滚同时带走两件不相干的东西**。

---

## §6 · ★★ 每一个开着的问题 —— **全部,带建议与证据**

> ⚠ **一个都没有替 Tim 答。** 下面每一条都是 grilling frontier 上的一格。

### ❓ Q1 —— **B1 结案,还是折算?**
`/inventory` 与 `/inventory/output/[…]` 上那个数,**维持现状(USD 裸印 + 标签写 USD + 一句解释)**,
还是把它折成 SGD?
➡️ ★ **建议:维持现状,把 `MKT-CCY-1` 在两份文件里结案。**
**证据**:四个落点全部标 `(USD)`(`f8a2f028`,2026-08-31);
而折算今天**折不出来** —— 线上唯一一条 USD 中间价是 **2026-07-31**,
`fx_rate_asof` 回溯上限 4 天,`fx_rate_asof('USD', 今天, 'mid')` 返回**零行**。
☞ **要折算,先得答 Q2。**

### ❓ Q2 —— **(只在 Q1 答「要折算」时才需要答)用哪个汇率、以哪一天为准?**
选项:① 报价那天的汇率 ② 每天一条的期末中间价 ③ 一个由人维护的「估值汇率」。
➡️ ★ **本刀不建议任何一个,而且建议现在不要答它。**
**证据 / 理由**:这是一条**财务口径**,而本仓库有一条常设规矩 ——
**一个发生在真实世界里的日期,软件不替人填**。
★ 更要紧的是:**三个选项都要先有一条今天不存在的汇率来源。**
这一段 **NOT MEASURED** —— 本刀没有勘察汇率来源怎么建。

### ❓ Q3 —— **B3 走哪一种形状:补策略,还是走函数?**
➡️ ★ **建议:走函数(§3 B3 的【乙】)。**
**证据**:① 那张表上其余 **16 支**碰它的函数**全部** `prosecdef = true`;
② 它**没有 `updated_by` / `updated_at`**,所以补策略要么不留痕、要么把一次迁移变成两次;
③ 它**没有 `enforce_write_permission` 触发器**,补策略后被拒的写在**数据库那侧仍然是静默的**
(今天靠应用侧 `refuseNothingChanged` 兜着)。
⚠ **反方论据是真的**:补策略更便宜,**且零应用改动 → 可以不跑 864s 的 smoke**。
☞ **判准是一句话:「谁改了计划投用日」这件事,需不需要被记住?**

### ❓ Q4 —— **谁可以改「计划投用日」?**
`module.finance.edit` 全体,还是更窄的一圈人?
➡️ ★ **建议:`module.finance.edit`,与该模块其余写入一致。**
**证据**:同表的 `SELECT` 策略用的就是 `module.finance.view`;
而应用侧被拒时已经按 `module.finance.edit` 报错(`actions.ts:237`)——
**换成别的码会让屏幕上那句拒绝变成假话。**
⚠ 若 Q3 答【乙】,这一条可以在函数里改得更细,**不必再来一次迁移**。

### ❓ Q5 —— **谁可以挪合同状态?**
➡️ ★ **建议:与建合同同一道门** —— 买方合同要 `module.suppliers.edit`,卖方合同要 `module.customers.edit`。
**证据**:`contracts` 现有的 UPDATE 策略**逐字就是这一条**,
`link_document_to_contract` 里那次 `require_permission` **也是这一条**。
☞ **选它,「甲 · 加个控件」这条路【零迁移】。** 选别的,就要改策略 → 要迁移。

### ❓ Q6 —— **挪合同状态算不算一件要留痕的事?**
➡️ ★ **建议:先只要 `updated_by`/`updated_at`(表上已经有),不建流水表。**
**证据**:线上 `contracts` **0 行** —— 为一张空表建一张历史表,
正是 `contracts.sql` 抬头自己点过名的那个形状(「**一张没有写入方的空表**」)。
⚠ **反方**:合同状态是**对外承诺**的开关,而 `terminated` 不可逆;
若 Tim 认为它是审计对象,那就该在第一份合同建出来**之前**建好流水表 ——
**事后补,补不出已经发生过的转移。**

### ❓ Q7 —— **哪些状态转移是合法的?**
`draft → active → suspended → active`?`terminated` 是不是终态?`expired` 谁来置?
➡️ ★ **建议:先只把 `draft → active` 这一条打开,其余三个状态【暂不接】。**
**证据**:今天唯一真的锋利的后果是 `link_document_to_contract` 那句
「**要挂上去,先把合同置为 active**」—— 它指向一个不存在的动作。
**打开这一条,那句 HINT 就不再是假话**,而另外三个状态今天**没有任何下游读它们**。
⚠ **一处必须一起裁的**:`expired` **不会自己发生**(没有任何作业跑),
所以「合同到期」今天在系统里**不是一个事件**。★ 这一段 **NOT MEASURED** —— 本刀没勘察到期作业。

### ❓ Q8 —— **B2 那两行物料,谁来答?什么时候答?**
➡️ ★ **建议:Tim 或采购侧认得这两批货的人,在 `/materials/<id>/edit` 上直接答,不要走工程。**
**证据**:表单本来就强制这两个字段;答完即生效,**编辑与加工同时活过来**。
★ **它押着 13 批 / 15,318 kg 的加工闸,而它的成本是两次点击。**
☞ **本刀建议它排在这四件的最前面,而它排的不是工时,是一次问答。**

### ❓ Q9 —— **`ZZ-SMOKE-PROBE` 上那 99,970 kg 怎么办?**
➡️ ★ **建议:与它自己那一族(`known-issues`「验证残留:线上那些 ZZ 行」)一起裁,不要在这里顺手处置。**
**证据**:它是 `ZZ-` 前缀的验证残留行,而那一族已经立过案、带着自己的删除条件。
⚠ **而必须说出来的是**:它**今天在污染库存合计** —— 9.99 万 kg。
★ 本刀**没有量**它落在哪几张报表上。**NOT MEASURED。**

### ❓ Q10 —— **B1 与 B2 的正文,谁去划掉?**
两份文件里那些过期的描述(「阶段 0」的 `MKT-CCY-1`、甲档里的「八行」、
甲档里那条「`link_document_to_contract` 零调用点」)。
➡️ ★ **建议:并进上面那把「文档刀」,按本仓库的老办法 —— 旧数带着它的日期留在原处,更正写成新块。**
**证据**:QUEUE-RECONCILE §9 就是这么做的(「**一个字都没删**」)。

---

## §7 · 读数登记 —— **CONFIRMED / NOT MEASURED,一条都不含糊**

| 读数 | 值 | 判词 |
|---|---|---|
| `marketValuePerKg()` 返回 USD/kg | 是 | ★ **CONFIRMED**(`lib/valuation.ts:100`) |
| 它的消费点数 | **2** | ★ **CONFIRMED**(全树 grep) |
| 那两个消费点的显示落点数 | **4** | ★ **CONFIRMED** |
| 四个落点今天标的币种 | **全部 (USD)** | ★ **CONFIRMED** |
| 修它的那个提交 | `f8a2f028`(FX-DISPLAY-1) | ★ **CONFIRMED**(`git log -S`) |
| USD 数与 SGD 数 @1.28 的差 | ~22% | ★ **CONFIRMED**(算术),⚠ **但它不再被当成同一个币种印出来** |
| 折算成 SGD 的路 | **不存在** | ★ **CONFIRMED**(线上 USD 中间价停在 2026-07-31,回溯上限 4 天) |
| 汇率来源要怎么建 | — | ★★ **NOT MEASURED** |
| `materials_kind_stated` 是 NOT VALID CHECK | 是 | ★ **CONFIRMED**(`convalidated = false`) |
| 它检查哪几列 | **`kind_code` · `may_be_processed`**(2 列) | ★ **CONFIRMED** |
| `materials` 全表行数 | **9** | ★ **CONFIRMED**(线上只读) |
| 未软删行数 | **5** | ★ **CONFIRMED** |
| ★ 未软删【且】违反约束 | ★ **3** | ★★ **CONFIRMED —— 不是 8** |
| 其中真业务物料 | ★ **2** | ★ **CONFIRMED** |
| 已软删且违反 | 4 | ★ **CONFIRMED** |
| 编辑表单强制填这两列 | 是 | ★ **CONFIRMED**(`actions.ts:56-57`) |
| 被挡住的真实进料余量 | **13 批 / 15,318 kg** | ★ **CONFIRMED** |
| 加工闸读的是不是同一列 | 是 | ★ **CONFIRMED**(`processing_inputs.sql:69-82`) |
| 「加工全关着」 | ★ **不精确** —— `ZZ-SMOKE-NTF`(100 kg)投得了料 | ★ **CONFIRMED** |
| `fixed_assets` RLS | on,`forced = false` | ★ **CONFIRMED** |
| 它的策略数 | ★ **1 条,只有 SELECT** | ★ **CONFIRMED** |
| 镜像与线上一致 | 是 | ★ **CONFIRMED**(`db/tables/fixed_assets.sql:108-109`) |
| 碰 `fixed_assets` 的函数 | **16 支,全部 SECURITY DEFINER** | ★ **CONFIRMED** |
| 直连写该表的应用点 | ★ **1 处**(`setPlannedInService`) | ★ **CONFIRMED** |
| 该表有没有 `updated_by`/`updated_at` | ★ **没有** | ★ **CONFIRMED**(23 列全查) |
| 该表有没有 `enforce_write_permission` | ★ **没有** | ★ **CONFIRMED**(触发器全查) |
| `fixed_assets` 行数 | **2**(1 行有计划日,0 行已投用) | ★ **CONFIRMED** |
| 那 1 行计划日是谁录的 | — | ★ **NOT TRACED** |
| 写 `contracts.status` 的函数 | ★ **0 支** | ★ **CONFIRMED** |
| 写 `contracts.status` 的界面 | ★ **0 处**(只有 1 处 `.insert`) | ★ **CONFIRMED** |
| `contracts` 行数 | ★★ **0** | ★ **CONFIRMED** |
| 到不了的状态 | **3 个**(`suspended` · `expired` · `terminated`) | ★ **CONFIRMED** |
| 依赖 `status` 的下游 | **1 处**(`link_document_to_contract` 要 `active`) | ★ **CONFIRMED** |
| `contracts` 有没有 UPDATE 策略 | ★ **有** | ★ **CONFIRMED** |
| 到期自动置 `expired` 的作业 | — | ★ **NOT MEASURED** |
| `approvals_enabled` | **false** | ★ **CONFIRMED** |
| `approval_level1_role_code` | **finance** | ★ **CONFIRMED** |
| `approval_level2_role_code` | **cfo** | ★ **CONFIRMED** |
| `approval_threshold_base` | **1000** | ★ **CONFIRMED** |
| 那四格是哪一天被设的 | — | ★ **UNCERTAIN**(整行时间戳 08-30,记载说 09-02;整行一个戳,分不出列) |
| DATE-1 三个提交在 HEAD 里 | 是 | ★ **CONFIRMED**(`merge-base --is-ancestor` ×3) |
| `attendance_periods` / `attendance_lines` | **0 / 0** | ★ **CONFIRMED** |
| `ZZ-SMOKE-PROBE` 污染了哪几张报表 | — | ★ **NOT MEASURED** |
| B3 / B4 各自的工时 | — | ★ **NOT ESTIMATED**(本刀不报没量过的工时) |

---

## §8 · 本刀登记、**不做**的两条

| 登记 | 内容 |
|---|---|
| ★★ **甲档那条「合同单据挂接零调用点」是假的** | `app/purchasing/orders/[id]/contractActions.ts:41` 就是 `rpc('link_document_to_contract')`,外加一个 `ContractLinkPanel.tsx`。★ **按 §4 登记,不扩散。** |
| ★ **`ZZ-SMOKE-PROBE` 押着 99,970 kg** | 一行 `ZZ-` 验证残留物料上挂着 9.99 万 kg 进料余量,**在污染库存合计**。归 `known-issues`「验证残留:线上那些 ZZ 行」那一族。**落在哪几张报表上 NOT MEASURED。** |

---

## §9 · 验证 —— **这一刀做了什么、没做什么**

| | 判词 |
|---|---|
| 改动面 | ★ **`docs/handbacks/BLOCKERS-0-stopgate.md` 一个文件** |
| `git diff --stat -- app/ lib/ db/ scripts/ messages/` | ★ **空** |
| 线上写入 | ★★ **零次。** 全部查询是单句 `SELECT`(`pg_constraint` · `pg_policies` · `pg_proc` · `pg_trigger` · `information_schema` · 六张业务表的只读读数)。**没有发过一次 `INSERT` / `UPDATE` / `DELETE`,也没有开过一个写事务。** |
| 迁移 | ★ **零** |

### ★ 故意【没有】跑的,以及为什么
> `db/gate.py` · `smoke-routes.mjs` · `survey-*` / `probe-*` · `--reach` · `npm run build` —— **一条都没有跑。**

★ **理由与 QUEUE-RECONCILE 同一条,而且是量过的:**
本刀的改动面是**一个 `docs/` 下的 `.md`**;
`app/globals.css` 用 `@import "tailwindcss" source(none)` 把扫描源限死在 `../app` 与 `../lib`,
**`docs/` 不在里面**。它们量的是渲染几何、数据库镜像与路由行为,
而本刀按构造改变不了其中任何一样。
☞ **跑它们要花约 75 分钟去证明一个恒等式。**

---

## §10 · 交回

★★ **本刀停在这里。没有开始建任何东西,也没有替自己答任何一个问题。**
§6 那十个问题归 Tim;§5 那个「几刀」的切法也归 Tim。
