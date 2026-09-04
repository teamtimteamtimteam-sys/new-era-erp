# NAV-REG-1 —— 一个功能可以属于好几个模块

**日期** 2026-09-01 · **前一刀** IA-0(`bbbe455`)· **下一刀** Phase 8(视觉重建)

Tim 的裁定:**一个功能可以出现在好几个模块底下,只要数据不重复。**
一个产出批次既是加工的结果、也是可售的库存 —— 它出现在两处是对的。
IA-0 量到:这件事今天**只能在注册表之外**表达(在每个属主模块的页面里手写一个
链接),而手写的链接与权限之间**没有任何东西保证同步**。两个例外可以容忍;
一条通则需要一个机制。本刀造那个机制。

---

## ★ CONV-7 ①(2026-09-04):工具从**四条**变成**五条**

**任务 · 日历 · 单位换算 · 提醒 · 定价。**
新增 `{ href: '/tools/reminders', navKey: 'reminders.title', modules: ['tools'],
permission: { all: [] } }`。

**判据【刻意】恒真,与 `/tools/calendar` 逐字同理** —— 那一页没有自己的权限模型,
34 支各按**自己家**那个模块的可见性出现或不出现。给这一条挂一个模块码,就等于替
34 支各不相同的判据挑一个代表:挑谁都错(挑 finance,一个只做仓库的人就看不见
他自己的盘点提醒;挑得宽,菜单上会出现一条点进去空空如也的条目)。
**本条不挡人,挡人的是每一支** —— 一个进得来却一支都看不见的读者,拿到的是一句
**具名的话**,不是一张白页。

**排在定价之前**,因为定价是这份菜单里唯一一条**自己还带着孩子**的条目
(`/pricing` 那一页列出公式 / 计价器 / 金属行情),把一条平的条目插在它后面
会读成它的第四个孩子。

**「菜单有没有地方假设它是四条」—— 查过了,没有。** `ModuleBar` 逐条渲染、
`ScrollPanel` 自带「还有 N 条」、`lib/moduleAccess.ts` 的分组按 `MODULE_GROUPS`
表算。唯一值得记一笔的是 `MODULE_GROUPS.tools` 里那个**空的**
`tools.group.pricing`(CONV-0 ②a 之后没有条目属于它)—— 渲染层的「空组不渲染」
把它滤掉,所以工具画成平铺的五条。

> **CONV-6 尚未落地**(2026-09-04 实测:`HEAD == origin/main == 08a5857`,
> 即 CONV-5e)。委托里「确认 CONV-6 改过菜单之后二级仍然正常」那一条**没有主语**。

---

## 一、谓词

`ModuleEntry.permission` 从"一个字符串"变成一个谓词(`lib/modules.ts`):

```ts
export type PermissionSpec =
    | string                                   // 绝大多数模块:一个码
    | { all: readonly string[]                 // 必须全部持有
        any?: readonly string[]                // 还必须任一持有  —— 与 all 相与(收窄)
        widen?: readonly string[] }            // 持有其一即可替代 all —— 与 all 相或(放宽)
```

### 这个形状不是新发明的 —— 它已经在库里跑了

这一点是本刀最重要的一条发现,它决定了整把刀的大小。**同一套三算子代数在这个仓库里
已经存在两份**,而且是**故意**保持同形的:

| 在哪 | 长什么样 |
|---|---|
| 数据库 | `(has_permission(permission) OR has_any_permission(arm_permission_widen(t)))`<br>`AND (arm_permission_any(t) IS NULL OR has_any_permission(arm_permission_any(t)))` |
| 首页看板 | `app/page.tsx` 的 `permission` / `permissionAny` / `permissionWiden` 三个字段 |

再拼第三种方言,就是 OPS-15 与 EQP-2d 存在的全部理由。所以本刀**沿用**它。

### AND 不是假想的需求

`/margin` 的判据是 `data.view_prices AND (module.finance.view OR module.processing.view)` ——
**一个 AND、一个 OR,两个都是真的**。一个只支持 OR 的形状,恰恰表达不了那个
促成本刀的案例。

---

## 二、求值只有一处

**`lib/modules.ts` 的 `allows(spec, perms)`。除它以外,全站没有任何地方拿权限码去比对
一份权限清单。**

三个消费方全部调它:

| 消费方 | 做什么 |
|---|---|
| `lib/moduleAccess.ts` | `getModuleAccess()` / `canEnter()` / `getFunctionAccess()` —— 取权限码,交给 `allows()` |
| `app/components/moduleGuard.tsx` | `requireModule` / `requireFunction` —— 页面守卫 |
| `app/page.tsx` | 看板每块牌子 —— **本刀把它内联的那三行判断搬走了** |

### 为什么最后一条是本刀的重点

EQP-2d 实测过两份实现漂开的后果:库里的视图加了放宽(`arm_permission_widen`),而首页
那一份判断没跟上,于是一个**拿得到行**的读者在屏幕上看见「受限」——
**把"你看得见"说成"你看不见"**。看板那条"缺席 ≠ 零"的规矩防的是另一个方向,
这一个此前没有人防。一条规则两个实现,迟早各错一次。

`scripts/check-permission-predicate.mjs` 把这条钉死:任何文件(除 `lib/modules.ts`)
里出现 `perms.includes(` 一类的写法,`npm run build` 就红。

---

## 三、一个功能属于几个模块:`FUNCTIONS`

```ts
export type FunctionEntry = {
    href: string
    navKey: string
    modules: readonly string[]     // 属主模块的 href,长度可以 > 1 —— 这就是那句话的机制
    permission: PermissionSpec     // 唯一的一份判据
}
```

每个属主模块的界面调 `getFunctionAccess('<模块 href>')` 画自己名下的功能;
`/margin` 自己那一页调 `requireFunction(FN.margin)`。**两者读的是同一条注册表条目。**

### 3d:哪一份是权威的

**注册表是权威的。页面这一侧靠【不表达】来服从** —— 页面守卫不写判据,它把注册表条目
整个接过来(`requireFunction(FN.margin)`)。于是"谁看得见这个入口"与"谁进得去这一页"
是同一个表达式,不可能各错一次。

`/margin` 从前在页面里写两道守卫(`requireAnyModule` + `requireDataClass`),
也就是把那个谓词**抄了一遍**。现在两句拒绝的措辞与先后一字未改,但它们是从
**同一个谓词的两半**推出来的:`any` 那一半(模块)不满足说「你没有进入该模块的权限」,
`all` 那一半(数据类)不满足说「这个数字属于价格信息」。

### 迁移了哪两个

| | 从前 | 现在 |
|---|---|---|
| `/margin` | 财务子导航 + 加工页头**各一个手写 `<Link>`**;页面自己 `requireAnyModule` + `requireDataClass` | 声明 `modules: ['/finance','/processing']`;两处入口都由 `getFunctionAccess` 派生;守卫 `requireFunction(FN.margin)` |
| `/deleted` | 导航条里一个**无条件**的链接,页面**完全不把关** | 声明六个属主模块与"六码任一"的谓词(取自视图每行自带的 `permission`);导航项与守卫同源 |

`app/output/[id]/edit` 上那条「查看全部批次毛利」是**上下文交叉引用**,不是模块入口 ——
措辞是那一处的话,所以标签不从注册表取;但**地址**改成了 `FN.margin.href`,不再写死。

---

## 四、三个修复

### R2 · 物流有了自己的码

`module.logistics.view` **此前根本不存在** —— 不在权限目录里,不在任何迁移里,
只在三处注释里被许诺过。IA-0 把这次改动记成"一行",**那是错的**:

- 把门的不是 `lib/modules.ts` 那一行,是 **8 张表**的 RLS(旧注释只点名了 5 张:
  还有 `containers` / `container_documents` / `container_milestones`);
- 还有**看板 4 支**(`free_time_expiring` / `container_no_arrival` /
  `container_eta_overdue` / `container_documents_late`)与 `arm_permission_widen`。
  只换表不换支,就是 EQP-2d 那个谎的重演;
- `po_awaiting_receipt` **不换** —— 它读 `purchase_orders`,那是真的采购。

**读换、写不换。** 8 张表的写策略仍然要 `module.purchasing.edit`:持有它的四个角色
(admin / finance / gm / procurement)全都在授予名单里,所以没有"改得动、读不回"的
倒挂;而铸一个没有任何策略引用的 `.edit` 码,就是铸一个死码。

**授予 9 个角色,扩大三家、缩小零家:**

| | 角色 | 之前 | 之后 |
|---|---|---|---|
| 今天就进得去(持 `purchasing.view`) | admin · auditor · cfo · finance · gm · procurement | 可见 | 可见 |
| Tim 点名的受害者 | **operations · warehouse · sales** | 不可见 | **可见** |
| 不授予 | hr · employee | 不可见 | 不可见 |

`sales` 是 IA-0 没点到的第三个受害者(它同样不持 `module.purchasing.view`)。

### R3 · 设置为几个角色渲染成空 —— **已移出本刀**

**我的 brief 在这一条上是错的,Tim 确认并把它移走了。**

「设置」**不是一个模块**:没有 `app/settings/page.tsx`,`MODULES` 里也没有它。它是
`TopNav` 里三个各自判权限的导航项。所以它**不会渲染成空,它渲染成缺席**,而 R4
(讲的是 `MODULES` 条目)够不到它。

而且数目也不对:**没有任何设置入口的角色是五个,不是三个** ——
`sales` / `hr` / `auditor` / **`cfo`** / `employee`。IA-0 漏掉的是 **cfo**,
而 cfo 是仅有的三个**有真实用户**的角色之一。

每一种"修好它"的做法都要铸一个码并挑授予对象,而那是 Tim 保留给自己的裁定。
**记在开户前那一刀的权限设计里,本刀不建任何一部分。**

### R4 · 进不去的模块是一条具名的限制,不是一处缺席

**`getVisibleModules` 从【过滤】变成了【标记】,现在叫 `getModuleAccess`,
它返回【全部】模块,每个带一个 `allowed`。**

> **下一个读到这里的人:不要把过滤加回来。返回全部不是遗漏,是这一刀的内容本身。**
> `scripts/check-permission-predicate.mjs` 会因为 `MODULES.filter(` 变红。

措辞沿用既有的那一套:`common.restricted`(「受限」)+ `dashboard.restrictedHint`
(「需要相应模块权限」),与首页牌子上那两行逐字相同 —— 同一个意思的第二套说法,
就是下一次漂移的种子。渲染带 `data-module-restricted="1"` 机器标记,理由与
`moduleGuard` 的 `data-access-denied` 相同:认文案字符串漏过一次就是一次误报。

**披露面:** 一个零模块权限的人现在看得见全部 15 个模块名。经查没有任何模块的**名字**
本身是秘密(权限参考页早已把整份目录摊开)。唯一值得记一笔的是 HR ——
看见「人力资源 · 受限」的人知道了公司在这套系统里发薪。这不是秘密,**记录在案而不作处理**。

### 逐角色实测:导航条上到底出现什么字

求值器是 `lib/modules.ts` 的 `allows()` **本身**(探针直接 import 它,不重写 ——
否则探针就成了第三份实现);权限集取自 **live 的 `role_permissions`**;文案取自
`messages/zh.ts`。受限文案「受限」,悬停提示「需要相应模块权限」。

| 角色 | 模块可进 | 导航条上的受限项(逐字) | /deleted | /margin |
|---|---|---|---|---|
| admin · auditor · gm | 15/15 | (无) | 可进 | 可进 |
| cfo | 3/15 | 供应商 · 受限 \| 客户 · 受限 \| 物料 · 受限 \| 定价 · 受限 \| 进料 · 受限 \| 产出 · 受限 \| 加工 · 受限 \| 库存 · 受限 \| 盘点 · 受限 \| 销售 · 受限 \| 任务 · 受限 \| 人力资源 · 受限 | 可进 | 可进 |
| finance | 11/15 | 加工 · 受限 \| 盘点 · 受限 \| 销售 · 受限 \| 人力资源 · 受限 | 可进 | 可进 |
| **operations** | 8/15 | 供应商 · 受限 \| 采购 · 受限 \| 客户 · 受限 \| 定价 · 受限 \| 销售 · 受限 \| 财务 · 受限 \| 人力资源 · 受限 | 可进 | 批次毛利 · 受限 |
| **warehouse** | 6/15 | 供应商 · 受限 \| 采购 · 受限 \| 客户 · 受限 \| 物料 · 受限 \| 定价 · 受限 \| 加工 · 受限 \| 销售 · 受限 \| 财务 · 受限 \| 人力资源 · 受限 | 可进 | 批次毛利 · 受限 |
| **sales** | 8/15 | 供应商 · 受限 \| 采购 · 受限 \| 进料 · 受限 \| 加工 · 受限 \| 盘点 · 受限 \| 财务 · 受限 \| 人力资源 · 受限 | 可进 | 批次毛利 · 受限 |
| procurement | 8/15 | 客户 · 受限 \| 产出 · 受限 \| 加工 · 受限 \| 盘点 · 受限 \| 销售 · 受限 \| 财务 · 受限 \| 人力资源 · 受限 | 可进 | 批次毛利 · 受限 |
| hr | 2/15 | (13 项,含 物流 · 受限) | 已删除记录 · 受限 | 批次毛利 · 受限 |
| employee | 0/15 | **全部 15 个模块名,每个带「· 受限」** | 已删除记录 · 受限 | 批次毛利 · 受限 |

**「物流」不在 operations / warehouse / sales 的受限清单里 —— 那正是 R2 要买的东西。**
在这之前,那三个角色的导航条上【连"物流"这两个字都没有】。

`employee` 那一行是 R4 的全部意思:一个零模块权限的人,从前看见的是一条**空导航**
(与"系统坏了"分不开),现在看见的是 15 个他进不去的模块**各自的名字**。

### 本刀改变了什么、没有改变什么(逐角色)

| | 结果 |
|---|---|
| 15 个模块的可进性 | **物流对 operations / warehouse / sales 从"不可见"变"可见"**;其余 14 个模块 × 11 个角色**一格未动**;**没有任何一格变小** |
| `/margin` | **11 个角色逐一比对,全部不变** —— 谓词与迁移前逐字同形 |
| `/deleted` | 9 个角色不变;**hr 与 employee 从"一张空表"变成"一句具名拒绝"**(两种情况下都是零行 —— 变的是它有没有把原因说出来,那正是 R4) |

### 稳定别名上的实测(不是每次部署那个 URL)

**验证陷阱**:`wait-for-deploy.sh` 印的是【每次部署】的 URL,它在 Vercel Deployment
Protection 后面 —— 实测 `curl` 它得到 **302 → `vercel.com/sso-api`**,于是任何针对它的
内容断言都会【空过】。所以以下全部取自稳定别名 `https://new-era-erp.vercel.app`
(docs/day-2-setup-notes.md:91)。

做法:用 service key 铸一个短命账号、授一个角色、登录拿 cookie、带着 cookie 取首页,
**读完就删,并且验证删干净了**(user_roles 残留 0 行 · auth 账号查不到 ✓)。

**operations(本刀让它看得见物流的那个角色)—— HTTP 200,导航条逐项:**

```
受限项  「Suppliers」    链接  「Materials」     链接  「Inventory」
受限项  「Purchasing」   链接  「Inbound」       链接  「Stocktakes」
受限项  「Customers」    链接  「Output」        链接  「Tasks」
受限项  「Pricing」      链接  「Processing」    链接  「Logistics」   ← R2
受限项  「Sales」        受限项「Finance」       链接  「Deleted records」
受限项  「HR」
```

物流那一项的原始 HTML —— 它是一条**可点的链接**,不是受限项:

```html
<a class="whitespace-nowrap rounded px-3 py-1 text-sm text-gray-600 hover:bg-gray-100 hover:text-gray-900"
   href="/logistics/forwarders">Logistics</a>
```

**employee(一个模块权限都没有)—— HTTP 200,16 个 `data-module-restricted` 标记:**

> Suppliers · Restricted ｜ Purchasing · Restricted ｜ Customers · Restricted ｜
> Materials · Restricted ｜ Pricing · Restricted ｜ Inbound · Restricted ｜
> Output · Restricted ｜ Processing · Restricted ｜ Inventory · Restricted ｜
> Stocktakes · Restricted ｜ Sales · Restricted ｜ Finance · Restricted ｜
> Tasks · Restricted ｜ HR · Restricted ｜ Logistics · Restricted ｜
> **Deleted records · Restricted**

**这一行就是 R4 的全部意思**:在这之前,一个零模块权限的人看见的是一条**空导航**
(与"系统坏了"分不开);现在他看见 15 个模块**各自的名字**,以及每一个都对他关着。
第 16 项是 `/deleted` —— 它由 `FN.deleted` 判,与模块用的是同一个求值器。

> 【为什么引文是英文】探针账号没有语言偏好,渲染走了 en。键是同一个
> `common.restricted`,zh 的值是「受限」(见上一节逐角色表)。

### 冒烟

| 跑法 | 判词 | 说明 |
|---|---|---|
| `--reach`(按角色可达性) | **`SMOKE_EXIT=124`** | **超时被杀,不是通过。** admin 与 operations 两个角色的【走】与【试开】两阶段都跑完了,finance 死在【走 5/50】。90 分钟上限。 |
| 普通冒烟(第一次) | `SMOKE_EXIT=1` | 1 条失败:`/hr/employees/[id]` 试用期入口 HTTP 503,原因是 `ECONNRESET` —— 网络层瞬时故障 |
| 普通冒烟(重跑) | **`SMOKE_EXIT=0`** | **231 ok · 8 skipped(无数据)· 0 FAILED** |

`--reach` 那一跑虽然没跑完,但它给出了 R2 最直接的证据:**operations 通过产品自己的
链接走到了 6 条 `/logistics/*` 路由** —— 本刀之前那个数是 0,因为那一项在它的导航条上
根本不存在。

> **它还抓到一条与本刀无关的真缺陷,记在这里而不是修在这一刀里:**
> `app/finance/claims/page.tsx:18` 与 `app/finance/cash-forecast/page.tsx:23`
> 都写着 `await requireModule(MOD.finance)` 而**没有接住返回值** ——
> 正确写法是 `const denied = await requireModule(…); if (denied) return denied`。
> 拒绝页被算出来又被丢掉,于是**谁都打得开这两页**。
> 两处分别来自 `3afde1d`(CLAIM-1)与 `c9aac03`(CASHFLOW-1),都是 2026-08-28,
> **早于本刀四天**,本刀一个字都没碰过这两个文件。
> 数据没有泄露(RLS 仍然挡着,无权的人看到的是空的),但"你进不来"被渲染成了
> "这里没有东西" —— 那正是 moduleGuard 存在的全部理由。
> **修它要一把自己的刀**:两行改动,外加在 `check-permission-predicate.mjs` 里加一条
> 不变量,让"丢掉守卫返回值"过不了 build。

---

## 五、删掉的死代码

`SECTIONS` · `ModuleEntry.section` · `titleKey` · `descKey` · `moduleForPath` · `alsoCovers`
—— 以及 `messages/{zh,en}.ts` 里随之失去读者的 34 个 `home.*` 键,
和两个**被本刀自己变成死代码**的东西:

- `requireAnyModule` —— 它问"任意一个模块",而那正是 `FUNCTIONS` 现在表达的东西;
  留着就是同一句话的第二种说法。
- `requireDataClass` —— 它此前**只有一个调用者**,就是 `/margin` 的第二道守卫。
  `requireFunction` 取代了那两道,于是它零调用者。**它表达的区别一个字都没丢**:
  模块拒绝与数据类拒绝的两句措辞就在 `requireFunction` 里,由谓词的两半决定用哪一句。

旧抬头写着"导航条与首页卡片从此读同一份数据"。**OPS-18 之后那句话就不成立了** ——
首页早就不渲染模块卡片,改成了运营看板。

> **IA-0 的字段盘点表把 `moduleForPath` 记成【活】,而它一次都没有被调用过。**
> 一张表说某样东西在用,不是它被调用的证据。`alsoCovers` 是它的唯一读者,
> 所以也是死的。
>
> `alsoCovers` 承载的**信息是真的**(`/contracts` 与 `/commissions` 归供应商模块),
> 那句话作为注释留在了 `MODULES` 里 —— 但**不作为字段**。
> **一个没有读者的字段,是下一个人据以断定"这里已经接好了"的东西。**

---

## 六、Phase 8 现在能在这份注册表里表达什么

| Phase 8 要的 | 注册表已经有的 |
|---|---|
| 侧栏 / 顶栏的模块目录 | `getModuleAccess()` —— 全部模块 + `allowed`,进不去的画成「受限」而不是消失 |
| 一个功能挂在好几个地方 | `FUNCTIONS[].modules` + `getFunctionAccess(模块)` |
| 财务第三级 | `getFunctionAccess('/finance')` 已经在 `app/finance/Subnav.tsx` 里跑;顺序仍然归 Phase 8 |
| 面包屑 | **还缺**:`moduleForPath` 已删(它没有调用者)。要按路由反查模块,Phase 8 得**新造**一个,并且这次要**有调用者** |
| 可编辑的 dock | 判据全部来自注册表,dock 只需要存"哪几个 href",可见性照旧问 `allows()` |

**本刀不建其中任何一样**(Tim 的 R5)。

---

## 七、门

- `npm run build` 新增 `scripts/check-permission-predicate.mjs`:求值一处 / 跨模块声明 / 具名受限,三条各自故障注入验证过会红。
- `db/fixtures/185-*.sql`:物流那道门,五臂(A 读得到 · B 旧钥匙零行 · C 无关角色零行 · D 写仍被拒 · E 看板四支换码而采购那一支不换),三处故障注入验证过会红。

---

## 八、UI-FIX-1(2026-09-02)—— 五条搬家之后,逐角色的实测

**搬家的完整叙述在 `docs/information-architecture.md` §13。这里只放【判据与数字】。**

### 8.1 判据:为什么"谓词没改"不算证明

谓词确实一个字没改,但**入口是由属主模块渲染的**,而拒绝是由 `requireFunction`
判的。两者若不同源,「摆放收窄」就会悄悄变成「访问收窄」——
本仓库对这一族已经付过账(OPS-15:一条规则两个实现,迟早各错一次)。

所以本刀的判据是**逐角色、逐条目、对着 live 授权求值**,而且求的是**两个不同的
问题**,因为它们的答案不一样:

* **打得开吗** = `allows(条目的谓词, 这个角色的权限)`;
* **走得到吗** = 打得开 **AND** 它至少有一个属主模块是进得去的
  ——【**后者才是搬家会动到的那个**】。

> ★【这里的"走得到"是【人】的走得到,而它与冒烟 `--reach` 量的【不是同一个东西】★
> 本节的模型是「顶栏 → 点开那个模块的菜单 → 点那一条」,**那正是人的走法**。
> 而 `scripts/smoke-routes.mjs --reach` 只跟着**服务端 HTML 里已经存在的**链接走,
> 而**顶栏的模块菜单是点开才渲染的**(`ModuleBar` 的 `{isOpen && …}`)——
> **于是整个第二级对那个爬虫都是不可见的**,它靠 dock + 各模块自己的 `Subnav`
> + 页内链接扩散。**两个数因此可以合法地不一致**,而本刀实测到了一次:
> `/metal-prices` 对 `operations` 在本节的模型里【走得到】(工具菜单里有),
> 在 `--reach` 里【走不到】(那张菜单不在 HTML 里)。
> **两者都没有错,它们量的是两件事。** 详见 `docs/information-architecture.md` §13.5 ——
> 本刀正是因为把这两件事当成了一件,先删错了一条断言。

`roles` / `role_permissions` 取自 live(2026-09-02),11 个角色的完整权限集;
两份 `lib/modules.ts`(搬家前 / 搬家后)同时 import,同一支脚本跑出下面两张表。

### 8.2 ★ 逐角色【走得到的二级条目】:唯一的损失是 `/deleted` ★

| 角色 | 走得到的条数(前 → 后) | 走不到了 | 新走得到 |
|---|---|---|---|
| admin | 76 → 76 | (无) | (无) |
| auditor | 72 → 71 | **`/deleted`** | (无) |
| cfo | 39 → 38 | **`/deleted`** | (无) |
| employee | 1 → 1 | (无) | (无) |
| finance | 56 → 55 | **`/deleted`** | (无) |
| gm | 73 → 72 | **`/deleted`** | (无) |
| hr | 12 → 12 | (无) | (无) |
| operations | 18 → 17 | **`/deleted`** | (无) |
| procurement | 22 → 21 | **`/deleted`** | (无) |
| sales | 18 → 17 | **`/deleted`** | (无) |
| warehouse | 13 → 12 | **`/deleted`** | (无) |

> ★★ **在全部 11 个角色 × 76 条条目上,唯一走不到的东西是 `/deleted`** ——
> 而那是 Tim 明令的那一条。★★
> **`/margin` 与 `/inventory/reports` 的"权限不变"因此不是一句断言,是这张表的一行:
> 每一个从前走得到它们的角色,现在仍然走得到,只是从另一个菜单进。**

**逐页的"打得开吗"(与属主无关的那一半),前后逐字相同:**

| 路由 | 打得开的角色(前后**完全一致**) |
|---|---|
| `/margin` | admin auditor cfo finance gm(**5**) |
| `/inventory/reports` | admin auditor finance gm operations procurement sales warehouse(**8**) |
| `/metal-prices` | **11 个角色全部**(`{ all: [] }`) |
| `/pricing` | admin auditor finance gm procurement sales(**6**) |
| `/inbound` | admin auditor finance gm operations procurement warehouse(**7**) |
| `/tasks` | admin auditor finance gm hr operations procurement sales warehouse(**9**) |
| **`/deleted`** | **前 9 个 → 后 1 个(admin)** ← 唯一变化的一行 |

### 8.3 `/margin` 的那次合成探针 —— 以及【live 上没有那个角色】

Tim 要求「拿一个真角色探一次:一个只持有加工权限、带 `view_prices` 的人,
搬家之后仍然打得开 `/margin`」。

> ★【必须先照直说的一件事】★ **live 上今天【没有】这个形状的角色。**
> 实测 `role_permissions`:同时持有 `module.processing.view` 与 `data.view_prices`
> 的角色只有 **admin / auditor / gm** 三个,**而这三个都【同时】持有
> `module.finance.view`** —— 也就是说,今天没有任何一个角色是靠"加工"那一半
> 通过 `/margin` 谓词的。(`operations` 有加工但**没有** `view_prices`;
> `procurement` / `sales` 有 `view_prices` 但**没有**加工。)
> **所以拿"一个真角色"探这一条是探不出来的 —— 不是没探,是那个角色不存在。**
> 这件事本身值得记:**`/margin` 谓词里"加工"那一半今天【没有任何 live 读者】。**
> (MAR-1 当时写的「没有任何 live 角色同时持有两者」是就 admin/auditor/gm 之外说的,
> 与这里是同一个观察的两面。)

**于是探针分两半,两半都做了:**

1. **合成权限集**(正是 `allows()` 唯一的输入形状):
   `['module.processing.view', 'data.view_prices']`
   → `allows(FN.margin.permission, …)` = **`true`**,搬家前后**都是 `true`**。
2. **谓词字面量逐字比对**:
   * 前:`{"all":["data.view_prices"],"any":["module.finance.view","module.processing.view"]}`
   * 后:`{"all":["data.view_prices"],"any":["module.finance.view","module.processing.view"]}`
   * **属主**:`operation,finance` → `finance`(**只有这一行变了**)

**而这个 `true` 就是页面守卫的答案本身**,不是它的一个近似:
`app/margin/page.tsx` 调的是 `requireFunction(FN.margin)`,它读 `fn.permission`
**整条**接过来求值,**从不看 `fn.modules`** —— 属主只喂菜单渲染。
一个只持有加工 + `view_prices` 的人,搬家之后照样打得开 `/margin`;
**他现在从财务的菜单里看见它。**

### 8.4 ⑦ 的一处【可见的】副作用:哪些模块名从"可进"变成"· 受限"

**页面一个都没丢(见 8.2),但顶栏上"这个模块名点不点得进去"变了。**
原因是**模块可进性是从二级条目推导的**(IA-BUILD-1 §2.2):把一条条目搬走,
它此前**独自撑着**的那个模块就不再有可进的东西了。

| 角色 | 九个里进得去(前 → 后) | 变成「· 受限」的 | 变成可进的 |
|---|---|---|---|
| admin | 9/9 → 9/9 | — | — |
| gm | 9/9 → 9/9 | — | — |
| auditor | 8/9 → 8/9 | — | — |
| finance | 8/9 → 8/9 | — | — |
| **cfo** | 6/9 → **4/9** | 运营 · 销售 · 库存 | **工具** |
| **operations** | 8/9 → **6/9** | 销售 · 财务 | — |
| **warehouse** | 8/9 → **6/9** | 销售 · 财务 | — |
| **sales** | 7/9 → **5/9** | 采购 · 财务 | — |
| **procurement** | 8/9 → **7/9** | 财务 | — |
| **hr** | 4/9 → **2/9** | 采购 · 销售 | — |
| **employee** | 2/9 → **1/9** | 采购 · 销售 | **工具** |

**逐条的因果,不是"大概是这样":**

* **销售 / 采购变「受限」**(cfo · operations · warehouse · sales · hr · employee)
  —— 这些角色此前是靠**金属行情**(判据 `{ all: [] }`,人人可读)撑开那两个模块的。
  行情搬进工具,那根撑杆就没了。**页面没丢:他们现在从【工具】进同一页。**
* **财务变「受限」**(operations · warehouse · sales · procurement)
  —— 这四个角色**没有** `module.finance.view`,此前是靠 **`/inventory/reports`**
  (双属主含 finance)撑开财务的。报表搬回库存,撑杆没了。
  **页面没丢:他们现在从【库存】进同一页**(四个角色都持 `module.inventory.view`)。
* **运营变「受限」**(cfo)—— cfo 此前是靠 **`/margin`**(双属主含 operation)
  撑开运营的。**页面没丢:cfo 现在从【财务】进 `/margin`。**
* **库存变「受限」**(cfo)—— cfo 此前是靠 **`/deleted`**(属主含 inventory)
  撑开库存的。**这一条是【真的丢了页面】**,因为 `/deleted` 的门本身换了(§13.2.3)。
* **工具变可进**(cfo · employee)—— 金属行情搬进来之后,**任何登录用户都进得去
  工具**。IA §7 那条「`employee` 有 2/9 进得去(采购与销售)」的观察**因此过期了**,
  正确的说法是:**`employee` 现在 1/9 —— 工具**,而他在里面**仍然只看得见
  「金属行情」一条可点**,其余写「· 受限」。**观察本身没错,是它挂靠的那个位置搬了家。**

> **★ 这一整节都不是缺陷,是 D5 在正常工作的样子 ★**
> 九个模块名**永远都在顶栏上**,进不去的写着「· 受限」而不是消失 ——
> 所以上表里每一次「变成受限」都是一句**看得见的、具名的**限制,
> 不是一处静默的缺席。**而它背后没有任何一页真的走不到了(唯一的例外是
> `/deleted`,那是明令)。**

### 8.5 本刀跑过的闸(判词全部取自脚本自己打出来的那一行)

| 闸 | 判词 | 数字 |
|---|---|---|
| `npm run build` | **`BUILD_EXIT=0`** | 12 条构建期检查全绿 + `Compiled successfully`;`check-permission-predicate`:**FUNCTIONS 76 条(4 条跨模块)**,求值一处,守卫 4 支 178 处调用都接住了返回值 |
| `check-i18n`(**故障注入验过**)| ✓ | 把 `nav.tools` 改成 `nav.toolsXX` → **红,点名 `lib/modules.ts:176 缺于 en 与 zh`**;改回 → 绿。**这条新键确实被这道闸看着,不是空过** |
| `smoke-routes.mjs`(快的那一半)| **`SMOKE_EXIT=0`** | **234 ok / 8 skipped / 0 FAILED** |
| `smoke-routes.mjs --reach=operations` | **第一跑 `REACHOPS_EXIT=1`(本刀自己改错了断言)· 第二跑 `REACHOPS2_EXIT=0`** | 两跑**走到 186 · 打得开 35 · 走不到 3**,三个数逐字相同 —— 见 `docs/information-architecture.md` §13.5 |
| **数据库那三道闸** | **没跑,而这是判断不是遗漏** | **本刀零 DDL、零迁移**:⑥⑦ 全部在 `lib/modules.ts` 与两份文案里,一行 SQL 都没有。`db/gate.py` 守的是"库能不能从镜像重建",本刀没有碰镜像 —— 跑它只会花掉 183–650 秒去证明一件没有被动过的事 |
| **备份** | **没跑,同一条理由** | `~/evoltrya-backups/backup.sh` 是**迁移前**的那道闸(AGENTS.md:「备份跑完再动库」)。**没有迁移,就没有要回滚的东西** |

**没跑的那两个 `--reach` 角色,照直说:**
`--reach=admin`(实测 ~63 分)与 `--reach=finance`(实测 59分47秒)**本刀没有跑**。
选 `operations` 是因为它**同时**碰到本刀改的三样东西里的两样(`/inbound` 新属主、
`/metal-prices` 换模块),而且是三个角色里最便宜的(实测 25分28秒)。
**它们没跑这件事由 §8.2 那张【逐角色求值】的表补上了一半** ——
那张表覆盖 **11 个角色**(比 `--reach` 支持的 3 个多),但它求的是**人的可达性**,
**不是**爬虫的;两者的区别见 §8.2 的那条方框。**这一条按 AGENTS.md 记进"积压的
reach 债",不假装它已经跑过。**

---

## 九、★【稳定别名上的实测 —— 部署之后,拿 11 个真角色逐个开过】★

> **判据只用稳定别名 `https://new-era-erp.vercel.app`**,不用每次部署那个 URL
> (后者 302 到 `vercel.com/sso-api`,任何断言在它上面都会【空过】)。
> 每个角色一个临时账号,授一个 live 角色,用它自己的会话抓页面,**用完即删**
> (实测收尾:`auth.users` 里 `alias-%@test.local` 剩 **0** 行)。
> 部署:`6226746884`,`state=success` @ `2026-09-02T16:16:00Z`。

### 9.1 顶栏:九个一级模块,逐角色(判据是 HTML 里的机器标记,不是文案)

「可进」= 带 `aria-haspopup="true"` 的按钮;「· 受限」= 带 `data-module-restricted="1"` 的 span。

| 角色 | 可进 | 顶栏上写着「· Restricted」的 | 总数 | §8.4 的预测 |
|---|---|---|---|---|
| admin | 9 | (无) | 9 | 9/9 ✓ |
| gm | 9 | (无) | 9 | 9/9 ✓ |
| auditor | 8 | Settings | 9 | 8/9 ✓ |
| finance | 8 | HR | 9 | 8/9 ✓ |
| procurement | 7 | Finance · HR | 9 | 7/9 ✓ |
| operations | 6 | Sales · Finance · HR | 9 | 6/9 ✓ |
| warehouse | 6 | Sales · Finance · HR | 9 | 6/9 ✓ |
| sales | 5 | Purchasing · Finance · HR · Settings | 9 | 5/9 ✓ |
| cfo | 4 | Operation · Sales · Inventory · HR · Settings | 9 | 4/9 ✓ |
| hr | 2 | Purchasing · Logistics · Operation · Sales · Finance · Inventory · Settings | 9 | 2/9 ✓ |
| employee | **1(Tools)** | 其余 8 个 | 9 | 1/9 ✓ |

**★ 11 个角色的数字与 §8.4 逐个相符,一个都没有偏 ★**
**★ 每一个角色的顶栏上都是【九个】一级 ★** —— 进不去的写着「· Restricted」而不是消失,
D5 在部署系统上按设计工作。**顶栏上已经没有「Tasks」这个一级了,它是「Tools」。**

### 9.2 ★ 三条搬走的页面:真的打开它们 ★

**这才是"权限变没变"的判据。** 拒绝屏认**机器标记** `data-access-denied`,不认文案 ——
而这正是本仓库那条「冒烟只断言 2xx,一个渲染出错误框的页面也是 200」说的东西:
下面每一格都是 **HTTP 200**,区别只在**里面是内容还是一句拒绝**。

| 角色 | `/deleted` | `/margin` | `/inventory/reports` | `/metal-prices` | `/pricing` |
|---|---|---|---|---|---|
| admin | **✓** | ✓ | ✓ | ✓ | ✓ |
| auditor | ✗ | ✓ | ✓ | ✓ | ✓ |
| cfo | ✗ | ✓ | ✗ | ✓ | ✗ |
| finance | ✗ | ✓ | ✓ | ✓ | ✓ |
| gm | ✗ | ✓ | ✓ | ✓ | ✓ |
| operations | ✗ | ✗ | ✓ | ✓ | ✗ |
| procurement | ✗ | ✗ | ✓ | ✓ | ✓ |
| sales | ✗ | ✗ | ✓ | ✓ | ✓ |
| warehouse | ✗ | ✗ | ✓ | ✓ | ✗ |
| hr | ✗ | ✗ | ✗ | ✓ | ✗ |
| employee | ✗ | ✗ | ✗ | ✓ | ✗ |
| **打得开的角色数** | **1** | **5** | **8** | **11** | **6** |

**逐条对着 §8.2 那份【搬家前】的求值核:**

| 路由 | 搬家前 | 部署后实测 | 判词 |
|---|---|---|---|
| `/deleted` | 9(admin auditor cfo finance gm operations procurement sales warehouse) | **1(admin)** | **★ 明令的收窄,数字与预测逐字相符 ★** |
| `/margin` | 5(admin auditor cfo finance gm) | **5,同一批人** | **★ 不变,证毕 ★** |
| `/inventory/reports` | 8(admin auditor finance gm operations procurement sales warehouse) | **8,同一批人** | **★ 不变,证毕 ★** |
| `/metal-prices` | 11 | **11** | 不变(`{ all: [] }`) |
| `/pricing` | 6(admin auditor finance gm procurement sales) | **6,同一批人** | 不变 |

> ★★【所以完成定义里那两句"权限不变"现在有三重证据,而第三重是最硬的】★★
> ① 谓词字面量逐字比对(没改);② 11 角色 × 76 条目的注册表求值(§8.2);
> ③ **在部署好的系统上,拿真会话把那两页【真的打开了】**(本节)。
> **`/margin` 与 `/inventory/reports` 改动前打得开的人,改动后一个不少。**
>
> **而 `/deleted` 那一列同样是真的**:除 admin 外的 **10 个角色**在部署系统上
> 拿到的是一句**具名的拒绝**,不是一张空表 —— 其中 **8 个是这一刀让他们失去的**
> (auditor · cfo · finance · gm · operations · procurement · sales · warehouse),
> hr 与 employee 本来就没有。**auditor 那一条仍然留给 Tim 再看一眼(§13.2.3)。**

---

## 十、NAV-CLEANUP-1(2026-09-03)—— 逐条的实测

### 10.1 ① 被删记录:一次【铸码】,以及为什么它非铸不可

**Tim 的裁定**:`/settings/deleted` 只给 admin 与 auditor,其余七个角色维持 UI-FIX-1 的样子。

**那在现有的权限词汇里【表达不出来】,而这是一条定理不是一次没想到:**

1. `lib/modules.ts` 的 `allows()` 是**单调**的 —— 每一项都是 `perms.includes(...)`,
   只用 ∧ 与 ∨ 组合。**给一个人加权限,永远不会把 true 变成 false。**
2. 实测 live 授权:**gm 持有 auditor 那 17 个码的全部,另外还多 16 个**
   (全部 `.edit` 码 + `data.view_banking` + `data.view_reviews`);
   **auditor 没有任何一个码是 gm 缺的。** 即 `perms(gm) ⊋ perms(auditor)`。
3. 由 ① 与 ②:**任何放 auditor 进来的谓词,必然也放 gm 进来。**

所以 Tim 裁定改词汇:铸 `data.view_deleted`,只授 admin 与 auditor。
**gm 刻意不授** —— 一份**已经过期**的文档(`docs/exec-views-plan.md`)仍把 gm 写成 MD,
而那个人已被另行裁定为只读;今天授给 gm,等于在发账号那天把他放进来。
**那份文档的更正是它自己的排队项,本刀不动它。**

**逐角色实测(从 live 授权算出来,不是手写 —— UI-FIX-1 的手写版四行是错的):**

| 角色 | 改动前 | 改动后 | |
|---|---|---|---|
| admin | ✓ | ✓ | |
| **auditor** | ✗ | **✓** | ★ 恢复 |
| cfo | ✗ | ✗ | |
| employee | ✗ | ✗ | |
| finance | ✗ | ✗ | |
| **gm** | ✗ | **✗** | ★ 明令不放进来 |
| hr | ✗ | ✗ | |
| operations | ✗ | ✗ | |
| procurement | ✗ | ✗ | |
| sales | ✗ | ✗ | |
| warehouse | ✗ | ✗ | |

**恢复 1 · 失去 0 · 改动后恰好 `admin auditor`。**

**故障注入(在一笔【回滚掉的】事务里把新码也授给 gm):**

| | 持有者 | 断言 |
|---|---|---|
| 注入后 | `admin auditor gm` | **RED** ✓ |
| 回滚后(live 现状) | `admin auditor` | **GREEN** ✓ |

**那条旧判据还有谁在用 —— 以及它们变了没有。** `/deleted` 此前借的是
`action.manage_permissions`,今天还有 **5 条**条目用它:`/settings`、
`/settings/accounts`、`/settings/roles`、`/settings/reference`、`/settings/approvals`
—— **五条的可见集都是 `admin`,而且【一个字没变】**:本刀只改了
`/settings/deleted` 自己那一条的 `permission` 字段,那个码本身与它的授权一动没动。

> **`/settings/reference`(权限速查)那一页【读的是 `permissions` 表】**,
> 所以新码在界面上自动出现,不需要第二处维护。**这正是"目录是数据、代码去检查它"
> 那条设计的兑现**,记在这里免得下一个人去找一份手写的清单。

### 10.2 ② 页内同级导航:按【组件】逐个判,不按页

Tim 走查报 49 页;实测是 **126 页 / 11 个组件**。**他的数来自他看见的,我的数来自树。**
按组件报(11 行可复核,126 行不可)。

**判据是算出来的,不是看出来的:** 一个目标【被二级菜单 offer 给这个读者】=
它是注册表条目 **AND** 判据放行 **AND** 它至少有一个属主模块这个读者进得去。
对 **11 个 live 角色**逐个求。

| 组件 | 目标数 | 判词 | 未覆盖 |
|---|---|---|---|
| `app/finance/Subnav.tsx` + `SubnavClient.tsx` | 32 | **删** | — |
| `app/hr/Subnav.tsx` | 10 | **删** | — |
| `app/inventory/Subnav.tsx` | 3 | **删** | — |
| `app/logistics/Subnav.tsx` | 3 | **删** | — |
| `app/pricing/Subnav.tsx` | 4 | **删** | — |
| `app/purchasing/Subnav.tsx` | 3 | **删** | — |
| `app/sales/Subnav.tsx` | 2 | **删** | — |
| `app/processing/Subnav.tsx` | 4 | **删** | — |
| `app/settings/permissions/Subnav.tsx` | 3 | **删** | — |
| `app/operation/processing/page.tsx` 的页头行 | 7 | **删** | — |
| **`app/hr/leave/LeaveSubnav.tsx`** | 6 | **★ 保留 ★** | **5 条** |

**三个数:删除 10 个组件 · 保留 1 个 · 未覆盖目标 5 条。**
(页数:121 页的 `<Subnav />` 连同 import 一起删掉。)

**★ 那 5 条未覆盖的目标,就是留给后面一刀的导航缺口 ★**
`/hr/leave/balances` · `/hr/leave/calendar` · `/hr/leave/grants` ·
`/hr/leave/types` · `/hr/leave/holidays`
—— **五条都是真实存在的路由,而【一个都不在注册表里】**,对**全部 11 个角色**
都只能从 `LeaveSubnav` 那一行进去。**所以那一行是它们唯一的入口,删掉就是弄丢五页。**
本刀按指令**保留它**,不去发明菜单条目(那是产品判断)。

> **Tim 点名要确认的一件事,确认了:** Q5 的拍平**确实**解掉了
> `settings/permissions/Subnav.tsx` 的搁浅风险 —— 它那 3 个目标
> (账号 / 角色 / 权限速查)在拍平之后**各自成为注册表条目**,于是判成"全覆盖"、
> 可以安全删除。**计划成立了,而这是算出来的,不是假定的。**

> ★【一件值得单独说的事:被删掉的代码是【对】的,而它让位给的菜单是【错】的】★
> `app/inventory/Subnav.tsx` 里那段最长前缀解析**做对了**二级高亮
> (它显式地把 `/inventory` 排到最后判,所以 `/inventory/locations` 不会同时点亮「现况」)。
> 而顶栏菜单里每一行各自 `startsWith`,**正是 Tim 报的那个缺陷**。
> **正确的实现一直在树里,只是没有长在菜单上。** 见 §10.4。

### 10.3 ③④ 路由层级:退休了什么、breadcrumb 变了什么

**没有重定向垫片。** 一次重定向会把任何一处没改到的内链**悄悄吸收掉**,
而那正是本刀要消灭的那一类缺陷。改不干净就让它红 ——
`scripts/check-nav-routes.mjs` 在构建期点名文件与行。

**它当场抓到 52 处**,其中最要紧的一类是 **`revalidatePath('/settings/permissions')` 共 8 处**
—— 那种失效**不报错**:页面照旧渲染,只是缓存再也不刷新了。

**breadcrumb 的变化(深路由 = 深度 ≥3,由 `gen-deep-routes.mjs` 算):23 → 19。**

| | 路由 |
|---|---|
| **失去** breadcrumb(4 条)| `/settings/permissions/reference` → `/settings/reference`(3→2)<br>`/settings/permissions/roles` → `/settings/roles`(3→2)<br>`/settings/permissions/roles/new` → `/settings/roles/new`(3→2)<br>`/settings/permissions/roles/[id]` → `/settings/roles/[id]`(3→2) |
| **获得** breadcrumb | **0 条** |

**★ 失去的这 4 条【正是 Tim 报的那条「设置 › 设置 › 角色」】★** —— 拍平之后它们不再
是三层,于是那条重复的面包屑不是被改掉的,是**不再存在**了。

**运营那边为什么没有获得**:`/operation/processing/[id]` 与 `/operation/processing/new`
确实各深了一层(1 → 2),但 `[id]` 是动态段、`new` 是叶子动作词,两者都不计深度
—— 判据在 `gen-deep-routes.mjs` 的抬头,本刀没有动它。

### 10.4 ⑤ 高亮:两个不同的机制,分开诊断

**Tim 猜的两个机制都对,而且它们确实是【两件事】:**

| 层级 | 症状 | 机制 | 位置 |
|---|---|---|---|
| **一级** | 从采购点进收货,采购**和**库存同时亮;库存报表一次点亮销售、财务、库存 | **多属主** —— `activeIds = new Set(moduleIdsForPath(pathname))` 把**全部**属主都点亮 | `ModuleBar.tsx:127` |
| **二级** | 打开「库位」,「现况」也跟着亮 | **前缀匹配,没有最长前缀** —— 每一行各自 `pathname === href \|\| startsWith(href + '/')`,而 `/inventory` 是 `/inventory/locations` 的前缀 | `ModuleBar.tsx:172` |

**一级那一条【不是 bug,是一次被推翻的裁定】。** IA-BUILD-1 在那一行上方写着:

> 「一个功能可以同属几个模块,所以高亮的可以是【两个】…… 挑一个就是撒谎。」

**2026-09-03,Tim 走了部署系统之后推翻了它。** 那句话在**描述数据**时是对的,
但高亮回答的不是"这一页属于谁",而是"**我现在站在哪**" —— 后者只能有一个答案。
**记在这里而不是静默编辑那条注释**(与 UI-FIX-1 记 D6 的推翻同一个做法)。

**修法:一份共享的解析器 `lib/navTrail.activeModuleForPath`。**
`ModuleBar` 的高亮与 `breadcrumbTrail` 的第一截**都调它**;从前面包屑自己写
`entry.modules[0]` —— 同一个谓词的第二份实现,**而且带着同一个缺陷**。

**★ 那个缺陷是 Tim 当场抓到的,而它是这一条里最要紧的一句 ★**
「永远亮 `modules[0]`」在 `/inbound` 上会亮**采购**,而 `/inbound` 的第三个属主
运营正是他特意为车间加的 —— **而 operations 这个角色进不去采购。**
按 D5,进不去的模块仍然渲染成「· 受限」。于是那个规则会**在正是为他加的那一页上,
把高亮打在一个他被挡在外面的模块上。**

**所以规则是:声明顺序里【这个读者进得去的】第一个属主。**
一个都进不去 = **矛盾**(他既然打开了这一页……),**报出来,不静默地不亮**。

> ★★【实跑之后发现:Tim 给的规则与他给的预期【对不上】,而对不上的是预期】★★
> 他的 fixture 预期写的是「operations 在 `/inbound` 上解析成**运营**」。
> **实测得到的是【库存】。** `/inbound` 的声明顺序是
> `purchasing → inventory → operation`,而 **operations 进得去库存**
> (它持 `module.inventory.view`)。按他自己的规则,采购被正确跳过,
> 但在采购之后、运营之前还站着一个库存。
> **他关心的那件事成立了**(不是采购、不是一个他进不去的模块);
> **"是运营"要成立,得改 `/inbound` 的声明顺序** —— 那是一个产品判断,
> 不是一处实现缺陷,所以本刀**不改**,把它报出来。
> 断言因此钉的是**规则**(结果必须是这个读者进得去的、且不是采购),
> 外加把今天的答案(`inventory`)钉住,好让任何改动都看得见。

**没有"进入上下文"这种东西 —— Tim 的 Q1 已裁定。** 记住"你从哪个菜单点进来"
在点击路径上是对的,而在**输入网址、dock 快捷方式、别处来的链接、刷新、
浏览器后退**上全是陈旧的。那等于给"我在哪"造第二个真源。
**一个确定的、可能不是你来路的答案,好过一个有时正确、有时陈旧的答案。**
**这条回退写在 `lib/navTrail.ts` 里 —— 判据住的地方,不只在文档里。**

**二级那一条**改成问 `entryForPath(pathname)`(它本来就是最长前缀的实现,
面包屑一直在用),而不是让每一行自己判断。**于是二级也只有一个答案。**

### 10.5 ⑥ 这一刀留下的那道闸

`scripts/check-nav-routes.mjs`,进 `npm run build`,不需要数据库,秒级。

| 判据 | 故障注入 |
|---|---|
| ① 注册表每条 href 都有路由 | 加一条 `/settings/nonexistent` → **RED**,点名条目 |
| ② 每条路由要么在注册表、要么在例外表(**带理由**)| 建一页 `/orphan-page` → **RED**,点名路由 |
| ③ 退休路径不许出现 | 往 `lib/dock.ts` 塞一行 `/processing` → **RED**,点名 `lib/dock.ts:118` |
| ③b `/finance` 必须是落地页 | 把 `ModuleLanding` 改名 → **RED** |
| ④ 范围 id 是真实前缀(Tim 加的)| `/operation` → `/operation-gone` → **RED**,点名 id |
| ⑤ 活动模块解析(**真的跑一遍**)| 强制 `modules[0]` → **RED 7 处**;面包屑自己写 `modules[0]` → **RED** |

**五条全部注入过红、复原后绿。** ⑤ 不是正则:它把 `lib/navTrail.ts` 的源码读出来、
改写两个 `@/` import、落成一个临时探针再 import —— **读的是今天的源码,不可能漂开**。
它对**每一条多属主条目 × 每一个属主**穷举「读者只进得去属主 i ⇒ 结果就是属主 i」。

> **它答得了什么、答不了什么,写在脚本抬头:**
> 答得了**注册表与文件系统对不对得上**;
> **答不了**一个人点不点得到那个入口 —— 那要么是 `--reach`(它看不见二级),
> 要么是人走一遍。**本脚本不冒充那件事。**

### 10.6 `--reach` 在这一刀之后是什么

**它已经不是端到端的可达性判据了,而这是本刀【自己造成】的,照直写下来:**

* 它**本来就看不见第二级**(顶栏菜单点开才渲染,爬虫点不了 —— UI-FIX-1 实测);
* ② 之后它**也不再能靠页内同级链接扩散** —— 那 10 个组件正是它此前的前沿。

**Q4 的落地页部分偿还了这一笔**:`/finance`、`/operation`、`/settings` 三张页面
把本模块的注册表条目**逐条画成服务端 HTML 里的 `<Link>`**,于是爬虫又有了真的前沿。
**接替它的是 ⑥ 那支静态检查。** 两者都不冒充对方,`smoke-routes.mjs` 的抬头已改写。

### 10.7 部署之后:破窗时长,与稳定别名上的实测

**破窗(AGENTS.md 的必填字段):**

| | 时刻 | 来源 |
|---|---|---|
| 起点 —— 迁移提交 | **2026-09-03 01:23:18 CST** | `db/apply_migration.sh` 自己打的(`db/migration-windows.tsv`) |
| 终点 —— 部署 `state=success` | **2026-09-03 02:00:52 CST** | 部署 `6228640081` 的 `created_at` |
| **破窗** | **37 分 34 秒** | |

**★ 期间什么是坏的:【什么都没坏】,而这句话要说得出理由 ★**
窗口里生产跑的是【旧代码 + 新库】。这一次的库改动是**纯增量**:
多了一个权限码 `data.view_deleted` 与两条授权(admin / auditor),
**没有撤掉任何策略、没有改任何列、没有动 `deleted_records` 那张视图**。
旧代码读的是 `action.manage_permissions`,那个码与它的授权一个字没动 ——
**所以旧代码在窗口里的行为与迁移之前逐字相同**:admin 看得见 `/deleted`,
其余角色看不见。**唯一"还没兑现"的是 auditor 的恢复** ——
那是一件**没有发生的好事**,不是一件坏掉的事。
(对照:AGENTS.md 记着的 SO-2b 那次撤掉了一条 INSERT 策略,窗口里那条录入路径
**是真的坏的** —— 两者的区别正是这一栏要说的东西。)

**稳定别名上的实测**(`https://new-era-erp.vercel.app`,每个角色一个临时账号,
用完即删 —— 收尾实测 `auth.users` 里 `alias-%@test.local` 剩 **0** 行):

| 角色 | `/settings/deleted` | `/settings` | `/finance` | `/finance/trial-balance` | `/operation` | `/operation/processing` |
|---|---|---|---|---|---|---|
| admin | **✓** | ✓ | ✓ | ✓ | ✓ | ✓ |
| **auditor** | **✓** | ✗ | ✓ | ✓ | ✓ | ✓ |
| **gm** | **✗** | ✗ | ✓ | ✓ | ✓ | ✓ |
| finance | ✗ | ✗ | ✓ | ✓ | ✗ | ✗ |
| operations | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ |
| employee | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |

**每一格都是 HTTP 200**,区别只在里面是内容还是一句具名的拒绝
(判据认机器标记 `data-access-denied`,不认文案)——
**这正是"冒烟只断言 2xx,一个渲染出错误框的页面也是 200"说的那件事。**

**★ ① 的裁定在部署系统上兑现了:`/settings/deleted` 恰好 admin + auditor,gm 被挡住。★**
live 最终授权实测:`data.view_deleted` 的持有者 = **`admin auditor`**。

**顺带一条值得看见的推导结果:auditor 的顶栏上「设置」是【可进】的** ——
因为设置名下他有一条打得开的条目(就是被删记录),而模块可进性是从二级条目推导的。
**于是他不只是"打得开"那一页,他还【走得到】它。** 而 `/settings`、`/settings/accounts`、
`/settings/roles` 对他写着「· 受限」—— 那三条要 `action.manage_permissions`。
**这就是 D5 要的样子:一页一页地诚实,而不是整个模块非黑即白。**

---

## CONV-0(2026-09-03)· 注册表 84 → 81 条,以及银行换组

**②a 定价:三条条目删掉了**(`/pricing/formulas` · `/pricing/calculator` ·
`/pricing/metal-prices`),`FN.metalPrices` 随之删掉,
`/pricing/metal-prices` 的守卫改成 `requireModule(MOD.pricing)` ——
**求的是同一个字符串** `module.pricing.view`。
工具菜单上现在只有「定价」一条,底下什么都没有;三个孩子由 `/pricing`
那一页的四张卡提供入口。**没有给组加 `href`** —— 「组是一个标题,不是一个去处」
那条分寸原样保留。

**②e 银行:`finance.group.config` → `finance.group.periodEnd`。** 判据一字未动。
判定依据(它是对账,不是账户主数据,也不是两者共用一个入口)写在注册表里那一条
的注释上,以及 `docs/refusal-convergence.md` ②e。

**两件连带的事实,写下来免得被后人当成遗漏:**

1. **第三级又是财务独有的。** `TOOLS_GROUPS` / `MODULE_GROUPS.tools` **留着**
   (Tim 的指示),但再没有条目带 `tools.group.pricing`,渲染层的「空组不渲染」
   把它滤掉。TOOLS-1 那次泛化仍然是对的,只是它今天又只有一个住户。
2. ★ **删注册表条目会让路径段掉出面包屑的命名范围** ★ ——
   `metal-prices` 因此需要一句 `breadcrumb.metal-prices`(已补,两个语言)。
   **`check-i18n` 没有抓住它**,原因与修法方向记在 `docs/forward-queue.md`。
   **下一个删注册表条目的人:先跑 `node scripts/gen-deep-routes.mjs --write`,
   然后读那份 diff。闸门在这一处帮不了你。**

---

# CONV-6(2026-09-04)—— 两批搬家、三条模块根、两条条目退场

## 范围 id 的变化(权限码【一个字没动】)

`SCOPES` 的 `id` 是一段**路由前缀**,所以它跟着路由走;`permission` 是 RLS 上写着
的那个码,所以它不动。这与 `/processing → /operation`(NAV-CLEANUP-1 ③)
和「任务 → 工具」(UI-FIX-1 ⑥)是**逐字相同**的拆法。

| 范围 | id 从 | id 到 | permission | `MOD` 里的名字 |
|---|---|---|---|---|
| 任务 | `/tasks` | `/tools/tasks` | `module.tasks.view`(不变) | `MOD.tasks`(不变) |
| 定价 | `/pricing` | `/tools/pricing` | `module.pricing.view`(不变) | `MOD.pricing`(不变) |
| 客户 | `/customers` | `/sales/customers` | `module.customers.view`(不变) | `MOD.customers`(不变) |

**184 处 `requireModule(...)` / `requireFunction(...)` 的调用点一行未改** ——
它们按【名字】取范围,而名字没变。

## 条目的变化

| 变动 | 条目 | 说明 |
|---|---|---|
| 地址搬家 | `/tasks` → `/tools/tasks` | 属主仍是 tools |
| 地址搬家 | `/pricing` → `/tools/pricing` | 三个孩子跟着走,**都不进菜单**(CONV-0 ②a 未变) |
| 地址搬家 | `/customers` → `/sales/customers` | 属主仍是 sales |
| 地址搬家 | `/commissions` → `/sales/commissions` | ★ **属主仍是采购 + 销售两个** ——地址搬了,属主没搬。先例是 `/finance/freight`(物流 + 财务) |
| **删条目** | `/customers/overlap` | 它是客户页的**孩子**,不是同辈。入口在客户列表页上(`app/sales/customers/page.tsx:152`),而**冒烟有一条断言看着那个入口** |
| **删条目 + 删路由** | `/settings` | 「设置概览」是它底下八条的复述。**没有任何角色的唯一入口经过它**(实测:`action.manage_permissions` 只授 admin,而 admin 持有全部八条的码) |
| **新条目** | `/purchasing` | 此前它是一次 `redirect()`,CHART-0 ② 据此删过它的条目。**Tim 裁定它不许再跳转** —— 那一页现在是采购 Overview,所以它配有一条条目 |
| **新条目** | `/logistics` | 此前**根本没有** `app/logistics/page.tsx` |
| **新条目** | `/sales` | 同上 |

三条新条目的标签共用 `nav.moduleOverview`(「概览 / Overview」)。财务与人力那两条
各有自己的键(`finance.subnav.overview` / `hr.subnav.overview`),**本刀不动它们** ——
改一个已经在屏幕上的标签不属于这一刀。

## 退休路径:检查加了四条,并且**多了一整条判据**

`scripts/check-nav-routes.mjs` 的 `RETIRED` 加了 `/tasks` · `/pricing` · `/customers`
· `/commissions`,判据与既有三条同形(前面不许是词字符或点 —— 新地址的最后一个
字符恰好是词字符,所以它们自动不被误判)。

★ **而这一刀真正的补强是第 ⑥ 条判据:带查询参数的站内链接,它指的那一页
必须真的读那个参数。** 理由与实测见那个文件的抬头 —— 前五条对这一族
**结构性地**看不见,因为退休的可以是一个**语义**(`/finance` 不再【是】试算平衡)
而不是一个字符串。**四条注入全部实测变红,还原后归零。**
