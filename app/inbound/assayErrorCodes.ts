import { getTranslations } from '@/lib/i18n/server'

// 化验相关 DB 函数(record_assay_result / apply_assay_result / unapply_assay_result,
// 以及它们内部调用的 calculate_metal_price 与 reprice_inbound_batch)抛出的错误码。
// 端口自 paymentErrorCodes.ts。不在集合内的是真正未编码的 DB 错误,原样返回。
const ASSAY_ERROR_CODES = new Set([
    'INBOUND_NOT_FOUND', 'ASSAY_DATE_INVALID', 'NO_METALS',
    'METAL_INVALID', 'CONTENT_INVALID', 'DUPLICATE_METAL',
    'ASSAY_NOT_FOUND', 'ASSAY_ALREADY_APPLIED', 'NOT_LATEST_ASSAY',
    'REASON_REQUIRED', 'FORMULA_NOT_FOUND', 'FORMULA_INACTIVE',
    // 重计价路径(reprice_inbound_batch)可能抛的
    'PRICE_INVALID', 'QUANTITY_INVALID', 'PERIOD_LOCKED',
    // FIN-27:结算读承诺副本 —— 没有副本就点名拒,不悄悄退回去读活公式
    'PRICING_TERMS_NOT_COMMITTED', 'PRICING_TERMS_ALREADY_COMMITTED',
    'PRICE_NOT_POSITIVE', 'REFERENCE_DATE_REQUIRED',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeFinanceError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeAssayError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    // cut 2b:calculate_metal_price / preview_reprice_inbound_batch 现在会对没有
    // data.view_prices 的人抛 PERMISSION_DENIED。那【不是错误】,是这个人不该看见价格 ——
    // 所以显示「受限」,而不是把一串权限码摔到现场人员脸上。
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await getTranslations())('common.restricted')
    }

    if (!match || !ASSAY_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('assay.errors.' + code, params)
}
