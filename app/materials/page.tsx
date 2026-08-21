// app/materials/page.tsx
// 物料字典列表页:URL 驱动的搜索 / 分类筛选 / 排序 / 分页(全部在服务端完成)。
// 端口自 suppliers 列表,字段适配 materials(种类筛选用 kind_code — PROC-1)。
import { Suspense } from 'react'
import { formatTimestamp } from '@/lib/format'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import MaterialToolbar from './MaterialToolbar'
import { getMaterialKinds } from './materialKindQuery'
import {
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
        kind?: string
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
    const kinds = await getMaterialKinds()
    const { q, kind, sort, dir } = parseMaterialListParams(sp)
    const requestedPage = parseMaterialPage(sp.page)
    const filterParams = { q, kind, sort, dir }

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
        .select('id, code, name, kind_code, may_be_processed, chemistry, unit, status, created_at, safety_stock_qty, waste_classification_code, material_kinds ( name_en, name_zh ), waste_classifications ( name_en, name_zh, is_controlled )')

    const { data: materials, error } = await applyMaterialFilters(
        baseQuery,
        filterParams
    ).range(from, to)

    // ── ASY-P2:每一个物料都要把自己的化验要求说出来,包括"没有" ────────────
    // 【为什么列表页也要有这一列】ASY-P1 的模型是「没有行 = 没有要求」,而那是一个
    // 假设:它读作"这种物料不需要化验",同时也是"还没有人想过这件事"的样子。
    // 只在编辑页说,就要求人一个一个点进去才知道自己有没有漏掉谁 —— 而这份政策
    // 是【逐个物料】做的决定,列表正是看见"还有谁没决定"的那张屏。
    // 【失败必须失败】不 `?? []`:读不出来会把每一行都画成"无化验要求"。
    const pageIds = (materials ?? []).map((m) => m.id)
    const reqRows = pageIds.length
        ? mustRows(
              await supabase
                  .from('material_required_metals')
                  .select('material_id, metal')
                  .in('material_id', pageIds)
                  .order('metal'),
              'material_required_metals'
          )
        : []
    const requiredByMaterial = new Map<string, string[]>()
    for (const r of reqRows) {
        requiredByMaterial.set(r.material_id, [
            ...(requiredByMaterial.get(r.material_id) ?? []),
            r.metal,
        ])
    }

    // 表头排序链接:点当前列翻转方向,点其它列默认升序;保留 q / kind。不带 page —— 改排序回到第 1 页。
    function sortHref(col: MaterialSortCol) {
        const nextDir = sort === col && dir === 'asc' ? 'desc' : 'asc'
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (kind) params.set('kind', kind)
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

    // 分页链接:保留当前的 q / kind / sort / dir,只改 page
    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (kind) params.set('kind', kind)
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
                <MaterialToolbar kinds={kinds} locale={locale} />
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
                            {t('materials.colWasteClass')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('materials.colAssayRequired')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('materials.colUnit')}
                        </th>
                        <th className="border border-gray-300 px-4 py-2 text-left">
                            {t('materials.colSafetyStock')}
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
                            {/* PROC-1:种类从字典读标签;【没人决定过】按名印出来,不留空 —— 空白会被读成"没有种类" */}
                            <td className="border border-gray-300 px-4 py-2">
                                {(m.material_kinds as { name_en: string; name_zh: string } | null)
                                    ? (locale === 'zh'
                                        ? (m.material_kinds as { name_zh: string }).name_zh
                                        : (m.material_kinds as { name_en: string }).name_en)
                                    : <span className="text-amber-700">{t('materials.kindUndecided')}</span>}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                {m.chemistry ? display(CHEMISTRY_OPTIONS, m.chemistry) : '—'}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {/* MAT-1:【未分类要说出来,不能画成空白】—— 空白读起来像
                                    "这一栏没填",而它的意思是"没有人分过类",
                                    与"分类为非受控"在合规判断上不是一回事。 */}
                                {m.waste_classifications ? (
                                    <>
                                        {locale === 'zh' ? m.waste_classifications.name_zh : m.waste_classifications.name_en}
                                        {m.waste_classifications.is_controlled && (
                                            <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800 border border-amber-300">
                                                {t('materials.wasteClass.controlled')}
                                            </span>
                                        )}
                                    </>
                                ) : (
                                    <span className="text-gray-400">{t('materials.wasteClass.unclassified')}</span>
                                )}
                            </td>
                            {/* ASY-P2:【"无化验要求"要说出来,不能画成空白】——
                                与旁边那一列同一条规矩:空白读起来像"这一栏没填",
                                而这里它的意思是一个决定(或者一个还没做的决定)。 */}
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {(requiredByMaterial.get(m.id) ?? []).length === 0 ? (
                                    <span className="text-gray-400">
                                        {t('materials.assayPolicy.noRequirement')}
                                    </span>
                                ) : (
                                    <span className="font-mono text-xs">
                                        {(requiredByMaterial.get(m.id) ?? [])
                                            .map((c) => t('metals.' + c))
                                            .join(', ')}
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{display(UNIT_OPTIONS, m.unit)}</td>
                            {/* SS-1:【绝不留空】—— 空白读起来像"没事",而它的真实含义是
                                "没有人设过这个阈值"。未监控必须自己说出来。 */}
                            <td className="border border-gray-300 px-4 py-2">
                                {m.safety_stock_qty === null ? (
                                    <span className="text-gray-400">{t('materials.notMonitored')}</span>
                                ) : (
                                    <span>{m.safety_stock_qty} {display(UNIT_OPTIONS, m.unit)}</span>
                                )}
                            </td>
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
