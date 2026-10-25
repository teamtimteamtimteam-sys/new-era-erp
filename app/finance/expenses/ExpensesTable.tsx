'use client'

// app/finance/expenses/ExpensesTable.tsx
// CONV-4 · 开支登记簿那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney, xDate } from '@/lib/export/cells'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { ListSort } from '@/lib/listSort'

export type ExpenseRow = {
    id: string
    code: string
    expenseDate: string
    /** TABLE-EXPORT-2a:开支日的原始日历日 */
    expenseDateRaw: string
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

export default function ExpensesTable({ rows, empty, exportHref, sort, shown, total }: {
    rows: ExpenseRow[]; empty: React.ReactNode
    /** TABLE-EXPORT-2a:服务端分页 —— 导出向这条路由要全部匹配行(同一套筛选) */
    exportHref: string
    /** TABLE-FEATURES-1 Q9:在数据库里排(expenseRows.ts 的 EXPENSE_SORT) */
    sort: ListSort; shown: number; total: number
}) {
    const t = useTranslations()
    const sortHref = useSortHref()

    // ★ 手机上留【单号】与【金额】—— 单号是身份,金额是这张登记簿存在的理由。
    //   科目、状态、对方、过账态都是认出这一行之后才要问的,进展开区。
    const columns: ExportableColumn<ExpenseRow>[] = [
        {
            key: 'code', sortable: true, header: t('expense.colCode'), priority: true, className: 'text-sm',
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/finance/expenses/${r.id}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'date', sortable: true, header: t('expense.colDate'), render: (r) => r.expenseDate, exportAs: (r) => xDate(r.expenseDateRaw) },
        {
            key: 'account', header: t('expense.colAccount'), className: 'text-sm',
            exportAs: (r) => xText(`${r.accountCode} ${r.accountName}`.trim()),
            render: (r) => (
                <>
                    <span>{r.accountCode}</span> {r.accountName}
                </>
            ),
        },
        {
            key: 'amount', sortable: true, header: t('expense.colAmount'), priority: true, align: 'right', className: 'text-sm',
            // 一格一个数:原币金额带它自己的币种;外币那一笔旁边的「= 本位币」是同一笔钱折出来的,不另占格
            exportAs: (r) => xMoney(r.amountCcy, r.currency),
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
            key: 'paymentStatus', sortable: true, header: t('expense.colStatus'),
            exportAs: (r) => xText(t('expense.status.' + r.paymentStatus)),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + (r.paymentStatus === 'paid' ? 'bg-green-100 text-green-800' : 'bg-amber-100 text-amber-800')}>
                    {t('expense.status.' + r.paymentStatus)}
                </span>
            ),
        },
        { key: 'counterparty', header: t('expense.colCounterparty'), className: 'text-sm', render: (r) => r.counterparty, exportAs: (r) => xText(r.counterparty) },
        {
            key: 'postedStatus', sortable: true, header: t('finance.colStatus'),
            exportAs: (r) => xText(t('finance.status.' + r.status)),
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
            exportSpec={{ name: 'expenses', title: t('expense.listTitle'), serverRows: exportHref }}
            sorting={{ mode: 'server', coverage: { shown, total }, active: sort, href: sortHref }}
        />
    )
}
