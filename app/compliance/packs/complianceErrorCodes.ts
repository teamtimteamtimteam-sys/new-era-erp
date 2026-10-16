import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

// MES-8b-1:合规包一族 DB 函数(compliance_pack_data / freeze_compliance_pack / record_compliance_pack_issue / set_compliance_settings /
// compliance_pack_month_status)抛出的错误码。【逐条从函数体枚举出来的】。不在集合内的是真正未编码的 DB 错误,交给共用兜底 lib/machine-text.ts。
export const COMPLIANCE_PACK_ERROR_CODES = new Set([
    'COMPLIANCE_PACK_PERIOD_REQUIRED',
    'COMPLIANCE_PACK_MONTH_NOT_LOCKED',
    'COMPLIANCE_PACK_SUPERSEDE_REASON_REQUIRED',
    'COMPLIANCE_PACK_REASON_WITHOUT_SUPERSEDE',
    'COMPLIANCE_PACK_NOT_FOUND',
    'COMPLIANCE_PACK_SUPERSEDED',
    'COMPLIANCE_PACK_ISSUE_PATH_INVALID',
    'COMPLIANCE_PACK_SHA_INVALID',
    'COMPLIANCE_PACK_BYTES_ALREADY_RECORDED',
    'COMPLIANCE_PACK_IMMUTABLE',
    'COMPLIANCE_PACK_ISSUE_IMMUTABLE',
    'COMPLIANCE_SETTINGS_PAIR_INCOMPLETE',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeComplianceError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match) return await fallbackForRawError(raw, 'localizeComplianceError@app/compliance/packs/complianceErrorCodes.ts')
    const t = await getTranslations()
    if (match[1] === 'PERMISSION_DENIED') return t('permissions.errDenied')
    if (!COMPLIANCE_PACK_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeComplianceError@app/compliance/packs/complianceErrorCodes.ts')
    }
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('compliancePacks.errors.' + match[1], params)
}
