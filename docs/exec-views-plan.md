# 四个人的第一屏 —— 高管视图计划(EXEC-0/0b,2026-08-16)

这份文件是 EXEC-1 及之后各刀的**依据**。里面的判定不再在对话里重新讨论;
要改,改这份文件。**臂的规格一律不在这里复制** —— 它们住在
`docs/dashboard-arm-inventory.md`,这里只引用名字与它记的那一行。

---

## 一 · 四个人,以及每个人的职责锚点

组织图(2026 年 8 月)。**锚点写下来,是因为"谁需要哪个数"的答案取自职责,
不取自职级** —— 一个按职级发号的方案会给 MD 一屏他不看的数,而把 CTO 真正每天
要看的那三个埋在三层菜单下面。

| 人 | 职务 | 职责锚点 |
|---|---|---|
| **Vince GOH** | Founder & MD | 政府关系与政务事项;以及 CEO 层面的宏观 |
| **Sandra YAP** | CCO | 客户履约与质量体系;物流 HC 与**合并后的 ESG/质量对外报告**在她这里(**客户的要求**,不是内部偏好) |
| **Cheng Siong PHUA** | CTO | 技术与运营;**实验室是近期的事** |
| **Tim CHEN** | CFO | 财务与公司事务;公司职能(HR/薪酬/IT,Choo Er TEH 之下)向他汇总 |

**两条从锚点直接推出来的后果,后面几节都靠它们:**

* **Sandra 那份 ESG/质量报告是【对外】的。** 对外意味着它迟早会被引用、被质疑、
  被要求"你当时发的是哪一版" —— 这个系统里对外单据的答案已经有了(签发档 +
  sha256 那一族)。所以第四节把它定成一份**签发档族的单据**,不是一个页面。
* **Phua 的实验室是近期的事。** 今天投料侧 19 条含量行的 `content_source`
  **全部为空**(一条化验来源都没有),而实验室落地会把这一侧从"手敲"变成
  "实验室"。凡是读回收率的地方,今天就必须把出处摆在数字旁边 —— 否则实验室
  上线那天,没有人分得清哪些历史数字该重新看一遍。

---

## 二 · 十二个数,逐个归类

分类口径:
**exists-as-arm** = `operations_now` 里已经有的一支(见 arm inventory 的编号表);
**exists-as-page** = 有页面能回答,但不在第一屏;
**derivable-today** = 数据与谓词都在,只差一支臂/一块面板;
**missing** = 需要新的列、新的记录或一次决定才能回答。

### Vince(MD)

| # | 数 | 归类 | 依据 |
|---|---|---|---|
| a | 月度收入 / 毛利覆盖 / 现金余额 | **exists-as-page** ×3 | 收入与毛利:`/finance/pnl`;毛利覆盖另见 `/margin`(批次毛利,`allocation_stale` 是它的缺口支);现金:`/finance/cashflow` 与 `/finance/bank`。三个数都算得出来,**都不在第一屏** |
| b | 证书/资质到期 | **missing**(候选已记) | `qualification_expiring` / `qualification_missing` 两支,arm inventory §"Reported, not built" 已经写好形状与理由(**没有 −30 天下限** —— 线上已有一张过期两年半的证书,带下限的告警会静默丢掉它)。权限 `module.suppliers.view` |
| c | 危废存储天数 vs 牌照时限 | **PARKED** | **NEA 牌照尚未持有(设备未到)。** 分类列的决定照旧成立(时限是**分类**的属性,不是证书的属性),而**数值等牌照文本**。今天不要填一个猜的数:一个猜出来的合规阈值比没有阈值坏 —— 它会让"没人看过"读成"看过了、没问题" |
| d | 供应商合规非绿计数 | **derivable-today** | `supplier_receiving_blocked` 视图已在(谓词与 `guard_inbound_po_receivable` 的证书段**同一份**,fixture 37F 钉着两者一致)。它今天只答"会不会拦收货",而"非绿"是更宽的一档 —— 与 (b) 那两支同一刀做,共用 `certificate_types.disposition` 的三档 |

### Sandra(CCO)

| # | 数 | 归类 | 依据 |
|---|---|---|---|
| a | 未履约订单 | **derivable-today** | `sales_orders.status IN ('confirmed','partially_shipped')` —— **"货还欠着"这个读法**,不发明任何排程概念(`shipments` 没有状态列,一条发货记录只在货真的走了之后才存在)。权限 `module.sales.view`。逐单的完成度由 `sales_order_fulfilment_status()` 回答,那是**一处推导**,新臂不得另算一遍 |
| b | 超信用额 + 应收账龄 | **exists-as-arm** ×2 | `credit_over_limit`(`operations_now`,读 `customer_ar_exposure_visible`)与 `ar_over_90`(最老账龄桶)。两支都已在册,Sandra 的第一屏是**换一个读者**,不是造新臂 |
| c | 行情陈旧 | **missing**(规格齐备) | ASY-3 的形状:一支臂带 severity,按 `price_date` 不按 `created_at`(补录发生过),`item_date = max(price_date)`,权限 `module.pricing.view`。**阈值默认 14 天,落成 `pricing_settings` 的一列** —— 实测录入节奏是"六周两次",7 天会天天响、30 天要等到数字已被跳过之后才响,14 天是这两者之间的一次**决定**,而它住在可见配置里,改得动。**窗口太薄那一半不上看板**,长在计价面板上(它是关于**这一次计价**的事实,不是关于维护欠账的) |

### Phua(CTO)

| # | 数 | 归类 | 依据 |
|---|---|---|---|
| a | 工单计划 vs 实绩 | **exists-as-page**(WO-1c) | `/processing/orders` 与 `/processing/orders/[id]`,读 `work_order_fulfilment`。**第一屏要的是一支臂**,arm inventory 已记两个候选(逾期计划、差异超阈)及各自必须先回答的问题 —— 排产日可空而**空不是逾期**;阈值今天没有家 |
| b | 待化验 | **exists-as-arm** | `awaiting_assay`(#1,`batch_assay_status`,`module.inbound.view`)。**它的限度要写在它旁边:它数的是"有没有化验单",不是"测了哪些金属"** —— 一张只测过 cu 的化验单会让这一支变绿,而 co、ni 仍然没有数。实验室落地之后这个区别会变得更要紧,不是更不要紧 |
| c | 安全库存 + 批次库龄 | **exists-as-arm** ×2 | `safety_stock_below`(#7c,**阈值为 NULL 的物料永不出现** —— 没设不是设成零)与 `output_unsold_aging`(#7,60 天)。注意 60 这个数**今天是写死在 `operations_now` 里的**,且与 Vince (c) 的合规时限**不是同一件事**,不要顺手合并 |

### Tim(CFO)

| # | 数 | 归类 | 依据 |
|---|---|---|---|
| a | 月结中枢 | **exists-as-page** | `/finance/month-end`,首页已有一条入口 |
| b | 现金 + 汇率缺口 | **exists-as-arm**(一半) | `fx_rate_gap`(#14,**45 天窗口**,理由是那一支会随年月增长的扫描,arm inventory §"两个被论证过的边界");现金余额是 **exists-as-page**(`/finance/cashflow`、`/finance/bank`),**没有臂** —— 而余额是一个**状态**不是一个**待办**,`operations_now` 装的是待办,所以它多半不该做成臂 |
| c | 毛利覆盖 + 未分摊成本 | **exists-as-arm**(一半) | `allocation_stale`(#4)答"未分摊";**批次毛利本身是 arm inventory 里的头号未建候选**,谓词已定(属主权限,`data.view_prices AND (module.finance.view OR module.processing.view)`),落点是 `app/page.tsx` 的 `TILES` |

**合计:exists-as-arm 6 · exists-as-page 5(含并列)· derivable-today 2 ·
missing 3 · parked 1。** 也就是说**十二个数里有九个今天就答得出来**,
真正缺的是三个:证书到期、行情陈旧、批次毛利 —— 而三个的规格都已经写好了。

---

## 三 · 已定:高管视图是**四个授权包 + 臂级谓词**,不是一个新模块

**不新建模块,不新增权限码。**

理由是这个仓库反复得到的同一条:每一支臂的权限**就是它读的那份数据自己的 RLS**
(OPS-15 的规矩)。造一个 `module.exec.view`,等于让"能不能看见这个数"与
"能不能看见这个数背后的数据"变成两个可以分开的答案 —— 而它们一旦分开,
一定会分叉,并且分叉的那一天没有任何闸门会响。

所以:**四个人 = 四个授权包**,每个包由既有的模块码与数据码组成;
**第一屏 = 既有看板 + 按人过滤的臂集合**。臂本身不改。

* **Vince 跑 `gm`,一字不改。** 实测:`gm` 持 32 个权限,四个数据码(`view_banking`
  / `view_prices` / `view_reviews` / `view_sales`)与全部业务模块的 view+edit 都在,
  缺的只有系统管理那几个。**它够了。** 唯一值得他自己回答一次的问题是要不要
  在 HR/财务/计价上保留 edit —— 那是一个偏好,不是一个缺口,所以不在这一刀里替他决定。
* **Sandra ≈ `sales` + 合规读**(`module.suppliers.view` 供资质那两支;
  `module.pricing.view` 她已有)。
* **Phua ≈ `operations`**(已含 processing / inbound / inventory / stocktakes 的
  view+edit),**加 `module.pricing.view`** —— 回收率与计价面板要读它。
* **Tim 跑 `finance` + `hr`**(公司职能向他汇总),或按需要归并成一个包。

---

## 四 · 已定:两处权限颗粒度,**现在都不拆**,而触发条件写下来

EXEC-0 量过两处捆绑,两处都恰好压在 Sandra / Phua 的边界上:

1. **`module.pricing.view` 把"公开行情"与"商务条款"捆在一起** —— `sales` 与
   `procurement` 今天都持 `module.pricing.edit`,于是能查一个金属行情的人,
   也能改计价公式。
2. **`data.view_prices` 把"批次成本"与"客户售价"捆在一起** —— `sales` 因售价
   而持有它,于是也看得见批次单位成本;`procurement` 因采购价而持有它。

**两处都不拆。** 拆的代价是具体的,而收益今天是零:

* 拆 `module.pricing.view` 会撞上 `lib/modules.ts` **一个模块一个权限码**的结构
  —— 那不是加一行,是改导航/模块机器本身;
* 拆 `data.view_prices` 要动每一张带 `unit_cost_base` / `unit_price` 的 `_masked`
  视图、每一处 `MaskedValue`,以及 `AGENTS.md` 常设决定二里已经钉死的批次毛利谓词。

**而今天没有人被这个捆绑伤到:四个人里没有任何一对需要"你看得见我看不见"。**

> **触发条件(写下来,免得下次再从头论证一遍):
> 第一个【业务线层级】的商务或采购岗位入职** —— 也就是第一个"应该看客户售价、
> 但不应该看批次成本"或者反过来的人。那一天这两条重新拿出来看,
> 而不是等到有人在屏幕上看见了不该看的数。

---

## 五 · 已定:收货差异 v1 = **已订 vs 已收**

`inbound_batches` 带 `purchase_order_id` / `purchase_order_line_id`,所以
**已订 vs 已收**今天就 join 得出来 —— 那是 v1。

**"申报 vs 实测"(重量、品位、杂质)今天记录不下来** —— 收货记录上没有任何
一对"申报值/实测值"的列。它是**一次未来的收货刀**,而且它本来就在 Doc 1 的
[SPECIFY] 清单里(收货那一节问的正是"到货与申报不符怎么记")——
**所以它是一件被问过、没有做的事,不是一个疏漏。** 排队,不硬凑。

---

## 六 · 已定:客户审计报告是一份**签发档族的单据**

不是一个页面。理由在第一节:它是对外的,而对外单据迟早要回答
"你当时发出去的是哪一版"。这个系统对那个问题已经有一整套答案 ——
桶 + `sha256` + `<doc>_issues` + 唯一写入口的 `record_*_issue`,今天有六份
(po / so / shipment / cn / qt / invoice),它会是第七份。

**内容上的两条硬约束:**

1. **出处跟着每一个数字走。** 报告读 `processing_metal_recovery`,而那张视图的
   `input_source` / `output_source`(`assay` / `manual` / `mixed` / `unknown`)
   与 `recovery_blocked_by` 必须**印在数字旁边**,不能进脚注。
   实测(2026-08-16):投料侧 **19 条含量行的 `content_source` 全部为空**,
   两侧都测过的 (加工单, 金属) 组合**只有 3 个** —— 今天发出去的任何回收率,
   都是拿手敲的百分比算出来的。
2. **`NULL` 渲染成「算不出来,因为 X」,永远不是 0、不是 100%。**
   视图的 `recovery_blocked_by` 就是那个 X,它是可枚举的。
   一个 `?? 0` 会把"没测过"变成"回收率为零",而那是发给客户的一句假话。

追溯链那一半今天就齐:`batch_lineage`(`depth` / `via_run_code` /
`parent_kind` / `parent_batch_id` / `quantity_consumed`,含再加工的多层链)。

---

## 七 · 已定:组织图填充的三件事,一刀做完

1. **所有员工都录进去**(`employees`:`code` / `legal_name` / `department_id` /
   `job_title` / `manager_id` / `hire_date` / `employment_status`;`departments`
   自带 `parent_department_id`,所以部门树本来就表达得了)。
   实测今天:**3 名员工、1 个部门、`manager_id` 一个都没设、`user_id` 只连了 1 个。**
2. **`user_id` 只连【有登录账号的人】** —— 不是每个员工都需要账号,而给一个不存在
   的账号连一根线,只会让"这个人没账号"与"这根线连错了"长得一样。
3. **同一刀把缺失的外键补上。** `docs/known-issues.md` 记着
   `employees.user_id` **没有指向 `auth.users` 的外键** —— 一个敲错的 uuid 今天
   **静默入库**,而这一刀正是要大批量地敲这一列。**在敲之前补,不是之后。**

**落地那天开始工作的东西:** 绩效评估的分派路径(`/my-reviews/[id]` 今天要靠
冒烟自己造两个临时员工才走得到)、以及签发人姓名 —— INV-2b 的走查里那一列
现在显示的是「该账号未关联员工档案」,那正是这条线没连的样子。

---

## 八 · 这份文件之后

**EXEC-1 = 行情陈旧臂 + 未履约订单臂**,两支都从**这份文件**取规格
(第二节 Sandra 的 a 与 c,以及 `docs/dashboard-arm-inventory.md` 里 ASY-3 那一节),
不从对话里取。

**没有排进 EXEC-1 的,以及为什么:**
* 证书到期两支 —— 挂在 `docs/compliance-scoping.md` 的 A3 决定上,那个决定还没做;
* 批次毛利 —— 谓词已定但"哪些限定词跟着数字走""已过账 COGS 还是当前成本"两个
  设计问题未决,它值一整刀;
* 危废存储时限 —— **等牌照文本**(第二节 Vince c)。
