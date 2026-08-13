'use server'

// STK-1:暂扣 / 释放的服务端动作。
//
// 【页面不算库存】数量与拒绝全部由 hold_stock / release_stock 决定,这里只转达。
// 尤其是"还能扣多少" —— 那是按 批次 × 库位 × 状态 现算的派生仓位,
// 页面上显示的那个数只是【上一次渲染时】的快照,拿它做判断就会与服务端漂开。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeStockError, localizeStockWarnings, warningCodesFrom } from './stockErrorCodes'

// IOD-2:warnings —— 【这一次成功了,但有件事没人决定过】。与 error 分开两个字段,
// 因为它们不是同一件事:有 error 时什么都没写,有 warnings 时东西已经写进去了。
export type StockActionState = { error?: string; warnings?: string[] }

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

// IOD-1:转移 —— 把一个桶的数量搬到另一个库位。【状态原样带过去】。
export async function transferStockAction(
    inboundBatchId: string | null,
    outputBatchId: string | null,
    fromLocationId: string | null,
    toLocationId: string,
    qty: string,
    stockStatus: string,
    note: string
): Promise<StockActionState> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('create_stock_transfer', {
        p_qty: Number(qty),
        p_to_location_id: toLocationId,
        ...(inboundBatchId ? { p_inbound_batch_id: inboundBatchId } : {}),
        ...(outputBatchId ? { p_output_batch_id: outputBatchId } : {}),
        ...(fromLocationId ? { p_from_location_id: fromLocationId } : {}),
        p_stock_status: stockStatus,
        ...(note.trim() === '' ? {} : { p_note: note.trim() }),
    })
    if (error) return { error: await localizeStockError(error.message) }
    revalidateBatch(inboundBatchId, outputBatchId)
    // IOD-2:告警只可能来自【入腿】的库位校验 —— 出腿一个字都不查。
    // 这一处不重定向,所以告警直接随返回值回到面板上。
    return { warnings: await localizeStockWarnings(warningCodesFrom(data)) }
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
