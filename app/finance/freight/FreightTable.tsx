'use client'

// app/finance/freight/FreightTable.tsx
// CONV-4 · 运费单据登记簿那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type FreightRow = {
    id: string
    code: string
    docDate: string
    forwarder: string
    amountBase: number
    baseCurrency: string
    allocationBasis: string
    paymentStatus: string
    reversed: boolean
}

export default function FreightTable({ rows, empty }: { rows: FreightRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【单号】与【金额】—— 理由同其余登记簿:身份 + 这张表存在的理由。
    const columns: Column<FreightRow>[] = [
        {
            key: 'code', header: t('finance.freight.colCode'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/finance/freight/${r.id}`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'date', header: t('finance.freight.colDate'), render: (r) => r.docDate },
        { key: 'forwarder', header: t('finance.freight.colForwarder'), render: (r) => r.forwarder },
        {
            key: 'amount', header: t('finance.freight.colAmount'), priority: true, align: 'right', className: 'font-mono text-sm',
            render: (r) => formatAmount(r.amountBase, r.baseCurrency),
        },
        { key: 'basis', header: t('finance.freight.colBasis'), className: 'text-sm', render: (r) => t('finance.freight.basis.' + r.allocationBasis) },
        { key: 'payment', header: t('finance.freight.colPayment'), className: 'text-sm', render: (r) => t('finance.freight.payment.' + r.paymentStatus) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            // ★ CONV-4:冲销单据整行发灰(转换前 <tr className="text-gray-400 line-through">)
            //   —— 这是给 DataTable 建 rowClassName 的那个第三次出现。
            rowClassName={(r) => (r.reversed ? 'text-gray-400 line-through' : undefined)}
        />
    )
}
