# ALERT-2c 第二轮交回 —— 量完了,两道门装上了,六条死词条删了

**日期:** 2026-09-08 · **不带版本号,不写发布说明**(委托书 §8)

---

## 1 · 起止与树的状态

| | |
|---|---|
| 开工前 HEAD | `b4c7c3fff8da74e6fbc6b0d64e0b6a1c899a2266` |
| 开工前 `origin/main` | `b4c7c3fff8da74e6fbc6b0d64e0b6a1c899a2266` —— **相等** |
| 开工前 `git status` | **干净**(零条) |
| 工作提交 | `e04feec` —— PIECE 3 / 4 / 1 的全部改动都在这一次里 |
| 交回时 HEAD | 本行由紧跟其后的一次【只改这一行】的订正提交写入(自指的哈希写不进它自己) |

委托书给的期望值 `b4c7c3f` **实测正确**。它和这一刀里其他每一个数字一样被量过,
没有被当成前提。

---

## 2 · PIECE 4 —— 六条(不是五条)孤儿词条

### 删掉的六条

| # | 键 | en | zh |
|---|---|---|---|
| ① | `suppliers.deleteConfirm` | 1355 | 1365 |
| ② | `customers.deleteConfirm` | 1949 | 1945 |
| ③ | `materials.deleteConfirm` | 2090 | 2085 |
| ④ | `inbound.deleteConfirm` | 2383 | 2377 |
| ⑤ | `output.deleteConfirm` | 2532 | 2526 |
| ⑥ | `tasks.deleteConfirm` | 5430 | 5379 |

(行号是删除前的。六条 × 两种语言 = 12 行。)

### ★ 五 vs 六 —— 这是一条【发现】,不是一次凑整

委托书写的是五条。**实测是六条**,而且第六条不是可有可无的边角:
六条全都带着那句已经被证伪的「可以恢复 / Soft delete: data is kept and recoverable」。

**更要紧的是它们并非同一种死法:**

* **四条**(`suppliers` / `customers` / `materials` / `inbound`)确实是委托书描述的
  「只被注释引用」—— 每一条在 `DeleteButton.tsx` 里都留着一行
  「CONFIRM-1:原来走的是原生确认框,消息键 xxx.deleteConfirm」。
* **两条**(`output` / `tasks`)**一个引用都没有,连注释都没有。**
  它们不是"被困在注释里的陷阱",它们是**彻底的死物**。
  ☞ 这是比另外四条**更强**的删除理由,不是更弱。

**这是本族第七次「交下来的数偏低」。** 前六次:10→74 · 17→190 · 0→1 ·
228→311 · 2→3 · 13→(见 PIECE 1)。**七次全部偏低,一次都没有偏高。**
而这一次偏低发生在**专门为"先量准再动"而切出来的这一刀里**,量的还是它
四个部件中最小的那一个。

### 两条断言,分开说 —— 它们证的不是同一件事(R2)

> **断言 A(grep):这六条渲染在任何地方。**
> 全仓库对 `t('<键>')` 的调用点:六条各 **0 处**。
> 唯一一条剩余文本命中是 `scripts/check-confirm-subject.mjs:9` 的一行**注释**
> (它拿 `materials.deleteConfirm` 当"整句式主语"的反面教材)。注释不渲染。

> **断言 B(build):删掉它们能编译。**
> `npm run build` 自己的退出码 **0**。
> **这条断言【只】说明删除不破坏编译,它对"有没有人在用"一个字都没说。**

**为什么必须分开写:** `scripts/check-i18n.mjs` **没有任何"未引用键"检查**
(实测:全脚本无 unused/orphan 判据),`package.json` 的 build 链里也没有别的闸做这件事。
所以一次绿色的 build **不可能**证明这六条没人用。
把两句话并成一句"build 证明它们没人引用",就是让一条证不了的断言借另一条的光 ——
而这正是本仓库反复付账的那一种句子。

### ★ 活着的同名兄弟(R2 c)—— **结构上证了,界面上没走**

`suppliers.deleteConfirmTitle` / `customers.deleteConfirmTitle` /
`materials.deleteConfirmTitle` / `inbound.deleteConfirmTitle` /
`output.deleteConfirmTitle` 五条**都还在**,调用点也都还在
(`app/suppliers/DeleteButton.tsx:24` 等),build 绿。
另有 `materials.attachments.deleteConfirm` 一族**同名但不同键**,未被波及。

> ⚠️ **委托书内部有一处冲突,我按 §3 判的。** R2(c) 要求「走一个用活兄弟键的页面,
> 确认真对话框还说得出话」;§3 又禁止任何浏览器/自动化。**两条不能同时满足。**
> 我照 §3 办:**这一条是结构上证的(键在、调用点在、build 绿),不是走出来的。**
> 若你要那次真走查,它和下面两道门的走查是同一趟,一起做最省事。

---

## 3 · PIECE 3 —— 两道门装上了(**都没有被走过**)

两处今天都是**裸硬删**:
`output_batch_safety_states.delete()`(`safetyActions.ts:36`)与
`quote_lines.delete()`(`app/sales/quotes/actions.ts:114`)——
没有理由、没有墓碑、没有回头路。ALERT-2a 已经把**牌子**写对了
(`removeLine: 'remove' → 'Delete'`,`safety.remove → 'Delete {name}'`,都在 `messages/*`,
两个 `.tsx` 一个字没动)。**这一刀补的是【门】,不是牌子。**

### (a) 安全状态 —— `app/output/[id]/edit/SafetyStatePanel.tsx`

照 R4:**在 map 里分叉**。持有该状态(「删除{name}」那一边)走 `<ConfirmButton>`;
未持有(「记上{name}」那一边)保持素 `<button>`。
**只有破坏的那个方向有门。** 两边都弹框,是在教人把对话框当过场 ——
那正是一个确认框失效的方式。

| 格 | en | zh |
|---|---|---|
| 主语 `subject` | 那条安全状态的名字(如 `Wet`) | 同(`name_zh`) |
| 标题 | `Delete this safety state?` | `确定删除这条安全状态吗?` |
| 正文 `body` | `common.hardDeleteNote`(ALERT-2a 原话,未改) | 同 |
| 后果 `details` | *A safety state is the record that somebody looked at this batch. Deleting it does not mean the batch is safe — it means nobody has looked, and the batch cannot be fed into any operation until someone records one again.* | *安全状态记的是【有人看过这批料】。删掉它不等于这批料安全 —— 它等于【没有人看过】,而在有人重新记上之前,这批料投不进任何工序。* |
| 确认钮 | `common.delete` = `Delete` | `删除` |

主语安全性**逐消费者**查过(CONFIRM-1 的判据):`SafetyStatePanel` 全仓库
**只有一个消费者**(`app/output/[id]/edit/page.tsx:456`),而那个名字就印在同一屏
上方那排徽章里,不走 `MaskedValue`。

### (b) 报价明细行 —— `app/sales/quotes/[id]/QuoteLinesEditor.tsx`

| 格 | en | zh |
|---|---|---|
| 主语 `subject` | `` `#${l.line_no} · ${l.material}` `` → 如 `#2 · CU-01 — Copper cathode` | 同(物料串本身双语共用) |
| 标题 | `Delete this quotation line?` | `确定删除这一行报价明细吗?` |
| 正文 `body` | `common.hardDeleteNote` | 同 |
| 确认钮 | `Delete` | `删除` |

**金额刻意不进主语** —— 与 `CostPanel` 同一条理由。
本组件唯一消费者是 `app/sales/quotes/[id]/page.tsx:147`,页内**没有一处 `MaskedValue`**,
行号与物料两列对每个读得到这一页的人都可见。

**没有动 `editable = canEdit && !isConverted && !isDeclined`**(R3)。

### ★★ 这两道门【没有被走过】,而这笔账记在你名下

照 §3,不装浏览器、不装任何自动化。所以:

> **可以说的:两道门【接上了】** —— `<ConfirmButton>` 已就位,
> `scripts/check-confirm-subject.mjs` 自己的退出码 0(58 处主语 / 57 个 JSX 开标签,
> 较改动前的 56/55 恰好 +2/+2,与本刀新增的两处一一对上),`npm run build` 退出码 0。
> **不可以说的:它们被打开过、被取消过。没有。**

**欠你的那两下,点这里:**

1. **安全状态**:`/output/<任一自产批次>/edit` → 下拉到「安全状态」那一块 →
   点一个**已经记上的**状态(钮上写「删除 XXX」)→ 对话框应当弹出、
   焦点落在【取消】上 → 按 Esc 或点【取消】→ **那条状态应当原封不动还在。**
2. **报价明细**:`/sales/quotes/<任一未转换、未谢绝的报价>` → 明细表任一行右侧
   【删除】→ 对话框应当弹出、主语那一格写着 `#行号 · 物料` →
   【取消】→ **那一行应当原封不动还在。**

---

## 4 · PIECE 1 —— 四个数,每个都带着它是怎么量出来的

**工具:`scripts/survey-conflated-booleans.mjs`**(本刀新增,**没有**进 build 链 ——
委托书禁止新增闸;它与 `survey-hidden-exits` / `survey-native-dialogs` 同类,手工跑)。

### 四个数

| 桶 | 含义 | 数 | 在 PIECE 2 范围内? |
|---|---|---:|---|
| ① | **权限 × 记录状态** | **6** | ✅ 拆成两个 prop |
| ② | 纯记录状态 | 31 | ❌ |
| ③ | 纯权限 | 2 | ❌(这正是 `PermissionGate` 该挂的形状) |
| ④ | **还掺着第三种东西** | **33** | ✅ 在范围内,**但两个 prop 的改法不适用** |

**分母:** 磁盘上 `app/**` 的 `.ts/.tsx` **877 个**,解析 **877 个**(相等,是一条断言);
整条布尔链(`&&` 与 `||`)**1554 条**,其中落在**控件闸位**上的 **256 条**。

### 桶 ① 的六处 —— 逐处点名

| # | 站点 | 那条布尔 |
|---|---|---|
| 1 | `app/finance/assets/[id]/DowntimePanel.tsx:113` | `canEdit && !openRow` |
| 2 | `app/hr/reviews/ReviewActions.tsx:109` | `canHrEdit && status !== 'void'` |
| 3 | `app/hr/reviews/[id]/page.tsx:183` | `canEditGoals={canWrite && r.status === 'draft'}` ← **委托书点名的旗舰站点** |
| 4 | `app/operation/orders/[id]/page.tsx:101` | `canEdit && ['draft','released'].includes(wo.status)` |
| 5 | `app/sales/quotes/[id]/page.tsx:81` | `editable = canEdit && !isConverted && !isDeclined` |
| 6 | `app/sales/quotes/[id]/page.tsx:195` | `canIssue={canEdit && !isConverted && !isDeclined}` |

**六处全部手工对着源码核过一遍**,每一个操作数的绑定都读了。

☞ 5 与 6 是**同一条表达式写了两遍**,`QuoteLinesEditor` 的删除钮就挂在 5 上(R3)。
   而这一处**今天说的话是对的** —— 页面另外传了一个 `reason` prop,
   分别指出「转过了 / 谢绝了 / 没有 module.sales.edit」三种情形。
   **布尔是混的,可屏幕上那句话是分开的。** PIECE 2 动它的时候别把这一点弄丢。

### ★ 交叉核对 —— 它必须【失败得不一样】

| | 主 pass | 交叉核对 |
|---|---|---|
| 怎么找链 | TypeScript **AST**,整条合取/析取式求值 | **不建 AST**:剥掉注释与字符串后在**全文**上括号配平 |
| 怎么判权限 | **出处**(污点传播:`can()` → 赋值 → 跨 prop),外加**真类型检查器** | **命名约定**(`can*`/`may*`/`allowed`/权限码字面量) |
| 它的失败方式 | 跟丢一次 prop 传递 | 一个名字起得不像权限的布尔 |

**两条路都不是行式的。** 委托书点名的 311/470 陷阱正是行式工具撞的
(一条跨行的合取式,行式工具看见两个半截);这里两条路都在**全文/整树**上走。

**结果:** 交叉核对命中 **80** 个文件,AST 命中 **27** 个。
**只有交叉核对看见的 56 个,只有 AST 看见的 3 个** —— **双向都有差额**,
这正是"失败方式不同"应有的样子(单向差额说明其中一条只是另一条的子集)。

56 个差额**抽样核过 5 个**(`moduleGuard` · `finance/assets/[id]/page.tsx` ·
`finance/gst/[periodId]` · `hr/payroll/[id]` · `inbound/[id]/edit/page.tsx`):
**没有一个藏着桶 ①/④ 的漏网站点。** 它们是交叉核对按命名过匹配的产物 ——
或者根本没有合取式,或者那条合取式挡的是**一次查询**(`canX && ids.length ? await query : []`),
而"先问权限再决定读不读"是本仓库明文规定的**正确**写法
(`app/hr/payroll/page.tsx:50` 那段注释逐字写着),不是缺陷。

### ★★ 故障注入 —— 覆盖率断言自己会不会红

| 注入格 | 弄瞎的是 | 脚本**自己的**退出码 | 咬到了吗 |
|---|---|:--:|---|
| `--inject=blind-parser` | 把 `.tsx` 按 JSON 解析(树在,里面空的) | **1** | ✓ 「类型检查器一个 boolean 都没认出来」+「AST 一个权限文件都没命中」 |
| `--inject=blind-taint` | 拿掉污点的**种子**(`can()` 不再算权限) | **1** | ✓ 「污点传播一个权限绑定都没找到 —— 种子瞎了,不是仓库里没有权限」 |
| 干净跑 | — | **0** | ✓ |

> 退出码是**脚本自己写进日志**的(`OWN_EXIT=$?` 紧跟在命令后面),
> 不是从管道尾巴上读的 —— 一条 `| tail` 会把 `$?` 换成 `tail` 的退出码,
> 而那会让两次注入看起来都"没红"。**第一次量的时候正是这么错的。**

### ★★★ 这个 13 最后是 6 —— 而它【不是】"比交下来的低"

委托书写着「若你的数落在交下来的数字上或之下,**明说**,并说你做了什么去测同一个盲点」。
照办,而且这一条要说清楚,因为它容易被读反:

**旧的 13 和新的 6 不是同一个量。** 旧判据数的是"文本上像 `perm && …state…` 的行";
新判据数的是**四个互斥的桶**,而旧的 13 里混着今天的桶 ①、桶 ④、以及一批**查询守卫**
(那些根本不是缺陷)。**可比的量是「在范围内的总数」:①6 + ④33 = 39,对旧的 13 —— 高出两倍。**
其中 **33 处**是旧正则**结构上不可能看见**的:它跨不过第二个 `&&`,也完全看不见 `||`。

**我做了什么去测同一个盲点(而它抓到了四次真漏):**

1. **`&&` 之外还量 `||`。** `disabled={pending || !canFinance || !date}` 按德摩根
   等价于 `enabled = !pending && canFinance && date` —— **同一个缺陷的反极性写法**。
   头一版只认 `&&`,`ClaimControls.tsx:69` 整条溜过去。
2. **【藏】也是闸。** `if (!showProbation && !canPay) return null`(`HrDecisionForm.tsx:62`)
   —— 按 DBLOCK-1 的裁定这是最坏的一种,而头一版只看 JSX 属性,看不见 return。
3. **解构也是绑定。** `const [canHrEdit, canPay] = await Promise.all([can('module.hr.edit'), …])`
   是本仓库取权限的**主要写法**;头一版只认 `ts.isIdentifier(n.name)`,于是
   `canHrEdit` 从来没被污染,**委托书点名的旗舰站点 `canEditGoals={canWrite && r.status==='draft'}`
   从我自己的 AST 底下溜了过去** —— 与它要抓的缺陷是同一个形状的漏抓。
   **是交叉核对把它顶出来的**,这正是"两条路必须失败得不一样"要买的东西。
4. **污点不许顺着不是布尔的东西爬。** 实测污点链:
   `canSeeFinance`(真权限)→ `invLines`(一批发票行)→ `liveInvoices` → `invCodeById`
   → `code` → `o` → `<AmendOrderForm status={o.status}>` → 于是
   `!isDraft && !addOnly && status !== 'confirmed' && …` 这**四条纯记录状态**的布尔
   整条进了桶 ①。两条错同一个根:一是**受权限影响的数据**不等于**一个权限答复**;
   二是 `order as unknown as { id: string; code: string; … }` 里的 `code` 是
   **类型注解上的属性名**,文本扫标识符分不出它和一次值引用。
   药是**真的类型检查器**(只让污点在 `boolean` 之间传),不是又一条正则。

**而第 4 条差点白做:** 头一版把 `program` 的 checker 拿去问**另一次
`ts.createSourceFile` 造出来的节点** —— **检查器不认识别人家的节点**,
325 次询问答出 **0** 个 boolean,污点传播被整条掐断(轮数=1),
**报告照样打印,数字照样好看。**
是那条新加的「类型检查器自己也要被证明是活的」断言把它顶出来的。
☞ 现在这条断言留在脚本里:`145 / 436 次询问`认出 boolean,**既不是 0 也不是全部**。
   本仓库那条「覆盖率本身必须是一条断言」,这一刀自己付了一次学费。

---

## 5 · 桶 ④ 的 33 处 —— 为什么"两个 prop"救不了它们

**第三种东西 = 既不是权限,也不是记录状态。** 给它写一句权限的话是假话,
写一句状态的话也是假话 —— **它要的根本不是一句拒绝。**

### (a) 「表单还没展开」—— 15 处

`canEdit && !open` · `canEdit && editing === null` · `canEdit && form === null` ·
`on && canEditGoals` ……

> `app/finance/cash-forecast/RecurringLines.tsx:67,72` ·
> `app/sales/customers/ChasePanel.tsx:136,142` ·
> `app/sales/customers/ContactsPanel.tsx:138,144` ·
> `app/finance/assets/[id]/MaintenancePanel.tsx:240` ·
> `app/finance/assets/[id]/ServiceIntervalPanel.tsx:312` ·
> `app/purchasing/licences/LicencePanel.tsx:114` ·
> `app/finance/assets/[id]/DowntimePanel.tsx:176` ·
> `app/hr/reviews/GoalsEditor.tsx:150,161,173,185,200`

**为什么两个 prop 不适用:** `open` / `editing` 是**这一次会话里的开合状态**,
不是记录的状态,也不该被写成一句"你不能……"。
这里真正的缺陷是**另一件事**:`canEdit` 为假时整个控件**不渲染**(藏),
而 DBLOCK-1 已经裁定"显示 + 解释"。
☞ **它们要的是 `<PermissionGate>` 包住控件、`open`/`editing` 照旧管开合** ——
  一个权限闸加一个开合条件,**不是把一个布尔拆成两个**。

### (b) 「瞬态 / 正在提交」混进权限 —— 8 处

`pending || !canEdit` · `isPending || blocked` · `!canEdit || isPending` ·
`pending || !canFinance || !date` ……

> `app/finance/assets/AssetActions.tsx:82` · `app/components/IssuePanel.tsx:101` ·
> `app/materials/[id]/edit/RequiredMetalsPanel.tsx:84` ·
> `app/hr/claims/[id]/ClaimControls.tsx:69` ·
> `app/hr/kpi/score/GenerateMissing.tsx:53` ·
> `app/purchasing/orders/[id]/RetentionPanel.tsx:161` ·
> `app/components/IssuePanel.tsx:63` · `app/finance/invoices/[id]/page.tsx:204`

**为什么两个 prop 不适用:** `isPending` 一秒后自己消失,而"没有权限"不会
(CMP-2 的房规原话:非瞬态条件才需要一行常驻的解释)。
把瞬态和权限拆成两个 prop,等于要求界面为一个**会自己好的**状态写一句拒绝。
☞ 它们要的是**权限那一半上闸(`PermissionGate`),瞬态那一半留在 `disabled` 里**。

### (c) 「还没选 / 还没有东西可操作」—— 10 处

> `app/hr/kpi/score/page.tsx:148` —— `mayScore && !!chosen && !locked && chosen.status !== 'closed'`
> `app/tools/reminders/page.tsx:188,335` · `app/inbound/[id]/assays/[assayId]/page.tsx:340` ·
> `app/sales/customers/StatementPanel.tsx:150` · `app/tools/tasks/[id]/Participants.tsx:112` ·
> `app/tools/tasks/[id]/page.tsx:98` · `app/hr/reviews/ReviewActions.tsx:85` ·
> `app/hr/reviews/HrDecisionForm.tsx:62` · `app/inbound/[id]/edit/SourceReasonPanel.tsx:117`

**★ 这一族里 `hr/kpi/score/page.tsx:148` 就是委托书点名的那一处。**
`!!chosen` 的意思是**「你还没选月份」**。
**给"还没选月份"写一句权限的话或一句状态的话,两句都是假话** ——
屏幕上该出现的是**空态**(「先在上面选一个月份」),不是一句拒绝。
☞ 所以它要的是**三分**,不是二分:权限 → `PermissionGate`;记录状态 → 状态那句话;
  **"还没选" → 空态**。`SourceReasonPanel:117` 同理,它的 `!showForm` 里
  同时裹着权限、状态、和一个 `useState` 开合位,**一个操作数里就有三类**。

---

## 6 · 找到了、按 R7 没有动的(留给 ALERT-2b)

| 文件:行 | 长什么样 |
|---|---|
| `app/output/[id]/edit/SafetyStatePanel.tsx:54` | 裸琥珀 `bg-amber-50 border-amber-300 text-amber-800`(「一条都没记」那句) |
| `app/output/[id]/edit/SafetyStatePanel.tsx:65` | 徽章上的裸红 `bg-red-100 text-red-800 border-red-300`(「不可投料」) |
| `app/output/[id]/edit/SafetyStatePanel.tsx:123` | 裸红行内错误框 `bg-red-100 border-red-400 text-red-700` |
| `app/sales/quotes/[id]/QuoteLinesEditor.tsx:56` | 同一个形状的裸红行内错误框 |

**一处都没碰,也没有采用 `Alert`。** 四处坐标已确认,ALERT-2b 直接继承,不必重找。

另外一条,**只报不改**:`scripts/check-confirm-subject.mjs:9` 的注释拿
`materials.deleteConfirm` 当反面教材,而那个键刚被本刀删掉,于是那行注释
**现在指着一个不存在的键**。没有动它 —— 委托书 §5 明令不碰任何闸。
(功能上无害:该脚本对解析不出来的键**刻意不拿它做判据**。)

---

## 7 · 我自己定的(都是细节,不是形状)

1. **普查脚本进仓库**,叫 `scripts/survey-conflated-booleans.mjs`,**不进 build 链**。
   理由:PIECE 2 必须能把这四个数**重跑一遍**;`survey-*` 是本仓库既有的
   "手工跑、不设闸"惯例。委托书禁的是**新增闸**,这不是闸。
2. **加了 `--why=` 出处追踪开关。** 那条
   `canSeeFinance → … → code → o → status` 的污点链**靠读代码猜不出来**。
   一条查不出出处的判据,不配拿来数数。
3. **安全状态对话框多了一句后果**(`removeConsequence`),用 `details` 格渲染。
   `common.hardDeleteNote` 说的是"永久、无副本";它说不出**这一条**特有的那件事 ——
   删掉的是**"有人看过"这个事实**。委托书 ★ 段整段在讲这件事,所以补上。
   永久性的措辞**仍然原样用 `hardDeleteNote`**,没有另写。
4. **那句后果用对话框自己的 token(`text-foreground`),没有画琥珀盒子。**
   本刀不碰 ALERT-2b 那 ~250 处行内色值,那就更不该往里**添**一处。
5. **「这一行是不是我的」算权限。** `isReviewer = myEmployeeId !== null &&
   r.reviewer_employee_id === myEmployeeId` 判的是关系授权 ——
   被它挡住的人不是"再等等流程",是"这件事不归你"。
   **不这样算的后果是具体的:旗舰站点 `canWrite && r.status === 'draft'`
   会从桶 ① 掉进桶 ④**,而 `DBLOCK-CONFLATED-BOOLEANS` 正是拿它当"权限×状态"的样板。
6. **`DBLOCK-CONFLATED-BOOLEANS` 一个字都没删、没改写。** 按委托书只许追加。
   本刀**没有追加** —— 四个数与桶 ④ 的分析在本文件里,而那一条要不要吸收,
   等 PIECE 2 落地时一并处置更省事(现在追加会写成一条"半截"的记录)。

---

## 8 · 没有做的

* **PIECE 2 一个字都没动**,也没有原型。桶 ①、桶 ④ 的改法只写到"它们需要什么"为止。
* 没有动 `QuoteLinesEditor` 的 `editable`。
* 没有新增任何 build 闸或 `check-i18n` 分支。
* 没有装浏览器、没有装任何自动化。
* 没有改手册、没有版本号、没有发布说明。
* **没有迁移** —— 本刀一条 SQL 都没有。

---

## 9 · 部署

| | |
|---|---|
| 提交 | `1d6973c`(工作提交 `e04feec` + 一行哈希订正) |
| 部署 id | **6330469290** |
| state | **success** |
| success 时刻 | 2026-09-08 22:57:26 CST |
| URL | `https://new-era-i6kjwk9if-tim-s-projects7.vercel.app` |

`scripts/wait-for-deploy.sh` 自己的退出码 **0**;
另用 `gh api …/deployments/6330469290/statuses` **单独复核过一次**
(`{"state":"success","created_at":"2026-09-08T14:57:26Z"}`)——
按 AGENTS.md 那条「标签念一遍、判据念一遍,是同一件事吗」,
这里的判据检查的确实是 `state=success`,不是"有没有一条记录"。

部署记录本身滞后 **213 秒**才出现,与 AGENTS.md 记的阵发滞后一致,不是异常。

**本刀没有迁移**,所以没有"破窗"那一栏的起点。

> ⚠️ 这一节所述的部署是 `1d6973c` 的。本节自己所在的这次补记提交会另有一次
> 部署,而它是**纯文档**改动 —— 上面四个数、两道门、六条词条都不受它影响。
