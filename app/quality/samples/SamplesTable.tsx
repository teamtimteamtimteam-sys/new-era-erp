'use client'

// app/quality/samples/SamplesTable.tsx
// MES-6a-1 · 样品清单那张表。手机上留【编号】与【状态】—— 编号是身份,状态(谁拿着、在哪)是这一页的问题。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xDate, xTime } from '@/lib/export/cells'

export type SampleRow = {
    id: string
    code: string
    kindLabel: string
    batchCode: string
    batchHref: string
    stateLabel: string
    where: string
    /** TABLE-EXPORT-1:已处置的样品,「在哪」那一格画的是处置时刻 —— 这是它的原始值(ISO);别的状态为 null。 */
    disposedAt: string | null
    takenLabel: string
    /** TABLE-EXPORT-1:导出用的原始日历日(YYYY-MM-DD)。 */
    takenOn: string
    keepUntil: string
    /** TABLE-EXPORT-1:原始日历日;null = 没有人说过留多久(屏幕与导出都写「尚未设定」)。 */
    retainUntil: string | null
    flag: 'due' | 'early' | null
}

export default function SamplesTable({ rows, empty }: { rows: SampleRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    // TABLE-EXPORT-1:日期是真日期;「在哪」一格对已处置的样品是处置时刻(真日期),其余是那句话;
    //   留存期那一格的「到期 / 提前处置」角标是同一格里的第二件事,导出只写日期(或「尚未设定」)。
    const columns: ExportableColumn<SampleRow>[] = [
        {
            key: 'code', header: t('quality.samples.colCode'), priority: true,
            exportAs: (r) => xText(r.code),
            render: (r) => <Link href={`/quality/samples/${r.id}`} className="hover:underline app-link">{r.code}</Link>,
        },
        {
            key: 'state', header: t('quality.samples.colState'), priority: true,
            exportAs: (r) => xText(r.stateLabel),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.stateLabel}</span>,
        },
        { key: 'kind', header: t('quality.samples.colKind'), render: (r) => r.kindLabel, exportAs: (r) => xText(r.kindLabel) },
        {
            key: 'batch', header: t('quality.samples.colBatch'),
            exportAs: (r) => xText(r.batchCode),
            render: (r) => <Link href={r.batchHref} className="hover:underline app-link">{r.batchCode}</Link>,
        },
        {
            key: 'where', header: t('quality.samples.colWhere'), render: (r) => r.where,
            exportAs: (r) => (r.disposedAt ? xTime(r.disposedAt) : xText(r.where)),
        },
        { key: 'taken', header: t('quality.samples.colTaken'), render: (r) => r.takenLabel, exportAs: (r) => xDate(r.takenOn) },
        {
            key: 'keep', header: t('quality.samples.colKeepUntil'),
            exportAs: (r) => (r.retainUntil ? xDate(r.retainUntil) : xText(t('quality.notYetSet'))),
            render: (r) => (
                <span>
                    {r.keepUntil}
                    {r.flag === 'due' && <span className="ml-2 text-xs text-amber-700">{t('quality.samples.flagDue')}</span>}
                    {r.flag === 'early' && <span className="ml-2 text-xs text-amber-700">{t('quality.samples.flagEarly')}</span>}
                </span>
            ),
        },
    ]
    return (
        <DataTable
            rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
            exportSpec={{ name: 'quality-samples', title: t('quality.samples.title') }}
        />
    )
}
