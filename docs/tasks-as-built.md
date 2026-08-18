# 任务模块:动工之前的实况(TASK-0,2026-08-18)

READ-ONLY 勘察。这份文件记的是【动手之前它是什么样】,以及几处只有量过才知道的事。
设计决定不在这里 —— 它们在 TASK-1a/1b/1c 的迁移抬头与表注释里。

## 一句话

**一张表、零个函数、零个视图、零支迁移。** 所有写入都是 app 直接打 PostgREST,
没有任何 RPC。860 行前端,一块看板,一个弹窗,**没有详情页**。

## 结构

| | 实况 |
|---|---|
| 表 | `db/tables/tasks.sql` 一张。`db/functions/`、`db/views/`、`db/migrations/` 里【一个都没有】 |
| 写入路径 | `app/tasks/actions.ts` 直接 PostgREST insert/update;没有数据库函数 |
| RLS | 四条策略全是 `has_permission('module.tasks.view'/'edit')` |
| 计划形状 | `due_date`、`reminder_at`、`priority`、`tags` 已有。**没有**父子、没有排序列、没有步骤 |
| 屏幕 | `app/tasks/page.tsx` + `TaskBoard.tsx` + `TaskModal.tsx`。**没有 `[id]` 路由** |
| 接缝 | 只有一处:`lib/modules.ts:116` 的导航项。app/ 与 lib/ 里再无别处提到 tasks |
| 掩码 | `tasks` 没有列级 SELECT 授权,也没有 `_masked` 伴生视图 —— 所以 `colgrant` / `colreader` 对它无话可说 |

## 【缺陷】所有权是一句空话,而列名承诺了它

`owner_id` / `visibility` / `shared_with` / `editors` 四列都带着自己的
`COMMENT`,写着「Reserved … NOT enforced until the user system exists」。
它们说的是实话 —— 但**屏幕上没有任何东西说这句话**。

实际后果,按名说清楚:

> **任何持 `module.tasks.edit` 的人,可以读、可以改、可以删【别人的私人任务】。**
> `role_permissions.sql` 把这条权限发给了**八个角色**。

`task_type ∈ ('personal','team')` 存在,但**系统里没有任何一处按它判权限**;
它只驱动看板上的一个徽章和弹窗里的一个下拉。
「team」也不记录参与者 —— 只有一个 `assigned_to uuid`,而且**没有外键**。

**判词按 AGENTS.md 的规矩说:这是缺陷,不是「访问按模块权限」。**
一个叫 `private` 的值、一个叫 `owner_id` 的列,如果不管事,那它们不是占位符,
是**误导**:读代码的人会以为它管事。

## 留痕:今天一条都没有

任务的任何修改都不留记录。`updated_at` / `updated_by` 会动,但那只回答
「最后一次是谁碰的」,不回答「改了什么、从什么改成什么」。

仓库里已有的两种历史形状,供比较:

* `sales_order_history` / `purchase_order_history` —— 每个可改字段一对
  `old_*/new_*` 列(采购单 11 对),`*_line_id` **故意不加外键**
  (「删行时这个 id 已经不存在」),`change_type` 的 CHECK,`amend_reason`,
  `changed_at`/`changed_by`。行大多是 NULL,这是有意的取舍;
  `sales_order_history` 的注释写明为什么不是 jsonb、不是一句人话:
  **「机器读得懂的历史才查得了、比得了」**。
* `approval_log` —— 多态:`subject_type` + `subject_id`(无外键)+ `subject_code`,
  `decision`、`actor_user_id`、`note`。

## 【接缝】通知说的是账号,任务将要说的是员工

`notification_reads` 的策略是 `user_id = auth.uid()` —— **账号空间**。
`approval_log.actor_user_id` 同样是账号空间。

而 TASK-1 起,任务这一侧的一切(`owner_id`、参与者、`changed_by`)都说
**员工空间**(`employees.id`),`auth.uid()` 只在谓词内部的那一次 join 上出现。
理由:`employees.user_id` 可空 —— **不是每个员工都有登录账号**,而正在招的
五名车间技工大多不会有。指向账号会让他们在关于自己机器的任务上永远无法被点名。

> **这道缝今天没有任何东西跨过去,所以现在什么都不用做。**
> 但当第一个「任务变更发一条通知」的需求到来时,**要把这次跨越明说出来**
> —— 哪一边转成哪一边、转不过去的时候(员工没有账号)怎么办 ——
> 而不是假设两边说的是同一种 uuid。它们长得一模一样,这正是危险的地方
> (与 `employees.user_id` 那条外键要解决的问题同形:一个指向空气的 uuid
> 与「这个人没有账号」在屏幕上一模一样)。

## 线上有多少数据(实测,2026-08-18,REST,只读 SELECT)

```
rows: 6   (live 5, soft-deleted 1)
task_type: personal 3 / team 3
status:    todo 3 / in_progress 2 / done 1
owner_id 有值: 6 行里 2 行(1 个不同的 owner)
assigned_to: 0    shared_with: 0    editors: 0    entity: 0    visibility: 全部 private
created:   2026-06-26 17:00 → 17:52(同一次播种,52 分钟之内)
```

三件事因此是**量出来的**,不是推断的:

1. **那几列不但没人读,而且是空的。** `assigned_to` / `shared_with` / `editors` /
   `entity` 一行都没有用过 —— 退役它们没有任何数据要迁。
2. **`/tasks/[id]` 不需要播种,也不需要进 `EXPECTED_SKIPS`。** 有 5 行活数据。
3. **冒烟的 `ID_SOURCES` 必须挑 `task_type=eq.team` 的行。** 冒烟是以 admin 登录的;
   等 TASK-1c 之后,私人任务属于别人,而 admin 不持 `module.tasks.view_all`,
   那一页会**正当地**拒绝。从六行里随机挑,会得到一个**时好时坏**的冒烟 ——
   比一直红更坏。

**全部是测试数据。** 系统从未上线;割接时业务表清空重录。所以 TASK-1c 不写
数据迁移 —— 见那支迁移的抬头。

## 顺带量到的一个数

那次 REST 请求(冷,含 TLS 握手)**7285 ms**。与 `docs/known-issues.md` 里
SMOKE-CONN-1 记的 4861 ms 同一量级、同一形状(握手贵、复用便宜)。
**它不判断任何事** —— 这次勘察不跑冒烟、不跑闸,记在这里只是又一次取样。
