// app/output/page.tsx
// 产出批次列表页:URL 驱动的搜索 / 状态筛选 / 客户筛选 / 物料筛选 / 排序 / 分页。
// 端口自 inbound 列表:supplier→customer、stage→state。customer_id 可空(未售出批次无客户)。
import { Suspense } from 'react'
import { formatTimestamp } from '@/lib/format'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import OutputToolbar, { type PartyOption } from './OutputToolbar'
import { STATE_OPTIONS, labelKeyForValue } from '../inbound/options'
import {
    parseOutputListParams,
    parseOutputPage,
    applyOutputFilters,
    resolveOutputSearchIds,
    buildOutputSearchOr,
    OUTPUT_PAGE_SIZE,
    type OutputSortCol,
} from './outputQuery'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

// FK 嵌入运行时是对象;TS 默认猜数组(无生成 DB 类型),用显式类型 + cast 锁住。
// customers 可空:库存中的批次还没指派客户。
type OutputRow = {
    id: string
    code: string
    quantity: number
    unit: string
    remaining_qty: number
    output_date: string | null
    state: string
    status: string
    created_at: string
    materials: { name: string } | null
    customers: { legal_name: string } | null
}

export default async function OutputPage({
    searchParams,
}: {
    // 本版本 Next 里 searchParams 是 Promise,需要 await
    searchParams: Promise<{
        q?: string
        state?: string
        customer_id?: string
        material_id?: string
        date_from?: string
        date_to?: string
        sort?: string
        dir?: string
        page?: string
    }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.output)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { q, state, customerId, materialId, dateFrom, dateTo, sort, dir } = parseOutputListParams(sp)
    const requestedPage = parseOutputPage(sp.page)
    const filterParams = { q, state, customerId, materialId, dateFrom, dateTo, sort, dir }

    // 跨关联方搜索:先查匹配 q 的物料/客户 id(q 为空时零开销),再拼成本表 FK 列的 OR
    const searchIds = await resolveOutputSearchIds(supabase, q)
    const searchOr = buildOutputSearchOr(q, searchIds)

    // 1) 匹配总数(同样套用过滤 + 搜索;只 select 'id' 不带嵌入 —— 过滤都打在本表列上,无需 join)
    //    + 同时取客户/物料下拉选项(独立查询,并行)。
    const [{ count }, customersRes, materialsRes] = await Promise.all([
        applyOutputFilters(
            supabase.from('output_batches').select('id', { count: 'exact', head: true }),
            filterParams,
            searchOr
        ),
        supabase
            .from('customers')
            .select('id, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('materials')
            .select('id, name')
            .is('deleted_at', null)
            .order('name'),
    ])

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / OUTPUT_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * OUTPUT_PAGE_SIZE
    const to = from + OUTPUT_PAGE_SIZE - 1

    // 2) 取当前页的行:带嵌入的 select(materials/customers 名字用于展示)+ 过滤 + 排序 + .range
    const baseQuery = supabase.from('output_batches').select(`
        id, code, quantity, unit, remaining_qty, output_date, state, status, created_at,
        materials ( name ),
        customers ( legal_name )
    `)

    const { data, error } = await applyOutputFilters(
        baseQuery,
        filterParams,
        searchOr
    ).range(from, to)
    const batches = data as unknown as OutputRow[] | null

    // 下拉选项:客户按 legal_name、物料按 name 作为显示标签
    const customerOptions: PartyOption[] = (mustRows(customersRes)).map((c) => ({
        id: c.id,
        label: c.legal_name,
    }))
    const materialOptions: PartyOption[] = (mustRows(materialsRes)).map((m) => ({
        id: m.id,
        label: m.name,
    }))

    // state 存储值反查成本地化文案;未知值原样显示
    const stateLabel = (value: string) => {
        const key = labelKeyForValue(STATE_OPTIONS, value)
        return key ? t(key) : value
    }

    // 表头排序链接:保留所有筛选,只改 sort/dir;不带 page —— 改排序回到第 1 页。
    function sortHref(col: OutputSortCol) {
        const nextDir = sort === col && dir === 'asc' ? 'desc' : 'asc'
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (state) params.set('state', state)
        if (customerId) params.set('customer_id', customerId)
        if (materialId) params.set('material_id', materialId)
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        params.set('sort', col)
        params.set('dir', nextDir)
        return `/output?${params.toString()}`
    }

    function sortableTh(col: OutputSortCol, label: string) {
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
        if (state) params.set('state', state)
        if (customerId) params.set('customer_id', customerId)
        if (materialId) params.set('material_id', materialId)
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        params.set('sort', sort)
        params.set('dir', dir)
        params.set('page', String(targetPage))
        return `/output?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('output.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('output.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('output.listTitle')}</h1>
                <Link
                    href="/output/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('output.addButton')}
                </Link>
            </div>

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <OutputToolbar customers={customerOptions} materials={materialOptions} />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('output.recordCount', { count: total })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        {sortableTh('code', t('output.colCode'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('output.colMaterial')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('output.colCustomer')}
                        </th>
                        {sortableTh('quantity', t('output.colQuantity'))}
                        {sortableTh('remaining_qty', t('output.colRemaining'))}
                        {sortableTh('output_date', t('output.colOutputDate'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('output.colState')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('output.colStatus')}
                        </th>
                        {sortableTh('created_at', t('output.colCreated'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('output.colActions')}
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
                                    href={`/output/${b.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {b.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{b.materials?.name ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.customers?.legal_name ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.quantity} {b.unit}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.remaining_qty} {b.unit}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.output_date ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {stateLabel(b.state)}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {b.status}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                {formatTimestamp(b.created_at, dateLocale)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <DeleteButton id={b.id} code={b.code} />
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <a
                                    href={`/output/${b.id}/label`}
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
                                colSpan={11}
                                className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                            >
                                {t('output.emptyState')}
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
                        {t('output.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('output.pagination.prev')}
                    </span>
                )}

                <span className="text-sm text-gray-600">
                    {t('output.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('output.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('output.pagination.next')}
                    </span>
                )}
            </div>
        </div>
    )
}
