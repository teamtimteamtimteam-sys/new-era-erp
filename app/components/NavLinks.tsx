// app/components/NavLinks.tsx
'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const NAV_ITEMS = [
    { href: '/suppliers', key: 'nav.suppliers' },
    { href: '/customers', key: 'nav.customers' },
    { href: '/materials', key: 'nav.materials' },
    { href: '/inbound', key: 'nav.inbound' },
    { href: '/output', key: 'nav.output' },
    { href: '/processing', key: 'nav.processing' },
    { href: '/inventory', key: 'nav.inventory' },
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
