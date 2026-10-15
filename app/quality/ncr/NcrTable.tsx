'use client'

// app/quality/ncr/NcrTable.tsx
// MES-6b-1 · 不合格报告清单那张表。手机上留【编号】与【状态】—— 编号是身份,状态(开着 / 怎么处置的,扣不扣着货)是这一页的问题。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type NcrRow = {
    id: string
    code: string
    statusLabel: string
    open: boolean
    holding: boolean
    sourceLabel: string
    batchCode: string
    batchHref: string
    opened: string
    description: string
}

export default function NcrTable({ rows, empty }: { rows: NcrRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: Column<NcrRow>[] = [
        {
            key: 'code', header: t('quality.ncr.colCode'), priority: true,
            render: (r) => <Link href={`/quality/ncr/${r.id}`} className="hover:underline app-link">{r.code}</Link>,
        },
        {
            key: 'status', header: t('quality.ncr.colStatus'), priority: true,
            render: (r) => (
                <span className="inline-flex flex-wrap gap-1">
                    <span className={`px-2 py-1 rounded text-xs ${r.open ? 'bg-amber-100' : 'bg-gray-200'}`}>{r.statusLabel}</span>
                    {r.holding && <span className="px-2 py-1 rounded text-xs bg-red-100" data-flag="holding">{t('quality.ncr.holdingFlag')}</span>}
                </span>
            ),
        },
        { key: 'source', header: t('quality.ncr.colSource'), render: (r) => r.sourceLabel },
        {
            key: 'batch', header: t('quality.ncr.colBatch'),
            render: (r) => <Link href={r.batchHref} className="hover:underline app-link">{r.batchCode}</Link>,
        },
        { key: 'opened', header: t('quality.ncr.colOpened'), render: (r) => r.opened },
        { key: 'description', header: t('quality.ncr.colDescription'), render: (r) => <span className="line-clamp-2">{r.description}</span> },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
