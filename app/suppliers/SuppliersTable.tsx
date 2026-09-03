'use client'

// app/suppliers/SuppliersTable.tsx
// CONV-5 · 供应商名单那张表。
//
// ★★【Q7:排序仍然是【服务端】的,表头仍然是链接】★★
// 这一页此前用一个 sortableTh 把三列表头渲染成带 ▲▼ 的链接,由 URL 参数
// 去数据库排。DataTable 的 `sorting.mode: 'server'` 就是为这一形状开的口子
// (CONV-1 在 /inbound 上先走过一遍),所以行为一个字没变:
//   · 排的是【全体】,不是这一页的 20 行;
//   · 链接由【客户端】拼 —— href 是一个函数,过不了 RSC 边界,
//     所以页面传的是筛选参数(纯数据),这里再拼。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import DeleteButton from './DeleteButton'

export type SupplierTableRow = {
    id: string
    code: string
    legalName: string
    country: string
    types: string
    status: string
    createdLabel: string
}

export default function SuppliersTable({
    rows, empty, sort, dir, filterQuery, shown, total,
}: {
    rows: SupplierTableRow[]
    empty: React.ReactNode
    sort: string
    dir: 'asc' | 'desc'
    /** 当前筛选参数(不含 sort/dir/page)—— 排序链接要原样带上它们。 */
    filterQuery: Record<string, string>
    shown: number
    total: number
}) {
    const t = useTranslations()

    // 排序链接:点当前列翻转方向,点其它列默认升序;保留 q / status。
    // 不带 page —— 改变排序时回到第 1 页。(与此前那个 sortHref 逐字同义。)
    const href = (key: string, nextDir: 'asc' | 'desc') => {
        const params = new URLSearchParams(filterQuery)
        params.set('sort', key)
        params.set('dir', nextDir)
        return `/suppliers?${params.toString()}`
    }

    // ★ 手机上留【编号】与【供应商名】—— 编号是身份,名字是这份名单被打开的理由。
    const columns: Column<SupplierTableRow>[] = [
        {
            key: 'code', header: t('suppliers.col.code'), priority: true, sortable: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/suppliers/${r.id}/edit`} className="text-blue-600 hover:underline">
                    {r.code}
                </Link>
            ),
        },
        { key: 'legal_name', header: t('suppliers.col.legalName'), priority: true, sortable: true, render: (r) => r.legalName },
        { key: 'country', header: t('suppliers.col.country'), render: (r) => r.country },
        { key: 'types', header: t('suppliers.col.types'), className: 'text-sm', render: (r) => r.types },
        {
            key: 'status', header: t('suppliers.col.status'), sortable: true,
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{t('suppliers.status.' + r.status)}</span>,
        },
        {
            key: 'created_at', header: t('suppliers.col.created'), sortable: true,
            className: 'text-sm text-gray-600', render: (r) => r.createdLabel,
        },
        {
            key: 'actions', header: t('suppliers.colActions'),
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
