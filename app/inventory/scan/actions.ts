'use server'

// MES-3b(2026-10-07,MES-3b Step 0 Q22,Tim):/inventory/scan 扫到一批之后,读它此刻在哪些库位、各是什么状态、多少。
//   【问库,不算账】数字全部来自 stock_by_status(与批次页上的库存分布同一张视图),这里一个加减都不做。
//   批号与单位读那一批自己的表(进料批经 inbound_batches_masked;读策略:进料 / 产出查看 —— 扫得出 found 的人本来就持它)。
import { createClient } from '@/lib/supabase/server'
import { mustRows, mustOne } from '@/lib/db-helpers'

export type ScanBucket = { location_id: string | null; location_code: string | null; location_name: string | null; stock_status: string; qty: number }
export type ScannedBatch = { kind: 'inbound_batch' | 'output_batch'; id: string; code: string; unit: string; buckets: ScanBucket[] }

export async function scannedBatchStock(kind: 'inbound_batch' | 'output_batch', id: string): Promise<ScannedBatch> {
    const supabase = await createClient()
    // 进料批读遮蔽视图(code 与 unit 两列都不遮;直连基表是 check-masked-reads 拦的那一种)
    const head = kind === 'inbound_batch'
        ? mustOne(await supabase.from('inbound_batches_masked').select('code, unit').eq('id', id).single(), 'inbound_batches_masked')
        : mustOne(await supabase.from('output_batches').select('code, unit').eq('id', id).single(), 'output_batches')
    const q = supabase.from('stock_by_status').select('location_id, location_code, location_name, stock_status, qty')
    const rows = mustRows(await (kind === 'inbound_batch' ? q.eq('inbound_batch_id', id) : q.eq('output_batch_id', id)),
        'stock_by_status') as unknown as ScanBucket[]
    // 扫码刚说"看得见",这里却一行都没有 —— 那是一次失败(批次刚被删、读策略变了),不是一个空批次
    if (!head) throw new Error(`scannedBatchStock: ${kind} ${id} not readable`)
    const h = head as { code: string; unit: string }
    return { kind, id, code: h.code, unit: h.unit, buckets: rows.filter((r) => Number(r.qty) > 0) }
}
