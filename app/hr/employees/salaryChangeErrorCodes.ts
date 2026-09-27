import { getTranslations } from '@/lib/i18n/server'
import { localizeSelfApproval } from '@/lib/selfApproval'
import { localizeHrError } from '../hrErrorCodes'

// app/hr/employees/salaryChangeErrorCodes.ts
// ★ APR-9(Tim 2026-09-27):调薪申请 —— 财务提,CFO 批(CFO 是当事人时 cco 批)。提交、决定、撤回共用的一份拒绝词表。
//   【只收这一刀新造的码】—— 月薪那几句旧话(SALARY_AMOUNT_INVALID · SALARY_EFFECTIVE_DATE_REQUIRED ·
//   SALARY_EFFECTIVE_IN_POSTED_PERIOD · EMPLOYEE_SEPARATED …)仍由 hrErrorCodes 那一份说,这里按码族转交,不抄第二份。
const SALARY_CHANGE_ERROR_CODES = new Set([
    'SALARY_CHANGE_OWN_REFUSED',
    'SALARY_NOT_SET_USE_INITIAL',
    'SALARY_CHANGE_NO_CHANGE',
    'SALARY_EFFECTIVE_IN_REQUESTED_PERIOD',
    'SALARY_CHANGE_REASON_REQUIRED',
    'SALARY_CHANGE_OPEN',
    'SALARY_CHANGE_NO_OTHER_DECIDER',
    'SALARY_CHANGED_SINCE_REQUEST',
    'SALARY_CHANGE_REJECT_REASON_REQUIRED',
    'SALARY_CHANGE_NOT_FOUND',
    'SALARY_CHANGE_NOT_SUBMITTED',
    'SALARY_CHANGE_NOT_OPEN',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeSalaryChangeError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (match && match[1] === 'SELF_APPROVAL_FORBIDDEN') {
        return await localizeSelfApproval((match[2] ?? '').split('|')[0] || null)
    }
    if (match && SALARY_CHANGE_ERROR_CODES.has(match[1])) {
        const params: Record<string, string> = {}
        if (match[2]) {
            match[2].split('|').forEach((v, i) => {
                params[String(i)] = v
            })
        }
        return (await getTranslations())('salaryChange.errors.' + match[1], params)
    }
    // 其余(权限、月薪的旧话、PDPA、员工状态)与共用兜底:人事那一份
    return await localizeHrError(raw)
}
