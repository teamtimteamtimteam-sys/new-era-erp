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
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'
import type { GridRow } from './ContaminationGrid'

type Client = SupabaseClient<Database>

export const GRID_SHOWN = 300
export const RECENT_CHECKS_SHOWN = 50

type SP = Record<string, string | string[] | undefined>

// ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):两张表都只画前 N 行,所以都在数据库里排(先排、再取前 N 行)。
//   列键 → 读取那一张视图上的列(lib/listSort.ts 的规矩)。一页两张 → 第二张(最近的抽检)带前缀 `checks_`。
//   网格:班次与流的名字是查出来的、单号一格拼着「另 n 张」—— 不可排;状态按库里的码排。默认不变:加工日新的在前,
//   平局 (班次, 流) —— 与加工日一起正是一格的身份。
export const GRID_SORT = { date: 'process_date', state: 'check_state', rate: 'max_rate_pct' } as const
export type GridSortKey = keyof typeof GRID_SORT
const GRID_SORT_DEFAULT: ListSort<GridSortKey> = { key: 'date', dir: 'desc' }
export function parseGridSort(sp: SP): ListSort<GridSortKey> {
    return parseListSort(sp, Object.keys(GRID_SORT) as GridSortKey[], GRID_SORT_DEFAULT)
}
export function gridExportHref(sort: ListSort<GridSortKey>): string {
    return `/operation/contamination/grid/export?${setSortParams(new URLSearchParams(), sort).toString()}`
}
//   抽检:日期 · 班次、抽检那一句、警戒那一句都是拼出来的,流的名字是查出来的 —— 不可排。默认不变:id 降序(最新的在前)。
export const CHECKS_SORT_PREFIX = 'checks_'
export const CHECKS_SORT = { run: 'run_code', when: 'sampled_at' } as const
export type ChecksSortKey = keyof typeof CHECKS_SORT
// 默认那一个不在表头上(id 不是一列):用 run 作键会把默认改成按单号排,所以默认另记 —— 白名单里加一个不画的 id
const CHECKS_SORT_ALL = { ...CHECKS_SORT, id: 'id' } as const
type ChecksSortAllKey = keyof typeof CHECKS_SORT_ALL
const CHECKS_SORT_DEFAULT: ListSort<ChecksSortAllKey> = { key: 'id', dir: 'desc' }
export function parseChecksSort(sp: SP): ListSort<ChecksSortAllKey> {
    return parseListSort(sp, Object.keys(CHECKS_SORT_ALL) as ChecksSortAllKey[], CHECKS_SORT_DEFAULT, CHECKS_SORT_PREFIX)
}
export function checksExportHref(sort: ListSort<ChecksSortAllKey>): string {
    return `/operation/contamination/checks/export?${setSortParams(new URLSearchParams(), sort, CHECKS_SORT_PREFIX).toString()}`
}

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
export function gridPage(supabase: Client, sort: ListSort<GridSortKey>, from: number, to: number) {
    // TABLE-FEATURES-1 Q9:平局键照旧 (加工日 desc, 班次, 流)
    return applyListSort(
        supabase.from('contamination_shift_status')
            .select('process_date, shift_code, stream_code, first_run_id, first_run_code, run_codes, max_rate_pct, any_above_warning, check_state'),
        sort, GRID_SORT, [['process_date', 'desc'], ['shift_code', 'asc'], ['stream_code', 'asc']],
    ).range(from, to)
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
export function checksPage(supabase: Client, columns: string, sort: ListSort<ChecksSortAllKey>, from: number, to: number) {
    // TABLE-FEATURES-1 Q9:平局键照旧 id 降序(bigserial,唯一)
    return applyListSort(
        supabase.from('contamination_check_rows').select(columns).eq('is_current', true),
        sort, CHECKS_SORT_ALL, [['id', 'desc']],
    ).range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as unknown[] | null }))
}
