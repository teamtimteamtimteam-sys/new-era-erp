'use server'

// ★ APR-9(Tim 2026-09-27):固定资产处置 —— 财务提,CFO 批每一张,批准之前什么都不发生。
//   提交(module.finance.edit;收款与银行科目提交时冻结)、CFO 的批准 / 驳回(要理由)、撤回(提单人本人,
//   或持 module.finance.edit 的人)。处置日【不由这里给】—— 它是批准那一天(grilling Q7),所以表单上没有日期框。
//   谁能批这里不预判(二级审批人、不是提单人 —— 按人认),拒绝由库出、就地说成人话。
//   审批关着时申请生下来就是 approved 并当场处置 —— 返回里的 status 说的是哪一种。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { refuseFromCoded } from '@/lib/action-refusal'
import { getTranslations } from '@/lib/i18n/server'
import { localizeDisposalRequestError } from './disposalRequestErrorCodes'

export type DisposalRequestState = {
    error?: string
    detail?: string
    request?: { label: string; status: 'submitted' | 'approved' }
}

function refresh() {
    revalidatePath('/finance/assets')
    revalidatePath('/finance/month-end')
    revalidatePath('/finance/journal')
    revalidatePath('/')
}

export async function submitDisposalRequest(
    assetId: string, proceeds: number, bankAccount: string | null, reason: string,
): Promise<DisposalRequestState> {
    const t = await getTranslations()
    if (reason.trim() === '') return { error: t('assetDisposal.reasonRequired') }
    if (!Number.isFinite(proceeds) || proceeds < 0) return { error: t('finance.errors.PROCEEDS_INVALID') }
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('submit_asset_disposal_request', {
        p_asset_id: assetId,
        p_proceeds: proceeds,
        // 收款为 0(报废)时银行科目不读(函数只在收款 > 0 时判它),传空串;收款 > 0 而没挑 → BANK_INVALID 按名拒
        p_bank_account: proceeds > 0 ? (bankAccount ?? '') : '',
        p_reason: reason.trim(),
    })
    if (error) return await refuseFromCoded(error.message, localizeDisposalRequestError)
    refresh()
    const d = data as { label?: string; status?: 'submitted' | 'approved' } | null
    return { request: d?.label && d.status ? { label: d.label, status: d.status } : undefined }
}

export async function decideDisposalRequest(
    requestId: string, approve: boolean, notes: string,
): Promise<{ error?: string; detail?: string }> {
    if (!approve && notes.trim() === '') {
        return { error: (await getTranslations())('assetDisposal.rejectReasonRequired') }
    }
    const supabase = await createClient()
    const { error } = await supabase.rpc('decide_asset_disposal_request', {
        p_request_id: requestId,
        p_approve: approve,
        p_notes: notes.trim() || undefined,
    })
    if (error) return await refuseFromCoded(error.message, localizeDisposalRequestError)
    refresh()
    return {}
}

export async function withdrawDisposalRequest(requestId: string): Promise<{ error?: string; detail?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_asset_disposal_request', { p_request_id: requestId })
    if (error) return await refuseFromCoded(error.message, localizeDisposalRequestError)
    refresh()
    return {}
}
