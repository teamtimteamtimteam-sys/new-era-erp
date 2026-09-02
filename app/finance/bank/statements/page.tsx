// app/finance/bank/statements/page.tsx
// 对账单列表:最新在前(period_end DESC),账户 + 状态筛选,count+range 分页
// (端口自收付款列表)。已软删的不列。每张报表的行状态计数按页级一次 .in 聚合。
import { Suspense } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatAmount } from '@/lib/format'
import StatementsToolbar from './StatementsToolbar'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

const PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function BankStatementsPage({
    searchParams,
}: {
    searchParams: Promise<{ account?: string; status?: string; page?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const account = sp.account === '1000' || sp.account === '1010' ? sp.account : ''
    const status = sp.status === 'open' || sp.status === 'reconciled' ? sp.status : ''
    const requestedPage = parsePage(sp.page)

    // 过滤链。最小链式子集,避免 supabase 深泛型。
    interface Chain {
        eq(c: string, v: string): Chain
        is(c: string, v: null): Chain
    }
    const applyFilters = <T,>(query: T): T => {
        let chain = (query as unknown as Chain).is('deleted_at', null)
        if (account) chain = chain.eq('bank_account_code', account)
        if (status) chain = chain.eq('status', status)
        return chain as unknown as T
    }

    const { count } = await applyFilters(
        supabase.from('bank_statements').select('id', { count: 'exact', head: true })
    )

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * PAGE_SIZE
    const to = from + PAGE_SIZE - 1

    const { data: statements, error } = await applyFilters(
        supabase
            .from('bank_statements')
            .select('id, code, bank_account_code, currency, period_start, period_end, opening_balance, closing_balance, status')
    )
        .order('period_end', { ascending: false })
        .order('created_at', { ascending: false })
        .range(from, to)

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('bank.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const rows = statements ?? []

    // 行状态计数:页级一次取本页所有报表的行状态,在内存里聚合
    const ids = rows.map((r) => r.id)
    const { data: lineRows } = ids.length
        ? await supabase
              .from('bank_statement_lines')
              .select('statement_id, match_status')
              .in('statement_id', ids)
        : { data: [] as { statement_id: string; match_status: string }[] }

    type Counts = { total: number; matched: number; unmatched: number; ignored: number }
    const countsById = new Map<string, Counts>()
    for (const l of lineRows ?? []) {
        const c = countsById.get(l.statement_id) ?? { total: 0, matched: 0, unmatched: 0, ignored: 0 }
        c.total += 1
        if (l.match_status === 'matched') c.matched += 1
        else if (l.match_status === 'ignored') c.ignored += 1
        else c.unmatched += 1
        countsById.set(l.statement_id, c)
    }
    const zero: Counts = { total: 0, matched: 0, unmatched: 0, ignored: 0 }

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (account) params.set('account', account)
        if (status) params.set('status', status)
        params.set('page', String(targetPage))
        return `/finance/bank/statements?${params.toString()}`
    }

    return (
        <div className="p-8">
            <div className="flex justify-between items-center mb-4">
                <h1 className="text-2xl font-bold">{t('bank.listTitle')}</h1>
                <Link
                    href="/finance/bank/import"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('bank.import')}
                </Link>
            </div>

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <StatementsToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">{t('finance.recordCount', { count: total })}</p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('bank.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('bank.colAccount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('bank.colPeriod')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('bank.colOpening')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('bank.colClosing')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('bank.colLines')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('bank.colMatched')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('bank.colUnmatched')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('bank.colIgnored')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colStatus')}</th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => {
                        const c = countsById.get(r.id) ?? zero
                        return (
                            <tr key={r.id}>
                                <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                    <Link
                                        href={`/finance/bank/statements/${r.id}`}
                                        className="text-blue-600 hover:underline"
                                    >
                                        {r.code}
                                    </Link>
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">
                                    <span className="font-mono">{r.bank_account_code}</span>{' '}
                                    {t('finance.bank.' + r.bank_account_code)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">
                                    {r.period_start} – {r.period_end}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatAmount(r.opening_balance, r.currency)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatAmount(r.closing_balance, r.currency)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">{c.total}</td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">{c.matched}</td>
                                <td
                                    className={
                                        'border border-gray-300 px-4 py-2 text-right font-mono text-sm ' +
                                        (c.unmatched > 0 ? 'text-amber-700 font-medium' : '')
                                    }
                                >
                                    {c.unmatched}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">{c.ignored}</td>
                                <td className="border border-gray-300 px-4 py-2">
                                    <span
                                        className={
                                            'px-2 py-1 rounded text-xs ' +
                                            (r.status === 'reconciled'
                                                ? 'bg-green-100 text-green-800'
                                                : 'bg-amber-100 text-amber-800')
                                        }
                                    >
                                        {t('bank.status.' + r.status)}
                                    </span>
                                </td>
                            </tr>
                        )
                    })}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={10} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('bank.empty')}
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
