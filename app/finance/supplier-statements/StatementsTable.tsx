'use client'

// MES-8a:供应商对账单清单 —— 一份一行。被取代的那一份灰掉、说出被哪一份取代。手机上留【号】【供应商】【期末】。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney, xTime } from '@/lib/export/cells'

export type StatementRow = {
    id: string; code: string; supplier: string; period: string; closing: string; issued: string; superseded: string | null; latestVersion: string
    // TABLE-EXPORT-2a:导出读原始值(期间是一段日期 → 由原始日期拼出的文字;期末余额是带币种的数;签发是一个时刻)
    periodRaw: string; closingAmt: number; baseCurrency: string; issuedRaw: string
}

export default function StatementsTable({ rows, empty }: { rows: StatementRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: ExportableColumn<StatementRow>[] = [
        { key: 'code', header: t('supplierStatements.colCode'), priority: true, exportAs: (r) => xText(r.code),
          render: (r) => <Link href={`/finance/supplier-statements/${r.id}`} className="hover:underline app-link">{r.code}</Link> },
        { key: 'supplier', header: t('supplierStatements.colSupplier'), priority: true, render: (r) => r.supplier, exportAs: (r) => xText(r.supplier) },
        { key: 'period', header: t('supplierStatements.colPeriod'), render: (r) => r.period, exportAs: (r) => xText(r.periodRaw) },
        { key: 'closing', header: t('supplierStatements.doc.closing'), align: 'right', priority: true, render: (r) => r.closing, exportAs: (r) => xMoney(r.closingAmt, r.baseCurrency) },
        { key: 'issued', header: t('supplierStatements.colIssued'), render: (r) => r.issued, exportAs: (r) => xTime(r.issuedRaw) },
        { key: 'pdf', header: t('supplierStatements.colPdf'), render: (r) => r.latestVersion, exportAs: (r) => xText(r.latestVersion) },
        { key: 'superseded', header: t('supplierStatements.colSuperseded'), render: (r) => r.superseded ?? '—', exportAs: (r) => xText(r.superseded) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        rowClassName={(r) => (r.superseded ? 'text-gray-400' : undefined)}
        exportSpec={{ name: 'supplier-statements', title: t('supplierStatements.listTitle'), serverRows: '/finance/supplier-statements/export' }} />
}
