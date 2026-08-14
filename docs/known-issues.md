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

## 服务端刷新令牌轮换会吊销会话,而【只有写入路径看得见】(SESSION-1 诊断 2026-08-12;SESSION-1b 部分缓解 2026-08-12,**仍未修复,观察中**)

> **状态(2026-08-12,SESSION-1b)**:**没有关闭,只加了一半。**
> * ✅ **已加"可闻性"**:`lib/supabase/server.ts` 的 `catch` 里,如果吞掉的那次写入
>   是一次【会话清除】,现在会 `console.warn` 出来。普通的 cookie 回写失败照旧安静。
> * ❌ **"让中间件成为唯一刷新者"这条待办作废了 —— 实测无效。**
>   给客户端加 `auth: { autoRefreshToken: false, persistSession: false }` 【不改变任何事】:
>   那次刷新是按过期时间【按需】发的,而这个开关关的是**后台定时刷新**,
>   请求级客户端根本活不到定时器响。逐项量过(把中间件拿开、数 `/auth/v1/token` 调用):
>   未过期 0/0、已过期 **1/1**(默认 vs 关掉开关),显式 Authorization 头同样是 1。
>   所以**没有加这个开关** —— 加上去只会留一句"修好了"的错觉,而错觉比缺口贵。
> * **并发刷新那一类因此仍然存在**,线上触发条件仍未证实。下一步只剩配置层
>   (`security_refresh_token_reuse_interval`、或关掉轮换),那是安全取舍,归 Tim 决定。

**症状**:在真实浏览器里提交表单,本地化错误正常渲染,**同一次响应把会话 cookie 清掉**
(`set-cookie: sb-…-auth-token=; Max-Age=0`),下一次导航跳 `/login`。

**结论(两句)**:会话不是被表单弄丢的 —— 线上审计日志显示,Tim 的令牌族在
**09:51:49Z 由一次服务端 `/token` 刷新调用吊销**(`token_revoked`,`grant_type=refresh_token`,
`remote_addr` 是 Vercel 的服务器 IP,不是他的浏览器),而他 09:54:22Z 才建成那个库位 ——
访问令牌本身还没过期,所以他继续用得好好的。**写入路径不是病因,是病灶第一次显形的地方**:
`lib/supabase/server.ts` 的 `setAll` 在 Server Component 里写 cookie 会抛异常并被
`catch {}` 吞掉,在 Server Action / Route Handler 里【写得成】—— 于是"刷新失败 → 清除会话"
这个动作在所有 GET 上是隐形的,在第一次 POST 上才落到响应里。

### 证据(全部实测,非推断)

| 查过的 | 结果 |
|---|---|
| 中间件是不是凶手 | **不是**。动作那一次请求里 `getUser -> user=<id> err=none`,而且**一次 `setAll` 都没调** |
| 谁发出的清除 | 服务端 Supabase 客户端的 `_removeSession`(在 `setAll` 处抓的调用栈) |
| 真表单路径 | **干净**。新鲜令牌 / 访问令牌已过期(中间件与动作双双刷新)两种情形下:重号提交都是 **200 + 正确的中文/英文错误句**,会话存活,全程无 `Max-Age=0` |
| 并发刷新(2 路) | 两路都刷新成功,无吊销 |
| 延迟重放旧刷新令牌(+15s/+30s/+60s) | 三次都成功,无吊销 —— **本地复现不出那次吊销** |
| 线上审计日志 | `token_revoked` / `actor_id 321f1819…` / `path=/token` / 09:51:49Z / Vercel 服务器 IP |
| 项目配置 | `jwt_exp=3600`、`refresh_token_rotation_enabled=true`、`security_refresh_token_reuse_interval=10` |
| 并发量 | 单个用户浏览时,认证服务器每秒最多 **6 次**调用,30 秒内 65 次 —— 每一次中间件都建一个新客户端,彼此没有共享锁 |

**尚未证实的那一环**:是什么触发了 09:51:49 的吊销。最合理的解释是
【访问令牌到期 + 一阵并发的服务端请求各自拿同一把刷新令牌去刷新】,超出 10 秒重用窗口
之后被判为重放 —— 但**本地两路并发与延迟重放都没能复现**,所以这一句是推论,不是结论。

**为什么现在才炸**:三件事要同时成立 ——(a) 访问令牌正好到刷新点、(b) 一阵并发请求、
(c) 之后有一次**写入**让清除显形。三者错开时,同一个缺陷完全不可见,所以它自
2026-06-11/06-24 那两次提交以来一直潜伏(`git log` 确认这些文件此后一个字没改),
而不是 LOC-1 带来的。

**爆炸半径**:任何模块的任何 server action,不限于库位、不限于错误路径 —— 成功提交
同样会显形。

### 【未修,且刻意不顺手修】

修法要动"谁负责刷新、怎么串行化",那是 auth 管道的结构改动,不是一处小补丁;
而在【复现不出吊销本身】之前动它,等于对着一个没被证实的因果关系改代码。
候选方向(按优先级,均未实施):

1. **只让中间件刷新**:server client 传 `auth: { autoRefreshToken: false }`,页面与动作
   一律用中间件刚刷新好的那份会话。最小、最贴合 SSR 模型。
2. **`setAll` 的吞异常改成有声**:Server Component 里写不了 cookie 是预期的,但
   【把"会话被清除"这件事也一起吞掉】不是 —— 至少要记一条日志,否则下一次同样查不动。
3. 调大 `security_refresh_token_reuse_interval`,或评估关掉轮换(是配置不是代码,
   但要先想清楚安全取舍)。

### 手工复现步骤(没有 fixture 能钉住它 —— 没有 JS 运行器)

**任何动到 `lib/supabase/middleware.ts` / `lib/supabase/server.ts` / `proxy.ts` 的改动之后,
按这个走一遍:**

1. `npx next dev -p 3210`,浏览器登录。
2. 打开 `/inventory/locations/new`,用一个已存在的库位号提交(触发具名重号拒绝)。
3. 断言两件事**同时**成立:① 红条显示那句本地化的重号提示;② **会话还在** ——
   刷新页面不跳 `/login`,响应里没有 `Max-Age=0`。
4. 再做一次**成功**提交,以及任意另一个模块的一次表单提交,确认第 3 步不是只对这一张表单成立。
5. 想连"令牌到期"一起试:把 cookie 里存的 `expires_at` 改到过去(不动 token 本身),
   再走一遍第 2–4 步 —— 那模拟的是一个放了一小时的标签页。

> **写这条时踩到的坑,记下来免得下一个人重踩**:用脚本驱动 server action 时,
> 【不要全页正则抓第一个 `$ACTION_ID_`】。外壳 `TopNav` 里的**退出登录**表单是页面上
> 第一张表单,抓第一个 action id 会把"提交这张表"变成"**退出登录**" ——
> 那会伪造出一模一样的 `Max-Age=0` + 跳 `/login`,把人引向完全错误的方向
> (本次就先误诊了一轮)。要按 `<form>` 元素定位到目标表单再取它自己的隐藏字段。

## `inbound_batches.status` / `output_batches.status`:没人写、没约束、却在界面上(STK-1 记,2026-08-12,未修)

两张批次表各有一列 `status text NOT NULL DEFAULT 'draft'`:

* **没有 CHECK** —— 取值不受任何约束;
* **全库没有任何写入者** —— 逐条查过 `db/functions/` 里每一处
  `UPDATE inbound_batches` / `UPDATE output_batches`,以及每一处 `SET status =`;
  唯一靠近批次表的 `status = 'reversed'` 是 `rollback_processing_run` 写在
  **processing_runs** 上的,不是批次;应用侧的 action 也一律不传它;
* **线上 16 / 17 行一律是 `'draft'`**;
* **然而它在屏幕上** —— `app/inbound/page.tsx` 的列表渲染 `{b.status}`,
  CSV 导出也带着它。

于是它是一个**永远显示 "draft" 的列**,而读的人无从知道那是"这批货还是草稿"
还是"这一列根本没人维护"。这正是这个仓库反复付账的那种形状:一个看起来在
表达什么、实际什么也没表达的字段,比没有这个字段更坏。

**STK-1 为什么绕开它而不是接管它**:库存状态(可用/暂扣)与这一列毫无关系,
但**名字已经被占了**。在同一批表上让 `status` 同时表示两件事,是下一个人必然
读错的设计 —— 所以新列叫 `stock_status`,而这两列**一个字都没碰**。

**退役它是一次独立的小刀**,而且不是"删掉就行":要先决定
(a) 界面那两处显示怎么办(直接去掉,还是换成真正有意义的 `stage` / `state`),
(b) CSV 导出的列要不要保留(有人可能已经在下游按列位取数),
(c) 删列还是留列加注释。三个都是判断,不该混在一次别的刀里顺手做掉。

## 收货库位【录不进去】—— ctx 机制到不了 PostgREST 的插入(IOD-1 报告,2026-08-12,未做)

IOD-1 的设计里,三个建批次的表单应当把一个【可选库位】经既有的 ctx 机制
传给收货触发器。**做不到,而原因是结构性的,不是写法问题。**

那个"既有机制"是 `commit_processing_run` 在用的
`set_config('evoltrya.movement_ctx', …, true)` + 触发器 `current_setting(…)`。
它成立的前提是**设置与插入在同一个数据库会话、同一个事务里** —— 而
commit_processing_run 整个就是一个数据库函数,所以天然满足。

三个建批次的地方不是数据库函数,是 app 里的 PostgREST 插入
(`supabase.from('inbound_batches').insert(...)`)。它们:

* 每一次调用都是一个【独立的 HTTP 请求】,因而是独立的会话与事务 ——
  `is_local => true` 的 GUC 在上一个请求结束时就没了;
* 而且 `set_config` 根本不在可调用的范围里:它住在 `pg_catalog`,PostgREST
  只暴露 `public`。实测:`POST /rest/v1/rpc/set_config` → `404 PGRST202`。

**所以 IOD-1 只落地了触发器那一侧**:`emit_batch_receipt_movement` 会读
`evoltrya.location_ctx`,不为空就把库位写进收货流水。今天没有任何调用方设置它,
所以每一次收货仍然落在【未指定库位】—— 那是一个合法状态(转移随时可以指定),
但**表单上没有库位这一栏**,与 IOD-1 的意图不符。

### 要做成,需要先决定用哪条路(三条,都不是小改)

1. **把三个插入改成数据库函数**(`receive_inbound_batch(...)` 之类):库位成为
   函数参数,函数内部 set_config 再插入,一个事务。最贴合既有机制,但等于
   给三条创建路径各写一个 RPC,并把三处表单改成调它 —— 是一次独立的刀。
2. **批次表加一列 `location_id`**,触发器读 `NEW.location_id`。最省事,但它与
   STK-1 定下的形状冲突:一个批次可以同时散在几个库位,批次上放一个库位
   会立刻自相矛盾(而且那一列在第一次转移之后就是错的)。
3. **收货后自动补一次转移**:插入照旧落 NULL 桶,紧接着调
   `create_stock_transfer` 把它搬到选中的库位。今天就能做,不动 schema ——
   代价是台账上每一次带库位的收货都会多出一对转移行,而那两行记录的是
   "系统替你做的一次搬运",不是真的搬过。要不要接受这个代价是 Tim 的判断。

**在选定之前,`evoltrya.location_ctx` 这条读取路径是【暂时无人调用】的** ——
留着是因为路线 1 一旦选中它就直接可用;记在这里,免得下一个人以为它坏了。

## `sales_records.movement_id` 只记一次销售的【第一条】流水腿(IOD-1 记,2026-08-13,未修)

IOD-1 之后,一次销售会按库位桶【逐桶写一行】流水(drain_stock)。而
`sales_records.movement_id` 是一个单值外键 —— 一次销售现在可能对应 2、3 行,
那一列只存得下第一行。

**今天为什么不痛**:线上所有流水的库位都是 NULL(库位这个轴 LOC-1 才落地),
所以每一次销售都只跨一个桶、只写一行,`movement_id` 与它一一对应。
**第一次有人把一批货分放两个库位再整批卖掉,这一列就开始只讲一半的故事。**

**它今天被谁读**:没有生产代码按 `movement_id` 反查流水(销售页读的是
sales_records 自己)。所以这是一处【将来会误导人】的字段,不是一处正在出错的字段 ——
记在这里,而不是等某天有人拿它做对账、发现数量对不上再回头查。

**修法是一张腿表,而那是它自己的一刀**:`sales_record_movements(sale_id,
movement_id)`,一次销售 N 行。要一并决定的两件事:
(a) 既有行怎么办 —— 回填成"一条腿"是可证明的(今天确实只有一行),
    与 PROC-1 回填产出侧出处同一种情形,可以回填;
(b) `movement_id` 那一列是删掉还是留成"主腿"。删列要连 sales_records 的
    镜像与类型一起动,留着则要写清楚它不是全集 —— 两者都不该顺手决定。

**为什么不能只写在函数体里**:那句理由现在躺在 `record_output_sale` 的注释里,
而会撞上它的人是【读 sales_records 的人】,不是读那个函数的人。写在这里,
是让它出现在会去找它的那条路上。

## 盘点看不见【桶】:差异一律落在 available,而 state 不重算(SO-2 记,2026-08-14,未修)

**两条,同一处代码,分开写是因为修法不同。**

`post_stocktake` 对每一条有差异的盘点行做两件事:

```sql
INSERT INTO inventory_movements (..., movement_type, qty_delta, ...)   -- 【不给 stock_status】
VALUES (..., 'adjustment', v_delta, ...);
UPDATE output_batches SET remaining_qty = v_line.counted_qty ...       -- 【不重算 state】
```

**① 差异一律落进 `available` 桶** —— 因为那一行不写 `stock_status`,吃的是列默认值。
盘点数的是**物理总量**(`remaining_qty`),而库存现在分三个桶:可用 / 暂扣 / 已承诺。
于是一次盘亏会把整个差异从可用里扣掉,哪怕短少的其实是被扣住或已许出去的那部分。
盘亏够大时,`check_no_negative_bucket` 会在提交时拒掉整张盘点单,报的是
`STK_NEGATIVE_BUCKET` —— **一条正确但读不懂的拒绝**:盘点的人没做错任何事。

**这不是 SO-2 引进的**:`on_hold` 从 STK-1 起就有同样的问题。但暂扣是罕见且刻意的
动作,而预留是日常动作,所以它从一个理论缺陷变成了一件会发生的事。**记在这里而不是
顺手修掉**,是因为正确的答案是一个**业务判断**,不是一次实现选择:

* 盘点点的是物理总量,还是"我能看见的可用货"?
* 差异该落在哪个桶?按现有三桶的比例摊?全落 available(今天的行为)?还是让盘点
  的人**逐桶点数**(那意味着 `stocktake_lines` 要多一根状态轴)?

三个答案对操作流程的要求完全不同。在预留这一刀里替人选一个,正是这个仓库反复付账的
那种事。**修法草案**:`stocktake_lines` 加 `stock_status`(默认 `available`),点数按桶;
过渡期内,盘亏超过 available 时按名拒绝并**说清楚是哪个桶挡住的**(而不是抛
`STK_NEGATIVE_BUCKET`)。

**② `state` 不重算。** `record_output_sale` 是 `output_batches.state` 的**唯一** UPDATE
写入者(它按 `remaining_qty` 归零与否写「已售罄」/「部分售出」)。`post_stocktake` 把
`remaining_qty` 直接设成盘点数却不碰 `state`,于是**一批被盘成 0 的货仍然显示「部分售出」**,
而一批盘盈回来的「已售罄」批次也不会变回去。今天线上没有已过账的差异行,所以还没有
人看见过。修法是把那个 CASE 抽成一个函数,两个写入者共用 —— 但**不要在这一刀里加第二个
state 写入者**:SO-2 的一条明确决定就是预留不碰 `state`,而"谁写这一列"必须保持
只有一处可数。

## 建单的 `created` 留痕【写不进去】,而错误被丢掉了(SO-2 普查发现,2026-08-14,未修)

`app/sales/orders/actions.ts` 的 `createSalesOrder` 最后一步是:

```ts
await supabase.from('sales_order_history').insert({ sales_order_id: orderId, change_type: 'created', ... })
```

**`sales_order_history` 没有面向客户端的 INSERT 策略**(SO-1 有意为之:留痕的唯一
写入口是属主权限的函数),所以这一句被 RLS 拒。而它的返回值**没有被检查**,于是拒绝
无声无息。线上核对过:`SO-2026-0001` 的历史里只有 `confirmed` 与 `issued` 两行,
**没有 `created`** —— 那张单是怎么来的,历史里查不到。

**为什么记在这里而不是顺手修掉**:正确的修法是把这一句搬进数据库(建单也走一个
DEFINER 函数,或者给 `set_sales_order_status` 那一族添一个 `record_sales_order_created`),
而那是 SO-1 的形状问题,不是预留这一刀的。**但它是 AGENTS.md 那条"失败不是空集"的
教科书案例**:`check-error-swallowing` 抓的是 `data ?? []` 那一族,一个**从头到尾没有
解构 error 的 `await`** 它看不见 —— 那正是该文件自己写明的盲区。

