'use client'

// app/finance/bank/statements/StatementsTable.tsx
// CONV-4 · 对账单登记簿那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type StatementRow = {
    id: string
    code: string
    bankAccountCode: string
    period: string
    opening: number
    closing: number
    currency: string
    lineTotal: number
    matched: number
    unmatched: number
    ignored: number
    status: string
}

export default function StatementsTable({ rows, empty }: { rows: StatementRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【单号】与【未匹配】—— 单号是身份,未匹配是这张登记簿存在的
    //   理由(人来这一页最常问的是"哪几张还没对完")。其余进展开区。
    const columns: Column<StatementRow>[] = [
        {
            key: 'code', header: t('bank.colCode'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/finance/bank/statements/${r.id}`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        {
            key: 'account', header: t('bank.colAccount'), className: 'text-sm',
            render: (r) => (
                <>
                    <span className="font-mono">{r.bankAccountCode}</span> {t('finance.bank.' + r.bankAccountCode)}
                </>
            ),
        },
        { key: 'period', header: t('bank.colPeriod'), className: 'text-sm', render: (r) => r.period },
        {
            key: 'opening', header: t('bank.colOpening'), align: 'right', className: 'font-mono text-sm',
            render: (r) => formatAmount(r.opening, r.currency),
        },
        {
            key: 'closing', header: t('bank.colClosing'), align: 'right', className: 'font-mono text-sm',
            render: (r) => formatAmount(r.closing, r.currency),
        },
        { key: 'lines', header: t('bank.colLines'), align: 'right', className: 'font-mono text-sm', render: (r) => r.lineTotal },
        { key: 'matched', header: t('bank.colMatched'), align: 'right', className: 'font-mono text-sm', render: (r) => r.matched },
        {
            key: 'unmatched', header: t('bank.colUnmatched'), priority: true, align: 'right', className: 'font-mono text-sm',
            render: (r) => <span className={r.unmatched > 0 ? 'text-amber-700 font-medium' : ''}>{r.unmatched}</span>,
        },
        { key: 'ignored', header: t('bank.colIgnored'), align: 'right', className: 'font-mono text-sm', render: (r) => r.ignored },
        {
            key: 'status', header: t('finance.colStatus'),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + (r.status === 'reconciled' ? 'bg-green-100 text-green-800' : 'bg-amber-100 text-amber-800')}>
                    {t('bank.status.' + r.status)}
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
