'use server'

// ★ APR-8(Tim 2026-09-26):合同条款与定价公式 —— cco 提,CFO 批每一张,批准之前什么都不生效。
//   这里是公式页与合同页共用的那几扇门:CFO 的批准 / 驳回(要理由)、撤回(提单人本人,或持那一种码的人)、
//   合同申请生效与暂停、公式停用。新建 / 修改公式的提交住在 app/tools/pricing/formulas/actions.ts(它要读表单)。
//   谁能批这里不预判(二级审批人、不是提单人 —— 按人认),拒绝由库出、就地说成人话。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { refuseFromCoded, refuseNothingChanged } from '@/lib/action-refusal'
import { getTranslations } from '@/lib/i18n/server'
import { localizeTermsRequestError } from './termsRequestErrorCodes'

export type TermsActionResult = { error?: string; detail?: string; status?: 'submitted' | 'approved'; label?: string }

function refreshTerms() {
    revalidatePath('/tools/pricing/formulas')
    revalidatePath('/contracts')
    revalidatePath('/')
}

export async function decideTermsRequest(
    requestId: string, approve: boolean, notes: string
): Promise<TermsActionResult> {
    if (!approve && notes.trim() === '') {
        return { error: (await getTranslations())('termsRequest.rejectReasonRequired') }
    }
    const supabase = await createClient()
    const { error } = await supabase.rpc('decide_terms_request', {
        p_request_id: requestId,
        p_approve: approve,
        p_notes: notes.trim() || undefined,
    })
    if (error) return await refuseFromCoded(error.message, localizeTermsRequestError)
    refreshTerms()
    return {}
}

export async function withdrawTermsRequest(requestId: string): Promise<TermsActionResult> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_terms_request', { p_request_id: requestId })
    if (error) return await refuseFromCoded(error.message, localizeTermsRequestError)
    refreshTerms()
    return {}
}

export async function submitContractActivation(contractId: string, reason: string): Promise<TermsActionResult> {
    if (reason.trim() === '') {
        return { error: (await getTranslations())('termsRequest.reasonRequired') }
    }
    const supabase = await createClient()
    const r = await supabase.rpc('submit_contract_activation_request', {
        p_contract_id: contractId, p_reason: reason.trim(),
    })
    if (r.error) return await refuseFromCoded(r.error.message, localizeTermsRequestError)
    refreshTerms()
    const d = r.data as { label?: string; status?: 'submitted' | 'approved' } | null
    return { label: d?.label, status: d?.status }
}

// 暂停一份生效中的合同 —— 一步(只会让效力变少,grilling Q2)。直连 UPDATE,守卫只放"只改状态"这一种;
// 零行 = 被策略挡下(没有 action.contract_terms),不许报告成功。
export async function suspendContract(contractId: string): Promise<TermsActionResult> {
    const supabase = await createClient()
    const { data, error } = await supabase
        .from('contracts')
        .update({ status: 'suspended' })
        .eq('id', contractId)
        .eq('status', 'active')
        .select('id')
    if (error) return await refuseFromCoded(error.message, localizeTermsRequestError)
    if (!data || data.length === 0) return await refuseNothingChanged('action.contract_terms')
    refreshTerms()
    return {}
}

// 停用一张公式 —— 一步(只会让能用的变少,grilling Q1)。重新启用要经 CFO。
export async function deactivateFormula(formulaId: string): Promise<TermsActionResult> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('deactivate_pricing_formula', { p_formula_id: formulaId })
    if (error) return await refuseFromCoded(error.message, localizeTermsRequestError)
    refreshTerms()
    revalidatePath(`/tools/pricing/formulas/${formulaId}/edit`)
    return {}
}
