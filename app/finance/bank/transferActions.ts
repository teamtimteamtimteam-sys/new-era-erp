'use server'

// 行内转账(FIN-1b):守卫全部在 DB(同户拒、非银行户拒、期间锁、同币种两边必相等)。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
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
