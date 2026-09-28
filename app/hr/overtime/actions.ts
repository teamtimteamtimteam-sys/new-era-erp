'use server'

// app/hr/overtime/actions.ts
// OVERTIME-1:加班批的八个动作。全部走 DB 函数 —— 拒绝住在函数里,这里只翻译(localizeHrError)。
// 录(action.overtime_enter):建批 · 加行 · 删行 · 提交 · 撤回 · 丢弃 · 冲销;批(action.overtime_approve):批准 / 驳回。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeHrError } from '../hrErrorCodes'

export type OvertimeState = { error?: string; success?: boolean; batchId?: string }

function touch(batchId?: string) {
    revalidatePath('/hr/overtime')
    if (batchId) revalidatePath(`/hr/overtime/${batchId}`)
}

export async function createOvertimeBatch(month: string): Promise<OvertimeState> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('create_overtime_batch', { p_month: month })
    if (error) return { error: await localizeHrError(error.message) }
    const batchId = (data as { batch_id?: string } | null)?.batch_id
    touch(batchId)
    return { success: true, batchId }
}

export async function addOvertimeLine(
    batchId: string, employeeId: string, workDate: string, hours: string, note: string,
): Promise<OvertimeState> {
    const supabase = await createClient()
    // 【小时原样交给库判】空串不在这里变成 0 —— 那会把"没填"变成一次按名拒之外的东西。
    const { error } = await supabase.rpc('add_overtime_line', {
        p_batch_id: batchId,
        p_employee_id: employeeId,
        p_work_date: workDate,
        p_hours: Number(hours),
        p_note: note.trim() || undefined,
    })
    if (error) return { error: await localizeHrError(error.message) }
    touch(batchId)
    return { success: true }
}

export async function deleteOvertimeLine(batchId: string, lineId: string): Promise<OvertimeState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('delete_overtime_line', { p_line_id: lineId })
    if (error) return { error: await localizeHrError(error.message) }
    touch(batchId)
    return { success: true }
}

export async function submitOvertimeBatch(batchId: string): Promise<OvertimeState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('submit_overtime_batch', { p_batch_id: batchId })
    if (error) return { error: await localizeHrError(error.message) }
    touch(batchId)
    return { success: true }
}

export async function withdrawOvertimeBatch(batchId: string): Promise<OvertimeState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_overtime_batch', { p_batch_id: batchId })
    if (error) return { error: await localizeHrError(error.message) }
    touch(batchId)
    return { success: true }
}

export async function discardOvertimeBatch(batchId: string): Promise<OvertimeState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('discard_overtime_batch', { p_batch_id: batchId })
    if (error) return { error: await localizeHrError(error.message) }
    touch(batchId)
    return { success: true }
}

export async function reverseOvertimeBatch(batchId: string, reason: string): Promise<OvertimeState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('reverse_overtime_batch', { p_batch_id: batchId, p_reason: reason })
    if (error) return { error: await localizeHrError(error.message) }
    touch(batchId)
    return { success: true }
}

export async function decideOvertimeBatch(
    batchId: string, decision: 'approved' | 'rejected', note: string,
): Promise<OvertimeState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('decide_overtime_batch', {
        p_batch_id: batchId, p_decision: decision, p_note: note.trim() || undefined,
    })
    if (error) return { error: await localizeHrError(error.message) }
    touch(batchId)
    return { success: true }
}
