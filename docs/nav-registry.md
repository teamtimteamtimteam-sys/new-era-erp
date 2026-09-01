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
