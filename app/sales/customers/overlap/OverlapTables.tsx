'use client'

// app/sales/customers/overlap/OverlapTables.tsx
// CONV-5 · 往来重叠报告的两张表(按税号 / 按名称)。
// ★ 这一页【故意】不给出一个合计,理由画在数字旁边(轧差是一次法律行为,
//   不是一次算术)。那句话与覆盖率分母都住在 page.tsx 的 notices 里,
//   而不是这两张表里 —— 表只负责列出配对。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type ByTaxRow = {
    key: string
    taxId: string
    customerId: string
    customerCode: string
    customerName: string
    supplierId: string
    supplierCode: string
    supplierName: string
    arOpen: string
    apOpen: string
}

export type ByNameRow = {
    key: string
    customerLabel: string
    supplierLabel: string
}

export function ByTaxTable({ rows }: { rows: ByTaxRow[] }) {
    const t = useTranslations()

    // ★ 手机上留【税号】与【客户】—— 税号是这一条配对的身份(两侧凭它认成同一家),
    //   客户侧是读者手上那一边。供应商侧与两个未结额进展开区。
    const columns: Column<ByTaxRow>[] = [
        { key: 'taxId', header: t('overlap.colTaxId'), priority: true, className: 'font-mono text-sm', render: (r) => r.taxId },
        {
            key: 'customer', header: t('overlap.colCustomer'), priority: true, className: 'text-sm',
            render: (r) => (
                <>
                    <Link href={`/sales/customers/${r.customerId}`} className="text-blue-600 hover:underline">
                        {r.customerCode}
                    </Link>{' '}
                    · {r.customerName}
                </>
            ),
        },
        {
            key: 'supplier', header: t('overlap.colSupplier'), className: 'text-sm',
            render: (r) => (
                <>
                    <Link href={`/suppliers/${r.supplierId}/edit`} className="text-blue-600 hover:underline">
                        {r.supplierCode}
                    </Link>{' '}
                    · {r.supplierName}
                </>
            ),
        },
        { key: 'ar', header: t('overlap.colAr'), align: 'right', className: 'text-sm', render: (r) => r.arOpen },
        { key: 'ap', header: t('overlap.colAp'), align: 'right', className: 'text-sm', render: (r) => r.apOpen },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} className="mb-6" />
}

export function ByNameTable({ rows }: { rows: ByNameRow[] }) {
    const t = useTranslations()

    // 2 列表:两列都留 —— 一条"按名称疑似同一家"的记录,少任何一侧都不成话。
    const columns: Column<ByNameRow>[] = [
        { key: 'customer', header: t('overlap.colCustomer'), priority: true, className: 'text-sm', render: (r) => r.customerLabel },
        { key: 'supplier', header: t('overlap.colSupplier'), priority: true, className: 'text-sm', render: (r) => r.supplierLabel },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} />
}
