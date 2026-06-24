'use server'

import { createClient } from '@/lib/supabase/server'
import type { Database } from '@/lib/database.types'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

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

    const { error } = await supabase.rpc('commit_processing_run', {
        p_process_date: payload.process_date,
        p_notes: payload.notes,
        p_loss_qty: payload.loss_qty,
        p_inputs: payload.inputs,
        p_outputs: payload.outputs,
    } as Database['public']['Functions']['commit_processing_run']['Args'])

    if (error) {
        return { error: error.message }
    }

    revalidatePath('/processing')
    revalidatePath('/inbound') // 库存被消耗
    revalidatePath('/output')  // 产生新产出批次
    redirect('/processing')
}
