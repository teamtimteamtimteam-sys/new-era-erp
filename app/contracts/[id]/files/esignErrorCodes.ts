// CONTRACT-ESIGN:合同电子文件、签字、签署人名单与印章那一族的具名拒绝 → 双语句子(contractFiles.errors.*)。
//   码是从【函数体】里逐条数出来的(db/functions/contract_file_* · contract_sign_begin · contract_signatory_* · signature_specimen_record ·
//   company_stamp_record · 两支守卫),外加服务端动作自己先判的几条(标着「应用侧」)。形状取自 contractErrorCodes.ts。
import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

export const ESIGN_ERROR_CODES = new Set([
    'CONTRACT_NOT_FOUND',
    'CONTRACT_FILE_RESTRICTED',
    'CONTRACT_FILE_KIND_INVALID',
    'CONTRACT_FILE_CONTRACT_CLOSED',
    'CONTRACT_FILE_SIGNED_LOCKED',
    'CONTRACT_COUNTERSIGN_NEEDS_SIGNED',
    'CONTRACT_FILE_COUNTERSIGNED_FINAL',
    'CONTRACT_FILE_TYPE_NOT_ACCEPTED',
    'CONTRACT_FILE_EMPTY',
    'CONTRACT_FILE_TOO_LARGE',
    'CONTRACT_FILE_NAME_REQUIRED',
    'CONTRACT_FILE_STORAGE_FULL',
    'CONTRACT_FILE_NOT_FOUND',
    'CONTRACT_FILE_NOT_UPLOADING',
    'CONTRACT_FILE_NOT_STORED',
    'CONTRACT_FILE_MISMATCH',
    'CONTRACT_FILE_HASH_INVALID',
    'CONTRACT_FILE_IMMUTABLE',
    'CONTRACT_FILE_NO_DELETE',
    'CONTRACT_FILE_NOT_VOIDABLE',
    'CONTRACT_VOID_NOT_PERMITTED',
    'CONTRACT_VOID_REASON_REQUIRED',
    'CONTRACT_SIGN_NOT_CURRENT_ORIGINAL',
    'CONTRACT_SIGN_NOT_SIGNATORY',
    'CONTRACT_SIGN_PASSWORD_REQUIRED',
    'CONTRACT_SIGN_NOT_ACTIVE',
    'CONTRACT_FILE_ALREADY_SIGNED',
    'CONTRACT_SIGN_NO_SPECIMEN',
    'CONTRACT_SIGN_NO_STAMP',
    'CONTRACT_SIGN_PLACEMENT_INVALID',
    'CONTRACT_SIGNATORY_EMPLOYEE_NOT_FOUND',
    'CONTRACT_SIGNATORY_NO_LOGIN',
    'CONTRACT_SIGNATORY_ALREADY_LISTED',
    'CONTRACT_SIGNATORY_TITLE_REQUIRED',
    'CONTRACT_SIGNATORY_NOT_LISTED',
    'CONTRACT_SIGNATORY_IMMUTABLE',
    'SIGNING_ASSET_NOT_STORED',
    'SIGNING_ASSET_TYPE',
    'SIGNING_ASSET_HASH_INVALID',
    'SIGNING_ASSET_IMMUTABLE',
    // ── 应用侧(服务端动作自己判的)──
    'CONTRACT_FILE_HASH_MISMATCH',
    'CONTRACT_FILE_UPLOAD_FAILED',
    'CONTRACT_PDF_ENCRYPTED',
    'CONTRACT_PDF_UNREADABLE',
    'CONTRACT_SIGN_PASSWORD_WRONG',
    'CONTRACT_SIGN_PAGE_OUT_OF_RANGE',
    'CONTRACT_SIGN_PAGE_ROTATED',
    'SIGNING_IMAGE_INVALID',
    'SIGNING_UPLOAD_FAILED',
])

export async function localizeEsignError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()
    const m = raw.match(/([A-Z][A-Z0-9_]+)(?:\|([\s\S]*))?$/)
    if (m && ESIGN_ERROR_CODES.has(m[1])) {
        const params: Record<string, string> = {}
        if (m[2]) m[2].split('|').forEach((v, i) => { params[String(i)] = v })
        return t('contractFiles.errors.' + m[1], params)
    }
    return await fallbackForRawError(raw, 'localizeEsignError@app/contracts/[id]/files/esignErrorCodes.ts')
}
