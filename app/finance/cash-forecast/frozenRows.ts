import 'server-only'

// TABLE-EXPORT-2a(Tim 2026-10-22,TABLE-EXPORT-2 Q2):「已冻结的预测」登记簿的【一份】读取 —— 页面与导出路由共用。
// 页面只画最近 FROZEN_SHOWN 张(从前是一句不说的 .limit(20)),表上方 RowCapNotice 说出「前 N 张,共 M 张」;
// 导出路由按同一条读取翻页取全(上限 50,000)。排序在 week_start 之后补 id —— 翻页要一个【唯一】的次序
// (同一周冻结过两次:被取代的那张与取代它的那张,week_start 相同)。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import type { FrozenRow } from './FrozenForecastsTable'

type Client = SupabaseClient<Database>

/** 页面画多少张 —— 与转换之前同一个数。 */
export const FROZEN_SHOWN = 20

export function frozenCount(supabase: Client) {
    return supabase.from('cash_forecasts').select('id', { count: 'exact', head: true })
}

export function frozenPage(supabase: Client, from: number, to: number) {
    return supabase
        .from('cash_forecasts')
        .select('id, code, week_start, frozen_at, superseded_at')
        .order('week_start', { ascending: false })
        .order('id', { ascending: true })
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as FrozenRow[] | null }))
}
