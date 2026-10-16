import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'
import { refusePermission } from '@/lib/action-refusal'

// MES-7b-1(2026-10-16,MES-7b Step 0 Q3–Q12):事故登记簿的拒绝 → 人话。record_incident · record_incident_update · link_ / unlink_incident_batch ·
//   set_safety_settings 与表上的守卫按名抛的码:`CODE|参数0|…`。PERMISSION_DENIED 是横跨所有模块的那一句。
//   开一张来源 incident 的不合格报告走质量那一边(localizeQualityError)—— 它的码在 quality.errors.* 里。
// 【加一条 = 来这里加一个名字】check-i18n 的 safety.errors.* 后缀集合现读下面这个 Set,漏了句子 npm run build 当场红。
const SAFETY_ERROR_CODES = new Set([
    'INCIDENT_KIND_REQUIRED', 'INCIDENT_TIME_REQUIRED', 'INCIDENT_WHAT_REQUIRED', 'INCIDENT_ACTION_REQUIRED', 'INCIDENT_RESPONSIBLE_REQUIRED',
    'INCIDENT_NEA_REPORTABLE_REQUIRED', 'INCIDENT_SOURCE_RESERVED', 'INCIDENT_TIME_IN_FUTURE', 'INCIDENT_KIND_UNKNOWN', 'INCIDENT_KIND_INACTIVE',
    'INCIDENT_DURATION_INVALID', 'INCIDENT_DOWNTIME_NEEDS_MACHINE', 'INCIDENT_DOWNTIME_NOT_FOUND', 'INCIDENT_DOWNTIME_OTHER_MACHINE',
    'INCIDENT_DOWNTIME_VOIDED', 'INCIDENT_RUN_EVENT_NOT_FOUND', 'INCIDENT_RUN_EVENT_WITHDRAWN', 'INCIDENT_RUN_EVENT_CORRECTED',
    'INCIDENT_INJURED_ONE_PERSON', 'INCIDENT_INJURY_NEEDS_PERSON', 'INCIDENT_DAYS_LOST_INVALID', 'INCIDENT_THROUGH_FUNCTION_ONLY',
    'INCIDENT_IMMUTABLE', 'INCIDENT_NOT_FOUND', 'INCIDENT_UPDATE_KIND_INVALID', 'INCIDENT_NOT_NEA_REPORTABLE', 'INCIDENT_UPDATE_TIME_REQUIRED',
    'INCIDENT_UPDATE_TIME_IN_FUTURE', 'INCIDENT_UPDATE_BEFORE_INCIDENT', 'INCIDENT_ALREADY_RECORDED', 'INCIDENT_CLOSE_SUMMARY_REQUIRED',
    'INCIDENT_CLOSED', 'INCIDENT_CORRECTION_FIELD_INVALID', 'INCIDENT_CORRECTION_REASON_REQUIRED', 'INCIDENT_CORRECTION_VALUE_INVALID',
    'INCIDENT_CORRECTION_NO_CHANGE', 'INCIDENT_UPDATE_IMMUTABLE', 'INCIDENT_UPDATE_THROUGH_FUNCTION_ONLY', 'INCIDENT_KIND_CODE_LOCKED',
    'INCIDENT_LINK_ONE_BATCH', 'INCIDENT_LINK_BASIS_INVALID', 'INCIDENT_LINK_NOT_SUGGESTED', 'INCIDENT_BATCH_ALREADY_LINKED',
    'INCIDENT_LINK_NOT_FOUND', 'INCIDENT_LINK_ALREADY_UNLINKED', 'INCIDENT_UNLINK_REASON_REQUIRED', 'INCIDENT_LINK_IMMUTABLE',
    'INCIDENT_LINK_THROUGH_FUNCTION_ONLY', 'SAFETY_REPORT_DAYS_INVALID', 'SAFETY_CONFIRM_NEEDS_VALUE', 'SAFETY_SETTINGS_MISSING',
    'EQUIPMENT_NOT_FOUND', 'EQUIPMENT_NOT_A_MACHINE', 'LOCATION_NOT_FOUND', 'EMPLOYEE_NOT_FOUND', 'INBOUND_NOT_FOUND', 'OUTPUT_NOT_FOUND',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeSafetyError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await refusePermission(match[2] ?? '')).error
    }
    if (!match || !SAFETY_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeSafetyError@app/safety/safetyErrorCodes.ts')
    }
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return (await getTranslations())('safety.errors.' + match[1], params)
}
