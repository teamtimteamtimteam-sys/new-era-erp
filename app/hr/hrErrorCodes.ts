import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'
import { localizeSelfApproval } from '@/lib/selfApproval'

// HR 相关 DB 函数与触发器(upsert/post/unpost_payroll_period、部门与汇报环路守卫)
// 抛出的错误码。端口自 paymentErrorCodes.ts。
// 不在集合内的是真正未编码的 DB 错误,交给共用兜底 lib/machine-text.ts。
const HR_ERROR_CODES = new Set([
    // AP-RECON-1 Batch B:三条日期规矩(Tim AP-RECON-1 Q7)—— 每一条都成句子。
    'POSTING_DATE_BEYOND_CURRENT_MONTH', 'DOCUMENT_DATE_IN_FUTURE',
    'CLAIM_YEAR_BEFORE_SYSTEM_START',
    'SYSTEM_START_NOT_SET', 'CARRY_FORWARD_BEFORE_SYSTEM_START',
    'EXPENSE_DATE_REQUIRED',
    'PAYROLL_POSTED', 'PAYROLL_NOT_FOUND', 'PAYROLL_ALREADY_POSTED', 'PAYROLL_NOT_POSTED',
    'PAYROLL_LINES_PAID', 'PAYROLL_LINE_ALREADY_PAID', 'PAYROLL_LINE_INVALID',
    'PAYROLL_CPF_ALREADY_PAID', 'PAYROLL_CPF_PAID', 'PAYROLL_DEDUCTIONS_ALREADY_PAID', 'PAYROLL_DEDUCTIONS_PAID', 'PAYROLL_NOTHING_TO_PAY',
    'NO_LINES', 'PERIOD_MONTH_INVALID', 'PAYMENT_DATE_REQUIRED',
    'EMPLOYEE_NOT_FOUND', 'DUPLICATE_EMPLOYEE', 'LINE_NOT_BALANCED', 'AMOUNT_INVALID',
    'PAYROLL_CURRENCY_UNSUPPORTED', 'REASON_REQUIRED', 'PERIOD_LOCKED',
    'DEPARTMENT_CYCLE', 'MANAGER_CYCLE',
    // ATTEND-1:考勤底稿。PAYROLL_ATTENDANCE_NOT_COMPLETE 是 post_payroll_period
    // 新加的那道拒绝 —— 它跟其余 PAYROLL_* 一起住在这里,因为读者遇到它的地方
    // 是薪资过账,不是考勤页。
    'ATTENDANCE_MONTH_REQUIRED', 'ATTENDANCE_MONTH_FUTURE', 'ATTENDANCE_PERIOD_EXISTS',
    'ATTENDANCE_PERIOD_NOT_FOUND', 'ATTENDANCE_LINE_NOT_FOUND', 'ATTENDANCE_PERIOD_NOT_OPEN',
    'ATTENDANCE_HOURS_INVALID', 'ATTENDANCE_PERIOD_INCOMPLETE', 'ATTENDANCE_PERIOD_NOT_COMPLETE',
    'ATTENDANCE_REOPEN_REASON_REQUIRED', 'ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL',
    'PAYROLL_ATTENDANCE_NOT_COMPLETE',
    'CURRENCY_INVALID', 'FX_RATE_INVALID',
    // ROLE-1(Tim 的矩阵,2026-09-23):月薪只走绩效评估与 set_initial_salary(第一份,Q7)。
    //   直连写月薪由触发器按名拒;第一份月薪那支函数自己的几条拒绝也住在这里。
    'SALARY_DIRECT_WRITE_REFUSED', 'SALARY_ALREADY_SET', 'SALARY_AMOUNT_INVALID',
    'SALARY_EFFECTIVE_DATE_REQUIRED', 'SALARY_EFFECTIVE_IN_POSTED_PERIOD',
    'EMPLOYEE_SEPARATED', 'PDPA_ALREADY_ANONYMISED',
    // PAYROLL-APR-1(Tim 的矩阵 §5,2026-09-24):工资过账与撤销要 CFO 批准。申请、决定、执行与
    //   等待期间的冻结,各自的拒绝都成句子;批准那一步走 require_approver_for(2)。
    'PAYROLL_NEEDS_APPROVED_REQUEST', 'PAYROLL_REQUEST_OPEN', 'PAYROLL_REQUEST_NOT_FOUND',
    'PAYROLL_REQUEST_NOT_OPEN', 'PAYROLL_REQUEST_NOT_SUBMITTED', 'PAYROLL_REQUEST_REJECT_REASON_REQUIRED',
    'PAYROLL_REQUEST_KIND_UNKNOWN', 'PAYROLL_REVERSAL_REASON_REQUIRED', 'PAYROLL_CHANGED_SINCE_REQUEST',
    'PAYROLL_REVERSAL_REQUESTED', 'PAYROLL_LINES_FROZEN', 'PAYROLL_STATUS_THROUGH_FUNCTION_ONLY',
    'ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL_REQUEST',
    'APPROVAL_NOT_AUTHORISED', 'APPROVALS_NOT_ENABLED',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeFinanceError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeHrError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    // ★ PAYROLL-APR-1:四眼那两句话跨模块【只写一遍】(lib/selfApproval.ts)——
    //   decide_payroll_request 抛 SELF_APPROVAL_FORBIDDEN|raiser(这张申请是你提的,按人认)。
    if (match && match[1] === 'SELF_APPROVAL_FORBIDDEN') {
        return await localizeSelfApproval((match[2] ?? '').split('|')[0] || null)
    }

    if (!match || !HR_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeHrError@app/hr/hrErrorCodes.ts') // BUGFIX-1b:生码 / 数据库报错 → 一句人话 + 一个可追查的短码(人话句子原样留着)
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('hr.errors.' + code, params)
}
