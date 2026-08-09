'use server'

import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { localizeSaleError } from './saleErrorCodes'

export type SaleState = { error?: string; success?: boolean }

export type QuoteState = {
    error?: string
    unitPrice?: number
    currency?: string
    provenance?: unknown
    summary?: { mode: string; usdPerKg: number; fxFactor: number; fxSide: string; series: string }
}

// SAL-A:卖方报价 —— 【问数据库】(price_output_sale),不在 TS 里再实现一遍算术。
// 【汇率的边在 DB 函数里定死为 tt_buy(收钱进来)】—— 买路径的 computeLineEstimate
// 用 tt_sell(付钱出去),两者共用同一扇门 fx_rate_asof,边是参数,不是两份实现。
export async function quoteSalePrice(
    batchId: string,
    formData: FormData
): Promise<QuoteState> {
    const t = await getTranslations()
    const formulaId = (formData.get('quote_formula_id') as string) || null   // 空 = 现货预设
    const currency = (formData.get('currency') as string) || (await getBaseCurrency())
    const quantity = Number((formData.get('quantity') as string) || '')
    const saleDate = (formData.get('sale_date') as string)?.trim() || ''
    if (!saleDate) return { error: t('output.sale.errDateRequired') }
    if (!Number.isFinite(quantity) || quantity <= 0) return { error: t('output.sale.errQuantity') }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('price_output_sale', {
        p_output_batch_id: batchId,
        p_formula_id: formulaId as unknown as string,
        p_currency: currency,
        p_quantity: quantity,
        p_reference_date: saleDate,
    })
    if (error) return { error: await localizeSaleError(error.message) }
    const r = data as unknown as {
        unit_price_ccy: number
        currency: string
        provenance: { mode: string; unit_price_usd_per_kg: number; price_series: string;
                      fx: { factor: number; side: string } }
    }
    return {
        unitPrice: Number(r.unit_price_ccy),
        currency: r.currency,
        provenance: r.provenance,
        summary: {
            mode: r.provenance.mode,
            usdPerKg: Number(r.provenance.unit_price_usd_per_kg),
            fxFactor: Number(r.provenance.fx.factor),
            fxSide: r.provenance.fx.side,
            series: r.provenance.price_series,
        },
    }
}

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
    // SAL-A:出处随行 —— computed 带依据(报价按钮的返回值原样传),manual 明说。
    // 报价后手改了价格 → 表单把 source 退回 manual 并丢弃依据(见 SalePanel):
    // 一个改过的数字挂着"算出来的"依据,正是 FIN-26 修掉的那种误读。
    const price_source = (formData.get('price_source') as string) || 'manual'
    const provenance_raw = (formData.get('price_provenance') as string) || ''
    const { error } = await supabase.rpc('record_output_sale', {
        p_output_batch_id: batchId,
        p_quantity: n,
        p_unit_price: price,
        p_currency: currency,
        p_customer_id: customer_id || undefined,
        p_sale_date: sale_date,
        p_notes: notes || undefined,
        p_price_source: price_source === 'computed' ? 'computed' : 'manual',
        p_price_provenance:
            price_source === 'computed' && provenance_raw ? JSON.parse(provenance_raw) : undefined,
    })

    if (error) {
        return { error: await localizeSaleError(error.message) }
    }

    revalidatePath(`/output/${batchId}/edit`)
    return { success: true }
}
