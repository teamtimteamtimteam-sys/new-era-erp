# 静默吞掉查询错误 —— 全量清点与结案

`?? []` 把查询失败变成空数组,页面于是回 HTTP 200 说"没有待办"。冒烟测试断言
2xx,正好从它旁边走过去。政策与助手见 `lib/db-helpers.ts`(`mustRows` /
`mustOne` / `mustCount`)与 AGENTS.md。

四轮并行审计共认定 **320 处**。其中 **153 处**已由 FIN-7-fu 机械转换,
`lib/permissions.ts` 与 34 处 `Promise.resolve({ data: [] })` 的结构性成因一并修掉。
本文件清点【剩下的 149 处】,每处一个判词,**HARMLESS 的也逐条点名,好让这张单子
可以结掉而不是无限期背着**。

## 判词分布

| 判词 | 数量 | 处置 |
|---|---|---|
| FAILS OPEN | 7 | **已全部修掉**(见下;含 FIN-9 改判的重估预览与关账对勾) |
| SHOWS FALSE DATA | 62 | 未修:只误导、不放行、不毁数据。按页面重要性排期 |
| HARMLESS | 80 | **结案,不再复查** |

## FAILS OPEN —— 7 处,已修

护栏读不出来就等于护栏不存在。规矩:**读不到当前状态的表单,不许提供写入。**

| 位置 | 失败时会发生什么 |
|---|---|
| `app/hr/payroll/loadGridData.ts:47` | 当期明细读成空 → 表格全空 → 保存走 `upsert_payroll_period`(先 DELETE 再按非空行重插)→ **整月工资被抹掉** |
| `app/finance/invoices/new/page.tsx:59` | "已开过票的销售"读成空集 → 这些销售重新可选 → **二次开票** |
| `app/hr/reviews/cycles/page.tsx:55` | 渲染成"还没有周期" → 诱使再开一轮 → **给每名员工再生成一条评估** |
| `app/hr/reviews/[id]/page.tsx:64` | `current_user_employee` 失败 → `isReviewer` 假 → **整页写权限被静默改写** |
| `app/suppliers/[id]/edit/page.tsx:57` | 当前模板不在选项里 → 下拉回落到"无" → 保存**静默清空默认付款条款** |
| `app/finance/revaluation/page.tsx`(FIN-9 改判) | 页面**自己用 TypeScript 又实现了一遍**调整额算法,与 `revalue_foreign_balances` 已漂开;少算既往重估行会放大调整额,而**这个数字会被过账进总账**。修法是删掉重复实现,不是修那条查询 |
| `app/finance/close/page.tsx:90`(FIN-9 改判) | 借贷都读成 0 → `0 === 0` → 关账按钮正上方亮绿色「✓ 已平」。**那个对勾正是失败本身画出来的**,而关账不好撤 |

另有 4 处在其它切次已修:`settings/permissions/roles/[id]:79`(保存会撤销该角色
全部授权)、`purchasing/payment-terms/[id]/edit:41`、`pricing/formulas/[id]/edit:55`、
`hr/departments/actions.ts:58`(数不出人数就删掉有人的部门)。

## HARMLESS —— 80 处,结案

三种形状,可整类结掉,不必逐条再看:

1. **同表同过滤的兄弟查询已经检查了 error 并渲染错误面板**(约 30 处)——
   失败时那条路径根本走不到。例:各列表页的 `count` 查询,其行查询已检查。
2. **标签/链接/徽章的回退**(约 30 处)—— 失败只是某个名字变成「—」或某个链接
   消失,金额、状态、行数都不受影响。例:`payments/[id]:88`、`payroll/page:31`。
3. **失败朝【关】的护栏**(约 20 处)—— 读不到就拒绝动作,只是报错文案不准。
   例:`metalContentActions.ts` 四处、`costActions.ts` 三处、`assays/actions.ts`
   四处,全都 `if (!x) return { error: … }`,不写任何东西。

导出路由(`customers|suppliers|materials/export/route.ts`)也在此列:它们的
`error` 已经先返回 HTTP 500,`?? []` 到不了。

## SHOWS FALSE DATA —— 结案(OPS-12,2026-08-07)

**复查发现 62 已经不是 62 —— 是 12。** 其余 50 处在此后的切次里被顺带修掉了:
凡是被别的原因动过的页面,重写时都用了 `mustRows` / `mustOne`(FIN-26/27/30/32
碰过的采购、计价、现金流、库存页都在其中)。这与本仓库反复出现的那句话一致:
**一个数字往往只是"上一个看的人看见的那个数"**;所以本轮先重新数,再动手。

清点方法本身也留了下来 —— `scripts/check-error-swallowing.mjs` 就是那次扫描,
装进了 `npm run build` 与 `db/gate.py`。

### 12 处按【拿着这张错屏幕会做什么】分组

**A. 会被人当数字用的(2 处)** —— 这一类与下面那类严重性不同,单列:

| 位置 | 读成空会看到什么 |
|---|---|
| `app/finance/cost-variance/page.tsx:12` | 整张成本差异表读成空 → "本期没有差异" → 没人去查那笔超支。该页【整个文件连 error 都没解构】 |
| `app/inbound/[id]/edit/page.tsx:197` | 可抵扣预付读成 null → "没有可抵扣的预付" → 操作员不去抵一笔确实存在的预付 |

**B. 选项读短的表单(10 处)** —— 失败时少几个选项。多数**朝关失败**
(下拉空就提交不了):bank/import 的档案、fx/new 的币种、journal/new 的科目、
claims/new 与 training/new 的员工、pricing/calculator 的公式、
leave/holidays 与 leave/types 与 reviews/scale 三个编辑器。

其中 `hr/departments/new` 是边界情形:父部门下拉读空 → 看起来"没有可选的父级" →
建出一个根部门而不是子部门。**它写错了东西,但没有绕过任何护栏**,而且是新建表单
不是编辑表单(不像 FIN-7 那次 `suppliers/[id]/edit` 会静默清空既有值)。

### 有没有"其实会写/会放行"的(即 FAILS OPEN 漏网)

**没有,而且是特意查过的**:三个编辑器(holidays / leave types / review scale)
形状上很像当年 `hr/payroll/loadGridData.ts` 那处 —— 读成空 + 保存 = 整月被抹掉。
逐个查过它们的保存动作:**都是逐行 insert / delete().eq('id', …)**,不是
"整删重插"。所以读成空只是编辑器空着,保存不会删掉任何东西。

另有 6 处被判为**误伤,进 ALLOWLIST 并写明理由**:`lib/db-helpers.ts` 是
`mustRows` 自身(上一行刚抛过)、`lib/permissions.ts` 上一行显式 throw、
三个 export 路由的 `error` 已先返回 500、
`ImportStatementForm` 的 `res.data` 是 **PapaParse 的解析结果不是查询**。

---

## SHOWS FALSE DATA —— 62 处(2026-08-05 的原始记录,留档)

不放行、不毁数据,但会把一个**似是而非的数字**摆在人面前,而人会照着它做决定。
按后果轻重,值得优先的几处:

- `app/finance/invoices/page.tsx`(5 处)—— 整个文件没有任何 error 检查,失败即
  干净的 200「没有发票」。
- `app/finance/invoices/[id]/pdf/route.ts:89` —— 发给客户的 PDF 有总额、没有行。
- `app/hr/page.tsx:41` —— 待办板读成"没有警报"(过期工作准证、试用期将满)。
- `app/inventory/{inbound,output}/[materialId]` —— 库存钻取整页读成 0 件、$0。

其余按页面排期即可;它们不构成放行或数据丢失。
