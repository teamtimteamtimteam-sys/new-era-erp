import { getTranslations } from '@/lib/i18n/server'
import { localizePaymentError } from '../paymentErrorCodes'
import { localizeFinanceError } from '../financeErrorCodes'

// app/finance/assets/disposalRequestErrorCodes.ts
// ★ APR-9(Tim 2026-09-27):固定资产处置申请 —— 财务提,CFO 批每一张,批准当场处置。提交、决定、撤回与旧门
//   dispose_fixed_asset(只会按名拒 ASSET_DISPOSAL_NEEDS_REQUEST)共用的一份拒绝词表。
//   【只收这一刀新造的码】—— 批准那一刻按原话冒出来的旧码(零成本的卡、银行科目、收款、期间锁、已处置)仍由
//   付款那一份(finance.errors,处置从 FA-1b 起就经它说)说,这里按码族转交,不抄第二份译文。
const DISPOSAL_REQUEST_ERROR_CODES = new Set([
    'ASSET_DISPOSAL_NEEDS_REQUEST',
    'ASSET_DISPOSAL_OPEN',
    'ASSET_DISPOSAL_REQUESTED',
    'ASSET_DISPOSAL_NO_OTHER_DECIDER',
    'ASSET_DISPOSAL_REASON_REQUIRED',
    'ASSET_DISPOSAL_REJECT_REASON_REQUIRED',
    'ASSET_DISPOSAL_NOT_FOUND',
    'ASSET_DISPOSAL_NOT_SUBMITTED',
    'ASSET_DISPOSAL_NOT_OPEN',
    'ASSET_CHANGED_SINCE_REQUEST',
])

// 审批四眼那一族(forbid_self_approval · require_approver_for · 开关)归财务那一份
const APPROVAL_FAMILY = /^(APPROVAL_NOT_AUTHORISED|APPROVALS_NOT_ENABLED)$/

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeDisposalRequestError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await getTranslations())('common.restricted')
    }
    if (match && DISPOSAL_REQUEST_ERROR_CODES.has(match[1])) {
        const params: Record<string, string> = {}
        if (match[2]) {
            match[2].split('|').forEach((v, i) => {
                params[String(i)] = v
            })
        }
        return (await getTranslations())('assetDisposal.errors.' + match[1], params)
    }
    if (APPROVAL_FAMILY.test(match?.[1] ?? '')) return await localizeFinanceError(raw)
    // SELF_APPROVAL_FORBIDDEN、处置的旧话与共用兜底:付款那一份
    return await localizePaymentError(raw)
}
