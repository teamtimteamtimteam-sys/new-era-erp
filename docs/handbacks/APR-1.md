# APR-1 — 审批开关的那扇门(2026-09-22)

**开工闸(通过):** 工作区干净;`HEAD` = `origin/main` = `git ls-remote origin main`
= `5d67336dfe30cc0e2db0ebd008e15a7638316e8f`(APR-0 勘察,只有文档)。

**★ 破窗起点(取自 `db/apply_migration.sh` 自己打印的那一行):**
### `2026-09-22 11:25:15 CST`
落盘记录:`db/migration-windows.tsv` → `2026-09-22T11:25:45+0800`。
**★ 终点:已关闭 —— Tim 确认部署完成(他没有给钟点)。**
**上界 `2026-09-22 12:25:06 CST`,而这是【量出来的】,不是"写这行字时的本地时间"。**
出处:`finance_settings_history` 里那**唯一一行**,`changed_at = 2026-09-22 12:25:06.869296+08`,
`changed_by = 321f1819-…`(= `admin@swm-os.test`)。**它只能由部署后的代码写出来** ——
`set_approvals_policy` 是这四列的唯一写入口,而 `changed_by` 是一个真的 JWT 主体,
不是 Management API 的 `postgres`(那条路上 `auth.uid()` 是 NULL)。
☞ 所以**破窗长度 ≤ 59 分 51 秒**(11:25:15 → 12:25:06)。
⚠ **另记一个更松、但口径不同的上界:**写下本段时的本地时间 `2026-09-22 12:40 CST` ——
照 APR-2 委托书的要求记下,**标明它是上界,而且是三者中最松的那个**。
★ 真正的终点(部署 `state=success` 的那一刻)**没有被任何东西记下来**,
照直说:它落在 11:25:15 与 12:25:06 之间,更精确的值本刀拿不到。
**这段时间里【什么是坏的】:** 库已经是新的,而线上跑的还是旧代码。旧代码
**不认识** `finance_settings_history` 与 `set_approvals_policy`,也不会送新的
`/settings/approvals` 表单 —— 所以那一页在这段时间里仍然是**只读的旧面板**,
没有报错、没有半截的表单。⚠ **真正会在这段时间里变的一件事:**
`approvals_readiness()` 的内检已经换成 `action.manage_permissions`(N6),
而**旧页面的闸本来就是那个码**,所以两者仍然重合 —— 这一格是运气,不是设计,
照直记下来。**审批在整段破窗期间保持 OFF。**

---

## ★ 读数的身份,一次说清

**本文所有线上读数都是:以 `postgres` 身份、经 Management API 执行,
`rolbypassrls = true`** —— 除了**显式声明切换了会话身份**的那几处
(`SET LOCAL ROLE authenticated` + `request.jwt.claims`),它们会逐处点名是【谁】。
每一处都说明读的是**基表**还是**系统视图**。

**每一个数字都是脚本自己那一行退出码报出来的**,不是启动器的状态。

---

## §1 · 交付了什么

| # | 东西 | 在哪 |
|--:|---|---|
| ① | `set_approvals_policy(boolean, text, text, numeric)` —— 四列的**唯一**写入口,`SECURITY DEFINER`,查 `action.manage_permissions` | `db/functions/set_approvals_policy.sql` |
| ② | `guard_approvals_policy_write()` + `trg_approvals_policy_write_gate` —— **列作用域**的写闸,按名拒 | `db/functions/guard_approvals_policy_write.sql` |
| ③ | `finance_settings_history` —— 只增不改,由同一支 RPC 写 | `db/tables/finance_settings_history.sql` |
| ④ | `/settings/approvals` 的写路径:表单 + server action + en/zh 文案 + **变更史面板** | `app/settings/approvals/{ApprovalsForm,ApprovalsHistory,actions}.tsx\|ts` |
| ⑤ | `approval_log` 读策略补上 `work_order` 这一支 | `db/tables/approval_log.sql` |
| ⑥ | N6:`approvals_readiness()` 的内检换成 `action.manage_permissions` | `db/functions/approvals_readiness.sql` |
| ⑦ | **闸轮多出来的一件:**两支错误码映射器的正则里【没有数字】,审批的具名拒绝一条都到不了屏幕 | `app/{finance/financeErrorCodes,purchasing/purchasingErrorCodes}.ts` |
| ⑧ | 文档:`docs/approvals.md` §3b/§3c · `docs/forward-queue.md` · `docs/known-issues.md`(关两条、开一条) | — |

**一个迁移,增量式:** `db/migrations/2026-09-22-apr1-the-approvals-switch-gets-a-door.sql`。
**新 fixture:** `db/fixtures/202-the-approvals-switch-has-exactly-one-door.sql`。

★ **本刀【没有】打开审批,一刻也没有。** 迁移自证第 ④ 条就是这件事:
迁移末尾断言 `approvals_enabled` 仍是 false,是的话才 COMMIT。

---

## §2 ★★★ 守卫靠什么认出"这是 RPC 写的" —— 以及为什么它【举不起来】

**这是本刀最要紧的一页,因为最直觉的那个做法是错的,而它错得很好看。**

### 2.1 两道测试,而载重的只有一道

```
guard_approvals_policy_write()          -- ★ INVOKER 权限,刻意的
  ① 四列的【值】一个都没变            → 放行(setPeriodLock / GST / close_period 走这一支)
  ② row_security_active(TG_RELID)     → RAISE 'APPROVALS_POLICY_DIRECT_WRITE|<变了的列>'
  ③ 事务局部的旗子没举起来            → 同一条拒绝
  ④ 把旗子放倒,放行                  -- 用完即焚
```

### 2.2 ★ 为什么旗子【不能】是那道边界 —— 实测,不是推的

**2026-09-22,一次回滚掉的探针,`postgres` 经 Management API:**

```
row_security_active('public.finance_settings')   as postgres       →  false
                                                 as authenticated  →  true
set_config('evoltrya.apr1_forge_probe','1',true) as authenticated  →  ★ 成功,
                                                    读回 '1',无错
SET LOCAL row_security = off                     as authenticated  →  接受,但
   row_security_active 仍然是 true,而任何一次读当场报
   "query would be affected by row-level security policy for table finance_settings"
```

★★ **一个自定义命名空间的 GUC 不是一项权限,它是一个谁都写得进的值。**
所以旗子只能表达"这条路【说出了】它在写这四列",永远不能表达"这个人【可以】写"。

★★ **而 `row_security_active` 举不起来。** 它不是一个值,是一件关于【调用者是谁】
的事实:要豁免只能**是**表的属主,或者跑在属主的 `SECURITY DEFINER` 函数体内 ——
那是一次授权,不是一个设置。**最显然的那次攻击把门关得更死,而不是打开它。**

### 2.3 ★ 为什么守卫是 INVOKER

`row_security_active` 必须反映【调用者】的视角。`enforce_write_permission` 的抬头
逐字写着同一句话,而它是全库唯一另一支不是 `SECURITY DEFINER` 的守卫。
★ **一支 DEFINER 的守卫问的是它自己,回答"RLS 没生效",于是放行一切【而且全绿】**
—— `db/fixtures/202` 的 P 臂专门断言 `prosecdef = false`。

### 2.4 ★ 用完即焚,以及它修的是哪一课

`set_config(..., true)` 的 `true` 是 **is_local = 事务局部**,不是语句局部 ——
PUR2-FU2(2026-08-11)被自己的探针抓到过。所以守卫**在它放行的那一行上把旗放倒**:
举一次旗只授权一次写入,不是"事务的余生"。`finance_settings` 是单行表,
一条语句就是一行,所以这是**精确的**,不是近似的。

### 2.5 ★★ 照直说:它【不】拦 `postgres`,而没有任何东西拦得住

属主可以 DROP 掉这个触发器。**它建起来的边界是:任何受 RLS 约束的调用者都改不动
那四列,包括持 `module.finance.edit` 的一级审批人本人** —— 那正是
`APR0-APPROVALS-SWITCH-WRITE-GATE` 登记的洞,而 §4 的线上走证就是冲着它去的。

迁移与 fixture 仍然写得了那四列,**而它们必须显式举旗** —— 也就是每一条直连写
都要在源码里说出这句话。**五支 fixture 共 23 处**(`35`×3 · `52`×1 · `75`×1 · `127`×8 · `151`×10),
与 fixture 127 里 `evoltrya.po_status_ctx` 同一个成规。
★ 第 24 处举旗在 `202` 里,而它**不是**一次正当的写:它是**伪造尝试** ——
以 `authenticated` 举旗,断言那次写**仍然被拒**,因为边界不在那个值上。

### 2.6 触发器的开火顺序是【设计的】,不是碰巧

触发器按名字排序开火。`trg_approvals_policy_write_gate` 排在 `trg_approvals_switch`
之前("po" < "sw"),于是**一次直连写听到的是"你不该直接写这四列"**,
而不是一句关于策略完整性的、会把人带偏的话。fixture 202 的 P 臂钉住这个不等式。

### 2.7 曾被考虑并否决:收回列权限

`REVOKE UPDATE (那四列) ... FROM authenticated` 是一道真的权限边界。
**而列权限在触发器之前判**,于是调用者拿到的是
`42501 permission denied for table finance_settings` —— **一句没有名字的机器话,
它会把那条具名拒绝抢在前面吃掉。** Tim 裁定(2026-09-22):不做。

---

## §3 · RPC 与 `guard_approvals_switch`:不绕过,也不重复

RPC 发出的是一条**普通 UPDATE**,所以 `trg_approvals_switch` 照常开火;
**RPC 里没有 `EXCEPTION` 块**,九条具名拒绝原样穿过它。fixture 202 的 G 臂三格:
策略不全 → `APPROVALS_POLICY_INCOMPLETE`;角色没人持有 →
`APPROVALS_LEVEL1_ROLE_UNHELD|fx202-empty`;★ **三样齐备 → 开得起来**
(少了最后这一格,一个"永远不许开"的实现会全绿)。

### ★★ 3.1 而"具名拒绝到得了屏幕"这件事,开工时是【假的】

闸轮读代码时量到的,不是推的。`app/finance/financeErrorCodes.ts` 的码正则是

```js
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/     // ★ 字符类里没有数字
```

而每一条带级别的审批拒绝都带着一个 `1` 或 `2`。把九条真的会抛出来的拒绝
喂进这行正则,**实测**:

| 数据库抛出的 | 正则抓出来的 | 到得了屏幕吗 |
|---|---|---|
| `APPROVALS_POLICY_INCOMPLETE\|…` | `APPROVALS_POLICY_INCOMPLETE` | ✓ |
| `APPROVALS_LEVEL1_HOLDER_CANNOT_SIGN_IN\|finance\|1` | ★ `_HOLDER_CANNOT_SIGN_IN` | ✗ |
| `APPROVALS_LEVEL2_HOLDER_CANNOT_SIGN_IN\|cfo\|1` | ★ `_HOLDER_CANNOT_SIGN_IN` | ✗ |
| `APPROVALS_LEVEL1_ROLE_UNHELD\|finance` | ★ `_ROLE_UNHELD` | ✗ |
| `APPROVALS_LEVEL2_ROLE_UNHELD\|cfo` | ★ `_ROLE_UNHELD` | ✗ |
| `APPROVALS_LEVEL1_ROLE_CANNOT_SEE_AMOUNTS\|finance` | ★ `_ROLE_CANNOT_SEE_AMOUNTS` | ✗ |
| `APPROVALS_LEVEL2_ROLE_CANNOT_SEE_AMOUNTS\|cfo` | ★ `_ROLE_CANNOT_SEE_AMOUNTS` | ✗ |
| `APPROVALS_CANNOT_DISABLE_WITH_PENDING\|2\|PO-…` | `APPROVALS_CANNOT_DISABLE_WITH_PENDING` | ✓ |
| `APPROVALS_POLICY_LOCKED_WHILE_ON\|…` | `APPROVALS_POLICY_LOCKED_WHILE_ON` | ✓ |

★ **九条里六条到不了屏幕。** 而更难发现的一半:`APPROVALS_LEVEL1_ROLE_UNHELD`
当时**在**码集合里,也**在**两本词典里 —— 有人写过那句话、翻译过那句话,
**而它一次也显示不出来**。
☞ **一条写过、翻译过、却永远显示不出来的句子,比没有那条句子更坏:
它让下一个人以为这件事已经被照顾到了。**

**处置(Tim 的 Q2):** 两支映射器的字符类改成 `[A-Z0-9_]`,按函数体逐条补齐
审批那一族的码与中英文案,并**退役两条已经不存在的码** ——
`APPROVALS_LEVEL2_USER_UNKNOWN` 与 `APPROVAL_LEVEL2_USER_NOT_SET`
(二级在 CHAIN-BUILD-1 就从【人】改成了【角色】)。
**另外 44 支同款正则不动**,登记为 `ERRCODE-DIGIT-UNREACHABLE`,触发条件写在那里:
扫过 `db/` 每一条 `RAISE EXCEPTION`,**带数字的码除审批这一族外全部是迁移自证**,
到不了任何屏幕 —— 所以今天那 44 支没有一支看得见一个带数字的码。

---

## §4 ★★ 线上走证 —— 审批一刻也没有被打开

**全部在一个【以 `RAISE EXCEPTION` 收尾的事务】里跑,所以整段回滚,
一个字节都没有落地。** 演员是 `chooer@evoltrya.test` ——
**线上唯一持 `finance` 的真人,也就是被裁定的一级审批人。**

**原样照录,2026-09-22:**

```
APR1_LIVE_PROOF
  session: finance_edit=t manage_permissions=f row_security_active=t
  ARM1 direct write : APPROVALS_POLICY_DIRECT_WRITE|approvals_enabled
  ARM2 through RPC  : PERMISSION_DENIED|action.manage_permissions
  ARM3 control lock : rows=1 err=ok
  enabled before=f after=f   history before=0 after=0
```

| 臂 | 它证明的 |
|---|---|
| 会话那一行 | ★ 这个人**持有** `module.finance.edit`(表的写闸对他是开的)、**不持** `action.manage_permissions`、而且 **RLS 对他生效** —— 三件事都点名,不留给人推 |
| ARM1 | 直连写那四列 → **守卫按名拒**。这正是 APR0 登记的那个洞,今天关上了 |
| ARM2 | 经 RPC → **RPC 按名拒**(权限) |
| ★ ARM3 | **同一个会话写非审批列(期间锁)成功,rows=1** —— 少了它,ARM1 证明的可能只是"这条路根本不通";它同时钉住"守卫不许碰其余各列" |

**独立的一次事后读数(另一个事务,`postgres`,读基表):**

```
read_as = postgres
approvals_enabled = false        finance_settings_history = 0 行
level1 = finance   level2 = cfo   threshold = 1000   locked_before = 2026-08-01
```

★ **开关在走证前后都是 `false`;留痕表事后 0 行。** 两个数都是 Tim 点名要的,
**而它们不可能动** —— 两条写的臂都是拒绝,拒绝不留行;ARM3 那次成功也随事务回滚。
读数照取,因为**一个没测过的假设和一次测量在报告里长得一样**。

### 4.1 `work_order` 留痕的线上走证(只读)

```
APR1_WORKORDER_RLS
  postgres (RLS bypassed) work_order rows = 1
  chooer/finance    (持 module.processing.view): work_order=1   whole table=14
  fusheng/warehouse (不持)                     : work_order=0   whole table=0
```

★ **那一行留痕从"对每一个人都是 0 行"变成了"对有资格的人是 1 行"。**
⚠ **照直说这个走证的短板:** `fusheng` 整张表都读到 0,所以他那个 0 分不出
"不该你看这一支"与"这张表你整个读不了"。**分得开的那一格在 fixture 202 的 H2**
——一个持 `module.hr.view` 的人读到 `leave_request=1`、`work_order=0`。
两处合起来才是完整的形状,单独任何一处都不是。

⚠ **另一件照直说的:`cfo` 不持 `module.processing.view`**(实测:持有它的是
`admin` · `auditor` · `cco` · `cto` · `finance` · `gm`)—— **二级审批人仍然读不到
工单的审批留痕。** 那不是漏掉的一格:取的码与 `work_orders` 自己的读策略是同一个,
**读工单的判据只该有一份定义**。

---

## §5 · 验证链,逐条 —— 每个数都是脚本自己那一行

| 步 | 结果 | 出处 |
|---|---|---|
| `db/gate.py --offline`(第一次) | ★ `GATE_OWN_EXIT=1`,48s —— **抓到 4 件** | 见 §6 |
| `db/gate.py --offline`(修完) | **`GATE_OWN_EXIT=0`**,48s,干净 | 日志自报 |
| `~/evoltrya-backups/backup.sh` | **`BACKUP_EXIT=0`**,4.4M,TOC **5876**(上一份 5848,下限 5263) | 脚本自报 |
| `db/apply_migration.sh` | **`APPLY_OWN_EXIT=0`**;预检 4 条 CREATE FUNCTION(1 替换 · 3 新建) | 脚本自报 |
| `npm run types:gen` | **`TYPES_OWN_EXIT=0`** | — |
| `npx tsc --noEmit` | ★ 第一次 `TSC_OWN_EXIT=2`(2 处),修完 **`TSC_OWN_EXIT=0`** | 见 §6 |
| `npm run build` | ★ 第一次 `BUILD_OWN_EXIT=2`,修完 **`BUILD_OWN_EXIT=0`** | 见 §6 |
| `db/gate.py`(整门) | **`GATE_OWN_EXIT=0`**,**394s** —— 四个判词全绿(可重建性 · 镜像 vs 线上 · 行为断言 · 匿名面) | 日志自报 |
| `scripts/check-i18n.mjs` | **`I18N_OWN_EXIT=0`** | — |
| `scripts/check-error-swallowing.mjs` | **`SWALLOW_OWN_EXIT=0`**,0 新增 | — |
| `scripts/smoke-routes.mjs`(detached) | ★ **`SMOKE_EXIT=0`** —— **250 ok · 6 skipped · 0 FAILED**;计时 225 条,合计 725.2s,中位数 2973 ms | 日志自己那一行 |

**整门 394s 落在既有区间(183–650s)内。** 冒烟 725s 与 2026-09-05 实测的 765s 同量级。

---

## §6 ★★ 闸与门抓到的四件事 —— 这一节是本刀最值钱的产出之一

**四件里有三件是【我写下来的断言被实测推翻】,而不是打字错误。**

### ① `--offline` 抓到:直写那四列的 fixture 不是四支,是**五支**

我用一条带 `grep -v "^.*--"` 的命令去数直连写的地方 —— **那个过滤把任何一行
含 `--` 的都扔掉了**,而 `db/fixtures/52` 的那条 UPDATE 中间正好夹着一行注释。
于是我在闸轮里报的是"两支 fixture 要改",真数是 **六支、23 处**。
☞ **教训不是"grep 写错了",是:一次【数出来的数】必须能被第二条独立的路复算。**
`--offline` 就是那条路,它 48 秒给出了答案。

### ② `--offline` 抓到:N6 的代价,正如闸轮预言,而它确实要动 fixture

`db/fixtures/127` 的 C8 与 `151` 的就绪面板断言都调 `approvals_readiness()`,
而它们的演员持 `module.finance.view`、不持 `action.manage_permissions`。
两支当场 `PERMISSION_DENIED|action.manage_permissions`。各加一个码即可。
☞ **闸轮把这一条预报出来了(F4),而它仍然只有在跑起来时才变成事实。**

### ③ `--offline` 抓到:新页面把查询失败读成空集(4 处 `?? []`)

改成 `lib/db-helpers.ts` 的 `mustRows`。★ 这一页上**两处空集各自都有一句错的读法
在等着**:角色清单读成空 = "系统里没有角色";留痕读成空 = "这条策略从来没有被人
动过"。**后者正是本刀同时在修的那条已知问题的形状。**

### ④ ★★ 整门抓到:`anon` 授权 —— **同一个坑,两天之内第二次**

我在迁移末尾写着「新表会拿到 Supabase 的默认表级授权,所以往
`db/anon-grants-baseline.tsv` 加一行」。**那句话是错的。** 实测(迁移之后,
读 `information_schema.role_table_grants`):

| 表 | anon 够得着吗 |
|---|---|
| `finance_settings_history`(本刀) | ★ **不** —— `authenticated` · `postgres` · `service_role` |
| `fixed_asset_history`(FA-HIST-1,两天前) | ★ **不** —— 逐字相同 |
| `approval_log` · `pricing_formula_history`(更早) | **有**(旧的那一套默认权限) |

原因 FA-HIST-1 **两天前已经量过并写下来了**:线上 public 有【两套】默认权限,
而 `apply_migration.sh` 以 `postgres` 直连,这样落下的表本来就没有 anon;
本地重建的 prelude 复刻的是另一套,于是重建多了 anon —— 镜像对不上。
**处置与 FA-HIST-1 逐字相同(取严的那一边):** 镜像里显式
`REVOKE ALL ... FROM anon`,让**重建**长成线上的样子;基线里那一行**撤掉** ——
往一份「只许缩小」的基线里加一行,方向就反了。

> ### ☞ 这一条的教训,比这一条本身耐用
> ★ **同一个坑,两天之内被踩了第二次,而第一次的教训写在
> `db/tables/fixed_asset_history.sql` 的注释里 —— 一个【下一个建表的人不会去读】
> 的地方。** 一条只写在某个具体文件里的规矩,它的读者是"碰巧打开那个文件的人",
> 而不是"下一个会撞上它的人"。
> ☞ 本刀把它写进了迁移抬头与本节,**但那两处的读者也一样窄**。
> 真正的解药是一道闸(建表时断言 anon 授权与 `fixed_asset_history` 同形),
> 而那不在本刀范围内 —— **照直记成一件没做的事,不假装写下来就等于解决了。**

### ⑤ 另外两件小的(`tsc` 与 `build`)

* `tsc`:可空 RPC 参数在生成类型里是 required(签名无默认值),按
  `app/purchasing/orders/new/actions.ts` 的既有写法窄化断言;`user_directory` 是视图,
  每一列都可空 —— **不假装 `user_id` 不会是 null**,拿不到 id 的行直接跳过。
* `build`:`check-document-registry.mjs` 的 `EXPECTED_TABLES` 221 → 222。
  **这个摩擦是刻意的**,所以它按设计变红了一次。`EXPECTED_CODE_TABLES` 不动 ——
  本表没有 `code` 列(它记的是单行配置表的变更,没有单据号)。

---

## §7 · 屏幕上有什么

* **四个值一起保存** —— 因为 `guard_approvals_switch` 是把它们放在一起判的。
* **能不能开 / 能不能关,在按之前就说出来**,读的是 `approvals_readiness()`,
  也就是闸读的同一份判据。★ 它**不是**第二道闸:绕开界面直接调 RPC 照样按名拒。
* ★ **`admin` 与 `cco` 【列】在下拉框里**,§0b 那句裁定印在旁边。
  §0b 说这条规矩**有意不做成机器规则**;**一个悄悄把它们去掉的下拉框,
  在执行这条规矩的同时不留下任何痕迹** —— 下一个读代码的人会以为数据库拦着它。
* ★ **没有"只读的观众",而这是【构造上】的:** 页面的闸、RPC 的闸、
  `approvals_readiness()` 的内检(N6 之后)是**同一个码**。屏幕自己把这句话说出来
  (`seeingIsChanging`),不留给人猜。
* **开着的时候改策略【允许】**,并且说明它对在途单据做了什么(带张数)。
  该不该锁住是 APR-2 的未决项 —— `guard_approvals_switch` 今天只禁止**清空**。
* ★ **变更史面板** —— 而它不是装饰:新建一张史表却没有任何地方读它,
  等于当场把 `APR0-WORK-ORDER-APPROVALS-INVISIBLE` 的形状再造一遍。
* ★ **空状态那句话是被认真写的:** 本表在 APR-1 之后**是空的**,因为线上那一行
  是这块屏幕存在之前直接改库设上的,而**那一次变更不在这里编造出来**。
  不说清楚,一片空白读起来正好等于"这条策略从来没有被人动过" ——
  一句关于内控的、错误的断言。
* **两句过期的话被改掉了:** `noConfigUi`(原文:"系统里根本没有配置审批链的界面")
  与页面抬头的注释(原文:"app/ 底下没有任何东西写那四列")。
  ☞ **留着比删掉更坏:一句留在屏幕上/代码里的过期断言,下一个人会当成前提去推理**
  —— `docs/approvals.md` §3 刚刚为完全相同的形状付过一次账。

---

## §8 · fixture 202 钉住了什么(十一臂)

`db/fixtures/202-the-approvals-switch-has-exactly-one-door.sql`

| 臂 | 它断言的 |
|---|---|
| P | 写闸装上了、**名字排在开关闸之前**、**守卫是 INVOKER**(DEFINER 会放行一切而且全绿) |
| A | RPC 写下四列,**正好落 1 行史**,old/new 两侧与 `changed_by` 都对 |
| J | RPC **不动期间锁** —— 否则它会继承一条自己没做过的改动带来的 SOD 拒绝 |
| B | 什么都没改 → **不落史**(Q6) |
| C | 持 `module.finance.edit` 而不持 `action.manage_permissions` → **RPC 按名拒** |
| D | 直连写四列 → **守卫按名拒**,而且**逐列点名**;而他**写得了这张表**(E 当场证明) |
| ★ D2 | **自己举一次旗也混不过去** —— 边界不在那个值上 |
| E | **对照**:同一会话写期间锁成功 rows=1 → D 不是"这条路不通",守卫没越界 |
| F | 留痕拒 `UPDATE` 与 `DELETE`,各自报 `HISTORY_APPEND_ONLY` |
| G | 策略不全 / 角色无人持有 → 开不起来;★ **三样齐备 → 开得起来**(否则"永远不许开"也全绿) |
| I | N6:持 `action.manage_permissions` 读得到就绪面板;只持 `module.finance.view` 的**被拒** |
| H | `work_order` 留痕读得出来,**两侧都有同会话对照**(H1 的人只读得到自己那一支;H2 的人读得到 `leave_request` 却读不到 `work_order`) |

---

## §9 · 本刀量过、并发现为假的断言

**(`AGENTS.md` 要求这一节存在,空着也要写。本刀不空 —— 而且其中四条是我自己写下的。)**

1. ★★ 「`guard_approvals_switch` 的具名拒绝到得了屏幕」—— **假**:九条里六条到不了,
   而其中一条还被写过、翻译过(§3.1)。
2. ★★ 「一个事务局部的旗子可以当作写闸的边界」—— **假**:`authenticated`
   自己就 `set_config` 得了,实测成功、读得回、不报错(§2.2)。
3. ★ 「直写那四列的 fixture 有两支」(我自己在闸轮里写的)—— **假**:**五支、23 处**。
   数错的原因是一条会吞掉含 `--` 的整行的 grep(§6①)。
4. ★★ 「新表会拿到 Supabase 的默认 anon 授权」(我自己在迁移里写的)—— **假**,
   而且 **FA-HIST-1 两天前就量过同一件事**(§6④)。
5. ★ 「`APPROVAL_LEVEL2_USER_NOT_SET` / `APPROVALS_LEVEL2_USER_UNKNOWN` 是活的码」
   —— **假**:二级在 CHAIN-BUILD-1 就从人改成了角色,两条都已退役。

**量过、确认【为真】的(复核也要留痕):**

* `row_security_active` 在 `authenticated` 下**为真且扳不倒**,`SET row_security = off`
  被接受却不改变它,而且让读当场报错 —— ✓ 实测三格。
* 线上策略行 `false · finance · cfo · 1000`、`locked_before = 2026-08-01` —— ✓ 走证前后一致。
* `finance` 持 `module.finance.edit` 且不持 `action.manage_permissions` —— ✓ 会话自报。
* `cfo` 不持 `module.processing.view` —— ✓ 于是二级读不到工单留痕,这是对的。
* `close_period` / `reopen_period` / `setPeriodLock` / GST 开关**都只写非审批列** ——
  ✓ 逐处读过,守卫的比值写法因此对它们完全透明(fixture 202 E 臂钉住其中一条)。

---

## §10 · 交回给 Tim 的

1. ★ **翻那个开关的人是 Tim,从 `/settings/approvals`,一次。** 本刀交付的是那扇门,
   不是那个动作。今天 `can_enable = true`(两级各一个真持有人,两级都看得见金额)。
2. ~~**破窗的终点** —— 等部署 `state=success`。~~ ★ **已关闭,见文首**(上界
   `12:25:06 CST`,量自 `finance_settings_history` 那唯一一行)。

### ★ 2b · 部署之后 Tim 做了什么 —— 【这是他的报告,不是一次测量】

**照录他说的话,标明它的性质:**

> 部署完成后,他从 `/settings/approvals` **把审批打开了**,然后**自己走了一遍采购单流程** ——
> 1,000 以下走一级、1,000 及以上走二级、**自批被拒**。**他报告没有问题。**

★★ **把它记成【Tim 的报告】,而不是【本刀量到的事】,而这不是客套** ——
APR-2 闸轮当天(2026-09-22 12:40,`postgres`,读基表)量到的是:

| 读的是什么 | 读数 | 与那份报告的关系 |
|---|---|---|
| `finance_settings_history` | **1 行**,`2026-09-22 12:25:06`,`changed_by = admin@swm-os.test` | ✓ **对得上** —— 开关确实是经那扇新门翻的 |
| `finance_settings.approvals_enabled` | **true** | ✓ 对得上 |
| `purchase_orders` 最新一行 | `PO-2026-0011`,`2026-09-08 10:51` —— ★ **今天一张都没有新建** | ✗ **对不上** |
| `approval_log` 今天(`decided_at::date = 2026-09-22`)的行数 | ★ **0**(全表 14 行,最后一行停在 `2026-09-11 22:32`) | ✗ **对不上** |
| `purchase_orders` 待批 | **0** | ✗ 对不上 —— 一次走到一半的流程本该留下 pending |

### ★ 状态:**OPEN —— 等 Tim 说明他那次走证是怎么做的**(2026-09-22)

Tim 已裁:**把这个差额记成【未决】,并且在他回答之前,不许从"采购链已经在线上证过了"
这个前提往下推。** APR-2 因此**没有**把它当成已知事实用过一次 ——
它反而【另外】量了一遍权限结构,并把结论单独写清楚(见下)。

☞ **照直说:那次采购单走证在线上【没有留下任何痕迹】。** 本刀**不推测**是哪一种
(预览环境 / 只翻页没提交 / 别的),只把两件事并排放着:**他的报告是他的报告,
而线上数据里找不到它。** ★ 这一格要紧,是因为下一刀会**从"采购链在线上跑通过"
这个前提往下推** —— 而这个前提今天**没有被线上数据证实**。
(★ 好消息:**权限结构支持它**。见 APR-2 闸轮 §a 的交叉表 —— `finance` 持
`module.purchasing.view` + `data.view_prices`,`cfo` 也持,所以两级都真的批得动。
**采购链是五条链里唯一一条权限对得上的。**)
3. **APR-2 起的六条裁定已经写进仓库**(`docs/approvals.md` §3c 讲理由,
   `docs/forward-queue.md` 讲顺序与触发条件)。★ **N1 是 APR-5 的前置**,
   而 APR-5/APR-6 仍然**没有估价** —— 它们的主体是 N1 与 N5 怎么落地。
4. ★ **一件没做、而且不假装做了的事**:§6④ 那个 anon 授权的坑**没有闸**。
   今天靠的是两处注释,而它们的读者太窄。要真的关掉它,得有一道
   "建表时断言 anon 授权与 `fixed_asset_history` 同形"的检查 —— 不在本刀范围。
