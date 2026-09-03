'use client'

// app/finance/credit-notes/CreditNotesTable.tsx
// CONV-4 · 贷项凭证登记簿那张表。见 page.tsx 顶注:模板通则,服务端压平、客户端只画。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type CreditNoteRow = {
    id: string
    code: string
    noteDate: string
    customerCell: React.ReactNode
    invoiceId: string | null
    invoiceCode: string | null
    total: number
    currency: string
    version: number | null
    reason: string
}

export default function CreditNotesTable({ rows }: { rows: CreditNoteRow[] }) {
    const t = useTranslations()

    // ★ 手机上留【单号】与【合计】—— 单号是身份,合计是这张登记簿存在的理由
    //   (人来这一页最常问的是"这张凭证冲了多少")。客户、对冲发票、签发状态、
    //   理由都是认出这一行之后才要问的,进展开区。
    const columns: Column<CreditNoteRow>[] = [
        {
            key: 'code', header: t('cn.colCode'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/finance/credit-notes/${r.id}`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'noteDate', header: t('cn.noteDate'), render: (r) => r.noteDate },
        { key: 'customer', header: t('cn.colCustomer'), render: (r) => r.customerCell },
        {
            key: 'invoice', header: t('cn.againstInvoice'), className: 'font-mono text-sm',
            render: (r) =>
                r.invoiceId ? (
                    <Link href={`/finance/invoices/${r.invoiceId}`} className="text-blue-600 hover:underline">
                        {r.invoiceCode}
                    </Link>
                ) : (
                    <span className="text-gray-400">—</span>
                ),
        },
        {
            key: 'total', header: t('cn.totalLabel'), priority: true, align: 'right', className: 'font-mono text-sm',
            render: (r) => formatAmount(r.total, r.currency),
        },
        {
            key: 'issued', header: t('cn.colIssued'),
            render: (r) =>
                r.version === null ? (
                    <span className="text-gray-500">{t('cn.noIssues')}</span>
                ) : (
                    <span className="px-2 py-1 rounded text-xs bg-green-100 text-green-800">
                        {t('cn.issuedVersion', { n: r.version })}
                    </span>
                ),
        },
        { key: 'reason', header: t('cn.reason'), render: (r) => <span className="text-gray-700">{r.reason}</span> },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('cn.empty')}
        />
    )
}
