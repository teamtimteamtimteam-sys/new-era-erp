# FA-HIST-1 —— 固定资产台账终于记得住谁改了它,而且屏幕上读得到(2026-09-20)

★★ **一句话**:`fixed_assets` 从 FIN-22 落地起**从来没有过留痕**。本刀按 Tim 的三条裁定
建了第 12 张影子表 `fixed_asset_history`,**由基表上的一支触发器捕获每一次写入**,
并在 `/finance/assets/[id]` 末尾给了操作员一块读得到的面板(中英双语 · 具名空状态)。
**以一个真的登录 finance 用户在线上证明过,然后把线上放回了开工前那一刻。**

---

## §1 · 开工闸 —— ✓ 干净

```
git status --porcelain      (空)
本地 HEAD                   0dc731c93d3a3df7402eff217d4ecb9c5027e1e2
origin/main 跟踪引用         0dc731c93d3a3df7402eff217d4ecb9c5027e1e2
git ls-remote origin main   0dc731c93d3a3df7402eff217d4ecb9c5027e1e2
```

三个 SHA 一致,工作树干净。**与 B3 那次不同,这次没有需要交代的差额。**

---

## §2 · ★★★ 委托书里的那个「五支写函数」是【错】的,而它错在两个方向

委托书自己写着「B3.md 一处数五支、另一处数了别的,**自己从目录建立真集**」——
照做了,而结果比一处笔误大。

**实测方法**:`pg_proc.prosrc` 正则命中 `INSERT INTO / UPDATE / DELETE FROM` 后接
`fixed_assets`,**全库扫线上目录**,不是读镜像推的。

**真集:7 支函数 / 8 条写语句 / 0 条 DELETE。**

| # | 函数 | 语句 | 写什么 |
|---|---|---|---|
| ① | `create_fixed_asset` | INSERT | 整行诞生 |
| ② | `record_expense`(资本**新建**支) | INSERT | 整行诞生 |
| ③ | `record_expense`(**追加成本**支) | UPDATE | `cost_base` |
| ④ | `reverse_expense` | UPDATE | `cost_base` |
| ⑤ | `set_asset_in_service` | UPDATE | `in_service_date` |
| ⑥ | `set_asset_acceptance` | UPDATE | `acceptance_date` |
| ⑦ | `set_asset_planned_in_service` | UPDATE | `planned_in_service_date` |
| ⑧ | `dispose_fixed_asset` | UPDATE | `status` / `disposal_*` |

⚠ **`depreciate_fixed_assets` 根本不写 `fixed_assets`** —— 它唯一的 INSERT 落在
`fixed_asset_depreciation`。**它在三份文档的名单上白站了。**
(委托书问的 (c)「它一次跑会造多少留痕行」因此答案是 **0 行,今天与任何体量下都是**;
线上实测 2 台资产 · 0 行折旧 · 0 台在役。)

⚠⚠ **而 `record_expense` / `reverse_expense` 从来【不在】任何一份名单上** ——
偏偏这两支动的是**钱**(`cost_base`)。
☞ **照那份五支的名单建出来的留痕,会对成本变动全盲。**
**这不是一处字面更正:它改变了这一刀要覆盖的范围。**

★ **这也是本刀选择【基表触发器】而不是【七支函数里逐支写 INSERT】的第一条理由:
名单会错,而且已经错了两次;一张表上的触发器不会漏掉第八个写入者。**

**三份文档已就地更正(原文一字不删,加删除线并注明)**:
`docs/handbacks/B3.md` §4 · `docs/known-issues.md` 同名条 · `docs/forward-queue.md` 乙表那一行。

---

## §3 · ★★★ 本刀最要紧的一个设计:那支触发器【不提任何一个列名】

**`db/fixtures/120` 的 F5(d)① 扫全库函数体**,要求除 `set_asset_planned_in_service`
一支外,**没有任何地方出现 `planned_in_service_date` 这个名字**。它守的承诺是:
**没有一条规则【读】这个计划日去决定任何事。**

★ **而它扫的是 `pg_proc WHERE prokind = 'f'` —— 触发器函数的 `prokind` 正是 `'f'`**
(线上实测:`trg_so_history_header` → `prokind=f, rettype=trigger`)。
☞ **一支在 INSERT 列表里写出 `old_planned_in_service_date` 的历史触发器,会当场让 120 变红。**

两条路,Tim 裁定走第二条:

* ✗ 给 120 加第二条豁免 —— 要动一条**已经存在的断言**,并把那个名字重新放回一个
  函数体里,再论证这次为什么没关系。**B3 §7 已经论证过一次了。**
* ✓ **让触发器根本不提它。** 做法:`to_jsonb(OLD)` / `to_jsonb(NEW)` 现算差集,
  键名在**运行时**拼成 `'old_'||k` / `'new_'||k`,再由 `jsonb_populate_record`
  落进**真正带类型的**成对列。

☞ **`db/fixtures/120` 一个字节都没有改。**
**那是「最小改动」能取到的最小值:零 —— 而承诺一个字都没放松。**

**表仍然是 `sales_order_history` 那一套形状**(23 对带类型的列),
所以 `task_history` 表注那条「机器读得懂的历史才查得了、比得了」**一字不让**。

---

## §4 · Tim 的四条裁定,逐条交代

| | 裁定 | 落地 |
|---|---|---|
| **Q1** | C · 成对列 + 通用写法,触发器不提列名,120 不改 | ✓ 见 §3。**并按 Tim 要求加了「成对齐全」判据**(fixture 201 的 **P1** 臂):`fixed_assets` 的每一列都必须在影子表有 `old_`/`new_` 两列 —— ★ 因为 `jsonb_populate_record` 对**没有对应列的键【不报错,直接丢】**。明天谁加第 24 列而忘了这里,**当场红,不是静默丢** |
| **Q2** | (i) · `changed_by_kind NOT NULL`,`'user'` / `'no_session'`,绝不叫 system | ✓ 两处文案逐字按 Tim 给的:zh「数据库直连(不经过登录)」· en "Direct database session (not a login)"。**不叫 system 的理由写进了列注释**:线上没有 pg_cron(实测 6 个扩展),`depreciate_fixed_assets` 又不写这张表 —— **没有任何系统写入者**,叫它 system 是给一个不存在的主体起名字 |
| **Q3** | (i) · 留外键 + `guard_fixed_assets_no_hard_delete`,自己报名 | ✓ 照 `guard_purchase_order_no_hard_delete` / `trg_tasks_no_hard_delete` 两处先例。抛 `FIXED_ASSET_NO_HARD_DELETE\|<code>` |
| **Q4** | `.limit(50)` + 具名截断行 + 面板在页末 + 复用 ActorName + **空状态的日期取自实际落库那天** | ✓ 全部。★ **那个日期是迁移真正落库之后从 `db/migration-windows.tsv` 取的:`2026-09-20`**(`applied_at = 2026-09-20T21:25:02+0800`),**不是提前写死的** |

---

## §5 · Round 2 的四个细节 —— 我自己定的,连同理由

委托书:「自己定,按 `sales_order_history` 的先例,每一条连理由写进交回;
**只有当它改变了这一刀的形状时才停下来**」。四条都只是细节,**没有一条改变形状**。

**① `change_type` 的取值:只有 `created` / `updated` 两个。**
★ **理由是一条硬推论,不是省事**:触发器**不提列名**(§3),所以它**分不出**、
也**不该分出**「这是一次投用还是一次设计划」。
☞ **若由函数文本分辨,就等于让一条规则去【读】那个计划日来决定一行历史长什么样 ——
而那正是 fixtures/120 守的那句承诺要拦的形状。**
「这一次改的是什么」由 `changed_columns` 这一列的**数据**回答。
⚠ **没有 `deleted`**:硬删被守卫拦死,**一个任何路径都产不出来的取值,写进 CHECK 就是一句谎**。

**② 列:23 对,一个不落**,连 `id` / `created_at` / `created_by` 这种永不改动的也配对。
★ 理由:**「每一列都有一对」是一条没有例外的规矩,而一条带例外的规矩需要一份豁免名单,
豁免名单会烂**(fixtures/120 F5(d) 正为这件事重写过一次)。
它还顺带买到一样东西:`created` 那一行的 `new_*` 侧**全部填满** ——
「这台机器出生时是什么样」单看留痕就答得出来(fixture 201 的 A 臂钉了这一条)。

**③ i18n 前缀:`assets.history.type.` 与 `assets.history.field.`**,
两条都**从数据库现读**,一条抄一份清单在这里都不行 ——
`type.` 读 `change_type` 的 CHECK,`field.` 读影子表的 `old_*` 列
(为此加了一支 `sqlPairFields()` 解析器,与既有的 `sqlEnum` 同族,**解析出 0 个就抛**)。
☞ 明天加第 24 列,**这里不用改,而 `npm run build` 会当场点名少了一条文案** ——
屏幕不会先长出一个裸列名。**已做反证**:抽掉 en 的一条,体检当场红并点名那一条;放回,绿。

**④ 每字段的中英文案**:23 对逐条写,按这张表自己的用词
(`in_service_date` = 投用日 / In-service date;`acceptance_date` = 验收合格日;
`planned_in_service_date` = 计划投用日 —— **与那三列的列注释用词一致**,不另造一套)。

---

## §6 · `db/fixtures/201` —— 16 臂,8 条写语句逐条走过

| 臂 | 钉住什么 |
|---|---|
| **前提** | 三支触发器都在(捕获 · 只增不改 · 禁硬删)—— 少一支,下面每一臂都会数到 0 行,**而 0 行看起来很像「这条路径不写历史」** |
| **P1** ★★ | **成对齐全**(Tim 点名):`fixed_assets` 每一列都有 `old_`/`new_` —— 拦的是 `jsonb_populate_record` 的**静默丢键** |
| **P2** ★★ | **捕获触发器不提 22 个列名中的任何一个** —— 比 120 严(120 只认一个名字)。☞ 没有它,下一个人顺手写进 `IF NEW.status = 'disposed'`,120 **不会红**,而触发器会一步步长回被禁止的形状 |
| **A** | `create_fixed_asset` ⇒ 恰好一行 `created` + 出生快照填满 + **`changed_by` 是调用者** |
| **B** ★ | `record_expense` 资本**新建**支 ⇒ 恰好一行(**这条路径从来不在任何名单上**) |
| **C** ★ | `record_expense` **追加成本**支 ⇒ 只动 `cost_base`,100000 → 170000 |
| **D** ★ | `reverse_expense` ⇒ 170000 → 100000(**B/C/D 三条是名单漏掉的那三条**) |
| **E** | `set_asset_in_service` ⇒ 只动 `in_service_date`,NULL → 日期 |
| **F** | `set_asset_acceptance` ⇒ 只动 `acceptance_date` |
| **G** ★ | `set_asset_planned_in_service` ⇒ 前后值**落进带类型的 date 列**(两边都 NULL 就是 P1 说的那种丢键) |
| **H** | `dispose_fixed_asset` ⇒ 同时动 `status` 与 `disposal_date`,active → disposed |
| **I** | **什么都没改的 UPDATE 不留行**(同 `trg_so_history_header`:一行「什么都没变」会把真正的修改淹掉) |
| **J** ★ | 没有登录会话 ⇒ `changed_by_kind='no_session'`,**而且它顺带证明了触发器对【不经函数的直连写】也开火** |
| **K** | 只增不改:UPDATE 与 DELETE 都抛 `FA_HISTORY_IMMUTABLE` |
| **L** | 基表硬删**按名拒** `FIXED_ASSET_NO_HARD_DELETE\|<code>` |
| **M** ★★ | **反面对照**:无 `finance.edit` ⇒ `PERMISSION_DENIED\|module.finance.edit` · ★ **同一会话里直连 UPDATE 仍 0 行**(B3 的 G 臂,一字不改)· **且没有留痕长出来** |
| **N** ★★ | **读的两半都钉**:有 `module.finance.view` 的人**看得见 N 行**,没有的人 **0 行** |

★ **N 臂为什么必须是两半**:只钉「没权限的人读到 0 行」是不够的 ——
**一张空表、一条写错的策略、一个拼错的权限码,都会让那个 0 出现。**
先钉「有权限的人看得见」,那个 0 才是一次**测量**,不是一次**缺席**。

★ **一处写法上的坑,记下来**:`now()` 是**事务**时刻,同一事务里落下的每一行
`changed_at` **一模一样**。所以本文件**没有一处**按 `ORDER BY changed_at DESC LIMIT 1`
取「最新那一行」—— 每一臂都按**它自己要找的那件事**取行(改了哪一列、改成了什么)。
第一版写了时间排序,**它会拿到任意一行**。

---

## §7 · ★ 开工后被判据抓到的三件,逐件交代

**① fixture 201H 自己写错了**(离线门第一次,`GATE_EXIT=4`)。
`'status' = ANY(changed_columns)` 取到的是 **`created` 那一行** —— 它的
`changed_columns` 是**整行 23 列**,`status` 当然在里面。**判据加了 `change_type='updated'`。**
☞ 这正是 §5 ② 那个「出生快照」设计的一个副作用,**被一条判据当场抓住了**。

**② `db/fixtures/77` 撞上了新守卫**(同一次,同一个 exit)。
它第 ③ 臂为了造「一台资产都没有」的状态,直接 `DELETE FROM fixed_assets` ——
而这条路上从此站着**三样有意的东西**(禁硬删守卫 · 留痕的只增不改守卫 · 影子表的外键)。
★ **处置:就地、只在那四条语句上把两支守卫关掉再打开**,
**而不是去给守卫本身开一个「fixture 例外」** ——
**一个写在守卫里的例外会活得比这支 fixture 久,而且下一个人读不出它是为谁开的。**
⚠ 并且**立刻打开**:本文件后面还有两个注入臂会再建资产,关着走完全文等于让那两臂
在一个没有守卫的库上通过。

**③ ★★ 整门 `exit 1` 抓到一处真的漂移,而它的答案与我下手前的假设【相反】。**
我原以为新表会像其余 11 张留痕一样拿到 `anon` 的默认授权,于是先往
`db/anon-grants-baseline.tsv` 加了一行。**整门说:重建有 `anon`,线上没有。**

线上实测,`public` 上有**两套**默认权限:

```
supabase_admin 建的表 → postgres + anon + authenticated + service_role
postgres       建的表 → postgres +       authenticated + service_role   ← 没有 anon
```

而 `db/apply_migration.sh` 走的是直连 psql,身份是 **postgres** ——
**于是本表落到线上时本来就没有 anon,而本地重建的 prelude 复刻的是前一套。**

★ **取齐取的是【严的那一边】**:镜像里补一句显式 `REVOKE ALL ... FROM anon`,
让重建长成线上的样子;**并把我加的那行基线删掉**(anon 根本够不着它,留着那一行是句假话)。
⚠ **不是反过来给线上补一条 anon 授权** —— **为了让一次比对变绿而放宽权限,方向就反了**,
那也正是基线文件那句「只许缩小」的意思。
☞ 留痕本来也轮不到 anon(唯一的策略是 `TO authenticated`)——**授权与策略各挡一层,两道都要。**

---

## §8 · 验证 —— **每一行都是脚本自己打出来的那一行,不是启动器的**

| 相位 | 判词 |
|---|---|
| 离线门(第一次) | `GATE_EXIT=4` ✗ —— 抓到 §7 ①② |
| 离线门(第二次) | **`GATE_EXIT=0`** ✓ · ★ `fixtures/120` ✓ `200` ✓ `201` ✓ `77` ✓ |
| 备份闸 | **`BACKUP_OWN_EXIT=0`** ✓ TOC **5848** 条(上一份 5846,下限 5261)· 4.3M |
| 迁移 | **`APPLY_OWN_EXIT=0`** ✓ 单事务提交(预检:3 新建函数 · 不加列 · 不引用科目码) |
| 类型重生成 | **`GEN_OWN_EXIT=0`** ✓ |
| `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** ✓ |
| `npm run build`(第一次) | `BUILD_OWN_EXIT=2` ✗ —— 量具自报没量准,见下 |
| `npm run build`(第二次) | **`BUILD_OWN_EXIT=0`** ✓ |
| 整门(第一次) | `GATE_OWN_EXIT=1` ✗ —— 抓到 §7 ③ |
| 整门(第二次) | **`GATE_OWN_EXIT=0`** ✓ 四个判词全绿(wall-clock **742s**)· 匿名面:线上是基线的子集(基线 **327** 条) |
| `scripts/check-i18n.mjs` | **`I18N_OWN_EXIT=0`** ✓ |
| `scripts/smoke-routes.mjs` | **`SMOKE_OWN_EXIT=0`** ✓ · ★ **`/finance/assets/[id]` → HTTP 200**(225 条计时,中位数 4265 ms) |

**⚠ `BUILD_OWN_EXIT=2` 那一次是【刻意的摩擦】,要说清它不是一个 bug:**
`scripts/check-document-registry.mjs` 钉着 `EXPECTED_TABLES = 220`,而本刀新增一张表。
**脚本自己的提示就是「表真的增减了,就把 EXPECTED_TABLES 与切次报告一起改掉;
这个摩擦是刻意的」** —— 于是 **220 → 221,并在这里报告**。
★ `EXPECTED_CODE_TABLES` **不动**(仍是 75):本表**没有 `code` 列**。
**两个数各自对着一件事,一起改才是可疑的。**

**⚠ 备份闸失败了两次才成,两次的原因不同,都记下来:**
① 第一次 `BACKUP_EXIT=1` —— `pg_dump` 在 `EXECUTE dumpFunc('329030')` 上
**SSL SYSCALL error: Operation timed out**(网络中断)。**脚本做对了事**:
删掉了那个 `.INCOMPLETE`,**没有留下一个看起来像备份的半截文件**,并且**如实退 1**。
② 第二次是**我的**问题:前台 Bash 十分钟到顶,**把它连同子进程一起杀了**
(日志里是 `pg_dump: terminated by user`)。第三次改用 `nohup … & disown`,
**九分钟跑完,绿。**
☞ **没有拿「上一份备份」凑数**:`evoltrya-backup-2026-09-20-1746.dump` 早于 B3 自己那次迁移
(17:52:55),**它不是当前线上结构的还原点**。

**⚠ 按委托书,本刀【没有】跑 141 条路由普查,也【没有】跑停止规则比较器** ——
唯一的屏幕改动落在一条那两样工具够不到的动态路由上。**改用线上真身证明,见 §9。**

---

## §9 · ★★★ 线上真身证明 —— 以一个【真的登录 finance 用户】

走的是**应用自己走的那条路**:anon key 当 `apikey` + **真的密码登录换来的 `access_token`**
→ PostgREST → `rpc`。**不是 postgres,不是 service_role。**

```
✓ PRE         FA-2026-0002 开工前 planned=null
✓ PRE-H       这张卡开工前的留痕行数 = 0
✓ ACCT        一次性账号已建 7891b21e…
✓ ROLE        已挂线上真角色 finance(有 module.finance.view + edit)
✓ LOGIN       真的密码登录,拿到 access_token
✓ WRITE       HTTP 200 · 计划投用日 → 2029-03-17
✓ READ        ★ 以那个登录用户读回了留痕行(HTTP 200)
✓ ROW-1       change_type=updated · changed_columns=["planned_in_service_date"]
✓ ROW-2       null → 2029-03-17
✓ ROW-3       changed_by=7891b21e-1832-4919-8cf3-43a7620ec766 · changed_by_kind=user
✓ ROW-4       ★ 记下来的人【就是】那个登录用户
✓ ROW-5       changed_by_kind='user'
✓ RESTORE     ★ 线上已还原到开工前那一刻(planned=null)
✓ KEEP        ★ 留痕行【留着】:0 → 2(+2)
✓ CLEANUP     临时账号与授权已清干净(残留 0 行)

LIVE_PROOF_RESULT ALL GREEN        LIVEPROOF_OWN_EXIT=0
```

**★ 委托书要的那一行留痕,原样:**

```json
{"change_type":"updated","changed_columns":["planned_in_service_date"],
 "changed_at":"2026-09-20T22:19:40.183994+08:00",
 "changed_by":"7891b21e-1832-4919-8cf3-43a7620ec766","changed_by_kind":"user",
 "old_planned_in_service_date":null,"new_planned_in_service_date":"2029-03-17"}
```

★★ **`changed_by` 就是那个登录用户** —— 这一行是 `auth.uid()` 在
`SECURITY DEFINER` 触发器里**仍然返回调用者**的实证,**不是从文档推的**。

⚠★ **那两行留痕【留着】,而这是对的,不是没清干净** ★⚠
**它们记录的是两件真的发生过的事**(设了计划 · 撤了计划),
而这张表是**只增不改**的:能把它们拿掉的东西,正是本刀要禁止的东西。
☞ **被放回去的是资产卡本身**(`planned_in_service_date` 回到 `NULL`),
**不是历史。** 线上复核:`FA-2026-0002` planned=NULL ·
**`FA-2026-0001` 一个字节都没碰**(planned 仍是 2027-01-01)· 探针账号残留 **0**。

---

## §10 · 改了什么

**数据库(一个迁移,全加,不动任何既有函数的行为)**
`db/migrations/2026-09-20-fahist1-fixed-asset-history.sql` ——
新表 `fixed_asset_history`(23 对带类型列 + `changed_columns` + `changed_by` + `changed_by_kind`)·
`trg_fixed_assets_history`(AFTER INSERT OR UPDATE,**不提列名**)·
`guard_fixed_asset_history_append_only` · `guard_fixed_assets_no_hard_delete` ·
RLS(**只有一条 SELECT 策略**,门与基表同一个 `module.finance.view`)。

**镜像** `db/tables/fixed_asset_history.sql`(新)· `db/tables/fixed_assets.sql`(+2 支触发器)·
`db/functions/` 三支新函数 · `db/anon-grants-baseline.tsv`(**不变** —— 加了又删,见 §7 ③)。

**判据** `db/fixtures/201-a-fixed-asset-remembers-who-changed-it.sql`(新,16 臂)·
`db/fixtures/77`(第 ③ 臂的脚手架,见 §7 ②)· `scripts/check-i18n.mjs`(+`sqlPairFields` 与两条前缀)·
`scripts/check-document-registry.mjs`(`EXPECTED_TABLES` 220 → 221)。

**屏幕** `app/finance/assets/[id]/HistoryPanel.tsx`(新)· 同目录 `page.tsx`(取数 + 页末挂载)·
`messages/en.ts` / `messages/zh.ts`(`assets.history.*`)。

**文档** 本文件 · `docs/known-issues.md`(**关闭**同名条,原文留着)·
`docs/forward-queue.md`(乙表那一行**结清**,原文留着)· `docs/handbacks/B3.md` §4(**就地更正**,原文留着)。

---

## §11 · 我**没有**做的,以及为什么

* **没有回填那两行线上资产的历史。** 它们是测试数据,而**发明一段没人见过的历史,
  比没有历史坏**。面板的空状态照直说留痕从哪一天起算。
* **没有动 7 支写函数里的任何一支。** 委托书:「只加捕获」。
* **没有给 `fixed_assets` 加 `updated_by`/`updated_at`。** Tim 裁的是影子表(选项 ②)。
* **没有碰 `fixtures/120`。** 见 §3 —— 这是本刀的一个设计目标,不是一次省略。
* **没有给 `fixed_assets` 补 UPDATE 策略。** fixture 200 的前提三仍然成立(整门已复核)。
* **没有跑 141 路由普查 / 停止规则比较器。** 委托书明令,理由见 §8。

---

## §12 · 下一刀该知道的两件

1. ★ **那支捕获触发器不提列名,是一条【要守着的】克制,不是一次炫技。**
   `fixtures/201` 的 **P2** 臂在守它。要往留痕里加判断之前,先读 §3。
2. ⚠ **`now()` 在一个事务里是常数** —— 任何要「最新那一行」的代码或判据,
   在同事务多写的场景下都会拿到任意一行。见 §6 末。

---

## §13 · 交回

* **破窗起点:`2026-09-20T21:25:02+0800`** · ~~**状态:PENDING**(终点由 Tim 在 Vercel 上读)~~
  ★★ **已关窗(FA-HIST-1 close-out,2026-09-20)**:
  **Deployment SUCCESS for `620ff83c7f26ad0a7e5501e763916930af94aeb8` —— confirmed by Tim,
  who also checked both history-panel states on the live site, 2026-09-20.**
  **FA-2026-0002 两行留痕画得对;FA-2026-0001 画的是那句具名空状态 —— 两种状态都验过。**
  ⚠ **No clock time was given.**
  ☞ **所以窗口终点只有一个【上界】,没有一次测量:`2026-09-20 22:48:04 +0800`**
  (= 本次 close-out 里 `date` 的输出,部署在这一刻之前**已经**成功)。
  ★ **它是【上界】,不是时长** —— 由它减起点得到的 **≈83 分钟** 是一个
  **不会更小的上限**,真实时长只会比它短。**不要把这个数当成一次测量抄走**
  (本仓库对「一个数被抄走时它的分母掉了」有成文的记载)。
  ⚠ **`db/migration-windows.tsv` 没有动** —— 那张表**没有关窗那一列**,
  它记的只是起点。关窗记在这里。
* 线上:**已还原到开工前那一刻**,探针账号残留 0,两行留痕**按设计留着**。
* 三个 SHA 见本次交回消息。
