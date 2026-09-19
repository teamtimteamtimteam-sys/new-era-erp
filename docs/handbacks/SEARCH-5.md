# SEARCH-5 交回 —— 可点击的关联分组(**建成了,而它比委托书描述的大一点**)

> **一句话:** 那一行「进料批 11」现在点得动,落在 `/related/supplier/<uuid>/inbound_batch`
> 上,画 11 行,而**点击走的是软导航**(探针在 `window` 上盖了记号,记号活过了那次换页)。
>
> ★ **而这一刀【不是】委托书写的那个「纯增量、什么都不会坏」的形状。** Tim 的 W1
> 把那 5 种单据折了进来,于是它同时**改了一条既有的 CHECK 约束与 5 行既有数据** ——
> 破窗那一节照实情写,不写"良性"两个字。
>
> ★ **停止闸自己有两个数是错的**,而两个都不改变裁定:
> 「89 组无向表对」**实测 94**(那个 89 是 178 ÷ 2,是算术不是计数);
> 「33 条列表路由里 32 条走共享组件」**实测 31 条** —— ★ 而**停止闸自己的 §4.1 表格
> 就写着第二个例外**(`/sales/shipments` 连 `page.tsx` 都没有),它在同一份文件里
> 与自己的标题矛盾。

---

## 1 · 开工闸(§1.1)

| # | 判据 | 读数 |
|---|---|---|
| 1 | `git status --porcelain` | **空** |
| 2 | 本地 HEAD == `origin/main` == `git ls-remote origin main` | 三者同为 **`7f1eb46fd95d5fc8d270bd80f8390639ced38c97`**,逐字 40 字符相同,且等于 Tim 确认过的那次部署 |

---

## 2 · ★ 每一个数当场重量一遍(§1.2)—— **包括量下来是对的那些**

**量法一律写在旁边。没有量法的数,下一刀重量不起来。**

### 2.1 量下来是对的

| 说的 | 实测 | 量法 |
|---|--:|---|
| 39 张登记表 · 40 个 key · 33 条 route | **39 / 40 / 33** | `document_types` 线上现读 |
| `document_relations` 254 条边 | **254** | `count(*)` |
| **178** 条有向表对 | **178** | `count(DISTINCT (from_table,to_table))` |
| **397** 条外键 | **397** | `pg_constraint contype='f'`,public |
| **140 / 178** 含无界边 | **140** | `kind IN ('in','bridge')` 的去重对数 |
| **31 / 40** 有 `label_column` | **31** | `label_column IS NOT NULL` |
| 一个分组自己最大 **11** | **11**(`supplier SUP-2026-0002 → inbound_batch`) | 40 个 key × 每张表逐行调 `search_related()`,`postgres` 身份(**上界**) |
| 一条命中所有分组合计最大 **30** | **30**(`material MAT-2026-0001`) | 同上 |
| 一条命中最多 **7** 组 | **7** | 同上 |
| 登记单据表合计 **325** 行 | **325** | 39 张**去重**表逐表 `count(*)`(逐 key 扫是 338 —— payments 被两个 key 各扫一次) |
| 树里 `PAGE_SIZE` **17 处全是 20** | **17 处,17 个 20** | `grep -oE "PAGE_SIZE *= *[0-9]+"` |
| 6 种单据没有任何系统级列表页 | **6**(assay_result · cod · traceability_report · collection_chase · customer_statement · shipment) | 逐条路由查 `page.tsx` |
| `expense_claim` 的列表在它登记路由之外 | **确认**:`/hr/claims` 读 `medical_claim_status`,`/finance/claims` 读 `expense_claim_status` | 读两页的 `.from(...)` |
| 那 5 种的 `?q=` 结构上永远 0 行 | **确认** | `/inbound` 过滤 `inbound_batches.code.ilike` + 物料/供应商 id;`/output` 过滤 `output_batches.code`;`/sales/customers` 过滤 customers 五列。**前缀一个都不重叠** |
| **16** 条边指向那几种没有列表页的单据 | **16** | `document_relations` 里 to_table 落在那 7 张表上的去重 (from,to) 对 |
| W2 的三条关系今天存在 | **确认**:`employees→expense_claims` · `expenses→expense_claims` · `sales_orders→assay_results` | 同上 |
| `containers` 那一行 42501 报错 JSON | **确认**,`id = f21b293a-bc5c-46de-9b54-3f1a8a4e1329`,106 字符 | `code !~ '^[A-Z0-9-]+$'` |
| 一次跨 39 张表的全扫约 **67s** | **64s** 墙钟 | 一条 HTTP 往返 |
| `gate.py --offline` **46s** | **46s** | 本刀自己跑的那一趟 |

### 2.2 ★★ 量下来是**错的** —— 两条

#### ① 「**89** 组无向单据↔单据」→ ★ **实测 94**

```
有向表对            178
  其中自指           10      ← 一个自指对映射成【一个】无向对,不是半个
  其中带反向的       168  = 84 个无向对
无向对合计         10 + 84 = 94
```

☞ **那个 89 = 178 ÷ 2。它是一次除法,不是一次计数。** 停止闸把它标成 CONFIRMED,
而它"确认"的办法正是那次除法 —— **一个被郑重确认过的数,反而比没人确认过的更容易被信**
(AGENTS.md 的 CONFIRM-1 那一节逐字记过这个形状)。
★ **它不改变任何裁定**:本刀一条判据都没有吊在这个数上。**照直记,不藏。**

#### ② 「33 条列表路由里 **32** 条走 `<ListPage>` + `<DataTable>`」→ ★ **实测 31**

```
量法(停止闸自己声明的那一条:只看路由目录【自己】那一层的 .tsx,不看 [id] 子树)
  两者都有 …… 31 条
  两者都无 ……  2 条   /tools/tasks(看板)· ★ /sales/shipments(目录里【一个 .tsx 都没有】)
```

☞ ★★ **而停止闸自己的 §4.1 表格就写着那第二个例外**
(「`/sales/shipments` 目录下只有 `[id]`,连 `page.tsx` 都没有」)——
**它在同一份文件里与自己的标题矛盾,而没有人把两处并排读过。**
★ **结论不变,而且更硬**:31/33 仍然压倒性地说明共享页是【填槽】不是【造机器】。

### 2.3 ★★ 停止闸**没有量到**、而这一刀撞上的两件事

#### ① **6 张单据表对 `authenticated` 没有表级 SELECT** —— 而这一支函数比它哥哥**多读一列**

`search_related()` 只取 `t.id, t.code`。`search_related_rows()` 还要取 `label_column`,
而**那一列正是遮蔽存在的理由**。

| | 读数 |
|---|--:|
| 39 张单据表里,对 `authenticated` **没有表级 SELECT** 的(只有列级授权) | ★ **6** —— `employees` · `inbound_batches` · `invoices` · `pricing_formulas` · `processing_runs` · `purchase_orders` |
| 31 个有 `label_column` 的种类里,`code` 或 label **读不到**的 | **0** |

☞ **今天一个缺口都没有,而今天【没有任何东西】盯着它。** 一次撤掉某个 label 列授权的
改动,会让这一支对那一类单据**整页报错**,而不是少显示一列。
★ 所以 **fixture 199 多了一条 F 臂**,逐个单据种类断言两列真的读得到 ——
AGENTS.md「给遮蔽表加一列要连授权一起加,否则它是隐形的」的另一半:
**给一支共享函数加一列要连授权一起断言,否则它是会爆的。**

#### ② 生成的类型**说不出** SQL 参数的可空性 —— 而它逼出了迁移 `-fu1`

`supabase gen types` 按**有没有 DEFAULT** 决定一个参数可不可省。主迁移把
`p_key` / `p_id` 写成无默认值的必填参数,于是生成的类型是 `p_key: string` ——
**「这两个参数永远有值」,而那句话是假的**(无主语那一形状按设计两个都不给)。

☞ 两条路,选了后一条并写下理由:

| | |
|---|---|
| 在调用点写 `as unknown as …Args` | ✗ **本仓库刚为这个形状付过账**(BUGFIX-1a:6 句 `as never` 挡住了唯一看得见 `container_no` 不存在的那道闸,一条死查询活了 8 天)。一句 cast 关掉的是**整个参数对象**的检查 |
| ★ 让 SQL 把自己的意思说完整(`-fu1`:三个前导参数 `DEFAULT NULL`) | ★ **选它。** 预检报 **`1 替换 · 0 新建`** —— 参数类型与顺序逐字未变,不是重载 |

⚠ `p_target_key` 也跟着拿了默认值,**而它不是可选的**:PostgreSQL 不许带默认值的参数
后面再跟不带默认值的,而**参数顺序不能动**(动了就是重载,`preflight_migration.py` 当场拒)。
☞ 它缺席时函数**自己响**:`SEARCH_UNKNOWN_DOCUMENT_TYPE|(null)`。

---

## 3 · Tim 的三条裁定,逐条交付

### W1 · Q7 = **YES,折进来了**

**做法:`document_types.link_mode` 加第四种 `'type_list'`,那 5 行重新指向。**

| | |
|---|---|
| 改前 | `list_q` → `<route>?q=<code>`,而那一页过滤的是**别的表**的 code,前缀不重叠 ⇒ **结构上永远 0 行** |
| 改后 | `type_list` → **`/documents/<key>`**,那一页列的**就是它自己** |

#### ★ 那个「没有主语」的区分 —— 它要了**第二条地址**,理由是机制不是口味

Tim 点名的那条区分(关系分组点击有主语,命中点击没有)落成**两条地址、一个组件**:

```
有主语   /related/<subjectKey>/<subjectId>/<targetKey>    「NMC Cathode Foil 的产出批」
无主语   /documents/<typeKey>                              「化验单」
```

**为什么必须是第二条地址,而不是三段里塞一个哨兵 —— 两条理由,第一条是硬的:**

1. ★ **Next 的路由【不允许】同一层上出现两个不同名字的动态段。**
   `app/related/[subject]` 与 `app/related/[target]` 做兄弟是一个**构建期错误**。
2. ★ 往三段里塞 `/related/none/none/assay_result` 之类的哨兵,会让一段
   **读起来像 id 的东西**其实不是 id。而把一份**全表列表**叫作「关联」,
   **地址本身就在说一句假话**。

☞ **共用的那一半是【组件】,不是【地址】**:`app/components/related/related-records.tsx`
两条路由都渲染它;两个 `page.tsx` 各自只做一件事 —— 把参数解析出来。

#### ⚠ 它换掉的那件事,照直说

| | |
|---|---|
| 今天 | 搜到一张化验单、点开 → 一张**保证空**的进料批列表,屏幕上写「没有符合条件的记录」 |
| 改后 | → **全部化验单**的列表,那张单据**真的在里面**,但要自己找(按单据号降序,20 条一页;实测化验单今天一共 **4** 条) |

☞ 这不是"精确定位",**它是 Tim 在 W1 里裁的形状**:一次命中点击说的是「化验单」。

★ **而它顺带【收掉】一处既存的披露**:这 5 种今天把单据号放进 `?q=`,
改完之后地址里只剩单据种类的 key。**本刀不扩大 URL 披露,反而少了 5 种**
(`list_q` 从 9 种降到 **4** 种)。

### W2 · Q8 = **YES,开行** —— ★ 交换按要求存档

> **存档(下一份委托书不许重新推导这一条):**
> **① Tim 早先那条理由的字面是「一个持 `module.hr.view` 的读者在页面上本来就看得见那张列表」——
> 承重的词是【那一页】。**
> **② 而对这三条关系(`employee → expense_claim` · `expense → expense_claim` ·
> `sales_order → assay_result`),【那一页不存在】** —— 勘察量到它们今天没有任何地方在列。
> **③ 于是 Tim 改从【权限】那一半裁**:总裁定是关于权限的,而权限这一侧三条全部成立 ——
> 看得见这些行的人都持着一个已经给了他全量列表的模块闸。
> ④ **不开会让搜索比数据库自己更严,而"更严"是这套系统从没有裁过的方向。**

**本刀量到的 RLS(线上现读),它是 ③ 的证据:**

| 表 | SELECT 谓词 |
|---|---|
| `expense_claims` | `has_permission('module.finance.view') OR employee_id = current_user_employee()` |
| `assay_results` | `(inbound_batch_id IS NOT NULL AND module.inbound.view) OR (output_batch_id IS NOT NULL AND module.output.view)` |

⚠ **一处措辞更正:** 停止闸把 `medical_claims` / `leave_requests` 写成**一条**析取策略。
实测是**两条各自独立的 permissive 策略**(`… select by permission` 与 `… select own rows`)。
**求值结果逐字相同**(permissive 策略之间就是 OR),所以结论不变 —— 记下来是因为
下一个按「一条策略」去 grep 的人会找不到它。

**落地:不写任何一张按关系的名单。** 三条关系和别的 178 条走**同一段代码** ——
`search_related_rows()` 是 INVOKER,RLS 自己回答。**一张名单正是 Tim 否掉小改法的同一种东西。**

### W3 · Q9 = **YES,任务画成表** —— ★ 代价存档

**代价,逐字:任务是【唯一一种】共享页的画法与它自己那一页不是同一种画法的单据。**
一个从 `/tools/tasks`(看板)走过来的人,会在关联页上看见同一批任务的另一种样子。
☞ 这句话写进了 `app/components/related/RelatedTable.tsx` 的抬头,不是只写在这里 ——
**读到它的人是下一个改那张表的人,不是下一个读交回报告的人。**

---

## 4 · ★★ 破窗 —— **必填字段,写实情**

```
起点  2026-09-19 22:43:04 CST   (db/apply_migration.sh 自己打的,落盘在 db/migration-windows.tsv)
      2026-09-19 22:46:09 CST   -fu1,在同一个窗口【之内】,不新开一个
终点  ★ 等 Tim 在 Vercel 面板上读 —— 这台机器够不到 Vercel(AGENTS.md 的常设规矩)
时长  ★ 因此本刀【报不出】一个测出来的时长。它由 Tim 那一侧的读数补齐,
      而一份【转述】和一次【测量】在报告里长得很像 —— 所以这一行写成空的,不填一个上界。
```

### ★ 期间【什么是坏的】—— 逐条,而它**不是**「什么都不会坏」

委托书 §4 写的是「一个增量函数,什么都没改,A/C/D 族」。★ **Tim 的 W1 把第二件折了进来,
而那一件改了一个既有对象与 5 行既有数据。照实情写:**

| # | 迁移做的事 | 窗口里的影响 |
|--:|---|---|
| ① | 新建 `search_related_rows()` | **零。** 部署在跑的那一版代码里没有这个字符串,RPC 名对不上就不会被调用 |
| ② | `link_mode` 的 CHECK **放宽**(3 → 4 种) | **零。** 只放宽,不收紧 |
| ③ | ★ **5 行 `link_mode` 从 `list_q` 变成 `type_list`** | ★ **旧代码不认识这个值。** `hrefFor()` 是一个 switch,`default:` 那一支 `return row.route` ⇒ **窗口期间,搜到这 5 种单据点开,落在【未过滤的】`/inbound` · `/output` · `/sales/customers` 上** |
| ④ | 其余 35 种的 `link_mode` | **零,一个字没动** |
| ⑤ | `-fu1`:三个参数加 `DEFAULT NULL` | **零。** 旧代码一次都不调它 |

☞ ★ **而 ③ 的方向值得读两遍:它比今天【好】,不是比今天坏。**
今天那 5 种落在一张 `?q=` 过滤到**永远 0 行**的列表上;窗口里落在同一张列表的
**未过滤**版本 —— 至少屏幕上有东西。
**所以这一刀的窗口是:一处已经坏了一周的落点,换了一种坏法,然后在部署那一刻被修好。**

⚠ **窗口里【不得不】发生的事,与 SEARCH-4 逐字同一条:**
`lib/database.types.ts` 从**线上**生成,所以 `tsc` 与 `npm run build` **只能在迁移之后跑** ——
一支还不存在的 RPC,类型里没有它的名字。☞ 于是 build / 整门 / 探针 / 改后 drift 都落在窗口里。
**除了这一段,别的都在迁移前做完了**(29 条静态检查、文案、探针改好、`gate.py --offline` 绿、
改前 drift 读数)。

---

## 5 · 停止条件,逐条(§5)

| | 判据 | 读数 |
|---|---|---|
| **(a)** | 390px 上本来 0 溢出的路由升到 0 以上 | ★ **没有。** `ABC_OWN_EXIT=0` · 281 组路由×视口 · 183 张表 · 647 次字段比较 |
| **(b)** | 本来就在溢出的那几条长大 | ★ **没有 —— 而这一次是 5 of 5,见 §5.1** |
| **(c)** | 不横滚的表开始横滚 / 横滚范围变大 | ★ **没有** —— 新页面怎么算,见 §5.2 |
| **(d)** | S2 的封存产物未变 | ★ **一个字节都没动** —— `control-style.ts` · `input.tsx` · `textarea.tsx` · `globals.css` · `table-style.ts` **一个都不在 `git status` 里** |
| **(e)** | `/brand-sampler` 未变 | ★ **860 渲染 / 903 计数**,两个视口都是,与基线逐字相同。★ **量在 `next start` 上**(探针要求 `.next/BUILD_ID` 存在) |
| **(f)** | 顶栏自己的盒子 | ★ **五条逐字相同:** `1280x53` · `390x55` · nav 字段 `200x32` · 首页入口 `358x49.02`@390 与 `544x53.63`@1280 |
| ★ **(g)** | **下拉自己的高度** | ★★ **九格读数与 SEARCH-4 【逐字节相同】,见 §5.3 —— 这是证出来的,不是假设的** |

### 5.1 ★ (b):**这一次是 5 of 5**,而第五条是补量来的

`/finance/freight/new` 在**本刀自己的两趟全量 drift 里都 `failed`**(改前 failed · 改后 failed)
—— 与 SEARCH-4 两趟的遭遇逐字相同。比对器**正确地拒绝**把它算成"没变"
(「只有一侧量到、因此【不作数】的:1 组」)。

☞ **照在案的办法补量**(单独重跑 + 一条伴随路由,伴随路由的读数按规矩丢掉):

```
node scripts/survey-controls.mjs --mode=drift \
     --only=/finance/freight/new,/tools/pricing/calculator          NEWR_EXIT=0
→ phone /finance/freight/new  整页溢出 = 27px   (表:overflowsShell=true 338/326)
```

★ **27 == 委托书点名的那个 27。它没有长大。**

⚠ **照直说这条读数的限制:改后那一侧是本刀量的,改前那一侧是【委托书转述的 SEARCH-4 的数】,
不是本刀自己的一次测量** —— 本刀的改前全量趟在这条路由上也 failed。
☞ 支撑它的第二条证据是**结构性的**:`git status` 里 `app/finance/` 底下**一个文件都没有**,
而本刀唯一一个在每条路由上都渲染的改动是搜索下拉(默认关着,几何由 (g) 单独钉住)。
**两条合起来我判它 5 of 5;只凭其中任何一条我不会这么判。**

### 5.2 ★ (c):新页面**怎么算的**,以及它为什么既不冒充回归、也不藏一个回归

> **答:`--mode=drift` 按构造【走不到】它 —— 它只走 `staticRoutes`,
> 而 `staticRoutes = allRoutes.filter(r => !r.includes('['))`。两条新路由全是动态段。**

☞ 于是:
* **它不会让一条新路由看起来像回归** —— 它根本不进 (a)(b)(c) 的分母;
* **它也藏不住一个回归** —— 比对器按【两份读数都覆盖到的路由】逐条比,
  既有的 281 组一组都没少(与改前那一趟同为 281 / 183 / 647)。

★ **而"进不了分母"不等于"不用量"。** 两条新路由**单独量了一趟**(`--urls=`,
那正是它存在的口子):

| 路由 | desktop 整页溢出 | phone 整页溢出 | 表横滚 |
|---|--:|--:|---|
| `/documents/assay_result` | **0** | **0** | 否(960/960 · 326/326) |
| `/related/supplier/6fd51aec…/inbound_batch` | **0** | **0** | 否(960/960 · 326/326) |

### 5.3 ★★ (g):**证出来的,不是假设的**

委托书要求「分组行变成链接**不许**改下拉的高度,**证明它,而不是假设**」。
☞ 做法:链接是**行内的** —— `<li>` 的 class 一个字没动,`<a>` 不加 `block`、
不加内边距、不加行高,只多一条 `hover:underline`。
☞ 证据是 `probe-nav-geometry` 的九格,**与 SEARCH-4 §13.2 的九格逐字节相同**:

| 位置 | 空查询 | 「Acme」 | 「in」(今天最高) | bottom |
|---|--:|--:|--:|--:|
| 1280 顶栏 | 282 | 262 | **834** | 884 |
| 390 首页 | 358 | 332 | **497.94** | 884 |
| 1280 首页 | 282 | 262 | **452.02** | 884 |

★ 连 N18d 的三行「夹住了并且真的会滚」也逐字相同(内容 1446>832 · 1716>496 · 1348>450)。
**一个 flex 行内的 `<a>` 对这个盒子的贡献是 0px,而那是量出来的。**

---

## 6 · ★ 十二条细节建议:**十一条照做,一条departure**

| # | 建议 | 落地 |
|--:|---|---|
| Q1 | 三段路径,不用查询串 | ✓ 照做(并多出一条 `/documents/<key>`,理由见 §3 W1) |
| Q2 | 主语用 uuid | ✓ 照做 |
| Q3 | 兄弟函数,纯增量迁移 | ✓ 照做(★ 而"纯增量"因 W1 不再成立,见 §4) |
| Q4 | `PAGE_SIZE = 20`,keyset 按 `code` 降序 | ✓ 照做 |
| Q5 | 两列:单据号 + 标签;9 种没有 label 的只画一列 | ✓ 照做 |
| Q6 | 排序/筛选/导出一样都不给 | ✓ 照做 |
| Q9 | 任务画成表 | ✓ 照做(Tim 的 W3) |
| Q10 | 分组行**全部**可点,含计数为 1 的 | ✓ 照做 |
| Q11 | breadcrumb 回主语详情页,不放"回到搜索" | ✓ 照做(★ 只有 `link_mode='detail'` 的主语才画,见下) |
| Q12 | `EXCEPTIONS` 两条 | ✓ 照做(★ 两条,但不是"父 + 动态段" —— 见下) |
| Q13 | 4 键 × 2 语言 | ★ **departure:12 键 × 2 = 24 条**,见下 |
| Q14 | 探针加一格**点击**式 | ✓ 照做,而且加了三格(R8 / R8b / R8c) |
| Q15 | fixture 一支四臂 | ★ **六臂** —— 多了 B(分页)与 F(列授权),见 §2.3 ① |

### ★ 三处 departure,逐条说清

#### ① Q13:4 键 → **12 键**(× 2 语言 = 24 条)

**那个 4 是在 W1 折进来【之前】估的。** 实际需要:

```
titleOf · noEdge · noneNow · noneOfType · subjectUnreadable · subjectUnreadableHint
colCode · colLabel · showing · nextPage · firstPage · backToSubject
```

★ 多出来的来自两处,**两处都是裁定要求的**:
* **W1 的第二种形状**要它自己的空态(`noneOfType`:「现在一张化验单都没有」)——
  它与有主语那一句(`noneNow`)**不是同一句话**;
* **§4.6 的四种零**各要一句,而「主语读不到」是**整页拒绝**,要标题 + 提示两条。

★ **而模块闸那一层【一个新键都没加】** —— 它复用既有的
`common.moduleDenied` / `common.moduleDeniedHint` / `common.backHome`。

#### ② Q12:`EXCEPTIONS` 两条,而**不是**「父 + 动态段」

实测 `check-nav-routes.mjs` 的 `routesFrom()` **只把带 `page.tsx` / `route.ts` 的目录算成路由**。
`/related`、`/related/[subject]`、`/related/[subject]/[id]`、`/documents` 都没有 `page.tsx`,
**所以它们根本不是路由,不需要例外。**
☞ 两条例外是**两条叶子**:`/related/[subject]/[id]/[target]` 与 `/documents/[key]`。
★ **故障注入过**:抽掉 `/documents/[key]` 那一条 → `NAVROUTES_OWN_EXIT=1`,点名那条路由;放回 → 0。

#### ③ Q11 的 breadcrumb:**只有 22 种单据画得出来**

`documentHref()` 对 `link_mode='detail'` 之外的三种给出的是**一张列表**,
而一条写着「回到 NMC Cathode Foil」却落在**全部物料**上的链接,是一句它兑现不了的话。
☞ 所以非 `detail` 的主语**不画返回链接**。实测 40 个 key 里 **22 个是 detail**,
**这一格因此经常是空的 —— 而空着是对的,不是漏了。**

---

## 7 · 造了什么(逐件)

| 件 | 位置 |
|---|---|
| 迁移 ×2 | `db/migrations/2026-09-19-search5-related-rows.sql`(函数 + CHECK 放宽 + 5 行重指)· `…-fu1.sql`(三个参数 `DEFAULT NULL`) |
| 函数镜像 | `db/functions/search_related_rows.sql`(`pg_get_functiondef` 原样字节) |
| 表镜像 | `db/tables/document_types.sql`(CHECK + 5 行 + `COMMENT ON COLUMN link_mode`) |
| fixture | `db/fixtures/199-…-the-negative-control-proves-it.sql`(**六臂**) |
| 新路由 ×2 | `app/related/[subject]/[id]/[target]/page.tsx` · `app/documents/[key]/page.tsx` |
| 共享组件 ×2 | `app/components/related/related-records.tsx` · `RelatedTable.tsx` |
| ★ 搬出来的一份实现 | `lib/search/documentHref.ts` —— 它此前叫 `hrefFor`,藏在 `records.ts` 里,**只有一个调用点**;现在有三个 |
| 改既有文件 | `lib/search/types.ts`(`RelatedGroup.href`)· `lib/search/records.ts` · `app/components/search/SearchEntry.tsx` |
| 闸 | `check-nav-routes.mjs`(2 条例外)· `check-search-registry.mjs`(`type_list` 一臂 + 盲区写进抬头)· `smoke-routes.mjs`(两条新路由进 `SPECIAL_ID_ROUTES`) |
| 文案 | `messages/en.ts` / `zh.ts` 各 12 键 |
| 探针 | `probe-search-results.mjs` 加 R8 / R8b / R8c,下界 14 → **17** |
| 立案 | `docs/known-issues.md` 三条(§9) |

### ★ 一处「一句话可以在写下的那天为真、在某一刀之后为假」

`SearchEntry.tsx` 里 SEARCH-4 写着一整段**为什么这些行不是链接**。
**那句话在它写下的那天是对的** —— 当时没有「这个供应商的进料批」这条地址。
☞ 本刀造的正是那条地址,所以那段注释被**替换**,并写清楚是被哪一刀替换的
(与 SEARCH-2b 把 `recents` 加进 `types.ts` 时那段说明同形)。
★ **替换它的是这一刀,不是一次顺手清扫。**

### ★ 一处静默回落被改成响亮拒绝

旧的 `hrefFor` 是 `default: return row.route`。★ **而本刀的破窗恰好把那条回落用上了**
(见 §4 ③)。新的 `documentHref()` 对认不出的 `link_mode` **RAISE**:
一个静默回落会让下一个加第五种 link_mode 的人**在屏幕上看不到任何东西**。

---

## 8 · fixture 199 —— **六臂,而两次故障注入证明它会咬人**

| 臂 | 断言 |
|---|---|
| A | 同一会话里 `count(search_related_rows) == search_related().n == total`(**4**;三条边,其中两条是桥,**一条桥故意指向已被 `in` 边数过的那张任务** ⇒ 顺带钉住 DISTINCT) |
| B | keyset 翻两页 **3 + 1**,不重不漏,`total` 两页都是 4 |
| ★ C | **反面对照**:换一个**没有 `module.tasks.view`** 的会话 ⇒ **两个数一起变 0** |
| D | 主语读不到(有 tasks.view、没有 hr.view)⇒ **函数一行都不返回**(而它**看得见那些任务** —— 前提单独断言过) |
| E | 拼错的 `target_key` ⇒ `SEARCH_UNKNOWN_DOCUMENT_TYPE`;**半个主语** ⇒ `SEARCH_RELATED_HALF_SUBJECT`。都是 RAISE,不是空集 |
| ★ F | 40 个种类的 `code` 与 `label_column` 对 `authenticated` **真的读得到**(见 §2.3 ①) |

**另有两条前提断言**:`authenticated` 有 `tasks`/`task_history` 的表级 SELECT(否则每一条 "0 行"
都会因为错的理由通过);两支函数**都不是 `SECURITY DEFINER`**(任一支借了身份,整支 fixture 作废)。

### ★★ 两次故障注入 —— **一条从没红过的断言,和一条不存在的断言,退出码相同**

| 注入 | 结果 |
|---|---|
| ① 抽掉 C 臂的 `SET LOCAL ROLE authenticated`(fixture 26 那一课的形状) | ★ **当场红**:`FIXTURE 199C 失败:一个【没有 module.tasks.view】的会话数出 4 条任务` |
| ② 抽掉取行函数里的 `DISTINCT ON` | ★ **当场红**:`FIXTURE 199A 失败:计数 4 ≠ 行数 8` |

☞ ① 证明**角色切换是承重的**(不切,两个数按构造相等);
② 证明 **A 臂真的在比两支函数**,不是在比一个数和它自己。

⚠ **两次注入都跑在线上的回滚事务里**,而 fixture 本身**在重建的空库上也绿**
(`gate --offline` 那一趟,202 支 fixture 全过)—— 它自带数据。

---

## 9 · ★ 只立案、不修的三件(§7)

全部写进 `docs/known-issues.md`,各带量法:

1. **`SEARCH5-CONTAINER-CODE-IS-AN-ERROR-BLOB`** —— `containers` 有一行把一段
   42501 报错 JSON 存成了单据号(`id = f21b293a-bc5c-46de-9b54-3f1a8a4e1329`)。
   ★ **不清扫**:一次清扫要依据**归属**与**年龄**两件它无法安全知道的事。
   ⚠ 它会作为一条单据进搜索结果,SEARCH-5 之后还多两个落点(`/documents/container` 等)。
2. **`SEARCH5-EXPENSE-CLAIM-ROUTE`** —— `expense_claim` 登记在 `/hr/claims`,
   而那一页列的是**医疗申报**;报销单的列表在 `/finance/claims`。
   ★ **不修**:改登记是它自己的一次裁定(三条路各有代价,都要有人拍板)。
   ⚠ 它是 `check-search-registry` 判据 ① **按构造看不见**的一类:那一页**在**。
3. ★★ **`SEARCH5-LIST-Q-DOES-NOT-CHECK-THE-TABLE`** —— 判据 ② 问「读不读 q」,
   **不问「列的是不是这张表」**。这正是那 5 种单据带着一个永远 0 行的落点绿了一周的原因。
   ★ **本刀把那 5 种改成 `type_list`,所以今天这个盲区没有受害者 —— 但判据没有变窄。**
   ☞ **为什么没顺手补上:量过两种可机读的代理,两种都不准** ——
   「路由目录里提没提这张表名」对 `collection_chase` **假阴性**
   (`app/sales/customers/contactActions.ts` 提了 `collection_chases`,而那张列表并不列它;
   实测 assay 0 · cod 0 · trc 0 · stmt 0 · **chase 1**),反过来写成必要条件就变**假阳性**。
   **一道在它存在的理由上会判错的闸,比没有闸更坏。**

---

## 10 · 验证 —— **每一行都是【脚本自己】打出来的那一行**

| | 判词 |
|---|---|
| `npx tsc --noEmit` | **0 errors**(迁移+类型重生成之后) |
| `npm run build`(29 条静态检查 + `next build`) | **`BUILD_OWN_EXIT=0`** · `BUILD_ID = YxNM2EUKIPmhzUhi0F860` · 两条新路由都在产物里 |
| `node scripts/check-lint.mjs` | `LINT_OWN_EXIT=0`(基线 error 41 · warning 86,**没有新增**) |
| `node scripts/check-i18n.mjs` | `I18N_OWN_EXIT=0` |
| `node scripts/check-nav-routes.mjs` | `NAVROUTES_OWN_EXIT=0` —— ★ **故意红过一次**(§6 ②) |
| `node scripts/check-search-registry.mjs` | `SEARCHREG_OWN_EXIT=0` · 两条路各读到 **40/40** · `detail 22 · list 9 · list_q 4 · type_list 5` —— ★ **故意红过一次**(5 条全部点名) |
| `node scripts/check-document-registry.mjs` | `REGISTRY_OWN_EXIT=0` |
| `python3 db/gate.py --offline` | **`GATEOFF_EXIT=0`**(46s)—— ★ fixture 199 在**重建的空库**上绿 |
| 备份 | **`BACKUP_EXIT=0`** · TOC **5842** 条(上一份 5708,下限 5137)· 4.3M · 约 14 分钟 |
| `db/apply_migration.sh`(主) | `✓ committed atomically` · 预检 **`0 替换 · 1 新建`** · 破窗起点 **2026-09-19T22:43:04+0800** |
| `db/apply_migration.sh`(fu1) | `✓ committed atomically` · 预检 **`1 替换 · 0 新建`** · 22:46:09 |
| `python3 db/gate.py` 整门 | **`GATE_EXIT=0`**(593s) |
| ┗ 四个判词 | 可重建性 ✓ · 镜像 vs 线上 ✓ · 行为断言 ✓(**202 支 fixture**)· 匿名面 ✓(线上 anon 够得着的函数**只有** `cod_verification`) |
| `scripts/probe-search-results.mjs` | **`PROBESEARCH_EXIT=0`** —— **18 格,0 红** · `BUILD_ID=YxNM2EUKIPmhzUhi0F860` |
| `scripts/probe-nav-geometry.mjs` | **`PROBENAV_EXIT=0`** —— **27 格,0 红** |
| `scripts/probe-brand-sampler.mjs` | **`PROBEBRAND_EXIT=0`** · 860/903,两个视口 |
| `scripts/smoke-routes.mjs` | **`SMOKE_EXIT=0`** —— **250 ok · 6 skipped · 0 FAILED** · 计时 **225** 条(SEARCH-4 是 223 ⇒ **正好多了本刀那两条**)· 合计 704.1s · 中位数 2961ms |
| `survey-controls --mode=drift` 改前 | **`DRIFT_EXIT=0`**(3,277,668 B · 141 路由 × 2 视口 · 11 条覆盖断言) |
| `survey-controls --mode=drift` 改后 | **`DRIFT_EXIT=0`**(3,277,730 B · 同上) |
| `survey-controls --mode=drift`(新路由 + freight 补量) | **`NEWR_EXIT=0`** |
| `scripts/check-stop-rules-abc.mjs` | **`ABC_OWN_EXIT=0`** |

### 10.1 ★ R8 那三格 —— **它点了,而且它证明了自己点的是软导航**

```
✓ R8.grouped-line-is-a-link-and-lands-on-its-rows
  点「SUP-2026-0002 的进料批」→ /related/supplier/6fd51aec-…/inbound_batch
  · 画出 11 行 · 自报 total=11 · 现读期望 11 · 首行 IN-2026-0322
✓ R8b.it-was-a-soft-navigation-not-a-reload
  window 上的记号:stamped
✓ R8c.the-dropdown-closed-behind-the-click
  落地之后下拉还开着:false
```

★ **R8b 是这三格里最要紧的那一个,而它是 CONFIRM-1 那一课的直接产物:**
`<SearchShell>` 住在**根布局**里,App Router 的软导航**不重画根布局** ——
于是一次 `page.goto` 的读数**对每一个真实会话都不作数**。
☞ 所以:等水合收尾(`__reactFiber$`)→ 在 `window` 上盖记号 → **点** → 断言记号还在。
**没有那个记号,一次悄悄退化成硬导航的点击会让这一格假绿 —— 那正是本格要抓的缺陷,
穿着本格自己的衣服回来。**

★ **期望值 11 是探针在跑的时候从 REST 现读的**(service role + 逐表计数),
与屏幕那一侧(admin 会话 + 函数)**不共用代码** —— SEARCH-3 的 R3 教训。

### 10.2 ★ 冒烟的预检**当场拦了一次**,而它拦得对

新路由第一次进冒烟时,`preflightIdSources()` **在起 dev server 之前 3 毫秒内**点名:
`段 [target] 【不在】 ID_SOURCES 里`。
☞ 两条新路由的段放的是 `document_types.key`(文本),**不是任何一行的 id** ——
`ID_SOURCES` 一律 `select=id`,结构上走不了。它们因此进了 `SPECIAL_ID_ROUTES`。
★ **而取值【必须落在一个非空的页面上】**:这两页对一个没有关联的三元组**照样 200**
(那是它们具名的空态),取错一组就是一次假绿 —— 与 `/finance/ledger/[account]` 那条
「取到一个没有分录的科目」逐字同族。
☞ 所以主循环**现读**:拿 `search_related()` 自己去问(它只返回 n>0 的分组),
第一个回得出分组的主语就是一个**保证非空**的三元组;取不到就**抛**,不算跳过。

### 10.3 ⚠ 一件没有量、而且不打算量的事 —— **第五次**

**一次关联查询要多久:没有量,也不打算量。** 325 行,规划器一律 Seq Scan。
**前四刀都拒绝过,而它们是对的。** keyset 与索引的理由是**形状**,不是一个读数。

---

## 11 · 价钱(§6)—— **两个数,永远**

| | |
|---|--:|
| **过程底价(本刀实测,脚本自报的墙钟合计)** | 改前 drift **1479s** · 改后 drift **≈1480s** · 备份 **≈840s** · 整门 **593s** · 冒烟 **704s** · `--offline` **46s** · 探针三支 **≈420s** · build ×3 **≈150s** · 新路由补量 **≈240s** ⇒ ★ **合计约 5950s ≈ 99 分钟**,**纯脚本时间,不含任何思考与写作** |
| **交出去的件数** | 迁移 2 · 函数镜像 1 · 表镜像 1 · fixture 1(6 臂)· 路由 2 · 组件 2 · 抽出的实现 1 · 改既有文件 3 · 闸 3 · 文案 24 条 · 探针 3 格 · 立案 3 条 |

★ **两个数不可比,并排放,不合并** —— 与停止闸对 SEARCH-1 那个 88 分钟的处置逐字同一条。

---

## 12 · 这一刀**没有**做的事

* ★ **没有碰 S2 的五个封存产物**,一个字节都没有。
* ★ **没有给共享页加排序 / 筛选 / 导出**(Q6 的裁定)—— 而失去的东西照直报:
  `/inbound` 有 8 个筛子 + 两种排序 + 分页 + 导出,`/output` 有 7 + 两种 + 分页 + 导出,
  **而它们恰好是关联最密的两张表**。从关联页跳过去的人拿到的是一张没有这些的表。
  **这是 Tim 接受过的代价,不是一次遗漏。**
* ★ **没有修那 3 件立案的事**(§9),也没有清扫那一行报错 JSON。
* ★ **没有去查 Vercel** —— 这台机器够不到它(AGENTS.md 的常设规矩)。
* ★ **没有报任何一个毫秒数的关联查询时延。**

---

## 13 · 等什么

**等 Tim 确认部署。** 破窗那一行的**终点**由他在 Vercel 面板上读 ——
本刀报不出一个测出来的时长,而**一个上界不是一次测量**。
