# CONSEQ-2 —— 交回报告(round 2)

**PART 2 与 PART 3,两部分都做完了。** 桶 B 的 21 处逐处验证,**15 处写了句子,6 处留白**;
留白的每一处连同理由逐条列在 §5.2,**可审计,不是默认**。

---

## 1. HEAD、以及开工时的树

| | |
|---|---|
| 开工前 HEAD | `df643736a24530053390c31b3eb4d503fd9a9cf0` |
| 开工前 `origin/main` | `df643736a24530053390c31b3eb4d503fd9a9cf0` —— **相等** |
| 树 | `nothing to commit, working tree clean` |
| 收工后 HEAD | 见 §11.3 |

★ **委托书写的期望 HEAD 是 `0733214`,实测不是它。** 按委托书自己的话
(「那个数字,和本块里每一个数字一样,是一条待测量的断言,不是前提」)照实报:

* `df64373` 是 `0733214` 的**直接后继**(`git merge-base --is-ancestor` 成立),
  两者之间只有一条提交:`df64373 NARROW-COVERAGE-1 交回报告 §12.3:补齐推送与部署的实测记录`。
* 它**只动了一个文件**:`docs/handbacks/NARROW-COVERAGE-1-round2.md`(+33 −1)。
  也就是 PART 1 自己那份交回报告的补记,**没有碰任何代码**。
* 停机判据是「树脏 **或** `HEAD != origin/main`」,两条都不成立,所以**没有停**。
  照实报出来,不当成"期望数字过期了"就忽略。

---

## 2. PART 2 —— 在【选择点】上量

### 2.1 ★★ 选择器到底是从哪里喂的 —— 一整个总体,而上一支量具结构上看不见它

**答案:三张【查名视图】,不是三张基表。**

| 表 | 喂选择器的那张视图 | 视图定义 | `.from()` 站点数 |
|---|---|---|---|
| `materials` | **`material_lookup`** | `db/views/material_lookup.sql` | **20** |
| `suppliers` | **`supplier_lookup`** | `db/views/supplier_lookup.sql` | **26** |
| `customers` | **`customer_lookup`** | `db/views/customer_lookup.sql` | **14** |

☞ **这 60 处站点,`delcount.mjs`(队列指定的那支量法)一处都看不见** ——
它只认 `.from('materials')` / `.from('suppliers')` / `.from('customers')` 三个字面量。
于是队列里那张「15 / 19 / 16」的表量的是 50 个站点,而**选择器全部住在另外 60 个里**。
这不是那支量具数错了,是**它的射程里根本没有这件事** —— 「名字对,覆盖窄」的又一例,
而且又一次出在交给下一刀的那个数上(与 NARROW-COVERAGE-1 更正 CONSEQ-1 时是同一个形状)。

**为什么是查名视图:** FIX-1 item 3 / FIX-2a / FIX-2b 那几刀把选择器从基表改成了查名视图,
理由写在视图抬头上 —— 基表的 RLS 是 `module.<自己>.view`,而收货 / 采购 / 产出那些页面的门
是别的模块码,于是一个只有采购权限的人读基表**拿到零行**,下拉整张是空的,
读起来是「这套系统里还没有登记物料」。视图的体内谓词把那句假话去掉了。

★★ **三张查名视图【自己都不过滤 `deleted_at`】,而且三张都把 `deleted_at` 摆在列上。**
也就是说过滤这件事**整个压在调用点身上** —— 这正是本节要逐处量的东西。

### 2.2 量法(instrument)、以及它的瞄准线

脚本:`pickerscan.mjs`(**留在 /tmp 那一侧,没有进仓库** —— 理由见 §9.1)。
**全文附在 §12,连同量法一起可以抄走**(队列 R-Q5:下一个人抄这个数时连量法一起抄)。

**瞄准线,逐字:**

```
【瞄准 · AIM】
  我读的是      :`app/` 与 `lib/` 下每一处 `.from('<六个标识符之一>')` 的
                  **完整调用链文本**(注释已抹成等长空格,字符串内容保留),
                  外加每一处 `.select('…')` 字面量里的**内嵌关系读**。
                  六个标识符 = 三张基表 + 三张查名视图。
  我声称管的是   :**这份枚举是完整的**,而且每一处都被分到
                  写入点 / 计数 / 按 id 取 / 列表取 这四格里的一格,
                  列表取的那一格还标出了它**链上有没有** `.is('deleted_at', null)`。
  两者不同之处   :★★ **我证不了「这条列表喂的是一个下拉」。**
                  我读的是查询,不是屏幕。
                  ☞ 【选择点这一半是人读出来的,不是这支脚本算出来的】——
                    本支只负责「一处都没漏」,`是不是选择点` 由人逐个文件读定。
                    把这两件事混成一个数,正是 CONSEQ-1 实例 5 那个形状。
```

★ **写下这三行当场就现形了一件事**:这支量具**没有资格**回答委托书那个问题的后一半。
所以本刀把它拆成两半 —— 机器管【枚举完整】,人管【是不是选择点】,
两半各自的结论分开写在 §2.5 与 §2.6。**没有把它们并成一个数。**

**关键的三个零件(定长窗口那一族缺陷的解药):**
1. **逐字符定性** `code / comment / string`。不用正则剥注释 —— 本仓库的注释里全是中文逗号
   与括号,而链的终点判据正是「深度 0 上的逗号」,注释里一个 `)` 就会让链**提前收尾而不吭声**。
2. **链的终点**靠三条判据:深度 < 0(撞上外层收括号)· 深度 0 上的 `,` `;` ·
   深度 0 上的换行且下一个 code 字符不是 `.`(本仓库不写分号)。
   **不用定长窗口** —— `delcount.mjs` 用的是 400 字符,而本仓库的链动辄跨几十行注释。
3. **过滤器可能不在链上**:列表页把链存进变量再交给 `applyXFilters(baseQuery, …)`。
   所以取出**赋值目标**再看它是不是被喂进那支 helper,而不是用 ±700 字符的窗口去猜。

### 2.3 覆盖断言 —— 四条里用了三条,第四条为什么用不上

| | 断言 | 本支怎么用的 |
|---|---|---|
| ① | `assertPopulation` | **六个标识符逐个断言非空**,不是只断言合计。合计非空掩盖得住一张表整个掉出射程 |
| ② | `assertPinned` | **发现步骤**:链解析数出的站点数 ↔ 原文字面量粗计数(两条路不共用任何零件)。**分格步骤**:四格之和 ↔ 站点总数。**链完整性**:疑似被提前截断的链条数 ↔ 0 |
| ③ | `assertAllowlistLive` | 12 → **15** 条【已知必然命中】的分格探针(每一条都是人读过源码之后写下的事实) |
| ④ | `assertAssertionsRan` | ★ **用不上,理由写在脚本里**:那一条治的是「单元测试形状」的脚本,失效方式是 early return 让某几条断言根本没跑到而 `failures` 仍是 0。本支不是那个形状 —— 它是一次普查,失效方式是【总体空掉】与【分格丢样本】,而那两样由 ① ② 守着。硬套只会得到一个恒真的数 |

**★ 本刀新加的第四条断言(不在 selfproof 里,是这一支自己的):**
**走完一个文件之后,词法状态必须回到 `code`。** 卡在字符串里 = 奇偶性反了。
它是被下面 §2.4 那次真实失败逼出来的。

**实测读数(全绿):** 走到文件 **922** 个 · `.from()` 站点合计 **110**(独立粗计数 **110**,相等)。

### 2.4 ★★ 本刀自己踩到的一次「量具坏了」,照直记 —— 而且**没有一条覆盖断言抓到它**

第一版跑出来的答案是「**5 处列表取未过滤 `deleted_at`**」,其中两处是
`app/inbound/export/route.ts:102,103`。**而那两行源码上明明白白写着 `.is('deleted_at', null)`。**

**病因:第一版的词法器不认【正则字面量】。**
`app/inbound/export/route.ts:54` 有一句
`return '"' + String(value).replace(/"/g, '""') + '"'` ——
`/"/g` 是一个**装着引号的正则**,于是那个 `"` 被当成开引号,
**从那一行起整个文件的字符串奇偶性都反了**。链在 `.select('id` 处提前收尾
(它把 `'id, name'` 里的逗号当成了 code 上的逗号),于是链上那个 `.is()` 我看不见。

★★ **而当时上面每一条覆盖断言都是绿的:**
两条路都数出 110 个站点(**发现步骤没瞎**),四格之和等于总数(**分格没丢样本**),
「疑似截断」那条也没响(截断后的链有 34 字符,不算短)。
这正是 `selfproof.mjs` 抬头写着它**治不了**的那一类:
**它们证的是【灵敏度】,不是【瞄准】。**

**抓住它的是人** —— 把输出和源码并排读了一遍,发现两者对不上。
☞ 于是补了一条**真的治得了这一族**的断言(「走完文件状态必须回到 code」),
并且**用一次致盲证明它咬得住**(下表 B5)。

**而那条新断言第一次跑就抓出了第二处** ——
`app/settings/import/ImportForm.tsx:191`:一个 `className` **合法地跨了四行**。
那是**我的规则错了,不是文件错了**(JSX 属性值真的跨行),
于是把「非模板串不跨行」那条规则**拿掉**,靠走完文件的平衡断言接住真正没闭合的串。
**一条会天天假红的闸三刀之内会被关掉(AGENTS.md 明写),所以这里选择放宽规则而不是加豁免。**

☞ **修好之后答案整个反过来了:未过滤的列表取从 5 处变成 0 处。**
**第一版那个「5」完全是词法器的产物,不是树的事实。**

### 2.5 致盲注入台账 —— **每一格的退出码都是脚本自己的**

判据:精确字符串替换(`blind2.py`,**不经过任何 shell 引用** —— 见 §9.2),
跑完逐字节还原并校验,**命中 0 处即报 NOOP**。

| # | 致盲的是什么 | 自身退出码 | 说明 |
|---|---|---|---|
| B1-第一次 | 发现正则(经 `/tmp/blind.mjs` + shell) | **NOOP** | ★ zsh 把 find 串里的引号吃掉了,**命中 0 处 —— 什么都没删掉,因此什么都没证明**。按名记下并替换,**不当成通过** |
| B1 | 发现正则 `String.raw\`\.from\(` → `\.fromZZZ\(` | **2** | 六个标识符全部掉到 0,`assertPopulation` 当场红 |
| B2 | 文件走查根 `['app','lib']` → 一个叶子目录 | **2** | 空总体 |
| B3 | `deleted_at` 判据 → `deleted_atZZZ` | **2** | 带 `filtered:true` 的探针全部命不中,`assertAllowlistLive` 咬住 |
| B4 | `chainEnd` 整支打桩成 `return start` | **2** | 「疑似截断」那条 |
| **B5** | ★★ **把【正则字面量】那一支拆掉**(即 §2.4 那个真缺陷) | **2** | **这一格证明新加的平衡断言真的治得了它** |
| B6-第一次 | 拆掉 helper 感知(`\|\| s.helperTakesIt`) | **1** | ★ **没到 2。** 它把三处 helper 过滤的站点报成「未过滤」—— **把一次【自己瞎掉】说成了【代码有问题】**。断言下得太早 |
| **B6** | 同一处,**补了三条 helper 探针之后** | **2** | 与 NARROW-COVERAGE-1 §2.4 #25–28 同一个动作:把断言下移到真会塌的那一格 |
| B7 | 内嵌关系读判据 | **2** | 空总体 |
| B8 | 按 id 取 判据 | **2** | 样本挪格,探针咬住 |
| B9 | 写入点判据 | **2** | 同上 |
| B10 | 把独立粗计数改成抄判据那条路(双向钉住变成同义反复) | **2** | `assertPinned` |

**★ NOOP / 没到 2 的格子,一格都没有当成通过:** B1-第一次(NOOP,已替换)· B6-第一次(exit 1,已补探针重跑)。

**★ 对照格 —— 给【上一代量具 `delcount.mjs`】同样的致盲:**

| # | 同一处致盲 | 原版自身退出码 | 它印了什么 |
|---|---|---|---|
| C1 | `deleted_at` 判据弄瞎 | **0** | 照常印出三张表的分格数 |
| C2 | 拆掉 helper 感知 | **0** | 同上 |
| **C3** | **窗口 400 → 40**(定长窗口那一族缺陷本身) | **0** | ★★ 「链上直接过滤」**8 / 10 / 8 → 0 / 0 / 0**,「真的不过滤」**1 / 2 / 2 → 9 / 12 / 10**,**而它照样 exit 0**。读的人会得出「树里有 31 处不过滤的读」,而真值是 5 |

☞ C1/C2 第一次跑回来是 **exit 1**,查下去是**跑错了工作目录**(脚本用相对路径 `app`/`lib`),
不是判词。**那是一次崩溃,不是一次判定** —— 修好 `cwd` 之后才是上表那三个 0。照实记。

### 2.6 分格实测(全部 110 处)

| 标识符 | 合计 | 写入点 | 计数 | 按 id 取 | 列表取 | 其中未过滤 |
|---|---|---|---|---|---|---|
| `materials` | 15 | 3 | 1 | 2 | 9 | **0** |
| `material_lookup` | 20 | 0 | 0 | 6 | 14 | **0** |
| `suppliers` | 19 | 4 | 2 | 3 | 10 | **0** |
| `supplier_lookup` | 26 | 0 | 0 | 10 | 16 | **0** |
| `customers` | 16 | 3 | 1 | 4 | 8 | **0** |
| `customer_lookup` | 14 | 0 | 0 | 6 | 8 | **0** |
| **合计** | **110** | 10 | 4 | 31 | **65** | **0** |

★ 三张基表那一半(15 / 19 / 16 与写入点 3 / 4 / 3)**与队列里的旧数逐个对上** ——
`delcount.mjs` 今天重跑,输出与队列所记逐字相同,那 5 处「真的不过滤」也照旧是
`purchasing/orders/[id]/page.tsx:258` · `logistics/forwarders/[id]/page.tsx:47` ·
`logistics/forwarders/page.tsx:55` · `finance/credit-notes/page.tsx:114` ·
`finance/statements/[id]/pdf/route.ts:53`。
**本支把这 5 处分进【按 id 取】那一格** —— 它们全是拿着一个已有父记录去取它指着的那一行,
与队列的结论一致,只是这一次那个分类是**判据分出来的,不是人事后解释的**。

**内嵌关系读(`.from()` 计数一处都看不见的那一群):`materials` 19 · `suppliers` 5 · `customers` 7,共 31 处。**

★ **与队列里那个「materials 21 · customers 9 · suppliers 4」对不上,而我复现不了旧数。**
队列写的量法是 `/tmp/delcount.mjs`,**但那支脚本根本不数内嵌读** ——
也就是说那三个数是另一次**没有留下量法**的测量。
按队列自己立的规矩(R-Q5:记出处,不只记结果),**这一条没有被满足**,登记在 §8 ④。
本刀这三个数的量法写在 §12,可复算。

**逐处读过,31 处内嵌读【没有一处是选择点】** —— 全部是详情页 / PDF 路由 / 标签路由 /
列表页拿着父行去印它已经选好的那个料/供应商/客户的名字。两处长得像例外的也查过了:
* `app/finance/invoices/new/page.tsx:48` —— 内嵌在 `sales_records_masked` 的
  `output_batches(code, unit, materials(name))` 里,是**已存在的销售记录**的料名;
  这一页的客户选择器是另一句直连 `.from('customers')…is('deleted_at', null)`。
* `app/operation/processing/new/page.tsx:25,32` —— `materials ( name )` 是给
  **投料批次**下拉当标签用的;被选中的是批次,不是料。料的选择器是另一句直连,过滤了。

### 2.7 还有没有别的喂料路径?(这一问不能靠假设)

| 可能的路径 | 实测 |
|---|---|
| 客户端组件自己查 | `use client` 且引用 supabase 的文件共 **9 个**,逐个读过:附件面板 ×4 · `NodeTree` · `SearchShell` · `RememberGreeting` · `IdleWatcher` · `materials/new/page.tsx`。**没有一个查这三张表**(`NodeTree` 那一处命中在注释里,讲的是 `task_nodes`) |
| 内部 API / route handler | `app/` 下 **30 支** `route.ts`,**全部是 export / pdf / label / avatar / import-template**。没有一支喂下拉 |
| 客户端 `fetch('/api/…')` | **0 处** |
| 服务端 action 返回列表 | 有:`app/sales/orders/actions.ts:208,211`(客户 + 物料)。**两句都过滤了** |

---

## 3. PART 2 的答案 —— 逐表

> **问题:一行软删的料 / 供应商 / 客户,今天还能不能在一张【新】单据上被【选中】?**

| 表 | 答案 | 证据 |
|---|---|---|
| `materials` | **不能** | ①(UI)喂新单据选择器的 **9 处**列表取(`materials` 9 + `material_lookup` 14,其中新单据那一批见下)**每一处都有 `.is('deleted_at', null)`**;②(DB)`create_purchase_order.sql:148` 与 `create_sales_order.sql:52` 各有一条**按名拒**:`MATERIAL_NOT_FOUND` / `SO_CREATE_LINE_INVALID\|%\|material`,谓词都是 `WHERE id = … AND deleted_at IS NULL` |
| `suppliers` | **不能** | ① 同上,**列表取 26 处(10 + 16)全部过滤**;② `create_purchase_order.sql:59` **按名拒** `SUPPLIER_NOT_FOUND`,谓词 `WHERE id = p_supplier_id AND deleted_at IS NULL` |
| `customers` | **不能** | ① 同上,**列表取 16 处(8 + 8)全部过滤**;② `create_sales_order.sql:23` **按名拒** `SO_CREATE_CUSTOMER_INVALID`,谓词同形 |

★ **两层证据是分开的,不要合并读:**
第一层是**屏幕上不出现**(65 处列表取,0 处未过滤);
第二层是**服务端按名拒**(三支创建 RPC 上的具名异常)。
第一层拦手滑,第二层拦直连 —— 这与 `purchasing/orders/new/page.tsx:69` 抬头那段
「它拦得住手滑,拦不住决心」是**同一种区分**,只是这一次两层都在。

★★ **但第二层【不是全覆盖】,照实说清楚:**
本刀查到**具名拒绝**的只有 `create_purchase_order` / `create_sales_order` /
`create_work_order` / `amend_work_order` / `create_order_invoice` / `record_expense` /
`record_payment` / `set_material_required_metals` 这几支。
**不走 RPC 而直接 INSERT 的那些写入路径,数据库上没有对应的具名拒绝** ——
外键只保证「这一行存在」,不保证「这一行没被软删」。
所以准确的话是:**今天没有任何一个屏幕会把软删的行摆出来给人选**,
而**「数据库一定会拒」只在上面那几支 RPC 覆盖到的单据上成立**。
☞ 本刀写进对话框的那句话(§6)因此只说前者,**没有说「系统会拒绝」** ——
那正是 CONSEQ-1 §3 拒绝写「关单之后系统会拒绝收货」的同一条线。

**附带产物,不丢掉:**§2.6 那张读点表,以及三张查名视图**自己不过滤 `deleted_at`**
这一条(`db/views/{material,supplier,customer}_lookup.sql` 的 `SELECT` 里 `deleted_at`
是**一列**,`WHERE` 里只有权限谓词)—— 过滤整个压在调用点上,今天 65/65 都做到了,
**而没有任何机制保证第 66 个调用点也会做到**。登记在 §8 ①。

---

## 4. 桶 B 的二十一处 —— 逐处的验证结果与出处

判据是 R-Q3:**先读动作自己的服务端调用与它背后的数据库闸(路线 c);
c 说不出话才退回去读调用点(路线 a);两条都得不出一句验证过的话,就一个字都不写。**

**15 处验证得出 · 6 处没有。** 最后一列就是出处。

| # | 站点 | 动作走到哪 | 验证到的后果 | 出处 |
|---|---|---|---|---|
| 1 | `FinanceAttachmentsPanel:226` | `deleteFinanceAttachment` → `finance_attachments` 软删 | ✗ **没有** | 见 §5.2 ①(查到一条闸,但**它不管这个面板**) |
| 2 | `MetalContentPanel:170` | `deleteAction` → `inbound_batch_metals` / `output_batch_metals` **硬删** | 这种金属不再计入本批计价;**删掉最后一种之后按合约条款算价会按名拒** | **c** ×2(**这个面板进料/产出两张页面共用,所以两边都查过**)— 进料侧:`db/functions/committed_terms_price.sql:34-39` `IF v_metals IS NULL THEN RAISE EXCEPTION 'NO_METALS'`;产出侧:`db/functions/price_output_sale.sql:48-53` `IF v_metals = '[]'::jsonb THEN RAISE EXCEPTION 'NO_METAL_CONTENT|%'`。两边随后都把这份清单喂给 `calculate_metal_price_from_terms` —— **句子在两张屏幕上都成立** |
| 3 | `DeleteStatementButton:24` | `deleteStatement` → `bank_statements` 软删 + `redirect` | **已对账的删不掉,要先重新打开**;删成之后被送回对账单列表 | **c** — `db/tables/bank_statements.sql:41,47`:`trg_bank_statements_no_delete_reconciled` 抛 `STATEMENT_RECONCILED`;`redirect('/finance/bank/statements')` 在 `actions.ts` 成功那一支 |
| 4 | `DeleteDepartmentButton:20` | `deleteDepartment` | **还有人在的部门删不掉**(并点出人数) | **c**(动作层的闸)— `app/hr/departments/actions.ts:58-73`:先 `count` `employees` 且 `deleted_at IS NULL`,`headcount > 0` 即 `hr.deptHasEmployees`;★ 且 `countRes.error` 时**挡住而不是放行** |
| 5 | `HolidaysTable:69` | `deleteHoliday` → `public_holidays` **硬删** | 这一天重新算作工作日:**跨过它的休假多扣一天**,**汇率取数也不再跳过它** | **c** — `db/functions/is_business_day.sql`(读 `public_holidays … AND h.is_active`),被 `calculate_leave_days.sql` 与 `fx_rate_asof.sql` 调用 |
| 6 | `GoalsEditor:279` | `removeGoal` → RPC `remove_review_goal` | **已经针对这条目标写下的内容一并消失;自评一开始就不能再删** | **c** — `db/functions/remove_review_goal.sql`:`PERFORM require_reviewer_of(v_g.review_id, ARRAY['draft'])`,函数抬头写明理由「自评开始之后删题,会把被评估人已经写下的回答一起抹掉」 |
| 7 | `DeleteTrainingButton:19` | `deleteTraining` → `training_records` 软删 | **它的续期提醒不再出现** | **a**(视图,硬证据)— `db/views/hr_alerts.sql:212-214`:培训到期那一支 `FROM training_records t … WHERE t.deleted_at IS NULL AND … (expiry_date - CURRENT_DATE) <= 90` |
| 8 | `materials/DeleteButton:22` | `softDeleteMaterial` → `materials` 软删 | **新单据上不再出现在可选项里;已经用到它的单据照常显示名字** | **a + c** — a:§2 那 23 处物料列表取全部过滤;c:`create_purchase_order.sql:148` `MATERIAL_NOT_FOUND` / `create_sales_order.sql:52` `SO_CREATE_LINE_INVALID`。后半句由 §2.6 那 5 处按 id 取撑着 |
| 9 | `materials/[id]/edit/AttachmentsPanel:196` | `material_attachments` 软删 | ✗ **没有** | 见 §5.2 ② |
| 10 | `CostPanel:100` | `softDeleteCostEntry` → `processing_cost_entries` 软删 | **按今天补一张冲销分录、原分录留账上**;**已汇出/已核销的删不掉**;**已分摊过的会被标成过期,要重跑** | **c** ×3 — ① `db/functions/finance_journal_triggers.sql` 的 `fin_journal_cost_entry()`:`IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN PERFORM post_journal_entry(CURRENT_DATE, 'Cost removed …', …, true)`;② `guard_cost_entry_settled()` 抛 `COST_ENTRY_SETTLED`;③ `db/views/processing_run_allocation_status.sql:59` `is_stale = allocated_at IS NOT NULL AND last_cost_change > allocated_at`,而 `last_cost_change = max(GREATEST(created_at, updated_at))`,软删把 `updated_at` 顶上去 |
| 11 | `LossPanel:100` | `deleteRunLoss` → `processing_run_losses` **硬删** | **这张单的损耗总量不变,变的只是它怎么分类;分类之和不必等于总量,但不许超过** | **c** — `db/functions/guard_processing_run_losses.sql` 及其自己的 `HINT`:「分了类的损耗之和超过了这张加工单的损耗总量。两者【不必相等】,但分类不许超过总量」 |
| 12 | `DeleteTemplateButton:25` | `deleteTemplate` → `payment_term_templates` 软删 | **名字可以重新使用**;**把它设为默认的供应商以后开单不再自动带出**;已用它的采购单条款不变 | **c + a** — c:`db/tables/payment_term_templates.sql:36` `CREATE UNIQUE INDEX idx_payment_term_templates_name_live`(partial,只看在册);a:`app/purchasing/orders/new/page.tsx` 模板那一句 `.is('deleted_at', null).eq('is_active', true)`,而默认模板是从这份清单里套用的;**「已用它的采购单条款不变」另有硬证据** —— `db/functions/create_purchase_order.sql:330` 是 `INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage, …)`,**里程碑是抄到单子上的,不是指回模板的** |
| 13 | `customers/DeleteButton:22` | `softDeleteCustomer` | 同 #8 | **a + c** — a:§2 那 16 处客户列表取全部过滤;c:`create_sales_order.sql:23` `SO_CREATE_CUSTOMER_INVALID` |
| 14 | `customers/[id]/edit/AttachmentsPanel:203` | `customer_attachments` 软删 | ✗ **没有** | 见 §5.2 ② |
| 15 | `QuoteLinesEditor:123` | `removeQuoteLine` → `quote_lines` **硬删** | **这份报价会被记成「签发之后又改过」**;**转成订单之后明细就不能再删** | **c** ×2 — ① `db/tables/quote_lines.sql:42` `trg_quote_lines_touch_parent`,注释写明它就是「签发之后又改过」那个信号(比 `quotes.updated_at` 与最新 `issued_at`);② `guard_quote_line_converted_immutable()` 抛 `QT_CONVERTED_IMMUTABLE\|lines\|%` |
| 16 | `suppliers/DeleteButton:22` | `softDeleteSupplier` | 同 #8 | **a + c** — a:§2 那 26 处供应商列表取全部过滤;c:`create_purchase_order.sql:59` `SUPPLIER_NOT_FOUND` |
| 17 | `suppliers/[id]/edit/AttachmentsPanel:203` | `supplier_attachments` 软删 | ✗ **没有** | 见 §5.2 ② |
| 18 | `CompliancePanel:120` | `deleteCompliance` → `supplier_compliance` 软删 | ★★ **拦收货的是【过期的】证书,不是【缺少的】证书 —— 所以删掉一张正在拦收货的过期证书之后,这家供应商的货又可以收了** | **c** — `db/tables/inbound_batches.sql:180-196`(`guard_inbound_po_receivable` 的证书段):`WHERE sc.supplier_id = NEW.supplier_id AND sc.deleted_at IS NULL AND ct.disposition = 'block' AND sc.valid_until < CURRENT_DATE` → `SUPPLIER_QUALIFICATION_EXPIRED`;**函数自己的注释逐字写着「【缺证不挡】:挡的是"过期",不是"没有"」**。同一份谓词也在 `db/views/supplier_receiving_blocked.sql` 上 |
| 19 | `DeleteFormulaButton:17` | `deleteFormula` → `pricing_formulas` 软删 + `redirect` | **新单上不再出现在可选项里**;已用它算过价的单据价格不变;删成之后回到公式列表 | **a + c** — a:`app/purchasing/orders/new/page.tsx` 公式那一句 `.is('deleted_at', null).eq('is_active', true).neq('direction','sale')`;c:`redirect('/tools/pricing/formulas')`,**外加一条按名拒** —— `db/functions/price_output_sale.sql:60-62`:`IF NOT FOUND OR v_formula_deleted IS NOT NULL THEN RAISE EXCEPTION 'FORMULA_NOT_FOUND|%'`(拿一条已软删的公式【重新算价】会被按名拒;而【已经算好存下来的价】不变,所以句子那两半都成立)|
| 20 | `NodeTree:146` | `removeNode` → `task_nodes` **硬删** | ✗ **没有写**(但**不是因为查不到**)| 见 §5.2 ③ —— 查到了 `TASK_NODE_HAS_CHILDREN`,**而调用点上有一条明文裁定说它不该写进这个对话框** |
| 21 | `TaskHeader:184` | `softDeleteTask` → `tasks` 软删 | ✗ **没有** | 见 §5.2 ④ |

★ **一处刻意的收窄,记在这里(与 CONSEQ-1 §3 同一条线):**
第 8 / 13 / 16 处**没有**写「系统会拒绝把它选到新单据上」——
那句话只在走了那几支创建 RPC 的单据上成立(§3 末尾那一段)。
成立的是「屏幕上不再把它摆出来给你选」,**所以写的是后者**。

---

## 5. PART 3 —— 写了哪些,以及**每一处留白的理由**

### 5.1 做法

**一律用既有的 `details` prop,`body` 一个字没动。** 不加新 prop,不动 `title`,不动按钮字。
`ConfirmContent` 上 `body?: string` 与 `details?: React.ReactNode` **本来就都有**
(`app/components/ui/confirm-dialog.tsx:73,79`),而**仓库里已有同形的先例**:
`app/output/[id]/edit/SafetyStatePanel.tsx:97` 就是拿 `details` 挂一句后果,
键名 `…removeConsequence`。**本刀逐字沿用那个写法与那套键名。**

```jsx
body={t('common.softDeleteNote')}          ← 一个字没动
details={
    <p className="text-sm font-medium text-foreground">
        {t('<新键>')}
    </p>
}
```

☞ **为什么不是把两句拼进 `body`**:那会把「通用那句」和「这一处那句」焊成一个字符串,
下一次改措辞就得同时改两句话中间的空格与标点。**分成两格,一次改动只碰一条词条**
(委托书:写成一次措辞改动只花一条消息的编辑)。

**15 处写了句子**(#2 #3 #4 #5 #6 #7 #8 #10 #11 #12 #13 #15 #16 #18 #19)。

### 5.2 ★ 留白的六处,逐条点名与理由(**可审计,不是默认**)

| # | 站点 | 为什么一个字都没写 |
|---|---|---|
| ① | `FinanceAttachmentsPanel:226` | **差一点写错,查下去发现不成立。** `finance_attachments` 确实挂着一条闸:`db/functions/decide_expense_claim.sql:79-83` —— 没有在册附件且没填 `no_receipt_reason` 就抛 `EXPENSE_CLAIM_NO_EVIDENCE`。**但它查的是 `claim_id`,而这个面板从不写 `claim_id`**:`financeAttachmentActions.ts:49-55` 把四种 `parent.kind` 映到 `sales_record_id` / `inbound_batch_id` / `payment_id` / `expense_id`,**没有 `claim_id` 这一支**。在这里写「删了它这笔报销就批不掉」会是一句**在这个屏幕上为假**的话。→ 留白;那条闸与它没有 UI 这件事登记在 §8 ② |
| ② | `materials/[id]/edit/AttachmentsPanel:196`<br>`customers/[id]/edit/AttachmentsPanel:203`<br>`suppliers/[id]/edit/AttachmentsPanel:203` | 三处同形。`material_attachments` / `customer_attachments` / `supplier_attachments` 三张表**在 `db/functions` 与 `db/views` 里没有任何读者**(只有 `db/tables/*.sql` 自己)。也就是说除了这张附件表自己的列表,**没有任何东西因为这一行消失而改变行为**。而 `common.softDeleteFileNote`(「记录会隐藏,已存储的文件仍保留」)**已经把全部真相说完了**。→ 通用那句就是全部真相,按 R-Q2 **留着别动** |
| ③ | `NodeTree:146` | ★ **查到了后果,但调用点上有一条明文裁定说它不该写在这里。** `db/functions/trg_task_nodes_no_orphan.sql` 抛 `TASK_NODE_HAS_CHILDREN`(绝不 CASCADE),这是真的。**而 `NodeTree.tsx:139-143` 逐字写着**:「★【子步骤那条规矩【不】写进这句话里】★ …… 把它写进确认框,等于描述一个「确认根本不适用」的情形 —— 那条拒绝会在按下之后按名出现,而它自己会说话。」**推翻一条前一刀写下来的裁定是一次形状改动,不是一个细节**,所以本刀不自己推翻它。→ 留白,并把它与 CONSEQ-1 的实际做法之间的张力登记在 §8 ③ 交给 Tim |
| ④ | `TaskHeader:184` | `softDeleteTask` 只是 `tasks` 上一句 `update({deleted_at})`。读 `tasks` 的是 `task_board_rows` 等视图,**效果就是"从看板上消失"**,而 `common.softDeleteNote`(「记录留在库里,谁删的、为什么都记着」)**已经把这件事说完了**。**没有找到任何一句它没说到、而又验证得出来的话。** → 留着别动 |

★ **委托书 §3 那一条在本刀身上兑现了**:21 处里有 6 处**没有**写第二句话,
其中 ① 和 ③ 是**已经写出草稿又撤掉的**。一句没验证过的第二句话比没有第二句话更坏。

---
## 6. 每一条新增的用户可见文案 —— **逐字,英中并列,按屏幕分组**

**十五条,全部是【新增】的词条。** 既有的 `common.softDeleteNote` /
`common.hardDeleteNote` / `common.softDeleteFileNote` 三句通用说明,
以及每一处的 `title`、`subject` 与按钮字,**一个字都没有改动**。

**没有一处新增或去掉确认框,没有一处改变哪些动作被把关,没有一个按钮标签变过。**

### 物料 · 删除(`/materials`)

词条键:`materials.deleteConsequence`

* **EN** — It stops being offered when someone makes a new document. Documents that already use it keep showing its name.
* **ZH** — 以后开新单据时，它不会再出现在可选项里。已经用到它的单据照常显示它的名字。

### 客户 · 删除(`/sales/customers`)

词条键:`customers.deleteConsequence`

* **EN** — It stops being offered when someone makes a new document. Documents that already use it keep showing its name.
* **ZH** — 以后开新单据时，它不会再出现在可选项里。已经用到它的单据照常显示它的名字。

### 供应商 · 删除(`/suppliers`)

词条键:`suppliers.deleteConsequence`

* **EN** — It stops being offered when someone makes a new document. Documents that already use it keep showing its name.
* **ZH** — 以后开新单据时，它不会再出现在可选项里。已经用到它的单据照常显示它的名字。

### 供应商 · 合规证书 · 删除(`/suppliers/[id]/edit`)

词条键:`suppliers.compliance.deleteConsequence`

* **EN** — Receiving is blocked by an expired certificate, not by a missing one. If this certificate had expired and was blocking receiving, deleting it lets goods from this supplier be received again.
* **ZH** — 拦住收货的是【过期的】证书，不是【缺少的】证书。这张证书如果已经过期、正在拦着收货，删掉它之后这家供应商的货又可以收了。

### 银行对账单 · 删除(`/finance/bank/statements/[id]`)

词条键:`bank.deleteConsequence`

* **EN** — A statement that has already been reconciled cannot be deleted — reopen it first. After deleting you are taken back to the statement list.
* **ZH** — 已经对过账的对账单删不掉——要先重新打开它。删除之后会回到对账单列表。

### 计价公式 · 删除(`/tools/pricing/formulas/[id]/edit`)

词条键:`pricing.deleteConsequence`

* **EN** — It stops being offered on new orders. Orders already priced with it keep their prices. After deleting you are taken back to the formula list.
* **ZH** — 以后开新单时，它不会再出现在可选项里。已经用它算过价的单据价格不变。删除之后会回到公式列表。

### 付款条件模板 · 删除(`/purchasing/payment-terms`)

词条键:`purchasing.deleteTemplateConsequence`

* **EN** — The name becomes free to use again. Suppliers that have this template as their default stop having it filled in for them; purchase orders already using it keep their terms.
* **ZH** — 这个名字可以重新使用。把它设为默认条款的供应商，以后开单不会再自动带出它；已经用了它的采购单条款不变。

### 加工单 · 成本条目 · 删除(`/operation/processing/[id]`)

词条键:`processing.cost.deleteConsequence`

* **EN** — A reversing entry is posted today, so the books balance from today rather than from the original date; the original entry stays. A cost that has already been remitted or written off cannot be deleted. If this run has already been allocated, the allocation is marked out of date and needs running again.
* **ZH** — 系统会按今天补一张冲销分录，于是账从今天起平，而不是从原来那一天起平；原来那张分录留在账上。已经汇出或已经核销的成本删不掉。这张加工单如果已经分摊过，分摊会被标成过期，要重新跑一次。

### 加工单 · 损耗分类 · 删除(`/operation/processing/[id]`)

词条键:`processing.loss.deleteConsequence`

* **EN** — The total loss on this run does not change — only how it is broken down. The categories never have to add up to the total, but they may not exceed it.
* **ZH** — 这张加工单的损耗总量不变——变的只是它怎么分类。分类之和不必等于总量，但不许超过总量。

### 报价单 · 删除明细行(`/sales/quotes/[id]`)

词条键:`quotes.removeLineConsequence`

* **EN** — The quotation will read as changed since it was last issued. Once a quotation has been converted into an order, its lines can no longer be deleted.
* **ZH** — 这份报价会被记成【签发之后又改过】。报价一旦转成订单，它的明细就不能再删。

### 批次金属含量 · 删除(`/inbound/[id] · /output/[id]`)

词条键:`metalContent.deleteConsequence`

* **EN** — This metal stops counting towards the price of this batch. Remove the last metal and the batch can no longer be priced from its agreed terms.
* **ZH** — 这种金属不再计入这批货的计价。删掉最后一种金属之后，这批货就无法再按约定的条款算价。

### 部门 · 删除(`/hr/departments`)

词条键:`hr.deleteDepartmentConsequence`

* **EN** — A department that still has people in it cannot be deleted — move them to another department first.
* **ZH** — 还有人在的部门删不掉——请先把这些同事调到别的部门。

### 培训记录 · 删除(`/hr/training`)

词条键:`hr.deleteTrainingConsequence`

* **EN** — Its renewal reminder stops appearing — this training will no longer be listed as expiring or overdue.
* **ZH** — 它的续期提醒不会再出现——这项培训不再被列为即将到期或已过期。

### 公众假期 · 删除(`/hr/leave/holidays`)

词条键:`leave.holidayDeleteConsequence`

* **EN** — This date counts as a working day again: leave that covers it will use one more day, and exchange-rate lookups will no longer skip past it.
* **ZH** — 这一天会重新算作工作日：跨过它的休假会多扣一天，汇率取数也不再跳过这一天。

### 绩效目标 · 删除(`/hr/reviews`)

词条键:`reviews.goalDeleteConsequence`

* **EN** — Whatever has already been written against this objective goes with it. Once the self-assessment has started, objectives can no longer be deleted.
* **ZH** — 已经针对这条目标写下的内容会跟着一起消失。自评一旦开始，目标就不能再删。

---

## 7. 队列条目 —— 连同【这些数是从哪来的】

`docs/forward-queue.md` 里的 `CONSEQ-2` 条目已划掉并改写成关闭记录,写进了这次提交
(维护规则:一刀关闭就在关闭它的那一次提交里把它划掉)。要点:

* **CONSEQ-2 关闭。** 桶 B 二十一处:**15 处补了后果句,6 处留白**(留白逐条列名与理由)。
* **「它不会再被选到」这句话现在可以写了,而当初写不了的理由是【问错了对象】。**
  * **旧的问法**「所有读点都过滤 `deleted_at` 吗」→ 分母里混着写入点、计数与按 id 取,
    而**选择器根本不在那个总体里**。
  * **新的问法**「一行软删的行还能不能在一张【新】单据上被选中」→ 量在选择点上。
  * **出处**:选择器从三张**查名视图**喂(`material_lookup` 20 · `supplier_lookup` 26 ·
    `customer_lookup` 14 = **60 个站点**),而队列指定的量法 `delcount.mjs`
    **结构上看不见这 60 处**。
* **新数与量法(可复算):**
  * `.from()` 站点 **110**(六个标识符),分格 写入点 10 · 计数 4 · 按 id 取 31 · 列表取 65。
  * **列表取里未过滤 `deleted_at` 的:0 处。**
  * 内嵌关系读 `materials` 19 · `suppliers` 5 · `customers` 7 = **31 处**,
    **逐处读过,没有一处是选择点。**
  * **量法:`pickerscan.mjs`,全文在 `docs/handbacks/CONSEQ-2-round2.md` §12。**
    三个关键零件:逐字符 code/comment/string 定性 · 三判据的链终点(**不是定长窗口**) ·
    赋值目标 → helper 感知。
* **★ 旧数照抄进来的那三个内嵌数(21 / 9 / 4)复现不了** —— 见 §8 ④。
* **★ 本刀自己踩过一次「量具坏了」并修好**(正则字面量把词法奇偶性弄反),
  过程与那条新断言记在 §2.4;**第一版那个「5 处未过滤」是量具的产物,不是树的事实。**

---

## 8. 又找到的窄覆盖 / 缺口,**登记,没有修**

| # | 事情 | 文件与行 | 为什么不在本刀修 |
|---|---|---|---|
| ① | **三张查名视图自己不过滤 `deleted_at`,却把 `deleted_at` 摆在列上** —— 过滤整个压在调用点上。今天 65/65 都做到了,**而没有任何机制保证第 66 个调用点也会做到** | `db/views/material_lookup.sql:29` · `db/views/supplier_lookup.sql:22` · `db/views/customer_lookup.sql:19`(三处 `WHERE` 里只有权限谓词) | 要么改视图(一支迁移,本刀明令不含 SQL),要么加一支检查(会改变构建链与 `check-instrument-selfproof` 的读数)。**两条都是另一刀** |
| ② | **`finance_attachments.claim_id` 有列、有外键、有索引、有一条闸依赖它,而 `app/` 里没有任何代码写它** —— 于是 `decide_expense_claim` 的「有没有凭据」那一问**永远只能靠 `no_receipt_reason` 那条例外出口回答** | 闸:`db/functions/decide_expense_claim.sql:79-83`;列:`db/tables/finance_attachments.sql:47,84-88`;**写入点:`grep -rn "claim_id" app/` 无一处写 `finance_attachments`** | 补上传 UI 是一个功能,不是一句文案。**远超本刀范围** |
| ③ | **`NodeTree` 的裁定与 CONSEQ-1 的实际做法之间有张力** —— `NodeTree.tsx:139-143` 明文说「按下之后才按名出现的拒绝,不该写进确认框」;而 CONSEQ-1 在 GST 开关(#3)与薪资撤销过账(#5)两处**恰恰把拒绝条件写进了确认框** | `app/tools/tasks/[id]/NodeTree.tsx:139-143` vs `docs/handbacks/CONSEQ-1-round2.md` §2 第 3、5 行 | 两边都有道理,而**统一它是一条房规,不是一处文案**。交给 Tim 裁 |
| ④ | **队列里那三个内嵌读数(materials 21 · customers 9 · suppliers 4)复现不了,而且它们的量法没有留下** —— 队列写的量法是 `delcount.mjs`,**但那支脚本根本不数内嵌读**。本刀量到 19 / 7 / 5 | `docs/forward-queue.md` CONSEQ-2 条目的更正块 | 这正是队列自己 R-Q5 要防的事(记出处,不只记结果)。**本刀把自己的量法写进 §12**,旧数只能标为出处不明 |
| ⑤ | **`pickerscan.mjs` 那条「是不是选择点」由人读定,没有机制守着** —— 下一次有人加一个新的下拉喂料点,没有任何东西会提醒他 | (本刀的量具,不在仓库里) | 把它做成一道闸要先解决「怎么机械地认出一个选择点」,而本刀的瞄准线正是写着这件事做不到。**登记,不假装做到了** |

---

## 9. 我自己决定的事(细节,不是形状)

### 9.1 量具**留在仓库外**,全文抄进交回报告

委托书允许两者。选了前者,理由是 PART 1 自己登记过的那一条:
**「一支存在却从不运行的证明工具,它的覆盖率是 0」**(合并记录实例 ⑨,
`check-css-declarations` 就是那个形状)。把 `pickerscan.mjs` 放进 `scripts/`
会立刻造出第二个同形的孤儿;放进 `docs/` 又会进 eslint 的 `lintFiles(['.'])` 射程,
**而 eslint 冻在 42/88**。
☞ 所以:**代码留在外面,方法与全文进交回报告**(§12),下一个人可以整支复制回来跑。
(中途确实往 `docs/instruments/` 拷过一次,**在跑构建之前撤掉了** —— 因为那次拷贝
发生在 `check-lint` 跑完之后,它没有被 lint 过,而我不打算把一个没被闸看过的文件带进提交。)

### 9.2 致盲改用 `blind2.py`,不用 `/tmp/blind.mjs`

`/tmp/blind.mjs` 本身没问题,**问题在它与 shell 之间**:第一次致盲(B1)的 find 串里
有引号,zsh 把它吃掉了,于是命中 0 处 —— **一次 NOOP**。
所以写了 `blind2.py`:find/replace 走 **stdin 上的 JSON**,**不经过任何 shell 引用**。
其余语义与 `blind.mjs` 逐条相同(命中 0 报 NOOP · 跑完逐字节还原并校验 · 取脚本自己的退出码)。
**多了一个显式 `cwd` 参数** —— 因为对照格第一次跑回来的 exit 1 是【工作目录错了】导致的崩溃,
不是判词(§2.5 末尾)。

### 9.3 后果句挂在 `details` 上,不拼进 `body`

`body` 与 `details` 都是既有 prop,仓库里已有同形先例(`SafetyStatePanel:97`)。
挂 `details` 让通用那句与这一处那句**各占一格**,改措辞时一次只碰一条词条。

### 9.4 键名一律 `…Consequence`

沿用既有命名(`output.safety.removeConsequence`,以及 `inbound` / `output` 两处
**早就存在的** `deleteConsequence`)。没有发明新的命名法。

### 9.5 三条 helper 探针是**致盲之后补的**

B6 第一次只到 exit 1,说明断言下得太早。补探针再跑即 exit 2。
这与 NARROW-COVERAGE-1 §2.4 #25–28 是同一个动作,**照实记成"第一次没咬人"**,
不记成一次通过。

### 9.6 `is_business_day` 那一句只写向前的一半

删掉一个公众假期之后,**已经批过的假会不会被重算**,本刀没有验证(要读
`calculate_leave_days` 的调用点是存了数还是每次现算)。所以句子只说
「跨过它的休假会多扣一天」这个向前成立的半句,**没有说"以前批的假也会变"**。

---
## 10. 怎么走这一遍

### 10.0 ★ 先说安全 —— **这十五处一处都不要在真记录上按下去**

* **五处是硬删**(#2 金属含量 · #5 公众假期 · #6 绩效目标 · #11 损耗分类 · #15 报价明细):
  行直接从库里移除,没有任何地方留副本。
* **十处是软删**,而 `common.softDeleteNote` 自己那句话就写着
  **「删除不会被撤销 —— 本系统刻意不提供恢复」**。
* 其中 **#10(加工成本条目)按下去会【真的过一张冲销分录】**,#3 与 #19 **按下去会跳走**。

☞ **走法:把对话框打开、读那两段字、然后按取消。**
   要真按下去,请先自己造一条丢得起的记录(新建 → 立刻删),不要拿线上单据试。
   **本节因此是【路径】,不是记录号** —— 与 CONSEQ-1 §8.1 同一个理由,见 §10.2。

### 10.1 十五处的去处、要什么角色、以及那条记录要满足什么

| # | 点哪儿 | 需要的权限码 | 那一行要满足什么 | 这一次读到的第二段应当是 |
|---|---|---|---|---|
| 8 | `/materials` 列表任一行的 **删除** | `module.materials.edit` | 任一在册物料 | 「新单据上不再出现在可选项里……」 |
| 13 | `/sales/customers` 任一行的 **删除** | `module.customers.edit` | 任一在册客户 | 同上 |
| 16 | `/suppliers` 任一行的 **删除** | `module.suppliers.edit` | 任一在册供应商 | 同上 |
| 18 | `/suppliers/<id>/edit` → 合规证书那张表 → **删除** | `module.suppliers.edit` | **一张 `disposition='block'` 且 `valid_until < 今天` 的证书**(最能说明问题的那一格) | 「拦收货的是【过期的】证书,不是【缺少的】证书……」 |
| 3 | `/finance/bank/statements/<id>` → **删除对账单** | `module.finance.edit` | 一张**未对账**的(已对账的会被 `STATEMENT_RECONCILED` 拒) | 「已经对过账的对账单删不掉……」 |
| 19 | `/tools/pricing/formulas/<id>/edit` → **删除** | `module.pricing.edit` | 任一在册公式 | 「新单上不再出现在可选项里……」 |
| 12 | `/purchasing/payment-terms` → 某个模板的 **删除** | `module.purchasing.edit` | 任一在册模板(**最好是某家供应商的默认模板**) | 「名字可以重新使用……」 |
| 10 | `/operation/processing/<id>` → 成本那张表 → **删除** | `module.processing.edit` | **`status='committed'` 且有成本条目的加工单**(`runEditable` 要的就是 committed) | 「按今天补一张冲销分录……」 |
| 11 | 同一页 → 损耗那张表 → **删除** | `module.processing.edit` | 有损耗分类行的加工单 | 「损耗总量不变,变的只是分类……」 |
| 15 | `/sales/quotes/<id>` → 明细行的 **删除** | `module.sales.edit` | **`status` 不是 `converted`** 的报价(converted 的会被 `QT_CONVERTED_IMMUTABLE` 拒) | 「会被记成【签发之后又改过】……」 |
| 2 | `/inbound/<id>` 或 `/output/<id>` → 金属含量那张表 → **删除** | `module.inbound.edit` / `module.output.edit` | 有含量行的批次 | 「这种金属不再计入本批计价……」 |
| 4 | `/hr/departments` → 某部门的 **删除** | `module.hr.edit` | **两种各看一次**:有人的(会被挡)、没人的 | 「还有人在的部门删不掉……」 |
| 7 | `/hr/training` → 某条记录的 **删除** | `module.hr.edit` | **有 `expiry_date` 的**(没有到期日的看不出提醒那半句) | 「它的续期提醒不再出现……」 |
| 5 | `/hr/leave/holidays` → 某个假期的 **删除** | `module.hr.edit` | 任一 `is_active` 的假期 | 「这一天重新算作工作日……」 |
| 6 | `/hr/reviews` → 目标编辑器 → 某条目标的 **删除** | `module.hr.edit` | **一份还是 `draft` 的评估**下面的目标 | 「已经写下的内容一并消失……」 |

★ **#6 与 CONSEQ-1 欠着的那一条是同一个前置**:它要一行 `performance_reviews`。
  委托书把「评估那一族要一行 `performance_reviews`」列在【Tim 还欠着、不是本刀的活】里,
  所以 #6 大概率也走不了 —— **照实说,不假装它能走。**

### 10.2 ★ 我没能替你取到真实记录号 —— **这是一次被拦下的查询,不是一次猜测**

本会话里对线上跑 `psql` 的那一次**被权限分类器拦下**(只读 `SELECT`,仍然被拦)。
按委托书的话:**把只读查询交回来,不猜记录号。**

```sql
-- CONSEQ-2 走查用:全部只读,一条写都没有。
\pset pager off

-- #18 最值得看的那一格:今天正在【拦着收货】的供应商证书
SELECT supplier_code, cert_type_code, valid_until FROM supplier_receiving_blocked;
-- 若上面是空的,退一步看有没有 block 类型的证书可看:
SELECT s.code, sc.cert_type_code, sc.valid_until, ct.disposition
  FROM supplier_compliance sc
  JOIN suppliers s          ON s.id  = sc.supplier_id
  JOIN certificate_types ct ON ct.code = sc.cert_type_code
 WHERE sc.deleted_at IS NULL ORDER BY sc.valid_until LIMIT 10;

-- #8 / #13 / #16
SELECT code, name       FROM materials WHERE deleted_at IS NULL ORDER BY code LIMIT 3;
SELECT code, legal_name FROM customers WHERE deleted_at IS NULL ORDER BY code LIMIT 3;
SELECT code, legal_name FROM suppliers WHERE deleted_at IS NULL
   AND counterparty_type <> 'forwarder' ORDER BY code LIMIT 3;

-- #3 一张【未对账】的对账单
SELECT id, status, (reconciled_at IS NOT NULL) AS reconciled
  FROM bank_statements WHERE deleted_at IS NULL ORDER BY created_at DESC LIMIT 5;

-- #10 / #11 committed 且有成本 / 有损耗分类的加工单
SELECT r.code, r.status,
       count(c.id) FILTER (WHERE c.deleted_at IS NULL) AS cost_entries,
       (SELECT count(*) FROM processing_run_losses l WHERE l.run_id = r.id) AS loss_rows
  FROM processing_runs r LEFT JOIN processing_cost_entries c ON c.run_id = r.id
 WHERE r.deleted_at IS NULL GROUP BY r.code, r.status ORDER BY cost_entries DESC LIMIT 5;

-- #15 一份【没有 converted】且有明细的报价
SELECT q.code, q.status, count(l.id) AS lines
  FROM quotes q LEFT JOIN quote_lines l ON l.quote_id = q.id
 WHERE q.deleted_at IS NULL AND q.status <> 'converted'
 GROUP BY q.code, q.status ORDER BY lines DESC LIMIT 5;

-- #2 有金属含量行的批次
SELECT b.code, count(m.metal) AS metals FROM inbound_batches b
  JOIN inbound_batch_metals m ON m.inbound_batch_id = b.id
 WHERE b.deleted_at IS NULL GROUP BY b.code ORDER BY metals DESC LIMIT 5;

-- #4 有人的 / 没人的部门各一个
SELECT d.name, count(e.id) FILTER (WHERE e.deleted_at IS NULL) AS headcount
  FROM departments d LEFT JOIN employees e ON e.department_id = d.id
 WHERE d.deleted_at IS NULL GROUP BY d.name ORDER BY headcount LIMIT 8;

-- #7 有到期日的培训 / #5 在册假期 / #12 模板 / #19 公式
SELECT training_name, expiry_date FROM training_records
 WHERE deleted_at IS NULL AND expiry_date IS NOT NULL ORDER BY expiry_date LIMIT 5;
SELECT holiday_date, name FROM public_holidays WHERE is_active ORDER BY holiday_date DESC LIMIT 5;
SELECT name, is_active FROM payment_term_templates WHERE deleted_at IS NULL LIMIT 5;
SELECT code, name, direction FROM pricing_formulas WHERE deleted_at IS NULL LIMIT 5;

-- #6 还是 draft 的评估(它同时是 CONSEQ-1 欠着的那个前置)
SELECT pr.id, pr.status, count(g.id) AS goals
  FROM performance_reviews pr LEFT JOIN review_goals g ON g.review_id = pr.id
 GROUP BY pr.id, pr.status LIMIT 5;
```

### 10.3 ★ 顺带值得看一眼的一处(**本刀没有改它**)

`/finance/expenses/<id>` 等四张详情页共用的那个附件面板(#1),
它的说明用的是 `common.softDeleteNote`(「记录留在库里」),
而三张主数据附件面板用的是 `common.softDeleteFileNote`(「记录会隐藏,已存储的文件仍保留」)。
**同样是删一个附件,两句话不一样。** 本刀**没有动它** —— 改通用那句是改 `body`,
而委托书说通用那句留着别动。**登记在这里,由你裁。**

---
## 11. 收尾:闸门、构建、提交

### 11.1 `db/gate.py` —— **自己的**退出码、墙钟、四条判词逐字

```
GATE_OWN_EXIT=0
```

**墙钟:404s**(外层实测,`date +%s` 前后相减;闸自己在第 247 行印的是
`== 三个判词(wall-clock 303s)` —— 那是三个判词那一段的耗时,
外层的 404s 还含 `db/check_grants.py` 那一段。**两个数都报出来,不合并。**)

★ **`db/gate.py:38` 的区间是 180–700s,而 404s 落在区间内 —— 所以本刀没有动那个区间。**
(委托书要求的是"落在区间外就放宽",这一次没有触发。)

**四条判词,逐字:**

```
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
```

### 11.2 `npm run build` —— 自己的退出码、eslint 冻结那一行、以及那一支元检查

```
BUILD_OWN_EXIT=0
```

**eslint 冻结闸,逐字:**

```
── eslint 冻结闸 ─────────────────────────────────────────────
基线  error 42 · warning 88
现在  error 42 · warning 88

✓ 没有新增的 eslint 问题。
```

**元检查(PART 1 那一支),逐字:**

```
✓ check-instrument-selfproof:32 支量具都写了瞄准线;其中 22 支(构建链里的,含本支)都带着覆盖断言。
```

**顺带,两支与本刀直接相关的:**

```
check-confirm-subject: 57 处 subject(JSX 57 · useConfirm 0) / 57 个 JSX 开标签,来自 51 个文件,English 词条 6313 条
EXIT 0 — 每一处确认都点得出它在确认什么。
```
☞ **57 / 57 一个没变** —— 本刀没有新增或去掉任何一个确认框,这一行就是那件事的独立证据。
另外 `npx tsc --noEmit` 单独跑过一次:`TSC_OWN_EXIT=0`,零行输出。

### 11.3 提交、推送、部署

| | |
|---|---|
| 开工 HEAD | `df643736a24530053390c31b3eb4d503fd9a9cf0` |
| **收工 HEAD** | **`77586eada533468318c143d6154f10c70dfbf827`** |
| 提交 | 19 个文件,+156 / −69(15 处调用点各 +5 行 · 两份词条各 +15 行 · 队列 · 本报告) |
| **推送校验** | ★ **靠 `git fetch` + 比对哈希,不靠 push 的输出** —— `HEAD` == `origin/main`,两者都是 `77586ea…`。**一个空的退出码不是一个成功的退出码**;顺带一提 `git push … \| tail` 那一行印出来的 `PUSH_OWN_EXIT=0` **是 `tail` 的退出码,不是 `git` 的**(zsh 的 `$?` 取的是管道最后一段),所以它本来也不作数 |
| 收工树 | `nothing to commit, working tree clean` |

**部署 —— 两个问题分开问的(委托书明令):**

| 问题 | 怎么问的 | 答案 |
|---|---|---|
| **Q1:存在一次 success 的部署吗?** | 问 `deployments/6343048085/**statuses**`(**不是**问那条部署记录本身) | **`state=success`**,`2026-09-09T05:15:12Z` |
| **Q2:那一次的 sha 是本刀这次提交吗?** | 问 `deployments/6343048085` 的 `.sha`,再与 `git rev-parse HEAD` 逐字比 | **`77586eada533468318c143d6154f10c70dfbf827` == 本刀提交,MATCH** |

* **部署 id:`6343048085`**
* **sha:`77586eada533468318c143d6154f10c70dfbf827`**
* **success 时刻:`2026-09-09T05:15:12Z` = 2026-09-09 13:15:12 CST**
* URL:`https://new-era-1b6e7onkd-tim-s-projects7.vercel.app`

★ **实测滞后**:推送后第一次查 `deployments?sha=` 返回**空数组**,轮询到第二次才拿到记录。
**空数组不是"部署失败",是"下游登记还没写下来"** —— 与 PART 1 记的 162 秒同族。

★ **破窗:不适用。** 本刀**零 SQL、零迁移**(`apply_migration.sh` 一次都没跑),
没有"旧代码 + 新库"那个窗口。success 时刻记在这里是为了完整,不是因为有窗口要闭合。

---

## 12. 量具全文 —— `pickerscan.mjs`

**它不在仓库里(理由见 §9.1),所以全文在这里。** 跑法:

```bash
cd ~/Documents/projects/new-era-erp
node <把下面这段存成的任意路径>.mjs
# 0 = 列表取全部过滤了 deleted_at   1 = 有未过滤的   2 = 量具坏了(覆盖断言失败)
# EMBEDS=1 额外逐条列出内嵌关系读;DUMP=<路径片段> 打印某个文件解析出的链
```

```javascript
#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// CONSEQ-2 PART 2 · 选择点普查 —— 「一行软删的料/供应商/客户,
//                                   还能不能在一张【新】单据上被【选中】」
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :`app/` 与 `lib/` 下每一处 `.from('<六个标识符之一>')` 的
//                   **完整调用链文本**(注释已抹成等长空格,字符串内容保留),
//                   外加每一处 `.select('…')` 字面量里的**内嵌关系读**。
//                   六个标识符 = 三张基表 + 三张查名视图:
//                   materials / material_lookup / suppliers / supplier_lookup /
//                   customers / customer_lookup。
//   我声称管的是   :**这份枚举是完整的**,而且每一处都被分到
//                   写入点 / 计数 / 按 id 取 / 列表取 这四格里的一格,
//                   列表取的那一格还标出了它**链上有没有** `.is('deleted_at', null)`。
//   两者不同之处   :★★ **我证不了「这条列表喂的是一个下拉」。**
//                   我读的是查询,不是屏幕。一条过滤了的查询照样可能把列表
//                   交给一个客户端组件再自己重新取一次;一条没过滤的查询也可能
//                   根本没有喂给任何 `<select>`。
//                   ☞ 【选择点这一半是人读出来的,不是这支脚本算出来的】——
//                     本支只负责「一处都没漏」,`是不是选择点` 由人逐个文件读定,
//                     逐条记在交回报告里。把这两件事混成一个数,正是
//                     CONSEQ-1 的实例 5(拿 `body=` 当「说不说后果」)那个形状。
//                   ☞ 另一处已知的窄:内嵌关系读我只认 `.select()` 的**字符串
//                     字面量**。select 串如果是拼出来的变量(如 EXPORT_COLUMNS),
//                     我看不见它里面有没有内嵌 —— 这一条按名记在下面 §EMBED-BLIND。
// ════════════════════════════════════════════════════════════════════════════
// 退出码沿用仓库三档:0 干净 · 1 找到违规 · 2 量具坏了(覆盖断言失败)。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { assertPopulation, assertPinned, assertAllowlistLive } from '/Users/timchen/Documents/projects/new-era-erp/scripts/lib/selfproof.mjs'

const SELF = 'pickerscan'
const ROOT = '/Users/timchen/Documents/projects/new-era-erp'

const IDS = ['materials', 'material_lookup', 'suppliers', 'supplier_lookup', 'customers', 'customer_lookup']
const BASE_OF = { material_lookup: 'materials', supplier_lookup: 'suppliers', customer_lookup: 'customers' }
const TABLE_OF = (id) => BASE_OF[id] ?? id

// ── 文件走查 ────────────────────────────────────────────────────────────────
const files = []
for (const root of ['app', 'lib']) {
    ;(function walk(d) {
        for (const n of readdirSync(join(ROOT, d))) {
            if (n === 'node_modules' || n === '.next' || n.startsWith('.')) continue
            const rel = `${d}/${n}`
            if (statSync(join(ROOT, rel)).isDirectory()) walk(rel)
            else if (/\.tsx?$/.test(n)) files.push(rel)
        }
    })(root)
}

// ── ① 逐字符定性:code / comment / string ───────────────────────────────────
// 为什么不用正则剥注释:本仓库的注释里全是中文逗号与括号,而链的终点判据
// 正是「深度 0 上的逗号」。注释里的一个 `)` 会让链提前收尾而**不吭声**。
// ★★【2026-09-09 · 本刀自己踩到的一次「量具坏了」,照直留在这里】★★
//   第一版【没有认正则字面量】。于是 `String(value).replace(/"/g, '""')` 里的
//   那个 `/"/g` —— 一个装着引号的正则 —— 让 `"` 被当成开引号,
//   **从那一行起整个文件的字符串奇偶性都反了**。
//   后果:`app/inbound/export/route.ts:102` 的链在 `.select('id` 处**提前收尾**,
//   于是它链上那个 `.is('deleted_at', null)` 我看不见,它被报成「未过滤」。
//   ☞ 而**上面三条覆盖断言全绿**:两条路都数出 110 个站点(发现步骤没瞎),
//     四格之和也等于总数(分格没丢样本)—— 它们证的是【灵敏度】,
//     而这是一次【瞄准】失效,正是 selfproof.mjs 抬头写着它治不了的那一类。
//     抓住它的是**人把输出和源码并排读了一遍**,不是任何一条断言。
//   ☞ 所以下面补了一条【真的治得了这一族】的断言:
//     **走完一个文件之后,状态必须回到 code** —— 卡在字符串里就是奇偶性反了。
function classify(src) {
    const kind = new Array(src.length).fill('code')
    let i = 0
    let unterminated = false
    // 正则字面量 vs 除号:看**前一个有意义的 code 字符**。
    // 它是 ( , = : [ ! & | ? { } ; 或者 return/typeof 之类,那么 `/` 开的是正则。
    const prevSignificant = () => {
        for (let j = i - 1; j >= 0; j--) {
            if (kind[j] === 'comment') continue
            if (/\s/.test(src[j])) continue
            return src[j]
        }
        return null
    }
    while (i < src.length) {
        const c = src[i], d = src[i + 1]
        if (c === '/' && d === '/') {
            while (i < src.length && src[i] !== '\n') kind[i++] = 'comment'
        } else if (c === '/' && d === '*') {
            kind[i++] = 'comment'; kind[i++] = 'comment'
            while (i < src.length && !(src[i] === '*' && src[i + 1] === '/')) kind[i++] = 'comment'
            if (i < src.length) { kind[i++] = 'comment'; kind[i++] = 'comment' }
        } else if (c === '/' && REGEX_CAN_START.has(prevSignificant())) {
            // 正则字面量:整段(含标志位)算 string,里面的引号一律不作数
            kind[i++] = 'code'
            let inClass = false
            while (i < src.length && src[i] !== '\n') {
                if (src[i] === '\\') { kind[i] = 'string'; kind[i + 1] = 'string'; i += 2; continue }
                if (src[i] === '[') inClass = true
                else if (src[i] === ']') inClass = false
                else if (src[i] === '/' && !inClass) { kind[i++] = 'code'; break }
                kind[i++] = 'string'
            }
            while (i < src.length && /[a-z]/.test(src[i])) kind[i++] = 'code'
        } else if (c === '"' || c === "'" || c === '`') {
            const q = c
            kind[i++] = 'code' // 引号本身算 code,便于 `.from('x')` 这样的正则照常匹配
            let closed = false
            while (i < src.length) {
                if (src[i] === '\\') { kind[i] = 'string'; kind[i + 1] = 'string'; i += 2; continue }
                if (src[i] === q) { kind[i++] = 'code'; closed = true; break }
                // ★ 这里【刻意不加】"非模板串不跨行"那条规则:
                //   JSX 的属性值是**真的跨行的**(app/settings/import/ImportForm.tsx:191
                //   那个 className 跨了四行)。加上那条规则会把一处合法写法报成奇偶性反了
                //   —— 一次误报,而 AGENTS.md 明写一道天天假红的闸三刀之内会被关掉。
                //   真正没闭合的串由走完文件之后的那条平衡断言接住。
                kind[i++] = 'string'
            }
            if (!closed) unterminated = true
        } else { i++ }
    }
    kind.unterminated = unterminated
    return kind
}
const REGEX_CAN_START = new Set(['(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '+', '-', '*', '%', '<', '>', '~', '^', null])

// 注释抹成等长空格(行号与偏移都不漂),字符串内容保留 —— 正则跑在这上面。
function maskComments(src, kind) {
    const out = src.split('')
    for (let i = 0; i < src.length; i++) if (kind[i] === 'comment' && src[i] !== '\n') out[i] = ' '
    return out.join('')
}

// ── ② 链的终点 ─────────────────────────────────────────────────────────────
// 深度只在 code 字符上加减(字符串与注释里的括号不算)。收尾判据三条:
//   · 深度 < 0        —— 撞上外层的收括号
//   · 深度 0 上的 , ;  —— 同级的下一项
//   · 深度 0 上的换行,而下一个 code 字符不是 `.` —— 本仓库不写分号,靠这条收尾
function chainEnd(src, kind, start) {
    let depth = 0
    let i = start
    for (; i < src.length; i++) {
        if (kind[i] !== 'code') continue
        const c = src[i]
        if (c === '(' || c === '[' || c === '{') depth++
        else if (c === ')' || c === ']' || c === '}') { depth--; if (depth < 0) return i }
        else if (depth === 0 && (c === ',' || c === ';')) return i
        else if (depth === 0 && c === '\n') {
            let j = i + 1
            while (j < src.length && (kind[j] !== 'code' || /\s/.test(src[j]))) j++
            if (j < src.length && src[j] !== '.') return i
        }
    }
    return i
}

// ── ③ 枚举 ─────────────────────────────────────────────────────────────────
const sites = []           // 每一处 .from(ID)
let rawLiteralHits = 0     // 独立粗计数:原文里 `.from('ID')` 字面量出现次数
const embeds = []          // 内嵌关系读

const unbalanced = []
for (const f of files) {
    const src = readFileSync(join(ROOT, f), 'utf8')
    const kind = classify(src)
    if (kind.unterminated) unbalanced.push(f)
    const masked = maskComments(src, kind)

    for (const id of IDS) {
        // 独立粗计数走【原文】,不剥注释、不解析链 —— 与下面那条路完全不共用零件
        const lit = `.from('${id}')`
        let p = -1
        while ((p = src.indexOf(lit, p + 1)) !== -1) rawLiteralHits++

        const re = new RegExp(String.raw`\.from\(\s*['"]${id}['"]\s*\)`, 'g')
        let m
        while ((m = re.exec(masked)) !== null) {
            const end = chainEnd(masked, kind, m.index + '.from'.length)
            const chain = masked.slice(m.index, end)
            // ★ 过滤器可能【不在链上】:列表页把链存进一个变量,
            //   再交给 applyXFilters(baseQuery, …) 去接过滤器。
            //   delcount.mjs 那一代用 ±700 字符的窗口猜这件事;这里改成
            //   **把赋值目标取出来,再看它是不是被喂进了那支 helper**。
            const assignedTo = (masked.slice(0, m.index)
                .match(/(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=\n]*)?=\s*(?:await\s+)?[A-Za-z_$][\w$]*\s*$/) ?? [])[1] ?? null
            const helperTakesIt = assignedTo !== null &&
                new RegExp(String.raw`apply(?:Material|Supplier|Customer)Filters\(\s*` + assignedTo + String.raw`\b`).test(masked)
            sites.push({
                file: f,
                line: src.slice(0, m.index).split('\n').length,
                id,
                table: TABLE_OF(id),
                chain,
                chainLen: chain.length,
                assignedTo,
                helperTakesIt,
            })
        }
    }

    // 内嵌关系读:`.select('… materials ( … ) …')` / `alias:materials(…)`
    const selRe = /\.select\(\s*(['"])([\s\S]*?)\1/g
    let s
    while ((s = selRe.exec(masked)) !== null) {
        const body = s[2]
        for (const t of ['materials', 'suppliers', 'customers']) {
            const eRe = new RegExp(String.raw`(?:^|[\s,:(])${t}\s*(?:!\w+)?\s*\(`, 'g')
            let e
            while ((e = eRe.exec(body)) !== null) {
                embeds.push({ file: f, line: src.slice(0, s.index).split('\n').length, table: t })
            }
        }
    }
}

// ── ④ 分格 ─────────────────────────────────────────────────────────────────
const WRITE = /\.(insert|update|upsert|delete)\s*\(/
const HEADCOUNT = /head:\s*true/
const BYID = /\.(eq|in)\(\s*['"]id['"]\s*,/
const DEL = /\.is\(\s*['"]deleted_at['"]\s*,\s*null\s*\)/
const HELPER = /apply(Material|Supplier|Customer)Filters/

for (const s of sites) {
    if (WRITE.test(s.chain)) s.bucket = 'write'
    else if (HEADCOUNT.test(s.chain)) s.bucket = 'count'
    else if (BYID.test(s.chain)) s.bucket = 'byid'
    else s.bucket = 'list'
    s.filtered = DEL.test(s.chain) || HELPER.test(s.chain) || s.helperTakesIt
}

// ════════════════════════════════════════════════════════════════════════════
// 覆盖断言 —— 四条里用得上三条,第四条为什么用不上写在下面
// ════════════════════════════════════════════════════════════════════════════

// ① 空总体:六个标识符【每一个】都必须量到东西。
//    整支合计非空是不够的 —— 一个标识符掉到 0,合计照样很大,而那一张表
//    从此不在射程里、屏幕上完全看不出来。所以逐个断言。
for (const id of IDS) {
    assertPopulation(SELF, `.from('${id}') 站点`, sites.filter((s) => s.id === id).length)
}
assertPopulation(SELF, '走到的 .ts/.tsx 文件', files.length)

// ② 双向钉住 · 其一:发现步骤。
//    判据那条路 = 剥注释 + 正则 + 链解析;独立那条路 = 原文里数字面量。
//    两条路不共用任何零件。不等就红,**不管哪个方向**。
assertPinned(SELF, '链解析数出的 .from() 站点 ↔ 原文字面量粗计数',
    sites.length, rawLiteralHits,
    '差额只有两种来源:注释里写了一处 .from(而粗计数把它算进来了),或者链解析漏抓/多抓。两种都要当场查清。')

// ② 双向钉住 · 其二:分格步骤。
//    delcount.mjs 那一代**对分类器没有任何防护**:它用一个 400 字符的定长窗口
//    当作「链」,而本仓库的链动辄跨几十行注释 —— 窗口切短了就静默漏掉过滤器。
//    这里钉的是【分格是一次划分】:四格之和必须等于总数,一处都不许掉出去。
assertPinned(SELF, '四格之和 ↔ 站点总数',
    sites.filter((s) => s.bucket === 'write').length +
    sites.filter((s) => s.bucket === 'count').length +
    sites.filter((s) => s.bucket === 'byid').length +
    sites.filter((s) => s.bucket === 'list').length,
    sites.length,
    '有站点没有被分到任何一格 —— 分类器有一条路径静默丢样本。')

// ★ 链解析【自己】的健全性:一条长度为 0 或者没有 `.select` 的链,
//   多半是终点判据提前收尾了。这一条治的正是定长窗口那一族缺陷的反面。
const truncated = sites.filter((s) => s.chainLen < `.from('${s.id}')`.length + 2)
assertPinned(SELF, '解析出的链里【疑似被提前截断】的条数', truncated.length, 0,
    truncated.map((s) => `  · ${s.file}:${s.line}`).join('\n'))

// ★ 新增的第四条(本刀踩过之后补的)—— 【走完一个文件,状态必须回到 code】。
//   一个装着引号的正则字面量、一个没闭合的串,都会让奇偶性从那一行起整个反掉,
//   而**上面每一条断言都照常全绿**:站点还是数得出来,四格照样加得起来,
//   只是每一条链都从错误的地方收尾。这一条直接量那个症状。
assertPinned(SELF, '走完之后仍卡在字符串里的文件数', unbalanced.length, 0,
    unbalanced.slice(0, 20).map((f) => `  · ${f}`).join('\n') +
    '\n  ☞ 奇偶性反了 —— 从那一行起本文件每一条链都会从错误的地方收尾,而其它断言看不见。')

// ③ 名单必须是活的 —— 一组【已知必然命中】的探针。
//    这一条守的是**分格判据**,不是发现步骤:上面②只保证「没丢样本」,
//    保证不了「分对了格」。下面每一条都是人读过源码之后写下的已知事实。
const PROBES = [
    // 新单据的选择点喂料(人读过,确认是喂给 <select> 的列表)
    { f: 'app/purchasing/orders/new/page.tsx', id: 'material_lookup', bucket: 'list', filtered: true },
    { f: 'app/purchasing/orders/new/page.tsx', id: 'supplier_lookup', bucket: 'list', filtered: true },
    { f: 'app/inbound/new/page.tsx', id: 'material_lookup', bucket: 'list', filtered: true },
    { f: 'app/output/new/page.tsx', id: 'customer_lookup', bucket: 'list', filtered: true },
    { f: 'app/sales/orders/new/page.tsx', id: 'materials', bucket: 'list', filtered: true },
    { f: 'app/sales/orders/new/page.tsx', id: 'customers', bucket: 'list', filtered: true },
    // 写入点(根本不是读点)
    { f: 'app/materials/new/actions.ts', id: 'materials', bucket: 'write' },
    { f: 'app/sales/customers/new/actions.ts', id: 'customers', bucket: 'write' },
    // 按 id 取:拿着一个已有父记录去取它指着的那一行(队列 §已知的坑里逐条列过)
    { f: 'app/purchasing/orders/[id]/page.tsx', id: 'materials', bucket: 'byid' },
    { f: 'app/finance/credit-notes/page.tsx', id: 'customers', bucket: 'byid' },
    { f: 'app/finance/statements/[id]/pdf/route.ts', id: 'customers', bucket: 'byid' },
    // 计数
    { f: 'app/materials/page.tsx', id: 'materials', bucket: 'count' },
    // ★ 过滤器【不在链上】的那一类 —— helper 接过去的。
    //   这三条是补上去的:拆掉 helper 感知那一次致盲原本只让本支报 exit 1
    //   (「找到 3 处未过滤」),也就是把一次**自己瞎掉**说成了**代码有问题**。
    //   探针补进来之后同一处致盲变成 exit 2。这是 NARROW-COVERAGE-1 §2.4
    //   #25–28 那四格的同一个动作:断言下得太早,就把它下移到真会塌的那一格。
    { f: 'app/materials/page.tsx', id: 'materials', bucket: 'list', filtered: true },
    { f: 'app/suppliers/page.tsx', id: 'suppliers', bucket: 'list', filtered: true },
    { f: 'app/sales/customers/page.tsx', id: 'customers', bucket: 'list', filtered: true },
]
assertAllowlistLive(SELF, '已知必然命中的分格探针', PROBES,
    (p) => sites.some((s) =>
        s.file === p.f && s.id === p.id && s.bucket === p.bucket &&
        (p.filtered === undefined || s.filtered === p.filtered)),
    (p) => `${p.f} · ${p.id} → ${p.bucket}${p.filtered === undefined ? '' : (p.filtered ? ' · 已过滤' : ' · 未过滤')}`)

// ④ assertAssertionsRan —— **用不上,说明理由**:
//    那一条治的是「单元测试形状」的脚本(check-pmap / check-org-tree /
//    check-near-duplicate):一串手写断言,失效方式是 early return 让某几条
//    根本没跑到而 failures 仍是 0。本支不是那个形状 —— 它没有分支断言,
//    它是一次普查,它的失效方式是【总体空掉】与【分格丢样本】,
//    而那两样已经由 ① 与 ② 守着。硬套第四条只会得到一个恒真的数。

// 内嵌读:零必须是一次测量
assertPopulation(SELF, '内嵌关系读(.select 字面量里的)', embeds.length)

// ════════════════════════════════════════════════════════════════════════════
// 输出
// ════════════════════════════════════════════════════════════════════════════
console.log(`走到文件 ${files.length} 个 · .from() 站点合计 ${sites.length}(独立粗计数 ${rawLiteralHits})`)
console.log()
for (const id of IDS) {
    const g = sites.filter((s) => s.id === id)
    const b = (n) => g.filter((s) => s.bucket === n)
    console.log(`===== ${id}  合计 ${g.length}`)
    console.log(`   写入点 ${b('write').length} · 计数 ${b('count').length} · 按 id 取 ${b('byid').length} · 列表取 ${b('list').length}`)
    for (const s of b('list')) {
        console.log(`     ${s.filtered ? '过滤了 ' : '★未过滤'}  ${s.file}:${s.line}`)
    }
}
console.log()
console.log('===== 内嵌关系读(.from() 计数一处都看不见的那一群)')
for (const t of ['materials', 'suppliers', 'customers']) {
    const g = embeds.filter((e) => e.table === t)
    console.log(`   ${t}: ${g.length}`)
    if (process.env.EMBEDS) for (const e of g) console.log(`       ${e.file}:${e.line}`)
}
console.log()

// 违规判据:一处**列表取**没有过滤 deleted_at,就是一条要人去看的线索。
// ★ 它【不是】自动的"有缺陷" —— 是不是选择点由人读定(见抬头的瞄准线)。
if (process.env.DUMP) {
    for (const s of sites) {
        if (s.file.includes(process.env.DUMP)) {
            console.log('--- DUMP', s.file + ':' + s.line, s.id, s.bucket, 'filtered=' + s.filtered)
            console.log(JSON.stringify(s.chain))
        }
    }
}
const unfiltered = sites.filter((s) => s.bucket === 'list' && !s.filtered)
console.log(`===== 列表取而未过滤 deleted_at:${unfiltered.length} 处`)
for (const s of unfiltered) console.log(`   ${s.file}:${s.line}  (${s.id})`)
process.exit(unfiltered.length > 0 ? 1 : 0)
```

**配套的致盲跑法** —— `blind2.py`(find/replace 走 stdin 上的 JSON,不经过 shell 引用):

```python
#!/usr/bin/env python3
# blind2.py <file> <label> [cwd] — find/replace pairs read from stdin as JSON [[find,repl],...]
# 命中 0 处 = NOOP:什么都没删掉,因此什么都没证明。跑完逐字节还原并校验。
import json, subprocess, sys, os
f, label = sys.argv[1], sys.argv[2]
cwd = sys.argv[3] if len(sys.argv) > 3 else os.path.dirname(f)
pairs = json.load(sys.stdin)
orig = open(f, encoding='utf-8').read()
cur, total = orig, 0
for find, repl in pairs:
    n = cur.count(find)
    total += n
    if n == 0:
        print(f"NOOP|{label}|找不到:{find[:70]!r} —— **什么都没删掉,因此什么都没证明**")
        sys.exit(0)
    cur = cur.replace(find, repl)
open(f, 'w', encoding='utf-8').write(cur)
try:
    p = subprocess.run(['node', f], capture_output=True, text=True, cwd=cwd)
    own, out = p.returncode, p.stdout + p.stderr
finally:
    open(f, 'w', encoding='utf-8').write(orig)
    assert open(f, encoding='utf-8').read() == orig, "RESTORE FAILED"
first = next((l for l in out.split('\n') if '覆盖断言失败' in l or l.startswith('✗')), '')
if not first:
    first = next((l for l in out.split('\n') if l.strip()), '')
print(f"OWN_EXIT={own}|{label}|命中 {total} 处|{first.strip()[:150]}")
```

★ **`cwd` 那个参数是必要的**:对照格跑 `delcount.mjs` 时第一次回来 exit 1,
查下去是工作目录不对导致的崩溃(那支脚本用相对路径 `app` / `lib`),**不是判词**。
一个崩溃的退出码与一个判定的退出码在屏幕上分不开 —— 所以要么把 `cwd` 给对,
要么把输出读一遍。**本刀两件都做了。**
