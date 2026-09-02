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
    // 【/metal-prices 不在这里,而且不是漏了 —— 它不归权限范围管,理由在数据自己身上】
    //
    // 【规矩:守卫跟着数据自己的 RLS 走。】而一张表的 RLS 本来就有【读】和【写】
    // 两个答案,它们可以不一样 —— metal_prices 的这两个答案恰恰不一样
    // (db/tables/metal_prices.sql):
    //
    //   SELECT               USING (true)                                → 公开
    //   INSERT/UPDATE/DELETE has_permission('module.pricing.edit')       → 受管
    //
    // 所以 app/metal-prices/ 底下四页带着【两种守卫】:列表页不设守卫,
    // {new,bulk,[id]/edit} 走 requireEditPermission('module.pricing.edit', …)。
    // 给列表页挂上 module.pricing.view,屏幕上就会对一个数据库愿意完整回答的人
    // 显示"你没有权限",那是【UI 比数据严】,而且严得没有任何东西背书。
    // ★ IA-BUILD-1 / D6:它在【导航】上现在同属采购与销售(见 FUNCTIONS),
    //   而那一条的判据同样是"最松的、仍然连贯的那一个" —— 见那里的抬头。
    { id: '/pricing', navKey: 'nav.pricing', permission: 'module.pricing.view' },
    { id: '/inbound', navKey: 'nav.inbound', permission: 'module.inbound.view' },
    { id: '/output', navKey: 'nav.output', permission: 'module.output.view' },
    { id: '/processing', navKey: 'nav.processing', permission: 'module.processing.view' },
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
    { id: 'tasks', navKey: 'nav.tasks' },
    { id: 'settings', navKey: 'nav.settings' },
]

/**
 * 财务的【第三级】分组。Tim 的 D1:只有财务有第三级,因为它的 30 条装不进一张平表。
 * 六个组名是他给的:报表 / 分录 / 应收 / 应付 / 期末 / 配置。
 * 【顺序就是这个数组的顺序】,而每一条二级条目用 group 指名自己属于哪一组。
 */
/** 【拥有第三级的那一个模块】。Tim 的 D1:**只有财务有第三级。** */
export const FINANCE_MODULE_ID = 'finance'

export const FINANCE_GROUPS = [
    'finance.group.reports',
    'finance.group.entries',
    'finance.group.receivables',
    'finance.group.payables',
    'finance.group.periodEnd',
    'finance.group.config',
] as const
export type FinanceGroup = (typeof FINANCE_GROUPS)[number]

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
    /** 第三级分组。**只有财务用**,其余模块只有两级。 */
    group?: FinanceGroup
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
const P_BULK_IMPORT = 'action.bulk_import'

export const FUNCTIONS: readonly FunctionEntry[] = [
    // ══ 采购 Purchasing ═════════════════════════════════════════════════════
    { href: '/purchasing', navKey: 'purchasing.subnav.overview', modules: ['purchasing'], permission: P_PURCHASING },
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
    { href: '/processing/orders', navKey: 'processing.subnav.workOrders', modules: ['operation'], permission: P_PROCESSING },
    { href: '/processing', navKey: 'processing.subnav.runs', modules: ['operation'], permission: P_PROCESSING },
    { href: '/processing/wip', navKey: 'processing.subnav.wip', modules: ['operation'], permission: P_PROCESSING },
    { href: '/processing/handovers', navKey: 'processing.subnav.handovers', modules: ['operation'], permission: P_PROCESSING },

    // ══ 销售 Sales ══════════════════════════════════════════════════════════
    { href: '/sales/quotes', navKey: 'sales.subnav.quotes', modules: ['sales'], permission: P_SALES },
    { href: '/sales/orders', navKey: 'sales.subnav.orders', modules: ['sales'], permission: P_SALES },
    { href: '/customers', navKey: 'nav.customers', modules: ['sales'], permission: P_CUSTOMERS },
    { href: '/customers/overlap', navKey: 'nav.customerOverlap', modules: ['sales'], permission: P_CUSTOMERS },

    // ══ 财务 Finance —— 唯一有第三级的模块。六组顺序见 FINANCE_GROUPS ═══════
    // 【组内顺序与组的划分】条目本身与它们的先后【逐字取自】此前的
    // app/finance/SubnavClient.tsx 的 ordered 数组(勘察 D3:那是 DERIVED 的);
    // **分好的六个组名是 Tim 给的**(D1),哪一条归哪一组是本刀的判断。
    { href: '/finance', navKey: 'finance.trialBalance', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.reports' },
    { href: '/finance/pnl', navKey: 'finance.subnav.pnl', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.reports' },
    { href: '/finance/balance-sheet', navKey: 'finance.subnav.balanceSheet', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.reports' },
    { href: '/finance/cashflow', navKey: 'finance.subnav.cashflow', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.reports' },
    { href: '/finance/cash-forecast', navKey: 'finance.subnav.cashForecast', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.reports' },
    { href: '/finance/price-exposure', navKey: 'priceExposure.entryLink', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.reports' },
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
    { href: '/finance/settings', navKey: 'finance.subnav.settings', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.config' },
    { href: '/finance/company', navKey: 'finance.subnav.company', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.config' },
    { href: '/finance/fx', navKey: 'finance.subnav.fx', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.config' },
    { href: '/finance/bank', navKey: 'finance.subnav.bank', modules: ['finance'], permission: P_FINANCE, group: 'finance.group.config' },

    // ══ 库存 Inventory ══════════════════════════════════════════════════════
    { href: '/inventory', navKey: 'inventory.subnav.overview', modules: ['inventory'], permission: P_INVENTORY },
    { href: '/inventory/locations', navKey: 'inventory.subnav.locations', modules: ['inventory'], permission: P_INVENTORY },
    // ★ M6:盘点降成库存的二级。**它自带 module.stocktakes.view,而模块可进性是
    //   从二级条目推导的,所以"只有盘点权限的人进得去库存"自动成立。**
    { href: '/stocktakes', navKey: 'nav.stocktakes', modules: ['inventory'], permission: P_STOCKTAKES },
    { href: '/materials', navKey: 'nav.materials', modules: ['inventory'], permission: P_MATERIALS },

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

    // ══ 任务 Tasks —— 只有一条,而它仍然是一个一级模块(Tim 的 D1) ═════════
    { href: '/tasks', navKey: 'nav.tasks', modules: ['tasks'], permission: P_TASKS },

    // ══ 设置 Settings ═══════════════════════════════════════════════════════
    // 【没有 module.settings.view 这个码,本刀也不铸一个】铸码是迁移级的动作,
    // 而"铸哪个码、授给谁"正是 NAV-REG-1 的 R3 里 Tim 保留给自己的裁定。
    // 所以设置这个一级的可进性,和其余八个一样,由它名下三条二级条目推导出来。
    { href: '/settings/permissions', navKey: 'nav.settings', modules: ['settings'], permission: P_MANAGE_PERMISSIONS },
    { href: '/settings/dictionaries', navKey: 'nav.dictionaries', modules: ['settings'], permission: P_DICTIONARIES },
    { href: '/settings/import', navKey: 'nav.import', modules: ['settings'], permission: P_BULK_IMPORT },
    // ★ D7:审批链从 /finance/settings 搬到设置,把关码跟着搬 ——
    //   从 module.finance.view 换成 action.manage_permissions。
    //   ★【必须照直说的一件事】这块面板是【只读】的,而且系统里【根本没有】
    //     配置审批链的界面:app/ 下没有任何东西写 approvals_enabled /
    //     approval_level1_role_code / approval_level2_role_code /
    //     approval_threshold_base 这四列,线上那一行是直接改库改出来的。
    //     所以本刀搬走的是【那扇窗】,不是一个控制器。见 docs/information-architecture.md。
    { href: '/settings/approvals', navKey: 'finance.approvals.title', modules: ['settings'], permission: P_MANAGE_PERMISSIONS },


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
    // 【双】库存报表:R5 —— 估值/对账/追溯既是库存的问题,也是财务的问题。
    { href: '/inventory/reports', navKey: 'inventory.subnav.reports', modules: ['inventory', 'finance'], permission: P_INVENTORY, group: 'finance.group.reports' },
    // 【双】收货 / 进料批次:采购的收货腿,也是库存的入库腿 —— 勘察 C1/C6。
    { href: '/inbound', navKey: 'nav.inbound', modules: ['purchasing', 'inventory'], permission: P_INBOUND },
    // 【双】产出批次:**这是 Tim 自己举的例子** —— 一批产出既是加工结果,也是可售库存。
    { href: '/output', navKey: 'nav.output', modules: ['operation', 'inventory'], permission: P_OUTPUT },
    // ══ D6:定价与行情【同属采购与销售】,一份判据,不设第十个模块 ═══════════
    // 定价服务采购(payable %、扣杂)与销售(报价)两侧;塞进任何一侧都会让
    // 另一侧看不见。/margin 是这条的先例。
    { href: '/pricing', navKey: 'nav.pricing', modules: ['purchasing', 'sales'], permission: P_PRICING },
    { href: '/pricing/formulas', navKey: 'pricing.subnav.formulas', modules: ['purchasing', 'sales'], permission: P_PRICING },
    { href: '/pricing/calculator', navKey: 'pricing.subnav.calculator', modules: ['purchasing', 'sales'], permission: P_PRICING },
    // ★★ 金属行情:**Tim 点名的那一个例外 —— 判据取【最松的、仍然连贯的那一个】** ★★
    //
    // metal_prices 的 SELECT 策略是 `USING (true)` —— 【读是公开的】,只有写受管
    // (module.pricing.edit)。所以这一条的判据是 `{ all: [] }`:
    //   **一个空的 all 通过 allows() 恒为真 → 任何登录用户都看得见这个入口。**
    //
    // 【为什么是这个值而不是 module.pricing.view】那会让界面【比数据严】:
    // 一个数据库愿意完整回答的人,会在屏幕上读到"你没有权限"。本仓库有一条更老的
    // 规矩说的是同一件事 —— 守卫跟着数据自己的 RLS 走,不跟目录的措辞走。
    // 【为什么不是"干脆不放进导航"】那就退回成一处缺席,而 D5 的全部内容是
    // 缺席与受限必须分得开。它既然人人读得到,就该人人看得见入口。
    // 【它仍然不是无门的】写那一半在 /metal-prices/{new,bulk,[id]/edit} 上由
    // requireEditPermission('module.pricing.edit') 把关,一个字没动。
    { href: '/metal-prices', navKey: 'nav.metalPrices', modules: ['purchasing', 'sales'], permission: { all: [] } },
    // 【双】运费单:既是一笔应付,也是一票货的成本 —— 勘察 C2。
    { href: '/finance/freight', navKey: 'finance.subnav.freight', modules: ['logistics', 'finance'], permission: P_FINANCE, group: 'finance.group.payables' },
    // MAR-1:批次毛利。收入在财务,分摊成本在加工,而【没有任何 live 角色同时持有
    // 两者】(admin / auditor / gm 除外)—— 挂进任一模块的路由树就会挡掉另一半读者。
    // 谓词与 db/views/batch_margin.sql 逐字同形。
    // 【收窄的那一半(any)是模块,相与的那一半(all)是数据类】—— 这个结构本身
    // 就是拒绝措辞的依据(见 moduleGuard 的 requireFunction)。
    {
        href: '/margin',
        navKey: 'margin.title',
        modules: ['operation', 'finance'],
        permission: { all: ['data.view_prices'], any: [P_FINANCE, P_PROCESSING] },
        group: 'finance.group.reports',
    },

    // ══ 跨全部模块的那一条 ══════════════════════════════════════════════════
    // AUDEL-3:被删记录。它跨【七支、六个码】,而这六个码正是视图 deleted_records
    // 每一行自带的那个 permission 列(db/views/deleted_records.sql)——
    // 这里不新造码,只把那份并集写成一个谓词。
    // 【all 是空的】:没有哪个码是人人必须持有的,由 any 单独决定。
    // 【行一级的过滤仍然在视图里】本谓词只回答"这一页对你有没有意义"。
    // 【它的属主是六个模块】—— 用新的九模块 id 重述,一个读者都没有少:
    //   inbound/output/stocktakes → 库存与运营;purchasing → 采购;sales → 销售;
    //   processing → 运营。
    {
        href: '/deleted',
        navKey: 'nav.deleted',
        modules: ['purchasing', 'operation', 'sales', 'inventory'],
        permission: {
            all: [],
            any: [P_INBOUND, P_OUTPUT, P_PROCESSING, P_STOCKTAKES, P_PURCHASING, P_SALES],
        },
    },
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
    processing: byId('/processing'),
    inventory: byId('/inventory'),
    stocktakes: byId('/stocktakes'),
    finance: byId('/finance'),
    tasks: byId('/tasks'),
    hr: byId('/hr'),
    logistics: byId('/logistics'),
} as const

export const FN = {
    margin: fnByHref('/margin'),
    deleted: fnByHref('/deleted'),
    metalPrices: fnByHref('/metal-prices'),
    pricing: fnByHref('/pricing'),
    commissions: fnByHref('/commissions'),
    contracts: fnByHref('/contracts'),
    licences: fnByHref('/purchasing/licences'),
    approvals: fnByHref('/settings/approvals'),
} as const
