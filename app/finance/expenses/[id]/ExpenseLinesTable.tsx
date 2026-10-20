'use client'

// app/finance/expenses/[id]/ExpenseLinesTable.tsx
// EXPENSE-MULTILINE-1(Tim 2026-10-20):费用单的行 —— 每一行自己的科目、税码、不含税净额、税与备注。
// 金额以单据币种印(表头已经说了币种与汇率);合计行就是表头那几个数(库强制它们 = 各行之和,所以这里不另加一遍)。

import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ExpenseLineRow = {
    lineNo: number
    accountCode: string
    accountName: string
    taxCode: string | null
    netCcy: number
    taxCcy: number
    notes: string | null
}

export default function ExpenseLinesTable({ rows, currency }: { rows: ExpenseLineRow[]; currency: string }) {
    const t = useTranslations()
    // ★ 手机上留【科目】与【净额】—— 一行是什么、多少钱;税码、税与备注进展开区。
    const columns: Column<ExpenseLineRow>[] = [
        { key: 'lineNo', header: t('expense.colLineNo'), render: (r) => r.lineNo },
        {
            key: 'account', header: t('expense.colAccount'), priority: true,
            render: (r) => (<><span>{r.accountCode}</span> {r.accountName}</>),
        },
        { key: 'taxCode', header: t('expense.form.taxCode'), render: (r) => r.taxCode ?? '—' },
        {
            key: 'net', header: t('expense.colLineNet', { ccy: currency }), priority: true, align: 'right',
            render: (r) => formatMoneyBare(r.netCcy, '列头 colLineNet 里的 {ccy}'),
        },
        {
            key: 'tax', header: t('expense.colLineTax', { ccy: currency }), align: 'right',
            render: (r) => formatMoneyBare(r.taxCcy, '列头 colLineTax 里的 {ccy}'),
        },
        { key: 'notes', header: t('expense.form.lineNotes'), render: (r) => r.notes ?? '' },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => String(r.lineNo)} phone={{ mode: 'columns' }}
                   empty={t('expense.linesEmpty')} />
    )
}
