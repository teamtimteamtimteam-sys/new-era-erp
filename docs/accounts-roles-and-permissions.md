# 账号、角色与权限 —— 六个人进系统之前的那一刀(C-1,2026-09-04)

> **这份文档的体例:问答在正文里,不只在结论里。**
> CONV-9 丢掉过一轮问答,结果后来的一刀几乎推翻了 Tim 的一条裁定 ——
> 因为文档只记了"决定是什么",记不出"这是 Tim 定的"还是"那一刀自己定的"。
> 所以下面每一条都写成【问 → 我的建议与证据 → Tim 的裁定】三段。

---

## 〇 · 这一刀之前的状态,以及委托书里被实测推翻的四条

C-1 的委托书写着"建两张新屏幕"。**实测:两张都已经存在。**

| 委托书这样说 | 实测 |
|---|---|
| 建账号、建角色两张都是**新页面** | 两张都**已经存在**且能用(`app/settings/roles/new/` · `app/settings/accounts/InvitePanel.tsx`) |
| 新页面 import 那三个组件,**闸会立刻红** | 闸只在我们**选择遵守规矩 (a)** 时才红 —— 老页面用的是裸 `<input>` |
| 把三个组件从 `GUARDED` 里拿掉即可 | **不够**:还要删掉 `KNOWN_CONVERSIONS` 里两行,否则 EXIT 1(实测) |
| 设置有**七**张子页 | `/settings` 下确实七张,但**还有第八张** `/finance/settings`,而它是最危险的一张 |

★ **真正的工作因此变了形状**:账号那张屏走的是 `inviteUserByEmail`(邮件邀请),
而本系统**没有邮件服务、本刀也不建**。所以 Step 2 是一次**改造**,不是一次新建。

### 汇报线的问题,被测量化解了

委托书问「可见性与审批路由是按角色还是按汇报线」,并把双上级当成一个待解问题。
**实测:这套系统从头到尾按【角色】。**

* `current_user_permissions()` = `user_roles ⋈ roles ⋈ role_permissions`,不含 `manager_id`;
* `require_approver_for()` 读 `finance_settings.approval_level{1,2}_role_code`,再问 `real_role_holders()`;
* 请假决定要 `module.hr.edit`,费用报销决定要 `module.finance.edit` —— 都不问上级;
* **`manager_id` 在全库只出现在一支函数里**:`master_import_apply`(也就是导入这一列本身);
* 线上 `manager_id` 非空的员工:**0 个**。

> **Tim 的裁定:** manager_id 只记**绩效评估**那一条线(Choo Er → Tim,Fu Sheng → Phua),
> 并写明第二条上级在系统里**没有任何含义**。不建双上级模型。

---

## 一 · 角色模型:只新建了一个角色

**不为"每人一个"而造角色。** 六个人里五个落在既有角色上,那些角色本来就是照这些工作对象设计的。

| 人 | 角色 | 新建? | 判据(按工作对象,不按职级) |
|---|---|---|---|
| Vince Goh(CEO) | `gm` | 既有 | 「看得见整个生意,包括成本与利润;但不能改任何人的权限」—— 权限由 Tim 管 |
| Tim Chen(CFO) | **`admin` + `cfo`** | 既有 | 见下面 Q1:**这是一处刻意的双角色** |
| Sandra Yap(CCO 兼 HR 负责人) | **`cco`** | **新建** | 商务 + 人 + 整个设置模块;其余模块只读 |
| Cheng Siong Phua(CTO) | `operations` | 既有 | 「加工、库存与盘点:管数量、产出与回收率,不涉及价格」 |
| Choo Er Teh(企业服务 + 财务) | `finance` | 既有 | 她已经持有它;也正是审批一级的角色 |
| Fu Sheng Wong(仓储 + 物流) | `warehouse` | 既有 | 「现场收货、产出与盘点;不接触任何商务数据」 |
| 将来的现场员工 | `warehouse` | 既有 | 同上 |

### `cco` 到底有哪些权限 —— 逐条列出,不让人从模块授权里倒推

**Tim 点名要求把 `data.*` 的最终集合写出来。** `cco` 持有六条:

| 码 | 它是什么 | 为什么 |
|---|---|---|
| `data.view_prices` | 价格、成本与利润 | CCO 的工作对象 |
| `data.view_sales` | 销售记录 | 同上 |
| `data.view_pay` | 工资、公积金 | HR 负责人 |
| `data.view_identity` | 身份证件与准证号 | HR 负责人 |
| `data.view_reviews` | 绩效评估正文 | HR 负责人 |
| `data.view_deleted` | 被删记录台账 | 矩阵里 `/settings/deleted` 那一格是 R,靠它 |

**刻意不给 `data.view_banking`**(开在发票上的公司银行明细)。

> ★ **`cco` 与 `gm` 不是包含关系,两个方向各宽一点。**
> `cco` 多出 `view_pay` · `view_identity` · `view_deleted`;`gm` 多出 `view_banking`。
> Tim 知情:「Sandra 会看见成本与利润、薪酬、身份信息与价格」—— 那句话里没有银行明细。
> **不要为了"对称"给 gm 加任何东西**(见 Q3)。

---

## 二 · 设置权限矩阵(Tim 裁定的版本)

E = 可编辑 · R = 只读 · — = 进不去

| 子页 | 把门的码 | Vince `gm` | Tim `admin` | Sandra `cco` | Phua `operations` | Choo Er `finance` | Fu Sheng `warehouse` |
|---|---|---|---|---|---|---|---|
| `/settings/accounts` | `action.manage_permissions` | — | **E** | **E** | — | — | — |
| `/settings/roles` | `action.manage_permissions` | — | **E** | **E** | — | — | — |
| `/settings/reference` | `action.manage_permissions` | — | R | R | — | — | — |
| `/settings/approvals` | `action.manage_permissions` | — | R | R | — | — | — |
| `/settings/deleted` | `data.view_deleted` | — | R | R | — | — | — |
| `/settings/dictionaries` | `module.materials.edit` / `module.inbound.edit`(逐节) | E | E | E | E | E | **E ⚠** |
| `/settings/import` | `action.bulk_import` | — | **E** | **E** | — | — | — |

**判据按工作对象:** Vince 读整个生意但不维护系统的管路;Tim 与 Sandra 都做管理;
Phua 管加工,所以物料字典是他的工作词汇;Choo Er 记进料,所以实验室与来源理由是她的;
Fu Sheng 在现场干活。

### ★★ 三件必须写在明处的事(Tim 点名要求记录)★★

1. **`action.manage_permissions` 就是 `/settings/roles` 那扇门** —— 也就是「决定每个角色能做什么」那块屏。
   **Sandra 因此可以给自己授予系统里的任何权限,也可以改动包括 `admin` 在内的任何角色。**
2. **`set_role_permissions` 是【先全删再重插】** —— 那块屏上按一次保存,
   就把那个角色的授权整体改写一遍。**在那里犯的错是静默的、系统级的。**
3. **收窄的办法是把 `action.manage_permissions` 拆成"账号码"与"矩阵码"两个**,
   连同证明 admin 一点都没少,约 1–1.5 小时。
   ★ **Tim 是【刻意推迟】它的,不是忽略了它。**

### ⚠ 一处 Tim 两条裁定之间的真冲突 —— 本刀按更具体的那条执行并报告

* Tim 写:`cco` **VIEW** 的模块清单里点名了 **inbound**;
* Tim 又写:矩阵里 Sandra 在 **dictionaries 是 E**,且「七张子页,无例外」。

**这两条互斥。** 字典那块屏的编辑权**就是** `module.materials.edit` 与 `module.inbound.edit`
(见 `app/settings/dictionaries/registry.ts`),而 Q7 裁定本刀**不铸新码**。
所以给 E 就只能给这两个**模块级**的码 —— 它们顺带给了 Sandra
**编辑物料主数据与进料批次**的能力,而那超出了"设置"。

> **本刀的处置:** 按【矩阵】执行(更具体的那一条),即 `cco` 拿到这两个 `.edit`。
> **这一条需要 Tim 再裁一次。** 收窄的办法有两个,都不需要铸新码:
> ① 把字典那两节的 `permission` 抬到 `module.materials.edit`;
> ② 或者接受 Sandra 在字典那一格是 **R**(Q7 已经证明只读在字典上是**免费**可表达的)。

### ★ 第八张设置页:`/finance/settings`(本刀不动,但必须记下来)

它写 `finance_settings.locked_before`(**期间锁**)与 GST 注册开关。
读门是 `module.finance.view`,**写门是 `module.finance.edit`**(RLS)。

> **Choo Er 拿到 `finance` 角色,因此她能移动期间锁 —— 而那会静默地拒掉整本账上的分录。**
> `guard_finance_settings_sod` 只拦"过账与关账不相容"这一种,不拦其它。
> **Tim 的裁定:本刀不动财务权限,发放之后再裁。**

---

## 三 · 问答全文(问 → 建议与证据 → 裁定)

**Q1 —— 「每人恰好一个角色」与审批二级冲突。**
Tim 线上持 `admin` + `cfo`。丢掉 `cfo` 会让 `cfo` 变成零持有人,
而 `require_approver_for(2)` 问的正是 `real_role_holders('cfo')` —— 一万以上的单子从此没人批得了。
今天审批是关着的(`approvals_enabled=false`),所以不会当场坏,坏在打开审批的那一天。
*我的建议:* Tim 只持 `admin`,并把 `approval_level2_role_code` 改成 `admin`。
> **裁定:Tim = `admin` + `cfo`,两个都留。** 这是对"每人一个角色"的一处**刻意的、有记录的例外**:
> 它把「谁管系统」与「谁批钱」分开。**`approval_level2_role_code` 保持 `cfo`,不要改。**
> Sandra 不是 admin,也不成为审批人。

**Q2 —— `cco` 把价格、销售、薪酬、身份集中在一个授权里。**
*我的建议:* 照建,这是她真实的工作面,但这是六个人里 `admin` 之外最宽的数据授权。
> **裁定:照建,并且比我提议的更宽**(见第一节)。已知悉并接受。

**Q3 —— CEO(`gm`)要不要 `data.view_deleted` / `view_pay` / `view_identity`?**
*我的建议:* 不动 `gm` —— 两处排除都是有记录的刻意决定。
> **裁定:`gm` 一个字不动。** 不要为了消除与 `cco` 的不对称而给它加任何东西。

**Q4 —— CTO 要不要看得见价格?** `operations` 刻意没有 `data.view_prices`。
> **裁定:初期不给。** 加回来便宜,看过了就收不回。

**Q5 —— 没有人映射到 `procurement`,而 `finance` 同时带着 `purchasing.edit` 与 `finance.edit`。**
也就是说 Choo Er 既能下采购单又能付钱 —— `role_permissions.sql` 明说没有角色该同时有这两样。
运行期还有 `guard_payment_sod` / `sod_supplier_creator` 兜着。
> **裁定:确认 Choo Er 下采购单,接受这处例外,依靠运行期守卫,
> 并把它记成一条【已知的、刻意的】角色级不变式违反 —— 等第二个财务的人到岗时再拆。**

**Q6 —— 「企业服务」要不要 HR 可见性?**
> **裁定:不给。** Sandra 是 HR 负责人。

**Q7 —— Step 3 的形状:接受二元访问,还是铸新码?**
账号 / 角色 / 导入三张页的"只读"在不铸码的前提下**表达不出来**(`user_directory` 对没有那个码的人返回零行)。
但**字典的只读是免费的**:registry 已经按 `module.X.edit` 分节,读用 `.view`、写用 `.edit` 即可。
而 reference / approvals / deleted **本来就是只读的**(没有写入控件)。
> **裁定:照此执行。二元 for 账号/角色/导入;字典做真只读;那三张标 R。本刀不铸任何新码。**

**Q8 —— Fu Sheng(`warehouse`)能编辑实验室与来源理由字典。**
> **裁定:收窄,但【不要收回授权】** —— 收回 `module.inbound.edit` 会弄坏现场收货。
> 用 Q7 那个免费的 view/edit 拆分,把这两节对他渲染成**只读**。(→ Step 3,下一场)

**Q9 —— 幽灵专治,还是采用完整的四条判据?**
线上 `chef1949@126.com` 是**未确认**账号 —— 只问"有没有 auth.users 行"的弱判据下,它照样顶得上最后一个管理员。
> **裁定:采用 `real_role_holders` 的完整四条。** 写第二份更弱的判据,正是那支函数存在要消灭的漂移。

**Q10 —— 采用四条判据有一处机械障碍。**
`real_role_holders` 返回 `user_id` 集合,而守卫必须排除**正在被撤销的那一行**;按 `user_id` 排除在一人持两个 `is_system` 角色时不等价,而第二个系统角色是造得出来的。
> **裁定:新增 `real_role_grants(p_role_code) → (grant_id, user_id)`,并把 `real_role_holders` 改写成它的投影。
> 这是本刀【唯一】的 DDL —— 一次迁移,一个破窗。先在前台备份,原子迁移,报告破窗时长。**

**Q11 —— 强制换密码?** → **裁定:强制。**
**Q12 —— 邀请流程并存还是替换?** → **裁定:替换。** 不留一个没配 SMTP 时安静失败的按钮。
**Q13 —— 员工档案。** → **裁定:六份**(Vince / Sandra / Phua / Fu Sheng / Choo Er + Tim 的那份见 Q14)。
**Q14 —— `chef1949@126.com`。** → **裁定:它是造邀请功能时的测试邮箱,不属于任何人。删账号、删授权、删员工行 —— 但【先查引用,有引用就停手报告,不强删也不级联】。**
**Q15 —— 遗留测试数据。** → **裁定:删四行 `ZZ-2BL-*` 员工与五个封禁账号;六条被引用的 scratch 行留着。**
**Q16 —— 毕业之后没有后继闸。** → **裁定:照样毕业,并像 CONV-0 / CONV-1 那样把"这道闸对这三个已经花掉了"写在明处。**
**Q17 —— 角色表单要不要搬上组件库?** → **裁定(修正):本刀【不搬】。** 那是对已上线可用代码的两小时形制改造,而 Tim 在发放之前不会用角色屏。账号屏照搬(反正在重写)。
**Q18 —— `cfo` 角色何去何从?** → **裁定:留着,并且由 Tim 持有**(见 Q1)。
**Q19 —— 幽灵还会再长出来。** → **裁定:只修"数错"。** 在 `known-issues.md` 的 GHOST-GRANTS 记下:**计数的洞堵上了,产地(`smoke-routes.mjs:1313`)仍然开着。**

---

## 四 · 本刀实际做了什么

### Step 0 —— 三个组件毕业

`input` · `label` · `select` 从 `scripts/check-base-isolation.mjs` 的 `GUARDED` 里拿掉,
并删掉 `KNOWN_CONVERSIONS` 里 `app/login/page.tsx → input` 与 `→ label` 两行。

> **为什么那两行非删不可(实测):** 三个组件离开 `GUARDED` 后,`importRe` 再也匹配不到它们,
> `known` 从 4 掉到 2,而 `KNOWN_CONVERSIONS.size` 仍是 4 ——
> 「基线比实际宽」那道自检会当场 **EXIT 1**,报「登记了 4 处,只找到 2 处」。

**★ 这道闸对这三个组件【已经花掉了,而且没有后继】。** CONV-0 拿掉 `refusal` 时有"只剩一份实现"接替;
CONV-1 拿掉 `data-table` 时有三样东西接替。**这三个没有。**
从今天起本仓库**没有任何机器**在检查谁 import 了它们。

**故障注入(两个方向):**

```
A 把【仍在 GUARDED 里】的 card 注入 app/welcome/page.tsx  → EXIT 1
    import  app/welcome/page.tsx:1  → @/app/components/ui/card   ← 点名到行
B 把【已毕业】的 input 注入同一个位置                      → EXIT 0  ← 好代码不被罚
   撤掉注入后 app/welcome/page.tsx 与 HEAD 逐字节相同(git diff 0 字节)
```

### ★ 闸当场抓到了本刀自己的一次越界 —— 而处置是退回来

写 `CreateAccountPanel` 时我用了 `Card` / `CardContent` / `Button`,
**而 Tim 的裁定只毕业了 input / label / select 三个。**
隔离闸 EXIT 1 并点名 `CreateAccountPanel.tsx:31 → button`。

> **处置:把按钮与卡片退回原生标记,不顺手把 button/card 也毕业掉。**
> 一道闸自己抓到的越界,如果由撞上它的人当场放宽,那道闸就不存在了。
>
> ☞ **留给下一刀的判断:一张真正的表单页需要 `button`,几乎肯定还需要 `card`。**
> 下一次建表单页会立刻再撞一次 —— 那时该由 Tim 裁定是否一并毕业,而不是由撞上的人决定。

### Step 0b —— `guard_last_admin` 只数真的数得上的授权

迁移:`db/migrations/2026-09-04-c1-guard-last-admin-counts-real-holders.sql`

* 新增 `real_role_grants(text) → (grant_id, user_id)`,四条判据的**唯一住处**;
* `real_role_holders` 改写成它的投影(签名与语义不变,三个既有调用方不受影响);
* `guard_last_admin` 改数 `real_role_grants`,并改成 `SECURITY DEFINER`。

> **为什么守卫必须变成 DEFINER:** `real_role_grants` 读 `auth.users`,EXECUTE 要从
> `authenticated` 收回;调用者权限的触发器以 `authenticated` 身份跑就**调不到它**,
> 守卫会在每一次撤销授权时抛权限错。
> **这不触发 gate 的 B2** —— `B2_SQL` 里写着 `pg_get_function_result(p.oid) <> 'trigger'`。

> ⚠ **一处实测才发现的坑:`REVOKE` 写在迁移里【不算数】。**
> `apply_migration.sh` 在 COMMIT 之后会**重新断言一遍 `db/views/zzz_function_grants.sql`**,
> 而那个文件当时没有这一行 —— 于是那次 REVOKE 被原样冲掉,
> 实测 `has_function_privilege('authenticated','real_role_grants','EXECUTE') = true`,
> **一条活的 B2 违规**。收回必须写进 `zzz_function_grants.sql`。已补并复验为 `false`。

**证明(`db/fixtures/191`)** —— 造一个幽灵,在**同一份数据**上让两个判据各算一次:

| 臂 | 断言 |
|---|---|
| A | **旧**判据回答"还有管理员"(幽灵顶上了)—— 这就是缺陷的案发现场 |
| B | **新**判据回答"没有别的管理员" |
| C | 真的撤一次,守卫**真的抛** `LAST_ADMIN_PROTECTED`(判据算得对 ≠ 守卫会拦) |
| D | 一个**存在但未确认**的账号同样顶不上(Q9 那条差别) |
| E | 第二个**真**管理员在场时,同一次撤销**成功**(只会拒的闸和拦不住的闸一样坏) |

> **fixture 的一处自我修正:** 头一版跑在**线上**时 B 臂就红了 ——
> 因为线上已经有 Tim 的 admin 授权,撤销 fixture 那条**真的**是安全的。
> 那是**前提没建好,不是守卫坏了**。所以加了一步:先把其它所有在册 admin 授权撤掉,
> 让 `g_real` 成为唯一的真管理员。空的重建库上这一步是空操作。

### Step 1 —— 角色、六个人、测试数据

脚本:`db/scripts/2026-09-04-c1-roles-people-and-the-test-data-purge.sql`

### ★★ Q14:`EMP-2026-0001` 【没有】被删除 —— 停手并报告 ★★

Tim 的裁定带着一条前置条件:「先查引用;有东西引用它就 STOP 并报告」。**实测它被引用:**

| 表 | 行数 |
|---|---:|
| `employment_history` | 2 |
| `payroll_lines` | 1 |
| `task_history.employee_id` | 4 |
| `task_participants.employee_id` | 2 |
| `training_records` | 1 |
| **合计** | **5 张表 10 行** |

> **处置:只解绑账号(`user_id = NULL`),保留档案行本身。**
> **Choo Er 因此【复用】这一行**,而不是另建一行 —— 另建会得到两个 "Choo Er Teh",
> 而旧的那个还被引用着。她的姓名、部门、岗位、入职日期本来就在这一行上。
> ☞ **待 Tim 裁定:** 这 10 行本身也都像测试数据。要清就得连它们一起清,
> 而那是一次**级联** —— 本刀按规矩不做。

同一条规矩也拦下了一行 `ZZ-2BL`:

> `ZZ-2BL-186301` 被 `equipment_maintenance` 引用 1 行(`description = 'Test'`,2026-08-23 建)。
> **只解绑账号,不删行。** 另外三行 `ZZ-2BL-138972 / 160682 / 291186` 无人引用 → 已删。

### ⚠ 新建员工档案的 HR 字段是【占位值】

`hire_date` / `employment_type` / `work_category` / `residency_status` 本刀**无从得知**。
**`hire_date` 会进假期累积的计算。** 每一行的 `notes` 里都写了这句话 —— 写在数据里,不只写在文档里。
尤其 Fu Sheng 取了 `work_category = 'shopfloor'`(仓储现场负责人),它影响考勤与加班规则。

### Step 2 —— 账号屏:邀请 → 建账号 + 设初始密码

* `inviteActions.ts` → **`accountActions.ts`**(`inviteUser` → `createAccount`;`resendInvite` 删除)
* `InvitePanel.tsx` → **`CreateAccountPanel.tsx`**,用 `Input` / `Label` / `Select`
* `UserRow.tsx` 的「重发邀请」按钮删除
* `lib/supabase/middleware.ts` 按 `must_change_password` 把人扣在 `/set-password`
* `app/set-password/SetPasswordForm.tsx` 在**同一次** `updateUser` 里改密码并清标记

> **角色为什么是 Select 而不是一排勾选框:** 勾选框把"零个"画成一个合法形状,
> 于是"建一个没有角色的账号"看起来像一个选项 —— 它不是。

> **★ 建到一半失败时的清理是【查状态码】的。** PRE-ACCOUNT-1 的头条正是这个形状:
> 四个带着仓库里公开密码的管理员账号活了 ~17.5 小时,因为清理**失败了却没人知道**。
> 所以 `createAccount` 的 `undo()` 返回它自己成不成功,而两种失败**说不同的话**:
> 「已经清干净,可以重试」 vs 「**没清掉**,现在有一个没有角色的账号,请立刻去删」。

> **`setEmployeeLink` 删掉了 —— 它是死代码。** 原文件注释说它"供用户页的编辑面板使用",
> 实测**没有任何文件 import 过它**(UserRow 走的是 `../accountsActions` 的 `saveUserRoles`)。

### 密码走的路

表单 → server action → Supabase。**不进 URL、不进任何日志、不进任何被 git 跟踪的文件。**
失败时也不回显密码;提交失败时密码框会被清空(留在屏幕上的密码是一次肩窥)。

---

## 四之二 · 验证:每一个退出码都读自脚本【自己的】日志

| 检查 | 退出码 | 备注 |
|---|---|---|
| `~/evoltrya-backups/backup.sh` | `BACKUP_OWN_EXIT=0` | TOC 5269 条;`pg_restore --list` 另跑一次,exit 0 |
| `db/apply_migration.sh` | `MIGRATE_OWN_EXIT=0` | 单事务;破窗起点 19:47:31 |
| `db/fixtures/191`(新) | 通过 | 线上跑过一次(整段回滚),gate 的**重建库**上也通过 |
| `db/fixtures/151`(修好) | `FX151_OWN_EXIT=0` | 注入目标改成 `real_role_grants`,并加了一句授权断言 |
| `scripts/check-base-isolation.mjs` | `0` | 两个方向都做了故障注入 |
| `scripts/check-component-library.mjs` | `0` | **基线未变**:66 个文件 / 76 处 |
| `scripts/check-datatable-phone.mjs` | `0` | 122 个调用点;**C-1 没有新增调用点**(两张新屏都不画表) |
| `scripts/check-i18n.mjs` | `0` | |
| `npx tsc --noEmit` | `0` | ★ 但它**没能**拦住那条 `'use server'` 的错,见 §四 |
| `npm run build` | `BUILD_OWN_EXIT=0` | 全部 20 道闸 + `next build` |
| `python3 db/gate.py` | **`GATE_EXIT=0`** | 三个判词全绿(wall-clock 368s) |
| `node scripts/smoke-routes.mjs` | **`SMOKE_EXIT=0`** | 217 条计时 · 合计 737.9s · 中位数 3053ms · 全部 200 |
| `node scripts/smoke-routes.mjs --reach=admin` | **`SMOKE_EXIT=1`** | ★ **结构性地红,不是 C-1 弄坏的** —— 见 known-issues 的 SMOKE-REACH |

**探针跑在 `npm run build` 【之前】。** 顺序如实写:
① 先跑探针(`.next` 里只有 `dev/`,没有 `BUILD_ID`)→ 它把 `/settings` 九条路由
全读成 HTTP 500;② 诊断用 `next build` 定位到那条 `'use server'` 的错;
③ 修好后 **`rm -rf .next`** 再跑一次探针 → 九条全部量得出来;
④ 然后才 `npm run build`;⑤ 冒烟前又 `rm -rf .next`(冒烟**没有** BUILD_ID 那道守卫)。

**手机形态实测(390px):`/settings` 九条里 8 条过关。**
`/settings/accounts` 溢出 27px —— **本刀之前就有**,判据见 known-issues ③。

---

## 五 · 留给下一场(Step 3)

1. 应用矩阵,含 Q8 的字典只读渲染;
2. 对「会静默弄坏数据」的子页做**服务端**证明,不是"按钮藏起来了";
3. 上面那条 `cco` 的 dictionaries E ↔ inbound VIEW 冲突,等 Tim 再裁一次。
