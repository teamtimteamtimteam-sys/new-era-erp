import 'server-only'

// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):报价清单的【一份】读取 —— 页面与导出路由共用。
// 页面只画最新的 QUOTES_SHOWN 张(从前是一句不说的 .limit(200)),表上方 RowCapNotice 说出「前 N 张,共 M 张」;
// 导出路由按同一条读取翻页取全(上限 50,000)。读的仍是 quote_status(过期是算出来的,见页面抬头);排序补 quote_id 作唯一次序。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import type { QuoteRow } from './QuotesTable'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'

type Client = SupabaseClient<Database>

/** 页面画多少张 —— 与转换之前同一个数。 */
export const QUOTES_SHOWN = 200

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):只画前 QUOTES_SHOWN 张 → 在数据库里排(排在截取之前)。
 *   列键 → `quote_status` 视图上的列。客户那一格是「代码 — 名称」,按视图上的 customer_code 排(代码在前,顺序与那串字一致);
 *   报价号按 code 排(旁边的 vN 是同一张报价的版本号);状态按库里的状态码排。
 *   默认 = 今天的 ORDER BY:quote_date DESC,平局按 quote_id。
 */
export const QUOTE_SORT = {
    code: 'code', customer: 'customer_code', quoteDate: 'quote_date', validUntil: 'valid_until',
    status: 'status', currency: 'currency', order: 'converted_order_code',
} as const
export type QuoteSortKey = keyof typeof QUOTE_SORT
const QUOTE_SORT_DEFAULT: ListSort<QuoteSortKey> = { key: 'quoteDate', dir: 'desc' }

export function parseQuoteSort(sp: Record<string, string | string[] | undefined>): ListSort<QuoteSortKey> {
    return parseListSort(sp, Object.keys(QUOTE_SORT) as QuoteSortKey[], QUOTE_SORT_DEFAULT)
}

/** 导出路由的地址:带上当前排序(TABLE-EXPORT-1 Q2:导出按当前的排序取全体)。 */
export function quotesExportHref(sort: ListSort<QuoteSortKey>): string {
    return `/sales/quotes/export?${setSortParams(new URLSearchParams(), sort).toString()}`
}

export function quotesCount(supabase: Client) {
    return supabase.from('quote_status').select('quote_id', { count: 'exact', head: true })
}

export function quotesPage(supabase: Client, from: number, to: number, sort: ListSort<QuoteSortKey> = QUOTE_SORT_DEFAULT) {
    return applyListSort(
        supabase.from('quote_status')
            .select('quote_id, code, customer_code, customer_name, quote_date, valid_until, currency, status, expired, converted_order_id, converted_order_code, issue_version'),
        sort, QUOTE_SORT, [['quote_date', 'desc'], ['quote_id', 'asc']],
    )
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as QuoteRow[] | null }))
}
