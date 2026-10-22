'use client'

// app/quality/disputes/DisputesTable.tsx
// MES-6a-1 · 化验争议清单那张表。手机上留【批次】与【状态】—— 批次是身份,状态是这一页的问题(哪几件还挡着定价与结算)。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xTime } from '@/lib/export/cells'

export type DisputeRow = {
    id: string
    batchCode: string
    statusLabel: string
    open: boolean
    assays: string
    diff: string
    /** TABLE-EXPORT-1:导出用的原始最大差值(屏幕上那个百分数);null = 算不出,屏幕上是「—」。 */
    maxDiffPct: number | null
    beyond: boolean
    governing: string
    opened: string
    /** TABLE-EXPORT-1:导出用的原始时刻(ISO)。 */
    createdAt: string
}

export default function DisputesTable({ rows, empty }: { rows: DisputeRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    // TABLE-EXPORT-1:差值一格导出【那个百分数】(一个数);同一格里「上限 …」那半句是上下文,不进这一格。
    const columns: ExportableColumn<DisputeRow>[] = [
        {
            key: 'batch', header: t('quality.disputes.colBatch'), priority: true,
            exportAs: (r) => xText(r.batchCode),
            render: (r) => <Link href={`/quality/disputes/${r.id}`} className="hover:underline app-link">{r.batchCode}</Link>,
        },
        {
            key: 'status', header: t('quality.disputes.colStatus'), priority: true,
            exportAs: (r) => xText(r.statusLabel),
            render: (r) => <span className={`px-2 py-1 rounded text-xs ${r.open ? 'bg-amber-100' : 'bg-gray-200'}`}>{r.statusLabel}</span>,
        },
        { key: 'assays', header: t('quality.disputes.colAssays'), render: (r) => r.assays, exportAs: (r) => xText(r.assays) },
        {
            key: 'diff', header: t('quality.disputes.colDiff'),
            exportAs: (r) => xNum(r.maxDiffPct, 'pct'),
            render: (r) => <span className={r.beyond ? 'text-amber-700' : undefined}>{r.diff}</span>,
        },
        { key: 'governing', header: t('quality.disputes.colGoverning'), render: (r) => r.governing, exportAs: (r) => xText(r.governing) },
        { key: 'opened', header: t('quality.disputes.colOpened'), render: (r) => r.opened, exportAs: (r) => xTime(r.createdAt) },
    ]
    return (
        <DataTable
            rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
            exportSpec={{ name: 'quality-disputes', title: t('quality.disputes.title') }}
        />
    )
}
