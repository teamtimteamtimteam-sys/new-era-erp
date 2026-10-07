'use server'

// PROC-BUILD-1 → MES-4a(2026-10-07,Step 0 Q28,Tim):一张加工单上【分了类的那部分损耗】的服务端动作。
//
// ★ MES-4a 之前这里直接 upsert / delete processing_run_losses —— 改一个数就把旧的抹掉,删一行就真的没了。
//   现在那张表【只追加】,表上不再有给 authenticated 的写策略:记一类 = record_run_loss,改一个数 = correct_run_loss
//   (新的一行带着理由指着旧的;旧的留着)。没有删除 —— "这一类其实是零"就更正成 0,连同为什么。
//
// 【loss_qty 是投入 − 产出,由数据库算】分类之和【不许超过】它,那条判据由数据库执行(guard_processing_run_losses),
// 不由这里执行 —— 屏幕上校验一遍再交给数据库,是把同一条规则写两份。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { localizeProcessingError } from '../../errorCodes'

export async function recordRunLoss(runId: string, formData: FormData): Promise<{ error?: string }> {
    const t = await getTranslations()
    const code = (formData.get('loss_category_code') as string)?.trim() || ''
    const raw = (formData.get('quantity') as string) ?? ''
    const notes = (formData.get('notes') as string)?.trim() || undefined
    if (!code) return { error: t('processing.loss.errInvalid') }
    const qty = Number(raw)
    // 【> 0】一笔为零的损耗与"没有这一类"分不开 —— 函数那一侧说的是同一句话(RUN_LOSS_QTY_INVALID)。
    if (raw === '' || !Number.isFinite(qty) || qty <= 0) return { error: t('processing.loss.errInvalid') }

    const supabase = await createClient()
    const { error } = await supabase.rpc('record_run_loss', {
        p_run_id: runId, p_loss_category_code: code, p_quantity: qty, p_notes: notes,
    })
    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath(`/operation/processing/${runId}`)
    return {}
}

/** MES-4b(Q18):按工序的电解液份额算一笔电解液挥发(份额 × 这一炉的投入)。只在这里按下去才记 —— 从不在提交时自动算、从不取余数。 */
export async function deriveElectrolyteLoss(runId: string, notes: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('record_derived_electrolyte_loss', { p_run_id: runId, p_notes: notes.trim() || undefined })
    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath(`/operation/processing/${runId}`)
    return {}
}

/** MES-4b(Q19):按【现在】的份额重新算那一笔(一条更正,理由必填)。改成量出来的走下面的 correctRunLoss。 */
export async function rederiveElectrolyteLoss(runId: string, lossId: number, reason: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('rederive_electrolyte_loss', { p_loss_id: lossId, p_reason: reason })
    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath(`/operation/processing/${runId}`)
    return {}
}

/** 更正一类损耗的数(可以更正成 0 —— 那是"这一类其实没有",不是删除)。理由必填,函数按名拒。 */
export async function correctRunLoss(runId: string, lossId: number, quantity: string, reason: string): Promise<{ error?: string }> {
    const t = await getTranslations()
    const qty = Number(quantity)
    if (quantity.trim() === '' || !Number.isFinite(qty) || qty < 0) return { error: t('processing.loss.errCorrectInvalid') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('correct_run_loss', { p_loss_id: lossId, p_quantity: qty, p_reason: reason })
    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath(`/operation/processing/${runId}`)
    return {}
}
