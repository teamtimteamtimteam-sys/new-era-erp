# CLEANUP-A —— 权限盲区与被吞掉的错误(2026-08-31)

一句话:**一个看不见某样东西的读者,必须被【告知】,不能被交给一个更小的数字、
一个空列表、或者一个恰好长得像合法状态的 `NULL`。**

本文件记:每一项的实测错数字、白名单逐角色的理由、清扫删了什么又刻意留下什么、
以及一个等 Tim 决定的问题。

---

## 〇 · 先纠正委托书 —— 五条前提实测不成立

照这些前提做,会做出错的修复,所以先写在最前面。

| 委托书说 | 线上实测 |
|---|---|
| `attendance_unpaid_days` 3.00 → 0 | **2.00 → 0**(8/10–8/12 跨了一个周末) |
| `sale_settlement_compute` 4 张化验单 → 0 | **今天复现不了。** 它早就有按名拒绝的闸;线上 `contract_document_terms` **零行**,4 张化验单**全在进料侧**,函数在金属循环之前就拒了 |
| `resolve_review_reviewer` 一个 uuid → NULL | 今天**对谁都返回 NULL**,与权限无关 —— 全库一个部门,而且它没有经理 |
| 11 条认不到人的授权 | **21 条**,其中 **13 条是 2026-08-31 当天**造出来的 |
| 解法按【返回类型】分岔,void 才 RAISE | **本刀六个对象里一个 void 都没有**,而其中三个照这条规矩改会把缺陷原样装回去 |

### ★ 被删掉的那条前提:「解法按返回类型分岔」

**返回类型是错的判据。** 正确的判据是:

> **这支函数的 `NULL` 是不是【已经有主】了?**
>
> 「有主」= `NULL` 已经在表达一个**合法状态**,而且**有人在读那个意思**。
> 若是,让"无权限"也返回 `NULL`,就是**把拒绝伪装成一个合法答案** ——
> 它会渲染成那个合法状态,于是**没有任何人、任何时候会看见它**。
> 这与"返回 0"是同一个缺陷,只是换了一件衣服。**这一类必须 RAISE。**

三个「NULL 已经有主」的:

| 对象 | 它的 `NULL` 本来是什么意思 | 谁在读那个意思 |
|---|---|---|
| `inbound_batch_landed_unit_cost` | 「这批货真的没有金额」 | `inbound_batch_valuation.unpriced` **就定义为**它 `IS NULL` |
| `resolve_review_reviewer` | 「解析不出评估人」 | `hr_alerts` 的 `review_no_reviewer` 一支专门等它 |
| `previewLeaveDays`(前端) | 「两头日期还没填全」 | `LeaveForm` 把它印成 `—` |

`db/fixtures/174` 的 **D 臂**把这件事变成可执行的证据:它注入的"旧版本"**不是**
"没有判据",而是**一个照委托书原话写的、返回 NULL 的判据版本** —— 看起来完全像
一次修复。断言说明的正是:**它与"解析不出评估人"在结果上一个字都不差。**

规矩已写进 `AGENTS.md`(「拒绝要用哪个值表示」一节)。

---

## 一 · 六项,每一项的实测错数字与处置

所有数字用**真角色**跑出来(`SET LOCAL ROLE authenticated` + jwt claims),不是推的。

| 对象 | 受限读者从前得到 | 真值 | 现在 | 形状 |
|---|---|---|---|---|
| `bank_book_balance_asof` | **0.00** | −29,753.70 | `NULL` | NULL 没有主 → NULL |
| `bank_reconciliation_status` | **两行假零** | −29,753.70 | 按名拒绝 | 视图 → 壳 + DEFINER 取数体 |
| `attendance_unpaid_days` | **0**(= 多发工资) | 2.00 | `NULL` | NULL 没有主 → NULL |
| `resolve_review_reviewer` | `NULL` | 上级部门经理 | 按名拒绝 | **NULL 已经有主 → RAISE** |
| `inbound_batch_landed_unit_cost` | 靠"没授权"活着 | — | 按名拒绝 | **NULL 已经有主 → RAISE** |
| `sale_settlement_compute` | (今天到不了) | — | 第二道按名闸 | 闸与身体读的不是同一条权限 |

### ★ 最坏的一处:`bank_reconciliation_status`

它比 R1 描述的形状还坏。R1 说的是"更小的数字"或"空列表" —— 这张视图**两样都不是**:
账户码 `'1000'`/`'1010'` 是 `VALUES` 里硬写的,所以**行不会消失**,只有钱变成 `0.00`。
**一个空列表还看得出"我什么都没拿到";两行假零看起来就是答案本身。**

而且它会**把函数那一侧的修复原样吃掉**:旧视图写着 `COALESCE(led.balance, 0::numeric)`,
而修好的 `bank_book_balance_asof` 现在返回 `NULL` —— 那个 `COALESCE` 把它**变回 0.00**。
**两处分开看都"修好了",合起来仍然说谎。** 所以 `db/fixtures/174` 的 **B 臂**注入的是
【旧视图】而函数保持修好的样子,专门钉住这一对。

### `attendance_period_status` —— 一处顺带查出来的、更坏的漏

修 `attendance_unpaid_days` 时发现它的算术调用方 `attendance_period_status`:

* 它写着 `round(COALESCE(sum(… attendance_unpaid_days(…) …), 0), 2)`,而 **`sum()` 会跳过
  `NULL`**。所以让函数返回 `NULL` 之后,这里不会报错、也不会变 `NULL` ——
  它会把那些员工**整个从月合计里抽走**,报表只是"小一点"。**这正是 R2 点名的
  PROC-COST-2 形状(750.00 → 0.00)。**
* 而它**本来就在漏一件更坏的事**:它是 `security_invoker = off`(以属主身份读、
  RLS 不生效)且 `GRANT` 给 `authenticated`。**实测:任何一个登录用户,不管有没有
  `module.hr.view`,都读得到全公司的考勤与无薪假。** 视图注释把把关记在"调用方"头上 ——
  那是"调用方不是控制"。

处置:同一个壳 + DEFINER 取数体(`attendance_period_status_rows`,判据 `module.hr.view`)。
`invoker = off` 保留 —— 它当初是对的(OPS-14 修法 (a)),错的是**没有人在这一层问权限**。

### 不在委托书六项里、但一起做了的

`bank_reconciliation_record`:`bank_reconciliation_status` 的同胞,同样消费
`bank_book_balance_asof` 并拿它做减法,而无权限读者从前拿到的是**空列表** ——
R1 明写着 NEVER AN EMPTY LIST。修一张留一张就是同一个"合起来仍然说谎"的形状。

---

## 一之二 · 主迁移做错了一件事,而 gate 当场抓住了它(fu1 / fu2)

**记在这里,因为它比本刀修的任何一处都更值得下一个人读到。**

主迁移给 `inbound_batch_landed_unit_cost` 加了 R3 要的判据。那件事本身是对的,
**放错了地方** —— 那支函数**同时**是两样东西:

* 一个**读者会读的价格**(要问权限),和
* 一个**过账时用来算钱的原语**(**不许**问权限)。

给后者加上"读者是谁"的判据,等于让**账上的金额取决于按按钮的人有什么权限**。

**怎么发现的:** `db/gate.py` 退 **4**,`db/fixtures/172` 当场红 ——
`LANDED_COST_PERMISSION_DENIED|data.view_prices`。172 的"受限读者"持
`module.inventory.view` + `module.inbound.view` + `module.finance.view` 而没有
`data.view_prices`:一个**完全合法**的部分权限读者。而
`inventory_valuation_snapshot` 本来就**已经**对他做对了事
(`prices_visible=false`、`restriction` 具名、金额 `NULL`、数量照常)。
**主迁移把一条本来就正确的路打断了。**

**而 gate 还没走到的那一处更坏:**`emit_batch_writeoff_movement` 这个**触发器**,
它的抬头**自己写着**这句话:

> 「读的是不带判据的那一支 —— 计值不许取决于谁按的按钮;一个只有 `inbound.edit`
> 的仓管按下注销时,带判据的读取器会返回 `NULL`,`COALESCE` 成 0 就等于本缺陷静默复发。」

主迁移把那句话作废了:那个仓管按下注销会**直接撞一条权限拒绝** ——
比返回 `NULL` 更响,但一样是错的,**注销这个业务动作本身失败了**。

### 修法用的是这个仓库【已经有】的形状

`PROC-COST-1 fu2` 早就为同一个问题立过模式:`batch_freight_base`(带判据)
←→ `batch_freight_base_all`(无判据)。而 `inbound_batch_landed_unit_cost` 的函数体里
**本来就写着**「读的是 `_all` 那一对」—— 它**一直站在这个分裂的"过账"那一侧**,
只是自己没有名字说明这件事。`db/check_mirrors.py` 的豁免名单里那段
「算术与受众分成两层」的注释,写的就是这条分界线。

* **`inbound_batch_landed_unit_cost_all`** —— 无判据的**过账**原语。四个机器调用方:
  注销触发器、`post_stocktake`、`inventory_control_reconciliation`、
  `inventory_valuation_snapshot`。不授给 `authenticated`。
* **`inbound_batch_landed_unit_cost`** —— 带判据的**读者**名,判据不变,
  算术**委托**给 `_all`(不复制:两份实现会悄悄分开)。
  **R3 仍然成立** —— `db/fixtures/174` 的 E 臂**刻意以一个拿得到 EXECUTE 的调用者身份**
  去问它,证明它自己拦得住。

> ### ★ 判据不在权限清单上,在【问题】上 ★
> **给人看一个价格 → 要问权限;算一笔要过账的钱 → 不许问权限。**
> 这就是 `_all` 这个后缀在本仓库里的全部含义。
>
> **为什么不是"把白名单再放宽一点"**:那条路要一直加到
> `data.view_prices OR stocktakes.edit OR finance.view OR inbound.edit` 才够,
> 而最后一条是**写权限** —— 用"你能改进料批"论证"你能看价格",不成话。
> 到那时它拦不住任何人,就是 R2 的另一半:**太宽的检查是戏**。

### fu2:一行代码改了,它旁边那句话没改

fu1 把触发器里的调用改成 `_all`,而紧挨着的注释仍然写着「经
`inbound_batch_landed_unit_cost`」—— 线上那支函数里于是留着一句**说的和做的不一样**的话。
gate 的【镜像 vs 线上】判词因为这一句而红,**那不是判词过严,是它按设计工作**:
它比对 `pg_get_functiondef` 的原样字节,注释也在其中,而线上与仓库对同一支函数的
说法必须一致。所以它值一支**只改注释**的迁移。

### 顺带记一条,免得下次再踩

`db/views/zzz_function_grants.sql` 会 `GRANT EXECUTE ON ALL FUNCTIONS ... TO authenticated`,
而 `apply_migration.sh` 在迁移之后**重跑它**。所以迁移里那句
`REVOKE ... FROM authenticated` 会被**随后那次 GRANT 抵消** ——
新函数的收权**必须写进 `zzz_function_grants.sql` 本身**,写在迁移里是不够的。
实测:fu1 应用后线上 `_all` 仍可执行(gate 的 B2 在**线上**红、在**重建**绿,
一红一绿正好指出这件事),补进那个文件并重跑一次才真的收掉。

---

## 二 · 白名单,逐角色

R2:**两个方向都是失败。太窄,一个 `NULL` 毒掉算术调用方;太宽,检查是戏。**
所以每一条都要有理由,而"会不会打断合法的路"是**量出来的**。

### `inbound_batch_landed_unit_cost` → `data.view_prices OR module.stocktakes.edit`

| 权限 | 为什么在里面 |
|---|---|
| `data.view_prices` | 落地单位成本**就是一个价格**。主判据。 |
| `module.stocktakes.edit` | `post_stocktake` 与注销触发器要拿它**算过账的钱**。**实测:持 `stocktakes.edit` 的四个角色里,`operations` 与 `warehouse` 都没有 `data.view_prices`** —— 只写第一条,盘点与注销当场对这两个角色坏掉,而它们正是真的在做盘点的人。 |
| ~~`module.inventory.view`~~ | **刻意不加。** 加了它,价格遮蔽等于没有:一个只有 `inventory.view` 的读者会拿到原始价格。遮蔽住在 `inbound_batch_valuation_rows` 里是对的。 |

**代价与补偿:**这支函数现在会拒绝只有 `inventory.view` 的读者,而
`inbound_batch_valuation.unpriced` 一列**本来就该给这种读者看**
(INV-VAL-1:「有没有价是事实,不是价」)。从前那句话成立靠的是"这支函数恰好不拒绝任何人";
现在它拒绝了,于是那句话需要自己的入口 —— 新增
**`inbound_batch_has_landed_cost(uuid) → boolean`**(判据 `module.inventory.view`,
不透出任何金额)。**它把那句话从偶然变成可执行的。**

### `bank_book_balance_asof` → `module.finance.view`

与 `journal_lines` / `journal_entries` 的 RLS 策略**逐字相同**。判据与策略一致,
所以本支**保持 `SECURITY INVOKER`** —— 不需要属主权限去读任何合法读者读不到的东西。
(PROC-COST-1 fu2 那一族用 DEFINER,是因为它们的判据**比 RLS 宽**。形状不同,不要照抄。)
**不加 `module.finance.edit`**:没有任何角色持 edit 而不持 view(查过),加上它只会让
白名单看起来更周全,而不改变任何一个人的可见性 —— 那是"太宽的检查是戏"。

### `attendance_unpaid_days` → `module.hr.view` **OR 本人**

`OR p_employee_id = current_user_employee()` **不是客气,是量出来的**:
`leave_requests` 有一条 `select own rows` 策略,**实测一个零权限的员工今天正确地
读到自己的 2.00 天**。只写 `module.hr.view` 会把这条合法的路**新打断** ——
R2 的反方向失败。`db/fixtures/174` 的 **C-inj-2** 就是注入那个"太窄"的白名单,
并断言它**看得见地**打断本人;没有这一注入,"本人读得到"那条断言可能整条是空转。

而 `C4` 断言**本人读【别人】仍然是 `NULL`** —— `OR` 那一支**有范围,不是一个口子**。

### `resolve_review_reviewer` → `module.hr.view`

`departments` 的 SELECT 策略就是它(三级解析必须读 `departments`)。
**本人读自己拿到的是【按名拒绝】,不是 `NULL`** —— 从前他拿到 `NULL`,那是一个
**错误答案**;现在拿到一句**说明**。R1 要的正是这个方向,**这不是丢了一个功能**。

### `sale_settlement_compute` → 加 `module.output.view` 作为第二道按名闸

第一道闸问 `module.customers.view`,而函数体接下来读的
`output_batches` / `assay_results` / `assay_result_metals` 三张,RLS 问的都是
`module.output.view`。**闸问的和身体读的不是同一条权限。**

**它今天拦不到任何人** —— 持 `customers.view` 的五个角色
(`admin`/`auditor`/`finance`/`gm`/`sales`)**全部**也持 `output.view`。
**加它的理由不是"线上现在错着",是"角色改一次就会无声地重新打开它"**,
而重新打开的那一天没有任何东西会响。fixture 会构造一个只有 `customers.view` 的读者
钉住它 —— **那不是线上缺陷的证据**。

### 一条查过、没有假设的事

**每一个持 `*.edit` 的角色是否也持对应的 `*.view`** —— 查过:
`module.hr.edit` 的三个持有者(`admin`/`gm`/`hr`)全都持 `module.hr.view`。
所以 `open_review_cycle` / `open_probation_review` / `complete_attendance_period`
这三个 DEFINER 调用方,**一个都不会被新判据拦住**。这是必须查、不能假设的东西。

---

## 三 · 两处被吞掉的错误

### `previewLeaveDays`

从前 `if (error) return null`。**而 `null` 已经有主**:`LeaveForm` 的 effect 开头就写着
`if (!start || !end || end < start) { setDays(null); return }`,屏幕上渲染成 `—`。
于是**一次 RPC 失败渲染成"你还没填完"** —— 而他明明填好了。

现在返回 `{ days: number } | { error: string }`,失败在屏幕上有自己的红字。

### `AssayForm` 的计价预览 —— 比委托书描述的**更坏一层**

委托书说"拒绝只是把转圈关掉"。实测比这更坏:`previewAssayPrice` **自己已经**把 RPC 的
拒绝变成 `{ error }` 并画得出红横幅;掉进那个 `.catch` 的是**抛出来**的一支。
而它只 `setPreviewing(false)`,于是 **`preview` 保持上一次的值** ——
如果上一次成功,屏幕上继续摆着一个**过期的价格**,而
`applyBlocked = !!preview.error` 仍然是 `false`,**「记录并应用」照样是主按钮**。
操作员可能按着一个悄悄没刷新的试算把化验应用下去。

所以修法是**两半**:① 说出来;② **把过期的结果一起清掉**。
只挂横幅而把那个数字留在屏幕上,危险的东西还在原地。

### 在册清单是**被做完清空的**,不是被改小的

`scripts/check-error-swallowing.mjs` 的 `QUEUED` 从 **2 条 → 0 条**,
两条的"去处"原本都写着「cleanup A」。**没有为它们加任何 `ALLOWLIST` 条目** ——
加一条豁免等于让下一个读的人以为有人核过了,而事实是它们被修好了。
两处的 `.catch` 现在都**带参数并且真的用了它**(`console.error` + 面向用户的文案),
所以本检查按它自己写明的规矩不再判它们:「空手接住」才是它要抓的东西。
`?? 空值` 的 8 条 allowlist **一条没动**。

---

## 四 · 21 条幽灵授权 —— 这是**第三次**清扫,所以重点是【为什么会回来】

### 清单与处置

* **删掉 21 条**(`user_roles` 29 行 → 8 行),全部指向**真的 `admin` 角色**、
  `granted_by` 为空、`user_id` 在 `auth.users` 里不存在。
  8 条造于 2026-08-26 01:24–02:06,13 条造于 **2026-08-31 当天** 00:20–19:43。
* **判据是「`auth` 行不存在」,不是「这个人登不进来」。两者是完全不同的事实。**
  * **Choo Er Teh(`chef1949@126.com`,EMP-2026-0001,持 `finance`)一个字没动** ——
    她的 `auth` 行**在**,只是邮箱从未验证。**登不进来 ≠ 认不到人。**
    按这条判据,她**不可能**被点名。
  * 5 条已置 `revoked_at` 的走查账号(2026-08-24)**也没动** ——
    `revoked_at` 是这套 schema 自己的"撤销",它留下了"授权存在过、又被撤了"这件事。
* **为什么是 DELETE 而不是 `revoked_at`**:同 ACCOUNTS-CLEAN。`revoked_at` 记的是
  "有人撤销了某个人的权限",而这些行背后**没有人**;给一个不存在的人记一笔撤销史,
  是在记一件没发生过的事(FIN-26)。

清扫后 `user_roles` 8 行:Tim(`admin`)、Tim(`cfo`)、Choo Er Teh(`finance`),
以及 5 条已撤销的走查账号 —— **全部解析得到人**。

### 诊断:它们为什么会回来

ACCOUNTS-CLEAN 在 2026-08-24 删掉 **66** 条,一周后又长回 **21** 条。查出来的因果链:

1. **`scripts/smoke-routes.mjs:1295` 每一次冒烟都把【真的 `admin` 角色】授给一个
   一次性账号**,`granted_by` 为空 —— 与 21 条的形状**逐项吻合**。
2. **`user_roles.user_id` 【没有】指向 `auth.users` 的外键**(而 `employees.user_id`
   **有** —— 本刀撞到过 `employees_user_id_fkey`)。**所以数据库不会替我们把"账号"和
   "它的权限"绑在一起**:删掉账号,权限原地留下。
3. **每一处拆开这两半的代码,都把它写成两次【各自可失败】的 HTTP 调用,
   而删权限那一半用的是不看返回码的 `rest()`**(`1052` / `1927` / `1941`),
   删账号那一半却用 `restOk()`。**于是"权限没删掉"可以静默失败,"账号删掉了"却一定成功。**
4. **结果对每一支检查都是隐形的**:冒烟的 `sweepScratch` 是【列出账号再清理】,
   账号一没,那行授权**此后永远**不在它视野里;`check-scratch-rows.mjs` 从前只认
   `roles` 的 `fixture-%` / `probe-%`,而这些指向真 `admin`。

**证据(不是推论):**21 个 uuid 里有一个出现在
`finance_settings.updated_by`(2026-08-30 19:05,授权时间是 08-26 01:59)——
**那是一次只有登录用户做得到的应用内写入**,而且它在授权之后**活了四天**。
所以这些 uuid **确实曾是真的、登录过的账号**,后来被删掉、权限留下。

**一条要收回的推论:**本刀早前曾用「`auth.audit_log_entries` 在那两个时间窗里是空的」
来论证"它们从来不是 auth 用户"。**那条推理是错的** —— 那张表**从头到尾一行都没有**
(全时段 0 行),所以它对这个问题**不提供任何证据**,两个方向都不支持。

### 做了什么让它不再无声

* **`restCleanup()`**(`scripts/smoke-routes.mjs`):清理失败**照常往下清**
  (在 `finally` 里抛出去会把后面几步一起吃掉,那是换一个缺陷),
  但**每一次失败都记账、都印出来、并且让冒烟变红**。
  **一条没删掉的 admin 授权是一次失败,不是一条日志。**
* **`check-scratch-rows.mjs` 扩到 `user_roles`**:报告 `user_id` 不在 `auth.users` 里
  且未撤销的授权。**已做故障注入验证**:插一条 3 小时前的幽灵 `admin` 授权,
  它按名报出来;删掉之后回到干净。分页取满 1000 时**跳过判断而不是下结论** ——
  "没在这一页里"不等于"不存在",而这个方向错了会诱人去删一条真的授权。
* **为什么不加外键了事**:`db/fixtures` 里约二十支用 `gen_random_uuid()` 造
  `user_roles` 行,一条指向 `auth.users` 的外键会**当场把它们全部打死**
  (`db/fixtures/README.md` 的「权限」一节早就把这条依赖写下来了)。
  **结构上绑定这条路是关着的**,所以检测 + 让那三处调用不再静默,才是可走的路。

> ⚠ **这是第三次清扫(66 → 8 → 13)。** 上面两条机制是**第一次**有东西会在它复发时
> 出声。如果下一轮仍然长出幽灵授权,**问题不在清扫,在别处**,而这一段就是从哪里接着查。

---

## 五 · 等 Tim 决定:`cfo` 拿到 `module.finance.view` 会新看见什么

**没有授予任何东西。** 这一节只报告。

`cfo` 今天只持 **2 条**权限:`data.view_prices`、`module.purchasing.view`。

授予 `module.finance.view` 会新开:

* **58 张表**的 SELECT —— 含 `journal_entries` / `journal_lines`(166 行)、
  `invoices`(9)、`payments`(13)、`bank_statements`(2)、`sales_records`(9)、
  `fixed_assets`(2)、`fx_rates`、`gst_periods`/`gst_return_boxes`、
  `period_closes` / `year_closes`、`payroll_lines`(见下)、`expense_claims`、
  `customer_statements`、`management_packs`、`approval_log` 等;
* **32 支函数** —— 含 `pnl_statement`、`balance_sheet`、`account_ledger`、
  `cash_flow_statement`、`ap_aging_asof` / `ar_aging_asof`、`f5_return` / `f5_box_detail`、
  `management_pack_data`、`preview_close_financial_year`、
  `preview_depreciate_fixed_assets`、`preview_revalue_foreign_balances`、
  `remit_wht`、`price_exposure_report`,以及本刀新建的三支取数体。

**一条要说清楚的例外:`payroll_lines` 【不会】因此打开。**
它的对账策略是 `has_permission('module.finance.view') AND has_permission('data.view_pay')`,
而 **`cfo` 没有 `data.view_pay`** —— `AND` 不成立。所以工资明细仍然看不见。
(它另有 `module.hr.view` 与"本人"两条策略,`cfo` 也都不满足。)

**判断这件事要问的不是"CFO 该不该看财务"**,而是:
**这 58 张表 + 32 支函数,是不是 `cfo` 这个角色应有的全部?** 它是一次**整块**的授予,
没有更细的粒度可选 —— 财务模块在这套系统里就是一条权限。

**等 Tim 一句话。**

---

## 六 · 这一刀没做、也不该被读成做了的事

* **没有给 `inbound_batch_landed_unit_cost` 加任何授权**(R3 明写)。它仍然对
  `authenticated` 不可执行 —— 变的是**它现在自己也拦**。
  `db/fixtures/174` 的 E 臂**刻意以一个拿得到 EXECUTE 的调用者身份**去问它,
  问的正是:**如果它被授权了,它自己拦不拦得住。**
* **`FX-DISPLAY-1` 的那层壳(`inbound_batch_valuation_rows`)没有退休,而且仍然必要。**
  它做的是本支函数做不到的两件事:①`SECURITY DEFINER` 才改变 `current_user`,
  视图的属主权限**替不了函数的 `EXECUTE`**;② 价格遮蔽(`data.view_prices` → `NULL`)
  与 `unpriced` 这条不遮蔽的事实,都住在那一层。**两个机制没有做同一件事。**
* 委托书列的"刻意状态"一个没动:测试残料批次、`ZZ-PROCCOST1-DEMO`/`ZZWIP-OB`、
  `PROCESSING_COSTS_UNALLOCATED` 的 8 条、M3/M4/M5/M7、
  `output_batch_safety_states` 零行、USD 折不了 SGD、10 条 `source='unknown'` 报价、
  审批开关、`company_compliance` 空、`waste_classifications`、tolling、匿名化函数、
  `INV-2026-0009` / `JE-2026-0070`、五条滞留残料、`.next` 的 145 GB。
* CHECK-1 立的 10 条 embeds 与 76 条 messages 货币字面量**基线没有动**。
