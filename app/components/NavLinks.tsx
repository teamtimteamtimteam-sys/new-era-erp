// app/components/NavLinks.tsx
'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const NAV_ITEMS = [
    { href: '/suppliers', key: 'nav.suppliers' },
    // 采购(采购单 / 付款条款模板)紧跟供应商 —— 采购单是"跟这家供应商谈成了什么"的存档
    { href: '/purchasing', key: 'nav.purchasing' },
    { href: '/customers', key: 'nav.customers' },
    { href: '/materials', key: 'nav.materials' },
    // 定价板块(公式 / 计价器 / 行情)。/metal-prices 的路由仍然有效,只是不再单独占一个
    // 顶级导航位 —— 入口收进定价首页与定价子导航,避免同一件事出现两个并列入口。
    { href: '/pricing', key: 'nav.pricing' },
    { href: '/inbound', key: 'nav.inbound' },
    { href: '/output', key: 'nav.output' },
    { href: '/processing', key: 'nav.processing' },
    { href: '/inventory', key: 'nav.inventory' },
    { href: '/stocktakes', key: 'nav.stocktakes' },
    { href: '/finance', key: 'nav.finance' },
    { href: '/tasks', key: 'nav.tasks' },
]

export default function NavLinks() {
    const pathname = usePathname()
    const t = useTranslations()

    return (
        <nav className="flex gap-1 overflow-x-auto px-6 pb-2">
            {NAV_ITEMS.map((item) => {
                const active =
                    pathname === item.href || pathname.startsWith(item.href + '/')
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
