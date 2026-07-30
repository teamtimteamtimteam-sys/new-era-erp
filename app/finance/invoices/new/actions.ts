'use server'

// 开票:勾选的销售 id 数组 → rpc create_invoice(校验、无缝编号、抬头快照一个事务)。
// 【不过任何分录】—— 收入与应收在销售当刻已确认,发票只是归拢成一份可寄出的文件。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeInvoiceError } from '../../invoiceErrorCodes'

export type CreateInvoiceState = { error?: string }

export async function createInvoice(
    _prevState: CreateInvoiceState,
    formData: FormData
): Promise<CreateInvoiceState> {
    const t = await getTranslations()

    const customerId = String(formData.get('customer_id') ?? '').trim()
    const issueDate = String(formData.get('issue_date') ?? '').trim()
    const termsRaw = String(formData.get('terms_days') ?? '').trim()
    const notes = String(formData.get('notes') ?? '').trim()
    const termsText = String(formData.get('terms_text') ?? '').trim()
    const saleIds = formData.getAll('sale_id').map(String).filter(Boolean)

    if (!customerId) {
        return { error: t('invoice.errors.CUSTOMER_NOT_FOUND', { 0: '?' }) }
    }
    if (saleIds.length === 0) {
        return { error: t('invoice.errors.NO_LINES') }
    }
    if (!issueDate || Number.isNaN(Date.parse(issueDate))) {
        return { error: t('finance.errDate') }
    }
    const termsDays = termsRaw === '' ? null : Number(termsRaw)
    if (termsDays !== null && (Number.isNaN(termsDays) || termsDays < 0 || termsDays > 3650)) {
        return { error: t('invoice.errTermsDays') }
    }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('create_invoice', {
        p_customer_id: customerId,
        p_sales_record_ids: saleIds,
        p_issue_date: issueDate,
        p_payment_terms_days: termsDays ?? undefined,
        p_notes: notes || undefined,
        p_terms_text: termsText || undefined,
    })

    if (error) {
        return { error: await localizeInvoiceError(error.message) }
    }

    const invoiceId = (data as { invoice_id?: string } | null)?.invoice_id

    revalidatePath('/finance/invoices')
    revalidatePath('/finance/receivables')

    if (invoiceId) {
        redirect(`/finance/invoices/${invoiceId}`)
    }
    redirect('/finance/invoices')
}
