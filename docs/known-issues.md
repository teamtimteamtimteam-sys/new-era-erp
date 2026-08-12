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

## stocktakes.started_at 名字像业务事实,内容是建单时间戳(2026-08-07 记录)

**现象**:`stocktakes.started_at` 读起来像"盘点开始/进行的那一天",实际是
`timestamptz NOT NULL DEFAULT now()`,**全代码库没有任何一处写过它** —— 没有
INSERT 列清单、没有 UPDATE,应用侧只读不写。线上每一行的 `started_at` 与
`created_at` **逐微秒相等**(3/3,最大差 0.000000 秒)。它是 `created_at` 的一个
同义副本,不是盘点日。

**风险**:与 FIN-1a / FIN-28 同一族的**名不副实**——名字承诺了一个业务事实,
内容是一个技术时间戳。它已经误导过一次:FIN-32 之后有人合理地读了这个名字,
推断盘点调整的业务日应当取 `started_at::date`,并据此指出"周一盘、周二过账会记成
周二"。推断本身是对的,只是那个字段不含盘点日 —— 系统里根本没有人告诉过它周一。

**为什么现在不修**:两条路,都不属于"改个名字"这么简单。
① 若判定它就是 `created_at` 的冗余,应当**删掉**它 —— 但它已在
`/stocktakes` 列表页上显示,删列要连页面一起改;
② 若判定盘点确实需要一个**盘点日**(Phase 2 的盘点单几乎一定需要),那要加的是
一个**让人填的字段**,而不是把这个默认值改名 —— 改名只会把一个技术时间戳伪装得
更像业务事实。届时 `post_stocktake` 的 `business_date` 改读它(与注销读
`deleted_at` 同一条规矩:日期要来自记录,而记录得先存在)。

在此之前:`post_stocktake` 用 `CURRENT_DATE`(过账日)是**诚实的**,理由写在函数
体里,不是"没有更好的来源"。


---

## 【已修】化验影响预览少乘一次汇率(ASY-1,2026-08-10 修复)

留一条记录,因为它是**同一株病的第四次**,而且这一次连"预览调的是 DB 试算函数"
这层防护都没挡住。

`preview_reprice_inbound_batch` 里写着 `v_usd := round(p_new_unit_price, 4)`,
注释还留着 FIN-0 翻本位币**之前**的那句"(USD 时 fx = 1)"。而提交侧
`apply_assay_result` 是按 `'USD'` 递给 `reprice_inbound_batch` 的,USD 在
FIN-0 之后是外币,提交按定价日 `tt_sell` 折算入账。线上实测(已回滚):
同一个 10 USD/kg,**预览说新单价 10.0000、总调整 500.00,提交存 12.8000、
过账 780.00**。屏幕上"当前单价"读的还是批次里的本位币价 —— 两行并排显示,
口径根本不同。

**教训,与 FIN-12 同一条**:翻本位币留下的常量不会自己消失,而
"预览调用了数据库函数"只保证**没有第二份 TypeScript 实现**,不保证那个
数据库函数本身还是对的。真正的保险是**让预览走提交那条路的同一段算术**
(ASY-1 之后 `preview_reprice_inbound_batch` 与 `reprice_inbound_batch`
逐行同构:同一次换汇、同一份 `reprice_split`、同一批过账闸),
并且 fixture **比两个数**而不是各测各的(fixture 40 D 臂)。

## `/finance/fx` 的"当天 N 笔凭证"在【报价来源】的那些行上是假的(PROC-1c 普查发现,2026-08-12)

**这条是普查的副产品,而它比普查本来在找的东西更要紧** —— 找的是"没人读的列",
撞见的是【一个屏幕在陈述一件不成立的事】。

METAL-3(2026-08-11)给 `fx_rate_gaps` 加了第二个来源:除了【有外币过账的日子】,
还有【有报价、而报价币种不是本位币的日子】。两个来源要的价种不同(过账日要
tt_buy/tt_sell/mid 三种,报价日只要 mid),所以它同时加了 `gap_source` 列说明
**这一行是为什么要价**。

`/finance/fx` 与 `/finance/month-end` 都不读 `gap_source`。单是这一条只是"分不出
两种行",还只是缺信息。真正的问题在 `txn_count`:

| 来源 | `txn_count` 数的是 | 屏幕上的话 |
|---|---|---|
| `posting` | `count(DISTINCT l.entry_id)` —— 分录数 | 「当天 3 笔凭证」**对** |
| `quote` | `count(*)` over `metal_prices` —— **行情条数** | 「当天 3 笔凭证」**假的** |

`gapsMissing` 的文案写死是「当天 {1} 笔凭证」/ "{1} entry(ies) that day"。而 CNY
**永远不会过账**(视图头自己写着,它不可交易),所以每一条 CNY 缺口行都是纯 quote
来源:屏幕会说"当天 N 笔凭证",而那一天的凭证数是 **0**。混合行(`posting+quote`)
更糟 —— `sum(u.txn_count)` 把分录数和行情条数**加在一起**,得到一个两种东西的和。

**为什么记在这里而不是顺手改**:改法不是把 `gap_source` 加进 select 就完事 ——
要判断这一行到底该说什么(两个数分开报?按来源换文案?还是 `txn_count` 本就该
拆成两列?),而"该说什么"取决于看板上的人拿这个数做什么决定。那是一次有自己
理由的显示改动,不该混进一次别的刀里悄悄带过。

**不是"少显示了一列",是"显示了一个错的数"** —— 与 `restricted-is-not-zero`、
MAT-1 的"未分类不是非受控"同一条:一个不会响的拦截比没有拦截更坏,一个说错话的
数字比一个缺席的数字更坏,因为人以为自己看过了。
