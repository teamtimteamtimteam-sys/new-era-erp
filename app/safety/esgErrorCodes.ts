// ESG-2(Tim 2026-10-31 Q1–Q15):电网因子 · 标准日工时 · 必修培训 · 公司制度 · 举报那一族的具名拒绝 → 双语句子(esg.errors.*)。
//   码是从【函数体】里逐条数出来的(db/functions/esg_set_grid_factor · esg_set_standard_hours · required_training_save / _retire ·
//   company_policy_record · whistleblowing_report_file / _record_outside / _update · 守卫 guard_grid_emission_factor_write /
//   guard_company_policy_write / guard_whistleblowing_write)。形状取自 esignErrorCodes.ts。
import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

export const ESG_ERROR_CODES = new Set([
    'ESG_GRID_FACTOR_YEAR_INVALID',
    'ESG_GRID_FACTOR_VALUE_INVALID',
    'ESG_GRID_FACTOR_SOURCE_REQUIRED',
    'ESG_GRID_FACTOR_REASON_REQUIRED',
    'ESG_GRID_FACTOR_NO_CHANGE',
    'ESG_GRID_FACTOR_IMMUTABLE',
    'ESG_STANDARD_HOURS_INVALID',
    'ESG_STANDARD_HOURS_NO_CHANGE',
    'REQUIRED_TRAINING_NAME_REQUIRED',
    'REQUIRED_TRAINING_CATEGORY_INVALID',
    'REQUIRED_TRAINING_VALIDITY_INVALID',
    'REQUIRED_TRAINING_APPLIES_INVALID',
    'REQUIRED_TRAINING_POSITIONS_REQUIRED',
    'REQUIRED_TRAINING_POSITION_NOT_FOUND',
    'REQUIRED_TRAINING_NAME_TAKEN',
    'REQUIRED_TRAINING_NOT_FOUND',
    'REQUIRED_TRAINING_RETIRED',
    'COMPANY_POLICY_TITLE_REQUIRED',
    'COMPANY_POLICY_VERSION_REQUIRED',
    'COMPANY_POLICY_OWNER_NOT_FOUND',
    'COMPANY_POLICY_DATES_REQUIRED',
    'COMPANY_POLICY_REVIEW_BEFORE_EFFECTIVE',
    'COMPANY_POLICY_DOCUMENT_REQUIRED',
    'COMPANY_POLICY_NOT_FOUND',
    'COMPANY_POLICY_ALREADY_SUPERSEDED',
    'COMPANY_POLICY_VERSION_SAME',
    'COMPANY_POLICY_IMMUTABLE',
    'WHISTLEBLOWING_EMPLOYEES_ONLY',
    'WHISTLEBLOWING_SUBJECT_REQUIRED',
    'WHISTLEBLOWING_DETAILS_REQUIRED',
    'WHISTLEBLOWING_CONCERNS_CCO_REQUIRED',
    'WHISTLEBLOWING_RECEIVED_ON_REQUIRED',
    'WHISTLEBLOWING_RECEIVED_ON_IN_FUTURE',
    'WHISTLEBLOWING_RECEIVED_VIA_INVALID',
    'WHISTLEBLOWING_NOT_FOUND',
    'WHISTLEBLOWING_CLOSED',
    'WHISTLEBLOWING_STATUS_INVALID',
    'WHISTLEBLOWING_NOTE_REQUIRED',
    'WHISTLEBLOWING_IMMUTABLE',
])

export async function localizeEsgError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()
    const m = raw.match(/([A-Z][A-Z0-9_]+)(?:\|([\s\S]*))?$/)
    if (m && ESG_ERROR_CODES.has(m[1])) {
        const params: Record<string, string> = {}
        if (m[2]) m[2].split('|').forEach((v, i) => { params[String(i)] = v })
        return t('esg.errors.' + m[1], params)
    }
    return await fallbackForRawError(raw, 'localizeEsgError@app/safety/esgErrorCodes.ts')
}
