// app/stocktakes/page.tsx
// 盘点单列表页。暂无筛选工具栏;count+range 分页端口自 processing 列表。
// 新建按钮直接提交 createStocktake(空单 → 跳详情开始点数)。
import { createClient } from '@/lib/supabase/server'
import { formatTimestamp } from '@/lib/format'
import Link from 'next/link'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { stocktakeStatusLabelKey } from './status'
import { createStocktake } from './actions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import StocktakesTable, { type StocktakeRow } from './StocktakesTable'
import { Button } from '@/app/components/ui/button'

const STOCKTAKE_PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function StocktakesPage({
    searchParams,
}: {
    searchParams: Promise<{ page?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.stocktakes)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    // 状态标签(未知值回退原样)
    const statusLabel = (v: string | null) => {
        const k = stocktakeStatusLabelKey(v)
        return k ? t(k) : v ?? '—'
    }

    const requestedPage = parsePage(sp.page)

    // 1) 匹配总数
    const { count } = await supabase
        .from('stocktakes')
        .select('id', { count: 'exact', head: true })
        .is('deleted_at', null)

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / STOCKTAKE_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * STOCKTAKE_PAGE_SIZE
    const to = from + STOCKTAKE_PAGE_SIZE - 1

    // 2) 取当前页
    const { data: rows, error } = await supabase
        .from('stocktakes')
        .select('id, code, status, started_at, posted_at, notes')
        .is('deleted_at', null)
        .order('created_at', { ascending: false })
        .range(from, to)

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        params.set('page', String(targetPage))
        return `/stocktakes?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('stocktakes.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('stocktakes.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // CONV-5:套 CONV-1 的两文件模板。state 恒为 'ok' —— 「新建盘点单」是一个
    // server action 表单,住在 actions 里(状态分支之前);一张盘点单都没有的时候
    // 它正是唯一能做的事。
    const tableRows: StocktakeRow[] = (rows ?? []).map((r) => ({
        id: r.id,
        code: r.code,
        statusLabel: statusLabel(r.status),
        // 时间戳按 locale 格式化在服务端做完 —— dateLocale 不过 RSC 边界
        startedLabel: formatTimestamp(r.started_at, dateLocale),
        postedLabel: r.posted_at ? formatTimestamp(r.posted_at, dateLocale) : null,
        notes: r.notes ?? '—',
    }))

    return (
        <ListPage
            title={t('stocktakes.listTitle')}
            actions={
                <form action={createStocktake}>
                    <Button
                        type="submit">
                        {t('stocktakes.new')}
                    </Button>
                </form>
            }
            state={{ kind: 'ok' }}
        >
            <p className="text-sm text-gray-600 mb-4">
                {t('stocktakes.recordCount', { count: total })}
            </p>

            <StocktakesTable rows={tableRows} empty={t('stocktakes.emptyState')} />

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Link
                        href={pageHref(page - 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('stocktakes.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('stocktakes.pagination.prev')}
                    </span>
                )}

                <span className="text-sm text-gray-600">
                    {t('stocktakes.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('stocktakes.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('stocktakes.pagination.next')}
                    </span>
                )}
            </div>
        </ListPage>
    )
}
