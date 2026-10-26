'use client'

// app/finance/credit-notes/CreditNotesTable.tsx
// CONV-4 · 贷项凭证登记簿那张表。见 page.tsx 顶注:模板通则,服务端压平、客户端只画。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney, xDate, xRestricted } from '@/lib/export/cells'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { ListSort } from '@/lib/listSort'
import type { ListTotal } from '@/lib/listTotals'
import { totalsFooterRows } from '@/app/components/ui/list-totals'

export type CreditNoteRow = {
    id: string
    code: string
    noteDate: string
    /** TABLE-EXPORT-2a:凭证日的原始日历日 */
    noteDateRaw: string
    // TABLE-EXPORT-2a:客户那一格是【纯数据】(从前是服务端画好的 ReactNode,过不了导出路由的 JSON)。
    //   受限 = 读者没有 module.customers.view —— 屏幕与导出都说「受限」,不说「—」(那会读成「这张凭证没有客户」)。
    customerRestricted: boolean
    customerCode: string | null
    customerName: string | null
    invoiceId: string | null
    invoiceCode: string | null
    total: number
    currency: string
    version: number | null
    reason: string
}

export default function CreditNotesTable({ rows, exportHref, sort, shown, total, totals }: {
    rows: CreditNoteRow[]
    /** TABLE-FEATURES-1 Q9:导出地址带上当前排序(creditNoteRows.ts 的 creditNoteExportHref) */
    exportHref: string
    /** TABLE-FEATURES-1 Q9:在数据库里排(creditNoteRows.ts 的 CREDIT_NOTE_SORT) */
    sort: ListSort; shown: number; total: number
    /** TABLE-FEATURES-2 Q1:库算的表尾合计(所有凭证的行之和,每个币种一行;creditNoteRows.ts 的 creditNoteTotals) */
    totals: ListTotal[]
}) {
    // ★ TABLE-EXPORT-2a:服务端分页,导出向 /finance/credit-notes/export 要全部行(这一页没有筛选)
    const t = useTranslations()
    const sortHref = useSortHref()

    // ★ 手机上留【单号】与【合计】—— 单号是身份,合计是这张登记簿存在的理由
    //   (人来这一页最常问的是"这张凭证冲了多少")。客户、对冲发票、签发状态、
    //   理由都是认出这一行之后才要问的,进展开区。
    const columns: ExportableColumn<CreditNoteRow>[] = [
        {
            key: 'code', sortable: true, header: t('cn.colCode'), priority: true, className: 'text-sm',
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/finance/credit-notes/${r.id}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'noteDate', sortable: true, header: t('cn.noteDate'), render: (r) => r.noteDate, exportAs: (r) => xDate(r.noteDateRaw) },
        {
            key: 'customer', header: t('cn.colCustomer'),
            exportAs: (r) => (r.customerRestricted ? xRestricted
                : xText(r.customerName ? `${r.customerCode ?? ''} ${r.customerName}`.trim() : null)),
            render: (r) => {
                if (r.customerRestricted) return <span className="text-[color:var(--brand-muted-text)]">{t('common.restricted')}</span>
                if (!r.customerName) return <span className="text-gray-400">—</span>
                return (
                    <>
                        <span className="text-xs text-[color:var(--brand-muted-text)]">{r.customerCode}</span> {r.customerName}
                    </>
                )
            },
        },
        {
            key: 'invoice', header: t('cn.againstInvoice'), className: 'text-sm',
            exportAs: (r) => xText(r.invoiceCode),
            render: (r) =>
                r.invoiceId ? (
                    <Link href={`/finance/invoices/${r.invoiceId}`} className="hover:underline app-link">
                        {r.invoiceCode}
                    </Link>
                ) : (
                    <span className="text-gray-400">—</span>
                ),
        },
        {
            key: 'total', header: t('cn.totalLabel'), priority: true, align: 'right', className: 'text-sm',
            render: (r) => formatAmount(r.total, r.currency),
            exportAs: (r) => xMoney(r.total, r.currency),
        },
        {
            key: 'issued', header: t('cn.colIssued'),
            exportAs: (r) => xText(r.version === null ? t('cn.noIssues') : t('cn.issuedVersion', { n: r.version })),
            render: (r) =>
                r.version === null ? (
                    <span className="text-gray-500">{t('cn.noIssues')}</span>
                ) : (
                    <span className="px-2 py-1 rounded text-xs bg-green-100 text-green-800">
                        {t('cn.issuedVersion', { n: r.version })}
                    </span>
                ),
        },
        { key: 'reason', sortable: true, header: t('cn.reason'), render: (r) => <span className="text-gray-700">{r.reason}</span>, exportAs: (r) => xText(r.reason) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={t('cn.empty')}
            exportSpec={{ name: 'credit-notes', title: t('cn.title'), serverRows: exportHref }}
            sorting={{ mode: 'server', coverage: { shown, total }, active: sort, href: sortHref }}
            footer={() => totalsFooterRows(totals, { total: 'total' }, t)}
        />
    )
}
