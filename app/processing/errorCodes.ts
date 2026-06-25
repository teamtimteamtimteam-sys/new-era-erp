import { getTranslations } from '@/lib/i18n/server'

// commit_processing_run / rollback_processing_run 这两个 DB 函数 RAISE 出来的 13 个错误码。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,原样返回。
const PROCESSING_ERROR_CODES = new Set([
    'NO_INPUTS', 'NO_OUTPUTS', 'LOSS_NEGATIVE', 'DUPLICATE_INPUT',
    'INPUT_QTY_INVALID', 'OUTPUT_QTY_INVALID', 'OUTPUT_NO_MATERIAL',
    'RUN_ALREADY_DELETED', 'INBOUND_NOT_FOUND', 'CONSUMED_EXCEEDS_REMAINING',
    'OUTPUT_EXCEEDS_INPUT', 'RUN_NOT_FOUND', 'OUTPUT_CONSUMED',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..." —— 即使 PostgREST 在前面包了前缀,
// 也能定位到大写下划线的 code 和它后面 |-分隔的参数。找不到已知 code 就原样返回。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeProcessingError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !PROCESSING_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('processing.errors.' + code, params)
}
