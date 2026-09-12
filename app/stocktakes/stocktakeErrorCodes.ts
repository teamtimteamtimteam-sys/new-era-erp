import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

// post_stocktake / cancel_stocktake 这两个 DB 函数 RAISE 出来的错误码(端口自 processing/errorCodes.ts)。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,交给共用兜底 lib/machine-text.ts。
const STOCKTAKE_ERROR_CODES = new Set([
    'STOCKTAKE_NOT_FOUND', 'STOCKTAKE_NOT_OPEN', 'BATCH_DELETED',

    'STOCKTAKE_CANCEL_REASON_REQUIRED',   // AUDEL-1b
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..." —— 即使 PostgREST 在前面包了前缀,
// 也能定位到大写下划线的 code 和它后面 |-分隔的参数。找不到已知 code 就交给共用兜底 lib/machine-text.ts。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeStocktakeError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !STOCKTAKE_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeStocktakeError@app/stocktakes/stocktakeErrorCodes.ts') // BUGFIX-1b:生码 / 数据库报错 → 一句人话 + 一个可追查的短码(人话句子原样留着)
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('stocktakes.errors.' + code, params)
}
