'use client'

// app/settings/permissions/Subnav.tsx
// 权限管理内部子导航(账号 / 角色 / 权限速查)。样式端口自 finance/Subnav。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const ITEMS = [
    { href: '/settings/permissions', key: 'permissions.subnav.users' },
    { href: '/settings/permissions/roles', key: 'permissions.subnav.roles' },
    { href: '/settings/permissions/reference', key: 'permissions.subnav.reference' },
]

export default function Subnav() {
    const pathname = usePathname()
    const t = useTranslations()

    // 最长前缀优先;都不中则账号页
    const active =
        ITEMS.slice(1).find((i) => pathname === i.href || pathname.startsWith(i.href + '/'))?.href ??
        '/settings/permissions'

    return (
        <nav className="flex gap-1 border-b border-gray-200 mb-6 pb-2">
            {ITEMS.map((i) => (
                <Link
                    key={i.href}
                    href={i.href}
                    className={
                        'whitespace-nowrap rounded px-3 py-1 text-sm ' +
                        (active === i.href
                            ? 'bg-gray-900 text-white'
                            : 'text-gray-600 hover:bg-gray-100 hover:text-gray-900')
                    }
                >
                    {t(i.key)}
                </Link>
            ))}
        </nav>
    )
}
