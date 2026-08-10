import { getTranslations } from '@/lib/i18n/server'

// create_invoice / void_invoice 抛出的错误码,端口自 paymentErrorCodes.ts。
// 不在集合内的是真正未编码的 DB 错误,原样返回。
const INVOICE_ERROR_CODES = new Set([
    'CUSTOMER_NOT_FOUND', 'NO_LINES', 'SALE_NOT_FOUND', 'SALE_WRONG_CUSTOMER',
    // SAL-C:无主销售不能开给客户 —— 发票是对外声称谁欠钱
    'SALE_NOT_ATTRIBUTED',
    'ALREADY_INVOICED', 'DUPLICATE_SALE', 'MIXED_CURRENCY',
    'INVOICE_NOT_FOUND', 'INVOICE_ALREADY_VOID', 'REASON_REQUIRED',
    'INVOICE_IMMUTABLE', 'TERMS_INVALID',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeFinanceError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeInvoiceError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !INVOICE_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('invoice.errors.' + code, params)
}
