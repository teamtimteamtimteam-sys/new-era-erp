'use server'

// MES-5a-2(2026-10-08,MES-0 Q26;MES-5a Step 0 Q24 · Q25 · Q27 · Q28 · Q32,Tim):电费单的预览、过账与 V25。
//   【分账的规则一条都不在这里】预览与过账调的是库里同一支 electricity_allocation_compute(AGENTS.md「一个预览的屏幕问数据库」):
//   这里只把输入框的字符串变成参数,原样送去,原样拿回来画。拒绝经 localizeEnergyError 说成人话。
//   【币种】账单只收本位币(Q28)—— 页面不提供别的币种(服务端一定拒的组合不摆出来),这里送的是从数据读出来的本位币。
//   【日期与金额】时间段、账单日、金额、kWh 决定期间与金额:没有默认值,空就送 null 让库按名拒;页面上的按钮也在它们为空时按不下去。
//   码:预览 module.finance.view;过账与 V25 module.finance.edit(库里问同一个)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getBaseCurrency } from '@/lib/currency'
import { bankAccountFor } from '@/lib/currencyMap'
import { localizeEnergyError } from './energyErrorCodes'

export type AllocationInput = {
    periodFrom: string
    periodTo: string
    billDate: string
    invoiceRef: string
    billAmount: string
    billKwh: string
    paymentStatus: 'unpaid' | 'paid'
    supplierId: string
    payeeName: string
    notes: string
}

export type AllocationPreview = {
    period_from: string; period_to: string; currency: string
    bill_amount: number; bill_kwh: number; price_per_kwh: number
    metered_kwh: number; allocated_kwh: number; shared_pool_kwh: number; unallocated_metered_kwh: number; unmetered_kwh: number
    allocated_amount: number; overhead_amount: number; relieved_estimate_amount: number; relieved_estimate_count: number
    shared_pool_rule: string | null
    machines: { equipment_id: string; equipment_code: string; description: string; measured: boolean; kwh: number | null; basis: string | null; runs: number;
                meters: { device_id: string; code: string; name: string; kwh: number | null; readings: number; has_reset: boolean; measured: boolean }[] }[]
    pool_meters: { device_id: string; code: string; name: string; kwh: number | null; readings: number; has_reset: boolean; measured: boolean }[]
    runs: { run_id: string; code: string; equipment_code: string; basis: string; own_kwh: number | null; minutes: number | null; weight: number;
            share: number; machine_kwh: number; kwh: number; amount: number }[]
    estimates: { id: string; run_id: string; run_code: string; amount: number }[]
    journal: { account_code: string; side: 'debit' | 'credit'; amount_ccy: number; line_memo: string }[]
}

const opt = (s: string) => (s.trim() === '' ? undefined : s.trim())
const req = (s: string) => (s.trim() === '' ? null : s.trim()) as string
/** 写不成数的不能送过去(JSON 里 NaN 是 null,而 null 的意思是"没给"):先按库里那条码说出来 */
function num(raw: string): number | null | 'bad' {
    const s = raw.trim()
    if (s === '') return null
    const n = Number(s)
    return Number.isFinite(n) ? n : 'bad'
}

async function common(r: AllocationInput) {
    const amount = num(r.billAmount)
    if (amount === 'bad') return { error: await localizeEnergyError('ELECTRICITY_BILL_AMOUNT_INVALID') }
    const kwh = num(r.billKwh)
    if (kwh === 'bad') return { error: await localizeEnergyError('ELECTRICITY_BILL_KWH_INVALID') }
    const base = await getBaseCurrency()
    return {
        args: {
            p_period_from: req(r.periodFrom), p_period_to: req(r.periodTo),
            p_bill_amount: amount as number, p_bill_kwh: kwh as number, p_currency: base,
            p_payment_status: r.paymentStatus, p_bank_account: r.paymentStatus === 'paid' ? bankAccountFor(base) : undefined,
        },
    }
}

export async function previewAllocation(r: AllocationInput): Promise<{ error?: string; preview?: AllocationPreview }> {
    const c = await common(r)
    if ('error' in c) return { error: c.error }
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('preview_electricity_allocation', c.args)
    if (error) return { error: await localizeEnergyError(error.message) }
    return { preview: data as unknown as AllocationPreview }
}

export async function postAllocation(r: AllocationInput): Promise<{ error?: string; allocationId?: string }> {
    const c = await common(r)
    if ('error' in c) return { error: c.error }
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('post_electricity_allocation', {
        ...c.args, p_bill_date: req(r.billDate), p_invoice_ref: req(r.invoiceRef),
        p_supplier_id: opt(r.supplierId), p_payee_name: opt(r.payeeName), p_notes: opt(r.notes),
    })
    if (error) return { error: await localizeEnergyError(error.message) }
    const out = data as unknown as { allocation_id: string; expense_id: string }
    revalidatePath('/finance/electricity')
    revalidatePath('/finance/expenses')
    revalidatePath('/finance/payables')
    revalidatePath('/finance/processing-costs')
    revalidatePath('/settings/pending-values')
    return { allocationId: out.allocation_id }
}

export async function setSharedPoolRule(rule: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_electricity_shared_pool_rule', { p_rule: rule.trim() })
    if (error) return { error: await localizeEnergyError(error.message) }
    revalidatePath('/finance/electricity')
    revalidatePath('/settings/pending-values')
    return {}
}

/** MES-5b-2(Q22):撤回一张电费单。理由原样送下去(库里 btrim 后为空就按名拒 ELECTRICITY_REVERSAL_REASON_REQUIRED)——
 *  这里不判任何东西:撤回过没有、经付款结过没有、期间锁没锁,全部由 reverse_electricity_allocation 判(reverseFreight 的同一条)。 */
export async function reverseAllocation(id: string, reason: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('reverse_electricity_allocation', { p_allocation_id: id, p_reason: reason })
    if (error) return { error: await localizeEnergyError(error.message) }
    revalidatePath('/finance/electricity')
    revalidatePath(`/finance/electricity/${id}`)
    revalidatePath('/finance/expenses')
    revalidatePath('/finance/payables')
    revalidatePath('/finance/processing-costs')
    revalidatePath('/finance/month-end')
    return {}
}
