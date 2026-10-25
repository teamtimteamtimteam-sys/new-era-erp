import 'server-only'

// TABLE-EXPORT-2a(Tim 2026-10-22 Q2):对账单列表的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts,上限 50,000);两者同一套筛选(账户 · 状态)、
// 同一个 select、同一个映射。排序 period_end / created_at DESC 之后补 id —— 翻页取全要一个【唯一】的次序。
// ★ 每张报表的行状态计数:分批按报表 id 问,而且【每一批自己也翻页】—— 一批报表的行可以过 1,000,
//   而线上 PostgREST 读到第 1,000 行就悄悄停(TABLE-EXPORT-1 实测 max_rows = 1000):不翻页,计数会悄悄偏小。
//   从前页面那一次读既不翻页,也不看 error(读失败 = 每张报表都是 0 行)。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { fetchAllPages, IN_CHUNK } from '@/lib/export/serverRows'
import type { StatementRow } from './StatementsTable'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'

type Client = SupabaseClient<Database>

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):可排的列 —— 列键 → `bank_statements` 上的列(lib/listSort.ts 的规矩)。
 *   期间那一格是两头拼成的文字,按【期末日】排(它就是今天的默认次序那一列)。
 *   期初 / 期末余额是各张报表自己币种的数,没有本位币那一列 —— 不可排;行数与匹配计数是另外数出来的 —— 不可排。
 * ★ 默认不变(Q7):期末日新的在前,平局按建立时刻、再按 id。
 */
export const STATEMENT_SORT = { code: 'code', account: 'bank_account_code', period: 'period_end', status: 'status' } as const
export type StatementSortKey = keyof typeof STATEMENT_SORT
const STATEMENT_SORT_DEFAULT: ListSort<StatementSortKey> = { key: 'period', dir: 'desc' }

export type StatementListParams = { account: '' | '1000' | '1010'; status: '' | 'open' | 'reconciled'; sort: ListSort<StatementSortKey> }

export function parseStatementListParams(sp: { account?: string; status?: string; sort?: string; dir?: string }): StatementListParams {
    return {
        account: sp.account === '1000' || sp.account === '1010' ? sp.account : '',
        status: sp.status === 'open' || sp.status === 'reconciled' ? sp.status : '',
        sort: parseListSort(sp, Object.keys(STATEMENT_SORT) as StatementSortKey[], STATEMENT_SORT_DEFAULT),
    }
}

// 过滤链。最小链式子集,避免 supabase 深泛型。
interface Chain {
    eq(c: string, v: string): Chain
    is(c: string, v: null): Chain
}
function applyFilters<T>(query: T, p: StatementListParams): T {
    let chain = (query as unknown as Chain).is('deleted_at', null)
    if (p.account) chain = chain.eq('bank_account_code', p.account)
    if (p.status) chain = chain.eq('status', p.status)
    return chain as unknown as T
}

export type StatementDbRow = {
    id: string; code: string; bank_account_code: string; currency: string; period_start: string; period_end: string
    opening_balance: number; closing_balance: number; status: string
}

export function statementCount(supabase: Client, p: StatementListParams) {
    return applyFilters(supabase.from('bank_statements').select('id', { count: 'exact', head: true }), p)
}

export function statementPage(supabase: Client, p: StatementListParams, from: number, to: number) {
    return applyListSort(
        applyFilters(
            supabase
                .from('bank_statements')
                .select('id, code, bank_account_code, currency, period_start, period_end, opening_balance, closing_balance, status'),
            p,
        ),
        p.sort, STATEMENT_SORT, [['period_end', 'desc'], ['created_at', 'desc'], ['id', 'asc']],
    )
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as StatementDbRow[] | null }))
}

/** 导出路由的地址:同一套筛选,不带 page。 */
export function statementExportHref(p: StatementListParams): string {
    const params = new URLSearchParams()
    if (p.account) params.set('account', p.account)
    if (p.status) params.set('status', p.status)
    setSortParams(params, p.sort)
    const qs = params.toString()
    return qs ? `/finance/bank/statements/export?${qs}` : '/finance/bank/statements/export'
}

export async function shapeStatementRows(supabase: Client, rows: StatementDbRow[]): Promise<StatementRow[]> {
    type Counts = { total: number; matched: number; unmatched: number; ignored: number }
    const countsById = new Map<string, Counts>()
    const ids = rows.map((r) => r.id)
    for (let i = 0; i < ids.length; i += IN_CHUNK) {
        const chunk = ids.slice(i, i + IN_CHUNK)
        const lines = await fetchAllPages(
            (from, to) => supabase.from('bank_statement_lines').select('id, statement_id, match_status')
                .in('statement_id', chunk).order('id', { ascending: true }).range(from, to),
            'bank_statement_lines (counts)',
        )
        for (const l of lines) {
            const c = countsById.get(l.statement_id) ?? { total: 0, matched: 0, unmatched: 0, ignored: 0 }
            c.total += 1
            if (l.match_status === 'matched') c.matched += 1
            else if (l.match_status === 'ignored') c.ignored += 1
            else c.unmatched += 1
            countsById.set(l.statement_id, c)
        }
    }
    const zero: Counts = { total: 0, matched: 0, unmatched: 0, ignored: 0 }
    return rows.map((r) => {
        const c = countsById.get(r.id) ?? zero
        return {
            id: r.id,
            code: r.code,
            bankAccountCode: r.bank_account_code,
            period: `${r.period_start} – ${r.period_end}`,
            opening: r.opening_balance,
            closing: r.closing_balance,
            currency: r.currency,
            lineTotal: c.total,
            matched: c.matched,
            unmatched: c.unmatched,
            ignored: c.ignored,
            status: r.status,
        }
    })
}
