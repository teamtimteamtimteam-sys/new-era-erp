'use client'

// app/hr/attendance/AttendanceTable.tsx
// CONV-5 · 考勤底稿登记簿那张表(一个月一行)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type AttendanceRow = {
    periodId: string
    code: string
    status: string
    lineCount: number
    unrecordedCount: number
    otNormalHours: number
    otRestDayHours: number
    otPublicHolidayHours: number
    unpaidDays: number
    payrollPosted: boolean
}

const STATUS_CLS: Record<string, string> = {
    open: 'bg-amber-100 text-amber-800',
    complete: 'bg-green-100 text-green-800',
}

export default function AttendanceTable({ rows, empty }: { rows: AttendanceRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【期间编号】与【未记行数】—— 编号是身份,而抬头写明这一页的读者
    //   要一眼看出的第一件事就是"这个月记满了没有",那正是未记行数这一列。
    const columns: Column<AttendanceRow>[] = [
        {
            key: 'code', header: t('attendance.colCode'), priority: true,
            render: (r) => (
                <Link className="text-blue-600 hover:underline" href={`/hr/attendance/${r.periodId}`}>
                    {r.code}
                </Link>
            ),
        },
        {
            key: 'status', header: t('attendance.colStatus'),
            render: (r) => (
                <span className={'rounded px-2 py-0.5 text-xs ' + (STATUS_CLS[r.status ?? ''] ?? 'bg-gray-100 text-gray-600')}>
                    {t('attendance.status.' + r.status)}
                </span>
            ),
        },
        { key: 'lines', header: t('attendance.colLines'), align: 'right', render: (r) => r.lineCount },
        {
            // 【未记行数】而不是"工时之和"—— 后者把"记了、是零"与"没人记过"混成一件事
            key: 'unrecorded', header: t('attendance.colUnrecorded'), priority: true, align: 'right',
            className: 'font-mono',
            render: (r) => (
                <span className={(r.unrecordedCount ?? 0) > 0 ? 'text-amber-700 font-medium' : 'text-gray-400'}>
                    {r.unrecordedCount}
                </span>
            ),
        },
        { key: 'otNormal', header: t('attendance.colOtNormal'), align: 'right', render: (r) => r.otNormalHours },
        { key: 'otRestDay', header: t('attendance.colOtRestDay'), align: 'right', render: (r) => r.otRestDayHours },
        { key: 'otHoliday', header: t('attendance.colOtHoliday'), align: 'right', render: (r) => r.otPublicHolidayHours },
        { key: 'unpaidDays', header: t('attendance.colUnpaidDays'), align: 'right', render: (r) => r.unpaidDays },
        {
            key: 'payroll', header: t('attendance.colPayroll'), className: 'text-xs text-gray-600',
            render: (r) => (r.payrollPosted ? t('attendance.payrollPosted') : '—'),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.periodId}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
