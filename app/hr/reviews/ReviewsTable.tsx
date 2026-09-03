'use client'

// app/hr/reviews/ReviewsTable.tsx
// CONV-5 · 绩效评估登记簿那张表。
// 【在当前状态里停了多久】在服务端用 daysInState 算好 —— 它读的是 reviewShared
// 里那套状态时间戳判据,列描述符不该重新实现它(CONV-1 §① 通则)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ReviewsTableRow = {
    id: string
    employeeLabel: string
    employeeCode: string
    typeLabel: string
    cycleName: string
    periodStart: string
    periodEnd: string
    reviewerCode: string | null
    reviewerName: string | null
    status: string
    statusCls: string
    daysInState: number
}

export default function ReviewsTable({ rows, empty }: { rows: ReviewsTableRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【员工】与【状态】—— 员工是身份,状态是这张登记簿存在的理由
    //   (一份在 submitted 里躺了三周的评估就是一件待办)。停留天数紧跟状态,
    //   但它是读到这一行之后才要问的,进展开区。
    const columns: Column<ReviewsTableRow>[] = [
        {
            key: 'employee', header: t('reviews.employee'), priority: true, className: 'whitespace-nowrap',
            render: (r) => (
                <Link href={`/hr/reviews/${r.id}`} className="text-blue-600 hover:underline">
                    <span className="font-mono">{r.employeeCode}</span> {r.employeeLabel}
                </Link>
            ),
        },
        { key: 'type', header: t('reviews.type'), render: (r) => r.typeLabel },
        { key: 'cycle', header: t('reviews.cycle'), render: (r) => r.cycleName },
        {
            key: 'period', header: t('reviews.period'), className: 'whitespace-nowrap font-mono text-xs',
            render: (r) => `${r.periodStart} → ${r.periodEnd}`,
        },
        {
            key: 'reviewer', header: t('reviews.reviewer'), className: 'whitespace-nowrap',
            render: (r) =>
                r.reviewerCode ? (
                    <>
                        <span className="font-mono">{r.reviewerCode}</span> {r.reviewerName}
                    </>
                ) : (
                    <span className="text-red-700">{t('reviews.noReviewer')}</span>
                ),
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

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
