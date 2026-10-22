'use client'

// app/finance/payments/PaymentsTable.tsx
// CONV-4 · 收付款登记簿那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney, xDate } from '@/lib/export/cells'

export type PaymentRow = {
    id: string
    code: string
    paymentDate: string
    /** TABLE-EXPORT-2a:收付日的原始日历日 */
    paymentDateRaw: string
    direction: string
    counterparty: string
    amountCcy: number
    currency: string
    amountBase: number
    baseCurrency: string
    bankAccountCode: string
    status: string
}

export default function PaymentsTable({ rows, empty, exportHref }: {
    rows: PaymentRow[]; empty: React.ReactNode
    /** TABLE-EXPORT-2a:服务端分页 —— 导出向这条路由要全部匹配行(同一套筛选) */
    exportHref: string
}) {
    const t = useTranslations()

    // ★ 手机上留【单号】与【金额】—— 单号是身份,金额是这张登记簿存在的理由。
    const columns: ExportableColumn<PaymentRow>[] = [
        {
            key: 'code', header: t('finance.colCode'), priority: true, className: 'text-sm',
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/finance/payments/${r.id}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'date', header: t('finance.colDate'), render: (r) => r.paymentDate, exportAs: (r) => xDate(r.paymentDateRaw) },
        {
            key: 'direction', header: t('finance.side'),
            exportAs: (r) => xText(t('finance.direction.' + r.direction)),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + (r.direction === 'in' ? 'bg-green-100 text-green-800' : 'bg-amber-100 text-amber-800')}>
                    {t('finance.direction.' + r.direction)}
                </span>
            ),
        },
        { key: 'counterparty', header: t('finance.colCounterparty'), className: 'text-sm', render: (r) => r.counterparty, exportAs: (r) => xText(r.counterparty) },
        {
            key: 'amount', header: t('finance.amount'), priority: true, align: 'right', className: 'text-sm',
            // 一格一个数:收付的原币金额带它自己的币种。外币那一笔旁边的「= 本位币」是同一笔钱按当时汇率折出来的,不另占格
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
        { key: 'bank', header: t('finance.bankAccount'), className: 'text-sm', render: (r) => t('finance.bank.' + r.bankAccountCode), exportAs: (r) => xText(t('finance.bank.' + r.bankAccountCode)) },
        {
            key: 'status', header: t('finance.colStatus'),
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
            exportSpec={{ name: 'payments', title: t('finance.paymentsTitle'), serverRows: exportHref }}
        />
    )
}
