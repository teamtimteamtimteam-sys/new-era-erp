'use server'

// ★ APR-5a(Tim 2026-09-25):作废一张发票要 CFO 批准。这里【提一张作废申请】
//   (submit_invoice_void_request);CFO 批准那一刻当场作废并冲销(明细行保留供审计,
//   所挂销售 / 订单行随之重新可开票)。审批关着时申请生下来就是 approved,当场作废。
//   批 / 驳 / 撤回贷项与作废两种申请,也在这里。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeInvoiceError } from '../../invoiceErrorCodes'
import { isCreditNoteErrorCode, localizeCreditNoteError } from '../../creditNoteErrorCodes'
import { refuseFromCoded } from '@/lib/action-refusal'
import { getTranslations } from '@/lib/i18n/server'

export type VoidInvoiceState = {
    error?: string
    detail?: string
    /** APR-5a:提出的那张申请 —— submitted(在等 CFO)或 approved(审批关着,已作废) */
    request?: { label: string; status: 'submitted' | 'approved' }
}

function refreshInvoice(invoiceId: string) {
    revalidatePath('/finance/invoices')
    revalidatePath(`/finance/invoices/${invoiceId}`)
    revalidatePath('/finance/receivables')
    revalidatePath('/finance/credit-notes')
    revalidatePath('/finance/journal')
    revalidatePath('/')
}

// 批准时的拒绝可能来自两支引擎(作废 → 发票那一族;贷项 → 贷项那一族)—— 按码认族。
async function localizeRequestError(message: string): Promise<string> {
    return isCreditNoteErrorCode(message) ? localizeCreditNoteError(message) : localizeInvoiceError(message)
}

// SO-3a:order 头的作废是一次【冲销】—— 冲销日必填(决定分录期间,永不默认);
// sale 头没有分录可冲,传了日期服务端按名拒(REVERSAL_DATE_NOT_ACCEPTED),
// 所以这里只在有值时递。APR-5a:冲销日随申请冻结,CFO 批准时就按它冲。
export async function voidInvoice(invoiceId: string, reason: string, reversalDate?: string): Promise<VoidInvoiceState> {
    const supabase = await createClient()

    const { data, error } = await supabase.rpc('submit_invoice_void_request', {
        p_invoice_id: invoiceId,
        p_reason: reason,
        ...(reversalDate && reversalDate.trim() !== '' ? { p_reversal_date: reversalDate } : {}),
    })

    if (error) {
        return await refuseFromCoded(error.message, localizeInvoiceError)
    }

    refreshInvoice(invoiceId)
    const r = data as { label?: string; status?: 'submitted' | 'approved' } | null
    return { request: r?.label && r.status ? { label: r.label, status: r.status } : undefined }
}

// ★ APR-5a:CFO 批准(当场过账,按冻结的日期)或驳回(要理由)一张贷项 / 作废申请。
//   谁能批这里不预判(二级审批人、不是提单人 —— 按人认),拒绝由库出、就地说成人话。
export async function decideInvoiceRequest(
    invoiceId: string, requestId: string, approve: boolean, notes: string
): Promise<{ error?: string }> {
    if (!approve && notes.trim() === '') {
        return { error: (await getTranslations())('finance.invoiceRequest.rejectReasonRequired') }
    }
    const supabase = await createClient()
    const { error } = await supabase.rpc('decide_invoice_request', {
        p_request_id: requestId,
        p_approve: approve,
        p_notes: notes.trim() || undefined,
    })
    if (error) return { error: await localizeRequestError(error.message) }
    refreshInvoice(invoiceId)
    return {}
}

// ★ APR-5a(grilling Q9):撤回 —— 提单人本人,或持 module.finance.edit 的人。
export async function withdrawInvoiceRequest(
    invoiceId: string, requestId: string, reason: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_invoice_request', {
        p_request_id: requestId,
        p_reason: reason.trim() || undefined,
    })
    if (error) return { error: await localizeRequestError(error.message) }
    refreshInvoice(invoiceId)
    return {}
}
