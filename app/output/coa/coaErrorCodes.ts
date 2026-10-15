import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'
import { refusePermission } from '@/lib/action-refusal'
import { isCaptureErrorCode, localizeCaptureError } from '@/app/operation/capture/captureErrorCodes'

// app/output/coa/coaErrorCodes.ts
// MES-6b-2(2026-10-15,MES-6b Step 0 Q29 · Q31 · Q32):分析证书那几支函数(issue_coa · record_coa_issue · coa_certificate_data · 守卫)
//   按名抛的码 → 人话。【这几句跟界面语言】—— 证书本身一律英文(给买方的),而拒绝是说给按按钮的那个人听的(与销毁证书同一条)。
//   QUALITY_HOLD_OPEN 在共用兜底那一层说(lib/machine-text.ts);称重不在校准期内那一句由采集那一支翻(与销毁证书同一个处置)。
// 【加一条 = 来这里加一个名字】check-i18n 的 coa.errors.* 后缀集合现读下面这个 Set,漏了句子 npm run build 当场红。
const COA_ERROR_CODES = new Set([
    'COA_NO_FINAL_ASSAY', 'COA_SALES_ORDER_NOT_FOR_BATCH', 'COA_ALREADY_ISSUED', 'COA_LIMIT_BREACHED',
    'COA_OUTPUT_WEIGHING_NOT_RECORDED', 'COA_OUTPUT_READING_NOT_RECORDED', 'COA_ISSUER_NOT_AN_EMPLOYEE', 'COA_ISSUER_POSITION_MISSING',
    'COA_NOT_FOUND', 'COA_NOT_ISSUED', 'COA_ISSUE_PATH_INVALID', 'COA_BYTES_ALREADY_RECORDED', 'COA_ISSUED_IMMUTABLE', 'COA_ALREADY_VOID',
    'COA_NO_DELETE', 'COMPANY_LEGAL_NAME_MISSING', 'OUTPUT_NOT_FOUND', 'ASSAY_DISPUTE_OPEN',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeCoaError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    if (isCaptureErrorCode(raw)) return await localizeCaptureError(raw)
    const match = raw.match(CODE_RE)
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await refusePermission(match[2] ?? '')).error
    }
    if (!match || !COA_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeCoaError@app/output/coa/coaErrorCodes.ts')
    }
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return (await getTranslations())('coa.errors.' + match[1], params)
}

/** 一句拒绝的【码】(给页面认出是哪一种,例如把 COA_ALREADY_ISSUED 画成"已有一张"而不是一句红字) */
export function coaErrorCode(message: string): string | null {
    return (message ?? '').trim().match(CODE_RE)?.[1] ?? null
}
