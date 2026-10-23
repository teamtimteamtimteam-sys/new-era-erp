import 'server-only'

// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-2b-2 · /operation/contamination 上两张只读前 N 行的表与一个数 —— 页面与导出路由共用
// ════════════════════════════════════════════════════════════════════════════
// · 每班一格的网格:页面画最新的 GRID_SHOWN(300)格,说出「前 N 条,共 M 条」,导出取全(Tim 2026-10-22 TABLE-EXPORT-2 Q2)。
// · 「最近的抽检」:页面画最新的 RECENT_CHECKS_SHOWN(50)次,同样说出来、导出取全(Tim 2026-10-23 TABLE-EXPORT-2b Q1)。
// · 「缺几格」那个数从前数的是截下来的 300 格(page.tsx 旧 :55)—— 第 301 格起缺了也不算。现在是一次 count(exact)
//   (Tim 2026-10-23 TABLE-EXPORT-2b Q6)。check_state 只有三个值(contamination_shift_status_all:checked · not_sampled ·
//   missing,ELSE 给 missing,从不为空),所以 `= 'missing'` 与页面「其余都算 missing」是同一条判据。
// 排序补唯一键:网格按 (加工日, 班次, 流) —— 那正是一格的身份;抽检按 id(bigserial)。
// ════════════════════════════════════════════════════════════════════════════

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { formatDate } from '@/lib/dates'
import type { GridRow } from './ContaminationGrid'

type Client = SupabaseClient<Database>

export const GRID_SHOWN = 300
export const RECENT_CHECKS_SHOWN = 50

type GridDb = {
    process_date: string; shift_code: string; stream_code: string; first_run_id: string; first_run_code: string; run_codes: string[]
    max_rate_pct: number | null; any_above_warning: boolean | null; check_state: string
}

export function gridCount(supabase: Client) {
    return supabase.from('contamination_shift_status').select('process_date', { count: 'exact', head: true })
}
export function missingCount(supabase: Client) {
    return supabase.from('contamination_shift_status').select('process_date', { count: 'exact', head: true }).eq('check_state', 'missing')
}
export function gridPage(supabase: Client, from: number, to: number) {
    return supabase.from('contamination_shift_status')
        .select('process_date, shift_code, stream_code, first_run_id, first_run_code, run_codes, max_rate_pct, any_above_warning, check_state')
        .order('process_date', { ascending: false }).order('shift_code').order('stream_code').range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as GridDb[] | null }))
}
export function shapeGridRows(grid: GridDb[], labels: { stream: (c: string) => string; shift: (c: string | null) => string },
                              locale: string, canOpenRuns: boolean): GridRow[] {
    return grid.map((g) => ({
        key: `${g.process_date}|${g.shift_code}|${g.stream_code}`,
        date: formatDate(g.process_date, locale), processDate: g.process_date, shift: labels.shift(g.shift_code), stream: labels.stream(g.stream_code),
        state: g.check_state === 'checked' ? 'checked' : g.check_state === 'not_sampled' ? 'not_sampled' : 'missing',
        maxRate: g.max_rate_pct === null ? null : Number(g.max_rate_pct), anyAbove: g.any_above_warning,
        runCode: g.first_run_code, runHref: canOpenRuns ? `/operation/processing/${g.first_run_id}` : null,
        runCount: (g.run_codes ?? []).length,
    }))
}

export function checksCount(supabase: Client) {
    return supabase.from('contamination_check_rows').select('id', { count: 'exact', head: true }).eq('is_current', true)
}
export function checksPage(supabase: Client, columns: string, from: number, to: number) {
    return supabase.from('contamination_check_rows').select(columns).eq('is_current', true)
        .order('id', { ascending: false }).range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as unknown[] | null }))
}
