import { getTranslations } from '@/lib/i18n/server'

// commit_processing_run / rollback_processing_run 这两个 DB 函数 RAISE 出来的 13 个错误码。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,原样返回。
const PROCESSING_ERROR_CODES = new Set([
    'PROCESS_DATE_REQUIRED',
    'COST_ENTRY_ALREADY_SETTLED', 'COST_ENTRY_IS_ESTIMATE', 'COST_ENTRY_NOT_ESTIMATE',
    'COST_ENTRY_SETTLED', 'COST_ENTRY_INVALID', 'RELIEF_MIXED_COST_TYPES',
    'NO_INPUTS', 'NO_OUTPUTS', 'LOSS_NEGATIVE', 'DUPLICATE_INPUT',
    'INPUT_QTY_INVALID', 'OUTPUT_QTY_INVALID', 'OUTPUT_NO_MATERIAL',
    'RUN_ALREADY_DELETED', 'INBOUND_NOT_FOUND', 'CONSUMED_EXCEEDS_REMAINING',
    'OUTPUT_EXCEEDS_INPUT', 'RUN_NOT_FOUND', 'OUTPUT_CONSUMED',
    // cut 3c — allocate_processing_costs 的错误码
    // (fu1: MISSING_METAL_PRICE removed — unpriced metals now skip instead of erroring)
    'RUN_NOT_COMMITTED', 'INVALID_BASIS', 'UNIT_NOT_KG',
    'NO_METAL_VALUE',
    // WO-1a/1b:工单(计划这一侧)+ 接缝。ALLOCATION_BASIS_REQUIRED 一并补上 ——
    // 它 FIN-36 就在抛了,只是从没有人把它编进来,于是屏幕上是机器串。
    'ALLOCATION_BASIS_REQUIRED',
    'WO_NOT_FOUND', 'WO_NOT_RELEASED', 'WO_NOT_DRAFT', 'WO_NOT_CANCELLABLE',
    'WO_NOT_AMENDABLE', 'WO_HAS_RUNS',
    'WO_NO_LINES', 'WO_LINE_QTY_INVALID', 'WO_MATERIAL_NOT_FOUND',
    'WO_DUPLICATE_MATERIAL', 'WO_EXPECTED_QTY_INVALID',
    'WO_EXPECTED_MATERIAL_NOT_FOUND', 'WO_DUPLICATE_EXPECTED',
    'WO_CLOSE_REASON_REQUIRED', 'WO_CANCEL_REASON_REQUIRED',
    'WO_AMEND_REASON_REQUIRED', 'WO_AMEND_NO_CHANGES',
    'WO_LINE_NOT_FOUND', 'WO_LINE_BELOW_CONSUMED', 'WO_EXPECTED_NOT_FOUND',

    'ROLLBACK_REASON_REQUIRED',   // AUDEL-1b
    'DELETE_REASON_REQUIRED',   // AUDEL-1b
    'SOFT_DELETE_NO_DIRECT_UPDATE',   // AUDEL-1b
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
