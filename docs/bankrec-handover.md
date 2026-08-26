# BANK-REC 交接(2026-08-26,**未完成的一刀**)

> **这一刀停在半路,是因为要关机,不是因为撞了墙。** 下面写的是:落了什么、
> 欠什么、哪些臂存在哪些不存在、下一次开工第一件事跑什么,以及**线上有哪些状态
> 会被一个新会话读错**。

## 0 · 一句话:下一次开工的第一个动作

```bash
./db/apply_migration.sh db/migrations/2026-08-26-bankrec-fu1-the-criterion-lives-where-the-next-query-gets-written.sql
```

**先做这个,别先跑 gate。** 理由见 §3 第 1 条:仓库里
`db/functions/journal_activity_lines.sql` 已经改了,线上那份还没改 ——
**现在跑 gate,镜像判词必然红,而那个红是【预期中的】,不是新问题。**

## 1 · 迁移【已经进了线上】—— 这一条要先读

`db/migrations/2026-08-26-bankrec-balance-agreement-and-the-explained-difference.sql`
**已于 2026-08-26 13:32:44 原子地应用到线上**(单连接、单事务、
`✓ committed atomically`)。破窗起点已落在 `db/migration-windows.tsv`。

**而应用代码【没有提交、没有部署】。所以此刻线上是:新库 + 旧应用。**

**这是不是有害的?按结构说,不按安慰说 —— 分三类:**

* **纯新增的部分(无害)**:两张新表(`bank_reconciliations`、
  `bank_reconciliation_variance_items`,**都是空的**)、三个新函数
  (`bank_book_balance_asof`、`preview_reconcile_statement`)、一个新视图
  (`bank_reconciliation_record`)。旧应用一处都不调它们,看不见它们。
* **修好了一个错数字(只会变对)**:`bank_reconciliation_status.ledger_balance`
  改读 `bank_book_balance_asof`。**列的形状没变**,旧应用照读不误。
  **实测影响:账户 `1010` 的现金余额今天从 −31,338.70 变成 −29,753.70** ——
  差 USD 1,585.00。**那不是新数据,那是 BANK-REC 修掉的缺陷**(见 `AGENTS.md`
  「Filtering journal entries to `status='posted'`」一节)。看到这个数变了不要惊慌。
* **真正变了行为的一处(需要知道,但当前打不到人)**:
  `reconcile_statement` 现在多一道余额一致的拒绝(`BALANCE_DISAGREES`),
  而**旧应用没有录入差额说明的界面** —— 也就是说,在部署之前,
  一张银行与账面对不上的报表会被拒,且人在旧界面上【没有出路】。
  这正是这一刀本来要消灭的那个形状(有闸无门)。

  > **但它当前打不到任何人,而这是量过的、不是猜的:**
  > 线上 `bank_statements` 一共 **1 张,状态已是 reconciled,open 的有 0 张**。
  > **没有任何一张报表处于可以被对账的状态**,所以那道新拒绝够不着任何人。
  > `bank_reconciliations` 有 **0 行**。
  >
  > 另外,旧签名的单参数调用**仍然解析得到新函数**(迁移里先 DROP 旧签名、
  > 新参数带 DEFAULT)。线上实测过:旧调用拿到的是
  > `BALANCE_DISAGREES|…` **一句话**,不是 "function does not exist"。
  > 只是旧的 `bankErrorCodes.ts` 不认得这个码,会把原始串直接显示出来 —— 难看,不危险。

**结论:不推送是当前的正确选择**(理由见 §2),而不推送的敞口是 **0 张可对账的报表**。

## 2 · 为什么提交了却【没有推送】

`npm run build` **这一整个会话从来没有跑过**,路由冒烟也没跑过。推送会触发 Vercel
部署,也就是把**没有验证过构建的应用代码**推上生产。而不推送的代价,上面已经量过,
是零。**两边一比,不推送。**

(四个不进构建也能单独跑的检查**都是绿的**:`check-i18n`、
`check-bilingual-concat`、`check-currency-literals`、`check-error-swallowing`。
绿的是这四个,**不是构建**。)

## 3 · 欠着的,按下一次该做的顺序

1. **应用 FU1 迁移**(见 §0)。`db/functions/journal_activity_lines.sql` 在仓库里
   已经加了「求和 vs 判活」那段判据,而**函数体里的注释就是函数体的一部分** ——
   线上没改,`check_mirrors` 就会报漂移。FU1 只改注释,**一个字节的逻辑都没动**。
2. **重跑 gate**(`db/run_detached.sh --log … --label … --timeout 1800 --token GATE
   -- python3 db/gate.py`,判词只认日志里 `^GATE_EXIT=` 那一行)。
   上一次的结果是 **`GATE_EXIT=1`**,三个判词分别是:
   * 判词【可重建性】**✓**(仓库能从零建出库,B1/B2 双侧断言通过);
   * 判词【镜像 vs 线上】**✗** —— 两个原因,都已处理或已知:
     (a) `guard_bank_reconciliation_immutable` 漂移,起因是**表镜像里漏抄了一行注释**
         (`-- 除这两列外任何列变更 → 拒绝`)。**已补回,但没有重新验证过。**
     (b) `lib/database.types.ts` 与线上 schema 不一致(174 行)—— **还没重新生成**,见第 3 条。
   * 判词【行为断言】**✗ 1 个 fixture 失败** —— 见 §4,**已修,未重验**。
3. **重新生成类型**:
   `supabase gen types typescript --project-id wvywpohbwkiinmipmuku > lib/database.types.ts`
4. **`npm run build`** —— 从未跑过。
5. **路由冒烟**:`node scripts/smoke-routes.mjs`,判词只认脚本自己打出来的那一行。
6. **划掉队列条目** `docs/forward-queue.md` 阶段 4 的「银行对账记录」—— **还没划。**
7. 提交 + 推送 + 确认 Vercel `state=success`,并把**破窗时长**写进切次报告
   (起点 `2026-08-26T13:32:44+0800`,已在 `db/migration-windows.tsv`)。

**`--reach` 判为不需要,并说明理由:** 本刀**没有新增页面**、没有动导航、模块清单
与任何 guard。改的是两个**已经可达**的页面(报表详情、对账工作台)的内容。
`--reach` 实测 2 小时以上,不为一次内容改动付这个价。
(「每月记录」刻意**不做成新页面**:报表列表本来就是按月的,而这个仓库
**已经上线过两次够不着的页面**。)

## 4 · fixture:哪些臂【存在】,哪些【不存在】

两份都是新写的,**跑在重建库上**(README:自带数据、不借业务数据)。

**`131-a-statement-cannot-be-reconciled-while-the-bank-and-the-books-disagree.sql`**
上一次 gate **✗ 失败**,原因是 **A 臂的断言写成了字符串比对**,而 numeric 的标度
让同一个数印成 `5000` 或 `5000.00`。**规则本身没问题 —— 拒绝确实按名抛出了**,
是断言在断言一个会漂的东西。**已改成按【数值】断言(`split_part(...)::numeric`),
但没有重新跑过。**

| 臂 | 断的是什么 | 注入方向 |
|---|---|---|
| A | 行全部处理完、余额仍不等 → `BALANCE_DISAGREES`,且带上两个数字与差额 | 注入一笔"银行有、账上没有"的 120,**先 ignore 掉**,并**先断言未处理行 = 0** —— 否则这一臂测的是 `LINES_OUTSTANDING` |
| B | 两个数字相等 → 照常对得上 | 反向臂:没有它,A 可能只是"什么都拒" |
| C | 说明恰好等于差额 → 带着差额对上,且**存下来的 difference 不是 0** | 断言解释**没有把两个数字抹平** |
| D | 说明少报 20 → `VARIANCE_UNEXPLAINED` | 有说明 → 够不到 A;差额非 0 → 够不到 E。**只能由它自己那条接住** |
| E | 没有差额却给说明 → `VARIANCE_NOT_APPLICABLE` | 反向的自相矛盾 |
| H1/H2 | 对账记录、差额说明都不可改不可删 | — |

**`132-the-book-balance-counts-both-sides-of-a-reversal-and-a-reconciliation-is-a-record.sql`**
上一次 gate **✓ 通过**(包含两条自证非空的臂)。

| 臂 | 断的是什么 | 注入方向 |
|---|---|---|
| G | 一笔被冲销的分录对现金余额净影响为 0 | **自证非空**:fixture 里自己算一遍旧口径(只数 posted),**断言它与正确答案确实不同**;若冲销的形状哪天变了,这一臂会失败而不是安静变绿 |
| F | 事后补一张日期 ≤ period_end 的分录,**冻结值纹丝不动**,而重算值动了 | **自证非空**:同时断言 `drift ≠ 0` —— 注入若没生效,这一臂不会因为"没事发生"而通过 |
| I | 重开报表**不删**记录,只标 superseded;再对一次是**一行新记录** | — |

### 【不存在】的臂 —— 别把它们读成已覆盖

* **`VARIANCE_KIND_INVALID` / `VARIANCE_AMOUNT_INVALID` / `VARIANCE_NOTE_REQUIRED`
  三条逐项校验,fixture 里【没有臂】。** 它们只在**线上回滚探针**里验过一次
  (三条都按名抛对了)。探针不进仓库,**所以这三条今天没有任何常设覆盖。**
* **`VARIANCE_ITEMS_INVALID`(传进来的不是数组)一次都没验过**,连探针都没有。
* **旧签名单参数调用仍然解析得到**:探针验过,**fixture 里没有臂**。
* **`preview_reconcile_statement` 的权限拒绝没有臂。**
* **报表之间的连续性检查**:**刻意不做**,已按名记进 `docs/known-issues.md`
  (含它会抓到什么、以及"第一张报表没有前一张"那个必须具名的起点分支)。

## 5 · 线上有哪些状态,一个新会话会读错

* **`INV-2026-0009` 必须留着,不要清理** —— 冒烟的查询探针要靠它才不是空的。
* **GST 开关是 ON**,而且是刻意的(GST 五刀已建成并上线)。
  fixture 里把它设成 false 是**在事务内、整段回滚**,与线上无关。
  **注意:线上直接 `UPDATE finance_settings SET gst_registered=false` 会被
  `guard_gst_switch` 拒**(有在册的带税单据)—— 那是对的,别绕它。
* **`bank_statements` 只有 1 张,已 reconciled,open 的 0 张**;
  **`bank_reconciliations` / `bank_reconciliation_variance_items` 都是空表**
  (新建的,还没有人对过账)。
* **账户 `1010` 的现金余额今天变了**(−31,338.70 → −29,753.70)。
  **那是修好了,不是数据被改了。** 底下的分录一条都没动过。
* 备份已做,**在迁移之前**:`~/evoltrya-backups/evoltrya-backup-2026-08-26-1317.dump`
  (3,041,124 字节,`RUN_EXIT=0`,`pg_restore --list` 读得出 4,149 条,耗时约 14 分钟)。
* **没有**遗留进程、**没有** idle-in-transaction、**没有**独占锁、`.live-lock` 已释放
  —— 关机前逐项确认过。

## 6 · 设计裁定(已经问过 Tim,不要重新推导)

三轮 grilling 的结论,全部已采纳并已实现:

1. **提取一份 `bank_book_balance_asof`,视图与拒绝共用** —— 而不是在旁边写第二份对的。
2. **差额说明是一张表(逐项)**,不是 `reason + amount` 一对列 —— 真实的一个月有
   好几笔不同金额的时点差。
3. **说明的金额必须【恰好】等于差额**,否则"这是原因"只是一句放在差额旁边的注解。
4. **快照**(与 GST 已申报的那一份同规矩),**而且冻结值与实时重算值必须并排显示、
   各自标明**,谁也不替换谁 —— 两者不一致本身就是信息。
5. **一次对账 = `bank_reconciliations` 的一行事件**,不是报表上的几个列 ——
   否则"重开再对一次"会覆盖第一次签下的那一份,而那正是被禁止的编辑。
6. **不设容差。** 容差就是"带阈值的未解释差额",而逐项说明已经给了诚实的出口。
7. **按钮不因差额变灰**,服务端始终是权威;面板**在差额为 0 时也显示三个数字** ——
   只在出事时才出现的面板,会教人把"它没出现"读成"没查过"。

## 7 · 一处【与 grilling 结论不同】的实现,理由在此

第二轮我曾提出、Tim 也批准了「**在本刀里修 `bank_unmatched_journal_lines`**」。
**实现时没有照做,因为那个前提被代码推翻了:**

`match_bank_line` 对属于 `reversed` 分录的行**直接抛 `JL_ENTRY_REVERSED`**
(`db/functions/match_bank_line.sql:57-59`)。也就是说那张视图过滤 `posted`
**问的是"这一行还配得上吗",与匹配函数自己的资格规则逐字一致** ——
它属于「判断单张分录还活着没有」那一类,**是对的用法**。
改掉它反而会把匹配函数保证会拒的候选摆到人面前。

**所以:`bank_unmatched_journal_lines` 保持原样,理由写在
`db/views/bank_reconciliation_status.sql` 的文件头与 `AGENTS.md` 那一节里。**
由此多出来的一条残留(冲销分录本身会永远留在候选清单里)**已按名记进
`docs/known-issues.md`**,含返回条件。

> 这一条要在下一次开工时**当面告诉 Tim**,不要让它只躺在文件里:
> **他批准的是一个被我后来推翻的前提。**
