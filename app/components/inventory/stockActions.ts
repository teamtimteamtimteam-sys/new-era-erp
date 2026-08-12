'use server'

// STK-1:暂扣 / 释放的服务端动作。
//
// 【页面不算库存】数量与拒绝全部由 hold_stock / release_stock 决定,这里只转达。
// 尤其是"还能扣多少" —— 那是按 批次 × 库位 × 状态 现算的派生仓位,
// 页面上显示的那个数只是【上一次渲染时】的快照,拿它做判断就会与服务端漂开。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeStockError } from './stockErrorCodes'

export type StockActionState = { error?: string }

function revalidateBatch(inboundId: string | null, outputId: string | null) {
    revalidatePath('/inventory')
    if (inboundId) revalidatePath(`/inbound/${inboundId}/edit`)
    if (outputId) revalidatePath(`/output/${outputId}/edit`)
}

export async function holdStockAction(
    inboundBatchId: string | null,
    outputBatchId: string | null,
    locationId: string | null,
    qty: string,
    reason: string
): Promise<StockActionState> {
    const supabase = await createClient()
    // 【按名传参,可选的就省略】两个批次父是二选一、库位可空 —— 它们在 SQL 侧
    // 都在默认值区(STK-1-fu2),所以这里不传就是 NULL,不必递一个 undefined 进去。
    const { error } = await supabase.rpc('hold_stock', {
        p_qty: Number(qty),
        p_reason: reason,
        ...(inboundBatchId ? { p_inbound_batch_id: inboundBatchId } : {}),
        ...(outputBatchId ? { p_output_batch_id: outputBatchId } : {}),
        ...(locationId ? { p_location_id: locationId } : {}),
    })
    if (error) return { error: await localizeStockError(error.message) }
    revalidateBatch(inboundBatchId, outputBatchId)
    return {}
}

export async function releaseStockAction(
    inboundBatchId: string | null,
    outputBatchId: string | null,
    locationId: string | null,
    qty: string,
    note: string
): Promise<StockActionState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('release_stock', {
        p_qty: Number(qty),
        ...(inboundBatchId ? { p_inbound_batch_id: inboundBatchId } : {}),
        ...(outputBatchId ? { p_output_batch_id: outputBatchId } : {}),
        ...(locationId ? { p_location_id: locationId } : {}),
        // 释放的备注可选 —— 空就是不写,不要塞一个空字符串进去
        ...(note.trim() === '' ? {} : { p_note: note.trim() }),
    })
    if (error) return { error: await localizeStockError(error.message) }
    revalidateBatch(inboundBatchId, outputBatchId)
    return {}
}
