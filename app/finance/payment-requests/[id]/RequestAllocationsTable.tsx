'use client'

// app/finance/payment-requests/[id]/RequestAllocationsTable.tsx
// PAY-REQ-1 · 一张付款申请要结清的单据。行在服务端压平(单据号 + 链接 + 金额文字)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type RequestAllocRow = {
    id: string
    docCode: string
    docHref: string | null
    amountText: string
}

export default function RequestAllocationsTable({ rows, empty }: { rows: RequestAllocRow[]; empty: React.ReactNode }) {
    const t = useTranslations()
    const columns: Column<RequestAllocRow>[] = [
        {
            key: 'doc', header: t('finance.colDocument'), priority: true,
            render: (r) => r.docHref
                ? <Link href={r.docHref} className="hover:underline app-link">{r.docCode}</Link>
                : r.docCode,
        },
        {
            key: 'amount', header: t('finance.paymentRequests.colAmountDoc'), priority: true, align: 'right',
            render: (r) => r.amountText,
        },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
