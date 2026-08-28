import { getTranslations } from '@/lib/i18n/server'

// HR 相关 DB 函数与触发器(upsert/post/unpost_payroll_period、部门与汇报环路守卫)
// 抛出的错误码。端口自 paymentErrorCodes.ts。
// 不在集合内的是真正未编码的 DB 错误,原样返回。
const HR_ERROR_CODES = new Set([
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
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeFinanceError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeHrError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !HR_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
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
