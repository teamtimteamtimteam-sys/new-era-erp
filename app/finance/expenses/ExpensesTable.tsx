'use client'

// app/finance/expenses/ExpensesTable.tsx
// CONV-4 · 开支登记簿那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ExpenseRow = {
    id: string
    code: string
    expenseDate: string
    accountCode: string
    accountName: string
    amountCcy: number
    currency: string
    amountBase: number
    baseCurrency: string
    paymentStatus: string
    counterparty: string
    status: string
}

export default function ExpensesTable({ rows, empty }: { rows: ExpenseRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【单号】与【金额】—— 单号是身份,金额是这张登记簿存在的理由。
    //   科目、状态、对方、过账态都是认出这一行之后才要问的,进展开区。
    const columns: Column<ExpenseRow>[] = [
        {
            key: 'code', header: t('expense.colCode'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/finance/expenses/${r.id}`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'date', header: t('expense.colDate'), render: (r) => r.expenseDate },
        {
            key: 'account', header: t('expense.colAccount'), className: 'text-sm',
            render: (r) => (
                <>
                    <span className="font-mono">{r.accountCode}</span> {r.accountName}
                </>
            ),
        },
        {
            key: 'amount', header: t('expense.colAmount'), priority: true, align: 'right', className: 'font-mono text-sm',
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
        {
            key: 'paymentStatus', header: t('expense.colStatus'),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + (r.paymentStatus === 'paid' ? 'bg-green-100 text-green-800' : 'bg-amber-100 text-amber-800')}>
                    {t('expense.status.' + r.paymentStatus)}
                </span>
            ),
        },
        { key: 'counterparty', header: t('expense.colCounterparty'), className: 'text-sm', render: (r) => r.counterparty },
        {
            key: 'postedStatus', header: t('finance.colStatus'),
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
