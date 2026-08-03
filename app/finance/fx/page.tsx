// app/finance/fx/page.tsx
// 汇率列表页(端口自 metal-prices):币种筛选 / 排序 / 分页 / 编辑入口。
import { Suspense } from 'react'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import Subnav from '../Subnav'
import FxToolbar from './FxToolbar'
import {
    parseFxListParams,
    parseFxPage,
    applyFxFilters,
    FX_PAGE_SIZE,
    type FxSortCol,
} from './fxQuery'
import { getTranslations } from '@/lib/i18n/server'

type FxRow = {
    id: string
    currency: string
    rate_type: string
    rate_sgd_per_unit: number
    rate_date: string
    source: string
    notes: string | null
}

export default async function FxRatesPage({
    searchParams,
}: {
    searchParams: Promise<{
        currency?: string
        sort?: string
        dir?: string
        page?: string
    }>
}) {
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const { currency, sort, dir } = parseFxListParams(sp)
    const requestedPage = parseFxPage(sp.page)
    const filterParams = { currency, sort, dir }

    // 1) 匹配总数 + 可选币种(非 SGD;并行)
    const [{ count }, currenciesRes] = await Promise.all([
        applyFxFilters(
            supabase.from('fx_rates').select('id', { count: 'exact', head: true }),
            filterParams
        ),
        supabase.from('currencies').select('code').neq('code', 'SGD').order('code'),
    ])

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / FX_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * FX_PAGE_SIZE
    const to = from + FX_PAGE_SIZE - 1

    // 2) 取当前页的行
    const { data, error } = await applyFxFilters(
        supabase.from('fx_rates').select('id, currency, rate_type, rate_sgd_per_unit, rate_date, source, notes'),
        filterParams
    ).range(from, to)
    const rows = data as unknown as FxRow[] | null
    const currencyOptions = (currenciesRes.data ?? []).map((c) => c.code)

    // 缺牌价的日子:有外币过账、当天缺任一侧牌价 —— 牌价是日课,漏一天可能永远补不回
    const { data: gapRows } = await supabase
        .from('fx_rate_gaps')
        .select('rate_date, currency, missing_types, txn_count')
        .order('rate_date', { ascending: false })
        .limit(30)
    const gaps = (gapRows ?? []) as unknown as {
        rate_date: string
        currency: string
        missing_types: string[]
        txn_count: number
    }[]

    function sortHref(col: FxSortCol) {
        const nextDir = sort === col && dir === 'asc' ? 'desc' : 'asc'
        const params = new URLSearchParams()
        if (currency) params.set('currency', currency)
        params.set('sort', col)
        params.set('dir', nextDir)
        return `/finance/fx?${params.toString()}`
    }

    function sortableTh(col: FxSortCol, label: string) {
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

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (currency) params.set('currency', currency)
        params.set('sort', sort)
        params.set('dir', dir)
        params.set('page', String(targetPage))
        return `/finance/fx?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.fxTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.fxPage.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('finance.fxTitle')}</h1>
                <Link
                    href="/finance/fx/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('finance.fxPage.addButton')}
                </Link>
            </div>

            <Subnav />

            {/* 缺牌价 = 有外币交易的那天没录当日牌价 —— 点名到日、到币、到缺哪侧 */}
            {gaps.length > 0 && (
                <div className="mb-4 rounded border border-amber-300 bg-amber-50 px-4 py-3 text-amber-900">
                    <p className="font-medium mb-1">{t('finance.fxPage.gapsTitle', { n: gaps.length })}</p>
                    <ul className="text-sm space-y-0.5">
                        {gaps.map((g) => (
                            <li key={g.rate_date + g.currency}>
                                <span className="font-mono">{g.rate_date}</span> · {g.currency} ·{' '}
                                {t('finance.fxPage.gapsMissing', { 0: g.missing_types.join(', '), 1: g.txn_count })}
                            </li>
                        ))}
                    </ul>
                </div>
            )}

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <FxToolbar currencies={currencyOptions} />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('finance.fxPage.recordCount', { count: total })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        {sortableTh('currency', t('finance.fxPage.colCurrency'))}
                        {sortableTh('rate_type', t('finance.fxPage.colType'))}
                        {sortableTh('rate_sgd_per_unit', t('finance.fxPage.colRate'))}
                        {sortableTh('rate_date', t('finance.fxPage.colRateDate'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('finance.fxPage.colSource')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('finance.fxPage.colNotes')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('finance.fxPage.colActions')}
                        </th>
                    </tr>
                </thead>
                <tbody>
                    {rows?.map((r) => (
                        <tr key={r.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">{r.currency}</td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {t('finance.fxPage.rateType.' + r.rate_type)}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                {r.rate_sgd_per_unit}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{r.rate_date}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">{r.source}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">{r.notes ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                <Link
                                    href={`/finance/fx/${r.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {t('finance.fxPage.editAction')}
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
                                {t('finance.fxPage.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>

            {/* 分页控件:服务端 <Link>;首页禁用上一页、末页禁用下一页 */}
            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Link
                        href={pageHref(page - 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('finance.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('finance.pagination.prev')}
                    </span>
                )}

                <span className="text-sm text-gray-600">
                    {t('finance.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('finance.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('finance.pagination.next')}
                    </span>
                )}
            </div>
        </div>
    )
}
