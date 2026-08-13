// lib/modules.ts
// 【模块清单:一处定义,两处消费】导航条(app/components/NavLinks.tsx)与首页卡片
// (app/page.tsx)从此读同一份数据。与 reprice_split、supplierQuery.ts 同一条规矩:
// 两份清单只要分开写,就一定会漂 —— 而这一份漂了的后果是【有人看见一个他进不去的入口】。
//
// 【为什么这个文件里没有任何服务端 import】NavLinks 是 'use client'。纯数据 + 类型
// 才能被两侧同时 import;权限过滤在服务端做(lib/moduleAccess.ts),结果作为 prop 传下来。
//
// 【顺序就是导航顺序】首页把同一份清单按 section 分组渲染,组内保持本数组的相对顺序 ——
// 实测与 OPS-15 之前手写的三组卡片逐张同序,所以这次换成共享清单【没有改动首页内容】。
// section 为 null 表示【只进导航、不出卡片】(任务板当前如此,与改造前一致)。

export type ModuleSection = 'masterData' | 'operations' | 'reports'

export type ModuleEntry = {
    /** 模块入口路由;模块下所有子路由都按同一个 permission 把关 */
    href: string
    /** 导航条标签 */
    navKey: string
    /** 首页卡片标题 / 说明(section 为 null 时不用) */
    titleKey: string
    descKey: string
    /** 进入本模块所需的权限码 —— 与 db/tables/permissions.sql 的 module.<x>.view 一一对应 */
    permission: string
    /** 首页卡片分组;null = 不在首页出卡片 */
    section: ModuleSection | null
    /**
     * 不在 href 前缀底下、但同属本模块的路由。
     * 【当前无人使用】—— 保留这个字段是因为"模块入口路由与它管辖的路由不同名"
     * 是迟早会再出现的形状;唯一用过它的 /metal-prices 已按 RLS 撤回把关(见下)。
     */
    alsoCovers?: string[]
}

// 【/margin 不在这份清单里,而且不是漏了 —— 它装不进这个形状】
// 批次毛利跨两个模块:收入在财务,分摊成本在加工,而【没有任何 live 角色同时持有
// 两者】(admin / auditor / gm 除外)。它要的谓词是
//     data.view_prices AND (module.finance.view OR module.processing.view)
// 而 ModuleEntry.permission 是【一个字符串】—— 一行一个码,表达不了 AND/OR。
//
// 【没有把它硬塞进导航,理由是 OPS-15 那条】在 NavLinks 里写一个绕过本清单的
// <Link href="/margin">,就是"谁能看见什么"的第二份定义 —— 而且它对 finance 与
// operations 会各错一次(一个看得见进得去、另一个看得见也进得去,但清单说不出为什么)。
// 要改的话,该改的是 permission 的类型(string | { all?: string[]; any?: string[] }),
// 求值只在 lib/moduleAccess.ts 一处,NavLinks 与首页卡片消费的仍是一个布尔值;
// moduleForPath 要一并决定是继续对 /margin 返回 null,还是也学会谓词。
//
// 【在那之前它靠三个入口,每一个都在读者已经持有的模块里】
//   * 财务子导航(app/finance/Subnav.tsx)—— 给财务侧的读者
//   * 加工列表页页头(app/processing/page.tsx)—— 给加工侧的读者
//   * 产出批次页上的【本批毛利数字本身】(MAR-1)—— 问题产生的地方就给答案
//   * 首页 margin_cost_not_allocated 支(MAR-1)—— 支级谓词表达得了这个 OR
export const MODULES: ModuleEntry[] = [
    { href: '/suppliers', navKey: 'nav.suppliers', titleKey: 'home.suppliersTitle', descKey: 'home.suppliersDesc',
      permission: 'module.suppliers.view', section: 'masterData' },
    // 采购在收货之前 —— 流程顺序:下单 → 收货 → 加工
    { href: '/purchasing', navKey: 'nav.purchasing', titleKey: 'home.purchasingTitle', descKey: 'home.purchasingDesc',
      permission: 'module.purchasing.view', section: 'operations' },
    { href: '/customers', navKey: 'nav.customers', titleKey: 'home.customersTitle', descKey: 'home.customersDesc',
      permission: 'module.customers.view', section: 'masterData' },
    { href: '/materials', navKey: 'nav.materials', titleKey: 'home.materialsTitle', descKey: 'home.materialsDesc',
      permission: 'module.materials.view', section: 'masterData' },
    // 【/metal-prices 不在这里,而且不是漏了 —— 它不归模块目录管,理由在数据自己身上】
    //
    // 【规矩:守卫跟着数据自己的 RLS 走,不跟模块目录走。】
    // 而一张表的 RLS 本来就有【读】和【写】两个答案,它们可以不一样 —— metal_prices
    // 的这两个答案恰恰不一样(db/tables/metal_prices.sql):
    //
    //   SELECT               USING (true)                                → 公开
    //   INSERT/UPDATE/DELETE has_permission('module.pricing.edit')       → 受管
    //
    // 所以 app/metal-prices/ 底下四页带着【两种守卫】,那是同一条规则的两半,不是
    // 四页里有一页例外:
    //
    //   /metal-prices(列表,只读)           不设守卫 —— 读策略放行任何人
    //   /metal-prices/{new,bulk,[id]/edit}   requireEditPermission('module.pricing.edit', …)
    //
    // 【读的那一半】行情是市场报价,不是本公司的秘密,数据自己声明它公开。页面守卫的
    // 职责是把"进不去"说出来,而不是发明一道数据库没有的门:给列表页挂上
    // module.pricing.view,屏幕上就会对一个数据库愿意完整回答的人显示"你没有权限",
    // 那是【UI 比数据严】,而且严得没有任何东西背书。
    //
    // 【写的那一半】反过来,数据库确实有那道门,只是它叫 module.pricing.edit。用
    // module.pricing.view 去把关会同时错两头:挡下有 edit 而无 view 的人,又放进有
    // view 而无 edit 的人 —— 后者填完整张表单再被 42501 拒收(AGENTS.md §"永远不要
    // 为服务端必然拒绝的动作渲染提交控件")。
    //
    // 权限目录里 module.pricing.view 那一条的描述("公式、计价器与行情")是【目录的
    // 措辞】,不是策略;两者冲突时以策略为准。下一个读到这里的人请不要把 alsoCovers
    // 加回来 —— 要改回去,先改 metal_prices 的策略,再改代码,顺序不能反。
    //
    // 【/pricing 本身仍然整个受管】:公式(pricing_formulas)与计价器不是公开数据 ——
    // 它的 SELECT 策略就是 has_permission('module.pricing.view'),而 payable_pct /
    // treatment_charge_usd_per_tonne / flat_discount_pct 是谈出来的商务条款,本来就是
    // perm2b 撤销、藏在 data.view_prices 后面的列。区别就在这一句上。
    { href: '/pricing', navKey: 'nav.pricing', titleKey: 'home.pricingTitle', descKey: 'home.pricingDesc',
      permission: 'module.pricing.view', section: 'masterData' },
    { href: '/inbound', navKey: 'nav.inbound', titleKey: 'home.inboundTitle', descKey: 'home.inboundDesc',
      permission: 'module.inbound.view', section: 'operations' },
    { href: '/output', navKey: 'nav.output', titleKey: 'home.outputTitle', descKey: 'home.outputDesc',
      permission: 'module.output.view', section: 'operations' },
    { href: '/processing', navKey: 'nav.processing', titleKey: 'home.processingTitle', descKey: 'home.processingDesc',
      permission: 'module.processing.view', section: 'operations' },
    { href: '/inventory', navKey: 'nav.inventory', titleKey: 'home.inventoryTitle', descKey: 'home.inventoryDesc',
      permission: 'module.inventory.view', section: 'reports' },
    { href: '/stocktakes', navKey: 'nav.stocktakes', titleKey: 'home.stocktakesTitle', descKey: 'home.stocktakesDesc',
      permission: 'module.stocktakes.view', section: 'operations' },
    // SO-1-fu:销售是一个【真模块】—— 自己的单据、自己的角色、自己的操作面。
    // 【additive】:只增一条,不动 NAV-1 冻结的那次重排。
    { href: '/sales/orders', navKey: 'nav.sales', titleKey: 'home.salesTitle', descKey: 'home.salesDesc',
      permission: 'module.sales.view', section: 'operations' },
    { href: '/finance', navKey: 'nav.finance', titleKey: 'home.financeTitle', descKey: 'home.financeDesc',
      permission: 'module.finance.view', section: 'reports' },
    // 任务板改造前就只在导航里、不在首页卡片里 —— section: null 把这件事写下来而不是让它
    // 成为"清单里少了一行"的意外(OPS-15 明令:除把关外不动首页内容)。
    { href: '/tasks', navKey: 'nav.tasks', titleKey: 'home.tasksTitle', descKey: 'home.tasksDesc',
      permission: 'module.tasks.view', section: null },
    { href: '/hr', navKey: 'nav.hr', titleKey: 'home.hrTitle', descKey: 'home.hrDesc',
      permission: 'module.hr.view', section: 'reports' },
]

/** 首页三组的顺序与标题(组内顺序 = MODULES 的相对顺序)。 */
export const SECTIONS: { id: ModuleSection; titleKey: string }[] = [
    { id: 'masterData', titleKey: 'home.sectionMasterData' },
    { id: 'operations', titleKey: 'home.sectionOperations' },
    { id: 'reports', titleKey: 'home.sectionReports' },
]

/**
 * 路由 → 所需权限码。子路由继承模块入口的权限(/finance/pnl 要 module.finance.view)。
 * 最长前缀优先,避免 /inbound 误配到 /inbound-xxx 这类将来可能出现的名字。
 * 返回 null = 本路由不受模块权限管辖(/me、/my-reviews、/login、/ 等)。
 */
export function moduleForPath(pathname: string): ModuleEntry | null {
    let best: ModuleEntry | null = null
    let bestLen = -1
    for (const m of MODULES) {
        for (const base of [m.href, ...(m.alsoCovers ?? [])]) {
            if ((pathname === base || pathname.startsWith(base + '/')) && base.length > bestLen) {
                best = m
                bestLen = base.length
            }
        }
    }
    return best
}

/**
 * 页面守卫按名字取模块:`requireModule(MOD.finance)`。
 * 显式列出而不是从 href 派生 —— 拼错一个名字是编译期错误,派生出来的只是 undefined。
 */
const byHref = (href: string): ModuleEntry => {
    const m = MODULES.find((x) => x.href === href)
    if (!m) throw new Error(`lib/modules.ts: no module for ${href}`)
    return m
}

export const MOD = {
    sales: byHref('/sales/orders'),
    suppliers: byHref('/suppliers'),
    purchasing: byHref('/purchasing'),
    customers: byHref('/customers'),
    materials: byHref('/materials'),
    pricing: byHref('/pricing'),
    inbound: byHref('/inbound'),
    output: byHref('/output'),
    processing: byHref('/processing'),
    inventory: byHref('/inventory'),
    stocktakes: byHref('/stocktakes'),
    finance: byHref('/finance'),
    tasks: byHref('/tasks'),
    hr: byHref('/hr'),
} as const
