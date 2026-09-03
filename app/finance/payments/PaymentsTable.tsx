'use client'

// app/finance/payments/PaymentsTable.tsx
// CONV-4 · 收付款登记簿那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type PaymentRow = {
    id: string
    code: string
    paymentDate: string
    direction: string
    counterparty: string
    amountCcy: number
    currency: string
    amountBase: number
    baseCurrency: string
    bankAccountCode: string
    status: string
}

export default function PaymentsTable({ rows, empty }: { rows: PaymentRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【单号】与【金额】—— 单号是身份,金额是这张登记簿存在的理由。
    const columns: Column<PaymentRow>[] = [
        {
            key: 'code', header: t('finance.colCode'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/finance/payments/${r.id}`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'date', header: t('finance.colDate'), render: (r) => r.paymentDate },
        {
            key: 'direction', header: t('finance.side'),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + (r.direction === 'in' ? 'bg-green-100 text-green-800' : 'bg-amber-100 text-amber-800')}>
                    {t('finance.direction.' + r.direction)}
                </span>
            ),
        },
        { key: 'counterparty', header: t('finance.colCounterparty'), className: 'text-sm', render: (r) => r.counterparty },
        {
            key: 'amount', header: t('finance.amount'), priority: true, align: 'right', className: 'font-mono text-sm',
            render: (r) => (
                <>
                    {r.currency} {formatMoneyBare(r.amountCcy, '同格内紧邻的 r.currency 前缀')}
                    {r.currency !== r.baseCurrency && (
                        <span className="text-gray-500 ml-2">
                            = {formatMoneyBare(r.amountBase, '同格内紧随其后的 baseCurrency 后缀')} {r.baseCurrency}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'bank', header: t('finance.bankAccount'), className: 'text-sm', render: (r) => t('finance.bank.' + r.bankAccountCode) },
        {
            key: 'status', header: t('finance.colStatus'),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + (r.status === 'posted' ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-700')}>
                    {t('finance.status.' + r.status)}
                </span>
            ),
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
