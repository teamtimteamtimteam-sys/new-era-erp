// app/inbound/pricingErrorCodes.ts
// 进料定价的具名拒绝 → 人话。INB-PAY-1 之前它住在 [id]/edit/pricingActions.ts 里;
// 建单带价现在走【同一个】定价函数(create_inbound_batch → reprice_inbound_batch),
// 于是两条路抛同一组码,也必须翻成同一句话 —— 一份清单、一个翻译器。
import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

// set_inbound_unit_price 抛出的错误码(镜像 saleErrorCodes 的宽松解析)
export const PRICING_ERROR_CODES = new Set([
    'FX_RATE_MISSING', 'FX_RATE_NOT_ACCEPTED',
    'INBOUND_NOT_FOUND', 'PRICE_INVALID', 'CURRENCY_INVALID', 'FX_RATE_REQUIRED',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizePricingError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()
    const match = raw.match(CODE_RE)

    if (!match || !PRICING_ERROR_CODES.has(match[1])) {
        // ★★ BUGFIX-1b:这一支【不】原样吐生字符串,它把原文塞进一句模板
        //   (「保存失败:{message}」)—— 于是生码照样到屏幕上,只是外面包了一层。
        //   round 1 按「return raw」数映射器,所以它没被算进那 45 支里。
        //   ☞ 生码 / 数据库报错走共用兜底;【人话句子仍然走原来那句模板】,
        //     一个字都没改 —— 那是 Tim 的条件(人话的措辞归 POLISH-1)。
        const fallback = await fallbackForRawError(raw, 'localizePricingError@app/inbound/pricingErrorCodes.ts')
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

// 这条消息是不是定价那一组的码(建单那条路据此决定走哪个翻译器)
export function isPricingErrorCode(message: string | undefined | null): boolean {
    const m = (message ?? '').trim().match(CODE_RE)
    return !!m && PRICING_ERROR_CODES.has(m[1])
}
