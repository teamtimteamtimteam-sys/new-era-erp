'use client'

// app/finance/invoices/InvoicesTable.tsx
// CONV-4 · 发票登记簿那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type InvoiceRow = {
    invoiceId: string
    code: string
    kind: string | null
    customerName: string | null
    issueDate: string
    dueDate: string
    daysOverdue: number | null
    overdue: boolean
    totalBase: number
    settledBase: number | null
    openBase: number | null
    paymentState: string | null
    isVoid: boolean
    baseCurrency: string
}

export default function InvoicesTable({ rows, empty }: { rows: InvoiceRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    const statePill = (r: InvoiceRow) => {
        if (r.isVoid) {
            return (
                <span className="px-2 py-1 rounded text-xs bg-gray-200 text-gray-600">
                    {t('invoice.status.void')}
                </span>
            )
        }
        const cls =
            r.paymentState === 'paid'
                ? 'bg-green-100 text-green-800'
                : r.paymentState === 'partial'
                  ? 'bg-amber-100 text-amber-800'
                  : 'bg-gray-200 text-gray-700'
        return (
            <span className={'px-2 py-1 rounded text-xs ' + cls}>
                {t('invoice.paymentState.' + (r.paymentState ?? 'unpaid'))}
            </span>
        )
    }

    // ★ 手机上留【单号】与【未结】—— 未结是这张登记簿存在的理由(谁还欠着钱)。
    //   客户名进展开区会让人对不上是谁欠的钱,所以也留在手机上。
    const columns: Column<InvoiceRow>[] = [
        {
            key: 'code', header: t('invoice.colCode'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <>
                    <Link
                        href={`/finance/invoices/${r.invoiceId}`}
                        className={r.isVoid ? 'text-gray-500 hover:underline line-through' : 'text-blue-600 hover:underline'}
                    >
                        {r.code}
                    </Link>
                    {/* SO-3a:order 头是过账单据 —— 列表上就要分得出两种 */}
                    {r.kind === 'order' && (
                        <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-blue-100 text-blue-800">
                            {t('invoice.kind.order')}
                        </span>
                    )}
                </>
            ),
        },
        { key: 'customer', header: t('invoice.colCustomer'), priority: true, render: (r) => r.customerName ?? '—' },
        { key: 'issueDate', header: t('invoice.colIssueDate'), render: (r) => r.issueDate },
        {
            key: 'dueDate', header: t('invoice.colDueDate'),
            render: (r) => (
                <>
                    {r.dueDate}
                    {r.overdue && r.daysOverdue ? (
                        <span className="ml-2 text-xs text-red-600">
                            {t('invoice.overdueDays', { n: r.daysOverdue })}
                        </span>
                    ) : null}
                </>
            ),
        },
        {
            key: 'total', header: t('invoice.colTotal'), align: 'right', className: 'font-mono text-sm',
            render: (r) => formatAmount(r.totalBase, r.baseCurrency),
        },
        {
            key: 'settled', header: t('invoice.colSettled'), align: 'right', className: 'font-mono text-sm',
            render: (r) => (r.settledBase === null ? '—' : formatAmount(r.settledBase, r.baseCurrency)),
        },
        {
            key: 'open', header: t('invoice.colOpen'), align: 'right', className: 'font-mono text-sm font-medium',
            render: (r) => (r.openBase === null ? '—' : formatAmount(r.openBase, r.baseCurrency)),
        },
        { key: 'state', header: t('invoice.colState'), render: statePill },
        {
            key: 'pdf', header: '',
            render: (r) => (
                // 列表上点 PDF 是【拿文件】(要往邮件里附),不是读 ——
                // 所以走 ?download=1 存成附件。要看版式去详情页预览。
                // attachment 不会导航,故不需要 target="_blank"
                <a
                    href={`/finance/invoices/${r.invoiceId}/pdf?download=1`}
                    className="text-blue-600 hover:underline text-sm"
                >
                    PDF
                </a>
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.invoiceId}
            phone={{ mode: 'columns' }}
            empty={empty}
            // ★ CONV-4:作废发票整行发灰(转换前 <tr className="text-gray-400">)——
            //   与 freight 的冲销行同一个形状,rowClassName 的又一处调用点。
            rowClassName={(r) => (r.isVoid ? 'text-gray-400' : undefined)}
        />
    )
}
