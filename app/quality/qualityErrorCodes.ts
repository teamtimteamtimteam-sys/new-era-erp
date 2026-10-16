import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'
import { refusePermission } from '@/lib/action-refusal'
import { localizeSelfApproval } from '@/lib/selfApproval'

// MES-6a-1(2026-10-09,MES-6a Step 0 Q7–Q23):样品与化验争议的拒绝 → 人话。MES-6b-1 加不合格报告(open_ncr · decide_ncr)。
//   样品的函数(record_sample · record_sample_event · set_quality_settings)与争议的函数(open / record_dispute_umpire / withdraw /
//   resolve_assay_dispute · link_dispute_fee)按名抛的码:`CODE|参数0|…`。PERMISSION_DENIED 是横跨所有模块的那一句。
// 【加一条 = 来这里加一个名字】check-i18n 的 quality.errors.* 后缀集合现读下面这个 Set,漏了句子 npm run build 当场红。
const QUALITY_ERROR_CODES = new Set([
    'SAMPLE_ONE_PARENT', 'SAMPLE_KIND_INVALID', 'SAMPLE_DATE_REQUIRED', 'SAMPLE_DATE_IN_FUTURE', 'SAMPLE_MASS_INVALID',
    'SAMPLE_CHECK_ONLY_FOR_CONTAMINATION', 'SAMPLE_CHECK_NOT_FOR_BATCH', 'SAMPLE_SALES_ORDER_NEEDS_OUTPUT_BATCH',
    'SAMPLE_NOT_FOUND', 'SAMPLE_EVENT_KIND_INVALID', 'SAMPLE_EVENT_TIME_REQUIRED', 'SAMPLE_EVENT_IN_FUTURE', 'SAMPLE_DISPOSED',
    'SAMPLE_EVENT_NOT_ALLOWED', 'SAMPLE_EVENT_OUT_OF_ORDER', 'SAMPLE_LAB_REQUIRED', 'SAMPLE_LAB_ONLY_WHEN_SENT',
    'SAMPLE_LOCATION_REQUIRED', 'SAMPLE_LOCATION_NOT_FOR_EVENT', 'SAMPLE_DISPOSAL_REASON_REQUIRED', 'SAMPLE_REASON_ONLY_WHEN_DISPOSED',
    'SAMPLE_NOT_FOR_BATCH', 'QUALITY_RETENTION_DAYS_INVALID', 'QUALITY_SETTINGS_MISSING',
    'ASSAY_DISPUTE_REASON_REQUIRED', 'ASSAY_DISPUTE_PARTY_MISMATCH', 'ASSAY_DISPUTE_NOT_SAME_BATCH', 'ASSAY_DISPUTE_ALREADY_OPEN',
    'ASSAY_DISPUTE_SALES_ORDER_NEEDS_OUTPUT_BATCH', 'ASSAY_DISPUTE_NOT_FOUND', 'ASSAY_DISPUTE_NOT_OPEN', 'ASSAY_DISPUTE_UMPIRE_EMPTY',
    'ASSAY_DISPUTE_NOTE_REQUIRED', 'ASSAY_DISPUTE_WITHDRAWN', 'ASSAY_DISPUTE_FEE_ALREADY_LINKED', 'ASSAY_DISPUTE_FEE_NO_UMPIRE_ASSAY',
    'ASSAY_DISPUTE_FEE_LAB_HAS_NO_SUPPLIER', 'ASSAY_DISPUTE_FEE_SUPPLIER_MISMATCH', 'ASSAY_DISPUTE_OPEN',
    'ASSAY_NOT_FOUND', 'ASSAY_NOT_FOR_BATCH', 'EXPENSE_NOT_FOUND', 'EXPENSE_NOT_POSTED',
    'INBOUND_NOT_FOUND', 'OUTPUT_NOT_FOUND', 'SO_NOT_FOUND', 'LAB_NOT_FOUND', 'LOCATION_NOT_FOUND',
    // MES-6b-1:不合格报告(open_ncr · decide_ncr)与质量暂扣
    'NCR_ONE_BATCH', 'NCR_SOURCE_SYSTEM_ONLY', 'NCR_SOURCE_RESERVED', 'NCR_SOURCE_INVALID', 'NCR_DESCRIPTION_REQUIRED',
    'NCR_LINK_NOT_FOR_BATCH', 'NCR_SALES_ORDER_OUTPUT_ONLY', 'NCR_NO_OTHER_DECIDER', 'NCR_NOT_FOUND', 'NCR_NOT_OPEN',
    'NCR_DISPOSITION_INVALID', 'NCR_DECISION_NOTE_REQUIRED', 'NCR_PENALTY_DOCUMENT_REQUIRED', 'NCR_PENALTY_DOCUMENT_INVALID',
    'NCR_PENALTY_DOCUMENT_ONLY_WITH_PENALTY', 'NCR_IMMUTABLE',
    // MES-7b-1:来源 incident 的报告(open_ncr 末尾的 p_incident_id)
    'NCR_INCIDENT_REQUIRED', 'NCR_INCIDENT_ONLY_WITH_SOURCE', 'NCR_INCIDENT_BATCH_NOT_LINKED', 'INCIDENT_NOT_FOUND',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeQualityError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await refusePermission(match[2] ?? '')).error
    }
    // MES-6b-1:开单人决定自己那一张(decide_ncr)—— 横跨所有模块的那一句;QUALITY_HOLD_OPEN 在共用兜底那一层说(lib/machine-text.ts)
    if (match && match[1] === 'SELF_APPROVAL_FORBIDDEN') {
        return await localizeSelfApproval((match[2] ?? '').split('|')[0] || null)
    }
    if (!match || !QUALITY_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeQualityError@app/quality/qualityErrorCodes.ts')
    }
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return (await getTranslations())('quality.errors.' + match[1], params)
}
