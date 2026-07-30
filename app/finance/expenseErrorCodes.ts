import { getTranslations } from '@/lib/i18n/server'

// record_expense / reverse_expense 抛出的错误码(端口自 paymentErrorCodes.ts)。
// 文案统一放 expense.errors(FX_RATE_REQUIRED / PERIOD_LOCKED 等与 finance.errors
// 同码但独立成套,避免跨命名空间引用)。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,原样返回。
const EXPENSE_ERROR_CODES = new Set([
    'ACCOUNT_NOT_FOUND', 'ACCOUNT_INACTIVE', 'ACCOUNT_NOT_EXPENSE',
    'AMOUNT_INVALID', 'FX_RATE_REQUIRED', 'PAYMENT_STATUS_INVALID',
    'BANK_INVALID', 'SUPPLIER_REQUIRED_FOR_UNPAID', 'SUPPLIER_NOT_FOUND',
    'PERIOD_LOCKED', 'EXPENSE_NOT_FOUND', 'EXPENSE_ALREADY_REVERSED',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeFinanceError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeExpenseError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !EXPENSE_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('expense.errors.' + code, params)
}
