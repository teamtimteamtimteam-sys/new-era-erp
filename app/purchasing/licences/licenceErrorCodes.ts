// CMPL-1:公司执照那条路上的具名拒绝 → 双语句子。
// 形状取自 commissionErrorCodes / contactErrorCodes(本仓库已有十处同形)。
//
// 【逐条从【约束与函数体】数出来的,不是凭印象列的】
//   ① 表上的 CHECK(db/tables/company_compliance.sql):
//        company_compliance_status_check                        (三值:active/suspended/revoked)
//        company_compliance_approved_storage_limit_tonnes_check  (> 0)
//      两条都由 PostgreSQL 按【约束名】报出来,所以这里按名字认 ——
//      约束名是我们自己起的,错误文本不是。
//   ② RLS 的拒绝:写这张表要 module.suppliers.edit,只有 view 的人会撞上它。
//   ③ 服务端自己先拒的一条(种类必填)与认证够不着那一条。
import { getTranslations } from '@/lib/i18n/server'

const LICENCE_ERROR_CODES = new Set([
    'LICENCE_KIND_REQUIRED',
    'LICENCE_STATUS_INVALID',
    'LICENCE_STORAGE_LIMIT_INVALID',
    'LICENCE_NOT_PERMITTED',
    'LICENCE_AUTH_UNAVAILABLE',
])

const CONSTRAINT_TO_CODE: Record<string, string> = {
    company_compliance_status_check: 'LICENCE_STATUS_INVALID',
    company_compliance_approved_storage_limit_tonnes_check: 'LICENCE_STORAGE_LIMIT_INVALID',
}

export async function localizeLicenceError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()

    for (const [constraint, code] of Object.entries(CONSTRAINT_TO_CODE)) {
        if (raw.includes(constraint)) return t('company.licence.errors.' + code)
    }
    // RLS:按 SQLSTATE 的措辞认,不猜某一句文案
    if (/row-level security|42501/i.test(raw)) {
        return t('company.licence.errors.LICENCE_NOT_PERMITTED')
    }
    if (LICENCE_ERROR_CODES.has(raw)) {
        return t('company.licence.errors.' + raw)
    }
    return raw // 真正的非编码错误 —— 原样呈上,不要吞掉
}
