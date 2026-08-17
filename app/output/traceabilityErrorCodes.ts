import { getTranslations } from '@/lib/i18n/server'

// app/output/traceabilityErrorCodes.ts
// AUD-2:traceability_report_data / record_traceability_report_issue 抛出的错误码。
// 端口自 assayErrorCodes.ts。不在集合内的是真正未编码的 DB 错误,原样返回 ——
// 一个被翻译器吞掉的陌生错误,比一串机器码更坏。
const TRACEABILITY_ERROR_CODES = new Set([
    'BATCH_REQUIRED',
    'BATCH_NOT_FOUND',
    'NOT_AN_OUTPUT_BATCH',
    'NOTHING_TO_REPORT',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeTraceabilityError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    // 权限拒绝不是错误,是这个人不该看见 —— 与化验那一份同一条处置。
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await getTranslations())('common.restricted')
    }

    if (!match || !TRACEABILITY_ERROR_CODES.has(match[1])) {
        return raw
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v
        })
    }

    return (await getTranslations())('traceability.errors.' + code, params)
}
