// app/materials/page.tsx
// 物料字典列表页:URL 驱动的搜索 / 分类筛选 / 排序 / 分页(全部在服务端完成)。
// 端口自 suppliers 列表,字段适配 materials(种类筛选用 kind_code — PROC-1)。
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import { formatTimestamp } from '@/lib/format'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import MaterialToolbar from './MaterialToolbar'
import { ListPage } from '@/app/components/ui/list-page'
import MaterialsTable, { type MaterialTableRow } from './MaterialsTable'
import { getMaterialKinds } from './materialKindQuery'
import { loadBatteryChemistries, toDictOptions, dictLabeller } from '@/app/components/dictionaries/dictionaryQuery'
import {
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
    // PROC-5:化学体系显示名来自字典。**连停用的一起读** —— 一条记着已停用
    // 取值的历史行必须照样显示得出名字,否则看起来像数据坏了。
    const chemistryLabel = dictLabeller(toDictOptions(await loadBatteryChemistries(supabase), locale))
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

    // CONV-5:套 CONV-1 的两文件模板。
    // ★ 这一页的四处"具名的缺席"(种类未决定 / 未分类 / 无化验要求 / 未监控)
    //   在这里压平成【可判空的字段】,那四句话由 MaterialsTable 画 —— 见它的抬头。
    // ★ Q7:排序仍是服务端的。★ state 恒为 'ok' —— MaterialToolbar 是真实出口。
    const tableRows: MaterialTableRow[] = (materials ?? []).map((m) => {
        const mk = m.material_kinds as { name_en: string; name_zh: string } | null
        const wc = m.waste_classifications
        return {
            id: m.id,
            code: m.code,
            name: m.name,
            // 语言在服务端选好 —— locale 不过 RSC 边界
            kindLabel: mk ? (locale === 'zh' ? mk.name_zh : mk.name_en) : null,
            chemistry: m.chemistry ? chemistryLabel(m.chemistry) : '—',
            wasteClassLabel: wc ? (locale === 'zh' ? wc.name_zh : wc.name_en) : null,
            wasteControlled: Boolean(wc?.is_controlled),
            assayMetals: requiredByMaterial.get(m.id) ?? [],
            unitLabel: display(UNIT_OPTIONS, m.unit),
            safetyStockLabel:
                m.safety_stock_qty === null ? null : `${m.safety_stock_qty} ${display(UNIT_OPTIONS, m.unit)}`,
            status: m.status,
            createdLabel: formatTimestamp(m.created_at, dateLocale),
        }
    })

    const filterQuery: Record<string, string> = {}
    if (q) filterQuery.q = q
    if (kind) filterQuery.kind = kind

    return (
        <ListPage
            title={t('materials.listTitle')}
            actions={
                <Button asChild>
                    <Link href="/materials/new">{t('materials.addButton')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <MaterialToolbar kinds={kinds} locale={locale} />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('materials.recordCount', { count: total })}
            </p>

            <MaterialsTable
                rows={tableRows}
                empty={t('materials.emptyState')}
                sort={sort}
                dir={dir}
                filterQuery={filterQuery}
                shown={tableRows.length}
                total={total}
            />

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
        </ListPage>
    )
}
