'use client'

// app/purchasing/Subnav.tsx
// 采购模块子导航(采购单 / 付款条款模板),样式端口自 finance/Subnav。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const ITEMS = [
    { href: '/purchasing/orders', key: 'purchasing.subnav.orders' },
    // GRN-1b:收货差异。【它必须在导航里】—— 差异此前唯一的到达方式是敲 URL,
    // 而那不是导航,那是记忆(SAL-B6 那一课:一个没有入口的页面等于不存在)。
    { href: '/purchasing/discrepancies', key: 'purchasing.subnav.discrepancies' },
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
