import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

// 定价引擎(calculate_metal_price / upsert_metal_prices)抛出的错误码,
// 端口自 paymentErrorCodes.ts。不在集合内的是真正未编码的 DB 错误,交给共用兜底 lib/machine-text.ts。
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
    // MES-6a-2(MES-6a Step 0 Q27):表上的守卫与写入函数按名拒 —— 行情、计价器、公式、合同的计价条款 / 精炼费 / 惩罚条款
    //   (合同条款与公式申请的拒绝经 termsRequestErrorCodes 转交到这里)
    'SUBSTANCE_NOT_PAYABLE', 'SUBSTANCE_NOT_PENALTY_ELEMENT',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeFinanceError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizePricingError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !PRICING_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizePricingError@app/tools/pricing/pricingErrorCodes.ts') // BUGFIX-1b:生码 / 数据库报错 → 一句人话 + 一个可追查的短码(人话句子原样留着)
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    const t = await getTranslations()
    // MES-6a-2:物质那两句点名的是码(f / cl / cu)—— 翻成名字再说;字典里每一个码都有 metals.<码>(check-i18n 读引导行核对)
    if ((code === 'SUBSTANCE_NOT_PAYABLE' || code === 'SUBSTANCE_NOT_PENALTY_ELEMENT') && params['0']) {
        params['0'] = t('metals.' + params['0'])
    }
    return t('pricing.errors.' + code, params)
}
