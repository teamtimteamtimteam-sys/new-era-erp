# 账号、角色与权限 —— 六个人进系统之前的那一刀(C-1,2026-09-04)

> **这份文档的体例:问答在正文里,不只在结论里。**
> CONV-9 丢掉过一轮问答,结果后来的一刀几乎推翻了 Tim 的一条裁定 ——
> 因为文档只记了"决定是什么",记不出"这是 Tim 定的"还是"那一刀自己定的"。
> 所以下面每一条都写成【问 → 我的建议与证据 → Tim 的裁定】三段。

---

## ★ 被锁在门外了怎么办 —— 恢复流程(COPY-1,2026-09-06 从屏幕搬到这里)

**这一节是 `/settings/accounts` 那句「进不去是救得回来的」所指的地方。**

### 为什么它在文档里,不在屏幕上

从前 `/settings/accounts` 上印着这么一句:

> Locked out? A lockout is recoverable in two minutes by connecting as the postgres
> role through the pooler, which bypasses RLS. The exact procedure is documented in
> the header of `db/migrations/2026-08-01-perm2a-module-enforcement.sql`

读这一屏的是仓管与行政,其中几位的第一语言是中文。「以 postgres 角色经连接池
直连绕过 RLS」对他们**没有任何可执行的东西,只有惊吓** —— 而那个 `.sql` 路径
不是线索,是噪音。

★ **读者本身是对的,没有变。** 那一屏的注释早就写清楚了:被锁在门外的人**读不到
这一屏**,所以这句话从来就是写给【还进得来的管理员】看的 —— 他要知道的只有两件事:
**救得回来**,以及**去哪儿找**。屏幕现在只说这两件;做法在下面。

### 做法(给 Tim / 拿得到数据库的人)

1. 以 `postgres` 角色经**连接池(pooler)**直连线上库。该角色**不受 RLS 约束**,
   所以即使权限表被改成谁都进不去,这条路仍然通。
2. 完整的分步流程写在这个文件的**文件头**:
   `db/migrations/2026-08-01-perm2a-module-enforcement.sql`
3. 实测**两分钟**以内可恢复。

> ★ **没有人会被永久锁在外面**,这是这套权限模型成立的前提之一 ——
> 一个能把自己锁死的系统,不该被交给六个人每天用。

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

> ### ⚠️ 【FIX-2a 更正,2026-09-05】这一句原本写的是「**刻意**不给 `data.view_banking`」
>
> **那是一次【假设】,不是一次裁定。** 改写为:
>
> **`cco` 【持有】 `data.view_banking`**(开在发票上的公司银行明细)。
> **★ 已裁定(UI-1a,2026-09-05):Tim 的原话是「SANDRA MAY SEE THE COMPANY'S
> BANK DETAILS」。授予方式是 `role_permissions` 的一行,没有迁移、没有 DDL。★**
> 【它此前【从未被裁定过】,是一个敞着的决定 —— 那段历史留在 §11.2b,
> 因为值得记住的不是这个权限码,是它差点被当成一条裁定的过程。】

> ★ **`cco` 与 `gm` 不是包含关系,两个方向各宽一点。**
> `cco` 多出 `view_pay` · `view_identity` · `view_deleted`;`gm` 多出 `view_banking`。
> ~~Tim 知情:「Sandra 会看见成本与利润、薪酬、身份信息与价格」—— 那句话里没有银行明细。~~
>
> > ### ⚠️ 【FIX-2a 更正】上面那句划掉的话,是这份文档里最该被记住的一次错误。
> > **它从"Tim 那句话【没有提到】银行明细",推出了"Tim 【决定】不给银行明细"。**
> > 那正是本文档 §11.2 用整整一节在禁止的形状:**把一次缺席渲染成一个答案。**
> > 完整的传播链见 **§11.2b**。
>
> **不要为了"对称"给 gm 加任何东西**(见 Q3 —— ★ 那一条的【裁定】是真的:
> 「`gm` 一个字不动」。但 Q3 里「两处排除都是有记录的刻意决定」那句话是
> **提问者的建议**,不是 Tim 的裁定,而它当时也没有依据。见 §11.2b 的表。)

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

---

# 十 · C-2 的破窗:1 小时 05 分 57 秒

| | |
|---|---|
| 起点(库已经是新的) | `2026-09-05 00:38:53 CST` —— `apply_migration.sh` 打印 |
| 终点(部署 state=success) | `2026-09-05 01:44:50 CST` —— 部署 id **6269781105** |
| **时长** | **1:05:57(65 分 57 秒)** |

## 10.1 这段时间里线上坏了什么 —— ★ 量过的,不是估的 ★

**只有一件事:`/hr/leave/holidays` 上【新增】一个假期会失败。**

对着当时线上那份代码(`8afa0b7`)逐条查过:

| 改动 | 旧代码在窗口里会怎样 |
|---|---|
| `public_holidays.holiday_key` 变 NOT NULL | ★ **旧的 `saveHoliday` 的 patch 里没有这一列** → INSERT 违反 NOT NULL → **新增假期失败**。修改既有假期不受影响(patch 不碰这一列) |
| `score_kpi_entry` 换签名(7→8 参数) | **不坏** —— 部署代码里 `app/` 与 `lib/` **零调用点**(只有 `database.types.ts` 里的类型声明) |
| `kpi_entries.feedback_note` / `kpi_cycles.locked_at` / `kpi_score_rubric` | **不坏** —— 旧代码不读这些列/这张表 |
| 六个人的档案与职位 | **不坏** —— 旧代码照读 |
| `/hr/kpi` 的六个职位挂满了 | **不坏**,而且是【对的】:那句具名缺席正确地不再渲染(见 kpi-framework §13.5) |

**当时线上只有 Tim 一个账号,而这一个坏掉的动作他在这 66 分钟里没有做。
实际受影响的人:0。**

## 10.2 与前两刀对照 —— ★ 窗口变长了,而原因【不是】顺序错了 ★

| | C-1a | C-1b | **C-2** |
|---|---|---|---|
| 时长 | 2h25m | 50m | **1h06m** |
| 做法 | 先迁移,再写全部代码 | 先写完代码,再迁移 | **先写完代码,再迁移** |

C-1b 那条结论(编码挪到迁移之前)**仍然成立,而且这一刀照做了** ——
窗口里一行业务代码都没有写。**长出来的 16 分钟全部是【验证】,而且几乎全部是
【第二遍】验证:**

* 门跑了两遍(每遍约 5.5 分钟)—— 第一遍红,抓到四件事;
* 冒烟跑了两遍(每遍约 17 分钟)—— 第一遍红,抓到第五件。

> ### ★ 这条对照给出的真结论,不是"顺序不对",而是:
> **代码先行之后,破窗时长已经【由验证套件的长度决定】,不再由编码决定。**
> 而验证套件里最贵的那一段是冒烟(约 17 分钟),它**每红一次就要整跑一遍**。
>
> **所以下一刀想再缩短窗口,能动的只有两处:**
> 1. **把能在迁移【之前】跑的检查,全部挪到迁移之前。** 本刀的五件事里,
>    **四件本来就可以**:镜像列序、`?? []`、两支 fixture 的必填列、
>    fixture 146 的位置参数 —— 它们**一个都不需要新的库**,
>    只需要把 `db/gate.py` 与那几支 fixture 对着【本地重建】先跑一遍。
>    (这与 AGENTS.md 那条「一条正确的检查放错了相位,就是一条慢检查」
>    是同一条,只是那里说的是开跑前 3 毫秒,这里说的是迁移前 5 分钟。)
> 2. **第五件挪不动** —— `/hr/kpi` 那条内容断言只有在【新数据真的在库里】
>    之后才会变红(六个职位挂满是迁移干的)。它属于"只有迁移之后才测得出来"
>    的那一类,而那一类就是破窗存在的理由。
>
> **记下来是因为下一个人会想再压这个数,而压错地方会把顺序改回去。**

---

# 十一 · FIX-1(2026-09-05)· 头三次真登录抓到的三件事

C-2 之后 Tim 建了第一批账号,亲自陪着走了头几次登录。这一节记的是那几次
走出来的东西 —— **全部来自真人在生产环境上的真操作,没有一条是走查看出来的。**

## 11.1 ★ 那张收货表单不是不方便,是【填不完】★

委托书报上来的是一件事:Fu Sheng(`warehouse`)打开「新增进料」,
**选不了供应商** —— 页面说「没有供货的供应商」,而 Tim 用自己的管理员账号
看得见供应商。

在**他自己的会话里**量过之后,真相比报上来的大三倍
(`SET LOCAL ROLE authenticated` + 他的 sub,单事务探针后回滚):

| `/inbound/new` 要读的 | Fu Sheng 看见 | `postgres` 看见 |
|---|---|---|
| `suppliers`(供货、在册) | **0** | 7 |
| **`materials`(在册)** | **0** | **5** |
| `customers`(在册) | **0** | 3 |
| `po_receivable_lines` | 0 | 0(线上今天确实没有可收货的单) |
| `storage_locations` | 1 | ✓ |
| `inbound_source_reasons` / `inbound_safety_states` | 4 / 5 | ✓ |

**供应商、物料、可收货采购单行,三个下拉全是空的。**

> ### ★ 为什么只有供应商被报上来
> **因为只有它自己会说话。** 那一格底下有一句「没有供货的供应商」,
> 而物料那一格只是一个空下拉 —— 一个空下拉和一个还没点开的下拉,
> 在屏幕上长得一模一样。**会出声的缺陷被报了上来,不出声的那个没有。**
> 这不是 Tim 看漏了,这是界面没说。

## 11.2 ★★ 这一节比本刀修的东西活得久:一次缺席被渲染成了一个答案 ★★

**挡住 Fu Sheng 的【不是】那道页面守卫。** 同一次探针里:

```
has_permission('module.inbound.view')  =  true      ← requireModule(MOD.inbound) 放行了
suppliers 可见行数                      =  0        ← RLS 在那之后把行滤光
```

页面正常渲染,守卫一声没吭。**RLS 的拒绝方式是【返回零行,不报错】。**
于是这一整条链上没有任何一环察觉出了事:

1. `requireModule` 通过 —— 它问的是"这个人进不进得来",答案是"进得来";
2. PostgREST 回 `200` + `[]` —— 没有 error,因为**这不是一次错误**;
3. `mustRows`(`lib/db-helpers.ts`)照定义把 `res.data ?? []` 递下去 ——
   它的分支是 `if (res.error) fail(...)`,而这里 `error` 是 null;
4. 页面自己的 `if (…Res.error)` 一支也不进;
5. 表单画出一张空下拉,底下写着「没有供货的供应商」。

> ## ★ 屏幕上那句「没有供货的供应商」,说的是七家真实存在的供应商。★
>
> **这正是 AGENTS.md 禁的那个形状:【把一次缺席渲染成一个答案】。**
> 而它此前一次都没有被抓到,原因很具体:
> **本仓库没有任何一道闸在看「这个读者拿到的空,是真的空,还是被滤成的空」。**
> 那两件事在 HTTP 层、在 PostgREST 的应答里、在 `mustRows` 的签名里,
> 都是同一个值 —— `[]`。要分开它们,只能问权限;而没有人在问。

这条发现的适用面【远大于收货表单】:任何一个页面,只要它的守卫用的码
与它读的表的 RLS 谓词不是同一个,就可能对某些角色画出这种"诚实的空"。
本刀量出来的是 **63 个文件、108 对(文件,表)** 处在这个形状里(见 11.4)。

**它与 C-1b 第四节那条是同一族,而且更深一层:**
那一条说的是「registry 的 `permission` 与 RLS 谓词不一致时,没有任何东西会告诉你」;
这一条说的是「**即使一致,守卫的码与页面读的表的码也可能不同,
而那个差额会安静地变成一屏空数据**」。

## 11.2b ★★ 一次观察,四跳之后变成了「Tim 自己的裁定」★★（FIX-2a,2026-09-05）

> **这一节【不是】关于银行明细。它是关于一份文档如何把自己的观察喂回给自己,
> 而每一跳都让那句话更硬一点 —— 直到它被当着 Tim 的面引用成他自己的决定。**

FIX-2a 的委托书要求核对本文档里每一句「Tim 裁定 / 刻意 / 明说」。核对的结果里
有一条是**结构性的**,而它值得比它所涉及的那个权限码活得更久。

### 那条链,逐跳点名

| 跳 | 位置 | 那一跳写下的话 | 它比上一跳多出了什么 |
|---|---|---|---|
| **0** | —— | **【事实】** Tim 说过:「Sandra 会看见成本与利润、薪酬、身份信息与价格」 | 一句关于**给了什么**的话 |
| **①** | §71 | 「Tim 知情……**那句话里没有银行明细**」 | **从一句话的【沉默】里读出了一个决定** |
| **②** | §67 | 「**刻意**不给 `data.view_banking`」 | 把①的推断写成了**一条属性**(「刻意」) |
| **③** | §893 | 「**刻意如此** —— …**§71 写明不给**」 | **改写了自己的出处**:§71 写的是"那句话没提",不是"写明不给" |
| **④** | §915 | 「那是**两次裁定**,不是两个缺口」 | 把它与 Vince 那条**真裁定**并列,于是它继承了后者的分量 |
| **⑤** | FIX-1 的报告 | 呈给 Tim 时,它是**他自己的一条裁定** | 闭环 |

**Tim 的回应(2026-09-05),原样记下:**

> 「一次观察经四跳变成了我随后归给自己的一条裁定。」

### ★ 为什么这一条比那个权限码要紧

**这份文档的 §11.2 用一整节讲一件事:一次缺席被渲染成了一个答案。**
「屏幕上那句『没有供货的供应商』,说的是七家真实存在的供应商。」

**而这条链是同一个形状,发生在【写那一节的这份文档自己身上】** ——
一句话里**没有提到**银行明细(缺席),被渲染成了**决定不给**银行明细(答案)。
唯一的区别是读者:那一次是 Fu Sheng 看着一张空下拉,这一次是 Tim 看着一份报告。

**它没有弄坏任何东西** —— 权限模型一个字节都没有动过,`cco` 今天没有
`data.view_banking`,而那**可能是对的**。危险的不是结果,是**依据**:
下一个人要重新决定这件事时,会读到「这是一条裁定」,于是不会去问。
**一条被相信的假依据,比一个错误的结果更难被发现,因为它会让人停止查证。**

### 判据(便宜,而且可以照着做)

> **「他没有说不」与「他说了不」之间,隔着一次提问。**
>
> 写下「刻意 / 裁定 / 明说 / by design」之前,回答一句:
> **我引用的那段话里,有没有【这个词】?**
> 有 → 引用它,连着出处行号。
> 没有 → 写「**未裁定**」或「**假设**」,并把它列进敞着的决定。
> **不要用"当时的语境显然是这个意思"补上那一步 —— 那正是第 ① 跳。**

**以及一条给读者的:** 一条声称有出处的断言,**去把那个出处读一遍**。
第 ③ 跳之所以成立,是因为没有人回头读 §71 —— 而读它只要十秒。

### 本刀对全文档的核对结果 —— 每一条都点名

| # | 断言 | 追得到裁定吗 | 处置 |
|---|---|---|---|
| 1 | §892 `gm` 读不到 `user_directory`(要 `action.manage_permissions`)是「刻意如此」 | **✅ 追得到** —— §82–85 那张矩阵抬头就写着「Tim 裁定的版本」,Vince 在 `/settings/accounts` 与 `/settings/roles` 两格都是「—」 | **保留,是裁定。** FIX-2a 不动那个权限;只把屏幕上的空【说出来】 |
| 2 | §67 `cco`「**刻意**不给 `data.view_banking`」 | **❌ 追不到** | **改成「没有」+ 标为敞着的决定**(已改)。**★ UI-1a 2026-09-05:Tim 裁了,授予 —— 那一格现在写「持有」。★** |
| 3 | §71「Tim 知情……那句话里没有银行明细」 | **❌ 这就是第 ① 跳本身** | **划掉,并在原地写明它是什么**(已改) |
| 4 | §893「刻意如此 —— §71 **写明**不给」 | **❌ 误引自己的出处** | **改写**(见 §11.4 那张表) |
| 5 | §915「那是**两次**裁定」 | **⚠️ 一半** —— Vince 那条是裁定,Sandra 那条不是 | **改成「一次裁定 + 一个敞着的决定」** |
| 6 | §146 Q3「两处排除都是**有记录的刻意决定**」 | **❌** —— 那是**提问者的建议**那一栏,不是「裁定」那一栏。Tim 的裁定只说了「`gm` 一个字不动」 | **标注:结论未受影响,但依据当时是假的** |
| 7 | §149 Q4 `operations`「刻意没有 `data.view_prices`」 | **✅** —— 裁定原文「初期不给。加回来便宜,看过了就收不回」 | **保留。** FIX-2a 的 (b) 判断正是建在它上面 |
| 8 | §102「Tim 是【刻意推迟】拆分 `action.manage_permissions` 的」 | **⚠️ 弱** —— 它在「Tim 点名要求记录」那一节里,所以**知情**是有据的;**「推迟」这个词**没有出处 | **标为假设,低风险** |

**七条里有四条追不到,而四条全部指向同一个权限码。** 这不是四次独立的疏忽 ——
**是同一次推断被引用了四遍**,而每一遍都让它看起来更像一次裁定。

### ★ 已裁定(UI-1a,2026-09-05):Sandra 看得见公司的银行明细

**★ 裁定原文:「SANDRA MAY SEE THE COMPANY'S BANK DETAILS」。★**
下面两边是 FIX-2a 摆给 Tim 的材料,**原样留着** —— 一条裁定的价值一半在结论,
一半在它当时权衡过什么。他选了「给」。

* **给的理由:** 她是 CCO,持有 `data.view_prices` / `view_sales` / `view_pay` /
  `view_identity` —— 六个人里 `admin` 之外最宽的数据授权。公司自己的收款银行
  出现在**每一张发出去的发票上**,而她做管理。
* **不给的理由:** 银行明细是**收款指令**,它的风险不是"被看见",是"被改"——
  而 `cco` 持有 `action.manage_permissions`,也就是说**她可以给自己授予它**。
  在那种情况下,不给它的作用更多是"记录一个默认",而不是一道墙。

**FIX-2a 做了什么、没做什么:**
* **没有**授予、**没有**收回 `data.view_banking`;
* **做了**:`/finance/company` 的银行那一段,对读不到的人从【五个空输入框】
  改成一句具名的拒绝(见 §13.4);
* **并且顺手关掉了一个真的洞** —— 那五个空输入框**保存时会把真实的银行资料清空**
  (见 §13.4,那一条不是文档问题,是缺陷)。

**这条决定回到 Tim 手上时,它是敞着的;他在 UI-1a 裁了它。**

**★ UI-1a 做了什么(2026-09-05)★**
* `role_permissions` 加了一行:`cco` + `data.view_banking`。**不是 DDL,没有迁移。**
* **两半都验过,在一个回滚掉的事务里**(模拟 Sandra 的会话):
  ① 那五列从【全部 NULL】变成【全部有值】;
  ② **25 张遮蔽视图逐张比对空值签名,只有 `company_profile_masked` 动了**,
     动的正好是那五列 —— 遮蔽按码生效,别的一列都没有跟着松开。
* **FIX-2a 的两件事都留着,一个字没改**:`/finance/company` 那一段对【没有这个码的
  任何角色】仍然渲染具名拒绝;`saveCompanyProfile` 仍然按权限筛出可写字段。
  ★ Sandra 从来不是那两件事防的对象 —— 防的是**日后持有编辑权而没有这个码的人**。★

## 11.3 修法:窄的【查名】视图,一个新权限码都没有

**没有把 `module.suppliers.view` 授给 warehouse**,因为那不是他需要的东西:
`suppliers` 表上还有 `payment_terms` / `incoterm` / `credit_rating` / `tax_id` /
`address` / `tax_residence`,而那个码同时打开 `contracts` 与 7 张 `contract_*`、
`commission_agreements`、`counterparty_contacts`、`company_compliance` ——
**整段商务关系**。`role_permissions` 对 warehouse 写的原话是
「现场收货、产出与盘点;**不接触任何商务数据**」。

他要的只有一样:**把那家供应商的名字叫出来,好让这张收货单指得中。**

照 C-1b 已经裁过的那句话做(本文档 §462:「读与写为什么可以是两个码…
这就是 Fu Sheng 的处境,**一个新码都不需要**」),第二处落点:

| 新视图 | 它出的列 —— ★ 这份清单【就是】暴露面 ★ | 体内谓词 | 因此新读到的角色 |
|---|---|---|---|
| `supplier_lookup` | `id, code, legal_name, supplies_goods, counterparty_type, deleted_at` | `suppliers.view` OR `inbound.view` | `operations`、`warehouse` |
| `material_lookup` | `id, code, name, deleted_at` | `materials.view` OR `inbound.view` OR `output.view` | `warehouse` |
| `customer_lookup` | `id, code, legal_name, deleted_at` | `customers.view` OR `output.view` | `operations`、`warehouse` |
| `po_receivable_lines_lookup` | `po_id, po_code, supplier_id, order_date, line_id, line_no, material_id, material_name, unit, remaining_qty` —— **一列价都没有** | `purchasing.view` OR `inbound.view` | `operations`、`warehouse` |

**12 个在册角色里,新读到东西的只有这两个** —— 而它们正是 Tim 裁进本刀的两个。
第三个角色一行都没有多拿到(对着线上 `role_permissions` 算的,不是估的)。

`supplies_goods` 与 `counterparty_type` 出现在 `supplier_lookup` 上,是因为两处
调用点各拿它们过滤(收货只列供货户;进料编辑排除货代)。搬到客户端做不到 ——
那会要求先把不该看的行发下去。

**形状不是本刀发明的:** `supplier_receiving_blocked` 就是一张属主权限视图,
体内挂 `module.inbound.view`,连着 `suppliers`,而 Fu Sheng **今天就读得到它** ——
它一直好好地待在这张坏掉的表单里。本刀只是把同一招用在他真正卡住的那三张表上。

### ★ 它顺带做了 GRN-1a 明说留给以后的那个决定

`db/migrations/2026-08-17-grn1a-…sql` 的抬头写着,它 2026-08-17 就量到
「warehouse 角色读 `po_receivable_lines` 得 0 行」,并且判词是:

> 「operations 与 warehouse 看不见差异,与他们今天看不见订量是同一件事。
>   这不是本刀新加的限制;**要改的话该改的是订量那道门,而那是一个单独的决定。**」

**那个单独的决定就是今天这一刀。** 但本刀只开【收货表单要的那十列】那道小门:
`grn_discrepancies` **一个字没动**,它仍然只对持 `purchasing.view` 的人有行
(fixture 100 的 C 条把这一点钉死,而且注入验证过)。那是下一刀的题目,不是顺手。

### 为什么 `po_receivable_lines` 是【新造一张】而不是放宽老的

1. **放宽老的做不到。** 它读 `purchase_orders_masked` 与
   `purchase_order_lines_masked`,而那两张伴生视图**各自体内**也写着
   `has_permission('module.purchasing.view')`。只改最外层是一次空操作。
2. **老的那一张带着价。** 单价那一列确实已按 `data.view_prices` 遮成 NULL
   (查过,不是假设),但 `pricing_formula_id` 没有遮。而两处收货调用点
   **一个价都不读**。**遮成 NULL 与根本不出现,对下一个读代码的人不是同一句话。**

## 11.4 完整的跨模块依赖普查 —— ★ 本刀只修了其中一角,其余在这里点名 ★

方法:272 个含 `.from()` 的 app 文件 × 守卫(`requireModule` / `requireEditPermission`)
× **线上** `pg_policies`(212 张表)与**线上**视图定义(98 张,其中 97 张
`security_invoker=false`,所以把关的是视图体里那句 `has_permission`)。
「跨模块」= 读所需的码落在守卫自己的模块族之外 —— 按构造排除了
EDIT_REQUIRES_VIEW 管的那一类。

**结果:63 个文件带跨模块读依赖;108 对(文件,表)至少对一个角色是空的。**

| 角色 | 受阻读点 | 其中写表单 | 人 | 判定 |
|---|---|---|---|---|
| `cfo` | 50 | — | Tim | **理论** —— 他同时持 `admin`,权限取并集,一条都不会发生 |
| **`warehouse`** | **43** | **21** | **Fu Sheng** | **真实 —— 他每天的活** |
| **`operations`** | **29** | **13** | **Phua** | **真实** |
| `procurement` | 22 | — | 无人 | 理论 |
| `sales` | 18 | — | 无人 | 理论 |
| **`finance`** | **15** | **4** | **Choo Er** | **真实,但只是空面板** |
| `hr` | 5 | — | 无人(Sandra 是 `cco`) | 理论 |
| `auditor` | 4 | — | 无人 | 理论 |
| `gm` | 2 | 2 | Vince | **裁定如此**(§82–85 那张矩阵)—— `user_directory` 要 `action.manage_permissions`,那正是没给他的。★ FIX-2a:权限不动,但屏幕改成【说出来】 |
| `cco` | 2 | **0** | Sandra | ⚠️ **【FIX-2a 更正:这一格两处都错】** ① 「刻意如此 / §71 写明不给」是一次**未经裁定的推断**(见 §11.2b);② **数也不对** —— 实测 `company_profile_masked` 对【每一个角色】都返回 **1 行**,包括 warehouse。挡住的不是行,是**五列**(`bank_*` 各自按 `data.view_banking` 遮成 NULL)。它根本不是一处跨模块读点,是一处**遮蔽列的渲染缺陷** —— 见 §13.4。**★ UI-1a 2026-09-05:那五列对 `cco` 不再遮蔽(Tim 裁定授予),所以这一格今天是 0 —— 但理由是【授权变了】,不是当初那两处错自己好了。★** |

### 本刀【没有】修的,逐条点名 —— 下一刀从这张表开始,不必重做普查

**A. 写表单上的空面板(cluster B):** 它们不挡活,只是少一块。

| 页面 | 读不到的东西 | 谁 |
|---|---|---|
| `/inbound/[id]/edit` | `po_prepayment_applicable`、`prepayment_applications_masked` | warehouse、operations |
| `/inbound/[id]/assays/new` | `purchase_order_lines`、`pricing_formulas` | warehouse、operations |
| `/inbound/[id]/edit` | `material_required_metals` | warehouse |
| `/output/[id]/edit` | `batch_margin`、`pricing_formulas_masked` | warehouse(operations 只缺后者) |
| `/operation/processing/new` | `finance_settings` | operations |
| `/inbound/[id]/edit`、`/output/[id]/edit` | `stocktakes`、`stocktake_lines` | **finance(Choo Er 的那四处)** |

**B. 只读页面(不是写表单,少的是一列名字或一块汇总):**
`/inbound`(suppliers、materials)、`/inventory`(materials、processing_runs、
processing_outputs_masked)、`/inventory/{inbound,output}/[materialId]`(materials、work_orders)、
`/logistics/containers[/[id]]`(suppliers、container_overview、shipments)、
`/logistics/forwarders[/[id]]`(suppliers、ap_open_items)、`/output`(customers、materials)、
`/finance/*` 若干、`/sales/orders/[id]` 的预留区。

**C. 不该动的:** Vince 的 `action.manage_permissions`、Sandra 的 `data.view_banking`。
~~那是两次裁定,不是两个缺口。~~

> ### ⚠️ 【FIX-2a 更正】**那是【一次裁定】加【一个从未被裁过的决定】。**
> * Vince 的 `action.manage_permissions` —— **裁定**,追得到(§82–85 的矩阵)。**FIX-2a 不动它。**
> * Sandra 的 `data.view_banking` —— **没有人裁过**。完整的传播链见 §11.2b,
>   它当时是一个**敞着的决定**,而不是一条依据。
>   **★ UI-1a(2026-09-05)裁了它:授予。见 §11.2b。★**
> 
> **两者都【不动权限】,而两者都要【把屏幕上的空说出来】** —— 那正是 FIX-2a 的标准:
> 不可接受的是沉默,不是扣下。

## 11.5 /set-password 与那一屏「什么都没发生」

**item 1 —— 它此前穿着整个应用外壳。** 模块栏还高亮着一节(界面说他进来了,
而他没有)、通知铃带着未读数、「我的档案」「我的评估」「登出」都在,
而模块栏逐条写着「销售 · 受限」——
**把这个账号缺哪些模块,告诉了一个还没完成设置的人。**
那一整条导航一个链接都点不动:中间件把每一条路由都弹回这一页。

> ### ★ 委托书里那句「用 /login 那套机制」藏着一个陷阱,而它差点被照做 ★
> `/login` 的裸壳来自 `app/layout.tsx` 的 `isPublicPath(pathname)`,
> **而中间件用的是【同一个函数】来决定"哪些路径不需要会话"。**
> 照字面复用只有一步:把 `'/set-password'` 加进 `PUBLIC_PATHS` ——
> **于是同一次改动顺手宣布了设密码页不需要会话。**
> 那不是复用,那是把一条安全判据改宽,而改宽的地方看起来只是排版。
>
> 处置:**机制照用,判据拆开。** `lib/loginRoute.ts` 现在有两个名字 ——
> `isPublicPath`(可以没有会话,只有 `/login`)与
> `isBareChromePath`(不画外壳,是前者的**超集**,代码保证,不靠人记得)。

**`/welcome` 不跟着改**(Tim 的裁定):那一页的人**已经**完成了设置 ——
密码换过了、会话是好的,他只是还没被授予任何模块。对他画一个诚实的空外壳是对的。
那些「· 受限」读起来怎么样,是 UI-1 的题目。

**裸壳上留了【一条】出口:「不是你?登出」。** 判据从这一页做得了什么推出来:
上面那行 intro 把 `user.email` 念了出来 —— **这一页主动告诉你你是谁**,
那么当那个"谁"是错的人时,它必须给得出一条出路;而中间件把每一条其他路由
都弹回这里。零个出口是本仓库撞过七次的那一族;一整条顶栏是正在修的缺陷;
**中间那一档就是这一条。** 它复用 `/logout` 那支已有的 action,没有第二条登出路径。

## 11.6 ★ item 2:重定向【一直都在】,缺的是那几秒里的任何证据 ★

委托书写着「设完密码不跳转」。**实测推翻:它跳转。**
在 `next dev` 上把两条进入路径 × 两个落点各跑了一遍,`router.push` 每一次都真的跳了。

真正的成因是旧写法把跳转放在一次 React transition 里
(`startTransition(async () => { …updateUser…; router.push(where) })`),
而 **transition 的语义就是:新界面准备好之前,旧界面原样留在屏幕上。**

实测(注入 1.2s 网络延迟,warehouse + 员工档案的测试账号):

| t | 地址栏 | 密码框 | 报错 | 按钮 |
|---|---|---|---|---|
| 415ms | `/suppliers` | 仍填着 23 字符 | 无 | disabled |
| 2512ms | `/suppliers` | 仍填着 | 无 | disabled |
| 6039ms | `/suppliers` | 仍填着 | 无 | disabled |
| 9021ms | `/me` | 空 | — | — |

> **六秒以上的空窗,屏幕上一个字都没变。** 而 `/me` 是一张读很多张表的重页面,
> 线上冷启动只会更长。Tim 看了几秒、认定没反应、又按了一次 ——
> 于是拿到 GoTrue 的「New password should be different from the old password」。
> **那句报错不是第二个缺陷,它是第一次成功的回声。**

**地址栏那一半也复现了,100%:** 中间件的强制重定向发生在一次客户端导航上,
Next 应用了新页面的 RSC 负载却**没有改 URL** —— 于是地址停在 `/purchasing`
(委托书注意到了这件事,而它不是无关的旁证,它是"看起来什么都没发生"的另一半)。

**修法:搬到 server action,结尾 `redirect()`** —— 与 `/login` 同一个形状。
`redirect()` 是传输层跳转,不在 transition 的"等新界面"语义里;它顺带纠正地址栏;
而配 `useActionState` 之后 `pending` **一直真到新页面渲染完**,所以那段空窗里
按钮写着「保存中…」、两个密码框是禁用的。

> ★ **空窗没有消失 —— 它由 `/me` 有多重决定,那不是这一刀的题目。
>   消失的是【它的无声】。** 把 `/me` 变轻是另一件事,已记进 manual-walk-list。

## 11.7 证明(全部读自脚本自己的日志)

* **fixture 100** —— 四条,两个方向:
  A 正对照(warehouse 现在叫得出:supplier 7 / material 5 / customer 3 / 那条采购单行 1,
  而 `has_permission('module.suppliers.view')` 仍然是 **false**);
  B 反对照(`hr` 与一个零权限账号,四张视图全 0);
  C **窄对照**(warehouse 读 `suppliers` / `materials` / `customers` 基表仍然是 0,
  读带价的 `po_receivable_lines` 是 0,读 `grn_discrepancies` 是 0);
  D 一致对照(对 `procurement`,新旧两张采购单行视图给出同一组 `line_id`,各 4 行,非空)。
* **注入五次,五次都红**:①去掉 `inbound.view` 那一支 → A 红;②门大开 → B 红;
  ③改用「把 suppliers.view 授给 warehouse」那条捷径 → **C 红**;
  ④漏掉 status 过滤 → D 红;⑤`grn_discrepancies` 顺手放宽 → C 红。
* **强制换密码那道闸仍然拦得住**:7 条路由(`/suppliers`、`/purchasing/orders`、
  `/inbound/new`、`/hr/employees`、`/finance/invoices`、`/me`、`/settings/accounts`)
  逐条实测被弹回设密码页;**注入验证**:把 `must_change_password` 清掉之后
  `/suppliers` 当场不再被弹 —— 那条断言是活的。
* **裸壳断言也是活的**:把根布局改回 `isPublicPath` 之后,`<header>` 与
  「受限」泄露【当场回来】。

---

# 十二 · FIX-1 的破窗:42 分 33 秒

| | |
|---|---|
| 起点(库已经是新的) | `2026-09-05 10:37:15 CST` —— `apply_migration.sh` 打印 |
| 终点(部署 state=success) | `2026-09-05 11:19:48 CST` —— 部署 id **6276572836** |
| **时长** | **0:42:33** |

## 12.1 这段时间里线上坏了什么 —— ★ 一件都没有,而这是【结构性】的,不是运气 ★

**本刀的迁移【纯增量】:四张新视图,零处改动现有对象。**
没有 ALTER、没有 DROP、没有策略改写、没有列变 NOT NULL。
窗口里跑着的旧代码读的是 `suppliers` / `materials` / `customers` /
`po_receivable_lines` —— 四个它一直在读的东西,一个字没变。
新视图对它不存在,而不存在的东西坏不了。

| 改动 | 旧代码在窗口里会怎样 |
|---|---|
| 新建 `supplier_lookup` / `material_lookup` / `customer_lookup` | **不坏** —— 旧代码零调用点 |
| 新建 `po_receivable_lines_lookup` | **不坏** —— 同上;老的 `po_receivable_lines` 一个字没动 |
| `grn_discrepancies`、三张 `_masked` 伴生视图、任何 RLS 策略 | **没碰** |

**实际受影响的人:0。** 而这一次不是"恰好没人做那个动作"(C-2 是那样),
是**没有那个动作**。

## 12.2 与前三刀对照 —— ★ 窗口第一次短过一小时,而原因是【相位】,不是速度 ★

| | C-1a | C-1b | C-2 | **FIX-1** |
|---|---|---|---|---|
| 时长 | 2h25m | 50m | 1h06m | **42m33s** |
| 做法 | 先迁移,再写全部代码 | 先写完代码,再迁移 | 先写完代码,再迁移 | **先写完代码,再迁移** |
| 迁移性质 | 改结构 | 改策略(收窄) | 改结构 + 换函数签名 | **纯增量** |

C-2 的结论是「代码先行之后,破窗时长已经由**验证套件的长度**决定,
下一刀能动的是**相位**,不是顺序」。**这一刀验证了它,而且是从另一头验证的:**
本刀的验证套件并没有变短(门 3 遍 ≈ 7.5 分、冒烟 1 遍 ≈ 7.3 分、
构建 1 遍、探针 1 遍),窗口短下来是因为**迁移本身不再是一件危险的事** ——
纯增量的 DDL 可以【尽早】落地,而它落地之后线上什么都没变,
于是"破窗"这个词在本刀里几乎只是一个计时器。

> ### ★ 真正该记下来的那条:窗口里那 7.5 分钟的门,有 5 分钟是我自己买的 ★
>
> 门跑了三遍,前两遍红,**两遍红的都不是产品代码,是我写的那支 fixture**:
>
> 1. 第一遍(`GATE_EXIT=4`):fixture 借线上数据(`SELECT … FROM suppliers LIMIT 1`),
>    而**门把 fixture 跑在从镜像重建出来的库上** —— 那里只有引导种子,
>    没有供应商、没有物料。我自己写的 `FIXTURE_SETUP_FAILED` 守卫当场点名了它,
>    这一点是对的;但那支 fixture 本来就不该借数据(README 第 2 条写着「自带数据」)。
> 2. 第二遍(`GATE_EXIT=4`):fixture 以 `RAISE EXCEPTION 'FIXTURE_REPORT …'` 结尾 ——
>    **那是 Management API 单跑时的写法**(要靠报错把报告带出来并回滚),
>    而门自己数事务前后的行数查泄漏,一支以异常结尾的 fixture 在它眼里就是失败。
>
> **两条都可以在迁移之前就知道,而且成本是【读十行】** ——
> 打开任意一支现成的 fixture 看它的结尾(`RAISE NOTICE` + `BEGIN;/ROLLBACK;`)。
> 我没有读,因为我照着一份**记忆里的约定**写,而那份约定描述的是另一个跑法。
>
> ★ **这就是 C-2 说的「能动的是相位」的一个具体样本:
>   一份写在别处的约定,不等于这道闸认的约定;而分辨这件事的办法是读代码,
>   不是回忆。** 下一刀写新 fixture 之前,先 `tail -20` 一支旧的。

## 12.3 三个退出码,全部读自脚本自己的日志

| | 值 | 出处 |
|---|---|---|
| 备份 | `BACKUP_OWN_EXIT=0` | `backup.sh` 自己的输出(TOC 5288 条,上一份 5272,下限 4744) |
| 迁移 | `MIGRATE_OWN_EXIT=0` | `apply_migration.sh` 自己的输出 |
| 门 | `GATE_EXIT=0`(第 3 遍,146s) | `gate.log` 里那一行 |
| 构建 | `BUILD_OWN_EXIT=0` | `npm run build`(19 道预检 + `next build`) |
| 冒烟 | `SMOKE_EXIT=0` | `smoke.log` 里那一行 —— 243 ok / 8 skipped / **0 FAILED** |
| 部署 | `DEPLOY_OWN_EXIT=0` | `wait-for-deploy.sh` —— id 6276572836,success |

★ **门第 1 遍与第 2 遍的 harness 通知都写着「completed (exit code 0)」,
而两遍的 `GATE_EXIT` 都是 4。** 那是 `run_detached.sh` 抬头记的同一个形状
第 6 次和第 7 次出现 —— 启动器的退出码冒充脚本的退出码。
**机制拦住了它:判词从日志里那一行读,不从通知读。**

---

# 十三 · FIX-2a(2026-09-05)· 剩下那些安静的谎话

> **FIX-1 的判词是「没有人被挡住」。Tim 推翻了它,而推翻的理由值得写在最前面:**
>
> 「那张收货表单严重的地方从来不是他不方便,是**系统说了谎**。
> Cluster B 的空面板是同一句谎话,只是更安静 —— Choo Er 打开一块盘点面板,
> 看见空的,于是认定没有盘点。她可能是错的。没有人被挡住,所以没有人报告,
> 所以它可以被一直相信下去。**那比一张填不完的表单更坏,不是更轻。**」
>
> 所以本刀的判据不是「谁被挡住了」,是:
> **有没有哪一屏,把一个空结果显示成一件关于生意的事实?**

## 13.1 普查重做了一遍 —— 而 §11.4 【不足以】当作 population

委托书写着「§11.4 已经点了名,不必重做普查」。**实测:做不到。**
§11.4 对 warehouse / operations / finance 是按名列的,而对那六个**没人持有的角色**
只有【一个数】(cfo 50、procurement 22、sales 18、hr 5、auditor 4)。
Tim 的 item 2 要求把它们一起修 —— 而**你没法按一个数去修**。
FIX-1 的普查脚本也没有进仓库。所以本刀重做了一遍。

**方法:** 199 条路由 × 传递 import 闭包 × 线上 `pg_policies`(212 表)×
线上视图体(102 张)× **12 个角色各一次模拟会话**(单事务,全部回滚)。

| | 数 |
|---|---:|
| (路由,对象)对:某个**进得去这一页**的角色读到空,而 admin 读得到行 | **142** |
| — 读它的文件**已经**在问某个权限 | 57 |
| — 读它的文件**一个权限都没问** | 85 |
| — 复核后是**假阳性** | 6 |
| **★ 本刀的真 population** | **79** |

### ★ 一条方法上的更正,它比结果更耐用

**最初的基线用的是 `postgres`,而那是错的。** 线上 102 张视图里 **97 张**是
`security_invoker=false` 且体内挂着 `has_permission`;`postgres` 没有 JWT claim,
于是**那 97 张对它一律返回 0 行** —— 一个"这张表本来就是空的"的假答案。
按 postgres 算,"真的空"是 107 个对象;按 **admin** 算是 54 个。
**基线必须是 admin。**

### 六个假阳性,逐条点名(「我没修」与「它不需要修」必须分得开)

| # | 位置 | 为什么不是缺陷 |
|---|---|---|
| ① | `/inbound/[id]/edit` × `output_batches` | **闭包假阳性**:读它的是 `metalContentActions.ts` 的 `saveOutputMetal`,而这一页只 import `saveInboundMetal` / `deleteInboundMetal` |
| ② | `/output/[id]/edit` × `inbound_batches` | 同上,方向相反 |
| ③④ | `/output/[id]/assays/[assayId]` × `assay_results` / `assay_result_metals` | **谓词按【行】分岔**(`inbound_batch_id` → inbound.view;`output_batch_id` → output.view),而线上 4 行**全部**是进料化验、产出化验 **0** 行。sales 持 output.view,它读到 0 是**真的没有产出化验**。★ 一个按行分岔的谓词,不能按角色判空。 |
| ⑤⑥ | `/hr/employees/new` 与 `/hr/employees/[id]/edit` × `user_directory` | **已经修好了**,而且修得比本刀要求的更早:两页都走 `canManagePermissions()`,读不到时**不渲染空下拉**,而是印出一句具名的话。是本刀的分类正则漏认了 `canManagePermissions(`(它只认 `can(`)。 |

## 13.2 ★ 本刀唯一的不变量 —— 它就是暴露面的全部论据

> **查名视图只改【行】谓词。每一【列】原样保留它已经背着的 `data.*` 遮蔽。**

于是**一张查名视图不可能让任何人看见一个他本来无权看见的数据类**:

* `payroll_period_lookup` 带着五个薪酬合计,而它们**仍按 `data.view_pay` 遮**——
  `finance` 与 `cfo` **本来就持有** `data.view_pay`(实测),挡住他们的从来只是
  `module.hr.view` 这道**行**门。**本刀一分钱都没有多给**,它只是不再对一个
  要去付薪的人说「这个月没有薪资期间」;
* `inbound_batch_lookup` 带着 `unit_price`,仍按 `data.view_prices` 遮;
* `processing_output_lookup` 与 `processing_cost_entry_lookup` 同理。

**所以"这张视图暴露了什么"只需要读它【没有被遮的那几列】。**
`db/fixtures/194` 的 D 臂**就是这条不变量**,而且是双向的:
没有 `view_pay` 的人读到 `NULL`,有 `view_pay` 的人读到 `4321.00` ——
少了后面那一半,前面那一半会靠「谁都读不到」通过(fixture 26 记过的真空通过)。

## 13.3 (a) 与 (b) —— 79 处,没有一处留成空白

**(a) 69 处 · (b) 10 处。** 一处不落。

**(b) 不是安慰奖。** 对 warehouse 与 operations 扣下价格与毛利**就是对的** ——
Tim 的 Q4 裁定原话「初期不给。加回来便宜,看过了就收不回」。
**不可接受的是【沉默】,不是【扣下】。**

(b) 的画法**一个新的都没有发明**,全部走 CONV-0 收敛出的那一份:
`<Refusal>`(一个**值**被扣下)· `<RefusalBlock>`(**这个地方**你进不来)。
措辞也沿用仓库已有的句式(`messages/en.ts` 那一族
「That is a permission answer, not …」)。

### 十处 (b),逐条

| 页面 | 角色 | 此前屏幕上写着 | 现在 |
|---|---|---|---|
| `/logistics/forwarders`(列表) | ops · sales · warehouse · procurement | 每一家货代都写着**「没有欠款」** | 那一格是「受限」 |
| `/logistics/forwarders/[id]` | 同上 | **「未结应付 0.00」** | 「受限」 |
| `/logistics/forwarders`(付款条件列) | 除 suppliers.view 之外 | 一根破折号 | 「受限」 |
| `/logistics/forwarders/[id]`(国别/条件) | 同上 | 字段**消失** | 「受限」 |
| `/tools/calendar` × 3 类(发票到期 / 到港预计 / 申报期结束) | hr | 点开那一类,写着**「这个月没有」** | 该类画成受限,格子换成一句拒绝 |
| `/hr/payroll`(列表) | hr | 已过账的期间,分录那一格是**破折号** | 「受限」,且**不画链接** |
| `/hr/payroll/[id]` | hr | 「分录」**整行消失** | 那一行在,值是「受限」 |
| `/inbound/[id]/assays/new` | warehouse · operations | **「该批次未设定定价公式」** | 一块具名拒绝,带权限码 |
| `/finance/company`(银行段) | 无 `data.view_banking` 者 | **五个空输入框** | 一块具名拒绝(见 §13.4) |

> ★ **`/hr/payroll` 那两条是 Tim 推翻我的地方,而他是对的。** 我提议 (a)
> (一张只有状态、没有金额的分录查名视图),理由是「那是 HR 自己单据的状态」。
> **裁定:(b)。**「过账是财务在总账里做的动作,不是 HR 做的。把状态给 HR,
> 等于让他们从一个自己不参与的流程里读出一个结论。那一格写『受限』挡不住任何人 ——
> Sandra 去问 Choo Er,而那次交接本来就该发生。」
>
> **判据因此是 `journal_entry_id` 有没有值,不是"查出来是不是空"**:
> 没有 id = 真的还没过账(诚实的破折号);有 id 而读不到 = 扣下了。

## 13.4 ★ item 3:那不是一块空面板,是五个会【清空真实数据】的空输入框

**委托书的说法要更正两处,而更正之后这一条从"文案问题"变成了"缺陷"。**

1. **Sandra 读得到 `company_profile_masked` 那一行** —— 实测**每一个角色**都读得到,
   包括 warehouse。挡住的**不是行,是五列**:`bank_name` / `bank_account_name` /
   `bank_account_no` / `bank_swift` / `bank_address` 各自按 `data.view_banking`
   遮成 `NULL`(视图体里五个 `CASE WHEN`)。
2. **屏幕上不是一块空面板** —— `CompanyProfileForm` 的
   `defaultValue={profile[name] ?? ''}` 把那五个 `NULL` 画成
   **五个空的输入框**,顶着一个「银行资料」的分组标题。
   **那比空面板更像"还没填"。**

### ★★ 而它下面还有一个真的洞:保存会把银行资料【清空】★★

`saveCompanyProfile` 无条件写**全部十五列**,`v || null` 把空串变成 `NULL`。
也就是说:一个没有 `data.view_banking` 的人,改一下公司电话再保存,
**就把公司真实的银行明细抹掉了** —— 而屏幕上什么都不会说。

**今天它打不着,而那是【运气】不是设计:**

| | 持有者(实测) |
|---|---|
| `data.view_banking` | admin · finance · gm |
| `module.finance.edit`(能保存这一页) | admin · finance · gm |

**两组恰好相同。** 而**列授权拦不住它**:实测 `authenticated` 对 `bank_*`
**有 `UPDATE` 权限**(被收回的只有 `SELECT`)。
**授一个角色 `module.finance.edit` 只要在权限屏上点几下**,而那一刻不会有
任何东西提醒任何人这件事 —— 这正是 Tim 把 item 2 写进委托书的那条理由的实例。

**Tim 的裁定:修,在本刀内。**
「你找到的;我的委托书不知道有这件事。在一张仍然会清空 `bank_*` 的表单上盖一个
(b) 标签,是一个**看起来完成了而其实没有**的修法。」

**修法(两半,缺一不可):**
* 界面:那一段渲染成 `<RefusalBlock>`,不渲染五个 input;
* 服务端:`saveCompanyProfile` 按**权限**筛出可写字段(`BANKING_FIELDS` 白名单)。
  ★ **判据是「这个人看得见这一列吗」,不是「表单交了什么上来」** ——
  表单没交,可能是看不见(不渲染),也可能是清空(渲染了但留白),
  而这两件事在 `FormData` 里**是同一个值**。不能从提交内容倒推,必须去问权限。

**FIX-2a 权限一个字节都没有动**,`data.view_banking` 既没给也没收。
**★ UI-1a(2026-09-05)给了 `cco`** —— 见 §11.2b。**上面那两半修法照旧成立**:
这一段对【任何没有这个码的角色】仍然渲染具名拒绝,写路径仍然按权限筛字段。

## 13.5 那一处【修复】,与暴露面清单分开报告(Tim 点名要求)

**`container_overview` 的体内谓词是 `module.purchasing.view`,而读它的两页
(`/logistics/containers`、`/logistics/containers/[id]`)的守卫是
`module.logistics.view`。**

于是 operations / sales / warehouse **通过了这一页的守卫**,然后从
**这一页自己的主表**读到零行:箱子列表画得出来,而每一行的发货单数、
涉及客户数、最新里程碑、待收单据数**全是空的**。

> **这不是"给谁多看了什么"。** 能开这一页的人本来就应该读得到这一页的内容。
> 加上 `logistics.view` **没有**让任何打不开这一页的人读到任何东西,
> 而 `purchasing.view` 原样留着 —— 没有人因此少读。
>
> **Tim:「分开报。它是一次修复,不是一次放宽 —— 别把它埋进暴露面清单里。」**

## 13.6 证明:per view,不是 per site(Tim 的 Q6)

本刀改了 40 个文件、79 个读点。**按读点写断言会是 85 条,而它们只是同样的
16 条被抄了五遍。** Tim:「一份读不完的证明不是证明。」

`db/fixtures/194` 因此把判据落在**暴露面**上,而暴露面住在视图里 ——
七条臂:A 正对照 · B 窄对照 · C 反对照 · **D 遮蔽对照(双向)** ·
E 修复对照 · F/F2 结构对照(问 `information_schema`,不问数据 —— 一张今天恰好
没有行的表,用数据断言不出"它不出这一列")。

**六次故障注入,六次都红:**

| # | 注入 | 变红的臂 |
|---|---|---|
| ① | 把 `logistics.view` 那一支从 `supplier_lookup` 拿掉 | A |
| ② | 走"把 `module.suppliers.view` 授给他"那条捷径 | B |
| ③ | 把 `data.view_pay` 的遮蔽从 `payroll_period_lookup` 上拿掉 | D1 |
| ④ | 把 `container_overview` 退回只认 `purchasing.view` | E |
| ⑤ | 门大开(一张查名视图 `WHERE true`) | C |
| ⑥ | 往 `supplier_lookup` 上加一列 `payment_terms` | F |

> ### ★ 第 ② 次注入第一遍是【假绿】,而它值得单独写下来
> 第一版把 `INSERT INTO role_permissions … WHERE code='fx194-log'` **前置**在
> `DO` 块之前 —— 而那个角色是 fixture **在块内**才建的。于是那条 INSERT
> 命中 **0 行**,注入什么都没改,报告 **GREEN**,读起来正好是「B 臂不咬人」。
>
> **一次什么都没改的注入,与一条不会响的检查,在屏幕上是同一样东西。**
> 这与本仓库反复付账的那一族(空集被读成"还没到"、启动器的退出码冒充脚本的)
> 是同一个形状 —— 只是这一次它出现在**验证那条检查的工具**上。
> 改法:注入改成**给 fixture 打补丁**(在角色确实存在的那一行改),
> 重跑当场变红并点名「读到了 suppliers 基表 1 行 —— 整段商务关系泄露了」。


---

# 十四 · FIX-2a 的破窗:56 分 29 秒

| | |
|---|---|
| 起点(迁移提交,`apply_migration.sh` 打印) | **2026-09-05 13:00:01 CST** |
| 中途(fu1 迁移) | 2026-09-05 13:24:18 CST |
| 终点(部署 `state=success`,`wait-for-deploy.sh` 读的) | **2026-09-05 13:56:30 CST** |
| **破窗时长** | **56 分 29 秒** |
| 部署 id | `6277736212` |
| 提交 | `e8d18ba`(HEAD == origin/main,树干净) |

## 14.1 这段时间里线上坏了什么 —— ★ 一件都没有,而这是【结构性】的 ★

窗口里生产跑的是**旧代码(`4061e92`)+ 新库**。这一刀的 DDL 分三类,
**三类都不可能弄坏旧代码**:

| 改动 | 旧代码看得见吗 | 为什么坏不了 |
|---|---|---|
| **15 张新视图** | **看不见** | 旧代码一次都没引用过它们。**不存在的东西坏不了。** |
| **5 张视图放宽/修正体内谓词**(container_overview · supplier/customer/material_lookup · processing_run_allocation_status) | 看得见 | **列一个字没动**,谓词只往【宽】改 —— 旧代码拿到的行**只多不少**,而多出来的那些正是这一刀要修的东西。没有任何读取会因此报错或少拿。 |
| **5 句 `ALTER VIEW … SET (security_invoker = off)`** | 看得见 | **零行为变化**:PostgreSQL 的默认本来就是属主权限,这一句只是把已经成立的事**声明出来**(它被 `CREATE OR REPLACE` 顺手丢掉了,见 §14.2)。 |
| **fu1 给 `processing_cost_entry_lookup` 追加两列** | **看不见** | 那张视图是本刀新建的,旧代码不认识它。 |

**与 FIX-1 那次的对照仍然成立,而理由也一样:纯增量或纯放宽的 DDL 没有"窗口风险"。**
C-2 那次是「恰好没人做那个动作」;这两次是**没有那个动作**。

## 14.2 ★ 一处实测的陷阱:`CREATE OR REPLACE VIEW` 会把 `WITH (...)` 丢掉

AGENTS.md 的「Database mirrors」一节记着这条,**而本刀还是撞了一次** ——
迁移落地后立刻复查 `reloptions`,五张被替换的视图上
`security_invoker = off` **全都不见了**。

> **说准一点:丢掉它【不会】把视图变成 invoker。** PostgreSQL 的默认就是属主权限,
> 所以**行为一字未变**,窗口里也没有任何东西因此出错。坏的是另外两件:
> ① 镜像文本对不上(`db/views/*.sql` 里写着那一句),`check_mirrors` 会为
>    一件**没有发生**的漂移报红;
> ② 下一个读镜像的人据此判断"这张视图是不是刻意声明过属主权限"。

**处置:** 立刻 `ALTER VIEW … SET (security_invoker = off)` 补回线上,
**并把同样五句写进迁移文件**,否则重建路径会再丢一次。

## 14.3 三个退出码,全部读自脚本【自己的】日志

```
BACKUP_EXIT=0    备份 4.0M / 5300 条 TOC,跑在迁移【之前】(前台等它自己那一行)
GATE4_EXIT=0     318s,三判词全绿(可重建性 / 镜像 vs 线上 / 行为断言)
BUILD5_EXIT=0    20 道检查 + next build
SMOKE2_EXIT=0    243 ok · 8 skipped(无数据)· 0 FAILED
```

> **★ 闸的第一次红是【环境】,不是缺陷,而分清这两者靠的是读日志本身:**
> `GATE3_EXIT=2` 报「仓库建不出库」,而同一份日志里写着
> **`REBUILD OK — prelude is SUFFICIENT`** —— 挂掉的是它随后**对线上做比对**
> 那一步(`SSL connection has been closed unexpectedly`)。
> 当时实测隧道 `select 1` = 0.95 / 1.99 / 2.54s(在退化)。
> 原样重跑一次:`GATE4_EXIT=0`。
> **一个退出码要配着它自己的日志读,否则"建不出库"与"网断了"长得一模一样。**
>
> **闸的第二次红是【真的】:** `GATE2_EXIT=1` 点名
> 「generated types 与线上 schema 不一致(6 行差异)」—— fu1 加了两列而
> `lib/database.types.ts` 没有重新生成。那正是 OPS-10 把类型文件也算作
> 一份镜像的理由。
