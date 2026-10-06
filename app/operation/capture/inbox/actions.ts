'use server'

// app/operation/capture/inbox/actions.ts
// MES-1(2026-10-06,MES-1 Step 0 Q11 · Q15,Tim):数据收件箱的三个动作。
//   · processReceived —— "Process received":把 status = received 的行按到达顺序交给分派器(ingest_process_pending,
//     module.processing.view)。转换只在员工的会话里跑;网关那一次匿名调用只收下(Q11)。
//   · retryInboxRow / discardInboxRow —— 失败或待转换的行重试、或带理由丢弃(action.manage_devices);永远不删。
// 判据全在库里(码、状态、理由、只经函数改);这里只再挡一道"理由不是空白"。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { localizeDeviceError } from '@/app/operation/devices/deviceErrorCodes'

function refresh() {
    revalidatePath('/operation/capture/inbox')
    revalidatePath('/operation/devices')
    revalidatePath('/tools/reminders')
}

export async function processReceived(): Promise<ActionOutcome & {
    counts?: { processed: number; transformed: number; failed: number; awaiting: number }
}> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('ingest_process_pending', { p_limit: 200 })
    if (error) return await refuseFromCoded(error.message, localizeDeviceError)
    refresh()
    return { success: true, counts: data as { processed: number; transformed: number; failed: number; awaiting: number } }
}

export async function retryInboxRow(id: number): Promise<ActionOutcome & { status?: string }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('retry_inbox_row', { p_id: id })
    if (error) return await refuseFromCoded(error.message, localizeDeviceError)
    refresh()
    return { success: true, status: data as string }
}

export async function discardInboxRow(id: number, reason: string): Promise<ActionOutcome> {
    if (reason.trim() === '') return { error: (await getTranslations())('devices.errors.INBOX_DISCARD_REASON_REQUIRED') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('discard_inbox_row', { p_id: id, p_reason: reason.trim() })
    if (error) return await refuseFromCoded(error.message, localizeDeviceError)
    refresh()
    return { success: true }
}
