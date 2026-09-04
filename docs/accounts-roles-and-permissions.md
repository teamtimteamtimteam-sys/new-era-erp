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

### 破窗时长

| | |
|---|---|
| 起点(库已经是新的) | `2026-09-04 19:47:31 CST` —— `apply_migration.sh` 打印,并落进 `db/migration-windows.tsv` |
| 终点(部署 state=success) | `2026-09-04 22:12:31 CST` —— 部署 id **6266152151** |
| **时长** | **2:25:00(145 分钟)** |

【这段时间里线上是什么状态】数据库已经是新的(守卫改数 `real_role_grants`),
而应用还是旧的。**这一次的破窗风险接近于零**,理由可以说清楚:本迁移只改了
一个**触发器函数**的判据,而 `app/` 下没有任何代码调用 `guard_last_admin` 或
`real_role_grants` —— 它们只在数据库内部被 `user_roles` 的写入触发。
新旧两版应用对它的感知完全一样。**这不是一句宽慰:如果迁移动的是应用读得到的
列或函数签名,同样长的窗口就会是一次真的暴露。**

**手机形态实测(390px):`/settings` 九条里 8 条过关。**
`/settings/accounts` 溢出 27px —— **本刀之前就有**,判据见 known-issues ③。

---

## 五 · 留给下一场(Step 3)

1. 应用矩阵,含 Q8 的字典只读渲染;
2. 对「会静默弄坏数据」的子页做**服务端**证明,不是"按钮藏起来了";
3. 上面那条 `cco` 的 dictionaries E ↔ inbound VIEW 冲突,等 Tim 再裁一次。

---
---

# 第二部分 · C-1b(2026-09-04):把矩阵真的落到实处

> 体例同上:每一条写成【问 → 我的建议与证据 → Tim 的裁定】。
> C-1a 的问答在第一部分,不要把两轮混在一起读。

## 〇 · C-1b 的委托书里,被实测推翻的两条

### ★ 假一:「NO DDL EXPECTED。item 2 与 3 是 registry 改动,不是 schema 改动」

**这一条是错的,而且如果照着做,会 ship 出一个【骗人的矩阵】。**

字典的写入路径 `app/settings/dictionaries/actions.ts` 里【没有任何一句
require_permission】—— 它整个靠 RLS,只在末尾把 `42501` 翻成一句人话。
也就是说 `registry.ts` 的 `permission` 字段**只是界面的门**。库那一侧的真相是:

```
laboratories            INSERT  WITH CHECK has_permission('module.inbound.edit')
laboratories            UPDATE  USING/CHECK has_permission('module.inbound.edit')
inbound_source_reasons  INSERT  WITH CHECK has_permission('module.inbound.edit')
inbound_source_reasons  UPDATE  USING/CHECK has_permission('module.inbound.edit')
```

**只改 registry = 把表单藏起来,而写入照样敞开。** Fu Sheng 仍持 `module.inbound.edit`,
一次直连 PostgREST 的 INSERT 照样建得出实验室。而委托书自己要求的是
「demonstrate SERVER-SIDE … not merely that a button is hidden」——
只改 registry 的话,**那个证明会在它要证的那一页上当场失败**。

所以 item 2+3 确实是【一次】改动,但它是一次 **schema 改动**:四条策略,一支迁移。

> **Tim 的裁定:** 做 DDL。「一次装样子的收窄比不收窄更坏,因为文档就得写成
> 『藏起来了,没有强制』,而后来的人会把矩阵当成真的。」

### ★ 假二:「ITEM 1 —— 应用权限矩阵(the main work)」

**七行里有六行【今天就已经是对的】,一行代码都不用改。** 逐格对着线上授权实测:

| 子页 | 把门的码 | 今天就满足矩阵吗 |
|---|---|---|
| accounts | `action.manage_permissions` | ✅ 只有 admin 与 cco 持有 |
| roles | 同上 | ✅ |
| reference | 同上 | ✅ 而且**零按钮、零表单、零输入框** —— R 是构造上的 |
| approvals | 同上 | ✅ **0/0/0** —— R 是构造上的 |
| deleted | `data.view_deleted` | ✅ **0/0/0** —— R 是构造上的 |
| import | `action.bulk_import` | ✅ |
| **dictionaries** | 逐节 `module.X.edit` | ❌ **唯一要动的一行** |

那三个「R」的格子,**控件是真的不存在**,不是被灰掉 —— 这正是委托书要的那种只读。
**item 1 真正的工作是【证明】,不是【应用】。**

## 一 · 谁看得见什么 —— 全部 12 个在册角色(不只那六个人)

C-1b 之后,逐格实测。`E×4` = 四张物料字典可编辑;`R×2` = 两张进料字典只读。

| 角色 | accounts | roles | reference | approvals | deleted | dictionaries | import |
|---|---|---|---|---|---|---|---|
| `admin` | E | E | R | R | R | E×4 + E×2 | E |
| `cco` | E | E | R | R | R | E×4 + E×2 | E |
| `gm` | — | — | — | — | — | E×4 + E×2 | — |
| `finance` | — | — | — | — | — | E×4 + E×2 | — |
| `operations` | — | — | — | — | — | E×4 + E×2 | — |
| `procurement` | — | — | — | — | — | E×4 + E×2 | — |
| **`warehouse`** | — | — | — | — | — | **R×2** ← item 2 的落点 | — |
| `auditor` | — | — | — | R | R | R×4 + R×2 | — |
| `sales` | — | — | — | — | — | R×4 | — |
| `cfo` | — | — | — | — | — | — | — |
| `hr` | — | — | — | — | — | — | — |
| `employee` | — | — | — | — | — | — | — |

★ **`cfo` 在这张表上一格都没有,而这不是缺陷** —— Tim 持 `admin` + `cfo`,
他走的是 admin 那一路(C-1a 的 Q1:把「谁管系统」与「谁批钱」分开)。

★ **`auditor` 与 `sales` 是【新】看得见字典页的**(只读)。
在此之前他们撞的是整页拒绝。Tim 知情并接受(Q4)——
判据是:这六张表的 SELECT 策略本来就是 `USING (true)`,
**他们本来就读得到,给一张只读的表比给一句拒绝更诚实。**

## 二 · item 2 + 3 是同一次改动,而它有两半

**registry 那一半**(界面):`DictSpec` 拆成 `permission`(写)与 `viewPermission`(读)。
四张物料字典 view = `materials.view`;实验室与无单收货理由
**edit = `materials.edit`、view = `inbound.view`**。

**迁移那一半**(数据库,真正拦住写入的):四条策略从 `module.inbound.edit`
抬到 `module.materials.edit`。

> **读与写为什么可以是两个码,而这不是投机取巧:** 现场的人必须【看得见】有哪些
> 实验室、有哪些收货理由,否则他填不了单;而决定"名录里该有谁"是物料主数据的事。
> 这就是 Fu Sheng 的处境,一个新码都不需要。

**谁受影响 —— 逐个点名,实测:**

* **失去**这两节编辑权的角色 = 持 `inbound.edit` 而不持 `materials.edit` 的
  → **只有 `warehouse` 一个**;
* **获得**编辑权的角色 → **一个都没有**;
* `admin` / `cco` / `finance` / `gm` / `operations` / `procurement` 都同时持
  `materials.edit`,**一个都不受影响**。

**另外:`cco` 的 `module.inbound.edit` 被收回了**(Tim 的 Q3)。
那条授权是 C-1a 为了"字典那一格是 E"顺带给的**副作用,不是一个决定**;
字典既然改由 `materials.edit` 把门,它就没有存在的理由了。
Sandra 保留 `inbound.view`(所以那两节仍然可编辑:写靠 materials.edit)与
`materials.edit`,**她的进料回到只读 —— 那正是 C-1a 原本裁的**。

## 三 · 问答全文(问 → 建议与证据 → 裁定)

**Q1 —— 做策略 DDL,还是放弃收窄?** 见上面「假一」。
➡️ *建议:* 做。四条策略,一支迁移。
> **裁定:做。** 「一次装样子的收窄比不收窄更坏。」

**Q2 —— Fu Sheng 怎么拿到只读而不是【什么都没有】?** 实测他
**一个 `materials` 权限都没有** —— `.view` 也没有。所以若六张字典全部只认
`materials.*`,他撞上的是整页拒绝,而不是只读。
➡️ *建议:* registry 拆成 permission / viewPermission,那两张 view 用 `inbound.view`。
> **裁定:照办。不铸新码,不新增授权。**

**Q3 —— 收回 cco 的 `module.inbound.edit`?**
➡️ *建议:* 收回;这是一条 Sandra 今天真的有、而 C-1a 刻意给过的能力,所以要你点头。
> **裁定:收回。那条授权是字典那一格的副作用,不是一个决定。**

**Q4 —— 只读渲染会让 `auditor` 与 `sales` 新看见这一页。**
➡️ *建议:* 接受并写进文档,不要悄悄上线。
> **裁定:接受,写进文档。**

**Q5 —— 还有谁需要编辑实验室?** 实测:失去的只有 warehouse,没有人获得。
> **裁定:照做。**

**Q6 —— 服务端证明长什么样?**
➡️ *建议:* 一支回滚 fixture,四扇门各钉【两个方向】。
> **裁定:批准,而且【必须有正对照】——「A proof that passes by refusing everything
> is not a proof.」**

**Q7 —— 要不要加一道检查,盯住 registry 与 RLS 一致?**
➡️ *建议:* 不加,写进文档。与 tsc 那条同一个道理。
> **裁定:不加。写下来:registry 是界面的门,RLS 谓词才是真相。**

**Q8 —— 只读长什么样?**
> **裁定:控件【整个不渲染】** —— 没有 AddRowPanel、没有行上的操作列,
> 一句话说明这一节是只读。**不是灰掉的按钮。**

**Q9 —— item 4 的机制。** 毕业 `button` 会让 `KNOWN_CONVERSIONS` 里
`'app/login/SubmitButton.tsx → button'` 变成孤儿,触发「基线比实际宽」自检 —— 与 C-1a
删 input/label 两行【同一个机制】。
> **裁定:照办。card 在注入时必须仍然变红。**

**Q10 —— 那个蓝色。** 见下面第五节。
> **裁定:不动,但把数字记下来,让将来那一刀从一份【测量】开始,而不是从一次走查开始。**

**Q11 —— 那六个人之外的角色。**
> **裁定:把 12 个角色的整张表写进文档。**(见第一节)

## 四 · 一条适用于不止一页的发现

**本仓库【没有任何机器】在检查 registry 的 `permission` 与那张表 RLS 谓词一致。**
`check-permission-predicate.mjs` 回答的是另外三个问题(求值只有一处 /
一个功能能属于几个模块 / 进不去要说出来),它对这条一致性无话可说。

**于是「只改 registry」这个错误是【隐形】的:** 界面看起来收紧了,闸全绿,
而写入敞开着。C-1b 差一点就这么做了 —— 拦住它的不是任何一道闸,是先去读了一遍策略。
Tim 裁定不为它建第四道检查(与 tsc 那条同一个道理),所以**它靠这一段活着**:

> ⚠ **改 `registry.ts` 的 `permission` 时,同一刀必须改那张表的 RLS 策略。
> 反过来也一样。两者不一致时,没有任何东西会告诉你。**

## 五 · item 6:那个蓝色 —— 报告,不动手

`/suppliers` 的「+ 新建供应商」用的是 **硬编码 `bg-blue-600`**(Tailwind 默认色),
**不是**品牌色。品牌那条链是通的:
`--color-primary` → `var(--brand-ocean-fill)` → `#007FAD`
(由 Pantone Hawaiian Ocean `#008EBC` 压暗到白字对比度 4.53:1 得来)。

**实测规模 —— 这不是一个按钮,是仓库里最主流的手搓按钮样式:**

| 量的是什么 | 数 |
|---|---:|
| `bg-blue-600` 出现次数 | **159** |
| 涉及文件 | **139** |
| `bg-blue-700`(它的 hover 伴生) | 134 |
| `text-blue-600` | 298 |
| 与那颗按钮**逐字相同**的签名 `bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400` | **54** |

**所以颜色这件事自成一刀**,而它现在从一份测量开始,不是从一次走查开始。

## 六 · item 4:`button` 毕业了,而理由与前三个不同

Tim 的判词:**这道闸在 button 这一格上,罚的是【对的】那一边。** 实测支持它,
而且比他说的更强 —— `app/`(不含组件库自己)有 **383 个手写 `<button>` 开标签,
散在 200 个文件里,81 种不同的 className 签名**,一个都不被这道闸看见;
而唯一被拦下来的,是那个颜色对的库按钮。

**这道闸现在对四个组件都花掉了:** `input` · `label` · `select`(C-1)· `button`(C-1b)。
**`card` 仍然守着**,清单上剩下的 6 个也是。

## 七 · 破窗时长(C-1b)

| | |
|---|---|
| 起点(库已经是新的) | `2026-09-04 22:55:53 CST` —— `apply_migration.sh` 打印 |
| 终点(部署 state=success) | `2026-09-04 23:45:57 CST` —— 部署 id **6267846189** |
| **时长** | **0:50:04(50 分钟)** |

【这段时间里线上是什么状态,以及为什么这一次的风险【不】接近于零】
库已经收紧(那两张字典的写权要 materials.edit),而应用还是旧的。
**旧应用的 registry 仍然按 `inbound.edit` 决定画不画表单** —— 也就是说在这
50 分钟里,一个只持 `inbound.edit` 的人(warehouse)**看得见那两节的编辑表单,
而按下保存会撞上 42501**。那正是本刀最想消灭的形状,只不过它被压缩在窗口里。

★ **方向是安全的那一边:先收紧库,再更新界面。** 反过来(先放松界面、后收紧库)
会在同样长的窗口里【真的放行】那些写入。这一条值得写下来:
**当一刀同时改「谁能写」与「界面画不画」时,先改库。**
今天线上只有 Tim 一个账号,而他持 admin —— 所以实际受影响的人是 0 个。

## 八 · 与 C-1a 的破窗对照(为什么这次长了一倍)

| | C-1a | C-1b |
|---|---|---|
| 时长 | 2h25m | **50m** |
| 做法 | 先迁移,再写全部代码 | **先写完全部代码,再迁移** |

C-1a 的窗口里有四个小时的编码;C-1b 把编码挪到迁移【之前】,窗口只剩
验证与部署。**同样的活,窗口短了将近三分之二** —— 这条顺序值得成为默认做法。

---

# 九 · C-2(2026-09-05)· 六个人的档案从占位值变成事实

**发号之前的最后一刀。C-1a 建了四条员工记录,HR 字段全是占位值;C-2 把它们落实。**

## 9.1 六个人今天的样子(线上实测,迁移之后)

| 工号 | 姓名 | 入职日 | 居留身份 | 职位 | 系统角色 |
|---|---|---|---|---|---|
| EMP-2026-0001 | Choo Er Teh | 2026-08-01 | `work_pass` | LEAD-ACC | finance |
| EMP-2026-0002 | Tim | 2026-08-11 | **(空 —— 见 9.3)** | CFO | admin + cfo |
| EMP-2026-0003 | Vince Goh | **2026-09-01** | `citizen` | **MD** | gm |
| EMP-2026-0004 | Sandra Yap | **2026-09-01** | `citizen` | **CCO** | cco |
| EMP-2026-0005 | Cheng Siong Phua | **2026-09-01** | `citizen` | **CTO** | operations |
| EMP-2026-0006 | Fu Sheng Wong | **2026-09-01** | `pr` | **LEAD-WH** | warehouse |

粗体 = C-2 写入的。六人全部 `full_time`,均不在试用期;
`work_category` 为 office(Fu Sheng 是 shopfloor)。

### ★ 只改了四行,而这是一次【勘察改掉的裁定】

Tim 最初的裁定是「六个人的入职日都是 2026-09-01」。勘察发现其中两行**不是占位值**
(Choo Er 2026-08-01、Tim 2026-08-11),而改动它们会让两人**各少掉一个月的年假累积**
(24/12 = 2 天)。**Tim 据此改了裁定:只写四个占位行。**

> **顺带纠正一条委托书里的前提:「那四个人的假期余额现在是错的」—— 假的。**
> 累积从 `date_trunc('month', hire_date)` 起算,而 `2026-09-04` 与 `2026-09-01`
> **是同一个月**:两者算出的余额逐位相同。**档案是错的,余额不是。**
> 迁移里因此有一对**反向断言**,确认那两行没有被顺手改掉。

## 9.2 ★ 职位 ≠ 角色 —— Phua 那一行是这条区别的活例子

**Cheng Siong Phua 的【系统角色】是 `operations`,【职位】是 CTO。两者不必一致。**

| | 它决定什么 |
|---|---|
| **职位**(`positions`) | 他**被考核哪五条 KPI** —— KPI 绑在职位上,不绑在人上(规格 §8.1) |
| **系统角色**(`roles`) | 他**看得见什么、改得动什么** —— 权限矩阵 |

原表点名 Phua 是 CTO,所以他的五条 KPI 从 CTO 模板复制;而他日常操作的是运营模块,
所以角色是 operations。**两者都不算错**(Tim 2026-09-05 裁定)。

## 9.3 ★ 一次按名的停止:Tim Chen 的居留身份没有写

Tim 补充裁定给了六个人的居留身份,并要求**用这一列已有的词汇表,缺值就停下来报告,
不要发明,也不要顺手放宽这一列**。

`employees_residency_status_check` 的词汇是 **`citizen` / `pr` / `work_pass`**,
五个人都对得上。**Tim 自己那一格停了 —— 而它不是词汇表缺一个值:**

EP 在这套模型里**是一种 work pass**(`residency_status='work_pass'` +
`work_pass_type='EP'`)。缺的是另一张表上的约束要的东西:

```sql
CONSTRAINT employees_work_pass_shape CHECK (
    residency_status IS DISTINCT FROM 'work_pass'
    OR (work_pass_type IS NOT NULL AND work_pass_expiry_date IS NOT NULL))
```

**`work_pass_expiry_date` —— 一个我没有的日期。** 编一个出来会让 `hr_alerts` 的
`work_pass_expiry` 那一支照着假日期去提醒或不提醒,而它看起来和真日期一模一样。
**宁可空着,不可编。**

> ### ★ 发号之前要 Tim 补的两样(这一格是全刀唯一没做完的地方)
> 1. Tim Chen 的 **`work_pass_type`**(大概是 `EP`)与 **`work_pass_expiry_date`**;
> 2. **Choo Er 的 `work_pass_expiry_date` 是 `2026-08-10` —— 已经过期 26 天**
>    (勘察发现,不属于 C-2 范围)。要么是待更新的旧数据,要么她的准证真的需要处理。
>
> 两样都在 `/hr/employees/[id]/edit` 上填得了,**不需要发版,也不阻塞发号**
> —— 但 `residency_status` **不驱动任何计算**(见 9.4),所以空着不会让任何数字出错。

## 9.4 `residency_status` 驱动什么 —— ★ 实测:什么都不驱动 ★

Tim 问了这一条。逐个读者查过:

| 读它的地方 | 干什么 |
|---|---|
| `my_profile` / `employees_masked` / `employee_directory` | **显示** |
| `export_my_personal_data` | PDPA 个人数据导出 |
| `anonymise_employee` | 离职匿名化时置空 |
| `app/hr/employees/*` | 表单与详情页显示 |

**没有一处做计算。** 特别是:

* **CPF 不算** —— 工资整个是外包的。`payroll_lines` 的表注写着「数字**全部来自
  外包服务商**;本系统记录并过账,**从不自己算 CPF 或个税**」。
* **外劳税(levy)全库零命中** —— 这个系统没有这个概念。
* **假期不看它** —— 年假费率由 `work_category`(office / shopfloor)决定,
  不由居留身份决定。

> **所以这六格从 NULL 变成有值,【没有改变任何一个已经算出来的数】。**
> 它改变的是:PDPA 导出更完整、HR 详情页不再显示「—」、
> 以及将来真要接 CPF 或 levy 时这份事实已经在库里了。
> ★ 也就是说 Tim 那一格空着,今天的代价是 0 个错数字。
