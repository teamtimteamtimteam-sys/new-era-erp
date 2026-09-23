'use server'

// 行内转账(FIN-1b):守卫全部在 DB(同户拒、非银行户拒、期间锁、同币种两边必相等)。
// ★ PAY-REQ-1 · Batch B(Tim 2026-09-23 的 Q15):转账【不再直接记】—— 钱离开之前要先批,
//   在自家两个户之间挪钱也是钱在动。这里提的是一张【转账申请】(submit_bank_transfer_request),
//   CFO 批准后由财务在申请页上执行,执行时给实际转账日。record_bank_transfer 从此按名拒
//   (PAYMENT_REQUEST_REQUIRED|bank_transfer),所以这里不再调它。
//   冲销同理:requestTransferReversal 提一张冲销申请(理由必填),执行时给冲销日。
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { localizePaymentError } from '../paymentErrorCodes'
import { refuseFromCoded } from '@/lib/action-refusal'

export type TransferState = { error?: string; detail?: string; success?: boolean }

export async function submitTransferRequest(input: {
    date: string
    from: string
    to: string
    amountOut: string
    amountIn: string
    reference: string
}): Promise<TransferState> {
    const supabase = await createClient()
    // 【必填】计划转账日决定试跑用哪一期 —— 界面禁用是第一道,这是第二道;库里还有第三道。
    if (!input.date) return { error: (await getTranslations())('finance.transfer.errDateRequired') }
    const { data, error } = await supabase.rpc('submit_bank_transfer_request', {
        p_planned_date: input.date,
        p_from_account: input.from,
        p_to_account: input.to,
        p_amount_out: Number(input.amountOut),
        p_amount_in: Number(input.amountIn),
        p_bank_reference: input.reference || undefined,
    })
    if (error) return await refuseFromCoded(error.message, localizePaymentError)
    revalidatePath('/finance/bank')
    revalidatePath('/finance/payment-requests')
    const requestId = (data as { request_id?: string } | null)?.request_id
    if (requestId) redirect(`/finance/payment-requests/${requestId}`)
    return { success: true }
}

export async function requestTransferReversal(transferId: string, reason: string): Promise<TransferState> {
    // 理由必填 —— 对话框已经挡了空白,这里独立再挡一道(库里还有第三道)。
    if (reason.trim() === '') {
        return { error: (await getTranslations())('finance.requestReversalReasonRequired') }
    }
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('submit_bank_transfer_reversal_request', {
        p_transfer_id: transferId,
        p_notes: reason.trim(),
    })
    if (error) return await refuseFromCoded(error.message, localizePaymentError)
    revalidatePath('/finance/bank')
    revalidatePath('/finance/payment-requests')
    const requestId = (data as { request_id?: string } | null)?.request_id
    if (requestId) redirect(`/finance/payment-requests/${requestId}`)
    return {}
}
