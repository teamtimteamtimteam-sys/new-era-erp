import 'server-only'

// TABLE-EXPORT-2a(Tim 2026-10-22 Q2):汇率列表的【一份】读取 —— 页面与导出路由共用。
// 筛选与排序仍是 fxQuery.ts 的 applyFxFilters(那份也被客户端那张表 import 类型,所以不能是 server-only;
// 本文件才是只在服务端跑的那一半)。页面取一页,导出路由翻页取全(上限 50,000),同一套筛选与排序,
// 在它之后补 id —— 翻页取全要一个【唯一】的次序(同一天同一币种可以有几种牌价类型,排序键会并列)。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { formatDate } from '@/lib/dates'
import { getLocale } from '@/lib/i18n/server'
import { applyFxFilters, type FxListParams } from './fxQuery'
import type { FxRateRow } from './FxRatesTable'

type Client = SupabaseClient<Database>

export type FxDbRow = {
    id: string; currency: string; rate_type: string; rate_sgd_per_unit: number; rate_date: string; source: string; notes: string | null
}

export function fxCount(supabase: Client, p: FxListParams) {
    return applyFxFilters(supabase.from('fx_rates').select('id', { count: 'exact', head: true }), p)
}

export function fxPage(supabase: Client, p: FxListParams, from: number, to: number) {
    return applyFxFilters(
        supabase.from('fx_rates').select('id, currency, rate_type, rate_sgd_per_unit, rate_date, source, notes'),
        p,
    )
        .order('id', { ascending: true })
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as FxDbRow[] | null }))
}

/** 导出路由的地址:同一套筛选与排序,不带 page。 */
export function fxExportHref(p: FxListParams): string {
    const params = new URLSearchParams()
    if (p.currency) params.set('currency', p.currency)
    params.set('sort', p.sort)
    params.set('dir', p.dir)
    return `/finance/fx/export?${params.toString()}`
}

export async function shapeFxRows(rows: FxDbRow[]): Promise<FxRateRow[]> {
    const locale = await getLocale()
    return rows.map((r) => ({
        id: r.id,
        currency: r.currency,
        rateType: r.rate_type,
        rateSgdPerUnit: r.rate_sgd_per_unit,
        rateDate: formatDate(r.rate_date, locale),
        rateDateRaw: r.rate_date,
        source: r.source,
        notes: r.notes,
    }))
}
