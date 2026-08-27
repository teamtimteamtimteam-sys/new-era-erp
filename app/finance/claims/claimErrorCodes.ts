import { getTranslations } from '@/lib/i18n/server'

// CLAIM-1:报销那三支函数抛出的错误码。
//
// ★【为什么每一个码都带 EXPENSE_ 前缀,而不是叫 CLAIM_NOT_FOUND】★
// 医疗报销那一族【已经】在抛 CLAIM_NOT_FOUND / CLAIM_NOT_SUBMITTED
// (decide_medical_claim),而 /me 上【已经】有一块 MyClaimsPanel 在显示它们。
// 两种报销落在同一张屏幕上是迟早的事(本刀就把自助面板放在它旁边),
// 那时一个共用的 localizer 会把一种报销的错误译成另一种的措辞 ——
// 一句【看起来对、其实答非所问】的话,正是这个仓库反复记账的那种缺陷。
// 所以这里用命名把碰撞【从构造上】去掉,而不是靠"没人会把两块面板并在一起"。
export const EXPENSE_CLAIM_ERROR_CODES = new Set([
    'EXPENSE_CLAIM_SPEND_DATE_REQUIRED',
    'EXPENSE_CLAIM_SPEND_DATE_FUTURE',
    'EXPENSE_CLAIM_AMOUNT_INVALID',
    'EXPENSE_CLAIM_CURRENCY_UNKNOWN',
    'EXPENSE_CLAIM_DESCRIPTION_REQUIRED',
    'EXPENSE_CLAIM_NOT_FOUND',
    'EXPENSE_CLAIM_NOT_SUBMITTED',
    'EXPENSE_CLAIM_REJECT_REASON_REQUIRED',
    'EXPENSE_CLAIM_ACCOUNT_REQUIRED',
    'EXPENSE_CLAIM_TAX_CODE_REQUIRED',
    'EXPENSE_CLAIM_NO_EVIDENCE',
    'EXPENSE_CLAIM_SELF_APPROVAL',
    'EMPLOYEE_NOT_FOUND',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeExpenseClaimError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match) return raw
    const t = await getTranslations()
    if (match[1] === 'PERMISSION_DENIED') return t('permissions.errDenied')
    // 【期间锁与汇率缺失是别人家的码,原样交出去】PERIOD_LOCKED 归财务那一族、
    // FX_RATE_MISSING 归 THE FX RULE 那一族 —— 措辞归它们自己,这里不复述。
    if (!EXPENSE_CLAIM_ERROR_CODES.has(match[1])) return raw
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('expenseClaims.errors.' + match[1], params)
}
