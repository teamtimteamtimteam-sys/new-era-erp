'use client'

// app/hr/leave/LeaveRequestsTable.tsx
// CONV-5 · 请假申请那张表。
// 【待办清单,不是档案】待审在最前的排序在服务端做好(page.tsx),
// 这里不接管排序 —— 否则那条"待办优先"的次序会被一次点击洗掉。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type LeaveRequestRow = {
    id: string
    code: string
    isException: boolean
    employeeLabel: string
    typeLabel: string
    startDate: string
    endDate: string
    days: number
    status: string
}

const STATUS_CLS: Record<string, string> = {
    pending: 'bg-amber-100 text-amber-800',
    approved: 'bg-green-100 text-green-800',
    rejected: 'bg-red-100 text-red-800',
    cancelled: 'bg-gray-100 text-gray-600',
}

export default function LeaveRequestsTable({ rows, empty }: { rows: LeaveRequestRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【单号】与【状态】—— 单号是身份,而这是一张待办清单:
    //   状态就是它存在的理由(谁还等着批)。日期区间进展开区。
    const columns: Column<LeaveRequestRow>[] = [
        {
            key: 'code', header: t('leave.code'), priority: true, className: 'font-mono text-xs',
            render: (r) => (
                <>
                    <Link href={`/hr/leave/${r.id}`} className="text-blue-600 hover:underline">
                        {r.code}
                    </Link>
                    {r.isException && (
                        <span className="ml-2 rounded bg-purple-100 px-1.5 py-0.5 text-[10px] text-purple-800">
                            {t('leave.exception')}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'employee', header: t('leave.employee'), render: (r) => r.employeeLabel },
        { key: 'type', header: t('leave.type'), render: (r) => r.typeLabel },
        { key: 'dates', header: t('leave.dates'), render: (r) => `${r.startDate} → ${r.endDate}` },
        { key: 'days', header: t('leave.days'), align: 'right', className: 'font-mono', render: (r) => r.days },
        {
            key: 'status', header: t('leave.status'), priority: true,
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
        />
    )
}
