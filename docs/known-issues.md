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

**为什么现在不修**:发现于路由冒烟的测试切次,不是该切次的事。修法到时候二选一:
给 `employees.user_id`(连同 `user_roles.user_id`)补 `REFERENCES auth.users
ON DELETE SET NULL`,或在完整性探针里加一条悬空扫描。补外键要同时改表镜像
(AGENTS.md 之约)并想清楚 Supabase 对跨架构外键的备份/恢复口径 —— 这正是
当初"较新的表"放弃外键的可能原因,修之前先把这一点查实。
