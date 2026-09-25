'use server'

// 盘点的四个 server actions:建单 / 记数 / 取消 / 过账 —— ROLE-1 Batch 3a 起四个都走库里的函数(三张表没有直连写)。
// 记数被两处复用:盘点详情页的 CountList 和批次编辑页的 StocktakeQuickCount(扫码即点)。
import { createClient } from '@/lib/supabase/server'
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

// 新建盘点单:open_stocktake(ROLE-1 Batch 3a —— 此前是直连 INSERT、created_by 由这里送;
// 从此开单人由库里按 auth.uid() 写,门是 action.stocktake_count)。建完直接跳详情页开始点数。
// 无用户输入;按钮对不持码的人是看得见、按不动的(PermissionGate),所以走到这里的拒绝属异常,抛给错误边界。
export async function createStocktake() {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('open_stocktake', { p_notes: undefined })
    const id = (data as { stocktake_id?: string } | null)?.stocktake_id
    if (error || !id) {
        throw new Error(error?.message ?? 'open_stocktake returned no id')
    }

    revalidatePath('/stocktakes')
    redirect(`/stocktakes/${id}`)
}

// 记一笔实点数:record_stocktake_count(ROLE-1 Batch 3a)。库里核盘点单仍是 open、book_qty 取
// 【保存时点】的批次剩余、同一 (盘点单, 批次) 重录覆盖那一格 —— 并在 stocktake_counts 追加一行
// "谁数的"(只增不改),过账时录过数的每一个人都被拒。录数的人由库里按 auth.uid() 写。
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
    const { error } = await supabase.rpc('record_stocktake_count', {
        p_stocktake_id: stocktakeId,
        p_inbound_batch_id: side === 'inbound' ? batchId : (null as unknown as string),
        p_output_batch_id: side === 'output' ? batchId : (null as unknown as string),
        p_counted_qty: qty,
        p_notes: notes ?? undefined,
    })
    if (error) {
        return { error: await localizeStocktakeError(error.message) }
    }

    revalidatePath(`/stocktakes/${stocktakeId}`)
    revalidatePath(`/stocktakes/${stocktakeId}/review`)
    revalidatePath(side === 'inbound' ? `/inbound/${batchId}/edit` : `/output/${batchId}/edit`)
    return { ok: true }
}

// 取消盘点:行保留存档,但永远不会过账。留在详情页(revalidate 后变只读)。
// AUDEL-1b:理由【必填】,而【录入框是 AUDEL-2】。
// 在那之前,界面传空串 → 数据库按名拒 → 屏幕上是一句看得懂的"请填写理由"。
// 这是刻意的:一个大声拒绝的按钮,好过一个悄悄写下空理由的按钮。
export async function cancelStocktake(stocktakeId: string, reason: string = ''): Promise<StocktakeActionState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('cancel_stocktake', { p_stocktake_id: stocktakeId, p_reason: reason })
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
