'use client'

// app/hr/leave/balances/BalancesTable.tsx
// CONV-5 · 全员年假余额那张表。
// 【90 天内到期的天数高亮】那是"再不休就烂掉"的部分,提前看见才来得及安排。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type BalanceRow = {
    employeeId: string
    employeeLabel: string
    granted: string
    consumed: string
    available: string
    // ★ LEAVE-BAL-1:待批与「可请」—— 可用是审批时比的数,可请是提交时比的数(Tim Q10)
    pending: string
    bookable: string
    expiringSoon: number
}

export default function BalancesTable({ rows, empty }: { rows: BalanceRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【员工】与【可用天数】—— 员工是身份,可用天数是批准人据以拍板的
    //   那一个数字,也就是这张表存在的理由。已授予/已休进展开区。
    const columns: Column<BalanceRow>[] = [
        { key: 'employee', header: t('leave.employee'), priority: true, render: (r) => r.employeeLabel },
        { key: 'granted', header: t('leave.granted'), align: 'right', render: (r) => r.granted },
        { key: 'taken', header: t('leave.taken'), align: 'right', render: (r) => r.consumed },
        {
            key: 'available', header: t('leave.available'), priority: true, align: 'right',
            className: 'font-medium', render: (r) => r.available,
        },
        { key: 'pending', header: t('leave.pending'), align: 'right', render: (r) => r.pending },
        { key: 'bookable', header: t('leave.bookable'), align: 'right', render: (r) => r.bookable },
        {
            key: 'expiring', header: t('leave.expiringSoon'), align: 'right',
            render: (r) =>
                r.expiringSoon > 0 ? (
                    <span className="rounded bg-amber-100 px-2 py-0.5 text-amber-800">{r.expiringSoon}</span>
                ) : (
                    '—'
                ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.employeeId}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
