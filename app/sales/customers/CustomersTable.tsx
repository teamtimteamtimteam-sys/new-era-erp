'use client'

// app/sales/customers/CustomersTable.tsx
// CONV-5 · 客户名单那张表。
// ★ Q7:排序仍然是服务端的(sorting.mode='server',与 /inbound、/suppliers 同一个
//   口子)。href 是函数,过不了 RSC 边界,所以页面传筛选参数,这里再拼链接。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import type { ExportColumnDef } from '@/app/components/ui/table-export'
import { xText, xTime } from '@/lib/export/cells'
import DeleteButton from './DeleteButton'

export type CustomerTableRow = {
    id: string
    code: string
    legalName: string
    country: string
    /** null = 没有主联系人 —— 【那不是空白,是一句话】。 */
    contactName: string | null
    contactInferred: boolean
    email: string
    types: string
    status: string
    createdLabel: string
    /** TABLE-EXPORT-1:导出用的原始时刻(Excel 里是真日期,按新加坡时间)。 */
    createdAt: string
    // TABLE-EXPORT-1(Tim 2026-10-22 Q5 / Q11):旧 CSV 有、表上没有的六列 —— 只给导出的扩展列读,屏幕不画。
    shortName: string | null
    taxId: string | null
    paymentTerms: string | null
    incoterm: string | null
    creditRating: string | null
    address: string | null
}

export default function CustomersTable({
    rows, empty, sort, dir, filterQuery, shown, total, exportHref,
}: {
    rows: CustomerTableRow[]
    empty: React.ReactNode
    sort: string
    dir: 'asc' | 'desc'
    filterQuery: Record<string, string>
    shown: number
    total: number
    /** TABLE-EXPORT-1:服务端翻页取全的那条路由(带当前筛选与排序)。 */
    exportHref: string
}) {
    const t = useTranslations()

    // 保留 q,只改 sort/dir;不带 page —— 改排序回到第 1 页(与此前 sortHref 同义)。
    const href = (key: string, nextDir: 'asc' | 'desc') => {
        const params = new URLSearchParams(filterQuery)
        params.set('sort', key)
        params.set('dir', nextDir)
        return `/sales/customers?${params.toString()}`
    }

    // ★ 手机上留【编号】与【客户名】—— 编号是身份,名字是这份名单被打开的理由。
    const columns: ExportableColumn<CustomerTableRow>[] = [
        {
            // SAL-B6:编号指向【状况页】,不再直接指向编辑表单 ——
            // 看一个客户的第一件事通常不是改他。
            key: 'code', header: t('customers.col.code'), priority: true, sortable: true, className: 'text-sm',
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/sales/customers/${r.id}`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'legal_name', header: t('customers.col.legalName'), priority: true, sortable: true, render: (r) => r.legalName, exportAs: (r) => xText(r.legalName) },
        { key: 'country', header: t('customers.col.country'), render: (r) => r.country, exportAs: (r) => xText(r.country) },
        {
            // 【没有主联系人不是空白,是一句话】—— 具名的缺席。
            key: 'contact', header: t('customers.col.contactPerson'), className: 'text-sm',
            exportAs: (r) => xText(r.contactName
                ? r.contactName + (r.contactInferred ? ` (${t('contacts.inferredTag')})` : '')
                : t('contacts.noPrimary')),
            render: (r) =>
                r.contactName ? (
                    <>
                        {r.contactName}
                        {r.contactInferred && (
                            <span className="ml-1 text-xs text-amber-700" title={t('contacts.inferredWhy')}>
                                {t('contacts.inferredTag')}
                            </span>
                        )}
                    </>
                ) : (
                    <span className="text-xs text-gray-500">{t('contacts.noPrimary')}</span>
                ),
        },
        { key: 'email', header: t('customers.col.email'), className: 'text-sm break-all', render: (r) => r.email, exportAs: (r) => xText(r.email) },
        { key: 'types', header: t('customers.col.types'), className: 'text-sm', render: (r) => r.types, exportAs: (r) => xText(r.types) },
        {
            key: 'status', header: t('customers.col.status'), exportAs: (r) => xText(r.status),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.status}</span>,
        },
        {
            key: 'created_at', header: t('customers.col.created'), sortable: true,
            className: 'text-sm text-gray-600', render: (r) => r.createdLabel,
            exportAs: (r) => xTime(r.createdAt),
        },
        {
            key: 'actions', header: t('customers.colActions'), exportAs: false,
            render: (r) => <DeleteButton id={r.id} legalName={r.legalName} />,
        },
    ]

    // ★ TABLE-EXPORT-1(Tim 2026-10-22 Q5 / Q11):旧的 CSV 导出(app/sales/customers/export/route.ts 从前那一版)
    //   比这张表多六列。它们【声明】成扩展列留在导出里,接在表的列后面;表头用编辑表单上同一句话。
    //   这是唯一的例外 —— 别的表导出的列就是表的列(scripts/check-table-export.mjs 只放这两张)。
    const extension: ExportColumnDef<CustomerTableRow>[] = [
        { key: 'short_name', header: t('customers.form.shortName'), exportAs: (r) => xText(r.shortName) },
        { key: 'tax_id', header: t('customers.form.taxId'), exportAs: (r) => xText(r.taxId) },
        { key: 'payment_terms', header: t('customers.form.paymentTerms'), exportAs: (r) => xText(r.paymentTerms) },
        { key: 'incoterm', header: t('customers.form.incoterm'), exportAs: (r) => xText(r.incoterm) },
        { key: 'credit_rating', header: t('customers.form.creditRating'), exportAs: (r) => xText(r.creditRating) },
        { key: 'address', header: t('customers.form.address'), exportAs: (r) => xText(r.address) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            sorting={{ mode: 'server', coverage: { shown, total }, active: { key: sort, dir }, href }}
            exportSpec={{ name: 'customers', title: t('customers.listTitle'), serverRows: exportHref, extension }}
        />
    )
}
