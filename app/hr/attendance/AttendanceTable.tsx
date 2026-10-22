'use client'

// app/hr/attendance/AttendanceTable.tsx
// CONV-5 · 考勤底稿登记簿那张表(一个月一行)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xInt } from '@/lib/export/cells'

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
    const columns: ExportableColumn<AttendanceRow>[] = [
        {
            key: 'code', header: t('attendance.colCode'), priority: true,
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link className="hover:underline app-link" href={`/hr/attendance/${r.periodId}`}>
                    {r.code}
                </Link>
            ),
        },
        {
            key: 'status', header: t('attendance.colStatus'),
            exportAs: (r) => xText(t('attendance.status.' + r.status)),
            render: (r) => (
                <span className={'rounded px-2 py-0.5 text-xs ' + (STATUS_CLS[r.status ?? ''] ?? 'bg-gray-100 text-gray-600')}>
                    {t('attendance.status.' + r.status)}
                </span>
            ),
        },
        { key: 'lines', header: t('attendance.colLines'), align: 'right', render: (r) => r.lineCount, exportAs: (r) => xInt(r.lineCount) },
        {
            // 【未记行数】而不是"工时之和"—— 后者把"记了、是零"与"没人记过"混成一件事
            key: 'unrecorded', header: t('attendance.colUnrecorded'), priority: true, align: 'right',
            exportAs: (r) => xInt(r.unrecordedCount),
            render: (r) => (
                <span className={(r.unrecordedCount ?? 0) > 0 ? 'text-amber-700 font-medium' : 'text-gray-400'}>
                    {r.unrecordedCount}
                </span>
            ),
        },
        { key: 'otNormal', header: t('attendance.colOtNormal'), align: 'right', render: (r) => r.otNormalHours, exportAs: (r) => xNum(r.otNormalHours, 'qty') },
        { key: 'otRestDay', header: t('attendance.colOtRestDay'), align: 'right', render: (r) => r.otRestDayHours, exportAs: (r) => xNum(r.otRestDayHours, 'qty') },
        { key: 'otHoliday', header: t('attendance.colOtHoliday'), align: 'right', render: (r) => r.otPublicHolidayHours, exportAs: (r) => xNum(r.otPublicHolidayHours, 'qty') },
        { key: 'unpaidDays', header: t('attendance.colUnpaidDays'), align: 'right', render: (r) => r.unpaidDays, exportAs: (r) => xNum(r.unpaidDays, 'qty') },
        {
            key: 'payroll', header: t('attendance.colPayroll'), className: 'text-xs text-gray-600',
            // TABLE-EXPORT-1:屏幕上没过账是一个破折号(不是一句话),导出留空格
            exportAs: (r) => xText(r.payrollPosted ? t('attendance.payrollPosted') : null),
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
            exportSpec={{ name: 'hr-attendance', title: t('attendance.title') }}
        />
    )
}
