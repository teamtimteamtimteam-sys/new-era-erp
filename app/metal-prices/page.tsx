// app/metal-prices/page.tsx
// 金属价格列表页:URL 驱动的金属筛选 / 排序 / 分页。
// 端口自 inbound 列表,精简为单表参考表:无搜索、无导出、无关联方下拉。
import { Suspense } from 'react'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import MetalPricesToolbar from './MetalPricesToolbar'
import { metalLabelKey } from './options'
import {
    parseMetalPricesListParams,
    parseMetalPricesPage,
    applyMetalPricesFilters,
    METAL_PRICES_PAGE_SIZE,
    type MetalPricesSortCol,
} from './metalPricesQuery'
import { formatUsd } from '@/lib/format'
import { getTranslations } from '@/lib/i18n/server'

type MetalPriceRow = {
    id: string
    metal: string
    price_usd_per_tonne: number
    price_date: string
    source: string
    notes: string | null
}

export default async function MetalPricesPage({
    searchParams,
}: {
    searchParams: Promise<{
        metal?: string
        sort?: string
        dir?: string
        page?: string
    }>
}) {
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const { metal, sort, dir } = parseMetalPricesListParams(sp)
    const requestedPage = parseMetalPricesPage(sp.page)
    const filterParams = { metal, sort, dir }

    // 1) 匹配总数(套用同一套过滤,只 select 'id')
    const { count } = await applyMetalPricesFilters(
        supabase.from('metal_prices').select('id', { count: 'exact', head: true }),
        filterParams
    )

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / METAL_PRICES_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * METAL_PRICES_PAGE_SIZE
    const to = from + METAL_PRICES_PAGE_SIZE - 1

    // 2) 取当前页的行
    const baseQuery = supabase
        .from('metal_prices')
        .select('id, metal, price_usd_per_tonne, price_date, source, notes')

    const { data, error } = await applyMetalPricesFilters(baseQuery, filterParams).range(
        from,
        to
    )
    const rows = data as unknown as MetalPriceRow[] | null

    // metal 存储值反查成本地化文案;未知值原样显示
    const metalLabel = (value: string) => {
        const key = metalLabelKey(value)
        return key ? t(key) : value
    }

    // 表头排序链接:保留金属筛选,只改 sort/dir;不带 page —— 改排序回到第 1 页。
    function sortHref(col: MetalPricesSortCol) {
        const nextDir = sort === col && dir === 'asc' ? 'desc' : 'asc'
        const params = new URLSearchParams()
        if (metal) params.set('metal', metal)
        params.set('sort', col)
        params.set('dir', nextDir)
        return `/metal-prices?${params.toString()}`
    }

    function sortableTh(col: MetalPricesSortCol, label: string) {
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

    // 分页链接:保留金属筛选 + sort/dir,只改 page
    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (metal) params.set('metal', metal)
        params.set('sort', sort)
        params.set('dir', dir)
        params.set('page', String(targetPage))
        return `/metal-prices?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('metalPrices.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('metalPrices.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('metalPrices.listTitle')}</h1>
                <Link
                    href="/metal-prices/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('metalPrices.addButton')}
                </Link>
            </div>

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <MetalPricesToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('metalPrices.recordCount', { count: total })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        {sortableTh('metal', t('metalPrices.colMetal'))}
                        {sortableTh('price_usd_per_tonne', t('metalPrices.colPrice'))}
                        {sortableTh('price_date', t('metalPrices.colPriceDate'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('metalPrices.colSource')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('metalPrices.colNotes')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('metalPrices.colActions')}
                        </th>
                    </tr>
                </thead>
                <tbody>
                    {rows?.map((r) => (
                        <tr key={r.id}>
                            <td className="border border-gray-300 px-4 py-2">{metalLabel(r.metal)}</td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {formatUsd(r.price_usd_per_tonne)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{r.price_date}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">{r.source}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">{r.notes ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                <Link
                                    href={`/metal-prices/${r.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {t('metalPrices.editAction')}
                                </Link>
                            </td>
                        </tr>
                    ))}
                    {(!rows || rows.length === 0) && (
                        <tr>
                            <td
                                colSpan={6}
                                className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                            >
                                {t('metalPrices.emptyState')}
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
                        {t('metalPrices.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('metalPrices.pagination.prev')}
                    </span>
                )}

                <span className="text-sm text-gray-600">
                    {t('metalPrices.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('metalPrices.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('metalPrices.pagination.next')}
                    </span>
                )}
            </div>
        </div>
    )
}
