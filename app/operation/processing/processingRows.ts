import 'server-only'

// TABLE-EXPORT-1(Tim 2026-10-22 Q2):加工单列表的【一份】读取 —— 页面与导出路由共用(照 app/materials/materialRows.ts 的样子)。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts);两者走同一个 select、同一套筛选(applyProcessingFilters)、
// 同一个「库里的行 → 表的行」映射,于是导出不可能比屏幕多一列或多一种口径。
// 排序在页面自己的排序列之后补一个 id —— 翻页取全要求一个【唯一】的次序(同一天的两张单不再随机互换)。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatDate } from '@/lib/dates'
import { processingStatusLabelKey } from '../status'
import { applyProcessingFilters, type ProcessingListParams } from '../processingQuery'
import type { ProcessingRunRow } from './ProcessingTable'

type Client = SupabaseClient<Database>

export const PROCESSING_LIST_SELECT =
    'id, code, process_date, total_input, total_output, loss_qty, status, created_at, work_order_id'

export function processingCount(supabase: Client, params: ProcessingListParams) {
    return applyProcessingFilters(supabase.from('processing_runs').select('id', { count: 'exact', head: true }), params)
}

export function processingPage(supabase: Client, params: ProcessingListParams, from: number, to: number) {
    return applyProcessingFilters(supabase.from('processing_runs').select(PROCESSING_LIST_SELECT), params)
        .order('id', { ascending: true })
        .range(from, to)
}

type ProcessingDbRow = NonNullable<Awaited<ReturnType<typeof processingPage>>['data']>[number]

/** 一个 .in() 里塞几万个 id 会把 URL 撑破;每批 200 个 id,结果行同样受 max_rows 管,所以每批再翻页。 */
async function inChunks<R>(ids: string[], read: (chunk: string[], from: number, to: number) => PromiseLike<{ data: R[] | null; error: { message: string } | null }>, what: string): Promise<R[]> {
    const out: R[] = []
    for (let i = 0; i < ids.length; i += 200) {
        const chunk = ids.slice(i, i + 200)
        for (let from = 0; ; from += 1000) {
            const got = mustRows(await read(chunk, from, from + 999), what)
            out.push(...got)
            if (got.length === 0) break
        }
    }
    return out
}

export async function shapeProcessingRows(supabase: Client, runs: ProcessingDbRow[]): Promise<ProcessingRunRow[]> {
    const t = await getTranslations()
    const locale = await getLocale()

    // 状态标签(未知值回退原样)
    const statusLabel = (v: string | null) => {
        const k = processingStatusLabelKey(v)
        return k ? t(k) : v ?? '—'
    }

    // WO-1c:把这些单上出现的工单编号一次取回来 —— 逐行去查会是 N+1。
    const woIds = Array.from(new Set(runs.map((r) => r.work_order_id).filter((x): x is string => !!x)))
    const woCode = new Map<string, string>()
    const woRows = await inChunks<{ id: string; code: string }>(woIds,
        (chunk, from, to) => supabase.from('work_orders').select('id, code').in('id', chunk).order('id').range(from, to), 'work_orders')
    woRows.forEach((w) => woCode.set(w.id, w.code))

    // MES-4a(Q19–Q21):每一炉的物料平衡状态 —— 读 processing_run_balance(结算函数读的是同一张底视图)。
    const runIds = runs.map((r) => r.id)
    const balanceState = new Map<string, string>()
    const bRows = await inChunks<{ run_id: string | null; balance_state: string | null }>(runIds,
        (chunk, from, to) => supabase.from('processing_run_balance').select('run_id, balance_state').in('run_id', chunk).order('run_id').range(from, to),
        'processing_run_balance')
    bRows.forEach((b) => { if (b.run_id && b.balance_state) balanceState.set(b.run_id, b.balance_state) })

    return runs.map((r) => ({
        id: r.id,
        code: r.code,
        processDate: formatDate(r.process_date, locale) ?? '—',
        totalInput: r.total_input != null ? String(r.total_input) : '—',
        totalOutput: r.total_output != null ? String(r.total_output) : '—',
        lossLabel:
            (r.loss_qty != null ? String(r.loss_qty) : '—') +
            (r.loss_qty != null && r.total_input ? ` (${((r.loss_qty / r.total_input) * 100).toFixed(1)}%)` : ''),
        statusLabel: statusLabel(r.status),
        workOrderId: r.work_order_id,
        workOrderCode: r.work_order_id ? (woCode.get(r.work_order_id) ?? '—') : '—',
        balanceState: balanceState.get(r.id) ?? null,
        // TABLE-EXPORT-1:导出用的原始值(Excel 里是数与真日期,不是排好的字)
        processDateRaw: r.process_date,
        totalInputQty: r.total_input,
        totalOutputQty: r.total_output,
        lossQty: r.loss_qty,
    }))
}
