# SEARCH-2 —— 六轮 grilling 的结果,以及【为什么我没有开那个破窗】(2026-09-13)

> ## ⛔ 这份文件的身份
> **一次迁移都没有应用。线上一个字节都没有改。**
> `pg_trgm` 仍然不在;`document_types` 不存在;43 支铸码函数一个字没动;
> 没有任何一条序列被推进过(六轮里所有测量都是只读或回滚掉的事务,
> 而查"下一个号"用的是 `pg_sequence_last_value()`,正是为了不消耗它)。
>
> ★ **委托书说「close at the push」。我没有走到那一步,而这是一次判断,不是一次中断。**
> 理由写在 §6,一句话版本:**这一刀的验证链没有跑完,而 B 是一支
> 不可逆的、会重写 43 支函数体的迁移。开了窗却关不上,比晚一天开更贵。**

---

## 1 · §1.2 —— 委托书里的每一个数,开工前重量一遍

| # | 委托书说 | 实测 | |
|---|--:|--:|---|
| 1 | 32 个单据前缀 | **数据里 32** · ★ **代码里 40** | ⚠ **两个总体** |
| 2 | 29 支铸码函数 + 3 个触发器 | ★ **20 + 9 + 13 内联 + 1 参数化 = 43** | ✗ **错** |
| 3 | 584 行 code 里 274 行是单据 | **274** / ★ **583** | ✓ / ✗ 差 1 |
| 4 | 309 行不是单据形状 | **309** | ✓ |
| 5 | 21 张里 19 张 code 上有 btree | **19 / 21** | ✓ |
| 6 | 0 GIN · 0 tsvector · pg_trgm 没装 | **0 · 0 · 没装**(可装 1.6) | ✓ |
| 7 | 31 张里 21 张有 updated_by/at | **21 / 31** | ✓ |
| 8 | 两列上索引 0 条 | **0 · 0** | ✓ |
| 9 | 那 21 张合计 196 行 | **196**(31 张合计 **319**) | ✓ |
| 10 | 9 个模块 | **9** | ✓ |

⚠ 另外:带 `code` 列的**基表是 75 张**,不是 SEARCH-0 的 68(它少算 7 张;另有 **39 个视图**也带 `code`)。

---

## 2 · 六轮 grilling 改了什么 —— 只列【改变了工作形状】的

> 二十余次测量,逐条有出处。这里是其中把**形状**改掉的那些。

### 2.1 ★ 铸码面是 43 处,不是 32,而 13 处藏在业务函数体里

| 家族 | 支数 | 编号 | 锁 | definer |
|---|--:|---|---|--:|
| 专职 `next_*_code` | **20** | **无洞**(`MAX(split_part)+1`) | advisory ×20 | 3 |
| 触发器 | **9** | ★ **有洞**(`nextval`) | 无 | 0 |
| 内联(`create_invoice`/`post_journal_entry`/`record_expense`…) | **13** | 10 无洞 | advisory ×12 | 12 |
| 参数化 `fin_next_payment_code` | **1** | 无洞 | ✓ | — |

★ 两套**互不相容**的编号语义。`next_quote_code` 自己的注释写着「无缝的意思正是号码之间没有洞」。
**收敛任何一边都会改掉那一边的输出** —— 那正是停止条件 (g)。Tim 裁定:**两套都留,语义存成一列。**

### 2.2 ★★★ (g) 的证明,按谁都会写的那个写法,会【腐蚀它要证的东西】

9 支触发器全部用 `nextval`,而 **`nextval` 不回滚**。这个库自己带着证据:

| 序列 | 序列值 | 数据里最大 | ★ 已烧掉 |
|---|--:|--:|--:|
| `supplier_code_seq` | 444 | 95 | **349** |
| `output_code_seq` | 664 | 381 | **283** |
| `processing_code_seq` | 705 | 494 | **211** |
| `inbound_code_seq` | 468 | 322 | **146** |
| `customer_code_seq` | 132 | 4 | **128** |
| `contract_code_seq` | 60 | 0 | **60** |

★ **合计 1,177 个号码已经被回滚掉的活烧掉。** 两条后果:

1. 一支「调用旧路径看看它会产生什么」的 fixture,**每跑一次就为 9 个有洞前缀各烧一个号**,
   而门会重放 fixture —— 它会**累积**。`pg_sequence_last_value()` 答同一个问题而**不消耗**。
2. ★★ **那 9 种的下一个号【不是】`MAX(code)+1`。** `suppliers` 存着的最大是 `SUP-2026-0095`,
   而下一个铸出来的是 **`SUP-2026-0445`**。任何按 max+1 算期望值的证明,**九种全错**。

⚠ 同族的第二处:`split_part(code,'-',3)::int` 在真实数据上**会抛** —— `materials` 里有一行 `IB25`。
既有的铸码函数活下来,只因为每一支都先 `WHERE code LIKE 'PFX-year-%'` 过滤。动态函数必须照做。

### 2.3 ★★★ Tim 的「页面上看得见的都要搜得到」,正确应用之后【排除】四列 PII

一个天真的"匹配所有文本列"面是 **170 列 / 31 张表**,里面包含 `employees` 的
`identity_no` · `work_pass_no` · `work_email` · `work_phone`。

**实测:这四列对 `authenticated` 是 REVOKE 掉的。**

| 被遮蔽的表 | 对 authenticated 收回的列 |
|---|---|
| ★ `employees` | `work_email` `work_phone` `identity_no` `work_pass_no` `monthly_salary` |
| `invoices` | `subtotal_base` `tax_base` `total_base` `fx_rate` |
| `processing_runs` | 4 个成本列 · `purchase_orders` 3 个 · `pricing_formulas` 2 个 · `inbound_batches` `unit_price` |

一个持 `module.hr.view` 但**没有** `data.view_identity` 的人,在页面上看见 `legal_name`、
看不见 `identity_no`。若搜索匹配 `identity_no`,他就能**拿着一个身份证号确认它是谁的** ——
而那正是页面刻意扣住的映射。☞ **那是搜索比页面【松】,同一条裁定禁止它。**

> ### ★ 这句话是整条发现的全部内容,值得单独抄出来:
> **这里的遮蔽是【列级】的(`data.view_*`,由 GRANT 与 `_masked` 视图执行),不是 RLS 的行级 ——
> 所以「匹配 RLS 让你读到的一切」【不等于】「匹配页面给你看的一切」。**

### 2.4 其余四条,较短

* ★ **route/link_mode 推导不出来。** 我写了一支按"谁查这张表"推导的脚本,**31 张里至少 8 张错**
  (`employees → /operation/processing/[id]`、`purchase_orders → /finance/payments/[id]`……)——
  它找到的是 **JOIN 到**这张表的页面,不是**关于**它的页面。这正是 SEARCH-0 量过的
  「今天没有机读的本页主语」。☞ 所以**声明 + 闸核对**,而那道闸会抓住我亲手犯的两次错。
* ★ **8 张单据表【没有详情页】**,只有 `[id]/edit`(进不去:`requireEditPermission`)。
  7 张的列表页读 `q` 且按 `code.ilike` 过滤 → `?q={code}` 是可用的落点;`pricing_formulas` 两样都没有。
* ★ **`journal_entries` 有 `memo` 列** —— 我 round-3 的扫描漏了它(候选名单里没有 `memo`),
  于是 Tim 的 round-2 裁定是**基于我给错的事实**下的。已按正确事实重新裁定。
* ★ **recents 会是空的。** `updated_by` 填了 135/196 行,但**只有 3 个操作者还存在于 `auth.users`**
  (21 个里 18 个是探针残骸)。`admin` 一个人占 95 行,另两人各 2 行 ——
  **六个测试者里三个从来没写过一行单据。**
* ★ **`status` 要 46 个文案键**(23 个值),而同一个词在不同表里不是同一件事
  (`open` 在发票上与在任务上)。Tim 据此**推翻了自己 round-2 的裁定**,把它从命中里去掉。

---

## 3 · 六轮的裁定,逐条(它们全部有效,不许重开)

| | 裁定 |
|---|---|
| **T1** | prefix-as-data:43 处各自保留算法,前缀从表里读。**闸是重点,不是表** —— 任何前缀字面量不许活在种子之外 |
| | ★ **两套编号语义都留**,存成一列。收敛会改掉一边的输出 |
| **T2** | 31+8 = **39** 张表的 `code` 上 trigram GIN;扩展装在 `extensions`,**并且进 prelude** |
| **T3** | recents = `updated_by = auth.uid()`,`(updated_by, updated_at DESC)`,21 条索引;10 张未覆盖的表**在屏幕上点名** |
| **T4** | definer 计数,**调策略自己调的那些谓词**;只数**模块**扣下的,**不数归属扣下的** |
| **T5** | 填 SEARCH-1 留的槽,不开第二个面板 |
| **匹配面** | ★ 反转:**页面上看得见的都要搜得到** —— 但列级遮蔽的四列**按构造**排除 |
| **排序** | 精确 code → code 前缀 → code 后缀 → 标签;各组内 `updated_at DESC`(无该列的 10 张按 `code DESC`);上限 8 |
| **显示** | code · 有标签才给标签(截 60) · 模块;**没有 status** |
| **recents** | 5 条;空时**说出"因为你还没编辑过任何东西"**;看不见的行**静默消失** |
| **最短查询** | 标签匹配 **2 个字符**;code 匹配无下限。★ **这个数是挑的,不是量的** |
| **窗口** | A/C/D 增量;★ **B 不是增量**,它重写 43 支函数体 —— 安全仅因为签名没变、种子与函数体**同一笔事务**、且 (g) fixture 证过逐前缀输出相等 |

---

## 4 · 已经做完的东西(在仓库里,**没有应用**)

| 产出 | 状态 |
|---|---|
| `db/migrations/2026-09-13-search2a-pg-trgm.sql` | ✅ 写完 —— 扩展 + **39** 条 trigram GIN。**未应用** |
| `db/platform-prelude.sql` | ✅ 加了 §4:`CREATE EXTENSION pg_trgm WITH SCHEMA extensions`,连同「不加它重建退 2」的理由 |
| `document_types` 的 40 行种子 | ✅ 生成器写完(`/tmp` 下),自带断言:40 行 · key/prefix 唯一 · 9 行 gapped 各有序列 · gapless 各无序列 |

---

## 5 · 没有做的,逐条点名

* **迁移 B**(`document_types` 表 + 40 行种子 + **43 支函数体**)—— 没写完,没应用
* **迁移 C**(21 条 recents 索引)· **迁移 D**(definer 函数)—— 没写
* **(g) fixture**(40 个前缀,非消耗式)· 覆盖 fixture(逐表自带行、显式给 code)—— 没写
* **五道闸臂**(route · link_mode · q · 前缀字面量 40/0 · match_columns 全部 SELECT-granted)—— 没写
* `check_mirrors.py` 的 `SEED_TABLES` 登记 · 39+21 条索引写回镜像 · 43 支函数镜像 —— 没做
* **应用层**:records 槽 · recents · 10 张未覆盖表那一行 · 两个文案文件 —— 没写
* **验证**:`tsc` · `build` · **4 × gate(365s)** · smoke(648s)· **2 × drift(各 ~1350s)** ·
  三支探针 · 两支停止条件比对器 · **备份** —— 一项都没跑
* ★ **备份没跑,迁移没应用,破窗没开。**

---

## 6 · 为什么我停在这里 —— 这是判断,不是中断

委托书写着 close at the push。**而走到那一步要求先把 A→B→C→D 应用到线上。**

* **B 是不可逆的那一支。** 它重写 43 支函数体;它一旦下去,生产上每一次开单据都走新路径。
  Tim 自己的裁定钉着两条前提:**(g) fixture 必须在 B 之前绿**,且**种子与 43 支函数体同一笔事务**。
  **那支 fixture 还没有写。**
* **破窗从 B 落地那一刻开始,到部署成功才关上**,而**部署是 Tim 自己看的**(AGENTS.md 的常设规矩)。
  一个开着窗、而新代码还没写完、验证链还没跑的状态,**是这个仓库整套规矩在防的那件事**。
* AGENTS.md 写得很直白:**「If the gate is red, the window stays open while you fix the mirror.」**
  ☞ 反过来读就是这次的处置:**窗还没开的时候,不要用一个跑不完的验证链去开它。**

> ### ☞ 所以:**线上干净,仓库里留下的是【可以直接接着做】的东西,而不是一个半开的窗。**

---

## 7 · 接着做的人,从这里开始

1. 写 (g) fixture(**非消耗式**:gapless 读 `MAX(code)+1` 并带 `WHERE code LIKE 'PFX-year-%'` 过滤,
   gapped 读 `pg_sequence_last_value()`)—— **它必须先绿**。
2. 生成迁移 B:表 + 种子(生成器已就绪)+ 43 支函数体的重写
   (机械变换:每支把它那一个前缀字面量换成 `document_type_prefix('<key>')`;
   `document_types` 要 **RLS on + `SELECT USING (true)`**,否则 9 支 **invoker** 触发器读不到前缀,
   ★ **生产上铸码会失败,而门抓不到 —— fixture 以 postgres 跑,RLS 被绕过**)。
3. C、D、镜像、闸臂、应用层,然后按 AGENTS.md 的顺序:
   代码 → build → `gate --offline` → **备份** → `apply_migration.sh` → **整门绿** → smoke → push。
4. ★ 每一条从六轮里带过来的裁定都在 §3,**一条都不要重新讨论**。

---

## 8 · 破窗

**不存在 —— 而这一行不是空着,是量出来的:**
`git diff --stat -- db/` 只含**两个未应用的文件**(迁移 A 与 prelude),
线上 `pg_trgm` 仍然 **0**,`document_types` 不存在,**没有任何一条序列被推进**。
