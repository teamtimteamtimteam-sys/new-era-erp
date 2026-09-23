# Gate, tooling, backup and deploy history — text moved verbatim out of AGENTS.md by AGENTS-TRIM-1 (2026-09-23); each ↩ heading names the section it came from.

## ↩ G01 · from AGENTS.md § The database gate runs on every cut that touches the database (old lines 131–198)

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

## ↩ G02 · from AGENTS.md § ★★ `--reach` cannot validate navigation on this tree (C-1b, 2026-09-04) (old lines 603–615)

**It reports ~96 routes unreachable no matter what your cut did. That is the tool, not
the app.** Do not spend a session rediscovering this.

**Mechanism.** `hrefsIn()` (`scripts/smoke-routes.mjs:1506`) is a single regex —
`/href="([^"]+)"/g` — run over **server-rendered HTML**. Since IA-BUILD-1 the navigation
is `app/components/nav/ModuleBar.tsx`, a `'use client'` component whose **top level is a
`<button>`, not an `<a href>`**, and whose second-level links render only after an
`onClick` state change. **The entire nav is therefore invisible to the crawler.** The
~39 routes it does reach are links embedded in page bodies.

**Measured 2026-09-04 (`--reach=admin`):** `SMOKE_EXIT=1` · crawler walked **320 pages** ·
137 openable static routes · **98 reported unreachable**.


## ↩ G03 · from AGENTS.md § ★★ `--reach` cannot validate navigation on this tree (C-1b, 2026-09-04) (old lines 625–628)

**This was a known boundary from the start**, written down when the mechanism was scoped:
`docs/per-role-reachability-scoping.md` §边界 — *"客户端交互之后才出现的入口(下拉、
弹窗、条件按钮)不在覆盖内"*. It only surfaced now because `--reach` defaults to off and
the cut before C-1a skipped it, so there was never a green baseline.

## ↩ G04 · from AGENTS.md § `--reach` takes a role now (GUARD-FIX-1, 2026-09-01) (old lines 642–672)

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

## ↩ G05 · from AGENTS.md § `--reach` takes a role now (GUARD-FIX-1, 2026-09-01) (old lines 679–735)

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

## ↩ G06 · from AGENTS.md § ★ 第三种形状:一条说不出自己抓到了什么的检查,会让你【再跑一遍】去问它 (old lines 801–816)

前两种形状的代价是"跑得太久"或"跑得太多遍";这一种的代价是**你不得不再跑一遍
才知道刚才那次是什么意思**。FIX-2a 实测付过这笔账:`GATE3_EXIT=2` 印着
【仓库建不出库】,而**同一份日志里写着 `REBUILD OK`** —— 真正挂掉的是随后对线上
的比对(SSL connection closed)。原样重跑 `GATE4_EXIT=0`。**一次网络抖动被报成
了仓库坏了,代价是一整轮门(实测 310s),外加读日志分辨真假的时间。**

处置(VERIFY-1):`db/verify_rebuild.py:signature()` 够不到线上时改退 **5**,
而不是混进 2;`db/gate.py` 认得 5 并单独出一句判词。**这不取消任何断言 ——
它只是让那条断言说得出自己抓到了什么。**

★ 而这一条最值得记的不是缺陷本身,是**它就写在一条已经点名了同一个病形的注释
底下**:`signature()` 上方那条注释提醒 `statement_timeout` 被掐断"看起来像比对
失败而不是超时",然后紧接着的那个分支,在【连接】这一层上犯了同一个错。
**一条点名了病形却漏掉自己兄弟的警告,与没有警告差不多。** 写下一条警告的时候,
顺手问一句:同一个形状在这附近还有没有第二处?


## ↩ G07 · from AGENTS.md § ★ 第三种形状:一条说不出自己抓到了什么的检查,会让你【再跑一遍】去问它 (old lines 861–888)

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

## ↩ G08 · from AGENTS.md § The backup runs BEFORE the migration, not after (old lines 2285–2300)

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

## ↩ G09 · from AGENTS.md § The backup runs BEFORE the migration, not after (old lines 2308–2311)

**SO-2 (2026-08-14) ran it after. That was a slip, recorded as a slip** — not a new order of
operations, and not something to copy from the git history. It cost nothing that day because
the cut turned out fine, which is exactly why it is written down instead of forgotten: the
run where the order matters is the run where you have already lost.

## ↩ G10 · from AGENTS.md § The backup runs BEFORE the migration, not after (old lines 2327–2341)

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

## ↩ G11 · from AGENTS.md § The backup runs BEFORE the migration, not after (old lines 2350–2381)

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

## ↩ G12 · from AGENTS.md § The backup runs BEFORE the migration, not after (old lines 2385–2399)

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

## ↩ G13 · from AGENTS.md § The backup runs BEFORE the migration, not after (old lines 2414–2419)

> **这是同一个形状的第三次,所以按规律记而不是按事故记:一个判词答的不是它标签
> 上写的那个问题。** 前两次是 `! pgrep`(答的是"进程还在吗",标签写的是"备份好了吗")
> 与 `backup.sh` 自己失败还退 0;这一次是**启动器的退出码冒充了脚本的退出码**。
> 与部署那条(GitHub 的登记冒充 Vercel 的状态)、与 `?sha=` 缩写(空集冒充"还没到")
> 是同一族。**每加一条等待或一条判据,把标签念出来,再把判据念出来,
> 两句话说的是同一件事吗?**

## ↩ G14 · from AGENTS.md § 网络掉线之后,后台那支活可能攥着一个【死掉的 socket】(PDPA-1,2026-08-24) (old lines 2439–2454)

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

## ↩ G15 · from AGENTS.md § 到点之后,那支活可能【活过了监督它的人】—— **已于 2026-08-29 做成机制(OPS-TIMEOUT)** (old lines 2475–2514)

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


## ↩ G16 · from AGENTS.md § 到点之后,那支活可能【活过了监督它的人】—— **已于 2026-08-29 做成机制(OPS-TIMEOUT)** (old lines 2522–2530)


> **顺带记下那一跑的真实代价,因为【写错的成本正是这个仓库反复付账的那个缺陷】。**
> `--reach` 那一跑实测 **2 小时以上**(139 条路由时代量到的是 65m44s),
> 而当天隧道是**退化**的:`select 1` 三次量到 **7.05s / 4.61s / 5.91s**,
> 对比同一天早些时候的 3.1–4.1s。`--reach` 的每一步都是一次真的服务端渲染、
> 每一次渲染都打远端库,所以隧道一退化,这一跑的时长就跟着乘上去。
> **决定"这一刀要不要跑 --reach"的人读的就是这个数** —— 它必须是量过的,
> 而且必须连着当天的链路状况一起读。


## ↩ G17 · from AGENTS.md § ★【同一天里的【第二次】—— 到这里就不该再写文档了,该把它做成机制】★(GST-2,2026-08-25) (old lines 2532–2541)


**第一次是 GST-1 的冒烟(2026-08-24 深夜),第二次是 GST-2 的 `check_mirrors`
(2026-08-25 凌晨)。同一支脚本、同一个机制、不到一天。**

第二次的形状与上面逐字相同,只换了被等的那支活:
`--timeout 900` 到点,`kill "$CHILD"` 打在子壳上,而 `check_mirrors` 活了下来、
**在到点之后一分钟把结论写完了**(日志 mtime 01:58:06,而 900s 的点在 01:57)。
于是那一跑的判词行【永远不会出现】,而在等它的那个循环
**又轮询了一小时二十七分钟**,直到有人去看。


## ↩ G18 · from AGENTS.md § 第二条教训,与上面那条【无关】:一个低于实测成本的上限,是一次必然的误杀 (old lines 2572–2578)


**这一次真正的错误不是等待器,是那个 `--timeout 900`。**
`check_mirrors` 在这条隧道上要跑 **十五分钟左右**(它重放整套镜像再逐项比对),
而 900s = 15 分钟 —— **上限与实测成本【一样长】,一点余量都没有**。
于是它在活干完之前一分钟到点,把一次【本来会成功的】运行变成了一次误杀。
同一天后面的四次 gate 用的是 2700s,一次都没有碰到过上限。


## ↩ G19 · from AGENTS.md § ★ THE GATE GOES GREEN BEFORE THE PUSH — a wrong mirror on main outlives an open window (old lines 2721–2733)

**Measured occurrence (UI-1b, 2026-09-05).** The migration went in at 17:55:51.
The window was analysed as **benign and the analysis was correct** — the migration
only *added* objects (two tables, one nullable column, one `hr_alerts` arm) that
the deployed code never reads, so nothing in production could break. On that
reasoning the push was sequenced **ahead** of the gate, to close the window early.
The gate then came back `GATE_EXIT=1` — `1 DIFFERENCE(S)`, `employees.columns` —
and by then `e6a0812` was already on `origin/main` carrying an incomplete mirror.

**Note what did NOT go wrong, because that is the trap:** the reasoning about the
window was sound, the window really was harmless, and closing it early really was
cheaper *for the window*. **The judgement was right about the thing it was
weighing and wrong about the thing it was not.** A correct risk assessment of one
cost is not a reason to accept an unmeasured second one.

## ↩ G20 · from AGENTS.md § A cut is not done at the commit — it is done at the DEPLOY (old lines 2792–2807)

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

## ↩ G21 · from AGENTS.md § 破窗时长是切次报告的一个【必填字段】,不是一句安慰 (old lines 2842–2851)

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

## ↩ G22 · from AGENTS.md § The script does the two checks you were told to remember (OPS-7) (old lines 2903–2910)

> **The instruction this replaces.** `fd84dc7` (FIN-23) closes with *"the lesson
> is now: new functions and newly hardcoded accounts get B1 and `is_system`
> checked BEFORE the migration"*, and `FIN-22b` says the same thing. **Those
> sentences are retired as of OPS-7** — a commit message cannot be edited, so
> the retirement is recorded here, where the reader who followed the reference
> will arrive. Do not re-adopt them as a manual step: the first is now
> impossible to get wrong and the second is checked for you. Following them by
> hand costs the time and proves nothing the tool has not already proven.

## ↩ G23 · from AGENTS.md § Migration filenames come from the system date (old lines 2961–2970)

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
