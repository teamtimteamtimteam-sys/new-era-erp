'use client'

// app/finance/payment-requests/[id]/RequestAllocationsTable.tsx
// PAY-REQ-1 · 一张付款申请要结清的单据。行在服务端压平(单据号 + 链接 + 金额文字)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xMoney, xText } from '@/lib/export/cells'

export type RequestAllocRow = {
    id: string
    docCode: string
    docHref: string | null
    amountText: string
    /** TABLE-EXPORT-3b:导出写这个数,不写上面那串字。 */
    amountDoc: number
}

// ★ TABLE-EXPORT-3b:一对导出。金额那一列各行按各自单据的币种,屏幕上格子与表头都不写币种(formatMoneyBare)—— 导出照屏幕,一个数。
export default function RequestAllocationsTable({ rows, empty, requestCode }: { rows: RequestAllocRow[]; empty: React.ReactNode; requestCode: string }) {
    const t = useTranslations()
    const columns: ExportableColumn<RequestAllocRow>[] = [
        {
            key: 'doc', header: t('finance.colDocument'), priority: true,
            render: (r) => r.docHref
                ? <Link href={r.docHref} className="hover:underline app-link">{r.docCode}</Link>
                : r.docCode,
            exportAs: (r) => xText(r.docCode),
        },
        {
            key: 'amount', header: t('finance.paymentRequests.colAmountDoc'), priority: true, align: 'right',
            render: (r) => r.amountText,
            exportAs: (r) => xMoney(r.amountDoc),
        },
    ]
    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            exportSpec={{
                name: 'finance-payment-request-allocations',
                title: t('finance.paymentRequests.allocTitle'),
                aboutExtra: [[t('finance.colCode'), requestCode]],
            }}
        />
    )
}
