import { getTranslations } from '@/lib/i18n/server'

// CASHFLOW-1:现金预测与预计日期那两支函数抛出的错误码。
// 【逐条从函数体枚举出来】,不是从"撞到过哪几条"数的。
// 不在集合内的原样返回 —— 尤其 FX_RATE_MISSING:它是 THE FX RULE 那一族的码,
// 措辞归它自己,这里不去复述。
export const CASH_FORECAST_ERROR_CODES = new Set([
    'FORECAST_WEEK_START_NOT_MONDAY',
    'FORECAST_SUPERSEDE_REASON_REQUIRED',
    'PAYMENT_TERM_NOT_FOUND',
    'EXPECTED_DATE_NOT_APPLICABLE',
    'EXPECTED_DATE_IN_PAST',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeCashForecastError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match) return raw
    const t = await getTranslations()
    if (match[1] === 'PERMISSION_DENIED') return t('permissions.errDenied')
    if (!CASH_FORECAST_ERROR_CODES.has(match[1])) return raw
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('cashForecast.errors.' + match[1], params)
}
