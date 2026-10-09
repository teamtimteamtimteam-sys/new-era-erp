'use client'

// app/quality/samples/SamplesTable.tsx
// MES-6a-1 · 样品清单那张表。手机上留【编号】与【状态】—— 编号是身份,状态(谁拿着、在哪)是这一页的问题。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type SampleRow = {
    id: string
    code: string
    kindLabel: string
    batchCode: string
    batchHref: string
    stateLabel: string
    where: string
    takenLabel: string
    keepUntil: string
    flag: 'due' | 'early' | null
}

export default function SamplesTable({ rows, empty }: { rows: SampleRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: Column<SampleRow>[] = [
        {
            key: 'code', header: t('quality.samples.colCode'), priority: true,
            render: (r) => <Link href={`/quality/samples/${r.id}`} className="hover:underline app-link">{r.code}</Link>,
        },
        {
            key: 'state', header: t('quality.samples.colState'), priority: true,
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.stateLabel}</span>,
        },
        { key: 'kind', header: t('quality.samples.colKind'), render: (r) => r.kindLabel },
        {
            key: 'batch', header: t('quality.samples.colBatch'),
            render: (r) => <Link href={r.batchHref} className="hover:underline app-link">{r.batchCode}</Link>,
        },
        { key: 'where', header: t('quality.samples.colWhere'), render: (r) => r.where },
        { key: 'taken', header: t('quality.samples.colTaken'), render: (r) => r.takenLabel },
        {
            key: 'keep', header: t('quality.samples.colKeepUntil'),
            render: (r) => (
                <span>
                    {r.keepUntil}
                    {r.flag === 'due' && <span className="ml-2 text-xs text-amber-700">{t('quality.samples.flagDue')}</span>}
                    {r.flag === 'early' && <span className="ml-2 text-xs text-amber-700">{t('quality.samples.flagEarly')}</span>}
                </span>
            ),
        },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
