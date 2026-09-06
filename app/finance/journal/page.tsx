// app/finance/journal/page.tsx
// 分录列表:最新在前,entry_date 日期区间 + count+range 分页(端口自 processing 列表)。
// 来源列按 source_type 本地化,可解析的 source_id 附业务单据链接(服务端小批量反查)。
//
// CONV-4:套 CONV-1 的两文件模板。state 恒为 'ok' —— 筛选工具栏是真实出口。
import { Suspense } from 'react'
import { getBaseCurrency } from '@/lib/currency'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { parseDateRange } from '@/lib/dateFilter'
import JournalToolbar from './JournalToolbar'
import JournalTable, { type JournalRow } from './JournalTable'
import { resolveSourceHrefs, sourceHrefKey } from '../sourceLinks'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { Button } from '@/app/components/ui/button'

const JOURNAL_PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function JournalListPage({
    searchParams,
}: {
    searchParams: Promise<{ date_from?: string; date_to?: string; page?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()

    const { dateFrom, dateTo } = parseDateRange(sp)
    const requestedPage = parsePage(sp.page)

    // 过滤链(journal_entries 无软删 —— 不可变表)。
    // 最小链式子集,避免 supabase 深泛型(同 processingQuery 手法)。
    interface Chain {
        gte(c: string, v: string): Chain
        lte(c: string, v: string): Chain
    }
    const applyFilters = <T,>(query: T): T => {
        let chain = query as unknown as Chain
        if (dateFrom) chain = chain.gte('entry_date', dateFrom)
        if (dateTo) chain = chain.lte('entry_date', dateTo)
        return chain as unknown as T
    }

    // 1) 匹配总数
    const { count } = await applyFilters(
        supabase.from('journal_entries').select('id', { count: 'exact', head: true })
    )

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / JOURNAL_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * JOURNAL_PAGE_SIZE
    const to = from + JOURNAL_PAGE_SIZE - 1

    // 2) 取当前页(创建序最新在前)
    const { data: entries, error } = await applyFilters(
        supabase
            .from('journal_entries')
            .select('id, code, entry_date, memo, source_type, source_id, status')
    )
        .order('created_at', { ascending: false })
        .range(from, to)

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.journalTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const rows = entries ?? []

    // 3) 每张分录的金额(Σ借方)+ 来源链接,页级小查询
    const ids = rows.map((r) => r.id)
    const [linesRes, hrefs] = await Promise.all([
        ids.length
            ? supabase.from('journal_lines').select('entry_id, debit').in('entry_id', ids)
            : Promise.resolve({ data: [] as { entry_id: string; debit: number }[], error: null }),
        resolveSourceHrefs(supabase, rows),
    ])
    const amountByEntry = new Map<string, number>()
    for (const l of mustRows(linesRes)) {
        amountByEntry.set(l.entry_id, (amountByEntry.get(l.entry_id) ?? 0) + l.debit)
    }

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        params.set('page', String(targetPage))
        return `/finance/journal?${params.toString()}`
    }

    const tableRows: JournalRow[] = rows.map((r) => ({
        id: r.id,
        code: r.code,
        entryDate: r.entry_date,
        memo: r.memo,
        sourceType: r.source_type,
        sourceHref: hrefs.get(sourceHrefKey(r)) ?? null,
        amount: amountByEntry.get(r.id) ?? 0,
        status: r.status,
    }))

    return (
        <ListPage title={t('finance.journalTitle')} state={{ kind: 'ok' }}>
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <JournalToolbar />
            </Suspense>

            <div className="flex flex-wrap items-center gap-4 mb-4">
                <p className="text-sm text-gray-600">
                    {t('finance.recordCount', { count: total })}
                </p>
                {/* ★【总账导出的入口】★ 一个没有入口的导出路由,路由冒烟照样 200 ——
                    而这个仓库为「无门上线」付过两次账(SAL-B6 的客户页、
                    FRT-FIX 的货代下拉)。期间沿用工具栏此刻筛的那一段:
                    导出必须有期间,而让人再填一遍就是同一个问题问两次。
                    【筛选为空时不给链接,而是说出为什么】—— 一份"默认全部"的
                    总账导出说不出自己覆盖到哪天。 */}
                {dateFrom && dateTo ? (
                    <Button asChild variant="outline" size="sm">
                        <a href={`/finance/journal/export?from=${dateFrom}&to=${dateTo}`}>
                            {t('glExport.button')}
                        </a>
                    </Button>
                ) : (
                    <span className="text-sm text-amber-700">{t('glExport.needPeriod')}</span>
                )}
            </div>

            <JournalTable rows={tableRows} empty={t('finance.emptyState')} baseCurrency={baseCurrency} />

            {/* 分页控件:服务端 <Link>;首页禁用上一页、末页禁用下一页 */}
            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline" size="sm">
                        <Link
                            href={pageHref(page - 1)}
                        >
                            {t('finance.pagination.prev')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" size="sm" disabled>
                        {t('finance.pagination.prev')}
                    </Button>
                )}

                <span className="text-sm text-gray-600">
                    {t('finance.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Button asChild variant="outline" size="sm">
                        <Link
                            href={pageHref(page + 1)}
                        >
                            {t('finance.pagination.next')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" size="sm" disabled>
                        {t('finance.pagination.next')}
                    </Button>
                )}
            </div>
        </ListPage>
    )
}
