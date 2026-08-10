// app/finance/journal/page.tsx
// 分录列表:最新在前,entry_date 日期区间 + count+range 分页(端口自 processing 列表)。
// 来源列按 source_type 本地化,可解析的 source_id 附业务单据链接(服务端小批量反查)。
import { Suspense } from 'react'
import { getBaseCurrency } from '@/lib/currency'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { parseDateRange } from '@/lib/dateFilter'
import { formatMoneyBare } from '@/lib/format'
import Subnav from '../Subnav'
import JournalToolbar from './JournalToolbar'
import { resolveSourceHrefs, sourceHrefKey } from '../sourceLinks'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

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

    const sourceLabel = (v: string | null) => (v ? t('finance.source.' + v) : '—')

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('finance.journalTitle')}</h1>

            <Subnav />

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <JournalToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('finance.recordCount', { count: total })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colMemo')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colSource')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colAmount', { ccy: baseCurrency })}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colStatus')}</th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => {
                        const href = hrefs.get(sourceHrefKey(r))
                        return (
                            <tr key={r.id}>
                                <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                    <Link
                                        href={`/finance/journal/${r.id}`}
                                        className="text-blue-600 hover:underline"
                                    >
                                        {r.code}
                                    </Link>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">{r.entry_date}</td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">{r.memo ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">
                                    {href ? (
                                        <Link href={href} className="text-blue-600 hover:underline">
                                            {sourceLabel(r.source_type)}
                                        </Link>
                                    ) : (
                                        sourceLabel(r.source_type)
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatMoneyBare(amountByEntry.get(r.id) ?? 0, '列头 金额 ({ccy}) —— 已带本位币')}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    <span
                                        className={
                                            'px-2 py-1 rounded text-xs ' +
                                            (r.status === 'posted'
                                                ? 'bg-green-100 text-green-800'
                                                : 'bg-gray-200 text-gray-700')
                                        }
                                    >
                                        {t('finance.status.' + r.status)}
                                    </span>
                                </td>
                            </tr>
                        )
                    })}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={6} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('finance.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>

            {/* 分页控件:服务端 <Link>;首页禁用上一页、末页禁用下一页 */}
            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Link
                        href={pageHref(page - 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('finance.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('finance.pagination.prev')}
                    </span>
                )}

                <span className="text-sm text-gray-600">
                    {t('finance.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('finance.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('finance.pagination.next')}
                    </span>
                )}
            </div>
        </div>
    )
}
