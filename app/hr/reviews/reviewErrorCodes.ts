import { getTranslations } from '@/lib/i18n/server'

// 绩效评估一族 DB 函数(add/update/remove_review_goal、set_goal_assessment、
// set_goal_actual_value、set_review_conclusion、open_for_self_assessment、
// save_self_assessment、submit/approve/acknowledge/void_review、
// open_review_cycle、set_review_reviewer)抛出的错误码。端口自 hrErrorCodes.ts。
// 不在集合内的是真正未编码的 DB 错误,原样返回。
const REVIEW_ERROR_CODES = new Set([
    'REVIEW_NOT_FOUND', 'REVIEW_BAD_STATUS', 'REVIEW_ALREADY_VOID',
    'NOT_REVIEW_REVIEWER', 'NOT_REVIEW_SUBJECT',
    'SELF_APPROVAL_FORBIDDEN', 'SELF_REVIEW_FORBIDDEN',
    'REVIEWER_REQUIRED', 'REVIEWER_SEPARATED',
    'RATING_REQUIRED', 'RATING_NOT_FOUND', 'SUMMARY_REQUIRED',
    'PROBATION_OUTCOME_REQUIRED', 'GOALS_REQUIRED',
    'GOAL_NOT_FOUND', 'GOAL_NOT_IN_REVIEW', 'GOAL_ID_REQUIRED', 'GOAL_RESULTS_NOT_ARRAY',
    'OBJECTIVE_REQUIRED', 'SELF_ASSESSMENT_LOCKED',
    'CYCLE_NOT_FOUND', 'CYCLE_CLOSED',
    'SALARY_EFFECTIVE_IN_POSTED_PERIOD',
    'EMPLOYEE_SEPARATED', 'EMPLOYEE_NOT_FOUND', 'REASON_REQUIRED',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeHrError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeReviewError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match) return raw

    const t = await getTranslations()
    // 权限一族的通用码不归本模块,给通用文案
    if (match[1] === 'PERMISSION_DENIED') return t('permissions.errDenied')
    if (!REVIEW_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }
    return t('reviews.errors.' + match[1], params)
}
