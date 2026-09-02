# NAV-REG-1 —— 一个功能可以属于好几个模块

**日期** 2026-09-01 · **前一刀** IA-0(`bbbe455`)· **下一刀** Phase 8(视觉重建)

Tim 的裁定:**一个功能可以出现在好几个模块底下,只要数据不重复。**
一个产出批次既是加工的结果、也是可售的库存 —— 它出现在两处是对的。
IA-0 量到:这件事今天**只能在注册表之外**表达(在每个属主模块的页面里手写一个
链接),而手写的链接与权限之间**没有任何东西保证同步**。两个例外可以容忍;
一条通则需要一个机制。本刀造那个机制。

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
