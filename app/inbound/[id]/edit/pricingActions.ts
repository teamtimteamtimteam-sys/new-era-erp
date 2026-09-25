'use server'

// 进料补价:唯一合法的 unit_price 变更路径(cut 1),走 set_inbound_unit_price RPC,
// 每次变更留 price_history 审计行。直接 UPDATE 会被 DB 触发器以 PRICE_VIA_FUNCTION 拒绝。
// ★ ROLE-1 Batch 4b:set_inbound_unit_price 从此【提一张定价申请】—— CFO 批了才进账
//   (审批关着时申请生下来就是 approved 并当场过账)。批 / 驳 / 撤回也在这里。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { localizePricingError } from '@/app/inbound/pricingErrorCodes'

export type SetPriceState = {
    error?: string
    success?: boolean
    /** ROLE-1 Batch 4b:提出的那张申请 —— submitted(在等 CFO)或 approved(审批关着,已过账) */
    request?: { label: string; status: 'submitted' | 'approved'; journalCode: string | null }
}

// INB-PAY-1:错误码与本地化搬到 app/inbound/pricingErrorCodes.ts —— 建单带价
// 现在走同一个定价函数,两条路要说同一句话,所以只能有一份。

export async function setInboundPrice(
    batchId: string,
    _prevState: SetPriceState,
    formData: FormData
): Promise<SetPriceState> {
    const t = await getTranslations()

    const price_raw = (formData.get('price') as string) || ''
    const currency = (formData.get('currency') as string) || await getBaseCurrency()
    const fx_rate_raw = (formData.get('fx_rate') as string) || ''
    const notes = (formData.get('notes') as string)?.trim() || ''

    const price = Number(price_raw)
    if (!price_raw || Number.isNaN(price) || price <= 0) {
        return { error: t('inbound.pricing.errors.PRICE_INVALID') }
    }

    // FIN-0:不传汇率 —— 外币按定价日行方卖出价(tt_sell)自动估值,缺牌价 DB 直接拒

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('set_inbound_unit_price', {
        p_inbound_batch_id: batchId,
        p_unit_price: price,
        p_currency: currency,
        p_notes: notes || undefined,
    })

    if (error) {
        return { error: await localizePricingError(error.message) }
    }

    refreshReceipt(batchId)
    const r = data as { label?: string; status?: 'submitted' | 'approved'; journal_code?: string | null } | null
    return {
        success: true,
        request: r?.label && r.status
            ? { label: r.label, status: r.status, journalCode: r.journal_code ?? null }
            : undefined,
    }
}

function refreshReceipt(batchId: string) {
    revalidatePath('/inbound')
    revalidatePath(`/inbound/${batchId}/edit`)
    revalidatePath('/inventory')
    revalidatePath('/finance/journal')
    revalidatePath('/')
}

// ★ ROLE-1 Batch 4b:CFO 批准(当场过账)或驳回(要理由)一张收货定价申请。
//   谁能批这里不预判(二级审批角色、不是提单人 —— 按人认),拒绝由库出、就地说成人话。
export async function decideReceiptPriceRequest(
    batchId: string, requestId: string, approve: boolean, notes: string
): Promise<{ error?: string }> {
    if (!approve && notes.trim() === '') {
        return { error: (await getTranslations())('inbound.priceRequest.rejectReasonRequired') }
    }
    const supabase = await createClient()
    const { error } = await supabase.rpc('decide_receipt_price_request', {
        p_request_id: requestId,
        p_approve: approve,
        p_notes: notes.trim() || undefined,
    })
    if (error) return { error: await localizePricingError(error.message) }
    refreshReceipt(batchId)
    return {}
}

// ★ ROLE-1 Batch 4b(Tim 的 Q7):撤回 —— 提单人本人,或持 action.price_receipts 的人。
export async function withdrawReceiptPriceRequest(
    batchId: string, requestId: string, reason: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_receipt_price_request', {
        p_request_id: requestId,
        p_reason: reason.trim() || undefined,
    })
    if (error) return { error: await localizePricingError(error.message) }
    refreshReceipt(batchId)
    return {}
}
