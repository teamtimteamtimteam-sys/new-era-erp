import { getTranslations } from '@/lib/i18n/server'

// CHASE-1:催收一族 DB 函数(record_collection_chase / record_promise_outcome /
// customer_collection_context)抛出的错误码。端口自 statementErrorCodes.ts。
// 【逐条从函数体枚举出来的】,不是从"撞到过哪几条"数的 —— 后者只会收录
// 已经出现过的那些,而没出现过的那些正是会以机器文本示人的那些。
// 不在集合内的是真正未编码的 DB 错误,原样返回。
export const CHASE_ERROR_CODES = new Set([
    'CUSTOMER_NOT_FOUND',
    'CHASE_DATE_REQUIRED',
    'CHASE_DATE_FUTURE',
    'CHASE_CHANNEL_INVALID',
    'CHASE_REACHED_REQUIRED',
    'CHASE_SUMMARY_REQUIRED',
    'CHASE_CONTACT_WITHOUT_REACH',
    'CHASE_NOT_FOUND',
    'CHASE_ALREADY_SUPERSEDED',
    'CHASE_SUPERSEDE_REASON_REQUIRED',
    'CHASE_SUPERSEDE_OUTCOME_RECORDED',
    'CHASE_DOCUMENT_KIND_UNKNOWN',
    'CHASE_DOCUMENT_NOT_THIS_CUSTOMER',
    'PROMISE_REQUIRES_CONTACT',
    'PROMISE_AMOUNT_REQUIRED',
    'PROMISE_AMOUNT_INVALID',
    'PROMISE_DATE_REQUIRED',
    'PROMISE_DATE_BEFORE_CHASE',
    'PROMISE_CURRENCY_UNKNOWN',
    'PROMISE_NOT_FOUND',
    'PROMISE_OUTCOME_ALREADY_RECORDED',
    'PROMISE_OUTCOME_INVALID',
    'PROMISE_CHASE_SUPERSEDED',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeStatementError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeChaseError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match) return raw

    const t = await getTranslations()
    if (match[1] === 'PERMISSION_DENIED') return t('permissions.errDenied')
    // 【汇率缺失是别人家的码,原样交给它自己那支】—— 承诺按催收当天折算,
    // 那一天没有汇率时抛的是 FX_RATE_MISSING,而它的措辞归 THE FX RULE 那一族。
    if (!CHASE_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v
        })
    }
    return t('chases.errors.' + match[1], params)
}
