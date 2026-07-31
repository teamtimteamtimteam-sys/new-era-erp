'use server'

// 收付款登记:并列数组核销字段(alloc_id[]/alloc_amount[])组装 allocations jsonb
// (空/0 行剔除)→ rpc record_payment(分录、单据、核销一个事务)。
// 敞口/归属/期间锁等校验在 DB 内,错误码本地化后展示;成功跳收付款详情。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizePaymentError } from '../../paymentErrorCodes'

export type CreatePaymentState = { error?: string }

export async function createPayment(
    _prevState: CreatePaymentState,
    formData: FormData
): Promise<CreatePaymentState> {
    const t = await getTranslations()

    const direction = formData.get('direction') === 'out' ? 'out' : 'in'
    const counterpartyId = String(formData.get('counterparty_id') ?? '').trim()
    const amountRaw = String(formData.get('amount') ?? '').trim()
    const currency = String(formData.get('currency') ?? 'USD')
    const fxRaw = String(formData.get('fx_rate') ?? '').trim()
    const bank = String(formData.get('bank_account') ?? '').trim()
    const paymentDate = String(formData.get('payment_date') ?? '').trim()
    const notes = String(formData.get('notes') ?? '').trim()

    // 前置校验(与 DB 二道防线一致,先给友好错误)
    if (!counterpartyId) {
        return { error: t('finance.errors.COUNTERPARTY_NOT_FOUND') }
    }
    const amount = Number(amountRaw)
    if (!amountRaw || Number.isNaN(amount) || amount <= 0) {
        return { error: t('finance.errors.AMOUNT_INVALID') }
    }
    let fxRate: number | undefined
    if (currency !== 'USD') {
        const fx = Number(fxRaw)
        if (!fxRaw || Number.isNaN(fx) || fx <= 0) {
            return { error: t('finance.errors.FX_RATE_REQUIRED', { 0: currency }) }
        }
        fxRate = fx
    }
    if (!paymentDate || Number.isNaN(Date.parse(paymentDate))) {
        return { error: t('finance.errDate') }
    }

    // 核销行:空/0/非法金额的行直接剔除(挂账 = 全部不核销,允许)。
    // 键按行的 alloc_kind 选:in → sales_record_id;
    // out → inbound_batch_id / expense_id / purchase_order_id(预付,分录借 1300)。
    const allocIds = formData.getAll('alloc_id').map(String)
    const allocKinds = formData.getAll('alloc_kind').map(String)
    const allocAmounts = formData.getAll('alloc_amount').map(String)
    type Alloc = {
        sales_record_id?: string
        inbound_batch_id?: string
        expense_id?: string
        purchase_order_id?: string
        amount_usd: number
    }
    const allocations: Alloc[] = []
    for (let i = 0; i < allocIds.length; i++) {
        const v = Number(allocAmounts[i])
        if (!allocIds[i] || !allocAmounts[i] || Number.isNaN(v) || v <= 0) continue
        if (direction === 'in') {
            allocations.push({ sales_record_id: allocIds[i], amount_usd: v })
        } else if (allocKinds[i] === 'expense') {
            allocations.push({ expense_id: allocIds[i], amount_usd: v })
        } else if (allocKinds[i] === 'purchase_order') {
            allocations.push({ purchase_order_id: allocIds[i], amount_usd: v })
        } else {
            allocations.push({ inbound_batch_id: allocIds[i], amount_usd: v })
        }
    }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('record_payment', {
        p_direction: direction,
        p_counterparty_id: counterpartyId,
        p_amount: amount,
        p_currency: currency,
        p_fx_rate: fxRate, // USD 时不传,DB 强制 1
        p_bank_account: bank || undefined,
        p_payment_date: paymentDate,
        p_notes: notes || undefined,
        p_allocations: allocations,
    })

    if (error) {
        return { error: await localizePaymentError(error.message) }
    }

    const paymentId = (data as { payment_id?: string } | null)?.payment_id

    revalidatePath('/finance')
    revalidatePath('/finance/journal')
    revalidatePath('/finance/receivables')
    revalidatePath('/finance/payables')
    revalidatePath('/finance/payments')

    if (paymentId) {
        redirect(`/finance/payments/${paymentId}`)
    }
    redirect('/finance/payments')
}
