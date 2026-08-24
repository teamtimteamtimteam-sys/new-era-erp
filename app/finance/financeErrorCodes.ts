import { getTranslations } from '@/lib/i18n/server'

// post_journal_entry / reverse_journal_entry / close_period / reopen_period
// 抛出的错误码(端口自 processing/errorCodes.ts)。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,原样返回。
const FINANCE_ERROR_CODES = new Set([
    'JE_NOT_FOUND', 'JE_ALREADY_REVERSED', 'PERIOD_LOCKED',
    'ACCOUNT_NOT_FOUND', 'ACCOUNT_INACTIVE', 'FX_RATE_REQUIRED',
    'JOURNAL_UNBALANCED',
    'NOT_MONTH_END', 'ALREADY_CLOSED', 'TRIAL_BALANCE_UNBALANCED',
    'CLOSE_NOT_FOUND', 'ALREADY_REOPENED', 'REASON_REQUIRED',
    // FIN-23:年结
    'YEAR_CLOSED', 'YEAR_END_INVALID', 'FINAL_PERIOD_NOT_CLOSED',
    'REVALUATION_NOT_RUN', 'DEPRECIATION_NOT_RUN', 'LATER_YEAR_CLOSED',
    'DATE_REQUIRED', 'SYSTEM_START_NOT_SET',
    // SOD-1:职责分离的两条拒绝。两条都由【触发器】抛出,所以它们会从
    // close_period、/finance/settings 的手动锁、以及 record_payment 三条路上冒出来 ——
    // 一条规矩,两个问法(db/functions/assert_segregated.sql)。
    'SOD_POST_AND_CLOSE', 'SOD_PAYEE_AND_PAY',
    // SOD-1:审批开关的两道闸。前三条管【开】,第四条管【关】(关掉会搁死在途单据),
    // 第五条管【开着的时候不许抽走策略】。
    'APPROVALS_POLICY_INCOMPLETE', 'APPROVALS_LEVEL1_ROLE_UNHELD',
    'APPROVALS_LEVEL2_USER_UNKNOWN', 'APPROVALS_CANNOT_DISABLE_WITH_PENDING',
    'APPROVALS_POLICY_LOCKED_WHILE_ON',
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
