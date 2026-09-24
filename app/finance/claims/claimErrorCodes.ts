import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'
import { localizeSelfApproval } from '@/lib/selfApproval'

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
    // AP-RECON-1 Batch B:三条日期规矩(Tim AP-RECON-1 Q7)—— 每一条都成句子。
    'POSTING_DATE_BEYOND_CURRENT_MONTH', 'DOCUMENT_DATE_IN_FUTURE',
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
    // ★ APR-3:EXPENSE_CLAIM_AMOUNT_BASE_UNRESOLVED —— 一个【不该发生】的状态:
    //   牌价查得到,而本位币金额仍然算不出来。按名拒而不是继续往下走。
    'EXPENSE_CLAIM_AMOUNT_BASE_UNRESOLVED',
    // ★ APR-3:接上审批引擎之后,这条路会抛按级别授权的拒绝。
    //   它不归报销这一族所有(每一条接上引擎的链都抛它),但报销的屏幕
    //   要能把它说成人话,否则它会退到共用兜底。
    'APPROVAL_NOT_AUTHORISED',
    'APPROVALS_NOT_ENABLED',
    'EMPLOYEE_NOT_FOUND',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeExpenseClaimError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match) return await fallbackForRawError(raw, 'localizeExpenseClaimError@app/finance/claims/claimErrorCodes.ts')
    const t = await getTranslations()
    // ★★ APR-3(Tim 的 Q5):四眼那两句话跨模块【只写一遍】(lib/selfApproval.ts)。
    //   此前这条链抛的是 EXPENSE_CLAIM_SELF_APPROVAL —— 一条两条腿共用一句话的码,
    //   而那句话写的是「这张单是你提的」。当拒绝的理由是【你就是这张单说的那个人】
    //   时,那句话是【假的】,并且把人指去修错的东西:提单人要找同事批,
    //   而单据的主角要找的是"既不是他、也不是提单人"的第三个人 —— 那个人
    //   可能根本不存在,那是一次真的配置问题。
    //   ☞ 那个码连同它的两条文案在 APR-3 同一个提交里退休了。
    if (match[1] === 'SELF_APPROVAL_FORBIDDEN') {
        return await localizeSelfApproval((match[2] ?? '').split('|')[0] || null)
    }
    if (match[1] === 'PERMISSION_DENIED') return t('permissions.errDenied')
    // 【期间锁与汇率缺失是别人家的码,交给共用兜底 lib/machine-text.ts】PERIOD_LOCKED 归财务那一族、
    // FX_RATE_MISSING 归 THE FX RULE 那一族 —— 措辞归它们自己,这里不复述。
    if (!EXPENSE_CLAIM_ERROR_CODES.has(match[1])) return await fallbackForRawError(raw, 'localizeExpenseClaimError@app/finance/claims/claimErrorCodes.ts')
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('expenseClaims.errors.' + match[1], params)
}
