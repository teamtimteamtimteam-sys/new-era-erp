'use client'

// app/hr/overtime/BatchesTable.tsx
// OVERTIME-1:加班批的登记簿 —— 一批一行。手机上留【批次】与【状态】:身份,以及"它现在在谁手里"。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type BatchRow = {
    id: string
    label: string
    periodMonth: string
    status: string
    lineCount: number
    people: number
    hours: number
}

export const OVERTIME_STATUS_CLS: Record<string, string> = {
    draft: 'bg-gray-100 text-gray-700',
    submitted: 'bg-amber-100 text-amber-800',
    approved: 'bg-green-100 text-green-800',
    rejected: 'bg-red-100 text-red-800',
    reversed: 'bg-gray-100 text-gray-500',
    discarded: 'bg-gray-100 text-gray-500',
}

export default function BatchesTable({ rows, empty }: { rows: BatchRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    const columns: Column<BatchRow>[] = [
        {
            key: 'label', header: t('overtime.colBatch'), priority: true,
            render: (r) => (
                <Link className="hover:underline app-link" href={`/hr/overtime/${r.id}`}>{r.label}</Link>
            ),
        },
        {
            key: 'status', header: t('overtime.colStatus'), priority: true,
            render: (r) => (
                <span className={'rounded px-2 py-0.5 text-xs ' + (OVERTIME_STATUS_CLS[r.status] ?? 'bg-gray-100 text-gray-600')}>
                    {t('overtime.status_' + r.status)}
                </span>
            ),
        },
        { key: 'people', header: t('overtime.colPeople'), align: 'right', render: (r) => r.people },
        { key: 'lines', header: t('overtime.colLines'), align: 'right', render: (r) => r.lineCount },
        { key: 'hours', header: t('overtime.colHours'), align: 'right', render: (r) => r.hours.toFixed(2) },
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
