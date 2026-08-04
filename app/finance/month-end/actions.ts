'use server'

// 月结各步的服务端动作(FIN-7)。守卫全在 DB;这里只翻错误、刷页面。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizePaymentError } from '../paymentErrorCodes'
import { localizeHrError } from '@/app/hr/hrErrorCodes'
import { localizeProcessingError } from '@/app/processing/errorCodes'
import { getTranslations } from '@/lib/i18n/server'

export type ActState = { error?: string; success?: boolean; result?: string }

function refresh() {
    for (const p of ['/finance/month-end', '/finance/payroll-payments', '/finance/processing-costs',
                     '/finance/revaluation', '/finance/journal', '/finance', '/hr'])
        revalidatePath(p)
}

export async function payLines(periodId: string, lineIds: string[], date: string, bank: string): Promise<ActState> {
    const supabase = await createClient()
    // 【必填】留空原本会被 COALESCE(p_payment_date, CURRENT_DATE) 悄悄换成今天,
    // 把整月薪资过进错的期间;而且"今天"永远撞不上 PERIOD_LOCKED —— 填对日期会报错,
    // 留空反而滑得过去。见 finance/payroll-payments/PayPanel.tsx 的注释。
    if (!date) return { error: (await getTranslations())('finance.costSettle.dateRequired') }
    const { error } = await supabase.rpc('pay_payroll_lines', {
        p_payroll_period_id: periodId, p_line_ids: lineIds,
        p_payment_date: date, p_bank_account: bank || undefined,
    })
    if (error) return { error: await localizeHrError(error.message) }
    refresh(); return { success: true }
}

export async function payCpf(periodId: string, date: string): Promise<ActState> {
    const supabase = await createClient()
    if (!date) return { error: (await getTranslations())('finance.costSettle.dateRequired') }
    const { error } = await supabase.rpc('pay_payroll_cpf', {
        p_payroll_period_id: periodId, p_payment_date: date,
    })
    if (error) return { error: await localizeHrError(error.message) }
    refresh(); return { success: true }
}

export async function payDeductions(periodId: string, date: string): Promise<ActState> {
    const supabase = await createClient()
    if (!date) return { error: (await getTranslations())('finance.costSettle.dateRequired') }
    const { error } = await supabase.rpc('pay_payroll_deductions', {
        p_payroll_period_id: periodId, p_payment_date: date,
    })
    if (error) return { error: await localizeHrError(error.message) }
    refresh(); return { success: true }
}

export async function remitCosts(entryIds: string[], date: string, bank: string): Promise<ActState> {
    const supabase = await createClient()
    // 【日期必填,不许默认】它决定这笔进哪个会计期间。原本 `date || undefined` 把空值
    // 变成不传,函数 COALESCE(p_payment_date, CURRENT_DATE) 于是【静默按今天过账】——
    // 七月的应计在八月结掉,差异就落在错的月份,而屏幕上没有任何迹象。
    // 冲抵那半边则是空串直接递到 Postgres 报 22007:同一个表单,一个看得见一个看不见。
    if (!date) return { error: (await getTranslations())('finance.costSettle.dateRequired') }
    const { error } = await supabase.rpc('remit_processing_costs', {
        p_entry_ids: entryIds, p_payment_date: date, p_bank_account: bank || undefined,
    })
    if (error) return { error: await localizeProcessingError(error.message) }
    refresh(); return { success: true }
}

export async function relieveAccruals(input: {
    entryIds: string[]; actual: number; date: string
    paymentStatus: string; bank: string; supplierId: string
}): Promise<ActState> {
    const supabase = await createClient()
    // 同上:必填。空串原样递进去会在 Postgres 炸出 22007(界面只会看到一句天书)。
    if (!input.date) return { error: (await getTranslations())('finance.costSettle.dateRequired') }
    const { error, data } = await supabase.rpc('relieve_processing_accruals', {
        p_entry_ids: input.entryIds, p_actual_amount: input.actual, p_expense_date: input.date,
        p_payment_status: input.paymentStatus,
        p_bank_account: input.paymentStatus === 'paid' ? input.bank || undefined : undefined,
        p_supplier_id: input.supplierId || undefined,
    })
    if (error) return { error: await localizeProcessingError(error.message) }
    refresh(); return { success: true, result: JSON.stringify(data) }
}

export async function runRevaluation(periodEnd: string): Promise<ActState> {
    const supabase = await createClient()
    const { error, data } = await supabase.rpc('revalue_foreign_balances', { p_period_end: periodEnd })
    if (error) return { error: await localizePaymentError(error.message) }
    refresh(); return { success: true, result: JSON.stringify(data) }
}

export async function reverseTransfer(transferId: string): Promise<ActState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('reverse_bank_transfer', { p_transfer_id: transferId })
    if (error) return { error: await localizePaymentError(error.message) }
    refresh(); revalidatePath('/finance/bank'); return { success: true }
}
