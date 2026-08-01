'use client'

// app/hr/leave/LeaveSubnav.tsx
// 请假管理内部的第二层导航。年度操作(授予/结转)【单独占一格】——
// 它们一年只跑一两次,但整本假期账都靠它们,埋起来就没人记得跑。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const ITEMS = [
    { href: '/hr/leave', key: 'leave.subnav.requests' },
    { href: '/hr/leave/balances', key: 'leave.subnav.balances' },
    { href: '/hr/leave/calendar', key: 'leave.subnav.calendar' },
    { href: '/hr/leave/grants', key: 'leave.subnav.grants' },
    { href: '/hr/leave/types', key: 'leave.subnav.types' },
    { href: '/hr/leave/holidays', key: 'leave.subnav.holidays' },
]

export default function LeaveSubnav() {
    const pathname = usePathname()
    const t = useTranslations()
    const active =
        ITEMS.filter((i) => i.href !== '/hr/leave').find(
            (i) => pathname === i.href || pathname.startsWith(i.href + '/')
        )?.href ?? '/hr/leave'

    return (
        <nav className="flex gap-1 mb-6 flex-wrap">
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
