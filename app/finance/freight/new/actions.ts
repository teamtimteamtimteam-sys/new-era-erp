'use server'

// 运费单据的写入(FRT-1)。判据与过账全在 record_freight_document 里 ——
// 页面【不自己算分摊】,与 preview_revalue_foreign_balances / reprice_split 同一条:
// 两份算术会在写下的那天一致,此后各自漂移,而屏幕上那份是人相信的那份。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeFreightError } from '../../freightErrorCodes'

export type FreightState = { error?: string }

export async function createFreightDocument(
    _prev: FreightState,
    formData: FormData
): Promise<FreightState> {
    const docDate = String(formData.get('doc_date') ?? '').trim()
    const supplierId = String(formData.get('supplier_id') ?? '').trim()
    const amount = String(formData.get('amount') ?? '').trim()
    const currency = String(formData.get('currency') ?? '').trim()
    const basis = String(formData.get('allocation_basis') ?? '').trim()
    const paymentStatus = String(formData.get('payment_status') ?? 'unpaid').trim()
    const bank = String(formData.get('bank_account_code') ?? '').trim() || null
    const notes = String(formData.get('notes') ?? '').trim() || null

    // 并列数组:勾选的批次 + (stated 口径时)逐批金额
    const batchIds = formData.getAll('batch_id').map(String)
    const stated = formData.getAll('stated_amount').map(String)
    const allocations = batchIds.map((id, i) => ({
        inbound_batch_id: id,
        ...(basis === 'stated' ? { amount_base: (stated[i] ?? '').trim() || null } : {}),
    }))

    const supabase = await createClient()
    const { error } = await supabase.rpc('record_freight_document', {
        // 必填项【不在这里兜底】:空值原样送下去,由 record_freight_document
        // 点名拒绝(FIN-10 的规矩 —— 决定期间与汇率的字段绝不给默认值)
        p_doc_date: docDate,
        p_supplier_id: supplierId,
        p_amount: amount ? Number(amount) : 0,
        p_currency: currency,
        p_allocation_basis: basis,
        p_payment_status: paymentStatus,
        p_bank_account: bank ?? undefined,
        p_allocations: allocations,
        p_notes: notes ?? undefined,
    })

    if (error) return { error: await localizeFreightError(error.message) }

    revalidatePath('/finance/freight')
    revalidatePath('/finance/payables')
    redirect('/finance/freight')
}
