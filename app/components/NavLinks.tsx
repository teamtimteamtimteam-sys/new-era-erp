// app/components/NavLinks.tsx
'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'

const NAV_ITEMS = [
    { href: '/suppliers', label: '供应商' },
    { href: '/customers', label: '客户' },
    { href: '/materials', label: '物料' },
    { href: '/inbound', label: '进料' },
    { href: '/output', label: '产出' },
    { href: '/processing', label: '加工' },
    { href: '/inventory', label: '库存' },
]

export default function NavLinks() {
    const pathname = usePathname()

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
                        {item.label}
                    </Link>
                )
            })}
        </nav>
    )
}
