# APR-0 — 审批链勘察(2026-09-22)

**只读勘察。除本文件、`docs/approvals.md` 与 `docs/known-issues.md` 外,不动任何东西。**
没有迁移、没有 gate、没有构建、没有冒烟、没有浏览器探针。

**开工闸(通过):** 工作区干净;`HEAD` = `origin/main` = `git ls-remote origin main`
= `a0de0f19319c6fe6fc018fd2a44a4b42931ff6a1`(DRAFT-7 收尾)。

---

## ★ 读数的身份,一次说清

**本文所有线上读数都是:以 `postgres` 身份、经 Management API 执行,`rolbypassrls = true`
—— 即 RLS 整个不参与。** 每一处读数都点名了它读的是**基表**还是**视图/系统视图**。
☞ 这条来自 `AGENTS.md`「一个「0 行」的读数,先问它是【谁】读的」:本文里的数
**全部落在基表与系统目录上**,没有一个落在带 `has_permission()` 谓词的视图上,
所以它们是真行数,不是一次权限拒绝。

★ **`approvals_readiness()` 本身【没有】在本勘察中被调用。** 它开头是
`PERFORM require_permission('module.finance.view')`,而 `postgres` 没有 JWT、
`auth.uid()` 为 NULL —— 调它只会拒绝。**本文的 readiness 结论是逐项重算它的函数体得到的**,
读的是它读的同一批表与同一批函数(`real_role_holders` / `role_can_see_amounts`)。
这一点照直写出来,因为**一次转述和一次测量在报告里长得一样**。

---

## ★★★ §0 · 委托书交给本刀的「已知」里,三条是假的

委托书自己写着「re-check, do not trust」。照做了,而收获比预期大 ——
**这一节是本次勘察最值钱的产出,它改变了 APR-1 是什么。**

| # | 委托书说的 | ★ 实测 |
|--:|---|---|
| ① | 「An approval engine exists but **nothing in the UI can turn it on**」 | **半真。** `/settings/approvals` **存在**,而且**已经**是 admin 把关的(`action.manage_permissions`)—— D7 / IA-BUILD-1 早就把它搬到了 Tim 裁定的位置。**缺的不是那扇窗,是写路径:** `app/` 底下没有任何东西写那四列(`app/finance/settings/actions.ts` 只导出 `setPeriodLock`)。 |
| ② | 「approver resolution 可能走 `manager_id`,于是可能路由到没有人」 | ★ **这条引擎里【没有】任何 manager 链。** `require_approver_for(p_level)` 从 `finance_settings` 取角色码,再要求 `auth.uid() ∈ real_role_holders(角色)`。**按角色,不按人,不按汇报线。**<br>☞ 顺带:组织架构也不空 —— `employees` 基表 **7 人在册 / 5 人有上级 / 6 人有账号**,`departments` **1 个**。委托书记的「一个员工、没有人有上级」是旧读数。 |
| ③ | 「approvals **cannot** be switched on」(`docs/approvals.md` §3) | ★★ **已经不成立。两级各有一个真的登录得了、且看得见金额的持有人。`can_enable = true`。** 详见下一格。 |

### ★★ ③ 的全文,因为它是本刀的头条

**读 `auth.users`(基表)、`user_roles`(基表)与 `real_role_holders()`,2026-09-22:**

| level | 角色 | holders_total | real_holders | can_see_amounts | 谁 |
|---|---|--:|--:|---|---|
| 1 | `finance` | 1 | ★ **1** | true | `chooer@evoltrya.test` |
| 2 | `cfo` | 1 | **1** | true | `admin@swm-os.test` |

**六个账号【全部】已确认、未封禁、未删除。** 于是逐项重算 `approvals_readiness()` 的函数体:

```
blocking = []            can_enable  = true
pending_purchase_orders = 0          can_disable = true
```

★ **`docs/approvals.md` §3 自己写下的到期条件("a second account can actually sign in")
【已经兑现】,而那份文档三个星期里一直在说相反的话。** 本刀已在那一节原地划掉并留下收据。

> ### ☞ 这一条的教训,比这一条本身耐用
> ★ **一个写进文档的「到期条件」不会自己触发。** 它写得很准,它成真了,而没有任何东西在看它。
> CHAIN-CONFIG-1 与 APR-0 之间的每一刀读到的都是一条**已经过期的阻塞**。
> ☞ 这正是 `AGENTS.md`「委托书里的【数】来自上一份报告,而不是来自一次测量」那一族的
> **又一张脸**,而这一次它穿的是**一条被郑重论证过的裁定**的衣服 ——
> 比一个光秃秃的整数更难怀疑。**便宜的解药只有一个:勘察重量它拿到的每一条前提,
> 包括那些以「已定事实」的形式交下来的。**

**另外两处顺手查实的漂移(已在 `docs/approvals.md` 原地记下):**

* **`action.manage_permissions` 不是 `admin` 独有** —— ★ `cco` 也持有(`sandra@evoltrya.test`,
  共 **37** 个码,含 `module.purchasing.edit` 与 `data.view_prices`)。§0b 写着「it is the only
  holder」,那句话今天是假的。**Tim 裁定:接受,写下来,本次不撤。**
* **`cfo` 持 5 个码,不是 EQP-PAY-1 钉的 4 个** —— 多的是 `module.logistics.view`,由
  **同一天**的 `navreg1-logistics-gets-its-own-code` 授予,理由正当(把 logistics 拆成独立码,
  「可见性不变」)。**不是漂移,但那条「self-check refuses any other number」的自证
  在大约一天之内就失效了。** ★ 结构上要紧的那一条仍然成立:**`cfo` 依然不持
  `module.purchasing.edit`** —— 审批人提不了他自己批的单。

---

## §1 · 引擎【如今是怎么建的】

### 1.1 构成(对象逐个点名)

| 类别 | 对象 | 镜像 file:line | 它做什么 |
|---|---|---|---|
| 表 | `approval_log` | `db/tables/approval_log.sql:35` | 只增不改的留痕。主体是 `(subject_type, subject_id)` |
| 约束 | `approval_log_subject_type_check` | `db/tables/approval_log.sql:46-52` | ★ **九个取值的白名单 —— 扩单据类型时唯一要改的枚举** |
| 约束 | `approval_log_amount_shape` | `db/tables/approval_log.sql:93` | 金额四列**全有或全无** |
| 触发器 | `trg_approval_log_append_only` | `db/tables/approval_log.sql:116` | UPDATE / DELETE 一律拒,两种分开报名 |
| 函数 | `guard_approval_log_append_only()` | `db/functions/guard_approval_log_append_only.sql:1` | 上一行的函数体 |
| 函数 | `record_approval_decision(...)` | `db/functions/record_approval_decision.sql:1` | ★ **留痕的唯一写入口**。先核对主体存在,再冻结编号与金额 |
| 函数 | `approvals_enabled()` | `db/functions/approvals_enabled.sql:1` | 读 `finance_settings.approvals_enabled`,`COALESCE(..., false)` |
| 函数 | `approval_level_for(numeric)` | `db/functions/approval_level_for.sql:1` | 按本位币金额分档:`>= 阈值` → 2,否则 1。阈值未设 / 金额为 NULL **一律 RAISE** |
| 函数 | `require_approver_for(smallint)` | `db/functions/require_approver_for.sql:1` | ★ **授权检查** —— 取该级角色码,要求调用者在 `real_role_holders()` 里 |
| 函数 | `real_role_holders(text)` | `db/functions/real_role_holders.sql:36` | ★ **「谁算一个真的持有人」的唯一定义**(C-1 之后是 `real_role_grants` 的投影) |
| 函数 | `real_role_grants(text)` | `db/functions/real_role_grants.sql` | 四条判据住在这里:未撤销 · 已确认 · 未封禁 · 未删除 |
| 函数 | `role_can_see_amounts(text)` | — | R4:这个**角色**看不看得见金额 |
| 函数 | `approvals_readiness()` | `db/functions/approvals_readiness.sql:26` | 屏幕与闸读的**同一份判据**;返回两级各自的 total / real / sees |
| 函数 | `guard_approvals_switch()` | `db/functions/guard_approvals_switch.sql:15` | 开关的两道闸(开:策略齐+两级有人+看得见;关:在途单据点名) |
| 触发器 | `trg_approvals_switch` | `finance_settings` 上 `BEFORE UPDATE FOR EACH ROW` | 上一行的挂载点 |
| 函数 | `void_approval_on_amount_increase()` | `db/functions/void_approval_on_amount_increase.sql:1` | 金额被改到**更高一档** → 原审批作废并重新路由 |
| 视图 | `zzz_function_grants` | `db/views/zzz_function_grants.sql` | 把三支内层函数对 `authenticated` 收权 |
| 页面 | `/settings/approvals` | `app/settings/approvals/page.tsx:37` | ★ **只读**状态面板,闸是 `action.manage_permissions` |
| 组件 | `ApprovalsPanel` | `app/settings/approvals/ApprovalsPanel.tsx:36` | 三种持有人状态分三句话说 |

### 1.2 哪些提交路径【今天】读这台引擎

| 单据 | 提交路径 | 决定路径 | 审批未生效(`enabled = false`)时它做什么 |
|---|---|---|---|
| **采购单** | `create_purchase_order` (`:9` 取 `approvals_enabled()`) | `approve_purchase_order` / `reject_purchase_order` | ★ 单据**生为 `confirmed`/`approved`**,`approved_at = now()`,并写一行 `auto_approved` 留痕,note 逐字写明「审批流未启用 —— 系统直接盖章,没有人做过这个决定」 |
| **工单** | `release_work_order` (`:10`) | 同一支(放行即决定) | ★ 同上:直接放行 + 一行 `auto_approved` |
| **请假** | `submit_leave_request` | `decide_leave_request` | ★ **完全不读这台引擎**。自带引擎,只是**写这张留痕表** |
| **医疗申报** | `submit_medical_claim` | `decide_medical_claim` | 同上 |
| **绩效评估** | `submit_review` | `approve_review` / `acknowledge_review` | 同上 |

★★ **「有没有路径绕过它」——【有,而且是四条,它们连接都没接上】:**
`payment` · `expense` · `pricing_formula` · `stocktake` **四个 subject_type 在枚举里,
而【没有任何一支函数写它们】。** 实测 `record_expense` / `record_payment` /
`apply_prepayment` / `record_po_issue` / `amend_purchase_order` 里
`record_approval_decision` 出现 **0 次**。
☞ 所以这不是「绕过」,是**从来没接上过** —— 而它比绕过更难发现:
**枚举里有那个名字,读的人会以为那条路是通的。**

### 1.3 策略那一行:四列,各是什么,谁改得了

**实测(读 `finance_settings` 基表):`enabled = false` · `level1 = finance` · `level2 = cfo` · `threshold = 1000`。**

| 列 | 含义 | 今天谁改得了 | 经由什么 |
|---|---|---|---|
| `approvals_enabled` | 总开关 | ★ 持 `module.finance.edit` 的人:`admin` · `finance` · `gm` | ★ **界面上没有任何路径** —— 那一行是**直接改库**改出来的 |
| `approval_level1_role_code` | 一级审批角色 | 同上 | 同上 |
| `approval_level2_role_code` | 二级审批角色 | 同上 | 同上 |
| `approval_threshold_base` | ★ **本位币**金额门槛(SGD),`>=` 归二级 | 同上 | 同上 |

★ **「谁改得了」这一栏是 APR-1 的全部理由,详见 §2.2。**

### 1.4 审批人怎么解析出来 —— 以及它今天在线上找不找得到人

```
require_approver_for(level)
  → finance_settings.approval_level{1,2}_role_code        （角色码,不是人）
  → real_role_holders(角色码)                              （四条判据)
  → auth.uid() 在不在里面?不在 → RAISE 'APPROVAL_NOT_AUTHORISED|级别|角色'
```

★ **没有汇报线、没有具名审批人、没有代理人、没有升级。**(§1 的「无代理人」是一条裁定,
写在 `docs/approvals.md` §1,并且跟着 `approvals_readiness()` 的返回值走。)

**今天找得到人吗 —— 找得到。逐项读数已在 §0 给出:两级各 1 个真持有人,两级都看得见金额。**
☞ 委托书担心的那条「走 manager_id 可能路由到没有人」在这条引擎上**不适用**,
因为它压根不走 manager_id。

### 1.5 自批:拒不拒?——【五条链里只有两条拒】

| 决定函数 | 拒自批吗 | 判据 |
|---|---|---|
| `approve_purchase_order` | ★ **拒** | `db/functions/approve_purchase_order.sql:45` — `created_by = auth.uid()` → `SELF_APPROVAL_FORBIDDEN` |
| `approve_review` | ★ **拒** | `db/functions/approve_review.sql:28` — `submitted_by = auth.uid()` |
| `decide_leave_request` | ★ **不拒** | 全文无 `SELF_APPROVAL`;只有 `require_permission('module.hr.edit')` |
| `decide_medical_claim` | ★ **不拒** | 同上 |
| `release_work_order` | ★ **不拒** | 只有 `require_permission('module.processing.edit')` + `require_approver_for(1)` |

☞ **也就是说:一个持 `module.hr.edit` 的人今天可以批准自己的请假单。**
Tim 已裁(Q6):**统一拒,复用 `SELF_APPROVAL_FORBIDDEN`。**

### 1.6 开关翻过去,在途的单据会怎么样

**开 → 关(`guard_approvals_switch.sql:76`):** 先数还有几张 pending 的采购单,
**大于 0 就按名拒绝**,并**点名是哪几张**:`APPROVALS_CANNOT_DISABLE_WITH_PENDING|数量|单号`。
★ 理由写在那支函数抬头:关掉之后 `approve_purchase_order` 抛 `APPROVALS_NOT_ENABLED`,
**pending 的单会永远停在 pending** —— 批不了也收不了货。
☞ **今天 pending = 0,所以现在关是自由的。这个自由在第一张单进来的那一刻结束。**

**关 → 开(同一支,`:31`):** 三列必须齐,两级都必须**有真持有人**且**看得见金额**,
否则按名拒(六种错误码各自点名)。★ **这道闸让「开着但没配」成为一个【到不了】的状态**,
而不是「到了会拒绝」—— 后者会把在途单据搁死。

★ **一个本刀没有找到答案、而它也不该在这里被发明的空白:**
**已经 pending 的单,在关掉再打开之后会怎样?** 它仍然是 `pending`,仍然可以被批 ——
因为没有任何东西在关闭时改写 `approval_status`。**但今天到不了这个状态**(关闭那道闸不许
带着 pending 关),所以它是一个**结构上不可达**的情形,不是一个缺陷。记下来只是为了
让下一个读的人不必重新推一遍。

---

## §2 · admin 那个开关

### 2.1 「admin」对应哪个码,线上谁持有,页面在不在

* **码:`action.manage_permissions`**(`lib/modules.ts:827`,`/settings/approvals` 那一条注册表条目)。
* **页面:在。** `app/settings/approvals/page.tsx` —— ★ **而它是只读的**,并且**把这件事印在屏幕上**
  (`finance.approvals.noConfigUi` 那条琥珀色提示)。
* ★ **线上持有者:`admin` 与 `cco`,各 1 个真持有人。**(不是委托书以为的 admin 独一份。)

⚠ **一处小的不一致,今天不咬人,但它会漂:** 页面的闸是 `action.manage_permissions`,
而它调的 `approvals_readiness()` 内部要求的是 **`module.finance.view`**
(`db/functions/approvals_readiness.sql:42`)。**两个码,同一块屏幕。**
今天 `admin` 与 `cco` **都**持 `module.finance.view`,所以看不出问题;
**哪一天有人持 `action.manage_permissions` 而不持 `module.finance.view`,
那一页会渲染成 `finance.approvals.readError`。** 登记在这里,不在这一刀修。

### 2.2 ★★ 操作员要把审批跑起来,那块屏幕上需要什么 —— 以及哪些今天有写路径

| 要能改的东西 | 引擎读它吗 | ★ 今天有写路径吗 |
|---|---|---|
| `approvals_enabled` 开/关 | ✓ `approvals_enabled()` | ★ **没有** |
| `approval_level1_role_code` | ✓ `require_approver_for(1)` | ★ **没有** |
| `approval_level2_role_code` | ✓ `require_approver_for(2)` | ★ **没有** |
| `approval_threshold_base` | ✓ `approval_level_for()` | ★ **没有** |
| 「这一级有几个人 / 看不看得见金额」 | ✓ 闸与屏幕同源 | ✓ 只读,已经在屏幕上 |
| 「开不开得了 / 关不关得掉」 | ✓ `can_enable` / `can_disable` | ✓ 只读,已经在屏幕上 |

★ **四列写路径:零。** 也就是说这块面板**只差写那一半**,读那一半(含三种持有人状态、
两级的金额可见性、翻开关会发生什么、无代理人那条裁定)**已经建好了**。

### 2.3 ★★ 写闸对不上 Tim 的裁定 —— 本刀的第二个缺陷

`finance_settings` 的写闸是一条**表级**触发器 `enforce_write_permission('module.finance.edit')`。
**而页面的闸是 `action.manage_permissions`。两批人不重合:**

| 角色 | 看得见那一页 | ★ 写得了 `finance_settings` | 真持有人 |
|---|---|---|---|
| `admin` | ✓ | ✓ | 1 |
| `cco` | ✓ | ✗ | 1 |
| ★ `finance` | ✗ | ★ **✓** | 1 —— ★ **一级审批人本人** |
| `gm` | ✗ | **✓** | 1 |

★★ **一级审批角色持有那张表的写权限。** 今天不可达(没有写路径),
**而 APR-1 一加上写路径,若只在 UI 那一侧按 `action.manage_permissions` 把关,
分离就只存在于屏幕上。**
☞ Tim 的处置(Q2):RPC **外加**一道列作用域的守卫。已登记
`APR0-APPROVALS-SWITCH-WRITE-GATE`。

### 2.4 翻开关要不要留痕?现成的痕迹接得住吗

**要 —— 而现成的接不住。实测:**

* ★ **库里没有任何设置/配置类的审计表。** 14 张 history/log 表**全部是逐单据的**
  (`purchase_order_history` · `employment_history` · `pricing_formula_history` …)。
* ★ **`approval_log` 也接不住**:它的主体是 `(subject_type, subject_id)`,而 `subject_id`
  是一个指向**单据行**的 `uuid`;`finance_settings` 是一张**单行表**,没有那样的 id。
  硬塞进去要么编一个假 subject_id,要么给枚举加一个不是单据的取值 —— **两者都是把一条
  「策略变更」伪装成一次「对某张单据的决定」。**

☞ Tim 的处置(Q7):**新建 `finance_settings_history`,只增不改,由同一支 RPC 写**,
照 `pricing_formula_history` 的形状(谁 · 何时 · 四列的 old → new)。

---

## §3 · 扩到【每一种流转单据】(Tim 重写的 Q5)

### 3.1 逐项对照表

**口径:「活跃行数」以 `postgres` 身份读【基表】,RLS 不参与,含软删行除非另注。**
「要补什么」四栏对应 §3.2 那四处。

#### 采购

| 项 | 表 | 动作(函数) | 带金额? | 已是 subject_type? | 活跃行 | ★ 要补什么 |
|---|---|---|---|---|--:|---|
| 采购单 | `purchase_orders` | `create_` / `approve_` / `reject_purchase_order` | ✓ `estimated_total_ccy` × `fx_rate` | ✓ | 11 | ★ **已全通** —— 唯一一条端到端建好的链 |
| 采购单**变更** | `purchase_orders` (+`purchase_order_history`) | `amend_purchase_order` | ✓ 同上 | ✓(复用 `purchase_order`) | 10 条变更史 | ③ 提交闸 + ④ 决定函数。★ **注意它与 `void_approval_on_amount_increase` 重叠**:今天「改价抬过档」已经会自动作废重路由,**所以这一项要先裁「变更本身要不要独立审批」,否则会有两套机制管同一件事** |
| 付款 | `payments` | `record_payment` | ✓ `amount_base` | ✓ **(枚举里有,没人写)** | 13 | ②已备好 · ③ ④ 全缺 · ①不用动 · RLS 那一支**已在**(`module.finance.view`) |
| ★ 收货(入库) | `inbound_batches` | `receive_inbound_batch_against_po` / `create_inbound_batch` | ✗ 表头无金额(`unit_price` 在行上,且可能 `unpriced`) | ✗ | 24 | ① ② ③ ④ **全缺**。★ **按 Q4 走一级**(它没有表头金额,而且入库时常常还没有价) |

#### 销售

| 项 | 表 | 动作 | 带金额? | 已是 subject_type? | 活跃行 | ★ 要补什么 |
|---|---|---|---|---|--:|---|
| 报价 | `quotes` | `record_qt_issue` / `convert_quote` | ★ **表头无合计**(只有 `currency` + `fx_rate`) | ✗ | 3 | ① ② ③ ④ 全缺 + ★ **金额问题**,见 §3.3 |
| 销售订单 | `sales_orders` | `create_sales_order` / `set_sales_order_status` | ★ **表头无合计** | ✗ | 6 | 同上 |
| 销售订单**变更** | `sales_orders` (+`sales_order_history`) | `amend_sales_order` | ★ 同上 | ✗ | 22 条变更史 | 同上 |
| 发票 | `invoices` | `create_invoice` / `create_order_invoice` / `void_invoice` | ✓ **`total_base` 有** | ✗ | 9 | ① ② ③ ④ 全缺(金额现成) |
| 贷项通知单 | `credit_notes` | `create_credit_note` / `record_cn_issue` | ★ **表头无合计**(有 `currency`/`fx_rate`/`entry_id`) | ✗ | 1 | ① ② ③ ④ 全缺 + 金额问题。★ **而且它【建出来就过账】** —— 没有 draft 态,见 §3.3 |

#### 物流

| 项 | 表 | 动作 | 带金额? | 已是 subject_type? | 活跃行 | ★ 要补什么 |
|---|---|---|---|---|--:|---|
| ★ 发运 | `shipments` | `ship_order`(`module.sales.edit`) | ✗ | ✗ | 3 | ★★ **它没有状态列** —— 整张表是 `id/code/sales_order_id/ship_date/notes/container_id`。**一次发运是一条【已经发生的事】的记录,不是一份走流程的单据。** 要审批它,得先给它一个状态;**那是一次建模改动,不是接线** |
| ★★ 装柜 | — | ★ **没有对应的动作** | — | ✗ | — | ★★ **照直说:树里【没有】「装柜」这个动作。** `containers` **没有状态列**;「装柜」是 `container_milestones` 里一行 `milestone = 'loaded'`(该表 17 行,`containers` 18 行)。**它是一条里程碑事实,不是一个决定** —— 没有 `load_container()` 这样的函数。**要审批它,得先发明它。本刀不发明。** |
| 货运单据 | `freight_documents` | `record_freight_document` / `record_export_freight_document` / `reverse_freight_document` | ✓ **`amount_base` 有** | ✗ | 4 | ① ② ③ ④ 全缺(金额现成,有 `status`) |

#### 生产

| 项 | 表 | 动作 | 带金额? | 已是 subject_type? | 活跃行 | ★ 要补什么 |
|---|---|---|---|---|--:|---|
| 工单 | `work_orders` | `release_work_order` | ✗ | ✓ | 1 | ★ **已通,而且它是 Q4 的先例**(无金额 → 恒定一级)。⚠ **但它的 RLS 读那一支是缺的** —— 见 §3.4 |
| 加工单提交 | `processing_runs` | `commit_processing_run`(`module.processing.edit`) | ✓ `total_cost_base` | ✗ | 14(committed 10) | ① ② ③ ④ 全缺。★ **成本可能不完整**(`cost_incomplete`),所以金额档位可能在提交时还不成立 —— 见 §3.3 |
| 盘点 | `stocktakes` | `post_stocktake`(`module.stocktakes.edit`) | ✗ | ✓ **(枚举里有,没人写)** | 10 | ②已备好 · ③ ④ 缺 · RLS 那一支**已在**。★ **按 Q4 走一级** |
| 固定资产处置 | `fixed_assets` | `dispose_fixed_asset`(`module.finance.edit`) | ✓ `disposal_proceeds_base` | ✗ | 2(已处置 **0**) | ① ② ③ ④ 全缺。★ **活跃行 0 意味着这条链上线时【没有历史包袱】,是最便宜的一条** |

#### 人事

| 项 | 表 | 动作 | 带金额? | 已是 subject_type? | 活跃行 | ★ 要补什么 |
|---|---|---|---|---|--:|---|
| 请假 | `leave_requests` | `decide_leave_request` | ✗(天数不是钱) | ✓ | 3 | ★ **有自己的引擎,只写留痕**。要的是:③ 接上 `approvals_enabled()` / `require_approver_for(1)` + ★ **Q6 的自批拒绝** |
| 医疗申报 | `medical_claims` | `decide_medical_claim` | ✓ `amount_sgd`(已是本位币口径) | ✓ | 1 | 同上,★ 而且它**带金额,所以真的会分档** |
| ★ 报销单 | `expense_claims` | `submit_expense_claim` / `decide_expense_claim`(`module.finance.edit`) | ✓ `amount_ccy` | ★ **✗ —— 唯一一个漏在枚举外的审批形状单据** | 4 | ① ② ③ ④ 全缺。★ **它的状态就是审批态**(`submitted/withdrawn/approved/rejected`),**最贴合、最该先接** |
| 薪资 | `payroll_periods` | `post_payroll_period`(`module.hr.edit`) | ✓ `gross_total` / `net_pay_total` 等 | ✗ | 1(`payroll_lines` 1) | ① ② ③ ④ 全缺。★ **要先裁用哪个数分档**(gross?net?),见 §3.3 |
| 绩效评估 | `performance_reviews` | `submit_` / `approve_` / `acknowledge_review` | ✗ | ✓ | ★ **0** | ★ **已拒自批**。要的是 ③ 接上引擎。活跃行 0 → 上线无包袱 |

#### 财务

| 项 | 表 | 动作 | 带金额? | 已是 subject_type? | 活跃行 | ★ 要补什么 |
|---|---|---|---|---|--:|---|
| 记账凭证 | `journal_entries` | `post_journal_entry` / `reverse_journal_entry` | ★ **表头【一个金额列都没有】**(金额在 `journal_lines` 上) | ✗ | ★ **82 —— 全场最多** | ① ② ③ ④ 全缺 + ★ **金额问题最重**,见 §3.3。⚠ **82 行、而且总账是所有报表的底座 —— 这一项的爆炸半径最大** |
| 定价公式 | `pricing_formulas` | `commit_pricing_terms` / 公式编辑(写 `pricing_formula_history`) | ✗ | ✓ **(枚举里有,没人写)** | 1 | ②已备好 · ③ ④ 缺 · RLS 那一支**已在**(`module.pricing.view`)。★ **按 Q4 走一级** |

### 3.2 ★★ 加一个 subject_type 要动【四处】—— 而上一次只动了两处半

| # | 要动的地方 | 它不做会怎样 |
|--:|---|---|
| ① | `approval_log.subject_type` 的 **CHECK 枚举** | `record_approval_decision` 抛 `APPROVAL_SUBJECT_TYPE_UNKNOWN` —— **响亮** |
| ② | `record_approval_decision` 的 **`CASE` 分支**(取编号、冻结金额) | 同上 —— **响亮** |
| ③ | **提交路径**:读 `approvals_enabled()`,分岔成「等人批」/「auto_approved 盖章」 | 单据照常建立,**留痕里什么都没有** —— 安静 |
| ④ | ★★ **`approval_log` 的 RLS 读策略那一支** | ★★ **写得进、读不出,对每一个人都是 0 行,而且不报错** —— **完全安静** |

★★ **WO-1b 做了 ①②③,漏了 ④。** 实测今天线上 `approval_log` 有 **1 行** `work_order`,
**任何 `authenticated` 身份读到的是 0 行。** 已登记 `APR0-WORK-ORDER-APPROVALS-INVISIBLE`,
Tim 已把它放进 APR-1。

☞ **APR-2 的每一个单据类型都要逐项走这四格,而 ④ 是唯一一个不做也不会有任何东西变红的。**

### 3.3 ★★ 按金额路由,撞上一件委托书没有预料到的事

Tim 的路由规则是:**带金额的按 1000 分档,不带金额的恒定一级。**
★ **而「带不带金额」不是一个二分,它是三分** —— 实测:

| 类 | 谁 | 后果 |
|---|---|---|
| **表头有本位币金额** | `purchase_orders`(算得出) · `payments` · `expenses` · `invoices` · `freight_documents` · `medical_claims` · `expense_claims` · `fixed_assets`(处置价) · `payroll_periods` · `processing_runs` | ★ **直接可用**,`approval_level_for()` 拿来就比 |
| **完全没有金额** | `work_orders` · `stocktakes` · `pricing_formulas` · `leave_requests` · `performance_reviews` · `inbound_batches`(表头) · `shipments` | ★ **Q4 的规则直接适用**,恒定一级 |
| ★★ **有钱,但表头上没有那个数** | `sales_orders` · `quotes` · `credit_notes` · `journal_entries` | ★★ **两条规则【都不适用】** |

★★ **第三类是这次扩展里真正的未决项,而它不是接线问题,是建模问题。**
`sales_orders` / `quotes` / `credit_notes` 只有 `currency` + `fx_rate`,合计在明细行上;
`journal_entries` 表头**一个金额列都没有**。要按金额路由,只有两条路:

* **(a) 决定时现算合计**(`SUM` 明细 × `fx_rate`)—— ⚠ 但 `approval_log` 的设计是
  **把金额冻结在决定当时**(`db/tables/approval_log.sql:27`),而**现算的数会随明细变**;
  更要紧的是 `void_approval_on_amount_increase` 那条「改价抬档就作废」在采购单上
  靠的是**表头那一列的 OLD/NEW**,明细级的改动它**看不见**。
* **(b) 给表头加一列维护出来的合计** —— 与 `purchase_orders.estimated_total_ccy` 同形,
  ★ **这是一次真的 schema 改动 + 一套维护它的触发器**,不是接线。

☞ **本刀不选。** 它是 §5 里交回给 Tim 的第一个问题。
★ 另外两个更小的同族未决:**加工单**的成本可能 `cost_incomplete`(提交时那个数可能还不成立),
**薪资**要裁按 gross 还是 net 分档。

### 3.4 ★ 完整性:Tim 的原话,照录

> **「whatever is found missing in real use is added later.」**

☞ 所以上面这张表**不声称穷尽**。它声称的是两件更窄、也更能核对的事:
**① 它逐项走过了 Tim 点名的那份清单;② 清单上对不到代码的那两项(装柜、发运)
是【照直说没有】,不是被编出来一个。**

---

## §4 · 用现有的六个账号,这条流走不走得通

### 4.1 六个账号,逐个点名(读 `auth.users` + `user_roles` 基表)

| 邮箱 | 已确认 | 封禁 | 删除 | 在册角色 | 已撤销 |
|---|---|---|---|---|---|
| `admin@swm-os.test` | ✓ | ✗ | ✗ | ★ `admin`, `cfo` | — |
| `chooer@evoltrya.test` | ✓ | ✗ | ✗ | ★ `finance` | — |
| `fusheng@evoltrya.test` | ✓ | ✗ | ✗ | `warehouse` | — |
| `phua@evolytra.test` | ✓ | ✗ | ✗ | `cto` | `operations` |
| `sandra@evoltrya.test` | ✓ | ✗ | ✗ | ★ `cco` | — |
| `vince@evoltrya.test` | ✓ | ✗ | ✗ | `gm` | — |

★ **六个【全部】登录得了。** 委托书说「不要假设只有一个能登录」—— 照做了,答案是六个都能。

### 4.2 ★ 走得通。一级那条臂用现有账号就够

**权限矩阵(读 `role_permissions` 基表):**

| 角色 | `module.purchasing.edit`(提单) | `module.purchasing.view` | `data.view_prices` | `module.finance.edit` |
|---|---|---|---|---|
| `admin` | ✓ | ✓ | ✓ | ✓ |
| `cco` | ✓ | ✓ | ✓ | ✗ |
| `cto` | ✓ | ✓ | ✓ | ✗ |
| ★ `finance` | ✓ | ✓ | ✓ | ✓ |
| `gm` | ✓ | ✓ | ✓ | ✓ |
| `cfo` | ★ **✗** | ✓ | ✓ | ✗ |
| `warehouse` | ✗ | ✗ | ✗ | ✗ |

**一级那条臂(金额 < SGD 1,000):**

| 谁 | 干什么 | 他持有需要的权限吗 |
|---|---|---|
| ★ **vince@evoltrya.test**(`gm`) | 提一张 **< 1000** 的采购单 | ✓ `module.purchasing.edit` + `data.view_prices` |
| ★ **chooer@evoltrya.test**(`finance`) | 批它 | ✓ `module.purchasing.view` + `data.view_prices` + 是 `finance` 的真持有人 |

★ **两个不同的人,所以 `SELF_APPROVAL_FORBIDDEN` 不会挡。一级这条臂【不需要任何测试账号】。**

**二级那条臂(金额 ≥ SGD 1,000)——★ 它落在 Tim 自己身上:**
`cfo` 的唯一真持有人是 `admin@swm-os.test`。
☞ 可以走(admin 持 `module.purchasing.view` + `data.view_prices`),
**但「提单人 ≠ 批准人」这件事在二级上只能由 Tim 自己扮演对手方** ——
提单的人必须是别人(vince 或 chooer),批的是 Tim。

⚠ **一件要照直说的:`finance` 自己持 `module.purchasing.edit`** —— 也就是说
chooer **既提得了单、又是一级审批人**。四眼在**单张单据**上仍然成立(`created_by ≠ auth.uid()`),
但「结构上提不了单的审批人」在一级上是 **0 个**。
☞ 这**不是本刀的发现**:`approvals_readiness` 专门返回 `level1_holders_who_cannot_raise`
来报告它,而且**报告不拦**(理由写在 `db/functions/approvals_readiness.sql:15-20`)。

### 4.3 一次性测试账号能证什么、不能证什么

★ **本刀判断:这条流【不需要】一次性账号,现有账号覆盖得了两条臂。**
若将来要用(例如造一个**不持 `module.purchasing.edit`** 的纯审批人来证那条结构分离):

* ★ **能证**:权限判据本身 —— 谁批得了、谁批不了、`require_approver_for` 拒不拒。
* ★ **不能证**:①「这个人真的登录得了」—— `real_role_holders` 的四条判据里
  ②③④ 说的是**真实账号状态**,而一个造出来的账号是照着判据造的,**它必然通过**;
  ② 屏幕上那一半(`data.view_prices` 的遮蔽在页面上长什么样)。
* ⚠ **两条硬约束,来自既有记录:** 自动模式下 `DO $$` 块里 **INSERT `user_roles` 是被拦的**
  (改用现有员工的 `sub` 模拟会话);以及 **`probe-*.mjs` 红着退出会把临时授权留在线上**
  (`npm run reap:ephemeral`,并复查 `user_roles`)。

### 4.4 ★ Tim 自己要动手的那几件

1. ★ **`vince@evoltrya.test` 与 `chooer@evoltrya.test` 的登录凭据** —— 两个人都要真的登进去。
   本机够不到那两个密码,这一步**不是工程决定**。
2. ★ **二级那条臂由 Tim 用 `admin@swm-os.test` 亲自批**(`cfo` 只有他一个真持有人)。
3. ★ **翻那个开关的人是 Tim,从屏幕上,APR-1 之后** —— 这是他 2026-09-22 的裁定。

---

## §5 · 每一个需要 Tim 的问题,连同他的答复

### 5.1 闸轮八问(2026-09-22 已答,照录)

| # | 问题 | 本刀的建议 | ★ Tim 的答复 |
|--:|---|---|---|
| **Q1** | 审批现在就能开了。现在开,还是等扩展建完? | 先别开,但**这一刀就把过期的文档改掉** | ★ **不开。** 等开关、写路径、痕迹三样都有了,由 Tim **从屏幕上一次性打开**。§3 原地划掉并留下收据 —— ✔ 本刀已做 |
| **Q2** | 哪个码管**写**这个开关? | (a) 一支查 `action.manage_permissions` 的 `SECURITY DEFINER` RPC | ★ **(a),外加一道守卫**:`finance_settings` 上,审批策略那四列凡不经该 RPC 的改动**一律按名拒绝**;**守卫不许碰其余各列**(`setPeriodLock` 照常工作);**拒绝要有名字** |
| **Q3** | `cco` 也持 `action.manage_permissions`,撤还是认? | 认下来并写进文档,不在这一刀撤 | ★ **接受 `cco` 为 admin 等价,写进 `docs/approvals.md`。本次不撤** —— ✔ 本刀已做 |
| **Q4** | 没有金额的单据,「审批」是什么意思? | 照 `release_work_order` 的先例,**恒定一级** | ★ **恒定一级,不发明条件语言** |
| **Q5** | 「每一种流转单据」到底是哪些? | (本刀原建议:先补四个已备好的 + 报销单) | ★ **Tim 重写:不限于已接线的。** 采购 / 销售 / 物流 / 生产 / 人事 / 财务 六族,逐项见 §3.1。**路由沿用现行规则。缺的东西在实际使用中发现再加** |
| **Q6** | 自批只有两条链拒,统一吗? | 统一 | ★ **统一拒,复用 `SELF_APPROVAL_FORBIDDEN`**,含 `decide_leave_request` · `decide_medical_claim` · `release_work_order`,**以及 APR-2 新加的每一条链** |
| **Q7** | 翻开关要留痕吗?现成的接得住吗? | 要;接不住;新建一张 | ★ **新建 `finance_settings_history`,只增不改,由同一支 RPC 写**,照 `pricing_formula_history` 的形状 |
| **Q8** | 一刀还是两刀? | 两刀,理由是迁移面不相交 | ★ **两阶段。** APR-1 = RPC + Q2 守卫 + `finance_settings_history` + `/settings/approvals` 的写路径 + `work_order` 的 RLS 修复。APR-2 起 = Q5 扩展 + Q6 统一拒绝 |

★ **Tim 要求记下的一句:APR-1 让 Tim 得以【先把审批打开、用手走一遍采购单】,
而此时其余单据类型都还没有进场。**

### 5.2 ★★ 本刀新发现的、仍然需要 Tim 的问题

**这些在闸轮时还不存在 —— 它们是 Q5 被重写、扩到那六族之后才冒出来的。本刀【不替他答】。**

---

❓ **N1 —— 表头没有合计的那四种单据,怎么按金额路由?**
`sales_orders` · `quotes` · `credit_notes` · `journal_entries` **表头上没有本位币合计**
(前三者只有 `currency` + `fx_rate`,`journal_entries` 一个金额列都没有)。
Q4 管的是「没有金额」,这四种**有钱但表头没有那个数**,两条规则都不适用(§3.3)。

➡️ **建议:(b) 给需要按金额路由的那几张表加一列维护出来的本位币合计**,与
`purchase_orders.estimated_total_ccy` 同形。
**理由不是整洁,是 `void_approval_on_amount_increase`:** 「改价抬过档就作废重路由」
今天靠的是**表头那一列的 OLD/NEW**;走 (a) 现算,明细级的改动这条触发器**看不见**,
于是一张已批的单可以被改到更高一档而没有任何东西作废它 —— ★ **那正是这台引擎已经
专门建过一次机制去防的事。** 代价照直说:**这是 schema 改动 + 维护触发器,不是接线**,
所以它应当**单独成刀**,而不是塞进某一族里。

---

❓ **N2 —— 「装柜」与「发运」:没有对应的动作。发明,还是从清单上拿掉?**
★ **装柜**:树里没有 `load_container()`;`containers` **没有状态列**;装柜是
`container_milestones` 里一行 `milestone = 'loaded'` —— **一条里程碑事实,不是一个决定**。
★ **发运**:`shipments` **整张表没有状态列**(`id/code/sales_order_id/ship_date/notes/container_id`),
`ship_order` 记录的是**已经发生的事**。

➡️ **建议:两项都从 APR-2 拿掉,登记成待裁,而不是在 APR-2 里发明一个状态机。**
理由:给它们加审批意味着**先给它们一个流转态**(draft → 待放行 → 已放行),
而那是在改变这两件事**是什么**,不是在给它们加一道闸。
☞ **如果 Tim 要的其实是「货出门之前要有人点头」,那更可能落在【销售订单】那一侧
(发货前的放行),而不是在 `shipments` 这张事后记录表上** —— 但这是一次业务判断,
本刀不替他做。

---

❓ **N3 —— 采购单变更:独立审批,还是沿用现有的「抬档才作废」?**
今天 `void_approval_on_amount_increase` 已经管着一半:**金额改到更高一档 → 原审批作废、
重新路由;同档内变动或降档 → 原审批仍然成立**(理由写在那支函数里:已批过二级的单
降到一级再批一次是空转)。而 Q5 把「采购单变更」单列为一项。

➡️ **建议:沿用现有机制,不给变更加第二套审批。**
否则同一件事会有两套机制管,而它们**会在「降档」那一格上打架**(现有机制说不必重批,
新机制说每次变更都要批)。★ **若 Tim 要的是「任何变更都要有人点头」,那应当是
【替换】那条触发器的规则,不是【叠加】** —— 而替换要连同它现在挡住的那个场景一起裁。

---

❓ **N4 —— 薪资按哪个数分档?加工单成本不全时怎么办?**
`payroll_periods` 有 `gross_total` / `net_pay_total` / `employee_cpf_total` 等多个合计,
**按哪个比 1000 是一个业务决定**(而且以薪资的量级,两者都会永远落在二级)。
`processing_runs` 的 `total_cost_base` **可能不完整**(上游未计价时标 `cost_incomplete`),
于是提交那一刻那个数可能还不成立。

➡️ **建议:薪资用 `gross_total`**(它是「这个期间承诺付出多少」最直接的口径,
而 net 受扣项影响、会让同样的用工成本落进不同档)。
**加工单:成本不完整时【按名拒绝提交审批】,而不是拿一个不完整的数去分档** ——
与 `approval_level_for` 在阈值未设时 RAISE 是同一条理由:**猜一个级别等于把审批变成装饰。**

---

❓ **N5 —— `journal_entries` 有 82 行,是全场最多的一张,而总账是所有报表的底座。它真的要进 APR-2 吗?**
它同时中了三条:**没有表头金额**(N1)、**行数最多**、**爆炸半径最大**
(`balance_sheet` / `pnl_statement` / `account_ledger` / `cash_flow_statement` 全都读它)。
而 `post_journal_entry` 已经带着 `YEAR_CLOSED` 与期间锁两道闸。

➡️ **建议:要,但【排在最后一刀,单独一刀】,并且先回答 N1。**
理由:一旦开启,**每一张手工凭证都要等人批**,而手工凭证正是月结、汇兑重估、
年结冲销那些**由别的机制自动产生**的东西的载体 —— ★ **必须先分清「人手敲的凭证」
与「系统过的凭证」,否则审批会卡住月结本身。** 本刀没有量那两者的比例,
照直记成 **NOT MEASURED**。

---

❓ **N6 —— 页面闸(`action.manage_permissions`)与 RPC 闸(`module.finance.view`)不一致,顺手对齐吗?**
`/settings/approvals` 的闸是前者,而它调的 `approvals_readiness()` 内部要求后者(§2.1)。
今天 `admin` 与 `cco` 两个码都持有,所以看不出问题。

➡️ **建议:在 APR-1 里把 `approvals_readiness()` 的内检改成 `action.manage_permissions`。**
它今天只有这一个调用方(那一页),而**两个码守同一块屏幕**正是本仓库
「屏幕与闸读同一份判据」反复付账的形状 —— 而这支函数的抬头**自己就写着那句话**。

---

## §6 · 刀形与估价

### 6.1 APR-1(Tim 已定的范围)

**内容:** ① `set_approvals_policy(...)` RPC · ② Q2 的列作用域守卫 ·
③ `finance_settings_history` · ④ `/settings/approvals` 的写路径 ·
⑤ `work_order` 的 `approval_log` RLS 修复 · ⑥ 文档(§3 划掉 + cco + 两条已知问题)——
⑥ 本刀已做。

**★ 两个数,照 `AGENTS.md`「写下来的成本必须是量过的成本」给出,并标明出处:**

| 流程底价(process floor) | 用时 | 出处 |
|---|--:|---|
| 闸轮往返(APR-1 自己那一轮) | ~20 min | 本刀 APR-0 闸轮的实际长度 |
| `db/gate.py --offline`(迁移前相) | ~1 min | **实测 44s**(AGENTS.md,2026-09-05) |
| 备份并等它自报 `BACKUP_EXIT=0` | ~15 min | **实测 8 min 与 34 min 两次**,取中;**不是一个可规划的数** |
| `apply_migration.sh` | ~1 min | — |
| ★ `db/gate.py` 整门 | ~8 min | **实测 310s**(2026-09-05,193 fixtures);**区间 183–650s,肥尾** |
| `npm run build` | ~1 min | **实测 22s**(19 条静态检查 + `next build`) |
| ★ `smoke-routes.mjs`(改了渲染层,必须跑) | ~13 min | **实测 765s**(2026-09-05,218 条路由) |
| 线上手工走证(Tim 登两个号走一遍) | ~15 min | 估,**不是实测** |
| **小计** | ★ **~74 min ≈ 1.25 h** | |

| 实作(measured work) | 用时 |
|---|--:|
| `set_approvals_policy` RPC(四列 + 权限检查 + 写 history) | ~30 min |
| Q2 守卫(**列作用域**:只拦那四列,其余放行)+ 故障注入 | ~30 min |
| `finance_settings_history` 表 + 只增不改守卫 + 镜像 | ~30 min |
| `/settings/approvals` 写路径(表单 + server action + en/zh 文案) | ~60 min |
| `work_order` 的 RLS 那一支 + 镜像 | ~15 min |
| Fixtures(RPC 走得通 · 守卫按名拒 · 直连写被拦 · history 落行 · work_order 读得出) | ~60 min |
| 镜像 + `types:gen` + 文档 | ~30 min |
| **小计** | ★ **~4.25 h** |

> ### ★ **APR-1 合计 ≈ 5.5 小时**(1.25 + 4.25)
> ⚠ **两个数都带着它们的不确定:** 备份 8–34 min、整门 183–650s。
> **坏的那一头会把流程底价推到 ~2 h,合计 ~6.25 h。**

### 6.2 APR-2 起:怎么切,每一刀一个点名的理由

★ **不做成一刀。** 理由不是"太大",是**三条边界各自是真的**:

| 刀 | 内容 | ★ 分刀的理由(点名) | 流程底价 | 实作 | 合计 |
|---|---|---|--:|--:|--:|
| **APR-2** | ★ **Q6 统一自批拒绝**(5 条既有链)+ **把三条 HR 链接上引擎**(请假 · 医疗 · 绩效) | ★ **它一个 subject_type 都不加** —— 四格里只动 ③,不动 ①②④。**于是它是唯一一刀可以【零枚举改动】验证 Q6**,而 Q6 是一条横跨所有链的规则:**先单独证它,再让后面每一刀继承它** | ~1.25 h | ~3 h | **~4.25 h** |
| **APR-3** | ★ **四个已备好的 subject_type 接上**(`payment` · `expense` · `pricing_formula` · `stocktake`)+ **报销单**(新枚举) | ★ **前四个的 ①②④ 已经就位**(枚举有、`CASE` 分支有、RLS 那一支有),**只差 ③**;报销单是**唯一**一个审批形状却漏在枚举外的单据。**把「几乎不用动结构」与「只差一个枚举」放在一起,这一刀可以【逐格演示那四格】而不被别的复杂度干扰** | ~1.25 h | ~4 h | **~5.25 h** |
| **APR-4** | 采购收货 · 发票 · 货运单据 · 固定资产处置 · 加工单提交 | ★ **这五项【表头都有可用的金额,或者明确没有金额】** —— 也就是说它们**不碰 N1**。一刀之内路由规则不需要任何新裁定 | ~1.5 h | ~5 h | **~6.5 h** |
| **APR-5** | 销售订单 · 报价 · 贷项通知单 · 销售订单变更 | ★ **这四项【全部卡在 N1 上】** —— 表头没有合计。**这一刀的主体其实是那次 schema 改动 + 维护触发器**,不是接线。**必须等 N1 有答案才能开** | ~1.5 h | ★ **NOT ESTIMATED —— 取决于 N1 怎么裁** | — |
| **APR-6** | 记账凭证 | ★ **N5**:行数最多、爆炸半径最大、而且要先分清「人敲的」与「系统过的」凭证。**单独一刀,排最后** | ~1.5 h | ★ **NOT ESTIMATED —— 取决于 N5 与 N1** | — |
| — | 薪资 · 采购单变更 | ★ **悬在 N3 / N4 上,未排刀** | — | — | — |

> ### ★ 照直说三件事
> ① **APR-5 与 APR-6 【没有估价】** —— 它们的主体是两个 Tim 还没裁的问题(N1 / N5),
>    而一个建在未决之上的估价是一个编出来的数。
> ② **APR-2–APR-4 合计 ≈ 16 小时**,加 APR-1 的 ~5.5,**已裁定部分共 ≈ 21.5 小时**。
> ③ ★ **「装柜」与「发运」不在任何一刀里** —— 它们对不到代码,见 N2。

---

## §7 · 本刀量过、并发现为假的断言

**(`AGENTS.md` 要求这一节存在,空着也要写。本刀不空。)**

1. ★ 「nothing in the UI can turn it on」—— **半假**:页面在,且已是 admin 把关;缺的是写路径。
2. ★★ 「approver resolution 可能走 manager_id」—— **假**:这条引擎里没有 manager 链。
3. ★ 「组织架构基本是空的:一个员工、没有人有上级」—— **假**:7 人在册、5 人有上级、6 人有账号。
4. ★★ 「approvals cannot be switched on」—— **假**:`can_enable = true`,两级各 1 个真持有人。
5. ★ 「`action.manage_permissions` 只有 admin 持有」(`docs/approvals.md` §0b)—— **假**:`cco` 也持有。
6. ★ 「`cfo` 持 4 个码,self-check 拒绝任何别的数」(§0 EQP-PAY-1)—— **假**:今天 5 个。
7. ★ 「六个账号里只有一个能登录」(旧记录)—— **假**:六个全部已确认、未封禁、未删除。
8. ★★ 「`docs/approvals.md` §3 的到期条件尚未兑现」—— **假**:已兑现,由另一个账号。

**量过、确认【为真】的(照 DRAFT-6 的先例,复核也要留痕):**

* 策略行 `false · finance · cfo · 1000` —— ✓ 逐字相符(读 `finance_settings` 基表)。
* `approval_log.subject_type` 恰好九个取值 —— ✓ 与 B3 的记录相符。
* 阈值 1000 保持不变 —— ✓ Tim 确认,本刀未动。
* `cfo` 仍不持 `module.purchasing.edit` —— ✓ 结构分离成立。
* `purchase_orders` 待批 = 0 —— ✓ 于是开关两个方向今天都是自由的。
