'use server'

// app/finance/payment-requests/[id]/actions.ts
// PAY-REQ-1(Tim 2026-09-23):付款申请的三个动作 —— 批/驳、撤回、付款。
//
// 【判据一条都不在这里】谁能批(二级审批角色、不是提单人)、什么状态能做什么、
// 金额与核销还站不站得住 —— 全部由 decide / withdraw / pay_payment_request 在库里裁,
// 拒绝经 refuseFromCoded 说成人话。这里只做两件【服务端必须独立再挡一道】的事:
//   · 驳回要理由(对话框已经挡了空白,库里还有一道);
//   · 出款的付款日必填 —— 它决定期间与汇率,绝不默认成今天(AGENTS.md
//     「Dates and amounts that decide a period」),UI 的禁用不是那道闸。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { getTranslations } from '@/lib/i18n/server'
import { localizePaymentError } from '../../paymentErrorCodes'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { mustOne } from '@/lib/db-helpers'

function refresh(requestId: string) {
    revalidatePath('/finance')
    revalidatePath('/finance/payment-requests')
    revalidatePath(`/finance/payment-requests/${requestId}`)
    revalidatePath('/finance/payments')
    revalidatePath('/finance/payables')
    revalidatePath('/finance/journal')
}

export async function decidePaymentRequest(
    requestId: string, approve: boolean, notes: string
): Promise<ActionOutcome> {
    if (!approve && notes.trim() === '') {
        return { error: (await getTranslations())('finance.paymentRequests.rejectReasonRequired') }
    }
    const supabase = await createClient()
    const { error } = await supabase.rpc('decide_payment_request', {
        p_request_id: requestId,
        p_approve: approve,
        p_notes: notes.trim() || undefined,
    })
    if (error) return await refuseFromCoded(error.message, localizePaymentError)
    refresh(requestId)
    return { success: true }
}

export async function withdrawPaymentRequest(requestId: string): Promise<ActionOutcome> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_payment_request', { p_request_id: requestId })
    if (error) return await refuseFromCoded(error.message, localizePaymentError)
    refresh(requestId)
    return { success: true }
}

export async function payPaymentRequest(
    requestId: string, paymentDate: string, fxRateRaw: string
): Promise<ActionOutcome> {
    const t = await getTranslations()
    const supabase = await createClient()

    // 种类从库里读,不信客户端传来的 —— 两种申请的参数形状不同(冲销不收日期也不收汇率)。
    const req = mustOne(
        await supabase.from('payment_requests').select('kind').eq('id', requestId).maybeSingle(),
        'payment request kind'
    ) as { kind: string } | null
    if (!req) return { error: t('finance.errors.PAYMENT_REQUEST_NOT_FOUND', { 0: requestId }) }

    let args: { p_request_id: string; p_payment_date?: string; p_fx_rate?: number } = { p_request_id: requestId }
    if (req.kind === 'payment_out') {
        const date = paymentDate.trim()
        if (!date || Number.isNaN(Date.parse(date))) {
            return { error: t('finance.errors.PAYMENT_DATE_REQUIRED'), field: 'payment_date' }
        }
        let fx: number | undefined
        if (fxRateRaw.trim() !== '') {
            fx = Number(fxRateRaw)
            if (!Number.isFinite(fx) || fx <= 0) {
                return { error: t('finance.errors.FX_RATE_INVALID', { 0: fxRateRaw }), field: 'fx_rate' }
            }
        }
        args = { p_request_id: requestId, p_payment_date: date, p_fx_rate: fx }
    }
    // payment_reversal:不送日期、不送汇率 —— 冲销由引擎按今天记(PAYMENT_REVERSAL_TAKES_NO_DATE)。

    const { data, error } = await supabase.rpc('pay_payment_request', args)
    if (error) return await refuseFromCoded(error.message, localizePaymentError)

    refresh(requestId)
    const paymentId = (data as { result_payment_id?: string } | null)?.result_payment_id
    if (paymentId) redirect(`/finance/payments/${paymentId}`)
    return { success: true }
}
