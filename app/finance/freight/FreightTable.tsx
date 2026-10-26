'use client'

// app/finance/freight/FreightTable.tsx
// CONV-4 · 运费单据登记簿那张表。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney, xDate } from '@/lib/export/cells'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { ListSort } from '@/lib/listSort'
import type { ListTotal } from '@/lib/listTotals'
import { totalsFooterRows } from '@/app/components/ui/list-totals'

export type FreightRow = {
    id: string
    code: string
    docDate: string
    /** TABLE-EXPORT-2a:单据日的原始日历日 */
    docDateRaw: string
    forwarder: string
    amountBase: number
    baseCurrency: string
    allocationBasis: string
    paymentStatus: string
    reversed: boolean
}

export default function FreightTable({ rows, empty, exportHref, sort, shown, total, totals }: {
    rows: FreightRow[]; empty: React.ReactNode
    /** TABLE-FEATURES-1 Q9:导出地址带上当前排序(freightRows.ts 的 freightExportHref) */
    exportHref: string
    /** TABLE-FEATURES-1 Q9:在数据库里排(freightRows.ts 的 FREIGHT_SORT);只画前 N 张 */
    sort: ListSort; shown: number; total: number
    /** TABLE-FEATURES-2 Q1:库算的表尾合计(所有在册运费单,不只画出来的前 200 张;冲销的加 0;freightRows.ts 的 freightTotals) */
    totals: ListTotal[]
}) {
    const t = useTranslations()
    const sortHref = useSortHref()

    // ★ 手机上留【单号】与【金额】—— 理由同其余登记簿:身份 + 这张表存在的理由。
    const columns: ExportableColumn<FreightRow>[] = [
        {
            key: 'code', sortable: true, header: t('finance.freight.colCode'), priority: true, className: 'text-sm',
            // 冲销的单据屏幕上整行划线发灰 —— 导出把这个状态写进单号格,不然它读起来与在册的一样
            exportAs: (r) => xText(r.reversed ? `${r.code} (${t('table.export.rowReversed')})` : r.code),
            render: (r) => (
                <Link href={`/finance/freight/${r.id}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'date', sortable: true, header: t('finance.freight.colDate'), render: (r) => r.docDate, exportAs: (r) => xDate(r.docDateRaw) },
        { key: 'forwarder', header: t('finance.freight.colForwarder'), render: (r) => r.forwarder, exportAs: (r) => xText(r.forwarder) },
        {
            key: 'amount', sortable: true, header: t('finance.freight.colAmount'), priority: true, align: 'right', className: 'text-sm',
            render: (r) => formatAmount(r.amountBase, r.baseCurrency),
            exportAs: (r) => xMoney(r.amountBase, r.baseCurrency),
        },
        { key: 'basis', sortable: true, header: t('finance.freight.colBasis'), className: 'text-sm', render: (r) => t('finance.freight.basis.' + r.allocationBasis), exportAs: (r) => xText(t('finance.freight.basis.' + r.allocationBasis)) },
        { key: 'payment', sortable: true, header: t('finance.freight.colPayment'), className: 'text-sm', render: (r) => t('finance.freight.payment.' + r.paymentStatus), exportAs: (r) => xText(t('finance.freight.payment.' + r.paymentStatus)) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            // ★ CONV-4:冲销单据整行发灰(转换前 <tr className="text-gray-400 line-through">)
            //   —— 这是给 DataTable 建 rowClassName 的那个第三次出现。
            rowClassName={(r) => (r.reversed ? 'text-gray-400 line-through' : undefined)}
            exportSpec={{ name: 'freight-documents', title: t('finance.freight.listTitle'), serverRows: exportHref }}
            sorting={{ mode: 'server', coverage: { shown, total }, active: sort, href: sortHref }}
            footer={() => totalsFooterRows(totals, { amount: 'amount' }, t)}
        />
    )
}
