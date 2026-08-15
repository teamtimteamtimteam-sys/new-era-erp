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
    // SO-3a:订单流开票(create_order_invoice / void_invoice 的 order 分支)。
    // CREDIT_* 在销售那一族也有同名码 —— 各族各配各的文案,判据仍是"抛错的函数
    // 属于哪一族",不是码长得像谁。
    'SO_NOT_FOUND',
    'SO_INVOICE_ORDER_NOT_CONFIRMED',
    'SO_INVOICE_NOTHING_TO_BILL',
    'SO_INVOICE_LINE_INVALID',
    'SO_LINE_ALREADY_INVOICED',
    'INVOICE_DATE_REQUIRED',
    'INVOICE_ORDER_GST_UNSUPPORTED',
    'INVOICE_LINE_KIND_MISMATCH',
    'CREDIT_HOLD',
    'CREDIT_LIMIT_EXCEEDED',
    // 作废(order 分支)
    'REVERSAL_DATE_REQUIRED',
    'REVERSAL_DATE_NOT_ACCEPTED',
    'INVOICE_HAS_SETTLEMENTS',
    // SO-3b 落地时启用 —— 文案先备好,免得那一刀漏了翻译(键检查会盯着这一条)
    'INVOICE_SHIPPED_NOT_VOIDABLE',
    // INV-2a/2b:签发档(record_invoice_issue)。INVOICE_NOT_FOUND 上面已经有了 ——
    // 同一个码,两族共用一句文案,因为它说的确实是同一件事。
    'INV_VOIDED_NOT_ISSUABLE',
    'INV_NO_LINES',
    'INV_PROFILE_INCOMPLETE',
    // 冲销分录撞上期间锁/年结时经由这里冒出来 —— 说人话,不抛原码
    'PERIOD_LOCKED',
    'YEAR_CLOSED',
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
