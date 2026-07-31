'use client'

// app/purchasing/Subnav.tsx
// 采购模块子导航(采购单 / 付款条款模板),样式端口自 finance/Subnav。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const ITEMS = [
    { href: '/purchasing/orders', key: 'purchasing.subnav.orders' },
    { href: '/purchasing/payment-terms', key: 'purchasing.subnav.templates' },
]

export default function Subnav() {
    const pathname = usePathname()
    const t = useTranslations()

    return (
        <nav className="flex gap-1 overflow-x-auto mb-6">
            {ITEMS.map((item) => {
                const active = pathname === item.href || pathname.startsWith(item.href + '/')
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
