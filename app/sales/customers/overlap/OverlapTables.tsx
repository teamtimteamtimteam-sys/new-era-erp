'use client'

// app/sales/customers/overlap/OverlapTables.tsx
// CONV-5 · 往来重叠报告的两张表(按税号 / 按名称)。
// ★ 这一页【故意】不给出一个合计,理由画在数字旁边(轧差是一次法律行为,
//   不是一次算术)。那句话与覆盖率分母都住在 page.tsx 的 notices 里,
//   而不是这两张表里 —— 表只负责列出配对。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney } from '@/lib/export/cells'

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
    /** TABLE-EXPORT-1:导出用的原始未结额(本位币)—— 与屏幕同一个数,不是格式化过的那串。 */
    arOpenBase: number
    apOpenBase: number
    /** TABLE-EXPORT-1:屏幕上两个未结额后面跟着的本位币(formatAmount 的「1,234.56 <本位币>」)—— 导出时一起写。 */
    ccy: string
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
    const columns: ExportableColumn<ByTaxRow>[] = [
        { key: 'taxId', header: t('overlap.colTaxId'), priority: true, className: 'text-sm', render: (r) => r.taxId, exportAs: (r) => xText(r.taxId) },
        {
            key: 'customer', header: t('overlap.colCustomer'), priority: true, className: 'text-sm',
            exportAs: (r) => xText(`${r.customerCode} · ${r.customerName}`),
            render: (r) => (
                <>
                    <Link href={`/sales/customers/${r.customerId}`} className="hover:underline app-link">
                        {r.customerCode}
                    </Link>{' '}
                    · {r.customerName}
                </>
            ),
        },
        {
            key: 'supplier', header: t('overlap.colSupplier'), className: 'text-sm',
            exportAs: (r) => xText(`${r.supplierCode} · ${r.supplierName}`),
            render: (r) => (
                <>
                    <Link href={`/suppliers/${r.supplierId}/edit`} className="hover:underline app-link">
                        {r.supplierCode}
                    </Link>{' '}
                    · {r.supplierName}
                </>
            ),
        },
        // ★ 两列并排,【不】合计 —— 导出也只给两列,不给一个轧差数(理由在 page.tsx 的 notices 里)
        { key: 'ar', header: t('overlap.colAr'), align: 'right', className: 'text-sm', render: (r) => r.arOpen, exportAs: (r) => xMoney(r.arOpenBase, r.ccy) },
        { key: 'ap', header: t('overlap.colAp'), align: 'right', className: 'text-sm', render: (r) => r.apOpen, exportAs: (r) => xMoney(r.apOpenBase, r.ccy) },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} className="mb-6"
        exportSpec={{ name: 'counterparty-overlap-by-tax-id', title: t('overlap.byTaxTitle') }} />
}

export function ByNameTable({ rows }: { rows: ByNameRow[] }) {
    const t = useTranslations()

    // 2 列表:两列都留 —— 一条"按名称疑似同一家"的记录,少任何一侧都不成话。
    const columns: ExportableColumn<ByNameRow>[] = [
        { key: 'customer', header: t('overlap.colCustomer'), priority: true, className: 'text-sm', render: (r) => r.customerLabel, exportAs: (r) => xText(r.customerLabel) },
        { key: 'supplier', header: t('overlap.colSupplier'), priority: true, className: 'text-sm', render: (r) => r.supplierLabel, exportAs: (r) => xText(r.supplierLabel) },
    ]

    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }}
        exportSpec={{ name: 'counterparty-overlap-by-name', title: t('overlap.byNameTitle') }} />
}
