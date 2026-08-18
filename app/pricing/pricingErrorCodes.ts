import { getTranslations } from '@/lib/i18n/server'

// 定价引擎(calculate_metal_price / upsert_metal_prices)抛出的错误码,
// 端口自 paymentErrorCodes.ts。不在集合内的是真正未编码的 DB 错误,原样返回。
const PRICING_ERROR_CODES = new Set([
    'REFERENCE_DATE_REQUIRED',
    'FORMULA_NOT_FOUND', 'FORMULA_INACTIVE', 'QUANTITY_INVALID', 'NO_METALS',
    'METAL_INVALID', 'CONTENT_INVALID', 'DUPLICATE_METAL', 'PRICE_INVALID',
    'PRICE_DATE_REQUIRED', 'NO_PRICES',
    // METAL-2:指数相关的两种拒绝。INDEX_CURRENCY_NOT_STATED 是【设计好的】那一种:
    // 报价币种没人声明之前,按那个指数算钱会被拦下 —— 拦下来是产品,不是故障。
    'INDEX_CURRENCY_NOT_STATED', 'PRICE_INDEX_UNKNOWN',
    // LME-1a:出处必填之后 upsert_metal_prices 会抛这四个。不登记它们,
    // 屏幕上出现的就是机器码(IOD-2 那一课)—— 而录入表单在 1b 之前
    // 【本来就会撞上第一个】,所以这四条文案是此刻最要紧的东西。
    'QUOTE_SOURCE_REQUIRED', 'QUOTE_SOURCE_INVALID',
    'QUOTE_SOURCE_UNKNOWN_NOT_ALLOWED_FOR_NEW', 'QUOTE_SOURCE_INDEX_REQUIRED',
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
