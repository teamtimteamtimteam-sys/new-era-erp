'use client'

// app/my-reviews/MyReviewsTable.tsx
// CONV-5 · 我评的评估那张表。
// 【一个组件,两处用】open / closed 两段共用它 —— 与转换前那个 renderTable
// 局部函数一样,不是两张不同的表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type MyReviewRow = {
    id: string
    employeeCode: string
    employeeName: string
    /** 职位 · 部门,已在服务端按 locale 拼好;没有就是 null。 */
    subtitle: string | null
    typeLabel: string
    cycleName: string
    periodStart: string
    periodEnd: string
    status: string
    statusCls: string
    daysInState: number
}

export default function MyReviewsTable({ rows }: { rows: MyReviewRow[] }) {
    const t = useTranslations()

    // ★ 手机上留【被评估人】与【状态】—— 人是身份,状态是"这一份轮到我做了没有"。
    const columns: Column<MyReviewRow>[] = [
        {
            key: 'employee', header: t('reviews.employee'), priority: true, className: 'whitespace-nowrap',
            render: (r) => (
                <>
                    <Link href={`/my-reviews/${r.id}`} className="text-blue-600 hover:underline">
                        <span className="font-mono">{r.employeeCode}</span> {r.employeeName}
                    </Link>
                    {r.subtitle && <span className="ml-2 text-xs text-gray-500">{r.subtitle}</span>}
                </>
            ),
        },
        { key: 'type', header: t('reviews.type'), render: (r) => r.typeLabel },
        { key: 'cycle', header: t('reviews.cycle'), render: (r) => r.cycleName },
        {
            key: 'period', header: t('reviews.period'), className: 'whitespace-nowrap font-mono text-xs',
            render: (r) => `${r.periodStart} → ${r.periodEnd}`,
        },
        {
            key: 'status', header: t('reviews.status'), priority: true,
            render: (r) => (
                <span className={'inline-block rounded px-2 py-0.5 text-xs ' + r.statusCls}>
                    {t(`reviews.status_${r.status}`)}
                </span>
            ),
        },
        {
            key: 'inState', header: t('reviews.inState'), className: 'whitespace-nowrap text-gray-600',
            render: (r) => t('hr.daysRemaining', { n: r.daysInState }),
        },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} className="mb-6" />
}
