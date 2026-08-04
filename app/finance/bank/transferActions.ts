'use server'

// 行内转账(FIN-1b):守卫全部在 DB(同户拒、非银行户拒、期间锁、同币种两边必相等)。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { localizePaymentError } from '../paymentErrorCodes'

export type TransferState = { error?: string; success?: boolean }

export async function recordTransfer(input: {
    date: string
    from: string
    to: string
    amountOut: string
    amountIn: string
    reference: string
}): Promise<TransferState> {
    const supabase = await createClient()
    // 【必填】这个日期决定过账期间/取哪天的汇率 —— 界面禁用是第一道,这是第二道:
    // 绕过界面也进不去。函数侧的 CURRENT_DATE 默认值已由 FIN-10 一并删除。
    if (!input.date) return { error: (await getTranslations())('finance.transfer.errDateRequired') }
    const { error } = await supabase.rpc('record_bank_transfer', {
        p_transfer_date: input.date,
        p_from_account: input.from,
        p_to_account: input.to,
        p_amount_out: Number(input.amountOut),
        p_amount_in: Number(input.amountIn),
        p_bank_reference: input.reference || undefined,
    })
    if (error) return { error: await localizePaymentError(error.message) }
    revalidatePath('/finance/bank')
    revalidatePath('/finance/journal')
    return { success: true }
}
