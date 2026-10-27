'use client'

// app/compliance/supplier-certificates/SupplierCertsTable.tsx
// SYSTEM-MAP-1(D4 · Q3):供应商证书总表那张表。手机上留【供应商】【证书】【有效期至】—— 来这一页要问的就是"谁的哪张什么时候到期"。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xDate } from '@/lib/export/cells'

export type SupplierCertRow = {
    id: string
    supplierId: string
    supplier: string
    type: string
    number: string | null
    issuer: string | null
    validFrom: string
    validFromRaw: string | null
    validUntil: string
    validUntilRaw: string | null
}

export default function SupplierCertsTable({ rows, empty }: { rows: SupplierCertRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: ExportableColumn<SupplierCertRow>[] = [
        {
            key: 'supplier', header: t('supplierCerts.colSupplier'), priority: true, exportAs: (r) => xText(r.supplier),
            render: (r) => <Link href={`/suppliers/${r.supplierId}/edit`} className="hover:underline app-link">{r.supplier}</Link>,
        },
        { key: 'type', header: t('supplierCerts.colType'), priority: true, render: (r) => r.type, exportAs: (r) => xText(r.type) },
        { key: 'number', header: t('supplierCerts.colNumber'), render: (r) => r.number ?? '—', exportAs: (r) => xText(r.number) },
        { key: 'issuer', header: t('supplierCerts.colIssuer'), render: (r) => r.issuer ?? '—', exportAs: (r) => xText(r.issuer) },
        { key: 'from', header: t('supplierCerts.colFrom'), render: (r) => r.validFrom, exportAs: (r) => xDate(r.validFromRaw) },
        { key: 'until', header: t('supplierCerts.colUntil'), priority: true, render: (r) => r.validUntil, exportAs: (r) => xDate(r.validUntilRaw) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: 'supplier-certificates', title: t('supplierCerts.title') }}
        // 全部证书一次读完(最早到期的在前),在浏览器里排
        sorting={{ mode: 'client', coverage: 'complete' }} />
}
