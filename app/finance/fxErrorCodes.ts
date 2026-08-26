import { getTranslations } from '@/lib/i18n/server'

// FX-RATES-1:record_fx_rate / withdraw_fx_rate 抛出来的错误码(端口自 bankErrorCodes)。
// **逐条从函数体里数出来的**,不是从"我这次撞见了哪几条"倒推的:
// record_fx_rate 有七条,withdraw_fx_rate 两条,两张表的守卫触发器各一条。
const FX_ERROR_CODES = new Set([
    // record_fx_rate
    'FX_RATE_DATE_REQUIRED', 'FX_RATE_DATE_IN_FUTURE', 'FX_CURRENCY_INVALID',
    'FX_CURRENCY_IS_BASE', 'FX_RATE_TYPE_INVALID', 'FX_RATE_INVALID', 'FX_RATE_EXISTS',
    // withdraw_fx_rate
    'FX_REASON_REQUIRED', 'FX_RATE_NOT_FOUND',
    // 守卫触发器
    'FX_RATE_VIA_FUNCTION', 'FX_RATE_HISTORY_IMMUTABLE',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeFxError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match || !FX_ERROR_CODES.has(match[1])) {
        return raw // 真正的非编码错误,原样交出去
    }
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v
        })
    }
    return (await getTranslations())('finance.fxPage.errors.' + match[1], params)
}
