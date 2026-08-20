import { getTranslations } from '@/lib/i18n/server'

// 采购与预付款相关 DB 函数(create_purchase_order / cancel_purchase_order /
// apply_payment_term_template / apply_prepayment,以及 record_payment 的 PO 预付分支)
// 抛出的错误码(端口自 paymentErrorCodes.ts)。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,原样返回。
const PURCHASING_ERROR_CODES = new Set([
    'ORDER_DATE_REQUIRED',
    'FX_RATE_MISSING', 'FX_RATE_NOT_ACCEPTED',
    'SUPPLIER_NOT_FOUND', 'NO_LINES', 'MATERIAL_NOT_FOUND', 'LINE_QTY_INVALID',
    'FORMULA_NOT_FOUND', 'FORMULA_INACTIVE', 'TERMS_SEQ_INVALID', 'TERMS_PCT_EXCEEDS',
    'PO_NOT_FOUND', 'PO_CANCELLED', 'PO_HAS_RECEIPTS', 'TEMPLATE_NOT_FOUND',
    'PREPAY_EXCEEDS_ESTIMATE', 'PREPAY_INSUFFICIENT', 'EXCEEDS_OPEN',
    'SUPPLIER_MISMATCH', 'INBOUND_UNPRICED', 'AMOUNT_INVALID',
    // FIN-26:行价出处
    'PRICE_SOURCE_INVALID', 'PROVENANCE_REQUIRED',
    // FIN-29:模板定额腿的币种 —— 未声明 / 与单据不同,都拒(不换算)
    'TEMPLATE_CURRENCY_REQUIRED', 'TEMPLATE_CURRENCY_UNDECLARED', 'TEMPLATE_CURRENCY_MISMATCH',
    // FIN-27:下单即抄下结算条款(承诺时刻);副本不可改写
    'PRICING_TERMS_NOT_COMMITTED', 'PRICING_TERMS_ALREADY_COMMITTED',
    'PRICING_COMMITMENT_IMMUTABLE', 'COMMITMENT_TARGET_INVALID',
    'ALLOC_WRONG_PARTY', 'PO_LINE_MISMATCH',
    // cut 4c:收货联动与结束/重开
    'PO_NOT_RECEIVABLE', 'PO_ALREADY_CLOSED', 'PO_NOT_CLOSED',
    'CLOSE_NOTES_REQUIRED', 'REASON_REQUIRED',
    // EQP-1a:采购单装得下一台机器之后,新出现的四条具名拒绝
    'PO_LINE_KIND_INVALID', 'ASSET_NOT_FOUND',
    'PO_LINES_MIXED_KINDS', 'PO_LINE_EQUIPMENT_NOT_RECEIVABLE',
    // CMP-2:这两个码一直会从收货触发器抛出,却不在这张表里 —— 打到操作员脸上的
    // 是裸管道串。拒绝要点名(供应商、证书、过期日 / 采购单、审批状态),用人话。
    'SUPPLIER_QUALIFICATION_EXPIRED', 'PO_NOT_APPROVED',

    'PO_CANCEL_REASON_REQUIRED',   // AUDEL-1b
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
