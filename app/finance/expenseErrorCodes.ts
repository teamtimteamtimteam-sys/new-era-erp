import { getTranslations } from '@/lib/i18n/server'

// record_expense / reverse_expense 抛出的错误码(端口自 paymentErrorCodes.ts)。
// 文案统一放 expense.errors(FX_RATE_REQUIRED / PERIOD_LOCKED 等与 finance.errors
// 同码但独立成套,避免跨命名空间引用)。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,原样返回。
const EXPENSE_ERROR_CODES = new Set([
    'FX_RATE_MISSING', 'FX_RATE_NOT_ACCEPTED',
    'ACCOUNT_NOT_FOUND', 'ACCOUNT_INACTIVE', 'ACCOUNT_NOT_EXPENSE',
    'AMOUNT_INVALID', 'FX_RATE_REQUIRED', 'PAYMENT_STATUS_INVALID',
    'BANK_INVALID', 'SUPPLIER_REQUIRED_FOR_UNPAID', 'SUPPLIER_NOT_FOUND',
    // PAYEE-1a:往来对象二选一(供应商 或 员工)。
    // SUPPLIER_REQUIRED_FOR_UNPAID 【数据库不再抛它】—— 它留在这里,是因为
    // 开支表单自己还有一道前置检查在用那句文案(那张表单目前只提供供应商,
    // 员工选项是 1b)。DB 侧的三个新码在这里,否则屏幕上会出现机器码。
    'COUNTERPARTY_REQUIRED_FOR_UNPAID', 'COUNTERPARTY_AMBIGUOUS', 'EMPLOYEE_NOT_FOUND',
    'PERIOD_LOCKED', 'EXPENSE_NOT_FOUND', 'EXPENSE_ALREADY_REVERSED',
    // FIN-22:资本分支(record_expense)与冲销守卫(reverse_expense)
    'CAPITAL_REQUIRES_ASSET', 'ASSET_REQUIRES_CAPITAL_ACCOUNT',
    'ASSET_DESCRIPTION_REQUIRED', 'ASSET_LIFE_INVALID', 'ASSET_RESIDUAL_INVALID',
    'ASSET_IN_SERVICE_BEFORE_ACQUISITION', 'EXPENSE_HAS_ASSET',
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
