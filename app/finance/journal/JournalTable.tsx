'use client'

// app/finance/journal/JournalTable.tsx
// CONV-4 · 分录登记簿(总账)那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type JournalRow = {
    id: string
    code: string
    entryDate: string
    memo: string | null
    sourceType: string | null
    sourceHref: string | null
    amount: number
    status: string
}

export default function JournalTable({ rows, empty, baseCurrency }: { rows: JournalRow[]; empty: React.ReactNode; baseCurrency: string }) {
    const t = useTranslations()
    const sourceLabel = (v: string | null) => (v ? t('finance.source.' + v) : '—')

    // ★ 手机上留【单号】与【金额】—— 单号是身份,金额是这张总账存在的理由。
    const columns: Column<JournalRow>[] = [
        {
            key: 'code', header: t('finance.colCode'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/finance/journal/${r.id}`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'date', header: t('finance.colDate'), render: (r) => r.entryDate },
        { key: 'memo', header: t('finance.colMemo'), className: 'text-sm', render: (r) => r.memo ?? '—' },
        {
            key: 'source', header: t('finance.colSource'), className: 'text-sm',
            render: (r) =>
                r.sourceHref ? (
                    <Link href={r.sourceHref} className="text-blue-600 hover:underline">
                        {sourceLabel(r.sourceType)}
                    </Link>
                ) : (
                    sourceLabel(r.sourceType)
                ),
        },
        {
            key: 'amount', header: t('finance.colAmount', { ccy: baseCurrency }), priority: true, align: 'right', className: 'font-mono text-sm',
            render: (r) => formatMoneyBare(r.amount, '列头 金额 —— 已带本位币'),
        },
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
