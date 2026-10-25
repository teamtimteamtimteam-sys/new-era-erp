import 'server-only'

// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):地磅单清单的【一份】读取与导出格 —— 页面与导出路由共用。
// 页面只画最新的 TICKETS_SHOWN 张(从前是一句不说的 .limit(200)),表上方 RowCapNotice 说出「前 N 张,共 M 张」;
// 导出路由按同一条读取翻页取全(上限 50,000)。排序在建单时刻之后补 ticket_id —— 翻页要一个【唯一】的次序。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { xText, xNum, xTime, type ExportCell } from '@/lib/export/cells'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'

type Client = SupabaseClient<Database>
type T = (key: string, values?: Record<string, string | number>) => string

export const TICKETS_SHOWN = 200

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):只画前 200 张 —— 在数据库里排(先排、再取前 N 张)。
 *   列键 → `weighbridge_ticket_weights` 上的列(lib/listSort.ts 的规矩);方向与状态按库里的码排。
 *   「已分」不可排:净重没有时屏幕上是「—」,而视图上的 shared_kg 仍是一个数 —— 按它排会把「—」排成 0。
 *   默认不变:建单时刻新的在前,平局 ticket_id。
 */
export const TICKET_SORT = {
    code: 'code', vehicle: 'vehicle_reg', direction: 'direction', status: 'status',
    gross: 'gross_kg', tare: 'tare_kg', net: 'net_kg', created: 'created_at',
} as const
export type TicketSortKey = keyof typeof TICKET_SORT
const TICKET_SORT_DEFAULT: ListSort<TicketSortKey> = { key: 'created', dir: 'desc' }
export function parseTicketSort(sp: Record<string, string | string[] | undefined>): ListSort<TicketSortKey> {
    return parseListSort(sp, Object.keys(TICKET_SORT) as TicketSortKey[], TICKET_SORT_DEFAULT)
}
export function ticketsExportHref(sort: ListSort<TicketSortKey>): string {
    return `/operation/weighbridge/export?${setSortParams(new URLSearchParams(), sort).toString()}`
}

export type Ticket = {
    ticket_id: string; code: string; direction: string; vehicle_reg: string; status: string; created_at: string
    gross_kg: number | null; tare_kg: number | null; net_kg: number | null; shared_kg: number; difference_kg: number | null
}

export function ticketsCount(supabase: Client) {
    return supabase.from('weighbridge_ticket_weights').select('ticket_id', { count: 'exact', head: true })
}

export function ticketsPage(supabase: Client, sort: ListSort<TicketSortKey>, from: number, to: number) {
    // TABLE-FEATURES-1 Q9:平局键照旧 created_at desc → ticket_id
    return applyListSort(
        supabase.from('weighbridge_ticket_weights')
            .select('ticket_id, code, direction, vehicle_reg, status, created_at, gross_kg, tare_kg, net_kg, shared_kg, difference_kg'),
        sort, TICKET_SORT, [['created_at', 'desc'], ['ticket_id', 'asc']],
    ).range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as Ticket[] | null }))
}

// TABLE-EXPORT-1:四个重量是公斤数(原始值,没有就空 —— 屏幕上是「—」,不是 0);建单时刻是真时刻。
//   「已分」那一格屏幕上挂着的差额那一句不进数字格(它是一个提示,不是这一格的值)
// TABLE-EXPORT-1:屏幕上四个重量都是「12 kg」(capture.kg),单位用同一个本地化标签 units.kg 一起写
export function ticketExports(x: Ticket, t: T, kgUnit: string): Record<string, ExportCell> {
    return {
        code: xText(x.code),
        vehicle: xText(x.vehicle_reg),
        direction: xText(t('weighbridge.direction.' + x.direction)),
        status: xText(t('weighbridge.status.' + x.status)),
        gross: xNum(x.gross_kg, 'qty', kgUnit),
        tare: xNum(x.tare_kg, 'qty', kgUnit),
        net: xNum(x.net_kg, 'qty', kgUnit),
        shared: xNum(x.net_kg == null ? null : x.shared_kg, 'qty', kgUnit),
        created: xTime(x.created_at),
    }
}
