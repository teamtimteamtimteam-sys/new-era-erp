'use client'

// app/sales/orders/SalesOrdersTable.tsx
// CONV-5 · 销售订单登记簿那张表。
// 日期按 locale 格式化在服务端做完 —— locale 不过 RSC 边界(CONV-1 §① 通则)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xDate } from '@/lib/export/cells'

export type SalesOrderRow = {
    id: string
    code: string
    customerLabel: string
    orderDateLabel: string
    /** TABLE-EXPORT-1:导出用的原始日子 `YYYY-MM-DD`(Excel 里是真日期)。 */
    orderDate: string
    statusLabel: string
    currency: string
}

export default function SalesOrdersTable({ rows, empty }: { rows: SalesOrderRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【单号】与【客户】—— 单号是身份,客户是这张登记簿被扫读的理由
    //   (这一单是谁的)。日期/状态/币种进展开区。
    const columns: ExportableColumn<SalesOrderRow>[] = [
        {
            key: 'code', header: t('sales.colCode'), priority: true, exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/sales/orders/${r.id}`} className="hover:underline text-xs app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'customer', header: t('sales.colCustomer'), priority: true, render: (r) => r.customerLabel, exportAs: (r) => xText(r.customerLabel) },
        { key: 'date', header: t('sales.colDate'), render: (r) => r.orderDateLabel, exportAs: (r) => xDate(r.orderDate) },
        { key: 'status', header: t('sales.colStatus'), render: (r) => r.statusLabel, exportAs: (r) => xText(r.statusLabel) },
        { key: 'currency', header: t('sales.colCurrency'), render: (r) => r.currency, exportAs: (r) => xText(r.currency) },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty}
        exportSpec={{ name: 'sales-orders', title: t('sales.listTitle') }} />
}
