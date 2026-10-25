'use client'

// app/safety/incidents/IncidentsTable.tsx
// MES-7b-1 · 事故清单那张表。手机上留【编号】与【NEA】—— 编号是身份,NEA 那一格是这一页唯一挂着法定时限的事。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xTime } from '@/lib/export/cells'

export type IncidentRow = {
    id: string
    code: string
    kindLabel: string
    occurred: string
    /** TABLE-EXPORT-2b-1:发生时刻的原始 ISO */
    occurredAt: string
    where: string
    nea: string
    neaDue: boolean
    closed: boolean
    statusLabel: string
    whatHappened: string
}

export default function IncidentsTable({ rows, empty }: { rows: IncidentRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: ExportableColumn<IncidentRow>[] = [
        {
            key: 'code', header: t('safety.incidents.colCode'), priority: true, exportAs: (r) => xText(r.code),
            render: (r) => <Link href={`/safety/incidents/${r.id}`} className="hover:underline app-link">{r.code}</Link>,
        },
        { key: 'kind', header: t('safety.incidents.colKind'), render: (r) => r.kindLabel, exportAs: (r) => xText(r.kindLabel) },
        { key: 'occurred', header: t('safety.incidents.colOccurred'), render: (r) => r.occurred, exportAs: (r) => xTime(r.occurredAt) },
        { key: 'where', header: t('safety.incidents.colWhere'), render: (r) => r.where, exportAs: (r) => xText(r.where === '—' ? null : r.where) },
        {
            key: 'nea', header: t('safety.incidents.colNea'), priority: true, exportAs: (r) => xText(r.nea),
            render: (r) => <span className={`px-2 py-1 rounded text-xs ${r.neaDue ? 'bg-amber-100' : 'bg-gray-100'}`} data-flag={r.neaDue ? 'nea-due' : undefined}>{r.nea}</span>,
        },
        { key: 'status', header: t('safety.incidents.colStatus'), render: (r) => r.statusLabel, exportAs: (r) => xText(r.statusLabel) },
        { key: 'what', header: t('safety.incidents.colWhat'), exportAs: (r) => xText(r.whatHappened), render: (r) => <span className="line-clamp-2">{r.whatHappened}</span> },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: 'safety-incidents', title: t('safety.incidents.title') }}
        // TABLE-FEATURES-1 Q9:全部事故一次读完,在浏览器里排
        sorting={{ mode: 'client', coverage: 'complete' }} />
}
