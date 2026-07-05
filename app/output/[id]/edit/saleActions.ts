'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { localizeSaleError } from './saleErrorCodes'

export type SaleState = { error?: string; success?: boolean }

export async function recordSale(
    batchId: string,
    _prevState: SaleState,
    formData: FormData
): Promise<SaleState> {
    const t = await getTranslations()

    const quantity_raw = (formData.get('quantity') as string) || ''
    const unit_price_raw = (formData.get('unit_price') as string) || ''
    const currency = (formData.get('currency') as string) || 'USD'
    const fx_rate_raw = (formData.get('fx_rate') as string) || ''
    const customer_id = (formData.get('customer_id') as string) || ''
    const sale_date = (formData.get('sale_date') as string)?.trim() || ''
    const notes = (formData.get('notes') as string)?.trim() || ''

    const n = Number(quantity_raw)
    if (!quantity_raw || Number.isNaN(n) || n <= 0) {
        return { error: t('output.sale.errQuantity') }
    }

    // 售价必填(cut 1:关闭"销售无金额"缺口);DB 端还会再校一次
    const price = Number(unit_price_raw)
    if (!unit_price_raw || Number.isNaN(price) || price <= 0) {
        return { error: t('output.sale.errors.SALE_PRICE_INVALID') }
    }

    // 非 USD 必须给汇率;USD 由 DB 强制 fx=1,不传
    let fx_rate: number | undefined
    if (currency !== 'USD') {
        const fx = Number(fx_rate_raw)
        if (!fx_rate_raw || Number.isNaN(fx) || fx <= 0) {
            return { error: t('output.sale.errors.FX_RATE_REQUIRED', { 0: currency }) }
        }
        fx_rate = fx
    }

    const supabase = await createClient()
    const { error } = await supabase.rpc('record_output_sale', {
        p_output_batch_id: batchId,
        p_quantity: n,
        p_unit_price: price,
        p_currency: currency,
        p_fx_rate: fx_rate,
        p_customer_id: customer_id || undefined,
        p_sale_date: sale_date || undefined,
        p_notes: notes || undefined,
    })

    if (error) {
        return { error: await localizeSaleError(error.message) }
    }

    revalidatePath(`/output/${batchId}/edit`)
    return { success: true }
}
