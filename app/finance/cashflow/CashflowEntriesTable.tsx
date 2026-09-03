'use client'

// app/finance/cashflow/CashflowEntriesTable.tsx
// CONV-4 · 现金流量表的【明细】那张表 —— 逐条分录,真正是"记录列表"
// (与它上面那张固定六行的汇总表不同,汇总表按兵不动,见 page.tsx 顶注)。

import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type CashflowEntryRow = {
    code: string
    entryDate: string
    memo: string | null
    section: string
    net: number
}

export default function CashflowEntriesTable({ rows, empty, baseCurrency }: { rows: CashflowEntryRow[]; empty: React.ReactNode; baseCurrency: string }) {
    const t = useTranslations()
    const sign = (n: number) => (n < 0 ? 'text-red-700' : n > 0 ? 'text-green-700' : 'text-gray-500')

    // ★ 手机上留【单号】与【净额】—— 单号是身份,净额是这张明细表存在的理由。
    const columns: Column<CashflowEntryRow>[] = [
        { key: 'date', header: t('finance.colDate'), render: (r) => r.entryDate },
        {
            key: 'code', header: t('finance.colCode'), priority: true, className: 'text-sm',
            render: (r) => (
                <>
                    <span className="font-mono">{r.code}</span>
                    {r.memo && <span className="block text-xs text-gray-500">{r.memo}</span>}
                </>
            ),
        },
        { key: 'section', header: t('finance.cashflowSection'), render: (r) => t('finance.cashflowSectionName.' + r.section) },
        {
            key: 'net', header: t('finance.colAmount', { ccy: baseCurrency }), priority: true, align: 'right', className: 'font-mono text-sm',
            render: (r) => <span className={sign(r.net)}>{formatMoneyBare(r.net, '标题下 cashflowDesc「……以 {ccy} 计」')}</span>,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.code}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
