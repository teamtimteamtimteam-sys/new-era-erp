'use client'

// app/hr/leave/LeaveRequestsTable.tsx
// CONV-5 · 请假申请那张表。
// 【待办清单,不是档案】待审在最前的排序在服务端做好(page.tsx),
// 这里不接管排序 —— 否则那条"待办优先"的次序会被一次点击洗掉。
// TABLE-FEATURES-1 Q9/Q12:表头排序交给数据库(leaveRows.ts 的 LEAVE_SORT)—— 点一列是读者自己换掉默认的待审优先,
// 不点就仍是待审优先(在截断之前排好的)。浏览器这一侧仍然不排。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum } from '@/lib/export/cells'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { ListSort } from '@/lib/listSort'

export type LeaveRequestRow = {
    id: string
    code: string
    isException: boolean
    employeeLabel: string
    typeLabel: string
    startDate: string
    endDate: string
    /** TABLE-EXPORT-1:导出用的原始日历日(YYYY-MM-DD),不是屏幕上格式化过的那串字。 */
    startDateRaw: string
    endDateRaw: string
    days: number
    status: string
}

const STATUS_CLS: Record<string, string> = {
    pending: 'bg-amber-100 text-amber-800',
    approved: 'bg-green-100 text-green-800',
    rejected: 'bg-red-100 text-red-800',
    cancelled: 'bg-gray-100 text-gray-600',
}

export default function LeaveRequestsTable({ rows, empty, exportUrl, sort, shown, total }: {
    rows: LeaveRequestRow[]; empty: React.ReactNode; exportUrl: string
    /** TABLE-FEATURES-1 Q9:在数据库里排(leaveRows.ts 的 LEAVE_SORT;默认 `pending` 不对应任何表头) */
    sort: ListSort; shown: number; total: number
}) {
    const t = useTranslations()
    const sortHref = useSortHref()

    // ★ 手机上留【单号】与【状态】—— 单号是身份,而这是一张待办清单:
    //   状态就是它存在的理由(谁还等着批)。日期区间进展开区。
    const columns: ExportableColumn<LeaveRequestRow>[] = [
        {
            key: 'code', sortable: true, header: t('leave.code'), priority: true, className: 'text-xs',
            // 例外标记照屏幕带上 —— 它是这张单要另眼看的理由,不能在文件里消失
            exportAs: (r) => xText(r.isException ? `${r.code} (${t('leave.exception')})` : r.code),
            render: (r) => (
                <>
                    <Link href={`/hr/leave/${r.id}`} className="hover:underline app-link">
                        {r.code}
                    </Link>
                    {r.isException && (
                        <span className="ml-2 rounded bg-purple-100 px-1.5 py-0.5 text-xs text-purple-800">
                            {t('leave.exception')}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'employee', header: t('leave.employee'), render: (r) => r.employeeLabel, exportAs: (r) => xText(r.employeeLabel) },
        { key: 'type', header: t('leave.type'), render: (r) => r.typeLabel, exportAs: (r) => xText(r.typeLabel) },
        { key: 'dates', sortable: true, header: t('leave.dates'), render: (r) => `${r.startDate} → ${r.endDate}`,
            // 一格装着两个日期,写不成一个 Excel 日期格 —— 用原始 YYYY-MM-DD 写成文字(可排序、可复制),不用屏幕上的格式
            exportAs: (r) => xText(`${r.startDateRaw} → ${r.endDateRaw}`) },
        { key: 'days', sortable: true, header: t('leave.days'), align: 'right', render: (r) => r.days, exportAs: (r) => xNum(r.days, 'qty') },
        {
            key: 'status', sortable: true, header: t('leave.status'), priority: true,
            exportAs: (r) => xText(t(`leave.status_${r.status}`)),
            render: (r) => (
                <span className={`rounded px-2 py-0.5 text-xs ${STATUS_CLS[r.status] ?? ''}`}>
                    {t(`leave.status_${r.status}`)}
                </span>
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            exportSpec={{ name: 'hr-leave-requests', title: t('leave.subnav.requests'), serverRows: exportUrl }}
            sorting={{ mode: 'server', coverage: { shown, total }, active: sort, href: sortHref }}
        />
    )
}
