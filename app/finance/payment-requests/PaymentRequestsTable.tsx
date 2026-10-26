'use client'

// app/finance/payment-requests/PaymentRequestsTable.tsx
// PAY-REQ-1 · 付款申请列表那张表。行在服务端压平(名字、日期),这里只画。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney, xTime } from '@/lib/export/cells'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { ListSort } from '@/lib/listSort'
import type { ListTotal } from '@/lib/listTotals'
import { totalsFooterRows } from '@/app/components/ui/list-totals'

export type PaymentRequestRow = {
    id: string
    code: string
    kind: string
    payee: string
    amountCcy: number
    currency: string
    status: string
    createdDate: string
    /** TABLE-EXPORT-2a:提出时刻(原始 ISO)—— 导出按 Q7 写成新加坡时间 */
    createdAtRaw: string
}

// 状态的颜色:等人批 = 琥珀;等人付 = 蓝;付了 = 绿;驳回/撤回 = 灰。
function statusClass(s: string): string {
    if (s === 'submitted') return 'bg-amber-100 text-amber-800'
    if (s === 'approved') return 'bg-blue-100 text-blue-800'
    if (s === 'paid') return 'bg-green-100 text-green-800'
    return 'bg-gray-200 text-gray-700'
}

export default function PaymentRequestsTable({ rows, empty, exportHref, sort, shown, total, totals }: {
    rows: PaymentRequestRow[]; empty: React.ReactNode
    /** TABLE-EXPORT-2a:服务端分页 —— 导出向这条路由要全部匹配行(同一个状态筛选) */
    exportHref: string
    /** TABLE-FEATURES-1 Q9:在数据库里排(requestRows.ts 的 REQUEST_SORT) */
    sort: ListSort; shown: number; total: number
    /** TABLE-FEATURES-2(Tim Q1):库算的合计(list_totals_payment_requests)—— 同一个状态筛选下的全部行,每个币种一行 */
    totals: ListTotal[]
}) {
    const t = useTranslations()
    const sortHref = useSortHref()

    // ★ 手机上留【申请号】与【金额】—— 申请号是身份,金额是审批人批的那个数。
    const columns: ExportableColumn<PaymentRequestRow>[] = [
        {
            key: 'code', sortable: true, header: t('finance.colCode'), priority: true,
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/finance/payment-requests/${r.id}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'kind', sortable: true, header: t('finance.paymentRequests.colKind'), render: (r) => t('finance.paymentRequests.kind.' + r.kind), exportAs: (r) => xText(t('finance.paymentRequests.kind.' + r.kind)) },
        { key: 'payee', header: t('finance.paymentRequests.colPayee'), render: (r) => r.payee, exportAs: (r) => xText(r.payee) },
        {
            key: 'amount', sortable: true, header: t('finance.amount'), priority: true, align: 'right',
            exportAs: (r) => xMoney(r.amountCcy, r.currency),
            render: (r) => (
                <>{r.currency} {formatMoneyBare(r.amountCcy, '同格内紧邻的 r.currency 前缀')}</>
            ),
        },
        {
            key: 'status', sortable: true, header: t('finance.colStatus'),
            exportAs: (r) => xText(t('finance.paymentRequests.status.' + r.status)),
            render: (r) => (
                <span className={'px-2 py-1 rounded text-xs ' + statusClass(r.status)}>
                    {t('finance.paymentRequests.status.' + r.status)}
                </span>
            ),
        },
        { key: 'created', sortable: true, header: t('finance.paymentRequests.colRaised'), render: (r) => r.createdDate, exportAs: (r) => xTime(r.createdAtRaw) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            exportSpec={{ name: 'payment-requests', title: t('finance.paymentRequests.title'), serverRows: exportHref }}
            sorting={{ mode: 'server', coverage: { shown, total }, active: sort, href: sortHref }}
            footer={() => totalsFooterRows(totals, { amount: 'amount' }, t)}
        />
    )
}
