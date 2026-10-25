'use client'

// app/hr/reviews/ReviewsTable.tsx
// CONV-5 · 绩效评估登记簿那张表。
// 【在当前状态里停了多久】在服务端用 daysInState 算好 —— 它读的是 reviewShared
// 里那套状态时间戳判据,列描述符不该重新实现它(CONV-1 §① 通则)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xInt } from '@/lib/export/cells'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { ListSort } from '@/lib/listSort'

export type ReviewsTableRow = {
    id: string
    employeeLabel: string
    employeeCode: string
    typeLabel: string
    cycleName: string
    periodStart: string
    periodEnd: string
    /** TABLE-EXPORT-1:导出用的原始日历日(YYYY-MM-DD),不是屏幕上格式化过的那串字。 */
    periodStartRaw: string
    periodEndRaw: string
    reviewerCode: string | null
    reviewerName: string | null
    status: string
    statusCls: string
    daysInState: number
}

export default function ReviewsTable({ rows, empty, exportUrl, sort, shown, total }: {
    rows: ReviewsTableRow[]; empty: React.ReactNode; exportUrl: string
    /** TABLE-FEATURES-1 Q9:在数据库里排(reviewsRows.ts 的 REVIEWS_SORT) */
    sort: ListSort; shown: number; total: number
}) {
    const t = useTranslations()
    const sortHref = useSortHref()

    // ★ 手机上留【员工】与【状态】—— 员工是身份,状态是这张登记簿存在的理由
    //   (一份在 submitted 里躺了三周的评估就是一件待办)。停留天数紧跟状态,
    //   但它是读到这一行之后才要问的,进展开区。
    const columns: ExportableColumn<ReviewsTableRow>[] = [
        {
            key: 'employee', header: t('reviews.employee'), priority: true, className: 'whitespace-nowrap',
            exportAs: (r) => xText(`${r.employeeCode} ${r.employeeLabel}`.trim()),
            render: (r) => (
                <Link href={`/hr/reviews/${r.id}`} className="hover:underline app-link">
                    <span>{r.employeeCode}</span> {r.employeeLabel}
                </Link>
            ),
        },
        { key: 'type', sortable: true, header: t('reviews.type'), render: (r) => r.typeLabel, exportAs: (r) => xText(r.typeLabel) },
        { key: 'cycle', header: t('reviews.cycle'), render: (r) => r.cycleName, exportAs: (r) => xText(r.cycleName) },
        {
            key: 'period', sortable: true, header: t('reviews.period'), className: 'whitespace-nowrap text-xs',
            render: (r) => `${r.periodStart} → ${r.periodEnd}`,
            // 一格装着两个日期,写不成一个 Excel 日期格 —— 用原始 YYYY-MM-DD 写成文字(可排序、可复制),不用屏幕上的格式
            exportAs: (r) => xText(`${r.periodStartRaw} → ${r.periodEndRaw}`),
        },
        {
            key: 'reviewer', header: t('reviews.reviewer'), className: 'whitespace-nowrap',
            // 【没有评估人】是一句话,不是空白 —— 导出照写那句话
            exportAs: (r) => xText(r.reviewerCode ? `${r.reviewerCode} ${r.reviewerName ?? ''}`.trim() : t('reviews.noReviewer')),
            render: (r) =>
                r.reviewerCode ? (
                    <>
                        <span>{r.reviewerCode}</span> {r.reviewerName}
                    </>
                ) : (
                    <span className="text-red-700">{t('reviews.noReviewer')}</span>
                ),
        },
        {
            key: 'status', sortable: true, header: t('reviews.status'), priority: true,
            exportAs: (r) => xText(t(`reviews.status_${r.status}`)),
            render: (r) => (
                <span className={'inline-block rounded px-2 py-0.5 text-xs ' + r.statusCls}>
                    {t(`reviews.status_${r.status}`)}
                </span>
            ),
        },
        {
            key: 'inState', header: t('reviews.inState'), className: 'whitespace-nowrap text-gray-600',
            // 屏幕是「N 天」;导出写那个天数本身(一个整数)
            exportAs: (r) => xInt(r.daysInState),
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
            exportSpec={{ name: 'hr-reviews', title: t('hr.subnav.reviews'), serverRows: exportUrl }}
            sorting={{ mode: 'server', coverage: { shown, total }, active: sort, href: sortHref }}
        />
    )
}
