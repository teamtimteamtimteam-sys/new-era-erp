'use server'

// ★ APR-7(Tim 2026-09-25):注销批次、加工回滚、作废销毁证书 —— 仓库提,CFO 批每一张,批准之前什么都不发生。
//   四扇提交的门(各问自己的码)、CFO 的批准 / 驳回(要理由)、撤回(提单人本人,或持那个码的人)。
//   谁能批这里不预判(二级审批人、不是提单人 —— 按人认),拒绝由库出、就地说成人话。
//   审批关着时申请生下来就是 approved 并当场生效 —— 返回里的 status 说的是哪一种。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { refuseFromCoded } from '@/lib/action-refusal'
import { getTranslations } from '@/lib/i18n/server'
import { localizeWarehouseRequestError } from './warehouseRequestErrorCodes'

export type WarehouseRequestKind = 'write_off_inbound' | 'write_off_output' | 'rollback' | 'cod_void'

export type WarehouseRequestState = {
    error?: string
    detail?: string
    request?: { label: string; status: 'submitted' | 'approved' }
}

function refreshWarehouse(extra?: string) {
    revalidatePath('/inventory')
    revalidatePath('/inbound')
    revalidatePath('/output')
    revalidatePath('/operation/processing')
    if (extra) revalidatePath(extra)
    revalidatePath('/')
}

export async function submitWarehouseRequest(
    kind: WarehouseRequestKind, subjectId: string, reason: string, extraPath?: string
): Promise<WarehouseRequestState> {
    if (reason.trim() === '') {
        return { error: (await getTranslations())('warehouseRequest.reasonRequired') }
    }
    const supabase = await createClient()
    const r = kind === 'write_off_inbound'
        ? await supabase.rpc('submit_inbound_write_off_request', { p_batch_id: subjectId, p_reason: reason.trim() })
        : kind === 'write_off_output'
            ? await supabase.rpc('submit_output_write_off_request', { p_batch_id: subjectId, p_reason: reason.trim() })
            : kind === 'rollback'
                ? await supabase.rpc('submit_rollback_request', { p_run_id: subjectId, p_reason: reason.trim() })
                : await supabase.rpc('submit_cod_void_request', { p_cod_id: subjectId, p_reason: reason.trim() })
    if (r.error) return await refuseFromCoded(r.error.message, localizeWarehouseRequestError)
    refreshWarehouse(extraPath)
    const d = r.data as { label?: string; status?: 'submitted' | 'approved' } | null
    return { request: d?.label && d.status ? { label: d.label, status: d.status } : undefined }
}

export async function decideWarehouseRequest(
    requestId: string, approve: boolean, notes: string
): Promise<{ error?: string; detail?: string }> {
    if (!approve && notes.trim() === '') {
        return { error: (await getTranslations())('warehouseRequest.rejectReasonRequired') }
    }
    const supabase = await createClient()
    const { error } = await supabase.rpc('decide_warehouse_request', {
        p_request_id: requestId,
        p_approve: approve,
        p_notes: notes.trim() || undefined,
    })
    if (error) return await refuseFromCoded(error.message, localizeWarehouseRequestError)
    refreshWarehouse()
    return {}
}

export async function withdrawWarehouseRequest(requestId: string): Promise<{ error?: string; detail?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_warehouse_request', { p_request_id: requestId })
    if (error) return await refuseFromCoded(error.message, localizeWarehouseRequestError)
    refreshWarehouse()
    return {}
}
