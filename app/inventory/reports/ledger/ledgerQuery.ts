// RPT-1:流水台账的取数 + 过滤。页面、CSV、PDF 三处共用这一份。
//
// 【只有这张表需要界】它是 append-only 的流水,只会变长(今天 85 行);
// 另外三张的行数由当下的库存状态决定,不随时间增长 —— 理由写在
// reportShared.LEDGER_DEFAULT_DAYS 上。默认窗口 90 天,可改,可清空;
// 【清空是一个明确的动作】,不是默认 —— 默认无界的报表迟早在最忙的页面上变慢。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { defaultLedgerFrom } from '../reportShared'

export type LedgerParams = {
    from: string; to: string; materialId: string; batchCode: string
    /**
     * ★★【CONV-6 ⑥ 的扫尾:一条【指名一条流水】的筛选,此前根本不存在】★★
     * 被删记录页(app/settings/deleted/page.tsx:153)一直在发
     * `/inventory/reports/ledger?movement=<id>` 这样的链接 ——
     * **而这一页从来没有读过 movement 这个参数。** 点下去参数被静默丢掉,
     * 人落在一张默认 90 天的完整流水上,再自己去里面找那一条。
     * 屏幕上"筛到了"与"没筛"长得一模一样,所以没有人发现。
     * 它是 CONV-6 ⑥ 那条新判据(带参数的链接,目标页必须真的读那个参数)
     * 扫出来的【第二处】,而它不是搬家造成的 —— 这个参数【一次都没有实现过】。
     */
    movementId: string
}

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
        movementId: (sp.movement ?? '').trim(),
    }
}

export function describeFilters(p: LedgerParams): string {
    // 【指名一条流水时,日期窗不参与描述】—— 它本来就没有生效(见 fetchLedger)
    if (p.movementId) return `movement=${p.movementId}`
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

    // ★【指名一条流水时,【不】套那个 90 天默认窗】★
    //   这一条要是漏了,这次修复就修出一个更坏的东西:一个被删了一年的批次,
    //   它的注销流水落在窗外,页面会画出【一张自信的空表】——
    //   而"这条流水不在这个日期区间里"与"这条流水不存在"在屏幕上分不开。
    //   本仓库为这条区别付过账(gl_control_reconciliation 的「照答会返回一个
    //   自信的 0.00」是同一句话的另一处)。指名一条 id 是一次【定位】,不是一次浏览。
    if (p.movementId) {
        q = q.eq('id', p.movementId)
    } else {
        if (p.from) q = q.gte('business_date', p.from)
        if (p.to) q = q.lte('business_date', p.to)
    }

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
