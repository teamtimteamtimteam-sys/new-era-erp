import { getTranslations } from '@/lib/i18n/server'
import { localizeFinanceError } from '@/app/finance/financeErrorCodes'
import { localizePricingError } from '@/app/tools/pricing/pricingErrorCodes'
import { localizeContractError } from '@/app/contracts/contractErrorCodes'

// app/components/pricing/termsRequestErrorCodes.ts
// ★ APR-8(Tim 2026-09-26):合同条款与定价公式 —— cco 提,CFO 批每一张。四扇提交的门、decide / withdraw、
//   两扇一步的门(停用 · 删除公式)与三组守卫(公式直连写 · 合同表头 · 七张条款表)共用的一份拒绝词表。
//   【只收这一刀新造的码】—— 批准那一刻按原话冒出来的旧码(公式找不到 / 停用、合同那一族、审批四眼)
//   仍由它们各自那一份说,这里按码族转交,不抄第二份译文。
export const TERMS_REQUEST_ERROR_CODES = new Set([
    'PRICING_FORMULA_THROUGH_REQUEST_ONLY',
    'CONTRACT_ACTIVATES_THROUGH_REQUEST',
    'CONTRACT_ACTIVE_IS_FROZEN',
    'CONTRACT_TERMS_FROZEN',
    'TERMS_REQUEST_FREEZES_CONTRACT',
    'TERMS_REQUEST_OPEN',
    'TERMS_REQUEST_NO_OTHER_DECIDER',
    'TERMS_REQUEST_REASON_REQUIRED',
    'TERMS_REQUEST_REJECT_REASON_REQUIRED',
    'TERMS_REQUEST_NO_CHANGE',
    'TERMS_REQUEST_NOT_FOUND',
    'TERMS_REQUEST_NOT_SUBMITTED',
    'TERMS_REQUEST_NOT_OPEN',
    'TERMS_REQUEST_KIND_UNKNOWN',
    'TERMS_CHANGED_SINCE_REQUEST',
    'TERMS_FORMULA_INVALID',
    'FORMULA_NOT_ACTIVE',
    'FORMULA_ALREADY_ACTIVE',
    'CONTRACT_NOT_FOUND',
    'CONTRACT_NOT_ACTIVATABLE',
    'CONTRACT_PERIOD_ENDED',
])

// 审批四眼那一族(forbid_self_approval · require_approver_for · 开关)归财务那一份
const APPROVAL_FAMILY = /^(SELF_APPROVAL_FORBIDDEN|APPROVAL_NOT_AUTHORISED|APPROVALS_NOT_ENABLED)$/

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeTermsRequestError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await getTranslations())('common.restricted')
    }
    if (match && TERMS_REQUEST_ERROR_CODES.has(match[1])) {
        const params: Record<string, string> = {}
        if (match[2]) {
            match[2].split('|').forEach((v, i) => {
                params[String(i)] = v
            })
        }
        return (await getTranslations())('termsRequest.errors.' + match[1], params)
    }
    const code = match?.[1] ?? ''
    if (APPROVAL_FAMILY.test(code)) return await localizeFinanceError(raw)
    if (code.startsWith('CONTRACT_')) return await localizeContractError(raw)
    // 其余(公式找不到 / 停用、表上的 CHECK 原话……)与共用兜底:定价那一份
    return await localizePricingError(raw)
}
