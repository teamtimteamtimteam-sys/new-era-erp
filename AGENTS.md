<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

# Database mirrors

`db/tables/`, `db/functions/`, `db/views/` mirror the live schema so it can be rebuilt from the repo. **Any migration that touches a table must update that table's mirror file in the same commit** — same for functions and views. Single-function files under `db/functions/` are exact `pg_get_functiondef` bytes; table mirrors are first-run CREATE scripts with columns in live ordinal order (ALTER-added columns stay at the end).

When in doubt run `python3 db/check_mirrors.py` — it replays the whole mirror set into a scratch schema inside a rolled-back transaction and diffs the catalogs against live (exit 0 = clean). Never paste a table mirror into the live DB directly: table mirrors contain `CREATE OR REPLACE FUNCTION` and would silently overwrite live functions — the script's header explains both hazards.

**从 `pg_get_viewdef()` 重新生成一份视图镜像时,`WITH (...)` 那一段【不会跟过来】。**
它只吐 `SELECT …`,不吐 reloptions。所以照它重建镜像会把
`WITH (security_invoker = off)` 悄悄丢掉(PAYEE-1a 实测,由判词二抓到)。
**要把话说准:丢掉它【不会】把视图变成 invoker** —— PostgreSQL 的默认本来就是
属主权限,所以行为一致,红的是【镜像文本】那一栏,不是那张视图的行为。
但仍然必须补回去:镜像要能一字不差地重建线上,而且下一个读镜像的人会据此
判断这张视图是不是刻意声明过。线上有 61 张显式 `security_invoker=off` 的视图,
本刀顺手全查了一遍,镜像缺这一句的:**0 张**。

## RUNTIME CONFIG bootstraps: what the harness cannot see

`check_mirrors.py` classifies seeded tables two ways (see `SEED_TABLES` /
`RUNTIME_CONFIG_TABLES`). RUNTIME CONFIG tables — the ones an operator can change
through the app — are **deliberately not row-compared against live**, because live
diverging from the file is the system working correctly, not drift.

That exemption is drawn in the right place, but it has an edge. The harness does
still **replay** each bootstrap into a scratch schema, so it already catches:

* a seeded column that was renamed or dropped (replay fails — proven against the
  `days_per_month` → `days_per_year` change);
* a seeded value that violates the table's own constraints (replay fails);
* a `NOT NULL` column added since, with no default, that the seed omits (replay fails);
* a bootstrap that seeds **zero** rows overall (`bootstrap` line, fails);
* a bootstrap referencing a permission code, role code or account code that its own
  mirror set does not define (`integrity` line, fails).

**What it cannot see, and you must check by reading:**

> **When a migration changes the MEANING of a column that a RUNTIME CONFIG table
> seeds, without changing its name or type, nothing will tell you the bootstrap is
> now wrong.** Re-read every affected bootstrap in the same commit.

The case that prompted this rule: HR-2c changed `leave_accrual_rates` from a monthly
figure to an annual one. It happened to rename the column, so a stale bootstrap would
have failed the replay — but had the column kept its name, the file would still have
said `2.0` and `1.5`, a rebuilt production database would have given every office
employee **2 days of annual leave a year instead of 24**, and `check_mirrors` would
have reported a clean bill of health.

So: **a migration that touches a RUNTIME CONFIG table must state, in the same commit,
whether its bootstrap default is still correct.** Not "still valid" — the harness
answers that. Still *correct*, meaning the numbers in it still mean what they meant.

## Verifying the rebuild path

`check_mirrors.py` asks "do the mirrors match live". **`db/verify_rebuild.py` asks the
other question: can this repository actually build a database at all.** OPS-1 ran that
experiment for the first time and the answer was no — three separate walls, none of
them written down anywhere (see `db/platform-prelude.sql`). Having fixed them, the
experiment needs to stay repeatable rather than have been done once.

```
python3 db/verify_rebuild.py --target "<dsn of an EMPTY database>"
python3 db/verify_rebuild.py --target "<dsn>" --skip-diff     # build only, no live comparison
```

Exit codes: **0** = builds and matches live · **1** = builds but differs · **2** = does
not build.

Prerequisites: `psql` on PATH; an **empty** target database (it gets written to — never
point it at live); network access to live if you want the diff. A throwaway local
cluster:

```
initdb -D /tmp/pg -U postgres --no-locale --encoding=UTF8
pg_ctl -D /tmp/pg -o "-p 55432 -k /tmp/pgsock -c listen_addresses=''" -l /tmp/pg.log start
createdb -h /tmp/pgsock -p 55432 -U postgres scratch
```
The socket directory must be short (< 103 bytes) — a deep temp path fails with
"Unix-domain socket path is too long".

**It also answers whether `db/platform-prelude.sql` is still sufficient.** When a replay
fails on a missing schema, role, relation, function, type or extension, the script names
the object and says the prelude is not sufficient, rather than leaving a bare psql error.
That matters because the prelude is the only written record of what the mirrors expect
the platform to provide, and nothing else notices when that expectation grows.

## Mirror function signatures: built-in types only

**A mirror function signature — `RETURNS` and every parameter type — must name only
built-in types. Never a table's composite type.**

This is not style. The replay order is `db/functions` → `db/tables` → `db/views`, and
`SET check_function_bodies = off` exempts a function's **body** but not its
**signature**: the return and parameter types must already exist when `CREATE FUNCTION`
runs. A table composite type in a signature therefore *can never work* in a rebuild,
whatever order you try. `%ROWTYPE` inside the body is fine — that is the part the
exemption covers.

Caught the hard way: `require_reviewer_of` was written `RETURNS performance_reviews`.
`check_mirrors` passed it; `verify_rebuild` failed with
`type "performance_reviews" does not exist`. An audit of all 100 function mirrors and
the live catalog found it to be the only instance, and no table column anywhere uses a
composite type.

## The database gate runs on every cut that touches the database

```
python3 db/gate.py        # ~4 min measured, no large payloads over the network
```

> **The cost, re-measured (PROC-1b, 2026-08-12): 247s wall clock, not the ~32s
> this line said for months.** The 32s was true when it was written and OPS-6 had
> just cut the 40-minute pooler replay down to one local rebuild; what grew since
> is the third verdict — **54 fixtures now, against 25 when that number was
> written** — and each one is a full behavioural run against the rebuild. Nobody
> re-measured, because the fixtures were added one at a time and no single one
> ever felt like it cost anything. Same disease as `--reach`'s "ten to fifteen
> minutes", found the same way: someone finally timed it. It is still fast enough
> to run on every database-touching cut, which is what matters — but **a
> written-down cost must be a measured cost**, so this one is now dated and says
> what it was measured against.
>
> **Re-measured (SO-2, 2026-08-14): 191s wall clock, 64 fixtures.** Ten more
> fixtures than the line above and it got *faster*, which is worth a sentence
> rather than a shrug: the 247s figure was one measurement on one machine on one
> day, and the honest reading is that this gate costs **two to four minutes**,
> not that it has a single true number. Keep dating them; do not average them.
>
> **Re-measured again (WO-1a / WO-1a-fu, 2026-08-16): 74 fixtures, and four runs
> the same afternoon came in at 130s, 152s, 379s and 266s.** The 379s is the one
> worth naming: it is 2.5× the 130s measured two hours earlier on the *same
> machine* with the same fixture count ±1. Nothing in the repo explains it — the
> new fixture's `pg_get_functiondef` captures are catalog reads costing
> milliseconds, and the run before it was cold too. The likeliest cause is the
> pooler/network, which this machine has already been observed to degrade on
> (see the INV-2a smoke episode). **So the honest reading is now a range with a
> fat tail: two to six minutes, occasionally worse, and the variance is not in
> the fixture count.** If a run ever exceeds ~400s, measure before assuming the
> gate got heavier — the variance so far has been environmental, and mistaking it
> for growth is how someone ends up "optimising" a gate that is not slow.
>
> **Re-measured (GRN-1a, 2026-08-17): 87 fixtures, 483s — one run, and it is the
> slowest yet recorded.** It crosses the ~400s line the paragraph above draws, so
> the line was honoured rather than shrugged at: 87 fixtures against 74 is +18%,
> and 483s against the 130s measured the same month is +270%. **The growth in
> fixture count does not come close to explaining it**, which is the same
> conclusion the 379s run reached by a different road. Recorded as one dated
> measurement, not averaged into the others, and **not** treated as evidence that
> the gate now costs eight minutes — the next run may well be two. The range
> stands: two to six minutes with a fat tail. What would change the reading is a
> *run of* slow measurements, not this one.
>
> **Re-measured (GRN-1b, 2026-08-17, same day, same machine): 87 fixtures — the
> identical set — in 155s.** That is 3.1× faster than the 483s logged hours
> earlier with **the same fixture count**, so it closes the question the previous
> paragraph left open: the 483s was **environmental, not growth**. Same-day
> corroboration: `select 1` against the pooler measured **2.9–4.4s** during the
> slow window (see the NET-CHECK entry in `docs/known-issues.md` — this machine's
> own egress, not the database). **Two measurements of the same set, 3× apart, are
> the strongest evidence in this table that fixture count is not the variable.**
> The range still reads two to six minutes with a fat tail; nobody should
> "optimise" this gate.
>
> **Re-measured (AUDIT-1, 2026-09-01): 181 fixtures in 461s.** Twice the fixture
> count of the FIX-1 line above and 3.5× its wall clock — but read it against the
> *same-era* runs, not against August: the GRN-1a/GRN-1b pair proved 3× swings at
> an identical fixture count on this machine. 461s sits just under the 483s record
> and inside the fat tail, so **the honest reading is still "two to six minutes,
> occasionally worse", now measured at roughly double the fixtures.** One
> measurement, dated, not averaged. What would change the reading is a run of slow
> measurements at this count, not this one.
>
> **Re-measured (FIX-1, 2026-08-18): 91 fixtures — four more than the pair
> above — in 133s.** That is the **fastest run yet recorded at the highest
> fixture count yet**: +4 fixtures against GRN-1b's 87, and 22s *faster*. It is
> the cleanest single refutation in this table of the idea that the gate is
> growing, and it changes nothing else — **two to six minutes with a fat tail,
> and the variance is environmental**.

One LOCAL rebuild, two separately-reported verdicts (OPS-6 merged the two older
tools — their build steps were identical and check_mirrors was shipping a
~14,000-line replay through the pooler, taking 40+ minutes and dying on DNS and
socket exhaustion):

| verdict | exit | question it answers |
|---|---|---|
| 可重建性 | 2 on fail | can this repository build a database **at all** (prelude sufficiency, B1/B2 on live AND rebuild) |
| 镜像 vs 线上 | 1 on fail | do the mirrors match live — structure, seed rows, bootstrap counts, cross-file integrity, definer caller checks, column grants, invoker views reading revoked columns (OPS-13), currency literals, **generated TypeScript types** (OPS-10: `lib/database.types.ts` is the schema's OTHER mirror — `db/tables/*.sql` is the one the rebuild reads, this is the one the COMPILER reads. When it lags, TypeScript validates against a shape the database no longer has, so a renamed or dropped column compiles clean and fails at runtime. Same question as the other mirrors and the same fix — regenerate and commit — so it shares this verdict rather than taking an exit code of its own. Regenerate with `npm run types:gen`; generation is deterministic, so the gate compares bytes. It costs ~5s of the gate's ~32s. **但它读的是 PostgREST 的 schema 缓存,不是 pg_catalog —— 刚 DROP 过东西时它会吐一份【过时】的文件**(TASK-1a-fu1 实测:函数在 `pg_proc` 里已经是 0 行,`types:gen` 仍然把它写了出来,gate 于是为一件不存在的漂移报红)。**DROP 之后先 `NOTIFY pgrst, 'reload schema';` 等十几秒再生成。** 这不是 gate 的毛病:两边都在说实话,只是其中一边看的是一份旧快照 —— 与本文件反复说的「先问这个判据读的是哪一份真源」是同一条), **database-level GUCs** (FIN-20: the rebuild inherited the dev machine's timezone while live ran UTC, so the two disagreed on what day it was for the project's whole life and nothing looked — same shape as function ACLs before OPS-4; exceptions are named in gate.py's GUC_ALLOWLIST with written reasons) |

The verdicts stay separate because they are different failures with different
fixes. `check_mirrors.py` and `verify_rebuild.py` remain as the engine (gate.py
imports/spawns them); run verify_rebuild alone when you only need one side.

### 种子比对表达式里的表名一律写 `{S}.` —— **不许写 `public.`**(CHECK-1,2026-08-31)

`check_mirrors.py` 把镜像建进**同一个库的另一个 schema**(`mir`);`db/gate.py` 把它
建进**另一个库**的 `public`。于是 `SEED_TABLES` 里同一句列表达式在两个工具里含义不同,
而**写死 `public.` 在 gate 里碰巧是对的、在 check_mirrors 里是跨 schema 比对**。

实测症状:`kpi_position_templates.position_code` 在 live 侧是 `'CFO'`、mirror 侧是
`NULL`,于是整张表每一行都"漂移" —— **镜像其实一个字都没错**,错的是比对表达式
(相关子查询拿 `mir` 的 `position_id` 去 `public.positions` 里找)。
**两个检查一红一绿,只可能有一个对,而这次对的是 gate。**

本地两 schema 复现:写死 `public.` → drift 2;各自解析到自己那一侧 → drift 0;
把 mirror 的 title 改一个字 → drift 2 回来(**它没有变瞎,只是不再撒谎**)。

修法不是把那两行改对 —— 那只让今天的两行对。表名改成占位符 `{S}.`,调用方各自替换
(`check_mirrors` → `mir` / `public`,`gate` → 两边都 `public`),
并加一条**导入即断言**:任何人再写一次 `public.`,两个工具在导入的那一瞬间就起不来。
**一个在种子上喊狼来了的检查,与一个被人关掉的检查是同一种坏。**

### 杀掉 `check_mirrors.py` 【不会】结束它在库上那笔事务(EQP-1c-a,2026-08-21)

> **`pkill -f check_mirrors.py` 杀的是本机那个 Python 进程。它在【线上】开着的那笔
> 事务不会跟着结束 —— 连接经连接池活下来,会话停在 `idle in transaction`,
> 手里攥着它replay 到一半的那些锁。**

实测:为了不与 `db/gate.py` 抢 scratch schema,`check_mirrors.py` 被 `pkill` 掉。
七分钟后,一条最普通的 `INSERT INTO suppliers` 撞上 **`canceling statement due to
statement timeout`** —— 报错一个字都没提锁。`pg_stat_activity` 里是这样:

```
pid 2269989 | idle in transaction | xact_age 00:07:12 | CREATE POLICY "roles insert by permission" ON mir.roles …
pid    5452 | active              | wait_event Lock/relation
```

也就是说**那笔事务还在,连别的会话都开始排在它后面了**,而本机上看不出任何异常。
这与本文件已经记着的两条是同一族:`pg_dump` 持着 ACCESS SHARE 让 `ALTER TABLE`
卡到超时(报错同样只说"语句超时",不说在等谁);以及"启动器的退出码冒充脚本的
退出码"。**共同点是:本机的进程状态,不等于库那一侧的状态。**

**处置(实测有效,而且是安全的):**

```sql
SELECT pid, state, now()-xact_start AS age, left(query,60)
  FROM pg_stat_activity WHERE state = 'idle in transaction' ORDER BY xact_start;
SELECT pg_terminate_backend(<pid>);
```

终止它是安全的:`check_mirrors` **整支都跑在一笔最终必然回滚的事务里**,
所以终止 = 提前回滚,那正是它本来的结局。实测终止后 `mir` schema 是 0 个,
排队的会话立刻放行。

**更好的做法是别制造这一幕:`db/gate.py` 内部就会跑 check_mirrors,
不要再单独起一个;真起了要停,用 `pg_terminate_backend` 收尾,不要只 `pkill`。**
顺带:单独跑 `check_mirrors.py` 是把 ~14,000 行重放【推过连接池】,
在这台机器的隧道上本来就慢得没道理 —— OPS-6 把它换成本地重建正是为了这个。

## A wait with no bound is a wait with no failure — use `db/wait_for.sh`

```
db/wait_for.sh --timeout 900 --label "db/gate.py 判词" -- grep -q "判词【行为断言】" /tmp/gate.log
```

**`--timeout` and `--label` are mandatory; the script refuses to run without
either.** That is the whole point — it is not possible to express an unbounded
wait with this tool, and on timeout it prints what it was waiting for, how long
it waited, and the condition itself.

The shape it exists to kill:

```bash
until grep -q "判词" gate.log; do sleep 5; done     # ← no exit condition
```

When the thing being waited on dies, this waits forever, silently. It happened
twice: once on a backup, then on 2026-08-07 for **2 hours 47 minutes**, waiting
for a fixture verdict string from a process that was no longer running. After
the first one the response was to remember to add a bound. Remembering did not
work — which is the usual signal that **a note was used where a mechanism was
needed**, and the same lesson OPS-7 drew about `B1`/`is_system`.

### 后台跑一支长脚本:用 `db/run_detached.sh`,不要再手写那三行(EQP-2c,2026-08-21)

```
db/run_detached.sh --log /tmp/backup.log --label "备份" --token BACKUP --timeout 2700 \
    -- ~/evoltrya-backups/backup.sh
```

**为什么是脚本而不是本文件下面那段样板。** 备份那一节已经把判据写清楚了 ——
「唯一证据是 `backup.log` 里那一行【脚本自己打出来的退出码】」,并且给了
子壳 + `wait_for.sh` + `grep` 的三行样板。**那段样板没能拦住任何一次:**
同一次会话里【启动器的退出码冒充脚本的退出码】**五次**(备份一次、冒烟四次),
EQP-1c-b-fu2 的提交信息记下了第四次,然后第五次照样发生。
**样板要人照抄,机制不照抄就跑不起来** —— 与 OPS-7 用脚本替掉两句"记得检查
B1 与 is_system"、`wait_for.sh` 替掉"记得给等待加上限",是同一次替换。

它做三件事:子壳把**命令自己的**退出码追加成 `<TOKEN>_EXIT=n`(那一行的作者是被等的
脚本,不是启动它的东西);用 `wait_for.sh` 等它;**拿不到那一行就拒绝给判词** ——
退 **3**,并明说「本脚本因此【不知道】它成没成功,这不是失败的证据,也不是成功的」。
**它不解决"脚本自己撒谎"**(BK-FIX 之前的 `backup.sh` 印着失败却退 0)——
那一条的处置是修那支脚本,已经做过。两条叠起来才完整:
**脚本要说真话(BK-FIX),而它说的话要真的被读到(本脚本)。**

**★【OPS-TIMEOUT(2026-08-29)之后,到点那一支变了,而这一段原本是错的】★**
这里原本写着"四个分支都做过故障注入(0 / 7 / 超时 / 用法错)"——
**那句话在【超时】那一格上是假的**:超时那一支当时会杀错东西(打在子壳上)、
并且**永远写不出判词**,而它从来没有被注入验过。它犯了两次才被人眼发现。
现在:

| 到点时 | 做什么 |
|---|---|
| ① 先看一眼 | 那支活可能刚好干完 —— 已有真判词就用它的 |
| ② **先写判词** | `<TOKEN>_EXIT=124`(124 = `timeout(1)` 的"命令超时";**不用 137/143,那两个数在本仓库已经表示"被别的东西 SIGKILL 掉了"**) |
| ③ 再收尾 | 按【进程组】发 SIGTERM → 宽限 **5s**(实测最慢的活 node 0.124s,取 40 倍余量)→ 还在就 SIGKILL |
| ④ 复核 | 收干净了就说收干净了;没收干净**按名报出来**,那是一个发现 |
| ⑤ 落到同一段读取路 | 退出码**从日志那一行读出来**,于是退出码与日志不可能各说各话 |

**于是 `run_detached` 到点退 124,不再退 3;3 只剩"连那一行都拿不到"这一个含义。**
**七个分支这次都做了故障注入**(正常退 0 / 正常退 7 / 超时 / 无视 SIGTERM 被强制 /
消费者读得到超时判词 / 信号转发 / 到点同刻活自己写出判词),
**并且先用 `git show HEAD:` 取出旧脚本把原始故障复现了一遍**——
旧脚本:判词 0 行、活还在、ppid=1;新脚本:同一支活,`B_EXIT=124`、进程组收干净、无孤儿。

> **顺带一条会咬人的:进程组一分开,Ctrl-C 就不再传到那支活身上了。**
> `run_detached` 因此自己 trap INT/TERM 并转发给那个组 —— 实测那两行是**承重**的:
> 摘掉它们,给监督者发一个 TERM,那支活会活下来(1 → 1);装着,它跟着走(1 → 0)。
> **没有它,这一刀就是在上限处消灭一个孤儿、同时在键盘上造出另一个。**

### 有上限是对的 —— 但先分清你等的是哪一种活

上面那条规矩(有上限、有失败分支)是为【本该很快出现、却没出现】的等待写的:
备份落盘、gate 吐判词、dev server 起来。那种等待里,超时几乎总是意味着出事了。

**有另一种活,它跑得好好的时候就是一声不吭:** 按角色的可达性走查(三个角色、
每个角色两三百个页面、十来分钟)、整库重建、大批量导入。对这种活,**任何上限都会
把"还在跑"翻译成失败**,而人一旦被误判折腾几次,就会去绕开那个上限 —— 那才是真正
的损失,因为绕开之后连失败分支都没有了。

**这种活不要等,要 start-and-leave:** 后台起它、让它把日志写下来、去干别的、
回头读结果。判断"活着还是挂了"由**日志自己回答**,所以这类脚本必须**逐条打印进度**——
沉默五分钟的进度条,和挂死的进程在屏幕上是同一样东西。逐条进度不是体贴,
是 start-and-leave 能不能用的前提。

**2026-08-10 的实况,记下来是因为它比道理更管用:** 为了绕开 600 秒的上限,
我把 `db/wait_for.sh` 换成了四个手写的 `until grep …; do sleep …; done`(正是这个
脚本存在的理由),三个还在轮询同一个日志;轮询期间为了"顺便把别的做了",
跑了一次 `npm run build` —— 它重写了 `.next`,把正在跑的 dev server 搞死了。
**等待本身造成了它正在等的那个失败**,而且因为轮询没有失败分支,又过了很久才被发现。
所以:等 ≠ 免费。等一个长活的正确做法是不等它。

### 重试的【延时】必须由一次测量撑着,不能由一个整数撑着(PAYEE-1a,2026-08-18)

> **一次重试之前要等多久,答案只能来自"我观察到那次故障已经过去了"。
> 来自"半小时听起来差不多"的延时,是一个没有证据的等待 —— 而它花掉的时间
> 与一次真正的观察一样长。**
>
> **没有那个测量时,正确的做法是:【立刻重试一次,然后停下来】。**

PAYEE-1a 的备份被网络打断(`Can't assign requested address`),当时的处置是
"30 分钟后重试一次"。**那 30 分钟没有任何依据**:这台机器的出口当天
【一整天都是慢的】—— `select 1` 从早到晚是 2.5s → 5.0s → 7.6s,单调变差,
没有任何一次测量显示它曾经恢复过。等 30 分钟与等 30 秒的区别,只在于
多花了 30 分钟。**间歇性的故障值得等;持续性的故障只值得再试一次。**

判据一句话:**你能指出哪一次测量说明"它会好起来"吗?**
* 能(例如实测到 `select 1` 已经回到亚秒、或者上游状态页说故障已解除)
  → 按那次测量决定等多久;
* 不能 → 立刻重试一次。**还失败就停下来报告,不要开始猜第二个整数。**

这与"不要对着劣化的网络做重试循环"是同一条的两半:
那条说【不要循环】,这条说【连那一次重试之前的延时,也要有出处】。

### 条件必须由【循环】求值,不是由启动它的那个 shell

用对了 `wait_for.sh` 仍然可以写出一个【永远不会成真】的等待:

```bash
# 坏:$(...) 在 wait_for 启动【之前】就被外层 shell 展开了一次,
#     条件从此冻结成 test "pending" = success —— 轮询 9 分钟,值永远不变。
./db/wait_for.sh --timeout 600 --label "部署" -- test "$(gh api … --jq .state)" = success

# 好:把求值放进循环每一次要跑的那条命令里
./db/wait_for.sh --timeout 600 --label "部署" -- \
    sh -c 'gh api … --jq .state | grep -qx success'
```

上限救了它(到点就停),但那 10 分钟本来一秒都不必花。**判据是:这条命令
每轮重跑一次,它的答案会变吗?** 命令替换、数组展开、以及任何在参数位置就
算完的东西,答案都是"不会"。RPT-1 实测过一次,记在这里而不是留给下一个人。

**Bounded is not enough on its own — the bound needs a failure branch.**
`smoke-routes.mjs` waited 60×1s for the dev server and then continued *whether
or not it was ready*: with a dead server that produced 131 connection failures
and no statement of the actual cause. It now fails immediately when the process
dies, names why, and prints the tail of the server log (fault-injected with a
`next dev` that cannot start: exits 1 with `dev server 没起来`).

So, for any new wait: use the script, or write the failure branch yourself. A
wait that cannot say "I gave up on X after Ns" is indistinguishable from a hang.

### 判据必须检查【标签承诺的那件事】—— 而空集不是"还没到"

上面两条管的是"等多久"和"条件每轮重不重算"。**还有第三种死法:条件写得
既有上限、又每轮重算,却【问的根本不是标签说的那个问题】。** SO-3b fu5 之后那条
手写的部署等待,一句里犯了两个,两个都实测复现过:

* **标签写着"部署 state=success",判据只 grep 有没有一条部署记录**
  (`deployments?sha=… --jq .[0].id | grep -q "[0-9]"`)。一次【失败的部署】照样
  让它变绿 —— 桩注入实测:`state=failure` 时它通过。**一个声称在检查 X、实际
  检查 Y 的等待比不检查更坏,因为它会被信。**
* **判据从第一轮起就不可能成立。** GitHub 的 `?sha=` 只认【完整 40 位】SHA;
  传 7 位缩写进去,它返回 **HTTP 200 + 空数组** —— 不报错、不提示。那次轮询了
  **877 秒**,而被等的部署【早就 success 了】。这是 `mustRows` / `restRows` /
  `check-i18n` 后缀解析同一条规矩的第四处:**一次失败(或一个问错了的问题)
  不是一个空集**,而把空集读成"还没到"的等待,会一直等下去。

所以除了上限与"每轮重算",再加一句自检:**把标签念出来,再把判据念出来,
两句话说的是同一件事吗?** 以及:**这个判据的"假"里,混进了"我问错了"吗?**

部署这一件已经做成机制,不要再手写:

```
scripts/wait-for-deploy.sh              # 等 HEAD
scripts/wait-for-deploy.sh 7a3f519      # 缩写在【本地】补全,不留到 API 那头变成空集
```
它 `git rev-parse` 补全 SHA、判据检查的就是 `state=success`、落到 `failure`/`error`
时**立刻退出(码 4)而不耗光上限**,并打印 CST 的 success 时刻 —— 那正是切次报告里
破窗那一栏的**终点**(起点由 `apply_migration.sh` 打印)。两个分支都做过故障注入。

### 部署这件事的【真源是 Vercel】,不是 GitHub 的部署记录(GRN-1b,2026-08-17)

> **判词的真源是 Vercel 自己的 deployment state。GitHub 的 deployment record 是
> 一份【下游登记】,它会滞后、也会干脆不出现 —— 实测滞后 30 分钟以上,当晚两次。**
> **所以:记录不在,不等于部署没发生。等之前先看 Vercel。**

这不是一个理论上的区别,它当晚花掉了两段时间:

* **一次 37 分钟的滞后。** GRN-1a 推送 14:48:32Z,GitHub 上的部署记录直到
  15:25:29Z 才出现(`state=success` 15:25:30Z,两者只差 1 秒)。默认 900 秒的
  上限因此超时退 3,并印出"多半已经死了或从未开始" —— 而它既没死也没有从未开始,
  它早就成功了。**当时据此写下的报告说"部署从未被触发",那句话是错的。**
* **一次干脆没出现。** GRN-1b(`a4ac8f1`)与其修复(`6d24704`)在 Vercel 面板上
  各自 **Ready、耗时 1 分 04 秒**,生产早已是新的;而 GitHub 那侧的记录迟迟不来,
  脚本还在轮询。同一晚 `api.github.com/graphql` 连续 **HTTP 503**(REST 正常)——
  **这两件事是同一场劣化的两个面**,而脚本轮询的恰恰是受影响的那一侧。

**为什么这条值得单独写下来:它是本文件已有那条规矩的一个新形状。** 上面写着
"一次失败(或一个问错了的问题)不是一个空集";这里是它的孪生:

> **一份【下游登记】的缺席,不是【那件事】的缺席。**

`?sha=` 返回空数组时,脚本读成"还没到"——这在登记正常时是对的,在登记本身
挂掉时就变成了一个**永远不会成真、而且问错了对象**的等待。上限救得了时间,
救不了结论:超时那句话会把"我问错了地方"说成"它多半死了"。

**所以流程是:**
1. 推送后先看 **Vercel 面板**(或下面那条命令行,如果将来接上);
2. Vercel 说 Ready → **部署完成,破窗在此刻闭合**,不必等 GitHub 登记;
3. 只在拿不到 Vercel 那一侧时,才退回 `wait-for-deploy.sh`,并且知道自己
   等的是一份**可能不来**的登记 —— 那时超时**不是**"部署失败"的证据。

**但不要把这条读成"GitHub 的记录没用"——【滞后是阵发的,不是常态】。**
同一晚 01:10:49 推送的 `c02f97c`,部署记录 **2 秒**就出现了,`state=success`
在 01:12:01。而那三笔"迟迟不来"的登记(a4ac8f1 / 6d24704 / 804808d)最终也
【全部到齐】,success 时刻分别是 16:20:46Z / 16:21:39Z / 16:26:20Z ——
也就是说当时它们【已经成功了】,只是登记还没写下来。
慢的那一段与 `api.github.com/graphql` 连续 503 同时发生,所以最可信的读法是:
**这是 GitHub 侧的一次阵发劣化,不是这条管线的固有属性。**
`wait-for-deploy.sh` 平时好用得很;要改的只是【记录不在时的结论】,不是这个工具。

**实测把这条钉死了(2026-08-18 00:10 CST):** `a4ac8f1` 推送于 23:38:09,
Vercel 面板上它与 `6d24704` **各自 Ready、各耗时 1 分 04 秒**;而 **32 分钟之后
GitHub 对这两个 SHA 的部署记录数都是 0**。也就是说,那个 2400 秒的等待会把上限
**整个耗光**,然后为两次【1 分钟就成功了的部署】报一句失败。
**这正是"把下游登记的缺席当成事件的缺席"能造成的最大代价:结论与事实完全相反。**

#### `wait-for-deploy.sh` 现在【问不了】Vercel —— 查过了,不是猜的

逐项实测(2026-08-18):

| 需要的东西 | 本机现状 |
|---|---|
| `vercel` CLI 在 PATH 上 | **没有**(`command -v vercel` 空) |
| `vercel` 在 devDependencies 里 | **没有** |
| `.vercel/project.json`(带 `projectId` / `orgId`) | **没有**(而且 `.gitignore:37` 忽略 `.vercel`) |
| `VERCEL_TOKEN` 之类的环境变量 | **没有** |
| `~/.vercel` 里的凭据 | **没有** |

**所以上面那条规矩目前是【流程】,不是【机制】** —— 与本文件反复说的那句相反的方向:
这里明知道"记住去看 Vercel"是一条靠人记的规矩,而靠记是不管用的(OPS-7 那一课)。
把它做成机制需要下面这些,**留给单独的一刀,不在 GRN-1b 里顺手做**
(在一次刚被它绊倒的切次里现写一个新检查,正是"匆忙写出来的检查"的由来):

1. **一个 Vercel API token**,按 `~/.pgpass` 的先例存在仓库【外面】,由环境变量
   (`VERCEL_TOKEN`)喂进去 —— 绝不进仓库;
2. **项目标识**:`vercel link` 生成的 `.vercel/project.json` 里的 `projectId`
   (它是 per-machine 且已被 gitignore),或者项目名 + 团队的 `teamId`/slug;
3. **按 commit SHA 找那次部署**,读它的 `state`(`READY` / `ERROR` / `BUILDING`
   / `QUEUED` / `CANCELED`)。Vercel 在每次部署上记着来源 commit ——
   **具体字段名与 API 版本在动手那天查文档确认,不要照抄这段话里的记忆**。

改完之后,判据的标签与判据本身才终于说的是同一件事:标签写着"部署成功了吗",
问的也就是部署本身,而不是"GitHub 有没有登记过这件事"。

## Route smoke test — run on demand, whenever the render layer changed

```
node scripts/smoke-routes.mjs                  # 16m47s measured 2026-08-26 across 192 routes (was "~2-4 min" at ~135 routes)
node scripts/smoke-routes.mjs --reach=finance  # ONE role's reachability — the form to reach for
node scripts/smoke-routes.mjs --reach         # all three roles (~100 min; a deliberate pre-push sweep)
```

### `--reach` takes a role now (GUARD-FIX-1, 2026-09-01)

**One role, one run.** Copy-paste form, one role at a time:

```
node scripts/smoke-routes.mjs --reach=finance      # admin | operations | finance
```

Duration per role, all measured: **admin ~63 min** and **operations ~17 min**
(2026-08-11, 1,018 fetches); **finance 59m47s** (GUARD-FIX-1 — 3587s,
verdict `REACHFIN2_EXIT=0`; walked 457 pages, tried 145 static routes, 88
openable, 3 unreachable = the expected set); **operations 25m28s** (CHART-0,
2026-09-02 — 1528s, verdict `SMOKE_EXIT=0`; walked 187 pages, tried 147 static
routes, 36 openable, 3 unreachable = the expected set). **operations 已经从
~17 min 长到 25m28s** —— 路由从 1,018 次抓取那一版长了不少,别再照 2026-08-11 那个数设超时。

> ★【CHART-0 更正一处措辞与一处顺序】★ 上面 finance 那次【不是】"this cut" ——
> 写下它的是 GUARD-FIX-1(`7759848`),而 `7759848` **早于** LOGIN-1-fu1(`210c4d6`)。
> 这件事要紧,因为 `210c4d6` 让已登录的人打开 `/login` 时重定向走,而
> `EXPECTED_UNREACHABLE` 的判据此前把"打不开"读成了"走得到" ——
> **从那一刀起这个检查对三个角色必然误报,而它默认不跑,于是躺了五刀没人发现。**
> CHART-0 修了判据(`gone` 改为直接问 `seen.has(x)`),完整的实测与推理写在
> `docs/information-architecture.md` §12.6。修完重跑 operations:187 / 36 / 3,
> **与误报那一次的三个数字逐字相同** —— 只有那一行假警报没了。 **Do NOT extrapolate a role's cost
from fetch ratios — that is how this cut got it wrong the first time.** Extrapolating from the 2026-08-11 ratios gave "~20–25 min",
a 3600s limit was set from it, and the run was on course to be killed at ~65 min
of real work — the GST-2 false-kill shape again, a limit derived from an
*estimated* cost rather than a *measured* one. Measured crawl rate: **10
pages/min**. A misspelt role **exits 2 loudly** rather than running
zero roles and printing a green line — a check that verifies nothing while
claiming to pass is the failure mode this repo keeps paying for.

**Why it was split, rather than given a longer timeout.** The all-roles run no
longer fits: admin alone ate ~63 of the 90 minutes and the route frontier grew
475 → 563 mid-crawl, so `finance` was killed part-way. **A three-hour check is a
check nobody runs** — and GUARD-FIX-1's two discarded guards survived four days
for exactly that reason, because `--reach` is the only thing that sees them and
nobody could afford to run it. Splitting also means a cut that changes one role's
access can exercise just that role.

**Do not "optimise" this into a crawl phase and a try-open phase.** That split
yields two runs *neither of which can fail*: the verdict is
`unreachable = openable − seen`, and both sets must come from the same role in
the same run. Splitting by role is the only split that still produces a verdict.

> **`--reach` catches a page whose guard was discarded — and until
> NAV-CLEANUP-1 it was the only check that caught an openable-but-unreachable
> page.** The ordinary smoke asserts 2xx, and by its own documented blind spot a
> page rendering an error box is still 200. `check-permission-predicate` ④
> catches the *spelling* of a discarded guard at build time; it cannot tell you
> whether a page actually refuses. Run `--reach=<role>` after touching
> navigation, `lib/modules.ts`, a permission guard, or that role's grants — and
> after adding a page.
>
> ★★【NAV-CLEANUP-1(2026-09-03)更正这句"唯一",而更正的方向是【它变弱了】】★★
> **两件事一起发生,所以这句话在今天是假的:**
> * **它结构上看不见【第二级】** —— 顶栏的模块菜单是点开才渲染的
>   (`ModuleBar` 的 `{isOpen && …}`),爬虫点不了。UI-FIX-1 为此付过账:
>   它据此删掉一条 `--reach` 断言,检查当场变红。
> * **NAV-CLEANUP-1 ② 又拿走了它的前沿** —— 页内的同级导航行整批删掉了
>   (10 个组件、121 页),而那正是它此前赖以扩散的东西。
>   今天它靠的是 dock 那几条 + 页内链接 + 三张【落地页】
>   (`/finance` `/operation` `/settings`,各自把本模块的注册表条目画成 `<Link>`)。
>
> **接替它的是 `scripts/check-nav-routes.mjs`(NAV-CLEANUP-1 ⑥,进 `npm run build`,
> 不碰数据库,秒级)**:注册表每条 href 都有路由 · 每条路由要么在注册表要么在
> 带理由的例外表 · 退休路径不许出现(点名文件与行) · 范围 id 是真实前缀 ·
> 活动模块解析器**真的跑一遍**。五条判据全部做过故障注入。
>
> **★ 但它们答的不是同一个问题,谁都不许冒充谁 ★**
> 静态检查答**注册表与文件系统对不对得上**;`--reach` 答**一个【会话】走不走得到**。
> **而"一个人点不点得到"两者都答不了** —— 那要人走一遍
> (见 `docs/information-architecture.md` §17.7 那份清单)。

> **快的那一半也重新量过(BANK-REC,2026-08-26):16m47s,192 条路由**
> (23:25:37 → 23:42:24,判词 `SMOKE_EXIT=0`,191 ok / 3 skipped / 0 FAILED;
> 同时段隧道 `select 1` 为 2.97 / 6.11 / 3.67s)。
> 上面那句「~2-4 min」写的是 **~135 条路由**那个时代,而路由数长了四成、
> 隧道也没那么快了 —— **它不是写错了,是写下来那天是对的,后来没人再量。**
> 与 `--reach` 那句"十到十五分钟"同一种过期,只是幅度小些。
> 记在这里是因为**决定"这一刀要不要等冒烟跑完"的人读的就是这个数**:
> 在两分钟它是顺手一跑,在十七分钟它要排进节奏里。

**The `--reach` half is opt-in on purpose.** It walks from `/` as `admin`,
`operations` and `finance`, following only the links each role's pages actually
render, and asserts the set each role can *open* but cannot *reach* — the check
that would name a page with no entry point. **It costs upwards of two hours — 65m 44s measured on 2026-08-11 across 139
routes, but OVER 2 HOURS on 2026-08-24 across 189 routes with the tunnel degraded
(`select 1` at 7.05 / 4.61 / 5.91s against 3.1–4.1s earlier the same day).** This file said
"ten to fifteen minutes" until then: that figure was an early estimate nobody went
back and measured, and it was off by four to five times. The number matters because
it is what someone deciding whether this cut needs `--reach` actually reads — at
fifteen minutes you run it out of habit, at an hour you first ask whether the cut
touched navigation, which is exactly the judgement making it opt-in was meant to
produce. **A written-down cost must be a measured cost.** It costs about an hour, and
it was briefly the default: that made every commit wait on it, which is the same
cost that kept it out of `db/gate.py` in the first place, arriving by another
road. **A check too slow to run every time ends up never run**, so the cadence is
written down instead: run it when navigation, subnavs, `lib/modules.ts` or a
permission guard changed; after adding a page; before a push that accumulated
several page-touching cuts; or when someone reports they cannot reach something.
Not after every edit — the fast half already renders every route on every run.

### 一条正确的检查放错了相位,就是一条慢检查

**能在开跑前回答的问题,就在开跑前回答 —— 而且在【还什么都没启动】的时候回答。**

2026-08-11:新加的 `/finance/freight/[id]` 没有 `ID_SOURCES` 映射,冒烟【走了几分钟
之后】才中止。那次中止本身是**对的** —— 它拒绝把"没有映射"当成"没有数据",点名了
路由并停下(那正是 `restRows` 那条规矩)。但它回答的是一个**静态**问题:每条动态
路由是不是都取得到 id?而它被问的时候,dev server 已经起来、一次性会话已经建好、
临时行已经扫过。于是那次失败花掉的不只是四分钟,还有一轮清理,以及重跑 `--reach`
的三十分钟。

现在它是 `preflightIdSources()`,跑在 `main()` 的第一行 —— 在 `sweepStalePort()`
之前、在 `next dev` 之前。**3 毫秒,43 条动态路由,不起服务器、不建会话、不碰数据库。**
两个分支分开报,因为修法不同:段在 `ID_SOURCES` 里却没有前缀命中(响亮中止),
与段压根不在 `ID_SOURCES` 里(**不中止**,字面量原样进 URL,跑到一半报成一次普通的
路由失败 —— 看起来像页面坏了,不像映射漏了)。后者至今没有触发过,而这正是它值得
被检查的理由;两个分支都做过故障注入。

**这是同一个形状的第三次,所以它是一条规律而不是一次事故:**

| | 慢在哪 | 怎么改的 |
|---|---|---|
| `check_mirrors` | 把 ~14,000 行重放【推过连接池】,40+ 分钟,死在 DNS 与套接字耗尽上 | 改成一次**本地**重建(OPS-6),~32 秒 |
| `--reach` | 曾经是默认,于是每一次提交都要等十几分钟 | 改成**显式开启**,把节奏写下来 —— 一条慢到不能每次跑的检查,最后会变成从来不跑 |
| 本次 | 一个静态问题被放在【走查中途】问 | 提到开跑前,3 毫秒 |

三次都不是"检查写错了",而是**问得太晚**。所以每加一条新检查,先问一句:
**它需要什么才能回答?** 只需要仓库里已有的文件,就别让它等服务器。

**Its blind spot bit within the hour it was written**, so treat this as load-bearing
rather than a caveat: dynamic routes (`/customers/[id]`) are excluded from the
assertion, because "this role has no rows here" and "this page has no entry point"
are the same thing to a walker. SAL-B6's new customer page shipped with **no entry
point at all** — the list linked only to `/edit` — and the check reported clean,
correctly, because the page is dynamic. **When you add an `[id]` page, confirm its
entry point by hand.**

**A third blind spot, and it bounds what a CONTENT assertion can ever check
(CAPEX-1, 2026-08-29): the fast half is `fetch`, not a browser — so anything
behind a client-side toggle is invisible to it.**

CAPEX-1 rewrote six message keys that had said "commissioning freezes the cost",
and the check it most wanted was *did those sentences actually leave the screen* —
「一条记录活得比它的主语久」being this repo's most repeated defect, whose failure
mode is that **nothing errors**. Two content assertions were written for exactly
that, and **both went red against clean 200s**: `expense.form.existingAssetHint`
renders only after `isAppend`, `purchasing.form.assetLineHint` only after
`isEquipment`, `assets.actions.commissionWhy` only once the panel is expanded.
None of the three is in the server-rendered HTML, nor in the next-intl payload.

**The red was the JUDGEMENT, not the page** — the same family as the `&` that the
server escapes to `&amp;`, and as `name="supplier_id"`: **a criterion that can
never be satisfied is a bad criterion, and it reports as "the feature is
broken".** So before adding a `MUST_CONTAIN` needle, ask: **is this string in the
DEFAULT render, or does a person have to click something first?** If a click is
required, this harness cannot see it, and the honest disposition is to say so
where the assertion would have gone rather than delete the idea silently — which
is what `scripts/smoke-routes.mjs` now does above `MUST_CONTAIN`.

**A second blind spot, same shape, found by a human clicking (FIX-1,
2026-08-18): a link hidden by CSS is reachable to the walker and invisible to
the person.** The inbound list carried both of its entry points as plain `<a>`
tags — `/inbound/receive` under `sm:hidden` and `/inbound/new` under
`hidden sm:inline-block`. They are **mutually exclusive by viewport width**, so
on a desktop browser there was no way at all to reach field receiving (and
therefore no way to receive against a purchase order line), while `--reach`
would have called both routes reachable, correctly, because both anchors are in
the markup. **The walker reads the DOM; a person reads the screen.** Responsive
visibility classes are the one construction where those two answers come apart
without anything being broken, so `sm:hidden` / `hidden sm:` on a *navigation*
element deserves the same hand-check an `[id]` page gets: open it at the width
the person actually uses.

Builds compile pages but never render them — two pages were broken for months
with every gate green (an RSC serialization error and an inverted currency
filter), each found by a human clicking. This script starts the dev server,
signs in with a throwaway admin session, requests every route under app/
with real ids pulled live from the database, and for each failure captures
the SERVER-side error and stack, not the browser message. It also runs one
REVIEWER-VIEW check: /my-reviews/[id] is a contract-404 for admin, so it
would otherwise never render — the script builds a scratch fixture (two
ZZ-SMOKE-* employees plus one probation review; scratch business rows are
NAMED as scratch because they surface on HR screens) and requests the page
as the actual reviewer, expecting exactly 200. Status-guarded routes get
their expected status COMPUTED from the picked row's status column, not a
loose "either is fine" list. Design redirects and contract-404s are declared
in the script's EXPECTED map — each entry was individually verified before
being allowed. Cleanup runs at START as well as at end: a finally block
does not survive a kill, and this script drives HTTP against a live server,
so a startup sweep of smoke-*/ZZ-SMOKE-* leftovers is the only rollback it
can have.
The skip list is ASSERTED, not printed: EXPECTED_SKIPS names the routes
allowed to skip for lack of data, and drift in either direction fails the
run — a route moving from ok to skipped is a coverage regression that looks
identical to "no data yet" (four finance routes silently lost coverage that
way). For the same reason a failed id query aborts loudly naming the route
and error instead of counting as a skip: a failed query is not an empty
table, just as a resolver parsing zero suffixes is not an empty set.
Deliberately NOT part of db/gate.py: it needs a dev server and minutes — a
slow gate is a skipped gate (the check_mirrors lesson). Run it after touching
page-level rendering, and after any bug a human finds by clicking.

### 临时行:报告,不清扫 —— 而这条区别本身就是判据

```
npm run check:scratch      # 也在冒烟开跑时自动跑一次(报告,不中止)
```

**一次清扫必须【依据一个它无法核实的判断去动手】**:这一行是上次崩掉的残骸,
还是另一个进程此刻正在用的?两者长得一模一样 —— `sweepScratch` 就是这么在
2026-08-10 删掉了另一个会话正在用的账号(`docs/concurrency-one-tree-one-smoke.md`)。
它没有归属信息也没有年龄判据,而**把它扩到更多张表,只会让同一个 bug 的爆炸半径更大**。

> **归属与年龄,正是清扫不能安全知道、而报告可以照直说出来的东西。**
> 同样的不确定,两种代价:报告说错了,人多看一眼;清扫做错了,正在跑的活被毁掉。

所以这个检查只**陈述**判断,不**依据**它动手。三件事让它不至于变成"喊狼来了":

* **两小时的年龄门槛**把【这一次正在跑的行】与【滞留的行】分开。判据是实测的最长
  一跑(`--reach` 65 分 44 秒),门槛必须明显高于它,否则一次 `--reach` 跑到一半
  会把自己的行报成滞留 —— 而喊狼来了的报告没人看。用年龄而不是运行标记,是因为
  实测发现的残骸**不是冒烟写的**,是一次没有回滚的 fixture/探针留下的:年龄对每
  一种来源都成立,不需要任何一方配合。
* **第三列报"还有谁在引用它"**,把"残骸"与"有人依赖的残骸"分开 —— 后者**不能删**。
* **它不中止冒烟**:家务不该做成拦路的门,否则人会学会跳过那道门。

**它第一次跑就证明了自己**:`materials.ZZ-SMOKE-PROBE` 命名像残骸,而**一张在册的
真批次 `IN-2026-0180`(Acme,100,000 kg)正引用着它**。一次按命名规则的清扫会把它
删掉,并让那张真批次指向一个已删的物料 —— 比留着残骸坏得多。

## 「取最新那一行」要先问:这张表【排得出先后】吗(AGING-1,2026-08-27)

**一张只可追加的留痕表,`created_at timestamptz NOT NULL DEFAULT now()` —— 看起来
它当然排得出先后。而 `now()` 是【事务开始时刻】,不是语句时刻:同一笔事务里写进去
的两行,`created_at` 一模一样。这张表对这两行的先后【没有任何记录】。**

AGING-1 的单价回推第一版写的是「取截至日之前最后一次改价的新价」:

```sql
ORDER BY ph.created_at DESC, ph.id DESC LIMIT 1     -- ← id 是随机 uuid
```

时刻相同的时候,决定答案的就是那个 `ORDER BY` 的第二项 —— 而它是
`gen_random_uuid()`。**同一份数据,两次运行两个答案。** 它是写 fixture 时抓到的:
同一支 fixture 时红时绿,而红的那次报的是「截至今天与今天那张视图对不上」。

**线上一次都不会显形**,因为界面上每次改价各自是一笔事务;能制造出它的只有
脚本与 fixture —— 也就是说**它会先在测试里显形,而最容易的处置是把测试改掉**。

**判据:你打算按什么排序?那个东西【真的记录了先后】吗?**
* `created_at DEFAULT now()` —— 记录的是**事务**,不是行;同事务内并列。
* 随机 uuid 主键 —— 不记录任何东西,把它放进 `ORDER BY` 只是让不确定变得看不见。
* `bigserial` / 显式序号 —— 记录先后,可以排。

**没有可排的东西时,换一个不需要排序的问法。** 这一次的换法是:
**不从历史里往前找,而从【今天的值】往回走** —— 「截至 D 的价」= 若 D 之后有过
改动就取最早那一次的 `old_unit_price`,否则就是今天的价。同刻的两行不再需要分先后,
而首次计价那一行 `old_unit_price` 本就是 NULL,于是"那天还没有价"诚实地是 NULL,
不会被今天的价顶上去。**残余的含糊(D 早于某一天,而那天有一笔事务改了两次以上)
写在函数注释里,而不是假装没有** —— 真要消除它,得给那张表加一列序号。

**这与本文件反复说的那条是同一族:先问这个判据读的是哪一份真源。**
那里问的是"读的是不是同一份";这里问的是"那份真源里,到底有没有你要的那个事实"。

## Adding a column to a masked table: extend the grant, or it is invisible

`perm2b` converted the masked tables to **column-list** SELECT grants
(`REVOKE SELECT ON t; GRANT SELECT (a, b, c) ON t`). PostgreSQL treats the two
verbs differently, and this asymmetry is the whole hazard:

* table-level **INSERT/UPDATE** grants *auto-extend* to columns added later;
* a column-list **SELECT** grant does **not** — the list is frozen.

So `ALTER TABLE ... ADD COLUMN` on a masked table produces a column the app can
write but cannot read. Every query selecting it, **or merely filtering on it**,
fails `42501`. FIN-6 did exactly this to `processing_cost_entries`, and
`/finance/processing-costs` plus the month-end cost step were empty from the day
they shipped, with every gate green.

**Adding a column to a masked table therefore means, in the same migration:**
1. add it to the column-list SELECT grant (non-sensitive), or deliberately leave
   it out (sensitive — readable only through the `_masked` view); and
2. add it to the `<table>_masked` view.

`db/gate.py` now asserts this (`colgrant` line, both live and rebuild): every
column of a masked table must be either SELECT-granted or present in the masked
view. Anything else is named and fails the gate. `check_mirrors` cannot see it —
it does not compare GRANTs — which is why the check lives in the gate.

**It is THREE changes, and they belong in ONE migration** (WO-1a, 2026-08-16):
the `ADD COLUMN`, the column-list `GRANT SELECT`, and the `_masked` view. WO-1a
split them across three migrations and **each step looked complete on its own** —
the DDL landed (column writable, `has_column_privilege(...)` measured `false`),
`fu1` added the grant and the gate was *still* red because `colgrant`'s predicate
is `(NOT granted AND NOT in_view) OR (has_view AND NOT in_view)`: **once a table
has a `_masked` companion, every column must be in that view, grant or no grant.**
`fu2` closed it.

The documentation above was already there and already clear; what was missing was
a check that fires at the right *time*. **That pre-flight scan now exists (CHECK-1,
2026-08-31) — the QUEUED note that stood here is retired.**

`db/preflight_migration.py` prints a **`masked`** line and **refuses (exit 2)** when
a migration `ADD COLUMN`s onto a table that has a `_masked` companion on live without
putting the column into that view in the same migration. Historical replay, run before
trusting it: the two defective main-cut migrations
(`procwire1bi`, `proc1biii`) are refused and all three columns named, while both `fu1`
migrations pass. Sweeping all 33 migrations dated 2026-08-30/31 refuses **three** and
passes the other 30 — and the third is a **fourth occurrence nobody had counted**:
`cmpl1` added four columns to `inbound_batches` and `cmpl1-fu2` cleaned up after it.
So the tally in this section is **four in three days, not three**.

**Two corrections to how this gap was described, because believing either of them
produces the wrong check:**

* **`colgrant` was never blind to this.** It catches all four, on both live and
  rebuild. The defect is **earliness**, not coverage — it fires after the DDL is
  already on live, which is why each occurrence cost a follow-up migration and a
  window where the column was writable and unreadable.
* **"Missing from the grant" is NOT the failure.** A masked price column is
  ungranted *on purpose* and shows through a `has_permission` CASE in the view.
  The rule is the one `colgrant` already states —
  `(granted OR in_view) AND (has_view → in_view)` — which for a masked table
  collapses to **the column must be in the view**, grant or no grant. A pre-flight
  stricter than the gate would refuse migrations the gate would pass, and people
  would learn to run `PREFLIGHT=0`; **a check people switch off is worse than no
  check.**

**A third checker covers the half neither of those can see:**
`scripts/check-masked-columns.mjs` (in `npm run build`, no database, sub-second)
compares `db/tables/*.sql` against `db/views/*_masked.sql` — it catches a grant that
landed on live but was never written back into the mirror, which would ship a fresh
install with the defect built in. It walks from the **table** side (files carrying
`REVOKE SELECT`), not the view side: the first draft iterated the view files, and
deleting a `_masked.sql` merely shrank the comparison and still reported clean.
Current state: **27 masked tables, 412 columns, zero violations** — 24 with a
`_masked` companion (every column must be in the view) and 3 masked by column list
only (`approval_log`, `notifications`, `po_issues` — every column must be in the
GRANT, the same formula with `in_view` false).

**Name them apart, and keep them apart:** `colgrant` (live, late) ·
`masked` (migration, early, refuses) · `masked-columns` (repo, fast).

### `check-masked-reads` 此前看不见 select 串里的【内嵌】(CHECK-1,2026-08-31)

`scripts/check-masked-reads.mjs` 认的是 `.from('<表>')` 字面量。而 PostgREST 还有
另一条读同一张表的路 —— 把表名写进 select 串当内嵌关系:

```ts
.select('id, code, processing_outputs ( unit_cost_base )')   // ← 一个字都不经过 .from()
```

**那条路整个是隐形的**,而它的代价是实测的:`/inventory/output/[materialId]` 内嵌
`processing_outputs` 基表,于是整条查询**对每一个真实用户返回 42501**,页面上的
`?? []` 把它吞成空列表 —— **屏幕上平静地写着「没有库存」,而库里有 6 批。门全绿。**

现在两条路都认,判词相同(**改读 `<表>_masked`**),并且改法可行不是理论:
FX-DISPLAY-1 实测换成 `processing_outputs_masked ( … )` 之后同一条查询 200。
落地时在册 **10 处**,进基线(键带 `:: embed` 后缀,与直连分开计数 —— 合成一个数
会让"改好一处直连、同时新增一处内嵌"互相抵消)。**这 10 处是债,不是覆盖**,
逐条列在 `docs/known-issues.md` 的 CHECK-1-EMBED,去处 cleanup A。
**注意扫描前要剥掉整行注释**:`.select(` 与字符串之间可以夹着注释,
第一版没剥,于是**恰好漏掉了被拿来当例子的那个文件**。

### `colgrant` asked half the question — `colreader` asks the other half (OPS-13)

**`colgrant` inspects the STATE of a column; it never asks WHO READS IT.** A
`security_invoker` view that selects a deliberately-revoked column satisfies both
of its branches — the column *is* revoked and *is* in the masked view — so the
verdict stays green while **every authenticated caller gets `42501`**.

`processing_cost_variance` was exactly this, and had never worked since the day it
shipped: the page returned a clean HTTP 200 with an empty table, because the
page's `?? []` swallowed the error and the route smoke test asserts 2xx. Three
checks looked straight at it and saw nothing.

The `colreader` line closes it, on both live and rebuild: for every
`security_invoker` view, every column it depends on must be readable by
`authenticated`. It uses `pg_depend`'s **column-level** records
(`refobjsubid > 0`) rather than parsing SQL — which columns a view references is
a catalog fact. Owner-rights views reading revoked columns are **not** flagged;
that is precisely what the `_masked` views are for.

**Two traps worth knowing, both hit while writing it:**

* `security_invoker` is stored in `reloptions` as **`'on'` or `'true'`**. Matching
  only one silently examines a subset — the first draft checked 1 view out of 15
  and reported clean, which is the very failure the check exists to remove.
* It records a view's *direct* dependencies. Invoker view A over invoker view B
  over a revoked column names **B**, not A; fixing B fixes A, so the count of
  affected views can exceed the count of named ones.

**The fix for anything it names** is the one `cost-variance` got: owner rights,
with **both** doors written back into the view body — the module predicate *and*
the data-class predicate. Owner rights bypass the column grant, so omitting the
second hands restricted values to anyone who can enter the module.

### 属主权限视图替得了【表】,替不了【函数的 EXECUTE】

**`security_invoker = off` 让视图对它引用的表/视图用【视图属主】的权限。视图体里
调用函数时,`EXECUTE` 仍然按【当前用户】判 —— 属主替换不覆盖函数执行权限。**

所以"属主视图 + 体内调一个已收权的函数"这个组合【行不通】:读者会撞上
`42501 permission denied for function …`。要么那个函数对读者可执行(那它就不能是
靠"调不到"把关的内层函数),要么把判据放进一张【基视图】—— 视图引用视图【是】
走属主替换的,再由带 `has_permission` 的外层视图去读它。

**这条已经被发现三次,而它此前只写在学到它的那两个对象上,所以第三次又是从头查的:**

* `db/views/customer_credit_status.sql` 的表注释(SAL-B4/B6):敞口因此走
  【有检查的外壳】`customer_ar_exposure_visible`,不走被收权的内层算子;
* `db/migrations/2026-08-10-asy1b-guard-is-invoker.sql`:同一件事在触发器守卫上
  的版本;
* RPT-1(2026-08-13):判据放进被收权的 SQL 函数、由属主视图调用,
  `/inventory/reports/violations` 当场 500 —— 冒烟查出来的,改法就是上面那张基视图
  (`stock_class_violations_all`)。

**判据一句话:属主视图里出现函数调用时,先问"读者能不能执行它"。**

### `colreader` asked about COLUMNS — `xmodule` asks about ROWS (OPS-14)

**A `security_invoker` view that joins tables from more than one module does not
restrict; it lies.**

`colreader` asks whether the *columns* an invoker view reads are readable — if not,
`42501`, loud. `xmodule` asks the other half: whether the *rows* are readable. If
not, they **vanish silently**. An inner join drops the whole row, an outer join
nulls it, an aggregate counts it as zero — and the view's derived columns are
computed from exactly those rows. No error is raised. **Every reader gets a
different answer, and nothing says so.**

The survey found **11 of 15** invoker views spanning modules, and **five were
already wrong on live** (all probed, all rolled back):

* `processing_run_allocation_status` — `safe_to_reallocate` was `true` as postgres
  and **`NULL` as `operations`**; the run page branches on that boolean and `NULL`
  is falsy, so a run that was perfectly safe wore the **red** "cannot re-allocate"
  banner. And `price_history` is `module.inbound.view` — it is one of three
  staleness sources, so `is_stale` **under-reported**: a stale run read as fresh.
* `purchase_order_status` — PO prepayment read **35,000.00** as `admin` and
  **0.00** as `procurement`.
* `ap_open_items` — a payable 30,000 settled read as **0 settled / fully open** to
  `procurement`.
* `hr_alerts` — `system_start_not_set` is written `NOT EXISTS (SELECT 1 FROM
  finance_settings …)`. The row vanishes for a non-finance reader, so the condition
  is **vacuously true**: the date *was* set, and the `hr` role saw a permanent false
  alarm **it could never clear**, because the table driving it was unreadable.
  Note the direction — a vanishing row produced a **false positive** here and a
  false negative above. Same disease, both ways.
* `batch_assay_status` — `INNER JOIN suppliers`: **10 rows as `admin`, 0 as
  `warehouse`**, who can see all 10 batches. The inbound list uses it for the
  "unapplied assay" badge, so those roles were never told.

**Two remedies, not interchangeable:**

| the borrowed columns are… | remedy |
|---|---|
| **derived facts** — a count, a boolean, a timestamp, a display label | **(a)** owner rights, with the reader's *own* module predicate in the body; the cross-module columns are then computed with owner privileges |
| **money** | **(b)** the arm the reader cannot see is **ABSENT, not wrong** — either the whole view carries the finance predicate (when the row's *existence* is a finance computation, as in `ap_open_items`, whose `WHERE open_ccy > 0` *is* one), or the individual amounts are masked to `NULL` (`purchase_order_status`), which the `_masked`/`MaskedValue` idiom already renders as 「受限」 |

**`0.00` and 「受限」 are not the same thing. The first is a lie.** That distinction
is the whole of remedy (b), and it is why a page reading these views must check the
permission code rather than `?? 0` — see `lib/permissions.ts`, whose entire reason
for existing is that `null` already means something else.

### 拒绝要用哪个值表示 —— 判据是【NULL 有没有主】,不是返回类型(CLEANUP-A,2026-08-31)

这一族的解法被**写错过一次**,而且错得看起来对。一份委托书把判据写成
**返回类型**:「有返回值的返回 `NULL`,`RETURNS void` 的改成 `RAISE`」。
照它做,六个对象里有三个会把缺陷原样装回去 —— 而那一刀里**一个 `void` 都没有**。

> ### ★ 正确的判据:**这支函数的 `NULL` 是不是【已经有主】了?**
>
> 「已经有主」= `NULL` 已经在表达一个**合法状态**,而且**有人在读它**。
> 若是,那么让"无权限"也返回 `NULL`,就是**把拒绝伪装成一个合法答案**:
> 它会渲染成那个合法状态,于是没有任何人、任何时候会看见它。
> **这与"返回 0"是同一个缺陷,只是换了一件衣服。这一类必须 `RAISE`。**

实测出来的三个「NULL 已经有主」:

| 对象 | 它的 `NULL` 本来是什么意思 | 谁在读那个意思 |
|---|---|---|
| `inbound_batch_landed_unit_cost` | 「这批货真的没有金额」 | `inbound_batch_valuation.unpriced` **就定义为**它 `IS NULL` |
| `resolve_review_reviewer` | 「解析不出评估人」 | `hr_alerts` 的 `review_no_reviewer` 一支专门等它 |
| `previewLeaveDays`(前端) | 「两头日期还没填全」 | `LeaveForm` 把它印成 `—` |

「NULL 没有主」的那一类,`NULL` 才是可用的"受限"信号 —— `bank_book_balance_asof`
与 `attendance_unpaid_days` 都 `COALESCE(…, 0)`,今天**根本产生不出 `NULL`**,
所以那个值是空着的,可以拿来用。

`RETURNS void` 仍然必须 `RAISE`,但那只是本判据的一个**推论**,不是判据本身:
一支 void 函数的"沉默"与"成功"是同一个字节,所以它的 `NULL` 永远有主。
按推论去套,遇到上表这种"有返回值、但 NULL 已经有主"的形状就会套错。

**返回集合的函数同理**:`RETURNS TABLE` 的"受限"若表示成**零行**,与"本来就没有数据"
分不开;而**视图连 `RAISE` 都做不到**,所以视图这一层的解法是
**壳 + `SECURITY DEFINER` 取数体**(先例:`INV-VAL-1-fu6` 的
`inbound_batch_valuation_rows`,CLEANUP-A 的 `bank_reconciliation_rows` /
`bank_reconciliation_record_rows` / `attendance_period_status_rows`)。

**改这一族之前,先问三个问题,并且【量】出答案,不要推:**
1. 这支函数的 `NULL` 今天产生得出来吗?产生得出来的话,谁在读它、读成什么意思?
2. 谁对它的结果做**算术**?`sum()` 会**跳过 `NULL`**,于是一个 `NULL` 不会变成
   `NULL`,而是让那一项**从合计里消失** —— 报表只是"小一点"(PROC-COST-2 量到
   750.00 → 0.00;CLEANUP-A 在 `attendance_period_status` 上遇到同一个形状)。
3. 加了判据之后,**有没有一条合法的路被新打断**?这是反方向的失败,必须实测:
   `attendance_unpaid_days` 的白名单里那句 `OR p_employee_id = current_user_employee()`
   就是量出来的 —— `leave_requests` 有一条 `select own rows` 策略,一个**零权限的员工
   今天正确地读到自己的 2.00 天**,只写 `module.hr.view` 会把它打断。

**Owner rights do not widen the module boundary here.** The `_masked` companions
these views read are themselves owner-rights views gated by `has_permission()`, and
`has_permission()` is `SECURITY DEFINER` resolving `auth.uid()` — it answers about
the **caller**, no matter who owns the outer view. So converting an invoker view to
owner rights leaves module and data-class gating untouched; the only thing that
changes is that RLS base tables stop dropping rows.

**What `xmodule` cannot see** — stated so a green line is not read as "clean
everywhere". When the second module arrives through an **owner-rights view**
(`<table>_masked`) rather than an RLS base table, `pg_policy` never sees it and the
view counts as single-module. `po_prepayment_applicable` is exactly that shape and
was fixed by hand in OPS-14; the check will not catch the next one. Masked views are
deliberately excluded because their gating is a `has_permission()` predicate — it
resolves per caller and never drops rows silently, which is the *intended*
mechanism, not the disease.

**Measured, so the gap is a size rather than a worry (2026-08-09).** Six views reach
a module *only* through another view: `employee_directory` (hr → hides finance),
`ap_open_items` (hides inbound), `batch_assay_status` (hides purchasing+pricing),
`po_prepayment_applicable`, `po_receivable_lines` and `purchase_order_status` (each
hides purchasing+inbound). **Five of the six are owner rights after OPS-14, so they
are immune by construction** — the disease needs invoker semantics. The one that is
still `security_invoker` is `employee_directory`, and it was probed rather than
assumed: an `hr`-only reader gets **the row, with `current_gross_pay` NULL** — that
is `data.view_pay` masking working correctly, not row loss — and a
`finance+view_pay` reader gets zero rows because `employees_masked` gates on
`module.hr.view`. Its hidden finance branch is an `OR` that only *widens*. So the
blind spot is **bounded at one view today and that view is not defective — but the
mechanism is general**: any new invoker view over a `_masked` view inherits it.
The cheap defence is to prefer owner rights for anything cross-module, which is what
the remedy table above already says.

**Two traps, both inherited from OPS-13 and both re-verified before trusting a
zero:** `security_invoker` is spelled `'on'` **or** `'true'` in `reloptions`, and
`processing_metal_recovery` is the repo's lone `'true'` — matching only `'on'`
examines 14 of 15 and reports clean. And the check reports **direct** dependencies
only. `check_xmodule_views()` therefore returns the number of invoker views and
base-table dependencies it actually examined, and the gate **fails** if either is
zero: *a zero must be a measurement, not an absence.*

**The behavioural half is fixture 26**, and it is worth knowing why it exists
separately: `xmodule` checks the *shape*, the fixture checks the *answer* — same
row, different reader, same result. Neither subsumes the other, because the shape
check cannot see a predicate missing from an owner-rights view, and the fixture
cannot see a view nobody reads yet.

### A fixture can be thorough about a rule and blind to the case where the rule's SUBJECT IS ABSENT

`db/fixtures/39` tests the credit limit from every angle that occurred to its author: NULL limit
versus zero limit, base currency versus document currency, cumulative exposure, hold with no
exposure, the history rows, the dashboard arm. **Every one of its arms passes an explicit
customer.** None asks what happens when there is no customer at all — and the answer was that
`record_output_sale` skips the entire credit block (`IF p_customer_id IS NOT NULL THEN`), so an
ownerless sale of any size is never checked. A 1,397 sale against a 1,000 limit went through, and
the fixture stayed green because the situation it created was one the fixture never described.

**This is not the empty-set vacuity already listed above.** There, the set was empty and the
assertion looped over nothing. Here the set is full, the arithmetic is exercised, the refusals fire
— and the *subject the rule is about* is missing, so the rule is not reached at all. A test suite
shaped entirely around "the rule applies, does it apply correctly?" cannot see "does the rule apply
at all?".

**The check to run on any new rule: what is this rule's subject, and is that subject optional?**
If a customer, a supplier, an employee, a batch or a formula can be NULL on the row the rule guards,
there must be an arm for the NULL. Its assertion is usually not "it refuses" — the ownerless sale is
legitimate and must be *allowed* (SAL-C) — but the fixture must state which of the two it is, because
otherwise the behaviour is whatever the guard's opening `IF` happens to do, and nobody has read it.

The same question applies to the fix: SAL-C's `attribute_sale_customer` exists precisely because
the subject can be absent and later become known, and its fixture arms cover *both* the absence
(recorded without a check) and the transition (attached, logged, exposure moves, one-way).

> **Fixtures run as `postgres`, which BYPASSES RLS.** The first draft of fixture 26
> did not switch roles, so arms A and C were **vacuous** — the fault injection turned
> `processing_run_allocation_status` back into an invoker view, `xmodule` went red,
> and the fixture stayed **green**. Any fixture asserting an RLS-dependent behaviour
> must `EXECUTE 'SET LOCAL ROLE authenticated'` around each read and `RESET ROLE`
> after. `has_permission()` needs no role switch — it reads `request.jwt.claims` —
> which is precisely why the two arms that used it worked and the two that needed RLS
> did not. Same shape as FIN-30's vacuous third arm.

## Four standing decisions about what the permission model actually protects

Tim's calls, recorded here rather than re-argued each time a screen needs a number.

### 1 · `module.finance.view` IMPLIES price visibility

**The general ledger is the price data.** `journal_lines`, `journal_entries`,
`expenses`, `payments` and `accounts` carry **no column-list SELECT grant** — perm2b
never revoked them. Probed with a role holding `module.finance.view` and nothing
else: `sales_records_masked` returns `unit_price = null`, `amount_base = null`, while
`SUM` over account 4000 returns **33,176.00**, with unmasked quantities beside it.

Masking prices from someone who can read every journal line is **theatre**. So the
boundary is stated rather than patched: **a reader with `module.finance.view` may see
prices.** Same argument already accepted when `data.view_pay` was granted to finance.

Two consequences, both load-bearing:

* **`data.view_prices` is a control for NON-finance roles only.** It is what keeps
  `operations` and `warehouse` from seeing purchase prices on the floor; it is not,
  and never was, a second lock on someone already inside the books.
* **The GL's lack of column masking is ACCEPTED, not a hole to close.** Do not
  "fix" it by revoking columns on `journal_lines` — that would break the P&L, the
  balance sheet, the cash-flow statement and the journal screen to buy a distinction
  the ledger cannot keep anyway.

### 2 · A batch-margin view is owner rights with `data.view_prices AND (module.finance.view OR module.processing.view)`

Decided before it is built, because the shape of the predicate is the whole question.
Revenue lives behind finance, allocated cost behind processing, and **no live role
holds both** — probed: the `finance` role sees 4 revenue rows and **zero** cost rows,
so the number Doc 2 calls the one the business most needs is invisible to the role
whose job it is. The `OR` is the point.

### 4 · 「谁能看见什么」只有【一个求值器】,而进不去要【说出来】(NAV-REG-1,2026-09-01)

Tim 的 R1 与 D5,落在 `lib/modules.ts`。细节见 `docs/nav-registry.md`;这里只留必须
先知道的三条:

* **求值只在 `lib/modules.ts` 的 `allows(spec, perms)` 里。** 任何别的地方拿权限码去
  比对一份权限清单,`npm run build` 会红(`scripts/check-permission-predicate.mjs`)。
  单码判断走 `lib/permissions.ts` 的 `can()`,它是 `allows()` 字符串分支的同义写法。
  **理由是实测的**:EQP-2d 之前库里与首页各有一份判断,库里加了放宽而首页没跟上,
  于是一个【拿得到行】的读者在屏幕上看见「受限」。一条规则两个实现,迟早各错一次。
* **谓词的形状不许再造第四种方言**:`(all 全有 OR widen 任一) AND (any 未声明 OR any 任一)`
  —— 与库里的 `arm_permission_any` / `arm_permission_widen` 逐字同形。
  `any` 收窄、`widen` 放宽,两个名字很像而方向相反。
* **一个功能可以属于好几个模块**:在 `FUNCTIONS` 里声明 `modules: [...]` 与【一份】
  `permission`,属主模块的界面用 `getFunctionAccess(模块 href)` 画入口,页面用
  `requireFunction(FN.x)` 把关 —— **注册表是权威的,页面靠不表达来服从**。
  在每个属主模块的页面里手写一个 `<Link>`,正是本条要排除的东西。
* **进不去的模块渲染成「受限」,不是消失。** `getModuleAccess()` 返回【全部】模块 +
  `allowed`,不过滤。措辞固定用 `common.restricted` + `dashboard.restrictedHint`。
  下一个读到这里的人:**不要把过滤加回来** —— 返回全部不是遗漏,是这条决定本身。

### 3 · A master-data display LABEL follows the document, not the module

A label identifying the counterparty is **a property of the document, not a separate
secret**. If you may see the payable, you may see whose it is. Withholding the name
while showing the amount controls nothing — and dropping the row entirely, which is
what OPS-14 found (`0` rows against `10`), is actively wrong.

**The boundary, so this does not become a general licence: only the display LABEL
follows the row.** Substantive master-data attributes — bank accounts, credit terms,
price files, contact details — do **not**, and stay behind their own module. OPS-14
audited all six affected views and each borrowed exactly `legal_name` / `name` plus a
join key. **If a view ever borrows more than a name, report it rather than folding it
in.**

Rejected, with the reason on record: LEFT JOIN with the name left `NULL`. A blank name
reads as **missing data**, not as a permission answer — the exact failure mode
`lib/permissions.ts` exists to prevent.

## Dates and amounts that decide a period: required, never defaulted

A field that decides an **FX rate**, a **posting period**, or an **amount**
needs BOTH guards, and they are the mechanism:

1. the submit control is **disabled while the value is empty**, and
2. the **server action rejects empty independently**, so bypassing the UI
   cannot post.

(A UI-only `required`/`onBlur` is a third layer, not the protection. React
never compares a controlled input's value prop against the live DOM, so a
field can display a date the app does not have — that is exactly how the
cost-settlement bug submitted `""` from a filled-looking box.)

**Never give these a server-side default.** `COALESCE(p_date, CURRENT_DATE)`
substituting today is the failure mode, not the fallback: today's date can
never hit `PERIOD_LOCKED`, so entering the correct closed-period date fails
loudly while leaving the field blank glides into the open month. The path
rewards leaving it empty. Full inventory in
`docs/empty-string-to-rpc-audit.md`.

### The `CURRENT_DATE` defaults are gone (FIN-10)

This section used to warn against "tidying" five call sites into
`|| undefined`, because each sat on a `COALESCE(..., CURRENT_DATE)` that
would turn a visible error into a silently wrong period. **Those defaults
have been removed.** Eleven functions now raise a named error instead:
`PAYMENT_DATE_REQUIRED`, `EXPENSE_DATE_REQUIRED`, `SALE_DATE_REQUIRED`,
`PROCESS_DATE_REQUIRED`, `ORDER_DATE_REQUIRED`, `REFERENCE_DATE_REQUIRED`,
`REVERSAL_DATE_REQUIRED`.

So the trap is gone rather than documented — which is the point. If you add
a new function whose date decides a posting period or a rate, **do not give
it a `CURRENT_DATE` default**; make it required and raise a named error.
Defaults that genuinely belong (code-numbering years, `p_as_of` read
queries, `create_invoice`) are listed in
`docs/empty-string-to-rpc-audit.md` so the distinction is on the record.

## 故障注入的还原完整性:用 `db/injection_probe.py`,不要靠 restore() 记得住

**一张故障注入矩阵的每一格都假设:这一格看到的库与基线只差我刚注入的那一处。**
那个假设由手写的 `restore()` 撑着,而**漏一句,后面每一格都跑在被污染的库上,
不会有任何东西报错。**

实际发生过:EQP-2b 的注入脚本里 F3 执行
`ALTER TABLE equipment_maintenance ALTER COLUMN downtime_id SET NOT NULL`,
而 `restore()` 里没有对应的 `DROP NOT NULL` —— F4/F5/F6 全跑在一张被改过的表上。
下一版脚本补上了,旁边写着"上一轮就是漏了这两句"。**它是被人读出来的,
不是被任何检查抓到的。** 连着两刀栽在同一处之后的结论是"这里需要一张清单",
而本仓库对"需要一张清单"的处置是把它换成机制。

```python
import sys; sys.path.insert(0, 'db')
from injection_probe import Pristine
P = Pristine(DSN, ['public.t', 'public.v', 'public.f(text)']).capture()   # 任何注入之前
for name, what, sql in CASES:
    restore(); P.assert_clean(what)      # ← 下一格开跑之前,先证明库是干净的
    run_sql(sql); ...
```

**判据是比【定义】,不是比"我记得改过什么"** —— 后者会和 `restore()` 犯同一个错。
表比列/约束/索引/RLS/策略,视图比 `pg_get_viewdef` **加 `reloptions`**
(viewdef 不吐 `WITH (…)`,本文件为此记过一次 `security_invoker`),函数比 `functiondef`。
不一致就当场退出并点名那个对象。**故障注入过**:复刻上面那次漏还原,probe 当场停下。

**它住在仓库里,而注入脚本住在仓库外面** —— 后者一刀一份、用完即弃,
那正是 `restore()` 被复制、同一个疏漏被犯两次的原因。共享的那一半必须留下来。

## A verdict that reports but does not enforce is not a gate

**Whatever verdict you add next, the first thing you do is make it fail on
purpose and confirm `db/gate.py` stops.** Not "read the output and see the
warning" — confirm the exit code is non-zero and the run is red.

This is not hypothetical. `verify_rebuild` has returned **3** for a failed
B1/B2 invariant assertion since OPS-5, and `db/gate.py` branched only on 1 and
2 — so 3 fell through `structural_drift = (3 == 1)` and **the gate exited 0
while printing a violation**. It did exactly that on 2026-08-04: the run
printed `B1 VIOLATION … anon can EXECUTE it` and passed. The violation got
fixed because a human read the output, which is precisely the property a gate
is supposed to remove. Nobody had ever made that verdict fail on purpose, so
nobody knew it did not bite.

The fixtures verdict (exit 4) was fault-injected before being trusted: fixture
07's lock date was inverted, the gate returned 4 and named the fixture. Do the
same for the next one. A check never observed failing is not known to work —
it is only known to be quiet.

### The same disease inside a REPORT: a self-check that compares a number with itself

The rule above is about gates. **A statement that claims to check itself is the
same thing wearing accounting clothes**, and OPS-17 found one: FIN-30's
`cash_flow_statement.ties` compared `closing_cash` against
`closing_cash_balance_sheet` — both computed **in the same function body, from the
same arithmetic, under the same filter**. When the filter was wrong both sides
were wrong together, so the check reported `true` while the number was off by
1,166.98. It shipped described as making the statement "self-checking".

**Two sides are only a check if they can move apart.** Ask it explicitly of any
`ties` / `balanced` / `reconciles` flag: *what would have to be true for these two
to differ?* If the answer names nothing, the flag is decoration. The fix is the
one OPS-17 made — point one side at a genuinely separate implementation
(`balance_sheet(p_to)`), then **reintroduce the original defect and watch the flag
go false**. It did, on all three probed periods.

**The survey OPS-17 ran, so the class is bounded rather than worried about
(2026-08-09).** Every comparison of this shape in `db/functions` and `db/views`:

| site | two sides independent? | can it fail? |
|---|---|---|
| `cash_flow_statement.ties` | **now yes** — `balance_sheet()` is a separate function | yes, fault-injected |
| `preview_close_financial_year.trial_balanced` | yes — `SUM(debit)` vs `SUM(credit)`, different columns | **no, structurally**: `trg_journal_lines_balance` is a DEFERRABLE constraint trigger enforcing Σd=Σc per entry at commit, so committed data cannot fail it |
| `balance_sheet.balanced` | yes — assets vs liabilities+equity+earnings, disjoint account sets | **no, structurally**: same trigger, same reason (the identity follows from Σ(debit−credit)=0 over all accounts) |
| `allocate_processing_costs` → `ALLOCATION_LEDGER_DIVERGED` | yes — a stored `capitalized_cost_base` vs the capitalisation entry's **status in the GL** | yes; it is the one remaining red by design |
| `preview_close_financial_year.revaluation_level` / `.depreciation_level` | n/a — **not comparisons**: readiness flags read off one derivation | n/a |
| `revalue_foreign_balances`, `close_financial_year`, `depreciate_fixed_assets` calling their previews | n/a — **one implementation, two callers**, which is the intended pattern | n/a — there is no second derivation to drift |

#### 一个带【兜底桶】的分项分解,会把余额逼成零 —— 同一个病的第三种穿法(GLEXPORT-1,2026-08-28)

**上面两种是「两边其实是一边」与「不变量在上游已经被保证」。第三种长这样:
把一个差额拆成几个分项,再留一个"其他"兜底桶接住剩下的 —— 于是
各分项之和【恒等于】那个差额,而"未解释余额"永远是 0。**

它比前两种更容易写出来,因为兜底桶看起来像是【稳健】:不管来源表将来长出什么
新值,分类都不会漏。而那恰恰是它的害处 —— **它把"我没想到的那一类"变成了
"没有那一类"**。

GLEXPORT-1 的控制科目勾稽差点就是这样。修法是把兜底桶**去掉**:
只声明式地扣掉三类(起单 / 结算 / 重估),任何**没有被分类的来源**
(`manual`、`year_close`、`writeoff`、以及将来新增的任何 `source_type`)
原样留在余额里。于是它动得开,而且动的方向正是要紧的那个 ——
**一笔直接打进控制科目的手工分录,正是现实中把明细账与总账弄散的头号原因。**

> **判据一句话:把你的分项加起来,能不能【按构造】等于那个差额?
> 能,就说明余额是装饰。** 让它等不了 —— 留一类东西是分类不认识的。

#### `source_id` 在【冲销件】上指的是【原分录】,不是原单据(GLEXPORT-1,2026-08-28)

**`reverse_journal_entry_internal` 建冲销件时,`source_type` 照抄原件,而
`source_id` 填的是 `v_orig.id` —— 那张【原分录】的 id,不是原单据的 id。**

于是任何"按单据归集总账"的写法:

```sql
WHERE e.source_id = <单据 id>          -- ← 只命中原件,漏掉它的冲销件
```

**只会命中原件、漏掉冲销件**,而它算得出数、不报错。实测(2026-08-28):
`IN-2026-0001` 的计价分录被冲销过,按上面这句归集得到 **−247,296**,
而它在总账上的真实净额是 **0**。差了一整笔,方向还是反的。

**处置有两条,选哪条取决于你要的是什么:**
* 要【按单据】看:得走两跳 ——
  `source_id IN (SELECT id FROM journal_entries WHERE source_id = <单据>)`
  把冲销件也捞进来(它们的 source_id 指着原件);
* 要【按类别】看:改用 `source_type` 分类,不碰 source_id。
  GLEXPORT-1 的控制科目勾稽走的是这一条 —— 它要的本来就是分类,不是逐单据。

**为什么记在这里而不是记在那支函数上:** 读到这条陷阱的人不会是正在改
`reverse_journal_entry_internal` 的人,而是正在写一句 `WHERE source_id = …`
的人 —— 而那句话遍布全库。

Note the second and third rows are a **different** failure from the first, and worth
naming separately: they are not self-comparisons, they are **guaranteed-true** — the
invariant they assert is already enforced upstream. That is not a defect (they cost
nothing and they guard against a direct-INSERT path that bypasses the writer), but
neither should anyone read a green `balanced` as evidence that the aggregation is
right. It is evidence that double-entry held, which the database already knew.

## Entitlement is DERIVED; consumption is RECORDED — so a fresh database gives everything away

This is the shape behind every fresh-install bug we have found, and it makes the
list predictable instead of remembered:

> An **entitlement** is computed from first principles — a policy figure, a rate,
> a hire date. A **consumption** exists only because someone recorded a row.
> A rebuilt database carries the principles perfectly and the records not at all.
> So every entitlement resets to full while every obligation against it vanishes.

The asymmetry is the whole problem. Both halves being missing would be visibly
wrong; only the recorded half being missing looks *exactly like a new employee
with a clean slate*, and produces a plausible number with no error.

Instances found so far, all the same shape:

* **annual leave carry-forward** — accrual runs from hire date whether or not
  this database was operating that year, so a 2020 hire gets a full year
  conjured out of a year that never happened here (HR-5, now refuses);
* **medical claim limit** — the annual allowance is derived from
  `hr_settings`, consumption comes from `medical_claims` rows, so pre-cutover
  claims are invisible and the *entire* allowance becomes available again.
  Worse than display: `decide_medical_claim` gates approval on that figure, so
  it approves claims it should refuse (HR-6, now bounded);
* **monthly leave accrual** when the start date falls mid-year — accrues
  January onward for months this database did not cover. **Closed by HR-7**:
  `accrued_annual_leave_detail` now takes `GREATEST` of all THREE dates — hire
  month, leave-year start, and `system_start_date` — in ONE comparison. Never
  stacked reductions: HR-6's medical limit is the proof of why, where cutting
  once by hire month and again by start month turned 3 months into 1 and 300
  into 100. Fixture 24 asserts both directions (hire Mar / start Oct, and hire
  Oct / start Mar) reaching the SAME answer — that symmetry is what distinguishes
  an intersection from an accumulation, and a stacking implementation fails it.
  Unlike HR-5 carry-forward and HR-6 medical, an unset `system_start_date` here
  does NOT refuse: this function sits on `my_profile` / `employees_masked`, so
  refusing would tell every employee their leave balance is unavailable because
  a finance setting is blank. It falls back to the two-date behaviour, reports
  `system_start_applied: false`, and `hr_alerts` raises `system_start_not_set` —
  the same disposition as `holiday_calendar_missing`. **The rule of thumb: an
  ACTION may refuse; a BALANCE someone reads about themselves must degrade and
  raise an alert instead.**

**The rule of thumb: anything computing an allowance per period is a
candidate.** A limit per year, an accrual per month, a quota per cycle — ask
what records the consumption, and whether those records exist for the whole
period. If the period is only partly covered, the derived half must be bounded
to the covered portion or refused outright; never left whole against a
consumption of zero.

`finance_settings.system_start_date` is the boundary all of these consult:
**the date from which this database holds a COMPLETE record.** Not the install
date and not necessarily the cutover date — if pre-cutover transactions are
being re-entered, it is the earliest real transaction, which can be months
earlier. It is declared rather than inferred from the earliest row, because an
inferred line moves the instant someone back-dates a document and nobody
notices. Getting it wrong raises no error; it silently puts every guard in the
wrong place.

## The third verdict: db/fixtures — does the rebuilt database WORK

`verify_rebuild` asks whether the repo can build a database and whether it
matches live. **`db/fixtures/*.sql` asks whether the thing it built behaves
correctly.** Different questions, same relationship as `check_mirrors` to
`verify_rebuild`, so it gets its own verdict and its own exit code.

```
python3 db/gate.py     # 0 clean · 1 mirror drift · 2 cannot build
                       # 3 B1/B2 invariant · 4 behavioural fixture failed
```

Twenty-five fixtures, ~128 assertions, on the paths where a silent break costs money:
settlement closing to exactly zero (including cross-currency), revaluation
idempotence, confirmation not touching leave, accrual not applying a category
change retroactively, one bank line per employee, realised 7100 never crossing
unrealised 7110, period lock, over-allocation in both currency spaces, the
bounded FX reach-back, the three `system_start_date` bounds, the database's
"today" being Singapore's today (config + semantics + both walk-observed
symptoms; a fixture cannot move the server clock, so the config arm is the
24-hour guard and the behaviour arms gain full discrimination during the
00:00–08:00 SG window), and a fully
allocated payment leaving **exactly zero** on account even when the rate moved
between booking and settlement (FIN-18 — that one asserts the *old* formula
differs too, so it cannot pass by both answers agreeing), and fixed assets
(FIN-22: depreciation from the in-service date not the acquisition date,
idempotent by arithmetic, capped at cost minus residual, non-monetary and
invisible to revaluation, disposal clearing 1500/1510 exactly, locked periods
refused by name), and year-end close (FIN-23: P&L accounts derived by
account_type never a code range — the FX arm posts to 7100 and a 4000-6999
implementation fails it; balance-sheet accounts untouched as one snapshot;
idempotent by arithmetic; the closed year's P&L still reproducible — the
report EXCLUDES year_close entries while the balance sheet INCLUDES them,
deliberately asymmetric, comments cross-referenced in both queries; the
YEAR_CLOSED guard in post_journal_entry is independent of locked_before, so
month-level reopen_period cannot pierce a closed year — the fixture's E arm
walks exactly that path; reopen reverses the closing entry with a reason and
restores the trial balance to the cent), and allocation's delta split
(FIN-24: re-allocation posts target-minus-recorded per OUTPUT BATCH — in-stock
share to 1220, sold-with-COGS share to 5000, written-off share to 5200 — the
material delta credits 5000 where repricing parks the consumed share, so the
two mechanisms compose instead of double-counting; repricing an input now
flags consuming runs stale; the one remaining red is a manually-reversed
capitalization entry, ALLOCATION_LEDGER_DIVERGED), and re-processing (FIN-25:
output batches feed further runs — two-sourced recovery arithmetic asserted
against hand-computed figures, cost relieved from 1220 not 1200, upstream
deltas propagating one edge per re-allocation through the stale flags with no
recursion, unpriced upstreams allowed but marked cost_incomplete and never
silent, reversal and self-consumption guards, and the metal_value arm on
fixture 18 that numerically separates per-batch from run-level ratios —
62.50 vs 27.50 — where the weight basis provably cannot), and PO price
provenance (FIN-26: price_source is RECORDED, never inferred from
expected_assay; a computed line carries enough to re-derive the number and
the fixture actually re-derives it; existing rows stay NULL and display as
unknown — a fabricated provenance record is worse than a blank), and committed
pricing terms (FIN-27: a formula referenced by a deal cannot change under it,
because the terms are COPIED onto the committing record and settlement reads the
copy — the fixture commits, edits the formula, settles, and asserts the
*committed* number, with the live-formula number computed alongside and asserted
to differ, so the arm cannot pass by both answers agreeing; a deal raised AFTER
the same edit uses the NEW terms, which is what stops "never update anything"
from passing too; a reference with no copy is refused BY NAME on both settlement
paths rather than silently falling back to the live formula; and a formula edit
writes an append-only history row with old and new — including the metals
sub-table, where the UI expresses "no longer payable" by DELETING the row, so a
header-only history would be silent about the most drastic edit there is).
and a payment term
template's fixed instalment (FIN-29: a template belongs to no order, so its fixed
amount had no currency at all — and `apply_payment_term_template` copies
VERBATIM, no rate is consulted, so "deposit 10,000" landed as 10,000 on a USD
order and on an SGD one alike and read correct on both. The template now declares
its own currency and a different-currency order is refused BY NAME rather than
converted — a payment term is a negotiated commitment, not a computed quantity,
the same reasoning as FIN-27. The declaration is CONDITIONAL: percentage-only
templates need no currency and must not be forced to invent one, which is what
the third arm holds — a "currency always required" implementation passes the
other three. Enforced by a guard trigger on BOTH parent and child, because the
rule spans two tables and a CHECK cannot see another table; and the validation
runs BEFORE the delete, so "refused means nothing was written" is structural
rather than a rollback artifact — the second arm asserts the order's own plan
survives the refusal intact).
and the cash flow statement (FIN-30: the hard part is
not the arithmetic, it is what counts as a cash flow. 1010 is revalued each
period end — its BASE-currency carrying value moves while no money does, and a
statement derived from base-currency movements prints that as a phantom cash
flow that balances perfectly. Revaluation is therefore a separate reconciling
line below the three sections, keyed off the entry's DECLARED source_type;
year_close is excluded, manual entries carry nothing so they are shown as their
own "unclassified" line rather than assumed operating, and which accounts are
cash / investing / financing is DECLARED on the account (`is_cash`,
`cash_flow_section`) instead of hardcoded — the year-close code-range defect
again. Self-checking: opening + sections + FX = closing, AND closing equals the
balance-sheet cash figure — **which was NOT "computed independently" until OPS-17,
though this paragraph said it was.** Both sides came out of the same function body
and the same arithmetic, so `ties` moved with the defect and could never report
false; live returned `ties=true` for all five probed periods, including one that
split a reversal pair across the period boundary. OPS-17 pointed it at
`balance_sheet(p_to)` — a different function, a different aggregation path — so the
sentence is now true. When they disagree the page says so instead of printing a
number that does not tie. Note the third arm was
VACUOUS on first write — a realistic year-close touches no cash, so it could
never enter the "entries that moved cash" set and the exclusion was untested;
deleting the filter left the fixture green. It now also posts a MALFORMED
cash-touching year-close and asserts the statement reports ties=false, which is
what makes the filter load-bearing).
and the inventory ledger's business date (FIN-32:
`business_date` is the day the thing HAPPENED, not the day it was keyed in — and
it was 58% empty, in a pattern: writeoff / reversal_void / reversal_restore were
100% empty because those paths never wrote it, and receipts were 80% empty
because they copy a nullable `arrival_date`. Both ends closed. The decision worth
knowing is the reversal's date: a rollback is NOT a physical event — batteries
that were processed stay processed — it corrects a mis-recorded run, so it takes
the ORIGINAL run's `process_date`, which makes the error and its correction
cancel on the same day and stops the intervening days showing stock that was
never really absent. Writeoff is the opposite — a real physical event — so it
takes `deleted_at::date`, read from the row rather than the clock. New rows are
required via `CHECK (...) NOT VALID`, which enforces on insert while leaving the
15 historical nulls untouched: they are history, not a bug, and backfilling them
would invent a fact nobody recorded).
Deliberately small: every retained fixture is
maintenance on every schema move, and the HR-2c accrual change already cost one
round of "is this staleness or regression?" judgement.

**Read `db/fixtures/README.md` before adding one.** Four rules, each of which
this repo learned the hard way:
1. assert invariants, not literals — and where a literal IS the assertion,
   write down how it was derived;
2. each case owns its data, no resetting between cases;
3. a failure must fail the GATE, not print a differing string;
4. depend only on STABLE bootstrap data (chart of accounts, currencies, roles,
   leave types) and never on TIME-BOUND state — `public_holidays` is seeded a
   year at a time and `finance_settings.locked_before` moves with month-end.
   Set what you need; do not inherit it.

Note the gate previously **swallowed verify_rebuild's exit 3**, so a B1/B2
invariant failure printed a violation and still exited 0. Fixed in the same
change that added verdict 4 — which is rule 3 applied to a check that predates
the rule.

## Filtering journal entries to `status='posted'`: wrong when SUMMING, right when testing ONE entry

**The rule, one line:** filtering journal entries to `status='posted'` is almost
always **wrong when you are AGGREGATING**, and almost always **right when you are
testing whether ONE entry is still live.**

**Why the aggregate case breaks.** Reversal in this system is: the original entry
flips to `status='reversed'`, and a **new, equal-and-opposite `posted` entry** is
issued (`reverse_journal_entry_internal.sql`). So `WHERE e.status='posted'`
**drops the original and keeps the reversal**, and the sum comes out to exactly
**−(the original)**. Nothing errors. The report is simply smaller — or larger —
by one entry. `journal_activity_lines` exists to forbid precisely this, and the
three reports that matter (`balance_sheet`, `pnl_statement`, `account_ledger`)
all read the rows through it rather than selecting their own.

**Why the single-entry case is fine.** "Is this one entry still live?" is a real
question with a real answer, and `posted` is the right test for it.
`guard_gst_switch` asking whether a taxed entry is still standing, and
`processing_run_allocation_status` asking whether a capitalisation entry still
holds, are both correct. So is `bank_unmatched_journal_lines`: it is the
match workbench's **candidate list**, and `match_bank_line` refuses a line whose
entry is reversed (`JL_ENTRY_REVERSED`) — the view filtering to `posted` is that
same eligibility rule, asked earlier.

**Four occurrences of the aggregate mistake so far, and it keeps coming back:**

| | where | found | state |
|---|---|---|---|
| ① | `cash_flow_statement` | OPS-17 | fixed |
| ② | `f5_return` / `f5_box_detail` | GST-2 | fixed, with the reasoning left in the function body |
| ③ | `bank_reconciliation_status.ledger_balance` | BANK-REC (2026-08-26) | fixed — **and it had been wrong on the live bank page the whole time** |
| ④ | `preview_revalue_foreign_balances` (**two** filters, not one) | BANK-REC, while fixing ③ | fixed by FXREV-1 (2026-08-27) — **and it had already posted a wrong entry: SGD 56,532.48** |

**③ was measured, not inferred (2026-08-26):** account `1010` carries 2 reversed
journal lines, so the bank page was showing **−31,338.70 where the ledger actually
says −29,753.70 — out by USD 1,585.00 in production.** `1000` happened to have no
reversals and was correct by luck, which is why nobody saw it.

**④ is the one that reached the ledger, and it is worth knowing how far.** The
misstatement was **SGD 56,532.48** on `JE-2026-0024` (FX revaluation as at
2026-07-31) — an overstated unrealised FX loss, posted because two reversed
originals on `2000` were dropped while their reversals were kept. It was
corrected forward by `JE-2026-0070` on 2026-08-27; July itself stays as it was.
Full record: `docs/fx-revaluation-misstatement-2026-07.md`.

**Two things FXREV-1 added to the rule itself:**

* **Count the filters, don't assume there is one.** This function had *two* —
  the main aggregate and a carry-forward subquery — and they fail in different
  directions, so a fixture that injects only an ordinary reversed entry passes
  while the second one is still broken. `db/fixtures/133` therefore has a
  separate arm whose injection is a **reversed revaluation entry**, which is the
  only thing that reaches the second filter.
* **`source_type = 'revaluation'` in that subquery is NOT the same kind of
  filter and must stay.** It asks "is this row a prior revaluation adjustment" —
  a semantic selection. Only the `status` half was wrong. When fixing one of
  these, separate the two questions before deleting anything.

**The lesson that outlives the four:** a defect found while building something
else is still a defect that shipped. ③ was not on anyone's list — it turned up
because BANK-REC needed to reuse that number and looked at how it was computed.
**Before reusing a number, read how it is derived.** Reusing it unread would have
built a refusal on top of a wrong figure, and the refusal would have blocked
honest reconciliations with a phantom difference.

## THE FX RULE — one rule, of which the rest are instances

> **Any amount not in the base currency converts at the rate. If no rate
> exists for that date, the system refuses and prompts for it to be
> entered. Never a fallback, never an assumption.**

Everything below is a consequence, not a separate rule. They were built one
at a time; a new screen should inherit the rule rather than rediscover it.

* **Reaching back is allowed only when the TRANSACTION DATE ITSELF is a
  non-publication day, and it must say so** (FIN-13, corrected by FIN-19).
  A Saturday transaction uses Friday's rate — that is correct, because the
  market did not publish on Saturday. **A business day with no rate on file
  refuses, exactly as an exact-match rule would.** Precisely: every day from
  the rate date (exclusive) through the transaction date **inclusive** must be
  a non-business day (weekend or active SG public holiday). A hard cap of
  **4 calendar days** backstops a mis-maintained holiday table. Beyond either,
  `fx_rate_for` raises `FX_RATE_MISSING|ccy|date|type`, unchanged.
  `fx_rate_asof` returns the rate **and the date it came from**; every screen
  showing a converted figure shows that date when it differs from the
  transaction date.
  The original FIN-0 defect was that the nearest-date lookup was **silent**,
  not that it reached back at all.

  > **How FIN-13 was wrong, because the shape recurs.** It said "every day
  > *strictly between* the rate and the transaction must be a non-business
  > day" and implemented `generate_series(v_when + 1, p_date - 1)`. For
  > **consecutive dates that interval is empty**, so the condition is
  > vacuously true and *every* business day silently accepted yesterday's
  > rate. That is the exact silent nearest-date lookup FIN-0 removed from
  > `pay_medical_claim`, reintroduced with a blessing on it — and it read as
  > a strict rule, which is why nobody re-derived it. Live proof: 5 Aug had a
  > rate, 6 Aug did not, and a 6 Aug receipt booked at 5 Aug's 1.24.
  > **A guard phrased over the interior of a range is vacuous at the
  > boundary. State such conditions over the closed range and check the
  > endpoint explicitly.** The fix was one token; finding it took a human
  > noticing a number on a screen.
  >
  > Note this also made the London/Singapore bullet below *true for the first
  > time*: before FIN-19, a UK bank holiday that SG treats as a business day
  > did not produce a conservative refusal — it silently took the previous
  > day's rate whenever one existed.
* **The London/Singapore calendar is a deliberate approximation.** Metal
  quotes follow London; the only holiday table we have is Singapore's. The
  failure mode is a false *refusal* on a UK bank holiday — conservative and
  self-announcing — never a silently wrong rate. Reasoned where the
  reach-back lives (`db/functions/fx_rate_asof.sql`).
  **METAL-3 added a second calendar to the same approximation, and its
  consequence is worth stating plainly rather than as a mechanism.** SMM quotes
  are published against Chinese market days, and `public_holidays` holds
  Singapore's. A CNY quote dated inside Golden Week or Spring Festival needs a
  CNY mid rate that nobody published, and the reach-back will not cross a run of
  days Singapore counts as working — so it refuses. The shape of that refusal is
  what matters: someone keying a week of quotes after the fact meets **a wall of
  refusals, one per day**, not a single one. It is still conservative and still
  self-announcing, and no wrong number is produced.
  **The open question, named rather than answered: should a reference rate reach
  back further than a settlement rate?** They are different risks — a settlement
  rate that is four days stale mis-states money that actually moved, while a
  reference rate that is four days stale mis-states a quote that was already an
  approximation of a market. A longer bound for `mid` might be right; it needs
  Tim's view on how far a metal quote may drift from its own conversion rate
  before the number stops meaning anything, and nobody has been asked.
* **`public_holidays` is load-bearing for two modules.** It drives
  `calculate_leave_days` (leave entitlement, silently wrong if a year is
  missing) and now `fx_rate_asof` (loudly wrong — it refuses). It is seeded
  a year at a time, so `hr_alerts` raises `holiday_calendar_missing` from
  October if next year has no rows. `is_business_day()` is the single
  definition both use.
* **Refusal is surfaced, not swallowed.** The revaluation banner names the
  date and the currencies that are missing, and disables the post button.
  Copy that shape: say what is missing, where to enter it, and disable the
  action.
* **The side is part of the rate.** Receipts convert at `tt_buy`, payments
  at `tt_sell` — `record_payment` decides it and every screen follows.
  A receipt valued at the selling rate is wrong every single time.
* **One implementation.** The screen asks the database for the rate; it
  does not compute one. See the ask-the-database rule below.
* **No `?? 0`, no `?? 1`, no defaulting to today's date** — a fabricated
  rate and a fabricated date are the same failure wearing different hats.
* **The base currency is data** (`currencies.is_base`), never a literal.
  See the currency-literal rule below.

**Known exception, deliberate and bounded:** cross-currency settlement,
where the bank actually converted. There the rate is the *actual dealt
rate* from the bank slip, not a board rate — `record_payment` requires it
and refuses to look one up. That is still the rule: the real rate, never an
assumed one.

**The metal pricing path: closed (FIN-15), and the shape of the answer is
worth keeping.** This paragraph used to read "known gap, NOT yet fixed" and
list three things. All three are settled, and only one of them turned out to
be a defect:

* **The function still does not convert — and that is correct.**
  `calculate_metal_price` is USD in, USD out: quotes are USD/tonne, treatment
  charges are USD/tonne, and it neither takes nor applies a rate. **The
  conversion belongs to the path, not the function.**
  **METAL-3 qualified this sentence, and the qualification matters: there are
  TWO conversions and only one of them belongs to the path.**
  *Output* conversion — USD → document currency, at the deal's date, on
  `tt_buy`/`tt_sell` — is the path's job (`computeLineEstimate`), exactly as
  written here, and METAL-3 did not touch it. *Input* conversion — a quote
  published in another currency (SMM in CNY) → the function's USD basis, at the
  **quote's own date**, on `mid` — happens **inside** the function, because only
  it knows which quote it picked and what day that quote is from. Converting at
  today's rate instead would make the same historical quote worth different
  amounts depending on when the screen is opened, which is restating history.
  On the `average` basis each quote converts at its own date before the mean is
  taken; averaging first would let one rate move contaminate every day in the
  window. `mid` rather than a side because a market quote is a reference price,
  not a dealt one — a bank's spread has no business inside a published figure.
  **METAL-2 made that assumption checkable instead of assumed.** Quotes now carry
  an index (`metal_prices.price_index` → `metal_price_indices`), and each index
  declares the currency it quotes in. USD-in stays true because the function
  **refuses** — `INDEX_CURRENCY_NOT_STATED|<index>` — rather than treating an
  index whose currency nobody has declared as if it were dollars. SMM ships with
  that column deliberately NULL: SMM publishes in CNY, but what *this company's*
  SMM contracts settle in is a term of the deal that Tim has not stated, and
  filling it in would be inventing one. If the answer is CNY, that is a
  `currencies` row plus a conversion path with its own "which day's rate"
  question — not a hurried rename.
  `computeLineEstimate` now converts before the number becomes a price —
  `usd_price × fx(USD) / fx(document currency)`, both legs `tt_sell` on the
  order date via `fx_rate_asof`, refusing and naming date/currency/side when a
  rate is missing. A USD document needs no special case: the two rates are the
  same and the ratio is 1. The calculator label reads `Value (USD)`, which is
  the truth — the old `(SGD)` label was the actual lie.
* **A missing quote refuses on the quoting path and still skips inside the
  function — deliberately, in both places.** METAL-2 sharpened what "missing"
  means: with two series a metal can have a perfectly good LME quote while the
  deal settles on SMM, so the refusal and the `skipped_metals` entry now name
  **which index** was empty. Without that, the message sends someone to look at
  the wrong table while the right number sits one row away. Skipping keeps one unpriced metal
  from halting production for `allocate_processing_costs`; refusing keeps a
  quote from silently going to a supplier priced too low. Same function, two
  callers, two dispositions. **Do not unify them.** Each side's comment names
  the other: `db/functions/allocate_processing_costs.sql` (first line) and
  `app/pricing/calculator/actions.ts`; `computeLineEstimate` inherits the
  refusal and points at the calculator for the reasoning.
* **`spot` reaching back to the nearest earlier price is a decision, not a
  fallback.** Metal markets do not quote at weekends, so a price series *must*
  reach back — the same reasoning as FIN-13's bounded FX reach-back. What was
  missing was never the refusal; it was saying **which date's price was used**,
  and each line now returns `price_date` (`price_from`/`price_to` for
  `average`). Reaching back silently was the defect; reaching back is not.

Full call-site inventory in `docs/currency-literals-audit.md`.

**The general lesson, which is why this paragraph was rewritten rather than
deleted:** a note describing a hazard that no longer exists is the same defect
as a comment asserting a hazard that cannot occur. It costs a reader the same
wrong belief and nothing in any gate will ever catch it. **Retire a "known
gap" in the place it lives, in the commit that closes it.**

## Currency codes are data, not constants

`'USD'` / `'SGD'` must never appear in a comparison, branch or default in
app code. The base currency comes from `currencies.is_base` via
`lib/currency.ts` (`getBaseCurrency()`, cached per request; client
components take it as a prop). The bank-account mapping lives in exactly
one file, `lib/currencyMap.ts`, mirroring `bank_native_currency()`.

`scripts/check-currency-literals.mjs` enforces it — in `npm run build`
(fast feedback) and in `db/gate.py` (`currency` line). Exceptions go in its
ALLOWLIST **with a written reason**, the same way `check_mirrors` handles
account codes and `check-i18n` handles dynamic suffixes: the list is
derived and visible, not remembered. Allowlist entries are `{path, match?,
reason}` — `match` pins the exemption to one *shape* on that path rather than
excusing the whole file.

**It checks two classes, and the second was added late (FIN-18).** The first
only ever looked at *judgements* — comparisons, branches, `??`/`||` defaults,
`{USD: …}` maps, `'SGD' AS`. But the most direct way to lie about a currency
never passes through a judgement; it is JSX body text:

```tsx
{payment.currency !== baseCurrency && <>= {formatMoney(amount_base)} USD</>}
```

That line **has the base currency in its hand** — the left side just compared
against it — and prints `USD` anyway. After FIN-0 the base is SGD, so the
screen read `= 1,736.00 USD`. No judgement pattern matched, the check reported
clean, and `db/gate.py` reported clean with it. The `jsx-text` class scans
`.tsx` for bare `USD`/`SGD` surviving after string literals and comments are
stripped; currency-picker `<option value="USD">USD</option>` is exempt
(the value and the text are the same code — that control exists to name
currencies). Adding it found **six** live instances of the identical
construction — payments list and detail, expenses list and detail, the AP
batch page and the AR document page. Two manual sweeps had missed all six.
**"Currency clean" meant less than it looked; assume the next blind spot is
whatever the check does not parse rather than whatever nobody wrote.**

Why a check and not care: FIN-0 changed the base from USD to SGD, and the
constants left behind broke four screens over four separate sweeps —
`/finance/payments` valued a base-currency payment at 0.00 and a USD one at
1:1 (FIN-12), and manual journal entry demanded an FX rate for base-currency
lines. Two full manual sweeps each missed a site. The check found 32 in one
run, including one I had just written myself.

**Message files too — and until CHECK-1 (2026-08-31) nothing scanned them.**
`check-i18n` validates that a key exists, never what it says, so `'Amount (SGD)'`
is invisible to it; and `check-currency-literals` named this as one of its three
originating causes while scanning only `app / lib / db`. **FX-DISPLAY-1's
"a USD number wearing an SGD name" lived in `messages/en.ts`, out of its reach.**
It now scans `messages/` as a fourth class (`message-text`). A label that names a
currency must take it as a `{ccy}` parameter from the row (or the base currency),
unless the string is genuinely about one currency by decision — metal prices are
quoted `USD/t` by market convention, and account names like `Bank – SGD` are proper
nouns. Those stay.

**76 instances were already there** (en 40, zh 36), so it is a **ratchet, not a
wall**: `scripts/currency-messages-baseline.json` holds today's count per
⟨file · key⟩ and the 77th turns it red — the same medicine `check-masked-reads`
took for its 71, and for the same reason (a check that reddens 76 lines on day one
teaches people to skip the gate). The report groups them **by shape** so a later
reader can tell the disease from the truth without re-deriving it: **36 `label`**
(currency baked into a column header — the FIN-0 disease), **20 `unit`**
(`USD/t`, `USD/kg`, `USD/吨` — genuinely dollars), **16 `prose`**, **4
`account-name`**. Full list in `docs/known-issues.md` under CHECK-1-MSG.

> ★ **CCY-VERIFY — a permanent limitation, not a to-do.** This check verifies that
> a currency is **stated**. It does **not** verify that the number really is in
> that currency, and it never will.
>
> **A green build does not mean currencies are verified; it means every currency
> shown is stated somewhere.**
>
> This was measured rather than assumed: tracing
> `colMarketValue: 'Market Value (USD)'` to its number ends at
> `metal_prices.price_usd_per_tonne`, and **`metal_prices` has no currency column
> at all** — the unit is baked into the column name. **There is no fact in the
> schema to compare a label against**, so any mechanisation would be an
> approximation, and this repo has twice been burned by a checker that claimed
> more than it did (the scanner that read PostgREST embed names as column names;
> this check's own "scans SQL" claim, empty from the day it was written until
> OPS-8). **A check that overstates itself is worse than a missing one — it spends
> someone's suspicion for them.**

### 双语的列要【选一个】,不是拼起来 —— 而 check-i18n 看不见这一类(GST-FIX-3,2026-08-26)

数据库里成对的 `*_zh` / `*_en`(`tax_codes.name_*`、`gst_return_boxes.label_*` 之类)
必须**按界面语言选一个**:服务端 `await getLocale()`、客户端 `useLocale()`,
仓库里有一百多处是这么写的。

**`check-i18n` 结构上看不见这一类** —— 它查的是【文案文件里的键】(`t('...')`),
而这些字符串一次也不经过 `t()`。那不是它的疏漏,是它的射程之外。

**它咬过一次,而且是被人眼咬出来的:** GST-1/2/3 三刀里同一个写法漏了**六处**
(税码下拉 ×4、GST 首页税码表、F5 每一格说明)。构建绿、闸绿、冒烟 188 条全过 ——
Tim 把界面切成英文,一眼看见「中文 / English」。
**六处同一个惯用法被漏掉,正是棘轮存在的理由**,所以 GST-FIX-3 加了
`scripts/check-bilingual-concat.mjs`,进【构建】(它只读仓库文件,够不着库,
不该占 gate 那 300 秒),基线 **0**。

> **判据写得很窄,而窄正是它不误报的全部依据:** 两个插值、**同一个主语**、
> 中间只隔着不含 `( ) , < >` 的字面文本。于是
> `csvCell(r.label_en), csvCell(r.label_zh)`(F5 的 CSV 导出,**两列**,是对的)
> 不会被抓,而 `{c.name_zh} / {c.name_en}` 会。
> 真要同时印两种语言,在那一行写 `i18n-both: <理由>` ——
> **行内注释,不是中心基线**:一次刻意的双语打印是【那一行的性质】,
> 理由要待在下一个读它的人眼前,而一份中心基线会与代码漂开、还能被整体刷新以变绿。

## Making the page agree with the server is only right when the server is right

A page that offers something the server will reject is **a question about the
rule**, not automatically a bug in the page. Ask which one is wrong before
changing either.

This has now gone the wrong way once, and it cost a real feature. The payment
screen listed documents that `record_payment` refused with
`ALLOC_CURRENCY_MISMATCH`, so the list was filtered to match. But the
constraint was itself too strict — a customer owing USD 6,000 who pays in SGD
**has settled that invoice**. Filtering the page made the mistake harder to
see: the option simply stopped existing, and a missing feature looks exactly
like a deliberate restriction. FIN-16 removed the constraint and the filter
together.

So when the two disagree:

* **If the server is right**, do not offer the action — disable the control
  and say why. (An over-allocated payment, a closed period, a settled cost
  entry: the server is right, and the page should not present a button whose
  only outcome is an error.)
* **If the server is wrong**, fix the server. A UI filter over a wrong rule
  buries it — the rule stops producing errors, so nothing ever prompts the
  question again.

The tell for the second case: the rejected action is one a person would
reasonably want to take, and the error message describes a *policy* rather
than an inconsistency. `ALLOC_CURRENCY_MISMATCH` said "this document is USD
and your payment is SGD", which is a policy statement. `ALLOC_EXCEEDS` says
"you are allocating more than is outstanding", which is an inconsistency.

## A screen that previews a posting ASKS the database what it will be

**Never re-implement a posting rule in TypeScript so a page can show a
preview.** Call the function that will do the posting — or a read-only
companion that shares its arithmetic — and render what it returns.

This has now been the same bug four times:

1. the assay impact preview (Phase 4 cut 5b),
2. the GrantRunner leave formula (deleted in HR-2c),
3. the revaluation preview (FIN-9 — the page's own aggregation had already
   drifted from `revalue_foreign_balances`, and the number it showed was
   about to be posted),
4. `/finance/payments` (FIN-12 — the form computed its own FX rate with a
   base-currency constant left over from before FIN-0 flipped the base to
   SGD, so a base-currency payment valued at **0.00** and a USD payment
   valued at **1:1**).

The failure is always the same shape: the two implementations agree on the
day they are written and drift silently afterwards, and the screen is the
one people trust because it is the one they can see.

**The pattern that works** is already in the repo: `reprice_split` shared
by `reprice_inbound_batch` and `preview_reprice_inbound_batch`;
`preview_revalue_foreign_balances` called by both the page and
`revalue_foreign_balances`. Add a preview function beside the writer, or
call the writer's own helper. One implementation, two callers.

**Corollary — the page must not disagree with the server about units or
eligibility either.** If the server validates in document currency, the
page shows document currency (`/finance/payments` was subtracting
document-currency allocations from a base-currency amount). If the server
will reject a combination, the page must not offer it: never render a
submit control for an action the server is guaranteed to refuse.

## A failed query must fail — never `?? []`

`lib/db-helpers.ts` exports `mustRows` / `mustOne` / `mustCount`. **Use them for
every query result.** They throw on `error` and return the empty value only when
the query genuinely succeeded with no rows.

The rule they enforce is the same one `scripts/smoke-routes.mjs` applies in
`restRows` and `scripts/check-i18n.mjs` applies to suffix parsing: **a failure is
not an empty set.** Written in three places, it is one policy.

Why it matters here specifically: `entriesRes.data ?? []` turns a permission
error into an empty array, so the page returns **HTTP 200 saying "nothing
outstanding"**. The route smoke test asserts 2xx and sails straight past it — a
page that cannot read its data must *error*, or no gate can ever catch it.

`?? []` remains correct for things that are not query results: nested relation
fields on an already-fetched row, `Map.get(...) ?? 0`, client-side state.

**`scripts/check-error-swallowing.mjs` now enforces it** — in `npm run build` and
in `db/gate.py` (`swallow` line), with an ALLOWLIST carrying written reasons, the
same shape as the currency check. It exists because the audit's own finding was
that this was the **house style**, not 320 individual slips: sweeping without a
check buys a clean count and nothing else, and the 321st gets written the same way.

**Be clear about what it cannot see**, so a green line is not read as "no
swallowing anywhere". **CHECK-1 (2026-08-31) measured the three shapes this
paragraph used to list and closed two of them:**

* `if (error) return []` / `null` / `0` — **now caught** (`swallow-return`, single
  and two-line forms). One instance repo-wide: `app/hr/leave/actions.ts:153`.
* `.catch(() => …)` — **now caught** (`swallow-catch`, empty-handed catches only;
  `.catch(e => …)` is not judged, because using the error may be legitimate
  handling and the difference is not decidable from text). One instance:
  `app/inbound/[id]/assays/new/AssayForm.tsx:86`.
* a query whose error is never destructured, whose `data?.map(...)` yields zero
  rows — **deliberately NOT mechanised, and it will not be.** Zero instances
  today, but that is not the reason. Deciding whether a given `data` is an
  unchecked query result means following the variable — **type/dataflow analysis,
  not text matching** — and an approximation would redden hundreds of correct
  optional chains until someone turned the check off. **It is a written
  convention instead:** *a query result must have had its `error` looked at before
  anything optional-chains it.*

**The two live instances are on the books, and the shape of that record matters.**
They are in the script's `QUEUED` list, **not** its `ALLOWLIST`, and the two mean
opposite things: `ALLOWLIST` asserts *this is not a defect*; `QUEUED` asserts
*this is a defect, just not fixed in this cut* and must name where it goes.
**Recording something uncertified as allowlisted is how the next reader comes to
believe someone checked it.** Queued entries print on every run with their reason
and destination (cleanup A — permissions and error handling).

## Test data that reads wrong on purpose

Anything that looks wrong in the test database but is known, accepted, and
disappears on the production rebuild gets ONE LINE in
`docs/known-wrong-until-cutover.md` — instead of being re-explained every time
someone notices it. Known structural issues that would SURVIVE a rebuild —
accepted for now, to be fixed deliberately — live next door in
`docs/known-issues.md`; remove the entry when the fix lands.

## The backup runs BEFORE the migration, not after

```
~/evoltrya-backups/backup.sh        # ~10 min measured 2026-08-14, over the pooler
```

> **重新测过(TASK-1a,2026-08-18):同一台机器、同一天、同一条连接串,
> 一次 8 分钟(20:13 起,EXIT=0,2.3M),一次跑到 34 分钟仍未结束(20:37 起,
> 最后被主动杀掉)。** 所以上面那个「~10 min」是【一次取样】,不是一个上界 ——
> 与 `db/gate.py` 那张表得到的是同一个结论,而这已经是本周第二次
> **一个过时的耗时估计参与了决策**(第一次是 gate 的 483s)。
>
> **两件事因此要分开说:**
> * **备份要多久,没有一个可以照着规划的数。** 要等它,就用它自己的退出码等,
>   并且准备好它可能是 8 分钟也可能是半小时。
> * **慢的是【连接池那条传输】,不一定是"网络坏了"。** 同一时刻实测
>   REST 后续请求中位数 **412 ms**(健康档),而 pg_dump 走 5432 的那条路
>   慢到四倍以上 —— 正是 SMOKE-CONN-1 那条「量错了传输层」的同一个区别。
>   **判断"能不能干活"之前,先问这件活走的是哪条路。**
>
> 顺带,那次主动杀掉把 BK-FIX 的三道检查【实测跑了一遍】:
> `BACKUP_EXIT=1`、失败分支按名说了原因、0 字节的残骸被删掉。它是好用的。

**A backup taken after `apply_migration.sh` is not a rollback — it is a snapshot of the
thing you might need to roll back.** The migration path is atomic (one connection, one
transaction), so a *failed* migration needs no backup; the backup is there for the case the
gates cannot see — a migration that succeeds and is wrong. For that case, taking it
afterwards buys nothing at all.

**SO-2 (2026-08-14) ran it after. That was a slip, recorded as a slip** — not a new order of
operations, and not something to copy from the git history. It cost nothing that day because
the cut turned out fine, which is exactly why it is written down instead of forgotten: the
run where the order matters is the run where you have already lost.

> **备份要【跑完】,不是【起过】—— SO-3b 实测(2026-08-14)。**
> `pg_dump` 在跑的时候对每一张表持着 ACCESS SHARE 锁,而 `ALTER TABLE` 要的是
> ACCESS EXCLUSIVE:两者冲突。于是"先起备份、马上开始迁移"会让迁移【卡在等锁上,
> 直到 statement timeout】:
> ```
> == applying …  psql:<stdin>:64: ERROR:  canceling statement due to statement timeout
> ```
> 那次没有留下任何损伤(迁移是单事务,超时即中止、整支回滚),而且**报错本身
> 完全不像是锁的问题** —— 它只说"语句超时",不说在等谁。上一支迁移没撞上,
> 只是因为那次备份早就跑完了。
> **所以规矩是"备份跑完再动库",而不是"先把备份起起来"**。
>
> ### 判据是【脚本的退出码】,不是 `! pgrep -x pg_dump`(BK-FIX,2026-08-16)
>
> 这里原本写的是:
> ```
> db/wait_for.sh --timeout 1800 --label "备份 pg_dump 收尾" -- sh -c '! pgrep -x pg_dump >/dev/null'
> ```
> **那个判据分不出【跑完了】与【死了】** —— pg_dump 一旦中途断线,pgrep 立刻查不到
> 进程,这个等待当场变绿,而磁盘上留下的是一个残缺的文件。
>
> 2026-08-16 实测到了这一幕:pg_dump 在隧道上断线
> (`server closed the connection unexpectedly`),留下一个 **0 字节**、名字完全正常的
> `.dump`。更坏的是 `backup.sh` 自己 —— 它印着「❌ 备份失败」,**却退出 0**
> (失败分支里没有 `exit 1`)。于是"备份成功了吗"这个问题,当时【每一条判据都答错】:
> 脚本说 0、pgrep 说没进程了、`ls -t` 说有一份最新的备份。
> 这正是本文件那条"**一个报告了却不拦的判词不是闸**",出现在这套系统最不能出错
> 的地方 —— **备份就是回滚**。
>
> **现在的判据:直接看脚本的退出码。**
> ```
> ~/evoltrya-backups/backup.sh || { echo "备份失败 —— 不要动库"; exit 1; }
> ```
> `backup.sh` 已改成三道检查、失败一律 `exit 1`:pg_dump 的退出码(失败时删掉残骸)、
> 体积下限(取自实测历史,见脚本抬头)、以及 `pg_restore --list` 读不读得出来。
> 三道都做过故障注入。
>
> ★★【CHECK-1(2026-08-31):那三道检查都是对的,而它们【跑不到】】★★
> 它们全都写在 pg_dump **返回之后**,于是共享一个前提:**这个脚本还活着。**
> 而实测的事故打碎的正是这个前提 —— **备份被一次工具超时连进程一起杀掉,
> 那几行一行都没执行**,磁盘上留下一个 0 字节、顶着完全正常名字的 dump。
> **顺序错了,不是检查错了:** 旧写法是「用好名字落盘 → 再验证」,
> 于是从 pg_dump 开始写的那一刻起,磁盘上就躺着一个**名字合格、内容未经检验**的文件。
>
> **现在是隔离名优先:** pg_dump 写的是 `<好名字>.INCOMPLETE`(它**不**匹配
> `evoltrya-backup-*.dump`),四道检查全过之后才 `mv` 成好名字。`mv` 在同一文件系统上
> 是原子的,所以**"叫 evoltrya-backup-*.dump" 与 "验证过" 从此是同一件事**,
> 任何一刻被 `kill -9` 都只留下一个不可能被误认的 `.INCOMPLETE`。
>
> **实测对照(CHECK-1,用真的 dump 做桩,写到一半 `kill -9`):**
>
> | | 磁盘上留下 | `ls -t evoltrya-backup-*.dump \| head -1` 给出 |
> |---|---|---|
> | 旧顺序 | `…-2058.dump`,**550,000 字节** | **那个残骸**(顶着好名字) |
> | 新顺序 | `…-2059.dump.INCOMPLETE` | 上一份**好的**备份,3,947,752 字节 |
>
> **第四道检查:TOC 条目数 vs 上一份成功备份**,跌超 10% 即拒。加它是因为
> **本文件下面那段说"目录区在文件尾部"是错的** —— 自定义格式的 TOC 写在**文件头**
> (2026-08-24 那份残骸头里印着 `Archive created at 10:51:17`,正是开跑那一刻),
> 所以 `pg_restore --list` 抓的是**头部损坏**,不是截断。阈值 10% 是量出来的:
> 实测 14 份连续备份的条目数增量全部为正(+6 … +63,最大约 1.3%),
> 所以它不可能对正常备份误报。**六个分支都做了故障注入**
> (正常 / pg_dump 失败 / 体积过小 / 随机垃圾 / **真的那份 08-24 残缺 dump**
>  4018 vs 5071 当场拒 / 写到一半被 kill -9)。
> **它仍然不是"备份一定是好的"** —— 唯一完整的证据仍是那一行 `BACKUP_EXIT=0`。
>
> **`backup.sh` 住在仓库【外面】(`~/evoltrya-backups/`),所以这几行字是本仓库对它
> 唯一的把手。** 换一台机器、或者有人重装了那个脚本,这里写的东西就是要重新做一遍的
> 清单 —— 而不是"上次好像修过"。
>
> #### 那条判据【在后台跑的时候会失效】—— 拿到的是启动器的退出码(TASK-1a,2026-08-18)
>
> BK-FIX 定下的规矩是对的:**看脚本自己的退出码**。但它写的那一行
> (`backup.sh || { …; exit 1; }`)默认备份跑在**前台**。**一旦把它放到后台,
> 那条规矩就静默地失效了** —— 你读到的 0 是【启动它的那个东西】的,不是它的。
>
> 实测:用 `( backup.sh > backup.log 2>&1; echo "EXIT=$?" >> backup.log ) &` 起了备份,
> 几秒后收到「completed (exit code 0)」。那个 0 是外层那句 `echo` 的。当时的真实状态是:
>
> ```
> pg_dump ALIVE — backup still running
> evoltrya-backup-2026-08-18-2013.dump   0 字节
> ```
>
> **又是一个 0 字节、名字完全正常的 dump,配一个绿色的退出码** —— 与 BK-FIX 那次
> 一模一样的画面,只是这次的假绿灯来自【启动方式】,不是脚本本身。
>
> **判据补一句,把后台这条路堵上:**
>
> > **备份跑完的唯一证据,是 `backup.log` 里那一行【脚本自己打出来的退出码】。**
> > 不是启动器的状态、不是通知、不是 `pgrep`、不是文件存在、不是 `ls -t` 最新的那个。
> > 用了包装/后台,它就**必须把脚本的退出码传出来**,否则不要用。
>
> ```
> # 后台起备份,然后【等脚本自己的那一行】,有上限、有失败分支
> ( ~/evoltrya-backups/backup.sh; echo "BACKUP_EXIT=$?" ) > /tmp/backup.log 2>&1 &
> db/wait_for.sh --timeout 1800 --label "备份脚本自报退出码" -- \
>     sh -c 'grep -q "^BACKUP_EXIT=" /tmp/backup.log'
> grep -q "^BACKUP_EXIT=0$" /tmp/backup.log || { echo "备份失败 —— 不要动库"; exit 1; }
> ```
>
> **这是同一个形状的第三次,所以按规律记而不是按事故记:一个判词答的不是它标签
> 上写的那个问题。** 前两次是 `! pgrep`(答的是"进程还在吗",标签写的是"备份好了吗")
> 与 `backup.sh` 自己失败还退 0;这一次是**启动器的退出码冒充了脚本的退出码**。
> 与部署那条(GitHub 的登记冒充 Vercel 的状态)、与 `?sha=` 缩写(空集冒充"还没到")
> 是同一族。**每加一条等待或一条判据,把标签念出来,再把判据念出来,
> 两句话说的是同一件事吗?**

#### 网络掉线之后,后台那支活可能攥着一个【死掉的 socket】(PDPA-1,2026-08-24)

**这是同一族的第四次,而这一次的假绿灯来自【网络】。** 症状三件,同时出现:

* 本地进程**还活着**(`pg_dump` 在,`ps` 看得见);
* 服务端**没有对应的 backend**(`pg_stat_activity` 里一个都没有 —— 那条连接早就没了);
* harness 报**启动器的退出码 = 成功**,而脚本自己一行总结都还没打。

**判据(两条,都要):**
1. **脚本自己打出来的那一行**(`^<TOKEN>_EXIT=`)。没有它 = 判词【未知】,不是成功。
2. **服务端有没有一个对得上的 backend。** 本地进程活着不代表活还在干;
   `SELECT ... FROM pg_stat_activity WHERE client_addr = inet_client_addr()` 答的是这个。

**不要 `pkill`。** 那次的 wrapper 被 SIGTERM 之后,`backup.sh` 认了 init 当父进程活下来 ——
**杀了一层,底下那层还在,而你已经不知道自己在等谁了。**
**要做的是:退出这次会话、开一个新的、先跑一次【只读】的状态检查再决定。**
读到什么、不读到什么,那次检查的清单就是这一节上面那两条判据。

> **代价与那个必须记住的意外发现。** 起 10:51,最后一个字节 10:56,12:14 被终止;
> 上一次会话把这场僵持记成 **59 分钟**。留在磁盘上的是一份 **2,813,952 字节**的 dump,
> 而同一天跑成功的那份是 2,925,407 —— **少了 111,455 字节**。
>
> **而它【通过】了 `pg_restore --list`:退出 0,4025 条 TOC,与好的那份一模一样。**
>
> **所以 `backup.sh` 抬头第 3 条那句话是错的。** 它写着"自定义格式的 dump 尾部有目录区,
> 断在中间的文件可能很大、却读不出来" —— **目录区不在尾部**:那份 dump 的头里印着
> `Archive created at 2026-08-24 10:51:17`,也就是**开跑那一刻**就写好了 TOC。
> 于是 `pg_restore --list` 抓不到"跑到一半断掉"这种截断,它只抓得住头部就坏了的文件。
> **这套系统里【唯一】拦住那份残缺备份的,是那一行没有出现的 `BACKUP_EXIT=`。**
> 体积下限(100KB)也没拦住 —— 残缺的那份是 2.8MB。
>
> **别去"修"那条检查然后以为完事**:一个"体积比上一份少 3%"式的判据会在库缩小的
> 那天(生产全新重建之后)天天误报,而误报的闸最后一定被绕过。
> 今天成立的结论是更窄也更硬的那一条:**备份跑完的证据只有脚本自己那一行。**

#### 到点之后,那支活可能【活过了监督它的人】—— **已于 2026-08-29 做成机制(OPS-TIMEOUT)**

> ★**先说结论,免得有人照着下面的历史去做一遍手工诊断:这个缺陷已经不在了。**★
> `db/run_detached.sh` 现在到点时**先写 `<TOKEN>_EXIT=124`,再按【进程组】收尾**
> (先 SIGTERM,宽限 5s,再 SIGKILL),并且**落到与正常收尾完全同一段读取路**,
> 所以退出码与日志不可能各说各话。**"被超时终止"从此是一句有作者的判词,
> 不再是一片沉默。**
>
> **下面这一整段【历史保留,不删】** —— 它是这条机制的论据:同一个形状犯了
> 两次、两次都靠人眼发现,而这正是本仓库"第二次就换成机制"那条门槛的实例。
> 读它是为了知道这条机制在防什么,**不是**为了照着它做诊断。
>
> **今天一支活看起来还是卡住了,该查什么(短版):**
> 1. 日志里有没有 `^<TOKEN>_EXIT=` ?**有 124 = 是监督者到点把它收掉的**
>    —— 要么它真卡了,要么那个上限太小(见下面那条"上限要有来路")。
> 2. 一行都没有 = 连判词都写不出来(日志写不进去之类),`run_detached` 退 3。
> 3. **ppid=1 的孤儿今天不该再出现了。** 真出现了,那是一个【新的】发现,
>    不是这一条 —— 按名报出来。

**【以下为历史,记录 2026-08-24 与 2026-08-25 那两次】**

**这是同一族的第五次,而方向【反过来了】。** 上一条(死 socket)是
**死掉的孩子看起来还活着**;这一条是**活着的孩子熬死了它的监督者**。

**机制(实测,不是推理)。** `db/run_detached.sh` 到点之后跑的是:

```
kill "$CHILD"          # 第 87 行
... exit 3             # 判词【未知】,这一半是对的
```

而 `$CHILD` 是那个**子壳**,不是真正在干活的进程。子壳长这样:

```
( "$@" >> "$LOG" 2>&1; echo "${MARK}$?" >> "$LOG" )
```

于是 SIGTERM 打在子壳上,屏幕上留下
`db/run_detached.sh: line 93: 24884 Terminated: 15`,
而 `node scripts/smoke-routes.mjs --reach`(24886)**没有死,它认了 init 当父亲**
—— `ps` 里 ppid 从 24884 变成 **1**,日志继续在长。

**后果比一次普通超时更坏,而且坏在一个不显眼的地方:**
**被杀掉的那个子壳,正是【将来要写 `echo "${MARK}$?"` 那一行的人】。**
判词那一行的作者死了,活还在干 —— 于是这一跑**永远不会有 `SMOKE_EXIT=`**,
不是"还没打",是"再也不会打"。而活本身跑完了、结论也打进了日志,
只是没有那一行机器读得懂的判词。

**发生时要查的两件事(答得出来才知道自己在等谁):**
1. **日志还在长吗?** 长 = 活还在干,只是没人监督了。
   (静止**不**等于死 —— 它可能卡在一次慢渲染上;要连采几次。)
2. **那支 node 的父进程是不是 1 了?** 是 = 它已经孤儿化,
   没有任何 `run_detached` 还在等它。用 `ps -p <pid> -o ppid=` 直接问。

**这一次的处置:让它跑完,判词从日志里那行【总结】读**
(`== N routes …: N ok, N skipped, N FAILED`),
**并在报告与提交信息里写明判词是从哪儿来的。**
一个来路不明的判词才是问题;这一个来路是清楚的,写下来就不算不明。

~~**不要在踩到它的这一刀里顺手修 `run_detached.sh`。**~~ **那条克制已经兑现了
(OPS-TIMEOUT,2026-08-29):修法没有在踩到它的那一刀里顺手做,而是单独一刀,
带着它自己的故障注入。** 原文的理由照录:一个刚被自己绊倒的人去改那根绊索,
改出来的东西没有人验过 —— 那是本仓库记过的**"匆忙的检查者"**形状。
**它当时点名要的那次注入(让被等的命令忽略 SIGTERM,断言等待器仍然收得干净)
已经做了**,而且实测走的正是 SIGKILL 那一支:宽限 5s 之后进程组还在,改发
SIGKILL,收干净,判词 `E_EXIT=124` 在日志里。

> **顺带记下那一跑的真实代价,因为【写错的成本正是这个仓库反复付账的那个缺陷】。**
> `--reach` 那一跑实测 **2 小时以上**(139 条路由时代量到的是 65m44s),
> 而当天隧道是**退化**的:`select 1` 三次量到 **7.05s / 4.61s / 5.91s**,
> 对比同一天早些时候的 3.1–4.1s。`--reach` 的每一步都是一次真的服务端渲染、
> 每一次渲染都打远端库,所以隧道一退化,这一跑的时长就跟着乘上去。
> **决定"这一刀要不要跑 --reach"的人读的就是这个数** —— 它必须是量过的,
> 而且必须连着当天的链路状况一起读。

##### ★【同一天里的【第二次】—— 到这里就不该再写文档了,该把它做成机制】★(GST-2,2026-08-25)

**第一次是 GST-1 的冒烟(2026-08-24 深夜),第二次是 GST-2 的 `check_mirrors`
(2026-08-25 凌晨)。同一支脚本、同一个机制、不到一天。**

第二次的形状与上面逐字相同,只换了被等的那支活:
`--timeout 900` 到点,`kill "$CHILD"` 打在子壳上,而 `check_mirrors` 活了下来、
**在到点之后一分钟把结论写完了**(日志 mtime 01:58:06,而 900s 的点在 01:57)。
于是那一跑的判词行【永远不会出现】,而在等它的那个循环
**又轮询了一小时二十七分钟**,直到有人去看。

> **本仓库自己的门槛是:同一个形状撞第二次,就不再写注解,而是换成机制。**
> OPS-7 用脚本替掉两句"记得检查";`db/wait_for.sh` 替掉"记得给等待加上限";
> `run_detached.sh` 本身就是那次替换的产物。**而它现在自己成了那个要被替换的注解。**
> 所以队列里那一条(**「run_detached 到点要杀的是进程组,不是子壳」**)
> **从"效率类"提到阶段 7 的最前面。**
>
> ★**那次替换已经做了:OPS-TIMEOUT,2026-08-29。**★ 它兑现的正是这一段写下的
> 那条门槛 —— **而这一段【不删】,因为两次事故就是那条机制的论据。**
> 一条规矩单独放着会被下一个人编辑掉;一条带着自己事故的规矩活得下来。

**【那三条判据今天还剩什么用】** 下面那个"等待器在等一件不存在的事"的判据,
**第 3 条(日志里一行 `*_EXIT=` 都没有)在 `run_detached` 起的活上基本不会再成立**
—— 到点会有 124。它仍然适用于**没有走 run_detached 的手写等待**,
以及"连判词都写不出来"的极端情形(日志写不进去)。
**第 2 条(连 ppid=1 的孤儿都没有)的含义也变了:今天出现一个孤儿本身就是发现。**

**【一句话的判据,写在这里是为了让它便宜】**
> **一个还在轮询的等待器,而它等的那样东西【哪儿都不存在】。**

三件事一起成立就是它,而三件都是一条命令的事:
1. 日志**不再长**(比对 mtime 与现在;不是"静止=死了",是"静止 + 下面两条");
2. 被等的那支活**一个进程都找不到**(连 ppid=1 的孤儿都没有);
3. 日志里**一行 `*_EXIT=` 都没有** —— 不是还没打,是**再也不会打**。

**三条都成立时,那个等待器等的是一件不可能发生的事,杀掉它是安全的** ——
它没有副作用、不持锁、也没有留下 idle-in-transaction 的后端(这一次逐条查过:
`.live-lock` 不存在,`idle_in_txn = 0`)。**判词从 `ps` 的输出读,不从退出码读**
—— 杀掉一个等待器,harness 报的是"失败(144)",而那说的是信号,不是结论。

##### 第二条教训,与上面那条【无关】:一个低于实测成本的上限,是一次必然的误杀

**这一次真正的错误不是等待器,是那个 `--timeout 900`。**
`check_mirrors` 在这条隧道上要跑 **十五分钟左右**(它重放整套镜像再逐项比对),
而 900s = 15 分钟 —— **上限与实测成本【一样长】,一点余量都没有**。
于是它在活干完之前一分钟到点,把一次【本来会成功的】运行变成了一次误杀。
同一天后面的四次 gate 用的是 2700s,一次都没有碰到过上限。

> **规矩:上限【从实测成本推出来,加余量】,不是挑一个看起来够大的整数。**
> 挑出来的数没有来路,而没有来路的数会在两个方向上都出错:
> 太小 → 把"还在跑"变成一次误杀,而误杀留下的日志【长得和真失败一模一样】;
> 太大 → 一支真的卡死的活要等到那个数才有人知道。
> 本仓库对"写下来的成本必须是量过的成本"已经有一条规矩(见上面 `--reach` 那一段)
> —— **这一条是它的另一半:量过的成本,还要真的被【用】进上限里。**
>
> **这一句 2026-08-29 起也写进了 `db/run_detached.sh` 的用法注释里,连同它的事故**
> (900 秒的上限安在一支实测约十五分钟的活上,零余量,于是活在干完前一分钟被砍)。
> 写在那里是因为**读它的人是正在敲 `--timeout` 的那个人**,而不是正在读本文件的人。

#### ★【一个时刻的观察,解释不了另一个时刻的报告】★(GST-FIX-2,2026-08-26)—— **两刀之内第二次,同一个数**

**这一条不是关于 GST,是关于【怎么读一份走查报告】。**

Tim 报「F5 的每一个『打开』点了都没反应」。我去看那一页,看到钻取渲染了一段
**正确的空**,于是断定"没有坏,只是反馈不明显",并据此改了反馈。
**而他点的时候 box1 是 1143.00** —— 他在 17.11 里把那张发票作废了,
我的观察发生在作废【之后】。**我用一个状态解释了另一个状态。**

> **更难看的是:我在同一份报告里,上一段刚刚承认过同一个错**
> (「我引用了一个已经变过的线上值」),下一段就又犯了一次,而且是更大的一次 ——
> 第一次只是引错一个数,第二次是**据此下了一个错的诊断,并按那个诊断改了代码**。
> 一条被写下来的教训,如果下一段就违反,那它没有被学会,只是被记下了。

**规矩(形状,不是这一次):**
> **一份走查报告与你的观察对不上时,【中间发生了什么】才是问题,
> 而不是"谁看错了"。** 先去找那个变化 —— 单据被作废了?开关被关了?
> 期间被申报了?—— 再谈解释。**不要在两个都可能为真的说法里挑一个。**

**具体做法,三条,都便宜:**
1. **先问"他点的时候,这个数是多少"**,不是"现在是多少"。
   `voided_at` / `updated_at` / 审计列会直接给出时刻,对得上就能重建。
2. **重建那个状态再观察**,而不是在当前状态上推理。这一次重建只花了一条
   `record_output_sale` + 一条 `create_invoice`。
3. **观察不能重现报告时,不许收工。** "在我这儿是好的"不是结论,
   是"我还没找到我们之间差了什么"。这一次差的是:我发的是一次全新的
   服务端 GET,而他点的是一次**客户端路由跳转** —— 两条不同的路,
   而我的探针只走了其中一条。

#### 屏幕上的判据若是数据库判据的【代名词】,它会在数据库那边一改就悄悄错掉(GST-3,2026-08-26)

**同一族的又一次,而这一次它藏在一个 `&&` 里。**

`VoidInvoiceControl` 决定要不要显示【冲销日】那一栏,判据写的是 `kind === 'order'`。
那在当时是对的 —— 只有 order 型发票过分录,而"过了分录"才需要冲销日。
**但 `kind === 'order'` 从来不是那条规矩,它只是那条规矩当时的【代名词】。**
真正的规矩住在 `void_invoice` 里:`IF v_inv.entry_id IS NOT NULL`。

GST-2 让【带税的 sale 型发票】也过一张分录。数据库那一侧自动跟上了
(它问的是 entry_id);屏幕那一侧没有,因为它问的是 kind。
后果:**一张带税的 sale 发票在界面上根本作废不了** —— 它要求冲销日,
而界面从不给出那个输入框。而作废又正好是关闭 GST 开关的必经之路,
于是"关"的整个方向在屏幕上是断的,直到 GST-3 走那条路时撞上。

> **判据:一个前端条件,是在【复述】某条服务端规矩,还是在【代指】它?**
> 复述(同一个字段、同一个比较)会随字段一起改;
> 代指(一个当时恰好等价的别的字段)不会 —— 它会安静地留在原地。
> **改法是让两边问【同一个问题】**:这里把 `kind === 'order'` 换成
> `hasEntry`,与 `void_invoice` 的 `entry_id IS NOT NULL` 逐字同源。

**与上面那一条是一对:** 那一条说的是【闸】只守它当时那条路;
这一条说的是【屏幕】只认它当时那个代名词。两者的失败形式相同 ——
不报错、不变红,只是某条路从此走不通,而没有任何检查会问"这条路走得通吗"。

#### 一道闸只守它当时那条路 —— **换了推导来源,闸就要跟着搬**(GST-2,2026-08-25)

**同一刀里撞到两次,方向相同,而两次都不是"新功能没做",是"旧保证悄悄缩水了"。**

GST-1 立过一条硬保证:**未注册时,带税码的行写不进去**
(`post_journal_entry` 的 `GST_NOT_REGISTERED`)。那时 F5 九格【全部】从总账推导,
所以"总账里没有带税码的行" ⇔ "F5 全零" —— 一道闸守住了全部入口,保证是完整的。

**GST-2 把销项侧改成从 `invoice_lines` 推导。就在那一刻,那道闸只剩半个。**
一个盖在发票行上的税码【根本不经过 post_journal_entry】,却足以让 box1 不为零。
闸没有坏、没人改它、它仍然对着它守的那条路一字不差 —— **变的是它守的东西
多了一个入口**。处置:保证跟着搬到三张单据表上
(`guard_document_tax_code`,invoice_lines / expenses / credit_note_lines)。

**第二次是同一件事的下游:`reverse_journal_entry_internal` 翻边时【不抄 tax_code】。**
GST-1 时代这不要紧(没有任何一行带税码);GST-2 之后 box5 是
`Σ(借−贷) FILTER (tax_code IN (TX,ZP,BL))`,冲销行不带码就冲不掉那笔采购 ——
**一笔已经冲销的进货会永远留在 box5 里,而总账本身是平的、借贷相等、
没有任何东西看起来不对。**

> **要问的那一句,在【改推导来源】的那一刀里问,不是在下一刀:**
> **"这个新来源上,原来那些不变量还成立吗?"**
> 三类东西要逐一过:① 拦住写入的闸(它守的是旧路径吗);
> ② 复制/翻边/快照那一族(它抄不抄这个新列);③ 勾稽的两边(它们还独立吗)。
> 三类都不会报错 —— 它们的失败形式是**一个算得出来的错数字**。

**这条与本仓库那条"检查了却不拦不是闸"是一对:** 那一条说的是闸要真的拦,
这一条说的是**闸要拦在【今天所有的】入口上**。一道昨天完整的闸,
在推导来源变了之后可以什么都没做就变得不完整。

##### 那些入口里,最坏的一个是【默认参数值】(WHT-1,2026-08-28)

**上面两条问的是「闸守住今天所有的入口了吗」。还要再问一句:
【那些入口里,有没有一个是不需要任何人做任何事就会走上的?】**

WHT-1 建代扣时撞上这一条。`record_expense` 的签名是
`p_payment_status text DEFAULT 'paid'`,而 `'paid'` 那一支
**借 6xxx / 贷银行一步到位** —— 不产生应付、不产生 payments 行、
**不经过 record_payment**,也就是不经过唯一知道怎么把一笔付款劈成
「净额出银行 + 代扣挂负债」的那段代码。

于是对非居民当场付清一笔咨询费,会**一分钱都不代扣**。而它的位置是最坏的:

> **一个走默认参数值就能到达的漏洞,【不需要任何人输入任何东西】就会被触发。**
> 所有"谁会那样填呢"的直觉在它面前都不成立 —— 那正是它的默认值。

**判据(便宜,每次加闸时问一遍):把这支函数的每一个带默认值的参数念一遍,
按默认值走会落到哪一支?那一支在这条新规矩下还成立吗?**

**处置的选择也值得记,因为它不是"哪个更安全"而是"哪个不制造第二份实现":**
让 `paid` 那一支自己也会劈账 = 把同一份算术写第二遍,而这个仓库为
"两份实现在写下来那天一致、之后悄悄分开"已经付过**四次**账(见上面的预览规则)。
所以选的是**按名拒**(`WHT_ON_PAID_EXPENSE_UNSUPPORTED`),
并且**拒绝的文案必须说出走法**(先记未付、再付款)——
**一条在默认路径上、又不指路的拒绝,买到的是绕过它的办法,不是安全。**
代价(那条路多走一步)按【买来的成本】记在 `docs/known-issues.md`,不记成缺陷。

## A cut is not done at the commit — it is done at the DEPLOY

**Every cut's report must state the commit AND that it was pushed; the wrap-up must
confirm the deployment actually went out.** Not "committed" — committed *and pushed
and live*.

This is not bookkeeping. **The database is shared and the application is not.** A
migration is live the instant `apply_migration.sh` commits; the app code that goes
with it is live only after a push and a Vercel build. Every unpushed cut therefore
opens a window in which **production runs old code against a new database** — and
that window is invisible from this machine, because the local tree, the local gate
and the local dev server all agree with each other perfectly.

**IOD-2 spent an afternoon inside that window (2026-08-13).** Two migrations were
applied to live and both commits sat unpushed. Tim hand-walked the new behaviour on
the production URL and got machine text twice. Two diagnoses were wrong before the
dev-server logs settled it — **across two rounds there had never been a single POST**,
because his clicks were never reaching this machine at all. The measured damage:

* `/inbound/receive` was **broken in production**, not merely unlocalized. IOD-2
  changed three RPCs from `RETURNS uuid` to `RETURNS jsonb`; the deployed code was
  `redirect(\`…/done/${data}\`)` guarded by `if (error || !data)`. An object is truthy,
  so the guard passed and the URL became `/done/[object Object]` → `notFound()`.
  **The batch was created first**, so an operator saw a 404 after a successful
  receipt — the exact shape that produces duplicate receipts.
* The IOD-2 warnings did not exist in production at all: the deployed callers read
  only `error` and discarded `data`.
* Two named refusals rendered as raw codes, because the deployed `STOCK_ERROR_CODES`
  predated them.

**The tell, so the next person recognises it in one step:** a raw error string on a
screen that contains a code the local tree has *just* taught the database to raise.
That combination means old app + new DB, and it can only mean that. Check
`git log origin/main` before diagnosing anything else — an unpushed commit explains
it faster than any amount of reasoning about the code in front of you.

**A migration applied without its commit pushed is a half-deployed cut.** If a cut
must stop between the two, say so in the report and name what is broken until the
push lands, rather than reporting a green gate as a finished cut.

### 破窗时长是切次报告的一个【必填字段】,不是一句安慰

> **每一份动了数据库的切次报告都要写出这一行:**
> **破窗 = 迁移提交的时刻 → 部署 `state=success` 的时刻,写成一个【测出来的】时长。**

**为什么写成一条规矩:同一个形状已经被命名两次,而两次的记法都是不可比的。**
IOD-2 那次是【事后被人发现的】9 小时;SO-2 的预留那一刀报的是"不到一小时" ——
那是一个**上界**,不是一次测量。两者放在一起没法比较,也没法看出趋势,而
"不到一小时"读起来还像是已经量过了。**一个没有数字的窗口,与一个没人提起的
窗口,在报告里长得一模一样。**

**所以时间由脚本打,不由人记。** `db/apply_migration.sh` 在提交前后各打一个
时间戳并直说"破窗从此刻开始计" —— 这是这个仓库反复得到的同一个结论:
**要用到一个事实,就让机器把它读出来,而不是叮嘱下一个人记着看表**
(与 OPS-7 用脚本替掉两句"记得检查 B1 与 is_system" 是同一条)。
部署那一端的时刻从 `gh api …/deployments/<id>/statuses` 的 `created_at` 读。

**这个字段的用处不是评分,是让"要不要现在停下来"变成一个有依据的判断。**
窗口里生产跑的是【旧代码 + 新库】;它有多贵,取决于那一刀改了什么 ——
撤掉一条 INSERT 策略,窗口里那条录入路径就是坏的;加一列则往往什么都不坏。
**报告要同时说【多长】和【期间什么是坏的】**,两者缺一个都不成立:
一个只说时长的报告不知道该不该紧张,一个只说影响的报告不知道紧张了多久。

已测:
* **IOD-2 ≈ 9 小时** —— 事后被人发现的,不是量出来的。
* **SO-2(预留)—— 量不出来了。** 那份报告写的是"不到一小时",而那是一个
  **上界**;迁移提交的时刻没有任何东西记下来,现在无从复原。**这一条留在这里
  不是为了自责,是这条规矩最有力的论据**:一个听起来已经量过的数字,和一个
  真的量过的数字,在报告里长得一模一样,而只有后者能被拿来比较。
* **SO-2b ≈ 25 分钟**(17:05 撤掉 INSERT 策略 → 17:30:29 部署 success)。
  起点是从 `sales_record_movements.created_at`(17:09:22,第二支迁移的提交
  时刻)往回推出来的,精度到分钟 —— 那一刀跑的时候脚本还没有打时间戳。
  **下一刀起,起点由脚本直接打印,不再需要反推。**

## Migrations apply over direct psql, never the Management API

```
./db/apply_migration.sh db/migrations/<file>.sql
```

One connection, one transaction, all-or-nothing: any error aborts before
COMMIT and the database is left untouched (proven in OPS-6 with a deliberately
failing migration). The Management API caps payloads at ~15KB and drops
connections — FIN-0 and FIN-1a both got chunked through it and both left the
database half-migrated until the gates caught it. Credentials are in ~/.pgpass;
the API remains fine for small interactive queries and rolled-back fixtures.

### The script does the two checks you were told to remember (OPS-7)

**FIN-22b and FIN-23b both ended with a sentence telling the next person to
check `B1` and `is_system` before the migration. FIN-27 then did it again.**
Three times for the anon-executable function, twice for the unpromoted account
code. A note saying "remember X" is evidence that X needs a mechanism, not that
the note was missing — this repo has now paid for that twice, so:

* **Anon-executable new functions are PREVENTED, not detected.** PostgreSQL
  grants `EXECUTE` to `PUBLIC` on every new function, and the revoke lives only
  in `db/views/zzz_function_grants.sql`, which the *rebuild* runs and **live
  does not**. So every occurrence looked identical: rebuild clean, live open,
  visible only to `gate.py`'s B1 afterwards. `apply_migration.sh` now replays
  that file **inside the migration's own transaction**, after the migration
  body. It is pure ACL (1 GRANT, 9 REVOKEs, no CREATE/INSERT/SELECT), idempotent,
  and assumes nothing about an empty database — run twice against live it moves
  zero of 178 `proacl`s. The failure mode cannot recur; there is nothing left to
  remember.
* **The other two are DETECTED before the migration runs**, by
  `db/preflight_migration.py`:
  * an account-code literal the migration introduces that is not `is_system` —
    **warns and continues**, because the pre-flight reads the file *before* it
    executes and a migration may legitimately promote the code itself, so it has
    no standing to refuse;
  * a `CREATE OR REPLACE FUNCTION` whose signature differs from a live function
    of the same name — **refuses**, because that is an overload rather than a
    replacement: the old signature survives as drift the mirrors cannot see
    (FIN-21), and no case exists where it is intended. This judgement needs only
    the *current* live catalog, so it is decidable now — which is exactly why it
    may refuse where the account check may not.
  The account-code scanner is imported from `check_mirrors.py`
  (`account_codes_in_text`), not reimplemented — one regex, one allowlist, one
  definition, so the two can never drift apart.

`PREFLIGHT=0` skips the scan; the only honest reason to use it is that the
pre-flight itself is broken, and then the thing to fix is the pre-flight.

> **The instruction this replaces.** `fd84dc7` (FIN-23) closes with *"the lesson
> is now: new functions and newly hardcoded accounts get B1 and `is_system`
> checked BEFORE the migration"*, and `FIN-22b` says the same thing. **Those
> sentences are retired as of OPS-7** — a commit message cannot be edited, so
> the retirement is recorded here, where the reader who followed the reference
> will arrive. Do not re-adopt them as a manual step: the first is now
> impossible to get wrong and the second is checked for you. Following them by
> hand costs the time and proves nothing the tool has not already proven.

## The i18n key check runs on every cut that touches the app

`node scripts/check-i18n.mjs` (also `npm run check:i18n`; `npm run build` runs it
before `next build`, so the build gate cannot pass without it).

The i18n resolver returns the KEY when a label is missing, so a missing
translation prints `hr.alertType.salary_not_set` on screen and nothing fails.
It bit three times before this check existed, all in **dynamically built keys**
(`t('hr.alertType.' + a.alert_type)`), which a plain grep can never connect to
the message files.

The check therefore has two halves and one discipline:

* **Static**: every `t('...')` literal, plus key-shaped literals feeding
  `t(variable)` (`key:`/`labelKey:`/`titleKey=` props and the like), must exist
  in **both** `messages/en.ts` and `messages/zh.ts` — failure names file and line.
* **Dynamic**: every `t('prefix' + x)` construction must be classified in the
  script's `MANIFEST`. For enumerable suffix sets the checker reads the **source
  of truth at check time** — `CHECK (col IN (...))` in `db/tables/*.sql`,
  `'x'::text AS alias` in views, `new Set([...])` in `*ErrorCodes.ts`, `as const`
  arrays — so adding an enum value automatically widens the check. A resolver
  that parses 0 suffixes fails (a broken parser is not an empty set).
* **The discipline**: a dynamic prefix missing from `MANIFEST` is a FAILURE, not
  a pass — a new dynamic call site must be classified (wire a source, or mark it
  `kind:'data'` with a written reason, which is reported as a named gap every
  run). Dead keys (defined, never referenced) are reported but never fail:
  failing on them would push people to delete keys that dynamic code needs.

As of 2026-08-03 all 62 dynamic prefixes are enumerable; the named-gap list is
empty. Keep it that way where possible — the three historical bugs all lived in
exactly the keys a static-only scan cannot see. (Two call shapes exist and both
are scanned: named `t(...)`, and the direct `(await getTranslations())(...)`
form the `*ErrorCodes.ts` files use — the latter hid eight error families from
the first version of this scan.)

**Neither substitutes for the other.** `check_mirrors` replays into a scratch schema
*inside live*, so an unqualified reference silently resolves against live's `public` and
passes — the check is green on a repo that cannot rebuild. `verify_rebuild` builds into
a genuinely empty database, where there is nothing to borrow. It has now caught one
such bug that `check_mirrors` was structurally unable to see.

## Migration filenames come from the system date

**Run `date`. Do not increment the previous filename.**

Incrementing compounds: HR-3a was dated 2026-08-03 while the clock said 2026-08-01, and
every later cut stepped forward from the *filename* rather than the clock, reaching
2026-08-10 on a day the clock said 2026-08-03.

**Known discrepancy, left in place deliberately.** `2026-08-03-hr3a` through
`2026-08-09-hr3c` were all committed on **2026-08-02** (verifiable with
`git log --diff-filter=A -- db/migrations/<file>`). Their dates are fiction; their
*sequence* is correct. Renaming them to the true date would collapse seven files onto
`2026-08-02`, and the resulting alphabetical order —
`hr2c-fu1, hr2c-fu2, hr2c, hr3a, hr3b, hr3c, ops1` — contradicts the real order
`hr3a, hr3b, ops1, hr2c, hr2c-fu1, hr2c-fu2, hr3c`. Renaming any subset is worse still,
inverting the relationship with the files left alone. Since nothing replays migrations
by filename (they are changelog-only; the install path is entirely mirror-based), the
misleading dates cost nothing while a rename would destroy real ordering information.
