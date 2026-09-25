'use server'

// ★ APR-6(Tim 2026-09-25):手工凭证与它的冲销要 CFO 批准才过账。
//   这里是凭证那一侧的三个动作:CFO 批准(当场按冻结的日期过账)/ 驳回(要理由)、撤回、
//   以及从分录详情页【提一张冲销申请】。提一张手工凭证在 ./new/actions.ts。
//   谁能批这里不预判(二级审批人、不是提单人 —— 按人认),拒绝由库出、就地说成人话。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeFinanceError } from '../financeErrorCodes'
import { refuseFromCoded } from '@/lib/action-refusal'
import { getTranslations } from '@/lib/i18n/server'
import { businessToday } from '@/lib/format'

function refreshJournal(entryId?: string | null) {
    revalidatePath('/finance')
    revalidatePath('/finance/journal')
    if (entryId) revalidatePath(`/finance/journal/${entryId}`)
    revalidatePath('/')
}

export async function decideJournalRequest(
    requestId: string, approve: boolean, notes: string, targetEntryId: string | null
): Promise<{ error?: string; detail?: string }> {
    if (!approve && notes.trim() === '') {
        return { error: (await getTranslations())('finance.journalRequest.rejectReasonRequired') }
    }
    const supabase = await createClient()
    const { error } = await supabase.rpc('decide_journal_request', {
        p_request_id: requestId,
        p_approve: approve,
        p_notes: notes.trim() || undefined,
    })
    if (error) return await refuseFromCoded(error.message, localizeFinanceError)
    refreshJournal(targetEntryId)
    return {}
}

export async function withdrawJournalRequest(
    requestId: string, reason: string, targetEntryId: string | null
): Promise<{ error?: string; detail?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_journal_request', {
        p_request_id: requestId,
        p_reason: reason.trim() || undefined,
    })
    if (error) return await refuseFromCoded(error.message, localizeFinanceError)
    refreshJournal(targetEntryId)
    return {}
}

// ★ APR-6(grilling Q6):从分录详情页冲一张分录 = 提一张冲销申请。冲销日 = 今天的【业务日】(新加坡),
//   随申请冻结 —— CFO 批准那一刻就按它冲。理由必填(它写进冲销分录的摘要)。
//   审批关着时申请生下来就是 approved,当场冲销(返回里带着冲销分录的 id)。
export type ReversalRequestState = {
    error?: string
    detail?: string
    request?: { label: string; status: 'submitted' | 'approved'; entryId: string | null }
}

export async function requestReversal(entryId: string, reason: string): Promise<ReversalRequestState> {
    if (reason.trim() === '') {
        return { error: (await getTranslations())('finance.journalRequest.reversalReasonRequired') }
    }
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('submit_journal_reversal_request', {
        p_entry_id: entryId,
        p_reversal_date: businessToday(),
        p_reason: reason.trim(),
    })
    if (error) return await refuseFromCoded(error.message, localizeFinanceError)
    refreshJournal(entryId)
    const r = data as { label?: string; status?: 'submitted' | 'approved'; entry_id?: string | null } | null
    return {
        request: r?.label && r.status ? { label: r.label, status: r.status, entryId: r.entry_id ?? null } : undefined,
    }
}
