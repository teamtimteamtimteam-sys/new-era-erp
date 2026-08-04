'use server'

import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import type { Database } from '@/lib/database.types'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeProcessingError } from '../errorCodes'

export type InputRow = {
    inbound_batch_id: string
    quantity_consumed: number
}

export type OutputRow = {
    material_id: string
    quantity: number
    unit: string
    purity: string | null
}

export type CommitProcessingPayload = {
    process_date: string
    notes: string | null
    loss_qty: number | null
    inputs: InputRow[]
    outputs: OutputRow[]
}

export type CommitProcessingState = { error?: string }

export async function commitProcessingRun(
    payload: CommitProcessingPayload
): Promise<CommitProcessingState> {
    const supabase = await createClient()

    // 【必填】这个日期决定过账期间/取哪天的汇率 —— 界面禁用是第一道,这是第二道:
    // 绕过界面也进不去。函数侧的 CURRENT_DATE 默认值已由 FIN-10 一并删除。
    if (!payload.process_date) return { error: (await getTranslations())('processing.errProcessDateRequired') }
    const { error } = await supabase.rpc('commit_processing_run', {
        p_process_date: payload.process_date,
        p_notes: payload.notes,
        p_loss_qty: payload.loss_qty,
        p_inputs: payload.inputs,
        p_outputs: payload.outputs,
    } as Database['public']['Functions']['commit_processing_run']['Args'])

    if (error) {
        return { error: await localizeProcessingError(error.message) }
    }

    revalidatePath('/processing')
    revalidatePath('/inbound') // 库存被消耗
    revalidatePath('/output')  // 产生新产出批次
    redirect('/processing')
}
