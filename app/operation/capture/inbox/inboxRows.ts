import 'server-only'

// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2 的第二条)· 数据收件箱:真的翻页,不是一句「前 N 条」
// ════════════════════════════════════════════════════════════════════════════
// 从前这一页一句不说地只读最新的 200 行(.limit(200)),而线上 ingest_inbox 有 2,005 行(TABLE-EXPORT-2b Step 0 实测,
// 以 postgres 读基表)—— 第 201 行起在屏幕上永远看不到。Tim 的裁定:这一页翻页(?page=),导出取全部匹配行(上限 50,000)。
// 读取、筛选(?status=)与导出格只在这里一份,页面与导出路由(./export/route.ts)共用。排序 id 降序 —— id 是 bigserial,唯一。
// ════════════════════════════════════════════════════════════════════════════

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { xText, xInt, xTime, type ExportCell } from '@/lib/export/cells'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'

type Client = SupabaseClient<Database>
type T = (key: string, values?: Record<string, string | number>) => string

/** 一页多少行 —— 与转换之前首屏同一个数。 */
export const INBOX_PAGE_SIZE = 200

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):翻页的列表在数据库里排 —— 列键 → `ingest_inbox` 上的列(lib/listSort.ts 的规矩)。
 *   仪器与数据类别的名字是查出来的、流 · 序号是拼出来的,不可排;状态按库里的码排。默认不变:id 降序(最新的在前)。
 */
export const INBOX_SORT = { id: 'id', at: 'received_at', status: 'status' } as const
export type InboxSortKey = keyof typeof INBOX_SORT
const INBOX_SORT_DEFAULT: ListSort<InboxSortKey> = { key: 'id', dir: 'desc' }
export function parseInboxSort(sp: Record<string, string | string[] | undefined>): ListSort<InboxSortKey> {
    return parseListSort(sp, Object.keys(INBOX_SORT) as InboxSortKey[], INBOX_SORT_DEFAULT)
}
/** 导出路由的地址:同一条筛选与排序,不带 page。 */
export function inboxExportHref(status: string | null, sort: ListSort<InboxSortKey>): string {
    const q = new URLSearchParams()
    if (status) q.set('status', status)
    setSortParams(q, sort)
    return `/operation/capture/inbox/export?${q.toString()}`
}

export const INBOX_STATUSES = ['received', 'failed', 'awaiting_transform', 'transformed', 'discarded'] as const

export type InboxRow = {
    id: number; received_at: string; source: string; device_id: string | null; data_class: string; stream: string | null
    seq: number | null; status: string; error_code: string | null; attempts: number; payload: unknown
    transform_result: unknown; discard_reason: string | null; clock_ahead: boolean
}

/** 不认识的状态当作「全部」—— 与转换之前同一条规则。 */
export function inboxStatus(raw: string | null | undefined): string | null {
    return (INBOX_STATUSES as readonly string[]).includes(raw ?? '') ? raw! : null
}

export function inboxCount(supabase: Client, status: string | null) {
    let q = supabase.from('ingest_inbox').select('id', { count: 'exact', head: true })
    if (status) q = q.eq('status', status)
    return q
}

export function inboxPage(supabase: Client, status: string | null, sort: ListSort<InboxSortKey>, from: number, to: number) {
    let q = supabase.from('ingest_inbox')
        .select('id, received_at, source, device_id, data_class, stream, seq, status, error_code, attempts, payload, transform_result, discard_reason, clock_ahead')
    if (status) q = q.eq('status', status)
    // TABLE-FEATURES-1 Q9:选中的列,再按 id 降序平局(id 唯一)
    return applyListSort(q, sort, INBOX_SORT, [['id', 'desc']]).range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as InboxRow[] | null }))
}

export type InboxLabels = { devices: Map<string, string>; classes: Map<string, string> }

export async function inboxLabels(supabase: Client, locale: string): Promise<InboxLabels> {
    const [devRes, classRes] = await Promise.all([
        supabase.from('devices').select('id, code'),
        supabase.from('ingest_data_classes').select('code, name_en, name_zh'),
    ])
    return {
        devices: new Map((mustRows(devRes, 'devices') as { id: string; code: string }[]).map((d) => [d.id, d.code])),
        classes: new Map((mustRows(classRes, 'ingest_data_classes') as { code: string; name_en: string; name_zh: string }[])
            .map((c) => [c.code, locale === 'zh' ? c.name_zh : c.name_en])),
    }
}

/** TABLE-EXPORT-1:编号是整数、收到是真时刻;状态那一格屏幕上挂着的错误码 / 丢弃理由 / 重试次数一并写出;
 *  载荷与转换结果写成一行 JSON(屏幕上是展开才看得见的同一份) */
export function inboxExports(r: InboxRow, lb: InboxLabels, t: T): Record<string, ExportCell> {
    return {
        id: xInt(r.id),
        at: xTime(r.received_at),
        device: xText(r.device_id && lb.devices.get(r.device_id) ? lb.devices.get(r.device_id)! : t('inbox.manual')),
        dataClass: xText(lb.classes.get(r.data_class) ?? r.data_class),
        seq: xText(r.stream ? `${r.stream} · ${r.seq}` : '—'),
        status: xText([
            t('inbox.status.' + r.status),
            r.error_code,
            r.discard_reason,
            r.attempts > 1 ? t('inbox.attempts', { n: String(r.attempts) }) : null,
        ].filter(Boolean).join(' · ')),
        payload: xText(JSON.stringify(r.payload) + (r.transform_result != null ? ` · ${JSON.stringify(r.transform_result)}` : '')),
    }
}
