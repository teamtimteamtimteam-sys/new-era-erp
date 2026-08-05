'use server'

import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
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
    const currency = (formData.get('currency') as string) || await getBaseCurrency()
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

    // FIN-0:不传汇率 —— 外币按销售日行方买入价(tt_buy)自动估值,缺牌价 DB 直接拒

    // 【销售日必填】留空原本走 COALESCE(p_sale_date, CURRENT_DATE) 悄悄记成"今天"。
    // 这个日期不只是个戳:它同时决定 fx_rate_for(currency, 日期, 'tt_buy') 取哪天的
    // 牌价(于是 amount_base 也跟着错)、库存流水的业务日期、以及【收入与 COGS 两张
    // 分录】落在哪个期间。表单里旁边的数量/单价都标了 required,唯独它没有,而日期
    // 输入一键就能清空 —— 最容易留空的那个,后果却最重。
    if (!sale_date) return { error: t('output.sale.errDateRequired') }

    const supabase = await createClient()
    const { error } = await supabase.rpc('record_output_sale', {
        p_output_batch_id: batchId,
        p_quantity: n,
        p_unit_price: price,
        p_currency: currency,
        p_customer_id: customer_id || undefined,
        p_sale_date: sale_date,
        p_notes: notes || undefined,
    })

    if (error) {
        return { error: await localizeSaleError(error.message) }
    }

    revalidatePath(`/output/${batchId}/edit`)
    return { success: true }
}
