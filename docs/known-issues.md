# Known issues — 已知、暂不修

与 known-wrong-until-cutover.md 分工:那边是【测试数据的错觉,生产重建即消失】;
这边是【结构或行为的真问题,重建也不会消失】,已知、有意暂不修。修掉一条就删一条。

## employees.user_id 没有指向 auth.users 的外键(2026-08-04 记录)

**现象**:`employees.user_id`(以及 `user_roles.user_id`)是裸 uuid,不建外键。
`employees.sql` 文件头把这写成约定:"与较新的表一致,只存 uuid"。但这个约定并不一致 ——
最老的两张表带着真外键:`suppliers.owner_id / created_by / updated_by` 和
`supplier_compliance.created_by / updated_by` 都 REFERENCES `auth.users`(线上目录核实,
2026-08-04)。所以这是新老表之间的不一致,不是平台限制。

**风险**:登录账号被删后,员工行的 `user_id` 悄悄悬空 —— 没有任何东西报错。
`current_user_employee()` 按 `user_id = auth.uid()` 解析,悬空即解析为空,后果是那个人
**看不到自己的 /me、/my-reviews**:自助侧整个消失,而 HR 侧一切如常,最难被发现的
一类断。反方向同样成立:`user_id` 填错成一个不存在的 uuid,插入照样成功。

**【修它会同时打断 db/fixtures】** 那套行为断言正是靠这个缺陷工作的:每个 fixture
自己插一条 `user_roles`(user_id 是个不存在的 uuid)来给自己授权。补上外键之后,
`db/fixtures/*.sql` 会【全部】失败 —— 改法是在 `auth.users` 里建一行临时用户。
修这条的人请一并改那里;`db/fixtures/README.md` 也反向指着本条。

**为什么现在不修**:发现于路由冒烟的测试切次,不是该切次的事。修法到时候二选一:
给 `employees.user_id`(连同 `user_roles.user_id`)补 `REFERENCES auth.users
ON DELETE SET NULL`,或在完整性探针里加一条悬空扫描。补外键要同时改表镜像
(AGENTS.md 之约)并想清楚 Supabase 对跨架构外键的备份/恢复口径 —— 这正是
当初"较新的表"放弃外键的可能原因,修之前先把这一点查实。

## 月初凌晨的服务端分录日期与期间锁(2026-08-06 记录,FIN-20 后基本消除)

**现象**:一批函数把分录日期盖成 CURRENT_DATE(冲销镜像 reverse_payment /
reverse_expense / reverse_bank_transfer、finance_journal_triggers、盘点
post_stocktake、预付冲抵 apply_prepayment、重分摊 allocate_processing_costs、
库存触发器)。服务器的"今天"若落后于业务的"今天"(FIN-20 之前的 UTC 库,每天
SG 00:00–08:00 都如此),这些分录全部记在【前一天】。最尖的一角在【月初】:
月结已把 locked_before 推到月界后,凌晨窗口里发起的冲销会拿到上月末的日期 ——
post_journal_entry 抛 PERIOD_LOCKED,操作员看到的是"冲销一笔昨天的付款被期间锁
拒绝",屏幕上没有任何东西解释为什么;若月结还没锁,则更糟:分录静默落进上一个
月,已出的月报被改写。

**处置**:FIN-20 把库时区定为 Asia/Singapore(库级 GUC,gate 的 guc 行与
fixture 15 双重钉住),窗口自此不存在 —— 服务器与业务的"今天"重合。此条留档的
理由:①谁在月初凌晨撞到过一次 PERIOD_LOCKED 的冲销,两分钟能查到这里;
②这一类(服务端盖章日期 vs 业务日期)只要将来有第二个时区/辖区就会回来,
到时的修法是显式业务日期参数,不是再改时区。真实撞过的实例(测试数据)列在
known-wrong-until-cutover.md:JE-2026-0007 / 0036 / 0038。

## ~~产出批喂回再加工:schema 上不可表示~~(2026-08-06 记录,同日由 FIN-25 清账)

【划掉】FIN-25 建了它:processing_inputs 双亲 XOR、成本第四处置(被下游耗掉 →
5000 停车,经过期旗逐级传导)、回收率两路投入、血缘视图 batch_lineage。
本条当初的警告 ——【拆分扩展必须与模型改动同落】—— 已照做(同一迁移)。
留此划掉行,免得有人再来找这个"缺口"。

## reprice 在进料粒度分不出"注销"与"耗用"(2026-08-06 记录,较小的不精确)

**现状**:`reprice_split` 只有两桶 —— 在库(→1200)与其余(→5000)。进料批被
【注销】的份额与被【加工耗用】的份额同进 5000;按 FIN-24 对产出批的裁定
(注销→5200,运营信号不并进材料成本),进料侧的注销份额本应进 5200。

**为什么不在 FIN-24 修**:进料批的注销份额要从 inventory_movements 反推,而存量
数据里 writeoff 早于移动台账;错的方向只是 5000 与 5200 之间的科目串位,金额与
损益均不受影响。Tim 裁定单独记账、另日修。

## ~~已分摊的加工单还能增删改成本条目,且没有分摊检查~~(2026-08-07 复核,已不成立)

【划掉】这条在 FIN-24 / FIN-25 之前成立,现在【不需要任何分摊检查】——
"允许改、会标过期、重跑是对的"这三件合起来就是答案:

* 增 / 改 / 删三条路都由 `costActions.ts` 的 `runEditable` 挡在
  `status='committed'` 且未软删;
* 三条路都让 `processing_run_allocation_status.is_stale` 变 true ——
  该视图取 `GREATEST(created_at, updated_at)`,而删除是软删(UPDATE deleted_at),
  `update_updated_at` 把 `updated_at` 顶上去。**它刻意不过滤 `deleted_at`,正是为此**;
* 重跑是差额法(FIN-24),**负差额一样正确**。实测(回滚型探针):
  首挂 600(材料 100 + 电 300 + 人工 200)→ 软删电费 → `is_stale` 转 true →
  重跑得 300,`1220` 恰好动 **−300**,`1200` 不动(材料份额未被牵动),
  `5110` 相对基线净额回 0(录入 +300 与软删冲销 −300 相抵),重跑后 `is_stale` 转 false。

复核时【剩下的那一件】已由 FIN-31 补上:硬删(`DELETE` 而非软删)不产生冲销分录、
不留历史行,还会把该行的时间戳从 `last_cost_change` 里拿走 —— 分摊于是可能不升反降地
显示"不过期"。它此前只是被 `processing_cost_entry_history` 的外键**顺带**挡住,
而那只覆盖有历史行的条目(线上 5 条里 3 条建于 FIN-8 之前,当时真的删得掉),
且那个外键一旦被改成 `ON DELETE CASCADE` 就会连同历史行一起无声失效。
现在是一条明写的守卫(`COST_ENTRY_HARD_DELETE`),fixture 18 第 I 臂钉住。

【留此划掉行的理由】这条在仓库里**从来没有被记录过** —— 不在本文件,不在任何
代码注释,git 历史里也没有。它靠在会话之间口头传递,于是被重新提起了不止一次。
写在这里,是为了让"已经查过、结论是什么、证据是什么"有个落点。

