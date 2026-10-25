'use client'

// app/finance/expenses/[id]/ExpenseLinesTable.tsx
// EXPENSE-MULTILINE-1(Tim 2026-10-20):费用单的行 —— 每一行自己的科目、税码、不含税净额、税与备注。
// 金额以单据币种印(表头已经说了币种与汇率);合计行就是表头那几个数(库强制它们 = 各行之和,所以这里不另加一遍)。

import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xInt, xMoney, xText } from '@/lib/export/cells'

export type ExpenseLineRow = {
    lineNo: number
    accountCode: string
    accountName: string
    taxCode: string | null
    netCcy: number
    taxCcy: number
    notes: string | null
}

export default function ExpenseLinesTable({ rows, currency, expenseCode }: { rows: ExpenseLineRow[]; currency: string; expenseCode: string }) {
    const t = useTranslations()
    // ★ 手机上留【科目】与【净额】—— 一行是什么、多少钱;税码、税与备注进展开区。
    // ★ TABLE-EXPORT-3b:一对导出。行里本来就是原始值;金额的币种在表头里(colLineNet/colLineTax 的 {ccy}),格子是光秃秃的数。
    const columns: ExportableColumn<ExpenseLineRow>[] = [
        { key: 'lineNo', header: t('expense.colLineNo'), render: (r) => r.lineNo, exportAs: (r) => xInt(r.lineNo) },
        {
            key: 'account', header: t('expense.colAccount'), priority: true,
            render: (r) => (<><span>{r.accountCode}</span> {r.accountName}</>),
            // 屏幕上是「科目号 科目名」一格 —— 导出照屏幕那串字
            exportAs: (r) => xText(`${r.accountCode} ${r.accountName}`),
        },
        { key: 'taxCode', header: t('expense.form.taxCode'), render: (r) => r.taxCode ?? '—', exportAs: (r) => xText(r.taxCode) },
        {
            key: 'net', header: t('expense.colLineNet', { ccy: currency }), priority: true, align: 'right',
            render: (r) => formatMoneyBare(r.netCcy, '列头 colLineNet 里的 {ccy}'),
            exportAs: (r) => xMoney(r.netCcy),
        },
        {
            key: 'tax', header: t('expense.colLineTax', { ccy: currency }), align: 'right',
            render: (r) => formatMoneyBare(r.taxCcy, '列头 colLineTax 里的 {ccy}'),
            exportAs: (r) => xMoney(r.taxCcy),
        },
        { key: 'notes', header: t('expense.form.lineNotes'), render: (r) => r.notes ?? '', exportAs: (r) => xText(r.notes) },
    ]
    return (
        <DataTable rows={rows} columns={columns} rowKey={(r) => String(r.lineNo)} phone={{ mode: 'columns' }}
                   empty={t('expense.linesEmpty')}
                   exportSpec={{ name: 'finance-expense-lines', title: t('expense.detailLines'), aboutExtra: [[t('expense.colCode'), expenseCode]] }} />
    )
}
