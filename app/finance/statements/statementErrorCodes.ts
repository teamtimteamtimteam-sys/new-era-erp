import { getTranslations } from '@/lib/i18n/server'

// STATEMENT-1:对账单一族 DB 函数(customer_statement_data / issue_customer_statement /
// record_statement_issue)抛出的错误码。端口自 creditNoteErrorCodes.ts。
// 【逐条从函数体枚举出来的】,不是从"撞到过哪几条"数的。
// 不在集合内的是真正未编码的 DB 错误,原样返回。
const STATEMENT_ERROR_CODES = new Set([
    'CUSTOMER_NOT_FOUND',
    'STATEMENT_PERIOD_REQUIRED',
    'STATEMENT_PERIOD_INVALID',
    'STATEMENT_PERIOD_FUTURE',
    'STATEMENT_DOES_NOT_TIE',
    'STATEMENT_SUPERSEDE_REASON_REQUIRED',
    'STATEMENT_NOT_FOUND',
    'STATEMENT_SUPERSEDED',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeCreditNoteError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeStatementError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match) return raw

    const t = await getTranslations()
    if (match[1] === 'PERMISSION_DENIED') return t('permissions.errDenied')
    if (!STATEMENT_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v
        })
    }
    return t('statements.errors.' + match[1], params)
}
