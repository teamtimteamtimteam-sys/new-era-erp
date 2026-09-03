'use client'

// app/sales/orders/SalesOrdersTable.tsx
// CONV-5 · 销售订单登记簿那张表。
// 日期按 locale 格式化在服务端做完 —— locale 不过 RSC 边界(CONV-1 §① 通则)。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type SalesOrderRow = {
    id: string
    code: string
    customerLabel: string
    orderDateLabel: string
    statusLabel: string
    currency: string
}

export default function SalesOrdersTable({ rows, empty }: { rows: SalesOrderRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【单号】与【客户】—— 单号是身份,客户是这张登记簿被扫读的理由
    //   (这一单是谁的)。日期/状态/币种进展开区。
    const columns: Column<SalesOrderRow>[] = [
        {
            key: 'code', header: t('sales.colCode'), priority: true,
            render: (r) => (
                <Link href={`/sales/orders/${r.id}`} className="text-blue-600 hover:underline font-mono text-xs">
                    {r.code}
                </Link>
            ),
        },
        { key: 'customer', header: t('sales.colCustomer'), priority: true, render: (r) => r.customerLabel },
        { key: 'date', header: t('sales.colDate'), render: (r) => r.orderDateLabel },
        { key: 'status', header: t('sales.colStatus'), render: (r) => r.statusLabel },
        { key: 'currency', header: t('sales.colCurrency'), render: (r) => r.currency },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={empty} />
}
