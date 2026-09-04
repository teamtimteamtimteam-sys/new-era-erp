// ⚠️ 【生成文件,不要手改】由 scripts/gen-deep-routes.mjs 产出。
// 改了它 `npm run build` 会红。判据与理由写在那个脚本的抬头里。
//
// 本次生成时的实测:路由 198 条,深度分布 {"0":1,"1":31,"2":138,"3":26,"4":2},
// 深(≥3)的 28 条 —— 这就是 Tim 的 D4 说的"23 条深路由"。
//
// 段是【路由模式】的段:动态段写成 [x],路由组已经去掉(它们不出现在 URL 里)。

/** 深路由的模式,升序。运行时把 usePathname() 按段匹配到其中一条。 */
export const DEEP_ROUTES: readonly string[] = [
    '/finance/bank/import',
    '/finance/bank/statements',
    '/finance/bank/statements/[id]',
    '/finance/bank/statements/[id]/reconcile',
    '/finance/fx/bulk',
    '/hr/leave/balances',
    '/hr/leave/calendar',
    '/hr/leave/grants',
    '/hr/leave/holidays',
    '/hr/leave/types',
    '/hr/reviews/cycles',
    '/hr/reviews/scale',
    '/inbound/receive/done/[id]',
    '/inventory/reports/ledger',
    '/inventory/reports/safety',
    '/inventory/reports/snapshot',
    '/inventory/reports/violations',
    '/purchasing/orders/[id]/amend',
    '/sales/customers/overlap',
    '/sales/orders/[id]/amend',
    '/tools/pricing/calculator',
    '/tools/pricing/formulas',
    '/tools/pricing/formulas/[id]/edit',
    '/tools/pricing/formulas/new',
    '/tools/pricing/metal-prices',
    '/tools/pricing/metal-prices/[id]/edit',
    '/tools/pricing/metal-prices/bulk',
    '/tools/pricing/metal-prices/new',
]

/** 生成时的深度分布 —— 让下一次 diff 一眼看得出是哪一档变了。 */
export const DEPTH_HISTOGRAM: Readonly<Record<string, number>> = {"0":1,"1":31,"2":138,"3":26,"4":2}

/**
 * 面包屑里【注册表答不上来的那些段】。每一个要 messages/{en,zh}.ts 里一句
 * breadcrumb.<段>;少一句 `npm run build` 会红(check-i18n 的 MANIFEST 从这里现读)。
 */
export const BREADCRUMB_SEGMENTS = ['amend', 'balances', 'bulk', 'calculator', 'calendar', 'cycles', 'done', 'edit', 'formulas', 'grants', 'holidays', 'import', 'ledger', 'metal-prices', 'new', 'overlap', 'receive', 'reconcile', 'safety', 'scale', 'snapshot', 'statements', 'types', 'violations'] as const
