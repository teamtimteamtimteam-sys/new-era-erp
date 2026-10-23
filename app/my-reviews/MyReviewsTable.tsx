'use client'

// app/my-reviews/MyReviewsTable.tsx
// CONV-5 · 我评的评估那张表。
// 【一个组件,两处用】open / closed 两段共用它 —— 与转换前那个 renderTable
// 局部函数一样,不是两张不同的表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xInt } from '@/lib/export/cells'

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
    /** TABLE-EXPORT-2b-1:导出用的原始日历日(YYYY-MM-DD),不是屏幕上格式化过的那串字。 */
    periodStartRaw: string
    periodEndRaw: string
    status: string
    statusCls: string
    daysInState: number
}

// TABLE-EXPORT-2b-1:两段各自一个导出 —— 文件名与标题由页面按段给
export default function MyReviewsTable({ rows, exportName, exportTitle }: { rows: MyReviewRow[]; exportName: string; exportTitle: string }) {
    const t = useTranslations()

    // ★ 手机上留【被评估人】与【状态】—— 人是身份,状态是"这一份轮到我做了没有"。
    const columns: ExportableColumn<MyReviewRow>[] = [
        {
            key: 'employee', header: t('reviews.employee'), priority: true, className: 'whitespace-nowrap',
            // 职位 · 部门在屏幕上跟在人名旁边 —— 同一格,照写
            exportAs: (r) => xText([`${r.employeeCode} ${r.employeeName}`.trim(), r.subtitle].filter(Boolean).join(' · ')),
            render: (r) => (
                <>
                    <Link href={`/my-reviews/${r.id}`} className="hover:underline app-link">
                        <span>{r.employeeCode}</span> {r.employeeName}
                    </Link>
                    {r.subtitle && <span className="ml-2 text-xs text-gray-500">{r.subtitle}</span>}
                </>
            ),
        },
        { key: 'type', header: t('reviews.type'), render: (r) => r.typeLabel, exportAs: (r) => xText(r.typeLabel) },
        { key: 'cycle', header: t('reviews.cycle'), render: (r) => r.cycleName, exportAs: (r) => xText(r.cycleName) },
        {
            key: 'period', header: t('reviews.period'), className: 'whitespace-nowrap text-xs',
            render: (r) => `${r.periodStart} → ${r.periodEnd}`,
            // 一格两个日期,写不成一个日期格 —— 原始 YYYY-MM-DD 写成文字(与 /hr/reviews 同一个做法)
            exportAs: (r) => xText(`${r.periodStartRaw} → ${r.periodEndRaw}`),
        },
        {
            key: 'status', header: t('reviews.status'), priority: true,
            exportAs: (r) => xText(t(`reviews.status_${r.status}`)),
            render: (r) => (
                <span className={'inline-block rounded px-2 py-0.5 text-xs ' + r.statusCls}>
                    {t(`reviews.status_${r.status}`)}
                </span>
            ),
        },
        {
            key: 'inState', header: t('reviews.inState'), className: 'whitespace-nowrap text-gray-600',
            render: (r) => t('hr.daysRemaining', { n: r.daysInState }),
            // 屏幕是「N 天」;导出写那个天数本身
            exportAs: (r) => xInt(r.daysInState),
        },
    ]

    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} className="mb-6"
            exportSpec={{ name: exportName, title: exportTitle }} />
    )
}
