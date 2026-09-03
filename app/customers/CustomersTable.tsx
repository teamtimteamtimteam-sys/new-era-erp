'use client'

// app/customers/CustomersTable.tsx
// CONV-5 · 客户名单那张表。
// ★ Q7:排序仍然是服务端的(sorting.mode='server',与 /inbound、/suppliers 同一个
//   口子)。href 是函数,过不了 RSC 边界,所以页面传筛选参数,这里再拼链接。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
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
}

export default function CustomersTable({
    rows, empty, sort, dir, filterQuery, shown, total,
}: {
    rows: CustomerTableRow[]
    empty: React.ReactNode
    sort: string
    dir: 'asc' | 'desc'
    filterQuery: Record<string, string>
    shown: number
    total: number
}) {
    const t = useTranslations()

    // 保留 q,只改 sort/dir;不带 page —— 改排序回到第 1 页(与此前 sortHref 同义)。
    const href = (key: string, nextDir: 'asc' | 'desc') => {
        const params = new URLSearchParams(filterQuery)
        params.set('sort', key)
        params.set('dir', nextDir)
        return `/customers?${params.toString()}`
    }

    // ★ 手机上留【编号】与【客户名】—— 编号是身份,名字是这份名单被打开的理由。
    const columns: Column<CustomerTableRow>[] = [
        {
            // SAL-B6:编号指向【状况页】,不再直接指向编辑表单 ——
            // 看一个客户的第一件事通常不是改他。
            key: 'code', header: t('customers.col.code'), priority: true, sortable: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/customers/${r.id}`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'legal_name', header: t('customers.col.legalName'), priority: true, sortable: true, render: (r) => r.legalName },
        { key: 'country', header: t('customers.col.country'), render: (r) => r.country },
        {
            // 【没有主联系人不是空白,是一句话】—— 具名的缺席。
            key: 'contact', header: t('customers.col.contactPerson'), className: 'text-sm',
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
        { key: 'email', header: t('customers.col.email'), className: 'text-sm break-all', render: (r) => r.email },
        { key: 'types', header: t('customers.col.types'), className: 'text-sm', render: (r) => r.types },
        {
            key: 'status', header: t('customers.col.status'),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{r.status}</span>,
        },
        {
            key: 'created_at', header: t('customers.col.created'), sortable: true,
            className: 'text-sm text-gray-600', render: (r) => r.createdLabel,
        },
        {
            key: 'actions', header: t('customers.colActions'),
            render: (r) => <DeleteButton id={r.id} legalName={r.legalName} />,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            sorting={{ mode: 'server', coverage: { shown, total }, active: { key: sort, dir }, href }}
        />
    )
}
