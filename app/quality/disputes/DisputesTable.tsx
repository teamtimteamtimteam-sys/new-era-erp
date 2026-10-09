'use client'

// app/quality/disputes/DisputesTable.tsx
// MES-6a-1 · 化验争议清单那张表。手机上留【批次】与【状态】—— 批次是身份,状态是这一页的问题(哪几件还挡着定价与结算)。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type DisputeRow = {
    id: string
    batchCode: string
    statusLabel: string
    open: boolean
    assays: string
    diff: string
    beyond: boolean
    governing: string
    opened: string
}

export default function DisputesTable({ rows, empty }: { rows: DisputeRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: Column<DisputeRow>[] = [
        {
            key: 'batch', header: t('quality.disputes.colBatch'), priority: true,
            render: (r) => <Link href={`/quality/disputes/${r.id}`} className="hover:underline app-link">{r.batchCode}</Link>,
        },
        {
            key: 'status', header: t('quality.disputes.colStatus'), priority: true,
            render: (r) => <span className={`px-2 py-1 rounded text-xs ${r.open ? 'bg-amber-100' : 'bg-gray-200'}`}>{r.statusLabel}</span>,
        },
        { key: 'assays', header: t('quality.disputes.colAssays'), render: (r) => r.assays },
        {
            key: 'diff', header: t('quality.disputes.colDiff'),
            render: (r) => <span className={r.beyond ? 'text-amber-700' : undefined}>{r.diff}</span>,
        },
        { key: 'governing', header: t('quality.disputes.colGoverning'), render: (r) => r.governing },
        { key: 'opened', header: t('quality.disputes.colOpened'), render: (r) => r.opened },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
