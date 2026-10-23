import 'server-only'

// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):报价清单的【一份】读取 —— 页面与导出路由共用。
// 页面只画最新的 QUOTES_SHOWN 张(从前是一句不说的 .limit(200)),表上方 RowCapNotice 说出「前 N 张,共 M 张」;
// 导出路由按同一条读取翻页取全(上限 50,000)。读的仍是 quote_status(过期是算出来的,见页面抬头);排序补 quote_id 作唯一次序。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import type { QuoteRow } from './QuotesTable'

type Client = SupabaseClient<Database>

/** 页面画多少张 —— 与转换之前同一个数。 */
export const QUOTES_SHOWN = 200

export function quotesCount(supabase: Client) {
    return supabase.from('quote_status').select('quote_id', { count: 'exact', head: true })
}

export function quotesPage(supabase: Client, from: number, to: number) {
    return supabase.from('quote_status')
        .select('quote_id, code, customer_code, customer_name, quote_date, valid_until, currency, status, expired, converted_order_id, converted_order_code, issue_version')
        .order('quote_date', { ascending: false })
        .order('quote_id', { ascending: true })
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as QuoteRow[] | null }))
}
