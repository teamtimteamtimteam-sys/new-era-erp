'use server'

// PROC-WIRE-1B-ii(R1 / M4):记录 / 撤销一批【自产料】身上的安全状态。
//
// 【为什么这块屏必须存在,而不是"以后再补"】那道火闸现在会拦下一批没有安全状态
// 的自产料,而它的 HINT 写着"到【产出 → 打开这一批 → 安全状态】那一块把它记上"。
// **没有这块屏,那句提示就是一句假话** —— 一条报了却没有下一步的拒绝,
// 正是本仓库反复付账的那一种。
//
// 【权限:module.output.edit,跟着父单据判】与 inbound_batch_safety_states 同一条
// (哪个模块能写父,哪个就能写行)。**它与"把一批货许给产线"不是同一件事** ——
// 那个是工序决定(processing.edit),这个是"收货/产出的人看见了什么"。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'

export async function addOutputSafetyState(
    batchId: string,
    code: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const t = await getTranslations()
    const { error } = await supabase
        .from('output_batch_safety_states')
        .insert({ output_batch_id: batchId, safety_state_code: code })
    // 【重复不是错误,是"已经记过了"】主键就是那条规矩(同一状态只记一次)。
    if (error && !error.message.includes('duplicate key')) {
        return { error: t('output.safety.errors.writeFailed', { msg: error.message }) }
    }
    revalidatePath(`/output/${batchId}/edit`)
    return {}
}

export async function removeOutputSafetyState(
    batchId: string,
    code: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const t = await getTranslations()
    const { error } = await supabase
        .from('output_batch_safety_states')
        .delete()
        .eq('output_batch_id', batchId)
        .eq('safety_state_code', code)
    if (error) return { error: t('output.safety.errors.writeFailed', { msg: error.message }) }
    revalidatePath(`/output/${batchId}/edit`)
    return {}
}
