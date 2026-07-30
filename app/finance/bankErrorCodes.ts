import { getTranslations } from '@/lib/i18n/server'

// 银行对账相关函数抛出的错误码(端口自 paymentErrorCodes.ts)。
// 覆盖 3a 引擎的【全部】错误码 —— 导入(3b)与逐笔匹配/对账(3c)共用一份,
// 3c 落地时这里不需要再改。
const BANK_ERROR_CODES = new Set([
    // import_bank_statement
    'BANK_INVALID', 'NO_LINES', 'LINE_AMOUNT_INVALID', 'LINE_DATE_OUT_OF_RANGE',
    'STATEMENT_NOT_BALANCED', 'PERIOD_INVALID',
    // match / unmatch / ignore
    'LINE_NOT_FOUND', 'STATEMENT_RECONCILED', 'LINE_NOT_UNMATCHED', 'LINE_NOT_MATCHED',
    'LINE_NOT_IGNORED', 'NO_JOURNAL_LINES', 'JL_NOT_FOUND', 'JL_WRONG_ACCOUNT',
    'JL_WRONG_CURRENCY', 'JL_ALREADY_MATCHED', 'JL_ENTRY_REVERSED', 'JL_WRONG_DIRECTION',
    'MATCH_AMOUNT_MISMATCH',
    // reconcile / unreconcile
    'LINES_OUTSTANDING', 'STATEMENT_ALREADY_RECONCILED', 'STATEMENT_NOT_RECONCILED',
    'STATEMENT_NOT_FOUND', 'REASON_REQUIRED',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeFinanceError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeBankError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !BANK_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('bank.errors.' + code, params)
}
