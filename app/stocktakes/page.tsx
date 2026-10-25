// app/stocktakes/page.tsx
// 盘点单列表页。暂无筛选工具栏;count+range 分页端口自 processing 列表。
// 新建按钮直接提交 createStocktake(空单 → 跳详情开始点数)。
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { createStocktake } from './actions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import StocktakesTable, { type StocktakeRow } from './StocktakesTable'
import { Button } from '@/app/components/ui/button'
import { stocktakeCount, stocktakePage, shapeStocktakeRows, parseStocktakeSort } from './stocktakeRows'
import { setSortParams } from '@/lib/listSort'
import { can } from '@/lib/permissions'
import { PermissionGate } from '@/app/components/ui/permission-gate'

const STOCKTAKE_PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function StocktakesPage({
    searchParams,
}: {
    searchParams: Promise<{ page?: string; sort?: string; dir?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.stocktakes)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const requestedPage = parsePage(sp.page)
    // TABLE-FEATURES-1 Q9:在数据库里排
    const sort = parseStocktakeSort(sp)
    // ROLE-1 Batch 3a:开单是录数的第一步,归 action.stocktake_count(仓库)。按不动时点名那个码。
    const canCount = await can('action.stocktake_count')

    // 1) 匹配总数
    const { count } = await stocktakeCount(supabase)

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / STOCKTAKE_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * STOCKTAKE_PAGE_SIZE
    const to = from + STOCKTAKE_PAGE_SIZE - 1

    // 2) 取当前页(TABLE-EXPORT-1:select / 排序 / 映射住在 stocktakeRows.ts,导出路由走同一份)
    const { data: rows, error } = await stocktakePage(supabase, from, to, sort)

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        setSortParams(params, sort)
        params.set('page', String(targetPage))
        return `/stocktakes?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="mb-4">{t('stocktakes.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('stocktakes.loadError')}</p>
                    <details className="mt-2">
                        <summary className="cursor-pointer text-xs">{t('common.actionMessage.technicalDetail')}</summary>
                        <pre className="mt-1 text-xs">{JSON.stringify(error, null, 2)}</pre>
                    </details>
                </div>
            </div>
        )
    }

    // CONV-5:套 CONV-1 的两文件模板。state 恒为 'ok' —— 「新建盘点单」是一个
    // server action 表单,住在 actions 里(状态分支之前);一张盘点单都没有的时候
    // 它正是唯一能做的事。
    const tableRows: StocktakeRow[] = await shapeStocktakeRows(rows ?? [])

    return (
        <ListPage
            title={t('stocktakes.listTitle')}
            actions={
                <PermissionGate code="action.stocktake_count" allowed={canCount}>
                    <form action={createStocktake}>
                        <Button
                            type="submit">
                            {t('stocktakes.new')}
                        </Button>
                    </form>
                </PermissionGate>
            }
            state={{ kind: 'ok' }}
        >
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">
                {t('stocktakes.recordCount', { count: total })}
            </p>

            {/* TABLE-EXPORT-1 Q2:导出取【全部】盘点单 —— 这一页没有筛选,排序固定,不带 page。 */}
            {/* TABLE-FEATURES-1 Q9:导出带上当前排序 */}
            <StocktakesTable rows={tableRows} empty={t('stocktakes.emptyState')}
                             exportHref={`/stocktakes/export?${setSortParams(new URLSearchParams(), sort).toString()}`}
                             sort={sort} shown={tableRows.length} total={total} />

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page - 1)}
                        >
                            {t('stocktakes.pagination.prev')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('stocktakes.pagination.prev')}
                    </Button>
                )}

                <span className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('stocktakes.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page + 1)}
                        >
                            {t('stocktakes.pagination.next')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('stocktakes.pagination.next')}
                    </Button>
                )}
            </div>
        </ListPage>
    )
}
