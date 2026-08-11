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
import { formatMoneyBare } from '@/lib/format'
import { getTranslations } from '@/lib/i18n/server'
import { can } from '@/lib/permissions'
import { mustOne } from '@/lib/db-helpers'
import ThresholdPanel from './ThresholdPanel'
import type { AnomalyVerdict } from './anomaly'

type MetalPriceRow = {
    id: string
    metal: string
    price_usd_per_tonne: number
    price_date: string
    source: string
    price_index: string | null
    notes: string | null
    // METAL-1:录入那一刻的判词(记录,不事后重算 —— 后来的报价会改变"上一条")
    anomaly_check: AnomalyVerdict | null
    // METAL-3:这一行是【哪个币种】报的 —— SMM 是 CNY/吨,不是 USD/吨。
    // FK 嵌入运行时是对象;显式类型 + cast 锁住(与其他页同一惯例)。
    metal_price_indices: { quote_currency: string | null } | null
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
    // 【本页没有 requireModule,是有意的,不是漏了 —— 不要"补"回来。这是那条规矩的「读」那一半】
    // 规矩只有一条:【守卫跟着数据自己的 RLS 走,不跟模块目录走】。
    // 而一张表的 RLS 本来就有读、写两个答案,metal_prices 的这两个答案【不一样】——
    // 所以 app/metal-prices/ 底下四页带着两种守卫,那是【同一条规则的两半,不是例外】:
    //
    //   读(列表页 /metal-prices)  SELECT ... USING (true)
    //                             → 不设守卫
    //   写(new / bulk / [id]/edit) INSERT|UPDATE|DELETE ... has_permission('module.pricing.edit')
    //                             → requireEditPermission('module.pricing.edit', ...)
    //
    // (策略原文见 db/tables/metal_prices.sql;完整理由见 lib/modules.ts 的 /pricing 那一条。)
    //
    // 看行情人人可以:行情是市场报价,数据自己声明它是公开的。给本页挂 module.pricing.view
    // 会让 UI 比数据库还严 —— 对一个数据库愿意完整回答的人显示"你没有权限",而那道门
    // 数据库里根本不存在。目录的措辞不是策略:module.pricing.view 那一条写着"公式、计价器
    // 与行情",两者冲突时以策略为准。要改回去,先改 metal_prices 的 SELECT 策略,再改
    // 这里,顺序不能反。/pricing 本身仍然受管 —— 公式与商务条款不是公开数据。

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
        .select('id, metal, price_usd_per_tonne, price_date, source, price_index, notes, anomaly_check, metal_price_indices ( quote_currency )')

    const { data, error } = await applyMetalPricesFilters(baseQuery, filterParams).range(
        from,
        to
    )
    const rows = data as unknown as MetalPriceRow[] | null

    // METAL-1:阈值(人人可读)+ 能不能改(module.pricing.edit,与 RLS 同码)。
    // mustOne:引导必须给出这一行,读不到要炸,不能当成"没有配置"悄悄过去。
    const settingsRes = await supabase
        .from('pricing_settings')
        .select('metal_price_change_warn_pct, notes')
        .eq('id', true)
        .maybeSingle()
    const settings = mustOne(settingsRes, 'pricing_settings')
    if (!settings) {
        // 引导必须给出这一行。读不到就【说出来】—— 一块显示不出阈值的提示面板
        // 与"没有异常"在屏幕上是同一样东西,而 metal_price_anomaly 那一侧也会
        // 以 PRICING_SETTINGS_MISSING 拒答。
        throw new Error('pricing_settings 引导行缺失:异常提示的阈值读不到')
    }
    const canEditPrices = await can('module.pricing.edit')

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
                <div className="flex gap-3">
                    <Link
                        href="/metal-prices/bulk"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('metalPrices.bulk.entry')}
                    </Link>
                    <Link
                        href="/metal-prices/new"
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                    >
                        {t('metalPrices.addButton')}
                    </Link>
                </div>
            </div>

            <ThresholdPanel
                thresholdPct={Number(settings.metal_price_change_warn_pct)}
                notes={settings.notes}
                canEdit={canEditPrices}
            />

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
                        {/* METAL-3:列头不再写死 USD —— SMM 按 CNY/吨发布,
                            一个写着 (USD/t) 的列头对那些行就是一句谎话
                            (FIN-18 的 jsx-text 教训:最直接的说谎方式是正文)。
                            币种跟着每一行走,见下面的单元格。 */}
                        {sortableTh('price_usd_per_tonne', t('metalPrices.colPricePerTonne'))}
                        {sortableTh('price_date', t('metalPrices.colPriceDate'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('metalPrices.colIndex')}
                        </th>
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
                                {formatMoneyBare(r.price_usd_per_tonne, '同格内紧跟着币种,见下一行')}
                                {/* 【数字自己带币种】—— 未标注指数的老行按 USD 记
                                    (那条序列一直是 USD),所以回退到报价基准。 */}
                                <span className="ml-1 text-xs text-gray-500">
                                    {r.metal_price_indices?.quote_currency ?? t('metalPrices.index.quoteBasisFallback')}
                                </span>
                                {/* METAL-1:录入那一刻的判词。outside 挂琥珀徽标;
                                    no_reference 挂灰色 —— 【它不是"检查通过"】,
                                    是"这个金属当时没有别的报价可比"。两者必须
                                    在屏幕上就分得开,否则第三种判词等于没有。 */}
                                {r.anomaly_check?.verdict === 'outside' && (
                                    <span
                                        title={t('metalPrices.anomaly.badgeTitle', {
                                            change: r.anomaly_check.change_pct ?? 0,
                                            refPrice: r.anomaly_check.reference_price ?? 0,
                                            refDate: r.anomaly_check.reference_date ?? '',
                                        })}
                                        className="ml-2 inline-block align-middle bg-amber-100 text-amber-800 border border-amber-300 rounded px-1.5 py-0.5 text-xs font-sans"
                                    >
                                        {t('metalPrices.anomaly.badge')}
                                    </span>
                                )}
                                {/* 【判词为空 = 这一行录入时还没有这项检查】(线上 11 行
                                    全是这样)。不画任何徽标会让它与"查过、没问题"
                                    在屏幕上一模一样 —— 那正是本刀要拆掉的读法,
                                    所以它有自己的、更安静的一个。FIN-26 的同一条:
                                    旧行留空,而空要显示成"不知道",不是"没问题"。 */}
                                {!r.anomaly_check && (
                                    <span
                                        title={t('metalPrices.anomaly.legacyTitle')}
                                        className="ml-2 inline-block align-middle bg-gray-50 text-gray-400 border border-gray-200 rounded px-1.5 py-0.5 text-xs font-sans"
                                    >
                                        {t('metalPrices.anomaly.legacyBadge')}
                                    </span>
                                )}
                                {r.anomaly_check?.verdict === 'no_reference' && (
                                    <span
                                        title={t('metalPrices.anomaly.noReferenceTitle')}
                                        className="ml-2 inline-block align-middle bg-gray-100 text-gray-600 border border-gray-300 rounded px-1.5 py-0.5 text-xs font-sans"
                                    >
                                        {t('metalPrices.anomaly.noReferenceBadge')}
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{r.price_date}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {/* 【空白会读成"没填",而它是一个状态】未标注指数的行
                                    要说出来 —— 它是既有 11 行所在的那条序列。 */}
                                {r.price_index ?? (
                                    <span className="text-gray-400">{t('metalPrices.index.unstatedShort')}</span>
                                )}
                            </td>
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
