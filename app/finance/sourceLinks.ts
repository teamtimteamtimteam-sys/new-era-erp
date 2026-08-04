// app/finance/sourceLinks.ts
// 分录来源 → 业务单据链接的服务端解析。按 source_type 分组批量查一次(.in),
// 页级规模下开销可忽略;解析不到(单据已删/类型无落点)→ 无链接,纯文本展示。
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'

export type SourceRef = { source_type: string | null; source_id: string | null }

// key: `${source_type}:${source_id}` → href
export async function resolveSourceHrefs(
    supabase: SupabaseClient<Database>,
    refs: SourceRef[]
): Promise<Map<string, string>> {
    const hrefs = new Map<string, string>()

    const idsBy = (type: string) =>
        Array.from(
            new Set(
                refs
                    .filter((r) => r.source_type === type && r.source_id)
                    .map((r) => r.source_id as string)
            )
        )

    const saleIds = idsBy('sale')
    const purchaseIds = idsBy('purchase')
    const writeoffIds = idsBy('writeoff')
    const costIds = idsBy('processing_cost')
    const allocIds = idsBy('allocation')
    const stocktakeIds = idsBy('stocktake')

    const [salesRes, costRes, inWoRes, outWoRes] = await Promise.all([
        // sale → sales_records.output_batch_id → 产出批次编辑页
        saleIds.length
            ? supabase.from('sales_records').select('id, output_batch_id').in('id', saleIds)
            : Promise.resolve({ data: [] as { id: string; output_batch_id: string }[], error: null }),
        // processing_cost → 成本行的 run → 加工单详情
        costIds.length
            ? supabase.from('processing_cost_entries').select('id, run_id').in('id', costIds)
            : Promise.resolve({ data: [] as { id: string; run_id: string }[], error: null }),
        // writeoff 的 source_id 是批次 id,但不知道在哪张表 —— 两边都查,命中即得
        writeoffIds.length
            ? supabase.from('inbound_batches').select('id').in('id', writeoffIds)
            : Promise.resolve({ data: [] as { id: string }[], error: null }),
        writeoffIds.length
            ? supabase.from('output_batches').select('id').in('id', writeoffIds)
            : Promise.resolve({ data: [] as { id: string }[], error: null }),
    ])

    for (const s of mustRows(salesRes)) {
        hrefs.set(`sale:${s.id}`, `/output/${s.output_batch_id}/edit`)
    }
    for (const c of mustRows(costRes)) {
        hrefs.set(`processing_cost:${c.id}`, `/processing/${c.run_id}`)
    }
    for (const b of mustRows(inWoRes)) {
        hrefs.set(`writeoff:${b.id}`, `/inbound/${b.id}/edit`)
    }
    for (const b of mustRows(outWoRes)) {
        hrefs.set(`writeoff:${b.id}`, `/output/${b.id}/edit`)
    }
    // 直接可拼的:purchase → 进料批次;allocation → 加工单;stocktake → 盘点单
    for (const id of purchaseIds) hrefs.set(`purchase:${id}`, `/inbound/${id}/edit`)
    for (const id of allocIds) hrefs.set(`allocation:${id}`, `/processing/${id}`)
    for (const id of stocktakeIds) hrefs.set(`stocktake:${id}`, `/stocktakes/${id}`)

    return hrefs
}

export function sourceHrefKey(r: SourceRef): string {
    return `${r.source_type}:${r.source_id}`
}
