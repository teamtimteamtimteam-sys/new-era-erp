// app/suppliers/page.tsx
// 供应商列表页:URL 驱动的搜索 / 状态筛选 / 排序(全部在服务端的 Supabase 查询里完成)
import { Suspense } from 'react'
import { formatTimestamp } from '@/lib/format'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import SupplierToolbar from './SupplierToolbar'
import {
    parseSupplierListParams,
    parseSupplierPage,
    applySupplierFilters,
    SUPPLIER_PAGE_SIZE,
    type SupplierSortCol,
} from './supplierQuery'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function SuppliersPage({
    searchParams,
}: {
    // 本版本 Next 里 searchParams 是 Promise,需要 await
    searchParams: Promise<{
        q?: string
        status?: string
        sort?: string
        dir?: string
        page?: string
    }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.suppliers)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    // 解析并校验 URL 参数(都给安全默认值)—— 与导出路由共用同一份逻辑
    const { q, status, sort, dir } = parseSupplierListParams(sp)
    const requestedPage = parseSupplierPage(sp.page)
    const filterParams = { q, status, sort, dir }

    // 1) 先取匹配总数(同样套用过滤,所以总页数对当前筛选是准确的)。head:true 只要 count 不要行。
    const { count } = await applySupplierFilters(
        supabase.from('suppliers').select('id', { count: 'exact', head: true }).neq('counterparty_type', 'forwarder'),
        filterParams
    )
    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / SUPPLIER_PAGE_SIZE))
    // 把页码上钳到总页数(手输过大的 ?page= 时回落到最后一页,而不是空表)
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * SUPPLIER_PAGE_SIZE
    const to = from + SUPPLIER_PAGE_SIZE - 1

    // 2) 取当前页的行:过滤 + 排序后再 .range(from, to)
    const baseQuery = supabase
        .from('suppliers')
        .select(
            'id, code, legal_name, short_name, country, supplier_types, status, tax_id, created_at'
        )
        // LOG-1b:货代不进供应商名单(他们保留 supplier id 只为账上那条链)
        .neq('counterparty_type', 'forwarder')

    const { data: suppliers, error } = await applySupplierFilters(
        baseQuery,
        filterParams
    ).range(from, to)

    // 表头排序链接:点当前列翻转方向,点其它列默认升序;保留 q / status。
    // 不带 page —— 改变排序时回到第 1 页。
    function sortHref(col: SupplierSortCol) {
        const nextDir = sort === col && dir === 'asc' ? 'desc' : 'asc'
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (status) params.set('status', status)
        params.set('sort', col)
        params.set('dir', nextDir)
        return `/suppliers?${params.toString()}`
    }

    // 分页链接:保留当前的 q / status / sort / dir,只改 page
    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (status) params.set('status', status)
        params.set('sort', sort)
        params.set('dir', dir)
        params.set('page', String(targetPage))
        return `/suppliers?${params.toString()}`
    }

    function sortableTh(col: SupplierSortCol, label: string) {
        const indicator = sort === col ? (dir === 'asc' ? ' ▲' : ' ▼') : ''
        return (
            <th className="border border-gray-300 px-4 py-2 text-left">
                <Link href={sortHref(col)} className="hover:underline">
                    {label}
                    {indicator}
                </Link>
            </th>
        )
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('suppliers.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('suppliers.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('suppliers.listTitle')}</h1>
                <div className="flex items-center gap-3">
                    {/* ★【CONTRACT-1:合同登记簿的入口 —— 那一页建好时【没有任何入口】★
                        照 PARTY-1 的做法办,理由也一样:本仓库为「页面上线却走不到」
                        付过两次账(SAL-B6、FIX-1),而 --reach 查得到静态路由,
                        只是它要跑两小时。所以这条链接与那一页在同一刀里补上,
                        并配一条冒烟可达性探针(scripts/smoke-routes.mjs 里在
                        /suppliers 的 HTML 里找 /contracts)—— 把"我记得加了链接"
                        换成机制。入口放在供应商名单上,因为"这家的货是不是背靠
                        一份长期协议"正是在看供应商名单时才会冒出来的问题。 */}
                    <Link href="/contracts" className="text-sm text-blue-600 hover:underline">
                        {t('contracts.entryLink')}
                    </Link>
                    <Link
                        href="/suppliers/new"
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                    >
                        {t('suppliers.addButton')}
                    </Link>
                </div>
            </div>

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <SupplierToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('suppliers.recordCount', { count: total })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        {sortableTh('code', t('suppliers.col.code'))}
                        {sortableTh('legal_name', t('suppliers.col.legalName'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('suppliers.col.country')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('suppliers.col.types')}
                        </th>
                        {sortableTh('status', t('suppliers.col.status'))}
                        {sortableTh('created_at', t('suppliers.col.created'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('suppliers.colActions')}
                        </th>
                    </tr>
                </thead>
                <tbody>
                    {suppliers?.map((s) => (
                        <tr key={s.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/suppliers/${s.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {s.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{s.legal_name}</td>
                            <td className="border border-gray-300 px-4 py-2">{s.country}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {s.supplier_types?.join(', ')}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {t('suppliers.status.' + s.status)}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                {formatTimestamp(s.created_at, dateLocale)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <DeleteButton id={s.id} legalName={s.legal_name} />
                            </td>
                        </tr>
                    ))}
                    {(!suppliers || suppliers.length === 0) && (
                        <tr>
                            <td
                                colSpan={7}
                                className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                            >
                                {t('suppliers.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>

            {/* 分页控件:服务端 <Link>,无额外客户端 JS;首页禁用上一页、末页禁用下一页 */}
            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Link
                        href={pageHref(page - 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('suppliers.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('suppliers.pagination.prev')}
                    </span>
                )}

                <span className="text-sm text-gray-600">
                    {t('suppliers.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('suppliers.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('suppliers.pagination.next')}
                    </span>
                )}
            </div>
        </div>
    )
}
