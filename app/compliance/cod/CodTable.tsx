'use client'

// app/compliance/cod/CodTable.tsx
// SYSTEM-MAP-1(D4):销毁证书清单那张表。手机上留【编号】与【状态】—— 编号是身份,状态是来这一页要问的那件事。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xDate, xTime } from '@/lib/export/cells'

export type CodRow = {
    id: string
    /** 待签发的还没有编号 */
    code: string | null
    statusLabel: string
    batchId: string
    batchCode: string | null
    completedOn: string
    completedOnRaw: string
    issuedAt: string
    issuedAtRaw: string | null
    /** 已签发 / 已作废的存档字节;待签发的没有 */
    pdfHref: string | null
}

export default function CodTable({ rows, empty }: { rows: CodRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: ExportableColumn<CodRow>[] = [
        { key: 'code', header: t('cod.number'), priority: true, render: (r) => r.code ?? '—', exportAs: (r) => xText(r.code) },
        { key: 'status', header: t('codList.colStatus'), priority: true, render: (r) => r.statusLabel, exportAs: (r) => xText(r.statusLabel) },
        {
            key: 'batch', header: t('codList.colBatch'), exportAs: (r) => xText(r.batchCode),
            render: (r) => <Link href={`/inbound/${r.batchId}/edit`} className="hover:underline app-link">{r.batchCode ?? '—'}</Link>,
        },
        { key: 'completed', header: t('cod.completedOn'), render: (r) => r.completedOn, exportAs: (r) => xDate(r.completedOnRaw) },
        { key: 'issued', header: t('cod.issuedOn'), render: (r) => r.issuedAt, exportAs: (r) => xTime(r.issuedAtRaw) },
        {
            key: 'pdf', header: t('codList.colPdf'), sortable: false, exportAs: false,
            render: (r) => r.pdfHref
                ? <a href={r.pdfHref} target="_blank" rel="noopener noreferrer" className="hover:underline app-link">{t('cod.openIssued')}</a>
                : '—',
        },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: 'certificates-of-destruction', title: t('codList.title') }}
        // 全部证书一次读完,在浏览器里排
        sorting={{ mode: 'client', coverage: 'complete' }} />
}
