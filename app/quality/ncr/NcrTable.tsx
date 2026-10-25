'use client'

// app/quality/ncr/NcrTable.tsx
// MES-6b-1 · 不合格报告清单那张表。手机上留【编号】与【状态】—— 编号是身份,状态(开着 / 怎么处置的,扣不扣着货)是这一页的问题。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xTime } from '@/lib/export/cells'

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
    /** TABLE-EXPORT-1:导出用的原始时刻(ISO)。 */
    openedAt: string
    description: string
}

export default function NcrTable({ rows, empty }: { rows: NcrRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    // TABLE-EXPORT-1:状态一格写处置(或「开着」)再加上「扣着货」那一枚(与屏幕同两段);描述导出全文(屏幕只是收成两行)。
    const columns: ExportableColumn<NcrRow>[] = [
        {
            key: 'code', header: t('quality.ncr.colCode'), priority: true,
            exportAs: (r) => xText(r.code),
            render: (r) => <Link href={`/quality/ncr/${r.id}`} className="hover:underline app-link">{r.code}</Link>,
        },
        {
            key: 'status', header: t('quality.ncr.colStatus'), priority: true,
            exportAs: (r) => xText(r.statusLabel + (r.holding ? ` · ${t('quality.ncr.holdingFlag')}` : '')),
            render: (r) => (
                <span className="inline-flex flex-wrap gap-1">
                    <span className={`px-2 py-1 rounded text-xs ${r.open ? 'bg-amber-100' : 'bg-gray-200'}`}>{r.statusLabel}</span>
                    {r.holding && <span className="px-2 py-1 rounded text-xs bg-red-100" data-flag="holding">{t('quality.ncr.holdingFlag')}</span>}
                </span>
            ),
        },
        { key: 'source', header: t('quality.ncr.colSource'), render: (r) => r.sourceLabel, exportAs: (r) => xText(r.sourceLabel) },
        {
            key: 'batch', header: t('quality.ncr.colBatch'),
            exportAs: (r) => xText(r.batchCode),
            render: (r) => <Link href={r.batchHref} className="hover:underline app-link">{r.batchCode}</Link>,
        },
        { key: 'opened', header: t('quality.ncr.colOpened'), render: (r) => r.opened, exportAs: (r) => xTime(r.openedAt) },
        {
            key: 'description', header: t('quality.ncr.colDescription'), exportAs: (r) => xText(r.description),
            render: (r) => <span className="line-clamp-2">{r.description}</span>,
        },
    ]
    return (
        <DataTable
            rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
            exportSpec={{ name: 'quality-ncr', title: t('quality.ncr.title') }}
            // TABLE-FEATURES-1 Q9:全部 NCR 一次读完,在浏览器里排。没点表头时照旧是页面给的次序(开着的在前,Q7 默认不变)
            sorting={{ mode: 'client', coverage: 'complete' }}
        />
    )
}
