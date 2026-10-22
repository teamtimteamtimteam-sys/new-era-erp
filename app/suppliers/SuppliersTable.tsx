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
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import type { ExportColumnDef } from '@/app/components/ui/table-export'
import { xText, xTime } from '@/lib/export/cells'
import DeleteButton from './DeleteButton'

export type SupplierTableRow = {
    id: string
    code: string
    legalName: string
    country: string
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

export default function SuppliersTable({
    rows, empty, sort, dir, filterQuery, shown, total, exportHref,
}: {
    rows: SupplierTableRow[]
    empty: React.ReactNode
    sort: string
    dir: 'asc' | 'desc'
    /** 当前筛选参数(不含 sort/dir/page)—— 排序链接要原样带上它们。 */
    filterQuery: Record<string, string>
    shown: number
    total: number
    /** TABLE-EXPORT-1:服务端翻页取全的那条路由(带当前筛选与排序)。 */
    exportHref: string
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
    const columns: ExportableColumn<SupplierTableRow>[] = [
        {
            key: 'code', header: t('suppliers.col.code'), priority: true, sortable: true, className: 'text-sm',
            exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/suppliers/${r.id}/edit`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'legal_name', header: t('suppliers.col.legalName'), priority: true, sortable: true, render: (r) => r.legalName, exportAs: (r) => xText(r.legalName) },
        { key: 'country', header: t('suppliers.col.country'), render: (r) => r.country, exportAs: (r) => xText(r.country) },
        { key: 'types', header: t('suppliers.col.types'), className: 'text-sm', render: (r) => r.types, exportAs: (r) => xText(r.types) },
        {
            key: 'status', header: t('suppliers.col.status'), sortable: true,
            exportAs: (r) => xText(t('suppliers.status.' + r.status)),
            render: (r) => <span className="px-2 py-1 bg-gray-200 rounded text-xs">{t('suppliers.status.' + r.status)}</span>,
        },
        {
            key: 'created_at', header: t('suppliers.col.created'), sortable: true,
            className: 'text-sm text-gray-600', render: (r) => r.createdLabel,
            exportAs: (r) => xTime(r.createdAt),
        },
        {
            key: 'actions', header: t('suppliers.colActions'), exportAs: false,
            render: (r) => <DeleteButton id={r.id} legalName={r.legalName} />,
        },
    ]

    // ★ TABLE-EXPORT-1(Tim 2026-10-22 Q5 / Q11):旧的 CSV 导出(app/suppliers/export/route.ts 从前那一版)
    //   比这张表多六列。它们【声明】成扩展列留在导出里,接在表的列后面;表头用编辑表单上同一句话。
    //   这是唯一的例外 —— 别的表导出的列就是表的列(scripts/check-table-export.mjs 只放这两张)。
    const extension: ExportColumnDef<SupplierTableRow>[] = [
        { key: 'short_name', header: t('suppliers.form.shortName'), exportAs: (r) => xText(r.shortName) },
        { key: 'tax_id', header: t('suppliers.form.taxId'), exportAs: (r) => xText(r.taxId) },
        { key: 'payment_terms', header: t('suppliers.form.paymentTerms'), exportAs: (r) => xText(r.paymentTerms) },
        { key: 'incoterm', header: t('suppliers.form.incoterm'), exportAs: (r) => xText(r.incoterm) },
        { key: 'credit_rating', header: t('suppliers.form.creditRating'), exportAs: (r) => xText(r.creditRating) },
        { key: 'address', header: t('suppliers.form.address'), exportAs: (r) => xText(r.address) },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            sorting={{ mode: 'server', coverage: { shown, total }, active: { key: sort, dir }, href }}
            exportSpec={{ name: 'suppliers', title: t('suppliers.listTitle'), serverRows: exportHref, extension }}
        />
    )
}
