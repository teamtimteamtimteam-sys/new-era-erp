// app/customers/page.tsx
// 客户列表页:URL 驱动的搜索 / 排序 / 分页(全部在服务端的 Supabase 查询里完成)。
// 端口自 suppliers 列表,去掉状态筛选(客户没有状态机)。
import { Suspense } from 'react'
import { formatTimestamp } from '@/lib/format'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import CustomerToolbar from './CustomerToolbar'
import {
    parseCustomerListParams,
    parseCustomerPage,
    applyCustomerFilters,
    CUSTOMER_PAGE_SIZE,
    type CustomerSortCol,
} from './customerQuery'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function CustomersPage({
    searchParams,
}: {
    // 本版本 Next 里 searchParams 是 Promise,需要 await
    searchParams: Promise<{
        q?: string
        sort?: string
        dir?: string
        page?: string
    }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.customers)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    // 解析并校验 URL 参数(都给安全默认值)—— 与导出路由共用同一份逻辑
    const { q, sort, dir } = parseCustomerListParams(sp)
    const requestedPage = parseCustomerPage(sp.page)
    const filterParams = { q, sort, dir }

    // 1) 先取匹配总数(同样套用过滤,所以总页数对当前搜索是准确的)。head:true 只要 count 不要行。
    const { count } = await applyCustomerFilters(
        supabase.from('customers').select('id', { count: 'exact', head: true }),
        filterParams
    )
    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / CUSTOMER_PAGE_SIZE))
    // 把页码上钳到总页数(手输过大的 ?page= 时回落到最后一页,而不是空表)
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * CUSTOMER_PAGE_SIZE
    const to = from + CUSTOMER_PAGE_SIZE - 1

    // 2) 取当前页的行:过滤 + 排序后再 .range(from, to)
    const baseQuery = supabase
        .from('customers')
        .select('id, code, legal_name, country, contact_person, email, customer_types, status, created_at')

    const { data: customers, error } = await applyCustomerFilters(
        baseQuery,
        filterParams
    ).range(from, to)

    // 表头排序链接:点当前列翻转方向,点其它列默认升序;保留 q。不带 page —— 改排序回到第 1 页。
    function sortHref(col: CustomerSortCol) {
        const nextDir = sort === col && dir === 'asc' ? 'desc' : 'asc'
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        params.set('sort', col)
        params.set('dir', nextDir)
        return `/customers?${params.toString()}`
    }

    function sortableTh(col: CustomerSortCol, label: string) {
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

    // 分页链接:保留当前的 q / sort / dir,只改 page
    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        params.set('sort', sort)
        params.set('dir', dir)
        params.set('page', String(targetPage))
        return `/customers?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('customers.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('customers.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('customers.listTitle')}</h1>
                <Link
                    href="/customers/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('customers.addButton')}
                </Link>
            </div>

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <CustomerToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('customers.recordCount', { count: total })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        {sortableTh('code', t('customers.col.code'))}
                        {sortableTh('legal_name', t('customers.col.legalName'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('customers.col.country')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('customers.col.contactPerson')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('customers.col.email')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('customers.col.types')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('customers.col.status')}
                        </th>
                        {sortableTh('created_at', t('customers.col.created'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('customers.colActions')}
                        </th>
                    </tr>
                </thead>
                <tbody>
                    {customers?.map((c) => (
                        <tr key={c.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/customers/${c.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {c.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{c.legal_name}</td>
                            <td className="border border-gray-300 px-4 py-2">{c.country}</td>
                            {/* 电话不上列表(列已经够多);联系人 + 邮箱是找人时最常看的两项 */}
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {c.contact_person ?? '—'}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm break-all">
                                {c.email ?? '—'}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {c.customer_types?.join(', ')}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {c.status}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                {formatTimestamp(c.created_at, dateLocale)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <DeleteButton id={c.id} legalName={c.legal_name} />
                            </td>
                        </tr>
                    ))}
                    {(!customers || customers.length === 0) && (
                        <tr>
                            <td
                                colSpan={9}
                                className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                            >
                                {t('customers.emptyState')}
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
                        {t('customers.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('customers.pagination.prev')}
                    </span>
                )}

                <span className="text-sm text-gray-600">
                    {t('customers.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('customers.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('customers.pagination.next')}
                    </span>
                )}
            </div>
        </div>
    )
}
