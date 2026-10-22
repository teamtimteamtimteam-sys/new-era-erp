'use client'

// app/hr/leave/balances/BalancesTable.tsx
// CONV-5 · 全员年假余额那张表。
// 【90 天内到期的天数高亮】那是"再不休就烂掉"的部分,提前看见才来得及安排。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum } from '@/lib/export/cells'

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
    /** TABLE-EXPORT-1:导出用的原始天数(Excel 里是一个数);读不到余额时是 null(屏幕上那个破折号)。 */
    raw: {
        granted: number | null
        consumed: number | null
        available: number | null
        pending: number | null
        bookable: number | null
    }
}

export default function BalancesTable({ rows, empty }: { rows: BalanceRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【员工】与【可用天数】—— 员工是身份,可用天数是批准人据以拍板的
    //   那一个数字,也就是这张表存在的理由。已授予/已休进展开区。
    const columns: ExportableColumn<BalanceRow>[] = [
        { key: 'employee', header: t('leave.employee'), priority: true, render: (r) => r.employeeLabel, exportAs: (r) => xText(r.employeeLabel) },
        { key: 'granted', header: t('leave.granted'), align: 'right', render: (r) => r.granted, exportAs: (r) => xNum(r.raw.granted, 'qty') },
        { key: 'taken', header: t('leave.taken'), align: 'right', render: (r) => r.consumed, exportAs: (r) => xNum(r.raw.consumed, 'qty') },
        {
            key: 'available', header: t('leave.available'), priority: true, align: 'right',
            className: 'font-medium', render: (r) => r.available,
            exportAs: (r) => xNum(r.raw.available, 'qty'),
        },
        { key: 'pending', header: t('leave.pending'), align: 'right', render: (r) => r.pending, exportAs: (r) => xNum(r.raw.pending, 'qty') },
        { key: 'bookable', header: t('leave.bookable'), align: 'right', render: (r) => r.bookable, exportAs: (r) => xNum(r.raw.bookable, 'qty') },
        {
            key: 'expiring', header: t('leave.expiringSoon'), align: 'right',
            // 屏幕上 0 画成破折号(没有要到期的);导出照原值写 0 —— 那是同一件事,而 Excel 里要的是一个数
            exportAs: (r) => xNum(r.expiringSoon, 'qty'),
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
            exportSpec={{ name: 'hr-leave-balances', title: t('leave.subnav.balances') }}
        />
    )
}
