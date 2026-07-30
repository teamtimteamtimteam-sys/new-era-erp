'use client'

// app/finance/Subnav.tsx
// 财务模块内部子导航(试算平衡 / 分录 / 手工分录 / 应收 / 应付 / 收付款 / 设置 / 汇率),
// 样式端口自 NavLinks,活动态按最长前缀匹配(/finance/journal/new 亮 newEntry 而非 journal)。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const ITEMS = [
    { href: '/finance/journal/new', key: 'finance.subnav.newEntry' },
    { href: '/finance/journal', key: 'finance.subnav.journal' },
    { href: '/finance/pnl', key: 'finance.subnav.pnl' },
    { href: '/finance/balance-sheet', key: 'finance.subnav.balanceSheet' },
    { href: '/finance/receivables', key: 'finance.subnav.receivables' },
    { href: '/finance/invoices', key: 'finance.subnav.invoices' },
    { href: '/finance/payables', key: 'finance.subnav.payables' },
    { href: '/finance/payments', key: 'finance.subnav.payments' },
    { href: '/finance/expenses', key: 'finance.subnav.expenses' },
    { href: '/finance/close', key: 'finance.subnav.close' },
    { href: '/finance/settings', key: 'finance.subnav.settings' },
    { href: '/finance/company', key: 'finance.subnav.company' },
    { href: '/finance/fx', key: 'finance.subnav.fx' },
    { href: '/finance/bank', key: 'finance.subnav.bank' },
]

export default function Subnav() {
    const pathname = usePathname()
    const t = useTranslations()

    // 最长前缀优先:第一个命中的 ITEMS 项为活动项;都不中则 /finance 本身(试算平衡)
    const activeHref =
        ITEMS.find((i) => pathname === i.href || pathname.startsWith(i.href + '/'))?.href ??
        '/finance'

    // 展示顺序:试算平衡 / 损益 / 资产负债 / 分录 / 手工分录 / 应收 / 应付 / 收付款 / 月结 / 设置 / 汇率
    const ordered = [
        { href: '/finance', key: 'finance.trialBalance' },
        { href: '/finance/pnl', key: 'finance.subnav.pnl' },
        { href: '/finance/balance-sheet', key: 'finance.subnav.balanceSheet' },
        { href: '/finance/journal', key: 'finance.subnav.journal' },
        { href: '/finance/journal/new', key: 'finance.subnav.newEntry' },
        { href: '/finance/receivables', key: 'finance.subnav.receivables' },
        { href: '/finance/invoices', key: 'finance.subnav.invoices' },
        { href: '/finance/payables', key: 'finance.subnav.payables' },
        { href: '/finance/payments', key: 'finance.subnav.payments' },
        { href: '/finance/expenses', key: 'finance.subnav.expenses' },
        { href: '/finance/close', key: 'finance.subnav.close' },
        { href: '/finance/settings', key: 'finance.subnav.settings' },
        { href: '/finance/company', key: 'finance.subnav.company' },
        { href: '/finance/fx', key: 'finance.subnav.fx' },
        { href: '/finance/bank', key: 'finance.subnav.bank' },
    ]

    return (
        <nav className="flex gap-1 overflow-x-auto mb-6">
            {ordered.map((item) => {
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
