import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

// MES-8a:供应商评分卡一族 DB 函数(supplier_scorecard_measures / supplier_scorecard_preview / record_supplier_review /
// set_supplier_score_settings / supplier_grade_advice)抛出的错误码 → 人话。【逐条从函数体枚举出来的】,不是从"撞到过哪几条"数的。
// 不在集合内的是真正未编码的 DB 错误,交给共用兜底 lib/machine-text.ts。
export const SCORECARD_ERROR_CODES = new Set([
    'SUPPLIER_NOT_FOUND',
    'SCORECARD_WINDOW_REQUIRED',
    'SCORECARD_WINDOW_INVALID',
    'SCORECARD_WINDOW_FUTURE',
    'SUPPLIER_REVIEW_NOT_FOUND',
    'SUPPLIER_REVIEW_OTHER_SUPPLIER',
    'SUPPLIER_REVIEW_ALREADY_CORRECTED',
    'SUPPLIER_REVIEW_CORRECTION_REASON_REQUIRED',
    'SUPPLIER_REVIEW_REASON_WITHOUT_CORRECTION',
    'SUPPLIER_REVIEW_IMMUTABLE',
    'SCORE_WEIGHTS_AND_LINES_TOGETHER',
    'SCORE_WEIGHT_MISSING',
    'SCORE_WEIGHT_UNKNOWN',
    'SCORE_WEIGHT_INVALID',
    'SCORE_GRADE_NAME_INVALID',
    'SCORE_GRADE_DUPLICATE',
    'SCORE_GRADE_LINE_INVALID',
    'SCORE_GRADE_LAST_LINE_OPEN',
    'SCORE_REVIEW_WINDOW_INVALID',
    'SCORE_CAP_GRADE_UNKNOWN',
    'SCORE_CAP_PCT_INVALID',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeScorecardError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match) return await fallbackForRawError(raw, 'localizeScorecardError@app/suppliers/scorecardErrorCodes.ts')
    const t = await getTranslations()
    if (match[1] === 'PERMISSION_DENIED') return t('permissions.errDenied')
    if (!SCORECARD_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeScorecardError@app/suppliers/scorecardErrorCodes.ts')
    }
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('scorecards.errors.' + match[1], params)
}
