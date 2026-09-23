'use server'

// ★ PAY-REQ-1(Tim 2026-09-23):冲销一笔收付款【不再直接冲】—— 钱离开之前要先批,
//   冲销也是钱在动。这里提的是一张【冲销申请】(submit_payment_reversal_request,
//   理由必填),CFO 批准后由财务在申请页上执行。reverse_payment 从此对一切调用按名拒
//   (PAYMENT_REQUEST_REQUIRED|payment_reversal),所以这里不再调它。
// 成功跳到那张申请;错误本地化(PAYMENT_REVERSAL_* 在 paymentErrorCodes 里)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { getTranslations } from '@/lib/i18n/server'
import { localizePaymentError } from '../../paymentErrorCodes'
import { refuseFromCoded } from '@/lib/action-refusal'

export type ReversePaymentState = { error?: string; detail?: string }

export async function requestPaymentReversal(paymentId: string, reason: string): Promise<ReversePaymentState> {
    // 理由必填 —— 对话框已经挡了空白,这里独立再挡一道(库里还有第三道)。
    if (reason.trim() === '') {
        return { error: (await getTranslations())('finance.requestReversalReasonRequired') }
    }
    const supabase = await createClient()

    const { data, error } = await supabase.rpc('submit_payment_reversal_request', {
        p_payment_id: paymentId,
        p_notes: reason.trim(),
    })

    if (error) {
        return await refuseFromCoded(error.message, localizePaymentError)
    }

    const requestId = (data as { request_id?: string } | null)?.request_id

    revalidatePath('/finance')
    revalidatePath('/finance/payments')
    revalidatePath(`/finance/payments/${paymentId}`)
    revalidatePath('/finance/payment-requests')

    if (requestId) {
        redirect(`/finance/payment-requests/${requestId}`)
    }
    return {}
}
