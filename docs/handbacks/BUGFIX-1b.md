# BUGFIX-1b · 交回报告(2026-09-12)· ★ `v1.4.18`

> ## ★ 一句话:GST 开着的时候,一笔已批准的医疗报销**终于开得出费用单**了(税码预选 BL、可改、要你点一下确认);而屏幕上那些一串大写字母的错误码与 SQL 原文,从今天起换成一句人话加一个可以报给管理员的短码。

> ### ★★ 本刀发 **`v1.4.18`** —— 它与 BUGFIX-1a 两刀合起来构成这一版。★★
> ★ **数据库改了一处**:`pay_medical_claim` 的签名(一支迁移,DROP + CREATE)。
> ★ **线上业务数据一行都没有写过** —— 所有行为都在**重建库**上证的,全程 ROLLBACK。

---

## 0 · 一页纸

| 条 | 它坏在哪 | 判词 | 本刀做了什么 |
|---|---|---|---|
| ★★ **b** 报销开不出费用单 | GST 开着时 `pay_medical_claim` 不传税码,而**员工这一侧永远解析不出默认值**(`employees` 没有 `default_tax_code`),于是 `resolve_tax_code` 抛 `TAX_CODE_REQUIRED\|supplier`、整笔事务回滚 | ★ **PROVEN(重建库四条臂)** | 函数加 `p_tax_code`(带默认值)+ 按名拒;界面加税码下拉,**预选 BL**、可改、`<ConfirmButton>` 确认;fixture 90 加一臂 K,**证过它在修法之前会红** |
| ★★ **d** 生码 / 数据库报错漏到人前面 | **45 支**「码 → 人话」的映射器都以**把生字符串原样吐出去**收尾 —— 那不是疏忽,是一条写下来的设计 | ★ **PROVEN(按形状重数)** | 新增 `lib/machine-text.ts` 一格共用兜底;**只换生码与数据库报错,人话句子一个字不动**;日历横幅 + **9 处**导出正文 + item b 那条路上的 6 支码逐处接好 |
| ⚠ **顺带查出的一条** | `refuseFromCoded` 靠「本地化器把原样那一串还回来了」分界 —— ★ **本刀让那条契约按构造失效**,后果是 ALERT-1 的 `detail` 那一格整个消失,30 个调用点全受影响 | ★ **PROVEN(读源码读出来的,不是量出来的)** | 两处都改成拿同一串再问一次兜底会说什么;**那 30 处的屏幕文字一个字都没有变**;⚠ **没有闸**,已登记 |

---

## 1 · §1 开工闸 —— 逐项

| 判据 | 读数 | 判词 |
|---|---|---|
| §1.1 `HEAD` | `b2c8d2e802678caf03ba79963f92930337b3e2ac` | ★ **等于 `origin/main`**,`git status --porcelain` **一行都没有** |
| §1.2 round 1 的六份产物 | `/tmp/BUGFIX-1-stopgate.md` · `A3-findings.md` · `A5-findings.md` · `A9-proposals.md` · `A3-probe.sql` · `A3-rebuild.log` | ★ **六份全在** |
| §1.3 读完了才开工 | 停止闸 A.3/A.5 · A9 · BUGFIX-1a 交回报告 · 队列(刀序 + 四条裁定 + 发货步骤 + 常设推送规矩)· known-issues · machine-text-reaching-humans · **GST 口径那份文档** · AGENTS.md 点名的每一节 · 四支 SQL · `ClaimControls.tsx` 与它的 server action · 映射器那一族 | ✓ |

### ★ §1.3 里那一条要自己找的:**「仓库的 GST-policy 文档」是哪一份**

★ **`docs/accounting-policies.md`(EVoltrya OS — Accounting Policy Memorandum)的 §9。**
量法:`grep -ril gst docs/` 得 20 份,逐份看**它是【政策】还是【某一刀的记录】**——
`purchase-order-gst.md` 与 `cancelled-po-and-po-gst.md` 是 **PO-GST-1 / FA-PO-1 两刀的记录**
(抬头就写着日期与刀名),而 `accounting-policies.md` 是**唯一一份自称政策备忘录、
每一条带 SETTLED / AS-BUILT / DIVERGES 标记与 enforcement point 的文档**,GST 就住在它的 §9.1/§9.1a。
☞ **本刀的裁定因此写成 §9.1b,紧挨着 §9.1a。**

---

## 2 · §1.4 —— 委托书里当作阈值用的每一个数,逐条重量

> **规矩(AGENTS.md CONFIRM-1):委托书里的数字一个都不许直接引用。**
> 下面每一行都带量法与分母。

| # | 委托书 / round 1 写的 | 本刀实测 | 判词 |
|---|---|---|---|
| 1 | **42** 支 `localize*Error` | ★ **按名字 43 支**(`git grep 'function localize[A-Za-z]*Error'`,含 2 支模块内私有的) | ★ **WRONG** |
| 2 | 其中 **41** 支「以原样返回生字符串收尾」 | ★ **按名字 40 支**(38 支 `return raw` + 2 支 `default: return message`);★★ **按【形状】重数是 45 支** | ★★ **WRONG,而差额是有意义的** —— 见下面 |
| 3 | **两条**导出路由把报错拼进 HTTP 正文 | ★ **9 处 / 8 个文件**(`Export failed: ${error.message}`) | ★★ **WRONG(低估 4.5 倍)** |
| 4 | CCY-1 的 **300 / 90 / 45** | ★ **909 / 132 / 68** | ★ **WRONG**(round 1 已判过,本刀把它**就地写进了那份文档**) |
| 5 | 「**949** 条码 × 映射器的上界」 | — | ⚠ ★ **NOT RE-MEASURED** —— 它**不是本刀任何一条判据的阈值**,所以本刀没有为它花时间。照直记。 |
| 6 | 「屏幕上真的漏出来的只有 **1** 处(141 条静态路由)」 | — | ⚠ ★ **NOT RE-MEASURED**(那一趟屏幕普查要 1977 秒,而本刀不靠它做任何判断) |
| 7 | 静态路由 **141** | ★ **本刀的冒烟跑了 **229 条路由 + 25 项探针**;★ **那不是 141 的更正** —— 141 是 round 1 那支【文本探针】自己那张静态路由 glob 的分母,两支量具的口径不是同一个**(本刀的冒烟自己数的,口径 = smoke 跑过的路由) | 见 §8 |
| 8 | `db/gate.py --offline` **~44s** | ★ **45 秒** | 见 §8 |
| 9 | 备份「8 分钟,也跑过 34 分钟没完」 | ★ **411 秒** | 见 §8 |
| 10 | 整门 **652s** | ★ **202 秒(第一趟,红)· 228 秒(重跑,绿)** | ★ **WRONG(旧数偏大 3 倍)** —— 而 AGENTS.md 那张表早就写着它是「两到六分钟,带一条肥尾」,不是一个数 |

### ★★ 第 2 行值得读两遍:**那个数错在【它数的东西和它的名字对不上】**

round 1 的判据是 **`return raw` 这个写法**;要数的却是 **「兜底把生字符串送出去」这件事**。
两者差了 **5 支**,而那 5 支**一个字都不叫 `localize*Error`**:

```
localize      app/operation/processing/[id]/lossActions.ts:17
localize      app/output/[id]/edit/purposeActions.ts:16
localize      app/settings/accounts/accountActions.ts:35
localize      app/settings/accountsActions.ts:15
dictError     app/settings/dictionaries/actions.ts:142
```

★ **另有 2 支既不在 43 里、也不在 45 里,而它们照样把生码送上屏幕**:
`localizeSaleError` 与 `app/inbound/[id]/edit/pricingActions.ts` 的 `localizePricingError`
把原文**塞进一句模板**(`t('…saveError', { message: raw })`)再返回 ——
☞ **按「return raw」按构造数不到它们。** 本刀两支都接上了(生码走兜底,人话仍走那句模板)。

★ **改了量法**:判据从「叫什么名字」换成 **「一支函数,入参是一个字符串,函数体里有一句 `return <那个入参>`」**
(量具 `/tmp/bugfix1b/scan-mappers2.mjs`)。**它与名字无关,所以下一次改名也漏不掉。**
☞ 这一条写进了 `AGENTS.md` 的 CONFIRM-1 表与「一次勘察只看得见代码碰巧给它起的名字」那一节。

---

## 3 · ★ B —— 医疗报销 → 费用单,在 GST 之下

### 3.1 §4.1 逐条读过的:税码今天是怎么走的

| 问 | 答(读源码 + 重建库实测) |
|---|---|
| `record_expense` **今天**怎么收税码? | ★ **它早就收**:签名第 14 个参数 `p_tax_code text DEFAULT NULL::text`(GST-2 加的)。GST 开着时它走 §4b:`SELECT default_tax_code FROM suppliers WHERE id = p_supplier_id` → `resolve_tax_code(p_tax_code, v_sup_default, 'input', 'supplier')`。**GST 关着时传一个非空税码会被按名拒**(`GST_NOT_REGISTERED`)。 |
| `decide_expense_claim` 怎么传? | ★ 两步:① GST 开着而 `p_tax_code` 空 → **先按名拒** `EXPENSE_CLAIM_TAX_CODE_REQUIRED\|<单号>`(**有翻译**);② `p_tax_code := NULLIF(btrim(COALESCE(p_tax_code,'')), '')` 传下去。 |
| `pay_medical_claim` 本刀之前怎么传? | ★★ **它不传。** `record_expense(…, p_supplier_id := NULL, 【没有 p_tax_code】)`,而收款人写死是员工(PAYEE-1a)。☞ GST 开着 → `resolve_tax_code(NULL, NULL, …)` → `TAX_CODE_REQUIRED\|supplier` → 回滚。 |
| 那句 `\|supplier` 指对了吗? | ★ **没有。** 这条路上**根本没有供应商**,而 `employees` **没有 `default_tax_code` 这一列** —— 照那句 HINT 去做的人**一件事都做不到**。 |

### 3.2 §4.2 最小的改动,以及【破窗里旧代码走哪一支】

* ★ `pay_medical_claim` 加 **`p_tax_code text DEFAULT NULL::text`**,加在参数表**最后**。
* ★ **为什么是 DROP + CREATE**:加参数 = 换签名 = **重载**,旧签名会原样活在线上变成镜像看不见的漂移(FIN-21);`db/preflight_migration.py` 为此**拒绝**这种形状,而 DROP + CREATE 是它**唯一放行**的走法。**PAYEE-1a 在同一支函数上付过同一笔账**(`2026-08-18-payee1a-…sql:977`)。
* ★ **允许的进项税码,真源只有一处**:**`tax_codes` 里 `is_active` 且 `side = 'input'` 的那些** —— 与报销单那条路(`app/finance/claims/page.tsx:73`)**逐字同源**,也正是 `resolve_tax_code` 在服务端要验的那一份。
* ★ **`record_expense` 与 `resolve_tax_code` 一个字都没有改。** 读过了,不必改:税码的有效性(存在 / 启用 / 侧别)本来就全归后者,这里只声明一个**这条路特有的前提**。
* ★ **`decide_expense_claim` 也一个字都没有改**(Tim 的裁定:报销单那条路要一次明确的选择,不预选)。

#### ★★ 破窗里【旧代码】做什么 —— 照直说,而且它与今天【不完全一样】

旧代码那句 `rpc('pay_medical_claim', { p_claim_id, p_expense_date })` 是**按名传参**,
而新增的两个参数都有默认值,★ **所以它仍然解析得到新函数**,走 `p_tax_code = NULL`:

| | 今天(修法之前) | 破窗里(新函数 + 旧代码) |
|---|---|---|
| 结果 | ★ **开不出费用单**,事务回滚 | ★ **开不出费用单**,事务回滚 —— **逐字相同** |
| 建出来的费用行数 | 0 | ★ **0**(实测,见下面 ARM2) |
| 屏幕上是什么 | 一串生码 `TAX_CODE_REQUIRED\|supplier` | ⚠ **一串【别的】生码** `MEDICAL_CLAIM_TAX_CODE_REQUIRED\|MC-…` |

⚠ **那一格差别不抹平**:旧代码的 `localizeLeaveError` 两个码**都不认识**,所以**屏幕上两者都是一串生码** ——
**窗口里【可见行为】不变,而拒绝的码变了。** 说"完全一样"是不准确的,说"结果一样"是准确的。

### 3.3 §4.3 四条臂 —— **在重建库上真的跑的,全程 ROLLBACK**

量具 `/tmp/bugfix1b/B-probe.sql`,跑在 `db/verify_rebuild.py --offline` 建出来的一次性本地库上
(`/tmp/bx1b/s:55441`,与 `db/gate.py:502` 同一套 initdb/pg_ctl 机制,**端口另取,不与 gate 的 55433 撞**)。
`REBUILD_OWN_EXIT=0` · `PROBE_OWN_EXIT=0`。逐字读数:

```
ARM1 GST off · no code   : succeeded=t  -> expense EXP-2026-0001 · tax_code=(NULL)
ARM2 GST on  · no code   : succeeded=f  -> MEDICAL_CLAIM_TAX_CODE_REQUIRED|MC-2026-0002  | 建出来的费用行数=0
ARM3 GST on  · BL        : succeeded=t  -> expense EXP-2026-0002  | tax_code=BL rate=9.000 tax_base=2.70
ARM4 GST on  · bad code  : succeeded=f  -> TAX_CODE_UNKNOWN|ZZ-NOT-A-CODE
```

| 臂 | 委托书要的 | 读数 | 判词 |
|---|---|---|---|
| 1 | GST 关、不给码 → **与今天一样走得通** | ✓ 走得通,`tax_code` 是 NULL(= 本刀之前的形状) | ★ **PASS** |
| 2 | GST 开、不给码(**旧代码那一支**)→ 报告它做什么 | ✓ **按名拒,而且【一行费用都没有建出来】** | ★ **PASS** |
| 3 | GST 开、码 BL → 建得出,**报告费用的税码** | ✓ `tax_code=BL`,税率 **9.000**,税额 **2.70**(30 × 9%) | ★ **PASS** |
| 4 | GST 开、坏码 → **拒,而且是人读得懂的话,不是生码** | ✓ 库抛 `TAX_CODE_UNKNOWN\|ZZ-NOT-A-CODE`;★ **人读得懂那一半由映射器完成** —— `localizeLeaveError` 本刀补了这一支,翻成 `expense.errors.TAX_CODE_UNKNOWN`:**「There is no tax code "ZZ-NOT-A-CODE". Pick one from the tax code list.」** | ★ **PASS** |

> ★ 第 4 臂的分工要说清楚:**数据库负责【拒得准】,映射器负责【说人话】。**
> 本刀给 `localizeLeaveError` 补了 **6 支**:`MEDICAL_CLAIM_TAX_CODE_REQUIRED`(新文案)
> 与 `TAX_CODE_REQUIRED` / `TAX_CODE_UNKNOWN` / `TAX_CODE_INACTIVE` / `TAX_CODE_WRONG_SIDE` /
> `GST_NOT_REGISTERED`(★ **句子是现成的** —— `expense.errors.*` 在树里躺着,**这条路径此前够不到它们**)。
> ☞ 这**不是**「逐个码补文案」那一档(那一档明确不在本刀里),这是把 item b 这条路上**今天真的撞得到的**那几支接好。

### 3.4 §4.4 界面 —— 预选 BL,可改,要人确认

| 判据 | 怎么做的 |
|---|---|
| **复用既有控件样式与既有 select 形状,不加新组件** | ★ `CONTROL_SELECT` + 一颗原生 `<select>`,**与 `ClaimDecisionPanel` 逐字同形**;确认走**既有的** `<ConfirmButton>`(CONFIRM-1 建的)。**没有新组件。** |
| **预选 BL** | `useState(hasBlocked ? 'BL' : '')`。★ **BL 不在启用清单里时【不伪造它】** —— 留空、补一条空占位项,并在下面写一句 `claims.taxCodeNoDefault` 说清为什么。**一个预选出来、其实不存在的税码,会在服务端被 `TAX_CODE_UNKNOWN` 挡回来,而屏幕上看起来像已经选好了。** |
| **仍然可以改** | 普通下拉,`onChange` 直接改。 |
| **人必须确认** | ★★ 「生成费用单」那颗钮换成 `<ConfirmButton>`:对话框的**主语是这张报销单的单号**(CONFIRM-1 的必填 `subject`),正文**把要用的税码与日期念出来**。<br>☞ **预选不等于替人决定** —— 而这句话只有在"那个值被念给他听、他再按一下"的时候才成立。 |
| **选项来自 §4.2 那同一处** | `page.tsx` 读 `tax_codes` 再 `.filter(x => x.is_active && x.side === 'input')`。 |
| **标签与选项 en/zh 都要有** | 标签 `claims.taxCode`(Tax code / 税码);选项按 `useLocale()` 取 `name_en` / `name_zh`(与 `NewExpenseForm` 同一个惯用法),不可抵的后面缀 `expense.form.taxCodeBlocked`(tax not claimable / 税不可抵)。★ 新增的 8 个键**两份文案文件都有**,`check-i18n` 退 **0**。 |
| **仍然出得来的那个失败要说人话** | ★ GST 开着而 BL 不在清单里 → 按钮 disabled,**旁边一行常驻说明**(`data-state-note="claim-tax-code"`),与 ALERT-2d ④ 那条房规同形。 |
| ★ **GST 关着时这颗下拉【不画】** | 关着时传一个非空税码进去,`record_expense` 会**按名拒**(`GST_NOT_REGISTERED`)。所以关着时界面不画、动作也不传。 |

★ **预选写在【界面】,不写在函数里 —— 这是一次裁定,不是一次实现选择。**
函数**没有默认值**,没给就按名拒。☞ **一个写在数据库默认值里的 BL,人看不见、也确认不了** ——
那就是"替人做了一个财务判断"。写在界面上,它是一个**摆在人面前的建议**。

### 3.5 §4.5 fixture 那一臂 —— ★★ **证过它在修法之前会红**

新增 **fixture 90 · 臂 K**(K1/K2/K3),把 GST **打开**再走一遍 submit → decide → pay。
判据与 `db/gate.py` 跑 fixture 的方式**逐字同源**(`psql -X -q -v ON_ERROR_STOP=1 -f`)。

| 跑在哪一个函数定义上 | 退出码 | 命中那一行 |
|---|---|---|
| ★ **修法【之前】**(`git show HEAD:db/functions/pay_medical_claim.sql` 那一份,装进重建库) | ★★ **`FIXTURE90_OWN_EXIT=3`** | `ERROR: FIXTURE 90K1 GST 开着而没给税码,必须按【这条路自己的】名拒(MEDICAL_CLAIM_TAX_CODE_REQUIRED),实得:`**`TAX_CODE_REQUIRED|supplier`** |
| ★ **修法【之后】** | ★ **`FIXTURE90_OWN_EXIT=0`** | `90K1 ✓` · `90K2 ✓` · `90K3 ✓` · `FIXTURE 90 全部通过` |

> ★★ **最值钱的一格:那一趟"之前"里,原有的 90H 是【绿的】。**
> 它断言的正是「submit → decide → pay 必须全程走通」,而它跑在 **GST 关着**那一档 ——
> ☞ **它按构造看不见这一条**,而这正是 round 1 查出「193 支 fixture 一支都没抓到」的机制。
> (AGENTS.md:*A fixture can be thorough about a rule and blind to the case where the rule's SUBJECT IS ABSENT* —— 这里缺席的主语是**税**。)

★ **顺带量到一条,写下来免得下一个人绕路**:在 K 的末尾写一句「把开关关回去」会被
**`guard_gst_switch` 按名拒**(`GST_CANNOT_DISABLE_WITH_CODED_EXPENSES|1|EXP-…`)——
K2 刚开出来的那笔带税码的费用正挡在那里。**那道闸是对的,所以本刀不绕过它**;
改成在 fixture 里写明「从 K 往下 GST 是开着的,要在关着那一档加臂就加在 K 前面」。

---

## 4 · ★ D —— 生码 / 数据库报错不再漏到人前面

### 4.1 §5.1 的数 —— **每一个都带分母与量法**(全文 `/tmp/bugfix1b/counts.md`)

#### ① 映射器与它们的兜底

| 读数 | 数 | 分母 | 量法 |
|---|--:|--:|---|
| 「码 → 人话」的映射器(**按形状**) | **48** | 48 | 见下面三行之和 |
| 其中**以「把入参原样返回」收尾** | ★ **45** | 48 | 一支函数,入参是字符串,函数体里有一句 `return <那个入参>`(按花括号配对切函数体,**不按行切**) |
| 其中把生字符串**塞进一句模板**再返回 | **2** | 48 | `t('output.sale.saveError', {message: raw})` · `t('inbound.pricing.saveError', {message: raw})` |
| 其中**转交给另一支映射器** | **1** | 48 | `localizeLinkError` → `localizeHrError` |

★ **本刀改了 45 + 2 = 47 支**;第 48 支(`localizeLinkError`)**由它转交的那一支覆盖**,不必单独改。

#### ② Tim 的条件:**两类各数一遍**

量法:`db/{functions,tables,views,triggers,policies}/*.sql` —— **769** 个文件、
**1367** 处 `RAISE [EXCEPTION] '<字面量>'`(量具 `/tmp/bugfix1b/scan-raises.mjs`)。

| 形状 | 去重后 | 出现次数 | 判据 |
|---|--:|--:|---|
| ① **UPPER_SNAKE 生码**(可带 `\|detail`) | ★ **908** | 1367 | 去掉 `%` 占位符之后,整串匹配 `^[A-Z][A-Z0-9_]{2,}$` |
| ② **数据库自己的报错措辞** | **0** | 0 | `does not exist` / `violates` / `permission denied` / `PGRST…` 等词表 |
| ③ **人话句子** | **0** | 0 | 既不是码也不含数据库措辞 |
| ★ 参数化的**码模板** | **1** | 1 | `assert_segregated.sql:44` 的 `RAISE EXCEPTION '%\|%', p_code, …` —— **码由调用方传进来,所以它是码,不是人话** |

> ★★ **结论,照直说:这棵树的数据库【从来不故意抛一句人话】。**
> `USING MESSAGE` 实测 **0** 处,`RAISE format(…)` 实测 **0** 处。
>
> ⚠ **那么第 ②③ 类今天从哪里来?从 Postgres / PostgREST / supabase-js 自己** ——
> 约束违例、列不存在、RLS 拒绝(②),以及网络与客户端错误(「Failed to fetch」,③)。
> ☞ ★ **它们不在 `db/` 里,所以【数不出一个分母】。这一点必须写出来** ——
> 否则「② 有 0 条」看起来像一个量过的零,而它其实是「这个集合不由本仓库产生」。

| 参考读数 | 数 | 分母 |
|---|--:|--:|
| 至少被**一支**映射器白名单收着的码 | **777** | 909 |
| 因此**没有任何一支**映射器认得的码 | ★ **132** | 909 |

#### ③ 映射器的输出到达屏幕 / HTTP 正文的落点

| 去处 | 数 | 分母 |
|---|--:|--:|
| `return { error: … }`(交回客户端组件,画进那个红框) | **206** | 241 |
| `new NextResponse(…)` / `new Response(…)`(**HTTP 正文**:PDF 与导出路由) | **16** | 241 |
| `return <字符串>` · 赋给变量再用 | **7** · **12** | 241 |
| **合计调用点** | **241** | 241(在 **146** 个在册文件里) |

#### ④ ★ 生码**不经过任何映射器**直接进 HTTP 正文的落点

★ **9 处 / 8 个文件**(round 1 只点了 2 条):

```
app/materials/export/route.ts:64          app/inbound/export/route.ts:96
app/suppliers/export/route.ts:66          app/finance/gst/[periodId]/export/route.ts:41
app/sales/customers/export/route.ts:65    app/finance/gst/[periodId]/export/route.ts:58
app/output/export/route.ts:96             app/finance/packs/[id]/export/route.ts:23
app/inventory/reports/reportShared.ts:50  ← 共用的 exportFailed(),4 个调用点
```
★ **9 处全部接上了。** ⚠ `app/finance/journal/export/route.ts:59` 也写 `Export failed:`,
但它拼的是**一句固定的英文说明**,不是 `error.message` —— **不算,也没有动它**。

### 4.2 §5.2 「看起来像一个码」是怎么判的,以及它两个方向的风险

> ### ★ 判据一句话
> **【整串】去掉首尾空白之后,恰好是一个 UPPER_SNAKE 码(≥3 字符),后面可以跟一个 `|` 和任意细节。**
> 不是「串尾出现过一个大写词」。第二类(数据库报错)走一张**带上下文的词表**
> (`violates [a-z-]+ constraint` 而**不是**裸的 `column `)—— round 1 的探针在这里栽过一次,
> 词表里放裸词让 8 条命中里 6 条是假阳性。

| 方向 | 一句话的风险 |
|---|---|
| ★ **误判(把人话当成码换掉)** | **一句人话必须通篇没有小写字母、没有空格**才会被当成码 —— 这棵树的数据库从不故意抛人话(实测 0 条),而客户端的句子(「Failed to fetch」)都带小写。☞ **风险接近零,但它不是零**:一条全大写的第三方短消息会被换掉。 |
| ★ **漏判(把码当成人话放过去)** | 一个码若**前面被包了一层前缀**(`xyz: TAX_CODE_REQUIRED\|supplier`),整串判据不认它,于是它**仍然原样到屏幕上 —— 也就是今天的行为**。☞ **漏判只退回现状,不会比今天更坏;而误判会毁掉信息。所以判据故意选紧的那一边。** |

★ **原文没有消失,它去了日志**:`console.error('[machine-text] <哪一支映射器> (<形状>/<标记>): <原文>')`,
与 `app/components/nav/ModuleBar.tsx` 那条 `[nav] …` 同一个写法。
☞ **「屏幕上看不到 SQL 原文」与「追查不到」不是同一件事。**

★ **两个新键**(`common.errUnexpected`,en/zh,**Q14 的定稿逐字**,占位符 `{code}`):

* en:`This step could not be completed (code {code}). Please pass this code to your administrator.`
* zh:`这一步没能完成(代码 {code}),请把代码告诉管理员。`

### 4.3 §5.4 四条读数

量具:`/tmp/bugfix1b/probe/`(用**仓库里真的** `lib/machine-text.ts` + **真的两支映射器** +
**真的** `messages/en.ts` / `zh.ts` 编译出来跑;**只替掉 `getTranslations()` 里读 cookie 那一格**,
解析那几行从 `lib/i18n/server.ts` 逐字抄)。`MAPPERPROBE_OWN_EXIT=0`,**9 个用例 × en/zh = 18 格全过(`FAILS=0`)**。

| # | 要证的 | 逐字读数(en) |
|---|---|---|
| 1 | **生码穿过映射器 → 那句话,带着码** | in `"TAX_CODE_REQUIRED\|supplier"` → out `"This step could not be completed (code TAX_CODE_REQUIRED). Please pass this code to your administrator."` |
| 2 | **数据库报错 → 那句话,带着【标记】,不是原文** | in `"column containers.container_no does not exist"` → out `"…(code DB-5A73Z1)…"` · in `"new row violates row-level security policy for table \"materials\""` → out `"…(code DB-GJLJ02)…"` |
| 3 | **人话句子【原样】** | in `"Failed to fetch"` → out `"Failed to fetch"` · `"The batch has already been counted today."` → 逐字相同 · 中文那一条同理 |
| ★ 反例 | **白名单认得的码【不许】被兜底盖掉** | in `"STOCKTAKE_NOT_OPEN"` → out `"The stocktake is not open (status: {0})"` —— **走的是它自己的文案** |
| 4 | **日历横幅与一条导出路由** | 见下面 |

第 4 条(量具 `probe2.ts`,`PROBE2_OWN_EXIT=0`)—— **两处调用点逐字同一条表达式**:

```
日历横幅(数据库报错):"One or more sources could not be read, so this month is INCOMPLETE:
  containerEta: This step could not be completed (code DB-5A73Z1). Please pass this code to your
  administrator.. This is not the same as \"nothing scheduled\"."
导出正文(数据库报错):"Export failed: This step could not be completed (code DB-5A73Z1). …"
日历横幅(人话)      :"… containerEta: Failed to fetch. …"      ← ★ 原样
导出正文(人话)      :"Export failed: Failed to fetch"          ← ★ 原样
```

> ⚠⚠ **这一条【不是一次屏幕读数】,照直说。** 它证明的是「这两处拼出来的字符串是什么」,
> **不是「浏览器里看到的是什么」**。屏幕那一侧:BUGFIX-1a 修掉 `container_no` 之后
> `/tools/calendar` 上那条横幅**今天根本不出现**,要看它得自己造一次失败。
> ☞ **一条判据只证明它自己走过的那条路**(AGENTS.md,本刀第二次引用这一条)。
>
> ⚠ **而它当场暴露了一处本刀【造出来的】瑕疵:那个双句号**(`administrator..` / `管理员。。`)——
> 兜底那句话以句号收尾,而 `calendar.sourceFailed` 的模板又补了一个。
> ★ **本刀不改它**:那要动一句**共享文案的措辞**,而 **Tim 把措辞划给了 POLISH-1**,
> Q14 那句更是他自己的定稿。**在没有裁定的情况下改一句共享文案,正是这个仓库反复付账的那件事。**
> ☞ 登记在 `docs/known-issues.md` 的 `BUGFIX1B-FALLBACK-DOUBLE-STOP`,与「那条横幅是浅蓝底 + 红字」
> (POLISH-1 · u)**是同一条横幅,一起改**。

### 4.4 ⚠ 顺带查出的那一条 —— **一条承重的契约,只写在注释里**

`lib/action-refusal.ts` 的 `refuseFromCoded` 用一条契约分界:
**「本地化器把原样那一串还回来了」= 它没认出这个码**。
★★ **本刀换掉 45 支映射器的兜底之后,那条契约按构造失效** —— `localized !== raw` 会永远为真。

| | |
|---|---|
| ★ **后果** | 不是一句错话,是 **ALERT-1 的 `detail` 那一格整个消失**:数据库原文本该降级进可展开的细节里,而它会连同分支 ③ 一起被跳过。**30 个调用点全受影响。** |
| ★★ **怎么发现的 —— 照直说** | **是【读】出来的,不是量出来的。** 改 `app/suppliers/supplierErrorCodes.ts` 的一句注释时,那句注释自己写着「refuseFromCoded 靠它分界」。`tsc` 绿、`npm run build` 绿、193 支 fixture 绿。<br>★ 同一个形状在 `app/operation/errorCodes.ts` 还有**第二处**(`viaMaterial !== raw`),也是照着注释找到的。 |
| **修法** | 两处都改成拿**同一串**再问一次 `fallbackTextFor(raw)`(同输入同语言 ⇒ 同输出,**精确比对,不是启发式**)。★ **那 30 个调用点的屏幕文字一个字都没有变** —— 它们守的是 ALERT-1 的裁定,那条裁定比本刀早。 |
| ⬜ **没做的** | **没有闸。** ★ round 1 提过一道(AST:`localize*` 的兜底不许 `return` 它自己的形参)。**本刀故意没有现写** —— 一个刚被自己绊倒的人写出来的闸没有人验过(AGENTS.md「匆忙的检查者」)。登记在 `docs/known-issues.md`。 |

★ 顺带:本刀因此**读并改了 59 处注释**,其中 **6 处**不是"过期",是**它的论证反过来指着新代码**
(例:「一句看不懂的英文比一句编出来的中文强,后者会让人以为系统理解了刚才发生的事」——
那句话在只有两个选项时是对的,而这一刀造出了第三个:**一句人话 + 一个真的码**)。
☞ **一条论证过期,比一个数字过期更难发现:数字会被重量,论证会被照着做。**

---

## 5 · §5.5 —— `docs/machine-text-reaching-humans.md` 已登记

* ★ **CCY-1 的三个数就地更正**:~~300 / 90 / 45~~ → **909 / 132 / 68**,原数**带删除线留着**,
  并写明**它们不是"数错了",是【数的东西和名字对不上】,两个方向都错**,以及本次的量法与分母。
* ★ **登记这一族【半件已结】**:兜底有了(三类各自怎么处置,列成一张表);
  **逐个码补文案还开着**,理由逐字沿用那份文档 2026-08-10 写下的那一句(它需要一份白名单口径,
  而那是一次判断不是一次解析)。
* ★ **顺带更正它自己一处措辞**:「45 是……会看见裸码的下限」—— **后半截从今天起不成立了**,前半截仍然成立。

---

## 6 · §2 规矩,逐条 DONE / NOT DONE

| 规矩 | 判词 | 凭据 |
|---|---|---|
| **R1** 线上业务数据只读;不建测试报销 / 测试费用;行为在重建库上证,全程 ROLLBACK;迁移是唯一允许的写,且只走仓库的迁移流程 | ★ **DONE** | 本刀**一次**都没有对线上执行过 INSERT/UPDATE/DELETE 业务行。四条臂与 fixture 两趟全在 `/tmp/bx1b` 那个一次性本地库上,`BEGIN … ROLLBACK`。迁移走 `db/apply_migration.sh`(§8)。 |
| **R2** 一次性账号只经 `scripts/ephemeral.mjs`,而且要清理 | ★ **DONE(而本刀没有用到它)** | 本刀**没有建过任何一次性账号** —— 四条臂用的是重建库里自己 INSERT 的 role/user(随 ROLLBACK 消失);冒烟自己管它的会话与清理。 |
| **R3** 每条结论标 PROVEN / SUSPECTED | ★ **DONE** | 见 §0 与各节。 |
| **R4** 关掉的那一族不许动 | ★ **DONE** | `git diff --stat` 对 `control-style.ts` · `table-style.ts` · `input.tsx` · `textarea.tsx` · `app/globals.css` · `app/login/` · `app/brand-sampler/` · `docs/handbacks/` = **空**;`decide_expense_claim.sql` = **空**。逐条读数见 §9。 |
| **R5** FONT-3 / POLISH-1 的每一件、以及逐码文案,都不在本刀 | ★ **DONE** | 一个 FONT-3 / POLISH-1 条目都没有碰;逐码文案**明确没做**,并把它连同理由登记进了队列与 known-issues。 |

---

## 7 · §7 文档,逐条

| 要写的 | 写在哪 | 判词 |
|---|---|---|
| GST 口径那份文档:BL 预选的裁定 · 为什么报销单那条路不同 · Reg 26 的依据 · **等会计确认** | ★ `docs/accounting-policies.md` **§9.1b**(标记 `SETTLED — 2026-09-12, ruled by Tim (BUGFIX-1b). ⚠ NOT YET CONFIRMED WITH THE ACCOUNTANT.`) | ★ **DONE** |
| `pay_medical_claim` 的函数注释指过去 | ★ `COMMENT ON FUNCTION public.pay_medical_claim(uuid, date, numeric, text)`(**在迁移与镜像里都有,逐字相同**)+ 镜像文件抬头那一段 | ★ **DONE** |
| `docs/forward-queue.md`:1b 完成 · `v1.4.18` 已发 · 刀序刷新 · 还开着什么 | ★ 刀序表 1b 那一行 · 拆分表那一格 · b/d 两条的「本族的结果」· **新增「`v1.4.18` 已发」整节**(含一张「还开着的」表:逐码文案 / 人话句子的措辞 / 双句号 / 那道没做的闸 / `detail` 里的原文)· 四条裁定标成**已执行**并逐条指出落在哪里 | ★ **DONE** |
| `docs/known-issues.md`:本刀查到而没修的 | ★ **4 条**:`BUGFIX1B-CODES-WITHOUT-COPY` · `BUGFIX1B-REFUSE-FROM-CODED-CONTRACT` · `BUGFIX1B-FALLBACK-DOUBLE-STOP` · `BUGFIX1B-DETAIL-KEEPS-THE-RAW` | ★ **DONE** |
| `docs/machine-text-reaching-humans.md` | 见 §5 | ★ **DONE** |
| `AGENTS.md`:只写新的失效模式 + CONFIRM-1 那一行 | ★ **一节新的**(「一条【承重的契约只写在注释里】」)· **CONFIRM-1 表加一行**(三个数逐条)· 「一次勘察只看得见代码碰巧给它起的名字」**加第三个实例**(42 → 45) | ★ **DONE** |

---

## 8 · §6 每一步:它【自己】的退出码与实测时长(UTC)

| 步 | 命令 | 起 → 止 | 秒 | 判词 |
|---|---|---|--:|---|
| 6.1 | `npx tsc --noEmit` | 02:08:45 → 02:08:46 | **1** | ★ `TSC_OWN_EXIT=0` |
| ★ 6.1 自证 | **故障注入**:往 `app/hr/claims/actions.ts` 塞一行 `const __probe: number = 'not a number'` | — | — | ★ **`INJECT_OWN_EXIT=2`**,点名 `actions.ts(73,7) TS2322` —— **这支闸会咬人**(注入后原样撤回,`git diff` 复核) |
| 6.2 | `node scripts/check-i18n.mjs` | 02:08:46 → 02:08:46 | **<1** | ★ `I18N_OWN_EXIT=0` · **缺键 0**(「代码引用的每一个键(含可枚举的动态键)en 与 zh 都在」) |
| 6.3 | `npm run build` | 02:08:46 → 02:09:24 | **38** | ★ `BUILD_OWN_EXIT=0` |
| 6.4 | `node scripts/smoke-routes.mjs`(**不带 `--reach`**;开跑前 `rm -rf .next`) | 02:09:58 → 02:20:33 | **631** | ★ `SMOKE_EXIT=0 —— **248 ok · 6 skipped(没数据)· 0 FAILED**` |
| 6.5 | `python3 db/gate.py --offline` | 02:21:09 → 02:21:54 | **45** | ★ `GATEOFF_OWN_EXIT=0 —— 「迁移前相位:✓ 干净」` |
| 6.6 | 备份 `~/evoltrya-backups/backup.sh` | 02:22:03 → 02:28:54 | **411** | ★ `BACKUP_EXIT=0 —— 4.2MB · **TOC 5592 条**(上一份 5456,下限 4910)· 落盘先用隔离名 `.INCOMPLETE`,四道检查全过之后才改名` |
| 6.7 | `./db/apply_migration.sh …` ★ **破窗在这里打开** | 02:29:33 → 02:29:58 | **25** | ★ `MIGRATION_OWN_EXIT=0 —— 预检:`account 1 个科目码 1 个已 is_system` · `function 1 条 CREATE:0 替换 · 1 新建` · `masked 本迁移不加列` · `✓ 预检通过`;`✓ committed atomically(含函数授权兜底)`` |
| 6.8 ① | `python3 db/gate.py`(整门,经 `db/run_detached.sh --timeout 2700`) | 02:30:07 → 02:33:29 | **202** | ★★ **`GATE_EXIT=1` —— 红,而【红对了】**:见下面 |
| ★ 6.8 修 | `NOTIFY pgrst,'reload schema'` → 等 20s → `npm run types:gen` → `npx tsc --noEmit` | 02:34:05 → 02:34:55 | **50** | ★ `NOTIFY_OWN_EXIT=0` · `TYPESGEN_OWN_EXIT=0` · `TSC3_OWN_EXIT=0` |
| 6.8 ② | `python3 db/gate.py`(整门,重跑) | 02:34:55 → 02:40:03 | **228** | ★★ **`GATE2_EXIT=0` —— 四条判词全绿** |
| — | 重建库四条臂 | 01:57:21 → 01:58:04 | **43** | ★ `REBUILD_OWN_EXIT=0` · `PROBE_OWN_EXIT=0` |
| — | fixture 90 两趟(修法前 / 修法后) | 01:59 → 02:01 | ~**120** | ★ `3`(红,点名 90K1)/ `0`(绿) |
| — | 映射器探针(真映射器 × 真文案 × en/zh) | 02:03 → 02:04 | ~**60** | ★ `MAPPERPROBE_OWN_EXIT=0` · `FAILS=0` · `PROBE2_OWN_EXIT=0` |

### ★★ 6.8 整门的四条判词 —— 逐字

```
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
```

### ★★ 而它【第一趟是红的】,红在本刀自己身上 —— 照直记

```
== 三个判词(wall-clock 202s)
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✗ 有漂移;另 1 项:generated types: lib/database.types.ts 与线上 schema
                     不一致(1 行差异):+          p_tax_code?: string  → 跑 npm run types:gen 并提交
GATE_EXIT=1
```

| | |
|---|---|
| **是谁造成的** | ★ **本刀。** 加了一个参数,而 `lib/database.types.ts` 是**这个 schema 的【另一份】镜像** —— `db/tables/*.sql` 是重建读的那一份,**这一份是【编译器】读的那一份**(OPS-10)。它落后的时候,TypeScript 会对着一个数据库已经没有的形状做校验。 |
| ★ **修法(在本刀之内,按 AGENTS.md 的顺序)** | `NOTIFY pgrst, 'reload schema';` → **等 20 秒** → `npm run types:gen`。<br>★ **那次 NOTIFY 不是仪式**:`types:gen` 读的是 **PostgREST 的 schema 缓存,不是 `pg_catalog`** —— 而本刀**刚 DROP 过一支函数**,AGENTS.md 为这一格付过账(TASK-1a-fu1:函数在 `pg_proc` 里已经是 0 行,`types:gen` 仍然把它写了出来,gate 于是为一件不存在的漂移报红)。 |
| ★ **复核:有没有【别的】漂移跟着进来** | ★ **没有。** `git diff lib/database.types.ts` 逐行看 = **恰好 1 行**:`+          p_tax_code?: string`。<br>☞ 这一句要量,不能靠"应该只有一行" —— 一次重新生成会把**线上此刻的全部形状**写下来,而线上未必只差这一处。 |
| ★★ **破窗在这段时间里【保持开着】,而那是对的** | AGENTS.md「**THE GATE GOES GREEN BEFORE THE PUSH**」:一个开着的破窗是**有界、被看着、可撤销**的;一份错的镜像落到 `main` 上是**无界、无声、没有任何东西指向它**的。<br>☞ **把一个有界的代价按住不放,去避免一个无界的** —— 这不该读起来像一次妥协。<br>★ 代价是量出来的:**破窗因此多开了约 7 分钟**(02:33:29 红 → 02:40:03 绿)。 |
| ★ **它同时是一条【正面】读数** | 这道闸**真的会为本刀咬人**。上一次有人说「gate 报告了却不拦」是 2026-08-04 —— 今天它拦住了,而且**点名了那一行**。 |

### ★ 6.7 第一次开跑被【拒了】—— 而它一个字节都没有碰到库,照直记

```
Sat 12 Sep 2026 02:29:04 UTC
✗ 迁移文件缺 BEGIN; —— 本仓库的迁移必须整文件一个事务
MIGRATION_OWN_EXIT=2
```

★ **本刀写的迁移文件漏了 `BEGIN;` / `COMMIT;`**(仓库惯例,`db/apply_migration.sh:43-44` 自己查)。
☞ **代价是【零】:那两行 `grep` 跑在任何连接之前,库分毫未动,破窗那一刻【还没有开始】。**
补上之后**重新核对了一次函数体与镜像逐字相同**(`diff` 退 **0**),再开跑,29 秒后提交。

★ **这一格值得留着,因为它是这个仓库一条法则的正面例子**:
`apply_migration.sh` 在**读文件**的时候就能回答这个问题,所以它**在开跑前**问 ——
与 AGENTS.md「一条正确的检查放错了相位,就是一条慢检查」逐字同一条,
只是这一次它放对了相位,于是那次失败**没有发生在破窗里**。

★ **本刀自己也在这一步前面加了一道同相位的闸**(`/tmp/bugfix1b/step67.sh`):
开跑前先 `grep -q "^BACKUP_EXIT=0$"`,并确认 `pg_dump` 已经不在跑 ——
后者是 SO-3b 那条(`pg_dump` 持着 ACCESS SHARE,DDL 会卡在等锁上直到 statement timeout,
而**报错只说"语句超时",不说在等谁**)。

### 6.3 的细目 —— 静态检查与 eslint 的实际数字

```
✓ check-generated-css:1104 条规则 / 1453 条声明,postcss 与 lightningcss 两支解析器都没有一条告警(82ms)
✓ check-select-columns:3701 个表×列对(去重 1748)+ 397 个写入键,全部对得上 lib/database.types.ts
✓ check-confirm-subject:58 处 subject(JSX 58 · useConfirm 0)/ 58 个 JSX 开标签 ← 本刀新加的那一颗在里面,逐文件相等的断言过了
✓ eslint 冻结闸:「没有新增的 eslint 问题」
    app/hr/claims/[id]/page.tsx        no-unused-vars  error 0→0 · warning 1→0   ← 基线可以【收紧】
    app/hr/employees/EmployeeForm.tsx  no-unused-vars  error 0→0 · warning 1→0
```
★ **eslint 一条都没有新增,而有两处变好了**(基线允许变短,脚本自己提示可以 `--update-baseline`;
本刀**没有刷新基线** —— 刷新它是另一件事,而它会把这两行读数抹掉)。
⚠ **一条 Turbopack 告警,不是本刀的**:`Failed to find font override values for font 'Google Sans'`
—— 字体那一族的,FONT-3 名下。

---

## 9 · R4 —— 关掉的那一族,逐条读数

```
app/components/ui/control-style.ts          git diff --stat 行数 = 0
app/components/ui/table-style.ts            git diff --stat 行数 = 0
app/components/ui/input.tsx                 git diff --stat 行数 = 0
app/components/ui/textarea.tsx              git diff --stat 行数 = 0
app/globals.css                             git diff --stat 行数 = 0
app/login                                   git diff --stat 行数 = 0
app/brand-sampler                           git diff --stat 行数 = 0
docs/handbacks                              git diff --stat 行数 = 0
db/functions/decide_expense_claim.sql       git diff --stat 行数 = 0
---- docs/handbacks 下【本刀新建的那一份除外】,有没有动过任何既有文件 ----
(以上为空 = 一份既有交回报告都没有改过;本刀的 BUGFIX-1b.md 是【新建】,不在 diff 里)
---- FONT-3 / POLISH-1 名下的文件有没有被碰 ----
(以上为空 = 组件库一个文件都没动)
```

---

## 10 · ★★ 破窗 ★★

| | |
|---|---|
| **起点(测量)** | ★ **2026-09-12T10:29:58+08:00(= 02:29:58 UTC)** —— `db/apply_migration.sh` 自己打的时间戳 |
| **窗口里线上跑的是** | **旧代码 + 新函数** |
| **窗口里什么是坏的 —— 逐条枚举** | ★ **一件都没有新坏。** 唯一受影响的路径是 `/hr/claims/<id>` 的「生成费用单」,而它**今天(GST 开着)本来就开不出费用单**:旧代码不传税码 → 新函数按名拒 → 事务回滚 → **费用行数 0**(实测 ARM2)。<br>⚠ **一处差别**:拒绝的码从 `TAX_CODE_REQUIRED\|supplier` 变成 `MEDICAL_CLAIM_TAX_CODE_REQUIRED\|MC-…`,而旧代码两个都不认识 —— **屏幕上两者都是一串生码,可见行为不变。**<br>★ 别的路径:`p_tax_code` 有默认值,**任何按名调用都仍然解析得到**;`record_expense` / `resolve_tax_code` 一个字没改,所以别的记费用的路**完全不受影响**。 |
| **终点(★ 转述,不是测量)** | ★★ **2026-09-12 · 10:45 新加坡时间(= 02:45 UTC)—— 部署成功。**<br>⚠⚠ ★★ **这一格【不是这台机器测出来的】** —— 它是 Tim 在 Vercel 面板上看到的那一刻,由他转述,并在 2026-09-12 收尾时补进本报告。<br>☞ **一份转述和一次测量在报告里长得很像,而它们不是一回事**(AGENTS.md「一刀的终端活【到推送为止】」)。**所以这一行写着【转述】,而起点那一行写着【测量】** —— 两者在同一张表里,标记不同。<br>★ **本刀在推送之后【没有】等部署、【没有】查部署状态、【没有】绑 deployment id、【没有】去复现任何东西。** |
| **时长** | ★★ **15 分 02 秒**(02:29:58Z → 02:45Z)。<br>⚠ **精度照直说:终点那个读数只到【分钟】**,所以这个秒数带 **±60 秒**的不确定;把它当成「**约 15 分钟**」来与别的刀比较,不要当成一个秒级的量。<br>★ 可以核对的两个硬点:迁移提交 **02:29:58Z**(`db/migration-windows.tsv` 那一行,脚本自己写的)·推送落地 **02:43:11Z**(`git push` 的读数)。☞ **部署不可能早于推送**,所以 **13 分 13 秒是一个下界**,而 15 分 02 秒落在它右边 —— 两者不矛盾,这一格因此是自洽的。 |

> ### ★★ 窗口已经关上(2026-09-12,由 Tim 确认)★★
> **02:29:58Z 开,02:45Z 关,约 15 分钟。** 窗口里线上跑的是**旧代码 + 新函数**,
> 而上面那张表已经逐条枚举过:**一件都没有新坏** —— 唯一受影响的那条路
> (`/hr/claims/<id>` 的「生成费用单」)在窗口之前就开不出费用单,窗口里仍然开不出,
> 窗口之后**才开得出**。
> ⚠ **有一件事这台机器仍然不知道,照直说:窗口里有没有人真的去按过那颗钮。**
> 本刀没有、也不该去查线上的动作日志(那是"去调查真源上发生的事",而这台机器够不到真源)。
> ☞ **若窗口里真有人按过,他看到的是一串生码 `MEDICAL_CLAIM_TAX_CODE_REQUIRED|MC-…`** ——
> 与窗口之前那串 `TAX_CODE_REQUIRED|supplier` 一样看不懂,**而两者的后果相同:没有开出费用单**。

---

## 11 · ★ Tim 该去哪儿看 —— 路由 · 视口 · 需要什么身份

> ★★ **第 1 条是【只有人能确认的那一件】** —— 本刀**一次都没有对线上写过业务数据**,
> 所以"那张真报销单开得出费用单"这句话,只有他按下那颗钮才成立。

| # | 去哪儿 | 需要什么 | 看什么 |
|--:|---|---|---|
| ★★ **1** | **`/hr/claims/<MC-2026-0001 的 id>`**(从 `/hr/claims` 点进去)<br>桌面视口 | ★ **`module.hr.view`** 才进得去页面;★ **`module.finance.edit`** 才按得动那颗钮(没有它按钮**在**、但不可按,旁边点名说要哪个权限) | ① 「生成费用单」那一段里**多了一颗税码下拉**,里面**预选着 `BL · Blocked input tax — tax not claimable`**;<br>② 下拉**可以改**,选项是 TX / ZP / EP / BL / OP(启用的进项码);<br>③ 下面一行小字说清**为什么是 BL**(Reg 26);<br>④ ★ 按「生成费用单」**先弹一个确认框** —— 主语是**单号 MC-2026-0001**,正文**把日期与税码念出来**;取消得掉,Esc 关得掉;<br>⑤ 确认之后 **费用单真的开出来了**(绿字 `Expense EXP-… raised.`),页面上出现「关联的费用单」。<br>★ **这一条本刀【没能】验证** —— 它要对线上写一行。 |
| 2 | **`/finance/expenses`**(或那张费用单) | `module.finance.view` | 那笔新费用**带着税码 `BL`**、税率 9%、状态 **unpaid**(**员工手里还没拿到钱** —— 结清走付款流程)。 |
| ★ **3** | **`/finance/claims`**(报销单,**另一条路**) | `module.finance.edit` | ★ **它【没有变】** —— 税码下拉仍然**空着**,仍然要一次明确的选择。**两条路给不同的答案,是一次裁定,不是一次疏忽。** |
| ★ **4 一处此前会漏出生码的地方** | ★ **`/hr/claims/<id>`,GST 开着、把税码改成一个停用的码再按确认**(或任何一次被库拒绝的操作) | 同 1 | 红框里是**一句人话**,不是 `TAX_CODE_INACTIVE\|…`。<br>⚠ **更直白的那一处(`/tools/calendar` 的横幅)今天【看不到】** —— BUGFIX-1a 把那条坏查询修好之后它不再出现,要看它得自己造一次失败。 |
| 5 | 任何一条**导出**(`/suppliers` → 导出 CSV 等) | 该模块的 view | 正常时照旧下载 CSV;**出错时**浏览器里那句话是 `Export failed: This step could not be completed (code …)`,**不再是一句 SQL 原文**。 |

---

## 12 · ★ 我【没能】验证的 —— 照直说

| # | 没验的 | 为什么 | 怎么才能验 |
|--:|---|---|---|
| ~~★ **1**~~ ★ **1 · 已由人走过(2026-09-12)** | **线上那张 MC-2026-0001 真的开得出费用单** | ★ **R1:线上业务数据只读。** 本刀**一次**都没有对线上写过业务行 —— 所以这一条**本刀至今没有验过**,下面那一格是**转述**。 | ★★ **Tim 在部署之后走了一遍(由他转述,2026-09-12)。**<br>⚠ **逐条读数没有传到这台机器上** —— 传过来的是「走查完成」这一句,**不是**五个子项各自的读数(预选是不是 BL · 改得动吗 · 确认框说了哪一张单 · 取消得掉吗 · 费用单真的出来了吗)。<br>☞ **所以这一格记的是【他走过了】,不是【五条全过】** —— 两者在报告里长得很像,而它们不是一回事。 |
| ★ **2** | **屏幕上真的长什么样**(税码下拉 · 确认框 · 兜底那句话) | 本刀的读数是**代码层与字符串层**的:`tsc` / 构建 / 冒烟(2xx)/ 直接调用映射器。★ **冒烟按它自己的抬头只断言 2xx,而一页渲染着错误框也是 200。** | 人走一遍(§11),或造一次真的失败再看。 |
| 3 | **日历横幅在屏幕上的样子** | 那条横幅**今天不出现**(BUGFIX-1a 修好了它的来源)。 | 造一次来源失败,或照 `data-calendar-failures="1"` 那个把手找。 |
| 4 | **「949 条上界」与「141 条路由上只漏 1 处」** | ★ **本刀没有重量**,因为它们**不是本刀任何一条判据的阈值**。屏幕普查那一趟要 1977 秒。 | 重跑 round 1 的文本探针。 |
| ★ **5** | **`refuseFromCoded` 那 30 个调用点【在屏幕上】仍然是对的** | 修法是**逐字保守**的(判据加了一项,输出不变),而**没有一道闸能证明它** —— 那条契约只写在注释里。 | 一次针对性的交互探针,或那道还没做的 AST 闸。 |
| ~~6~~ ★ **6 · 已答复(2026-09-12)** | **部署** | ★★ **规矩:一刀的终端活到推送为止。** 这台机器够不到 Vercel(五项逐条实测全部 ABSENT)。 | ★ **成功,10:45 新加坡时间 —— Tim 在 Vercel 面板上看到的,由他转述。**<br>★ **本刀没有去查、没有去等、也没有在被告知之后去复现任何东西。** |

---

## 13 · 改了哪些文件 —— 以及【为什么它在这份清单里】

| 组 | 文件数 | 为什么 |
|---|--:|---|
| **B · 库** | 2 | `db/functions/pay_medical_claim.sql`(镜像)· `db/migrations/2026-09-12-bugfix1b-a-medical-claim-needs-a-tax-code.sql`(★ **两份的函数体 `diff` 退 0,逐字相同**) |
| **B · 界面** | 3 | `app/hr/claims/[id]/page.tsx`(读 GST 开关与税码清单)· `[id]/ClaimControls.tsx`(下拉 + 确认)· `app/hr/claims/actions.ts`(多一个参数,**不替人补默认值**) |
| **B · 文案与映射** | 3 | `messages/en.ts` · `messages/zh.ts`(8 个 claims 键 + `common.errUnexpected`)· `app/hr/leave/actions.ts`(6 支税码码) |
| **B · fixture** | 1 | `db/fixtures/90-…sql` 臂 K |
| **D · 共用兜底** | 1 | ★ **新增** `lib/machine-text.ts` |
| **D · 映射器** | 47 | 45 支换兜底 + 2 支模板型接上 |
| **D · 那条契约** | 2 | `lib/action-refusal.ts` · `app/operation/errorCodes.ts` |
| **D · 漏到人前的落点** | 9 | `app/tools/calendar/sources.ts` + 8 个导出相关文件(含共用的 `reportShared.ts`,它的 `exportFailed()` 因此变成 `async`,4 个调用点跟着加 `await`) |
| **文档** | 5 | `AGENTS.md` · `docs/accounting-policies.md` · `docs/forward-queue.md` · `docs/known-issues.md` · `docs/machine-text-reaching-humans.md` |
| **B · 库(生成的那一份镜像)** | 1 | ★ `lib/database.types.ts` —— **整门第一趟就是为它红的**(+1 行 `p_tax_code?: string`) |
| **破窗台账** | 1 | `db/migration-windows.tsv`(`apply_migration.sh` 自己写的那一行起点) |
| **本报告** | 1 | `docs/handbacks/BUGFIX-1b.md` |

★ **仓库里一个临时文件都没留**:量具、探针、日志**全部在 `/tmp/bugfix1b/` 与 `/tmp/bx1b/`**(仓库外)。

---

## 14 · 部署与残留

> ### ★ 本节的【部署】那两格是 2026-09-12 收尾时补的,不是收工那一刻写的
> 队列那条规矩写着:**破窗时长仍然是交回报告的一个必填字段,而它的终点读数从 Tim 那里来。**
> ☞ 所以这一格**按设计就是后填的** —— 它不是一次改写。★ **原来那两行的措辞留在 §10 与 §12**,
> 补上去的部分都带着日期与「转述」两个字。

| | |
|---|---|
| **提交** | ★ **`8472ad45c7e5dab2626a7cf8653e9f1699f5b936`** —— 工作与本报告**同一个提交**(78 个文件) |
| **推送** | ★ **是 —— 三方完整 40 字符 SHA 逐字相同** |
| **三方 SHA** | 见本刀在终端里报的那三行(`HEAD` · `origin/main` · `git ls-remote`,**完整 40 字符**) |
| ★ **部署** | ★★ **成功 —— 2026-09-12 10:45 新加坡时间(= 02:45 UTC),由 Tim 在 Vercel 面板上确认。**<br>⚠ **这是一句【转述】**:本刀不查、不等、不绑 deployment id,被告知之后也没有去复现任何东西(AGENTS.md「一刀的终端活【到推送为止】」—— 那一条有一次实测的价钱,BUGFIX-1a 整趟跑过一遍,**买到的是零**)。<br>★ **破窗因此关上:02:29:58Z → 02:45Z,约 15 分钟。** |
| **一次性账号 / 临时行** | 本刀**没有建过一次性账号**;冒烟自己那一套由它自己清理,它报出来的滞留行**照它的规矩只报告不清扫**(见 §8 的冒烟日志) |
| **那个一次性本地库** | `/tmp/bx1b`,已 `pg_ctl stop -m immediate`(`PGSTOP_OWN_EXIT=0`),**复核过没有残留的 postgres 进程** |

---

## 15 · ★★ `v1.4.18` 交给测试的人的那一份说明(完整,BUGFIX-1a + BUGFIX-1b 两刀合起来)★★

> **这一节是给测试者的,可以整段发出去。**

---

### `v1.4.18` —— 这一版修的是【坏了】的东西,不是【不好看】的东西

这一版由两批改动组成。下面按**你会在哪里碰到它**来写,不按内部的刀序。

#### ★ 请先读这一句 —— 关于字体

> ★★ **字体正在【分步】统一,`v1.4.19` 会把它做完。**
> ☞ **【字体不一致】这一类现象【不要报】** —— 屏幕上一定还有两种字,那件事已经有人领了、有版本号、有日期。

#### 一 · 报销:GST 开着时,已批准的医疗报销**终于开得出费用单**

* **此前**:在 `HR → 报销 → 某一张报销单` 上按「生成费用单」,会跳出一串大写字母
  (`TAX_CODE_REQUIRED|supplier`),而**费用单一张都开不出来**。
  ⚠ **那不是"一句没翻译的话",那是一次【做不成的动作】** —— 而且**你做什么都修不好**。
* **现在**:那一段里**多了一颗「税码」下拉**,里面**预先选好 `BL`(不可抵进项)**。
  按「生成费用单」会**先弹一个确认框**,把**日期与税码念给你听**,你按下去它才真的开单。
* **请重点走这几步:**
  1. 下拉里**预选的是不是 BL**?
  2. 把它**改成别的**(例如 TX)再确认,开出来的费用单上是不是**你选的那个**?
  3. 确认框里**说的是哪一张单**(单号)、**哪一天**、**哪个税码**?**取消**得掉吗?**Esc** 关得掉吗?
  4. 开完之后,费用单的状态是 **未付** —— ★ **这是对的**:钱要走付款流程才到人手里。
* ★ **为什么预选 BL**:新加坡 GST 的一般规则是 Reg 26 把员工医疗开支的进项税**挡住**
  (不可抵),除非属《工伤补偿法》强制或劳资协议要求的那几类。
  ☞ **属于那几类就把它改掉** —— 系统只是把"绝大多数"摆在你面前,**判断仍然是你的**。
* ★ **另一条路【故意不一样】**:`财务 → 报销单`(expense claim)那一屏的税码**仍然空着、仍然要你选**。
  **那是有意的,不要报成不一致** —— 那里覆盖的是任意一类支出,没有"绝大多数"可言。

#### 二 · 错误提示:再也不会把一串机器码摔到你脸上

* **此前**:一步做不成的时候,屏幕上常常是 `CREDIT_LIMIT_EXCEEDED|ZZ-C3|10000|8820|2000`
  这样一串东西,或者一句 SQL 原文(`column … does not exist`)。
* **现在**:那些会变成 **「这一步没能完成(代码 XXX),请把代码告诉管理员。」**
  ☞ ★ **请把那个【代码】连同你当时在做什么一起报给我们** —— 它是我们查这件事的钥匙。
* ★ **有两类东西【故意没有变】,请不要报成缺陷:**
  1. **系统本来就说得清楚的那些提示**(「这个客户没有默认税码……」)——它们原样留着,
     因为一句具体的话比一句通用的兜底告诉你更多;
  2. ★ **那句兜底本身的措辞**(包括它有时会连着出现两个句号)—— **措辞归下一批**(`v1.4.20`)。

#### 三 · 下面这些是同一版里 BUGFIX-1a 修好的,请顺手确认

| 在哪儿 | 此前 | 现在 |
|---|---|---|
| **`工具 → 日历`** | 集装箱「到港预计」**一条都画不出来**(从 2026-09-03 起就没出现过),而横幅上印着一句 SQL 原文 | 画得出来了。⚠ **本月(2026-09)线上 0 条 ETA,四条全在 2026-08** —— **九月是空的,那不是故障**,请切到 8 月看。<br>★ 顺带:日历上的请假条目现在显示**姓名**,不再只显示工号。 |
| **`HR → 请假`**(以及 `/me` 的请假余额) | 「来源」那一列印着 `leave.grantType_monthly_accrual` 这样一个键 | 写着 **Monthly accrual / 按月累计** |
| **`工具 → 任务` → 某个任务的步骤日期** | 点开日期选择器,**浮层关不掉**、焦点被抢走 | 选完就关得掉。★ 请特意走一遍任务 **`Chicken Duck Talk`** 的步骤 **`Dinner`** —— **这一条只有人能确认**(无头浏览器弹不出原生浮层) |
| **`HR → KPI 评分`** 等带多行输入框的表 | 越打字框越宽,把邻居那一列挤没 | 不再变宽,字改为换行。<br>⚠ **已知代价,不要报**:那两列现在**很窄**(约 50px),于是打长字会变得很高。**列宽是下一批(`v1.4.20`)的事,已经在册。** |

#### 四 · ★ 这一版【明确没做】的,报了也会被归到后面的版本

* **逐个错误码补专门的文案** —— 今天它们走的是那句通用兜底。**它需要一次口径裁定,会有自己的一刀。**
* **文字措辞**(包括上面那个双句号)、**按钮尺寸**、**空态的说法**、**表格列宽**、**组织图** —— 全部是 `v1.4.20`。
* **字体** —— `v1.4.19`。(见最上面那一句。)

---

pbcopy < docs/handbacks/BUGFIX-1b.md
