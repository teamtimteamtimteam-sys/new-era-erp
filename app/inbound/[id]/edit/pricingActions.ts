'use server'

// 进料补价:唯一合法的 unit_price 变更路径(cut 1),走 set_inbound_unit_price RPC,
// 每次变更留 price_history 审计行。直接 UPDATE 会被 DB 触发器以 PRICE_VIA_FUNCTION 拒绝。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

export type SetPriceState = { error?: string; success?: boolean }

// set_inbound_unit_price 抛出的错误码(镜像 saleErrorCodes 的宽松解析)
const PRICING_ERROR_CODES = new Set([
    'FX_RATE_MISSING', 'FX_RATE_NOT_ACCEPTED',
    'INBOUND_NOT_FOUND', 'PRICE_INVALID', 'CURRENCY_INVALID', 'FX_RATE_REQUIRED',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

async function localizePricingError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()
    const match = raw.match(CODE_RE)

    if (!match || !PRICING_ERROR_CODES.has(match[1])) {
        // ★★ BUGFIX-1b:这一支【不】原样吐生字符串,它把原文塞进一句模板
        //   (「保存失败:{message}」)—— 于是生码照样到屏幕上,只是外面包了一层。
        //   round 1 按「return raw」数映射器,所以它没被算进那 45 支里。
        //   ☞ 生码 / 数据库报错走共用兜底;【人话句子仍然走原来那句模板】,
        //     一个字都没改 —— 那是 Tim 的条件(人话的措辞归 POLISH-1)。
        const fallback = await fallbackForRawError(raw, 'localizePricingError@app/inbound/[id]/edit/pricingActions.ts')
        if (fallback !== raw) return fallback
        return t('inbound.pricing.saveError', { message: raw })
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v
        })
    }
    return t('inbound.pricing.errors.' + code, params)
}

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
    const { error } = await supabase.rpc('set_inbound_unit_price', {
        p_inbound_batch_id: batchId,
        p_unit_price: price,
        p_currency: currency,
        p_notes: notes || undefined,
    })

    if (error) {
        return { error: await localizePricingError(error.message) }
    }

    revalidatePath('/inbound')
    revalidatePath(`/inbound/${batchId}/edit`)
    revalidatePath('/inventory')
    return { success: true }
}
