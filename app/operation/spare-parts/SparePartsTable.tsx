'use client'

// app/operation/spare-parts/SparePartsTable.tsx
// SYSTEM-MAP-1(D4):备件清单那张表。手机上留【批次】【备件】【可用】—— 来这一页要问的是"手上有多少"。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xDate, xNum, xBool } from '@/lib/export/cells'

export type SparePartRow = {
    batchId: string
    batchCode: string
    part: string
    unit: string
    available: number
    remaining: number | null
    priced: boolean
    hold: string | null
    arrival: string
    arrivalRaw: string | null
}

const QTY = new Intl.NumberFormat('en-US', { maximumFractionDigits: 4 })

export default function SparePartsTable({ rows, empty }: { rows: SparePartRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    // TABLE-FEATURES-1 规矩 7:各行单位可以不同(件 / kg)—— 只有整屏同一个单位时数量列才可排
    const oneUnit = new Set(rows.map((r) => r.unit)).size <= 1
    const columns: ExportableColumn<SparePartRow>[] = [
        {
            key: 'batch', header: t('spareParts.colBatch'), priority: true, exportAs: (r) => xText(r.batchCode),
            render: (r) => <Link href={`/inbound/${r.batchId}/edit`} className="hover:underline app-link">{r.batchCode}</Link>,
        },
        { key: 'part', header: t('spareParts.colPart'), priority: true, render: (r) => r.part, exportAs: (r) => xText(r.part) },
        {
            key: 'available', header: t('spareParts.colAvailable'), priority: true, align: 'right', sortable: oneUnit,
            render: (r) => `${QTY.format(r.available)} ${r.unit}`, exportAs: (r) => xNum(r.available, 'qty', r.unit),
        },
        {
            key: 'remaining', header: t('spareParts.colRemaining'), align: 'right', sortable: oneUnit,
            render: (r) => (r.remaining === null ? '—' : `${QTY.format(r.remaining)} ${r.unit}`), exportAs: (r) => xNum(r.remaining, 'qty', r.unit),
        },
        {
            key: 'priced', header: t('spareParts.colPriced'),
            render: (r) => (r.priced ? t('spareParts.yes') : t('spareParts.no')), exportAs: (r) => xBool(r.priced, t('spareParts.yes'), t('spareParts.no')),
        },
        { key: 'hold', header: t('spareParts.colHold'), render: (r) => r.hold ?? '—', exportAs: (r) => xText(r.hold) },
        { key: 'arrival', header: t('spareParts.colArrival'), render: (r) => r.arrival, exportAs: (r) => xDate(r.arrivalRaw) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.batchId} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: 'spare-parts', title: t('spareParts.title') }}
        // 全部备件批一次读完,在浏览器里排
        sorting={{ mode: 'client', coverage: 'complete' }} />
}
