'use client'

// MES-8a:供应商对账单清单 —— 一份一行。被取代的那一份灰掉、说出被哪一份取代。手机上留【号】【供应商】【期末】。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type StatementRow = {
    id: string; code: string; supplier: string; period: string; closing: string; issued: string; superseded: string | null; latestVersion: string
}

export default function StatementsTable({ rows, empty }: { rows: StatementRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: Column<StatementRow>[] = [
        { key: 'code', header: t('supplierStatements.colCode'), priority: true,
          render: (r) => <Link href={`/finance/supplier-statements/${r.id}`} className="hover:underline app-link">{r.code}</Link> },
        { key: 'supplier', header: t('supplierStatements.colSupplier'), priority: true, render: (r) => r.supplier },
        { key: 'period', header: t('supplierStatements.colPeriod'), render: (r) => r.period },
        { key: 'closing', header: t('supplierStatements.doc.closing'), align: 'right', priority: true, render: (r) => r.closing },
        { key: 'issued', header: t('supplierStatements.colIssued'), render: (r) => r.issued },
        { key: 'pdf', header: t('supplierStatements.colPdf'), render: (r) => r.latestVersion },
        { key: 'superseded', header: t('supplierStatements.colSuperseded'), render: (r) => r.superseded ?? '—' },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        rowClassName={(r) => (r.superseded ? 'text-gray-400' : undefined)} />
}
