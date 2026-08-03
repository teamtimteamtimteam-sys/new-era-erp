import { getTranslations } from '@/lib/i18n/server'

// 采购与预付款相关 DB 函数(create_purchase_order / cancel_purchase_order /
// apply_payment_term_template / apply_prepayment,以及 record_payment 的 PO 预付分支)
// 抛出的错误码(端口自 paymentErrorCodes.ts)。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,原样返回。
const PURCHASING_ERROR_CODES = new Set([
    'FX_RATE_MISSING', 'FX_RATE_NOT_ACCEPTED',
    'SUPPLIER_NOT_FOUND', 'NO_LINES', 'MATERIAL_NOT_FOUND', 'LINE_QTY_INVALID',
    'FORMULA_NOT_FOUND', 'FORMULA_INACTIVE', 'TERMS_SEQ_INVALID', 'TERMS_PCT_EXCEEDS',
    'PO_NOT_FOUND', 'PO_CANCELLED', 'PO_HAS_RECEIPTS', 'TEMPLATE_NOT_FOUND',
    'PREPAY_EXCEEDS_ESTIMATE', 'PREPAY_INSUFFICIENT', 'EXCEEDS_OPEN',
    'SUPPLIER_MISMATCH', 'INBOUND_UNPRICED', 'AMOUNT_INVALID',
    'ALLOC_WRONG_PARTY', 'PO_LINE_MISMATCH',
    // cut 4c:收货联动与结束/重开
    'PO_NOT_RECEIVABLE', 'PO_ALREADY_CLOSED', 'PO_NOT_CLOSED',
    'CLOSE_NOTES_REQUIRED', 'REASON_REQUIRED',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeFinanceError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizePurchasingError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !PURCHASING_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('purchasing.errors.' + code, params)
}
