import { getTranslations } from '@/lib/i18n/server'

// post_journal_entry / reverse_journal_entry 抛出的错误码(端口自 processing/errorCodes.ts)。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,原样返回。
const FINANCE_ERROR_CODES = new Set([
    'JE_NOT_FOUND', 'JE_ALREADY_REVERSED', 'PERIOD_LOCKED',
    'ACCOUNT_NOT_FOUND', 'ACCOUNT_INACTIVE', 'FX_RATE_REQUIRED',
    'JOURNAL_UNBALANCED',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..." —— 即使 PostgREST 在前面包了前缀,
// 也能定位到大写下划线的 code 和它后面 |-分隔的参数。找不到已知 code 就原样返回。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeFinanceError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !FINANCE_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('finance.errors.' + code, params)
}
