'use server'

// 冲销收付款:调 reverse_payment(冲其分录 + 生成同方向镜像单,核销自动失效),
// 成功跳镜像单详情;错误本地化(PERIOD_LOCKED 等;PAYMENT_* 未编码则原样返回)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizePaymentError } from '../../paymentErrorCodes'

export type ReversePaymentState = { error?: string }

export async function reversePayment(paymentId: string): Promise<ReversePaymentState> {
    const supabase = await createClient()

    const { data, error } = await supabase.rpc('reverse_payment', {
        p_payment_id: paymentId,
    })

    if (error) {
        return { error: await localizePaymentError(error.message) }
    }

    const reversalId = (data as { reversal_payment_id?: string } | null)?.reversal_payment_id

    revalidatePath('/finance')
    revalidatePath('/finance/journal')
    revalidatePath('/finance/receivables')
    revalidatePath('/finance/payables')
    revalidatePath('/finance/payments')
    revalidatePath(`/finance/payments/${paymentId}`)

    if (reversalId) {
        redirect(`/finance/payments/${reversalId}`)
    }
    return {}
}
