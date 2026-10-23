'use client'

// app/finance/cashflow/CashflowEntriesTable.tsx
// CONV-4 · 现金流量表的【明细】那张表 —— 逐条分录,真正是"记录列表"
// (与它上面那张固定六行的汇总表不同,汇总表按兵不动,见 page.tsx 顶注)。

import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xDate, xMoney, xText } from '@/lib/export/cells'

export type CashflowEntryRow = {
    code: string
    entryDate: string
    /** TABLE-EXPORT-3a:导出写真日期,不写屏幕上格式化过的那串字。 */
    entryYmd: string
    memo: string | null
    section: string
    net: number
}

export default function CashflowEntriesTable({ rows, empty, baseCurrency, period }: { rows: CashflowEntryRow[]; empty: React.ReactNode; baseCurrency: string; period: string }) {
    const t = useTranslations()
    const sign = (n: number) => (n < 0 ? 'text-red-700' : n > 0 ? 'text-green-700' : 'text-gray-500')

    // ★ 手机上留【单号】与【净额】—— 单号是身份,净额是这张明细表存在的理由。
    // TABLE-EXPORT-3a(Tim 2026-10-23,Q7 的报表体之一):这张明细表有自己的一对导出。
    //   单号那一格屏幕上还叠着摘要 —— 一格一个值,导出写单号(主值),与 docs/table-export.md「一格放不下」同一条。
    const columns: ExportableColumn<CashflowEntryRow>[] = [
        { key: 'date', header: t('finance.colDate'), render: (r) => r.entryDate, exportAs: (r) => xDate(r.entryYmd) },
        {
            key: 'code', header: t('finance.colCode'), priority: true, className: 'text-sm',
            render: (r) => (
                <>
                    <span>{r.code}</span>
                    {r.memo && <span className="block text-xs text-gray-500">{r.memo}</span>}
                </>
            ),
            exportAs: (r) => xText(r.code),
        },
        { key: 'section', header: t('finance.cashflowSection'), render: (r) => t('finance.cashflowSectionName.' + r.section), exportAs: (r) => xText(t('finance.cashflowSectionName.' + r.section)) },
        {
            key: 'net', header: t('finance.colAmount', { ccy: baseCurrency }), priority: true, align: 'right', className: 'text-sm',
            render: (r) => <span className={sign(r.net)}>{formatMoneyBare(r.net, '标题下 cashflowDesc「……以 {ccy} 计」')}</span>,
            exportAs: (r) => xMoney(r.net),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.code}
            phone={{ mode: 'columns' }}
            empty={empty}
            exportSpec={{ name: 'finance-cash-flow-detail', title: t('finance.cashflowDetail'), aboutExtra: [[t('table.export.aboutPeriod'), period]] }}
        />
    )
}
