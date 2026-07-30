import { getTranslations } from '@/lib/i18n/server'

// 定价引擎(calculate_metal_price / upsert_metal_prices)抛出的错误码,
// 端口自 paymentErrorCodes.ts。不在集合内的是真正未编码的 DB 错误,原样返回。
const PRICING_ERROR_CODES = new Set([
    'FORMULA_NOT_FOUND', 'FORMULA_INACTIVE', 'QUANTITY_INVALID', 'NO_METALS',
    'METAL_INVALID', 'CONTENT_INVALID', 'DUPLICATE_METAL', 'PRICE_INVALID',
    'PRICE_DATE_REQUIRED', 'NO_PRICES',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeFinanceError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizePricingError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !PRICING_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('pricing.errors.' + code, params)
}
