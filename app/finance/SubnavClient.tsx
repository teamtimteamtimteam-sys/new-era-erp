'use client'

// app/finance/SubnavClient.tsx
// 财务模块内部子导航的【渲染一半】。'use client' 是因为活动态要 usePathname;
// 判权限要读库,所以判断在 Subnav.tsx(服务端)做完再传进来。
// 样式端口自 NavLinks,活动态按最长前缀匹配(/finance/journal/new 亮 newEntry 而非 journal)。
//
// 【NAV-REG-1:跨模块功能不写在这两份清单里】/margin 从前在 ITEMS 与 ordered 里
// 各有一行手写的常量。它现在由 functionItems 传进来 —— 地址、标签、以及"进不进得去"
// 全部来自 lib/modules.ts 的 FN.margin,与 /margin 页面自己的守卫是同一份判据。
// 【位置一字未动】仍然在价格敞口与结账之间;顺序归 Phase 8 管,本刀只换来源。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

/** 注册表派生的功能入口:标签与判据都不是本文件的。 */
export type FunctionItem = { href: string; key: string; allowed: boolean }

/** ordered 里的这个记号 = "把 functionItems 展开在这里"。 */
const REGISTRY_SLOT = '@registry' as const

const ITEMS = [
    { href: '/finance/journal/new', key: 'finance.subnav.newEntry' },
    { href: '/finance/journal', key: 'finance.subnav.journal' },
    { href: '/finance/pnl', key: 'finance.subnav.pnl' },
    { href: '/finance/balance-sheet', key: 'finance.subnav.balanceSheet' },
    { href: '/finance/cashflow', key: 'finance.subnav.cashflow' },
    // CASHFLOW-1:预测紧挨着现金流量表 —— 一个是已经发生的钱、一个是还没发生的。
    // 【这个文件里有两份清单,必须一起加】ITEMS 决定活动态的最长前缀匹配,
    // ordered 决定实际画出来的顺序;只加一份,要么链接不出现、要么高亮不对。
    { href: '/finance/cash-forecast', key: 'finance.subnav.cashForecast' },
    { href: '/finance/receivables', key: 'finance.subnav.receivables' },
    { href: '/finance/invoices', key: 'finance.subnav.invoices' },
    { href: '/finance/credit-notes', key: 'finance.subnav.creditNotes' },
    { href: '/finance/payables', key: 'finance.subnav.payables' },
    { href: '/finance/payments', key: 'finance.subnav.payments' },
    { href: '/finance/expenses', key: 'finance.subnav.expenses' },
    { href: '/finance/claims', key: 'finance.subnav.expenseClaims' },
    { href: '/finance/freight', key: 'finance.subnav.freight' },
    { href: '/finance/assets', key: 'finance.subnav.assets' },
    { href: '/finance/month-end', key: 'finance.subnav.monthEnd' },
    { href: '/finance/payroll-payments', key: 'finance.subnav.payrollPay' },
    { href: '/finance/processing-costs', key: 'finance.subnav.costSettle' },
    { href: '/finance/revaluation', key: 'finance.subnav.reval' },
    { href: '/finance/cost-variance', key: 'finance.subnav.variance' },
    // COMM-1:价格敞口。【这个文件里有两份清单,必须一起加】—— 见上面 cash-forecast
    // 那条注释:ITEMS 决定活动态的最长前缀匹配,ordered 决定实际画出来的顺序。
    { href: '/finance/price-exposure', key: 'priceExposure.entryLink' },
    // 【/margin 不在这两份清单里了】它是注册表来的(见文件抬头);活动态匹配
    // 在下面把 functionItems 并进来,所以站在 /margin 上子导航照样高亮。
    { href: '/finance/close', key: 'finance.subnav.close' },
    { href: '/finance/gst', key: 'finance.subnav.gst' },
    { href: '/finance/wht', key: 'finance.subnav.wht' },
    { href: '/finance/packs', key: 'finance.subnav.pack' },
    { href: '/finance/settings', key: 'finance.subnav.settings' },
    { href: '/finance/company', key: 'finance.subnav.company' },
    { href: '/finance/fx', key: 'finance.subnav.fx' },
    { href: '/finance/bank', key: 'finance.subnav.bank' },
]

export default function SubnavClient({ functionItems }: { functionItems: FunctionItem[] }) {
    const pathname = usePathname()
    const t = useTranslations()

    // 最长前缀优先:第一个命中的 ITEMS 项为活动项;都不中则 /finance 本身(试算平衡)
    // 活动态要把注册表来的那些也算进去,否则站在 /margin 上整条子导航都不高亮。
    const matchable = [...ITEMS, ...functionItems]
    const activeHref =
        matchable.find((i) => pathname === i.href || pathname.startsWith(i.href + '/'))?.href ??
        '/finance'

    // 展示顺序:试算平衡 / 损益 / 资产负债 / 分录 / 手工分录 / 应收 / 应付 / 收付款 / 月结 / 设置 / 汇率
    const ordered = [
        { href: '/finance', key: 'finance.trialBalance' },
        { href: '/finance/pnl', key: 'finance.subnav.pnl' },
        { href: '/finance/balance-sheet', key: 'finance.subnav.balanceSheet' },
    { href: '/finance/cashflow', key: 'finance.subnav.cashflow' },
        { href: '/finance/cash-forecast', key: 'finance.subnav.cashForecast' },
        { href: '/finance/journal', key: 'finance.subnav.journal' },
        { href: '/finance/journal/new', key: 'finance.subnav.newEntry' },
        { href: '/finance/receivables', key: 'finance.subnav.receivables' },
        { href: '/finance/invoices', key: 'finance.subnav.invoices' },
        { href: '/finance/credit-notes', key: 'finance.subnav.creditNotes' },
        { href: '/finance/payables', key: 'finance.subnav.payables' },
        { href: '/finance/payments', key: 'finance.subnav.payments' },
        { href: '/finance/expenses', key: 'finance.subnav.expenses' },
        { href: '/finance/claims', key: 'finance.subnav.expenseClaims' },
    { href: '/finance/freight', key: 'finance.subnav.freight' },
    { href: '/finance/assets', key: 'finance.subnav.assets' },
        { href: '/finance/month-end', key: 'finance.subnav.monthEnd' },
        { href: '/finance/payroll-payments', key: 'finance.subnav.payrollPay' },
        { href: '/finance/processing-costs', key: 'finance.subnav.costSettle' },
        { href: '/finance/revaluation', key: 'finance.subnav.reval' },
        { href: '/finance/cost-variance', key: 'finance.subnav.variance' },
        { href: '/finance/price-exposure', key: 'priceExposure.entryLink' },
        REGISTRY_SLOT,
        { href: '/finance/close', key: 'finance.subnav.close' },
    { href: '/finance/gst', key: 'finance.subnav.gst' },
        { href: '/finance/wht', key: 'finance.subnav.wht' },
        { href: '/finance/packs', key: 'finance.subnav.pack' },
        { href: '/finance/settings', key: 'finance.subnav.settings' },
        { href: '/finance/company', key: 'finance.subnav.company' },
        { href: '/finance/fx', key: 'finance.subnav.fx' },
        { href: '/finance/bank', key: 'finance.subnav.bank' },
    ]

    // 记号就地展开成注册表来的那几项(位置不变)
    const rendered: FunctionItem[] = ordered.flatMap((item) =>
        item === REGISTRY_SLOT ? functionItems : [{ ...item, allowed: true }],
    )

    return (
        <nav className="flex gap-1 overflow-x-auto mb-6">
            {rendered.map((item) => {
                // 【进不去的功能:具名的限制,不是缺席】—— 与 NavLinks 同一条(R4),
                // 同一套措辞(common.restricted + dashboard.restrictedHint)。
                if (!item.allowed) {
                    return (
                        <span
                            key={item.href}
                            data-module-restricted="1"
                            title={t('dashboard.restrictedHint')}
                            className="whitespace-nowrap rounded px-3 py-1 text-sm text-gray-400 cursor-default"
                        >
                            {t(item.key)} · {t('common.restricted')}
                        </span>
                    )
                }
                const active = item.href === activeHref
                return (
                    <Link
                        key={item.href}
                        href={item.href}
                        className={
                            'whitespace-nowrap rounded px-3 py-1 text-sm ' +
                            (active
                                ? 'bg-gray-900 text-white'
                                : 'text-gray-600 hover:bg-gray-100 hover:text-gray-900')
                        }
                    >
                        {t(item.key)}
                    </Link>
                )
            })}
        </nav>
    )
}
