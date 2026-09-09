# PERM-CODE-1 + LINT-FREEZE-1 交回 —— 四道闸与服务端对上了,eslint 冻住了

**两件都做完了,队列也补正了。本刀没有一条 SQL,没有迁移。**

---

## 1 · 起止与树的状态

| | |
|---|---|
| 开工 HEAD | `b3ef1de15e4041593da74be127e1ad49744c2c5d` |
| `origin/main`(**`git fetch origin` 之后**读的) | 同上,相等 |
| 开工时的树 | `nothing to commit, working tree clean`(0 个改动文件) |
| 收工 HEAD | 工作提交 `abdd179`,**已推送、已部署**(见 §8.3);本行之后另有一次 docs-only 的补记提交。★ 哈希**不写在这里** —— 一份报告写不出自己所在那次提交的哈希,而 ALERT-2c 为此付过账(amend 之后那一行指向一个不存在的提交)。`git log -1` 是唯一的真源。 |

★ 那次 fetch 是这一刀自己的闸交回来的规矩:**一次没有 fetch 过的"相等"是自证的**。

---

## 2 · 任务一 · 四道闸,逐处

### 2.0 先说数:是【四道】错,不是五道

文件里 `<PermissionGate` 原本 **5** 处,但它们不是同一种错,**而且其中一道本来就是对的**:

| # | 改前行 | 改前 `code=` | `allowed=` 实际携带 | 判定 |
|---|---|---|---|---|
| 1 | `:218` 外层 | `module.processing.edit` | processing | ✅ **本来就对**,原样留下 |
| 2 | `:219` 内层 | `module.finance.edit` | processing | ❌ 码错 → **删掉** |
| 3 | `:367` | `module.finance.edit` | processing | ❌ 码错 → 改码 |
| 4 | `:436` | `module.finance.edit` | processing | ❌ **布尔**错 → 改布尔 |
| 5 | `:479` | `module.finance.edit` | processing | ❌ **布尔**错 → 改布尔 |

委托书原稿的「五处 `code="module.finance.edit"`」把 `:219` 数了两遍(一次在坐标表里、
一次作为"那一对嵌套")。**实际是四处 finance 码 + 一处 processing 码。**

### 2.1 强制到底在哪 —— **改每一处之前又读了一遍**

| 控件 | 动作 | 路 | **强制点(逐字读的)** | 实际强制 |
|---|---|---|---|---|
| 新增保养(展开钮 · 保存) | `recordMaintenance` | `actions.ts:60` `supabase.from('equipment_maintenance').insert(...)` —— **直插,不是 RPC** | `db/tables/equipment_maintenance.sql:144-147`<br>`FOR INSERT ... WITH CHECK (has_permission('module.processing.edit'::text))` | **`module.processing.edit`** |
| 资本化(两处) | `capitaliseMaintenance` | `actions.ts:99` `supabase.rpc('record_expense', …)` | `db/functions/record_expense.sql:54`<br>`PERFORM require_permission('module.finance.edit');` | **`module.finance.edit`** |

两条都不是"看着像":

* `record_expense` 的那句 `require_permission` 是 `BEGIN` 之后的**第一条语句、无分支**,
  且**全文件仅此一条**(`grep -c require_permission` = **1**)。
* **资本化【不需要第二个权限】。** 这一条是特意去证伪的:`record_expense.sql:634`
  确实 `UPDATE equipment_maintenance`(那张表的 update 策略要 processing.edit),
  **但该函数是 `SECURITY DEFINER`**(`record_expense.sql:4`),以属主身份跑、绕过 RLS ——
  `equipment_maintenance.sql` 自己的 SILENT-1 注释也写着「属主 / SECURITY DEFINER
  那些路一律放行」。**所以那条路上只有一道 finance.edit。**

### 2.2 四道闸改成了什么(改后行号)

| 闸 | 现在 `code=` | 现在 `allowed=` | 与强制一致? |
|---|---|---|---|
| `:236` 新增保养的展开钮 | `module.processing.edit` | `canEdit`(processing) | ✅ |
| `:386` 保养表单的【保存】 | `module.processing.edit` | `canEdit`(processing) | ✅ |
| `:457` 资本化(未展开态) | `module.finance.edit` | `canCapitalise`(finance) | ✅ |
| `:500` 资本化(展开后的提交) | `module.finance.edit` | `canCapitalise`(finance) | ✅ |

**嵌套那一对怎么解的:** 两层的 `allowed` 是**同一个布尔**(都是 `allowed={canEdit}`),
所以内层**一次都没有挡住过任何人** —— 外层为真时内层必为真。
它唯一的作用是把一句**错的**原因印到屏幕上。**内层已删,外层留下**:
外层的码与实际强制一致,也与同屏 `:226` 那句 `equipment.needsProcessingEdit` 一致。

### 2.3 操作的人现在看见什么(这是本刀的全部意义)

`PermissionGate` **把 `code` 印到人眼前**(可见的一行点名权限码 + `title` 里
"管理员在 Settings → Roles 里勾它")。所以改前改后的差别是这样的:

| 谁 | 控件 | **改前** | **改后** |
|---|---|---|---|
| 持 `finance.edit`、**不**持 `processing.edit`(线上的 **`finance`** 角色) | 新增保养 / 保存 | 「去要 **module.finance.edit**」—— ★ **而这个人【已经持有】那个码。** 一句指着他早就有的权限的话。 | 「去要 **module.processing.edit**」—— 他确实缺这个 |
| 持 `processing.edit`、**不**持 `finance.edit`(线上的 **`operations`** / **`cco`** 角色) | 资本化 | 一个**按得下去**的钮,按下去被服务端拒(SILENT-1 形状) | 钮**看得见、按不动**,并说出缺 `module.finance.edit` |

★ 第一行那一格是 `permission-gate.tsx` 抬头自己写下的最坏情形
(「更坏的情形是他【已经有】那个码」)在这棵树上的**实例**。它今天没了。

### 2.4 i18n:**一个键都没有新增,一个都没有删**

* 新增的用户可见字符串:**0**
* 改动的用户可见字符串:**0**
* 退休的键:**0**
* `equipment.needsProcessingEdit`(`:226`)按 R5 **留着** —— 改完之后它与 `:218`/`:236`
  的码**一致**了,而此前它与内层那道 finance 闸在同一屏上**互相矛盾**。

> 所以本刀**没有 §5「每一句新的/改过的用户可见文字」那一节可写** —— 它是空的,
> 而空着比编一节出来诚实。

---

## 3 · `:197` 现在长什么样,以及谁因此看得见了

**改前:**
```
r.capitalised && !r.capitalised_expense_id && inServiceDate && canEdit ? (
```
那个 `canEdit` 是 **processing**,却在决定一个 **finance** 控件画不画。

**改后:**
```
r.capitalised && !r.capitalised_expense_id && inServiceDate ? (
```
三个**记录状态**条件留着,权限整个交给里面那两道闸(ALERT-2d ④(a) 的药:
闸归闸、状态归状态)。

**谁因此看得见了:一个持 `module.finance.edit` 而不持 `module.processing.edit` 的人**
—— 也就是线上 **`finance`** 角色。改前这个人**连按钮都看不到**(那一格渲染成
`capNotInService` / `capNeedsFlag` 之外的空白),而他恰恰是**唯一真正有权做这件事的人**。
那正是 DBLOCK-1 裁掉的藏法:**藏起来的钮教给人的是「这个功能不存在」。**

⚠️ **但这一处今天【走不出来】,原因在 §7.2 —— 线上没有一台设备有投用日。**

---

## 4 · 任务二 · eslint 冻结

### 4.1 基线是从哪个数写下来的 —— **写基线的那一刻现量的**

```
node scripts/check-lint.mjs --update-baseline
BASELINE_WRITE_OWN_EXIT=0
✓ 基线已写入 scripts/lint-baseline.json —— error 42 · warning 88
  89 条【文件 + 规则】。
```

| | |
|---|---|
| **error** | **42** |
| **warning** | **88** |
| 合计 | **130** |
| 文件 | 85 |
| 【文件 + 规则】条目 | **89** |
| 基线大小 / 位置 | **13,346 字节** · `scripts/lint-baseline.json` |
| 闸 | `scripts/check-lint.mjs`,已接进 `npm run build`(`check-confirm-subject` 之后、`next build` 之前) |
| 单跑 | `npm run check:lint` |
| 代价 | **13 秒**(对照:门 183–650s,冒烟 765s) |

★ 这个 42 是**在任务一改完之后**量的,与闸前那次相同 —— 任务一没有动到任何 lint 计数。
**交下来的是 43;真值 42。** 本族"交下来的数偏低"这次反了过来:它**高了一个**。
它的来历没有找到(`forward-queue.md` 里 `lint` 零命中)。

### 4.2 为什么 eslint 此前从来没有让构建变红

`npm run lint` 一直都在,`eslint.config.mjs` 也一直都在 —— 但 **`next@16.2.6` 的
`next build` 不再自动跑 eslint**(Next 15 起的变更),`next.config.ts` 里也没有任何
eslint 设定。**42 个 error 与 88 个 warning,一个都没有拦过任何人。**

### 4.3 注入证明 —— **三个退出码,都是闸【自己的】**

判据:`CHECK_LINT_OWN_EXIT=$?` 直接写进日志,**不看管道的码**。

| 步 | 做了什么 | **闸自己的退出码** |
|---|---|---|
| 1 | 什么都不改 | **`CHECK_LINT_OWN_EXIT=0`** ✅ 绿 |
| 2 | 新建 `lib/__lint-freeze-probe.ts`,内容 `let probe = 1` | **`CHECK_LINT_OWN_EXIT=1`** ✅ **红** |
| 3 | 删掉它 | **`CHECK_LINT_OWN_EXIT=0`** ✅ 绿 |

第 2 步闸打印的原话:
```
✗ 1 条【新的】文件+规则组合 —— 基线里没有它:
   lib/__lint-freeze-probe.ts  prefer-const  error 1 · warning 0
✗ 总数上升:error 42→43 · warning 88→88
```
> (它把 42 顶成了 **43**。这一族第九次遇见这个数,而这一次它终于是量出来的。)

#### ★ 第一次注入【没有咬住】,而那不是闸的毛病 —— 记下来,免得下一个人重蹈

第一版探针写成 **`scripts/__lint-freeze-probe.mjs`**,闸退 **0**。
查下去:该文件**确实被 lint 到了**(`lintFiles` 结果里有它,`isPathIgnored` = false),
但 **`prefer-const` 在这份配置下对 `.mjs` 不生效** —— `eslint-config-next` 的
TS 那一套是按 ts/tsx 挂的,`npx eslint` 直接跑那个文件也是退 0。
**是探针选错了文件类型,不是闸瞎。** 换成 `lib/__lint-freeze-probe.ts` 立刻变红。
☞ **这正是"注入证明"存在的理由:** 没有它,我会交回一道自己从没见过它咬人的闸,
  而它对**新建的 `.mjs` 违规**到底红不红,今天仍然会是一个没人问过的问题。

#### ★ warning 那一半也单独证过(R2 的整个理由就在这里)

再注入 `lib/__lint-freeze-warnprobe.ts`(一个未使用的 `const`,**只出 warning**):
```
CHECK_LINT_OWN_EXIT=1
✗ lib/__lint-freeze-warnprobe.ts  @typescript-eslint/no-unused-vars  error 0 · warning 1
✗ 总数上升:error 42→42 · warning 88→89
```
**error 一个没动,闸照样红。** 若按只冻 42 的做法,这一格是绿的 ——
而 `no-unused-vars` 正是这棵树上最大的那一类(63 个)。两个探针都已删除。

### 4.4 什么东西让两个数升不上去

闸红的三个条件,任一成立即 `exit 1`:

1. **出现基线里没有的【文件 + 规则】组合**(新文件、老文件犯新规则,都落这里);
2. **某个【文件 + 规则】的 error 或 warning 计数比基线大**;
3. **总数上升** —— `error` 与 `warning` **各判各的**,任一上升即红。

变少则打印出来并提示 `--update-baseline` 收紧。**基线只会缩短。**

★ **这个口径【已知的洞】,写在脚本抬头而不是等人踩:**
同一文件、同一规则里,**一处被修好 + 一处被新加(净额为零)**,闸看不见。
键取【文件 + 规则】而不是行号是刻意的 —— 行号随每次编辑漂,
**一道天天假红的闸三刀之内会被人关掉**,那比这个洞贵得多。

### 4.5 **那 42 个,一个都没有修**

冻结与修复是两件事;混在一起,绿灯两件事都证明不了。

---

## 5 · 队列补正(R4)—— 只动了两处,别的一个字没动

`docs/forward-queue.md`:**+31 行 / −4 行,两个 hunk**(`@@ -3085 @@` 与 `@@ -3107 @@`)。

| 做了什么 | 具体 |
|---|---|
| **改名 + 划掉** | `### ⬜ ALERT-2c · 权限与状态混在一个布尔里的控件` → `### ~~ALERT-2c …~~ —— 其实是 ALERT-2d 做的,已完成 2026-09-09`,并加一段【编号更正】说明:本条描述的是 `559da63` **ALERT-2d** 落地的东西 |
| **正文原样留着** | 那段开工前的量与判据**一个字没改** —— 它是证据;收工的四个数指去 `ALERT-2d-round2.md` §2.4 |
| **触发条件划掉** | `~~无前置~~` → **已由 ALERT-2d 落地**;并写明 `DBLOCK-CONFLATED-BOOLEANS` 一个字没删、删除条件虽已满足但**要不要收掉是 Tim 的裁定** |
| **新增** | `### ~~ALERT-2c · 六条死词条,以及两处…硬删~~ **已完成 2026-09-08**`(`e04feec`)—— 它此前在本文件里**一个字都没有** |

**没有做的:** 没有重编任何无关条目的号,没有整理,没有改写任何"只是不整齐"的条目。
diff 只落在上面那两个 hunk 里。

### ★ 一件我【没有】自作主张的事

**PERM-CODE-1 与 LINT-FREEZE-1 这一刀本身,仍然不在队列上。** 委托书 R4 精确列了三件
补正,加一条新条目在那三件之外,所以我没有加 —— 而这恰好把 R4 要治的那个形状
(仓库跑在队列前面)**又制造了一次**。**要不要补,是你的裁定。**

---

## 6 · 我自己定的(都是细节,不是形状)

1. **新 prop 叫 `canCapitalise`,不叫 `canEditFinance`** —— 按控件命名,与它守的那个动作同名。
2. **`page.tsx` 里没有新建变量**,直接 `canCapitalise={canEdit}`(`:49` 那个 finance 布尔),
   并在调用点上方写了注释说明这两个布尔为什么不同名。**新增取数:0。**
3. **注释按房内密度写**:四处改动各自带了"为什么"(强制在哪、为什么内层是净损失)。
4. **加了 `npm run check:lint`** 单跑入口,与另外 21 支 `check:*` 一致。
5. **闸放在 `check-confirm-subject` 之后、`next build` 之前** —— 与其余 21 支同段。
6. **探针文件放 `lib/`**,不放 `app/`:`app/` 下多一个 `.ts` 会被路由扫描看见。两个都已删除。
7. `scripts/check-lint.mjs` 用 **ESLint Node API**(不是 `npx eslint --format json`):
   省一次进程启动,且与 `npm run lint` 读同一份 `eslint.config.mjs`。

---

## 7 · 走查 —— 点哪里,以及**要用哪个角色**

★ **本刀只对"持一个权限、不持另一个"的人可见。用 admin 走完全看不出区别** ——
admin 两个码都有,四道闸全部放行,屏幕和改前一模一样。

线上角色与这两个码的对应(实测 `roles ⋈ role_permissions`):

| 角色 | `module.processing.edit` | `module.finance.edit` |
|---|---|---|
| `admin` · `gm` | ✔ | ✔ |
| **`operations`** · **`cco`** | **✔** | ✘ |
| **`finance`** | ✘ | **✔** |
| `auditor` · `cfo` · `hr` · `procurement` · `sales` · `warehouse` | ✘ | ✘ |

### 7.1 走得出来的那一半 —— 保养那两道闸

**去:** `/finance/assets/a1560d88-de19-40fe-b78b-3bfa4079762b`
(**`FA-2026-0001`**,线上唯一有保养记录的设备,**2 条**)。

* **用 `finance` 角色**(有 finance、没 processing):
  「保养与维修」标题旁的【新增】钮**看得见、按不动**,旁边那行现在写
  **`module.processing.edit`**。
  ★ **这就是本刀要你看的那一格** —— 改前它写的是 `module.finance.edit`,
  **而这个角色正好持有那个码**:一句叫他去要一样他早就有的东西的话。
* **用 `operations` 或 `cco`**:【新增】钮正常可用(他们确实有 processing.edit)。

### 7.2 ⚠️ 走**不**出来的那一半 —— 资本化那两道闸,**线上没有可走的行**

**别去点,会白跑。** 资本化那一格要三个记录状态同时成立
(`capitalised` ✓ · 未资本化过 ✓ · **机器已投用**),而线上:

```
fixed_assets:  FA-2026-0001  in_service_date = NULL   (2 条保养,其中 1 条已标资本化)
               FA-2026-0002  in_service_date = NULL   (0 条保养)
```

**两台设备的 `in_service_date` 都是空的**,所以那一格今天渲染的是
`equipment.maint.capNotInService`(「未投用」)那句话,**不是按钮** ——
无论你用哪个角色。于是:

* `:457` / `:500` 那两道 finance 闸 **今天在线上走不出来**;
* §3 那条「finance 角色现在看得见这个钮了」的改进,**同样走不出来**。

**要走它,先给 `FA-2026-0001` 填一个投用日**(设备页上的"计划投用/投用日"),
之后用 **`operations`** 角色去看那个钮:应当**看得见、按不动**,并写着
`module.finance.edit`。**这一步需要你先造数据,所以我没有替你做。**

### 7.3 一件我查不到的事

**我没能列出"今天线上各角色分别挂在谁头上"** —— 那条 `user_roles` 查询
在本次会话里被拦下了两次(auto-mode 分类器)。角色→权限的对应表(上面那张)是量到的;
**谁持哪个角色请在 Settings → Roles 里看。**

---

## 8 · 收尾

### 8.1 `db/gate.py` —— **它自己的退出码,以及四条判词逐字**

```
GATE_OWN_EXIT=0        ELAPSED_S=571     (门自己报的 wall-clock 452s)
```
判词四条,**逐字**:

```
判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)
判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)
判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)
判词【匿名面】:✓ 线上是基线的子集(基线 327 条)
```

附带值得记一句的两格:`NO DIFFERENCES — the rebuild matches live ✓`;
`check_grants` 的注入自检**两格都变红**(它自己证明了自己没瞎)。
本刀没有动任何 SQL,所以门是**回归**用的,不是验收新迁移用的。

### 8.2 `npm run build`

```
BUILD_OWN_EXIT=0
```
新闸在构建链里跑到了,输出逐字:
```
── eslint 冻结闸 ─────────────────────────────────────────────
基线  error 42 · warning 88
现在  error 42 · warning 88

✓ 没有新增的 eslint 问题。
```

### 8.3 部署 —— **推了,到了,两个问题分开问过**

> ★【补记,2026-09-09】本节原本写着「推不了」。`git push` 第一次在会话里
> **被 auto-mode 分类器拦下**,按委托书 §9 **没有试任何变体**,把原样的命令
> 交回;Tim 在对话里重新下达之后**当场就过了**。
> ☞ 这与 `evoltrya-db-access` 记的 ANON-0(2026-09-07)逐字同形:
> **一次拦截不是一条长期拒绝** —— 本地提交、把那一行交回、他递回来时再跑。

```
b3ef1de..abdd179  main -> main
```
**推送是【fetch 之后比哈希】确认的,不是读 push 那几行输出确认的**
(那次 `PIPESTATUS` 取空了,而一个取空的退出码不是一个成功的退出码):
`git rev-parse origin/main` = `abdd1795de4f75407b02fb988a07d83f7f3225b6`,ahead 0。

**两个问题【分开问】(委托书 §9),不是一个问题问两遍:**

| 问题 | 怎么问的 | 答案 |
|---|---|---|
| ① 存在一次成功的部署吗 | `gh api …/deployments/6340509017/statuses` | **`state=success`**,`2026-09-09T01:21:46Z` = **09:21:46 CST** |
| ② 那次部署的 sha 是不是这一刀 | `gh api …/deployments/6340509017` | `sha` = **`abdd1795de4f75407b02fb988a07d83f7f3225b6`**,`environment=Production` |

| | |
|---|---|
| 部署 id | **6340509017** |
| sha | `abdd1795de4f75407b02fb988a07d83f7f3225b6` |
| success 时刻 | **2026-09-09 09:21:46 CST** |
| URL | `https://new-era-ar1fb78jr-tim-s-projects7.vercel.app` |

`scripts/wait-for-deploy.sh` 自己的退出码 **0**,等了 **161s** 部署记录才出现
—— 在它 900s 的上限之内,也再次印证 AGENTS.md 那条:**那份登记是下游的,会滞后。**

★ **本刀【没有破窗】。** 破窗的定义是「生产跑着旧代码、对着新库」,
而本刀**一条 SQL 都没有、没有迁移、库一个字节都没动**。
未推送期间唯一的后果是那四道闸的修复还没上线,不存在任何不一致状态。

推完之后,部署那两个问题**要分开问**(委托书 §9),仓库里已有现成的机制:

```
scripts/wait-for-deploy.sh          # 等 HEAD;它自己补全 40 位 sha、判据就是 state=success
                                    # 失败时退 4 而不是耗光上限
```
然后**第二个问题单独问一遍**(存在一次成功的部署 ≠ 那次部署是这一刀):

```
gh api repos/:owner/:repo/deployments --jq '.[0] | {id, sha}'
gh api repos/:owner/:repo/deployments/<id>/statuses --jq '.[0] | {state, created_at}'
```

**为什么这一次【没有破窗】,而不是"破窗还开着":**
破窗的定义是**生产跑着旧代码、对着新库**。而本刀
**一条 SQL 都没有、没有迁移、库一个字节都没动** ——
所以未推送的后果只有一个:**那四道闸的修复还没上线**,
线上今天仍然对 `finance` 角色说「去要 module.finance.edit」。
**没有任何东西因为这次未推送而处于不一致状态。**

☞ 一并交回的还有 §7.3 那一件:`user_roles` 的持有人查询在本次会话里
**被同一个分类器拦了两次**,所以「今天谁挂着 operations / finance 角色」
这一格我**没有数据**,请在 Settings → Roles 里看。
