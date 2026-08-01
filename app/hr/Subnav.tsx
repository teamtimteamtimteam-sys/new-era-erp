'use client'

// app/hr/Subnav.tsx
// 人力资源模块子导航(概览 / 员工 / 部门 / 薪资 / 培训),样式端口自 finance/Subnav。
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

const ITEMS = [
    { href: '/hr', key: 'hr.subnav.overview' },
    { href: '/hr/employees', key: 'hr.subnav.employees' },
    { href: '/hr/departments', key: 'hr.subnav.departments' },
    { href: '/hr/payroll', key: 'hr.subnav.payroll' },
    { href: '/hr/leave', key: 'hr.subnav.leave' },
    { href: '/hr/claims', key: 'hr.subnav.claims' },
    { href: '/hr/training', key: 'hr.subnav.training' },
]

export default function Subnav() {
    const pathname = usePathname()
    const t = useTranslations()

    // 最长前缀优先:/hr/employees/x 亮 employees 而不是 overview;都不中则概览
    const activeHref =
        ITEMS.filter((i) => i.href !== '/hr').find(
            (i) => pathname === i.href || pathname.startsWith(i.href + '/')
        )?.href ?? '/hr'

    return (
        <nav className="flex gap-1 overflow-x-auto mb-6">
            {ITEMS.map((item) => {
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
