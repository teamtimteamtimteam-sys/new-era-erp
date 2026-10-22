'use client'

// app/finance/invoices/InvoicesTable.tsx
// CONV-4 · 发票登记簿那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { MaskedValue } from '@/app/components/MaskedValue'
import { xText, xMoney, xDate, xMasked } from '@/lib/export/cells'

export type InvoiceRow = {
    invoiceId: string
    code: string
    kind: string | null
    customerName: string | null
    issueDate: string
    /** TABLE-EXPORT-2a:开具日 / 到期日的原始日历日 */
    issueDateRaw: string
    dueDate: string
    dueDateRaw: string
    daysOverdue: number | null
    overdue: boolean
    /** NULL = 读者没有 data.view_prices(invoices_masked 遮了它)—— 见 canViewPrices */
    totalBase: number | null
    settledBase: number | null
    openBase: number | null
    paymentState: string | null
    isVoid: boolean
    baseCurrency: string
    /** TABLE-EXPORT-2 Q8(Tim 2026-10-22):合计与未收被遮时屏幕与导出说「受限」,不说「—」 */
    canViewPrices: boolean
}

export default function InvoicesTable({ rows, empty, exportHref }: {
    rows: InvoiceRow[]; empty: React.ReactNode
    /** TABLE-EXPORT-2a:服务端分页 —— 导出向这条路由要全部匹配行(同一套筛选) */
    exportHref: string
}) {
    const t = useTranslations()

    const statePill = (r: InvoiceRow) => {
        if (r.isVoid) {
            return (
                <span className="px-2 py-1 rounded text-xs bg-gray-200 text-[color:var(--brand-text)]">
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
    const columns: ExportableColumn<InvoiceRow>[] = [
        {
            key: 'code', header: t('invoice.colCode'), priority: true, className: 'text-sm',
            // 「订单发票」那枚标与作废的划线都只在这一格里 —— 导出把它们写成文字接在单号后面
            exportAs: (r) => xText([r.code, r.kind === 'order' ? `(${t('invoice.kind.order')})` : null, r.isVoid ? `(${t('table.export.rowVoid')})` : null].filter(Boolean).join(' ')),
            render: (r) => (
                <>
                    <Link
                        href={`/finance/invoices/${r.invoiceId}`}
                        className={r.isVoid ? 'text-gray-500 hover:underline line-through' : 'app-link hover:underline'}
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
        { key: 'customer', header: t('invoice.colCustomer'), priority: true, render: (r) => r.customerName ?? '—', exportAs: (r) => xText(r.customerName) },
        { key: 'issueDate', header: t('invoice.colIssueDate'), render: (r) => r.issueDate, exportAs: (r) => xDate(r.issueDateRaw) },
        {
            key: 'dueDate', header: t('invoice.colDueDate'),
            // 一个真日期;「逾期 N 天」由这个日子与今天推得出,不写进日期格
            exportAs: (r) => xDate(r.dueDateRaw),
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
            key: 'total', header: t('invoice.colTotal'), align: 'right', className: 'text-sm',
            // Q8:被遮的合计是「受限」(MaskedValue 同一条判据),不是「—」
            render: (r) => <MaskedValue value={r.totalBase} canView={r.canViewPrices} format={(v: number) => formatAmount(v, r.baseCurrency)} fallback="—" />,
            exportAs: (r) => xMasked(r.totalBase, r.canViewPrices, (v) => xMoney(v, r.baseCurrency)),
        },
        {
            key: 'settled', header: t('invoice.colSettled'), align: 'right', className: 'text-sm',
            render: (r) => (r.settledBase === null ? '—' : formatAmount(r.settledBase, r.baseCurrency)),
            exportAs: (r) => xMoney(r.settledBase, r.baseCurrency),
        },
        {
            key: 'open', header: t('invoice.colOpen'), align: 'right', className: 'text-sm font-medium',
            // 未收由合计算出来:合计被遮,它也是 NULL —— 那是「受限」;作废的单没有未收,那才是「—」
            render: (r) => (r.isVoid ? '—'
                : <MaskedValue value={r.openBase} canView={r.canViewPrices} format={(v: number) => formatAmount(v, r.baseCurrency)} fallback="—" />),
            exportAs: (r) => (r.isVoid ? xMoney(null) : xMasked(r.openBase, r.canViewPrices, (v) => xMoney(v, r.baseCurrency))),
        },
        {
            key: 'state', header: t('invoice.colState'), render: statePill,
            exportAs: (r) => xText(r.isVoid ? t('invoice.status.void') : t('invoice.paymentState.' + (r.paymentState ?? 'unpaid'))),
        },
        {
            key: 'pdf', header: '', exportAs: false,
            render: (r) => (
                // 列表上点 PDF 是【拿文件】(要往邮件里附),不是读 ——
                // 所以走 ?download=1 存成附件。要看版式去详情页预览。
                // attachment 不会导航,故不需要 target="_blank"
                <a
                    href={`/finance/invoices/${r.invoiceId}/pdf?download=1`}
                    className="hover:underline text-sm app-link"
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
            exportSpec={{ name: 'invoices', title: t('invoice.listTitle'), serverRows: exportHref }}
        />
    )
}
