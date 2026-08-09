// app/materials/page.tsx
// 物料字典列表页:URL 驱动的搜索 / 分类筛选 / 排序 / 分页(全部在服务端完成)。
// 端口自 suppliers 列表,字段适配 materials(分类筛选用 category)。
import { Suspense } from 'react'
import { formatTimestamp } from '@/lib/format'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import MaterialToolbar from './MaterialToolbar'
import {
    CATEGORY_OPTIONS,
    CHEMISTRY_OPTIONS,
    UNIT_OPTIONS,
    labelKeyForValue,
    type MaterialSelectOption,
} from './options'
import {
    parseMaterialListParams,
    parseMaterialPage,
    applyMaterialFilters,
    MATERIAL_PAGE_SIZE,
    type MaterialSortCol,
} from './materialQuery'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function MaterialsPage({
    searchParams,
}: {
    // 本版本 Next 里 searchParams 是 Promise,需要 await
    searchParams: Promise<{
        q?: string
        category?: string
        sort?: string
        dir?: string
        page?: string
    }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.materials)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    // 把存储值反查成本地化文案;自定义自由文本(无 key)原样显示
    const display = (options: MaterialSelectOption[], value: string | null) => {
        const key = labelKeyForValue(options, value)
        return key ? t(key) : value ?? '—'
    }

    // 解析并校验 URL 参数(都给安全默认值)—— 与导出路由共用同一份逻辑
    const { q, category, sort, dir } = parseMaterialListParams(sp)
    const requestedPage = parseMaterialPage(sp.page)
    const filterParams = { q, category, sort, dir }

    // 1) 先取匹配总数(同样套用过滤,所以总页数对当前筛选是准确的)。head:true 只要 count 不要行。
    const { count } = await applyMaterialFilters(
        supabase.from('materials').select('id', { count: 'exact', head: true }),
        filterParams
    )
    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / MATERIAL_PAGE_SIZE))
    // 把页码上钳到总页数(手输过大的 ?page= 时回落到最后一页,而不是空表)
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * MATERIAL_PAGE_SIZE
    const to = from + MATERIAL_PAGE_SIZE - 1

    // 2) 取当前页的行:过滤 + 排序后再 .range(from, to)
    const baseQuery = supabase
        .from('materials')
        .select('id, code, name, category, chemistry, unit, status, created_at')

    const { data: materials, error } = await applyMaterialFilters(
        baseQuery,
        filterParams
    ).range(from, to)

    // 表头排序链接:点当前列翻转方向,点其它列默认升序;保留 q / category。不带 page —— 改排序回到第 1 页。
    function sortHref(col: MaterialSortCol) {
        const nextDir = sort === col && dir === 'asc' ? 'desc' : 'asc'
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (category) params.set('category', category)
        params.set('sort', col)
        params.set('dir', nextDir)
        return `/materials?${params.toString()}`
    }

    function sortableTh(col: MaterialSortCol, label: string) {
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

    // 分页链接:保留当前的 q / category / sort / dir,只改 page
    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (category) params.set('category', category)
        params.set('sort', sort)
        params.set('dir', dir)
        params.set('page', String(targetPage))
        return `/materials?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('materials.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('materials.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('materials.listTitle')}</h1>
                <Link
                    href="/materials/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('materials.addButton')}
                </Link>
            </div>

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <MaterialToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('materials.recordCount', { count: total })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        {sortableTh('code', t('materials.colCode'))}
                        {sortableTh('name', t('materials.colName'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('materials.colCategory')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('materials.colChemistry')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('materials.colUnit')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('materials.colStatus')}
                        </th>
                        {sortableTh('created_at', t('materials.colCreated'))}
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('materials.colActions')}
                        </th>
                    </tr>
                </thead>
                <tbody>
                    {materials?.map((m) => (
                        <tr key={m.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/materials/${m.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {m.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{m.name}</td>
                            <td className="border border-gray-300 px-4 py-2">{display(CATEGORY_OPTIONS, m.category)}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                {m.chemistry ? display(CHEMISTRY_OPTIONS, m.chemistry) : '—'}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{display(UNIT_OPTIONS, m.unit)}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {m.status}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                {formatTimestamp(m.created_at, dateLocale)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <DeleteButton id={m.id} name={m.name} />
                            </td>
                        </tr>
                    ))}
                    {(!materials || materials.length === 0) && (
                        <tr>
                            <td
                                colSpan={8}
                                className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                            >
                                {t('materials.emptyState')}
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
                        {t('materials.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('materials.pagination.prev')}
                    </span>
                )}

                <span className="text-sm text-gray-600">
                    {t('materials.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('materials.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('materials.pagination.next')}
                    </span>
                )}
            </div>
        </div>
    )
}
