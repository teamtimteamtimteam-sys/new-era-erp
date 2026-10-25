import 'server-only'

// TABLE-EXPORT-2a(Tim 2026-10-22 Q2):分录列表的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts,上限 50,000);两者同一套筛选(entry_date 区间)、
// 同一个 select、同一个映射。排序 created_at DESC 之后补 id —— 翻页取全要一个【唯一】的次序。
// ★ TABLE-FEATURES-1 Q7(2026-10-25):默认改为 entry_date DESC → created_at DESC → id(见 JOURNAL_SORT)。
// ★ 这【不是】总账导出(./export/route.ts,一行一条分录行、必须给起止日 —— GLEXPORT-1,五条专用导出之一):
//   这一条导出的是这张清单本身,一行一张分录,列就是表上的列(TABLE-EXPORT-1 Q11)。
// ★ 金额:每张分录 Σ借方,读 journal_lines_masked —— 工资分录的金额对不持 data.view_pay 的人受限(U1-A);
//   读基表的话那几行对他们不在,金额会悄悄变成 0.00(比「受限」更坏)。分批按分录 id 问,【每一批自己也翻页】
//   (一批分录的行可以过 1,000,而线上 PostgREST 读到第 1,000 行就悄悄停 —— 不翻页,金额会悄悄偏小)。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { parseDateRange } from '@/lib/dateFilter'
import { formatDate } from '@/lib/dates'
import { getLocale } from '@/lib/i18n/server'
import { fetchAllPages, IN_CHUNK } from '@/lib/export/serverRows'
import { resolveSourceHrefs, sourceHrefKey } from '../sourceLinks'
import type { JournalRow } from './JournalTable'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'

type Client = SupabaseClient<Database>

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):可排的列 —— 列键 → `journal_entries` 上的列(lib/listSort.ts 的规矩)。
 *   金额是各行借方之和(另读 journal_lines_masked 算出来的),不可排。来源按 source_type 那个码排。
 * ★ Q7:默认按分录日(新的在前),平局按建立时刻、再按 id —— 筛选按分录日,排序原来却按建立时刻。
 */
export const JOURNAL_SORT = { code: 'code', date: 'entry_date', memo: 'memo', source: 'source_type', status: 'status' } as const
export type JournalSortKey = keyof typeof JOURNAL_SORT
const JOURNAL_SORT_DEFAULT: ListSort<JournalSortKey> = { key: 'date', dir: 'desc' }

export type JournalListParams = { dateFrom: string; dateTo: string; sort: ListSort<JournalSortKey> }

export function parseJournalListParams(sp: { date_from?: string; date_to?: string; sort?: string; dir?: string }): JournalListParams {
    const { dateFrom, dateTo } = parseDateRange(sp)
    return { dateFrom, dateTo, sort: parseListSort(sp, Object.keys(JOURNAL_SORT) as JournalSortKey[], JOURNAL_SORT_DEFAULT) }
}

// 过滤链(journal_entries 无软删 —— 不可变表)。最小链式子集,避免 supabase 深泛型。
interface Chain {
    gte(c: string, v: string): Chain
    lte(c: string, v: string): Chain
}
function applyFilters<T>(query: T, p: JournalListParams): T {
    let chain = query as unknown as Chain
    if (p.dateFrom) chain = chain.gte('entry_date', p.dateFrom)
    if (p.dateTo) chain = chain.lte('entry_date', p.dateTo)
    return chain as unknown as T
}

export type JournalDbRow = {
    id: string; code: string; entry_date: string; memo: string | null; source_type: string | null; source_id: string | null; status: string
}

export function journalCount(supabase: Client, p: JournalListParams) {
    return applyFilters(supabase.from('journal_entries').select('id', { count: 'exact', head: true }), p)
}

export function journalPage(supabase: Client, p: JournalListParams, from: number, to: number) {
    return applyListSort(
        applyFilters(
            supabase.from('journal_entries').select('id, code, entry_date, memo, source_type, source_id, status'),
            p,
        ),
        p.sort, JOURNAL_SORT, [['entry_date', 'desc'], ['created_at', 'desc'], ['id', 'asc']],
    )
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as JournalDbRow[] | null }))
}

/** 导出路由的地址(清单的导出,不是总账导出):同一套筛选,不带 page。 */
export function journalListExportHref(p: JournalListParams): string {
    const params = new URLSearchParams()
    if (p.dateFrom) params.set('date_from', p.dateFrom)
    if (p.dateTo) params.set('date_to', p.dateTo)
    setSortParams(params, p.sort)
    const qs = params.toString()
    return qs ? `/finance/journal/entries/export?${qs}` : '/finance/journal/entries/export'
}

/**
 * 库里的行 → 表的行。`withLinks`:页面要来源单据的链接(按 source_type 分组反查);导出不要 —— 导出的是来源【类型】那一格的字,
 * 链接不是数据(TABLE-EXPORT-1 Q11:列就是表上的列,一格一个值)。
 */
export async function shapeJournalRows(supabase: Client, rows: JournalDbRow[], withLinks: boolean): Promise<JournalRow[]> {
    const locale = await getLocale()
    const amountByEntry = new Map<string, number>()
    const restrictedEntries = new Set<string>()
    const ids = rows.map((r) => r.id)
    for (let i = 0; i < ids.length; i += IN_CHUNK) {
        const chunk = ids.slice(i, i + IN_CHUNK)
        const lines = await fetchAllPages(
            (from, to) => supabase.from('journal_lines_masked').select('id, entry_id, debit, amounts_restricted')
                .in('entry_id', chunk).order('id', { ascending: true }).range(from, to)
                .then(({ data, error }) => ({ error, data: data as unknown as { entry_id: string; debit: number | null; amounts_restricted: boolean }[] | null })),
            'journal_lines_masked (entry amounts)',
        )
        for (const l of lines) {
            if (l.amounts_restricted) restrictedEntries.add(l.entry_id)
            amountByEntry.set(l.entry_id, (amountByEntry.get(l.entry_id) ?? 0) + (l.debit ?? 0))
        }
    }
    const hrefs = withLinks ? await resolveSourceHrefs(supabase, rows) : new Map<string, string>()
    return rows.map((r) => ({
        id: r.id,
        code: r.code,
        entryDate: formatDate(r.entry_date, locale),
        entryDateRaw: r.entry_date,
        memo: r.memo,
        sourceType: r.source_type,
        sourceHref: hrefs.get(sourceHrefKey(r)) ?? null,
        // 受限的分录给 null —— 表格印「受限」,不印一个由被遮的行拼出来的 0.00
        amount: restrictedEntries.has(r.id) ? null : Math.round((amountByEntry.get(r.id) ?? 0) * 100) / 100,
        status: r.status,
    }))
}
