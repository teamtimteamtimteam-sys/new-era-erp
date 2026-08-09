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
    // 【/metal-prices 不在这里,而且不是漏了 —— 它【不受模块把关】,理由在数据自己身上】
    //
    // metal_prices 的 SELECT 策略写的是 `USING (true)`(db/tables/metal_prices.sql):
    // 任何 authenticated 都读得到,一行不遮。这是【数据自己声明它是公开的】—— 行情是
    // 市场报价,不是本公司的秘密。页面守卫的职责是把"进不去"说出来,而不是发明一道
    // 数据库没有的门:给这四页挂上 module.pricing.view,屏幕上就会对一个数据库愿意
    // 完整回答的人显示"你没有权限",那是【UI 比数据严】,而且严得没有任何东西背书。
    //
    // 【所以这里的规矩是:把关跟着数据自己的 RLS 走,不跟模块目录走。】权限目录里
    // module.pricing.view 那一条的描述("公式、计价器与行情")是【目录的措辞】,不是
    // 策略;两者冲突时以策略为准。下一个读到这里的人请不要把 alsoCovers 加回来 ——
    // 要改回去,先改 metal_prices 的 SELECT 策略,再改这里,顺序不能反。
    //
    // 【/pricing 本身仍然受管】:公式(pricing_formulas)与计价器不是公开数据 ——
    // 那里面有 payable_pct / treatment_charge_usd_per_tonne / flat_discount_pct,
    // 是谈出来的商务条款,且本来就是 perm2b 撤销的列。区别就在这一句上。
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
