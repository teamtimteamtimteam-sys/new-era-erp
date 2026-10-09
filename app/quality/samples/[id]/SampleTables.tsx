'use client'

// app/quality/samples/[id]/SampleTables.tsx
// MES-6a-1 · 样品页上的两张表:保管记录(一行一件事,按先后)与化验了这份样品的结果。字由服务端排好,这里只画。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type EventRow = { id: string; when: string; what: string; detail: string; reason: string; notes: string }
export type AssayRow = { id: string; code: string; href: string; party: string; date: string; lab: string }

export function EventsTable({ rows }: { rows: EventRow[] }) {
    const t = useTranslations()
    const columns: Column<EventRow>[] = [
        { key: 'when', header: t('quality.sample.colWhen'), priority: true, render: (r) => r.when },
        { key: 'what', header: t('quality.sample.colWhat'), priority: true, render: (r) => r.what },
        { key: 'detail', header: t('quality.sample.colDetail'), render: (r) => r.detail },
        { key: 'reason', header: t('quality.sample.colReason'), render: (r) => r.reason },
        { key: 'notes', header: t('quality.form.notes'), className: 'text-gray-600', render: (r) => r.notes },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty="—" />
}

export function AssaysTable({ rows, empty }: { rows: AssayRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: Column<AssayRow>[] = [
        { key: 'code', header: t('quality.sample.colAssay'), priority: true,
          render: (r) => <Link href={r.href} className="hover:underline app-link">{r.code}</Link> },
        { key: 'party', header: t('quality.colParty'), priority: true, render: (r) => r.party },
        { key: 'date', header: t('quality.colDate'), render: (r) => r.date },
        { key: 'lab', header: t('quality.sample.lab'), render: (r) => r.lab },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
