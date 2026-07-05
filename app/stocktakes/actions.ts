'use server'

// 盘点的四个 server actions:建单 / 记数(upsert 行) / 取消 / 过账。
// 记数被两处复用:盘点详情页的 CountList 和批次编辑页的 StocktakeQuickCount(扫码即点)。
import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeStocktakeError } from './stocktakeErrorCodes'

export type BatchSide = 'inbound' | 'output'

export type SaveCountState = {
    ok?: boolean
    error?: string
}

export type StocktakeActionState = {
    error?: string
}

// 新建盘点单:插一张空单(code 触发器自动生成 ST-YYYY-NNNN;status 默认 'open'),
// 建完直接跳详情页开始点数。无用户输入,失败属异常,直接抛给错误边界。
export async function createStocktake() {
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { data, error } = await supabase
        .from('stocktakes')
        .insert({
            notes: null,
            created_by: user?.id ?? null,
            updated_by: user?.id ?? null,
        } as InsertRow<'stocktakes'>)
        .select('id')
        .single()

    if (error || !data) {
        throw new Error(error?.message ?? 'stocktake insert failed')
    }

    revalidatePath('/stocktakes')
    redirect(`/stocktakes/${data.id}`)
}

// 记一笔实点数:book_qty 取【保存时点】的批次当前剩余(不是打开页面时的快照),
// 同一 (盘点单, 批次) 重复保存走 upsert 覆盖 —— 即"重盘"。
export async function saveCount(
    stocktakeId: string,
    side: BatchSide,
    batchId: string,
    _prev: SaveCountState,
    formData: FormData
): Promise<SaveCountState> {
    const t = await getTranslations()

    const qtyRaw = (formData.get('qty') as string) || ''
    const notes = (formData.get('notes') as string)?.trim() || null

    const qty = Number(qtyRaw)
    if (!qtyRaw || Number.isNaN(qty) || qty < 0) {
        return { error: t('stocktakes.errQty') }
    }

    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    // 页面只在 open 时渲染录入,但服务端再核一次,挡住过账/取消之后的竞态提交
    const { data: st, error: stError } = await supabase
        .from('stocktakes')
        .select('status')
        .eq('id', stocktakeId)
        .is('deleted_at', null)
        .single()
    if (stError || !st) {
        return { error: t('stocktakes.errors.STOCKTAKE_NOT_FOUND', { 0: stocktakeId }) }
    }
    if (st.status !== 'open') {
        return { error: t('stocktakes.errors.STOCKTAKE_NOT_OPEN', { 0: st.status }) }
    }

    // 两张批次表列名一致,但 supabase 泛型按字面量表名解析,分支各写一遍
    const { data: batch, error: batchError } = side === 'inbound'
        ? await supabase
              .from('inbound_batches')
              .select('remaining_qty')
              .eq('id', batchId)
              .is('deleted_at', null)
              .single()
        : await supabase
              .from('output_batches')
              .select('remaining_qty')
              .eq('id', batchId)
              .is('deleted_at', null)
              .single()
    if (batchError || !batch) {
        return { error: t('stocktakes.errors.BATCH_DELETED', { 0: batchId }) }
    }

    const line = {
        stocktake_id: stocktakeId,
        book_qty: batch.remaining_qty,
        counted_qty: qty,
        notes,
        // onConflict UPDATE 不走列默认值,显式刷新重盘时间戳
        counted_at: new Date().toISOString(),
        created_by: user?.id ?? null,
    }

    const { error: upsertError } = side === 'inbound'
        ? await supabase
              .from('stocktake_lines')
              .upsert({ ...line, inbound_batch_id: batchId }, { onConflict: 'stocktake_id,inbound_batch_id' })
        : await supabase
              .from('stocktake_lines')
              .upsert({ ...line, output_batch_id: batchId }, { onConflict: 'stocktake_id,output_batch_id' })

    if (upsertError) {
        return { error: t('stocktakes.saveError', { message: upsertError.message }) }
    }

    revalidatePath(`/stocktakes/${stocktakeId}`)
    revalidatePath(`/stocktakes/${stocktakeId}/review`)
    revalidatePath(side === 'inbound' ? `/inbound/${batchId}/edit` : `/output/${batchId}/edit`)
    return { ok: true }
}

// 取消盘点:行保留存档,但永远不会过账。留在详情页(revalidate 后变只读)。
export async function cancelStocktake(stocktakeId: string): Promise<StocktakeActionState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('cancel_stocktake', { p_stocktake_id: stocktakeId })
    if (error) {
        return { error: await localizeStocktakeError(error.message) }
    }
    revalidatePath('/stocktakes')
    revalidatePath(`/stocktakes/${stocktakeId}`)
    return {}
}

// 过账:每个有差异的批次写一笔 adjustment 流水并把剩余改成实点数(delta 由 DB 按当前剩余重算)。
// 成功后跳回详情页(此时已是只读 posted 视图)。
export async function postStocktake(stocktakeId: string): Promise<StocktakeActionState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('post_stocktake', { p_stocktake_id: stocktakeId })
    if (error) {
        return { error: await localizeStocktakeError(error.message) }
    }
    // 库存被改动:批次列表 / 库存汇总一并刷新
    revalidatePath('/stocktakes')
    revalidatePath(`/stocktakes/${stocktakeId}`)
    revalidatePath('/inbound')
    revalidatePath('/output')
    revalidatePath('/inventory')
    redirect(`/stocktakes/${stocktakeId}`)
}
