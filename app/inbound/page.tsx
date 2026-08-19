// app/inbound/page.tsx
// 进料批次列表页:URL 驱动的搜索 / 阶段筛选 / 供应商筛选 / 物料筛选 / 排序 / 分页。
// 端口自 materials 列表,适配事务表:关联方(供应商/物料)用 FK-id 下拉,嵌入仅用于展示。
import { Suspense } from 'react'
import { formatTimestamp } from '@/lib/format'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import InboundToolbar, { type PartyOption } from './InboundToolbar'
import { STAGE_OPTIONS, labelKeyForValue } from './options'
import {
    parseInboundListParams,
    parseInboundPage,
    applyInboundFilters,
    resolveInboundSearchIds,
    buildInboundSearchOr,
    INBOUND_PAGE_SIZE,
    type InboundSortCol,
} from './inboundQuery'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import StockWarningBanner from '@/app/components/inventory/StockWarningBanner'
import { mustCount, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

// FK 嵌入运行时是对象;TS 默认猜数组(无生成 DB 类型),用显式类型 + cast 锁住。
type InboundRow = {
    id: string
    code: string
    quantity: number
    unit: string
    remaining_qty: number
    arrival_date: string | null
    stage: string
    status: string
    pricing_status: string
    created_at: string
    materials: { name: string } | null
    suppliers: { legal_name: string } | null
}

export default async function InboundPage({
    searchParams,
}: {
    // 本版本 Next 里 searchParams 是 Promise,需要 await
    searchParams: Promise<{
        q?: string
        stage?: string
        supplier_id?: string
        material_id?: string
        date_from?: string
        date_to?: string
        pricing_status?: string
        sort?: string
        dir?: string
        page?: string
        warn?: string
    }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.inbound)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { q, stage, supplierId, materialId, dateFrom, dateTo, pricingStatus, sort, dir } =
        parseInboundListParams(sp)
    const requestedPage = parseInboundPage(sp.page)
    const filterParams = { q, stage, supplierId, materialId, dateFrom, dateTo, pricingStatus, sort, dir }

    // 跨关联方搜索:先查匹配 q 的物料/供应商 id(q 为空时零开销),再拼成本表 FK 列的 OR
    const searchIds = await resolveInboundSearchIds(supabase, q)
    const searchOr = buildInboundSearchOr(q, searchIds)

    // 1) 匹配总数(同样套用过滤 + 搜索;只 select 'id' 不带嵌入 —— 过滤都打在本表列上,无需 join)
    //    + 同时取供应商/物料下拉选项(独立查询,并行)。
    const [{ count }, suppliersRes, materialsRes, unpricedRes] = await Promise.all([
        applyInboundFilters(
            supabase.from('inbound_batches').select('id', { count: 'exact', head: true }),
            filterParams,
            searchOr
        ),
        supabase
            .from('suppliers')
            .select('id, legal_name')
            .is('deleted_at', null)
            // LOG-1b:货代不进供应商名单(他们保留 supplier id 只为账上那条链)
            .neq('counterparty_type', 'forwarder')
            .order('legal_name'),
        supabase
            .from('materials')
            .select('id, name')
            .is('deleted_at', null)
            .order('name'),
        // 未计价的在册批次数(cut 1 估值缺口提示;不做筛选入口,仅提示)
        supabase
            .from('inbound_batches_masked')
            .select('id', { count: 'exact', head: true })
            .is('deleted_at', null)
            .is('unit_price', null),
    ])

    // 定价状态计数(cut 5b):等化验的批次 = 还没算对的钱,列表顶上要看得见
    const [unpricedStatusRes, provisionalRes] = await Promise.all([
        supabase
            .from('inbound_batches')
            .select('id', { count: 'exact', head: true })
            .is('deleted_at', null)
            .eq('pricing_status', 'unpriced'),
        supabase
            .from('inbound_batches')
            .select('id', { count: 'exact', head: true })
            .is('deleted_at', null)
            .eq('pricing_status', 'provisional'),
    ])

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / INBOUND_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * INBOUND_PAGE_SIZE
    const to = from + INBOUND_PAGE_SIZE - 1

    // 2) 取当前页的行:带嵌入的 select(materials/suppliers 名字用于展示)+ 过滤 + 排序 + .range
    const baseQuery = supabase.from('inbound_batches').select(`
        id, code, quantity, unit, remaining_qty, arrival_date, stage, status, pricing_status, created_at,
        materials ( name ),
        suppliers ( legal_name )
    `)

    const { data, error } = await applyInboundFilters(
        baseQuery,
        filterParams,
        searchOr
    ).range(from, to)
    const batches = data as unknown as InboundRow[] | null

    // 本页各批次是否有"已记录未应用"的化验(cut 5b);只查当前页的 id —— 同
    // 采购单详情页取已抵扣额的做法
    const pageIds = (batches ?? []).map((b) => b.id)
    const { data: assayStatusRows } = pageIds.length
        ? await supabase
              .from('batch_assay_status')
              .select('inbound_batch_id, has_unapplied_assay')
              .in('inbound_batch_id', pageIds)
        : { data: [] as { inbound_batch_id: string | null; has_unapplied_assay: boolean | null }[] }
    const unappliedByBatch = new Set(
        (assayStatusRows ?? [])
            .filter((r) => r.has_unapplied_assay)
            .map((r) => r.inbound_batch_id ?? '')
    )

    // 下拉选项:供应商按 legal_name、物料按 name 作为显示标签
    const supplierOptions: PartyOption[] = (mustRows(suppliersRes)).map((s) => ({
        id: s.id,
        label: s.legal_name,
    }))
    const materialOptions: PartyOption[] = (mustRows(materialsRes)).map((m) => ({
        id: m.id,
        label: m.name,
    }))

    // stage 存储值反查成本地化文案;未知值原样显示
    const stageLabel = (value: string) => {
        const key = labelKeyForValue(STAGE_OPTIONS, value)
        return key ? t(key) : value
    }

    // 表头排序链接:保留所有筛选,只改 sort/dir;不带 page —— 改排序回到第 1 页。
    function sortHref(col: InboundSortCol) {
        const nextDir = sort === col && dir === 'asc' ? 'desc' : 'asc'
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (stage) params.set('stage', stage)
        if (supplierId) params.set('supplier_id', supplierId)
        if (materialId) params.set('material_id', materialId)
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        if (pricingStatus) params.set('pricing_status', pricingStatus)
        params.set('sort', col)
        params.set('dir', nextDir)
        return `/inbound?${params.toString()}`
    }

    function sortableTh(col: InboundSortCol, label: string) {
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

    // 分页链接:保留所有筛选 + sort/dir,只改 page
    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (stage) params.set('stage', stage)
        if (supplierId) params.set('supplier_id', supplierId)
        if (materialId) params.set('material_id', materialId)
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        if (pricingStatus) params.set('pricing_status', pricingStatus)
        params.set('sort', sort)
        params.set('dir', dir)
        params.set('page', String(targetPage))
        return `/inbound?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('inbound.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('inbound.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            {/* IOD-2:刚刚那次收货的落地告警(建批次成功、但有决定没人做过) */}
            <StockWarningBanner warn={sp.warn} />
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('inbound.listTitle')}</h1>
                {/* FIX-1:这两个钮原本是 sm:hidden / hidden sm:inline-block ——
                    【互斥】的:桌面上现场收货那条路根本不出现,手机上完整录入
                    那条不出现。于是"从采购单收货"在桌面浏览器里没有任何入口,
                    而 --reach 也看不见:两个 <a> 都在 HTML 里,只是被 CSS 藏了。
                    可达性走查读的是标记,人读的是屏幕 —— 这是那道检查的盲区,
                    与 [id] 动态路由那条并列。现在两条路一直都在,并用下面那一行
                    说出它们的区别(而不是让人靠钮的名字猜)。 */}
                <div className="flex items-center gap-2">
                    <Link
                        href="/inbound/receive"
                        className="border border-blue-600 text-blue-600 px-4 py-2 rounded hover:bg-blue-50"
                    >
                        {t('receive.entry')}
                    </Link>
                    <Link
                        href="/inbound/new"
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                    >
                        {t('inbound.addButton')}
                    </Link>
                </div>
            </div>
            <p className="text-sm text-gray-500 mb-4">{t('inbound.twoPathsHint')}</p>

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <InboundToolbar suppliers={supplierOptions} materials={materialOptions} />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('inbound.recordCount', { count: total })}
                {(mustCount(unpricedRes)) > 0 && (
                    <span className="ml-2 text-gray-400">
                        {t('inbound.unpricedBadge', { n: mustCount(unpricedRes) })}
                    </span>
                )}
                {/* 等化验/暂定价的批次数(cut 5b):这些批次的应付金额还不是最终数 */}
                {((mustCount(unpricedStatusRes)) > 0 || (mustCount(provisionalRes)) > 0) && (
                    <span className="ml-2 text-gray-400">
                        {t('assay.awaitingFinal', {
                            unpriced: mustCount(unpricedStatusRes),
                            provisional: mustCount(provisionalRes),
                        })}
                    </span>
                )}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        {sortableTh('code', t('inbound.colCode'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('inbound.colMaterial')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('inbound.colSupplier')}
                        </th>
                        {sortableTh('quantity', t('inbound.colQuantity'))}
                        {sortableTh('remaining_qty', t('inbound.colRemaining'))}
                        {sortableTh('arrival_date', t('inbound.colArrivalDate'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('inbound.colStage')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('inbound.colStatus')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('assay.colPricingStatus')}
                        </th>
                        {sortableTh('created_at', t('inbound.colCreated'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('inbound.colActions')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('batchLabel.col')}
                        </th>
                    </tr>
                </thead>
                <tbody>
                    {batches?.map((b) => (
                        <tr key={b.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/inbound/${b.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {b.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{b.materials?.name ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.suppliers?.legal_name ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.quantity} {b.unit}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.remaining_qty} {b.unit}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.arrival_date ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {stageLabel(b.stage)}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {b.status}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 whitespace-nowrap">
                                <span
                                    className={
                                        'px-2 py-1 rounded text-xs ' +
                                        (b.pricing_status === 'final'
                                            ? 'bg-green-100 text-green-800'
                                            : b.pricing_status === 'provisional'
                                              ? 'bg-amber-100 text-amber-800'
                                              : 'bg-gray-200 text-gray-600')
                                    }
                                >
                                    {t('assay.pricingStatus.' + b.pricing_status)}
                                </span>
                                {/* 已记录未应用的化验:价格还停在旧含量上 */}
                                {unappliedByBatch.has(b.id) && (
                                    <span
                                        title={t('assay.hasUnappliedMarker')}
                                        className="ml-1 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800"
                                    >
                                        ⚠
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                {formatTimestamp(b.created_at, dateLocale)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <DeleteButton id={b.id} code={b.code} />
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <a
                                    href={`/inbound/${b.id}/label`}
                                    target="_blank"
                                    rel="noopener noreferrer"
                                    className="text-blue-600 hover:underline text-sm"
                                >
                                    {t('batchLabel.col')}
                                </a>
                            </td>
                        </tr>
                    ))}
                    {(!batches || batches.length === 0) && (
                        <tr>
                            <td
                                colSpan={12}
                                className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                            >
                                {t('inbound.emptyState')}
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
                        {t('inbound.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('inbound.pagination.prev')}
                    </span>
                )}

                <span className="text-sm text-gray-600">
                    {t('inbound.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('inbound.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('inbound.pagination.next')}
                    </span>
                )}
            </div>
        </div>
    )
}
