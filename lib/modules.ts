// lib/modules.ts
// 【导航分类法、权限范围、以及全站唯一的权限谓词求值器】
//
// ════════════════════════════════════════════════════════════════════════════
// IA-BUILD-1(2026-09-02):本文件现在回答【三】个不同的问题,而它们此前是一个
// ════════════════════════════════════════════════════════════════════════════
//   MODULES   —— 顶栏上的【九个一级模块】。Tim 的 D1。**它们没有 permission
//                字段**,理由见下面 §二;
//   SCOPES    —— 【15 个权限范围】,页面守卫用它(requireModule(MOD.finance))。
//                这就是 NAV-REG-1 之前那份 MODULES,一行未改地搬了过来;
//   FUNCTIONS —— 【每一个二级条目】,含它的属主模块(可以多于一个)与判据。
//
// ★【为什么必须是三份而不是一份 —— 这是本刀最重要的一条结构判断】★
// 九模块方案把 suppliers / materials / stocktakes / customers / inbound /
// output / pricing 从【一级模块】降成【二级条目】。但**它们的权限码一个都没有
// 降级**:`/suppliers/*` 仍然由 module.suppliers.view 把门,因为那是
// suppliers 表 RLS 上写着的那个码。
// **导航的层级与权限的范围是两件事,而它们此前共用一份清单。**
// 实测:169 处 `requireModule(MOD.x)` 调用点依赖那 15 个范围。把它们跟着导航
// 一起砍成九个,等于把 40 多页的门换掉 —— 而没有任何人要求换门。
// 所以:**导航重排,门一个字不动。**
//
// ── §一 · 求值只有一处 ───────────────────────────────────────────────────
// 【lib/modules.ts 的 allows()】。lib/moduleAccess.ts、app/components/moduleGuard.tsx
// 与首页看板【全部调它】,谁都不再自己比对权限码。
// 【为什么这一条是硬规矩】EQP-2d 实测过两份实现漂开的后果:库里的视图已经放宽了
// (arm_permission_widen),而首页那一份还没有,于是一个【拿得到行】的读者在屏幕上
// 看见「受限」—— 把"你看得见"说成"你看不见"。一条规则两个实现,迟早各错一次。
// scripts/check-permission-predicate.mjs 把这条钉死。
//
// ── §二 · ★ 一级模块【没有】自己的 permission —— 它是【推导】出来的 ★ ────
// 一个模块进不进得去 = **它名下有没有【任何一条】二级条目进得去**
// (lib/moduleAccess.ts 的 getModuleAccess:`entries.some(...allows...)`)。
//
// 【为什么推导而不是再写一份谓词】写一份就是第二份定义,而它与二级条目的判据
// 之间没有任何东西保证同步 —— 那正是 OPS-15 与本文件 §一 要杀的东西。一个人
// 看见「采购 · 受限」却持有 module.suppliers.view(供应商就在采购底下),
// 就是这份漂移的样子。
//
// 【它顺手把 Tim 的 M6 变成了一件不需要特判的事】M6:盘点降成库存的二级,
// 而"只有盘点权限的人必须进得去库存 —— 你数不了你看不见的东西"。
// 推导之后这【自动成立】:盘点是库存名下的一条二级条目,它进得去,
// 所以库存这个一级就进得去。**不需要 widen,不需要新码,不需要一行特判。**
// 而进去之后看到的是一张【逐条诚实】的菜单:盘点可点,现况/库位/物料「· 受限」——
// 不是一个打得开却零行的库存页(NAV-REG-1 为物流记下的那个陷阱)。
//
// ── §三 · 为什么这个文件里没有任何服务端 import ─────────────────────────
// 渲染层是 'use client'。纯数据 + 类型 + 纯函数才能被两侧同时 import;
// 取权限码在服务端做(lib/permissions.ts),结果作为 prop 传下来。

/**
 * 权限谓词。单个字符串 = 只要这一个码(绝大多数条目就是这样)。
 *
 * 对象形式的三个算子与库里同名同义:
 *   all   —— 必须【全部】持有;
 *   any   —— 还必须【任一持有】,与 all 相与 → 方向是【收窄】;
 *   widen —— 持有其一即可【替代】all,与 all 相或 → 方向是【放宽】。
 * 两个方向都要有,而且不能互相顶替:LOG-5a 需要放宽、MAR-1 需要收窄。
 */
export type PermissionSpec =
    | string
    | {
          /** 空数组 = 没有"人人必须持有"的那一半;此时由 any 单独决定。 */
          all: readonly string[]
          any?: readonly string[]
          widen?: readonly string[]
      }

/**
 * 【全站唯一的权限谓词求值器】。
 * 除本函数外,任何地方都【不得】自己拿权限码去比对一份清单来决定可见性。
 * 单码判断走 lib/permissions.ts 的 can(),它是本函数字符串分支的同义写法。
 */
export function allows(spec: PermissionSpec, perms: readonly string[]): boolean {
    if (typeof spec === 'string') return perms.includes(spec)
    const base =
        spec.all.every((c) => perms.includes(c)) ||
        (spec.widen?.some((c) => perms.includes(c)) ?? false)
    return base && (spec.any === undefined || spec.any.some((c) => perms.includes(c)))
}

// ════════════════════════════════════════════════════════════════════════════
// 一 · 权限范围 SCOPES —— 页面守卫用的那 15 个
// ════════════════════════════════════════════════════════════════════════════
/**
 * 一个权限范围:一段路由 + 进它要什么权限。
 * 【它不是导航层级】—— 见文件抬头。`/suppliers` 在导航上是采购的二级,
 * 在权限上仍然是它自己的范围,因为 suppliers 表的 RLS 就是这么写的。
 */
export type AccessScope = {
    /** 范围标识(同时是它的路由前缀) */
    id: string
    /** 拒绝页的标题用它 */
    navKey: string
    /** 与 db/tables/permissions.sql 的码对应 */
    permission: PermissionSpec
}

export const SCOPES: readonly AccessScope[] = [
    // CONTRACT-1:/contracts 归在供应商范围之下,而这是一个【判断】不是一次偷懒。
    //   一份合同跨买卖两侧,而本仓库的权限是按范围分的 —— 没有"合同"这个范围,
    //   新造一个就要新造一个权限码。
    //   **行一级的可见性已经由 RLS 管对了**:买方合同要 suppliers.view,
    //   卖方合同要 customers.view。挂在 suppliers 之下,是因为**第一批真合同是供货协议**。
    //   COMM-1:/commissions 同一条判断 —— 一份佣金协议的【主语是代理人】,
    //   而代理人是一个 supplier(counterparty_type = service_vendor)。
    { id: '/suppliers', navKey: 'nav.suppliers', permission: 'module.suppliers.view' },
    { id: '/purchasing', navKey: 'nav.purchasing', permission: 'module.purchasing.view' },
    { id: '/customers', navKey: 'nav.customers', permission: 'module.customers.view' },
    { id: '/materials', navKey: 'nav.materials', permission: 'module.materials.view' },
    // 【金属行情不在这里,而且不是漏了 —— 它不归权限范围管,理由在数据自己身上】
    //
    // 【规矩:守卫跟着数据自己的 RLS 走。】而一张表的 RLS 本来就有【读】和【写】
    // 两个答案,它们可以不一样 —— metal_prices 的这两个答案恰恰不一样
    // (db/tables/metal_prices.sql):
    //
    //   SELECT               USING (true)                                → 公开
    //   INSERT/UPDATE/DELETE has_permission('module.pricing.edit')       → 受管
    //
    // 所以金属行情底下四页带着【两种守卫】:列表页不设守卫,
    // {new,bulk,[id]/edit} 走 requireEditPermission('module.pricing.edit', …)。
    // 给列表页挂上 module.pricing.view,屏幕上就会对一个数据库愿意完整回答的人
    // 显示"你没有权限",那是【UI 比数据严】,而且严得没有任何东西背书。
    // ★ UI-FIX-1 ⑦(2026-09-02):它在【导航】上现在只属于【工具】。
    //   IA-BUILD-1 / D6 此前把它挂在采购与销售之下,那句话已被 Tim 推翻 ——
    //   见 FUNCTIONS 里工具那一段。**判据仍然是"最松的、仍然连贯的那一个"。**
    { id: '/pricing', navKey: 'nav.pricing', permission: 'module.pricing.view' },
    { id: '/inbound', navKey: 'nav.inbound', permission: 'module.inbound.view' },
    { id: '/output', navKey: 'nav.output', permission: 'module.output.view' },
    // ★【NAV-CLEANUP-1 ③(2026-09-03):范围 id 从 '/operation/processing' 改成 '/operation'】★
    //   Tim 的 Q3 裁定:**id 是路由前缀,所以它跟着路由走;permission 是 RLS 上
    //   写着的那个码,所以它一个字不动。** 这与 UI-FIX-1 把「任务」改名成「工具」
    //   时的拆法逐字相同 —— 导航与门是两件事。
    //   169 处 requireModule(MOD.processing) 的调用点【一行没改】:它们按名取范围,
    //   而 MOD.processing 这个名字没变,变的只是它 id 字段里那段前缀。
    { id: '/operation', navKey: 'nav.operation', permission: 'module.processing.view' },
    { id: '/inventory', navKey: 'nav.inventory', permission: 'module.inventory.view' },
    { id: '/stocktakes', navKey: 'nav.stocktakes', permission: 'module.stocktakes.view' },
    { id: '/sales', navKey: 'nav.sales', permission: 'module.sales.view' },
    { id: '/finance', navKey: 'nav.finance', permission: 'module.finance.view' },
    { id: '/tasks', navKey: 'nav.tasks', permission: 'module.tasks.view' },
    { id: '/hr', navKey: 'nav.hr', permission: 'module.hr.view' },
    // NAV-REG-1 / R2:物流【终于有了自己的码】。8 张表的 SELECT 策略同时换成了本码;
    // 写的那一半没有动(仍是 module.purchasing.edit),所以不存在"改得动、读不回"的倒挂。
    { id: '/logistics', navKey: 'nav.logistics', permission: 'module.logistics.view' },
]

// ════════════════════════════════════════════════════════════════════════════
// 二 · 九个一级模块 —— Tim 的 D1,顺序就是他给的顺序
// ════════════════════════════════════════════════════════════════════════════
/**
 * 一个一级模块。**注意它没有 permission** —— 见文件抬头 §二:
 * "进不进得去"由它名下的二级条目推导,不另写一份谓词。
 *
 * 【也没有 href】模块名在顶栏上是一个【展开二级的按钮】,不是一个链接(Tim 的 D2:
 * 不做模块目录页,顶栏本身就是目录)。可导航的地址【全部】是二级条目 ——
 * 包括模块自己的落地页(财务的试算平衡 = /finance,库存的现况 = /inventory)。
 * 【为什么这一条要紧】「设置」根本没有 app/settings/page.tsx。给模块塞一个 href
 * 就得为它造一张落地页,而那正是 D2 说不要的东西。
 */
export type ModuleEntry = {
    /** 模块标识。二级条目用它声明属主;活动态也按它。 */
    id: string
    /** 顶栏标签 */
    navKey: string
}

export const MODULES: readonly ModuleEntry[] = [
    { id: 'purchasing', navKey: 'nav.purchasing' },
    { id: 'logistics', navKey: 'nav.logistics' },
    { id: 'operation', navKey: 'nav.operation' },
    { id: 'sales', navKey: 'nav.sales' },
    { id: 'finance', navKey: 'nav.finance' },
    { id: 'inventory', navKey: 'nav.inventory' },
    { id: 'hr', navKey: 'nav.hr' },
    // ★ UI-FIX-1 ⑥(2026-09-02):「任务」改名为「工具」。★
    // Tim 的理由:任务一个人撑不起一个一级模块(2 页,对着财务的 54 页),
    // 而他【不要】把它折进别的模块,所以这一格改成【小工具的去处】。
    // 【只动导航的 id 与标签,权限范围一个字没动】SCOPES 里 '/tasks' 仍然是
    // module.tasks.view —— 那是任务表 RLS 上写着的码,与顶栏叫什么无关
    // (本文件抬头 §一 那条"导航重排,门一个字不动")。
    { id: 'tools', navKey: 'nav.tools' },
    { id: 'settings', navKey: 'nav.settings' },
]

/**
 * 财务的【第三级】分组。Tim 的 D1:只有财务有第三级,因为它的 30 条装不进一张平表。
 * 六个组名是他给的:报表 / 分录 / 应收 / 应付 / 期末 / 配置。
 * 【顺序就是这个数组的顺序】,而每一条二级条目用 group 指名自己属于哪一组。
 */
/** 【拥有第三级的模块】。Tim 的 D1 原文是「只有财务有第三级」—— 那句话到 TOOLS-1 为止是对的。 */
export const FINANCE_MODULE_ID = 'finance'

/**
 * ★★【TOOLS-1 ①b:第二个有第三级的模块 —— 工具】★★
 *
 * 【这不是一个新机制】财务已经有第三级了,本刀只是把"哪个模块有分组"
 * 从【一个写死的 id】变成【一张表】。渲染层、兜底网、空组不渲染,一个字没动。
 *
 * 【为什么定价要第三级】Tim 的裁定:工具的二级恰好四条
 * (任务 · 日历 · 单位换算 · 定价),而定价名下的公式/计算器/金属行情
 * 是【定价的内部结构】,不是与任务并列的东西。它们平铺在二级时,
 * 工具的二级有六条,而其中三条只有做定价的人用得上。
 */
// ★★【CONV-0 ②a:这一组现在【一条条目都没有】—— 留着,而理由要说清】★★
// 定价的三个孩子已经整批离开菜单(见下面 FUNCTIONS 里那段),所以再没有任何
// 条目带 group: 'tools.group.pricing'。渲染层的「空组不渲染」(lib/moduleAccess.ts)
// 会把它滤掉,工具因此画成平铺的四条 —— 屏幕上不留任何残迹。
//
// 【为什么不删掉它 —— Tim 的裁定】TOOLS-1 把"哪个模块有第三级"从【一个写死的
// 财务 id】换成了【一张表】,那次泛化本身是对的,变的只是它今天有几个住户。
// **实测:工具是这张表在财务之外的唯一使用者,所以本刀之后第三级又是财务独有。**
// 这是一件值得知道的事(一个没有使用者的能力,是下一个人据以断定"这里已经接好了"
// 的东西),但它【不是】一件值得现在拆掉的事:拆了,下一个要给某模块加第三级的人
// 得把 TOOLS-1 那一刀重做一遍。
export const TOOLS_GROUPS = ['tools.group.pricing'] as const
export type ToolsGroup = (typeof TOOLS_GROUPS)[number]

export const FINANCE_GROUPS = [
    'finance.group.reports',
    'finance.group.entries',
    'finance.group.receivables',
    'finance.group.payables',
    'finance.group.periodEnd',
    'finance.group.config',
] as const
export type FinanceGroup = (typeof FINANCE_GROUPS)[number]

/** 一个条目可以声明的第三级分组 —— 两个模块的并集。 */
export type NavGroup = FinanceGroup | ToolsGroup

/**
 * 【模块 id → 它的第三级分组,按渲染顺序】。
 * **这张表【就是】"谁有第三级"的唯一答案** —— lib/moduleAccess.ts 只问它。
 * 不在表里的模块 groups 为空数组,渲染层因此走平铺分支(与从前逐字相同)。
 */
export const MODULE_GROUPS: Readonly<Record<string, readonly string[]>> = {
    [FINANCE_MODULE_ID]: FINANCE_GROUPS,
    tools: TOOLS_GROUPS,
}

// ════════════════════════════════════════════════════════════════════════════
// 三 · 二级条目 FUNCTIONS —— 每一个可导航的地址
// ════════════════════════════════════════════════════════════════════════════
/**
 * 【一个功能可以同属几个模块】—— NAV-REG-1 的核心,Tim 的裁定 R1/D6。
 *
 * 一个产出批次既是加工的结果、也是可售的库存;一个数字可以正当地出现在两个模块
 * 底下,只要【数据不重复】。modules 列出属主(MODULES 的 id),permission 是
 * 【唯一的一份】判据 —— 于是"谁能看见这个入口"与"谁能进这一页"来自同一个表达式。
 *
 * ★ IA-BUILD-1:这份清单从【只装跨模块的两条】扩成了【装下每一个二级条目】。★
 * 单属主的条目 modules 长度为 1,跨属主的长度 > 1 —— 是同一个机制的两种用法,
 * 不是两份清单。**九个 Subnav 里那些手写的常量数组,读者从此都是这一份。**
 */
export type FunctionEntry = {
    href: string
    navKey: string
    /** 属主模块(MODULES 的 id);长度可以大于 1 —— 那正是本清单存在的理由 */
    modules: readonly string[]
    /** 【唯一的一份】判据 */
    permission: PermissionSpec
    /**
     * 第三级分组。**它的意思是"在【属主模块】的第三级里归哪一组"**,
     * 不是"它自带一个层级" —— /finance/freight 同属物流与财务,在财务底下归
     * 「应付」,在物流底下就是平铺的一条。
     * 哪些模块有第三级,由 MODULE_GROUPS 决定。
     */
    group?: NavGroup
}

// —— 常用判据的简写。**它们不是新判据**,只是同一个码少写几遍。 ——————————
const P_PURCHASING = 'module.purchasing.view'
const P_SUPPLIERS = 'module.suppliers.view'
const P_CUSTOMERS = 'module.customers.view'
const P_MATERIALS = 'module.materials.view'
const P_INBOUND = 'module.inbound.view'
const P_OUTPUT = 'module.output.view'
const P_PROCESSING = 'module.processing.view'
const P_INVENTORY = 'module.inventory.view'
const P_STOCKTAKES = 'module.stocktakes.view'
const P_SALES = 'module.sales.view'
const P_FINANCE = 'module.finance.view'
const P_TASKS = 'module.tasks.view'
const P_HR = 'module.hr.view'
const P_LOGISTICS = 'module.logistics.view'
const P_PRICING = 'module.pricing.view'
/** 设置底下三张字典的码 —— 与 app/settings/dictionaries/registry.ts 的 DICT_PERMISSIONS 同源。 */
const P_DICTIONARIES = { all: [], any: ['module.materials.edit', 'module.inbound.edit'] } as const
const P_MANAGE_PERMISSIONS = 'action.manage_permissions'
/** NAV-CLEANUP-1 ①:被删记录【自己的】码。只授 admin 与 auditor —— 理由见那一条。 */
const P_VIEW_DELETED = 'data.view_deleted'
const P_BULK_IMPORT = 'action.bulk_import'

export const FUNCTIONS: readonly FunctionEntry[] = [
    // ══ 采购 Purchasing ═════════════════════════════════════════════════════
    // ★【CHART-0 ②:「采购主页」这一条【删掉了】,因为它是一个别名不是一个去处】★
    //   app/purchasing/page.tsx 全文十四行,主体是 `redirect('/purchasing/orders')` ——
    //   它没有自己的内容,点下去落在【同一个菜单里紧挨着的下一条】上。
    //   scripts/smoke-routes.mjs 早就把它记成 `'/purchasing': [307]`,那一行是
    //   同一件事的第二个独立证词。
    //   【为什么删它安全,而删别的不安全】模块名在顶栏上是一个【展开菜单的按钮】,
    //   不是链接(D2),所以【一级永远到不了模块根】—— 一条二级条目删掉,它指的
    //   那一页就从导航上消失了。这一条例外,只因为它指的那一页【本身就是一次跳转】,
    //   而跳转的终点 /purchasing/orders 就在下一行,自己是一条条目。
    //   其余八个模块根逐个查过,没有第二个别名 —— 结论见 docs/information-architecture.md。
    { href: '/purchasing/orders', navKey: 'purchasing.subnav.orders', modules: ['purchasing'], permission: P_PURCHASING },
    { href: '/purchasing/discrepancies', navKey: 'purchasing.subnav.discrepancies', modules: ['purchasing'], permission: P_PURCHASING },
    { href: '/purchasing/payment-terms', navKey: 'purchasing.subnav.templates', modules: ['purchasing'], permission: P_PURCHASING },
    { href: '/suppliers', navKey: 'nav.suppliers', modules: ['purchasing'], permission: P_SUPPLIERS },
    { href: '/contracts', navKey: 'nav.contracts', modules: ['purchasing'], permission: P_SUPPLIERS },
    // ★ D7:公司执照登记簿搬到采购。**它的码本来就是 module.suppliers.view** ——
    //   见 db/tables/company_compliance.sql 与 app/purchasing/licences/page.tsx 的抬头。
    //   勘察文件的 M2 说它在 module.finance.view 后面,那一句【是错的】:
    //   finance.view 把的是它此前寄居的那一页(/finance/company),不是这块面板。
    { href: '/purchasing/licences', navKey: 'company.licence.title', modules: ['purchasing'], permission: P_SUPPLIERS },

    // ══ 物流 Logistics ══════════════════════════════════════════════════════
    { href: '/logistics/forwarders', navKey: 'logistics.forwardersTitle', modules: ['logistics'], permission: P_LOGISTICS },
    { href: '/logistics/lanes', navKey: 'logistics.lanesTitle', modules: ['logistics'], permission: P_LOGISTICS },
    { href: '/logistics/containers', navKey: 'logistics.containersTitle', modules: ['logistics'], permission: P_LOGISTICS },

    // ══ 运营 Operation ══════════════════════════════════════════════════════
    // ★【NAV-CLEANUP-1 ③:运营的落地页】★ Tim 的 Q4:它【只】列本模块自己的条目,
    //   而且那份清单从注册表派生 —— 所以它不可能与二级菜单漂开。不做经营内容。
    { href: '/operation', navKey: 'processing.subnav.overview', modules: ['operation'], permission: P_PROCESSING },
    { href: '/operation/orders', navKey: 'processing.subnav.workOrders', modules: ['operation'], permission: P_PROCESSING },
    { href: '/operation/processing', navKey: 'processing.subnav.runs', modules: ['operation'], permission: P_PROCESSING },
    { href: '/operation/wip', navKey: 'processing.subnav.wip', modules: ['operation'], permission: P_PROCESSING },
    { href: '/operation/handovers', navKey: 'processing.subnav.handovers', modules: ['operation'], permission: P_PROCESSING },

    // ══ 销售 Sales ══════════════════════════════════════════════════════════
    { href: '/sales/quotes', navKey: 'sales.subnav.quotes', modules: ['sales'], permission: P_SALES },
    { href: '/sales/orders', navKey: 'sales.subnav.orders', modules: ['sales'], permission: P_SALES },
    { href: '/customers', navKey: 'nav.customers', modules: ['sales'], permission: P_CUSTOMERS },
    { href: '/customers/overlap', navKey: 'nav.customerOverlap', modules: ['sales'], permission: P_CUSTOMERS },

    // ══ 财务 Finance —— 唯一有第三级的模块。六组顺序见 FINANCE_GROUPS ═══════
    // 【组内顺序与组的划分】条目本身与它们的先后【逐字取自】此前的
    // app/finance/SubnavClient.tsx 的 ordered 数组(勘察 D3:那是 DERIVED 的);
    // **分好的六个组名是 Tim 给的**(D1),哪一条归哪一组是本刀的判断。
    // ★【NAV-CLEANUP-1 ③:/finance 不再【是】试算平衡,它是财务的落地页】★
    //   【它【没有】group,而那是刻意的】只有财务有第三级;一个落地页不属于
    //   「报表 / 分录 / 应收 / 应付 / 期末 / 配置」里的任何一组。
    //   ModuleBody 把【没落进任何一组的】条目画在分组【前面】(本刀改的),
    //   于是它出现在财务菜单的最上面,而不是被挤到六个组的后面。
    { href: '/finance', navKey: 'finance.subnav.overview', modules: ['finance'], permission: P_FINANCE },
    { href: '/finance/trial-balance', navKey: 'finance.trialBalance', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.reports' },
    { href: '/finance/pnl', navKey: 'finance.subnav.pnl', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.reports' },
    { href: '/finance/balance-sheet', navKey: 'finance.subnav.balanceSheet', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.reports' },
    { href: '/finance/cashflow', navKey: 'finance.subnav.cashflow', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.reports' },
    { href: '/finance/cash-forecast', navKey: 'finance.subnav.cashForecast', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.reports' },
    { href: '/finance/price-exposure', navKey: 'priceExposure.entryLink', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.reports' },
    // ★★【UI-FIX-1 ⑦:批次毛利从运营【搬走】,财务独占 —— 而【判据一个字没动】】★★
    //
    // Tim 的理由:它是一个财务数字,不是一个车间数字。
    //
    // ★【明令记下来的那一条:摆在哪 ≠ 谁进得去】★
    //   谓词仍然是 `data.view_prices AND (finance OR processing)` ——
    //   **一个只持有 processing + view_prices 的人照样打得开 /margin**,
    //   只是他现在从【财务】的菜单里看见它。属主收窄了,门没有收窄。
    //   (本刀在 live 上拿真角色探过这一条,结论记在 docs/nav-registry.md。)
    //
    // ★【为的记录:/margin 是多属主的【第一个】先例,而那条先例仍然作数】★
    //   MAR-1 让它同属加工与财务;NAV-REG-1 引的正是它的 AND 合取,作为
    //   "注册表既需要 OR 也需要 AND"的证据。**那个谓词原封不动地活着** ——
    //   本刀收窄的只是它的属主。机制的先例与这一次的摆放是两件事。
    //
    // 【它仍然带 group】属主是财务,财务是唯一有第三级的模块,所以它落在「报表」组里,
    // 位置与从前(共有区末尾、财务报表组内最后一条)逐字相同。
    // 【运营那一侧不是一处缺席】/operation/processing 列表页页头那个 /margin 链接【留着】——
    // 它读的是 FN.margin.permission(同一份判据),而不是属主模块,所以进得去的人
    // 从加工页上仍然一点就到。属主管的是【菜单】,不是【页面之间的链接】。
    {
        href: '/margin',
        navKey: 'margin.title',
        modules: ['finance'],
        permission: { all: ['data.view_prices'], any: [P_FINANCE, P_PROCESSING] },
        group: 'finance.group.reports',
    },
    { href: '/finance/journal', navKey: 'finance.subnav.journal', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.entries' },
    { href: '/finance/journal/new', navKey: 'finance.subnav.newEntry', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.entries' },
    { href: '/finance/receivables', navKey: 'finance.subnav.receivables', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.receivables' },
    { href: '/finance/invoices', navKey: 'finance.subnav.invoices', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.receivables' },
    { href: '/finance/credit-notes', navKey: 'finance.subnav.creditNotes', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.receivables' },
    { href: '/finance/payables', navKey: 'finance.subnav.payables', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.payables' },
    { href: '/finance/payments', navKey: 'finance.subnav.payments', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.payables' },
    { href: '/finance/expenses', navKey: 'finance.subnav.expenses', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.payables' },
    { href: '/finance/claims', navKey: 'finance.subnav.expenseClaims', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.payables' },
    { href: '/finance/assets', navKey: 'finance.subnav.assets', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.payables' },
    { href: '/finance/month-end', navKey: 'finance.subnav.monthEnd', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.periodEnd' },
    { href: '/finance/payroll-payments', navKey: 'finance.subnav.payrollPay', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.periodEnd' },
    { href: '/finance/processing-costs', navKey: 'finance.subnav.costSettle', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.periodEnd' },
    { href: '/finance/revaluation', navKey: 'finance.subnav.reval', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.periodEnd' },
    { href: '/finance/cost-variance', navKey: 'finance.subnav.variance', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.periodEnd' },
    { href: '/finance/close', navKey: 'finance.subnav.close', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.periodEnd' },
    { href: '/finance/gst', navKey: 'finance.subnav.gst', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.periodEnd' },
    { href: '/finance/wht', navKey: 'finance.subnav.wht', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.periodEnd' },
    { href: '/finance/packs', navKey: 'finance.subnav.pack', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.periodEnd' },
    // ★★【CONV-0 ②e:银行【从「配置」搬到「期末」】—— Tim 的走查,2026-09-03】★★
    //
    // 【先判定它是什么,再决定它去哪 —— 这是裁定要求的顺序】
    //   委托书给了三种可能:银行【对账】(期末工作,该搬)、银行【账户主数据】
    //   (配置,不该搬)、或者两者【共用一个入口】(那就该拆开)。逐一对着代码看:
    //     · app/finance/bank/page.tsx 自称「银行对账首页」,读的是
    //       `bank_reconciliation_status` 视图(账面余额 / 最近对账单 / 差额 /
    //       两侧未匹配计数),卡片下方直链每一张待对账报表的工作台;
    //     · 它名下的全部子路由是 statements/ · import/ · statements/[id]/reconcile/
    //       —— 一条主数据维护路径都没有;
    //     · 银行【账户】主数据在这一页上根本不存在:全仓库引用 `bank_accounts` 的
    //       只有 app/finance/assets/page.tsx 一处,账户本身是会计科目
    //       (account_code),在科目表里维护。
    //   唯一不是对账的东西是页内的 TransferForm(账户间调拨)—— 那是一笔【交易】,
    //   不是一份主数据。**所以这不是"两件事共用一个入口",不需要拆。**
    //
    // 【结论】它整个是期末工作,整条搬。判据 P_FINANCE 一个字没动 ——
    // 搬的是【它在哪一组】,与②a 搬定价是同一种改动。
    { href: '/finance/bank', navKey: 'finance.subnav.bank', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.periodEnd' },
    { href: '/finance/settings', navKey: 'finance.subnav.settings', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.config' },
    { href: '/finance/company', navKey: 'finance.subnav.company', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.config' },
    { href: '/finance/fx', navKey: 'finance.subnav.fx', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.config' },

    // ══ 库存 Inventory ══════════════════════════════════════════════════════
    { href: '/inventory', navKey: 'inventory.subnav.overview', modules: ['inventory'], permission: P_INVENTORY },
    { href: '/inventory/locations', navKey: 'inventory.subnav.locations', modules: ['inventory'], permission: P_INVENTORY },
    // ★ M6:盘点降成库存的二级。**它自带 module.stocktakes.view,而模块可进性是
    //   从二级条目推导的,所以"只有盘点权限的人进得去库存"自动成立。**
    { href: '/stocktakes', navKey: 'nav.stocktakes', modules: ['inventory'], permission: P_STOCKTAKES },
    { href: '/materials', navKey: 'nav.materials', modules: ['inventory'], permission: P_MATERIALS },
    // ★★【UI-FIX-1 ⑦:库存报表从财务【搬回】库存,独占 —— 这是一次纠错,不是一次去重】★★
    //
    // 【它此前在哪】NAV-REG-1/R5 把它挂成 inventory + finance 双属主,并且给了
    // group: 'finance.group.reports' —— 于是它出现在财务菜单的「报表」组里,标签
    // 就叫「报表」。CHART-0 ② 查过它【不是别名】(它有自己的内容),把措辞问题留给了 Tim。
    // **2026-09-02 Tim 裁定:它是【库存】报表,摆在财务底下是一个错误。**
    // 那一页自己印的就是"Inventory reports — read-only views over stock as it stands"。
    //
    // ★【判据一个字没动,而这是明令】★ 仍然是 module.inventory.view。
    //   **一页摆在哪、与谁进得去,是两个问题,这一刀只动第一个。**
    //   于是改动前进得去的人,改动后一个不少地仍然进得去 —— 只是从库存菜单进。
    // 【group 一并去掉,因为它只对财务有意义】只有财务有第三级(FINANCE_MODULE_ID);
    //   留着一个 finance.group.* 而属主里没有 finance,是一个没有读者的字段。
    { href: '/inventory/reports', navKey: 'inventory.subnav.reports', modules: ['inventory'], permission: P_INVENTORY },

    // ══ 人力 HR —— 勘察 D3 判定为 DERIVED,逐条取自 app/hr/Subnav.tsx ════════
    { href: '/hr', navKey: 'hr.subnav.overview', modules: ['hr'], permission: P_HR },
    { href: '/hr/employees', navKey: 'hr.subnav.employees', modules: ['hr'], permission: P_HR },
    { href: '/hr/departments', navKey: 'hr.subnav.departments', modules: ['hr'], permission: P_HR },
    { href: '/hr/attendance', navKey: 'hr.subnav.attendance', modules: ['hr'], permission: P_HR },
    { href: '/hr/payroll', navKey: 'hr.subnav.payroll', modules: ['hr'], permission: P_HR },
    { href: '/hr/leave', navKey: 'hr.subnav.leave', modules: ['hr'], permission: P_HR },
    { href: '/hr/claims', navKey: 'hr.subnav.claims', modules: ['hr'], permission: P_HR },
    { href: '/hr/training', navKey: 'hr.subnav.training', modules: ['hr'], permission: P_HR },
    { href: '/hr/reviews', navKey: 'hr.subnav.reviews', modules: ['hr'], permission: P_HR },
    { href: '/hr/kpi', navKey: 'hr.subnav.kpi', modules: ['hr'], permission: P_HR },
    // CHART-1 ③:组织架构图。与其它 HR 页同一个判据 —— 它读的两张真源
    // (employees_masked / departments)本来就都由 module.hr.view 把门,
    // 另铸一个码会造出一个"进得去模块、进不去这一页"的洞(/margin 那一课)。
    { href: '/hr/org', navKey: 'hr.subnav.org', modules: ['hr'], permission: P_HR },

    // ══ 工具 Tools(UI-FIX-1 ⑥/⑦)══════════════════════════════════════════
    // 此前叫「任务」,名下只有一条。改名之后它是【小工具的去处】,而 ⑦ 把定价
    // 整组搬了进来。**条目的标签仍然是「任务」** —— 改名换的是模块,不是那一页。
    { href: '/tasks', navKey: 'nav.tasks', modules: ['tools'], permission: P_TASKS },
    // TOOLS-1 ②:跨模块日历。**只读** —— 它没有自己的权限模型,每一项按它【自己家】
    // 那个模块的可见性出现或不出现(见 app/tools/calendar/sources.ts)。
    // 所以这条注册表判据是"任何登录用户"的下一档:它自己不挡人,挡人的是每一个来源。
    { href: '/tools/calendar', navKey: 'nav.calendar', modules: ['tools'], permission: { all: [] } },
    // ★★【TOOLS-1:单位换算器 —— 这一条的判据【刻意】是恒真的,不要"顺手"关上】★★
    //
    // 【它承载着一条产品保证,而那条保证此前没有检查看着】
    //   Tim 的 4c:**新同事第一次登录时 dock 不能是空的**,因为"空的 dock"是一个
    //   没有人会发现的功能。lib/dock.ts 的默认候选清单靠【一条任何人都进得去的条目】
    //   来兑现它,而在本刀之前,全注册表【只有金属行情那一条】是恒真的。
    //   本刀把金属行情收窄了(见上),于是那条保证改由这一条承载。
    //
    // 【为什么换算器是它的合适持有者 —— 按价值,不是按凑数】
    //   吨/公斤/磅与湿基转干基是【公司里每一个岗位都碰得到】的算术:仓库、采购、
    //   化验、财务。金属行情是【一个群体】的计价基准。一扇开着的门,该开在
    //   受众真的是所有人的那一页上。
    //   而且它没有业务数据 —— 输入是使用者自己敲进去的数,所以恒真的判据
    //   与它背后的数据是【相称】的,正如金属行情的恒真曾与 USING(true) 相称。
    //
    // ★ 关掉这一条之前,先跑 `npm run check:dock` ★ 它会算出每个角色的默认 dock,
    //   任何角色掉到 0 就变红。**这条保证从此有检查看着,不再只有一句注释。**
    { href: '/tools/converter', navKey: 'nav.converter', modules: ['tools'], permission: { all: [] } },
    // ★★【UI-FIX-1 ⑦:定价从采购与销售【搬进】工具,而这【推翻了 D6 as built】】★★
    //
    // 【被推翻的是什么】IA-BUILD-1 的 D6 把定价同时挂在采购与销售之下,理由是
    // "它同时服务两侧,塞进任何一侧都会让另一侧看不见"。那个理由本身没有错,
    // **Tim 在 2026-09-02 就定价这一件事推翻了它** —— 定价现在【只属于工具】。
    // 【所以下面那段 D6 的推理不再生效,不许照它读】共有区里 D6 的抬头已经改写。
    // 【D6 的机制没有被推翻】/commissions、/inbound、/output、/finance/freight
    // 仍然是多属主的,多属主机制本身一行未动 —— 变的只是定价这一族的属主。
    //
    // 【判据一个字没动】仍然是 module.pricing.view;搬的是【它在哪个菜单里】,
    // 不是【谁进得去】。这与本刀 /margin 那一条是同一条裁定。
    { href: '/pricing', navKey: 'nav.pricing', modules: ['tools'], permission: P_PRICING },
    // ★★【CONV-0 ②a:定价的三个孩子【整批离开菜单】—— Tim 的裁定,2026-09-03】★★
    //
    // 【症状】工具的二级是「任务 · 日历 · 单位换算 · 定价」,而紧贴在「定价」这一条
    // 下面又是一个【也叫定价】的组标题,底下挂着公式 / 计价器 / 金属行情。
    // 同一个词在同一张菜单上出现两次,一次是去处、一次是标题 —— 读的人分不出
    // 哪一个是"定价"。TOOLS-1 把这件事留给了 Tim,他裁的是:这不是口味问题。
    //
    // 【裁定】**工具菜单上只出现「定价」一条,它底下什么都没有。**
    // 公式、计价器、金属行情【不进菜单】,由 /pricing 那一页自己列出来。
    //
    // ★【为什么不是"给组加一个 href,让组名可点"】★
    //   那是在答另一个问题。组名不可点是 ModuleBar 里写着的一条分寸
    //   (「组是一个标题,不是一个去处」),而这一刀【没有】推翻它 —— 财务的六个组
    //   仍然是纯标题。这一刀做的是让定价【不再需要】第三级。
    //
    // ★【删掉三条条目,判据一个字没变 —— 这是本刀必须说清的一点】★
    //   三条的 permission 全是 P_PRICING,而它们的页面守卫求的是同一个字符串:
    //     /pricing/formulas · /pricing/calculator → requireModule(MOD.pricing)
    //     /pricing/metal-prices                   → requireModule(MOD.pricing)(本刀改,见下)
    //   实测 live 授权:module.pricing.view 归 admin · auditor · finance · gm ·
    //   procurement · sales 六个角色;没有任何角色持有别的 pricing 码而缺这一个。
    //   **所以这是一次导航改动,不是一次访问改动。**
    //
    // ★【check-nav-routes 为什么仍然绿】★ 判据②认的是"落在某条注册表条目之下"
    //   (isCoveredByEntry),而 /pricing 这一条还在 —— 三条子路由都在它底下,
    //   所以它们【不需要】进 EXCEPTIONS。少写一条例外,就少一处将来要维护的理由。
    //
    // ★【读者怎么走到它们】★ 只有一条路:打开 /pricing,四张卡各指一个孩子。
    //   本刀【同时】修好了那一页 —— 此前它的第三张卡直指 bulk(录入),
    //   而金属行情【列表】只挂在卡片下面一个灰色小链接上。菜单入口撤掉之后,
    //   那个灰链接会成为列表页唯一的门 —— 那不是整理菜单,那是把一页藏起来。
    //   见 app/pricing/page.tsx。
    //
    // ══ 以下这一整段【不再有条目跟在它后面】—— CONV-0 ②a 删掉了那一行 ══════
    // 它说的那次【收窄】仍然完全有效,只是判据不再由一条 FUNCTIONS 条目携带,
    // 而是由页面自己的 requireModule(MOD.pricing) 表达 —— 求的是同一个字符串。
    // 留着它,因为它记的是【为什么金属行情要受 module.pricing.view 管】,
    // 而那个理由今天还在承重;末尾那句「见下面那一条」指的是 /tools/converter,
    // 它在本文件更靠前的位置(dock 兜底那一条),不在这一段之后。
    // ★★【TOOLS-1 ①b:金属行情搬进 /pricing 之下,并且【刻意收窄】判据】★★
    //
    // 【历史,保留不删 —— 它是这次改动的论据,不是过时的注解】
    //   UI-FIX-1 ⑦ 把它搬进工具时,判据刻意留成 `{ all: [] }`(恒真),理由写着:
    //   「metal_prices 的 SELECT 是 USING(true),读是公开的;换成 module.pricing.view
    //     会让界面【比数据严】—— 一个数据库愿意完整回答的人,会在屏幕上读到"你没有权限"。」
    //   **那条理由在它是【一级路由】时是对的。** 本刀改的是它的位置,而位置改变了结论:
    //
    // 【为什么现在要收窄 —— Tim 的裁定(甲),2026-09-03】
    //   它现在住在 /pricing 底下,而 /pricing 由 module.pricing.view 把门。
    //   保持 `{ all: [] }` 会造出一个【半开】的状态:菜单里看不见,URL 却打得开。
    //   **那种状态是最难解释的一种** —— 在一次审计里,或者在一个"我为什么找不到这一页"
    //   的支持问题里。金属行情是采购报价的基准,它属于定价。
    //
    // ★【这是一次【导航与路由守卫】的收窄,不是一次数据控制】★
    //   **metal_prices 的 RLS 仍然是 `USING (true)`,一个字没动。**
    //   数据在库那一层仍然对任何登录用户可读 —— 谁要是后来把这条读成
    //   "金属行情是受控数据",那就读错了。写那一半照旧由
    //   requireEditPermission('module.pricing.edit') 把关。
    //
    // 【失去它的五个角色(实测,不是手写)】cfo · employee · hr · operations · warehouse
    //   —— 逐角色的前后对照见本刀报告与 docs/nav-registry.md。
    // 【dock 的兜底不再挂在这一条上】它挪到了 /tools/converter(见下面那一条)。

    // ══ 设置 Settings ═══════════════════════════════════════════════════════
    // ★★【NAV-CLEANUP-1 ④(2026-09-03):设置拍平成【一级】,Tim 的 Q5 裁定】★★
    //
    // 【它此前的四处不连贯,一次全解掉】
    //   ① 有一条二级条目【也叫「设置」】(navKey: 'nav.settings'),点开是账号页;
    //   ② 面包屑因此读作「设置 › 设置 › 角色」;
    //   ③ 同一层的页面地址深浅不一(/settings/roles 是三层,
    //      /settings/import 是两层);
    //   ④ 角色与权限速查【根本不在注册表里】—— 它们只由 permissions/Subnav.tsx
    //      那一行页内链接支撑,而 ② 正在删掉那一类行。**先把它们变成注册表条目,
    //      删那一行才不会把两页弄丢。**
    //
    // 【拍平之后:每一条都是 /settings/<一个词>,各自是注册表里的一条】
    //   /settings            落地页(Q4:只列本模块条目,从注册表派生)
    //   /settings/accounts   账号        ← 此前的 /settings/accounts
    //   /settings/roles      角色        ← 此前的 /settings/roles
    //   /settings/reference  权限速查    ← 此前的 /settings/reference
    //   /settings/dictionaries /settings/import /settings/approvals  原地不动
    //   /settings/deleted    被删记录    ← 此前的 /settings/deleted(见下)
    //
    // 【/settings/accounts 这个前缀【整段退休】】它下面那五个共用文件搬去了
    //   app/settings/{guard.tsx, accountsActions.ts} 与 app/settings/accounts/。
    //   scripts/check-retired-paths.mjs 会在构建期拦住任何一处复活。
    //
    // 【落地页的判据取 action.manage_permissions,而不是一个并集】
    //   现有的 /inventory 与 /hr 两个 Overview 用的就是本模块那个主码,这里照它。
    //   写一个「manage_permissions OR 字典 OR 导入」的并集就是把模块可进性
    //   【定义第二遍】—— 而那正是本文件抬头 §一 要杀的东西。
    //   代价照直说:一个只持字典编辑权的人进得去设置,但那一条 Overview 对他
    //   写着「· 受限」。**这是 D5 想要的样子,不是一处缺席。**
    { href: '/settings', navKey: 'nav.settingsOverview', modules: ['settings'], permission: P_MANAGE_PERMISSIONS },
    { href: '/settings/accounts', navKey: 'permissions.subnav.users', modules: ['settings'], permission: P_MANAGE_PERMISSIONS },
    { href: '/settings/roles', navKey: 'permissions.subnav.roles', modules: ['settings'], permission: P_MANAGE_PERMISSIONS },
    { href: '/settings/reference', navKey: 'permissions.subnav.reference', modules: ['settings'], permission: P_MANAGE_PERMISSIONS },
    { href: '/settings/dictionaries', navKey: 'nav.dictionaries', modules: ['settings'], permission: P_DICTIONARIES },
    { href: '/settings/import', navKey: 'nav.import', modules: ['settings'], permission: P_BULK_IMPORT },
    // ★ D7:审批链从 /finance/settings 搬到设置,把关码跟着搬 ——
    //   从 module.finance.view 换成 action.manage_permissions。
    //   ★【必须照直说的一件事】这块面板是【只读】的,而且系统里【根本没有】
    //     配置审批链的界面。所以搬走的是【那扇窗】,不是一个控制器。
    { href: '/settings/approvals', navKey: 'finance.approvals.title', modules: ['settings'], permission: P_MANAGE_PERMISSIONS },
    // ★★【NAV-CLEANUP-1 ①:被删记录 —— 地址进设置,并且【铸了一个属于它自己的码】】★★
    //
    // 【UI-FIX-1 留下的状态】属主收成设置一个,判据借用 action.manage_permissions。
    //   实测后果:9 个角色 → 1 个(admin),而 Tim 只预期失去 3 个。
    //   ★ auditor 一并被挡在外面 —— 一页被判为"审计性质",却挡住了审计角色本人。★
    //
    // 【本刀 Tim 的裁定:auditor 回来,其余七个维持 UI-FIX-1 的样子】
    //
    // ★★【为什么这需要【铸一个新码】,而不是换一个谓词写法 —— 这是一条证明】★★
    //   allows() 是【单调】的:它每一项都是 perms.includes(...),只用 ∧ 和 ∨ 组合,
    //   所以【给一个人加权限永远不会把 true 变成 false】。
    //   实测 live 授权:**gm 持有 auditor 那 17 个码的【全部】,另外还多 16 个**
    //   (全部 .edit 码 + data.view_banking + data.view_reviews);auditor 没有任何
    //   一个码是 gm 缺的。于是 gm 的权限集【真包含】auditor 的。
    //   单调 + 真包含 ⇒ **任何放 auditor 进来的谓词,必然也放 gm 进来。**
    //   「auditor 进、gm 不进」在【现有的权限词汇里根本表达不出来】——
    //   这不是没想到写法,是一条关于这套词汇的定理。**所以变的是词汇本身。**
    //
    // 【为什么这也是【对】的修法,不只是可行的那个】/settings/deleted 一直骑在一个属于
    //   别人的判据上(先是六个模块码的并集,后是 action.manage_permissions)。
    //   它已经搬进设置、并被裁定为审计性质,那么"谁可以打开它"就是它自己的问题,
    //   值得有自己的码。**此后它的可见集不会再因为别人的权限变动而被顺带改掉。**
    //
    // 【铸出来的码】data.view_deleted —— 只授给 admin 与 auditor。
    //   迁移:db/migrations/2026-09-03-navcleanup1-*.sql(备份在前,单事务)。
    //   ★ gm 【不授】★ —— docs/exec-views-plan.md 那份【已经过期】的文档仍把 gm
    //     写成 MD,而 Tim 已另行裁定那个人是只读的;今天授给 gm,等于在发账号那天
    //     把那个人放进来。**那份文档的更正是它自己的排队项,本刀不动它。**
    //
    // 【行一级的过滤一字未动】视图 deleted_records 每一行仍然由它自己那个
    // has_permission 裁决,所以进来之后看得见哪几类,与从前完全一样。
    // 本谓词只回答"这一页对你有没有意义"。
    { href: '/settings/deleted', navKey: 'nav.deleted', modules: ['settings'], permission: P_VIEW_DELETED },


    // ══════════════════════════════════════════════════════════════════════
    // 【共有区】—— 属主多于一个的条目全部集中在这里
    // ══════════════════════════════════════════════════════════════════════
    // ★【为什么它们不写在各自属主那一段里,而是集中在最后】★
    // functionsForModule() 按【数组顺序】返回,所以数组顺序【就是】菜单顺序。
    // 一条跨属主的条目只有一处声明(那正是本机制的全部内容),于是它在两个
    // 菜单里的位置由它在数组里的【那一个】位置决定 —— 写在采购那一段里,
    // 它就会插在销售自己的条目【前面】。
    // 集中放在全部单属主段之后,每个模块的菜单就都是【先自己的,后共有的】,
    // 而这对每一个属主都成立,不需要第二份排序表。
    // (第二份排序表正是本刀在财务子导航里刚刚删掉的那种东西。)
    // 【双】佣金:主语是代理人(一个 service_vendor 供应商),但 free_standing
    // 与卖方侧的佣金是销售在看 —— 勘察 C1/C4。
    { href: '/commissions', navKey: 'nav.commissions', modules: ['purchasing', 'sales'], permission: P_SUPPLIERS },
    // 【三】收货 / 进料批次:采购的收货腿,库存的入库腿 —— 勘察 C1/C6。
    // ★【UI-FIX-1 ⑦:运营成为第三个属主 —— 这是一次纯粹的【增加】】★
    //   Tim 的理由:车间需要知道什么料到了。
    //   **没有任何人失去东西**:判据一个字没动(module.inbound.view),
    //   采购与库存两侧的入口原样留着,只是运营的菜单里多了一条。
    //   【它是本注册表里第一条【三】属主的条目】—— 机制本来就没有上限,
    //   modules 是一个数组而不是一对,这一条只是第一次用到第三格。
    { href: '/inbound', navKey: 'nav.inbound', modules: ['purchasing', 'inventory', 'operation'], permission: P_INBOUND },
    // 【双】产出批次:**这是 Tim 自己举的例子** —— 一批产出既是加工结果,也是可售库存。
    { href: '/output', navKey: 'nav.output', modules: ['operation', 'inventory'], permission: P_OUTPUT },
    // ══ D6 as built【已于 2026-09-02 被 UI-FIX-1 ⑦ 就定价这一件事推翻】═══════
    // 这里从前写的是:「定价与行情同属采购与销售,一份判据,不设第十个模块 ——
    // 定价服务采购(payable %、扣杂)与销售(报价)两侧;塞进任何一侧都会让另一侧
    // 看不见。/margin 是这条的先例。」
    // ★ 那段推理【不再生效】,不许照它读。★ Tim 裁定定价整族(含金属行情)
    //   只属于【工具】,采购与销售两侧都不再有这个入口 —— 见上面工具那一段。
    //   记在这里而不是删掉,是为了让"D6 说定价同属两侧"这句话不至于读起来还作数。
    // 【被推翻的是这一族的摆放,不是多属主机制】机制仍然在用:上面的 /commissions、
    //   /inbound(本刀刚变成三属主)、/output、下面的 /finance/freight 都是。
    // 【双】运费单:既是一笔应付,也是一票货的成本 —— 勘察 C2。
    { href: '/finance/freight', navKey: 'finance.subnav.freight', modules: ['logistics', 'finance'], permission: P_FINANCE, group: 'finance.group.payables' },
]

/** 某个模块名下的二级条目(一个条目会在它每个属主模块下各出现一次 —— 那是要点)。 */
export function functionsForModule(moduleId: string): FunctionEntry[] {
    return FUNCTIONS.filter((f) => f.modules.includes(moduleId))
}

/**
 * 按名字取范围 / 功能:`requireModule(MOD.finance)`、`requireFunction(FN.margin)`。
 * 显式列出而不是从 id 派生 —— 拼错一个名字是编译期错误,派生出来的只是 undefined。
 */
const byId = (id: string): AccessScope => {
    const m = SCOPES.find((x) => x.id === id)
    if (!m) throw new Error(`lib/modules.ts: no scope for ${id}`)
    return m
}
const fnByHref = (href: string): FunctionEntry => {
    const f = FUNCTIONS.find((x) => x.href === href)
    if (!f) throw new Error(`lib/modules.ts: no function for ${href}`)
    return f
}

/** 【权限范围】—— 页面守卫用。键与 NAV-REG-1 逐字相同,169 处调用点一行未改。 */
export const MOD = {
    sales: byId('/sales'),
    suppliers: byId('/suppliers'),
    purchasing: byId('/purchasing'),
    customers: byId('/customers'),
    materials: byId('/materials'),
    pricing: byId('/pricing'),
    inbound: byId('/inbound'),
    output: byId('/output'),
    processing: byId('/operation'),
    inventory: byId('/inventory'),
    stocktakes: byId('/stocktakes'),
    finance: byId('/finance'),
    tasks: byId('/tasks'),
    hr: byId('/hr'),
    logistics: byId('/logistics'),
} as const

export const FN = {
    margin: fnByHref('/margin'),
    deleted: fnByHref('/settings/deleted'),
    pricing: fnByHref('/pricing'),
    commissions: fnByHref('/commissions'),
    contracts: fnByHref('/contracts'),
    licences: fnByHref('/purchasing/licences'),
    approvals: fnByHref('/settings/approvals'),
    /** NAV-CLEANUP-1:两张落地页各自的判据 —— 页面守卫按名取,拼错是编译期错误。 */
    financeHome: fnByHref('/finance'),
    settingsHome: fnByHref('/settings'),
} as const
