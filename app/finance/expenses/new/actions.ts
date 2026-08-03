'use server'

// 开支登记:表单 → rpc record_expense(校验、无缝编号、自动分录一个事务)。
// paid → 借费用科目/贷银行;unpaid → 借费用科目/贷 2000 应付(成为 AP 单据)。
// 科目/供应商/期间锁等校验在 DB 内,错误码本地化后展示;成功跳开支详情。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeExpenseError } from '../../expenseErrorCodes'

export type CreateExpenseState = { error?: string }

export async function createExpense(
    _prevState: CreateExpenseState,
    formData: FormData
): Promise<CreateExpenseState> {
    const t = await getTranslations()

    const expenseDate = String(formData.get('expense_date') ?? '').trim()
    const accountCode = String(formData.get('account_code') ?? '').trim()
    const amountRaw = String(formData.get('amount') ?? '').trim()
    const currency = String(formData.get('currency') ?? 'SGD')
    const paymentStatus = formData.get('payment_status') === 'paid' ? 'paid' : 'unpaid'
    const bank = String(formData.get('bank_account') ?? '').trim()
    const supplierId = String(formData.get('supplier_id') ?? '').trim()
    const payeeName = String(formData.get('payee_name') ?? '').trim()
    const notes = String(formData.get('notes') ?? '').trim()

    // 前置校验(与 DB 二道防线一致,先给友好错误)
    if (!expenseDate || Number.isNaN(Date.parse(expenseDate))) {
        return { error: t('finance.errDate') }
    }
    if (!accountCode) {
        return { error: t('expense.errors.ACCOUNT_NOT_FOUND', { 0: '?' }) }
    }
    const amount = Number(amountRaw)
    if (!amountRaw || Number.isNaN(amount) || amount <= 0) {
        return { error: t('expense.errors.AMOUNT_INVALID') }
    }
    if (paymentStatus === 'unpaid' && !supplierId) {
        return { error: t('expense.errors.SUPPLIER_REQUIRED_FOR_UNPAID') }
    }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('record_expense', {
        p_expense_date: expenseDate,
        p_account_code: accountCode,
        p_amount: amount,
        p_currency: currency,
        // FIN-0:不传汇率 —— 外币按费用日行方卖出价自动估值,当天缺牌价 DB 直接拒
        p_payment_status: paymentStatus,
        p_bank_account: paymentStatus === 'paid' ? bank || undefined : undefined,
        p_supplier_id: paymentStatus === 'unpaid' ? supplierId : undefined,
        p_payee_name: payeeName || undefined,
        p_notes: notes || undefined,
    })

    if (error) {
        return { error: await localizeExpenseError(error.message) }
    }

    const expenseId = (data as { expense_id?: string } | null)?.expense_id

    revalidatePath('/finance')
    revalidatePath('/finance/journal')
    revalidatePath('/finance/payables')
    revalidatePath('/finance/expenses')

    if (expenseId) {
        redirect(`/finance/expenses/${expenseId}`)
    }
    redirect('/finance/expenses')
}
