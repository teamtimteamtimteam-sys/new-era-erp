# SEARCH-2b —— 停止闸留下的活,做完了(2026-09-13)

> ## ⛔ 先说这份文件的身份
> **四支迁移全部应用到线上。破窗是真的,而且【现在开着】。**
> `SEARCH-2` 那一刀停在应用之前,理由写在它的 §6,而那次判断是对的 ——
> 它当时确实没有一条能跑完的验证链。这一刀把链跑完了,然后才动库。
>
> ★ **§3 的裁定一条都没有重开。** 有两处是【把裁定应用完】,不是改它:
> 一处多出一支函数体(44,不是 43),一处多出一条索引(22,不是 21)。
> 两处各自写明了为什么那不是一次重开 —— 见 §4.1 与 §4.2。

---

## 1 · 开工闸(§1.1 的三条)

| # | 判据 | 读数 |
|---|---|---|
| 1 | `git status --porcelain` | **空** |
| 2 | 本地 HEAD == origin/main == `git ls-remote` | 三者同为 `fce682752c7a3c09e689307fd962443badadd51d` ✓ 且等于 Tim 确认过的那次部署 |
| 3 | 线上仍然干净 | `pg_trgm` **0** · `document_types` **0** · GIN 索引 **0** · 六条序列 **444 / 664 / 705 / 468 / 132 / 60** —— 与 SEARCH-2 §2.2 那张表逐个相同,**没有人来过** |

---

## 2 · 四支迁移,以及它们各自的时刻

| 迁移 | 内容 | 应用时刻(CST) | 形状 |
|---|---|---|---|
| **A** | `pg_trgm` + 39 条 trigram GIN | **18:02:28** | 纯增量 |
| ★ **B** | `document_types`(表 + 40 行种子)+ `document_type_prefix()` + **44 支函数体** | ★ **18:19:30** | **不是增量 —— 破窗从这里开始** |
| **C** | 22 条 `(updated_by, updated_at DESC)` | (见 §7) | 纯增量 |
| **D** | `view_permission` 列 + 5 支搜索函数 | (见 §7) | 纯增量 |

---

## 3 · 停止条件 (g):**40 个前缀,逐个,铸得一模一样**

**证法有两层,而第一层是【不消耗式的】—— 这一条是 SEARCH-2 §2.2 挣来的:**
9 支触发器用 `nextval`,而 **nextval 不回滚**;线上已经被回滚掉的活烧掉 **1,177** 个号。
一支"调用旧路径看看它会产生什么"的 fixture 每跑一次就烧 9 个,而门【重放】fixture。
☞ 所以:无洞的读 `MAX(split_part)+1`(带 `WHERE code LIKE 'PFX-year-%'` 过滤),
有洞的读 `pg_sequence_last_value()` —— 答同一个问题而不消耗。

### 3.1 逐前缀,迁移 B 前后(线上真实数据,40 个全列)

| key | 号 | key | 号 |
|---|---|---|---|
| assay_result | `ASY-2026-0005` | material | `MAT-2026-0077` |
| attendance_period | `ATT-2026-09` | medical_claim | `MC-2026-0002` |
| bank_statement | `BS-2026-0003` | output_batch | `OUT-2026-0665` |
| cash_forecast | `FCST-2026-0001` | payment_out | `PMT-2026-0010` |
| cod | `COD-2026-0003` | payment_receipt | `RCPT-2026-0005` |
| collection_chase | `CHASE-2026-0001` | payroll_period | `PAY-2026-0002` |
| container | `CTR-2026-0012` | pricing_formula | `PF-2026-0002` |
| contract | `CON-2026-0061` | processing_run | `PROC-2026-0706` |
| credit_note | `CN-2026-0002` | purchase_order | `PO-2026-0012` |
| customer | `CUS-2026-0133` | quote | `QT-2026-0003` |
| customer_statement | `STMT-2026-0001` | sales_order | `SO-2026-0005` |
| employee | `EMP-2026-0007` | shipment | `SHP-2026-0002` |
| expense | `EXP-2026-0009` | stocktake | `ST-2026-0086` |
| expense_claim | `CLM-2026-0004` | ★ supplier | ★ `SUP-2026-0445` |
| fixed_asset | `FA-2026-0003` | task | `TASK-2026-0182` |
| freight_document | `FRT-2026-0002` | traceability_report | `TRC-2026-0002` |
| gst_period | `GST-2026-Q3` | wht_remittance | `WHT-2026-09` |
| inbound_batch | `IN-2026-0469` | work_order | `WO-2026-0002` |
| invoice | `INV-2026-0010` | journal_entry | `JE-2026-0078` |
| leave_request | `LV-2026-0004` | management_pack | `PACK-2026-09` |

★ **`SUP-2026-0445` 是这张表里最值钱的一格**:`suppliers` 里存着的最大是
`SUP-2026-0095`。**那 9 种的下一个号不是 MAX(code)+1**,任何按 max+1 算期望值
的证明,九种全错 —— 这张表是按 numbering 分支算的,所以它对。

### 3.2 ★ 而 (g) 还有【第二层】,fixture 给不了

`db/fixtures/100-*.sql` 证的是「下一个号」。**别处有没有被动过,由生成器证:**
`db/migrations/2026-09-13-search2b-document-types.build.py` 对 44 支里的每一支,
把替换**倒回去**,断言与线上当时的定义**逐字节相同**。
☞ 两条断言合起来才是 (g):一条管【输出】,一条管【输出以外的一切】。

**照直说它证不了的:** 并发取号。两个会话同时取号的行为由 advisory lock / 序列
决定,而这一刀一个字都没动它们 —— 但"没动"是逐字节断言给的,不是 fixture 给的。

### 3.3 四种铸码形状,不是一种

写在这里,因为一个"全都是 MAX+1"的期望值公式会让 4 个前缀全错:

| 形状 | 支数 | 例 |
|---|--:|---|
| `seq_year`(MAX+1,4 位) | **27** | `QT-2026-0003` |
| `nextval_year` | **9** | `SUP-2026-0445` |
| `count_month`(月内第几份) | **2** | `PACK-2026-09` · `WHT-2026-09` |
| `period_month` | **1** | `ATT-2026-09` |
| `period_quarter` | **1** | `GST-2026-Q3` |

---

## 4 · 三件【裁定没写、而必须处理】的事

### 4.1 ★★★ 是 **44** 支函数体,不是 43 —— 差的那一支叫 `reverse_payment`

SEARCH-2 六轮统计出 `20 + 9 + 13 + 1 = 43`。那个 `1` 是 `fin_next_payment_code`,
**它自己没有字面量**(前缀是参数),要改的是它的**调用方**。
上一会话点名了 `record_payment:635` 的 `CASE WHEN … 'RCPT' … 'PMT'`,
**没有找到 `reverse_payment:26` 那一条一模一样的**。

**怎么找到的:** 不按名字枚举,按【字面量住的那个空间】枚举 —— 对全部 public 函数
逐支扫 40 个前缀。得到 44。
☞ 这正是 AGENTS.md 「42 支 → 45 支,差的 5 支不叫那个名字」那一条的原样重演。

**为什么这不是重开裁定:** T1 写着「**任何前缀字面量不许活在种子之外**」。
`reverse_payment` 落在那句话管的范围里。**这是把裁定应用完,不是改它。**
线上现在的读数:种子之外的前缀字面量 **0 处**。

### 4.2 ★★ 是 **22** 条 recents 索引,不是 21 —— 而那个数的【分母】掉了一层

* 六轮量的是「**31 张有行的表**里 21 张带 `updated_by`/`updated_at`」—— 分母 **31**;
* 单据种类是 **39 张表 / 40 个前缀**(另外 8 张今天一行都没有)。
  同一个判据放在 39 张上:**22 张两列都有**,多出来的是 `contracts`。

处置照【迁移 A 已经裁过的那条原则】走,一个字不改:
**「document_types 定义的是这套系统能铸什么,不是它铸过什么」** ——
A 给那 8 张空表也建了 trigram GIN。`contracts` 落在同一句话里。

☞ 同一个分母搬家也让「**10** 张未覆盖的表在屏幕上点名」变成 **17** 张(39 − 22)。
★ **而应用层不许把 10 或 17 写死**:那一行由 `search_recents_uncovered()` 现算。
一个抄进 TSX 的数字会在下一次加一张单据表时安静地错掉,而没有任何东西会红。

### 4.3 ★★ 一条索引在两边【渲染成两段不同的文本】,而那与数据无关

实测(线上回滚掉的事务里,同一条索引):

| 读的那一侧的 `search_path` | `pg_get_indexdef` 给出 |
|---|---|
| 含 `extensions` | `USING gin (code gin_trgm_ops)` |
| 不含 | `USING gin (code extensions.gin_trgm_ops)` |

而 `verify_rebuild` / `check_mirrors` 比的**正是这段文本**。线上那条 `search_path`
是**平台给的**(`pg_db_role_setting` 里 postgres 角色上的一条),裸集群的重建没有 ——
于是门会报一处**与镜像、与数据都无关**的漂移。

**处置:** `db/platform-prelude.sql` 补一条 `ALTER ROLE postgres SET search_path …`。
写成 ROLE 级而不是 DATABASE 级,因为线上就是 ROLE 级的,**而且 `db/gate.py` 的 guc
判据只看 `setrole = 0`(库级)—— 写成库级反而会凭空造出一处 GUC 漂移**。
读数:迁移 A 之后整门 `NO DIFFERENCES — the rebuild matches live ✓`。

### 4.4 ★ 一张新表在【重建那一侧】自带 anon 授权 —— 而 prelude 早就把这一幕写下来了

迁移 B 之后整门报 **2 处漂移**,两处都是 `document_types` 的 anon 授权
(`table_grants` + `column_grants`),**而且只在重建那一侧**。

原因不在迁移里:
* 线上建表走 **postgres 在 public 上的默认权限**,那一组**不含 anon**(`pg_default_acl` 实测);
* 而 `db/platform-prelude.sql` 为了重现平台基座,写的是
  `ALTER DEFAULT PRIVILEGES … TO anon, authenticated, service_role`。

☞ **这不是一个意外,prelude 自己那段注释逐字预告过它**,连修法一起:
> 「将来加一张表时会发生什么 —— 线上不会给它 anon,重建会给,于是门会报一处漂移,
> 而修法是【在那张表的镜像里写一句 REVOKE】。**那正是我们要的:一张新表对匿名开不开,
> 必须有人写下来。**」

处置照它写的做:`db/tables/document_types.sql` 里一句 `REVOKE ALL … FROM anon`。
**线上一个字都不用改**(它本来就没给),`db/anon-grants-baseline.tsv` 也一行不动
(线上仍然是它的子集)。

> ★ **而这中间有一次红,记在这里而不是抹掉:** 补 REVOKE 之前那一趟整门
> `GATE_EXIT=1`。同一趟里 `seed:document_types live 40 mirrored 40 **drifted 0**`、
> fixture 100 ✓ —— **线上那一侧是对的,红的是镜像**。AGENTS.md 的规矩正是
> 「门红的时候窗口开着,你去修镜像」,这一段就是那条规矩被执行的样子。

---

## 5 · ★★★ 那个【门按构造抓不到】的陷阱,以及它是怎么被真的验过的

`document_types` 需要 **RLS on + `SELECT USING (true)`**。9 支触发器铸码函数是
**INVOKER**(`prosecdef=f`,实测),生产上以 `authenticated` 跑;没有策略它们读不到前缀。
而 **`db/fixtures` 以 `postgres` 跑,`rolbypassrls=t`** —— 门会一路绿,生产上铸码全部失败。

**验法:不读策略然后自己同意自己。以 `authenticated` 真的跑,并且带反面对照。**

| 格 | 做了什么 | 读数 |
|---|---|---|
| ① | `postgres` 读前缀 | `SUP` —— ★ 但这一格**证明不了生产**(bypassrls) |
| ② | ★ `SET LOCAL ROLE authenticated` 读前缀 | **`SUP`** ← **这一格才是生产** |
| ③ | `authenticated` 调一支真的 INVOKER 铸码函数 | `ASY-2026-0001` |
| ④ | ★ **撤掉策略**,同一格 | **抛 `DOCUMENT_TYPE_PREFIX_MISSING`** ✓ |

★ **④ 是这四格里唯一让前三格有意义的那一格。** 没有它,②的绿可能只是
"RLS 根本没开"。

### 5.1 ★ 而"读不到"必须【抛】,不许返回 NULL

`document_type_prefix()` 读不到就 `RAISE EXCEPTION`。理由不是洁癖:
返回 NULL 会让 `'X' || NULL || '-'` 整体变成 NULL,于是 **code 变成 NULL** ——
一次安静的错误,而不是一次响亮的失败。而 RLS 挡住读的那一刻,正是这支函数
唯一有可能读不到的时刻。(同 ALERT-1「被 RLS 挡下的 UPDATE 不是错误,
它是一次成功的空操作」。)

### 5.2 ③ 那一格的读数是 `ASY-2026-0001`,而线上的下一个号是 `ASY-2026-0005`

**这不是回归,写在这里免得下一个人当成缺陷。** `next_assay_code` 是 INVOKER,
它 `MAX()` 的那张表**在调用者自己的 RLS 之下** —— 一个没有 JWT 声明的
`authenticated` 会话看不见任何行,于是 MAX 落在空集上。
**实测:迁移 B 【之前】同一格给出的也是 `ASY-2026-0001`。** 前后相同,
这一刀一个字都没动它;而"修"它会改掉铸码输出 —— 那正是停止条件 (g) 禁止的。

---

## 6 · 五道闸臂

| 臂 | 住在哪 | 读数 |
|---|---|---|
| ① route 落在真页面上 | `scripts/check-search-registry.mjs` | 40 行 · detail 22 · list 9 · list_q 9 ✓ |
| ② `link_mode` 与 `[id]/page.tsx` / `page.tsx` 对得上 | 同上 | ✓ |
| ③ `list_q` 的列表页**真的读 `q`** | 同上 | ✓ |
| ④ 前缀字面量 **40 / 0** | `db/fixtures/100-*.sql` 第 6 臂 | 线上实测种子外 **0 处** |
| ⑤ `match_columns` 逐列 **authenticated SELECT-granted** | `db/fixtures/100-*.sql` 第 8 臂 | ✓,带正面对照 |

### 6.1 ★ 三次故障注入 —— 一条从没红过的判据不算判据

| 注入 | 它该红在哪 | 读数 |
|---|---|---|
| route 改成不存在的页面 | 判据 ① | `EXIT=1` · `quote: link_mode='detail' 但 app/sales/quotes-does-not-exist/[id]/page.tsx 不存在` |
| `detail` 改成 `list_q`(而它没有列表页) | 判据 ② | `EXIT=1` · `shipment: … 但 app/sales/shipments/page.tsx 不存在` |
| 删掉一行种子 | 覆盖率断言 | `EXIT=1` · `解析出 39 行,期待 40 —— 判据瞎了` |

还原之后 `EXIT=0`,且注入文件与注入前**逐字节相同**。

### 6.2 ★ 判据 ① 开工当天就抓到了一处真的,然后【把自己改对了】

第一版按导航注册表核对 route,当场点名 **`shipment` 的 `/sales/shipments`**。
查下去:那条路径**只有 `[id]/page.tsx`,没有列表页**,所以它从来不是一个菜单去处 ——
`link_mode='detail'` 是**对的**,错的是判据。
☞ 于是判据被改成:**detail 型看 `[id]/page.tsx`,不看注册表**。
**一条抓到了真东西、然后把自己改对了的判据,比一条从没红过的可信。**

### 6.3 ★ 第 5 臂的正面对照,以及它守的那条裁定

一个天真的"匹配所有文本列"面是 **170 列 / 31 张表**,里面包含 `employees` 的
`identity_no` · `work_pass_no` · `work_email` · `work_phone`。
一个持 `module.hr.view` 但没有 `data.view_identity` 的人,在页面上看得见
`legal_name`、看不见 `identity_no`;**若搜索匹配 `identity_no`,他就能拿着一个
身份证号确认它是谁的** —— 而那正是页面刻意扣住的映射。
☞ 第 8 臂另有一格**正面对照**:断言 `employees.identity_no` 对 `authenticated`
**确实不是** SELECT-granted。没有它,"全部通过"可能只是
`has_column_privilege` 在这个库上恒为真。

### 6.4 ★★ 「注释污染扫描」在**同一刀里咬了两次**,第二次咬的是我自己的脚本

1. **第一次**:fixture 100 的第 5 臂(「按 MAX+1 取号的函数必须带 LIKE 过滤」)
   点名了 `master_import_apply` —— 它一支号都不取。命中它的是**它注释里抄着的
   一行** `split_part(code,'-',3)::integer`。
2. **第二次**:迁移 D 的镜像生成器有一句「表镜像里已经有 view_permission 就停」,
   而它被**我自己写在那个文件抬头里的**「…(view_permission 列)」咬住,当场误停。

AGENTS.md 已经记着这一族(「一句注释可以污染将来对它自己的计数」,并且注明
第三、第四次「这一次注释咬的是改写脚本,不是计数」)。**本刀是第五、第六次。**
☞ 两处的药是同一味,而且都不是"下次注意":
  · fixture 100 第 5/6 臂:扫之前 `regexp_replace(def, '--[^\n]*', '')` —— **只看会被执行的字节**;
  · 生成器:判据从"字符串在不在"改成 **`^\s*view_permission\s+text\[\]`(看列声明)**。

### 6.5 ★ 而门当场抓住了第三件:一个 `re.S` 让每个函数镜像吞掉了半支迁移

迁移 D 的镜像生成器用 `(?:^-- ─.*?\n(?:^--.*\n)*)?` 去收函数上方那段注释,
**而它开了 `re.DOTALL`** —— 于是 `.*?` 一路吞到文件开头,把 `ALTER TABLE`、
`COMMENT ON`、整段 40 行 `UPDATE` 全塞进了 `db/functions/search_documents.sql`。

☞ **判词【可重建性】当场退 2 并点了名:**
```
REPLAY FAILED in db/functions/search_documents.sql
    ERROR:  relation "public.document_types" does not exist
  db/platform-prelude.sql IS NOT SUFFICIENT - missing platform objects:
      relation public.document_types
```
(重建先放 `db/functions` 再放 `db/tables`,所以那张表那时还不存在 ——
**这条错正是这个判词存在的理由**:check_mirrors 把镜像放进【线上库里】的临时
schema,那里 `public.document_types` 是在的,它借得到,一路绿。)

处置:切法改成**逐行**(找到 `CREATE` 那一行,往上收紧邻的注释行,往下到
`$function$;`),并且逐支断言 **「只有一支函数、没有 DDL/DML」** ——
一条会红的断言,而不是一次"下次小心"。

### 6.6 ★★ 而**构建链自己**拦下了这道新闸 —— 它不许一支量具说不出自己在看什么

`npm run build` 第一次跑就退 1,红的是 `check-instrument-selfproof`:

```
✗ check-instrument-selfproof:2 处
   · check-search-registry.mjs:缺【瞄准 · AIM】那三行
   · check-search-registry.mjs:在构建链里,却没有任何覆盖断言 ——
     它报 0 条时说不出自己有没有在看。
```

☞ **两条都对,而第一条问出了一件我本来不会写下来的事:**
`check-search-registry` **读的是镜像,不是线上**。这条差别今天是安全的 ——
`db/check_mirrors.py` 的 `SEED_TABLES` 逐行比对把镜像钉在线上 ——
**但那句"今天是安全的"必须被写下来**,否则哪天有人把 `document_types` 从
`SEED_TABLES` 里摘掉,这道闸会对着一份过期的登记表报绿,而它自己看不出来。
瞄准线现在写着这句话。

覆盖断言补了**两条独立的路**(整行正则 vs 只数 `('key',`),并且当场注入验过:
把一行的 `numbering` 写成数字 → `INJ4_EXIT=1`,两条路读出 **39 / 40**,
①②**各自点名**;还原后逐字节相同。

---

## 7 · 应用层 —— **填一个已经存在的槽,不是再开一个面板**

SEARCH-1 的 S2 把 job ① 的槽留在三处,各带一段指名 SEARCH-2 的注释。这一刀填的就是它们:

| 处 | 改了什么 |
|---|---|
| `lib/search/types.ts` | `records.built` 的含义没变,**答案变了**;新增 `recents`(见下) |
| `app/components/search/actions.ts` | `records: { built: true, …}`;空查询时也取 recents |
| `app/components/search/SearchEntry.tsx` | `data-search-slot="records"` 那一节画真结果;新增 `data-search-slot="recents"` |
| `lib/search/records.ts` | **本刀新建** —— href / 模块名那一层翻译,匹配与排序都在库里 |
| `messages/en.ts` · `messages/zh.ts` | 四个新键,两个文件都有(`check-i18n` 自报绿) |

### 7.1 ★ `recents` 字段现在才加,而 SEARCH-1 不加它是对的

SEARCH-1 写着:「这里【没有】recents 字段 —— 一个永远是空数组的 recents,
与『还没建』在屏幕上长得一模一样,而那正是本仓库反复在修的那种谎。」
☞ **那句话在它写下的那天是对的,今天不再对了** —— 迁移 C 与 D 把这一半真的建起来了。
★ 而"空"仍然要说清楚:空的时候面板说的是**「因为你还没编辑过任何东西」**,
不是"没有结果"。这一格今天对大多数人**本来就是空的** ——
**本刀开工时当场重量了一遍**(委托书里的数来自上一份报告,不来自一次测量):

| | |
|---|--:|
| 22 张被覆盖的表合计行数 | **196** |
| 其中 `updated_by` 填了的 | **135** |
| 不同的编辑者 | **21** |
| ★ 而其中**还在 `auth.users` 里**的 | ★ **3** |

☞ 21 个里 18 个是探针残骸。**六个测试者里三个从来没写过一行单据。**
这个数与 SEARCH-2 六轮量到的**逐条相同**,所以那句文案是对的。

### 7.2 ★ `more` 必须是真数 —— 一个 `LIMIT n+1` 答不出"还有几条"

裁定写着「不许静默截断」。`LIMIT n+1` 只答得出**还有没有**更多,答不出**还有几条**,
于是有 50 条时它会报 1。**一个说了个小数的截断提示,与一个不提截断的结果,读起来一样错。**
☞ `search_documents()` 用 `count(*) OVER ()` 在 LIMIT **之前**求出 `total`,
应用拿 `total - 已画出的` 当 `more`。

### 7.3 ★ 两句【SEARCH-1 亲手留下的"到时候要重写"】,都重写了

* `actions.ts` 抬头:「job ② 与 job ③ 一行数据库都不读……**job ① 进来那天,这句话要重写**。」
  → 已改写成四次查询的实际清单,**并且仍然不报毫秒数**:39 张单据表今天合计 319 行,
  规划器在这个体量上永远选 Seq Scan,在这上面测出来的毫秒数量的是往返、不是查询成本。
* `types.ts` 的 recents 段(见 7.1)。

### 7.4 ★ `?? []` 一处都没留 —— 而这是被闸当场抓到的

`lib/search/records.ts` 第一版用 `found.data ?? []`,`check-error-swallowing.mjs`
当场点名 **4 处**。改走 `lib/db-helpers.ts` 的 `mustRows` / `mustOne`,复查
**0 unallowed**。☞ 这一节尤其要紧:recents **本来就经常是空的**,
所以一次静默失败在屏幕上与"你还没编辑过任何东西"长得一模一样。

> ★ **而那一趟整门的红,起因是我自己正在写的这个文件,不是迁移 A。**
> 同一趟里结构比对是 `NO DIFFERENCES`、种子 `drifted 0`。
> **在一棵正在被编辑的树上跑门,会把两个问题混成一个读数** —— 记在这里。

---


### 7.5 ★★ 一条【SEARCH-1 亲手写下、而本刀必须让它红】的判据

`probe-search-results.mjs` 的 **R3** 断言的是
`recordsState === 'not-built'` —— 「单据那一节说的是【还没建】」。
**本刀把它建起来了**,于是 `data-search-records-state` 这个属性根本不再渲染,
R3 当场红:`SEARCHPROBE_OWN_EXIT=1`。

☞ **两个错的修法,各错在不同的地方:**
* **删掉它** —— 那就把「找不找得到单据」变成没有人看着的事;
* **留着它** —— 那就留下一条【永远红】的判据,而永远红的判据会被人学会忽略。

**处置是【换】:** R3 现在断言 ① 不再画「还没建」(`recordsState === null`)、
② 至少一条命中、③ 命中里带着搜的那个号。
★ 而那个号**从线上现读**(取 `quotes` 里 `code` 最大的一条),不写死 ——
**一个写死的号会在那一行被删掉的那天为了错的理由变红,而那天没有人分得清
红的是"搜索坏了"还是"那行没了"。** 取不到号就抛,不许当成通过。

实测:`R3.records-slot-is-built-and-finds-one` ✓ ——
命中「`ZZ-SMOKE-QT-CJK` 备注:本次报价含中文说明…」,
**一张真的报价单,从面板里打字搜出来的。**

---

## 8 · 停止条件 (a)–(f) —— 逐条,改前 / 改后

**基线是 SEARCH-1 的 after 读数**,而【是哪一份】要说清楚:
`.survey-out/search1-after/controls-drift-baseline.json`,`at = 2026-09-13T06:11:13Z`,
**142 条路由 × 2 个视口 = 284 组** —— 与 SEARCH-1 §4.2 报的 284 组对得上。
(同目录下还有一份 `search1-after-repair`,只有 3 条路由,是那一刀的定点复读,
**不是全量基线**;取错会让 281 组【无人比对】而读数照样打印绿色。)

### (d) S2 的五份关闭输出 —— **一字未动**

`git diff --numstat` 逐个:`control-style.ts` · `input.tsx` · `textarea.tsx` ·
`globals.css` · `table-style.ts` —— **五个都是 0 行**。

### ★ (f) 顶栏自己的盒子 —— 与 SEARCH-1 的读数**逐字相同**

`scripts/probe-nav-geometry.mjs` · `NAVGEO_OWN_EXIT=0`(13 格,0 红),10 次读数:

| 视口 | SEARCH-1 的 after | 本刀 |
|---|---|---|
| 1280 | `1280x53 @top=0 pad=0/0/0/0 sticky z=50` | ★ **逐字相同**(6 次读数) |
| 390 | `390x55 @top=0 pad=0/0/0/0 sticky z=50` | ★ **逐字相同**(4 次读数) |

★ SEARCH-1 顺带量过的两个盒子也一并对上了:
顶栏那一格搜索框 **`200x32`**、首页那个入口 **`358x49.02`** —— **两个都没动**。

### ★ (e) `/brand-sampler` —— 860 / 903,两个视口都对上

`scripts/probe-brand-sampler.mjs` · `SAMPLER_OWN_EXIT=0`

| | desktop @1440 | phone @390 |
|---|--:|--:|
| 渲染成员 | **860**(SEARCH-1:860) | **860**(SEARCH-1:860) |
| 连不渲染的一起数 | **903** | **903** |
| 顶栏那一堆 | 43 | 43 |

★ **我量的是 `next start`**(探针自己起的,`:3204`)—— 所以那个数是 **903**;
`next dev` 上同一支探针给的是 916。**委托书要求说出这句话,因为两个数都对,
而拿错一个就会把"没变"读成"变了"。**

### (g) 每一个单据码仍然铸得一模一样 —— 见 §3

### (a)(b)(c) —— `scripts/check-stop-rules-abc.mjs` · `STOPRULE_ABC_OWN_EXIT=0`

```
视口 2 个(desktop / phone)
路由×视口 282 组比过 · 表 184 张比过 · 字段比较 650 次
改前就在溢出的:5 组 —— phone|/finance/freight/new=27px · phone|/operation/processing/new=177px
                       · phone|/purchasing/payment-terms/new=143px · phone|/sales/orders/new=8px
                       · phone|/tools/pricing/metal-prices/bulk=24px
✓ (a)(b)(c) 一条都没踩。
```

★ **委托书点名的那 5 条,逐条重量、逐条对上**;`/sales/orders/new`(8px,已知修不动)
**本刀一个字都没碰**。

#### ★★ 而这一趟里有一格【差点以一个干净的零蒙混过去】

第一次比对报的是 **281 组**,并且自己说出了 **3 组「只有一侧量到、因此不作数」**:

| 不作数的格 | 是什么 |
|---|---|
| `desktop /brand-sampler` · `phone /brand-sampler` | 本刀的 drift 枚举到 **141** 条路由,SEARCH-1 的基线是 **142** —— 差的就是它 |
| ★ **`phone /finance/freight/new`** | ★ **改后那一侧 `failed`**:`renderer wedged … CDP timeout: Runtime.evaluate` |

☞ **第三格是要命的那一格**:`/finance/freight/new` 正是【(b) 点名的 5 条之一】。
**退出码那时已经是 0** —— 而那个 0 的意思是"比过的都没踩",不是"那条路由没长大"。
一支老实的比对器把这件事**说了出来**(「这一格【不作数】,不是"没变"」),
而本仓库反复付账的正是它的反面:**一个把"没量到"渲染成"没变化"的读数。**

处置:**定点复读那一条路由**(`--only=/finance/freight/new`),读数
`docScrollW=417 · docClientW=390` ⇒ **溢出 27px,与基线逐字相同**;
合并回改后那份读数(`controls-drift-merged.json`,**合并时断言"一格 failed 都不许剩"**),
再比一次 → **282 组**,不作数的只剩 `/brand-sampler` 那两格。

#### ★ 而那两格【不是缺口】—— 它们由 (e) 那支专门的探针覆盖

```
282 组(drift 比对)+ 2 组(/brand-sampler × 2 视口,probe-brand-sampler 逐成员比)
= 284 组 —— 与 SEARCH-1 §4.2 报的 284 组【正好对上】
```
☞ 这一行值得写出来,因为「141 对 142」单看像是漏了一条路由;
**它没有漏,它换了一支更严的量具**(那支探针比的是 860 个成员的逐个签名,
不是一条 docScrollW)。

---

## 9 · ★★★ 破窗 —— 这一刀【有】,而且这一行是量出来的

**窗口 = 迁移提交的时刻 → 部署 `state=success` 的时刻。**

| | |
|---|---|
| **起点(A,良性)** | `2026-09-13T18:02:28+0800` —— 纯增量:装一个扩展 + 39 条索引。旧代码不读它们,**期间没有任何东西是坏的** |
| ★ **起点(B,真正的那个)** | **`2026-09-13T18:19:30+0800`** |
| **终点** | **还没有** —— 等 Tim 确认部署 |

### 期间什么是坏的 —— 两件都要说,缺一个都不成立

* **B 不是增量的。** 它重写了 44 支函数体:提交的那一刻起,**生产上每一次开单据
  走的都是新路径**,而新代码还没部署。
* ★ **而它在窗口里是安全的,靠三件事,缺一不可:**
  1. **签名一个字没变** —— 调用方不必知道这件事发生过(预检读数:
     `45 条 CREATE FUNCTION:44 替换 · 1 新建`,零重载);
  2. **种子与 44 支函数体在同一笔事务里** —— 少一行种子而新函数体已经上线,
     等于生产上开不出任何单据;
  3. **(g) 逐前缀证过输出相等,生成器逐字节证过别处没动。**
* ☞ **所以窗口里【没有任何已知的坏东西】** —— 旧代码调的还是那 44 个签名,
  拿回来的还是那 40 个号。窗口的代价是**风险**,不是**已知损伤**:
  一旦有什么不对,生产上错的会是【开单据】这条路,而那是这套系统最中心的一条。
* **C 与 D 是纯增量**,窗口对它们是良性的。

> ### ☞ 所以这次的部署确认是【有时限的】,而前几次不是。

---

## 10 · 每一条命令,以及**它自己打出来的那一行退出码**

★ 一律取【脚本自己那一行】,不取启动器的状态 —— `db/run_detached.sh` 的判词
只认日志里的 `^GATE_EXIT=` / `^BACKUP_EXIT=`,这张表也只抄那一行。

| # | 命令 | 它自己那一行 | 备注 |
|--:|---|---|---|
| 1 | `psql` 开工闸(pg_trgm / document_types / 六条序列) | `PSQL_OWN_EXIT=0` | 线上仍然干净 |
| 2 | 线上回滚式全量证明(捕获 40 → 应用 B 全文 → 重算 40 → fixture 100) | `PROOF_OWN_EXIT=0` | **一个号都没烧**:回滚后六条序列逐个不变 |
| 3 | RLS 四格(含反面对照) | `RLS_OWN_EXIT=0` | ④ 撤掉策略当场红 |
| 4 | A+B+C+D 同一笔事务,回滚 | `ABCD_OWN_EXIT=0` | 四支迁移互相之间没有冲突 |
| 5 | `python3 db/gate.py --offline`(A 之前) | `GATE_EXIT=0` | 46s |
| 6 | `~/evoltrya-backups/backup.sh`(A 之前) | `BACKUP_EXIT=0` | TOC 5593 |
| 7 | `./db/apply_migration.sh …search2a…` | `✓ committed atomically` | 18:02:28 |
| 8 | `python3 db/gate.py`(A 之后) | `GATE_EXIT=1` | ★ 红的是**我当时正在写的那个应用文件**(见 §7.4),结构比对 `NO DIFFERENCES` |
| 9 | `node scripts/check-error-swallowing.mjs` | `0 unallowed` | 改走 `mustRows`/`mustOne` 之后 |
| 10 | `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` | 四个新键 en/zh 都有 |
| 11 | `node scripts/check-search-registry.mjs` | `REGISTRY_OWN_EXIT=0` | 40 行 · detail 22 · list 9 · list_q 9 |
| 12 | 同上,三次故障注入 | `EXIT=1` · `1` · `1` | 还原后 `EXIT=0`,文件逐字节相同 |
| 13 | `python3 db/gate.py --offline`(B 之前) | `GATE_EXIT=0` | 47s |
| 14 | `~/evoltrya-backups/backup.sh`(B 之前) | `BACKUP_EXIT=0` | TOC 5665 |
| 15 | `./db/apply_migration.sh …search2b…` | `APPLY_B_OWN_EXIT=0` | ★ 18:19:30 · 预检 `44 替换 · 1 新建` |
| 16 | 线上核验 B(种子 / 序列 / authenticated / 字面量) | `VERIFY_B_OWN_EXIT=0` | 40·40·9 · 序列不变 · `SUP` · **0 处** |
| 17 | B 前后 40 个号逐条比 | `POSTB_OWN_EXIT=0` | **逐字节相同** |
| 18 | `supabase gen types typescript` | `GENTYPES_OWN_EXIT=0` | |
| 19 | `python3 db/gate.py`(B 之后) | `GATE_EXIT=1` | ★ 唯一漂移:`document_types` 的 anon 授权,**只在重建侧**(见 §4.4);同趟 `seed drifted 0`、fixture 100 ✓ |
| 20 | `python3 db/gate.py`(B 之后,补上 REVOKE) | **`GATE_EXIT=0`** | 225s · 四个判词全绿 |
| 21 | `python3 db/gate.py --offline`(C 之前) | `GATE_EXIT=0` | |
| 22 | `~/evoltrya-backups/backup.sh`(C/D 之前) | `BACKUP_EXIT=0` | TOC 5675 |
| 23 | `./db/apply_migration.sh …search2c…` | `APPLY_C_OWN_EXIT=0` | 18:40:51 |
| 24 | `python3 db/gate.py`(C 之后) | **`GATE_EXIT=0`** | 194s · 四个判词全绿 |
| 25 | `python3 db/gate.py --offline`(D 之前,第一次) | `GATE_EXIT=2` | ★ **重建建不出来** —— 一个 `re.S` 让函数镜像吞掉了半支迁移(§6.5) |
| 26 | `python3 db/gate.py --offline`(D 之前,切法改对之后) | `GATE_EXIT=0` | fixture 101 ✓ |
| 27 | `./db/apply_migration.sh …search2d…` | `APPLY_D_OWN_EXIT=0` | 18:49:22 · 预检 `5 新建 · 0 替换` |
| 28 | 线上跑一遍三支搜索函数 | `CDTEST_OWN_EXIT=0` | 22 索引 · 40 种全有闸 · `uncovered=17` · **limit 2 时 total 仍是 58** |
| 29 | `npm run types:gen` | `TYPESGEN_OWN_EXIT=0` | |
| 30 | `npx tsc --noEmit` | **`TSC_OWN_EXIT=0`** | |
| 31 | `npm run build`(第一次) | `BUILD_OWN_EXIT=1` | ★ `check-instrument-selfproof` 拦下新闸(§6.6) |
| 32 | `node scripts/check-search-registry.mjs` 注入覆盖断言 ② | `INJ4_EXIT=1` | 两条路读出 39/40,①②各自点名;还原后逐字节相同 |
| 33 | `npm run build`(补上瞄准线与覆盖断言) | **`BUILD_OWN_EXIT=0`** | `BUILD_ID=Z0GJ1ljzH1dQSlW2Prdgq` |
| 34 | `python3 db/gate.py`(D 之后,第一次) | `GATE_EXIT=1` | ★ 唯一漂移:`view_permission` 的**列注释**只在线上;`seed drifted 0`、fixture 101 ✓ |
| 35 | `python3 db/gate.py`(D 之后,补上列注释) | **`GATE_EXIT=0`** | 254s · ★ **四支迁移全部落地,四个判词全绿** |
| 36 | `node scripts/check-nav-routes.mjs` | `NAVROUTES_OWN_EXIT=0` | 注册表 101 · 路由 232 · 埋着的屏幕 0 |
| 37 | `node scripts/smoke-routes.mjs` | **`SMOKE_EXIT=0`** | 223 条计时 · 合计 533.1s · 中位数 2221 ms |
| 38 | `node scripts/probe-search-results.mjs`(第一次) | `SEARCHPROBE_OWN_EXIT=1` | ★ **R3 红** —— 它断言的正是本刀要取消的那个状态(§7.5) |
| 39 | 同上,R3 改写之后 | **`SEARCHPROBE_OWN_EXIT=0`** | 10 格 0 红 · R3 真的搜到一张单据 |
| 40 | `node scripts/probe-nav-geometry.mjs` | **`NAVGEO_OWN_EXIT=0`** | 13 格 0 红 · (f) 的那张表见 §8 |
| 41 | `node scripts/probe-brand-sampler.mjs` | **`SAMPLER_OWN_EXIT=0`** | 860 / 903 两个视口 · ★ 跑在 `next start` 上 |
| 42 | `survey-controls --mode=drift`(第一次) | `DRIFT_EXIT=2` | ★ 它**拒绝**在生产 `.next` 上跑 `next dev`,并说出了修法 |
| 43 | `rm -rf .next` 之后重跑 | **`DRIFT_EXIT=0`** | 141 条路由 × 2 · 覆盖断言 11 条 |
| 44 | `check-stop-rules-abc`(第一次) | `STOPRULE_ABC_OWN_EXIT=0` | ★ **281 组**,而它自己点出 **3 组不作数**(§8) |
| 45 | drift 定点复读 `/finance/freight/new` | `DRIFT_EXIT=0` | `docScrollW=417 · docClientW=390` ⇒ 27px,与基线相同 |
| 46 | `check-stop-rules-abc`(合并之后) | **`STOPRULE_ABC_OWN_EXIT=0`** | **282 组** · 不作数只剩 `/brand-sampler` ×2(由 (e) 覆盖) |
| 47 | `npm run build`(收尾,`.next` 被 drift 清掉之后重建) | **`BUILD_OWN_EXIT=0`** | `BUILD_ID=fam8vWSBKqOAqB7ua649O` |

> ★ **两个 BUILD_ID,而这不是笔误:** `Z0GJ1ljzH1dQSlW2Prdgq` 是量那三支探针时
> 树上跑的那一个(`next start`);drift 要 `next dev`,而它**拒绝**在生产 `.next`
> 上跑并说出了修法,于是 `.next` 被删掉重来,收尾那次建出 `fam8vWSBKqOAqB7ua649O`。
> **两次建之间树一个字都没改**(改的是 `.next`,一个可再生的缓存)——
> 而这句话要写出来,因为委托书点名过 SEARCH-1 那次「对着旧 build 量出一个
> 干净的零」。这里的顺序是【量完再建】,不是【建完再量】。

---

## 11 · 我【没有】做的,以及【证不了】的,逐条点名

* ★ **并发取号没有被证过。** (g) 证的是「下一个号」;两个会话同时取号的行为由
  advisory lock / 序列决定,而这一刀一个字都没动它们 —— 但"没动"是生成器的
  逐字节断言给的,不是 fixture 给的。
* ★ **`search_documents_withheld()` 在两张表上【少报】。** `assay_results` 与
  `contracts` 的 SELECT 策略是**按行析取**的(`customer_id IS NOT NULL AND has_permission('A')
  OR supplier_id IS NOT NULL AND has_permission('B')`)。一个持 A 不持 B 的人
  看不见 B 那一类的行 —— 那**是**一次模块扣下,但数出它要逐行看列的内容。
  本支的规则是「一个码都不持有才计」,所以那一格偏在**少报**这一边 ——
  **不声称自己知道**。写在迁移 D 的抬头与 `lib/search/records.ts` 的抬头。
* ★ **一次搜索在生产上要多久,仍然没有量。** 39 张单据表今天合计 **319 行**,
  规划器在这个体量上永远选 Seq Scan;在这上面测出来的毫秒数量的是往返,
  不是这支查询的成本。**报一个毫秒数就是编一个数。**
  ☞ 迁移 A 的抬头量过那个拐点:合成 20 万行时 trigram **12.0ms vs 33.4ms(2.8×)**。
* ★ **`next_*_code` 在 INVOKER 下受调用者 RLS 影响** —— 一个看不见既有行的
  会话会从 0001 重新数(§5.2)。**这是既有行为,前后相同,本刀没碰**;
  "修"它会改掉铸码输出,而那正是 (g) 禁止的。**在册,不在本刀。**
* **「限定在本页主语之内」** —— SEARCH-1 留的另一半,不在这一刀里(它要的是
  「今天没有机读的本页主语」,SEARCH-0 已经量过)。
* **标签列的 trigram 索引** —— 迁移 A 的抬头已立案:「标签列将来也需要同样的
  处理,那不是这一刀的事」。今天标签匹配走的是 `ILIKE`,没有索引。

---

## 12 · ★★ 这一刀被【本仓库自己的量具】抓到四次,而四次都在库之外

写下来,因为它们合起来说明一件事:**这套闸是有效的,而它今晚挡下的全是我的工具,
不是数据库。**

| # | 谁抓的 | 抓到什么 |
|--:|---|---|
| 1 | `check-error-swallowing` | `lib/search/records.ts` 里 4 处 `?? []` —— 一次查询失败会被画成**「你还没编辑过任何东西」**。改走 `mustRows`/`mustOne` |
| 2 | **判词【可重建性】**(退 2) | 一个 `re.S` 让每个函数镜像吞掉半支迁移。★ **`check_mirrors` 会放它过去** —— 它把镜像放进【线上库里】的临时 schema,那里 `document_types` 是在的,借得到。**只有真的建进一个空库才看得见**(§6.5) |
| 3 | `check-instrument-selfproof` | 新闸说不出【它读的是什么】、也没有覆盖断言(§6.6) |
| 4 | **判词【镜像 vs 线上】** | `view_permission` 的**列注释**只在线上 —— 镜像生成器抄了列和 CHECK,漏了注释 |

另有两处是我自己在跑闸之前发现并修掉的,都属于同一族:
**注释污染扫描**(fixture 100 第 5 臂被 `master_import_apply` 的注释咬 · 生成器被自己
抬头里的一句话咬,§6.4)。**AGENTS.md 里那一族已经记着四次,本刀是第五、第六次。**

> ★ **一条都没有落在铸码上。** (g) 在 B 下去之前证过,B 下去之后又对着落地状态
> 重证了一遍。

---

## 13 · ★★★ Tim 现在要做的那一件事,以及为什么这一次【有时限】

**看一眼 Vercel,确认这次部署 `state=success`。**

★ **而这一次和前几次不一样,原因写在这里,不是客套话:**
前几刀的窗口里,库是【加了东西】的,旧代码看不见也碰不到 —— 窗口开着不疼。
**这一刀的 B 重写了 44 支铸码函数体。** 从 18:19:30 起,生产上每一次开单据
走的都是新路径,而应用还没换。它今天是安全的(签名没变 · 种子同事务 ·
逐前缀逐字节证过),**但它的安全靠的是三条证据,不是靠"这一刀没动什么"。**

☞ 所以:**窗口关掉之前,这一刀不算做完**,而窗口的终点只有 Tim 看得见
(AGENTS.md 的常设规矩:部署是 Tim 自己看的,这台机器够不到 Vercel)。

---

## 14 · 下一刀

* **标签列的 trigram 索引** —— 迁移 A 的抬头已立案。今天标签匹配走 `ILIKE`,无索引;
  而 job ① 的匹配面里标签那一半是最可能先长起来的。
* **「限定在本页主语之内」** —— SEARCH-1 留的另一半。它要「机读的本页主语」,
  而 SEARCH-0 量过:今天没有。**那是一刀勘察,不是一刀实现。**
* ★ **`search_documents_withheld()` 在 `assay_results` / `contracts` 上少报的那一格**
  (§11)。要把它数对,得让策略的【按行析取】变成可机读的东西 —— 而那是
  「策略谓词的结构化表示」这一类的活,比这一刀大。**在册,有名字。**
* ★ **`next_*_code` 在 INVOKER 下从 0001 重新数**(§5.2)。既有行为,本刀没碰,
  **而碰它就会改掉铸码输出** —— 所以它要么是一刀专门的、带 Tim 裁定的改动,
  要么永远不动。不要顺手"修"它。

*(填于收尾)*
