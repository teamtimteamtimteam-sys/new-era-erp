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
    // FIN-0:汇率只在【跨币种】(付款币种 ≠ 银行户口本币,银行实际做了兑换)时必填,
    // 填的是水单两边实际金额折出的成交价(C4)。同币种走牌价,由 DB 自动取。
    let fxRate: number | undefined
    if (fxRaw) {
        const fx = Number(fxRaw)
        if (Number.isNaN(fx) || fx <= 0) {
            return { error: t('finance.errors.FX_RATE_INVALID', { 0: fxRaw }) }
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
        amount_base: number
    }
    const allocations: Alloc[] = []
    for (let i = 0; i < allocIds.length; i++) {
        const v = Number(allocAmounts[i])
        if (!allocIds[i] || !allocAmounts[i] || Number.isNaN(v) || v <= 0) continue
        if (direction === 'in') {
            allocations.push({ sales_record_id: allocIds[i], amount_base: v })
        } else if (allocKinds[i] === 'expense') {
            allocations.push({ expense_id: allocIds[i], amount_base: v })
        } else if (allocKinds[i] === 'purchase_order') {
            allocations.push({ purchase_order_id: allocIds[i], amount_base: v })
        } else {
            allocations.push({ inbound_batch_id: allocIds[i], amount_base: v })
        }
    }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('record_payment', {
        p_direction: direction,
        p_counterparty_id: counterpartyId,
        p_amount: amount,
        p_currency: currency,
        p_fx_rate: fxRate, // FIN-0:只有跨币种(银行实际做了兑换)才传 —— 水单实际金额折出的成交价
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
