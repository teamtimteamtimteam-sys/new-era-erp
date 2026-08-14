'use server'

// 作废发票:调 void_invoice。其明细行保留供审计,但所挂销售随之重新可开票
// (invoice_lines.invoice_voided 由 DB 触发器同步,部分唯一索引因此放行重开)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeInvoiceError } from '../../invoiceErrorCodes'

export type VoidInvoiceState = { error?: string }

// SO-3a:order 头的作废是一次【冲销】—— 冲销日必填(决定分录期间,永不默认);
// sale 头没有分录可冲,传了日期服务端按名拒(REVERSAL_DATE_NOT_ACCEPTED),
// 所以这里只在有值时递。
export async function voidInvoice(invoiceId: string, reason: string, reversalDate?: string): Promise<VoidInvoiceState> {
    const supabase = await createClient()

    const { error } = await supabase.rpc('void_invoice', {
        p_invoice_id: invoiceId,
        p_reason: reason,
        ...(reversalDate && reversalDate.trim() !== '' ? { p_reversal_date: reversalDate } : {}),
    })

    if (error) {
        return { error: await localizeInvoiceError(error.message) }
    }

    revalidatePath('/finance/invoices')
    revalidatePath(`/finance/invoices/${invoiceId}`)
    revalidatePath('/finance/receivables')
    return {}
}
