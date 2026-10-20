import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

// MES-9a(2026-10-19):供应商门户一族 DB 函数抛出的错误码 → 人话。【逐条从函数体枚举出来的】:
//   portal_require_link(每一支门户函数的第一句)· portal_user_create_link · portal_user_revoke · portal_contact_anonymise · set_account_setting ·
//   portal_document_open(MES-9b)· portal_submission_begin / _finish / _abandon / _accept / _reject(MES-9c)。
// 不在集合内的是真正未编码的 DB 错误,交给共用兜底 lib/machine-text.ts。
export const PORTAL_ERROR_CODES = new Set([
    'PORTAL_ROLE_REQUIRED',
    'PORTAL_NOT_A_PORTAL_ACCOUNT',
    'PORTAL_ACCESS_REVOKED',
    'PORTAL_SESSION_ENDED',
    'PORTAL_SUPPLIER_NOT_FOUND',
    'PORTAL_CONTACT_NOT_OF_SUPPLIER',
    'PORTAL_CONTACT_NO_EMAIL',
    'PORTAL_EMAIL_NOT_CONTACT',
    'PORTAL_CONTACT_ALREADY_LINKED',
    'PORTAL_ACCOUNT_ALREADY_LINKED',
    'PORTAL_ACCOUNT_HAS_ROLE',
    'PORTAL_ACCOUNT_IS_EMPLOYEE',
    'PORTAL_ACCOUNT_NO_ROLES',
    'PORTAL_ACCOUNT_NO_EMPLOYEE',
    'PORTAL_LINK_NOT_FOUND',
    'PORTAL_ALREADY_REVOKED',
    'PORTAL_REVOKE_REASON_REQUIRED',
    'PORTAL_ANONYMISE_NEEDS_REVOKE',
    'PORTAL_ALREADY_ANONYMISED',
    'ACCOUNT_SETTING_UNKNOWN',
    'ACCOUNT_SETTING_INVALID',
    // MES-9b:portal_document_open
    'PORTAL_DOCUMENT_NOT_FOUND',
    'PORTAL_DOCUMENT_VOID',
    'PORTAL_DOCUMENT_KIND_UNKNOWN',
    // MES-9c:portal_submission_begin · _finish · _abandon(门户)· portal_submission_accept · _reject(员工)
    'PORTAL_UPLOAD_LIMITS_NOT_SET',
    'PORTAL_UPLOAD_TYPE_NOT_ACCEPTED',
    'PORTAL_UPLOAD_TOO_LARGE',
    'PORTAL_UPLOAD_EMPTY',
    'PORTAL_UPLOAD_NAME_REQUIRED',
    'PORTAL_UPLOAD_NOT_STORED',
    'PORTAL_UPLOAD_MISMATCH',
    'PORTAL_CERT_TYPE_UNKNOWN',
    'PORTAL_CERT_DATES_INVALID',
    'PORTAL_SUBMISSION_NOT_FOUND',
    'PORTAL_SUBMISSION_NOT_UPLOADING',
    'PORTAL_SUBMISSION_NOT_WAITING',
    'PORTAL_SUBMISSION_REASON_REQUIRED',
    'PORTAL_SUBMISSION_FILE_PATH_INVALID',
    'PORTAL_SUBMISSION_FILE_NOT_COPIED',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

/** 认得出的码回它的码与人话;认不出的回 null 码与兜底的人话。 */
export async function localizePortalError(message: string): Promise<{ code: string | null; text: string }> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    const t = await getTranslations()
    if (match && match[1] === 'PERMISSION_DENIED') return { code: 'PERMISSION_DENIED', text: t('permissions.errDenied') }
    if (!match || !PORTAL_ERROR_CODES.has(match[1])) {
        return { code: null, text: await fallbackForRawError(raw, 'localizePortalError@app/portal/portalErrorCodes.ts') }
    }
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return { code: match[1], text: t('portal.errors.' + match[1], params) }
}
