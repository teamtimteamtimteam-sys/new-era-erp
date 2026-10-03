// app/finance/sourceLinks.ts
// 分录来源 → 业务单据链接的服务端解析。按 source_type 分组批量查一次(.in),
// 页级规模下开销可忽略;解析不到(单据已删/类型无落点)→ 无链接,纯文本展示。
//
// ★★【FIX-2a:那三张【基表】读的都是别的模块,而 cfo 一个模块都没有】★★
// 分录、总账、明细账三页的守卫是 module.finance.view;而这里读的
// inbound_batches / output_batches / processing_cost_entries 分别挂
// module.inbound.view / module.output.view / module.processing.view。
// cfo 只持 finance / logistics / purchasing —— 于是【每一条分录的来源链接都解析不到】,
// 而上面那句注释会把它读成「单据已删」。**那是一句关于数据的断言,
// 而真相是"你不能看那张表"。** 三处一律改读查名视图(体内都加了 finance.view),
// 它们【一列钱都不多出】—— 金额那一列在 processing_cost_entry_lookup 上
// 仍然按 data.view_prices 遮,而这里根本不选它。
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'

import { effectiveSources, type SourceRef } from './sourceLinkReversal'
export type { SourceRef }

// key: `${source_type}:${source_id}` → href
// ★ AUDIT-TRAIL-1c-1(Q15):一张冲销分录的 source_id 是【原分录】的 id —— 先换成原分录的来源再解析(sourceLinkReversal.ts)
export async function resolveSourceHrefs(
    supabase: SupabaseClient<Database>,
    refs0: SourceRef[]
): Promise<Map<string, string>> {
    const ids0 = Array.from(new Set(refs0.map((r) => r.source_id).filter(Boolean) as string[]))
    const journals = ids0.length
        ? mustRows(await supabase.from('journal_entries').select('id, source_type, source_id').in('id', ids0), 'reversal journals (Q15)')
        : []
    const eff = effectiveSources(refs0, journals)
    const refs = Array.from(eff.values())
    const resolved = await resolveDirect(supabase, refs)
    const hrefs = new Map<string, string>()
    for (const [key, r] of eff) {
        const h = resolved.get(`${r.source_type}:${r.source_id}`)
        if (h) hrefs.set(key, h)
    }
    return hrefs
}

async function resolveDirect(
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
            ? supabase.from('processing_cost_entry_lookup').select('id, run_id').in('id', costIds)
            : Promise.resolve({ data: [] as { id: string; run_id: string }[], error: null }),
        // writeoff 的 source_id 是批次 id,但不知道在哪张表 —— 两边都查,命中即得
        writeoffIds.length
            ? supabase.from('inbound_batch_lookup').select('id').in('id', writeoffIds)
            : Promise.resolve({ data: [] as { id: string }[], error: null }),
        writeoffIds.length
            ? supabase.from('output_batch_lookup').select('id').in('id', writeoffIds)
            : Promise.resolve({ data: [] as { id: string }[], error: null }),
    ])

    for (const s of mustRows(salesRes)) {
        hrefs.set(`sale:${s.id}`, `/output/${s.output_batch_id}/edit`)
    }
    for (const c of mustRows(costRes)) {
        hrefs.set(`processing_cost:${c.id}`, `/operation/processing/${c.run_id}`)
    }
    for (const b of mustRows(inWoRes)) {
        hrefs.set(`writeoff:${b.id}`, `/inbound/${b.id}/edit`)
    }
    for (const b of mustRows(outWoRes)) {
        hrefs.set(`writeoff:${b.id}`, `/output/${b.id}/edit`)
    }
    // 直接可拼的:purchase → 进料批次;allocation → 加工单;stocktake → 盘点单
    for (const id of purchaseIds) hrefs.set(`purchase:${id}`, `/inbound/${id}/edit`)
    for (const id of allocIds) hrefs.set(`allocation:${id}`, `/operation/processing/${id}`)
    for (const id of stocktakeIds) hrefs.set(`stocktake:${id}`, `/stocktakes/${id}`)

    return hrefs
}

export function sourceHrefKey(r: SourceRef): string {
    return `${r.source_type}:${r.source_id}`
}
