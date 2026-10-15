'use client'

// app/quality/coa/CoaTable.tsx
// MES-6b-2 · 分析证书清单那张表。手机上留【号】与【状态】—— 号是身份,状态(已签发 / 已作废、有没有在等的作废申请)是这一页的问题。
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import WarehouseRequestButton from '@/app/components/inventory/WarehouseRequestButton'

export type CoaListRow = {
    id: string
    code: string
    status: 'issued' | 'void'
    statusLabel: string
    batchId: string
    batchCode: string
    issuedTo: string
    issued: string
    issuedBy: string
    replacedBy: string | null
    hasBytes: boolean
    openRequestLabel: string | null
}

export default function CoaTable({ rows, empty, canIssue, hideBatch = false }: {
    rows: CoaListRow[]
    empty: React.ReactNode
    canIssue: boolean
    hideBatch?: boolean
}) {
    const t = useTranslations()
    const columns: Column<CoaListRow>[] = [
        {
            key: 'code', header: t('coa.col.code'), priority: true,
            render: (r) => <Link href={`/quality/coa/${r.id}`} className="hover:underline app-link">{r.code}</Link>,
        },
        {
            key: 'status', header: t('coa.col.status'), priority: true,
            render: (r) => (
                <span className="inline-flex flex-wrap gap-1">
                    <span className={`px-2 py-1 rounded text-xs ${r.status === 'issued' ? 'bg-green-100' : 'bg-gray-200'}`}>{r.statusLabel}</span>
                    {r.replacedBy && <span className="px-2 py-1 rounded text-xs bg-gray-100">{t('coa.replacedBy', { code: r.replacedBy })}</span>}
                </span>
            ),
        },
        // 批次页上那一批就是自己 —— 不再画"批次"一列
        ...(hideBatch ? [] : [{
            key: 'batch', header: t('coa.col.batch'),
            render: (r: CoaListRow) => <Link href={`/output/${r.batchId}/edit`} className="hover:underline app-link">{r.batchCode}</Link>,
        }]),
        { key: 'issuedTo', header: t('coa.col.issuedTo'), render: (r) => r.issuedTo },
        { key: 'issued', header: t('coa.col.issued'), render: (r) => <span>{r.issued}<span className="block text-xs text-[color:var(--brand-muted-text)]">{r.issuedBy}</span></span> },
        {
            // 下载与作废申请是要按的控件 —— 手机上留在表里(TABLE-STYLE-1 R1)
            key: 'actions', header: t('coa.col.actions'), priority: true,
            render: (r) => (
                <span className="flex flex-wrap gap-x-3 gap-y-1 items-start">
                    {r.hasBytes ? (
                        <a className="app-link underline" href={`/output/${r.batchId}/coa/pdf?coa=${encodeURIComponent(r.code)}`} target="_blank" rel="noopener noreferrer">
                            {t('coa.download')}
                        </a>
                    ) : <span className="text-xs text-[color:var(--brand-muted-text)]">{t('coa.noBytes')}</span>}
                    {r.status === 'issued' && (
                        <WarehouseRequestButton kind="coa_void" subjectId={r.id} subjectCode={r.code} permissionCode="action.issue_coa"
                            allowed={canIssue} openRequestLabel={r.openRequestLabel} extraPath="/quality/coa" />
                    )}
                </span>
            ),
        },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
