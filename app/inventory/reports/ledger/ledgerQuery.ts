// RPT-1:流水台账的取数 + 过滤。页面、CSV、PDF 三处共用这一份。
//
// 【只有这张表需要界】它是 append-only 的流水,只会变长(今天 85 行);
// 另外三张的行数由当下的库存状态决定,不随时间增长 —— 理由写在
// reportShared.LEDGER_DEFAULT_DAYS 上。默认窗口 90 天,可改,可清空;
// 【清空是一个明确的动作】,不是默认 —— 默认无界的报表迟早在最忙的页面上变慢。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { defaultLedgerFrom } from '../reportShared'

export type LedgerParams = { from: string; to: string; materialId: string; batchCode: string }

export type LedgerRow = {
    id: string; business_date: string | null; occurred_at: string; movement_type: string
    qty_delta: number; stock_status: string; location_id: string | null
    inbound_batch_id: string | null; output_batch_id: string | null; notes: string | null
    storage_locations: { code: string } | null
    inbound_batches: { code: string; materials: { code: string; name: string } | null } | null
    output_batches: { code: string; materials: { code: string; name: string } | null } | null
}

export function parseLedgerParams(sp: Record<string, string | undefined>): LedgerParams {
    return {
        from: (sp.from ?? '').trim() || defaultLedgerFrom(),
        to: (sp.to ?? '').trim() || '',
        materialId: (sp.material_id ?? '').trim(),
        batchCode: (sp.batch ?? '').trim(),
    }
}

export function describeFilters(p: LedgerParams): string {
    const bits = [`${p.from || '…'} → ${p.to || '…'}`]
    if (p.materialId) bits.push(`material=${p.materialId}`)
    if (p.batchCode) bits.push(`batch=${p.batchCode}`)
    return bits.join(' · ')
}

export async function fetchLedger(p: LedgerParams): Promise<LedgerRow[]> {
    const supabase = await createClient()
    let q = supabase
        .from('inventory_movements')
        .select(`id, business_date, occurred_at, movement_type, qty_delta, stock_status,
                 location_id, inbound_batch_id, output_batch_id, notes,
                 storage_locations ( code ),
                 inbound_batches ( code, materials ( code, name ) ),
                 output_batches ( code, materials ( code, name ) )`)
        .order('business_date', { ascending: false, nullsFirst: false })
        .order('occurred_at', { ascending: false })
        .limit(2000)

    if (p.from) q = q.gte('business_date', p.from)
    if (p.to) q = q.lte('business_date', p.to)

    const rows = mustRows(await q, 'inventory_movements') as unknown as LedgerRow[]

    // 物料与批次号在【嵌入的关联行】上,PostgREST 不便直接过滤 —— 行数已由日期
    // 窗与 2000 上限收住,所以这一步在这里筛。【上限是明写的】:超过就该收窄日期,
    // 而不是让首屏拖着一整年的流水。
    return rows.filter((r) => {
        const mat = r.inbound_batches?.materials ?? r.output_batches?.materials ?? null
        const batchCode = r.inbound_batches?.code ?? r.output_batches?.code ?? ''
        if (p.materialId && mat?.code !== p.materialId) return false
        if (p.batchCode && !batchCode.toLowerCase().includes(p.batchCode.toLowerCase())) return false
        return true
    })
}

export const flatten = (r: LedgerRow) => {
    const mat = r.inbound_batches?.materials ?? r.output_batches?.materials ?? null
    return {
        date: r.business_date ?? '',
        batch: r.inbound_batches?.code ?? r.output_batches?.code ?? '',
        material: mat ? `${mat.code} ${mat.name}` : '',
        materialCode: mat?.code ?? '',
        location: r.storage_locations?.code ?? '',
        type: r.movement_type,
        status: r.stock_status,
        qty: r.qty_delta,
        notes: r.notes ?? '',
    }
}
