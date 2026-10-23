import 'server-only'

// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-2b-2 · 确认队列上两张只读前 N 行的表 —— 页面与导出路由共用的读取与导出格
// ════════════════════════════════════════════════════════════════════════════
// 「等确认的草稿」(PENDING_SHOWN = 200,最老的在前 —— 等得最久的先处理)与「最近确认的称重」(RECENT_SHOWN = 50,
// Tim 2026-10-23 TABLE-EXPORT-2b Q1)从前都一句不说地截断。现在页面画前 N 行、表上方 RowCapNotice 说出「前 N 条,共 M 条」,
// 导出路由(./pending/export · ./recent/export)按同一条读取翻页取全(上限 50,000,Tim TABLE-EXPORT-2 Q2)。
// 导出格(exports)只在这里造一份:页面用它配上画好的格子,路由原样交回 —— 列只有一份定义。
// 排序补唯一键(草稿 id / 称重 id)—— 翻页要一个【唯一】的次序。
// ════════════════════════════════════════════════════════════════════════════

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { inChunks } from '@/lib/export/serverRows'
import { xText, xNum, xInt, xTime, type ExportCell } from '@/lib/export/cells'

type Client = SupabaseClient<Database>
type T = (key: string, values?: Record<string, string | number>) => string

export const PENDING_SHOWN = 200
export const RECENT_SHOWN = 50

export type Draft = {
    id: string; inbox_id: number; device_id: string | null; station: string | null; proposed: { weight_kg?: number }
    source: string; created_at: string
}
export type Weighing = {
    weighing_id: string; ticket_id: string | null; role: string; weight_kg: number; source: string; device_code: string | null
    captured_at: string; is_current: boolean; status: string
}
export type DeviceRef = { id: string; code: string }

// 一张草稿等了几整天(永不过期,MES-0 Q13)。放在组件外:渲染里直接读时钟是 react-hooks/purity 拦的那一类。
export function ageInDays(createdAt: string): number {
    return Math.max(0, Math.floor((Date.now() - new Date(createdAt).getTime()) / 86_400_000))
}

// ── 等确认的草稿 ────────────────────────────────────────────────────────────
export function pendingCount(supabase: Client) {
    return supabase.from('capture_drafts').select('id', { count: 'exact', head: true }).eq('status', 'pending')
}
export function pendingPage(supabase: Client, from: number, to: number) {
    return supabase.from('capture_drafts').select('id, inbox_id, device_id, station, proposed, source, created_at')
        .eq('status', 'pending').order('created_at').order('id').range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as Draft[] | null }))
}
/** TABLE-EXPORT-1:导出读原始值 —— 读数是一个数(kg),收到是真时刻,等了几天是整数 */
export function draftExports(d: Draft, dev: DeviceRef | null | undefined, kgUnit: string): Record<string, ExportCell> {
    const kg = Number(d.proposed?.weight_kg ?? 0)
    return {
        weight: xNum(kg, 'qty', kgUnit), // TABLE-EXPORT-1:屏幕上是「12 kg」(capture.kg),单位一起写
        device: xText(dev ? dev.code : '—'),
        station: xText(d.station ?? '—'),
        received: xTime(d.created_at),
        age: xInt(ageInDays(d.created_at)),
    }
}

// ── 最近确认的称重 ──────────────────────────────────────────────────────────
export function recentCount(supabase: Client) {
    return supabase.from('weighing_calibration').select('weighing_id', { count: 'exact', head: true })
}
export function recentPage(supabase: Client, from: number, to: number) {
    return supabase.from('weighing_calibration').select('weighing_id, ticket_id, role, weight_kg, source, device_code, captured_at, is_current, status')
        .order('captured_at', { ascending: false }).order('weighing_id').range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as Weighing[] | null }))
}

export type WeighingLookups = {
    changesByWeighing: Map<string, { original_value: unknown; confirmed_value: unknown; reason: string }>
    correctionReason: Map<string, string>
    tickets: Map<string, string>
}

/** 改过的值(capture_draft_changes)、更正理由与地磅单号 —— 按 id 分批反查(导出一次可以有几万个 id)。 */
export async function weighingLookups(supabase: Client, weighings: Weighing[]): Promise<WeighingLookups> {
    const changesByWeighing: WeighingLookups['changesByWeighing'] = new Map()
    const correctionReason = new Map<string, string>()
    const tickets = new Map<string, string>()
    const wIds = weighings.map((w) => w.weighing_id)
    if (wIds.length > 0) {
        const wr = await inChunks(wIds, (c) => supabase.from('weighings').select('id, draft_id, correction_reason, corrects_id').in('id', c)
            .then(({ data, error }) => ({ error, data: data as { id: string; draft_id: string; correction_reason: string | null; corrects_id: string | null }[] | null })), 'weighings')
        const draftOf = new Map(wr.map((w) => [w.draft_id, w.id]))
        wr.forEach((w) => { if (w.correction_reason) correctionReason.set(w.id, w.correction_reason) })
        const ch = await inChunks([...draftOf.keys()], (c) => supabase.from('capture_draft_changes').select('draft_id, original_value, confirmed_value, reason').in('draft_id', c)
            .then(({ data, error }) => ({ error, data: data as { draft_id: string; original_value: unknown; confirmed_value: unknown; reason: string }[] | null })), 'capture_draft_changes')
        ch.forEach((c) => { const w = draftOf.get(c.draft_id); if (w) changesByWeighing.set(w, c) })
    }
    const tIds = [...new Set(weighings.map((w) => w.ticket_id).filter((x): x is string => !!x))]
    if (tIds.length > 0) {
        const tr = await inChunks(tIds, (c) => supabase.from('weighbridge_tickets').select('id, code').in('id', c)
            .then(({ data, error }) => ({ error, data: data as { id: string; code: string }[] | null })), 'weighbridge_tickets')
        tr.forEach((x) => tickets.set(x.id, x.code))
    }
    return { changesByWeighing, correctionReason, tickets }
}

/** TABLE-EXPORT-1:重量是一个数;屏幕上挂在它下面的「改过 / 更正」两句与仪器下面的校准状态,导出同样写出来(读者不必回屏幕看) */
export function weighingExports(w: Weighing, lk: WeighingLookups, t: T, kgUnit: string): Record<string, ExportCell> {
    return {
        at: xTime(w.captured_at),
        weight: xNum(w.weight_kg, 'qty', kgUnit),
        role: xText(w.ticket_id ? `${t('weighing.role.' + w.role)} · ${lk.tickets.get(w.ticket_id) ?? '—'}` : t('weighing.role.' + w.role)),
        instrument: xText(`${w.device_code ?? '—'} · ${t('calibration.status.' + w.status)}`),
        source: xText(t('capture.source.' + w.source)),
    }
}

/** 路由用:设备 id → 编号(草稿那一张的「仪器」一列)。 */
export async function deviceRefs(supabase: Client): Promise<Map<string, DeviceRef>> {
    const devs = mustRows(await supabase.from('devices').select('id, code'), 'devices') as DeviceRef[]
    return new Map(devs.map((d) => [d.id, d]))
}
