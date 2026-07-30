'use server'

// 作废发票:调 void_invoice。其明细行保留供审计,但所挂销售随之重新可开票
// (invoice_lines.invoice_voided 由 DB 触发器同步,部分唯一索引因此放行重开)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeInvoiceError } from '../../invoiceErrorCodes'

export type VoidInvoiceState = { error?: string }

export async function voidInvoice(invoiceId: string, reason: string): Promise<VoidInvoiceState> {
    const supabase = await createClient()

    const { error } = await supabase.rpc('void_invoice', {
        p_invoice_id: invoiceId,
        p_reason: reason,
    })

    if (error) {
        return { error: await localizeInvoiceError(error.message) }
    }

    revalidatePath('/finance/invoices')
    revalidatePath(`/finance/invoices/${invoiceId}`)
    revalidatePath('/finance/receivables')
    return {}
}
