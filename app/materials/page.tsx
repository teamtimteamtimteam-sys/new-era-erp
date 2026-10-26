// app/materials/page.tsx
// 物料字典列表页:URL 驱动的搜索 / 分类筛选 / 排序 / 分页(全部在服务端完成)。
// 端口自 suppliers 列表,字段适配 materials(种类筛选用 kind_code — PROC-1)。
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import MaterialToolbar from './MaterialToolbar'
import { ListPage } from '@/app/components/ui/list-page'
import MaterialsTable, { type MaterialTableRow } from './MaterialsTable'
import { materialCount, materialPage, shapeMaterialRows } from './materialRows'
import { getMaterialKinds } from './materialKindQuery'
import {
    parseMaterialListParams,
    parseMaterialPage,
    MATERIAL_PAGE_SIZE,
    type MaterialSortCol,
} from './materialQuery'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { SavedViewsBar } from '@/app/components/ui/saved-views'
import { loadSavedViews } from '@/lib/savedViewsServer'

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
    // TABLE-FEATURES-3(Tim 2026-10-26 Q1–Q3):保存的视图 —— 地址为空时套用本人的默认视图(一次跳转,所以在任何别的查询之前)
    const savedViews = await loadSavedViews(supabase, { listKey: '/materials', sp })
    const t = await getTranslations()
    const locale = await getLocale()
    const kinds = await getMaterialKinds()
    // 解析并校验 URL 参数(都给安全默认值)—— 与导出路由共用同一份逻辑
    const { q, kind, sort, dir } = parseMaterialListParams(sp)
    const requestedPage = parseMaterialPage(sp.page)
    const filterParams = { q, kind, sort, dir }

    // 1) 先取匹配总数(同样套用过滤,所以总页数对当前筛选是准确的)。head:true 只要 count 不要行。
    const { count } = await materialCount(supabase, filterParams)
    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / MATERIAL_PAGE_SIZE))
    // 把页码上钳到总页数(手输过大的 ?page= 时回落到最后一页,而不是空表)
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * MATERIAL_PAGE_SIZE
    const to = from + MATERIAL_PAGE_SIZE - 1

    // 2) 取当前页的行:过滤 + 排序后再 .range(from, to)
    const { data: materials, error } = await materialPage(supabase, filterParams, from, to)

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
                <h1 className="mb-4">{t('materials.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('materials.loadError')}</p>
                    <details className="mt-2">
                        <summary className="cursor-pointer text-xs">{t('common.actionMessage.technicalDetail')}</summary>
                        <pre className="mt-1 text-xs">{JSON.stringify(error, null, 2)}</pre>
                    </details>
                </div>
            </div>
        )
    }

    // CONV-5:套 CONV-1 的两文件模板。
    // ★ 这一页的四处"具名的缺席"(种类未决定 / 未分类 / 无化验要求 / 未监控)
    //   在这里压平成【可判空的字段】,那四句话由 MaterialsTable 画 —— 见它的抬头。
    // ★ Q7:排序仍是服务端的。★ state 恒为 'ok' —— MaterialToolbar 是真实出口。
    const tableRows: MaterialTableRow[] = await shapeMaterialRows(supabase, materials ?? [])

    const filterQuery: Record<string, string> = {}
    if (q) filterQuery.q = q
    if (kind) filterQuery.kind = kind
    // TABLE-EXPORT-1 Q2:导出取【全部匹配行】—— 同一套筛选与排序,不带 page。
    const exportHref = `/materials/export?${new URLSearchParams({ ...filterQuery, sort, dir }).toString()}`

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
                <SavedViewsBar listKey="/materials" views={savedViews} />
                <MaterialToolbar kinds={kinds} locale={locale} />
            </Suspense>

            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">
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
                exportHref={exportHref}
            />

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page - 1)}
                        >
                            {t('materials.pagination.prev')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('materials.pagination.prev')}
                    </Button>
                )}

                <span className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('materials.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page + 1)}
                        >
                            {t('materials.pagination.next')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('materials.pagination.next')}
                    </Button>
                )}
            </div>
        </ListPage>
    )
}
